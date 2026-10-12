'use strict';

/*
 * Gen2 status: before-move gates and end-of-turn residuals.
 *
 * Node twin of src/BattleSim2/Status.lua. Differs from Gen1 Status.js:
 *
 *   * Freeze never thaws before a move (CheckTurn draws nothing for it);
 *     HandleDefrost thaws between turns under DEFROST_BYTE (`defrosts`).
 *   * Burn and poison tick 1/8 max HP (not 1/16), GetEighthMaxHP's bytes
 *     (Items.eighth). Burn still halves physical Attack via burnAttack —
 *     SpA is untouched.
 *   * Toxic ramps as GetSixteenthMaxHP (Items.sixteenth) times the count, a
 *     16-bit sum.
 *   * Paralysis full-stops on a BattleRandom byte under `25 percent` -- 63,
 *     so 63/256 (CheckTurn's `cp 25 percent / ret nc`) -- not the 1/4 the
 *     referee used to roll; speed still quarters.
 *   * Sleep draws no byte in CheckTurn (the caller draws for paralysis alone).
 *   * Sleep wakes *and acts* on the turn the counter hits zero.
 *   * Confusion self-hit routes through Damage.compute as HitConfusion runs
 *     BattleCommand_DamageCalc and nothing after it: power 40, no crit, no
 *     STAB, no matchup, no variation. The caller hands in the attack /
 *     defense HitSelfInConfusion builds and, as `itemBoostPercent`, the
 *     type-boost item DamageCalc finds for the SELECTED move's type -- both
 *     cart bugs; the Lua twin's header names them.
 */

const Damage = require('./Damage.js');
// GetEighthMaxHP / GetSixteenthMaxHP, the residuals' HP arithmetic.
const Items = require('./Items.js');

const idiv = (a, b) => Math.floor(a / b);

// CheckTurn's `cp 25 percent`: a byte under 63 is a full paralysis.
const PARALYSIS_STOP_BYTE = 63;
// HandleDefrost's `cp 10 percent`: 25 (a byte under it thaws).
const DEFROST_BYTE = 25;
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

// CheckTurn's freeze gate: frozen solid, whatever the roll (none is drawn).
function freezeTick() {
  return { thawed: false, canMove: false };
}

// HandleDefrost's roll for one frozen battler.
function defrosts(byte) {
  return int(byte, 255) < DEFROST_BYTE;
}

function freezeCanMove(roll) {
  return freezeTick(roll).canMove;
}

// roll: the BattleRandom byte; stop under PARALYSIS_STOP_BYTE.
function paralysisStop(roll) {
  return int(roll, 255) < PARALYSIS_STOP_BYTE;
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

  return {
    turnsRemaining: left,
    snappedOut: false,
    selfHit: true,
    canMove: false,
    selfDamage: selfHitDamage(s),
  };
}

// HitConfusion's damage on its own: the confusion gate's self-hit above, and
// the disobedient monster's "won't obey!" self-hit (BattleCommand_CheckObedience
// calls the same HitConfusion). `state` carries level, attack, defense and the
// optional itemBoostPercent.
function selfHitDamage(state) {
  const s = state || {};
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
    itemBoostPercent: s.itemBoostPercent,
  });
  return hit.damage || 0;
}

// ------- residuals

function eighth(maxHp) {
  return Items.eighth(maxHp);
}

function residualBurn(maxHp) {
  return eighth(maxHp);
}

function residualPoison(maxHp) {
  return eighth(maxHp);
}

function residualToxic(maxHp, toxicCounter) {
  const counter = Math.max(1, int(toxicCounter, 1));
  return (Items.sixteenth(maxHp) * counter) % 65536;
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
    case 'freeze':
      if (r.defrostByte !== undefined && r.defrostByte !== null) {
        return { defrosted: defrosts(r.defrostByte) };
      }
      return beforeMove(r, r.roll);
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
  defrosts,
  paralysisStop,
  paralysisTick,
  paralysisSpeed,
  confusionSelfHit,
  confusionTick,
  selfHitDamage,
  residualBurn,
  residualPoison,
  residualToxic,
  burnAttack,
  int,
  PARALYSIS_STOP_BYTE,
  DEFROST_BYTE,
  CONFUSION_HIT_ROLL,
  CONFUSION_POWER,
  RESIDUAL_DIVISOR,
  TOXIC_DIVISOR,
};
