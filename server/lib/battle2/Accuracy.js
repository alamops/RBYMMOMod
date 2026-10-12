'use strict';

/*
 * Gen2 accuracy: BattleCommand_CheckHit's byte domain, as the cart rolls it.
 *
 * Node twin of src/BattleSim2/Accuracy.lua (which carries the notes and the
 * pret citations). From `.StatModifiers` on: the move's accuracy BYTE (the
 * wire's, or BattleCommand_OHKO's, or THUNDER's `50 percent + 1` in the sun),
 * the user's accuracy level then the target's evasion level negated through
 * AccuracyLevelMultipliers (each pass at least 1, the product held at $ff; a
 * FORESIGHT-identified target with evasion at least the user's accuracy
 * skips the step), `.BrightPowder` off it, and then a byte of 255 hits with
 * NOTHING drawn, any other byte one BattleRandom under it.
 *
 * Flat `hit(input)` matches the Gen1 JS twin; Lua takes (byte, roll, opts).
 */

const Items = require('./Items.js');

const BYTE_MAX = 255;

// AccuracyLevelMultipliers, -6..+6, as num/den.
const LEVEL_MULT = {
  [-6]: [33, 100], [-5]: [36, 100], [-4]: [43, 100],
  [-3]: [50, 100], [-2]: [60, 100], [-1]: [75, 100],
  0: [1, 1],
  1: [133, 100], 2: [166, 100], 3: [2, 1],
  4: [233, 100], 5: [133, 50], 6: [3, 1],
};

// BattleCommand_ThunderAccuracy's sun byte (`50 percent + 1`).
const THUNDER_SUN_BYTE = 128;

const idiv = (a, b) => Math.floor(a / b);

const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);

function int(value, fallback) {
  const n = Number(value);
  if (value === null || value === undefined || Number.isNaN(n)) return fallback;
  if (typeof value === 'boolean') return fallback;
  return Math.floor(n);
}

function stageMul(stage) {
  return LEVEL_MULT[clamp(int(stage, 0), -6, 6)];
}

// The cart's accuracy byte for a sheet's accuracy: the byte itself, 0..255.
function moveByte(accuracy) {
  return clamp(int(accuracy, BYTE_MAX), 0, BYTE_MAX);
}

// `.StatModifiers` on a byte, FORESIGHT's `identified` exemption included.
function effectiveByte(byte, accuracyStage, evasionStage, identified) {
  const acc = int(accuracyStage, 0);
  const eva = int(evasionStage, 0);
  let value = Math.max(0, int(byte, 0));
  if (identified && eva >= acc) return Math.min(BYTE_MAX, value);
  let [num, den] = stageMul(acc);
  value = idiv(value * num, den);
  if (value < 1) value = 1;
  [num, den] = stageMul(-eva);
  value = idiv(value * num, den);
  if (value < 1) value = 1;
  if (value > BYTE_MAX) value = BYTE_MAX;
  return value;
}

// The byte the roll is compared with: `.StatModifiers`, then `.BrightPowder`.
function finalByte(byte, opts) {
  const o = opts || {};
  let b = effectiveByte(byte, o.accuracyStage, o.evasionStage, o.identified);
  if (o.brightPowder !== undefined && o.brightPowder !== null) {
    b = Items.brightPowder(b, o.brightPowder);
  }
  return b;
}

// Whether the check draws its BattleRandom: every byte but 255.
function draws(byte) {
  return int(byte, 0) < BYTE_MAX;
}

// `cp -1 / jr z, .Hit`, then `BattleRandom / cp b / jr nc, .Miss`.
function hitByte(byteAccuracy, roll) {
  const b = int(byteAccuracy, 0);
  if (b >= BYTE_MAX) return true;
  return int(roll, BYTE_MAX) < b;
}

/*
 * hit({ accuracy, roll, accuracyStage, evasionStage, brightPowder,
 *       identified, alwaysHits }) -> { hit, effectiveAccuracy }
 *
 * `accuracy` is the move's byte; `effectiveAccuracy` the byte rolled against
 * (null when `alwaysHits`: the caller's earlier step decided).
 */
function hit(input) {
  const src = input || {};
  if (src.alwaysHits) return { effectiveAccuracy: null, hit: true };
  const b = finalByte(moveByte(src.accuracy), src);
  return { effectiveAccuracy: b, hit: hitByte(b, src.roll) };
}

module.exports = {
  hit,
  hitByte,
  moveByte,
  effectiveByte,
  finalByte,
  draws,
  int,
  BYTE_MAX,
  LEVEL_MULT,
  THUNDER_SUN_BYTE,
};
