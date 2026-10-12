'use strict';

/*
 * Gen 3 major status: who can take which condition, and what each one costs.
 *
 * Node twin of src/BattleSim3/Status.lua (pokefirered/src/battle_util.c:805,
 * battle_script_commands.c:2150 / 2356):
 *
 *   * sleep lasts roll(0,3)+2 = 2..5 turns; Early Bird counts it down twice
 *   * burn / poison chip max(1, floor(maxHp / 8)) at the end of the turn
 *   * toxic chip max(1, floor(maxHp / 16)) * n, n = 1..15, counted per switch-in
 *   * burn halves physical Attack (Damage.base), paralysis quarters Speed
 *   * freeze thaws on roll(0,4) == 0, paralysis stops on roll(0,3) == 0
 *
 * Status tokens are the wire's (SLP PSN BRN FRZ PAR TOX) end to end.
 *
 * Multi-value returns as arrays: sleepTick -> [left, woke],
 * chip -> [amount, counter], canApply -> [ok, reason].
 *
 * Nothing here throws.
 */

const Types = require('./Types.js');
const { int, own } = require('./lua.js');

const TOKENS = {
  SLP: true, PSN: true, BRN: true, FRZ: true, PAR: true, TOX: true,
};

// Legacy spellings a sheet may carry (BattleSim2's words, the engine's words).
const ALIASES = {
  sleep: 'SLP',
  poison: 'PSN',
  burn: 'BRN',
  freeze: 'FRZ',
  paralysis: 'PAR',
  toxic: 'TOX',
  SLEEP: 'SLP',
  POISON: 'PSN',
  BURN: 'BRN',
  FREEZE: 'FRZ',
  PARALYSIS: 'PAR',
  TOXIC: 'TOX',
};

const THAW_ROLL_MAX = 4; // roll(0,4); thaw on 0
const PARALYSIS_ROLL_MAX = 3; // roll(0,3); stuck on 0
const TOXIC_MAX = 15;

function normalise(token) {
  if (token === undefined || token === null || token === '' || token === 0) return null;
  if (typeof token !== 'string') return null;
  if (own(TOKENS, token)) return token;
  return own(ALIASES, token) ? ALIASES[token] : null;
}

// pokefirered/src/battle_script_commands.c:2356 (adapter rollSleepTurns)
function sleepTurns(rng) {
  return (rng ? rng.roll(0, 3) : 0) + 2;
}

// One sleep tick (pret battle_util.c:1268): [counter left, woke this turn].
// Early Bird subtracts two. A mon at 0 is awake.
function sleepTick(turns, earlyBird) {
  let left = Math.max(0, int(turns, 0));
  const toSub = (earlyBird !== undefined && earlyBird !== null && earlyBird !== false) ? 2 : 1;
  if (left < toSub) left = 0; else left -= toSub;
  return [left, left === 0];
}

// pokefirered/src/battle_util.c:805-850
// Returns [amount, newToxicCounter] (null for non-toxic; [null, null] for none).
function chip(statusIn, maxHp, toxicCounter) {
  const status = normalise(statusIn);
  const mhp = Math.max(1, int(maxHp, 1));
  if (status === 'PSN' || status === 'BRN') {
    let loss = Math.floor(mhp / 8);
    if (loss === 0) loss = 1;
    return [loss, null];
  }
  if (status === 'TOX') {
    let loss = Math.floor(mhp / 16);
    if (loss === 0) loss = 1;
    let c = Math.max(0, int(toxicCounter, 0));
    if (c < TOXIC_MAX) c += 1;
    return [loss * c, c];
  }
  return [null, null];
}

function paralysisSpeed(speed) {
  return Math.floor(Math.max(0, int(speed, 0)) / 4);
}

// What stops a condition from landing at all, given the facts the turn machine
// knows. ctx: { sun, uproar, safeguard, ignoreSafeguard }.
// Returns [ok, reason] with reason one of status | safeguard | type | ability
// | sun | uproar | none (and null when ok).
function canApply(b, statusIn, ctxIn) {
  const ctx = ctxIn || {};
  const status = normalise(statusIn);
  if (!b || !status) return [false, 'none'];
  if (normalise(b.mon ? b.mon.status : null)) return [false, 'status'];
  const t = (v) => v !== undefined && v !== null && v !== false;
  if (t(ctx.safeguard) && !t(ctx.ignoreSafeguard)) return [false, 'safeguard'];
  const ab = b.ability;
  const isType = (ty) => b.type1 === ty || b.type2 === ty;
  if (status === 'PSN' || status === 'TOX') {
    if (isType(Types.ID.POISON) || isType(Types.ID.STEEL)) return [false, 'type'];
    if (ab === 'IMMUNITY') return [false, 'ability'];
  } else if (status === 'BRN') {
    if (isType(Types.ID.FIRE)) return [false, 'type'];
    if (ab === 'WATER_VEIL') return [false, 'ability'];
  } else if (status === 'FRZ') {
    if (isType(Types.ID.ICE)) return [false, 'type'];
    if (t(ctx.sun)) return [false, 'sun'];
    if (ab === 'MAGMA_ARMOR') return [false, 'ability'];
  } else if (status === 'PAR') {
    if (ab === 'LIMBER') return [false, 'ability'];
  } else if (status === 'SLP') {
    if (ab !== 'SOUNDPROOF' && t(ctx.uproar)) return [false, 'uproar'];
    if (ab === 'INSOMNIA' || ab === 'VITAL_SPIRIT') return [false, 'ability'];
  }
  return [true, null];
}

// Sentence fragments the turn machine narrates with (our own words, not ROM text).
const INFLICT_TEXT = {
  SLP: ' fell asleep!',
  PSN: ' was poisoned!',
  BRN: ' was burned!',
  FRZ: ' was frozen solid!',
  PAR: ' is paralyzed! It may be unable to move!',
  TOX: ' is badly poisoned!',
};
const CHIP_TEXT = {
  PSN: ' is hurt by poison!',
  TOX: ' is hurt by poison!',
  BRN: ' is hurt by its burn!',
};
const WORD = {
  PSN: 'poison', TOX: 'poison', SLP: 'sleep', PAR: 'paralysis', BRN: 'burn', FRZ: 'ice',
};

module.exports = {
  TOKENS,
  ALIASES,
  THAW_ROLL_MAX,
  PARALYSIS_ROLL_MAX,
  TOXIC_MAX,
  normalise,
  sleepTurns,
  sleepTick,
  chip,
  paralysisSpeed,
  canApply,
  INFLICT_TEXT,
  CHIP_TEXT,
  WORD,
};
