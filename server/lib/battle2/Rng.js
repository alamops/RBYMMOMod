'use strict';

/*
 * Deterministic RNG for the Gen2 mediated battle sim.
 *
 * Twin of src/BattleSim2/Rng.lua. Same LCG as Gen1 BattleSim/Rng so Lua and
 * Node share one sequence. Only the damage roll differs: Gen2 draws the
 * cart's DamageVariation loop (`damageRoll`), a rotated byte in 217..255.
 *
 * 32-bit LCG: state = (1664525 * state + 1013904223) >>> 0
 * (Numerical Recipes constants). Every draw comes off the high half of the
 * state: `byte()` reads bits 16..23, `below` / `nextInt` bits 16..31 (K12).
 */

const TWO32 = 4294967296;
const MULT = 1664525;
const INCR = 1013904223;

const DAMAGE_ROLL_MIN = 217;
const DAMAGE_ROLL_MAX = 255;

// The guard on the rejection loop below (the Lua twin explains).
const REDRAW_LIMIT = 1024;

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

  // One draw into 0..span-1 off the state's HIGH bits (contract K12): its
  // high 16 bits (16..31) modulo the span. `next() % span` kept the low bits,
  // and an LCG's bit k cycles with period 2^(k+1) -- bit 0 alternates, bits
  // 0..1 repeat every four draws -- so a crit at chance 4 or 2 and the 16-wide
  // damage roll followed a fixed pattern set by the draw's position in the
  // stream. The same rule as Gen 1's lib/battle/Rng.js (one K12 for both
  // referees), exact in both runtimes. A span wider than 65536 (no referee
  // caller has one) stitches two high halves into a 32-bit value first.
  function high16() {
    return Math.floor(next() / 65536);
  }

  function scaled(span) {
    if (span <= 65536) return high16() % span;
    const top = high16();
    const bottom = high16();
    return (top * 65536 + bottom) % span;
  }

  // 0..n-1, matching engine Damage.rollCritical / rand(..., n).
  function below(n) {
    const span = Math.floor(Number(n) || 0);
    if (span <= 1) return 0;
    return scaled(span);
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
    return lo + scaled(span);
  }

  return {
    next,
    byte,
    below,
    nextInt,
    // BattleCommand_DamageVariation's `.loop` (the Lua twin cites it):
    // BattleRandom, `rrca`, redrawn while under 217.
    damageRoll() {
      for (let i = 0; i < REDRAW_LIMIT; i++) {
        const b = byte();
        const r = Math.floor(b / 2) + (b % 2) * 128;
        if (r >= DAMAGE_ROLL_MIN) return r;
      }
      return DAMAGE_ROLL_MAX;
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
  REDRAW_LIMIT,
  MULT,
  INCR,
};
