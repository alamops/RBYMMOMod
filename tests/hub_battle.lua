-- src/Hub.lua's mediated battles: the LAN host as intermediator.
--
-- Run: luajit tests/hub_battle.lua                  (from this folder's root)
--   or luajit mods/rby_mmo/tests/hub_battle.lua     (from the engine)
--
-- Standalone, like tests/battle_sim_turn.lua beside it and for the same
-- reason: Hub.lua is deliberately socket-free and facade-free, so a suite that
-- needed love, the engine or the mod loader to drive it would be testing
-- something weaker than the claim.  Everything below talks to fake peers --
-- any table answering :send and :close -- through the same `need`-shaped
-- resolver main.lua uses.
--
-- What is pinned here is the half of the hub the main suite's section 3 does
-- not reach: a battle this hub *runs* rather than relays.  server/hub.test.js
-- pins the same behaviours on the Node side, and the two have to agree message
-- for message -- a client cannot tell which of the two hosting paths refereed
-- its fight, and the day it can is the day one of them is wrong.
--
-- Legal: every fixture below is synthetic.  No species, move or item this repo
-- may not name appears anywhere in this file.

-- ------------------------------------------------------------------
-- where we are
-- ------------------------------------------------------------------

local ROOT = "."
do
  local invoked = arg and arg[0]
  local dir = invoked and invoked:match("^(.*)[/\\]tests[/\\][^/\\]+$")
  if dir and dir ~= "" then ROOT = dir end
end

local function slurp(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local body = handle:read("*a")
  handle:close()
  return body
end

local loadstr = loadstring or load
local cache = {}
local function need(name)
  if cache[name] ~= nil then return cache[name] end
  local path = ROOT .. "/src/" .. name .. ".lua"
  local body = slurp(path)
  if not body then error("missing " .. path, 0) end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then error(tostring(err), 0) end
  cache[name] = chunk(need)
  return cache[name]
end

local Config = need("Config")
local Wire = need("Wire")
local Hub = need("Hub")

-- ------------------------------------------------------------------
-- assertions
-- ------------------------------------------------------------------

local passed, failed = 0, 0

local function ok(condition, what)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write("FAIL " .. tostring(what) .. "\n")
  end
end

local function eq(actual, expected, what)
  if actual == expected then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format("FAIL %s: expected %s, got %s\n",
      tostring(what), tostring(expected), tostring(actual)))
  end
end

-- ------------------------------------------------------------------
-- the fakes
-- ------------------------------------------------------------------

local function fakePeer()
  local peer = { outbox = {}, closed = false }
  function peer:send(msg) self.outbox[#self.outbox + 1] = msg end
  function peer:close() self.closed = true end
  return peer
end

-- Pull the first message of a type off a peer, so a later assertion is not
-- answered by traffic an earlier step left behind.
local function take(peer, msgType)
  for i, msg in ipairs(peer.outbox) do
    if msg.type == msgType then return table.remove(peer.outbox, i) end
  end
  return nil
end

local function count(peer, msgType)
  local n = 0
  for _, msg in ipairs(peer.outbox) do
    if msg.type == msgType then n = n + 1 end
  end
  return n
end

local function testPlayerId(seed)
  local s = tostring(seed or "")
  local out = {}
  for i = 1, 32 do
    local c = s:byte((i - 1) % #s + 1) or 97
    out[i] = string.format("%x", (c + i) % 16)
  end
  return table.concat(out)
end

local function join(hub, name)
  local peer = fakePeer()
  local client = hub:accept(peer)
  if client then
    hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
      name = name, map = "PALLET", x = 5, y = 5, facing = "down",
      playerId = testPlayerId(name) })
  end
  return client, peer
end

local function partyForm(hub, asker, invitee)
  hub:receive(asker, { type = Wire.PARTY_INVITE, to = invitee.id })
  hub:receive(invitee, { type = Wire.PARTY_RESPOND, to = asker.id, accept = true })
end

local function coopAskCount(hub)
  local n = 0
  for _ in pairs(hub.coopAsks or {}) do n = n + 1 end
  return n
end

-- ------------------------------------------------------------------
-- the fixtures
-- ------------------------------------------------------------------
--
-- A two-by-two chart of neutral cells: enough to be a well-formed ruleset,
-- and deliberately not enough to be anybody's real type table.

local CHART = { { 100, 100 }, { 100, 100 } }

local function move(o)
  o = o or {}
  return {
    id = o.id or "thump",
    pp = o.pp or 20,
    power = o.power or 200,
    accuracy = o.accuracy or 255,
    type = 0, effect = 0, chance = 0,
  }
end

local function mon(o)
  o = o or {}
  return {
    species = o.species or "ALPHA",
    level = o.level or 50,
    hp = o.hp or 300,
    maxHp = o.maxHp or o.hp or 300,
    stats = {
      atk = o.atk or 200, def = o.def or 200,
      spd = o.spd or 100, spc = o.spc or 100,
    },
    moves = { move() },
  }
end

-- Set the two sides up so the fight cannot go long: one side hits for a great
-- deal and moves first, the other has a single point of HP.  The point of the
-- test is the plumbing around the sim, not the sim's arithmetic -- that is
-- tests/battle_sim_turn.lua's job -- so the shortest honest KO is the one to
-- ask for.
local function bruiser() return mon({ atk = 999, spd = 999 }) end
local function glassjaw() return mon({ species = "BETA", hp = 1, def = 1, spd = 1 }) end

-- Walk a battle to its end by answering every open turn from both seats.
-- Bounded, because a loop that could not end is the failure this whole suite
-- is meant to catch rather than hang on.
local function fightItOut(hub, seats, limit)
  for _ = 1, limit or 20 do
    for _, seat in ipairs(seats) do
      hub:receive(seat.client, { type = Wire.BATTLE_CHOICE,
        battle = seat.battle, action = "fight", move = 0 })
    end
    if not hub.battles[seats[1].battle] then return true end
  end
  return false
end

-- ------------------------------------------------------------------
-- 1. a record opens with the session, and only for a battle
-- ------------------------------------------------------------------

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")

  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "trade" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "trade", accept = true })
  eq(hub.battles[ann.sessionId], nil,
     "a trade session opens no mediated record -- there is no trade sim")

  hub:receive(ann, { type = Wire.SESSION_LEAVE })
  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })

  local record = hub.battles[ann.sessionId]
  ok(record ~= nil, "a battle session opens one the moment it is agreed")
  eq(record.mode, "1v1", "and it knows the shape of the fight")
  eq(record.hostId, ann.id, "the requester is the authority, as they are the host")
  eq(record.sim, nil, "but nothing is being refereed yet")
  eq(ann.battleId, record.id, "both players are marked as being in it")
  eq(bob.battleId, record.id, "both, not just the one that asked")
end

-- ------------------------------------------------------------------
-- 2. the hard cut: mmo.relay has nowhere to go once a battle is brokered
-- ------------------------------------------------------------------

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann, annPeer = join(hub, "ANN")
  local bob, bobPeer = join(hub, "BOB")

  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "trade" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "trade", accept = true })
  hub:receive(ann, { type = Wire.RELAY, to = bob.id, payload = { hello = 1 } })
  ok(take(bobPeer, Wire.RELAY) ~= nil, "a trade still relays, untouched")

  hub:receive(ann, { type = Wire.SESSION_LEAVE })
  take(annPeer, Wire.SESSION_END)
  take(bobPeer, Wire.SESSION_END)

  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  hub:receive(ann, { type = Wire.RELAY, to = bob.id, payload = { hello = 1 } })
  eq(take(bobPeer, Wire.RELAY), nil,
     "a battle does not: the lockstep vocabulary is cut at the hub")
  eq(ann.relayDrops, 1, "and the refusal is counted rather than being silent")
end

-- ------------------------------------------------------------------
-- 3. ruleset, parties, and the fight opens
-- ------------------------------------------------------------------

local function openFight(hub, seed)
  local ann, annPeer = join(hub, "ANN")
  local bob, bobPeer = join(hub, "BOB")
  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  local id = ann.sessionId

  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id,
                     chart = CHART, seed = seed or 12345 })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, mons = { bruiser() } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = id, mons = { glassjaw() } })
  return {
    id = id,
    ann = { client = ann, peer = annPeer, battle = id },
    bob = { client = bob, peer = bobPeer, battle = id },
  }
end

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann, annPeer = join(hub, "ANN")
  local bob, bobPeer = join(hub, "BOB")
  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  local id = ann.sessionId

  -- The guest's chart is not a chart: two would be a fight with no answer to
  -- "which", and taking the later one would let either side re-roll the
  -- matchups by sending one late.
  hub:receive(bob, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART })
  eq(hub.battles[id].ruleset, nil, "only the authority's ruleset is taken")

  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, chart = "not a chart" })
  eq(hub.battles[id].ruleset, nil, "and a malformed one is refused outright")
  eq(ann.relayDrops, 1, "loudly enough to be counted")

  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id,
                     chart = CHART, seed = 99 })
  ok(hub.battles[id].ruleset ~= nil, "the authority's readable one lands")
  eq(hub.battles[id].sim, nil, "a ruleset alone does not open a fight")

  -- A party for a fight this connection is not in is a sheet whose sender
  -- believes it is being used somewhere else.
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "99", mons = { bruiser() } })
  eq(hub.battles[id].parties[ann.id], nil, "a party naming another battle is ignored")

  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, mons = { bruiser() } })
  eq(hub.battles[id].sim, nil, "one party is still not a field")
  eq(take(annPeer, Wire.BATTLE_READY), nil, "so nobody has been told to draw one")

  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = id, mons = { glassjaw() } })
  ok(hub.battles[id].sim ~= nil, "the message that completes the set opens the fight")

  local readyA = take(annPeer, Wire.BATTLE_READY)
  local readyB = take(bobPeer, Wire.BATTLE_READY)
  ok(readyA ~= nil and readyB ~= nil, "and both sides are told the field is up")
  ok(Wire.battleReady(readyA) ~= nil, "in a shape their own sanitiser accepts")
  eq(readyA.mode, "1v1", "naming the mode rather than leaving it to be guessed")
  eq(readyA.sides.a[1], ann.id, "with the authority on side a")
  eq(readyA.sides.b[1], bob.id, "and the other player on side b")

  ok(count(annPeer, Wire.BATTLE_EVENT) > 0,
     "the opening events are flushed in the same breath")
  local event = take(annPeer, Wire.BATTLE_EVENT)
  ok(Wire.battleEvent(event) ~= nil, "and survive the client's own sanitiser")
  eq(event.battle, id, "every event names the fight it belongs to")
end

-- ------------------------------------------------------------------
-- 4. a fight the hub resolves ends in a KO, and pays out on its own word
-- ------------------------------------------------------------------

do
  local hub = Hub.new({ maxPlayers = 4 })
  local fight = openFight(hub)
  local id = fight.id
  take(fight.ann.peer, Wire.BATTLE_READY)
  take(fight.bob.peer, Wire.BATTLE_READY)

  -- While the hub is refereeing, a client's vote on the result is ignored
  -- rather than weighed: there is a witness now, and it did every roll.
  hub:receive(fight.ann.client,
    { type = Wire.RESULT, session = id, outcome = "win" })
  eq(hub.matches[id].reports[fight.ann.client.id], nil,
     "mmo.result about a mediated fight files nothing")

  ok(fightItOut(hub, { fight.ann, fight.bob }), "the fight reaches an end")

  local outcome = take(fight.ann.peer, Wire.BATTLE_OUTCOME)
  ok(outcome ~= nil, "the winner is told how it ended")
  ok(take(fight.bob.peer, Wire.BATTLE_OUTCOME) ~= nil, "and so is the loser")
  ok(Wire.battleOutcome(outcome) ~= nil,
     "in a shape their own sanitiser accepts")
  eq(outcome.outcome, "win", "stated from the field's point of view")
  eq(outcome.reason, "ko", "and the ordinary reason is the ordinary word for it")
  eq(outcome.winners[1], fight.ann.client.id, "naming who won")
  eq(outcome.losers[1], fight.bob.client.id, "and who did not")

  eq(hub.battles[id], nil, "the record is forgotten once it is settled")
  eq(fight.ann.client.battleId, nil, "and both players are let out of it")
  eq(fight.bob.client.battleId, nil, "both, so the next fight finds a free seat")
  eq(hub.matches[id], nil, "the paperwork goes with it -- one battle, one payout")

  -- The rating moved on the intermediator's word alone, with no second report
  -- from anybody.
  ok(hub.board:points(fight.ann.client.id) > hub.board:points(fight.bob.client.id),
     "the winner is worth more than the loser afterwards")
  local rank = take(fight.ann.peer, Wire.RANK)
  ok(rank ~= nil, "and the new number is published")
end

-- ------------------------------------------------------------------
-- 5. a player who leaves is paused, not excused -- and forfeits on the clock
-- ------------------------------------------------------------------

do
  local hub = Hub.new({ maxPlayers = 4 })
  local fight = openFight(hub)
  local id = fight.id
  take(fight.ann.peer, Wire.BATTLE_READY)

  hub:receive(fight.bob.client, { type = Wire.SESSION_LEAVE })
  ok(hub.battles[id] ~= nil,
     "walking off the field does not end a fight the hub is running")
  ok(hub.battles[id].sim ~= nil, "the sim is still holding the grace open")

  hub:update(1)
  eq(hub.battles[id] and true or false, true,
     "and it is still running well inside the window")

  -- ...and back again inside it resumes where it paused.
  hub:receive(fight.bob.client, { type = Wire.BATTLE_RECONNECT, battle = id })
  local resumed = false
  for _, msg in ipairs(fight.ann.peer.outbox) do
    if msg.type == Wire.BATTLE_EVENT and msg.t == "reconnect" then resumed = true end
  end
  ok(resumed, "a reconnect inside the grace is announced to the other side")

  -- Now really gone: the connection drops and nobody comes back for it.
  hub:drop(fight.bob.client)
  ok(hub.battles[id] ~= nil, "a dropped socket still only starts the clock")
  hub:update(Config.BATTLE_RECONNECT_GRACE + 2)

  local outcome = take(fight.ann.peer, Wire.BATTLE_OUTCOME)
  ok(outcome ~= nil, "which the tick eventually fires")
  eq(outcome.outcome, "forfeit", "as a forfeit rather than a draw")
  eq(outcome.reason, "disconnect", "and it says why")
  eq(outcome.winners[1], fight.ann.client.id, "to the player who was still there")
  eq(hub.battles[id], nil, "the record is cleared like any other settlement")
end

-- ------------------------------------------------------------------
-- 5c. SESSION_LEAVE during grace cannot start a second fight
-- ------------------------------------------------------------------
--
-- endSession calls leaveBattle (grace, battleId kept) then clears sessionId.
-- REQUEST / startSession used to look only at sessionId, so the same
-- connection could open a new pairing; openMediatedBattle then overwrote
-- member.battleId and left the old sim ticking toward a forfeit.

do
  local hub = Hub.new({ maxPlayers = 8 })
  local fight = openFight(hub)
  local id = fight.id
  take(fight.ann.peer, Wire.BATTLE_READY)
  take(fight.bob.peer, Wire.BATTLE_READY)
  local bob = fight.bob.client
  local cal, calPeer = join(hub, "CAL")
  calPeer.outbox = {}

  hub:receive(bob, { type = Wire.SESSION_LEAVE })
  eq(bob.sessionId, nil, "the session is gone")
  eq(bob.battleId, id, "but grace still binds them to the fight")
  ok(hub.battles[id] ~= nil, "and the original record is still standing")

  fight.bob.peer.outbox = {}
  hub:receive(bob, { type = Wire.REQUEST, to = cal.id, kind = "duel" })
  eq(take(fight.bob.peer, Wire.DECLINE), nil,
     "a request with no valid kind earns no reply")

  hub:receive(bob, { type = Wire.REQUEST, to = cal.id, kind = "battle" })
  eq(take(calPeer, Wire.REQUEST), nil,
     "the leaver cannot open a second pairing while grace runs")
  local selfBusy = take(fight.bob.peer, Wire.DECLINE)
  ok(selfBusy ~= nil, "the leaver is told no so their outgoing ask clears")
  eq(selfBusy and selfBusy.reason, "busy", "as busy, because they still have a battle")
  eq(selfBusy and selfBusy.kind, "battle", "naming the ask they sent")

  hub:receive(cal, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  local declined = take(calPeer, Wire.DECLINE)
  ok(declined ~= nil, "asking them is answered, not a new fight")
  eq(declined.reason, "busy", "as busy, because they still have a battle")

  hub:startSession(bob, cal, "battle")
  eq(cal.sessionId, nil, "startSession itself refuses while they are bound")
  eq(hub:openMediatedBattle("s999", { memberIds = { bob.id } }), nil,
     "openMediatedBattle will not overwrite an unsettled battleId")
  eq(bob.battleId, id, "so they stay on the original fight")
  ok(hub.battles[id] ~= nil, "which is still the one record")

  hub:update(Config.BATTLE_RECONNECT_GRACE + 2)
  eq(hub.battles[id], nil, "past grace the original fight settles")
  eq(bob.battleId, nil, "and they are let out of it")
  calPeer.outbox = {}
  hub:receive(bob, { type = Wire.REQUEST, to = cal.id, kind = "battle" })
  ok(take(calPeer, Wire.REQUEST) ~= nil, "past grace a new ask is forwarded")
end

-- A stolen battleId is a drop of that seat, not a wipe of the field.
do
  local hub = Hub.new({ maxPlayers = 4 })
  local fight = openFight(hub)
  local id = fight.id
  take(fight.ann.peer, Wire.BATTLE_READY)
  take(fight.bob.peer, Wire.BATTLE_READY)
  local ann, bob = fight.ann.client, fight.bob.client

  bob.battleId = "stolen"
  hub:tickBattles(hub.clock)
  ok(hub.battles[id] ~= nil,
     "a stolen seat does not abort the partner still bound")
  eq(ann.battleId, id, "the partner stays on the original fight")
  eq(bob.battleId, nil, "and the stolen pointer is forgotten")

  ann.battleId = "stolen2"
  hub:tickBattles(hub.clock)
  eq(hub.battles[id], nil,
     "when no connected member still points at it, the record is aborted")
  eq(ann.battleId, nil, "and the second stolen pointer is forgotten")
end

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")
  hub:openCoopBattle("c-orphan", { ann.id, bob.id },
    { mode = "coop_npc", hostId = ann.id })
  ok(hub.coopBattles["c-orphan"] ~= nil, "a coop group opens with the fight")

  ann.battleId, bob.battleId = "stolen", "stolen2"
  hub:tickBattles(hub.clock)
  eq(hub.battles["c-orphan"], nil, "the fight is gone")
  eq(hub.coopBattles["c-orphan"], nil, "and the fan-out group closes with it")
  eq(ann.coopBattleId, nil, "so neither member is still filed under it")
  eq(bob.coopBattleId, nil, "both of them")
end

-- ------------------------------------------------------------------
-- 5b. a throwing handler does not take the hub down
-- ------------------------------------------------------------------

do
  local seen = {}
  local hub = Hub.new({
    maxPlayers = 4,
    onHandlerError = function(msgType, clientId, err)
      seen[#seen + 1] = { msgType = msgType, clientId = clientId, err = tostring(err) }
    end,
  })
  local fight = openFight(hub)
  local id = fight.id
  take(fight.ann.peer, Wire.BATTLE_READY)
  take(fight.bob.peer, Wire.BATTLE_READY)

  -- Inject a boom into the live sim's choice path: the same class of throw a
  -- wedged Turn/Damage used to kill the LAN host with.
  local sim = hub.battles[id].sim
  local real = sim.submitChoice
  sim.submitChoice = function()
    error("injected handler boom", 0)
  end
  hub:receive(fight.ann.client, {
    type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0,
  })
  eq(#seen, 1, "the throw was reported rather than rethrown")
  eq(seen[1].msgType, Wire.BATTLE_CHOICE, "naming the handler")
  ok(hub.clients[fight.ann.client.id] ~= nil,
     "and the client was not dropped solely for the throw")

  sim.submitChoice = real
  hub:receive(fight.ann.client, { type = Wire.PING })
  ok(take(fight.ann.peer, Wire.PONG) ~= nil,
     "a later message still lands on the same connection")
end

-- ------------------------------------------------------------------
-- 6. a fight that was still being assembled is called off, not refereed
-- ------------------------------------------------------------------

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann, annPeer = join(hub, "ANN")
  local bob = join(hub, "BOB")
  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  local id = ann.sessionId
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART })

  hub:drop(bob)
  eq(hub.battles[id], nil, "a half-built fight goes with the player who left")
  local outcome = take(annPeer, Wire.BATTLE_OUTCOME)
  ok(outcome ~= nil, "and the player still there is told, not left waiting")
  eq(outcome.outcome, "draw", "as a draw -- nothing was ever fought")
  eq(outcome.winners, nil,
     "carrying no winners at all: an empty list is a message no client reads")
  eq(ann.battleId, nil, "and the survivor is out of it")
end

-- ------------------------------------------------------------------
-- 7. the co-op shapes, as far as this wave owns them
-- ------------------------------------------------------------------
--
-- The four-way flow is Wave 3's; what is pinned here is the seat arithmetic
-- underneath it, because it is what decides whether a trainer's party lands on
-- a synthetic seat or displaces the host's own team.

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")

  local record = hub:openMediatedBattle("npc-1", {
    mode = "coop_npc", hostId = ann.id, memberIds = { ann.id, bob.id },
  })
  ok(record ~= nil, "a co-op record opens from a plan")
  eq(#(record.npcIds or {}), 2,
     "with two synthetic seats -- two players meet two monsters, and one seat "
     .. "was a 2-on-1 where the screen draws a 2-on-2")
  eq(record.npcIds[1], "nnpc-1a", "named off the battle they belong to")
  eq(record.npcIds[2], "nnpc-1b", "and told apart by a letter")
  eq(Wire.id(record.npcIds[1]), record.npcIds[1],
     "and spellable on the wire, because battle_ready advertises them")
  eq(record.sides.b[1], record.npcIds[1], "side b is the trainer's")
  eq(#record.sides.b, 2, "both seats of it")
  eq(#hub:seatsNeeded(record), 4, "and four seats owe a party, not three")
  eq(hub:battleSeat(record, ann, { side = "b" }), record.npcIds[1],
     "the authority's side-b upload is the trainer's team")
  eq(hub:battleSeat(record, ann, { side = "a" }), ann.id,
     "and their side-a upload is still their own")
  eq(hub:battleSeat(record, bob, { side = "b" }), nil,
     "a partner cannot fill the trainer's seat by claiming side b")

  local stranger = join(hub, "CAL")
  eq(hub:battleSeat(record, stranger, { side = "a" }), nil,
     "and somebody who is not in the fight fills no seat at all")

  -- An inferred plan still has to produce a field somebody can fight on.
  hub:abortMediatedBattle(record, "gone")
  local pvp = hub:openMediatedBattle("pvp-1",
    { memberIds = { ann.id, bob.id, stranger.id } })
  eq(pvp.mode, "coop_pvp", "three humans infer coop_pvp without synthetic seats")
  eq(#pvp.sides.a + #pvp.sides.b, 3, "with everybody placed on one side or other")
  eq(pvp.npcIds, nil, "and no synthetic seats, because both sides are players")
end

-- ------- the trainer's team is dealt across the two seats
--
-- It is uploaded as one list because that is what it is on the host's screen --
-- src/CoopBattle.lua re-interleaves the two ownerless slots back into send-out
-- order -- so the deal here is the inverse of the one src/Coop.lua made when it
-- built the field.

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")

  local record = hub:openMediatedBattle("npc-2", {
    mode = "coop_npc", hostId = ann.id, memberIds = { ann.id, bob.id },
  })
  local first, second = record.npcIds[1], record.npcIds[2]
  ok(hub:fillBattleParty(record, ann, { battle = "npc-2", side = "b", mons = {
    mon({ species = "ONE" }), mon({ species = "TWO" }),
    mon({ species = "THREE" }), mon({ species = "FOUR" }),
  } }), "a side-b upload from the authority is taken")
  eq(#record.parties[first].mons, 2, "half the team fights from the first seat")
  eq(#record.parties[second].mons, 2, "and half from the second")
  eq(record.parties[first].mons[1].species, "ONE",
     "the trainer still leads with the monster it meant to")
  eq(record.parties[second].mons[1].species, "TWO",
     "and the next one out stands beside it, not behind it")
  eq(record.parties[first].mons[2].species, "THREE", "then back to the first")
  eq(record.parties[second].mons[2].species, "FOUR", "and the last one last")

  -- A trainer with one monster is still a trainer, so the spare seat is given
  -- up rather than the fight being refused over a party nobody can fill.
  hub:abortMediatedBattle(record, "gone")
  local lone = hub:openMediatedBattle("npc-3", {
    mode = "coop_npc", hostId = ann.id, memberIds = { ann.id, bob.id },
  })
  hub:fillBattleParty(lone, ann,
    { battle = "npc-3", side = "b", mons = { mon() } })
  eq(#lone.npcIds, 1, "one monster seats one npc")
  eq(#lone.sides.b, 1, "and the empty seat leaves the field with it")
  eq(#hub:seatsNeeded(lone), 3, "so nothing is left owing a party that never comes")
end

-- ------------------------------------------------------------------
-- 8. a field the turn machine will not fight on
-- ------------------------------------------------------------------
--
-- Turn.create answers a reason rather than raising, because every caller here
-- is downstream of a mod callback where a bare error() is a loader rule
-- violation.  What the hub owes in return is not to leave the fight half-open:
-- abort the record, release the pairing, and tell both sides so they are
-- not waiting for a battle_ready that will never come.

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann, annPeer = join(hub, "ANN")
  local bob, bobPeer = join(hub, "BOB")
  local cal, calPeer = join(hub, "CAL")

  -- Three fighters crowded onto one side of a 1v1: well-formed as messages,
  -- unfightable as a field.
  local record = hub:openMediatedBattle("bad-1", {
    mode = "1v1", hostId = ann.id,
    memberIds = { ann.id, bob.id, cal.id },
    sides = { a = { ann.id, bob.id }, b = { cal.id } },
  })
  record.ruleset = { chart = CHART, seed = 7 }
  for _, seat in ipairs({ ann, bob, cal }) do
    record.parties[seat.id] = { battle = "bad-1", mons = { mon() } }
  end

  eq(ann.battleId, "bad-1", "the seats were marked before assembly")
  eq(hub:tryStartSim(record), false, "an unfightable field opens no sim")
  eq(ann.relayDrops, 1, "with the refusal charged to the authority")
  eq(hub.battles["bad-1"], nil,
     "the record is cleared rather than left half-open")
  eq(ann.battleId, nil, "and the host is unmarked")
  eq(bob.battleId, nil, "and so is the guest")
  eq(cal.battleId, nil, "and the third seat too")
  local outcome = take(annPeer, Wire.BATTLE_OUTCOME)
  ok(outcome and outcome.outcome == "draw" and outcome.reason == "agree",
     "players hear it called off rather than waiting for battle_ready")
  local bobOut = take(bobPeer, Wire.BATTLE_OUTCOME)
  ok(bobOut and bobOut.reason == "agree", "both sides hear the abort")
  local calOut = take(calPeer, Wire.BATTLE_OUTCOME)
  ok(calOut and calOut.reason == "agree", "every marked seat hears it")
end

-- A REQUEST/RESPOND 1v1 still holds sessionId after abortMediatedBattle.
-- Assembly failure has to drop that too, or busyNow keeps the pairing stuck.
do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann, annPeer = join(hub, "ANN")
  local bob, bobPeer = join(hub, "BOB")
  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  local record = hub.battles[ann.sessionId]
  record.ruleset = { chart = CHART, seed = 7 }
  record.parties[ann.id] = { battle = record.id, mons = {} }
  record.parties[bob.id] = { battle = record.id, mons = { mon() } }
  eq(ann.sessionId, record.id, "the pairing is live")
  ok(hub.matches[record.id] ~= nil, "ranked paperwork existed for the pairing")
  eq(hub:tryStartSim(record), false, "an empty party opens no sim")
  eq(ann.sessionId, nil, "the host is off the pairing")
  eq(bob.sessionId, nil, "and so is the guest")
  eq(ann.battleId, nil, "and unmarked for the fight")
  eq(hub.matches[record.id], nil, "and the settlement record is dropped")
  hub:receive(ann, { type = Wire.RESULT, session = record.id, outcome = "win" })
  hub:receive(bob, { type = Wire.RESULT, session = record.id, outcome = "loss" })
  eq(hub.matches[record.id], nil, "a leftover vote cannot resurrect it")
  local outcome = take(annPeer, Wire.BATTLE_OUTCOME)
  ok(outcome and outcome.reason == "agree", "they hear it called off")
  ok(take(bobPeer, Wire.SESSION_END) ~= nil, "the guest hears the pairing end")
end

-- Same for a co-op group: abort alone left coopBattleId set.
do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann, annPeer = join(hub, "ANN")
  local bob = join(hub, "BOB")
  local id = hub:openCoopBattle("c-bad", { ann.id, bob.id },
    { mode = "coop_npc", hostId = ann.id })
  local record = hub.battles[id]
  record.ruleset = { chart = CHART, seed = 7 }
  for _, seat in ipairs(hub:seatsNeeded(record)) do
    record.parties[seat] = { battle = id, mons = { mon() } }
  end
  record.parties[record.npcIds[1]] = { battle = id, mons = {} }
  hub.coopMatches[id] = {
    a = {}, b = {}, reports = {}, everyone = { ann.id, bob.id },
    startedAt = hub.clock,
  }
  eq(ann.coopBattleId, id, "the co-op group is live")
  eq(hub:tryStartSim(record), false, "an empty npc seat opens no sim")
  eq(ann.coopBattleId, nil, "the group is released")
  eq(bob.coopBattleId, nil, "both members")
  eq(hub.coopBattles[id], nil, "and forgotten")
  eq(hub.coopMatches[id], nil, "and the settlement record is dropped")
  local outcome = take(annPeer, Wire.BATTLE_OUTCOME)
  ok(outcome and outcome.reason == "agree", "they hear it called off")
end

-- A refused open must not leave a group, seat marks, or ranked paperwork.
do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")
  local cal = join(hub, "CAL")
  local dee = join(hub, "DEE")
  eq(hub:openCoopBattle("c-none", {}, { mode = "coop_pvp" }), nil,
     "an empty roster opens nothing")
  eq(hub.coopBattles["c-none"], nil, "and leaves no group")
  eq(ann.coopBattleId, nil, "and marks no seat")
  eq(hub.coopMatches["c-none"], nil, "and files no paperwork")

  hub.coopAsks["c-miss"] = {
    asker = ann.id,
    sideA = { ann.id, bob.id },
    sideB = { cal.id, dee.id },
    everyone = {},
    answers = {},
    needed = 3,
    startedAt = hub.clock,
  }
  hub:startCoopBattle("c-miss")
  eq(hub.coopMatches["c-miss"], nil, "a refused start files no settlement record")
  eq(hub.coopBattles["c-miss"], nil, "and leaves no group")
  eq(hub.battles["c-miss"], nil, "and opens no fight")
  eq(hub.coopAsks["c-miss"], nil, "and the ask is torn down")
end

-- ------------------------------------------------------------------
-- 9. one battles table, two id spaces
-- ------------------------------------------------------------------
--
-- Sessions and co-op battles are numbered by two counters that know nothing of
-- each other, and both open a mediated record under their own id.  Plain
-- integers meant the second counter's "1" landed on the first's record: a co-op
-- fight inheriting a 1v1's parties, and a choice from one filed into the other.

do
  local hub = Hub.new({ maxPlayers = 8 })
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")
  local cal = join(hub, "CAL")
  local dee = join(hub, "DEE")

  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  eq(ann.sessionId, "s1", "a session id carries its own letter")
  eq(Wire.id(ann.sessionId), ann.sessionId, "and is still an id on the wire")

  local coop = hub:openCoopBattle("c1", { cal.id, dee.id },
    { mode = "coop_npc", hostId = cal.id })
  eq(coop, "c1", "a co-op battle carries a different one")
  ok(hub.battles["s1"] ~= nil and hub.battles["c1"] ~= nil,
     "so both records exist at once rather than one overwriting the other")
  eq(hub.battles["s1"].mode, "1v1", "each still knowing which fight it is")
  eq(hub.battles["c1"].mode, "coop_npc", "and neither wearing the other's shape")
end

-- ------------------------------------------------------------------
-- 10. the seed is the intermediator's
-- ------------------------------------------------------------------
--
-- A client may still send one -- the field has ridden mmo.battle_ruleset since
-- the lockstep days -- but a fight whose seed came off the wire is one the
-- authority can replay offline until it likes the run, and then ask for it.

do
  local hub2 = Hub.new({ maxPlayers = 4 })
  local ann = join(hub2, "ANN")
  local bob = join(hub2, "BOB")
  local record = hub2:openMediatedBattle("seed-1", {
    mode = "1v1", hostId = ann.id, memberIds = { ann.id, bob.id },
    sides = { a = { ann.id }, b = { bob.id } },
  })
  record.ruleset = { chart = CHART, seed = 777 }
  record.parties[ann.id] = { battle = "seed-1", mons = { mon() } }
  record.parties[bob.id] = { battle = "seed-1", mons = { mon() } }
  ok(hub2:tryStartSim(record), "the fight opens")
  ok(record.sim.seed ~= 777,
     "on a seed of the hub's own, not the one the authority asked for "
     .. "(a pool that answered 777 by chance is a one-in-2^30 rerun)")

  -- The one way in is a field on the hub, which is not something a connection
  -- can reach -- and it is what lets a suite ask for a reproducible fight.
  local hub3 = Hub.new({ maxPlayers = 4 })
  hub3.forceBattleSeed = 5
  local cal = join(hub3, "CAL")
  local dee = join(hub3, "DEE")
  local forced = hub3:openMediatedBattle("seed-2", {
    mode = "1v1", hostId = cal.id, memberIds = { cal.id, dee.id },
    sides = { a = { cal.id }, b = { dee.id } },
  })
  forced.ruleset = { chart = CHART, seed = 777 }
  forced.parties[cal.id] = { battle = "seed-2", mons = { mon() } }
  forced.parties[dee.id] = { battle = "seed-2", mons = { mon() } }
  ok(hub3:tryStartSim(forced), "a forced fight opens too")
  eq(forced.sim.seed, 5, "and takes the hub's number over the wire's")
end

-- ------------------------------------------------------------------
-- 11. a fight against a trainer, which nobody is connected to
-- ------------------------------------------------------------------
--
-- The two things coop_npc was waiting on: two seats for the trainer rather than
-- one, and something to answer for them.  Without the second, every turn sat out
-- BATTLE_CHOICE_TIMEOUT and was auto-picked a minute later anyway.

do
  local hub = Hub.new({ maxPlayers = 4 })
  hub.forceBattleSeed = 1
  local ann, annPeer = join(hub, "ANN")
  local bob, bobPeer = join(hub, "BOB")

  hub:openCoopBattle("c1", { ann.id, bob.id },
    { mode = "coop_npc", hostId = ann.id })
  local record = hub.battles["c1"]

  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "c1", chart = CHART })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "c1", side = "a",
                     mons = { bruiser() } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = "c1", side = "a",
                     mons = { bruiser() } })
  eq(record.sim, nil, "two players are not a field: the trainer owes a team too")

  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "c1", side = "b",
                     mons = { glassjaw(), glassjaw() } })
  ok(record.sim ~= nil, "and the host's second party is what completes the set")
  eq(#record.parties[record.npcIds[1]].mons, 1, "dealt one to each seat")
  eq(#record.parties[record.npcIds[2]].mons, 1, "both of them, not one seat's two")

  -- A trainer seat the host uploaded no bag for stays empty. The gym kit
  -- used to be seeded onto *each* NPC seat, so a 2v2 looked like eight
  -- healing items and every Youngster drank potions. Hosts now upload the
  -- trainer's own kit with the side-"b" party; nothing here invents one.
  ok(not hub:isWildSeat(record, record.npcIds[1]),
     "a coop_npc npc seat is a trainer, not wildlife")
  eq(record.sim.byId[record.npcIds[1]].bag, nil,
     "no uploaded bag means no gym kit")
  eq(record.sim.byId[record.npcIds[2]].bag, nil,
     "...on either seat")

  local ready = take(annPeer, Wire.BATTLE_READY)
  ok(ready ~= nil, "the field is announced")
  ok(Wire.battleReady(ready) ~= nil, "in a shape the client's sanitiser accepts")
  eq(#ready.sides.b, 2, "with both trainer seats named on side b")
  eq(ready.sides.b[1], record.npcIds[1],
     "under their own ids rather than behind the host's, so the screen can map "
     .. "each of them onto a box it is already drawing")
  ok(take(bobPeer, Wire.BATTLE_READY) ~= nil, "and the partner hears it too")

  -- The turn the trainer is in resolves on the players' choices alone. Nothing
  -- below advances the hub's clock, so a turn that needed the deadline to close
  -- would leave this loop going round until it gave up.
  local annSeat = { client = ann, battle = "c1" }
  local bobSeat = { client = bob, battle = "c1" }
  ok(fightItOut(hub, { annSeat, bobSeat }),
     "the fight runs to an end with nobody waiting on a clock")
  eq(hub.clock, 0, "and no time passed at all -- the trainer answered at once")

  local outcome = take(annPeer, Wire.BATTLE_OUTCOME)
  ok(outcome ~= nil, "both players are told how it ended")
  eq(outcome.outcome, "win", "stated from the field's point of view")
  eq(outcome.winners[1], ann.id, "with the two players named as the winners")
  eq(outcome.losers[1], record.npcIds[1],
     "and the trainer's seats as the side that lost")
  eq(hub.battles["c1"], nil, "the record is cleared like any other settlement")

  -- Nobody was ever picked for on the clock: that sentence is the timeout's, and
  -- a refereed trainer battle must not be reading it every turn.
  local hurried = false
  for _, msg in ipairs(bobPeer.outbox) do
    if msg.type == Wire.BATTLE_EVENT and type(msg.text) == "string"
       and msg.text:find("ran out of time", 1, true) then hurried = true end
  end
  ok(not hurried, "and nothing in the log says anybody ran out of time")
end

-- One trainer, one bag: an uploaded kit is shared across both NPC seats,
-- not cloned, so a 2v2 cannot drink the same potion twice.

do
  local hub = Hub.new({ maxPlayers = 4 })
  hub.forceBattleSeed = 1
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")
  hub:openCoopBattle("c-bag", { ann.id, bob.id },
    { mode = "coop_npc", hostId = ann.id })
  local record = hub.battles["c-bag"]
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "c-bag", chart = CHART })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "c-bag", side = "a",
                     mons = { bruiser() } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = "c-bag", side = "a",
                     mons = { bruiser() } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "c-bag", side = "b",
                     mons = { glassjaw(), glassjaw() },
                     bag = { { id = "POTION", count = 1 } } })
  ok(record.sim ~= nil, "the fight opens with the trainer's uploaded kit")
  local bagA = record.sim.byId[record.npcIds[1]].bag
  local bagB = record.sim.byId[record.npcIds[2]].bag
  eq(bagA and bagA.POTION, 1, "one potion, the count the trainer actually has")
  eq(bagB and bagB.POTION, 1, "visible on the second seat too")
  ok(bagA == bagB, "the same table -- spending one spends both")
end

-- Guest side-"b" is not an NPC upload. Only the initiator fills the trainer
-- kit; a guest sheet on that side is dropped rather than overwriting them.

do
  local hub = Hub.new({ maxPlayers = 4 })
  hub.forceBattleSeed = 1
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")
  hub:openCoopBattle("c-guestb", { ann.id, bob.id },
    { mode = "coop_npc", hostId = ann.id })
  local record = hub.battles["c-guestb"]
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "c-guestb", chart = CHART })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "c-guestb", side = "a",
                     mons = { bruiser() } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = "c-guestb", side = "a",
                     mons = { bruiser() } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = "c-guestb", side = "b",
                     mons = { glassjaw(), glassjaw() },
                     bag = { { id = "POTION", count = 9 } } })
  eq(record.sim, nil, "a guest side-b does not open the fight")
  eq(record.parties[bob.id] and record.parties[bob.id].mons[1].hp, bruiser().hp,
     "and does not replace the guest's own party")
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "c-guestb", side = "b",
                     mons = { glassjaw(), glassjaw() },
                     bag = { { id = "POTION", count = 1 } } })
  ok(record.sim ~= nil, "the initiator's side-b is what seats the trainer")
  eq(record.sim.byId[record.npcIds[1]].bag and
       record.sim.byId[record.npcIds[1]].bag.POTION, 1,
     "with the initiator's kit, not the guest's")
end

-- ------- protocol-only wild: one human, one NPC seat, catch sheet on outcome

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann = join(hub, "ANN")
  local record = hub:openMediatedBattle("wild-1", {
    mode = "wild", hostId = ann.id, memberIds = { ann.id },
  })
  ok(record ~= nil, "a wild record opens from a plan")
  eq(#(record.npcIds or {}), 1, "with one synthetic wild seat")
  eq(record.sides.b[1], record.npcIds[1], "side b is the wild seat")
  eq(hub:battleSeat(record, ann, { side = "b" }), record.npcIds[1],
     "the host's side-b upload fills the wild seat")
  eq(#hub:seatsNeeded(record), 2, "two seats owe a party")

  ok(hub:fillBattleParty(record, ann, {
    battle = "wild-1", side = "a", mons = { mon() },
  }), "player party uploaded")
  ok(hub:fillBattleParty(record, ann, {
    battle = "wild-1", side = "b",
    mons = { mon({ species = "PIDGEY", catchRate = 255 }) },
  }), "wild party uploaded")
  record.ruleset = { chart = CHART, seed = 1 }
  ok(hub:tryStartSim(record), "wild sim starts")
  ok(record.sim ~= nil, "and the intermediator is running")

  -- Wildlife carries no bag.  The seat is synthetic exactly as a coop_npc
  -- trainer seat is, and it used to be seeded with the same gym kit -- which is
  -- how a wild monster ended up drinking a Potion mid-fight.  BattleSim refuses
  -- an item from the seat as well; this is the bag never existing.
  ok(hub:isNpcSeat(record, record.npcIds[1]), "the wild seat is a synthetic seat")
  ok(hub:isWildSeat(record, record.npcIds[1]), "and it is wildlife, not a trainer")
  eq(record.bags[record.npcIds[1]], nil, "so no gym kit was seeded onto it")
  eq(record.sim.byId[record.npcIds[1]].bag, nil,
     "and it fights with no bag at all")
end

-- ------- coop_wild: two humans, one wild seat; 2-human gate; catcher on catch

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")

  local record = hub:openMediatedBattle("cw-1", {
    mode = "coop_wild", hostId = ann.id, memberIds = { ann.id, bob.id },
  })
  ok(record ~= nil, "a coop_wild record opens with two members")
  eq(#(record.npcIds or {}), 1, "with one synthetic wild seat")
  eq(#record.sides.a, 2, "side a is two humans")
  eq(#record.sides.b, 1, "side b is the wild seat")
  eq(record.sides.b[1], record.npcIds[1], "side b names the wild seat")
  eq(hub:battleSeat(record, ann, { side = "b" }), record.npcIds[1],
     "the host's side-b upload fills the wild seat")
  eq(#hub:seatsNeeded(record), 3, "three seats owe a party")
end

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann = join(hub, "ANN")

  local record = hub:openMediatedBattle("cw-2", {
    mode = "coop_wild", hostId = ann.id, memberIds = { ann.id },
  })
  eq(record, nil, "coop_wild refuses with one human")
end

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")
  local cal = join(hub, "CAL")

  local record = hub:openMediatedBattle("cw-3", {
    mode = "coop_wild", hostId = ann.id,
    memberIds = { ann.id, bob.id, cal.id },
  })
  ok(record ~= nil, "coop_wild opens with three humans")
  eq(#(record.npcIds or {}), 1, "still one synthetic wild seat")
  eq(#record.sides.a, 3, "side a is three humans")
  eq(#record.sides.b, 1, "side b is the wild seat")
  eq(#hub:seatsNeeded(record), 4, "four seats owe a party")
end

do
  local hub = Hub.new({ maxPlayers = 8 })
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")
  local cal = join(hub, "CAL")

  local record = hub:openMediatedBattle("npc-3h", {
    mode = "coop_npc", hostId = ann.id,
    memberIds = { ann.id, bob.id, cal.id },
  })
  ok(record ~= nil, "coop_npc opens with three humans")
  eq(#(record.npcIds or {}), 3, "foe seats match the human count")
  eq(#record.sides.a, 3, "side a is three humans")
  eq(#record.sides.b, 3, "side b is three trainer seats")
  eq(#hub:seatsNeeded(record), 6, "six seats owe a party")
end

-- ------- parties: grow to three, refuse a fourth, leave-one-of-three

do
  local hub = Hub.new({ maxPlayers = 8 })
  local ann, annPeer = join(hub, "ANN")
  local bob, bobPeer = join(hub, "BOB")
  local cal, calPeer = join(hub, "CAL")
  local dee, deePeer = join(hub, "DEE")

  partyForm(hub, ann, bob)
  local pair = take(annPeer, Wire.PARTY)
  take(bobPeer, Wire.PARTY)
  eq(#pair.members, 2, "a new party starts with two members")

  partyForm(hub, ann, cal)
  local trioAnn = take(annPeer, Wire.PARTY)
  local trioBob = take(bobPeer, Wire.PARTY)
  local trioCal = take(calPeer, Wire.PARTY)
  eq(#trioAnn.members, 3, "inviting a third carries the full roster")
  eq(trioBob.id, trioAnn.id, "every member shares one party id")
  eq(trioCal.id, trioAnn.id, "including the newcomer")

  hub:receive(ann, { type = Wire.PARTY_INVITE, to = dee.id })
  eq(take(deePeer, Wire.PARTY_INVITE), nil,
     "a full party never forwards a fourth invite")

  hub:receive(cal, { type = Wire.PARTY_LEAVE })
  local duoAnn = take(annPeer, Wire.PARTY)
  local duoBob = take(bobPeer, Wire.PARTY)
  eq(#duoAnn.members, 2, "two remain after one of three leaves")
  eq(take(annPeer, Wire.PARTY_END), nil,
     "survivors are not told the party ended")
  eq(take(bobPeer, Wire.PARTY_END), nil,
     "survivors are not told the party ended")
  local calEnd = take(calPeer, Wire.PARTY_END)
  ok(calEnd ~= nil, "the leaver hears party_end")
  eq(calEnd.reason, "left", "with reason left")
end

-- ------- square party PvP: mismatch decline, 2v2 and 3v3 ask

do
  local hub = Hub.new({ maxPlayers = 8 })
  local ann, annPeer = join(hub, "ANN")
  local bob, bobPeer = join(hub, "BOB")
  local cal, calPeer = join(hub, "CAL")
  local dee, deePeer = join(hub, "DEE")
  local eve, evePeer = join(hub, "EVE")

  partyForm(hub, ann, bob)
  take(annPeer, Wire.PARTY)
  take(bobPeer, Wire.PARTY)
  partyForm(hub, ann, cal)
  take(annPeer, Wire.PARTY)
  take(bobPeer, Wire.PARTY)
  take(calPeer, Wire.PARTY)

  partyForm(hub, dee, eve)
  take(deePeer, Wire.PARTY)
  take(evePeer, Wire.PARTY)

  hub:receive(ann, { type = Wire.COOP_CHALLENGE, to = dee.id })
  local mismatch = take(annPeer, Wire.COOP_DECLINE)
  ok(mismatch ~= nil, "3v2 challenge declines on the asker")
  eq(mismatch.reason, "mismatch", "with reason mismatch")
  eq(coopAskCount(hub), 0, "and no ask is created")
  eq(take(bobPeer, Wire.COOP_ASK), nil, "no partner is asked on mismatch")
end

do
  local hub = Hub.new({ maxPlayers = 8 })
  local ann, annPeer = join(hub, "ANN")
  local bob, bobPeer = join(hub, "BOB")
  local eve, evePeer = join(hub, "EVE")
  local fay, fayPeer = join(hub, "FAY")

  partyForm(hub, ann, bob)
  take(annPeer, Wire.PARTY)
  take(bobPeer, Wire.PARTY)
  partyForm(hub, eve, fay)
  take(evePeer, Wire.PARTY)
  take(fayPeer, Wire.PARTY)

  hub:receive(ann, { type = Wire.COOP_CHALLENGE, to = eve.id })
  eq(take(annPeer, Wire.COOP_DECLINE), nil, "2v2 challenge is not declined")
  ok(coopAskCount(hub) == 1, "2v2 opens one ask")
  ok(take(bobPeer, Wire.COOP_ASK) ~= nil, "the asker's partner is asked")
  ok(take(evePeer, Wire.COOP_ASK) ~= nil, "the challenged party is asked")
end

do
  local hub = Hub.new({ maxPlayers = 8 })
  local ann, annPeer = join(hub, "ANN")
  local bob, bobPeer = join(hub, "BOB")
  local cal, calPeer = join(hub, "CAL")
  local dee, deePeer = join(hub, "DEE")
  local eve, evePeer = join(hub, "EVE")
  local fay, fayPeer = join(hub, "FAY")

  partyForm(hub, ann, bob)
  take(annPeer, Wire.PARTY)
  take(bobPeer, Wire.PARTY)
  partyForm(hub, ann, cal)
  take(annPeer, Wire.PARTY)
  take(bobPeer, Wire.PARTY)
  take(calPeer, Wire.PARTY)

  partyForm(hub, dee, eve)
  take(deePeer, Wire.PARTY)
  take(evePeer, Wire.PARTY)
  partyForm(hub, dee, fay)
  take(deePeer, Wire.PARTY)
  take(evePeer, Wire.PARTY)
  take(fayPeer, Wire.PARTY)

  hub:receive(ann, { type = Wire.COOP_CHALLENGE, to = dee.id })
  eq(take(annPeer, Wire.COOP_DECLINE), nil, "3v3 challenge is not declined")
  ok(coopAskCount(hub) == 1, "3v3 opens one ask")
  ok(take(bobPeer, Wire.COOP_ASK) ~= nil, "every asker-side member is asked")
  ok(take(calPeer, Wire.COOP_ASK) ~= nil, "including the third traveller")
  ok(take(deePeer, Wire.COOP_ASK) ~= nil, "the challenged side is asked too")
end

do
  local hub = Hub.new({ maxPlayers = 4 })
  hub.forceBattleSeed = 1
  local ann, annPeer = join(hub, "ANN")
  local bob, bobPeer = join(hub, "BOB")

  hub:openCoopBattle("cw-catch", { ann.id, bob.id },
    { mode = "coop_wild", hostId = ann.id })
  local record = hub.battles["cw-catch"]

  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "cw-catch", chart = CHART })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "cw-catch", side = "a",
    mons = { mon() },
    bag = { { id = "MASTER_BALL", count = 1 } } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = "cw-catch", side = "a",
    mons = { mon({ species = "PARTNER" }) } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "cw-catch", side = "b",
    mons = { mon({ species = "PIDGEY", catchRate = 255 }) } })
  ok(record.sim ~= nil, "coop_wild sim starts with two humans and a wild party")
  ok(hub:isWildSeat(record, record.npcIds[1]),
     "coop_wild's synthetic seat is wildlife too")
  eq(record.sim.byId[record.npcIds[1]].bag, nil,
     "and it is seated with no bag either")
  take(annPeer, Wire.BATTLE_READY)
  take(bobPeer, Wire.BATTLE_READY)

  local outcome = nil
  for _ = 1, 20 do
    hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = "cw-catch",
      action = "item", item = "MASTER_BALL" })
    hub:receive(bob, { type = Wire.BATTLE_CHOICE, battle = "cw-catch",
      action = "fight", move = 0 })
    outcome = take(annPeer, Wire.BATTLE_OUTCOME)
      or take(bobPeer, Wire.BATTLE_OUTCOME)
    if outcome or not hub.battles["cw-catch"] then break end
  end

  ok(outcome ~= nil, "catch ends with a battle_outcome broadcast")
  ok(Wire.battleOutcome(outcome) ~= nil,
     "in a shape the client's sanitiser accepts")
  eq(outcome.reason, "catch", "catch success reasons the outcome as catch")
  eq(outcome.catcher, ann.id, "catcher names the thrower")
  ok(take(annPeer, Wire.BATTLE_OUTCOME) ~= nil
     or take(bobPeer, Wire.BATTLE_OUTCOME) ~= nil,
     "both players hear the outcome")
  eq(hub.battles["cw-catch"], nil, "the record is cleared like any other settlement")
end

-- ------- PROTOCOL 15: hub bag proofs hold until resolve; cancel drops hold

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann, annPeer = join(hub, "ANN")
  local bob = join(hub, "BOB")
  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  local id = ann.sessionId

  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART, seed = 7 })
  -- Unknown bag ids refuse the whole party sheet.
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id,
    mons = { mon({ hp = 40, maxHp = 100 }) },
    bag = { { id = "NOT_A_REAL_ITEM", count = 1 } } })
  eq(hub.battles[id].parties[ann.id], nil, "unknown bag id refuses the party")
  -- Vitamins are BattleSim-known: accepted on the bag sheet.
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id,
    mons = { mon({ hp = 40, maxHp = 100 }) },
    bag = { { id = "PROTEIN", count = 1 }, { id = "POTION", count = 1 },
            { id = "POKE_FLUTE", count = 1 } } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = id,
    mons = { mon({ hp = 100 }) } })
  local record = hub.battles[id]
  ok(record.sim ~= nil, "a fight opens with bag sheets")
  eq(record.bags[ann.id].PROTEIN, 1, "ann's uploaded bag holds one protein")
  eq(record.bags[ann.id].POTION, 1, "ann's uploaded bag holds one potion")
  eq(record.bags[bob.id].POTION, nil, "bob uploaded no bag: empty")

  hub:receive(bob, { type = Wire.BATTLE_CHOICE, battle = id,
    action = "item", item = "POTION" })
  eq(record.sim.byId[bob.id].choice, nil,
     "an item with no matching bag stack is refused silently")

  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id,
    action = "item", item = "POTION" })
  ok(record.sim.byId[ann.id].choice ~= nil, "a proved potion is accepted")
  eq(record.bags[ann.id].POTION, 1, "stack is held, not spent, until resolve")
  eq(record.bagHold[ann.id], "POTION", "hold names the pending item")

  -- Cancel before the foe answers: hold drops, stack stays.
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id, action = "cancel" })
  eq(record.sim.byId[ann.id].choice, nil, "cancel clears the filed choice")
  eq(record.bagHold[ann.id], nil, "and drops the bag hold")
  eq(record.bags[ann.id].POTION, 1, "without decrementing the bag")

  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id,
    action = "item", item = "POTION" })
  ok(record.sim.byId[ann.id].choice ~= nil, "potion can be filed again")
  hub:receive(bob, { type = Wire.BATTLE_CHOICE, battle = id,
    action = "fight", move = 0 })
  take(annPeer, Wire.BATTLE_EVENT)
  eq(record.bags[ann.id].POTION, nil, "resolve commits the hold and spends")

  -- Overdrawn: potion already spent.
  if record.sim and record.sim.phase == "choice" then
    hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id,
      action = "item", item = "POTION" })
    eq(record.sim.byId[ann.id].choice, nil,
       "a second potion after the stack is gone is refused")

    hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id,
      action = "item", item = "POKE_FLUTE" })
    ok(record.sim.byId[ann.id].choice ~= nil, "Poké Flute is proved present")
    eq(record.bags[ann.id].POKE_FLUTE, 1,
       "but never decremented (key item / noConsume)")
  end
end

-- ------------------------------------------------------------------
-- mid-fight learn / replace (PROTOCOL 28)
-- ------------------------------------------------------------------

do
  local hub = Hub.new({ maxPlayers = 4 })
  local fight = openFight(hub)
  local record = hub.battles[fight.id]
  ok(record.sim ~= nil, "the fight is live before the learn")
  local live = record.sim.byId[fight.ann.client.id].mons[1]
  live.moves = {
    { id = "OLD", pp = 10, power = 40, accuracy = 255, type = 0, effect = 0, chance = 0 },
  }
  local function payload(moves)
    return { mon = 0, moves = moves }
  end
  ok(hub:applyBattleMoveset(record, fight.ann.client, payload({
    { id = "OLD", pp = 99, power = 999, accuracy = 255, type = 0, effect = 0, chance = 0 },
    { id = "NEW", pp = 20, power = 80, accuracy = 255, type = 0, effect = 0, chance = 0,
      name = "New" },
  })), "an append of one slot is accepted")
  eq(live.moves[2] and live.moves[2].id, "NEW", "the Lua hub holds the learned move")
  eq(live.moves[1].pp, 10, "unchanged slot keeps hub PP")
  eq(live.moves[1].power, 40, "and hub power, not the client's rewrite")

  eq(hub:applyBattleMoveset(record, fight.ann.client, payload({
    { id = "AAA", pp = 20, power = 80, accuracy = 255, type = 0, effect = 0, chance = 0 },
    { id = "BBB", pp = 20, power = 80, accuracy = 255, type = 0, effect = 0, chance = 0 },
  })), false, "rewriting two slots is refused")
  eq(live.moves[1].id, "OLD", "...and the sheet is untouched")

  ok(hub:applyBattleMoveset(record, fight.ann.client, payload({
    { id = "OLD", pp = 10, power = 40, accuracy = 255, type = 0, effect = 0, chance = 0 },
    { id = "SWAP", pp = 15, power = 60, accuracy = 255, type = 0, effect = 0, chance = 0 },
  })), "replacing exactly one id is accepted")
  eq(live.moves[2].id, "SWAP", "...on the slot the next fight choice will execute")

  live.transformed = true
  eq(hub:applyBattleMoveset(record, fight.ann.client, payload({
    { id = "OLD", pp = 10, power = 40, accuracy = 255, type = 0, effect = 0, chance = 0 },
    { id = "SWAP", pp = 15, power = 60, accuracy = 255, type = 0, effect = 0, chance = 0 },
    { id = "NEW", pp = 20, power = 80, accuracy = 255, type = 0, effect = 0, chance = 0 },
  })), false, "a transformed battler is left alone")
end

-- Co-op mediated fights set battleId / coopBattleId, not sessionId. Treating
-- only sessionId as hub-busy published those players as free and delivered
-- a second ask a modified client could accept.
do
  local hub = Hub.new({ maxPlayers = 4 })
  local host, hostPeer = join(hub, "HOST")
  local ally, allyPeer = join(hub, "ALLY")
  local asker, askerPeer = join(hub, "ASKER")
  hostPeer.outbox, allyPeer.outbox, askerPeer.outbox = {}, {}, {}

  hub:receive(asker, { type = Wire.REQUEST, to = ally.id, kind = "trade" })
  ok(take(allyPeer, Wire.REQUEST) ~= nil, "the ask lands while they are free")

  hub:openCoopBattle("c-busy", { host.id, ally.id },
    { mode = "coop_npc", hostId = host.id })
  eq(ally.sessionId, nil, "co-op does not take a sessionId")
  ok(ally.battleId ~= nil, "it takes a battleId")
  ok(ally.coopBattleId ~= nil, "and a coopBattleId")
  eq((take(askerPeer, Wire.MOVE) or {}).busy, true,
     "the hub publishes them busy without anyone stepping")

  allyPeer.outbox, askerPeer.outbox = {}, {}
  hub:receive(ally, { type = Wire.RESPOND, to = asker.id, kind = "trade",
                      accept = true })
  eq((take(askerPeer, Wire.DECLINE) or {}).reason, "busy",
     "accepting after the fight opened is refused as busy")
  eq(take(allyPeer, Wire.SESSION), nil, "and starts no second session")

  askerPeer.outbox, allyPeer.outbox = {}, {}
  hub:receive(asker, { type = Wire.REQUEST, to = ally.id, kind = "battle" })
  eq((take(askerPeer, Wire.DECLINE) or {}).reason, "busy",
     "asking a fighter is declined at the hub")
  eq(take(allyPeer, Wire.REQUEST), nil, "and never reaches them")

  allyPeer.outbox, askerPeer.outbox = {}, {}
  hub:receive(ally, { type = Wire.REQUEST, to = asker.id, kind = "trade" })
  eq(take(askerPeer, Wire.REQUEST), nil,
     "a fighter's own ask is dropped rather than forwarded")

  askerPeer.outbox = {}
  hub:closeCoopBattle("c-busy")
  eq((take(askerPeer, Wire.MOVE) or {}).busy, false,
     "and publishing them free when the fight ends")
end

-- Each occupancy field is a gate on its own: a fight record without a
-- co-op group, or a group whose sim is already gone, must still look busy.
do
  local hub = Hub.new({ maxPlayers = 3 })
  local _, _hostPeer = join(hub, "HOST")
  local ally, allyPeer = join(hub, "ALLY")
  local asker, askerPeer = join(hub, "ASKER")
  allyPeer.outbox, askerPeer.outbox = {}, {}

  -- A live unsettled record, not a dangling pointer: unsettledBattle heals
  -- a stale battleId rather than treating it as occupancy.
  hub.battles["c-only"] = { id = "c-only", settled = false, memberIds = { ally.id } }
  ally.battleId = "c-only"
  hub:receive(asker, { type = Wire.REQUEST, to = ally.id, kind = "battle" })
  eq((take(askerPeer, Wire.DECLINE) or {}).reason, "busy",
     "battleId alone is hub-busy")
  eq(take(allyPeer, Wire.REQUEST), nil)

  ally.battleId = nil
  ally.coopBattleId = "c-group"
  askerPeer.outbox, allyPeer.outbox = {}, {}
  hub:receive(asker, { type = Wire.REQUEST, to = ally.id, kind = "battle" })
  eq((take(askerPeer, Wire.DECLINE) or {}).reason, "busy",
     "coopBattleId alone is hub-busy")
  eq(take(allyPeer, Wire.REQUEST), nil)
end

-- Wave 2 T2d: hub generation selects BattleSim vs BattleSim2 at Hub.new.
do
  local Turn1 = need("BattleSim/Turn")
  local Turn2 = need("BattleSim2/Turn")
  local gen1 = Hub.new({ maxPlayers = 4 })
  eq(gen1.generation, 1, "omitted generation defaults to 1")
  ok(gen1.Turn == Turn1, "generation 1 loads BattleSim/Turn")
  local gen2 = Hub.new({ maxPlayers = 4, generation = 2 })
  eq(gen2.generation, 2, "generation:2 is stored")
  ok(gen2.Turn == Turn2, "generation 2 loads BattleSim2/Turn")
  ok(gen2.Turn ~= Turn1, "Gen2 hub never holds Gen1 Turn")
end

-- ------- Gen 1 / Gen 2 read paths are what they were before Gen 3
--
-- Gen 3 added a move row keyed on `num` and two choice fields (`pass`,
-- `dexCaught`).  Neither may reach an older read: a stray `num` on a Gen 1 /
-- Gen 2 row is ignored as it always was -- rather than sending the row to the
-- Gen 3 reader, which refuses it for want of target / priority / flags -- and a
-- stray `pass` on an older choice is ignored rather than refusing the turn.
-- server/hub_battle.test.js pins the same on the Node twin.
do
  local stray = move()
  stray.num = 7
  local sheet = mon()
  sheet.moves = { stray }
  local clean = Wire.battleMon(sheet)
  ok(clean ~= nil, "a Gen 1 sheet whose row carries a stray num still reads")
  eq(clean and clean.moves[1].id, "thump", "as the older row")
  eq(clean and clean.moves[1].num, nil, "with the stray field left behind")
  local gold = mon()
  gold.stats = { atk = 200, def = 200, spe = 100, spa = 100, spd = 100 }
  gold.moves = { stray }
  local goldClean = Wire.battleMon(gold)
  eq(goldClean and goldClean.generation, 2, "a Gen 2 sheet with the same row reads too")
  eq(goldClean and goldClean.moves[1].num, nil, "in the older dialect")
  ok(Wire.battleParty({ battle = "b1", mons = { sheet } }, 1) ~= nil,
     "and a Gen 1 hub takes the party it sits in")
  for _, gen in ipairs({ 1, 2 }) do
    local rules = Wire.battleRuleset({ chart = CHART, metronomePool = { stray } }, gen)
    ok(rules ~= nil, "a Gen " .. gen .. " metronome pool row with a stray num reads")
    eq(rules and rules.metronomePool[1].num, nil, "as the older row on Gen " .. gen)
  end
  ok(Wire.battleRuleset({ chart = CHART, metronomePool = { stray } }) ~= nil,
     "and on a ruleset that names no hub generation")

  local asked = { battle = "b1", action = "fight", move = 0, pass = "far", dexCaught = 1 }
  for _, gen in ipairs({ 1, 2, "none" }) do
    local c = Wire.battleChoice(asked, gen ~= "none" and gen or nil)
    ok(c ~= nil, "a choice with Gen 3 fields in it is still a choice (" .. gen .. ")")
    eq(c and c.pass, nil, "whose stray pass is not read (" .. gen .. ")")
    eq(c and c.dexCaught, nil, "nor its dex word (" .. gen .. ")")
  end
  eq(Wire.battleChoice(asked, 3), nil, "while a Gen 3 hub refuses the same fields unread")

  -- On the hub: a Gen 1 fight files a turn whose choice carries a stray pass.
  local hub = Hub.new({ maxPlayers = 4 })
  local f = openFight(hub)
  local record = hub.battles[f.id]
  hub:receive(f.ann.client, { type = Wire.BATTLE_CHOICE, battle = f.id, action = "fight",
                              move = 0, pass = "far" })
  ok(record.sim.byId[f.ann.client.id].choice ~= nil, "a Gen 1 hub files that turn")

  -- Events, when the reader names its generation.
  eq(Wire.battleEvent({ battle = "b1", seq = 1, t = "ability" }, 1), nil,
     "a Gen 1 reader has no ability kind")
  ok(Wire.battleEvent({ battle = "b1", seq = 1, t = "ability" }) ~= nil,
     "(which a reader naming none still draws)")
  local ev = Wire.battleEvent({ battle = "b1", seq = 2, t = "stat", slot = 0, side = "a",
    target = 2, stage = 1, delta = 1, holding = 3 }, 2)
  ok(ev ~= nil and ev.target == nil and ev.delta == nil and ev.holding == nil,
     "a Gen 2 reader keeps none of Gen 3's other event fields")
  -- ...but `stage` it reads now: a `stat` event's signed stage is the older
  -- dialect's too (contract K10 of docs/plans/gen12-referee-gaps-fix.md).
  eq(ev and ev.stage, 1, "a Gen 2 reader keeps the signed stage (K10)")
  local mv = Wire.battleEvent({ battle = "b1", seq = 3, t = "moves", slot = 0, side = "a",
    moves = { stray } }, 1)
  eq(mv and mv.moves and mv.moves[1].id, "thump", "and reads a moves row in the older dialect")
end

-- ------------------------------------------------------------------
-- 12. Gen 3 (PROTOCOL 30): the hub referees on BattleSim3
-- ------------------------------------------------------------------
--
-- One Gen 3 hub seats FireRed, LeafGreen and Emerald, and a fight it brokers is
-- resolved by BattleSim3 against the Gen 3 dialect of every upload
-- (docs/plans/gen3-battle-sheet.md, contract C4): the ordered type table and
-- the packed move pool instead of a percent chart, sheets that carry abilities
-- and held items, and bags keyed by numeric pret item id.  server/hub_battle.test.js
-- pins the same fights on the Node twin, message for message.  Every number
-- below is synthetic except the pret enum values the sheet contract names.

local Turn3 = need("BattleSim3/Turn")

-- A tiny ordered chart: three super-effective rows, the Foresight sentinel,
-- and one ghost immunity behind it.
local CHART3 = { 10, 12, 20, 11, 10, 20, 12, 11, 20, -1, -1, 0, 0, 7, 0 }
local POOL3 = { "33:0:40:0:100:35:0:0:0:51:POOL_TAP", "52:4:40:10:100:25:10:0:0:18:POOL_SPARK" }

local function move3(o)
  o = o or {}
  return {
    id = o.id or "TAP3", num = o.num or 33, pp = o.pp or 20, maxPp = o.maxPp or 20,
    power = o.power or 90, type = o.type or 0, accuracy = o.accuracy or 100,
    effect = o.effect or 0, chance = o.chance or 0, target = o.target or 0,
    priority = o.priority or 0, flags = o.flags or 51, name = o.name,
  }
end

local function mon3(o)
  o = o or {}
  return {
    generation = 3, species = o.species or "GAMMA", speciesNum = o.speciesNum or 1,
    level = o.level or 50, hp = o.hp or 150, maxHp = o.maxHp or o.hp or 150,
    stats = { atk = o.atk or 120, def = o.def or 80, spe = o.spe or 90,
              spa = o.spa or 80, spd = o.spd or 80 },
    types = o.types or { 0 }, ability = o.ability or 0,
    heldItem = o.heldItem or 0, holdEffect = o.holdEffect or 0,
    holdEffectParam = o.holdEffectParam or 0, gender = o.gender or "M",
    friendship = 70, weight = 300, nature = 0,
    hiddenPower = { type = 1, power = 50 }, beatUp = { atk = 60, def = 60 },
    catchRate = o.catchRate,
    moves = o.moves or { move3() },
  }
end

local function bruiser3() return mon3({ atk = 400, def = 400, spe = 300, moves = { move3({ power = 200 }) } }) end
local function glassjaw3()
  return mon3({ species = "DELTA", hp = 1, def = 5, atk = 10, spe = 1, moves = { move3({ power = 10 }) } })
end

local function join3(hub, name, version)
  local peer = fakePeer()
  local client = hub:accept(peer)
  if client then
    hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
      name = name, map = "FR_PALLET_TOWN", x = 5, y = 5, facing = "down",
      generation = 3, version = version or "firered",
      playerId = testPlayerId(name) })
  end
  return client, peer
end

local function eventText(peer, needle)
  for _, msg in ipairs(peer.outbox) do
    if msg.type == Wire.BATTLE_EVENT and type(msg.text) == "string"
       and msg.text:find(needle, 1, true) then return true end
  end
  return false
end

-- ------- the hub picks its sim by generation

do
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  eq(hub.generation, 3, "generation:3 is stored")
  ok(hub.Turn == Turn3, "generation 3 loads BattleSim3/Turn")
  ok(hub.Effects == Wire.effectsFor(3), "and proves bags against Wire's Gen 3 catalog")
  ok(hub.Effects.itemEffect("13") ~= nil, "a numeric-string id reads the catalog")
  ok(hub.Effects.itemEffect(350).noConsume == true, "Poke Flute is never spent")
  eq(hub.Effects.itemEffect(5), nil, "the Safari Ball is not a mediated item")
end

-- ------- 1v1 PvP: ordered chart, Gen 3 sheets, a numeric bag, a KO

do
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  hub.forceBattleSeed = 7
  local ann, annPeer = join3(hub, "ANN", "firered")
  local bob, bobPeer = join3(hub, "BOB", "emerald")
  ok(ann and ann.ready and bob and bob.ready, "FireRed and Emerald meet on one Gen 3 hub")
  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  local id = ann.sessionId
  ok(id ~= nil and hub.battles[id] ~= nil, "the battle session opens a mediated record")

  -- A Gen 1 percent chart is not a Gen 3 ruleset: the hub reads its own dialect.
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART })
  eq(hub.battles[id].ruleset and hub.battles[id].ruleset.typeTable, nil,
     "a percent chart carries no ordered table on a Gen 3 hub")
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id,
                     typeTable = { 10, 12 } })
  eq(hub.battles[id].ruleset and hub.battles[id].ruleset.typeTable, nil,
     "a triple list cut mid-row is refused")
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, generation = 3,
                     typeTable = CHART3, movePool = POOL3 })
  local rules = hub.battles[id].ruleset
  ok(rules ~= nil and #rules.typeTable == #CHART3, "the ordered chart lands whole")
  eq(rules.movePool[1], POOL3[1], "and the packed pool survives canonical")

  -- Bags are numeric pret ids.  13 heals; 5 (the Safari Ball) is refused.
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, mons = { bruiser3() },
                     bag = { { id = 5, count = 1 } } })
  eq(hub.battles[id].parties[ann.id], nil, "a bag naming an unmediated item refuses the party")
  -- Hurt, so a potion has something to do (the sim refuses an item with no effect).
  local hurt = bruiser3()
  hurt.hp = 100
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id,
                     mons = { hurt },
                     bag = { { id = 13, count = 2, name = "TONIC" }, { id = "350", count = 1 } } })
  local noWeight = glassjaw3()
  noWeight.weight = nil
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = id, mons = { noWeight } })
  eq(hub.battles[id].parties[bob.id], nil, "an upload missing a Gen 3 formula input is refused")
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = id, mons = { glassjaw3() } })

  local record = hub.battles[id]
  ok(record.sim ~= nil, "the message that completes the set opens a Gen 3 fight")
  eq(record.bags[ann.id]["13"], 2, "the hub holds the bag keyed as a choice spells it")
  eq(record.sim.byId[ann.id].bag[13], 2, "and the sim holds it by numeric id")
  local ready = take(annPeer, Wire.BATTLE_READY)
  ok(ready ~= nil and Wire.battleReady(ready) ~= nil, "battle_ready goes out")
  local sawSend = false
  for _, msg in ipairs(annPeer.outbox) do
    if msg.type == Wire.BATTLE_EVENT then
      ok(Wire.battleEvent(msg) ~= nil, "every opening event survives the client sanitiser")
      if msg.t == "send" then sawSend = true end
    end
  end
  ok(sawSend, "and the opening sends are among them")

  -- The bag proof on a numeric-string id: held, cancel drops the hold, spent at resolve.
  hub:receive(bob, { type = Wire.BATTLE_CHOICE, battle = id, action = "item", item = "13" })
  eq(record.sim.byId[bob.id].choice, nil, "an item with no stack is refused")
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id, action = "item",
                     item = "13", slot = 0 })
  ok(record.sim.byId[ann.id].choice ~= nil, "a proved Gen 3 potion is filed")
  eq(record.bagHold[ann.id], "13", "and held, not spent")
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id, action = "cancel" })
  eq(record.bagHold[ann.id], nil, "cancel drops the hold")
  eq(record.bags[ann.id]["13"], 2, "without spending")
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id, action = "item",
                     item = "13", slot = 0 })
  annPeer.outbox = {}
  hub:receive(bob, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
  eq(record.bags[ann.id]["13"], 1, "the turn resolves and one potion is gone")
  ok(eventText(annPeer, "ANN used TONIC!"), "narrated under the name the bag uploaded")

  -- The Poke Flute is proved and never spent.
  if record.sim and record.sim.phase == "choice" then
    hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id, action = "item", item = "350" })
    ok(record.sim.byId[ann.id].choice ~= nil, "the flute is proved present")
    hub:receive(bob, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
    eq(record.bags[ann.id]["350"], 1, "and is still in the bag after the turn")
  end

  ok(fightItOut(hub, { { client = ann, battle = id }, { client = bob, battle = id } }),
     "the fight reaches an end")
  local outcome = take(annPeer, Wire.BATTLE_OUTCOME)
  ok(outcome ~= nil and Wire.battleOutcome(outcome) ~= nil, "the outcome goes out, sanitisable")
  eq(outcome and outcome.reason, "ko", "a KO")
  eq(outcome and outcome.winners[1], ann.id, "for the side that hit")
  ok(take(bobPeer, Wire.BATTLE_OUTCOME) ~= nil, "and the loser hears it")
  eq(hub.battles[id], nil, "the record is settled and forgotten")
end

-- ------- 2v2 against a trainer: one kit shared across both NPC seats

do
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  hub.forceBattleSeed = 3
  local ann, annPeer = join3(hub, "ANN")
  local bob = join3(hub, "BOB", "leafgreen")
  hub:openCoopBattle("g3c", { ann.id, bob.id }, { mode = "coop_npc", hostId = ann.id })
  local record = hub.battles["g3c"]
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "g3c", typeTable = CHART3 })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g3c", side = "a", mons = { bruiser3() } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = "g3c", side = "a", mons = { bruiser3() } })
  eq(record.sim, nil, "the trainer still owes a team")
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g3c", side = "b",
                     mons = { glassjaw3(), glassjaw3() },
                     bag = { { id = 22, count = 1, name = "KIT TONIC" } } })
  ok(record.sim ~= nil, "the host's side b completes the Gen 3 field")
  local bagA = record.sim.byId[record.npcIds[1]].bag
  local bagB = record.sim.byId[record.npcIds[2]].bag
  eq(bagA and bagA[22], 1, "the trainer's one potion, by numeric id")
  ok(bagA == bagB, "one table on both seats: spending it once spends it")
  eq(record.bags[record.npcIds[2]]["22"], 1, "and the hub sheet aliases it too")
  -- The kit's names travel with the shared bag: only the first seat was handed
  -- it, so the second used to open with no names and narrate "used an item!".
  local second = record.sim.byId[record.npcIds[2]]
  ok(second.bagNames == record.sim.byId[record.npcIds[1]].bagNames,
     "the second seat shares the first seat's bag names")
  eq(second.bagNames[22], "KIT TONIC", "so it knows the potion by the uploaded name")
  record.sim:drainEvents()
  second.choice = { action = "item", item = 22 }
  record.sim:_useItem(second)
  local narrated = false
  for _, event in ipairs(record.sim:drainEvents()) do
    if type(event.text) == "string" and event.text:find("TRAINER used KIT TONIC!", 1, true) then
      narrated = true
    end
  end
  ok(narrated, "and a potion drunk from the second seat is narrated by name")
  second.choice = nil

  ok(fightItOut(hub, { { client = ann, battle = "g3c" }, { client = bob, battle = "g3c" } }),
     "the trainer answers at once and the fight runs out")
  local outcome = take(annPeer, Wire.BATTLE_OUTCOME)
  ok(outcome ~= nil and Wire.battleOutcome(outcome) ~= nil, "outcome sanitisable")
  eq(outcome and outcome.outcome, "win", "the two players win")
  eq(outcome and outcome.losers[1], record.npcIds[1], "over the trainer's seats")
end

-- ------- a wild catch: numeric ball id, the caught sheet on the outcome

do
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  hub.forceBattleSeed = 11
  local ann, annPeer = join3(hub, "ANN", "emerald")
  local record = hub:openMediatedBattle("g3w", { mode = "wild", hostId = ann.id, memberIds = { ann.id } })
  ok(record ~= nil, "a Gen 3 wild record opens")
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "g3w", typeTable = CHART3,
                     weather = "RAIN", terrain = 3, underwater = true })
  ok(record.ruleset and record.ruleset.weather == "RAIN" and record.ruleset.underwater,
     "a wild ruleset keeps its weather and field")
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g3w", side = "a", mons = { mon3() },
                     bag = { { id = 1, count = 1 } } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g3w", side = "b",
                     mons = { mon3({ species = "EPSILON", catchRate = 45 }) } })
  ok(record.sim ~= nil, "the wild fight opens")
  eq(record.sim.field.weather, "RAIN", "under the overworld's rain")
  eq(record.sim.byId[record.npcIds[1]].bag, nil, "wildlife carries no bag")
  annPeer.outbox = {}
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = "g3w", action = "item", item = "1",
                     dexCaught = false })
  local sawBall = false
  for _, msg in ipairs(annPeer.outbox) do
    if msg.type == Wire.BATTLE_EVENT and msg.t == "ball" then
      sawBall = Wire.battleEvent(msg) ~= nil and msg.amount == 4 and msg.text == "1"
    end
  end
  ok(sawBall, "one ball event: four shakes, the ball named by its id")
  local outcome = take(annPeer, Wire.BATTLE_OUTCOME)
  local clean = outcome and Wire.battleOutcome(outcome)
  ok(clean ~= nil, "the catch outcome survives the client sanitiser")
  eq(clean and clean.reason, "catch", "reason catch")
  eq(clean and clean.catcher, ann.id, "caught by the thrower")
  eq(clean and clean.caught and clean.caught.species, "EPSILON", "the wild sheet rides along")
  eq(clean and clean.caught and clean.caught.ball, 1, "with the ball it went into")
  eq(clean and clean.caught and clean.caught.generation, 3, "read in the Gen 3 dialect")
end

-- ------- mid-fight learn on Gen 3: the row keeps num / target / priority / flags

do
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  local ann = join3(hub, "ANN")
  local bob = join3(hub, "BOB")
  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  local id = ann.sessionId
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, typeTable = CHART3 })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, mons = { mon3() } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = id, mons = { mon3() } })
  local record = hub.battles[id]
  local fighter = record.sim.byId[ann.id]
  local learned = move3({ id = "SHIELD3", num = 182, power = 0, accuracy = 0,
                          effect = 111, target = 16, priority = 3, flags = 0 })
  hub:receive(ann, { type = Wire.BATTLE_MOVESET, battle = id, mon = 0,
                     moves = { move3(), learned } })
  local row = fighter.mons[1].moves[2]
  eq(row and row.num, 182, "the learned row keeps its move number")
  eq(row and row.priority, 3, "its priority")
  eq(row and row.target, 16, "and its target")
  ok(fighter.b.moves == fighter.mons[1].moves, "the active battler fights with the new list")
  eq(fighter.mons[1].moves[1].pp, 20, "the unchanged slot keeps the hub's PP")
end

-- ------- the Gen 3 dialect at the boundary, and the limits a full upload meets

do
  -- A worst-case ruleset: the full ordered table and a full pool of long ids.
  local tt = {}
  for i = 1, Config.BATTLE_TYPE_TABLE3_MAX do
    tt[#tt + 1] = i % 18; tt[#tt + 1] = (i * 7) % 18; tt[#tt + 1] = 20
  end
  local pool = {}
  for i = 1, Config.BATTLE_MOVE_POOL3_MAX do
    pool[i] = table.concat({ (i % 354) + 1, 213, 255, 17, 100, 99, 100, 255, -7, 63,
      string.rep("X", 36) .. string.format("%04d", i) }, ":")
  end
  local rules = { type = Wire.BATTLE_RULESET, battle = "b1", generation = 3,
                  typeTable = tt, movePool = pool, terrain = 9, weather = "HAIL" }
  ok(Wire.payloadOk(rules), "a full Gen 3 ruleset is inside PAYLOAD_MAX_NODES")
  local clean = Wire.battleRuleset(rules, 3)
  ok(clean ~= nil, "and the sanitiser takes it whole")
  eq(clean and #clean.movePool, Config.BATTLE_MOVE_POOL3_MAX, "every pool entry kept")
  local over = {}
  for i = 1, #pool do over[i] = pool[i] end
  over[#over + 1] = pool[1]
  eq(#Wire.battleRuleset({ typeTable = tt, movePool = over }, 3).movePool,
     Config.BATTLE_MOVE_POOL3_MAX, "a pool past the cap keeps the cap")
  local big = {}
  for i = 1, 3 * (Config.BATTLE_TYPE_TABLE3_MAX + 1) do big[i] = 0 end
  eq(Wire.battleRuleset({ typeTable = big }, 3), nil, "a table past its cap is refused")
  eq(Wire.battleRuleset({ typeTable = { 0, -1, 10 } }, 3), nil,
     "half a sentinel is refused")
  eq(Wire.battleRuleset({ typeTable = CHART3, movePool = { "1:2:3" } }, 3), nil,
     "a pool entry that does not parse refuses the ruleset")
  eq(Wire.battleRuleset({ typeTable = CHART3, weather = "FOG" }, 3), nil,
     "an unknown weather refuses it")
  eq(Wire.battleRuleset({ generation = 3, typeTable = CHART3, movePool = { "+7:0:40:0:100:10:0:0:-0:3:X" } }), nil,
     "a signed-plus integer is not the sim's grammar")
  ok(Wire.battleRuleset({ generation = 3, movePool = { "7:0:40:0:100:10:0:0:-0:3:X" } }).movePool[1]
     == "7:0:40:0:100:10:0:0:0:3:X", "and -0 is written back as 0")

  -- A full six-mon Gen 3 party with a full bag.
  local mons = {}
  for i = 1, Config.BATTLE_MON_MAX do
    local m = mon3({ moves = { move3(), move3({ id = "B" }), move3({ id = "C" }), move3({ id = "D" }) } })
    m.speciesId = tostring(i); m.slot = i - 1; m.abilityName = "ABILITYNAME"; m.itemName = "ITEMNAME"
    m.ivs = { hp = 31, atk = 31, def = 31, spe = 31, spa = 31, spd = 31 }
    m.evs = { hp = 255, atk = 255, def = 0, spe = 0, spa = 0, spd = 0 }
    m.personality = 4294967295; m.otId = 12345
    mons[i] = m
  end
  local bag = {}
  local ids = { 1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
    24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41 }
  for i, n in ipairs(ids) do bag[i] = { id = n, count = 99, name = "ITEM" .. n } end
  local party = { type = Wire.BATTLE_PARTY, battle = "b1", generation = 3, mons = mons, bag = bag }
  ok(Wire.payloadOk(party), "a full Gen 3 party is inside PAYLOAD_MAX_NODES")
  local cp = Wire.battleParty(party, 3)
  ok(cp ~= nil and #cp.mons == 6 and #cp.bag == #ids, "and sanitises whole")

  -- The sheet's own checks.
  local noAbility = mon3(); noAbility.ability = nil
  eq(Wire.battleMon(noAbility), nil, "a Gen 3 sheet without an ability is refused")
  local badGender = mon3(); badGender.gender = "X"
  eq(Wire.battleMon(badGender), nil, "a gender outside M/F/U is refused")
  local caught = mon3(); caught.weight, caught.hiddenPower, caught.beatUp = nil, nil, nil
  ok(Wire.battleMon(caught) ~= nil, "a caught sheet without the upload-only inputs still reads")
  eq(Wire.battleParty({ battle = "b1", mons = { caught } }, 3), nil,
     "but an upload without them does not")
  eq(Wire.battleParty({ battle = "b1", mons = { mon3() }, generation = 2 }, 3), nil,
     "a party claiming another generation is refused on a Gen 3 hub")
  local mixed = { generation = 2, species = "OLDER", level = 50, hp = 100, maxHp = 100,
    stats = { atk = 50, def = 50, spe = 50, spa = 50, spd = 50 }, moves = { move() } }
  ok(Wire.battleMon(mixed) ~= nil, "(a well-formed Gen 2 sheet on its own)")
  eq(Wire.battleParty({ battle = "b1", generation = 3, mons = { mon3(), mixed } }), nil,
     "and a Gen 3 party with a Gen 2 sheet in it is refused")
  eq(Wire.battleBag({ ["13"] = 2, ["22"] = 1 }, 3)[1].id, 13, "the map form reads numeric-string keys")
  eq(Wire.battleBag({ { id = "0x0D", count = 1 } }, 3), nil, "a hex id is not an item id")
  eq(Wire.battleBag({ { id = 13, count = 1 }, { id = "13", count = 1 } }, 3), nil,
     "the same item twice is refused")

  -- Choices and events.  Gen 3's two choice fields are read on a Gen 3 hub.
  local c = Wire.battleChoice({ battle = "b1", action = "fight", move = 0, pass = 2 }, 3)
  eq(c and c.pass, 2, "a Baton Pass destination rides the fight choice")
  eq(Wire.battleChoice({ battle = "b1", action = "fight", move = 0, pass = 6 }, 3), nil,
     "outside the party it is refused")
  local ic = Wire.battleChoice({ battle = "b1", action = "item", item = "9", dexCaught = true }, 3)
  eq(ic and ic.dexCaught, true, "Repeat Ball's dex word rides the item choice")
  eq(Wire.battleChoice({ battle = "b1", action = "item", item = "9", dexCaught = 1 }, 3), nil,
     "and only as a boolean")
  local ev = Wire.battleEvent({ battle = "b1", seq = 3, t = "stat", slot = 0, side = "a",
    text = "ATK fell", stat = "atk", stage = -2, delta = -2 })
  ok(ev ~= nil and ev.stat == "atk" and ev.stage == -2 and ev.delta == -2,
     "a Gen 3 stat event keeps its signed stage and delta")
  local held = Wire.battleEvent({ battle = "b1", seq = 4, t = "held", slot = 3, side = "b",
    mon = 0, amount = 139, holding = 0, text = "BERRY" })
  ok(held ~= nil and held.holding == 0 and held.amount == 139, "a held event keeps what is left held")
  local anim = Wire.battleEvent({ battle = "b1", seq = 5, t = "anim", slot = 0, side = "a",
    text = "SWEEP", target = 4, spread = 1 })
  ok(anim ~= nil and anim.target == 4 and anim.spread == 1, "an anim keeps its target and spread")
  local ball = Wire.battleEvent({ battle = "b1", seq = 6, t = "ball", slot = 0, side = "a",
    target = 3, amount = 2, text = "4" })
  ok(ball ~= nil and ball.text == "4", "a ball names its id like an item does")
  for _, kind in ipairs({ "ability", "weather", "form", "sub" }) do
    ok(Wire.battleEvent({ battle = "b1", seq = 7, t = kind }) ~= nil, "kind " .. kind .. " is in the vocabulary")
  end
  local mv = Wire.battleEvent({ battle = "b1", seq = 8, t = "moves", slot = 0, side = "a",
    moves = { move3() } })
  eq(mv and mv.moves and mv.moves[1].num, 33, "a Gen 3 moves event keeps its rows' numbers")
end

-- ------- Gen 3 Pay Day and the holders-only exp fact (sheet doc §1, §7.1)
--
-- A 2v2 against a trainer.  ANN's PAYER scatters coins every turn; BOB's
-- BOOMER blows itself up to take the first trainer mon with it, so BOB's seat
-- fought that knockout with nobody left standing who did -- the holders-only
-- fact (`participants` 0, no `mon`) goes to it, while ANN's fighter is paid as
-- the one participant.  BOB sends his second mon, PAYER finishes the second
-- trainer mon, and the outcome carries the coins of all three Pay Days to both
-- players (side a is every human in the fight).  server/hub_battle.test.js
-- pins the same fight on the Node twin.

local IDLE3 = { id = "IDLE", num = 150, effect = 85, power = 0, target = 16, flags = 0 }

do
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  hub.forceBattleSeed = 1
  local ann, annPeer = join3(hub, "ANN")
  local bob, bobPeer = join3(hub, "BOB", "emerald")
  hub:openCoopBattle("g3pay", { ann.id, bob.id }, { mode = "coop_npc", hostId = ann.id })
  local record = hub.battles["g3pay"]
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "g3pay", typeTable = CHART3 })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g3pay", side = "a", mons = {
    mon3({ species = "PAYER", level = 40, spe = 300, atk = 50,
           moves = { move3({ id = "COINS", num = 6, effect = 34, power = 20, chance = 100 }) } }) } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = "g3pay", side = "a", mons = {
    mon3({ species = "BOOMER", spe = 200, atk = 999,
           moves = { move3({ id = "BLAST", num = 153, effect = 7, power = 250 }) } }),
    mon3({ species = "SHARER", heldItem = 182, holdEffect = 25, moves = { move3(IDLE3) } }) } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g3pay", side = "b", mons = {
    mon3({ species = "TRAINEE", def = 5, spe = 1, moves = { move3(IDLE3) } }),
    mon3({ species = "TRAINEE", def = 5, spe = 1, moves = { move3(IDLE3) } }) } })
  ok(record.sim ~= nil, "pay day: the Gen 3 coop_npc field opens")
  annPeer.outbox, bobPeer.outbox = {}, {}

  local exps, outcome = {}, nil
  for _ = 1, 8 do
    if not hub.battles["g3pay"] then break end
    if record.sim.byId[bob.id].mustReplace then
      hub:receive(bob, { type = Wire.BATTLE_CHOICE, battle = "g3pay", action = "switch", slot = 1 })
    end
    hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = "g3pay", action = "fight", move = 0 })
    hub:receive(bob, { type = Wire.BATTLE_CHOICE, battle = "g3pay", action = "fight", move = 0 })
    for _ = 1, 64 do
      local msg = take(annPeer, Wire.BATTLE_EVENT)
      if not msg then break end
      if msg.t == "exp" then exps[#exps + 1] = msg end
    end
    outcome = take(annPeer, Wire.BATTLE_OUTCOME)
    if outcome then break end
  end

  -- The first knockout: ANN's fighter, and BOB's holders-only fact.
  local first, holders = nil, nil
  for _, e in ipairs(exps) do
    if e.slot == 0 and not first then first = e end
    if e.slot == 1 and e.participants == 0 and not holders then holders = e end
  end
  eq(first and first.participants, 1, "pay day: the fighter still standing is the one participant")
  eq(first and first.mon, 0, "pay day: ...and names its party index")
  ok(holders ~= nil, "pay day: the seat whose fighter fell gets the holders-only fact")
  eq(holders and holders.mon, nil, "pay day: ...with no mon (nobody of it that fought stands)")
  local clean = holders and Wire.battleEvent(holders, 3)
  eq(clean and clean.participants, 0, "pay day: a Gen 3 reader keeps the zero")
  eq(clean and clean.mon, nil, "pay day: ...and still no mon")
  local older = holders and Wire.battleEvent(holders, 2)
  eq(older and older.participants, nil, "pay day: a Gen 2 reader drops the zero, as it always has")

  ok(outcome ~= nil, "pay day: the trainer's side falls")
  eq(outcome and outcome.outcome, "win", "pay day: the players win")
  eq(outcome and outcome.reason, "ko", "pay day: by knockout")
  eq(outcome and outcome.payDay, 600, "pay day: three Pay Days at level 40 is 3 x 200 coins")
  local atBob = take(bobPeer, Wire.BATTLE_OUTCOME)
  eq(atBob and atBob.payDay, 600, "pay day: both players on side a hear the coins")
  local read = outcome and Wire.battleOutcome(outcome, 3)
  eq(read and read.payDay, 600, "pay day: the Gen 3 outcome reader keeps it")
  -- An older reader reads it too since contract K11 (Red and Gold report
  -- their own Pay Day coins), under its own cart's PAYDAY12_MAX bound.
  eq(outcome and Wire.battleOutcome(outcome, 1).payDay, 600, "pay day: a Gen 1 reader reads it too (K11)")
  eq(hub.battles["g3pay"], nil, "pay day: the record settles and clears")
end

-- ------- ...and a fight between players pays nobody: the coins are counted,
-- the outcome carries none (link rules), and neither does a Gen 1 hub's.
do
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  hub.forceBattleSeed = 1
  local ann, annPeer = join3(hub, "ANN")
  local bob, bobPeer = join3(hub, "BOB", "leafgreen")
  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  local id = ann.sessionId
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, typeTable = CHART3 })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, mons = {
    mon3({ species = "PAYER", level = 40, spe = 300, atk = 400,
           moves = { move3({ id = "COINS", num = 6, effect = 34, power = 60, chance = 100 }) } }) } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = id, mons = {
    mon3({ species = "DELTA", def = 5, spe = 1, moves = { move3(IDLE3) } }) } })
  local record = hub.battles[id]
  local outcome = nil
  for _ = 1, 6 do
    if not hub.battles[id] then break end
    hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
    hub:receive(bob, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
    outcome = take(annPeer, Wire.BATTLE_OUTCOME) or take(bobPeer, Wire.BATTLE_OUTCOME)
    if outcome then break end
  end
  ok(record.sim:snapshot().payDay.a > 0, "pvp pay day: the referee counted the coins")
  eq(outcome and outcome.outcome, "win", "pvp pay day: the fight ends")
  eq(outcome and outcome.payDay, nil, "pvp pay day: and the outcome pays nobody")

  local gen1 = Hub.new({ maxPlayers = 4 })
  gen1.forceBattleSeed = 1
  local a1, a1Peer = join(gen1, "ANN")
  local b1, b1Peer = join(gen1, "BOB")
  gen1:openCoopBattle("g1c", { a1.id, b1.id }, { mode = "coop_npc", hostId = a1.id })
  gen1:receive(a1, { type = Wire.BATTLE_RULESET, battle = "g1c", chart = CHART })
  gen1:receive(a1, { type = Wire.BATTLE_PARTY, battle = "g1c", side = "a", mons = { bruiser() } })
  gen1:receive(b1, { type = Wire.BATTLE_PARTY, battle = "g1c", side = "a", mons = { bruiser() } })
  gen1:receive(a1, { type = Wire.BATTLE_PARTY, battle = "g1c", side = "b", mons = { glassjaw(), glassjaw() } })
  fightItOut(gen1, { { client = a1, battle = "g1c" }, { client = b1, battle = "g1c" } })
  local g1 = take(a1Peer, Wire.BATTLE_OUTCOME) or take(b1Peer, Wire.BATTLE_OUTCOME)
  eq(g1 and g1.outcome, "win", "gen 1 coop_npc: the players win")
  local keys = {}
  for k in pairs(g1 or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  eq(table.concat(keys, ","), "battle,losers,outcome,reason,type,winners",
     "gen 1 coop_npc: the outcome is the fields it always was, no payDay")
end

-- ------- whose cart: each human seat's `family` is the hub's word, from its hello
--
-- Obedience has one rule that differs by cart (docs/plans/gen3-badge-rules.md
-- §1.2): Focus Punch skips the random-move branch on FireRed / LeafGreen and
-- not on Emerald, so the referee reads a fighter entry's `family`.  One Gen 3
-- hub seats both carts, and a hub that left the field off played every
-- Emerald mon by FireRed's rule.  The hub stamps each human seat with the cart
-- its own hello named; a party claiming a family is not read; an NPC seat gets
-- none; a link fight's referee drops it with the badges; a Gen 1 hub never
-- writes the field (Gold's own, contract K6, is pinned further down).
-- server/hub_battle.test.js pins the same on the Node twin.

-- Turn.create's options as the hub assembled them, the field still built by
-- the real referee: the fighter entries are what these blocks look at.
local function spyCreate(hub)
  local real, seen = hub.Turn, {}
  hub.Turn = setmetatable({
    create = function(opts) seen.opts = opts; return real.create(opts) end,
  }, { __index = real })
  return seen
end

local function entryOf(seen, side, playerId)
  for _, entry in ipairs(seen.opts and seen.opts.sides[side] or {}) do
    if entry.playerId == playerId then return entry end
  end
  return nil
end

local FOCUS3 = { id = "FOCUS3", num = 264, effect = 170, power = 150, type = 1,
                 priority = -3, flags = 35 }

-- A level-100 mon from another trainer: over the no-badge cap of 10, so every
-- move it is told to use asks the obedience roll first.
local function tradee3()
  local m = mon3({ species = "TRADEE", level = 100, moves = { move3(FOCUS3), move3() } })
  m.traded = true
  return m
end

-- Emerald and FireRed side by side against a trainer.
do
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  hub.forceBattleSeed = 3
  local seen = spyCreate(hub)
  local ann = join3(hub, "ANN", "emerald")
  local bob = join3(hub, "BOB", "firered")
  hub:openCoopBattle("g3f", { ann.id, bob.id }, { mode = "coop_npc", hostId = ann.id })
  local record = hub.battles["g3f"]
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "g3f", typeTable = CHART3 })
  local annMon = tradee3()
  annMon.unfateful = true
  -- Each upload claims the other cart's family: no party field decides it.
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g3f", side = "a", family = "frlg",
                     badges = { "1", "3" }, mons = { annMon } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = "g3f", side = "a", family = "rse",
                     mons = { bruiser3() } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g3f", side = "b",
                     mons = { glassjaw3(), glassjaw3() } })
  ok(record.sim ~= nil, "family: the mixed-cart coop_npc field opens")
  local annEntry, bobEntry = entryOf(seen, "a", ann.id), entryOf(seen, "a", bob.id)
  eq(annEntry and annEntry.family, "rse", "family: the Emerald player's entry is rse")
  eq(bobEntry and bobEntry.family, "frlg", "family: the FireRed player's entry is frlg")
  for _, npcId in ipairs(record.npcIds) do
    local npc = entryOf(seen, "b", npcId)
    ok(npc ~= nil and npc.family == nil, "family: an NPC seat's entry has none (" .. npcId .. ")")
  end
  -- What the hub was handed reaches the entry unchanged: the badges as the set
  -- the sanitiser rebuilt, the sheet's traded / unfateful on the mon itself.
  ok(annEntry and annEntry.badges and annEntry.badges["1"] == true and annEntry.badges["3"] == true,
     "family: the uploaded badges ride the entry")
  eq(annEntry and annEntry.mons[1].traded, true, "family: the mon's traded flag rides the entry")
  eq(annEntry and annEntry.mons[1].unfateful, true, "family: and its unfateful flag")
  local annFighter, bobFighter = record.sim.byId[ann.id], record.sim.byId[bob.id]
  eq(annFighter.family, "rse", "family: the referee plays Emerald's rule for ANN")
  eq(bobFighter.family, "frlg", "family: and FireRed's for BOB")
  eq(annFighter.badgeRules, true, "family: against the computer, badge rules apply")
  ok(annFighter.badges and annFighter.badges[1] and annFighter.badges[3] and not annFighter.badges[2],
     "family: with ANN's own badges 1 and 3")
  eq(bobFighter.badges, nil, "family: and none for BOB, who brought none")
  eq(annFighter.mons[1].traded, true, "family: the referee's mon is still traded")
end

-- The rule it decides, end to end: the same fight, the same seed, only ANN's
-- cart differs.  Her traded Focus Punch user disobeys on the first turn, and
-- the second roll lands under the cap -- Emerald answers with another move,
-- FireRed's exemption skips that branch and she naps instead.  Seed 10 was
-- found by a probe; the Node twin draws the same.
local function focusPunchObey(version)
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  hub.forceBattleSeed = 10
  local ann, annPeer = join3(hub, "ANN", version)
  local bob = join3(hub, "BOB", "firered")
  hub:openCoopBattle("g3o", { ann.id, bob.id }, { mode = "coop_npc", hostId = ann.id })
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "g3o", typeTable = CHART3 })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g3o", side = "a", mons = { tradee3() } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = "g3o", side = "a",
                     mons = { mon3({ moves = { move3(IDLE3) } }) } })
  local wall = function() return mon3({ species = "TRAINEE", hp = 900, moves = { move3(IDLE3) } }) end
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g3o", side = "b", mons = { wall(), wall() } })
  if not hub.battles["g3o"].sim then return nil end
  annPeer.outbox = {}
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = "g3o", action = "fight", move = 0 })
  hub:receive(bob, { type = Wire.BATTLE_CHOICE, battle = "g3o", action = "fight", move = 0 })
  local tokens = {}
  for _, msg in ipairs(annPeer.outbox) do
    if msg.type == Wire.BATTLE_EVENT and msg.t == "obey" and msg.side == "a" then
      tokens[#tokens + 1] = msg.text
    end
  end
  return table.concat(tokens, ",")
end

eq(focusPunchObey("emerald"), "uses_random_move",
   "family: an Emerald mon's Focus Punch can be swapped for another move")
eq(focusPunchObey("firered"), "falls_asleep",
   "family: a FireRed mon's is exempt from that branch, same seed")

-- A link fight: the entries still say whose cart, and the referee reads none of
-- it -- no badge rules, no badges, no family, and nobody disobeys.
do
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  hub.forceBattleSeed = 10
  local seen = spyCreate(hub)
  local ann, annPeer = join3(hub, "ANN", "emerald")
  local bob = join3(hub, "BOB", "firered")
  local cal = join3(hub, "CAL", "leafgreen")
  local dee = join3(hub, "DEE", "emerald")
  hub:openCoopBattle("g3p", { ann.id, bob.id, cal.id, dee.id }, { mode = "coop_pvp", hostId = ann.id })
  local record = hub.battles["g3p"]
  eq(record and record.mode, "coop_pvp", "family pvp: a four-player link fight opens")
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "g3p", typeTable = CHART3 })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g3p", badges = { "1", "2", "3" },
                     mons = { tradee3() } })
  for _, who in ipairs({ bob, cal, dee }) do
    hub:receive(who, { type = Wire.BATTLE_PARTY, battle = "g3p", badges = { "8" },
                       mons = { mon3({ hp = 900, moves = { move3(IDLE3) } }) } })
  end
  ok(record.sim ~= nil, "family pvp: the field opens")
  eq(entryOf(seen, "a", ann.id).family, "rse", "family pvp: the entry still names ANN's cart")
  eq(entryOf(seen, "b", cal.id).family, "frlg", "family pvp: on either side")
  for _, who in ipairs({ ann, bob, cal, dee }) do
    local fighter = record.sim.byId[who.id]
    ok(fighter.badgeRules == nil and fighter.badges == nil and fighter.family == nil,
       "family pvp: the referee plays link rules for " .. who.name)
  end
  annPeer.outbox = {}
  for _, who in ipairs({ ann, bob, cal, dee }) do
    hub:receive(who, { type = Wire.BATTLE_CHOICE, battle = "g3p", action = "fight", move = 0 })
  end
  ok(count(annPeer, Wire.BATTLE_EVENT) > 0, "family pvp: the turn resolves")
  local obeyed = 0
  for _, msg in ipairs(annPeer.outbox) do
    if msg.type == Wire.BATTLE_EVENT and msg.t == "obey" then obeyed = obeyed + 1 end
  end
  eq(obeyed, 0, "family pvp: and the over-cap traded mon is not asked to obey")
end

-- Gen 1: no field at all -- it is Gen 2's and Gen 3's (no Kanto rule reads one).
do
  local hub = Hub.new({ maxPlayers = 4 })
  hub.forceBattleSeed = 1
  local seen = spyCreate(hub)
  local ann = hub:accept(fakePeer())
  hub:receive(ann, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "ANN", map = "PALLET",
                     x = 5, y = 5, facing = "down", version = "red", playerId = testPlayerId("ANN") })
  local bob = join(hub, "BOB")
  eq(ann.version, "red", "family gen 1: the hello's cart is recorded")
  hub:openCoopBattle("g1f", { ann.id, bob.id }, { mode = "coop_npc", hostId = ann.id })
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "g1f", chart = CHART })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g1f", side = "a", mons = { bruiser() } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = "g1f", side = "a", mons = { bruiser() } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g1f", side = "b", mons = { glassjaw(), glassjaw() } })
  ok(hub.battles["g1f"].sim ~= nil, "family gen 1: the coop_npc field opens")
  local entries = 0
  for _, side in ipairs({ "a", "b" }) do
    for _, entry in ipairs(seen.opts.sides[side]) do
      entries = entries + 1
      eq(entry.family, nil, "family gen 1: no entry carries one (" .. entry.playerId .. ")")
    end
  end
  eq(entries, 4, "family gen 1: all four seats were looked at")
end

-- ------- Gold's badge type boost: the ruleset's `typeIds` reaches the referee
--
-- BattleSim2 ports DoBadgeTypeBoosts (keyed by type), but a move row carries
-- only its chart index; the ruleset's `typeIds` -- MediatedBattle.snapshotRuleset's
-- chart axis by name -- is what names it.  The hub hands it to Turn.create, so
-- a HIVE owner's BUG move hits harder in coop_npc; a badge for another type
-- does nothing to it, and with no typeIds nothing can be named and nothing
-- fires.  server/hub_battle.test.js pins the same on the Node twin.
local function join2(hub, name)
  local peer = fakePeer()
  local client = hub:accept(peer)
  if client then
    hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
      name = name, map = "NEW_BARK_TOWN", x = 5, y = 5, facing = "down",
      generation = 2, version = "gold", playerId = testPlayerId(name) })
  end
  return client, peer
end

-- The type axis: 0 is a type no badge names, 1 is BUG (HIVE's), 2 is FIRE.
local CHART2 = { { 100, 100, 100 }, { 100, 100, 100 }, { 100, 100, 100 } }
local TYPE_IDS2 = { "DARK", "BUG", "FIRE" }

local function sheet2(o)
  return { species = o.species or "ALPHA", level = 50, hp = o.hp or 300, maxHp = o.hp or 300,
           stats = { atk = o.atk or 100, def = o.def or 100, spe = o.spe or 50, spa = 50, spd = 100 },
           moves = { { id = o.move or "thump", pp = 20, power = o.power or 1, accuracy = 255,
                       type = o.type or 0, effect = 0, chance = 0 } } }
end

-- What ANN's BUG move dealt the NPC at field 3, the ruleset and her badges as
-- given.  BOB aims at the other NPC, so field 3's only hit is hers.
local function bugHit(badges, typeIds)
  local hub = Hub.new({ maxPlayers = 4, generation = 2 })
  hub.forceBattleSeed = 5
  local seen = spyCreate(hub)
  local ann, annPeer = join2(hub, "ANN")
  local bob = join2(hub, "BOB")
  hub:openCoopBattle("g2t", { ann.id, bob.id }, { mode = "coop_npc", hostId = ann.id })
  local record = hub.battles["g2t"]
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "g2t", chart = CHART2,
                     typeIds = typeIds, specialTypes = { 2 } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g2t", side = "a", badges = badges,
                     mons = { sheet2({ spe = 200, power = 50, type = 1, move = "bugbite" }) } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = "g2t", side = "a",
                     mons = { sheet2({ spe = 100 }) } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g2t", side = "b",
                     mons = { sheet2({ species = "WALL", hp = 900, spe = 1 }),
                              sheet2({ species = "WALL", hp = 900, spe = 1 }) } })
  if not record.sim then return nil, record, seen end
  annPeer.outbox = {}
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = "g2t", action = "fight", move = 0, target = 3 })
  hub:receive(bob, { type = Wire.BATTLE_CHOICE, battle = "g2t", action = "fight", move = 0, target = 4 })
  for _, msg in ipairs(annPeer.outbox) do
    if msg.type == Wire.BATTLE_EVENT and msg.t == "damage" and msg.slot == 3 then
      return msg.amount, record, seen
    end
  end
  return false, record, seen
end

do
  local boosted, record, seen = bugHit({ "HIVE" }, TYPE_IDS2)
  ok(record and record.sim ~= nil, "typeIds: the Gen 2 coop_npc field opens")
  eq(table.concat(seen.opts and seen.opts.typeIds or {}, ","), "DARK,BUG,FIRE",
     "typeIds: the hub hands the uploaded axis to Turn.create")
  eq(table.concat(record.sim.typeIds or {}, ","), "DARK,BUG,FIRE", "typeIds: and the referee keeps it")
  local annFighter = record.sim.byId[testPlayerId("ANN")]
  ok(annFighter and annFighter.badges and annFighter.badges.HIVE == true,
     "typeIds: ANN's fighter holds HIVE")
  local plain = bugHit(nil, TYPE_IDS2)
  ok(type(boosted) == "number" and type(plain) == "number", "typeIds: ANN's BUG move lands on field 3")
  ok(boosted > plain, ("typeIds: HIVE boosts a BUG move (%s > %s)"):format(tostring(boosted), tostring(plain)))
  -- FOG: GHOST's type badge, and none of Gold's stat badges (ZEPHYR would raise
  -- Attack, BadgeStatBoosts).
  eq(bugHit({ "FOG" }, TYPE_IDS2), plain, "typeIds: a badge for another type does nothing to it")
  eq(bugHit({ "HIVE" }, nil), plain, "typeIds: with no typeIds the move's type has no name, and nothing fires")
  -- An axis the hub cannot read -- a content mod's type id off the wire's id
  -- alphabet, since a registry id is any non-empty string -- is dropped, not
  -- refused: the ruleset stands, the field opens, and it plays exactly as one
  -- uploaded with no typeIds at all.
  local modded, moddedRecord, moddedSeen = bugHit({ "HIVE" }, { "DARK", "mymod.BUG", "FIRE" })
  ok(moddedRecord and moddedRecord.sim ~= nil, "typeIds (unreadable): the field still opens")
  ok(moddedSeen.opts ~= nil and moddedSeen.opts.typeIds == nil,
     "typeIds (unreadable): ...and Turn.create is handed no axis")
  ok(moddedSeen.opts ~= nil and moddedSeen.opts.chart ~= nil and #moddedSeen.opts.specialTypes == 1,
     "typeIds (unreadable): ...but the rest of the ruleset")
  eq(modded, plain, "typeIds (unreadable): ...so nothing fires")
end

-- ------- Gold's cart lineage on a fighter entry (contract K6)
--
-- docs/plans/gen12-referee-fidelity.md: BattleSim2 reads side a's first
-- fighter's `family` for the rule Gold / Silver and Crystal disagree on
-- (TruncateHL_BC loops on Crystal outside a link battle, one pass on Gold /
-- Silver), so a Gen 2 hub stamps each human seat the way a Gen 3 hub does --
-- from the hello it admitted, never off the party -- gold / silver -> gs,
-- crystal -> crystal.  An NPC seat gets none.  The K1 / K2 fields a Gold sheet
-- carries ride the entry through the sanitiser, and a Gold `held` event goes
-- out to every member as the referee wrote it.  server/hub_battle.test.js pins
-- the same on the Node twin.
local function join2v(hub, name, version)
  local peer = fakePeer()
  local client = hub:accept(peer)
  if client then
    hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
      name = name, map = "NEW_BARK_TOWN", x = 5, y = 5, facing = "down",
      generation = 2, version = version, playerId = testPlayerId(name) })
  end
  return client, peer
end

do
  local hub = Hub.new({ maxPlayers = 4, generation = 2 })
  hub.forceBattleSeed = 5
  local seen = spyCreate(hub)
  local ann, annPeer = join2v(hub, "ANN", "crystal")
  local bob = join2v(hub, "BOB", "silver")
  eq(ann.version, "crystal", "family gen 2: the hello's cart is recorded")
  hub:openCoopBattle("g2f", { ann.id, bob.id }, { mode = "coop_npc", hostId = ann.id })
  local record = hub.battles["g2f"]
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = "g2f", chart = CHART2,
                     typeIds = TYPE_IDS2, specialTypes = { 2 } })
  local held = sheet2({ spe = 200 })
  held.heldItem, held.holdEffect, held.holdParam, held.itemName = "LEFTOVERS", "HELD_LEFTOVERS", 6, "LEFTOVERS"
  held.traded = true
  -- The upload claims the other cart's family: no party field decides it.
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g2f", side = "a", family = "gs",
                     generation = 2, mons = { held } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = "g2f", side = "a", family = "crystal",
                     generation = 2, mons = { sheet2({ spe = 100 }) } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = "g2f", side = "b", generation = 2,
                     mons = { sheet2({ species = "WALL", hp = 900, spe = 1 }),
                              sheet2({ species = "WALL", hp = 900, spe = 1 }) } })
  ok(record and record.sim ~= nil, "family gen 2: the coop_npc field opens")
  local annEntry, bobEntry = entryOf(seen, "a", ann.id), entryOf(seen, "a", bob.id)
  eq(annEntry and annEntry.family, "crystal", "family gen 2: the Crystal player's entry is crystal")
  eq(bobEntry and bobEntry.family, "gs", "family gen 2: the Silver player's entry is gs")
  for _, npcId in ipairs(record and record.npcIds or {}) do
    local npc = entryOf(seen, "b", npcId)
    ok(npc ~= nil and npc.family == nil, "family gen 2: an NPC seat's entry has none (" .. npcId .. ")")
  end
  local annMon = annEntry and annEntry.mons[1]
  eq(annMon and annMon.traded, true, "gen 2 sheet: traded rides the entry (K1)")
  eq(annMon and annMon.heldItem, "LEFTOVERS", "gen 2 sheet: the item rides the entry")
  eq(annMon and annMon.holdEffect, "HELD_LEFTOVERS", "gen 2 sheet: ...with its hold effect (K2)")
  eq(annMon and annMon.holdParam, 6, "gen 2 sheet: ...its parameter")
  eq(annMon and annMon.itemName, "LEFTOVERS", "gen 2 sheet: ...and its name")

  -- A Gold `held` the referee writes goes out to every member untouched: put
  -- straight into the referee's own event buffer, so what is pinned here is the
  -- hub's pass-through and not the referee's vocabulary (tests/battle_sim2_*).
  if record and record.sim then
    annPeer.outbox = {}
    record.sim.buffer[#record.sim.buffer + 1] = {
      battle = "g2f", seq = 9000, t = "held", slot = 0, side = "a", mon = 0,
      text = "LEFTOVERS", amount = 1,
    }
    hub:flushBattle(record)
    local out
    for _, msg in ipairs(annPeer.outbox) do
      if msg.type == Wire.BATTLE_EVENT and msg.t == "held" then out = msg end
    end
    eq(out and out.text, "LEFTOVERS", "gen 2 held: the hub passes the referee's event through")
    eq(out and out.amount, 1, "gen 2 held: ...amount and all")
    local clean = out and Wire.battleEvent(out, 2)
    eq(clean and clean.text, "LEFTOVERS", "gen 2 held: ...and a Gold client's sanitiser keeps it")
  end
end

-- Gold alone, and a hello with no cart: no family -- the referee plays gs.
do
  local hub = Hub.new({ maxPlayers = 4, generation = 2 })
  hub.forceBattleSeed = 5
  local seen = spyCreate(hub)
  local gold = join2v(hub, "GOLDY", "gold")
  local bare = join2v(hub, "BARE", nil)
  hub:openCoopBattle("g2n", { gold.id, bare.id }, { mode = "coop_npc", hostId = gold.id })
  hub:receive(gold, { type = Wire.BATTLE_RULESET, battle = "g2n", chart = CHART2 })
  hub:receive(gold, { type = Wire.BATTLE_PARTY, battle = "g2n", side = "a", mons = { sheet2({ spe = 200 }) } })
  hub:receive(bare, { type = Wire.BATTLE_PARTY, battle = "g2n", side = "a", mons = { sheet2({ spe = 100 }) } })
  hub:receive(gold, { type = Wire.BATTLE_PARTY, battle = "g2n", side = "b",
                      mons = { sheet2({ species = "WALL", hp = 900, spe = 1 }),
                               sheet2({ species = "WALL", hp = 900, spe = 1 }) } })
  ok(hub.battles["g2n"] and hub.battles["g2n"].sim ~= nil, "family gen 2 (gold): the field opens")
  eq(entryOf(seen, "a", gold.id) and entryOf(seen, "a", gold.id).family, "gs",
     "family gen 2 (gold): a Gold player's entry is gs")
  eq(entryOf(seen, "a", bare.id) and entryOf(seen, "a", bare.id).family, nil,
     "family gen 2 (no cart): a hello naming no cart leaves the field off")
end

-- A four-player Gold spar: the entries still say whose cart (the referee reads
-- side a's; a link fight plays one pass whoever's it is).
do
  local hub = Hub.new({ maxPlayers = 4, generation = 2 })
  hub.forceBattleSeed = 5
  local seen = spyCreate(hub)
  local who = { join2v(hub, "ANN", "crystal"), join2v(hub, "BOB", "gold"),
                join2v(hub, "CAL", "silver"), join2v(hub, "DEE", "crystal") }
  local ids = {}
  for i, c in ipairs(who) do ids[i] = c.id end
  hub:openCoopBattle("g2p", ids, { mode = "coop_pvp", hostId = ids[1],
                                   sides = { a = { ids[1], ids[2] }, b = { ids[3], ids[4] } } })
  hub:receive(who[1], { type = Wire.BATTLE_RULESET, battle = "g2p", chart = CHART2 })
  for i = 1, 4 do
    hub:receive(who[i], { type = Wire.BATTLE_PARTY, battle = "g2p", mons = { sheet2({ spe = 10 * i }) } })
  end
  ok(hub.battles["g2p"] and hub.battles["g2p"].sim ~= nil, "family gen 2 pvp: the spar opens")
  eq(entryOf(seen, "a", ids[1]).family, "crystal", "family gen 2 pvp: ANN's entry names her cart")
  eq(entryOf(seen, "a", ids[2]).family, "gs", "family gen 2 pvp: BOB's")
  eq(entryOf(seen, "b", ids[3]).family, "gs", "family gen 2 pvp: on either side")
  eq(entryOf(seen, "b", ids[4]).family, "crystal", "family gen 2 pvp: DEE's")
end

-- ------- Gen 3 lists: what Json.decode hands over, and what is a list at all
--
-- lib/sanitize.js used to refuse what this side took (an object where a list
-- belongs: ipairs reads nothing and called it the empty list) and the reverse
-- (a JSON null inside a list, which this side is never handed -- the engine's
-- decoder appends nothing for it).  Both twins now judge one list:
-- tests/fixtures/hub_protocol_parity.json pins the cases message for message,
-- and the engine's own decoder is held to the reading here, where it can be
-- reached (run from the engine root).
do
  eq(Wire.battleRuleset({ typeTable = CHART3, specialTypes = { a = 1 } }, 3), nil,
     "an object where the special-type list belongs is refused")
  eq(Wire.battleRuleset({ typeTable = CHART3, movePool = { a = "x" } }, 3), nil,
     "and where the move pool belongs")
  ok(Wire.battleRuleset({ typeTable = CHART3, specialTypes = {} }, 3) ~= nil,
     "while the empty table is the empty list, as `{}` and `[]` decode alike")
  local okJson, Json = pcall(require, "src.link.Json")
  if okJson and type(Json) == "table" and type(Json.decode) == "function" then
    local list = Json.decode("[10,null,12]")
    eq(#list, 2, "the engine's decoder closes a null element up")
    eq(list[2], 12, "so the element after it moves down")
    eq(next(Json.decode('{"a":null}')), nil, "and stores nothing for a null value")
    local hole = Wire.battleRuleset(Json.decode(
      '{"typeTable":[10,12,20,null,11,10,20,12,11,20,-1,-1,0,0,7,0]}'), 3)
    eq(hole and #hole.typeTable, #CHART3, "a null between rows leaves the rows around it")
    eq(Wire.battleRuleset(Json.decode(
      '{"typeTable":[10,12,null,11,10,20,12,11,20,-1,-1,0,0,7,0]}'), 3), nil,
      "and a null in place of a cell refuses the chart")
    local bag = Wire.battleBag(Json.decode('{"13":2,"22":null}'), 3)
    eq(bag and #bag, 1, "a null count in a map bag is no entry at all")
  else
    io.write("hub_battle: src.link.Json not reachable from here (run from the engine root); "
      .. "decoder checks skipped\n")
  end
end

-- ------------------------------------------------------------------
-- The referee-gap contracts on the hub (docs/plans/gen12-referee-gaps-fix.md)
-- ------------------------------------------------------------------
--
-- K9: a mid-fight level-up rides mmo.battle_moveset, and the hub forwards its
-- level / stats / maxHp to the referee's `levelUp(playerId, monIndex, level,
-- stats, maxHp)` -- 1-based index -- whatever became of the move list, only
-- when the referee has the method.  The method is a stub recording each call
-- (the Gen 1 / Gen 2 referees' own rebuild is theirs to pin).  K8: a learn
-- keeps an unchanged row's highCrit / PP Ups / Gold priority and takes a new
-- row's.  server/hub_battle.test.js pins the same on the Node twin, and
-- tests/fixtures/hub_protocol_parity.json holds the two to one digest.

local function row(id, o)
  local out = { id = id, pp = 20, power = 40, accuracy = 255, type = 0, effect = 0, chance = 0 }
  for k, v in pairs(o or {}) do out[k] = v end
  return out
end

do
  local hub = Hub.new({ maxPlayers = 4 })
  local fight = openFight(hub)
  local record = hub.battles[fight.id]
  local client = fight.ann.client
  ok(record.sim ~= nil, "level-up: the fight is live")
  local calls = {}
  record.sim.levelUp = function(sim, playerId, index, level, stats, maxHp)
    calls[#calls + 1] = { sim = sim, playerId = playerId, index = index, level = level,
                          stats = stats, maxHp = maxHp }
  end
  local live = record.sim.byId[client.id].mons[1]
  live.moves = { row("OLD", { pp = 10, highCrit = true, ppUps = 1 }) }

  ok(hub:applyBattleMoveset(record, client, { mon = 0, moves = { row("OLD", { pp = 99 }) },
       level = 51, stats = { atk = 1, def = 2, spd = 3, spc = 4 }, maxHp = 310 }),
     "level-up: the hub's own moves with a level reach the referee")
  eq(#calls, 1, "level-up: one call")
  eq(calls[1] and calls[1].sim, record.sim, "level-up: called as a method on the referee")
  eq(calls[1] and calls[1].playerId, client.id, "level-up: for the sender's seat")
  eq(calls[1] and calls[1].index, 1, "level-up: the 1-based party index (wire mon 0)")
  eq(calls[1] and calls[1].level, 51, "level-up: the new level")
  eq(calls[1] and calls[1].stats and calls[1].stats.spc, 4, "level-up: the new stats")
  eq(calls[1] and calls[1].maxHp, 310, "level-up: the new max HP")
  eq(live.moves[1].pp, 10, "level-up: the unchanged row keeps the hub's PP")
  eq(live.moves[1].highCrit, true, "level-up: ...and its high-crit flag (K8: the rebuild used to drop it)")
  eq(live.moves[1].ppUps, 1, "level-up: ...and its PP Ups")

  hub:receive(client, { type = Wire.BATTLE_MOVESET, battle = fight.id, mon = 0,
    moves = { row("OLD") }, level = "52", stats = { atk = 5, def = 6, spd = 7, spc = 8 } })
  eq(#calls, 2, "level-up: the wire path forwards too")
  eq(calls[2] and calls[2].level, 52, "level-up: ...the sanitised level")
  eq(calls[2] and calls[2].maxHp, nil, "level-up: ...and no max HP when none was stated")
  hub:receive(client, { type = Wire.BATTLE_MOVESET, battle = fight.id, mon = 0,
    moves = { row("OLD") }, level = 0 })
  eq(#calls, 2, "level-up: a mangled level refuses the whole message")

  ok(hub:applyBattleMoveset(record, client, { mon = 0,
       moves = { row("OLD"), row("NEW", { ppUps = 2, highCrit = true }) } }),
     "level-up: a learn with no level is applied")
  eq(#calls, 2, "level-up: ...and calls nothing")
  eq(live.moves[2] and live.moves[2].ppUps, 2, "level-up: the learned row keeps its PP Ups")
  eq(live.moves[2] and live.moves[2].highCrit, true, "level-up: ...and its high-crit flag")
  eq(live.moves[2] and live.moves[2].priority, nil, "level-up: a Gen 1 row has no priority")

  ok(hub:applyBattleMoveset(record, client, { mon = 0,
       moves = { row("AAA"), row("BBB") }, level = 53 }),
     "level-up: a refused rewrite still forwards its level")
  eq(#calls, 3, "level-up: ...one more call")
  eq(live.moves[1].id, "OLD", "level-up: ...and the list is untouched")

  live.transformed = true
  ok(hub:applyBattleMoveset(record, client, { mon = 0,
       moves = { row("OLD"), row("NEW"), row("THIRD") }, level = 54, maxHp = 320 }),
     "level-up: a transformed battler still grows")
  eq(#calls, 4, "level-up: ...the referee hears it")
  eq(#live.moves, 2, "level-up: ...and only its move list is protected")
  eq(hub:applyBattleMoveset(record, client, { mon = 0,
       moves = { row("OLD"), row("NEW"), row("THIRD") } }), false,
     "level-up: moves alone on a transformed battler reach nothing")
  live.transformed = nil

  eq(hub:applyBattleMoveset(record, client, { mon = 5, moves = { row("OLD") }, level = 55 }), false,
     "level-up: a party index with no mon is refused")
  eq(#calls, 4, "level-up: ...and forwards nothing")

  record.sim.levelUp = false
  eq(hub:applyBattleMoveset(record, client, { mon = 0, moves = { row("AAA"), row("BBB") },
       level = 56 }), false, "level-up: a referee with no K9 method is not called")
  ok(hub:applyBattleMoveset(record, client, { mon = 0,
       moves = { row("OLD"), row("NEW"), row("THIRD") }, level = 56 }),
     "level-up: ...and a learn still lands without it")
  eq(#live.moves, 3, "level-up: ...three moves now")
end

-- The two learn rules are exported for the solo path's referee (a fight with
-- no hub), so it applies a learn by the same rule rather than a copy of it.
do
  eq(Hub.movesetDeltaOk({ row("A") }, { row("A"), row("B") }), true, "export: an append is a learn")
  eq(Hub.movesetDeltaOk({ row("A"), row("B") }, { row("C"), row("D") }), false, "export: a rewrite is not")
  local next12 = Hub.nextMoves12({ row("A", { pp = 3, highCrit = true }) },
                                 { row("A", { pp = 99 }), row("B", { ppUps = 1 }) })
  eq(next12[1].pp, 3, "export: an unchanged row keeps the old PP")
  eq(next12[1].highCrit, true, "export: ...and its high-crit flag")
  eq(next12[2].ppUps, 1, "export: a new row takes its own PP Ups")
  local held = { transformed = true, moves = { row("COPY") }, preTransform = { moves = { row("A") } } }
  eq(Hub.learnTo(2, held, { row("A"), row("B") }), true, "export: learnTo lands a learn")
  eq(#held.preTransform.moves, 2, "export: ...in the list a Transform put aside")
  eq(held.moves[1].id, "COPY", "export: ...leaving Gold's copied moves be")
  eq(Hub.learnTo(2, { transformed = true, moves = { row("COPY") } }, { row("COPY"), row("B") }), false,
     "export: a transformed battler with nothing put aside is left alone")
end

-- Gold: the learn keeps the cart's priority byte (K8), and a Gold sheet's K7
-- blocks ride the hub's stored party into the referee's hands.
do
  local hub = Hub.new({ maxPlayers = 4, generation = 2 })
  local ann = join2(hub, "ANN")
  local bob = join2(hub, "BOB")
  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  local id = ann.sessionId
  local gold = sheet2({})
  gold.base = { hp = 41, atk = 52, def = 63, spe = 74, spa = 85, spd = 96 }
  gold.dvs = { atk = 12, def = 7, spe = 15, spc = 3 }
  gold.statExp = { hp = 1, atk = 2, def = 3, spe = 4, spc = 5 }
  gold.happiness = 200
  gold.moves[1].priority, gold.moves[1].ppUps = 2, 3
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART2 })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, mons = { gold } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = id, mons = { sheet2({}) } })
  local record = hub.battles[id]
  ok(record and record.sim ~= nil, "gold K7/K8: the fight opens on a sheet carrying them")
  local stored = record.parties[ann.id] and record.parties[ann.id].mons[1]
  eq(stored and stored.dvs and stored.dvs.spc, 3, "gold K7: the stored sheet keeps the cart's DVs")
  eq(stored and stored.base and stored.base.spd, 96, "gold K7: ...the species base stats")
  eq(stored and stored.statExp and stored.statExp.spc, 5, "gold K7: ...and the stat exp")
  eq(stored and stored.happiness, 200, "gold K14: ...and the happiness RETURN reads")
  eq(stored and stored.moves[1].priority, 2, "gold K8: ...and the move's priority byte")
  eq(stored and stored.moves[1].ppUps, 3, "gold K8: ...and its PP Ups")
  if record and record.sim then
    local live = record.sim.byId[ann.id].mons[1]
    live.moves = { row("thump", { priority = 1 }) }
    hub:receive(ann, { type = Wire.BATTLE_MOVESET, battle = id, mon = 0,
      moves = { row("thump", { priority = 3 }), row("quick", { priority = 2 }) } })
    eq(live.moves[1].priority, 1, "gold K8: an unchanged row keeps the hub's priority")
    eq(live.moves[2] and live.moves[2].priority, 2, "gold K8: a learned row takes its own")
    local calls = 0
    record.sim.levelUp = function() calls = calls + 1 end
    hub:receive(ann, { type = Wire.BATTLE_MOVESET, battle = id, mon = 0,
      moves = { row("thump"), row("quick") }, level = 51,
      stats = { atk = 1, def = 2, spe = 3, spa = 4, spd = 5 }, maxHp = 140 })
    eq(calls, 1, "gold K9: a Gold level-up reaches the referee")
    hub:receive(ann, { type = Wire.BATTLE_MOVESET, battle = id, mon = 0,
      moves = { row("thump"), row("quick") }, level = 52,
      stats = { atk = 1, def = 2, spd = 3, spc = 4 } })
    eq(calls, 1, "gold K9: Kanto-keyed stats refuse a Gold moveset")
  end
end

-- A learn on a transformed battler, real referees: the hub judges it against,
-- and writes it into, the party list the referee put aside at Transform
-- (`preTransform.moves`), so the switch-out gives back the learned list
-- rather than the one from before it.  Gold leaves the copied moves in the
-- fight (pokecrystal LearnMove skips wBattleMonMoves while
-- SUBSTATUS_TRANSFORMED is set); Red overwrites them with its own (pokered
-- LearnMove has no such check), as a separate copy.  Hub.learnTo;
-- server/hub_battle.test.js pins the same on the Node twin.
local function transformLearn(generation)
  local hub = Hub.new({ maxPlayers = 4, generation = generation })
  hub.forceBattleSeed = 1
  local ann = (generation == 2 and join2 or join)(hub, "ANN")
  local id = "tl"
  hub:openCoopBattle(id, { ann.id }, { mode = "wild", hostId = ann.id })
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id,
                     chart = generation == 2 and CHART2 or CHART })
  local function sheet(species, moves)
    local out = generation == 2 and sheet2({ species = species }) or mon({ species = species })
    out.moves = moves
    return out
  end
  local function mv(moveId, effect, power)
    return row(moveId, { pp = 10, power = power or 0, effect = effect or 0 })
  end
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = {
    sheet("COPYCAT", { mv("TRANSFORM", 57), mv("TACKLE", 0, 1) }),
    sheet("BENCH", { mv("TACKLE", 0, 1) }) } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, side = "b", mons = {
    sheet("FOE", { mv("GROWL"), mv("HUSH") }) } })
  local record = hub.battles[id]
  if not (record and record.sim) then return nil end
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
  local live = record.sim.byId[ann.id].mons[1]
  local seen = { transformed = live.transformed == true, put = live.preTransform ~= nil }
  local learnt = hub:applyBattleMoveset(record, ann, { mon = 0,
    moves = { mv("TRANSFORM", 57), mv("TACKLE", 0, 1), mv("LEARNT", 0, 40) } })
  seen.learnt = learnt
  seen.battle = live.moves[1] and live.moves[1].id
  seen.battleCount = #live.moves
  seen.party = live.preTransform and #live.preTransform.moves
  seen.partyPp = live.preTransform and live.preTransform.moves[1].pp
  seen.separate = live.preTransform and live.preTransform.moves[1] ~= live.moves[1]
  seen.rewrite = hub:applyBattleMoveset(record, ann, { mon = 0,
    moves = { mv("AAA"), mv("BBB"), mv("CCC") } })
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id, action = "switch", slot = 1 })
  seen.after = live.transformed == true
  seen.restored = {}
  for i, m in ipairs(live.moves) do seen.restored[i] = m.id end
  return seen
end

do
  local gold = transformLearn(2)
  ok(gold ~= nil, "transformed learn: a Gold wild fight opens")
  if gold then
    ok(gold.transformed and gold.put, "transformed learn (gold): TRANSFORM put the party list aside")
    eq(gold.learnt, true, "transformed learn (gold): the learn is applied")
    eq(gold.party, 3, "transformed learn (gold): ...to the list put aside")
    eq(gold.partyPp, 9, "transformed learn (gold): ...which keeps the party's PP")
    eq(gold.battle, "GROWL", "transformed learn (gold): the copied moves stay in the fight")
    eq(gold.battleCount, 2, "transformed learn (gold): ...all of them (pokecrystal LearnMove)")
    eq(gold.rewrite, false, "transformed learn (gold): a rewrite is still refused")
    eq(gold.after, false, "transformed learn (gold): the switch-out undoes the Transform")
    eq(table.concat(gold.restored, ","), "TRANSFORM,TACKLE,LEARNT",
       "transformed learn (gold): ...and gives back the learned list")
  end
  local red = transformLearn(1)
  ok(red ~= nil, "transformed learn: a Red wild fight opens")
  if red then
    ok(red.transformed and red.put, "transformed learn (red): TRANSFORM put the party list aside")
    eq(red.learnt, true, "transformed learn (red): the learn is applied")
    eq(red.party, 3, "transformed learn (red): ...to the list put aside")
    eq(red.battle, "TRANSFORM", "transformed learn (red): the fight's moves become its own (pokered LearnMove)")
    eq(red.battleCount, 3, "transformed learn (red): ...the learned move among them")
    eq(red.separate, true, "transformed learn (red): ...as a copy the fight's PP cannot reach the party through")
    eq(red.rewrite, false, "transformed learn (red): a rewrite is still refused")
    eq(red.after, false, "transformed learn (red): the switch-out undoes the Transform")
    eq(table.concat(red.restored, ","), "TRANSFORM,TACKLE,LEARNT",
       "transformed learn (red): ...and gives back the learned list")
  end
end

-- ------------------------------------------------------------------
-- Wave 4 of docs/plans/gen12-referee-gaps-fix.md: a learn is judged against
-- the PARTY list -- the one a Transform put aside, a MIMIC's slots given back
-- (`preMimic`) -- and reaches the battle list only as the cart's LearnMove
-- does: for a new move alone (pokered LearnMoveFromLevelUp / pokecrystal
-- LearnLevelMoves call it only then), on Red whatever the Transform
-- (pokered LearnMove copies wPartyMon*Moves / PP over wBattleMon*), on Gold
-- only untransformed (pokecrystal LearnMove's SUBSTATUS_TRANSFORMED check).
-- Hub.learnTo; server/hub_battle.test.js pins the same on the Node twin.
-- ------------------------------------------------------------------

do
  -- Red, transformed: a level-up with no new move re-sends the same ids, and
  -- that is no LearnMove -- the copied moves stay (they used to be replaced).
  local red = { transformed = true, moves = { row("COPY1", { pp = 5 }), row("COPY2", { pp = 5 }) },
                preTransform = { moves = { row("A", { pp = 7 }), row("B") } } }
  eq(Hub.learnTo(1, red, { row("A", { pp = 99 }), row("B") }), true, "wave 4: a Red re-send while transformed is taken")
  eq(red.moves[1].id, "COPY1", "wave 4: ...and the copied moves stay in the fight")
  eq(#red.moves, 2, "wave 4: ...all of them")
  eq(red.preTransform.moves[1].pp, 7, "wave 4: ...the list put aside keeps its PP")
  eq(Hub.learnTo(1, red, { row("A"), row("B"), row("C") }), true, "wave 4: a Red learn while transformed")
  eq(red.moves[3] and red.moves[3].id, "C", "wave 4: ...copies the party list over the copies (pokered LearnMove)")
  eq(red.moves[1].pp, 7, "wave 4: ...with the party's PP")
  ok(red.moves[1] ~= red.preTransform.moves[1], "wave 4: ...as a list of its own")

  -- Under a MIMIC used while the monster was itself: slot 1 holds the copy
  -- (HUSH, at the PP it shares with the party on Red), the party's MIMIC
  -- saved as the Red referee keeps it.
  local function mimicked(generation, copyPp)
    local mon = { moves = { row("HUSH", { pp = copyPp }), row("B") },
                  preMimic = { [1] = row("MIMIC", { pp = 9, effect = 82 }) } }
    return mon
  end
  local m = mimicked(1, 6)
  eq(Hub.learnTo(1, m, { row("MIMIC"), row("B") }), true, "wave 4: a re-send under MIMIC is taken")
  eq(m.moves[1].id, "HUSH", "wave 4: ...and the copy stays in the fight")
  ok(m.preMimic and m.preMimic[1] and m.preMimic[1].id == "MIMIC", "wave 4: ...its saved row kept for the switch-out")
  eq(Hub.learnTo(1, m, { row("HUSH"), row("B"), row("C") }), false,
     "wave 4: the battle list is not the party list -- the copy sent back as a learn is refused")
  eq(Hub.learnTo(1, m, { row("MIMIC"), row("B"), row("C") }), true,
     "wave 4: a learn under MIMIC is judged against the party list (it used to be refused)")
  eq(m.moves[1].id, "MIMIC", "wave 4: ...Red's LearnMove copies the party list over the copy")
  eq(m.moves[1].pp, 6, "wave 4: ...MIMIC at the slot's PP (DecrementPP wrote both)")
  eq(m.moves[3] and m.moves[3].id, "C", "wave 4: ...the learned move among them")
  eq(m.preMimic, nil, "wave 4: ...and no saved row is left to give back over the learned list")
  local forget = mimicked(1, 6)
  eq(Hub.learnTo(1, forget, { row("NEW"), row("B") }), true, "wave 4: forgetting MIMIC itself for a new move")
  eq(forget.moves[1].id, "NEW", "wave 4: ...lands in its slot")
  eq(forget.preMimic, nil, "wave 4: ...and the saved MIMIC goes with it")
  eq(Hub.learnTo(1, mimicked(1, 6), { row("X"), row("Y") }), false, "wave 4: a rewrite under MIMIC is refused")

  -- Gold: the same learn ends the copy too (untransformed), MIMIC at the PP
  -- the party kept -- CheckMimicUsed stops the party spend on its slot.
  local g = mimicked(2, 5)
  eq(Hub.learnTo(2, g, { row("MIMIC"), row("B") }), true, "wave 4 (gold): a re-send under MIMIC is taken")
  eq(g.moves[1].id, "HUSH", "wave 4 (gold): ...and the copy stays")
  eq(Hub.learnTo(2, g, { row("MIMIC"), row("B"), row("C") }), true, "wave 4 (gold): a learn under MIMIC")
  eq(g.moves[1].id, "MIMIC", "wave 4 (gold): ...pokecrystal LearnMove copies the party list over the copy")
  eq(g.moves[1].pp, 9, "wave 4 (gold): ...MIMIC at the party's own PP")
  eq(g.preMimic, nil, "wave 4 (gold): ...nothing left to give back")

  -- A MIMIC before a Transform: the list put aside holds the copy, the
  -- saved row the party's MIMIC.  A learn folds it in.
  local function both(copyPp)
    return { transformed = true, moves = { row("COPY", { pp = 5 }) },
             preTransform = { moves = { row("HUSH", { pp = copyPp }), row("B") } },
             preMimic = { [1] = row("MIMIC", { pp = 9 }) } }
  end
  local gt = both(4)
  eq(Hub.learnTo(2, gt, { row("MIMIC"), row("B"), row("C") }), true, "wave 4 (gold): a learn under MIMIC and Transform")
  eq(gt.moves[1].id, "COPY", "wave 4 (gold): ...leaves the copied moves in the fight")
  eq(gt.preTransform.moves[1].id, "MIMIC", "wave 4 (gold): ...writes the party list put aside")
  eq(gt.preTransform.moves[1].pp, 9, "wave 4 (gold): ...MIMIC at the party's PP")
  eq(#gt.preTransform.moves, 3, "wave 4 (gold): ...with the learned move")
  eq(gt.preMimic, nil, "wave 4 (gold): ...and folds the saved row into it")
  local rt = both(4)
  eq(Hub.learnTo(1, rt, { row("MIMIC"), row("B") }), true, "wave 4: a Red re-send under MIMIC and Transform")
  eq(rt.moves[1].id, "COPY", "wave 4: ...leaves the copied moves")
  eq(rt.preTransform.moves[1].id, "MIMIC", "wave 4: ...the saved row folded into the list put aside")
  eq(rt.preTransform.moves[1].pp, 4, "wave 4: ...at the PP the slot shared with the party")
  eq(rt.preMimic, nil, "wave 4: ...so the switch-out has one list to give back")
end

-- The same on the real Red referee, MIMIC's pick off the wire (`mimic`, the
-- 0-based index into the foe's moves; absent, the menu's first row).
local function mimicLearn(pick)
  local hub = Hub.new({ maxPlayers = 4, generation = 1 })
  hub.forceBattleSeed = 1
  local ann = join(hub, "ANN")
  local id = "ml"
  hub:openCoopBattle(id, { ann.id }, { mode = "wild", hostId = ann.id })
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART })
  local function mv(moveId, effect, power)
    return row(moveId, { pp = 10, power = power or 0, effect = effect or 0 })
  end
  local function sheet(species, moves)
    local out = mon({ species = species })
    out.moves = moves
    return out
  end
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = {
    sheet("COPYCAT", { mv("MIMIC", 82), mv("TACKLE", 0, 1) }), sheet("BENCH", { mv("TACKLE", 0, 1) }) } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, side = "b", mons = {
    sheet("FOE", { mv("GROWL"), mv("HUSH") }) } })
  local record = hub.battles[id]
  if not (record and record.sim) then return nil end
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0, mimic = pick })
  local live = record.sim.byId[ann.id].mons[1]
  local seen = { copy = live.moves[1].id, copyPp = live.moves[1].pp,
                 saved = live.preMimic and live.preMimic[1] and live.preMimic[1].id }
  seen.resend = hub:applyBattleMoveset(record, ann, { mon = 0, moves = { mv("MIMIC", 82), mv("TACKLE", 0, 1) } })
  seen.afterResend = live.moves[1].id
  seen.copyBack = hub:applyBattleMoveset(record, ann, { mon = 0,
    moves = { mv(live.moves[1].id), mv("TACKLE", 0, 1), mv("LEARNT", 0, 40) } })
  seen.learnt = hub:applyBattleMoveset(record, ann, { mon = 0,
    moves = { mv("MIMIC", 82), mv("TACKLE", 0, 1), mv("LEARNT", 0, 40) } })
  seen.battle = {}
  for i, m in ipairs(live.moves) do seen.battle[i] = m.id .. ":" .. m.pp end
  seen.savedAfter = live.preMimic
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id, action = "switch", slot = 1 })
  seen.restored = {}
  for i, m in ipairs(live.moves) do seen.restored[i] = m.id end
  return seen
end

do
  local picked = mimicLearn(1)
  ok(picked ~= nil, "wave 4 mimic: a Red wild fight opens")
  if picked then
    eq(picked.copy, "HUSH", "wave 4 mimic: the wire's pick reaches the referee (the foe's second move)")
    eq(picked.copyPp, 9, "wave 4 mimic: ...in MIMIC's slot, at its PP")
    eq(picked.saved, "MIMIC", "wave 4 mimic: ...the party's MIMIC saved")
    eq(picked.resend, true, "wave 4 mimic: a re-send of the party's ids is taken")
    eq(picked.afterResend, "HUSH", "wave 4 mimic: ...and leaves the copy in the fight")
    eq(picked.copyBack, false, "wave 4 mimic: the copy sent back as a learn is refused")
    eq(picked.learnt, true, "wave 4 mimic: a learn under MIMIC lands")
    eq(table.concat(picked.battle, ","), "MIMIC:9,TACKLE:10,LEARNT:10",
       "wave 4 mimic: ...the party list over the copy, MIMIC at the PP it shared")
    eq(picked.savedAfter, nil, "wave 4 mimic: ...no saved row left")
    eq(table.concat(picked.restored, ","), "MIMIC,TACKLE,LEARNT",
       "wave 4 mimic: the switch-out keeps the learned list")
  end
  local unpicked = mimicLearn(nil)
  eq(unpicked and unpicked.copy, "GROWL", "wave 4 mimic: no pick on the wire is the menu's first row")
end

-- A transformed battler's re-send on the real referees: the copies stay on
-- both carts (Red's used to be replaced by its own list).
local function transformResend(generation)
  local hub = Hub.new({ maxPlayers = 4, generation = generation })
  hub.forceBattleSeed = 1
  local ann = (generation == 2 and join2 or join)(hub, "ANN")
  local id = "tr"
  hub:openCoopBattle(id, { ann.id }, { mode = "wild", hostId = ann.id })
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id,
                     chart = generation == 2 and CHART2 or CHART })
  local function sheet(species, moves)
    local out = generation == 2 and sheet2({ species = species }) or mon({ species = species })
    out.moves = moves
    return out
  end
  local function mv(moveId, effect, power)
    return row(moveId, { pp = 10, power = power or 0, effect = effect or 0 })
  end
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = {
    sheet("COPYCAT", { mv("TRANSFORM", 57), mv("TACKLE", 0, 1) }), sheet("BENCH", { mv("TACKLE", 0, 1) }) } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, side = "b", mons = {
    sheet("FOE", { mv("GROWL"), mv("HUSH") }) } })
  local record = hub.battles[id]
  if not (record and record.sim) then return nil end
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
  local live = record.sim.byId[ann.id].mons[1]
  local seen = { transformed = live.transformed == true }
  seen.resend = hub:applyBattleMoveset(record, ann, { mon = 0,
    moves = { mv("TRANSFORM", 57), mv("TACKLE", 0, 1) }, level = 51 })
  seen.battle = live.moves[1] and live.moves[1].id
  seen.battlePp = live.moves[1] and live.moves[1].pp
  seen.party = live.preTransform and live.preTransform.moves[1].id
  return seen
end

do
  for _, generation in ipairs({ 1, 2 }) do
    local label = generation == 2 and "gold" or "red"
    local seen = transformResend(generation)
    ok(seen and seen.transformed, "wave 4 resend (" .. label .. "): TRANSFORM lands")
    if seen then
      eq(seen.resend, true, "wave 4 resend (" .. label .. "): a level-up re-sending the same ids is taken")
      eq(seen.battle, "GROWL", "wave 4 resend (" .. label .. "): ...and the copied moves stay in the fight")
      eq(seen.battlePp, 5, "wave 4 resend (" .. label .. "): ...at their 5 PP")
      eq(seen.party, "TRANSFORM", "wave 4 resend (" .. label .. "): ...the party list put aside unchanged")
    end
  end
end

-- Gold's wTimeOfDay off a Gen 2 ruleset (`timeOfDay`): the hub keeps it,
-- hands it to the referee's create, and MOONLIGHT heals by it -- half at
-- night, a quarter at any other time, half with no clock stated (the link
-- reading); an unknown one refuses the ruleset.  A Red hub reads none.
local function moonlight(generation, timeOfDay)
  local hub = Hub.new({ maxPlayers = 4, generation = generation })
  hub.forceBattleSeed = 1
  local ann = (generation == 2 and join2 or join)(hub, "ANN")
  local id = "tod"
  hub:openCoopBattle(id, { ann.id }, { mode = "wild", hostId = ann.id })
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id,
                     chart = generation == 2 and CHART2 or CHART, timeOfDay = timeOfDay })
  local record = hub.battles[id]
  local seen = { ruleset = record and record.ruleset ~= nil,
                 kept = record and record.ruleset and record.ruleset.timeOfDay }
  local function sheet(species, moves, hp)
    local out = generation == 2 and sheet2({ species = species, hp = 100 }) or mon({ species = species, hp = 100 })
    out.hp = hp or out.hp
    out.moves = moves
    return out
  end
  local function mv(moveId, effect)
    return row(moveId, { pp = 10, power = 0, effect = effect or 0 })
  end
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = {
    sheet("MOTH", { mv("MOONLIGHT", 130) }, 40) } })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, side = "b", mons = {
    sheet("FOE", { mv("HUSH") }) } })
  seen.opened = record ~= nil and record.sim ~= nil
  if not seen.opened then return seen end
  seen.simTime = record.sim.timeOfDay
  hub:receive(ann, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
  seen.hp = record.sim.byId[ann.id].mons[1].hp
  return seen
end

do
  local nite = moonlight(2, "nite")
  eq(nite.kept, "nite", "time of day: a Gold ruleset keeps it")
  eq(nite.simTime, "nite", "time of day: ...and the referee is created with it")
  eq(nite.hp, 90, "time of day: MOONLIGHT at night heals half (BattleCommand_HealNite)")
  local day = moonlight(2, "day")
  eq(day.simTime, "day", "time of day: day reaches the referee")
  eq(day.hp, 65, "time of day: ...and MOONLIGHT by day heals a quarter")
  eq(moonlight(2, "morn").hp, 65, "time of day: ...in the morning too")
  local none = moonlight(2, nil)
  eq(none.simTime, nil, "time of day: none stated is none")
  eq(none.hp, 90, "time of day: ...the link reading (half)")
  local bad = moonlight(2, "evening")
  eq(bad.ruleset, false, "time of day: an unknown time refuses the Gold ruleset")
  eq(bad.opened, false, "time of day: ...so no fight is assembled on it")
  eq(moonlight(2, "NITE").ruleset, false, "time of day: ...the spelling is the referee's, lower case")
  local red = moonlight(1, "nite")
  ok(red.ruleset and red.kept == nil, "time of day: a Red ruleset neither keeps one")
  ok(moonlight(1, "evening").ruleset, "time of day: ...nor refuses one")
  eq(red.simTime, nil, "time of day: ...and the Red referee is created without it")
end

-- Red's MIMIC pick on a choice: read on a Gen 1 hub, ignored on Gold's.
do
  local fight = { battle = "b1", action = "fight", move = 0, mimic = 2 }
  eq(Wire.battleChoice(fight, 1).mimic, 2, "mimic: a Gen 1 choice carries the pick")
  eq(Wire.battleChoice({ battle = "b1", action = "fight", move = 0, mimic = 3 }, 1).mimic, 3,
     "mimic: ...up to the fourth move")
  eq(Wire.battleChoice({ battle = "b1", action = "fight", move = 0, mimic = 4 }, 1), nil,
     "mimic: past the fourth move refuses the choice")
  eq(Wire.battleChoice({ battle = "b1", action = "fight", move = 0, mimic = -1 }, 1), nil,
     "mimic: ...as does a negative pick")
  eq(Wire.battleChoice({ battle = "b1", action = "fight", move = 0, mimic = true }, 1), nil,
     "mimic: ...or one that is no number")
  local gold = Wire.battleChoice({ battle = "b1", action = "fight", move = 0, mimic = 9 }, 2)
  ok(gold and gold.mimic == nil, "mimic: Gold ignores it, whatever it holds")
  local gen3 = Wire.battleChoice({ battle = "b1", action = "fight", move = 0, mimic = 9 }, 3)
  ok(gen3 and gen3.mimic == nil, "mimic: ...as does Gen 3")
  local none = Wire.battleChoice({ battle = "b1", action = "fight", move = 0, mimic = 9 })
  ok(none and none.mimic == nil, "mimic: ...and a caller naming no generation")
end

-- A Gen 3 hub reads no level-up (BattleSim3 rebuilds nothing from one), so a
-- referee there is never called, whatever the client sends.
do
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  local ann = join3(hub, "ANN")
  local bob = join3(hub, "BOB")
  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  local id = ann.sessionId
  hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, typeTable = CHART3 })
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, mons = { mon3() } })
  hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = id, mons = { mon3() } })
  local record = hub.battles[id]
  local calls = 0
  record.sim.levelUp = function() calls = calls + 1 end
  hub:receive(ann, { type = Wire.BATTLE_MOVESET, battle = id, mon = 0,
    moves = { move3(), move3({ id = "NEW3", num = 44 }) }, level = 51,
    stats = { atk = 1, def = 2, spe = 3, spa = 4, spd = 5 }, maxHp = 140 })
  eq(calls, 0, "gen 3: a moveset's level-up fields are never read")
  eq(#record.sim.byId[ann.id].mons[1].moves, 2, "gen 3: ...while the learn lands as before")
end

-- K11: the hubs copy a Gen 1 / Gen 2 referee's Pay Day coins onto the outcome
-- in the NPC modes alone, and only a positive count (a 0 is the field's
-- absence on both twins).  The referee's outcome is a stub here.
local function paid(mode, coins)
  local hub = Hub.new({ maxPlayers = 4 })
  local ann, annPeer = join(hub, "ANN")
  local bob = join(hub, "BOB")
  local id
  if mode == "1v1" then
    hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
    hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
    id = ann.sessionId
    hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART })
    hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, mons = { mon() } })
    hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = id, mons = { mon() } })
  else
    id = "pw"
    hub:openCoopBattle(id, { ann.id }, { mode = "wild", hostId = ann.id })
    hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART })
    hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = { mon() } })
    hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, side = "b", mons = { mon() } })
  end
  local record = hub.battles[id]
  if not (record and record.sim) then return false end
  annPeer.outbox = {}
  record.sim.outcome = function()
    return { outcome = "win", winners = { ann.id }, losers = { bob.id }, reason = "ko", payDay = coins }
  end
  hub:flushBattle(record)
  return take(annPeer, Wire.BATTLE_OUTCOME)
end

do
  local wild = paid("wild", 350)
  ok(wild, "pay day 1/2: a wild fight settles on the referee's outcome")
  eq(wild and wild.payDay, 350, "pay day 1/2: the coins ride the outcome of a fight against the computer")
  eq(wild and Wire.battleOutcome(wild, 1).payDay, 350, "pay day 1/2: and a Gen 1 reader keeps them")
  local link = paid("1v1", 350)
  ok(link, "pay day 1/2: a 1v1 settles too")
  eq(link and link.payDay, nil, "pay day 1/2: a fight between players carries none")
  local none = paid("wild", 0)
  ok(none, "pay day 1/2: a fight with no coins settles")
  eq(none and none.payDay, nil, "pay day 1/2: a 0 is the field's absence, as on the Node twin")
end

-- K11 on an escape: pokered's EndOfBattle pays wTotalPayDayMoney whenever
-- wBattleResult is still 0, and a Teleport / Whirlwind / Roar / POKE DOLL
-- escape never writes it -- so Red's coins ride a `run` outcome.  Gold calls
-- every escape a DRAW (ExitBattle skips CheckPayDay) and Gen 3 pays only from
-- HandleEndTurn_BattleWon, so their hubs keep the field off a run even when
-- the referee's (stubbed) outcome carries one.  The stub names side a the
-- losers, as a referee does when the players fled -- the coins are still
-- theirs.  server/hub_battle.test.js pins the same on the Node twin.
local function fled(generation, mode, coins, reason)
  local hub = Hub.new({ maxPlayers = 4, generation = generation })
  local joinAs = (generation == 2 and join2) or (generation == 3 and join3) or join
  local ann, annPeer = joinAs(hub, "ANN")
  local bob, bobPeer = joinAs(hub, "BOB")
  local function sheet()
    if generation == 2 then return sheet2({}) end
    if generation == 3 then return mon3() end
    return mon()
  end
  local members = mode == "coop_wild" and { ann.id, bob.id } or { ann.id }
  local id = "fw"
  hub:openCoopBattle(id, members, { mode = mode, hostId = ann.id })
  if generation == 3 then
    hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id, typeTable = CHART3 })
  else
    hub:receive(ann, { type = Wire.BATTLE_RULESET, battle = id,
                       chart = generation == 2 and CHART2 or CHART })
  end
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = { sheet() } })
  if mode == "coop_wild" then
    hub:receive(bob, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = { sheet() } })
  end
  hub:receive(ann, { type = Wire.BATTLE_PARTY, battle = id, side = "b", mons = { sheet() } })
  local record = hub.battles[id]
  if not (record and record.sim) then return nil end
  annPeer.outbox, bobPeer.outbox = {}, {}
  local wild = record.npcIds[1]
  record.sim.outcome = function()
    if reason == "ko" then
      return { outcome = "win", winners = members, losers = { wild }, reason = "ko", payDay = coins }
    end
    return { outcome = "win", winners = { wild }, losers = members, reason = "run", payDay = coins }
  end
  hub:flushBattle(record)
  return take(annPeer, Wire.BATTLE_OUTCOME), take(bobPeer, Wire.BATTLE_OUTCOME)
end

do
  local red = fled(1, "wild", 350)
  ok(red, "pay day on a run: a Red wild escape settles")
  eq(red and red.reason, "run", "pay day on a run: ...as a run")
  eq(red and red.winners and red.winners[1], "nfwa", "pay day on a run: ...the wild seat named the winner")
  eq(red and red.losers and #red.losers, 1, "pay day on a run: ...and the player who fled the loser")
  eq(red and red.payDay, 350, "pay day on a run: Red's coins ride the escape (pokered EndOfBattle)")
  eq(red and Wire.battleOutcome(red, 1).payDay, 350, "pay day on a run: ...and a Gen 1 reader keeps them")
  local atAnn, atBob = fled(1, "coop_wild", 350)
  eq(atAnn and atAnn.payDay, 350, "pay day on a run: a Red co-op escape pays the first player")
  eq(atBob and atBob.payDay, 350, "pay day on a run: ...and the second (both seats on side a)")
  eq((fled(1, "wild", 0) or {}).payDay, nil, "pay day on a run: a 0 is still the field's absence")
  local gold = fled(2, "wild", 350)
  ok(gold, "pay day on a run: a Gold wild escape settles")
  eq(gold and gold.payDay, nil, "pay day on a run: Gold pays none (every escape is a DRAW)")
  local gold2 = fled(2, "coop_wild", 350)
  eq(gold2 and gold2.payDay, nil, "pay day on a run: ...in co-op neither")
  eq((fled(2, "wild", 350, "ko") or {}).payDay, 350, "pay day on a run: Gold's knockout still pays")
  local g3 = fled(3, "wild", 350)
  ok(g3, "pay day on a run: a Gen 3 wild escape settles")
  eq(g3 and g3.payDay, nil, "pay day on a run: Gen 3 pays none (HandleEndTurn_BattleWon only)")
  eq((fled(3, "wild", 350, "ko") or {}).payDay, 350, "pay day on a run: Gen 3's knockout still pays")
end

-- K13: an id is refused past 40 characters, never cut (the Node twin's cleanId).
do
  eq(Wire.id(string.rep("i", 40)), string.rep("i", 40), "id: 40 characters is an id")
  eq(Wire.id(string.rep("i", 41)), nil, "id: 41 is refused, not cut to 40")
  eq(Wire.battleReconnect({ battle = string.rep("b", 41) }), nil, "id: a long battle id refuses the message")
  local long = mon()
  long.moves[1].id = string.rep("m", 41)
  eq(Wire.battleMon(long), nil, "id: a long move id refuses the monster, as on the dedicated hub")
end

-- K13's twin: a map id is refused past 64 characters, never cut (the Node
-- twin's cleanMapId), so a step there leaves its player unplaced on this hub
-- as on the dedicated one.
do
  eq(Wire.mapId(string.rep("M", 64)), string.rep("M", 64), "map id: 64 characters is a map id")
  eq(Wire.mapId(string.rep("M", 65)), nil, "map id: 65 is refused, not cut to 64")
  local hub = Hub.new({ maxPlayers = 4 })
  local ann = join(hub, "ANN")
  local bob, bobPeer = join(hub, "BOB")
  bobPeer.outbox = {}
  hub:receive(ann, { type = Wire.MOVE, map = string.rep("M", 65), x = 3, y = 4, facing = "up" })
  local step = take(bobPeer, Wire.MOVE)
  ok(step ~= nil, "map id: a step with a long map still reaches the room")
  eq(step and step.map, nil, "map id: ...with its player unplaced")
  eq(ann.map, nil, "map id: ...and nowhere on the hub's own roster")
  hub:receive(ann, { type = Wire.MOVE, map = string.rep("M", 64), x = 3, y = 4, facing = "up" })
  step = take(bobPeer, Wire.MOVE)
  eq(step and step.map, string.rep("M", 64), "map id: a 64-character map places them")
  eq(bob.map, "PALLET", "map id: (the onlooker stays where it was)")
end

-- K14: Gold's happiness rides a Gen 2 sheet; a Gen 1 reader neither copies
-- nor refuses one, and a Gen 2 sheet with an unreadable one is refused whole.
do
  local red = mon()
  red.happiness = 70
  local read = Wire.battleMon(red)
  ok(read ~= nil, "happiness: a Red sheet stating one is still read")
  eq(read and read.happiness, nil, "happiness: ...without it (Red has no happiness byte)")
  local gold = sheet2({})
  gold.happiness = 255
  eq((Wire.battleMon(gold) or {}).happiness, 255, "happiness: a Gold sheet carries it")
  gold.happiness = 256
  eq(Wire.battleMon(gold), nil, "happiness: past one byte refuses the Gold sheet")
end

-- ------------------------------------------------------------------

io.write(string.format("hub_battle: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
