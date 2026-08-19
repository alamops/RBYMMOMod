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
  eq(hub:battleSeat(record, bob, { side = "b" }), bob.id,
     "a partner cannot fill the trainer's seat by claiming side b")

  local stranger = join(hub, "CAL")
  eq(hub:battleSeat(record, stranger, { side = "a" }), nil,
     "and somebody who is not in the fight fills no seat at all")

  -- An inferred plan still has to produce a field somebody can fight on.
  local pvp = hub:openMediatedBattle("pvp-1",
    { memberIds = { ann.id, bob.id, stranger.id } })
  eq(pvp.mode, "coop_pvp", "three or more is inferred as a four-way")
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
-- no sim, and the refusal charged to the authority whose upload produced it.

do
  local hub = Hub.new({ maxPlayers = 4 })
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")
  local cal = join(hub, "CAL")

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

  eq(hub:tryStartSim(record), false, "an unfightable field opens no sim")
  eq(record.sim, nil, "and the record is left exactly as it was")
  eq(ann.relayDrops, 1, "with the refusal charged to the authority")
  eq(hub.battles["bad-1"], record,
     "the record stays: nothing was settled, so nothing is cleared")
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
  local hub = Hub.new({ maxPlayers = 4 })
  local ann = join(hub, "ANN")
  local bob = join(hub, "BOB")

  hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
  hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "battle", accept = true })
  eq(ann.sessionId, "s1", "a session id carries its own letter")
  eq(Wire.id(ann.sessionId), ann.sessionId, "and is still an id on the wire")

  local coop = hub:openCoopBattle("c1", { ann.id, bob.id },
    { mode = "coop_npc", hostId = ann.id })
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

  -- A trainer seat the host uploaded no bag for is seeded with the gym kit, so
  -- a gym leader can potion.  The wild-seat block below is the other half of
  -- this claim: wildlife is never seeded, because a wild monster has no bag.
  ok(not hub:isWildSeat(record, record.npcIds[1]),
     "a coop_npc npc seat is a trainer, not wildlife")
  ok(record.bags[record.npcIds[1]] ~= nil, "so it was seeded with a gym kit")
  eq(record.sim.byId[record.npcIds[1]].bag.POTION,
     need("BattleSim/Turn").DEFAULT_NPC_BAG.POTION,
     "the kit the sim actually fights with")

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
  eq(record, nil, "coop_wild refuses without exactly two humans")
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
  eq(record, nil, "coop_wild refuses with three humans")
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

-- ------------------------------------------------------------------

io.write(string.format("hub_battle: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
