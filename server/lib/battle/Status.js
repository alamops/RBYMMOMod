'use strict';

/*
 * Gen1 status: what stops a turn, what it costs at the end of one, and what it
 * does to a stat while it lasts.
 *
 * Node half of src/BattleSim/Status.lua; same parity contract as Damage.js,
 * and the function names are the Lua twin's on purpose, so the two files can
 * be read side by side by whoever is chasing a disagreement.
 *
 * Status is where a mediated battle is easiest to get subtly wrong, because
 * most of it is off-turn bookkeeping the player never sees a number for. The
 * quirks kept here on purpose:
 *
 *   * Sleep decrements *before* the move and the waking turn is still lost, so
 *     a 1-turn sleep costs a turn rather than none.
 *   * Freeze never self-thaws. In Gen1 only a fire move or a healing item ends
 *     it, so `thawed` is false for every roll and the roll is accepted only so
 *     callers do not have to special-case which statuses want one.
 *   * Paralysis stops the turn 63/256 of the time -- not 25% -- and quarters
 *     speed with a floor of 1.
 *   * Confusion decrements first and snaps out at zero, so the turn a mon
 *     comes out of confusion is a turn it gets to act.
 *
 * The confusion self-hit is a typeless 40-power move using the confused side's
 * own attack against its own defence, with no STAB, no type effectiveness, no
 * crit and no random roll (the roll is pinned at maximum). It runs through the
 * same Damage.compute as everything else rather than getting its own
 * arithmetic, so it cannot drift away from the main formula.
 *
 * Edge inputs match Lua: paralysisStop(undefined) coerces the roll to 255
 * (false), and confusionTick forwards atk/def aliases into Damage.compute.
 */

const Damage = require('./Damage.js');

const idiv = (a, b) => Math.floor(a / b);

const PARALYSIS_STOP_ROLL = 63; // out of 256
const CONFUSION_HIT_ROLL = 128; // out of 256
const CONFUSION_POWER = 40;
const RESIDUAL_DIVISOR = 16;

function int(value, fallback) {
  const n = Number(value);
  if (value === null || value === undefined || Number.isNaN(n)) return fallback;
  if (typeof value === 'boolean') return fallback;
  return Math.floor(n);
}

// ------- before-move gates

// A counter already at zero means "not asleep": the gate passes rather than
// decrementing into negatives, so a caller that asks the wrong question gets a
// harmless answer instead of a monster stuck asleep forever.
function sleepTick(turnsRemaining) {
  const left = Math.max(0, int(turnsRemaining, 0));
  if (left === 0) return { turnsRemaining: 0, wokeUp: false, canMove: true };
  return { turnsRemaining: left - 1, wokeUp: left - 1 === 0, canMove: false };
}

function sleepCanMove(turnsRemaining) {
  return sleepTick(turnsRemaining).canMove;
}

// The roll is accepted and ignored: there is no self-thaw in Gen1, and taking
// the argument keeps the gate's shape uniform for the turn machine that will
// call all four of these through one dispatcher.
function freezeTick(_roll) {
  return { thawed: false, canMove: false };
}

function freezeCanMove(_roll) {
  return false;
}

// Missing roll → 255, matching Lua int(roll, 255): 255 < 63 is false.
function paralysisStop(roll) {
  return int(roll, 255) < PARALYSIS_STOP_ROLL;
}

function paralysisTick(roll) {
  const stopped = paralysisStop(roll);
  return { fullyParalyzed: stopped, canMove: !stopped };
}

// max(1, floor(speed/4)) -- the floor matters at low speed, where a straight
// quarter would reach zero and the turn order would stop being defined.
function paralysisSpeed(speed) {
  return Math.max(1, idiv(Math.max(0, int(speed, 1)), 4));
}

function confusionSelfHit(roll) {
  return int(roll, 255) < CONFUSION_HIT_ROLL;
}

// state: { turnsRemaining, level, attack | atk, defense | def }
//
// The self-hit damage is computed here rather than left to the caller because
// the parameters that make it typeless are part of the *rule*, not the
// caller's choice: get one of them wrong and confusion hurts differently on
// the two runtimes.
function confusionTick(state, roll) {
  const s = state || {};
  let left = Math.max(0, int(s.turnsRemaining, 0));
  if (left > 0) left -= 1;

  if (left === 0) {
    return { turnsRemaining: 0, snappedOut: true, selfHit: false, canMove: true, selfDamage: 0 };
  }
  if (!confusionSelfHit(roll)) {
    return { turnsRemaining: left, snappedOut: false, selfHit: false, canMove: true, selfDamage: 0 };
  }

  // Forward atk/def aliases the way Lua does, so Damage.compute's stat() reads
  // whichever spelling the caller had.
  const hit = Damage.compute({
    level: s.level,
    power: CONFUSION_POWER,
    attack: s.attack,
    atk: s.atk,
    defense: s.defense,
    def: s.def,
    crit: false,
    stab: false,
    typeEffect: [100],
    roll: Damage.ROLL_MAX,
  });

  return {
    turnsRemaining: left,
    snappedOut: false,
    selfHit: true,
    canMove: false,
    selfDamage: hit.damage || 0,
  };
}

// ------- residuals

function sixteenth(maxHp) {
  return Math.max(1, idiv(Math.max(0, int(maxHp, 0)), RESIDUAL_DIVISOR));
}

function residualBurn(maxHp) {
  return sixteenth(maxHp);
}

function residualPoison(maxHp) {
  return sixteenth(maxHp);
}

// Toxic stacks by multiplying the same sixteenth by the badly-poisoned
// counter, which the turn machine increments once per tick.
function residualToxic(maxHp, toxicCounter) {
  return sixteenth(maxHp) * Math.max(1, int(toxicCounter, 1));
}

function burnAttack(attack) {
  return Math.max(1, idiv(Math.max(0, int(attack, 1)), 2));
}

// ------- dispatchers

/*
 * One entry point for the turn machine, so the call order lives in one place
 * rather than being reassembled at each of the sites that gate a move.
 * Returns the same objects the individual gates do, plus the status name, and
 * null for a status with no before-move gate at all (burn, poison, toxic) so
 * the caller can tell "passed the gate" from "there was no gate".
 */
function beforeMove(state, roll) {
  const s = state || {};
  let out = null;
  switch (s.status) {
    case 'sleep': out = sleepTick(s.turnsRemaining); break;
    case 'freeze': out = freezeTick(roll); break;
    case 'paralysis': out = paralysisTick(roll); break;
    case 'confusion': out = confusionTick(s, roll); break;
    default: return null;
  }
  out.status = s.status;
  return out;
}

// The end-of-turn half of the same seam. null when the status costs no HP.
function residual(state) {
  const s = state || {};
  if (s.status === 'burn') return residualBurn(s.maxHp);
  if (s.status === 'poison') return residualPoison(s.maxHp);
  if (s.status === 'toxic') return residualToxic(s.maxHp, s.toxicCounter);
  return null;
}

/*
 * evaluate(record) -- one door for a fixture-shaped record.
 *
 * The turn machine calls `beforeMove` and `residual`; this exists for the
 * parity suites, which drive a flat table where the fields present decide
 * which of the seams above a case is asking about (a paralysis record with a
 * `speed` is asking about the stat, one with a `roll` about the gate). Returns
 * null for a combination this module has no answer for, rather than guessing.
 */
function evaluate(record) {
  const r = record || {};
  switch (r.status) {
    case 'paralysis':
      if (r.speed !== undefined) return { speed: paralysisSpeed(r.speed) };
      return beforeMove(r, r.roll);
    case 'burn':
      if (r.attack !== undefined) return { attack: burnAttack(r.attack) };
      return { residualDamage: residualBurn(r.maxHp) };
    case 'poison':
    case 'toxic':
      return { residualDamage: residual(r) };
    default:
      return beforeMove(r, r.roll);
  }
}

module.exports = {
  beforeMove,
  residual,
  evaluate,
  sleepTick,
  sleepCanMove,
  freezeTick,
  freezeCanMove,
  paralysisStop,
  paralysisTick,
  paralysisSpeed,
  confusionSelfHit,
  confusionTick,
  residualBurn,
  residualPoison,
  residualToxic,
  burnAttack,
  int,
  PARALYSIS_STOP_ROLL,
  CONFUSION_HIT_ROLL,
  CONFUSION_POWER,
  RESIDUAL_DIVISOR,
};
