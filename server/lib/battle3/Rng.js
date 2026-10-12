'use strict';

/*
 * Deterministic RNG for the Gen 3 mediated battle sim.
 *
 * Node twin of src/BattleSim3/Rng.lua. The same LCG as lib/battle and
 * lib/battle2, so a hub carries one generator shape across all three
 * generations:
 *
 *   s = (1664525 * s + 1013904223) mod 2^32
 *
 * What differs is the one primitive every Gen 3 draw site uses, `roll(lo, hi)`,
 * which reads the TOP of the state rather than `s % span`:
 *
 *   roll(lo, hi) = lo + floor(s * (hi - lo + 1) / 2^32)
 *
 * An LCG modulo a power of two has a short period in its low bits (bit 0
 * alternates every step), so a coin flip taken off the bottom is a rota, not a
 * coin. The product is exact in a double (s < 2^32 and every span drawn is at
 * most 2^16), so this computes the same number the Lua does, bit for bit.
 *
 * The state step uses Math.imul for the low 32 bits of the product; the Lua
 * multiplies in doubles (exact below 2^53) and reduces mod 2^32. Same value.
 *
 * A range with one value (or an inverted one) returns `lo` and draws NOTHING.
 * That is part of the draw-order contract: "a random target among one living
 * foe" costs no state on either runtime.
 */

const { toNumber } = require('./lua.js');

const TWO32 = 4294967296;
const MULT = 1664525;
const INCR = 1013904223;

const DAMAGE_ROLL_MIN = 85;
const DAMAGE_ROLL_MAX = 100;

function normaliseSeed(seed) {
  let n = toNumber(seed);
  if (n === null) return 0;
  n = Math.floor(n) % TWO32;
  if (n < 0) n += TWO32;
  return n;
}

function floorArg(value, fallback) {
  const n = toNumber(value);
  return Math.floor(n === null ? fallback : n);
}

class Rng {
  constructor(seed) {
    this.s = normaliseSeed(seed);
    this.draws = 0;
  }

  next() {
    this.s = (Math.imul(MULT, this.s) + INCR) >>> 0;
    this.draws += 1;
    return this.s;
  }

  // The Gen 3 primitive. Inclusive on both ends, like the engine's roll(lo, hi).
  roll(lo, hi) {
    const l = floorArg(lo, 0);
    const h = floorArg(hi, l);
    if (h <= l) return l;
    const span = h - l + 1;
    return l + Math.floor(this.next() * span / TWO32);
  }

  // 85..100, the damage variance band (pret `100 - Random() % 16`).
  damageRoll() {
    return this.roll(DAMAGE_ROLL_MIN, DAMAGE_ROLL_MAX);
  }

  // Kept for callers ported from BattleSim2 (the aim stream draws with byte()).
  byte() {
    return Math.floor(this.next() / 65536) % 256;
  }

  state() {
    return this.s;
  }

  setState(value) {
    this.s = normaliseSeed(value);
    return this;
  }

  clone() {
    const out = new Rng(0);
    out.s = this.s;
    out.draws = this.draws;
    return out;
  }
}

function create(seed) {
  return new Rng(seed);
}

// A scripted stand-in with the same interface, for the vector pack: `values`
// is consumed in order, and a draw past the end (or outside the requested
// range) answers the range's top. Never used by the turn machine.
function scripted(values) {
  const list = Array.isArray(values) ? values : [];
  const script = {
    i: 0,
    draws: 0,
    log: [],
    roll(lo, hi) {
      const l = floorArg(lo, 0);
      const h = floorArg(hi, l);
      if (h <= l) return l;
      this.i += 1;
      this.draws += 1;
      let v = list[this.i - 1];
      this.log.push({ lo: l, hi: h, v });
      v = toNumber(v);
      if (v === null || v < l || v > h) return h;
      return Math.floor(v);
    },
    damageRoll() {
      return this.roll(DAMAGE_ROLL_MIN, DAMAGE_ROLL_MAX);
    },
    state() {
      return this.i;
    },
  };
  return script;
}

module.exports = {
  Rng,
  create,
  new: create,
  scripted,
  DAMAGE_ROLL_MIN,
  DAMAGE_ROLL_MAX,
  MULT,
  INCR,
};
