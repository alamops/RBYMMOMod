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

-- The engine's per-class record for this trainer, or nil.
--
-- Shared by itemsFor / bagFor / _usesFor so a third caller cannot resolve the
-- class one way and the budget another.
local function classOf(trainer, data)
  local eng = loadEngine()
  local TrainerAI = eng and eng.TrainerAI
  if not (TrainerAI and type(TrainerAI.classFor) == "function") then return nil end
  local ok, class = pcall(TrainerAI.classFor,
    { trainer = trainer, data = data })
  if ok and type(class) == "table" then return class end
  return nil
end

-- Every item id this trainer's AI could ever reach for.
--
-- Exported for the caller's benefit rather than used here: a `coop_npc` seat
-- whose `bag` sheet is set is held to it (`Turn._bagHas`). The ids come from
-- the trainer's own `items` list and, on Gen 1, the class's `item` -- not from
-- `Turn.DEFAULT_NPC_BAG`, which is a generic gym kit that made every Youngster
-- look like Brock.
function M.itemsFor(trainer, data, generation)
  local out = {}
  if type(trainer) ~= "table" then return out end
  -- Gen 3 keeps a trainer's kit as up to four numeric pret item ids (the
  -- engine trainer row's `items`, 0 for an empty slot) and has no class table
  -- to consult -- nor could it: the Gen 1 TrainerAI module is a boot error on
  -- Emerald.  So its answer is the list itself, zeros dropped.
  if generation == 3 then
    for _, id in ipairs(M.itemsOf3(trainer)) do out[#out + 1] = id end
    return out
  end
  local seen = {}
  local function put(id)
    if type(id) ~= "string" or id == "" or seen[id] then return end
    seen[id] = true
    out[#out + 1] = id
  end
  if generation == 2 or type(trainer.items) == "table" then
    for _, id in ipairs(trainer.items or {}) do put(id) end
  end
  local class = classOf(trainer, data)
  if class then put(class.item) end
  return out
end

-- The trainer's actual kit, as id → count.
--
-- Gen 2 (and any trainer that already carries an `items` list): each entry is
-- one use, the way AI_TryItem spends `trainer.items`. Gen 1 with no list: the
-- class's `item` × `uses`, which is what BattleState would have allowed -- a
-- bug catcher with uses = 0 carries nothing, a gym leader with uses = 2
-- carries two of their item. Empty when there is nothing to carry; never the
-- generic gym kit.
function M.bagFor(trainer, data, generation)
  local bag = {}
  if type(trainer) ~= "table" then return bag end
  -- Gen 3: one use per slot, keyed by the numeric id the BattleSim3 bag is
  -- keyed by (docs/plans/gen3-battle-sheet.md §4).
  if generation == 3 then
    for _, id in ipairs(M.itemsOf3(trainer)) do bag[id] = (bag[id] or 0) + 1 end
    return bag
  end
  if generation == 2 or type(trainer.items) == "table" then
    for _, id in ipairs(trainer.items or {}) do
      if type(id) == "string" and id ~= "" then
        bag[id] = (bag[id] or 0) + 1
      end
    end
  end
  if generation ~= 2 then
    local class = classOf(trainer, data)
    local item = class and class.item
    local uses = class and max(0, tonumber(class.uses) or 0) or 0
    if type(item) == "string" and item ~= "" and uses > 0 then
      bag[item] = max(bag[item] or 0, uses)
    end
  end
  return bag
end

-- bagFor as a `{id, count}` list the wire (and sendParty) already speaks.
function M.bagEntries(trainer, data, generation)
  local bag = M.bagFor(trainer, data, generation)
  local out = {}
  for id, count in pairs(bag) do
    out[#out + 1] = { id = id, count = count }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
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
  -- Gen 3 is built by its own constructor, before anything below asks for a
  -- dataset: its moves, types and stats all ride on the BattleSim3 sheets
  -- (docs/plans/gen3-battle-sheet.md), so there is no `data.moves` to need,
  -- and none of the Gen 1 / Gen 2 engine modules may be reached for at all.
  if tonumber(opts.generation) == 3
      or (opts.generation == nil and Gen.generation(game) == 3) then
    return M.new3(opts)
  end
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

  -- Three-way, not a clamp: Gen 3 left above through M.new3, so what reaches
  -- here is Gold (2) or Red -- and anything unrecognisable (a stub game with
  -- no generation) reads as Red, the build this file was first written for.
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
-- and, for a Gen 3 lone double only (absent on every 1v1, which then reads
-- exactly as it always has):
--
--   double          true
--   seat            the field slot of the trainer seat choosing (3 or 4)
--   partner         the trainer's other active battler, or nil
--   foes            { { slot = <field slot>, battler = <battler> }, ... }:
--                   the player's LIVING battlers, one or two
--   claimed         { [party index] = true }: what the sibling seat already
--                   switches or sends in this turn
--
-- Returns a choice in `Turn:submitChoice`'s vocabulary --
-- `{ action = "fight", move = <zero-based index> }`,
-- `{ action = "switch", slot = <the monster's own slot> }` or
-- `{ action = "item", item = <id> }` -- or nil when it has no answer, which is
-- a normal outcome and the caller's cue to call `Turn:autoPick`.
--
-- No `target` is stated in a 1v1. Solo seats one fighter per side there, so
-- the sim's own "first living foe" default is the only monster a choice could
-- mean, and naming a slot would only give the answer a second way to be
-- refused. A double names one -- `target = <field slot>` -- on a
-- single-target move only, since that is the one kind the referee aims by
-- the choice; a spread, self or random move is left to the referee's own
-- reading, as the cart's controller leaves it to the move's target byte.  A
-- Ghost's CURSE names the foe opposite the user, where the cart's AI curse
-- lands.
function M:choose(view)
  if type(view) ~= "table" then return nil end
  if type(view.mon) ~= "table" then return nil end
  -- A forced send-out is answered without ever looking across the field, and
  -- the seat opposite may be mid-replacement itself, so the far monster is
  -- required only for the choices that actually score against it.
  if not view.mustReplace and type(view.foe) ~= "table"
      and not (view.double and type(view.foes) == "table" and #view.foes > 0) then
    return nil
  end

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
  local class = classOf(self.trainer, self.data)
  if not class then return 0 end
  return max(0, tonumber(class.uses) or 0)
end

function M:_decide(view)
  -- A forced send-out is not a turn and the AI is never asked for one.
  -- EnemySendOutFirstMon walks the party from the top and fields the first
  -- monster that can still fight, which is also exactly what
  -- `TrainerAI.switchAction` picks when it rotates -- so both generations get
  -- the same one answer here.
  --
  -- Gen 3 is the exception: the cart's opponent controller sends out
  -- GetMostSuitableMonToSwitchInto, not the next monster in the party (see
  -- M:_replacement3), so its forced send-out is its own.
  if self.generation == 3 then return self:_decideGen3(view) end
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

-- ------------------------------------------------------------------
-- Gen 3
-- ------------------------------------------------------------------
--
-- FireRed / LeafGreen / Emerald trainers think with pret's AI *scripts*
-- (data/battle_ai_scripts.s, run by src/core/game3/battle/ai_vm.lua over the
-- engine's own battle state), and that is the one Gen 3 engine AI this file
-- does not bridge the way it bridges Red's TrainerAI and Gold's Ai: the VM
-- reads some sixty commands' worth of an engine `st` -- battle history, the
-- controller's per-battler records, the move table by ROM number -- and a copy
-- of *that* synthesised from a BattleSim3 field would be a second battle
-- state kept in step with the first, which is exactly the puppet the header
-- above argues against.
--
-- So the scripts are ported rather than driven.  What is kept from the cart is
-- the part a player can feel:
--
--   * **the trainer's own AI flags** (the engine trainer row's `aiFlags`, the
--     cart's gTrainers[].aiFlags) pick which scripts run, bit for bit through
--     the version's own layout -- FireRed numbers CHECK_VIABILITY 1 /
--     TRY_TO_FAINT 2, Emerald the other way round, and Emerald adds
--     PREFER_POWER_EXTREMES and TRY_SUNNY_DAY_START -- read from the engine's
--     battle profile.  A youngster with CHECK_BAD_MOVE alone and a gym leader
--     with half the bits set fight differently for the reason they do on the
--     cart; a trainer with no bits at all picks among its usable moves at
--     random, which is what an empty script list does there (and what Gold's
--     bridge does for a class with no AI word);
--   * **scoring**: every usable move starts at 100 and each script moves it
--     (AI_CheckBadMove's -8 / -10 / -12, TryToFaint's +4, SetupFirstTurn's
--     +2 ...), the simulated 85..100 damage roll per move
--     (AI_THINKING_STRUCT->simulatedRNG), and the best score wins, ties drawn
--     at random;
--   * **ShouldSwitch and ShouldUseItem** (battle_ai_switch_items.c, the
--     engine's ai_switch.lua / ai_items.lua) ahead of the move, and
--     GetMostSuitableMonToSwitchInto for a send-out -- including the cart's
--     own backwards typing test, because a faithful opponent is the point;
--   * and everything a Gen 3 script reads that Gen 2's never could:
--     abilities (Levitate, Volt / Water Absorb, Flash Fire, Wonder Guard,
--     Soundproof, Sturdy, Damp, Insomnia, Limber, Own Tempo, Clear Body, Hyper
--     Cutter, Keen Eye, Oblivious, Suction Cups, Immunity, Water Veil, Shadow
--     Tag / Arena Trap / Magnet Pull, Natural Cure), the weather (Thunder,
--     SolarBeam, Weather Ball, the sun-scaled heals, the four weather moves,
--     Swift Swim / Chlorophyll), and held items (their damage boosts through
--     the sim's own formula, Choice Band's lock, Thief / Trick / Knock Off
--     only against something held);
--   * **a lone double** the way each family plays one (M:_chooseDouble3):
--     FireRed / LeafGreen aim at a random foe and score against it, Emerald
--     scores every move against every battler -- its own partner included --
--     and takes the best target; Emerald's AI_DoubleBattle and AI_TryOnAlly
--     (M:_doubleBattle3, M:_tryOnAlly3); and a switch or send-out that never
--     names either seat's active or the sibling seat's claim (M:_benchable3).
--
-- The damage every script asks about is the referee's own pure formula
-- (BattleSim3/Damage.calc) over the referee's own battlers -- stages, screens,
-- weather, abilities and held items included -- called with no generator, so
-- asking never draws from the fight's RNG and the fight stays reproducible
-- from its seed.
--
-- The view carries the sim (`view.sim`, `view.battler`, `view.foeBattler`)
-- when SoloBattle builds it; a view of bare sheets (a suite, a caller with
-- only the monsters) is read through a battler-shaped copy with neutral
-- stages, so the brain answers either way.

local sim3
local function Sim3()
  if sim3 == nil then
    local parts, all = {}, true
    for key, name in pairs({
      Types = "BattleSim3/Types", Damage = "BattleSim3/Damage",
      Effects = "BattleSim3/Effects", Items = "BattleSim3/Items",
      Abilities = "BattleSim3/Abilities",
    }) do
      local ok, value = pcall(need, name)
      if ok and type(value) == "table" then parts[key] = value else all = false end
    end
    sim3 = all and parts or false
    if not all then
      warnOnce("sim3", "the mod's Gen 3 battle modules (src/BattleSim3/) did not "
        .. "load, so solo trainers on this cart fight with the referee's generic "
        .. "picker; reinstall the mod folder so every file under src/ is present")
    end
  end
  return sim3 or nil
end

-- FireRed / LeafGreen's AI_SCRIPT_* bit numbers (pokefirered/include/
-- constants/battle_ai.h:37, the engine profile's FRLG_AI_BITS), the fallback
-- when the engine's battle profile cannot be asked.
M.AI_BITS_FRLG = {
  CHECK_BAD_MOVE = 0, CHECK_VIABILITY = 1, TRY_TO_FAINT = 2, SETUP_FIRST_TURN = 3,
  RISKY = 4, PREFER_STRONGEST_MOVE = 5, PREFER_BATON_PASS = 6, DOUBLE_BATTLE = 7,
  HP_AWARE = 8,
}

-- The running cart's bit layout: the engine battle profile's `aiFlagBits`
-- (Emerald's differs from FireRed's), reached through src/Gen3.lua so it is
-- only ever required on a Gen 3 boot.
local function aiBitsOf3()
  local okG, Gen3 = pcall(need, "Gen3")
  if not (okG and type(Gen3) == "table" and type(Gen3.engine) == "function") then
    return M.AI_BITS_FRLG
  end
  local BP = Gen3.engine("src.core.game3.battle.profile")
  if not (BP and type(BP.get) == "function") then return M.AI_BITS_FRLG end
  local ok, bp = pcall(BP.get, Gen3.session and Gen3.session() or nil)
  if ok and type(bp) == "table" and type(bp.aiFlagBits) == "table" then
    return bp.aiFlagBits
  end
  return M.AI_BITS_FRLG
end

local function bitSet(flags, bit)
  if type(bit) ~= "number" then return false end
  return math.floor((tonumber(flags) or 0) / (2 ^ bit)) % 2 == 1
end

local function int3(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return math.floor(n)
end

-- A Gen 3 trainer's items: the numeric ids in the engine row's `items` (four
-- slots, 0 for an empty one), in slot order.  Exported for SoloBattle and the
-- bag helpers above.
function M.itemsOf3(trainer)
  local out = {}
  if type(trainer) ~= "table" or type(trainer.items) ~= "table" then return out end
  for _, raw in ipairs(trainer.items) do
    local id = int3(raw, nil)
    if id and id > 0 then out[#out + 1] = id end
  end
  return out
end

-- Which cart's AI scripts a bit layout belongs to.  The engine runs the
-- cart's own scripts (battle/ai.lua over the imported script pack), and the
-- two families' differ past their numbering -- FireRed's AI_TryToFaint has no
-- 4x bonus, Emerald's AI_CheckBadMove sends FISSURE and HORN DRILL to the
-- immunity checks, slot 5 is PREFER_STRONGEST_MOVE on one and
-- PREFER_POWER_EXTREMES on the other -- so the layout the running cart's
-- battle profile hands over (`aiFlagBits`) says which set this is: only
-- Emerald's names PREFER_POWER_EXTREMES / TRY_SUNNY_DAY_START.
function M.aiFamily3(bits)
  if type(bits) == "table" and (bits.PREFER_POWER_EXTREMES ~= nil
      or bits.TRY_SUNNY_DAY_START ~= nil) then
    return "rse"
  end
  return "frlg"
end

-- opts (beyond M.new's): trainer (the engine trainer record: `aiFlags`,
-- `items`), aiFlags (override), aiBits (a bit layout, for a suite), family
-- ("frlg" | "rse", override; else read off the layout, M.aiFamily3).
function M.new3(opts)
  opts = opts or {}
  local trainer = opts.trainer or M.trainerOf(opts.engine)
  if type(trainer) ~= "table" then
    return nil, "this battle has no trainer record, so there is no AI to bridge"
  end
  if not Sim3() then
    return nil, "the mod's Gen 3 battle modules are unavailable"
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
  local flags = tonumber(opts.aiFlags) or tonumber(trainer.aiFlags) or 0
  local bits = type(opts.aiBits) == "table" and opts.aiBits or aiBitsOf3()
  local family = (opts.family == "rse" or opts.family == "frlg") and opts.family
    or M.aiFamily3(bits)
  local self = setmetatable({
    generation = 3,
    trainer = trainer,
    rng = rng,
    aiFlags = math.max(0, math.floor(flags)),
    aiBits = bits,
    family3 = family,
    aiUses = 0, aiLayer2 = 0, turns = 0, lastMon = nil,
    -- battleHistory->trainerItems: the four slots, spent to 0 as they are
    -- used, never compacted (ShouldUseItem's slot arithmetic reads the gaps).
    items3 = M.itemsOf3(trainer),
    itemsNo3 = #M.itemsOf3(trainer),
  }, M)
  return self
end

-- `flags`, when given, is the set a fight actually runs (ctx.aiFlags: an
-- Emerald double's has DOUBLE_BATTLE ORed in); else the trainer's own.
function M:_flag3(name, flags)
  return bitSet(flags or self.aiFlags, self.aiBits and self.aiBits[name])
end

-- ------- reading the field

local STAGE_ZERO = { atk = 0, def = 0, spe = 0, spa = 0, spd = 0, acc = 0, eva = 0 }

-- A battler-shaped reading of a bare sheet (no sim in the view).
local function pseudoBattler(mon, S, side)
  if type(mon) ~= "table" then return nil end
  local types = type(mon.types) == "table" and mon.types or {}
  local t1 = int3(types[1], 0)
  local t2 = int3(types[2], nil)
  if t2 == t1 then t2 = nil end
  local stages = {}
  for k, v in pairs(STAGE_ZERO) do stages[k] = v end
  return {
    mon = mon, stats = type(mon.stats) == "table" and mon.stats or {},
    moves = type(mon.moves) == "table" and mon.moves or {},
    stages = stages, type1 = t1, type2 = t2,
    ability = S.Abilities.nameOf(mon.ability), abilityName = mon.abilityName,
    speciesNum = mon.speciesNum, side = side, isFirstTurn = 0,
  }
end

function M:_ctx3(view)
  local S = Sim3()
  if not S then return nil end
  local sim = type(view.sim) == "table" and view.sim or nil
  local b = type(view.battler) == "table" and view.battler or pseudoBattler(view.mon, S, "b")
  if not b then return nil end
  local t = type(view.foeBattler) == "table" and view.foeBattler
    or pseudoBattler(view.foe, S, "a")
  local typeTable = (sim and sim.typeTable) or view.typeTable
  local weather = view.weather
  if weather == nil and sim and type(sim.weather) == "function" then
    local ok, w = pcall(sim.weather, sim)
    if ok then weather = w end
  end
  local function sideOf(side)
    if sim and type(sim.sides) == "table" and sim.sides[side] then return sim.sides[side] end
    return {}
  end
  local ctx = {
    S = S, sim = sim, b = b, t = t,
    typeTable = typeTable, specialTypes = sim and sim.specialTypes or nil,
    weather = weather,
    party = type(view.party) == "table" and view.party or { view.mon },
    active = tonumber(view.active),
    bag = type(view.bag) == "table" and view.bag or nil,
    mySide = sideOf(b.side or "b"),
    foeSide = sideOf((t and t.side) or "a"),
    -- gBattleResults.battleTurnCounter: 0 on the fight's first turn.
    turnCount = math.max(0, (tonumber(sim and sim.turn) or tonumber(view.turn) or 1) - 1),
    -- The scripts this fight runs: the trainer's own, unless a double adds one.
    aiFlags = self.aiFlags,
  }
  if view.double then self:_double3(ctx, view) end
  return ctx
end

local function hpOf(b) return int3(b and b.mon and b.mon.hp, 0) end
local function maxHpOf(b) return math.max(1, int3(b and b.mon and b.mon.maxHp, 1)) end
local function pct(b) return math.floor(hpOf(b) * 100 / maxHpOf(b)) end
local function statusOf3(b)
  local s = b and b.mon and b.mon.status
  if type(s) ~= "string" or s == "" then return nil end
  return s:upper()
end
local function hasType(b, t) return b ~= nil and (b.type1 == t or b.type2 == t) end

-- A view's battler, or a bare sheet read as one (a suite's hand-built view).
local function asBattler(x, S, side)
  if type(x) ~= "table" then return nil end
  if type(x.mon) == "table" then return x end
  return pseudoBattler(x, S, side)
end

-- The double's half of the reading (the C2 view, docs/plans/gen3-solo-doubles.md).
--
--   foes      the player's living battlers as { slot, b }, by field slot --
--             pret battler order puts the player's left (slot 0) before its
--             right (slot 1), and every loop below walks them that way
--   partner   the trainer's other active battler (nil when that position is
--             empty), partnerSlot its field slot
--   claimed   party indices the sibling seat is already sending in
--   attacker  gBattleMons[gLastHitBy[battler]]: whoever stands where the
--             battler that last hit us stood -- the cart reads the position,
--             not the monster, and keeps reading it after a faint (the
--             fainted mon's data is never cleared)
--   t         the first foe, until a target rule picks one
--
-- And the scripts: Emerald's BattleAI_SetupAIData ORs AI_SCRIPT_DOUBLE_BATTLE
-- into every double's flags (pokeemerald battle_ai_script_commands.c:378, the
-- engine's ai.lua:472); FireRed / LeafGreen run the trainer's own flags only,
-- whose DOUBLE_BATTLE bit no trainer row on either cart sets -- and whose
-- AI_DoubleBattle is a bare `end` either way (see M:_doubleBattle3).
function M:_double3(ctx, view)
  local S = ctx.S
  local foes = {}
  for _, entry in ipairs(type(view.foes) == "table" and view.foes or {}) do
    if type(entry) == "table" then
      local fb = asBattler(entry.battler or entry.mon, S, "a")
      local slot = fb and (int3(entry.slot, nil) or int3(fb.slot, nil))
      if slot and hpOf(fb) > 0 then foes[#foes + 1] = { slot = slot, b = fb } end
    end
  end
  table.sort(foes, function(x, y) return x.slot < y.slot end)
  ctx.double = true
  ctx.foes = foes
  ctx.seat = int3(view.seat, nil) or int3(ctx.b.slot, nil)
  local partner = asBattler(view.partner, S, ctx.b.side or "b")
  if partner and hpOf(partner) <= 0 then partner = nil end
  ctx.partner = partner
  ctx.partnerSlot = (partner and int3(partner.slot, nil)) or (ctx.seat == 4 and 3 or 4)
  ctx.claimed = type(view.claimed) == "table" and view.claimed or {}
  local hit = ctx.b.lastHitBy
  if type(hit) == "table" then
    ctx.attacker = (type(hit.fighter) == "table" and hit.fighter.b) or hit
  end
  if foes[1] then ctx.t = foes[1].b end
  if self.family3 == "rse" then
    local bit = self.aiBits and self.aiBits.DOUBLE_BATTLE
    if type(bit) == "number" and not bitSet(ctx.aiFlags, bit) then
      ctx.aiFlags = ctx.aiFlags + 2 ^ bit
    end
  end
end

-- May this party member be sent in?  Alive, not the battler choosing -- and,
-- in a double, not the partner's active either, nor what the sibling seat
-- already claimed this turn: GetMostSuitableMonToSwitchInto and every
-- ShouldSwitch finder skip gBattlerPartyIndexes of both battlerIn1 and
-- battlerIn2 and both seats' monToSwitchIntoId (pret battle_ai_switch_items.c,
-- the engine's ai_switch.lua `excluded`).
function M:_benchable3(ctx, index, mon)
  if mon == ctx.b.mon or int3(mon.hp, 0) <= 0 then return false end
  if ctx.partner and mon == ctx.partner.mon then return false end
  if ctx.claimed and ctx.claimed[index] then return false end
  return true
end

-- The battler at the other position of `battler`'s side, read the way the
-- cart's gBattleMons is: whoever stands there, else whoever last stood there
-- (a fainted mon's types and ability stay in the struct), else nil -- a
-- position that was never filled, which the cart reads as zeroes: no
-- ability, Normal type.
function M:_flankmate3(ctx, battler)
  if not battler then return nil end
  if battler == ctx.b then
    if ctx.partner then return ctx.partner end
  elseif battler == ctx.partner then
    return ctx.b
  else
    local mine = false
    for _, foe in ipairs(ctx.foes or {}) do
      if foe.b == battler then mine = true end
    end
    if mine then
      for _, foe in ipairs(ctx.foes) do
        if foe.b ~= battler then return foe.b end
      end
    end
  end
  local fighter, sim = battler.fighter, ctx.sim
  if not (sim and type(fighter) == "table" and type(sim.bySide) == "table") then return nil end
  for _, other in ipairs(sim.bySide[fighter.side] or {}) do
    if other ~= fighter then return other.b or other.lastB end
  end
  return nil
end

-- One of the player's two positions at random, flipped to the other when
-- that one is empty: BattleAI_SetupAIData's FireRed target
-- (`Random() & BIT_FLANK`, the engine's ai.lua:280-282) and the opponent
-- GetMostSuitableMonToSwitchInto types a double's send-out against
-- (battle_ai_switch_items.c:448).  The roll is drawn even when only one
-- position stands, as the cart draws it.
function M:_flankFoe3(ctx)
  local want = self.rng(0, 1)
  local other = nil
  for _, foe in ipairs(ctx.foes or {}) do
    if foe.slot == want then return foe end
    other = other or foe
  end
  return other
end

-- The move's type as it will be dealt: Hidden Power's own, Weather Ball's
-- weather (pret Cmd_weatherdamage / the engine's typing), else the row's.
function M:_moveType3(ctx, user, mv)
  local S, E = ctx.S, ctx.S.Effects.E
  local eff = int3(mv.effect, 0)
  if eff == E.HIDDEN_POWER then
    local hp = user and user.mon and user.mon.hiddenPower
    if type(hp) == "table" and tonumber(hp.type) then return int3(hp.type, 0) end
  elseif eff == E.WEATHER_BALL and ctx.weather then
    local T = S.Types.ID
    local by = { RAIN = T.WATER, SUN = T.FIRE, SAND = T.ROCK, HAIL = T.ICE }
    if by[ctx.weather] then return by[ctx.weather] end
  end
  return int3(mv.type, 0)
end

-- The chart's product for a type against a battler (100 neutral, 0 immune).
function M:_product3(ctx, moveType, target)
  if not target then return 100 end
  local ok, product = pcall(ctx.S.Types.effectivenessOf, ctx.typeTable, moveType,
    target.type1, target.type2, target.identified and true or false)
  if ok and tonumber(product) then return tonumber(product) end
  return 100
end

-- EFFECT_* ids whose damage ignores the row's power, from BattleSim3's own
-- effect table the first time a Gen 3 fight asks.
local fixedDamage
local function fixedSet(E)
  if not fixedDamage then
    fixedDamage = {}
    for _, name in ipairs({ "SUPER_FANG", "DRAGON_RAGE", "LEVEL_DAMAGE", "PSYWAVE",
                            "SONICBOOM", "COUNTER", "MIRROR_COAT", "ENDEAVOR" }) do
      if E[name] then fixedDamage[E[name]] = true end
    end
  end
  return fixedDamage
end

-- Does this move deal damage at all?  Any power, or a fixed / one-hit KO
-- effect.  (pret's power *reading*, below, is stricter: it counts only
-- power > 1, which leaves Return, Flail, Hidden Power ... "other".)
local function isDamaging(mv, E)
  local eff = int3(mv.effect, 0)
  if fixedSet(E)[eff] or eff == E.OHKO then return true end
  return int3(mv.power, 0) > 0
end

-- AI_CBM_CheckIfNegatesType, and Soundproof: would this move do nothing at
-- all to `target`?  Returns the pret score change (-10 / -12) or nil.
function M:_negated3(ctx, user, target, mv)
  if not target then return nil end
  local S = ctx.S
  local E, T = S.Effects.E, S.Types.ID
  local ab = target.ability
  if ab == "SOUNDPROOF" and S.Abilities.SOUND_MOVES[int3(mv.num, -1)] then return -10 end
  if not isDamaging(mv, E) then return nil end
  local mtype = self:_moveType3(ctx, user, mv)
  if self:_product3(ctx, mtype, target) == 0 then return -10 end
  local power = int3(mv.power, 0)
  if ab == "VOLT_ABSORB" and mtype == T.ELECTRIC and power ~= 0 then return -12 end
  if ab == "WATER_ABSORB" and mtype == T.WATER and power ~= 0 then return -12 end
  if ab == "FLASH_FIRE" and mtype == T.FIRE then return -12 end
  if ab == "LEVITATE" and mtype == T.GROUND then return -10 end
  if ab == "WONDER_GUARD" and int3(mv.num, 0) ~= 165
      and self:_product3(ctx, mtype, target) <= 100 then
    return -10
  end
  return nil
end

-- pret MOVE_FISSURE / MOVE_HORN_DRILL: Emerald's AI_CheckBadMove names these
-- two (and not GUILLOTINE or SHEER COLD) for its immunity checks.
local MOVE_HORN_DRILL, MOVE_FISSURE = 32, 90

-- pret get_how_powerful_move_is's MOVE_POWER_DISCOURAGED (the engine's
-- ai_cmds.lua): a move of power 1 or less (status moves, the fixed-damage
-- and one-hit KO rows, Counter, Hidden Power), or one of
-- sDiscouragedPowerfulMoveEffects.
local function discouraged3(mv, G)
  return int3(mv.power, 0) <= 1 or G.discouraged[int3(mv.effect, 0)] == true
end

-- Does AI_CheckBadMove put this move through AI_CBM_CheckIfNegatesType (the
-- type immunity, the absorbing abilities, WONDER GUARD, LEVITATE)?  Only a
-- move the power reading does not call DISCOURAGED -- and, on Emerald,
-- FISSURE and HORN DRILL, which it names first.  Every other move goes
-- straight to the SOUNDPROOF check.
function M:_negationChecked3(mv, G)
  local num = int3(mv.num, 0)
  if self.family3 == "rse" and (num == MOVE_FISSURE or num == MOVE_HORN_DRILL) then
    return true
  end
  return not discouraged3(mv, G)
end

-- What this move would take off `target` this turn, on the referee's own
-- formula, with `roll` as the damage roll (85..100) and no critical hit.  Zero
-- for a move the target's typing or ability swallows.
function M:_damage3(ctx, user, target, mv, roll)
  if not (user and target and type(mv) == "table") then return 0 end
  local S = ctx.S
  local E = S.Effects.E
  if self:_negated3(ctx, user, target, mv) then return 0 end
  local eff = int3(mv.effect, 0)
  if eff == E.OHKO then
    if target.ability == "STURDY" then return 0 end
    if int3(target.mon.level, 1) > int3(user.mon.level, 1) then return 0 end
    return hpOf(target)
  end
  local side = (ctx.sim and ctx.sim.sides and ctx.sim.sides[target.side]) or {}
  local ok, dmg = pcall(S.Damage.calc, user, target, mv, {
    typeTable = ctx.typeTable, specialTypes = ctx.specialTypes, weather = ctx.weather,
    reflect = int3(side.reflectTurns, 0) > 0, lightScreen = int3(side.lightScreenTurns, 0) > 0,
    noCrit = true, forceRoll = roll or 100, magnitudeRoll = 50, psywaveRoll = 5,
    defenderId = target.slot,
  })
  if not ok then return 0 end
  dmg = int3(dmg, 0) or 0
  -- The two-strike moves the formula prices once.
  if eff == E.DOUBLE_HIT or eff == E.TWINEEDLE then dmg = dmg * 2 end
  if eff == E.MULTI_HIT then dmg = dmg * 3 end
  return math.max(0, dmg)
end

-- The usable slots (1-based into the battler's current move list): the
-- referee's own moveLimitations when the view carries the sim -- Disable,
-- Taunt, Torment, Imprison, Encore, Choice Band, empty PP -- else PP alone.
function M:_legal3(ctx)
  local b = ctx.b
  local moves = type(b.moves) == "table" and b.moves or {}
  local bad = {}
  local sim = ctx.sim
  if sim and type(sim.moveLimitations) == "function" and b.fighter then
    local ok, got = pcall(sim.moveLimitations, sim, b)
    if ok and type(got) == "table" then bad = got end
  else
    for i, mv in ipairs(moves) do
      if int3(mv.pp, 0) <= 0 or int3(mv.num, 1) == 0 then bad[i] = true end
    end
  end
  local out = {}
  for i = 1, #moves do
    if not bad[i] then out[#out + 1] = i end
  end
  return out
end

-- ------- the decision

function M:_decideGen3(view)
  local ctx = self:_ctx3(view)
  if not ctx then return nil end
  if view.mustReplace then
    local pick = self:_replacement3(ctx)
    if not pick then return nil end
    return { action = "switch", slot = int3(pick.slot, 0) }
  end
  if not ctx.t then return nil end

  -- A seat the referee has already locked (recharge, a rampage, a two-turn
  -- release) owes it nothing and is not asked; one with nothing usable is
  -- Struggle, which the referee reads off any index.
  local legal = self:_legal3(ctx)
  if #legal == 0 then return { action = "fight", move = 0 } end

  -- battle_main.c:3125 HandleAction: ShouldSwitch, then ShouldUseItem, then
  -- the move.  Wild fights never reach this file (no trainer record).
  local switch = self:_shouldSwitch3(ctx)
  if switch then return switch end
  local item = self:_shouldUseItem3(ctx)
  if item then return item end
  if ctx.double then return self:_chooseDouble3(ctx, legal) end
  return self:_chooseMove3(ctx, legal)
end

-- ------- ShouldSwitch (battle_ai_switch_items.c:302, engine ai_switch.lua)

function M:_superMove3(ctx, user, target, moves)
  local E = ctx.S.Effects.E
  for _, mv in ipairs(moves or {}) do
    if int3(mv.num, 0) ~= 0 and isDamaging(mv, E)
        and self:_product3(ctx, self:_moveType3(ctx, user, mv), target) > 100
        and not self:_negated3(ctx, user, target, mv) then
      return true
    end
  end
  return false
end

-- HasSuperEffectiveMoveAgainstOpponents with noRng (pret
-- battle_ai_switch_items.c:176): the move list hits the battler opposite, or
-- in a double either of the player's, super effectively.
function M:_superAgainstFoes3(ctx, user, moves)
  for _, foe in ipairs(self:_opponents3(ctx)) do
    if self:_superMove3(ctx, user, foe, moves) then return true end
  end
  return false
end

-- The battlers ShouldSwitch reads across the field: the one opposite, or a
-- double's living foes in pret battler order (the engine's ai_switch.lua
-- has_super_effective: the left position, then the right).
function M:_opponents3(ctx)
  if not ctx.double then return { ctx.t } end
  local out = {}
  for _, foe in ipairs(ctx.foes) do out[#out + 1] = foe.b end
  return out
end

function M:_bench3(ctx)
  local out = {}
  for index, mon in ipairs(ctx.party) do
    if self:_benchable3(ctx, index, mon) then out[#out + 1] = { index = index, mon = mon } end
  end
  return out
end

-- The player's move that last landed on our battler (pret expLastLandedMove),
-- as a row: the player's own move list carries it -- in a double, the list
-- of whoever landed it first, then either foe's.
function M:_lastLanded3(ctx)
  local num = int3(ctx.b.lastLandedMove, 0)
  if num == 0 then return nil end
  local sources = { ctx.t }
  if ctx.double then
    sources = {}
    if ctx.attacker then sources[1] = ctx.attacker end
    for _, foe in ipairs(ctx.foes) do sources[#sources + 1] = foe.b end
  end
  for _, src in ipairs(sources) do
    for _, mv in ipairs(src.moves or {}) do
      if int3(mv.num, -1) == num then return mv end
    end
    local mon = src.mon
    for _, mv in ipairs((mon and mon.moves) or {}) do
      if int3(mv.num, -1) == num then return mv end
    end
  end
  if ctx.b.lastHitByType ~= nil then
    return { num = num, type = ctx.b.lastHitByType, power = 2, effect = 0 }
  end
  return nil
end

-- ShouldSwitch's own reading of "held in" (the engine's ai_switch.lua
-- shouldSwitch, pret battle_ai_switch_items.c:302), which is not the rule the
-- referee enforces and is ported as the cart wrote it: an ARENA TRAP anywhere
-- on the opposing side holds the AI's mon in even when it is a Flying type or
-- levitates, and a MAGNET PULL anywhere on the field -- its own side's, its
-- own -- holds a Steel type in.  (SHADOW TAG: any opposing one.)
function M:_aiTrapped3(ctx)
  local b, S = ctx.b, ctx.S
  local field = {}
  local sim = ctx.sim
  if sim and type(sim.fighters) == "table" then
    for _, fighter in ipairs(sim.fighters) do
      if fighter.b then field[#field + 1] = fighter.b end
    end
  elseif ctx.double then
    field = { b }
    if ctx.partner then field[#field + 1] = ctx.partner end
    for _, foe in ipairs(ctx.foes) do field[#field + 1] = foe.b end
  else
    field = { b, ctx.t }
  end
  local steel = hasType(b, S.Types.ID.STEEL)
  for _, o in ipairs(field) do
    if o then
      local a = o.ability
      if o ~= b and o.side ~= b.side and (a == "SHADOW_TAG" or a == "ARENA_TRAP") then
        return true
      end
      if a == "MAGNET_PULL" and steel then return true end
    end
  end
  return false
end

-- FindMonWithFlagsAndSuperEffective (pret battle_ai_switch_items.c:236, the
-- engine's find_mon_with_flags): a bench mon the move that last landed on us
-- could not touch (`flag` "immune") or barely scratches ("notVery"), holding
-- a move that hits back super effectively -- each such move a 1-in-`modulo`
-- roll.  nil when the last hit was nothing or a status move.  "Hits back" is
-- against gBattleMons[gLastHitBy]: the one foe in a 1v1, and in a double
-- whoever stands where the last hit came from (ctx.attacker).
function M:_findMonWithFlags3(ctx, bench, last, flag, modulo)
  if not (last and int3(last.power, 0) > 0 and ctx.b.lastHitBy ~= nil) then return nil end
  local S, attacker = ctx.S, (ctx.double and ctx.attacker) or ctx.t
  for _, entry in ipairs(bench) do
    local pb = pseudoBattler(entry.mon, S, ctx.b.side)
    local product = self:_product3(ctx, int3(last.type, 0), pb)
    local immune = product == 0 or (self:_negated3(ctx, attacker, pb, last) ~= nil)
    local hit = (flag == "immune" and immune)
      or (flag == "notVery" and not immune and product < 100)
    if hit then
      for _, mv in ipairs(entry.mon.moves or {}) do
        if self:_superMove3(ctx, pb, attacker, { mv }) and self.rng(0, modulo - 1) == 0 then
          return entry
        end
      end
    end
  end
  return nil
end

function M:_shouldSwitch3(ctx)
  local b, t, S = ctx.b, ctx.t, ctx.S
  local sim = ctx.sim
  -- Trapped: Mean Look / Spider Web / Block, a partial trap, Ingrain (the
  -- referee's own reading) -- and the three trapping abilities, the AI's way.
  if sim and b.fighter then
    local okT, trapped = pcall(sim.isTrapped, sim, b)
    if okT and trapped then return nil end
  end
  if self:_aiTrapped3(ctx) then return nil end
  local bench = self:_bench3(ctx)
  if #bench == 0 then return nil end
  local rng = self.rng

  local function to(entry)
    if not entry then
      entry = self:_replacement3(ctx)
      if not entry then return nil end
      return { action = "switch", slot = int3(entry.slot, 0) }
    end
    return { action = "switch", slot = int3(entry.mon.slot, 0) }
  end

  -- ShouldSwitchIfPerishSong: the count has run out.
  if b.perishTurns ~= nil and int3(b.perishTurns, 1) == 0 then return to(nil) end

  -- ShouldSwitchIfWonderGuard: nothing of ours gets past it, a bench mon's
  -- does (each super-effective find rolls 2-in-3).  Singles only: the cart's
  -- returns FALSE in a double before it looks (battle_ai_switch_items.c:32,
  -- the engine's if_wonder_guard).
  if not ctx.double and t and t.ability == "WONDER_GUARD"
      and not self:_superMove3(ctx, b, t, b.moves) then
    for _, entry in ipairs(bench) do
      local pb = pseudoBattler(entry.mon, S, b.side)
      for _, mv in ipairs(entry.mon.moves or {}) do
        if self:_superMove3(ctx, pb, t, { mv }) and rng(0, 2) < 2 then return to(entry) end
      end
    end
  end

  local last = self:_lastLanded3(ctx)
  -- FindMonThatAbsorbsOpponentsMove.  Its HasSuperEffectiveMoveAgainst-
  -- Opponents(TRUE) asks both of a double's foes.
  do
    local skip = (self:_superAgainstFoes3(ctx, b, b.moves) and rng(0, 2) ~= 0) or last == nil
    if not skip and int3(last.power, 0) > 0 then
      local T = S.Types.ID
      local mt = int3(last.type, 0)
      local absorb = (mt == T.FIRE and "FLASH_FIRE") or (mt == T.WATER and "WATER_ABSORB")
        or (mt == T.ELECTRIC and "VOLT_ABSORB") or nil
      if absorb and b.ability ~= absorb then
        for _, entry in ipairs(bench) do
          if S.Abilities.nameOf(entry.mon.ability) == absorb and rng(0, 1) == 1 then
            return to(entry)
          end
        end
      end
    end
  end

  -- ShouldSwitchIfNaturalCure (the engine's if_natural_cure): asleep, NATURAL
  -- CURE, at half HP or more.  Nothing has landed (or a status move did): a
  -- coin flip -- the cart's `else if` flips a second coin when the first one
  -- missed, since "nothing" has no power either.  Else a bench mon the last
  -- hit could not touch, or barely scratched, with a super-effective answer
  -- (no roll), and last a third coin.
  if statusOf3(b) == "SLP" and b.ability == "NATURAL_CURE"
      and hpOf(b) >= math.floor(maxHpOf(b) / 2) then
    if last == nil and rng(0, 1) == 1 then return to(nil) end
    if (last == nil or int3(last.power, 0) == 0) and rng(0, 1) == 1 then return to(nil) end
    local found = self:_findMonWithFlags3(ctx, bench, last, "immune", 1)
      or self:_findMonWithFlags3(ctx, bench, last, "notVery", 1)
    if found then return to(found) end
    if rng(0, 1) == 1 then return to(nil) end
  end

  -- HasSuperEffectiveMoveAgainstOpponents (9-in-10 per find; a double's
  -- second foe after the first), or boosted.
  for _, foe in ipairs(self:_opponents3(ctx)) do
    for _, mv in ipairs(b.moves or {}) do
      if self:_superMove3(ctx, b, foe, { mv }) and rng(0, 9) ~= 0 then return nil end
    end
  end
  local raised = 0
  for _, v in pairs(b.stages or {}) do
    if (tonumber(v) or 0) > 0 then raised = raised + v end
  end
  if raised > 3 then return nil end

  -- FindMonWithFlagsAndSuperEffective: a bench mon the last hit could not
  -- touch (1-in-2), then one it barely scratches (1-in-3).
  local found = self:_findMonWithFlags3(ctx, bench, last, "immune", 2)
    or self:_findMonWithFlags3(ctx, bench, last, "notVery", 3)
  if found then return to(found) end
  return nil
end

-- ------- GetMostSuitableMonToSwitchInto (battle_ai_switch_items.c:596)
--
-- The cart's own two passes, and both are ported as the cart wrote them.  The
-- first scores each bench mon by how the *opponent's* types fare against the
-- bench mon's types and keeps the highest -- the famous backwards test that
-- sends in the mon the player's typing hits hardest -- and then accepts it
-- only if it has a super-effective move of its own.  The second is meant to
-- take whoever deals the most damage, but the cart's AI_CalcDmg there prices
-- the *active* battler's attack, not the candidate's, so what it measures is
-- a constant: the engine's reading (Engine.mostSuitableMon, pret
-- battle_ai_switch_items.c:510) is a base of 2 for every move not of power 1,
-- times 1.5 when the move shares a type with the mon being replaced, through
-- the type chart against the opponent -- and the first mon to reach the
-- highest such value wins.  An opponent that played better than the cart here
-- would be a different game.
--
-- A double changes two things, both the cart's (battle_ai_switch_items.c:448,
-- the engine's Engine.mostSuitableMon): neither seat's active nor the
-- sibling seat's pending send-in is a candidate (M:_benchable3), and the
-- opponent both passes test against is one of the player's two positions at
-- random (M:_flankFoe3) -- the other foe is never consulted.
function M:_replacement3(ctx)
  local S, t = ctx.S, ctx.t
  local candidates = {}
  for index, mon in ipairs(ctx.party) do
    if self:_benchable3(ctx, index, mon) then candidates[#candidates + 1] = mon end
  end
  if #candidates == 0 then return nil end
  if ctx.double then
    local foe = self:_flankFoe3(ctx)
    if foe then t = foe.b end
  end
  if not t then return candidates[1] end
  local invalid = {}
  while true do
    local best, bestV = nil, 0
    for _, mon in ipairs(candidates) do
      if not invalid[mon] then
        local pb = pseudoBattler(mon, S, ctx.b.side)
        local v = 100
        for _, oType in ipairs({ t.type1, t.type2 or t.type1 }) do
          v = math.floor(v * self:_product3(ctx, oType, pb) / 100)
        end
        if bestV < v then best, bestV = mon, v end
      end
    end
    if not best then break end
    local pb = pseudoBattler(best, S, ctx.b.side)
    if self:_superMove3(ctx, pb, t, best.moves) then return best end
    invalid[best] = true
  end
  local best, bestDmg = nil, 0
  for _, mon in ipairs(candidates) do
    for _, mv in ipairs(mon.moves or {}) do
      if int3(mv.num, 0) ~= 0 and int3(mv.power, 0) ~= 1 then
        local mt = int3(mv.type, 0)
        local dmg = 2
        if hasType(ctx.b, mt) then dmg = math.floor(dmg * 15 / 10) end
        local ok, typed = pcall(S.Types.typeCalc, ctx.typeTable, mt, t.type1, t.type2, dmg)
        dmg = ok and int3(typed, 0) or 0
        if bestDmg < dmg then best, bestDmg = mon, dmg end
      end
    end
  end
  return best or candidates[1]
end

-- ------- ShouldUseItem (battle_ai_switch_items.c:562, engine ai_items.lua)
--
-- The trainer's four item slots, in order, each spent to empty once used; a
-- slot past the first is only reached when the trainer is down to as many
-- monsters as it has items left after it (the cart's rationing).  The kind
-- of each item is read off the referee's own bag catalog, the same table the
-- use is refereed by.
function M:_shouldUseItem3(ctx)
  local items = self.items3
  if type(items) ~= "table" or #items == 0 then return nil end
  local b, S = ctx.b, ctx.S
  local valid = 0
  for _, mon in ipairs(ctx.party) do
    if int3(mon.hp, 0) > 0 then valid = valid + 1 end
  end
  local hp, maxHp = hpOf(b), maxHpOf(b)
  local firstTurn = int3(b.isFirstTurn, 0) > 0
  local status = statusOf3(b)
  for i = 0, 3 do
    if not (i > 0 and valid > (self.itemsNo3 - i) + 1) then
      local id = items[i + 1] or 0
      local effect = id ~= 0 and S.Items.bagEffect(id) or nil
      local use = false
      if effect then
        if id == 19 then
          use = hp < math.floor(maxHp / 4) and hp ~= 0
        elseif effect.heal or effect.healFull then
          local param = effect.healFull and 255 or int3(effect.heal, 0)
          use = param ~= 0 and hp ~= 0 and (hp < math.floor(maxHp / 4) or maxHp - hp > param)
        elseif effect.cure or effect.confusion then
          if status and effect.cure and effect.cure[status] then use = true end
          if effect.confusion and int3(b.confusion, 0) > 0 then use = true end
        elseif effect.stage or effect.focusEnergy then
          use = firstTurn
        elseif effect.mist then
          use = firstTurn and int3(ctx.mySide.mistTurns, 0) == 0
        end
      end
      if use and (ctx.bag == nil or (tonumber(ctx.bag[id]) or 0) > 0) then
        items[i + 1] = 0
        return { action = "item", item = id }
      end
    end
  end
  return nil
end

-- ------- the scripts

-- EFFECT_* groups, by the scripts that name them.  Built on first use from
-- BattleSim3's own effect table so the numbers are written down once.
local groups3

local function groupsOf(E)
  if groups3 then return groups3 end
  local function set(...)
    local out = {}
    for _, name in ipairs({ ... }) do
      if E[name] then out[E[name]] = true end
    end
    return out
  end
  groups3 = {
    selfUp = {
      [E.ATTACK_UP] = "atk", [E.DEFENSE_UP] = "def", [E.SPEED_UP] = "spe",
      [E.SPECIAL_ATTACK_UP] = "spa", [E.SPECIAL_DEFENSE_UP] = "spd",
      [E.ACCURACY_UP] = "acc", [E.EVASION_UP] = "eva",
      [E.ATTACK_UP_2] = "atk", [E.DEFENSE_UP_2] = "def", [E.SPEED_UP_2] = "spe",
      [E.SPECIAL_ATTACK_UP_2] = "spa", [E.SPECIAL_DEFENSE_UP_2] = "spd",
      [E.ACCURACY_UP_2] = "acc", [E.EVASION_UP_2] = "eva",
      [E.DEFENSE_CURL] = "def", [E.MINIMIZE] = "eva",
    },
    foeDown = {
      [E.ATTACK_DOWN] = "atk", [E.DEFENSE_DOWN] = "def", [E.SPEED_DOWN] = "spe",
      [E.SPECIAL_ATTACK_DOWN] = "spa", [E.SPECIAL_DEFENSE_DOWN] = "spd",
      [E.ACCURACY_DOWN] = "acc", [E.EVASION_DOWN] = "eva",
      [E.ATTACK_DOWN_2] = "atk", [E.DEFENSE_DOWN_2] = "def", [E.SPEED_DOWN_2] = "spe",
      [E.SPECIAL_ATTACK_DOWN_2] = "spa", [E.SPECIAL_DEFENSE_DOWN_2] = "spd",
      [E.ACCURACY_DOWN_2] = "acc", [E.EVASION_DOWN_2] = "eva",
    },
    heal = set("RESTORE_HP", "MORNING_SUN", "SYNTHESIS", "MOONLIGHT", "SOFTBOILED", "SWALLOW"),
    sunHeal = set("MORNING_SUN", "SYNTHESIS", "MOONLIGHT"),
    weather = { [E.RAIN_DANCE] = "RAIN", [E.SUNNY_DAY] = "SUN",
                [E.SANDSTORM] = "SAND", [E.HAIL] = "HAIL" },
    -- AI_SetupFirstTurn_SetupEffectsToEncourage (battle_ai_scripts.s)
    setup = set("ATTACK_UP", "DEFENSE_UP", "SPEED_UP", "SPECIAL_ATTACK_UP",
      "SPECIAL_DEFENSE_UP", "ACCURACY_UP", "EVASION_UP", "ATTACK_DOWN", "DEFENSE_DOWN",
      "SPEED_DOWN", "SPECIAL_ATTACK_DOWN", "SPECIAL_DEFENSE_DOWN", "ACCURACY_DOWN",
      "EVASION_DOWN", "CONVERSION", "LIGHT_SCREEN", "SPECIAL_DEFENSE_UP_2", "FOCUS_ENERGY",
      "CONFUSE", "ATTACK_UP_2", "DEFENSE_UP_2", "SPEED_UP_2", "SPECIAL_ATTACK_UP_2",
      "ACCURACY_UP_2", "EVASION_UP_2", "ATTACK_DOWN_2", "DEFENSE_DOWN_2", "SPEED_DOWN_2",
      "SPECIAL_ATTACK_DOWN_2", "SPECIAL_DEFENSE_DOWN_2", "ACCURACY_DOWN_2", "EVASION_DOWN_2",
      "REFLECT", "POISON", "PARALYZE", "SUBSTITUTE", "LEECH_SEED", "MINIMIZE", "CURSE",
      "SWAGGER", "CAMOUFLAGE", "YAWN", "DEFENSE_CURL", "TORMENT", "FLATTER", "WILL_O_WISP",
      "INGRAIN", "IMPRISON", "TEETER_DANCE", "TICKLE", "DOUBLE_TEAM", "COSMIC_POWER",
      "BULK_UP", "CALM_MIND", "DRAGON_DANCE"),
    -- AI_Risky_EffectsToEncourage
    risky = set("SLEEP", "EXPLOSION", "MIRROR_MOVE", "OHKO", "HIGH_CRITICAL", "CONFUSE",
      "METRONOME", "PSYWAVE", "COUNTER", "DESTINY_BOND", "SWAGGER", "ATTRACT", "PRESENT",
      "ALL_STATS_UP_HIT", "BELLY_DRUM", "MIRROR_COAT", "FOCUS_PUNCH", "REVENGE",
      "TEETER_DANCE"),
    -- sDiscouragedPowerfulMoveEffects (battle_ai_script_commands.c)
    discouraged = set("EXPLOSION", "DREAM_EATER", "RAZOR_WIND", "SKY_ATTACK", "RECHARGE",
      "SKULL_BASH", "SOLAR_BEAM", "SPIT_UP", "FOCUS_PUNCH", "SUPERPOWER", "ERUPTION",
      "OVERHEAT"),
    -- AI_HPAware's three lists (battle_ai_scripts.s)
    hpHigh = set("EXPLOSION", "RESTORE_HP", "REST", "DESTINY_BOND", "FLAIL", "ENDURE",
      "MORNING_SUN", "SYNTHESIS", "MOONLIGHT", "SOFTBOILED", "MEMENTO", "GRUDGE", "OVERHEAT"),
    hpMedium = set("EXPLOSION", "ATTACK_UP", "DEFENSE_UP", "SPEED_UP", "SPECIAL_ATTACK_UP",
      "SPECIAL_DEFENSE_UP", "ACCURACY_UP", "EVASION_UP", "ATTACK_DOWN", "DEFENSE_DOWN",
      "SPEED_DOWN", "SPECIAL_ATTACK_DOWN", "SPECIAL_DEFENSE_DOWN", "ACCURACY_DOWN",
      "EVASION_DOWN", "BIDE", "CONVERSION", "LIGHT_SCREEN", "MIST", "FOCUS_ENERGY",
      "ATTACK_UP_2", "DEFENSE_UP_2", "SPEED_UP_2", "SPECIAL_ATTACK_UP_2",
      "SPECIAL_DEFENSE_UP_2", "ACCURACY_UP_2", "EVASION_UP_2", "ATTACK_DOWN_2",
      "DEFENSE_DOWN_2", "SPEED_DOWN_2", "SPECIAL_ATTACK_DOWN_2", "SPECIAL_DEFENSE_DOWN_2",
      "ACCURACY_DOWN_2", "EVASION_DOWN_2", "CONVERSION_2", "SAFEGUARD", "BELLY_DRUM",
      "TICKLE", "COSMIC_POWER", "BULK_UP", "CALM_MIND", "DRAGON_DANCE"),
    hpLow = set("ATTACK_UP", "DEFENSE_UP", "SPEED_UP", "SPECIAL_ATTACK_UP",
      "SPECIAL_DEFENSE_UP", "ACCURACY_UP", "EVASION_UP", "ATTACK_DOWN", "DEFENSE_DOWN",
      "SPEED_DOWN", "SPECIAL_ATTACK_DOWN", "SPECIAL_DEFENSE_DOWN", "ACCURACY_DOWN",
      "EVASION_DOWN", "BIDE", "CONVERSION", "LIGHT_SCREEN", "MIST", "FOCUS_ENERGY",
      "ATTACK_UP_2", "DEFENSE_UP_2", "SPEED_UP_2", "SPECIAL_ATTACK_UP_2",
      "SPECIAL_DEFENSE_UP_2", "ACCURACY_UP_2", "EVASION_UP_2", "ATTACK_DOWN_2",
      "DEFENSE_DOWN_2", "SPEED_DOWN_2", "SPECIAL_ATTACK_DOWN_2", "SPECIAL_DEFENSE_DOWN_2",
      "ACCURACY_DOWN_2", "EVASION_DOWN_2", "RAGE", "CONVERSION_2", "LOCK_ON", "SAFEGUARD",
      "BELLY_DRUM", "PSYCH_UP", "MIRROR_COAT", "SOLAR_BEAM", "ERUPTION", "TICKLE",
      "COSMIC_POWER", "BULK_UP", "CALM_MIND", "DRAGON_DANCE"),
    targetLow = set("SLEEP", "EXPLOSION", "ATTACK_UP", "DEFENSE_UP", "SPEED_UP",
      "SPECIAL_ATTACK_UP", "SPECIAL_DEFENSE_UP", "ACCURACY_UP", "EVASION_UP", "ATTACK_DOWN",
      "DEFENSE_DOWN", "SPEED_DOWN", "SPECIAL_ATTACK_DOWN", "SPECIAL_DEFENSE_DOWN",
      "ACCURACY_DOWN", "EVASION_DOWN", "BIDE", "CONVERSION", "TOXIC", "LIGHT_SCREEN",
      "OHKO", "SUPER_FANG", "FOCUS_ENERGY", "CONFUSE", "ATTACK_UP_2", "DEFENSE_UP_2",
      "SPEED_UP_2", "SPECIAL_ATTACK_UP_2", "SPECIAL_DEFENSE_UP_2", "ACCURACY_UP_2",
      "EVASION_UP_2", "ATTACK_DOWN_2", "DEFENSE_DOWN_2", "SPEED_DOWN_2",
      "SPECIAL_ATTACK_DOWN_2", "SPECIAL_DEFENSE_DOWN_2", "ACCURACY_DOWN_2",
      "EVASION_DOWN_2", "POISON", "PARALYZE", "PAIN_SPLIT", "CONVERSION_2", "LOCK_ON",
      "SAFEGUARD", "BELLY_DRUM", "PSYCH_UP", "MIRROR_COAT", "SOLAR_BEAM", "ERUPTION",
      "TICKLE", "COSMIC_POWER", "BULK_UP", "CALM_MIND", "DRAGON_DANCE"),
  }
  return groups3
end

-- pret's MOVE_POWER_* reading: "other" for a non-damaging or discouraged move,
-- else "best" when nothing else on the list would deal more.
local function powerClasses(self, ctx, legal, est, G)
  local out = {}
  local moves = ctx.b.moves
  local E = ctx.S.Effects.E
  local function counted(i)
    local mv = moves[i]
    return int3(mv.power, 0) > 1 and not G.discouraged[int3(mv.effect, 0)]
      and not fixedSet(E)[int3(mv.effect, 0)] and int3(mv.effect, 0) ~= E.OHKO
  end
  for _, i in ipairs(legal) do
    if not counted(i) then
      out[i] = "other"
    else
      local best = true
      for _, j in ipairs(legal) do
        if j ~= i and counted(j) and (est[j] or 0) > (est[i] or 0) then best = false end
      end
      out[i] = best and "best" or "notbest"
    end
  end
  return out
end

-- The best-scored usable slot, ties drawn at random, and its score.
function M:_bestOf3(scores, legal)
  local best, pool = nil, {}
  for _, i in ipairs(legal) do
    local s = scores[i]
    if best == nil or s > best then best, pool = s, { i }
    elseif s == best then pool[#pool + 1] = i end
  end
  return pool[self.rng(1, #pool)], best
end

function M:_chooseMove3(ctx, legal)
  local rng = self.rng
  -- No scripts at all: the controller picks a usable slot at random.
  if ctx.aiFlags == 0 then
    return { action = "fight", move = legal[rng(1, #legal)] - 1 }
  end
  local scores = self:_scoreMoves3(ctx, legal)
  self.lastScores3 = scores
  local pick = self:_bestOf3(scores, legal)
  return { action = "fight", move = pick - 1 }
end

-- ------- a double's target (BattleAI_SetupAIData / ChooseMoveOrAction_Doubles)
--
-- The two families part here, and each is ported as its cart wrote it.
--
-- FireRed / LeafGreen aim first and score after: one of the player's two
-- positions at random (M:_flankFoe3), and every script then runs against
-- that one battler, exactly as a 1v1 runs against the one opposite.  Its
-- scripts never look at the AI's own partner.
--
-- Emerald scores every move against every battler but itself
-- (pokeemerald battle_ai_script_commands.c:448, the engine's
-- Ai.chooseDoubles): each standing foe *and* its own partner, a fresh
-- simulated roll per pass, the best move per target with ties drawn at
-- random -- and a partner pass counts only at 100 or more (AI_TryOnAlly
-- prices almost everything at -30, so what survives is a move the cart
-- means for the ally).  The target with the highest best wins, ties drawn at
-- random, and its move is the one used.
--
-- Either way the target is named only for a MOVE_TARGET_SELECTED move: the
-- controller re-aims a user / user-or-selected move at the user and a BOTH
-- move at the player's left position (battle_controller_opponent.c:1370),
-- and the referee reads its own target for every other kind.  The one
-- exception is a Ghost's CURSE, which names the foe opposite the user
-- (M:_oppositeFoe3).
function M:_chooseDouble3(ctx, legal)
  local rng = self.rng
  -- No standing foe to aim at (a view caught between faints): score the 1v1
  -- reading and leave the target to the referee.
  if #ctx.foes == 0 then return self:_chooseMove3(ctx, legal) end
  if self.family3 == "rse" and ctx.aiFlags ~= 0 then
    -- pret battler ids 0..3 are the player's left, the AI side's left, the
    -- player's right, the AI side's right: field slots 0, 3, 1, 4.
    local cands = {}
    for _, foe in ipairs(ctx.foes) do
      cands[#cands + 1] = { slot = foe.slot, b = foe.b, order = foe.slot * 2 }
    end
    if ctx.partner then
      cands[#cands + 1] = { slot = ctx.partnerSlot, b = ctx.partner, ally = true,
                            order = (ctx.partnerSlot - 3) * 2 + 1 }
    end
    table.sort(cands, function(x, y) return x.order < y.order end)
    local most, pool = nil, {}
    for _, cand in ipairs(cands) do
      ctx.t, ctx.tIsAlly = cand.b, cand.ally
      cand.scores = self:_scoreMoves3(ctx, legal)
      cand.pick, cand.best = self:_bestOf3(cand.scores, legal)
      if cand.ally and cand.best < 100 then cand.best = -1 end
      if most == nil or cand.best > most then most, pool = cand.best, { cand }
      elseif cand.best == most then pool[#pool + 1] = cand end
    end
    local chosen = pool[rng(1, #pool)]
    ctx.t, ctx.tIsAlly = chosen.b, chosen.ally
    self.lastScores3 = chosen.scores
    return self:_aimed3(ctx, chosen.pick, chosen.slot)
  end
  -- FireRed / LeafGreen (and an Emerald trainer with no script bit at all,
  -- whose BattleAI_SetupAIData target is the same flank roll).
  local foe = self:_flankFoe3(ctx)
  if foe then ctx.t = foe.b end
  local choice = self:_chooseMove3(ctx, legal)
  return self:_aimed3(ctx, choice.move + 1, foe and foe.slot or nil)
end

-- pret include/constants/battle.h MOVE_TARGET_SELECTED: the one target byte a
-- double's choice names its battler for (see M:_chooseDouble3).
local MOVE_TARGET_SELECTED = 0
-- pret include/constants/moves.h MOVE_CURSE.
local MOVE_CURSE = 174

-- The battler a Ghost's CURSE turns on when the cart's AI uses it.  The AI
-- aims every USER-row move at itself (battle_controller_opponent.c:1370, the
-- engine's ai.lua:353), and the Ghost curse then lands on the battler
-- opposite the user (the engine's effects/setup.lua foeOf: battler 0 faces 1,
-- 2 faces 3), else the nearest standing foe.  The referee aims a Ghost's
-- CURSE as a SELECTED move and defaults an unnamed one to the first living
-- foe, so a second seat must name its opposite or curse the wrong battler.
-- The referee's own Battle:oppositeFoe when the view carries it, else the
-- same rule over the view's foes: the player slot in the seat's position,
-- nearest first, ties to the lower slot.
function M:_oppositeFoe3(ctx)
  local sim, b = ctx.sim, ctx.b
  if sim and type(sim.oppositeFoe) == "function" and type(b.fighter) == "table" then
    local ok, foe = pcall(sim.oppositeFoe, sim, b)
    if ok and type(foe) == "table" and int3(foe.slot, nil) then return int3(foe.slot, nil) end
  end
  local want = ctx.seat and (ctx.seat - 3) or 0
  local best, bestD = nil, nil
  for _, foe in ipairs(ctx.foes) do
    local d = math.abs(foe.slot - want)
    if bestD == nil or d < bestD then best, bestD = foe, d end
  end
  return best and best.slot or nil
end

function M:_aimed3(ctx, i, slot)
  local out = { action = "fight", move = i - 1 }
  local row = ctx.b.moves and ctx.b.moves[i]
  if type(row) ~= "table" then return out end
  if int3(row.num, 0) == MOVE_CURSE and hasType(ctx.b, ctx.S.Types.ID.GHOST) then
    out.target = self:_oppositeFoe3(ctx)
    return out
  end
  if slot ~= nil and int3(row.target, 0) == MOVE_TARGET_SELECTED then
    out.target = slot
  end
  return out
end

-- Every script's verdict on every usable slot against ctx.t, in the order
-- the cart's loop runs them (AI flag bit by bit, each over the whole
-- moveset), plus the simulated damage roll each pass draws first.
function M:_scoreMoves3(ctx, legal)
  local S, b, t = ctx.S, ctx.b, ctx.t
  local E = S.Effects.E
  local G = groupsOf(E)
  local rng = self.rng
  local flags = ctx.aiFlags
  local moves = b.moves

  local scores, est = {}, {}
  for _, i in ipairs(legal) do
    scores[i] = 100
    -- AI_THINKING_STRUCT->simulatedRNG[i] = 100 - (Random() % 16)
    est[i] = self:_damage3(ctx, b, t, moves[i], 100 - rng(0, 15))
  end
  local power = powerClasses(self, ctx, legal, est, G)
  local rand = function() return rng(0, 255) end

  -- Emerald, scoring against its own partner: every script up to
  -- PREFER_BATON_PASS opens `if_target_is_ally AI_Ret`, and the last three
  -- -- DOUBLE_BATTLE, HP_AWARE, TRY_SUNNY_DAY_START -- open
  -- `if_target_is_ally AI_TryOnAlly`, so each of those the fight runs
  -- prices the move for the ally once more (M:_tryOnAlly3).
  if ctx.tIsAlly then
    for _, name in ipairs({ "DOUBLE_BATTLE", "HP_AWARE", "TRY_SUNNY_DAY_START" }) do
      if self:_flag3(name, flags) then
        for _, i in ipairs(legal) do
          scores[i] = scores[i] + self:_tryOnAlly3(ctx, moves[i], power[i], rand)
        end
      end
    end
    return scores
  end

  if self:_flag3("CHECK_BAD_MOVE", flags) then
    for _, i in ipairs(legal) do scores[i] = scores[i] + self:_checkBad3(ctx, moves[i], G) end
  end
  -- AI_TryToFaint.  `if_can_faint` (the engine's ai_cmds.lua, pret
  -- Cmd_if_can_faint) skips any move of power under 2 -- the one-hit KO and
  -- fixed-damage rows, Counter, Hidden Power -- and prices the rest with the
  -- simulated roll, never under 1.  Only Emerald's script then adds +2 at
  -- random for a 4x hit; FireRed's ends after the NOT_MOST -1.
  if self:_flag3("TRY_TO_FAINT", flags) then
    local rse = self.family3 == "rse"
    for _, i in ipairs(legal) do
      local mv = moves[i]
      local eff = int3(mv.effect, 0)
      if int3(mv.power, 0) >= 2 and hpOf(t) <= math.max(1, est[i] or 0) then
        if eff ~= E.EXPLOSION then
          scores[i] = scores[i] + 4
          if eff == E.QUICK_ATTACK then scores[i] = scores[i] + 2 end
        end
      elseif power[i] == "notbest" then
        scores[i] = scores[i] - 1
      elseif rse and isDamaging(mv, E)
          and self:_product3(ctx, self:_moveType3(ctx, b, mv), t) >= 400
          and rand() >= 80 then
        scores[i] = scores[i] + 2
      end
    end
  end
  if self:_flag3("CHECK_VIABILITY", flags) then
    for _, i in ipairs(legal) do scores[i] = scores[i] + self:_viability3(ctx, moves[i], G, est[i]) end
  end
  if self:_flag3("SETUP_FIRST_TURN", flags) and ctx.turnCount == 0 then
    for _, i in ipairs(legal) do
      if G.setup[int3(moves[i].effect, 0)] and rand() >= 80 then scores[i] = scores[i] + 2 end
    end
  end
  if self:_flag3("RISKY", flags) then
    for _, i in ipairs(legal) do
      if G.risky[int3(moves[i].effect, 0)] and rand() >= 128 then scores[i] = scores[i] + 2 end
    end
  end
  -- Slot 5.  Emerald calls it AI_PreferPowerExtremes, FireRed
  -- AI_PreferStrongestMove, and the two carts' scripts are the same few
  -- lines (the ones the engine runs from the cart): get_how_powerful_move_is,
  -- and +2 at random for a move it calls DISCOURAGED -- the power reading's
  -- "other", status moves and the fixed / discouraged ones.  Despite the name,
  -- FireRed's does not favour the strongest move.
  if self:_flag3("PREFER_STRONGEST_MOVE", flags) or self:_flag3("PREFER_POWER_EXTREMES", flags) then
    for _, i in ipairs(legal) do
      if power[i] == "other" and rand() >= 100 then scores[i] = scores[i] + 2 end
    end
  end
  if self:_flag3("PREFER_BATON_PASS", flags) then
    local hasPass = false
    for _, i in ipairs(legal) do
      if int3(moves[i].effect, 0) == E.BATON_PASS then hasPass = true end
    end
    if hasPass then
      local raised = 0
      for _, v in pairs(b.stages or {}) do
        if (tonumber(v) or 0) > 0 then raised = raised + v end
      end
      for _, i in ipairs(legal) do
        local eff = int3(moves[i].effect, 0)
        if eff == E.BATON_PASS then
          scores[i] = scores[i] + ((raised > 0) and 2 or -2)
        elseif (G.selfUp[eff] or eff == E.SUBSTITUTE or eff == E.INGRAIN) and ctx.turnCount <= 1 then
          scores[i] = scores[i] + 3
        end
      end
    end
  end
  -- AI_DoubleBattle (bit 7, between PREFER_BATON_PASS and HP_AWARE), against
  -- a foe; only a double runs it (see M:_doubleBattle3).
  if ctx.double and self:_flag3("DOUBLE_BATTLE", flags) then
    for _, i in ipairs(legal) do
      scores[i] = scores[i] + self:_doubleBattle3(ctx, moves[i], power[i])
    end
  end
  if self:_flag3("HP_AWARE", flags) then
    local mine, theirs = pct(b), pct(t)
    for _, i in ipairs(legal) do
      local eff = int3(moves[i].effect, 0)
      local list = (mine > 70 and G.hpHigh) or (mine > 30 and G.hpMedium) or G.hpLow
      if list[eff] and rand() >= 50 then scores[i] = scores[i] - 2 end
      if theirs <= 30 and G.targetLow[eff] and rand() >= 50 then scores[i] = scores[i] - 2 end
    end
  end
  -- Emerald's AI_TrySunnyDayStart: open the fight with the sun.
  if self:_flag3("TRY_SUNNY_DAY_START", flags) and int3(b.isFirstTurn, 0) > 0 then
    for _, i in ipairs(legal) do
      if int3(moves[i].effect, 0) == E.SUNNY_DAY and ctx.weather ~= "SUN" then
        scores[i] = scores[i] + 5
      end
    end
  end

  return scores
end

-- count_alive_pokemon (pret Cmd_count_alive_pokemon, the engine's
-- ai_cmds.lua): `battler`'s party, living, minus the mon it has out -- and in
-- a double minus its flankmate's too (gBattlerPartyIndexes of the partner
-- position), so a seat never counts its own partner as a reserve.
function M:_aliveBehind3(ctx, battler, party)
  local mate = ctx.double and self:_flankmate3(ctx, battler) or nil
  local n = 0
  for _, mon in ipairs(party) do
    if mon ~= battler.mon and not (mate and mon == mate.mon) and int3(mon.hp, 0) > 0 then
      n = n + 1
    end
  end
  return n
end

-- Cmd_check_ability's answer: 1 the battler has it, 0 it has another, 2 the
-- cart cannot say -- no ability at all, which is how an empty position (or no
-- battler) reads.  The brain reads the referee's battler for every side, as
-- the rest of this file does, where the cart guesses the player's from the
-- species.
local function checkAbility3(battler, name)
  local ab = battler and battler.ability
  if ab == nil or ab == "" then return 2 end
  return (ab == name) and 1 or 0
end

-- The moves AI_DoubleBattle and AI_TryOnAlly name (pret include/constants/
-- moves.h), and the item AI_TrySwaggerOnAlly looks for (items.h).
local MOVE_EARTHQUAKE, MOVE_MAGNITUDE, MOVE_SKILL_SWAP = 89, 222, 285
local MOVE_WILL_O_WISP, MOVE_TOXIC, MOVE_HELPING_HAND, MOVE_SWAGGER = 261, 92, 270, 207
local ITEM_PERSIM_BERRY = 140
-- AI_TrySkillSwapOnAlly's "a partner with a move COMPOUND EYES would steady":
-- FIRE BLAST, THUNDER, CROSS CHOP, HYDRO PUMP, DYNAMIC PUNCH, BLIZZARD, MEGAHORN.
local COMPOUND_EYES_MOVES = {
  [126] = true, [87] = true, [238] = true, [56] = true, [223] = true, [59] = true, [224] = true,
}

local function knows3(battler, num)
  for _, m in ipairs((battler and battler.moves) or {}) do
    if int3(m.num, 0) == num then return true end
  end
  return false
end

-- AI_DoubleBattle against a foe (pokeemerald data/battle_ai_scripts.s, run
-- by the engine from the cart's own pack).  FireRed / LeafGreen's
-- AI_DoubleBattle is a bare `end` -- the bit runs and scores nothing -- so
-- only Emerald's arms are here, in the script's own order:
--   * SKILL SWAP: +5 to shed the user's TRUANT, else +2 to take the foe's
--     SHADOW TAG or PURE POWER;
--   * EARTHQUAKE / MAGNITUDE, which hit the partner too: +2 when the partner
--     is out of reach (LEVITATE, Flying), -10 when it is a Fire, Electric,
--     Poison or Rock type, -3 otherwise -- an empty partner position reads
--     as zeroes, so it is the -3;
--   * an Electric move, while the foe's partner could pull it with
--     LIGHTNING ROD (check_ability anything but "no"): -2, and -8 more if
--     that partner is a Ground type;
--   * a Fire move, with the user's FLASH FIRE already lit: +1;
--   * otherwise, a user without GUTS that has a status: -5 for a move the
--     power reading calls DISCOURAGED, else +1, and +2 more for the
--     strongest -- the script tests `if_not_equal ABILITY_GUTS` where it
--     reads as if it meant the reverse, and is ported as it runs;
--   * and a GUTS user whose partner knows HELPING HAND: +1 for any move the
--     power reading does not discourage.
-- The type it branches on is the row's (get_curr_move_type), not Hidden
-- Power's or Weather Ball's dealt type.
function M:_doubleBattle3(ctx, mv, power)
  if self.family3 ~= "rse" then return 0 end
  local S, b, t = ctx.S, ctx.b, ctx.t
  local T = S.Types.ID
  local num = int3(mv.num, 0)
  if num == MOVE_SKILL_SWAP then
    if b.ability == "TRUANT" then return 5 end
    if t.ability == "SHADOW_TAG" or t.ability == "PURE_POWER" then return 2 end
    return 0
  end
  local mtype = int3(mv.type, 0)
  if num == MOVE_EARTHQUAKE or num == MOVE_MAGNITUDE then
    local p = self:_flankmate3(ctx, b)
    if checkAbility3(p, "LEVITATE") == 1 or hasType(p, T.FLYING) then return 2 end
    if hasType(p, T.FIRE) or hasType(p, T.ELECTRIC) or hasType(p, T.POISON)
        or hasType(p, T.ROCK) then
      return -10
    end
    return -3
  end
  if mtype == T.ELECTRIC then
    local tp = self:_flankmate3(ctx, t)
    if checkAbility3(tp, "LIGHTNING_ROD") == 0 then return 0 end
    if hasType(tp, T.GROUND) then return -10 end
    return -2
  end
  if mtype == T.FIRE then
    return b.flashFire and 1 or 0
  end
  if b.ability ~= "GUTS" then
    if not statusOf3(b) then return 0 end
    if power == "other" then return -5 end
    return (power == "best") and 3 or 1
  end
  -- if_has_move AI_USER_PARTNER skips a partner at 0 HP.
  local p = ctx.partner
  if p and hpOf(p) > 0 and knows3(p, MOVE_HELPING_HAND) and power ~= "other" then return 1 end
  return 0
end

-- AI_TryOnAlly (pokeemerald data/battle_ai_scripts.s): Emerald scoring a
-- move against its own partner.  -30 -- never aim it at the ally -- for
-- everything but what the cart means for one:
--   * a move the power reading does not discourage: only a Fire move into a
--     FLASH FIRE partner that has not caught one yet, +3;
--   * SKILL SWAP: +10 to relieve a TRUANT partner of it; else, from a user
--     without LEVITATE, +3 to hand over COMPOUND EYES to a partner holding
--     one of the inaccurate moves it steadies; from a LEVITATE user, -30 into
--     a LEVITATE partner, +1 per Electric type the partner has (handing it
--     the Ground immunity it lacks) -- and on the way, wherever a type is not
--     Electric, the script falls into the COMPOUND EYES test with that *type*
--     still in the register, which TYPE_PSYCHIC (14, COMPOUND EYES's number
--     too) passes;
--   * WILL-O-WISP / TOXIC onto a GUTS partner with no status, while the user
--     itself is at 91% or more: +5;
--   * HELPING HAND: +2, or -1 one time in four;
--   * SWAGGER into a partner holding a PERSIM BERRY: +3 unless its Attack is
--     already above +1, where the script ends at 0.
function M:_tryOnAlly3(ctx, mv, power, rand)
  local b, t = ctx.b, ctx.t
  local T = ctx.S.Types.ID
  local num = int3(mv.num, 0)
  if power ~= "other" then
    if int3(mv.type, 0) == T.FIRE and checkAbility3(t, "FLASH_FIRE") == 1 then
      return t.flashFire and -30 or 3
    end
    return -30
  end
  if num == MOVE_SKILL_SWAP then
    if t.ability == "TRUANT" then return 10 end
    local score, passes = 0, nil
    if b.ability ~= "LEVITATE" then
      passes = b.ability == "COMPOUND_EYES"
    elseif t.ability == "LEVITATE" then
      return -30
    elseif t.type1 ~= T.ELECTRIC then
      passes = t.type1 == T.PSYCHIC
    else
      score = 1
      local t2 = t.type2 or t.type1
      if t2 == T.ELECTRIC then return 2 end
      passes = t2 == T.PSYCHIC
    end
    -- if_has_move AI_USER_PARTNER: the user's partner is the ally scored.
    if passes and hpOf(t) > 0 then
      for _, m in ipairs(t.moves or {}) do
        if COMPOUND_EYES_MOVES[int3(m.num, 0)] then return score + 3 end
      end
    end
    return score - 30
  end
  if num == MOVE_WILL_O_WISP or num == MOVE_TOXIC then
    if t.ability ~= "GUTS" or statusOf3(t) or pct(b) < 91 then return -30 end
    return 5
  end
  if num == MOVE_HELPING_HAND then
    if rand() < 64 then return -1 end
    return 2
  end
  if num == MOVE_SWAGGER then
    if int3(t.mon and t.mon.heldItem, 0) ~= ITEM_PERSIM_BERRY then return -30 end
    if int3(t.stages and t.stages.atk, 0) > 1 then return 0 end
    return 3
  end
  return -30
end

-- AI_CheckBadMove: the negations, then each effect's "this will fail" test.
function M:_checkBad3(ctx, mv, G)
  local S, b, t = ctx.S, ctx.b, ctx.t
  local E, T = S.Effects.E, S.Types.ID
  local eff = int3(mv.effect, 0)
  local neg
  if self:_negationChecked3(mv, G) then
    neg = self:_negated3(ctx, b, t, mv)
  elseif t.ability == "SOUNDPROOF" and S.Abilities.SOUND_MOVES[int3(mv.num, -1)] then
    neg = -10
  end
  if neg then return neg end
  local tAb = t.ability
  local tStatus = statusOf3(t)
  local tSafe = int3(ctx.foeSide.safeguardTurns, 0) > 0
  local mtype = self:_moveType3(ctx, b, mv)
  local immuneByType = self:_product3(ctx, mtype, t) == 0

  local up = G.selfUp[eff]
  if up then
    if int3(b.stages and b.stages[up], 0) >= 6 then return -10 end
    return 0
  end
  local down = G.foeDown[eff]
  if down then
    if int3(t.stages and t.stages[down], 0) <= -6 then return -10 end
    if tAb == "CLEAR_BODY" or tAb == "WHITE_SMOKE" then return -10 end
    if down == "atk" and tAb == "HYPER_CUTTER" then return -10 end
    if down == "acc" and tAb == "KEEN_EYE" then return -10 end
    if int3(ctx.foeSide.mistTurns, 0) > 0 then return -10 end
    return 0
  end
  if eff == E.SLEEP or eff == E.YAWN then
    if tAb == "INSOMNIA" or tAb == "VITAL_SPIRIT" then return -10 end
    if tStatus or tSafe then return -10 end
    if eff == E.YAWN and int3(t.yawnTurns, 0) > 0 then return -10 end
  elseif eff == E.TOXIC or eff == E.POISON then
    if hasType(t, T.POISON) or hasType(t, T.STEEL) or tAb == "IMMUNITY" then return -10 end
    if tStatus or tSafe then return -10 end
  elseif eff == E.PARALYZE then
    if immuneByType or tAb == "LIMBER" then return -10 end
    if tStatus or tSafe then return -10 end
  elseif eff == E.WILL_O_WISP then
    if hasType(t, T.FIRE) or tAb == "WATER_VEIL" or tAb == "FLASH_FIRE" then return -10 end
    if tStatus or tSafe then return -10 end
  elseif eff == E.CONFUSE or eff == E.SWAGGER or eff == E.FLATTER or eff == E.TEETER_DANCE then
    if tAb == "OWN_TEMPO" or tSafe then return -10 end
    if int3(t.confusion, 0) > 0 then return -5 end
  elseif eff == E.ATTRACT then
    local g1, g2 = b.mon and b.mon.gender, t.mon and t.mon.gender
    if t.infatuatedWith ~= nil or tAb == "OBLIVIOUS" then return -10 end
    if g1 == "U" or g2 == "U" or g1 == g2 then return -10 end
  elseif eff == E.LEECH_SEED then
    if hasType(t, T.GRASS) or t.seededBy ~= nil then return -10 end
  elseif eff == E.DREAM_EATER or eff == E.NIGHTMARE then
    if tStatus ~= "SLP" then return -8 end
    if eff == E.NIGHTMARE and t.nightmare then return -10 end
  elseif eff == E.OHKO then
    if tAb == "STURDY" then return -10 end
    if int3(t.mon.level, 1) > int3(b.mon.level, 1) then return -10 end
  elseif eff == E.EXPLOSION then
    if tAb == "DAMP" then return -10 end
    -- the last mon standing does not blow itself up while the player has more
    local mine = self:_aliveBehind3(ctx, b, ctx.party)
    if mine == 0 then
      local fighter = t.fighter
      local theirs = self:_aliveBehind3(ctx, t, (fighter and fighter.mons) or {})
      if theirs > 0 then return -10 end
    end
  elseif G.heal[eff] then
    if hpOf(b) >= maxHpOf(b) then return -8 end
  elseif eff == E.REST then
    if hpOf(b) >= maxHpOf(b) then return -8 end
    if b.ability == "INSOMNIA" or b.ability == "VITAL_SPIRIT" then return -10 end
  elseif eff == E.BELLY_DRUM then
    if pct(b) < 51 then return -10 end
  elseif eff == E.SUBSTITUTE then
    if int3(b.substituteHP, 0) > 0 then return -8 end
    if pct(b) <= 25 then return -10 end
  elseif eff == E.LIGHT_SCREEN then
    if int3(ctx.mySide.lightScreenTurns, 0) > 0 then return -8 end
  elseif eff == E.REFLECT then
    if int3(ctx.mySide.reflectTurns, 0) > 0 then return -8 end
  elseif eff == E.MIST then
    if int3(ctx.mySide.mistTurns, 0) > 0 then return -8 end
  elseif eff == E.SAFEGUARD then
    if int3(ctx.mySide.safeguardTurns, 0) > 0 then return -8 end
  elseif eff == E.FOCUS_ENERGY then
    if b.focusEnergy then return -10 end
  elseif eff == E.SPIKES then
    if int3(ctx.foeSide.spikes, 0) >= 3 then return -10 end
  elseif G.weather[eff] then
    if ctx.weather == G.weather[eff] then return -8 end
  elseif eff == E.ROAR then
    if tAb == "SUCTION_CUPS" or t.ingrain then return -10 end
    local bench = self:_aliveBehind3(ctx, t, (t.fighter and t.fighter.mons) or {})
    if bench == 0 then return -10 end
  elseif eff == E.DISABLE then
    if t.disabledNum then return -8 end
  elseif eff == E.ENCORE then
    if int3(t.encoreTurns, 0) > 0 then return -8 end
  elseif eff == E.TAUNT then
    if int3(t.tauntTurns, 0) > 0 then return -1 end
  elseif eff == E.TORMENT then
    if t.tormented then return -10 end
  elseif eff == E.FORESIGHT then
    if t.identified then return -10 end
  elseif eff == E.PERISH_SONG then
    if t.perishTurns ~= nil then return -10 end
  elseif eff == E.MEAN_LOOK then
    if t.trappedBy ~= nil then return -10 end
  elseif eff == E.INGRAIN then
    if b.ingrain then return -10 end
  elseif eff == E.SNORE or eff == E.SLEEP_TALK then
    if statusOf3(b) ~= "SLP" then return -8 end
  elseif eff == E.FAKE_OUT then
    if int3(b.isFirstTurn, 0) <= 0 then return -10 end
  elseif eff == E.STOCKPILE then
    if int3(b.stockpile, 0) >= 3 then return -10 end
  elseif eff == E.SPIT_UP or eff == E.SWALLOW then
    if int3(b.stockpile, 0) == 0 then return -10 end
  elseif eff == E.REFRESH then
    local s = statusOf3(b)
    if not (s == "PSN" or s == "TOX" or s == "BRN" or s == "PAR") then return -10 end
  elseif eff == E.HELPING_HAND or eff == E.FOLLOW_ME then
    -- A singles fight has nobody to help or to draw fire from.  In a double
    -- the cart's own test passes: AI_CBM_HelpingHand is `is_double_battle`,
    -- -10 only outside one, and AI_CheckBadMove names no Follow Me arm.
    if ctx.double then return 0 end
    return -10
  elseif eff == E.TRICK then
    if int3(b.mon.heldItem, 0) == 0 and int3(t.mon.heldItem, 0) == 0 then return -10 end
    if tAb == "STICKY_HOLD" then return -10 end
  elseif eff == E.KNOCK_OFF or eff == E.THIEF then
    -- still damaging; the item half simply has nothing to take
    return 0
  elseif eff == E.RECYCLE then
    if not b.usedHeldItem or int3(b.mon.heldItem, 0) ~= 0 then return -10 end
  elseif eff == E.MEMENTO then
    if int3(t.stages and t.stages.atk, 0) <= -6 and int3(t.stages and t.stages.spa, 0) <= -6 then
      return -10
    end
  elseif eff == E.TICKLE then
    if int3(t.stages and t.stages.atk, 0) <= -6 and int3(t.stages and t.stages.def, 0) <= -6 then
      return -10
    end
  elseif eff == E.COSMIC_POWER then
    if int3(b.stages.def, 0) >= 6 and int3(b.stages.spd, 0) >= 6 then return -10 end
  elseif eff == E.BULK_UP then
    if int3(b.stages.atk, 0) >= 6 and int3(b.stages.def, 0) >= 6 then return -10 end
  elseif eff == E.CALM_MIND then
    if int3(b.stages.spa, 0) >= 6 and int3(b.stages.spd, 0) >= 6 then return -10 end
  elseif eff == E.DRAGON_DANCE then
    if int3(b.stages.atk, 0) >= 6 and int3(b.stages.spe, 0) >= 6 then return -10 end
  elseif eff == E.MUD_SPORT then
    if b.mudSport then return -10 end
  elseif eff == E.WATER_SPORT then
    if b.waterSport then return -10 end
  elseif eff == E.BATON_PASS then
    local bench = self:_aliveBehind3(ctx, b, ctx.party)
    if bench == 0 then return -10 end
  elseif eff == E.PROTECT or eff == E.ENDURE then
    if int3(b.protectStreak, 0) > 0 then return -2 end
  end
  return 0
end

-- AI_CheckViability's readings a sheet can answer: heal thresholds, the
-- weather's effect on the move, stat-change sense, status against a target
-- that is nearly down, the self-KO trade.
function M:_viability3(ctx, mv, G, estimate)
  local S, b, t = ctx.S, ctx.b, ctx.t
  local E, T = S.Effects.E, S.Types.ID
  local eff = int3(mv.effect, 0)
  local rng = self.rng
  local mine, theirs = pct(b), pct(t)
  local w = ctx.weather
  local faster = false
  do
    local okS, Field = pcall(need, "BattleSim3/Field")
    if okS and type(Field) == "table" and type(Field.speed) == "function" then
      faster = Field.speed(b, w) > Field.speed(t, w)
    end
  end
  local score = 0

  if G.heal[eff] or eff == E.REST then
    if mine >= 100 then score = score - 3
    elseif mine > 80 and rng(0, 255) >= 70 then score = score - 3
    elseif mine < 40 then score = score + ((faster or rng(0, 255) >= 128) and 2 or 1)
    elseif rng(0, 255) >= 128 then score = score + 1 end
    if G.sunHeal[eff] then
      if w == "SUN" then score = score + 1 elseif w then score = score - 1 end
    end
  elseif G.selfUp[eff] then
    local stage = int3(b.stages and b.stages[G.selfUp[eff]], 0)
    if stage >= 3 then score = score - 1 end
    if mine < 70 and rng(0, 255) >= 128 then score = score - 2 end
    if mine >= 100 and stage == 0 and rng(0, 255) >= 128 then score = score + 1 end
  elseif G.foeDown[eff] then
    local stage = int3(t.stages and t.stages[G.foeDown[eff]], 0)
    if stage <= -3 then score = score - 1 end
    if theirs < 70 and rng(0, 255) >= 128 then score = score - 2 end
  elseif eff == E.SLEEP or eff == E.TOXIC or eff == E.POISON or eff == E.PARALYZE
      or eff == E.WILL_O_WISP or eff == E.LEECH_SEED or eff == E.CONFUSE then
    if theirs <= 50 and rng(0, 255) >= 128 then score = score - 1 end
    if eff == E.SLEEP then
      -- a sleeper is worth more to a mon that knows Dream Eater / Nightmare
      for _, other in ipairs(b.moves or {}) do
        local oe = int3(other.effect, 0)
        if oe == E.DREAM_EATER or oe == E.NIGHTMARE then score = score + 1; break end
      end
    end
    if eff == E.PARALYZE and not faster and rng(0, 255) >= 64 then score = score + 1 end
  elseif eff == E.EXPLOSION then
    if mine >= 80 and theirs > 50 then score = score - 3
    elseif mine < 30 then score = score + 1 end
  elseif eff == E.PROTECT then
    local s = statusOf3(t)
    if s == "TOX" or s == "PSN" or s == "BRN" or t.seededBy ~= nil or t.cursed then
      score = score + 1
    end
  elseif eff == E.SUBSTITUTE then
    if mine < 50 then score = score - 1 end
  elseif G.weather[eff] then
    local want = G.weather[eff]
    if mine < 40 then score = score - 1 end
    local ab = b.ability
    if (want == "RAIN" and ab == "SWIFT_SWIM") or (want == "SUN" and ab == "CHLOROPHYLL") then
      score = score + 1
    end
    if want == "RAIN" and hasType(b, T.WATER) then score = score + 1 end
    if want == "SUN" and hasType(b, T.FIRE) then score = score + 1 end
    if (want == "SAND" and (hasType(b, T.ROCK) or hasType(b, T.GROUND) or hasType(b, T.STEEL)))
        or (want == "HAIL" and hasType(b, T.ICE)) then
      score = score + 1
    end
    if w and w ~= want then score = score + 1 end
  elseif eff == E.THUNDER then
    if w == "RAIN" then score = score + 1 elseif w == "SUN" then score = score - 1 end
  elseif eff == E.SOLAR_BEAM then
    if w == "SUN" then score = score + 1
    elseif w == "RAIN" or w == "SAND" or w == "HAIL" then score = score - 1 end
  elseif eff == E.WEATHER_BALL then
    if w then score = score + 1 end
  elseif eff == E.THIEF or eff == E.KNOCK_OFF or eff == E.TRICK then
    if int3(t.mon.heldItem, 0) ~= 0 and t.ability ~= "STICKY_HOLD" then score = score + 1 end
    if eff == E.THIEF and int3(b.mon.heldItem, 0) ~= 0 then score = score - 1 end
  elseif eff == E.OHKO then
    if theirs < 50 then score = score - 1 end
  end
  -- A damaging move the player's ability would feed (Flash Fire) or a fire
  -- move into rain / water move into sun is priced by the formula already;
  -- a move that does nothing this turn at all is CheckBadMove's to punish.
  if estimate ~= nil and isDamaging(mv, E) and estimate == 0 then score = score - 1 end
  return score
end

return M
