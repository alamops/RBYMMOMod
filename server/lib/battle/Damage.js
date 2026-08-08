'use strict';

/*
 * Gen1 damage, integer for integer.
 *
 * This is the Node half of src/BattleSim's damage step and the two must agree
 * on every vector in tests/fixtures/battle_sim_vectors.json. A hub that prices
 * a hit at 47 while the LAN host prices it at 48 is not one game, it is two,
 * and the player who loses to the difference has no way to tell which half was
 * wrong. Neither side derives its numbers from the other: both are written out
 * against the same fixture, which is the only thing holding them together.
 *
 * Everything below is integer arithmetic. There is no rounding policy to get
 * wrong because there is no fractional intermediate kept anywhere -- each
 * division truncates immediately, in the order the hardware did it.
 *
 * The Gen1 quirks that are load-bearing here, in the order they bite:
 *
 *   * A stat above 255 does not saturate, it is quartered -- and *both* stats
 *     are quartered when *either* one overflows, so a 400-attack mon hitting a
 *     200-defence one fights at 100 against 50.
 *   * A critical hit doubles the level going into the level term rather than
 *     doubling the finished number, so it is worth slightly less than 2x.
 *   * Type effectiveness is a list of percents applied one at a time, not one
 *     multiplier: 2x then 0.5x truncates in the middle and does not come back
 *     to where it started for every base value.
 *   * Immunity short-circuits. Nothing after a 0% runs, so the random roll
 *     never gets to drag the result back up to its own minimum of 1.
 *
 * The one Gen1 behaviour deliberately *not* modelled is the shortcut where a
 * damage of 1 skips the random roll; the fixture says so in its own notes, and
 * the min-1 clamp below is applied unconditionally instead.
 *
 * Edge inputs match Lua's Damage.lua: missing level → 1, atk/def/typeEff
 * aliases, a bare number typeEffect, and nonsensical values coerced rather than
 * producing NaN.
 */

const ROLL_MIN = 217;
const ROLL_MAX = 255;
const STAT_CAP = 255;

// Every division in this file. Values are small positive integers (the largest
// intermediate is on the order of a few million), so this is exact.
const idiv = (a, b) => Math.floor(a / b);

// Lua's `int(value, fallback)`: tonumber, reject NaN, floor.
function int(value, fallback) {
  const n = Number(value);
  if (value === null || value === undefined || Number.isNaN(n)) return fallback;
  if (typeof value === 'boolean') return fallback;
  return Math.floor(n);
}

// Reads a stat off either spelling. `attack`/`defense` is what the wire and
// the fixtures use; `atk`/`def` is what the engine's battler tables use.
function stat(source, long, short, fallback) {
  if (!source || typeof source !== 'object') return fallback;
  let value = source[long];
  if (value === undefined || value === null) value = source[short];
  return int(value, fallback);
}

// Normalises whatever the caller had to hand into a list of percents: a bare
// number is a single step, a list is taken as written, nil is neutral.
function percents(effect) {
  if (effect === undefined || effect === null) return [100];
  if (typeof effect === 'number') return [Math.floor(effect)];
  if (!Array.isArray(effect)) return [100];
  const list = [];
  for (let i = 0; i < effect.length; i += 1) {
    list.push(int(effect[i], 100));
  }
  if (list.length === 0) return [100];
  return list;
}

// Both stats fall together when either overflows -- see the header. Defence
// floors at 1 either way: it is a divisor, and a zero one would take the whole
// turn machine down rather than dealing a big number.
function clampStats(attack, defense) {
  const a = Math.max(0, int(attack, 0));
  const d = Math.max(0, int(defense, 1));
  if (a > STAT_CAP || d > STAT_CAP) {
    return {
      attack: Math.max(1, idiv(a, 4)),
      defense: Math.max(1, idiv(d, 4)),
      statClamped: true,
    };
  }
  return { attack: a, defense: Math.max(1, d), statClamped: false };
}

// A crit doubles the level here, not the finished damage. Missing level → 1,
// matching Lua's levelTerm(int(level, 1)).
function levelTerm(level, crit) {
  let L = Math.max(0, int(level, 1));
  if (crit) L *= 2;
  return idiv(2 * L, 5) + 2;
}

function baseDamage(term, power, attack, defense) {
  return idiv(idiv(term * power * attack, defense), 50) + 2;
}

function applyStab(d) {
  return idiv(d * 3, 2);
}

// Returns null on immunity so the caller can tell "zero because immune" from
// "zero because the numbers came out that way" -- only the first stops the
// rest of the chain.
function applyTypeEffect(d, list) {
  let out = d;
  for (const pct of list) {
    if (pct === 0) return null;
    out = idiv(out * pct, 100);
  }
  return out;
}

function applyRoll(d, roll) {
  return Math.max(1, idiv(d * int(roll, ROLL_MAX), ROLL_MAX));
}

/*
 * compute({ level, power, attack|atk, defense|def, stab, typeEffect|typeEff,
 *           crit, roll })
 *
 * Flat shape for the fixture / hub call sites; aliases and coercion match
 * Lua's Damage.compute(attacker, defender, move, opts).
 *
 * `roll` is 217..255, or null/undefined to ask for the band instead of a
 * number: then `damage` is null and `minDamage`/`maxDamage` bound it.
 */
function compute(input) {
  const src = input || {};
  const effect = src.typeEffect !== undefined && src.typeEffect !== null
    ? src.typeEffect : src.typeEff;
  const list = percents(effect);
  const crit = !!src.crit;

  const rawAttack = stat(src, 'attack', 'atk', 0);
  const rawDefense = stat(src, 'defense', 'def', 1);
  const stats = clampStats(rawAttack, rawDefense);
  const term = levelTerm(src.level, crit);
  const power = Math.max(0, int(src.power, 0));
  const base = baseDamage(term, power, stats.attack, stats.defense);

  let modified = src.stab ? applyStab(base) : base;
  const typed = applyTypeEffect(modified, list);
  const immune = typed === null;
  modified = immune ? 0 : typed;

  const result = {
    levelTerm: term,
    base,
    modified,
    attack: stats.attack,
    defense: stats.defense,
    statClamped: stats.statClamped,
    crit,
    stab: !!src.stab,
    immune,
    minDamage: immune ? 0 : applyRoll(modified, ROLL_MIN),
    maxDamage: immune ? 0 : applyRoll(modified, ROLL_MAX),
  };

  if (immune) {
    result.roll = null;
    result.damage = 0;
  } else if (src.roll === null || src.roll === undefined) {
    result.roll = null;
    result.damage = null;
  } else {
    result.roll = int(src.roll, ROLL_MAX);
    result.damage = applyRoll(modified, result.roll);
  }

  return result;
}

// The chart-free half of STAB: whether the move's type is one of the
// attacker's. The percents still have to come from the caller's type chart,
// but this much is just set membership and both runtimes can own it.
function hasStab(moveType, attackerTypes) {
  if (!attackerTypes) return false;
  for (const t of attackerTypes) {
    if (t === moveType) return true;
  }
  return false;
}

module.exports = {
  compute,
  hasStab,
  clampStats,
  levelTerm,
  baseDamage,
  applyStab,
  applyTypeEffect,
  applyRoll,
  idiv,
  int,
  percents,
  ROLL_MIN,
  ROLL_MAX,
  STAT_CAP,
};
