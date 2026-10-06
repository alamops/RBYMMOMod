-- Gen1 move-effect ids and stat-stage multipliers.
--
-- Behavior taxonomy mirroring the public pret jump-table order; not ROM bytes.
-- Hand-authored 87-slot table (indices 0..86) shared with server/lib/battle/.
--
-- Phase 0: lookup + stage multipliers.  Phase 1: primary stat/status handlers.
-- Phase 2: post-damage side-chance effects + flinch.
-- Phase 3: multi-hit, fixed damage, drain, recoil.
-- Phase 4: multi-turn charge, recharge, trap, thrash, rage.
-- Phase 5: volatiles (substitute, screens, mist, focus energy) + meta
--          (conversion, transform).
-- Phase 6: meta / flow (bide, explode, jump kick, teleport, pay day,
--          mirror, mimic, metronome gap, no-op slots).
-- Stored battle stats: pokered's party / unmodified / battle stat sets, the
--          stage-change door (`changeStat`) and both Gen 1 stat glitches.
--
-- No love, no engine modules, no mod facade.

local need = ...

-- The two condition penalties are Status' formulas (and its vectors'); the
-- stat machinery below is where they are written into a battle stat.
local Status = need("BattleSim/Status")
-- The lines below name battlers the way the cart's <USER> / <TARGET> do:
-- through Events.named (contract K17), with the cart's breaks (K18); an
-- event's own `text` is the same line read plain (Events.plain).
local Events = need("BattleSim/events")

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

-- CalculateModifiedStat (engine/battle/core.asm :6376-6440): the unmodified
-- stat times its StatModifierRatios entry (data/battle/stat_modifiers.asm --
-- 15/10 and 150/100 truncate alike, so the table above is that one as
-- percents), held to 1..MAX_STAT_VALUE.  The two stat-change effects clamp
-- only one end each; see `changeStat`.
function M.applyStage(base, stage)
  local value = floor(max(0, int(base, 0)) * M.stageMult(stage) / 100)
  if value < 1 then return 1 end
  if value > M.MAX_STAT_VALUE then return M.MAX_STAT_VALUE end
  return value
end

-- Gen1 ApplyBadgeStatBoosts: ×9/8 when the fighter holds the matching badge,
-- capped at MAX_STAT_VALUE (999) -- pokered's .applyBoostToStat compares the
-- boosted word against it and writes 999 back when it went over; the engine's
-- port caps the same way (gen1recomp src/battle/Damage.lua:44-54, citing
-- engine/battle/core.asm:6454).
-- `wireStatKey` is atk/def/spd/spc; `badges` is a set of badge ids → true.
-- A fighter only holds a set where the cart would have applied it -- side a
-- of a fight against the computer; Turn.create drops it in 1v1 / coop_pvp
-- (link battles, which the cart never boosts) and on side b (Turn.BADGE_MODES)
-- -- so this never has to ask what kind of fight it is in.
M.MAX_STAT_VALUE = 999

local BADGE_FOR_STAT = {
  atk = "BOULDERBADGE",
  def = "THUNDERBADGE",
  spd = "SOULBADGE",
  spc = "VOLCANOBADGE",
}

function M.badgeBoost(statValue, wireStatKey, badges)
  local base = max(0, int(statValue, 0))
  if type(badges) ~= "table" then return base end
  local badge = BADGE_FOR_STAT[wireStatKey]
  if not badge or not badges[badge] then return base end
  return min(M.MAX_STAT_VALUE, floor(base * 9 / 8))
end

-- ------------------------------------------------------------------
-- Stored battle stats (pokered's own data flow)
-- ------------------------------------------------------------------
--
-- pokered does not derive a battle stat when it needs one.  It keeps three
-- sets per battler and *writes* the battle one at a handful of moments, and
-- every Gen 1 stat glitch falls out of which moment forgot what.  So the
-- referee keeps the same three, under the same rules, rather than a read-time
-- formula that would round and cap differently:
--
--   * `mon.partyStats` -- the party struct (wPartyMon1Attack...).  The sheet's
--     stats; only a vitamin moves them, and Transform never does.  A critical
--     hit reads these at both ends (GetDamageVarsForPlayerAttack, core.asm
--     :4059-4072, :4091-4104).
--   * `mon.stats` -- the unmodified stats (wPlayerMonUnmodifiedAttack...), the
--     base every stage change and Haze rebuild from.  Reloaded from the party
--     at every switch-in (LoadBattleMonFromParty :1654-1657); Transform copies
--     the target's over them (transform.asm .copyStats).
--   * `mon.cur` -- the battle stats (wBattleMonAttack...): what turn order,
--     damage and the confusion self-hit read, and nothing else adds to them at
--     read time.  Written by the switch-in seed (party -> burn/paralysis
--     penalty -> badges), every stage change, a badge re-run, a condition's
--     penalty, Haze and Transform -- every one of them below or in Turn.
--
-- `changeStat` is the one door every stage change goes through, so a new
-- stat-changing source hooks in there and inherits both glitches for free.

M.BATTLE_STATS = { "atk", "def", "spd", "spc" }
local IS_BATTLE_STAT = { atk = true, def = true, spd = true, spc = true }

local function statBlock(src)
  src = type(src) == "table" and src or {}
  return {
    atk = max(0, int(src.atk, 1)), def = max(0, int(src.def, 1)),
    spd = max(0, int(src.spd, 1)), spc = max(0, int(src.spc, 1)),
  }
end

local function resetStages(mon)
  mon.stages.atk = 0
  mon.stages.def = 0
  mon.stages.spd = 0
  mon.stages.spc = 0
  mon.stages.acc = 0
  mon.stages.eva = 0
end

-- Turn.create builds all three sets.  A monster table assembled anywhere else
-- (the Effects suite, a future caller) carries `stats` alone, and gets the
-- other two from it here rather than making every function below guard nil.
function M.ensureBattleStats(mon)
  if type(mon) ~= "table" then return end
  if type(mon.stats) ~= "table" then mon.stats = statBlock(nil) end
  if type(mon.partyStats) ~= "table" then mon.partyStats = statBlock(mon.stats) end
  if type(mon.cur) ~= "table" then mon.cur = statBlock(mon.stats) end
  if type(mon.stages) ~= "table" then
    mon.stages = { atk = 0, def = 0, spd = 0, spc = 0, acc = 0, eva = 0 }
  end
end

-- ApplyBadgeStatBoosts (core.asm :6454-6500): every badge-owned stat of the
-- battle mon gets +stat>>3 (the 9/8 above), held at 999 -- every one of them,
-- every time it runs, compounding on whatever is already there.  `badges` is
-- nil wherever the cart returns early (a link battle) or never looks (the
-- enemy's battler): Turn.create keeps a set only on side a of BADGE_MODES.
function M.applyBadgeBoosts(mon, badges)
  if type(mon) ~= "table" or type(badges) ~= "table" then return end
  M.ensureBattleStats(mon)
  for _, key in ipairs(M.BATTLE_STATS) do
    if badges[BADGE_FOR_STAT[key]] then
      mon.cur[key] = M.badgeBoost(mon.cur[key], key, badges)
    end
  end
end

-- QuarterSpeedDueToParalysis / HalveAttackDueToBurn (core.asm :6283-6366),
-- written into the battle stat, minimum 1, and only for the condition the
-- monster actually has.  It runs when the condition lands (effects.asm :236,
-- :243, :289, :294; paralyze.asm), when the monster is sent out
-- (LoadBattleMonFromParty :1658), and after every successful stat change on
-- whichever battler's turn it is NOT, whatever stat the change touched
-- (effects.asm :504-506, :694-698) -- the re-penalty glitch.  Nothing lifts it
-- but a rebuild of that stat: a stage change, Haze, a switch, the player's
-- own status-cure item (`reloadPartyStats`).
function M.applyStatusPenalty(mon)
  if type(mon) ~= "table" then return end
  M.ensureBattleStats(mon)
  if mon.status == "paralysis" then
    mon.cur.spd = Status.paralysisSpeed(mon.cur.spd)
  elseif mon.status == "burn" then
    mon.cur.atk = Status.burnAttack(mon.cur.atk)
  end
end

-- CalculateModifiedStats + ApplyBurnAndParalysisPenalties +
-- ApplyBadgeStatBoosts: the battle stats rebuilt from the unmodified ones
-- through the current stages, the way a level-up mid-fight rebuilds them
-- (engine/battle/experience.asm :226-238).  Turn.create seeds with it -- a
-- live sheet states no stages, so that is LoadBattleMonFromParty's own seed;
-- the suites' sheets state some -- and a vitamin on the fielded monster
-- re-runs it.
function M.recalcBattleStats(mon, badges)
  if type(mon) ~= "table" then return end
  M.ensureBattleStats(mon)
  for _, key in ipairs(M.BATTLE_STATS) do
    mon.cur[key] = M.applyStage(mon.stats[key], mon.stages[key])
  end
  M.applyStatusPenalty(mon)
  M.applyBadgeBoosts(mon, badges)
end

-- LoadBattleMonFromParty (core.asm :1626-1667) / LoadEnemyMonFromParty: the
-- party stats become the unmodified ones (undoing a Transform), then the
-- battle ones, then the penalty, then the badges, and every stage goes back to
-- neutral.  Turn runs it at every switch-in, and at a faint so nothing a
-- fallen monster carried survives to a revival.
function M.loadBattleStats(mon, badges)
  if type(mon) ~= "table" then return end
  M.ensureBattleStats(mon)
  mon.stats = statBlock(mon.partyStats)
  resetStages(mon)
  mon.cur = statBlock(mon.stats)
  M.applyStatusPenalty(mon)
  M.applyBadgeBoosts(mon, badges)
end

-- ItemUseMedicine's .cureStatusAilment (engine/items/item_effects.asm
-- :868-913): curing the fielded monster copies its party stats over its
-- battle stats -- which drops the penalty, every badge boost and every stage's
-- effect (the stages themselves stay) -- and on a Transformed one, its own
-- stats come back.  Turn calls it for the player's items only; the computer's
-- AICureStatus (engine/battle/trainer_ai.asm :625-636) touches no stat.
function M.reloadPartyStats(mon)
  if type(mon) ~= "table" then return end
  M.ensureBattleStats(mon)
  mon.cur = statBlock(mon.partyStats)
end

-- A copy of a battle-stat block, for the one caller that moves a whole set
-- between battlers (Transform).
function M.copyStats(src)
  return statBlock(src)
end

-- One stage change, the way StatModifierUpEffect / StatModifierDownEffect
-- (engine/battle/effects.asm :351-514 / :539-716) make it.  Every stage change
-- in this referee goes through here: a move's primary or side effect
-- (applyPrimary / applySide below), an X item and Rage (Turn).
--
-- ctx:
--   mon, fighter -- the battler whose stage moves, and its seat
--   stat, delta  -- "atk" .. "eva", +-1 / +-2
--   mover        -- the seat whose turn it is (hWhoseTurn): the move's or the
--                   item's user, or the raging battler for Rage, which
--                   HandleBuildingRage makes the user (core.asm :4913-4950)
--   nonMover     -- the battle mon "whose turn it is not", which the
--                   re-penalty lands on: the action's target for a move, the
--                   battler opposite for an item, the attacker for Rage.  nil
--                   when nobody is standing there.
--
-- Returns the outcome and the stage it left:
--   "rose" / "fell" -- the stage moved and the battle stat was rebuilt
--   "max" / "min"   -- already at +6 / -6: nothing moved (the cart's
--                      "Nothing happened!" / CantLowerAnymore)
--   "stuck"         -- the battle stat itself was already at 999 (a raise) or
--                      1 (a drop).  The stage is wound back ONE step whatever
--                      the delta (RestoreOriginalStatModifier `dec [hl]`,
--                      CantLowerAnymore_Pop `inc [hl]`), so a +2 move on a 999
--                      stat still nets +1 -- the cart's quirk, kept.
--
-- The rebuild is the changed stat alone: unmodified x the new stage's ratio,
-- held at 999 on a raise and at 1 on a drop, the one end each routine checks.
-- The other end is left open as the cart leaves it: a drop from a raised stage
-- can store more than 999 (a 458 Defense lowered from +4 to +3 is 1145), and a
-- raise out of -6 on a tiny stat can store 0; the damage step scales and
-- clamps what it is handed.  Burn, paralysis and badges are not in the
-- rebuild -- which is why a stage change on a burned Attack lifts the burn
-- until the re-penalty puts it back.
function M.changeStat(ctx)
  local mon, fighter = ctx.mon, ctx.fighter
  local stat, delta = ctx.stat, int(ctx.delta, 0)
  M.ensureBattleStats(mon)
  local before = M.clampStage(mon.stages[stat])
  if delta > 0 and before >= M.STAGE_MAX then return "max", before end
  if delta < 0 and before <= M.STAGE_MIN then return "min", before end
  local after = M.clampStage(before + delta)
  mon.stages[stat] = after

  if IS_BATTLE_STAT[stat] then
    local current = int(mon.cur[stat], 0)
    if delta > 0 and current == M.MAX_STAT_VALUE then
      mon.stages[stat] = after - 1
      return "stuck", mon.stages[stat]
    end
    if delta < 0 and current == 1 then
      mon.stages[stat] = after + 1
      return "stuck", mon.stages[stat]
    end
    local value = floor(max(0, int(mon.stats[stat], 0)) * M.stageMult(after) / 100)
    if delta > 0 then
      value = min(M.MAX_STAT_VALUE, value)
    else
      value = max(1, value)
    end
    mon.cur[stat] = value
  end

  -- The badge-stacking glitch.  ApplyBadgeStatBoosts runs again on the
  -- player's battle mon after the player's own raise (effects.asm :497-499)
  -- and after the enemy's drop (:687-689) -- accuracy and evasion included --
  -- over all four stats, so every badge stat compounds another 9/8.  "The
  -- player" is the seat holding a badge set (Turn.create keeps one only on
  -- side a of a fight against the computer), so a raise re-runs the mover's
  -- own set and a drop re-runs the set of a target sitting across from it.
  if delta > 0 then
    if ctx.mover == fighter then M.applyBadgeBoosts(mon, fighter and fighter.badges) end
  elseif ctx.mover and fighter and ctx.mover.side ~= fighter.side then
    M.applyBadgeBoosts(mon, fighter.badges)
  end

  -- The re-penalty glitch: both routines end on QuarterSpeedDueToParalysis +
  -- HalveAttackDueToBurn for the battler whose turn it is not, whichever stat
  -- moved ("these shouldn't be here", effects.asm :504-506; :694-698).
  if ctx.nonMover then M.applyStatusPenalty(ctx.nonMover) end

  return delta > 0 and "rose" or "fell", after
end

-- ------------------------------------------------------------------
-- Phase 1 primary handlers
-- ------------------------------------------------------------------

-- StatModTextStrings (data/battle/stat_mod_names.asm): the evasion stat is
-- "EVADE" in the cart's sentences.
local STAT_LABELS = {
  atk = "ATTACK", def = "DEFENSE", spd = "SPEED",
  spc = "SPECIAL", acc = "ACCURACY", eva = "EVADE",
}

-- effect id -> { stat, delta, selfTarget }
local STAT_EFFECTS = {
  [10] = { stat = "atk", delta = 1, selfTarget = true },
  [11] = { stat = "def", delta = 1, selfTarget = true },
  [12] = { stat = "spd", delta = 1, selfTarget = true },
  [13] = { stat = "spc", delta = 1, selfTarget = true },
  [14] = { stat = "acc", delta = 1, selfTarget = true },
  [15] = { stat = "eva", delta = 1, selfTarget = true },
  [18] = { stat = "atk", delta = -1, selfTarget = false },
  [19] = { stat = "def", delta = -1, selfTarget = false },
  [20] = { stat = "spd", delta = -1, selfTarget = false },
  [21] = { stat = "spc", delta = -1, selfTarget = false },
  [22] = { stat = "acc", delta = -1, selfTarget = false },
  [23] = { stat = "eva", delta = -1, selfTarget = false },
  [50] = { stat = "atk", delta = 2, selfTarget = true },
  [51] = { stat = "def", delta = 2, selfTarget = true },
  [52] = { stat = "spd", delta = 2, selfTarget = true },
  [53] = { stat = "spc", delta = 2, selfTarget = true },
  [54] = { stat = "acc", delta = 2, selfTarget = true },
  [55] = { stat = "eva", delta = 2, selfTarget = true },
  [58] = { stat = "atk", delta = -2, selfTarget = false },
  [59] = { stat = "def", delta = -2, selfTarget = false },
  [60] = { stat = "spd", delta = -2, selfTarget = false },
  [61] = { stat = "spc", delta = -2, selfTarget = false },
  [62] = { stat = "acc", delta = -2, selfTarget = false },
  [63] = { stat = "eva", delta = -2, selfTarget = false },
}

-- TransformEffect_'s `.copyPPLoop`: every copied move gets 5 PP.
M.TRANSFORM_PP = 5
-- DisableEffect's slot draw is a loop the cart never needs to bound; the
-- referee bounds it (applyPrimary) so a malformed sheet cannot hang a hub.
M.DISABLE_PICK_GUARD = 4096
-- The same bound on every other redraw loop the referee runs for a cart
-- routine that loops until a byte suits it (SleepEffect's counter,
-- SwitchAndTeleportEffect's level roll, MimicEffect's `.getRandomMove`): a
-- generator that never yields one is a frozen cart, and the referee answers
-- the loop's fallback instead (quirks reproduced, freezes never).
M.REDRAW_GUARD = 4096

-- The primary stat drops, StatModifierDownEffect's non-side branch.
function M.isPrimaryStatDown(effectId)
  local fx = STAT_EFFECTS[int(effectId, 0)]
  return fx ~= nil and fx.delta < 0
end

-- MoveHitTest's Mist check (core.asm :5262-5299): the mover's effect in
-- ATTACK_DOWN1..HAZE or ATTACK_DOWN2..REFLECT against a target PROTECTED_BY_
-- MIST misses, before the accuracy byte.  Of those, only the stat drops ever
-- call MoveHitTest (Conversion, Haze and the screens are ResidualEffects1 and
-- never do), so the drops are the whole of it.
function M.mistBlocks(effectId, targetMon)
  return M.isPrimaryStatDown(effectId) and type(targetMon) == "table"
    and targetMon.mist == true
end

-- How a power-0 move meets MoveHitTest, by its pokered routine.  The cart
-- never runs MoveHitTest for a power-0 move on the way in (CalculateDamage's
-- `jp z, PlayerCheckIfFlyOrChargeEffect`, core.asm :3145; ResidualEffects1
-- jumps past it, :3125), so each effect's routine decides:
--   "none"     -- no hit test at all: no INVULNERABLE miss, no accuracy byte.
--                 The self and field effects, Bide, Teleport (its own level
--                 roll), Transform (its own broken check), Splash, Mirror
--                 Move / Metronome (the called move tests), and an
--                 effect-less move (`.executeOtherEffects` finds nothing).
--   "conversion" -- ConversionEffect_'s own INVULNERABLE check, no byte.
--   "statdown" -- StatModifierDownEffect: the computer's extra miss byte, a
--                 Substitute, then MoveHitTest (Mist inside it).
--   "poison"   -- PoisonEffect: a Substitute, a status, a Poison type, then
--                 MoveHitTest.
--   "disable"  -- DisableEffect: MoveHitTest, "But it failed!" on a miss.
--   "sleep"    -- SleepEffect (effects.asm :26-68): a recharging target skips
--                 every check and the hit test; else already asleep, any
--                 status, then MoveHitTest -- no byte before the last.
--   "paralyze" -- ParalyzeEffect_ (move_effects/paralyze.asm): any status, an
--                 ELECTRIC move into a GROUND type, then MoveHitTest.
--   "confusion" -- ConfusionEffect (effects.asm :1120-1126): a Substitute,
--                 then MoveHitTest, then already confused.
--   "mimic"    -- MimicEffect (effects.asm :1203-1273): MoveHitTest, then
--                 the pick (the player's menu, or `BattleRandom & 3`).
--   "leechseed" -- LeechSeedEffect_ (move_effects/leech_seed.asm):
--                 MoveHitTest, then a GRASS type, then already seeded.
-- None of the last five asks CheckTargetSubstitute but Confusion, so a doll
-- stops none of the others (`blockedBySubstitute`).
local STATUS_PLAN = {
  [0] = "none", [1] = "none", [9] = "none", [83] = "none",
  [10] = "none", [11] = "none", [12] = "none", [13] = "none", [14] = "none", [15] = "none",
  [50] = "none", [51] = "none", [52] = "none", [53] = "none", [54] = "none", [55] = "none",
  [25] = "none", [26] = "none", [28] = "none", [46] = "none", [47] = "none",
  [56] = "none", [57] = "none", [64] = "none", [65] = "none", [79] = "none", [85] = "none",
  [24] = "conversion",
  [18] = "statdown", [19] = "statdown", [20] = "statdown", [21] = "statdown",
  [22] = "statdown", [23] = "statdown", [58] = "statdown", [59] = "statdown",
  [60] = "statdown", [61] = "statdown", [62] = "statdown", [63] = "statdown",
  [66] = "poison", [86] = "disable",
  [32] = "sleep", [49] = "confusion", [67] = "paralyze", [82] = "mimic",
  [84] = "leechseed",
}

-- An effect outside the table is a power-0 move whose routine is a damaging
-- one (a modded sheet): CalculateDamage returned before the hit test, so it
-- is "none" too.
function M.statusPlan(effectId)
  return STATUS_PLAN[int(effectId, 0)] or "none"
end

-- PoisonEffect's turn-aways (effects.asm :78-96), checked before its
-- MoveHitTest: a Substitute, any status at all, a Poison type (`cp POISON`
-- on both type bytes; `poisonType` is the ruleset's index, nil when it named
-- none).  The primary routine says "It didn't affect" for all three.
function M.poisonTurnsAway(targetMon, poisonType)
  if type(targetMon) ~= "table" then return true end
  if M.hasSubstitute(targetMon) or M.hasMajorStatus(targetMon) then return true end
  if poisonType ~= nil and type(targetMon.types) == "table" then
    for i = 1, #targetMon.types do
      if targetMon.types[i] == poisonType then return true end
    end
  end
  return false
end

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
    -- ConfusionEffectFailed (effects.asm :1158-1163): the primary's
    -- ConditionalPrintButItFailed prints (wMoveDidntMiss is clear on a
    -- power-0 move); the side effect's `cp CONFUSION_SIDE_EFFECT / ret z`
    -- says nothing.
    if failIfAlready then out.messages[#out.messages + 1] = "But, it failed!" end
    return
  end
  local turns = (rng and rng:byte() or 0) % 4 + 2
  mon.confusion = turns
  -- ConfusionSideEffectSuccess plays the move's animation for the primary
  -- (`cp CONFUSION_SIDE_EFFECT / call nz, PlayCurrentMoveAnimation2`).
  out.animates = true
  -- BecameConfusedText, "<TARGET>\nbecame confused!".
  local text = Events.named(fighter.side, mon.species) .. "\nbecame confused!"
  out.messages[#out.messages + 1] = text
  local fields = fighterFields(fighter)
  fields.confused = 1
  fields.text = Events.plain(text)
  out.events[#out.events + 1] = { kind = "status", fields = fields }
end

-- A move's stage change, narrated.  `changeStat` does the arithmetic and both
-- glitches; this adds the sentences.  `mover` is the move's user and
-- `nonMover` the battle mon of the seat the action was aimed at -- the
-- battler whose turn it is not, in the cart's one-opponent terms.  `side` is a
-- move's side effect, which the cart lets fail silently where a primary prints
-- "Nothing happened!" (CantLowerAnymore: `cp ATTACK_DOWN_SIDE_EFFECT; ret nc`).
-- Both of a drop's failures go through that label -- the stage already at -6
-- (`dec b; jp z, CantLowerAnymore`) and the stat already at 1 -- so a side
-- effect says nothing at either wall.
--
-- Mist stops a primary drop and never a side effect's.  The cart's only Mist
-- check is MoveHitTest's (core.asm `.enemyMistCheck` / `.playerMistCheck`),
-- which looks at effects ATTACK_DOWN1..HAZE and ATTACK_DOWN2..REFLECT alone;
-- the side-effect drops (ATTACK_DOWN_SIDE_EFFECT..SPECIAL_DOWN_SIDE_EFFECT)
-- are past that range, and StatModifierDownEffect's side branch never calls
-- MoveHitTest -- so AURORA BEAM lowers a Mist user's Attack.
--
-- The walls a primary hits say what the cart's routines say: a raise at +6
-- is StatModifierUpEffect's `jp c, PrintNothingHappenedText` (effects.asm
-- :368-370) and a drop at -6 is CantLowerAnymore (:705-710), both "Nothing
-- happened!" -- the same line the 999 / 1 walls print.  Mist is no longer
-- asked here: it is MoveHitTest's (core.asm :5262-5283), and Turn runs that
-- before the accuracy byte (`_statusHitTest`).  Returns true when the stage
-- moved -- the one outcome UpdateStatDone / UpdateLoweredStatDone animate.
local function applyStatChange(out, fighter, mon, stat, delta, mover, nonMover, side)
  local label = STAT_LABELS[stat] or stat
  local outcome, after = M.changeStat({
    mon = mon, fighter = fighter, stat = stat, delta = delta,
    mover = mover, nonMover = nonMover,
  })
  if outcome == "max" or outcome == "min" or outcome == "stuck" then
    if not side then out.messages[#out.messages + 1] = "Nothing happened!" end
    return false
  end
  -- MonsStatsRoseText / MonsStatsFellText (effects.asm :516-536, :718-742):
  -- "<USER>'s <STAT> rose!" and "<TARGET>'s <STAT> fell!", with "greatly"
  -- for the two-stage effects (an UP2 effect: `cp ATTACK_DOWN1_EFFECT / ret
  -- nc`; a DOWN2 one: BIDE_EFFECT up to ATTACK_DOWN_SIDE_EFFECT).  A side
  -- effect's one stage is plain "fell!".  The name is <USER>'s for a raise
  -- and <TARGET>'s for a drop -- `mon` either way, on `fighter`'s side
  -- (K17) -- and the box breaks after it ("'s" / `line`) and, for a
  -- "greatly", at GreatlyRoseText's / GreatlyFellText's <SCROLL> (K18).
  local text = Events.named(fighter.side, mon.species) .. "'s\n" .. label
    .. ((delta >= 2 or delta <= -2) and "\ngreatly " or " ") .. outcome .. "!"
  out.messages[#out.messages + 1] = text
  local fields = fighterFields(fighter)
  -- The stage it now sits at -- when that is not below neutral.  `amount` is
  -- unsigned on the wire (Wire.AMOUNT_MAX: the direction is the sentence's),
  -- so Wire.battleEvent strips a negative one in transit; leaving it out here
  -- keeps the stream the referee emits the stream a client receives.
  if after >= 0 then fields.amount = after end
  -- ...and `stage` says it signed, -6..6, every time (contract K10).
  fields.stage = after
  fields.text = Events.plain(text)
  out.events[#out.events + 1] = { kind = "stat", fields = fields }
  return true
end

-- HazeEffect_ (engine/battle/move_effects/haze.asm) on one battler: every
-- stage back to neutral (ResetStatMods), the unmodified stats copied over the
-- battle ones -- which lifts a burn or paralysis penalty and every badge boost
-- until something rebuilds them (ResetStats skips HP and nothing else) -- its
-- Disable gone, and CureVolatileStatuses: confusion, X Accuracy, Mist, Focus
-- Energy, Leech Seed, and BattleStatus3's Bad Poison, Reflect and Light
-- Screen (`and %11110000 | 1 << TRANSFORMED` keeps the Transform).  The Bad
-- Poison bit going leaves a TOXIC monster plain poisoned -- its PSN bit is in
-- the status byte, which Haze cures on the target alone (`applyPrimary`) --
-- and takes a lingering bit (`toxicLinger`) with it.  Returns whether the
-- battler was confused, for the snap-out chip.
local function hazeReset(mon)
  M.ensureBattleStats(mon)
  resetStages(mon)
  mon.cur = statBlock(mon.stats)
  mon.reflect = false
  mon.lightScreen = false
  mon.disable = nil
  mon.xAccuracy = false
  mon.mist = false
  mon.focusEnergy = false
  mon.leechSeed = nil
  if mon.status == "toxic" then mon.status = "poison" end
  mon.toxicLinger = nil
  local confused = int(mon.confusion, 0) > 0
  mon.confusion = 0
  return confused
end

-- Whether a Substitute stands in front of `mon`.  The doll's HP is
-- `substitute`; AttackSubstitute (core.asm :4849-4900) leaves a doll standing
-- at 0 when a hit takes exactly its HP (`sub [hl]` / `ret nc`), and that doll
-- is `subAtZero` -- still up, so it still blocks, still soaks the next hit
-- (which breaks it) and still makes a second SUBSTITUTE fail.
function M.hasSubstitute(mon)
  if type(mon) ~= "table" then return false end
  return int(mon.substitute, 0) > 0 or mon.subAtZero == true
end

-- The primaries a doll stops are the routines that ask CheckTargetSubstitute
-- (effects.asm :1436-1446): StatModifierDownEffect (:551), PoisonEffect
-- (:86) and ConfusionEffect (:1121) -- and no other.  SleepEffect,
-- ParalyzeEffect_, LeechSeedEffect_, TransformEffect_ (whose only
-- HAS_SUBSTITUTE_UP test is the user's own, for its animation), MimicEffect
-- and DisableEffect never ask, and MoveHitTest's own Substitute check is the
-- broken drain one (core.asm :5251-5256), so SLEEP POWDER, THUNDER WAVE,
-- LEECH SEED, TRANSFORM, MIMIC and DISABLE all reach the monster behind a
-- doll.  The self and field effects never had a target to stop.  Turn runs
-- each of the three where its routine does (the "statdown", "poison" and
-- "confusion" plans), before the hit test; this is the backstop for a caller
-- that skipped them.
local function blockedBySubstitute(effectId)
  local statFx = STAT_EFFECTS[effectId]
  if statFx then return not statFx.selfTarget end
  return effectId == 49 or effectId == 66
end

-- ------------------------------------------------------------------
-- CalcStat (home/move_mon.asm :54-229)
-- ------------------------------------------------------------------
--
-- One stat from its base, its DV, the level and (when `statExp` is not nil)
-- the stat exp: floor(((base + DV) * 2 + floor(b / 4)) * level / 100) + 5,
-- and + level + 10 for HP, held at 999.  `b` is `.statExpLoop`'s: the least
-- b >= 1 with b * b >= stat exp, at most 255 -- so a stat exp of 0 still
-- counts 1, which floors to 0.  `statExp` nil is CalcStat called with `b = 0`
-- ("consider stat exp?" no): the term is 0.  GetEnemyMonStat (core.asm
-- :4258-4297) is the second; a level-up's CalcStats (experience.asm) the
-- first.
function M.statExpBonus(statExp)
  local se = max(0, int(statExp, 0))
  local b = 1
  while b < 255 and b * b < se do b = b + 1 end
  return b
end

function M.calcStat(base, dv, level, statExp, isHp)
  local term = 0
  if statExp ~= nil then term = floor(M.statExpBonus(statExp) / 4) end
  local L = max(0, int(level, 1))
  local value = floor(((max(0, int(base, 0)) + max(0, int(dv, 0))) * 2 + term) * L / 100)
  if isHp then value = value + L + 10 else value = value + 5 end
  if value > M.MAX_STAT_VALUE then value = M.MAX_STAT_VALUE end
  return value
end

-- The HP DV CalcStat builds out of the other four's low bits (`.getHPIV`).
function M.hpDv(dvs)
  if type(dvs) ~= "table" then return 0 end
  return (int(dvs.atk, 0) % 2) * 8 + (int(dvs.def, 0) % 2) * 4
    + (int(dvs.spd, 0) % 2) * 2 + (int(dvs.spc, 0) % 2)
end

-- ------------------------------------------------------------------
-- A move's maximum PP, and the PP items that read it
-- ------------------------------------------------------------------

-- GetMaxPP (engine/items/item_effects.asm): the move's base PP plus, for each
-- PP Up the PP byte's top two bits count *now*, AddBonusPP's fifth of the
-- base capped at 7.  So a DecrementPP that wraps a slot at 0 (Turn `stepPp`:
-- 63 PP and one PP Up fewer) moves the maximum with the bits, and the cart's
-- ETHER reads that.  The client's sheet states the same number
-- (MediatedBattle maxPpOf), which is what `basePpOf` reads the base back out
-- of: the referee holds no move table.
M.PP_UP_BONUS_MAX = 7
M.PP_BASE_MAX = 63          -- PP_MASK: a base PP is the low six bits

function M.getMaxPp(base, ups)
  return base + ups * min(M.PP_UP_BONUS_MAX, floor(base / 5))
end

-- The base PP behind a stated maximum: the one `base` (0..PP_BASE_MAX) whose
-- GetMaxPP over `ups` is `maxPp` -- strictly increasing in the base, so there
-- is at most one -- or nil for a number no base gives (a sheet stating a
-- maximum of its own), whose maximum then never moves.
function M.basePpOf(maxPp, ups)
  for base = min(maxPp, M.PP_BASE_MAX), 0, -1 do
    local value = M.getMaxPp(base, ups)
    if value == maxPp then return base end
    if value < maxPp then return nil end
  end
  return nil
end

-- ItemUsePPRestore's `.restorePP` (item_effects.asm), on one move row, for an
-- ETHER's 10 (`amount` a number) or a MAX ETHER (`amount` true; the ELIXERs
-- run it on every slot).  `b` is GetMaxPP -- the row's `maxPp`, which the
-- sheet states and a wrap re-reads.  ETHER: the PP's low six bits equal to
-- `b` is no effect (`ret z`); otherwise +10, kept only below `b`.  MAX ETHER
-- compares the WHOLE byte with `b` -- the cart's own bug ("doesn't mask out
-- the upper two bits"), so a full move with PP Ups is restored to what it
-- has.  Either writes the PP Ups beside `b`: a slot past its wrap -- 63 over
-- a lower maximum -- is brought DOWN to it, and that is a restore.  True when
-- the cart's flag says restored: `add b` left a byte other than 0.
function M.restorePp(move, amount)
  local pp, ups = max(0, int(move.pp, 0)), int(move.ppUps, 0) % 4
  local b = max(0, int(move.maxPp, pp))
  if amount == true then
    if ups * 64 + pp == b then return false end
  else
    if pp == b then return false end
    local new = pp + int(amount, 0)
    if new < b then b = new end
  end
  move.pp = b
  return (ups * 64 + b) % 256 ~= 0
end

-- ------------------------------------------------------------------
-- Transform (engine/battle/move_effects/transform.asm), and undoing it
-- ------------------------------------------------------------------

local function copyList(list)
  local out = {}
  if type(list) == "table" then for i = 1, #list do out[i] = list[i] end end
  return out
end

local function copyMoveRow(m)
  return {
    id = m.id or "move", name = m.name,
    pp = max(0, int(m.pp, 0)), maxPp = m.maxPp,
    power = max(0, int(m.power, 0)), accuracy = max(0, int(m.accuracy, 255)),
    type = max(0, int(m.type, 0)), effect = max(0, int(m.effect, 0)),
    chance = max(0, int(m.chance, 0)), highCrit = m.highCrit == true,
    ppUps = m.ppUps, basePp = m.basePp,
  }
end

local function copyKeyed(t)
  if type(t) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

-- What a switch-out gives back.  TransformEffect_ rewrites the battle
-- struct only (wBattleMon / wEnemyMon); the party struct keeps the
-- monster's own species, types, moves and PP -- DecrementPP returns before
-- the party copy while TRANSFORMED is set -- so LoadBattleMonFromParty
-- (core.asm :1626-1667) brings all of it back.  The referee keeps the
-- pre-Transform copy on the monster (`preTransform`, the first Transform's
-- only: a second one copies over a battle struct the party never saw) and
-- restores it here, at a switch-in and at a faint.  The stats are
-- `loadBattleStats`'.
function M.untransform(mon)
  if type(mon) ~= "table" then return end
  local saved = mon.preTransform
  mon.preTransform = nil
  mon.transformed = false
  if not saved then return end
  mon.types = saved.types
  mon.moves = saved.moves
  mon.baseSpd = saved.baseSpd
  mon.base = saved.base
  mon.dvs = saved.dvs
end

-- Everything a switch-out or a faint gives back of the battle struct's move
-- list (LoadBattleMonFromParty reloads it from the party): the Transform's
-- (`untransform`), then every slot a MIMIC wrote while the monster was itself
-- -- the party's own move again, at the slot's PP, which DecrementPP kept in
-- step with the party's.  A MIMIC used while TRANSFORMed wrote over a copy the
-- party never had, and `untransform` already threw it away.  Walked in slot
-- order so both runtimes rebuild the same list.
function M.restoreMoves(mon)
  if type(mon) ~= "table" then return end
  M.untransform(mon)
  local saved = mon.preMimic
  mon.preMimic = nil
  if type(saved) ~= "table" or type(mon.moves) ~= "table" then return end
  for i = 1, #mon.moves do
    local row = saved[i]
    if row then
      local back = copyMoveRow(row)
      back.pp = max(0, int(mon.moves[i].pp, back.pp))
      -- ...and its PP Ups: one byte, which a wrapping DecrementPP borrows
      -- from in both copies alike (Turn `_decrementPp`) -- and GetMaxPP over
      -- MIMIC's base re-reads them (`M.getMaxPp`).
      if mon.moves[i].ppUps ~= nil then back.ppUps = mon.moves[i].ppUps end
      if back.basePp then back.maxPp = M.getMaxPp(back.basePp, int(back.ppUps, 0)) end
      mon.moves[i] = back
    end
  end
end

-- `.setSleepCounter` (effects.asm :55-59): `BattleRandom / and SLP_MASK`,
-- redrawn while it comes out 0 -- 1..7 turns.  No generator draws nothing and
-- answers 1 (a caller that cannot roll still gets an honest sleep).
function M.sleepTurns(rng)
  if not rng then return 1 end
  for _ = 1, M.REDRAW_GUARD do
    local turns = rng:byte() % 8
    if turns ~= 0 then return turns end
  end
  return 1
end

-- SwitchAndTeleportEffect's level roll (effects.asm :810-846, and the
-- enemy's mirror :856-880), for a wild fight: a user at or above the
-- target's level always gets away, with no draw.  Otherwise `add b / inc c`
-- -- c is the two levels plus one, an 8-bit sum -- and `BattleRandom` is
-- redrawn until it is below c, then compared with the target's level / 4
-- (`srl b / srl b`): at or above it, the escape works.  A c that wrapped to 0
-- has no byte below it and freezes the cart; the referee draws nothing there
-- and the escape fails (quirks reproduced, freezes never).
function M.teleportEscapes(userLevel, targetLevel, rng)
  local a = max(0, int(userLevel, 1)) % 256
  local b = max(0, int(targetLevel, 1)) % 256
  if a >= b then return true end
  local c = (a + b + 1) % 256
  if c == 0 or not rng then return false end
  for _ = 1, M.REDRAW_GUARD do
    local r = rng:byte()
    if r < c then return r >= floor(b / 4) end
  end
  return false
end

-- ctx: effectId, rng, userMon, targetMon, userFighter, targetFighter,
--      moveIndex (1-based), statusToWire, plus
--   moveId       the move's id (PoisonEffect's `cp TOXIC`)
--   field        every standing battler, { fighter, mon } in field order
--                (Haze's reach)
--   playerMover  the user is "the player" (Transform's broken check)
--   unlimitedPp  the target is the computer's, whose PP DisableEffect never
--                reads outside a link battle
-- Returns { nothing, messages, events, heals, cannotMove, animates } where
-- heals = { amount } for user, `cannotMove` is Haze's CANNOT_MOVE on the
-- target and `animates` says the routine played the move's animation
-- (PlayCurrentMoveAnimation / PlayCurrentMoveAnimation2): every routine here
-- plays it where it succeeds and nowhere it fails -- HAZE and SPLASH always
-- -- which is what Turn reads to keep or take back the power-0 move's `anim`
-- (contract K22's audit).
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

  if targetMon and M.hasSubstitute(targetMon) and blockedBySubstitute(effectId) then
    out.nothing = true
    return out
  end

  -- SplashEffect (effects.asm :1282-1284): its animation, then
  -- PrintNoEffectText -- "No effect!".
  if effectId == 85 then -- SPLASH_EFFECT
    out.animates = true
    out.messages[#out.messages + 1] = "No effect!"
    return out
  end

  if effectId == 56 then -- HEAL_EFFECT
    -- HealEffect_ (move_effects/heal.asm).  Full HP fails it, through a
    -- compare that is the cart's own bug: `cp [hl]` on the high bytes only
    -- sets the carry and `sbc [hl]` on the low ones decides, so a monster
    -- 255 or 511 HP short of its maximum fails too -- "But, it failed!".
    -- REST then writes 2 over the whole status byte -- asleep for two turns,
    -- any poison, burn, freeze or paralysis gone (their stored penalties
    -- stay: nothing recomputes the stats) and a TOXIC's BADLY_POISONED bit,
    -- which lives in BattleStatus3, left lingering -- says "started
    -- sleeping!" or, when it had a status, "fell asleep and became
    -- healthy!", and heals to the full; RECOVER and SOFTBOILED heal half the
    -- maximum.  RegainedHealthText follows the HP (`afterHeals`).
    local hp, maxHp = max(0, int(userMon.hp, 0)), max(1, int(userMon.maxHp, 1))
    local carry = (floor(hp / 256) % 256 < floor(maxHp / 256) % 256) and 1 or 0
    if ((hp % 256) - (maxHp % 256) - carry) % 256 == 0 then
      out.messages[#out.messages + 1] = "But, it failed!"
      return out
    end
    local amount = floor(maxHp / 2)
    if M.moveKey(ctx.moveId) == "REST" then
      local had = M.hasMajorStatus(userMon)
      if userMon.status == "toxic" then userMon.toxicLinger = true end
      userMon.status = "sleep"
      userMon.statusTurns = 2
      -- FellAsleepBecameHealthyText / StartedSleepingEffect, <USER>'s.
      local user = Events.named(userFighter.side, userMon.species)
      local text = had and (user .. "\nfell asleep and\nbecame healthy!")
        or (user .. "\nstarted sleeping!")
      out.messages[#out.messages + 1] = text
      local fields = fighterFields(userFighter)
      fields.status = wire.sleep or "SLP"
      fields.text = Events.plain(text)
      out.events[#out.events + 1] = { kind = "status", fields = fields }
      amount = maxHp
    end
    out.heals[#out.heals + 1] = { amount = amount }
    out.afterHeals = { Events.named(userFighter.side, userMon.species) .. "\nregained health!" }
    -- `.playAnim`, the restore's (heal.asm): never on the failed compare.
    out.animates = true
    return out
  end

  if effectId == 25 then -- HAZE_EFFECT
    -- Every battler on the field gets hazeReset -- the cart's two, every
    -- standing one of a 2v2 (`ctx.field`, field order; the user and the
    -- target when a caller names none) -- and only the TARGET's status byte
    -- is cured (`.cureStatuses`), whatever it held.  A target that was
    -- asleep or frozen loses the move it has not used yet: `ld a, $ff /
    -- ld [de], a` writes CANNOT_MOVE over its selected move (`cannotMove`,
    -- Turn's to honour).
    local field = ctx.field
    if type(field) ~= "table" or #field == 0 then
      field = { { fighter = userFighter, mon = userMon },
                { fighter = targetFighter, mon = targetMon } }
    end
    local snapped = {}
    for _, seat in ipairs(field) do
      if hazeReset(seat.mon) then snapped[#snapped + 1] = seat end
    end
    local cured = targetMon.status
    if cured then
      targetMon.status = nil
      targetMon.statusTurns = 0
      if cured == "sleep" or cured == "freeze" then out.cannotMove = true end
      local fields = fighterFields(targetFighter)
      fields.text = targetMon.species .. " recovered"
      out.events[#out.events + 1] = { kind = "status", fields = fields }
    end
    for _, seat in ipairs(snapped) do
      local fields = fighterFields(seat.fighter)
      fields.confused = 0
      fields.text = seat.mon.species .. " snapped out of confusion"
      out.events[#out.events + 1] = { kind = "status", fields = fields }
    end
    out.messages[#out.messages + 1] = "All STATUS changes\nare eliminated!"
    out.animates = true
    return out
  end

  local statFx = STAT_EFFECTS[effectId]
  if statFx then
    local mon = statFx.selfTarget and userMon or targetMon
    local fighter = statFx.selfTarget and userFighter or targetFighter
    -- UpdateStatDone / UpdateLoweredStatDone play it on a stage that moved;
    -- a wall is "Nothing happened!" and no animation.
    out.animates = applyStatChange(out, fighter, mon, statFx.stat, statFx.delta,
      userFighter, targetMon, false)
    return out
  end

  if effectId == 32 then -- SLEEP_EFFECT
    -- SleepEffect (effects.asm :26-68), past the checks Turn ran first (the
    -- "sleep" plan).  `ctx.overwrite` is its recharging target, which skips
    -- them all: `.setSleepCounter` writes the counter over the whole status
    -- byte, so a poison, a burn or a paralysis is simply gone (their stored
    -- penalties stay -- nothing recomputes them) and a TOXIC's BADLY_POISONED
    -- bit, which lives in BattleStatus3, outlives it (`toxicLinger`), as it
    -- does a disobedience nap.
    if M.hasMajorStatus(targetMon) and not ctx.overwrite then
      out.nothing = true
      return out
    end
    if targetMon.status == "toxic" then targetMon.toxicLinger = true end
    -- `.setSleepCounter`: `BattleRandom / and SLP_MASK`, redrawn while it is
    -- 0 -- 1..7, uniform, one draw or more.
    local turns = M.sleepTurns(rng)
    targetMon.status = "sleep"
    targetMon.statusTurns = turns
    out.animates = true
    local token = wire.sleep or "SLP"
    local text = Events.named(targetFighter.side, targetMon.species) .. "\nfell asleep!"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = token
    fields.text = Events.plain(text)
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  if effectId == 66 then -- POISON_EFFECT
    -- PoisonEffect's turn-aways (a doll, any status, a Poison type) ran in
    -- Turn before the hit test (`M.poisonTurnsAway`); this is what is left
    -- for a target that has none.  `.inflictPoison`: TOXIC -- the move, by
    -- its id (`cp TOXIC` on wPlayerMoveNum) -- sets BADLY_POISONED and zeroes
    -- the counter (the referee's counter is the cart's plus one, so 1), and
    -- says "<TARGET>'s badly poisoned!"; anything else is plain PSN.
    if M.hasMajorStatus(targetMon) then
      out.nothing = true
      return out
    end
    local toxic = M.moveKey(ctx.moveId) == "TOXIC"
    out.animates = true
    targetMon.status = toxic and "toxic" or "poison"
    targetMon.toxicLinger = nil
    if toxic then targetMon.toxicCounter = 1 end
    local token = toxic and (wire.toxic or "TOX") or (wire.poison or "PSN")
    local text = Events.named(targetFighter.side, targetMon.species)
      .. (toxic and "'s\nbadly poisoned!" or "\nwas poisoned!")
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = token
    fields.text = Events.plain(text)
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  if effectId == 67 then -- PARALYZE_EFFECT
    if M.hasMajorStatus(targetMon) then
      out.nothing = true
      return out
    end
    targetMon.status = "paralysis"
    out.animates = true
    -- ParalyzeEffect_ quarters the battle Speed the moment it lands
    -- (paralyze.asm `callfar QuarterSpeedDueToParalysis`).
    M.applyStatusPenalty(targetMon)
    local token = wire.paralysis or "PAR"
    -- PrintMayNotAttackText (paralyze.asm :39).
    local text = Events.named(targetFighter.side, targetMon.species)
      .. "'s\nparalyzed! It may\nnot attack!"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = token
    fields.text = Events.plain(text)
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
    out.animates = true
    local text = Events.named(targetFighter.side, targetMon.species) .. "\nwas seeded!"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.text = Events.plain(text)
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  if effectId == 86 then -- DISABLE_EFFECT
    -- DisableEffect (effects.asm :1286-1367), after its MoveHitTest (Turn):
    -- a target with a move already disabled fails; otherwise `BattleRandom
    -- & 3` picks a slot, redrawn until it holds a move.  When the target is
    -- the player's monster (the enemy's turn, or a link battle -- both sides
    -- of one here, the owner's rule), the slot must also have PP: every PP
    -- at 0 (masked) is "But it failed!" -- after the draw that found a
    -- move -- and a slot whose raw PP byte is 0 is redrawn.  The raw byte
    -- holds the PP Ups in its top two bits, so a 0-PP move with PP Ups
    -- (K8 `ppUps`) can be the one disabled.  The computer's moves have
    -- unlimited PP outside a link battle (`ctx.unlimitedPp`) and are taken
    -- as found.  Then `BattleRandom & 7` + 1 turns: 1..8.
    if targetMon.disable and int(targetMon.disable.turns, 0) > 0 then
      out.messages[#out.messages + 1] = "But, it failed!"
      return out
    end
    local moves = targetMon.moves or {}
    if #moves == 0 or not rng then
      out.messages[#out.messages + 1] = "But, it failed!"
      return out
    end
    local slot, tries = nil, 0
    while not slot do
      tries = tries + 1
      -- A freeze guard the cart does not need (a target always holds a move
      -- with PP by the time this loops); `byte % 4` reaches every slot long
      -- before it.
      if tries > M.DISABLE_PICK_GUARD then
        for i = 1, #moves do
          if ctx.unlimitedPp or int(moves[i].pp, 0) > 0
             or int(moves[i].ppUps, 0) > 0 then
            slot = i
            break
          end
        end
        break
      end
      local pick = rng:byte() % 4 + 1
      local m = moves[pick]
      if m then
        if ctx.unlimitedPp then
          slot = pick
        else
          local anyPp = false
          for i = 1, #moves do
            if int(moves[i].pp, 0) > 0 then anyPp = true end
          end
          if not anyPp then
            out.messages[#out.messages + 1] = "But, it failed!"
            return out
          end
          if int(m.pp, 0) > 0 or int(m.ppUps, 0) > 0 then slot = pick end
        end
      end
    end
    if not slot then
      out.messages[#out.messages + 1] = "But, it failed!"
      return out
    end
    local turns = rng:byte() % 8 + 1
    -- The slot (the menu's wPlayerDisabledMove nibble) and the move's id
    -- (wPlayerDisabledMoveNumber, TriedToUseDisabledMoveCheck's).
    targetMon.disable = { moveIndex = slot, turns = turns, moveId = moves[slot].id }
    out.animates = true
    -- MoveWasDisabledText, "<TARGET>'s\n<MOVE> was\ndisabled!".
    out.messages[#out.messages + 1] = Events.named(targetFighter.side, targetMon.species)
      .. "'s\n" .. moveLabel(moves[slot]) .. " was\ndisabled!"
    return out
  end

  if effectId == 79 then -- SUBSTITUTE_EFFECT
    -- SubstituteEffect_ (move_effects/substitute.asm): HasSubstituteText
    -- for a doll already up, TooWeakSubstituteText for HP the quarter would
    -- not leave standing.  (The cart's own bug lets a monster at exactly a
    -- quarter make one and sit at 0 HP; the referee does not field a 0-HP
    -- monster, and keeps the `<=`.)
    local cost = floor(max(1, int(userMon.maxHp, 1)) / 4)
    if M.hasSubstitute(userMon) then
      out.messages[#out.messages + 1] =
        Events.named(userFighter.side, userMon.species) .. "\nhas a SUBSTITUTE!"
      return out
    end
    if userMon.hp <= cost then
      out.messages[#out.messages + 1] = "Too weak to make\na SUBSTITUTE!"
      return out
    end
    userMon.hp = userMon.hp - cost
    userMon.substitute = cost
    userMon.subAtZero = nil
    out.animates = true
    out.directDamage = { { amount = cost } }
    out.messages[#out.messages + 1] = "It created a\nSUBSTITUTE!"
    return out
  end

  -- Reflect and Light Screen are per battler and do not stack: a second cast
  -- while the bit is up is "But it failed!" (ReflectLightScreenEffect_,
  -- engine/battle/move_effects/reflect_light_screen.asm `.moveFailed`).
  if effectId == 64 then -- LIGHT_SCREEN_EFFECT
    if userMon.lightScreen then
      out.messages[#out.messages + 1] = "But, it failed!"
      return out
    end
    userMon.lightScreen = true
    out.animates = true
    out.messages[#out.messages + 1] = Events.named(userFighter.side, userMon.species)
      .. "'s\nprotected against\nspecial attacks!"
    return out
  end

  if effectId == 65 then -- REFLECT_EFFECT
    if userMon.reflect then
      out.messages[#out.messages + 1] = "But, it failed!"
      return out
    end
    userMon.reflect = true
    out.animates = true
    out.messages[#out.messages + 1] =
      Events.named(userFighter.side, userMon.species) .. "\ngained armor!"
    return out
  end

  -- MistEffect_ / FocusEnergyEffect_ (move_effects/mist.asm,
  -- focus_energy.asm): a bit already set is `.mistAlreadyInUse` /
  -- `.alreadyUsing`, PrintButItFailedText_ -- "But it failed!".
  if effectId == 46 then -- MIST_EFFECT
    if userMon.mist then
      out.messages[#out.messages + 1] = "But, it failed!"
      return out
    end
    userMon.mist = true
    out.animates = true
    out.messages[#out.messages + 1] =
      Events.named(userFighter.side, userMon.species) .. "'s\nshrouded in mist!"
    return out
  end

  if effectId == 47 then -- FOCUS_ENERGY_EFFECT
    if userMon.focusEnergy then
      out.messages[#out.messages + 1] = "But, it failed!"
      return out
    end
    userMon.focusEnergy = true
    out.animates = true
    out.messages[#out.messages + 1] =
      Events.named(userFighter.side, userMon.species) .. "'s\ngetting pumped!"
    return out
  end

  if effectId == 24 then -- CONVERSION_EFFECT
    -- ConversionEffect_ (move_effects/conversion.asm) copies BOTH of the
    -- target's type bytes over the user's (`ld a, [hli] / ld [de], a`
    -- twice), then ConvertedTypeText.
    local types = {}
    for i = 1, #(targetMon.types or {}) do types[i] = targetMon.types[i] end
    if #types == 0 then types[1] = 0 end
    userMon.types = types
    out.animates = true
    out.messages[#out.messages + 1] =
      "Converted type to\n" .. Events.named(targetFighter.side, targetMon.species) .. "'s!"
    return out
  end

  if effectId == 82 then -- MIMIC_EFFECT
    -- MimicEffect (effects.asm :1203-1273), past its MoveHitTest and its
    -- pick, which Turn makes (`ctx.mimicSlot`: the player's menu, or
    -- `BattleRandom & 3`).  `.playerTurn`'s `ld [hl], a` writes the picked
    -- move's id over the user's slot at wPlayerMoveListIndex -- the chosen
    -- slot (`ctx.moveIndex`) -- and nothing else: the slot keeps the PP and
    -- the PP Ups MIMIC had, this turn's spend included.  It is the battle
    -- struct's alone; the party keeps MIMIC, and a switch-out or a faint
    -- brings it back (`M.restoreMoves`) with the PP the two shared --
    -- DecrementPP writes both while the monster is not TRANSFORMed.
    local moveIndex = int(ctx.moveIndex, 0)
    local source = type(targetMon.moves) == "table"
      and targetMon.moves[int(ctx.mimicSlot, 0)] or nil
    local slotMove = userMon.moves[moveIndex]
    if not (source and slotMove) then
      out.messages[#out.messages + 1] = "But, it failed!"
      return out
    end
    if not userMon.transformed then
      userMon.preMimic = userMon.preMimic or {}
      if not userMon.preMimic[moveIndex] then
        userMon.preMimic[moveIndex] = copyMoveRow(slotMove)
      end
    end
    userMon.moves[moveIndex] = {
      id = source.id or "move",
      -- The copy is narrated under the same name the original was, so a
      -- mimicked move does not revert to its slug on the learner's screen.
      name = source.name,
      pp = max(0, int(slotMove.pp, 0)),
      maxPp = slotMove.maxPp,
      ppUps = slotMove.ppUps,
      -- The PP byte is still MIMIC's, and so is the GetMaxPP an ETHER reads
      -- for the slot (the party's MIMIC, ItemUsePPRestore): its base rides on.
      basePp = slotMove.basePp,
      power = max(0, int(source.power, 0)),
      accuracy = max(0, int(source.accuracy, 255)),
      type = max(0, int(source.type, 0)),
      effect = max(0, int(source.effect, 0)),
      chance = max(0, int(source.chance, 0)),
      highCrit = source.highCrit == true,
    }
    out.animates = true
    -- MimicLearnedMoveText, "<USER>\nlearned\n<MOVE>!".
    out.messages[#out.messages + 1] = Events.named(userFighter.side, userMon.species)
      .. "\nlearned\n" .. moveLabel(source) .. "!"
    out.movesChanged = true
    return out
  end

  if effectId == 57 then -- TRANSFORM_EFFECT
    -- TransformEffect_ (transform.asm) copies the target's battle stats AND
    -- its unmodified ones, and its stat mods below; the user's party stats are
    -- untouched, which is what a later critical hit reads.  Its INVULNERABLE
    -- check is the cart's bug: on the player's turn it tests the USER's own
    -- BattleStatus1 (`ld a, [wPlayerBattleStatus1]`), so only a player's
    -- monster still flagged INVULNERABLE (the full-paralysis FLY glitch)
    -- fails; on the enemy's turn `a` is hWhoseTurn (1) and bit 6 is clear,
    -- so nothing fails.  `ctx.playerMover` is the owner's rule for "the
    -- player" (Turn: side a against the computer, both sides of a link).
    if ctx.playerMover and userMon.invulnerable then
      out.messages[#out.messages + 1] = "But, it failed!"
      return out
    end
    M.ensureBattleStats(userMon)
    M.ensureBattleStats(targetMon)
    -- The party struct's view, kept for the switch-out (`M.untransform`).
    if not userMon.preTransform then
      local moves = {}
      for i = 1, #(userMon.moves or {}) do moves[i] = copyMoveRow(userMon.moves[i]) end
      userMon.preTransform = {
        types = copyList(userMon.types), moves = moves, baseSpd = userMon.baseSpd,
        base = copyKeyed(userMon.base), dvs = copyKeyed(userMon.dvs),
      }
    end
    -- The species byte (wBattleMonSpecies), which CriticalHitTest reads its
    -- base Speed off, and GetEnemyMonStat its base stats: the target's sheet
    -- names them (`baseSpd`, K7 `base`).  The DVs come along too (`.next`
    -- copies two bytes of the target's), which GetEnemyMonStat reads as well.
    userMon.baseSpd = targetMon.baseSpd
    if userMon.baseSpd == nil and type(targetMon.base) == "table" then
      userMon.baseSpd = targetMon.base.spd
    end
    userMon.base = copyKeyed(targetMon.base)
    userMon.dvs = copyKeyed(targetMon.dvs)
    userMon.stats.atk = max(1, int(targetMon.stats.atk, 1))
    userMon.stats.def = max(1, int(targetMon.stats.def, 1))
    userMon.stats.spd = max(1, int(targetMon.stats.spd, 1))
    userMon.stats.spc = max(1, int(targetMon.stats.spc, 1))
    userMon.cur = M.copyStats(targetMon.cur)
    userMon.types = {}
    for i = 1, #targetMon.types do userMon.types[i] = targetMon.types[i] end
    if #userMon.types == 0 then userMon.types[1] = 0 end
    userMon.stages.atk = M.clampStage(targetMon.stages.atk)
    userMon.stages.def = M.clampStage(targetMon.stages.def)
    userMon.stages.spd = M.clampStage(targetMon.stages.spd)
    userMon.stages.spc = M.clampStage(targetMon.stages.spc)
    userMon.stages.acc = M.clampStage(targetMon.stages.acc)
    userMon.stages.eva = M.clampStage(targetMon.stages.eva)
    -- `.copyPPLoop`: 5 PP for every move copied (the whole PP byte, so no
    -- PP Ups), whatever the target had left.
    local copied = {}
    for i = 1, #targetMon.moves do
      local m = targetMon.moves[i]
      copied[#copied + 1] = {
        id = m.id or "move",
        name = m.name,
        pp = M.TRANSFORM_PP,
        maxPp = M.TRANSFORM_PP,
        ppUps = 0,
        -- No GetMaxPP behind the 5 (Turn `stepPp` keeps it fixed).
        basePp = false,
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
    out.animates = true
    -- TransformedText, "<USER>\ntransformed into\n<SPECIES>!": the copied
    -- species is wNameBuffer's (GetMonName), printed bare.
    out.messages[#out.messages + 1] = Events.named(userFighter.side, userMon.species)
      .. "\ntransformed into\n" .. targetMon.species .. "!"
    out.movesChanged = true
    return out
  end

  out.nothing = true
  return out
end

-- ------------------------------------------------------------------
-- Phase 2 side-chance handlers (post-damage, damaging hits only)
-- ------------------------------------------------------------------
--
-- **Red keeps the odds on the effect, not on the move.**  pokered's move
-- records carry no chance byte (data/moves/moves.asm: animation, effect,
-- power, type, accuracy, PP), and the engine's imported Red records follow
-- them -- EMBER is `effect = "BURN_SIDE_EFFECT1"` and nothing more -- so every
-- Red move reaches the referee with `chance = 0` (MediatedBattle `moveOf`
-- reads a `def.chance` no Red record has).  Each routine in
-- engine/battle/effects.asm holds its own constant and compares one
-- BattleRandom byte against it raw (`cp b` / `ret nc`: the effect lands when
-- the byte is below it), RGBDS `percent` being `* $ff / 100` in integer
-- arithmetic (macros/data.asm):
--
--   PoisonEffect          POISON_SIDE_EFFECT1   20 percent + 1 =  52  (:101)
--                         POISON_SIDE_EFFECT2   40 percent + 1 = 103  (:104)
--                         TWINEEDLE_EFFECT: TwoToFiveAttacksEffect's
--                         `.twineedle` rewrites the move's effect to
--                         POISON_SIDE_EFFECT1, so                  52
--   FreezeBurnParalyzeEffect  BURN / FREEZE / PARALYZE_SIDE_EFFECT1
--                                               10 percent + 1 =  26  (:215)
--                         ..._SIDE_EFFECT2      30 percent + 1 =  77  (:218)
--   FlinchSideEffect      FLINCH_SIDE_EFFECT1   10 percent + 1 =  26  (:984)
--                         FLINCH_SIDE_EFFECT2   30 percent + 1 =  77  (:986)
--   StatModifierDownEffect  ATTACK..SPECIAL_DOWN_SIDE_EFFECT
--                                               33 percent + 1 =  85  (:562)
--   ConfusionSideEffect   CONFUSION_SIDE_EFFECT 10 percent     =  25  (:1116)
--                         -- the one constant without the + 1
--
-- A sheet `chance` above 0 is an explicit override in the percent the sheet
-- has always spoken -- floor(chance * 255 / 100), so 100 is 255 and still
-- fails on the byte 255, Accuracy.lua's quirk -- because the suites state one
-- and a content mod's move record may carry one.  0 or absent reads the
-- cart's constant: it is what every Red move sends.  The override moves the
-- threshold and nothing else; when a routine draws, and what it checks before
-- it does, stay the cart's (`applySide`).
M.SIDE_THRESHOLD = {
  [2] = 52, [33] = 103, [77] = 52,             -- PoisonEffect
  [4] = 26, [5] = 26, [6] = 26,                -- FreezeBurnParalyzeEffect
  [34] = 77, [35] = 77, [36] = 77,
  [31] = 26, [37] = 77,                        -- FlinchSideEffect
  [68] = 85, [69] = 85, [70] = 85, [71] = 85,  -- StatModifierDownEffect
  [76] = 25,                                   -- ConfusionSideEffect
}

-- StatModifierDownEffect's extra miss on the enemy's turn outside a link
-- battle (:549-554, `cp 25 percent + 1`), drawn before anything else the
-- routine looks at -- and the side-effect drops go through that routine too,
-- where `MoveMissed` is silent.
M.COMPUTER_DROP_MISS = 64

-- The byte a side effect's draw has to land below: the sheet's percent when it
-- states one, else the cart's constant for the effect.  0 for an effect with
-- no routine here, which never draws -- whatever chance its sheet states,
-- because no Red routine would roll for it.
function M.sideThreshold(effectId, chance)
  local base = M.SIDE_THRESHOLD[int(effectId, 0)]
  if not base then return 0 end
  local pct = max(0, min(100, int(chance, 0)))
  if pct > 0 then return floor(pct * 255 / 100) end
  return base
end

-- One BattleRandom against a threshold: drawn whatever it is compared to.
local function drawBelow(rng, threshold)
  if not rng then return false end
  return rng:byte() < threshold
end

local SIDE_POISON = { [2] = true, [33] = true, [77] = true }
local SIDE_STATUS = {
  [4] = "burn", [5] = "freeze", [6] = "paralysis",
  [34] = "burn", [35] = "freeze", [36] = "paralysis",
}
local SIDE_FLINCH = { [31] = true, [37] = true }
local SIDE_STAT_DOWN = {
  [68] = "atk", [69] = "def", [70] = "spd", [71] = "spc",
}

-- PoisonedText, BurnedText, FrozenText, ParalyzedMayNotAttackText (text_3
-- .asm): "<TARGET>" and the cart's breaks after it.
local INFLICTED = {
  poison = { token = "PSN", says = "\nwas poisoned!" },
  burn = { token = "BRN", says = "\nwas burned!" },
  freeze = { token = "FRZ", says = "\nwas frozen solid!" },
  paralysis = { token = "PAR", says = "'s\nparalyzed! It may\nnot attack!" },
}

-- Whether chart index `typeIndex` is one of the monster's (wEnemyMonType1 /
-- wEnemyMonType2: the battle types, so a Conversion or a Transform counts).
-- nil names no type and matches nothing.
local function hasType(mon, typeIndex)
  if typeIndex == nil or type(mon.types) ~= "table" then return false end
  for i = 1, #mon.types do
    if mon.types[i] == typeIndex then return true end
  end
  return false
end

-- A side effect's condition landing.  The penalty is the routine's own:
-- .burn1 / .burn2 run HalveAttackDueToBurn and paralyze1 / paralyze2
-- QuarterSpeedDueToParalysis the moment it lands (:243, :294; :236, :289);
-- poison and freeze have none, and applyStatusPenalty leaves them be.
local function inflict(out, fighter, mon, status, wire)
  mon.status = status
  M.applyStatusPenalty(mon)
  local entry = INFLICTED[status]
  local text = Events.named(fighter.side, mon.species) .. entry.says
  out.messages[#out.messages + 1] = text
  local fields = fighterFields(fighter)
  fields.status = wire[status] or entry.token
  fields.text = Events.plain(text)
  out.events[#out.events + 1] = { kind = "status", fields = fields }
end

-- One move's side effect, the way its pokered routine runs it.  Turn calls
-- this once per move, after the last hit (`.executeOtherEffects`), and only
-- where the cart gets that far: a target that fainted returned at `ret z`
-- (core.asm :3242), and a Substitute the move broke zeroed the move's effect
-- (AttackSubstitute `.nullifyEffect`, :4899).  A Substitute still standing is
-- read here, off `targetMon.substitute` (M.hasSubstitute: a doll standing at
-- 0 HP included), because each routine answers it
-- differently.
--
-- ctx: effectId, chance, rng, targetMon, targetFighter, userFighter,
--      statusToWire, plus what the routines look at before they draw:
--   moveType       the move's chart index (FreezeBurnParalyzeEffect's
--                  same-type return, CheckDefrost's Fire test)
--   poisonType, fireType
--                  the chart indices of POISON and FIRE (Turn reads them off
--                  the ruleset's `typeIds`).  nil when it named none: then a
--                  Poison-type target can be poisoned and nothing thaws,
--                  because no index can be told to be either type.
--   computerMover  the move is the computer's (StatModifierDownEffect's
--                  extra miss)
--   playerMover    the move is the player's (FreezeBurnParalyzeEffect's
--                  ClearHyperBeam on a freeze, and its HUD shake)
-- Returns { proc, messages, events, shake }; `proc` is the routine's own draw
-- landing (not the computer's miss byte), `shake` the cart animation the
-- routine plays on a status it lands, ahead of its line (Turn sends it on the
-- target's seat):
--   PoisonEffect (:118-151), a side effect -- the primary plays the move's
--     own: ENEMY_HUD_SHAKE_ANIM on the player's turn, SHAKE_SCREEN_ANIM on
--     the enemy's (`ld b, SHAKE_SCREEN_ANIM` ... `jr nz, .ok` / `ld b,
--     ENEMY_HUD_SHAKE_ANIM`, then `ld a, b / call PlayBattleAnimation2`);
--   FreezeBurnParalyzeEffect (:194-302): ENEMY_HUD_SHAKE_ANIM on the
--     player's turn (`.burn1` / `.freeze1` / paralyze1), nothing on the
--     enemy's (`.burn2` / `.freeze2` / paralyze2 print only).
-- "The player's turn" is `playerMover`, the owner's rule.  No other side
-- effect plays one: a flinch, a stat drop, a confusion side effect say
-- nothing or only their line.
function M.applySide(ctx)
  ctx = ctx or {}
  local out = { proc = false, messages = {}, events = {} }
  local effectId = int(ctx.effectId, 0)
  local rng = ctx.rng
  local targetMon = ctx.targetMon
  local targetFighter = ctx.targetFighter
  local wire = ctx.statusToWire or {}
  local threshold = M.sideThreshold(effectId, ctx.chance)
  if threshold <= 0 or type(targetMon) ~= "table" then return out end
  local behindSub = M.hasSubstitute(targetMon)
  local moveType = int(ctx.moveType, nil)

  -- PoisonEffect (:78-162): a Substitute, any status at all and a
  -- Poison-type target each leave through `.noEffect` -- silent for a side
  -- effect -- before `.sideEffectTest` draws.
  if SIDE_POISON[effectId] then
    if behindSub or M.hasMajorStatus(targetMon)
       or hasType(targetMon, ctx.poisonType) then
      return out
    end
    if not drawBelow(rng, threshold) then return out end
    out.proc = true
    inflict(out, targetFighter, targetMon, "poison", wire)
    out.shake = ctx.playerMover and "ENEMY_HUD_SHAKE_ANIM" or "SHAKE_SCREEN_ANIM"
    return out
  end

  -- FreezeBurnParalyzeEffect (:194-302): a Substitute returns first; a target
  -- that already has a status jumps to CheckDefrost (:312-345), where a Fire
  -- move thaws a frozen one ("Fire defrosted <TARGET>!", text_3.asm) and
  -- anything else does nothing; then a target sharing the move's type returns
  -- ("an ice move can't freeze an ice-type, body slam can't paralyze a
  -- normal-type").  None of them draws.
  local status = SIDE_STATUS[effectId]
  if status then
    if behindSub then return out end
    if M.hasMajorStatus(targetMon) then
      if targetMon.status == "freeze" and ctx.fireType ~= nil
         and moveType == ctx.fireType then
        targetMon.status = nil
        targetMon.statusTurns = 0
        local text = "Fire defrosted\n" .. Events.named(targetFighter.side, targetMon.species) .. "!"
        out.messages[#out.messages + 1] = text
        -- No token: a `status` event without one is a cure (Events.lua).
        local fields = fighterFields(targetFighter)
        fields.text = Events.plain(text)
        out.events[#out.events + 1] = { kind = "status", fields = fields }
      end
      return out
    end
    if hasType(targetMon, moveType) then return out end
    if not drawBelow(rng, threshold) then return out end
    out.proc = true
    -- `.freeze1` -- the player's turn -- calls ClearHyperBeam on the target
    -- before writing FRZ; `.freeze2` does not ("hyper beam bits aren't reset
    -- for opponent's side").  `playerMover` is the owner's reading of "the
    -- player": side a against the computer, both sides of a link fight.
    if status == "freeze" and ctx.playerMover then targetMon.mustRecharge = false end
    inflict(out, targetFighter, targetMon, status, wire)
    if ctx.playerMover then out.shake = "ENEMY_HUD_SHAKE_ANIM" end
    return out
  end

  -- FlinchSideEffect (:971-993): a Substitute returns before the draw; a
  -- flinch that lands runs ClearHyperBeam on its target (:991), on either
  -- side's turn -- so a HYPER BEAM user a slower foe flinches never
  -- recharges.
  if SIDE_FLINCH[effectId] then
    if behindSub then return out end
    if not drawBelow(rng, threshold) then return out end
    out.proc = true
    targetMon.flinch = true
    targetMon.mustRecharge = false
    return out
  end

  -- StatModifierDownEffect (:539-562): the computer's extra miss draws first,
  -- then a Substitute misses -- both through `MoveMissed`, silent for a side
  -- effect -- and only then the side-effect byte.  The drop is the one a
  -- primary drop makes, so a side-effect drop on the player's monster re-runs
  -- its badges too (the glitch's Psychic case); Mist is never asked
  -- (applyStatChange).
  local stat = SIDE_STAT_DOWN[effectId]
  if stat then
    if ctx.computerMover and drawBelow(rng, M.COMPUTER_DROP_MISS) then
      return out
    end
    if behindSub then return out end
    if not drawBelow(rng, threshold) then return out end
    out.proc = true
    applyStatChange(out, targetFighter, targetMon, stat, -1,
      ctx.userFighter, targetMon, true)
    return out
  end

  -- ConfusionSideEffect (:1114-1118) draws before it looks at anything, and
  -- ConfusionSideEffectSuccess (:1128-1152) never asks about a Substitute, so
  -- the side effect confuses the monster behind one.  A target already
  -- confused fails silently (ConfusionEffectFailed: `cp
  -- CONFUSION_SIDE_EFFECT; ret z`) without the 2-5 turn byte.
  if effectId == 76 then
    if not drawBelow(rng, threshold) then return out end
    out.proc = true
    confuse(out, targetFighter, targetMon, rng, false)
    return out
  end

  return out
end

-- ------------------------------------------------------------------
-- Phase 3 multi-hit, fixed damage, drain, recoil
-- ------------------------------------------------------------------

-- TWO_TO_FIVE_ATTACKS_EFFECT (29) and EFFECT_1E (30) share
-- TwoToFiveAttacksEffect in the cart's pointer table
-- (data/moves/effects_pointers.asm) and both sit in AlwaysHappenSideEffects,
-- so a move carrying the unused 30 hits two to five times as 29 does;
-- ATTACK_TWICE (44) and TWINEEDLE (77) are the fixed pair.
local MULTIHIT = { [29] = true, [30] = true, [44] = true, [77] = true }
local FIXED_DAMAGE = { [38] = true, [40] = true, [41] = true }
local DRAIN = { [3] = true, [8] = true }
local RECOIL = { [48] = true }

function M.isMultihit(effectId)
  return MULTIHIT[int(effectId, 0)] == true
end

-- CalculateDamage (core.asm :4321-4325) jumps past its power-0 return for
-- the two-to-five pair, so a 0-power TWO_TO_FIVE / EFFECT_1E move still
-- computes a hit: a 0 quotient plus the 2 floor, then STAB, the chart and
-- the roll (a 2 rolls).
function M.hitsAtPowerZero(effectId)
  local id = int(effectId, 0)
  return id == 29 or id == 30
end

-- TwoToFiveAttacksEffect (effects.asm :925-969): ATTACK_TWICE and TWINEEDLE
-- are 2 with no draw; the two-to-five pair draws `BattleRandom & 3`, keeps a
-- 0 or 1 (2 or 3 hits), and on a 2 or 3 draws `& 3` again and keeps that --
-- 2, 3, 4, 5 hits at 3/8, 3/8, 1/8, 1/8.  The caller draws this where the cart
-- does: at the first hit's AlwaysHappenSideEffects, so after that hit (a
-- knockout included) and never when that hit broke a Substitute (Turn).
function M.hitCount(effectId, rng)
  effectId = int(effectId, 0)
  if effectId == 44 or effectId == 77 then return 2 end
  if effectId == 29 or effectId == 30 then
    local n = (rng and rng:byte() or 0) % 4
    if n >= 2 then n = (rng and rng:byte() or 0) % 4 end
    return 2 + n
  end
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

-- DrainHPEffect_ (engine/battle/move_effects/drain_hp.asm): wDamage halved
-- in place, and a 0 bumped to 1 -- "the attacker gains at least 1 HP".
function M.drainAmount(damage)
  return max(1, floor(max(0, int(damage, 0)) / 2))
end

-- RecoilEffect_ (engine/battle/move_effects/recoil.asm): a quarter of
-- wDamage, or half for STRUGGLE (`cp STRUGGLE` before the second `srl`),
-- at least 1.
function M.recoilAmount(damage, struggle)
  local d = max(0, int(damage, 0))
  if struggle then return max(1, floor(d / 2)) end
  return max(1, floor(d / 4))
end

-- SetDamageEffects (data/battle/set_damage_effects.asm): SUPER FANG and
-- SPECIAL_DAMAGE skip CriticalHitTest, HandleCounterMove, CalculateDamage,
-- AdjustDamageForMoveType and RandomizeDamage (core.asm :3137-3140) and go
-- straight to MoveHitTest, so they draw no crit byte and no roll and reach a
-- Ghost or a Normal type the chart would wall; their number is
-- ApplyAttackToEnemyPokemon's (:4612-4672).  OHKO is not one of them: it
-- runs the ordinary path with OneHitKOEffect_ in CalculateDamage's place.
local SET_DAMAGE = { [40] = true, [41] = true }

function M.isSetDamage(effectId)
  return SET_DAMAGE[int(effectId, 0)] == true
end

function M.isOhko(effectId)
  return int(effectId, 0) == 38
end

-- OneHitKOEffect_ (move_effects/one_hit_ko.asm): `sub b / sbc b / jr c,
-- .userIsSlower` -- the move fails only when the user's current Speed is
-- below the target's, so a tie lands.
function M.ohkoLands(userSpeed, foeSpeed)
  return int(userSpeed, 0) >= int(foeSpeed, 0)
end

-- The wDamage a landed OHKO carries into the hit, before RandomizeDamage's
-- roll (the caller's): OneHitKOEffect_ writes $FFFF, and CalculateDamage
-- hands it on to AdjustDamageForMoveType -- STAB is `add hl, bc` on 16 bits
-- (65535 + 32767 wraps to 32766), and each matching TypeEffects row is a
-- Multiply / Divide by 10 whose quotient keeps its low two bytes (core.asm
-- :5100-5170).  `percents` are the rows in the walk's order (Turn
-- `_typeRows`); a 0 is an immunity.  Never under a few thousand on a real
-- chart, so AttackSubstitute breaks a doll outright (a high byte) and an
-- overkill writes the target's HP back over it.
function M.ohkoDamage(stab, percents)
  local d = 65535
  if stab then d = (d + floor(d / 2)) % 65536 end
  for _, pct in ipairs(percents or {}) do
    d = floor(d * max(0, int(pct, 100)) / 100) % 65536
  end
  return d
end

-- `.specialDamage` reads wPlayerMoveNum, not the move's power (every one of
-- these is power 1 on the cart): SEISMIC TOSS and NIGHT SHADE deal the
-- user's level, SONICBOOM 20, DRAGON RAGE 40, and anything else is PSYWAVE.
-- Keyed by the move id the way COUNTER and QUICK ATTACK are.
M.SPECIAL_DAMAGE = {
  SEISMIC_TOSS = "level", NIGHT_SHADE = "level",
  SONICBOOM = 20, DRAGON_RAGE = 40, PSYWAVE = "psywave",
}

-- PSYWAVE's damage: b = level + level / 2 (an 8-bit `add`, so a level over
-- 170 wraps), then `BattleRandom` redrawn until it is in range -- and the
-- range is the mover's.  The player's `.specialDamage` (core.asm
-- :4657-4670) redraws a 0 too (`and a / jr z, .loop`): [1, b).  The
-- enemy's (:4776-4789) has no such test: [0, b), so the computer's PSYWAVE
-- can deal 0 ("it's possible for the enemy to do 0 damage").  `computer` is
-- the computer's seat (Turn `isComputerSeat`); both sides of a link fight
-- are players, each on its own cart, and keep [1, b).  A range with no byte
-- in it -- b of 0 or 1 for the player, 0 for the computer -- freezes the
-- cart; the referee deals the range's floor there (1, or 0) and draws
-- nothing, and bounds the loop the same way (quirks reproduced, freezes
-- never).
function M.psywaveDamage(level, rng, computer)
  local L = max(0, int(level, 1)) % 256
  local b = (L + floor(L / 2)) % 256
  local floorV = computer and 0 or 1
  if b <= floorV or not rng then return floorV end
  for _ = 1, M.REDRAW_GUARD do
    local r = rng:byte()
    if r >= floorV and r < b then return r end
  end
  return floorV
end

-- ctx: effectId, moveId, userMon, targetMon, power, rng, computerMover
-- The damage a SetDamageEffects move deals, drawn where the cart draws it
-- (PSYWAVE's loop, after the hit test; `computerMover` picks the enemy's
-- range, `psywaveDamage`).  A SPECIAL_DAMAGE move whose id the
-- cart's table does not name is a modded one with no cart rule to follow:
-- it keeps the referee's older reading, its power when above 1 and the
-- user's level otherwise.
function M.setDamage(ctx)
  ctx = ctx or {}
  local effectId = int(ctx.effectId, 0)
  local userMon = ctx.userMon or {}
  local targetMon = ctx.targetMon or {}
  if effectId == 40 then
    return max(1, floor(int(targetMon.hp, 0) / 2))
  end
  local rule = M.SPECIAL_DAMAGE[M.moveKey(ctx.moveId)]
  if rule == "level" then return max(0, int(userMon.level, 1)) end
  if rule == "psywave" then
    return M.psywaveDamage(userMon.level, ctx.rng, ctx.computerMover == true)
  end
  if type(rule) == "number" then return rule end
  local power = int(ctx.power, 0)
  if power > 1 then return power end
  return max(1, int(userMon.level, 1))
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

-- Registry id, uppercased. Dig vs Fly share an effect in one gen and not
-- the other; the cart keys vanish and charge text off the move id.
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

-- Fly (effect 43) and Dig (CHARGE + move.id, the engine's special case).
function M.vanishes(effectId, moveOrId)
  return M.isFly(effectId) or M.isDigMove(moveOrId)
end

-- ChargeMoveEffectText (text_3.asm): "<USER>", then the move's own `line`.
-- `side` is the user's (K17's mark); a caller that names none gets the bare
-- name.
function M.chargeMessage(mon, effectId, moveOrId, side)
  local key = M.moveKey(moveOrId)
  local species = (mon and mon.species) or "POKéMON"
  if side ~= nil then species = Events.named(side, species) end
  if key == "DIG" then return species .. "\ndug a hole!" end
  if key == "SOLARBEAM" then return species .. "\ntook in sunlight!" end
  if key == "SKULL_BASH" then return species .. "\nlowered its head!" end
  if key == "RAZOR_WIND" then return species .. "\nmade a whirlwind!" end
  if key == "FLY" or M.isFly(effectId) then return species .. "\nflew up high!" end
  return species .. "\nis glowing!"
end

-- MoveHitTest (core.asm :5228-5262): SWIFT's `ret z` comes before the
-- INVULNERABLE test, so SWIFT reaches a FLY or DIG user, and nothing else
-- does -- `bit INVULNERABLE / jp nz, .moveMissed` has no exception.  (THUNDER
-- reaching FLY, EARTHQUAKE reaching DIG are Gold's, not Red's.)
-- `chargeMoveId` is kept for the callers' shape.
function M.hitsInvulnerable(chargeMoveId, attackerMove)
  local id = M.moveKey(attackerMove)
  if id == "SWIFT" then return true end
  if type(attackerMove) == "table" and M.isSwift(attackerMove.effect) then
    return true
  end
  return false
end

function M.isTrapping(effectId)
  return int(effectId, 0) == 42
end

-- TrappingEffect (effects.asm :1080-1103): `BattleRandom & 3`, kept when
-- 0 or 1, else drawn again -- the counter is that plus one, the attacks
-- after the first, so 2..5 attacks in all at 3/8, 3/8, 1/8, 1/8 (the
-- two-to-five odds).  The referee's `turns` is the total.
function M.trapTurns(rng)
  local n = (rng and rng:byte() or 0) % 4
  if n >= 2 then n = (rng and rng:byte() or 0) % 4 end
  return 2 + n
end

-- The two SpecialEffectsCont routines (data/battle/special_effects.asm):
-- PlayerCanExecuteMove runs them before damage calculation and every hit
-- test (core.asm :3131-3133), so their counters are drawn first and
-- TrappingEffect's ClearHyperBeam lands even when the move then misses.
function M.startsBeforeHit(effectId)
  local id = int(effectId, 0)
  return id == 27 or id == 42
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

-- The effects ExecutePlayerMove / ExecuteEnemyMove hand to JumpMoveEffect
-- before the hit, so a move carrying one never reaches HandleBuildingRage:
-- ResidualEffects1 at PlayerCanExecuteMove (pokered
-- data/battle/residual_effects_1.asm), ResidualEffects2 at `.next`
-- (residual_effects_2.asm), and Mirror Move / Metronome, which jump back to
-- CheckIfPlayerNeedsToChargeUp with the move they call (core.asm :3198-3211).
-- Only a power-0 move asks (Turn's `_useMove`): one with power builds by
-- landing.
local SKIPS_BUILDING_RAGE = {
  -- ResidualEffects1
  [24] = true, [25] = true, [28] = true, [46] = true, [47] = true,
  [49] = true, [56] = true, [57] = true, [64] = true, [65] = true,
  [66] = true, [67] = true, [79] = true, [82] = true, [84] = true,
  [85] = true,
  -- ResidualEffects2
  [1] = true, [10] = true, [11] = true, [12] = true, [13] = true,
  [14] = true, [15] = true, [18] = true, [19] = true, [20] = true,
  [21] = true, [22] = true, [23] = true, [26] = true, [32] = true,
  [50] = true, [51] = true, [52] = true, [53] = true, [54] = true,
  [55] = true, [58] = true, [59] = true, [60] = true, [61] = true,
  [62] = true, [63] = true,
  -- the two that call another move
  [9] = true, [83] = true,
}

function M.skipsBuildingRage(effectId)
  return SKIPS_BUILDING_RAGE[int(effectId, 0)] == true
end

-- ------------------------------------------------------------------
-- move priority
-- ------------------------------------------------------------------
--
-- pokered has no priority table: MainInBattleLoop (core.asm :370-391) asks
-- two questions of wPlayerSelectedMove / wEnemySelectedMove before it
-- compares Speed -- QUICK_ATTACK moves first, COUNTER moves last, and the two
-- sides naming the same one fall through to `.compareSpeed`.  As brackets
-- that is +1, -1 and 0 for everything else, which is BattleSim2's shape
-- (GetMovePriority) with Gen 1's two rows.  Keyed by the move id, because the
-- cart compares move ids: the selected move is what is read, so Metronome and
-- Mirror Move sit in bracket 0 whatever they call.
M.BASE_PRIORITY = 0
M.MOVE_PRIORITY = {
  QUICK_ATTACK = 1,
  COUNTER = -1,
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
local ITEM_HEAL = {
  POTION = 20, SUPER_POTION = 50, HYPER_POTION = 200,
  FRESH_WATER = 50, SODA_POP = 60, LEMONADE = 80,
}
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
}
-- Wire keys match Gen1 ids (X_DEFEND, not X_DEFENSE). X_ACCURACY is a flag.
local ITEM_X_STAGE = {
  X_ATTACK = "atk", X_DEFEND = "def", X_SPEED = "spd", X_SPECIAL = "spc",
}
local ITEM_VITAMIN = {
  HP_UP = "hp", PROTEIN = "atk", IRON = "def",
  CARBOS = "spd", CALCIUM = "spc",
}
-- Gen1 vitamins add 2560 Stat Exp and fail once that pool is already ≥ 25600.
M.VITAMIN_GAIN = 2560
M.VITAMIN_FAIL_AT = 25600

local ITEM_BALL = {
  POKE_BALL = true, GREAT_BALL = true, ULTRA_BALL = true,
  MASTER_BALL = true, SAFARI_BALL = true,
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
    -- A party stat moved: the party struct always, the unmodified stat only
    -- when no Transform has replaced it -- the rule a level-up mid-fight
    -- follows (experience.asm :226-232).  The battle stat is Turn's to
    -- rebuild (recalcBattleStats), and only for the fielded monster.
    M.ensureBattleStats(mon)
    mon.partyStats[stat] = math.max(1, int(mon.partyStats[stat], 1) + delta)
    if not mon.transformed then
      mon.stats[stat] = math.max(1, int(mon.stats[stat], 1) + delta)
    end
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
      spd = math.max(1, int(mon.stats and mon.stats.spd, 1)),
      spc = math.max(1, int(mon.stats and mon.stats.spc, 1)),
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

-- ItemUseBall's Rand1 (`.loop`, item_effects.asm :180-214): a byte is drawn
-- before the ball is even looked at -- the MASTER BALL's too, which then
-- captures -- and a GREAT BALL's is redrawn while above 200, an ULTRA or a
-- SAFARI BALL's while above 150 (`cp b / jr c, .loop`).  The loop never
-- freezes on a real generator; the referee bounds it all the same and
-- answers the range's top (quirks reproduced, freezes never).  No
-- generator draws nothing and answers 0.
local function catchRoll(rng, maxV)
  if not rng then return 0 end
  maxV = max(0, min(255, int(maxV, 255)))
  for _ = 1, M.REDRAW_GUARD do
    local r = rng:byte()
    if r <= maxV then return r end
  end
  return maxV
end

-- Returns caught, shakes (0-3).  RNG order: Rand1 (above), then Rand2 only
-- when Rand1 - Status passed the catch rate and W came out at 255 or below.
-- Wobble math draws nothing.
function M.catchAttempt(ballId, targetMon, rng)
  local def = BALL_DEFS[ballId] or BALL_DEFAULT
  if def.autoCatch then
    catchRoll(rng, 255)
    return true, 3
  end

  local rate = int(targetMon and targetMon.catchRate, 255)
  if rate < 0 then rate = 0 elseif rate > 255 then rate = 255 end

  local statusBonus, shakeBonus = 0, 5
  local s = targetMon and targetMon.status
  if s == "sleep" or s == "freeze" then
    statusBonus, shakeBonus = 25, 10
  elseif s then
    statusBonus, shakeBonus = 12, 5
  end

  -- W = ((MaxHP * 255) / BallFactor) / max(HP / 4, 1), unclamped: the HP
  -- quarter is the low byte of the 16-bit shift (`srl b / rr a` twice), a 0
  -- read as 1; X = min(W, 255) is the byte Rand2 and the shakes read.
  local maxhp = max(1, int(targetMon and targetMon.maxHp, 1))
  local hp = max(0, int(targetMon and targetMon.hp, 0))
  local hpQuarter = floor(hp / 4) % 256
  if hpQuarter == 0 then hpQuarter = 1 end
  local factor = def.hpFactor or BALL_DEFAULT.hpFactor
  local w = floor(floor(maxhp * 255 / factor) / hpQuarter)
  local f = min(255, w)

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
  -- "If W > 255, the ball captures the Pokémon" (`jr nz, .captured`, :305-310)
  -- -- before Rand2 is drawn.
  if w > 255 then return true, 3 end
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

-- PrintMoveFailureText (core.asm :3718-3768): the crash is wDamage / 8,
-- bumped to 1 -- and wDamage is always 0 by then ("since the move missed,
-- wDamage will always contain 0 at this point"), so it is 1, whatever the
-- monster's HP.  `wDamage` is taken for the cart's own reading.
function M.jumpKickCrash(wDamage)
  return max(1, floor(max(0, int(wDamage, 0)) / 8))
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

-- TryRunningFromBattle's wild odds (engine/battle/core.asm :1508-1567): nil
-- for a getaway that draws no byte, else the number a BattleRandom byte must
-- not exceed (`cp b` / `jr nc`).  The runner's 16-bit Speed at or over the
-- wild one's gets away (StringCmp); so does a divisor of 0 -- the wild
-- Speed / 4 taken to its low byte, `srl b / rr a` twice and only `a` kept --
-- and a quotient of the runner's Speed x 32 (the product's low word,
-- hDividend) by it over 255 (hQuotient + 2 nonzero).  Each attempt past the
-- first adds 30 (`attempts` counts this one), and a sum that carries past
-- 255 gets away too.
function M.runOdds(playerSpeed, enemySpeed, attempts)
  local p = max(0, int(playerSpeed, 0)) % 65536
  local e = max(0, int(enemySpeed, 0)) % 65536
  if p >= e then return nil end
  local divisor = floor(e / 4) % 256
  if divisor == 0 then return nil end
  local quotient = floor(((p * 32) % 65536) / divisor)
  if quotient > 255 then return nil end
  for _ = 2, max(1, int(attempts, 1)) do
    quotient = quotient + 30
    if quotient > 255 then return nil end
  end
  return quotient
end

function M.isPayDay(effectId)
  return int(effectId, 0) == 16
end

-- PayDayEffect_ (engine/battle/move_effects/pay_day.asm): the user's level
-- doubled with an 8-bit `add a` (a level over 127 wraps), per use.
function M.payDayCoins(level)
  return (2 * max(0, int(level, 0))) % 256
end

-- The cart's move id for COUNTER: HandleCounterMove (core.asm :4547-4610)
-- compares wPlayerSelectedMove / wEnemySelectedMove with COUNTER, so it is
-- the move, not an effect (COUNTER is NO_ADDITIONAL_EFFECT).
function M.isCounter(moveOrId)
  return M.moveKey(moveOrId) == "COUNTER"
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
