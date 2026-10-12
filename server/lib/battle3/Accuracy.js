'use strict';

/*
 * Gen 3 accuracy: percent domain, one combined stage, a 1..100 roll.
 *
 * Node twin of src/BattleSim3/Accuracy.lua (pokefirered/src/
 * battle_script_commands.c:1003 Cmd_accuracycheck, :570 sAccuracyStageRatios):
 *
 *   buff = accStage - evaStage          (evasion ignored when Foresighted)
 *   clamp -6..6; calc = floor(ratio[1] * moveAcc / ratio[2])
 *   Compound Eyes x130/100, Sand Veil in sand x80/100, Hustle on physical
 *   x80/100, BrightPowder / Lax Incense (HOLD_EFFECT_EVASION_UP) x(100-param)/100
 *   hit when roll(1, 100) <= calc
 *
 * The pre-roll gates (Protect, semi-invulnerable, Lock-On, never-miss effects,
 * Thunder in rain) are the turn machine's, because they decide whether a roll
 * is drawn at all; this module answers only the number.
 *
 * hit -> [hit, calc].
 *
 * Nothing here throws.
 */

const { int, truthy } = require('./lua.js');

// pokefirered/src/battle_script_commands.c:570
const STAGE = {
  '-6': [33, 100],
  '-5': [36, 100],
  '-4': [43, 100],
  '-3': [50, 100],
  '-2': [60, 100],
  '-1': [75, 100],
  0: [1, 1],
  1: [133, 100],
  2: [166, 100],
  3: [2, 1],
  4: [233, 100],
  5: [133, 50],
  6: [3, 1],
};

const ROLL_MIN = 1;
const ROLL_MAX = 100;

const HOLD_EVASION_UP = 22;

// opts: accStage, evaStage, foresight, compoundEyes, sandVeilInSand,
//       hustlePhysical, evasionItemParam (the BrightPowder param, or null)
// Returns the effective accuracy (an integer; may exceed 100).
function calc(moveAccuracy, optsIn) {
  const opts = optsIn || {};
  const acc = Math.max(0, int(moveAccuracy, 100));
  const accStage = int(opts.accStage, 0);
  const evaStage = int(opts.evaStage, 0);
  let buff;
  if (truthy(opts.foresight)) buff = accStage; else buff = accStage - evaStage;
  if (buff < -6) buff = -6; else if (buff > 6) buff = 6;
  const ratio = STAGE[buff];
  let c = Math.floor(ratio[0] * acc / ratio[1]);
  if (truthy(opts.compoundEyes)) c = Math.floor(c * 130 / 100);
  if (truthy(opts.sandVeilInSand)) c = Math.floor(c * 80 / 100);
  if (truthy(opts.hustlePhysical)) c = Math.floor(c * 80 / 100);
  if (opts.evasionItemParam !== undefined && opts.evasionItemParam !== null) {
    c = Math.floor(c * (100 - int(opts.evasionItemParam, 0)) / 100);
  }
  return c;
}

// Battler-level convenience: the same calc read off the Damage.js battler
// shape. `physical` and `sand` are the caller's.
function forBattlers(moveAccuracy, user, target, physical, sand) {
  const tMon = target && target.mon;
  const tHe = int(tMon ? tMon.holdEffect : null, 0);
  const tParam = int(tMon ? tMon.holdParam : null, 0);
  const accStage = user && user.stages && user.stages.acc != null ? user.stages.acc : 0;
  const evaStage = target && target.stages && target.stages.eva != null ? target.stages.eva : 0;
  return calc(moveAccuracy, {
    accStage,
    evaStage,
    foresight: target ? target.identified : null,
    compoundEyes: !!user && user.ability === 'COMPOUND_EYES',
    sandVeilInSand: truthy(sand) && !!target && target.ability === 'SAND_VEIL',
    hustlePhysical: truthy(physical) && !!user && user.ability === 'HUSTLE',
    evasionItemParam: (tHe === HOLD_EVASION_UP) ? tParam : null,
  });
}

// roll: 1..100. Returns [hit, calc].
function hit(calcValue, roll) {
  const c = int(calcValue, 0);
  return [int(roll, ROLL_MAX) <= c, c];
}

module.exports = {
  STAGE, ROLL_MIN, ROLL_MAX, calc, forBattlers, hit,
};
