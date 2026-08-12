-- Gen2 move-effect ids and stat-stage multipliers (light port of Gen1 Effects).
--
-- Same 87-slot pret-ordered table as BattleSim/Effects.lua for now; stage and
-- sheet keys are Gen2: atk/def/spe/spa/spd (Sp.Def). Calcium / X_SPECIAL write
-- spa. Held-item hooks and a full Gen2 effect jump table are follow-up.
--
-- No love, no engine modules, no mod facade.

local need = ...

local M = {}

local floor, max, min = math.floor, math.max, math.min

-- pret/pokered effect name order (effect id = index).
M.NAMES = {
  [0] = "NO_ADDITIONAL_EFFECT",
  [1] = "EFFECT_01",
  [2] = "POISON_SIDE_EFFECT1",
  [3] = "DRAIN_HP_EFFECT",
  [4] = "BURN_SIDE_EFFECT1",
  [5] = "FREEZE_SIDE_EFFECT1",
  [6] = "PARALYZE_SIDE_EFFECT1",
  [7] = "EXPLODE_EFFECT",
  [8] = "DREAM_EATER_EFFECT",
  [9] = "MIRROR_MOVE_EFFECT",
  [10] = "ATTACK_UP1_EFFECT",
  [11] = "DEFENSE_UP1_EFFECT",
  [12] = "SPEED_UP1_EFFECT",
  [13] = "SPECIAL_UP1_EFFECT",
  [14] = "ACCURACY_UP1_EFFECT",
  [15] = "EVASION_UP1_EFFECT",
  [16] = "PAY_DAY_EFFECT",
  [17] = "SWIFT_EFFECT",
  [18] = "ATTACK_DOWN1_EFFECT",
  [19] = "DEFENSE_DOWN1_EFFECT",
  [20] = "SPEED_DOWN1_EFFECT",
  [21] = "SPECIAL_DOWN1_EFFECT",
  [22] = "ACCURACY_DOWN1_EFFECT",
  [23] = "EVASION_DOWN1_EFFECT",
  [24] = "CONVERSION_EFFECT",
  [25] = "HAZE_EFFECT",
  [26] = "BIDE_EFFECT",
  [27] = "THRASH_PETAL_DANCE_EFFECT",
  [28] = "SWITCH_AND_TELEPORT_EFFECT",
  [29] = "TWO_TO_FIVE_ATTACKS_EFFECT",
  [30] = "EFFECT_1E",
  [31] = "FLINCH_SIDE_EFFECT1",
  [32] = "SLEEP_EFFECT",
  [33] = "POISON_SIDE_EFFECT2",
  [34] = "BURN_SIDE_EFFECT2",
  [35] = "FREEZE_SIDE_EFFECT2",
  [36] = "PARALYZE_SIDE_EFFECT2",
  [37] = "FLINCH_SIDE_EFFECT2",
  [38] = "OHKO_EFFECT",
  [39] = "CHARGE_EFFECT",
  [40] = "SUPER_FANG_EFFECT",
  [41] = "SPECIAL_DAMAGE_EFFECT",
  [42] = "TRAPPING_EFFECT",
  [43] = "FLY_EFFECT",
  [44] = "ATTACK_TWICE_EFFECT",
  [45] = "JUMP_KICK_EFFECT",
  [46] = "MIST_EFFECT",
  [47] = "FOCUS_ENERGY_EFFECT",
  [48] = "RECOIL_EFFECT",
  [49] = "CONFUSION_EFFECT",
  [50] = "ATTACK_UP2_EFFECT",
  [51] = "DEFENSE_UP2_EFFECT",
  [52] = "SPEED_UP2_EFFECT",
  [53] = "SPECIAL_UP2_EFFECT",
  [54] = "ACCURACY_UP2_EFFECT",
  [55] = "EVASION_UP2_EFFECT",
  [56] = "HEAL_EFFECT",
  [57] = "TRANSFORM_EFFECT",
  [58] = "ATTACK_DOWN2_EFFECT",
  [59] = "DEFENSE_DOWN2_EFFECT",
  [60] = "SPEED_DOWN2_EFFECT",
  [61] = "SPECIAL_DOWN2_EFFECT",
  [62] = "ACCURACY_DOWN2_EFFECT",
  [63] = "EVASION_DOWN2_EFFECT",
  [64] = "LIGHT_SCREEN_EFFECT",
  [65] = "REFLECT_EFFECT",
  [66] = "POISON_EFFECT",
  [67] = "PARALYZE_EFFECT",
  [68] = "ATTACK_DOWN_SIDE_EFFECT",
  [69] = "DEFENSE_DOWN_SIDE_EFFECT",
  [70] = "SPEED_DOWN_SIDE_EFFECT",
  [71] = "SPECIAL_DOWN_SIDE_EFFECT",
  [72] = "UNUSED",
  [73] = "UNUSED",
  [74] = "UNUSED",
  [75] = "UNUSED",
  [76] = "CONFUSION_SIDE_EFFECT",
  [77] = "TWINEEDLE_EFFECT",
  [78] = "UNUSED",
  [79] = "SUBSTITUTE_EFFECT",
  [80] = "HYPER_BEAM_EFFECT",
  [81] = "RAGE_EFFECT",
  [82] = "MIMIC_EFFECT",
  [83] = "METRONOME_EFFECT",
  [84] = "LEECH_SEED_EFFECT",
  [85] = "SPLASH_EFFECT",
  [86] = "DISABLE_EFFECT",
}

M.CATEGORIES = {
  [0] = "none",
  [1] = "other",
  [2] = "status_side",
  [3] = "drain",
  [4] = "status_side",
  [5] = "status_side",
  [6] = "status_side",
  [7] = "other",
  [8] = "drain",
  [9] = "meta",
  [10] = "stat", [11] = "stat", [12] = "stat", [13] = "stat",
  [14] = "stat", [15] = "stat",
  [16] = "other",
  [17] = "other",
  [18] = "stat", [19] = "stat", [20] = "stat", [21] = "stat",
  [22] = "stat", [23] = "stat",
  [24] = "meta",
  [25] = "meta",
  [26] = "other",
  [27] = "thrash",
  [28] = "flow",
  [29] = "multihit",
  [30] = "other",
  [31] = "status_side",
  [32] = "status_primary",
  [33] = "status_side", [34] = "status_side", [35] = "status_side",
  [36] = "status_side", [37] = "status_side",
  [38] = "fixed",
  [39] = "charge",
  [40] = "fixed",
  [41] = "fixed",
  [42] = "trap",
  [43] = "charge",
  [44] = "multihit",
  [45] = "recoil",
  [46] = "volatile",
  [47] = "volatile",
  [48] = "recoil",
  [49] = "status_primary",
  [50] = "stat", [51] = "stat", [52] = "stat", [53] = "stat",
  [54] = "stat", [55] = "stat",
  [56] = "heal",
  [57] = "meta",
  [58] = "stat", [59] = "stat", [60] = "stat", [61] = "stat",
  [62] = "stat", [63] = "stat",
  [64] = "volatile",
  [65] = "volatile",
  [66] = "status_primary",
  [67] = "status_primary",
  [68] = "status_side", [69] = "status_side", [70] = "status_side",
  [71] = "status_side",
  [72] = "unused", [73] = "unused", [74] = "unused", [75] = "unused",
  [76] = "status_side",
  [77] = "multihit",
  [78] = "unused",
  [79] = "volatile",
  [80] = "flow",
  [81] = "other",
  [82] = "meta",
  [83] = "meta",
  [84] = "volatile",
  [85] = "other",
  [86] = "volatile",
}

M.STAGE_MIN = -6
M.STAGE_MAX = 6

-- Gen1 stage multipliers as percents (25/100 .. 400/100).
M.STAGE_MULT = {
  [-6] = 25, [-5] = 28, [-4] = 33, [-3] = 40, [-2] = 50, [-1] = 66,
  [0] = 100,
  [1] = 150, [2] = 200, [3] = 250, [4] = 300, [5] = 350, [6] = 400,
}

local BY_NAME = {}
for id = 0, 86 do
  BY_NAME[M.NAMES[id]] = id
end

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

function M.idOf(name)
  if type(name) ~= "string" then return nil end
  return BY_NAME[name]
end

function M.nameOf(id)
  id = int(id, nil)
  if id == nil or id < 0 or id > 86 then return nil end
  return M.NAMES[id]
end

function M.category(id)
  id = int(id, nil)
  if id == nil or id < 0 or id > 86 then return nil end
  return M.CATEGORIES[id]
end

function M.clampStage(stage)
  local s = int(stage, 0)
  if s < M.STAGE_MIN then return M.STAGE_MIN end
  if s > M.STAGE_MAX then return M.STAGE_MAX end
  return s
end

function M.stageMult(stage)
  return M.STAGE_MULT[M.clampStage(stage)]
end

function M.applyStage(base, stage)
  return floor(max(0, int(base, 0)) * M.stageMult(stage) / 100)
end

-- Gen1 ApplyBadgeStatBoosts: ×9/8 when the fighter holds the matching badge.
-- `wireStatKey` is atk/def/spe/spa/spd; `badges` is a set of badge ids → true.
local BADGE_FOR_STAT = {
  atk = "BOULDERBADGE",
  def = "THUNDERBADGE",
  spe = "SOULBADGE",
  spa = "VOLCANOBADGE",
  spd = "MARSHBADGE",
}

function M.badgeBoost(statValue, wireStatKey, badges)
  local base = max(0, int(statValue, 0))
  if type(badges) ~= "table" then return base end
  local badge = BADGE_FOR_STAT[wireStatKey]
  if not badge or not badges[badge] then return base end
  return floor(base * 9 / 8)
end

-- ------------------------------------------------------------------
-- Phase 1 primary handlers
-- ------------------------------------------------------------------

local STAT_LABELS = {
  atk = "ATTACK", def = "DEFENSE", spe = "SPEED",
  spa = "SP.ATK", spd = "SP.DEF", acc = "ACCURACY", eva = "EVASION",
}

-- effect id -> { stat, delta, selfTarget }
local STAT_EFFECTS = {
  [10] = { stat = "atk", delta = 1, selfTarget = true },
  [11] = { stat = "def", delta = 1, selfTarget = true },
  [12] = { stat = "spe", delta = 1, selfTarget = true },
  [13] = { stat = "spa", delta = 1, selfTarget = true },
  [14] = { stat = "acc", delta = 1, selfTarget = true },
  [15] = { stat = "eva", delta = 1, selfTarget = true },
  [18] = { stat = "atk", delta = -1, selfTarget = false },
  [19] = { stat = "def", delta = -1, selfTarget = false },
  [20] = { stat = "spe", delta = -1, selfTarget = false },
  [21] = { stat = "spa", delta = -1, selfTarget = false },
  [22] = { stat = "acc", delta = -1, selfTarget = false },
  [23] = { stat = "eva", delta = -1, selfTarget = false },
  [50] = { stat = "atk", delta = 2, selfTarget = true },
  [51] = { stat = "def", delta = 2, selfTarget = true },
  [52] = { stat = "spe", delta = 2, selfTarget = true },
  [53] = { stat = "spa", delta = 2, selfTarget = true },
  [54] = { stat = "acc", delta = 2, selfTarget = true },
  [55] = { stat = "eva", delta = 2, selfTarget = true },
  [58] = { stat = "atk", delta = -2, selfTarget = false },
  [59] = { stat = "def", delta = -2, selfTarget = false },
  [60] = { stat = "spe", delta = -2, selfTarget = false },
  [61] = { stat = "spa", delta = -2, selfTarget = false },
  [62] = { stat = "acc", delta = -2, selfTarget = false },
  [63] = { stat = "eva", delta = -2, selfTarget = false },
}

local PHASE1_PRIMARY = {
  [10] = true, [11] = true, [12] = true, [13] = true, [14] = true, [15] = true,
  [18] = true, [19] = true, [20] = true, [21] = true, [22] = true, [23] = true,
  [25] = true, [32] = true, [49] = true, [50] = true, [51] = true, [52] = true,
  [53] = true, [54] = true, [55] = true, [56] = true, [58] = true, [59] = true,
  [60] = true, [61] = true, [62] = true, [63] = true, [66] = true, [67] = true,
  [84] = true, [85] = true, [86] = true,
}

function M.isPhase1Primary(effectId)
  effectId = int(effectId, nil)
  if effectId == nil then return false end
  return PHASE1_PRIMARY[effectId] == true
end

local PHASE5_VOLATILE = {
  [24] = true, [46] = true, [47] = true, [57] = true,
  [64] = true, [65] = true, [79] = true,
}

local PHASE6_PRIMARY = {
  [82] = true, -- MIMIC_EFFECT
}

function M.isPhase5Volatile(effectId)
  effectId = int(effectId, nil)
  if effectId == nil then return false end
  return PHASE5_VOLATILE[effectId] == true
end

function M.isPhase6Primary(effectId)
  effectId = int(effectId, nil)
  if effectId == nil then return false end
  return PHASE6_PRIMARY[effectId] == true
end

function M.handlesPrimary(effectId)
  return M.isPhase1Primary(effectId) or M.isPhase5Volatile(effectId)
      or M.isPhase6Primary(effectId)
end

function M.hasMajorStatus(mon)
  if not mon or not mon.status then return false end
  local s = mon.status
  return s == "sleep" or s == "poison" or s == "burn"
      or s == "freeze" or s == "paralysis" or s == "toxic"
end

local function fighterFields(fighter)
  return { slot = fighter.slot, side = fighter.side }
end

local function applyStatChange(out, fighter, mon, stat, delta)
  if delta < 0 and mon.mist then
    out.messages[#out.messages + 1] = "But it failed"
    return
  end
  local label = STAT_LABELS[stat] or stat
  local before = M.clampStage(mon.stages[stat])
  local after = M.clampStage(before + delta)
  if after == before then
    if delta > 0 then
      out.messages[#out.messages + 1] =
        mon.species .. "'s " .. label .. " won't go any higher"
    else
      out.messages[#out.messages + 1] =
        mon.species .. "'s " .. label .. " won't go any lower"
    end
    return
  end
  mon.stages[stat] = after
  local verb = delta > 0 and "rose" or "fell"
  local text = mon.species .. "'s " .. label .. " " .. verb
  out.messages[#out.messages + 1] = text
  local fields = fighterFields(fighter)
  fields.amount = after
  fields.text = text
  out.events[#out.events + 1] = { kind = "stat", fields = fields }
end

local function resetStages(mon)
  mon.stages.atk = 0
  mon.stages.def = 0
  mon.stages.spe = 0
  mon.stages.spa = 0
  mon.stages.spd = 0
  mon.stages.acc = 0
  mon.stages.eva = 0
end

-- ctx: effectId, rng, userMon, targetMon, userFighter, targetFighter,
--      moveIndex (1-based), statusToWire
-- Returns { nothing, messages, events, heals } where heals = { amount } for user.
function M.applyPrimary(ctx)
  ctx = ctx or {}
  local out = { nothing = false, messages = {}, events = {}, heals = {}, costs = {}, directDamage = {} }
  local effectId = int(ctx.effectId, 0)
  local userMon = ctx.userMon
  local targetMon = ctx.targetMon
  local userFighter = ctx.userFighter
  local targetFighter = ctx.targetFighter
  local wire = ctx.statusToWire or {}
  local rng = ctx.rng

  if effectId == 85 then -- SPLASH_EFFECT
    out.nothing = true
    return out
  end

  if effectId == 56 then -- HEAL_EFFECT
    local amount = floor(max(1, int(userMon.maxHp, 1)) / 2)
    out.heals[#out.heals + 1] = { amount = amount }
    return out
  end

  if effectId == 25 then -- HAZE_EFFECT
    resetStages(userMon)
    resetStages(targetMon)
    out.messages[#out.messages + 1] = "All stat changes were eliminated"
    return out
  end

  local statFx = STAT_EFFECTS[effectId]
  if statFx then
    local mon = statFx.selfTarget and userMon or targetMon
    local fighter = statFx.selfTarget and userFighter or targetFighter
    applyStatChange(out, fighter, mon, statFx.stat, statFx.delta)
    return out
  end

  if effectId == 32 then -- SLEEP_EFFECT
    if M.hasMajorStatus(targetMon) then
      out.nothing = true
      return out
    end
    local turns = (rng and rng:byte() or 0) % 7 + 1
    targetMon.status = "sleep"
    targetMon.statusTurns = turns
    local token = wire.sleep or "SLP"
    local text = targetMon.species .. " fell asleep"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = token
    fields.text = text
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  if effectId == 66 then -- POISON_EFFECT
    if M.hasMajorStatus(targetMon) then
      out.nothing = true
      return out
    end
    targetMon.status = "poison"
    local token = wire.poison or "PSN"
    local text = targetMon.species .. " was poisoned"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = token
    fields.text = text
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  if effectId == 67 then -- PARALYZE_EFFECT
    if M.hasMajorStatus(targetMon) then
      out.nothing = true
      return out
    end
    targetMon.status = "paralysis"
    local token = wire.paralysis or "PAR"
    local text = targetMon.species .. " is paralyzed"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = token
    fields.text = text
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  if effectId == 49 then -- CONFUSION_EFFECT
    if targetMon.confusion and targetMon.confusion > 0 then
      out.nothing = true
      return out
    end
    local turns = (rng and rng:byte() or 0) % 4 + 2
    targetMon.confusion = turns
    out.messages[#out.messages + 1] = targetMon.species .. " became confused"
    return out
  end

  if effectId == 84 then -- LEECH_SEED_EFFECT
    if targetMon.leechSeed then
      out.nothing = true
      return out
    end
    targetMon.leechSeed = { fromSlot = userFighter.slot }
    local text = targetMon.species .. " was seeded"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.text = text
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  if effectId == 86 then -- DISABLE_EFFECT
    local lastIdx = int(targetMon.lastMoveIndex, 0)
    if lastIdx < 1 or not targetMon.moves[lastIdx] then
      out.nothing = true
      return out
    end
    if targetMon.disable and targetMon.disable.turns and targetMon.disable.turns > 0 then
      out.nothing = true
      return out
    end
    local turns = (rng and rng:byte() or 0) % 4 + 2
    targetMon.disable = { moveIndex = lastIdx, turns = turns }
    local moveId = targetMon.moves[lastIdx].id or "move"
    out.messages[#out.messages + 1] =
      moveId .. " was disabled"
    return out
  end

  if effectId == 79 then -- SUBSTITUTE_EFFECT
    local cost = floor(max(1, int(userMon.maxHp, 1)) / 4)
    if userMon.substitute and userMon.substitute > 0 then
      out.nothing = true
      return out
    end
    if userMon.hp <= cost then
      out.nothing = true
      return out
    end
    userMon.hp = userMon.hp - cost
    userMon.substitute = cost
    out.directDamage = { { amount = cost } }
    out.messages[#out.messages + 1] =
      userMon.species .. " created a substitute"
    return out
  end

  if effectId == 64 then -- LIGHT_SCREEN_EFFECT
    userMon.lightScreen = true
    out.messages[#out.messages + 1] =
      userMon.species .. " created a light screen"
    return out
  end

  if effectId == 65 then -- REFLECT_EFFECT
    userMon.reflect = true
    out.messages[#out.messages + 1] =
      userMon.species .. " created a reflect"
    return out
  end

  if effectId == 46 then -- MIST_EFFECT
    userMon.mist = true
    out.messages[#out.messages + 1] =
      userMon.species .. " is shrouded in mist"
    return out
  end

  if effectId == 47 then -- FOCUS_ENERGY_EFFECT
    userMon.focusEnergy = true
    out.messages[#out.messages + 1] =
      userMon.species .. " is getting pumped"
    return out
  end

  if effectId == 24 then -- CONVERSION_EFFECT
    local foeType = targetMon.types[1] or 0
    userMon.types = { foeType }
    out.messages[#out.messages + 1] =
      userMon.species .. " converted type"
    return out
  end

  if effectId == 82 then -- MIMIC_EFFECT
    local moveIndex = int(ctx.moveIndex, 0)
    local lastIdx = int(targetMon.lastMoveIndex, 0)
    if lastIdx < 1 or lastIdx > #targetMon.moves then
      out.nothing = true
      return out
    end
    local source = targetMon.moves[lastIdx]
    if not source then
      out.nothing = true
      return out
    end
    userMon.moves[moveIndex] = {
      id = source.id or "move",
      pp = max(0, int(source.pp, 0)),
      power = max(0, int(source.power, 0)),
      accuracy = max(0, int(source.accuracy, 255)),
      type = max(0, int(source.type, 0)),
      effect = max(0, int(source.effect, 0)),
      chance = max(0, int(source.chance, 0)),
    }
    out.messages[#out.messages + 1] =
      userMon.species .. " learned " .. (source.id or "move")
    out.movesChanged = true
    return out
  end

  if effectId == 57 then -- TRANSFORM_EFFECT
    userMon.stats.atk = max(1, int(targetMon.stats.atk, 1))
    userMon.stats.def = max(1, int(targetMon.stats.def, 1))
    userMon.stats.spe = max(1, int(targetMon.stats.spe, 1))
    userMon.stats.spa = max(1, int(targetMon.stats.spa, 1))
    userMon.stats.spd = max(1, int(targetMon.stats.spd, 1))
    userMon.types = {}
    for i = 1, #targetMon.types do userMon.types[i] = targetMon.types[i] end
    if #userMon.types == 0 then userMon.types[1] = 0 end
    userMon.stages.atk = M.clampStage(targetMon.stages.atk)
    userMon.stages.def = M.clampStage(targetMon.stages.def)
    userMon.stages.spe = M.clampStage(targetMon.stages.spe)
    userMon.stages.spa = M.clampStage(targetMon.stages.spa)
    userMon.stages.spd = M.clampStage(targetMon.stages.spd)
    userMon.stages.acc = M.clampStage(targetMon.stages.acc)
    userMon.stages.eva = M.clampStage(targetMon.stages.eva)
    local copied = {}
    for i = 1, #targetMon.moves do
      local m = targetMon.moves[i]
      copied[#copied + 1] = {
        id = m.id or "move",
        pp = max(0, int(m.pp, 0)),
        power = max(0, int(m.power, 0)),
        accuracy = max(0, int(m.accuracy, 255)),
        type = max(0, int(m.type, 0)),
        effect = max(0, int(m.effect, 0)),
        chance = max(0, int(m.chance, 0)),
      }
    end
    userMon.moves = copied
    userMon.transformed = true
    out.messages[#out.messages + 1] =
      userMon.species .. " transformed into " .. targetMon.species
    out.movesChanged = true
    return out
  end

  out.nothing = true
  return out
end

-- ------------------------------------------------------------------
-- Phase 2 side-chance handlers (post-damage, damaging hits only)
-- ------------------------------------------------------------------

-- Same 1/256 quirk as Accuracy.lua: byte is 0..255, threshold is
-- floor(chance * 255 / 100), proc when byte < threshold.  chance 0 never;
-- chance 100 is byte < 255 (always except the 1/256 roll of 255).
function M.sideChanceProc(rng, chance)
  chance = max(0, min(100, int(chance, 0)))
  if chance <= 0 then return false end
  local threshold = floor(chance * 255 / 100)
  if threshold <= 0 then return false end
  return rng and rng:byte() < threshold
end

local SIDE_STAT_DOWN = {
  [68] = "atk", [69] = "def", [70] = "spe", [71] = "spa",
}

-- ctx: effectId, chance, rng, targetMon, targetFighter, statusToWire
-- Returns { proc, messages, events }.
function M.applySide(ctx)
  ctx = ctx or {}
  local out = { proc = false, messages = {}, events = {} }
  local effectId = int(ctx.effectId, 0)
  local chance = int(ctx.chance, 0)
  local rng = ctx.rng
  local targetMon = ctx.targetMon
  local targetFighter = ctx.targetFighter
  local wire = ctx.statusToWire or {}

  if not M.sideChanceProc(rng, chance) then return out end
  out.proc = true

  if effectId == 2 or effectId == 33 or effectId == 77 then -- poison / twineedle
    if M.hasMajorStatus(targetMon) then return out end
    targetMon.status = "poison"
    local token = wire.poison or "PSN"
    local text = targetMon.species .. " was poisoned"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = token
    fields.text = text
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  if effectId == 4 or effectId == 34 then -- burn
    if M.hasMajorStatus(targetMon) then return out end
    targetMon.status = "burn"
    local token = wire.burn or "BRN"
    local text = targetMon.species .. " was burned"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = token
    fields.text = text
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  if effectId == 5 or effectId == 35 then -- freeze
    if M.hasMajorStatus(targetMon) then return out end
    targetMon.status = "freeze"
    local token = wire.freeze or "FRZ"
    local text = targetMon.species .. " was frozen solid"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = token
    fields.text = text
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  if effectId == 6 or effectId == 36 then -- paralysis
    if M.hasMajorStatus(targetMon) then return out end
    targetMon.status = "paralysis"
    local token = wire.paralysis or "PAR"
    local text = targetMon.species .. " is paralyzed"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = token
    fields.text = text
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  if effectId == 31 or effectId == 37 then -- flinch
    targetMon.flinch = true
    return out
  end

  local stat = SIDE_STAT_DOWN[effectId]
  if stat then
    applyStatChange(out, targetFighter, targetMon, stat, -1)
    return out
  end

  if effectId == 76 then -- confusion side
    if targetMon.confusion and targetMon.confusion > 0 then return out end
    local turns = (rng and rng:byte() or 0) % 4 + 2
    targetMon.confusion = turns
    out.messages[#out.messages + 1] = targetMon.species .. " became confused"
    return out
  end

  out.proc = false
  return out
end

-- ------------------------------------------------------------------
-- Phase 3 multi-hit, fixed damage, drain, recoil
-- ------------------------------------------------------------------

local MULTIHIT = { [29] = true, [44] = true, [77] = true }
local FIXED_DAMAGE = { [38] = true, [40] = true, [41] = true }
local DRAIN = { [3] = true, [8] = true }
local RECOIL = { [48] = true }

function M.isMultihit(effectId)
  return MULTIHIT[int(effectId, 0)] == true
end

-- Draws one RNG byte for TWO_TO_FIVE (29) only; fixed counts otherwise.
function M.hitCount(effectId, rng)
  effectId = int(effectId, 0)
  if effectId == 44 or effectId == 77 then return 2 end
  if effectId == 29 then return 2 + (rng and rng:byte() or 0) % 4 end
  return 1
end

function M.isFixedDamage(effectId)
  return FIXED_DAMAGE[int(effectId, 0)] == true
end

function M.isDrain(effectId)
  return DRAIN[int(effectId, 0)] == true
end

function M.isRecoil(effectId)
  return RECOIL[int(effectId, 0)] == true
end

function M.drainAmount(damage)
  return floor(max(0, int(damage, 0)) / 2)
end

function M.recoilAmount(damage)
  return max(1, floor(max(0, int(damage, 0)) / 4))
end

-- ctx: effectId, userMon, targetMon, power, userSpeed, foeSpeed
-- Returns fixed damage, or nil when the effect fails (OHKO speed gate).
function M.fixedDamage(ctx)
  ctx = ctx or {}
  local effectId = int(ctx.effectId, 0)
  local userMon = ctx.userMon
  local targetMon = ctx.targetMon
  local movePower = int(ctx.power, 0)
  local userSpeed = int(ctx.userSpeed, 0)
  local foeSpeed = int(ctx.foeSpeed, 0)

  if effectId == 38 then
    if userSpeed <= foeSpeed then return nil end
    return max(1, int(targetMon.hp, 0))
  end
  if effectId == 40 then
    return max(1, floor(int(targetMon.hp, 0) / 2))
  end
  if effectId == 41 then
    if movePower >= 1 then return movePower end
    return max(1, int(userMon.level, 1))
  end
  return nil
end

-- ------------------------------------------------------------------
-- Phase 4 multi-turn / charge handlers
-- ------------------------------------------------------------------

function M.isCharge(effectId)
  local id = int(effectId, 0)
  return id == 39 or id == 43
end

function M.isFly(effectId)
  return int(effectId, 0) == 43
end

function M.chargeMessage(mon, effectId)
  if M.isFly(effectId) then
    return mon.species .. " flew up high"
  end
  return mon.species .. " is glowing"
end

function M.isTrapping(effectId)
  return int(effectId, 0) == 42
end

function M.trapTurns(rng)
  return 2 + (rng and rng:byte() or 0) % 4
end

function M.isHyperBeam(effectId)
  return int(effectId, 0) == 80
end

function M.isThrash(effectId)
  return int(effectId, 0) == 27
end

function M.thrashTurns(rng)
  return 2 + (rng and rng:byte() or 0) % 2
end

function M.isRage(effectId)
  return int(effectId, 0) == 81
end

-- Gen1: Reflect halves physical, Light Screen halves special.  `isSpecial`
-- comes from Effects.isSpecialType(move.type, battle.specialTypes).
function M.screenDamage(damage, defender, isSpecial)
  local d = max(0, int(damage, 0))
  if isSpecial then
    if defender.lightScreen then d = floor(d / 2) end
  else
    if defender.reflect then d = floor(d / 2) end
  end
  return d
end

-- Gen1 category is type-based (Fire/Water/…/Dragon → Special; else Physical).
-- `specialTypes` is a set of chart indices uploaded with the ruleset; absent
-- or empty means every damaging move stays Physical (atk/def).
function M.isSpecialType(typeId, specialTypes)
  if type(specialTypes) ~= "table" then return false end
  return specialTypes[int(typeId, 0)] == true
end

-- Hand-authored Gen1 battle items (public heal amounts / X-item stages).
-- Unknown ids return nil; Turn announces "But it failed" and still spends the
-- turn (no silent soft-stall on junk ids). Hub bag proofs (PROTOCOL 15) refuse
-- / debit against the uploaded sheet; clients still debit save.inventory.
local ITEM_STATUS = {
  ANTIDOTE = { poison = true, toxic = true },
  BURN_HEAL = { burn = true },
  ICE_HEAL = { freeze = true },
  AWAKENING = { sleep = true },
  PARLYZ_HEAL = { paralysis = true },
  FULL_HEAL = {
    poison = true, toxic = true, burn = true,
    freeze = true, sleep = true, paralysis = true,
  },
  -- Gen 2 berries (same clear sets as the Gen1 cures they replaced).
  PSNCUREBERRY = { poison = true, toxic = true },
  PRZCUREBERRY = { paralysis = true },
  BURNT_BERRY = { freeze = true },
  ICE_BERRY = { burn = true },
  MINT_BERRY = { sleep = true },
  MIRACLEBERRY = {
    poison = true, toxic = true, burn = true,
    freeze = true, sleep = true, paralysis = true,
  },
}
-- Wire keys match Gen1 ids (X_DEFEND, not X_DEFENSE). X_ACCURACY is a flag.
local ITEM_X_STAGE = {
  X_ATTACK = "atk", X_DEFEND = "def", X_SPEED = "spe", X_SPECIAL = "spa",
}
local ITEM_VITAMIN = {
  HP_UP = "hp", PROTEIN = "atk", IRON = "def",
  CARBOS = "spe", CALCIUM = "spa",
}
-- Gen1 vitamins add 2560 Stat Exp and fail once that pool is already ≥ 25600.
M.VITAMIN_GAIN = 2560
M.VITAMIN_FAIL_AT = 25600

local ITEM_BALL = {
  POKE_BALL = true, GREAT_BALL = true, ULTRA_BALL = true,
  MASTER_BALL = true, SAFARI_BALL = true,
  -- Gen 2 Kurt / Park balls (hub treats as ball=true; catch math stays local).
  LEVEL_BALL = true, LURE_BALL = true, MOON_BALL = true, FRIEND_BALL = true,
  FAST_BALL = true, HEAVY_BALL = true, LOVE_BALL = true, PARK_BALL = true,
}

local ITEM_HEAL = {
  POTION = 20, SUPER_POTION = 50, HYPER_POTION = 200,
  FRESH_WATER = 50, SODA_POP = 60, LEMONADE = 80,
  BERRY = 10, BERRY_JUICE = 20,
}

-- Deliberately absent from itemEffect (unknown → "But it failed", still spend
-- the turn; bag upload also omits them via itemIsBattleUsable):
--   PP_UP / PP_UP_2, evolutionary stones, RARE_CANDY, HM/TM,
--   Repel / Super Repel / Max Repel, Escape Rope, and other field-only ids.
-- In-battle catalog covered above: heals, status cures, Revive/Ether/Elixer,
-- X-items / Dire Hit / Guard Spec, balls, Poké Doll, Poké Flute, vitamins.

function M.itemEffect(itemId)
  if type(itemId) ~= "string" or itemId == "" then return nil end
  if itemId == "MAX_POTION" then
    return { healFull = true, needsParty = true }
  end
  if itemId == "FULL_RESTORE" then
    return { healFull = true, clearAllStatus = true, needsParty = true }
  end
  if itemId == "REVIVE" then
    return { revive = 0.5, needsParty = true, faintedOnly = true }
  end
  if itemId == "MAX_REVIVE" then
    return { revive = 1, needsParty = true, faintedOnly = true }
  end
  if itemId == "ETHER" then
    return { ppRestore = 10, needsParty = true, needsMove = true }
  end
  if itemId == "MAX_ETHER" then
    return { ppRestore = true, needsParty = true, needsMove = true }
  end
  if itemId == "ELIXER" or itemId == "ELIXIR" then
    return { ppRestoreAll = 10, needsParty = true }
  end
  if itemId == "MAX_ELIXER" or itemId == "MAX_ELIXIR" then
    return { ppRestoreAll = true, needsParty = true }
  end
  if itemId == "X_ACCURACY" then
    return { xAccuracy = true, activeOnly = true }
  end
  if itemId == "DIRE_HIT" then
    return { focusEnergy = true, activeOnly = true }
  end
  if itemId == "GUARD_SPEC" then
    return { mist = true, activeOnly = true }
  end
  if itemId == "POKE_DOLL" then
    return { pokeDoll = true }
  end
  if itemId == "POKE_FLUTE" then
    -- Key item: wakes sleep on every battler's party; never consumed.
    return { pokeFlute = true, noConsume = true }
  end
  local stageStat = ITEM_X_STAGE[itemId]
  if stageStat then
    return { stage = { stat = stageStat, delta = 1 }, activeOnly = true }
  end
  local vitaminStat = ITEM_VITAMIN[itemId]
  if vitaminStat then
    -- Fight-local Stat Exp on the uploaded sheet; the client writebacks
    -- save.statExp on confirm. No permanent EV store on the hub itself.
    return { vitamin = true, vitaminStat = vitaminStat, needsParty = true }
  end
  if ITEM_BALL[itemId] then
    return { ball = true }
  end
  local heal = ITEM_HEAL[itemId]
  local statuses = ITEM_STATUS[itemId]
  if not heal and not statuses then return nil end
  return { heal = heal, clearStatuses = statuses, needsParty = true }
end

-- Apply a Gen1 vitamin to a battle mon sheet. Mutates `mon.evs` and battle
-- stats / maxHp. Returns result table or nil when it fails.
function M.applyVitamin(mon, itemId)
  if type(mon) ~= "table" then return nil end
  local effect = M.itemEffect(itemId)
  local stat = effect and effect.vitaminStat
  if not stat then return nil end
  mon.evs = mon.evs or {}
  local before = math.max(0, int(mon.evs[stat], 0))
  if before >= M.VITAMIN_FAIL_AT then return nil end
  local after = math.min(65535, before + M.VITAMIN_GAIN)
  mon.evs[stat] = after
  local function contrib(ev)
    return math.floor(math.sqrt(math.max(0, ev)) / 4)
  end
  local level = math.max(1, int(mon.level, 1))
  local delta = math.floor((contrib(after) - contrib(before)) * level / 100)
  if stat == "hp" then
    mon.maxHp = math.max(1, int(mon.maxHp, 1) + delta)
    mon.hp = math.min(mon.maxHp, int(mon.hp, 0) + delta)
  else
    mon.stats = mon.stats or {}
    mon.stats[stat] = math.max(1, int(mon.stats[stat], 1) + delta)
  end
  return { stat = stat, delta = delta, before = before, after = after }
end

-- Sheet snapshot for a catch outcome (battleMon-shaped).
function M.caughtSheet(mon)
  if type(mon) ~= "table" then return nil end
  local moves = {}
  for i = 1, #(mon.moves or {}) do
    local m = mon.moves[i]
    if m then
      moves[#moves + 1] = {
        id = m.id or "move",
        pp = math.max(0, int(m.pp, 0)),
        power = math.max(0, int(m.power, 0)),
        accuracy = math.max(0, int(m.accuracy, 255)),
        type = math.max(0, int(m.type, 0)),
        effect = math.max(0, int(m.effect, 0)),
        chance = math.max(0, int(m.chance, 0)),
      }
    end
  end
  if #moves == 0 then return nil end
  local out = {
    species = tostring(mon.species or "?"),
    level = math.max(1, int(mon.level, 1)),
    hp = math.max(0, int(mon.hp, 0)),
    maxHp = math.max(1, int(mon.maxHp, 1)),
    stats = {
      atk = math.max(1, int(mon.stats and mon.stats.atk, 1)),
      def = math.max(1, int(mon.stats and mon.stats.def, 1)),
      spe = math.max(1, int(mon.stats and mon.stats.spe, 1)),
      spa = math.max(1, int(mon.stats and mon.stats.spa, 1)),
      spd = math.max(1, int(mon.stats and mon.stats.spd, 1)),
    },
    moves = moves,
    catchRate = math.max(0, math.min(255, int(mon.catchRate, 255))),
  }
  if mon.speciesId then out.speciesId = tostring(mon.speciesId) end
  if type(mon.types) == "table" then out.types = mon.types end
  return out
end

-- Gen1 ItemUseBall factors (engine/items/item_effects.asm). Public constants.
local BALL_DEFS = {
  MASTER_BALL = { autoCatch = true },
  POKE_BALL   = { randMax = 255, hpFactor = 12, wobbleFactor = 255 },
  GREAT_BALL  = { randMax = 200, hpFactor = 8,  wobbleFactor = 200 },
  ULTRA_BALL  = { randMax = 150, hpFactor = 12, wobbleFactor = 150 },
  SAFARI_BALL = { randMax = 150, hpFactor = 12, wobbleFactor = 150 },
}
local BALL_DEFAULT = { randMax = 255, hpFactor = 12, wobbleFactor = 150 }

local function catchRoll(rng, maxV)
  maxV = max(0, int(maxV, 0))
  if maxV <= 0 then return 0 end
  if maxV >= 255 then return rng and rng:byte() or 0 end
  return (rng and rng:byte() or 0) % (maxV + 1)
end

-- Returns caught, shakes (0-3).  RNG order: catch roll, then HP roll when
-- the first roll passed the rate check.  Wobble math draws nothing.
function M.catchAttempt(ballId, targetMon, rng)
  local def = BALL_DEFS[ballId] or BALL_DEFAULT
  if def.autoCatch then return true, 3 end

  local rate = int(targetMon and targetMon.catchRate, 255)
  if rate < 0 then rate = 0 elseif rate > 255 then rate = 255 end

  local statusBonus, shakeBonus = 0, 5
  local s = targetMon and targetMon.status
  if s == "sleep" or s == "freeze" then
    statusBonus, shakeBonus = 25, 10
  elseif s then
    statusBonus, shakeBonus = 12, 5
  end

  local maxhp = max(1, int(targetMon and targetMon.maxHp, 1))
  local hp = max(0, int(targetMon and targetMon.hp, 0))
  local hpQuarter = max(1, floor(hp / 4))
  local factor = def.hpFactor or BALL_DEFAULT.hpFactor
  local f = min(255, floor(floor(maxhp * 255 / factor) / hpQuarter))

  local function shakes()
    local ballFactor2 = def.wobbleFactor or BALL_DEFAULT.wobbleFactor
    local y = floor(rate * 100 / ballFactor2)
    local z
    if y > 255 then
      z = 255
    else
      z = floor(f * y / 255)
    end
    if s then z = z + shakeBonus end
    if z < 10 then return 0 elseif z < 30 then return 1
    elseif z < 70 then return 2 else return 3 end
  end

  local r = catchRoll(rng, def.randMax or 255) - statusBonus
  if r < 0 then return true, 3 end
  if r > rate then return false, shakes() end
  if catchRoll(rng, 255) <= f then return true, 3 end
  return false, shakes()
end

function M.isWildMode(mode)
  return type(mode) == "string" and mode:find("wild", 1, true) ~= nil
end

-- ------------------------------------------------------------------
-- Phase 6 meta / flow handlers
-- ------------------------------------------------------------------

local NO_OP = {
  [1] = true, [30] = true,
  [72] = true, [73] = true, [74] = true, [75] = true, [78] = true,
}

function M.isNoOp(effectId)
  return NO_OP[int(effectId, 0)] == true
end

function M.isBide(effectId)
  return int(effectId, 0) == 26
end

function M.bideTurns(rng)
  return 2 + (rng and rng:byte() or 0) % 2
end

function M.isExplode(effectId)
  return int(effectId, 0) == 7
end

function M.isJumpKick(effectId)
  return int(effectId, 0) == 45
end

function M.jumpKickCrash(maxHp)
  return max(1, floor(max(1, int(maxHp, 1)) / 8))
end

function M.isSwitchAndTeleport(effectId)
  return int(effectId, 0) == 28
end

-- Mediated modes (1v1, coop_*) have no wild flee; only modes whose name
-- contains "wild" may treat Teleport as a successful run.
function M.teleportRunAllowed(mode)
  return type(mode) == "string" and mode:find("wild", 1, true) ~= nil
end

function M.isPayDay(effectId)
  return int(effectId, 0) == 16
end

function M.isMirrorMove(effectId)
  return int(effectId, 0) == 9
end

function M.isMimic(effectId)
  return int(effectId, 0) == 82
end

function M.isMetronome(effectId)
  return int(effectId, 0) == 83
end

return M
