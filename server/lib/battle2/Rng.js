'use strict';

/*
 * Deterministic RNG for the Gen2 mediated battle sim.
 *
 * Twin of src/BattleSim2/Rng.lua. Same LCG as Gen1 BattleSim/Rng so Lua and
 * Node share one sequence. Only the damage-variance band differs: Gen2 draws
 * 85..100 inclusive.
 *
 * 32-bit LCG: state = (1664525 * state + 1013904223) >>> 0
 * (Numerical Recipes constants). Draws use bits 16..23, not the low byte.
 */

const TWO32 = 4294967296;
const MULT = 1664525;
const INCR = 1013904223;

const DAMAGE_ROLL_MIN = 85;
const DAMAGE_ROLL_MAX = 100;

function normaliseSeed(seed) {
  let n = Number(seed);
  if (!Number.isFinite(n)) return 0;
  n = Math.floor(n) % TWO32;
  if (n < 0) n += TWO32;
  return n >>> 0;
}

function create(seed) {
  let s = normaliseSeed(seed);

  function next() {
    s = (Math.imul(MULT, s) + INCR) >>> 0;
    return s;
  }

  function byte() {
    return Math.floor(next() / 65536) % 256;
  }

  // 0..n-1, matching engine Damage.rollCritical / rand(..., n).
  function below(n) {
    const span = Math.floor(Number(n) || 0);
    if (span <= 1) return 0;
    return next() % span;
  }

  function nextInt(min, max) {
    let lo = Number(min);
    let hi = Number(max);
    if (!Number.isFinite(lo) && !Number.isFinite(hi)) return byte();
    lo = Math.floor(Number.isFinite(lo) ? lo : 0);
    hi = Math.floor(Number.isFinite(hi) ? hi : lo);
    if (hi < lo) {
      const t = lo;
      lo = hi;
      hi = t;
    }
    const span = hi - lo + 1;
    if (span <= 1) return lo;
    return lo + (next() % span);
  }

  return {
    next,
    byte,
    below,
    nextInt,
    damageRoll() {
      return nextInt(DAMAGE_ROLL_MIN, DAMAGE_ROLL_MAX);
    },
    state() {
      return s;
    },
    setState(value) {
      s = normaliseSeed(value);
      return this;
    },
    clone() {
      return create(s);
    },
  };
}

module.exports = {
  create,
  DAMAGE_ROLL_MIN,
  DAMAGE_ROLL_MAX,
  MULT,
  INCR,
};
