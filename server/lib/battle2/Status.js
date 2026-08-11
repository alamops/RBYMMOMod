'use strict';

/*
 * Gen2 status: before-move gates and end-of-turn residuals.
 *
 * Node twin of src/BattleSim2/Status.lua. Differs from Gen1 Status.js:
 *
 *   * Freeze thaws 1/5 (roll % 5 === 0).
 *   * Burn and poison tick 1/8 max HP (not 1/16). Burn still halves physical
 *     Attack via burnAttack — SpA is untouched.
 *   * Toxic still ramps as max(1, floor(maxHp * counter / 16)).
 *   * Paralysis full-stops 1/4 of the time (roll % 4 === 0), not Gen1's 63/256;
 *     speed still quarters.
 *   * Sleep wakes *and acts* on the turn the counter hits zero.
 *   * Confusion self-hit still routes through Damage.compute (now Gen2).
 */

const Damage = require('./Damage.js');

const idiv = (a, b) => Math.floor(a / b);

const PARALYSIS_SKIP_CHANCE = 4;
const THAW_CHANCE = 5;
const CONFUSION_HIT_ROLL = 128;
const CONFUSION_POWER = 40;
const RESIDUAL_DIVISOR = 8;
const TOXIC_DIVISOR = 16;

function int(value, fallback) {
  const n = Number(value);
  if (value === null || value === undefined || Number.isNaN(n)) return fallback;
  if (typeof value === 'boolean') return fallback;
  return Math.floor(n);
}

// ------- before-move gates

function sleepTick(turnsRemaining) {
  let left = Math.max(0, int(turnsRemaining, 0));
  if (left === 0) {
    return { turnsRemaining: 0, wokeUp: false, canMove: true };
  }
  left -= 1;
  if (left === 0) {
    // Gen2: waking turn is free — the mon acts this turn.
    return { turnsRemaining: 0, wokeUp: true, canMove: true };
  }
  return { turnsRemaining: left, wokeUp: false, canMove: false };
}

function sleepCanMove(turnsRemaining) {
  return sleepTick(turnsRemaining).canMove;
}

// roll: 0..THAW_CHANCE-1 conceptually; thaw when roll % 5 === 0.
// Missing roll → 1 (Lua int(roll, 1)): not thawed.
function freezeTick(roll) {
  const thawed = int(roll, 1) % THAW_CHANCE === 0;
  return { thawed, canMove: thawed };
}

function freezeCanMove(roll) {
  return freezeTick(roll).canMove;
}

// Missing roll → 1: 1 % 4 !== 0 → not stopped.
function paralysisStop(roll) {
  return int(roll, 1) % PARALYSIS_SKIP_CHANCE === 0;
}

function paralysisTick(roll) {
  const stopped = paralysisStop(roll);
  return { fullyParalyzed: stopped, canMove: !stopped };
}

function paralysisSpeed(speed) {
  return Math.max(1, idiv(Math.max(0, int(speed, 1)), 4));
}

function confusionSelfHit(roll) {
  return int(roll, 255) < CONFUSION_HIT_ROLL;
}

// state: { turnsRemaining, level, attack | atk, defense | def }
function confusionTick(state, roll) {
  const s = state || {};
  let left = Math.max(0, int(s.turnsRemaining, 0));
  if (left > 0) left -= 1;

  if (left === 0) {
    return {
      turnsRemaining: 0, snappedOut: true, selfHit: false,
      canMove: true, selfDamage: 0,
    };
  }
  if (!confusionSelfHit(roll)) {
    return {
      turnsRemaining: left, snappedOut: false, selfHit: false,
      canMove: true, selfDamage: 0,
    };
  }

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
    physical: true,
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

function eighth(maxHp) {
  return Math.max(1, idiv(Math.max(0, int(maxHp, 0)), RESIDUAL_DIVISOR));
}

function residualBurn(maxHp) {
  return eighth(maxHp);
}

function residualPoison(maxHp) {
  return eighth(maxHp);
}

function residualToxic(maxHp, toxicCounter) {
  const counter = Math.max(1, int(toxicCounter, 1));
  return Math.max(1, idiv(Math.max(0, int(maxHp, 0)) * counter, TOXIC_DIVISOR));
}

function burnAttack(attack) {
  return Math.max(1, idiv(Math.max(0, int(attack, 1)), 2));
}

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

function residual(state) {
  const s = state || {};
  if (s.status === 'burn') return residualBurn(s.maxHp);
  if (s.status === 'poison') return residualPoison(s.maxHp);
  if (s.status === 'toxic') return residualToxic(s.maxHp, s.toxicCounter);
  return null;
}

/*
 * evaluate(record) — fixture-shaped dispatcher, same role as Gen1 Status.js.
 */
function evaluate(record) {
  const r = record || {};
  switch (r.status) {
    case 'paralysis':
      if (r.speed !== undefined && r.speed !== null) {
        return { speed: paralysisSpeed(r.speed) };
      }
      return beforeMove(r, r.roll);
    case 'burn':
      if (r.attack !== undefined && r.attack !== null) {
        return { attack: burnAttack(r.attack) };
      }
      return { residualDamage: residualBurn(r.maxHp) };
    case 'poison':
      return { residualDamage: residualPoison(r.maxHp) };
    case 'toxic':
      return { residualDamage: residualToxic(r.maxHp, r.toxicCounter) };
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
  PARALYSIS_SKIP_CHANCE,
  THAW_CHANCE,
  CONFUSION_HIT_ROLL,
  CONFUSION_POWER,
  RESIDUAL_DIVISOR,
  TOXIC_DIVISOR,
};
