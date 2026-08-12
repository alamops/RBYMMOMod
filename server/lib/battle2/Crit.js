'use strict';

/*
 * Gen2 critical hits: a chance ladder, not Gen1's base-Speed threshold.
 *
 * Node twin of src/BattleSim2/Crit.lua. Level 0..6 indexes 1-in-N chances
 * {15,8,4,3,2,2,2}. A hit is critical when random(N) returns 0.
 *
 * Level contributions (capped at 6):
 *   +1 Focus Energy, +2 high-crit move, +1 Scope Lens,
 *   +2 species+item bonus (Lucky Punch / Stick).
 *
 * Unlike Gen1 there is no Focus Energy bug here — Focus Energy raises the
 * level. Crit *damage* (flat x2) lives in Damage.js; this module only answers
 * the roll.
 *
 * Flat `check(input)` matches the Gen1 JS twin; Lua takes
 * (criticalLevel, roll, opts).
 */

const CRITICAL_CHANCES = {
  0: 15, 1: 8, 2: 4, 3: 3, 4: 2, 5: 2, 6: 2,
};

function int(value, fallback) {
  const n = Number(value);
  if (value === null || value === undefined || Number.isNaN(n)) return fallback;
  if (typeof value === 'boolean') return fallback;
  return Math.floor(n);
}

function chance(level) {
  const capped = Math.max(0, Math.min(6, int(level, 0)));
  return CRITICAL_CHANCES[capped];
}

// opts: { focusEnergy, highCritMove, scopeLens, speciesItemBonus }
function level(opts) {
  const o = opts || {};
  let lvl = 0;
  if (o.focusEnergy) lvl += 1;
  if (o.highCritMove) lvl += 2;
  if (o.scopeLens) lvl += 1;
  if (o.speciesItemBonus) lvl += 2;
  return Math.min(6, lvl);
}

/*
 * check({ criticalLevel, focusEnergy, highCritMove, scopeLens,
 *         speciesItemBonus, roll })
 *
 * `roll` is 0..chance-1 (caller draws with Rng.below(chance)). Missing roll
 * defaults to `chance` so an omitted roll is not a crit (r === 0 fails).
 */
function check(input) {
  const src = input || {};
  let lvl = int(src.criticalLevel, 0);
  if (src.focusEnergy || src.highCritMove || src.scopeLens || src.speciesItemBonus) {
    lvl = level(src);
  }
  const ch = chance(lvl);
  const r = int(src.roll, ch);
  return { isCrit: r === 0, chance: ch, level: lvl };
}

module.exports = {
  check,
  chance,
  level,
  int,
  CRITICAL_CHANCES,
};
