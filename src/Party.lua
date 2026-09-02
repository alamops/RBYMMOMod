-- Parties: up to Config.PARTY_MAX travellers, and the invite that got you there.
--
-- A party is two or three players who have agreed to travel together.  What
-- it buys is small and deliberate -- a marker over each partner's head, a
-- chat scope that reaches them wherever they are, and a members list you can
-- open their trainer card from -- and what it costs is one field on every
-- presence.  Config.PARTY_MAX is three: a pair can invite a third, and one
-- of three leaving leaves a remainder of two.
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

-- The first other member.  Call sites that still speak of "your friend" in
-- the singular -- a LEAVE prompt at size 2, a party-event gate that only
-- needs "is there anyone to tell" -- keep using this; size-3 copy goes
-- through partners() instead.
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

-- Every other member, in hub order.  At PARTY_MAX = 3 there are up to two.
function M:partners()
  local out = {}
  for _, member in ipairs(self.members) do
    if not self:isSelf(member.id) then
      out[#out + 1] = { id = member.id, name = member.name }
    end
  end
  return out
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
  if self:isMember(peer.id) then
    self.ui:say("They're already\nin your party.")
    return false
  end
  if self:count() >= Config.PARTY_MAX then
    self.ui:say("Your party is\nfull.")
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
  --
  -- An invitee already in a party declines even when that party still has
  -- room: growing happens from the asker's side, not by accepting a second
  -- invite into somebody else's list.
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

-- First-formation toast: one partner keeps the singular copy; two names both.
local function formationCopy(partners)
  if #partners >= 2 then
    local a = partners[1].name or "a friend"
    local b = partners[2].name or "a friend"
    return ("with %s and %s"):format(a, b)
  end
  local name = (partners[1] and partners[1].name) or "your friend"
  return ("with %s"):format(name)
end

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
  local prev = self.members
  self.id, self.members = id, members
  self.outgoing, self.incoming = nil, nil

  -- Same party id with a different roster: a third joined, or one left and
  -- the remainder stayed.  Toast the delta rather than replaying formation.
  if had == id then
    local was = {}
    for _, member in ipairs(prev) do was[member.id] = member end
    local now = {}
    for _, member in ipairs(members) do now[member.id] = member end
    for mid, member in pairs(now) do
      if not was[mid] and not self:isSelf(mid) then
        local name = member.name or "Someone"
        self:note(("%s joined the party."):format(name))
        self.ui:say(("%s joined\nthe party."):format(name))
      end
    end
    for mid, member in pairs(was) do
      if not now[mid] and not self:isSelf(mid) then
        local name = member.name or "Someone"
        self:note(("%s left the party."):format(name))
        self.ui:say(("%s left\nthe party."):format(name))
      end
    end
    return
  end

  local with = formationCopy(self:partners())
  self:note(("Teamed up %s."):format(with))
  self.ui:say(("You're in a party\n%s!"):format(with))
end

-- The hub says the party is over.  Reasons are `left` (we are the one who
-- left, so the box would be telling us what we just did) and `peer_left`.
-- At size 3 a single peer leaving normally arrives as mmo.party with the
-- remainder, not as party_end -- this path is the dissolve (or a hub that
-- still ends the whole group).
function M:onEnd(msg)
  if not self:has() then
    -- Our own leave already cleared the state optimistically; the hub's
    -- confirmation landing afterwards is the ordinary case, not an error.
    self.outgoing, self.incoming = nil, nil
    return
  end
  local partners = self:partners()
  local reason = msg and msg.reason
  self:reset()
  if reason == "left" then return end
  -- Naming only the first partner would lie when two people just left the
  -- list together; keep the singular peer_left copy at size 2.
  if #partners > 1 then
    self:note("Someone left the party.")
    self.ui:say("Someone left\nthe party.")
  else
    local name = (partners[1] and partners[1].name) or "Your friend"
    self:note(("%s left the party."):format(name))
    self.ui:say(("%s left\nthe party."):format(name))
  end
end

-- Leaving clears us locally and asks the hub to drop us.  At two people the
-- hub dissolves the party; at three the other two stay together.  Cleared
-- here rather than on the hub's answer: pressing LEAVE has to leave, even on
-- a connection that is already dying.  The hub's follow-up (party_end, or
-- mmo.party with the remainder) lands on a client that has nothing left to
-- clear, which onEnd / onParty treat as ordinary.
function M:leave()
  if not self:has() then return false end
  local partners = self:partners()
  self:reset()
  self.transport:send(Wire.PARTY_LEAVE, {})
  if #partners > 1 then
    self:note("Left the party.")
  else
    local name = (partners[1] and partners[1].name) or "your friend"
    self:note(("Left the party with %s."):format(name))
  end
  return true
end

M.MAX = Config.PARTY_MAX

return M
