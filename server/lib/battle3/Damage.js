'use strict';

/*
 * Gen 3 damage, as an integer pipeline.
 *
 * Node twin of src/BattleSim3/Damage.lua, which is pret:
 *
 *   CalculateBaseDamage   pokefirered/src/pokemon.c:2385     (`base`)
 *   Cmd_damagecalc        pokefirered/src/battle_script_commands.c:1209
 *   Cmd_typecalc          pokefirered/src/battle_script_commands.c:1274
 *   ApplyRandomDmgMultiplier / Cmd_adjustnormaldamage   battle_script_commands.c:1558
 *
 * The battler shape (the turn machine builds it; the vector runner builds the
 * same thing with `battler`):
 *
 *   b.mon      = { level, hp, maxHp, status, holdEffect, holdParam, friendship,
 *                  weight, hiddenPower = { type, power }, beatUp = { atk, def } }
 *   b.stats    = { atk, def, spe, spa, spd }      effective (Transform swaps it)
 *   b.stages   = { atk, def, spe, spa, spd, acc, eva }   -6..6
 *   b.type1, b.type2 (null when single-typed), b.ability (pret token or null),
 *   b.speciesNum, and the volatiles read here: flashFire, charged,
 *   helpingHand, substituteHP, lastPhysDmg / lastPhysBy, lastSpecDmg /
 *   lastSpecBy, identified.
 *   b.badges   = { [n]: true } (n 1..8) or null: its trainer's badges, set only
 *                on side a of a fight against the computer (Turn.BADGE_MODES).
 *
 * Randomness is drawn from `opts.rng` in the engine's order: Magnitude,
 * Psywave, critical hit, damage roll -- each only when reached.
 *
 * Multi-value returns as arrays: calc -> [damage, info], hiddenPower ->
 * [power, type], magnitude -> [magnitude, power].
 *
 * Nothing here throws.
 */

const Types = require('./Types.js');
const Crit = require('./Crit.js');
const {
  int, isTable, truthy, toNumber,
} = require('./lua.js');

const ROLL_MIN = 85;
const ROLL_MAX = 100;

// pret EFFECT_* the pipeline branches on (include/constants/battle_move_effects.h).
const E = {
  EXPLOSION: 7,
  RETURN: 121,
  FRUSTRATION: 123,
  MAGNITUDE: 126,
  PURSUIT: 128,
  SONICBOOM: 130,
  HIDDEN_POWER: 135,
  DRAGON_RAGE: 41,
  SUPER_FANG: 40,
  LEVEL_DAMAGE: 87,
  PSYWAVE: 88,
  COUNTER: 89,
  FLAIL: 99,
  FALSE_SWIPE: 101,
  MIRROR_COAT: 144,
  SOLAR_BEAM: 151,
  FACADE: 169,
  SMELLINGSALT: 171,
  REVENGE: 185,
  ENDEAVOR: 189,
  ERUPTION: 190,
  LOW_KICK: 196,
  WEATHER_BALL: 203,
};

// pret HOLD_EFFECT_* the base formula reads (include/constants/hold_effects.h).
const HOLD = {
  CHOICE_BAND: 29,
  SOUL_DEW: 34,
  DEEP_SEA_TOOTH: 35,
  DEEP_SEA_SCALE: 36,
  LIGHT_BALL: 45,
  METAL_POWDER: 64,
  THICK_CLUB: 65,
};

// pret SPECIES_* the base formula reads (internal numbering).
const SPECIES = {
  PIKACHU: 25,
  CUBONE: 104,
  MAROWAK: 105,
  DITTO: 132,
  CLAMPERL: 373,
  LATIAS: 407,
  LATIOS: 408,
};

const MOVE_STRUGGLE = 165;

// pokefirered/src/pokemon.c:1461 sHoldEffectToType
const TYPE_BOOST = {
  31: 6,
  42: 8,
  46: 4,
  47: 5,
  48: 12,
  49: 17,
  50: 1,
  51: 13,
  52: 11,
  53: 2,
  54: 3,
  55: 15,
  56: 7,
  57: 14,
  58: 10,
  59: 16,
  60: 0,
};

// pokefirered/src/pokemon.c:1442 gStatStageRatios
const STAGE_RATIO = {
  '-6': [10, 40],
  '-5': [10, 35],
  '-4': [10, 30],
  '-3': [10, 25],
  '-2': [10, 20],
  '-1': [10, 15],
  0: [10, 10],
  1: [15, 10],
  2: [20, 10],
  3: [25, 10],
  4: [30, 10],
  5: [35, 10],
  6: [40, 10],
};

function clampStage(value) {
  const s = int(value, 0);
  if (s < -6) return -6;
  if (s > 6) return 6;
  return s;
}

// pokefirered/src/pokemon.c:2374 APPLY_STAT_MOD
function applyStage(stat, stage) {
  const r = STAGE_RATIO[clampStage(stage)];
  return Math.floor(Math.max(0, int(stat, 0)) * r[0] / r[1]);
}

// ------------------------------------------------------------------
// accessors (one place that knows the battler shape)
// ------------------------------------------------------------------

function monOf(b) {
  return (b && truthy(b.mon)) ? b.mon : {};
}

function statOf(b, key) {
  let s = b ? b.stats : null;
  if (!isTable(s)) s = monOf(b).stats;
  if (!isTable(s)) return 1;
  return Math.max(0, int(s[key], 1));
}

function stageOf(b, key) {
  const s = b ? b.stages : null;
  if (!isTable(s)) return 0;
  return clampStage(s[key]);
}

function statusOf(b) {
  const s = monOf(b).status;
  if (s === undefined || s === null || s === '' || s === 0) return null;
  return s;
}

function holdOf(b) {
  const m = monOf(b);
  return [int(m.holdEffect, 0), int(m.holdParam, 0)];
}

function hasType(b, t) {
  return b !== undefined && b !== null && (b.type1 === t || b.type2 === t);
}

// The badges a trainer brings (docs/plans/gen3-badge-rules.md K1), as the set
// { [n]: true } over n = 1..8, or null when none survive. Accepts a list
// (['1', '3'] / [1, 3]: each value a badge) or a set ({ 1: true } /
// { '1': true }: each key whose value is true); anything that is not an
// integer 1..8 is dropped, never an error. The Lua twin walks one table with
// pairs(); here a list's 1-based position is its index plus one, and an
// object's keys are never positions (they are strings in Lua too).
function badgeSet(raw) {
  if (!isTable(raw)) return null;
  const out = {};
  let any = false;
  const take = (n) => {
    if (n !== null && Number.isInteger(n) && n >= 1 && n <= 8) {
      out[n] = true;
      any = true;
    }
  };
  if (Array.isArray(raw)) {
    raw.forEach((v, i) => take(v === true ? i + 1 : toNumber(v)));
  } else {
    for (const [k, v] of Object.entries(raw)) {
      if (v === true) take(toNumber(k));
    }
  }
  return any ? out : null;
}

// pokefirered/src/pokemon.c:2381 FlagGet(FLAG_BADGE0n_GET), read off the
// battler's own trainer (each human brings their own; the foe side has none).
function hasBadge(b, n) {
  const set = b ? b.badges : null;
  return isTable(set) && set[n] === true;
}

// A convenience for the vector pack and the cross-check: build the battler
// shape above from one flat spec.
function battler(specIn) {
  const spec = specIn || {};
  const stats = spec.stats || {};
  const stages = spec.stages || {};
  const types = spec.types || [0];
  const he = int(spec.holdEffect, 0);
  const b = {
    mon: {
      level: int(spec.level, 50),
      hp: int(spec.hp, 100),
      maxHp: int(spec.maxHp, 100),
      status: spec.status,
      heldItem: int(spec.heldItem, he > 0 ? 1 : 0),
      holdEffect: he,
      holdParam: int(spec.holdParam, 0),
      friendship: int(spec.friendship, 70),
      weight: int(spec.weight, 0),
      hiddenPower: spec.hiddenPower,
      beatUp: spec.beatUp,
    },
    stats: {
      atk: int(stats.atk, 50),
      def: int(stats.def, 50),
      spe: int(stats.spe, 50),
      spa: int(stats.spa, 50),
      spd: int(stats.spd, 50),
    },
    stages: {
      atk: clampStage(stages.atk),
      def: clampStage(stages.def),
      spe: clampStage(stages.spe),
      spa: clampStage(stages.spa),
      spd: clampStage(stages.spd),
      acc: clampStage(stages.acc),
      eva: clampStage(stages.eva),
    },
    type1: int(types[0], 0),
    ability: spec.ability,
    speciesNum: int(spec.speciesNum, 0),
    focusEnergy: spec.focusEnergy === true,
    flashFire: spec.flashFire === true,
    charged: spec.charged === true,
    helpingHand: spec.helpingHand === true,
    substituteHP: int(spec.substituteHP, 0),
    identified: spec.identified === true,
    lastPhysDmg: int(spec.lastPhysDmg, 0),
    lastPhysBy: spec.lastPhysBy,
    lastSpecDmg: int(spec.lastSpecDmg, 0),
    lastSpecBy: spec.lastSpecBy,
    badges: badgeSet(spec.badges),
  };
  const t2 = int(types[1], null);
  if (t2 !== null && t2 !== b.type1) b.type2 = t2;
  return b;
}

// ------------------------------------------------------------------
// variable power
// ------------------------------------------------------------------

// pokefirered/src/battle_script_commands.c:8503. Returns [power, type].
function hiddenPower(ivsIn) {
  const ivs = ivsIn || {};
  const g = (k) => Math.max(0, int(ivs[k], 0));
  const hp = g('hp');
  const atk = g('atk');
  const def = g('def');
  const spe = g('spe');
  const spa = g('spa');
  const spd = g('spd');
  const bit = (v, b) => Math.floor(v / b) % 2;
  const powerBits = bit(hp, 2) + 2 * bit(atk, 2) + 4 * bit(def, 2) + 8 * bit(spe, 2)
    + 16 * bit(spa, 2) + 32 * bit(spd, 2);
  const typeBits = bit(hp, 1) + 2 * bit(atk, 1) + 4 * bit(def, 1) + 8 * bit(spe, 1)
    + 16 * bit(spa, 1) + 32 * bit(spd, 1);
  const power = Math.floor(40 * powerBits / 63) + 30;
  let t = Math.floor(15 * typeBits / 63) + 1;
  if (t >= Types.ID.MYSTERY) t += 1;
  return [power, t];
}

// pokefirered/src/battle_script_commands.c:7928
function flailPower(hpIn, maxHpIn) {
  const hp = int(hpIn, 1);
  const maxHp = Math.max(1, int(maxHpIn, 1));
  let n = Math.floor(hp * 48 / maxHp);
  if (n === 0 && hp > 0) n = 1;
  if (n <= 1) return 200;
  if (n <= 4) return 150;
  if (n <= 9) return 100;
  if (n <= 16) return 80;
  if (n <= 32) return 40;
  return 20;
}

// pokefirered/src/battle_script_commands.c:9074 (weight in hectograms)
function lowKickPower(weight) {
  const wt = int(weight, 0);
  const tbl = [[100, 20], [250, 40], [500, 60], [1000, 80], [2000, 100]];
  for (const row of tbl) {
    if (row[0] > wt) return row[1];
  }
  return 120;
}

// pokefirered/src/battle_script_commands.c:8284 -> [magnitude, power]
function magnitude(rIn) {
  const r = int(rIn, 0);
  if (r < 5) return [4, 10];
  if (r < 15) return [5, 30];
  if (r < 35) return [6, 50];
  if (r < 65) return [7, 70];
  if (r < 85) return [8, 90];
  if (r < 95) return [9, 110];
  return [10, 150];
}

// pokefirered/src/battle_script_commands.c:7557
function psywave(level, rIn) {
  const r = Math.max(0, Math.min(10, int(rIn, 0)));
  return Math.floor(int(level, 1) * (r * 10 + 50) / 100);
}

// ------------------------------------------------------------------
// CalculateBaseDamage
// ------------------------------------------------------------------

// opts: power, moveType, crit, reflect, lightScreen, doubleScreens, spread,
//       weather ("RAIN"|"SUN"|"SAND"|"HAIL"|null, already Cloud-Nine-filtered),
//       mudSport, waterSport, specialTypes, plusPartner, minusPartner
function base(attacker, defender, moveIn, optsIn) {
  const opts = optsIn || {};
  const move = moveIn || {};
  const aMon = monOf(attacker);
  const optPower = int(opts.power, null);
  let power = optPower !== null ? optPower : Math.max(0, int(move.power, 0));
  const optType = int(opts.moveType, null);
  const moveType = optType !== null ? optType : int(move.type, 0);
  const crit = truthy(opts.crit);

  let attack = statOf(attacker, 'atk');
  let defense = statOf(defender, 'def');
  let spAttack = statOf(attacker, 'spa');
  let spDefense = statOf(defender, 'spd');

  const aAb = attacker ? attacker.ability : null;
  const dAb = defender ? defender.ability : null;
  if (aAb === 'HUGE_POWER' || aAb === 'PURE_POWER') attack *= 2;

  // pokefirered/src/pokemon.c:2381 badge boosts (engine damage.lua:205-217):
  // x110/100 floored, after Huge Power / Pure Power and before the held items and
  // the abilities below; the stat stages come later, in the formula. Badge 1 the
  // attacker's Attack, 5 the defender's Defense, 7 the attacker's Sp. Atk and the
  // defender's Sp. Def -- each read off that battler's own trainer, so a self-hit
  // (confusion, disobedience) carries both of its own. See the Lua twin.
  if (hasBadge(attacker, 1)) attack = Math.floor(110 * attack / 100);
  if (hasBadge(defender, 5)) defense = Math.floor(110 * defense / 100);
  if (hasBadge(attacker, 7)) spAttack = Math.floor(110 * spAttack / 100);
  if (hasBadge(defender, 7)) spDefense = Math.floor(110 * spDefense / 100);

  const [aHe, aParam] = holdOf(attacker);
  const [dHe] = holdOf(defender);
  if (TYPE_BOOST[aHe] !== undefined && TYPE_BOOST[aHe] === moveType) {
    if (Types.isPhysical(moveType, opts.specialTypes)) {
      attack = Math.floor(attack * (aParam + 100) / 100);
    } else {
      spAttack = Math.floor(spAttack * (aParam + 100) / 100);
    }
  }
  const aSp = int(attacker ? attacker.speciesNum : null, 0);
  const dSp = int(defender ? defender.speciesNum : null, 0);
  if (aHe === HOLD.CHOICE_BAND) attack = Math.floor(150 * attack / 100);
  if (aHe === HOLD.SOUL_DEW && (aSp === SPECIES.LATIAS || aSp === SPECIES.LATIOS)) {
    spAttack = Math.floor(150 * spAttack / 100);
  }
  if (dHe === HOLD.SOUL_DEW && (dSp === SPECIES.LATIAS || dSp === SPECIES.LATIOS)) {
    spDefense = Math.floor(150 * spDefense / 100);
  }
  if (aHe === HOLD.DEEP_SEA_TOOTH && aSp === SPECIES.CLAMPERL) spAttack *= 2;
  if (dHe === HOLD.DEEP_SEA_SCALE && dSp === SPECIES.CLAMPERL) spDefense *= 2;
  if (aHe === HOLD.LIGHT_BALL && aSp === SPECIES.PIKACHU) spAttack *= 2;
  if (dHe === HOLD.METAL_POWDER && dSp === SPECIES.DITTO) defense *= 2;
  if (aHe === HOLD.THICK_CLUB && (aSp === SPECIES.CUBONE || aSp === SPECIES.MAROWAK)) {
    attack *= 2;
  }
  if (dAb === 'THICK_FAT' && (moveType === Types.ID.FIRE || moveType === Types.ID.ICE)) {
    spAttack = Math.floor(spAttack / 2);
  }
  if (aAb === 'HUSTLE') attack = Math.floor(150 * attack / 100);
  if ((aAb === 'PLUS' && truthy(opts.minusPartner)) || (aAb === 'MINUS' && truthy(opts.plusPartner))) {
    spAttack = Math.floor(150 * spAttack / 100);
  }
  if (aAb === 'GUTS' && truthy(statusOf(attacker))) attack = Math.floor(150 * attack / 100);
  if (dAb === 'MARVEL_SCALE' && truthy(statusOf(defender))) defense = Math.floor(150 * defense / 100);
  if (moveType === Types.ID.ELECTRIC && truthy(opts.mudSport)) power = Math.floor(5 * power / 10);
  if (moveType === Types.ID.FIRE && truthy(opts.waterSport)) power = Math.floor(5 * power / 10);
  const aHp = int(aMon.hp, 0);
  const aMax = Math.max(1, int(aMon.maxHp, 1));
  if (aHp <= Math.floor(aMax / 3) && ((moveType === Types.ID.GRASS && aAb === 'OVERGROW')
      || (moveType === Types.ID.FIRE && aAb === 'BLAZE')
      || (moveType === Types.ID.WATER && aAb === 'TORRENT')
      || (moveType === Types.ID.BUG && aAb === 'SWARM'))) {
    power = Math.floor(150 * power / 100);
  }

  if (int(move.effect, -1) === E.EXPLOSION) defense = Math.floor(defense / 2);

  const level = int(aMon.level, 1);
  const levelFactor = Math.floor(2 * level / 5) + 2;
  let damage = 0;

  if (Types.isPhysical(moveType, opts.specialTypes)) {
    let atkStage = stageOf(attacker, 'atk');
    if (crit && atkStage <= 0) atkStage = 0;
    damage = applyStage(attack, atkStage);
    damage *= power;
    damage *= levelFactor;
    let defStage = stageOf(defender, 'def');
    if (crit && defStage >= 0) defStage = 0;
    const helper = Math.max(1, applyStage(defense, defStage));
    damage = Math.floor(damage / helper);
    damage = Math.floor(damage / 50);
    if (statusOf(attacker) === 'BRN' && aAb !== 'GUTS') damage = Math.floor(damage / 2);
    if (truthy(opts.reflect) && !crit) {
      if (truthy(opts.doubleScreens)) damage = 2 * Math.floor(damage / 3);
      else damage = Math.floor(damage / 2);
    }
    // pokefirered/src/pokemon.c:2552
    if (truthy(opts.spread)) damage = Math.floor(damage / 2);
    if (damage === 0) damage = 1;
  }

  if (moveType === Types.ID.MYSTERY) damage = 0;

  if (Types.isSpecial(moveType, opts.specialTypes)) {
    let atkStage = stageOf(attacker, 'spa');
    if (crit && atkStage <= 0) atkStage = 0;
    damage = applyStage(spAttack, atkStage);
    damage *= power;
    damage *= levelFactor;
    let defStage = stageOf(defender, 'spd');
    if (crit && defStage >= 0) defStage = 0;
    const helper = Math.max(1, applyStage(spDefense, defStage));
    damage = Math.floor(damage / helper);
    damage = Math.floor(damage / 50);
    if (truthy(opts.lightScreen) && !crit) {
      if (truthy(opts.doubleScreens)) damage = 2 * Math.floor(damage / 3);
      else damage = Math.floor(damage / 2);
    }
    // pokefirered/src/pokemon.c:2604
    if (truthy(opts.spread)) damage = Math.floor(damage / 2);
    const { weather } = opts;
    if (weather === 'RAIN') {
      if (moveType === Types.ID.FIRE) damage = Math.floor(damage / 2);
      else if (moveType === Types.ID.WATER) damage = Math.floor(15 * damage / 10);
    }
    if ((weather === 'RAIN' || weather === 'SAND' || weather === 'HAIL')
        && int(move.effect, -1) === E.SOLAR_BEAM) {
      damage = Math.floor(damage / 2);
    }
    if (weather === 'SUN') {
      if (moveType === Types.ID.FIRE) damage = Math.floor(15 * damage / 10);
      else if (moveType === Types.ID.WATER) damage = Math.floor(damage / 2);
    }
    if (attacker && truthy(attacker.flashFire) && moveType === Types.ID.FIRE) {
      damage = Math.floor(15 * damage / 10);
    }
  }

  return damage + 2;
}

// ------------------------------------------------------------------
// the whole pipeline
// ------------------------------------------------------------------

function roll(opts, lo, hi) {
  const { rng } = opts;
  if (rng && rng.roll) return rng.roll(lo, hi);
  return hi;
}

function fixedInfo(move, product, flags, physical, extra) {
  const info = {
    move, effectiveness: product, critical: false, physical, fixed: true, typeFlags: flags,
  };
  if (extra) Object.assign(info, extra);
  return info;
}

// opts (beyond base's): typeTable, rng, forceCrit, forceRoll, noRandom, noCrit,
//   dmgMultiplier, magnitudeRoll, psywaveRoll, pursuitSwitch, defenderId
//   (Revenge), foresight (override; default defender.identified), fixedDamage.
//
// Returns [damage, info], info = { effectiveness (product x100), critical,
//   physical, stab, magnitude, moveType, typeFlags, power, failed?, fixed?,
//   setDamage?, status? }.
function calc(attacker, defender, moveIn, optsIn) {
  const opts = optsIn || {};
  const move = moveIn || {};
  const aMon = monOf(attacker);
  const dMon = monOf(defender);
  const effect = int(move.effect, 0);
  const optPower = int(opts.power, null);
  let power = optPower !== null ? optPower : Math.max(0, int(move.power, 0));
  const optType = int(opts.moveType, null);
  let moveType = optType !== null ? optType : int(move.type, 0);
  let dmgMultiplier = Math.max(1, int(opts.dmgMultiplier, 1));
  let magnitudeVal = null;
  const { weather } = opts;
  const level = int(aMon.level, 1);
  const noPower = opts.power === undefined || opts.power === null;
  const noType = opts.moveType === undefined || opts.moveType === null;

  if (power <= 0 && noPower) {
    return [0, {
      move, effectiveness: 100, critical: false, status: true,
    }];
  }

  if (effect === E.MAGNITUDE && noPower) {
    let r = int(opts.magnitudeRoll, null);
    if (r === null) r = roll(opts, 0, 99);
    [magnitudeVal, power] = magnitude(r);
  } else if (effect === E.RETURN && noPower) {
    power = Math.floor(10 * int(aMon.friendship, 70) / 25);
  } else if (effect === E.FRUSTRATION && noPower) {
    power = Math.floor(10 * (255 - int(aMon.friendship, 70)) / 25);
  } else if (effect === E.ERUPTION && noPower) {
    power = Math.floor(int(aMon.hp, 1) * power / Math.max(1, int(aMon.maxHp, 1)));
    if (power === 0) power = 1;
  } else if (effect === E.FLAIL && noPower) {
    power = flailPower(aMon.hp, aMon.maxHp);
  } else if (effect === E.LOW_KICK && noPower) {
    power = lowKickPower(dMon.weight);
  } else if (effect === E.HIDDEN_POWER && noPower) {
    const hpw = aMon.hiddenPower;
    if (isTable(hpw)) {
      power = Math.max(1, int(hpw.power, 70));
      if (noType) moveType = int(hpw.type, moveType);
    }
  } else if (effect === E.WEATHER_BALL && noType) {
    // pokefirered/src/battle_script_commands.c:9345
    if (truthy(weather)) {
      dmgMultiplier *= 2;
      if (weather === 'RAIN') moveType = Types.ID.WATER;
      else if (weather === 'SAND') moveType = Types.ID.ROCK;
      else if (weather === 'SUN') moveType = Types.ID.FIRE;
      else if (weather === 'HAIL') moveType = Types.ID.ICE;
    }
  }

  // pret sets the multiplier in the move's own script (Facade, Revenge,
  // SmellingSalt), so the doubling is applied unconditionally -- the cart's
  // behaviour, and a documented engine gap (see the Lua twin).
  if (effect === E.PURSUIT && truthy(opts.pursuitSwitch)) {
    dmgMultiplier *= 2;
  } else if (effect === E.FACADE) {
    const st = statusOf(attacker);
    if (st === 'BRN' || st === 'PAR' || st === 'PSN' || st === 'TOX') {
      dmgMultiplier *= 2;
    }
  } else if (effect === E.REVENGE) {
    // pokefirered/src/battle_script_commands.c:8946: hurt this turn BY THIS TARGET.
    const by = opts.defenderId;
    if ((int(attacker.lastPhysDmg, 0) > 0 && attacker.lastPhysBy === by)
        || (int(attacker.lastSpecDmg, 0) > 0 && attacker.lastSpecBy === by)) {
      dmgMultiplier *= 2;
    }
  } else if (effect === E.SMELLINGSALT) {
    if (statusOf(defender) === 'PAR' && int(defender.substituteHP, 0) <= 0) {
      dmgMultiplier *= 2;
    }
  }

  const physical = Types.isPhysical(moveType, opts.specialTypes);
  let { foresight } = opts;
  if (foresight === undefined || foresight === null) foresight = truthy(defender.identified);
  let [, flags, product] = Types.typeCalc(opts.typeTable, moveType, defender.type1,
    defender.type2, null, foresight);

  let fixedAmount = null;
  if (effect === E.COUNTER || effect === E.MIRROR_COAT) {
    const taken = (effect === E.COUNTER) ? int(attacker.lastPhysDmg, 0) : int(attacker.lastSpecDmg, 0);
    if (taken <= 0) {
      return [0, {
        move, effectiveness: product, critical: false, physical, failed: true,
      }];
    }
    return [(flags.immune ? 0 : taken * 2), {
      move,
      effectiveness: product,
      critical: false,
      physical,
      typeFlags: flags,
      setDamage: true,
      moveType,
    }];
  } else if (effect === E.DRAGON_RAGE) {
    fixedAmount = 40;
  } else if (effect === E.SONICBOOM) {
    fixedAmount = 20;
  } else if (effect === E.LEVEL_DAMAGE) {
    fixedAmount = level;
  } else if (effect === E.SUPER_FANG) {
    fixedAmount = Math.max(1, Math.floor(int(dMon.hp, 1) / 2));
  } else if (effect === E.ENDEAVOR) {
    const uHp = int(aMon.hp, 0);
    const dHp = int(dMon.hp, 0);
    if (dHp <= uHp) {
      return [0, {
        move, effectiveness: product, critical: false, physical, failed: true,
      }];
    }
    fixedAmount = dHp - uHp;
  } else if (effect === E.PSYWAVE) {
    let r = int(opts.psywaveRoll, null);
    if (r === null) r = roll(opts, 0, 10);
    fixedAmount = psywave(level, r);
  } else if (truthy(opts.fixedDamage)) {
    fixedAmount = int(opts.fixedDamage, 0);
  }
  if (fixedAmount !== null) {
    if (flags.immune) return [0, fixedInfo(move, 0, flags, physical, { moveType })];
    return [fixedAmount, fixedInfo(move, product, flags, physical, { moveType })];
  }

  let crit = false;
  const dAb = defender.ability;
  if (opts.forceCrit !== undefined && opts.forceCrit !== null) {
    crit = truthy(opts.forceCrit);
  } else if (dAb !== 'BATTLE_ARMOR' && dAb !== 'SHELL_ARMOR' && !truthy(opts.noCrit)) {
    // pokefirered/src/battle_script_commands.c:1170
    const stage = Crit.stage(attacker, move);
    [crit] = Crit.check(stage, roll(opts, 0, Crit.chance(stage) - 1));
  }
  const critMul = crit ? Crit.MULTIPLIER : 1;

  let dmg = base(attacker, defender, move, {
    power,
    moveType,
    crit,
    reflect: opts.reflect,
    lightScreen: opts.lightScreen,
    doubleScreens: opts.doubleScreens,
    spread: opts.spread,
    weather,
    mudSport: opts.mudSport,
    waterSport: opts.waterSport,
    specialTypes: opts.specialTypes,
    plusPartner: opts.plusPartner,
    minusPartner: opts.minusPartner,
  });
  // pokefirered/src/battle_script_commands.c:1209
  dmg = dmg * critMul * dmgMultiplier;
  if (truthy(attacker.charged) && int(move.type, -1) === Types.ID.ELECTRIC) dmg *= 2;
  // pokefirered/src/battle_script_commands.c:1219
  if (truthy(attacker.helpingHand)) dmg = Math.floor(dmg * 15 / 10);

  let stab = false;
  const struggle = int(move.num, 0) === MOVE_STRUGGLE;
  if (!struggle) {
    if (hasType(attacker, moveType)) {
      stab = true;
      dmg = Math.floor(dmg * 15 / 10);
    }
    [dmg, flags, product] = Types.typeCalc(opts.typeTable, moveType, defender.type1,
      defender.type2, dmg, foresight);
  } else {
    flags = { super: false, notVery: false, immune: false };
    product = 100;
  }
  if (flags.immune) {
    return [0, {
      move,
      effectiveness: 0,
      critical: false,
      physical,
      stab,
      magnitude: magnitudeVal,
      moveType,
      typeFlags: flags,
      power,
      struggle,
    }];
  }

  // pokefirered/src/battle_script_commands.c:1558
  if (dmg !== 0 && !truthy(opts.noRandom)) {
    let r = int(opts.forceRoll, null);
    if (r === null) r = roll(opts, ROLL_MIN, ROLL_MAX);
    dmg = Math.floor(dmg * r / 100);
    if (dmg === 0) dmg = 1;
  }

  if (effect === E.FALSE_SWIPE && int(defender.substituteHP, 0) <= 0) {
    const curHp = int(dMon.hp, 1);
    if (dmg >= curHp) dmg = Math.max(0, curHp - 1);
  }

  return [dmg, {
    move,
    effectiveness: product,
    critical: crit,
    physical,
    stab,
    magnitude: magnitudeVal,
    moveType,
    typeFlags: flags,
    power,
    struggle,
  }];
}

// The confusion self-hit and disobedience self-hit: pret battle_util.c:1424, a
// typeless 40-power physical hit on itself, no crit, no STAB, no chart; the
// caller draws the 85..100 roll. The battler's own badges boost it as on the
// cart (badge 1 its Attack, badge 5 its Defense: engine.lua:668 / :1341).
function selfHitBase(b) {
  return base(b, b, { power: 40, type: 0, effect: 0 }, { power: 40, moveType: 0 });
}

module.exports = {
  ROLL_MIN,
  ROLL_MAX,
  E,
  TYPE_BOOST,
  STAGE_RATIO,
  clampStage,
  applyStage,
  badgeSet,
  hasBadge,
  battler,
  hiddenPower,
  flailPower,
  lowKickPower,
  magnitude,
  psywave,
  base,
  calc,
  selfHitBase,
};
