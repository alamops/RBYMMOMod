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
-- 2. ai_classes "class" records: the referee's now, never this file's
-- ------------------------------------------------------------------
--
-- Contract K16 of docs/plans/gen12-referee-remaining-gaps.md: the Red and
-- Gold referees run the class's item and switch AI themselves, at the cart's
-- point in the turn (pokered TrainerAI's `Random` byte while wAICount lasts;
-- pokecrystal AI_SwitchOrTryItem), off the class data the NPC upload states.
-- So whatever the record would do -- an item every turn, a rotation, a heal
-- below an HP fraction -- this brain answers the move, and spends nothing.

-- 2a. an item-only class that would fire every turn: a move, every turn.
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

  for turn = 1, 3 do
    local c = brain:choose(view)
    eq(c and c.action, "fight", "K16 (Red): turn " .. turn .. " is a move -- the class item is the referee's")
  end
  eq(brain.aiUses, 2, "K16 (Red): wAICount is seeded off the record and never spent here")
end

-- 2b. switchChance would always rotate: still the move.
do
  DATA.ai_classes.FIX_TRAINER_SWITCHCHANCE = { switchChance = 256, uses = 1 }
  local trainer = { id = "FIX_TRAINER_SWITCHCHANCE" }
  local active = mkMon1{ slot = 1, hp = 50, moves = { { id = "bonk", pp = 10 } } }
  local bench = mkMon1{ slot = 7, hp = 30 }
  local foe = mkMon1{}

  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
    rng = detRng, typeName = TYPE_NAMES }
  local choice = brain:choose{ mon = active, foe = foe, party = { active, bench }, bag = {} }
  eq(choice and choice.action, "fight", "K16 (Red): Agatha's switch roll is the referee's -- a move here")
end

-- 2c. hpBelow / switchBelow at every HP band: the move.
do
  DATA.ai_classes.FIX_TRAINER_HPGATE = {
    hpBelow = 4, switchBelow = 2, item = "FIX_ITEM_HPGATE", uses = 1,
  }
  local trainer = { id = "FIX_TRAINER_HPGATE" }
  local foe = mkMon1{}
  for _, hp in ipairs({ 10, 30, 80 }) do
    local mon = mkMon1{ hp = hp, maxHp = 100, slot = 1, moves = { { id = "bonk", pp = 10 } } }
    local bench = mkMon1{ hp = 40, maxHp = 100, slot = 9 }
    local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
      rng = detRng, typeName = TYPE_NAMES }
    local choice = brain:choose{ mon = mon, foe = foe, party = { mon, bench },
      bag = { FIX_ITEM_HPGATE = 1 } }
    eq(choice and choice.action, "fight",
       "K16 (Red): at " .. hp .. "/100 HP the class's heal / rotation is the referee's -- a move here")
  end
end

-- ------------------------------------------------------------------
-- 3. a `brain` record supersedes the layers -- for the move
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
  -- A brain that answers with an item on Red is declined (K16): the item
  -- slot of the turn is the referee's TrainerAI, and nil hands the seat to
  -- `autoPick`.  Nothing is spent.
  DATA.ai_classes.FIX_TRAINER_BRAINITEM = { uses = 3 }
  local trainer = {
    id = "FIX_TRAINER_BRAINITEM",
    brain = function(_) return { special = "aiItem", item = "FIX_ITEM_BRAIN" } end,
  }
  local mon = mkMon1{ moves = { { id = "bonk", pp = 10 } } }
  local foe = mkMon1{}

  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
    rng = detRng, typeName = TYPE_NAMES }
  local choice = brain:choose{ mon = mon, foe = foe, party = { mon } }
  eq(choice, nil, "K16 (Red): a brain's item answer is declined -- the referee owns that slot")
  eq(brain.aiUses, 3, "...and spends none of the budget seeded from uses = 3")
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
-- 5. forced replacement: the referee's (K16), on Red and Gold
-- ------------------------------------------------------------------
--
-- pokered EnemySendOut's party order and pokecrystal
-- FindMonInOTPartyToSwitchIntoBattle are the referee's to run; this brain
-- answers nil and SoloBattle files `autoPick`, which reaches them.

do
  local trainer = { id = "FIX_TRAINER_REPLACE" }
  local fainted = mkMon1{ slot = 1, hp = 0 }
  local alive = mkMon1{ slot = 8, hp = 20 }
  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 1,
    rng = detRng, typeName = TYPE_NAMES }
  eq(brain:choose{ mon = fainted, mustReplace = true, party = { fainted, alive } }, nil,
     "K16 (Red): a forced replacement is the referee's -- nil, never a switch")
end

do
  local trainer = { id = "FIX_TRAINER_REPLACE2", attributes = { 0, 0, 0, 0, 0 } }
  local fainted = mkMon2{ slot = 2, hp = 0 }
  local alive = mkMon2{ slot = 5, hp = 15 }
  local brain = SoloBrain.new{ data = DATA, trainer = trainer, generation = 2,
    rng = detRng, typeName = TYPE_NAMES }
  eq(brain:choose{ mon = fainted, mustReplace = true, party = { fainted, alive } }, nil,
     "K16 (Gold): a forced replacement is the referee's too")
end

-- ------------------------------------------------------------------
-- 6. Gold: AI_TryItem is the referee's -- the move, and no engine mutation
-- ------------------------------------------------------------------
--
-- A hurt, highest-level monster whose trainer holds a POTION would drink it
-- on the cart (AI_TryItem); the Gold referee does that now from the class
-- attributes the NPC upload states (`trainerItems`).  This brain answers the
-- move and never touches the registry's own item list.  "POTION" is the
-- engine's own functional identifier here (src/battle/gen2/Ai.lua matches
-- real ids), not ROM-derived flavor.
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
  eq(c1 and c1.action, "fight", "K16 (Gold): a hurt monster's POTION is the referee's -- a move here")
  eq(#trainer.items, 1, "the registry's own item list is untouched in length")
  eq(trainer.items[1], "POTION", "...and in content -- this is the record every future fight reads")
  eq(brain.items2, nil, "K16 (Gold): no private item copy is kept -- nothing here spends one")
end

-- ------------------------------------------------------------------
-- 7. SoloBrain.classOf: one resolution of a trainer's class record
-- ------------------------------------------------------------------

do
  DATA.ai_classes.FIX_TRAINER_CLASSOF = { uses = 2, chance = 64, item = "FIX_ITEM_CLASSOF" }
  local class = SoloBrain.classOf({ id = "FIX_TRAINER_CLASSOF" }, DATA)
  eq(class and class.uses, 2, "classOf: the trainer's ai_classes record by id")
  local aliased = SoloBrain.classOf({ id = "OTHER", aiClass = "FIX_TRAINER_CLASSOF" }, DATA)
  eq(aliased and aliased.item, "FIX_ITEM_CLASSOF", "classOf: ...or by its `aiClass` (TrainerAI.classFor)")
  eq(SoloBrain.classOf({ id = "FIX_NO_SUCH_CLASS" }, DATA), nil, "classOf: no record is nil (GenericAI)")
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
-- 9b. SoloBrain.bagFor -- actual counts, not the gym kit
-- ------------------------------------------------------------------

do
  DATA.ai_classes.FIX_TRAINER_BAGFOR = { item = "FIX_ITEM_CLASS", uses = 2 }
  local trainer = { id = "FIX_TRAINER_BAGFOR" }
  local bag = SoloBrain.bagFor(trainer, DATA, 1)
  eq(bag.FIX_ITEM_CLASS, 2, "Gen 1 with no items list: class.item x class.uses")
end

do
  DATA.ai_classes.FIX_TRAINER_BAGNONE = { item = "FIX_ITEM_UNUSED", uses = 0 }
  local trainer = { id = "FIX_TRAINER_BAGNONE" }
  local bag = SoloBrain.bagFor(trainer, DATA, 1)
  eq(bag.FIX_ITEM_UNUSED, nil, "uses = 0 is an empty bag, not a free potion")
end

do
  local trainer = { id = "FIX_TRAINER_BAG2", items = { "FIX_ITEM_A", "FIX_ITEM_A", "FIX_ITEM_B" } }
  local bag = SoloBrain.bagFor(trainer, DATA, 2)
  eq(bag.FIX_ITEM_A, 2, "Gen 2 counts duplicate entries as uses")
  eq(bag.FIX_ITEM_B, 1, "...and keeps the rest")
  local entries = SoloBrain.bagEntries(trainer, DATA, 2)
  eq(#entries, 2, "bagEntries is the wire shape")
  eq(entries[1].id, "FIX_ITEM_A", "...sorted by id")
  eq(entries[1].count, 2, "...with the counted uses")
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
-- 11. Gen 3 is its own brain, never Red's (the old `~= 2 -> 1` clamp)
-- ------------------------------------------------------------------
--
-- The full Gen 3 arm is tests/gen3_solo.lua, over a real BattleSim3 referee;
-- what is pinned here is the dispatch, on bare sheets with no referee in the
-- view (the brain reads a battler-shaped copy of each).  (That no Gen 1 /
-- Gen 2 engine module is reached on the way is gen3_solo's to assert: this
-- suite has loaded them itself by here.)

do
  local brain = SoloBrain.new{ generation = 3, trainer = { aiFlags = 1, items = { 13, 0, 0, 0 } },
    rng = function(lo) return lo end }
  ok(brain ~= nil, "a Gen 3 brain builds with no dataset -- the sheets carry the numbers")
  eq(brain and brain.generation, 3, "...and it is Gen 3, not clamped to 1")
  eq(SoloBrain.new{ generation = 3 }, nil, "a Gen 3 fight with no trainer record has no brain")
  local bag = SoloBrain.bagFor({ items = { 13, 0, 13, 21 } }, nil, 3)
  eq(bag[13], 2, "bagFor(3) counts the numeric item slots")
  eq(#SoloBrain.itemsFor({ items = { 13, 0, 0, 21 } }, nil, 3), 2, "itemsFor(3) drops empty slots")

  local function row(num, power, typeId)
    return { id = "FIX3_" .. num, num = num, pp = 10, maxPp = 10, power = power, type = typeId,
             accuracy = 100, effect = 0, chance = 0, target = 0, priority = 0, flags = 0 }
  end
  local function sheet3(fields)
    local s = { speciesNum = 1, level = 50, hp = 100, maxHp = 100, types = { 0 }, ability = 0,
                stats = { atk = 80, def = 80, spe = 80, spa = 80, spd = 80 },
                moves = { row(1, 40, 0) } }
    for k, v in pairs(fields) do s[k] = v end
    return s
  end
  -- ABILITY_LEVITATE (26) makes a Ground (4) move do nothing; CHECK_BAD_MOVE
  -- (bit 0) scores it down, and the plain move is taken instead.
  local mon = sheet3({ moves = { row(89, 100, 4), row(1, 40, 0) } })
  local foe = sheet3({ ability = 26, types = { 14 } })
  local choice = brain and brain:choose{ mon = mon, foe = foe, party = { mon } }
  eq(choice and choice.action, "fight", "Gen 3 on bare sheets still answers")
  eq(choice and choice.move, 1, "...and steers around LEVITATE")
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
