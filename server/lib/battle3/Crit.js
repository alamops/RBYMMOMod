'use strict';

/*
 * Gen 3 critical hits: a five-step stage ladder.
 *
 * Node twin of src/BattleSim3/Crit.lua (pokefirered/src/battle_script_commands.c
 * :1170 Cmd_critcalc):
 *
 *   stage = +2 Focus Energy (or Dire Hit), +1 high-crit move effect, +1 Scope
 *           Lens, +2 Lucky Punch on Chansey, +2 Stick on Farfetch'd; cap 4
 *   chance = 1 in { 16, 8, 4, 3, 2 }[stage]; critical when roll(0, n-1) == 0
 *
 * pret reads the HOLD EFFECT, which is what the sheet carries. Battle Armor /
 * Shell Armor skip the roll entirely at the call site (Damage.calc).
 *
 * check -> [isCrit, chance].
 *
 * Nothing here throws.
 */

const { int, isTable, truthy } = require('./lua.js');

const CHANCE = { 0: 16, 1: 8, 2: 4, 3: 3, 4: 2 };
const MAX_STAGE = 4;
const MULTIPLIER = 2;

// pokefirered/src/battle_script_commands.c:1170 (sHighCritEffects via move effect)
const HIGH_CRIT_EFFECTS = { 43: true, 75: true, 200: true, 209: true };

const HOLD_SCOPE_LENS = 41;
const HOLD_LUCKY_PUNCH = 63;
const HOLD_STICK = 66;
const SPECIES_CHANSEY = 113;
const SPECIES_FARFETCHD = 83;

function isHighCrit(effect) {
  return HIGH_CRIT_EFFECTS[int(effect, -1)] === true;
}

// attacker: the battler shape Damage.js documents (focusEnergy, mon.holdEffect,
// speciesNum). move: a move row (effect).
function stage(attacker, move) {
  let s = 0;
  if (attacker && truthy(attacker.focusEnergy)) s += 2;
  if (isTable(move) && isHighCrit(move.effect)) s += 1;
  const he = int(attacker && attacker.mon ? attacker.mon.holdEffect : null, 0);
  const species = int(attacker ? attacker.speciesNum : null, 0);
  if (he === HOLD_SCOPE_LENS) s += 1;
  if (he === HOLD_LUCKY_PUNCH && species === SPECIES_CHANSEY) s += 2;
  if (he === HOLD_STICK && species === SPECIES_FARFETCHD) s += 2;
  if (s > MAX_STAGE) s = MAX_STAGE;
  return s;
}

// Stage from explicit flags (the vector pack's view of the same ladder).
function stageFrom(optsIn) {
  const opts = optsIn || {};
  let s = 0;
  if (truthy(opts.focusEnergy)) s += 2;
  if (truthy(opts.highCrit)) s += 1;
  if (truthy(opts.scopeLens)) s += 1;
  if (truthy(opts.speciesItem)) s += 2;
  return Math.min(MAX_STAGE, s);
}

function chance(s) {
  return CHANCE[Math.max(0, Math.min(MAX_STAGE, int(s, 0)))];
}

// roll: 0..chance-1. Returns [isCrit, chance].
function check(s, roll) {
  const c = chance(s);
  return [int(roll, c) === 0, c];
}

module.exports = {
  CHANCE, MAX_STAGE, MULTIPLIER, HIGH_CRIT_EFFECTS, isHighCrit, stage, stageFrom, chance, check,
};
