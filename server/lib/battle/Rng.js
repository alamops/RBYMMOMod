'use strict';

/*
 * Deterministic RNG for the mediated battle sim.
 *
 * Twin of src/BattleSim/Rng.lua. Both runtimes must produce the same sequence
 * from the same seed: a fight on a LAN host and the same fight on the Node hub
 * are otherwise different games. Math.random cannot do that.
 *
 * 32-bit LCG: state = (1664525 * state + 1013904223) >>> 0
 * (Numerical Recipes constants). Draws use bits 16..23, not the low byte —
 * an LCG's low bits cycle with a short period.
 */

const TWO32 = 4294967296;
const MULT = 1664525;
const INCR = 1013904223;

const DAMAGE_ROLL_MIN = 217;
const DAMAGE_ROLL_MAX = 255;

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
