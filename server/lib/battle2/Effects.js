'use strict';

/*
 * Gen2 move-effect ids and stat-stage multipliers (light port of Gen1 Effects).
 *
 * Behavior taxonomy mirroring the public pret jump-table order; not ROM bytes.
 * Hand-authored 87-slot table (indices 0..86) that Gold's EFFECT_* names fold
 * onto where a Gen 1 handler is the cart's command, and after it the
 * Gold-native rows (87..MAX_EFFECT_ID) whose commands no Gen 1 id runs; twin of
 * src/BattleSim2/Effects.lua. Sheet keys: atk/def/spe/spa/spd (Sp.Def).
 *
 * Phase 0: lookup + stage multipliers. Phase 1: primary stat/status handlers.
 * Phase 2: post-damage side-chance effects + flinch.
 * Phase 3: multi-hit, fixed damage, drain, recoil.
 * Phase 4: multi-turn charge, recharge, trap, thrash, rage.
 */

// For the burn / paralysis tail of `battleStat`, so the halving and the
// quartering are one rule with one owner rather than a second copy here.
const Status = require('./Status.js');
// The HELD_PREVENT_* tokens the status commands ask about (Items.prevents).
const Items = require('./Items.js');

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
  // The Gold-native rows, each under the cart's own constant (pokecrystal
  // constants/move_effect_constants.asm, pokegold the same), the name a Gold
  // sheet's `def.effect` carries -- so `idOf` answers them off BY_NAME.
  'EFFECT_SP_DEF_DOWN_HIT', // 87: CRUNCH, PSYCHIC, SHADOW BALL
  'EFFECT_ACCURACY_DOWN_HIT', // 88: MUD-SLAP, OCTAZOOKA
  'EFFECT_ATTACK_UP_HIT', // 89: METAL CLAW
  'EFFECT_DEFENSE_UP_HIT', // 90: STEEL WING
  'EFFECT_ALL_UP_HIT', // 91: ANCIENTPOWER
  'EFFECT_FLAME_WHEEL', // 92
  'EFFECT_SACRED_FIRE', // 93
  'EFFECT_STOMP', // 94
  'EFFECT_TWISTER', // 95
  'EFFECT_SNORE', // 96
  'EFFECT_THUNDER', // 97
  'EFFECT_TRI_ATTACK', // 98
  'EFFECT_GUST', // 99
  'EFFECT_EARTHQUAKE', // 100
  'EFFECT_SKY_ATTACK', // 101
  // The referee-gaps run's wave 2 (R2b; the Lua twin explains).
  'EFFECT_SLEEP_TALK', // 102
  'EFFECT_LOCK_ON', // 103
  'EFFECT_SAFEGUARD', // 104
  'EFFECT_TOXIC', // 105
  // The referee-gaps run's wave 3 (R2c; the Lua twin names each command).
  'EFFECT_RETURN', // 106
  'EFFECT_FRUSTRATION', // 107
  'EFFECT_HIDDEN_POWER', // 108
  'EFFECT_REVERSAL', // 109
  'EFFECT_MAGNITUDE', // 110
  'EFFECT_PRESENT', // 111
  'EFFECT_TRIPLE_KICK', // 112
  'EFFECT_FURY_CUTTER', // 113
  'EFFECT_ROLLOUT', // 114
  'EFFECT_DEFENSE_CURL', // 115
  'EFFECT_BEAT_UP', // 116
  'EFFECT_PURSUIT', // 117
  'EFFECT_FALSE_SWIPE', // 118
  'EFFECT_FUTURE_SIGHT', // 119
  'EFFECT_PROTECT', // 120
  'EFFECT_ENDURE', // 121
  'EFFECT_COUNTER', // 122
  'EFFECT_MIRROR_COAT', // 123
  'EFFECT_RAIN_DANCE', // 124
  'EFFECT_SUNNY_DAY', // 125
  'EFFECT_SANDSTORM', // 126
  'EFFECT_SOLARBEAM', // 127
  'EFFECT_MORNING_SUN', // 128
  'EFFECT_SYNTHESIS', // 129
  'EFFECT_MOONLIGHT', // 130
  'EFFECT_LEVEL_DAMAGE', // 131
  'EFFECT_PSYWAVE', // 132
  // The referee-gaps run's wave 4 (R2d): the status and field scripts and
  // the SP. DEF stat rows (the Lua twin names each command).
  'EFFECT_ATTRACT', // 133
  'EFFECT_BATON_PASS', // 134
  'EFFECT_BELLY_DRUM', // 135
  'EFFECT_CONVERSION2', // 136
  'EFFECT_CURSE', // 137
  'EFFECT_DESTINY_BOND', // 138
  'EFFECT_ENCORE', // 139
  'EFFECT_FORESIGHT', // 140
  'EFFECT_HEAL_BELL', // 141
  'EFFECT_MEAN_LOOK', // 142
  'EFFECT_NIGHTMARE', // 143
  'EFFECT_PAIN_SPLIT', // 144
  'EFFECT_PERISH_SONG', // 145
  'EFFECT_PSYCH_UP', // 146
  'EFFECT_RAPID_SPIN', // 147
  'EFFECT_SKETCH', // 148
  'EFFECT_SPIKES', // 149
  'EFFECT_SPITE', // 150
  'EFFECT_SP_DEF_UP_2', // 151
  'EFFECT_SWAGGER', // 152
  'EFFECT_TELEPORT', // 153
  'EFFECT_SP_DEF_UP', // 154
  'EFFECT_SP_DEF_DOWN', // 155
  'EFFECT_SP_DEF_DOWN_2', // 156
  'EFFECT_SKULL_BASH', // 157
];

// The last id either table numbers. The wire carries a Gen 1/2 move's effect
// as a byte (Wire.battleMove, sanitize EFFECT_MAX), so this may grow to 255.
const MAX_EFFECT_ID = 157;

// The Gold-native ids by name, for the call sites that branch on one --
// and the shared rows whose command Gold rewrote (wave 5): CONVERSION and
// EFFECT_FORCE_SWITCH (ROAR, WHIRLWIND).
const CONVERSION = 24;
const FORCE_SWITCH = 28;
const SP_DEF_DOWN_HIT = 87;
const ACCURACY_DOWN_HIT = 88;
const ATTACK_UP_HIT = 89;
const DEFENSE_UP_HIT = 90;
const ALL_UP_HIT = 91;
const FLAME_WHEEL = 92;
const SACRED_FIRE = 93;
const STOMP = 94;
const TWISTER = 95;
const SNORE = 96;
const THUNDER = 97;
const TRI_ATTACK = 98;
const GUST = 99;
const EARTHQUAKE = 100;
const SKY_ATTACK = 101;
const SLEEP_TALK = 102;
const LOCK_ON = 103;
const SAFEGUARD = 104;
const TOXIC = 105;
const RETURN = 106;
const FRUSTRATION = 107;
const HIDDEN_POWER = 108;
const REVERSAL = 109;
const MAGNITUDE = 110;
const PRESENT = 111;
const TRIPLE_KICK = 112;
const FURY_CUTTER = 113;
const ROLLOUT = 114;
const DEFENSE_CURL = 115;
const BEAT_UP = 116;
const PURSUIT = 117;
const FALSE_SWIPE = 118;
const FUTURE_SIGHT = 119;
const PROTECT = 120;
const ENDURE = 121;
const COUNTER = 122;
const MIRROR_COAT = 123;
const RAIN_DANCE = 124;
const SUNNY_DAY = 125;
const SANDSTORM = 126;
const SOLARBEAM = 127;
const MORNING_SUN = 128;
const SYNTHESIS = 129;
const MOONLIGHT = 130;
const LEVEL_DAMAGE = 131;
const PSYWAVE = 132;
const ATTRACT = 133;
const BATON_PASS = 134;
const BELLY_DRUM = 135;
const CONVERSION2 = 136;
const CURSE = 137;
const DESTINY_BOND = 138;
const ENCORE = 139;
const FORESIGHT = 140;
const HEAL_BELL = 141;
const MEAN_LOOK = 142;
const NIGHTMARE = 143;
const PAIN_SPLIT = 144;
const PERISH_SONG = 145;
const PSYCH_UP = 146;
const RAPID_SPIN = 147;
const SKETCH = 148;
const SPIKES = 149;
const SPITE = 150;
const SP_DEF_UP_2 = 151;
const SWAGGER = 152;
const TELEPORT = 153;
const SP_DEF_UP = 154;
const SP_DEF_DOWN = 155;
const SP_DEF_DOWN_2 = 156;
const SKULL_BASH = 157;

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
  'status_side', 'status_side',
  'status_side', 'status_side', 'status_side',
  'status_side', 'status_side',
  'status_side', 'status_side', 'status_side',
  'status_side', 'status_side',
  'other', 'other',
  'charge',
  'meta', 'volatile', 'volatile',
  'status_primary',
  'other', 'other', 'other', 'fixed',
  'other', 'other', 'multihit', 'other',
  'other', 'stat', 'multihit', 'other',
  'other', 'other', 'volatile', 'volatile',
  'fixed', 'fixed', 'field', 'field',
  'field', 'charge', 'heal', 'heal',
  'heal', 'fixed', 'fixed',
  'volatile', 'flow', 'stat', 'meta',
  'stat', 'volatile', 'volatile', 'volatile',
  'heal', 'volatile', 'volatile', 'heal',
  'field', 'stat', 'other', 'meta',
  'field', 'volatile', 'stat', 'status_primary',
  'flow', 'stat', 'stat', 'stat',
  'charge',
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
// Map every EFFECT_* that already has a handler onto that handler. The
// Gold-native rows answer under their own names (BY_NAME), SKY ATTACK among
// them: its script is RazorWind's plus `effectchance` / `flinchtarget`, which
// CHARGE_EFFECT does not run. Gen 2 only moves (Spikes, …) stay unmapped and
// still no-op honestly. Wave 3 moved SOLARBEAM, LEVEL_DAMAGE, PSYWAVE, the
// three time-of-day heals and DEFENSE_CURL off these folds onto ids of their
// own (the Lua twin says why). Wave 4 moved SKULL BASH off 39 onto 157 and
// gave every status / field script a row of its own (133..156), BY_NAME's.
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
  EFFECT_SUPER_FANG: 40,
  EFFECT_STATIC_DAMAGE: 41,
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
// This is the cart's CalcPlayerStats; the three writers that use another
// order are `storedStat`'s (the Lua twin explains).
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

// ------------------------------------------------------------------
// the stored battle stats (docs/plans/gen12-referee-gaps-fix.md, R2b; the
// Lua twin carries the notes: "init" InitBattleMon / InitEnemyMon / the
// in-battle level-up, status before badge; "load" LoadEnemyMon, no status;
// Transform's copy; a snapshot stands while its inputs do)
// ------------------------------------------------------------------
const STAT_KEYS = ['atk', 'def', 'spe', 'spa', 'spd'];
const STAGE_KEYS = ['atk', 'def', 'spe', 'spa', 'spd', 'acc', 'eva'];

// From wave 4, the "pass" order (BATON PASS's PassedBattleMonEntrance, the
// Lua twin explains): InitBattleMon's status and badge, then the levels.
function orderedStat(mon, key, badges, order) {
  const stats = mon.stats && typeof mon.stats === 'object' ? mon.stats : {};
  const stages = mon.stages && typeof mon.stages === 'object' ? mon.stages : {};
  if (order === 'pass') {
    let base = Math.max(1, int(stats[key], 1));
    if (key === 'atk' && mon.status === 'burn') base = Status.burnAttack(base);
    if (key === 'spe' && mon.status === 'paralysis') base = Status.paralysisSpeed(base);
    base = badgeBoost(base, key, badges, stats.spa);
    return applyStage(base, stages[key]);
  }
  let value = applyStage(stats[key], stages[key]);
  if (order === 'load') return value;
  if (key === 'atk' && mon.status === 'burn') value = Status.burnAttack(value);
  if (key === 'spe' && mon.status === 'paralysis') value = Status.paralysisSpeed(value);
  let spa;
  if (key === 'spd') spa = applyStage(stats.spa, stages.spa);
  return badgeBoost(value, key, badges, spa);
}

// CalcMonStatC for one stat (the Lua twin explains): GetSquareRoot is the
// smallest root whose square is not below the stat exp, 255 at most.
function squareRoot(exp) {
  const e = Math.max(0, int(exp, 0));
  for (let b = 1; b <= 254; b += 1) {
    if (b * b >= e) return b;
  }
  return 255;
}

function monStat(base, dv, exp, level, hp) {
  let value = (Math.max(0, int(base, 0)) + Math.max(0, int(dv, 0))) * 2
    + Math.floor(squareRoot(exp) / 4);
  value = Math.floor((value * level) / 100);
  value += hp ? level + 10 : 5;
  if (value > MAX_STAT_VALUE) value = MAX_STAT_VALUE;
  return value;
}

// CalcMonStats over a Gold sheet's K7 blocks at `level`, or null without
// `base` and `dvs`.
function calcMonStats(base, dvs, statExp, level) {
  if (!base || typeof base !== 'object' || !dvs || typeof dvs !== 'object') return null;
  const exp = statExp && typeof statExp === 'object' ? statExp : {};
  const lv = Math.max(1, int(level, 1));
  const hpDv = (int(dvs.atk, 0) % 2) * 8 + (int(dvs.def, 0) % 2) * 4
    + (int(dvs.spe, 0) % 2) * 2 + (int(dvs.spc, 0) % 2);
  return {
    stats: {
      atk: monStat(base.atk, dvs.atk, exp.atk, lv, false),
      def: monStat(base.def, dvs.def, exp.def, lv, false),
      spe: monStat(base.spe, dvs.spe, exp.spe, lv, false),
      spa: monStat(base.spa, dvs.spc, exp.spc, lv, false),
      spd: monStat(base.spd, dvs.spc, exp.spc, lv, false),
    },
    maxHp: monStat(base.hp, hpDv, exp.hp, lv, true),
  };
}

// The five battle stats in `order` ('calc', 'init' or 'load').
function calcStats(mon, badges, order) {
  const out = {};
  for (const key of STAT_KEYS) {
    out[key] = order === 'calc' ? battleStat(mon, key, badges) : orderedStat(mon, key, badges, order);
  }
  return out;
}

// Record `values` as the monster's battle stats, with the inputs they stand on.
function snapStats(mon, badges, values) {
  const stats = mon.stats && typeof mon.stats === 'object' ? mon.stats : {};
  const stages = mon.stages && typeof mon.stages === 'object' ? mon.stages : {};
  const snap = {
    values: {}, stats: {}, stages: {}, status: mon.status, badges,
  };
  for (const key of STAT_KEYS) {
    snap.values[key] = values[key];
    snap.stats[key] = stats[key];
  }
  for (const key of STAGE_KEYS) snap.stages[key] = clampStage(stages[key]);
  mon.statSnap = snap;
}

function dropSnap(mon) {
  if (mon && typeof mon === 'object') mon.statSnap = null;
}

// Lua's nil and JS's null / undefined are one "absent".
const same = (x, y) => (x === undefined || x === null ? (y === undefined || y === null) : x === y);

function snapStands(snap, mon, badges) {
  if (!same(snap.status, mon.status) || !same(snap.badges, badges)) return false;
  const stats = mon.stats && typeof mon.stats === 'object' ? mon.stats : {};
  const stages = mon.stages && typeof mon.stages === 'object' ? mon.stages : {};
  for (const key of STAT_KEYS) {
    if (!same(snap.stats[key], stats[key])) return false;
  }
  for (const key of STAGE_KEYS) {
    if (snap.stages[key] !== clampStage(stages[key])) return false;
  }
  return true;
}

// The battle stat a hit, the turn order or RaiseStat's 999 test reads.
function storedStat(mon, key, badges) {
  if (!mon || typeof mon !== 'object') return battleStat(mon, key, badges);
  const snap = mon.statSnap;
  if (snap) {
    if (snapStands(snap, mon, badges)) return snap.values[key];
    mon.statSnap = null;
  }
  return battleStat(mon, key, badges);
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
  spa: 'SPCL.ATK', spd: 'SPCL.DEF', acc: 'ACCURACY', eva: 'EVASION',
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
  // Gold's SP. DEF rows (wave 4); AMNESIA is the Up2.
  151: { stat: 'spd', delta: 2, selfTarget: true },
  154: { stat: 'spd', delta: 1, selfTarget: true },
  155: { stat: 'spd', delta: -1, selfTarget: false },
  156: { stat: 'spd', delta: -2, selfTarget: false },
};

const PHASE1_PRIMARY = {
  10: true, 11: true, 12: true, 13: true, 14: true, 15: true,
  18: true, 19: true, 20: true, 21: true, 22: true, 23: true,
  25: true, 32: true, 49: true, 50: true, 51: true, 52: true,
  53: true, 54: true, 55: true, 56: true, 58: true, 59: true,
  60: true, 61: true, 62: true, 63: true, 66: true, 67: true,
  84: true, 85: true, 86: true,
  103: true, 104: true, 105: true, // LOCK_ON, SAFEGUARD, TOXIC
  115: true, // DEFENSE_CURL
  // Wave 4: the status scripts on the user and its target alone (the Lua
  // twin names them).
  133: true, 135: true, 137: true, 138: true, 140: true,
  142: true, 143: true, 146: true, 150: true, 151: true,
  152: true, 154: true, 155: true, 156: true,
};

// The 0-power Gold scripts Turn runs itself (PROTECT / ENDURE, the weather
// moves, the time-of-day heals; from wave 4 BATON PASS, HEAL BELL, PERISH
// SONG, SKETCH, SPIKES and TELEPORT); none runs `checkhit`.
const FIELD_MOVES = {
  120: true, 121: true, 124: true, 125: true, 126: true,
  128: true, 129: true, 130: true,
  134: true, 141: true, 145: true, 148: true, 149: true,
  153: true,
  // Wave 5: Gold's CONVERSION (`_conversion`).
  24: true,
};

// The `checkhit` scripts whose command Turn runs after it (wave 4):
// CONVERSION2, ENCORE, PAIN SPLIT; from wave 5 ROAR / WHIRLWIND's
// ForceSwitch.
const TURN_COMMANDS = { 28: true, 136: true, 139: true, 144: true };

// The commands that read wAttackMissed themselves and say their own failure
// line (the Lua twin lists them).
const READS_MISS = {
  28: true, 32: true, 49: true, 66: true, 67: true, 82: true, 84: true,
  86: true, 103: true, 105: true, 133: true, 136: true,
  139: true, 140: true, 144: true, 150: true, 152: true,
};

// The referee-numbered move scripts with no `checkhit` (the Lua twin lists
// them): none of them spends the target's LOCK-ON.
const NO_CHECKHIT = {
  9: true, 10: true, 11: true, 12: true, 13: true, 14: true,
  15: true, 24: true, 25: true, 26: true, 46: true, 47: true,
  50: true, 51: true, 52: true, 53: true, 54: true, 55: true,
  56: true, 57: true, 64: true, 65: true, 79: true, 83: true,
  85: true, 102: true, 104: true,
  115: true, 119: true, 120: true, 121: true, 122: true,
  123: true, 124: true, 125: true, 126: true, 128: true,
  129: true, 130: true,
  134: true, 135: true, 137: true, 138: true, 141: true,
  142: true, 143: true, 145: true, 146: true, 148: true,
  149: true, 151: true, 153: true, 154: true,
};

// CheckHit's `.LockOn`: a locked-on target in the sky is still missed by these.
const LOCK_ON_SKY_MISS = { EARTHQUAKE: true, FISSURE: true, MAGNITUDE: true };

// SLEEP TALK's `.check_two_turn_move`: the effects it never calls (SKULL
// BASH's 157 from wave 4).
const SLEEP_TALK_EXCLUDED = {
  26: true, 39: true, 43: true, 101: true, 127: true,
  157: true,
};

// The scripts with `checksafeguard` after their `checkhit`.
const CHECKS_SAFEGUARD = {
  32: true, 49: true, 66: true, 67: true, 105: true,
};

function isPhase1Primary(effectId) {
  const n = int(effectId, null);
  if (n === null) return false;
  return PHASE1_PRIMARY[n] === true;
}

const PHASE5_VOLATILE = {
  46: true, 47: true, 57: true,
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

// Whether a monster has the type a chart index names (null names none).
function hasType(mon, typeIndex) {
  if (typeIndex === null || typeIndex === undefined || !Array.isArray(mon.types)) return false;
  return mon.types.includes(typeIndex);
}

// PrintDidntAffect's line (DidntAffect1Text), a status command's own failure.
function didntAffectLine(mon) {
  return `It didn't affect ${mon.species}!`;
}

// BattleCommand_Safeguard's `ld a, 5`.
const SAFEGUARD_TURNS = 5;

// BattleCommand_Transform's `.pp_loop`: 5 PP a copied move (SKETCH 1).
const TRANSFORM_PP = 5;

// BattleCommand_Mimic's `ld [hl], 5`.
const MIMIC_PP = 5;

// BattleCommand_Heal's REST: REST_SLEEP_TURNS + 1.
const REST_SLEEP_COUNT = 3;

// BattleCommand_BellyDrum's AttackUp2s after the first.
const BELLY_DRUM_CLIMB = 5;

// One move row copied whole (K8's `priority` and `ppUps` with it), the shape
// MIMIC puts aside (`preMimic`) and Red's twin keeps.
function copyMoveRow(m) {
  return {
    id: m.id || 'move',
    name: m.name,
    pp: Math.max(0, int(m.pp, 0)),
    maxPp: m.maxPp,
    power: Math.max(0, int(m.power, 0)),
    accuracy: Math.max(0, int(m.accuracy, 255)),
    type: Math.max(0, int(m.type, 0)),
    effect: Math.max(0, int(m.effect, 0)),
    chance: Math.max(0, int(m.chance, 0)),
    highCrit: m.highCrit === true,
    priority: m.priority,
    ppUps: m.ppUps,
    basePp: m.basePp,
  };
}

// A move's base PP, as SKETCH copies it (the Lua twin explains): the smallest
// base whose PP Ups (floor(base / 5), held at 7, each) reach the row's max.
// A MIMIC / TRANSFORM copy states the base it was copied from (wave 5).
function basePp(move) {
  const stated = (move.basePp === null || move.basePp === undefined)
    ? null : int(move.basePp, null);
  if (stated !== null && stated >= 0) return stated;
  const top = Math.max(0, int(move.maxPp, int(move.pp, 0)));
  const ups = int(move.ppUps, 0);
  if (ups <= 0) return top;
  for (let base = 1; base <= top; base += 1) {
    if (base + ups * Math.min(7, Math.floor(base / 5)) === top) return base;
  }
  return top;
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
  const text = `${mon.species} became confused!`;
  out.messages.push(text);
  const fields = fighterFields(fighter);
  fields.confused = 1;
  fields.text = text;
  out.events.push({ kind: 'status', fields });
}

// The stored battle stats as they stand now (`storedStat` for each).
function currentStats(mon, badges) {
  const out = {};
  for (const key of STAT_KEYS) out[key] = storedStat(mon, key, badges);
  return out;
}

// A status written the way the cart writes one outside a stat rebuild (the
// Lua twin explains): the byte changes, the battle stats stay -- but for the
// penalty a landing burn or paralysis puts on the stat it finds.
function setStatus(mon, badges, status) {
  const values = currentStats(mon, badges);
  mon.status = status;
  if (status === 'burn') values.atk = Status.burnAttack(values.atk);
  if (status === 'paralysis') values.spe = Status.paralysisSpeed(values.spe);
  snapStats(mon, badges, values);
}

// `setStatus` on a monster whose seat is `fighter` (its badges).
function setStatusOn(mon, fighter, status) {
  setStatus(mon, fighter ? fighter.badges : null, status);
}

// A stage written the way RaiseStat's `.stats_already_max` writes it: the
// level moves and no CalcPlayerStats follows, so the battle stats stay.
function setStageKeep(mon, badges, stat, stage) {
  const values = currentStats(mon, badges);
  mon.stages[stat] = stage;
  snapStats(mon, badges, values);
}

// What a sentence calls a held item (Items.label's rule).
function itemLabel(mon) {
  return mon.itemName || mon.heldItem || 'ITEM';
}

// The `stat` event for a stage that moved: `amount` as it always rode and the
// signed `stage` beside it (contract K10).
// StatUpMessage / StatDownMessage in Gen 2's words (wave 5; the Lua twin
// cites them): "went up!" / "went way up!" (a +2 command), "fell!" /
// "sharply fell!".
function statUpLine(mon, stat, delta) {
  return `${mon.species}'s ${STAT_LABELS[stat] || stat}${int(delta, 1) >= 2 ? ' went way up!' : ' went up!'}`;
}
function statDownLine(mon, stat, delta) {
  return `${mon.species}'s ${STAT_LABELS[stat] || stat}${int(delta, -1) <= -2 ? ' sharply fell!' : ' fell!'}`;
}

function statEvent(out, fighter, stage, text) {
  const fields = fighterFields(fighter);
  fields.amount = stage;
  fields.stage = stage;
  fields.text = text;
  out.events.push({ kind: 'stat', fields });
}

// One stage written and announced: the battle stats are rebuilt (the
// snapshot drops) and the line is StatUpMessage / StatDownMessage's.
function applyStatChange(out, fighter, mon, stat, delta) {
  const before = clampStage(mon.stages[stat]);
  const after = clampStage(before + delta);
  mon.stages[stat] = after;
  dropSnap(mon);
  const text = delta > 0 ? statUpLine(mon, stat, delta) : statDownLine(mon, stat, delta);
  out.messages.push(text);
  statEvent(out, fighter, after, text);
  return true;
}

// Every stage back to 0. Haze, and the levels a monster leaves behind:
// pokecrystal keeps one set of stat levels per side (wPlayerStatLevels) and
// refills it on every send-out (ResetPlayerStatLevels, engine/battle/
// core.asm:3944), so a monster that switches in or faints brings no stage
// with it -- the referee keeps them per monster and clears them at those two
// points instead (Turn `_resolveSwitches` / `_faint`). Haze rebuilds the
// battle stats, so the snapshot goes with them.
function resetStages(mon) {
  mon.stages.atk = 0;
  mon.stages.def = 0;
  mon.stages.spe = 0;
  mon.stages.spa = 0;
  mon.stages.spd = 0;
  mon.stages.acc = 0;
  mon.stages.eva = 0;
  dropSnap(mon);
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

// BattleCommand_StatDown up to `.DidntMiss` (the Lua twin carries the
// notes): Mist, the stage at -6, then the computer's byte -- skipped while the
// target is still locked on (`lockedOn`) and for ACCURACY_DOWN_HIT. Returns
// 'mist', 'floor' or 'missed' for the step that stopped the drop, or null.
function statDownGate(rng, targetMon, stat, computerMover, effectId, lockedOn) {
  if (targetMon.mist) return 'mist';
  if (clampStage(targetMon.stages[stat]) <= STAGE_MIN) return 'floor';
  if (computerMover && !lockedOn && int(effectId, 0) !== ACCURACY_DOWN_HIT
      && rng && rng.byte() < COMPUTER_DROP_MISS) {
    return 'missed';
  }
  return null;
}

// TryLowerStat's floor: the battle stat is already 1 (not acc / eva).
function statAtFloor(mon, stat, badges) {
  if (stat === 'acc' || stat === 'eva') return false;
  return storedStat(mon, stat, badges) <= 1;
}

// StatDownFailText / StatUpFailText's lines (data/text/battle.asm).
function mistLine(mon) {
  return `${mon.species}'s protected by MIST.`;
}
function wontDropLine(mon, stat) {
  return `${mon.species}'s ${STAT_LABELS[stat] || stat} won't drop anymore!`;
}
function wontRiseLine(mon, stat) {
  return `${mon.species}'s ${STAT_LABELS[stat] || stat} won't rise anymore!`;
}

// The line a primary stat-down move ends on when its `checkhit` missed.
function statDownMissLine(targetMon, stat) {
  if (targetMon.mist) return mistLine(targetMon);
  if (clampStage(targetMon.stages[stat]) <= STAGE_MIN) return wontDropLine(targetMon, stat);
  return 'But it failed!';
}

// No generic substitute gate (wave 4): every Gold status command asks the
// substitute itself, where its own code puts the check (the Lua twin lists
// them).

// The cart's failure lines: FailMove / PrintButItFailed, PrintDidntAffect(2).
function butItFailed(out) {
  out.messages.push('But it failed!');
  return out;
}
function didntAffect(out, targetMon) {
  out.messages.push(didntAffectLine(targetMon));
  return out;
}
// FailMove / FailMimic: "But it failed!", or "It failed!" while the target
// is PROTECTing (FailText_CheckOpponentProtect).
// AttackMissedText, a move's miss line (wave 5).
function missLine(userMon) {
  return `${userMon.species}'s attack missed!`;
}

function failMoveLine(targetMon) {
  if (targetMon && targetMon.protect) return 'It failed!';
  return 'But it failed!';
}
function failMove(out, targetMon) {
  out.messages.push(failMoveLine(targetMon));
  return out;
}

// `.CheckAIRandomFail` and its inlined twins in Poison / Paralyze (the Lua
// twin cites them): the computer's seat, the target not locked on, one byte
// under 64 fails.
function aiRandomFail(c, targetMon) {
  if (!c.computerMover || targetMon.lockOn) return false;
  return Boolean(c.rng) && c.rng.byte() < COMPUTER_DROP_MISS;
}

// RaiseStat with none of its messages (the Lua twin explains). Returns
// { raised, stage }.
function raiseStat(mon, badges, stat, delta) {
  const before = clampStage(mon.stages[stat]);
  if (before >= STAGE_MAX) return { raised: false, stage: before };
  let after = Math.min(STAGE_MAX, before + delta);
  if (stat !== 'acc' && stat !== 'eva'
      && storedStat(mon, stat, badges) >= MAX_STAT_VALUE) {
    after -= 1;
    if (after !== before) setStageKeep(mon, badges, stat, after);
    return { raised: false, stage: after };
  }
  mon.stages[stat] = after;
  dropSnap(mon);
  return { raised: true, stage: after };
}

// GetGender for CheckOppositeGender (the Lua twin explains): the Attack and
// Speed DVs as a byte against the species' BASE_GENDER (`base.gender`,
// proposed K15), the monster's own under Transform. 'M', 'F' or null.
const GENDER_F0 = 0;
const GENDER_F100 = 254;
const GENDER_UNKNOWN = 255;
function gender(mon) {
  if (!mon || !mon.base || typeof mon.base !== 'object') return null;
  const ratio = int(mon.base.gender, null);
  if (ratio === null) return null;
  let dvs = mon.dvs;
  if (mon.preTransform) dvs = mon.preTransform.dvs;
  if (!dvs || typeof dvs !== 'object') return null;
  if (ratio === GENDER_UNKNOWN) return null;
  if (ratio === GENDER_F0) return 'M';
  if (ratio === GENDER_F100) return 'F';
  const byte = (int(dvs.atk, 0) % 16) * 16 + int(dvs.spe, 0) % 16;
  if (ratio < byte) return 'M';
  return 'F';
}

// The HELD_PREVENT_* item's line ("<TARGET>'s protected by <ITEM>!").
function protectedBy(out, targetMon) {
  out.messages.push(`${targetMon.species}'s protected by ${itemLabel(targetMon)}!`);
  return out;
}

// RaiseStat for a primary stat-up move (the Lua twin carries the notes):
// +6 fails, a battle stat at MAX_STAT_VALUE puts ONE level back with no
// rebuild, both "won't rise anymore!". Returns whether the stat rose.
function raisePrimary(out, fighter, mon, stat, delta) {
  const before = clampStage(mon.stages[stat]);
  const r = raiseStat(mon, fighter ? fighter.badges : null, stat, delta);
  if (r.raised) {
    const text = statUpLine(mon, stat, delta);
    out.messages.push(text);
    statEvent(out, fighter, r.stage, text);
    return true;
  }
  const text = wontRiseLine(mon, stat);
  if (r.stage !== before) statEvent(out, fighter, r.stage, text);
  out.messages.push(text);
  return false;
}

// BattleCommand_StatDown and its lines for a primary stat-down move that hit.
function lowerPrimary(out, c, fighter, mon, stat, delta) {
  const stop = statDownGate(c.rng, mon, stat, c.computerMover === true,
    c.effectId, mon.lockOn === true);
  if (stop === 'mist') {
    out.messages.push(mistLine(mon));
    return out;
  }
  if (stop === 'floor') {
    out.messages.push(wontDropLine(mon, stat));
    return out;
  }
  if (stop === 'missed' || int(mon.substitute, 0) > 0) {
    out.messages.push('But it failed!');
    return out;
  }
  if (statAtFloor(mon, stat, fighter ? fighter.badges : null)) {
    out.messages.push(wontDropLine(mon, stat));
    return out;
  }
  applyStatChange(out, fighter, mon, stat, delta);
  return out;
}

// ctx: effectId, rng, userMon, targetMon, userFighter, targetFighter,
//      moveIndex (1-based), statusToWire, userScreens, computerMover,
//      moveKey, moveImmune, poisonType / grassType, fieldMons; from wave 4
//      missed, ghostType, targetSafeguard (the Lua twin describes each, and
//      the result's `selfDamage`, `trailing`, `failureText` and
//      `targetMovesChanged`).
function applyPrimary(ctx) {
  const out = {
    nothing: false, messages: [], events: [], heals: [], costs: [],
    directDamage: [], trailing: [],
  };
  const c = ctx || {};
  const effectId = int(c.effectId, 0);
  const {
    userMon, targetMon, userFighter, targetFighter, rng,
  } = c;
  const wire = c.statusToWire || {};
  const targetBadges = targetFighter ? targetFighter.badges : null;

  if (effectId === 85) {
    out.nothing = true;
    return out;
  }

  // BattleCommand_Heal (the Lua twin cites it): "HP is full!" at full HP;
  // REST sleeps the user (REST_SLEEP_COUNT, toxic gone, stats rebuilt) and
  // restores the whole max HP, the rest GetHalfMaxHP; "regained health!".
  if (effectId === 56) {
    const maxHp = Math.max(1, int(userMon.maxHp, 1));
    if (userMon.hp >= maxHp) {
      out.messages.push(`${userMon.species}'s HP is full!`);
      return out;
    }
    let amount = Math.max(1, Math.floor(maxHp / 2));
    if (c.moveKey === 'REST') {
      const had = Boolean(userMon.status);
      userMon.status = 'sleep';
      userMon.statusTurns = REST_SLEEP_COUNT;
      // `res SUBSTATUS_TOXIC`: the bit with no PSN too (wave 5).
      userMon.toxicLatent = null;
      dropSnap(userMon);
      const text = `${userMon.species}`
        + (had ? ' fell asleep and became healthy!' : ' went to sleep!');
      out.messages.push(text);
      const fields = fighterFields(userFighter);
      fields.status = wire.sleep || 'SLP';
      fields.text = text;
      out.events.push({ kind: 'status', fields });
      amount = maxHp;
    }
    out.heals.push({ amount });
    out.trailing.push(`${userMon.species} regained health!`);
    return out;
  }

  // BattleCommand_ResetStats: every monster on the field, all four in a 2v2.
  if (effectId === 25) {
    const field = Array.isArray(c.fieldMons) ? c.fieldMons : [userMon, targetMon];
    for (const mon of field) resetStages(mon);
    out.messages.push('All stat changes were eliminated!');
    return out;
  }

  // DefenseCurl's script: `defenseup`, then BattleCommand_Curl whatever the
  // raise did (ROLLOUT's extra doubling reads SUBSTATUS_CURLED).
  if (effectId === DEFENSE_CURL) {
    raisePrimary(out, userFighter, userMon, 'def', 1);
    userMon.curled = true;
    return out;
  }

  const statFx = STAT_EFFECTS[effectId];
  if (statFx) {
    if (statFx.selfTarget) {
      const raised = raisePrimary(out, userFighter, userMon, statFx.stat, statFx.delta);
      // MinimizeDropSub: wPlayerMinimized / wEnemyMinimized, what STOMP's
      // doubleminimizedamage reads. A send-out clears it.
      if (raised && c.moveKey === 'MINIMIZE') userMon.minimized = true;
      return out;
    }
    return lowerPrimary(out, c, targetFighter, targetMon, statFx.stat, statFx.delta);
  }

  // BattleCommand_SleepTarget, in its order (the Lua twin cites it):
  // HELD_PREVENT_SLEEP, already asleep, wAttackMissed, the computer's byte,
  // any other status, a substitute.
  if (effectId === 32) {
    if (Items.prevents(targetMon, 'sleep')) return protectedBy(out, targetMon);
    if (targetMon.status === 'sleep') {
      out.messages.push(`${targetMon.species}'s already asleep!`);
      return out;
    }
    if (c.missed || aiRandomFail(c, targetMon) || hasMajorStatus(targetMon)
        || int(targetMon.substitute, 0) > 0) {
      return didntAffect(out, targetMon);
    }
    // `.random_loop`: BattleRandom & SLP_MASK, drawn again on 0 and 7, plus 1:
    // a counter of 2..7 (1..6 turns asleep).
    let turns = 0;
    for (let i = 0; i < REDRAW_LIMIT; i += 1) {
      const r = (rng ? rng.byte() : 0) % 8;
      if (r !== 0 && r !== 7) { turns = r + 1; break; }
    }
    if (turns === 0) turns = 2;
    setStatus(targetMon, targetBadges, 'sleep');
    targetMon.statusTurns = turns;
    const token = wire.sleep || 'SLP';
    const text = `${targetMon.species} fell asleep!`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  // BattleCommand_Poison, POISONPOWDER's and TOXIC's one command.
  if (effectId === 66 || effectId === TOXIC) {
    if (c.moveImmune || hasType(targetMon, c.poisonType)) {
      out.messages.push(`It doesn't affect ${targetMon.species}!`);
      return out;
    }
    if (targetMon.status === 'poison' || targetMon.status === 'toxic') {
      out.messages.push(`${targetMon.species}'s already poisoned!`);
      return out;
    }
    if (Items.prevents(targetMon, 'poison')) return protectedBy(out, targetMon);
    // Any other status, the computer's byte, a substitute, wAttackMissed.
    if (hasMajorStatus(targetMon) || aiRandomFail(c, targetMon)
        || int(targetMon.substitute, 0) > 0 || c.missed) {
      return didntAffect(out, targetMon);
    }
    const toxic = effectId === TOXIC;
    setStatus(targetMon, targetBadges, toxic ? 'toxic' : 'poison');
    let text;
    if (toxic) {
      targetMon.toxicCounter = 1;
      // The bit a HEAL BELL / BATON PASS left is the status's now.
      targetMon.toxicLatent = null;
      text = `${targetMon.species}'s badly poisoned!`;
    } else {
      text = `${targetMon.species} was poisoned!`;
    }
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = toxic ? (wire.toxic || 'TOX') : (wire.poison || 'PSN');
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  // BattleCommand_Paralyze: already paralyzed, a matchup of 0, the item,
  // then the computer's byte, any other status, wAttackMissed, a substitute.
  if (effectId === 67) {
    if (targetMon.status === 'paralysis') {
      out.messages.push(`${targetMon.species}'s already paralyzed!`);
      return out;
    }
    if (c.moveImmune) {
      out.messages.push(`It doesn't affect ${targetMon.species}!`);
      return out;
    }
    if (Items.prevents(targetMon, 'paralysis')) return protectedBy(out, targetMon);
    if (aiRandomFail(c, targetMon) || hasMajorStatus(targetMon) || c.missed
        || int(targetMon.substitute, 0) > 0) {
      return didntAffect(out, targetMon);
    }
    setStatus(targetMon, targetBadges, 'paralysis');
    const token = wire.paralysis || 'PAR';
    const text = `${targetMon.species}'s paralyzed! Maybe it can't attack!`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  // BattleCommand_Confuse: the item, already confused, then a substitute or
  // wAttackMissed (PrintDidntAffect2).
  if (effectId === 49) {
    if (Items.prevents(targetMon, 'confusion')) return protectedBy(out, targetMon);
    if ((targetMon.confusion || 0) > 0) {
      out.messages.push(`${targetMon.species}'s already confused!`);
      return out;
    }
    if (int(targetMon.substitute, 0) > 0 || c.missed) return didntAffect(out, targetMon);
    confuse(out, targetFighter, targetMon, rng, true);
    return out;
  }

  // BattleCommand_LeechSeed: wAttackMissed or a substitute ("evaded the
  // attack!"), a Grass type, one already seeded ("evaded" again).
  if (effectId === 84) {
    const evaded = `${targetMon.species} evaded the attack!`;
    if (c.missed || int(targetMon.substitute, 0) > 0) {
      out.messages.push(evaded);
      return out;
    }
    if (hasType(targetMon, c.grassType)) {
      out.messages.push(`It doesn't affect ${targetMon.species}!`);
      return out;
    }
    if (targetMon.leechSeed) {
      out.messages.push(evaded);
      return out;
    }
    targetMon.leechSeed = { fromSlot: userFighter.slot };
    const text = `${targetMon.species} was seeded!`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  // BattleCommand_Disable (the Lua twin cites it): wAttackMissed, a count
  // running, no LAST_COUNTER_MOVE or STRUGGLE, a slot whose raw PP byte is 0
  // -- "But it failed!"; else `.loop2`'s 2..8 count.
  if (effectId === 86) {
    const last = targetMon.lastCounterMove;
    const running = targetMon.disable && int(targetMon.disable.turns, 0) > 0;
    if (c.missed || running || !last || moveKey(last) === 'STRUGGLE') {
      return failMove(out, targetMon);
    }
    let index = null;
    for (let i = 1; i <= targetMon.moves.length; i += 1) {
      if (moveKey(targetMon.moves[i - 1]) === moveKey(last)) { index = i; break; }
    }
    const slotMove = index !== null ? targetMon.moves[index - 1] : null;
    if (!slotMove || (int(slotMove.pp, 0) <= 0 && int(slotMove.ppUps, 0) <= 0)) {
      return failMove(out, targetMon);
    }
    let count = 0;
    for (let i = 0; i < REDRAW_LIMIT; i += 1) {
      const r = (rng ? rng.byte() : 0) % 8;
      if (r !== 0) { count = r + 1; break; }
    }
    if (count === 0) count = 2;
    targetMon.disable = { moveIndex: index, turns: count };
    out.messages.push(`${targetMon.species}'s ${moveLabel(slotMove)} was DISABLED!`);
    return out;
  }

  // BattleCommand_Substitute (the Lua twin cites it, wave 5's lines): one up
  // already, the HP not above a quarter, else the doll and the user's wrap
  // released.
  if (effectId === 79) {
    const cost = Math.floor(Math.max(1, int(userMon.maxHp, 1)) / 4);
    if (userMon.substitute && userMon.substitute > 0) {
      out.messages.push(`${userMon.species} has a SUBSTITUTE!`);
      return out;
    }
    if (userMon.hp <= cost) {
      out.messages.push('Too weak to make a SUBSTITUTE!');
      return out;
    }
    userMon.hp -= cost;
    userMon.substitute = cost;
    userMon.trapped = null;
    out.directDamage = [{ amount: cost }];
    out.messages.push(`${userMon.species} made a SUBSTITUTE!`);
    return out;
  }

  // BattleCommand_Screen (pokecrystal engine/battle/effect_commands.asm:
  // 6147-6188): a screen belongs to the user's SIDE (wPlayerScreens), lasts
  // SCREEN_TURNS, and a second cast while it is up fails ("But it failed!")
  // rather than refreshing the count. `c.userScreens` is the side's
  // { lightScreen, reflect, safeguard } turn counts (Turn's
  // `this.screens[side]`), which the between-turn ticks count down.
  if (effectId === 64 || effectId === 65) {
    const key = effectId === 64 ? 'lightScreen' : 'reflect';
    const screens = c.userScreens;
    if (!screens || typeof screens !== 'object' || int(screens[key], 0) > 0) {
      out.messages.push('But it failed!');
      return out;
    }
    screens[key] = SCREEN_TURNS;
    // LightScreenEffectText / ReflectEffectText (wave 5).
    out.messages.push(`${userMon.species}`
      + (effectId === 64 ? "'s SPCL.DEF rose!" : "'s DEFENSE rose!"));
    return out;
  }

  // BattleCommand_Safeguard: the user's SIDE for five ticks.
  if (effectId === SAFEGUARD) {
    const screens = c.userScreens;
    if (!screens || typeof screens !== 'object' || int(screens.safeguard, 0) > 0) {
      out.messages.push('But it failed!');
      return out;
    }
    screens.safeguard = SAFEGUARD_TURNS;
    out.messages.push(`${userMon.species}'s covered by a veil!`);
    return out;
  }

  // BattleCommand_LockOn: a substitute, then wAttackMissed, fail it, else
  // the TARGET is locked on.
  if (effectId === LOCK_ON) {
    if (int(targetMon.substitute, 0) > 0 || c.missed) return didntAffect(out, targetMon);
    targetMon.lockOn = true;
    out.messages.push(`${userMon.species} took aim!`);
    return out;
  }

  // BattleCommand_Mist / _FocusEnergy (wave 5): the bit already set fails.
  if (effectId === 46) {
    if (userMon.mist) return butItFailed(out);
    userMon.mist = true;
    out.messages.push(`${userMon.species}'s shrouded in MIST!`);
    return out;
  }

  if (effectId === 47) {
    if (userMon.focusEnergy) return butItFailed(out);
    userMon.focusEnergy = true;
    out.messages.push(`${userMon.species}'s getting pumped!`);
    return out;
  }

  // BattleCommand_Mimic (the Lua twin cites it): ClearLastMove; wAttackMissed,
  // a hidden target, no LAST_COUNTER_MOVE or STRUGGLE, a move the user knows
  // -- "But it failed!"; the copy with 5 PP into the slot holding MIMIC, the
  // untransformed user's party row put aside (`preMimic`, 1-based slot).
  if (effectId === 82) {
    userMon.lastCounterMove = null;
    userMon.lastMove = null;
    out.clearLastMove = true;
    const last = targetMon.lastCounterMove;
    if (c.missed || targetMon.invulnerable || !last || moveKey(last) === 'STRUGGLE') {
      return failMove(out, targetMon);
    }
    const key = moveKey(last);
    let slot = null;
    for (let i = 1; i <= userMon.moves.length; i += 1) {
      if (moveKey(userMon.moves[i - 1]) === key) return failMove(out, targetMon);
    }
    // `cp MIMIC` by id, or a modded move with Mimic's own command.
    for (let i = userMon.moves.length; i >= 1; i -= 1) {
      const m = userMon.moves[i - 1];
      if (moveKey(m) === 'MIMIC' || int(m.effect, 0) === 82) { slot = i; break; }
    }
    if (slot === null) return failMove(out, targetMon);
    if (!userMon.transformed) {
      userMon.preMimic = userMon.preMimic || {};
      if (!userMon.preMimic[slot]) userMon.preMimic[slot] = copyMoveRow(userMon.moves[slot - 1]);
    }
    const copy = copyMoveRow(last);
    copy.basePp = basePp(last);
    copy.pp = MIMIC_PP;
    copy.maxPp = MIMIC_PP;
    copy.ppUps = undefined;
    userMon.moves[slot - 1] = copy;
    out.messages.push(`${userMon.species} learned ${moveLabel(last)}!`);
    out.movesChanged = true;
    return out;
  }

  // BattleCommand_Transform (the Lua twin carries the notes): ClearLastMove,
  // "But it failed!" against a transformed or hidden target, no substitute
  // asked; the copy with 5 PP a move (SKETCH 1), the DVs, the unmodified
  // stats, the target's battle stats as they stand, the types and the
  // levels; what the user was kept in `preTransform`.
  if (effectId === 57) {
    userMon.lastCounterMove = null;
    userMon.lastMove = null;
    out.clearLastMove = true;
    if (targetMon.transformed || targetMon.invulnerable) {
      out.messages.push('But it failed!');
      return out;
    }
    if (!userMon.preTransform) {
      userMon.preTransform = {
        stats: userMon.stats, types: userMon.types,
        moves: userMon.moves.slice(), dvs: userMon.dvs,
      };
    }
    const battleStats = currentStats(targetMon, targetBadges);
    userMon.stats = {
      atk: Math.max(1, int(targetMon.stats.atk, 1)),
      def: Math.max(1, int(targetMon.stats.def, 1)),
      spe: Math.max(1, int(targetMon.stats.spe, 1)),
      spa: Math.max(1, int(targetMon.stats.spa, 1)),
      spd: Math.max(1, int(targetMon.stats.spd, 1)),
    };
    userMon.types = targetMon.types.length ? [...targetMon.types] : [0];
    userMon.stages.atk = clampStage(targetMon.stages.atk);
    userMon.stages.def = clampStage(targetMon.stages.def);
    userMon.stages.spe = clampStage(targetMon.stages.spe);
    userMon.stages.spa = clampStage(targetMon.stages.spa);
    userMon.stages.spd = clampStage(targetMon.stages.spd);
    userMon.stages.acc = clampStage(targetMon.stages.acc);
    userMon.stages.eva = clampStage(targetMon.stages.eva);
    userMon.dvs = targetMon.dvs && typeof targetMon.dvs === 'object'
      ? { ...targetMon.dvs } : undefined;
    userMon.moves = targetMon.moves.map((m) => {
      const pp = moveKey(m) === 'SKETCH' ? 1 : TRANSFORM_PP;
      return {
        id: m.id || 'move',
        name: m.name,
        pp,
        maxPp: pp,
        power: Math.max(0, int(m.power, 0)),
        accuracy: Math.max(0, int(m.accuracy, 255)),
        type: Math.max(0, int(m.type, 0)),
        effect: Math.max(0, int(m.effect, 0)),
        chance: Math.max(0, int(m.chance, 0)),
        highCrit: m.highCrit === true,
        priority: m.priority,
        // SKETCH's base PP for the copy (wave 5).
        basePp: basePp(m),
      };
    });
    userMon.transformed = true;
    userMon.disable = null;
    // BattleCommand_Transform copies the target's species into the battle
    // struct, which the Lucky Punch / Stick crit check reads; the party
    // species -- `speciesId`, untouched -- is what Light Ball, Thick Club and
    // Metal Powder read (Items.js).
    userMon.transformSpecies = targetMon.speciesId === undefined ? null : targetMon.speciesId;
    // ...and the copied species' base stats (K7), BEAT UP's target Defense.
    userMon.transformBase = targetMon.transformBase || targetMon.base || null;
    snapStats(userMon, userFighter ? userFighter.badges : null, battleStats);
    out.messages.push(`${userMon.species} TRANSFORMED into ${targetMon.species}!`);
    out.movesChanged = true;
    return out;
  }

  // BattleCommand_Attract (the Lua twin cites it): wAttackMissed, the
  // genders (`gender`), a hidden target, one already in love -- "But it
  // failed!"; else in love with the user's seat.
  if (effectId === ATTRACT) {
    const mine = gender(userMon);
    const theirs = gender(targetMon);
    if (c.missed || !mine || !theirs || mine === theirs
        || targetMon.invulnerable || targetMon.inLove) {
      return failMove(out, targetMon);
    }
    targetMon.inLove = { fromSlot: userFighter ? userFighter.slot : null };
    out.messages.push(`${targetMon.species} fell in love!`);
    return out;
  }

  // BattleCommand_BellyDrum, the cart's bug kept (the Lua twin explains):
  // AttackUp2 first, then the HP check keeping the two stages, then the half
  // off the HP and five more AttackUp2s.
  if (effectId === BELLY_DRUM) {
    const badges = userFighter ? userFighter.badges : null;
    const before = clampStage(userMon.stages.atk);
    const first = raiseStat(userMon, badges, 'atk', 2);
    let after = first.stage;
    const half = Math.max(1, Math.floor(Math.max(1, int(userMon.maxHp, 1)) / 2));
    if (!first.raised || userMon.hp <= half) {
      if (after !== before) statEvent(out, userFighter, after, undefined);
      return butItFailed(out);
    }
    out.selfDamage = half;
    for (let i = 0; i < BELLY_DRUM_CLIMB; i += 1) {
      const r = raiseStat(userMon, badges, 'atk', 2);
      after = r.stage;
      if (!r.raised) break;
    }
    const text = `${userMon.species} cut its HP and maximized ATTACK!`;
    statEvent(out, userFighter, after, text);
    out.trailing.push(text);
    return out;
  }

  // BattleCommand_Curse (the Lua twin cites it): a GHOST user curses the
  // target for half its own max HP; any other trades a Speed stage (whose
  // TryLowerStat rebuilds the OPPONENT's battle stats) for Attack and Defense.
  if (effectId === CURSE) {
    if (hasType(userMon, c.ghostType)) {
      if (targetMon.invulnerable || int(targetMon.substitute, 0) > 0 || targetMon.cursed) {
        return butItFailed(out);
      }
      targetMon.cursed = true;
      out.selfDamage = Math.max(1, Math.floor(Math.max(1, int(userMon.maxHp, 1)) / 2));
      out.trailing.push(`${userMon.species} cut its own HP and put a CURSE on ${targetMon.species}!`);
      return out;
    }
    if (clampStage(userMon.stages.atk) >= STAGE_MAX
        && clampStage(userMon.stages.def) >= STAGE_MAX) {
      out.messages.push(`${userMon.species}'s ABILITY won't rise anymore!`);
      return out;
    }
    const badges = userFighter ? userFighter.badges : null;
    const speed = clampStage(userMon.stages.spe);
    if (speed > STAGE_MIN && storedStat(userMon, 'spe', badges) > 1) {
      userMon.stages.spe = speed - 1;
      dropSnap(targetMon);
      dropSnap(userMon);
      const text = statDownLine(userMon, 'spe', -1);
      out.messages.push(text);
      statEvent(out, userFighter, speed - 1, text);
    }
    for (const stat of ['atk', 'def']) {
      const r = raiseStat(userMon, badges, stat, 1);
      if (r.raised) {
        const text = statUpLine(userMon, stat, 1);
        out.messages.push(text);
        statEvent(out, userFighter, r.stage, text);
      }
    }
    return out;
  }

  // BattleCommand_DestinyBond: no check at all.
  if (effectId === DESTINY_BOND) {
    userMon.destinyBond = true;
    out.messages.push(`${userMon.species}'s trying to take its opponent with it!`);
    return out;
  }

  // BattleCommand_Foresight: wAttackMissed, a hidden target, one identified.
  if (effectId === FORESIGHT) {
    if (c.missed || targetMon.invulnerable || targetMon.identified) return failMove(out, targetMon);
    targetMon.identified = true;
    out.messages.push(`${userMon.species} identified ${targetMon.species}!`);
    return out;
  }

  // BattleCommand_ArenaTrap: a hidden target, a user already holding a foe.
  if (effectId === MEAN_LOOK) {
    if (targetMon.invulnerable || userMon.meanLook) return butItFailed(out);
    userMon.meanLook = { slot: targetFighter ? targetFighter.slot : null };
    out.messages.push(`${targetMon.species} can't escape now!`);
    return out;
  }

  // BattleCommand_Nightmare: hidden, a substitute, awake, already one.
  if (effectId === NIGHTMARE) {
    if (targetMon.invulnerable || int(targetMon.substitute, 0) > 0
        || targetMon.status !== 'sleep' || targetMon.nightmare) {
      return butItFailed(out);
    }
    targetMon.nightmare = true;
    out.messages.push(`${targetMon.species} started to have a NIGHTMARE!`);
    return out;
  }

  // BattleCommand_PsychUp: a target at every base level fails; else the
  // levels copied and the user's stats rebuilt.
  if (effectId === PSYCH_UP) {
    let any = false;
    for (const key of STAGE_KEYS) {
      if (clampStage(targetMon.stages[key]) !== 0) any = true;
    }
    if (!any) return butItFailed(out);
    for (const key of STAGE_KEYS) userMon.stages[key] = clampStage(targetMon.stages[key]);
    dropSnap(userMon);
    out.messages.push(`${userMon.species} copied the stat changes of ${targetMon.species}!`);
    return out;
  }

  // BattleCommand_Spite: wAttackMissed, no LAST_COUNTER_MOVE or STRUGGLE, a
  // slot with no PP -- PrintDidntAffect2; else 2..5 PP off it.
  if (effectId === SPITE) {
    const last = targetMon.lastCounterMove;
    if (c.missed || !last || moveKey(last) === 'STRUGGLE') return didntAffect(out, targetMon);
    let slotMove = null;
    for (const m of targetMon.moves) {
      if (moveKey(m) === moveKey(last)) { slotMove = m; break; }
    }
    if (!slotMove || int(slotMove.pp, 0) <= 0) return didntAffect(out, targetMon);
    let amount = (rng ? rng.byte() : 0) % 4 + 2;
    if (slotMove.pp < amount) amount = slotMove.pp;
    slotMove.pp -= amount;
    out.targetMovesChanged = true;
    out.messages.push(`${targetMon.species}'s ${moveLabel(slotMove)} was reduced by ${amount}!`);
    return out;
  }

  // SWAGGER: attackup2 on the target, whose failure (+6, 999) is the
  // script's `failuretext` (no confusion); else `confusetarget`, silent on
  // the item, the target's SAFEGUARD, a substitute and a confusion.
  if (effectId === SWAGGER) {
    if (c.missed) {
      out.failureText = true;
      return out;
    }
    const before = clampStage(targetMon.stages.atk);
    const r = raiseStat(targetMon, targetBadges, 'atk', 2);
    if (!r.raised) {
      if (r.stage !== before) statEvent(out, targetFighter, r.stage, undefined);
      out.failureText = true;
      return out;
    }
    const text = statUpLine(targetMon, 'atk', 2);
    out.messages.push(text);
    statEvent(out, targetFighter, r.stage, text);
    if (Items.prevents(targetMon, 'confusion') || c.targetSafeguard
        || int(targetMon.substitute, 0) > 0 || int(targetMon.confusion, 0) > 0) {
      return out;
    }
    confuse(out, targetFighter, targetMon, rng, false);
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
// chance 100 is byte < 255 (always except the 1/256 roll of 255). Draws
// nothing at chance 0 -- the cart's `effectchance` does (effectChance), so
// the turn machine draws through that one.
function sideChanceProc(rng, chance) {
  let c = Math.max(0, Math.min(100, int(chance, 0)));
  if (c <= 0) return false;
  const threshold = Math.floor(c * 255 / 100);
  if (threshold <= 0) return false;
  return rng && rng.byte() < threshold;
}

// BattleCommand_EffectChance (pokecrystal engine/battle/effect_commands.asm:
// 1851-1874, pokegold the same): a substitute standing (CheckSubstituteOpp)
// fails it before any byte; otherwise BattleRandom is drawn WHATEVER the
// chance -- 0 included, which then never lands -- and lands under the move's
// chance byte (floor(pct * 255 / 100); the 1/256 miss of a 100% move kept).
// Returns whether wEffectFailed stayed clear.
function effectChance(rng, chance, behindSub) {
  if (behindSub) return false;
  const pct = Math.max(0, Math.min(100, int(chance, 0)));
  const byte = rng ? rng.byte() : 255;
  return byte < Math.floor(pct * 255 / 100);
}

// The scripts that run `effectchance` right after `checkhit` (the Lua twin
// lists them): the byte is drawn on a miss too. Id 0 draws only for a damaging
// move that states a chance -- THIEF, whose `thief` has no Gen 1 id.
const EFFECT_CHANCE_SCRIPTS = {
  2: true, 4: true, 5: true, 6: true, 31: true,
  33: true, 34: true, 35: true, 36: true, 37: true,
  68: true, 69: true, 70: true, 71: true, 76: true, 77: true,
  87: true, 88: true, 89: true, 90: true, 91: true,
  92: true, 93: true, 94: true, 95: true, 96: true, 97: true,
  100: true, 101: true,
};

function drawsEffectChance(effectId, move) {
  const id = int(effectId, 0);
  if (EFFECT_CHANCE_SCRIPTS[id]) return true;
  if (id !== 0 || !move || typeof move !== 'object') return false;
  return int(move.power, 0) > 0 && int(move.chance, 0) > 0;
}

const SIDE_STAT_DOWN = {
  68: 'atk', 69: 'def', 70: 'spe', 71: 'spa',
  87: 'spd', 88: 'acc',
};
// The *UpHit scripts' raises, on the USER (BattleCommand_AttackUp /
// DefenseUp, and AllStatsUp's five in its order).
const SIDE_STAT_UP = {
  89: ['atk'],
  90: ['def'],
  91: ['atk', 'def', 'spe', 'spa', 'spd'],
};
const SIDE_POISON = { 2: true, 33: true, 77: true };
const SIDE_BURN = { 4: true, 34: true, 92: true, 93: true };
const SIDE_FREEZE = { 5: true, 35: true };
const SIDE_PARALYZE = { 6: true, 36: true, 97: true };
const SIDE_FLINCH = {
  31: true, 37: true, 94: true, 95: true, 96: true, 101: true,
};

const SIDE_TEXT = {
  poison: ' was poisoned!', burn: ' was burned!',
  freeze: ' was frozen solid!', paralysis: "'s paralyzed! Maybe it can't attack!",
};
const SIDE_TOKEN = { poison: 'PSN', burn: 'BRN', freeze: 'FRZ', paralysis: 'PAR' };

// The status lands the way the cart writes it (`setStatus`), on the target's
// seat's badges.
function inflict(out, fighter, mon, status, wire) {
  setStatusOn(mon, fighter, status);
  const text = `${mon.species}${SIDE_TEXT[status]}`;
  out.messages.push(text);
  const fields = fighterFields(fighter);
  fields.status = wire[status] || SIDE_TOKEN[status];
  fields.text = text;
  out.events.push({ kind: 'status', fields });
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

// The status commands, one function each because TRI ATTACK's
// `tristatuschance` jumps into whichever its byte names. `s` is the side
// state applySide builds: target, fighter, wire, behindSub, moveType,
// normalType, poisonType, safeguard (the target's side has SAFEGUARD up).
// Each command also asks the target's HELD_PREVENT_* item just ahead of
// wEffectFailed; all of these stop silently.

// BattleCommand_PoisonTarget (:3668-3700): a substitute, any status, a
// POISON-type target (CheckIfTargetIsPoisonType -- POISON alone),
// HELD_PREVENT_POISON, wEffectFailed, then Safeguard.
function poisonTarget(out, s, hit) {
  if (s.behindSub || hasMajorStatus(s.target)) return;
  if (hasType(s.target, s.poisonType)) return;
  if (Items.prevents(s.target, 'poison')) return;
  if (!hit || s.safeguard) return;
  out.proc = true;
  inflict(out, s.fighter, s.target, 'poison', s.wire);
}

// BattleCommand_BurnTarget (:3930-3968): a substitute returns; a target with
// any status jumps to Defrost (:3969-3993) BEFORE wEffectFailed is read, so a
// frozen target is thawed by every burn-family hit that reaches the command,
// its chance byte landed or not, and any other status ends it there; then a
// target sharing the move's type, HELD_PREVENT_BURN, wEffectFailed, then
// Safeguard. Defrost writes the status byte with no rebuild (`setStatus`).
function burnTarget(out, s, hit) {
  if (s.behindSub) return;
  const targetMon = s.target;
  if (hasMajorStatus(targetMon)) {
    if (targetMon.status === 'freeze') {
      setStatusOn(targetMon, s.fighter, null);
      targetMon.statusTurns = 0;
      const text = `${targetMon.species} was defrosted!`;
      out.messages.push(text);
      // No token: a `status` event without one is a cure (events.js).
      const fields = fighterFields(s.fighter);
      fields.text = text;
      out.events.push({ kind: 'status', fields });
      out.proc = true;
    }
    return;
  }
  if (moveTypeMatchesTarget(targetMon, s.moveType, s.normalType)) return;
  if (Items.prevents(targetMon, 'burn')) return;
  if (!hit || s.safeguard) return;
  out.proc = true;
  inflict(out, s.fighter, targetMon, 'burn', s.wire);
}

// BattleCommand_FreezeTarget (:3994-4044): a substitute, any status, a
// target sharing the move's type, HELD_PREVENT_FREEZE, wEffectFailed, then
// Safeguard. A landed freeze's tail is Turn's `_applySide`.
function freezeTarget(out, s, hit) {
  if (s.behindSub || hasMajorStatus(s.target)) return;
  // `cp WEATHER_SUN / ret z`: nothing freezes under SUNNY DAY (wave 3).
  if (s.sunny) return;
  if (moveTypeMatchesTarget(s.target, s.moveType, s.normalType)) return;
  if (Items.prevents(s.target, 'freeze')) return;
  if (!hit || s.safeguard) return;
  out.proc = true;
  inflict(out, s.fighter, s.target, 'freeze', s.wire);
}

// BattleCommand_ParalyzeTarget (:4045-4078): a substitute, any status,
// HELD_PREVENT_PARALYZE, wEffectFailed, then Safeguard. No type check at all.
function paralyzeTarget(out, s, hit) {
  if (s.behindSub || hasMajorStatus(s.target)) return;
  if (Items.prevents(s.target, 'paralysis')) return;
  if (!hit || s.safeguard) return;
  out.proc = true;
  inflict(out, s.fighter, s.target, 'paralysis', s.wire);
}

// Guard on TRI ATTACK's `.loop`; the Lua twin says why.
const REDRAW_LIMIT = 1024;

// BattleCommand_TriStatusChance (:4730-4746): its own `effectchance`, then
// `.loop` -- BattleRandom, `swap a`, `and %11`, 0 drawn again -- WHATEVER
// effectchance said: 1 is ParalyzeTarget, 2 FreezeTarget, 3 BurnTarget.
function triStatusChance(out, s, rng, chance) {
  const hit = effectChance(rng, chance, s.behindSub);
  let pick = 0;
  for (let i = 0; i < REDRAW_LIMIT; i += 1) {
    pick = Math.floor((rng ? rng.byte() : 0) / 16) % 4;
    if (pick !== 0) break;
  }
  if (pick === 0) pick = 1;
  if (pick === 1) {
    paralyzeTarget(out, s, hit);
  } else if (pick === 2) {
    freezeTarget(out, s, hit);
  } else {
    burnTarget(out, s, hit);
  }
}

// RaiseStat (:4142-4231) for the *UpHit side effects: wEffectFailed, a stage
// already at +6, and -- for a stat that is not accuracy or evasion -- the
// stored battle stat already at MAX_STAT_VALUE all fail it, silently.
// Returns whether the stage moved.
function raiseSideStat(out, fighter, mon, stat, hit, badges) {
  if (!hit) return false;
  const before = clampStage(mon.stages[stat]);
  if (before >= STAGE_MAX) return false;
  if (stat !== 'acc' && stat !== 'eva'
      && storedStat(mon, stat, badges) >= MAX_STAT_VALUE) {
    return false;
  }
  return applyStatChange(out, fighter, mon, stat, 1);
}

// The secondary effect of a damaging hit, run where every *Hit script runs it:
// after `checkfaint` and `buildopponentrage`, whether the hit reached the HP
// or a substitute took it; each routine asks about the substitute standing
// NOW (CheckSubstituteOpp).
//
// ctx: effectId, hit, rng, targetMon, targetFighter, userMon, userFighter,
//      userBadges, statusToWire, moveType, poisonType / normalType,
//      computerMover, chance (TRI ATTACK's and DEFENSE_DOWN_HIT's own bytes,
//      and the byte drawn here when `hit` is absent), targetSafeguard.
// Returns { proc, messages, events }. The Lua twin carries the long notes.
function applySide(ctx) {
  const out = { proc: false, messages: [], events: [] };
  const c = ctx || {};
  const effectId = int(c.effectId, 0);
  const { rng, targetMon, targetFighter } = c;
  if (!targetMon || typeof targetMon !== 'object') return out;
  const behindSub = int(targetMon.substitute, 0) > 0;
  const s = {
    target: targetMon,
    fighter: targetFighter,
    wire: c.statusToWire || {},
    behindSub,
    moveType: int(c.moveType, null),
    normalType: c.normalType,
    poisonType: c.poisonType,
    safeguard: c.targetSafeguard === true,
    sunny: c.sunny === true,
  };

  if (effectId === TRI_ATTACK) {
    triStatusChance(out, s, rng, c.chance);
    return out;
  }

  let hit = c.hit;
  if (hit === undefined || hit === null) hit = effectChance(rng, c.chance, behindSub);

  if (SIDE_POISON[effectId]) { poisonTarget(out, s, hit); return out; }
  if (SIDE_BURN[effectId]) { burnTarget(out, s, hit); return out; }
  if (SIDE_FREEZE[effectId]) { freezeTarget(out, s, hit); return out; }
  if (SIDE_PARALYZE[effectId]) { paralyzeTarget(out, s, hit); return out; }

  // BattleCommand_FlinchTarget (:5357-5374): a substitute, then a sleeping or
  // frozen target, then CheckOpponentWentFirst (`targetWentFirst`), then
  // wEffectFailed; FlinchTarget's EndRechargeOpp cancels a recharge (R2b's
  // finding (i)). STOMP, TWISTER, SNORE and SKY ATTACK end in this command.
  if (SIDE_FLINCH[effectId]) {
    if (behindSub) return out;
    if (targetMon.status === 'sleep' || targetMon.status === 'freeze') return out;
    if (c.targetWentFirst) return out;
    if (!hit) return out;
    out.proc = true;
    targetMon.flinch = true;
    targetMon.mustRecharge = false;
    return out;
  }

  // BattleCommand_StatDown (statDownGate, then `.DidntMiss`), every failure
  // silent. DefenseDownHit's SECOND `effectchance` is drawn here, against the
  // substitute standing now, and its verdict is the one StatDown reads.
  const stat = SIDE_STAT_DOWN[effectId];
  if (stat) {
    if (effectId === 69) hit = effectChance(rng, c.chance, behindSub);
    if (statDownGate(rng, targetMon, stat, c.computerMover === true, effectId,
      targetMon.lockOn === true)) {
      return out;
    }
    if (behindSub || !hit || targetMon.invulnerable) return out;
    if (statAtFloor(targetMon, stat, targetFighter ? targetFighter.badges : null)) return out;
    out.proc = true;
    applyStatChange(out, targetFighter, targetMon, stat, -1);
    return out;
  }

  // The *UpHit scripts' raises on the user (raiseSideStat; AllStatsUp's
  // ResetMiss lets each of the five fail alone).
  const ups = SIDE_STAT_UP[effectId];
  if (ups) {
    const { userMon } = c;
    if (!userMon || typeof userMon !== 'object') return out;
    for (const key of ups) {
      if (raiseSideStat(out, c.userFighter, userMon, key, hit, c.userBadges)) out.proc = true;
    }
    return out;
  }

  // BattleCommand_ConfuseTarget (:5732-5749): HELD_PREVENT_CONFUSE,
  // wEffectFailed, Safeguard, a substitute, then a target already confused,
  // all before FinishConfusingTarget draws the 2-5 turn byte.
  if (effectId === 76) {
    if (Items.prevents(targetMon, 'confusion')) return out;
    if (!hit || s.safeguard || behindSub) return out;
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

// The looping scripts (wave 3 adds TRIPLE KICK); BEAT UP is Turn's own.
const MULTIHIT = { 29: true, 44: true, 77: true, 112: true };
// The ConstantDamage rows: no crit, no roll (R2b's finding (g)).
const FIXED_DAMAGE = { 38: true, 40: true, 41: true, 131: true, 132: true };
// The damaging scripts whose `checkhit` comes before `critical`, and those
// whose roll comes after it (the Lua twin names them).
const HIT_FIRST = { 27: true, 42: true, 111: true };
const ROLL_AFTER_CHECKHIT = { 81: true, 97: true, 113: true, 114: true };
// RolloutPower's MAX_ROLLOUT_COUNT.
const ROLLOUT_MAX = 5;
const DRAIN = { 3: true, 8: true };
const RECOIL = { 48: true };

function isMultihit(effectId) {
  return MULTIHIT[int(effectId, 0)] === true;
}

// The hits a script is known to run before its loop starts: DoubleHit and
// PoisonMultiHit two, every other script one (MultiHit's count is drawn after
// the first hit, multiHitCount). Draws nothing.
function fixedHits(effectId) {
  const id = int(effectId, 0);
  if (id === 44 || id === 77) return 2;
  return 1;
}

// BattleCommand_EndLoop's first pass for EFFECT_MULTI_HIT (effect_commands.asm:
// 5271-5284): BattleRandom & 3 stands when under 2, otherwise a second
// BattleRandom & 3 replaces it; the move hits that + 2 times in all.
function multiHitCount(rng) {
  let a = (rng ? rng.byte() : 0) % 4;
  if (a >= 2) a = (rng ? rng.byte() : 0) % 4;
  return a + 2;
}

// EndLoop's `.reject_triple_kick_sample`: BattleRandom & 3, again on 0 --
// the kicks in all, 1..3.
function tripleKickCount(rng) {
  for (let i = 0; i < REDRAW_LIMIT; i += 1) {
    const a = (rng ? rng.byte() : 0) % 4;
    if (a !== 0) return a;
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

function drainAmount(damage) {
  return Math.floor(Math.max(0, int(damage, 0)) / 2);
}

// BattleCommand_Recoil: a quarter of wCurDamage, at least 1 -- 0 when a
// substitute took the hit (DoSubstituteDamage's ResetDamage), so 1 then.
function recoilAmount(damage) {
  return Math.max(1, Math.floor(Math.max(0, int(damage, 0)) / 4));
}

// BattleCommand_PayDay: the user's level doubled in a byte (`add a`, its
// carry lost), added to the fight's one wPayDayMoney whoever's turn it is.
function payDayCoins(level) {
  return (Math.max(0, int(level, 0)) * 2) % 256;
}

// EFFECT_OHKO is not here: Gold's is BattleCommand_OHKO, resolved whole by
// Turn (`isOhko`). BattleCommand_ConstantDamage: SUPER FANG halves the HP,
// LEVEL_DAMAGE is the level, PSYWAVE draws until 0 < byte < level + level / 2
// (a byte add; a cap of 0 or 1 never ends on the cart -- guarded to 1), every
// other row is the power.
function fixedDamage(ctx) {
  const c = ctx || {};
  const effectId = int(c.effectId, 0);
  const { userMon, targetMon } = c;
  const movePower = int(c.power, 0);

  if (effectId === 40) {
    return Math.max(1, Math.floor(int(targetMon.hp, 0) / 2));
  }
  if (effectId === LEVEL_DAMAGE) {
    return Math.max(0, int(userMon.level, 1)) % 256;
  }
  if (effectId === PSYWAVE) {
    const level = Math.max(0, int(userMon.level, 1)) % 256;
    const cap = (level + Math.floor(level / 2)) % 256;
    for (let i = 0; i < REDRAW_LIMIT; i += 1) {
      const r = c.rng ? c.rng.byte() : 1;
      if (r !== 0 && r < cap) return r;
      if (cap <= 1) break;
    }
    return 1;
  }
  if (effectId === 41) {
    if (movePower >= 1) return movePower;
    return Math.max(1, int(userMon.level, 1));
  }
  return null;
}

// EFFECT_OHKO: BattleCommand_OHKO, its own accuracy and $ffff (Turn).
function isOhko(effectId) {
  return int(effectId, 0) === 38;
}

// ------------------------------------------------------------------
// the Gold-only damage formulas (wave 3, R2c; the Lua twin carries the notes)
// ------------------------------------------------------------------

const BASE_HAPPINESS = 70;

function happinessPower(happiness) {
  const h = Math.max(0, Math.min(255, int(happiness, BASE_HAPPINESS)));
  return Math.floor(h * 10 / 25) % 256;
}
function frustrationPower(happiness) {
  const h = Math.max(0, Math.min(255, int(happiness, BASE_HAPPINESS)));
  return Math.floor((255 - h) * 10 / 25) % 256;
}

const HIDDEN_POWER_TYPES = [
  'FIGHTING', 'FLYING', 'POISON', 'GROUND', 'ROCK', 'BUG', 'GHOST', 'STEEL',
  'FIRE', 'WATER', 'GRASS', 'ELECTRIC', 'PSYCHIC_TYPE', 'ICE', 'DRAGON', 'DARK',
];

// HiddenPowerDamage over the K7 DVs: { power, type } or null without DVs.
function hiddenPower(dvs) {
  if (!dvs || typeof dvs !== 'object') return null;
  const atk = Math.max(0, int(dvs.atk, 0)) % 16;
  const def = Math.max(0, int(dvs.def, 0)) % 16;
  const spe = Math.max(0, int(dvs.spe, 0)) % 16;
  const spc = Math.max(0, int(dvs.spc, 0)) % 16;
  const top = Math.floor(atk / 8) * 8 + Math.floor(def / 8) * 4
    + Math.floor(spe / 8) * 2 + Math.floor(spc / 8);
  const power = Math.floor((top * 5 + spc % 4) / 2) + 31;
  const index = (atk % 4) * 4 + def % 4;
  return { power, type: HIDDEN_POWER_TYPES[index] };
}

const REVERSAL_POWER = [[1, 200], [4, 150], [9, 100], [16, 80], [32, 40], [48, 20]];

// ConstantDamage's `.reversal`: the HP-bar pixels and FlailReversalPower.
function reversalPower(hp, maxHp) {
  const h = Math.max(0, int(hp, 0)) % 65536;
  const m = Math.max(1, int(maxHp, 1)) % 65536;
  const product = h * 48;
  let q;
  if (m < 256) {
    q = Math.floor(product / Math.max(1, m));
  } else {
    let divisor = Math.floor(m / 4) % 256;
    if (divisor === 0) divisor = 1;
    const dividend = Math.floor(product / 65536) * 65536 + Math.floor((product % 65536) / 4);
    q = Math.floor(dividend / divisor);
  }
  q %= 256;
  for (const row of REVERSAL_POWER) {
    if (row[0] >= q) return row[1];
  }
  return REVERSAL_POWER[REVERSAL_POWER.length - 1][1];
}

const MAGNITUDE_ROWS = [
  [13, 10, 4], [38, 30, 5], [89, 50, 6], [166, 70, 7],
  [217, 90, 8], [242, 110, 9], [255, 150, 10],
];
// BattleCommand_GetMagnitude: { power, magnitude }.
function magnitude(byte) {
  const b = Math.max(0, Math.min(255, int(byte, 0)));
  for (const row of MAGNITUDE_ROWS) {
    if (row[0] >= b) return { power: row[1], magnitude: row[2] };
  }
  return { power: 150, magnitude: 10 };
}

const PRESENT_ROWS = [[102, 40], [179, 80], [204, 120]];
// PresentPower: the power, or null for the heal.
function presentPower(byte) {
  const b = Math.max(0, Math.min(255, int(byte, 0)));
  for (const row of PRESENT_ROWS) {
    if (row[0] >= b) return row[1];
  }
  return null;
}

const TYPE_CONSTANTS = {
  NORMAL: 0, FIGHTING: 1, FLYING: 2, POISON: 3, GROUND: 4, ROCK: 5,
  BIRD: 6, BUG: 7, GHOST: 8, STEEL: 9, CURSE_TYPE: 19, FIRE: 20,
  WATER: 21, GRASS: 22, ELECTRIC: 23, PSYCHIC_TYPE: 24, ICE: 25,
  DRAGON: 26, DARK: 27,
};
function typeConstant(name) {
  if (typeof name !== 'string') return 0;
  return Object.prototype.hasOwnProperty.call(TYPE_CONSTANTS, name) ? TYPE_CONSTANTS[name] : 0;
}

// ProtectChance after its went-first and substitute checks.
function protectChance(rng, count) {
  let b = 255;
  for (let i = 0; i < Math.max(0, int(count, 0)); i += 1) {
    b = Math.floor(b / 2);
    if (b === 0) return false;
  }
  let r = 0;
  for (let i = 0; i < REDRAW_LIMIT; i += 1) {
    r = rng ? rng.byte() : 1;
    if (r !== 0) break;
  }
  if (r === 0) r = 1;
  return (r - 1) < b;
}

const WEATHER_TURNS = 5;
const WEATHER_OF = { 124: 'rain', 125: 'sun', 126: 'sandstorm' };

// DoWeatherModifiers: the type rows first, then rain's SOLARBEAM row; tenths.
function weatherTenths(weather, typeName, effectId) {
  if (weather === 'rain') {
    if (typeName === 'WATER') return 15;
    if (typeName === 'FIRE') return 5;
  } else if (weather === 'sun') {
    if (typeName === 'FIRE') return 15;
    if (typeName === 'WATER') return 5;
  }
  if (weather === 'rain' && int(effectId, 0) === SOLARBEAM) return 5;
  return null;
}

const SANDSTORM_IMMUNE = { ROCK: true, GROUND: true, STEEL: true };

const WEATHER_LINES = {
  rain: { start: 'A downpour started!', continues: 'Rain continues to fall.',
    ended: 'The rain stopped.' },
  sun: { start: 'The sunlight got bright!', continues: 'The sunlight is strong.',
    ended: 'The sunlight faded.' },
  sandstorm: { start: 'A SANDSTORM brewed!', continues: 'The SANDSTORM rages.',
    ended: 'The SANDSTORM subsided.' },
};

const HEAL_TIME = { 128: 'morn', 129: 'day', 130: 'nite' };
// BattleCommand_TimeBasedHealContinue's .Multipliers row and its HP.
function timeHealAmount(maxHp, timeMatches, weather) {
  let c = 2;
  if (!timeMatches) c -= 1;
  if (weather !== null && weather !== undefined) {
    c += 1;
    if (weather !== 'sun') c -= 2;
  }
  if (c <= 0) return Items.eighth(maxHp);
  if (c === 1) return Items.quarter(maxHp);
  if (c === 2) return Items.half(maxHp);
  return Math.max(0, int(maxHp, 0)) % 65536;
}

// ------------------------------------------------------------------
// Phase 4 multi-turn / charge handlers
// ------------------------------------------------------------------

function isCharge(effectId) {
  const id = int(effectId, 0);
  return id === 39 || id === 43 || id === SKY_ATTACK || id === SOLARBEAM
    || id === SKULL_BASH;
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
  if (key === 'DIG') return `${species} dug a hole!`;
  if (key === 'SOLARBEAM') return `${species} took in sunlight!`;
  if (key === 'SKULL_BASH') return `${species} lowered its head!`;
  if (key === 'RAZOR_WIND') return `${species} made a whirlwind!`;
  if (key === 'FLY' || isFly(effectId)) return `${species} flew up high!`;
  return `${species} is glowing!`;
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

// BattleCommand_TrapTarget: BattleRandom & 3, plus 3 -- HandleWrap's count,
// ticked at the end of every turn, the landing one included.
function wrapCount(rng) {
  return 3 + (rng ? rng.byte() : 0) % 4;
}

function isHyperBeam(effectId) {
  return int(effectId, 0) === 80;
}

function isThrash(effectId) {
  return int(effectId, 0) === 27;
}

// BattleCommand_Rampage: "Rampage for 1 or 2 more turns" (BattleRandom & 1,
// plus 1).
function rampageTurns(rng) {
  return 1 + (rng ? rng.byte() : 0) % 2;
}

// BattleCommand_CheckRampage's confusion when the count runs out:
// BattleRandom & 1, plus 2.
function rampageConfusion(rng) {
  return 2 + (rng ? rng.byte() : 0) % 2;
}

// BattleCommand_Defrost: FLAME WHEEL's and SACRED FIRE's `defrost` thaws a
// frozen user; CheckTurn lets the two through a freeze by move id.
const DEFROSTS_USER = { 92: true, 93: true };
const FREEZE_BYPASS = { FLAME_WHEEL: true, SACRED_FIRE: true };

// The doublings after `damagevariation`: TWISTER / GUST on a target in the
// sky, EARTHQUAKE on one underground, STOMP on one that used MINIMIZE.
const DOUBLE_VS_FLYING = { 95: true, 99: true };
// ...and MAGNITUDE's `doubleundergrounddamage` (wave 3).
const DOUBLE_VS_UNDERGROUND = { 100: true, 110: true };
const DOUBLE_VS_MINIMIZED = { 94: true };

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

// The effect rows that have ids of their own from wave 3 (PROTECT / ENDURE 3,
// COUNTER / MIRROR COAT 0), read after VITAL THROW's move-id row.
const EFFECT_PRIORITY = { 120: 3, 121: 3, 122: 0, 123: 0 };

// The priority bracket of a move (a move record or its id). A record's own
// `priority` (contract K8) wins over the tables.
function movePriority(moveOrId) {
  if (moveOrId && typeof moveOrId === 'object' && typeof moveOrId.priority === 'number') {
    return moveOrId.priority;
  }
  const key = moveKey(moveOrId);
  if (key !== 'VITAL_THROW' && moveOrId && typeof moveOrId === 'object') {
    const byEffect = EFFECT_PRIORITY[int(moveOrId.effect, -1)];
    if (byEffect !== undefined) return byEffect;
  }
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

// Deliberately absent from itemEffect (unknown → "But it failed!", still spend
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

// Lua's `type(x) == "table"`.
const isTable = (value) => typeof value === 'object' && value !== null;

// PokeBallEffect (pokegold engine/items/item_effects.asm, pokecrystal the
// same), FX-R2 -- the Lua twin carries the notes: the ball's
// BallMultiplierFunctionTable routine, the HP step and the SLP/FRZ +10 (not
// for a LEVEL BALL), ONE byte that catches at most at wFinalCatchRate, then on
// a miss up to three WobbleProbabilities draws. Returns { caught, shakes,
// finalRate }.
const WOBBLE_PROBABILITIES = [
  [1, 63], [2, 75], [3, 84], [4, 90], [5, 95], [7, 103],
  [10, 113], [15, 126], [20, 134], [30, 149], [40, 160],
  [50, 169], [60, 177], [80, 191], [100, 201], [120, 211],
  [140, 220], [160, 227], [180, 234], [200, 240], [220, 246],
  [240, 251], [254, 253], [255, 255],
];
const BATTLETYPE_FISH = 4;
const FAST_BALL_SPECIES = { MAGNEMITE: true, GRIMER: true, TANGELA: true };
const HEAVY_BALL_WEIGHTS = [[8, 0], [12, 20], [16, 30], [255, 40]];

function doubleByte(b) {
  const out = b * 2;
  return out > 255 ? 255 : out;
}

function heavyBallWeightByte(weight) {
  const half = Math.floor((Math.max(0, int(weight, 0)) % 65536) / 2);
  const sixteenth = Math.floor(half / 16);
  return Math.floor((half - sixteenth - Math.floor(sixteenth / 2)) / 256);
}

function ballRate(ballId, rate, target, ctx) {
  const c0 = isTable(ctx) ? ctx : {};
  let b = Math.max(0, Math.min(255, int(rate, 0)));
  if (ballId === 'ULTRA_BALL') return doubleByte(b);
  if (ballId === 'GREAT_BALL' || ballId === 'SAFARI_BALL' || ballId === 'PARK_BALL') {
    b += Math.floor(b / 2);
    return b > 255 ? 255 : b;
  }
  if (ballId === 'HEAVY_BALL') {
    const weight = isTable(target) ? int(target.weight, null) : null;
    if (weight === null) return b;
    const high = heavyBallWeightByte(weight);
    if (high < 4) return b < 20 ? 1 : b - 20;
    for (const [key, boost] of HEAVY_BALL_WEIGHTS) {
      if (high < key) {
        b += boost;
        return b > 255 ? 255 : b;
      }
    }
    return b;
  }
  if (ballId === 'LEVEL_BALL') {
    const mine = int(isTable(c0.thrower) ? c0.thrower.level : undefined, 0);
    const enemy = int(isTable(target) ? target.level : undefined, 0);
    if (enemy >= mine) return b;
    if (b * 2 > 255) return 255;
    b *= 2;
    let c = Math.floor(mine / 2);
    if (enemy >= c) return b;
    if (b * 2 > 255) return 255;
    b *= 2;
    c = Math.floor(c / 2);
    if (enemy >= c) return b;
    return doubleByte(b);
  }
  if (ballId === 'LURE_BALL') {
    if (int(c0.battleType, -1) !== BATTLETYPE_FISH) return b;
    return Math.min(255, b * 3);
  }
  if (ballId === 'LOVE_BALL') {
    const thrower = c0.thrower;
    if (!isTable(thrower) || !isTable(target)) return b;
    const species = thrower.speciesId;
    if (species === undefined || species === null || species !== target.speciesId) return b;
    const mine = gender(thrower);
    const theirs = gender(target);
    if (mine === null || theirs === null || mine !== theirs) return b;
    return Math.min(255, b * 8);
  }
  if (ballId === 'FAST_BALL') {
    if (isTable(target) && target.speciesId && FAST_BALL_SPECIES[target.speciesId] === true) {
      return Math.min(255, b * 4);
    }
    return b;
  }
  return b;
}

function catchHpRate(rate, hp, maxHp, status) {
  let doubled = (2 * Math.max(0, int(hp, 0))) % 65536;
  let tripled = (3 * Math.max(0, int(maxHp, 0))) % 65536;
  let c;
  if (tripled >= 256) {
    tripled = Math.floor(tripled / 4);
    doubled = Math.floor(doubled / 4);
    c = doubled % 256;
    if (c === 0) c = 1;
  } else {
    c = doubled % 256;
  }
  const b = tripled % 256;
  const multiplier = (((b - c) % 256) + 256) % 256;
  let quotient = 0;
  if (b > 0) quotient = Math.floor(Math.max(0, Math.min(255, int(rate, 0))) * multiplier / b);
  quotient %= 256;
  if (quotient === 0) quotient = 1;
  if (status === 'sleep' || status === 'freeze') quotient += 10;
  if (quotient > 255) quotient = 255;
  return quotient;
}

function wobbleByte(finalRate) {
  const rate = int(finalRate, 0);
  for (const [key, value] of WOBBLE_PROBABILITIES) {
    if (key >= rate) return value;
  }
  return 255;
}

function catchAttempt(ballId, targetMon, rng, ctx) {
  const draw = () => (rng ? rng.byte() : 0);
  if (ballId === 'MASTER_BALL') return { caught: true, shakes: 3, finalRate: 255 };
  const target = isTable(targetMon) ? targetMon : {};
  const rate = ballRate(ballId, Math.max(0, Math.min(255, int(target.catchRate, 255))), target, ctx);
  let final = rate;
  if (ballId !== 'LEVEL_BALL') final = catchHpRate(rate, target.hp, target.maxHp, target.status);
  if (draw() <= final) return { caught: true, shakes: 3, finalRate: final };
  const threshold = wobbleByte(final);
  for (let wobbles = 0; wobbles <= 2; wobbles += 1) {
    if (draw() >= threshold) return { caught: false, shakes: wobbles, finalRate: final };
  }
  return { caught: false, shakes: 3, finalRate: final };
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

// Mediated modes (1v1, coop_*) have no wild flee; only modes whose name
// contains "wild" may treat Teleport as a successful run.
function teleportRunAllowed(mode) {
  return typeof mode === 'string' && mode.includes('wild');
}

// TryToRunAwayFromBattle's wild odds (wave 5; the Lua twin cites it): null
// for a getaway with no byte, else what a BattleRandom byte must not exceed.
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
  MAX_EFFECT_ID,
  CONVERSION,
  FORCE_SWITCH,
  SP_DEF_DOWN_HIT,
  ACCURACY_DOWN_HIT,
  ATTACK_UP_HIT,
  DEFENSE_UP_HIT,
  ALL_UP_HIT,
  FLAME_WHEEL,
  SACRED_FIRE,
  STOMP,
  TWISTER,
  SNORE,
  THUNDER,
  TRI_ATTACK,
  GUST,
  EARTHQUAKE,
  SKY_ATTACK,
  SLEEP_TALK,
  LOCK_ON,
  SAFEGUARD,
  TOXIC,
  SAFEGUARD_TURNS,
  TRANSFORM_PP,
  NO_CHECKHIT,
  LOCK_ON_SKY_MISS,
  SLEEP_TALK_EXCLUDED,
  CHECKS_SAFEGUARD,
  STAT_KEYS,
  calcStats,
  calcMonStats,
  snapStats,
  dropSnap,
  storedStat,
  currentStats,
  setStatus,
  setStatusOn,
  statEvent,
  statUpLine,
  statDownLine,
  missLine,
  didntAffectLine,
  failMoveLine,
  mistLine,
  wontDropLine,
  wontRiseLine,
  statDownMissLine,
  isOhko,
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
  effectChance,
  EFFECT_CHANCE_SCRIPTS,
  drawsEffectChance,
  REDRAW_LIMIT,
  applySide,
  isMultihit,
  fixedHits,
  multiHitCount,
  isFixedDamage,
  isDrain,
  isRecoil,
  drainAmount,
  recoilAmount,
  payDayCoins,
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
  wrapCount,
  isHyperBeam,
  isThrash,
  rampageTurns,
  rampageConfusion,
  DEFROSTS_USER,
  FREEZE_BYPASS,
  DOUBLE_VS_FLYING,
  DOUBLE_VS_UNDERGROUND,
  RETURN, FRUSTRATION, HIDDEN_POWER, REVERSAL, MAGNITUDE, PRESENT,
  TRIPLE_KICK, FURY_CUTTER, ROLLOUT, DEFENSE_CURL, BEAT_UP, PURSUIT,
  FALSE_SWIPE, FUTURE_SIGHT, PROTECT, ENDURE, COUNTER, MIRROR_COAT,
  RAIN_DANCE, SUNNY_DAY, SANDSTORM, SOLARBEAM, MORNING_SUN, SYNTHESIS,
  MOONLIGHT, LEVEL_DAMAGE, PSYWAVE,
  ATTRACT, BATON_PASS, BELLY_DRUM, CONVERSION2, CURSE, DESTINY_BOND, ENCORE,
  FORESIGHT, HEAL_BELL, MEAN_LOOK, NIGHTMARE, PAIN_SPLIT, PERISH_SONG,
  PSYCH_UP, RAPID_SPIN, SKETCH, SPIKES, SPITE, SP_DEF_UP_2, SWAGGER, TELEPORT,
  SP_DEF_UP, SP_DEF_DOWN, SP_DEF_DOWN_2, SKULL_BASH,
  TURN_COMMANDS, READS_MISS, MIMIC_PP, REST_SLEEP_COUNT, BELLY_DRUM_CLIMB,
  GENDER_F0, GENDER_F100, GENDER_UNKNOWN, gender, raiseStat, copyMoveRow, basePp,
  FIELD_MOVES, HIT_FIRST, ROLL_AFTER_CHECKHIT, ROLLOUT_MAX,
  BASE_HAPPINESS, happinessPower, frustrationPower,
  HIDDEN_POWER_TYPES, hiddenPower, REVERSAL_POWER, reversalPower,
  MAGNITUDE_ROWS, magnitude, PRESENT_ROWS, presentPower,
  TYPE_CONSTANTS, typeConstant, protectChance, tripleKickCount,
  WEATHER_TURNS, WEATHER_OF, weatherTenths, SANDSTORM_IMMUNE, WEATHER_LINES,
  HEAL_TIME, timeHealAmount, EFFECT_PRIORITY,
  DOUBLE_VS_MINIMIZED,
  isRage,
  isSpecialType,
  itemEffect,
  itemFailsOnFainted,
  applyVitamin,
  caughtSheet,
  catchAttempt,
  ballRate,
  catchHpRate,
  wobbleByte,
  heavyBallWeightByte,
  WOBBLE_PROBABILITIES,
  BATTLETYPE_FISH,
  FAST_BALL_SPECIES,
  isWildMode,
  isNoOp,
  isBide,
  bideTurns,
  isExplode,
  isJumpKick,
  jumpKickCrash,
  teleportRunAllowed,
  runEndsBattle,
  runOdds,
  isPayDay,
  isMirrorMove,
  isMimic,
  isMetronome,
};
