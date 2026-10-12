-- src/SoloBrain.lua: who answers for a solo fight's opponent, exercised with
-- no engine BattleState anywhere.
--
-- Run: luajit tests/solo_brain.lua
--   or luajit mods/rby_mmo/tests/solo_brain.lua  (from the engine)
--
-- The contract pinned here (SoloBrain's header; the "Solo fights" bullet of
-- contract K16, docs/plans/gen12-referee-remaining-gaps.md):
--
--   * Red and Gold: no brain.  The referee runs the carts' own computer
--     (pokered TrainerAI / AIEnemyTrainerChooseMoves / EnemySendOut,
--     pokecrystal AIChooseMove / AI_SwitchOrTryItem /
--     FindMonInOTPartyToSwitchIntoBattle) through `Turn:autoPick`, so
--     `SoloBrain.new` declines for a wild monster, every Gold trainer and a
--     Red trainer with no registered `brain`.
--   * The one exception: a mod-registered `brain` function on a Red trainer
--     record or its `ai_classes` class.  It is handed a BattleState-shaped
--     copy of the field and its *move* is filed; an item or a switch it
--     answers is declined, and so is a forced send-out.
--   * Gen 3 answers the whole turn (tests/gen3_solo.lua has the full arm).
--
-- Standalone in the same spirit as tests/battle_sim_turn.lua: it loads the
-- shipped mod files through a from-scratch `need`-shaped resolver, the same
-- two-argument `chunk(need, mod)` convention main.lua's real loader uses
-- (SoloBrain.lua reads `local need, mod = ...`).  What makes this suite
-- possible at all is that SoloBrain synthesises its own BattleState-shaped
-- view rather than touching a real one (see the module's own header, "a
-- brain's view, and why it is a copy rather than a puppet") -- so a unit test
-- can hand it plain tables and never stand up love, a ROM, or a screen.
--
-- The engine's own modules (src/battle/TrainerAI.lua, TypeChart.lua) are
-- pulled in by SoloBrain itself via plain `require`, not through `need` -- a
-- class-registered brain is resolved through TrainerAI.classFor, and section
-- 3's brain hands its view to TrainerAI.chooseMove -- so this suite only runs
-- from a checkout where those resolve, i.e. the engine root (or a view of it
-- with this mod symlinked in), never in total isolation.
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
-- the very first brain in this whole process to call `_ensureTypeChart`
-- decides the chart for every brain built afterwards -- TypeChart.load is
-- never called a second time once the module's own probe already succeeds.
-- A second, different `type_chart` table defined later in this file would
-- therefore be silently ignored. One canonical chart sidesteps that trap
-- instead of tripping over it.

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

local function twoMoves()
  return { { id = "soak", pp = 10 }, { id = "bonk", pp = 10 } }
end

-- A Red brain over `trainer`, built the way every scenario below builds one.
local function redBrain(trainer, extra)
  extra = extra or {}
  return SoloBrain.new{
    data = DATA, trainer = trainer, generation = 1, aiMods = extra.aiMods,
    rng = detRng, typeName = TYPE_NAMES,
  }
end

-- ------------------------------------------------------------------
-- 1. Red and Gold: no brain -- the referee's own computer answers
-- ------------------------------------------------------------------
--
-- Whatever the trainer's class would do on the cart -- layers in `aiMods`,
-- an item every turn, Gold's whole AI word -- is the referee's now, run from
-- the class data the NPC upload states, at the cart's own draw points.  So
-- there is nothing for this module to build, and SoloBattle files `autoPick`.

do
  DATA.ai_classes.FIX_TRAINER_ITEMCLASS = {
    kind = "class", chance = 256, item = "FIX_ITEM_CLASS", uses = 2,
  }
  local brain, reason = redBrain({ id = "FIX_TRAINER_ITEMCLASS", aiMods = { "LAYER_3" } },
    { aiMods = { "LAYER_3" } })
  eq(brain, nil, "Red: a trainer with layers and an item class but no brain gets none")
  ok(type(reason) == "string" and reason:find("brain") ~= nil,
    "...and the reason says so rather than raising: " .. tostring(reason))

  eq(redBrain({ id = "FIX_TRAINER_NOCLASS" }), nil,
    "Red: a trainer with no class record at all (GenericAI) gets none")

  -- A record that is not a function is not a brain (the engine would call
  -- it and raise; this declines).
  eq(redBrain({ id = "FIX_TRAINER_NOTFN", brain = "not a function" }), nil,
    "Red: a non-function `brain` field builds nothing")
end

do
  local asked = false
  local trainer = {
    id = "FIX_TRAINER_GOLD",
    -- TRNATTR_AI_MOVE_WEIGHTS with every layer bit set: on the cart this
    -- class scores its moves, and so does the referee -- not this module.
    attributes = { 0, 0, 0, 0xFF, 0x03, 0, 0, 0 },
    items = { "POTION" },
    -- Gold's engine battle has no brain seam (gen2 Battle:vanillaEnemyMove
    -- consults none), so a function here is never asked either.
    brain = function() asked = true; return nil end,
  }
  local brain, reason = SoloBrain.new{ data = DATA, trainer = trainer, generation = 2,
    rng = detRng, typeName = TYPE_NAMES }
  eq(brain, nil, "Gold: no brain for any trainer -- AIChooseMove is the referee's")
  ok(type(reason) == "string" and reason:find("Gold") ~= nil,
    "...and the reason names it: " .. tostring(reason))
  eq(asked, false, "Gold: a `brain` on the record is never called")
  eq(#trainer.items, 1, "Gold: the registry's own item list is untouched")
end

do
  local noBrain, reason = SoloBrain.new{ data = DATA, generation = 1 }
  eq(noBrain, nil, "Red wild: no trainer record refuses to build")
  ok(type(reason) == "string" and reason:find("trainer") ~= nil,
    "...and names the reason rather than raising: " .. tostring(reason))
  eq(SoloBrain.new{ data = DATA, generation = 2 }, nil, "Gold wild: the same")
end

do
  local noData, reason = SoloBrain.new{ trainer = { id = "x", brain = function() end } }
  eq(noData, nil, "Red: no dataset to read moves from refuses to build, brain or not")
  ok(type(reason) == "string" and reason:find("dataset") ~= nil,
    "...and says so: " .. tostring(reason))
end

-- ------------------------------------------------------------------
-- 2. a registered brain on a Red trainer: its move is filed
-- ------------------------------------------------------------------

-- 2a. the record's own brain, over layers that would pick otherwise.
do
  local trainer = {
    id = "FIX_TRAINER_BRAINSUP",
    aiMods = { "LAYER_3" },
    brain = function(battle) return battle.enemy.curMoves[2] end, -- always "bonk"
  }
  local brain, reason = redBrain(trainer, { aiMods = { "LAYER_3" } })
  ok(brain ~= nil, "Red: a trainer carrying a brain function gets a brain: " .. tostring(reason))
  eq(brain and brain.generation, 1, "...a Red one")
  local mon = mkMon1{ moves = twoMoves() }
  local foe = mkMon1{ types = { SCORCH } }
  local choice = brain and brain:choose{ mon = mon, foe = foe, party = { mon } }
  eq(choice and choice.action, "fight", "the brain's move is filed")
  -- the index vocabulary trap: submitChoice's `move` is zero-based, so slot 2
  -- ("bonk") reads 1 -- not 2, which is what `fighter.choice` would hold.
  eq(choice and choice.move, 1,
    "...bonk (slot 2, zero-based 1), not the layers' super-effective soak")
end

-- 2b. a class-registered brain (an `ai_classes` record of kind "brain"),
-- resolved through TrainerAI.classFor -- the record's own `aiClass` first.
do
  DATA.ai_classes.FIX_CLASS_BRAIN = {
    kind = "brain",
    brain = function(battle) return battle.enemy.curMoves[1] end, -- "soak"
  }
  local brain = redBrain({ id = "FIX_TRAINER_OTHER", aiClass = "FIX_CLASS_BRAIN" })
  ok(brain ~= nil, "Red: a class carrying a brain gives its trainers one")
  local mon = mkMon1{ moves = twoMoves() }
  local choice = brain and brain:choose{ mon = mon, foe = mkMon1{}, party = { mon } }
  eq(choice and choice.move, 0, "...and the class brain's move (soak, zero-based 0) is filed")
end

-- 2c. the record's brain over its class's (vanillaEnemyAction's
-- `self.trainer.brain or (class and class.brain)`).
do
  local brain = redBrain({
    id = "FIX_CLASS_BRAIN",
    brain = function(battle) return battle.enemy.curMoves[2] end,
  })
  local mon = mkMon1{ moves = twoMoves() }
  local choice = brain and brain:choose{ mon = mon, foe = mkMon1{}, party = { mon } }
  eq(choice and choice.move, 1, "the trainer record's brain wins over its class's")
end

-- 2d. answers spelled other ways: an id, Struggle, and a duplicate move.
do
  local answer
  local brain = redBrain({ id = "FIX_TRAINER_SHAPES", brain = function() return answer end })

  answer = { id = "bonk" }
  local mon = mkMon1{ moves = twoMoves() }
  local c = brain:choose{ mon = mon, foe = mkMon1{}, party = { mon } }
  eq(c and c.move, 1, "a move named by id is filed by its slot")

  answer = { id = "STRUGGLE", struggle = true }
  local spent = mkMon1{ moves = { { id = "bonk", pp = 0 }, { id = "soak", pp = 0 } } }
  c = brain:choose{ mon = spent, foe = mkMon1{}, party = { spent } }
  eq(c and c.action, "fight", "Struggle is filed as a move")
  eq(c and c.move, 0, "...the sim's own spelling of it: every slot empty, the first index")

  local twice = mkMon1{ moves = { { id = "bonk", pp = 10 }, { id = "bonk", pp = 10 } } }
  local exact = twice.moves
  brain.brainFn = function(battle) return battle.enemy.curMoves[2] end
  c = brain:choose{ mon = twice, foe = mkMon1{}, party = { twice } }
  eq(c and c.move, 1, "a move known twice is filed at the exact slot the brain returned")
  eq(twice.moves, exact, "...and the sim monster is not written to")
end

-- 2e. what the brain is handed: the BattleState surface, per send-out.
do
  DATA.ai_classes.FIX_TRAINER_VIEW = { uses = 2, chance = 64, item = "FIX_ITEM_VIEW" }
  local seen = {}
  local trainer = {
    id = "FIX_TRAINER_VIEW", aiMods = { 3 },
    brain = function(battle)
      seen[#seen + 1] = battle
      return battle.enemy.curMoves[1]
    end,
  }
  local brain = redBrain(trainer, { aiMods = { 3 } })
  local first = mkMon1{ species = "fixlead", moves = twoMoves(), types = { AQUA }, slot = 1 }
  local second = mkMon1{ species = "fixnext", moves = twoMoves(), slot = 4 }
  local foe = mkMon1{ types = { SCORCH, PLAIN } }
  local party = { first, second }
  brain:choose{ mon = first, foe = foe, party = party, active = 1 }
  brain:choose{ mon = first, foe = foe, party = party, active = 1 }
  brain:choose{ mon = second, foe = foe, party = party, active = 2 }

  local v = seen[1] or {}
  eq(v.kind, "trainer", "view: a trainer battle")
  eq(v.trainer, trainer, "view: the trainer record itself")
  eq(v.data, DATA, "view: the dataset")
  eq(v.rng, detRng, "view: the brain draws from the generator it was built with")
  eq(v.enemyAIMods and v.enemyAIMods[1], 3, "view: enemyAIMods, the class's layers")
  eq(v.ruleset and v.ruleset.enemyUnlimitedPP, false, "view: the enemy's PP counts (the referee depletes it)")
  eq(v.enemy and v.enemy.curMoves[1].id, "soak", "view: the enemy's moves")
  eq(v.enemy and v.enemy.curTypes[1], "AQUA", "view: the enemy's types by name")
  eq(v.player and table.concat(v.player.curTypes, ","), "SCORCH,PLAIN", "view: the player's too")
  eq(v.enemy and v.enemy.mon.species, "fixlead", "view: the enemy monster's species")
  eq(#(v.enemyParty or {}), 2, "view: the whole party")
  eq(v.enemyIndex, 1, "view: and which one is out")
  eq(v.aiUses, 2, "view: wAICount seeded from the class's uses")
  eq(v.turnCount, 0, "view: the first selection of this monster")
  eq(seen[2] and seen[2].turnCount, 1, "view: the second counts on")
  eq(seen[3] and seen[3].turnCount, 0, "view: a new monster out starts again")
  eq(seen[3] and seen[3].enemyIndex, 2, "view: ...at its own party index")
  ok(seen[1] ~= seen[2], "view: a fresh copy every call -- nothing the brain writes leaks in")
end

-- ------------------------------------------------------------------
-- 3. a brain that hands its view to the engine's own chooser
-- ------------------------------------------------------------------
--
-- A registered brain may wrap vanilla: `TrainerAI.chooseMove(battle.enemy,
-- battle.rng, battle)`.  The copy is complete enough for that -- LAYER_3
-- prices the types off the loaded chart -- and wAILayer2Encouragement, which
-- chooseMove counts on the battler it is handed, comes back off the copy and
-- is handed in again next call, as BattleState's battler keeps it, until the
-- monster changes.

do
  local TrainerAI = require("src.battle.TrainerAI")
  local layer2 = {}
  local brain = redBrain({
    id = "FIX_TRAINER_WRAP", aiMods = { "LAYER_3" },
    brain = function(battle)
      layer2[#layer2 + 1] = battle.enemy.aiLayer2
      return TrainerAI.chooseMove(battle.enemy, battle.rng, battle)
    end,
  }, { aiMods = { "LAYER_3" } })
  local mon = mkMon1{ moves = twoMoves(), types = { PLAIN } }
  local foe = mkMon1{ types = { SCORCH } }
  local c = brain:choose{ mon = mon, foe = foe, party = { mon } }
  eq(c and c.move, 0, "wrapped TrainerAI: LAYER_3 picks the super-effective soak")
  brain:choose{ mon = mon, foe = foe, party = { mon } }
  local next_ = mkMon1{ moves = twoMoves() }
  brain:choose{ mon = next_, foe = foe, party = { mon, next_ } }
  eq(table.concat(layer2, ","), "0,1,0",
    "wrapped TrainerAI: wAILayer2Encouragement carries across selections and resets on a send-out")
end

-- ------------------------------------------------------------------
-- 4. what a brain answers that is not filed
-- ------------------------------------------------------------------
--
-- The class routine's slot of the turn -- an item, a switch -- is the
-- referee's (contract K16), run from the uploaded `aiClass` whoever filed
-- the move; EnemySendOut's walk is the referee's too.  Each of these is nil,
-- SoloBattle's cue to file `autoPick`.

do
  DATA.ai_classes.FIX_TRAINER_BRAINITEM = { uses = 3, item = "FIX_ITEM_BRAIN" }
  local answer
  local calls = 0
  local brain = redBrain({ id = "FIX_TRAINER_BRAINITEM",
    brain = function() calls = calls + 1; return answer end })
  local mon = mkMon1{ moves = { { id = "bonk", pp = 10 } }, slot = 1 }
  local bench = mkMon1{ moves = { { id = "bonk", pp = 10 } }, slot = 6 }
  local view = { mon = mon, foe = mkMon1{}, party = { mon, bench } }

  answer = { special = "aiItem", item = "FIX_ITEM_BRAIN" }
  eq(brain:choose(view), nil, "K16 (Red): a brain's item answer is declined")
  eq(brain.aiUses, 3, "...and the budget seeded from uses = 3 is not spent here")

  answer = { special = "aiSwitch", index = 2 }
  eq(brain:choose(view), nil, "K16 (Red): a brain's switch answer is declined")

  answer = nil
  eq(brain:choose(view), nil, "a brain that answers nothing is declined")
  answer = "bonk"
  eq(brain:choose(view), nil, "a brain that answers a non-table is declined")

  local before = calls
  answer = { id = "bonk" }
  local fainted = mkMon1{ hp = 0, slot = 1, moves = { { id = "bonk", pp = 10 } } }
  eq(brain:choose{ mon = fainted, mustReplace = true, party = { fainted, bench } }, nil,
    "K16 (Red): a forced send-out is the referee's (EnemySendOut) -- nil, never a switch")
  eq(calls, before, "...and the brain is not even asked")
end

-- A move the referee would refuse is declined, never filed to be refused.
do
  local answer
  local brain = redBrain({ id = "FIX_TRAINER_REFUSED", brain = function(battle)
    return answer == "slot1" and battle.enemy.curMoves[1] or answer
  end })
  local disabled = mkMon1{ moves = twoMoves(), disable = { turns = 3, moveIndex = 1 } }
  answer = "slot1"
  eq(brain:choose{ mon = disabled, foe = mkMon1{}, party = { disabled } }, nil,
    "a brain's disabled slot is declined -- autoPick answers instead")
  answer = { id = "bonk" }
  local c = brain:choose{ mon = disabled, foe = mkMon1{}, party = { disabled } }
  eq(c and c.move, 1, "...while the slot the sim takes is filed")

  local dry = mkMon1{ moves = { { id = "soak", pp = 0 }, { id = "bonk", pp = 10 } } }
  answer = "slot1"
  eq(brain:choose{ mon = dry, foe = mkMon1{}, party = { dry } }, nil,
    "a brain's empty-PP slot (another still has PP) is declined")
  answer = { id = "nosuchmove" }
  eq(brain:choose{ mon = dry, foe = mkMon1{}, party = { dry } }, nil,
    "a move the monster does not know is declined")
end

-- A brain that raises: declined, and said once -- naming whose it is.
do
  local brain = redBrain({ id = "FIX_TRAINER_RAISES", brain = function() error("fix boom") end })
  local mon = mkMon1{ moves = twoMoves() }
  local before = #warnings
  eq(brain:choose{ mon = mon, foe = mkMon1{}, party = { mon } }, nil, "a raising brain is declined")
  eq(brain:choose{ mon = mon, foe = mkMon1{}, party = { mon } }, nil, "...every time")
  eq(#warnings - before, 1, "...with one warning for the session, not one a turn")
  local line = warnings[before + 1] or ""
  ok(line:find("brain") ~= nil and line:find("fix boom", 1, true) ~= nil
     and line:find("report this to the mod", 1, true) ~= nil,
    "...naming the brain, its error and the remediation: " .. line)
  for i = #warnings, before + 1, -1 do table.remove(warnings, i) end
end

-- ------------------------------------------------------------------
-- 5. the nil contract: a decline, never an error
-- ------------------------------------------------------------------

do
  local brain = redBrain({ id = "FIX_TRAINER_NILCONTRACT", brain = function(battle)
    return battle.enemy.curMoves[1]
  end })
  local mon = mkMon1{ moves = { { id = "bonk", pp = 10 } } }

  eq(brain:choose(nil), nil, "choose(nil) declines rather than throwing")
  eq(brain:choose{}, nil, "choose({}) with no mon declines")
  eq(brain:choose{ mon = mon }, nil,
    "choose with no foe and no mustReplace declines -- there is nothing to score against")
end

-- ------------------------------------------------------------------
-- 6. SoloBrain.classOf: one resolution of a trainer's class record
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
-- 7. SoloBrain.trainerOf: both generations' shapes, and no others
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
-- 8. the trainer's kit: Gen 3's slots, nothing on Red or Gold (K16)
-- ------------------------------------------------------------------

do
  DATA.ai_classes.FIX_TRAINER_KIT = { item = "FIX_ITEM_KIT", uses = 2 }
  local red = { id = "FIX_TRAINER_KIT", items = { "FIX_ITEM_A" } }
  eq(#SoloBrain.itemsFor(red, DATA, 1), 0, "itemsFor(1): Red carries no NPC kit -- the class item is the referee's")
  eq(next(SoloBrain.bagFor(red, DATA, 1)), nil, "bagFor(1): ...nor a bag")
  local gold = { id = "FIX_TRAINER_KIT2", items = { "FIX_ITEM_A", "FIX_ITEM_B" } }
  eq(#SoloBrain.itemsFor(gold, DATA, 2), 0, "itemsFor(2): Gold's trainer items are the referee's (trainerItems)")
  eq(next(SoloBrain.bagFor(gold, DATA, 2)), nil, "bagFor(2): ...and no bag")
  eq(SoloBrain.bagEntries, nil, "no wire-shaped NPC bag is offered at all")
end

-- ------------------------------------------------------------------
-- 9. Gen 3 is its own brain, never Red's (the old `~= 2 -> 1` clamp)
-- ------------------------------------------------------------------
--
-- The full Gen 3 arm is tests/gen3_solo.lua, over a real BattleSim3 referee;
-- what is pinned here is the dispatch, on bare sheets with no referee in the
-- view (the brain reads a battler-shaped copy of each).  (That no Gen 1
-- engine module is reached on the way is gen3_solo's to assert: this suite
-- has loaded them itself by here.)

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
-- none of them (the raising brain aside, whose one line was checked and
-- taken back) should have made the module's own pcall catch anything
-- ------------------------------------------------------------------

eq(#warnings, 0,
  "no warning fired during any of the above -- every nil above was a clean decline: "
  .. table.concat(warnings, " | "))

-- ------------------------------------------------------------------

io.write(string.format("solo_brain: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
