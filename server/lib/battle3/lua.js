'use strict';

/*
 * The Lua semantics the Gen 3 twin leans on, spelled out once.
 *
 * server/lib/battle3/ mirrors src/BattleSim3/ line for line, and most of what
 * can go wrong in that mirror is not arithmetic but the two languages
 * disagreeing about small things: what counts as false, what `tonumber`
 * accepts, which way `%` rounds a negative. Every module here takes those
 * answers from this file instead of re-deriving them at the call site, so a
 * reader checking a line against its Lua twin only has to check the line.
 *
 *   * `truthy(v)`   Lua's truth: only nil and false are false. 0 and '' are
 *                   true in Lua and false in JS, and a sleep counter of 0 or an
 *                   empty name is exactly where the two runtimes would part.
 *   * `toNumber(v)` Lua's tonumber: a number, or a string that spells one;
 *                   booleans and null are refused (Number(true) is 1).
 *   * `int(v, fb)`  every module's `int(value, fallback)`: floor(tonumber(v)),
 *                   or the fallback for anything tonumber refuses (NaN too).
 *   * `mod(a, b)`   Lua's `%`, floored: the sign follows the divisor. JS `%`
 *                   truncates, and the two differ on every negative operand.
 *   * `isTable(v)`  Lua's `type(v) == "table"`: objects and arrays, not null.
 *   * `at(t, i)`    Lua's `t[i]` on a list whose indices stay 1-based as
 *                   values (a party index, a move slot): the array behind it
 *                   is 0-based, so every read goes through here rather than
 *                   open-coding the minus one.
 *   * `fmt(p, ...)` Lua's `p:format(...)` for the `%s`-only sentence
 *                   templates the sim uses (surplus arguments are ignored,
 *                   as Lua ignores them).
 *
 * Nothing here throws.
 */

const NUMERIC = /^[+-]?(?:(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?|0[xX][0-9a-fA-F]+)$/;

function toNumber(value) {
  if (typeof value === 'number') return Number.isNaN(value) ? null : value;
  if (typeof value === 'string') {
    const s = value.trim();
    if (s === '' || !NUMERIC.test(s)) return null;
    const n = Number(s);
    return Number.isNaN(n) ? null : n;
  }
  return null;
}

function int(value, fallback) {
  const n = toNumber(value);
  if (n === null) return fallback;
  return Math.floor(n);
}

function truthy(value) {
  return value !== undefined && value !== null && value !== false;
}

function mod(a, b) {
  return a - Math.floor(a / b) * b;
}

function isTable(value) {
  return typeof value === 'object' && value !== null;
}

const own = (object, key) => isTable(object) && Object.prototype.hasOwnProperty.call(object, key);

function at(list, index) {
  if (!isTable(list) || typeof index !== 'number') return undefined;
  return list[index - 1];
}

function fmt(pattern, ...args) {
  let i = 0;
  return String(pattern).replace(/%s/g, () => {
    const v = args[i];
    i += 1;
    return String(v);
  });
}

module.exports = {
  toNumber, int, truthy, mod, isTable, own, at, fmt,
};
