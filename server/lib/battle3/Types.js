'use strict';

/*
 * Gen 3 types: the pret TYPE_* ids, the physical/special split, and the
 * ORDERED type chart walk.
 *
 * Node twin of src/BattleSim3/Types.lua (pokefirered/src/battle_script_commands.c
 * :1274 Cmd_typecalc). The ids are pret enum values and are code, not data. The
 * chart itself IS data, so it is never written here: it arrives per battle as
 * the ruleset's `typeTable`, a flat list of `atk, def, mult` triples in cart
 * order, with the multiplier in tenths and the Foresight sentinel `-1, -1, 0` in
 * place (docs/plans/gen3-battle-sheet.md §3.1).
 *
 * Order is the whole point: the cart applies one row at a time and floors after
 * each, in TABLE order, so a percent matrix applied in defender order drifts by
 * one HP on some matchups. The sentinel ends the walk for a Foresighted
 * defender, which is how Foresight removes the ghost immunities.
 *
 * Multi-value returns come back as arrays: typeCalc -> [dmg, flags, product],
 * effectivenessOf -> [product, flags].
 *
 * Nothing here throws.
 */

const { int, isTable, truthy } = require('./lua.js');

const ID = {
  NORMAL: 0,
  FIGHTING: 1,
  FLYING: 2,
  POISON: 3,
  GROUND: 4,
  ROCK: 5,
  BUG: 6,
  GHOST: 7,
  STEEL: 8,
  MYSTERY: 9,
  FIRE: 10,
  WATER: 11,
  GRASS: 12,
  ELECTRIC: 13,
  PSYCHIC: 14,
  ICE: 15,
  DRAGON: 16,
  DARK: 17,
};
const MAX = 17;

// The sentinel row that separates the Foresight-skippable tail.
const FORESIGHT_SENTINEL = -1;

// pret IS_TYPE_PHYSICAL(type) ((type) < TYPE_MYSTERY). `specialTypes`, when a
// ruleset carries one, is a set { [typeId]: true } of the special types and
// every other type except MYSTERY is physical.
function isPhysical(typeId, specialTypes) {
  const t = int(typeId, 0);
  if (t === ID.MYSTERY) return false;
  if (isTable(specialTypes)) return specialTypes[t] !== true;
  return t < ID.MYSTERY;
}

function isSpecial(typeId, specialTypes) {
  const t = int(typeId, 0);
  if (t === ID.MYSTERY) return false;
  return !isPhysical(t, specialTypes);
}

// Copy a flat triple list into a clean integer array, dropping a trailing
// partial triple. A cell that is not an integer makes its row neutral (atk -2
// never matches a real type), so one bad cell cannot shift every later triple.
function copyTable(raw) {
  if (!Array.isArray(raw)) return null;
  const out = [];
  const n = raw.length - (raw.length % 3);
  for (let i = 1; i <= n; i += 3) {
    let a = int(raw[i - 1], null);
    let d = int(raw[i], null);
    let m = int(raw[i + 1], null);
    if (a === null || d === null || m === null || m < 0) {
      a = -2;
      d = -2;
      m = 10;
    }
    out.push(a, d, m);
  }
  if (out.length === 0) return null;
  return out;
}

// pokefirered/src/battle_script_commands.c:1274
//
// Returns [dmg (null in, null out), flags { super, notVery, immune }, product]
// where product is every multiplier applied, in tenths-of-tenths (100 neutral,
// 0 immune, 400 = 4x) -- an integer, so no runtime ever compares floats.
function typeCalc(table, atkType, def1In, def2In, dmgIn, foresight) {
  const atk = int(atkType, 0);
  const def1 = int(def1In, 0);
  let def2 = int(def2In, null);
  if (def2 === null) def2 = def1;
  let dmg = (dmgIn === undefined) ? null : dmgIn;
  const flags = { super: false, notVery: false, immune: false };
  let product = 100;
  const t = Array.isArray(table) ? table : null;
  if (!t) return [dmg, flags, product];

  const modulate = (mult) => {
    product = Math.floor(product * mult / 10);
    if (dmg !== null) {
      dmg = Math.floor(dmg * mult / 10);
      if (dmg === 0 && mult !== 0) dmg = 1;
    }
    if (mult === 0) {
      flags.immune = true;
      flags.super = false;
      flags.notVery = false;
    } else if (mult === 5 && !flags.immune) {
      if (flags.super) flags.super = false; else flags.notVery = true;
    } else if (mult === 20 && !flags.immune) {
      if (flags.notVery) flags.notVery = false; else flags.super = true;
    }
  };

  let i = 1;
  while (i + 2 <= t.length) {
    const a = t[i - 1];
    const d = t[i];
    const m = t[i + 1];
    if (a === FORESIGHT_SENTINEL) {
      if (truthy(foresight)) break;
    } else if (a === atk) {
      if (d === def1) modulate(m);
      if (d === def2 && def1 !== def2) modulate(m);
    }
    i += 3;
  }
  return [dmg, flags, product];
}

// The engine's convenience reading: is this move immune / super / not very.
function effectivenessOf(table, atkType, def1, def2, foresight) {
  const [, flags, product] = typeCalc(table, atkType, def1, def2, null, foresight);
  return [product, flags];
}

module.exports = {
  ID, MAX, FORESIGHT_SENTINEL, isPhysical, isSpecial, copyTable, typeCalc, effectivenessOf,
};
