'use strict';

/*
 * Gen2 move-effect ids and stat-stage multipliers (light port of Gen1 Effects).
 *
 * Behavior taxonomy mirroring the public pret jump-table order; not ROM bytes.
 * Hand-authored 87-slot table (indices 0..86), twin of src/BattleSim2/Effects.lua.
 * Sheet keys: atk/def/spe/spa/spd (Sp.Def).
 *
 * Phase 0: lookup + stage multipliers. Phase 1: primary stat/status handlers.
 * Phase 2: post-damage side-chance effects + flinch.
 * Phase 3: multi-hit, fixed damage, drain, recoil.
 * Phase 4: multi-turn charge, recharge, trap, thrash, rage.
 */

// For the burn / paralysis tail of `battleStat`, so the halving and the
// quartering are one rule with one owner rather than a second copy here.
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

// BattleCommand_Screen's `ld a, 5`: a Reflect or Light Screen counts five
// between-turn ticks (HandleScreens), the turn it went up included.
const SCREEN_TURNS = 5;

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

// Crystal / Gold sheets name effects EFFECT_* (moveEffectOrder), not the
// pret/pokered *_EFFECT tokens this table is numbered by.  `moveOf` stores
// `idOf(def.effect) || 0`, so an unmapped name becomes NO_ADDITIONAL_EFFECT
// and every 0-power status move says "But nothing happened".  That is why
// Leer / Hypnosis / Screech worked in engine 1v1 and failed in every
// BattleSim2 fight (2v2 co-op, mediated PvP, solo-on).
//
// Map every EFFECT_* that already has a handler onto that handler.  Gen 2
// only moves (Protect, Spikes, …) stay unmapped and still no-op honestly.
const GEN2_EFFECT_ID = {
  EFFECT_NORMAL_HIT: 0,
  EFFECT_SLEEP: 32,
  EFFECT_POISON_HIT: 2,
  EFFECT_LEECH_HIT: 3,
  EFFECT_BURN_HIT: 4,
  EFFECT_FREEZE_HIT: 5,
  EFFECT_PARALYZE_HIT: 6,
  EFFECT_SELFDESTRUCT: 7,
  EFFECT_DREAM_EATER: 8,
  EFFECT_MIRROR_MOVE: 9,
  EFFECT_ATTACK_UP: 10,
  EFFECT_DEFENSE_UP: 11,
  EFFECT_DEFENSE_CURL: 11,
  EFFECT_SPEED_UP: 12,
  EFFECT_SP_ATK_UP: 13,
  EFFECT_ACCURACY_UP: 14,
  EFFECT_EVASION_UP: 15,
  EFFECT_ALWAYS_HIT: 17,
  EFFECT_ATTACK_DOWN: 18,
  EFFECT_DEFENSE_DOWN: 19,
  EFFECT_SPEED_DOWN: 20,
  EFFECT_SP_ATK_DOWN: 21,
  EFFECT_ACCURACY_DOWN: 22,
  EFFECT_EVASION_DOWN: 23,
  EFFECT_CONVERSION: 24,
  EFFECT_RESET_STATS: 25,
  EFFECT_BIDE: 26,
  EFFECT_RAMPAGE: 27,
  EFFECT_FORCE_SWITCH: 28,
  EFFECT_MULTI_HIT: 29,
  EFFECT_FLINCH_HIT: 31,
  EFFECT_PAY_DAY: 16,
  EFFECT_OHKO: 38,
  EFFECT_RAZOR_WIND: 39,
  EFFECT_SOLARBEAM: 39,
  EFFECT_SKULL_BASH: 39,
  EFFECT_SKY_ATTACK: 39,
  EFFECT_SUPER_FANG: 40,
  EFFECT_STATIC_DAMAGE: 41,
  EFFECT_LEVEL_DAMAGE: 41,
  EFFECT_PSYWAVE: 41,
  EFFECT_TRAP_TARGET: 42,
  EFFECT_FLY: 43,
  EFFECT_DOUBLE_HIT: 44,
  EFFECT_JUMP_KICK: 45,
  EFFECT_MIST: 46,
  EFFECT_FOCUS_ENERGY: 47,
  EFFECT_RECOIL_HIT: 48,
  EFFECT_CONFUSE: 49,
  EFFECT_ATTACK_UP_2: 50,
  EFFECT_DEFENSE_UP_2: 51,
  EFFECT_SPEED_UP_2: 52,
  EFFECT_SP_ATK_UP_2: 53,
  EFFECT_ACCURACY_UP_2: 54,
  EFFECT_EVASION_UP_2: 55,
  EFFECT_HEAL: 56,
  EFFECT_MORNING_SUN: 56,
  EFFECT_SYNTHESIS: 56,
  EFFECT_MOONLIGHT: 56,
  EFFECT_TRANSFORM: 57,
  EFFECT_ATTACK_DOWN_2: 58,
  EFFECT_DEFENSE_DOWN_2: 59,
  EFFECT_SPEED_DOWN_2: 60,
  EFFECT_SP_ATK_DOWN_2: 61,
  EFFECT_ACCURACY_DOWN_2: 62,
  EFFECT_EVASION_DOWN_2: 63,
  EFFECT_LIGHT_SCREEN: 64,
  EFFECT_REFLECT: 65,
  EFFECT_POISON: 66,
  EFFECT_TOXIC: 66,
  EFFECT_PARALYZE: 67,
  EFFECT_ATTACK_DOWN_HIT: 68,
  EFFECT_DEFENSE_DOWN_HIT: 69,
  EFFECT_SPEED_DOWN_HIT: 70,
  EFFECT_SP_ATK_DOWN_HIT: 71,
  EFFECT_CONFUSE_HIT: 76,
  EFFECT_POISON_MULTI_HIT: 77,
  EFFECT_SUBSTITUTE: 79,
  EFFECT_HYPER_BEAM: 80,
  EFFECT_RAGE: 81,
  EFFECT_MIMIC: 82,
  EFFECT_METRONOME: 83,
  EFFECT_LEECH_SEED: 84,
  EFFECT_SPLASH: 85,
  EFFECT_DISABLE: 86,
};

function idOf(name) {
  if (typeof name !== 'string') return null;
  const hit = BY_NAME[name];
  if (hit !== undefined) return hit;
  const mapped = GEN2_EFFECT_ID[name];
  return mapped === undefined ? null : mapped;
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

// CalcBattleStats (pokecrystal engine/battle/effect_commands.asm:4817-4875):
// the unmodified stat times the stage's ratio from data/battle/
// stat_multipliers.asm, then a quotient of 0 is raised to 1 and one at or past
// MAX_STAT_VALUE is held at 999. The cart's ratios are num/den pairs (15/10,
// 2/1, 25/10 ...); each is the percent above over 100 exactly, so the floor
// lands on the same integer.
function applyStage(base, stage) {
  const value = Math.floor(Math.max(0, int(base, 0)) * stageMult(stage) / 100);
  if (value < 1) return 1;
  if (value > MAX_STAT_VALUE) return MAX_STAT_VALUE;
  return value;
}

// Crystal's badge rules, as gen1recomp ports them (src/battle/gen2/Battle.lua,
// the engine every number here was checked against). `badges` is a set of
// Gold badge ids -> true: the eight Johto ids and the eight Kanto ids that
// name the rows of the engine's BADGE_TYPE_BOOSTS (ZEPHYR ... RISING, BOULDER
// ... EARTH), which is what a Gold client uploads. Gen 1's BOULDERBADGE-style
// ids mean nothing here: Gold has no badge by that name.
//
// A fighter only holds a set where the cart would have applied it -- side a
// of a fight against the computer; Turn.attempt drops it in 1v1 / coop_pvp
// (link battles, where Crystal's BadgeStatBoosts returns early) and on side b
// (Turn.BADGE_MODES) -- so nothing below has to ask what kind of fight it is.

// BadgeStatBoosts (engine/battle/core.asm:6534; port Battle.lua:209-220,
// BADGE_STAT_BOOSTS): every other wJohtoBadges bit boosts a stat, walked
// after PlainBadge and MineralBadge swap places, which is what lands Mineral
// on Defense and Plain on Speed. Kanto badges boost no stat; Sp. Def has no
// badge of its own and is only ever reached by Glacier's buggy tail below.
const BADGE_FOR_STAT = {
  atk: 'ZEPHYR',
  def: 'MINERAL',
  spe: 'PLAIN',
  spa: 'GLACIER',
};

// MAX_STAT_VALUE, the ceiling BoostStat caps a boosted stat at.
const MAX_STAT_VALUE = 999;

// BoostStat (engine/battle/core.asm:6590; port Battle.lua:787-792):
// raise a stat by an eighth, capped at MAX_STAT_VALUE. The eighth is a plain
// shift, so a stat under 8 gains nothing.
function boostStat(value) {
  const v = Math.max(0, int(value, 0));
  return Math.min(MAX_STAT_VALUE, v + Math.floor(v / 8));
}

// BadgeStatBoosts' buggy tail (port Battle.lua:794-809, glacierBoostsSpDef):
// the closing Special Defense check does `srl a` assuming `a` still holds the
// badge bits, but when GlacierBadge fired for Special Attack the BoostStat
// before it overwrote `a` with its cap-check arithmetic. So with Glacier
// owned, whether Sp. Def is ALSO boosted turns on the boosted Sp. Atk:
//   * at or past the 999 cap `a` leaves as LOW(999) = $e7, odd: boosted;
//   * otherwise `a` is high(v) - 3 - borrow, the borrow set when low(v) <
//     LOW(999), and the bit shifted out of it decides.
// (pokegold's own comment marks the check buggy.) The byte wrap is spelled
// out because JS `%` keeps the sign; the Lua twin's floored `% 256` does not.
function glacierBoostsSpDef(boostedSpa) {
  const v = Math.max(0, int(boostedSpa, 0));
  if (v >= MAX_STAT_VALUE) return true;
  const borrow = (v % 256) < 231 ? 1 : 0;
  const a = (((Math.floor(v / 256) - 3 - borrow) % 256) + 256) % 256;
  return a % 2 === 1;
}

// One stat plus its owner's badge boost. `wireStatKey` is atk/def/spe/spa/
// spd. `spa` is the same monster's Sp. Atk as BadgeStatBoosts finds it --
// already staged, because CalcPlayerStats runs CalcBattleStats first -- and
// is read only for `spd`: it is what Glacier's tail is decided on.
function badgeBoost(statValue, wireStatKey, badges, spa) {
  const base = Math.max(0, int(statValue, 0));
  if (!badges || typeof badges !== 'object') return base;
  const badge = Object.prototype.hasOwnProperty.call(BADGE_FOR_STAT, wireStatKey)
    ? BADGE_FOR_STAT[wireStatKey] : undefined;
  if (badge) {
    if (badges[badge]) return boostStat(base);
    return base;
  }
  if (wireStatKey === 'spd' && badges.GLACIER
      && glacierBoostsSpDef(boostStat(spa))) {
    return boostStat(base);
  }
  return base;
}

// The stat a hit, the turn order or a confusion self-hit reads: the battle
// stat, rebuilt the way CalcPlayerStats does it (pokecrystal engine/battle/
// effect_commands.asm:4778-4797) --
//
//   1. CalcBattleStats: the unmodified stat x the stage ratio, 1..999
//      (`applyStage`);
//   2. BadgeStatBoosts (engine/battle/core.asm:6768): +1/8, held at 999, and
//      Glacier's Sp. Def tail reading the staged-then-boosted Sp. Atk;
//   3. ApplyPrzEffectOnSpeed / ApplyBrnEffectOnAttack (core.asm:6585-6669):
//      paralysis quarters Speed and burn halves Attack, each at least 1.
//
// Read-time rather than stored; the Lua twin's note says where the cart reads
// otherwise (a switch-in's status penalty runs before BadgeStatBoosts) and
// why that stays written down rather than modelled.
//
// `mon` is a sheet: { stats, stages, status }. `badges` is its seat's set
// (null for every seat the cart would not boost; see Turn.BADGE_MODES).
function battleStat(mon, key, badges) {
  const m = mon && typeof mon === 'object' ? mon : {};
  const stats = m.stats && typeof m.stats === 'object' ? m.stats : {};
  const stages = m.stages && typeof m.stages === 'object' ? m.stages : {};
  let value = applyStage(stats[key], stages[key]);
  let spa;
  if (key === 'spd') spa = applyStage(stats.spa, stages.spa);
  value = badgeBoost(value, key, badges, spa);
  if (key === 'atk' && m.status === 'burn') value = Status.burnAttack(value);
  if (key === 'spe' && m.status === 'paralysis') {
    value = Status.paralysisSpeed(value);
  }
  return value;
}

// DoBadgeTypeBoosts (pokecrystal engine/battle/misc.asm:146; port
// Battle.lua:835-848, badgeTypeBoost; rows from data/types/
// badge_type_boosts.asm in the cart's own walk order -- the eight wJohtoBadges
// bits, then the eight wKantoBadges bits). On the player's turn the move's
// type is looked up here, each type at most once, and owning that row's badge
// adds an eighth to the damage (Damage.compute's `badgeTypeBoost`). `type`
// is the type's registry id, which the ruleset's `typeIds` resolves a move's
// chart index to -- PSYCHIC_TYPE is Psychic's, because PSYCHIC is a move.
const BADGE_TYPE_BOOSTS = [
  { badge: 'ZEPHYR', type: 'FLYING' },
  { badge: 'HIVE', type: 'BUG' },
  { badge: 'PLAIN', type: 'NORMAL' },
  { badge: 'FOG', type: 'GHOST' },
  { badge: 'MINERAL', type: 'STEEL' },
  { badge: 'STORM', type: 'FIGHTING' },
  { badge: 'GLACIER', type: 'ICE' },
  { badge: 'RISING', type: 'DRAGON' },
  { badge: 'BOULDER', type: 'ROCK' },
  { badge: 'CASCADE', type: 'WATER' },
  { badge: 'THUNDER', type: 'ELECTRIC' },
  { badge: 'RAINBOW', type: 'GRASS' },
  { badge: 'SOUL', type: 'POISON' },
  { badge: 'MARSH', type: 'PSYCHIC_TYPE' },
  { badge: 'VOLCANO', type: 'FIRE' },
  { badge: 'EARTH', type: 'GROUND' },
];

// Whether a move of type `typeId` is boosted for a fighter holding `badges`.
// The first row naming the type answers, as the cart's scan does.
function badgeTypeBoost(typeId, badges) {
  if (!badges || typeof badges !== 'object' || typeof typeId !== 'string') return false;
  for (const row of BADGE_TYPE_BOOSTS) {
    if (row.type === typeId) return badges[row.badge] === true;
  }
  return false;
}

// ------------------------------------------------------------------
// Phase 1 primary handlers
// ------------------------------------------------------------------

const STAT_LABELS = {
  atk: 'ATTACK', def: 'DEFENSE', spe: 'SPEED',
  spa: 'SP.ATK', spd: 'SP.DEF', acc: 'ACCURACY', eva: 'EVASION',
};

// effect id -> { stat, delta, selfTarget }
const STAT_EFFECTS = {
  10: { stat: 'atk', delta: 1, selfTarget: true },
  11: { stat: 'def', delta: 1, selfTarget: true },
  12: { stat: 'spe', delta: 1, selfTarget: true },
  13: { stat: 'spa', delta: 1, selfTarget: true },
  14: { stat: 'acc', delta: 1, selfTarget: true },
  15: { stat: 'eva', delta: 1, selfTarget: true },
  18: { stat: 'atk', delta: -1, selfTarget: false },
  19: { stat: 'def', delta: -1, selfTarget: false },
  20: { stat: 'spe', delta: -1, selfTarget: false },
  21: { stat: 'spa', delta: -1, selfTarget: false },
  22: { stat: 'acc', delta: -1, selfTarget: false },
  23: { stat: 'eva', delta: -1, selfTarget: false },
  50: { stat: 'atk', delta: 2, selfTarget: true },
  51: { stat: 'def', delta: 2, selfTarget: true },
  52: { stat: 'spe', delta: 2, selfTarget: true },
  53: { stat: 'spa', delta: 2, selfTarget: true },
  54: { stat: 'acc', delta: 2, selfTarget: true },
  55: { stat: 'eva', delta: 2, selfTarget: true },
  58: { stat: 'atk', delta: -2, selfTarget: false },
  59: { stat: 'def', delta: -2, selfTarget: false },
  60: { stat: 'spe', delta: -2, selfTarget: false },
  61: { stat: 'spa', delta: -2, selfTarget: false },
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

function applyStatChange(out, fighter, mon, stat, delta) {
  if (delta < 0 && mon.mist) {
    out.messages.push('But it failed');
    return;
  }
  const label = STAT_LABELS[stat] || stat;
  const before = clampStage(mon.stages[stat]);
  const after = clampStage(before + delta);
  if (after === before) {
    if (delta > 0) {
      out.messages.push(`${mon.species}'s ${label} won't go any higher`);
    } else {
      out.messages.push(`${mon.species}'s ${label} won't go any lower`);
    }
    return;
  }
  mon.stages[stat] = after;
  const verb = delta > 0 ? 'rose' : 'fell';
  const text = `${mon.species}'s ${label} ${verb}`;
  out.messages.push(text);
  const fields = fighterFields(fighter);
  fields.amount = after;
  fields.text = text;
  out.events.push({ kind: 'stat', fields });
}

// Every stage back to 0. Haze, and the levels a monster leaves behind:
// pokecrystal keeps one set of stat levels per side (wPlayerStatLevels) and
// refills it on every send-out (ResetPlayerStatLevels, engine/battle/
// core.asm:3944), so a monster that switches in or faints brings no stage
// with it -- the referee keeps them per monster and clears them at those two
// points instead (Turn `_resolveSwitches` / `_faint`).
function resetStages(mon) {
  mon.stages.atk = 0;
  mon.stages.def = 0;
  mon.stages.spe = 0;
  mon.stages.spa = 0;
  mon.stages.spd = 0;
  mon.stages.acc = 0;
  mon.stages.eva = 0;
}

// BattleCommand_StatDown's `.ComputerMiss` byte (pokecrystal engine/battle/
// effect_commands.asm:4320-4440; pokegold the same but for Crystal's Battle
// Tower exemption, which no fight here is): `cp 25 percent + 1`, and RGBDS
// `percent` is `* $ff / 100` in integer arithmetic, so 63 + 1 -- the computer
// misses on a byte under 64.
const COMPUTER_DROP_MISS = 64;

// The stat a primary stat-down move lowers (ATTACK_DOWN ... EVASION_DOWN and
// the _2 rows), or null. The *DownHit side effects are SIDE_STAT_DOWN below.
function primaryStatDown(effectId) {
  const statFx = STAT_EFFECTS[int(effectId, -1)];
  if (statFx && statFx.delta < 0 && !statFx.selfTarget) return statFx.stat;
  return null;
}

// BattleCommand_StatDown up to `.DidntMiss`, the one routine a primary
// stat-down move (`attackdown` after `checkhit`) and a *DownHit side effect
// (`attackdown` after `buildopponentrage`) both run, in its order:
//
//   1. CheckMist: the target's SUBSTATUS_MIST -> `.Mist`;
//   2. the stage already at -6 (`dec b / jp z, .CantLower`) -> `.CantLower`
//      -- a -2 drop from -5 goes on, its `dec b / jr nz` / `inc b` stopping
//      it at -6;
//   3. `.ComputerMiss`: on the enemy's turn outside a link battle
//      (`computerMover`, Turn's isComputerSeat) a BattleRandom under
//      COMPUTER_DROP_MISS -> `.Failed`. The exemption it skips the byte for
//      -- EFFECT_ACCURACY_DOWN_HIT, the attacking moves that lower accuracy --
//      is not an effect this table maps (Gold's MUD-SLAP / OCTAZOOKA fold to
//      0, known gaps), and neither is Lock-On, so every stat-down move here
//      draws it.
//
// Nothing before the byte asks whether the move hit, whether a substitute
// stands or whether the side effect's chance landed: `checkhit` only set
// wAttackMissed, a substitute is CheckSubstituteOpp at `.DidntMiss`, and
// wEffectFailed is read after that -- so the computer draws it for a missed
// GROWL, for a hit into a substitute and for an AURORA BEAM whose chance
// byte failed alike. Returns 'mist', 'floor' or 'missed' for the step that
// stopped the drop, or null when it goes on to `.DidntMiss`.
function statDownGate(rng, targetMon, stat, computerMover) {
  if (targetMon.mist) return 'mist';
  if (clampStage(targetMon.stages[stat]) <= STAGE_MIN) return 'floor';
  if (computerMover && rng && rng.byte() < COMPUTER_DROP_MISS) return 'missed';
  return null;
}

// Cartridge Substitute blocks foe-targeting primaries (Sleep Powder, Growl,
// Disable, Transform, Mimic). Self-targeting (Recover, Swords Dance,
// Substitute) and field-wide Haze still run; Conversion copies onto the user.
// A stat-down move meets the substitute later, inside BattleCommand_StatDown
// (`applyPrimary` below), so it is not stopped here.
function blockedBySubstitute(effectId) {
  const statFx = STAT_EFFECTS[effectId];
  if (statFx) return false;
  if (effectId === 24 || effectId === 25 || effectId === 46 || effectId === 47
      || effectId === 56 || effectId === 64 || effectId === 65
      || effectId === 79 || effectId === 85) {
    return false;
  }
  return true;
}

// ctx: effectId, rng, userMon, targetMon, userFighter, targetFighter,
//      moveIndex (1-based), statusToWire, userScreens (the user's side's
//      screen counts; see LIGHT_SCREEN_EFFECT below), computerMover (the
//      move is the computer's: BattleCommand_StatDown's extra miss)
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
    resetStages(userMon);
    resetStages(targetMon);
    out.messages.push('All stat changes were eliminated');
    return out;
  }

  const statFx = STAT_EFFECTS[effectId];
  if (statFx) {
    const mon = statFx.selfTarget ? userMon : targetMon;
    const fighter = statFx.selfTarget ? userFighter : targetFighter;
    if (!statFx.selfTarget) {
      // BattleCommand_StatDown's own order (statDownGate): Mist and a stage
      // at -6 first -- applyStatChange says their lines, "But it failed" and
      // "won't go any lower", as before -- then the computer's byte, whose
      // miss is `.Failed` ("But it failed!", TryPrintButItFailed), and only
      // then the substitute (CheckSubstituteOpp at `.DidntMiss`).
      const stop = statDownGate(rng, mon, statFx.stat, c.computerMover === true);
      if (stop === 'missed') {
        out.messages.push('But it failed');
        return out;
      }
      if (stop === null && (mon.substitute || 0) > 0) {
        out.nothing = true;
        return out;
      }
    }
    applyStatChange(out, fighter, mon, statFx.stat, statFx.delta);
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

  // BattleCommand_Screen (pokecrystal engine/battle/effect_commands.asm:
  // 6147-6188): a screen belongs to the user's SIDE (wPlayerScreens), lasts
  // SCREEN_TURNS, and a second cast while it is up fails ("But it failed!")
  // rather than refreshing the count. `c.userScreens` is the side's
  // { lightScreen, reflect } turn counts (Turn's `this.screens[side]`), which
  // the between-turn tick counts down; nothing else ever clears them.
  if (effectId === 64 || effectId === 65) {
    const key = effectId === 64 ? 'lightScreen' : 'reflect';
    const screens = c.userScreens;
    if (!screens || typeof screens !== 'object' || int(screens[key], 0) > 0) {
      out.messages.push('But it failed');
      return out;
    }
    screens[key] = SCREEN_TURNS;
    out.messages.push(`${userMon.species}`
      + (effectId === 64 ? ' created a light screen' : ' created a reflect'));
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
    userMon.stats.atk = Math.max(1, int(targetMon.stats.atk, 1));
    userMon.stats.def = Math.max(1, int(targetMon.stats.def, 1));
    userMon.stats.spe = Math.max(1, int(targetMon.stats.spe, 1));
    userMon.stats.spa = Math.max(1, int(targetMon.stats.spa, 1));
    userMon.stats.spd = Math.max(1, int(targetMon.stats.spd, 1));
    userMon.types = targetMon.types.length ? [...targetMon.types] : [0];
    userMon.stages.atk = clampStage(targetMon.stages.atk);
    userMon.stages.def = clampStage(targetMon.stages.def);
    userMon.stages.spe = clampStage(targetMon.stages.spe);
    userMon.stages.spa = clampStage(targetMon.stages.spa);
    userMon.stages.spd = clampStage(targetMon.stages.spd);
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
    // BattleCommand_Transform copies the target's species into the battle
    // struct, which the Lucky Punch / Stick crit check reads; the party
    // species -- `speciesId`, untouched -- is what Light Ball, Thick Club and
    // Metal Powder read (Items.js).
    userMon.transformSpecies = targetMon.speciesId === undefined ? null : targetMon.speciesId;
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
  68: 'atk', 69: 'def', 70: 'spe', 71: 'spa',
};
const SIDE_POISON = { 2: true, 33: true, 77: true };
const SIDE_BURN = { 4: true, 34: true };
const SIDE_FREEZE = { 5: true, 35: true };
const SIDE_PARALYZE = { 6: true, 36: true };
const SIDE_FLINCH = { 31: true, 37: true };

const SIDE_TEXT = {
  poison: 'was poisoned', burn: 'was burned',
  freeze: 'was frozen solid', paralysis: 'is paralyzed',
};
const SIDE_TOKEN = { poison: 'PSN', burn: 'BRN', freeze: 'FRZ', paralysis: 'PAR' };

function inflict(out, fighter, mon, status, wire) {
  mon.status = status;
  const text = `${mon.species} ${SIDE_TEXT[status]}`;
  out.messages.push(text);
  const fields = fighterFields(fighter);
  fields.status = wire[status] || SIDE_TOKEN[status];
  fields.text = text;
  out.events.push({ kind: 'status', fields });
}

function hasType(mon, typeIndex) {
  if (typeIndex === null || typeIndex === undefined || !Array.isArray(mon.types)) return false;
  for (let i = 0; i < mon.types.length; i += 1) {
    if (mon.types[i] === typeIndex) return true;
  }
  return false;
}

// CheckMoveTypeMatchesTarget (effect_commands.asm:5909-5945, pokegold the
// same): the move's type against both of the target's, "unless the move is
// Normal (Tri Attack)" -- a NORMAL move never matches. `normalType` is
// NORMAL's chart index off the ruleset's typeIds; a fight that names no types
// compares the indices alone, which every burn and freeze move on the carts
// (none of them Normal) answers the same way.
function moveTypeMatchesTarget(targetMon, moveType, normalType) {
  if (moveType === null || moveType === undefined) return false;
  if (normalType !== null && normalType !== undefined && moveType === normalType) return false;
  return hasType(targetMon, moveType);
}

// The secondary effect of a damaging hit, run where every *Hit script runs it:
// after `checkfaint` (the caller never asks for a target the hit knocked out)
// and `buildopponentrage`, whether the hit reached the HP or a substitute took
// it -- `checkfaint` reads the monster's HP, not the doll's, so a hit into a
// substitute goes on to the effect command, and each routine asks about the
// substitute itself (CheckSubstituteOpp: the one standing NOW, so a hit that
// broke it is past it).
//
// ctx: effectId, hit, rng, targetMon, targetFighter, userFighter,
//      statusToWire, moveType (the move's chart index), poisonType /
//      normalType (POISON's and NORMAL's chart indices off the ruleset's
//      typeIds, null when it names none), computerMover (the move is the
//      computer's: BattleCommand_StatDown's extra miss), chance (only when
//      `hit` is absent).
// Returns { proc, messages, events }. `hit` is BattleCommand_EffectChance's
// verdict, drawn by the caller where the script's `effectchance` stands --
// false when a substitute stood at it (CheckSubstituteOpp, before the byte);
// absent, the byte is drawn here first. `rng` is also the computer's
// stat-down byte and the confusion side effect's turn count. Each routine
// below runs in pokecrystal's order (engine/battle/effect_commands.asm,
// diffed against pokegold); HELD_PREVENT_* (no item on either cart carries
// one, data/items/attributes.asm), SafeCheckSafeguard and FreezeTarget's
// WEATHER_SUN return are skipped because nothing here can set them.
function applySide(ctx) {
  const out = { proc: false, messages: [], events: [] };
  const c = ctx || {};
  const effectId = int(c.effectId, 0);
  const { rng, targetMon, targetFighter } = c;
  const wire = c.statusToWire || {};
  if (!targetMon || typeof targetMon !== 'object') return out;
  const behindSub = int(targetMon.substitute, 0) > 0;
  const moveType = int(c.moveType, null);

  let hit = c.hit;
  if (hit === undefined || hit === null) hit = !behindSub && sideChanceProc(rng, c.chance) === true;

  // BattleCommand_PoisonTarget (:3668-3700; Twineedle's `poisontarget` after
  // its loop is the same command): a substitute, any status, a POISON-type
  // target (CheckIfTargetIsPoisonType -- POISON alone, so a STEEL type a
  // non-Poison move reaches, Twineedle's BUG, is poisoned), and only then
  // wEffectFailed.
  if (SIDE_POISON[effectId]) {
    if (behindSub || hasMajorStatus(targetMon)) return out;
    if (hasType(targetMon, c.poisonType)) return out;
    if (!hit) return out;
    out.proc = true;
    inflict(out, targetFighter, targetMon, 'poison', wire);
    return out;
  }

  // BattleCommand_BurnTarget (:3930-3968): a substitute returns; a target
  // with any status jumps to Defrost (:3969-3993) BEFORE wEffectFailed is
  // read, so a frozen target is thawed by every burn-family hit that reaches
  // the command, its chance byte landed or not ("<TARGET> was defrosted!"),
  // and any other status ends it there; then a target sharing the move's type
  // (CheckMoveTypeMatchesTarget: don't burn a Fire type), then wEffectFailed.
  if (SIDE_BURN[effectId]) {
    if (behindSub) return out;
    if (hasMajorStatus(targetMon)) {
      if (targetMon.status === 'freeze') {
        targetMon.status = null;
        targetMon.statusTurns = 0;
        const text = `${targetMon.species} was defrosted`;
        out.messages.push(text);
        // No token: a `status` event without one is a cure (events.js).
        const fields = fighterFields(targetFighter);
        fields.text = text;
        out.events.push({ kind: 'status', fields });
        out.proc = true;
      }
      return out;
    }
    if (moveTypeMatchesTarget(targetMon, moveType, c.normalType)) return out;
    if (!hit) return out;
    out.proc = true;
    inflict(out, targetFighter, targetMon, 'burn', wire);
    return out;
  }

  // BattleCommand_FreezeTarget (:3994-4044): a substitute, any status, a
  // target sharing the move's type (don't freeze an Ice type), then
  // wEffectFailed.
  if (SIDE_FREEZE[effectId]) {
    if (behindSub || hasMajorStatus(targetMon)) return out;
    if (moveTypeMatchesTarget(targetMon, moveType, c.normalType)) return out;
    if (!hit) return out;
    out.proc = true;
    inflict(out, targetFighter, targetMon, 'freeze', wire);
    return out;
  }

  // BattleCommand_ParalyzeTarget (:4045-4078): a substitute, any status, then
  // wEffectFailed. No type check at all -- an ELECTRIC move paralyses an
  // Electric type and a NORMAL one a Normal type on both carts.
  if (SIDE_PARALYZE[effectId]) {
    if (behindSub || hasMajorStatus(targetMon)) return out;
    if (!hit) return out;
    out.proc = true;
    inflict(out, targetFighter, targetMon, 'paralysis', wire);
    return out;
  }

  // BattleCommand_FlinchTarget (:5357-5374): a substitute, then a sleeping or
  // frozen target (`and 1 << FRZ | SLP_MASK / ret nz`), then
  // CheckOpponentWentFirst, then wEffectFailed. The went-first test is not
  // asked here: a flag on a monster that has already moved is never read --
  // `_openTurn` clears it before that monster's next CheckTurn -- so it
  // changes nothing. Nor is EndRechargeOpp: a recharge the target owes this
  // turn was turned into its skip when the turn's choices were filled.
  if (SIDE_FLINCH[effectId]) {
    if (behindSub) return out;
    if (targetMon.status === 'sleep' || targetMon.status === 'freeze') return out;
    if (!hit) return out;
    out.proc = true;
    targetMon.flinch = true;
    return out;
  }

  // BattleCommand_StatDown, the routine the primary moves share
  // (statDownGate: Mist, -6, the computer's byte), then `.DidntMiss`: a
  // substitute, wEffectFailed and CheckHiddenOpponent, each `.Failed`. A *Hit
  // script has no `statdownfailtext` and `statdownmessage` speaks only when
  // wFailedMessage is 0, so every one of those fails silently -- no "But it
  // failed", no "won't go any lower".
  const stat = SIDE_STAT_DOWN[effectId];
  if (stat) {
    if (statDownGate(rng, targetMon, stat, c.computerMover === true)) return out;
    if (behindSub || !hit || targetMon.invulnerable) return out;
    out.proc = true;
    applyStatChange(out, targetFighter, targetMon, stat, -1);
    return out;
  }

  // BattleCommand_ConfuseTarget (:5732-5749): wEffectFailed, then a
  // substitute, then a target already confused, all before
  // FinishConfusingTarget draws the 2-5 turn byte.
  if (effectId === 76) {
    if (!hit || behindSub) return out;
    if (targetMon.confusion && targetMon.confusion > 0) return out;
    out.proc = true;
    confuse(out, targetFighter, targetMon, rng, false);
    return out;
  }

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

const FLY_DIG_EXCEPTIONS = {
  FLY: { GUST: true, WHIRLWIND: true, THUNDER: true, TWISTER: true },
  DIG: { EARTHQUAKE: true, FISSURE: true, MAGNITUDE: true },
};

function hitsInvulnerable(chargeMoveId, attackerMove) {
  const charge = moveKey(chargeMoveId);
  const id = moveKey(attackerMove);
  const reaches = FLY_DIG_EXCEPTIONS[charge];
  return !!(reaches && reaches[id]);
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

// ------------------------------------------------------------------
// move priority
// ------------------------------------------------------------------
//
// GetMovePriority (pokecrystal engine/battle/core.asm:829-850): Vital Throw
// answers 0 by its move id, every other move by its effect's row in
// data/moves/effects_priorities.asm, and a move with no row is BASE_PRIORITY
// (constants/battle_constants.asm: 1). DetermineMoveOrder compares the two
// numbers before anything else (CompareMovePriority), so a higher one moves
// first whatever the Speed.
//
// Keyed by the move ids that carry those effects (data/moves/moves.asm) rather
// than by effect; the Lua twin says why (no effect id in this table names any
// of the five, and EFFECT_FORCE_SWITCH shares 28 with Gen 1's Teleport row).
// The selected move's id is what is read, as the cart reads wCurPlayerMove.
const BASE_PRIORITY = 1;
const MOVE_PRIORITY = {
  PROTECT: 3, DETECT: 3, // EFFECT_PROTECT, 3
  ENDURE: 3, // EFFECT_ENDURE, 3
  QUICK_ATTACK: 2, MACH_PUNCH: 2, EXTREMESPEED: 2, // EFFECT_PRIORITY_HIT, 2
  WHIRLWIND: 0, ROAR: 0, // EFFECT_FORCE_SWITCH, 0
  COUNTER: 0, // EFFECT_COUNTER, 0
  MIRROR_COAT: 0, // EFFECT_MIRROR_COAT, 0
  VITAL_THROW: 0, // `cp VITAL_THROW / ld a, 0`
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
  BERRY: 10, BERRY_JUICE: 20,
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
  PSNCUREBERRY: { poison: true, toxic: true },
  PRZCUREBERRY: { paralysis: true },
  BURNT_BERRY: { freeze: true },
  ICE_BERRY: { burn: true },
  MINT_BERRY: { sleep: true },
  MIRACLEBERRY: {
    poison: true, toxic: true, burn: true,
    freeze: true, sleep: true, paralysis: true,
  },
};
const ITEM_X_STAGE = {
  X_ATTACK: 'atk', X_DEFEND: 'def', X_SPEED: 'spe', X_SPECIAL: 'spa',
};
const ITEM_VITAMIN = {
  HP_UP: 'hp', PROTEIN: 'atk', IRON: 'def', CARBOS: 'spe', CALCIUM: 'spa',
};
const VITAMIN_GAIN = 2560;
const VITAMIN_FAIL_AT = 25600;
const ITEM_BALL = {
  POKE_BALL: true, GREAT_BALL: true, ULTRA_BALL: true,
  MASTER_BALL: true, SAFARI_BALL: true,
  LEVEL_BALL: true, LURE_BALL: true, MOON_BALL: true, FRIEND_BALL: true,
  FAST_BALL: true, HEAVY_BALL: true, LOVE_BALL: true, PARK_BALL: true,
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
    if (!mon.stats) mon.stats = {};
    mon.stats[stat] = Math.max(1, int(mon.stats[stat], 1) + delta);
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
      spe: Math.max(1, int(mon.stats && mon.stats.spe, 1)),
      spa: Math.max(1, int(mon.stats && mon.stats.spa, 1)),
      spd: Math.max(1, int(mon.stats && mon.stats.spd, 1)),
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
  battleStat,
  resetStages,
  STAT_LABELS,
  SCREEN_TURNS,
  BASE_PRIORITY,
  MOVE_PRIORITY,
  movePriority,
  badgeBoost,
  boostStat,
  glacierBoostsSpDef,
  badgeTypeBoost,
  BADGE_FOR_STAT,
  BADGE_TYPE_BOOSTS,
  MAX_STAT_VALUE,
  isPhase1Primary,
  isPhase5Volatile,
  isPhase6Primary,
  handlesPrimary,
  hasMajorStatus,
  applyPrimary,
  COMPUTER_DROP_MISS,
  primaryStatDown,
  statDownGate,
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
  FLY_DIG_EXCEPTIONS,
  isTrapping,
  trapTurns,
  isHyperBeam,
  isThrash,
  thrashTurns,
  isRage,
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
