'use strict';

/*
 * Gen 3 abilities: the id table and every battle behaviour.
 *
 * Node twin of src/BattleSim3/Abilities.lua (engine src/core/game3/battle/
 * abilities.lua, pret battle_util.c AbilityBattleEffects). The ability call
 * sites that live beside their formula stay there (Damage.js, Accuracy.js,
 * Move.js); this file holds the ones with a trigger of their own: switch-in
 * (weather setters, Intimidate, Trace, Forecast, Cloud Nine / Air Lock), end of
 * turn (Rain Dish, Shed Skin, Speed Boost, Truant), absorb (Volt / Water
 * Absorb, Flash Fire), contact (Static, Flame Body, Poison Point, Effect
 * Spore, Rough Skin, Cute Charm), Color Change, the immunity cures,
 * Synchronize, the escape blockers and Natural Cure.
 *
 * Every behaviour takes the battle `B` first and talks to the field through
 * the helper surface Move.js installs on it (B.roll, B.active, B.foes, B.say,
 * B.emitAbility, B.heal, B.loseHp, B.inflict, B.cure, B.weather, ...). The ids
 * are pret include/constants/abilities.h -- code constants, not data.
 *
 * escapeBlocker -> [battler, abilityToken] | [null, null].
 *
 * Nothing here throws.
 */

const Types = require('./Types.js');
const Status = require('./Status.js');
const {
  int, truthy, mod, own,
} = require('./lua.js');

const M = {};

// pokefirered/include/constants/abilities.h
M.BY_ID = {
  1: 'STENCH',
  2: 'DRIZZLE',
  3: 'SPEED_BOOST',
  4: 'BATTLE_ARMOR',
  5: 'STURDY',
  6: 'DAMP',
  7: 'LIMBER',
  8: 'SAND_VEIL',
  9: 'STATIC',
  10: 'VOLT_ABSORB',
  11: 'WATER_ABSORB',
  12: 'OBLIVIOUS',
  13: 'CLOUD_NINE',
  14: 'COMPOUND_EYES',
  15: 'INSOMNIA',
  16: 'COLOR_CHANGE',
  17: 'IMMUNITY',
  18: 'FLASH_FIRE',
  19: 'SHIELD_DUST',
  20: 'OWN_TEMPO',
  21: 'SUCTION_CUPS',
  22: 'INTIMIDATE',
  23: 'SHADOW_TAG',
  24: 'ROUGH_SKIN',
  25: 'WONDER_GUARD',
  26: 'LEVITATE',
  27: 'EFFECT_SPORE',
  28: 'SYNCHRONIZE',
  29: 'CLEAR_BODY',
  30: 'NATURAL_CURE',
  31: 'LIGHTNING_ROD',
  32: 'SERENE_GRACE',
  33: 'SWIFT_SWIM',
  34: 'CHLOROPHYLL',
  35: 'ILLUMINATE',
  36: 'TRACE',
  37: 'HUGE_POWER',
  38: 'POISON_POINT',
  39: 'INNER_FOCUS',
  40: 'MAGMA_ARMOR',
  41: 'WATER_VEIL',
  42: 'MAGNET_PULL',
  43: 'SOUNDPROOF',
  44: 'RAIN_DISH',
  45: 'SAND_STREAM',
  46: 'PRESSURE',
  47: 'THICK_FAT',
  48: 'EARLY_BIRD',
  49: 'FLAME_BODY',
  50: 'RUN_AWAY',
  51: 'KEEN_EYE',
  52: 'HYPER_CUTTER',
  53: 'PICKUP',
  54: 'TRUANT',
  55: 'HUSTLE',
  56: 'CUTE_CHARM',
  57: 'PLUS',
  58: 'MINUS',
  59: 'FORECAST',
  60: 'STICKY_HOLD',
  61: 'SHED_SKIN',
  62: 'GUTS',
  63: 'MARVEL_SCALE',
  64: 'LIQUID_OOZE',
  65: 'OVERGROW',
  66: 'BLAZE',
  67: 'TORRENT',
  68: 'SWARM',
  69: 'ROCK_HEAD',
  70: 'DROUGHT',
  71: 'ARENA_TRAP',
  72: 'VITAL_SPIRIT',
  73: 'WHITE_SMOKE',
  74: 'PURE_POWER',
  75: 'SHELL_ARMOR',
  76: 'CACOPHONY',
  77: 'AIR_LOCK',
};
M.ID = {};
for (const id of Object.keys(M.BY_ID)) M.ID[M.BY_ID[id]] = Number(id);
M.MAX = 77;

// pokefirered/src/battle_util.c:31 sSoundMovesTable (move numbers)
M.SOUND_MOVES = {
  45: true,
  46: true,
  47: true,
  48: true,
  103: true,
  173: true,
  253: true,
  319: true,
  320: true,
  304: true,
};

M.SPECIES_CASTFORM = 385;

M.nameOf = function nameOf(idIn) {
  const id = int(idIn, 0);
  return own(M.BY_ID, id) ? M.BY_ID[id] : null;
};

M.idOf = function idOf(name) {
  return (typeof name === 'string' && own(M.ID, name)) ? M.ID[name] : 0;
};

// The display name an ability is narrated under: the sheet's, or the token.
M.label = function label(name, sheetName) {
  if (typeof sheetName === 'string' && sheetName !== '') return sheetName;
  if (typeof name !== 'string') return 'ability';
  return name.replace(/_/g, ' ');
};

function isType(b, t) {
  return b != null && (b.type1 === t || b.type2 === t);
}
M.isType = isType;

function setType(b, t) {
  b.type1 = t;
  delete b.type2;
}

function nm(B, b) {
  return B.nameOf(b);
}

// ------------------------------------------------------------------
// Forecast (pokefirered/src/battle_util.c:1611 CastformDataTypeChange)
// ------------------------------------------------------------------

// Returns 0 for no change, else form + 1 (1 normal, 2 sunny, 3 rainy, 4 snowy),
// the engine's encoding; the `form` event carries form - 1.
M.castformChange = function castformChange(B, b) {
  if (!truthy(b) || int(b.speciesNum, 0) !== M.SPECIES_CASTFORM || b.ability !== 'FORECAST'
      || int(b.mon.hp, 0) <= 0) {
    return 0;
  }
  const w = B.weather();
  if (!truthy(w) && !isType(b, Types.ID.NORMAL)) {
    setType(b, Types.ID.NORMAL);
    return 1;
  }
  if (!truthy(w)) return 0;
  let form = 0;
  if (w !== 'RAIN' && w !== 'SUN' && w !== 'HAIL' && !isType(b, Types.ID.NORMAL)) {
    setType(b, Types.ID.NORMAL);
    form = 1;
  }
  if (w === 'SUN' && !isType(b, Types.ID.FIRE)) { setType(b, Types.ID.FIRE); form = 2; }
  if (w === 'RAIN' && !isType(b, Types.ID.WATER)) { setType(b, Types.ID.WATER); form = 3; }
  if (w === 'HAIL' && !isType(b, Types.ID.ICE)) { setType(b, Types.ID.ICE); form = 4; }
  return form;
};

// pokefirered/data/battle_scripts_1.s:3972
function castformScript(B, b, form) {
  b.castformForm = form - 1;
  B.emit('form', { slot: b.slot, side: b.side, amount: form - 1 });
  B.say(`${nm(B, b)} transformed!`);
}

// pokefirered/src/battle_util.c:2169 (ABILITYEFFECT_FORECAST): the first
// Castform that changes, and only one per call.
M.forecast = function forecast(B) {
  for (const b of B.active()) {
    if (b.ability === 'FORECAST') {
      const form = M.castformChange(B, b);
      if (form !== 0) {
        castformScript(B, b, form);
        return true;
      }
    }
  }
  return false;
};

function weatherFormChanges(B) {
  for (let i = 1; i <= 2; i += 1) {
    if (!M.forecast(B)) break;
  }
}

// ------------------------------------------------------------------
// switch-in (pokefirered/src/battle_util.c:1704 ABILITYEFFECT_ON_SWITCHIN)
// ------------------------------------------------------------------

const WEATHER_ABILITY = {
  DRIZZLE: ['RAIN', "'s DRIZZLE made it rain!"],
  SAND_STREAM: ['SAND', "'s SAND STREAM whipped up a sandstorm!"],
  DROUGHT: ['SUN', "'s DROUGHT intensified the sun's rays!"],
};

M.switchIn = function switchIn(B, b) {
  if (!truthy(b) || int(b.mon.hp, 0) <= 0) return false;
  const ab = b.ability;
  // pokefirered/src/battle_util.c:1698: in a veiled GHOST fight Intimidate and
  // Trace do nothing, either side (Turn.create `ghost = 'veiled'`).
  if (B.ghost === 'veiled' && (ab === 'INTIMIDATE' || ab === 'TRACE')) return false;
  const key = truthy(ab) ? ab : '';
  const row = (typeof key === 'string' && own(WEATHER_ABILITY, key)) ? WEATHER_ABILITY[key] : null;
  if (row) {
    // An ability's weather is permanent (weatherTurns 0); the same permanent
    // weather already up does nothing.
    if (!(B.field.weather === row[0] && int(B.field.weatherTurns, 0) <= 0)) {
      B.field.weather = row[0];
      B.field.weatherTurns = 0;
      B.emitAbility(b);
      B.emit('weather', {
        text: row[0], amount: 1, slot: b.slot, side: b.side,
      });
      B.say(nm(B, b) + row[1]);
      weatherFormChanges(B);
      return true;
    }
  } else if (ab === 'INTIMIDATE') {
    if (!truthy(b.intimidated)) {
      b.intimidatePending = true;
      b.intimidated = true;
    }
  } else if (ab === 'FORECAST') {
    const form = M.castformChange(B, b);
    if (form !== 0) {
      castformScript(B, b, form);
      return true;
    }
  } else if (ab === 'TRACE') {
    if (!truthy(b.traced)) {
      b.tracePending = true;
      b.traced = true;
    }
  } else if (ab === 'CLOUD_NINE' || ab === 'AIR_LOCK') {
    for (const o of B.active()) {
      const form = M.castformChange(B, o);
      if (form !== 0) {
        castformScript(B, o, form);
        return true;
      }
    }
  }
  return false;
};

// pokefirered/data/battle_scripts_1.s:3983 BattleScript_IntimidateActivates
function intimidateOne(B, b, foe) {
  if (!(truthy(foe) && int(foe.mon.hp, 0) > 0 && int(foe.substituteHP, 0) <= 0)) return;
  const fab = foe.ability;
  if (fab === 'CLEAR_BODY' || fab === 'HYPER_CUTTER' || fab === 'WHITE_SMOKE') {
    // src/battle_script_commands.c:9181
    B.emitAbility(foe);
    B.say(`${nm(B, foe)}'s ${B.abilityLabel(foe)} prevents ${B.abilityLabel(b)}!`);
  } else {
    const side = B.sideState(foe.side);
    if (int(side.mistTurns, 0) > 0) {
      if (!truthy(foe.statLoweredMsg)) {
        foe.statLoweredMsg = true;
        B.say(`${nm(B, foe)} is protected by MIST!`);
      }
    } else if (foe.stages.atk > -6) {
      foe.stages.atk -= 1;
      B.emit('stat', {
        slot: foe.slot,
        side: foe.side,
        stat: 'atk',
        stage: foe.stages.atk,
        delta: -1,
        text: `${nm(B, b)}'s INTIMIDATE cuts ${nm(B, foe)}'s ATTACK!`,
      });
      B.say(`${nm(B, b)}'s INTIMIDATE cuts ${nm(B, foe)}'s ATTACK!`);
    }
  }
}

// The first pending Intimidate on the field resolves; the caller loops.
M.runIntimidate = function runIntimidate(B) {
  for (const b of B.active()) {
    if (truthy(b.intimidatePending) && b.ability === 'INTIMIDATE') {
      delete b.intimidatePending;
      // pokefirered/src/battle_script_commands.c:9174 (every foe in doubles);
      // one `ability` event for the activation, a line per foe.
      B.emitAbility(b);
      for (const foe of B.foes(b)) intimidateOne(B, b, foe);
      return true;
    }
  }
  return false;
};

// pokefirered/src/battle_util.c:2231 ABILITYEFFECT_TRACE
M.runTrace = function runTrace(B) {
  for (const b of B.active()) {
    if (truthy(b.tracePending) && b.ability === 'TRACE') {
      const cands = [];
      for (const foe of B.foes(b)) {
        if (truthy(foe.ability) && int(foe.mon.hp, 0) > 0) cands.push(foe);
      }
      let foe = null;
      if (cands.length === 1) {
        foe = cands[0];
      } else if (cands.length >= 2) {
        // battle_util.c:2243: a coin between the two foes; with a wider field,
        // one draw over every traceable foe (a single foe draws nothing).
        foe = cands[B.roll(0, cands.length - 1)];
      }
      if (truthy(foe)) {
        delete b.tracePending;
        b.ability = foe.ability;
        if (foe.abilityName == null) delete b.abilityName; else b.abilityName = foe.abilityName;
        // src/battle_util.c:2281
        B.emitAbility(b);
        B.say(`${nm(B, b)} TRACED ${nm(B, foe)}'s ${B.abilityLabel(foe)}!`);
        return true;
      }
    }
  }
  return false;
};

// ------------------------------------------------------------------
// end of turn (pokefirered/src/battle_util.c:1816 ABILITYEFFECT_ENDTURN)
// ------------------------------------------------------------------

M.endTurn = function endTurn(B, b) {
  if (!truthy(b) || int(b.mon.hp, 0) <= 0) return false;
  const ab = b.ability;
  if (ab === 'RAIN_DISH') {
    if (B.weather() === 'RAIN' && b.mon.maxHp > b.mon.hp) {
      let amt = Math.floor(b.mon.maxHp / 16);
      if (amt === 0) amt = 1;
      B.emitAbility(b);
      B.say(`${nm(B, b)}'s RAIN DISH restored its HP a little!`);
      B.heal(b, amt);
      return true;
    }
  } else if (ab === 'SHED_SKIN') {
    const s = Status.normalise(b.mon.status);
    if (truthy(s) && B.roll(0, 2) === 0) {
      B.emitAbility(b);
      const word = own(Status.WORD, s) ? Status.WORD[s] : 'status';
      B.cure(b, `${nm(B, b)}'s SHED SKIN cured its ${word} problem!`);
      delete b.nightmare;
      return true;
    }
  } else if (ab === 'SPEED_BOOST') {
    if (b.stages.spe < 6 && int(b.isFirstTurn, 0) !== 2) {
      b.stages.spe += 1;
      B.emitAbility(b);
      B.emit('stat', {
        slot: b.slot,
        side: b.side,
        stat: 'spe',
        stage: b.stages.spe,
        delta: 1,
        text: `${nm(B, b)}'s SPEED BOOST raised its SPEED!`,
      });
      B.say(`${nm(B, b)}'s SPEED BOOST raised its SPEED!`);
      return true;
    }
  } else if (ab === 'TRUANT') {
    b.truantCounter = (int(b.truantCounter, 0) === 0) ? 1 : 0;
  }
  return false;
};

// pokefirered/src/battle_util.c:1337
M.truantLoafs = function truantLoafs(b) {
  return b != null && b.ability === 'TRUANT' && int(b.truantCounter, 0) !== 0;
};

// pokefirered/src/battle_util.c:1874: the move is a sound move and the target
// is Soundproof.
M.soundproofBlocks = function soundproofBlocks(target, moveNum) {
  return target != null && target.ability === 'SOUNDPROOF' && M.SOUND_MOVES[int(moveNum, -1)] === true;
};

// ------------------------------------------------------------------
// absorb (pokefirered/src/battle_util.c:1891 ABILITYEFFECT_ABSORBING)
// ------------------------------------------------------------------

// Returns true when the target's ability swallowed the move (the caller marks
// the move as having no effect). Narration and healing happen here.
M.absorb = function absorb(B, user, target, moveType, power, moveName) {
  if (!truthy(target) || target === user) return false;
  const ab = target.ability;
  let kind = null;
  if (ab === 'VOLT_ABSORB' && moveType === Types.ID.ELECTRIC && power !== 0) kind = 'hp';
  else if (ab === 'WATER_ABSORB' && moveType === Types.ID.WATER && power !== 0) kind = 'hp';
  else if (ab === 'FLASH_FIRE' && moveType === Types.ID.FIRE
      && Status.normalise(target.mon.status) !== 'FRZ') kind = 'fire';
  if (kind === null) return false;
  B.emitAbility(target);
  if (kind === 'fire') {
    if (!truthy(target.flashFire)) {
      target.flashFire = true;
      B.say(`${nm(B, target)}'s FLASH FIRE raised its FIRE power!`);
    } else {
      B.say(`${nm(B, target)}'s FLASH FIRE made ${moveName} ineffective!`);
    }
    return true;
  }
  if (target.mon.hp >= target.mon.maxHp) {
    B.say(`${nm(B, target)}'s ${B.abilityLabel(target)} made ${moveName} useless!`);
  } else {
    let amt = Math.floor(target.mon.maxHp / 4);
    if (amt === 0) amt = 1;
    B.heal(target, amt);
    B.say(`${nm(B, target)} restored HP using its ${B.abilityLabel(target)}!`);
  }
  return true;
};

// ------------------------------------------------------------------
// status from an ability (pokefirered/src/battle_script_commands.c:2110)
// ------------------------------------------------------------------

// holder: the battler whose ability acts; victim: who takes the status.
// primary: a Synchronize pass (announces the prevention the way a primary
// status move does).
M.applyStatus = function applyStatus(B, holder, victim, status, primary, M_) {
  if (!truthy(victim) || int(victim.mon.hp, 0) <= 0) return false;
  if (int(victim.substituteHP, 0) > 0 && victim !== (truthy(M_) ? M_.user : M_)) return false;
  const vab = victim.ability;
  const vs = Status.normalise(victim.mon.status);
  const isPrimary = truthy(primary);
  const prevents = () => {
    B.emitAbility(victim);
    B.say(`${nm(B, victim)}'s ${B.abilityLabel(victim)} prevents it!`);
    return false;
  };
  const noEffect = () => {
    B.say(`${nm(B, holder)}'s ${B.abilityLabel(holder)} had no effect on ${nm(B, victim)}!`);
    return false;
  };
  if (status === 'SLP') {
    if (truthy(vs)) return false;
    if (vab !== 'SOUNDPROOF' && truthy(B.uproarActive())) return false;
    if (vab === 'VITAL_SPIRIT' || vab === 'INSOMNIA') return false;
  } else if (status === 'PSN' || status === 'TOX') {
    if (vab === 'IMMUNITY' && isPrimary) return prevents();
    const immuneType = isType(victim, Types.ID.POISON) || isType(victim, Types.ID.STEEL);
    if (immuneType && isPrimary) return noEffect();
    if (immuneType) return false;
    if (truthy(vs) || vab === 'IMMUNITY') return false;
  } else if (status === 'BRN') {
    if (vab === 'WATER_VEIL' && isPrimary) return prevents();
    if (isType(victim, Types.ID.FIRE) && isPrimary) return noEffect();
    if (isType(victim, Types.ID.FIRE) || vab === 'WATER_VEIL' || truthy(vs)) return false;
  } else if (status === 'PAR') {
    if (vab === 'LIMBER') {
      if (isPrimary) return prevents();
      return false;
    }
    if (truthy(vs)) return false;
  } else {
    return false;
  }
  B.emitAbility(holder);
  let text;
  if (status === 'TOX') {
    text = `${nm(B, victim)} is badly poisoned!`;
  } else if (status === 'PSN') {
    text = `${nm(B, holder)}'s ${B.abilityLabel(holder)} poisoned ${nm(B, victim)}!`;
  } else if (status === 'PAR') {
    text = `${nm(B, holder)}'s ${B.abilityLabel(holder)} paralyzed ${nm(B, victim)}!`;
  } else if (status === 'BRN') {
    text = `${nm(B, holder)}'s ${B.abilityLabel(holder)} burned ${nm(B, victim)}!`;
  } else {
    text = `${nm(B, holder)}'s ${B.abilityLabel(holder)} made ${nm(B, victim)} sleep!`;
  }
  B.inflict(victim, status, { text, source: holder });
  if (status !== 'SLP') B.syncEffect = { status };
  return true;
};

// ------------------------------------------------------------------
// on damage (pokefirered/src/battle_util.c:1964 ABILITYEFFECT_ON_DAMAGE)
// ------------------------------------------------------------------

function contact(move) {
  return move != null && mod(int(move.flags, 0), 2) === 1;
}

// M_: the move context (user, target, move, moveType, mnum, noEffect,
// targetDamaged). Returns true when something happened.
M.onDamage = function onDamage(B, M_) {
  const { user, target } = M_;
  if (!truthy(target) || target === user || truthy(M_.noEffect) || !truthy(M_.targetDamaged)) return false;
  const ab = target.ability;
  let mtRaw;
  if (truthy(M_.moveType)) mtRaw = M_.moveType;
  else mtRaw = truthy(M_.move) ? M_.move.type : M_.move;
  const mt = int(mtRaw, 0);
  if (ab === 'COLOR_CHANGE') {
    if (M_.mnum !== 165 && int(M_.move.power, 0) !== 0 && !isType(target, mt)
        && int(target.mon.hp, 0) > 0) {
      setType(target, mt);
      B.emitAbility(target);
      B.say(`${nm(B, target)}'s COLOR CHANGE made it the ${B.typeLabel(mt)} type!`);
      return true;
    }
    return false;
  }
  if (int(user.mon.hp, 0) <= 0 || !contact(M_.move)) return false;
  if (ab === 'ROUGH_SKIN') {
    let amt = Math.floor(user.mon.maxHp / 16);
    if (amt === 0) amt = 1;
    B.emitAbility(target);
    B.loseHp(user, amt);
    B.say(`${nm(B, user)} was hurt by ${nm(B, target)}'s ROUGH SKIN!`);
    M_.tryFaintUser();
    return true;
  } else if (ab === 'EFFECT_SPORE') {
    if (B.roll(0, 9) === 0) {
      let r;
      do {
        r = B.roll(0, 3);
      } while (r === 0);
      const status = ['SLP', 'PSN', 'PAR'][r - 1];
      M.applyStatus(B, target, user, status, false, M_);
      return true;
    }
  } else if (ab === 'POISON_POINT' || ab === 'STATIC' || ab === 'FLAME_BODY') {
    if (B.roll(0, 2) === 0) {
      let status;
      if (ab === 'POISON_POINT') status = 'PSN';
      else if (ab === 'STATIC') status = 'PAR';
      else status = 'BRN';
      M.applyStatus(B, target, user, status, false, M_);
      return true;
    }
  } else if (ab === 'CUTE_CHARM') {
    if (int(target.mon.hp, 0) > 0 && B.roll(0, 2) === 0 && user.ability !== 'OBLIVIOUS') {
      const ug = truthy(user.mon.gender) ? user.mon.gender : 'U';
      const tg = truthy(target.mon.gender) ? target.mon.gender : 'U';
      if (ug !== tg && !truthy(user.infatuatedWith) && ug !== 'U' && tg !== 'U') {
        user.infatuatedWith = target;
        B.emitAbility(target);
        B.say(`${nm(B, target)}'s CUTE CHARM infatuated ${nm(B, user)}!`);
        return true;
      }
    }
  }
  return false;
};

// ------------------------------------------------------------------
// immunity cures (pokefirered/src/battle_util.c:2087 ABILITYEFFECT_IMMUNITY)
// ------------------------------------------------------------------

M.immunityCure = function immunityCure(B) {
  let any = false;
  for (const b of B.active()) {
    const ab = b.ability;
    const s = Status.normalise(b.mon.status);
    let word = null;
    let kind = null;
    if (ab === 'IMMUNITY' && (s === 'PSN' || s === 'TOX')) {
      word = 'poison';
      kind = 1;
    } else if (ab === 'OWN_TEMPO' && int(b.confusion, 0) > 0) {
      word = 'confusion';
      kind = 2;
    } else if (ab === 'LIMBER' && s === 'PAR') {
      word = 'paralysis';
      kind = 1;
    } else if ((ab === 'INSOMNIA' || ab === 'VITAL_SPIRIT') && s === 'SLP') {
      delete b.nightmare;
      word = 'sleep';
      kind = 1;
    } else if (ab === 'WATER_VEIL' && s === 'BRN') {
      word = 'burn';
      kind = 1;
    } else if (ab === 'MAGMA_ARMOR' && s === 'FRZ') {
      word = 'ice';
      kind = 1;
    } else if (ab === 'OBLIVIOUS' && truthy(b.infatuatedWith)) {
      word = 'love';
      kind = 3;
    }
    if (kind !== null) {
      const text = `${nm(B, b)}'s ${B.abilityLabel(b)} cured its ${word} problem!`;
      B.emitAbility(b);
      if (kind === 1) {
        B.cure(b, text);
      } else if (kind === 2) {
        delete b.confusion;
        B.emit('status', {
          slot: b.slot, side: b.side, confused: 0, text,
        });
        B.say(text);
      } else {
        delete b.infatuatedWith;
        B.say(text);
      }
      any = true;
    }
  }
  return any;
};

// pokefirered/src/battle_util.c:2185 ABILITYEFFECT_SYNCHRONIZE: a pending
// status the move just inflicted on the holder is passed back to the victim.
M.synchronize = function synchronize(B, M_, holder, victim) {
  const pend = B.syncEffect;
  if (!truthy(pend) || !truthy(holder) || holder.ability !== 'SYNCHRONIZE') return false;
  delete B.syncEffect;
  let { status } = pend;
  if (status === 'TOX') status = 'PSN';
  M.applyStatus(B, holder, victim, status, true, M_);
  return true;
};

// ------------------------------------------------------------------
// escape (pokefirered/src/battle_main.c:3002 IsRunningFromBattleImpossible)
// ------------------------------------------------------------------

// Returns [blocking battler, its ability], or [null, null].
M.escapeBlocker = function escapeBlocker(B, b) {
  for (const foe of B.foes(b)) {
    const fab = foe.ability;
    if (fab === 'SHADOW_TAG') return [foe, fab];
    if (fab === 'ARENA_TRAP' && b.ability !== 'LEVITATE' && !isType(b, Types.ID.FLYING)) {
      return [foe, fab];
    }
  }
  // pokefirered/src/battle_main.c:3036 (Magnet Pull traps a Steel type)
  if (isType(b, Types.ID.STEEL)) {
    for (const o of B.active()) {
      if (o !== b && o.side !== b.side && o.ability === 'MAGNET_PULL') return [o, 'MAGNET_PULL'];
    }
  }
  return [null, null];
};

// pokefirered/src/battle_script_commands.c:9197 (Natural Cure on switch-out).
// The cart prints nothing; the `ability` event and the cleared status are the
// whole of it.
M.switchOut = function switchOut(B, b) {
  if (truthy(b) && b.ability === 'NATURAL_CURE' && truthy(Status.normalise(b.mon.status))) {
    B.emitAbility(b);
    B.cure(b, null);
    return true;
  }
  return false;
};

module.exports = M;
