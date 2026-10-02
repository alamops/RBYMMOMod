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
    if (failIfAlready) out.nothing = true;
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
function applyStatChange(out, fighter, mon, stat, delta, mover, nonMover, side) {
  if (delta < 0 && mon.mist) {
    out.messages.push('But it failed');
    return;
  }
  const label = STAT_LABELS[stat] || stat;
  const { outcome, stage } = changeStat({
    mon, fighter, stat, delta, mover, nonMover,
  });
  if (outcome === 'max') {
    out.messages.push(`${mon.species}'s ${label} won't go any higher`);
    return;
  }
  if (outcome === 'min') {
    if (!side) out.messages.push(`${mon.species}'s ${label} won't go any lower`);
    return;
  }
  if (outcome === 'stuck') {
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
  fields.text = text;
  out.events.push({ kind: 'stat', fields });
}

// HazeEffect_ (engine/battle/move_effects/haze.asm) on one battler: every
// stage back to neutral, the unmodified stats copied over the battle ones --
// which lifts a burn or paralysis penalty and every badge boost until
// something rebuilds them (ResetStats skips HP and nothing else) -- and its
// Reflect and Light Screen gone (CureVolatileStatuses).
function hazeReset(mon) {
  ensureBattleStats(mon);
  resetStages(mon);
  mon.cur = statBlock(mon.stats);
  mon.reflect = false;
  mon.lightScreen = false;
}

// Cartridge Substitute blocks foe-targeting primaries (Sleep Powder, Growl,
// Disable, Transform, Mimic). Self-targeting (Recover, Swords Dance,
// Substitute) and field-wide Haze still run; Conversion copies onto the user.
function blockedBySubstitute(effectId) {
  const statFx = STAT_EFFECTS[effectId];
  if (statFx) return !statFx.selfTarget;
  if (effectId === 24 || effectId === 25 || effectId === 46 || effectId === 47
      || effectId === 56 || effectId === 64 || effectId === 65
      || effectId === 79 || effectId === 85) {
    return false;
  }
  return true;
}

// ctx: effectId, rng, userMon, targetMon, userFighter, targetFighter,
//      moveIndex (1-based), statusToWire
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

  if (targetMon && (targetMon.substitute || 0) > 0 && blockedBySubstitute(effectId)) {
    out.nothing = true;
    return out;
  }

  if (effectId === 85) {
    out.nothing = true;
    return out;
  }

  if (effectId === 56) {
    const amount = Math.floor(Math.max(1, int(userMon.maxHp, 1)) / 2);
    out.heals.push({ amount });
    return out;
  }

  if (effectId === 25) {
    // Both battlers of the action, as the cart's two: stages, battle stats
    // and screens (see hazeReset).
    hazeReset(userMon);
    hazeReset(targetMon);
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
    if (hasMajorStatus(targetMon)) {
      out.nothing = true;
      return out;
    }
    const turns = (rng ? rng.byte() : 0) % 7 + 1;
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
    if (hasMajorStatus(targetMon)) {
      out.nothing = true;
      return out;
    }
    targetMon.status = 'poison';
    const token = wire.poison || 'PSN';
    const text = `${targetMon.species} was poisoned`;
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
    const lastIdx = int(targetMon.lastMoveIndex, 0);
    if (lastIdx < 1 || !targetMon.moves[lastIdx - 1]) {
      out.nothing = true;
      return out;
    }
    if (targetMon.disable && targetMon.disable.turns && targetMon.disable.turns > 0) {
      out.nothing = true;
      return out;
    }
    const turns = (rng ? rng.byte() : 0) % 4 + 2;
    targetMon.disable = { moveIndex: lastIdx, turns };
    out.messages.push(`${moveLabel(targetMon.moves[lastIdx - 1])} was disabled`);
    return out;
  }

  if (effectId === 79) {
    const cost = Math.floor(Math.max(1, int(userMon.maxHp, 1)) / 4);
    if (userMon.substitute && userMon.substitute > 0) {
      out.nothing = true;
      return out;
    }
    if (userMon.hp <= cost) {
      out.nothing = true;
      return out;
    }
    userMon.hp -= cost;
    userMon.substitute = cost;
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

  if (effectId === 46) {
    userMon.mist = true;
    out.messages.push(`${userMon.species} is shrouded in mist`);
    return out;
  }

  if (effectId === 47) {
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
    const moveIndex = int(c.moveIndex, 0);
    const lastIdx = int(targetMon.lastMoveIndex, 0);
    if (lastIdx < 1 || lastIdx > targetMon.moves.length) {
      out.nothing = true;
      return out;
    }
    const source = targetMon.moves[lastIdx - 1];
    if (!source) {
      out.nothing = true;
      return out;
    }
    userMon.moves[moveIndex - 1] = {
      id: source.id || 'move',
      // The copy is narrated under the same name the original was, so a
      // mimicked move does not revert to its slug on the learner's screen.
      name: source.name,
      pp: Math.max(0, int(source.pp, 0)),
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
    // untouched, which is what a later critical hit reads.
    ensureBattleStats(userMon);
    ensureBattleStats(targetMon);
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
    userMon.moves = targetMon.moves.map((m) => ({
      id: m.id || 'move',
      name: m.name,
      pp: Math.max(0, int(m.pp, 0)),
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

// Same 1/256 quirk as Accuracy.js: byte is 0..255, threshold is
// floor(chance * 255 / 100), proc when byte < threshold. chance 0 never;
// chance 100 is byte < 255 (always except the 1/256 roll of 255).
function sideChanceProc(rng, chance) {
  let c = Math.max(0, Math.min(100, int(chance, 0)));
  if (c <= 0) return false;
  const threshold = Math.floor(c * 255 / 100);
  if (threshold <= 0) return false;
  return rng && rng.byte() < threshold;
}

const SIDE_STAT_DOWN = {
  68: 'atk', 69: 'def', 70: 'spd', 71: 'spc',
};

// ctx: effectId, chance, rng, targetMon, targetFighter, userFighter,
//      statusToWire
function applySide(ctx) {
  const out = { proc: false, messages: [], events: [] };
  const c = ctx || {};
  const effectId = int(c.effectId, 0);
  const chance = int(c.chance, 0);
  const { rng, targetMon, targetFighter } = c;
  const wire = c.statusToWire || {};

  if (!sideChanceProc(rng, chance)) return out;
  out.proc = true;

  if (effectId === 2 || effectId === 33 || effectId === 77) {
    if (hasMajorStatus(targetMon)) return out;
    targetMon.status = 'poison';
    const token = wire.poison || 'PSN';
    const text = `${targetMon.species} was poisoned`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 4 || effectId === 34) {
    if (hasMajorStatus(targetMon)) return out;
    targetMon.status = 'burn';
    // .burn1 / .burn2: HalveAttackDueToBurn the moment it lands
    // (effects.asm :243, :294).
    applyStatusPenalty(targetMon);
    const token = wire.burn || 'BRN';
    const text = `${targetMon.species} was burned`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 5 || effectId === 35) {
    if (hasMajorStatus(targetMon)) return out;
    targetMon.status = 'freeze';
    const token = wire.freeze || 'FRZ';
    const text = `${targetMon.species} was frozen solid`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 6 || effectId === 36) {
    if (hasMajorStatus(targetMon)) return out;
    targetMon.status = 'paralysis';
    // paralyze1 / paralyze2: QuarterSpeedDueToParalysis the moment it lands
    // (effects.asm :236, :289).
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

  if (effectId === 31 || effectId === 37) {
    targetMon.flinch = true;
    return out;
  }

  const stat = SIDE_STAT_DOWN[effectId];
  if (stat) {
    // The same StatModifierDownEffect a primary drop runs, so a side-effect
    // drop on the player's monster re-runs its badges too (the glitch's
    // Psychic case).
    applyStatChange(out, targetFighter, targetMon, stat, -1,
      c.userFighter, targetMon, true);
    return out;
  }

  if (effectId === 76) {
    confuse(out, targetFighter, targetMon, rng, false);
    return out;
  }

  out.proc = false;
  return out;
}

// ------------------------------------------------------------------
// Phase 3 multi-hit, fixed damage, drain, recoil
// ------------------------------------------------------------------

const MULTIHIT = { 29: true, 44: true, 77: true };
const FIXED_DAMAGE = { 38: true, 40: true, 41: true };
const DRAIN = { 3: true, 8: true };
const RECOIL = { 48: true };

function isMultihit(effectId) {
  return MULTIHIT[int(effectId, 0)] === true;
}

function hitCount(effectId, rng) {
  const id = int(effectId, 0);
  if (id === 44 || id === 77) return 2;
  if (id === 29) return 2 + (rng ? rng.byte() : 0) % 4;
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

function drainAmount(damage) {
  return Math.floor(Math.max(0, int(damage, 0)) / 2);
}

function recoilAmount(damage) {
  return Math.max(1, Math.floor(Math.max(0, int(damage, 0)) / 4));
}

function fixedDamage(ctx) {
  const c = ctx || {};
  const effectId = int(c.effectId, 0);
  const { userMon, targetMon } = c;
  const movePower = int(c.power, 0);
  const userSpeed = int(c.userSpeed, 0);
  const foeSpeed = int(c.foeSpeed, 0);

  if (effectId === 38) {
    if (userSpeed <= foeSpeed) return null;
    return Math.max(1, int(targetMon.hp, 0));
  }
  if (effectId === 40) {
    return Math.max(1, Math.floor(int(targetMon.hp, 0) / 2));
  }
  if (effectId === 41) {
    if (movePower >= 1) return movePower;
    return Math.max(1, int(userMon.level, 1));
  }
  return null;
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

// Gen 1 cartridge: Swift skips the invuln check; Thunder reaches Fly;
// Earthquake / Fissure miss Dig.
function hitsInvulnerable(chargeMoveId, attackerMove) {
  const charge = moveKey(chargeMoveId);
  const id = moveKey(attackerMove);
  if (id === 'SWIFT') return true;
  if (attackerMove && typeof attackerMove === 'object' && isSwift(attackerMove.effect)) {
    return true;
  }
  if (charge === 'FLY' && id === 'THUNDER') return true;
  return false;
}

function isTrapping(effectId) {
  return int(effectId, 0) === 42;
}

function trapTurns(rng) {
  return 2 + (rng ? rng.byte() : 0) % 4;
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

function jumpKickCrash(maxHp) {
  return Math.max(1, Math.floor(Math.max(1, int(maxHp, 1)) / 8));
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

function isPayDay(effectId) {
  return int(effectId, 0) === 16;
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
  applyPrimary,
  sideChanceProc,
  applySide,
  isMultihit,
  hitCount,
  isFixedDamage,
  isDrain,
  isRecoil,
  drainAmount,
  recoilAmount,
  fixedDamage,
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
  isPayDay,
  isMirrorMove,
  isMimic,
  isMetronome,
};
