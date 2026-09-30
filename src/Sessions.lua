-- Trade and battle between two players, anywhere in the world.
--
-- **The two kinds part company here, and have since PROTOCOL 10.**
--
-- A *trade* is still the engine's own machinery: Protocol.TradeSession is a
-- symmetric state machine -- the swap itself, the OT bookkeeping that marks a
-- mon as traded, all of it -- driven over a SessionNet whose payloads the hub
-- forwards unread.  So for a trade this module carries the request, runs the
-- engine's real hello/verdict handshake, hands the session to TradeSession,
-- and tears it down when either side leaves.
--
-- **One thing TradeSession decides but does not do: the trade evolution.**
-- `apply` answers what the received mon becomes and hands that back as its
-- second return; on the cable-club path src/link/LinkState.lua is what turns
-- the answer into a screen.  A hub trade has no LinkState, so this module is
-- that screen's opposite number -- see M:evolveTraded.  Reading the header
-- above as "TradeSession does evolutions too" is exactly the mistake that
-- left every MMO-traded MACHOKE a MACHOKE: the second return was dropped on
-- the floor here and nothing errored, on either side.
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
--
-- ------- three generations, three trade codecs, one machine
--
-- Gen 1 hands the session to the engine's Protocol.TradeSession, Gold to
-- src/Trade2.lua, FireRed / LeafGreen / Emerald to src/Trade3.lua.  All three
-- are the same stage machine over the same wire vocabulary, so everything
-- below beginTrade -- the picker, the confirm, the settle-then-leave teardown,
-- the save, the evolution -- is shared, and only asks the generation where
-- the answer is a different screen: Gen 3 has no game.stack (every screen is
-- a layer on src/ui/game3/stack.lua), no Evolution.evolve (the cart's own
-- EvolutionScene), no MoveLearnMenu (the cart's own LearnMove prompts) and no
-- game.writeSave (Game3:saveGame).  Each of those arms sits in front of the
-- Gen 1 / Gen 2 code it replaces and returns before that code runs, so a Red
-- or Gold session never reaches a Gen 3 module -- the loader throws on the
-- cross-generation require.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local SessionNet = need("SessionNet")
local MediatedBattle = need("MediatedBattle")
local Gen = need("Gen")
local Gen3 = need("Gen3")
local Trade2 = need("Trade2")
local Trade3 = need("Trade3")
local EvolveFx = need("EvolveFx")
local LearnMove = need("LearnMove")

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

-- REQUEST_TIMEOUT covers an ask that has gone out and never come back.
--
-- There is a human on the other end reading a yes/no box, so it is the most
-- generous of the three -- but it is not open-ended, and the reason is that
-- an ask with no clock is the one piece of state here that can strand a
-- player for the rest of a session.  `outgoing` makes this client busy, and
-- the hub answers a request pointed at somebody who has already left with
-- silence: nothing arrives, nothing clears it, and from then on every invite
-- *this* player receives is auto-refused while their own are turned away with
-- "You're already busy with someone."  Only the CANCEL row on the waiting box
-- could break it, and a box popped by a blackout or a save load takes that
-- escape with it.
--
-- Firing sends the ordinary cancel -- see M:cancelRequest -- so the asked
-- player's box is taken down with a sentence rather than left to be answered
-- into a hub that has already forgotten the ask.
local REQUEST_TIMEOUT = 120

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
  -- Gen 2 ui/gen2/BattleState: no kind; wild/trainer live on state.battle.
  -- Mirrored in Coop.isFightState -- same rule, two call sites.
  local battle = state.battle
  if type(battle) == "table" and (battle.wild or battle.trainer) then
    return true
  end
  return false
end

-- ------- Gen 3's screen stack
--
-- A Gen 3 boot has no game.stack.  Every screen -- the cart's menus and this
-- mod's alike -- is a layer on the modal stack src/ui/game3/stack.lua keeps
-- (Gen3.stack()), and a layer is the record Stack.push builds, { id, mod, ...
-- }, around the table that was pushed.  src/Gen3Ui.lua pushes the screen
-- itself as `mod` under a unique "rby_mmo:<Screen>#n" id, and src/Ui.lua's
-- doors (Ui.holds / Ui.unwindTo / Ui.pop) answer from there on a Gen 3 boot --
-- so those doors are what this file asks, through `self.ui`, whenever it
-- carries them.
--
-- The engine stack is read directly only where there is no ui to ask (the
-- static fight check) and for a ui without the doors (a headless harness's
-- stub): then a held box is looked for as the layer, the table in it, its
-- layer id, or the `screen` / `state` a wrapper layer keeps, and a layer is
-- taken down the way Gen3Ui.pop takes it -- removed, then its optional
-- `exit`, which only this mod's own layers are given.
--
-- Asked only of a game with no `stack` of its own on a Gen 3 boot: a Gen 1
-- or Gen 2 game, and every harness that hands one in, takes the old path
-- untouched.  Reads the engine's `_layers` directly because Stack has no
-- iterator, and "is this box anywhere on the stack" is the question.
local LAYER_PREFIX = Config.GEN3_LAYER_PREFIX or "rby_mmo:"

local function stack3(game)
  if type(game) == "table" and game.stack ~= nil then return nil end
  if not Gen3.active() then return nil end
  local Stack = Gen3.stack()
  if type(Stack) == "table" and type(Stack._layers) == "table" then return Stack end
  return nil
end

local function layerHolds(layer, target)
  if target == nil or type(layer) ~= "table" then return false end
  if layer == target or layer.mod == target or layer.id == target then return true end
  local inner = layer.mod
  return type(inner) == "table" and (inner.screen == target or inner.state == target)
end

local function layerIndex3(Stack, target)
  local layers = Stack._layers
  for i = #layers, 1, -1 do
    if layerHolds(layers[i], target) then return i end
  end
  return nil
end

-- Take the top layer down the way Gen3Ui.pop (and StateStack:pop on Gen 1)
-- takes one down: removed first, then its optional `exit` -- for this mod's
-- own layers only, since a cart layer's module is not a screen object.
local function popTop3(Stack)
  local layers = Stack._layers
  local top = layers[#layers]
  if not top then return false end
  pcall(Stack.pop)
  local inner = top.mod
  local exit = type(inner) == "table" and inner.exit
  if type(exit) == "function" and type(top.id) == "string"
      and top.id:sub(1, #LAYER_PREFIX) == LAYER_PREFIX then
    pcall(exit, inner)
  end
  return true
end

-- One of src/Ui.lua's stack doors (a module function, reached through the Ui
-- instance's metatable), or nil when this ui has none.
local function uiDoor(self, name)
  local ui = type(self) == "table" and self.ui or nil
  local door = type(ui) == "table" and ui[name] or nil
  if type(door) == "function" then return door end
  return nil
end

-- ------- prompts that wait for the player
--
-- src/Ui.lua's Ui.occupied / Ui:whenFree.  On Gen 3 a prompt this module
-- raises unasked -- somebody's request, the answer to an ask the player made
-- and walked away from, a trade screen opening on the far side's accept --
-- waits while the cart is using the screen (its BAG, START, the dex, an
-- NPC's sentence ...) instead of going up through it, and appears the moment
-- the player is free.  A ui without them (every harness stub), and Gen 1 /
-- Gen 2 (where Ui.occupied is always false), show it at once, as before.
local function gameOf(self, game)
  if game ~= nil then return game end
  local ctx = type(self.ui) == "table" and self.ui.ctx or nil
  return type(ctx) == "table" and ctx.game or nil
end

function M:occupied(game)
  local door = uiDoor(self, "occupied")
  if not door then return false end
  local ok, busy = pcall(door, gameOf(self, game))
  return ok and busy == true
end

local function whenFree(self, game, show, opts)
  local ui = self.ui
  if type(ui) == "table" and type(ui.whenFree) == "function" then
    return ui:whenFree(gameOf(self, game), show, opts)
  end
  return show()
end

-- A sentence for the player, put up when they are free to read it.  onDone
-- runs when it is dismissed -- or at once when no box could go up at all, so
-- a continuation hung on it (the trade evolution) is never stranded.  Only a
-- line with nothing behind it is filed under this module (Ui:whenFree's
-- owner), so M:onTransportReady can take the stale ones back without ever
-- taking a continuation with them.
function M:tell(game, text, onDone)
  local ui = self.ui
  return whenFree(self, game, function()
    local box = ui:say(text, onDone)
    if not box and onDone then onDone() end
    return box
  end, onDone == nil and { owner = self } or nil)
end

local function unwind3(Stack, target, alsoPop)
  local index = layerIndex3(Stack, target)
  if not index then return false end
  local guard = 0
  while #Stack._layers > index and guard < 16 do
    popTop3(Stack)
    guard = guard + 1
  end
  local layers = Stack._layers
  if alsoPop and #layers == index and layerHolds(layers[index], target) then
    popTop3(Stack)
  end
  return true
end

-- A Gen 3 layer that is a fight: the table pushed, or the state a wrapper
-- layer carries, read by the same isFightState rule.
local function layerFight(layer)
  if type(layer) ~= "table" then return false end
  local inner = layer.mod
  if M.isFightState(inner) then return true end
  return type(inner) == "table"
    and (M.isFightState(inner.state) or M.isFightState(inner.screen))
end

function M.stackHasFight(game)
  local stack = game and game.stack
  if not stack then
    -- Gen 3: the cart's own battle runs inside the field phase rather than
    -- on the stack, so it is asked of the battle module; this mod's fights
    -- are layers.
    local Stack = stack3(game)
    if not Stack then return false end
    if Gen3.inBattle() then return true end
    local layers = Stack._layers
    for i = #layers, 1, -1 do
      if layerFight(layers[i]) then return true end
    end
    return false
  end
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

-- **Why an invite arriving right now could not be put to this player**, or
-- nil when it could.  One statement of "busy", read from two places that
-- used to disagree:
--
--   * M:onRequest, which refuses on it, and
--   * Client's presence push, which is what everybody else's roster row --
--     and so the decision to ask at all -- is drawn from.
--
-- They *did* disagree, and that disagreement is the whole bug this exists to
-- close.  Presence carried isBusy alone (a hub session), so a player in an
-- ordinary wild or trainer fight was published as free, asked, and refused
-- in the same breath -- with nothing on either screen to say why.  A refusal
-- the asker could have seen coming is a refusal nobody has to send.
--
-- Ordered cheap-first because presence asks this on every tick: four field
-- reads answer it for a player standing in a field, and only a player who is
-- otherwise idle pays for the stack walk.
function M:busyReason(game)
  if self.fight then return "fighting" end
  if self.active or self.outgoing then return "busy" end
  if self.incoming then return "asked" end
  if self:inFight(game) then return "fighting" end
  return nil
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
  if not stack and target ~= nil then
    local Stack = stack3(game)
    if Stack then
      local holds = uiDoor(self, "holds")
      if holds then
        local ok, held = pcall(holds, game, target)
        if ok and held then return true end
      end
      return layerIndex3(Stack, target) ~= nil
    end
  end
  if not (states and target) then return nil end
  for i = #states, 1, -1 do
    if states[i] == target then return true end
  end
  return false
end

function M:unwindTo(game, target, alsoPop)
  local stack = game and game.stack
  if not stack and target ~= nil then
    local Stack = stack3(game)
    if Stack then
      local unwind = uiDoor(self, "unwindTo")
      if unwind then
        local ok, done = pcall(unwind, game, target, alsoPop)
        if ok and done then return true end
      end
      return unwind3(Stack, target, alsoPop)
    end
  end
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
  --
  -- The refusal carries *why*, so the asker reads "BOB is in a battle."
  -- rather than the flat "BOB refused to battle." a person pressing NO
  -- earns.  And it is said in the corner on this side too: an invite that
  -- was answered on the player's behalf, with nothing on screen at any
  -- point, is the one refusal neither player could diagnose.
  local reason = self:busyReason(game)
  if reason then
    self.transport:send(Wire.RESPOND,
      { to = from, kind = kind, accept = false, reason = reason })
    self:sayRefused(name, kind)
    return
  end

  -- Free but looking at the cart's own screen (Gen 3: the BAG, START, an
  -- NPC's sentence -- Ui.occupied) is not busy: the ask is held, not refused,
  -- and put to the player the moment they close what they have open.  It is
  -- marked `deferred` until then, which is what M:onCancel and
  -- waitOutRequest read: an ask withdrawn or run out before it was ever seen
  -- goes without a box.  While it waits this side still reads as "asked" to
  -- everybody else, exactly as it would with the box up.
  local incoming = { from = from, name = name, kind = kind, deferred = true }
  self.incoming = incoming
  whenFree(self, game, function()
    if self.incoming ~= incoming then return nil end
    incoming.deferred = nil
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
    return box
  end, { alive = function() return self.incoming == incoming end, owner = self })
end

-- The corner line an auto-refusal leaves on the *refusing* player's screen.
--
-- A toast rather than a box, and the choice is the whole point of the seam:
-- this fires while the player is mid-fight or mid-trade, and a modal there is
-- exactly the interruption onRequest refuses the invite to avoid.  The corner
-- is the one surface that can speak without being asked to (see Toast's
-- header), so it is the only place this line could go.
--
-- Wired by Client, absent in a headless build, and silent when it is: an
-- invite is still refused correctly with nobody to tell.
function M:sayRefused(name, kind)
  if not self.toast then return end
  self.toast(("%s asked to %s"):format(name,
    kind == "trade" and "trade" or "battle"))
end

-- What a refusal reads as, given the reason the far side sent with it.
--
-- Pure and named so the suite can pin every sentence without standing up a
-- hub -- and so the two kinds pick their wording in one place rather than at
-- each call site.  An unknown or absent reason falls through to the flat
-- sentence, which is the honest one for the case it describes: a person read
-- the box and said no.
function M.declineText(name, kind, reason)
  local battle = kind ~= "trade"
  if reason == "fighting" then
    return ("%s is in\na battle."):format(name)
  elseif reason == "busy" then
    return ("%s is busy\nright now."):format(name)
  elseif reason == "asked" then
    return ("%s is answering\nsomeone else."):format(name)
  elseif reason == "gone" then
    return ("%s has left\nthe game."):format(name)
  end
  if battle then return ("%s refused\nto battle."):format(name) end
  return ("%s said no."):format(name)
end

function M:onDecline(msg)
  local outgoing = self.outgoing
  local name = Wire.name(msg.name) or (outgoing and outgoing.name) or "They"
  local kind = outgoing and outgoing.kind
  self.outgoing = nil
  self:closeWaitBox()
  self:tell(nil, M.declineText(name, kind, Wire.declineReason(msg.reason)))
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
  if pending.deferred then
    -- Never on screen (the player was in the cart's own menus the whole
    -- time), so there is no box to take down and no "cancelled" to explain:
    -- the queued prompt drops itself (its alive check is this field), and
    -- the corner says who asked, as it does for an ask refused while busy.
    self:sayRefused(pending.name, pending.kind)
    return
  end
  self:closeIncomingBox()
  self:tell(nil, ("%s cancelled\nthe invite."):format(name))
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
    self:tell(nil, ("%s went\noffline."):format(name))
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

-- True when this pairing is already the screen: a duplicate SESSION for
-- the same battle must not re-push or leave, finished or not.
function M:sameFight(battleId)
  local fight = self.fight
  return fight ~= nil and battleId ~= nil and fight.battle == battleId
end

-- Take the current screen off `self.fight` without talking to the hub.
--
-- SESSION_LEAVE would end whichever pairing the hub currently has -- and
-- after a new onSession that is the fight we are about to join, not the
-- discarded one. onDone is cleared and `left` is set first so a later pop
-- of a buried screen cannot endMediated the replacement (offerForgets
-- would run under the new fight).
function M:dropLocalFight()
  local fight = self.fight
  self.fight = nil
  if not fight then return end
  fight.onDone = nil
  if not fight.finished and fight.finish then
    fight:finish("draw", "gone")
  end
  fight.left = true
  local stack = fight.game and fight.game.stack
  if stack and type(stack.pop) == "function" then
    local top = stack.top and stack:top()
    if top == fight then
      pcall(function() stack:pop() end)
    end
  elseif not stack then
    local Stack = stack3(fight.game)
    local layers = Stack and Stack._layers
    if layers and layerHolds(layers[#layers], fight) then
      local pop = uiDoor(self, "pop")
      local ok, popped = false, false
      if pop then ok, popped = pcall(pop, fight.game, fight) end
      if not (ok and popped) then popTop3(Stack) end
    end
  end
end

-- Put up the fight and upload what we are bringing.
--
-- The upload happens *here* rather than only in the screen's `enter`, and the
-- ordering is load-bearing: it is what lets the fight be driven with no state
-- stack at all -- the headless suite, and any build whose UI failed to come
-- up.  MediatedBattle:start is idempotent, so `enter` doing it again is free.
function M:beginMediated(game, sessionId, peerId, peerName, role)
  if self:sameFight(sessionId) then return true end
  if self.fight then
    -- The hub already moved client.battleId before sending SESSION. Keep
    -- and SESSION_LEAVE would leave the new pairing and keep a screen
    -- whose choices the hub no longer routes. Unnamed has nothing to
    -- follow, so that stays on the live screen.
    if not sessionId then
      mod.log:warn("beginMediated while a mediated fight is still on screen "
        .. "-- keeping the one on screen; finish or leave that fight first, "
        .. "and report this if a second pairing keeps arriving")
      return false
    end
    mod.log:warn("beginMediated while a mediated fight is still on screen "
      .. "-- dropping it to follow the pairing the hub already opened; "
      .. "report this if a second pairing keeps arriving")
    self:dropLocalFight()
  end
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
    -- The second argument is the list of moves this fight levelled into with
    -- no slot free -- see M:offerForgets, which is where they are put to the
    -- player once the screen is off the stack.
    onDone    = function(_, toLearn) self:endMediated(game, toLearn) end,
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
  if self:sameFight(battleId) then return true end
  -- Occupancy is still the live fight: this caller did not just receive a
  -- SESSION that moved battleId. Leaving would pause or forfeit the screen
  -- the player is looking at.
  if self.fight then
    mod.log:warn("beginWildMediated while a mediated fight is still on "
      .. "screen -- keeping the one on screen; finish or leave that fight "
      .. "first, and report this if a second pairing keeps arriving")
    return false
  end
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
    -- Same on the wild path, and it is the one that reaches this most often:
    -- a wild fight is where a mediated party earns its levels today, and a
    -- catch landing in the same ending does not change what was learned.
    onDone       = function(_, toLearn) self:endMediated(game, toLearn) end,
  })
  self.fight = fight
  fight:start(game)
  self.ui:pushState(game, fight)
  return true
end

-- The fight is off this screen.  Tell the hub, so the pairing does not sit
-- open until a grace runs out -- the record is already settled by the time an
-- outcome has been drawn, so this frees it rather than forfeiting anything.
--
-- `toLearn` is whatever the fight banked but could not fit (MediatedBattle's
-- `teach`).  The hub hears first and the player second: the leave is a fact
-- about a fight that is already over, and the prompt below can sit on screen
-- for as long as somebody takes to answer it.
--
-- On Gen 3 the evolutions wait for the last learn to be answered.  Both are
-- the cart's own exchanges -- LearnMove.begin's prompts, and EvolutionScene,
-- which runs LearnMove.begin again for the evolved species before it closes
-- -- and starting the scene while a learn is still on screen ran the two
-- through the same engine module at once: callbacks lost, learns dropped.
-- The cart itself never overlaps them (after a battle it teaches, then
-- evolves).  Gen 1 and Gen 2 keep their order: both offers at once, as
-- before -- their screens stack.
function M:endMediated(game, toLearn)
  local fight = self.fight
  self.fight = nil
  if fight then self.transport:send(Wire.SESSION_LEAVE, {}) end
  game = game or (fight and fight.game)
  -- Forgets first, then the #65 fallback: same order Coop.onBattleOver uses.
  -- The fight is already off `self.fight`, so the sets have to be read off
  -- the snapshot -- a mid-movie snapDisplay abandoned apply and left
  -- leveledUp for this offer; evoResolved subtracts a prompt the player
  -- already answered on the arena.
  local function evolutions()
    if not fight then return end
    EvolveFx.offerEvolutions(game, fight.leveledUp, fight.result, fight.evoResolved, {
      warn = function(fmt, ...) mod.log:warn(fmt, ...) end,
      ui = (self.ui and self.ui.push and self.ui) or mod.ui,
    })
  end
  if Gen.generation(game) == 3 then
    if not self:offerForgets(game, toLearn, evolutions) then evolutions() end
    return
  end
  self:offerForgets(game, toLearn)
  evolutions()
end

-- Moves a monster levelled into during a mediated fight but had no room for.
--
-- **Coop:offerForgets' twin, and deliberately a twin rather than a call into
-- it.** The two live on different paths -- a 1v1 or a wild mediated fight is
-- not a co-op battle and has no co-op state -- and reaching across for the
-- method would make this module depend on the whole of Coop for a screen
-- push, on the same module graph whose resolver refuses a cycle. The shape
-- of the list is the contract they share (`{ mon = <save party mon>, move =
-- <move id> }`), and it is the same shape because both fights build it the
-- same way.
--
-- The mon in each entry is the **save party** monster `Experience.apply`
-- already levelled, not the uploaded sheet -- so the moveset the menu edits
-- is the one the save keeps, and a catch landing in the same ending (which
-- appends to that same party) cannot move it: the entry holds the table
-- itself, never an index into the party.
--
-- Put to the player *after* the battle, one screen at a time. The engine's
-- own MoveLearnMenu is pushed rather than a copy of it, and it is handed a
-- completion callback -- the fourth argument Evolution.lua passes -- which
-- fires on both answers: after "learned" and after "did not learn". That is
-- what sequences two pending learns without stacking two menus, and what
-- makes declining cost nothing but the next prompt.
--
-- `onAllDone` (Gen 3 only; see M:endMediated) runs once, after the last
-- entry has been answered.  False, and onAllDone never called, when there is
-- nothing to offer -- the caller carries on itself.
function M:offerForgets(game, toLearn, onAllDone)
  game = game or (self.ui and self.ui.ctx and self.ui.ctx.game)
  if not (game and type(toLearn) == "table" and #toLearn > 0) then return false end

  -- Copied, because the list belongs to a screen that is being torn down.
  local pending = {}
  for i = 1, #toLearn do pending[i] = toLearn[i] end
  local gen3 = Gen.generation(game) == 3
  local finished = false

  local nextOne
  nextOne = function()
    local entry = table.remove(pending, 1)
    while entry ~= nil and not (type(entry) == "table"
      and type(entry.mon) == "table" and entry.move ~= nil) do
      -- A malformed entry is skipped rather than opening a menu with nothing
      -- in it; the rest of the list is still owed to the player.
      entry = table.remove(pending, 1)
    end
    if entry == nil then
      if gen3 and not finished then
        finished = true
        if onAllDone then onAllDone() end
      end
      return
    end

    -- Gen 3 has no MoveLearnMenu to push: the cart's own exchange runs
    -- through src/LearnMove.lua's Gen 3 arm (LearnMove.begin, handed this
    -- mod's boxes on the game3 stack and the summary screen's move picker,
    -- in the field's wording -- the fight is already over) and calls back
    -- once on both answers, which sequences the queue exactly as the Gen 1
    -- screen's callback does.  Its boxes are this mod's own layers, not the
    -- engine's Message / Choice singletons an evolution scene also drives.
    if gen3 then
      if LearnMove.open(game, entry.mon, entry.move, function() nextOne() end,
          { ui = self.ui, battle = false }) then
        return
      end
      mod.log:warn("could not open the move-learning prompt for move %s; it "
        .. "can still be learned by levelling again", tostring(entry.move))
      return nextOne()
    end

    local pushed
    local ok = pcall(function()
      pushed = mod.ui.push(game, "MoveLearnMenu", entry.mon, entry.move,
        function() nextOne() end)
    end)
    -- A screen went up: it owns the rest of the queue now, through the
    -- callback above. A pcall that *succeeds* but hands back nothing
    -- table-shaped (an unregistered screen id resolves to nil) is just as
    -- screen-less as a throw, so both take the remediation branch below.
    if ok and type(pushed) == "table" then return end

    do
      -- Auto-fill a free slot when the forget UI is missing; otherwise warn,
      -- because the level is banked either way and the move can still be had
      -- by levelling again outside the MMO.
      local mon = entry.mon
      local moved = false
      if type(mon.moves) == "table" and #mon.moves < 4 then
        local mdef = game.data and game.data.moves and game.data.moves[entry.move]
        mon.moves[#mon.moves + 1] = { id = entry.move, pp = (mdef and mdef.pp) or 5 }
        moved = true
        self.ui:say((mon.nickname or mon.species or "POKéMON")
          .. " learned\n" .. tostring(entry.move) .. "!")
      end
      if not moved then
        mod.log:warn("could not open the move-learning screen for %s; it can "
          .. "still be learned by levelling again", tostring(entry.move))
      end
    end
    -- Nothing is on screen to call back -- a build with no UI at all, or a
    -- push that threw -- so the queue is carried on here rather than being
    -- stranded one entry in.
    nextOne()
  end

  nextOne()
  return true
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

-- Read in this boot's own vocabulary (Wire.battleEvent's `generation`): Gen 1
-- and Gen 2 exactly as their stream always read, Gen 3 the union with its own
-- fields.  With no fight there is nothing to read it for.
function M:onBattleEvent(msg)
  local fight = self.fight
  if not fight then return end
  local event = Wire.battleEvent(msg, Gen.generation(gameOf(self, fight.game)))
  if event then fight:onEvent(event) end
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
    self:tell(nil, ("%s disconnected."):format(session.peerName))
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
  if session then
    -- a Gen 3 trade's "Waiting for NAME..." (M:holdTrade) goes with it
    self:releaseHold(session)
    session.net:close()
  end
  if message then self:tell(nil, message) end
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
  local opts = {
    subset = session.verdict == "subset",
    strict = modules.Handshake.strict(session.verdict),
    peerName = session.peerName,
  }
  -- Gen 2: MMO-owned Trade2 over packMon2 + party mail. Gen 1 keeps the
  -- engine TradeSession path byte-for-behaviour. Capability-tested so an
  -- older engine without packMon2 refuses clearly instead of packing Gen 1
  -- shapes into a Gold party.
  --
  -- Gen 3: Trade3 over packMon3 / unpackMon3, the same capability rule --
  -- a build without the Gen 3 codec must not fall through to the Gen 1
  -- one, which would pack a FireRed party as Red mons.
  local generation = Gen.generation(game)
  if generation == 3 then
    if not (Trade3 and Trade3.capable and Trade3.capable()) then
      mod.log:warn("Gen 3 trade needs Protocol.packMon3 and unpackMon3 on "
        .. "this engine -- update gen1recomp (dev branch)")
      return self:endSession("You can't trade\non this build.")
    end
    session.trade = Trade3.TradeSession.new(game, opts)
  elseif generation == 2 then
    if not (Trade2 and Trade2.capable and Trade2.capable()) then
      mod.log:warn("Gen 2 trade needs Protocol.packMon2 and unpackMon2 on "
        .. "this engine -- update gen1recomp (dev branch) or trade on Gen 1")
      return self:endSession("You can't trade\non this build.")
    end
    session.trade = Trade2.TradeSession.new(game, opts)
  else
    session.trade = modules.Protocol.TradeSession.new(
      game.data, game.save.party, opts)
  end
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

local function generationOf3(game)
  return Gen.generation(game) == 3
end

-- The Gen 3 session running now: the game's own (Game3 replaces the table on
-- a CONTINUE and clears it at the title), else the runtime's.
local function currentSession3(game)
  local s = type(game) == "table" and game.session or nil
  if type(s) == "table" then return s end
  return Gen3.session()
end

-- ------- the trade holds the screen (Gen 3)
--
-- From the pick until the swap is saved, a layer of this mod's own stays up
-- -- "Waiting for NAME...", src/Ui.lua's Ui:holdScreen -- and with it up the
-- cart's field and START are frozen.  The cart's own trade screen owns the
-- screen for the whole exchange the same way; here it matters because the
-- peer files the party it was *shown*, so a mon moved or a held item taken
-- off after the pick is one the peer would receive while this save still had
-- it (src/Trade3.lua's header).  The confirm goes up over it.  It comes down
-- at "done", once the swap is on the cartridge, or with the session, however
-- that ends.  A ui without holdScreen (Gen 1 / Gen 2 -- whose pick never
-- waited for the cart's menus -- and every harness stub) holds nothing.
function M:holdTrade(game, session)
  if not session or session.hold or self.active ~= session then return false end
  if session.stage ~= "trade" then return false end
  local ui = self.ui
  if not (type(ui) == "table" and type(ui.holdScreen) == "function") then return false end
  if Gen.generation(game) ~= 3 then return false end
  local ok, box = pcall(ui.holdScreen, ui, game,
    ("Waiting for\n%s..."):format(tostring(session.peerName or "them")))
  if not (ok and type(box) == "table") then return false end
  session.hold = { box = box, game = game }
  return true
end

function M:releaseHold(session)
  local held = session and session.hold
  if not held then return false end
  session.hold = nil
  local pop = uiDoor(self, "pop")
  if not pop then return false end
  local ok, popped = pcall(pop, held.game, held.box)
  return ok and popped == true
end

-- Drives the trade UI from the state machine's stage rather than from the
-- messages, so the prompt shown always matches what the machine will accept.
function M:advanceTrade(game, session)
  local trade = session.trade
  if not trade then return end

  if trade.stage == "picking" and not session.pickOpen then
    -- The far side's accept can land while this player has the cart's own
    -- BAG or START open (Gen 3; Ui.occupied): the picker waits for them to
    -- close it, asked again every tick, rather than going up through it.  A
    -- human is choosing either way, and this stage has no clock.
    if self:occupied(game) then return end
    session.pickOpen = true
    self.ui:pickPartyMon(game, trade, function(index)
      session.pickOpen = false
      if not index then
        session.net:send({ type = "bye" })
        return self:endSession("The trade was\ncancelled.")
      end
      -- A Gen 3 cart refuses some offers outright -- the last mon able to
      -- battle, a mon or an egg this save or the partner's cannot trade yet
      -- (Trade3:refusal).  The picker greys those rows, and this is the
      -- belt for one that got through: the cart's sentence, then the picker
      -- again once it has been read.  Gen 1 / Gen 2 machines have no
      -- `refusal`, so they never reach it.
      local why = trade.refusal and trade:refusal(index)
      if why then
        session.pickOpen = true
        if not self.ui:say(why, function() session.pickOpen = false end) then
          session.pickOpen = false
        end
        return
      end
      -- Gen 3: a pick of a mon the peer was never shown (the party changed
      -- while the picker waited) answers a bye and cancels -- see Trade3.
      session.net:send(trade:pick(index))
      if trade.stage ~= "cancelled" then self:holdTrade(game, session) end
    end)

  -- myConfirm, not just the box flag: the machine sits in "confirming" from
  -- the moment this side answers until the peer's answer arrives, so a test
  -- on the stage alone re-opened the box the instant the player closed it
  -- and asked them to agree to the same trade over and over.
  elseif trade.stage == "confirming" and trade.myConfirm == nil
         and not session.confirmOpen then
    -- Gen 3: an offer this cart cannot take (Trade3:theirRefusal -- an
    -- event-only MEW / DEOXYS that is not, or a mon this save may not
    -- receive before the National Dex) is not put to the player as a yes /
    -- no.  The cart answers it: the no goes out, the peer is let go, and the
    -- cart's own sentence says why.  Nothing was applied on either side --
    -- neither reached "done".
    local refused = trade.theirRefusal and trade:theirRefusal()
    if refused then
      session.net:send(trade:confirm(false))
      session.net:send({ type = "bye" })
      return self:endSession("The trade stopped:\n" .. refused)
    end
    -- Same wait as the picker's: their pick can arrive while the player is in
    -- the cart's menus.  Nothing is on the wire from this side yet, so no
    -- clock runs against the wait (waitOut's CONFIRM_TIMEOUT starts at our
    -- own answer); the far side's own timeout is what bounds it.
    if self:occupied(game) then return end
    session.confirmOpen = true
    local theirs = trade.theirParty and trade.theirParty[trade.theirPick]
    local label = theirs and tostring(theirs.species) or "their POKéMON"
    -- Gen 3 species are numbers; the cart names a mon by its nickname.
    if theirs and trade.labelOf then label = trade:labelOf(theirs) end
    self.ui:confirm(game, ("Trade for\n%s?"):format(label), function(yes)
      session.confirmOpen = false
      session.net:send(trade:confirm(yes and true or false))
    end)

  elseif trade.stage == "done" and not session.applied then
    session.applied = true
    -- The slot the received mon lands in, read before apply so the evolution
    -- below writes back into the party position the swap actually used
    -- rather than searching for the record afterwards.
    local slot = trade.myPick
    local ok, received, evolveTo, evoEntry =
      pcall(function() return trade:apply(game) end)
    -- An apply that answered nothing applied nothing (Trade2 and Trade3 warn
    -- and return nil; Gen 1's raises instead), so it is the failure branch
    -- below, not a "traded over!" about a mon that never arrived.
    local raised = not ok
    if ok and received == nil then ok = false end
    -- Trade3 found the mon it sent by identity; the received one is there.
    if trade.appliedSlot then slot = trade.appliedSlot end
    -- The session this trade wrote into (Gen 3): the evolution below is
    -- about that save and no other -- see `evolve`.
    local owner = generationOf3(game) and trade.session or nil

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
      -- On the cartridge before anything is drawn -- see M:saveTrade.  First,
      -- and ahead of the box: the swap is already in game.save.party, and
      -- every frame it is only there is a frame a force-quit can undo it in.
      self:saveTrade(game)
      -- The exchange is over and on disk: the screen goes back to the player
      -- (the line below goes up in the hold's place).
      self:releaseHold(session)

      local name = received and tostring(received.species) or "a POKéMON"
      if received and trade.labelOf then name = trade:labelOf(received) end
      -- The evolution follows the line, never sits under it: the cable club
      -- prints "Trade completed!" and only then flashes the mon, and a movie
      -- opening on top of a box the player is still reading would bury it.
      --
      -- Runs immediately when nothing was pushed to wait on -- a build with
      -- no UI, or a harness whose `say` is a stub -- because the trade is
      -- committed on both sides by now and there is no second chance at it.
      -- The guard is what keeps a stub that *both* calls back and returns
      -- nothing from evolving the same mon twice.
      --
      -- On Gen 3 the line can wait (M:tell, the cart's menus), and a player
      -- can reset to the title and load another save while it does.  The
      -- evolution -- and the save it ends in -- belongs to the save the swap
      -- was made in: under any other it would evolve a mon that is not in
      -- the party and then write *that* save over this one.
      local evolved = false
      local function evolve()
        if evolved then return end
        evolved = true
        if owner ~= nil and currentSession3(game) ~= owner then
          mod.log:warn("a different save was loaded before %s could evolve "
            .. "after the trade, so it did not -- the trade itself was saved; "
            .. "trade it again to give the evolution another chance",
            tostring(Trade3.displayName(received)))
          return
        end
        self:evolveTraded(game, received, evolveTo, evoEntry, slot)
      end
      -- Through M:tell, so a player who opened the BAG while waiting on the
      -- far side's confirm reads it once they close the BAG rather than
      -- through it -- and tell runs `evolve` at once when no box could go up.
      self:tell(game, ("%s was\ntraded over!"):format(name), evolve)
    else
      self:releaseHold(session)
      -- The peer has our confirm and will apply regardless, so there is no
      -- undo to offer; what there is, is a way to see what actually landed.
      -- (A nil answer already said why in its own warning.)
      if raised then
        mod.log:warn("applying the finished trade raised (%s) -- check the "
          .. "party from START > POKéMON before trading again", tostring(received))
      end
      self:tell(game, "The trade failed\nto complete.")
    end

  elseif trade.stage == "cancelled" and not session.applied then
    session.applied = true
    self:endSession(trade.error and ("The trade stopped:\n" .. trade.error)
      or "The trade was\ncancelled.")
  end
end

-- ------- committing the trade to disk

-- The swap, on the cartridge, the moment it happens -- and again once the
-- evolution that followed it has settled.
--
-- Both saves are the cable club's (src/link/LinkState.lua's "done" branch,
-- gen1recomp #222): pokered's engine/link/cable_club.asm calls SaveSAVtoSRAM
-- straight after every trade, so the trade is committed before the animation
-- runs, and the second write is what keeps the *evolved* species on disk
-- rather than the pre-evo `apply` landed.  Without them the received mon
-- lives only in memory until the player happens to open START > SAVE: a
-- force-quit loses it outright, and a reset gives back the one that was
-- traded away -- so the pair of them are now two copies of the same mon in
-- the world, which is the duplication this session's whole teardown exists
-- to prevent, arriving by the back door.
--
-- **A hub trade holds that window open longer than a cable trade does.**
-- Finishing locally is deliberately not what ends the session here: this
-- side sits in "settling" for as long as SETTLE_TIMEOUT while the peer
-- acknowledges, and the player is free to walk away, be dropped, or quit
-- during it.
--
-- Guarded and pcall'd rather than called flat.  A build with no writeSave --
-- the headless suites, the LinkBattle-shaped fake games the engine's own
-- call site names -- is not a failure, and a save that throws must not take
-- the trade down with it: the swap has happened in memory either way, and
-- the honest thing to do is say so and name the way out.  `false` is a
-- refusal rather than a throw (src/script/Commands.lua reads it that way for
-- a tool session that vetoes writes) and is reported the same.
--
-- Gen 3's writer is Game3:saveGame -- START > SAVE's own path, which also
-- persists the live flag store and the FRLG quest log before it writes, and
-- which the engine's own Gen 3 link trade runs after every trade as well
-- (src/core/game3/link/trade.lua saveAfterTrade).  It answers nil when the
-- phase has nothing to save, which reads as written, as on the other two.
function M:saveTrade(game)
  if type(game) ~= "table" then return false end
  local write = game.writeSave
  if type(write) ~= "function" and type(game.saveGame) == "function"
      and Gen.generation(game) == 3 then
    write = game.saveGame
  end
  if type(write) ~= "function" then return false end
  local ok, wrote = pcall(write, game)
  if ok and wrote ~= false then return true end
  mod.log:warn("could not save after the trade (%s) -- the POKéMON is in "
    .. "the party, but save from START > SAVE before quitting or it will "
    .. "not be there next time",
    ok and "the game refused the write" or tostring(wrote))
  return false
end

-- ------- trade evolutions

-- KADABRA into ALAKAZAM, on the side that just received it.
--
-- Both TradeSessions answer *whether* a received mon evolves and stop there
-- (src/link/Protocol.lua's `evolveTo`, src/Trade2.lua's row) -- turning that
-- answer into a screen has always been the caller's job, and on the cable
-- club the caller is src/link/LinkState.lua.  This is the hub trade's half
-- of that, and until it existed the answer went nowhere.
--
-- Two games, two screens, one shape:
--
--   * **Gen 1** goes through `Evolution.evolve`, which owns the
--     EvolutionState push, and is handed via="TRADE" so B cannot cancel it
--     (pokered skips the flash B-poll under LINK_STATE_TRADING, #213).
--   * **Gold** has no link trade of its own, so this pushes the engine's
--     Gen2EvolutionAnim the way src/core/Game2.lua's afterRareCandy does --
--     including the pop, because that screen reports through `onDone` and
--     leaves the stack to whoever pushed it.  B is left working there: the
--     engine's screen only refuses a cancel for `force` (a stone), and
--     inventing a second rule for it here is not this module's call.
--
-- Nothing raises: a missing module, an unregistered screen or a push that
-- throws all fall through to applying the evolution outright, because the
-- trade is committed on both sides by the time this runs and a mon left as
-- the wrong species is permanent -- there is no second chance at a trade
-- evolution.  The player is told what they missed rather than what broke.
function M:evolveTraded(game, mon, evolveTo, entry, slot)
  if not (game and type(mon) == "table" and evolveTo) then return false end

  local generation = Gen.generation(game)
  if generation == 3 then return self:evolveTraded3(game, mon, evolveTo) end
  local isGen2 = generation == 2
  local ok, Evolution = pcall(require,
    isGen2 and "src.core.gen2.Evolution" or "src.pokemon.Evolution")
  if not (ok and type(Evolution) == "table") then
    mod.log:warn("the engine's evolution module is unavailable, so the "
      .. "POKéMON just traded over did not evolve -- update gen1recomp "
      .. "(dev branch); the trade itself is safe")
    return false
  end

  -- Gold's screen is driven by the row rather than by a species id; a build
  -- whose TradeSession only answered the species still gets a usable one.
  if isGen2 and type(entry) ~= "table" then
    entry = { method = "EVOLVE_TRADE", into = evolveTo }
  end

  -- The second write of the pair M:saveTrade documents, on the far side of
  -- the movie: what `apply` committed to disk was the pre-evo, and this is
  -- what puts the species the player is now looking at there instead.
  local function persist() self:saveTrade(game) end

  local shown
  if isGen2 then
    shown = self:showGen2Evolution(game, mon, entry, slot, persist)
  else
    shown = pcall(Evolution.evolve, game, mon, evolveTo, persist, "TRADE")
  end
  if shown then return true end

  -- No screen went up.  `evolve` applies before it prints on its headless
  -- branch, so a mon already carrying the new species is one that got there
  -- -- re-applying would rebuild its stats a second time for nothing.
  if mon.species == evolveTo then return true end

  -- Gold's `apply` builds a new record and answers nil when it cannot -- an
  -- unknown target species, a dataset with no base stats behind it -- so the
  -- fallback is only a success when something came back.  Gen 1 mutates in
  -- place, and the species is the same statement of it.
  local ran, applied = pcall(function()
    if not isGen2 then
      Evolution.apply(game, mon, evolveTo, "TRADE")
      return mon.species == evolveTo
    end
    local evolvedMon = Evolution.apply(game.data, mon, entry)
    if not evolvedMon then return false end
    local party = game.save and game.save.party
    if party and slot and party[slot] == mon then party[slot] = evolvedMon end
    if Evolution.markPokedex then
      Evolution.markPokedex(game.save, evolvedMon.species)
    end
    return true
  end)
  if ran and applied then
    -- The movie is what the player lost, not the evolution and not the save.
    persist()
    mod.log:warn("could not open the evolution screen, so %s evolved into "
      .. "%s without one -- the POKéMON is fine; report the line above",
      tostring(mon.nickname or mon.species), tostring(evolveTo))
    return true
  end

  mod.log:warn("%s did not evolve after the trade -- trade it again to give "
    .. "the evolution another chance", tostring(mon.nickname or mon.species))
  return false
end

-- The Gen 3 evolution: the cart's own EvolutionScene, opened the way
-- natives_trade.lua tryTradeEvolution opens it after a cable trade --
-- `canStop = false` (a trade evolution cannot be cancelled with B), via
-- "trade" so pokemon.evolved says so.  The scene is a layer of its own that
-- applies the evolution itself (Evolution.apply: species, renamed nickname,
-- stats, dex, Shedinja) and runs the learn-move queue for the new species
-- before it pops itself and calls back -- which is where the second save
-- goes.  The held item a trade-item row wanted is already gone: Trade3's
-- apply asked Evolution.tradeTarget, which takes it the way the cart does.
--
-- Without a window (headless) or without the scene module, the evolution is
-- applied outright, as tryTradeEvolution's own headless branch does, and
-- the player is told what they missed.
function M:evolveTraded3(game, mon, evolveTo)
  local Evolution = Gen3.engine("src.core.game3.evolution")
  if not (Evolution and type(Evolution.apply) == "function") then
    mod.log:warn("the engine's Gen 3 evolution module is unavailable, so the "
      .. "POKéMON just traded over did not evolve -- update gen1recomp "
      .. "(dev branch); the trade itself is safe")
    return false
  end
  local session = (type(game) == "table" and game.session) or Gen3.session()
  local function persist() self:saveTrade(game) end

  if type(love) == "table" and love.graphics then
    local Scene = Gen3.engine("src.ui.game3.evolution_scene")
    if Scene and type(Scene.start) == "function" then
      local ok, shown = pcall(Scene.start, mon, evolveTo, {
        canStop = false,
        session = session,
        via = "trade",
        onDone = function() persist() end,
      })
      if ok and shown then return true end
    end
  end

  if tonumber(mon.species) == tonumber(evolveTo) then return true end
  local ran, applied = pcall(Evolution.apply, mon, evolveTo, session,
    session and session.bag, "trade")
  if ran and applied then
    persist()
    if type(love) == "table" and love.graphics then
      mod.log:warn("could not open the evolution screen, so %s evolved "
        .. "without one -- the POKéMON is fine; report the line above",
        tostring(Trade3.displayName(mon)))
    end
    return true
  end
  mod.log:warn("%s did not evolve after the trade -- trade it again to give "
    .. "the evolution another chance", tostring(Trade3.displayName(mon)))
  return false
end

-- The Gen 2 push, split out because it carries the slot bookkeeping the Gen
-- 1 path does not need: EvolutionAnim builds a *new* party record and files
-- it at `index`, so a wrong index would write the evolved mon over somebody
-- else's slot.  `slot` is what the trade filed the mon into; it is verified
-- against the party rather than trusted, and searched for if the party moved
-- under us between the swap and the box being dismissed.
--
-- `onDone` is the caller's second save, run beside the pop rather than
-- handed to the screen: Gen2EvolutionAnim reports and then waits to be taken
-- down, so both belong to whoever pushed it.
function M:showGen2Evolution(game, mon, entry, slot, onDone)
  local party = game.save and game.save.party
  if type(party) ~= "table" then return false end
  if party[slot] ~= mon then
    slot = nil
    for i, member in ipairs(party) do
      if member == mon then
        slot = i
        break
      end
    end
    if not slot then return false end
  end

  local ok, pushed = pcall(mod.ui.push, game, "Gen2EvolutionAnim", {
    mon = mon,
    entry = entry,
    index = slot,
    party = party,
    save = game.save,
    onDone = function()
      local stack = game.stack
      if stack and stack.pop then stack:pop() end
      -- After the pop, so the write sees the party the screen finished
      -- filing rather than one mid-commit.
      if onDone then onDone() end
    end,
  })
  return ok and type(pushed) == "table"
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
--
-- Anything still held back for the player (M:tell, a deferred ask) is about
-- the connection before this one -- an ask the hub forgot with it, a "said
-- no" to an ask the reconnect already cleared -- so it goes, unseen, rather
-- than surfacing later as an ask nobody can answer.  The line a finished
-- trade still owes is kept: it carries the evolution behind it, and M:tell
-- never files such a line under this module (see there).
function M:onTransportReady()
  if self.incoming and self.incoming.deferred then self.incoming = nil end
  local ui = self.ui
  if type(ui) == "table" and type(ui.dropDeferred) == "function" then
    ui:dropDeferred(self)
  end
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

  self:waitOutRequest(game, dt)

  -- Prompts held back while the cart had the screen (Ui:whenFree -- this
  -- module's, Party's, anyone's that shares the Ui).  Ui pumps its queue from
  -- an input.step link of its own on Gen 3 as well, hub or no hub (a line a
  -- finished trade owes outlives the connection); this pass is the one the
  -- hub tick adds, and a ui without that link (a harness) relies on.
  -- Nothing queued is one field read.
  local ui = self.ui
  if type(ui) == "table" and type(ui.pumpDeferred) == "function" then
    ui:pumpDeferred(gameOf(self, game))
  end

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

-- The two halves of an unanswered ask that can strand this client, swept
-- once per tick.  Neither is about a live session, which is why this runs
-- above the "no session, nothing to do" return rather than inside waitOut.
--
--   * **Our ask, with no answer.** Clocked on REQUEST_TIMEOUT and cancelled
--     when it runs out -- see that constant for the lock this breaks.
--
--   * **Their ask, with no box left to answer it in.** `incoming` is cleared
--     by the confirm's own callback, so a box that leaves the stack any other
--     way (a blackout, a save load, anything that clears the stack under it)
--     used to leave this side marked as holding an invite forever: silently
--     refusing every later one, with nothing on screen to answer.  A box gone
--     without an answer *is* a no, so it is sent as one and the asker stops
--     waiting.
--
-- **The box has to have been seen on the stack before its absence means
-- anything.** "Not on the stack" is the same answer for a box that was
-- dismissed and one that was never pushed -- a build with no UI, a harness
-- whose `confirm` is a stub, a push that failed -- and only the first of
-- those is an unanswered invite.  Latching on the first sighting is what
-- tells them apart; unwindTo can treat the two alike because doing nothing is
-- right either way, and this cannot, because it sends a refusal.
function M:waitOutRequest(game, dt)
  dt = tonumber(dt) or 0

  local outgoing = self.outgoing
  if outgoing then
    outgoing.clock = (outgoing.clock or 0) + dt
    if outgoing.clock >= REQUEST_TIMEOUT then
      local name = outgoing.name or "They"
      self:cancelRequest()
      self:tell(game, ("%s never\nanswered."):format(name))
    end
  end

  local incoming = self.incoming
  if incoming and incoming.deferred then
    -- Their ask, still waiting for this player to come out of the cart's
    -- menus (M:onRequest).  Clocked on the asker's own REQUEST_TIMEOUT: by
    -- the time it runs out here the asker has given up and cancelled (which
    -- M:onCancel drops without a box), so this is only the backstop for a
    -- cancel that never arrived -- the ask is dropped unseen and answered no,
    -- the reason saying this side was busy, which it was.
    incoming.clock = (incoming.clock or 0) + dt
    if incoming.clock >= REQUEST_TIMEOUT then
      self.incoming = nil
      self.transport:send(Wire.RESPOND,
        { to = incoming.from, kind = incoming.kind, accept = false, reason = "busy" })
      self:sayRefused(incoming.name, incoming.kind)
    end
    return
  end
  local held = incoming and self.incomingBox
  if not (held and held.box) then return end
  local on = self:onStack(held.game or game, held.box)
  if on then
    held.seen = true
  elseif on == false and held.seen then
    self.incoming = nil
    self.incomingBox = nil
    self.transport:send(Wire.RESPOND,
      { to = incoming.from, kind = incoming.kind, accept = false })
  end
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
