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
  if o.catchRate ~= nil then out.catchRate = o.catchRate end
  if o.evs then out.evs = o.evs end
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
  return string.format("id=%s,pp=%d,power=%d,accuracy=%d,type=%d,effect=%d,chance=%d",
    m.id, m.pp, m.power, m.accuracy, m.type, m.effect, m.chance)
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
  ok(battle:submitChoice("p1", { action = "fight", move = 0, target = 1 }) == false,
     "a target nobody occupies is refused")
  ok(battle:submitChoice("p1", { action = "fight", move = 0, target = 0 }) == false,
     "and so is aiming at your own slot")
  ok(battle:submitChoice("p1", { action = "cancel" }) == false,
     "cancelling nothing is refused")

  ok(battle:submitChoice("p1", { action = "fight", move = 0, target = 2 }) == true,
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
  listEq(slots, { 0, 1, 2, 3 }, "numbered side a first, then side b")

  battle:submitChoice("a1", { action = "fight", move = 0 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
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
    if event.t == "msg" and event.text:find("flinched", 1, true) then
      flinched = true
    end
  end
  ok(flinched, "flinch side effect causes the slower foe to flinch")
  eq(fighterIn(battle:snapshot(), "p1").hp, p1hpBefore,
     "the flinched foe never lands its attack")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "ember", power = 40, effect = 4, chance = 100 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1 }) },
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

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 120,
        moves = { move({ id = "ember", power = 40, effect = 4, chance = 0 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 1 }) },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)

  eq(fighterIn(battle:snapshot(), "p2").status, nil,
     "burn side effect with chance 0 never inflicts burn")
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
    if event.t == "damage" and event.slot == 2 then
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

  local failed = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "But it failed" then failed = true end
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
    if event.t == "damage" and event.slot == 2 then foeDamaged = true end
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
    if event.t == "damage" and event.slot == 2 then foeDamaged = true end
  end
  ok(released, "CHARGE_EFFECT turn two auto-releases the charged move")
  ok(foeDamaged, "CHARGE_EFFECT turn two deals damage")
  alpha = activeMonOf(battle, "p1")
  ok(alpha and alpha.charging == nil, "CHARGE_EFFECT clears charging after release")
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

  local recharged = false
  for _, event in ipairs(turn1) do
    if event.t == "msg" and event.text:find("must recharge", 1, true) then
      recharged = true
    end
  end
  ok(recharged, "opening the recharge turn announces must recharge")

  local p1hp = fighterIn(battle:snapshot(), "p1").hp
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
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
  local events = drain(battle)

  local trapMsg = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text:find("trap", 1, true) then trapMsg = true end
  end
  ok(trapMsg, "trapped mon takes residual trap damage")
  ok(fighterIn(battle:snapshot(), "p2").hp < 200,
     "trap residual reduces trapped mon HP")
end

do
  local battle = battleOf({
    aMons = { mon({ species = "Alpha", maxHp = 200 }) },
    bMons = { mon({ species = "Beta", maxHp = 200 }) },
  })
  drain(battle)
  local alpha = activeMonOf(battle, "p1")
  local beta = activeMonOf(battle, "p2")
  alpha.trapping = { turns = 2, moveIndex = 1, targetSlot = 1 }
  beta.trapped = { turns = 2, damage = 10, fromSlot = 0 }
  battle:_fillForcedChoices()
  eq(battle.byId.p1.choice and battle.byId.p1.choice.action, "skip",
     "trapping locks the attacker into a skip")
  eq(battle.byId.p2.choice and battle.byId.p2.choice.action, "skip",
     "trapped locks the victim into a skip")
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
  eq(alpha and alpha.moves[1] and alpha.moves[1].pp, 8,
     "TRANSFORM_EFFECT copies move PP")
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
    if event.t == "msg" and event.text == "But it failed" then blocked = true end
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

  local storing = false
  for _, event in ipairs(turn1) do
    if event.t == "msg" and event.text:find("storing energy", 1, true) then
      storing = true
    end
  end
  ok(storing, "BIDE_EFFECT announces storing energy on turn one")

  local alpha = activeMonOf(battle, "p1")
  ok(alpha and alpha.bide ~= nil, "BIDE_EFFECT sets bide state")

  local foeHpBefore = fighterIn(battle:snapshot(), "p2").hp
  for _ = 1, 6 do
    if not alpha or not alpha.bide then break end
    if alpha.bide.turns <= 0 then break end
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drain(battle)
    alpha = activeMonOf(battle, "p1")
  end

  local released = false
  local events = {}
  for _ = 1, 4 do
  battle:submitChoice("p2", { action = "fight", move = 0 })
    events = drain(battle)
    for _, event in ipairs(events) do
      if event.t == "damage" and event.slot == 2 and event.amount > 0 then
        released = true
      end
    end
    alpha = activeMonOf(battle, "p1")
    if alpha and not alpha.bide then break end
  end

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
  eq(fighterIn(snap, "p1").hp, hpBefore - 20,
     "JUMP_KICK crash is floor(maxHp/8) minimum 1")
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
  ok(physDealt < specDealt,
     "Reflect halves physical but not Special damage")
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
    if event.t == "msg" and event.text == "Alpha's ATTACK rose" then rose = true end
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
    if event.t == "msg" and event.text == "But it failed" then failed = true end
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
  local failed = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "But it failed" then failed = true end
  end
  ok(failed, "balls fail outside wild mediated mode")
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
  battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("b1", { action = "fight", move = 0 })
  battle:submitChoice("b2", { action = "fight", move = 0, target = 1 })
  local events = drain(battle)
  local failed = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "But it failed" then failed = true end
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
  drain(battle)
  eq(battle.fighters[1].mons[1].moves[1].pp, 11, "ETHER restores 10 PP")
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
    if event.t == "msg" and event.text == "But it failed" then failed = true end
  end
  ok(failed, "unknown item ids announce But it failed")
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
  local battle = battleOf({
    aMons = { mon({ species = "Alpha", maxHp = 200, spd = 50,
      moves = { move({ id = "splash", power = 0, effect = 85 }) } }) },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 50,
      moves = { move({ id = "splash", power = 0, effect = 85 }) } }) },
  })
  drain(battle)
  local alpha = activeMonOf(battle, "p1")
  local beta = activeMonOf(battle, "p2")
  alpha.trapping = { turns = 2, moveIndex = 1, targetSlot = 1 }
  beta.trapped = { turns = 2, damage = 10, fromSlot = 0 }
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
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
  local sawMoves, firstId = false, nil
  for _, event in ipairs(events) do
    if event.t == "moves" and event.moves and event.moves[1] then
      sawMoves = true
      firstId = event.moves[1].id
    end
  end
  ok(sawMoves, "Transform emits a moves event")
  eq(firstId, "foe-one", "Transform moves event carries the foe's first move id")
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
  local sawMimic = false
  for _, event in ipairs(events) do
    if event.t == "moves" and event.moves and event.moves[1]
       and event.moves[1].id == "copied" then
      sawMimic = true
    end
  end
  ok(sawMimic, "Mimic emits a moves event with the copied move id")
end

-- ------------------------------------------------------------------
-- 23. Gen1 badge boosts on mediated fighters
-- ------------------------------------------------------------------

do
  local Effects = BattleSim.Effects
  eq(Effects.badgeBoost(64, "atk", nil), 64, "no badge set leaves the stat alone")
  eq(Effects.badgeBoost(64, "atk", { BOULDERBADGE = true }), 72,
     "BOULDERBADGE boosts attack by floor(9/8)")
  eq(Effects.badgeBoost(64, "def", { THUNDERBADGE = true }), 72,
     "THUNDERBADGE boosts defense")

  local function damageToFoe(battle)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    local events = drain(battle)
    for _, event in ipairs(events) do
      if event.t == "damage" and event.slot == 2 then
        return event.amount
      end
    end
    return nil
  end

  local function fighterSides(badges)
    return {
      a = { {
        playerId = "p1", name = "Ann", badges = badges,
        mons = { mon({
          atk = 88, def = 40, spd = 40, spc = 40,
          moves = { move({ power = 50 }) },
        }) },
      } },
      b = { { playerId = "p2", name = "Bob",
        mons = { mon({
          species = "Beta", atk = 40, def = 80, hp = 200, maxHp = 200,
          moves = { move({ power = 1 }) },
        }) },
      } },
    }
  end

  local bare = battleOf({ seed = 777001, sides = fighterSides(nil) })
  local badged = battleOf({
    seed = 777001,
    sides = fighterSides({ BOULDERBADGE = true }),
  })

  local plainDmg = damageToFoe(bare)
  local boostedDmg = damageToFoe(badged)
  ok(plainDmg and plainDmg > 0, "the unbadged attack lands")
  ok(boostedDmg and boostedDmg > plainDmg,
     "BOULDERBADGE raises mediated physical damage")
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

do
  local battle = battleOf({
    aMons = { mon({ species = "Alpha", maxHp = 200, spd = 10 }) },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 90 }) },
  })
  drain(battle)
  local a = battle.fighters[1]
  local mon = a.mons[1]
  mon.trapped = { turns = 2, damage = 10, fromSlot = 2 }
  battle:submitChoice("p2", { action = "fight", move = 0 })
  -- Open next turn after resolving: force-fill should narrate can't move.
  -- Directly exercise _fillForcedChoices via a fresh turn.
  battle.fighters[2].choice = { action = "skip" }
  a.choice = nil
  battle:_fillForcedChoices()
  local events = drain(battle)
  local said = false
  for _, event in ipairs(events) do
    if event.t == "msg" and tostring(event.text):find("can't move", 1, true) then
      said = true
    end
  end
  ok(said, "trap immobilize narrates can't move")
  ok(a.choice and a.choice.action == "skip", "and files a skip")
end

do
  local battle = battleOf({
    aMons = {
      mon({
        species = "Alpha", maxHp = 200, spd = 10,
        moves = { move({ id = "WRAP", power = 15, effect = 42 }) },
      }),
    },
    bMons = { mon({ species = "Beta", maxHp = 200, spd = 90 }) },
  })
  drain(battle)
  local a = battle.fighters[1]
  local b = battle.fighters[2]
  a.mons[1].trapping = { turns = 2, moveIndex = 1, targetSlot = 2 }
  b.mons[1].trapped = { turns = 2, damage = 10, fromSlot = 0 }
  a.choice = nil
  b.choice = nil
  battle:_fillForcedChoices()
  local events = drain(battle)
  local continued, animed, victimCant = false, false, false
  for _, event in ipairs(events) do
    if event.t == "msg" and tostring(event.text):find("WRAP continues", 1, true) then
      continued = true
    end
    if event.t == "anim" and event.slot == 0 and event.text == "WRAP" then
      animed = true
    end
    if event.t == "msg" and tostring(event.text):find("can't move", 1, true) then
      victimCant = true
    end
  end
  ok(continued, "trapper narrates the move continues")
  ok(animed, "trapper emits a continue anim (no re-roll)")
  ok(victimCant, "victim still can't move")
  ok(a.choice and a.choice.action == "skip", "trapper files skip, not fight")
  ok(b.choice and b.choice.action == "skip", "victim files skip")
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

    local mangled = nil
    for _, event in ipairs(everyEvent) do
      local clean = Wire.battleEvent(event)
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
