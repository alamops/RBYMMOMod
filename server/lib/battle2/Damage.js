'use strict';

/*
 * Gen2 damage, integer for integer.
 *
 * Node twin of src/BattleSim2/Damage.lua. Parity contract is the same one the
 * Gen1 Damage.js opens with: every vector in
 * tests/fixtures/battle_sim2_vectors.json must agree field-for-field with the
 * Lua half, or a mediated fight on a Node hub and the same fight on a LAN host
 * are two different games.
 *
 * Differs from Gen1 (lib/battle/Damage.js) on purpose:
 *
 *   * Special is SpA vs SpD (sheet keys spa/spd; legacy spc fills both).
 *   * No 255-stat pair clamp inside compute(): the cart's own fold to a byte
 *     is TruncateHL_BC, run by the caller on the stats it chose
 *     (`truncateStats` below), and compute() takes the pair it hands back.
 *   * Crit is a flat x2 after the base product and the type-boost item
 *     (BattleCommand_DamageCalc's .CriticalMultiplier, pokecrystal engine/
 *     battle/effect_commands.asm:3108), not a doubled level term. WHICH
 *     stats a crit reads is not decided here: CheckDamageStatsCritical
 *     (:2660) keeps the boosted pair only when the defender's stage is
 *     strictly lower than the attacker's, and otherwise reads the unmodified
 *     stats -- no stages, badges, burn, paralysis or screens. Turn makes that
 *     choice before it calls in.
 *   * After base (+ optional item boost + crit): cap at 997 then +2
 *     (MIN_DAMAGE), so every non-immune damaging hit leaves DamageCalc ≥ 2.
 *   * DoBadgeTypeBoosts (input.badgeTypeBoost) next, ahead of STAB: an
 *     eighth of the running damage, at least 1.
 *   * STAB is floor(d * 15/10); type rows are percents applied one at a time
 *     as floor(d * pct/100), with a non-immune floor of 1.
 *   * Variation last: floor(d * roll / 100) for roll in 85..100, only when
 *     running damage ≥ 2; final clamp 1..999.
 *
 * Flat `compute(input)` shape matches the Gen1 JS twin and the fixture; Lua
 * takes (attacker, defender, move, opts). Physical vs special: input.physical
 * (default true). When false, reads spa (or spc) vs spd (or spc).
 */

const ROLL_MIN = 85;
const ROLL_MAX = 100;
const MAX_DAMAGE = 999;
const MIN_DAMAGE = 2;

const idiv = (a, b) => Math.floor(a / b);

function int(value, fallback) {
  const n = Number(value);
  if (value === null || value === undefined || Number.isNaN(n)) return fallback;
  if (typeof value === 'boolean') return fallback;
  return Math.floor(n);
}

function stat(source, long, short, fallback) {
  if (!source || typeof source !== 'object') return fallback;
  let value = source[long];
  if (value === undefined || value === null) value = source[short];
  return int(value, fallback);
}

// Prefer spa/spd; fall back to legacy Gen1 spc for either side.
function attackStat(src, physical) {
  if (physical) return stat(src, 'attack', 'atk', 0);
  let value = src.spa;
  if (value === undefined || value === null) value = src.specialAttack;
  if (value === undefined || value === null) value = src.spc;
  if (value === undefined || value === null) value = src.special;
  return int(value, 0);
}

function defenseStat(src, physical) {
  if (physical) return Math.max(1, stat(src, 'defense', 'def', 1));
  let value = src.spd;
  if (value === undefined || value === null) value = src.specialDefense;
  if (value === undefined || value === null) value = src.spc;
  if (value === undefined || value === null) value = src.special;
  return Math.max(1, int(value, 1));
}

function percents(effect) {
  if (effect === undefined || effect === null) return [100];
  if (typeof effect === 'number') return [Math.floor(effect)];
  if (!Array.isArray(effect)) return [100];
  const list = [];
  for (let i = 0; i < effect.length; i += 1) {
    list.push(int(effect[i], 100));
  }
  if (list.length === 0) return [100];
  return list;
}

// floor(2L/5)+2 — Gen2 does not double L on crit.
function levelTerm(level, _crit) {
  const L = Math.max(0, int(level, 1));
  return idiv(L * 2, 5) + 2;
}

// Core product before the +2 min-damage pad.
function base(level, power, attack, defense) {
  if ((power || 0) <= 0) return 0;
  const def = Math.max(1, int(defense, 1));
  let value = levelTerm(level, false);
  value *= Math.max(0, int(power, 0));
  value *= Math.max(0, int(attack, 0));
  value = idiv(value, def);
  value = idiv(value, 50);
  return value;
}

// TruncateHL_BC (pokecrystal engine/battle/effect_commands.asm:2614-2658):
// fold the attack / defense pair the damage formula multiplies into a byte
// each. While either is 255 or more, both are shifted right twice -- a value
// the shift empties becomes 1 -- and what comes out are the low bytes.
//
// `link` is the cart's `wLinkMode == LINK_COLOSSEUM` early exit: one pass and
// no re-check, so a stat still past 1023 after it keeps only its low byte --
// the wrap bug docs/bugs_and_glitches.md names. A wrapped 0 is not repaired
// here: a defense of 0 is lifted to 1 by DamageCalc (`compute` below) and an
// attack of 0 leaves the base at 0. Returns { attack, defense }.
function truncateStats(attack, defense, link) {
  let a = Math.max(0, int(attack, 0));
  let d = Math.max(0, int(defense, 0));
  while (a > 255 || d > 255) {
    d = Math.floor(d / 4);
    if (d === 0) d = 1;
    a = Math.floor(a / 4);
    if (a === 0) a = 1;
    if (link) break;
  }
  return { attack: a % 256, defense: d % 256 };
}

function applyRoll(modified, roll) {
  const d = Math.max(0, int(modified, 0));
  if (d < 2) return Math.max(1, d);
  let r = int(roll, ROLL_MAX);
  if (r < ROLL_MIN) r = ROLL_MIN;
  if (r > ROLL_MAX) r = ROLL_MAX;
  return Math.max(1, Math.min(MAX_DAMAGE, idiv(d * r, 100)));
}

/*
 * compute({ level, power, attack|atk, defense|def, spa|spc, spd|spc,
 *           stab, typeEffect|typeEff, crit, roll, physical, itemBoostPercent,
 *           badgeTypeBoost })
 *
 * Flat shape for the fixture / hub call sites. `roll` null/undefined asks for
 * the band: then `damage` is null and minDamage/maxDamage bound it.
 */
function compute(input) {
  const src = input || {};
  let physical = src.physical;
  if (physical === undefined || physical === null) physical = true;
  physical = !!physical;

  const attack = attackStat(src, physical);
  const defense = defenseStat(src, physical);
  const term = levelTerm(src.level, false);
  const power = Math.max(0, int(src.power, 0));
  const baseVal = base(src.level, power, attack, defense);

  const result = {
    levelTerm: term,
    base: baseVal,
    attack,
    defense,
    physical,
    statClamped: false,
    crit: !!src.crit,
    stab: !!src.stab,
    immune: false,
  };

  if (power <= 0) {
    result.modified = 0;
    result.damage = 0;
    result.minDamage = 0;
    result.maxDamage = 0;
    return result;
  }

  let d = baseVal;

  if (src.itemBoostPercent !== undefined && src.itemBoostPercent !== null
      && int(src.itemBoostPercent, 0) > 0) {
    d = idiv(d * (100 + int(src.itemBoostPercent, 0)), 100);
  }

  if (src.crit) d *= 2;

  // Cap at DAMAGE_CAP then add MIN_DAMAGE (engine DamageCalc tail).
  d = Math.min(d, MAX_DAMAGE - MIN_DAMAGE) + MIN_DAMAGE;

  // DoBadgeTypeBoosts (pokecrystal engine/battle/misc.asm:146), farcalled by
  // BattleCommand_Stab ahead of the STAB multiply: the player owns the badge
  // whose row names the move's type, and the running damage gains an eighth
  // of itself, at least 1 (engine src/battle/gen2/Damage.lua:269-274). The
  // engine runs DoWeatherModifiers just before it; this sim has no weather,
  // so nothing sits between the DamageCalc tail and here.
  if (src.badgeTypeBoost) d += Math.max(1, Math.floor(d / 8));

  if (src.stab) d = idiv(d * 15, 10);

  const effect = src.typeEffect !== undefined && src.typeEffect !== null
    ? src.typeEffect : src.typeEff;

  for (const pct of percents(effect)) {
    if (pct <= 0) {
      result.modified = 0;
      result.immune = true;
      result.damage = 0;
      result.minDamage = 0;
      result.maxDamage = 0;
      return result;
    }
    d = idiv(d * pct, 100);
    if (d === 0) d = 1;
  }

  result.modified = d;
  result.minDamage = applyRoll(d, ROLL_MIN);
  result.maxDamage = applyRoll(d, ROLL_MAX);

  if (src.roll === null || src.roll === undefined) {
    result.damage = null;
  } else {
    result.roll = int(src.roll, ROLL_MAX);
    result.damage = applyRoll(d, result.roll);
  }

  return result;
}

function hasStab(moveType, attackerTypes) {
  if (!attackerTypes) return false;
  for (const t of attackerTypes) {
    if (t === moveType) return true;
  }
  return false;
}

module.exports = {
  compute,
  hasStab,
  levelTerm,
  base,
  truncateStats,
  applyRoll,
  idiv,
  int,
  percents,
  attackStat,
  defenseStat,
  ROLL_MIN,
  ROLL_MAX,
  MAX_DAMAGE,
  MIN_DAMAGE,
};
