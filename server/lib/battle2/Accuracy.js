'use strict';

/*
 * Gen2 accuracy: percent domain with stat stages, not Gen1's 1/256 miss.
 *
 * Node twin of src/BattleSim2/Accuracy.lua. Accuracy of 0 (or alwaysHits) means
 * never miss (Swift). Otherwise:
 *
 *   value = accuracy scaled by attacker accuracy stage and defender evasion
 *           stage (same STAGE table as damage), clamped to 1..100
 *   hit   = roll < value   for roll in 0..99
 *
 * There is no Gen1-style "100% still misses 1/256" quirk: a 100% move with
 * neutral stages hits on every roll 0..99.
 *
 * Callers may pass stages (-6..+6) or legacy percent mods (100 = neutral);
 * stages win when present. Flat `hit(input)` matches the Gen1 JS twin; Lua
 * takes (moveAccuracy, roll, opts).
 *
 * Two checks are the cart's byte domain instead (the Lua twin explains): a
 * BRIGHTPOWDER on the target and a one-hit KO move roll a BattleRandom byte
 * against the cart's accuracy byte (`hitBytes`).
 */

const Items = require('./Items.js');

const MIN = 1;
const MAX = 100;
const ROLL_MAX = 99;

const idiv = (a, b) => Math.floor(a / b);

const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);

function int(value, fallback) {
  const n = Number(value);
  if (value === null || value === undefined || Number.isNaN(n)) return fallback;
  if (typeof value === 'boolean') return fallback;
  return Math.floor(n);
}

// Same STAGE table as engine Damage.lua / this sim's Damage.applyStage.
const STAGE = {
  [-6]: [25, 100], [-5]: [28, 100], [-4]: [33, 100],
  [-3]: [40, 100], [-2]: [50, 100], [-1]: [66, 100],
  0: [1, 1],
  1: [15, 10], 2: [2, 1], 3: [25, 10],
  4: [3, 1], 5: [35, 10], 6: [4, 1],
};

function stageMul(stage) {
  const entry = STAGE[clamp(int(stage, 0), -6, 6)];
  return entry;
}

// accuracy: move accuracy in 0..100 (0 = never miss).
// accuracyStage / evasionStage: -6..+6.
function effective(accuracy, accuracyStage, evasionStage) {
  const acc = Math.max(0, int(accuracy, MAX));
  if (acc <= 0) return null;
  let [num, den] = stageMul(accuracyStage);
  let value = idiv(acc * num, den);
  [num, den] = stageMul(-(int(evasionStage, 0)));
  value = idiv(value * num, den);
  return clamp(value, MIN, MAX);
}

// The cart's accuracy byte for a sheet's accuracy (RGBDS `percent`), a byte
// a Gen 1 sheet still carries as it is.
function moveByte(accuracy) {
  const acc = Math.max(0, int(accuracy, MAX));
  if (acc > MAX) return Math.min(255, acc);
  return idiv(acc * 255, 100);
}

// `.StatModifiers` on a byte: each pass at least 1, held at 255 past a byte.
function effectiveByte(byte, accuracyStage, evasionStage) {
  let [num, den] = stageMul(accuracyStage);
  let value = idiv(Math.max(0, int(byte, 0)) * num, den);
  if (value < 1) value = 1;
  [num, den] = stageMul(-(int(evasionStage, 0)));
  value = idiv(value * num, den);
  if (value < 1) value = 1;
  if (value > 255) value = 255;
  return value;
}

// `cp -1 / jr z, .Hit`, then `BattleRandom / cp b / jr nc, .Miss`.
function hitByte(byteAccuracy, roll) {
  const b = int(byteAccuracy, 0);
  if (b >= 255) return true;
  return int(roll, 255) < b;
}

// The byte-domain tail of CheckHit from a base byte: `.StatModifiers`,
// `.BrightPowder` and the roll. Returns { hit, effectiveAccuracy } (a byte).
function hitBytes(byte, roll, opts) {
  const src = opts || {};
  let b = effectiveByte(byte, src.accuracyStage, src.evasionStage);
  if (src.brightPowder !== undefined && src.brightPowder !== null) {
    b = Items.brightPowder(b, src.brightPowder);
  }
  return { effectiveAccuracy: b, hit: hitByte(b, roll) };
}

// Percent-mod path for fixtures that do not carry stages.
function effectiveFromMods(accuracy, accuracyMod, evasionMod) {
  const acc = Math.max(0, int(accuracy, MAX));
  if (acc <= 0) return null;
  let value = idiv(acc * Math.max(0, int(accuracyMod, 100)), 100);
  value = idiv(value * Math.max(0, int(evasionMod, 100)), 100);
  return clamp(value, MIN, MAX);
}

/*
 * hit({ accuracy, accuracyStage, evasionStage, accuracyMod, evasionMod,
 *       alwaysHits, brightPowder, roll })
 *
 * `alwaysHits` (or accuracy 0) skips the roll and reports null effective
 * accuracy. Missing `roll` defaults to 0. `brightPowder` is the DEFENDER's
 * HELD_BRIGHTPOWDER parameter: with it the check is `hitBytes` over the
 * move's byte, `roll` a BattleRandom byte and the effective accuracy a byte;
 * an always-hit move never meets it.
 */
function hit(input) {
  const src = input || {};
  if (src.alwaysHits) {
    return { effectiveAccuracy: null, hit: true };
  }
  const acc = Math.max(0, int(src.accuracy, MAX));
  if (acc <= 0) {
    return { effectiveAccuracy: null, hit: true };
  }
  if (src.brightPowder !== undefined && src.brightPowder !== null) {
    return hitBytes(moveByte(acc), src.roll, src);
  }

  let effectiveAccuracy;
  if (src.accuracyStage !== undefined && src.accuracyStage !== null
      || src.evasionStage !== undefined && src.evasionStage !== null) {
    effectiveAccuracy = effective(acc, src.accuracyStage, src.evasionStage);
  } else {
    effectiveAccuracy = effectiveFromMods(acc, src.accuracyMod, src.evasionMod);
  }
  return {
    effectiveAccuracy,
    hit: int(src.roll, 0) < effectiveAccuracy,
  };
}

module.exports = {
  hit,
  hitBytes,
  hitByte,
  moveByte,
  effectiveByte,
  effective,
  effectiveFromMods,
  int,
  MIN,
  MAX,
  ROLL_MAX,
  STAGE,
};
