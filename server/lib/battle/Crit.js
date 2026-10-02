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
 * Order matters, and it is pokered's CriticalHitTest (engine/battle/core.asm
 * :4478-4540) one shift at a time, every left shift held at 255: b =
 * floor(baseSpeed / 2); Focus Energy halves it (`srl b`, the bug) where every
 * other move doubles it; a high-crit move then doubles it twice more where an
 * ordinary one halves it. So Focus Energy with a high-crit move lands on
 * 4 * floor(b0 / 2) -- 100 for a base Speed of 100 -- not on the 96 a
 * "quarter it, then times eight" shortcut reaches.
 *
 * Edge inputs match Lua: missing roll defaults to MAX (255), so an omitted
 * roll almost never crits.
 */

const MIN = 0;
const MAX = 255;
// What the high-crit chain multiplies an unpumped threshold by, end to end
// (the x2 every move gets, then two more), kept as a named number for logs.
const HIGH_RATIO = 8;

const idiv = (a, b) => Math.floor(a / b);

const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);

function int(value, fallback) {
  const n = Number(value);
  if (value === null || value === undefined || Number.isNaN(n)) return fallback;
  if (typeof value === 'boolean') return fallback;
  return Math.floor(n);
}

// One left shift of the 8-bit register: carry out means "cap at 255/256".
function sla(b) {
  return Math.min(MAX, b * 2);
}

// opts: { focusEnergy, highCritMove }
function threshold(baseSpeed, opts) {
  const o = opts || {};
  let b = idiv(Math.min(MAX, Math.max(0, int(baseSpeed, 0))), 2);
  if (o.focusEnergy) {
    b = idiv(b, 2);
  } else {
    b = sla(b);
  }
  if (o.highCritMove) {
    b = sla(sla(b));
  } else {
    b = idiv(b, 2);
  }
  return clamp(b, MIN, MAX);
}

/*
 * check({ baseSpeed, focusEnergy, highCritMove, roll })
 *
 * `baseSpeed` is the species base speed, not the battler's current speed --
 * Gen1 crit rate ignores stat stages and paralysis alike.
 */
function check(input) {
  const src = input || {};
  const t = threshold(src.baseSpeed, src);
  return { threshold: t, isCrit: int(src.roll, MAX) < t };
}

module.exports = { check, threshold, int, MIN, MAX, HIGH_RATIO };
