-- The opponent's mind, borrowed from the engine and lent to the mod's referee.
--
-- When this mod substitutes its own battle system for an ordinary solo fight
-- (src/SoloBattle.lua), the far side of the field is a `BattleSim` fighter with
-- no connection behind it. The referee already knows how to answer for such a
-- seat: `Turn:autoPick` files the same choice the choice-timeout would file, a
-- bag/super-effective/setup/switch heuristic that both runtimes reproduce byte
-- for byte. That heuristic exists so a hub-refereed fight cannot stall, and it
-- is the right answer *there* -- but it is not anybody in particular. It plays
-- BROCK exactly the way it plays a bug catcher.
--
-- A solo fight never crosses the wire, and that one fact changes what is
-- possible. There is no second runtime to stay byte-identical with, no Node
-- twin to keep in parity, and nothing to gain by hiding the engine's own data
-- from the thing choosing the move. So the NPC's turn is decided *here*, on the
-- client, by the engine's real trainer AI -- `src/battle/TrainerAI.lua` on Gen 1
-- and `src/battle/gen2/Ai.lua` on Gen 2 -- and then handed to the referee as an
-- ordinary `submitChoice`. Giovanni buys his GUARD SPEC, Agatha rotates, Brock
-- reaches for the FULL HEAL the moment you paralyse Onix, and a Gold class with
-- the SMART bit set still scores its moves the way scoring.asm scores them.
-- `src/BattleSim/Turn.lua` is not touched by any of it, which is the property
-- that keeps this whole feature off the wire.
--
-- ------- the adapter, and why it is a copy rather than a puppet
--
-- `TrainerAI` was written against an engine `BattleState`: it reads
-- `battle.enemy.curMoves`, `battle.player.curTypes`, `battle.aiUses`,
-- `battle.rng`. Our fight is a `BattleSim` `Turn`, whose monsters are a
-- different shape entirely -- numeric type ids, numeric effect ids, `atk`/`spc`
-- where the engine says `attack`/`special`, and a party dealt onto one fighter
-- rather than an `enemyParty` beside an `enemyIndex`.
--
-- There were two ways across. The frozen engine `BattleState` is *right there*,
-- sitting on the stack underneath our screen with a real `enemy` battler and a
-- real `enemyParty` on it, and the sim's state could simply be written onto it
-- each turn and `battle:vanillaEnemyAction()` called directly. That is less
-- translation, and it is the wrong trade: it mutates a live engine object in
-- the middle of a fight it is not running, which means every bug it produces
-- looks like an engine bug, reproduces only in this mod, and reproduces only
-- some of the time. It would also make this file impossible to test without
-- standing up a whole `BattleState`.
--
-- So this file synthesises a `BattleState`-*shaped* view from a plain
-- description of the sim's current state, calls the engine AI against the copy,
-- and translates the answer back. Nothing engine-owned is written to. The
-- inputs are tables a caller can build by hand, which is what makes the
-- dispatch (layer / class action / `brain` record / `aiUses` budget) testable
-- under headless `luajit` with no battle anywhere.
--
-- ------- what it will not answer
--
-- `nil` is a first-class result and never an error. A build whose engine battle
-- modules would not load, a wild encounter (no trainer record, so no per-trainer
-- behaviour to be faithful to), a monster whose every move is disabled, an AI
-- that reached for an item the NPC's bag sheet does not hold, a dataset with no
-- move table -- all of them answer `nil`, and the caller falls back to
-- `Turn:autoPick`, which is a complete answer on its own. That is the whole
-- error contract: this module makes a good fight better and can never make one
-- fail to run.
--
-- ------- two index vocabularies, and the one this speaks
--
-- Worth stating plainly because the two live a few hundred lines apart in
-- `Turn.lua` and disagree. `Battle:autoPick` writes `fighter.choice` *directly*,
-- so its `move` is a one-based index into `mon.moves` and its `slot` is a party
-- index. `Battle:submitChoice` goes through `_normaliseChoice`, which is the
-- wire's vocabulary: `move` is **zero-based**, and `slot` is the monster's own
-- `slot` field -- the sender's party position -- matched by `partyIndexOf`
-- rather than counted off the array. Everything returned from here is in
-- `submitChoice`'s vocabulary, because `submitChoice` is what the caller calls.
-- Nothing here may be assigned to `fighter.choice`.

local need, mod = ...
local Gen = need("Gen")

local M = {}
M.__index = M

local max = math.max

-- ------------------------------------------------------------------
-- the engine, softly
-- ------------------------------------------------------------------
--
-- Lazily and behind pcall, the same posture `MediatedBattle.loadEngine` and
-- `CoopBattle.loadEngine` take: `modkit validate` loads every file in this
-- folder headlessly with no love and no data, and a require that throws at file
-- scope would fail the whole mod over a feature the player may never turn on.
-- Every one of these is optional -- a boot missing `TrainerAI` fights on with
-- `autoPick`, which is exactly what happened before this file existed.

local engine, engineTried

local function loadEngine()
  if engineTried then return engine end
  engineTried = true
  local parts = {}
  local function grab(key, path)
    local ok, value = pcall(require, path)
    if ok and value ~= nil then parts[key] = value end
  end
  -- Gen 1: the three vanilla scoring layers, the per-class item/switch table,
  -- and the type chart those layers ask for effectiveness.
  grab("TrainerAI", "src.battle.TrainerAI")
  grab("TypeChart", "src.battle.TypeChart")
  -- Gen 2: the ten flag-gated layers, plus the damage estimator they rank by.
  grab("Ai2", "src.battle.gen2.Ai")
  grab("Damage2", "src.battle.gen2.Damage")
  engine = parts
  return engine
end

M.loadEngine = loadEngine

-- One warning per session per reason, never a raise. This runs inside a battle
-- pump; a log line per turn would be its own bug.
local warned = {}

local function warnOnce(key, message)
  if warned[key] then return end
  warned[key] = true
  local log = mod and mod.log
  if log and log.warn then pcall(log.warn, log, message) end
end

-- ------------------------------------------------------------------
-- the sim's spellings, and the engine's
-- ------------------------------------------------------------------

-- `Turn.STATUS_TO_WIRE`, mirrored rather than imported: the three-letter token
-- is what the engine itself spells a condition with (`src/battle/Status.lua`
-- registers SLP / PSN / BRN / FRZ / PAR), so one table serves both directions
-- of this bridge and `src/BattleSim/` stays a directory this file never loads.
local STATUS_TO_ENGINE = {
  sleep = "SLP", poison = "PSN", burn = "BRN",
  freeze = "FRZ", paralysis = "PAR", toxic = "TOX",
}

-- Both sims carry battle stats under short keys and the two generations do not
-- agree: Gen 1 is atk/def/spd/spc with one shared Special, Gen 2 is
-- atk/def/spe/spa/spd with Speed spelled `spe` and `spd` meaning Sp.Def. Read
-- through these rather than by key, so a view built from either sim answers.
local function statOf(stats, ...)
  if type(stats) ~= "table" then return nil end
  for i = 1, select("#", ...) do
    local value = tonumber(stats[select(i, ...)])
    if value then return value end
  end
  return nil
end

-- The numeric type ids a sim monster carries are positions in an ordering the
-- client built when it snapshotted the party -- `MediatedBattle.typeOrder`,
-- which sorts the registry's own type ids and cuts the tail at
-- `Config.BATTLE_TYPE_MAX`. Reversing it is how a sim mon gets its engine type
-- names back, and it is deliberately *that* function rather than a second copy
-- of the same sort: two orderings that drift would hand the AI a Fire move
-- against a Rock defender and call it neutral, silently, forever.
local mediated, mediatedTried

local function typeOrderOf(data)
  if not mediatedTried then
    mediatedTried = true
    local ok, value = pcall(need, "MediatedBattle")
    if ok and type(value) == "table" and type(value.typeOrder) == "function" then
      mediated = value
    else
      mediated = false
      warnOnce("typeOrder",
        "the mod's own MediatedBattle module did not load, so a solo trainer's "
        .. "AI cannot resolve type matchups and will score moves without them; "
        .. "reinstall the mod folder so every file under src/ is present")
    end
  end
  if not mediated then return nil end
  local ok, order = pcall(mediated.typeOrder, data)
  if not ok then return nil end
  return order
end

-- ------------------------------------------------------------------
-- construction
-- ------------------------------------------------------------------

-- The trainer record, wherever this generation keeps it.
--
-- Gen 1 hangs it on the `BattleState` itself; Gen 2's `BattleState` is a shell
-- around a `gen2.Battle` and the record sits on `state.battle.trainer`. The
-- same two-line aliasing `Coop:onTrainerBattle` and `Coop.payTrainerPrize`
-- already do, in one place so a third caller cannot get it half right.
function M.trainerOf(state)
  if type(state) ~= "table" then return nil end
  if type(state.trainer) == "table" then return state.trainer end
  local inner = state.battle
  if type(inner) == "table" and type(inner.trainer) == "table" then
    return inner.trainer
  end
  return nil
end

-- Every item id this trainer's AI could ever reach for.
--
-- Exported for the caller's benefit rather than used here: a `coop_npc` seat
-- whose `bag` sheet is set is held to it (`Turn._bagHas`), and
-- `Turn.DEFAULT_NPC_BAG` holds four generic ids that between them cover none of
-- GIOVANNI's GUARD SPEC, LANCE's HYPER POTION or BRUNO's X DEFEND. A caller
-- that seeds the NPC bag from this list gets the fight the trainer was written
-- to fight; one that does not will simply see those choices declined here.
function M.itemsFor(trainer, data, generation)
  local out = {}
  if type(trainer) ~= "table" then return out end
  local seen = {}
  local function put(id)
    if type(id) ~= "string" or id == "" or seen[id] then return end
    seen[id] = true
    out[#out + 1] = id
  end
  if generation == 2 or type(trainer.items) == "table" then
    for _, id in ipairs(trainer.items or {}) do put(id) end
  end
  local eng = loadEngine()
  local TrainerAI = eng and eng.TrainerAI
  if TrainerAI and type(TrainerAI.classFor) == "function" then
    local ok, class = pcall(TrainerAI.classFor,
      { trainer = trainer, data = data })
    if ok and type(class) == "table" then put(class.item) end
  end
  return out
end

-- opts:
--   game        the live game; `game.data` is the dataset the AI reads
--   engine      the frozen engine BattleState underneath, for its trainer
--   trainer     an explicit trainer record, overriding the one above
--   data        an explicit dataset, overriding game.data
--   generation  1 or 2; defaults to Gen.generation(game)
--   aiMods      the Gen 1 scoring layers; defaults to the battle's own
--   rng         function(lo, hi) -> integer in [lo, hi]
--   typeName    function(n) -> engine type id, or an array indexed from 1;
--               injected by the suites so a unit test needs no type chart
--
-- Returns the brain, or nil plus a reason. A reason and not a raise: the caller
-- is a divert path that must leave the vanilla battle running when this cannot
-- be built, and it has a player standing in front of it either way.
function M.new(opts)
  opts = opts or {}
  local game = opts.game
  local data = opts.data or (type(game) == "table" and game.data) or nil
  if type(data) ~= "table" or type(data.moves) ~= "table" then
    return nil, "no dataset to read the trainer's moves from"
  end

  local trainer = opts.trainer or M.trainerOf(opts.engine)
  if type(trainer) ~= "table" then
    -- A wild encounter has no trainer and therefore no per-trainer behaviour to
    -- be faithful to. `autoPick` is the honest answer there, and refusing here
    -- is how the caller learns to use it without a second predicate.
    return nil, "this battle has no trainer record, so there is no AI to bridge"
  end

  local generation = tonumber(opts.generation) or Gen.generation(game)
  if generation ~= 2 then generation = 1 end

  local eng = loadEngine()
  if generation == 1 and not (eng and eng.TrainerAI) then
    return nil, "the engine's TrainerAI module is unavailable"
  end
  if generation == 2 and not (eng and eng.Ai2) then
    return nil, "the engine's Gen 2 Ai module is unavailable"
  end

  local rng = opts.rng
  if type(rng) ~= "function" then
    rng = function(lo, hi)
      if hi == nil then lo, hi = 1, lo end
      if hi < lo then return lo end
      local love_ = rawget(_G, "love")
      local roll = love_ and love_.math and love_.math.random or math.random
      return roll(lo, hi)
    end
  end

  local self = setmetatable({
    data = data,
    generation = generation,
    trainer = trainer,
    rng = rng,
    -- The Gen 1 scoring layers. `battle.enemyAIMods` is what BattleState reads
    -- and the trainer record is where it came from, so either answers.
    aiMods = opts.aiMods
      or (type(opts.engine) == "table" and opts.engine.enemyAIMods)
      or trainer.aiMods,
    typeName = opts.typeName,
    -- wAICount and wAILayer2Encouragement, both of which the engine resets on
    -- every enemy send-out. Seeded on the first turn each monster is out --
    -- see M:_rollover.
    aiUses = 0,
    aiLayer2 = 0,
    turns = 0,
    lastMon = nil,
    -- Gen 2's AI_TryItem removes what it used from `trainer.items`, so a
    -- trainer with one POTION cannot drink it every turn. That list is engine-
    -- owned registry data and must not be edited, so the budget is spent
    -- against this copy instead.
    items2 = nil,
  }, M)

  if generation == 2 then
    local items = {}
    for _, id in ipairs(trainer.items or {}) do
      if type(id) == "string" and id ~= "" then items[#items + 1] = id end
    end
    self.items2 = items
  end

  return self
end

-- ------------------------------------------------------------------
-- the type bridge
-- ------------------------------------------------------------------

function M:_typeName(index)
  local injected = self.typeName
  if type(injected) == "function" then return injected(index) end
  if type(injected) == "table" then return injected[(index or 0) + 1] end
  if self.typeOrder == nil then
    self.typeOrder = typeOrderOf(self.data) or false
  end
  local order = self.typeOrder
  if not order or type(order.ids) ~= "table" then return nil end
  return order.ids[(tonumber(index) or 0) + 1]
end

function M:_typesOf(simMon)
  local out = {}
  for _, index in ipairs((simMon and simMon.types) or {}) do
    local name = self:_typeName(index)
    if name then out[#out + 1] = name end
  end
  return out
end

-- `TypeChart.rows` asserts on a chart that was never loaded, and Gen 1's
-- LAYER_3 calls it for every move it scores. The engine loads the chart when it
-- opens a battle, so in the live game this probe always passes on the first
-- turn and never runs again; it exists for the headless case, where nothing has
-- opened a battle and the assert would take the whole choice with it.
function M:_ensureTypeChart()
  if self.chartReady ~= nil then return self.chartReady end
  local TypeChart = (loadEngine() or {}).TypeChart
  if not TypeChart or type(TypeChart.rows) ~= "function" then
    self.chartReady = false
    return false
  end
  if pcall(TypeChart.rows, "?", {}) then
    self.chartReady = true
    return true
  end
  if type(TypeChart.load) == "function" and type(self.data.type_chart) == "table" then
    pcall(TypeChart.load, self.data)
  end
  self.chartReady = pcall(TypeChart.rows, "?", {}) and true or false
  return self.chartReady
end

-- ------------------------------------------------------------------
-- what the sim will actually accept
-- ------------------------------------------------------------------

-- The move slots `_normaliseChoice` would take, as `{ id, pp, move }` where
-- `move` is already the zero-based index a choice states.
--
-- Two rules, both the sim's rather than the AI's: a slot with no PP is refused
-- unless *every* slot is empty (which is how the sim spells Struggle), and a
-- disabled slot is refused outright. Filtering here rather than after the AI
-- has chosen is what keeps a refused choice from silently costing the NPC its
-- turn.
local function legalMoves(simMon)
  local moves = (simMon and simMon.moves) or {}
  local anyPp = false
  for i = 1, #moves do
    if (tonumber(moves[i].pp) or 0) > 0 then anyPp = true; break end
  end
  local disable = simMon and simMon.disable
  local disabledSlot = nil
  if type(disable) == "table" and (tonumber(disable.turns) or 0) > 0 then
    disabledSlot = tonumber(disable.moveIndex)
  end
  local out = {}
  for i = 1, #moves do
    local move = moves[i]
    if i ~= disabledSlot and (not anyPp or (tonumber(move.pp) or 0) > 0) then
      out[#out + 1] = { id = move.id, pp = tonumber(move.pp) or 0, move = i - 1 }
    end
  end
  return out, disabledSlot
end

-- ------------------------------------------------------------------
-- the entry point
-- ------------------------------------------------------------------

-- view:
--   mon             the NPC's active monster, in sim shape        (required)
--   foe             the player's active monster, in sim shape
--                   (required except on a forced send-out)
--   party           the NPC fighter's whole `mons` list, in order (optional)
--   active          index into `party` of `mon`                   (optional)
--   bag             the NPC fighter's bag sheet, id -> count      (optional)
--   mustReplace     the fighter owes a send-out, not a turn       (optional)
--   playerUsedMoves move ids the player has used this fight       (optional)
--   playerTurns     turns the player's active monster has been out (optional)
--
-- Returns a choice in `Turn:submitChoice`'s vocabulary --
-- `{ action = "fight", move = <zero-based index> }`,
-- `{ action = "switch", slot = <the monster's own slot> }` or
-- `{ action = "item", item = <id> }` -- or nil when it has no answer, which is
-- a normal outcome and the caller's cue to call `Turn:autoPick`.
--
-- No `target` is stated. Solo seats one fighter per side, so the sim's own
-- "first living foe" default is the only monster a choice could mean, and
-- naming a slot would only give the answer a second way to be refused.
function M:choose(view)
  if type(view) ~= "table" then return nil end
  if type(view.mon) ~= "table" then return nil end
  -- A forced send-out is answered without ever looking across the field, and
  -- the seat opposite may be mid-replacement itself, so the far monster is
  -- required only for the choices that actually score against it.
  if not view.mustReplace and type(view.foe) ~= "table" then return nil end

  self:_rollover(view)

  -- The whole decision, inside one pcall. Everything below reaches into engine
  -- modules that were written for a different object, and the contract of this
  -- file is that it can decline but never throw: a raise here would surface as
  -- a battle that stops answering, which is worse than a generic move.
  local ok, choice = pcall(self._decide, self, view)
  if not ok then
    warnOnce("decide",
      "the engine's trainer AI could not be driven against this battle ("
      .. tostring(choice) .. "), so solo trainers will fight with the "
      .. "referee's generic move picker instead; report this with the game "
      .. "version and the trainer you were fighting")
    return nil
  end
  return choice
end

-- wAICount and wAILayer2Encouragement are reset on every enemy send-out, and
-- the send-out this file can see is "the active monster is not the one it was
-- last turn". Sim monsters are deep-copied once when the battle is created and
-- never replaced, so table identity is a sound stand-in for "same monster" --
-- and it is also the only one available, since two of a trainer's mons may
-- share a species, a level and a slot number after a party is dealt.
function M:_rollover(view)
  if view.mon == self.lastMon then
    self.turns = self.turns + 1
    return
  end
  self.lastMon = view.mon
  self.turns = 0
  self.aiLayer2 = 0
  self.aiUses = self:_usesFor()
end

-- BattleState:aiUsesFor, without the BattleState: the class record's `uses`, or
-- zero for a trainer whose class never reaches for anything.
function M:_usesFor()
  if self.generation ~= 1 then return 0 end
  local TrainerAI = (loadEngine() or {}).TrainerAI
  if not (TrainerAI and type(TrainerAI.classFor) == "function") then return 0 end
  local ok, class = pcall(TrainerAI.classFor,
    { trainer = self.trainer, data = self.data })
  if not ok or type(class) ~= "table" then return 0 end
  return max(0, tonumber(class.uses) or 0)
end

function M:_decide(view)
  -- A forced send-out is not a turn and the AI is never asked for one.
  -- EnemySendOutFirstMon walks the party from the top and fields the first
  -- monster that can still fight, which is also exactly what
  -- `TrainerAI.switchAction` picks when it rotates -- so both generations get
  -- the same one answer here.
  if view.mustReplace then
    local slot = self:_firstLivingBench(view)
    if slot == nil then return nil end
    return { action = "switch", slot = slot }
  end

  if self.generation == 2 then return self:_decideGen2(view) end
  return self:_decideGen1(view)
end

-- The lowest-indexed living bench monster's own slot, or nil.
function M:_firstLivingBench(view)
  for _, mon in ipairs(view.party or {}) do
    if mon ~= view.mon and (tonumber(mon.hp) or 0) > 0 then
      return tonumber(mon.slot) or 0
    end
  end
  return nil
end

-- ------------------------------------------------------------------
-- Gen 1
-- ------------------------------------------------------------------

-- A `BattleState`-shaped copy of the sim's current field.
--
-- Only the surface `TrainerAI` reads is filled, plus the handful of fields a
-- registered `brain` record plausibly reaches for (species, level, stats), so
-- that a mod's own brain meets something recognisable rather than a stub. The
-- table is rebuilt per call and thrown away after: `chooseMove` *writes*
-- `battler.aiLayer2`, and a shared view would carry that write into the next
-- turn twice.
function M:_gen1Battle(view)
  local mon, foe = view.mon, view.foe
  local enemy = self:_battler(mon, false)
  local player = self:_battler(foe, true)
  enemy.aiLayer2 = self.aiLayer2

  local party, active = {}, 1
  for index, member in ipairs(view.party or { mon }) do
    party[index] = self:_battler(member, false).mon
    if member == mon then active = index end
  end
  if tonumber(view.active) then active = tonumber(view.active) end

  return {
    kind = "trainer",
    trainer = self.trainer,
    data = self.data,
    rng = self.rng,
    -- Vanilla Gen 1 never reads the enemy's PP -- `SelectEnemyMove` does not
    -- look -- and the engine spells that as `enemyUnlimitedPP`. The referee
    -- does deplete it, though, and a choice naming an empty slot is refused
    -- outright by `_normaliseChoice`. Between "the AI may pick a move that
    -- cannot be used" and "the AI respects a limit the cart did not have", the
    -- second is the one that still produces a fight, so the flag is forced off
    -- here whatever the frozen battle's ruleset says.
    ruleset = { enemyUnlimitedPP = false },
    enemyAIMods = self.aiMods,
    aiUses = self.aiUses,
    enemy = enemy,
    player = player,
    enemyParty = party,
    enemyIndex = active,
    turnCount = self.turns,
  }
end

function M:_battler(simMon, isPlayer)
  local curMoves = {}
  for _, move in ipairs((simMon and simMon.moves) or {}) do
    curMoves[#curMoves + 1] = { id = move.id, pp = tonumber(move.pp) or 0 }
  end

  local disable = simMon and simMon.disable
  local disabledSlot = nil
  if type(disable) == "table" and (tonumber(disable.turns) or 0) > 0 then
    disabledSlot = tonumber(disable.moveIndex)
  end

  local stages = (simMon and simMon.stages) or {}
  local monView = {
    species = simMon and simMon.species or "?",
    level = tonumber(simMon and simMon.level) or 1,
    hp = tonumber(simMon and simMon.hp) or 0,
    status = STATUS_TO_ENGINE[simMon and simMon.status] or nil,
    moves = curMoves,
    stats = {
      hp = tonumber(simMon and simMon.maxHp) or 1,
      attack = statOf(simMon and simMon.stats, "atk") or 1,
      defense = statOf(simMon and simMon.stats, "def") or 1,
      speed = statOf(simMon and simMon.stats, "spd", "spe") or 1,
      special = statOf(simMon and simMon.stats, "spc", "spa") or 1,
    },
  }

  return {
    isPlayer = isPlayer and true or false,
    name = monView.species,
    mon = monView,
    curMoves = curMoves,
    curTypes = self:_typesOf(simMon),
    disabledSlot = disabledSlot,
    stages = {
      attack = tonumber(stages.atk) or 0,
      defense = tonumber(stages.def) or 0,
      speed = tonumber(stages.spd) or tonumber(stages.spe) or 0,
      special = tonumber(stages.spc) or tonumber(stages.spa) or 0,
      accuracy = tonumber(stages.acc) or 0,
      evasion = tonumber(stages.eva) or 0,
    },
    toxicCounter = tonumber(simMon and simMon.toxicCounter) or nil,
    mist = (simMon and simMon.mist) and true or false,
  }
end

-- `BattleState:vanillaEnemyAction`, step for step: a registered `brain` record
-- supersedes everything, then the class's item/switch roll gets the turn if it
-- wants it, then the scoring layers pick a move.
function M:_decideGen1(view)
  local TrainerAI = (loadEngine() or {}).TrainerAI
  if not TrainerAI then return nil end
  self:_ensureTypeChart()

  local battle = self:_gen1Battle(view)

  local classOk, class = pcall(TrainerAI.classFor, battle)
  class = classOk and class or nil
  local brain = self.trainer.brain or (type(class) == "table" and class.brain)
  if type(brain) == "function" then
    local ok, action = pcall(brain, battle)
    if not ok then return nil end
    -- A brain owns the whole turn, including the budget: if it answered with an
    -- item or a switch, that is a use, exactly as it would be through the class
    -- path below.
    local choice = self:_fromEngineAction(action, view, battle)
    if choice and choice.action ~= "fight" then
      self.aiUses = max(0, self.aiUses - 1)
    end
    return choice
  end

  if self.aiUses > 0 then
    local ok, action = pcall(TrainerAI.classAction, battle)
    if ok and type(action) == "table" then
      local choice = self:_fromEngineAction(action, view, battle)
      if choice then
        self.aiUses = max(0, self.aiUses - 1)
        return choice
      end
      -- Declined -- the item is not on the NPC's bag sheet, or the bench it
      -- wanted to rotate to is gone. The budget is *not* spent on a turn the
      -- trainer did not get to take, and the fight falls through to a move,
      -- which is what the class routine's own `ret nc` arms do.
    end
  end

  local ok, chosen = pcall(TrainerAI.chooseMove, battle.enemy, battle.rng, battle)
  -- `chooseMove` counts the selection on the battler it was handed, and layer 2
  -- only fires on the second selection of each monster -- so the count has to
  -- come back off the copy before it is discarded.
  self.aiLayer2 = tonumber(battle.enemy.aiLayer2) or self.aiLayer2
  if not ok or type(chosen) ~= "table" then return nil end

  -- Struggle. The referee has its own spelling for this (every slot empty makes
  -- any index legal) and no id to match against, so the answer is the first
  -- slot the referee would accept.
  if chosen.struggle then
    local legal = legalMoves(view.mon)
    if #legal == 0 then return nil end
    return { action = "fight", move = legal[1].move }
  end

  -- `chooseMove` returns one of the very entries it was given, so identity is
  -- the exact answer to "which slot" -- and it is the only exact one, because a
  -- monster may legally know the same move twice.
  for index, move in ipairs(battle.enemy.curMoves) do
    if move == chosen then
      return self:_fightAt(view, index)
    end
  end
  return self:_fightById(view, chosen.id)
end

-- Translate `vanillaEnemyAction`'s answer -- an `{ special = ... }` table from
-- the class routine, or a bare move instance from a brain or a locked action.
function M:_fromEngineAction(action, view, battle)
  if type(action) ~= "table" then return nil end

  if action.special == "aiSwitch" then
    local index = tonumber(action.index)
    local target = index and (view.party or {})[index]
    if type(target) ~= "table" then return nil end
    if target == view.mon or (tonumber(target.hp) or 0) <= 0 then return nil end
    return { action = "switch", slot = tonumber(target.slot) or 0 }
  end

  if action.special == "aiItem" then
    local item = action.item
    if type(item) ~= "string" or item == "" then return nil end
    -- A seat with a bag sheet is held to it by `_normaliseChoice`, and a
    -- refused choice would cost the trainer its turn without saying so. A seat
    -- with no sheet is permissive, and so is this.
    if type(view.bag) == "table" and (tonumber(view.bag[item]) or 0) <= 0 then
      return nil
    end
    -- No `slot`: the referee reads an absent one as the active monster, which
    -- is the only monster a trainer's AI ever heals.
    return { action = "item", item = item }
  end

  if action.struggle then
    local legal = legalMoves(view.mon)
    if #legal == 0 then return nil end
    return { action = "fight", move = legal[1].move }
  end

  if action.id ~= nil then
    if battle then
      for index, move in ipairs(battle.enemy.curMoves) do
        if move == action then return self:_fightAt(view, index) end
      end
    end
    return self:_fightById(view, action.id)
  end

  return nil
end

-- A one-based slot in the monster's move list, as a choice -- but only if the
-- referee would take it. The AI is allowed to want a move the sim will not
-- accept (a disabled slot on a build where the two disagree about the count);
-- answering nil there hands the turn to `autoPick` rather than losing it.
function M:_fightAt(view, slot)
  for _, legal in ipairs(legalMoves(view.mon)) do
    if legal.move == slot - 1 then
      return { action = "fight", move = legal.move }
    end
  end
  return nil
end

function M:_fightById(view, moveId)
  if type(moveId) ~= "string" then return nil end
  for _, legal in ipairs(legalMoves(view.mon)) do
    if legal.id == moveId then
      return { action = "fight", move = legal.move }
    end
  end
  return nil
end

-- ------------------------------------------------------------------
-- Gen 2
-- ------------------------------------------------------------------
--
-- Gold's AI is a friendlier thing to bridge than Red's: `Ai.choose` already
-- takes a plain context table rather than a `BattleState`, because the engine
-- built it that way for its own tests. So the adapter here is a context builder
-- and nothing else -- there is no synthetic battle object at all, and
-- `Battle:vanillaEnemyMove` is the shape being mirrored rather than a thing
-- being fooled.
--
-- Two of the cart's inputs have no counterpart in a `BattleSim` field and are
-- therefore left absent rather than guessed: the weather (the sim models none)
-- and the `usedMoves` history the switch heuristic scores matchups from. The
-- second is offered on the view (`playerUsedMoves`) for a caller that keeps it,
-- and its absence reads as a neutral matchup -- which `Ai.switchScore` answers
-- by not rotating, the conservative half of the wrong answer.

-- `spd` is the one key the two sims disagree about outright: Gen 1 spells Speed
-- with it, Gen 2 spells Sp.Def with it and puts Speed on `spe`. So the shape is
-- decided the same way `BattleSim2`'s own ingest decides it -- by whether the
-- Gen 2 keys are present at all -- rather than by falling back key by key,
-- which would quietly file a Gen 1 Speed stage as a Sp.Def one.
function M:_gen2Stages(simMon)
  local stages = (simMon and simMon.stages) or {}
  local gen2Shaped = stages.spe ~= nil or stages.spa ~= nil
  local speed = gen2Shaped and stages.spe or stages.spd
  local spAttack = gen2Shaped and stages.spa or stages.spc
  local spDefense = gen2Shaped and stages.spd or stages.spc
  return {
    attack = tonumber(stages.atk) or 0,
    defense = tonumber(stages.def) or 0,
    speed = tonumber(speed) or 0,
    specialAttack = tonumber(spAttack) or 0,
    specialDefense = tonumber(spDefense) or 0,
    accuracy = tonumber(stages.acc) or 0,
    evasion = tonumber(stages.eva) or 0,
  }
end

function M:_decideGen2(view)
  local eng = loadEngine()
  local Ai = eng and eng.Ai2
  if not Ai then return nil end
  local flags = Ai.flagsOf(self.trainer.attributes)

  -- AI_SwitchOrTryItem runs ahead of the move choice and can spend the turn.
  local spent = self:_gen2SwitchOrItem(view, flags)
  if spent then return spent end

  local legal = legalMoves(view.mon)
  if #legal == 0 then return nil end

  -- A class with no AI word picks at random, which is what AIChooseMove does
  -- when wEnemyTrainerAIFlags is zero -- and what a wild mon does. It is a real
  -- answer, not a fallback, so it is returned rather than declined.
  if flags == 0 then
    return { action = "fight", move = legal[self.rng(1, #legal)].move }
  end

  local mon, foe = view.mon, view.foe
  local data = self.data
  local chart = type(data.type_chart) == "table" and data.type_chart or {}
  local enemyTypes, playerTypes = self:_typesOf(mon), self:_typesOf(foe)

  local ok, chosen = pcall(Ai.choose, {
    moves = legal,
    moveDef = function(id) return data.moves[id] end,
    attacker = {
      level = tonumber(mon.level) or 1,
      stats = {
        attack = statOf(mon.stats, "atk") or 1,
        specialAttack = statOf(mon.stats, "spa", "spc") or 1,
      },
      types = enemyTypes,
    },
    defender = {
      hp = tonumber(foe.hp) or 0,
      stats = {
        defense = statOf(foe.stats, "def") or 1,
        specialDefense = statOf(foe.stats, "spd", "spc") or 1,
      },
      status = STATUS_TO_ENGINE[foe.status] or nil,
      confused = (tonumber(foe.confusion) or 0) > 0,
      types = playerTypes,
    },
    typeChart = chart,
    data = data,
    enemyHp = tonumber(mon.hp) or 0,
    enemyMaxHp = tonumber(mon.maxHp) or 1,
    enemyTurns = self.turns,
    playerTurns = tonumber(view.playerTurns) or self.turns,
    smart = self:_gen2Smart(view, enemyTypes, playerTypes),
    playerLastPower = self:_gen2LastPower(view),
    attackerStages = self:_gen2Stages(mon),
    defenderStages = self:_gen2Stages(foe),
    flags = flags,
    random = function(n) return self.rng(0, max(0, (tonumber(n) or 1) - 1)) end,
  })
  if not ok or type(chosen) ~= "string" then return nil end
  return self:_fightById(view, chosen)
end

-- Everything AI_Smart's seventy handlers read that a `BattleSim` field can
-- honestly answer. A field this sim does not model is simply absent, and the
-- engine's own comment on this table is that a missing field never fires its
-- branch -- so an omission costs one handler, never correctness.
function M:_gen2Smart(view, enemyTypes, playerTypes)
  local mon, foe, data = view.mon, view.foe, self.data
  local chart = type(data.type_chart) == "table" and data.type_chart or {}

  local knownEffects, moveIds = {}, {}
  for _, move in ipairs(mon.moves or {}) do
    moveIds[move.id] = true
    local def = data.moves[move.id]
    if def and def.effect then knownEffects[def.effect] = true end
  end

  local usedEffects, physical, special = {}, 0, 0
  local Damage2 = (loadEngine() or {}).Damage2
  local categories = chart.types
  for _, id in ipairs(view.playerUsedMoves or {}) do
    local def = data.moves[id]
    if def then
      if def.effect then usedEffects[def.effect] = true end
      if (tonumber(def.power) or 0) > 0 then
        local isPhysical = true
        if Damage2 and type(Damage2.isPhysical) == "function" then
          local ok, value = pcall(Damage2.isPhysical, def.type, categories)
          if ok then isPhysical = value and true or false end
        end
        if isPhysical then physical = physical + 1 else special = special + 1 end
      end
    end
  end

  local hasBench = false
  for _, member in ipairs(view.party or {}) do
    if member ~= mon and (tonumber(member.hp) or 0) > 0 then hasBench = true; break end
  end

  local playerSpecial = false
  if type(categories) == "table" then
    for _, id in ipairs(playerTypes) do
      local record = categories[id]
      if type(record) == "table" and record.category == "special" then
        playerSpecial = true
        break
      end
    end
  end

  return {
    enemyHp = tonumber(mon.hp) or 0,
    enemyMaxHp = tonumber(mon.maxHp) or 1,
    playerHp = tonumber(foe.hp) or 0,
    playerMaxHp = tonumber(foe.maxHp) or 1,
    enemyFaster = (statOf(mon.stats, "spe", "spd") or 0)
      > (statOf(foe.stats, "spe", "spd") or 0),
    enemyTurns = self.turns,
    playerTurns = tonumber(view.playerTurns) or self.turns,
    enemyStatus = STATUS_TO_ENGINE[mon.status] or nil,
    playerStatus = STATUS_TO_ENGINE[foe.status] or nil,
    playerToxic = foe.status == "toxic",
    enemyToxic = mon.status == "toxic",
    playerLeechSeed = foe.leechSeed ~= nil,
    enemyLeechSeed = mon.leechSeed ~= nil,
    playerCharged = foe.charging ~= nil,
    playerFlying = foe.invulnerable == true,
    enemyRage = mon.raging == true,
    enemySleepTurns = mon.status == "sleep" and (tonumber(mon.statusTurns) or 0) or nil,
    enemyHasBench = hasBench,
    stages = self:_gen2Stages(mon),
    playerStages = self:_gen2Stages(foe),
    knownEffects = knownEffects,
    enemyMoveIds = moveIds,
    enemyTypes = enemyTypes,
    playerTypes = playerTypes,
    playerSpecialType = playerSpecial,
    playerPhysicalMoves = physical,
    playerSpecialMoves = special,
    playerUsedEffects = usedEffects,
    playerMatchupScore = self:_gen2MatchupScore(view, enemyTypes),
  }
end

-- wLastPlayerCounterMove's base power, which two SMART handlers take as their
-- fifth argument. Only a caller that tracks the player's history can answer it.
function M:_gen2LastPower(view)
  local used = view.playerUsedMoves
  if type(used) ~= "table" or #used == 0 then return nil end
  local def = self.data.moves[used[#used]]
  return def and tonumber(def.power) or nil
end

-- CheckPlayerMoveTypeMatchups: one point off BASE_AI_SWITCH_SCORE for every
-- super-effective damaging move the player has *shown*. With no history the
-- score stays neutral, which reads to `Ai.switchScore` as "the player is not
-- winning the matchup" and therefore as no rotation.
function M:_gen2MatchupScore(view, enemyTypes)
  local eng = loadEngine()
  local Ai, Damage2 = eng and eng.Ai2, eng and eng.Damage2
  if not (Ai and Damage2 and type(Damage2.typeMultiplier) == "function") then
    return nil
  end
  local score = tonumber(Ai.BASE_SWITCH_SCORE) or 10
  local matchups = (type(self.data.type_chart) == "table")
    and self.data.type_chart.matchups or nil
  for _, id in ipairs(view.playerUsedMoves or {}) do
    local def = self.data.moves[id]
    if def and (tonumber(def.power) or 0) > 0 then
      local ok, mult = pcall(Damage2.typeMultiplier, def.type, enemyTypes, matchups)
      if ok and (tonumber(mult) or 10) > 10 then score = score - 1 end
    end
  end
  return score
end

-- AI_SwitchOrTryItem, in its own order: the rotation roll first, then the item.
-- Returns a choice when the turn was spent, nil when the AI wants to attack.
function M:_gen2SwitchOrItem(view, flags)
  local eng = loadEngine()
  local Ai, Damage2 = eng and eng.Ai2, eng and eng.Damage2
  if not Ai then return nil end
  local attributes = self.trainer.attributes
  if type(attributes) ~= "table" then return nil end

  local mon = view.mon
  -- The AI cannot rotate out of a wrap, the same pin that closes
  -- `TryPlayerSwitch`. The sim spells it `trapped` on the monster being held.
  local trapped = type(mon.trapped) == "table"
    and (tonumber(mon.trapped.turns) or 0) > 0

  if not trapped and Damage2 and type(Damage2.typeMultiplier) == "function" then
    local playerTypes = self:_typesOf(view.foe)
    local matchups = (type(self.data.type_chart) == "table")
      and self.data.type_chart.matchups or nil
    local bench = {}
    for index, member in ipairs(view.party or {}) do
      if member ~= mon and (tonumber(member.hp) or 0) > 0 then
        local memberTypes = self:_typesOf(member)
        local incomingOk, incoming = pcall(Damage2.typeMultiplier,
          playerTypes[1], memberTypes, matchups)
        local superEffective = false
        for _, move in ipairs(member.moves or {}) do
          local def = self.data.moves[move.id]
          if def and (tonumber(def.power) or 0) > 0 then
            local ok, mult = pcall(Damage2.typeMultiplier, def.type,
              playerTypes, matchups)
            if ok and (tonumber(mult) or 10) > 10 then
              superEffective = true
              break
            end
          end
        end
        bench[#bench + 1] = {
          index = index, mon = member, healthy = true,
          resists = incomingOk and (tonumber(incoming) or 10) < 10 or false,
          superEffective = superEffective,
        }
      end
    end

    local scoreOk, score, target = pcall(Ai.switchScore, {
      bench = bench,
      perishCount = tonumber(mon.perish),
      matchupScore = self:_gen2MatchupScore(view, self:_typesOf(mon)),
    })
    if scoreOk and target then
      local rollOk, wants = pcall(Ai.shouldSwitch, attributes, score,
        function(n) return self.rng(0, max(0, (tonumber(n) or 1) - 1)) end)
      if rollOk and wants then
        local chosen = (view.party or {})[target]
        if type(chosen) == "table" then
          return { action = "switch", slot = tonumber(chosen.slot) or 0 }
        end
      end
    end
  end

  -- AI_TryItem. Only the trainer's highest-level monster is worth an item.
  local highest = 0
  for _, member in ipairs(view.party or { mon }) do
    highest = max(highest, tonumber(member.level) or 0)
  end
  local itemOk, item = pcall(Ai.chooseItem, {
    items = self.items2 or {},
    isHighestLevel = (tonumber(mon.level) or 0) >= highest,
    hp = tonumber(mon.hp) or 0,
    maxHp = tonumber(mon.maxHp) or 1,
    status = STATUS_TO_ENGINE[mon.status] or nil,
    enemyTurns = self.turns,
  })
  if not itemOk or type(item) ~= "string" then return nil end
  if type(view.bag) == "table" and (tonumber(view.bag[item]) or 0) <= 0 then
    return nil
  end
  -- Spend it off this brain's own copy of the list, never off the registry
  -- record: a trainer with one POTION must not drink it every turn, and the
  -- trainer record outlives the battle.
  for index, id in ipairs(self.items2 or {}) do
    if id == item then table.remove(self.items2, index); break end
  end
  return { action = "item", item = item }
end

return M
