-- Parties: you and one friend, and the invite that got you there.
--
-- A party is two players who have agreed to travel together.  What it buys
-- is small and deliberate -- a marker over your partner's head, a chat scope
-- that reaches them wherever they are, and a members list you can open their
-- trainer card from -- and what it costs is one field on every presence.
-- Config.PARTY_MAX says why it is two and not six.
--
-- **The hub owns the membership; this module owns what the player sees.**
-- Nothing here decides that a party exists: mmo.party arrives with the whole
-- list in it and replaces whatever was held, so a client can never end up
-- carrying a member the hub has already forgotten.  The one exception is
-- leaving, which clears locally before the confirmation comes back -- see
-- M:leave.
--
-- Shaped like Sessions: a transport and a ui handed in at construction, no
-- engine modules, no love.  That is what lets the suite drive the whole
-- invite handshake -- both sides of it -- under plain luajit.

local need = ...
local Config = need("Config")
local Wire = need("Wire")

local M = {}
M.__index = M

function M.new(transport, ui, chat)
  return setmetatable({
    transport = transport,
    ui = ui,
    chat = chat,
    id = nil,
    members = {},     -- ordered, as the hub listed them
    selfId = nil,
    outgoing = nil,   -- { to, name } while an invite of ours is unanswered
    incoming = nil,   -- { from, name } while the prompt is up
  }, M)
end

-- ------- state

-- Which of the members is us.  The roster deliberately drops our own
-- presence (it is what stops the local player being drawn as their own
-- remote avatar), so a party -- which does include us -- cannot ask it who
-- we are and is told directly at welcome instead.
function M:setSelf(id) self.selfId = id end

function M:has() return self.id ~= nil end

function M:isSelf(id)
  return self.selfId ~= nil and id == self.selfId
end

function M:isMember(id)
  if not id then return false end
  for _, member in ipairs(self.members) do
    if member.id == id then return true end
  end
  return false
end

-- True only for somebody else in our party -- the test the map marker and
-- the roster's PARTY column want, both of which are about a player who is
-- not us.
function M:isPartner(id)
  return not self:isSelf(id) and self:isMember(id)
end

-- A copy, so a screen holding the list across a frame cannot be surprised by
-- a party that ended underneath it.
function M:list()
  local out = {}
  for _, member in ipairs(self.members) do
    out[#out + 1] = { id = member.id, name = member.name }
  end
  return out
end

function M:count() return #self.members end

-- The other member.  At PARTY_MAX = 2 there is exactly one, which is what
-- lets the party chat scope take no target and the LEAVE prompt name a
-- person rather than a group.
function M:partner()
  for _, member in ipairs(self.members) do
    if not self:isSelf(member.id) then return member end
  end
  return nil
end

function M:partnerName()
  local partner = self:partner()
  return partner and partner.name or nil
end

-- Everything about the party goes, including a half-finished invite: a
-- prompt left armed across a disconnect would answer to a hub that is no
-- longer listening.
function M:reset()
  self.id, self.members = nil, {}
  self.outgoing, self.incoming = nil, nil
end

-- A line in the chat log, so the party's own history says when it started
-- and when it ended rather than only what was said in between.  Marked
-- outgoing: it is this client narrating itself, and it must not add to the
-- unread count.
function M:note(text)
  if not (self.chat and text) then return nil end
  return self.chat:push({
    name = "PARTY", scope = "party", text = text, outgoing = true,
  })
end

-- ------- inviting

function M:invite(peer)
  if not (peer and peer.id) then return false end
  if self:has() then
    self.ui:say("You're already in\na party.")
    return false
  end
  if self.outgoing then
    self.ui:say(("You already asked\n%s."):format(self.outgoing.name or "them"))
    return false
  end
  self.outgoing = { to = peer.id, name = peer.name }
  self.transport:send(Wire.PARTY_INVITE, { to = peer.id })
  self.ui:say(("Asked %s to\nteam up."):format(peer.name or "them"))
  return true
end

function M:onInvite(game, msg)
  local from = Wire.id(msg.from)
  local name = Wire.name(msg.name)
  if not (from and name) then return end

  -- Answered immediately rather than queued, for the same reason a trade
  -- request is: a prompt that surfaces minutes later, over whatever the
  -- player is doing by then, is worse than a no the asker can act on now.
  if self:has() or self.incoming or self.outgoing then
    self.transport:send(Wire.PARTY_RESPOND, { to = from, accept = false })
    return
  end

  self.incoming = { from = from, name = name }
  self.ui:confirm(game, ("%s wants to\nteam up!"):format(name), function(yes)
    local pending = self.incoming
    self.incoming = nil
    if not pending then return end
    self.transport:send(Wire.PARTY_RESPOND,
      { to = pending.from, accept = yes and true or false })
  end)
end

function M:onDecline(msg)
  local name = Wire.name(msg.name) or "They"
  self.outgoing = nil
  -- Two ways to be turned down, and they are worth telling apart: somebody
  -- who said no might say yes later, somebody already travelling with a
  -- friend cannot be asked again until they are not.
  if msg.reason == "in_party" then
    self.ui:say(("%s is already\nin a party."):format(name))
  else
    self.ui:say(("%s said no."):format(name))
  end
end

-- A player left the game.  Only ever about an invite in flight -- a party
-- they were *in* ends through the hub's own mmo.party_end.
--
-- Without this, an invite pointed at somebody who disconnects before
-- answering is an ask that can never be answered: the hub drops its side of
-- it silently (there is nobody left to answer, so there is no decline to
-- send), and this client goes on believing an answer is coming. Every later
-- invite is then refused by our own "You already asked X." -- a player
-- locked out of the feature by somebody else's dropped connection, with the
-- name of a trainer who is no longer on the roster.
function M:onPeerGone(id)
  if not id then return end
  if self.outgoing and self.outgoing.to == id then
    local name = self.outgoing.name or "They"
    self.outgoing = nil
    self.ui:say(("%s went\noffline."):format(name))
  end
  -- Their prompt may still be on screen; the callback checks for this and
  -- answers nothing, which is right -- there is nobody to answer.
  if self.incoming and self.incoming.from == id then
    self.incoming = nil
  end
end

-- ------- the party itself

function M:onParty(msg)
  local id = Wire.id(msg.id)
  local members = Wire.members(msg.members)
  if not (id and members) then return end

  -- An ask that was still on screen when this landed can no longer be said
  -- yes to, so it is said no to out loud rather than dropped.
  --
  -- Dropping it is a dead end for the *other* player, not for us: their
  -- client holds an outgoing invite until it hears back, so a silently
  -- forgotten prompt leaves them permanently unable to ask anyone, with
  -- nothing on screen explaining why. The hub refuses the pairing either way
  -- (party_respond re-checks both sides before forming); this is only about
  -- who finds out.
  if self.incoming then
    self.transport:send(Wire.PARTY_RESPOND,
      { to = self.incoming.from, accept = false })
  end

  local had = self.id
  self.id, self.members = id, members
  self.outgoing, self.incoming = nil, nil
  if had == id then return end

  local name = self:partnerName() or "your friend"
  self:note(("Teamed up with %s."):format(name))
  self.ui:say(("You're in a party\nwith %s!"):format(name))
end

-- The hub says the party is over.  Reasons are `left` (we are the one who
-- left, so the box would be telling us what we just did) and `peer_left`.
function M:onEnd(msg)
  if not self:has() then
    -- Our own leave already cleared the state optimistically; the hub's
    -- confirmation landing afterwards is the ordinary case, not an error.
    self.outgoing, self.incoming = nil, nil
    return
  end
  local name = self:partnerName() or "Your friend"
  local reason = msg and msg.reason
  self:reset()
  if reason == "left" then return end
  self:note(("%s left the party."):format(name))
  self.ui:say(("%s left\nthe party."):format(name))
end

-- Leaving ends the party for both of us -- there is no "the party continues
-- without you" at two people, which is the whole of Config.PARTY_MAX's
-- consequence.
--
-- Cleared here rather than on the hub's answer, and that ordering is the
-- point: pressing LEAVE has to leave, even on a connection that is already
-- dying.  The hub's mmo.party_end lands a moment later on a client that has
-- nothing left to clear, which onEnd treats as ordinary.
function M:leave()
  if not self:has() then return false end
  local name = self:partnerName() or "your friend"
  self:reset()
  self.transport:send(Wire.PARTY_LEAVE, {})
  self:note(("Left the party with %s."):format(name))
  return true
end

M.MAX = Config.PARTY_MAX

return M
