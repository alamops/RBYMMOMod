'use strict';

/*
 * Gen2 move-effect ids and stat-stage multipliers (light port of Gen1 Effects).
 *
 * Behavior taxonomy mirroring the public pret jump-table order; not ROM bytes.
 * Hand-authored 87-slot table (indices 0..86), twin of src/BattleSim2/Effects.lua.
 * Sheet keys: atk/def/spe/spa/spd (Sp.Def).
 *
 * Phase 0: lookup + stage multipliers. Phase 1: primary stat/status handlers.
 * Phase 2: post-damage side-chance effects + flinch.
 * Phase 3: multi-hit, fixed damage, drain, recoil.
 * Phase 4: multi-turn charge, recharge, trap, thrash, rage.
 */

const NAMES = [
  'NO_ADDITIONAL_EFFECT',
  'EFFECT_01',
  'POISON_SIDE_EFFECT1',
  'DRAIN_HP_EFFECT',
  'BURN_SIDE_EFFECT1',
  'FREEZE_SIDE_EFFECT1',
  'PARALYZE_SIDE_EFFECT1',
  'EXPLODE_EFFECT',
  'DREAM_EATER_EFFECT',
  'MIRROR_MOVE_EFFECT',
  'ATTACK_UP1_EFFECT',
  'DEFENSE_UP1_EFFECT',
  'SPEED_UP1_EFFECT',
  'SPECIAL_UP1_EFFECT',
  'ACCURACY_UP1_EFFECT',
  'EVASION_UP1_EFFECT',
  'PAY_DAY_EFFECT',
  'SWIFT_EFFECT',
  'ATTACK_DOWN1_EFFECT',
  'DEFENSE_DOWN1_EFFECT',
  'SPEED_DOWN1_EFFECT',
  'SPECIAL_DOWN1_EFFECT',
  'ACCURACY_DOWN1_EFFECT',
  'EVASION_DOWN1_EFFECT',
  'CONVERSION_EFFECT',
  'HAZE_EFFECT',
  'BIDE_EFFECT',
  'THRASH_PETAL_DANCE_EFFECT',
  'SWITCH_AND_TELEPORT_EFFECT',
  'TWO_TO_FIVE_ATTACKS_EFFECT',
  'EFFECT_1E',
  'FLINCH_SIDE_EFFECT1',
  'SLEEP_EFFECT',
  'POISON_SIDE_EFFECT2',
  'BURN_SIDE_EFFECT2',
  'FREEZE_SIDE_EFFECT2',
  'PARALYZE_SIDE_EFFECT2',
  'FLINCH_SIDE_EFFECT2',
  'OHKO_EFFECT',
  'CHARGE_EFFECT',
  'SUPER_FANG_EFFECT',
  'SPECIAL_DAMAGE_EFFECT',
  'TRAPPING_EFFECT',
  'FLY_EFFECT',
  'ATTACK_TWICE_EFFECT',
  'JUMP_KICK_EFFECT',
  'MIST_EFFECT',
  'FOCUS_ENERGY_EFFECT',
  'RECOIL_EFFECT',
  'CONFUSION_EFFECT',
  'ATTACK_UP2_EFFECT',
  'DEFENSE_UP2_EFFECT',
  'SPEED_UP2_EFFECT',
  'SPECIAL_UP2_EFFECT',
  'ACCURACY_UP2_EFFECT',
  'EVASION_UP2_EFFECT',
  'HEAL_EFFECT',
  'TRANSFORM_EFFECT',
  'ATTACK_DOWN2_EFFECT',
  'DEFENSE_DOWN2_EFFECT',
  'SPEED_DOWN2_EFFECT',
  'SPECIAL_DOWN2_EFFECT',
  'ACCURACY_DOWN2_EFFECT',
  'EVASION_DOWN2_EFFECT',
  'LIGHT_SCREEN_EFFECT',
  'REFLECT_EFFECT',
  'POISON_EFFECT',
  'PARALYZE_EFFECT',
  'ATTACK_DOWN_SIDE_EFFECT',
  'DEFENSE_DOWN_SIDE_EFFECT',
  'SPEED_DOWN_SIDE_EFFECT',
  'SPECIAL_DOWN_SIDE_EFFECT',
  'UNUSED',
  'UNUSED',
  'UNUSED',
  'UNUSED',
  'CONFUSION_SIDE_EFFECT',
  'TWINEEDLE_EFFECT',
  'UNUSED',
  'SUBSTITUTE_EFFECT',
  'HYPER_BEAM_EFFECT',
  'RAGE_EFFECT',
  'MIMIC_EFFECT',
  'METRONOME_EFFECT',
  'LEECH_SEED_EFFECT',
  'SPLASH_EFFECT',
  'DISABLE_EFFECT',
];

const CATEGORIES = [
  'none', 'other', 'status_side', 'drain', 'status_side', 'status_side',
  'status_side', 'other', 'drain', 'meta',
  'stat', 'stat', 'stat', 'stat', 'stat', 'stat',
  'other', 'other',
  'stat', 'stat', 'stat', 'stat', 'stat', 'stat',
  'meta', 'meta', 'other', 'thrash', 'flow', 'multihit', 'other',
  'status_side', 'status_primary',
  'status_side', 'status_side', 'status_side', 'status_side', 'status_side',
  'fixed', 'charge', 'fixed', 'fixed', 'trap', 'charge', 'multihit', 'recoil',
  'volatile', 'volatile', 'recoil', 'status_primary',
  'stat', 'stat', 'stat', 'stat', 'stat', 'stat',
  'heal', 'meta',
  'stat', 'stat', 'stat', 'stat', 'stat', 'stat',
  'volatile', 'volatile',
  'status_primary', 'status_primary',
  'status_side', 'status_side', 'status_side', 'status_side',
  'unused', 'unused', 'unused', 'unused',
  'status_side', 'multihit', 'unused', 'volatile', 'flow', 'other', 'meta',
  'meta', 'volatile', 'other', 'volatile',
];

const STAGE_MIN = -6;
const STAGE_MAX = 6;

// Gen1 stage multipliers as percents (25/100 .. 400/100).
const STAGE_MULT = {
  [-6]: 25, [-5]: 28, [-4]: 33, [-3]: 40, [-2]: 50, [-1]: 66,
  0: 100,
  1: 150, 2: 200, 3: 250, 4: 300, 5: 350, 6: 400,
};

const BY_NAME = Object.create(null);
for (let id = 0; id < NAMES.length; id += 1) {
  BY_NAME[NAMES[id]] = id;
}

function int(value, fallback) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.floor(n);
}

function idOf(name) {
  if (typeof name !== 'string') return null;
  const hit = BY_NAME[name];
  return hit === undefined ? null : hit;
}

function nameOf(id) {
  const n = int(id, null);
  if (n === null || n < 0 || n >= NAMES.length) return null;
  return NAMES[n];
}

function category(id) {
  const n = int(id, null);
  if (n === null || n < 0 || n >= CATEGORIES.length) return null;
  return CATEGORIES[n];
}

function clampStage(stage) {
  const s = int(stage, 0);
  if (s < STAGE_MIN) return STAGE_MIN;
  if (s > STAGE_MAX) return STAGE_MAX;
  return s;
}

function stageMult(stage) {
  return STAGE_MULT[clampStage(stage)];
}

function applyStage(base, stage) {
  return Math.floor(Math.max(0, int(base, 0)) * stageMult(stage) / 100);
}

// Gen1 ApplyBadgeStatBoosts: ×9/8 when the fighter holds the matching badge.
const BADGE_FOR_STAT = {
  atk: 'BOULDERBADGE',
  def: 'THUNDERBADGE',
  spe: 'SOULBADGE',
  spa: 'VOLCANOBADGE',
  spd: 'MARSHBADGE',
};

function badgeBoost(statValue, wireStatKey, badges) {
  const base = Math.max(0, int(statValue, 0));
  if (!badges || typeof badges !== 'object') return base;
  const badge = BADGE_FOR_STAT[wireStatKey];
  if (!badge || !badges[badge]) return base;
  return Math.floor((base * 9) / 8);
}

// ------------------------------------------------------------------
// Phase 1 primary handlers
// ------------------------------------------------------------------

const STAT_LABELS = {
  atk: 'ATTACK', def: 'DEFENSE', spe: 'SPEED',
  spa: 'SP.ATK', spd: 'SP.DEF', acc: 'ACCURACY', eva: 'EVASION',
};

// effect id -> { stat, delta, selfTarget }
const STAT_EFFECTS = {
  10: { stat: 'atk', delta: 1, selfTarget: true },
  11: { stat: 'def', delta: 1, selfTarget: true },
  12: { stat: 'spe', delta: 1, selfTarget: true },
  13: { stat: 'spa', delta: 1, selfTarget: true },
  14: { stat: 'acc', delta: 1, selfTarget: true },
  15: { stat: 'eva', delta: 1, selfTarget: true },
  18: { stat: 'atk', delta: -1, selfTarget: false },
  19: { stat: 'def', delta: -1, selfTarget: false },
  20: { stat: 'spe', delta: -1, selfTarget: false },
  21: { stat: 'spa', delta: -1, selfTarget: false },
  22: { stat: 'acc', delta: -1, selfTarget: false },
  23: { stat: 'eva', delta: -1, selfTarget: false },
  50: { stat: 'atk', delta: 2, selfTarget: true },
  51: { stat: 'def', delta: 2, selfTarget: true },
  52: { stat: 'spe', delta: 2, selfTarget: true },
  53: { stat: 'spa', delta: 2, selfTarget: true },
  54: { stat: 'acc', delta: 2, selfTarget: true },
  55: { stat: 'eva', delta: 2, selfTarget: true },
  58: { stat: 'atk', delta: -2, selfTarget: false },
  59: { stat: 'def', delta: -2, selfTarget: false },
  60: { stat: 'spe', delta: -2, selfTarget: false },
  61: { stat: 'spa', delta: -2, selfTarget: false },
  62: { stat: 'acc', delta: -2, selfTarget: false },
  63: { stat: 'eva', delta: -2, selfTarget: false },
};

const PHASE1_PRIMARY = {
  10: true, 11: true, 12: true, 13: true, 14: true, 15: true,
  18: true, 19: true, 20: true, 21: true, 22: true, 23: true,
  25: true, 32: true, 49: true, 50: true, 51: true, 52: true,
  53: true, 54: true, 55: true, 56: true, 58: true, 59: true,
  60: true, 61: true, 62: true, 63: true, 66: true, 67: true,
  84: true, 85: true, 86: true,
};

function isPhase1Primary(effectId) {
  const n = int(effectId, null);
  if (n === null) return false;
  return PHASE1_PRIMARY[n] === true;
}

const PHASE5_VOLATILE = {
  24: true, 46: true, 47: true, 57: true,
  64: true, 65: true, 79: true,
};

const PHASE6_PRIMARY = {
  82: true, // MIMIC_EFFECT
};

function isPhase5Volatile(effectId) {
  const n = int(effectId, null);
  if (n === null) return false;
  return PHASE5_VOLATILE[n] === true;
}

function isPhase6Primary(effectId) {
  const n = int(effectId, null);
  if (n === null) return false;
  return PHASE6_PRIMARY[n] === true;
}

function handlesPrimary(effectId) {
  return isPhase1Primary(effectId) || isPhase5Volatile(effectId)
    || isPhase6Primary(effectId);
}

function hasMajorStatus(mon) {
  if (!mon || !mon.status) return false;
  const s = mon.status;
  return s === 'sleep' || s === 'poison' || s === 'burn'
    || s === 'freeze' || s === 'paralysis' || s === 'toxic';
}

function fighterFields(fighter) {
  return { slot: fighter.slot, side: fighter.side };
}

function applyStatChange(out, fighter, mon, stat, delta) {
  if (delta < 0 && mon.mist) {
    out.messages.push('But it failed');
    return;
  }
  const label = STAT_LABELS[stat] || stat;
  const before = clampStage(mon.stages[stat]);
  const after = clampStage(before + delta);
  if (after === before) {
    if (delta > 0) {
      out.messages.push(`${mon.species}'s ${label} won't go any higher`);
    } else {
      out.messages.push(`${mon.species}'s ${label} won't go any lower`);
    }
    return;
  }
  mon.stages[stat] = after;
  const verb = delta > 0 ? 'rose' : 'fell';
  const text = `${mon.species}'s ${label} ${verb}`;
  out.messages.push(text);
  const fields = fighterFields(fighter);
  fields.amount = after;
  fields.text = text;
  out.events.push({ kind: 'stat', fields });
}

function resetStages(mon) {
  mon.stages.atk = 0;
  mon.stages.def = 0;
  mon.stages.spe = 0;
  mon.stages.spa = 0;
  mon.stages.spd = 0;
  mon.stages.acc = 0;
  mon.stages.eva = 0;
}

// ctx: effectId, rng, userMon, targetMon, userFighter, targetFighter,
//      moveIndex (1-based), statusToWire
function applyPrimary(ctx) {
  const out = {
    nothing: false, messages: [], events: [], heals: [], costs: [],
    directDamage: [],
  };
  const c = ctx || {};
  const effectId = int(c.effectId, 0);
  const {
    userMon, targetMon, userFighter, targetFighter, rng,
  } = c;
  const wire = c.statusToWire || {};

  if (effectId === 85) {
    out.nothing = true;
    return out;
  }

  if (effectId === 56) {
    const amount = Math.floor(Math.max(1, int(userMon.maxHp, 1)) / 2);
    out.heals.push({ amount });
    return out;
  }

  if (effectId === 25) {
    resetStages(userMon);
    resetStages(targetMon);
    out.messages.push('All stat changes were eliminated');
    return out;
  }

  const statFx = STAT_EFFECTS[effectId];
  if (statFx) {
    const mon = statFx.selfTarget ? userMon : targetMon;
    const fighter = statFx.selfTarget ? userFighter : targetFighter;
    applyStatChange(out, fighter, mon, statFx.stat, statFx.delta);
    return out;
  }

  if (effectId === 32) {
    if (hasMajorStatus(targetMon)) {
      out.nothing = true;
      return out;
    }
    const turns = (rng ? rng.byte() : 0) % 7 + 1;
    targetMon.status = 'sleep';
    targetMon.statusTurns = turns;
    const token = wire.sleep || 'SLP';
    const text = `${targetMon.species} fell asleep`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 66) {
    if (hasMajorStatus(targetMon)) {
      out.nothing = true;
      return out;
    }
    targetMon.status = 'poison';
    const token = wire.poison || 'PSN';
    const text = `${targetMon.species} was poisoned`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 67) {
    if (hasMajorStatus(targetMon)) {
      out.nothing = true;
      return out;
    }
    targetMon.status = 'paralysis';
    const token = wire.paralysis || 'PAR';
    const text = `${targetMon.species} is paralyzed`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 49) {
    if (targetMon.confusion && targetMon.confusion > 0) {
      out.nothing = true;
      return out;
    }
    const turns = (rng ? rng.byte() : 0) % 4 + 2;
    targetMon.confusion = turns;
    out.messages.push(`${targetMon.species} became confused`);
    return out;
  }

  if (effectId === 84) {
    if (targetMon.leechSeed) {
      out.nothing = true;
      return out;
    }
    targetMon.leechSeed = { fromSlot: userFighter.slot };
    const text = `${targetMon.species} was seeded`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 86) {
    const lastIdx = int(targetMon.lastMoveIndex, 0);
    if (lastIdx < 1 || !targetMon.moves[lastIdx - 1]) {
      out.nothing = true;
      return out;
    }
    if (targetMon.disable && targetMon.disable.turns && targetMon.disable.turns > 0) {
      out.nothing = true;
      return out;
    }
    const turns = (rng ? rng.byte() : 0) % 4 + 2;
    targetMon.disable = { moveIndex: lastIdx, turns };
    const moveId = targetMon.moves[lastIdx - 1].id || 'move';
    out.messages.push(`${moveId} was disabled`);
    return out;
  }

  if (effectId === 79) {
    const cost = Math.floor(Math.max(1, int(userMon.maxHp, 1)) / 4);
    if (userMon.substitute && userMon.substitute > 0) {
      out.nothing = true;
      return out;
    }
    if (userMon.hp <= cost) {
      out.nothing = true;
      return out;
    }
    userMon.hp -= cost;
    userMon.substitute = cost;
    out.directDamage = [{ amount: cost }];
    out.messages.push(`${userMon.species} created a substitute`);
    return out;
  }

  if (effectId === 64) {
    userMon.lightScreen = true;
    out.messages.push(`${userMon.species} created a light screen`);
    return out;
  }

  if (effectId === 65) {
    userMon.reflect = true;
    out.messages.push(`${userMon.species} created a reflect`);
    return out;
  }

  if (effectId === 46) {
    userMon.mist = true;
    out.messages.push(`${userMon.species} is shrouded in mist`);
    return out;
  }

  if (effectId === 47) {
    userMon.focusEnergy = true;
    out.messages.push(`${userMon.species} is getting pumped`);
    return out;
  }

  if (effectId === 24) {
    const foeType = targetMon.types[0] || 0;
    userMon.types = [foeType];
    out.messages.push(`${userMon.species} converted type`);
    return out;
  }

  if (effectId === 82) {
    const moveIndex = int(c.moveIndex, 0);
    const lastIdx = int(targetMon.lastMoveIndex, 0);
    if (lastIdx < 1 || lastIdx > targetMon.moves.length) {
      out.nothing = true;
      return out;
    }
    const source = targetMon.moves[lastIdx - 1];
    if (!source) {
      out.nothing = true;
      return out;
    }
    userMon.moves[moveIndex - 1] = {
      id: source.id || 'move',
      pp: Math.max(0, int(source.pp, 0)),
      power: Math.max(0, int(source.power, 0)),
      accuracy: Math.max(0, int(source.accuracy, 255)),
      type: Math.max(0, int(source.type, 0)),
      effect: Math.max(0, int(source.effect, 0)),
      chance: Math.max(0, int(source.chance, 0)),
    };
    out.messages.push(`${userMon.species} learned ${source.id || 'move'}`);
    out.movesChanged = true;
    return out;
  }

  if (effectId === 57) {
    userMon.stats.atk = Math.max(1, int(targetMon.stats.atk, 1));
    userMon.stats.def = Math.max(1, int(targetMon.stats.def, 1));
    userMon.stats.spe = Math.max(1, int(targetMon.stats.spe, 1));
    userMon.stats.spa = Math.max(1, int(targetMon.stats.spa, 1));
    userMon.stats.spd = Math.max(1, int(targetMon.stats.spd, 1));
    userMon.types = targetMon.types.length ? [...targetMon.types] : [0];
    userMon.stages.atk = clampStage(targetMon.stages.atk);
    userMon.stages.def = clampStage(targetMon.stages.def);
    userMon.stages.spe = clampStage(targetMon.stages.spe);
    userMon.stages.spa = clampStage(targetMon.stages.spa);
    userMon.stages.spd = clampStage(targetMon.stages.spd);
    userMon.stages.acc = clampStage(targetMon.stages.acc);
    userMon.stages.eva = clampStage(targetMon.stages.eva);
    userMon.moves = targetMon.moves.map((m) => ({
      id: m.id || 'move',
      pp: Math.max(0, int(m.pp, 0)),
      power: Math.max(0, int(m.power, 0)),
      accuracy: Math.max(0, int(m.accuracy, 255)),
      type: Math.max(0, int(m.type, 0)),
      effect: Math.max(0, int(m.effect, 0)),
      chance: Math.max(0, int(m.chance, 0)),
    }));
    userMon.transformed = true;
    out.messages.push(`${userMon.species} transformed into ${targetMon.species}`);
    out.movesChanged = true;
    return out;
  }

  out.nothing = true;
  return out;
}

// ------------------------------------------------------------------
// Phase 2 side-chance handlers (post-damage, damaging hits only)
// ------------------------------------------------------------------

// Same 1/256 quirk as Accuracy.js: byte is 0..255, threshold is
// floor(chance * 255 / 100), proc when byte < threshold. chance 0 never;
// chance 100 is byte < 255 (always except the 1/256 roll of 255).
function sideChanceProc(rng, chance) {
  let c = Math.max(0, Math.min(100, int(chance, 0)));
  if (c <= 0) return false;
  const threshold = Math.floor(c * 255 / 100);
  if (threshold <= 0) return false;
  return rng && rng.byte() < threshold;
}

const SIDE_STAT_DOWN = {
  68: 'atk', 69: 'def', 70: 'spe', 71: 'spa',
};

// ctx: effectId, chance, rng, targetMon, targetFighter, statusToWire
function applySide(ctx) {
  const out = { proc: false, messages: [], events: [] };
  const c = ctx || {};
  const effectId = int(c.effectId, 0);
  const chance = int(c.chance, 0);
  const { rng, targetMon, targetFighter } = c;
  const wire = c.statusToWire || {};

  if (!sideChanceProc(rng, chance)) return out;
  out.proc = true;

  if (effectId === 2 || effectId === 33 || effectId === 77) {
    if (hasMajorStatus(targetMon)) return out;
    targetMon.status = 'poison';
    const token = wire.poison || 'PSN';
    const text = `${targetMon.species} was poisoned`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 4 || effectId === 34) {
    if (hasMajorStatus(targetMon)) return out;
    targetMon.status = 'burn';
    const token = wire.burn || 'BRN';
    const text = `${targetMon.species} was burned`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 5 || effectId === 35) {
    if (hasMajorStatus(targetMon)) return out;
    targetMon.status = 'freeze';
    const token = wire.freeze || 'FRZ';
    const text = `${targetMon.species} was frozen solid`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 6 || effectId === 36) {
    if (hasMajorStatus(targetMon)) return out;
    targetMon.status = 'paralysis';
    const token = wire.paralysis || 'PAR';
    const text = `${targetMon.species} is paralyzed`;
    out.messages.push(text);
    const fields = fighterFields(targetFighter);
    fields.status = token;
    fields.text = text;
    out.events.push({ kind: 'status', fields });
    return out;
  }

  if (effectId === 31 || effectId === 37) {
    targetMon.flinch = true;
    return out;
  }

  const stat = SIDE_STAT_DOWN[effectId];
  if (stat) {
    applyStatChange(out, targetFighter, targetMon, stat, -1);
    return out;
  }

  if (effectId === 76) {
    if (targetMon.confusion && targetMon.confusion > 0) return out;
    const turns = (rng ? rng.byte() : 0) % 4 + 2;
    targetMon.confusion = turns;
    out.messages.push(`${targetMon.species} became confused`);
    return out;
  }

  out.proc = false;
  return out;
}

// ------------------------------------------------------------------
// Phase 3 multi-hit, fixed damage, drain, recoil
// ------------------------------------------------------------------

const MULTIHIT = { 29: true, 44: true, 77: true };
const FIXED_DAMAGE = { 38: true, 40: true, 41: true };
const DRAIN = { 3: true, 8: true };
const RECOIL = { 48: true };

function isMultihit(effectId) {
  return MULTIHIT[int(effectId, 0)] === true;
}

function hitCount(effectId, rng) {
  const id = int(effectId, 0);
  if (id === 44 || id === 77) return 2;
  if (id === 29) return 2 + (rng ? rng.byte() : 0) % 4;
  return 1;
}

function isFixedDamage(effectId) {
  return FIXED_DAMAGE[int(effectId, 0)] === true;
}

function isDrain(effectId) {
  return DRAIN[int(effectId, 0)] === true;
}

function isRecoil(effectId) {
  return RECOIL[int(effectId, 0)] === true;
}

function drainAmount(damage) {
  return Math.floor(Math.max(0, int(damage, 0)) / 2);
}

function recoilAmount(damage) {
  return Math.max(1, Math.floor(Math.max(0, int(damage, 0)) / 4));
}

function fixedDamage(ctx) {
  const c = ctx || {};
  const effectId = int(c.effectId, 0);
  const { userMon, targetMon } = c;
  const movePower = int(c.power, 0);
  const userSpeed = int(c.userSpeed, 0);
  const foeSpeed = int(c.foeSpeed, 0);

  if (effectId === 38) {
    if (userSpeed <= foeSpeed) return null;
    return Math.max(1, int(targetMon.hp, 0));
  }
  if (effectId === 40) {
    return Math.max(1, Math.floor(int(targetMon.hp, 0) / 2));
  }
  if (effectId === 41) {
    if (movePower >= 1) return movePower;
    return Math.max(1, int(userMon.level, 1));
  }
  return null;
}

// ------------------------------------------------------------------
// Phase 4 multi-turn / charge handlers
// ------------------------------------------------------------------

function isCharge(effectId) {
  const id = int(effectId, 0);
  return id === 39 || id === 43;
}

function isFly(effectId) {
  return int(effectId, 0) === 43;
}

function chargeMessage(mon, effectId) {
  if (isFly(effectId)) return `${mon.species} flew up high`;
  return `${mon.species} is glowing`;
}

function isTrapping(effectId) {
  return int(effectId, 0) === 42;
}

function trapTurns(rng) {
  return 2 + (rng ? rng.byte() : 0) % 4;
}

function isHyperBeam(effectId) {
  return int(effectId, 0) === 80;
}

function isThrash(effectId) {
  return int(effectId, 0) === 27;
}

function thrashTurns(rng) {
  return 2 + (rng ? rng.byte() : 0) % 2;
}

function isRage(effectId) {
  return int(effectId, 0) === 81;
}

// Gen1: Reflect halves physical, Light Screen halves special.
function screenDamage(damage, defender, isSpecial) {
  let d = Math.max(0, int(damage, 0));
  if (isSpecial) {
    if (defender.lightScreen) d = Math.floor(d / 2);
  } else if (defender.reflect) {
    d = Math.floor(d / 2);
  }
  return d;
}

// Gen1 category is type-based. specialTypes is a set of chart indices.
function isSpecialType(typeId, specialTypes) {
  if (!specialTypes || typeof specialTypes !== 'object') return false;
  return specialTypes[int(typeId, 0)] === true;
}

const ITEM_HEAL = {
  POTION: 20, SUPER_POTION: 50, HYPER_POTION: 200,
  FRESH_WATER: 50, SODA_POP: 60, LEMONADE: 80,
  BERRY: 10, BERRY_JUICE: 20,
};
const ITEM_STATUS = {
  ANTIDOTE: { poison: true, toxic: true },
  BURN_HEAL: { burn: true },
  ICE_HEAL: { freeze: true },
  AWAKENING: { sleep: true },
  PARLYZ_HEAL: { paralysis: true },
  FULL_HEAL: {
    poison: true, toxic: true, burn: true,
    freeze: true, sleep: true, paralysis: true,
  },
  PSNCUREBERRY: { poison: true, toxic: true },
  PRZCUREBERRY: { paralysis: true },
  BURNT_BERRY: { freeze: true },
  ICE_BERRY: { burn: true },
  MINT_BERRY: { sleep: true },
  MIRACLEBERRY: {
    poison: true, toxic: true, burn: true,
    freeze: true, sleep: true, paralysis: true,
  },
};
const ITEM_X_STAGE = {
  X_ATTACK: 'atk', X_DEFEND: 'def', X_SPEED: 'spe', X_SPECIAL: 'spa',
};
const ITEM_VITAMIN = {
  HP_UP: 'hp', PROTEIN: 'atk', IRON: 'def', CARBOS: 'spe', CALCIUM: 'spa',
};
const VITAMIN_GAIN = 2560;
const VITAMIN_FAIL_AT = 25600;
const ITEM_BALL = {
  POKE_BALL: true, GREAT_BALL: true, ULTRA_BALL: true,
  MASTER_BALL: true, SAFARI_BALL: true,
  LEVEL_BALL: true, LURE_BALL: true, MOON_BALL: true, FRIEND_BALL: true,
  FAST_BALL: true, HEAVY_BALL: true, LOVE_BALL: true, PARK_BALL: true,
};

// Deliberately absent from itemEffect (unknown → "But it failed", still spend
// the turn; bag upload also omits them): PP_UP / PP_UP_2, evolutionary stones,
// RARE_CANDY, HM/TM, Repel family, Escape Rope, and other field-only ids.
// In-battle catalog: heals, status cures, Revive/Ether/Elixer, X-items /
// Dire Hit / Guard Spec, balls, Poké Doll, Poké Flute, vitamins.

function itemEffect(itemId) {
  if (typeof itemId !== 'string' || !itemId) return null;
  if (itemId === 'MAX_POTION') return { healFull: true, needsParty: true };
  if (itemId === 'FULL_RESTORE') {
    return { healFull: true, clearAllStatus: true, needsParty: true };
  }
  if (itemId === 'REVIVE') {
    return { revive: 0.5, needsParty: true, faintedOnly: true };
  }
  if (itemId === 'MAX_REVIVE') {
    return { revive: 1, needsParty: true, faintedOnly: true };
  }
  if (itemId === 'ETHER') {
    return { ppRestore: 10, needsParty: true, needsMove: true };
  }
  if (itemId === 'MAX_ETHER') {
    return { ppRestore: true, needsParty: true, needsMove: true };
  }
  if (itemId === 'ELIXER' || itemId === 'ELIXIR') {
    return { ppRestoreAll: 10, needsParty: true };
  }
  if (itemId === 'MAX_ELIXER' || itemId === 'MAX_ELIXIR') {
    return { ppRestoreAll: true, needsParty: true };
  }
  if (itemId === 'X_ACCURACY') return { xAccuracy: true, activeOnly: true };
  if (itemId === 'DIRE_HIT') return { focusEnergy: true, activeOnly: true };
  if (itemId === 'GUARD_SPEC') return { mist: true, activeOnly: true };
  if (itemId === 'POKE_DOLL') return { pokeDoll: true };
  if (itemId === 'POKE_FLUTE') return { pokeFlute: true, noConsume: true };
  const stageStat = ITEM_X_STAGE[itemId];
  if (stageStat) return { stage: { stat: stageStat, delta: 1 }, activeOnly: true };
  const vitaminStat = ITEM_VITAMIN[itemId];
  if (vitaminStat) {
    return { vitamin: true, vitaminStat, needsParty: true };
  }
  if (ITEM_BALL[itemId]) return { ball: true };
  const heal = ITEM_HEAL[itemId];
  const statuses = ITEM_STATUS[itemId];
  if (heal === undefined && !statuses) return null;
  return { heal, clearStatuses: statuses, needsParty: true };
}

function applyVitamin(mon, itemId) {
  if (!mon || typeof mon !== 'object') return null;
  const effect = itemEffect(itemId);
  const stat = effect && effect.vitaminStat;
  if (!stat) return null;
  if (!mon.evs) mon.evs = {};
  const before = Math.max(0, int(mon.evs[stat], 0));
  if (before >= VITAMIN_FAIL_AT) return null;
  const after = Math.min(65535, before + VITAMIN_GAIN);
  mon.evs[stat] = after;
  const contrib = (ev) => Math.floor(Math.sqrt(Math.max(0, ev)) / 4);
  const level = Math.max(1, int(mon.level, 1));
  const delta = Math.floor((contrib(after) - contrib(before)) * level / 100);
  if (stat === 'hp') {
    mon.maxHp = Math.max(1, int(mon.maxHp, 1) + delta);
    mon.hp = Math.min(mon.maxHp, int(mon.hp, 0) + delta);
  } else {
    if (!mon.stats) mon.stats = {};
    mon.stats[stat] = Math.max(1, int(mon.stats[stat], 1) + delta);
  }
  return { stat, delta, before, after };
}

function caughtSheet(mon) {
  if (!mon || typeof mon !== 'object') return null;
  const moves = [];
  for (const m of mon.moves || []) {
    if (!m) continue;
    moves.push({
      id: m.id || 'move',
      pp: Math.max(0, int(m.pp, 0)),
      power: Math.max(0, int(m.power, 0)),
      accuracy: Math.max(0, int(m.accuracy, 255)),
      type: Math.max(0, int(m.type, 0)),
      effect: Math.max(0, int(m.effect, 0)),
      chance: Math.max(0, int(m.chance, 0)),
    });
  }
  if (!moves.length) return null;
  const out = {
    species: String(mon.species || '?'),
    level: Math.max(1, int(mon.level, 1)),
    hp: Math.max(0, int(mon.hp, 0)),
    maxHp: Math.max(1, int(mon.maxHp, 1)),
    stats: {
      atk: Math.max(1, int(mon.stats && mon.stats.atk, 1)),
      def: Math.max(1, int(mon.stats && mon.stats.def, 1)),
      spe: Math.max(1, int(mon.stats && mon.stats.spe, 1)),
      spa: Math.max(1, int(mon.stats && mon.stats.spa, 1)),
      spd: Math.max(1, int(mon.stats && mon.stats.spd, 1)),
    },
    moves,
    catchRate: Math.max(0, Math.min(255, int(mon.catchRate, 255))),
  };
  if (mon.speciesId) out.speciesId = String(mon.speciesId);
  if (Array.isArray(mon.types)) out.types = mon.types.slice();
  return out;
}

const BALL_DEFS = {
  MASTER_BALL: { autoCatch: true },
  POKE_BALL: { randMax: 255, hpFactor: 12, wobbleFactor: 255 },
  GREAT_BALL: { randMax: 200, hpFactor: 8, wobbleFactor: 200 },
  ULTRA_BALL: { randMax: 150, hpFactor: 12, wobbleFactor: 150 },
  SAFARI_BALL: { randMax: 150, hpFactor: 12, wobbleFactor: 150 },
};
const BALL_DEFAULT = { randMax: 255, hpFactor: 12, wobbleFactor: 150 };

function catchRoll(rng, maxV) {
  maxV = Math.max(0, int(maxV, 0));
  if (maxV <= 0) return 0;
  if (maxV >= 255) return rng ? rng.byte() : 0;
  return (rng ? rng.byte() : 0) % (maxV + 1);
}

function catchAttempt(ballId, targetMon, rng) {
  const def = BALL_DEFS[ballId] || BALL_DEFAULT;
  if (def.autoCatch) return { caught: true, shakes: 3 };

  let rate = int(targetMon && targetMon.catchRate, 255);
  if (rate < 0) rate = 0;
  else if (rate > 255) rate = 255;

  let statusBonus = 0;
  let shakeBonus = 5;
  const s = targetMon && targetMon.status;
  if (s === 'sleep' || s === 'freeze') {
    statusBonus = 25;
    shakeBonus = 10;
  } else if (s) {
    statusBonus = 12;
    shakeBonus = 5;
  }

  const maxhp = Math.max(1, int(targetMon && targetMon.maxHp, 1));
  const hp = Math.max(0, int(targetMon && targetMon.hp, 0));
  const hpQuarter = Math.max(1, Math.floor(hp / 4));
  const factor = def.hpFactor || BALL_DEFAULT.hpFactor;
  const f = Math.min(255, Math.floor(Math.floor(maxhp * 255 / factor) / hpQuarter));

  function shakes() {
    const ballFactor2 = def.wobbleFactor || BALL_DEFAULT.wobbleFactor;
    const y = Math.floor(rate * 100 / ballFactor2);
    let z = y > 255 ? 255 : Math.floor(f * y / 255);
    if (s) z += shakeBonus;
    if (z < 10) return 0;
    if (z < 30) return 1;
    if (z < 70) return 2;
    return 3;
  }

  const r = catchRoll(rng, def.randMax || 255) - statusBonus;
  if (r < 0) return { caught: true, shakes: 3 };
  if (r > rate) return { caught: false, shakes: shakes() };
  if (catchRoll(rng, 255) <= f) return { caught: true, shakes: 3 };
  return { caught: false, shakes: shakes() };
}

function isWildMode(mode) {
  return typeof mode === 'string' && mode.includes('wild');
}

// ------------------------------------------------------------------
// Phase 6 meta / flow handlers
// ------------------------------------------------------------------

const NO_OP = {
  1: true, 30: true,
  72: true, 73: true, 74: true, 75: true, 78: true,
};

function isNoOp(effectId) {
  return NO_OP[int(effectId, 0)] === true;
}

function isBide(effectId) {
  return int(effectId, 0) === 26;
}

function bideTurns(rng) {
  return 2 + (rng ? rng.byte() : 0) % 2;
}

function isExplode(effectId) {
  return int(effectId, 0) === 7;
}

function isJumpKick(effectId) {
  return int(effectId, 0) === 45;
}

function jumpKickCrash(maxHp) {
  return Math.max(1, Math.floor(Math.max(1, int(maxHp, 1)) / 8));
}

function isSwitchAndTeleport(effectId) {
  return int(effectId, 0) === 28;
}

// Mediated modes (1v1, coop_*) have no wild flee; only modes whose name
// contains "wild" may treat Teleport as a successful run.
function teleportRunAllowed(mode) {
  return typeof mode === 'string' && mode.includes('wild');
}

function isPayDay(effectId) {
  return int(effectId, 0) === 16;
}

function isMirrorMove(effectId) {
  return int(effectId, 0) === 9;
}

function isMimic(effectId) {
  return int(effectId, 0) === 82;
}

function isMetronome(effectId) {
  return int(effectId, 0) === 83;
}

module.exports = {
  NAMES,
  CATEGORIES,
  STAGE_MIN,
  STAGE_MAX,
  STAGE_MULT,
  idOf,
  nameOf,
  category,
  clampStage,
  stageMult,
  applyStage,
  badgeBoost,
  isPhase1Primary,
  isPhase5Volatile,
  isPhase6Primary,
  handlesPrimary,
  hasMajorStatus,
  applyPrimary,
  sideChanceProc,
  applySide,
  isMultihit,
  hitCount,
  isFixedDamage,
  isDrain,
  isRecoil,
  drainAmount,
  recoilAmount,
  fixedDamage,
  isCharge,
  isFly,
  chargeMessage,
  isTrapping,
  trapTurns,
  isHyperBeam,
  isThrash,
  thrashTurns,
  isRage,
  screenDamage,
  isSpecialType,
  itemEffect,
  applyVitamin,
  caughtSheet,
  catchAttempt,
  isWildMode,
  isNoOp,
  isBide,
  bideTurns,
  isExplode,
  isJumpKick,
  jumpKickCrash,
  isSwitchAndTeleport,
  teleportRunAllowed,
  isPayDay,
  isMirrorMove,
  isMimic,
  isMetronome,
};
