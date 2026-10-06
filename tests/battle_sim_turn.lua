-- src/BattleSim/Turn.lua: the turn machine, end to end.
--
-- Run: luajit tests/battle_sim_turn.lua            (from this folder's root)
--   or luajit mods/rby_mmo/tests/battle_sim_turn.lua  (from the engine)
--
-- Standalone for the same reason tests/battle_sim_vectors.lua is: the claim
-- src/BattleSim/ makes is that it resolves a whole fight with no love, no
-- engine modules and no mod facade, so a suite that needed any of those to run
-- would be testing something weaker than the claim.  It loads the shipped
-- files through the same `need`-shaped resolver main.lua uses.
--
-- The sibling suite pins the *formulas* against the shared vector pack.  This
-- one pins the things a vector cannot express -- the order questions get asked
-- in, what a clock does when nobody answers, and who is told they won -- and
-- the property it leans on hardest is that a battle is a pure function of its
-- seed and its choice log.  Test 1 is that property stated directly: play the
-- same script twice and every byte of both event streams has to match, because
-- the day it does not is the day the LAN host and the Node hub are running two
-- different fights from the same seed.
--
-- The last section reaches for src/Wire.lua if it happens to load, and skips
-- if it does not.  src/BattleSim/events.lua *mirrors* Wire's event vocabulary
-- rather than importing it -- Wire needs Config, this directory runs where
-- Config does not -- and a mirror nobody checks is a mirror that drifts.  So
-- when Wire is reachable, every event this sim produced is round-tripped
-- through Wire.battleEvent and has to come back unchanged.

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

local BattleSim = need("BattleSim/init")
local Turn, Events = BattleSim.Turn, BattleSim.Events

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

local function listEq(actual, expected, what)
  if type(actual) ~= "table" then return eq(tostring(actual), table.concat(expected, ","), what) end
  eq(table.concat(actual, ","), table.concat(expected, ","), what)
end

-- ------------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------------
--
-- Synthetic throughout, and that is the legal posture rather than laziness: no
-- species, move or item this repo may not name appears anywhere here.

local function move(o)
  o = o or {}
  local out = {
    id = o.id or "thump",
    pp = o.pp or 20,
    power = o.power ~= nil and o.power or 40,
    accuracy = o.accuracy or 255,
    type = o.type or 0,
    effect = o.effect or 0,
    chance = o.chance or 0,
  }
  if o.maxPp then out.maxPp = o.maxPp end
  if o.highCrit then out.highCrit = true end
  return out
end

local function mon(o)
  o = o or {}
  local out = {
    species = o.species or "Alpha",
    level = o.level or 20,
    hp = o.hp,
    maxHp = o.maxHp or 60,
    status = o.status,
    types = o.types,
    stats = {
      atk = o.atk or 40, def = o.def or 40,
      spd = o.spd or 40, spc = o.spc or 40,
    },
    moves = o.moves or { move() },
  }
  if o.stages then out.stages = o.stages end
  if o.mist then out.mist = true end
  if o.substitute then out.substitute = o.substitute end
  if o.confusion then out.confusion = o.confusion end
  if o.catchRate ~= nil then out.catchRate = o.catchRate end
  if o.speciesId then out.speciesId = o.speciesId end
  if o.evs then out.evs = o.evs end
  if o.baseSpd ~= nil then out.baseSpd = o.baseSpd end
  return out
end

local function battleOf(o)
  o = o or {}
  local battle, err = Turn.create({
    id = o.id or "b1",
    mode = o.mode or "1v1",
    seed = o.seed or 12345,
    chart = o.chart,
    specialTypes = o.specialTypes,
    metronomePool = o.metronomePool,
    choiceTimeout = o.choiceTimeout or 60,
    reconnectGrace = o.reconnectGrace or 60,
    sides = o.sides or {
      a = { { playerId = "p1", name = "Ann",
              mons = o.aMons or { mon() }, bag = o.aBag } },
      b = { { playerId = "p2", name = "Bob",
              mons = o.bMons or { mon({ species = "Beta" }) },
              bag = o.bBag } },
    },
  })
  if not battle then error("fixture battle refused: " .. tostring(err), 0) end
  return battle
end

local function dumpMove(m)
  return string.format("id=%s,pp=%d,maxPp=%s,ppUps=%s,power=%d,accuracy=%d,type=%d,effect=%d,chance=%d",
    m.id, m.pp, tostring(m.maxPp), tostring(m.ppUps), m.power, m.accuracy, m.type, m.effect, m.chance)
end

local function dumpValue(v)
  if type(v) == "table" then
    if v[1] and type(v[1]) == "table" and type(v[1].id) == "string" then
      local parts = {}
      for i, m in ipairs(v) do parts[i] = "{" .. dumpMove(m) .. "}" end
      return "[" .. table.concat(parts, ",") .. "]"
    end
  end
  return tostring(v)
end

local function dump(event)
  local keys = {}
  for key in pairs(event) do keys[#keys + 1] = key end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = key .. "=" .. dumpValue(event[key])
  end
  return table.concat(parts, ",")
end

local function dumpAll(list)
  local out = {}
  for i, event in ipairs(list) do out[i] = dump(event) end
  return table.concat(out, "|")
end

local function kinds(list)
  local seen = {}
  for _, event in ipairs(list) do seen[event.t] = (seen[event.t] or 0) + 1 end
  return seen
end

local function fighterIn(snap, playerId)
  for _, entry in ipairs(snap.field) do
    if entry.playerId == playerId then return entry end
  end
  return nil
end

-- Every event any battle in this file emits ends up here, so the vocabulary
-- checks at the bottom see the whole surface rather than one scenario's.
--
-- Contiguity is counted here rather than at the bottom because it is a
-- per-battle property and several fixtures deliberately share an id: a client
-- reads a gap in `seq` as lost messages and asks for a resync, so a stream
-- that skips a number is a real bug even though every individual event is
-- well-formed.  Keying on the battle table itself is what keeps two runs of
-- the same fixture from looking like one stream that restarted.
local everyEvent = {}
local lastSeq, seqGaps = {}, 0

local function drain(battle)
  local list = battle:drainEvents()
  for _, event in ipairs(list) do
    everyEvent[#everyEvent + 1] = event
    local previous = lastSeq[battle]
    if previous and event.seq ~= previous + 1 then seqGaps = seqGaps + 1 end
    lastSeq[battle] = event.seq
  end
  return list
end

-- ------------------------------------------------------------------
-- 1. determinism: same seed, same script, same fight
-- ------------------------------------------------------------------

local function play(seed)
  local battle = battleOf({
    seed = seed,
    aMons = {
      mon({ species = "Alpha", maxHp = 120, atk = 60, spd = 55 }),
      mon({ species = "Gamma", maxHp = 90 }),
    },
    bMons = {
      mon({ species = "Beta", maxHp = 120, atk = 58, spd = 55 }),
      mon({ species = "Delta", maxHp = 90 }),
    },
  })

  local function fightOrReplace(playerId)
    local snap = battle:snapshot()
    for _, f in ipairs(snap.field or {}) do
      if f.playerId == playerId and f.mustReplace then
        local slot = nil
        for i, hp in ipairs(f.party or {}) do
          if (hp or 0) > 0 then slot = i - 1; break end
        end
        if slot ~= nil then
          return battle:submitChoice(playerId, { action = "switch", slot = slot })
        end
        return false
      end
    end
    return battle:submitChoice(playerId, { action = "fight", move = 0 })
  end

  local log = {}
  for _ = 1, 40 do
    if battle:outcome() then break end
    fightOrReplace("p1")
    fightOrReplace("p2")
    log[#log + 1] = dumpAll(drain(battle))
    for _, entry in ipairs(battle:snapshot().field) do
      log[#log + 1] = entry.playerId .. " " ..
        tostring(entry.species) .. " " .. entry.hp
    end
  end

  local out = battle:outcome()
  log[#log + 1] = out
    and (out.outcome .. "/" .. tostring(out.reason) .. "/" ..
         table.concat(out.winners or {}, "+"))
    or "unfinished"
  return table.concat(log, "\n"), out
end

do
  local first, outcome = play(4242)
  local second = play(4242)
  eq(first, second, "same seed and script replay identically")
  ok(outcome ~= nil, "the scripted fight actually ended")
  ok(first ~= play(9001), "a different seed produces a different fight")

  -- Equal speeds on both sides, so the tie-break byte is genuinely exercised
  -- above rather than the fight always resolving side a first.
  ok(first:find("Beta"), "both sides appear in the trail")
end

-- ------------------------------------------------------------------
-- 1b. the party the caller handed over is not the party that fights
-- ------------------------------------------------------------------
--
-- The determinism above is only true because create() deep-copies.  A sim that
-- damaged the caller's tables in place would still pass test 1 -- it builds
-- fresh fixtures each run -- and would then quietly make the *second* fight
-- from a saved party a different fight, which is the bug this states outright.

do
  local party = { mon({ species = "Alpha", maxHp = 200, hp = 200 }) }
  local moves = party[1].moves
  local battle = battleOf({ aMons = party, bMons = { mon({ maxHp = 200 }) } })
  drain(battle)

  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)

  ok(fighterIn(battle:snapshot(), "p1").hp < 200, "the fight really happened")
  eq(party[1].hp, 200, "the caller's monster kept its HP")
  eq(moves[1].pp, 20, "and its PP")
  eq(party[1].status, nil, "and its condition")

  eq(#battle:drainEvents(), 0, "a drained buffer comes back empty")
end

-- ------------------------------------------------------------------
-- 1c. what a send says about the monster it fields
-- ------------------------------------------------------------------
--
-- `text` is the token the fight is *narrated* under, and on a real upload that
-- token is the player's nickname wherever their monster has one -- so it is the
-- one thing on the event that the client opposite cannot look anything up by.
-- `speciesId` and `level` ride beside it for exactly that seat: without them it
-- has no front pic to draw, no number for the level pill, and (on the faint) no
-- base rate to price the award with.  Both are pass-through -- no formula here
-- reads either, and there is no species table to read them against.

do
  local battle = battleOf({
    aMons = { mon({ species = "Nickname", speciesId = "alpha", level = 33 }) },
    bMons = { mon({ species = "Beta" }) },
  })
  local sends = {}
  for _, event in ipairs(drain(battle)) do
    if event.t == "send" then sends[event.slot] = event end
  end
  ok(sends[0] ~= nil and sends[3] ~= nil, "the opening fields both seats")
  eq(sends[0].text, "Nickname", "the send narrates under the uploaded token")
  eq(sends[0].speciesId, "alpha", "...and states the registry id beside it")
  eq(sends[0].level, 33, "...and the level, which nothing else on the wire says")
  eq(sends[3].speciesId, nil, "a sheet that stated no id produces no field")
  eq(sends[3].level, 20, "...though the level is always known")
  ok(Events.check(sends[0]), "and the event is one Wire's whitelist accepts")

  -- `maxHp` is the same kind of field for the same reason: every other reading
  -- of HP on this wire is a current number, so a client that was told only
  -- `hp` had to take the largest it had ever seen on a seat for that seat's
  -- maximum -- right for a monster sent out whole, and wrong for every one
  -- that walks out already hurt.  The referee has held the real maximum since
  -- it built the battler, so it says it.
  eq(sends[0].maxHp, 60, "a send states what its HP is out of")
  eq(sends[0].hp, 60, "...which the opening send matches, nobody having moved")
end

-- ...and a monster that walked in already statused. A `status` event is an
-- inflict or a lift; the condition it *arrived* with is a fact about the
-- occupant, and without it on the send the plate draws a healthy card.
do
  local battle = battleOf({
    aMons = { mon({ status = "PSN" }) },
    bMons = { mon({ species = "Beta", status = "SLP" }) },
  })
  local sends = {}
  for _, event in ipairs(drain(battle)) do
    if event.t == "send" then sends[event.slot] = event end
  end
  eq(sends[0] and sends[0].status, "PSN",
     "a send names the poison the occupant walked in with")
  eq(sends[3] and sends[3].status, "SLP",
     "...and the sleeper on the other seat, so both cards can show a chip")
  ok(Events.check(sends[0]), "still an event Wire's whitelist accepts")
end

-- Confusion is a fight-local volatile, not a standing status. A send names
-- it with `confused=1` so the plate can draw CNF without putting CNF on the
-- party sheet; an inflict is a status event with the same flag and no token.
do
  local battle = battleOf({
    aMons = { mon({ confusion = 3, status = "PSN" }) },
    bMons = { mon({ species = "Beta" }) },
  })
  local send
  for _, event in ipairs(drain(battle)) do
    if event.t == "send" and event.slot == 0 then send = event end
  end
  eq(send and send.confused, 1,
     "a send names the confusion the occupant walked in with")
  eq(send and send.status, "PSN", "...without dropping the standing poison")
  ok(Events.check(send), "still an event Wire's whitelist accepts")
end

do
  local battle = battleOf({
    aMons = { mon({ spd = 90,
      moves = { move({ id = "daze", power = 0, effect = 49, accuracy = 255 }) } }) },
    bMons = { mon({ species = "Beta", spd = 10 }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local inflicted
  for _, event in ipairs(drain(battle)) do
    if event.t == "status" and event.confused == 1 then inflicted = event end
  end
  ok(inflicted ~= nil, "confuse-ray emits a status event with confused=1")
  eq(inflicted and inflicted.status, nil,
     "...and no standing-status token, so PSN is not wiped")
  ok(inflicted and Events.check(inflicted),
     "still an event Wire's whitelist accepts")
end

do
  -- turnsRemaining 1 always snaps out (Status.confusionTick).
  local battle = battleOf({
    aMons = { mon({ confusion = 1, spd = 90 }) },
    bMons = { mon({ species = "Beta", spd = 10 }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local snapped
  for _, event in ipairs(drain(battle)) do
    if event.t == "status" and event.confused == 0 then snapped = event end
  end
  ok(snapped ~= nil, "snapping out emits confused=0")
  eq(snapped and snapped.status, nil,
     "...without a standing-status token, so PSN would be left alone")
end

-- ...and the case the guess got wrong, stated outright: a party monster that
-- walked into this fight from the last one, hurt.
do
  local battle = battleOf({
    aMons = { mon({ maxHp = 200, hp = 42 }) },
    bMons = { mon({ species = "Beta" }) },
  })
  local send
  for _, event in ipairs(drain(battle)) do
    if event.t == "send" and event.slot == 0 then send = event end
  end
  ok(send ~= nil, "the hurt monster is fielded")
  eq(send.hp, 42, "the send carries the HP it really has")
  eq(send.maxHp, 200, "...and the maximum that HP is a fifth of")
  ok(Events.check(send), "still an event Wire's whitelist accepts")
end

-- ------------------------------------------------------------------
-- 2. a KO ends the battle, and names who won
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    aMons = { mon({ species = "Alpha", maxHp = 300, atk = 150, spd = 120, level = 50 }) },
    bMons = { mon({ species = "Beta", maxHp = 1, atk = 5, spd = 10, level = 5 }) },
  })

  local all = {}
  for _ = 1, 5 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    for _, event in ipairs(drain(battle)) do all[#all + 1] = event end
  end

  local out = battle:outcome()
  ok(out ~= nil, "a KO ends the battle")
  if out then
    eq(out.battle, "b1", "the outcome names the battle")
    eq(out.outcome, "win", "a decided fight is a win from the field's side")
    eq(out.reason, "ko", "and the reason is ko")
    listEq(out.winners, { "p1" }, "the survivor won")
    listEq(out.losers, { "p2" }, "the wiped side lost")
  end

  local seen = kinds(all)
  ok((seen.faint or 0) >= 1, "the KO emitted a faint")
  ok((seen.over or 0) == 1, "the battle emitted exactly one over")
  eq(battle:snapshot().phase, "over", "the phase settles on over")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }) == false,
     "a finished battle refuses further choices")
end

-- ------------------------------------------------------------------
-- 3. disconnect: grace runs out, the side forfeits
-- ------------------------------------------------------------------

do
  local battle = battleOf({ reconnectGrace = 60 })
  drain(battle)

  ok(battle:disconnect("p2") == true, "a live player can drop")
  ok(battle:disconnect("p2") == false, "dropping twice is refused")
  ok(battle:disconnect("nobody") == false, "an unknown player cannot drop")

  local waiting = kinds(drain(battle))
  eq(waiting.wait, 1, "the drop announced itself with wait")

  ok(battle:tick(30) == false, "nothing fires inside the grace window")
  ok(battle:outcome() == nil, "and the battle is still open")

  ok(battle:tick(61) == true, "the grace expiry is a tick that did something")
  local out = battle:outcome()
  ok(out ~= nil, "past the grace the battle is over")
  if out then
    eq(out.outcome, "forfeit", "a dropped side forfeits")
    eq(out.reason, "disconnect", "for the disconnect reason")
    listEq(out.winners, { "p1" }, "the player who stayed won")
    listEq(out.losers, { "p2" }, "the player who dropped lost")
  end
  eq(kinds(drain(battle)).over, 1, "the forfeit emitted over")
end

-- ------------------------------------------------------------------
-- 3b. a wedged resolve aborts on the wall-clock ceiling
-- ------------------------------------------------------------------

do
  local battle = battleOf({ resolveTimeout = 30 })
  drain(battle)
  -- Force the stuck state a throw mid-resolve leaves behind: phase resolving,
  -- deadline already in the past, nothing else to wait on.
  battle.phase = "resolving"
  battle.resolveDeadline = battle.now - 1
  ok(battle:tick(battle.now) == true, "a past resolveDeadline is a tick that acted")
  local out = battle:outcome()
  ok(out ~= nil, "the ceiling ends the fight")
  if out then
    eq(out.outcome, "draw", "as a draw -- nobody won a stuck resolve")
    eq(out.reason, "timeout", "under the existing timeout reason")
  end
  eq(battle:snapshot().phase, "over", "and the phase settles on over")
  eq(battle:snapshot().resolveDeadline, nil, "with the deadline cleared")
end

-- ------------------------------------------------------------------
-- 4. reconnect inside the window, and the fight carries on
-- ------------------------------------------------------------------

do
  local battle = battleOf({ reconnectGrace = 60, choiceTimeout = 60 })
  drain(battle)

  battle:disconnect("p1")
  battle:tick(30)
  ok(battle:reconnect("p1") == true, "a dropped player can come back inside grace")
  ok(battle:reconnect("p1") == false, "coming back twice is refused")
  eq(kinds(drain(battle)).reconnect, 1, "the return announced itself")

  battle:tick(61)
  ok(battle:outcome() == nil, "a grace that was cleared does not fire later")
  eq(battle:snapshot().phase, "choice", "the fight is back to asking for choices")

  ok(battle:submitChoice("p1", { action = "fight", move = 0 }) == true,
     "the returning player may choose")
  ok(battle:submitChoice("p2", { action = "fight", move = 0 }) == true,
     "and the turn completes")
  eq(battle:snapshot().turn, 2, "a resolved turn opens the next one")
  eq(kinds(drain(battle)).turn, 1, "which asks for choices again")

  -- The clock the drop suspended: while somebody is away, only the grace runs.
  local paused = battleOf({ reconnectGrace = 600, choiceTimeout = 10 })
  drain(paused)
  paused:disconnect("p2")
  paused:tick(120)
  eq(paused:snapshot().turn, 1, "the choice clock is suspended while a side is away")
  ok(paused:outcome() == nil, "and no timeout resolved it behind their back")
end

-- ------------------------------------------------------------------
-- 4b. a dropped seat cannot file until reconnect()
-- ------------------------------------------------------------------

do
  local battle = battleOf({ reconnectGrace = 60, choiceTimeout = 60 })
  drain(battle)

  battle:disconnect("p1")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }) == false,
     "a disconnected seat cannot file a choice")
  ok(battle:submitChoice("p2", { action = "fight", move = 0 }) == true,
     "the seat that stayed may still file")
  eq(battle:snapshot().turn, 1,
     "the turn does not resolve on the dropped seat's leftover")

  battle:reconnect("p1")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }) == true,
     "reconnect restores the right to choose")
  eq(battle:snapshot().turn, 2, "and the already-filed peer lets the turn complete")
end

do
  local battle = battleOf({ reconnectGrace = 60, choiceTimeout = 60 })
  drain(battle)

  ok(battle:submitChoice("p1", { action = "fight", move = 0 }) == true,
     "a connected seat may file before it drops")
  battle:disconnect("p1")
  ok(battle:submitChoice("p2", { action = "fight", move = 0 }) == true,
     "the seat that stayed may still file after the drop")
  eq(battle:snapshot().turn, 1,
     "a leftover choice does not resolve the turn while a seat is away")

  battle:reconnect("p1")
  eq(battle:snapshot().turn, 2,
     "reconnect completes the already-answered turn without a second pick")
end

-- ------------------------------------------------------------------
-- 5. the choice clock: a timeout picks a move rather than ending the fight
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    choiceTimeout = 10,
    aMons = { mon({ species = "Alpha", maxHp = 200, spd = 90 }) },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 10 }) },
  })
  drain(battle)

  eq(battle:snapshot().deadline, 10, "creating the battle armed the clock")
  battle:submitChoice("p1", { action = "fight", move = 0 })
  listEq(battle:snapshot().waiting, { "p2" }, "one side is still owed")
  do
    local early = drain(battle)
    local chose = nil
    for _, event in ipairs(early) do
      if event.t == "chose" then chose = event end
    end
    ok(chose ~= nil, "filing a choice emits chose before the turn resolves")
    if chose then
      eq(chose.slot, 0, "naming the field slot that answered")
      eq(chose.text, "Ann", "and the trainer name for the wait line")
    end
  end

  ok(battle:submitChoice("p1", { action = "cancel" }) == true,
     "a filed choice can be taken back")
  do
    local cancelled = drain(battle)
    local unchose = nil
    for _, event in ipairs(cancelled) do
      if event.t == "unchose" then unchose = event end
    end
    ok(unchose ~= nil, "cancelling a choice emits unchose")
    if unchose then
      eq(unchose.slot, 0, "naming the field slot that walked back")
      eq(unchose.text, "Ann", "and the trainer name for the wait line")
    end
  end

  ok(battle:tick(9) == false, "the clock has not run out yet")
  eq(battle:snapshot().turn, 1, "so the turn is still open")

  ok(battle:tick(11) == true, "past the deadline the tick resolves the turn")
  ok(battle:outcome() == nil, "a timeout does not end the battle")
  eq(battle:snapshot().turn, 2, "it spends the turn and opens the next")

  local snap = battle:snapshot()
  ok(fighterIn(snap, "p1").hp < 200, "the auto-picked move was actually used")
  eq(snap.deadline, 21, "and the next turn re-arms the clock")
end

-- ------------------------------------------------------------------
-- 6. what a choice may say
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    aMons = {
      mon({ species = "Alpha", moves = { move(), move({ id = "empty", pp = 0 }) } }),
      mon({ species = "Gamma" }),
      mon({ species = "Down", hp = 0 }),
    },
  })
  drain(battle)

  ok(battle:submitChoice("ghost", { action = "fight", move = 0 }) == false,
     "an unknown player is refused")
  ok(battle:submitChoice("p1", { action = "wander" }) == false,
     "an action outside the vocabulary is refused")
  ok(battle:submitChoice("p1", { action = "fight" }) == false,
     "fight with no move is refused")
  ok(battle:submitChoice("p1", { action = "fight", move = 7 }) == false,
     "a move index that names nothing is refused")
  ok(battle:submitChoice("p1", { action = "fight", move = 1 }) == false,
     "a move with no PP left is refused")
  ok(battle:submitChoice("p1", { action = "switch", slot = 2 }) == false,
     "switching to a fainted monster is refused")
  ok(battle:submitChoice("p1", { action = "switch", slot = 0 }) == false,
     "switching to the monster already out is refused")
  ok(battle:submitChoice("p1", { action = "item" }) == false,
     "an item choice with no item is refused")
  ok(battle:submitChoice("p1", { action = "item", item = "POTION", slot = 2 }) == false,
     "Potion on a fainted mon is refused")
  ok(battle:submitChoice("p1", { action = "item", item = "PROTEIN", slot = 2 }) == false,
     "Protein on a fainted mon is refused")
  ok(battle:submitChoice("p1", { action = "item", item = "REVIVE", slot = 0 }) == false,
     "Revive on a living mon is refused")
  ok(battle:submitChoice("p1", { action = "fight", move = 0, target = 1 }) == false,
     "a target nobody occupies is refused")
  ok(battle:submitChoice("p1", { action = "fight", move = 0, target = 0 }) == false,
     "and so is aiming at your own slot")
  ok(battle:submitChoice("p1", { action = "cancel" }) == false,
     "cancelling nothing is refused")

  ok(battle:submitChoice("p1", { action = "fight", move = 0, target = 3 }) == true,
     "a well-formed choice is accepted")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }) == false,
     "a second choice in the same turn is refused")
  ok(battle:submitChoice("p1", { action = "cancel" }) == true,
     "but the first one can be taken back")
  ok(battle:submitChoice("p1", { action = "switch", slot = 1 }) == true,
     "and replaced")

  battle:submitChoice("p2", { action = "fight", move = 0 })
  local seen = kinds(drain(battle))
  eq(seen.switch, 1, "the switch resolved")
  eq(fighterIn(battle:snapshot(), "p1").species, "Gamma", "with the new monster out")
end

-- ------------------------------------------------------------------
-- 7. running is a concession, and mutual running is a draw
-- ------------------------------------------------------------------

do
  local battle = battleOf()
  drain(battle)
  battle:submitChoice("p1", { action = "run" })
  battle:submitChoice("p2", { action = "fight", move = 0 })

  local out = battle:outcome()
  ok(out ~= nil, "one side running ends the fight")
  if out then
    eq(out.outcome, "win", "the side that stayed wins")
    eq(out.reason, "run", "for the run reason")
    listEq(out.winners, { "p2" }, "and is named as the winner")
    listEq(out.losers, { "p1" }, "the runner is the loser")
  end
  eq(kinds(drain(battle)).run, 1, "the flight was announced")

  local both = battleOf()
  drain(both)
  both:submitChoice("p1", { action = "run" })
  both:submitChoice("p2", { action = "run" })
  local drawn = both:outcome()
  ok(drawn ~= nil, "both running ends the fight too")
  if drawn then
    eq(drawn.outcome, "draw", "with a draw")
    eq(drawn.reason, "run", "for the same reason")
    eq(drawn.winners, nil, "a draw names no winners")
    eq(drawn.losers, nil, "and no losers")
  end
  eq(kinds(drain(both)).run, 2, "both flights were announced")
end

-- ------------------------------------------------------------------
-- 7b. trainer RUN does not forfeit; wild and pvp still end the fight
-- ------------------------------------------------------------------
--
-- `_resolveRuns` used to be mode-blind: any run finished the fight and the
-- runner lost. Hub-refereed gyms (mode coop_npc) then blacked the player out
-- on RUN. Gated the same way Teleport already is.
--
-- R1e: and the cart's gate is at the menu.  TryRunningFromBattle's
-- `.trainerBattle` prints NoRunningText and leaves wActionResultOrTookBattleTurn
-- at 0, so BattleMenu_RunWasSelected goes back to DisplayBattleMenu: the turn
-- is not spent.  The referee refuses the choice, the seat still owes one, and
-- the line is the client's own (it declines to send the RUN, as the cart's
-- menu does).

-- Exact: Wire.M.text strips newlines, so a three-line vanilla string would
-- survive a `/running/` check as "norunning" and still display mangled.
local TRAINER_RUN_REFUSAL = "No! There's no running from a trainer battle!"

local function saidRunning(events)
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == TRAINER_RUN_REFUSAL then
      return true
    end
  end
  return false
end

do
  local battle = battleOf({
    mode = "coop_npc",
    aMons = { mon({ species = "Alpha", maxHp = 200 }) },
    bMons = { mon({ species = "Beta", maxHp = 200, atk = 80 }) },
  })
  drain(battle)
  local turnBefore = battle:snapshot().turn
  local hpBefore = fighterIn(battle:snapshot(), "p1").hp
  eq(battle:submitChoice("p1", { action = "run" }), false,
     "coop_npc RUN is refused at the menu (the cart's DisplayBattleMenu again)")
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local out = drain(battle)
  eq(battle:outcome(), nil, "coop_npc RUN does not finish the fight")
  ok(not saidRunning(out), "the refusal line is the client's, not the referee's")
  eq(kinds(out).over, nil, "with no over event")
  eq(kinds(out).run, nil, "and no run event -- that kind means someone fled")
  eq(battle:snapshot().turn, turnBefore, "the turn is not spent: it waits on the runner")
  eq(battle.byId.p1.choice, nil, "...whose seat still owes its answer")
  eq(fighterIn(battle:snapshot(), "p1").hp, hpBefore, "so the foe has not attacked yet")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "the re-asked FIGHT is taken")
  drain(battle)
  eq(battle:snapshot().turn, turnBefore + 1, "and the turn resolves")
  ok(fighterIn(battle:snapshot(), "p1").hp < hpBefore, "with the foe's attack in it")
end

do
  local battle = battleOf({
    mode = "coop_npc",
    sides = {
      a = {
        { playerId = "p1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200 }) } },
        { playerId = "p2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200 }) } },
      },
      b = {
        { playerId = "n1", name = "NpcA",
          mons = { mon({ species = "Beta", maxHp = 200 }) } },
        { playerId = "n2", name = "NpcB",
          mons = { mon({ species = "Delta", maxHp = 200 }) } },
      },
    },
  })
  drain(battle)
  eq(battle:submitChoice("p1", { action = "run" }), false, "one partner's RUN is refused too")
  battle:submitChoice("p2", { action = "fight", move = 0 })
  battle:autoPick("n1")
  battle:autoPick("n2")
  local out = drain(battle)
  eq(battle:outcome(), nil, "one partner's RUN does not forfeit a 2v2 gym")
  eq(battle.phase, "choice", "...and the turn holds for the runner's real answer")
  ok(not saidRunning(out), "with no refusal line from the referee")
end

do
  local battle = battleOf({
    mode = "coop_wild",
    sides = {
      a = {
        { playerId = "p1", name = "Ann", mons = { mon({ species = "Alpha" }) } },
        { playerId = "p2", name = "Abe", mons = { mon({ species = "Gamma" }) } },
      },
      b = {
        { playerId = "wild", name = "Wild", mons = { mon({ species = "Beta" }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "run" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  battle:autoPick("wild")
  drain(battle)
  local out = battle:outcome()
  ok(out ~= nil, "coop_wild RUN still ends the fight")
  if out then
    eq(out.reason, "run", "as a flee")
    listEq(out.losers, { "p1", "p2" }, "the fleeing side loses")
  end
end

do
  local battle = battleOf({ mode = "coop_pvp" })
  drain(battle)
  battle:submitChoice("p1", { action = "run" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local out = battle:outcome()
  ok(out ~= nil, "coop_pvp RUN is still a concession")
  if out then
    eq(out.reason, "run", "for the run reason")
    listEq(out.losers, { "p1" }, "the runner loses")
  end
end

-- ------------------------------------------------------------------
-- 8. the item stub: announced, and it costs the turn
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    aMons = { mon({ species = "Alpha", maxHp = 200 }) },
    bMons = { mon({ species = "Beta", maxHp = 200 }) },
  })
  drain(battle)

  battle:submitChoice("p1", { action = "item", item = "restore" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local seen = kinds(drain(battle))

  eq(seen.item, 1, "the item announced itself")
  eq(battle:snapshot().turn, 2, "and the turn resolved")
  eq(fighterIn(battle:snapshot(), "p2").hp, 200, "the item did nothing to the foe")
  ok(fighterIn(battle:snapshot(), "p1").hp < 200, "and cost the turn it was used on")
end

-- ------------------------------------------------------------------
-- 9. the type chart, including the row that says "no"
-- ------------------------------------------------------------------

do
  -- chart[atkType + 1][defType + 1]: a move of type 0 does nothing at all to a
  -- defender of type 1, and the reverse matchup is ordinary.
  local battle = battleOf({
    chart = { { 100, 0 }, { 100, 100 } },
    aMons = { mon({ species = "Alpha", maxHp = 200, types = { 0 } }) },
    bMons = { mon({ species = "Beta", maxHp = 200, types = { 1 } }) },
  })
  drain(battle)

  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)

  eq(fighterIn(battle:snapshot(), "p2").hp, 200, "an immune defender takes nothing")
  ok(fighterIn(battle:snapshot(), "p1").hp < 200, "while the neutral hit lands")

  -- No chart at all is neutral rather than refused.
  local bare = battleOf({
    aMons = { mon({ species = "Alpha", maxHp = 200, types = { 9 } }) },
    bMons = { mon({ species = "Beta", maxHp = 200, types = { 9 } }) },
  })
  drain(bare)
  bare:submitChoice("p1", { action = "fight", move = 0 })
  bare:submitChoice("p2", { action = "fight", move = 0 })
  drain(bare)
  ok(fighterIn(bare:snapshot(), "p2").hp < 200,
     "a type the chart never heard of reads as neutral")
end

-- ------------------------------------------------------------------
-- 10. status: the gates fire, and residuals bite
-- ------------------------------------------------------------------

do
  local frozen = battleOf({
    aMons = { mon({ species = "Alpha", maxHp = 200, status = "FRZ" }) },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1 }) },
  })
  drain(frozen)
  frozen:submitChoice("p1", { action = "fight", move = 0 })
  frozen:submitChoice("p2", { action = "fight", move = 0 })
  drain(frozen)
  eq(fighterIn(frozen:snapshot(), "p2").hp, 200, "a frozen monster never moves")
  eq(fighterIn(frozen:snapshot(), "p1").status, "FRZ", "and stays frozen")

  local burned = battleOf({
    aMons = { mon({ species = "Alpha", maxHp = 160, status = "BRN" }) },
    bMons = { mon({ species = "Beta", maxHp = 200 }) },
  })
  drain(burned)
  burned:submitChoice("p1", { action = "fight", move = 0 })
  burned:submitChoice("p2", { action = "fight", move = 0 })
  local seen = kinds(drain(burned))
  ok((seen.damage or 0) >= 3, "the burn residual is its own damage event")
  eq(burned:snapshot().turn, 2, "and the turn still completed")

  local asleep = battleOf({
    aMons = { mon({ species = "Alpha", maxHp = 200, status = "SLP" }) },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1 }) },
  })
  drain(asleep)
  asleep:submitChoice("p1", { action = "fight", move = 0 })
  asleep:submitChoice("p2", { action = "fight", move = 0 })
  drain(asleep)
  eq(fighterIn(asleep:snapshot(), "p1").status, nil,
     "a one-turn sleep wakes up")
  eq(fighterIn(asleep:snapshot(), "p2").hp, 200,
     "and still loses the turn it woke on")
end

-- ------------------------------------------------------------------
-- 11. 2v2: four field slots, and a turn that resolves across them
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    mode = "coop_pvp",
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = { mon({ species = "Alpha", maxHp = 200, spd = 80 }) } },
        { playerId = "a2", name = "Abe", mons = { mon({ species = "Gamma", maxHp = 200, spd = 70 }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = { mon({ species = "Beta", maxHp = 200, spd = 60 }) } },
        { playerId = "b2", name = "Bea", mons = { mon({ species = "Delta", maxHp = 200, spd = 50 }) } },
      },
    },
  })
  drain(battle)

  local snap = battle:snapshot()
  eq(#snap.field, 4, "a 2v2 puts four fighters on the field")
  local slots = {}
  for _, entry in ipairs(snap.field) do slots[#slots + 1] = entry.slot end
  listEq(slots, { 0, 1, 3, 4 }, "numbered side a first, then side b (slots 0,1 and 3,4)")

  battle:submitChoice("a1", { action = "fight", move = 0 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
  battle:submitChoice("b1", { action = "fight", move = 0 })
  eq(battle:snapshot().turn, 1, "the turn waits on the fourth player")
  do
    local mid = kinds(drain(battle))
    eq(mid.chose, 3, "each accepted answer emits chose for the wait line")
    eq(mid.turn, nil, "and the turn has not closed yet")
  end
  battle:submitChoice("b2", { action = "fight", move = 0 })
  do
    local closed = kinds(drain(battle))
    eq(closed.chose, 1, "the last answer also emits chose")
    eq(closed.turn, 1, "then the next turn opens")
  end
  eq(battle:snapshot().turn, 2, "and resolves once everybody has answered")

  local after = battle:snapshot()
  ok(fighterIn(after, "b2").hp < 200, "a named target on the far slot was hit")

  -- One player dropping in a 2v2 still forfeits the pair: the side is the unit
  -- a mediated fight is scored on, which is why the outcome carries lists.
  battle:disconnect("b1")
  battle:tick(1000)
  local out = battle:outcome()
  ok(out ~= nil, "the grace expiry ends the 2v2 too")
  if out then
    listEq(out.winners, { "a1", "a2" }, "the whole intact side won")
    listEq(out.losers, { "b1", "b2" }, "and the whole dropped side lost")
  end
end

-- ------------------------------------------------------------------
-- 12. create refuses what it cannot fight, and says why
-- ------------------------------------------------------------------

do
  local function refused(opts, what)
    local battle, err = Turn.create(opts)
    ok(battle == nil and type(err) == "string", what)
  end

  refused(nil, "no options is refused")
  refused({ sides = { a = {}, b = {} } }, "an empty side is refused")
  refused({ sides = { a = { { playerId = "p1", mons = { mon() } } } } },
          "a missing opposing side is refused")
  refused({ sides = {
    a = { { playerId = "p1", mons = { mon() } } },
    b = { { playerId = "p1", mons = { mon() } } },
  } }, "a duplicate playerId is refused")
  refused({ sides = {
    a = { { playerId = "p1", mons = {} } },
    b = { { playerId = "p2", mons = { mon() } } },
  } }, "an empty party is refused")
  refused({ mode = "1v1", sides = {
    a = { { playerId = "p1", mons = { mon() } }, { playerId = "p3", mons = { mon() } } },
    b = { { playerId = "p2", mons = { mon() } } },
  } }, "a second fighter in a 1v1 is refused")
end

-- ------------------------------------------------------------------
-- 15. Struggle when every move is out of PP
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, atk = 80, level = 40,
        moves = {
          move({ id = "spent-a", pp = 0, power = 40 }),
          move({ id = "spent-b", pp = 0, power = 60 }),
        },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1 }) },
  })
  drain(battle)

  ok(battle:submitChoice("p1", { action = "fight", move = 0 }) == true,
     "fight is allowed when every move is out of PP")
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local anim, recoil = nil, false
  for _, event in ipairs(events) do
    if event.t == "anim" and event.text == "STRUGGLE" then anim = event end
    if event.t == "msg" and event.text:find("recoil", 1, true) then
      recoil = true
    end
  end
  ok(anim ~= nil, "all PP empty uses Struggle animation")
  ok(recoil, "Struggle recoil is announced")

  local snap = battle:snapshot()
  ok(fighterIn(snap, "p2").hp < 200, "Struggle damages the foe")
  ok(fighterIn(snap, "p1").hp < 200, "Struggle recoils the user")
end

-- ------------------------------------------------------------------
-- 16. auto-pick prefers a super-effective damaging move
-- ------------------------------------------------------------------

do
  -- chart[atk+1][def+1]: type 0 vs type 1 is 200%, type 1 vs type 1 is 100%.
  local chart = { { 100, 200 }, { 100, 100 } }
  local battle = battleOf({
    chart = chart,
    choiceTimeout = 10,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 10,
        moves = {
          move({ id = "se-hit", type = 0, power = 40 }),
          move({ id = "hard-neutral", type = 1, power = 60 }),
        },
      }),
    },
    bMons = {
      mon({ species = "Beta", maxHp = 200, spd = 90, types = { 1 } }),
    },
  })
  drain(battle)

  battle:submitChoice("p2", { action = "fight", move = 0 })
  ok(battle:tick(11) == true, "timeout auto-picks for the slow side")
  local events = drain(battle)

  local used = nil
  for _, event in ipairs(events) do
    if event.t == "anim" and event.slot == 0 then used = event.text end
  end
  eq(used, "se-hit", "auto-pick prefers the super-effective move over higher power")
  ok(fighterIn(battle:snapshot(), "p2").hp < 200,
     "the super-effective auto-pick actually landed")
end

-- ------------------------------------------------------------------
-- 16b. auto-pick: status / setup / SE bench switch when no SE damage
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    choiceTimeout = 10,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 10,
        moves = {
          move({ id = "thump", power = 40 }),
          move({ id = "sleep-powder", power = 0, effect = 32, accuracy = 255 }),
        },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 90 }) },
  })
  drain(battle)
  battle:submitChoice("p2", { action = "fight", move = 0 })
  ok(battle:tick(11) == true, "timeout status-picks when no SE damage")
  local events = drain(battle)
  local used = nil
  for _, event in ipairs(events) do
    if event.t == "anim" and event.slot == 0 then used = event.text end
  end
  eq(used, "sleep-powder", "auto-pick prefers sleep over neutral damage")
end

do
  local battle = battleOf({
    choiceTimeout = 10,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 10,
        moves = {
          move({ id = "thump", power = 40 }),
          move({ id = "swords", power = 0, effect = 50 }),
        },
      }),
    },
    bMons = {
      mon({ species = "Beta", maxHp = 200, spd = 90, status = "PSN" }),
    },
  })
  drain(battle)
  battle:submitChoice("p2", { action = "fight", move = 0 })
  ok(battle:tick(11) == true, "timeout setup-picks when foe already statused")
  local events = drain(battle)
  local used = nil
  for _, event in ipairs(events) do
    if event.t == "anim" and event.slot == 0 then used = event.text end
  end
  eq(used, "swords", "auto-pick prefers setup over neutral damage")
end

do
  -- chart: type 0 vs type 1 = 0% (immune); type 1 vs type 1 = 200%.
  local chart = { { 100, 0 }, { 100, 200 } }
  local battle = battleOf({
    chart = chart,
    choiceTimeout = 10,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 10,
        moves = { move({ id = "immune-hit", type = 0, power = 80 }) },
      }),
      mon({
        species = "Gamma", maxHp = 200, spd = 10,
        moves = { move({ id = "se-hit", type = 1, power = 40 }) },
      }),
    },
    bMons = {
      mon({ species = "Beta", maxHp = 200, spd = 90, types = { 1 } }),
    },
  })
  drain(battle)
  battle:submitChoice("p2", { action = "fight", move = 0 })
  ok(battle:tick(11) == true, "timeout switches when active is immuned")
  local snap = battle:snapshot()
  local a = fighterIn(snap, "p1")
  eq(a and a.species, "Gamma", "auto-pick switched to the SE bench mon")
  -- Party HP array: index 1 still full (was switched out before damage),
  -- index 2 is the new active that may have taken a hit from p2.
  ok(a and a.party and a.party[1] == 200, "the immuned lead kept its HP")
end

-- ------------------------------------------------------------------
-- 17. Wave C phase 1: primary stat stages and status inflict
-- ------------------------------------------------------------------

local function fighterById(battle, playerId)
  for _, fighter in ipairs(battle.fighters) do
    if fighter.playerId == playerId then return fighter end
  end
  return nil
end

local function activeMonOf(battle, playerId)
  local fighter = fighterById(battle, playerId)
  if not fighter or not fighter.active then return nil end
  return fighter.mons[fighter.active]
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "swords", power = 0, effect = 50 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1 }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local statEvent = nil
  for _, event in ipairs(events) do
    if event.t == "stat" and event.slot == 0 then statEvent = event end
  end
  ok(statEvent ~= nil, "ATTACK_UP2 emits a stat event on the user")
  if statEvent then
    eq(statEvent.amount, 2, "ATTACK_UP2 raises attack two stages")
    ok(statEvent.text:find("rose", 1, true) ~= nil, "stat text says rose")
  end
  local alpha = activeMonOf(battle, "p1")
  ok(alpha and alpha.stages.atk == 2, "ATTACK_UP2 leaves atk stage at +2")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "sleep-powder", power = 0, effect = 32, accuracy = 255 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1 }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local slept = nil
  for _, event in ipairs(events) do
    if event.t == "status" and event.status == "SLP" then slept = event end
  end
  ok(slept ~= nil, "sleep powder emits SLP status")
  eq(fighterIn(battle:snapshot(), "p2").status, "SLP", "sleep powder sets sleep on foe")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        stages = { atk = 4, def = -2 },
        moves = { move({ id = "haze", power = 0, effect = 25 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        stages = { spd = 3, acc = -1 },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)

  local alpha = activeMonOf(battle, "p1")
  local beta = activeMonOf(battle, "p2")
  ok(alpha and alpha.stages.atk == 0 and alpha.stages.def == 0,
     "haze clears the user's stages")
  ok(beta and beta.stages.spd == 0 and beta.stages.acc == 0,
     "haze clears the foe's stages")
end

-- ------------------------------------------------------------------
-- 18. Wave C phase 2: side-chance effects + flinch
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "bite", power = 40, effect = 31, chance = 100 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1 }) },
  })
  drain(battle)
  local p1hpBefore = fighterIn(battle:snapshot(), "p1").hp
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local flinched = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text:find("flinched!", 1, true) then
      flinched = true
    end
  end
  ok(flinched, "flinch side effect causes the slower foe to flinch")
  eq(fighterIn(battle:snapshot(), "p1").hp, p1hpBefore,
     "the flinched foe never lands its attack")
end

-- Beta is type 1: FreezeBurnParalyzeEffect returns before its draw on a
-- target that shares the move's type (section 28), and the move is type 0.
do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "ember", power = 40, effect = 4, chance = 100 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1, types = { 1 } }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local burned = nil
  for _, event in ipairs(events) do
    if event.t == "status" and event.status == "BRN" then burned = event end
  end
  ok(burned ~= nil, "burn side effect with chance 100 emits BRN")
  eq(fighterIn(battle:snapshot(), "p2").status, "BRN",
     "burn side effect with chance 100 sets burn on foe")
end

-- Chance 0 is what every Red move sends (its records carry no chance), and
-- it reads the routine's own odds: BURN_SIDE_EFFECT1 is `10 percent + 1`,
-- 26.  The side byte is this turn's fourth draw (accuracy, crit, damage
-- roll, side): 25 on seed 18957 burns, 26 on seed 14106 does not.  Section 28
-- forces every family's bytes with a scripted generator.
for _, case in ipairs({ { seed = 18957, status = "BRN" }, { seed = 14106, status = nil } }) do
  local battle = battleOf({
    seed = case.seed,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "ember", power = 40, effect = 4, chance = 0 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1, types = { 1 } }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)

  eq(fighterIn(battle:snapshot(), "p2").status, case.status,
     "burn side effect with chance 0 reads the cart's 26 (seed " .. case.seed .. ")")
end

-- ------------------------------------------------------------------
-- 19. Wave C phase 3: multi-hit, fixed damage, drain, recoil
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120, atk = 80, level = 40,
        moves = { move({ id = "double-slap", power = 10, effect = 44 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1, def = 40 }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local foeDamage = 0
  for _, event in ipairs(events) do
    if event.t == "damage" and event.slot == 3 then
      foeDamage = foeDamage + 1
    end
  end
  eq(foeDamage, 2, "ATTACK_TWICE lands two separate damage events")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "horn-drill", power = 1, effect = 38, accuracy = 255 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1 }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  eq(fighterIn(battle:snapshot(), "p2").hp, 0,
     "OHKO from the faster mon removes all foe HP")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 1,
        moves = { move({ id = "horn-drill", power = 1, effect = 38, accuracy = 255 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 120 }) },
  })
  drain(battle)
  local foeHpBefore = fighterIn(battle:snapshot(), "p2").hp
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  -- OneHitKOEffect_ sets wCriticalHitOrOHKO to $ff before it finds the user
  -- slower, so PrintMoveFailureText says UnaffectedText (R1c).
  local failed = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "Beta's unaffected!" then failed = true end
  end
  ok(failed, "OHKO fails when the user is not faster")
  eq(fighterIn(battle:snapshot(), "p2").hp, foeHpBefore,
     "a failed OHKO leaves the foe untouched")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", hp = 150, maxHp = 200, spd = 120, atk = 80, level = 40,
        moves = { move({ id = "mega-drain", power = 40, effect = 3 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, def = 40,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  local userHpBefore = fighterIn(battle:snapshot(), "p1").hp
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local drained = false
  for _, event in ipairs(events) do
    if event.t == "drain" and event.slot == 0 then drained = true end
  end
  ok(drained, "DRAIN_HP emits a drain heal on the user")
  ok(fighterIn(battle:snapshot(), "p1").hp > userHpBefore,
     "DRAIN_HP restores HP after damage")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120, atk = 80, level = 40,
        moves = { move({ id = "take-down", power = 40, effect = 48 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, def = 40,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  local userHpBefore = fighterIn(battle:snapshot(), "p1").hp
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local recoil = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text:find("recoil", 1, true) then recoil = true end
  end
  ok(recoil, "RECOIL_EFFECT announces recoil")
  ok(fighterIn(battle:snapshot(), "p1").hp < userHpBefore,
     "RECOIL_EFFECT damages the user after a hit")
end

-- ------------------------------------------------------------------
-- 20. Wave C phase 4: multi-turn charge, recharge, trap
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    seed = 7777,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120, atk = 80, level = 40,
        moves = { move({ id = "solar-beam", power = 60, effect = 39 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, def = 40,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)

  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn1 = drain(battle)

  local glowing = false
  local foeDamaged = false
  for _, event in ipairs(turn1) do
    if event.t == "msg" and event.text:find("glowing", 1, true) then
      glowing = true
    end
    if event.t == "damage" and event.slot == 3 then foeDamaged = true end
  end
  ok(glowing, "CHARGE_EFFECT turn one announces glowing")
  ok(not foeDamaged, "CHARGE_EFFECT turn one deals no damage")

  local alpha = activeMonOf(battle, "p1")
  ok(alpha and alpha.charging ~= nil, "CHARGE_EFFECT sets charging state")

  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn2 = drain(battle)

  local released = false
  foeDamaged = false
  for _, event in ipairs(turn2) do
    if event.t == "anim" and event.text == "solar-beam" and event.slot == 0 then
      released = true
    end
    if event.t == "damage" and event.slot == 3 then foeDamaged = true end
  end
  ok(released, "CHARGE_EFFECT turn two auto-releases the charged move")
  ok(foeDamaged, "CHARGE_EFFECT turn two deals damage")
  alpha = activeMonOf(battle, "p1")
  ok(alpha and alpha.charging == nil, "CHARGE_EFFECT clears charging after release")
end

-- Dig (CHARGE + move.id) vanishes, talks like Dig, and Earthquake misses.
do
  local battle = battleOf({
    seed = 4242,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120, atk = 80, level = 40,
        moves = { move({ id = "DIG", power = 60, effect = 39, pp = 10 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, def = 40, atk = 80,
        moves = { move({ id = "EARTHQUAKE", power = 80, effect = 0, accuracy = 255 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn1 = drain(battle)
  local dug, failed, damaged, chargeAnim = false, false, false, false
  for _, event in ipairs(turn1) do
    if event.t == "msg" and event.text:find("dug a hole!", 1, true) then dug = true end
    -- MoveHitTest's INVULNERABLE miss is PrintMoveFailureText's "<USER>'s
    -- attack missed!" (R1c), not "But, it failed!".
    if event.t == "msg" and event.text == "Beta's attack missed!" then failed = true end
    if event.t == "damage" then damaged = true end
    if event.t == "anim" and event.text == "DIG" and event.amount == 1 then
      chargeAnim = true
    end
  end
  ok(dug, "DIG turn one announces dug a hole!")
  ok(chargeAnim, "DIG charge anim carries amount=1")
  ok(failed, "Gen1 Earthquake misses a digging target")
  ok(not damaged, "DIG charge turn deals no damage")
  local alpha = activeMonOf(battle, "p1")
  ok(alpha and alpha.invulnerable == true, "DIG sets invulnerable")
  -- ChargeEffect is reached ahead of PlayerCanExecuteMove: no used line and
  -- no DecrementPP on the charge turn (R1d); the release pays.
  eq(alpha and alpha.moves[1].pp, 10, "DIG spends no PP on the charge turn")
  local usedLine = false
  for _, event in ipairs(turn1) do
    if event.t == "msg" and event.text == "Alpha used DIG!" then usedLine = true end
  end
  ok(not usedLine, "DIG's charge turn prints no used line")

  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn2 = drain(battle)
  local released, foeDamaged = false, false
  for _, event in ipairs(turn2) do
    if event.t == "anim" and event.text == "DIG" and event.amount == nil then
      released = true
    end
    if event.t == "damage" and event.slot == 3 then foeDamaged = true end
  end
  ok(released, "DIG turn two auto-releases without amount=1")
  ok(foeDamaged, "DIG turn two deals damage")
  local releaseLine = false
  for _, event in ipairs(turn2) do
    if event.t == "msg" and event.text == "Alpha used DIG!" then releaseLine = true end
  end
  ok(releaseLine, "DIG's release prints the used line")
  alpha = activeMonOf(battle, "p1")
  eq(alpha and alpha.moves[1].pp, 9, "DIG spends its PP on the release")
  ok(alpha and alpha.invulnerable ~= true, "DIG release clears invulnerable")
  ok(alpha and alpha.charging == nil, "DIG release clears charging")
end

-- Charge-family setup lines key off move.id (hyphenated ids still glow).
do
  local Effects = need("BattleSim/Effects")
  local mon = { species = "Alpha" }
  eq(Effects.chargeMessage(mon, 39, "SOLARBEAM"), "Alpha took in sunlight!")
  eq(Effects.chargeMessage(mon, 39, "SKULL_BASH"), "Alpha lowered its head!")
  eq(Effects.chargeMessage(mon, 39, "RAZOR_WIND"), "Alpha made a whirlwind!")
  eq(Effects.chargeMessage(mon, 39, "SKY_ATTACK"), "Alpha is glowing!")
  eq(Effects.chargeMessage(mon, 39, "solar-beam"), "Alpha is glowing!")
end

-- Fly: nothing but SWIFT reaches it on Red -- MoveHitTest's INVULNERABLE
-- test has no THUNDER exception (that is Gold's), so THUNDER misses (R1c).
do
  local battle = battleOf({
    seed = 4343,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120, atk = 80, level = 40,
        moves = { move({ id = "FLY", power = 70, effect = 43, pp = 10 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, def = 40, atk = 80,
        moves = { move({ id = "THUNDER", power = 80, effect = 0, accuracy = 255 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn1 = drain(battle)
  local flew, failed, damaged = false, false, false
  for _, event in ipairs(turn1) do
    if event.t == "msg" and event.text:find("flew up high!", 1, true) then flew = true end
    if event.t == "msg" and event.text == "Beta's attack missed!" then failed = true end
    if event.t == "damage" and event.slot == 0 then damaged = true end
  end
  ok(flew, "FLY turn one announces flew up high!")
  ok(failed, "Gen1 Thunder misses a flying target")
  ok(not damaged, "Gen1 Thunder leaves the flying user untouched")
end

-- Swift hits Fly/Dig in Gen 1 (accuracy skip also skips invuln).
do
  local battle = battleOf({
    seed = 4444,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "FLY", power = 70, effect = 43 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, atk = 80,
        moves = { move({ id = "SWIFT", power = 60, effect = 17, accuracy = 255 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn1 = drain(battle)
  local damaged = false
  for _, event in ipairs(turn1) do
    if event.t == "damage" and event.slot == 0 then damaged = true end
  end
  ok(damaged, "Gen1 Swift hits a flying target")
end

do
  local battle = battleOf({
    seed = 8888,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120, atk = 40, level = 20,
        moves = { move({ id = "hyper-beam", power = 40, effect = 80 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 400, spd = 1, def = 80, atk = 80, level = 40,
        moves = { move({ id = "tackle", power = 40 }) },
      }),
    },
  })
  drain(battle)

  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn1 = drain(battle)

  ok(fighterIn(battle:snapshot(), "p2").hp < 400,
     "HYPER_BEAM damages the foe on the attack turn")
  listEq(battle:snapshot().waiting, { "p2" },
         "recharge auto-fills p1 so only the foe is owed")

  -- "must recharge!" is the recharger's own slot (`.HyperBeamCheck`), not the
  -- turn's opening (R1c): nothing says it until the turn resolves.
  local early = false
  for _, event in ipairs(turn1) do
    if event.t == "msg" and event.text:find("must recharge!", 1, true) then early = true end
  end
  ok(not early, "opening the recharge turn says nothing yet")

  local p1hp = fighterIn(battle:snapshot(), "p1").hp
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn2 = drain(battle)
  local recharged = false
  for _, event in ipairs(turn2) do
    if event.t == "msg" and event.text:find("must recharge!", 1, true) then
      recharged = true
    end
  end
  ok(recharged, "the recharge turn's slot announces must recharge!")
  ok(fighterIn(battle:snapshot(), "p1").hp < p1hp,
     "foe still attacks during recharge skip")
end

do
  local battle = battleOf({
    seed = 9999,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120, atk = 80, level = 40,
        moves = { move({ id = "wrap", power = 20, effect = 42 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, def = 40,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)

  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local landing = drain(battle)

  -- Gen1's 2..5 is the *total* attack count, and the hit that applied the trap
  -- was the first of them -- so the turn it lands on deals the move's damage
  -- and nothing else.  A residual here would be that hit counted twice.
  local landingTrapMsg = false
  for _, event in ipairs(landing) do
    if event.t == "msg" and event.text:find("trap", 1, true) then landingTrapMsg = true end
  end
  ok(not landingTrapMsg, "the turn the trap lands on deals no residual on top of the hit")
  local afterHit = fighterIn(battle:snapshot(), "p2").hp
  ok(afterHit < 200, "the trapping move itself damages the victim")

  -- The turn after: both are players, and each gets the battle menu (R1d),
  -- so each answers FIGHT -- the trapper's continuation, the held monster's
  -- CANNOT_MOVE.  The later hits are the trapper's own slot
  -- (`.MultiturnMoveCheck`): "<MON>'s attack continues!" and the stored hit,
  -- not a residual (R1c).
  ok(battle.byId.p1.choice == nil and battle.byId.p2.choice == nil,
     "a link fight's trapper and held monster are both asked")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "the trapper's FIGHT files")
  ok(battle:submitChoice("p2", { action = "fight", move = 0 }), "the held monster's FIGHT files")
  local residual = drain(battle)
  local residualMsg = false
  for _, event in ipairs(residual) do
    if event.t == "msg" and event.text == "Alpha's attack continues!" then residualMsg = true end
  end
  ok(residualMsg, "the trapper's attack continues on the turns that follow")
  ok(fighterIn(battle:snapshot(), "p2").hp < afterHit,
     "the continuation reduces the trapped mon's HP")
end

do
  local battle = battleOf({
    aMons = { mon({ species = "Alpha", maxHp = 200 }) },
    bMons = { mon({ species = "Beta", maxHp = 200 }) },
  })
  drain(battle)
  local alpha = activeMonOf(battle, "p1")
  local beta = activeMonOf(battle, "p2")
  -- The trap is the trapper's: it holds the seat its record names (Beta's
  -- slot, 3), and a forced trapper re-runs its move as `.MultiturnMoveCheck`
  -- in its own slot -- a forced fight, not a skip (R1c).
  alpha.trapping = { turns = 2, moveIndex = 1, targetSlot = 3 }
  beta.trapped = { turns = 2, damage = 10, fromSlot = 0 }
  battle:_fillForcedChoices()
  -- Both are players (1v1): the cart's battle menu is open to both (R1d),
  -- and FIGHT -- whatever slot comes with it -- is the lock-in.
  eq(battle.byId.p1.choice, nil, "a player's trapper is not filled")
  eq(battle.byId.p2.choice, nil, "a player's held monster is not filled")
  local lock = battle:_normaliseChoice(battle.byId.p1, { action = "fight", move = 3 })
  eq(lock and lock.action, "fight", "the trapper's FIGHT locks it into its move")
  ok(lock and lock.trapContinue, "...as the trap's continuation")
  local held = battle:_normaliseChoice(battle.byId.p2, { action = "fight" })
  eq(held and held.action, "skip", "the held monster's FIGHT is CANNOT_MOVE")
  eq(held and held.skip, "trapped", "...the trapped skip")
  local out = battle:_normaliseChoice(battle.byId.p2, { action = "item", item = "X_ATTACK" })
  eq(out and out.action, "item", "the held monster may use an item instead")
end

-- The computer's seats are filled, as SelectEnemyMove fills them.
do
  local battle = battleOf({
    mode = "wild",
    aMons = { mon({ species = "Alpha", maxHp = 200 }) },
    bMons = { mon({ species = "Beta", maxHp = 200 }) },
  })
  drain(battle)
  local alpha = activeMonOf(battle, "p1")
  local beta = activeMonOf(battle, "p2")
  beta.trapping = { turns = 2, moveIndex = 1, targetSlot = 0 }
  alpha.trapped = { turns = 2, damage = 10, fromSlot = 3 }
  battle.byId.p1.choice, battle.byId.p2.choice = nil, nil
  battle:_fillForcedChoices()
  ok(battle.byId.p2.choice and battle.byId.p2.choice.trapContinue,
     "the computer's trapper is filled with its continuation")
  ok(battle.byId.p2.forced, "...a referee-filled answer")
  eq(battle.byId.p1.choice, nil, "the player it holds is asked")
end

-- A trapping move is worth `trapTurns` attacks in total, not one more than
-- that: the counter covers the hit that applied it plus the residuals.  Both
-- ends of the 2..5 roll are checked by playing many seeds rather than by
-- reaching into the RNG, and the victim loses one turn per attack after the
-- first.
do
  local attacks, lost = {}, {}
  for seed = 1, 120 do
    local battle = battleOf({
      seed = seed,
      aMons = { mon({ species = "Alpha", maxHp = 999, spd = 120,
                      moves = { move({ id = "wrap", power = 5, effect = 42 }) } }) },
      bMons = { mon({ species = "Beta", maxHp = 999, def = 200, spd = 1,
                      moves = { move({ id = "splash", power = 0, effect = 85 }) } }) },
    })
    drain(battle)

    -- Every attack after the first is "attack continues!" in Alpha's slot,
    -- and the slower Beta loses the trap's first turn too (`.HeldInPlaceCheck`:
    -- "can't move!") and every continuation turn, silently (CANNOT_MOVE) --
    -- so it loses one turn per attack (R1c; it used to move on the first).
    -- Both answer FIGHT every turn (R1d: the battle menu, then the lock-in),
    -- and the chain is over once neither holds the trap at a turn's end.
    local hits, skipped = 0, 0
    for _ = 1, 30 do
      if battle:outcome() then break end
      battle:submitChoice("p1", { action = "fight", move = 0 })
      battle:submitChoice("p2", { action = "fight", move = 0 })
      for _, event in ipairs(drain(battle)) do
        if event.t == "msg" then
          if event.text == "Alpha used wrap!" then hits = hits + 1 end
          if event.text == "Alpha's attack continues!" then
            hits = hits + 1
            skipped = skipped + 1
          end
          if event.text:find("can't move!", 1, true) then skipped = skipped + 1 end
        end
      end
      local a, b = activeMonOf(battle, "p1"), activeMonOf(battle, "p2")
      if not (a and a.trapping) and not (b and b.trapped) then break end
    end
    attacks[hits] = (attacks[hits] or 0) + 1
    lost[skipped] = (lost[skipped] or 0) + 1
  end

  -- 1 attack / 0 lost turns is the run where the move simply missed and no
  -- trap was ever applied; everything else has to sit inside Gen1's range.
  local strayAttacks, strayLost = nil, nil
  for count in pairs(attacks) do
    if count ~= 1 and (count < 2 or count > 5) then strayAttacks = count end
  end
  for count in pairs(lost) do
    if count ~= 0 and (count < 2 or count > 5) then strayLost = count end
  end
  eq(strayAttacks, nil, "a trap is worth 2..5 attacks, never 6")
  eq(strayLost, nil, "a trap costs the slower victim 2..5 turns")
  ok(attacks[2] and attacks[5], "both ends of the 2..5 roll are reached")
end

-- A referee-filled answer is not the player's to take back: the computer's
-- trap continuation (wild Beta's) is filed at the turn's open and a cancel
-- from its seat is refused.  The player it holds is asked (R1d: the battle
-- menu), so the turn keeps its deadline, and the player's own lock-in -- its
-- FIGHT, CANNOT_MOVE -- can be taken back like any answer.
do
  local battle = battleOf({
    mode = "wild", seed = 9999,
    aMons = { mon({ species = "Alpha", maxHp = 999, def = 200, spd = 1,
                    moves = { move({ id = "splash", power = 0, effect = 85 }) } }) },
    bMons = { mon({ species = "Beta", maxHp = 999, spd = 120,
                    moves = { move({ id = "wrap", power = 5, effect = 42 }) } }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)

  ok(battle.deadline ~= nil, "a turn the held player answers keeps its deadline")
  ok(battle.byId.p2.forced, "the computer's trap continuation is the referee's answer")
  ok(battle:submitChoice("p2", { action = "cancel" }) == false,
     "cancel cannot clear a forced trap answer")
  ok(battle.byId.p2.choice ~= nil, "the forced answer survived the cancel")
  local lock = battle:_normaliseChoice(battle.byId.p1, { action = "fight", move = 0 })
  eq(lock and lock.skip, "trapped", "the held player's FIGHT is CANNOT_MOVE")

  -- The chain still runs to its end on the player's answers.
  local free = false
  for _ = 1, 40 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    drain(battle)
    local a = activeMonOf(battle, "p1")
    if a and not a.trapped and not battle.byId.p2.forced then free = true; break end
  end
  ok(free, "the trap chain still ends after a refused cancel")
end

-- An ordinary answer stays cancellable -- the guard is about forced fills only.
do
  local battle = battleOf({})
  drain(battle)
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "an ordinary answer files")
  ok(battle:submitChoice("p1", { action = "cancel" }), "and can still be taken back")
  ok(battle.byId.p1.choice == nil, "cancel cleared it")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "and the seat can answer again")
end

-- ------------------------------------------------------------------
-- 21. Wave C phase 5: substitute, screens, mist, focus, meta
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 1, atk = 120, level = 50,
        moves = {
          move({ id = "splash", power = 0, effect = 85 }),
          move({ id = "tackle", power = 60 }),
        },
      }),
    },
    bMons = {
      mon({
        species = "Beta", hp = 200, maxHp = 200, spd = 120,
        moves = {
          move({ id = "substitute", power = 0, effect = 79 }),
          move({ id = "splash", power = 0, effect = 85 }),
        },
      }),
    },
  })
  drain(battle)

  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn1 = drain(battle)

  local subCreated = false
  for _, event in ipairs(turn1) do
    if event.t == "msg" and event.text:find("substitute", 1, true) then
      subCreated = true
    end
  end
  ok(subCreated, "SUBSTITUTE_EFFECT announces substitute creation")

  local beta = activeMonOf(battle, "p2")
  ok(beta and beta.substitute and beta.substitute > 0,
     "SUBSTITUTE_EFFECT sets substitute HP pool on user")

  local betaHpBefore = fighterIn(battle:snapshot(), "p2").hp
  battle:submitChoice("p1", { action = "fight", move = 1 })
  battle:submitChoice("p2", { action = "fight", move = 1 })
  drain(battle)

  eq(fighterIn(battle:snapshot(), "p2").hp, betaHpBefore,
     "substitute absorbs damage so the mon's HP is unchanged")
  beta = activeMonOf(battle, "p2")
  ok(beta and (not beta.substitute or beta.substitute == 0),
     "enough damage breaks the substitute without hitting the mon")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = {
          move({ id = "sleep", power = 0, effect = 32, accuracy = 255 }),
          move({ id = "growl", power = 0, effect = 18, accuracy = 255 }),
          move({ id = "swords", power = 0, effect = 50, accuracy = 255 }),
        },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, substitute = 50,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)

  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn1 = drain(battle)
  -- SleepEffect never asks CheckTargetSubstitute (effects.asm :26-68): the
  -- doll stands and the monster behind it falls asleep (R1c; it used to be
  -- "But nothing happened").
  local beta = activeMonOf(battle, "p2")
  eq(beta and beta.status, "sleep", "SLEEP_EFFECT reaches the monster behind a substitute")
  eq(beta and beta.substitute, 50, "SLEEP_EFFECT leaves the substitute standing")
  local slept = false
  for _, event in ipairs(turn1) do
    if event.t == "msg" and event.text == "Beta fell asleep!" then
      slept = true
    end
  end
  ok(slept, "SLEEP_EFFECT vs substitute says Beta fell asleep!")

  battle:submitChoice("p1", { action = "fight", move = 1 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  beta = activeMonOf(battle, "p2")
  eq(beta and beta.stages.atk, 0, "Growl fails through a substitute")

  battle:submitChoice("p1", { action = "fight", move = 2 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local alpha = activeMonOf(battle, "p1")
  eq(alpha and alpha.stages.atk, 2,
     "Swords Dance still works while the foe has a substitute")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "transform", power = 0, effect = 57, accuracy = 255 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, substitute = 40,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  -- TransformEffect_'s only HAS_SUBSTITUTE_UP test is the user's own, for its
  -- animation: a doll in front of the target stops nothing (R1c).
  local alpha = activeMonOf(battle, "p1")
  ok(alpha and alpha.transformed, "TRANSFORM_EFFECT goes through a substitute")
end

do
  -- Damaging hit with a foe primary: breaking the sub must not then Growl.
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120, atk = 120, level = 50,
        moves = {
          move({ id = "thump", power = 60, effect = 18, accuracy = 255 }),
        },
      }),
    },
    bMons = {
      mon({
        species = "Beta", hp = 200, maxHp = 200, spd = 1, substitute = 5,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local beta = activeMonOf(battle, "p2")
  eq(beta and (beta.substitute or 0), 0, "damaging hit broke the substitute")
  eq(beta and beta.stages.atk, 0,
     "Growl primary does not land on the hit that broke the sub")
  eq(fighterIn(battle:snapshot(), "p2").hp, 200,
     "breaking the sub still does not cut HP")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "transform", power = 0, effect = 57 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = {
          move({ id = "copied-move", power = 55, pp = 8 }),
          move({ id = "other", power = 0, effect = 85 }),
        },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)

  local alpha = activeMonOf(battle, "p1")
  ok(alpha and alpha.transformed, "TRANSFORM_EFFECT sets transformed flag")
  ok(alpha and alpha.moves[1] and alpha.moves[1].id == "copied-move",
     "TRANSFORM_EFFECT copies the foe's first move")
  -- TransformEffect_'s `.copyPPLoop` (R1b): 5 PP on every copied move,
  -- whatever the target had left (its 8 here).
  eq(alpha and alpha.moves[1] and alpha.moves[1].pp, 5,
     "TRANSFORM_EFFECT gives every copied move 5 PP")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "growl", power = 0, effect = 18, accuracy = 255 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, mist = true,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local blocked = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "But, it failed!" then blocked = true end
  end
  ok(blocked, "MIST blocks foe Attack Down with But it failed")
  local beta = activeMonOf(battle, "p2")
  ok(beta and beta.stages.atk == 0, "MIST leaves foe attack stage unchanged")
end

-- ------------------------------------------------------------------
-- 22. Wave C phase 6: meta / flow (bide, explode, jump kick, metronome)
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    seed = 4242,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, hp = 200, spd = 120, atk = 80, level = 40,
        moves = { move({ id = "bide", power = 0, effect = 26 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, atk = 60, level = 40,
        moves = { move({ id = "tackle", power = 40 }) },
      }),
    },
  })
  drain(battle)

  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn1 = drain(battle)

  -- BideEffect prints nothing past "used BIDE" (R1d): no "storing energy".
  local storing = false
  for _, event in ipairs(turn1) do
    if event.t == "msg" and event.text:find("energy", 1, true) then
      storing = true
    end
  end
  ok(not storing, "BIDE_EFFECT says nothing on turn one past its used line")

  local alpha = activeMonOf(battle, "p1")
  ok(alpha and alpha.bide ~= nil, "BIDE_EFFECT sets bide state")

  -- Every turn after this one is a Bide turn (the store, then the unleash on
  -- the turn its counter reaches 0).  Ann is a player: the cart gives her the
  -- battle menu, and her FIGHT -- no move menu -- is the Bide (`_menuFight`).
  local foeHpBefore = fighterIn(battle:snapshot(), "p2").hp
  local released = false
  local silent = true
  for _ = 1, 6 do
    if not alpha or not alpha.bide then break end
    ok(battle.byId.p1.choice == nil, "the Bide user is asked, not filled")
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    for _, event in ipairs(drain(battle)) do
      if event.t == "damage" and event.slot == 3 and event.amount > 0 then
        released = true
      end
      if event.t == "msg" and event.text:find("storing energy", 1, true) then silent = false end
    end
    alpha = activeMonOf(battle, "p1")
  end

  ok(silent, "a store turn says nothing (SavingEnergyText is unreferenced)")
  ok(released, "BIDE_EFFECT release deals damage to the foe")
  ok(alpha and alpha.bide == nil, "BIDE_EFFECT clears bide after release")
  ok(fighterIn(battle:snapshot(), "p2").hp < foeHpBefore,
     "BIDE release reduced foe HP")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120, atk = 120, level = 50,
        moves = { move({ id = "explosion", power = 100, effect = 7, accuracy = 255 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, def = 40,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local fainted = false
  for _, event in ipairs(events) do
    if event.t == "faint" and event.slot == 0 then fainted = true end
  end
  ok(fainted, "EXPLODE_EFFECT faints the user after attacking")
  ok(fighterIn(battle:snapshot(), "p2").hp < 200,
     "EXPLODE_EFFECT still damages the foe")
end

do
  local battle = battleOf({
    seed = 999,
    aMons = {
      mon({
        species = "Alpha", maxHp = 160, spd = 120,
        moves = { move({ id = "jump-kick", power = 70, effect = 45, accuracy = 0 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, def = 40,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  local hpBefore = fighterIn(battle:snapshot(), "p1").hp
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)

  local snap = battle:snapshot()
  ok(fighterIn(snap, "p1").hp < hpBefore,
     "JUMP_KICK_EFFECT crash damages the user on miss")
  -- PrintMoveFailureText (R1b): the crash is wDamage / 8 bumped to 1, and
  -- wDamage is always 0 after a miss -- 1 HP, not an eighth of the max.
  eq(fighterIn(snap, "p1").hp, hpBefore - 1,
     "JUMP_KICK crash is 1 HP")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "metronome", power = 0, effect = 83 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1 }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local nothing = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "But nothing happened" then
      nothing = true
    end
  end
  ok(nothing, "METRONOME_EFFECT does nothing without a move pool")
end

do
  local battle = battleOf({
    seed = 7,
    metronomePool = {
      move({ id = "pool-thump", power = 60, accuracy = 255, type = 0 }),
    },
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120, atk = 100, level = 50,
        moves = { move({ id = "metronome", power = 0, effect = 83 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, def = 40,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  local hpBefore = fighterIn(battle:snapshot(), "p2").hp
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  local called = false
  for _, event in ipairs(events) do
    if event.t == "anim" and event.text == "pool-thump" then called = true end
  end
  ok(called, "METRONOME_EFFECT calls a move from the uploaded pool")
  ok(fighterIn(battle:snapshot(), "p2").hp < hpBefore,
     "Metronome-called move deals damage")
end

do
  -- Type 1 is Special; high spc / low atk vs high def / low spc.
  local battle = battleOf({
    seed = 3,
    specialTypes = { 1 },
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120, atk = 1, spc = 200,
        level = 50,
        moves = { move({ id = "psy", power = 80, type = 1, accuracy = 255 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, def = 200, spc = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  ok(fighterIn(battle:snapshot(), "p2").hp < 200,
     "specialTypes uses spc/spc for Special-typed moves")
end

do
  local battle = battleOf({
    seed = 11,
    specialTypes = { 1 },
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 1, atk = 120, spc = 120,
        level = 50,
        moves = {
          move({ id = "splash", power = 0, effect = 85 }),
          move({ id = "phys", power = 80, type = 0, accuracy = 255 }),
          move({ id = "spec", power = 80, type = 1, accuracy = 255 }),
        },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 120, def = 40, spc = 40,
        moves = {
          move({ id = "reflect", power = 0, effect = 65 }),
          move({ id = "splash", power = 0, effect = 85 }),
        },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local beta = activeMonOf(battle, "p2")
  ok(beta and beta.reflect, "REFLECT_EFFECT sets reflect")

  local hpBefore = fighterIn(battle:snapshot(), "p2").hp
  battle:submitChoice("p1", { action = "fight", move = 1 }) -- physical
  battle:submitChoice("p2", { action = "fight", move = 1 })
  drain(battle)
  local afterPhys = fighterIn(battle:snapshot(), "p2").hp
  local physDealt = hpBefore - afterPhys

  battle:submitChoice("p1", { action = "fight", move = 2 }) -- special
  battle:submitChoice("p2", { action = "fight", move = 1 })
  drain(battle)
  local afterSpec = fighterIn(battle:snapshot(), "p2").hp
  local specDealt = afterPhys - afterSpec
  ok(physDealt > 0 and specDealt > 0, "both categories still deal damage under Reflect")
  -- Reflect doubles the physical defence before the damage formula (pokered
  -- GetDamageVarsForPlayerAttack's `sla c / rl b`), where it used to halve the
  -- finished damage; the comparison is the same either way.
  ok(physDealt < specDealt,
     "Reflect doubles the physical defence but not the Special one")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", hp = 50, maxHp = 200, spd = 120, status = "BRN",
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "FULL_RESTORE" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local alpha = activeMonOf(battle, "p1")
  eq(alpha and alpha.hp, 200, "FULL_RESTORE heals to max HP")
  eq(alpha and alpha.status, nil, "FULL_RESTORE clears status")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "X_ATTACK" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local alpha = activeMonOf(battle, "p1")
  eq(alpha and alpha.stages.atk, 1, "X_ATTACK raises the attack stage")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "X_ACCURACY" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local alpha = activeMonOf(battle, "p1")
  ok(alpha and alpha.xAccuracy, "X_ACCURACY sets the never-miss flag")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "DIRE_HIT" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local alpha = activeMonOf(battle, "p1")
  ok(alpha and alpha.focusEnergy, "DIRE_HIT sets focus energy")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "GUARD_SPEC" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local alpha = activeMonOf(battle, "p1")
  ok(alpha and alpha.mist, "GUARD_SPEC sets mist")
end

do
  -- Vitamins mutate fight-local Stat Exp on the sheet (client writebacks save).
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", level = 100, maxHp = 200, spd = 120, atk = 40,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  local alpha = activeMonOf(battle, "p1")
  local before = alpha.stats.atk
  battle:submitChoice("p1", { action = "item", item = "PROTEIN" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  local rose = false
  for _, event in ipairs(events) do
    -- VitaminStatRoseText's own stop (R1e): "<MON>'s <STAT> rose."
    if event.t == "msg" and event.text == "Alpha's ATTACK rose." then rose = true end
  end
  ok(rose, "PROTEIN raises Attack on the fight sheet")
  alpha = activeMonOf(battle, "p1")
  eq(alpha.stats.atk, before + 12,
     "level-100 PROTEIN adds Gen1 Stat Exp delta 12")
  eq(alpha.evs.atk, 2560, "sheet EV/Stat Exp gains 2560")
  local itemEv = nil
  for _, event in ipairs(events) do
    if event.t == "item" then itemEv = event end
  end
  eq(itemEv and itemEv.amount, 1, "successful vitamin sets amount=1 for save writeback")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", level = 100, maxHp = 200, spd = 120, atk = 40,
        evs = { atk = 25600 },
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "PROTEIN" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  local failed = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "But, it failed!" then failed = true end
  end
  ok(failed, "PROTEIN fails once Stat Exp is already ≥ 25600")
  local itemEv = nil
  for _, event in ipairs(events) do
    if event.t == "item" then itemEv = event end
  end
  ok(itemEv ~= nil, "failed vitamin still emits item (bag spend)")
  eq(itemEv.amount, nil, "failed vitamin does not set amount=1 writeback flag")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "POKE_BALL" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  -- ThrowBallAtTrainerMon (R1e): the trainer blocks it, no "used" line.
  local blocked, thief, used = false, false, false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "The trainer blocked the BALL!" then blocked = true end
    if event.t == "msg" and event.text == "Don't be a thief!" then thief = true end
    if event.t == "msg" and tostring(event.text):find("used POKé BALL", 1, true) then used = true end
  end
  ok(blocked and thief, "balls fail outside wild mediated mode")
  ok(not used, "...with no \"used\" line: the trainer blocks the ball before ItemUseText00")
end

do
  local battle = battleOf({
    mode = "wild",
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, catchRate = 255,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "MASTER_BALL" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  ok(battle.result ~= nil, "MASTER_BALL ends a wild fight")
  eq(battle.result and battle.result.reason, "catch",
     "catch success reasons the outcome as catch")
  ok(battle.result.caught ~= nil, "catch outcome carries a caught sheet")
  eq(battle.result.caught.species, "Beta", "caught sheet names the wild mon")
  eq(battle.result.catcher, "p1", "solo wild catch names the thrower as catcher")
end

-- ------------------------------------------------------------------
-- 12f2. wild / coop_wild: Gen1 ball toss/shake anim chain
-- ------------------------------------------------------------------

local function ballAnimTexts(events)
  local out = {}
  for _, event in ipairs(events) do
    if event.t == "anim" then
      out[#out + 1] = {
        text = event.text, amount = event.amount, slot = event.slot,
      }
    end
  end
  return out
end

local function hasAnim(anims, text)
  for _, a in ipairs(anims) do
    if a.text == text then return a end
  end
  return nil
end

do
  local battle = battleOf({
    mode = "wild",
    seed = 42,
    sides = {
      a = {
        { playerId = "p1", name = "Red", bag = { MASTER_BALL = 1 },
          mons = { mon({
            species = "Alpha", maxHp = 200, spd = 120,
            moves = { move({ id = "splash", power = 0, effect = 85 }) },
          }) } },
      },
      b = {
        { playerId = "p2", name = "Wild",
          mons = { mon({
            species = "Beta", maxHp = 200, spd = 1, catchRate = 255,
            moves = { move({ id = "splash", power = 0, effect = 85 }) },
          }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "MASTER_BALL" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  local anims = ballAnimTexts(events)
  eq(anims[1] and anims[1].text, "ULTRATOSS_ANIM",
     "MASTER_BALL catch opens with ULTRATOSS_ANIM")
  eq(anims[2] and anims[2].text, "POOF_ANIM", "catch chain poofs after toss")
  eq(anims[3] and anims[3].text, "HIDEPIC_ANIM", "catch chain hides the foe pic")
  eq(anims[4] and anims[4].text, "SHAKE_ANIM", "catch chain shakes")
  eq(anims[4] and anims[4].amount, 3, "MASTER_BALL shake amount is 3")
  eq(#anims, 4, "caught chain ends after SHAKE (no SHOWPIC)")
  ok(not hasAnim(anims, "SHOWPIC_ANIM"), "caught chain has no SHOWPIC")
end

do
  -- Sleep + mid catchRate: wobble math yields shakes>0; first roll often fails.
  local found, seedUsed = nil, nil
  for seed = 89000, 89200 do
    local battle = battleOf({
      mode = "wild",
      seed = seed,
      sides = {
        a = {
          { playerId = "p1", name = "Red", bag = { POKE_BALL = 1 },
            mons = { mon({
              species = "Alpha", maxHp = 200, spd = 120,
              moves = { move({ id = "splash", power = 0, effect = 85 }) },
            }) } },
        },
        b = {
          { playerId = "p2", name = "Wild",
            mons = { mon({
              species = "Beta", maxHp = 200, hp = 200, spd = 1,
              catchRate = 45, status = "sleep",
              moves = { move({ id = "splash", power = 0, effect = 85 }) },
            }) } },
        },
      },
    })
    drain(battle)
    battle:submitChoice("p1", { action = "item", item = "POKE_BALL" })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    local events = drain(battle)
    if not battle.result then
      local anims = ballAnimTexts(events)
      local shake = hasAnim(anims, "SHAKE_ANIM")
      if shake and (shake.amount or 0) > 0 and hasAnim(anims, "SHOWPIC_ANIM") then
        found, seedUsed = anims, seed
        break
      end
    end
  end
  ok(found ~= nil, "found a POKE_BALL break-free with shakes>0")
  if found then
    eq(found[1] and found[1].text, "TOSS_ANIM",
       "POKE_BALL fail opens with TOSS_ANIM (seed " .. tostring(seedUsed) .. ")")
    ok(hasAnim(found, "POOF_ANIM") ~= nil, "fail-with-shakes has POOF")
    ok(hasAnim(found, "HIDEPIC_ANIM") ~= nil, "fail-with-shakes has HIDEPIC")
    ok(hasAnim(found, "SHOWPIC_ANIM") ~= nil,
       "fail-with-shakes restores pic via SHOWPIC")
  end
end

-- ------------------------------------------------------------------
-- 12g. coop_wild: seating, ball order, catcher
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    mode = "coop_wild",
    seed = 88001,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, spd = 80 }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, spd = 70 }) } },
      },
      b = {
        { playerId = "wild", name = "Wild",
          mons = { mon({ species = "Beta", maxHp = 200, spd = 10, catchRate = 255 }) } },
      },
    },
  })
  drain(battle)
  eq(#battle:snapshot().field, 3, "coop_wild create accepts 2v1 seating")
end

do
  local battle, err = Turn.create({
    mode = "coop_wild",
    seed = 88002,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = { mon() } },
        { playerId = "a2", name = "Abe", mons = { mon({ species = "Gamma" }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = { mon({ species = "Beta" }) } },
        { playerId = "b2", name = "Bea", mons = { mon({ species = "Delta" }) } },
      },
    },
  })
  ok(battle == nil, "coop_wild refuses two fighters on side b")
  ok(type(err) == "string" and err:find("side b", 1, true) ~= nil,
     "refusal names side b: " .. tostring(err))
end

do
  eq(Events.fieldSlot("b", 1), 3, "1v1 foe field slot is 3 not 2")
  eq(Events.fieldSlot("a", 1), 0, "...side a index 1 is slot 0")
  eq(Events.fieldSlot("b", 2), 4, "...side b index 2 is slot 4")
end

do
  local battle = battleOf({
    mode = "coop_wild",
    seed = 88006,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, spd = 80 }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, spd = 70 }) } },
        { playerId = "a3", name = "Cal",
          mons = { mon({ species = "Epsilon", maxHp = 200, spd = 60 }) } },
      },
      b = {
        { playerId = "wild", name = "Wild",
          mons = { mon({ species = "Beta", maxHp = 200, spd = 10, catchRate = 255 }) } },
      },
    },
  })
  drain(battle)
  eq(#battle.bySide.a, 3, "coop_wild 3-human create: side a length 3")
  eq(#battle.bySide.b, 1, "coop_wild 3-human create: side b length 1")
  eq(#battle:snapshot().field, 4, "coop_wild create accepts 3v1 seating")
  local slots = {}
  for _, entry in ipairs(battle:snapshot().field) do slots[#slots + 1] = entry.slot end
  listEq(slots, { 0, 1, 2, 3 }, "3-human coop_wild uses slots 0, 1, 2, 3")
end

do
  local battle, err = Turn.create({
    mode = "coop_wild",
    seed = 88007,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mon() } } },
      b = { { playerId = "wild", name = "Wild", mons = { mon() } } },
    },
  })
  ok(battle == nil, "coop_wild refuses one human on side a")
  ok(type(err) == "string", "refusal names why: " .. tostring(err))
end

do
  local battle, err = Turn.create({
    mode = "coop_wild",
    seed = 88008,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = { mon() } },
        { playerId = "a2", name = "Abe", mons = { mon() } },
        { playerId = "a3", name = "Cal", mons = { mon() } },
        { playerId = "a4", name = "Dan", mons = { mon() } },
      },
      b = { { playerId = "wild", name = "Wild", mons = { mon() } } },
    },
  })
  ok(battle == nil, "coop_wild refuses four humans on side a")
  ok(type(err) == "string" and err:find("side a", 1, true) ~= nil,
     "refusal names side a: " .. tostring(err))
end

do
  local battle = battleOf({
    mode = "coop_pvp",
    seed = 88009,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = { mon({ species = "Alpha", maxHp = 200, spd = 80 }) } },
        { playerId = "a2", name = "Abe", mons = { mon({ species = "Gamma", maxHp = 200, spd = 70 }) } },
        { playerId = "a3", name = "Cal", mons = { mon({ species = "Epsilon", maxHp = 200, spd = 60 }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = { mon({ species = "Beta", maxHp = 200, spd = 55 }) } },
        { playerId = "b2", name = "Bea", mons = { mon({ species = "Delta", maxHp = 200, spd = 50 }) } },
        { playerId = "b3", name = "Ben", mons = { mon({ species = "Zeta", maxHp = 200, spd = 45 }) } },
      },
    },
  })
  drain(battle)
  eq(#battle:snapshot().field, 6, "3v3 coop_pvp create puts six fighters on the field")
  local slots = {}
  for _, entry in ipairs(battle:snapshot().field) do slots[#slots + 1] = entry.slot end
  listEq(slots, { 0, 1, 2, 3, 4, 5 }, "3v3 uses field slots 0 through 5")
end

do
  local battle = battleOf({
    mode = "coop_pvp",
    seed = 88010,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, spd = 80 }) } },
      },
      b = {
        { playerId = "b1", name = "Bob",
          mons = { mon({ species = "Beta", maxHp = 200, spd = 60 }) } },
        { playerId = "b2", name = "Bea",
          mons = { mon({ species = "Delta", maxHp = 200, spd = 50 }) } },
        { playerId = "b3", name = "Ben",
          mons = { mon({ species = "Zeta", maxHp = 200, spd = 40 }) } },
      },
    },
  })
  drain(battle)
  for _, slot in ipairs({ 3, 4, 5 }) do
    ok(battle:submitChoice("a1", { action = "fight", move = 0, target = slot }) == true,
       "coop_pvp: target " .. slot .. " is accepted while three foes live")
    ok(battle:submitChoice("a1", { action = "cancel" }) == true,
       "...and can be taken back before the turn closes")
  end
end

do
  local battle = battleOf({
    mode = "coop_npc",
    seed = 88011,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, spd = 80 }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, spd = 70 }) } },
      },
      b = {
        { playerId = "b1", name = "Bob",
          mons = { mon({ species = "Beta", maxHp = 200, spd = 60 }) } },
        { playerId = "b2", name = "Bea",
          mons = { mon({ species = "Delta", maxHp = 200, spd = 50 }) } },
        { playerId = "b3", name = "Ben",
          mons = { mon({ species = "Zeta", maxHp = 200, spd = 40 }) } },
      },
    },
  })
  drain(battle)
  for _, slot in ipairs({ 3, 4, 5 }) do
    ok(battle:submitChoice("a1", { action = "fight", move = 0, target = slot }) == true,
       "coop_npc: target " .. slot .. " is accepted while three foes live")
    ok(battle:submitChoice("a1", { action = "cancel" }) == true,
       "...and can be taken back before the turn closes")
  end
end

do
  local splash = move({ id = "splash", power = 0, effect = 85 })
  local battle = battleOf({
    mode = "coop_wild",
    seed = 88003,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, spd = 120, moves = { splash } }) },
          bag = { POKE_BALL = 1 } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, spd = 1, moves = { splash } }) },
          bag = { POKE_BALL = 1 } },
      },
      b = {
        { playerId = "wild", name = "Wild",
          mons = { mon({
            species = "Beta", maxHp = 200, hp = 200, spd = 1, catchRate = 3,
            moves = { splash },
          }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("a1", { action = "item", item = "POKE_BALL" })
  battle:submitChoice("a2", { action = "item", item = "POKE_BALL" })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  local events = drain(battle)
  local ballSlots = {}
  for _, event in ipairs(events) do
    if event.t == "item" and event.text == "POKE_BALL" then
      ballSlots[#ballSlots + 1] = event.slot
    end
  end
  eq(#ballSlots, 2, "both POKE_BALL throws resolve when neither catches")
  eq(ballSlots[1], 0, "faster human's ball resolves first")
  eq(ballSlots[2], 1, "slower human's ball resolves second")
end

do
  local splash = move({ id = "splash", power = 0, effect = 85 })
  local battle = battleOf({
    mode = "coop_wild",
    seed = 88004,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, spd = 120, moves = { splash } }) },
          bag = { MASTER_BALL = 1 } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, spd = 1, moves = { splash } }) },
          bag = { MASTER_BALL = 1 } },
      },
      b = {
        { playerId = "wild", name = "Wild",
          mons = { mon({
            species = "Beta", maxHp = 200, spd = 1, catchRate = 255,
            moves = { splash },
          }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("a1", { action = "item", item = "MASTER_BALL" })
  battle:submitChoice("a2", { action = "item", item = "MASTER_BALL" })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  local events = drain(battle)
  local ballSlots = {}
  for _, event in ipairs(events) do
    if event.t == "item" and event.text == "MASTER_BALL" then
      ballSlots[#ballSlots + 1] = event.slot
    end
  end
  eq(#ballSlots, 1, "first catch stops the slower ball from resolving")
  eq(ballSlots[1], 0, "only the faster thrower's ball is spent")
  eq(battle.result and battle.result.reason, "catch", "coop_wild catch ends the fight")
  eq(battle.result.catcher, "a1", "catcher is the faster thrower's playerId")
  eq(battle.byId.a1.bag.MASTER_BALL, nil, "faster fighter spent their ball")
  eq(battle.byId.a2.bag.MASTER_BALL, 1, "slower fighter never spent their ball")
  local anims = ballAnimTexts(events)
  eq(anims[1] and anims[1].text, "ULTRATOSS_ANIM",
     "coop_wild MASTER_BALL catch emits ULTRATOSS_ANIM")
  ok(hasAnim(anims, "HIDEPIC_ANIM") ~= nil, "coop_wild catch has HIDEPIC")
  ok(hasAnim(anims, "SHAKE_ANIM") ~= nil, "coop_wild catch has SHAKE")
  eq(#anims, 4, "coop_wild catch is one ball chain (slower throw never resolves)")
end

do
  local splash = move({ id = "splash", power = 0, effect = 85 })
  local battle = battleOf({
    mode = "coop_npc",
    seed = 88005,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, spd = 120, moves = { splash } }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, spd = 70, moves = { splash } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob",
          mons = { mon({ species = "Beta", maxHp = 200, spd = 60, moves = { splash } }) } },
        { playerId = "b2", name = "Bea",
          mons = { mon({ species = "Delta", maxHp = 200, spd = 50, moves = { splash } }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("a1", { action = "item", item = "POKE_BALL" })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
  battle:submitChoice("b1", { action = "fight", move = 0 })
  battle:submitChoice("b2", { action = "fight", move = 0, target = 1 })
  local events = drain(battle)
  local failed = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "The trainer blocked the BALL!" then failed = true end
  end
  ok(failed, "balls still fail in coop_npc")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 100, hp = 50, spd = 120,
        moves = { move({ id = "splash", power = 0, effect = 85, pp = 5, maxPp = 20 }) },
      }),
      mon({
        species = "Bench", maxHp = 100, hp = 0, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "REVIVE", slot = 1 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local bench = battle.fighters[1].mons[2]
  ok(bench.hp > 0, "REVIVE restores a fainted party slot")
  eq(bench.hp, 50, "REVIVE restores half max HP")
end

do
  local battle = battleOf({
    aBag = { POTION = 1 },
    aMons = {
      mon({
        species = "Alpha", maxHp = 100, hp = 50, spd = 120,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
      mon({
        species = "Bench", maxHp = 100, hp = 0, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  ok(battle:submitChoice("p1", { action = "item", item = "POTION", slot = 1 }) == false,
     "Potion on a fainted party slot does not file")
  eq(battle.byId.p1.bag.POTION, 1, "...and the bag is not spent")
  eq(battle.byId.p1.choice, nil, "...and the turn is still owed")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 100, spd = 120,
        moves = { move({ id = "tackle", power = 40, pp = 1, maxPp = 20 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "ETHER", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  eq(battle.fighters[1].mons[1].moves[1].pp, 11, "ETHER restores 10 PP")
  local restored, restoredMon = nil, nil
  for _, event in ipairs(events) do
    if event.t == "moves" and event.slot == 0 and event.moves and event.moves[1] then
      restored = event.moves[1]
      restoredMon = event.mon
    end
  end
  ok(restored ~= nil, "ETHER also publishes the list so FIGHT can redraw PP")
  eq(restored and restored.pp, 11, "...at the restored count")
  eq(restoredMon, 0, "...and names the fielded party index")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 100, spd = 120,
        moves = { move({ id = "thump", power = 40, pp = 10, maxPp = 20 }) },
      }),
      mon({
        species = "Bench", maxHp = 100, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85, pp = 1, maxPp = 20 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "ETHER", move = 0, slot = 1 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  eq(battle.fighters[1].mons[2].moves[1].pp, 11, "ETHER still restores a bench slot")
  eq(battle.fighters[1].mons[1].moves[1].pp, 10, "...and leaves the fielded mon's PP")
  local fieldMoves = false
  for _, event in ipairs(events) do
    if event.t == "moves" and event.slot == 0 then fieldMoves = true end
  end
  eq(fieldMoves, false,
     "a bench Ether does not publish a moves list on the field seat")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 100, spd = 120,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "NOT_A_REAL_ITEM" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  local failed = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "It won't have any effect." then failed = true end
  end
  ok(failed, "unknown item ids announce ItemUseNoEffect's line")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 100, spd = 120, status = "SLP", statusTurns = 3,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1, status = "SLP", statusTurns = 2,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "item", item = "POKE_FLUTE" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  eq(battle.fighters[1].mons[1].status, nil, "POKE_FLUTE wakes the user's party")
  eq(battle.fighters[2].mons[1].status, nil, "and the foe's party too")
end

do
  -- Both seats HYPER BEAM, so the next turn is a recharge on both -- no menu
  -- on either cart (MainInBattleLoop :293-295), every seat forced.  (A trap
  -- no longer forces a player's seat: the battle menu stays open, R1d.)
  local battle = battleOf({
    aMons = { mon({ species = "Alpha", maxHp = 200, spd = 50,
      moves = { move({ id = "beam", power = 10, effect = 80 }) } }) },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 50,
      moves = { move({ id = "beam", power = 10, effect = 80 }) } }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  ok(activeMonOf(battle, "p1").mustRecharge and activeMonOf(battle, "p2").mustRecharge,
     "both beams landed, both must recharge!")
  ok(battle.forcedPending == true, "both-sides forced defers resolve to tick")
  eq(battle.phase, "choice", "and leaves the paced turn open")
  local turn = battle.turn
  battle:tick(battle.now + 1)
  ok(battle.forcedPending ~= true or battle.turn > turn or battle.phase ~= "choice"
     or battle.result ~= nil,
     "tick advances the forced chain one step")
end

-- ------------------------------------------------------------------
-- 12b. Disable, Leech Seed, Transform/Mimic move sync
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 1,
        moves = { move({ id = "disable", power = 0, effect = 86, accuracy = 255 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 120,
        moves = {
          move({ id = "thump-a", power = 40 }),
          move({ id = "thump-b", power = 40 }),
        },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  ok(not battle:submitChoice("p2", { action = "fight", move = 0 }),
     "Disable blocks choosing the foe's last-used move")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", hp = 150, maxHp = 200, spd = 120,
        moves = { move({ id = "leech-seed", power = 0, effect = 84 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 160, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  local foeHpBefore = fighterIn(battle:snapshot(), "p2").hp
  local userHpBefore = fighterIn(battle:snapshot(), "p1").hp
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local snap = battle:snapshot()
  ok(fighterIn(snap, "p2").hp < foeHpBefore,
     "Leech Seed residual damages the seeded mon")
  ok(fighterIn(snap, "p1").hp > userHpBefore,
     "Leech Seed residual heals the seeder")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "transform", power = 0, effect = 57 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = {
          move({ id = "foe-one", power = 55, type = 1 }),
          move({ id = "foe-two", power = 30, type = 2 }),
        },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  local overlay = nil
  for _, event in ipairs(events) do
    if event.t == "moves" and event.slot == 0 and event.mon == nil
       and event.moves and event.moves[1] then
      overlay = event
    end
  end
  ok(overlay ~= nil, "Transform emits a moves event")
  eq(overlay and overlay.moves[1].id, "foe-one",
     "Transform moves event carries the foe's first move id")
  eq(overlay and overlay.mon, nil,
     "Transform overlay omits mon so the client does not write mine[]")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 1,
        moves = {
          move({ id = "mimic", power = 0, effect = 82 }),
          move({ id = "splash", power = 0, effect = 85 }),
        },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 120,
        moves = {
          move({ id = "copied", power = 70 }),
          move({ id = "other", power = 10 }),
        },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 1 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  local sawMimic, mimicMon = false, "unset"
  for _, event in ipairs(events) do
    if event.t == "moves" and event.slot == 0 and event.moves and event.moves[1]
       and event.moves[1].id == "copied" then
      sawMimic = true
      mimicMon = event.mon
    end
  end
  ok(sawMimic, "Mimic emits a moves event with the copied move id")
  eq(mimicMon, nil, "Mimic overlay omits mon so the client does not write mine[]")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "thump", pp = 20, maxPp = 20, power = 40 }) },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 1,
        moves = { move({ id = "splash", power = 0, effect = 85 }) },
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  local spent, spentMon = nil, nil
  for _, event in ipairs(events) do
    if event.t == "moves" and event.slot == 0 and event.moves and event.moves[1] then
      spent = event.moves[1]
      spentMon = event.mon
    end
  end
  ok(spent ~= nil, "using a move emits a moves event so FIGHT can redraw PP")
  eq(spent and spent.pp, 19, "...with the spent count")
  eq(spent and spent.maxPp, 20, "...and the maximum the menu prints beside it")
  eq(spent and spent.id, "thump", "...for the slot that was actually used")
  eq(spentMon, 0, "...and names the fielded party index")
end

-- ------------------------------------------------------------------
-- 23. Gen1 badge boosts on mediated fighters: against the computer only
-- ------------------------------------------------------------------
--
-- The cart boosts the player's monster and only outside a link battle
-- (pokered's ApplyBadgeStatBoosts, "return if link battle"), so the referee
-- keeps an uploaded set on side a of wild / coop_wild / coop_npc and drops it
-- in 1v1, coop_pvp and on side b (Turn.BADGE_MODES, Turn.BADGE_SIDE).  This
-- section used to assert a 1v1 boost -- the leak docs/plans/gen3-badge-rules.md
-- §1 fixes -- and now states the three halves of the rule: a PvP fight with
-- badges is the unbadged fight, damage and turn order alike; the same seats in
-- a computer fight are boosted, so the gate is the mode and not a removal; and
-- side b's upload is ignored even there.  server/battle_turn.test.js states
-- the same three against lib/battle, and the badges_* parity scenarios hold
-- the twins to the same streams.

do
  local Effects = BattleSim.Effects
  eq(Effects.badgeBoost(64, "atk", nil), 64, "no badge set leaves the stat alone")
  eq(Effects.badgeBoost(64, "atk", { BOULDERBADGE = true }), 72,
     "BOULDERBADGE boosts attack by floor(9/8)")
  eq(Effects.badgeBoost(64, "def", { THUNDERBADGE = true }), 72,
     "THUNDERBADGE boosts defense")
  -- pokered's .applyBoostToStat holds the boosted word at MAX_STAT_VALUE (the
  -- engine's port: src/battle/Damage.lua:44-54).
  eq(Effects.MAX_STAT_VALUE, 999, "the cap is MAX_STAT_VALUE, 999")
  eq(Effects.badgeBoost(887, "atk", { BOULDERBADGE = true }), 997,
     "887 boosts to 997, under the cap")
  eq(Effects.badgeBoost(888, "atk", { BOULDERBADGE = true }), 999,
     "888 boosts to exactly 999")
  eq(Effects.badgeBoost(950, "atk", { BOULDERBADGE = true }), 999,
     "950 would boost to 1068 and is held at 999")

  local modes = {}
  for mode in pairs(Turn.BADGE_MODES) do modes[#modes + 1] = mode end
  table.sort(modes)
  eq(table.concat(modes, ","), "coop_npc,coop_wild,wild",
     "badges count in the three fights against the computer, and no other")
  eq(Turn.BADGE_SIDE, "a", "...and only on the player's side of them")

  local ALL = { BOULDERBADGE = true, THUNDERBADGE = true, SOULBADGE = true,
                VOLCANOBADGE = true }

  -- One exchange: Ann (side a) and Bob (side b) each swing once.  `a` / `b`
  -- override the stats and carry each seat's upload; `a.seed` / `a.confusion`
  -- set up a confused Ann on a chosen seed (section (d)).
  local function exchange(mode, a, b)
    local battle = battleOf({
      mode = mode, seed = a.seed or 777001,
      sides = {
        a = { { playerId = "p1", name = "Ann", badges = a.badges,
                mons = { mon({
                  maxHp = 200, hp = 200, atk = a.atk or 88, def = a.def or 40,
                  spd = a.spd or 40, confusion = a.confusion,
                  moves = { move({ power = 50 }) },
                }) } } },
        b = { { playerId = "p2", name = "Bob", badges = b.badges,
                mons = { mon({
                  species = "Beta", maxHp = 200, hp = 200, atk = b.atk or 40,
                  def = 80, spd = b.spd or 40, moves = { move({ power = b.power or 1 }) },
                }) } } },
      },
    })
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    return drain(battle)
  end
  local function hitOn(events, slot)
    for _, event in ipairs(events) do
      if event.t == "damage" and event.slot == slot then return event.amount end
    end
    return nil
  end
  local function firstHit(events)
    for _, event in ipairs(events) do
      if event.t == "damage" then return event.slot end
    end
    return nil
  end

  -- Damage: BOULDERBADGE on Ann's physical hit.  Speed: Ann at 40 against Bob
  -- at 42, so SOULBADGE (40 -> 45) is exactly what decides who swings first.
  local hit = { badges = { BOULDERBADGE = true } }
  local fast = { badges = { SOULBADGE = true }, spd = 40 }
  local foe = { spd = 42 }

  -- (a) the link modes: every byte of the badged fight is the unbadged one.
  for _, mode in ipairs({ "1v1", "coop_pvp" }) do
    local bare = exchange(mode, {}, {})
    local plainDmg = hitOn(bare, 3)
    -- 18 since K12 (the damage roll reads the RNG's high bits); 17 before.
    eq(plainDmg, 18, mode .. ": the unbadged attack lands for 18")
    eq(hitOn(exchange(mode, hit, {}), 3), plainDmg,
       mode .. ": BOULDERBADGE does not raise the damage -- a link battle")
    -- One seat at a time: both at once would cancel here (each attack is
    -- boosted by the same ninth its target's defence is) and prove nothing.
    eq(dumpAll(exchange(mode, { badges = ALL }, {})), dumpAll(bare),
       mode .. ": side a uploading every badge fights the unbadged fight")
    eq(dumpAll(exchange(mode, {}, { badges = ALL })), dumpAll(bare),
       mode .. ": so does side b uploading every badge")
    eq(firstHit(exchange(mode, { spd = 40 }, foe)), 0,
       mode .. ": unbadged, Bob (42) outspeeds Ann (40)")
    eq(firstHit(exchange(mode, fast, foe)), 0,
       mode .. ": SOULBADGE does not let Ann overtake him")
  end

  -- (b) the same seats against the computer: boosted, which is what makes the
  --     gate the mode rather than a removal of the boost.
  for _, mode in ipairs({ "coop_npc", "wild" }) do
    eq(hitOn(exchange(mode, {}, {}), 3), 18, mode .. ": unbadged, the same 18")
    -- 88 -> floor(88 * 9 / 8) = 99 Attack; lib/battle reaches the same 20
    -- (18 / 20 since K12's high-bits damage roll; 17 / 19 before).
    eq(hitOn(exchange(mode, hit, {}), 3), 20,
       mode .. ": BOULDERBADGE raises side a's physical damage to 20")
    eq(firstHit(exchange(mode, { spd = 40 }, foe)), 0,
       mode .. ": unbadged, the foe (42) still goes first")
    eq(firstHit(exchange(mode, fast, foe)), 3,
       mode .. ": SOULBADGE (40 -> 45) puts side a in front")
  end

  -- (c) side b's upload, ignored against the computer too.  Each of these
  --     would have changed the fight had it counted: THUNDERBADGE would cut
  --     Ann's hit, BOULDERBADGE would raise Bob's, and SOULBADGE (37 -> 41)
  --     would put Bob ahead of Ann's 40.
  local bare = exchange("coop_npc", {}, { power = 30 })
  local hostile = exchange("coop_npc", {}, { badges = ALL, power = 30 })
  eq(hitOn(hostile, 3), hitOn(bare, 3), "coop_npc: side b's THUNDERBADGE is ignored")
  eq(hitOn(hostile, 0), hitOn(bare, 0), "coop_npc: side b's BOULDERBADGE is ignored")
  eq(dumpAll(hostile), dumpAll(bare), "coop_npc: side b's upload changes nothing at all")
  eq(firstHit(exchange("coop_npc", {}, { badges = ALL, spd = 37 })), 3,
     "coop_npc: side b's SOULBADGE does not overtake side a")

  -- (d) the confusion self-hit reads the badge-boosted stats as well: pokered's
  --     HandleSelfConfusionDamage takes wBattleMon's Attack and Defense, which
  --     ApplyBadgeStatBoosts raised, and the engine port's computeDamage(user,
  --     user) boosts both ends (src/battle/BattleState.lua:4187).  Attack 160
  --     and Defense 9 keep the two boosts from cancelling: 160 -> 180 and
  --     9 -> 10 move the 40-power hit from 144 to 146.
  local function selfHit(events)
    local hurt = false
    for _, event in ipairs(events) do
      if event.t == "msg" and event.text and event.text:find("hurt itself", 1, true) then
        hurt = true
      elseif hurt and event.t == "damage" then
        return event.amount
      end
    end
    return nil
  end
  local confusedSeed
  for seed = 1, 200 do
    if selfHit(exchange("coop_npc", { seed = seed, atk = 160, def = 9, confusion = 3 }, {})) then
      confusedSeed = seed
      break
    end
  end
  ok(confusedSeed ~= nil, "found a seed where a confused Ann hits herself")
  local function confused(mode, badges)
    return selfHit(exchange(mode, { seed = confusedSeed, atk = 160, def = 9, confusion = 3,
                                    badges = badges }, {}))
  end
  local PAIR = { BOULDERBADGE = true, THUNDERBADGE = true }
  eq(confused("coop_npc", nil), 144, "coop_npc: unbadged, Ann's self-hit is 144")
  eq(confused("coop_npc", PAIR), 146,
     "coop_npc: BOULDERBADGE + THUNDERBADGE (180 / 10) make it 146")
  eq(confused("coop_npc", { BOULDERBADGE = true }), 162,
     "coop_npc: BOULDERBADGE alone (180 / 9) raises it to 162")
  eq(confused("coop_npc", { THUNDERBADGE = true }), 130,
     "coop_npc: THUNDERBADGE alone (160 / 10) cuts it to 130")
  eq(confused("1v1", nil), 144, "1v1: the same unbadged 144")
  eq(confused("1v1", PAIR), 144, "1v1: the pair reaches no self-hit in a link battle")
end

-- ------------------------------------------------------------------
-- 12b2. Gen 1 crit uses species base Speed, not battle Speed; high-crit rides the move
-- ------------------------------------------------------------------
do
  local function playCrit(seed, aOpts, badges, mode)
    local battle = battleOf({
      seed = seed, mode = mode,
      sides = {
        a = { { playerId = "p1", name = "Ann", badges = badges,
                mons = { mon({
                  maxHp = 200, hp = 200, atk = 80, spd = 80,
                  baseSpd = aOpts.baseSpd,
                  moves = { move({ power = 50, highCrit = aOpts.highCrit }) },
                }) } } },
        b = { { playerId = "p2", name = "Bob",
                mons = { mon({
                  species = "Beta", maxHp = 200, hp = 200, def = 80, spd = 10,
                  moves = { move({ power = 1 }) },
                }) } } },
      },
    })
    drain(battle)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    return drain(battle), battle
  end
  local function sawCrit(events)
    for _, event in ipairs(events) do
      if event.t == "msg" and event.text == "Critical hit!" then return true end
    end
    return false
  end

  -- threshold(1) = 0: no roll is below 0, so battle Speed 80 cannot leak in.
  ok(not sawCrit(playCrit(1, { baseSpd = 1 })),
     "species base Speed 1 never crits, even with battle Speed 80")

  -- threshold(100) = 50; high-crit ×8 → 255. Need a roll in [50, 254] so
  -- ordinary odds miss and high-crit hits — otherwise dropping highCritMove
  -- would still pass on a low roll.
  local critSeed
  for seed = 1, 400 do
    if not sawCrit(playCrit(seed, { baseSpd = 100 }))
       and sawCrit(playCrit(seed, { baseSpd = 100, highCrit = true })) then
      critSeed = seed
      break
    end
  end
  ok(critSeed ~= nil,
     "found a seed where ordinary odds miss and a high-crit move hits")
  ok(not sawCrit(playCrit(critSeed, { baseSpd = 100 })),
     "base Speed 100 without highCrit misses on that seed")
  ok(sawCrit(playCrit(critSeed, { baseSpd = 100, highCrit = true })),
     "highCrit on the move sheet raises the Gen 1 threshold")

  -- Soul Badge must not change crit (Alpha still outspeeds either way).  Played
  -- against the computer, because that is the only fight the badge reaches the
  -- battler in at all (Turn.BADGE_MODES, section 23): in the 1v1 above it is
  -- dropped at create and this comparison would hold for the wrong reason.
  local bare = dumpAll(playCrit(777002, { baseSpd = 80 }, nil, "coop_npc"))
  local badgedEvents, badgedBattle =
    playCrit(777002, { baseSpd = 80 }, { SOULBADGE = true }, "coop_npc")
  eq(badgedBattle.byId.p1.badges and badgedBattle.byId.p1.badges.SOULBADGE, true,
     "coop_npc: the badge really is on the battler for this comparison")
  eq(bare, dumpAll(badgedEvents),
     "SOULBADGE does not change crit rate or this turn's resolution")

  -- Old sheet: omitted baseSpd falls back to stats.spd, still without the badge.
  local fallbackBare = dumpAll(playCrit(777002, {}, nil, "coop_npc"))
  local fallbackBadged = dumpAll(playCrit(777002, {}, { SOULBADGE = true }, "coop_npc"))
  eq(fallbackBare, fallbackBadged,
     "omitted baseSpd still ignores SOULBADGE")
end

-- ------------------------------------------------------------------
-- 12c. faint with bench asks for a switch (no auto-send)
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    aMons = {
      mon({ species = "Alpha", maxHp = 1, atk = 5, spd = 10 }),
      mon({ species = "Gamma", maxHp = 200, atk = 50, spd = 50 }),
    },
    bMons = {
      mon({ species = "Beta", maxHp = 300, atk = 150, spd = 120, level = 50 }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  local sawFaint, sawSend = false, false
  for _, event in ipairs(events) do
    if event.t == "faint" and event.slot == 0 then sawFaint = true end
    if event.t == "send" and event.slot == 0 and event.text == "Gamma" then
      sawSend = true
    end
  end
  ok(sawFaint, "faint emitted for the KO'd seat")
  ok(not sawSend, "bench is not auto-sent on faint")
  local faintAmt = nil
  for _, event in ipairs(events) do
    if event.t == "faint" and event.slot == 0 then faintAmt = event.amount end
  end
  eq(faintAmt, 1, "faint.amount=1 marks mustReplace (living bench)")
  local snap = battle:snapshot()
  local a = fighterIn(snap, "p1")
  ok(a and a.mustReplace == true, "snapshot marks mustReplace")
  ok(a and a.species == nil, "no active mon until the player switches")

  ok(battle:submitChoice("p1", { action = "fight", move = 0 }) == false,
     "fight is refused while mustReplace")
  ok(battle:submitChoice("p1", { action = "switch", slot = 1 }) == true,
     "switch to the bench is accepted")
  battle:submitChoice("p2", { action = "fight", move = 0 })
  events = drain(battle)
  local sent = false
  for _, event in ipairs(events) do
    if event.t == "send" and event.text == "Gamma" then sent = true end
  end
  ok(sent, "chosen replacement is sent out")
  eq(fighterIn(battle:snapshot(), "p1").species, "Gamma", "Gamma is now active")
end

do
  -- Empty bench: faint has no amount; fight ends without a replace window.
  local battle = battleOf({
    aMons = { mon({ species = "Alpha", maxHp = 1, atk = 5, spd = 10 }) },
    bMons = {
      mon({ species = "Beta", maxHp = 300, atk = 150, spd = 120, level = 50 }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  local faintAmt, over = "missing", false
  for _, event in ipairs(events) do
    if event.t == "faint" and event.slot == 0 then faintAmt = event.amount end
    if event.t == "over" then over = true end
  end
  eq(faintAmt, nil, "empty-bench faint omits amount (no mustReplace)")
  ok(over, "and the fight ends when the last mon falls")
  local a = fighterIn(battle:snapshot(), "p1")
  ok(a and a.mustReplace ~= true, "snapshot has no mustReplace")
end

do
  -- Both sides lose their last mon on the same action (KO + recoil) → draw.
  -- An empty-bench KO still ends before the foe moves; mutual faint is the
  -- recoil / explode / residual case, not two sequential Tackles.
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 1, atk = 200, spd = 90,
        moves = { move({ id = "take-down", power = 90, effect = 48 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 1, atk = 5, spd = 10 }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  local outcome = battle:outcome()
  ok(outcome and outcome.outcome == "draw", "both-faint same turn is a draw")
  eq(outcome and outcome.reason, "ko", "under the ko reason")
  local overReason = nil
  for _, event in ipairs(events) do
    if event.t == "over" then overReason = event.text end
  end
  eq(overReason, "ko", "over event names ko")
end

-- ------------------------------------------------------------------
-- 12c2. round 11: the replace phase is a phase, not a folded-in choice
-- ------------------------------------------------------------------
--
-- 12c above pins the *outcome* a faint-with-bench has always had: nothing is
-- auto-sent, and the seat owes a switch.  What round 11 changed is the shape of
-- the window that collects it.  A faint used to advance the turn and fold the
-- replacement into the next ordinary choice box, so the player picked a move at
-- a foe that was not on the field yet.  Now the referee holds a phase of its
-- own between the two turns -- `_openReplace` / `_closeReplace` -- and the
-- three things a client reads off that are all invisible to 12c:
--
--   * the turn number does NOT move while the phase is open.  A client that
--     saw turn 2 open would draw the next box; the fight is still on the turn
--     whose faint opened this.
--   * the solicitation is a `turn` event WITH `slot` -- one per owing seat, in
--     `self.fighters` order (side a then side b, ascending field slot).  A
--     slot-less `turn` still means "ordinary choice window", so the two are
--     told apart by a field that already rides the wire.
--   * the phase belongs to the owing seats and to nobody else.  A standing
--     seat's fight would be an answer to a window that has not opened, and a
--     `cancel` would be a second way to hold the field open a monster short.
--
-- And the clock still covers it: the same deadline sweep that answers an
-- unanswered move answers an unanswered replacement, so a seat that walks away
-- mid-replace cannot wedge the fight.

do
  -- (a) 1v1, the single-fighter case that predates the phase: only one seat can
  -- ever be owing, and it still opens and closes cleanly.  This is the
  -- regression guard against a fix that only works for multi-fighter coop.
  local battle = battleOf({
    seed = 111001,
    aMons = {
      mon({ species = "Alpha", maxHp = 1, atk = 5, spd = 10 }),
      mon({ species = "Gamma", maxHp = 200, atk = 50, spd = 50 }),
    },
    bMons = {
      mon({ species = "Beta", maxHp = 300, atk = 150, spd = 120, level = 50 }),
    },
  })
  drain(battle)
  eq(battle:snapshot().turn, 1, "the fight opens on turn 1")

  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local snap = battle:snapshot()
  eq(snap.phase, "replace", "a faint with a living bench opens the replace phase")
  eq(snap.turn, 1, "and the turn number does not move while it is open")
  listEq(snap.waiting, { "p1" }, "only the fallen seat is owed anything")

  local solicits, bare = {}, 0
  for _, event in ipairs(events) do
    if event.t == "turn" then
      if event.slot ~= nil then solicits[#solicits + 1] = event else bare = bare + 1 end
    end
  end
  eq(#solicits, 1, "one solicitation for the one owing seat")
  eq(solicits[1] and solicits[1].slot, 0, "...naming its field slot")
  eq(solicits[1] and solicits[1].amount, 1, "...and the turn it is still on")
  eq(bare, 0, "no ordinary choice window opened behind it")

  ok(battle:submitChoice("p1", { action = "switch", slot = 1 }) == true,
     "the owing seat's switch is accepted")
  events = drain(battle)
  local sawSend, closed = false, nil
  for _, event in ipairs(events) do
    if event.t == "send" and event.text == "Gamma" then sawSend = true end
    if event.t == "turn" and event.slot == nil then closed = event end
  end
  ok(sawSend, "the replacement is fielded when the phase closes")
  ok(closed ~= nil, "and a slot-less turn opens the ordinary window")
  eq(closed and closed.amount, 2, "...on turn 2")
  local after = battle:snapshot()
  eq(after.phase, "choice", "the phase is back to choice")
  eq(after.turn, 2, "and only now does the turn increment")
end

do
  -- (b) one seat per side falls in the SAME action (recoil KO, both benched):
  -- `_anyMustReplace` finds two owing seats, so two solicitations go out before
  -- either is answered, and the phase stays open until BOTH have replaced.
  local battle = battleOf({
    seed = 111002,
    aMons = {
      mon({
        species = "Alpha", maxHp = 1, atk = 200, spd = 90,
        moves = { move({ id = "take-down", power = 90, effect = 48 }) },
      }),
      mon({ species = "Gamma", maxHp = 200 }),
    },
    bMons = {
      mon({ species = "Beta", maxHp = 1, atk = 5, spd = 10 }),
      mon({ species = "Delta", maxHp = 200 }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)

  local snap = battle:snapshot()
  eq(snap.phase, "replace", "two faints in one action still open one replace phase")
  eq(snap.turn, 1, "and it holds the turn number just the same")
  listEq(snap.waiting, { "p1", "p2" }, "both fallen seats are owed")

  local solicits, bare = {}, 0
  for _, event in ipairs(events) do
    if event.t == "turn" then
      if event.slot ~= nil then solicits[#solicits + 1] = event else bare = bare + 1 end
    end
  end
  eq(#solicits, 2, "exactly one solicitation per owing seat")
  eq(solicits[1] and solicits[1].slot, 0, "...side a's seat (slot 0) first")
  eq(solicits[2] and solicits[2].slot, 3, "...then side b's (slot 3) -- fighters order")
  eq(bare, 0, "and no ordinary window opened while both were pending")

  ok(battle:submitChoice("p1", { action = "switch", slot = 1 }) == true,
     "the first owing seat replaces")
  events = drain(battle)
  local earlySend, earlyTurn = false, false
  for _, event in ipairs(events) do
    if event.t == "send" then earlySend = true end
    if event.t == "turn" then earlyTurn = true end
  end
  ok(not earlySend, "nothing is fielded on a half-answered phase")
  ok(not earlyTurn, "and no turn of any shape is emitted")
  eq(battle:snapshot().phase, "replace", "the phase is still open on the second seat")
  eq(battle:snapshot().turn, 1, "turn number still pinned")

  ok(battle:submitChoice("p2", { action = "switch", slot = 1 }) == true,
     "the second owing seat replaces")
  events = drain(battle)
  local sends, closes = {}, 0
  for _, event in ipairs(events) do
    if event.t == "send" then sends[#sends + 1] = event.text end
    if event.t == "turn" and event.slot == nil then closes = closes + 1 end
  end
  listEq(sends, { "Gamma", "Delta" }, "both replacements field together, side a first")
  eq(closes, 1, "and a single ordinary window opens for the pair")
  eq(battle:snapshot().phase, "choice", "the phase closes once nobody owes a send-out")
  eq(battle:snapshot().turn, 2, "and the turn finally advances")
end

do
  -- (c) coop_pvp, two fighters a side, one of side a's falls: the phase is the
  -- owing seat's alone.  Its partner is refused whatever it asks, and the owing
  -- seat itself may only switch -- `cancel` is not a way out of a forced
  -- replacement.
  local battle = battleOf({
    mode = "coop_pvp",
    seed = 111003,
    sides = {
      a = {
        { playerId = "p1", name = "Ann", mons = {
          mon({ species = "Alpha", maxHp = 300, atk = 20, spd = 80 }),
          mon({ species = "Omega", maxHp = 300 }) } },
        { playerId = "q1", name = "Amy", mons = {
          mon({ species = "Gamma", maxHp = 1, atk = 5, spd = 5 }),
          mon({ species = "Delta", maxHp = 300 }) } },
      },
      b = {
        { playerId = "p2", name = "Bob", mons = {
          mon({ species = "Beta", maxHp = 300, atk = 150, spd = 120, level = 50 }) } },
        { playerId = "q2", name = "Ben", mons = {
          mon({ species = "Zeta", maxHp = 300, atk = 20, spd = 60 }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("q1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("p2", { action = "fight", move = 0, target = 1 })
  battle:submitChoice("q2", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)

  local snap = battle:snapshot()
  eq(snap.phase, "replace", "the partner's KO opens the phase")
  eq(snap.turn, 1, "on the turn the faint happened")
  listEq(snap.waiting, { "q1" }, "and only the fallen seat owes anything")
  ok(fighterIn(snap, "p1").species == "Alpha", "its standing partner is untouched")

  local solicits = {}
  for _, event in ipairs(events) do
    if event.t == "turn" and event.slot ~= nil then solicits[#solicits + 1] = event end
  end
  eq(#solicits, 1, "one solicitation, for the one owing seat")
  eq(solicits[1] and solicits[1].slot, 1, "...naming q1's field slot, not the side")

  ok(battle:submitChoice("p1", { action = "fight", move = 0 }) == false,
     "a standing seat cannot fight during someone else's replacement")
  ok(battle:submitChoice("p1", { action = "switch", slot = 1 }) == false,
     "...nor sneak a free switch in on the phase")
  ok(battle:submitChoice("q1", { action = "cancel" }) == false,
     "a forced replacement cannot be taken back")
  ok(battle:submitChoice("q1", { action = "fight", move = 0 }) == false,
     "and the owing seat itself may not answer with a fight")
  eq(battle:snapshot().phase, "replace", "four refusals later the phase is untouched")
  eq(#drain(battle), 0, "and a refused choice emits nothing at all")

  ok(battle:submitChoice("q1", { action = "switch", slot = 1 }) == true,
     "only the owing seat's switch closes it")
  events = drain(battle)
  local sent, closed = nil, false
  for _, event in ipairs(events) do
    if event.t == "send" then sent = event end
    if event.t == "turn" and event.slot == nil then closed = true end
  end
  eq(sent and sent.text, "Delta", "the replacement is fielded")
  eq(sent and sent.slot, 1, "...into the seat that owed it")
  ok(closed, "and the ordinary window opens behind it")
  eq(battle:snapshot().phase, "choice", "phase closed")
  eq(battle:snapshot().turn, 2, "turn advanced exactly once for the whole phase")
end

do
  -- (d) nobody answers: the choice clock covers a replace phase the same way it
  -- covers a choice window.  `_autoChoice` takes its `mustReplace` branch, the
  -- seat is narrated as having run out of time, and the fight carries on rather
  -- than wedging on a field that is a monster short.
  local battle = battleOf({
    seed = 111004,
    choiceTimeout = 10,
    aMons = {
      mon({ species = "Alpha", maxHp = 1, atk = 5, spd = 10 }),
      mon({ species = "Gamma", maxHp = 200, atk = 50, spd = 50 }),
    },
    bMons = {
      mon({ species = "Beta", maxHp = 300, atk = 150, spd = 120, level = 50 }),
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  eq(battle:snapshot().phase, "replace", "the faint left a replacement owed")
  eq(battle:snapshot().deadline, 10, "and the phase armed the choice clock")

  ok(battle:tick(9) == false, "inside the deadline the sweep does nothing")
  eq(battle:snapshot().phase, "replace", "so the phase is still waiting")
  eq(battle:snapshot().turn, 1, "and the turn is still pinned")
  eq(#drain(battle), 0, "a quiet tick emits nothing")

  ok(battle:tick(11) == true, "past the deadline the sweep acts")
  local events = drain(battle)
  local timedOut, sent, closed = false, nil, false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "Ann ran out of time" then timedOut = true end
    if event.t == "send" then sent = event end
    if event.t == "turn" and event.slot == nil then closed = true end
  end
  ok(timedOut, "the unanswered seat is narrated the same as an unanswered move")
  eq(sent and sent.text, "Gamma", "the auto-picked bench mon is fielded")
  ok(closed, "and the ordinary window opens")
  ok(battle:outcome() == nil, "a timed-out replacement does not end the fight")
  eq(battle:snapshot().phase, "choice", "the phase closed on the clock alone")
  eq(battle:snapshot().turn, 2, "spending the turn the faint was on")
  eq(fighterIn(battle:snapshot(), "p1").species, "Gamma", "Gamma really is out")
end

-- ------------------------------------------------------------------
-- 12d. auto-pick retreats at low HP to an SE bench mon
-- ------------------------------------------------------------------

do
  local chart = { { 100, 0 }, { 100, 200 } }
  local battle = battleOf({
    chart = chart,
    choiceTimeout = 10,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, hp = 40, spd = 10,
        moves = { move({ id = "neutral", type = 0, power = 40 }) },
      }),
      mon({
        species = "Gamma", maxHp = 200, spd = 10,
        moves = { move({ id = "se-hit", type = 1, power = 40 }) },
      }),
    },
    bMons = {
      mon({ species = "Beta", maxHp = 200, spd = 90, types = { 1 } }),
    },
  })
  drain(battle)
  battle:submitChoice("p2", { action = "fight", move = 0 })
  ok(battle:tick(11) == true, "timeout retreats when HP is critical")
  eq(fighterIn(battle:snapshot(), "p1").species, "Gamma",
     "auto-pick switched to the SE bench mon at low HP")
end

-- ------------------------------------------------------------------
-- 12e. forced multi-turn narration (trap immobilize)
-- ------------------------------------------------------------------
--
-- R1c: a held monster's turn is CANNOT_MOVE -- ExecutePlayerMove skips it
-- without a word -- and the trapper's later hits are its own slot,
-- `.MultiturnMoveCheck`'s "<MON>'s attack continues!".  Nothing is said when
-- the forced turn is filed; the slot says it.

-- The computer's seats are the filled ones (SelectEnemyMove :2949-2955); a
-- player's held monster or trapper gets the battle menu and answers it
-- (R1d, `_menuFight`), so these run in a wild fight.
do
  local battle = battleOf({
    mode = "wild",
    aMons = { mon({ species = "Alpha", maxHp = 200, spd = 90,
      moves = { move({ id = "WRAP", power = 15, effect = 42 }) } }) },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 10 }) },
  })
  drain(battle)
  local a = battle.fighters[1]
  local b = battle.fighters[2]
  b.mons[1].trapped = { turns = 2, damage = 10, fromSlot = 0 }
  a.mons[1].trapping = { turns = 2, moveIndex = 1, targetSlot = 3 }
  a.choice, b.choice = nil, nil
  battle:_fillForcedChoices()
  local events = drain(battle)
  local said = false
  for _, event in ipairs(events) do
    if event.t == "msg" and tostring(event.text):find("can't move!", 1, true) then
      said = true
    end
  end
  ok(not said, "trap immobilize files CANNOT_MOVE without a word")
  ok(b.choice and b.choice.action == "skip", "and files the computer's skip")
  ok(a.choice == nil, "the player's trapper is asked instead")
end

do
  local battle = battleOf({
    mode = "wild",
    aMons = { mon({ species = "Alpha", maxHp = 200, spd = 10 }) },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 90,
        moves = { move({ id = "WRAP", power = 15, effect = 42 }) },
      }),
    },
  })
  drain(battle)
  local a = battle.fighters[1]
  local b = battle.fighters[2]
  b.mons[1].trapping = { turns = 2, moveIndex = 1, targetSlot = 0 }
  a.mons[1].trapped = { turns = 2, damage = 10, fromSlot = 3 }
  a.choice = nil
  b.choice = nil
  battle:_fillForcedChoices()
  local early = false
  for _, event in ipairs(drain(battle)) do
    if event.t == "msg" then early = true end
  end
  ok(not early, "filing the forced trap turns says nothing")
  ok(b.choice and b.choice.action == "fight" and b.choice.trapContinue,
     "trapper files its move's continuation")
  ok(a.choice == nil, "the held player is asked")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "and its FIGHT is CANNOT_MOVE")
  local events = drain(battle)
  local continued, animed, victimCant, ppSpent = false, false, false, false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "Beta's attack continues!" then
      continued = true
    end
    if event.t == "anim" and event.slot == 3 and event.text == "WRAP" then
      animed = true
    end
    if event.t == "msg" and tostring(event.text):find("can't move!", 1, true) then
      victimCant = true
    end
    if event.t == "msg" and event.text == "Beta used WRAP!" then ppSpent = true end
  end
  ok(continued, "trapper narrates the attack continues, in its slot")
  ok(animed, "trapper emits a continue anim (no re-roll)")
  ok(not victimCant, "the held victim's CANNOT_MOVE says nothing")
  ok(not ppSpent, "no used line: the continuation skips PlayerCanExecuteMove")
  eq(a.mons[1].hp, 190, "the stored 10 lands on the victim")
  eq(b.mons[1].trapping and b.mons[1].trapping.turns, 1, "one attack spent off the counter")
end

-- ------------------------------------------------------------------
-- 12f. auto-pick uses bag: heal / cure / X-item; setup skips subbed foes
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    choiceTimeout = 10,
    aBag = { POTION = 2 },
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, hp = 80, spd = 10,
        moves = { move({ id = "thump", power = 40 }) },
      }),
      mon({
        species = "Gamma", maxHp = 200, spd = 10,
        moves = { move({ id = "se-hit", type = 1, power = 40 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 90 }) },
  })
  drain(battle)
  battle:submitChoice("p2", { action = "fight", move = 0 })
  ok(battle:tick(11) == true, "timeout heals at ≤50% HP instead of fighting")
  local events = drain(battle)
  local usedItem = false
  for _, event in ipairs(events) do
    if event.t == "item" and event.text == "POTION" then usedItem = true end
  end
  ok(usedItem, "auto-pick spent a Potion")
  local a = fighterIn(battle:snapshot(), "p1")
  ok(a and a.species == "Alpha", "stayed in rather than SE-retreating")
  ok(a and a.hp > 80, "Potion healed before the foe's hit")
  eq(battle.byId.p1.bag.POTION, 1, "and decremented the fighter bag")
end

do
  local battle = battleOf({
    choiceTimeout = 10,
    aBag = { FULL_HEAL = 1, POTION = 1 },
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, hp = 200, spd = 10,
        status = "PSN",
        moves = { move({ id = "thump", power = 40 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 90 }) },
  })
  drain(battle)
  battle:submitChoice("p2", { action = "fight", move = 0 })
  ok(battle:tick(11) == true, "timeout cures status before other bag actions")
  local events = drain(battle)
  local cured = false
  for _, event in ipairs(events) do
    if event.t == "item" and event.text == "FULL_HEAL" then cured = true end
  end
  ok(cured, "auto-pick used Full Heal")
  local mon = battle.byId.p1.mons[1]
  eq(mon.status, nil, "poison cleared")
  eq(battle.byId.p1.bag.FULL_HEAL, nil, "Full Heal stack spent")
  eq(battle.byId.p1.bag.POTION, 1, "Potion left untouched at full HP")
end

do
  local battle = battleOf({
    choiceTimeout = 10,
    aBag = { X_ATTACK = 1 },
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 10,
        moves = { move({ id = "thump", power = 40 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 90 }) },
  })
  drain(battle)
  battle:submitChoice("p2", { action = "fight", move = 0 })
  ok(battle:tick(11) == true, "timeout uses X Attack while stages are flat")
  local events = drain(battle)
  local used = false
  for _, event in ipairs(events) do
    if event.t == "item" and event.text == "X_ATTACK" then used = true end
  end
  ok(used, "auto-pick spent X Attack")
  eq(battle.byId.p1.mons[1].stages.atk, 1, "attack stage rose")
end

do
  -- Foe behind a Substitute: skip status/setup, trade damage instead.
  local battle = battleOf({
    choiceTimeout = 10,
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 10,
        moves = {
          move({ id = "thump", power = 40 }),
          move({ id = "sleep-powder", power = 0, effect = 32, accuracy = 255 }),
          move({ id = "swords", power = 0, effect = 50 }),
        },
      }),
    },
    bMons = {
      mon({
        species = "Beta", maxHp = 200, spd = 90,
        substitute = 50,
      }),
    },
  })
  drain(battle)
  battle:submitChoice("p2", { action = "fight", move = 0 })
  ok(battle:tick(11) == true, "timeout damages through a Substitute")
  local events = drain(battle)
  local used = nil
  for _, event in ipairs(events) do
    if event.t == "anim" and event.slot == 0 then used = event.text end
  end
  eq(used, "thump", "auto-pick skips status/setup against a Substitute")
end

-- ------------------------------------------------------------------
-- 12f3. wildlife never uses an item, from either end
-- ------------------------------------------------------------------
--
-- A wild monster has no bag and no hands.  The seat is driven from two ends --
-- the hub auto-picks for it, and a submitted choice can arrive addressed to it
-- -- so both are pinned here.  The bag is handed to the wild seat deliberately:
-- the point is that even a seat that HAS one never spends it, so a hub that
-- seeds the wrong kit (which is what `wild` did with `DEFAULT_NPC_BAG`) cannot
-- put a Potion in a Rattata's mouth.  Trainer seats are unaffected -- 12f above
-- is the same fixture on the default 1v1 mode and still spends its Potion.

-- 1v1 wild keeps a lone human; coop_wild now refuses that seating, so the
-- partner is a dummy who never acts (timeout auto-picks a weak tap).
local function wildHumans(mode, p1)
  if mode == "coop_wild" then
    return {
      p1,
      { playerId = "p2", name = "Pat",
        mons = { mon({ species = "Gamma", maxHp = 200, spd = 1,
                       moves = { move({ id = "thump", power = 1 }) } }) } },
    }
  end
  return { p1 }
end

for _, mode in ipairs({ "wild", "coop_wild" }) do
  do
    local battle = battleOf({
      mode = mode,
      choiceTimeout = 10,
      seed = 88010,
      sides = {
        a = wildHumans(mode, {
          playerId = "p1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, spd = 90,
                         moves = { move({ id = "thump", power = 40 }) } }) },
        }),
        b = {
          { playerId = "wild", name = "Wild",
            -- Hurt below half and poisoned: 12f's fixture files a heal here.
            mons = { mon({ species = "Beta", maxHp = 200, hp = 40, spd = 10,
                           status = "PSN",
                           moves = { move({ id = "thump", power = 40 }) } }) },
            bag = { POTION = 2, FULL_HEAL = 1, X_ATTACK = 1 } },
        },
      },
    })
    drain(battle)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    ok(battle:tick(11) == true, mode .. ": the wild seat's turn resolves")
    local events = drain(battle)
    local itemUsed = nil
    for _, event in ipairs(events) do
      if event.t == "item" and event.side == "b" then itemUsed = event.text end
    end
    eq(itemUsed, nil, mode .. ": auto-pick never reaches the wild seat's bag")
    eq(battle.byId.wild.bag.POTION, 2, mode .. ": and spends none of it")
    eq(battle.byId.wild.bag.FULL_HEAL, 1, mode .. ": cure untouched too")
    eq(battle.byId.wild.mons[1].status, "poison", mode .. ": still poisoned")
  end

  do
    local battle = battleOf({
      mode = mode,
      seed = 88011,
      sides = {
        a = wildHumans(mode, {
          playerId = "p1", name = "Ann",
          -- Hurt, so the POTION has HP to restore: one at full HP is the
          -- cart's ItemUseNoEffect, refused before it is filed (FX-R1).
          mons = { mon({ species = "Alpha", maxHp = 200, hp = 100, spd = 90 }) },
          bag = { POTION = 1 },
        }),
        b = {
          { playerId = "wild", name = "Wild",
            mons = { mon({ species = "Beta", maxHp = 200, hp = 40, spd = 10 }) },
            bag = { POTION = 1 } },
        },
      },
    })
    drain(battle)
    ok(battle:submitChoice("wild", { action = "item", item = "POTION", slot = 0 })
       == false, mode .. ": a submitted item from the wild seat is refused")
    eq(battle.byId.wild.choice, nil, mode .. ": and files nothing")
    ok(battle:submitChoice("p1", { action = "item", item = "POTION", slot = 0 })
       == true, mode .. ": the player on side a still may")
  end
end

-- ------------------------------------------------------------------
-- 12h. round 5: `exp` event emission gates (`_awardExp`)
-- ------------------------------------------------------------------
--
-- The referee holds no species table and can never price a faint (the legal
-- floor, restated in `_awardExp`'s own comment); what it states is which mode
-- a faint happened in, who was still standing on the owner side, and how many
-- of them there were to split across. This section pins the gate itself --
-- which modes pay at all -- and the one edge case inside a paying mode where
-- a winner is excluded: a seat still owing a replacement after its own faint.

local thumpMove = function() return move({ id = "thump", power = 40, accuracy = 255 }) end

local function expEvents(events)
  local out = {}
  for _, event in ipairs(events) do
    if event.t == "exp" then out[#out + 1] = event end
  end
  return out
end

-- 1v1: a farming loop the mode gate refuses outright, deliberately rather
-- than incidentally -- vanilla link battles do not pay either.
do
  local battle = battleOf({
    mode = "1v1",
    seed = 90101,
    aMons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spd = 80, moves = { thumpMove() } }) },
    bMons = { mon({ species = "Beta", maxHp = 30, spd = 10, moves = { thumpMove() } }) },
  })
  drain(battle)
  local events = {}
  for _ = 1, 10 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  end
  ok(#expEvents(events) == 0, "1v1: no exp event, however the fight ends")
  local sawFaint = false
  for _, e in ipairs(events) do if e.t == "faint" then sawFaint = true end end
  ok(sawFaint, "...and a faint really did happen, so the gate is what refused it")
end

-- coop_pvp: the other PvP shape, same refusal -- paying a player for beating
-- another player is the farming loop, not a co-op detail.
do
  local battle = battleOf({
    mode = "coop_pvp",
    seed = 90102,
    sides = {
      a = { { playerId = "a1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spd = 80, moves = { thumpMove() } }) } } },
      b = { { playerId = "b1", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 30, spd = 10, moves = { thumpMove() } }) } } },
    },
  })
  drain(battle)
  local events = {}
  for _ = 1, 10 do
    if battle:outcome() then break end
    battle:submitChoice("a1", { action = "fight", move = 0 })
    battle:submitChoice("b1", { action = "fight", move = 0 })
    for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  end
  ok(#expEvents(events) == 0, "coop_pvp: no exp event either")
  local sawFaint = false
  for _, e in ipairs(events) do if e.t == "faint" then sawFaint = true end end
  ok(sawFaint, "...and again a faint really happened")
end

-- wild: the one owner-slot winner is paid, once, naming the fallen wild mon.
do
  local battle = battleOf({
    mode = "wild",
    seed = 90103,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spd = 80, moves = { thumpMove() } }) } } },
      b = { { playerId = "wild", name = "Wild",
              mons = { mon({ species = "Beta", maxHp = 60, spd = 10, moves = { thumpMove() } }) } } },
    },
  })
  drain(battle)
  local events = {}
  for _ = 1, 10 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  end
  local exps = expEvents(events)
  eq(#exps, 1, "wild: exactly one exp event")
  eq(exps[1] and exps[1].slot, 0, "...paid to the sole owner seat, slot 0")
  eq(exps[1] and exps[1].species, "Beta", "...naming the wild mon that fell")
  eq(exps[1] and exps[1].participants, 1, "...split one way")
end

-- coop_wild: both owner seats stand at the KO, so both are paid, in
-- field-slot order.
do
  local battle = battleOf({
    mode = "coop_wild",
    seed = 90104,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spd = 80, moves = { thumpMove() } }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 90, spd = 70, moves = { thumpMove() } }) } },
      },
      b = { { playerId = "wild", name = "Wild",
              mons = { mon({ species = "Beta", maxHp = 200, spd = 10, moves = { thumpMove() } }) } } },
    },
  })
  drain(battle)
  local events = {}
  for _ = 1, 10 do
    if battle:outcome() then break end
    battle:submitChoice("a1", { action = "fight", move = 0 })
    battle:submitChoice("a2", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  end
  local exps = expEvents(events)
  eq(#exps, 2, "coop_wild: one exp event per standing owner-slot winner")
  eq(exps[1] and exps[1].slot, 0, "...a1 (slot 0) first")
  eq(exps[2] and exps[2].slot, 1, "...then a2 (slot 1)")
  eq(exps[1] and exps[1].participants, 2, "...both counted in the split")
  eq(exps[2] and exps[2].participants, 2, "...on both events")
end

-- coop_npc: the trainer-shaped exp-awarding mode, same shape as coop_wild
-- but a 2v2 npc side rather than a single wild seat.
--
-- Both a1 and a2 aim at the same seat (b1/slot 3) on purpose: a1 (faster)
-- KOs it, and a2's identical aim is exactly the mid-turn-dead-target case
-- `_retarget` exists for. Before the U-wave fix this fizzled ("has no
-- target") -- silently, since the surrounding assertion only checked
-- `#expEvents(events) > 0`, which the KO alone already satisfies. The fixed
-- behaviour changed the stream under that assertion without breaking it: the
-- fizzle (one `msg`) became a real attack (`anim` + `msg` + `damage`, +2
-- events over the old shape), landing on b2/slot 4 -- the nearest living
-- seat -- rather than the corpse a2 actually aimed at. Pinned explicitly here
-- so that change stays intended rather than silent.
do
  local battle = battleOf({
    mode = "coop_npc",
    -- Re-scanned when R1c moved the accuracy byte behind the crit and the
    -- roll: a seed where a1 alone fells b1 and a2 still has its turn after.
    seed = 90106,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spd = 80, moves = { thumpMove() } }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 90, spd = 70, moves = { thumpMove() } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob",
          mons = { mon({ species = "Beta", maxHp = 60, spd = 60, moves = { thumpMove() } }) } },
        { playerId = "b2", name = "Bea",
          mons = { mon({ species = "Delta", maxHp = 60, spd = 50, moves = { thumpMove() } }) } },
      },
    },
  })
  drain(battle)
  local events = {}
  for _ = 1, 12 do
    if battle:outcome() then break end
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("b1", { action = "fight", move = 0 })
    battle:submitChoice("b2", { action = "fight", move = 0 })
    for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  end
  ok(#expEvents(events) > 0, "coop_npc: at least one exp event over a KO")

  -- The retarget itself: a2 (Abe/Gamma) still aimed at the now-dead b1 seat
  -- (slot 3) when its action ran, immediately after the two exp events b1's
  -- fall paid out. It must not fizzle -- it swings, and lands on b2 (slot 4).
  local koIdx, secondExpIdx = nil, nil
  local expSeen = 0
  for i, e in ipairs(events) do
    if e.t == "faint" and e.text == "Beta" then koIdx = i end
    if e.t == "exp" then
      expSeen = expSeen + 1
      if expSeen == 2 then secondExpIdx = i end
    end
  end
  ok(koIdx ~= nil, "coop_npc retarget: b1's Beta really did fall")
  ok(secondExpIdx ~= nil and secondExpIdx > koIdx,
     "coop_npc retarget: both exp events (a1 and a2's shares) paid before a2's own action runs")

  local noFizzle, sawAnim, sawDamageOnSlot4 = true, false, false
  for i = secondExpIdx + 1, #events do
    local e = events[i]
    if e.t == "msg" and e.text and e.text:find("has no target", 1, true) then
      noFizzle = false
    end
    if e.t == "anim" and e.side == "a" and e.slot == 1 then sawAnim = true end
    if sawAnim and e.t == "damage" and e.side == "b" and e.slot == 4 then
      sawDamageOnSlot4 = true
      break
    end
  end
  ok(noFizzle, "coop_npc retarget: a2 never says 'has no target' for the dead b1 seat")
  ok(sawAnim, "coop_npc retarget: a2's move still plays its anim (slot 1, the attacker's own seat)")
  ok(sawDamageOnSlot4,
     "coop_npc retarget: a2's attack lands as real damage on b2/slot 4, the nearest living seat")
end

-- A seat still owing a replacement after its own faint: neither paid nor
-- counted in the divisor. a1 has no bench, so once its lone mon goes down it
-- is permanently `activeMon() == nil` -- exactly what CoopSim's owner-guard
-- reads as "not standing" -- while a2 finishes the wild mon off alone.
do
  local battle = battleOf({
    mode = "coop_wild",
    seed = 90106,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 1, spd = 5, moves = { thumpMove() } }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 100, spd = 60, moves = { thumpMove() } }) } },
      },
      b = { { playerId = "wild", name = "Wild",
              mons = { mon({ species = "Beta", maxHp = 30, spd = 100, atk = 20, moves = { thumpMove() } }) } } },
    },
  })
  drain(battle)
  local events = {}
  for _ = 1, 15 do
    if battle:outcome() then break end
    battle:submitChoice("a1", { action = "fight", move = 0 })
    battle:submitChoice("a2", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  end
  local sawA1Faint = false
  for _, e in ipairs(events) do
    if e.t == "faint" and e.slot == 0 then sawA1Faint = true end
  end
  ok(sawA1Faint, "the fixture really did down a1 before the wild mon fell")
  local exps = expEvents(events)
  eq(#exps, 1, "the seat still owing a replacement is not paid a second event")
  eq(exps[1] and exps[1].slot, 1, "...only a2 (slot 1), the seat actually standing")
  eq(exps[1] and exps[1].participants, 1,
     "...and the divisor is 1 -- the down seat is not counted in the split either")
end

-- ------------------------------------------------------------------
-- 12i. round 6: participation -- who fought the monster that fell
-- ------------------------------------------------------------------
--
-- Section 12h pinned the emission GATE (which modes pay, and the one
-- exclusion the old "standing winners" rule needed). Round 6 replaced
-- "standing winners" itself with vanilla's real rule: every mon of yours
-- that was ever in against the fallen foe and is still alive, benched
-- included (`Battle:_refield` / `Battle:_awardExp`, `src/BattleSim/Turn.lua`).
-- These four scenarios are the adversarial drive that pinned the Lua/JS twins
-- against each other (byte-identical event streams, same rng) before this
-- suite existed to check them on its own; each one is restated here in this
-- file's own fixture idiom.

-- (a) a mon fights, switches out alive, and its replacement lands the KO:
-- both are paid, on their own party index, at the one seat that owns them.
do
  local battle = battleOf({
    mode = "wild",
    seed = 101,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mon({ species = "Alpha", maxHp = 200, atk = 90, spd = 80, moves = { thumpMove() } }),
        mon({ species = "Gamma", maxHp = 200, atk = 90, spd = 80, moves = { thumpMove() } }),
      } } },
      b = { { playerId = "wild", name = "Wild", mons = {
        mon({ species = "Beta", maxHp = 90, spd = 10,
              moves = { move({ id = "tap", power = 5 }) } }) } } },
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  local events = drain(battle)
  battle:submitChoice("p1", { action = "switch", slot = 1 })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  for _ = 1, 10 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  end
  local exps = expEvents(events)
  eq(#exps, 2, "switch-out-alive: both the fighter and its replacement are paid")
  eq(exps[1] and exps[1].slot, 0, "...both events on the one seat that owns them")
  eq(exps[2] and exps[2].slot, 0, "...")
  eq(exps[1] and exps[1].mon, 0, "...Alpha, party index 0, first")
  eq(exps[2] and exps[2].mon, 1, "...then Gamma, party index 1, the replacement")
  eq(exps[1] and exps[1].participants, 2, "...divisor 2 on both")
  eq(exps[2] and exps[2].participants, 2, "...")
end

-- (b) a participant faints before the KO lands: RemoveFaintedPlayerMon drops
-- it from the set, so it is neither paid nor counted in the divisor.
do
  local battle = battleOf({
    mode = "wild",
    seed = 202,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mon({ species = "Alpha", maxHp = 20, atk = 5, spd = 10,
              moves = { move({ id = "tap", power = 5 }) } }),
        mon({ species = "Gamma", maxHp = 300, atk = 90, spd = 80, moves = { thumpMove() } }),
      } } },
      b = { { playerId = "wild", name = "Wild", mons = {
        mon({ species = "Beta", maxHp = 120, atk = 90, spd = 50, moves = { thumpMove() } }) } } },
    },
  })
  drain(battle)
  local events = {}
  for _ = 1, 14 do
    if battle:outcome() then break end
    local snap, replaced = battle:snapshot(), false
    for _, f in ipairs(snap.field) do
      if f.playerId == "p1" and f.mustReplace then
        battle:submitChoice("p1", { action = "switch", slot = 1 })
        replaced = true
      end
    end
    if not replaced then battle:submitChoice("p1", { action = "fight", move = 0 }) end
    battle:submitChoice("wild", { action = "fight", move = 0 })
    for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  end
  local sawA1Faint = false
  for _, e in ipairs(events) do
    if e.t == "faint" and e.slot == 0 then sawA1Faint = true end
  end
  ok(sawA1Faint, "the fixture really did faint Alpha before the wild mon fell")
  local exps = expEvents(events)
  eq(#exps, 1, "the fainted participant funds no event of its own")
  eq(exps[1] and exps[1].mon, 1, "...only Gamma, party index 1, is paid")
  eq(exps[1] and exps[1].participants, 1,
     "...and the divisor is 1 -- Alpha is dropped from the count too")
end

-- (c) the foe swaps its monster out and back: each swap resets that seat's
-- own participation set, so only who is in against the CURRENT foe is paid.
do
  local battle = battleOf({
    mode = "wild",
    seed = 303,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mon({ species = "Alpha", maxHp = 300, atk = 5, spd = 80,
              moves = { move({ id = "tap", power = 5 }) } }),
        mon({ species = "Gamma", maxHp = 300, atk = 90, spd = 80, moves = { thumpMove() } }),
      } } },
      b = { { playerId = "wild", name = "Wild", mons = {
        mon({ species = "Beta", maxHp = 90, atk = 5, spd = 10,
              moves = { move({ id = "tap", power = 5 }) } }),
        mon({ species = "Delta", maxHp = 300, atk = 5, spd = 10,
              moves = { move({ id = "tap", power = 5 }) } }),
      } } },
    },
  })
  drain(battle)
  local events = {}
  -- Alpha is in against Beta.
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  -- Alpha out, Gamma in: Beta's set is now {Alpha, Gamma}.
  battle:submitChoice("p1", { action = "switch", slot = 1 })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  -- Beta out, Delta in: Delta's set resets to whoever is standing -- {Gamma}.
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("wild", { action = "switch", slot = 1 })
  for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  -- Delta out, Beta back: Beta's set resets again to {Gamma} -- Alpha is gone.
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("wild", { action = "switch", slot = 0 })
  for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  for _ = 1, 10 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  end
  local exps = expEvents(events)
  eq(#exps, 1, "the foe-switch reset leaves only one participant")
  eq(exps[1] and exps[1].mon, 1, "...Gamma, party index 1 -- Alpha's earlier turn was reset away")
  eq(exps[1] and exps[1].participants, 1, "...divisor 1")
end

-- (d) coop_wild: the partner's monster fought and then switched to its
-- bench; it is still paid, on its own party index, at its own seat.
do
  local battle = battleOf({
    mode = "coop_wild",
    seed = 404,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mon({ species = "Alpha", maxHp = 300, atk = 90, spd = 80, moves = { thumpMove() } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mon({ species = "Gamma", maxHp = 300, atk = 5, spd = 70,
                moves = { move({ id = "tap", power = 5 }) } }),
          mon({ species = "Zeta", maxHp = 300, atk = 5, spd = 70,
                moves = { move({ id = "tap", power = 5 }) } }) } },
      },
      b = { { playerId = "wild", name = "Wild", mons = {
        mon({ species = "Beta", maxHp = 150, atk = 5, spd = 10,
              moves = { move({ id = "tap", power = 5 }) } }) } } },
    },
  })
  drain(battle)
  local events = {}
  battle:submitChoice("a1", { action = "fight", move = 0 })
  battle:submitChoice("a2", { action = "fight", move = 0 })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  battle:submitChoice("a1", { action = "fight", move = 0 })
  battle:submitChoice("a2", { action = "switch", slot = 1 })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  for _ = 1, 10 do
    if battle:outcome() then break end
    battle:submitChoice("a1", { action = "fight", move = 0 })
    battle:submitChoice("a2", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  end
  local exps = expEvents(events)
  eq(#exps, 3, "three participants: a1's Alpha, a2's benched Gamma, a2's active Zeta")
  eq(exps[1] and exps[1].slot, 0, "a1 (slot 0) first")
  eq(exps[1] and exps[1].mon, 0, "...Alpha, party index 0")
  eq(exps[2] and exps[2].slot, 1, "then a2 (slot 1)'s bench")
  eq(exps[2] and exps[2].mon, 0, "...Gamma, party index 0, though it is not on the field")
  eq(exps[3] and exps[3].slot, 1, "then a2 (slot 1) again")
  eq(exps[3] and exps[3].mon, 1, "...Zeta, party index 1, the one actually standing")
  eq(exps[1] and exps[1].participants, 3, "the divisor is 3 on every one of them")
  eq(exps[2] and exps[2].participants, 3, "...")
  eq(exps[3] and exps[3].participants, 3, "...")
end

-- ------------------------------------------------------------------
-- 12j. round 6 follow-up: the two adversarial orderings, and the
-- counterfactual that pins the mechanism rather than the outcome
-- ------------------------------------------------------------------
--
-- 12i pinned "who fought the monster that fell" as a standing question. These
-- three restate the adversarial drive that actually shook that rule out:
-- (a) a participant that dies in the SAME action as the KO it helped land
-- must not be paid or counted -- `Battle:_faint`'s own comment calls out the
-- bug this guards ("the user was still standing, still flagged, and still in
-- the divisor"); (b) the deferred send-out mark (`fighter.pendingFought`,
-- held from a faint to the choice window that answers it) survives a foe
-- swap on the very turn it is consumed; (c) that same held mark is not
-- inherited by a successor whose OWN owner faults before it ever fields --
-- the counterfactual that proves (b) is really about a monster still
-- standing, not about time alone.

-- (a) an Explosion-style double-KO in coop_wild: a1's move fells the wild
-- mon AND a1 itself. The self-KO'er is dropped from the set before anybody
-- is counted, so the one exp event this knockout funds names only a2, and
-- the divisor is 1 -- not 2, which is what "unpaid but still counted" would
-- have left behind.
do
  local boom = move({ id = "boom", power = 250, accuracy = 255, effect = 7 })
  local battle = battleOf({
    mode = "coop_wild",
    seed = 4242,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mon({ species = "Alpha", maxHp = 200, atk = 200, spd = 90, moves = { boom } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mon({ species = "Gamma", maxHp = 200, atk = 40, spd = 80, moves = { thumpMove() } }) } },
      },
      b = { { playerId = "wild", name = "Wild", mons = {
        mon({ species = "Beta", maxHp = 60, spd = 10, moves = { thumpMove() } }) } } },
    },
  })
  local events = drain(battle)
  battle:submitChoice("a1", { action = "fight", move = 0 })
  battle:submitChoice("a2", { action = "fight", move = 0 })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  for _, e in ipairs(drain(battle)) do events[#events + 1] = e end

  local faints = 0
  for _, e in ipairs(events) do if e.t == "faint" then faints = faints + 1 end end
  eq(faints, 2, "both the wild mon and the self-KO'er faint in this action")
  local exps = expEvents(events)
  eq(#exps, 1, "exactly one exp event -- the exploder funds nothing of its own")
  eq(exps[1] and exps[1].slot, 1, "paid to a2's seat, not a1's")
  eq(exps[1] and exps[1].mon, 0, "a2's own party index")
  eq(exps[1] and exps[1].participants, 1,
     "divisor 1 -- a1 is dropped from the set, not merely left unpaid")
end

-- (b) the replacement mark: a1 KOs b1; on the next turn a switches to a2
-- (still alive -- a1 was never fainted) the same turn b fields b2. Vanilla
-- still marks a1 -- it was standing when b1 fell -- and the send-out's own
-- mark lands on a2 too, so when a2 finishes off b2 both are paid, divisor 2.
do
  local tap = move({ id = "tap", power = 5, accuracy = 255 })
  local battle = battleOf({
    mode = "coop_npc",
    seed = 101,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mon({ species = "Alpha", maxHp = 300, atk = 200, spd = 80, moves = { thumpMove() } }),
        mon({ species = "Gamma", maxHp = 300, atk = 200, spd = 80, moves = { thumpMove() } }),
      } } },
      b = { { playerId = "npc", name = "Rival", mons = {
        mon({ species = "Beta", maxHp = 40, spd = 10, moves = { tap } }),
        mon({ species = "Delta", maxHp = 40, spd = 10, moves = { tap } }),
      } } },
    },
  })
  local events = drain(battle)
  -- turn 1: a1 KOs b1
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("npc", { action = "fight", move = 0 })
  for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  -- turn 2: npc's fallen b1 owes a replacement first -- close the replace
  -- phase (b fields b2) -- THEN p1 files its voluntary switch to a2 on the
  -- turn-2 window that the closed replace phase opens.
  battle:submitChoice("npc", { action = "switch", slot = 1 })
  for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  battle:submitChoice("p1", { action = "switch", slot = 1 })
  for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  -- turn 3+: a2 KOs b2
  for _ = 1, 6 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("npc", { action = "fight", move = 0 })
    for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  end

  local allExp = expEvents(events)
  eq(#allExp, 3, "one event for b1's knockout, two for b2's")
  eq(allExp[1] and allExp[1].participants, 1, "b1's knockout: a1 alone, divisor 1")
  local exps = { allExp[2], allExp[3] }
  eq(exps[1] and exps[1].slot, 0, "both of b2's events sit on the one seat that owns them")
  eq(exps[2] and exps[2].slot, 0, "...")
  eq(exps[1] and exps[1].mon, 0, "party index 0 (Alpha, standing at the first KO)...")
  eq(exps[2] and exps[2].mon, 1, "...then 1 (Gamma, the send-out)")
  eq(exps[1] and exps[1].participants, 2,
     "the deferred mark carried onto the SECOND foe -- divisor 2, not 1")
  eq(exps[2] and exps[2].participants, 2, "...")
end

-- (c) the counterfactual: the held mark's owner faints before its successor
-- ever fields. `_unfield` (RemoveFaintedPlayerMon) reaches `pendingFought`
-- too, so the fallen mon's mark does not survive to inflate the NEXT
-- knockout's divisor -- the successor inherits nothing, because there was
-- no live monster left to have been "standing" when b1 fell.
do
  local slam = move({ id = "slam", power = 250, accuracy = 255, effect = 48 })
  local tap = move({ id = "tap", power = 5, accuracy = 255 })
  local battle = battleOf({
    mode = "coop_npc",
    seed = 77,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mon({ species = "Alpha", maxHp = 300, hp = 5, atk = 200, spd = 80, moves = { slam } }),
        mon({ species = "Gamma", maxHp = 300, atk = 200, spd = 80, moves = { thumpMove() } }),
      } } },
      b = { { playerId = "npc", name = "Rival", mons = {
        mon({ species = "Beta", maxHp = 40, spd = 10, moves = { tap } }),
        mon({ species = "Delta", maxHp = 40, spd = 10, moves = { tap } }),
      } } },
    },
  })
  local events = {}
  for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  -- a1 (5 HP) KOs b1 with a 250-power recoil move and its own recoil finishes
  -- it off in the same action -- exactly 12i(a)'s shape, but here the seat
  -- still has a bench, so it owes a replacement rather than ending the fight.
  for _ = 1, 8 do
    if battle:outcome() then break end
    local snap, replaced = battle:snapshot(), false
    for _, f in ipairs(snap.field) do
      if f.mustReplace then
        local slot = nil
        for i, hp in ipairs(f.party or {}) do
          if (hp or 0) > 0 then slot = i - 1; break end
        end
        if slot then
          battle:submitChoice(f.playerId, { action = "switch", slot = slot })
          replaced = true
        end
      end
    end
    if not replaced then
      battle:submitChoice("p1", { action = "fight", move = 0 })
      battle:submitChoice("npc", { action = "fight", move = 0 })
    end
    for _, e in ipairs(drain(battle)) do events[#events + 1] = e end
  end

  local faintedA1 = false
  for _, e in ipairs(events) do
    if e.t == "faint" and e.slot == 0 and e.text == "Alpha" then faintedA1 = true end
  end
  ok(faintedA1, "the fixture really did self-KO Alpha alongside b1")
  local allExp = expEvents(events)
  -- The first knockout (b1) paid nobody at all: Alpha was the only
  -- participant and it fell in the same action, so no exp event exists for
  -- it -- restated as a positive count rather than an index lookup.
  local firstKoCount = 0
  for _, e in ipairs(allExp) do
    if e.species == "Beta" then firstKoCount = firstKoCount + 1 end
  end
  eq(firstKoCount, 0, "b1's knockout funded no event -- its sole participant self-KO'd")

  -- b2's knockout (Delta) is what the counterfactual is about: Gamma, the
  -- successor Ann fields after Alpha's fall, must NOT inherit a mark from a
  -- monster that never lived to see it sent out.
  local secondKo = {}
  for _, e in ipairs(allExp) do
    if e.species == "Delta" then secondKo[#secondKo + 1] = e end
  end
  eq(#secondKo, 1, "Delta's knockout paid exactly one event -- Gamma alone")
  eq(secondKo[1] and secondKo[1].mon, 1,
     "Gamma, party index 1 -- Alpha's fallen index 0 is not reused or renumbered")
  eq(secondKo[1] and secondKo[1].participants, 1,
     "divisor 1 -- Alpha's held mark did not carry over to Gamma")
end

-- ------------------------------------------------------------------
-- 12i. dead-target retargeting (`_retarget`, `_useMove`'s call site)
-- ------------------------------------------------------------------
--
-- A fight choice always names a living opposing seat at *choice* time
-- (`_normaliseChoice` refuses an empty one). A mid-turn faint is the only way
-- that aim goes stale by the time the action actually runs: in a 2v2, a
-- faster ally can KO the seat a slower ally is aiming at before the slower
-- one's own action resolves. `_retarget` is what that slower action asks
-- instead of fizzling. The rule, restated as the three cases below:
--   (a) whatever is standing in the SAME field position now, even if it is
--       not who was aimed at -- a seat is a field position here;
--   (b) otherwise the nearest living opposing seat by |slot distance|, ties
--       broken toward the lower seat index;
--   (c) otherwise nil, and the action is skipped.
-- Resolved once per action (`_useMove`, before the move runs), so a
-- multi-hit strike puts every hit on the retargeted seat rather than
-- re-rolling per hit. `Effects.isCharge`/`isBide` record `targetSlot` off
-- this same resolved value, not `choice.target`, so a charge's release or a
-- Bide's payload lands where the action actually went.

-- (a) the owner's case: a faster ally's KO empties the seat a slower ally
-- aimed at in the same turn. The slower ally's attack must not fizzle -- it
-- retargets to the nearest living seat and lands there for real damage.
do
  local battle = battleOf({
    mode = "coop_pvp",
    seed = 4242,
    sides = {
      a = {
        { playerId = "fast", name = "Fast",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 200, spd = 90,
                         moves = { move({ id = "bigsmash", power = 150 }) } }) } },
        { playerId = "slow", name = "Slow",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 60, spd = 10,
                         moves = { move({ id = "tap", power = 40 }) } }) } },
      },
      b = {
        { playerId = "foeA", name = "FoeA",
          mons = { mon({ species = "Beta", maxHp = 12, spd = 5 }) } },
        { playerId = "foeB", name = "FoeB",
          mons = { mon({ species = "Delta", maxHp = 200, spd = 4 }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("fast", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("slow", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("foeA", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)

  local koIdx, noFizzle, sawSlowAnim, landed = nil, true, false, false
  for i, e in ipairs(events) do
    if e.t == "faint" and e.text == "Beta" then koIdx = i end
    if e.t == "msg" and e.text and e.text:find("has no target", 1, true) then
      noFizzle = false
    end
    if koIdx and i > koIdx and e.t == "anim" and e.side == "a" and e.slot == 1 then
      sawSlowAnim = true
    end
    if sawSlowAnim and e.t == "damage" and e.side == "b" and e.slot == 4 then
      landed = true
    end
  end
  ok(koIdx ~= nil, "retarget/owner: fast's hit really KO'd the aimed-at seat")
  ok(noFizzle, "retarget/owner: slow's attack never says 'has no target'")
  ok(sawSlowAnim, "retarget/owner: slow's move still plays its anim")
  ok(landed, "retarget/owner: slow's attack lands as real damage on foeB, the retargeted seat")

  local snap = battle:snapshot()
  eq(fighterIn(snap, "foeA").hp, 0, "retarget/owner: foeA (the original aim) stayed at 0 hp")
  eq(fighterIn(snap, "foeB").hp, 182, "retarget/owner: foeB (the retargeted seat) took slow's hit")
end

-- (b) same-position preference: the aimed-at seat is refilled by a
-- *voluntary* switch (not a faint) before the slower action runs. Gen 1
-- switches resolve before fights regardless of speed, so the seat is full
-- again by the time the aim is honoured -- the original aim lands on
-- whoever now stands in that same field position, unchanged.
do
  local battle = battleOf({
    mode = "coop_pvp",
    seed = 4242,
    sides = {
      a = {
        { playerId = "fast", name = "Fast",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 200, spd = 90,
                         moves = { move({ id = "bigsmash", power = 150 }) } }) } },
        { playerId = "slow", name = "Slow",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 60, spd = 10,
                         moves = { move({ id = "tap", power = 40 }) } }) } },
      },
      b = {
        { playerId = "foeA", name = "FoeA",
          mons = { mon({ species = "Beta", maxHp = 200, spd = 5 }),
                   mon({ species = "Epsilon", maxHp = 200, spd = 5 }) } },
        { playerId = "foeB", name = "FoeB",
          mons = { mon({ species = "Delta", maxHp = 200, spd = 4 }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("fast", { action = "fight", move = 0, target = 4 })
  battle:submitChoice("slow", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("foeA", { action = "switch", slot = 1 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)

  local sawSwitch, sawSend, landedOnSlot3 = false, false, false
  for _, e in ipairs(events) do
    if e.t == "switch" and e.side == "b" and e.slot == 3 then sawSwitch = true end
    if e.t == "send" and e.side == "b" and e.slot == 3 and e.text == "Epsilon" then sawSend = true end
    if e.t == "damage" and e.side == "b" and e.slot == 3 then landedOnSlot3 = true end
  end
  ok(sawSwitch and sawSend, "retarget/same-position: foeA's switch really refilled slot 3 first")
  ok(landedOnSlot3, "retarget/same-position: slow's aim at slot 3 still lands there, on the replacement")

  local snap = battle:snapshot()
  eq(fighterIn(snap, "foeA").hp, 182, "retarget/same-position: Epsilon (the replacement) took slow's hit")
  -- 0 since K12 (the high-bits damage roll now knocks Delta out); 6 before.
  -- Either way the hit landed on foeB, the seat fast aimed at.
  eq(fighterIn(snap, "foeB").hp, 0, "retarget/same-position: foeB took fast's original, unretargeted hit")
end

-- (c) both opposing seats are empty when the action runs, but the field
-- still owes replacements (both foes have a bench mon left): the action
-- skips silently -- no target to retarget onto -- and the referee opens the
-- replace phase right after, soliciting exactly the two seats that fell.
do
  local battle = battleOf({
    mode = "coop_pvp",
    seed = 4242,
    sides = {
      a = {
        { playerId = "fast", name = "Fast",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 200, spd = 90,
                         moves = { move({ id = "bigsmash", power = 150 }) } }) } },
        { playerId = "slow", name = "Slow",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 60, spd = 10,
                         moves = { move({ id = "tap", power = 40 }) } }) } },
      },
      b = {
        { playerId = "foeA", name = "FoeA",
          mons = { mon({ species = "Beta", maxHp = 12, spd = 5 }),
                   mon({ species = "Epsilon", maxHp = 200, spd = 5 }) } },
        { playerId = "foeB", name = "FoeB",
          mons = { mon({ species = "Delta", maxHp = 200, spd = 50,
                         moves = { move({ id = "boom", power = 100, effect = 7 }) } }),
                   mon({ species = "Zeta", maxHp = 200, spd = 5 }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("fast", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("slow", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("foeA", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)

  local sawSkipMsg, replaceSlots = false, {}
  for _, e in ipairs(events) do
    if e.t == "msg" and e.text == "Gamma has no target" then sawSkipMsg = true end
    if e.t == "turn" and e.slot ~= nil then replaceSlots[#replaceSlots + 1] = e.slot end
  end
  ok(sawSkipMsg, "retarget/both-empty+bench: slow's action skips with the referee's own line")
  listEq(replaceSlots, { 3, 4 }, "retarget/both-empty+bench: both fallen seats are solicited to replace")
  eq(battle:snapshot().phase, "replace",
     "retarget/both-empty+bench: the referee opened the replace phase, not `over`")
end

-- (d) the same wipe, but neither foe has a bench mon left: the battle ends
-- outright (`over`) before slow's action even runs -- there is no action
-- left to skip, and no replace phase to open.
do
  local battle = battleOf({
    mode = "coop_pvp",
    seed = 4242,
    sides = {
      a = {
        { playerId = "fast", name = "Fast",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 200, spd = 90,
                         moves = { move({ id = "bigsmash", power = 150 }) } }) } },
        { playerId = "slow", name = "Slow",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 60, spd = 10,
                         moves = { move({ id = "tap", power = 40 }) } }) } },
      },
      b = {
        { playerId = "foeA", name = "FoeA",
          mons = { mon({ species = "Beta", maxHp = 12, spd = 5 }) } },
        { playerId = "foeB", name = "FoeB",
          mons = { mon({ species = "Delta", maxHp = 200, spd = 50,
                         moves = { move({ id = "boom", power = 100, effect = 7 }) } }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("fast", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("slow", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("foeA", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)

  local sawSkipMsg, sawOver = false, false
  for _, e in ipairs(events) do
    if e.t == "msg" and e.text and e.text:find("has no target", 1, true) then sawSkipMsg = true end
    if e.t == "over" then sawOver = true end
  end
  ok(not sawSkipMsg,
     "retarget/both-empty+no-bench: no skip line -- the fight is over before slow's action runs")
  ok(sawOver, "retarget/both-empty+no-bench: the battle ends outright")
  eq(battle:snapshot().phase, "over", "retarget/both-empty+no-bench: phase is `over`, not `replace`")
end

-- (e) multi-hit: the redirect is resolved once for the whole action, not
-- once per hit -- every hit of a 2-5-style multi-hit move lands on the same
-- retargeted seat.
do
  local battle = battleOf({
    mode = "coop_pvp",
    seed = 4242,
    sides = {
      a = {
        { playerId = "fast", name = "Fast",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 200, spd = 90,
                         moves = { move({ id = "bigsmash", power = 150 }) } }) } },
        { playerId = "slow", name = "Slow",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 60, spd = 10,
                         moves = { move({ id = "doubletap", power = 40, effect = 44 }) } }) } },
      },
      b = {
        { playerId = "foeA", name = "FoeA",
          mons = { mon({ species = "Beta", maxHp = 12, spd = 5 }) } },
        { playerId = "foeB", name = "FoeB",
          mons = { mon({ species = "Delta", maxHp = 200, spd = 4 }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("fast", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("slow", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("foeA", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)

  local sawSlowAnim, hitsOnSlot4, hitsElsewhere = false, 0, 0
  for _, e in ipairs(events) do
    if e.t == "anim" and e.side == "a" and e.slot == 1 then sawSlowAnim = true end
    if sawSlowAnim and e.t == "damage" and e.side == "b" then
      if e.slot == 4 then hitsOnSlot4 = hitsOnSlot4 + 1 else hitsElsewhere = hitsElsewhere + 1 end
    end
  end
  eq(hitsOnSlot4, 2, "retarget/multi-hit: both hits of the multi-hit move land on the retargeted seat")
  eq(hitsElsewhere, 0, "retarget/multi-hit: no hit strays back onto the original (dead) aim")
  eq(fighterIn(battle:snapshot(), "foeB").hp, 164,
     "retarget/multi-hit: both hits actually subtracted from the survivor's hp")
end

-- (f) a charge move's first turn records the *retargeted* seat, not the
-- original dead aim -- so its automatic release next turn (`_fillForcedChoices`)
-- swings at the seat the charge actually resolved onto.
do
  local battle = battleOf({
    mode = "coop_pvp",
    seed = 5151,
    sides = {
      a = {
        { playerId = "fast", name = "Fast",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 200, spd = 200,
                         moves = { move({ id = "smash", power = 40 }) } }) } },
        { playerId = "charger", name = "Charger",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 90, spd = 10,
                         moves = { move({ id = "solarbeam", power = 60, effect = 39 }) } }) } },
      },
      b = {
        { playerId = "foeA", name = "FoeA",
          mons = { mon({ species = "Beta", maxHp = 12, spd = 5,
                         moves = { move({ id = "tackle", power = 20 }) } }) } },
        { playerId = "foeB", name = "FoeB",
          mons = { mon({ species = "Delta", maxHp = 200, spd = 1,
                         moves = { move({ id = "tackle", power = 20 }) } }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("fast", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("charger", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("foeA", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 0 })
  drain(battle)

  local chargerMon = activeMonOf(battle, "charger")
  ok(chargerMon and chargerMon.charging ~= nil, "retarget/charge: charging state was set")
  eq(chargerMon and chargerMon.charging.targetSlot, 4,
     "retarget/charge: the stored aim is the retargeted seat (4), not the dead original (3)")

  battle:submitChoice("fast", { action = "fight", move = 0, target = 4 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 0 })
  local turn2 = drain(battle)

  local released, landedOnSlot4 = false, false
  for _, e in ipairs(turn2) do
    if e.t == "anim" and e.side == "a" and e.slot == 1 and e.text == "solarbeam" then released = true end
    if released and e.t == "damage" and e.side == "b" and e.slot == 4 then landedOnSlot4 = true end
  end
  ok(released, "retarget/charge: the charge auto-releases next turn")
  ok(landedOnSlot4, "retarget/charge: the release lands on the retargeted seat, not the dead original")
end

-- (g) a Bide's first turn records the retargeted seat the same way; several
-- turns later, its release (2x the stored damage) is paid to that same
-- recorded seat.
do
  local battle = battleOf({
    mode = "coop_pvp",
    seed = 6161,
    sides = {
      a = {
        { playerId = "fast", name = "Fast",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 200, spd = 200,
                         moves = { move({ id = "smash", power = 40 }) } }) } },
        { playerId = "bider", name = "Bider",
          mons = { mon({ species = "Gamma", maxHp = 200, def = 30, spd = 10,
                         moves = { move({ id = "bide", power = 0, effect = 26 }) } }) } },
      },
      b = {
        { playerId = "foeA", name = "FoeA",
          mons = { mon({ species = "Beta", maxHp = 12, spd = 5,
                         moves = { move({ id = "tackle", power = 20 }) } }) } },
        { playerId = "foeB", name = "FoeB",
          mons = { mon({ species = "Delta", maxHp = 400, spd = 1, atk = 60,
                         moves = { move({ id = "tackle", power = 20 }) } }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("fast", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("bider", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("foeA", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 1 })
  drain(battle)

  local biderMon = activeMonOf(battle, "bider")
  ok(biderMon and biderMon.bide ~= nil, "retarget/bide: bide state was set")
  eq(biderMon and biderMon.bide.targetSlot, 4,
     "retarget/bide: the stored aim is the retargeted seat (4), not the dead original (3)")

  local announced, sawReleaseAnim, landedOnSlot4 = false, false, false
  for _ = 1, 6 do
    if landedOnSlot4 then break end
    battle:submitChoice("fast", { action = "fight", move = 0, target = 4 })
    -- The Bide user is a player: its FIGHT, with no move menu behind it, is
    -- the Bide's forced turn (R1d `_menuFight`) -- the aim it names is not
    -- read; the stored one is.
    battle:submitChoice("bider", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("foeB", { action = "fight", move = 0, target = 1 })
    local events = drain(battle)
    for _, e in ipairs(events) do
      if e.t == "msg" and e.text == "Gamma unleashed energy!" then announced = true end
      if e.t == "anim" and e.side == "a" and e.slot == 1 and e.text == "bide" then
        sawReleaseAnim = true
      end
      if sawReleaseAnim and e.t == "damage" and e.side == "b" and e.slot == 4 then
        landedOnSlot4 = true
      end
    end
  end
  ok(announced, "retarget/bide: bide eventually announces its release")
  ok(landedOnSlot4, "retarget/bide: the release damage is paid to the retargeted seat")
end

-- ------------------------------------------------------------------
-- 12k. whom the referee swings at when nobody chose (`_autoTarget`)
-- ------------------------------------------------------------------
--
-- Reported from a real two-player game: "the enemy only attacks my friend and
-- never me, no matter who hosts."  It was not a networking fault and not a
-- seating fault.  Every aim the referee files for itself went through
-- `_firstLivingFoe`, which answers "the lowest-numbered living foe" -- so a
-- coop_wild's wild monster, and *both* seats of a coop_npc trainer, swung at
-- seat 0 on every turn of every fight.  The player sitting in seat 1 was never
-- attacked once, for the whole battle, in either co-op mode.
--
-- ("No matter who hosts" is the part that hid it: seat order is the coop
-- party's member order, and member 1 is whoever *sent the invite* -- nothing
-- to do with who is hosting.  Two friends where the same one always invites
-- get the same seat 0 every time.)

local function aimBattle(mode, seed, foes)
  local sideB = {}
  for i, name in ipairs(foes) do
    sideB[i] = { playerId = "n" .. i, name = name, mons = {
      mon({ species = "Beta", maxHp = 400, spd = 90 }) } }
  end
  return Turn.create({
    id = "aim", mode = mode, seed = seed, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "p1", name = "One", mons = { mon({ species = "Alpha", maxHp = 400, spd = 10 }) } },
        { playerId = "p2", name = "Two", mons = { mon({ species = "Gamma", maxHp = 400, spd = 10 }) } },
      },
      b = sideB,
    },
  }), sideB
end

-- The bug, stated as the fight the player actually played: two humans, an NPC
-- side that answers for itself, and a count of who got hit.
for _, case in ipairs({
  { mode = "coop_wild", foes = { "Wild" } },
  { mode = "coop_npc",  foes = { "NpcA", "NpcB" } },
}) do
  local battle, sideB = aimBattle(case.mode, 4242, case.foes)
  drain(battle)
  local onSlot0, onSlot1 = 0, 0
  for _ = 1, 10 do
    battle:submitChoice("p1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("p2", { action = "fight", move = 0, target = 3 })
    for _, foe in ipairs(sideB) do battle:autoPick(foe.playerId) end
    for _, event in ipairs(drain(battle)) do
      if event.t == "damage" and event.side == "a" then
        if event.slot == 0 then onSlot0 = onSlot0 + 1 else onSlot1 = onSlot1 + 1 end
      end
    end
    if battle.result then break end
  end
  ok(onSlot0 > 0, case.mode .. ": the npc side still attacks the first player")
  ok(onSlot1 > 0, case.mode .. ": and it attacks the second one too (the reported bug)")
end

-- A draw, not a rota: the two seats of a coop_npc turn are free to agree.
do
  local battle, sideB = aimBattle("coop_npc", 4242, { "NpcA", "NpcB" })
  drain(battle)
  local ganged, split = false, false
  for _ = 1, 12 do
    battle:submitChoice("p1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("p2", { action = "fight", move = 0, target = 4 })
    for _, foe in ipairs(sideB) do battle:autoPick(foe.playerId) end
    local hits = {}
    for _, event in ipairs(drain(battle)) do
      if event.t == "damage" and event.side == "a" then hits[#hits + 1] = event.slot end
    end
    if #hits == 2 then
      if hits[1] == hits[2] then ganged = true else split = true end
    end
    if battle.result then break end
  end
  ok(ganged, "coop_npc: some turns both npcs gang up on one player")
  ok(split, "coop_npc: and on others they split -- a draw, not an alternation")
end

-- The half that keeps every recorded vector honest: an aim is drawn from a
-- second generator, so asking for one must not spend a byte of the battle's
-- own.  A draw that leaked onto `rng` would move every roll after it.
do
  local battle = aimBattle("coop_npc", 4242, { "NpcA", "NpcB" })
  drain(battle)
  local before = battle.rng:state()
  local npc = battle.byId["n1"]
  local seen = {}
  for _ = 1, 32 do seen[battle:_autoTarget(npc).slot] = true end
  eq(battle.rng:state(), before, "aim: 32 draws later the battle RNG has not moved")
  ok(seen[0] and seen[1], "aim: and those draws reached both player seats")
end

-- Three foe seats: auto-target must reach every living player seat, not just
-- the lowest-numbered one.
do
  local battle = aimBattle("coop_npc", 4242, { "NpcA", "NpcB", "NpcC" })
  drain(battle)
  local onSlot0, onSlot1 = 0, 0
  for _ = 1, 10 do
    battle:submitChoice("p1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("p2", { action = "fight", move = 0, target = 3 })
    for i = 1, 3 do battle:autoPick("n" .. i) end
    for _, event in ipairs(drain(battle)) do
      if event.t == "damage" and event.side == "a" then
        if event.slot == 0 then onSlot0 = onSlot0 + 1 else onSlot1 = onSlot1 + 1 end
      end
    end
    if battle.result then break end
  end
  ok(onSlot0 > 0, "aim/3foe: npcs still attack the first player")
  ok(onSlot1 > 0, "aim/3foe: and they attack the second one too")
end

-- Three living foes: a slower ally's dead aim retargets to the nearest seat.
do
  local battle = battleOf({
    mode = "coop_pvp",
    seed = 88012,
    sides = {
      a = {
        { playerId = "fast", name = "Fast",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 200, spd = 99,
                         moves = { move({ id = "bigsmash", power = 150 }) } }) } },
        { playerId = "slow", name = "Slow",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 60, spd = 10,
                         moves = { move({ id = "tap", power = 40 }) } }) } },
      },
      b = {
        { playerId = "foeA", name = "FoeA",
          mons = { mon({ species = "Beta", maxHp = 12, spd = 5 }) } },
        { playerId = "foeB", name = "FoeB",
          mons = { mon({ species = "Delta", maxHp = 400, spd = 5 }) } },
        { playerId = "foeC", name = "FoeC",
          mons = { mon({ species = "Zeta", maxHp = 400, spd = 4 }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("fast", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("slow", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("foeA", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("foeC", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)

  local hitSlot4 = false
  for _, e in ipairs(events) do
    if e.t == "damage" and e.side == "b" and e.slot == 4 then hitSlot4 = true end
  end
  ok(hitSlot4, "retarget/3foe: slower ally retargets to foeB at slot 4, the nearest living seat")
end

-- One living foe is answered without a draw at all, which is why every 1v1 and
-- wild fixture in this suite replays byte for byte after aims began to spread.
do
  local battle = battleOf({ seed = 4242 })
  drain(battle)
  local before = battle.aim:state()
  local fighter = battle.byId["p2"]
  for _ = 1, 8 do eq(battle:_autoTarget(fighter).slot, 0, "aim: 1v1 has one answer") end
  eq(battle.aim:state(), before, "aim: and a fight with one foe never touches the aim stream")
end

-- ------------------------------------------------------------------
-- 24. team rosters (PROTOCOL 24)
-- ------------------------------------------------------------------
--
-- The only thing this wire says about a monster nobody has seen, and the only
-- source there is for the seat opposite: no client uploads a party to any other
-- client.  So what is asserted here is not "the field said the right thing" but
-- the two properties a roster chip is built on -- that the count is the party's
-- and that the states follow the fight.

-- The token function, before any battle uses it.
do
  eq(Events.teamToken({ hp = 30 }), "o", "team: a standing monster is `o`")
  eq(Events.teamToken({ hp = 30, status = "PSN" }), "s", "team: a statused one is `s`")
  eq(Events.teamToken({ hp = 0 }), "x", "team: a downed one is `x`")
  -- Fainted beats statused, and it has to: the status field that put a monster
  -- down is still set on it, so asking about the status first would draw a
  -- spent ball as merely poisoned.
  eq(Events.teamToken({ hp = 0, status = "PSN" }), "x",
    "team: down outranks statused on the same monster")
  eq(Events.teamToken(nil), nil, "team: nothing is not a ball")
  eq(Events.teamString({ mon({ hp = 30 }), mon({ hp = 0 }), mon({ hp = 5, status = "BRN" }) }),
    "oxs", "team: the roster is one character per member, in party order")
  eq(#Events.teamString({ mon(), mon(), mon() }), 3,
    "team: and its length is the party size -- there is no empty-slot token")
  eq(Events.teamString(nil), "", "team: no party is no roster")
end

-- The opening: one per seat, behind the send-outs and in front of the window.
do
  local battle = battleOf({
    aMons = { mon(), mon({ species = "Spare" }) },
    bMons = { mon({ species = "Beta" }) },
  })
  local list = drain(battle)
  local order, rosters = {}, {}
  for _, event in ipairs(list) do
    order[#order + 1] = event.t
    if event.t == "team" then rosters[event.slot] = event.team end
  end
  listEq(order, { "send", "send", "team", "team", "turn" },
    "team: the opening rosters land behind the send-outs and ahead of the turn")
  eq(rosters[0], "oo", "team: side a's seat published the two it brought")
  eq(rosters[3], "o", "team: and side b's the one it brought")
end

-- Nothing changed, nothing said.  The diff is what keeps this off a wire that
-- carries it on every window of every fight.
do
  local battle = battleOf()
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local second = kinds(drain(battle))
  eq(second.team, nil,
    "team: a turn that moved no ball state re-publishes nothing")
end

-- A faint darkens the ball inside its own batch, not at the next window: this
-- is the one roster change a player watches happen.
do
  local battle = battleOf({
    aMons = { mon({ hp = 1 }), mon({ species = "Spare" }) },
    bMons = { mon({ species = "Beta", spd = 200, moves = { move({ power = 200 }) } }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local list = drain(battle)
  local faintAt, teamAt, roster
  for i, event in ipairs(list) do
    if event.t == "faint" and not faintAt then faintAt = i end
    if event.t == "team" and event.slot == 0 and not teamAt then
      teamAt, roster = i, event.team
    end
  end
  ok(faintAt ~= nil, "team: the fixture landed the knockout it was built for")
  ok(teamAt ~= nil and faintAt ~= nil and teamAt == faintAt + 1,
    "team: the roster follows the faint line immediately")
  eq(roster, "xo", "team: and the ball that went down is the one that darkened")
end

-- A status is published too -- at the window, because that is when the player
-- who has to act on it is looking.
do
  local battle = battleOf({
    aMons = { mon(), mon({ species = "Spare" }) },
    bMons = { mon({ species = "Beta" }) },
  })
  drain(battle)
  -- Written onto the sheet the referee is fighting with, which is what a
  -- residual or a side-effect would have done; the publisher does not care
  -- which of them did it.
  battle.byId["p1"].mons[1].status = "PSN"
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local published
  for _, event in ipairs(drain(battle)) do
    if event.t == "team" and event.slot == 0 then published = event.team end
  end
  eq(published, "so", "team: a condition on a party member reaches the roster")
end

-- The bench is in it.  A seat that never fields its fourth monster still says
-- it has one -- which is the whole of "how many have they got left".
do
  local battle = battleOf({
    aMons = { mon(), mon({ species = "B" }), mon({ species = "C" }),
              mon({ species = "D" }) },
  })
  local roster
  for _, event in ipairs(drain(battle)) do
    if event.t == "team" and event.slot == 0 then roster = event.team end
  end
  eq(roster, "oooo", "team: the roster counts the bench, not the field")
end

-- ------------------------------------------------------------------
-- 12l. what a move is *called* in a sentence (PROTOCOL 26)
-- ------------------------------------------------------------------
--
-- The referee holds no move table and never will, so before the sheet carried
-- a display name the only spelling of a move on the wire was its registry id
-- -- and every sentence written about one printed that: "Alpha used
-- SLOW_SWIPE", "SLOW_SWIPE is disabled".  The slug reached the one box a
-- player actually reads the fight in.
--
-- Four call sites say a move's name and all four are checked here, because
-- each was its own `.id`: the attack line, both halves of Disable, and
-- Mimic's "learned".  (Disable wearing off names the monster, the cart's
-- DisabledNoMoreText, R1b.)  DISABLE picks its slot at random (R1b,
-- DisableEffect's `BattleRandom & 3`): seed 4243 is one on which it picks
-- THUMP HIT.  The id keeps riding on `anim` -- that is
-- what a client looks the move animation up by -- so the two spellings must
-- never be swapped for each other, which is the last check below.

do
  local swipe = move({ id = "slow_swipe", power = 10 })
  swipe.name = "SLOW SWIPE"
  local lockdown = move({ id = "lock_down", power = 0, effect = 86 })
  lockdown.name = "LOCK DOWN"
  local copycat = move({ id = "copy_cat", power = 0, effect = 82 })
  copycat.name = "COPY CAT"
  local thump = move({ id = "thump", power = 10 })
  thump.name = "THUMP HIT"
  -- No name at all: what a protocol-25 client uploads, and what every move on
  -- a mixed hub's other half still looks like.
  local nudge = move({ id = "nudge", power = 10 })

  -- A fight against the computer (R1c): MimicEffect's pick is the player's
  -- menu there, whose cursor starts on the target's first move -- THUMP HIT.
  -- In a link fight it is `BattleRandom & 3`, and the copy could be `nudge`.
  local battle = battleOf({
    id = "names", seed = 4243, mode = "wild",
    aMons = { mon({ species = "Alpha", maxHp = 400, spd = 90,
                    moves = { swipe, lockdown, copycat } }) },
    bMons = { mon({ species = "Beta", maxHp = 400, spd = 10,
                    moves = { thump, nudge } }) },
  })
  local said, animated = {}, {}
  local function step(aMove, bMove)
    battle:submitChoice("p1", { action = "fight", move = aMove })
    battle:submitChoice("p2", { action = "fight", move = bMove })
    for _, event in ipairs(drain(battle)) do
      if event.t == "msg" then said[#said + 1] = event.text end
      if event.t == "anim" then animated[#animated + 1] = event.text end
    end
  end
  drain(battle)
  step(0, 0)                       -- both swing
  step(1, 0)                       -- Disable lands, then refuses Bob's pick
  step(2, 1)                       -- Mimic copies the disabled move
  for _ = 1, 5 do step(2, 1) end   -- the copy is used; Disable wears off

  local function spoke(line)
    for _, text in ipairs(said) do if text == line then return true end end
    return false
  end

  ok(spoke("Alpha used SLOW SWIPE!"), "an attack prints the move's display name")
  ok(spoke("Beta's THUMP HIT was disabled!"), "Disable landing names the move")
  ok(spoke("Beta's THUMP HIT is disabled!"), "and so does the refusal it causes")
  ok(spoke("Beta's disabled no more!"), "and it wearing off names the monster")
  ok(spoke("Alpha learned THUMP HIT!"), "Mimic names what it copied")
  ok(spoke("Alpha used THUMP HIT!"),
     "and the copy carries the name with it -- a copy that dropped it would "
     .. "revert to the slug on every turn afterwards")

  -- Not a defensive branch: half the sheets on a mixed hub carry no name, and
  -- the fallback is the sentence those fights have always shown.
  ok(spoke("Beta used nudge!"), "a move with no name is narrated under its id")

  local sawId, sawName = false, false
  for _, text in ipairs(animated) do
    if text == "slow_swipe" then sawId = true end
    if text == "SLOW SWIPE" then sawName = true end
  end
  ok(sawId, "the anim row still carries the registry id")
  ok(not sawName, "and never the display name, which no art is filed under")
end

-- ------------------------------------------------------------------
-- 12m. autoPick never leaves a living choice-phase seat owing
-- ------------------------------------------------------------------
--
-- `_autoChoice` used to return nil when the active mon has no moves (and when
-- there is nobody across the field to aim at). Hub then waits out the choice
-- clock and retries the same nil. Solo sets SOLO_CHOICE_TIMEOUT to 0 -- "no
-- deadline at all" -- so the NPC never files, the player has already answered,
-- and the band sits on "Waiting for X..." with RUN refused in a trainer fight.
-- An empty sheet with a living foe is now Struggle; skip is only no-target.

do
  local battle = battleOf({
    choiceTimeout = 0,
    aMons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spd = 80 }) },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 10, moves = {} }) },
  })
  drain(battle)
  eq(battle.turn, 1, "the opening window is turn 1")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "the player files")
  ok(battle:autoPick("p2"), "an empty-moves NPC still files")
  local struggle = false
  for _, event in ipairs(drain(battle)) do
    if event.t == "anim" and event.text == "STRUGGLE" then struggle = true end
  end
  ok(struggle, "the empty sheet Struggles rather than skipping")
  ok(battle.turn >= 2 or battle:outcome() ~= nil,
     "the turn closed rather than sitting on an owed NPC")
end

-- The timeout sweep must file Struggle too, not push the clock on a nil pick.
do
  local battle = battleOf({
    choiceTimeout = 10,
    aMons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spd = 80 }) },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 10, moves = {} }) },
  })
  drain(battle)
  eq(battle.turn, 1, "the opening window is turn 1")
  ok(battle:tick(9) == false, "inside the deadline the sweep does nothing")
  ok(battle:tick(11) == true, "past the deadline the sweep files")
  local struggle = false
  for _, event in ipairs(drain(battle)) do
    if event.t == "anim" and event.text == "STRUGGLE" then struggle = true end
  end
  ok(struggle, "an unanswered empty sheet Struggles rather than pushing the clock")
  ok(battle.turn >= 2 or battle:outcome() ~= nil,
     "the timeout closed the turn instead of waiting another window")
end

-- ------------------------------------------------------------------
-- 12n. a dead side in the choice window ends the fight
-- ------------------------------------------------------------------
--
-- A faint that left the field in `choice` (active cleared, hp 0, no
-- `_checkOver`) used to hang: the player filed FIGHT, `_normaliseChoice`
-- returned nil (no living foe), Solo's clock is 0 so nothing timed out,
-- and the band sat on "Waiting for WILD...". tick() now ends that window,
-- and a FIGHT with nobody to aim at is a skip so the turn can close.

do
  local battle = battleOf({
    choiceTimeout = 0,
    mode = "wild",
    aMons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spd = 80 }) },
    bMons = { mon({ species = "Beta", maxHp = 40, spd = 10 }) },
  })
  drain(battle)
  local foe = battle.byId.p2
  foe.mons[1].hp = 0
  foe.active = nil
  ok(battle:tick(0) == true, "one tick notices the empty side")
  local out = battle:outcome()
  ok(out ~= nil, "and the fight ends rather than waiting for the wild")
  eq(out and out.reason, "ko", "as a knockout")
end

do
  local battle = battleOf({
    choiceTimeout = 0,
    mode = "wild",
    aMons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spd = 80 }) },
    bMons = { mon({ species = "Beta", maxHp = 40, spd = 10 }) },
  })
  drain(battle)
  local foe = battle.byId.p2
  foe.mons[1].hp = 0
  foe.active = nil
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }),
     "FIGHT with nobody to aim at is accepted as a skip")
  ok(battle:outcome() ~= nil, "and the skip closes the fight")
end

-- ------------------------------------------------------------------
-- 25. Gen 1 stored battle stats: the switch-in seed, both glitches, the
--     walls, the resets, crits on party stats, screens, the self-hit
-- ------------------------------------------------------------------
--
-- pokered keeps a battle stat it *writes* (src/BattleSim/Effects.lua's
-- "Stored battle stats" note), and every number below is worked by hand from
-- the routines that write it -- the arithmetic is in the comment beside each
-- assertion.  The g1_* scenarios in tests/drivers/battle_turn_parity.lua hold
-- lib/battle to the same streams and to the same stored stats (`probes`).

do
  local ALL = { BOULDERBADGE = true, THUNDERBADGE = true, SOULBADGE = true,
                VOLCANOBADGE = true }

  local function fxm(id, power, effect, o)
    o = o or {}
    local out = move({ id = id, power = power, effect = effect,
                       type = o.type, chance = o.chance })
    if o.highCrit then out.highCrit = true end
    return out
  end

  -- `a` / `b`: mon() options plus `extra` (raw sheet fields mon() does not
  -- carry: stages, reflect); `aBadges`, `aBag`, `bBag` ride the seats.
  local function g1(o)
    local function sheet(opts)
      local raw = mon(opts)
      for key, value in pairs(opts.extra or {}) do raw[key] = value end
      return raw
    end
    local aMons, bMons = {}, {}
    for i, opts in ipairs(o.a) do aMons[i] = sheet(opts) end
    for i, opts in ipairs(o.b) do bMons[i] = sheet(opts) end
    local battle = battleOf({
      mode = o.mode or "wild", seed = o.seed or 6201,
      specialTypes = o.specialTypes,
      sides = {
        a = { { playerId = "p1", name = "Ann", badges = o.aBadges,
                bag = o.aBag, mons = aMons } },
        b = { { playerId = "p2", name = "Bob", bag = o.bBag, mons = bMons } },
      },
    })
    drain(battle)
    return battle
  end

  local function step(battle, aChoice, bChoice)
    battle:submitChoice("p1", aChoice)
    battle:submitChoice("p2", bChoice)
    return drain(battle)
  end
  local function use(i) return { action = "fight", move = i } end

  local function cur4(battle, playerId)
    local m = activeMonOf(battle, playerId)
    if not m then return "none" end
    return string.format("%d/%d/%d/%d", m.cur.atk, m.cur.def, m.cur.spd, m.cur.spc)
  end
  local function said(events, text)
    for _, event in ipairs(events) do
      if event.t == "msg" and event.text == text then return true end
    end
    return false
  end
  local function hits(events, slot)
    local out = {}
    for _, event in ipairs(events) do
      if event.t == "damage" and event.slot == slot then out[#out + 1] = event.amount end
    end
    return out
  end

  local ANN = { atk = 100, def = 80, spd = 60, spc = 50, maxHp = 300, baseSpd = 0 }
  local function ann(o)
    local out = {}
    for k, v in pairs(ANN) do out[k] = v end
    for k, v in pairs(o or {}) do out[k] = v end
    return out
  end
  local splash = fxm("splash", 0, 85)

  -- (a) The switch-in seed, in LoadBattleMonFromParty's order: party ->
  --     penalty -> badges.  Speed 60 paralysed is 15, then SOULBADGE adds
  --     15>>3 = 1 -> 16; the other three are x9/8: 112, 90, 56.  The foe gets
  --     the penalty and never a badge: Attack 100 burned is 50.
  do
    local battle = g1({ aBadges = ALL,
      a = { ann({ status = "PAR", moves = { splash } }) },
      b = { { species = "Beta", atk = 100, status = "BRN", baseSpd = 0, moves = { splash } } } })
    eq(cur4(battle, "p1"), "112/90/16/56", "seed: party -> paralysis -> badges")
    eq(cur4(battle, "p2"), "50/40/40/40", "seed: the foe is penalised, never boosted")
    local alpha = activeMonOf(battle, "p1")
    eq(alpha.partyStats.spd, 60, "the party stats stay as the sheet stated them")
    eq(alpha.stats.spd, 60, "...and so do the unmodified ones")
    local link = g1({ mode = "1v1", aBadges = ALL,
      a = { ann({ status = "PAR", moves = { splash } }) },
      b = { { species = "Beta", baseSpd = 0, moves = { splash } } } })
    eq(cur4(link, "p1"), "100/80/15/50", "seed in a link fight: the penalty, no badge")
    eq(link:_speedOf(fighterById(link, "p1"), activeMonOf(link, "p1")), 15,
       "turn order reads the stored Speed")
  end

  -- (b) The player's own raise.  ATTACK_UP2: 100 x 200/100 = 200 from the
  --     unmodified stat (badge and stage both dropped), then ApplyBadgeStatBoosts
  --     over all four: 200+25 = 225, 90+11 = 101, 67+8 = 75, 56+7 = 63.  An
  --     accuracy raise runs the badges again: 253, 113, 84, 70.  Each one
  --     re-quarters the paralysed foe: 80 -> 20 at the seed, then 5, then 1.
  do
    local battle = g1({ aBadges = ALL,
      a = { ann({ moves = { fxm("sharpen", 0, 50), fxm("aim", 0, 14) } }) },
      b = { { species = "Beta", spd = 80, status = "PAR", baseSpd = 0, moves = { splash } } } })
    eq(cur4(battle, "p2"), "40/40/20/40", "the paralysed foe starts quartered")
    step(battle, use(0), use(0))
    eq(cur4(battle, "p1"), "225/101/75/63", "badge-stacking: a raise re-runs every badge")
    eq(activeMonOf(battle, "p1").stages.atk, 2, "...over a +2 stage")
    eq(activeMonOf(battle, "p2").cur.spd, 5, "re-penalty: the foe's 20 quartered again")
    step(battle, use(1), use(0))
    eq(cur4(battle, "p1"), "253/113/84/70", "an accuracy raise compounds them again")
    eq(activeMonOf(battle, "p2").cur.spd, 1, "...and re-quarters the foe to its floor of 1")

    -- A link fight: no badge ever, but the re-penalty is unconditional.
    local link = g1({ mode = "1v1", aBadges = ALL,
      a = { ann({ moves = { fxm("sharpen", 0, 50) } }) },
      b = { { species = "Beta", spd = 80, status = "PAR", baseSpd = 0, moves = { splash } } } })
    step(link, use(0), use(0))
    eq(cur4(link, "p1"), "200/80/60/50", "a link fight rebuilds the stat and boosts nothing")
    eq(activeMonOf(link, "p2").cur.spd, 5, "...and still re-penalises the foe")
  end

  -- (c) The enemy's drops on the player.  Burned, the seed Attack is
  --     100/2 = 50 -> 56.  A Growl: 100 x 66/100 = 66 (the burn dropped), all
  --     four badges (74, 101, 75, 63), then the re-penalty on the burned target
  --     itself: 74/2 = 37.  A side-effect Special drop: 50 x 66/100 = 33, the
  --     badges (41, 113, 84, 37), 41/2 = 20.  An accuracy drop: badges only
  --     (22, 127, 94, 41), 22/2 = 11.
  do
    local battle = g1({ aBadges = ALL,
      a = { ann({ status = "BRN", moves = { splash } }) },
      b = { { species = "Beta", spd = 90, baseSpd = 0,
              moves = { fxm("growl", 0, 18), fxm("psyray", 40, 71, { chance = 100 }),
                        fxm("sand", 0, 22) } } } })
    eq(cur4(battle, "p1"), "56/90/67/56", "a burned seed halves, then boosts")
    step(battle, use(0), use(0))
    eq(cur4(battle, "p1"), "37/101/75/63", "the enemy's drop re-runs the badges, then the burn")
    step(battle, use(0), use(1))
    eq(cur4(battle, "p1"), "20/113/84/37", "a side-effect drop does the same")
    step(battle, use(0), use(2))
    eq(cur4(battle, "p1"), "11/127/94/41", "and so does an accuracy drop")

    -- The player's own drop on the enemy re-runs nothing of the player's.
    local mine = g1({ aBadges = ALL,
      a = { ann({ spd = 90, moves = { fxm("growl", 0, 18) } }) },
      b = { { species = "Beta", baseSpd = 0, moves = { splash } } } })
    local before = cur4(mine, "p1")
    step(mine, use(0), use(0))
    eq(cur4(mine, "p1"), before, "the player's drop leaves the player's badges alone")
    eq(activeMonOf(mine, "p2").cur.atk, 26, "the foe's 40 x 66/100 = 26")
  end

  -- (d) An X item is the player's raise: X SPEED 60 x 150/100 = 90, badges
  --     (126, 101, 101, 63); the battler opposite (burned, 80/2 = 40) is
  --     halved again to 20.  At the 999 wall it fails, the stage back where
  --     it was.
  do
    local battle = g1({ aBadges = ALL, aBag = { X_SPEED = 2 },
      a = { ann({ moves = { splash } }) },
      b = { { species = "Beta", atk = 80, status = "BRN", baseSpd = 0, moves = { splash } } } })
    step(battle, { action = "item", item = "X_SPEED" }, use(0))
    eq(cur4(battle, "p1"), "126/101/101/63", "an X item re-runs every badge")
    eq(activeMonOf(battle, "p2").cur.atk, 20, "...and re-penalises the battler opposite")

    local wall = g1({ mode = "1v1", aBag = { X_SPEED = 2 },
      a = { ann({ spd = 700, moves = { splash } }) },
      b = { { species = "Beta", baseSpd = 0, moves = { splash } } } })
    step(wall, { action = "item", item = "X_SPEED" }, use(0))
    eq(activeMonOf(wall, "p1").cur.spd, 999, "700 x 150/100 = 1050 is stored as 999")
    local events = step(wall, { action = "item", item = "X_SPEED" }, use(0))
    ok(said(events, "Nothing happened!"), "an X item on a 999 stat fails")
    eq(activeMonOf(wall, "p1").stages.spd, 1, "...and leaves the stage at +1")
  end

  -- (e) Rage: the raging battler is the user, so its badges re-run and the
  --     attacker is re-penalised.  After the X SPEED above and one Rage build:
  --     Attack 100 x 150/100 = 150 -> 168, the others 113 / 113 / 70; the
  --     burned attacker 20 -> 10.
  do
    local battle = g1({ aBadges = ALL, aBag = { X_SPEED = 1 },
      a = { ann({ maxHp = 400, moves = { fxm("fury", 20, 81) } }) },
      b = { { species = "Beta", maxHp = 400, atk = 80, spd = 50, status = "BRN",
              baseSpd = 0, moves = { fxm("thump", 10, 0) } } } })
    step(battle, { action = "item", item = "X_SPEED" }, use(0))
    step(battle, use(0), use(0))
    eq(cur4(battle, "p1"), "168/113/113/70", "a Rage build re-runs every badge")
    eq(activeMonOf(battle, "p2").cur.atk, 10, "...and re-penalises the attacker")
  end

  -- (f) The walls (link fight, no badges).  +2 on 500: 1000 -> 999.  +2 on
  --     999: "Nothing happened!", the stage wound back ONE step (+2 -> +4 ->
  --     +3).  A drop on a Defense of 1: "Nothing happened!", -1 -> 0; a -2 drop
  --     nets -1.  A side-effect drop at the wall says nothing.
  do
    local battle = g1({ mode = "1v1",
      a = { ann({ atk = 500, spd = 90, moves = { fxm("sharpen", 0, 50),
        fxm("soften", 0, 19), fxm("crush", 0, 59), fxm("nip", 1, 69, { chance = 100 }) } }) },
      b = { { species = "Beta", maxHp = 999, def = 1, baseSpd = 0, moves = { splash } } } })
    step(battle, use(0), use(0))
    eq(activeMonOf(battle, "p1").cur.atk, 999, "a raise past 999 stores 999")
    local events = step(battle, use(0), use(0))
    ok(said(events, "Nothing happened!"), "a raise on a 999 stat fails")
    eq(activeMonOf(battle, "p1").stages.atk, 3, "...and a +2 still nets +1")
    events = step(battle, use(1), use(0))
    ok(said(events, "Nothing happened!"), "a drop on a stat of 1 fails")
    eq(activeMonOf(battle, "p2").stages.def, 0, "...the -1 wound back")
    step(battle, use(2), use(0))
    eq(activeMonOf(battle, "p2").stages.def, -1, "a -2 drop at the wall nets -1")
    events = step(battle, use(3), use(0))
    ok(not said(events, "Nothing happened!"), "a side-effect drop at the wall is silent")
    eq(activeMonOf(battle, "p2").stages.def, -1, "...and moves nothing")
  end

  -- (g) The resets.  A switch-in reloads the party stats and zeroes every
  --     stage (the raised 225 is 112 again); a faint does the same to the
  --     fallen monster; Haze copies the unmodified stats over both battlers,
  --     badges and the foe's paralysis lifted with the stages; and a
  --     Transformed monster switched back in has its own stats back.
  do
    local battle = g1({ aBadges = ALL,
      a = { ann({ moves = { fxm("sharpen", 0, 50), fxm("haze", 0, 25) } }),
            { species = "Gamma", baseSpd = 0, moves = { splash } } },
      b = { { species = "Beta", spd = 80, status = "PAR", baseSpd = 0, moves = { splash } } } })
    step(battle, use(0), use(0))
    step(battle, { action = "switch", slot = 1 }, use(0))
    step(battle, { action = "switch", slot = 0 }, use(0))
    eq(cur4(battle, "p1"), "112/90/67/56", "a switch-in reloads party -> badges")
    eq(activeMonOf(battle, "p1").stages.atk, 0, "...with every stage back at 0")
    step(battle, use(0), use(0))
    step(battle, use(1), use(0))
    eq(cur4(battle, "p1"), "100/80/60/50", "Haze: the unmodified stats, badges lifted")
    eq(cur4(battle, "p2"), "40/40/80/40", "Haze lifts the foe's paralysis penalty too")

    local fell = g1({ mode = "1v1",
      a = { ann({ hp = 1, moves = { fxm("sharpen", 0, 50) } }),
            { species = "Gamma", baseSpd = 0, moves = { splash } } },
      b = { { species = "Beta", atk = 200, spd = 10, baseSpd = 0, moves = { fxm("thump", 40, 0) } } } })
    step(fell, use(0), use(0))
    local fallen = fighterById(fell, "p1").mons[1]
    eq(fallen.hp, 0, "the raised monster fell")
    eq(fallen.stages.atk, 0, "a faint zeroes its stages")
    eq(fallen.cur.atk, 100, "...and reloads its battle stats from the party")

    local mimic = g1({ mode = "1v1",
      a = { ann({ atk = 30, spd = 90, moves = { fxm("mimicry", 0, 57) } }),
            { species = "Gamma", baseSpd = 0, moves = { splash } } },
      b = { { species = "Beta", atk = 200, baseSpd = 0, moves = { splash } } } })
    step(mimic, use(0), use(0))
    local alpha = activeMonOf(mimic, "p1")
    eq(alpha.cur.atk, 200, "Transform copies the battle stats")
    eq(alpha.stats.atk, 200, "...and the unmodified ones")
    eq(alpha.partyStats.atk, 30, "...and never the party struct")
    step(mimic, { action = "switch", slot = 1 }, use(0))
    step(mimic, { action = "switch", slot = 0 }, use(0))
    eq(activeMonOf(mimic, "p1").stats.atk, 30, "switched back in, its own stats return")
  end

  -- (h) A critical hit reads both party stats.  The same seed, the same draws:
  --     a raised (+2), badged, burned Attack into a Reflect deals exactly what
  --     a plain 100 into a plain 100 deals -- and at level 20 that is the
  --     crit base 18 x 70 x 100 / 100 / 50 + 2 = 27, x1.5 STAB = 40, rolled
  --     into 34..40.
  do
    local function critHit(dressed)
      local battle = g1({ seed = 6202, aBadges = dressed and ALL or nil,
        a = { ann({ baseSpd = 255, status = dressed and "BRN" or nil,
                    extra = dressed and { stages = { atk = 2 } } or nil,
                    moves = { fxm("slash", 70, 0, { highCrit = true }) } }) },
        b = { { species = "Beta", maxHp = 400, def = 100, spd = 30, baseSpd = 0,
                extra = dressed and { reflect = true } or nil, moves = { splash } } } })
      local events = step(battle, use(0), use(0))
      return said(events, "Critical hit!"), hits(events, 3)[1]
    end
    local critA, dealtA = critHit(true)
    local critB, dealtB = critHit(false)
    ok(critA and critB, "base Speed 255 with a high-crit move crits")
    eq(dealtA, dealtB, "a crit ignores the stage, the badges, the burn and the Reflect")
    ok(dealtA >= 34 and dealtA <= 40, "...and lands in the party-stat band 34..40")

    -- Transform + crit: the transformed monster swings with its own 30, not
    -- the copied 200 -- a crit base of 18 x 70 x 30 / 100 / 50 + 2 = 9, x1.5
    -- = 13 at most, where 200 would be 52 x 1.5 = 78.
    local mimic = g1({ mode = "1v1", seed = 6107,
      a = { ann({ atk = 30, def = 30, spd = 90, spc = 30, maxHp = 400, baseSpd = 255,
                  moves = { fxm("mimicry", 0, 57) } }) },
      b = { { species = "Beta", maxHp = 400, atk = 200, def = 100, spd = 40, spc = 100,
              baseSpd = 255, moves = { fxm("slash", 70, 0, { highCrit = true }) } } } })
    step(mimic, use(0), use(0))
    local events = step(mimic, use(0), use(0))
    local onBob = hits(events, 3)[1]
    ok(onBob ~= nil and onBob <= 13, "a transformed crit reads its pre-Transform Attack")
  end

  -- (i) Screens double the defence before the scaling.  512 x2 = 1024 ->
  --     1024/4 = 256, whose low byte 0 divides as 1: level 20, 10 power, 25
  --     Attack: 10 x 10 x 25 / 1 / 50 + 2 = 52, x1.5 = 78, rolled 66..78 --
  --     where the unscreened 512 (128 scaled) is 2, x1.5 = 3.  A second Reflect
  --     fails, a fixed 20 is still 20, Haze takes both screens down.
  do
    local battle = g1({ mode = "1v1", seed = 6109,
      a = { ann({ maxHp = 900, def = 512, spd = 90,
                  moves = { fxm("wall", 0, 65), fxm("glow", 0, 64), splash } }) },
      b = { { species = "Beta", maxHp = 400, atk = 100, spd = 30, baseSpd = 0,
              moves = { fxm("thump", 10, 0), fxm("sonic", 20, 41), fxm("haze", 0, 25) } } } })
    local dealt = hits(step(battle, use(0), use(0)), 0)[1]
    ok(dealt and dealt >= 66 and dealt <= 78, "a Reflect that wraps the byte hits harder")
    local events = step(battle, use(0), use(1))
    ok(said(events, "But, it failed!"), "a second Reflect fails")
    eq(hits(events, 0)[1], 20, "a fixed-damage move ignores the Reflect")
    step(battle, use(1), use(2))
    local alpha = activeMonOf(battle, "p1")
    ok(not alpha.reflect and not alpha.lightScreen, "Haze takes both screens down")
    dealt = hits(step(battle, use(2), use(0)), 0)[1]
    ok(dealt and dealt <= 3, "unscreened, 512 (128 scaled) is a 3 at most")
  end

  -- (j) The confusion self-hit, 40 power at level 20 with no roll: 160 into
  --     its own 9 is 10 x 40 x 160 / 9 / 50 + 2 = 144; into 9 x2 -- the
  --     OPPONENT's Reflect -- 10 x 40 x 160 / 18 / 50 + 2 = 73.  Its own
  --     Reflect does nothing.
  do
    local function selfHits(aExtra, bExtra)
      local battle = g1({ mode = "1v1", seed = 6111,
        a = { ann({ maxHp = 900, atk = 160, def = 9, spd = 30, confusion = 6,
                    extra = aExtra, moves = { splash } }) },
        b = { { species = "Beta", maxHp = 400, spd = 90, baseSpd = 0, extra = bExtra,
                moves = { splash } } } })
      local out = {}
      for _ = 1, 5 do
        for _, amount in ipairs(hits(step(battle, use(0), use(0)), 0)) do
          out[#out + 1] = amount
        end
      end
      return table.concat(out, ",")
    end
    local theirs = selfHits(nil, { reflect = true })
    ok(theirs ~= "", "the confused monster hurt itself")
    ok(not theirs:find("[^73,]"), "the opponent's Reflect doubles its Defense: 73 a hit")
    local own = selfHits({ reflect = true }, nil)
    ok(own ~= "" and not own:find("[^14,]") and own:find("144", 1, true),
       "its own Reflect does not: 144 a hit")
  end

  -- (k) MainInBattleLoop clears a flinch at the turn's open: a slower Stomp
  --     that lands on a monster that already moved costs it nothing.
  do
    local battle = g1({ mode = "1v1",
      a = { ann({ maxHp = 400, spd = 90, moves = { fxm("thump", 10, 0) } }) },
      b = { { species = "Beta", maxHp = 400, spd = 30, baseSpd = 0,
              moves = { fxm("stomp", 10, 31, { chance = 100 }) } } } })
    local flinched = false
    for _ = 1, 3 do
      if said(step(battle, use(0), use(0)), "Alpha flinched!") then flinched = true end
    end
    ok(not flinched, "a stale flinch dies at the next turn's open")
  end

  -- (l) Curing the player's fielded monster rewrites its battle stats from the
  --     party (ItemUseMedicine): the paralysis and every badge go, 60 Speed and
  --     a bare 100 Attack.  A Full Restore that also healed takes the HP
  --     branch and leaves the stats as they were; at full HP it is a Full
  --     Heal.  The computer's cure never touches a stat.
  do
    local function cured(item, hp, mode, side)
      local battle = g1({ mode = mode or "wild", aBadges = ALL,
        aBag = { [item] = 1 }, bBag = { [item] = 1 },
        a = { ann({ status = side == "b" and nil or "PAR", hp = hp, moves = { splash } }) },
        b = { { species = "Beta", spd = 80, status = side == "b" and "PAR" or nil,
                baseSpd = 0, moves = { splash } } } })
      if side == "b" then
        step(battle, use(0), { action = "item", item = item })
        return activeMonOf(battle, "p2")
      end
      step(battle, { action = "item", item = item }, use(0))
      return activeMonOf(battle, "p1")
    end
    local healed = cured("PARLYZ_HEAL")
    eq(healed.status, nil, "Parlyz Heal cures")
    eq(string.format("%d/%d", healed.cur.atk, healed.cur.spd), "100/60",
       "...and copies the party stats over the battle ones")
    local restored = cured("FULL_RESTORE", 100)
    eq(restored.status, nil, "a Full Restore that heals cures too")
    eq(restored.cur.spd, 16, "...but leaves the stored penalty")
    local full = cured("FULL_RESTORE", nil)
    eq(full.cur.spd, 60, "at full HP a Full Restore is a Full Heal")
    local npc = cured("PARLYZ_HEAL", nil, "coop_npc", "b")
    eq(npc.status, nil, "the computer cures its own monster")
    eq(npc.cur.spd, 20, "...and AICureStatus leaves the quartered Speed")
  end

  -- (m) A vitamin on the fielded monster rebuilds its battle stats the way a
  --     level-up does: PROTEIN at level 100 is +12 (floor(sqrt(2560)/4) = 12),
  --     so 112 party -> 112 unmodified -> x9/8 = 126.
  do
    local battle = g1({ aBadges = ALL, aBag = { PROTEIN = 1 },
      a = { ann({ level = 100, moves = { splash } }) },
      b = { { species = "Beta", baseSpd = 0, moves = { splash } } } })
    step(battle, { action = "item", item = "PROTEIN" }, use(0))
    local alpha = activeMonOf(battle, "p1")
    eq(alpha.partyStats.atk, 112, "PROTEIN raises the party Attack")
    eq(alpha.cur.atk, 126, "...and the fielded battle stat is rebuilt through the badges")
  end
end

-- ------------------------------------------------------------------
-- 26. Gen 1 priority, obedience, the called-move path, the flinch-reset skip
-- ------------------------------------------------------------------
--
-- docs/plans/gen12-referee-fidelity.md §1 items 6-8 (task G1b).  The
-- obedience branches are forced rather than found: `script` hands the
-- battle's generator the BattleRandom bytes CheckForDisobedience reads, in
-- order, and then falls back to a seeded generator for everything after.
-- Beside each script is the cart's arithmetic for it (pokered core.asm
-- :3830-4007; Status' obedience section; the vector pack's `obedience`
-- notes): with no badge the cap is 10, so a level-100 monster has b = 110
-- for the first two rolls and b = 90 for the third.  The g1_priority* /
-- g1_obey_* / g1_flinch_* parity scenarios hold lib/battle to the same
-- streams on real seeds.

do
  local Rng = BattleSim.Rng

  local function script(battle, bytes)
    local fallback = Rng.new(99)
    local used = 0
    battle.rng = {
      byte = function()
        used = used + 1
        if bytes[used] ~= nil then return bytes[used] end
        return fallback:byte()
      end,
      nextInt = function(_, lo, hi) return fallback:nextInt(lo, hi) end,
      damageRoll = function() return fallback:damageRoll() end,
      next = function() return fallback:next() end,
      state = function() return fallback:state() end,
    }
  end

  -- A sheet names its moves (PROTOCOL 26), and Wire's text filter drops an
  -- underscore, so an id that has one gets the display name a client sends.
  local function fxm(id, power, effect, o)
    o = o or {}
    local out = move({ id = id, power = power, effect = effect, pp = o.pp,
                       chance = o.chance })
    if id:find("_", 1, true) then out.name = id:gsub("_", " ") end
    return out
  end

  -- `a` / `b`: mon() options plus `traded` and `extra` (raw sheet fields
  -- mon() does not carry); `badges` ride side a's seat.
  local function arena(o)
    local function sheet(opts)
      local raw = mon(opts)
      if opts.traded then raw.traded = true end
      for key, value in pairs(opts.extra or {}) do raw[key] = value end
      return raw
    end
    local aMons, bMons = {}, {}
    for i, opts in ipairs(o.a) do aMons[i] = sheet(opts) end
    for i, opts in ipairs(o.b) do bMons[i] = sheet(opts) end
    local battle = battleOf({
      mode = o.mode or "wild", seed = o.seed or 6401, metronomePool = o.pool,
      sides = {
        a = { { playerId = "p1", name = "Ann", badges = o.badges, mons = aMons } },
        b = { { playerId = "p2", name = "Bob", mons = bMons } },
      },
    })
    drain(battle)
    return battle
  end

  local function step(battle, aChoice, bChoice)
    battle:submitChoice("p1", aChoice)
    battle:submitChoice("p2", bChoice)
    return drain(battle)
  end
  local function use(i) return { action = "fight", move = i } end
  local function said(events, text)
    for _, event in ipairs(events) do
      if event.t == "msg" and event.text == text then return true end
    end
    return false
  end
  -- Who acted, in order: the slots of the turn's `anim` events.
  local function order(events)
    local out = {}
    for _, event in ipairs(events) do
      if event.t == "anim" then out[#out + 1] = event.slot .. ":" .. event.text end
    end
    return table.concat(out, " ")
  end
  local function hits(events, slot)
    local out = {}
    for _, event in ipairs(events) do
      if event.t == "damage" and event.slot == slot then out[#out + 1] = event.amount end
    end
    return out
  end

  local splash = function() return fxm("splash", 0, 85) end
  -- The traded level-100 monster every obedience case starts from: faster
  -- than Bob, so its rolls are the turn's first draws.
  local function rogue(o)
    local out = { species = "Alpha", level = 100, maxHp = 999, atk = 30, def = 60,
                  spd = 90, traded = true, baseSpd = 0,
                  moves = { fxm("thump", 10, 0), fxm("chop", 10, 0), splash() } }
    for k, v in pairs(o or {}) do out[k] = v end
    return out
  end
  local function bob(o)
    local out = { species = "Beta", maxHp = 999, spd = 30, baseSpd = 0, moves = { splash() } }
    for k, v in pairs(o or {}) do out[k] = v end
    return out
  end

  -- (a) Priority.  Quick Attack +1 beats Speed, Counter -1 loses to it, the
  --     same move on both sides is Speed's, and a Metronome that calls Quick
  --     Attack sits in bracket 0 -- as does Struggle, even off a Quick Attack
  --     slot.  The link fight and the computer fight order alike.
  do
    for _, mode in ipairs({ "1v1", "wild" }) do
      local kit = function() return { fxm("QUICK_ATTACK", 10, 0), fxm("thump", 10, 0),
                                       fxm("COUNTER", 10, 0) } end
      local battle = arena({ mode = mode,
        a = { { species = "Alpha", maxHp = 400, spd = 30, baseSpd = 0, moves = kit() } },
        b = { { species = "Beta", maxHp = 400, spd = 90, baseSpd = 0, moves = kit() } } })
      eq(order(step(battle, use(0), use(1))), "0:QUICK_ATTACK 3:thump",
         mode .. ": the slower Quick Attack moves first")
      eq(order(step(battle, use(0), use(0))), "3:QUICK_ATTACK 0:QUICK_ATTACK",
         mode .. ": Quick Attack on both sides is Speed's")
      eq(order(step(battle, use(1), use(2))), "0:thump 3:COUNTER",
         mode .. ": the faster Counter moves last")
      eq(order(step(battle, use(2), use(2))), "3:COUNTER 0:COUNTER",
         mode .. ": Counter on both sides is Speed's")
    end

    local metro = arena({ pool = { fxm("QUICK_ATTACK", 10, 0) },
      a = { { species = "Alpha", maxHp = 400, spd = 30, baseSpd = 0,
              moves = { fxm("metronome", 0, 83) } } },
      b = { { species = "Beta", maxHp = 400, spd = 90, baseSpd = 0,
              moves = { fxm("thump", 10, 0) } } } })
    eq(order(step(metro, use(0), use(0))), "3:thump 0:metronome 0:QUICK_ATTACK",
       "a Metronome that calls Quick Attack moves at Metronome's bracket")

    local spent = arena({
      a = { { species = "Alpha", maxHp = 400, spd = 30, baseSpd = 0,
              moves = { fxm("QUICK_ATTACK", 10, 0, { pp = 0 }) } } },
      b = { { species = "Beta", maxHp = 400, spd = 90, baseSpd = 0,
              moves = { fxm("thump", 10, 0) } } } })
    eq(order(step(spent, use(0), use(0))), "3:thump 0:STRUGGLE",
       "Struggle off an empty Quick Attack slot has no priority")

    -- Different brackets never share a tie byte: at equal Speed, side b's
    -- Quick Attack goes first on every seed (a tie group would put side a
    -- first on half of them).
    local always = true
    for seed = 1, 40 do
      local tied = arena({ mode = "1v1", seed = seed,
        a = { { species = "Alpha", maxHp = 400, spd = 50, baseSpd = 0,
                moves = { fxm("thump", 10, 0) } } },
        b = { { species = "Beta", maxHp = 400, spd = 50, baseSpd = 0,
                moves = { fxm("QUICK_ATTACK", 10, 0) } } } })
      if order(step(tied, use(0), use(0))) ~= "3:QUICK_ATTACK 0:thump" then always = false end
    end
    ok(always, "a Quick Attack at equal Speed wins without a coin flip")
  end

  -- (b) Who obeys without a roll.  A roller draws at least one byte and
  --     shifts every roll after it, so a battle that does not roll plays out
  --     exactly -- events and generator state -- as the same battle with the
  --     monster untraded.
  do
    local function same(label, o)
      local function run(traded)
        local a = {}
        for i, opts in ipairs(o.a) do
          local copy = {}
          for k, v in pairs(opts) do copy[k] = v end
          if i == 1 and o.side ~= "b" then copy.traded = traded end
          a[i] = copy
        end
        local b = {}
        for i, opts in ipairs(o.b) do
          local copy = {}
          for k, v in pairs(opts) do copy[k] = v end
          if i == 1 and o.side == "b" then copy.traded = traded end
          b[i] = copy
        end
        local battle = arena({ mode = o.mode, badges = o.badges, seed = 6402, a = a, b = b })
        local events = step(battle, use(0), use(0))
        return dumpAll(events) .. "#" .. battle.rng:state()
      end
      eq(run(true), run(false), label)
    end
    same("level 10 under no badge (cap 10) obeys without a draw",
      { a = { rogue({ level = 10 }) }, b = { bob() } })
    same("CASCADEBADGE's cap 30 covers level 30",
      { badges = { CASCADEBADGE = true }, a = { rogue({ level = 30 }) }, b = { bob() } })
    same("EARTHBADGE's cap 101 covers level 100",
      { badges = { EARTHBADGE = true }, a = { rogue() }, b = { bob() } })
    same("a link fight never checks",
      { mode = "1v1", a = { rogue() }, b = { bob() } })
    same("coop_pvp never checks",
      { mode = "coop_pvp", a = { rogue() }, b = { bob() } })
    same("side b never checks",
      { side = "b", a = { rogue({ traded = false }) }, b = { bob({ level = 100 }) } })
    same("a thrash's continuation never checks",
      { a = { rogue({ extra = { thrashing = { turns = 2, moveIndex = 1 } } }) }, b = { bob() } })
    same("a Rage's continuation never checks",
      { a = { rogue({ moves = { fxm("fury", 10, 81) },
                      extra = { raging = true, rageMove = 1 } }) }, b = { bob() } })
    same("a charge's release never checks",
      { a = { rogue({ moves = { fxm("glow", 10, 39) },
                      extra = { charging = { moveIndex = 1, effect = 39, targetSlot = 3 } } }) },
        b = { bob() } })
    same("a Bide's release never checks",
      { a = { rogue({ moves = { fxm("bide", 0, 26) },
                      extra = { bide = { turns = 0, stored = 5, moveIndex = 1, targetSlot = 3 } } }) },
        b = { bob() } })
  end

  -- (c) The first roll passes (swap(0x20) = 2 < 10): the chosen move, as
  --     chosen.
  do
    local battle = arena({ a = { rogue() }, b = { bob() } })
    script(battle, { 0x20 })
    local events = step(battle, use(0), use(0))
    ok(said(events, "Alpha used thump!"), "an R1 pass uses the chosen move")
    eq(activeMonOf(battle, "p1").moves[1].pp, 19, "...and pays for it")
  end

  -- (d) `.useRandomMove`: R1 swap(0x05) = 80 (< 110, not < 10), R2 0x02 < 10.
  --     `.chooseMove` redraws 0 (the chosen slot) and takes 1 (chop).  The
  --     line is the cart's "used instead,"; the PP comes off the CHOSEN slot
  --     (DecrementPP reads wPlayerMoveListIndex); the move used is the one a
  --     Mirror Move would copy.
  do
    local battle = arena({ a = { rogue() }, b = { bob() } })
    script(battle, { 0x05, 0x02, 0x00, 0x01 })
    local events = step(battle, use(0), use(0))
    ok(said(events, "Alpha used instead, chop!"), "a random move says \"used instead,\"")
    eq(order(events), "0:chop 3:splash", "...and is the move animated")
    local alpha = activeMonOf(battle, "p1")
    eq(alpha.moves[1].pp, 19, "the chosen slot pays the PP")
    eq(alpha.moves[2].pp, 20, "...the move used does not")
    eq(alpha.lastMoveIndex, 2, "...and is the last move used")

    -- A disobedient monster moves at the bracket of the move it was told to
    -- use: a chosen Quick Attack still goes first, whatever it uses instead.
    local quick = arena({
      a = { rogue({ spd = 10, moves = { fxm("QUICK_ATTACK", 10, 0), fxm("thump", 10, 0) } }) },
      b = { bob() } })
    script(quick, { 0x05, 0x02, 0x01 })
    eq(order(step(quick, use(0), use(0))), "0:thump 3:splash",
       "the chosen Quick Attack's bracket moves the move used instead")
  end

  -- (e) Every `.useRandomMove` refusal falls to `.monDoesNothing` without a
  --     `.chooseMove` draw: the third byte, 0x02, is read as the loaf line
  --     (2 & 3 = turned away) and nothing is spent.
  do
    local function refused(label, moves, extra)
      local battle = arena({ a = { rogue({ moves = moves, extra = extra }) }, b = { bob() } })
      script(battle, { 0x05, 0x02, 0x02 })
      local events = step(battle, use(0), use(0))
      ok(said(events, "Alpha turned away!"), label .. ": loafs instead")
      eq(order(events), "3:splash", label .. ": ...and uses nothing")
      eq(activeMonOf(battle, "p1").moves[1].pp, moves[1].pp, label .. ": ...or any PP")
    end
    refused("one move known", { fxm("thump", 10, 0) })
    refused("a move disabled", { fxm("thump", 10, 0), fxm("chop", 10, 0) },
      { disable = { moveIndex = 2, turns = 3 } })
    refused("Struggle", { fxm("thump", 10, 0, { pp = 0 }), fxm("chop", 10, 0, { pp = 0 }) })
    refused("no PP outside the chosen slot", { fxm("thump", 10, 0), fxm("chop", 10, 0, { pp = 0 }) })
  end

  -- (f) `.monNaps`: R3 swap(0x24) = 66 < b = 90.  The nap draw 0x18 is
  --     swap(0x30) & 7 = 3 turns, written over the whole status: a paralysis
  --     (whose gate passed on 200) is gone but its quartered Speed stays in
  --     the battle stat; a burn's halved Attack likewise.
  do
    local par = arena({ a = { rogue({ spd = 200, status = "PAR" }) }, b = { bob() } })
    eq(activeMonOf(par, "p1").cur.spd, 50, "the paralysis seeds a quartered Speed")
    script(par, { 200, 0x05, 0x02 * 25, 0x24, 0x18 })
    local events = step(par, use(0), use(0))
    ok(said(events, "Alpha began to nap!"), "the nap is announced")
    local napped = nil
    for _, event in ipairs(events) do
      if event.t == "status" and event.slot == 0 then napped = event end
    end
    eq(napped and napped.status, "SLP", "...with the status event's sleep token")
    local alpha = activeMonOf(par, "p1")
    eq(alpha.status, "sleep", "the nap overwrites the paralysis")
    eq(alpha.statusTurns, 3, "...for swap(0x30) & 7 = 3 turns")
    eq(alpha.cur.spd, 50, "...and leaves the stored Speed quartered")

    local brn = arena({ a = { rogue({ status = "BRN" }) }, b = { bob() } })
    script(brn, { 0x05, 50, 0x24, 0x18 })
    step(brn, use(0), use(0))
    local burned = activeMonOf(brn, "p1")
    eq(burned.status, "sleep", "the nap overwrites a burn")
    eq(burned.cur.atk, 15, "...and the halved Attack stays stored")

    -- Asleep, it rolls nothing: the sleep gate stops it first.
    local events2 = step(brn, use(0), use(0))
    ok(said(events2, "Alpha is fast asleep!"), "the next turn is asleep, not disobedient")
  end

  -- (g) "won't obey!" and HandleSelfConfusionDamage: R3 swap(0xA5) = 90, not
  --     below 90 and 90 - 90 < 90.  Level 100, 30 Attack into the 60 Defense
  --     the FOE's Reflect doubles: 42 x 40 x 30 / 120 / 50 + 2 = 10 (18
  --     without the Reflect, 42 x 40 x 30 / 60 / 50 + 2).
  do
    local function selfHit(reflect)
      local battle = arena({ a = { rogue() },
        b = { bob({ extra = reflect and { reflect = true } or nil }) } })
      script(battle, { 0x05, 50, 0xA5 })
      local events = step(battle, use(0), use(0))
      ok(said(events, "Alpha won't obey!") and said(events, "It hurt itself in its confusion!"),
         "won't obey, then the self-hit")
      return hits(events, 0)[1]
    end
    eq(selfHit(true), 10, "the foe's Reflect doubles the self-hit's Defense")
    eq(selfHit(false), 18, "...and without it the hit is 18")

    -- Behind its own doll the same 18 lands on the FOE's doll:
    -- HandleSelfConfusionDamage ends on ApplyDamageToPlayerPokemon, and its
    -- Substitute branch's AttackSubstitute picks the doll by hWhoseTurn --
    -- the other side's (core.asm :3714, :4849-4856).  CheckForDisobedience
    -- calls it without `.IsConfused`'s BattleStatus1 clear.
    local battle = arena({ a = { rogue({ extra = { substitute = 25 } }) },
      b = { bob({ extra = { substitute = 30 } }) } })
    script(battle, { 0x05, 50, 0xA5 })
    local events = step(battle, use(0), use(0))
    ok(said(events, "It hurt itself in its confusion!"), "behind a doll: still the self-hit line")
    eq(#hits(events, 0), 0, "...but Alpha takes nothing")
    eq(hits(events, 3)[1], 18, "...Bob's doll takes the 18")
    eq(activeMonOf(battle, "p2").substitute, 12, "...and stands at 12")
    eq(activeMonOf(battle, "p1").substitute, 25, "Alpha's own doll is untouched")
    eq(battle.lastDamage, 18, "wDamage holds the self-hit's 18")
  end

  -- (h) `.monDoesNothing`'s four lines: R3 swap(0x4B) = 180, 180 - 90 >= 90;
  --     then R & 3.
  do
    for _, case in ipairs({
      { 0x00, "Alpha is loafing around." }, { 0x05, "Alpha won't obey!" },
      { 0xFE, "Alpha turned away!" }, { 0x0B, "Alpha ignored orders!" },
    }) do
      local battle = arena({ a = { rogue() }, b = { bob() } })
      script(battle, { 0x05, 50, 0x4B, case[1] })
      local events = step(battle, use(0), use(0))
      ok(said(events, case[2]), "loaf line: " .. case[2])
      eq(#hits(events, 0), 0, "...and nobody is hurt: " .. case[2])
    end
  end

  -- (i) wMonIsDisobedient through a call: a Metronome picked instead keeps
  --     the flag, so its call says "used instead," too; a Mirror Move picked
  --     instead clears it (MirrorMoveCheck's `xor a`), so the copy is plain.
  do
    local metro = arena({ pool = { fxm("chop", 10, 0) },
      a = { rogue({ moves = { fxm("thump", 10, 0), fxm("metronome", 0, 83) } }) },
      b = { bob() } })
    script(metro, { 0x05, 0x02, 0x01 })
    local events = step(metro, use(0), use(0))
    ok(said(events, "Alpha used instead, metronome!")
       and said(events, "Alpha used instead, chop!"),
       "a Metronome picked instead calls its move \"instead\" too")
    eq(activeMonOf(metro, "p1").moves[1].pp, 19, "...and the chosen slot pays")

    local mirror = arena({
      a = { rogue({ moves = { fxm("thump", 10, 0), fxm("mirror", 0, 9) } }) },
      b = { bob() } })
    script(mirror, { 0x20 })
    step(mirror, use(0), use(0))
    script(mirror, { 0x05, 0x02, 0x01 })
    events = step(mirror, use(0), use(0))
    ok(said(events, "Alpha used instead, mirror!") and said(events, "Alpha used splash!"),
       "a Mirror Move picked instead copies plainly")
  end

  -- (j) The called move: Struggle only when the move IS Struggle.  A
  --     Metronome or a Mirror Move that spends the last PP takes no recoil;
  --     the Struggle that follows does.  And the call runs no gate: a
  --     confused caller's counter ticks once (6 -> 5), not twice.
  do
    local metro = arena({ pool = { fxm("thump", 10, 0) },
      a = { { species = "Alpha", maxHp = 400, spd = 90, baseSpd = 0,
              moves = { fxm("metronome", 0, 83, { pp = 1 }) } } },
      b = { bob() } })
    local events = step(metro, use(0), use(0))
    ok(said(events, "Alpha used thump!"), "the last PP calls a move")
    ok(not said(events, "Alpha's hit with recoil!"), "...which takes no Struggle recoil")
    events = step(metro, use(0), use(0))
    ok(said(events, "Alpha used STRUGGLE!") and said(events, "Alpha's hit with recoil!"),
       "the next turn's Struggle does")

    local mirror = arena({
      a = { { species = "Alpha", maxHp = 400, spd = 10, baseSpd = 0,
              moves = { fxm("mirror", 0, 9, { pp = 1 }) } } },
      b = { bob({ moves = { fxm("thump", 10, 0) } }) } })
    events = step(mirror, use(0), use(0))
    ok(said(events, "Alpha used thump!"), "a Mirror Move on its last PP copies")
    ok(not said(events, "Alpha's hit with recoil!"), "...and takes no recoil")

    local dizzy = arena({ pool = { fxm("thump", 10, 0) },
      a = { { species = "Alpha", maxHp = 400, spd = 90, baseSpd = 0, confusion = 6,
              moves = { fxm("metronome", 0, 83) } } },
      b = { bob() } })
    -- (R1e: a confusion byte below 128 is the one that keeps its head.)
    script(dizzy, { 100 })
    events = step(dizzy, use(0), use(0))
    ok(said(events, "Alpha used thump!"), "a confused caller that keeps its head calls")
    eq(activeMonOf(dizzy, "p1").confusion, 5, "...and the call runs no second confusion gate")
  end

  -- (k) The flinch-reset skip.  A raging player's monster a slower Stomp
  --     flinched loses its next Rage to the flinch; in a link fight too (both
  --     sides are "the player", the owner's rule); the computer's raging
  --     monster is always reset.  A flinch that lands runs ClearHyperBeam on
  --     its target (FlinchSideEffect, effects.asm :991), so a HYPER BEAM user
  --     a slower Stomp flinched is not recharging at the open: the reset takes
  --     the flinch and it fires again (the cart's recharge skip).
  do
    local function rage(mode, side)
      local fury = { fxm("fury", 20, 81) }
      local stomp = { fxm("stomp", 10, 31, { chance = 100 }) }
      local fast = { species = side == "b" and "Beta" or "Alpha", maxHp = 400, spd = 90,
                     baseSpd = 0, moves = fury }
      local slow = { species = side == "b" and "Alpha" or "Beta", maxHp = 400, spd = 30,
                     baseSpd = 0, moves = stomp }
      local battle = arena({ mode = mode,
        a = { side == "b" and slow or fast }, b = { side == "b" and fast or slow } })
      step(battle, use(0), use(0))
      return step(battle, use(0), use(0))
    end
    ok(said(rage("wild"), "Alpha flinched!"), "the player's raging monster keeps the flinch")
    -- The owner's rule (R1b): in a link fight both sides are "the player",
    -- so the raging monster keeps its flinch there too.
    ok(said(rage("1v1"), "Alpha flinched!"), "a link fight keeps it too")
    ok(not said(rage("wild", "b"), "Beta flinched!"), "the computer's raging monster is reset")

    local beam = arena({
      a = { { species = "Alpha", maxHp = 400, spd = 90, baseSpd = 0, moves = { fxm("beam", 20, 80) } } },
      b = { bob({ maxHp = 400, moves = { fxm("stomp", 10, 31, { chance = 100 }) } }) } })
    step(beam, use(0), use(0))
    eq(activeMonOf(beam, "p1").mustRecharge, false, "the flinch cleared the recharge")
    eq(activeMonOf(beam, "p1").flinch, false, "...so the open reset the flinch like any")
    ok(said(step(beam, use(0), use(0)), "Alpha used beam!"), "...and the beam fires again")

    -- Per seat in co-op: the raging seat keeps its flinch, its partner's is
    -- reset like any.
    local coop = battleOf({ mode = "coop_wild", seed = 6403, sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = { mon({ species = "Alpha", maxHp = 400, spd = 90,
          baseSpd = 0, moves = { fxm("fury", 20, 81) } }) } },
        { playerId = "a2", name = "Abe", mons = { mon({ species = "Gamma", maxHp = 400, spd = 80,
          baseSpd = 0, moves = { fxm("thump", 10, 0) } }) } },
      },
      b = { { playerId = "w", name = "Wild", mons = { mon({ species = "Beta", maxHp = 900,
        spd = 30, baseSpd = 0, moves = { fxm("stomp", 10, 31, { chance = 100 }) } }) } } },
    } })
    drain(coop)
    local function round(target)
      coop:submitChoice("a1", { action = "fight", move = 0, target = 3 })
      coop:submitChoice("a2", { action = "fight", move = 0, target = 3 })
      coop:submitChoice("w", { action = "fight", move = 0, target = target })
      return drain(coop)
    end
    round(0)
    local second = round(1)
    ok(said(second, "Alpha flinched!"), "co-op: the raging seat keeps its flinch")
    local third = round(1)
    ok(not said(third, "Gamma flinched!"), "co-op: the partner's flinch is reset")
    ok(said(third, "Gamma used thump!"), "...and it moves")
  end

  -- (l) The fields the rules read: `badgeRules` on side a of a fight against
  --     the computer and nowhere else, `traded` kept only as true.
  do
    local function rules(mode)
      local battle = battleOf({ mode = mode, sides = mode == "coop_wild" and {
        a = { { playerId = "p1", name = "Ann", mons = { mon() } },
              { playerId = "p3", name = "Abe", mons = { mon() } } },
        b = { { playerId = "p2", name = "Bob", mons = { mon() } } },
      } or nil })
      return tostring(fighterById(battle, "p1").badgeRules) .. "/"
        .. tostring(fighterById(battle, "p2").badgeRules)
    end
    eq(rules("wild"), "true/nil", "wild: side a has the badge rules")
    eq(rules("coop_wild"), "true/nil", "coop_wild: side a has them")
    eq(rules("coop_npc"), "true/nil", "coop_npc: side a has them")
    eq(rules("1v1"), "nil/nil", "1v1: nobody")
    eq(rules("coop_pvp"), "nil/nil", "coop_pvp: nobody")

    local function traded(value)
      local raw = mon()
      raw.traded = value
      local battle = battleOf({ aMons = { raw } })
      return activeMonOf(battle, "p1").traded
    end
    eq(traded(true), true, "traded = true is kept")
    eq(traded(false), nil, "traded = false is absent")
    eq(traded("yes"), nil, "a non-boolean traded is absent")
  end
end

-- ------------------------------------------------------------------
-- 27. Gen 1 review fixes: a Leech Seed KO, where Rage builds, a Bide aimed
--     at slot 0, a side-effect drop at -6
-- ------------------------------------------------------------------
--
-- Task FX1.  HandleBuildingRage (pokered core.asm :4913-4950) has two
-- callers, ExecutePlayerMove :3243 and ExecuteEnemyMove :5643, both after
-- ApplyAttackTo*Pokemon and both behind `ret z` on the target's HP: it runs
-- once per hit of a move that lands -- a Substitute soaking it included --
-- never for the hit that knocks the target out, and never for HP no
-- opponent's move took.  The three ways in that carry no hit: a Bide
-- release, a trap's later turns (the trapper's own attack on the cart), a
-- missed Explosion (`.notDone`), and a power-0 move outside both
-- ResidualEffects lists -- Disable -- whose build comes before its own hit
-- test.  The g1_leech_ko / g1_rage_* / g1_bide_slot0 / g1_side_min parity
-- scenarios hold lib/battle to the same streams.

do
  local Rng = BattleSim.Rng

  -- BattleRandom, scripted: the listed bytes first, then a seeded generator.
  local function script(battle, bytes)
    local fallback = Rng.new(99)
    local used = 0
    battle.rng = {
      byte = function()
        used = used + 1
        if bytes[used] ~= nil then return bytes[used] end
        return fallback:byte()
      end,
      nextInt = function(_, lo, hi) return fallback:nextInt(lo, hi) end,
      damageRoll = function() return fallback:damageRoll() end,
      next = function() return fallback:next() end,
      state = function() return fallback:state() end,
    }
  end

  local function fxm(id, power, effect, o)
    o = o or {}
    return move({ id = id, power = power, effect = effect, chance = o.chance,
                  accuracy = o.accuracy, pp = o.pp or 60 })
  end
  -- mon() plus the raw sheet fields it does not carry (raging, substitute,
  -- leechSeed, bide, lastMoveIndex, ...); crits held off with baseSpd 0.
  local function sheet(o)
    local raw = mon(o)
    raw.baseSpd = 0
    if o.confusion then raw.confusion = o.confusion end
    for key, value in pairs(o.extra or {}) do raw[key] = value end
    return raw
  end
  local function duel(o)
    local aMons, bMons = {}, {}
    for i, opts in ipairs(o.a) do aMons[i] = sheet(opts) end
    for i, opts in ipairs(o.b) do bMons[i] = sheet(opts) end
    local battle = battleOf({
      mode = o.mode or "1v1", seed = o.seed or 6601,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = aMons } },
        b = { { playerId = "p2", name = "Bob", mons = bMons } },
      },
    })
    drain(battle)
    return battle
  end
  local function step(battle, aChoice, bChoice)
    battle:submitChoice("p1", aChoice)
    battle:submitChoice("p2", bChoice)
    return drain(battle)
  end
  local function use(i) return { action = "fight", move = i } end
  local function said(events, text)
    for _, event in ipairs(events) do
      if event.t == "msg" and event.text == text then return true end
    end
    return false
  end
  local function count(events, pred)
    local n = 0
    for _, event in ipairs(events) do if pred(event) then n = n + 1 end end
    return n
  end
  local fury = function() return fxm("fury", 20, 81) end
  local splash = function() return fxm("splash", 0, 85) end
  local raging = { raging = true, rageMove = 1 }
  local function with(base, more)
    local out = {}
    for k, v in pairs(base) do out[k] = v end
    for k, v in pairs(more or {}) do out[k] = v end
    return out
  end

  -- (a) The Leech Seed tick that knocks the seeded monster out.  `_faint`
  --     clears `leechSeed`, and the residual used to read it afterwards and
  --     throw.  The seeder is healed the whole 1/16 -- floor(100 / 16) = 6,
  --     50 -> 56 -- though Beta had only 3 HP to give: the cart's
  --     HandlePoisonBurnLeechSeed drains, then heals by the same amount, and
  --     only then looks at the faint.
  do
    local battle = duel({
      a = { { species = "Alpha", hp = 50, maxHp = 100, spd = 90, moves = { fxm("seed", 0, 84) } } },
      b = { { species = "Beta", hp = 3, maxHp = 100, spd = 10, moves = { splash() } } } })
    local okStep, events = pcall(step, battle, use(0), use(0))
    ok(okStep, "a Leech Seed KO resolves without throwing: " .. tostring(not okStep and events or ""))
    if okStep then
      eq(count(events, function(e) return e.t == "faint" and e.slot == 3 end), 1, "the seeded monster falls")
      local healed = nil
      for _, e in ipairs(events) do if e.t == "drain" and e.slot == 0 then healed = e.amount .. "/" .. e.hp end end
      eq(healed, "6/56", "the seeder gets the whole 1/16")
      eq(battle:outcome() and battle:outcome().outcome, "win", "and the fight is over")
    end
  end

  -- (b) No build from HP no opponent's move took.  Alpha rages from its
  --     sheet, poisoned and seeded by Beta, and confused; Beta only
  --     Splashes.  Scripted: byte 1 is Alpha's confusion gate (200, 128 and
  --     up: a self-hit -- R1e, `.IsConfused`'s `jr c` skips it below 128) on
  --     turn 1.  Turn 2 the seeded generator decides; either way
  --     poison (400 / 16 = 25) and the seed (25) tick twice and the stage
  --     never moves -- it used to rise by one for every one of them.
  do
    local battle = duel({
      a = { { species = "Alpha", maxHp = 400, atk = 100, def = 80, spd = 90, status = "PSN",
              confusion = 4, moves = { fury() },
              extra = with(raging, { leechSeed = { fromSlot = 3 } }) } },
      b = { { species = "Beta", maxHp = 400, spd = 10, moves = { splash() } } } })
    script(battle, { 200 })
    local first = step(battle, use(0), use(0))
    ok(said(first, "It hurt itself in its confusion!"), "turn 1 is a self-hit")
    ok(said(first, "Alpha's hurt by poison!") and said(first, "LEECH SEED saps Alpha!"),
       "...and both residuals tick")
    local second = step(battle, use(0), use(0))
    local alpha = activeMonOf(battle, "p1")
    eq(alpha.stages.atk, 0, "no self-hit, poison or seed tick builds Rage")
    eq(alpha.cur.atk, 100, "ATTACK is where it started")
    ok(not said(first, "Alpha's ATTACK rose!") and not said(second, "Alpha's ATTACK rose!"),
       "and nothing says it rose")
  end

  -- (c) The hit that knocks the raging monster out builds nothing (`ret z`),
  --     so the burned attacker keeps its 200 / 2 = 100 rather than being
  --     re-penalised to 50 by a build that never happened.
  do
    local battle = duel({
      a = { { species = "Alpha", hp = 20, maxHp = 300, spd = 90, moves = { fury() }, extra = raging },
            { species = "Gamma", maxHp = 300, moves = { splash() } } },
      b = { { species = "Beta", maxHp = 300, atk = 200, spd = 10, status = "BRN",
              moves = { fxm("thump", 80, 0) } } } })
    eq(activeMonOf(battle, "p2").cur.atk, 100, "the burned attacker: 200 -> 100")
    local events = step(battle, use(0), use(0))
    ok(count(events, function(e) return e.t == "faint" and e.slot == 0 end) == 1, "Alpha falls")
    ok(not said(events, "Alpha's ATTACK rose!"), "the knockout builds nothing")
    eq(activeMonOf(battle, "p2").cur.atk, 100, "...and re-penalises nobody")
  end

  -- (d) A Substitute that soaks the hit still builds, and a two-hit move
  --     builds once per hit, each after its hit.  Beta's kicks hit for 7.  A
  --     5-HP doll breaks on the first hit, and that ends the move (the
  --     effect `.nullifyEffect` zeroed never reaches TwoToFiveAttacksEffect):
  --     one hit, one build -- stage +1, 40 x 150 / 100 = 60 -- and Alpha's
  --     own HP untouched.  A 12-HP doll soaks the first (5 left) and breaks
  --     on the second: both hits thrown, both build -- +2, 40 x 200 / 100 = 80.
  local function slotZero(events)
    local order = {}
    for _, e in ipairs(events) do
      if e.slot == 0 and (e.t == "damage" or e.t == "stat") then order[#order + 1] = e.t end
    end
    return table.concat(order, " ")
  end
  do
    local battle = duel({
      a = { { species = "Alpha", maxHp = 400, spd = 90, moves = { fury() },
              extra = with(raging, { substitute = 5 }) } },
      b = { { species = "Beta", maxHp = 400, spd = 10, moves = { fxm("kicks", 20, 44) } } } })
    local events = step(battle, use(0), use(0))
    local alpha = activeMonOf(battle, "p1")
    ok(said(events, "Alpha's SUBSTITUTE broke!"), "the first hit breaks the doll")
    eq(alpha.stages.atk, 1, "...and the move ends there: one hit, one build")
    eq(alpha.cur.atk, 60, "40 at +1")
    eq(alpha.hp, 400, "no second hit reaches Alpha")
    eq(slotZero(events), "damage stat", "the build follows its hit")
  end
  do
    local battle = duel({
      a = { { species = "Alpha", maxHp = 400, spd = 90, moves = { fury() },
              extra = with(raging, { substitute = 12 }) } },
      b = { { species = "Beta", maxHp = 400, spd = 10, moves = { fxm("kicks", 20, 44) } } } })
    local events = step(battle, use(0), use(0))
    local alpha = activeMonOf(battle, "p1")
    ok(said(events, "Alpha's SUBSTITUTE broke!"), "the second hit breaks the 12-HP doll")
    eq(alpha.stages.atk, 2, "both hits build, the soaked one included")
    eq(alpha.cur.atk, 80, "40 at +2")
    eq(alpha.hp, 400, "...both on the doll")
    eq(slotZero(events), "damage stat damage stat", "each build follows its hit")
  end

  -- (e) A Bide release is a hit: Beta's sheet holds 10 stored and its
  --     counter is spent, so this forced turn unleashes at Alpha (slot 0) --
  --     after `.BideCheck` adds wDamage, which is Alpha's faster Rage hit (8)
  --     -- for 2 x 18 = 36, and the raging Alpha builds after it.  Alpha's
  --     Rage is forced; Beta, a player, answers the battle menu, and its
  --     FIGHT is the Bide's turn (R1d `_menuFight`).
  do
    local battle = duel({
      a = { { species = "Alpha", maxHp = 400, spd = 90, moves = { fury() }, extra = raging } },
      b = { { species = "Beta", maxHp = 400, spd = 10, moves = { fxm("bide", 0, 26) },
              extra = { bide = { turns = 0, stored = 10, moveIndex = 1, targetSlot = 0 } } } } })
    battle:submitChoice("p2", { action = "fight" })
    local events = drain(battle)
    local order = {}
    for _, e in ipairs(events) do
      if e.slot == 0 and (e.t == "damage" or e.t == "stat") then order[#order + 1] = e.t .. ":" .. tostring(e.amount) end
    end
    eq(table.concat(order, " "), "damage:36 stat:1", "the release lands at slot 0, then the build")
  end

  -- (f) The two builds no hit carries.  Beta's Disable and Explosion both
  --     have accuracy 0 (effective 1: they land only on a 0 byte), and both
  --     miss here.  The Disable still built Alpha (+1): power 0 sends it round
  --     MoveHitTest to a no-op ApplyAttack and the build, and Disable's own
  --     hit test comes after -- its miss is "But it failed!" (DisableEffect's
  --     `.moveMissed`).  The Explosion still ran (`.notDone`): Alpha builds
  --     again (+2) and Beta goes down.
  do
    local battle = duel({
      seed = 6505,
      a = { { species = "Alpha", maxHp = 400, spd = 90, moves = { fury() },
              extra = with(raging, { lastMoveIndex = 1 }) } },
      b = { { species = "Beta", maxHp = 400, spd = 10,
              moves = { fxm("numb", 0, 86, { accuracy = 0 }), fxm("boom", 130, 7, { accuracy = 0 }) } } } })
    local first = step(battle, use(0), use(0))
    ok(said(first, "But, it failed!"), "the Disable missed")
    eq(activeMonOf(battle, "p1").stages.atk, 1, "...and Alpha built all the same")
    local second = step(battle, use(0), use(1))
    ok(said(second, "Beta's attack missed!"), "the Explosion missed")
    eq(activeMonOf(battle, "p1").stages.atk, 2, "...and Alpha built again")
    eq(battle:outcome() and battle:outcome().winners[1], "p1", "the exploder went down")
  end

  -- (g) A trap's later turns are the trapper's own attack on the cart, so a
  --     raging, trapped Alpha builds on every tick and the re-penalty finds
  --     the trapper: Delta (slot 4, burned, 200 -> 100) is halved again on
  --     the Wrap's hit and on its tick -- 50, then 25 -- while Beta, burned
  --     and standing opposite at slot 3, keeps its 100.  (The residual used
  --     to name the battler opposite.)
  do
    local battle = battleOf({
      mode = "coop_pvp", seed = 6506,
      sides = {
        a = {
          { playerId = "a1", name = "Ann", mons = { sheet({ species = "Alpha", maxHp = 400, spd = 90,
              moves = { fury() }, extra = raging }) } },
          { playerId = "a2", name = "Amy", mons = { sheet({ species = "Gamma", maxHp = 400, spd = 80,
              moves = { splash() } }) } },
        },
        b = {
          { playerId = "b1", name = "Bob", mons = { sheet({ species = "Beta", maxHp = 400, atk = 200,
              spd = 20, status = "BRN", moves = { splash() } }) } },
          { playerId = "b2", name = "Bea", mons = { sheet({ species = "Delta", maxHp = 400, atk = 200,
              spd = 10, status = "BRN", moves = { fxm("wrap", 5, 42) } }) } },
        },
      },
    })
    drain(battle)
    local function round(turn)
      battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
      battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
      battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
      battle:submitChoice("b2", { action = "fight", move = 0, target = 0 })
      for s = 1, 3 do battle:tick(turn * 10 + s) end
      return drain(battle)
    end
    round(1)
    eq(activeMonOf(battle, "a1").stages.atk, 1, "the Wrap's hit builds")
    eq(activeMonOf(battle, "b2").cur.atk, 50, "...and re-penalises the trapper")
    local second = round(2)
    ok(said(second, "Delta's attack continues!"), "turn 2 is the trap's continuation")
    eq(activeMonOf(battle, "a1").stages.atk, 2, "the tick builds")
    eq(activeMonOf(battle, "b2").cur.atk, 25, "the trapper is re-penalised again")
    eq(activeMonOf(battle, "b1").cur.atk, 100, "the battler opposite is not")
  end

  -- (h) A Bide aimed at field slot 0 releases at slot 0 in a 2v2, whatever
  --     the spread aim would have picked -- slot 0 is a seat, not "no aim".
  --     (lib/battle once read it with `||`; the g1_bide_slot0 scenario is the
  --     seed on which that went to slot 1.)  On this seed the counter is 3:
  --     three stores of wDamage -- Alpha's 5 each turn -- and the unleash on
  --     the fourth turn, 2 x 15 (R1b: `.BideCheck` stores wDamage).
  do
    local battle = battleOf({
      mode = "coop_pvp", seed = 3,
      sides = {
        a = {
          { playerId = "a1", name = "Ann", mons = { sheet({ species = "Alpha", maxHp = 400, spd = 90,
              moves = { fxm("tap", 10, 0) } }) } },
          { playerId = "a2", name = "Amy", mons = { sheet({ species = "Gamma", maxHp = 400, spd = 80,
              moves = { splash() } }) } },
        },
        b = {
          { playerId = "b1", name = "Bob", mons = { sheet({ species = "Beta", maxHp = 400, spd = 10,
              moves = { fxm("bide", 0, 26) } }) } },
          { playerId = "b2", name = "Bea", mons = { sheet({ species = "Delta", maxHp = 400, spd = 5,
              moves = { splash() } }) } },
        },
      },
    })
    drain(battle)
    local hitsOnA = {}
    for turn = 1, 4 do
      battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
      battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
      battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
      battle:submitChoice("b2", { action = "fight", move = 0, target = 0 })
      for s = 1, 3 do battle:tick(turn * 10 + s) end
      for _, e in ipairs(drain(battle)) do
        if e.t == "damage" and e.side == "a" then hitsOnA[#hitsOnA + 1] = e.slot .. ":" .. e.amount end
      end
    end
    eq(table.concat(hitsOnA, " "), "0:30", "the release lands on slot 0")
  end

  -- (i) A side-effect drop at -6 says nothing (CantLowerAnymore:
  --     `cp ATTACK_DOWN_SIDE_EFFECT; ret nc`); the primary at -6 prints its
  --     line, "Nothing happened!" (R1b).
  do
    local battle = duel({
      a = { { species = "Alpha", maxHp = 400, spd = 90,
              moves = { fxm("bubble", 10, 70, { chance = 100 }), fxm("goo", 0, 20) } } },
      b = { { species = "Beta", maxHp = 400, spd = 10, moves = { splash() },
              extra = { stages = { atk = 0, def = 0, spd = -6, spc = 0, acc = 0, eva = 0 } } } } })
    local first = step(battle, use(0), use(0))
    ok(not said(first, "Beta's SPEED won't go any lower"), "the side effect at -6 is silent")
    local second = step(battle, use(1), use(0))
    ok(said(second, "Nothing happened!"), "the primary at -6 still says so")
  end
end

-- ------------------------------------------------------------------
-- 28. Gen 1 side-effect odds: the routines' own thresholds, the explicit
--     override, and what each routine checks before it draws
-- ------------------------------------------------------------------
--
-- Task FX4.  pokered keeps a side effect's odds in the routine, not the move
-- record, so every Red move reaches the referee at chance 0 and reads
-- Effects.SIDE_THRESHOLD: PoisonEffect 52 / 103 (TWINEEDLE rides 52),
-- FreezeBurnParalyzeEffect 26 / 77, FlinchSideEffect 26 / 77,
-- StatModifierDownEffect 85, ConfusionSideEffect 25 (engine/battle/
-- effects.asm; the vector pack's `side` section pins the table).  Every
-- byte below is forced, and every BattleRandom a turn draws is counted, so
-- "draws nothing" is a number.  The g1_odds_* / g1_side_* parity scenarios
-- hold lib/battle to the same streams.

do
  local Rng, Effects = BattleSim.Rng, BattleSim.Effects

  -- BattleRandom, scripted and logged: the listed bytes first, then a seeded
  -- generator.  The damage roll comes off the generator and is not logged, so
  -- a plain turn of a hit and a splash logs three bytes: the hit's accuracy
  -- and crit, the splash's accuracy.
  local function script(battle, bytes)
    local fallback = Rng.new(99)
    local log = {}
    battle.rng = {
      byte = function()
        local b = bytes[#log + 1]
        if b == nil then b = fallback:byte() end
        log[#log + 1] = b
        return b
      end,
      nextInt = function(_, lo, hi) return fallback:nextInt(lo, hi) end,
      damageRoll = function() return fallback:damageRoll() end,
      next = function() return fallback:next() end,
      state = function() return fallback:state() end,
    }
    return log
  end

  local function fxm(id, power, effect, o)
    o = o or {}
    return move({ id = id, power = power, effect = effect, chance = o.chance,
                  type = o.type, pp = 60 })
  end
  local function hit(effect, o) return fxm("hit", 10, effect, o) end
  local splash = function() return fxm("splash", 0, 85) end

  -- Alpha (p1, fast) against Beta (p2, slow, type 1), crits held off with
  -- baseSpd 0.  `a` / `b` add mon() options and raw sheet fields (`extra`);
  -- `typeIds` is the ruleset's chart axis by name.
  local function duel(o)
    local function sheet(base, more)
      local opts = {}
      for k, v in pairs(base) do opts[k] = v end
      for k, v in pairs(more or {}) do opts[k] = v end
      local raw = mon(opts)
      raw.baseSpd = 0
      for key, value in pairs(opts.extra or {}) do raw[key] = value end
      return raw
    end
    local battle = assert(Turn.create({
      id = "fx4", mode = o.mode or "1v1", seed = 4, typeIds = o.typeIds,
      choiceTimeout = 60, reconnectGrace = 60,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = { sheet(
          { species = "Alpha", maxHp = 400, spd = 90, types = { 1 }, moves = { hit(0) } }, o.a) } } },
        b = { { playerId = "p2", name = "Bob", mons = { sheet(
          { species = "Beta", maxHp = 400, spd = 10, types = { 1 }, moves = { splash() } }, o.b) } } },
      },
    }))
    drain(battle)
    return battle
  end
  local function said(events, text)
    for _, event in ipairs(events) do
      if event.t == "msg" and event.text == text then return true end
    end
    return false
  end
  -- The `damage` events one side took, as "amount:hp".
  local function hitsOn(events, side)
    local out = {}
    for _, event in ipairs(events) do
      if event.t == "damage" and event.side == side then
        out[#out + 1] = event.amount .. ":" .. event.hp
      end
    end
    return out
  end
  -- One turn on scripted bytes: how many it drew, what it said, the battle.
  local function turn(o, bytes)
    local battle = duel(o)
    local log = script(battle, bytes or { 255, 0 })
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    local events = drain(battle)
    return #log, events, battle, log
  end
  local function beta(battle) return activeMonOf(battle, "p2") end

  -- (a) Every family at chance 0: the byte one below the routine's threshold
  --     lands, the threshold itself does not, and it is the move's third
  --     byte (crit 255, accuracy 0 -- R1c: CriticalHitTest before MoveHitTest
  --     -- then the side byte).  Twineedle's two
  --     hits draw nothing between them.
  local FAMILIES = {
    { 2, 52, "Beta was poisoned!" }, { 33, 103, "Beta was poisoned!" },
    { 77, 52, "Beta was poisoned!" },
    { 4, 26, "Beta was burned!" }, { 34, 77, "Beta was burned!" },
    { 5, 26, "Beta was frozen solid!" }, { 35, 77, "Beta was frozen solid!" },
    { 6, 26, "Beta's paralyzed! It may not attack!" }, { 36, 77, "Beta's paralyzed! It may not attack!" },
    { 31, 26, "Beta flinched!" }, { 37, 77, "Beta flinched!" },
    { 68, 85, "Beta's ATTACK fell!" }, { 69, 85, "Beta's DEFENSE fell!" },
    { 70, 85, "Beta's SPEED fell!" }, { 71, 85, "Beta's SPECIAL fell!" },
    { 76, 25, "Beta became confused!" },
  }
  for _, f in ipairs(FAMILIES) do
    local effect, at, says = f[1], f[2], f[3]
    for _, byte in ipairs({ at - 1, at }) do
      local _, events, _, log = turn({ a = { moves = { hit(effect) } } }, { 255, 0, byte })
      eq(log[3], byte, ("effect %d: the side byte is the move's third"):format(effect))
      eq(said(events, says), byte < at,
         ("effect %d at chance 0: byte %d %s"):format(effect, byte,
           byte < at and "lands" or "does not"))
    end
  end
  eq(Effects.SIDE_THRESHOLD[76], 25, "ConfusionSideEffect is `cp 10 percent`, the one with no + 1")

  -- (b) The explicit override: a sheet percent is floor(pct * 255 / 100) and
  --     wins over the cart's constant; an effect with no side routine draws
  --     nothing whatever chance it states.
  local plain = turn({})
  -- (R1b: SPLASH is ResidualEffects1 and never reaches MoveHitTest, so the
  -- splash draws nothing -- the plain turn is the hit's crit and acc.)
  eq(plain, 2, "a plain hit draws two bytes and a splash none")
  for _, c in ipairs({
    { chance = 20, byte = 50, lands = true },   -- 51
    { chance = 0, byte = 50, lands = false },   -- the cart's 26
    { chance = 19, byte = 47, lands = true },   -- 48
    { chance = 19, byte = 48, lands = false },
    { chance = 100, byte = 254, lands = true }, -- 255
    { chance = 100, byte = 255, lands = false },
  }) do
    local _, events = turn({ a = { moves = { hit(4, { chance = c.chance }) } } }, { 255, 0, c.byte })
    eq(said(events, "Beta was burned!"), c.lands,
       ("burn at chance %d, byte %d"):format(c.chance, c.byte))
  end
  eq((turn({ a = { moves = { hit(0, { chance = 100 }) } } })), plain,
     "chance 100 on effect 0 draws nothing")
  eq((turn({ a = { moves = { hit(3, { chance = 100 }) } } })), plain,
     "...nor on a drain")

  -- (c) What each routine checks before its draw.  Byte 0 would land
  --     anywhere, so a turn that draws no more than the plain one never
  --     asked.
  local draws, events, battle
  draws = turn({ a = { moves = { hit(4) } }, b = { status = "PSN" } })
  eq(draws, plain, "FreezeBurnParalyze: an already-statused target, no draw")
  draws, events, battle = turn({ a = { moves = { hit(4) } }, b = { types = { 0 } } })
  eq(draws, plain, "...a target of the move's own type, no draw")
  eq(beta(battle).status, nil, "...and no burn")
  draws, events, battle = turn({ a = { moves = { hit(2) } }, typeIds = { "NORMAL", "POISON" } })
  eq(draws, plain, "PoisonEffect: a Poison-type target (typeIds names index 1), no draw")
  eq(beta(battle).status, nil, "...and no poison")
  draws, events, battle = turn({ a = { moves = { hit(2) } }, b = { types = { 0 } },
                                 typeIds = { "NORMAL", "POISON" } })
  eq(draws, plain + 1, "...a Normal-type one draws")
  eq(beta(battle).status, "poison", "...and is poisoned")
  draws, events, battle = turn({ a = { moves = { hit(2) } } })
  eq(beta(battle).status, "poison", "without typeIds no index is POISON: type 1 is poisoned")
  draws = turn({ a = { moves = { hit(2) } }, b = { status = "BRN" } })
  eq(draws, plain, "PoisonEffect: an already-statused target, no draw")

  local SUB = { extra = { substitute = 200 } }
  for _, c in ipairs({ { 4, "burn" }, { 2, "poison" }, { 31, "flinch" }, { 71, "drop" } }) do
    draws, events, battle = turn({ a = { moves = { hit(c[1]) } }, b = SUB })
    eq(draws, plain, c[2] .. " into a Substitute that holds: no draw")
    ok(beta(battle).substitute > 0 and beta(battle).status == nil
       and beta(battle).stages.spc == 0, "...and nothing lands behind it")
  end
  draws, events, battle = turn({ a = { moves = { hit(76) } }, b = SUB }, { 255, 0, 0, 1 })
  ok(said(events, "Beta became confused!"),
     "ConfusionSideEffect checks no Substitute: it confuses the monster behind one")
  eq(beta(battle).substitute > 0, true, "...the Substitute still standing")
  -- An already-confused target: the side byte is still drawn, and the
  -- failure is silent and draws no turn count.  The control is the same
  -- confused target taking a plain hit.
  local confusedPlain = turn({ b = { confusion = 3 } }, { 255, 0, 200 })
  draws, events = turn({ a = { moves = { hit(76) } }, b = { confusion = 3 } }, { 255, 0, 0, 200 })
  eq(draws, confusedPlain + 1, "a confused target: the side byte, and nothing else")
  ok(not said(events, "Beta became confused!"), "...silently")

  -- (d) Where the move never gets to its side effect: a Substitute it broke
  --     (`.nullifyEffect`) and a knockout (`ret z`).
  local DOLL = { extra = { substitute = 1 } }
  draws, events, battle = turn({ a = { moves = { hit(4) } }, b = DOLL })
  ok(said(events, "Beta's SUBSTITUTE broke!"), "the hit breaks the Substitute")
  eq(draws, plain, "...and the burn effect is gone with it: no draw")
  eq(beta(battle).status, nil, "...no burn")
  draws, events, battle = turn({ a = { moves = { hit(77) } }, b = DOLL })
  eq(beta(battle).hp, 400, "Twineedle stops at the hit that broke the Substitute")
  eq(#hitsOn(events, "b"), 1, "...one hit, the doll's")
  eq(draws, plain, "...and its poison does not roll")
  eq(beta(battle).status, nil, "...no poison")
  local koPlain = turn({ b = { hp = 1 } })
  draws, events = turn({ a = { moves = { hit(4) } }, b = { hp = 1 } })
  eq(draws, koPlain, "a knockout draws no side byte")
  ok(not said(events, "Beta was burned!"), "...and burns nobody")

  -- (e) CheckDefrost: a Fire move into a frozen target thaws it and draws
  --     nothing; any other burn-family move leaves it frozen.
  local FIRE = { "NORMAL", "FIRE" }
  draws, events, battle = turn({ a = { moves = { hit(4, { type = 1 }) } },
    b = { status = "FRZ", types = { 0 } }, typeIds = FIRE })
  ok(said(events, "Fire defrosted Beta!"), "a Fire burn move thaws a frozen target")
  eq(beta(battle).status, nil, "...the freeze is gone")
  eq(draws, plain, "...and no draw: the thawed Beta moves as the plain turn's")
  draws, events, battle = turn({ a = { moves = { hit(4) } },
    b = { status = "FRZ", types = { 0 } }, typeIds = FIRE })
  ok(not said(events, "Fire defrosted Beta!"), "a Normal burn move does not thaw")
  eq(beta(battle).status, "freeze", "...Beta stays frozen")
  draws, events, battle = turn({ a = { moves = { hit(4, { type = 1 }) } },
    b = { status = "FRZ", types = { 0 } } })
  eq(beta(battle).status, "freeze", "without typeIds nothing is FIRE: nothing thaws")

  -- (f) Mist stops a primary drop and never a side effect's.
  draws, events, battle = turn({ a = { moves = { hit(71) } }, b = { extra = { mist = true } } })
  ok(said(events, "Beta's SPECIAL fell!"), "a side-effect drop goes through Mist")
  ok(not said(events, "But, it failed!"), "...without a word of failure")
  draws, events = turn({ a = { moves = { fxm("goo", 0, 21) } }, b = { extra = { mist = true } } })
  ok(said(events, "But, it failed!"), "a primary drop into Mist still fails")

  -- (g) The computer's side-effect drop: StatModifierDownEffect draws its
  --     extra miss first on the enemy's turn outside a link battle (`cp 25
  --     percent + 1`, 64), then the Substitute check, then the side byte.
  --     Beta is the wild monster here, and the faster.
  local function wildDrop(bytes, more)
    local o = { mode = "wild", a = { spd = 10, moves = { splash() } },
                b = { spd = 90, moves = { hit(70) } } }
    for k, v in pairs(more or {}) do o.a[k] = v end
    return turn(o, bytes)
  end
  local drew, said1, b1 = wildDrop({ 255, 0, 63 })
  eq(activeMonOf(b1, "p1").stages.spd, 0, "the computer's miss byte 63 stops the drop")
  eq(drew, 3, "...and no side byte follows it: crit, acc, miss (Alpha's splash draws none)")
  drew, said1, b1 = wildDrop({ 255, 0, 64, 84 })
  eq(activeMonOf(b1, "p1").stages.spd, -1, "64 passes and the side byte 84 lands")
  eq(drew, 4, "...crit, acc, miss, side")
  drew, said1, b1 = wildDrop({ 255, 0, 64, 85 })
  eq(activeMonOf(b1, "p1").stages.spd, 0, "...and 85 does not")
  drew, said1, b1 = wildDrop({ 255, 0, 64 }, { extra = { substitute = 200 } })
  eq(drew, 3, "into a Substitute: the miss byte is drawn, the side byte is not")
  eq(activeMonOf(b1, "p1").stages.spd, 0, "...and nothing falls")
  -- The same move in a link fight never draws the miss byte.
  draws, events, battle = turn({ a = { spd = 10, moves = { splash() } },
    b = { spd = 90, moves = { hit(70) } } }, { 255, 0, 84 })
  eq(activeMonOf(battle, "p1").stages.spd, -1, "a link fight: the side byte comes straight after the crit")
  eq(draws, 3, "...crit, acc, side")
  -- The player's drop on the computer draws no miss byte either.
  draws, events, battle = turn({ mode = "wild", a = { moves = { hit(70) } } }, { 255, 0, 84 })
  eq(beta(battle).stages.spd, -1, "the player's side-effect drop on the wild monster: no miss byte")
  eq(draws, 3, "...crit, acc, side")
end

-- ------------------------------------------------------------------
-- 29. Gen 1 multi-hit moves after a broken Substitute
-- ------------------------------------------------------------------
--
-- Task FX7.  pokered learns a move hits more than once only after its first
-- hit: TwoToFiveAttacksEffect runs from the AlwaysHappenSideEffects lookup at
-- `.notDone` (core.asm :3232-3237) and sets ATTACKING_MULTIPLE_TIMES there.
-- A first hit that breaks a Substitute has already zeroed the move's effect
-- (AttackSubstitute `.nullifyEffect`, :4899), so the lookup misses and the
-- move ends after that one hit -- DOUBLE KICK (44), TWINEEDLE (77) and the
-- two-to-five moves (29) alike.  A break on hit 2 or later finds the bit set
-- and the move goes on, its later hits landing on the monster; the effect is
-- gone all the same, so TWINEEDLE's poison never rolls.  Every byte is
-- scripted and the damage roll held at 255, so each hit is exactly 10 (level
-- 20, 40 / 40, power 40, no STAB): a 5-HP doll breaks on hit 1, a 15-HP doll
-- on hit 2, a 25-HP one on hit 3, and a 10-HP doll survives hit 1 at 0
-- (AttackSubstitute's `ret nc`) to break on hit 2.  The two-to-five count is
-- TwoToFiveAttacksEffect's (effects.asm :925-969), drawn where the cart
-- draws it: after the first hit (crit, acc, hit 1, then the count), and not
-- at all when that hit broke the doll.  `byte % 4` below 2 is 2 or 3 hits;
-- 2 or 3 draws a second byte whose `% 4` is kept -- 3/8, 3/8, 1/8, 1/8 for
-- 2..5.  The g1_multi_sub / g1_rage_sub* parity scenarios hold lib/battle to
-- the same streams.

do
  local Rng = BattleSim.Rng

  local function script(battle, bytes)
    local fallback = Rng.new(99)
    local log = {}
    battle.rng = {
      byte = function()
        local b = bytes[#log + 1]
        if b == nil then b = fallback:byte() end
        log[#log + 1] = b
        return b
      end,
      nextInt = function(_, lo, hi) return fallback:nextInt(lo, hi) end,
      damageRoll = function() return 255 end,
      next = function() return fallback:next() end,
      state = function() return fallback:state() end,
    }
    return log
  end
  local function fxm(id, power, effect)
    return move({ id = id, power = power, effect = effect, pp = 60 })
  end
  local function sheet(o)
    local raw = mon(o)
    raw.baseSpd = 0
    return raw
  end

  -- Alpha (p1, fast, type 1) uses `effect` at power 40 on Beta (p2, slow,
  -- type 1, 400 HP, a doll of `sub` HP, none at 0), who splashes.  Returns
  -- the damage Beta's side took ("amount:hp" -- a doll's hit leaves hp at
  -- 400), how many bytes the turn drew, whether the doll broke, whether Beta
  -- was poisoned, and Beta.
  local function turn(effect, sub, bytes)
    local battle = assert(Turn.create({
      id = "fx7", mode = "1v1", seed = 7, choiceTimeout = 60, reconnectGrace = 60,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = { sheet({ species = "Alpha",
          maxHp = 400, spd = 90, types = { 1 }, moves = { fxm("multi", 40, effect) } }) } } },
        b = { { playerId = "p2", name = "Bob", mons = { sheet({ species = "Beta",
          maxHp = 400, spd = 10, types = { 1 }, substitute = sub > 0 and sub or nil,
          moves = { fxm("splash", 0, 85) } }) } } },
      },
    }))
    drain(battle)
    local log = script(battle, bytes)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    local hits, broke, poisoned = {}, false, false
    for _, e in ipairs(drain(battle)) do
      if e.t == "damage" and e.side == "b" then hits[#hits + 1] = e.amount .. ":" .. e.hp end
      if e.t == "msg" and e.text == "Beta's SUBSTITUTE broke!" then broke = true end
      if e.t == "msg" and e.text == "Beta was poisoned!" then poisoned = true end
    end
    return table.concat(hits, " "), #log, broke, poisoned, activeMonOf(battle, "p2")
  end

  -- (a) Two-to-five (29): count bytes 3 then 3, five hits.
  local FIVE = { 255, 0, 3, 3 }
  local hits, draws, broke, poisoned, beta = turn(29, 0, FIVE)
  eq(hits, "10:390 10:380 10:370 10:360 10:350", "29, no doll: five hits on Beta")
  -- (R1b: Beta's SPLASH draws no accuracy byte, ResidualEffects1.)
  eq(draws, 4, "...crit, acc, the two count bytes after hit 1")
  hits, draws, broke, _, beta = turn(29, 5, FIVE)
  ok(broke, "29, a 5-HP doll: the first hit breaks it")
  eq(hits, "10:400", "...and the move ends there: the four hits left are never thrown")
  eq(beta.hp, 400, "...Beta untouched")
  eq(beta.substitute or 0, 0, "...the doll gone")
  eq(draws, 2, "...and no count byte: crit, acc")
  hits, draws, broke, _, beta = turn(29, 15, FIVE)
  ok(broke, "29, a 15-HP doll: the second hit breaks it")
  eq(hits, "10:400 10:400 10:390 10:380 10:370",
     "...and the move goes on: hits 3 to 5 land on Beta")
  eq(beta.hp, 370, "...30 off Beta")
  eq(draws, 4, "...the same four bytes")
  hits, draws, broke = turn(29, 25, FIVE)
  ok(broke, "29, a 25-HP doll: the third hit breaks it")
  eq(hits, "10:400 10:400 10:400 10:390 10:380", "...and hits 4 and 5 land on Beta")
  hits, draws, broke, _, beta = turn(29, 10, FIVE)
  ok(broke, "29, a 10-HP doll: hit 1 takes exactly its HP and it stands, at 0")
  eq(hits, "10:400 10:400 10:390 10:380 10:370",
     "...so the count is drawn, hit 2 breaks it and hits 3 to 5 land on Beta")
  eq(draws, 4, "...four bytes, as with no doll")
  hits, draws, broke, _, beta = turn(29, 15, { 255, 0, 0 })
  ok(broke, "29 on a count byte of 0, two hits: the second breaks the 15-HP doll")
  eq(hits, "10:400 10:400", "...both on the doll, Beta untouched")
  eq(beta.hp, 400, "...at 400")
  eq(draws, 3, "...one count byte: crit, acc, count")
  -- The rest of the distribution: 1 keeps 3 hits; 2 redraws, and the redraw's
  -- `% 4` is kept whatever it is (2 + 2 = 4 hits, 2 + 0 = 2 hits).
  hits, draws = turn(29, 0, { 255, 0, 1 })
  eq(hits, "10:390 10:380 10:370", "29 on a count byte of 1: three hits, no redraw")
  eq(draws, 3, "...crit, acc, count")
  hits, draws = turn(29, 0, { 255, 0, 2, 6 })
  eq(hits, "10:390 10:380 10:370 10:360", "29 on 2 then 6: the redraw's 2, four hits")
  eq(draws, 4, "...two count bytes")
  hits, draws = turn(29, 0, { 255, 0, 7, 4 })
  eq(hits, "10:390 10:380", "29 on 7 then 4: the redraw's 0, two hits")
  -- EFFECT_1E (30) is the same routine (effects_pointers.asm) and the same
  -- AlwaysHappenSideEffects entry: a two-to-five move.
  hits, draws = turn(30, 0, FIVE)
  eq(hits, "10:390 10:380 10:370 10:360 10:350", "EFFECT_1E (30): five hits on the same bytes")
  eq(draws, 4, "...drawn as 29 draws them")

  -- (b) DOUBLE KICK (44): two hits, no count byte.
  local TWO = { 255, 0 }
  hits, draws = turn(44, 0, TWO)
  eq(hits, "10:390 10:380", "44, no doll: two hits on Beta")
  eq(draws, 2, "...crit, acc")
  hits, draws, broke, _, beta = turn(44, 5, TWO)
  ok(broke, "44, a 5-HP doll: the first hit breaks it")
  eq(hits, "10:400", "...and the second is never thrown")
  eq(beta.hp, 400, "...Beta untouched")
  eq(draws, 2, "...the same two bytes")
  hits, draws, broke, _, beta = turn(44, 15, TWO)
  ok(broke, "44, a 15-HP doll: the second hit breaks it")
  eq(hits, "10:400 10:400", "...both hits thrown, both on the doll")
  eq(beta.hp, 400, "...Beta untouched")

  -- (c) TWINEEDLE (77): two hits, then the poison byte -- 0 here, which
  --     lands wherever it is drawn (PoisonEffect's 52).
  local NEEDLE = { 255, 0, 0 }
  hits, draws, broke, poisoned, beta = turn(77, 0, NEEDLE)
  eq(hits, "10:390 10:380 25:355", "77, no doll: two hits, then the poison's tick")
  ok(poisoned, "...the side byte 0 poisons")
  eq(draws, 3, "...crit, acc, side")
  hits, draws, broke, poisoned, beta = turn(77, 5, NEEDLE)
  ok(broke, "77, a 5-HP doll: the first hit breaks it")
  eq(hits, "10:400", "...and the move ends there: no second hit")
  ok(not poisoned and beta.status == nil, "...no poison")
  eq(draws, 2, "...and no side byte: crit, acc")
  hits, draws, broke, poisoned, beta = turn(77, 15, NEEDLE)
  ok(broke, "77, a 15-HP doll: the second hit breaks it")
  eq(hits, "10:400 10:400", "...both hits on the doll")
  ok(not poisoned and beta.status == nil, "...and the poison is gone with the effect")
  eq(draws, 2, "...no side byte")
  hits, draws, broke, poisoned, beta = turn(77, 30, NEEDLE)
  ok(not broke and beta.substitute == 10, "77, a 30-HP doll soaks both hits and stands at 10")
  ok(not poisoned and beta.status == nil, "...and PoisonEffect, reached, stops at it")
  eq(draws, 2, "...before its byte")
end

-- ------------------------------------------------------------------
-- R1a (gen12-referee-gaps-fix): the draws the cart's rules take away, on a
-- scripted generator that counts bytes and damage rolls apart.  The
-- g1_damage_tails / g1_counter / g1_pay_day / g1_leech_toxic parity
-- scenarios hold lib/battle to the same streams.
-- ------------------------------------------------------------------

do
  local Rng = BattleSim.Rng
  local function script(battle, bytes)
    local fallback = Rng.new(99)
    local log = { bytes = 0, rolls = 0 }
    battle.rng = {
      byte = function()
        log.bytes = log.bytes + 1
        local b = bytes[log.bytes]
        if b == nil then b = fallback:byte() end
        return b
      end,
      nextInt = function(_, lo, hi) return fallback:nextInt(lo, hi) end,
      damageRoll = function() log.rolls = log.rolls + 1; return 255 end,
      next = function() return fallback:next() end,
      state = function() return fallback:state() end,
    }
    return log
  end
  local function duel(o)
    local battle = assert(Turn.create({
      id = "r1a", mode = o.mode or "1v1", seed = 7, choiceTimeout = 60, reconnectGrace = 60,
      chart = o.chart, typeIds = o.typeIds,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = { o.a } } },
        b = { { playerId = "p2", name = "Bob", mons = { o.b } } },
      },
    }))
    drain(battle)
    return battle
  end
  local function play(battle, bytes, aMove, bMove)
    local log = script(battle, bytes or {})
    battle:submitChoice("p1", { action = "fight", move = aMove or 0 })
    battle:submitChoice("p2", { action = "fight", move = bMove or 0 })
    return drain(battle), log
  end
  local function hitsOn(events, slot)
    local out = {}
    for _, e in ipairs(events) do
      if e.t == "damage" and e.slot == slot then out[#out + 1] = e.amount end
    end
    return table.concat(out, " ")
  end
  local function saidIt(events, text)
    for _, e in ipairs(events) do
      if e.t == "msg" and e.text == text then return true end
    end
    return false
  end

  -- (a) RandomizeDamage's `cp 2` / `ret c` and AdjustDamageForMoveType's 0.
  --     A level-2, Attack-5 hit into Defense 200 is a base 2; Beta is types 1
  --     and 2.  Two bytes for Alpha (crit, acc), none for Beta's splash
  --     (ResidualEffects1: no MoveHitTest).
  local CHART = { { 100, 100, 100 }, { 100, 50, 100 }, { 100, 50, 50 }, { 100, 0, 100 } }
  local function tails(moveType)
    local battle = duel({ chart = CHART,
      a = { species = "Alpha", level = 2, maxHp = 60, stats = { atk = 5, def = 40, spd = 90, spc = 40 },
            types = { 0 }, baseSpd = 0, moves = { move({ id = "tap", power = 10, type = moveType }) } },
      b = { species = "Beta", maxHp = 60, stats = { atk = 40, def = 200, spd = 10, spc = 40 },
            types = { 1, 2 }, baseSpd = 0, moves = { move({ id = "splash", power = 0, effect = 85 }) } } })
    return play(battle, { 255, 0 })
  end
  local events, log = tails(1)
  eq(hitsOn(events, 3), "1", "0.5x on a base 2: the hit lands for 1")
  eq(log.rolls, 0, "...and draws no damage roll (`cp 2` / `ret c`)")
  events, log = tails(2)
  ok(saidIt(events, "Alpha's attack missed!") and hitsOn(events, 3) == "",
     "0.25x on a base 2 reaches 0: a miss (AdjustDamageForMoveType)")
  eq(log.rolls, 0, "...with no roll")
  events, log = tails(3)
  ok(saidIt(events, "It doesn't affect Beta!"), "an immunity says so")
  eq(log.rolls, 0, "...and an immunity's 0 draws no roll either")
  events, log = tails(0)
  eq(log.rolls, 1, "a STAB 3 rolls")
  eq(log.bytes, 2, "every case: crit, acc -- an immunity and a 0 still draw the accuracy byte")

  -- (b) COUNTER: the conditions first, with no draw when they fail; then
  --     the one hit test, and no crit byte and no roll.  Bob (fast) thumps
  --     for 10 (level 20, 40 / 40, power 40, roll held at 255).
  local function counterDuel(bobMove, aExtra)
    local a = { species = "Alpha", level = 20, maxHp = 400, stats = { atk = 40, def = 40, spd = 10, spc = 40 },
                types = { 1 }, baseSpd = 0,
                moves = { move({ id = "COUNTER", power = 1, type = 1 }) } }
    for k, v in pairs(aExtra or {}) do a[k] = v end
    return duel({
      a = a,
      b = { species = "Beta", level = 20, maxHp = 400, stats = { atk = 40, def = 40, spd = 90, spc = 40 },
            types = { 1 }, baseSpd = 0, moves = { bobMove } } })
  end
  local battle = counterDuel(move({ id = "thump", power = 40 }))
  events, log = play(battle, { 255, 0, 255, 0 })
  eq(hitsOn(events, 3), "20", "COUNTER returns twice the 10")
  eq(log.bytes, 4, "...Bob's crit and acc, then COUNTER's crit byte and its one hit test")
  eq(log.rolls, 1, "...and only Bob's roll")
  eq(battle.lastDamage, 20, "wDamage now holds the 20")
  battle = counterDuel(move({ id = "flame", power = 40, type = 2 }))
  events, log = play(battle, { 255, 0 })
  ok(saidIt(events, "Alpha's attack missed!"), "a type-2 hit is not countered")
  eq(log.bytes, 3, "...and COUNTER drew only its crit byte (CriticalHitTest comes first)")
  battle = counterDuel(move({ id = "thump", power = 40 }), { substitute = 50 })
  events = play(battle, { 255, 0, 255, 0 })
  eq(hitsOn(events, 3), "20", "a hit Alpha's doll soaked is countered whole")

  -- (c) Pay Day: the pile on a wild win; nothing in a link fight.
  local function payDuel(mode)
    local battle = duel({ mode = mode,
      a = { species = "Alpha", level = 20, maxHp = 400, stats = { atk = 40, def = 40, spd = 90, spc = 40 },
            types = { 1 }, baseSpd = 0, moves = { move({ id = "coin", power = 40, effect = 16 }) } },
      b = { species = "Beta", level = 20, hp = 10, maxHp = 400, stats = { atk = 40, def = 40, spd = 10, spc = 40 },
            types = { 1 }, baseSpd = 0, moves = { move({ id = "splash", power = 0, effect = 85 }) } } })
    play(battle, { 255, 0 })
    return battle:outcome()
  end
  local won = payDuel("wild")
  eq(won and won.payDay, 40, "a wild win reports level x 2 = 40 (PayDayEffect_)")
  local link = payDuel("1v1")
  eq(link and link.payDay, nil, "a link win reports no Pay Day")

  -- (d) LEECH SEED x the toxic counter (HandlePoisonBurnLeechSeed_DecreaseOwnHP
  --     runs the counter for the seed tick too), and the seeder's whole share.
  battle = duel({
    a = { species = "Alpha", level = 20, hp = 300, maxHp = 400, stats = { atk = 40, def = 40, spd = 90, spc = 40 },
          types = { 1 }, baseSpd = 0, moves = { move({ id = "splash", power = 0, effect = 85 }) } },
    b = { species = "Beta", level = 20, maxHp = 400, status = "TOX", stats = { atk = 40, def = 40, spd = 10, spc = 40 },
          types = { 1 }, baseSpd = 0, leechSeed = { fromSlot = 0 },
          moves = { move({ id = "splash", power = 0, effect = 85 }) } } })
  events = play(battle, { 0, 0 })
  eq(hitsOn(events, 3), "25 50", "toxic x1, then the seed x2")
  eq(activeMonOf(battle, "p1").hp, 350, "...the seeder gets the 50")
  eq(activeMonOf(battle, "p2").toxicCounter, 3, "...and the counter went up twice")

  -- (e) AlwaysHappenSideEffects against a 200-HP doll that holds: the drain
  --     heals half the whole hit (DrainHPEffect_ halves wDamage), STRUGGLE's
  --     recoil is half of it (RecoilEffect_ `cp STRUGGLE`) off the user's own
  --     HP, never its own doll.  The hit is 10 (roll held at 255).
  local function intoDoll(moves, aExtra)
    local a = { species = "Alpha", level = 20, hp = 300, maxHp = 400,
                stats = { atk = 40, def = 40, spd = 90, spc = 40 }, types = { 1 }, baseSpd = 0,
                moves = moves }
    for k, v in pairs(aExtra or {}) do a[k] = v end
    local b = duel({ a = a,
      b = { species = "Beta", level = 20, maxHp = 400, substitute = 200,
            stats = { atk = 40, def = 40, spd = 10, spc = 40 }, types = { 1 }, baseSpd = 0,
            moves = { move({ id = "splash", power = 0, effect = 85 }) } } })
    play(b, { 255, 0 })
    return activeMonOf(b, "p1")
  end
  eq(intoDoll({ move({ id = "leech", power = 40, effect = 3 }) }).hp, 305,
     "a drain into a holding doll heals 5 of the 10")
  local strug = intoDoll({ move({ id = "thump", power = 40, pp = 0 }) }, { substitute = 30 })
  eq(strug.hp, 294, "STRUGGLE (power 50: 12) into the doll: half, 6, off Alpha's HP")
  eq(strug.substitute, 30, "...never Alpha's own doll")

  -- (f) RAGE pays its PP once (DecrementPP returns while USING_RAGE);
  --     "<MON>'s RAGE is building!" heads every build.  (The g1_rage_thrash_pp
  --     scenario holds RAGE at 0 PP to RAGE.)
  battle = duel({
    a = { species = "Alpha", level = 20, maxHp = 400, stats = { atk = 40, def = 40, spd = 90, spc = 40 },
          types = { 1 }, baseSpd = 0, moves = { move({ id = "RAGE", power = 20, effect = 81, pp = 2 }) } },
    b = { species = "Beta", level = 20, maxHp = 400, stats = { atk = 40, def = 40, spd = 10, spc = 40 },
          types = { 1 }, baseSpd = 0, moves = { move({ id = "thump", power = 10 }) } } })
  for turn = 1, 2 do
    events = play(battle, { 255, 0, 255, 0 })
    ok(saidIt(events, "Alpha used RAGE!"), "turn " .. turn .. ": RAGE")
    ok(saidIt(events, "Alpha's RAGE is building!"), "turn " .. turn .. ": the building line")
  end
  eq(activeMonOf(battle, "p1").moves[1].pp, 1, "one PP spent over both turns")

  -- (g) Pay Day's pile is both sides': the computer's coins are picked up too.
  battle = duel({ mode = "wild",
    a = { species = "Alpha", level = 20, maxHp = 400, stats = { atk = 40, def = 40, spd = 90, spc = 40 },
          types = { 1 }, baseSpd = 0, moves = { move({ id = "coin", power = 40, effect = 16 }) } },
    b = { species = "Beta", level = 30, hp = 15, maxHp = 400, stats = { atk = 40, def = 40, spd = 10, spc = 40 },
          types = { 1 }, baseSpd = 0, moves = { move({ id = "coin", power = 10, effect = 16 }) } } })
  play(battle, { 255, 0, 255, 0 })
  play(battle, { 255, 0 })
  eq(battle:outcome() and battle:outcome().payDay, 140, "2 x 40 of Alpha's + 60 of Beta's")

  -- (h) A METRONOME that called FLY lands FLY on the next turn.
  battle = assert(Turn.create({ id = "r1am", mode = "1v1", seed = 7, choiceTimeout = 60,
    reconnectGrace = 60, metronomePool = { move({ id = "FLY", power = 90, effect = 43 }) },
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { { species = "Alpha", level = 20, maxHp = 400,
        stats = { atk = 40, def = 40, spd = 90, spc = 40 }, types = { 1 }, baseSpd = 0,
        moves = { move({ id = "METRONOME", power = 0, effect = 83 }) } } } } },
      b = { { playerId = "p2", name = "Bob", mons = { { species = "Beta", level = 20, maxHp = 400,
        stats = { atk = 40, def = 40, spd = 10, spc = 40 }, types = { 1 }, baseSpd = 0,
        moves = { move({ id = "splash", power = 0, effect = 85 }) } } } } },
    } }))
  drain(battle)
  play(battle, { 0, 0, 0 })
  events = play(battle, { 255, 0, 0 })
  ok(saidIt(events, "Alpha used FLY!") and not saidIt(events, "Alpha used METRONOME!"),
     "the release is FLY, not a second METRONOME")
  eq(hitsOn(events, 3) ~= "", true, "...and it lands")
  -- The release is PlayerCanExecuteMove's: DecrementPP on wPlayerMoveListIndex
  -- -- METRONOME's slot -- a second time (R1d) -- but the call itself gave
  -- one back: ReloadMoveData's IncrementMovePP, which the called charge's
  -- ChargeEffect never spent again (R1e).  One PP net, as any call.
  eq(activeMonOf(battle, "p1").moves[1].pp, 19,
     "METRONOME paid at the call, refunded by ReloadMoveData, paid at the release (20 -> 19)")
end

-- ------------------------------------------------------------------
-- R1b (gen12-referee-gaps-fix wave 2): each rule against pokered on a
-- scripted generator that counts bytes and damage rolls apart.  The g1_*
-- `fights` parity scenarios (tests/drivers/battle_turn_parity.lua) hold
-- lib/battle to the same streams.
-- ------------------------------------------------------------------

do
  local Rng = BattleSim.Rng
  local Effects = BattleSim.Effects
  local function script(battle, bytes)
    local fallback = Rng.new(99)
    local log = { bytes = 0, rolls = 0 }
    battle.rng = {
      byte = function()
        log.bytes = log.bytes + 1
        local b = bytes[log.bytes]
        if b == nil then b = fallback:byte() end
        return b
      end,
      nextInt = function(_, lo, hi) return fallback:nextInt(lo, hi) end,
      damageRoll = function() log.rolls = log.rolls + 1; return 255 end,
      next = function() return fallback:next() end,
      state = function() return fallback:state() end,
    }
    return log
  end
  local function mv(id, power, effect, o)
    o = o or {}
    local m = move({ id = id, power = power, effect = effect or 0, pp = o.pp or 60,
                     accuracy = o.accuracy, type = o.type, chance = o.chance })
    if o.ppUps then m.ppUps = o.ppUps end
    return m
  end
  local SPL = function() return mv("splash", 0, 85) end
  -- A sheet: mon()'s defaults, base Speed 0 (no crits), and raw extras.
  local function sh(o, extra)
    local raw = mon(o)
    raw.baseSpd = o.baseSpd or 0
    for k, v in pairs(extra or {}) do raw[k] = v end
    return raw
  end
  local function duel(o)
    local battle = assert(Turn.create({
      id = "r1b", mode = o.mode or "1v1", seed = o.seed or 7, choiceTimeout = 60,
      reconnectGrace = 60, chart = o.chart, typeIds = o.typeIds, metronomePool = o.pool,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = o.aMons or { o.a }, bag = o.aBag,
                badges = o.aBadges } },
        b = { { playerId = "p2", name = "Bob", mons = o.bMons or { o.b }, bag = o.bBag } },
      },
    }))
    drain(battle)
    return battle
  end
  local function play(battle, bytes, aChoice, bChoice)
    local log = script(battle, bytes or {})
    local function c(x)
      if type(x) == "number" then return { action = "fight", move = x } end
      return x
    end
    if aChoice ~= false then battle:submitChoice("p1", c(aChoice or 0)) end
    if bChoice ~= false then battle:submitChoice("p2", c(bChoice or 0)) end
    if battle.forcedPending then battle:tick(battle.now) end
    return drain(battle), log
  end
  local function said(events, text)
    for _, e in ipairs(events) do
      if e.t == "msg" and e.text == text then return true end
    end
    return false
  end
  local function texts(events)
    local out = {}
    for _, e in ipairs(events) do if e.t == "msg" then out[#out + 1] = e.text end end
    return out
  end
  local function indexOf(list, text)
    for i, v in ipairs(list) do if v == text then return i end end
    return nil
  end
  local function hits(events, slot)
    local out = {}
    for _, e in ipairs(events) do
      if e.t == "damage" and e.slot == slot then out[#out + 1] = e.amount end
    end
    return table.concat(out, " ")
  end
  local alpha = function(b) return activeMonOf(b, "p1") end
  local beta = function(b) return activeMonOf(b, "p2") end

  -- (a) StatModifierDownEffect's primary (effects.asm :539-562): the
  --     computer's extra miss byte first, then the doll and MoveHitTest --
  --     Mist and X Accuracy before its accuracy byte.
  local function growlDuel(mode, aExtra, bExtra)
    return duel({ mode = mode,
      a = sh({ species = "Alpha", spd = 10, moves = { SPL() } }, aExtra),
      b = sh({ species = "Beta", spd = 90, moves = { mv("growl", 0, 18) } }, bExtra) })
  end
  local events, log = play(growlDuel("wild"), { 63 })
  ok(said(events, "But, it failed!") and alpha and true, "the computer's growl: byte 63 is the 25% miss")
  eq(log.bytes, 1, "...the miss byte alone: no accuracy byte, and Alpha's splash draws none")
  local b = growlDuel("wild")
  events, log = play(b, { 64, 0 })
  eq(alpha(b).stages.atk, -1, "byte 64 passes the miss, the accuracy byte 0 hits")
  eq(log.bytes, 2, "...two bytes")
  b = growlDuel("1v1")
  events, log = play(b, { 0 })
  eq(alpha(b).stages.atk, -1, "a link fight: no miss byte")
  eq(log.bytes, 1, "...the accuracy byte alone")
  events, log = play(growlDuel("wild", { mist = true }), { 64 })
  ok(said(events, "But, it failed!"), "into Mist: MoveHitTest's miss")
  eq(log.bytes, 1, "...the computer's miss byte, then nothing: Mist is before the accuracy byte")
  b = duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("growl", 0, 18) } }),
             b = sh({ species = "Beta", spd = 10, moves = { SPL() } }, { substitute = 30 }) })
  events, log = play(b, {})
  ok(said(events, "But, it failed!") and beta(b).stages.atk == 0, "into a doll: But it failed")
  eq(log.bytes, 0, "...before any byte")
  b = duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("growl", 0, 18) } }, { xAccuracy = true }),
             b = sh({ species = "Beta", spd = 10, moves = { SPL() } }) })
  events, log = play(b, {})
  eq(beta(b).stages.atk, -1, "X Accuracy: the drop lands")
  eq(log.bytes, 0, "...with no accuracy byte (MoveHitTest's `ret nz`)")
  -- The walls: -6 and +6 are "Nothing happened!" for a primary.
  b = duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("growl", 0, 18), mv("dance", 0, 50) },
                      stages = { atk = 6 } }),
             b = sh({ species = "Beta", spd = 10, moves = { SPL() }, stages = { atk = -6 } }) })
  events = play(b, { 0 })
  ok(said(events, "Nothing happened!"), "a primary drop at -6: Nothing happened")
  events = play(b, {}, 1)
  ok(said(events, "Nothing happened!"), "a primary raise at +6: Nothing happened")
  -- K10: the signed stage rides the stat event.
  b = growlDuel("1v1")
  events = play(b, { 0 })
  local stage = nil
  for _, e in ipairs(events) do if e.t == "stat" then stage = e.stage end end
  eq(stage, -1, "the stat event carries the signed stage")

  -- (b) PoisonEffect's primary (effects.asm :78-162): a Poison type, a status
  --     and a doll turn it away before MoveHitTest; TOXIC badly poisons.
  local function powder(id, bExtra, typeIds)
    return duel({ typeIds = typeIds or { "NORMAL", "POISON" },
      a = sh({ species = "Alpha", spd = 90, moves = { mv(id, 0, 66) } }),
      b = sh({ species = "Beta", spd = 10, types = { 1 }, moves = { SPL() } }, bExtra) })
  end
  b = powder("powder")
  events, log = play(b, {})
  ok(said(events, "It didn't affect Beta!") and beta(b).status == nil, "a Poison-type target: It didn't affect")
  eq(log.bytes, 0, "...before the accuracy byte")
  b = powder("powder", { types = { 0 }, status = "BRN" })
  events, log = play(b, {})
  ok(said(events, "It didn't affect Beta!") and log.bytes == 0, "an already-statused target: the same")
  b = powder("powder", { types = { 0 }, substitute = 20 })
  events, log = play(b, {})
  ok(said(events, "It didn't affect Beta!") and log.bytes == 0, "a doll: the same")
  b = powder("TOXIC", { types = { 0 } })
  events, log = play(b, { 0 })
  ok(said(events, "Beta's badly poisoned!") and beta(b).status == "toxic", "TOXIC badly poisons")
  eq(log.bytes, 1, "...on its accuracy byte")
  b = powder("powder", { types = { 0 } })
  events = play(b, { 255 })
  ok(said(events, "It didn't affect Beta!"), "a miss says It didn't affect too (`.didntAffect`)")

  -- (c) DisableEffect (effects.asm :1286-1367).
  local function lock(bMoves, mode, bExtra, aMoves)
    return duel({ mode = mode,
      a = sh({ species = "Alpha", spd = 90, moves = aMoves or { mv("lock", 0, 86), SPL() } }),
      b = sh({ species = "Beta", spd = 10, moves = bMoves }, bExtra) })
  end
  local THREE = function() return { mv("thump", 10, 0), mv("chop", 10, 0), mv("slam", 10, 0) } end
  b = lock(THREE())
  events, log = play(b, { 0, 1, 7 })
  ok(said(events, "Beta's chop was disabled!"), "the slot is BattleRandom & 3: byte 1 is slot 2")
  eq(beta(b).disable and beta(b).disable.turns, 7, "8 steps (& 7 + 1), the first taken in Beta's own turn")
  eq(log.bytes, 5, "...acc, slot, count, then Beta's thump (crit, acc)")
  b = lock(THREE())
  play(b, { 0, 3, 1, 7 })
  eq(beta(b).disable and beta(b).disable.moveIndex, 2, "slot 4 holds no move: redrawn")
  b = lock({ mv("thump", 10, 0, { pp = 0 }), mv("chop", 10, 0, { pp = 0, ppUps = 1 }), mv("slam", 10, 0) })
  events, log = play(b, { 0, 0, 1, 7 }, nil, 2)
  eq(beta(b).disable and beta(b).disable.moveIndex, 2,
     "the player's target: a bare 0-PP slot is redrawn, a 0-PP slot with PP Ups is taken (the raw byte)")
  b = lock({ mv("thump", 10, 0, { pp = 0 }), mv("chop", 10, 0, { pp = 0 }) }, "wild")
  events, log = play(b, { 0, 0, 7 })
  eq(beta(b).disable and beta(b).disable.moveIndex, 1, "the computer's target: its PP is never read")
  b = lock(THREE())
  events, log = play(b, { 255 })
  ok(said(events, "But, it failed!") and beta(b).disable == nil, "a miss: But it failed")
  b = lock(THREE(), nil, { disable = { moveIndex = 2, turns = 3 } })
  events = play(b, { 0 })
  ok(said(events, "But, it failed!"), "a target already disabled: But it failed")
  b = lock(THREE(), nil, { substitute = 20 })
  play(b, { 0, 0, 7 })
  ok(beta(b).disable ~= nil, "a doll does not stop it")
  -- `.AnyMoveDisabledCheck` steps in the monster's own turn; the step to 0
  -- frees the move that very turn.
  -- (The menu refuses the disabled slot, so Beta picks CHOP.)
  b = lock(THREE(), nil, { disable = { moveIndex = 1, turns = 1 } }, { SPL() })
  events = play(b, {}, 0, 1)
  local t = texts(events)
  ok(indexOf(t, "Beta's disabled no more!") and indexOf(t, "Beta used chop!")
     and indexOf(t, "Beta's disabled no more!") < indexOf(t, "Beta used chop!"),
     "the last step comes in Beta's own turn, before its move")
  ok(beta(b).disable == nil, "...and lifts it")

  -- (d) CheckPlayerStatusConditions' order: confusion before paralysis; a
  --     sleeping monster's flinch waits; full paralysis drops the thrash and
  --     the charge but not the vanish.
  local function dazed(extra)
    return duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("thump", 10, 0) },
                           status = "PAR", confusion = 4 }, extra),
                  b = sh({ species = "Beta", spd = 10, moves = { SPL() } }) })
  end
  -- (R1e: `cp 50 percent + 1 / jr c` jumps past the self-hit below 128.)
  events, log = play(dazed(), { 255 })
  ok(said(events, "It hurt itself in its confusion!"), "a confusion byte of 255 is the self-hit")
  eq(log.bytes, 1, "...and no paralysis byte follows it")
  events, log = play(dazed(), { 127, 0 })
  ok(said(events, "Alpha's fully paralyzed!"), "past confusion, the paralysis byte 0 stops it")
  eq(log.bytes, 2, "...confusion's byte, then paralysis'")
  b = duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("thump", 10, 0) }, status = "SLP" },
                    { statusTurns = 3, flinch = true }),
             b = sh({ species = "Beta", spd = 10, moves = { SPL() } }) })
  -- (the turn's open reset the sheet's flinch; set one the open cannot see)
  alpha(b).flinch = true
  events, log = play(b, { 0 })
  ok(said(events, "Alpha is fast asleep!") and not said(events, "Alpha flinched!"),
     "asleep and flinched: the sleep check comes first")
  eq(alpha(b).statusTurns, 2, "...and the sleep counter ticks")
  b = duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("THRASH", 30, 27) }, status = "PAR" },
                    { thrashing = { turns = 2, moveIndex = 1 } }),
             b = sh({ species = "Beta", spd = 10, moves = { SPL() } }) })
  events = play(b, { 0 }, false)
  ok(alpha(b).thrashing == nil and alpha(b).confusion == 0, "full paralysis ends the thrash, unconfused")
  b = duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("FLY", 90, 43) }, status = "PAR" },
                    { charging = { moveIndex = 1, effect = 43, targetSlot = 3, moveId = "FLY" },
                      invulnerable = true }),
             b = sh({ species = "Beta", spd = 10, moves = { mv("thump", 10, 0) } }) })
  events = play(b, { 0 }, false)
  ok(alpha(b).charging == nil and alpha(b).invulnerable == true,
     "full paralysis drops the charge and keeps INVULNERABLE (the FLY glitch)")
  -- (R1c: MoveHitTest's INVULNERABLE miss prints PrintMoveFailureText's
  -- "<USER>'s attack missed!".)
  ok(said(events, "Beta's attack missed!"), "...so Beta's thump still finds nobody")

  -- (e) SpecialEffectsCont before the hit test: a THRASH that misses still
  --     thrashes; a Wrap that misses takes its trap back but has already
  --     cleared the target's recharge.
  b = duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("THRASH", 30, 27, { accuracy = 0 }) } }),
             b = sh({ species = "Beta", spd = 10, moves = { SPL() } }) })
  events, log = play(b, { 0, 255 })
  ok(said(events, "Alpha's attack missed!") and alpha(b).thrashing ~= nil, "a missed THRASH thrashes on")
  eq(alpha(b).thrashing.turns, 2, "...its counter (byte & 1, + 2) drawn before the accuracy byte")
  b = duel({ a = sh({ species = "Alpha", spd = 10, moves = { mv("wrap", 15, 42, { accuracy = 0 }) } }),
             b = sh({ species = "Beta", spd = 90, moves = { SPL() } }, { mustRecharge = true }) })
  beta(b).mustRecharge = true
  events, log = play(b, { 0, 255 })
  ok(beta(b).trapped == nil and alpha(b).trapping == nil, "a missed Wrap holds nobody")
  eq(beta(b).mustRecharge, false, "...but ClearHyperBeam ran first")
  eq(log.bytes, 3, "...the count byte, the crit byte, then the accuracy byte")
  b = duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("wrap", 15, 42) } }),
             b = sh({ species = "Beta", spd = 10, moves = { SPL() } }) })
  play(b, { 2, 3, 255, 0 })
  -- The next turn: both players answer the battle menu's FIGHT (R1d), the
  -- continuation and CANNOT_MOVE.
  play(b, {})
  eq(beta(b).trapped and beta(b).trapped.turns, 3,
     "a count byte of 2 redraws: 3 & 3 is 3, 5 attacks -- this one and the next, then 3")

  -- (f) OneHitKOEffect_ lands on a Speed tie; the set-damage moves draw no
  --     crit and no roll and pass the chart; JUMP KICK crashes for 1.
  b = duel({ a = sh({ species = "Alpha", spd = 40, moves = { mv("drill", 1, 38) } }),
             b = sh({ species = "Beta", spd = 40, moves = { SPL() } }) })
  events = play(b, { 0, 255, 0 })
  eq(beta(b), nil, "a tie: the OHKO lands")
  local function toss(id, level, effect)
    local m = mv(id, 1, effect or 41, { type = 1 })
    m.name = (id:gsub("_", " "))             -- Wire's text filter drops `_`
    return duel({ chart = { { 100, 0 }, { 100, 0 } },
      a = sh({ species = "Alpha", level = level, spd = 90, moves = { m } }),
      b = sh({ species = "Beta", spd = 10, types = { 1 }, maxHp = 400, moves = { SPL() } }) })
  end
  b = toss("SEISMIC_TOSS", 30)
  events, log = play(b, { 0 })
  eq(hits(events, 3), "30", "SEISMIC TOSS: the level, through a 0x chart")
  eq(log.bytes .. "/" .. log.rolls, "1/0", "...the accuracy byte, no crit byte, no roll")
  events = play(toss("SONICBOOM", 30), { 0 })
  eq(hits(events, 3), "20", "SONICBOOM: 20, whatever the power")
  events = play(toss("DRAGON_RAGE", 30), { 0 })
  eq(hits(events, 3), "40", "DRAGON RAGE: 40")
  events, log = play(toss("PSYWAVE", 30), { 0, 0, 45, 44 })
  eq(hits(events, 3), "44", "PSYWAVE: redrawn past 0 and 45 (level x 1.5), 44 kept")
  eq(log.bytes, 4, "...acc, then the loop's three")
  events = play(toss("fang", 30, 40), { 0 })
  eq(hits(events, 3), "200", "SUPER FANG: half the HP")
  b = duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("leap", 70, 45, { accuracy = 0 }) } }),
             b = sh({ species = "Beta", spd = 10, moves = { SPL() } }) })
  events = play(b, { 255 })
  ok(said(events, "Alpha kept going and crashed!") and alpha(b).hp == alpha(b).maxHp - 1,
     "a missed JUMP KICK: 1 HP")

  -- (g) Haze cures the target's status only; a frozen target loses its move.
  b = duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("haze", 0, 25) }, status = "BRN" }),
             b = sh({ species = "Beta", spd = 10, moves = { mv("thump", 10, 0) }, status = "FRZ" },
                    { confusion = 3, mist = true }) })
  events = play(b, {})
  ok(beta(b).status == nil and beta(b).confusion == 0 and not beta(b).mist, "Haze: the target is cured")
  eq(alpha(b).status, "burn", "...the user's status stays")
  ok(not said(events, "Beta used thump!"), "...and the thawed target does not move")

  -- (h) The toxic flag outlives a disobedience nap (`toxicLinger`): the
  --     seed then takes its sixteenth times the counter.  A traded level-50
  --     Alpha with no badges: bytes 225 / 30 pass both obedience loops, 16
  --     naps, 8 sets the nap's turns (CheckForDisobedience's arithmetic).
  b = duel({ mode = "wild",
             a = sh({ species = "Alpha", level = 50, spd = 90, maxHp = 400, moves = { mv("thump", 10, 0) },
                      status = "TOX" }, { traded = true, toxicCounter = 3, leechSeed = { fromSlot = 3 } }),
             b = sh({ species = "Beta", spd = 10, moves = { SPL() } }) })
  events = play(b, { 225, 30, 16, 8 })
  ok(said(events, "Alpha began to nap!") and alpha(b).status == "sleep", "the nap")
  eq(alpha(b).toxicLinger, true, "...and the Bad Poison bit outlives it")
  eq(hits(events, 0), "75", "the seed takes 25 x the counter 3")
  eq(alpha(b).toxicCounter, 4, "...and climbs")

  -- (i) Asleep, the selection is last turn's: a QUICK ATTACK chosen in the
  --     menu moves in last turn's bracket.
  b = duel({ a = sh({ species = "Alpha", spd = 10, moves = { mv("tap", 10, 0), mv("QUICK_ATTACK", 10, 0) } }),
             b = sh({ species = "Beta", spd = 90, moves = { mv("lull", 0, 32), mv("thump", 10, 0) } }) })
  play(b, { 0, 3 }, 0, 0)
  events = play(b, { 0, 0, 0 }, 1, 1)
  t = texts(events)
  ok(indexOf(t, "Beta used thump!") < indexOf(t, "Alpha is fast asleep!"),
     "an asleep QUICK ATTACK moves in tap's bracket: Beta first")

  -- (j) AnyMoveToSelect with a move disabled reads the raw bytes.
  b = duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("tap", 10, 0, { pp = 0, ppUps = 1 }),
                                                             mv("chop", 10, 0) } },
                    { disable = { moveIndex = 2, turns = 4 } }),
             b = sh({ species = "Beta", spd = 10, moves = { SPL() } }) })
  eq(b:submitChoice("p1", { action = "fight", move = 0 }), false, "a 0-PP slot with PP Ups: no Struggle, refused")
  eq(b:submitChoice("p1", { action = "fight", move = 1 }), false, "...and the disabled one too")

  -- (k) The computer's item in its slot: Alpha's hit, then the potion.
  b = duel({ mode = "coop_npc", bBag = { SUPER_POTION = 1 },
             a = sh({ species = "Alpha", spd = 90, moves = { mv("tap", 20, 0) } }),
             b = sh({ species = "Beta", spd = 10, hp = 100, maxHp = 400, moves = { SPL() } }) })
  events = play(b, {}, 0, { action = "item", item = "SUPER_POTION" })
  local order = {}
  for _, e in ipairs(events) do
    if e.t == "damage" or e.t == "item" then order[#order + 1] = e.t end
  end
  eq(table.concat(order, " "), "damage item", "the trainer's potion comes in its own slot, after Alpha's hit")
  b = duel({ a = sh({ species = "Alpha", spd = 90, moves = { mv("tap", 20, 0) } }), bBag = { SUPER_POTION = 1 },
             b = sh({ species = "Beta", spd = 10, hp = 100, maxHp = 400, moves = { SPL() } }) })
  events = play(b, {}, 0, { action = "item", item = "SUPER_POTION" })
  order = {}
  for _, e in ipairs(events) do
    if e.t == "damage" or e.t == "item" then order[#order + 1] = e.t end
  end
  eq(table.concat(order, " "), "item damage", "a player's item (a link fight) resolves before the moves")

  -- (l) "Hit the enemy N times!" for the player, "Hit N times!" for the
  --     computer.
  b = duel({ mode = "wild",
             a = sh({ species = "Alpha", spd = 90, moves = { mv("kicks", 20, 44) } }),
             b = sh({ species = "Beta", spd = 10, moves = { mv("kicks", 20, 44) } }) })
  events = play(b, { 255, 0, 255, 0 })
  ok(said(events, "Hit the enemy 2 times!") and said(events, "Hit 2 times!"), "both lines, by seat")

  -- (m) K9: the rebuild, and what is refused.
  b = duel({ mode = "wild", aBadges = { BOULDERBADGE = true },
             aMons = { sh({ species = "Alpha", spd = 90, atk = 60, maxHp = 60, hp = 30,
                            moves = { mv("tap", 10, 0) }, status = "BRN" }) },
             b = sh({ species = "Beta", spd = 10, moves = { SPL() } }) })
  eq(b:levelUp("p1", 1, 21, { atk = 64, def = 41, spd = 91, spc = 41 }, 62), true, "a plausible level-up is taken")
  eq(alpha(b).level .. "/" .. alpha(b).maxHp .. "/" .. alpha(b).hp, "21/62/32", "level, max HP, HP + 2")
  eq(alpha(b).partyStats.atk, 64, "the party stat")
  eq(alpha(b).cur.atk, 36, "battle Attack: 64, halved by the burn (32), x9/8 (36)")
  eq(b:levelUp("p1", 1, 21, { atk = 65, def = 41, spd = 91, spc = 41 }, 62), false, "the same level again: refused")
  eq(b:levelUp("p1", 1, 22, { atk = 63, def = 41, spd = 91, spc = 41 }, 62), false, "a stat that fell: refused")
  eq(b:levelUp("p2", 1, 21, nil, nil), false, "the computer's seat: refused")
  eq(b:levelUp("p1", 9, 30, nil, nil), false, "no such monster: refused")
  eq(b:levelUp("p1", 1, "x", {}, nil), false, "nonsense: refused, never raised")
  eq(Effects.calcStat(70, 9, 30, nil, false), 52, "CalcStat, no stat exp: ((70 + 9) x 2 x 30 / 100) + 5")
  eq(Effects.calcStat(45, 0, 16, 0, true), 40, "...and HP: + level + 10")
  eq(Effects.calcStat(255, 15, 100, 65535, false), 608, "...full stat exp adds floor(255 / 4)")
end

-- ------------------------------------------------------------------
-- R1c (gen12-referee-gaps-fix wave 3): the draw points and turn shapes R1b
-- left as referee conventions, against pokered, on a scripted generator that
-- counts bytes and damage rolls apart.  The g1_draw_order, g1_computer_pp,
-- g1_doll_status, g1_sleep_effect, g1_mimic, g1_already_up, g1_teleport,
-- g1_trap_turns, g1_tie_actions, g1_toxic_bench and g1_pay_day_faint parity
-- scenarios (tests/drivers/battle_turn_parity.lua) hold lib/battle to the same
-- streams.
-- ------------------------------------------------------------------

do
  local Rng = BattleSim.Rng
  local function script(battle, bytes)
    local fallback = Rng.new(99)
    local log = { bytes = 0, rolls = 0 }
    battle.rng = {
      byte = function()
        log.bytes = log.bytes + 1
        local b = bytes[log.bytes]
        if b == nil then b = fallback:byte() end
        return b
      end,
      nextInt = function(_, lo, hi) return fallback:nextInt(lo, hi) end,
      damageRoll = function() log.rolls = log.rolls + 1; return 255 end,
      next = function() return fallback:next() end,
      state = function() return fallback:state() end,
    }
    return log
  end
  local function mv(id, power, effect, o)
    o = o or {}
    local m = move({ id = id, power = power, effect = effect, accuracy = o.accuracy,
                     type = o.type, pp = o.pp or 60 })
    return m
  end
  local function sheet(o)
    local raw = mon(o)
    raw.baseSpd = o.baseSpd or 0
    for k, v in pairs(o.extra or {}) do raw[k] = v end
    return raw
  end
  local function duel(o)
    local battle = assert(Turn.create({
      id = "r1c", mode = o.mode or "1v1", seed = 7, choiceTimeout = 60, reconnectGrace = 60,
      chart = o.chart, typeIds = o.typeIds,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = o.a } },
        b = { { playerId = "p2", name = "Bob", mons = o.b } },
      },
    }))
    drain(battle)
    return battle
  end
  -- One turn on scripted bytes.  A turn forced on every seat resolves on the
  -- clock, and only when `aChoice` / `bChoice` are both false (the caller
  -- asking for exactly that turn).
  local function play(battle, bytes, aChoice, bChoice)
    local log = script(battle, bytes or {})
    if aChoice ~= false then
      battle:submitChoice("p1", type(aChoice) == "table" and aChoice or { action = "fight", move = aChoice or 0 })
    end
    if bChoice ~= false then
      battle:submitChoice("p2", type(bChoice) == "table" and bChoice or { action = "fight", move = bChoice or 0 })
    end
    if aChoice == false and bChoice == false and battle.forcedPending then battle:tick(battle.now) end
    return drain(battle), log
  end
  local function said(events, text)
    for _, e in ipairs(events) do if e.t == "msg" and e.text == text then return true end end
    return false
  end
  local SPL = function() return mv("splash", 0, 85) end
  local function alpha(b) return activeMonOf(b, "p1") end
  local function beta(b) return activeMonOf(b, "p2") end

  -- (a) PlayerCalcMoveDamage: CriticalHitTest's byte first, RandomizeDamage's
  --     roll, MoveHitTest's byte last.  Alpha's base Speed 255 crits on a 0
  --     (`rlc` x3 of 0 under 127); an accuracy-128 tap misses on a 200.
  local b = duel({ a = { sheet({ species = "Alpha", spd = 90, baseSpd = 255,
                               moves = { mv("tap", 40, 0, { accuracy = 128 }) } }) },
                   b = { sheet({ species = "Beta", maxHp = 400, spd = 10, moves = { SPL() } }) } })
  local events, log = play(b, { 0, 200 })
  ok(said(events, "Alpha's attack missed!") and not said(events, "Critical hit!"),
     "a crit byte of 0 then an accuracy byte of 200: the miss, no crit line")
  eq(log.bytes .. "/" .. log.rolls, "2/1", "...the crit byte, the roll and the accuracy byte all drawn")
  b = duel({ a = { sheet({ species = "Alpha", spd = 90, baseSpd = 255,
                         moves = { mv("tap", 40, 0, { accuracy = 128 }) } }) },
             b = { sheet({ species = "Beta", maxHp = 400, spd = 10, moves = { SPL() } }) } })
  events = play(b, { 0, 100 })
  ok(said(events, "Critical hit!"), "byte 0 then 100: the crit lands, read from the first byte")

  -- (b) Sleep and freeze read no byte; the confusion check none on its
  --     snap-out turn.
  b = duel({ a = { sheet({ species = "Alpha", spd = 90, status = "SLP", extra = { statusTurns = 3 } }) },
             b = { sheet({ species = "Beta", spd = 10, status = "FRZ" }) } })
  events, log = play(b, {})
  eq(log.bytes, 0, "a sleeping and a frozen battler draw nothing")
  b = duel({ a = { sheet({ species = "Alpha", spd = 90, confusion = 1, moves = { SPL() } }) },
             b = { sheet({ species = "Beta", spd = 10, moves = { SPL() } }) } })
  events, log = play(b, {})
  ok(said(events, "Alpha's confused no more!") and log.bytes == 0, "the snap-out turn draws no byte")
  b = duel({ a = { sheet({ species = "Alpha", spd = 90, confusion = 2, moves = { SPL() } }) },
             b = { sheet({ species = "Beta", spd = 10, moves = { SPL() } }) } })
  events, log = play(b, { 200 })
  eq(log.bytes, 1, "a monster still confused draws its self-hit byte")

  -- (c) DREAM EATER into a waking target: crit and roll, then MoveHitTest's
  --     sleep check -- no accuracy byte; an immunity still draws one.
  b = duel({ a = { sheet({ species = "Alpha", spd = 90, moves = { mv("dream", 40, 8) } }) },
             b = { sheet({ species = "Beta", spd = 10, moves = { SPL() } }) } })
  events, log = play(b, {})
  ok(said(events, "Alpha's attack missed!"), "DREAM EATER misses an awake target")
  eq(log.bytes .. "/" .. log.rolls, "1/1", "...on its crit byte and its roll alone")
  b = duel({ chart = { { 100, 0 }, { 100, 100 } },
             a = { sheet({ species = "Alpha", spd = 90, types = { 0 }, moves = { mv("tap", 40, 0) } }) },
             b = { sheet({ species = "Beta", spd = 10, types = { 1 }, moves = { SPL() } }) } })
  events, log = play(b, {})
  ok(said(events, "It doesn't affect Beta!"), "an immunity")
  eq(log.bytes .. "/" .. log.rolls, "2/0", "...draws the crit and the accuracy byte, no roll")

  -- (d) COUNTER's crit byte comes first; an OHKO into a faster target draws
  --     its crit byte and is "Beta's unaffected!".
  b = duel({ a = { sheet({ species = "Alpha", spd = 10, moves = { mv("COUNTER", 1, 0, { type = 1 }) } }) },
             b = { sheet({ species = "Beta", spd = 90, moves = { mv("flame", 10, 0, { type = 2 }) } }) } })
  events, log = play(b, {})
  eq(log.bytes, 3, "Beta's crit and accuracy, then COUNTER's crit byte before it refuses")
  b = duel({ a = { sheet({ species = "Alpha", spd = 10, moves = { mv("drill", 1, 38) } }) },
             b = { sheet({ species = "Beta", spd = 90, moves = { SPL() } }) } })
  events, log = play(b, {})
  ok(said(events, "Beta's unaffected!") and log.bytes == 1, "OneHitKOEffect_'s miss: one crit byte")

  -- (e) The computer: no PP spent, a 0-PP move picked, STRUGGLE only on one
  --     disabled move.
  b = duel({ mode = "wild", a = { sheet({ species = "Alpha", spd = 90, moves = { SPL() } }) },
             b = { sheet({ species = "Beta", spd = 10, moves = { mv("thump", 10, 0, { pp = 1 }) } }) } })
  play(b, {})
  play(b, {})
  eq(beta(b).moves[1].pp, 1, "the computer's PP never moves")
  ok(b:submitChoice("p1", { action = "fight", move = 0 }), "(Ann files)")
  ok(b:submitChoice("p2", { action = "fight", move = 0 }), "a 1-PP move is still the computer's")
  b = duel({ mode = "wild", a = { sheet({ species = "Alpha", spd = 90, moves = { SPL() } }) },
             b = { sheet({ species = "Beta", spd = 10, moves = { mv("thump", 10, 0, { pp = 0 }) } }) } })
  events = play(b, {})
  ok(said(events, "Beta used thump!"), "a 0-PP move: picked and used, not STRUGGLE")
  eq(b:_struggles(b.byId.p2, beta(b)), false, "SelectEnemyMove never reads PP")
  beta(b).disable = { moveIndex = 1, turns = 3, moveId = "thump" }
  eq(b:_struggles(b.byId.p2, beta(b)), true, "one move, disabled: STRUGGLE")

  -- (f) Sleep through a doll; SleepEffect on a recharging target.
  b = duel({ a = { sheet({ species = "Alpha", spd = 10, moves = { mv("lull", 0, 32, { accuracy = 0 }) } }) },
             b = { sheet({ species = "Beta", spd = 90, status = "PSN", moves = { mv("beam", 20, 80) } }) } })
  events, log = play(b, { 255, 0, 3 })
  ok(said(events, "Beta fell asleep!") and beta(b).status == "sleep" and not beta(b).mustRecharge,
     "an accuracy-0 SLEEP lands on the recharging Beta, its POISON overwritten, its recharge gone")
  eq(beta(b).statusTurns, 3, "...the counter one `and SLP_MASK` byte (3)")
  eq(log.bytes, 3, "...Beta's crit and accuracy, then the counter: no hit test")
  b = duel({ a = { sheet({ species = "Alpha", spd = 90, moves = { mv("lull", 0, 32) } }) },
             b = { sheet({ species = "Beta", spd = 10, moves = { SPL() }, extra = { substitute = 50 } }) } })
  events, log = play(b, { 0, 0, 5 })
  ok(said(events, "Beta fell asleep!") and beta(b).substitute == 50, "SLEEP through a standing doll")
  eq(log.bytes, 3, "...its accuracy byte, a 0 redrawn, then 5")

  -- (g) The trap: the slower Beta held on the first turn, the continuation
  --     in Alpha's slot drawing nothing, the hold ending with the counter.
  b = duel({ a = { sheet({ species = "Alpha", spd = 90, moves = { mv("wrap", 15, 42), SPL() } }) },
             b = { sheet({ species = "Beta", spd = 10, moves = { mv("thump", 10, 0) } }) } })
  events, log = play(b, { 0, 255, 0 })
  ok(said(events, "Beta can't move!"), "`.HeldInPlaceCheck`: the slower Beta loses the trap's first turn")
  eq(alpha(b).trapping and alpha(b).trapping.turns, 1, "a count byte of 0: one attack after this one")
  -- Both are players: each answers the battle menu's FIGHT (R1d), the
  -- continuation and CANNOT_MOVE.
  events, log = play(b, {}, 0, 0)
  ok(said(events, "Alpha's attack continues!") and not said(events, "Beta can't move!"),
     "the continuation, in Alpha's slot; Beta's CANNOT_MOVE silent")
  eq(log.bytes .. "/" .. log.rolls, "0/0", "...and drawing nothing")
  ok(alpha(b).trapping == nil and beta(b).trapped == nil, "CheckNumAttacksLeft let go at the turn's end")
  events = play(b, { 255, 0 }, 1, 0)
  ok(said(events, "Beta used thump!"), "Beta moves again")

  -- (h) Speed ties on a switch and an item turn draw the byte.
  b = duel({ a = { sheet({ species = "Alpha" }), sheet({ species = "Gamma" }) },
             b = { sheet({ species = "Beta" }) } })
  events, log = play(b, { 0 }, { action = "switch", slot = 1 }, { action = "item", item = "restore" })
  eq(log.bytes, 1, "40 against 40: a switch and an item still meet the compare and its tie byte")

  -- (i) A TOXIC on the bench is plain poison.
  b = duel({ a = { sheet({ species = "Alpha", spd = 90, status = "TOX", moves = { SPL() } }),
                   sheet({ species = "Gamma", spd = 90, moves = { SPL() } }) },
             b = { sheet({ species = "Beta", spd = 10, moves = { SPL() } }) } })
  play(b, {}, { action = "switch", slot = 1 })
  eq(b.byId.p1.mons[1].status, "poison", "switched out: BADLY_POISONED is gone with the battle struct")

  -- (j) Focus Energy / Mist twice, Splash, Mirror Move's failure line.
  b = duel({ a = { sheet({ species = "Alpha", spd = 90, moves = { mv("pump", 0, 47), mv("copy", 0, 9) } }) },
             b = { sheet({ species = "Beta", spd = 10, moves = { SPL() } }) } })
  play(b, {})
  events = play(b, {})
  ok(said(events, "But, it failed!"), "FOCUS ENERGY already up: But it failed")
  ok(said(events, "No effect!"), "SPLASH: No effect!")
  b = duel({ a = { sheet({ species = "Alpha", spd = 90, moves = { mv("copy", 0, 9) } }) },
             b = { sheet({ species = "Beta", spd = 10, moves = { SPL() } }) } })
  events = play(b, {})
  ok(said(events, "The MIRROR MOVE failed!"), "MIRROR MOVE with nothing to copy: MirrorMoveFailedText")
end

-- ------------------------------------------------------------------
-- R1d (gen12-referee-gaps-fix wave 4): the battle menu a player keeps
-- through a Bide, a trap and a hold; the computer's re-pick; the cart's
-- message order; the charge's PP; a coop_wild RUN; Haze's lasting
-- CANNOT_MOVE; the chart's row order.  The g1_menu_lockin, g1_charge_turn,
-- g1_thrash_anim, g1_hit_lines, g1_coop_run, g1_haze_lock and g1_chart_order
-- parity scenarios (tests/drivers/battle_turn_parity.lua) hold lib/battle to
-- the same streams.
-- ------------------------------------------------------------------

do
  local function sheet(o)
    local raw = mon(o)
    raw.baseSpd = o.baseSpd or 0
    for k, v in pairs(o.extra or {}) do raw[k] = v end
    return raw
  end
  local function duel(o)
    local battle = assert(Turn.create({
      id = "r1d", mode = o.mode or "1v1", seed = o.seed or 7, choiceTimeout = 60,
      reconnectGrace = 60, chart = o.chart, chartOrder = o.chartOrder,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = o.a } },
        b = { { playerId = "p2", name = "Bob", mons = o.b } },
      },
    }))
    drain(battle)
    return battle
  end
  local function said(events, text)
    for _, e in ipairs(events) do if e.t == "msg" and e.text == text then return true end end
    return false
  end

  -- (a) `_menuFight`: a player's FIGHT with no move menu behind it.
  local b = duel({ a = { sheet({ species = "Alpha", moves = { move({ id = "bide", power = 0, effect = 26 }) },
                                 extra = { bide = { turns = 2, stored = 0, moveIndex = 1, targetSlot = 3 } } }) },
                   b = { sheet({ species = "Beta" }) } })
  eq(b.byId.p1.choice, nil, "a player's Bide user is asked (DisplayBattleMenu runs first)")
  local c = b:_normaliseChoice(b.byId.p1, { action = "fight", move = 3 })
  ok(c and c.bideStore and c.target == 3, "...and its FIGHT, naming no slot, is the Bide's turn")
  c = b:_normaliseChoice(b.byId.p1, { action = "fight" })
  ok(c and c.bideStore, "...with no slot at all, too")
  eq(b:_normaliseChoice(b.byId.p1, { action = "switch", slot = 0 }), nil,
     "a switch to the monster already out is still refused")

  -- (b) Asleep, a 0-PP or disabled slot is taken: no move menu, the gate stops it.
  b = duel({ a = { sheet({ species = "Alpha", status = "SLP",
                           moves = { move({ id = "dry", pp = 0 }), move({ id = "wet" }) },
                           extra = { statusTurns = 3, disable = { moveIndex = 2, turns = 3 } } }) },
             b = { sheet({ species = "Beta" }) } })
  c = b:_normaliseChoice(b.byId.p1, { action = "fight", move = 0 })
  eq(c and c.move, 1, "asleep: a 0-PP slot is taken")
  c = b:_normaliseChoice(b.byId.p1, { action = "fight", move = 1 })
  eq(c and c.move, 2, "...so is the disabled one")
  c = b:_normaliseChoice(b.byId.p1, { action = "fight", move = 3 })
  eq(c and c.move, 1, "...and a slot naming nothing is the first")

  -- (c) SelectEnemyMove after the player's switch: the computer's trap let go
  --     re-picks (`_reselectComputer`); a player's trapper whose item ran its
  --     counter out frees the computer it held.
  b = duel({ mode = "wild",
             a = { sheet({ species = "Alpha", spd = 10 }), sheet({ species = "Gamma", spd = 10 }) },
             b = { sheet({ species = "Beta", spd = 90, moves = { move({ id = "wrap", power = 15, effect = 42 }),
                                                                  move({ id = "slam", power = 40 }) } }) } })
  local beta = activeMonOf(b, "p2")
  local alpha = activeMonOf(b, "p1")
  beta.trapping = { turns = 2, moveIndex = 1, targetSlot = 0, damage = 4 }
  alpha.trapped = { turns = 2, damage = 4, fromSlot = 3 }
  b.byId.p2.choice = nil
  b:_fillForcedChoices()
  ok(b.byId.p2.choice and b.byId.p2.choice.trapContinue, "the wild trapper's continuation is filed")
  -- The re-pick is `.chooseRandomMove`'s (R1e): its first byte, 100, is
  -- below 50 percent (127) and not below 25 percent (63) -- the second slot.
  local repick = { 100 }
  local seeded = b.rng
  b.rng = {
    byte = function()
      local n = table.remove(repick, 1)
      if n ~= nil then return n end
      return seeded:byte()
    end,
    nextInt = function(_, lo, hi) return seeded:nextInt(lo, hi) end,
    damageRoll = function() return seeded:damageRoll() end,
    next = function() return seeded:next() end,
    state = function() return seeded:state() end,
  }
  ok(b:submitChoice("p1", { action = "switch", slot = 1 }), "the held player switches")
  local events = drain(b)
  ok(said(events, "Beta used slam!") and not said(events, "Beta used wrap!"),
     "the trap let go, the computer picks afresh: SLAM, not WRAP run fresh")

  b = duel({ mode = "wild",
             a = { sheet({ species = "Alpha", spd = 90, moves = { move({ id = "wrap", power = 15, effect = 42 }) } }) },
             b = { sheet({ species = "Beta", spd = 10, moves = { move({ id = "thump", power = 10 }) } }) } })
  alpha, beta = activeMonOf(b, "p1"), activeMonOf(b, "p2")
  alpha.trapping = { turns = 1, moveIndex = 1, targetSlot = 3, damage = 4 }
  beta.trapped = { turns = 1, damage = 4, fromSlot = 0 }
  b.byId.p2.choice = nil
  b:_fillForcedChoices()
  eq(b.byId.p2.choice and b.byId.p2.choice.skip, "trapped", "the held wild Beta: CANNOT_MOVE")
  ok(b:submitChoice("p1", { action = "item", item = "X_ATTACK" }), "the trapper uses an item")
  events = drain(b)
  ok(alpha.trapping == nil and beta.trapped == nil, "UseBagItem's step took the counter to 0: let go")
  ok(said(events, "Beta used thump!"), "...before SelectEnemyMove, so Beta picks and moves")

  -- (d) The message order: "is confused!" every confused turn, ahead of its byte.
  b = duel({ a = { sheet({ species = "Alpha", spd = 90, confusion = 3, moves = { move({ id = "splash", power = 0, effect = 85 }) } }) },
             b = { sheet({ species = "Beta", spd = 10, moves = { move({ id = "splash", power = 0, effect = 85 }) } }) } })
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "fight", move = 0 })
  events = drain(b)
  eq(events[1] and events[1].t, "chose", "(the turn's answers first)")
  ok(said(events, "Alpha is confused!"), "IsConfusedText on a turn the counter does not reach 0")
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "fight", move = 0 })
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "fight", move = 0 })
  events = drain(b)
  ok(not said(events, "Alpha is confused!") or said(events, "Alpha's confused no more!"),
     "the snap-out turn says ConfusedNoMoreText instead")

  -- (e) chartOrder: all or nothing.
  b = duel({ chartOrder = { 0, 1, 0 }, a = { sheet({ species = "Alpha" }) }, b = { sheet({ species = "Beta" }) } })
  eq(b.chartRows, nil, "an odd-length order is refused whole")
  b = duel({ chartOrder = { 0, 1, -1, 2 }, a = { sheet({ species = "Alpha" }) }, b = { sheet({ species = "Beta" }) } })
  eq(b.chartRows, nil, "a negative index refuses it whole")
  b = duel({ chartOrder = { 0, 1.5 }, a = { sheet({ species = "Alpha" }) }, b = { sheet({ species = "Beta" }) } })
  eq(b.chartRows, nil, "so does a fraction")
  b = duel({ chart = { { 100, 200, 50 }, { 100, 100, 100 }, { 100, 100, 100 } },
             chartOrder = { 0, 2, 0, 1, 1, 1 },
             a = { sheet({ species = "Alpha" }) }, b = { sheet({ species = "Beta", types = { 1, 2 } }) } })
  local percents, last = b:_typeRows(0, activeMonOf(b, "p2"))
  eq(table.concat(percents, ","), "50,200", "the rows of the move's type that name a defender type, in order")
  eq(last, 200, "wDamageMultipliers: the last of them")
  percents, last = b:_typeRows(2, activeMonOf(b, "p2"))
  eq(#percents .. ":" .. last, "0:100", "no row: EFFECTIVE, nothing applied")

  -- (e2) A thrash's continuation is THRASH in wPlayerMoveNum: the animation,
  --      and CriticalHitTest's HighCriticalMoves lookup -- a high-crit
  --      thrashing move crits at the ordinary rate on those turns.
  local Crit = BattleSim.Crit
  local byte = nil
  for candidate = 0, 255 do
    if Crit.check(60, candidate, { highCritMove = true })
       and not Crit.check(60, candidate, {}) then byte = candidate; break end
  end
  ok(byte ~= nil, "(a byte the high-crit rate crits on and the ordinary one does not)")
  b = duel({ a = { sheet({ species = "Alpha", spd = 90, baseSpd = 60,
                           moves = { (function() local m = move({ id = "PETAL_DANCE", power = 20, effect = 27 })
                                                 m.highCrit = true; return m end)() },
                           extra = { thrashing = { turns = 2, moveIndex = 1 } } }) },
             b = { sheet({ species = "Beta", spd = 10, maxHp = 400,
                           moves = { move({ id = "splash", power = 0, effect = 85 }) } }) } })
  ok(b.byId.p1.choice and b.byId.p1.choice.forcedMove, "the thrash is forced")
  local fallback = BattleSim.Rng.new(5)
  b.rng = {
    byte = function(self) local v = byte; byte = nil; if v then return v end return fallback:byte() end,
    nextInt = function(_, lo, hi) return fallback:nextInt(lo, hi) end,
    damageRoll = function() return 255 end,
    next = function() return fallback:next() end,
    state = function() return fallback:state() end,
  }
  b:submitChoice("p2", { action = "fight", move = 0 })
  events = drain(b)
  local anim = nil
  for _, e in ipairs(events) do if e.t == "anim" and e.slot == 0 then anim = e.text end end
  eq(anim, "THRASH", "the continuation animates THRASH")
  ok(said(events, "Alpha's thrashing about!") and not said(events, "Critical hit!"),
     "...and crits at the ordinary rate: no crit on a byte only the high-crit rate takes")

  -- (f) `_selectsAnew`: only a move menu lifts Haze's CANNOT_MOVE.  The wild
  --     Beta, frozen while it owed a HYPER BEAM recharge (the enemy side
  --     keeps it), is thawed by HAZE: its forced recharge turns never select
  --     anew, so it never acts -- not even to recharge.
  b = duel({ mode = "wild",
             a = { sheet({ species = "Alpha", spd = 90, moves = { move({ id = "haze", power = 0, effect = 25 }),
                                                                  move({ id = "splash", power = 0, effect = 85 }) } }) },
             b = { sheet({ species = "Beta", spd = 10, status = "FRZ", extra = { mustRecharge = true } }) } })
  local lines = {}
  for turn = 1, 3 do
    b:submitChoice("p1", { action = "fight", move = turn == 1 and 0 or 1 })
    b:submitChoice("p2", { action = "fight", move = 0 })
    for _, e in ipairs(drain(b)) do if e.t == "msg" then lines[#lines + 1] = e.text end end
  end
  local betaActed = false
  for _, text in ipairs(lines) do if text:find("^Beta") then betaActed = true end end
  ok(not betaActed, "Haze's CANNOT_MOVE outlasts the turn while no menu writes a new selection")
  eq(activeMonOf(b, "p2").mustRecharge, true, "...the recharge never spent")
  ok(b.byId.p2.cannotMove, "...the seat still selecting CANNOT_MOVE")

  b = duel({ a = { sheet({ species = "Alpha" }) }, b = { sheet({ species = "Beta" }) } })
  local f1 = b.byId.p1
  f1.choice = { action = "fight", move = 1 }
  ok(b:_selectsAnew(f1, activeMonOf(b, "p1")), "an awake player's FIGHT opens the move menu")
  f1.choice = { action = "switch", slot = 1 }
  ok(not b:_selectsAnew(f1, activeMonOf(b, "p1")), "a switch leaves the selection")
  f1.choice = { action = "fight", move = 1, forcedMove = activeMonOf(b, "p1").moves[1] }
  ok(not b:_selectsAnew(f1, activeMonOf(b, "p1")), "a forced replay leaves it")
end

-- ------------------------------------------------------------------
-- R1e (gen12-referee-gaps-fix wave 5): each rule against pokered on a
-- scripted generator.  The g1_sub_lines, g1_pp_wrap, g1_npc_run,
-- g1_counter_struct, g1_status_anims, g1_cart_pick, g1_heal, g1_item_lines
-- and g1_conversion parity scenarios (tests/drivers/battle_turn_parity.lua)
-- hold lib/battle to the same streams.
-- ------------------------------------------------------------------

do
  local Rng = BattleSim.Rng
  local function script(battle, bytes)
    local fallback = Rng.new(99)
    local log = { bytes = 0 }
    battle.rng = {
      byte = function()
        log.bytes = log.bytes + 1
        local b = bytes[log.bytes]
        if b == nil then b = fallback:byte() end
        return b
      end,
      nextInt = function(_, lo, hi) return fallback:nextInt(lo, hi) end,
      damageRoll = function() return 255 end,
      next = function() return fallback:next() end,
      state = function() return fallback:state() end,
    }
    return log
  end
  local function mv(id, power, effect, o)
    o = o or {}
    local m = move({ id = id, power = power, effect = effect or 0, pp = o.pp or 60,
                     type = o.type, accuracy = o.accuracy, chance = o.chance })
    if o.ppUps then m.ppUps = o.ppUps end
    return m
  end
  local function sh(o, extra)
    local raw = mon(o)
    raw.baseSpd = 0
    for k, v in pairs(extra or {}) do raw[k] = v end
    return raw
  end
  local function duel(o)
    local battle = assert(Turn.create({
      id = "r1e", mode = o.mode or "1v1", seed = o.seed or 7, choiceTimeout = 60,
      reconnectGrace = 60, chart = o.chart, chartOrder = o.chartOrder, typeIds = o.typeIds,
      metronomePool = o.pool,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = o.a } },
        b = { { playerId = "p2", name = "Bob", mons = o.b, aiMods = o.aiMods, bag = o.bBag } },
      },
    }))
    drain(battle)
    return battle
  end
  local function said(events, text)
    for _, e in ipairs(events) do if e.t == "msg" and e.text == text then return true end end
    return false
  end
  local function texts(events)
    local out = {}
    for _, e in ipairs(events) do if e.t == "msg" then out[#out + 1] = e.text end end
    return out
  end
  local function indexOf(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
    return nil
  end

  -- (1) AttackSubstitute: "The SUBSTITUTE took damage for <TARGET>!" on
  --     every hit into a doll -- before the break line -- and on a self-hit,
  --     naming the doll's owner across the field.
  local b = duel({ a = { sh({ species = "Alpha", spd = 90, maxHp = 400, moves = { mv("thump", 10) } }) },
                   b = { sh({ species = "Beta", spd = 10, maxHp = 400, moves = { mv("splash", 0, 85) } },
                            { substitute = 30 }) } })
  script(b, { 255, 0 })
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(b)
  local t = texts(events)
  eq(t[2], "The SUBSTITUTE took damage for Beta!", "a hit that the doll holds: the line")
  ok(not said(events, "Beta's SUBSTITUTE broke!"), "...and no break")
  b = duel({ a = { sh({ species = "Alpha", spd = 90, maxHp = 400, moves = { mv("thump", 10) } },
                     { confusion = 5, substitute = 40 }) },
             b = { sh({ species = "Beta", spd = 10, maxHp = 400, moves = { mv("splash", 0, 85) } },
                      { substitute = 2 }) } })
  script(b, { 200 })
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "fight", move = 0 })
  t = texts(drain(b))
  local hurt = indexOf(t, "It hurt itself in its confusion!")
  ok(hurt ~= nil, "byte 200: the self-hit")
  eq(t[(hurt or 0) + 1], "The SUBSTITUTE took damage for Beta!", "...whose line names Beta's doll")
  eq(t[(hurt or 0) + 2], "Beta's SUBSTITUTE broke!", "...which breaks")

  -- (2) DecrementPP's `dec [hl]` on the PP byte: 0 PP with two PP Ups is
  --     63 PP with one; with none, 63 with three.
  b = duel({ a = { sh({ species = "Alpha", spd = 90, maxHp = 400,
                        moves = { mv("wrap", 15, 42, { pp = 1, ppUps = 2 }) } }) },
             b = { sh({ species = "Beta", spd = 10, maxHp = 400, moves = { mv("thump", 10) } }),
                   sh({ species = "Delta", spd = 10, maxHp = 400, moves = { mv("thump", 10) } }) } })
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "fight", move = 0 })
  drain(b)
  eq(activeMonOf(b, "p1").moves[1].pp, 0, "WRAP's last PP")
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "switch", slot = 1 })
  events = drain(b)
  local wrapped = activeMonOf(b, "p1").moves[1]
  eq(wrapped.pp .. "/" .. wrapped.ppUps, "63/1", "the freed trap's fresh run borrows: 63 PP, one PP Up fewer")
  local spent = nil
  for _, e in ipairs(events) do if e.t == "moves" and e.side == "a" then spent = e.moves[1].pp end end
  eq(spent, 63, "...and the moves event carries the 63")
  b = duel({ a = { sh({ species = "Alpha", spd = 90, maxHp = 400,
                        moves = { mv("wrap", 15, 42, { pp = 1 }) } }) },
             b = { sh({ species = "Beta", spd = 10, maxHp = 400, moves = { mv("thump", 10) } }),
                   sh({ species = "Delta", spd = 10, maxHp = 400, moves = { mv("thump", 10) } }) } })
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "fight", move = 0 })
  drain(b)
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "switch", slot = 1 })
  drain(b)
  wrapped = activeMonOf(b, "p1").moves[1]
  eq(wrapped.pp .. "/" .. wrapped.ppUps, "63/3", "...with none, the borrow wraps the PP Ups to three")

  -- IncrementMovePP: a METRONOME that calls a non-charge move costs one PP;
  -- one that calls FLY costs none until the release.
  b = duel({ pool = { mv("tap", 10) },
             a = { sh({ species = "Alpha", spd = 90, maxHp = 400, moves = { mv("METRONOME", 0, 83, { pp = 10 }) } }) },
             b = { sh({ species = "Beta", spd = 10, maxHp = 400, moves = { mv("splash", 0, 85) } }) } })
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "fight", move = 0 })
  drain(b)
  eq(activeMonOf(b, "p1").moves[1].pp, 9, "a called TAP: spent, refunded, spent -- one PP")

  -- The stale selection: a frozen monster's FIGHT names a placeholder; a
  -- thaw before its slot runs last turn's move, paying last turn's index.
  local quick = mv("QUICK_ATTACK", 10, 4, { type = 1 })
  quick.name = "QUICK ATTACK"
  b = duel({ typeIds = { "NORMAL", "FIRE" },
             a = { sh({ species = "Alpha", spd = 90, maxHp = 400, types = { 1 },
                        moves = { mv("thump", 10, 0, { pp = 1 }), mv("tap", 10) } }) },
             b = { sh({ species = "Beta", spd = 10, maxHp = 400,
                        moves = { mv("chill", 10, 5, { chance = 100 }), quick } }) } })
  script(b, { 255, 0, 255, 0, 0 })
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "fight", move = 0 })
  drain(b)
  eq(activeMonOf(b, "p1").status, "freeze", "chilled after spending thump's last PP")
  script(b, { 255, 0, 255, 0 })
  b:submitChoice("p1", { action = "fight", move = 1 })
  b:submitChoice("p2", { action = "fight", move = 1 })
  t = texts(drain(b))
  ok(indexOf(t, "Fire defrosted Alpha!") ~= nil and indexOf(t, "Alpha used thump!") ~= nil
     and indexOf(t, "Alpha used tap!") == nil, "thawed: last turn's thump, not the frozen menu's tap")
  eq(activeMonOf(b, "p1").moves[1].pp, 63, "...at 0 PP: the wrap")
  eq(activeMonOf(b, "p1").moves[2].pp, 60, "...and tap untouched")

  -- (4) COUNTER: the selection for COUNTER, the struct for power and type.
  b = duel({ a = { sh({ species = "Alpha", spd = 90, maxHp = 400,
                        moves = { mv("thump", 10), mv("COUNTER", 1, 0, { type = 1 }) } }) },
             b = { sh({ species = "Beta", spd = 10, maxHp = 400, moves = { mv("chop", 30) } }),
                   sh({ species = "Delta", spd = 10, maxHp = 400, moves = { mv("chop", 30) } }) } })
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "fight", move = 0 })
  drain(b)
  local f2 = fighterById(b, "p2")
  eq(f2.moveStruct and (f2.moveStruct.power .. "/" .. f2.moveStruct.type), "30/0",
     "GetCurrentMove left CHOP in Beta's struct")
  local last = b.lastDamage
  b:submitChoice("p1", { action = "fight", move = 1 })
  b:submitChoice("p2", { action = "switch", slot = 1 })
  events = drain(b)
  local countered = nil
  for _, e in ipairs(events) do if e.t == "damage" and e.side == "b" then countered = e.amount end end
  eq(countered, 2 * last, "Beta switched (no selection): COUNTER reads the struct and hits for twice wDamage")
  ok(b:_counterDamage(nil) == nil, "no target: a miss")
  f2.selectedMove = nil
  b.lastDamage = 7
  f2.moveStruct = { power = 30, type = 2 }
  eq(b:_counterDamage(f2), nil, "a struct of neither Normal nor Fighting type: a miss")
  f2.selectedMove = mv("COUNTER", 1)
  f2.moveStruct = { power = 30, type = 0 }
  eq(b:_counterDamage(f2), nil, "a target that selected COUNTER: a miss")
  f2.selectedMove = nil
  b.lastDamage = 7
  eq(b:_counterDamage(f2), 14, "CANNOT_MOVE (no selection) with a Normal struct: twice wDamage")
  f2.moveStruct = { power = 0, type = 0 }
  eq(b:_counterDamage(f2), nil, "a power-0 struct: a miss")
  f2.moveStruct = nil
  eq(b:_counterDamage(f2), nil, "nothing loaded: a miss")

  -- (7) `.chooseRandomMove`: below 63 the first slot, below 127 the
  --     second, below 190 the third, else the fourth; an empty or disabled
  --     slot draws again.
  local function pick(moves, bytes, extra)
    local battle = duel({ mode = "wild",
      a = { sh({ species = "Alpha", spd = 90, maxHp = 400, moves = { mv("splash", 0, 85) } }) },
      b = { sh({ species = "Beta", spd = 10, maxHp = 400, moves = moves }, extra) } })
    local log = script(battle, bytes)
    local fighter = fighterById(battle, "p2")
    local choice = { action = "fight", target = 0 }
    battle:_cartMovePick(fighter, activeMonOf(battle, "p2"), choice)
    return choice.move, log.bytes
  end
  local FOUR = { mv("m1", 10), mv("m2", 10), mv("m3", 10), mv("m4", 10) }
  for _, case in ipairs({ { 0, 1 }, { 62, 1 }, { 63, 2 }, { 126, 2 }, { 127, 3 }, { 189, 3 }, { 190, 4 }, { 255, 4 } }) do
    local got = pick(FOUR, { case[1] })
    eq(got, case[2], ("byte %d: slot %d"):format(case[1], case[2]))
  end
  local got, drawn = pick({ mv("m1", 10) }, { 200, 100, 70, 10 })
  eq(got .. "/" .. drawn, "1/4", "one move: drawn until a byte lands below 63")
  got, drawn = pick({ mv("m1", 10), mv("m2", 10) }, { 70, 10 }, { disable = { moveIndex = 2, turns = 3 } })
  eq(got .. "/" .. drawn, "1/2", "the disabled second slot is drawn again")
  got, drawn = pick({ mv("m1", 10) }, { 0 }, { disable = { moveIndex = 1, turns = 3 } })
  eq(drawn, 0, "one move, disabled: STRUGGLE with no draw")

  -- AIEnemyTrainerChooseMoves: the layers' scores and the minimum.
  local function layers(aiMods, bMoves, o)
    o = o or {}
    local battle = duel({ mode = "coop_npc", aiMods = aiMods, chart = o.chart, chartOrder = o.chartOrder,
      a = { sh({ species = "Alpha", spd = 90, maxHp = 400, status = o.status, types = o.types,
                 moves = { mv("splash", 0, 85) } }) },
      b = { sh({ species = "Beta", spd = 10, maxHp = 400, moves = bMoves }, o.extra) } })
    local fighter = fighterById(battle, "p2")
    fighter.aiLayer2 = o.aiLayer2 or 0
    local usable = battle:_aiTrainerMoves(fighter, activeMonOf(battle, "p2"), { action = "fight", target = 0 })
    local list = {}
    for i = 1, 4 do if usable[i] then list[#list + 1] = i end end
    return table.concat(list, ","), fighter
  end
  local STATUSY = { mv("lull", 0, 32), mv("thump", 10), mv("toxin", 0, 66), mv("hum", 0, 1) }
  eq(layers({ 1 }, STATUSY), "1,2,3,4", "layer 1 against a healthy target: nothing moves")
  eq(layers({ 1 }, STATUSY, { status = "PAR" }), "2", "...against a statused one: the status moves +5")
  local GROWY = { mv("grow", 0, 10), mv("thump", 10), mv("dull", 0, 18), mv("shield", 0, 65) }
  eq(layers({ 2 }, GROWY), "1,2,3,4", "layer 2 off its second selection: nothing")
  eq(layers({ 2 }, GROWY, { aiLayer2 = 1 }), "1,3,4",
     "...on it: ATTACK_UP1_EFFECT up to BIDE (GROWL's 18 too) and ATTACK_UP2 up to POISON (REFLECT's 65)")
  eq(layers({ 2 }, GROWY, { aiLayer2 = 2 }), "1,2,3,4", "...and on no later one (`cp $1 / ret nz`)")
  local CHART = { { 100, 100 }, { 200, 50 } }
  local TYPED = { mv("hit0", 10, 0, { type = 0 }), mv("hit1", 10, 0, { type = 1 }) }
  eq(layers({ 3 }, TYPED, { chart = CHART, types = { 0 } }), "2", "layer 3: the super-effective move -1")
  eq(layers({ 3 }, TYPED, { chart = CHART, types = { 1 } }), "1",
     "...a not-very-effective one +1 when another type does damage")
  local LONE = { mv("hit1", 10, 0, { type = 1 }), mv("calm", 0, 0, { type = 1 }) }
  eq(layers({ 3 }, LONE, { chart = CHART, types = { 1 } }), "1,2",
     "...and left alone when no other type does damage (the scan finds no better move)")
  local _, fighter = layers({ 3 }, TYPED, { chart = CHART, types = { 1 } })
  eq(fighter.moveStruct and (fighter.moveStruct.power .. "/" .. fighter.moveStruct.type), "10/0",
     "ReadMove's last copy is in the struct: the better-move scan's find")
  eq(layers({ 1 }, STATUSY, { status = "PAR", extra = { disable = { moveIndex = 2, turns = 2 } } }), "1,3,4",
     "the disabled slot starts at $50: the +5 status moves are the minimum now")
  eq(layers({}, STATUSY, { status = "PAR" }), "1,2,3,4", "no layer: the original move set")

  -- (3) the trainer RUN: covered in section 7b above.

  -- (6) the sleeping and confused animations, by seat.
  b = duel({ mode = "wild",
             a = { sh({ species = "Alpha", spd = 90, maxHp = 400, moves = { mv("thump", 10) } },
                      { status = "SLP", statusTurns = 3 }) },
             b = { sh({ species = "Beta", spd = 10, maxHp = 400, moves = { mv("thump", 10) } },
                      { confusion = 4 }) } })
  script(b, { 0 })
  b:submitChoice("p1", { action = "fight", move = 0 })
  b:submitChoice("p2", { action = "fight", move = 0 })
  local seq = {}
  for _, e in ipairs(drain(b)) do
    if e.t == "anim" then seq[#seq + 1] = "@" .. e.text elseif e.t == "msg" then seq[#seq + 1] = e.text end
  end
  eq(table.concat(seq, "|", 1, 4), "@SLP_PLAYER_ANIM|Alpha is fast asleep!|Beta is confused!|@CONF_ANIM",
     "the player's sleep animation first, the computer's confusion after its line")

  -- HealEffect_'s compare.
  local function heal(hp, maxHp, id)
    local battle = duel({ a = { sh({ species = "Alpha", spd = 90, hp = hp, maxHp = maxHp,
                                     moves = { mv(id or "RECOVER", 0, 56) } }) },
                          b = { sh({ species = "Beta", spd = 10, maxHp = 400, moves = { mv("splash", 0, 85) } }) } })
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    return said(drain(battle), "But, it failed!"), activeMonOf(battle, "p1")
  end
  ok(heal(400, 400), "full HP fails")
  ok(heal(145, 400), "255 short fails (the high-byte carry)")
  ok(heal(89, 600), "511 short fails too")
  local failed, alpha = heal(144, 400)
  ok(not failed and alpha.hp == 344, "256 short heals half the maximum")
  failed, alpha = heal(399, 400)
  ok(not failed and alpha.hp == 400, "one short heals to the full")
  failed, alpha = heal(100, 400, "REST")
  ok(not failed and alpha.hp == 400 and alpha.status == "sleep" and alpha.statusTurns == 2,
     "REST: full HP, asleep with a counter of 2")
end

-- ------------------------------------------------------------------
-- RP1 (gen12-referee-gaps-fix polish): Red's `msg` lines in the cart's own
-- glyphs (Wire.battleText carries é now: "POKé BALL", "POKéMON" -- charmap
-- $54 / $BA), K8's PP Ups on every `moves` row, and GetMaxPP kept through
-- DecrementPP's wrap -- the sheet's stated maximum, re-read over the PP Up
-- bits a borrow leaves, and ItemUsePPRestore's `.restorePP` against it.  The
-- g1_pp_max parity scenario holds lib/battle to the same streams.
-- ------------------------------------------------------------------

do
  local function mv(id, o)
    o = o or {}
    local m = move({ id = id, power = o.power or 10, effect = o.effect or 0, pp = o.pp or 60,
                     maxPp = o.maxPp })
    if o.ppUps then m.ppUps = o.ppUps end
    return m
  end
  local function duel(aMoves, o)
    o = o or {}
    local battle = battleOf({
      id = "rp1", mode = o.mode or "1v1", seed = o.seed or 7,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = {
          (function() local m = mon({ species = "Alpha", spd = 90, maxHp = 400, moves = aMoves })
                      m.baseSpd = 0; return m end)() } } },
        b = { { playerId = "p2", name = "Bob", mons = o.bMons or {
          mon({ species = "Beta", spd = 10, maxHp = 400, catchRate = o.catchRate,
                moves = { mv("splash", { power = 0, effect = 85 }) } }) } } },
      },
    })
    drain(battle)
    return battle
  end
  local function turn(battle, c1, c2)
    battle:submitChoice("p1", c1)
    battle:submitChoice("p2", c2 or { action = "fight", move = 0 })
    return drain(battle)
  end
  local function texts(events)
    local out = {}
    for _, e in ipairs(events) do if e.t == "msg" then out[#out + 1] = e.text end end
    return out
  end
  local function has(list, text)
    for _, v in ipairs(list) do if v == text then return true end end
    return false
  end
  local function count(list, text)
    local n = 0
    for _, v in ipairs(list) do if v == text then n = n + 1 end end
    return n
  end
  -- Ann's last `moves` row in a batch: "pp/maxPp/ppUps" per slot.
  local function row(events)
    local out = nil
    for _, e in ipairs(events) do
      if e.t == "moves" and e.side == "a" then
        local cells = {}
        for i, m in ipairs(e.moves) do
          cells[i] = tostring(m.pp) .. "/" .. tostring(m.maxPp) .. "/" .. tostring(m.ppUps)
        end
        out = table.concat(cells, ",")
      end
    end
    return out
  end
  local FIGHT = { action = "fight", move = 0 }
  local function item(id, slot) return { action = "item", item = id, move = slot } end

  -- (1) The item lines in the cart's glyphs: data/items/names.asm's "POKé
  --     BALL" / "POKé DOLL" / "POKé FLUTE", text_6.asm's "#MON".
  local b = duel({ mv("splash", { power = 0, effect = 85 }) }, { mode = "wild", catchRate = 0 })
  local t = texts(turn(b, item("POKE_BALL")))
  ok(has(t, "Ann used POKé BALL!"), "ItemUseText00 names the POKé BALL")
  ok(has(t, "You missed the POKéMON!"), "ItemUseBallText01, at a catch rate of 0")
  b = duel({ mv("splash", { power = 0, effect = 85 }) }, { mode = "wild", catchRate = 100 })
  t = texts(turn(b, item("POKE_BALL")))
  ok(has(t, "Darn! The POKéMON broke free!"), "ItemUseBallText02: one shake at 100 and full HP")
  b = duel({ mv("splash", { power = 0, effect = 85 }) }, { mode = "wild" })
  t = texts(turn(b, item("POKE_FLUTE")))
  ok(has(t, "Played the POKé FLUTE. Now, that's a catchy tune!"), "PlayedFluteNoEffectText")
  b = duel({ mv("splash", { power = 0, effect = 85 }) }, { mode = "wild", bMons = {
    mon({ species = "Beta", spd = 10, maxHp = 400, status = "SLP",
          moves = { mv("splash", { power = 0, effect = 85 }) } }) } })
  t = texts(turn(b, item("POKE_FLUTE")))
  ok(has(t, "Ann played the POKé FLUTE.") and has(t, "All sleeping POKéMON woke up."),
     "PlayedFluteHadEffectText, FluteWokeUpText")
  b = duel({ mv("splash", { power = 0, effect = 85 }) }, { mode = "wild" })
  t = texts(turn(b, item("POKE_DOLL")))
  ok(has(t, "Ann used POKé DOLL!"), "the doll's use line")

  -- (2) K8's PP Ups on every row: a spend states them beside the PP.
  b = duel({ mv("thump", { pp = 30, ppUps = 2, maxPp = 49 }) })
  eq(row(turn(b, FIGHT)), "29/49/2", "a spend's row: the PP, GetMaxPP, and the PP Ups")

  -- (3) A slot that arrives past its wrap: 63 PP over a stated GetMaxPP of 35.
  --     The maximum stays the sheet's (it was raised to 63); the ETHER
  --     brings the slot DOWN to it, and a second is no effect, said once.
  b = duel({ mv("thump", { pp = 63, maxPp = 35 }) })
  eq(row(turn(b, FIGHT)), "62/35/0", "the spend from 63: the stated maximum kept")
  local events = turn(b, item("ETHER", 0))
  eq(row(events), "35/35/0", "ETHER past the wrap: down to GetMaxPP")
  ok(has(texts(events), "PP was restored."), "...and that is a restore (`add b`: NZ)")
  -- A second is ItemUsePPRestore's `.noEffect` -> `.itemNotUsed`: the item
  -- kept and the turn unspent (FX-R1), so the choice is refused unfiled.
  eq(b:submitChoice("p1", item("ETHER", 0)), false,
     "ETHER at the maximum: no effect, refused (`.itemNotUsed`)")
  eq(b.byId.p1.choice, nil, "...and the seat still owes its turn")
  b:submitChoice("p1", FIGHT)
  b:submitChoice("p2", FIGHT)
  drain(b)

  -- (4) A wrap mid-fight: the freed trap's fresh run pays from 0 PP.  With a
  --     PP Up: 63 PP and none, and GetMaxPP re-reads 15 (15 + 3 before).
  local function wrapped(o)
    local battle = duel({ mv("wrap", { power = 15, effect = 42, pp = 1, ppUps = o.ppUps,
                                       maxPp = o.maxPp }) }, { bMons = {
      mon({ species = "Beta", spd = 10, maxHp = 400, moves = { mv("thump") } }),
      mon({ species = "Delta", spd = 10, maxHp = 400, moves = { mv("thump") } }) } })
    turn(battle, FIGHT, FIGHT)
    return row(turn(battle, FIGHT, { action = "switch", slot = 1 }))
  end
  eq(wrapped({ ppUps = 1, maxPp = 18 }), "63/15/0", "the borrow: one PP Up fewer, GetMaxPP over none")
  eq(wrapped({ maxPp = 15 }), "63/24/3", "...none wraps to three: 15 + 3 x 3")
  eq(wrapped({ ppUps = 1, maxPp = 17 }), "63/17/0", "a maximum no base gives (16, then 18) stays put")
  eq(wrapped({ ppUps = 1 }), "63/1/0", "a sheet that states none keeps the old reading, its PP")

  -- (5) MAX ETHER compares the whole byte (the cart's own bug): a full move
  --     with a PP Up "restores"; one with none is no effect.
  b = duel({ mv("thump", { pp = 20, ppUps = 1, maxPp = 20 }), mv("tap", { pp = 15, maxPp = 15 }) })
  events = turn(b, item("MAX_ETHER", 0))
  ok(has(texts(events), "PP was restored."), "MAX ETHER on a full move with a PP Up: restored")
  eq(row(events), "20/20/1,15/15/0", "...to what it had")
  eq(b:submitChoice("p1", item("MAX_ETHER", 1)), false,
     "MAX ETHER on a full move with none: no effect, refused (`.itemNotUsed`)")
  b:submitChoice("p1", FIGHT)
  b:submitChoice("p2", FIGHT)
  drain(b)
  ok(has(texts(turn(b, item("MAX_ELIXER"))), "PP was restored."),
     "MAX ELIXER over the same list: restored through the first slot")
end

-- ------------------------------------------------------------------
-- 12b. FX-R1: the Red referee's review fixes, each against pokered
-- ------------------------------------------------------------------

do
  local FIGHT = { action = "fight", move = 0 }
  local function texts(events)
    local out = {}
    for _, e in ipairs(events) do if e.t == "msg" then out[#out + 1] = e.text end end
    return out
  end
  local function has(list, text)
    for _, v in ipairs(list) do if v == text then return true end end
    return false
  end
  local function indexOf(list, text)
    for i, v in ipairs(list) do if v == text then return i end end
    return nil
  end

  -- CalcHitChance's `c = 14 - EVASIONMOD`: the target's +6 evasion reads the
  -- 25/100 ratio, so a 100-accuracy move needs a byte under 25.
  local hits, misses = 0, 0
  for seed = 1, 60 do
    local b = battleOf({ seed = seed,
      aMons = { mon({ spd = 90, moves = { move({ id = "jab", power = 10, accuracy = 100 }) } }) },
      bMons = { mon({ species = "Beta", spd = 10, stages = { eva = 6 },
                      moves = { move({ id = "splash", power = 0, effect = 85 }) } }) } })
    drain(b)
    b:submitChoice("p1", FIGHT)
    b:submitChoice("p2", FIGHT)
    local t = texts(drain(b))
    if has(t, "Alpha's attack missed!") then misses = misses + 1 else hits = hits + 1 end
  end
  ok(misses > 45, "evasion +6 makes the move miss more (CalcHitChance reflects the stage)")

  -- SendOutMon zeroes CONFUSED: out confused, back in clear-headed.
  local b = battleOf({
    aMons = { mon({ spd = 90, confusion = 4, moves = { move({ id = "growl", power = 0, effect = 18 }) } }),
              mon({ species = "Gamma", spd = 90 }) },
    bMons = { mon({ species = "Beta", spd = 10, moves = { move({ id = "splash", power = 0, effect = 85 }) } }) } })
  drain(b)
  b:submitChoice("p1", { action = "switch", slot = 1 })
  b:submitChoice("p2", FIGHT)
  drain(b)
  b:submitChoice("p1", { action = "switch", slot = 0 })
  b:submitChoice("p2", FIGHT)
  drain(b)
  eq(b.byId.p1.mons[1].confusion, 0, "switched back in: no confusion (SendOutMon, core.asm :1744-1749)")

  -- The end of each slot: a poisoned Alpha at 5 HP moves first, its poison
  -- takes it down right after, and Beta never moves.
  b = battleOf({
    aMons = { mon({ spd = 90, hp = 5, maxHp = 160, status = "PSN",
                    moves = { move({ id = "growl", power = 0, effect = 18 }) } }) },
    bMons = { mon({ species = "Beta", spd = 10, moves = { move({ id = "growl", power = 0, effect = 18 }) } }) } })
  drain(b)
  b:submitChoice("p1", FIGHT)
  b:submitChoice("p2", FIGHT)
  local t = texts(drain(b))
  ok(has(t, "Alpha's hurt by poison!") and not has(t, "Beta used growl!"),
     "a poison KO right after the mover's slot ends the turn (HandlePoisonBurnLeechSeed `jp z`)")
  eq(b:outcome() and b:outcome().winners[1], "p2", "...and the fight")

  -- ...a KO-er takes no residual that turn; and a slower poisoned battler's
  -- tick comes after its own move, not at a turn's end.
  b = battleOf({
    aMons = { mon({ spd = 90, atk = 300, status = "PSN", maxHp = 160,
                    moves = { move({ id = "slam", power = 120 }) } }) },
    bMons = { mon({ species = "Beta", spd = 10, hp = 5, maxHp = 20 }), mon({ species = "Delta", spd = 10 }) } })
  drain(b)
  b:submitChoice("p1", FIGHT)
  b:submitChoice("p2", FIGHT)
  ok(not has(texts(drain(b)), "Alpha's hurt by poison!"),
     "the slot that knocked Beta out skips Alpha's residual (`jp z, HandleEnemyMonFainted`)")
  b = battleOf({
    aMons = { mon({ spd = 10, status = "PSN", maxHp = 160, moves = { move({ id = "growl", power = 0, effect = 18 }) } }) },
    bMons = { mon({ species = "Beta", spd = 90, status = "BRN", maxHp = 160,
                    moves = { move({ id = "growl", power = 0, effect = 18 }) } }) } })
  drain(b)
  b:submitChoice("p1", FIGHT)
  b:submitChoice("p2", FIGHT)
  t = texts(drain(b))
  ok(indexOf(t, "Beta's hurt by the burn!") < indexOf(t, "Alpha used growl!")
     and indexOf(t, "Alpha used growl!") < indexOf(t, "Alpha's hurt by poison!"),
     "each residual at the end of its own slot, in the turn's order")

  -- A mutual last-monster KO: a loss against the computer, a draw in a link.
  for _, case in ipairs({ { mode = "wild", winner = "p2" }, { mode = "1v1", outcome = "draw" } }) do
    b = battleOf({ mode = case.mode,
      aMons = { mon({ spd = 90, atk = 200, hp = 40, maxHp = 400,
                      moves = { move({ id = "blast", power = 170, effect = 7 }) } }) },
      bMons = { mon({ species = "Beta", spd = 10, hp = 20, maxHp = 400,
                      moves = { move({ id = "splash", power = 0, effect = 85 }) } }) } })
    drain(b)
    b:submitChoice("p1", FIGHT)
    b:submitChoice("p2", FIGHT)
    drain(b)
    local o = b:outcome()
    if case.winner then
      eq(o and o.winners and o.winners[1], case.winner,
         "wild: both last monsters down -- the player blacks out (HandlePlayerBlackOut)")
    else
      eq(o and o.outcome, "draw", "1v1: both carts black out -- a draw")
    end
  end

  -- ROAR / WHIRLWIND blow the TARGET away: its seat is the runner.
  b = battleOf({ mode = "wild",
    aMons = { mon({ level = 50, spd = 90, moves = { move({ id = "WHIRLWIND", power = 0, effect = 28 }) } }) },
    bMons = { mon({ species = "Beta", level = 5, spd = 10, moves = { move({ id = "splash", power = 0, effect = 85 }) } }) } })
  drain(b)
  b:submitChoice("p1", FIGHT)
  b:submitChoice("p2", FIGHT)
  local runSide = nil
  for _, e in ipairs(drain(b)) do if e.t == "run" then runSide = e.side end end
  eq(runSide, "b", "WHIRLWIND: the wild monster was blown away -- its seat ran")
  eq(b:outcome() and b:outcome().winners[1], "p1", "...side a stays")

  -- ItemUseFailed: a POTION at full HP is handed back, item and turn.
  b = battleOf({ aBag = { POTION = 1 } })
  drain(b)
  eq(b:submitChoice("p1", { action = "item", item = "POTION", slot = 0 }), false,
     "a POTION at full HP is refused unfiled (`.healingItemNoEffect` -> ItemUseFailed)")
  eq(b.byId.p1.bag.POTION, 1, "...the bag keeps it")

  -- ETHER on a TRANSFORMed monster: the party's own move, then its PP over
  -- the copies (`.afterRestoringPP`).
  b = battleOf({ aBag = { ETHER = 1 },
    aMons = { mon({ spd = 90, moves = { move({ id = "morph", power = 0, effect = 57, pp = 5, maxPp = 5 }) } }) },
    bMons = { mon({ species = "Beta", spd = 10,
                    moves = { move({ id = "thump", pp = 12 }), move({ id = "chop", pp = 3 }) } }) } })
  drain(b)
  b:submitChoice("p1", FIGHT)
  b:submitChoice("p2", FIGHT)
  drain(b)
  b:submitChoice("p1", { action = "item", item = "ETHER", move = 0 })
  b:submitChoice("p2", FIGHT)
  drain(b)
  local alpha = b.byId.p1.mons[1]
  eq(alpha.preTransform.moves[1].pp, 5, "ETHER restored morph, the party's own move")
  eq(alpha.moves[1].pp .. "/" .. alpha.moves[2].pp, "5/0",
     "...and the four party PP bytes went over the copies: chop has none")

  -- A learned row the hub laid in (no basePp): DecrementPP's wrap reads its
  -- base off the maximum it states, before the PP Up bits move.
  b = battleOf({})
  drain(b)
  local mon1 = b.byId.p1.mons[1]
  mon1.moves[2] = { id = "learned", pp = 0, ppUps = 1, maxPp = 18, power = 10,
                    accuracy = 255, type = 0, effect = 0, chance = 0 }
  b:_decrementPp(mon1, 2)
  eq(mon1.moves[2].pp .. "/" .. mon1.moves[2].ppUps .. "/" .. mon1.moves[2].maxPp, "63/0/15",
     "a learned row's wrap: GetMaxPP re-read over the base its 18 named (15 + 3)")
  eq(mon1.moves[2].basePp, 15, "...the base kept on the row")
end

-- ------------------------------------------------------------------
-- 13. the vocabulary, on everything every scenario above produced
-- ------------------------------------------------------------------

do
  ok(#everyEvent > 100, "the suite produced a real sample of events")

  local badKind, badShape = nil, nil
  for _, event in ipairs(everyEvent) do
    if not Events.KINDS[event.t] then badKind = badKind or tostring(event.t) end
    local fine, why = Events.check(event)
    if not fine then badShape = badShape or (tostring(event.t) .. ": " .. tostring(why)) end
  end

  eq(badKind, nil, "every kind emitted is in the closed set")
  eq(badShape, nil, "every event carries only whitelisted fields")
  eq(seqGaps, 0, "sequence numbers are contiguous within a battle")
end

-- ------------------------------------------------------------------
-- 14. the mirror, when Wire is reachable
-- ------------------------------------------------------------------

do
  local loaded, Wire = pcall(need, "Wire")
  if not loaded then
    io.write("battle_sim_turn: Wire not loadable here, mirror check skipped\n")
  else
    local missing, extra = nil, nil
    for kind in pairs(Events.KINDS) do
      if not Wire.BATTLE_EVENTS[kind] then extra = extra or kind end
    end
    for kind in pairs(Wire.BATTLE_EVENTS) do
      if not Events.KINDS[kind] then missing = missing or kind end
    end
    eq(extra, nil, "the mirror invents no kind Wire has not got")
    eq(missing, nil, "and drops none of Wire's")

    -- Read in the Red dialect (generation 1), the one a hub hands these
    -- events to: a `msg` line keeps the cart's battle glyphs there
    -- (Wire.battleText -- "POKé BALL", "POKéMON"), which the dialect-less
    -- reading (M.text) strips.
    local mangled = nil
    for _, event in ipairs(everyEvent) do
      local clean = Wire.battleEvent(event, 1)
      if not clean or dump(clean) ~= dump(event) then
        mangled = mangled or (tostring(event.t) .. " -> " .. tostring(clean and dump(clean)))
      end
    end
    eq(mangled, nil, "every emitted event survives Wire.battleEvent unchanged")
  end
end

-- ------------------------------------------------------------------

io.write(string.format("battle_sim_turn: %d passed, %d failed (%d events)\n",
  passed, failed, #everyEvent))
os.exit(failed == 0 and 0 or 1)
