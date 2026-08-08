'use strict';

/*
 * Gen1 critical hits.
 *
 * Node half of src/BattleSim's crit step; same parity contract as Damage.js.
 *
 * Two things here are bugs that have to be kept:
 *
 *   * Focus Energy *quarters* the crit threshold instead of quartering the
 *     odds of not critting. It makes crits rarer. The generation shipped that
 *     way, every reimplementation reproduces it, and a hub that helpfully
 *     inverted it would hand one side of a mediated battle a buff the other
 *     side's client never agreed to.
 *   * The threshold is compared against a 256-value roll but clamps at 255, so
 *     even a high-crit-ratio move with a fast user cannot crit on roll 255.
 *
 * Order matters: Focus Energy divides first, the high-ratio multiplier
 * applies after, and only the final value is clamped -- so the two stack to
 * 96 rather than saturating at 255 and then being quartered to 63.
 */

const MIN = 0;
const MAX = 255;
const HIGH_RATIO = 8;

const idiv = (a, b) => Math.floor(a / b);

const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);

// opts: { focusEnergy, highCritMove }
function threshold(baseSpeed, opts) {
  const o = opts || {};
  let t = idiv(Math.max(0, baseSpeed || 0), 2);
  if (o.focusEnergy) t = idiv(t, 4);
  if (o.highCritMove) t = t * HIGH_RATIO;
  return clamp(t, MIN, MAX);
}

/*
 * check({ baseSpeed, focusEnergy, highCritMove, roll })
 *
 * `baseSpeed` is the species base speed, not the battler's current speed --
 * Gen1 crit rate ignores stat stages and paralysis alike.
 */
function check(input) {
  const t = threshold(input.baseSpeed, input);
  return { threshold: t, isCrit: input.roll < t };
}

module.exports = { check, threshold, MIN, MAX, HIGH_RATIO };
