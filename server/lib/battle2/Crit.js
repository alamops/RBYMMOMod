'use strict';

/*
 * Gen2 critical hits: a chance ladder, not Gen1's base-Speed threshold.
 *
 * Node twin of src/BattleSim2/Crit.lua. Level 0..6 indexes
 * data/battle/critical_hit_chances.asm (`1 out_of N`: 17, 32, 64, 85, 128,
 * 128, 128), and a hit is critical when the BattleRandom byte `.Tally` draws
 * is below its row (`cp [hl] / ret nc`) -- the byte domain since wave 4.
 *
 * Level contributions (capped at 6):
 *   +1 Focus Energy, +2 high-crit move, +1 Scope Lens.
 * The species+item bonus (Chansey's Lucky Punch, Farfetch'd's Stick) is not a
 * contribution: BattleCommand_Critical loads c = 2 and jumps straight to
 * `.Tally`, so with it the level IS 2 (the Lua twin cites the lines).
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
const CRITICAL_BYTES = {
  0: 17, 1: 32, 2: 64, 3: 85, 4: 128, 5: 128, 6: 128,
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

// The byte a level's crit is drawn under.
function threshold(level) {
  const capped = Math.max(0, Math.min(6, int(level, 0)));
  return CRITICAL_BYTES[capped];
}

const SPECIES_ITEM_LEVEL = 2;

// opts: { focusEnergy, highCritMove, scopeLens, speciesItemBonus }
function level(opts) {
  const o = opts || {};
  if (o.speciesItemBonus) return SPECIES_ITEM_LEVEL;
  let lvl = 0;
  if (o.focusEnergy) lvl += 1;
  if (o.highCritMove) lvl += 2;
  if (o.scopeLens) lvl += 1;
  return Math.min(6, lvl);
}

/*
 * check({ criticalLevel, focusEnergy, highCritMove, scopeLens,
 *         speciesItemBonus, roll })
 *
 * `roll` is the BattleRandom byte `.Tally` compares; a missing roll reads 255
 * (never a crit). `chance` is the threshold byte.
 */
function check(input) {
  const src = input || {};
  let lvl = int(src.criticalLevel, 0);
  if (src.focusEnergy || src.highCritMove || src.scopeLens || src.speciesItemBonus) {
    lvl = level(src);
  }
  const th = threshold(lvl);
  const r = int(src.roll, 255);
  return { isCrit: r < th, chance: th, level: lvl };
}

module.exports = {
  check,
  chance,
  threshold,
  level,
  int,
  CRITICAL_CHANCES,
  CRITICAL_BYTES,
  SPECIES_ITEM_LEVEL,
};
