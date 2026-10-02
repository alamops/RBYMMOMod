'use strict';

/*
 * Gen 3 field state: weather, the per-side conditions, and the end-of-turn
 * order.
 *
 * Node twin of src/BattleSim3/Field.lua (pokefirered/src/battle_util.c:453
 * FIELD_PHASES_ORDER, :722 BATTLER_PHASES_ORDER, :1064 POST_PHASES_ORDER). The
 * residual handlers themselves live in Residual.js, because every one of them
 * writes the event stream; this file is the order they run in and the numbers
 * they use.
 *
 * Nothing here throws.
 */

const Types = require('./Types.js');
const Damage = require('./Damage.js');
const { int, truthy } = require('./lua.js');

const WEATHER = {
  RAIN: true, SUN: true, SAND: true, HAIL: true,
};
const WEATHER_TURNS = 5; // Rain Dance / Sunny Day / Sandstorm / Hail
const SCREEN_TURNS = 5; // Reflect / Light Screen
const SAFEGUARD_TURNS = 5;
const MIST_TURNS = 5;
const WEATHER_CHIP_DENOM = 16;
const TRAP_CHIP_DENOM = 16;

// pokefirered/src/battle_util.c:453
const FIELD_PHASES = ['reflect', 'light_screen', 'mist', 'safeguard', 'wish', 'weather'];

// pokefirered/src/battle_util.c:722 (the enum order is the run order):
// ENDTURN_ITEMS1 is `held_items` (ItemBattleEffects(NORMAL, battler, FALSE)),
// ENDTURN_ITEMS2 after Yawn is `held_items2` (the same with moveTurn TRUE --
// the status cures, a Yawn sleep included).  `volatiles` is the sim's own
// per-turn bookkeeping, not a cart step.
const BATTLER_PHASES = [
  'ingrain', 'abilities', 'held_items', 'leech_seed', 'status_chip', 'nightmare',
  'curse', 'partial_trap', 'uproar', 'thrash', 'disable', 'encore', 'lock_on',
  'charge', 'taunt', 'yawn', 'held_items2', 'volatiles',
];

// pokefirered/src/battle_util.c:1064
const POST_PHASES = ['fainted_actions', 'future_sight', 'perish_song'];

// A battler that faints in one of these stops its remaining end-of-turn steps.
const FAINT_HALT = {
  ingrain: true,
  leech_seed: true,
  status_chip: true,
  nightmare: true,
  curse: true,
  partial_trap: true,
};

function kind(weather) {
  if (typeof weather !== 'string') return null;
  const w = weather.toUpperCase();
  if (w === 'RAIN' || w === 'RAINY' || w === 'DOWNPOUR') return 'RAIN';
  if (w === 'SUN' || w === 'SUNNY') return 'SUN';
  if (w === 'SAND' || w === 'SANDSTORM') return 'SAND';
  if (w === 'HAIL') return 'HAIL';
  return null;
}

// pokefirered/include/battle_util.h:49 WEATHER_HAS_EFFECT: no Cloud Nine / Air
// Lock on any standing battler.
function effective(weather, battlers) {
  const k = kind(weather);
  if (!k) return null;
  for (const b of (battlers || [])) {
    if (b.ability === 'CLOUD_NINE' || b.ability === 'AIR_LOCK') return null;
  }
  return k;
}

function chip(maxHp, denom) {
  const d = (denom !== undefined && denom !== null && denom !== false) ? denom : WEATHER_CHIP_DENOM;
  return Math.max(1, Math.floor(Math.max(0, int(maxHp, 16)) / d));
}

// Who a sandstorm / hail spares: Rock / Ground / Steel and Sand Veil in sand,
// Ice in hail, and anyone hidden underground or underwater.
function weatherImmune(b, k) {
  const semi = b.semi === 'UNDERGROUND' || b.semi === 'UNDERWATER';
  const is = (t) => b.type1 === t || b.type2 === t;
  if (k === 'SAND') {
    return is(Types.ID.ROCK) || is(Types.ID.STEEL) || is(Types.ID.GROUND)
      || b.ability === 'SAND_VEIL' || semi;
  }
  if (k === 'HAIL') return is(Types.ID.ICE) || semi;
  return true;
}

// pokefirered/src/battle_main.c:3399 GetWhoStrikesFirst's speed (engine
// speed_of, engine.lua:203): Swift Swim / Chlorophyll x2 in their weather, the
// Speed stage, badge 3 x110/100 floored (the battler's own trainer's, which only
// side a carries against the computer -- Turn.BADGE_MODES; engine.lua:221),
// Macho Brace halves, paralysis quarters, and Quick Claw makes it the maximum
// when this turn's random number falls under 0xFFFF * param / 100.
// `quickClawNumber` is the turn's roll(0, 65535), or null when none was drawn.
// Escape odds read the raw stat, not this (Turn.js's run).
const HOLD_MACHO_BRACE = 24;
const HOLD_QUICK_CLAW = 26;
const QUICK_CLAW_SPEED = 0xFFFFFFFF;

function speed(b, weather, quickClawNumber) {
  if (!b) return 0;
  let spe = int(b.stats ? b.stats.spe : null, 1);
  let mul = 1;
  if ((b.ability === 'SWIFT_SWIM' && weather === 'RAIN') || (b.ability === 'CHLOROPHYLL' && weather === 'SUN')) {
    mul = 2;
  }
  spe = Damage.applyStage(spe * mul, b.stages ? b.stages.spe : null);
  if (Damage.hasBadge(b, 3)) spe = Math.floor(spe * 110 / 100);
  const mon = truthy(b.mon) ? b.mon : {};
  const he = (int(mon.heldItem, 0) !== 0) ? int(mon.holdEffect, 0) : 0;
  const param = int(mon.holdParam, 0);
  if (he === HOLD_MACHO_BRACE) spe = Math.floor(spe / 2);
  if (mon.status === 'PAR') spe = Math.floor(spe / 4);
  if (he === HOLD_QUICK_CLAW && quickClawNumber !== undefined && quickClawNumber !== null
      && quickClawNumber < Math.floor(0xFFFF * param / 100)) {
    spe = QUICK_CLAW_SPEED;
  }
  return spe;
}

// The turn-order policy (sheet doc §6): rows { pri, spe, order } sorted by
// priority, then speed, then `order`; every group tied on both priority and
// speed spends ONE rng.roll(0, 255), and a value >= tieRoll reverses the group.
// A group of one draws nothing. Sorts in place and returns the rows.
//
// `order` is unique per row, so the comparator is a total order and JS's
// stable sort lands on the same permutation Lua's table.sort does.
function sortRows(rows, rng, tieRoll) {
  if (rows.length <= 1) return rows;
  rows.sort((x, y) => {
    if (x.pri !== y.pri) return x.pri > y.pri ? -1 : 1;
    if (x.spe !== y.spe) return x.spe > y.spe ? -1 : 1;
    if (x.order !== y.order) return x.order < y.order ? -1 : 1;
    return 0;
  });
  const threshold = (tieRoll !== undefined && tieRoll !== null && tieRoll !== false) ? tieRoll : 128;
  let i = 1;
  while (i <= rows.length) {
    let j = i;
    while (j < rows.length && rows[j].pri === rows[i - 1].pri && rows[j].spe === rows[i - 1].spe) j += 1;
    if (j > i && rng.roll(0, 255) >= threshold) {
      for (let lo = i; lo <= i + Math.floor((j - i) / 2); lo += 1) {
        const hi = j - (lo - i);
        const tmp = rows[lo - 1];
        rows[lo - 1] = rows[hi - 1];
        rows[hi - 1] = tmp;
      }
    }
    i = j + 1;
  }
  return rows;
}

// One side's conditions, fresh.
function newSide() {
  return {
    reflectTurns: 0,
    lightScreenTurns: 0,
    mistTurns: 0,
    safeguardTurns: 0,
    spikes: 0,
    wish: [], // [{ turns, wisher (name), slot }]
    futureSight: [], // [{ turns, damage, moveNum, move, attackerSlot, targetSlot, doom }]
    followMe: null, // the battler drawing attacks this turn
  };
}

// pokefirered/src/battle_script_commands.c:793 sTerrainToType (Camouflage) and
// :741 sNaturePowerMoves / :9226 sSecretPowerEffects, keyed by BATTLE_TERRAIN_*.
const TERRAIN_TYPE = {
  0: Types.ID.GRASS,
  1: Types.ID.GRASS,
  2: Types.ID.GROUND,
  3: Types.ID.WATER,
  4: Types.ID.WATER,
  5: Types.ID.WATER,
  6: Types.ID.ROCK,
  7: Types.ID.ROCK,
  8: Types.ID.NORMAL,
  9: Types.ID.NORMAL,
};
const NATURE_POWER_MOVE = {
  0: 78, 1: 75, 2: 89, 3: 56, 4: 57, 5: 61, 6: 157, 7: 247, 8: 129, 9: 129,
};
const SECRET_POWER_EFFECT = {
  0: 'POISON',
  1: 'SLEEP',
  2: 'ACC_MINUS_1',
  3: 'DEF_MINUS_1',
  4: 'ATK_MINUS_1',
  5: 'SPD_MINUS_1',
  6: 'CONFUSION',
  7: 'FLINCH',
  8: 'PARALYSIS',
  9: 'PARALYSIS',
};
const DEFAULT_TERRAIN = 8;

module.exports = {
  WEATHER,
  WEATHER_TURNS,
  SCREEN_TURNS,
  SAFEGUARD_TURNS,
  MIST_TURNS,
  WEATHER_CHIP_DENOM,
  TRAP_CHIP_DENOM,
  FIELD_PHASES,
  BATTLER_PHASES,
  POST_PHASES,
  FAINT_HALT,
  kind,
  effective,
  chip,
  weatherImmune,
  QUICK_CLAW_SPEED,
  speed,
  sortRows,
  newSide,
  TERRAIN_TYPE,
  NATURE_POWER_MOVE,
  SECRET_POWER_EFFECT,
  DEFAULT_TERRAIN,
};
