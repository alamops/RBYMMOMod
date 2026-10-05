'use strict';

/*
 * Gen1 move-effect ids and stat-stage multipliers.
 *
 * Behavior taxonomy mirroring the public pret jump-table order; not ROM bytes.
 * Hand-authored 87-slot table (indices 0..86), twin of src/BattleSim/Effects.lua.
 *
 * Phase 0: lookup + stage multipliers. Phase 1: primary stat/status handlers.
 * Phase 2: post-damage side-chance effects + flinch.
 * Phase 3: multi-hit, fixed damage, drain, recoil.
 * Phase 4: multi-turn charge, recharge, trap, thrash, rage.
 * Stored battle stats: pokered's party / unmodified / battle stat sets, the
 * stage-change door (`changeStat`) and both Gen 1 stat glitches.
 */

// The two condition penalties are Status' formulas (and its vectors'); the
// stat machinery below is where they are written into a battle stat.
const Status = require('./Status.js');

const NAMES = [
  'NO_ADDITIONAL_EFFECT',
  'EFFECT_01',
  'POISON_SIDE_EFFECT1',
  'DRAIN_HP_EFFECT',
  'BURN_SIDE_EFFECT1',
  'FREEZE_SIDE_EFFECT1',
  'PARALYZE_SIDE_EFFECT1',
  'EXPLODE_EFFECT',
  'DREAM_EATER_EFFECT',
  'MIRROR_MOVE_EFFECT',
  'ATTACK_UP1_EFFECT',
  'DEFENSE_UP1_EFFECT',
  'SPEED_UP1_EFFECT',
  'SPECIAL_UP1_EFFECT',
  'ACCURACY_UP1_EFFECT',
  'EVASION_UP1_EFFECT',
  'PAY_DAY_EFFECT',
  'SWIFT_EFFECT',
  'ATTACK_DOWN1_EFFECT',
  'DEFENSE_DOWN1_EFFECT',
  'SPEED_DOWN1_EFFECT',
  'SPECIAL_DOWN1_EFFECT',
  'ACCURACY_DOWN1_EFFECT',
  'EVASION_DOWN1_EFFECT',
  'CONVERSION_EFFECT',
  'HAZE_EFFECT',
  'BIDE_EFFECT',
  'THRASH_PETAL_DANCE_EFFECT',
  'SWITCH_AND_TELEPORT_EFFECT',
  'TWO_TO_FIVE_ATTACKS_EFFECT',
  'EFFECT_1E',
  'FLINCH_SIDE_EFFECT1',
  'SLEEP_EFFECT',
  'POISON_SIDE_EFFECT2',
  'BURN_SIDE_EFFECT2',
  'FREEZE_SIDE_EFFECT2',
  'PARALYZE_SIDE_EFFECT2',
  'FLINCH_SIDE_EFFECT2',
  'OHKO_EFFECT',
  'CHARGE_EFFECT',
  'SUPER_FANG_EFFECT',
  'SPECIAL_DAMAGE_EFFECT',
  'TRAPPING_EFFECT',
  'FLY_EFFECT',
  'ATTACK_TWICE_EFFECT',
  'JUMP_KICK_EFFECT',
  'MIST_EFFECT',
  'FOCUS_ENERGY_EFFECT',
  'RECOIL_EFFECT',
  'CONFUSION_EFFECT',
  'ATTACK_UP2_EFFECT',
  'DEFENSE_UP2_EFFECT',
  'SPEED_UP2_EFFECT',
  'SPECIAL_UP2_EFFECT',
  'ACCURACY_UP2_EFFECT',
  'EVASION_UP2_EFFECT',
  'HEAL_EFFECT',
  'TRANSFORM_EFFECT',
  'ATTACK_DOWN2_EFFECT',
  'DEFENSE_DOWN2_EFFECT',
  'SPEED_DOWN2_EFFECT',
  'SPECIAL_DOWN2_EFFECT',
  'ACCURACY_DOWN2_EFFECT',
  'EVASION_DOWN2_EFFECT',
  'LIGHT_SCREEN_EFFECT',
  'REFLECT_EFFECT',
  'POISON_EFFECT',
  'PARALYZE_EFFECT',
  'ATTACK_DOWN_SIDE_EFFECT',
  'DEFENSE_DOWN_SIDE_EFFECT',
  'SPEED_DOWN_SIDE_EFFECT',
  'SPECIAL_DOWN_SIDE_EFFECT',
  'UNUSED',
  'UNUSED',
  'UNUSED',
  'UNUSED',
  'CONFUSION_SIDE_EFFECT',
  'TWINEEDLE_EFFECT',
  'UNUSED',
  'SUBSTITUTE_EFFECT',
  'HYPER_BEAM_EFFECT',
  'RAGE_EFFECT',
  'MIMIC_EFFECT',
  'METRONOME_EFFECT',
  'LEECH_SEED_EFFECT',
  'SPLASH_EFFECT',
  'DISABLE_EFFECT',
];

const CATEGORIES = [
  'none', 'other', 'status_side', 'drain', 'status_side', 'status_side',
  'status_side', 'other', 'drain', 'meta',
  'stat', 'stat', 'stat', 'stat', 'stat', 'stat',
  'other', 'other',
  'stat', 'stat', 'stat', 'stat', 'stat', 'stat',
  'meta', 'meta', 'other', 'thrash', 'flow', 'multihit', 'other',
  'status_side', 'status_primary',
  'status_side', 'status_side', 'status_side', 'status_side', 'status_side',
  'fixed', 'charge', 'fixed', 'fixed', 'trap', 'charge', 'multihit', 'recoil',
  'volatile', 'volatile', 'recoil', 'status_primary',
  'stat', 'stat', 'stat', 'stat', 'stat', 'stat',
  'heal', 'meta',
  'stat', 'stat', 'stat', 'stat', 'stat', 'stat',
  'volatile', 'volatile',
  'status_primary', 'status_primary',
  'status_side', 'status_side', 'status_side', 'status_side',
  'unused', 'unused', 'unused', 'unused',
  'status_side', 'multihit', 'unused', 'volatile', 'flow', 'other', 'meta',
  'meta', 'volatile', 'other', 'volatile',
];

const STAGE_MIN = -6;
const STAGE_MAX = 6;

// Gen1 stage multipliers as percents (25/100 .. 400/100).
const STAGE_MULT = {
  [-6]: 25, [-5]: 28, [-4]: 33, [-3]: 40, [-2]: 50, [-1]: 66,
  0: 100,
  1: 150, 2: 200, 3: 250, 4: 300, 5: 350, 6: 400,
};

const BY_NAME = Object.create(null);
for (let id = 0; id < NAMES.length; id += 1) {
  BY_NAME[NAMES[id]] = id;
}

function int(value, fallback) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.floor(n);
}

function idOf(name) {
  if (typeof name !== 'string') return null;
  const hit = BY_NAME[name];
  return hit === undefined ? null : hit;
}

function nameOf(id) {
  const n = int(id, null);
  if (n === null || n < 0 || n >= NAMES.length) return null;
  return NAMES[n];
}

function category(id) {
  const n = int(id, null);
  if (n === null || n < 0 || n >= CATEGORIES.length) return null;
  return CATEGORIES[n];
}

/*
 * What a move is *called* in a sentence: the display name its sheet carried
 * (PROTOCOL 26), or its registry id when it carried none. Turn.js keeps the
 * same one-line rule; both are prose, never a key something indexes.
 */
function moveLabel(move, fallback) {
  const back = fallback || 'move';
  if (move === null || typeof move !== 'object') return back;
  if (typeof move.name === 'string' && move.name !== '') return move.name;
  if (typeof move.id === 'string' && move.id !== '') return move.id;
  return back;
}

function clampStage(stage) {
  const s = int(stage, 0);
  if (s < STAGE_MIN) return STAGE_MIN;
  if (s > STAGE_MAX) return STAGE_MAX;
  return s;
}

function stageMult(stage) {
  return STAGE_MULT[clampStage(stage)];
}

// CalculateModifiedStat (engine/battle/core.asm :6376-6440): the unmodified
// stat times its StatModifierRatios entry (data/battle/stat_modifiers.asm --
// 15/10 and 150/100 truncate alike, so the table above is that one as
// percents), held to 1..MAX_STAT_VALUE. The two stat-change effects clamp only
// one end each; see `changeStat`.
function applyStage(base, stage) {
  const value = Math.floor(Math.max(0, int(base, 0)) * stageMult(stage) / 100);
  if (value < 1) return 1;
  if (value > MAX_STAT_VALUE) return MAX_STAT_VALUE;
  return value;
}

// Gen1 ApplyBadgeStatBoosts: ×9/8 when the fighter holds the matching badge,
// capped at MAX_STAT_VALUE (999) -- pokered's .applyBoostToStat compares the
// boosted word against it and writes 999 back when it went over; the engine's
// port caps the same way (gen1recomp src/battle/Damage.lua:44-54, citing
// engine/battle/core.asm:6454).
// A fighter only holds a set where the cart would have applied it -- side a
// of a fight against the computer; Turn.attempt drops it in 1v1 / coop_pvp
// (link battles, which the cart never boosts) and on side b (Turn.BADGE_MODES)
// -- so this never has to ask what kind of fight it is in.
const MAX_STAT_VALUE = 999;

const BADGE_FOR_STAT = {
  atk: 'BOULDERBADGE',
  def: 'THUNDERBADGE',
  spd: 'SOULBADGE',
  spc: 'VOLCANOBADGE',
};

function badgeBoost(statValue, wireStatKey, badges) {
  const base = Math.max(0, int(statValue, 0));
  if (!badges || typeof badges !== 'object') return base;
  const badge = BADGE_FOR_STAT[wireStatKey];
  if (!badge || !badges[badge]) return base;
  return Math.min(MAX_STAT_VALUE, Math.floor((base * 9) / 8));
}

// ------------------------------------------------------------------
// Stored battle stats (pokered's own data flow)
// ------------------------------------------------------------------
//
// pokered does not derive a battle stat when it needs one. It keeps three
// sets per battler and *writes* the battle one at a handful of moments, and
// every Gen 1 stat glitch falls out of which moment forgot what. So the
// referee keeps the same three, under the same rules, rather than a read-time
// formula that would round and cap differently:
//
//   * `mon.partyStats` -- the party struct (wPartyMon1Attack...). The sheet's
//     stats; only a vitamin moves them, and Transform never does. A critical
//     hit reads these at both ends (GetDamageVarsForPlayerAttack, core.asm
//     :4059-4072, :4091-4104).
//   * `mon.stats` -- the unmodified stats (wPlayerMonUnmodifiedAttack...), the
//     base every stage change and Haze rebuild from. Reloaded from the party
//     at every switch-in (LoadBattleMonFromParty :1654-1657); Transform copies
//     the target's over them (transform.asm .copyStats).
//   * `mon.cur` -- the battle stats (wBattleMonAttack...): what turn order,
//     damage and the confusion self-hit read, and nothing else adds to them at
//     read time. Written by the switch-in seed (party -> burn/paralysis
//     penalty -> badges), every stage change, a badge re-run, a condition's
//     penalty, Haze and Transform -- every one of them below or in Turn.
//
// `changeStat` is the one door every stage change goes through, so a new
// stat-changing source hooks in there and inherits both glitches for free.

const BATTLE_STATS = ['atk', 'def', 'spd', 'spc'];
const IS_BATTLE_STAT = { atk: true, def: true, spd: true, spc: true };

// Lua's max(0, int(v, 1)): a missing value is 1 (JS's Number(null) is 0, so
// absence is spelled out rather than left to `int`).
function statValue(value) {
  if (value === undefined || value === null) return 1;
  return Math.max(0, int(value, 1));
}

function statBlock(src) {
  const from = src && typeof src === 'object' ? src : {};
  return {
    atk: statValue(from.atk), def: statValue(from.def),
    spd: statValue(from.spd), spc: statValue(from.spc),
  };
}

function resetStages(mon) {
  mon.stages.atk = 0;
  mon.stages.def = 0;
  mon.stages.spd = 0;
  mon.stages.spc = 0;
  mon.stages.acc = 0;
  mon.stages.eva = 0;
}

// Turn.attempt builds all three sets. A monster object assembled anywhere else
// (the Effects suite, a future caller) carries `stats` alone, and gets the
// other two from it here rather than making every function below guard null.
function ensureBattleStats(mon) {
  if (!mon || typeof mon !== 'object') return;
  if (!mon.stats || typeof mon.stats !== 'object') mon.stats = statBlock(null);
  if (!mon.partyStats || typeof mon.partyStats !== 'object') {
    mon.partyStats = statBlock(mon.stats);
  }
  if (!mon.cur || typeof mon.cur !== 'object') mon.cur = statBlock(mon.stats);
  if (!mon.stages || typeof mon.stages !== 'object') {
    mon.stages = { atk: 0, def: 0, spd: 0, spc: 0, acc: 0, eva: 0 };
  }
}

// ApplyBadgeStatBoosts (core.asm :6454-6500): every badge-owned stat of the
// battle mon gets +stat>>3 (the 9/8 above), held at 999 -- every one of them,
// every time it runs, compounding on whatever is already there. `badges` is
// null wherever the cart returns early (a link battle) or never looks (the
// enemy's battler): Turn.attempt keeps a set only on side a of BADGE_MODES.
function applyBadgeBoosts(mon, badges) {
  if (!mon || typeof mon !== 'object' || !badges || typeof badges !== 'object') return;
  ensureBattleStats(mon);
  for (const key of BATTLE_STATS) {
    if (badges[BADGE_FOR_STAT[key]]) {
      mon.cur[key] = badgeBoost(mon.cur[key], key, badges);
    }
  }
}

// QuarterSpeedDueToParalysis / HalveAttackDueToBurn (core.asm :6283-6366),
// written into the battle stat, minimum 1, and only for the condition the
// monster actually has. It runs when the condition lands (effects.asm :236,
// :243, :289, :294; paralyze.asm), when the monster is sent out
// (LoadBattleMonFromParty :1658), and after every successful stat change on
// whichever battler's turn it is NOT, whatever stat the change touched
// (effects.asm :504-506, :694-698) -- the re-penalty glitch. Nothing lifts it
// but a rebuild of that stat: a stage change, Haze, a switch, the player's
// own status-cure item (`reloadPartyStats`).
function applyStatusPenalty(mon) {
  if (!mon || typeof mon !== 'object') return;
  ensureBattleStats(mon);
  if (mon.status === 'paralysis') {
    mon.cur.spd = Status.paralysisSpeed(mon.cur.spd);
  } else if (mon.status === 'burn') {
    mon.cur.atk = Status.burnAttack(mon.cur.atk);
  }
}

// CalculateModifiedStats + ApplyBurnAndParalysisPenalties +
// ApplyBadgeStatBoosts: the battle stats rebuilt from the unmodified ones
// through the current stages, the way a level-up mid-fight rebuilds them
// (engine/battle/experience.asm :226-238). Turn.attempt seeds with it -- a
// live sheet states no stages, so that is LoadBattleMonFromParty's own seed;
// the suites' sheets state some -- and a vitamin on the fielded monster
// re-runs it.
function recalcBattleStats(mon, badges) {
  if (!mon || typeof mon !== 'object') return;
  ensureBattleStats(mon);
  for (const key of BATTLE_STATS) {
    mon.cur[key] = applyStage(mon.stats[key], mon.stages[key]);
  }
  applyStatusPenalty(mon);
  applyBadgeBoosts(mon, badges);
}

// LoadBattleMonFromParty (core.asm :1626-1667) / LoadEnemyMonFromParty: the
// party stats become the unmodified ones (undoing a Transform), then the
// battle ones, then the penalty, then the badges, and every stage goes back to
// neutral. Turn runs it at every switch-in, and at a faint so nothing a fallen
// monster carried survives to a revival.
function loadBattleStats(mon, badges) {
  if (!mon || typeof mon !== 'object') return;
  ensureBattleStats(mon);
  mon.stats = statBlock(mon.partyStats);
  resetStages(mon);
  mon.cur = statBlock(mon.stats);
  applyStatusPenalty(mon);
  applyBadgeBoosts(mon, badges);
}

// ItemUseMedicine's .cureStatusAilment (engine/items/item_effects.asm
// :868-913): curing the fielded monster copies its party stats over its
// battle stats -- which drops the penalty, every badge boost and every stage's
// effect (the stages themselves stay) -- and on a Transformed one, its own
// stats come back. Turn calls it for the player's items only; the computer's
// AICureStatus (engine/battle/trainer_ai.asm :625-636) touches no stat.
function reloadPartyStats(mon) {
  if (!mon || typeof mon !== 'object') return;
  ensureBattleStats(mon);
  mon.cur = statBlock(mon.partyStats);
}

// A copy of a battle-stat block, for the one caller that moves a whole set
// between battlers (Transform).
function copyStats(src) {
  return statBlock(src);
}

// One stage change, the way StatModifierUpEffect / StatModifierDownEffect
// (engine/battle/effects.asm :351-514 / :539-716) make it. Every stage change
// in this referee goes through here: a move's primary or side effect
// (applyPrimary / applySide below), an X item and Rage (Turn).
//
// ctx:
//   mon, fighter -- the battler whose stage moves, and its seat
//   stat, delta  -- 'atk' .. 'eva', +-1 / +-2
//   mover        -- the seat whose turn it is (hWhoseTurn): the move's or the
//                   item's user, or the raging battler for Rage, which
//                   HandleBuildingRage makes the user (core.asm :4913-4950)
//   nonMover     -- the battle mon "whose turn it is not", which the
//                   re-penalty lands on: the action's target for a move, the
//                   battler opposite for an item, the attacker for Rage. null
//                   when nobody is standing there.
//
// Returns { outcome, stage }:
//   'rose' / 'fell' -- the stage moved and the battle stat was rebuilt
//   'max' / 'min'   -- already at +6 / -6: nothing moved (the cart's
//                      "Nothing happened!" / CantLowerAnymore)
//   'stuck'         -- the battle stat itself was already at 999 (a raise) or
//                      1 (a drop). The stage is wound back ONE step whatever
//                      the delta (RestoreOriginalStatModifier `dec [hl]`,
//                      CantLowerAnymore_Pop `inc [hl]`), so a +2 move on a 999
//                      stat still nets +1 -- the cart's quirk, kept.
//
// The rebuild is the changed stat alone: unmodified x the new stage's ratio,
// held at 999 on a raise and at 1 on a drop, the one end each routine checks.
// The other end is left open as the cart leaves it: a drop from a raised stage
// can store more than 999 (a 458 Defense lowered from +4 to +3 is 1145), and a
// raise out of -6 on a tiny stat can store 0; the damage step scales and
// clamps what it is handed. Burn, paralysis and badges are not in the rebuild
// -- which is why a stage change on a burned Attack lifts the burn until the
// re-penalty puts it back.
function changeStat(ctx) {
  const { mon, fighter, stat } = ctx;
  const delta = int(ctx.delta, 0);
  ensureBattleStats(mon);
  const before = clampStage(mon.stages[stat]);
  if (delta > 0 && before >= STAGE_MAX) return { outcome: 'max', stage: before };
  if (delta < 0 && before <= STAGE_MIN) return { outcome: 'min', stage: before };
  const after = clampStage(before + delta);
  mon.stages[stat] = after;

  if (IS_BATTLE_STAT[stat]) {
    const current = int(mon.cur[stat], 0);
    if (delta > 0 && current === MAX_STAT_VALUE) {
      mon.stages[stat] = after - 1;
      return { outcome: 'stuck', stage: mon.stages[stat] };
    }
    if (delta < 0 && current === 1) {
      mon.stages[stat] = after + 1;
      return { outcome: 'stuck', stage: mon.stages[stat] };
    }
    let value = Math.floor(Math.max(0, int(mon.stats[stat], 0)) * stageMult(after) / 100);
    if (delta > 0) {
      value = Math.min(MAX_STAT_VALUE, value);
    } else {
      value = Math.max(1, value);
    }
    mon.cur[stat] = value;
  }

  // The badge-stacking glitch. ApplyBadgeStatBoosts runs again on the
  // player's battle mon after the player's own raise (effects.asm :497-499)
  // and after the enemy's drop (:687-689) -- accuracy and evasion included --
  // over all four stats, so every badge stat compounds another 9/8. "The
  // player" is the seat holding a badge set (Turn.attempt keeps one only on
  // side a of a fight against the computer), so a raise re-runs the mover's
  // own set and a drop re-runs the set of a target sitting across from it.
  if (delta > 0) {
    if (ctx.mover === fighter) applyBadgeBoosts(mon, fighter ? fighter.badges : null);
  } else if (ctx.mover && fighter && ctx.mover.side !== fighter.side) {
    applyBadgeBoosts(mon, fighter.badges);
  }

  // The re-penalty glitch: both routines end on QuarterSpeedDueToParalysis +
  // HalveAttackDueToBurn for the battler whose turn it is not, whichever stat
  // moved ("these shouldn't be here", effects.asm :504-506; :694-698).
  if (ctx.nonMover) applyStatusPenalty(ctx.nonMover);

  return { outcome: delta > 0 ? 'rose' : 'fell', stage: after };
}

// ------------------------------------------------------------------
// Phase 1 primary handlers
// ------------------------------------------------------------------

const STAT_LABELS = {
  atk: 'ATTACK', def: 'DEFENSE', spd: 'SPEED',
  spc: 'SPECIAL', acc: 'ACCURACY', eva: 'EVASION',
};

// effect id -> { stat, delta, selfTarget }
const STAT_EFFECTS = {
  10: { stat: 'atk', delta: 1, selfTarget: true },
  11: { stat: 'def', delta: 1, selfTarget: true },
  12: { stat: 'spd', delta: 1, selfTarget: true },
  13: { stat: 'spc', delta: 1, selfTarget: true },
  14: { stat: 'acc', delta: 1, selfTarget: true },
  15: { stat: 'eva', delta: 1, selfTarget: true },
  18: { stat: 'atk', delta: -1, selfTarget: false },
  19: { stat: 'def', delta: -1, selfTarget: false },
  20: { stat: 'spd', delta: -1, selfTarget: false },
  21: { stat: 'spc', delta: -1, selfTarget: false },
  22: { stat: 'acc', delta: -1, selfTarget: false },
  23: { stat: 'eva', delta: -1, selfTarget: false },
  50: { stat: 'atk', delta: 2, selfTarget: true },
  51: { stat: 'def', delta: 2, selfTarget: true },
  52: { stat: 'spd', delta: 2, selfTarget: true },
  53: { stat: 'spc', delta: 2, selfTarget: true },
  54: { stat: 'acc', delta: 2, selfTarget: true },
  55: { stat: 'eva', delta: 2, selfTarget: true },
  58: { stat: 'atk', delta: -2, selfTarget: false },
  59: { stat: 'def', delta: -2, selfTarget: false },
  60: { stat: 'spd', delta: -2, selfTarget: false },
  61: { stat: 'spc', delta: -2, selfTarget: false },
  62: { stat: 'acc', delta: -2, selfTarget: false },
  63: { stat: 'eva', delta: -2, selfTarget: false },
};

// TransformEffect_'s `.copyPPLoop`: every copied move gets 5 PP.
const TRANSFORM_PP = 5;
// DisableEffect's slot draw is a loop the cart never needs to bound; the
// referee bounds it (applyPrimary) so a malformed sheet cannot hang a hub.
const DISABLE_PICK_GUARD = 4096;
// The same bound on every other redraw loop the referee runs for a cart
// routine that loops until a byte suits it (SleepEffect's counter,
// SwitchAndTeleportEffect's level roll, MimicEffect's `.getRandomMove`): a
// generator that never yields one is a frozen cart, and the referee answers
// the loop's fallback instead (quirks reproduced, freezes never).
const REDRAW_GUARD = 4096;

// The primary stat drops, StatModifierDownEffect's non-side branch.
function isPrimaryStatDown(effectId) {
  const fx = STAT_EFFECTS[int(effectId, 0)];
  return fx !== undefined && fx.delta < 0;
}

// MoveHitTest's Mist check (core.asm :5262-5299): the mover's effect in
// ATTACK_DOWN1..HAZE or ATTACK_DOWN2..REFLECT against a target PROTECTED_BY_
// MIST misses, before the accuracy byte. Of those, only the stat drops ever
// call MoveHitTest (Conversion, Haze and the screens are ResidualEffects1 and
// never do), so the drops are the whole of it.
function mistBlocks(effectId, targetMon) {
  return isPrimaryStatDown(effectId) && !!targetMon && typeof targetMon === 'object'
    && targetMon.mist === true;
}

// How a power-0 move meets MoveHitTest, by its pokered routine. The cart
// never runs MoveHitTest for a power-0 move on the way in (CalculateDamage's
// `jp z, PlayerCheckIfFlyOrChargeEffect`, core.asm :3145; ResidualEffects1
// jumps past it, :3125), so each effect's routine decides:
//   'none'     -- no hit test at all: no INVULNERABLE miss, no accuracy byte.
//                 The self and field effects, Bide, Teleport (its own level
//                 roll), Transform (its own broken check), Splash, Mirror
//                 Move / Metronome (the called move tests), and an
//                 effect-less move (`.executeOtherEffects` finds nothing).
//   'conversion' -- ConversionEffect_'s own INVULNERABLE check, no byte.
//   'statdown' -- StatModifierDownEffect: the computer's extra miss byte, a
//                 Substitute, then MoveHitTest (Mist inside it).
//   'poison'   -- PoisonEffect: a Substitute, a status, a Poison type, then
//                 MoveHitTest.
//   'disable'  -- DisableEffect: MoveHitTest, "But it failed!" on a miss.
//   'sleep'    -- SleepEffect (effects.asm :26-68): a recharging target skips
//                 every check and the hit test; else already asleep, any
//                 status, then MoveHitTest -- no byte before the last.
//   'paralyze' -- ParalyzeEffect_ (move_effects/paralyze.asm): any status, an
//                 ELECTRIC move into a GROUND type, then MoveHitTest.
//   'confusion' -- ConfusionEffect (effects.asm :1120-1126): a Substitute,
//                 then MoveHitTest, then already confused.
//   'mimic'    -- MimicEffect (effects.asm :1203-1273): MoveHitTest, then
//                 the pick (the player's menu, or `BattleRandom & 3`).
//   'leechseed' -- LeechSeedEffect_ (move_effects/leech_seed.asm):
//                 MoveHitTest, then a GRASS type, then already seeded.
// None of the last five asks CheckTargetSubstitute but Confusion, so a doll
// stops none of the others (`blockedBySubstitute`).
const STATUS_PLAN = {
  0: 'none', 1: 'none', 9: 'none', 83: 'none',
  10: 'none', 11: 'none', 12: 'none', 13: 'none', 14: 'none', 15: 'none',
  50: 'none', 51: 'none', 52: 'none', 53: 'none', 54: 'none', 55: 'none',
  25: 'none', 26: 'none', 28: 'none', 46: 'none', 47: 'none',
  56: 'none', 57: 'none', 64: 'none', 65: 'none', 79: 'none', 85: 'none',
  24: 'conversion',
  18: 'statdown', 19: 'statdown', 20: 'statdown', 21: 'statdown',
  22: 'statdown', 23: 'statdown', 58: 'statdown', 59: 'statdown',
  60: 'statdown', 61: 'statdown', 62: 'statdown', 63: 'statdown',
  66: 'poison', 86: 'disable',
  32: 'sleep', 49: 'confusion', 67: 'paralyze', 82: 'mimic',
  84: 'leechseed',
};

// An effect outside the table is a power-0 move whose routine is a damaging
// one (a modded sheet): CalculateDamage returned before the hit test, so it
// is 'none' too.
function statusPlan(effectId) {
  return STATUS_PLAN[int(effectId, 0)] || 'none';
}

// PoisonEffect's turn-aways (effects.asm :78-96), checked before its
// MoveHitTest: a Substitute, any status at all, a Poison type (`cp POISON`
// on both type bytes; `poisonType` is the ruleset's index, null when it
// named none). The primary routine says "It didn't affect" for all three.
function poisonTurnsAway(targetMon, poisonType) {
  if (!targetMon || typeof targetMon !== 'object') return true;
  if (hasSubstitute(targetMon) || hasMajorStatus(targetMon)) return true;
  if (poisonType !== null && poisonType !== undefined && Array.isArray(targetMon.types)) {
    for (const t of targetMon.types) {
      if (t === poisonType) return true;
    }
  }
  return false;
}

const PHASE1_PRIMARY = {
  10: true, 11: true, 12: true, 13: true, 14: true, 15: true,
  18: true, 19: true, 20: true, 21: true, 22: true, 23: true,
  25: true, 32: true, 49: true, 50: true, 51: true, 52: true,
  53: true, 54: true, 55: true, 56: true, 58: true, 59: true,
  60: true, 61: true, 62: true, 63: true, 66: true, 67: true,
  84: true, 85: true, 86: true,
};

function isPhase1Primary(effectId) {
  const n = int(effectId, null);
  if (n === null) return false;
  return PHASE1_PRIMARY[n] === true;
}

const PHASE5_VOLATILE = {
  24: true, 46: true, 47: true, 57: true,
  64: true, 65: true, 79: true,
};

const PHASE6_PRIMARY = {
  82: true, // MIMIC_EFFECT
};

function isPhase5Volatile(effectId) {
  const n = int(effectId, null);
  if (n === null) return false;
  return PHASE5_VOLATILE[n] === true;
}

function isPhase6Primary(effectId) {
  const n = int(effectId, null);
  if (n === null) return false;
  return PHASE6_PRIMARY[n] === true;
}

function handlesPrimary(effectId) {
  return isPhase1Primary(effectId) || isPhase5Volatile(effectId)
    || isPhase6Primary(effectId);
}

function hasMajorStatus(mon) {
  if (!mon || !mon.status) return false;
  const s = mon.status;
  return s === 'sleep' || s === 'poison' || s === 'burn'
    || s === 'freeze' || s === 'paralysis' || s === 'toxic';
}

function fighterFields(fighter) {
  return { slot: fighter.slot, side: fighter.side };
}

// Confusion is a volatile, not a major status: it does not occupy `mon.status`
// and does not persist on the party sheet. The chip is a `confused` flag on
// the status event (1 inflicted, 0 snapped out), independent of PSN/SLP/…
function confuse(out, fighter, mon, rng, failIfAlready) {
  if (mon.confusion && mon.confusion > 0) {
    // ConfusionEffectFailed (effects.asm :1158-1163): the primary's
    // ConditionalPrintButItFailed prints (wMoveDidntMiss is clear on a
    // power-0 move); the side effect's `cp CONFUSION_SIDE_EFFECT / ret z`
    // says nothing.
    if (failIfAlready) out.messages.push('But it failed');
    return;
  }
  const turns = (rng ? rng.byte() : 0) % 4 + 2;
  mon.confusion = turns;
  const text = `${mon.species} became confused`;
  out.messages.push(text);
  const fields = fighterFields(fighter);
  fields.confused = 1;
  fields.text = text;
  out.events.push({ kind: 'status', fields });
}

// A move's stage change, narrated. `changeStat` does the arithmetic and both
// glitches; this adds the sentences. `mover` is the move's user and
// `nonMover` the battle mon of the seat the action was aimed at -- the battler
// whose turn it is not, in the cart's one-opponent terms. `side` is a move's
// side effect, which the cart lets fail silently where a primary prints
// "Nothing happened!" (CantLowerAnymore: `cp ATTACK_DOWN_SIDE_EFFECT; ret nc`).
// Both of a drop's failures go through that label -- the stage already at -6
// (`dec b; jp z, CantLowerAnymore`) and the stat already at 1 -- so a side
// effect says nothing at either wall.
//
// Mist stops a primary drop and never a side effect's. The cart's only Mist
// check is MoveHitTest's (core.asm `.enemyMistCheck` / `.playerMistCheck`),
// which looks at effects ATTACK_DOWN1..HAZE and ATTACK_DOWN2..REFLECT alone;
// the side-effect drops (ATTACK_DOWN_SIDE_EFFECT..SPECIAL_DOWN_SIDE_EFFECT)
// are past that range, and StatModifierDownEffect's side branch never calls
// MoveHitTest -- so AURORA BEAM lowers a Mist user's Attack.
//
// The walls a primary hits say what the cart's routines say: a raise at +6
// is StatModifierUpEffect's `jp c, PrintNothingHappenedText` (effects.asm
// :368-370) and a drop at -6 is CantLowerAnymore (:705-710), both "Nothing
// happened!" -- the same line the 999 / 1 walls print. Mist is no longer
// asked here: it is MoveHitTest's (core.asm :5262-5283), and Turn runs that
// before the accuracy byte (`_statusHitTest`).
function applyStatChange(out, fighter, mon, stat, delta, mover, nonMover, side) {
  const label = STAT_LABELS[stat] || stat;
  const { outcome, stage } = changeStat({
    mon, fighter, stat, delta, mover, nonMover,
  });
  if (outcome === 'max' || outcome === 'min' || outcome === 'stuck') {
    if (!side) out.messages.push('Nothing happened');
    return;
  }
  const text = `${mon.species}'s ${label} ${outcome}`;
  out.messages.push(text);
  const fields = fighterFields(fighter);
  // The stage it now sits at -- when that is not below neutral. `amount` is
  // unsigned on the wire (Wire.AMOUNT_MAX / lib/sanitize: the direction is the
  // sentence's), so the sanitiser strips a negative one in transit; leaving it
  // out here keeps the stream the referee emits the stream a client receives.
  if (stage >= 0) fields.amount = stage;
  // ...and `stage` says it signed, -6..6, every time (contract K10).
  fields.stage = stage;
  fields.text = text;
  out.events.push({ kind: 'stat', fields });
}

// HazeEffect_ (engine/battle/move_effects/haze.asm) on one battler: every
// stage back to neutral (ResetStatMods), the unmodified stats copied over the
// battle ones -- which lifts a burn or paralysis penalty and every badge boost
// until something rebuilds them (ResetStats skips HP and nothing else) -- its
// Disable gone, and CureVolatileStatuses: confusion, X Accuracy, Mist, Focus
// Energy, Leech Seed, and BattleStatus3's Bad Poison, Reflect and Light
// Screen (`and %11110000 | 1 << TRANSFORMED` keeps the Transform). The Bad
// Poison bit going leaves a TOXIC monster plain poisoned -- its PSN bit is in
// the status byte, which Haze cures on the target alone (`applyPrimary`) --
// and takes a lingering bit (`toxicLinger`) with it. Returns whether the
// battler was confused, for the snap-out chip.
function hazeReset(mon) {
  ensureBattleStats(mon);
  resetStages(mon);
  mon.cur = statBlock(mon.stats);
  mon.reflect = false;
  mon.lightScreen = false;
  mon.disable = null;
  mon.xAccuracy = false;
  mon.mist = false;
  mon.focusEnergy = false;
  mon.leechSeed = null;
  if (mon.status === 'toxic') mon.status = 'poison';
  mon.toxicLinger = null;
  const confused = int(mon.confusion, 0) > 0;
  mon.confusion = 0;
  return confused;
}

// Whether a Substitute stands in front of `mon`. The doll's HP is
// `substitute`; AttackSubstitute (core.asm :4849-4900) leaves a doll standing
// at 0 when a hit takes exactly its HP (`sub [hl]` / `ret nc`), and that doll
// is `subAtZero` -- still up, so it still blocks, still soaks the next hit
// (which breaks it) and still makes a second SUBSTITUTE fail.
function hasSubstitute(mon) {
  if (!mon || typeof mon !== 'object') return false;
  return int(mon.substitute, 0) > 0 || mon.subAtZero === true;
}

// The primaries a doll stops are the routines that ask CheckTargetSubstitute
// (effects.asm :1436-1446): StatModifierDownEffect (:551), PoisonEffect
// (:86) and ConfusionEffect (:1121) -- and no other. SleepEffect,
// ParalyzeEffect_, LeechSeedEffect_, TransformEffect_ (whose only
// HAS_SUBSTITUTE_UP test is the user's own, for its animation), MimicEffect
// and DisableEffect never ask, and MoveHitTest's own Substitute check is the
// broken drain one (core.asm :5251-5256), so SLEEP POWDER, THUNDER WAVE,
// LEECH SEED, TRANSFORM, MIMIC and DISABLE all reach the monster behind a
// doll. The self and field effects never had a target to stop. Turn runs
// each of the three where its routine does (the 'statdown', 'poison' and
// 'confusion' plans), before the hit test; this is the backstop for a caller
// that skipped them.
function blockedBySubstitute(effectId) {
  const statFx = STAT_EFFECTS[effectId];
  if (statFx) return !statFx.selfTarget;
  return effectId === 49 || effectId === 66;
}

// ------------------------------------------------------------------
// CalcStat (home/move_mon.asm :54-229)
// ------------------------------------------------------------------
//
// One stat from its base, its DV, the level and (when `statExp` is not null)
// the stat exp: floor(((base + DV) * 2 + floor(b / 4)) * level / 100) + 5,
// and + level + 10 for HP, held at 999. `b` is `.statExpLoop`'s: the least
// b >= 1 with b * b >= stat exp, at most 255 -- so a stat exp of 0 still
// counts 1, which floors to 0. `statExp` null is CalcStat called with `b = 0`
// ("consider stat exp?" no): the term is 0. GetEnemyMonStat (core.asm
// :4258-4297) is the second; a level-up's CalcStats (experience.asm) the
// first.
function statExpBonus(statExp) {
  const se = Math.max(0, int(statExp, 0));
  let b = 1;
  while (b < 255 && b * b < se) b += 1;
  return b;
}

function calcStat(base, dv, level, statExp, isHp) {
  let term = 0;
  if (statExp !== null && statExp !== undefined) term = Math.floor(statExpBonus(statExp) / 4);
  const L = Math.max(0, int(level, 1));
  let value = Math.floor(((Math.max(0, int(base, 0)) + Math.max(0, int(dv, 0))) * 2 + term) * L / 100);
  if (isHp) value += L + 10; else value += 5;
  if (value > MAX_STAT_VALUE) value = MAX_STAT_VALUE;
  return value;
}

// The HP DV CalcStat builds out of the other four's low bits (`.getHPIV`).
function hpDv(dvs) {
  if (!dvs || typeof dvs !== 'object') return 0;
  return (int(dvs.atk, 0) % 2) * 8 + (int(dvs.def, 0) % 2) * 4
    + (int(dvs.spd, 0) % 2) * 2 + (int(dvs.spc, 0) % 2);
}

// ------------------------------------------------------------------
// Transform (engine/battle/move_effects/transform.asm), and undoing it
// ------------------------------------------------------------------

function copyMoveRow(m) {
  return {
    id: m.id || 'move', name: m.name,
    pp: Math.max(0, int(m.pp, 0)), maxPp: m.maxPp,
    power: Math.max(0, int(m.power, 0)), accuracy: Math.max(0, int(m.accuracy, 255)),
    type: Math.max(0, int(m.type, 0)), effect: Math.max(0, int(m.effect, 0)),
    chance: Math.max(0, int(m.chance, 0)), highCrit: m.highCrit === true,
    ppUps: m.ppUps,
  };
}

function copyKeyed(t) {
  if (!t || typeof t !== 'object') return null;
  return { ...t };
}

// What a switch-out gives back. TransformEffect_ rewrites the battle
// struct only (wBattleMon / wEnemyMon); the party struct keeps the
// monster's own species, types, moves and PP -- DecrementPP returns before
// the party copy while TRANSFORMED is set -- so LoadBattleMonFromParty
// (core.asm :1626-1667) brings all of it back. The referee keeps the
// pre-Transform copy on the monster (`preTransform`, the first Transform's
// only: a second one copies over a battle struct the party never saw) and
// restores it here, at a switch-in and at a faint. The stats are
// `loadBattleStats`'.
function untransform(mon) {
  if (!mon || typeof mon !== 'object') return;
  const saved = mon.preTransform;
  mon.preTransform = null;
  mon.transformed = false;
  if (!saved) return;
  mon.types = saved.types;
  mon.moves = saved.moves;
  mon.baseSpd = saved.baseSpd;
  mon.base = saved.base;
  mon.dvs = saved.dvs;
}

// Everything a switch-out or a faint gives back of the battle struct's move
// list (LoadBattleMonFromParty reloads it from the party): the Transform's
// (`untransform`), then every slot a MIMIC wrote while the monster was itself
// -- the party's own move again, at the slot's PP, which DecrementPP kept in
// step with the party's. A MIMIC used while TRANSFORMed wrote over a copy the
// party never had, and `untransform` already threw it away. Walked in slot
// order so both runtimes rebuild the same list.
function restoreMoves(mon) {
  if (!mon || typeof mon !== 'object') return;
  untransform(mon);
  const saved = mon.preMimic;
  mon.preMimic = null;
  if (!saved || typeof saved !== 'object' || !Array.isArray(mon.moves)) return;
  for (let i = 1; i <= mon.moves.length; i += 1) {
    const row = saved[i];
    if (row) {
      const back = copyMoveRow(row);
      back.pp = Math.max(0, int(mon.moves[i - 1].pp, back.pp));
      mon.moves[i - 1] = back;
    }
  }
}

// `.setSleepCounter` (effects.asm :55-59): `BattleRandom / and SLP_MASK`,
// redrawn while it comes out 0 -- 1..7 turns. No generator draws nothing and
// answers 1 (a caller that cannot roll still gets an honest sleep).
function sleepTurns(rng) {
  if (!rng) return 1;
  for (let i = 0; i < REDRAW_GUARD; i += 1) {
    const turns = rng.byte() % 8;
    if (turns !== 0) return turns;
  }
  return 1;
}

// SwitchAndTeleportEffect's level roll (effects.asm :810-846, and the
// enemy's mirror :856-880), for a wild fight: a user at or above the
// target's level always gets away, with no draw. Otherwise `add b / inc c`
// -- c is the two levels plus one, an 8-bit sum -- and `BattleRandom` is
// redrawn until it is below c, then compared with the target's level / 4
// (`srl b / srl b`): at or above it, the escape works. A c that wrapped to 0
// has no byte below it and freezes the cart; the referee draws nothing there
// and the escape fails (quirks reproduced, freezes never).
function teleportEscapes(userLevel, targetLevel, rng) {
  const a = Math.max(0, int(userLevel, 1)) % 256;
  const b = Math.max(0, int(targetLevel, 1)) % 256;
  if (a >= b) return true;
  const c = (a + b + 1) % 256;
  if (c === 0 || !rng) return false;
  for (let i = 0; i < REDRAW_GUARD; i += 1) {
    const r = rng.byte();
    if (r < c) return r >= Math.floor(b / 4);
  }
  return false;
}

// ctx: effectId, rng, userMon, targetMon, userFighter, targetFighter,
//      moveIndex (1-based), statusToWire, plus
//   moveId       the move's id (PoisonEffect's `cp TOXIC`)
//   field        every standing battler, { fighter, mon } in field order
//                (Haze's reach)
//   playerMover  the user is "the player" (Transform's broken check)
//   unlimitedPp  the target is the computer's, whose PP DisableEffect never
//                reads outside a link battle
// Returns { nothing, messages, events, heals, cannotMove } where heals =
// { amount } for user and `cannotMove` is Haze's CANNOT_MOVE on the target.
function applyPrimary(ctx) {
  const out = {
    nothing: false, messages: [], events: [], heals: [], costs: [],
    directDamage: [],
  };
  const c = ctx || {};
  const effectId = int(c.effectId, 0);
  const {
    userMon, targetMon, userFighter, targetFighter, rng,
  } = c;
  const wire = c.statusToWire || {};

  if (targetMon && hasSubstitute(targetMon) && blockedBySubstitute(effectId)) {
    out.nothing = true;
    return out;
  }

  // SplashEffect (effects.asm :1282-1284): its animation, then
  // PrintNoEffectText -- "No effect!".
  if (effectId === 85) {
    out.messages.push('No effect!');
    return out;
  }

  if (effectId === 56) {
    const amount = Math.floor(Math.max(1, int(userMon.maxHp, 1)) / 2);
    out.heals.push({ amount });
    return out;
  }

  if (effectId === 25) {
    // Every battler on the field gets hazeReset -- the cart's two, every
    // standing one of a 2v2 (`c.field`, field order; the user and the target
    // when a caller names none) -- and only the TARGET's status byte is cured
    // (`.cureStatuses`), whatever it held. A target that was asleep or frozen
    // loses the move it has not used yet: `ld a, $ff / ld [de], a` writes
    // CANNOT_MOVE over its selected move (`cannotMove`, Turn's to honour).
    let field = c.field;
    if (!Array.isArray(field) || field.length === 0) {
      field = [{ fighter: userFighter, mon: userMon },
        { fighter: targetFighter, mon: targetMon }];
    }
    const snapped = [];
    for (const seat of field) {
      if (hazeReset(seat.mon)) snapped.push(seat);
    }
    const cured = targetMon.status;
    if (cured) {
      targetMon.status = null;
      targetMon.statusTurns = 0;
      if (cured === 'sleep' || cured === 'freeze') out.cannotMove = true;
      const fields = fighterFields(targetFighter);
      fields.text = `${targetMon.species} recovered`;
      out.events.push({ kind: 'status', fields });
    }
    for (const seat of snapped) {
      const fields = fighterFields(seat.fighter);
      fields.confused = 0;
      fields.text = `${seat.mon.species} snapped out of confusion`;
      out.events.push({ kind: 'status', fields });
    }
    out.messages.push('All stat changes were eliminated');
    return out;
  }

  const statFx = STAT_EFFECTS[effectId];
  if (statFx) {
    const mon = statFx.selfTarget ? userMon : targetMon;
    const fighter = statFx.selfTarget ? userFighter : targetFighter;
    applyStatChange(out, fighter, mon, statFx.stat, statFx.delta,
      userFighter, targetMon, false);
    return out;
  }

  if (effectId === 32) {
    // SleepEffect (effects.asm :26-68), past the checks Turn ran first (the
    // 'sleep' plan). `c.overwrite` is its recharging target, which skips
    // them all: `.setSleepCounter` writes the counter over the whole status
    // byte, so a poison, a burn or a paralysis is simply gone (their stored
    // penalties stay -- nothing recomputes them) and a TOXIC's BADLY_POISONED
    // bit, which lives in BattleStatus3, outlives it (`toxicLinger`), as it
    // does a disobedience nap.
    if (hasMajorStatus(targetMon) && !c.overwrite) {
      out.nothing = true;
      return out;
    }
    if (targetMon.status === 'toxic') targetMon.toxicLinger = true;
    // `.setSleepCounter`: `BattleRandom / and SLP_MASK`, redrawn while it is
    // 0 -- 1..7, uniform, one draw or more.
    const turns = sleepTurns(rng);
    targetMon.status = 'sleep';
    targetMon.statusTurns = turns;
    const token = wire.sleep || 'SLP';
    const text = `${targetMon.species} fell asleep`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 66) {
    // PoisonEffect's turn-aways (a doll, any status, a Poison type) ran in
    // Turn before the hit test (`poisonTurnsAway`); this is what is left for
    // a target that has none. `.inflictPoison`: TOXIC -- the move, by its id
    // (`cp TOXIC` on wPlayerMoveNum) -- sets BADLY_POISONED and zeroes the
    // counter (the referee's counter is the cart's plus one, so 1), and says
    // "<TARGET>'s badly poisoned!"; anything else is plain PSN.
    if (hasMajorStatus(targetMon)) {
      out.nothing = true;
      return out;
    }
    const toxic = moveKey(c.moveId) === 'TOXIC';
    targetMon.status = toxic ? 'toxic' : 'poison';
    targetMon.toxicLinger = null;
    if (toxic) targetMon.toxicCounter = 1;
    const token = toxic ? (wire.toxic || 'TOX') : (wire.poison || 'PSN');
    const text = `${targetMon.species}${toxic ? "'s badly poisoned" : ' was poisoned'}`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 67) {
    if (hasMajorStatus(targetMon)) {
      out.nothing = true;
      return out;
    }
    targetMon.status = 'paralysis';
    // ParalyzeEffect_ quarters the battle Speed the moment it lands
    // (paralyze.asm `callfar QuarterSpeedDueToParalysis`).
    applyStatusPenalty(targetMon);
    const token = wire.paralysis || 'PAR';
    const text = `${targetMon.species} is paralyzed`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 49) {
    confuse(out, targetFighter, targetMon, rng, true);
    return out;
  }

  if (effectId === 84) {
    if (targetMon.leechSeed) {
      out.nothing = true;
      return out;
    }
    targetMon.leechSeed = { fromSlot: userFighter.slot };
    const text = `${targetMon.species} was seeded`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 86) {
    // DisableEffect (effects.asm :1286-1367), after its MoveHitTest (Turn):
    // a target with a move already disabled fails; otherwise `BattleRandom
    // & 3` picks a slot, redrawn until it holds a move. When the target is
    // the player's monster (the enemy's turn, or a link battle -- both sides
    // of one here, the owner's rule), the slot must also have PP: every PP
    // at 0 (masked) is "But it failed!" -- after the draw that found a move
    // -- and a slot whose raw PP byte is 0 is redrawn. The raw byte holds
    // the PP Ups in its top two bits, so a 0-PP move with PP Ups (K8
    // `ppUps`) can be the one disabled. The computer's moves have unlimited
    // PP outside a link battle (`c.unlimitedPp`) and are taken as found.
    // Then `BattleRandom & 7` + 1 turns: 1..8.
    if (targetMon.disable && int(targetMon.disable.turns, 0) > 0) {
      out.messages.push('But it failed');
      return out;
    }
    const moves = targetMon.moves || [];
    if (moves.length === 0 || !rng) {
      out.messages.push('But it failed');
      return out;
    }
    let slot = null;
    let tries = 0;
    while (slot === null) {
      tries += 1;
      // A freeze guard the cart does not need (a target always holds a move
      // with PP by the time this loops); `byte % 4` reaches every slot long
      // before it.
      if (tries > DISABLE_PICK_GUARD) {
        for (let i = 1; i <= moves.length; i += 1) {
          if (c.unlimitedPp || int(moves[i - 1].pp, 0) > 0
              || int(moves[i - 1].ppUps, 0) > 0) {
            slot = i;
            break;
          }
        }
        break;
      }
      const pick = rng.byte() % 4 + 1;
      const m = moves[pick - 1];
      if (m) {
        if (c.unlimitedPp) {
          slot = pick;
        } else {
          let anyPp = false;
          for (let i = 1; i <= moves.length; i += 1) {
            if (int(moves[i - 1].pp, 0) > 0) anyPp = true;
          }
          if (!anyPp) {
            out.messages.push('But it failed');
            return out;
          }
          if (int(m.pp, 0) > 0 || int(m.ppUps, 0) > 0) slot = pick;
        }
      }
    }
    if (slot === null) {
      out.messages.push('But it failed');
      return out;
    }
    const turns = rng.byte() % 8 + 1;
    // The slot (the menu's wPlayerDisabledMove nibble) and the move's id
    // (wPlayerDisabledMoveNumber, TriedToUseDisabledMoveCheck's).
    targetMon.disable = { moveIndex: slot, turns, moveId: moves[slot - 1].id };
    out.messages.push(`${moveLabel(moves[slot - 1])} was disabled`);
    return out;
  }

  if (effectId === 79) {
    const cost = Math.floor(Math.max(1, int(userMon.maxHp, 1)) / 4);
    if (hasSubstitute(userMon)) {
      out.nothing = true;
      return out;
    }
    if (userMon.hp <= cost) {
      out.nothing = true;
      return out;
    }
    userMon.hp -= cost;
    userMon.substitute = cost;
    userMon.subAtZero = null;
    out.directDamage = [{ amount: cost }];
    out.messages.push(`${userMon.species} created a substitute`);
    return out;
  }

  // Reflect and Light Screen are per battler and do not stack: a second cast
  // while the bit is up is "But it failed!" (ReflectLightScreenEffect_,
  // engine/battle/move_effects/reflect_light_screen.asm `.moveFailed`).
  if (effectId === 64) {
    if (userMon.lightScreen) {
      out.messages.push('But it failed');
      return out;
    }
    userMon.lightScreen = true;
    out.messages.push(`${userMon.species} created a light screen`);
    return out;
  }

  if (effectId === 65) {
    if (userMon.reflect) {
      out.messages.push('But it failed');
      return out;
    }
    userMon.reflect = true;
    out.messages.push(`${userMon.species} created a reflect`);
    return out;
  }

  // MistEffect_ / FocusEnergyEffect_ (move_effects/mist.asm,
  // focus_energy.asm): a bit already set is `.mistAlreadyInUse` /
  // `.alreadyUsing`, PrintButItFailedText_ -- "But it failed!".
  if (effectId === 46) {
    if (userMon.mist) {
      out.messages.push('But it failed');
      return out;
    }
    userMon.mist = true;
    out.messages.push(`${userMon.species} is shrouded in mist`);
    return out;
  }

  if (effectId === 47) {
    if (userMon.focusEnergy) {
      out.messages.push('But it failed');
      return out;
    }
    userMon.focusEnergy = true;
    out.messages.push(`${userMon.species} is getting pumped`);
    return out;
  }

  if (effectId === 24) {
    const foeType = targetMon.types[0] || 0;
    userMon.types = [foeType];
    out.messages.push(`${userMon.species} converted type`);
    return out;
  }

  if (effectId === 82) {
    // MimicEffect (effects.asm :1203-1273), past its MoveHitTest and its
    // pick, which Turn makes (`c.mimicSlot`: the player's menu, or
    // `BattleRandom & 3`). `.playerTurn`'s `ld [hl], a` writes the picked
    // move's id over the user's slot at wPlayerMoveListIndex -- the chosen
    // slot (`c.moveIndex`) -- and nothing else: the slot keeps the PP and
    // the PP Ups MIMIC had, this turn's spend included. It is the battle
    // struct's alone; the party keeps MIMIC, and a switch-out or a faint
    // brings it back (`restoreMoves`) with the PP the two shared --
    // DecrementPP writes both while the monster is not TRANSFORMed.
    const moveIndex = int(c.moveIndex, 0);
    const pick = int(c.mimicSlot, 0);
    const source = Array.isArray(targetMon.moves) && pick >= 1
      ? targetMon.moves[pick - 1] : undefined;
    const slotMove = moveIndex >= 1 ? userMon.moves[moveIndex - 1] : undefined;
    if (!(source && slotMove)) {
      out.messages.push('But it failed');
      return out;
    }
    if (!userMon.transformed) {
      if (!userMon.preMimic) userMon.preMimic = {};
      if (!userMon.preMimic[moveIndex]) {
        userMon.preMimic[moveIndex] = copyMoveRow(slotMove);
      }
    }
    userMon.moves[moveIndex - 1] = {
      id: source.id || 'move',
      // The copy is narrated under the same name the original was, so a
      // mimicked move does not revert to its slug on the learner's screen.
      name: source.name,
      pp: Math.max(0, int(slotMove.pp, 0)),
      maxPp: slotMove.maxPp,
      ppUps: slotMove.ppUps,
      power: Math.max(0, int(source.power, 0)),
      accuracy: Math.max(0, int(source.accuracy, 255)),
      type: Math.max(0, int(source.type, 0)),
      effect: Math.max(0, int(source.effect, 0)),
      chance: Math.max(0, int(source.chance, 0)),
      highCrit: source.highCrit === true,
    };
    out.messages.push(`${userMon.species} learned ${moveLabel(source)}`);
    out.movesChanged = true;
    return out;
  }

  if (effectId === 57) {
    // TransformEffect_ (transform.asm) copies the target's battle stats AND
    // its unmodified ones, and its stat mods below; the user's party stats are
    // untouched, which is what a later critical hit reads. Its INVULNERABLE
    // check is the cart's bug: on the player's turn it tests the USER's own
    // BattleStatus1 (`ld a, [wPlayerBattleStatus1]`), so only a player's
    // monster still flagged INVULNERABLE (the full-paralysis FLY glitch)
    // fails; on the enemy's turn `a` is hWhoseTurn (1) and bit 6 is clear,
    // so nothing fails. `c.playerMover` is the owner's rule for "the player"
    // (Turn: side a against the computer, both sides of a link).
    if (c.playerMover && userMon.invulnerable) {
      out.messages.push('But it failed');
      return out;
    }
    ensureBattleStats(userMon);
    ensureBattleStats(targetMon);
    // The party struct's view, kept for the switch-out (`untransform`).
    if (!userMon.preTransform) {
      userMon.preTransform = {
        types: [...(userMon.types || [])],
        moves: (userMon.moves || []).map(copyMoveRow),
        baseSpd: userMon.baseSpd,
        base: copyKeyed(userMon.base),
        dvs: copyKeyed(userMon.dvs),
      };
    }
    // The species byte (wBattleMonSpecies), which CriticalHitTest reads its
    // base Speed off, and GetEnemyMonStat its base stats: the target's sheet
    // names them (`baseSpd`, K7 `base`). The DVs come along too (`.next`
    // copies two bytes of the target's), which GetEnemyMonStat reads as well.
    userMon.baseSpd = targetMon.baseSpd;
    if ((userMon.baseSpd === undefined || userMon.baseSpd === null)
        && targetMon.base && typeof targetMon.base === 'object') {
      userMon.baseSpd = targetMon.base.spd;
    }
    userMon.base = copyKeyed(targetMon.base);
    userMon.dvs = copyKeyed(targetMon.dvs);
    userMon.stats.atk = Math.max(1, int(targetMon.stats.atk, 1));
    userMon.stats.def = Math.max(1, int(targetMon.stats.def, 1));
    userMon.stats.spd = Math.max(1, int(targetMon.stats.spd, 1));
    userMon.stats.spc = Math.max(1, int(targetMon.stats.spc, 1));
    userMon.cur = copyStats(targetMon.cur);
    userMon.types = targetMon.types.length ? [...targetMon.types] : [0];
    userMon.stages.atk = clampStage(targetMon.stages.atk);
    userMon.stages.def = clampStage(targetMon.stages.def);
    userMon.stages.spd = clampStage(targetMon.stages.spd);
    userMon.stages.spc = clampStage(targetMon.stages.spc);
    userMon.stages.acc = clampStage(targetMon.stages.acc);
    userMon.stages.eva = clampStage(targetMon.stages.eva);
    // `.copyPPLoop`: 5 PP for every move copied (the whole PP byte, so no
    // PP Ups), whatever the target had left.
    userMon.moves = targetMon.moves.map((m) => ({
      id: m.id || 'move',
      name: m.name,
      pp: TRANSFORM_PP,
      maxPp: TRANSFORM_PP,
      ppUps: 0,
      power: Math.max(0, int(m.power, 0)),
      accuracy: Math.max(0, int(m.accuracy, 255)),
      type: Math.max(0, int(m.type, 0)),
      effect: Math.max(0, int(m.effect, 0)),
      chance: Math.max(0, int(m.chance, 0)),
      highCrit: m.highCrit === true,
    }));
    userMon.transformed = true;
    out.messages.push(`${userMon.species} transformed into ${targetMon.species}`);
    out.movesChanged = true;
    return out;
  }

  out.nothing = true;
  return out;
}

// ------------------------------------------------------------------
// Phase 2 side-chance handlers (post-damage, damaging hits only)
// ------------------------------------------------------------------
//
// **Red keeps the odds on the effect, not on the move.** pokered's move
// records carry no chance byte (data/moves/moves.asm: animation, effect,
// power, type, accuracy, PP), and the engine's imported Red records follow
// them -- EMBER is `effect = "BURN_SIDE_EFFECT1"` and nothing more -- so every
// Red move reaches the referee with `chance = 0` (MediatedBattle `moveOf`
// reads a `def.chance` no Red record has). Each routine in
// engine/battle/effects.asm holds its own constant and compares one
// BattleRandom byte against it raw (`cp b` / `ret nc`: the effect lands when
// the byte is below it), RGBDS `percent` being `* $ff / 100` in integer
// arithmetic (macros/data.asm):
//
//   PoisonEffect          POISON_SIDE_EFFECT1   20 percent + 1 =  52  (:101)
//                         POISON_SIDE_EFFECT2   40 percent + 1 = 103  (:104)
//                         TWINEEDLE_EFFECT: TwoToFiveAttacksEffect's
//                         `.twineedle` rewrites the move's effect to
//                         POISON_SIDE_EFFECT1, so                  52
//   FreezeBurnParalyzeEffect  BURN / FREEZE / PARALYZE_SIDE_EFFECT1
//                                               10 percent + 1 =  26  (:215)
//                         ..._SIDE_EFFECT2      30 percent + 1 =  77  (:218)
//   FlinchSideEffect      FLINCH_SIDE_EFFECT1   10 percent + 1 =  26  (:984)
//                         FLINCH_SIDE_EFFECT2   30 percent + 1 =  77  (:986)
//   StatModifierDownEffect  ATTACK..SPECIAL_DOWN_SIDE_EFFECT
//                                               33 percent + 1 =  85  (:562)
//   ConfusionSideEffect   CONFUSION_SIDE_EFFECT 10 percent     =  25  (:1116)
//                         -- the one constant without the + 1
//
// A sheet `chance` above 0 is an explicit override in the percent the sheet
// has always spoken -- floor(chance * 255 / 100), so 100 is 255 and still
// fails on the byte 255, Accuracy.js's quirk -- because the suites state one
// and a content mod's move record may carry one. 0 or absent reads the cart's
// constant: it is what every Red move sends. The override moves the threshold
// and nothing else; when a routine draws, and what it checks before it does,
// stay the cart's (`applySide`).
const SIDE_THRESHOLD = {
  2: 52, 33: 103, 77: 52, // PoisonEffect
  4: 26, 5: 26, 6: 26, // FreezeBurnParalyzeEffect
  34: 77, 35: 77, 36: 77,
  31: 26, 37: 77, // FlinchSideEffect
  68: 85, 69: 85, 70: 85, 71: 85, // StatModifierDownEffect
  76: 25, // ConfusionSideEffect
};

// StatModifierDownEffect's extra miss on the enemy's turn outside a link
// battle (:549-554, `cp 25 percent + 1`), drawn before anything else the
// routine looks at -- and the side-effect drops go through that routine too,
// where `MoveMissed` is silent.
const COMPUTER_DROP_MISS = 64;

// The byte a side effect's draw has to land below: the sheet's percent when it
// states one, else the cart's constant for the effect. 0 for an effect with
// no routine here, which never draws -- whatever chance its sheet states,
// because no Red routine would roll for it.
function sideThreshold(effectId, chance) {
  const base = SIDE_THRESHOLD[int(effectId, 0)];
  if (base === undefined) return 0;
  const pct = Math.max(0, Math.min(100, int(chance, 0)));
  if (pct > 0) return Math.floor(pct * 255 / 100);
  return base;
}

// One BattleRandom against a threshold: drawn whatever it is compared to.
function drawBelow(rng, threshold) {
  if (!rng) return false;
  return rng.byte() < threshold;
}

const SIDE_POISON = { 2: true, 33: true, 77: true };
const SIDE_STATUS = {
  4: 'burn', 5: 'freeze', 6: 'paralysis',
  34: 'burn', 35: 'freeze', 36: 'paralysis',
};
const SIDE_FLINCH = { 31: true, 37: true };
const SIDE_STAT_DOWN = {
  68: 'atk', 69: 'def', 70: 'spd', 71: 'spc',
};

const INFLICTED = {
  poison: { token: 'PSN', says: ' was poisoned' },
  burn: { token: 'BRN', says: ' was burned' },
  freeze: { token: 'FRZ', says: ' was frozen solid' },
  paralysis: { token: 'PAR', says: ' is paralyzed' },
};

// Whether chart index `typeIndex` is one of the monster's (wEnemyMonType1 /
// wEnemyMonType2: the battle types, so a Conversion or a Transform counts).
// null names no type and matches nothing.
function hasType(mon, typeIndex) {
  if (typeIndex === null || typeIndex === undefined || !Array.isArray(mon.types)) return false;
  for (const t of mon.types) {
    if (t === typeIndex) return true;
  }
  return false;
}

// A side effect's condition landing. The penalty is the routine's own:
// .burn1 / .burn2 run HalveAttackDueToBurn and paralyze1 / paralyze2
// QuarterSpeedDueToParalysis the moment it lands (:243, :294; :236, :289);
// poison and freeze have none, and applyStatusPenalty leaves them be.
function inflict(out, fighter, mon, status, wire) {
  mon.status = status;
  applyStatusPenalty(mon);
  const entry = INFLICTED[status];
  const text = `${mon.species}${entry.says}`;
  out.messages.push(text);
  const fields = fighterFields(fighter);
  fields.status = wire[status] || entry.token;
  fields.text = text;
  out.events.push({ kind: 'status', fields });
}

// One move's side effect, the way its pokered routine runs it. Turn calls
// this once per move, after the last hit (`.executeOtherEffects`), and only
// where the cart gets that far: a target that fainted returned at `ret z`
// (core.asm :3242), and a Substitute the move broke zeroed the move's effect
// (AttackSubstitute `.nullifyEffect`, :4899). A Substitute still standing is
// read here, off `targetMon.substitute` (hasSubstitute: a doll standing at
// 0 HP included), because each routine answers it
// differently.
//
// ctx: effectId, chance, rng, targetMon, targetFighter, userFighter,
//      statusToWire, plus what the routines look at before they draw:
//   moveType       the move's chart index (FreezeBurnParalyzeEffect's
//                  same-type return, CheckDefrost's Fire test)
//   poisonType, fireType
//                  the chart indices of POISON and FIRE (Turn reads them off
//                  the ruleset's `typeIds`). null when it named none: then a
//                  Poison-type target can be poisoned and nothing thaws,
//                  because no index can be told to be either type.
//   computerMover  the move is the computer's (StatModifierDownEffect's
//                  extra miss)
//   playerMover    the move is the player's (FreezeBurnParalyzeEffect's
//                  ClearHyperBeam on a freeze)
// Returns { proc, messages, events }; `proc` is the routine's own draw
// landing (not the computer's miss byte).
function applySide(ctx) {
  const out = { proc: false, messages: [], events: [] };
  const c = ctx || {};
  const effectId = int(c.effectId, 0);
  const { rng, targetMon, targetFighter } = c;
  const wire = c.statusToWire || {};
  const threshold = sideThreshold(effectId, c.chance);
  if (threshold <= 0 || !targetMon || typeof targetMon !== 'object') return out;
  const behindSub = hasSubstitute(targetMon);
  const moveType = c.moveType === undefined || c.moveType === null
    ? null : int(c.moveType, null);

  // PoisonEffect (:78-162): a Substitute, any status at all and a
  // Poison-type target each leave through `.noEffect` -- silent for a side
  // effect -- before `.sideEffectTest` draws.
  if (SIDE_POISON[effectId]) {
    if (behindSub || hasMajorStatus(targetMon)
      || hasType(targetMon, c.poisonType)) {
      return out;
    }
    if (!drawBelow(rng, threshold)) return out;
    out.proc = true;
    inflict(out, targetFighter, targetMon, 'poison', wire);
    return out;
  }

  // FreezeBurnParalyzeEffect (:194-302): a Substitute returns first; a target
  // that already has a status jumps to CheckDefrost (:312-345), where a Fire
  // move thaws a frozen one ("Fire defrosted <TARGET>!", text_3.asm) and
  // anything else does nothing; then a target sharing the move's type returns
  // ("an ice move can't freeze an ice-type, body slam can't paralyze a
  // normal-type"). None of them draws.
  const status = SIDE_STATUS[effectId];
  if (status) {
    if (behindSub) return out;
    if (hasMajorStatus(targetMon)) {
      if (targetMon.status === 'freeze' && c.fireType !== null && c.fireType !== undefined
        && moveType === c.fireType) {
        targetMon.status = null;
        targetMon.statusTurns = 0;
        const text = `Fire defrosted ${targetMon.species}`;
        out.messages.push(text);
        // No token: a `status` event without one is a cure (events.js).
        const fields = fighterFields(targetFighter);
        fields.text = text;
        out.events.push({ kind: 'status', fields });
      }
      return out;
    }
    if (hasType(targetMon, moveType)) return out;
    if (!drawBelow(rng, threshold)) return out;
    out.proc = true;
    // `.freeze1` -- the player's turn -- calls ClearHyperBeam on the target
    // before writing FRZ; `.freeze2` does not ("hyper beam bits aren't reset
    // for opponent's side"). `playerMover` is the owner's reading of "the
    // player": side a against the computer, both sides of a link fight.
    if (status === 'freeze' && c.playerMover) targetMon.mustRecharge = false;
    inflict(out, targetFighter, targetMon, status, wire);
    return out;
  }

  // FlinchSideEffect (:971-993): a Substitute returns before the draw; a
  // flinch that lands runs ClearHyperBeam on its target (:991), on either
  // side's turn -- so a HYPER BEAM user a slower foe flinches never
  // recharges.
  if (SIDE_FLINCH[effectId]) {
    if (behindSub) return out;
    if (!drawBelow(rng, threshold)) return out;
    out.proc = true;
    targetMon.flinch = true;
    targetMon.mustRecharge = false;
    return out;
  }

  // StatModifierDownEffect (:539-562): the computer's extra miss draws first,
  // then a Substitute misses -- both through `MoveMissed`, silent for a side
  // effect -- and only then the side-effect byte. The drop is the one a
  // primary drop makes, so a side-effect drop on the player's monster re-runs
  // its badges too (the glitch's Psychic case); Mist is never asked
  // (applyStatChange).
  const stat = SIDE_STAT_DOWN[effectId];
  if (stat) {
    if (c.computerMover && drawBelow(rng, COMPUTER_DROP_MISS)) return out;
    if (behindSub) return out;
    if (!drawBelow(rng, threshold)) return out;
    out.proc = true;
    applyStatChange(out, targetFighter, targetMon, stat, -1,
      c.userFighter, targetMon, true);
    return out;
  }

  // ConfusionSideEffect (:1114-1118) draws before it looks at anything, and
  // ConfusionSideEffectSuccess (:1128-1152) never asks about a Substitute, so
  // the side effect confuses the monster behind one. A target already
  // confused fails silently (ConfusionEffectFailed: `cp
  // CONFUSION_SIDE_EFFECT; ret z`) without the 2-5 turn byte.
  if (effectId === 76) {
    if (!drawBelow(rng, threshold)) return out;
    out.proc = true;
    confuse(out, targetFighter, targetMon, rng, false);
    return out;
  }

  return out;
}

// ------------------------------------------------------------------
// Phase 3 multi-hit, fixed damage, drain, recoil
// ------------------------------------------------------------------

// TWO_TO_FIVE_ATTACKS_EFFECT (29) and EFFECT_1E (30) share
// TwoToFiveAttacksEffect in the cart's pointer table
// (data/moves/effects_pointers.asm) and both sit in AlwaysHappenSideEffects,
// so a move carrying the unused 30 hits two to five times as 29 does;
// ATTACK_TWICE (44) and TWINEEDLE (77) are the fixed pair.
const MULTIHIT = { 29: true, 30: true, 44: true, 77: true };
const FIXED_DAMAGE = { 38: true, 40: true, 41: true };
const DRAIN = { 3: true, 8: true };
const RECOIL = { 48: true };

function isMultihit(effectId) {
  return MULTIHIT[int(effectId, 0)] === true;
}

// CalculateDamage (core.asm :4321-4325) jumps past its power-0 return for
// the two-to-five pair, so a 0-power TWO_TO_FIVE / EFFECT_1E move still
// computes a hit: a 0 quotient plus the 2 floor, then STAB, the chart and
// the roll (a 2 rolls).
function hitsAtPowerZero(effectId) {
  const id = int(effectId, 0);
  return id === 29 || id === 30;
}

// TwoToFiveAttacksEffect (effects.asm :925-969): ATTACK_TWICE and TWINEEDLE
// are 2 with no draw; the two-to-five pair draws `BattleRandom & 3`, keeps a
// 0 or 1 (2 or 3 hits), and on a 2 or 3 draws `& 3` again and keeps that --
// 2, 3, 4, 5 hits at 3/8, 3/8, 1/8, 1/8. The caller draws this where the cart
// does: at the first hit's AlwaysHappenSideEffects, so after that hit (a
// knockout included) and never when that hit broke a Substitute (Turn).
function hitCount(effectId, rng) {
  const id = int(effectId, 0);
  if (id === 44 || id === 77) return 2;
  if (id === 29 || id === 30) {
    let n = (rng ? rng.byte() : 0) % 4;
    if (n >= 2) n = (rng ? rng.byte() : 0) % 4;
    return 2 + n;
  }
  return 1;
}

function isFixedDamage(effectId) {
  return FIXED_DAMAGE[int(effectId, 0)] === true;
}

function isDrain(effectId) {
  return DRAIN[int(effectId, 0)] === true;
}

function isRecoil(effectId) {
  return RECOIL[int(effectId, 0)] === true;
}

// DrainHPEffect_ (engine/battle/move_effects/drain_hp.asm): wDamage halved
// in place, and a 0 bumped to 1 -- "the attacker gains at least 1 HP".
function drainAmount(damage) {
  return Math.max(1, Math.floor(Math.max(0, int(damage, 0)) / 2));
}

// RecoilEffect_ (engine/battle/move_effects/recoil.asm): a quarter of
// wDamage, or half for STRUGGLE (`cp STRUGGLE` before the second `srl`), at
// least 1.
function recoilAmount(damage, struggle) {
  const d = Math.max(0, int(damage, 0));
  if (struggle) return Math.max(1, Math.floor(d / 2));
  return Math.max(1, Math.floor(d / 4));
}

// SetDamageEffects (data/battle/set_damage_effects.asm): SUPER FANG and
// SPECIAL_DAMAGE skip CriticalHitTest, HandleCounterMove, CalculateDamage,
// AdjustDamageForMoveType and RandomizeDamage (core.asm :3137-3140) and go
// straight to MoveHitTest, so they draw no crit byte and no roll and reach a
// Ghost or a Normal type the chart would wall; their number is
// ApplyAttackToEnemyPokemon's (:4612-4672). OHKO is not one of them: it runs
// the ordinary path with OneHitKOEffect_ in CalculateDamage's place.
const SET_DAMAGE = { 40: true, 41: true };

function isSetDamage(effectId) {
  return SET_DAMAGE[int(effectId, 0)] === true;
}

function isOhko(effectId) {
  return int(effectId, 0) === 38;
}

// OneHitKOEffect_ (move_effects/one_hit_ko.asm): `sub b / sbc b / jr c,
// .userIsSlower` -- the move fails only when the user's current Speed is
// below the target's, so a tie lands.
function ohkoLands(userSpeed, foeSpeed) {
  return int(userSpeed, 0) >= int(foeSpeed, 0);
}

// `.specialDamage` reads wPlayerMoveNum, not the move's power (every one of
// these is power 1 on the cart): SEISMIC TOSS and NIGHT SHADE deal the
// user's level, SONICBOOM 20, DRAGON RAGE 40, and anything else is PSYWAVE.
// Keyed by the move id the way COUNTER and QUICK ATTACK are.
const SPECIAL_DAMAGE = {
  SEISMIC_TOSS: 'level', NIGHT_SHADE: 'level',
  SONICBOOM: 20, DRAGON_RAGE: 40, PSYWAVE: 'psywave',
};

// PSYWAVE's damage: b = level + level / 2 (an 8-bit `add`, so a level over
// 170 wraps), then `BattleRandom` redrawn until it is in [1, b). A b of 0 or
// 1 has no such byte and freezes the cart; the referee deals 1 there and
// draws nothing (quirks reproduced, freezes never).
function psywaveDamage(level, rng) {
  const L = Math.max(0, int(level, 1)) % 256;
  const b = (L + Math.floor(L / 2)) % 256;
  if (b <= 1 || !rng) return 1;
  let r;
  do { r = rng.byte(); } while (!(r !== 0 && r < b));
  return r;
}

// ctx: effectId, moveId, userMon, targetMon, power, rng
// The damage a SetDamageEffects move deals, drawn where the cart draws it
// (PSYWAVE's loop, after the hit test). A SPECIAL_DAMAGE move whose id the
// cart's table does not name is a modded one with no cart rule to follow: it
// keeps the referee's older reading, its power when above 1 and the user's
// level otherwise.
function setDamage(ctx) {
  const c = ctx || {};
  const effectId = int(c.effectId, 0);
  const userMon = c.userMon || {};
  const targetMon = c.targetMon || {};
  if (effectId === 40) {
    return Math.max(1, Math.floor(int(targetMon.hp, 0) / 2));
  }
  const key = moveKey(c.moveId);
  const rule = Object.prototype.hasOwnProperty.call(SPECIAL_DAMAGE, key) ? SPECIAL_DAMAGE[key] : undefined;
  if (rule === 'level') return Math.max(0, int(userMon.level, 1));
  if (rule === 'psywave') return psywaveDamage(userMon.level, c.rng);
  if (typeof rule === 'number') return rule;
  const power = int(c.power, 0);
  if (power > 1) return power;
  return Math.max(1, int(userMon.level, 1));
}

// ------------------------------------------------------------------
// Phase 4 multi-turn / charge handlers
// ------------------------------------------------------------------

function isCharge(effectId) {
  const id = int(effectId, 0);
  return id === 39 || id === 43;
}

function isFly(effectId) {
  return int(effectId, 0) === 43;
}

function moveKey(moveOrId) {
  let id = moveOrId;
  if (moveOrId && typeof moveOrId === 'object') id = moveOrId.id;
  if (typeof id !== 'string') return '';
  return id.toUpperCase();
}

function isDigMove(moveOrId) {
  return moveKey(moveOrId) === 'DIG';
}

function isSwift(effectId) {
  return int(effectId, 0) === 17;
}

function vanishes(effectId, moveOrId) {
  return isFly(effectId) || isDigMove(moveOrId);
}

function chargeMessage(mon, effectId, moveOrId) {
  const key = moveKey(moveOrId);
  const species = (mon && mon.species) || 'POKéMON';
  if (key === 'DIG') return `${species} dug a hole`;
  if (key === 'SOLARBEAM') return `${species} took in sunlight`;
  if (key === 'SKULL_BASH') return `${species} lowered its head`;
  if (key === 'RAZOR_WIND') return `${species} made a whirlwind`;
  if (key === 'FLY' || isFly(effectId)) return `${species} flew up high`;
  return `${species} is glowing`;
}

// MoveHitTest (core.asm :5228-5262): SWIFT's `ret z` comes before the
// INVULNERABLE test, so SWIFT reaches a FLY or DIG user, and nothing else
// does -- `bit INVULNERABLE / jp nz, .moveMissed` has no exception. (THUNDER
// reaching FLY, EARTHQUAKE reaching DIG are Gold's, not Red's.)
// `chargeMoveId` is kept for the callers' shape.
function hitsInvulnerable(chargeMoveId, attackerMove) {
  const id = moveKey(attackerMove);
  if (id === 'SWIFT') return true;
  if (attackerMove && typeof attackerMove === 'object' && isSwift(attackerMove.effect)) {
    return true;
  }
  return false;
}

function isTrapping(effectId) {
  return int(effectId, 0) === 42;
}

// TrappingEffect (effects.asm :1080-1103): `BattleRandom & 3`, kept when 0
// or 1, else drawn again -- the counter is that plus one, the attacks after
// the first, so 2..5 attacks in all at 3/8, 3/8, 1/8, 1/8 (the two-to-five
// odds). The referee's `turns` is the total.
function trapTurns(rng) {
  let n = (rng ? rng.byte() : 0) % 4;
  if (n >= 2) n = (rng ? rng.byte() : 0) % 4;
  return 2 + n;
}

// The two SpecialEffectsCont routines (data/battle/special_effects.asm):
// PlayerCanExecuteMove runs them before damage calculation and every hit
// test (core.asm :3131-3133), so their counters are drawn first and
// TrappingEffect's ClearHyperBeam lands even when the move then misses.
function startsBeforeHit(effectId) {
  const id = int(effectId, 0);
  return id === 27 || id === 42;
}

function isHyperBeam(effectId) {
  return int(effectId, 0) === 80;
}

function isThrash(effectId) {
  return int(effectId, 0) === 27;
}

function thrashTurns(rng) {
  return 2 + (rng ? rng.byte() : 0) % 2;
}

function isRage(effectId) {
  return int(effectId, 0) === 81;
}

// The effects ExecutePlayerMove / ExecuteEnemyMove hand to JumpMoveEffect
// before the hit, so a move carrying one never reaches HandleBuildingRage:
// ResidualEffects1 at PlayerCanExecuteMove (pokered
// data/battle/residual_effects_1.asm), ResidualEffects2 at `.next`
// (residual_effects_2.asm), and Mirror Move / Metronome, which jump back to
// CheckIfPlayerNeedsToChargeUp with the move they call (core.asm :3198-3211).
// Only a power-0 move asks (Turn's `_useMove`): one with power builds by
// landing.
const SKIPS_BUILDING_RAGE = new Set([
  // ResidualEffects1
  24, 25, 28, 46, 47,
  49, 56, 57, 64, 65,
  66, 67, 79, 82, 84,
  85,
  // ResidualEffects2
  1, 10, 11, 12, 13,
  14, 15, 18, 19, 20,
  21, 22, 23, 26, 32,
  50, 51, 52, 53, 54,
  55, 58, 59, 60, 61,
  62, 63,
  // the two that call another move
  9, 83,
]);

function skipsBuildingRage(effectId) {
  return SKIPS_BUILDING_RAGE.has(int(effectId, 0));
}

// ------------------------------------------------------------------
// move priority
// ------------------------------------------------------------------
//
// pokered has no priority table: MainInBattleLoop (core.asm :370-391) asks
// two questions of wPlayerSelectedMove / wEnemySelectedMove before it
// compares Speed -- QUICK_ATTACK moves first, COUNTER moves last, and the two
// sides naming the same one fall through to `.compareSpeed`. As brackets
// that is +1, -1 and 0 for everything else, which is battle2's shape
// (GetMovePriority) with Gen 1's two rows. Keyed by the move id, because the
// cart compares move ids: the selected move is what is read, so Metronome and
// Mirror Move sit in bracket 0 whatever they call.
const BASE_PRIORITY = 0;
const MOVE_PRIORITY = {
  QUICK_ATTACK: 1,
  COUNTER: -1,
};

// The priority bracket of a move (a move record or its id).
function movePriority(moveOrId) {
  const key = moveKey(moveOrId);
  if (!Object.prototype.hasOwnProperty.call(MOVE_PRIORITY, key)) return BASE_PRIORITY;
  return MOVE_PRIORITY[key];
}

// Gen1 category is type-based. specialTypes is a set of chart indices.
function isSpecialType(typeId, specialTypes) {
  if (!specialTypes || typeof specialTypes !== 'object') return false;
  return specialTypes[int(typeId, 0)] === true;
}

const ITEM_HEAL = {
  POTION: 20, SUPER_POTION: 50, HYPER_POTION: 200,
  FRESH_WATER: 50, SODA_POP: 60, LEMONADE: 80,
};
const ITEM_STATUS = {
  ANTIDOTE: { poison: true, toxic: true },
  BURN_HEAL: { burn: true },
  ICE_HEAL: { freeze: true },
  AWAKENING: { sleep: true },
  PARLYZ_HEAL: { paralysis: true },
  FULL_HEAL: {
    poison: true, toxic: true, burn: true,
    freeze: true, sleep: true, paralysis: true,
  },
};
const ITEM_X_STAGE = {
  X_ATTACK: 'atk', X_DEFEND: 'def', X_SPEED: 'spd', X_SPECIAL: 'spc',
};
const ITEM_VITAMIN = {
  HP_UP: 'hp', PROTEIN: 'atk', IRON: 'def', CARBOS: 'spd', CALCIUM: 'spc',
};
const VITAMIN_GAIN = 2560;
const VITAMIN_FAIL_AT = 25600;
const ITEM_BALL = {
  POKE_BALL: true, GREAT_BALL: true, ULTRA_BALL: true,
  MASTER_BALL: true, SAFARI_BALL: true,
};

// Deliberately absent from itemEffect (unknown → "But it failed", still spend
// the turn; bag upload also omits them): PP_UP / PP_UP_2, evolutionary stones,
// RARE_CANDY, HM/TM, Repel family, Escape Rope, and other field-only ids.
// In-battle catalog: heals, status cures, Revive/Ether/Elixer, X-items /
// Dire Hit / Guard Spec, balls, Poké Doll, Poké Flute, vitamins.

function itemEffect(itemId) {
  if (typeof itemId !== 'string' || !itemId) return null;
  if (itemId === 'MAX_POTION') return { healFull: true, needsParty: true };
  if (itemId === 'FULL_RESTORE') {
    return { healFull: true, clearAllStatus: true, needsParty: true };
  }
  if (itemId === 'REVIVE') {
    return { revive: 0.5, needsParty: true, faintedOnly: true };
  }
  if (itemId === 'MAX_REVIVE') {
    return { revive: 1, needsParty: true, faintedOnly: true };
  }
  if (itemId === 'ETHER') {
    return { ppRestore: 10, needsParty: true, needsMove: true };
  }
  if (itemId === 'MAX_ETHER') {
    return { ppRestore: true, needsParty: true, needsMove: true };
  }
  if (itemId === 'ELIXER' || itemId === 'ELIXIR') {
    return { ppRestoreAll: 10, needsParty: true };
  }
  if (itemId === 'MAX_ELIXER' || itemId === 'MAX_ELIXIR') {
    return { ppRestoreAll: true, needsParty: true };
  }
  if (itemId === 'X_ACCURACY') return { xAccuracy: true, activeOnly: true };
  if (itemId === 'DIRE_HIT') return { focusEnergy: true, activeOnly: true };
  if (itemId === 'GUARD_SPEC') return { mist: true, activeOnly: true };
  if (itemId === 'POKE_DOLL') return { pokeDoll: true };
  if (itemId === 'POKE_FLUTE') return { pokeFlute: true, noConsume: true };
  const stageStat = ITEM_X_STAGE[itemId];
  if (stageStat) return { stage: { stat: stageStat, delta: 1 }, activeOnly: true };
  const vitaminStat = ITEM_VITAMIN[itemId];
  if (vitaminStat) {
    return { vitamin: true, vitaminStat, needsParty: true };
  }
  if (ITEM_BALL[itemId]) return { ball: true };
  const heal = ITEM_HEAL[itemId];
  const statuses = ITEM_STATUS[itemId];
  if (heal === undefined && !statuses) return null;
  return { heal, clearStatuses: statuses, needsParty: true };
}

// Potion / Ether / status cure / vitamin cannot apply to a KO (Revive is
// faintedOnly). Shared by the item picker and `_normaliseChoice` so a
// submitted choice cannot spend the bag or the turn.
function itemFailsOnFainted(effect) {
  if (!effect || typeof effect !== 'object' || effect.faintedOnly) return false;
  return Boolean(effect.heal || effect.healFull || effect.clearStatuses
      || effect.clearAllStatus || effect.ppRestore || effect.ppRestoreAll
      || effect.vitamin);
}

function applyVitamin(mon, itemId) {
  if (!mon || typeof mon !== 'object') return null;
  const effect = itemEffect(itemId);
  const stat = effect && effect.vitaminStat;
  if (!stat) return null;
  if (!mon.evs) mon.evs = {};
  const before = Math.max(0, int(mon.evs[stat], 0));
  if (before >= VITAMIN_FAIL_AT) return null;
  const after = Math.min(65535, before + VITAMIN_GAIN);
  mon.evs[stat] = after;
  const contrib = (ev) => Math.floor(Math.sqrt(Math.max(0, ev)) / 4);
  const level = Math.max(1, int(mon.level, 1));
  const delta = Math.floor((contrib(after) - contrib(before)) * level / 100);
  if (stat === 'hp') {
    mon.maxHp = Math.max(1, int(mon.maxHp, 1) + delta);
    mon.hp = Math.min(mon.maxHp, int(mon.hp, 0) + delta);
  } else {
    // A party stat moved: the party struct always, the unmodified stat only
    // when no Transform has replaced it -- the rule a level-up mid-fight
    // follows (experience.asm :226-232). The battle stat is Turn's to rebuild
    // (recalcBattleStats), and only for the fielded monster.
    ensureBattleStats(mon);
    mon.partyStats[stat] = Math.max(1, int(mon.partyStats[stat], 1) + delta);
    if (!mon.transformed) {
      mon.stats[stat] = Math.max(1, int(mon.stats[stat], 1) + delta);
    }
  }
  return { stat, delta, before, after };
}

function caughtSheet(mon) {
  if (!mon || typeof mon !== 'object') return null;
  const moves = [];
  for (const m of mon.moves || []) {
    if (!m) continue;
    moves.push({
      id: m.id || 'move',
      name: m.name,
      pp: Math.max(0, int(m.pp, 0)),
      power: Math.max(0, int(m.power, 0)),
      accuracy: Math.max(0, int(m.accuracy, 255)),
      type: Math.max(0, int(m.type, 0)),
      effect: Math.max(0, int(m.effect, 0)),
      chance: Math.max(0, int(m.chance, 0)),
    });
  }
  if (!moves.length) return null;
  const out = {
    species: String(mon.species || '?'),
    level: Math.max(1, int(mon.level, 1)),
    hp: Math.max(0, int(mon.hp, 0)),
    maxHp: Math.max(1, int(mon.maxHp, 1)),
    stats: {
      atk: Math.max(1, int(mon.stats && mon.stats.atk, 1)),
      def: Math.max(1, int(mon.stats && mon.stats.def, 1)),
      spd: Math.max(1, int(mon.stats && mon.stats.spd, 1)),
      spc: Math.max(1, int(mon.stats && mon.stats.spc, 1)),
    },
    moves,
    catchRate: Math.max(0, Math.min(255, int(mon.catchRate, 255))),
  };
  if (mon.speciesId) out.speciesId = String(mon.speciesId);
  if (Array.isArray(mon.types)) out.types = mon.types.slice();
  return out;
}

const BALL_DEFS = {
  MASTER_BALL: { autoCatch: true },
  POKE_BALL: { randMax: 255, hpFactor: 12, wobbleFactor: 255 },
  GREAT_BALL: { randMax: 200, hpFactor: 8, wobbleFactor: 200 },
  ULTRA_BALL: { randMax: 150, hpFactor: 12, wobbleFactor: 150 },
  SAFARI_BALL: { randMax: 150, hpFactor: 12, wobbleFactor: 150 },
};
const BALL_DEFAULT = { randMax: 255, hpFactor: 12, wobbleFactor: 150 };

function catchRoll(rng, maxV) {
  maxV = Math.max(0, int(maxV, 0));
  if (maxV <= 0) return 0;
  if (maxV >= 255) return rng ? rng.byte() : 0;
  return (rng ? rng.byte() : 0) % (maxV + 1);
}

function catchAttempt(ballId, targetMon, rng) {
  const def = BALL_DEFS[ballId] || BALL_DEFAULT;
  if (def.autoCatch) return { caught: true, shakes: 3 };

  let rate = int(targetMon && targetMon.catchRate, 255);
  if (rate < 0) rate = 0;
  else if (rate > 255) rate = 255;

  let statusBonus = 0;
  let shakeBonus = 5;
  const s = targetMon && targetMon.status;
  if (s === 'sleep' || s === 'freeze') {
    statusBonus = 25;
    shakeBonus = 10;
  } else if (s) {
    statusBonus = 12;
    shakeBonus = 5;
  }

  const maxhp = Math.max(1, int(targetMon && targetMon.maxHp, 1));
  const hp = Math.max(0, int(targetMon && targetMon.hp, 0));
  const hpQuarter = Math.max(1, Math.floor(hp / 4));
  const factor = def.hpFactor || BALL_DEFAULT.hpFactor;
  const f = Math.min(255, Math.floor(Math.floor(maxhp * 255 / factor) / hpQuarter));

  function shakes() {
    const ballFactor2 = def.wobbleFactor || BALL_DEFAULT.wobbleFactor;
    const y = Math.floor(rate * 100 / ballFactor2);
    let z = y > 255 ? 255 : Math.floor(f * y / 255);
    if (s) z += shakeBonus;
    if (z < 10) return 0;
    if (z < 30) return 1;
    if (z < 70) return 2;
    return 3;
  }

  const r = catchRoll(rng, def.randMax || 255) - statusBonus;
  if (r < 0) return { caught: true, shakes: 3 };
  if (r > rate) return { caught: false, shakes: shakes() };
  if (catchRoll(rng, 255) <= f) return { caught: true, shakes: 3 };
  return { caught: false, shakes: shakes() };
}

function isWildMode(mode) {
  return typeof mode === 'string' && mode.includes('wild');
}

// ------------------------------------------------------------------
// Phase 6 meta / flow handlers
// ------------------------------------------------------------------

const NO_OP = {
  1: true, 30: true,
  72: true, 73: true, 74: true, 75: true, 78: true,
};

function isNoOp(effectId) {
  return NO_OP[int(effectId, 0)] === true;
}

function isBide(effectId) {
  return int(effectId, 0) === 26;
}

function bideTurns(rng) {
  return 2 + (rng ? rng.byte() : 0) % 2;
}

function isExplode(effectId) {
  return int(effectId, 0) === 7;
}

function isJumpKick(effectId) {
  return int(effectId, 0) === 45;
}

// PrintMoveFailureText (core.asm :3718-3768): the crash is wDamage / 8,
// bumped to 1 -- and wDamage is always 0 by then ("since the move missed,
// wDamage will always contain 0 at this point"), so it is 1, whatever the
// monster's HP. `wDamage` is taken for the cart's own reading.
function jumpKickCrash(wDamage) {
  return Math.max(1, Math.floor(Math.max(0, int(wDamage, 0)) / 8));
}

function isSwitchAndTeleport(effectId) {
  return int(effectId, 0) === 28;
}

// Mediated modes (1v1, coop_*) have no wild flee; only modes whose name
// contains "wild" may treat Teleport as a successful run.
function teleportRunAllowed(mode) {
  return typeof mode === 'string' && mode.includes('wild');
}

// RUN finishes the fight in wild/coop_wild (flee) and 1v1/coop_pvp
// (concession). coop_npc -- and any other non-wild non-pvp mode -- refuses
// without finishing, so a gym cannot be forfeited by pressing RUN.
function runEndsBattle(mode) {
  if (teleportRunAllowed(mode)) return true;
  return mode === '1v1' || mode === 'coop_pvp';
}

// TryRunningFromBattle's wild odds (engine/battle/core.asm :1508-1567): null
// for a getaway that draws no byte, else the number a BattleRandom byte must
// not exceed (`cp b` / `jr nc`). The runner's 16-bit Speed at or over the
// wild one's gets away (StringCmp); so does a divisor of 0 -- the wild Speed
// / 4 taken to its low byte, `srl b / rr a` twice and only `a` kept -- and a
// quotient of the runner's Speed x 32 (the product's low word, hDividend) by
// it over 255 (hQuotient + 2 nonzero). Each attempt past the first adds 30
// (`attempts` counts this one), and a sum that carries past 255 gets away too.
function runOdds(playerSpeed, enemySpeed, attempts) {
  const p = Math.max(0, int(playerSpeed, 0)) % 65536;
  const e = Math.max(0, int(enemySpeed, 0)) % 65536;
  if (p >= e) return null;
  const divisor = Math.floor(e / 4) % 256;
  if (divisor === 0) return null;
  let quotient = Math.floor(((p * 32) % 65536) / divisor);
  if (quotient > 255) return null;
  for (let i = 2; i <= Math.max(1, int(attempts, 1)); i += 1) {
    quotient += 30;
    if (quotient > 255) return null;
  }
  return quotient;
}

function isPayDay(effectId) {
  return int(effectId, 0) === 16;
}

// PayDayEffect_ (engine/battle/move_effects/pay_day.asm): the user's level
// doubled with an 8-bit `add a` (a level over 127 wraps), per use.
function payDayCoins(level) {
  return (2 * Math.max(0, int(level, 0))) % 256;
}

// The cart's move id for COUNTER: HandleCounterMove (core.asm :4547-4610)
// compares wPlayerSelectedMove / wEnemySelectedMove with COUNTER, so it is
// the move, not an effect (COUNTER is NO_ADDITIONAL_EFFECT).
function isCounter(moveOrId) {
  return moveKey(moveOrId) === 'COUNTER';
}

function isMirrorMove(effectId) {
  return int(effectId, 0) === 9;
}

function isMimic(effectId) {
  return int(effectId, 0) === 82;
}

function isMetronome(effectId) {
  return int(effectId, 0) === 83;
}

module.exports = {
  NAMES,
  CATEGORIES,
  STAGE_MIN,
  STAGE_MAX,
  STAGE_MULT,
  idOf,
  nameOf,
  category,
  clampStage,
  stageMult,
  applyStage,
  badgeBoost,
  BATTLE_STATS,
  ensureBattleStats,
  applyBadgeBoosts,
  applyStatusPenalty,
  recalcBattleStats,
  loadBattleStats,
  reloadPartyStats,
  copyStats,
  changeStat,
  MAX_STAT_VALUE,
  isPhase1Primary,
  isPhase5Volatile,
  isPhase6Primary,
  handlesPrimary,
  hasMajorStatus,
  hasSubstitute,
  applyPrimary,
  SIDE_THRESHOLD,
  COMPUTER_DROP_MISS,
  sideThreshold,
  applySide,
  isMultihit,
  hitCount,
  isFixedDamage,
  isDrain,
  isRecoil,
  drainAmount,
  recoilAmount,
  hitsAtPowerZero,
  isSetDamage,
  isOhko,
  ohkoLands,
  SPECIAL_DAMAGE,
  psywaveDamage,
  setDamage,
  statExpBonus,
  calcStat,
  hpDv,
  untransform,
  restoreMoves,
  sleepTurns,
  teleportEscapes,
  TRANSFORM_PP,
  DISABLE_PICK_GUARD,
  REDRAW_GUARD,
  isPrimaryStatDown,
  mistBlocks,
  statusPlan,
  poisonTurnsAway,
  startsBeforeHit,
  isCharge,
  isFly,
  moveKey,
  isDigMove,
  isSwift,
  vanishes,
  chargeMessage,
  hitsInvulnerable,
  isTrapping,
  trapTurns,
  isHyperBeam,
  isThrash,
  thrashTurns,
  isRage,
  skipsBuildingRage,
  BASE_PRIORITY,
  MOVE_PRIORITY,
  movePriority,
  isSpecialType,
  itemEffect,
  itemFailsOnFainted,
  applyVitamin,
  caughtSheet,
  catchAttempt,
  isWildMode,
  isNoOp,
  isBide,
  bideTurns,
  isExplode,
  isJumpKick,
  jumpKickCrash,
  isSwitchAndTeleport,
  teleportRunAllowed,
  runEndsBattle,
  runOdds,
  isPayDay,
  payDayCoins,
  isCounter,
  isMirrorMove,
  isMimic,
  isMetronome,
};
