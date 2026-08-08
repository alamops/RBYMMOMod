'use strict';

/*
 * Gen1 accuracy: does the move connect.
 *
 * Node half of src/BattleSim's accuracy step; the parity contract is the same
 * one Damage.js opens with.
 *
 * Accuracy is a 0..255 byte, not a percent, and the roll it is compared
 * against has 256 values. Since the effective accuracy is clamped to 255, a
 * move players call "100%" still misses on roll 255 -- the famous 1-in-256.
 * That is reproduced deliberately: a hub that quietly fixed it would disagree
 * with every other Gen1 implementation the player has ever seen, and would
 * disagree with the Lua twin the moment the twin did not fix it too.
 *
 * The modifiers are percents applied one at a time and truncated in between,
 * so an accuracy boost followed by an evasion boost is not commutative with
 * itself at every input. Order here is accuracy first, then evasion.
 *
 * Edge inputs match Lua: missing accuracy defaults to 255, missing roll
 * defaults to 0 (so a missing roll hits whenever effective accuracy > 0).
 */

const MIN = 1;
const MAX = 255;

const idiv = (a, b) => Math.floor(a / b);

const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);

function int(value, fallback) {
  const n = Number(value);
  if (value === null || value === undefined || Number.isNaN(n)) return fallback;
  if (typeof value === 'boolean') return fallback;
  return Math.floor(n);
}

// Truncating between the two modifiers is the point -- do not fold them into
// one multiply. Missing accuracy → MAX (255), matching Lua.
function effective(accuracy, accuracyMod, evasionMod) {
  const acc = Math.max(0, int(accuracy, MAX));
  const withAcc = idiv(acc * Math.max(0, int(accuracyMod, 100)), 100);
  const withEva = idiv(withAcc * Math.max(0, int(evasionMod, 100)), 100);
  return clamp(withEva, MIN, MAX);
}

/*
 * hit({ accuracy, accuracyMod, evasionMod, alwaysHits, roll })
 *
 * `alwaysHits` skips the roll entirely and reports a null effective accuracy:
 * a move that cannot miss has no accuracy to report, and returning 255 would
 * invite a caller to roll against it and reintroduce the 1-in-256.
 *
 * Missing `roll` defaults to 0 (Lua int(roll, 0)), so an omitted roll hits.
 */
function hit(input) {
  const src = input || {};
  if (src.alwaysHits) {
    return { effectiveAccuracy: null, hit: true };
  }
  const effectiveAccuracy = effective(src.accuracy, src.accuracyMod, src.evasionMod);
  return { effectiveAccuracy, hit: int(src.roll, 0) < effectiveAccuracy };
}

module.exports = { hit, effective, int, MIN, MAX };
