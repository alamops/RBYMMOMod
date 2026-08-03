-- Trade and battle between two players, anywhere in the world.
--
-- Almost nothing about trading or link battling is reimplemented here.  The
-- engine already owns both: Protocol.TradeSession is a symmetric trade
-- state machine (including trade evolutions and the OT bookkeeping that
-- marks a mon as traded), and LinkBattle is a full lockstep battle.  Both
-- are driven over a SessionNet, so what this module actually does is:
--
--   * carry a request from one player to another through the hub,
--   * run the engine's own hello/verdict handshake between the two peers,
--   * hand the resulting session to the engine's machinery,
--   * and tear it down when either side leaves.
--
-- One rule runs through the teardown, and it is the only thing standing
-- between a trade and a duplicated Pokemon: **finishing locally is not what
-- ends a session.** A session ends when both sides have applied, when the
-- connection genuinely drops, or on a timeout measured in tens of seconds --
-- never on this process getting there first. Everything in the lifecycle
-- section below is a consequence of that.
--
-- Running the real handshake matters.  It is what decides whether two
-- players with different mod sets may battle at all, and it produces the
-- `strict` and `verdict` values the trade and battle code need to refuse a
-- mon the other game would rebuild differently.  Skipping it and hardcoding
-- "full" would silently desync two differently-modded players.

local need, mod = ...
local Wire = need("Wire")
local SessionNet = need("SessionNet")

local M = {}
M.__index = M

-- The one message this file adds to the engine's link vocabulary: "I have
-- applied my half of the trade."  It exists so that neither side has to
-- guess when the session is safe to take down -- see advanceTrade's `done`
-- branch for what happens when the guess is wrong.  Prefixed, because it
-- travels inside the same envelope as hello/party/pick/confirm and must not
-- collide with anything the engine may add later; TradeSession:handle
-- ignores a type it does not know, so a peer running an older build of this
-- mod simply never hears it and falls back to its own teardown.
local APPLIED = "mmo_applied"

-- How long this side waits for the peer once it can no longer make progress
-- on its own.  Both are long relative to a hub round trip on purpose: being
-- impatient here is exactly what broke the trade in the first place.
--
-- CONFIRM_TIMEOUT covers "our confirm is on the wire, theirs has not come
-- back" -- there is a human on the other end reading a yes/no box, so it is
-- generous.  Nothing has been applied when it fires, and nothing can have
-- been applied on the far side either: a peer that never sent its confirm
-- never reached `done`.
local CONFIRM_TIMEOUT = 60
-- SETTLE_TIMEOUT covers the acknowledgement after both sides have applied.
-- No human is involved and nothing is at stake by then, so it is short.
local SETTLE_TIMEOUT = 10

local linkModules, linkTried

-- Loaded on demand: a player who never trades or battles should not drag
-- the link stack in, and a headless validate never touches it at all.
local function link()
  if linkTried then return linkModules end
  linkTried = true
  local ok, protocol = pcall(require, "src.link.Protocol")
  local okH, handshake = pcall(require, "src.link.Handshake")
  local okB, battle = pcall(require, "src.link.LinkBattle")
  if ok and okH and okB then
    linkModules = { Protocol = protocol, Handshake = handshake, Battle = battle }
  else
    mod.log:error("the engine's link modules are unavailable; trading and "
      .. "battling are off for this session -- chat and presence still work")
  end
  return linkModules
end

function M.new(transport, ui)
  return setmetatable({
    transport = transport,
    ui = ui,
    active = nil,      -- the one live session; two at once is never valid
    outgoing = nil,    -- { to, kind } while waiting for an answer
    incoming = nil,    -- { from, name, kind } while the prompt is up
    drops = 0,         -- relays refused since the current session began
  }, M)
end

function M:isBusy()
  return self.active ~= nil or self.outgoing ~= nil
end

-- ------- requests

function M:request(peer, kind)
  if self:isBusy() then
    self.ui:say("You're already busy\nwith someone.")
    return false
  end
  self.outgoing = { to = peer.id, kind = kind, name = peer.name }
  self.transport:send(Wire.REQUEST, { to = peer.id, kind = kind })
  self.ui:say(("Asked %s to\n%s."):format(peer.name,
    kind == "trade" and "trade" or "battle"))
  return true
end

function M:onRequest(game, msg)
  local from = Wire.id(msg.from)
  local name = Wire.name(msg.name)
  local kind = Wire.KINDS[msg.kind] and msg.kind or nil
  if not (from and name and kind) then return end

  -- Busy is answered immediately rather than queued: a prompt that appears
  -- minutes later, over whatever the player is doing by then, is worse than
  -- a refusal the asker can act on now.
  if self:isBusy() then
    self.transport:send(Wire.RESPOND, { to = from, kind = kind, accept = false })
    return
  end

  self.incoming = { from = from, name = name, kind = kind }
  self.ui:confirm(game,
    ("%s wants to\n%s!"):format(name, kind == "trade" and "trade" or "battle"),
    function(yes)
      local pending = self.incoming
      self.incoming = nil
      if not pending then return end
      self.transport:send(Wire.RESPOND,
        { to = pending.from, kind = pending.kind, accept = yes and true or false })
    end)
end

function M:onDecline(msg)
  local name = Wire.name(msg.name) or "They"
  self.outgoing = nil
  self.ui:say(("%s said no."):format(name))
end

-- ------- session lifecycle

function M:onSession(game, msg)
  local peerId = Wire.id(msg.peer)
  local peerName = Wire.name(msg.peerName) or "FRIEND"
  local kind = Wire.KINDS[msg.kind] and msg.kind or nil
  local role = (msg.role == "host" or msg.role == "guest") and msg.role or nil
  if not (peerId and kind and role) then return end

  self.outgoing = nil
  local modules = link()
  if not modules then return end

  -- one warning per session, so the count starts again with the session
  self.drops = 0

  local net = SessionNet.new(self.transport, peerId, peerName)
  self.active = {
    peerId = peerId,
    peerName = peerName,
    kind = kind,
    role = role,
    net = net,
    stage = "handshake",
  }

  -- the engine's own hello, unmodified: same fingerprint, same mod list,
  -- same verdict rules as a cable-club link
  local myHello = modules.Handshake.hello(game, kind)
  self.active.myHello = myHello
  net:send(myHello)
end

-- A refused relay is the same silence src/Hub.lua's onDrop was given a voice
-- for, one layer further in.  Nothing but trade and battle rides this path,
-- so a payload dropped here is a trade that half-happened -- and until this
-- existed it left no trace at all, on either side of the wire.
--
-- Once per session, and never again for it: a peer sending nothing but junk
-- costs the host one line, not a flooded terminal.  The count is reset in
-- onSession, which is the only place a session begins.
function M:noteDrop(reason)
  self.drops = (self.drops or 0) + 1
  if self.drops ~= 1 then return end
  mod.log:warn("dropped a relay from the hub (%s); if a trade or battle "
    .. "seems stuck, leave it from START > MMO and ask again", reason)
end

function M:onRelay(msg)
  local session = self.active
  if not session then
    return self:noteDrop("no session is open on this side")
  end
  if Wire.id(msg.from) ~= session.peerId then
    return self:noteDrop("from someone who is not the peer")
  end
  if type(msg.payload) ~= "table" then
    return self:noteDrop("the payload is not a table")
  end
  session.net:deliver(msg.payload)
end

-- The hub says the other side is gone.
--
-- Marked, not deleted, while a trade is live.  The hub forwards in order, so
-- a relay sent before the goodbye arrives before it -- but both land in the
-- same batch of inbound messages, and deleting the session here threw away a
-- confirm that had already been delivered into its inbox and was one poll
-- away from completing the trade.  That is the duplication bug: whichever
-- side finished first applied and left, and the other was cut off before it
-- could.  So update() gets one more pass to drain what already arrived, and
-- ends the session itself once it has.
--
-- Every other stage has nothing buffered worth reading -- the battle owns
-- its own inbox and watches net.closed -- so those end here as before.
function M:onSessionEnd(reason)
  local session = self.active
  self.outgoing = nil
  if not session then
    self.active = nil
    return
  end
  session.peerGone = reason or "peer_left"
  session.net.closed = true
  if session.stage == "trade" or session.stage == "settling" then return end
  self.active = nil
  if reason == "peer_left" then
    self.ui:say(("%s disconnected."):format(session.peerName))
  end
end

-- What to put on screen when a session ends because the peer left.  A trade
-- that completed has said everything worth saying already; "X disconnected."
-- stacked on top of "X was traded over!" reads as a failure when it was a
-- success.
function M:leaveMessage(session)
  if session.peerGone ~= "peer_left" then return nil end
  if session.applied then return nil end
  return ("%s disconnected."):format(session.peerName)
end

function M:endSession(message)
  local session = self.active
  self.active = nil
  if session then session.net:close() end
  if message then self.ui:say(message) end
end

-- ------- the handshake, then the handoff

function M:beginTrade(game, session, modules)
  if not modules.Handshake.tradeAllowed(session.verdict) then
    return self:endSession("You can't trade\nwith that game.")
  end
  session.trade = modules.Protocol.TradeSession.new(game.data, game.save.party, {
    subset = session.verdict == "subset",
    strict = modules.Handshake.strict(session.verdict),
    peerName = session.peerName,
  })
  session.stage = "trade"
  session.net:send(session.trade:opening())
end

function M:beginBattle(game, session, modules)
  if not modules.Handshake.battleAllowed(session.verdict) then
    return self:endSession("Link battle needs\nthe same mods on\nboth games.")
  end
  session.stage = "battleWait"
  session.myParty = modules.Protocol.packParty(game.save.party)
  -- the host deals the shared seed the lockstep simulation runs on
  if session.role == "host" and love and love.math then
    session.seed = love.math.random(1, 2 ^ 30)
  end
  session.net:send({ type = "party", mons = session.myParty, seed = session.seed })
end

function M:handleHandshake(game, session, msg, modules)
  if msg.type ~= "hello" then return end
  session.theirHello = msg
  local verdict = modules.Handshake.checkCompat(session.myHello, msg)
  session.verdict = verdict
  if session.kind == "trade" then
    self:beginTrade(game, session, modules)
  else
    self:beginBattle(game, session, modules)
  end
end

function M:handleBattleWait(game, session, msg, modules)
  if msg.type ~= "party" then return end
  session.theirParty = msg.mons
  if session.role == "guest" then session.seed = session.seed or msg.seed end
  if not (session.myParty and session.theirParty and session.seed) then return end

  local constructor = session.role == "host"
    and modules.Battle.newHost or modules.Battle.newGuest
  local state, err = constructor(game, session.net, {
    theirName = session.peerName,
    verdict = session.verdict,
    strict = modules.Handshake.strict(session.verdict),
    myParty = session.myParty,
    theirParty = session.theirParty,
    seed = session.seed,
  })
  if not state then
    return self:endSession(err or "That battle can't\nstart.")
  end
  session.stage = "battle"
  -- the engine owns the battle from here; the mod only watches for the
  -- connection dying underneath it
  self.ui:pushState(game, state)
end

function M:handleTrade(game, session, msg)
  local reply = session.trade:handle(msg)
  if reply then session.net:send(reply) end
end

-- Drives the trade UI from the state machine's stage rather than from the
-- messages, so the prompt shown always matches what the machine will accept.
function M:advanceTrade(game, session)
  local trade = session.trade
  if not trade then return end

  if trade.stage == "picking" and not session.pickOpen then
    session.pickOpen = true
    self.ui:pickPartyMon(game, trade, function(index)
      session.pickOpen = false
      if not index then
        session.net:send({ type = "bye" })
        return self:endSession("The trade was\ncancelled.")
      end
      session.net:send(trade:pick(index))
    end)

  -- myConfirm, not just the box flag: the machine sits in "confirming" from
  -- the moment this side answers until the peer's answer arrives, so a test
  -- on the stage alone re-opened the box the instant the player closed it
  -- and asked them to agree to the same trade over and over.
  elseif trade.stage == "confirming" and trade.myConfirm == nil
         and not session.confirmOpen then
    session.confirmOpen = true
    local theirs = trade.theirParty and trade.theirParty[trade.theirPick]
    local label = theirs and tostring(theirs.species) or "their POKéMON"
    self.ui:confirm(game, ("Trade for\n%s?"):format(label), function(yes)
      session.confirmOpen = false
      session.net:send(trade:confirm(yes and true or false))
    end)

  elseif trade.stage == "done" and not session.applied then
    session.applied = true
    local ok, received = pcall(function() return trade:apply(game) end)

    -- Reaching "done" means two things at once: the peer's confirm is in
    -- hand, and this side's own confirm went out before the machine could
    -- get here.  So the peer is one already-sent message away from applying
    -- too -- and tearing the session down at this point, which is what this
    -- used to do, pulled the relay out from under that message.  The hub
    -- told the other side "peer_left", it dropped its session, and the
    -- confirm it was holding was never read: one Pokemon on both sides and
    -- none on the other, decided by nothing but which process got here
    -- first.
    --
    -- The session therefore outlives local completion.  It ends when the
    -- peer says it applied too, when the connection genuinely drops, or on
    -- SETTLE_TIMEOUT -- never on this side finishing.
    session.stage = "settling"
    session.settleClock = 0
    session.net:send({ type = APPLIED })

    if ok then
      local name = received and tostring(received.species) or "a POKéMON"
      self.ui:say(("%s was\ntraded over!"):format(name))
    else
      -- The peer has our confirm and will apply regardless, so there is no
      -- undo to offer; what there is, is a way to see what actually landed.
      mod.log:warn("applying the finished trade raised (%s) -- check the "
        .. "party from START > POKéMON before trading again", tostring(received))
      self.ui:say("The trade failed\nto complete.")
    end

  elseif trade.stage == "cancelled" and not session.applied then
    session.applied = true
    self:endSession(trade.error and ("The trade stopped:\n" .. trade.error)
      or "The trade was\ncancelled.")
  end
end

-- ------- per-tick

function M:update(game, dt)
  local session = self.active
  if not session then return end

  session.net:update()
  -- A transport that died under us is not a peer that finished, so nothing
  -- is applied here that was not applied already.  peerGone is excluded
  -- because onSessionEnd closes the net deliberately and the drain below is
  -- the whole point of still being here.
  if session.net.closed and not session.peerGone then
    if session.applied then return self:endSession(nil) end
    return self:endSession(("The link with %s\nwas lost."):format(session.peerName))
  end

  local modules = link()
  if not modules then return end

  -- Once the battle state is up it owns the inbox: LinkBattle polls the
  -- same SessionNet every frame, and draining it here first would consume
  -- the action/event messages the lockstep simulation is waiting on.
  if session.stage == "battle" then return end

  for _, msg in ipairs(session.net:poll()) do
    if type(msg) == "table" and type(msg.type) == "string" then
      -- Read before the stage is consulted, because it can arrive in the
      -- same batch as the confirm that puts this side into "settling" --
      -- the peer sends both in that order and the hub forwards in order.
      if msg.type == APPLIED then
        session.peerApplied = true
      elseif session.stage == "handshake" then
        self:handleHandshake(game, session, msg, modules)
      elseif session.stage == "battleWait" then
        self:handleBattleWait(game, session, msg, modules)
      elseif session.stage == "trade" then
        self:handleTrade(game, session, msg)
      end
    end
  end

  if session.stage == "trade" then self:advanceTrade(game, session) end
  -- advanceTrade can end the session itself (a cancelled trade), and an
  -- ended session must not be timed out or torn down twice
  if self.active ~= session then return end

  -- Last, and only after the drain above: a peer that finished the trade on
  -- its way out is applied here before its goodbye is acted on.
  if session.peerGone then
    return self:endSession(self:leaveMessage(session))
  end

  self:waitOut(session, dt)
end

-- The two places a session can no longer make progress on its own, and how
-- long each is given.  Everything else it might be waiting on is a human
-- looking at a menu, and a human is allowed to take as long as they like --
-- arming a clock against one of those would abandon live trades.
function M:waitOut(session, dt)
  dt = dt or 0

  if session.stage == "settling" then
    -- Both halves are applied by now; all that is outstanding is the other
    -- end saying so, and neither party changes whichever way this goes.
    if session.peerApplied then return self:endSession(nil) end
    session.settleClock = (session.settleClock or 0) + dt
    if session.settleClock >= SETTLE_TIMEOUT then
      return self:endSession(nil)
    end
    return
  end

  local trade = session.stage == "trade" and session.trade
  if trade and trade.stage == "confirming" and trade.myConfirm ~= nil then
    session.confirmClock = (session.confirmClock or 0) + dt
    if session.confirmClock >= CONFIRM_TIMEOUT then
      -- Fails closed, and it can only fail closed: the peer never sent the
      -- confirm this was waiting for, so the peer never reached "done"
      -- either and neither party has been touched.  The bye says so out
      -- loud rather than leaving them on a box that will never resolve.
      session.net:send({ type = "bye" })
      return self:endSession("They never answered.\nThe trade is off.")
    end
  else
    session.confirmClock = 0
  end
end

return M
