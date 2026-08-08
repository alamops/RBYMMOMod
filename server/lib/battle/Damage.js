'use strict';

/*
 * Gen1 damage, integer for integer.
 *
 * This is the Node half of src/BattleSim's damage step and the two must agree
 * on every vector in tests/fixtures/battle_sim_vectors.json. A hub that prices
 * a hit at 47 while the LAN host prices it at 48 is not one game, it is two,
 * and the player who loses to the difference has no way to tell which half was
 * wrong. Neither side derives its numbers from the other: both are written out
 * against the same fixture, which is the only thing holding them together.
 *
 * Everything below is integer arithmetic. There is no rounding policy to get
 * wrong because there is no fractional intermediate kept anywhere -- each
 * division truncates immediately, in the order the hardware did it.
 *
 * The Gen1 quirks that are load-bearing here, in the order they bite:
 *
 *   * A stat above 255 does not saturate, it is quartered -- and *both* stats
 *     are quartered when *either* one overflows, so a 400-attack mon hitting a
 *     200-defence one fights at 100 against 50.
 *   * A critical hit doubles the level going into the level term rather than
 *     doubling the finished number, so it is worth slightly less than 2x.
 *   * Type effectiveness is a list of percents applied one at a time, not one
 *     multiplier: 2x then 0.5x truncates in the middle and does not come back
 *     to where it started for every base value.
 *   * Immunity short-circuits. Nothing after a 0% runs, so the random roll
 *     never gets to drag the result back up to its own minimum of 1.
 *
 * The one Gen1 behaviour deliberately *not* modelled is the shortcut where a
 * damage of 1 skips the random roll; the fixture says so in its own notes, and
 * the min-1 clamp below is applied unconditionally instead.
 */

const ROLL_MIN = 217;
const ROLL_MAX = 255;
const STAT_CAP = 255;

// Every division in this file. Values are small positive integers (the largest
// intermediate is on the order of a few million), so this is exact.
const idiv = (a, b) => Math.floor(a / b);

// Both stats fall together when either overflows -- see the header. Defence
// floors at 1 either way: it is a divisor, and a zero one would take the whole
// turn machine down rather than dealing a big number.
function clampStats(attack, defense) {
  const a = Math.max(0, attack || 0);
  const d = Math.max(0, defense === undefined ? 1 : defense);
  if (a > STAT_CAP || d > STAT_CAP) {
    return {
      attack: Math.max(1, idiv(a, 4)),
      defense: Math.max(1, idiv(d, 4)),
      statClamped: true,
    };
  }
  return { attack: a, defense: Math.max(1, d), statClamped: false };
}

// A crit doubles the level here, not the finished damage.
function levelTerm(level, crit) {
  const L = crit ? level * 2 : level;
  return idiv(2 * L, 5) + 2;
}

function baseDamage(term, power, attack, defense) {
  return idiv(idiv(term * power * attack, defense), 50) + 2;
}

function applyStab(d) {
  return idiv(d * 3, 2);
}

// Returns null on immunity so the caller can tell "zero because immune" from
// "zero because the numbers came out that way" -- only the first stops the
// rest of the chain.
function applyTypeEffect(d, percents) {
  let out = d;
  for (const pct of percents) {
    if (pct === 0) return null;
    out = idiv(out * pct, 100);
  }
  return out;
}

function applyRoll(d, roll) {
  return Math.max(1, idiv(d * roll, ROLL_MAX));
}

/*
 * compute({ level, power, attack, defense, stab, typeEffect, crit, roll })
 *
 * `roll` is 217..255, or null to ask for the band instead of a number: then
 * `damage` is null and `minDamage`/`maxDamage` bound it inclusively.
 *
 * `typeEffect` is a list of percents already looked up against the type chart
 * by the caller -- this module owns no chart, and cannot, because the chart is
 * the player's own game data.
 *
 * The intermediates come back too. The parity suites assert on them, and when
 * the two runtimes ever do disagree, the intermediate that first differs is
 * the entire bug report.
 */
function compute(input) {
  const percents = input.typeEffect || [100];
  const crit = !!input.crit;

  const stats = clampStats(input.attack, input.defense);
  const term = levelTerm(input.level, crit);
  const base = baseDamage(term, input.power, stats.attack, stats.defense);

  let modified = input.stab ? applyStab(base) : base;
  const typed = applyTypeEffect(modified, percents);
  const immune = typed === null;
  modified = immune ? 0 : typed;

  const result = {
    levelTerm: term,
    base,
    modified,
    attack: stats.attack,
    defense: stats.defense,
    statClamped: stats.statClamped,
    crit,
    stab: !!input.stab,
    immune,
    minDamage: immune ? 0 : applyRoll(modified, ROLL_MIN),
    maxDamage: immune ? 0 : applyRoll(modified, ROLL_MAX),
  };

  if (immune) {
    result.roll = null;
    result.damage = 0;
  } else if (input.roll === null || input.roll === undefined) {
    result.roll = null;
    result.damage = null;
  } else {
    result.roll = input.roll;
    result.damage = applyRoll(modified, input.roll);
  }

  return result;
}

// The chart-free half of STAB: whether the move's type is one of the
// attacker's. The percents still have to come from the caller's type chart,
// but this much is just set membership and both runtimes can own it.
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
  clampStats,
  levelTerm,
  baseDamage,
  applyStab,
  applyTypeEffect,
  applyRoll,
  idiv,
  ROLL_MIN,
  ROLL_MAX,
  STAT_CAP,
};
