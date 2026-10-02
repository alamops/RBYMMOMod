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
-- exactly the drift these suites exist to catch.

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
-- trapping moves: the counter is a total attack count, and the answer the
-- referee files for a locked seat is not the player's to take back
-- ------------------------------------------------------------------

-- Gen1's 2..5 roll counts the hit that applied the trap, so the turn it lands
-- on deals the move's damage and no residual on top of it.  Counting it the
-- other way made a 2-turn Wrap hit three times.
do
  local battle = battleOf({ seed = 9999, sides = {
    a = { { playerId = "p1", name = "One", mons = {
      mon({ species = "Alpha", maxHp = 999, spe = 120,
            moves = { move({ id = "wrap", power = 5, effect = 42 }) } }) } } },
    b = { { playerId = "p2", name = "Two", mons = {
      mon({ species = "Beta", maxHp = 999, def = 200, spe = 1,
            moves = { move({ id = "tap", power = 0 }) } }) } } },
  } })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })

  local landingResidual = false
  for _, event in ipairs(drain(battle)) do
    if event.t == "msg" and event.text:find("hurt by the trap", 1, true) then
      landingResidual = true
    end
  end
  ok(not landingResidual, "the turn the trap lands on deals no residual on top of the hit")

  local beta = battle.byId["p2"]
  local afterHit = beta.mons[beta.active].hp
  ok(afterHit < 999, "the trapping move itself damages the victim")

  -- The turn after is forced on both seats, so it waits for a tick.
  battle:tick(battle.now + 1)
  local residual = false
  for _, event in ipairs(drain(battle)) do
    if event.t == "msg" and event.text:find("hurt by the trap", 1, true) then
      residual = true
    end
  end
  ok(residual, "the turns that follow each deal one residual")
  ok(beta.mons[beta.active].hp < afterHit, "trap residual reduces trapped mon HP")
end

-- A trap forces *both* seats, so `_openTurn` leaves that turn without a
-- deadline: a cancel that cleared one of those answers would hang the fight
-- with nothing left to time it out.
do
  local battle = battleOf({ seed = 9999, sides = {
    a = { { playerId = "p1", name = "One", mons = {
      mon({ species = "Alpha", maxHp = 999, spe = 120,
            moves = { move({ id = "wrap", power = 5, effect = 42 }) } }) } } },
    b = { { playerId = "p2", name = "Two", mons = {
      mon({ species = "Beta", maxHp = 999, def = 200, spe = 1,
            moves = { move({ id = "tap", power = 0 }) } }),
      mon({ species = "Delta", maxHp = 999, spe = 1,
            moves = { move({ id = "tap", power = 0 }) } }) } } },
  } })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)

  eq(battle.deadline, nil, "a turn forced on every seat opens without a deadline")
  ok(battle.byId["p2"].forced, "the trapped seat is marked as answered by the referee")
  ok(battle:submitChoice("p2", { action = "cancel" }) == false,
     "cancel cannot clear a forced trap answer")
  ok(battle:submitChoice("p2", { action = "switch", slot = 1 }) == false,
     "and the victim still cannot switch out of the trap")
  ok(battle.byId["p2"].choice ~= nil, "the forced answer survived the cancel")

  -- The refusal is what keeps the clock alive: the chain still runs to its end.
  local freed = false
  for _ = 1, 40 do
    if battle:outcome() then break end
    if battle:submitChoice("p2", { action = "fight", move = 0 }) then freed = true; break end
    if not battle:tick(battle.now + 1) then break end
    drain(battle)
  end
  ok(freed, "the trap chain still ends after a refused cancel")
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

  ok(spoke("Alpha used SLOW SWIPE"), "gen2: an attack prints the display name")
  ok(spoke("THUMP HIT was disabled"), "gen2: Disable landing names the move")
  ok(spoke("THUMP HIT is disabled"), "gen2: and so does the refusal it causes")
  ok(spoke("THUMP HIT is no longer disabled"), "gen2: and so does it wearing off")
  ok(spoke("Alpha learned THUMP HIT"), "gen2: Mimic names what it copied")
  ok(spoke("Alpha used THUMP HIT"), "gen2: and the copy keeps the name")
  ok(spoke("Beta used nudge"), "gen2: a move with no name is narrated under its id")

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
  eq(Effects.idOf("EFFECT_SOLARBEAM"), 39, "gen2: EFFECT_SOLARBEAM maps onto CHARGE")
  eq(Effects.idOf("EFFECT_SKULL_BASH"), 39, "gen2: EFFECT_SKULL_BASH maps onto CHARGE")
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
  eq(Effects.idOf("EFFECT_PROTECT"), nil, "gen2: Protect stays unmapped (no handler)")
  ok(Effects.hitsInvulnerable("FLY", { id = "GUST" }), "gen2: Gust reaches Fly")
  ok(Effects.hitsInvulnerable("FLY", { id = "TWISTER" }), "gen2: Twister reaches Fly")
  ok(Effects.hitsInvulnerable("FLY", { id = "WHIRLWIND" }), "gen2: Whirlwind reaches Fly")
  ok(Effects.hitsInvulnerable("DIG", { id = "EARTHQUAKE" }), "gen2: Earthquake reaches Dig")
  ok(Effects.hitsInvulnerable("DIG", { id = "FISSURE" }), "gen2: Fissure reaches Dig")
  ok(Effects.hitsInvulnerable("DIG", { id = "MAGNITUDE" }), "gen2: Magnitude reaches Dig")
  ok(not Effects.hitsInvulnerable("FLY", { id = "SWIFT" }), "gen2: Swift misses Fly")
  ok(not Effects.hitsInvulnerable("DIG", { id = "TACKLE" }), "gen2: Tackle misses Dig")
  local mon = { species = "Alpha" }
  eq(Effects.chargeMessage(mon, 39, "SOLARBEAM"), "Alpha took in sunlight")
  eq(Effects.chargeMessage(mon, 39, "SKULL_BASH"), "Alpha lowered its head")
  eq(Effects.chargeMessage(mon, 39, "RAZOR_WIND"), "Alpha made a whirlwind")
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
    if event.t == "msg" and event.text:find("But it failed", 1, true) then failed = true end
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
    if event.t == "msg" and event.text:find("But it failed", 1, true) then failed = true end
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
  eq(out.nothing, true, "gen2: SLEEP_EFFECT vs substitute is nothing")
  eq(target.status, nil, "gen2: SLEEP_EFFECT does not land through a substitute")
end

do
  local target = dummyMon({ species = "Beta", substitute = 40 })
  local out = applyPrimary(18, dummyMon(), target)
  eq(out.nothing, true, "gen2: Growl vs substitute is nothing")
  eq(target.stages.atk, 0, "gen2: Growl does not drop atk behind a substitute")
end

do
  local target = dummyMon({ species = "Beta", substitute = 40, lastMoveIndex = 1 })
  eq(applyPrimary(86, dummyMon(), target).nothing, true,
     "gen2: DISABLE_EFFECT vs substitute is nothing")
end

do
  local user = dummyMon()
  eq(applyPrimary(57, user, dummyMon({ species = "Beta", substitute = 40 })).nothing,
     true, "gen2: TRANSFORM_EFFECT vs substitute is nothing")
  eq(user.transformed, nil, "gen2: TRANSFORM_EFFECT does not copy through a substitute")
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
            moves = { move({ id = "leer", power = 0, accuracy = 0,
                             effect = leer }) },
          }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({
            species = "Gamma", maxHp = 200, spe = 80,
            moves = { move({ id = "hypno", power = 0, accuracy = 0,
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
    if event.t == "msg" and event.text == "But nothing happened" then
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
  -- the ruleset (typeIds, specialTypes).
  local function exchange(mode, a, b, rules)
    rules = rules or {}
    local battle, err = Turn.create({
      id = "b1", mode = mode, seed = a.seed or 777001,
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
    eq(hitOn(exchange(mode, {}, { power = 30 }), 0), 11,
       mode .. ": Bob's 30-power hit on an unbadged Ann is 11")
    eq(hitOn(exchange(mode, { badges = { MINERAL = true } }, { power = 30 }), 0), 9,
       mode .. ": MINERAL (Defense 40 -> 45) cuts it to 9")
    eq(hitOn(exchange(mode, { type = 2, spa = 88 }, {}, RULES), 3), 23,
       mode .. ": Ann's Special hit, unbadged, is 23")
    eq(hitOn(exchange(mode, { type = 2, spa = 88, badges = { GLACIER = true } }, {}, RULES), 3), 25,
       mode .. ": GLACIER (Sp. Atk 88 -> 99) raises it to 25")

    -- Glacier's Sp. Def tail, both ways: Bob's Special hit on Ann.  Sp. Atk
    -- 227 boosts to 255, which the tail reads as odd (Sp. Def boosted); 200
    -- boosts to 225, even, and Sp. Def stays as it was.
    local special = { power = 30, type = 2, spa = 60 }
    eq(hitOn(exchange(mode, { spa = 227 }, special, RULES), 0), 10,
       mode .. ": Bob's Special hit on an unbadged Ann is 10")
    eq(hitOn(exchange(mode, { spa = 227, badges = { GLACIER = true } }, special, RULES), 0), 9,
       mode .. ": GLACIER with Sp. Atk 227 (-> 255) boosts Sp. Def too: 9")
    eq(hitOn(exchange(mode, { spa = 200, badges = { GLACIER = true } }, special, RULES), 0), 10,
       mode .. ": GLACIER with Sp. Atk 200 (-> 225) leaves Sp. Def alone: 10")

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
      if said(events, "A critical hit") then return damageOn(events, 3) end
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
  local battle = duel({
    specialTypes = { 1 },
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
  ok(said(again, "But it failed"), "a second Light Screen while one is up fails")
  eq(battle.screens.a.lightScreen, 3, "...and does not refresh the count")
  local fixed = turn(battle, { action = "fight", move = 1 }, { action = "fight", move = 1 })
  eq(damageOn(fixed, 0), 20, "a fixed-damage hit is never screened: the post-hoc halving is gone")
  turn(battle, { action = "fight", move = 1 })
  local fade = turn(battle, { action = "fight", move = 1 })
  ok(said(fade, "Ann's LIGHT SCREEN fell"), "it falls at the end of its fifth turn")
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
    if said(turn(battle), "Alpha hurt itself in confusion") then found = seed; break end
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
    return duel({
      chart = GHOST_CHART,
      a = { sheet({ species = "Alpha", spe = 90, types = { 0 },
                    moves = { hit("thump", 40, 0, 0, pp) } }) },
      b = { sheet({ species = "Beta", spe = 10, types = { 1 }, moves = { hit("tap", 0, 0, 85) } }) },
    })
  end
  local normal = vsGhost(10)
  drain(normal)
  ok(said(turn(normal), "It doesn't affect Beta"), "a NORMAL move cannot touch the GHOST on this chart")
  local struggle = vsGhost(0)
  drain(struggle)
  local events = turn(struggle)
  local dealt = damageOn(events, 3)
  -- 10 x 50 x 40 / 40 / 50 = 10, +2 = 12, no STAB though Alpha is type 0.
  ok(dealt and dealt >= 10 and dealt <= 12, "Struggle hits the GHOST anyway, with no STAB (10..12)")
  ok(not said(events, "It doesn't affect Beta"), "...and no matchup line at all")
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
  ok(not said(called, "Alpha is hit with recoil"), "...and the called move takes no Struggle recoil")
  local after = turn(metronome)
  ok(animOrder(after):find("STRUGGLE", 1, true) ~= nil, "the turn after, every slot is empty: Struggle")
  ok(said(after, "Alpha is hit with recoil"), "...which does recoil")

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

io.write(string.format("battle_sim2_turn: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
