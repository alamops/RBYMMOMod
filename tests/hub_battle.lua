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

local function join(hub, name)
  local peer = fakePeer()
  local client = hub:accept(peer)
  if client then
    hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
      name = name, map = "PALLET", x = 5, y = 5, facing = "down" })
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
  ok(hub.board:points("ANN") > hub.board:points("BOB"),
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
  eq(record.npcId, "npc:npc-1", "with a synthetic seat no connection can be")
  eq(#hub:seatsNeeded(record), 3, "and three seats owe a party, not two")
  eq(hub:battleSeat(record, ann, { side = "b" }), record.npcId,
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
  eq(pvp.npcId, nil, "and no synthetic seat, because both sides are players")
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

io.write(string.format("hub_battle: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
