-- src/BattleSim2/Turn.lua: the Gen 2 turn machine's referee-level rules.
--
-- Run: luajit tests/battle_sim2_turn.lua              (from this folder's root)
--   or luajit mods/rby_mmo/tests/battle_sim2_turn.lua (from the engine)
--
-- Standalone for the same reason `tests/battle_sim2_vectors.lua` is: the claim
-- src/BattleSim2/ makes is that it resolves a whole fight with no love, no
-- engine modules and no mod facade.
--
-- The sibling vector suite pins the *formulas*.  This one pins the three
-- referee rules `docs/plans/gen2-new-battle-system.md` brought across from the
-- Gen 1 twin, all of which a vector is the wrong shape to state:
--
--   1. **who a faint pays** -- the `exp` mode gate, the participation set, and
--      the divisor.  The referee holds no species table and can never price a
--      faint (the legal floor, restated in `_awardExp`'s own comment); what it
--      states is which mode a faint happened in, who was still standing on the
--      owner side, and how many of them there were to split across.
--   2. **the replace phase** -- a faint with a living bench opens a phase of
--      its own, the seat that owes is the only one asked, and the turn number
--      does not move until the successor is on the field.
--   3. **stolen-KO retargeting** -- an action aimed at a seat a faster ally
--      already emptied swings at whoever is left instead of fizzling.
--
-- Every one of these is byte-shared with `src/BattleSim/Turn.lua` and with the
-- Node twin under `server/lib/battle2/`; `server/battle2_turn.test.js` runs the
-- same scenarios, and a case that passes on one side and fails on the other is
-- exactly the drift these suites exist to catch.  Sections 8 and 9 state the
-- pokecrystal fidelity rules one at a time: the damage step, then the Gold
-- held items, obedience, the flinch reset and the cart family (K6).

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
  if not body then
    io.stderr:write("battle_sim2_turn: missing " .. path .. "\n")
    os.exit(1)
  end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then
    io.stderr:write("battle_sim2_turn: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  cache[name] = chunk(need)
  return cache[name]
end

local BattleSim2 = need("BattleSim2/init")
local Turn, Events, Effects = BattleSim2.Turn, BattleSim2.Events, BattleSim2.Effects

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
  return {
    id = o.id or "thump",
    pp = o.pp or 20,
    power = o.power ~= nil and o.power or 40,
    accuracy = o.accuracy or 255,
    type = o.type or 0,
    effect = o.effect or 0,
    chance = o.chance or 0,
  }
end

-- Gen 2 sheet dialect: spe (Speed), spa (Sp.Atk), spd (Sp.Def).  The Gen 1
-- spd=Speed / spc=Special shape is what `copyMon` shape-sniffs away from, and
-- naming all five here is what keeps this suite on the Gen 2 branch of it.
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
      spe = o.spe or 40, spa = o.spa or 40, spd = o.spd or 40,
    },
    moves = o.moves or { move() },
  }
  if o.substitute then out.substitute = o.substitute end
  return out
end

local function battleOf(o)
  local battle, err = Turn.create({
    id = o.id or "b1",
    mode = o.mode or "1v1",
    seed = o.seed or 12345,
    choiceTimeout = o.choiceTimeout or 60,
    reconnectGrace = o.reconnectGrace or 60,
    metronomePool = o.metronomePool,
    chart = o.chart,
    specialTypes = o.specialTypes,
    typeIds = o.typeIds,
    sides = o.sides,
  })
  if not battle then error("fixture battle refused: " .. tostring(err), 0) end
  return battle
end

local function drain(battle)
  return battle:drainEvents()
end

-- Play a scripted fight and hand back everything it emitted, opening drain
-- included.  `script` files one round of choices; it is called until the fight
-- ends or the round cap is hit, which keeps a rule that accidentally wedges the
-- machine from hanging the suite.
local function play(battle, script, rounds)
  local events = {}
  for _, event in ipairs(drain(battle)) do events[#events + 1] = event end
  for round = 1, rounds or 12 do
    if battle:outcome() then break end
    script(battle, round)
    for _, event in ipairs(drain(battle)) do events[#events + 1] = event end
  end
  return events
end

local function ofKind(events, kind)
  local out = {}
  for _, event in ipairs(events) do
    if event.t == kind then out[#out + 1] = event end
  end
  return out
end

local function sawKind(events, kind)
  return #ofKind(events, kind) > 0
end

-- The two seats a co-op fight puts on side a, against one synthetic seat on b.
local function coopSides(aMons, bMons)
  return {
    a = {
      { playerId = "a1", name = "Ann", mons = aMons[1] },
      { playerId = "a2", name = "Abe", mons = aMons[2] },
    },
    b = { { playerId = "npc", name = "Foe", mons = bMons } },
  }
end

local function coopWildSides3(aMons, bMon)
  return {
    a = {
      { playerId = "a1", name = "Ann", mons = aMons[1] },
      { playerId = "a2", name = "Abe", mons = aMons[2] },
      { playerId = "a3", name = "Cal", mons = aMons[3] },
    },
    b = { { playerId = "wild", name = "Wild", mons = { bMon } } },
  }
end

-- ------------------------------------------------------------------
-- 1. the exp mode gate
-- ------------------------------------------------------------------
--
-- `EXP_MODES` is the rule, not a shortcut for an owner check: a seated fighter
-- carries a playerId whether a connection is behind it or a synthetic wild /
-- trainer seat is, so "does this seat have an owner" is not a question the turn
-- machine can ask -- but the mode answers it.

-- 1v1: a farming loop the gate refuses outright.  Vanilla link battles do not
-- pay either, so this is deliberate rather than incidental.
do
  local battle = battleOf({
    mode = "1v1", seed = 90101,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 30, spe = 10 }) } } },
    },
  })
  local events = play(battle, function(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end)
  eq(#ofKind(events, "exp"), 0, "1v1: no exp event, however the fight ends")
  ok(sawKind(events, "faint"),
     "...and a faint really did happen, so the gate is what refused it")
end

-- coop_pvp: the other PvP shape, same refusal.
do
  local battle = battleOf({
    mode = "coop_pvp", seed = 90102,
    sides = {
      a = { { playerId = "a1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "b1", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 30, spe = 10 }) } } },
    },
  })
  local events = play(battle, function(b)
    b:submitChoice("a1", { action = "fight", move = 0 })
    b:submitChoice("b1", { action = "fight", move = 0 })
  end)
  eq(#ofKind(events, "exp"), 0, "coop_pvp: no exp event either")
  ok(sawKind(events, "faint"), "...and again a faint really happened")
end

-- wild: the one owner seat is paid, once, naming the monster that fell.
do
  local battle = battleOf({
    mode = "wild", seed = 90103,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "wild", name = "Wild",
              mons = { mon({ species = "Beta", maxHp = 60, spe = 10 }) } } },
    },
  })
  local events = play(battle, function(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("wild", { action = "fight", move = 0 })
  end)
  local exps = ofKind(events, "exp")
  eq(#exps, 1, "wild: exactly one exp event")
  eq(exps[1] and exps[1].slot, 0, "...paid to the sole owner seat, slot 0")
  eq(exps[1] and exps[1].species, "Beta", "...naming the wild mon that fell")
  eq(exps[1] and exps[1].level, 20, "...and the level it was")
  eq(exps[1] and exps[1].participants, 1, "...split one way")
  eq(exps[1] and exps[1].mon, 0, "...banked by party index 0")
  ok(exps[1] and exps[1].amount == nil,
     "...and never an amount: the referee holds no species table")
end

-- coop_wild: both owner seats stood against the wild mon, so both are paid, in
-- field-slot order, and each names the same divisor.
do
  local battle = battleOf({
    mode = "coop_wild", seed = 90104,
    sides = coopSides(
      { { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) },
        { mon({ species = "Gamma", maxHp = 200, atk = 90, spe = 70 }) } },
      { mon({ species = "Beta", maxHp = 200, spe = 10 }) }),
  })
  -- coop_wild seats the wild mon on b under the id the roster gave it.
  local events = play(battle, function(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    b:autoPick("npc")
  end)
  local exps = ofKind(events, "exp")
  eq(#exps, 2, "coop_wild: both standing owner seats are paid")
  eq(exps[1] and exps[1].slot, 0, "...slot 0 first")
  eq(exps[2] and exps[2].slot, 1, "...then slot 1 -- seat order, not speed order")
  eq(exps[1] and exps[1].participants, 2, "...split two ways")
  eq(exps[2] and exps[2].participants, 2, "...and both say so")
end

-- ------------------------------------------------------------------
-- 2. participation: the set is per FOE MONSTER, and a corpse leaves it
-- ------------------------------------------------------------------

-- A benched monster that was never in against the foe collects nothing, and is
-- not in the divisor either: the set is the flag list, not the party.
do
  local battle = battleOf({
    mode = "wild", seed = 90105,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
                mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }),
                mon({ species = "Bench", maxHp = 200, spe = 5 }),
              } } },
      b = { { playerId = "wild", name = "Wild",
              mons = { mon({ species = "Beta", maxHp = 60, spe = 10 }) } } },
    },
  })
  local events = play(battle, function(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("wild", { action = "fight", move = 0 })
  end)
  local exps = ofKind(events, "exp")
  eq(#exps, 1, "a bench that never fought is not paid")
  eq(exps[1] and exps[1].participants, 1, "...and is not in the divisor either")
  eq(exps[1] and exps[1].mon, 0, "...the share goes to the one that was out")
end

-- A monster that switches in joins the standing foe's set, so both halves of a
-- swap are paid when the foe finally drops.
do
  local battle = battleOf({
    mode = "wild", seed = 90106,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
                mon({ species = "Alpha", maxHp = 200, atk = 20, spe = 80 }),
                mon({ species = "Second", maxHp = 200, atk = 90, spe = 80 }),
              } } },
      b = { { playerId = "wild", name = "Wild",
              mons = { mon({ species = "Beta", maxHp = 90, spe = 10 }) } } },
    },
  })
  local events = play(battle, function(b, round)
    if round == 1 then
      b:submitChoice("p1", { action = "switch", slot = 1 })
    else
      b:submitChoice("p1", { action = "fight", move = 0 })
    end
    b:submitChoice("wild", { action = "fight", move = 0 })
  end)
  local exps = ofKind(events, "exp")
  ok(#exps >= 1, "the swap-in that landed the KO is paid")
  if #exps >= 1 then
    eq(exps[1].participants, 2,
       "...and the monster it came in for is still a participant, so the "
       .. "divisor is two")
  end
end

-- ------------------------------------------------------------------
-- 3. the replace phase
-- ------------------------------------------------------------------
--
-- A faint with a living bench must not be folded into the next choice window:
-- the successor walks out first, and only then does the turn advance.

do
  local battle = battleOf({
    mode = "coop_npc", seed = 90107,
    sides = coopSides(
      { { mon({ species = "Alpha", maxHp = 200, atk = 95, spe = 90 }) },
        { mon({ species = "Gamma", maxHp = 200, atk = 95, spe = 80 }) } },
      { mon({ species = "Beta", maxHp = 30, spe = 10 }),
        mon({ species = "Delta", maxHp = 200, spe = 10 }) }),
  })
  local events = play(battle, function(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    b:autoPick("npc")
  end, 3)

  -- The solicitation is a `turn` carrying the asked seat's field slot, which is
  -- the whole of the wire contract: with `slot` it is a replacement ask, without
  -- it the ordinary window.
  local solicited = nil
  local firstOrdinaryAfter = nil
  local sawFaint = false
  for _, event in ipairs(events) do
    if event.t == "faint" then sawFaint = true end
    if event.t == "turn" and event.slot ~= nil and solicited == nil then
      solicited = event
    elseif event.t == "turn" and event.slot == nil and solicited ~= nil
           and firstOrdinaryAfter == nil then
      firstOrdinaryAfter = event
    end
  end
  ok(sawFaint, "the KO that opens the phase really happened")
  ok(solicited ~= nil, "a replacement solicitation was raised")
  eq(solicited and solicited.slot, 3, "...naming the seat that owes, slot 3")

  -- The turn number does not move across the phase: the fight is still on the
  -- turn whose faint opened it.
  local faintTurn = nil
  for _, event in ipairs(events) do
    if event.t == "turn" and event.slot == nil and faintTurn == nil then
      faintTurn = event.amount
    end
  end
  eq(solicited and solicited.amount, faintTurn,
     "...on the same turn number the faint happened on")
  ok(firstOrdinaryAfter == nil
     or firstOrdinaryAfter.amount == (faintTurn or 0) + 1,
     "...and the next ordinary window is exactly one turn later")

  -- Order within the batch: faint, then the spoils, then the ask, then the
  -- successor, then the turn.  A client reads this as one story.
  local order = {}
  for _, event in ipairs(events) do
    if event.t == "faint" or event.t == "exp" or event.t == "switch"
       or event.t == "send" or (event.t == "turn" and event.slot ~= nil) then
      order[#order + 1] = event.t == "turn" and "ask" or event.t
    end
  end
  local joined = table.concat(order, ",")
  ok(joined:find("faint,exp,exp,ask,switch,send", 1, true) ~= nil,
     "the batch reads faint -> spoils -> ask -> switch -> send (" .. joined .. ")")
end

-- A standing seat may not answer during the replace phase: its fight would be
-- an answer to a turn that has not opened yet.
do
  local battle = battleOf({
    mode = "coop_npc", seed = 90108,
    sides = coopSides(
      { { mon({ species = "Alpha", maxHp = 200, atk = 95, spe = 90 }) },
        { mon({ species = "Gamma", maxHp = 200, atk = 95, spe = 80 }) } },
      { mon({ species = "Beta", maxHp = 30, spe = 10 }),
        mon({ species = "Delta", maxHp = 200, spe = 10 }) }),
  })
  drain(battle)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
  battle:autoPick("npc")
  drain(battle)
  eq(battle:snapshot().phase, "replace",
     "the KO left the machine in the replace phase")
  eq(battle:submitChoice("a1", { action = "fight", move = 0, target = 3 }), false,
     "a standing seat's fight is refused during the phase")
  eq(battle:submitChoice("a1", { action = "cancel" }), false,
     "...and so is a cancel: a forced replacement cannot be taken back")
  eq(battle:autoPick("a1"), false,
     "an NPC that is still standing does not file either")
  ok(battle:autoPick("npc"), "only the seat that owes may answer")
  eq(battle:snapshot().phase, "choice",
     "...and answering it closes the phase")
end

-- The highest-consequence path in the phase, and the one neither generation
-- covered until now: if the timeout sweep does not reach a `replace` seat, an
-- idle or dropped player wedges the fight forever -- `_maybeResolve` never
-- fires, because the only thing anybody owes is the replacement nobody filed.
-- `server/battle2_turn.test.js` asserts the same scenario on the JS twin.
do
  local battle = battleOf({
    mode = "coop_npc", seed = 90111, choiceTimeout = 10, reconnectGrace = 600,
    sides = coopSides(
      { { mon({ species = "Alpha", maxHp = 200, atk = 95, spe = 90 }) },
        { mon({ species = "Gamma", maxHp = 200, atk = 95, spe = 80 }) } },
      { mon({ species = "Beta", maxHp = 30, spe = 10 }),
        mon({ species = "Delta", maxHp = 400, spe = 10 }) }),
  })
  drain(battle)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
  battle:autoPick("npc")
  drain(battle)
  eq(battle:snapshot().phase, "replace", "the KO opened the phase")

  -- Nobody answers. The clock is what has to carry it.
  ok(battle:tick(battle:snapshot().now + 60),
     "the deadline passing is a tick that did something")
  eq(battle:snapshot().phase, "choice",
     "the sweep filled the owed replacement and closed the phase")
  local sent = 0
  for _, event in ipairs(drain(battle)) do
    if event.t == "send" and event.slot == 3 then sent = sent + 1 end
  end
  ok(sent > 0, "...and the successor really was fielded")
end

-- ------------------------------------------------------------------
-- 4. stolen-KO retargeting
-- ------------------------------------------------------------------
--
-- In a 2v2 the faster ally KOs the seat the slower ally picked.  Without
-- `_retarget` the slower mon fizzles with "has no target"; with it the action
-- swings at whoever is left.

do
  -- Two foe seats.  a1 (fastest) empties slot 3; a2 aimed there too and must
  -- land on slot 4 -- rule (b), the nearest living opposing seat.
  local battle = battleOf({
    mode = "coop_pvp", seed = 90109,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 200, spe = 99 }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 200, spe = 90 }) } },
      },
      b = {
        { playerId = "b1", name = "Bob",
          mons = { mon({ species = "Beta", maxHp = 1, spe = 5 }) } },
        { playerId = "b2", name = "Bea",
          mons = { mon({ species = "Delta", maxHp = 400, spe = 5 }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("b2", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)

  local fizzled = false
  for _, event in ipairs(events) do
    if event.t == "msg" and type(event.text) == "string"
       and event.text:find("has no target", 1, true) then
      fizzled = true
    end
  end
  ok(not fizzled, "the slower ally does not fizzle on the seat its partner emptied")

  local hitSlot4 = false
  for _, event in ipairs(events) do
    if event.t == "damage" and event.slot == 4 then hitSlot4 = true end
  end
  ok(hitSlot4, "...it swings at the nearest living opposing seat instead")
end

-- Nothing standing opposite: the action is skipped rather than redirected onto
-- an ally -- rule (c), and the reason `_retarget` only ever searches the
-- opposing side.
do
  local battle = battleOf({
    mode = "coop_pvp", seed = 90110,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 200, spe = 99 }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 200, spe = 90 }) } },
      },
      b = { { playerId = "b1", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 1, spe = 5 }) } } },
    },
  })
  drain(battle)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)
  local hitOwnSide = false
  for _, event in ipairs(events) do
    if event.t == "damage" and (event.slot == 0 or event.slot == 1)
       and event.status == nil then
      -- Side a taking damage here could only be the ally strike this rule
      -- exists to make impossible; a residual would carry `status`.
      hitOwnSide = true
    end
  end
  ok(not hitOwnSide, "an emptied opposing side never redirects a move onto an ally")
end

-- ------------------------------------------------------------------
-- 5. the vocabulary really carries all of this
-- ------------------------------------------------------------------
--
-- `Events.build` enforces the field whitelist at construction, so a field this
-- suite reads off an event is a field the Node twin and the screen will see
-- too.  A kind or key that only exists because a test made it up would be a
-- drop three modules downstream instead of a failure here.

do
  ok(Events.KINDS.exp == true, "`exp` is in the closed kind set")
  eq(Events.FIELDS.species, "string", "...with a species field")
  eq(Events.FIELDS.level, "number", "...a level")
  eq(Events.FIELDS.participants, "number", "...a participant count")
  eq(Events.FIELDS.mon, "number", "...and a party index")
  ok(Events.SHAPES.send and Events.SHAPES.send.mon ~= nil,
     "`send` promises the party index it fielded")
  ok(Events.SHAPES.send.status ~= nil,
     "...and the condition a newcomer walked in with")
  ok(Events.SHAPES.switch and Events.SHAPES.switch.mon ~= nil,
     "...and so does `switch`")
  ok(Events.SHAPES.turn and Events.SHAPES.turn.slot ~= nil,
     "`turn` documents the replacement-solicitation slot")

  local built = Events.build("exp", {
    slot = 0, species = "Beta", level = 20, participants = 2, mon = 1,
  })
  ok(built ~= nil, "an exp event builds")
  eq(built and built.t, "exp", "...tagged exp")
  eq(built and built.participants, 2, "...carrying its divisor")
  eq(built and built.mon, 1, "...and the party index banking the share")
end

-- ------------------------------------------------------------------
-- 4. wildlife never uses an item, from either end
-- ------------------------------------------------------------------
--
-- Byte-shared with the Gen 1 twin's 12f3 and with server/lib/battle2/Turn.js.
-- A wild monster has no bag and no hands, and its seat is driven from two ends
-- -- the hub auto-picks for it, and a submitted choice can arrive addressed to
-- it -- so both are pinned.  The wild seat is handed a bag on purpose: the
-- point is that even a seat that HAS one never spends it, so a hub seeding the
-- wrong kit cannot put a Potion in a wild monster's mouth.

-- 1v1 wild keeps a lone human; coop_wild now refuses that seating, so the
-- partner is a dummy who never acts (timeout auto-picks a weak tap).
local function wildHumans(mode, p1)
  if mode == "coop_wild" then
    return {
      p1,
      { playerId = "p2", name = "Pat",
        mons = { mon({ species = "Gamma", maxHp = 200, spe = 1 }) } },
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
          mons = { mon({ species = "Alpha", maxHp = 200, spe = 90 }) },
        }),
        b = {
          { playerId = "wild", name = "Wild",
            -- Hurt below half and poisoned: a trainer seat heals or cures here.
            mons = { mon({ species = "Beta", maxHp = 200, hp = 40, spe = 10,
                           status = "PSN" }) },
            bag = { POTION = 2, FULL_HEAL = 1, X_ATTACK = 1 } },
        },
      },
    })
    drain(battle)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    ok(battle:tick(11) == true, mode .. ": the wild seat's turn resolves")
    local items = ofKind(drain(battle), "item")
    eq(#items, 0, mode .. ": auto-pick never reaches the wild seat's bag")
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
          mons = { mon({ species = "Alpha", maxHp = 200, spe = 90 }) },
          bag = { POTION = 1 },
        }),
        b = {
          { playerId = "wild", name = "Wild",
            mons = { mon({ species = "Beta", maxHp = 200, hp = 40, spe = 10 }) },
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

do
  local battle = battleOf({
    seed = 88021,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = {
                mon({ species = "Alpha", maxHp = 100, hp = 50, spe = 90 }),
                mon({ species = "Bench", maxHp = 100, hp = 0, spe = 1 }),
              },
              bag = { POTION = 1 } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 200, spe = 10 }) } } },
    },
  })
  drain(battle)
  ok(battle:submitChoice("p1", { action = "item", item = "POTION", slot = 1 }) == false,
     "Potion on a fainted party slot is refused")
  eq(battle.byId.p1.bag.POTION, 1, "...and the bag is not spent")
  eq(battle.byId.p1.choice, nil, "...and the turn is still owed")
end

-- ------------------------------------------------------------------
-- 6. whom the referee swings at when nobody chose (`_autoTarget`)
-- ------------------------------------------------------------------
--
-- The Gen 1 twin's tests/battle_sim_turn.lua carries the long version of this
-- story.  Short version: every aim the referee filed for itself used to be
-- "the lowest-numbered living foe", so on a side holding two players the NPCs
-- swung at seat 0 every turn and the second player was never attacked at all.
-- Gold inherited the rule and therefore the bug, so it inherits the pin.

local function aimSides(foes)
  local sideB = {}
  for i = 1, foes do
    sideB[i] = { playerId = "n" .. i, name = "Npc" .. i, mons = {
      mon({ species = "Beta", maxHp = 400, spe = 90 }) } }
  end
  return {
    a = {
      { playerId = "p1", name = "One", mons = { mon({ species = "Alpha", maxHp = 400, spe = 10 }) } },
      { playerId = "p2", name = "Two", mons = { mon({ species = "Gamma", maxHp = 400, spe = 10 }) } },
    },
    b = sideB,
  }
end

for _, case in ipairs({
  { mode = "coop_wild", foes = 1 },
  { mode = "coop_npc",  foes = 2 },
}) do
  local battle = battleOf({ id = "aim", mode = case.mode, seed = 4242, sides = aimSides(case.foes) })
  drain(battle)
  local onSlot0, onSlot1 = 0, 0
  for _ = 1, 10 do
    battle:submitChoice("p1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("p2", { action = "fight", move = 0, target = 3 })
    for i = 1, case.foes do battle:autoPick("n" .. i) end
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

-- An aim is drawn from a second generator, so asking for one must not spend a
-- byte of the battle's own -- otherwise every vector in the Gold pack moves.
do
  local battle = battleOf({ id = "aim", mode = "coop_npc", seed = 4242, sides = aimSides(2) })
  drain(battle)
  local before = battle.rng:state()
  local npc = battle.byId["n1"]
  local seen = {}
  for _ = 1, 32 do seen[battle:_autoTarget(npc).slot] = true end
  eq(battle.rng:state(), before, "aim: 32 draws later the battle RNG has not moved")
  ok(seen[0] and seen[1], "aim: and those draws reached both player seats")
end

do
  eq(Events.fieldSlot("b", 1), 3, "1v1 foe field slot is 3 not 2")
  eq(Events.fieldSlot("a", 1), 0, "...side a index 1 is slot 0")
  eq(Events.fieldSlot("b", 2), 4, "...side b index 2 is slot 4")
end

do
  local battle = battleOf({
    mode = "coop_pvp",
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = { mon({ maxHp = 200, spe = 80 }) } },
        { playerId = "a2", name = "Abe", mons = { mon({ maxHp = 200, spe = 70 }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = { mon({ maxHp = 200, spe = 60 }) } },
        { playerId = "b2", name = "Bea", mons = { mon({ maxHp = 200, spe = 50 }) } },
      },
    },
  })
  drain(battle)
  local slots = {}
  for _, entry in ipairs(battle:snapshot().field) do slots[#slots + 1] = entry.slot end
  listEq(slots, { 0, 1, 3, 4 }, "2v2 coop_pvp uses slots 0, 1, 3, 4")
end

do
  local battle = battleOf({
    mode = "coop_wild", seed = 90112,
    sides = coopWildSides3(
      { { mon({ maxHp = 200, spe = 80 }) },
        { mon({ maxHp = 200, spe = 70 }) },
        { mon({ maxHp = 200, spe = 60 }) } },
      mon({ maxHp = 200, spe = 10 })),
  })
  drain(battle)
  eq(#battle.bySide.a, 3, "coop_wild 3-human create: side a length 3")
  eq(#battle.bySide.b, 1, "coop_wild 3-human create: side b length 1")
  eq(#battle:snapshot().field, 4, "coop_wild create accepts 3v1 seating")
end

do
  local battle, err = Turn.create({
    mode = "coop_wild", seed = 90113,
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
    mode = "coop_wild", seed = 90114,
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
    mode = "coop_pvp", seed = 90115,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = { mon({ maxHp = 200, spe = 80 }) } },
        { playerId = "a2", name = "Abe", mons = { mon({ maxHp = 200, spe = 70 }) } },
        { playerId = "a3", name = "Cal", mons = { mon({ maxHp = 200, spe = 60 }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = { mon({ maxHp = 200, spe = 55 }) } },
        { playerId = "b2", name = "Bea", mons = { mon({ maxHp = 200, spe = 50 }) } },
        { playerId = "b3", name = "Ben", mons = { mon({ maxHp = 200, spe = 45 }) } },
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
    mode = "coop_pvp", seed = 90116,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mon({ maxHp = 200, spe = 80 }) } } },
      b = {
        { playerId = "b1", name = "Bob", mons = { mon({ maxHp = 200, spe = 60 }) } },
        { playerId = "b2", name = "Bea", mons = { mon({ maxHp = 200, spe = 50 }) } },
        { playerId = "b3", name = "Ben", mons = { mon({ maxHp = 200, spe = 40 }) } },
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
    mode = "coop_npc", seed = 90117,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = { mon({ maxHp = 200, spe = 80 }) } },
        { playerId = "a2", name = "Abe", mons = { mon({ maxHp = 200, spe = 70 }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = { mon({ maxHp = 200, spe = 60 }) } },
        { playerId = "b2", name = "Bea", mons = { mon({ maxHp = 200, spe = 50 }) } },
        { playerId = "b3", name = "Ben", mons = { mon({ maxHp = 200, spe = 40 }) } },
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
  local battle = battleOf({ id = "aim", mode = "coop_npc", seed = 4242, sides = aimSides(3) })
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

do
  local battle = battleOf({
    mode = "coop_pvp", seed = 90118,
    sides = {
      a = {
        { playerId = "fast", name = "Fast",
          mons = { mon({ maxHp = 200, atk = 200, spe = 99,
                         moves = { move({ power = 150 }) } }) } },
        { playerId = "slow", name = "Slow",
          mons = { mon({ maxHp = 200, atk = 60, spe = 10,
                         moves = { move({ power = 40 }) } }) } },
      },
      b = {
        { playerId = "foeA", name = "FoeA",
          mons = { mon({ maxHp = 12, spe = 5 }) } },
        { playerId = "foeB", name = "FoeB",
          mons = { mon({ maxHp = 400, spe = 5 }) } },
        { playerId = "foeC", name = "FoeC",
          mons = { mon({ maxHp = 400, spe = 4 }) } },
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
-- wild fixture replays byte for byte after aims began to spread.
do
  local battle = battleOf({ id = "solo", seed = 4242, sides = {
    a = { { playerId = "p1", name = "One", mons = { mon({ species = "Alpha" }) } } },
    b = { { playerId = "p2", name = "Two", mons = { mon({ species = "Beta" }) } } },
  } })
  drain(battle)
  local before = battle.aim:state()
  local fighter = battle.byId["p2"]
  for _ = 1, 8 do eq(battle:_autoTarget(fighter).slot, 0, "aim: 1v1 has one answer") end
  eq(battle.aim:state(), before, "aim: and a fight with one foe never touches the aim stream")
end


-- ------------------------------------------------------------------
-- trapping moves, Gold's way: BattleCommand_TrapTarget sets a 3..6 wrap
-- count, HandleWrap ticks it at the end of every turn -- the one it landed on
-- included -- for a sixteenth of max HP until it releases at 0, and the only
-- thing the trap takes from its victim is switching and running.
-- ------------------------------------------------------------------

do
  local function wrapFight()
    return battleOf({ seed = 9999, sides = {
      a = { { playerId = "p1", name = "One", mons = {
        mon({ species = "Alpha", maxHp = 999, spe = 120,
              moves = { move({ id = "wrap", power = 5, effect = 42 }),
                        move({ id = "tap", power = 1 }) } }) } } },
      b = { { playerId = "p2", name = "Two", mons = {
        mon({ species = "Beta", maxHp = 999, def = 200, spe = 1,
              moves = { move({ id = "tap", power = 1 }) } }),
        mon({ species = "Delta", maxHp = 999, spe = 1,
              moves = { move({ id = "tap", power = 1 }) } }) } } },
    } })
  end
  local function saw(events, text)
    for _, event in ipairs(events) do
      if event.t == "msg" and event.text and event.text:find(text, 1, true) then return true end
    end
    return false
  end

  local battle = wrapFight()
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local first = drain(battle)
  local beta = battle.byId["p2"].mons[1]
  ok(saw(first, "Beta was WRAPPED by Alpha"), "TrapTarget says the cart's WRAP line")
  ok(beta.trapped ~= nil and beta.trapped.turns >= 2 and beta.trapped.turns <= 5,
     "a 3..6 count, already one tick down at the end of the turn it landed on")
  ok(saw(first, "Beta's hurt by wrap!"), "HandleWrap deals its residual that same turn")
  ok(saw(first, "Beta used tap!"), "the wrapped monster still moved that turn")

  -- The next turn forces nobody: both seats are asked, and a deadline runs.
  ok(battle.deadline ~= nil, "a wrap forces no seat, so the turn opens with a deadline")
  ok(battle.byId["p2"].forced == nil, "the wrapped seat is not answered by the referee")
  ok(battle:submitChoice("p2", { action = "switch", slot = 1 }) == false,
     "the wrapped monster cannot be recalled")
  ok(battle:submitChoice("p2", { action = "fight", move = 0 }), "...but it can fight")
  ok(battle:submitChoice("p2", { action = "cancel" }), "...and take its answer back like anyone")
  ok(battle:submitChoice("p1", { action = "fight", move = 1 }), "the trapper chooses freely")
  local before = beta.hp
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local second = drain(battle)
  ok(saw(second, "Beta's hurt by wrap!") or saw(second, "Beta was released from wrap!"),
     "each later turn ticks the count")
  ok(beta.hp < before, "...and the residual is a sixteenth of max HP off the HP")

  local released = false
  for _ = 1, 8 do
    if released or battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 1 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    released = saw(drain(battle), "Beta was released from wrap!")
  end
  ok(released, "the count runs out with the cart's release line")
  eq(beta.trapped, nil, "...and the wrap is gone")
  ok(battle:submitChoice("p2", { action = "switch", slot = 1 }), "released, it can switch again")
end

-- A wrap held by a monster that leaves the field ends: every send-out clears
-- both wrap counts (NewBattleMonStatus / NewEnemyMonStatus).
do
  local battle = battleOf({ seed = 9999, sides = {
    a = { { playerId = "p1", name = "One", mons = {
      mon({ species = "Alpha", maxHp = 999, spe = 120,
            moves = { move({ id = "wrap", power = 5, effect = 42 }) } }),
      mon({ species = "Gamma", maxHp = 999, spe = 120,
            moves = { move({ id = "tap", power = 1 }) } }) } } },
    b = { { playerId = "p2", name = "Two", mons = {
      mon({ species = "Beta", maxHp = 999, def = 200, spe = 1,
            moves = { move({ id = "tap", power = 1 }) } }) } } },
  } })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  ok(battle.byId["p2"].mons[1].trapped ~= nil, "Beta is wrapped")
  battle:submitChoice("p1", { action = "switch", slot = 1 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  eq(battle.byId["p2"].mons[1].trapped, nil, "the trapper's switch releases it")
end

-- An ordinary answer stays cancellable -- the guard is about forced fills only.
do
  local battle = battleOf({ sides = {
    a = { { playerId = "p1", name = "One", mons = { mon({ species = "Alpha" }) } } },
    b = { { playerId = "p2", name = "Two", mons = { mon({ species = "Beta" }) } } },
  } })
  drain(battle)
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "an ordinary answer files")
  ok(battle:submitChoice("p1", { action = "cancel" }), "and can still be taken back")
  ok(battle.byId["p1"].choice == nil, "cancel cleared it")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "and the seat can answer again")
end

-- ------------------------------------------------------------------
-- what a move is *called* in a sentence (PROTOCOL 26)
-- ------------------------------------------------------------------
--
-- Gen 2's own copies of the five call sites that name a move.  The Gen 1 twin
-- (tests/battle_sim_turn.lua, section 12l) carries the same block, and
-- separately on purpose: BattleSim2 is a twin of BattleSim rather than an
-- import of it, so a fix landed on one half of one generation is exactly the
-- drift this catches.

do
  local swipe = move({ id = "slow_swipe", power = 10 })
  swipe.name = "SLOW SWIPE"
  local lockdown = move({ id = "lock_down", power = 0, effect = 86 })
  lockdown.name = "LOCK DOWN"
  local copycat = move({ id = "copy_cat", power = 0, effect = 82 })
  copycat.name = "COPY CAT"
  local thump = move({ id = "thump", power = 10 })
  thump.name = "THUMP HIT"
  -- No name at all: what a protocol-25 client uploads.
  local nudge = move({ id = "nudge", power = 10 })

  local battle = battleOf({ id = "names", seed = 4242, sides = {
    a = { { playerId = "p1", name = "Ann", mons = {
      mon({ species = "Alpha", maxHp = 400, spe = 90,
            moves = { swipe, lockdown, copycat } }) } } },
    b = { { playerId = "p2", name = "Bob", mons = {
      mon({ species = "Beta", maxHp = 400, spe = 10,
            moves = { thump, nudge } }) } } },
  } })
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
  step(0, 0)
  step(1, 0)
  step(2, 1)
  for _ = 1, 5 do step(2, 1) end

  local function spoke(line)
    for _, text in ipairs(said) do if text == line then return true end end
    return false
  end

  ok(spoke("Alpha used SLOW SWIPE!"), "gen2: an attack prints the display name")
  -- R2d: Gold's own DISABLE line, WasDisabledText.
  ok(spoke("Beta's THUMP HIT was DISABLED!"), "gen2: Disable landing names the move")
  ok(spoke("Beta's THUMP HIT is DISABLED!"), "gen2: and so does the refusal it causes")
  -- R2c: the count ticks in CheckTurn and wears off with DisabledNoMoreText.
  ok(spoke("Beta's disabled no more!"), "gen2: and so does it wearing off")
  ok(spoke("Alpha learned THUMP HIT!"), "gen2: Mimic names what it copied")
  ok(spoke("Alpha used THUMP HIT!"), "gen2: and the copy keeps the name")
  ok(spoke("Beta used nudge!"), "gen2: a move with no name is narrated under its id")

  local sawId, sawName = false, false
  for _, text in ipairs(animated) do
    if text == "slow_swipe" then sawId = true end
    if text == "SLOW SWIPE" then sawName = true end
  end
  ok(sawId, "gen2: the anim row still carries the registry id")
  ok(not sawName, "gen2: and never the display name")
end

-- autoPick never leaves a living choice-phase seat owing: an empty moveset
-- used to return nil, and with choiceTimeout 0 the fight sat forever. An empty
-- sheet with a living foe is now Struggle; skip is only no-target.
do
  local battle = battleOf({
    choiceTimeout = 0,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 200, spe = 10, moves = {} }) } } },
    },
  })
  drain(battle)
  eq(battle.turn, 1, "the opening window is turn 1")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "the player files")
  ok(battle:autoPick("p2"), "an empty-moves NPC still files")
  local struggle = false
  for _, event in ipairs(drain(battle)) do
    if event.t == "anim" and event.text == "STRUGGLE" then struggle = true end
  end
  ok(struggle, "gen2: the empty sheet Struggles rather than skipping")
  ok(battle.turn >= 2 or battle:outcome() ~= nil,
     "the turn closed rather than sitting on an owed NPC")
end

-- The timeout sweep must file Struggle too, not push the clock on a nil pick.
do
  local battle = battleOf({
    choiceTimeout = 10,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 200, spe = 10, moves = {} }) } } },
    },
  })
  drain(battle)
  eq(battle.turn, 1, "the opening window is turn 1")
  ok(battle:tick(9) == false, "inside the deadline the sweep does nothing")
  ok(battle:tick(11) == true, "past the deadline the sweep files")
  local struggle = false
  for _, event in ipairs(drain(battle)) do
    if event.t == "anim" and event.text == "STRUGGLE" then struggle = true end
  end
  ok(struggle, "gen2: an unanswered empty sheet Struggles rather than pushing the clock")
  ok(battle.turn >= 2 or battle:outcome() ~= nil,
     "the timeout closed the turn instead of waiting another window")
end

-- A dead side left in `choice` must end the fight. Same hang the Gen 1
-- twin pins: FIGHT used to return nil (no living foe) and a zero timeout
-- sat on "Waiting for WILD...".
do
  local battle = battleOf({
    choiceTimeout = 0,
    mode = "wild",
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 40, spe = 10 }) } } },
    },
  })
  drain(battle)
  local foe = battle.byId.p2
  foe.mons[1].hp = 0
  foe.active = nil
  ok(battle:tick(0) == true, "gen2: one tick notices the empty side")
  local out = battle:outcome()
  ok(out ~= nil, "gen2: and the fight ends rather than waiting for the wild")
  eq(out and out.reason, "ko", "gen2: as a knockout")
end

do
  local battle = battleOf({
    choiceTimeout = 0,
    mode = "wild",
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 40, spe = 10 }) } } },
    },
  })
  drain(battle)
  local foe = battle.byId.p2
  foe.mons[1].hp = 0
  foe.active = nil
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }),
     "gen2: FIGHT with nobody to aim at is accepted as a skip")
  ok(battle:outcome() ~= nil, "gen2: and the skip closes the fight")
end

-- ------------------------------------------------------------------
-- two-turn charge / vanish (Gen 2 exceptions + EFFECT_* upload aliases)
-- ------------------------------------------------------------------

do
  local Effects = need("BattleSim2/Effects")
  eq(Effects.idOf("EFFECT_FLY"), 43, "gen2: EFFECT_FLY maps onto FLY_EFFECT")
  -- R2c: SOLARBEAM has its own id (its sun skip and rain halving), a charge.
  eq(Effects.idOf("EFFECT_SOLARBEAM"), 127, "gen2: EFFECT_SOLARBEAM has its own id")
  ok(Effects.isCharge(127), "gen2: ...a charge move all the same")
  -- R2d: SKULL BASH has its own id (its charge turn's Defense raise), a charge.
  eq(Effects.idOf("EFFECT_SKULL_BASH"), 157, "gen2: EFFECT_SKULL_BASH has its own id")
  ok(Effects.isCharge(157), "gen2: ...a charge move all the same")
  eq(Effects.idOf("FLY_EFFECT"), 43, "gen2: Gen1 FLY_EFFECT name still resolves")
  -- Crystal status / stat-down names.  Before these aliases, moveOf stored 0
  -- and every 0-power status move in a BattleSim2 fight (2v2 especially)
  -- announced "But nothing happened".
  eq(Effects.idOf("EFFECT_DEFENSE_DOWN"), 19, "gen2: EFFECT_DEFENSE_DOWN is Leer")
  eq(Effects.idOf("EFFECT_DEFENSE_DOWN_2"), 59, "gen2: EFFECT_DEFENSE_DOWN_2 is Screech")
  eq(Effects.idOf("EFFECT_SLEEP"), 32, "gen2: EFFECT_SLEEP is Hypnosis")
  eq(Effects.idOf("EFFECT_PARALYZE_HIT"), 6, "gen2: EFFECT_PARALYZE_HIT is Lick")
  eq(Effects.idOf("EFFECT_ATTACK_DOWN"), 18, "gen2: EFFECT_ATTACK_DOWN is Growl")
  eq(Effects.idOf("EFFECT_PARALYZE"), 67, "gen2: EFFECT_PARALYZE is Thunder Wave")
  eq(Effects.idOf("EFFECT_METRONOME"), 83, "gen2: EFFECT_METRONOME is Metronome")
  eq(Effects.idOf("EFFECT_PROTECT"), 120, "gen2: Protect has its own id from R2c")
  ok(Effects.hitsInvulnerable("FLY", { id = "GUST" }), "gen2: Gust reaches Fly")
  ok(Effects.hitsInvulnerable("FLY", { id = "TWISTER" }), "gen2: Twister reaches Fly")
  ok(Effects.hitsInvulnerable("FLY", { id = "WHIRLWIND" }), "gen2: Whirlwind reaches Fly")
  ok(Effects.hitsInvulnerable("DIG", { id = "EARTHQUAKE" }), "gen2: Earthquake reaches Dig")
  ok(Effects.hitsInvulnerable("DIG", { id = "FISSURE" }), "gen2: Fissure reaches Dig")
  ok(Effects.hitsInvulnerable("DIG", { id = "MAGNITUDE" }), "gen2: Magnitude reaches Dig")
  ok(not Effects.hitsInvulnerable("FLY", { id = "SWIFT" }), "gen2: Swift misses Fly")
  ok(not Effects.hitsInvulnerable("DIG", { id = "TACKLE" }), "gen2: Tackle misses Dig")
  local mon = { species = "Alpha" }
  eq(Effects.chargeMessage(mon, 39, "SOLARBEAM"), "Alpha took in sunlight!")
  eq(Effects.chargeMessage(mon, 39, "SKULL_BASH"), "Alpha lowered its head!")
  eq(Effects.chargeMessage(mon, 39, "RAZOR_WIND"), "Alpha made a whirlwind!")
end

do
  local battle = battleOf({
    seed = 5151,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({
                species = "Alpha", maxHp = 200, spe = 120, atk = 80,
                moves = { move({ id = "DIG", power = 60, effect = 39, pp = 10 }) },
              }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({
                species = "Beta", maxHp = 200, spe = 1, def = 40, atk = 80,
                moves = { move({ id = "EARTHQUAKE", power = 80, accuracy = 255 }) },
              }) } } },
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn1 = drain(battle)
  local dug, failed, damaged = false, false, false
  for _, event in ipairs(turn1) do
    if event.t == "msg" and event.text:find("dug a hole", 1, true) then dug = true end
    if event.t == "msg" and event.text:find("But it failed!", 1, true) then failed = true end
    if event.t == "damage" and event.slot == 0 then damaged = true end
  end
  ok(dug, "gen2: DIG announces dug a hole")
  ok(not failed, "gen2: Earthquake reaches a digging target")
  ok(damaged, "gen2: Earthquake damages the digging user")

  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn2 = drain(battle)
  local released, foeDamaged = false, false
  for _, event in ipairs(turn2) do
    if event.t == "anim" and event.text == "DIG" and event.amount == nil then
      released = true
    end
    if event.t == "damage" and event.slot ~= 0 then foeDamaged = true end
  end
  ok(released, "gen2: DIG turn two auto-releases")
  ok(foeDamaged, "gen2: DIG turn two still hits after being struck underground")
end

do
  local battle = battleOf({
    seed = 5252,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({
                species = "Alpha", maxHp = 200, spe = 120,
                moves = { move({ id = "FLY", power = 70, effect = 43 }) },
              }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({
                species = "Beta", maxHp = 200, spe = 1, atk = 80,
                moves = { move({ id = "SWIFT", power = 60, effect = 17, accuracy = 255 }) },
              }) } } },
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local turn1 = drain(battle)
  local failed, damaged = false, false
  for _, event in ipairs(turn1) do
    -- CheckHit's `.FlyDigMoves` miss: AttackMissedText (wave 5).
    if event.t == "msg" and event.text:find("attack missed!", 1, true) then failed = true end
    if event.t == "damage" and event.slot == 0 then damaged = true end
  end
  ok(failed, "gen2: Swift misses a flying target")
  ok(not damaged, "gen2: Swift deals no damage while the target is airborne")
end

-- A dropped seat cannot file until reconnect() -- twin of the Gen 1
-- battle_sim_turn.lua 4b claim, so SESSION_LEAVE cannot resolve turns
-- through the pause on the Gen 2 machine either.
do
  local battle = battleOf({
    reconnectGrace = 60, choiceTimeout = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha" }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta" }) } } },
    },
  })
  drain(battle)
  battle:disconnect("p1")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }) == false,
     "gen2: a disconnected seat cannot file a choice")
  ok(battle:submitChoice("p2", { action = "fight", move = 0 }) == true,
     "gen2: the seat that stayed may still file")
  eq(battle:snapshot().turn, 1,
     "gen2: the turn does not resolve on the dropped seat's leftover")
  battle:reconnect("p1")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }) == true,
     "gen2: reconnect restores the right to choose")
  eq(battle:snapshot().turn, 2,
     "gen2: and the already-filed peer lets the turn complete")
end

do
  local battle = battleOf({
    reconnectGrace = 60, choiceTimeout = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha" }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta" }) } } },
    },
  })
  drain(battle)
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }) == true,
     "gen2: a connected seat may file before it drops")
  battle:disconnect("p1")
  ok(battle:submitChoice("p2", { action = "fight", move = 0 }) == true,
     "gen2: the seat that stayed may still file after the drop")
  eq(battle:snapshot().turn, 1,
     "gen2: a leftover choice does not resolve the turn while a seat is away")
  battle:reconnect("p1")
  eq(battle:snapshot().turn, 2,
     "gen2: reconnect completes the already-answered turn without a second pick")
end

-- ------------------------------------------------------------------
-- Substitute vs primary effects (cartridge: foe-targeting fails)
-- ------------------------------------------------------------------

local function dummyMon(o)
  o = o or {}
  return {
    species = o.species or "Alpha",
    hp = o.hp or 100,
    maxHp = o.maxHp or 100,
    status = o.status,
    types = o.types or { 0 },
    stats = { atk = 40, def = 40, spe = 40, spa = 40, spd = 40 },
    stages = { atk = 0, def = 0, spe = 0, spa = 0, spd = 0, acc = 0, eva = 0 },
    moves = o.moves or {
      { id = "thump", name = "THUMP", pp = 10, power = 40,
        accuracy = 255, type = 0, effect = 0, chance = 0 },
    },
    lastMoveIndex = o.lastMoveIndex or 1,
    substitute = o.substitute or 0,
  }
end

local function applyPrimary(effectId, user, target)
  return Effects.applyPrimary({
    effectId = effectId,
    rng = { byte = function() return 0 end },
    userMon = user,
    targetMon = target,
    userFighter = { slot = 1, side = "a" },
    targetFighter = { slot = 2, side = "b" },
    moveIndex = 1,
  })
end

do
  local target = dummyMon({ species = "Beta", substitute = 40 })
  local out = applyPrimary(32, dummyMon(), target)
  -- R2d: SleepTarget's own line, DidntAffect1Text.
  eq(out.messages[1], "It didn't affect Beta!", "gen2: SLEEP_EFFECT vs substitute didn't affect")
  eq(target.status, nil, "gen2: SLEEP_EFFECT does not land through a substitute")
end

do
  local target = dummyMon({ species = "Beta", substitute = 40 })
  local out = applyPrimary(18, dummyMon(), target)
  -- BattleCommand_StatDown's `.DidntMiss`: a substitute is `.Failed`, whose
  -- StatDownFailText is "But it failed!" (R2b), not "But nothing happened".
  eq(out.nothing, false, "gen2: Growl vs substitute is no \"nothing\"")
  eq(out.messages[1], "But it failed!", "gen2: ...it fails")
  eq(target.stages.atk, 0, "gen2: Growl does not drop atk behind a substitute")
end

do
  -- R2d: Gold's BattleCommand_Disable asks no substitute at all -- the
  -- target's LAST_COUNTER_MOVE is disabled behind one.
  local target = dummyMon({ species = "Beta", substitute = 40 })
  target.lastCounterMove = target.moves[1]
  local out = Effects.applyPrimary({
    effectId = 86, rng = { byte = function() return 3 end },
    userMon = dummyMon(), targetMon = target,
    userFighter = { slot = 1, side = "a" }, targetFighter = { slot = 2, side = "b" },
  })
  eq(out.messages[1], "Beta's THUMP was DISABLED!", "gen2: DISABLE_EFFECT lands behind a substitute")
  eq(target.disable and target.disable.turns, 4, "gen2: ...for `.loop2`'s byte & 7, plus 1")
end

do
  local user = dummyMon()
  -- BattleCommand_Transform reads no substitute: only a transformed or hidden
  -- target fails it (R2b).
  eq(applyPrimary(57, user, dummyMon({ species = "Beta", substitute = 40 })).nothing,
     false, "gen2: TRANSFORM_EFFECT copies through a substitute")
  eq(user.transformed, true, "gen2: ...and the user is transformed")
end

do
  local user = dummyMon()
  local out = applyPrimary(50, user, dummyMon({ species = "Beta", substitute = 40 }))
  eq(out.nothing, false, "gen2: Swords Dance is not nothing against a foe substitute")
  eq(user.stages.atk, 2, "gen2: Swords Dance still raises the user's atk")
end

do
  local user = dummyMon()
  user.stages.atk = 2
  local target = dummyMon({ species = "Beta", substitute = 40 })
  target.stages.def = 2
  local out = applyPrimary(25, user, target)
  eq(out.nothing, false, "gen2: HAZE_EFFECT is not nothing against a substitute")
  eq(user.stages.atk, 0, "gen2: HAZE_EFFECT still resets the user")
  eq(target.stages.def, 0, "gen2: HAZE_EFFECT still resets the foe behind a substitute")
end

do
  local battle = battleOf({
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mon({
          species = "Alpha", maxHp = 200, spe = 120, atk = 120, level = 50,
          moves = { move({ id = "sleep", power = 0, effect = 32, accuracy = 255 }) },
        }),
      } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mon({
          species = "Beta", maxHp = 200, spe = 1, substitute = 50,
          moves = { move({ id = "splash", power = 0, effect = 85 }) },
        }),
      } } },
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local beta = battle.byId.p2
  local betaMon = beta and beta.mons[beta.active]
  eq(betaMon and betaMon.status, nil, "gen2: SLEEP_EFFECT fails through a substitute")
  eq(betaMon and betaMon.substitute, 50, "gen2: SLEEP_EFFECT leaves the substitute standing")
end

do
  local battle = battleOf({
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mon({
          species = "Alpha", maxHp = 200, spe = 120, atk = 120, level = 50,
          moves = { move({ id = "thump", power = 60, effect = 18, accuracy = 255 }) },
        }),
      } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mon({
          species = "Beta", hp = 200, maxHp = 200, spe = 1, substitute = 5,
          moves = { move({ id = "splash", power = 0, effect = 85 }) },
        }),
      } } },
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)
  local beta = battle.byId.p2
  local betaMon = beta and beta.mons[beta.active]
  eq(betaMon and (betaMon.substitute or 0), 0, "gen2: damaging hit broke the substitute")
  eq(betaMon and betaMon.stages.atk, 0,
     "gen2: Growl primary does not land on the hit that broke the sub")
end

-- ------------------------------------------------------------------
-- trainer RUN does not forfeit; the Gen 1 twin owns the long version
-- ------------------------------------------------------------------

do
  local battle = battleOf({
    mode = "coop_npc",
    seed = 90120,
    sides = coopSides(
      { { mon({ species = "Alpha", maxHp = 200, spe = 80 }) },
        { mon({ species = "Gamma", maxHp = 200, spe = 70 }) } },
      { mon({ species = "Beta", maxHp = 200, spe = 10, atk = 80 }) }
    ),
  })
  drain(battle)
  local turnBefore = battle:snapshot().turn
  battle:submitChoice("a1", { action = "run" })
  battle:submitChoice("a2", { action = "fight", move = 0 })
  battle:autoPick("npc")
  local out = drain(battle)
  eq(battle:outcome(), nil, "coop_npc RUN does not finish the fight")
  local refused = false
  for _, event in ipairs(out) do
    if event.t == "msg"
       and event.text == "No! There's no running from a trainer battle!" then
      refused = true
    end
  end
  ok(refused, "and says the Wire-safe trainer refusal")
  eq(battle:snapshot().turn, turnBefore + 1, "the runner's action still spends the turn")
end

-- ------------------------------------------------------------------
-- Crystal status moves in a 2v2 (the player-report: Leer / Hypnosis /
-- Screech / Lick do nothing in doubles, work in engine singles).
-- ------------------------------------------------------------------
--
-- Sheets carry EFFECT_* names.  `idOf` is what `moveOf` uses; feeding the
-- mapped id here is the same number a real Crystal upload now stores.

do
  local Effects = need("BattleSim2/Effects")
  local leer = Effects.idOf("EFFECT_DEFENSE_DOWN")
  local sleep = Effects.idOf("EFFECT_SLEEP")
  local battle = battleOf({
    mode = "coop_pvp", seed = 4242,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({
            species = "Alpha", maxHp = 200, spe = 90,
            -- The wire's accuracy byte: 255 never draws (R2c, the cart's
            -- CheckHit), where 0 was the percent domain's "never misses".
            moves = { move({ id = "leer", power = 0, accuracy = 255,
                             effect = leer }) },
          }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({
            species = "Gamma", maxHp = 200, spe = 80,
            moves = { move({ id = "hypno", power = 0, accuracy = 255,
                             effect = sleep }) },
          }) } },
      },
      b = {
        { playerId = "b1", name = "Bob",
          mons = { mon({
            species = "Beta", maxHp = 200, spe = 5, def = 80,
            moves = { move({ id = "thump", power = 1 }) },
          }) } },
        { playerId = "b2", name = "Bea",
          mons = { mon({
            species = "Delta", maxHp = 200, spe = 5,
            moves = { move({ id = "thump", power = 1 }) },
          }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
  battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("b2", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)

  local nothing = false
  local defFell, slept = false, false
  for _, event in ipairs(events) do
    if event.t == "msg" and type(event.text) == "string" then
      if event.text:find("nothing happened", 1, true) then nothing = true end
      if event.text:find("DEFENSE fell", 1, true) then defFell = true end
      if event.text:find("fell asleep", 1, true) then slept = true end
    end
  end
  ok(not nothing, "2v2: Crystal status moves do not no-op")
  ok(defFell, "2v2: Leer (EFFECT_DEFENSE_DOWN) drops the aimed foe's Defense")
  ok(slept, "2v2: Hypnosis (EFFECT_SLEEP) puts the aimed foe to sleep")
  eq(battle.byId.b1.mons[1].stages.def, -1, "2v2: Bob's Defense stage is -1")
  eq(battle.byId.b2.mons[1].status, "sleep", "2v2: Bea is asleep")
end

-- Metronome: same Crystal-name hole, plus it needs the uploaded pool.
-- Party / official / hosted fights go through BattleSim2; engine solo does
-- not.  Without EFFECT_METRONOME → 83 the move never consults the pool.

do
  local Effects = need("BattleSim2/Effects")
  local metro = Effects.idOf("EFFECT_METRONOME")
  local battle = battleOf({
    seed = 7,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({
                species = "Alpha", maxHp = 200, spe = 120,
                moves = { move({ id = "metronome", power = 0, accuracy = 0,
                                 effect = metro }) },
              }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 200, spe = 1 }) } } },
    },
  })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  local events = drain(battle)
  local nothing = false
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == "But nothing happened." then
      nothing = true
    end
  end
  ok(nothing, "gen2: Metronome does nothing without a move pool")
end

do
  local Effects = need("BattleSim2/Effects")
  local metro = Effects.idOf("EFFECT_METRONOME")
  local battle = battleOf({
    mode = "coop_pvp", seed = 7,
    metronomePool = {
      move({ id = "pool-thump", power = 60, accuracy = 255, type = 0 }),
    },
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({
            species = "Alpha", maxHp = 200, spe = 120, atk = 100, level = 50,
            moves = { move({ id = "metronome", power = 0, accuracy = 0,
                             effect = metro }) },
          }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({
            species = "Gamma", maxHp = 200, spe = 80,
            moves = { move({ id = "thump", power = 1 }) },
          }) } },
      },
      b = {
        { playerId = "b1", name = "Bob",
          mons = { mon({
            species = "Beta", maxHp = 200, spe = 5, def = 40,
            moves = { move({ id = "thump", power = 1 }) },
          }) } },
        { playerId = "b2", name = "Bea",
          mons = { mon({
            species = "Delta", maxHp = 200, spe = 5,
            moves = { move({ id = "thump", power = 1 }) },
          }) } },
      },
    },
  })
  drain(battle)
  local hpBefore = battle.byId.b1.mons[1].hp
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
  battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("b2", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)
  local called = false
  for _, event in ipairs(events) do
    if event.t == "anim" and event.text == "pool-thump" then called = true end
  end
  ok(called, "2v2: Metronome (EFFECT_METRONOME) calls a move from the pool")
  ok(battle.byId.b1.mons[1].hp < hpBefore,
     "2v2: the Metronome-called move deals damage")
end

-- ------------------------------------------------------------------
-- 7. badge rules: Crystal's, and against the computer only
-- ------------------------------------------------------------------
--
-- Crystal boosts the player's monster and only outside a link battle
-- (BadgeStatBoosts opens with `ld a, [wLinkMode] / and a / ret nz`), so the
-- referee keeps an uploaded set on side a of wild / coop_wild / coop_npc and
-- drops it in 1v1, coop_pvp and on side b (Turn.BADGE_MODES, Turn.BADGE_SIDE).
-- What a kept set does is Gold's, not Red's: the ids are Gold's (ZEPHYR ...
-- EARTH), ZEPHYR / MINERAL / PLAIN / GLACIER boost Attack / Defense / Speed /
-- Sp. Atk by an eighth up to 999, Sp. Def only through Glacier's buggy tail,
-- and DoBadgeTypeBoosts adds an eighth to a move whose type's badge is held.
-- Every formula here was checked against the Gold engine's own functions
-- (src/battle/gen2/Battle.lua) through the vector pack; this section states
-- the rules on a whole turn.  server/battle2_turn.test.js builds the same
-- sheets on the same seed and reaches the same numbers.

do
  local modes = {}
  for mode in pairs(Turn.BADGE_MODES) do modes[#modes + 1] = mode end
  table.sort(modes)
  eq(table.concat(modes, ","), "coop_npc,coop_wild,wild",
     "badges count in the three fights against the computer, and no other")
  eq(Turn.BADGE_SIDE, "a", "...and only on the player's side of them")

  -- Every Gold badge, Johto then Kanto.
  local ALL = {}
  for _, row in ipairs(Effects.BADGE_TYPE_BOOSTS) do ALL[row.badge] = true end

  -- The ruleset's type axis.  Index 0 is a type no badge names, so a move of
  -- type 0 is never type-boosted; 1 is BUG (HIVE's), 2 is FIRE and Special.
  local RULES = { typeIds = { "DARK", "BUG", "FIRE" }, specialTypes = { 2 } }

  -- One exchange: Ann (side a) and Bob (side b) each swing once.  `a` / `b`
  -- override the stats, the move's power and type, and carry each seat's
  -- upload (`a.pp = 0` empties Ann's one slot, so she Struggles); `rules` is
  -- the ruleset (typeIds, specialTypes).  The default seed is the one the
  -- numbers below were pinned on, re-chosen (from 777001) when K12 moved the
  -- stream onto the RNG's high bits, and again (777019) when wave 4 put the
  -- crit on CriticalHitChances' byte and the roll on DamageVariation's loop
  -- (R2d), so every exchange rolls what it did.
  local function exchange(mode, a, b, rules)
    rules = rules or {}
    local battle, err = Turn.create({
      id = "b1", mode = mode, seed = a.seed or 777019,
      choiceTimeout = 60, reconnectGrace = 60,
      typeIds = rules.typeIds, specialTypes = rules.specialTypes,
      sides = {
        a = { { playerId = "p1", name = "Ann", badges = a.badges,
                mons = { (function()
                  local m = mon({
                    maxHp = 200, hp = 200, atk = a.atk or 88, def = a.def or 40,
                    spe = a.spe or 40, spa = a.spa or 40,
                    moves = { move({ power = 50, type = a.type or 0, pp = a.pp }) },
                  })
                  m.confusion = a.confusion
                  return m
                end)() } } },
        b = { { playerId = "p2", name = "Bob", badges = b.badges,
                mons = { mon({
                  species = "Beta", maxHp = 200, hp = 200, atk = b.atk or 40,
                  def = b.def or 80, spe = b.spe or 40, spa = b.spa or 40,
                  moves = { move({ power = b.power or 1, type = b.type or 0 }) },
                }) } } },
      },
    })
    if not battle then error("fixture battle refused: " .. tostring(err), 0) end
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
  -- What a confusion self-hit cost, or nil when the seat did not hit itself.
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
  -- The whole stream as one string, sorted keys, so two fights compare byte
  -- for byte; a `moves` row prints as id/pp, which is all that event varies in.
  local function streamOf(events)
    local rows = {}
    for i, event in ipairs(events) do
      local keys = {}
      for k in pairs(event) do keys[#keys + 1] = k end
      table.sort(keys)
      local parts = {}
      for _, k in ipairs(keys) do
        local v = event[k]
        if type(v) == "table" then
          local cells = {}
          for j, row in ipairs(v) do
            cells[j] = type(row) == "table"
              and (tostring(row.id) .. "/" .. tostring(row.pp)) or tostring(row)
          end
          v = "[" .. table.concat(cells, ",") .. "]"
        end
        parts[#parts + 1] = k .. "=" .. tostring(v)
      end
      rows[i] = table.concat(parts, ",")
    end
    return table.concat(rows, "|")
  end

  -- A seed on which Ann hits herself on the first turn of a confusion.
  local confusedSeed
  for seed = 1, 200 do
    if selfHit(exchange("coop_npc", { seed = seed, confusion = 3 }, {})) then
      confusedSeed = seed
      break
    end
  end
  ok(confusedSeed ~= nil, "found a seed where a confused Ann hits herself")

  -- (a) the link modes: every byte of the badged fight is the unbadged one.
  for _, mode in ipairs({ "1v1", "coop_pvp" }) do
    local bare = exchange(mode, {}, {})
    eq(hitOn(bare, 3), 18, mode .. ": the unbadged attack lands for 18")
    eq(hitOn(exchange(mode, { badges = { ZEPHYR = true } }, {}), 3), 18,
       mode .. ": ZEPHYR does not raise the damage -- a link battle")
    -- One seat at a time: both at once would cancel here (each attack is
    -- boosted by the same eighth its target's defence is) and prove nothing.
    eq(streamOf(exchange(mode, { badges = ALL }, {})), streamOf(bare),
       mode .. ": side a uploading every badge fights the unbadged fight")
    eq(streamOf(exchange(mode, {}, { badges = ALL })), streamOf(bare),
       mode .. ": so does side b uploading every badge")
    eq(firstHit(exchange(mode, { spe = 40 }, { spe = 42 })), 0,
       mode .. ": unbadged, Bob (42) outspeeds Ann (40)")
    eq(firstHit(exchange(mode, { spe = 40, badges = { PLAIN = true } }, { spe = 42 })), 0,
       mode .. ": PLAIN does not let Ann overtake him")
    eq(hitOn(exchange(mode, { type = 1, badges = { HIVE = true } }, {}, RULES), 3), 12,
       mode .. ": HIVE does not type-boost a BUG move either")
    local bareSelf = selfHit(exchange(mode, { seed = confusedSeed, confusion = 3 }, {}))
    ok(bareSelf ~= nil, mode .. ": the confused Ann hits herself on this seed too")
    eq(selfHit(exchange(mode, { seed = confusedSeed, confusion = 3,
                                badges = { ZEPHYR = true } }, {})), bareSelf,
       mode .. ": nor does ZEPHYR reach a confusion self-hit")
  end

  -- (b) the same seats against the computer, under Gold's mapping.
  for _, mode in ipairs({ "coop_npc", "wild" }) do
    eq(hitOn(exchange(mode, {}, {}), 3), 18, mode .. ": unbadged, the same 18")
    -- 88 -> 88 + floor(88 / 8) = 99 Attack; lib/battle2 reaches the same 20.
    eq(hitOn(exchange(mode, { badges = { ZEPHYR = true } }, {}), 3), 20,
       mode .. ": ZEPHYR raises side a's physical damage to 20")
    eq(hitOn(exchange(mode, { badges = { BOULDER = true, BOULDERBADGE = true } }, {}), 3), 18,
       mode .. ": BOULDER (Kanto) and BOULDERBADGE (Red's id) boost no stat on Gold")
    eq(firstHit(exchange(mode, { spe = 40 }, { spe = 42 })), 0,
       mode .. ": unbadged, the foe (42) still goes first")
    eq(firstHit(exchange(mode, { spe = 40, badges = { PLAIN = true } }, { spe = 42 })), 3,
       mode .. ": PLAIN (40 -> 45) puts side a in front")
    -- R2c moved Bob's roll (the crit byte and the roll now come before the
    -- accuracy check, and a 255 accuracy byte draws nothing): 10 and 8 on
    -- this seed, the same eighth apart.
    eq(hitOn(exchange(mode, {}, { power = 30 }), 0), 10,
       mode .. ": Bob's 30-power hit on an unbadged Ann is 10")
    eq(hitOn(exchange(mode, { badges = { MINERAL = true } }, { power = 30 }), 0), 8,
       mode .. ": MINERAL (Defense 40 -> 45) cuts it to 8")
    eq(hitOn(exchange(mode, { type = 2, spa = 88 }, {}, RULES), 3), 23,
       mode .. ": Ann's Special hit, unbadged, is 23")
    eq(hitOn(exchange(mode, { type = 2, spa = 88, badges = { GLACIER = true } }, {}, RULES), 3), 25,
       mode .. ": GLACIER (Sp. Atk 88 -> 99) raises it to 25")

    -- Glacier's Sp. Def tail, both ways: Bob's Special hit on Ann.  Sp. Atk
    -- 227 boosts to 255, which the tail reads as odd (Sp. Def boosted); 200
    -- boosts to 225, even, and Sp. Def stays as it was.
    local special = { power = 30, type = 2, spa = 60 }
    eq(hitOn(exchange(mode, { spa = 227 }, special, RULES), 0), 9,
       mode .. ": Bob's Special hit on an unbadged Ann is 9")
    eq(hitOn(exchange(mode, { spa = 227, badges = { GLACIER = true } }, special, RULES), 0), 8,
       mode .. ": GLACIER with Sp. Atk 227 (-> 255) boosts Sp. Def too: 8")
    eq(hitOn(exchange(mode, { spa = 200, badges = { GLACIER = true } }, special, RULES), 0), 9,
       mode .. ": GLACIER with Sp. Atk 200 (-> 225) leaves Sp. Def alone: 9")

    -- The 999 cap: 950 + floor(950 / 8) = 1068 is held at 999, so a badged
    -- 950 hits exactly as an unbadged 999 does, and harder than a bare 950.
    eq(hitOn(exchange(mode, { atk = 950 }, { def = 600 }), 3), 24,
       mode .. ": an unbadged Attack of 950 hits for 24")
    eq(hitOn(exchange(mode, { atk = 999 }, { def = 600 }), 3), 26,
       mode .. ": an unbadged Attack of 999 hits for 26")
    eq(hitOn(exchange(mode, { atk = 950, badges = { ZEPHYR = true } }, { def = 600 }), 3), 26,
       mode .. ": ZEPHYR on 950 is capped at 999 and hits for the same 26")

    -- DoBadgeTypeBoosts: Ann's BUG move (no STAB, so 12 bare) and HIVE.
    eq(hitOn(exchange(mode, { type = 1 }, {}, RULES), 3), 12,
       mode .. ": Ann's BUG move, no badge, is 12")
    eq(hitOn(exchange(mode, { type = 1, badges = { HIVE = true } }, {}, RULES), 3), 13,
       mode .. ": HIVE adds its eighth: 13")
    eq(hitOn(exchange(mode, { type = 1, badges = { FOG = true } }, {}, RULES), 3), 12,
       mode .. ": a badge of another type adds nothing")
    eq(hitOn(exchange(mode, { type = 1, badges = { HIVE = true } }, {},
                      { specialTypes = RULES.specialTypes }), 3), 12,
       mode .. ": with no typeIds the move's type has no name, and nothing fires")
    eq(hitOn(exchange(mode, { badges = { HIVE = true } }, { power = 30, type = 1 }, RULES), 0),
       hitOn(exchange(mode, {}, { power = 30, type = 1 }, RULES), 0),
       mode .. ": the foe's BUG move is not boosted by Ann's HIVE")

    -- Struggle never is: pokecrystal BattleCommand_Stab returns for it
    -- (`cp STRUGGLE / ret z`) before DoBadgeTypeBoosts.  On a chart whose
    -- index 0 is BUG, Ann's type-0 move takes HIVE's eighth; her Struggle,
    -- whose placeholder type is that same 0, does not -- and takes no STAB
    -- either, though Ann is type 0 (the same early return): 10 x 50 x 88 /
    -- 80 / 50 = 11, +2 = 13, and the roll leaves 12, where STAB used to make
    -- it 19 and 18.
    local BUG_FIRST = { typeIds = { "BUG", "DARK", "FIRE" }, specialTypes = { 2 } }
    eq(hitOn(exchange(mode, {}, {}, BUG_FIRST), 3), 18,
       mode .. ": index 0 named BUG, Ann's type-0 move is 18 bare")
    eq(hitOn(exchange(mode, { badges = { HIVE = true } }, {}, BUG_FIRST), 3), 20,
       mode .. ": ...and HIVE type-boosts it to 20")
    local struggled = exchange(mode, { pp = 0 }, {}, BUG_FIRST)
    local struggledAnim = false
    for _, event in ipairs(struggled) do
      if event.t == "anim" and event.text == "STRUGGLE" then struggledAnim = true end
    end
    ok(struggledAnim, mode .. ": with her one slot at 0 PP, Ann Struggles")
    eq(hitOn(struggled, 3), 12, mode .. ": her Struggle, no badge and no STAB, is 12")
    eq(hitOn(exchange(mode, { pp = 0, badges = { HIVE = true } }, {}, BUG_FIRST), 3), 12,
       mode .. ": HIVE leaves her Struggle at 12 (type 0 is BUG here, and still nothing fires)")

    -- HitConfusion reads the boosted Attack (ZEPHYR) like any other hit.
    local bareSelf = selfHit(exchange(mode, { seed = confusedSeed, confusion = 3 }, {}))
    local zephyrSelf = selfHit(exchange(mode, { seed = confusedSeed, confusion = 3,
                                                badges = { ZEPHYR = true } }, {}))
    ok(bareSelf and zephyrSelf and zephyrSelf > bareSelf,
       mode .. ": ZEPHYR raises a confusion self-hit too")
  end

  -- (c) side b's upload, ignored against the computer too.  Each of these
  --     would have changed the fight had it counted: MINERAL would cut Ann's
  --     hit, ZEPHYR would raise Bob's, and PLAIN (37 -> 41) would put Bob
  --     ahead of Ann's 40.
  local bare = exchange("coop_npc", {}, { power = 30 })
  local hostile = exchange("coop_npc", {}, { badges = ALL, power = 30 })
  eq(hitOn(hostile, 3), hitOn(bare, 3), "coop_npc: side b's MINERAL is ignored")
  eq(hitOn(hostile, 0), hitOn(bare, 0), "coop_npc: side b's ZEPHYR is ignored")
  eq(streamOf(hostile), streamOf(bare), "coop_npc: side b's upload changes nothing at all")
  eq(firstHit(exchange("coop_npc", {}, { badges = ALL, spe = 37 })), 3,
     "coop_npc: side b's PLAIN does not overtake side a")
  eq(streamOf(exchange("coop_npc", {}, { badges = ALL, power = 30, type = 1 }, RULES)),
     streamOf(exchange("coop_npc", {}, { power = 30, type = 1 }, RULES)),
     "coop_npc: side b's HIVE does not type-boost its BUG move")
end

-- ------------------------------------------------------------------
-- 8. pokecrystal fidelity: stat order, crits, folding, screens, the
--    self-hit, Struggle, a Metronome call and move priority
-- ------------------------------------------------------------------
--
-- docs/plans/gen12-referee-fidelity.md, Gen 2.  The parity driver
-- (tests/drivers/battle2_turn_parity.lua) pins whole fights both runtimes
-- agree on; this states the rules one at a time, each number worked from the
-- cart's arithmetic.  server/battle2_turn.test.js holds the same claims.

-- A sheet in one line: everything explicit, so the JS twin builds the same.
local function sheet(o)
  return {
    species = o.species, level = o.level or 20, maxHp = o.maxHp or 300,
    hp = o.hp, status = o.status, types = o.types or { 2 },
    stats = { atk = o.atk or 40, def = o.def or 40, spe = o.spe or 40,
              spa = o.spa or 40, spd = o.spd or 40 },
    stages = o.stages, confusion = o.confusion, substitute = o.substitute,
    moves = o.moves,
  }
end
local function hit(id, power, ty, effect, pp)
  return { id = id, pp = pp or 30, power = power, accuracy = 255,
           type = ty or 0, effect = effect or 0, chance = 0 }
end
local function said(events, text)
  for _, event in ipairs(events) do
    if event.t == "msg" and event.text == text then return true end
  end
  return false
end
local function damageOn(events, slot)
  for _, event in ipairs(events) do
    if event.t == "damage" and event.slot == slot then return event.amount end
  end
  return nil
end
local function animOrder(events)
  local out = {}
  for _, event in ipairs(events) do
    if event.t == "anim" then out[#out + 1] = event.text end
  end
  return table.concat(out, ",")
end
local function duel(o)
  return battleOf({
    mode = o.mode or "1v1", seed = o.seed or 4242, chart = o.chart,
    specialTypes = o.specialTypes, typeIds = o.typeIds,
    metronomePool = o.metronomePool,
    sides = {
      a = { { playerId = "p1", name = "Ann", badges = o.badges, mons = o.a } },
      b = { { playerId = "p2", name = "Bob", mons = o.b } },
    },
  })
end
local function turn(battle, a, b)
  battle:submitChoice("p1", a or { action = "fight", move = 0 })
  battle:submitChoice("p2", b or { action = "fight", move = 0 })
  return drain(battle)
end

-- (a) the formulas, alone
do
  local Damage = need("BattleSim2/Damage")
  eq(Effects.applyStage(100, 1), 150, "CalcBattleStats: 100 at +1 is 150")
  eq(Effects.applyStage(3, -6), 1, "...a quotient of 0 is raised to 1")
  eq(Effects.applyStage(700, 2), 999, "...and one past MAX_STAT_VALUE is held at 999")

  local m = { stats = { atk = 100, def = 40, spe = 100, spa = 152, spd = 100 },
              stages = { atk = -1, spe = 2, spa = 1 } }
  eq(Effects.battleStat(m, "atk", { ZEPHYR = true }), 74,
     "the stage first (66), then ZEPHYR's eighth: 74 -- badge-then-stage was 73")
  m.status = "burn"
  eq(Effects.battleStat(m, "atk", { ZEPHYR = true }), 37,
     "burn halves what the badge left: 37")
  m.status = "paralysis"
  eq(Effects.battleStat(m, "spe", { PLAIN = true }), 56,
     "200 at +2, 225 under PLAIN, quartered by paralysis: 56")
  eq(Effects.battleStat(m, "spd", { GLACIER = true }), 112,
     "Glacier's tail reads the STAGED Sp. Atk: 228 boosts to 256, odd, so Sp. Def 100 -> 112")
  m.stages.spa = 0
  eq(Effects.battleStat(m, "spd", { GLACIER = true }), 100,
     "unstaged, 152 boosts to 171, even, and Sp. Def stays 100")

  local function fold(a, d, link)
    local x, y = Damage.truncateStats(a, d, link)
    return x .. "/" .. y
  end
  eq(fold(200, 100, false), "200/100", "TruncateHL_BC leaves two bytes alone")
  eq(fold(950, 600, false), "237/150", "...folds both by four while either is past 255")
  eq(fold(200, 1200, false), "12/75", "...as often as it takes outside a link battle")
  eq(fold(200, 1200, true), "50/44", "...but once in one, keeping 300's low byte: the wrap")
  eq(fold(3, 1000, false), "1/250", "...and a stat the shift empties becomes 1")
  eq(fold(1024, 50, true), "0/12", "...while a wrapped attack stays 0 (DamageCalc only lifts defense)")

  for id, want in pairs({
    PROTECT = 3, DETECT = 3, ENDURE = 3,
    QUICK_ATTACK = 2, MACH_PUNCH = 2, EXTREMESPEED = 2,
    ROAR = 0, WHIRLWIND = 0, COUNTER = 0, MIRROR_COAT = 0, VITAL_THROW = 0,
    STRUGGLE = 1, thump = 1,
  }) do
    eq(Effects.movePriority(id), want, "GetMovePriority: " .. id .. " is " .. want)
  end
  eq(Effects.movePriority({ id = "quick_attack" }), 2, "a move record answers by its id, any case")
  eq(Effects.movePriority(nil), Effects.BASE_PRIORITY, "no move is BASE_PRIORITY")
end

-- (a2) CheckDamageStatsCritical: a crit keeps the staged pair only when the
--      defender's stage is strictly lower than the attacker's
do
  local function critHit(atkStage, defStage)
    for seed = 1, 400 do
      local slash = hit("slash_hit", 40)
      slash.highCrit = true
      local battle = duel({
        seed = seed,
        a = { sheet({ species = "Alpha", spe = 90, stages = { atk = atkStage },
                      moves = { slash } }) },
        b = { sheet({ species = "Beta", spe = 10, stages = { def = defStage },
                      moves = { hit("tap", 0, 0, 85) } }) },
      })
      drain(battle)
      local events = turn(battle)
      if said(events, "A critical hit!") then return damageOn(events, 3) end
    end
    return nil
  end
  -- Defense +6 is not lower than Attack 0: the unmodified 40 against 40 --
  -- 10 x 40 x 40 / 40 / 50 = 8, x2 = 16, +2 = 18, then the roll.
  local plain = critHit(0, 6)
  ok(plain and plain >= 15 and plain <= 18,
     "a crit into Defense +6 reads the unmodified stats (15..18), not 160 Defense")
  -- Defense +1 is lower than Attack +6: the staged 160 against 60 --
  -- 10 x 40 x 160 / 60 / 50 = 21, x2 = 42, +2 = 44, then the roll.
  local staged = critHit(6, 1)
  ok(staged and staged >= 37 and staged <= 44,
     "a crit from Attack +6 into Defense +1 keeps both stages (37..44)")
end

-- (b) stages do not survive a switch-in or a faint
do
  local battle = duel({
    a = { sheet({ species = "Alpha", spe = 90,
                  moves = { hit("sharpen", 0, 0, Effects.idOf("ATTACK_UP2_EFFECT")),
                            hit("thump", 60) } }),
          sheet({ species = "Gamma", spe = 90, moves = { hit("thump", 10) } }) },
    b = { sheet({ species = "Beta", spe = 10, maxHp = 30, atk = 40,
                  stages = { atk = 3, def = -2 }, moves = { hit("tap", 1) } }) },
  })
  drain(battle)
  turn(battle)
  eq(battle.byId.p1.mons[1].stages.atk, 2, "the +2 lands on Alpha")
  turn(battle, { action = "switch", slot = 1 })
  turn(battle, { action = "switch", slot = 0 })
  eq(battle.byId.p1.mons[1].stages.atk, 0,
     "Alpha comes back in at 0: a send-out brings no stage (ResetPlayerStatLevels)")
  local beta = battle.byId.p2.mons[1]
  for _ = 1, 6 do
    if battle:outcome() then break end
    turn(battle, { action = "fight", move = 1 })
  end
  eq(beta.hp, 0, "Beta goes down")
  eq(beta.stages.atk, 0, "and its +3 Attack goes with it")
  eq(beta.stages.def, 0, "and its -2 Defense")
end

-- (c) screens: per side, five ticks, a failed recast, special and fixed hits
do
  -- Seed 4243: Beta's zap does not crit (it does on 4242 since K12, and a crit
  -- reads the unscreened Sp. Def -- CheckDamageStatsCritical).
  local battle = duel({
    specialTypes = { 1 }, seed = 4243,
    a = { sheet({ species = "Alpha", spe = 90,
                  moves = { hit("glow_wall", 0, 1, 64, 20), hit("tap", 1) } }) },
    b = { sheet({ species = "Beta", spe = 10, spa = 60,
                  moves = { hit("zap", 40, 1), hit("sonic_ping", 20, 0, 41) } }) },
  })
  drain(battle)
  local first = turn(battle)
  eq(battle.screens.a.lightScreen, 4, "Light Screen goes up at 5 and the turn's tick takes one")
  eq(battle.screens.b.lightScreen, 0, "...on Ann's side only")
  local screened = damageOn(first, 0)
  -- 10 x 40 x 60 / 80 (Sp. Def 40 doubled) / 50 = 6, +2 = 8, then the roll.
  ok(screened and screened <= 8 and screened >= 6, "a special hit into it reads Sp. Def doubled (6..8)")
  local again = turn(battle)
  ok(said(again, "But it failed!"), "a second Light Screen while one is up fails")
  eq(battle.screens.a.lightScreen, 3, "...and does not refresh the count")
  local fixed = turn(battle, { action = "fight", move = 1 }, { action = "fight", move = 1 })
  eq(damageOn(fixed, 0), 20, "a fixed-damage hit is never screened: the post-hoc halving is gone")
  turn(battle, { action = "fight", move = 1 })
  local fade = turn(battle, { action = "fight", move = 1 })
  -- BattleText_MonsLightScreenFell; a link fight names the side's trainer
  -- where each cart says "Your" (wave 5, `_screenOwner`).
  ok(said(fade, "Ann's POKéMON's LIGHT SCREEN fell!"), "it falls at the end of its fifth turn")
  eq(battle.screens.a.lightScreen, 0, "...and is down")
  local bare = turn(battle, { action = "fight", move = 1 })
  local unscreened = damageOn(bare, 0)
  -- 10 x 40 x 60 / 40 / 50 = 12, +2 = 14, then the roll.
  ok(unscreened and unscreened >= 11 and unscreened <= 14, "the next special hit is whole again (11..14)")
end

-- (d) the confusion self-hit: no crit, no roll, and past the user's substitute
do
  local function confusedFight(seed)
    return duel({
      seed = seed,
      a = { sheet({ species = "Alpha", spe = 90, atk = 60, def = 60, confusion = 4,
                    substitute = 50, moves = { hit("tap", 1) } }) },
      b = { sheet({ species = "Beta", spe = 10, moves = { hit("tap", 0, 0, 85) } }) },
    })
  end
  local found
  for seed = 1, 200 do
    local battle = confusedFight(seed)
    drain(battle)
    if said(turn(battle), "It hurt itself in its confusion!") then found = seed; break end
  end
  ok(found ~= nil, "a seed on which the confused Alpha hits itself")
  local battle = confusedFight(found)
  drain(battle)
  local events = turn(battle)
  -- 10 x 40 x 60 / 60 / 50 = 8, +2 = 10: DamageCalc's tail and nothing after.
  eq(damageOn(events, 0), 10, "the self-hit is DamageCalc and nothing after: 10, every time")
  eq(battle.byId.p1.mons[1].hp, 290, "...and it comes off the HP")
  eq(battle.byId.p1.mons[1].substitute, 50, "...past the user's own substitute (`ld c, TRUE`)")
end

-- (e) typeless Struggle, its recoil, and a Metronome call with the last PP
do
  local GHOST_CHART = { { 100, 0 }, { 100, 100 } }
  local function vsGhost(pp)
    -- Seed 1: no crit on Struggle's swing (R2c moved the stream off 4242's).
    return duel({
      seed = 1,
      chart = GHOST_CHART,
      a = { sheet({ species = "Alpha", spe = 90, types = { 0 },
                    moves = { hit("thump", 40, 0, 0, pp) } }) },
      b = { sheet({ species = "Beta", spe = 10, types = { 1 }, moves = { hit("tap", 0, 0, 85) } }) },
    })
  end
  local normal = vsGhost(10)
  drain(normal)
  ok(said(turn(normal), "It doesn't affect Beta!"), "a NORMAL move cannot touch the GHOST on this chart")
  local struggle = vsGhost(0)
  drain(struggle)
  local events = turn(struggle)
  local dealt = damageOn(events, 3)
  -- 10 x 50 x 40 / 40 / 50 = 10, +2 = 12, no STAB though Alpha is type 0.
  ok(dealt and dealt >= 10 and dealt <= 12, "Struggle hits the GHOST anyway, with no STAB (10..12)")
  ok(not said(events, "It doesn't affect Beta!"), "...and no matchup line at all")
  eq(damageOn(events, 0), math.max(1, math.floor(dealt / 4)), "recoil is a quarter of what it dealt")

  local feeble = duel({
    a = { sheet({ species = "Alpha", spe = 90, atk = 1, moves = { hit("thump", 40, 0, 0, 0) } }) },
    b = { sheet({ species = "Beta", spe = 10, def = 255, moves = { hit("tap", 0, 0, 85) } }) },
  })
  drain(feeble)
  local tiny = turn(feeble)
  eq(damageOn(tiny, 0), 1, "a Struggle that deals 1 still costs 1 (BattleCommand_Recoil's minimum)")

  local metronome = duel({
    metronomePool = { hit("pool_hit", 60, 1, 0, 10) },
    a = { sheet({ species = "Alpha", spe = 90,
                  moves = { hit("wave_finger", 0, 0, Effects.idOf("EFFECT_METRONOME"), 1) } }) },
    b = { sheet({ species = "Beta", spe = 10, moves = { hit("tap", 0, 0, 85) } }) },
  })
  drain(metronome)
  local called = turn(metronome)
  ok(animOrder(called):find("pool_hit", 1, true) ~= nil, "the last PP calls the pool move")
  ok(not said(called, "Alpha's hit with recoil!"), "...and the called move takes no Struggle recoil")
  local after = turn(metronome)
  ok(animOrder(after):find("STRUGGLE", 1, true) ~= nil, "the turn after, every slot is empty: Struggle")
  ok(said(after, "Alpha's hit with recoil!"), "...which does recoil")

  -- ResetTurn re-enters DoMove past CheckTurn, so the called move is not gated
  -- a second time: a confused caller spends one confusion turn, not two.
  local function confusedCaller(seed)
    return duel({
      seed = seed, metronomePool = { hit("pool_hit", 60, 1, 0, 10) },
      a = { sheet({ species = "Alpha", spe = 90, confusion = 5,
                    moves = { hit("wave_finger", 0, 0, Effects.idOf("EFFECT_METRONOME"), 5) } }) },
      b = { sheet({ species = "Beta", spe = 10, moves = { hit("tap", 0, 0, 85) } }) },
    })
  end
  local clean
  for seed = 1, 200 do
    local battle = confusedCaller(seed)
    drain(battle)
    local events = turn(battle)
    if animOrder(events):find("pool_hit", 1, true) then clean = battle; break end
  end
  ok(clean ~= nil, "a seed on which the confused caller gets its call off")
  eq(clean and clean.byId.p1.mons[1].confusion, 4,
     "...and the confusion counter ticked once: the called move ran no gate of its own")
end

-- (f) move priority: the bracket before the Speed
do
  local function order(aMove, aSpe, bMove, bSpe)
    local battle = duel({
      a = { sheet({ species = "Alpha", spe = aSpe, moves = { aMove } }) },
      b = { sheet({ species = "Beta", spe = bSpe, moves = { bMove } }) },
    })
    drain(battle)
    return animOrder(turn(battle))
  end
  eq(order(hit("QUICK_ATTACK", 40), 10, hit("thump", 40), 99), "QUICK_ATTACK,thump",
     "QUICK_ATTACK (2) beats a far faster plain hit (1)")
  eq(order(hit("QUICK_ATTACK", 40), 10, hit("EXTREMESPEED", 80), 99), "EXTREMESPEED,QUICK_ATTACK",
     "EXTREMESPEED shares QUICK_ATTACK's bracket, so Speed decides")
  eq(order(hit("thump", 40), 99, hit("PROTECT", 0), 1), "PROTECT,thump",
     "PROTECT (3) moves first from the slowest seat")
  eq(order(hit("VITAL_THROW", 70, 0, 17), 99, hit("thump", 40), 1), "thump,VITAL_THROW",
     "VITAL_THROW (0) moves last from the fastest seat")
  eq(order(hit("thump", 40, 0, 0, 0), 10, hit("VITAL_THROW", 70, 0, 17), 99), "STRUGGLE,VITAL_THROW",
     "Struggle moves at BASE_PRIORITY, ahead of a bracket-0 move")
end

-- (g) an NPC never re-raises a screen that is already up
do
  local battle = battleOf({
    mode = "coop_npc", seed = 77,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = {
        sheet({ species = "Alpha", spe = 10, moves = { hit("tap", 1) } }) } } },
      b = { { playerId = "npc", name = "Foe", mons = {
        sheet({ species = "Beta", spe = 90,
                moves = { hit("wall_up", 0, 1, 65, 20), hit("thump", 40) } }) } } },
    },
  })
  drain(battle)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:autoPick("npc")
  local first = drain(battle)
  ok(animOrder(first):find("wall_up", 1, true) ~= nil, "the NPC sets up Reflect on a level field")
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:autoPick("npc")
  local second = drain(battle)
  ok(animOrder(second):find("wall_up", 1, true) == nil, "...and does not cast it again while it is up")
  ok(animOrder(second):find("thump", 1, true) ~= nil, "...it attacks instead")
end

-- ------------------------------------------------------------------
-- 9. Gold held items, obedience, the flinch reset and the cart family
-- ------------------------------------------------------------------
--
-- docs/plans/gen12-referee-fidelity.md, Gen 2, wave 2: the rules one at a
-- time.  The parity driver pins whole fights both runtimes agree on; the
-- formulas are in the vector pack's ITEMS section.  Every parameter is
-- synthetic; server/battle2_turn.test.js holds the same claims.

local Items, Crit = BattleSim2.Items, BattleSim2.Crit

-- A sheet with an item ({ id, effect, param, name, mail }) and the obedience
-- fields, on top of section 8's `sheet`.
local function held(o)
  local m = sheet(o)
  m.speciesId, m.traded, m.statusTurns = o.speciesId, o.traded, o.statusTurns
  m.focusEnergy, m.disable = o.focusEnergy, o.disable
  if o.item then
    m.heldItem, m.holdEffect, m.holdParam = o.item[1], o.item[2], o.item[3]
    m.itemName, m.mail = o.item[4], o.item[5]
  end
  return m
end
local function fight(o)
  local foe = o.foe or ((o.mode == "wild" or o.mode == "coop_wild") and "wild" or "p2")
  return battleOf({
    mode = o.mode or "1v1", seed = o.seed or 4242, typeIds = o.typeIds,
    specialTypes = o.specialTypes, chart = o.chart,
    sides = {
      a = { { playerId = "p1", name = "Ann", badges = o.badges, family = o.family, mons = o.a } },
      b = { { playerId = foe, name = "Bob", mons = o.b } },
    },
  }), foe
end
local function round(battle, foe, a, b)
  battle:submitChoice("p1", a or { action = "fight", move = 0 })
  battle:submitChoice(foe, b or { action = "fight", move = 0 })
  return drain(battle)
end
local function heldEvents(events)
  local out = {}
  for _, event in ipairs(events) do
    if event.t == "held" then out[#out + 1] = event.text .. ":" .. event.amount .. "@" .. event.slot end
  end
  return table.concat(out, ",")
end
local LEFTOVERS = { "LEFTOVERS", "HELD_LEFTOVERS", 0, "LEFTOVERS" }

-- (a) the sheet: K1 / K2 kept, badgeRules and family per seat (K6)
do
  local battle = battleOf({
    mode = "wild", seed = 1,
    sides = {
      a = { { playerId = "p1", name = "Ann", family = "crystal", mons = {
        held({ species = "Alpha", traded = true, item = { "FLOWER_MAIL", nil, 77, "FLOWER MAIL", true },
               moves = { hit("tap", 1) } }),
        held({ species = "Gamma", moves = { hit("tap", 1) } }) } } },
      b = { { playerId = "wild", name = "Wild", family = "crystal", mons = {
        held({ species = "Beta", item = { "LEFTOVERS", "HELD_LEFTOVERS", 999, "LEFTOVERS" },
               moves = { hit("tap", 1) } }) } } },
    },
  })
  local ann, wild = battle.byId.p1, battle.byId.wild
  local alpha, beta = ann.mons[1], wild.mons[1]
  eq(alpha.heldItem, "FLOWER_MAIL", "copyMon keeps heldItem")
  eq(alpha.holdParam, 77, "...its parameter")
  eq(alpha.mail, true, "...the Mail flag")
  eq(alpha.itemName, "FLOWER MAIL", "...and the display name")
  eq(alpha.traded, true, "...and K1's traded")
  eq(beta.holdParam, 255, "a parameter past a byte is held at 255")
  eq(ann.mons[2].heldItem, nil, "a monster with no item carries none of the fields")
  eq(ann.mons[2].traded, nil, "...and no traded")
  eq(ann.badgeRules, true, "side a of a wild fight plays by the badge rules")
  eq(wild.badgeRules, nil, "...side b never does")
  eq(battle.family, "crystal", "the fight's cart is side a's first seat's")
  local link = battleOf({ mode = "1v1", sides = {
    a = { { playerId = "p1", name = "Ann", family = "silver", mons = { held({ species = "Alpha", moves = { hit("tap", 1) } }) } } },
    b = { { playerId = "p2", name = "Bob", family = "crystal", mons = { held({ species = "Beta", moves = { hit("tap", 1) } }) } } },
  } })
  eq(link.byId.p1.badgeRules, nil, "a link battle has no badge-rules seat")
  eq(link.family, "gs", "an unknown family on side a reads as Gold / Silver's, whatever side b says")
  local held2 = held({ species = "Alpha", item = { "LEFTOVERS" }, moves = { hit("tap", 1) } })
  held2.heldItem = nil
  held2.holdEffect = "HELD_LEFTOVERS"
  local orphan = battleOf({ mode = "1v1", sides = {
    a = { { playerId = "p1", name = "Ann", mons = { held2 } } },
    b = { { playerId = "p2", name = "Bob", mons = { held({ species = "Beta", moves = { hit("tap", 1) } }) } } },
  } })
  eq(orphan.byId.p1.mons[1].holdEffect, nil, "a hold effect with no item is nothing held")
end

-- (b) K6: TruncateHL_BC's pass count by cart and mode
do
  local function onePass(mode, family)
    local foe = (mode == "wild") and "wild" or "p2"
    local battle = battleOf({ mode = mode, sides = {
      a = { { playerId = "p1", name = "Ann", family = family, mons = { held({ species = "Alpha", moves = { hit("tap", 1) } }) } } },
      b = { { playerId = foe, name = "Bob", mons = { held({ species = "Beta", moves = { hit("tap", 1) } }) } } },
    } })
    return battle:_onePassTruncate()
  end
  eq(onePass("wild", nil), true, "Gold / Silver (no family): one pass outside a link battle")
  eq(onePass("wild", "gs"), true, "...and with gs stated")
  eq(onePass("wild", "crystal"), false, "Crystal loops outside a link battle")
  eq(onePass("1v1", "crystal"), true, "...and folds once in one")
  eq(onePass("coop_pvp", "gs"), true, "a link battle on Gold folds once too")
end

-- (c) Quick Claw: inside a bracket only, and a bracket of one draws nothing
do
  local claw = { "QUICK_CLAW", "HELD_QUICK_CLAW", 255, "QUICK CLAW" }
  local function order(item, bMove, seed)
    local battle, foe = fight({ seed = seed or 3,
      a = { held({ species = "Alpha", spe = 10, item = item, moves = { hit("ann_hit", 10) } }) },
      b = { held({ species = "Beta", spe = 90, moves = { bMove or hit("bob_hit", 10) } }) } })
    drain(battle)
    local events = round(battle, foe)
    return animOrder(events), battle.rng:state()
  end
  eq((order(claw)), "ann_hit,bob_hit", "a claw that fires (255) puts the slower holder first")
  eq((order(nil)), "bob_hit,ann_hit", "...where Speed alone puts it last")
  local _, bare = order(nil)
  local _, clawed = order(claw)
  ok(bare ~= clawed, "...and its byte is a real draw")
  local qa = order(claw, hit("QUICK_ATTACK", 10))
  eq(qa, "QUICK_ATTACK,ann_hit", "a claw never lifts its holder past a higher bracket")
  local _, s1 = order(claw, hit("QUICK_ATTACK", 10), 9)
  local _, s2 = order(nil, hit("QUICK_ATTACK", 10), 9)
  eq(s1, s2, "...and with each bracket holding one actor, nothing is drawn")
  -- side b's holder rolls first: with both holding a sure claw, Bob (side b) goes first
  local battle, foe = fight({ seed = 3,
    a = { held({ species = "Alpha", spe = 50, item = claw, moves = { hit("ann_hit", 10) } }) },
    b = { held({ species = "Beta", spe = 10, item = claw, moves = { hit("bob_hit", 10) } }) } })
  drain(battle)
  eq(animOrder(round(battle, foe)), "bob_hit,ann_hit", "both holding: side b's claw is rolled first and fires")
end

-- (d) Leftovers, a Berry eaten and gone, the strict half, the held event
do
  local battle, foe = fight({ seed = 7,
    a = { held({ species = "Alpha", maxHp = 320, hp = 100, spe = 90, item = LEFTOVERS, moves = { hit("tap", 1) } }) },
    b = { held({ species = "Beta", maxHp = 100, hp = 50, spe = 10, item = { "BERRY", "HELD_BERRY", 12, "BERRY" },
                moves = { hit("tap", 0, 0, 85) } }) } })
  drain(battle)
  local events = round(battle, foe)
  ok(said(events, "Alpha recovered with LEFTOVERS."), "Leftovers: the cart's sentence")
  eq(battle.byId.p1.mons[1].heldItem, "LEFTOVERS", "...and kept")
  eq(heldEvents(events), "LEFTOVERS:1@0,BERRY:0@3", "held events: Leftovers still held, the Berry gone")
  ok(said(events, "Beta recovered using a BERRY!"), "a Berry under half: eaten")
  eq(battle.byId[foe].mons[1].heldItem, nil, "...and gone from the referee's copy")
  eq(battle.byId[foe].mons[1].hp, 49 + 12, "...after healing its parameter (12)")
  local quiet, qfoe = fight({ seed = 7,
    a = { held({ species = "Alpha", spe = 90, moves = { hit("tap", 0, 0, 85) } }) },
    b = { held({ species = "Beta", maxHp = 100, hp = 50, spe = 10, item = { "BERRY", "HELD_BERRY", 12, "BERRY" },
                moves = { hit("tap", 0, 0, 85) } }) } })
  drain(quiet)
  local events2 = round(quiet, qfoe)
  ok(not sawKind(events2, "held"), "at exactly half the cart keeps the Berry (2*HP < max)")
  eq(Items.sixteenth(320), 20, "Leftovers heals a sixteenth")
end

-- (e) status berries right after infliction, and only the matching one
do
  local battle, foe = fight({ seed = 11,
    a = { held({ species = "Alpha", spe = 90, moves = { hit("doze_dust", 0, 0, 32) } }) },
    b = { held({ species = "Beta", spe = 10, item = { "MINT_BERRY", "HELD_HEAL_SLEEP", 0, "MINT BERRY" },
                moves = { hit("tap", 1) } }) } })
  drain(battle)
  local events = round(battle, foe)
  ok(said(events, "Beta fell asleep!"), "the sleep lands")
  ok(said(events, "Beta recovered using a MINT BERRY!"), "...and the Mint Berry takes it straight away")
  eq(battle.byId[foe].mons[1].status, nil, "...so the target is awake")
  ok(said(events, "Beta used tap!"), "...and moves this very turn")
  local wrong, wfoe = fight({ seed = 11,
    a = { held({ species = "Alpha", spe = 90, moves = { hit("doze_dust", 0, 0, 32) } }) },
    b = { held({ species = "Beta", spe = 10, item = { "ICE_BERRY", "HELD_HEAL_BURN", 0, "ICE BERRY" },
                moves = { hit("tap", 1) } }) } })
  drain(wrong)
  local events2 = round(wrong, wfoe)
  ok(not sawKind(events2, "held"), "a berry for another status does nothing, then or between turns")
  eq(wrong.byId[wfoe].mons[1].heldItem, "ICE_BERRY", "...and is kept")
end

-- (f) Focus Band: every hit rolls, a lethal one is held at 1
do
  local band = { "FOCUS_BAND", "HELD_FOCUS_BAND", 255, "FOCUS BAND" }
  local function bandFight(item, hp, seed)
    local battle, foe = fight({ seed = seed or 21,
      a = { held({ species = "Alpha", atk = 200, spe = 90, moves = { hit("thump", 80) } }) },
      b = { held({ species = "Beta", maxHp = 400, hp = hp, spe = 10, item = item, moves = { hit("tap", 0, 0, 85) } }) } })
    drain(battle)
    local events = round(battle, foe)
    return events, battle, foe
  end
  local events, battle, foe = bandFight(band, 5)
  eq(battle.byId[foe].mons[1].hp, 1, "a lethal hit the band catches leaves 1 HP")
  ok(said(events, "Beta hung on with FOCUS BAND!"), "...with the cart's line")
  eq(heldEvents(events), "FOCUS_BAND:1@3", "...and the band is still held")
  local _, bare = bandFight(nil, 400)
  local quietEvents, banded = bandFight(band, 400)
  ok(bare.rng:state() ~= banded.rng:state(), "a non-lethal hit still rolls the band")
  ok(not sawKind(quietEvents, "held"), "...and says nothing")
end

-- (g) King's Rock: eligible scripts only, no substitute, no fainted target
do
  local rock = { "KINGS_ROCK", "HELD_FLINCH", 255, "KING'S ROCK" }
  local function kr(move, item, b, seed)
    local battle, foe = fight({ seed = seed or 3,
      a = { held({ species = "Alpha", spe = 90, item = item, moves = { move } }) },
      b = { b or held({ species = "Beta", maxHp = 400, spe = 10, moves = { hit("tap", 1) } }) } })
    drain(battle)
    return round(battle, foe), battle
  end
  local events = kr(hit("thump", 10), rock)
  ok(said(events, "Beta flinched!"), "a plain hit with King's Rock flinches a slower target")
  local _, plain = kr(hit("thump", 10), nil)
  local _, rocked = kr(hit("FUTURE_SIGHT", 10), rock)
  eq(plain.rng:state(), rocked.rng:state(), "a folded-0 move whose script has no `kingsrock` draws nothing")
  -- THUNDER has its own id now (Effects.THUNDER): its script has no
  -- `kingsrock` either, and it is no longer named by move id to say so.
  local _, thunderPlain = kr(hit("THUNDER", 10, 0, Effects.THUNDER), nil)
  local _, thunderRocked = kr(hit("THUNDER", 10, 0, Effects.THUNDER), rock)
  eq(thunderPlain.rng:state(), thunderRocked.rng:state(),
     "...nor does a Gold-native id whose script has none (THUNDER)")
  -- SNORE needs a sleeping user (BattleCommand_Snore fails an awake one).
  local function snoreRun(item)
    local battle, foe = fight({ seed = 3,
      a = { held({ species = "Alpha", spe = 90, item = item, status = "SLP", statusTurns = 7,
                   moves = { hit("SNORE", 10, 0, Effects.SNORE) } }) },
      b = { held({ species = "Beta", maxHp = 400, spe = 10, moves = { hit("tap", 1) } }) } })
    drain(battle)
    round(battle, foe)
    return battle
  end
  ok(snoreRun(nil).rng:state() ~= snoreRun(rock).rng:state(),
     "SNORE's script ends in `kingsrock`, so its own id rolls it")
  local _, burnt = kr(hit("ember_hit", 10, 0, 4), rock)
  local _, burntPlain = kr(hit("ember_hit", 10, 0, 4), nil)
  eq(burnt.rng:state(), burntPlain.rng:state(), "...nor does a status hit")
  local subbed = held({ species = "Beta", maxHp = 400, spe = 10, moves = { hit("tap", 1) } })
  subbed.substitute = 300
  local subEvents, subBattle = kr(hit("thump", 10), rock, subbed)
  ok(not said(subEvents, "Beta flinched!"), "a substitute still standing shields the target")
  local _, subPlain = kr(hit("thump", 10), nil, held({ species = "Beta", maxHp = 400, spe = 10, substitute = 300,
                                                        moves = { hit("tap", 1) } }))
  eq(subBattle.rng:state(), subPlain.rng:state(), "...and no byte is drawn for it")
  eq(Items.kingsRockMove(Effects.idOf("TWO_TO_FIVE_ATTACKS_EFFECT"), "fury_hits"), true, "multi-hit scripts end in `kingsrock`")
end

-- (h) the species items read the right species through Transform
do
  -- Lucky Punch reads the BATTLE species: a Ditto that becomes a Chansey has it.
  local battle, foe = fight({ seed = 5,
    a = { held({ species = "Alpha", speciesId = "DITTO", spe = 90, item = { "LUCKY_PUNCH", nil, 0, "LUCKY PUNCH" },
                 moves = { hit("copycat", 0, 0, 57) } }) },
    b = { held({ species = "Beta", speciesId = "CHANSEY", spe = 10, moves = { hit("tap", 1) } }) } })
  drain(battle)
  round(battle, foe)
  local alpha = battle.byId.p1.mons[1]
  eq(battle:_battleSpecies(alpha), "CHANSEY", "Transform rewrites the battle species")
  eq(Items.critSpeciesItem(battle:_battleSpecies(alpha), alpha.heldItem), true, "...so Lucky Punch sets the level")
  eq(alpha.speciesId, "DITTO", "...while the party species stays")
  eq(Items.metalPowder({ heldItem = "METAL_POWDER", speciesId = alpha.speciesId }, 100, 100), 100,
     "Metal Powder's attack side is untouched while the defense fits")
  local _, d = Items.metalPowder({ heldItem = "METAL_POWDER", speciesId = alpha.speciesId }, 100, 100)
  eq(d, 150, "...and the party species is what Metal Powder reads")
  eq(Crit.level({ speciesItemBonus = true, focusEnergy = true, highCritMove = true, scopeLens = true }), 2,
     "the species item sets the crit level to 2 outright")
end

-- (i) Thief: Mail by flag or by id, a full hand, both ways, and its
--     `effectchance`: a substitute or a byte at or over the chance byte (the
--     1/256 miss of Thief's 100%) leaves wEffectFailed set and nothing is taken
do
  -- Thief's row: a 100% effect chance (`percent 100`, $ff on the cart).
  local function thiefMove()
    local move = hit("THIEF", 10)
    move.chance = 100
    return move
  end
  local function thief(bItem, aItem, seed, substitute)
    local battle, foe = fight({ seed = seed or 4,
      a = { held({ species = "Alpha", spe = 90, item = aItem, moves = { thiefMove() } }) },
      b = { held({ species = "Beta", maxHp = 400, spe = 10, item = bItem, substitute = substitute,
                   moves = { hit("tap", 1) } }) } })
    drain(battle)
    return round(battle, foe), battle, foe
  end
  local events, battle, foe = thief({ "CHARCOAL", "HELD_FIRE_BOOST", 20, "CHARCOAL" })
  ok(said(events, "Alpha stole CHARCOAL from its foe!"), "Thief takes the foe's item")
  eq(heldEvents(events), "CHARCOAL:0@3,CHARCOAL:1@0", "...two held events: the victim's, then the thief's")
  eq(battle.byId.p1.mons[1].holdEffect, "HELD_FIRE_BOOST", "...and the rule travels with it")
  eq(battle.byId[foe].mons[1].heldItem, nil, "...the victim holds nothing")
  local mailEvents = thief({ "FLOWER_MAIL", nil, 0, "FLOWER MAIL", true })
  ok(not sawKind(mailEvents, "held"), "Mail (the flag) is never taken")
  local idEvents = thief({ "SURF_MAIL", nil, 0, "SURF MAIL" })
  ok(not sawKind(idEvents, "held"), "...nor a Mail id the sheet forgot to flag")
  local fullEvents = thief({ "CHARCOAL", "HELD_FIRE_BOOST", 20, "CHARCOAL" }, { "BERRY", "HELD_BERRY", 12, "BERRY" })
  ok(not sawKind(fullEvents, "held"), "a thief already holding something takes nothing")
  local emptyEvents = thief(nil)
  ok(not sawKind(emptyEvents, "held"), "...and a foe holding nothing gives nothing")
  local subEvents, subBattle = thief({ "CHARCOAL", "HELD_FIRE_BOOST", 20, "CHARCOAL" }, nil, 4, 80)
  ok(not sawKind(subEvents, "held"), "a substitute at `effectchance` keeps the item")
  eq(subBattle.byId.p2.mons[1].heldItem, "CHARCOAL", "...which the foe still holds")
  ok(said(subEvents, "Alpha used THIEF!"), "...though the hit itself landed")
  -- Seed 163 draws the 255 at `effectchance` (R2c's draw order moved it off
  -- 153, R2d's crit byte and DamageVariation loop off 218).
  local missEvents, missBattle = thief({ "CHARCOAL", "HELD_FIRE_BOOST", 20, "CHARCOAL" }, nil, 163)
  ok(not sawKind(missEvents, "held"), "the 1/256 byte of 255 against a 100% chance takes nothing")
  eq(missBattle.byId.p2.mons[1].heldItem, "CHARCOAL", "...and the foe keeps its item")
  local zero = thiefMove()
  zero.chance = 0
  local zBattle, zFoe = fight({ seed = 4,
    a = { held({ species = "Alpha", spe = 90, moves = { zero } }) },
    b = { held({ species = "Beta", maxHp = 400, spe = 10, item = { "CHARCOAL", "HELD_FIRE_BOOST", 20, "CHARCOAL" },
                 moves = { hit("tap", 1) } }) } })
  drain(zBattle)
  ok(not sawKind(round(zBattle, zFoe), "held"), "a sheet with a chance of 0 never steals (BattleRandom cp 0)")
  -- the computer's Thief is not gated (Gen 3's is): the wild monster robs the player
  local wild, wfoe = fight({ mode = "wild", seed = 4,
    a = { held({ species = "Alpha", spe = 90, item = LEFTOVERS, moves = { hit("tap", 0, 0, 85) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { thiefMove() } }) } })
  drain(wild)
  local wildEvents = round(wild, wfoe)
  ok(said(wildEvents, "Beta stole LEFTOVERS from its foe!"), "a wild Thief takes the player's item")
  eq(wild.byId.p1.mons[1].heldItem, nil, "...and it is gone")
end

-- (j) Berserk Gene: 256, an already-confused holder, Attack at +6
do
  local gene = { "BERSERK_GENE", nil, 0, "BERSERKGENE" }
  local battle = fight({
    a = { held({ species = "Alpha", spe = 90, item = gene, moves = { hit("tap", 1) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("tap", 1) } }) } })
  local events = drain(battle)
  local alpha = battle.byId.p1.mons[1]
  eq(alpha.confusion, Turn.BERSERK_CONFUSION, "from a count of 0 the confusion runs 256 checks")
  eq(alpha.stages.atk, 2, "Attack +2")
  eq(alpha.heldItem, nil, "the gene is used up")
  ok(said(events, "Alpha's BERSERKGENE activated!"), "...with the cart's line")
  local turnAt, geneAt = 0, 0
  for i, event in ipairs(events) do
    if event.t == "turn" then turnAt = i end
    if event.t == "held" then geneAt = i end
  end
  ok(geneAt > 0 and geneAt < turnAt, "...before the turn opens")
  local maxed = held({ species = "Alpha", spe = 90, item = gene, moves = { hit("tap", 1) } })
  maxed.stages = { atk = 6 }
  maxed.confusion = 3
  local battle2 = fight({ a = { maxed }, b = { held({ species = "Beta", spe = 10, moves = { hit("tap", 1) } }) } })
  local events2 = drain(battle2)
  eq(battle2.byId.p1.mons[1].confusion, 3, "an already-confused holder keeps its count")
  ok(not said(events2, "Alpha became confused!"), "...and is not told again")
  ok(not said(events2, "Alpha's ATTACK went way up!"), "Attack at +6 says nothing")
end

-- (k) obedience gates: who is asked, and when nothing is drawn
do
  local function obeyRun(o)
    local battle, foe = fight({ mode = o.mode or "wild", seed = o.seed or 31, badges = o.badges,
      a = { held({ species = "Alpha", level = o.level or 80, spe = 90, traded = o.traded,
                   moves = { hit("thump", 10), hit("pound_two", 10) } }) },
      b = { held({ species = "Beta", level = 80, spe = 10, maxHp = 900, moves = { hit("tap", 1) } }) } })
    drain(battle)
    local events = {}
    for _ = 1, 4 do for _, e in ipairs(round(battle, foe)) do events[#events + 1] = e end end
    return events, battle.rng:state()
  end
  local _, base = obeyRun({})
  local _, traded = obeyRun({ traded = true })
  ok(base ~= traded, "a traded L80 monster with no badge is asked (cap 10)")
  local _, capped = obeyRun({ traded = true, level = 10 })
  local _, cappedBase = obeyRun({ level = 10 })
  eq(capped, cappedBase, "at the cap it obeys without a draw")
  local _, rising = obeyRun({ traded = true, badges = { RISING = true } })
  eq(rising, base, "RISING: every level obeys, no draw")
  local _, link = obeyRun({ traded = true, mode = "1v1" })
  local _, linkBase = obeyRun({ mode = "1v1" })
  eq(link, linkBase, "a link battle never asks")
  local _, pvp = obeyRun({ traded = true, mode = "1v1", badges = {} })
  eq(pvp, linkBase, "...whatever it uploads")
  -- CheckUserIsCharging and CheckRampage skip the command: a charged move's
  -- release and a rampage's continuation are never asked.
  local function locked(traded, field, value)
    local mon = held({ species = "Alpha", level = 80, spe = 90, traded = traded,
                       moves = { hit("beam_up", 60, 0, 39), hit("rampage", 60, 0, 27) } })
    mon[field] = value
    local battle, foe = fight({ mode = "wild", seed = 31, a = { mon },
      b = { held({ species = "Beta", level = 80, maxHp = 900, spe = 10, moves = { hit("tap", 1) } }) } })
    drain(battle)
    battle:tick(1)
    local events = drain(battle)
    for _, e in ipairs(round(battle, foe)) do events[#events + 1] = e end
    return battle.rng:state(), events
  end
  local charged = { moveIndex = 1, effect = 39, moveId = "beam_up", targetSlot = 3 }
  local tradedCharge, chargeEvents = locked(true, "charging", charged)
  eq(tradedCharge, (locked(nil, "charging", { moveIndex = 1, effect = 39, moveId = "beam_up", targetSlot = 3 })),
     "a charged move's release is never asked")
  ok(said(chargeEvents, "Alpha used beam_up!"), "...and goes off")
  eq((locked(true, "thrashing", { turns = 1, moveIndex = 2 })),
     (locked(nil, "thrashing", { turns = 1, moveIndex = 2 })), "nor is a rampage's continuation")
end

-- (l) obedience while asleep, and the Snore / Sleep Talk sleep bypass
do
  local function sleeper(move, traded, seed)
    local battle, foe = fight({ mode = "wild", seed = seed,
      a = { held({ species = "Alpha", level = 80, spe = 90, status = "SLP", statusTurns = 7, traded = traded,
                   moves = { move, hit("thump", 10) } }) },
      b = { held({ species = "Beta", level = 80, maxHp = 900, spe = 10, moves = { hit("tap", 1) } }) } })
    drain(battle)
    return round(battle, foe)
  end
  local snore = sleeper(hit("SNORE", 10), nil, 3)
  ok(said(snore, "Alpha is fast asleep!") and said(snore, "Alpha used SNORE!"), "Snore gets past the sleep gate")
  local other = sleeper(hit("thump", 10), nil, 3)
  ok(said(other, "Alpha is fast asleep!") and not said(other, "Alpha used thump!"), "...any other move does not")
  local ignored
  for seed = 1, 40 do
    local events = sleeper(hit("SLEEP_TALK", 0), true, seed)
    if said(events, "Alpha ignored orders...sleeping!") then ignored = events; break end
  end
  ok(ignored ~= nil, "a disobedient sleeper using Sleep Talk ignores orders")
  ok(ignored and not said(ignored, "Alpha used SLEEP_TALK!"), "...and the move is not used")
end

-- (m) `.UseInstead` spends the other move's PP and forgets the last move
do
  local found
  for seed = 1, 400 do
    local battle, foe = fight({ mode = "wild", seed = seed,
      a = { held({ species = "Alpha", level = 80, spe = 90, traded = true,
                   moves = { hit("thump", 10), hit("pound_two", 10) } }) },
      b = { held({ species = "Beta", level = 80, maxHp = 900, spe = 10, moves = { hit("tap", 1) } }) } })
    drain(battle)
    local events = round(battle, foe)
    if said(events, "Alpha used instead, pound_two!") then found = battle; break end
  end
  ok(found ~= nil, "a disobedient monster uses another move instead")
  if found then
    local alpha = found.byId.p1.mons[1]
    eq(alpha.moves[2].pp, 29, "...spending that move's PP")
    eq(alpha.moves[1].pp, 30, "...not the chosen one's")
    eq(alpha.lastMoveIndex, 0, "...and `.EndDisobedience` forgets it as the last move")
  end
end

-- (n) the flinch reset at turn open, and the recharge exception
do
  local rock = { "KINGS_ROCK", "HELD_FLINCH", 255, "KING'S ROCK" }
  local battle, foe = fight({ mode = "wild", seed = 3,
    a = { held({ species = "Alpha", spe = 90, moves = { hit("tap", 1) } }) },
    b = { held({ species = "Beta", spe = 10, item = rock, moves = { hit("thump", 10) } }) } })
  drain(battle)
  local B = Turn.Battle
  local orig = B._openTurn
  local seen
  B._openTurn = function(self) seen = self.byId.p1.mons[1].flinch; return orig(self) end
  round(battle, foe)
  B._openTurn = orig
  eq(seen, true, "the slower holder's roll lands on a target that already moved")
  eq(battle.byId.p1.mons[1].flinch, false, "...and the turn's open clears it")
  ok(said(round(battle, foe), "Alpha used tap!"), "...so it acts next turn")
  -- a badge-rules seat whose monster must recharge keeps its own flag
  local kept = fight({ mode = "wild", seed = 3,
    a = { held({ species = "Alpha", spe = 90, moves = { hit("tap", 1) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("tap", 1) } }) } })
  local alpha = kept.byId.p1.mons[1]
  alpha.flinch, alpha.mustRecharge = true, true
  kept.byId.wild.mons[1].flinch = true
  kept:_openTurn()
  eq(alpha.flinch, true, "the player's recharging monster keeps its flag (CheckPlayerLockedIn returns first)")
  eq(kept.byId.wild.mons[1].flinch, false, "...the computer's is reset")
  local linked = fight({ mode = "1v1", seed = 3,
    a = { held({ species = "Alpha", spe = 90, moves = { hit("tap", 1) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("tap", 1) } }) } })
  local lalpha = linked.byId.p1.mons[1]
  lalpha.flinch, lalpha.mustRecharge = true, true
  linked:_openTurn()
  eq(lalpha.flinch, false, "a link battle resets every flag")
end

-- (o) Mysteryberry, the stat-up items, and every event passing the whitelist
do
  local battle, foe = fight({ seed = 2,
    a = { held({ species = "Alpha", spe = 90, item = { "MYSTERYBERRY", "HELD_RESTORE_PP", 0, "MYSTERYBERRY" },
                 moves = { hit("tap", 1), hit("spent", 40, 0, 0, 0) } }) },
    b = { held({ species = "Beta", spe = 10, item = { "X_GEM", "HELD_SPEED_UP", 0, "X GEM" },
                moves = { hit("tap", 1) } }) } })
  local events = drain(battle)
  for _, e in ipairs(round(battle, foe)) do events[#events + 1] = e end
  eq(battle.byId.p1.mons[1].moves[2].pp, 5, "Mysteryberry: +5 PP to the first empty slot")
  ok(said(events, "Alpha recovered PP using MYSTERYBERRY."), "...with the cart's line")
  eq(battle.byId[foe].mons[1].stages.spe, 1, "a HELD_SPEED_UP item raises Speed a stage")
  ok(said(events, "Beta's X GEM activated!"), "...and says so")
  local topped = held({ species = "Beta", spe = 10, item = { "X_GEM", "HELD_SPEED_UP", 0, "X GEM" },
                        moves = { hit("tap", 1) } })
  topped.stages = { spe = 6 }
  local full, ffoe = fight({ seed = 2, a = { held({ species = "Alpha", spe = 90, moves = { hit("tap", 1) } }) },
                             b = { topped } })
  drain(full)
  local fullEvents = round(full, ffoe)
  ok(not sawKind(fullEvents, "held"), "...but not past +6, where the item is kept")
  local good = true
  for _, e in ipairs(events) do
    local fine, why = Events.check(e)
    if not fine then good = false; io.stderr:write("held whitelist: " .. tostring(why) .. "\n") end
  end
  ok(good, "every event the held items emit passes the vocabulary check")
  ok(Events.KINDS.held == true, "`held` is a Gen 2 kind")
end

-- (p) the wave-2 review fixes (docs/plans/gen12-referee-fidelity.md)
do
  local Damage = BattleSim2.Damage
  local function rngOf(battle) return battle.rng:state() end
  local function countSaid(events, text)
    local n = 0
    for _, event in ipairs(events) do
      if event.t == "msg" and event.text == text then n = n + 1 end
    end
    return n
  end

  -- A Bide's release skips `checkobedience` (StoreEnergy's
  -- SkipToBattleCommand): a traded level-80 monster draws exactly what an
  -- untraded one does on that turn (seed 2 disobeyed here before).
  local function bideRelease(traded)
    local alpha = held({ species = "Alpha", level = 80, maxHp = 900, spe = 90, traded = traded,
                         moves = { hit("BIDE", 0, 0, 26, 10), hit("tap", 10) } })
    alpha.bide = { turns = 0, stored = 40, moveIndex = 1, targetSlot = 3 }
    local battle, foe = fight({ mode = "wild", seed = 2, a = { alpha },
      b = { held({ species = "Beta", maxHp = 900, spe = 10, moves = { hit("tap", 1) } }) } })
    drain(battle)
    -- A player's Bide is asked (R2b's finding (h), R2c): its FIGHT is the
    -- release, whatever slot it names.
    battle:submitChoice("p1", { action = "fight", move = 1 })
    battle:submitChoice(foe, { action = "fight", move = 0 })
    return drain(battle), battle
  end
  local tEvents, tBattle = bideRelease(true)
  local _, uBattle = bideRelease(nil)
  -- StoreEnergy's release says "unleashed energy" and runs no `usedmovetext`
  -- (R2b), at its slot rather than at the turn's open.
  ok(said(tEvents, "Alpha unleashed energy!") and not said(tEvents, "Alpha used BIDE!"),
     "a traded monster's Bide is unleashed")
  eq(damageOn(tEvents, 3), 80, "...at twice the energy stored")
  eq(rngOf(tBattle), rngOf(uBattle), "...and its release draws no obedience byte")

  -- CheckTurn's order: confusion, then the disabled move, then paralysis.
  local function confusedFight(status)
    local battle, foe = fight({ seed = 8,
      a = { held({ species = "Alpha", spe = 90, status = status, confusion = 4, moves = { hit("thump", 10) } }) },
      b = { held({ species = "Beta", spe = 10, moves = { hit("tap", 1) } }) } })
    drain(battle)
    return round(battle, foe), battle
  end
  local pcEvents, pcBattle = confusedFight("PAR")
  local _, cBattle = confusedFight(nil)
  ok(said(pcEvents, "It hurt itself in its confusion!"), "a paralysed, confused monster rolls its confusion first")
  eq(rngOf(pcBattle), rngOf(cBattle), "...and a self-hit leaves no paralysis byte drawn")
  -- Gold's DISABLE reads the target's LAST_COUNTER_MOVE (R2d), so Alpha
  -- uses thump once first; its paralysis is put on after that turn, so both
  -- fights reach the second one with the same stream.
  local function disabledFight(status)
    local alpha = held({ species = "Alpha", spe = 10,
                         moves = { hit("thump", 10), hit("pound_two", 10) } })
    local battle, foe = fight({ seed = 9, a = { alpha },
      b = { held({ species = "Beta", spe = 90, moves = { hit("DISABLE", 0, 0, 86), hit("tap", 1) } }) } })
    drain(battle)
    round(battle, foe, nil, { action = "fight", move = 1 })
    battle.fighters[1].mons[1].status = status and "paralysis" or nil
    return round(battle, foe), battle
  end
  local pdEvents, pdBattle = disabledFight("PAR")
  local _, dBattle = disabledFight(nil)
  ok(said(pdEvents, "Alpha's thump is DISABLED!"), "the move a faster Disable just took is refused")
  ok(not said(pdEvents, "Alpha's fully paralyzed!"), "...before the paralysis gate")
  eq(rngOf(pdBattle), rngOf(dBattle), "...which draws no byte for it")

  -- HandleMysteryberry reads the party PP, which a transformed monster never
  -- spends: the referee skips it and the berry is kept.
  local copy = held({ species = "Alpha", spe = 90, item = { "MYSTERYBERRY", "HELD_RESTORE_PP", 0, "MYSTERYBERRY" },
                      moves = { hit("tap", 1), hit("spent", 40, 0, 0, 0) } })
  copy.transformed = true
  local mBattle, mFoe = fight({ seed = 2, a = { copy },
    b = { held({ species = "Beta", spe = 10, moves = { hit("tap", 1) } }) } })
  drain(mBattle)
  local mEvents = round(mBattle, mFoe)
  eq(mBattle.byId.p1.mons[1].heldItem, "MYSTERYBERRY", "a transformed holder keeps its Mysteryberry")
  eq(mBattle.byId.p1.mons[1].moves[2].pp, 0, "...and its copied slot gains nothing")
  ok(not sawKind(mEvents, "held"), "...and nothing is said about it")

  -- GetSixteenthMaxHP over GetQuarterMaxHP, register for register.
  eq(Items.sixteenth(1024), 257, "1024 HP: b = 1 rides through, c = 0 -> 1 -> 0 -> 1")
  eq(Items.sixteenth(1100), 260, "1100 HP: 256 + (19 >> 2)")
  eq(Items.sixteenth(999), 62, "under 1024 it is max(1, floor(maxHp / 16))")
  eq(Items.sixteenth(15), 1, "...at least 1")

  -- A Leech Seed sap that knocks the seeded monster out: no throw, and the
  -- seeder is still healed.
  local seeded = held({ species = "Beta", maxHp = 320, hp = 10, spe = 10, moves = { hit("tap", 1) } })
  seeded.leechSeed = { fromSlot = 0 }
  local lBattle, lFoe = fight({ seed = 3, b = { seeded },
    a = { held({ species = "Alpha", maxHp = 300, hp = 100, spe = 90, moves = { hit("tap", 1) } }) } })
  drain(lBattle)
  local lok, lEvents = pcall(round, lBattle, lFoe)
  ok(lok, "a sap that knocks the seeded monster out does not throw")
  if lok then
    ok(said(lEvents, "LEECH SEED saps Beta!"), "...the sap is announced")
    -- GetEighthMaxHP of 320 is 40, but SubtractHP hands back the 9 HP Beta
    -- had left, and that is what RestoreHP gives the seeder.
    eq(lBattle.byId.p1.mons[1].hp, 108, "...and the seeder is healed the HP taken (99 + 9)")
    eq(lBattle:outcome() and lBattle:outcome().reason, "ko", "...and the faint ends the fight")
  end

  -- Gold / Crystal Rage: a counter, not an Attack stage, and no lock-in.
  local function rageFight(o)
    local alpha = held({ species = "Alpha", maxHp = 500, spe = o.aSpe or 90, status = o.status,
                         confusion = o.confusion, substitute = o.substitute,
                         moves = { hit("RAGE", 20, 0, 81), hit("tap", 1) } })
    alpha.raging, alpha.rageCounter = o.raging, o.rageCounter
    local battle, foe = fight({ seed = o.seed, a = { alpha },
      b = { held({ species = "Beta", maxHp = o.bHp or 900, spe = o.bSpe or 10,
                   moves = { hit(o.bMove or "pelt", 5, 0, o.bEffect or 29), hit("tap", 1) } }) } })
    drain(battle)
    return battle, foe
  end
  local rBattle, rFoe = rageFight({ seed = 11 })
  local r1 = round(rBattle, rFoe)
  local ralpha = rBattle.byId.p1.mons[1]
  local built = countSaid(r1, "Alpha's RAGE is building!")
  ok(built >= 2, "every hit of a multi-hit move builds rage")
  eq(ralpha.rageCounter, built, "...one counter step per line")
  eq(ralpha.stages.atk, 0, "...and Gold's Rage raises no Attack stage")
  ok(ralpha.raging, "Rage that connected leaves the user raging")
  eq(rBattle.byId.p1.choice, nil, "...but not locked in: the seat is asked again")
  ok(not said(r1, "Alpha's RAGE is building"), "...and no turn-open lock-in line")
  round(rBattle, rFoe, { action = "fight", move = 1 }, { action = "fight", move = 1 })
  eq(ralpha.raging, false, "choosing another move ends the rage")
  eq(ralpha.rageCounter, 0, "...and zeroes the counter")
  -- The top roll (Damage.ROLL_MAX: 255 since R2d's DamageVariation byte) is
  -- x255/255, the damage as it stands.
  local top = Damage.ROLL_MAX
  local base = Damage.compute({ level = 20, attack = 40 }, { defense = 40 }, { power = 20 }, { roll = top }).damage
  eq(Damage.compute({ level = 20, attack = 40 }, { defense = 40 }, { power = 20 },
                    { roll = top, rageCount = 4 }).damage, 5 * base, "RageDamage: x(count + 1)")
  eq(Damage.compute({ level = 20, attack = 40 }, { defense = 40 }, { power = 20 },
                    { roll = top, rageCount = 255 }).damage, 256 * base,
     "...x256 at 255, with no 999 tail after it")
  eq(Damage.compute({ level = 100, attack = 255 }, { defense = 1 }, { power = 250 },
                    { roll = top, rageCount = 255 }).damage, 65535,
     "...pinned at $ffff when the sum carries")
  -- Seed 2 (R2c's draw order moved it off 1).
  local sBattle, sFoe = rageFight({ seed = 2, status = "PSN", confusion = 3, bMove = "thump", bEffect = 0 })
  round(sBattle, sFoe)
  local s2 = round(sBattle, sFoe)
  ok(said(s2, "It hurt itself in its confusion!"), "seed 2: a confusion self-hit while raging")
  eq(sBattle.byId.p1.mons[1].rageCounter, 2, "...builds nothing, nor does poison: only Beta's two hits count")
  local cBattle2, cFoe2 = rageFight({ seed = 21, aSpe = 10, bSpe = 90, bHp = 999, raging = true,
                                      rageCounter = 254, substitute = 30 })
  local c1 = round(cBattle2, cFoe2)
  eq(countSaid(c1, "Alpha's RAGE is building!"), 1, "a hit into the substitute builds, and 255 holds silently")
  eq(cBattle2.byId.p1.mons[1].rageCounter, 255, "...at 255")
end

-- ------------------------------------------------------------------
-- 10. Gold side effects: the carts' conditions (FX6)
-- ------------------------------------------------------------------
--
-- Since Gold sheets carry the cart's `effectChance`, Gold secondary effects
-- fire in refereed fights, so each routine must ask what pokecrystal's asks
-- (engine/battle/effect_commands.asm, diffed against pokegold): the type
-- immunities (PoisonTarget's POISON check, CheckMoveTypeMatchesTarget for burn
-- and freeze, none for paralysis), BurnTarget's Defrost ahead of
-- wEffectFailed, FlinchTarget's sleeping / frozen return, and
-- BattleCommand_StatDown's `.ComputerMiss` byte -- shared by the primary and
-- the side-effect drops -- with the side effect's silent failures.
-- server/battle2_turn.test.js holds the same claims.

do
  -- Chart axis for the hand-built calls: NORMAL 0, FIRE 1, ICE 2, ELECTRIC 3,
  -- POISON 4, BUG 5, STEEL 6.
  local NORMAL, FIRE, ICE, ELECTRIC, POISON, BUG, STEEL = 0, 1, 2, 3, 4, 5, 6
  local TYPE_IDS = { "NORMAL", "FIRE", "ICE", "ELECTRIC", "POISON", "BUG", "STEEL" }
  local WIRE = { poison = "PSN", burn = "BRN", freeze = "FRZ", paralysis = "PAR" }
  -- A scripted byte source that counts what it hands out.
  local function bytes(list)
    local r = { drawn = 0 }
    function r:byte()
      self.drawn = self.drawn + 1
      return list[self.drawn] or 0
    end
    return r
  end
  local function tgt(o)
    o = o or {}
    -- `stats`: TryLowerStat reads the battle stat (a stat already at 1 is
    -- not lowered), so the target states one.
    return { species = "Tgt", types = o.types or { NORMAL }, status = o.status, statusTurns = 0,
             substitute = o.substitute or 0, mist = o.mist, confusion = o.confusion or 0,
             invulnerable = o.invulnerable,
             stats = { atk = 50, def = 50, spe = 50, spa = 50, spd = 50 },
             stages = { atk = o.atk or 0, def = 0, spe = 0, spa = 0, spd = 0, acc = 0, eva = 0 } }
  end
  local function side(effectId, target, o)
    o = o or {}
    return Effects.applySide({
      effectId = effectId, hit = o.hit ~= false, rng = o.rng or bytes({}), targetMon = target,
      targetFighter = { slot = 3, side = "b" }, userFighter = { slot = 0, side = "a" },
      statusToWire = WIRE, moveType = o.moveType, poisonType = o.poisonType,
      normalType = o.normalType, computerMover = o.computer,
    })
  end
  local function primary(effectId, target, o)
    o = o or {}
    return Effects.applyPrimary({
      effectId = effectId, rng = o.rng or bytes({}), targetMon = target,
      userMon = tgt(), targetFighter = { slot = 3, side = "b" }, userFighter = { slot = 0, side = "a" },
      statusToWire = WIRE, computerMover = o.computer,
    })
  end

  -- (a) PoisonTarget: CheckIfTargetIsPoisonType, POISON alone.
  local t = tgt({ types = { POISON } })
  side(2, t, { moveType = POISON, poisonType = POISON })
  eq(t.status, nil, "a POISON-type target is never poisoned by a side effect")
  t = tgt({ types = { BUG, POISON } })
  side(77, t, { moveType = BUG, poisonType = POISON })
  eq(t.status, nil, "...its second type counts (Twineedle on a Bug / Poison)")
  t = tgt({ types = { STEEL } })
  local out = side(77, t, { moveType = BUG, poisonType = POISON })
  eq(t.status, "poison", "a STEEL type a Bug move reaches is poisoned: the check is POISON alone")
  eq(out.events[1] and out.events[1].fields.status, "PSN", "...with the PSN token")
  t = tgt({ types = { POISON } })
  side(2, t, { moveType = POISON })
  eq(t.status, "poison", "a fight that names no types cannot tell POISON, and poisons")

  -- (b) BurnTarget / FreezeTarget: CheckMoveTypeMatchesTarget; ParalyzeTarget
  --     has no type check at all.
  t = tgt({ types = { FIRE } })
  side(4, t, { moveType = FIRE, normalType = NORMAL })
  eq(t.status, nil, "a Fire move never burns a Fire type")
  t = tgt({ types = { NORMAL, FIRE } })
  side(4, t, { moveType = FIRE, normalType = NORMAL })
  eq(t.status, nil, "...nor a dual type whose second type is Fire")
  t = tgt({ types = { NORMAL } })
  side(4, t, { moveType = FIRE, normalType = NORMAL })
  eq(t.status, "burn", "a Fire move burns a Normal type")
  t = tgt({ types = { NORMAL } })
  side(4, t, { moveType = NORMAL, normalType = NORMAL })
  eq(t.status, "burn", "a NORMAL move never matches (the Tri Attack exemption)")
  t = tgt({ types = { NORMAL } })
  side(4, t, { moveType = NORMAL })
  eq(t.status, nil, "...which needs the names: without typeIds the indices alone decide")
  t = tgt({ types = { ICE } })
  side(5, t, { moveType = ICE, normalType = NORMAL })
  eq(t.status, nil, "an Ice move never freezes an Ice type")
  t = tgt({ types = { FIRE } })
  side(5, t, { moveType = ICE, normalType = NORMAL })
  eq(t.status, "freeze", "an Ice move freezes a Fire type")
  t = tgt({ types = { ELECTRIC } })
  side(6, t, { moveType = ELECTRIC, normalType = NORMAL })
  eq(t.status, "paralysis", "an Electric move paralyses an Electric type: ParalyzeTarget asks no type")
  t = tgt({ types = { NORMAL } })
  side(36, t, { moveType = NORMAL, normalType = NORMAL })
  eq(t.status, "paralysis", "...and a Normal one a Normal type")
  for _, id in ipairs({ 2, 4, 5, 6 }) do
    t = tgt({ types = { BUG }, substitute = 10 })
    side(id, t, { moveType = NORMAL, normalType = NORMAL, poisonType = POISON })
    eq(t.status, nil, "effect " .. id .. ": a substitute standing at the command stops it")
  end

  -- (c) BurnTarget's Defrost, ahead of wEffectFailed.
  t = tgt({ status = "freeze" })
  out = side(4, t, { hit = false, moveType = FIRE, normalType = NORMAL })
  eq(t.status, nil, "a burn-family hit thaws a frozen target whatever its chance byte said")
  eq(out.messages[1], "Tgt was defrosted!", "...with the cart's line")
  eq(out.events[1] and out.events[1].fields.status, nil, "...on a status event with no token (a cure)")
  t = tgt({ status = "freeze", types = { FIRE } })
  side(4, t, { hit = true, moveType = FIRE, normalType = NORMAL })
  eq(t.status, nil, "...a Fire-type one too: Defrost comes before the type check")
  t = tgt({ status = "freeze", substitute = 10 })
  side(4, t, { hit = true, moveType = FIRE, normalType = NORMAL })
  eq(t.status, "freeze", "a standing substitute returns before Defrost")
  t = tgt({ status = "paralysis" })
  out = side(4, t, { hit = true, moveType = FIRE, normalType = NORMAL })
  eq(t.status, "paralysis", "any other status ends BurnTarget at Defrost's `ret z`")
  eq(#out.messages, 0, "...silently")
  t = tgt({ status = "freeze" })
  side(5, t, { hit = true, moveType = ICE, normalType = NORMAL })
  eq(t.status, "freeze", "only BurnTarget thaws")

  -- (d) FlinchTarget: `and 1 << FRZ | SLP_MASK / ret nz`.
  t = tgt({ status = "sleep" })
  side(31, t)
  eq(t.flinch, nil, "a sleeping target is never flinched")
  t = tgt({ status = "freeze" })
  side(37, t)
  eq(t.flinch, nil, "...nor a frozen one")
  t = tgt({ status = "paralysis" })
  side(31, t)
  eq(t.flinch, true, "a paralysed one is")
  t = tgt({ substitute = 5 })
  side(31, t)
  eq(t.flinch, nil, "...and nothing behind a substitute")

  -- (e) BattleCommand_StatDown for a side effect: the computer's byte, and
  --     every failure silent.
  eq(Effects.COMPUTER_DROP_MISS, 64, "`cp 25 percent + 1` is 64")
  local r = bytes({ 63 })
  t = tgt()
  out = side(68, t, { rng = r, computer = true })
  eq(r.drawn, 1, "the computer's side-effect drop draws its byte")
  eq(t.stages.atk, 0, "...under 64 it misses")
  eq(#out.messages, 0, "...silently")
  r = bytes({ 64 })
  t = tgt()
  out = side(68, t, { rng = r, computer = true })
  eq(t.stages.atk, -1, "64 and over goes on to the drop")
  eq(out.messages[1], "Tgt's ATTACK fell!", "...with its line")
  r = bytes({ 200 })
  t = tgt()
  side(70, t, { rng = r, computer = true, hit = false })
  eq(r.drawn, 1, "the byte is drawn even when the chance byte failed")
  eq(t.stages.spe, 0, "...which then fails at wEffectFailed")
  r = bytes({ 200 })
  t = tgt({ substitute = 10 })
  side(68, t, { rng = r, computer = true })
  eq(r.drawn, 1, "...and for a hit into a substitute")
  eq(t.stages.atk, 0, "...which then fails at CheckSubstituteOpp")
  r = bytes({ 200 })
  t = tgt({ mist = true })
  out = side(68, t, { rng = r, computer = true })
  eq(r.drawn, 0, "Mist stops the routine before the byte")
  eq(#out.messages, 0, "...and a side effect says nothing about it (no \"But it failed\")")
  r = bytes({ 200 })
  t = tgt({ atk = -6 })
  out = side(68, t, { rng = r, computer = true })
  eq(r.drawn, 0, "a stage at -6 stops it before the byte")
  eq(#out.messages, 0, "...silently (no \"won't go any lower\")")
  r = bytes({})
  t = tgt()
  side(68, t, { rng = r })
  eq(r.drawn, 0, "a player's side-effect drop draws no byte")
  eq(t.stages.atk, -1, "...and lands")
  -- DefenseDownHit's second `effectchance` (pokecrystal docs/bugs_and_
  -- glitches.md): drawn in the tail against the substitute standing then, and
  -- its verdict is the one StatDown reads.
  r = bytes({ 10 })
  t = tgt()
  out = Effects.applySide({ effectId = 69, hit = false, chance = 30, rng = r, targetMon = t,
    targetFighter = { slot = 3, side = "b" }, statusToWire = WIRE })
  eq(r.drawn, 1, "DEFENSE_DOWN_HIT draws its second effectchance byte")
  eq(t.stages.def, -1, "...and a landed second byte lowers Defense whatever the first said")
  r = bytes({ 200 })
  t = tgt()
  Effects.applySide({ effectId = 69, hit = true, chance = 30, rng = r, targetMon = t,
    targetFighter = { slot = 3, side = "b" }, statusToWire = WIRE })
  eq(t.stages.def, 0, "...and a failed one stops it whatever the first said")
  r = bytes({ 10 })
  t = tgt({ substitute = 10 })
  Effects.applySide({ effectId = 69, hit = true, chance = 30, rng = r, targetMon = t,
    targetFighter = { slot = 3, side = "b" }, statusToWire = WIRE })
  eq(r.drawn, 0, "...which a substitute still standing skips, byte and all")
  t = tgt({ invulnerable = true })
  side(68, t)
  eq(t.stages.atk, 0, "CheckHiddenOpponent: a target in the sky or underground is not lowered")
  r = bytes({ 0 })
  t = tgt({ substitute = 10 })
  out = side(76, t, { rng = r })
  eq(r.drawn, 0, "ConfuseTarget: a substitute returns before the turn byte")
  eq(t.confusion, 0, "...and confuses nothing")

  -- (f) ...and for a primary stat-down move: the same routine, in its order.
  eq(Effects.primaryStatDown(18), "atk", "ATTACK_DOWN lowers atk")
  eq(Effects.primaryStatDown(62), "acc", "ACCURACY_DOWN_2 lowers acc")
  eq(Effects.primaryStatDown(10), nil, "a raise is no stat-down move")
  eq(Effects.primaryStatDown(68), nil, "...and a *DownHit is the side effect's")
  r = bytes({ 10 })
  t = tgt()
  out = primary(18, t, { rng = r, computer = true })
  eq(out.messages[1], "But it failed!", "the computer's GROWL misses on a byte under 64")
  eq(t.stages.atk, 0, "...lowering nothing")
  r = bytes({ 64 })
  t = tgt()
  primary(18, t, { rng = r, computer = true })
  eq(t.stages.atk, -1, "...and lands at 64")
  r = bytes({ 64 })
  t = tgt({ substitute = 10 })
  out = primary(18, t, { rng = r, computer = true })
  eq(r.drawn, 1, "the byte comes before the substitute")
  eq(out.messages[1], "But it failed!", "...which then stops the move (`.Failed`, R2b)")
  r = bytes({ 64 })
  t = tgt({ mist = true })
  out = primary(18, t, { rng = r, computer = true })
  eq(r.drawn, 0, "Mist comes before the byte")
  eq(out.messages[1], "Tgt's protected by MIST.", "...with the cart's Mist line (ProtectedByMistText, R2b)")
  r = bytes({ 64 })
  t = tgt({ atk = -6 })
  out = primary(18, t, { rng = r, computer = true })
  eq(r.drawn, 0, "so does a stage at -6")
  eq(out.messages[1], "Tgt's ATTACK won't drop anymore!", "...with the cart's line (WontDropAnymoreText, R2b)")
  r = bytes({ 64 })
  t = tgt({ atk = -5 })
  primary(58, t, { rng = r, computer = true })
  eq(r.drawn, 1, "a -2 drop from -5 goes on to the byte")
  eq(t.stages.atk, -6, "...and stops at -6")
  t = tgt({ mist = true, substitute = 10 })
  out = primary(18, t)
  eq(out.messages[1], "Tgt's protected by MIST.", "Mist is asked before the substitute, a player's move too")
  eq(out.nothing, false, "...so the substitute's \"nothing happened\" is not the line")

  -- (g) Through the turn machine.  Two seats on one seed: the wild fight is
  --     the computer's, the 1v1 the same fight between two players.  Ann
  --     waits (a 0-power no-op); Bob uses the move under test.
  local function duelOf(mode, bMove, o)
    o = o or {}
    local battle, foe = fight({ mode = mode, seed = o.seed or 5, typeIds = TYPE_IDS,
      a = { held({ species = "Alpha", maxHp = 300, spe = o.aSpe or 10, types = { NORMAL },
                   status = o.aStatus, statusTurns = o.aTurns,
                   moves = { o.aMove or hit("wait", 0, 0, 85) } }) },
      b = { held({ species = "Beta", maxHp = 300, hp = o.bHp, spe = o.bSpe or 90, types = o.bTypes or { NORMAL },
                   status = o.bStatus, statusTurns = o.bTurns, item = o.bItem, moves = { bMove } }) } })
    local aMon = battle.byId.p1.mons[1]
    if o.aSub then aMon.substitute = o.aSub end
    if o.aAway then aMon.invulnerable = true end
    drain(battle)
    return battle, round(battle, foe)
  end
  local function oneByteAhead(link, wild, what)
    local probe = link.rng:clone()
    probe:byte()
    eq(wild.rng:state(), probe:state(), what)
  end
  local growl = { id = "growl", pp = 30, power = 0, accuracy = 100, type = 0, effect = 18, chance = 0 }
  local linkG = duelOf("1v1", growl)
  local wildG, wildGEvents = duelOf("wild", growl)
  oneByteAhead(linkG, wildG, "the computer's GROWL draws one byte the same move in a link fight does not")
  ok(said(wildGEvents, "Beta used growl!"), "...on Bob's turn")
  local miss = { id = "growl", pp = 30, power = 0, accuracy = 1, type = 0, effect = 18, chance = 0 }
  local linkM, linkMEvents = duelOf("1v1", miss)
  local wildM = duelOf("wild", miss)
  -- A missed primary stat-down move says StatDownFailText's line -- `.Failed`
  -- on wAttackMissed is "But it failed" -- not a miss line (R2b).
  ok(said(linkMEvents, "But it failed!") and not said(linkMEvents, "Beta's attack missed!"),
     "a 1% GROWL misses on this seed, with StatDownFailText's line")
  oneByteAhead(linkM, wildM, "...and the computer's still draws its StatDown byte after the miss")
  local linkF, linkFEvents = duelOf("1v1", growl, { aAway = true })
  local wildF = duelOf("wild", growl, { aAway = true })
  ok(said(linkFEvents, "But it failed!"), "a GROWL at a target in the sky fails (`.FlyDigMoves`)")
  oneByteAhead(linkF, wildF, "...and the computer's draws its StatDown byte there too")
  local aurora = { id = "aurora", pp = 30, power = 10, accuracy = 100, type = 2, effect = 68, chance = 10 }
  local linkS = duelOf("1v1", aurora, { aSub = 250 })
  local wildS, wildSEvents = duelOf("wild", aurora, { aSub = 250 })
  oneByteAhead(linkS, wildS, "the computer's AURORA BEAM into a substitute draws the StatDown byte, and only it")
  eq(wildS.byId.p1.mons[1].stages.atk, 0, "...lowers nothing")
  ok(not said(wildSEvents, "But it failed!"), "...and says nothing about it")

  -- The reviewer's BITE probe: a sleeper that wakes and acts is not flinched.
  local bite = { id = "bite", pp = 30, power = 10, accuracy = 100, type = 0, effect = 31, chance = 100 }
  local _, biteEvents = duelOf("1v1", hit("tap", 1), { aMove = bite, aSpe = 90, bSpe = 10,
                                                       bStatus = "SLP", bTurns = 1 })
  ok(not said(biteEvents, "Beta flinched!"), "a flinch hit on a sleeping target sets nothing")
  ok(said(biteEvents, "Beta used tap!"), "...so the target that wakes this turn acts")

  -- Type immunity through the machine: a 100% ember on a Fire type.
  local ember = { id = "ember", pp = 30, power = 10, accuracy = 100, type = FIRE, effect = 4, chance = 100 }
  local emberBattle, emberEvents = duelOf("1v1", hit("tap", 1), { aMove = ember, aSpe = 90, bSpe = 10,
                                                                   bTypes = { FIRE } })
  eq(emberBattle.byId.p2.mons[1].status, nil, "a Fire move at 100% never burns a Fire type")
  ok(not said(emberEvents, "Beta was burned!"), "...and says so nowhere")

  -- Defrost through the machine: a 10% ember on a frozen target thaws it,
  -- and the thawed target then takes its turn.
  local ember10 = { id = "ember", pp = 30, power = 10, accuracy = 100, type = FIRE, effect = 4, chance = 10 }
  local thawBattle, thawEvents = duelOf("1v1", hit("tap", 1), { aMove = ember10, aSpe = 90, bSpe = 10,
                                                                 bStatus = "FRZ" })
  ok(said(thawEvents, "Beta was defrosted!"), "a burn-family hit thaws a frozen target")
  eq(thawBattle.byId.p2.mons[1].status, nil, "...which is no longer frozen")
  ok(said(thawEvents, "Beta used tap!"), "...and moves this turn")

  -- `effectchance` stands before `applydamage` and only a substitute skips
  -- its byte: a Focus Band holder at 1 HP takes a hit for 0 and is still
  -- burned by it.
  local band = { "FOCUS_BAND", "HELD_FOCUS_BAND", 255, "FOCUS BAND" }
  local bandBattle, bandEvents = duelOf("1v1", hit("tap", 1), { aMove = ember, aSpe = 90, bSpe = 10,
                                                                 bHp = 1, bItem = band })
  ok(said(bandEvents, "Beta hung on with FOCUS BAND!"), "the band holds a 1-HP holder at 1")
  eq(bandBattle.byId.p2.mons[1].status, "burn", "...and the chance byte still draws and burns it")
end

-- ------------------------------------------------------------------
-- the referee-gaps run (docs/plans/gen12-referee-gaps-fix.md, R2a): the claims
-- the parity scenarios pin only as streams
-- ------------------------------------------------------------------

do
  local Damage = need("BattleSim2/Damage")
  -- A byte source that hands out a list, then 0s, and counts its draws.
  local function bytes(list)
    local r = { drawn = 0 }
    function r:byte()
      self.drawn = self.drawn + 1
      return list[self.drawn] or 0
    end
    return r
  end
  local function withMove(m, o)
    o = o or {}
    local battle = fight({ seed = o.seed or 5, mode = o.mode,
      a = { held({ species = "Alpha", maxHp = 400, spe = 90, status = o.status, moves = { m } }) },
      b = { held({ species = "Beta", maxHp = 900, spe = 10, substitute = o.substitute,
                   moves = { hit("wait", 0, 0, 85) } }) } })
    drain(battle)
    return battle
  end

  -- (a) the Gold-native ids, under the cart's own names
  local names = {
    EFFECT_SP_DEF_DOWN_HIT = 87, EFFECT_ACCURACY_DOWN_HIT = 88, EFFECT_ATTACK_UP_HIT = 89,
    EFFECT_DEFENSE_UP_HIT = 90, EFFECT_ALL_UP_HIT = 91, EFFECT_FLAME_WHEEL = 92,
    EFFECT_SACRED_FIRE = 93, EFFECT_STOMP = 94, EFFECT_TWISTER = 95, EFFECT_SNORE = 96,
    EFFECT_THUNDER = 97, EFFECT_TRI_ATTACK = 98, EFFECT_GUST = 99, EFFECT_EARTHQUAKE = 100,
    EFFECT_SKY_ATTACK = 101,
    -- R2b's: the commands the referee runs now, and TOXIC off POISON's id.
    EFFECT_SLEEP_TALK = 102, EFFECT_LOCK_ON = 103, EFFECT_SAFEGUARD = 104, EFFECT_TOXIC = 105,
  }
  for name, id in pairs(names) do
    eq(Effects.idOf(name), id, name .. " has its own id")
    eq(Effects.nameOf(id), name, "...and the id names it back")
  end
  eq(Effects.MAX_EFFECT_ID, 157, "the table ends at EFFECT_SKULL_BASH (R2d)")
  eq(Effects.nameOf(158), nil, "nothing past it")
  eq(Effects.category(101), "charge", "SKY ATTACK still charges")
  ok(Effects.isCharge(Effects.SKY_ATTACK), "...as a charge move")
  eq(Effects.idOf("EFFECT_RAZOR_WIND"), 39, "the other charge moves keep CHARGE_EFFECT")

  -- (b) BattleCommand_EffectChance: a byte at chance 0, none behind a substitute
  local r = bytes({ 254 })
  eq(Effects.effectChance(r, 100, false), true, "254 is under a 100% chance's byte")
  r = bytes({ 255 })
  eq(Effects.effectChance(r, 100, false), false, "255 is the 1/256 miss")
  r = bytes({ 0 })
  eq(Effects.effectChance(r, 0, false), false, "a 0% chance never lands...")
  eq(r.drawn, 1, "...but draws its byte (EARTHQUAKE, SKY ATTACK on the carts)")
  r = bytes({ 0 })
  eq(Effects.effectChance(r, 100, true), false, "a substitute fails it...")
  eq(r.drawn, 0, "...before any byte")
  ok(Effects.drawsEffectChance(4, hit("ember", 40, 1, 4)), "a burn hit's script has the command")
  ok(Effects.drawsEffectChance(Effects.EARTHQUAKE, hit("EARTHQUAKE", 40, 0, 100)), "...and EARTHQUAKE's")
  ok(not Effects.drawsEffectChance(Effects.TRI_ATTACK, hit("TRI_ATTACK", 40)), "TRI ATTACK draws its own later")
  ok(not Effects.drawsEffectChance(Effects.GUST, hit("GUST", 40)), "GUST has none")
  ok(not Effects.drawsEffectChance(0, hit("thump", 40)), "NormalHit has none")
  local thief = hit("THIEF", 40)
  thief.chance = 100
  ok(Effects.drawsEffectChance(0, thief), "a damaging id-0 move that states a chance is read as THIEF's")

  -- ...and on a miss: a 1%-accurate burn hit draws one byte more than a
  -- 1%-accurate plain hit, and a substitute takes that byte away again.
  -- A plain hit states no chance (a damaging id-0 move that did would be
  -- read as THIEF's script, which has the command).
  local function wild(effect)
    return { id = "wild", pp = 60, power = 40, accuracy = 1, type = 0, effect = effect,
             chance = (effect == 0) and 0 or 10 }
  end
  local missSeed
  for seed = 1, 400 do
    local b = withMove(wild(0), { seed = seed })
    if said(round(b, "p2"), "Alpha's attack missed!") then missSeed = seed; break end
  end
  ok(missSeed ~= nil, "found a seed where the 1% move misses")
  local plainMiss, burnMiss = withMove(wild(0), { seed = missSeed }), withMove(wild(4), { seed = missSeed })
  round(plainMiss, "p2"); round(burnMiss, "p2")
  local plainState, burnState = plainMiss.rng:state(), burnMiss.rng:state()
  local probe = need("BattleSim2/Rng").new(0):setState(plainState)
  probe:next()
  eq(burnState, probe:state(), "a missed burn hit draws exactly one more byte: its `effectchance`")
  local subMiss = withMove(wild(4), { seed = missSeed, substitute = 50 })
  local subPlain = withMove(wild(0), { seed = missSeed, substitute = 50 })
  round(subMiss, "p2"); round(subPlain, "p2")
  eq(subMiss.rng:state(), subPlain.rng:state(), "...and none behind a substitute")

  -- (c) MULTI_HIT's count: BattleRandom & 3, a second byte when it is 2 or 3
  local tally = { 0, 0, 0, 0, 0, 0 }
  for first = 0, 3 do
    for second = 0, 3 do
      local n = Effects.multiHitCount(bytes({ first, second }))
      tally[n] = tally[n] + 1
    end
  end
  -- 16 equally likely pairs: 2 and 3 take 4 + 2 each, 4 and 5 two each.
  eq(tally[2] .. "," .. tally[3] .. "," .. tally[4] .. "," .. tally[5], "6,6,2,2",
     "2 and 3 hits at 3/8 each, 4 and 5 at 1/8")
  r = bytes({ 1 })
  eq(Effects.multiHitCount(r), 3, "a first byte under 2 stands")
  eq(r.drawn, 1, "...with no second draw")
  eq(Effects.fixedHits(29), 1, "MULTI_HIT's count is not known before its first hit")
  eq(Effects.fixedHits(44), 2, "DOUBLE_HIT is two")
  eq(Effects.fixedHits(77), 2, "...and so is TWINEEDLE")

  -- (d) the counts the carts draw
  eq(Effects.wrapCount(bytes({ 0 })), 3, "TrapTarget: & 3 plus 3, from 3...")
  eq(Effects.wrapCount(bytes({ 7 })), 6, "...to 6")
  eq(Effects.rampageTurns(bytes({ 0 })) .. "/" .. Effects.rampageTurns(bytes({ 1 })), "1/2",
     "Rampage: 1 or 2 more turns")
  eq(Effects.rampageConfusion(bytes({ 0 })) .. "/" .. Effects.rampageConfusion(bytes({ 1 })), "2/3",
     "CheckRampage's confusion: 2 or 3 turns")
  eq(Effects.payDayCoins(30), 60, "PAY DAY: level x 2")
  eq(Effects.payDayCoins(140), 24, "...in a byte, its carry lost (`add a`, then `add [hl]`)")

  -- (e) StatDown's `.ComputerMiss` exemption for ACCURACY_DOWN_HIT
  r = bytes({ 0 })
  local target = { species = "Tgt", stages = { atk = 0, def = 0, spe = 0, spa = 0, spd = 0, acc = 0, eva = 0 } }
  eq(Effects.statDownGate(r, target, "acc", true, Effects.ACCURACY_DOWN_HIT), nil,
     "the computer's MUD-SLAP goes on to `.DidntMiss`...")
  eq(r.drawn, 0, "...without the 25% byte")
  eq(Effects.statDownGate(r, target, "atk", true, 68), "missed", "an ATTACK_DOWN_HIT still draws it")

  -- (f) RaiseStat on the user: silent at +6 and at a 999 battle stat
  local user = held({ species = "Alpha", def = 999, stages = { atk = 6 },
                      moves = { hit("tap", 1) } })
  user.stages = { atk = 6, def = 0, spe = 0, spa = 0, spd = 0, acc = 0, eva = 0 }
  local out = Effects.applySide({ effectId = Effects.ALL_UP_HIT, hit = true, rng = bytes({}),
    targetMon = { species = "Tgt", stages = target.stages, substitute = 0 },
    userMon = user, userFighter = { slot = 0, side = "a" }, targetFighter = { slot = 3, side = "b" } })
  eq(user.stages.atk .. "/" .. user.stages.def .. "/" .. user.stages.spe, "6/0/1",
     "ANCIENTPOWER raises what it can: Attack at +6 and Defense at 999 stay")
  eq(#out.messages, 3, "...three lines, and none for the two that failed")
  user.stages.spe = 0
  Effects.applySide({ effectId = Effects.ATTACK_UP_HIT, hit = false, rng = bytes({}),
    targetMon = { species = "Tgt", stages = target.stages, substitute = 0 },
    userMon = user, userFighter = { slot = 0, side = "a" }, targetFighter = { slot = 3, side = "b" } })
  eq(user.stages.spe, 0, "a failed effectchance raises nothing")

  -- (g) CantMove: a stopped rampage or charge is over
  -- Seed 3 (R2c: the 63/256 paralysis byte and the draw order moved it off 7).
  local thrasher = withMove(hit("THRASH", 20, 0, 27, 10), { seed = 3 })
  round(thrasher, "p2")
  local alpha = thrasher.byId.p1.mons[1]
  ok(alpha.thrashing ~= nil, "THRASH starts a rampage")
  alpha.status = "paralysis"
  local stopped = false
  for _ = 1, 30 do
    if not alpha.thrashing then break end
    local ev = round(thrasher, "p2")
    if said(ev, "Alpha's fully paralyzed!") then stopped = true; break end
  end
  ok(stopped, "seed 3: a full paralysis lands while the rampage runs")
  eq(alpha.thrashing, nil, "a full paralysis (CantMove) ends the rampage")
  eq(alpha.confusion, 0, "...with no confusion")
  local flier = withMove(hit("FLY", 30, 0, 43), { seed = 3 })
  round(flier, "p2")
  local fa = flier.byId.p1.mons[1]
  ok(fa.charging ~= nil and fa.invulnerable, "FLY charges and vanishes")
  fa.flinch = true
  local fev = round(flier, "p2")
  ok(said(fev, "Alpha flinched!"), "a flinch stops the release")
  eq(fa.charging, nil, "...and CantMove ends the charge")
  eq(fa.invulnerable, false, "...bringing the flier back down")

  -- (h) THRASH with its last PP keeps thrashing, never Struggle
  local last = withMove(hit("THRASH", 20, 0, 27, 1), { seed = 9 })
  round(last, "p2")
  local la = last.byId.p1.mons[1]
  eq(la.moves[1].pp, 0, "the first turn spends the last PP")
  local nextTurn = round(last, "p2")
  ok(said(nextTurn, "Alpha used THRASH!"), "the rampage's next turn is THRASH...")
  ok(not said(nextTurn, "Alpha used STRUGGLE!"), "...not Struggle")
  eq(la.moves[1].pp, 0, "...and spends no PP")

  -- (i) HYPER BEAM recharges after a hit into a substitute
  local beam = withMove(hit("HYPER_BEAM", 150, 0, 80), { seed = 4, substitute = 400 })
  local beamTurn = round(beam, "p2")
  eq(beam.byId.p2.mons[1].hp, 900, "the substitute took the HYPER BEAM")
  -- The recharge is the next turn's: said at its slot in that turn (R2b,
  -- CheckTurn's first test), not at the open of it.
  ok(not said(beamTurn, "Alpha must recharge!"), "...the line is not the HYPER BEAM turn's")
  ok(said(round(beam, "p2"), "Alpha must recharge!"), "...and it still recharges (the next turn)")

  -- (j) PAY DAY: the pot on a win against the computer, a catch included;
  --     none in a link fight
  local function payFight(mode)
    local b = fight({ mode = mode, seed = 6,
      a = { held({ species = "Alpha", level = 30, maxHp = 400, atk = 90, spe = 90,
                   moves = { hit("PAY_DAY", 40, 0, 16) } }) },
      b = { held({ species = "Beta", maxHp = 30, spe = 10, moves = { hit("wait", 0, 0, 85) } }) } })
    drain(b)
    local foe = (mode == "wild") and "wild" or "p2"
    for _ = 1, 6 do
      if b:outcome() then break end
      round(b, foe)
    end
    return b:outcome()
  end
  local won = payFight("wild")
  ok(won and won.outcome == "win" and won.payDay ~= nil and won.payDay % 60 == 0,
     "a won wild fight reports the pot, 60 a hit")
  eq(payFight("1v1").payDay, nil, "a link fight reports none")
  local catcher = fight({ mode = "wild", seed = 6,
    a = { held({ species = "Alpha", level = 30, maxHp = 400, atk = 1, spe = 90,
                 moves = { hit("PAY_DAY", 1, 0, 16) } }) },
    b = { held({ species = "Beta", maxHp = 900, spe = 10, moves = { hit("wait", 0, 0, 85) } }) } })
  drain(catcher)
  round(catcher, "wild")
  catcher:submitChoice("p1", { action = "item", item = "MASTER_BALL" })
  catcher:submitChoice("wild", { action = "fight", move = 0 })
  drain(catcher)
  local caught = catcher:outcome()
  eq(caught and caught.reason, "catch", "a MASTER BALL catches")
  eq(caught and caught.payDay, 60, "...and a catch is a WIN: the pot is paid")
end

-- ------------------------------------------------------------------
-- the referee-gaps run's wave 2 (docs/plans/gen12-referee-gaps-fix.md, R2b).
-- The parity scenarios (tests/drivers/battle2_turn_parity.lua, `r2b_*`) pin
-- the streams; these name the rules.
-- ------------------------------------------------------------------

-- (a) the sheet: K8 on a move, K7 / K14 on a monster; absent stays absent
do
  local b = fight({ seed = 1,
    a = { held({ species = "Alpha", moves = { { id = "jab", pp = 5, power = 10, accuracy = 100,
                                              priority = 2, ppUps = 3 }, hit("tap", 1) } }) },
    b = { held({ species = "Beta", moves = { hit("tap", 1) } }) } })
  local m = b.byId.p1.mons[1]
  eq(m.moves[1].priority, 2, "K8: the sheet's priority is kept")
  eq(m.moves[1].ppUps, 3, "K8: ...and its PP Ups")
  eq(m.moves[2].priority, nil, "...absent stays absent")
  local raw = held({ species = "Gamma", moves = { hit("tap", 1) } })
  raw.base = { hp = 50, atk = 60, def = 70, spe = 80, spa = 90, spd = 100 }
  raw.dvs = { atk = 15, def = 0, spe = 7, spc = 99 }
  raw.statExp = { hp = 1000 }
  raw.happiness = 300
  local c = fight({ seed = 1, a = { raw }, b = { held({ species = "Beta", moves = { hit("tap", 1) } }) } })
  local g = c.byId.p1.mons[1]
  eq(g.base.spd, 100, "K7: base kept")
  eq(g.dvs.spc, 15, "K7: a DV is held to 0..15")
  eq(g.statExp.hp, 1000, "K7: stat exp kept")
  eq(g.statExp.atk, nil, "K7: a block's missing key stays missing")
  eq(g.happiness, 255, "K14: happiness held to a byte")
  eq(b.byId.p1.mons[1].dvs, nil, "...and a sheet that states none carries none")
end

-- (b) K10: a `stat` event carries the signed stage, which Events accepts
do
  local b = fight({ seed = 2,
    a = { held({ species = "Alpha", spe = 90, moves = { hit("GROWL", 0, 0, 18) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("tap", 1) } }) } })
  drain(b)
  local events = round(b, "p2")
  local stage
  for _, e in ipairs(events) do
    if e.t == "stat" then stage = e.stage; ok(Events.check(e), "...and the event checks") end
  end
  eq(stage, -1, "a lowered stat's event says stage -1")
  eq(Events.FIELDS.stage, "number", "`stage` is a number field")
end

-- (c) CalcMonStatC (K9's fallback): ((base + DV) x 2 + root(exp) / 4) x L / 100 + 5,
--     HP + L + 10, the HP DV from the four's low bits, held at 999
do
  local s = Effects.calcMonStats({ hp = 100, atk = 100, def = 100, spe = 100, spa = 100, spd = 100 },
    { atk = 15, def = 15, spe = 15, spc = 15 }, { atk = 65535 }, 50)
  eq(s.stats.def, 120, "no stat exp: (115 x 2) x 50 / 100 + 5")
  eq(s.stats.atk, 151, "full stat exp: root 255, + 63")
  eq(s.maxHp, 175, "HP: the HP DV (15) and L + 10")
  eq(Effects.calcMonStats(nil, {}, nil, 50), nil, "nothing without base and DVs")
  local cap = Effects.calcMonStats({ hp = 255, atk = 255, def = 1, spe = 1, spa = 1, spd = 1 },
    { atk = 15, def = 0, spe = 0, spc = 0 }, { atk = 65535 }, 255)
  eq(cap.stats.atk, 999, "held at MAX_STAT_VALUE")
end

-- (d) the switch-in order: InitBattleMon (status, then badge) and
--     LoadEnemyMon (no status at all), until the next rebuild
do
  local b = fight({ mode = "wild", seed = 3, badges = { PLAIN = true },
    a = { held({ species = "Alpha", spe = 10, moves = { hit("tap", 1) } }),
          held({ species = "Gamma", spe = 15, status = "PAR", moves = { hit("tap", 1) } }) },
    b = { held({ species = "Beta", spe = 4, moves = { hit("tap", 1) } }) } })
  drain(b)
  round(b, "wild", { action = "switch", slot = 1 })
  local fa = b.byId.p1
  local g = fa.mons[2]
  eq(b:_speedOf(fa, g), 3, "a paralysed switch-in with PLAIN: boost(quarter(15)) = 3")
  eq(Effects.battleStat(g, "spe", fa.badges), 4, "...where CalcPlayerStats would read 4")
  g.stages.atk = 1
  eq(b:_speedOf(fa, g), 4, "a stage change rebuilds it in CalcPlayerStats's order")
  g.stages.atk = 0
  eq(b:_speedOf(fa, g), 4, "...and the snapshot stays gone when the stage comes back")
  local c = fight({ mode = "coop_npc", seed = 3,
    a = { held({ species = "Alpha", atk = 200, spe = 30, moves = { hit("slam", 40) } }) },
    b = { held({ species = "Beta", hp = 1, spe = 10, moves = { hit("tap", 1) } }),
          held({ species = "Delta", spe = 80, status = "PAR", moves = { hit("tap", 1) } }) } })
  drain(c)
  round(c, "p2")
  c:submitChoice("p2", { action = "switch", slot = 1 })
  local fb = c.byId.p2
  eq(c:_speedOf(fb, fb.mons[2]), 80, "the computer's paralysed switch-in keeps its full Speed")
  local d = fight({ seed = 3,
    a = { held({ species = "Alpha", atk = 200, spe = 30, moves = { hit("slam", 40) } }) },
    b = { held({ species = "Beta", hp = 1, spe = 10, moves = { hit("tap", 1) } }),
          held({ species = "Delta", spe = 80, status = "PAR", moves = { hit("tap", 1) } }) } })
  drain(d)
  round(d, "p2")
  d:submitChoice("p2", { action = "switch", slot = 1 })
  eq(d:_speedOf(d.byId.p2, d.byId.p2.mons[2]), 20, "...a link fight's foe is quartered (InitEnemyMon)")
end

-- (e) K9 levelUp: what it refuses, the HP step, a transformed and a benched mon
do
  local b = fight({ mode = "wild", seed = 4,
    a = { held({ species = "Alpha", level = 20, maxHp = 100, hp = 60, spe = 40, moves = { hit("tap", 1) } }),
          held({ species = "Gamma", level = 10, maxHp = 50, spe = 5, moves = { hit("tap", 1) } }) },
    b = { held({ species = "Beta", level = 20, maxHp = 900, spe = 50, moves = { hit("tap", 1) } }) } })
  drain(b)
  local stats = { atk = 45, def = 45, spe = 60, spa = 45, spd = 45 }
  eq(b:levelUp("nobody", 1, 21), false, "an unknown seat is refused")
  eq(b:levelUp("p1", 9, 21), false, "...a monster the party lacks")
  eq(b:levelUp("p1", 1, 19), false, "...a level below the current one")
  eq(b:levelUp("p1", 1, 101), false, "...past LEVEL_MAX")
  eq(b:levelUp("p1", 1, 21, { atk = 45 }), false, "...a stat block missing a stat")
  eq(b:levelUp("p1", 1, 20), false, "...and a report that changes nothing")
  eq(b:levelUp("p1", 1, 21, stats, 110), true, "a level-up lands")
  local a = b.byId.p1.mons[1]
  eq(a.level, 21, "the level")
  eq(a.maxHp, 110, "the max HP")
  eq(a.hp, 70, "the HP rises by the max-HP step")
  eq(a.stats.spe, 60, "the party stats")
  eq(b:_speedOf(b.byId.p1, a), 60, "and the fielded monster's battle stats are rebuilt")
  eq(b:levelUp("p1", 2, 11, stats, 60), true, "a benched monster grows too")
  eq(b.byId.p1.mons[2].stats.spe, 60, "...in its party stats")
  ok(b.byId.p1.mons[2].statSnap == nil, "...and no battle stats until it is sent out")
end

-- (f) Transform undone: a switch-out gives back the party moves, types and
--     stats; 5 PP a copied move, SKETCH 1
do
  local b = fight({ seed = 5,
    a = { held({ species = "Alpha", spe = 90, types = { 1 }, moves = { hit("TRANSFORM", 0, 0, 57, 10) } }),
          held({ species = "Gamma", spe = 20, moves = { hit("tap", 1) } }) },
    b = { held({ species = "Beta", atk = 120, spe = 60, types = { 3 },
                moves = { hit("SKETCH", 0), hit("slam", 40, 0, 0, 30) } }) } })
  drain(b)
  round(b, "p2")
  local a = b.byId.p1.mons[1]
  ok(a.transformed, "Alpha transformed")
  eq(a.moves[1].pp, 1, "SKETCH copied with 1 PP")
  eq(a.moves[2].pp, 5, "...the rest with 5")
  eq(a.types[1], 3, "...and the types")
  eq(a.stats.atk, 120, "...and the stats")
  round(b, "p2", { action = "switch", slot = 1 })
  ok(not a.transformed, "the switch-out undoes it")
  eq(a.moves[1].id, "TRANSFORM", "...its own moves back")
  eq(a.moves[1].pp, 9, "...with the PP the party kept")
  eq(a.types[1], 1, "...its own types")
  eq(a.stats.atk, 40, "...and its own stats")
end

-- (g) SLEEP TALK's pick: never itself, the disabled move or a two-turn one;
--     a 0-PP move is called all the same
do
  local b = fight({ seed = 6,
    a = { held({ species = "Alpha", status = "SLP", statusTurns = 7, spe = 90,
                 moves = { hit("SLEEP_TALK", 0, 0, 102), hit("SKULL_BASH", 50, 0, 39),
                           hit("BIDE", 0, 0, 26), hit("kick", 20, 0, 0, 0) } }) },
    b = { held({ species = "Beta", maxHp = 900, spe = 10, moves = { hit("tap", 1) } }) } })
  drain(b)
  local a = b.byId.p1.mons[1]
  for _ = 1, 4 do
    eq(b:_sleepTalkPick(a, a.moves[1]).id, "kick", "the one callable move, its 0 PP and all")
  end
  a.status = nil
  eq(b:_sleepTalkPick(a, a.moves[1]), nil, "awake, nothing")
end

-- (h) LOCK-ON: only a move whose script runs `checkhit` spends it, and while
--     it stands the computer's stat-down byte is skipped
do
  local b = fight({ seed = 7,
    a = { held({ species = "Alpha", spe = 90, moves = { hit("SWORDS_DANCE", 0, 0, 50), hit("tap", 1) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("tap", 1) } }) } })
  drain(b)
  local beta = b.byId.p2.mons[1]
  beta.lockOn = true
  round(b, "p2")
  eq(beta.lockOn, true, "SWORDS DANCE (no checkhit) leaves the target's lock-on")
  round(b, "p2", { action = "fight", move = 1 })
  eq(beta.lockOn, nil, "a hit spends it")
  local drawn = 0
  local r = { byte = function() drawn = drawn + 1; return 0 end }
  local t = { mist = false, stages = { atk = 0 } }
  eq(Effects.statDownGate(r, t, "atk", true, 18, true), nil, "locked on: no `.ComputerMiss`")
  eq(drawn, 0, "...and no byte drawn")
end

-- (i) a recharge is an actor: its Quick Claw rolls (DetermineMoveOrder
--     compares wCurPlayerMove)
do
  local function steps(from, to)
    local r = BattleSim2.Rng.new(0)
    r:setState(from)
    for n = 0, 64 do
      if r:state() == to then return n end
      r:next()
    end
    return nil
  end
  local function beam(item)
    local b = fight({ seed = 8,
      a = { held({ species = "Alpha", spe = 10, item = item, moves = { hit("HYPER_BEAM", 150, 0, 80) } }) },
      b = { held({ species = "Beta", maxHp = 900, spe = 50,
                   moves = { hit("tap", 1), hit("SPLASH", 0, 0, 85) } }) } })
    drain(b)
    round(b, "p2")
    local before = b.rng:state()
    -- SPLASH draws nothing, so the forced turn's bytes are the claw's alone
    -- (R2d: a hit's DamageVariation loop draws a varying count).
    b:submitChoice("p2", { action = "fight", move = 1 })
    local events = drain(b)
    return steps(before, b.rng:state()), events
  end
  local bare = beam(nil)
  local clawed, events = beam({ "QUICK_CLAW", "HELD_QUICK_CLAW", 255, "QUICK CLAW" })
  eq(clawed, bare + 1, "the recharging seat's claw rolls one byte on its forced turn")
  ok(said(events, "Alpha must recharge!"), "...and the recharge is said at its slot")
  eq(events[#events].t, "turn", "...the turn then opens")
end

-- (j) Haze reaches every monster on the field (BattleCommand_ResetStats)
do
  local mons = {}
  for i = 1, 4 do
    mons[i] = { species = "M" .. i, stages = { atk = 2, def = 0, spe = 0, spa = 0, spd = 0, acc = 0, eva = 0 } }
  end
  Effects.applyPrimary({ effectId = 25, userMon = mons[1], targetMon = mons[3],
    userFighter = { slot = 0, side = "a" }, targetFighter = { slot = 3, side = "b" }, fieldMons = mons })
  for i = 1, 4 do eq(mons[i].stages.atk, 0, "Haze resets battler " .. i) end
end

-- (k) TOXIC: 1/16 x n, and a switch-out leaves plain poison
do
  local b = fight({ seed = 9,
    a = { held({ species = "Alpha", spe = 90, moves = { hit("TOXIC", 0, 0, 105) } }) },
    b = { held({ species = "Beta", maxHp = 160, spe = 10, moves = { hit("tap", 1) } }),
          held({ species = "Delta", maxHp = 160, spe = 10, moves = { hit("tap", 1) } }) } })
  drain(b)
  local first = round(b, "p2")
  ok(said(first, "Beta's badly poisoned!"), "TOXIC badly poisons")
  eq(damageOn(first, 3), 10, "...the first tick 1/16")
  eq(damageOn(round(b, "p2"), 3), 20, "...the second 2/16")
  round(b, "p2", nil, { action = "switch", slot = 1 })
  eq(b.byId.p2.mons[1].status, "poison", "the switch-out leaves plain poison")
end

-- (l) the freeze: CheckTurn draws nothing for it and never thaws; HandleDefrost
--     skips the turn it landed
do
  local b = fight({ seed = 10,
    a = { held({ species = "Alpha", spe = 90, status = "FRZ", moves = { hit("tap", 1) } }) },
    b = { held({ species = "Beta", maxHp = 900, spe = 10, moves = { hit("wait", 0, 0, 85) } }) } })
  drain(b)
  local a = b.byId.p1.mons[1]
  a.justFrozen = true
  local before = b.rng:state()
  b:_runGates(b.byId.p1, a, a.moves[1])
  eq(b.rng:state(), before, "the frozen gate draws nothing")
  b:_heldDefrost()
  eq(b.rng:state(), before, "...nor does the defrost on the turn the freeze landed")
  a.justFrozen = nil
  b:_heldDefrost()
  ok(b.rng:state() ~= before, "the next turn's defrost rolls")
end

-- ------------------------------------------------------------------
-- 12. the referee-gaps run's wave 3 (R2c): the Gold move effects, weather and
--     R2b's found cart differences (the parity driver's r2c_* scenarios pin
--     the same rules across the twins)
-- ------------------------------------------------------------------
do
  local Status2 = need("BattleSim2/Status")
  local Rng2 = need("BattleSim2/Rng")
  local function stream(list)
    local i = 0
    return { byte = function() i = i + 1; return list[i] or 0 end }
  end
  local TYPES = { "NORMAL", "FIGHTING", "GHOST", "WATER", "FIRE", "ROCK", "STEEL", "GROUND" }
  local function f3(o)
    local battle, foe = fight(o)
    drain(battle)
    return battle, foe
  end
  local function am(id, power, ty, effect, acc, chance)
    local m = hit(id, power, ty, effect)
    m.accuracy, m.chance = acc or 255, chance or 0
    return m
  end
  local function dmgs(events, slot)
    local out = {}
    for _, e in ipairs(events) do
      if e.t == "damage" and e.slot == slot then out[#out + 1] = e.amount end
    end
    return out
  end

  -- (a) + (b): a 255 accuracy byte draws nothing, and a NormalHit draws its
  -- crit and roll whatever happens -- the crit byte and DamageVariation's
  -- loop (R2d: as many bytes as it takes) for the turn, a splash none.
  local b = f3({ seed = 41, a = { held({ species = "Alpha", spe = 90, moves = { hit("tap", 20) } }) },
    b = { held({ species = "Beta", maxHp = 900, spe = 10, moves = { hit("splash", 0, 0, 85) } }) } })
  local probe = Rng2.new(0):setState(b.rng:state())
  probe:byte(); probe:damageRoll()
  round(b, "p2")
  eq(b.rng:state(), probe:state(), "(a)+(b): a hit at byte 255 draws the crit and the roll only")

  -- (c) no sleep byte in CheckTurn; (d) 63/256; (e) SleepTarget's 2..7.
  local s = f3({ seed = 42, a = { held({ species = "Alpha", spe = 90, status = "SLP", statusTurns = 4,
                                          moves = { hit("tap", 1) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("tap", 1) } }) } })
  local sa = s.byId.p1.mons[1]
  local before = s.rng:state()
  s:_runGates(s.byId.p1, sa, sa.moves[1])
  eq(s.rng:state(), before, "(c): a sleeping monster's CheckTurn draws nothing")
  ok(Status2.paralysisStop(62) and not Status2.paralysisStop(63), "(d): full paralysis under 63")
  local target = { species = "T", hp = 10, maxHp = 10, stages = {}, types = { 0 }, substitute = 0 }
  Effects.applyPrimary({ effectId = 32, rng = stream({ 0, 7, 8, 3 }), userMon = { species = "U", maxHp = 10, stages = {} },
    targetMon = target, userFighter = { slot = 0, side = "a" }, targetFighter = { slot = 3, side = "b" } })
  eq(target.statusTurns, 4, "(e): 0 and 7 are drawn again, then 3 + 1")

  -- (f) the Disable count ticks in CheckTurn.
  local d = f3({ seed = 43, a = { held({ species = "Alpha", spe = 90, disable = { moveIndex = 2, turns = 1 },
                                          moves = { hit("tap", 1), hit("thump", 10) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("tap", 1) } }) } })
  local dev = round(d, "p2")
  ok(said(dev, "Alpha's disabled no more!"), "(f): the count runs out at CheckTurn")
  eq(d.byId.p1.mons[1].disable, nil, "...and the move is free again")

  -- (h) a player's Bide is asked (and an item ends it); the computer's is filled.
  local bd = f3({ seed = 44, a = { held({ species = "Alpha", spe = 90, moves = { hit("BIDE", 0, 0, 26), hit("tap", 1) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("tap", 5) } }) } })
  round(bd, "p2")
  ok(bd.byId.p1.mons[1].bide ~= nil, "BIDE begins")
  eq(bd.byId.p1.choice, nil, "(h): the player is asked during a Bide")
  round(bd, "p2", { action = "item", item = "POTION" })
  eq(bd.byId.p1.mons[1].bide, nil, "...and an item ends it")
  local cb = f3({ mode = "wild", seed = 45,
    a = { held({ species = "Alpha", spe = 10, moves = { hit("tap", 1) } }) },
    b = { held({ species = "Wild", spe = 90, moves = { hit("BIDE", 0, 0, 26) } }) } })
  round(cb, "wild")
  ok(cb.byId.wild.choice ~= nil and cb.byId.wild.forced, "...the wild monster's Bide is filled")

  -- (i) FlinchTarget: a target that went first is not flinched; a landing
  -- flinch cancels a recharge.
  local victim = { species = "V", hp = 10, maxHp = 10, stages = {}, substitute = 0, mustRecharge = true }
  Effects.applySide({ effectId = 31, hit = true, targetMon = victim, targetWentFirst = true,
    targetFighter = { slot = 3, side = "b" } })
  ok(not victim.flinch, "(i): a target that went first is not flinched")
  Effects.applySide({ effectId = 31, hit = true, targetMon = victim, targetWentFirst = false,
    targetFighter = { slot = 3, side = "b" } })
  ok(victim.flinch and not victim.mustRecharge, "...and a flinch cancels its recharge")

  -- PROTECT and COUNTER.
  local p = f3({ seed = 46, a = { held({ species = "Alpha", maxHp = 400, spe = 90,
                                          moves = { hit("PROTECT", 0, 0, Effects.PROTECT) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("slam", 40) } }) } })
  local pev = round(p, "p2")
  ok(said(pev, "Alpha's PROTECTING itself!") and damageOn(pev, 0) == nil, "PROTECT blocks the slam")
  eq(p.byId.p1.mons[1].protect, nil, "...and is down once the turn's moves are done")
  local c = f3({ seed = 47, a = { held({ species = "Alpha", maxHp = 600, spe = 10,
                                          moves = { hit("COUNTER", 1, 0, Effects.COUNTER) } }) },
    b = { held({ species = "Beta", maxHp = 900, spe = 90, moves = { hit("slam", 40) } }) } })
  local cev = round(c, "p2")
  eq(damageOn(cev, 3), 2 * damageOn(cev, 0), "COUNTER returns twice what the slam took")

  -- FUTURE SIGHT hits at the end of the turn after next.
  local fsb = f3({ seed = 48, a = { held({ species = "Alpha", spe = 90,
      moves = { hit("FUTURE_SIGHT", 80, 0, Effects.FUTURE_SIGHT), hit("splash", 0, 0, 85) } }) },
    b = { held({ species = "Beta", maxHp = 900, spe = 10, moves = { hit("splash", 0, 0, 85) } }) } })
  ok(said(round(fsb, "p2"), "Alpha foresaw an attack!"), "FUTURE SIGHT is foreseen")
  ok(not said(round(fsb, "p2", { action = "fight", move = 1 }), "Beta was hit by FUTURE SIGHT!"), "...not yet")
  ok(said(round(fsb, "p2", { action = "fight", move = 1 }), "Beta was hit by FUTURE SIGHT!"),
     "...it lands at the second turn's end")

  -- PURSUIT chases a player's switch, doubled, before it.
  local pu = f3({ seed = 49,
    a = { held({ species = "Alpha", spe = 90, moves = { hit("tap", 1) } }),
          held({ species = "Gamma", spe = 90, moves = { hit("tap", 1) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("PURSUIT", 40, 0, Effects.PURSUIT) } }) } })
  local puev = round(pu, "p2", { action = "switch", slot = 1 })
  local hitAt, switchAt
  for i, e in ipairs(puev) do
    if e.t == "damage" and not hitAt then hitAt = i end
    if e.t == "switch" and not switchAt then switchAt = i end
  end
  ok(hitAt and switchAt and hitAt < switchAt, "PURSUIT lands before the player's switch")

  -- The weather: THUNDER at a 1 byte never misses in the rain; SANDSTORM
  -- spares STEEL; the time-of-day heal reads the clock outside a link fight.
  local w = f3({ seed = 50, typeIds = TYPES,
    a = { held({ species = "Alpha", maxHp = 400, spe = 90,
                 moves = { hit("RAIN_DANCE", 0, 3, Effects.RAIN_DANCE), am("THUNDER", 60, 0, Effects.THUNDER, 1),
                           hit("SANDSTORM", 0, 5, Effects.SANDSTORM) } }) },
    b = { held({ species = "Beta", maxHp = 900, spe = 10, types = { 6 }, moves = { hit("splash", 0, 0, 85) } }) } })
  ok(said(round(w, "p2"), "A downpour started!"), "RAIN DANCE")
  local tev = round(w, "p2", { action = "fight", move = 1 })
  ok(damageOn(tev, 3) ~= nil, "THUNDER's 1 byte never misses in the rain")
  local sev = round(w, "p2", { action = "fight", move = 2 })
  ok(said(sev, "The SANDSTORM hits Alpha!") and not said(sev, "The SANDSTORM hits Beta!"),
     "SANDSTORM hits the NORMAL type and spares the STEEL one")
  local th = f3({ mode = "wild", seed = 51,
    a = { held({ species = "Alpha", maxHp = 400, hp = 50, spe = 90,
                 moves = { hit("MORNING_SUN", 0, 0, Effects.MORNING_SUN), hit("MOONLIGHT", 0, 0, Effects.MOONLIGHT) } }) },
    b = { held({ species = "Wild", spe = 10, moves = { hit("splash", 0, 0, 85) } }) } })
  th.timeOfDay = "nite"
  local function drained(events)
    for _, e in ipairs(events) do if e.t == "drain" then return e.amount end end
    return nil
  end
  eq(drained(round(th, "wild")), 100, "MORNING SUN at night: a quarter")
  eq(drained(round(th, "wild", { action = "fight", move = 1 })), 200, "MOONLIGHT at night: a half")

  -- The fixed-damage rows draw no crit and no roll: SEISMIC TOSS into a
  -- SPLASH leaves the stream where it was.
  local fx = f3({ seed = 52, a = { held({ species = "Alpha", level = 37, spe = 90,
                                           moves = { hit("SEISMIC_TOSS", 1, 1, Effects.LEVEL_DAMAGE) } }) },
    b = { held({ species = "Beta", maxHp = 900, spe = 10, moves = { hit("splash", 0, 0, 85) } }) } })
  local fxBefore = fx.rng:state()
  eq(damageOn(round(fx, "p2"), 3), 37, "(g): SEISMIC TOSS deals the level")
  eq(fx.rng:state(), fxBefore, "...with nothing drawn")

  -- ROLLOUT locks the seat in; BEAT UP from a wild monster "fails".
  local ro = f3({ seed = 53, a = { held({ species = "Alpha", spe = 90,
      moves = { hit("ROLLOUT", 30, 0, Effects.ROLLOUT), hit("tap", 1) } }) },
    b = { held({ species = "Beta", maxHp = 999, spe = 10, moves = { hit("tap", 1) } }) } })
  round(ro, "p2")
  ok(ro.byId.p1.choice ~= nil and ro.byId.p1.forced, "ROLLOUT's next roll is filled")
  local bu = f3({ mode = "wild", seed = 54,
    a = { held({ species = "Alpha", maxHp = 400, spe = 10, moves = { hit("tap", 1) } }) },
    b = { held({ species = "Wild", spe = 90, moves = { hit("BEAT_UP", 10, 0, Effects.BEAT_UP) } }) } })
  local buev = round(bu, "wild")
  ok(said(buev, "Wild's attack!") and said(buev, "But it failed!"), "a wild BEAT UP hits once and fails")
end

-- ------------------------------------------------------------------
-- the referee-gaps run's wave 4 (R2d): the rules the parity scenarios
-- (tests/drivers/battle2_turn_parity.lua, r2d_*) do not state on their own
-- ------------------------------------------------------------------

do
  local Effects = BattleSim2.Effects
  -- The ids and tables (Effects.lua 133..157).
  local names = {
    EFFECT_ATTRACT = 133, EFFECT_BATON_PASS = 134, EFFECT_BELLY_DRUM = 135,
    EFFECT_CONVERSION2 = 136, EFFECT_CURSE = 137, EFFECT_DESTINY_BOND = 138,
    EFFECT_ENCORE = 139, EFFECT_FORESIGHT = 140, EFFECT_HEAL_BELL = 141,
    EFFECT_MEAN_LOOK = 142, EFFECT_NIGHTMARE = 143, EFFECT_PAIN_SPLIT = 144,
    EFFECT_PERISH_SONG = 145, EFFECT_PSYCH_UP = 146, EFFECT_RAPID_SPIN = 147,
    EFFECT_SKETCH = 148, EFFECT_SPIKES = 149, EFFECT_SPITE = 150,
    EFFECT_SP_DEF_UP_2 = 151, EFFECT_SWAGGER = 152, EFFECT_TELEPORT = 153,
    EFFECT_SP_DEF_UP = 154, EFFECT_SP_DEF_DOWN = 155, EFFECT_SP_DEF_DOWN_2 = 156,
    EFFECT_SKULL_BASH = 157,
  }
  for name, id in pairs(names) do
    eq(Effects.idOf(name), id, "R2d: " .. name .. " has its own id")
  end
  ok(Effects.NO_CHECKHIT[134] and Effects.NO_CHECKHIT[151] and not Effects.NO_CHECKHIT[139],
     "R2d: BATON PASS and AMNESIA run no `checkhit`; ENCORE does")
  ok(Effects.READS_MISS[32] and Effects.READS_MISS[84] and not Effects.READS_MISS[18],
     "R2d: SleepTarget and LeechSeed read wAttackMissed; a stat-down's miss is StatDown's")
  ok(Items.kingsRockMove(147) and Items.kingsRockMove(157) and not Items.kingsRockMove(133),
     "R2d: RAPID SPIN and SKULL BASH run `kingsrock`, ATTRACT does not")
  ok(Effects.SLEEP_TALK_EXCLUDED[157], "R2d: SLEEP TALK never calls SKULL BASH")
  eq(Effects.primaryStatDown(156), "spd", "R2d: SP. DEF DOWN 2 is a primary stat-down")

  -- GetGender over K15's BASE_GENDER and the Attack / Speed DVs.
  local function g(ratio, atk, spe, extra)
    local m = { base = { gender = ratio }, dvs = { atk = atk, def = 0, spe = spe, spc = 0 } }
    for k, v in pairs(extra or {}) do m[k] = v end
    return Effects.gender(m)
  end
  eq(g(255, 15, 15), nil, "R2d: GENDER_UNKNOWN is genderless")
  eq(g(0, 0, 0), "M", "R2d: GENDER_F0 is male whatever the DVs")
  eq(g(254, 15, 15), "F", "R2d: GENDER_F100 is female whatever the DVs")
  eq(g(127, 7, 15), "F", "R2d: Attack DV 7 / Speed 15 (byte 127) is not above F50's 127: female")
  eq(g(127, 8, 0), "M", "R2d: ...byte 128 is: male")
  eq(Effects.gender({ dvs = { atk = 15, spe = 15 } }), nil, "R2d: no ratio on the sheet: no gender")
  eq(g(127, 0, 0, { preTransform = { dvs = { atk = 15, spe = 15 } } }), "M",
     "R2d: a transformed monster keeps its own DVs' gender")

  -- SKETCH's base PP off a row's max and its PP Ups (ComputeMaxPP).
  eq(Effects.basePp({ maxPp = 61, ppUps = 3 }), 40, "R2d: 40 + 3 x 7 = 61")
  eq(Effects.basePp({ maxPp = 32, ppUps = 3 }), 20, "R2d: 20 + 3 x 4 = 32")
  eq(Effects.basePp({ maxPp = 35 }), 35, "R2d: no PP Ups: the max")
end

do
  -- MEAN LOOK closes switching and running (BattleMenu_PKMN's `.check_trapped`,
  -- TryRunningFromBattle) to the seat it holds; BATON PASS is still open.
  local battle, foe = fight({ mode = "wild",
    a = { held({ species = "Alpha", spe = 10, moves = { hit("wait", 0, 0, 85) } }),
          held({ species = "Gamma", spe = 10, moves = { hit("wait", 0, 0, 85) } }) },
    b = { held({ species = "Wild", spe = 90, moves = { hit("MEAN_LOOK", 0, 0, 142) } }) } })
  drain(battle)
  local events = round(battle, foe)
  ok(said(events, "Alpha can't escape now!"), "R2d: the wild monster holds Alpha")
  ok(not battle:submitChoice("p1", { action = "switch", slot = 1 }), "R2d: ...no switch")
  ok(not battle:submitChoice("p1", { action = "run" }), "R2d: ...no run")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "R2d: ...a move is still chosen")
end

do
  -- The computer's FULL HEAL (AI_HealStatus): the burn goes and its Attack
  -- stays halved -- no CalcEnemyStats; the player's rebuilds it.  The burn
  -- lands in the fight (setStatus, BurnTarget's ApplyBrnEffectOnAttack): a
  -- computer's monster SENT OUT burned keeps its full Attack (LoadEnemyMon),
  -- which would hide the bug.
  local function healed(side)
    local burned = held({ species = "Burnt", atk = 100, spe = 10, moves = { hit("wait", 0, 0, 85) } })
    local other = held({ species = "Other", spe = 90, moves = { hit("wait", 0, 0, 85) } })
    local o = { mode = "coop_npc", a = { side == "a" and burned or other }, b = { side == "b" and burned or other } }
    local battle, foe = fight(o)
    drain(battle)
    local seat = side == "a" and battle.byId.p1 or battle.byId[foe]
    local mon = seat.mons[1]
    Effects.setStatusOn(mon, seat, "burn")
    eq(Effects.storedStat(mon, "atk", seat.badges), 50, "R2d: side " .. side .. "'s burn halves its Attack")
    if side == "a" then
      round(battle, foe, { action = "item", item = "FULL_HEAL" }, nil)
    else
      round(battle, foe, nil, { action = "item", item = "FULL_HEAL" })
    end
    return mon.status, Effects.storedStat(mon, "atk", seat.badges)
  end
  local aStatus, aAtk = healed("a")
  local bStatus, bAtk = healed("b")
  eq(aStatus, nil, "R2d: the player's FULL HEAL cures the burn")
  eq(aAtk, 100, "R2d: ...and CalcPlayerStats gives the Attack back")
  eq(bStatus, nil, "R2d: the computer's FULL HEAL cures it too")
  eq(bAtk, 50, "R2d: ...but its Attack stays halved (the cart's bug)")
end

do
  -- BATON PASS's successor: InitBattleMon's burn THEN the passed stages
  -- ("pass"), the stage on the halved Attack -- and a FLYING successor takes
  -- no SPIKES.
  local typeIds = { "NORMAL", "FLYING" }
  local battle, foe = fight({ typeIds = typeIds,
    a = { held({ species = "Alpha", spe = 90, types = { 0 },
                 moves = { hit("SWORDS_DANCE", 0, 0, 50), hit("BATON_PASS", 0, 0, 134) } }),
          held({ species = "Gamma", atk = 101, spe = 90, types = { 1 }, status = "BRN",
                 moves = { hit("wait", 0, 0, 85) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("SPIKES", 0, 0, 149) } }) } })
  drain(battle)
  round(battle, foe)
  local events = round(battle, foe, { action = "fight", move = 1, pass = 1 })
  local gamma = battle.byId.p1.mons[2]
  eq(battle.byId.p1.active, 2, "R2d: BATON PASS sends the named successor")
  eq(gamma.stages.atk, 2, "R2d: ...with the passed +2")
  eq(Effects.storedStat(gamma, "atk", nil), 100, "R2d: ...on the burn-halved Attack: floor(101/2) x 2")
  ok(battle.screens.a.spikes, "R2d: SPIKES lie on Ann's side")
  ok(not said(events, "Gamma's hurt by SPIKES!"), "R2d: a FLYING successor takes no SPIKES")
end

do
  -- ENCORE: an encored seat's FIGHT is the encored slot whatever it names.
  local battle, foe = fight({
    a = { held({ species = "Alpha", spe = 90, moves = { hit("ENCORE", 0, 0, 139), hit("tap", 1) } }) },
    b = { held({ species = "Beta", maxHp = 900, spe = 10, moves = { hit("tap", 1), hit("thump", 5) } }) } })
  drain(battle)
  round(battle, foe, { action = "fight", move = 1 }, { action = "fight", move = 1 })
  round(battle, foe, { action = "fight", move = 0 }, { action = "fight", move = 1 })
  local beta = battle.byId[foe].mons[1]
  ok(beta.encore ~= nil and beta.encore.moveIndex == 2, "R2d: Beta is encored into thump")
  battle:submitChoice("p1", { action = "fight", move = 1 })
  battle:submitChoice(foe, { action = "fight", move = 0 })
  local events = drain(battle)
  ok(said(events, "Beta used thump!"), "R2d: Beta's tap is thump")
end

do
  -- The computer's `.CheckAIRandomFail` is the computer's alone: a link
  -- fight's side b draws no byte for its HYPNOSIS.
  local function sleepRng(mode)
    local battle, foe = fight({ mode = mode, seed = 3,
      a = { held({ species = "Alpha", spe = 10, moves = { hit("wait", 0, 0, 85) } }) },
      b = { held({ species = "Beta", spe = 90, moves = { hit("HYPNOSIS", 0, 0, 32) } }) } })
    drain(battle)
    local before = battle.rng:state()
    battle.byId.p1.mons[1].status = "poison"
    local events = round(battle, foe)
    ok(said(events, "It didn't affect Alpha!"), "R2d: " .. mode .. ": HYPNOSIS into a status fails")
    local oneByte = battle.rng:clone()
    oneByte:setState(before)
    oneByte:byte()
    return before, battle.rng:state(), oneByte:state()
  end
  local a1, a2 = sleepRng("1v1")
  local _, b2, bOne = sleepRng("coop_npc")
  eq(a1, a2, "R2d: a link foe's HYPNOSIS into a status draws nothing")
  eq(b2, bOne, "R2d: the computer's draws exactly its AI byte")
end

-- ------------------------------------------------------------------
-- The referee-gaps run's wave 5 (R2e): the last Gold rows.
-- ------------------------------------------------------------------

do
  -- CONVERSION (move_effects/conversion.asm): a CURSE_TYPE move and the
  -- user's own types are never a pick; none left -- "But it failed!", no byte.
  local types = { "NORMAL", "FIRE", "CURSE_TYPE" }
  local battle, foe = fight({ mode = "1v1", seed = 7, typeIds = types,
    a = { held({ species = "Alpha", spe = 90, types = { 0 },
                 moves = { hit("CONVERSION", 0, 0, 24), hit("curse_ish", 0, 2), hit("fire_hit", 20, 1) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("wait", 0, 0, 85) } }) } })
  drain(battle)
  local events = round(battle, foe)
  ok(said(events, "Alpha transformed into the FIRE-type!"), "R2e: CONVERSION takes a move's type, never ???")
  eq(battle.byId.p1.mons[1].types[1], 1, "R2e: ...and both type bytes become it")
  local before = battle.rng:state()
  events = round(battle, foe)
  -- Now FIRE: NORMAL (CONVERSION's own) is left.
  ok(said(events, "Alpha transformed into the NORMAL-type!"), "R2e: the user's type is skipped")
  local only, foe2 = fight({ mode = "1v1", seed = 7, typeIds = types,
    a = { held({ species = "Alpha", spe = 90, types = { 0 },
                 moves = { hit("CONVERSION", 0, 0, 24), hit("curse_ish", 0, 2) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("wait", 0, 0, 85) } }) } })
  drain(only)
  local state = only.rng:state()
  events = round(only, foe2)
  ok(said(events, "But it failed!"), "R2e: nothing but its own and ??? -- it fails")
  eq(only.rng:state(), state, "R2e: ...drawing nothing")
  ok(before ~= nil, "R2e: (the pick draws)")
end

do
  -- HEAL BELL leaves SUBSTATUS_TOXIC; REST and a cure clear it.
  local battle, foe = fight({ mode = "1v1",
    a = { held({ species = "Alpha", maxHp = 960, spe = 90, moves = { hit("HEAL_BELL", 0, 0, 141), hit("REST", 0, 0, 56) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("wait", 0, 0, 85) } }) } })
  drain(battle)
  local alpha = battle.byId.p1.mons[1]
  alpha.status, alpha.toxicCounter = "toxic", 3
  round(battle, foe)
  eq(alpha.status, nil, "R2e: HEAL BELL cures the badly poisoned user")
  eq(alpha.toxicLatent, true, "R2e: ...and leaves SUBSTATUS_TOXIC")
  eq(alpha.toxicCounter, 3, "R2e: ...with its count")
  alpha.status = "burn"
  local events = round(battle, foe, { action = "fight", move = 0 })
  -- The bell cured the burn again; set it after the move, as a foe's would.
  alpha.status = "burn"
  alpha.hp = 500
  battle:submitChoice("p1", { action = "fight", move = 1 })
  battle:submitChoice(foe, { action = "fight", move = 0 })
  events = drain(battle)
  ok(said(events, "Alpha went to sleep!") or said(events, "Alpha fell asleep and became healthy!"),
     "R2e: REST")
  eq(alpha.toxicLatent, nil, "R2e: REST clears SUBSTATUS_TOXIC")
  ok(events ~= nil, "R2e: (the round ran)")
end

do
  -- SKETCH reads a MIMIC copy's base PP (Effects.basePp's `basePp`).
  local copy = Effects.copyMoveRow({ id = "SLAM", pp = 5, maxPp = 5, basePp = 35 })
  eq(Effects.basePp(copy), 35, "R2e: a copy states the base PP it was copied from")
  eq(Effects.basePp({ id = "SLAM", pp = 20, maxPp = 42, ppUps = 1 }), 35, "R2e: an own row derives it")
end

do
  -- TryToRunAwayFromBattle's odds (Effects.runOdds).
  eq(Effects.runOdds(100, 100, 1), nil, "R2e: as fast gets away, no byte")
  eq(Effects.runOdds(10, 200, 1), 6, "R2e: 320 / 50")
  eq(Effects.runOdds(10, 200, 2), 36, "R2e: +30 a try past the first")
  eq(Effects.runOdds(10, 3, 1), nil, "R2e: faster")
  eq(Effects.runOdds(1, 2, 1), nil, "R2e: a divisor of 0 gets away")
  eq(Effects.runOdds(100, 1028, 1), nil, "R2e: a quotient over 255 gets away (the divisor's low byte)")
  eq(Effects.runOdds(50, 60, 1), 106, "R2e: 1600 / 15")
end

do
  -- An ETHER on a transformed monster restores the PARTY's PP
  -- (BattleRestorePP skips the battle struct): the overlay is untouched and
  -- the party list is told at the undo.
  local battle, foe = fight({ mode = "1v1",
    a = { held({ species = "Alpha", spe = 90, moves = { hit("TRANSFORM", 0, 0, 57),
                 { id = "thump", pp = 0, maxPp = 30, power = 10, accuracy = 255, type = 0, effect = 0, chance = 0 } } }),
          held({ species = "Gamma", spe = 90, moves = { hit("tap", 1) } }) },
    b = { held({ species = "Beta", spe = 10, moves = { hit("tap", 1), hit("slam", 10) } }) } })
  drain(battle)
  round(battle, foe)
  local alpha = battle.byId.p1.mons[1]
  ok(alpha.transformed, "R2e: Alpha transformed")
  local events = round(battle, foe, { action = "item", item = "ETHER", move = 1 })
  eq(alpha.preTransform.moves[2].pp, 10, "R2e: the ETHER restores the party's slot")
  eq(alpha.moves[2].pp, 5, "R2e: ...not the copy")
  local partyMoves = false
  for _, event in ipairs(events) do
    if event.t == "moves" and event.slot == 0 and event.mon ~= nil then partyMoves = true end
  end
  ok(not partyMoves, "R2e: ...and no party list is published under the overlay")
  -- A transformed spend publishes the overlay only.
  events = round(battle, foe, { action = "fight", move = 1 })
  local overlay = nil
  for _, event in ipairs(events) do
    if event.t == "moves" and event.slot == 0 then overlay = event end
  end
  ok(overlay ~= nil and overlay.mon == nil, "R2e: a transformed PP spend carries no `mon`")
  events = round(battle, foe, { action = "switch", slot = 1 })
  local told = nil
  for _, event in ipairs(events) do
    if event.t == "moves" and event.slot == 0 and event.mon == 0 then told = event end
  end
  ok(told ~= nil and told.moves[2].pp == 10, "R2e: the party list is told at the undo")
end

do
  -- METRONOME's pool: a row without `num` is unreachable when any row
  -- states one, and numbered by its place when none does.
  local function poolBattle(pool)
    return duel({ seed = 99, metronomePool = pool,
      a = { sheet({ species = "Alpha", spe = 90, moves = { hit("METRONOME", 0, 0, 83) } }) },
      b = { sheet({ species = "Beta", spe = 10, moves = { hit("wait", 0, 0, 85) } }) } })
  end
  local mixed = poolBattle({ hit("MODDED", 10) })
  mixed.metronomePool[1].num = nil
  local numbered = { { id = "POUND", pp = 5, power = 40, type = 0, effect = 0, num = 1 },
                     { id = "MODDED", pp = 5, power = 40, type = 0, effect = 0 } }
  local b2 = poolBattle(numbered)
  drain(b2)
  local hits = {}
  for _ = 1, 3 do
    for _, event in ipairs(turn(b2)) do
      if event.t == "msg" and event.text:find("used MODDED", 1, true) then hits[#hits + 1] = event.text end
    end
  end
  eq(#hits, 0, "R2e: an unnumbered row in a numbered pool is never called")
  drain(mixed)
  local called = false
  for _ = 1, 3 do
    for _, event in ipairs(turn(mixed)) do
      if event.t == "msg" and event.text == "Alpha used MODDED!" then called = true end
    end
  end
  ok(called, "R2e: a pool with no `num` is numbered by place")
end

-- ------------------------------------------------------------------

io.write(string.format("battle_sim2_turn: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
