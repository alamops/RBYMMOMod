-- Trade and battle between two players, anywhere in the world.
--
-- **The two kinds part company here, and have since PROTOCOL 10.**
--
-- A *trade* is still the engine's own machinery: Protocol.TradeSession is a
-- symmetric state machine -- trade evolutions, the OT bookkeeping that marks a
-- mon as traded, all of it -- driven over a SessionNet whose payloads the hub
-- forwards unread.  So for a trade this module carries the request, runs the
-- engine's real hello/verdict handshake, hands the session to TradeSession,
-- and tears it down when either side leaves.
--
-- A *battle* no longer touches any of that.  The intermediator -- the Node hub
-- or a LAN host running src/BattleSim/ -- resolves the fight itself, so both
-- clients upload what they are bringing and then draw an ordered event stream.
-- src/MediatedBattle.lua is that client, and the three consequences here are
-- worth stating plainly:
--
--   * **No handshake.** Both hubs hard-cut mmo.relay for a battle session
--     (relay.js's "this battle is mediated" drop), so a hello sent down that
--     path would not arrive -- and there is nothing left for it to decide.
--   * **No canBattle refuse.** The fingerprint gate existed because a lockstep
--     pair had to agree about their content before they could roll the same
--     numbers.  The intermediator rolls them now, off an uploaded chart and
--     uploaded parties, so a Red can fight a Yellow and a data pack can fight
--     vanilla.  M.canBattle survives below because the pairing rule is still
--     worth stating and still tested -- it is simply no longer consulted.
--   * **No mmo.result.** The dual-client vote is replaced by the
--     intermediator's single mmo.battle_outcome, and the way that is made
--     structural rather than remembered is that nothing on this path ever
--     records a `lastBattle` for M:claimBattle to hand out.
--
-- One rule runs through the trade teardown, and it is the only thing standing
-- between a trade and a duplicated Pokemon: **finishing locally is not what
-- ends a session.** A session ends when both sides have applied, when the
-- connection genuinely drops, or on a timeout measured in tens of seconds --
-- never on this process getting there first. Everything in the lifecycle
-- section below is a consequence of that.
--
-- Running the real handshake still matters for the trade half.  It produces
-- the `strict` and `verdict` values TradeSession needs to refuse a mon the
-- other game would rebuild differently; hardcoding "full" would silently
-- desync two differently-modded players.

local need, mod = ...
local Wire = need("Wire")
local SessionNet = need("SessionNet")
local MediatedBattle = need("MediatedBattle")

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
    outgoing = nil,    -- { to, kind, name } while waiting for an answer
    incoming = nil,    -- { from, name, kind } while the prompt is up
    waitBox = nil,     -- held "Waiting for NAME..." box for a battle ask
    incomingBox = nil, -- held yes/no box on the asked side
    drops = 0,         -- relays refused since the current session began
    -- The mediated fight, held apart from `active` rather than inside it.
    -- They are never both set -- a session is a trade or a battle -- and the
    -- separation is what keeps every `self.active` branch below about trade
    -- alone instead of asking which kind it is looking at.
    fight = nil,
  }, M)
end

function M:isBusy()
  return self.active ~= nil or self.outgoing ~= nil or self.fight ~= nil
end

-- A state on the engine stack that means "this player is in a fight".
-- Wild / trainer / link are BattleState.kind; a co-op 2-on-2 carries `.sim`
-- and has no kind of its own.  Scanned anywhere on the stack, not only the
-- top: a menu or co-op prompt can sit above a live battle, and an invite
-- popping over either is the bug this exists to stop.
--
-- A mediated screen is none of those -- it is not a BattleState, and it has no
-- sim because the sim is on the intermediator -- so it says so with a marker
-- of its own rather than borrowing a field that means something else.
function M.isFightState(state)
  if type(state) ~= "table" then return false end
  local kind = state.kind
  if kind == "wild" or kind == "trainer" or kind == "link" then return true end
  if state.sim ~= nil then return true end
  if state.mmoBattle == true then return true end
  return false
end

function M.stackHasFight(game)
  local stack = game and game.stack
  if not stack then return false end
  local states = stack.states
  if type(states) == "table" then
    for i = #states, 1, -1 do
      if M.isFightState(states[i]) then return true end
    end
    return false
  end
  local top = stack.top and stack:top()
  return M.isFightState(top)
end

-- True while this client is mid-fight: an optional `fighting` callback
-- (Client wires co-op running/state through it) or a battle still on the
-- stack.  Trade/PVP sessions are already covered by isBusy.
function M:inFight(game)
  if self.fighting and self.fighting(game) then return true end
  return M.stackHasFight(game)
end

-- ------- prompt stack helpers
--
-- The waiting box and the incoming confirm are screens on the engine's
-- stack.  An answer that arrives while they are up -- a refuse, a cancel,
-- a peer going offline, the session actually starting -- has to take them
-- down rather than leave them buried under whatever comes next.  Same shape
-- as Coop:closeAskBox / unwindTo: only pop when the held box is still on
-- the stack, and never hunt blindly.

function M:onStack(game, target)
  local stack = game and game.stack
  local states = stack and stack.states
  if not (states and target) then return nil end
  for i = #states, 1, -1 do
    if states[i] == target then return true end
  end
  return false
end

function M:unwindTo(game, target, alsoPop)
  local stack = game and game.stack
  if not (stack and target) then return false end
  if self:onStack(game, target) == false then return false end
  local guard = 0
  while stack:top() and stack:top() ~= target and guard < 16 do
    stack:pop()
    guard = guard + 1
  end
  if alsoPop and stack:top() == target then stack:pop() end
  return true
end

function M:closeWaitBox()
  local held = self.waitBox
  self.waitBox = nil
  if not (held and held.box) then return false end
  return self:unwindTo(held.game, held.box, true)
end

function M:closeIncomingBox()
  local held = self.incomingBox
  self.incomingBox = nil
  if not (held and held.box) then return false end
  return self:unwindTo(held.game, held.box, true)
end

-- ------- requests

-- The box the asker stands behind after a battle request.  B (and the only
-- row) opens a yes/no confirm rather than cancelling outright: backing out of
-- an ask that is already on somebody else's screen is worth a second look,
-- and a no drops straight back onto this waiting line because the confirm
-- sits on top of it.
function M:showWaiting()
  local outgoing = self.outgoing
  if not (outgoing and outgoing.kind == "battle") then return end
  local name = outgoing.name or "them"
  local game = self.ui.ctx and self.ui.ctx.game
  local box = self.ui:choose(game, ("Waiting for\n%s..."):format(name), {
    {
      label = "CANCEL",
      onSelect = function()
        if not self.outgoing then return end
        self.ui:confirm(game, "Cancel the\nrequest?", function(yes)
          if not yes then return end
          self:cancelRequest()
        end, { defaultNo = true })
      end,
    },
  })
  self.waitBox = { box = box, game = game }
end

function M:request(peer, kind)
  if self:isBusy() then
    self.ui:say("You're already busy\nwith someone.")
    return false
  end
  local game = self.ui.ctx and self.ui.ctx.game
  if self:inFight(game) then
    self.ui:say("Finish your battle\nfirst.")
    return false
  end
  self.outgoing = { to = peer.id, kind = kind, name = peer.name }
  self.transport:send(Wire.REQUEST, { to = peer.id, kind = kind })
  -- A battle ask holds the screen until it is answered or cancelled: the
  -- old one-line "Asked X to battle." dismissed itself on A and left the
  -- player locked as busy with nothing on screen saying why.  Trade keeps
  -- the short sentence -- there is no waiting box for it yet.
  if kind == "battle" then
    self:showWaiting()
  else
    self.ui:say(("Asked %s to\ntrade."):format(peer.name))
  end
  return true
end

-- Take our unanswered ask back.  Safe when there is none: every exit that
-- might race a human press goes through here.
function M:cancelRequest()
  local outgoing = self.outgoing
  if not outgoing then return false end
  self.outgoing = nil
  self:closeWaitBox()
  self.transport:send(Wire.REQUEST_CANCEL, {})
  return true
end

function M:onRequest(game, msg)
  local from = Wire.id(msg.from)
  local name = Wire.name(msg.name)
  local kind = Wire.KINDS[msg.kind] and msg.kind or nil
  if not (from and name and kind) then return end

  -- Busy, already prompted, or mid-fight: answered immediately rather than
  -- queued.  A yes/no over a wild encounter, a link battle, or a co-op
  -- screen is worse than a refusal the asker can act on now -- and is how
  -- invites used to appear in the middle of fights.
  if self:isBusy() or self.incoming or self:inFight(game) then
    self.transport:send(Wire.RESPOND, { to = from, kind = kind, accept = false })
    return
  end

  self.incoming = { from = from, name = name, kind = kind }
  local box = self.ui:confirm(game,
    ("%s wants to\n%s!"):format(name, kind == "trade" and "trade" or "battle"),
    function(yes)
      local pending = self.incoming
      self.incoming = nil
      self.incomingBox = nil
      if not pending then return end
      self.transport:send(Wire.RESPOND,
        { to = pending.from, kind = pending.kind, accept = yes and true or false })
    end)
  self.incomingBox = { box = box, game = game }
end

function M:onDecline(msg)
  local outgoing = self.outgoing
  local name = Wire.name(msg.name) or (outgoing and outgoing.name) or "They"
  local kind = outgoing and outgoing.kind
  self.outgoing = nil
  self:closeWaitBox()
  if kind == "battle" then
    self.ui:say(("%s refused\nto battle."):format(name))
  else
    self.ui:say(("%s said no."):format(name))
  end
end

-- The asker walked away before we answered.  Their name is stamped by the
-- hub, so a forged cancel cannot put somebody else's nick on this sentence.
function M:onCancel(msg)
  local from = Wire.id(msg.from)
  local name = Wire.name(msg.name) or "They"
  local pending = self.incoming
  if not pending then return end
  if from and pending.from ~= from then return end
  self.incoming = nil
  self:closeIncomingBox()
  self.ui:say(("%s cancelled\nthe invite."):format(name))
end

-- A player left the game.  Same duty Party:onPeerGone has for invites: an
-- unanswered ask pointed at somebody who is gone can never be answered, and
-- without this the asker stays busy forever with nothing on screen saying
-- why.  The hub clears its pendingTo in silence; this is the half that
-- tells the human.
function M:onPeerGone(id)
  if not id then return end
  if self.outgoing and self.outgoing.to == id then
    local name = self.outgoing.name or "They"
    self.outgoing = nil
    self:closeWaitBox()
    self.ui:say(("%s went\noffline."):format(name))
  end
  if self.incoming and self.incoming.from == id then
    self.incoming = nil
    self:closeIncomingBox()
  end
end

-- ------- session lifecycle

function M:onSession(game, msg)
  local peerId = Wire.id(msg.peer)
  local peerName = Wire.name(msg.peerName) or "FRIEND"
  local kind = Wire.KINDS[msg.kind] and msg.kind or nil
  local role = (msg.role == "host" or msg.role == "guest") and msg.role or nil
  if not (peerId and kind and role) then return end

  self.outgoing = nil
  self.incoming = nil
  -- The waiting / invite boxes outlive the ask they were about the moment
  -- the session starts; left up they bury under the trade or battle screen
  -- and resurface when it pops.
  self:closeWaitBox()
  self:closeIncomingBox()

  -- The hub's id for this pairing, and for a battle it is also the id of the
  -- fight: every mediated message names the battle, and both intermediators
  -- key their record on the session id rather than minting a second one.
  local sessionId = Wire.id(msg.id)

  -- one warning per session, so the count starts again with the session
  self.drops = 0

  -- The fork.  Deliberately *before* link(): a mediated battle needs neither
  -- Protocol nor Handshake nor LinkBattle, so a build whose link stack failed
  -- to load can still fight -- it just cannot trade.
  if kind == "battle" then
    return self:beginMediated(game, sessionId, peerId, peerName, role)
  end

  local modules = link()
  if not modules then return end

  local net = SessionNet.new(self.transport, peerId, peerName)
  self.active = {
    id = sessionId,
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

-- ------- the mediated battle
--
-- Four short functions, because there is very little left to do on this side:
-- open the screen, forward the three inbound types to it, and leave the hub's
-- pairing when it is over.  Everything that used to live between those steps
-- -- the handshake, the verdict, the seed, the party pack, the lockstep loop --
-- is either on the intermediator now or does not exist.

-- Put up the fight and upload what we are bringing.
--
-- The upload happens *here* rather than only in the screen's `enter`, and the
-- ordering is load-bearing: it is what lets the fight be driven with no state
-- stack at all -- the headless suite, and any build whose UI failed to come
-- up.  MediatedBattle:start is idempotent, so `enter` doing it again is free.
function M:beginMediated(game, sessionId, peerId, peerName, role)
  if not sessionId then
    -- Every mediated message names its battle, so a session with no id is a
    -- fight nothing could be uploaded to.  Left rather than sat in: the hub
    -- would hold the pairing open until somebody's grace expired.
    mod.log:warn("the hub started a battle without naming it, so there is "
      .. "nothing to upload a party to -- ask again, and report this if it "
      .. "keeps happening")
    self.transport:send(Wire.SESSION_LEAVE, {})
    return false
  end

  local fight = MediatedBattle.new({
    transport = self.transport,
    ui        = self.ui,
    game      = game,
    battle    = sessionId,
    role      = role,
    peerId    = peerId,
    peerName  = peerName,
    autoPick  = self.autoPick == true,
    onDone    = function() self:endMediated() end,
  })
  self.fight = fight
  fight:start(game)
  self.ui:pushState(game, fight)
  return true
end

-- Protocol-only wild mediated fight: the caller (or a test) already opened a
-- hub battle with mode "wild". This screen uploads the player's party and the
-- wild sheets as side "b", and keeps `wildCatchMon` for a catch grant.
-- Does **not** divert overworld encounters — solo wild stays on the engine.
function M:beginWildMediated(game, battleId, opts)
  opts = opts or {}
  if not battleId then
    mod.log:warn("beginWildMediated needs a battle id from the hub")
    return false
  end
  local wildParty = opts.wildParty
  if type(wildParty) ~= "table" or #wildParty == 0 then
    if opts.mon then
      wildParty = MediatedBattle.snapshotMons(game, { opts.mon })
    end
  end
  if type(wildParty) ~= "table" or #wildParty == 0 then
    mod.log:warn("beginWildMediated needs a wild party sheet")
    return false
  end

  local fight = MediatedBattle.new({
    transport    = self.transport,
    ui           = self.ui,
    game         = game,
    battle       = battleId,
    role         = "host",
    peerName     = opts.peerName or "WILD",
    mode         = "wild",
    wildParty    = wildParty,
    wildCatchMon = opts.wildCatchMon or opts.mon,
    autoPick     = self.autoPick == true,
    onDone       = function() self:endMediated() end,
  })
  self.fight = fight
  fight:start(game)
  self.ui:pushState(game, fight)
  return true
end

-- The fight is off this screen.  Tell the hub, so the pairing does not sit
-- open until a grace runs out -- the record is already settled by the time an
-- outcome has been drawn, so this frees it rather than forfeiting anything.
function M:endMediated()
  local fight = self.fight
  self.fight = nil
  if not fight then return end
  self.transport:send(Wire.SESSION_LEAVE, {})
end

-- The three things an intermediator says during a fight.
--
-- Routed through the live fight and matched on its battle id, which is what
-- makes a message about somebody else's match inert: the id is checked inside
-- MediatedBattle against the one this client uploaded to.
function M:onBattleReady(msg)
  local ready = Wire.battleReady(msg)
  if ready and self.fight then self.fight:onReady(ready) end
end

function M:onBattleEvent(msg)
  local event = Wire.battleEvent(msg)
  if event and self.fight then self.fight:onEvent(event) end
end

function M:onBattleOutcome(msg)
  local outcome = Wire.battleOutcome(msg)
  if outcome and self.fight then self.fight:onOutcome(outcome) end
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
  self:closeWaitBox()

  -- A mediated fight does not end because the pairing did.  The peer leaving
  -- the field starts BATTLE_RECONNECT_GRACE on the intermediator, and what
  -- ends the battle is the outcome it sends when that grace expires -- or the
  -- reconnect event, if they come back.  So this narrates and waits: closing
  -- the screen here would take a fight away from a player who is about to be
  -- told they won it.
  local fight = self.fight
  if fight and not fight.finished then
    if reason == "peer_left" then
      fight:say(("%s disconnected."):format(fight.peerName))
    end
    return
  end

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

-- Every way out of a session, including the one Client.disconnect takes on the
-- way off a hub entirely.  A live fight is finished rather than dropped: the
-- screen is still on the stack and the player is still looking at it, so it
-- needs an ending it can be dismissed from.
function M:endSession(message)
  local session = self.active
  self.active = nil
  local fight = self.fight
  self.fight = nil
  if fight then fight:finish("draw", "disconnect") end
  if session then session.net:close() end
  if message then self.ui:say(message) end
end

-- ------- the handshake, then the handoff (trade only)

-- Whether a hello claims the lockstep surface was touched: an affects_link
-- mod, or a write into a link-surface registry.  Carried on the hello so we
-- do not have to re-derive it from the peer's mod list alone (a mod can set
-- affects_link false and still patch pokemon).
function M.linkSurfaceTouched(hello)
  return hello ~= nil and hello.linkModified == true
end

-- Cable-club battleAllowed, plus one MMO exception: fingerprints that differ
-- only because the imported games differ (Red vs Blue, two ROM dumps) while
-- neither side has touched the link surface.  Vanilla Gen 1 let those fight;
-- refusing them here blamed "mods" for a cartridge mismatch.  A side that
-- has actually changed battle rules still has to match.
--
-- **Nothing in this file calls it any more.**  From PROTOCOL 10 an MMO battle
-- is resolved by the intermediator off an uploaded chart and uploaded parties,
-- so there is no shared simulation left for two copies to disagree inside and
-- no verdict to gate on -- see the fork in M:onSession.  It survives as a
-- statement of the pairing rule, still asserted by the suite and still driven
-- against two real ROM extracts by tests/drivers/red_yellow_battle_compat.lua, and it
-- is what a cable-club link would consult if this mod ever brokered one again.
function M.canBattle(verdict, myHello, theirHello, Handshake)
  if not (Handshake and Handshake.battleAllowed) then return false end
  if Handshake.battleAllowed(verdict) then return true end
  if verdict == "subset"
      and not M.linkSurfaceTouched(myHello)
      and not M.linkSurfaceTouched(theirHello) then
    return true
  end
  return false
end

-- Why a battle was refused, naming the mods that differ when we can.
-- Handshake.describe already diffs the hello mod lists; we keep that and
-- add a clearer line when the lists match but one side still claims a
-- modified link surface (registry writes with affects_link left false).
function M.battleBlockMessage(myHello, theirHello, verdict, Handshake)
  local fallback = "Link battle needs\nthe same mods on\nboth games."
  if not (Handshake and Handshake.describe) then return fallback end
  local lines = Handshake.describe(myHello, theirHello, verdict, "battle")
  if Handshake.modDiff then
    local diff = Handshake.modDiff(myHello, theirHello)
    local named = #(diff.onlyMine or {}) + #(diff.onlyTheirs or {})
      + #(diff.differing or {})
    if named == 0 and (M.linkSurfaceTouched(myHello) or M.linkSurfaceTouched(theirHello)) then
      return "A mod changed\nbattle rules on\none game."
    end
  end
  if lines and #lines > 0 then return table.concat(lines, "\n") end
  return fallback
end

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

-- Only a trade reaches here now, and the hub is what guarantees it: a battle
-- session forks in M:onSession before a SessionNet is ever built, and both
-- intermediators refuse mmo.relay for one, so this hello has nowhere else it
-- could have come from.
function M:handleHandshake(game, session, msg, modules)
  if msg.type ~= "hello" then return end
  session.theirHello = msg
  local verdict = modules.Handshake.checkCompat(session.myHello, msg)
  session.verdict = verdict
  self:beginTrade(game, session, modules)
end

-- The battle this result belongs to, if the state that just ended is the one
-- this mod handed to the engine.  Answers once: a result is reported to the
-- hub exactly once, and a second call for the same battle gets nothing.
--
-- **Nothing sets `lastBattle` on the mediated path, so this now answers nil
-- for every MMO fight** -- and that is the mechanism rather than an accident.
-- src/Client.lua's reportBattle claims before it sends, so a battle with no
-- claim is a battle with no mmo.result, which is exactly the rule PROTOCOL 10
-- wants: the intermediator saw the fight and its mmo.battle_outcome is the
-- whole account of it.  Making that structural is better than remembering not
-- to send, because there is no second place to forget it in.  The field itself
-- stays -- a cable-club link handed to the engine would fill it again, and the
-- suite sets it directly to pin the claim-once rule.
function M:claimBattle(state)
  local last = self.lastBattle
  if not last then return nil end
  if state ~= nil and last.state ~= state then return nil end
  self.lastBattle = nil
  return last
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

-- Whether the hub is still there to referee.
--
-- Asked of the transport rather than of a session, because a mediated fight
-- has no SessionNet to watch die -- its messages go straight to the hub.
-- Answers true for a transport that cannot say, so a harness whose stub has no
-- isReady drives a fight rather than having it cut off at the first tick.
function M:linkAlive()
  local transport = self.transport
  if not (transport and transport.isReady) then return true end
  return transport:isReady() == true
end

-- Transport became ready again (welcome after a blip, or the suite calling
-- this directly). Resume a live mediated fight with mmo.battle_reconnect.
function M:onTransportReady()
  local fight = self.fight
  if fight and not fight.finished and fight.onTransportReady then
    return fight:onTransportReady()
  end
  return false
end

function M:update(game, dt)
  -- The mediated fight is driven by the engine's own state stack -- it is a
  -- screen, and screens get their update from up there -- so there is exactly
  -- one thing left to watch for it: the hub going away and coming back.
  -- Finishing on the drop would forfeit a fight the intermediator is holding
  -- open on BATTLE_RECONNECT_GRACE; narrating and waiting lets onTransportReady
  -- send mmo.battle_reconnect when the link returns.
  local fight = self.fight
  local alive = self:linkAlive()
  if fight and not fight.finished then
    if not alive then
      if fight.onTransportLost then fight:onTransportLost() end
    elseif self.linkWasDown then
      self:onTransportReady()
    end
  end
  self.linkWasDown = not alive

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

  for _, msg in ipairs(session.net:poll()) do
    if type(msg) == "table" and type(msg.type) == "string" then
      -- Read before the stage is consulted, because it can arrive in the
      -- same batch as the confirm that puts this side into "settling" --
      -- the peer sends both in that order and the hub forwards in order.
      if msg.type == APPLIED then
        session.peerApplied = true
      elseif session.stage == "handshake" then
        self:handleHandshake(game, session, msg, modules)
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
