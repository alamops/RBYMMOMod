-- Gen2 move-effect ids and stat-stage multipliers (light port of Gen1 Effects).
--
-- Same 87-slot pret-ordered table as BattleSim/Effects.lua for now; stage and
-- sheet keys are Gen2: atk/def/spe/spa/spd (Sp.Def). Calcium / X_SPECIAL write
-- spa. Held-item hooks and a full Gen2 effect jump table are follow-up.
--
-- No love, no engine modules, no mod facade.

local need = ...

-- For the burn / paralysis tail of `battleStat`, so the halving and the
-- quartering are one rule with one owner rather than a second copy here.
local Status = need("BattleSim2/Status")

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

-- BattleCommand_Screen's `ld a, 5`: a Reflect or Light Screen counts five
-- between-turn ticks (HandleScreens), the turn it went up included.
M.SCREEN_TURNS = 5

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

-- Crystal / Gold sheets name effects EFFECT_* (moveEffectOrder), not the
-- pret/pokered *_EFFECT tokens this table is numbered by.  `moveOf` stores
-- `idOf(def.effect) or 0`, so an unmapped name becomes NO_ADDITIONAL_EFFECT
-- and every 0-power status move says "But nothing happened".  That is why
-- Leer / Hypnosis / Screech worked in engine 1v1 (gen2/Battle.lua) and
-- failed in every BattleSim2 fight -- 2v2 co-op, mediated PvP, solo-on.
--
-- Map every EFFECT_* that already has a handler onto that handler.  Gen 2
-- only moves (Protect, Spikes, …) stay unmapped and still no-op honestly.
-- Charge / vanish aliases keep the same ids as before.
local GEN2_EFFECT_ID = {
  EFFECT_NORMAL_HIT = 0,
  EFFECT_SLEEP = 32,
  EFFECT_POISON_HIT = 2,
  EFFECT_LEECH_HIT = 3,
  EFFECT_BURN_HIT = 4,
  EFFECT_FREEZE_HIT = 5,
  EFFECT_PARALYZE_HIT = 6,
  EFFECT_SELFDESTRUCT = 7,
  EFFECT_DREAM_EATER = 8,
  EFFECT_MIRROR_MOVE = 9,
  EFFECT_ATTACK_UP = 10,
  EFFECT_DEFENSE_UP = 11,
  EFFECT_DEFENSE_CURL = 11,
  EFFECT_SPEED_UP = 12,
  EFFECT_SP_ATK_UP = 13,
  EFFECT_ACCURACY_UP = 14,
  EFFECT_EVASION_UP = 15,
  EFFECT_ALWAYS_HIT = 17,
  EFFECT_ATTACK_DOWN = 18,
  EFFECT_DEFENSE_DOWN = 19,
  EFFECT_SPEED_DOWN = 20,
  EFFECT_SP_ATK_DOWN = 21,
  EFFECT_ACCURACY_DOWN = 22,
  EFFECT_EVASION_DOWN = 23,
  EFFECT_CONVERSION = 24,
  EFFECT_RESET_STATS = 25,
  EFFECT_BIDE = 26,
  EFFECT_RAMPAGE = 27,
  EFFECT_FORCE_SWITCH = 28,
  EFFECT_MULTI_HIT = 29,
  EFFECT_FLINCH_HIT = 31,
  EFFECT_PAY_DAY = 16,
  EFFECT_OHKO = 38,
  EFFECT_RAZOR_WIND = 39,
  EFFECT_SOLARBEAM = 39,
  EFFECT_SKULL_BASH = 39,
  EFFECT_SKY_ATTACK = 39,
  EFFECT_SUPER_FANG = 40,
  EFFECT_STATIC_DAMAGE = 41,
  EFFECT_LEVEL_DAMAGE = 41,
  EFFECT_PSYWAVE = 41,
  EFFECT_TRAP_TARGET = 42,
  EFFECT_FLY = 43,
  EFFECT_DOUBLE_HIT = 44,
  EFFECT_JUMP_KICK = 45,
  EFFECT_MIST = 46,
  EFFECT_FOCUS_ENERGY = 47,
  EFFECT_RECOIL_HIT = 48,
  EFFECT_CONFUSE = 49,
  EFFECT_ATTACK_UP_2 = 50,
  EFFECT_DEFENSE_UP_2 = 51,
  EFFECT_SPEED_UP_2 = 52,
  EFFECT_SP_ATK_UP_2 = 53,
  EFFECT_ACCURACY_UP_2 = 54,
  EFFECT_EVASION_UP_2 = 55,
  EFFECT_HEAL = 56,
  EFFECT_MORNING_SUN = 56,
  EFFECT_SYNTHESIS = 56,
  EFFECT_MOONLIGHT = 56,
  EFFECT_TRANSFORM = 57,
  EFFECT_ATTACK_DOWN_2 = 58,
  EFFECT_DEFENSE_DOWN_2 = 59,
  EFFECT_SPEED_DOWN_2 = 60,
  EFFECT_SP_ATK_DOWN_2 = 61,
  EFFECT_ACCURACY_DOWN_2 = 62,
  EFFECT_EVASION_DOWN_2 = 63,
  EFFECT_LIGHT_SCREEN = 64,
  EFFECT_REFLECT = 65,
  EFFECT_POISON = 66,
  EFFECT_TOXIC = 66,
  EFFECT_PARALYZE = 67,
  EFFECT_ATTACK_DOWN_HIT = 68,
  EFFECT_DEFENSE_DOWN_HIT = 69,
  EFFECT_SPEED_DOWN_HIT = 70,
  EFFECT_SP_ATK_DOWN_HIT = 71,
  EFFECT_CONFUSE_HIT = 76,
  EFFECT_POISON_MULTI_HIT = 77,
  EFFECT_SUBSTITUTE = 79,
  EFFECT_HYPER_BEAM = 80,
  EFFECT_RAGE = 81,
  EFFECT_MIMIC = 82,
  EFFECT_METRONOME = 83,
  EFFECT_LEECH_SEED = 84,
  EFFECT_SPLASH = 85,
  EFFECT_DISABLE = 86,
}

function M.idOf(name)
  if type(name) ~= "string" then return nil end
  return BY_NAME[name] or GEN2_EFFECT_ID[name]
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

-- What a move is *called* in a sentence: the display name its sheet carried
-- (PROTOCOL 26), or its registry id when it carried none.  Turn.lua keeps the
-- same one-line rule; both are prose, never a key something indexes.
local function moveLabel(move, fallback)
  fallback = fallback or "move"
  if type(move) ~= "table" then return fallback end
  local name = move.name
  if type(name) == "string" and name ~= "" then return name end
  local id = move.id
  if type(id) == "string" and id ~= "" then return id end
  return fallback
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

-- CalcBattleStats (pokecrystal engine/battle/effect_commands.asm:4817-4875):
-- the unmodified stat times the stage's ratio from data/battle/
-- stat_multipliers.asm, then a quotient of 0 is raised to 1 and one at or past
-- MAX_STAT_VALUE is held at 999.  The cart's ratios are num/den pairs (15/10,
-- 2/1, 25/10 ...); each is the percent above over 100 exactly, so the floor
-- lands on the same integer.
function M.applyStage(base, stage)
  local value = floor(max(0, int(base, 0)) * M.stageMult(stage) / 100)
  if value < 1 then return 1 end
  if value > M.MAX_STAT_VALUE then return M.MAX_STAT_VALUE end
  return value
end

-- Crystal's badge rules, as gen1recomp ports them (src/battle/gen2/Battle.lua,
-- the engine every number here was checked against).  `badges` is a set of
-- Gold badge ids -> true: the eight Johto ids and the eight Kanto ids that
-- name the rows of the engine's BADGE_TYPE_BOOSTS (ZEPHYR ... RISING, BOULDER
-- ... EARTH), which is what a Gold client uploads.  Gen 1's BOULDERBADGE-style
-- ids mean nothing here: Gold has no badge by that name.
--
-- A fighter only holds a set where the cart would have applied it -- side a
-- of a fight against the computer; Turn.create drops it in 1v1 / coop_pvp
-- (link battles, where Crystal's BadgeStatBoosts returns early) and on side b
-- (Turn.BADGE_MODES) -- so nothing below has to ask what kind of fight it is.

-- BadgeStatBoosts (engine/battle/core.asm:6534; port Battle.lua:209-220,
-- BADGE_STAT_BOOSTS): every other wJohtoBadges bit boosts a stat, walked
-- after PlainBadge and MineralBadge swap places, which is what lands Mineral
-- on Defense and Plain on Speed.  Kanto badges boost no stat; Sp. Def has no
-- badge of its own and is only ever reached by Glacier's buggy tail below.
local BADGE_FOR_STAT = {
  atk = "ZEPHYR",
  def = "MINERAL",
  spe = "PLAIN",
  spa = "GLACIER",
}
M.BADGE_FOR_STAT = BADGE_FOR_STAT

-- MAX_STAT_VALUE, the ceiling BoostStat caps a boosted stat at.
M.MAX_STAT_VALUE = 999

-- BoostStat (engine/battle/core.asm:6590; port Battle.lua:787-792):
-- raise a stat by an eighth, capped at MAX_STAT_VALUE.  The eighth is a plain
-- shift, so a stat under 8 gains nothing.
function M.boostStat(value)
  local v = max(0, int(value, 0))
  return min(M.MAX_STAT_VALUE, v + floor(v / 8))
end

-- BadgeStatBoosts' buggy tail (port Battle.lua:794-809, glacierBoostsSpDef):
-- the closing Special Defense check does `srl a` assuming `a` still holds the
-- badge bits, but when GlacierBadge fired for Special Attack the BoostStat
-- before it overwrote `a` with its cap-check arithmetic.  So with Glacier
-- owned, whether Sp. Def is ALSO boosted turns on the boosted Sp. Atk:
--   * at or past the 999 cap `a` leaves as LOW(999) = $e7, odd: boosted;
--   * otherwise `a` is high(v) - 3 - borrow, the borrow set when low(v) <
--     LOW(999), and the bit shifted out of it decides.
-- (pokegold's own comment marks the check buggy.)  `% 256` here is Lua's
-- floored modulo, which is the byte wrap; the JS twin spells it out.
function M.glacierBoostsSpDef(boostedSpa)
  local v = max(0, int(boostedSpa, 0))
  if v >= M.MAX_STAT_VALUE then return true end
  local borrow = (v % 256) < 231 and 1 or 0
  local a = (floor(v / 256) - 3 - borrow) % 256
  return a % 2 == 1
end

-- One stat plus its owner's badge boost.  `wireStatKey` is atk/def/spe/spa/
-- spd.  `spa` is the same monster's Sp. Atk as BadgeStatBoosts finds it --
-- already staged, because CalcPlayerStats runs CalcBattleStats first -- and
-- is read only for `spd`: it is what Glacier's tail is decided on.
function M.badgeBoost(statValue, wireStatKey, badges, spa)
  local base = max(0, int(statValue, 0))
  if type(badges) ~= "table" then return base end
  local badge = BADGE_FOR_STAT[wireStatKey]
  if badge then
    if badges[badge] then return M.boostStat(base) end
    return base
  end
  if wireStatKey == "spd" and badges.GLACIER
     and M.glacierBoostsSpDef(M.boostStat(spa)) then
    return M.boostStat(base)
  end
  return base
end

-- The stat a hit, the turn order or a confusion self-hit reads: the battle
-- stat, rebuilt the way CalcPlayerStats does it (pokecrystal engine/battle/
-- effect_commands.asm:4778-4797) --
--
--   1. CalcBattleStats: the unmodified stat x the stage ratio, 1..999
--      (`applyStage`);
--   2. BadgeStatBoosts (engine/battle/core.asm:6768): +1/8, held at 999, and
--      Glacier's Sp. Def tail reading the staged-then-boosted Sp. Atk;
--   3. ApplyPrzEffectOnSpeed / ApplyBrnEffectOnAttack (core.asm:6585-6669):
--      paralysis quarters Speed and burn halves Attack, each at least 1.
--
-- Read-time rather than stored (docs/plans/gen12-referee-fidelity.md,
-- decision 2): the cart rebuilds every stat from the raw one on each stage
-- change and on a status-cure item (HealStatus farcalls CalcPlayerStats), and
-- a status landing mid-fight cuts the stat it finds -- already staged and
-- boosted -- so the order above is what a hit reads.  The one place the cart
-- reads otherwise is written down rather than modelled: a switch-in loads the
-- party stats and runs the status penalty BEFORE BadgeStatBoosts (core.asm:
-- 3904-3906), so a burned or paralysed switch-in holding ZEPHYR / PLAIN can
-- sit a point off this until its first stage change.
--
-- `mon` is a sheet: { stats, stages, status }.  `badges` is its seat's set
-- (nil for every seat the cart would not boost; see Turn.BADGE_MODES).
function M.battleStat(mon, key, badges)
  mon = type(mon) == "table" and mon or {}
  local stats = type(mon.stats) == "table" and mon.stats or {}
  local stages = type(mon.stages) == "table" and mon.stages or {}
  local value = M.applyStage(stats[key], stages[key])
  local spa = nil
  if key == "spd" then spa = M.applyStage(stats.spa, stages.spa) end
  value = M.badgeBoost(value, key, badges, spa)
  if key == "atk" and mon.status == "burn" then value = Status.burnAttack(value) end
  if key == "spe" and mon.status == "paralysis" then
    value = Status.paralysisSpeed(value)
  end
  return value
end

-- DoBadgeTypeBoosts (pokecrystal engine/battle/misc.asm:146; port
-- Battle.lua:835-848, badgeTypeBoost; rows from data/types/
-- badge_type_boosts.asm in the cart's own walk order -- the eight wJohtoBadges
-- bits, then the eight wKantoBadges bits).  On the player's turn the move's
-- type is looked up here, each type at most once, and owning that row's badge
-- adds an eighth to the damage (Damage.compute's `badgeTypeBoost`).  `type`
-- is the type's registry id, which the ruleset's `typeIds` resolves a move's
-- chart index to -- PSYCHIC_TYPE is Psychic's, because PSYCHIC is a move.
M.BADGE_TYPE_BOOSTS = {
  { badge = "ZEPHYR", type = "FLYING" },
  { badge = "HIVE", type = "BUG" },
  { badge = "PLAIN", type = "NORMAL" },
  { badge = "FOG", type = "GHOST" },
  { badge = "MINERAL", type = "STEEL" },
  { badge = "STORM", type = "FIGHTING" },
  { badge = "GLACIER", type = "ICE" },
  { badge = "RISING", type = "DRAGON" },
  { badge = "BOULDER", type = "ROCK" },
  { badge = "CASCADE", type = "WATER" },
  { badge = "THUNDER", type = "ELECTRIC" },
  { badge = "RAINBOW", type = "GRASS" },
  { badge = "SOUL", type = "POISON" },
  { badge = "MARSH", type = "PSYCHIC_TYPE" },
  { badge = "VOLCANO", type = "FIRE" },
  { badge = "EARTH", type = "GROUND" },
}

-- Whether a move of type `typeId` is boosted for a fighter holding `badges`.
-- The first row naming the type answers, as the cart's scan does.
function M.badgeTypeBoost(typeId, badges)
  if type(badges) ~= "table" or type(typeId) ~= "string" then return false end
  for _, row in ipairs(M.BADGE_TYPE_BOOSTS) do
    if row.type == typeId then return badges[row.badge] == true end
  end
  return false
end

-- ------------------------------------------------------------------
-- Phase 1 primary handlers
-- ------------------------------------------------------------------

local STAT_LABELS = {
  atk = "ATTACK", def = "DEFENSE", spe = "SPEED",
  spa = "SP.ATK", spd = "SP.DEF", acc = "ACCURACY", eva = "EVASION",
}
M.STAT_LABELS = STAT_LABELS

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

-- Confusion is a volatile, not a major status: it does not occupy `mon.status`
-- and does not persist on the party sheet. The chip is a `confused` flag on
-- the status event (1 inflicted, 0 snapped out), independent of PSN/SLP/…
local function confuse(out, fighter, mon, rng, failIfAlready)
  if mon.confusion and mon.confusion > 0 then
    if failIfAlready then out.nothing = true end
    return
  end
  local turns = (rng and rng:byte() or 0) % 4 + 2
  mon.confusion = turns
  local text = mon.species .. " became confused"
  out.messages[#out.messages + 1] = text
  local fields = fighterFields(fighter)
  fields.confused = 1
  fields.text = text
  out.events[#out.events + 1] = { kind = "status", fields = fields }
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

-- Every stage back to 0.  Haze, and the levels a monster leaves behind:
-- pokecrystal keeps one set of stat levels per side (wPlayerStatLevels) and
-- refills it on every send-out (ResetPlayerStatLevels, engine/battle/
-- core.asm:3944), so a monster that switches in or faints brings no stage
-- with it -- the referee keeps them per monster and clears them at those two
-- points instead (Turn `_resolveSwitches` / `_faint`).
local function resetStages(mon)
  mon.stages.atk = 0
  mon.stages.def = 0
  mon.stages.spe = 0
  mon.stages.spa = 0
  mon.stages.spd = 0
  mon.stages.acc = 0
  mon.stages.eva = 0
end
M.resetStages = resetStages

-- BattleCommand_StatDown's `.ComputerMiss` byte (pokecrystal engine/battle/
-- effect_commands.asm:4320-4440; pokegold the same but for Crystal's Battle
-- Tower exemption, which no fight here is): `cp 25 percent + 1`, and RGBDS
-- `percent` is `* $ff / 100` in integer arithmetic, so 63 + 1 -- the computer
-- misses on a byte under 64.
M.COMPUTER_DROP_MISS = 64

-- The stat a primary stat-down move lowers (ATTACK_DOWN ... EVASION_DOWN and
-- the _2 rows), or nil.  The *DownHit side effects are SIDE_STAT_DOWN below.
function M.primaryStatDown(effectId)
  local statFx = STAT_EFFECTS[int(effectId, -1)]
  if statFx and statFx.delta < 0 and not statFx.selfTarget then return statFx.stat end
  return nil
end

-- BattleCommand_StatDown up to `.DidntMiss`, the one routine a primary
-- stat-down move (`attackdown` after `checkhit`) and a *DownHit side effect
-- (`attackdown` after `buildopponentrage`) both run, in its order:
--
--   1. CheckMist: the target's SUBSTATUS_MIST -> `.Mist`;
--   2. the stage already at -6 (`dec b / jp z, .CantLower`) -> `.CantLower`
--      -- a -2 drop from -5 goes on, its `dec b / jr nz` / `inc b` stopping
--      it at -6;
--   3. `.ComputerMiss`: on the enemy's turn outside a link battle
--      (`computerMover`, Turn's isComputerSeat) a BattleRandom under
--      M.COMPUTER_DROP_MISS -> `.Failed`.  The exemption it skips the byte for
--      -- EFFECT_ACCURACY_DOWN_HIT, the attacking moves that lower accuracy --
--      is not an effect this table maps (Gold's MUD-SLAP / OCTAZOOKA fold to
--      0, known gaps), and neither is Lock-On, so every stat-down move here
--      draws it.
--
-- Nothing before the byte asks whether the move hit, whether a substitute
-- stands or whether the side effect's chance landed: `checkhit` only set
-- wAttackMissed, a substitute is CheckSubstituteOpp at `.DidntMiss`, and
-- wEffectFailed is read after that -- so the computer draws it for a missed
-- GROWL, for a hit into a substitute and for an AURORA BEAM whose chance
-- byte failed alike.  Returns "mist", "floor" or "missed" for the step that
-- stopped the drop, or nil when it goes on to `.DidntMiss`.
function M.statDownGate(rng, targetMon, stat, computerMover)
  if targetMon.mist then return "mist" end
  if M.clampStage(targetMon.stages[stat]) <= M.STAGE_MIN then return "floor" end
  if computerMover and rng and rng:byte() < M.COMPUTER_DROP_MISS then
    return "missed"
  end
  return nil
end

-- Cartridge Substitute blocks foe-targeting primaries (Sleep Powder, Growl,
-- Disable, Transform, Mimic). Self-targeting (Recover, Swords Dance,
-- Substitute) and field-wide Haze still run; Conversion copies onto the user.
-- A stat-down move meets the substitute later, inside BattleCommand_StatDown
-- (`applyPrimary` below), so it is not stopped here.
local function blockedBySubstitute(effectId)
  local statFx = STAT_EFFECTS[effectId]
  if statFx then return false end
  if effectId == 24 or effectId == 25 or effectId == 46 or effectId == 47
      or effectId == 56 or effectId == 64 or effectId == 65
      or effectId == 79 or effectId == 85 then
    return false
  end
  return true
end

-- ctx: effectId, rng, userMon, targetMon, userFighter, targetFighter,
--      moveIndex (1-based), statusToWire, userScreens (the user's side's
--      screen counts; see LIGHT_SCREEN_EFFECT below), computerMover (the
--      move is the computer's: BattleCommand_StatDown's extra miss)
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

  if targetMon and (targetMon.substitute or 0) > 0 and blockedBySubstitute(effectId) then
    out.nothing = true
    return out
  end

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
    if not statFx.selfTarget then
      -- BattleCommand_StatDown's own order (statDownGate): Mist and a stage
      -- at -6 first -- applyStatChange says their lines, "But it failed" and
      -- "won't go any lower", as before -- then the computer's byte, whose
      -- miss is `.Failed` ("But it failed!", TryPrintButItFailed), and only
      -- then the substitute (CheckSubstituteOpp at `.DidntMiss`).
      local stop = M.statDownGate(rng, mon, statFx.stat, ctx.computerMover == true)
      if stop == "missed" then
        out.messages[#out.messages + 1] = "But it failed"
        return out
      end
      if stop == nil and (mon.substitute or 0) > 0 then
        out.nothing = true
        return out
      end
    end
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
    confuse(out, targetFighter, targetMon, rng, true)
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
    out.messages[#out.messages + 1] =
      moveLabel(targetMon.moves[lastIdx]) .. " was disabled"
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

  -- BattleCommand_Screen (pokecrystal engine/battle/effect_commands.asm:
  -- 6147-6188): a screen belongs to the user's SIDE (wPlayerScreens), lasts
  -- SCREEN_TURNS, and a second cast while it is up fails ("But it failed!")
  -- rather than refreshing the count.  `ctx.userScreens` is the side's
  -- { lightScreen, reflect } turn counts (Turn's `self.screens[side]`), which
  -- the between-turn tick counts down; nothing else ever clears them.
  if effectId == 64 or effectId == 65 then -- LIGHT_SCREEN_EFFECT / REFLECT_EFFECT
    local key = effectId == 64 and "lightScreen" or "reflect"
    local screens = ctx.userScreens
    if type(screens) ~= "table" or int(screens[key], 0) > 0 then
      out.messages[#out.messages + 1] = "But it failed"
      return out
    end
    screens[key] = M.SCREEN_TURNS
    out.messages[#out.messages + 1] = userMon.species
      .. (effectId == 64 and " created a light screen" or " created a reflect")
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
      -- The copy is narrated under the same name the original was, so a
      -- mimicked move does not revert to its slug on the learner's screen.
      name = source.name,
      pp = max(0, int(source.pp, 0)),
      power = max(0, int(source.power, 0)),
      accuracy = max(0, int(source.accuracy, 255)),
      type = max(0, int(source.type, 0)),
      effect = max(0, int(source.effect, 0)),
      chance = max(0, int(source.chance, 0)),
      highCrit = source.highCrit == true,
    }
    out.messages[#out.messages + 1] =
      userMon.species .. " learned " .. moveLabel(source)
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
        name = m.name,
        pp = max(0, int(m.pp, 0)),
        power = max(0, int(m.power, 0)),
        accuracy = max(0, int(m.accuracy, 255)),
        type = max(0, int(m.type, 0)),
        effect = max(0, int(m.effect, 0)),
        chance = max(0, int(m.chance, 0)),
        highCrit = m.highCrit == true,
      }
    end
    userMon.moves = copied
    userMon.transformed = true
    -- BattleCommand_Transform copies the target's species into the battle
    -- struct (wBattleMonSpecies), which BattleCommand_Critical's Lucky Punch /
    -- Stick check reads; the party species -- `speciesId`, untouched -- is what
    -- Light Ball, Thick Club and Metal Powder read (Items.lua).
    userMon.transformSpecies = targetMon.speciesId
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
local SIDE_POISON = { [2] = true, [33] = true, [77] = true }
local SIDE_BURN = { [4] = true, [34] = true }
local SIDE_FREEZE = { [5] = true, [35] = true }
local SIDE_PARALYZE = { [6] = true, [36] = true }
local SIDE_FLINCH = { [31] = true, [37] = true }

local SIDE_TEXT = {
  poison = "was poisoned", burn = "was burned",
  freeze = "was frozen solid", paralysis = "is paralyzed",
}
local SIDE_TOKEN = { poison = "PSN", burn = "BRN", freeze = "FRZ", paralysis = "PAR" }

local function inflict(out, fighter, mon, status, wire)
  mon.status = status
  local text = mon.species .. " " .. SIDE_TEXT[status]
  out.messages[#out.messages + 1] = text
  local fields = fighterFields(fighter)
  fields.status = wire[status] or SIDE_TOKEN[status]
  fields.text = text
  out.events[#out.events + 1] = { kind = "status", fields = fields }
end

local function hasType(mon, typeIndex)
  if typeIndex == nil or type(mon.types) ~= "table" then return false end
  for i = 1, #mon.types do
    if mon.types[i] == typeIndex then return true end
  end
  return false
end

-- CheckMoveTypeMatchesTarget (effect_commands.asm:5909-5945, pokegold the
-- same): the move's type against both of the target's, "unless the move is
-- Normal (Tri Attack)" -- a NORMAL move never matches.  `normalType` is
-- NORMAL's chart index off the ruleset's typeIds; a fight that names no types
-- compares the indices alone, which every burn and freeze move on the carts
-- (none of them Normal) answers the same way.
local function moveTypeMatchesTarget(targetMon, moveType, normalType)
  if moveType == nil then return false end
  if normalType ~= nil and moveType == normalType then return false end
  return hasType(targetMon, moveType)
end

-- The secondary effect of a damaging hit, run where every *Hit script runs it:
-- after `checkfaint` (the caller never asks for a target the hit knocked out)
-- and `buildopponentrage`, whether the hit reached the HP or a substitute took
-- it -- `checkfaint` reads the monster's HP, not the doll's, so a hit into a
-- substitute goes on to the effect command, and each routine asks about the
-- substitute itself (CheckSubstituteOpp: the one standing NOW, so a hit that
-- broke it is past it).
--
-- ctx: effectId, hit, rng, targetMon, targetFighter, userFighter,
--      statusToWire, moveType (the move's chart index), poisonType /
--      normalType (POISON's and NORMAL's chart indices off the ruleset's
--      typeIds, nil when it names none), computerMover (the move is the
--      computer's: BattleCommand_StatDown's extra miss), chance (only when
--      `hit` is absent).
-- Returns { proc, messages, events }.  `hit` is BattleCommand_EffectChance's
-- verdict, drawn by the caller where the script's `effectchance` stands --
-- false when a substitute stood at it (CheckSubstituteOpp, before the byte);
-- absent, the byte is drawn here first.  `rng` is also the computer's
-- stat-down byte and the confusion side effect's turn count.  Each routine
-- below runs in pokecrystal's order (engine/battle/effect_commands.asm,
-- diffed against pokegold); HELD_PREVENT_* (no item on either cart carries
-- one, data/items/attributes.asm), SafeCheckSafeguard and FreezeTarget's
-- WEATHER_SUN return are skipped because nothing here can set them.
function M.applySide(ctx)
  ctx = ctx or {}
  local out = { proc = false, messages = {}, events = {} }
  local effectId = int(ctx.effectId, 0)
  local rng = ctx.rng
  local targetMon = ctx.targetMon
  local targetFighter = ctx.targetFighter
  local wire = ctx.statusToWire or {}
  if type(targetMon) ~= "table" then return out end
  local behindSub = int(targetMon.substitute, 0) > 0
  local moveType = int(ctx.moveType, nil)

  local hit = ctx.hit
  if hit == nil then hit = (not behindSub) and M.sideChanceProc(rng, ctx.chance) == true end

  -- BattleCommand_PoisonTarget (:3668-3700; Twineedle's `poisontarget` after
  -- its loop is the same command): a substitute, any status, a POISON-type
  -- target (CheckIfTargetIsPoisonType -- POISON alone, so a STEEL type a
  -- non-Poison move reaches, Twineedle's BUG, is poisoned), and only then
  -- wEffectFailed.
  if SIDE_POISON[effectId] then
    if behindSub or M.hasMajorStatus(targetMon) then return out end
    if hasType(targetMon, ctx.poisonType) then return out end
    if not hit then return out end
    out.proc = true
    inflict(out, targetFighter, targetMon, "poison", wire)
    return out
  end

  -- BattleCommand_BurnTarget (:3930-3968): a substitute returns; a target
  -- with any status jumps to Defrost (:3969-3993) BEFORE wEffectFailed is
  -- read, so a frozen target is thawed by every burn-family hit that reaches
  -- the command, its chance byte landed or not ("<TARGET> was defrosted!"),
  -- and any other status ends it there; then a target sharing the move's type
  -- (CheckMoveTypeMatchesTarget: don't burn a Fire type), then wEffectFailed.
  if SIDE_BURN[effectId] then
    if behindSub then return out end
    if M.hasMajorStatus(targetMon) then
      if targetMon.status == "freeze" then
        targetMon.status = nil
        targetMon.statusTurns = 0
        local text = targetMon.species .. " was defrosted"
        out.messages[#out.messages + 1] = text
        -- No token: a `status` event without one is a cure (events.lua).
        local fields = fighterFields(targetFighter)
        fields.text = text
        out.events[#out.events + 1] = { kind = "status", fields = fields }
        out.proc = true
      end
      return out
    end
    if moveTypeMatchesTarget(targetMon, moveType, ctx.normalType) then return out end
    if not hit then return out end
    out.proc = true
    inflict(out, targetFighter, targetMon, "burn", wire)
    return out
  end

  -- BattleCommand_FreezeTarget (:3994-4044): a substitute, any status, a
  -- target sharing the move's type (don't freeze an Ice type), then
  -- wEffectFailed.
  if SIDE_FREEZE[effectId] then
    if behindSub or M.hasMajorStatus(targetMon) then return out end
    if moveTypeMatchesTarget(targetMon, moveType, ctx.normalType) then return out end
    if not hit then return out end
    out.proc = true
    inflict(out, targetFighter, targetMon, "freeze", wire)
    return out
  end

  -- BattleCommand_ParalyzeTarget (:4045-4078): a substitute, any status, then
  -- wEffectFailed.  No type check at all -- an ELECTRIC move paralyses an
  -- Electric type and a NORMAL one a Normal type on both carts.
  if SIDE_PARALYZE[effectId] then
    if behindSub or M.hasMajorStatus(targetMon) then return out end
    if not hit then return out end
    out.proc = true
    inflict(out, targetFighter, targetMon, "paralysis", wire)
    return out
  end

  -- BattleCommand_FlinchTarget (:5357-5374): a substitute, then a sleeping or
  -- frozen target (`and 1 << FRZ | SLP_MASK / ret nz`), then
  -- CheckOpponentWentFirst, then wEffectFailed.  The went-first test is not
  -- asked here: a flag on a monster that has already moved is never read --
  -- `_openTurn` clears it before that monster's next CheckTurn -- so it
  -- changes nothing.  Nor is EndRechargeOpp: a recharge the target owes this
  -- turn was turned into its skip when the turn's choices were filled.
  if SIDE_FLINCH[effectId] then
    if behindSub then return out end
    if targetMon.status == "sleep" or targetMon.status == "freeze" then return out end
    if not hit then return out end
    out.proc = true
    targetMon.flinch = true
    return out
  end

  -- BattleCommand_StatDown, the routine the primary moves share
  -- (statDownGate: Mist, -6, the computer's byte), then `.DidntMiss`: a
  -- substitute, wEffectFailed and CheckHiddenOpponent, each `.Failed`.  A *Hit
  -- script has no `statdownfailtext` and `statdownmessage` speaks only when
  -- wFailedMessage is 0, so every one of those fails silently -- no "But it
  -- failed", no "won't go any lower".
  local stat = SIDE_STAT_DOWN[effectId]
  if stat then
    if M.statDownGate(rng, targetMon, stat, ctx.computerMover == true) then return out end
    if behindSub or not hit or targetMon.invulnerable then return out end
    out.proc = true
    applyStatChange(out, targetFighter, targetMon, stat, -1)
    return out
  end

  -- BattleCommand_ConfuseTarget (:5732-5749): wEffectFailed, then a
  -- substitute, then a target already confused, all before
  -- FinishConfusingTarget draws the 2-5 turn byte.
  if effectId == 76 then
    if not hit or behindSub then return out end
    if targetMon.confusion and targetMon.confusion > 0 then return out end
    out.proc = true
    confuse(out, targetFighter, targetMon, rng, false)
    return out
  end

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

function M.moveKey(moveOrId)
  local id = moveOrId
  if type(moveOrId) == "table" then id = moveOrId.id end
  if type(id) ~= "string" then return "" end
  return string.upper(id)
end

function M.isDigMove(moveOrId)
  return M.moveKey(moveOrId) == "DIG"
end

function M.isSwift(effectId)
  return int(effectId, 0) == 17
end

function M.vanishes(effectId, moveOrId)
  return M.isFly(effectId) or M.isDigMove(moveOrId)
end

function M.chargeMessage(mon, effectId, moveOrId)
  local key = M.moveKey(moveOrId)
  local species = (mon and mon.species) or "POKéMON"
  if key == "DIG" then return species .. " dug a hole" end
  if key == "SOLARBEAM" then return species .. " took in sunlight" end
  if key == "SKULL_BASH" then return species .. " lowered its head" end
  if key == "RAZOR_WIND" then return species .. " made a whirlwind" end
  if key == "FLY" or M.isFly(effectId) then return species .. " flew up high" end
  return species .. " is glowing"
end

-- CheckHit's .FlyDigMoves (Crystal effect_commands.asm:1713-1746).
-- Swift does *not* reach a vanished target in Gen 2.
M.FLY_DIG_EXCEPTIONS = {
  FLY = { GUST = true, WHIRLWIND = true, THUNDER = true, TWISTER = true },
  DIG = { EARTHQUAKE = true, FISSURE = true, MAGNITUDE = true },
}

function M.hitsInvulnerable(chargeMoveId, attackerMove)
  local charge = M.moveKey(chargeMoveId)
  local id = M.moveKey(attackerMove)
  local reaches = M.FLY_DIG_EXCEPTIONS[charge]
  return (reaches and reaches[id]) and true or false
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

-- ------------------------------------------------------------------
-- move priority
-- ------------------------------------------------------------------
--
-- GetMovePriority (pokecrystal engine/battle/core.asm:829-850): Vital Throw
-- answers 0 by its move id, every other move by its effect's row in
-- data/moves/effects_priorities.asm, and a move with no row is BASE_PRIORITY
-- (constants/battle_constants.asm: 1).  DetermineMoveOrder compares the two
-- numbers before anything else (CompareMovePriority), so a higher one moves
-- first whatever the Speed.
--
-- The cart keys the table by effect; this keys it by the move ids that carry
-- those effects (data/moves/moves.asm), because none of the five effects has
-- an id in this file's table -- a Gold sheet names EFFECT_PROTECT /
-- EFFECT_ENDURE / EFFECT_PRIORITY_HIT / EFFECT_COUNTER / EFFECT_MIRROR_COAT
-- as effect 0 (GEN2_EFFECT_ID above), and EFFECT_FORCE_SWITCH shares 28 with
-- Gen 1's Teleport row.  The selected move's id is what is read, as the cart
-- reads wCurPlayerMove: Metronome and Mirror Move move at base priority
-- whatever they call.
M.BASE_PRIORITY = 1
M.MOVE_PRIORITY = {
  PROTECT = 3, DETECT = 3,                            -- EFFECT_PROTECT, 3
  ENDURE = 3,                                         -- EFFECT_ENDURE, 3
  QUICK_ATTACK = 2, MACH_PUNCH = 2, EXTREMESPEED = 2, -- EFFECT_PRIORITY_HIT, 2
  WHIRLWIND = 0, ROAR = 0,                            -- EFFECT_FORCE_SWITCH, 0
  COUNTER = 0,                                        -- EFFECT_COUNTER, 0
  MIRROR_COAT = 0,                                    -- EFFECT_MIRROR_COAT, 0
  VITAL_THROW = 0,                                    -- `cp VITAL_THROW / ld a, 0`
}

-- The priority bracket of a move (a move record or its id).
function M.movePriority(moveOrId)
  local priority = M.MOVE_PRIORITY[M.moveKey(moveOrId)]
  if priority == nil then return M.BASE_PRIORITY end
  return priority
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

-- Potion / Ether / status cure / vitamin cannot apply to a KO (Revive is
-- faintedOnly). Shared by the item picker and `_normaliseChoice` so a
-- submitted choice cannot spend the bag or the turn.
function M.itemFailsOnFainted(effect)
  if type(effect) ~= "table" or effect.faintedOnly then return false end
  return not not (effect.heal or effect.healFull or effect.clearStatuses
      or effect.clearAllStatus or effect.ppRestore or effect.ppRestoreAll
      or effect.vitamin)
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
        name = m.name,
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

-- RUN finishes the fight in wild/coop_wild (flee) and 1v1/coop_pvp
-- (concession). coop_npc -- and any other non-wild non-pvp mode -- refuses
-- without finishing, so a gym cannot be forfeited by pressing RUN.
function M.runEndsBattle(mode)
  if M.teleportRunAllowed(mode) then return true end
  return mode == "1v1" or mode == "coop_pvp"
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
