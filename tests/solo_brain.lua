-- src/SoloBrain.lua: the bridge from the engine's real trainer AI to a
-- BattleSim choice, exercised with no engine BattleState anywhere.
--
-- Run: luajit tests/solo_brain.lua
--   or luajit mods/rby_mmo/tests/solo_brain.lua  (from the engine)
--
-- Standalone in the same spirit as tests/battle_sim_turn.lua: it loads the
-- shipped mod files through a from-scratch `need`-shaped resolver, the same
-- two-argument `chunk(need, mod)` convention main.lua's real loader uses
-- (SoloBrain.lua:73 reads `local need, mod = ...`).  What makes this suite
-- possible at all is that SoloBrain synthesises its own BattleState-shaped
-- view rather than touching a real one (see the module's own header,
-- "the adapter, and why it is a copy rather than a puppet") -- so a unit test
-- can hand it plain tables and never stand up love, a ROM, or a screen.
--
-- The engine's own AI modules (src/battle/TrainerAI.lua, TypeChart.lua,
-- src/battle/gen2/Ai.lua, Damage.lua) are pulled in by SoloBrain itself via
-- plain `require`, not through `need` -- so this suite only runs from a
-- checkout where those resolve, i.e. the engine root (or a view of it with
-- this mod symlinked in), never in total isolation.
--
-- Legal: every trainer id, move id, item id and type name below is invented
-- for this file (the "thump" / "FIX_*" convention every sibling suite
-- uses) -- no ROM-derived name appears anywhere here.

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

-- ------------------------------------------------------------------
-- the mod facade, stubbed
-- ------------------------------------------------------------------
--
-- Only `log` is ever touched by SoloBrain (`warnOnce`, guarded by pcall on
-- both sides).  Captured rather than dropped: a suite that only cares whether
-- something crashed would miss the module quietly giving up and answering
-- `nil` for the wrong reason.

local warnings = {}

local stubMod = {
  id = "rby_mmo",
  path = ROOT,
  log = {
    info = function() end,
    warn = function(_, message) warnings[#warnings + 1] = tostring(message) end,
    error = function(_, message) warnings[#warnings + 1] = tostring(message) end,
  },
}

local cache = {}
local function need(name)
  if cache[name] ~= nil then return cache[name] end
  local path = ROOT .. "/src/" .. name .. ".lua"
  local body = slurp(path)
  if not body then error("missing " .. path, 0) end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then error(tostring(err), 0) end
  cache[name] = chunk(need, stubMod)
  return cache[name]
end

local SoloBrain = need("SoloBrain")

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
-- fixtures
-- ------------------------------------------------------------------
--
-- One shared type-name space (PLAIN / AQUA / SCORCH, all invented) and one
-- shared `type_chart`.  Not a style choice: src/battle/TypeChart.lua keeps
-- its loaded matchup table in a *module-level* upvalue behind `require`, so
-- the very first Gen 1 brain in this whole process to call `_ensureTypeChart`
-- decides the chart for every Gen 1 brain built afterwards -- TypeChart.load
-- is never called a second time once the module's own probe already
-- succeeds. A second, different `type_chart` table defined later in this
-- file would therefore be silently ignored. One canonical chart sidesteps
-- that trap instead of tripping over it.

local TYPE_NAMES = { "PLAIN", "AQUA", "SCORCH" } -- index 0, 1, 2
local PLAIN, AQUA, SCORCH = 0, 1, 2

local TYPE_CHART = {
  matchups = {
    { attacker = "AQUA", defender = "SCORCH", multiplier = 20 }, -- super effective
    { attacker = "SCORCH", defender = "AQUA", multiplier = 5 },
  },
}

-- A deterministic rng: always the low end of the range. Every scenario below
-- is built to have exactly one right answer under this rng, the same way
-- `battle_sim_turn.lua`'s fixtures pin ties rather than leaving them to
-- chance.
local function detRng(lo, hi)
  if hi == nil then lo, hi = 1, lo end
  if hi < lo then return lo end
  return lo
end

-- One shared dataset. `ai_classes` must always be a *table* (even empty):
-- TrainerAI.classFor only falls back to `require("data.scripts.ai_classes")`
-- -- real ROM-extracted data this suite must never touch -- when
-- `battle.data.ai_classes` itself is absent, not when the id inside it is
-- missing.
local DATA = {
  moves = {
    soak = { type = "AQUA", power = 40, effect = "NONE" },
    bonk = { type = "PLAIN", power = 40, effect = "NONE" },
  },
  type_chart = TYPE_CHART,
  ai_classes = {},
}

local function mkMon1(o)
  o = o or {}
  return {
    species = o.species or "fixmon",
    level = o.level or 50,
    hp = o.hp ~= nil and o.hp or 100,
    maxHp = o.maxHp or 100,
    status = o.status,
    moves = o.moves or {},
    stats = o.stats or { atk = 50, def = 50, spd = 50, spc = 50 },
    types = o.types or {},
    disable = o.disable,
    stages = o.stages,
    slot = o.slot or 1,
  }
end

local function mkMon2(o)
  o = o or {}
  return {
    species = o.species or "fixmon2",
    level = o.level or 50,
    hp = o.hp ~= nil and o.hp or 100,
    maxHp = o.maxHp or 100,
    status = o.status,
    moves = o.moves or {},
    stats = o.stats or { atk = 50, def = 50, spa = 50, spd = 50, spe = 50 },
    types = o.types or {},
    disable = o.disable,
    stages = o.stages,
    slot = o.slot or 1,
  }
end

-- ------------------------------------------------------------------
-- 1. layer scoring prefers the super-effective move, both generations
-- ------------------------------------------------------------------
--
-- Gen 1 reads LAYER_3 straight off src/battle/TrainerAI.lua; Gen 2 reads the
-- TYPES layer off the *other* engine module, src/battle/gen2/Ai.lua, driven
-- entirely by the trainer class's AI word (TRNATTR_AI_MOVE_WEIGHTS). Same
-- claim, two unrelated implementations, so it is worth pinning on both.

do
  local trainer1 = { id = "FIX_TRAINER_LAYER1" }
  local mon = mkMon1{
    moves = { { id = "soak", pp = 10 }, { id = "bonk", pp = 10 } },
  }
  local foe = mkMon1{ types = { SCORCH } }

  local brain, reason = SoloBrain.new{
    data = DATA, trainer = trainer1, generation = 1, aiMods = { "LAYER_3" },
    rng = detRng, typeName = TYPE_NAMES,
  }
  ok(brain ~= nil, "Gen 1 brain builds against a trainer with a real class: " .. tostring(reason))

  local choice = brain:choose{ mon = mon, foe = foe, party = { mon } }
  ok(choice ~= nil, "Gen 1 layer scoring answers")
  eq(choice and choice.action, "fight", "Gen 1 layer scoring picks a move")
  -- the index vocabulary trap (item 5): submitChoice's `move` is zero-based,
  -- and slot 1 ("soak") is the super-effective one, so this must read 0 --
  -- not 1, which is what `fighter.choice` would have held instead.
  eq(choice and choice.move, 0, "Gen 1: soak (slot 1, zero-based 0) is chosen over neutral bonk")
end

do
  local trainer2 = {
    id = "FIX_TRAINER_LAYER2",
    -- byte 4 of TrainerClassAttributes is the low half of the AI word;
    -- Ai.FLAGS.TYPES = 0x0004 turns on only the type-effectiveness layer.
    attributes = { 0, 0, 0, 0x04, 0, 0, 0, 0 },
  }
  local mon = mkMon2{
    stats = { atk = 50, def = 50, spa = 50, spd = 50, spe = 50 },
    moves = { { id = "soak", pp = 10 }, { id = "bonk", pp = 10 } },
    types = { PLAIN },
  }
  local foe = mkMon2{ types = { SCORCH } }

  local brain, reason = SoloBrain.new{
    data = DATA, trainer = trainer2, generation = 2,
    rng = detRng, typeName = TYPE_NAMES,
  }
  ok(brain ~= nil, "Gen 2 brain builds against a trainer with an AI word: " .. tostring(reason))

  local choice = brain:choose{ mon = mon, foe = foe }
  ok(choice ~= nil, "Gen 2 layer scoring answers")
  eq(choice and choice.action, "fight", "Gen 2 layer scoring picks a move")
  eq(choice and choice.move, 0, "Gen 2: soak is chosen over neutral bonk too")
end

-- ------------------------------------------------------------------
-- 2. ai_classes "class" records: item budget, switch / switchChance / switchBelow
-- ------------------------------------------------------------------

-- 2a. an item-only class fires every turn it can, and stops dead exactly
-- `uses` turns later -- never a turn early, never a turn late.
do
  DATA.ai_classes.FIX_TRAINER_BUDGET = {
    kind = "class", chance = 256, item = "FIX_ITEM_BUDGET", uses = 2,
  }
  local trainer = { id = "FIX_TRAINER_BUDGET" }
  local mon = mkMon1{ moves = { { id = "bonk", pp = 10 } } }
  local foe = mkMon1{}
  local view = { mon = mon, foe = foe, party = { mon }, bag = { FIX_ITEM_BUDGET = 9 } }

  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
    rng = detRng, typeName = TYPE_NAMES }

  local c1 = brain:choose(view)
  eq(c1 and c1.action, "item", "budget: use #1 is the item")
  eq(c1 and c1.item, "FIX_ITEM_BUDGET", "budget: the class's own item id")

  local c2 = brain:choose(view)
  eq(c2 and c2.action, "item", "budget: use #2 is still the item (uses = 2)")

  local c3 = brain:choose(view)
  eq(c3 and c3.action, "fight", "budget: use #3 is a move -- the budget is exhausted")
  eq(brain.aiUses, 0, "budget: the counter reads exactly zero after the record's uses")
end

-- 2b. switchChance fires unconditionally (it is rolled before the item
-- branch even runs) and rotates to the lowest-indexed living bench mon.
do
  DATA.ai_classes.FIX_TRAINER_SWITCHCHANCE = { switchChance = 256, uses = 1 }
  local trainer = { id = "FIX_TRAINER_SWITCHCHANCE" }
  local active = mkMon1{ slot = 1, hp = 50 }
  local bench = mkMon1{ slot = 7, hp = 30 }
  local foe = mkMon1{}

  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
    rng = detRng, typeName = TYPE_NAMES }
  local choice = brain:choose{ mon = active, foe = foe, party = { active, bench }, bag = {} }
  eq(choice and choice.action, "switch", "switchChance always rotates when it triggers")
  eq(choice and choice.slot, 7, "switch names the bench mon's own slot, not a party index")
end

-- 2c. hpBelow / switchBelow: heal when badly hurt, rotate when moderately
-- hurt, do nothing (fall through to a move) at full health. Three fresh
-- brains, one per HP band, so budgets never bleed across scenarios.
do
  DATA.ai_classes.FIX_TRAINER_HPGATE = {
    hpBelow = 4, switchBelow = 2, item = "FIX_ITEM_HPGATE", uses = 1,
  }
  local trainer = { id = "FIX_TRAINER_HPGATE" }
  local foe = mkMon1{}

  -- badly hurt (< maxHp/4): the item.
  do
    local mon = mkMon1{ hp = 10, maxHp = 100, moves = { { id = "bonk", pp = 10 } } }
    local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
      rng = detRng, typeName = TYPE_NAMES }
    local choice = brain:choose{ mon = mon, foe = foe, party = { mon },
      bag = { FIX_ITEM_HPGATE = 1 } }
    eq(choice and choice.action, "item", "hpBelow: low HP reaches for the item")
  end

  -- moderately hurt (maxHp/4 <= hp < maxHp/2): rotate instead.
  do
    local mon = mkMon1{ hp = 30, maxHp = 100, slot = 1 }
    local bench = mkMon1{ hp = 40, maxHp = 100, slot = 9 }
    local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
      rng = detRng, typeName = TYPE_NAMES }
    local choice = brain:choose{ mon = mon, foe = foe, party = { mon, bench }, bag = {} }
    eq(choice and choice.action, "switch", "switchBelow: moderate HP rotates")
    eq(choice and choice.slot, 9, "...to the bench mon's own slot")
  end

  -- healthy (>= maxHp/2): the class declines outright, and the budget it
  -- never spent falls through to a move.
  do
    local mon = mkMon1{ hp = 80, maxHp = 100, moves = { { id = "bonk", pp = 10 } } }
    local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
      rng = detRng, typeName = TYPE_NAMES }
    local choice = brain:choose{ mon = mon, foe = foe, party = { mon }, bag = {} }
    eq(choice and choice.action, "fight", "hpBelow: full health does nothing special, so a move is played")
  end
end

-- ------------------------------------------------------------------
-- 3. a `brain` record supersedes everything -- layer, class and budget alike
-- ------------------------------------------------------------------

do
  -- The class would always fire the item (chance = 256), and LAYER_3 would
  -- always prefer the super-effective "soak" -- neither gets a say once the
  -- trainer carries a `brain` function.
  DATA.ai_classes.FIX_TRAINER_BRAINSUP = {
    chance = 256, item = "FIX_ITEM_NEVERUSED", uses = 5,
  }
  local trainer = {
    id = "FIX_TRAINER_BRAINSUP",
    brain = function(battle) return battle.enemy.curMoves[2] end, -- always "bonk"
  }
  local mon = mkMon1{
    moves = { { id = "soak", pp = 10 }, { id = "bonk", pp = 10 } },
  }
  local foe = mkMon1{ types = { SCORCH } }

  local brain = SoloBrain.new{
    data = DATA, trainer = trainer, generation = 1, aiMods = { "LAYER_3" },
    rng = detRng, typeName = TYPE_NAMES,
  }
  local choice = brain:choose{ mon = mon, foe = foe, party = { mon }, bag = {} }
  eq(choice and choice.action, "fight", "a brain's own move choice wins")
  eq(choice and choice.move, 1,
    "...specifically bonk (slot 2, zero-based 1), not the layer's super-effective pick")
end

do
  -- A brain that answers with an item still spends the aiUses budget, same
  -- as the class path -- the module's own comment on this: "if it answered
  -- with an item or a switch, that is a use".
  DATA.ai_classes.FIX_TRAINER_BRAINITEM = { uses = 3 }
  local trainer = {
    id = "FIX_TRAINER_BRAINITEM",
    brain = function(_) return { special = "aiItem", item = "FIX_ITEM_BRAIN" } end,
  }
  local mon = mkMon1{ moves = { { id = "bonk", pp = 10 } } }
  local foe = mkMon1{}

  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
    rng = detRng, typeName = TYPE_NAMES }
  -- aiUses is seeded lazily, on the first `choose` (the send-out rollover),
  -- not by `new` -- so the budget is 0 until the first call, and what proves
  -- the class's `uses = 3` really seeded it is the arithmetic after that
  -- call: 3 minus the one use this item answer spends.
  local choice = brain:choose{ mon = mon, foe = foe, party = { mon } }
  eq(choice and choice.action, "item", "the brain's item answer is honoured")
  eq(choice and choice.item, "FIX_ITEM_BRAIN", "...with the brain's own item id")
  eq(brain.aiUses, 2, "...and it cost the brain one use, seeded from the class's uses = 3")
end

-- ------------------------------------------------------------------
-- 4. the nil contract: a decline, never an error
-- ------------------------------------------------------------------

do
  local noBrain, reason = SoloBrain.new{ data = DATA }
  eq(noBrain, nil, "no trainer record at all -- a wild fight -- refuses to build")
  ok(type(reason) == "string" and reason:find("trainer") ~= nil,
    "...and names the reason rather than raising: " .. tostring(reason))
end

do
  local noData, reason = SoloBrain.new{ trainer = { id = "x" } }
  eq(noData, nil, "no dataset to read moves from also refuses to build")
  ok(type(reason) == "string" and reason:find("dataset") ~= nil,
    "...and says so: " .. tostring(reason))
end

do
  local trainer = { id = "FIX_TRAINER_NILCONTRACT" }
  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
    rng = detRng, typeName = TYPE_NAMES }
  local mon = mkMon1{ moves = { { id = "bonk", pp = 10 } } }

  eq(brain:choose(nil), nil, "choose(nil) declines rather than throwing")
  eq(brain:choose{}, nil, "choose({}) with no mon declines")
  eq(brain:choose{ mon = mon }, nil,
    "choose with no foe and no mustReplace declines -- there is nothing to score against")
end

-- ------------------------------------------------------------------
-- 5. bag honesty: an item the trainer's bag does not hold is declined, and
--    the decline costs nothing off the AI's own budget
-- ------------------------------------------------------------------

do
  DATA.ai_classes.FIX_TRAINER_BAGHONESTY = {
    chance = 256, item = "FIX_ITEM_NOTINBAG", uses = 1,
  }
  local trainer = { id = "FIX_TRAINER_BAGHONESTY" }
  local mon = mkMon1{ moves = { { id = "bonk", pp = 10 } } }
  local foe = mkMon1{}
  local view = { mon = mon, foe = foe, party = { mon }, bag = {} } -- empty bag

  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
    rng = detRng, typeName = TYPE_NAMES }

  local c1 = brain:choose(view)
  eq(c1 and c1.action, "fight", "an item not on the bag sheet is declined, falling to a move")
  eq(brain.aiUses, 1, "...and the decline spent none of the budget")

  local c2 = brain:choose(view)
  eq(c2 and c2.action, "fight", "it declines again next turn, not just once")
  eq(brain.aiUses, 1, "...the budget is still untouched")
end

-- ------------------------------------------------------------------
-- 6. forced replacement: mustReplace yields a switch to a living bench mon
-- ------------------------------------------------------------------

do
  local trainer = { id = "FIX_TRAINER_REPLACE" }
  local fainted = mkMon1{ slot = 1, hp = 0 }
  local alsoFainted = mkMon1{ slot = 4, hp = 0 }
  local alive = mkMon1{ slot = 8, hp = 20 }

  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
    rng = detRng, typeName = TYPE_NAMES }
  -- no `foe` at all: a forced send-out never scores against the far side.
  local choice = brain:choose{
    mon = fainted, mustReplace = true, party = { fainted, alsoFainted, alive },
  }
  eq(choice and choice.action, "switch", "a forced replacement switches")
  eq(choice and choice.slot, 8, "...to the lowest-indexed living bench mon's own slot")

  local wipedOut = brain:choose{
    mon = fainted, mustReplace = true, party = { fainted, alsoFainted },
  }
  eq(wipedOut, nil, "with no living bench mon, there is nothing to answer -- nil, not an error")
end

do
  -- the same forced-replacement path, off a Gen 2 brain: `_decide` handles
  -- mustReplace before it ever branches on generation, so this is one code
  -- path serving both.
  local trainer = { id = "FIX_TRAINER_REPLACE2", attributes = { 0, 0, 0, 0, 0 } }
  local fainted = mkMon2{ slot = 2, hp = 0 }
  local alive = mkMon2{ slot = 5, hp = 15 }
  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 2,
    rng = detRng, typeName = TYPE_NAMES }
  local choice = brain:choose{ mon = fainted, mustReplace = true, party = { fainted, alive } }
  eq(choice and choice.action, "switch", "Gen 2 forced replacement switches too")
  eq(choice and choice.slot, 5, "...to the same living bench mon's own slot")
end

-- ------------------------------------------------------------------
-- 7. no engine mutation: Gen 2 items are spent off a private copy
-- ------------------------------------------------------------------
--
-- The real cart's AI_TryItem removes what it used from the trainer's item
-- list; SoloBrain's own header calls this out as a corruption it guards
-- against, because the registry's trainer record has to survive the battle
-- for the next player who fights this same trainer.
--
-- Gen 2's `Ai.chooseItem` -- unlike Gen 1's `ai_classes` item field, which
-- passes its string straight through unvalidated -- walks a fixed table of
-- real item ids (`Ai.ITEM_ORDER` / `Ai.HEAL_ITEMS`) baked into
-- src/battle/gen2/Ai.lua itself; a made-up id is simply never matched. So
-- this is the one spot in this suite that must use a real item id -- "POTION"
-- is the engine's own functional identifier here, not ROM-derived flavor,
-- the same way "STRUGGLE" is elsewhere in this bridge.
do
  local trainer = {
    id = "FIX_TRAINER_ITEMS2",
    items = { "POTION" },
    attributes = { 0, 0, 0, 0, 0 }, -- flags = 0: no scoring layers to score with
  }
  local mon = mkMon2{ hp = 10, maxHp = 100, moves = { { id = "bonk", pp = 10 } } }
  local foe = mkMon2{}
  local view = { mon = mon, foe = foe, bag = { POTION = 5 } }

  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 2,
    rng = detRng, typeName = TYPE_NAMES }

  local c1 = brain:choose(view)
  eq(c1 and c1.action, "item", "Gen 2: a hurt, highest-level mon reaches for its item")
  eq(c1 and c1.item, "POTION", "...the trainer's own item id")
  eq(#trainer.items, 1, "the registry's own item list is untouched in length")
  eq(trainer.items[1], "POTION", "...and in content -- this is the record every future fight reads")
  eq(#brain.items2, 0, "the brain's private copy is what actually got spent")

  local c2 = brain:choose(view)
  eq(c2 and c2.action, "fight", "with the private copy empty, the item is not offered again")
end

-- ------------------------------------------------------------------
-- 8. SoloBrain.trainerOf: both generations' shapes, and no others
-- ------------------------------------------------------------------

do
  local record = { id = "FIX_TRAINER_OF" }
  eq(SoloBrain.trainerOf{ trainer = record }, record, "Gen 1 shape: state.trainer directly")

  local record2 = { id = "FIX_TRAINER_OF_2" }
  eq(SoloBrain.trainerOf{ battle = { trainer = record2 } }, record2,
    "Gen 2 shape: the record on state.battle.trainer")

  eq(SoloBrain.trainerOf(nil), nil, "a nil state resolves to nil, not an error")
  eq(SoloBrain.trainerOf{}, nil, "a state with neither shape resolves to nil")
  -- Real BattleState.newTrainer always sets `.trainer` in the same breath as
  -- `.oppClass` (BattleState.lua:790-796) -- oppClass names *which* trainer,
  -- it is never itself where the resolved record lives. trainerOf reflects
  -- that: an id with no resolved record beside it answers nil rather than
  -- guessing.
  eq(SoloBrain.trainerOf{ oppClass = "FIX_OPP_SOMETHING" }, nil,
    "oppClass alone (no .trainer) is not a shape trainerOf resolves")
end

-- ------------------------------------------------------------------
-- 9. SoloBrain.itemsFor
-- ------------------------------------------------------------------

do
  DATA.ai_classes.FIX_TRAINER_ITEMSFOR = { item = "FIX_ITEM_FOR" }
  local trainer = { id = "FIX_TRAINER_ITEMSFOR" }
  local items = SoloBrain.itemsFor(trainer, DATA, 1)
  eq(#items, 1, "Gen 1 with no items list: only the class's own item")
  eq(items[1], "FIX_ITEM_FOR", "...by id")
end

do
  local trainer = { id = "FIX_TRAINER_ITEMSFOR2", items = { "FIX_ITEM_A", "FIX_ITEM_B" } }
  local items = SoloBrain.itemsFor(trainer, DATA, 2)
  eq(#items, 2, "Gen 2 carries the trainer's own item list through")
  eq(items[1], "FIX_ITEM_A", "...in order")
  eq(items[2], "FIX_ITEM_B", "...both of them")
end

-- ------------------------------------------------------------------
-- 10. disabled and empty-PP slots are never returned
-- ------------------------------------------------------------------

do
  local trainer = { id = "FIX_TRAINER_STRUGGLE" }
  local mon = mkMon1{ moves = { { id = "bonk", pp = 0 }, { id = "soak", pp = 0 } } }
  local foe = mkMon1{}
  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
    rng = detRng, typeName = TYPE_NAMES }
  local choice = brain:choose{ mon = mon, foe = foe, party = { mon } }
  -- every slot out of PP is the sim's own spelling of Struggle: any index is
  -- legal, and the referee's convention (mirrored in SoloBrain) is the first.
  eq(choice and choice.action, "fight", "an all-empty moveset still answers -- Struggle")
  eq(choice and choice.move, 0, "...as the sim's own Struggle convention, slot 0")
end

do
  local trainer = { id = "FIX_TRAINER_DISABLED" }
  local mon = mkMon1{
    moves = { { id = "bonk", pp = 10 }, { id = "soak", pp = 10 } },
    disable = { turns = 3, moveIndex = 1 },
  }
  local foe = mkMon1{}
  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
    rng = detRng, typeName = TYPE_NAMES }
  local choice = brain:choose{ mon = mon, foe = foe, party = { mon } }
  eq(choice and choice.action, "fight", "a disabled slot still leaves a legal move to answer with")
  eq(choice and choice.move, 1, "...the other slot, zero-based 1 -- never the disabled slot 0")
end

do
  local trainer = { id = "FIX_TRAINER_NOPP" }
  local mon = mkMon1{
    moves = { { id = "bonk", pp = 0 }, { id = "soak", pp = 10 } },
  }
  local foe = mkMon1{}
  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
    rng = detRng, typeName = TYPE_NAMES }
  local choice = brain:choose{ mon = mon, foe = foe, party = { mon } }
  eq(choice and choice.action, "fight", "a slot with no PP (but not every slot) still answers")
  eq(choice and choice.move, 1, "...the slot that still has PP, never the empty one")
end

-- ------------------------------------------------------------------
-- every scenario above is a legitimate decline or a legitimate answer --
-- none of them should have made the adapter's own pcall catch anything
-- ------------------------------------------------------------------

eq(#warnings, 0,
  "no adapter warning fired during any of the above -- every nil above was a clean decline: "
  .. table.concat(warnings, " | "))

-- ------------------------------------------------------------------

io.write(string.format("solo_brain: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
