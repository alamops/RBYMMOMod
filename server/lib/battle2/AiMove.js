'use strict';

/*
 * AIChooseMove: the computer's move choice on Gold / Silver / Crystal.
 *
 * Node twin of src/BattleSim2/AiMove.lua, line for line; the Lua header and
 * comments carry every pokecrystal / pokegold citation (engine/battle/ai/
 * move.asm, scoring.asm, redundant.asm, switch.asm's CheckPlayerMoveType-
 * Matchups, core.asm's ParseEnemyAction) and only what the port has to keep
 * true is restated here.
 *
 * A pure module over the referee's battle state: it reads `fighter.mons`, the
 * stages, the volatile fields, the screens, the weather and `fighter.aiFlags`
 * (TRNATTR_AI_MOVE_WEIGHTS, contract K16) and changes nothing on them; the
 * only thing it moves is `battle.rng`, one byte where the cart calls `Random`,
 * in the cart's order. Indexing: `fighter.active`, a slot and `moveIndex` are
 * 1-based as in the Lua; the arrays (`mons`, `moves`, `types`, `scores`) are
 * 0-based here.
 *
 * State the referee does not keep, read from named fields with a default:
 * `mon.turnsTaken` (wPlayerTurnsTaken / wEnemyTurnsTaken, 0: DoTurn's count --
 * a lock-in's first turn only; the Lua twin explains) and the player's
 * `mon.usedMoves` (wPlayerUsedMoves, empty), both kept by Turn.
 */

const Damage = require('./Damage.js');
const Effects = require('./Effects.js');
const Items = require('./Items.js');

const NUM_MOVES = 4;
const BASE_SCORE = 20;
const UNUSABLE_SCORE = 80;
const DISMISS = 10;
const BASE_STAT_LEVEL = 7;
const MAX_STAT_LEVEL = 13;
const EFFECTIVE = 10;
const BASE_AI_SWITCH_SCORE = 10;
const LAYERS = [
  'BASIC', 'SETUP', 'TYPES', 'OFFENSIVE', 'SMART',
  'OPPORTUNIST', 'AGGRESSIVE', 'CAUTIOUS', 'STATUS', 'RISKY',
];
const LAYER_SLOTS = 16;
const REDRAW_LIMIT = 1024;
const LINK_MODES = { '1v1': true, coop_pvp: true };

// The `percent` thresholds (macros/data.asm).
const P4 = 10; const P8 = 20; const P10 = 25; const P12 = 30; const P16 = 40;
const P20M1 = 50;
const P28M1 = 70;
const P31P1 = 80;
const P35P1 = 90;
const P39P1 = 100;
const P50P1 = 128;
const P70 = 178;
const P71M1 = 180;
const P79M1 = 200;
const P90P1 = 230;

// constants/move_effect_constants.asm, in order.
const CART_EFFECTS = [
  'EFFECT_NORMAL_HIT', 'EFFECT_SLEEP', 'EFFECT_POISON_HIT', 'EFFECT_LEECH_HIT',
  'EFFECT_BURN_HIT', 'EFFECT_FREEZE_HIT', 'EFFECT_PARALYZE_HIT', 'EFFECT_SELFDESTRUCT',
  'EFFECT_DREAM_EATER', 'EFFECT_MIRROR_MOVE', 'EFFECT_ATTACK_UP', 'EFFECT_DEFENSE_UP',
  'EFFECT_SPEED_UP', 'EFFECT_SP_ATK_UP', 'EFFECT_SP_DEF_UP', 'EFFECT_ACCURACY_UP',
  'EFFECT_EVASION_UP', 'EFFECT_ALWAYS_HIT', 'EFFECT_ATTACK_DOWN', 'EFFECT_DEFENSE_DOWN',
  'EFFECT_SPEED_DOWN', 'EFFECT_SP_ATK_DOWN', 'EFFECT_SP_DEF_DOWN', 'EFFECT_ACCURACY_DOWN',
  'EFFECT_EVASION_DOWN', 'EFFECT_RESET_STATS', 'EFFECT_BIDE', 'EFFECT_RAMPAGE',
  'EFFECT_FORCE_SWITCH', 'EFFECT_MULTI_HIT', 'EFFECT_CONVERSION', 'EFFECT_FLINCH_HIT',
  'EFFECT_HEAL', 'EFFECT_TOXIC', 'EFFECT_PAY_DAY', 'EFFECT_LIGHT_SCREEN',
  'EFFECT_TRI_ATTACK', 'EFFECT_UNUSED_25', 'EFFECT_OHKO', 'EFFECT_RAZOR_WIND',
  'EFFECT_SUPER_FANG', 'EFFECT_STATIC_DAMAGE', 'EFFECT_TRAP_TARGET', 'EFFECT_UNUSED_2B',
  'EFFECT_DOUBLE_HIT', 'EFFECT_JUMP_KICK', 'EFFECT_MIST', 'EFFECT_FOCUS_ENERGY',
  'EFFECT_RECOIL_HIT', 'EFFECT_CONFUSE', 'EFFECT_ATTACK_UP_2', 'EFFECT_DEFENSE_UP_2',
  'EFFECT_SPEED_UP_2', 'EFFECT_SP_ATK_UP_2', 'EFFECT_SP_DEF_UP_2', 'EFFECT_ACCURACY_UP_2',
  'EFFECT_EVASION_UP_2', 'EFFECT_TRANSFORM', 'EFFECT_ATTACK_DOWN_2', 'EFFECT_DEFENSE_DOWN_2',
  'EFFECT_SPEED_DOWN_2', 'EFFECT_SP_ATK_DOWN_2', 'EFFECT_SP_DEF_DOWN_2',
  'EFFECT_ACCURACY_DOWN_2', 'EFFECT_EVASION_DOWN_2', 'EFFECT_REFLECT', 'EFFECT_POISON',
  'EFFECT_PARALYZE', 'EFFECT_ATTACK_DOWN_HIT', 'EFFECT_DEFENSE_DOWN_HIT',
  'EFFECT_SPEED_DOWN_HIT', 'EFFECT_SP_ATK_DOWN_HIT', 'EFFECT_SP_DEF_DOWN_HIT',
  'EFFECT_ACCURACY_DOWN_HIT', 'EFFECT_EVASION_DOWN_HIT', 'EFFECT_SKY_ATTACK',
  'EFFECT_CONFUSE_HIT', 'EFFECT_POISON_MULTI_HIT', 'EFFECT_UNUSED_4E', 'EFFECT_SUBSTITUTE',
  'EFFECT_HYPER_BEAM', 'EFFECT_RAGE', 'EFFECT_MIMIC', 'EFFECT_METRONOME',
  'EFFECT_LEECH_SEED', 'EFFECT_SPLASH', 'EFFECT_DISABLE', 'EFFECT_LEVEL_DAMAGE',
  'EFFECT_PSYWAVE', 'EFFECT_COUNTER', 'EFFECT_ENCORE', 'EFFECT_PAIN_SPLIT', 'EFFECT_SNORE',
  'EFFECT_CONVERSION2', 'EFFECT_LOCK_ON', 'EFFECT_SKETCH', 'EFFECT_DEFROST_OPPONENT',
  'EFFECT_SLEEP_TALK', 'EFFECT_DESTINY_BOND', 'EFFECT_REVERSAL', 'EFFECT_SPITE',
  'EFFECT_FALSE_SWIPE', 'EFFECT_HEAL_BELL', 'EFFECT_PRIORITY_HIT', 'EFFECT_TRIPLE_KICK',
  'EFFECT_THIEF', 'EFFECT_MEAN_LOOK', 'EFFECT_NIGHTMARE', 'EFFECT_FLAME_WHEEL',
  'EFFECT_CURSE', 'EFFECT_UNUSED_6E', 'EFFECT_PROTECT', 'EFFECT_SPIKES', 'EFFECT_FORESIGHT',
  'EFFECT_PERISH_SONG', 'EFFECT_SANDSTORM', 'EFFECT_ENDURE', 'EFFECT_ROLLOUT',
  'EFFECT_SWAGGER', 'EFFECT_FURY_CUTTER', 'EFFECT_ATTRACT', 'EFFECT_RETURN',
  'EFFECT_PRESENT', 'EFFECT_FRUSTRATION', 'EFFECT_SAFEGUARD', 'EFFECT_SACRED_FIRE',
  'EFFECT_MAGNITUDE', 'EFFECT_BATON_PASS', 'EFFECT_PURSUIT', 'EFFECT_RAPID_SPIN',
  'EFFECT_UNUSED_82', 'EFFECT_UNUSED_83', 'EFFECT_MORNING_SUN', 'EFFECT_SYNTHESIS',
  'EFFECT_MOONLIGHT', 'EFFECT_HIDDEN_POWER', 'EFFECT_RAIN_DANCE', 'EFFECT_SUNNY_DAY',
  'EFFECT_DEFENSE_UP_HIT', 'EFFECT_ATTACK_UP_HIT', 'EFFECT_ALL_UP_HIT', 'EFFECT_FAKE_OUT',
  'EFFECT_BELLY_DRUM', 'EFFECT_PSYCH_UP', 'EFFECT_MIRROR_COAT', 'EFFECT_SKULL_BASH',
  'EFFECT_TWISTER', 'EFFECT_EARTHQUAKE', 'EFFECT_FUTURE_SIGHT', 'EFFECT_GUST',
  'EFFECT_STOMP', 'EFFECT_SOLARBEAM', 'EFFECT_THUNDER', 'EFFECT_TELEPORT',
  'EFFECT_BEAT_UP', 'EFFECT_FLY', 'EFFECT_DEFENSE_CURL',
];
const CART_EFFECT_NUM = {};
for (let num = 0; num < CART_EFFECTS.length; num += 1) CART_EFFECT_NUM[CART_EFFECTS[num]] = num;

// The referee's effect id back to the cart's number (the Lua twin explains).
const FROM_REFEREE = new Map();
for (let num = 0; num < CART_EFFECTS.length; num += 1) {
  const id = Effects.idOf(CART_EFFECTS[num]);
  if (id !== null && id !== undefined && !FROM_REFEREE.has(id)) FROM_REFEREE.set(id, num);
}

// Lua's `tonumber` then `floor`: nil, a boolean or a blank string is the
// fallback, NaN is the fallback.
function int(value, fallback) {
  if (value === null || value === undefined || typeof value === 'boolean') return fallback;
  if (typeof value === 'string' && value.trim() === '') return fallback;
  const n = Number(value);
  if (Number.isNaN(n)) return fallback;
  return Math.floor(n);
}

// Lua's `%` on a positive modulus: never negative.
function mod(a, b) {
  return ((a % b) + b) % b;
}

function byte(value) {
  return mod(int(value, 0), 256);
}

function isTable(value) {
  return typeof value === 'object' && value !== null;
}

// Lua's `not value`: nil and false only (0 and '' are true there).
function blank(value) {
  return value === null || value === undefined || value === false;
}

// The cart's effect number of a move record (-1: none the cart has).
function cartEffect(rec) {
  if (!isTable(rec)) return -1;
  const id = int(rec.effect, 0);
  if (id === 0) {
    if (Effects.moveKey(rec) === Items.THIEF) return CART_EFFECT_NUM.EFFECT_THIEF;
    if (Effects.movePriority(rec) === 2) return CART_EFFECT_NUM.EFFECT_PRIORITY_HIT;
    return 0;
  }
  const num = FROM_REFEREE.get(id);
  if (num === undefined) return -1;
  return num;
}

function set(list) {
  return new Set(list);
}

function effectSet(names) {
  return new Set(names.map((name) => CART_EFFECT_NUM[name]));
}

// data/battle/ai/*.asm (pokecrystal and pokegold the same).
const STATUS_ONLY_EFFECTS = effectSet([
  'EFFECT_SLEEP', 'EFFECT_TOXIC', 'EFFECT_POISON', 'EFFECT_PARALYZE',
]);
const USEFUL_MOVES = set([
  'DOUBLE_EDGE', 'SING', 'FLAMETHROWER', 'HYDRO_PUMP', 'SURF', 'ICE_BEAM', 'BLIZZARD',
  'HYPER_BEAM', 'SLEEP_POWDER', 'THUNDERBOLT', 'THUNDER', 'EARTHQUAKE', 'TOXIC',
  'PSYCHIC_M', 'HYPNOSIS', 'RECOVER', 'FIRE_BLAST', 'SOFTBOILED', 'SUPER_FANG',
]);
const ENCORE_MOVES = set([
  'SWORDS_DANCE', 'WHIRLWIND', 'LEER', 'ROAR', 'DISABLE', 'MIST', 'LEECH_SEED', 'GROWTH',
  'POISONPOWDER', 'STRING_SHOT', 'MEDITATE', 'AGILITY', 'TELEPORT', 'SCREECH', 'HAZE',
  'FOCUS_ENERGY', 'DREAM_EATER', 'POISON_GAS', 'SPLASH', 'SHARPEN', 'CONVERSION',
  'SUPER_FANG', 'SUBSTITUTE', 'TRIPLE_KICK', 'SPIDER_WEB', 'MIND_READER', 'FLAME_WHEEL',
  'AEROBLAST', 'COTTON_SPORE', 'POWDER_SNOW',
]);
const RAIN_DANCE_MOVES = [
  'WATER_GUN', 'HYDRO_PUMP', 'SURF', 'BUBBLEBEAM', 'THUNDER', 'WATERFALL', 'CLAMP',
  'BUBBLE', 'CRABHAMMER', 'OCTAZOOKA', 'WHIRLPOOL',
];
// The cart's list, without SOLARBEAM, FLAME_WHEEL and MOONLIGHT (the bug).
const SUNNY_DAY_MOVES = [
  'FIRE_PUNCH', 'EMBER', 'FLAMETHROWER', 'FIRE_SPIN', 'FIRE_BLAST', 'SACRED_FIRE',
  'MORNING_SUN', 'SYNTHESIS',
];
const STALL_MOVES = set([
  'SWORDS_DANCE', 'TAIL_WHIP', 'LEER', 'GROWL', 'DISABLE', 'MIST', 'COUNTER',
  'LEECH_SEED', 'GROWTH', 'STRING_SHOT', 'MEDITATE', 'AGILITY', 'RAGE', 'MIMIC',
  'SCREECH', 'HARDEN', 'WITHDRAW', 'DEFENSE_CURL', 'BARRIER', 'LIGHT_SCREEN', 'HAZE',
  'REFLECT', 'FOCUS_ENERGY', 'BIDE', 'AMNESIA', 'TRANSFORM', 'SPLASH', 'ACID_ARMOR',
  'SHARPEN', 'CONVERSION', 'SUBSTITUTE', 'FLAME_WHEEL',
]);
const RECKLESS_EFFECTS = effectSet([
  'EFFECT_SELFDESTRUCT', 'EFFECT_RAMPAGE', 'EFFECT_MULTI_HIT', 'EFFECT_DOUBLE_HIT',
]);
const CONSTANT_DAMAGE_EFFECTS = effectSet([
  'EFFECT_SUPER_FANG', 'EFFECT_STATIC_DAMAGE', 'EFFECT_LEVEL_DAMAGE', 'EFFECT_PSYWAVE',
]);
const RESIDUAL_MOVES = set([
  'MIST', 'LEECH_SEED', 'POISONPOWDER', 'STUN_SPORE', 'THUNDER_WAVE', 'FOCUS_ENERGY',
  'BIDE', 'POISON_GAS', 'TRANSFORM', 'CONVERSION', 'SUBSTITUTE', 'SPIKES',
]);
const RISKY_EFFECTS = effectSet(['EFFECT_SELFDESTRUCT', 'EFFECT_OHKO']);

const E = CART_EFFECT_NUM;

// ------------------------------------------------------------------
// the cart's state, read off the referee's
// ------------------------------------------------------------------

const SLP_MASK = 7; const PSN_BIT = 8; const BRN_BIT = 16; const FRZ_BIT = 32; const PAR_BIT = 64;
function statusByte(mon) {
  const s = mon && mon.status;
  if (s === 'sleep') return mod(int(mon.statusTurns, 0), 8);
  if (s === 'poison' || s === 'toxic') return PSN_BIT;
  if (s === 'burn') return BRN_BIT;
  if (s === 'freeze') return FRZ_BIT;
  if (s === 'paralysis') return PAR_BIT;
  return 0;
}

function band(a, b) {
  return a & b;
}

function sleepTurns(mon) { return band(statusByte(mon), SLP_MASK); }

function level(mon, key) {
  return BASE_STAT_LEVEL + Effects.clampStage(mon.stages && mon.stages[key]);
}

function toxic(mon) {
  return mon.status === 'toxic' || mon.toxicLatent === true;
}

function confused(mon) { return int(mon.confusion, 0) > 0; }
function rolling(mon) {
  return isTable(mon.rollout) && mon.rollout.active === true;
}

function type1(mon) { return int(mon.types && mon.types[0], 0); }
function type2(mon) {
  const t = mon.types && mon.types[1];
  if (t === null || t === undefined) return type1(mon);
  return int(t, 0);
}

function typeName(ctx, t) {
  if (t === null || t === undefined) return null;
  return ctx.battle._typeIdOf(t);
}

function special(ctx, t) {
  return Effects.isSpecialType(t, ctx.battle.specialTypes);
}

// The referee's stat snapshot put back as it was (no key added where none was).
function keepSnap(mon, snap) {
  if (mon.statSnap !== snap) mon.statSnap = snap;
}

// A battle stat (wBattleMonSpeed / wEnemyMonSpeed).
function speedOf(ctx, fighter, mon) {
  const snap = mon.statSnap;
  const value = ctx.battle._speedOf(fighter, mon);
  keepSnap(mon, snap);
  return int(value, 0);
}

function typeIndexOf(typeIds, name) {
  if (!Array.isArray(typeIds) || typeof name !== 'string') return null;
  for (let i = 0; i < typeIds.length; i += 1) {
    if (typeIds[i] === name) return i;
  }
  return null;
}

function recType(ctx, rec) {
  if (rec.typeId) {
    const index = typeIndexOf(ctx.battle.typeIds, rec.typeId);
    if (index !== null) return index;
  }
  return int(rec.type, 0);
}

// AIGetEnemyMove.
function load(ctx, rec) {
  ctx.cur = {
    rec,
    id: Effects.moveKey(rec),
    effect: cartEffect(rec),
    power: byte(rec.power),
    type: recType(ctx, rec),
    acc: byte(rec.accuracy),
  };
  return ctx.cur;
}

// The four move slots, 1-based: a record or null.
function slot(ctx, i) {
  const { moves } = ctx.mon;
  const rec = Array.isArray(moves) ? moves[i - 1] : null;
  if (!isTable(rec)) return null;
  return rec;
}

// ------------------------------------------------------------------
// the HP and speed checks
// ------------------------------------------------------------------

function above(mon, shift) {
  return mod(int(mon.hp, 0) * shift, 65536) > mod(int(mon.maxHp, 0), 65536);
}
function enemyHalf(ctx) { return above(ctx.mon, 2); }
function enemyQuarter(ctx) { return above(ctx.mon, 4); }
function playerHalf(ctx) { return above(ctx.foeMon, 2); }
function playerQuarter(ctx) { return above(ctx.foeMon, 4); }
function enemyMax(ctx) {
  return mod(int(ctx.mon.hp, 0), 65536) === mod(int(ctx.mon.maxHp, 0), 65536);
}
function playerMax(ctx) {
  return mod(int(ctx.foeMon.hp, 0), 65536) === mod(int(ctx.foeMon.maxHp, 0), 65536);
}

function enemyFaster(ctx) {
  return speedOf(ctx, ctx.fighter, ctx.mon) > speedOf(ctx, ctx.foe, ctx.foeMon);
}

// FindAliveEnemyMons' carry.
function enemyLastMon(ctx) {
  const mons = ctx.fighter.mons;
  if (mons.length < 2) return true;
  for (let i = 1; i <= mons.length; i += 1) {
    if (i !== ctx.fighter.active && int(mons[i - 1].hp, 0) !== 0) return false;
  }
  return true;
}

// AICheckLastPlayerMon's nz.
function playerHasOthers(ctx) {
  const mons = ctx.foe.mons;
  for (let i = 1; i <= mons.length; i += 1) {
    if (i !== ctx.foe.active && int(mons[i - 1].hp, 0) !== 0) return true;
  }
  return false;
}

// AIHasMoveEffect.
function hasMoveEffect(ctx, effect) {
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec) return false;
    if (load(ctx, rec).effect === effect) return true;
  }
  return false;
}

// AIHasMoveInArray.
function hasMoveInArray(ctx, list) {
  for (const id of list) {
    for (let i = 1; i <= NUM_MOVES; i += 1) {
      const rec = slot(ctx, i);
      if (rec && Effects.moveKey(rec) === id) return true;
    }
  }
  return false;
}

// ------------------------------------------------------------------
// the draws
// ------------------------------------------------------------------

function random(ctx) {
  ctx.draws += 1;
  return ctx.battle.rng.byte();
}

function ai8020(ctx) { return random(ctx) < P20M1; }
function ai5050(ctx) { return random(ctx) < P50P1; }

// ------------------------------------------------------------------
// the score bytes
// ------------------------------------------------------------------

function add(ctx, i, n) {
  ctx.scores[i - 1] = mod(ctx.scores[i - 1] + n, 256);
}
function dismiss(ctx, i) { add(ctx, i, DISMISS); }

// ------------------------------------------------------------------
// type matchups
// ------------------------------------------------------------------

function matchupStep(ctx, m, t, defType, probe) {
  let pct = int(ctx.battle._matchupCell(t, defType, probe), 100);
  if (pct < 0) pct = 0;
  return Math.floor(m * Math.floor(pct / 10) / 10);
}

function matchup(ctx, t, defType1, defType2, identified) {
  if (t === null || t === undefined) return EFFECTIVE;
  const probe = { identified: identified === true };
  let m = matchupStep(ctx, EFFECTIVE, t, defType1, probe);
  if (defType2 !== defType1) m = matchupStep(ctx, m, t, defType2, probe);
  return mod(m, 256);
}

function moveType(ctx) {
  if (ctx.turn === 1) return ctx.cur ? ctx.cur.type : null;
  return ctx.playerMoveType;
}
function oppIdentified(ctx) {
  if (ctx.turn === 1) return ctx.foeMon.identified === true;
  return ctx.mon.identified === true;
}

function checkTypeMatchup(ctx, defender) {
  return matchup(ctx, moveType(ctx), type1(defender), type2(defender), oppIdentified(ctx));
}

function battleCheckTypeMatchup(ctx) {
  if (ctx.turn === 1) return checkTypeMatchup(ctx, ctx.foeMon);
  return checkTypeMatchup(ctx, ctx.mon);
}

// CheckPlayerMoveTypeMatchups as AI_Smart calls it.
function checkPlayerMoveTypeMatchups(ctx) {
  let score = BASE_AI_SWITCH_SCORE;
  const { foeMon, mon } = ctx;
  const used = Array.isArray(foeMon.usedMoves) ? foeMon.usedMoves : [];
  if (blank(used[0])) {
    if (checkTypeMatchup(ctx, mon) >= EFFECTIVE + 1) score -= 1;
    if (type2(foeMon) !== type1(foeMon)) {
      if (checkTypeMatchup(ctx, mon) >= EFFECTIVE + 1) score -= 1;
    }
  } else {
    let e = 0;
    let done = false;
    for (let i = 1; i <= NUM_MOVES; i += 1) {
      const rec = usedMove(foeMon, used[i - 1]);
      if (!rec) break;
      if (byte(rec.power) !== 0) {
        const m = checkTypeMatchup(ctx, mon);
        if (m >= EFFECTIVE + 1) {
          score -= 1;
          done = true;
          break;
        }
        if (m !== 0) {
          if (m >= EFFECTIVE) {
            e = 2;
          } else if (e < 1) {
            e = 1;
          }
        }
      }
    }
    if (!done && e !== 2) {
      score += 1;
      if (e === 0) score += 1;
    }
  }
  // `.CheckEnemyMoveMatchups`: 1 not very effective, 5 more neutral, 100.
  let c = 0;
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec) break;
    if (byte(rec.power) !== 0) {
      const m = checkTypeMatchup(ctx, foeMon);
      if (m !== 0) {
        c = mod(c + 1, 256);
        if (m >= EFFECTIVE) {
          c = mod(c + 5, 256);
          if (m !== EFFECTIVE) c = 100;
        }
      }
    }
  }
  if (c === 0) {
    score -= 2;
  } else if (c < 5) {
    score -= 1;
  } else if (c >= 100) {
    score += 1;
  }
  return mod(score, 256);
}

// A wPlayerUsedMoves entry as a move record: the player's own row for its id,
// else the entry when it is a record, else a zero row (the Lua twin explains).
function usedMove(mon, entry) {
  if (entry === null || entry === undefined || entry === false) return null;
  const key = Effects.moveKey(entry);
  if (key !== '') {
    for (const rec of (Array.isArray(mon.moves) ? mon.moves : [])) {
      if (isTable(rec) && Effects.moveKey(rec) === key) return rec;
    }
  }
  if (isTable(entry)) return entry;
  if (key === '') return null;
  return { id: key, power: 0, type: 0, effect: 0, accuracy: 255 };
}

// ------------------------------------------------------------------
// AIDamageCalc
// ------------------------------------------------------------------

function damageCalc(ctx, constant) {
  ctx.turn = 1;
  const { cur } = ctx;
  if (constant && CONSTANT_DAMAGE_EFFECTS.has(cur.effect)) {
    const fixed = Effects.fixedDamage({
      effectId: int(cur.rec.effect, 0), userMon: ctx.mon, targetMon: ctx.foeMon,
      power: cur.power, rng: ctx.counter,
    });
    return mod(int(fixed, 0), 65536);
  }
  const { battle, mon, foeMon } = ctx;
  const snapA = mon.statSnap;
  const snapB = foeMon.statSnap;
  const effectId = int(cur.rec.effect, 0);
  const stats = battle._damageStats(ctx.fighter, mon, ctx.foe, foeMon,
    cur.type, effectId, false);
  keepSnap(mon, snapA);
  keepSnap(foeMon, snapB);
  const name = typeName(ctx, cur.type);
  let d = Damage.calc(mon.level, cur.power, stats.attack, stats.defense, {
    itemBoostPercent: Items.typeBoostPercent(mon, name),
  });
  if (d === null || d === undefined) d = 0;
  d = Damage.stab(d, {
    weatherTenths: Effects.weatherTenths(battle._weatherKind(), name, effectId),
    badgeTypeBoost: false,
    stab: cur.type === type1(mon) || cur.type === type2(mon),
    typeEffect: battle._typePercents(cur.type, foeMon),
  }).damage;
  return mod(int(d, 0), 65536);
}

// ------------------------------------------------------------------
// AI_Redundant
// ------------------------------------------------------------------

function screens(ctx, fighter) {
  return (ctx.battle.screens && ctx.battle.screens[fighter.side]) || {};
}

function weather(ctx) { return ctx.battle._weatherKind(); }

const REDUNDANT = {};
REDUNDANT[E.EFFECT_DREAM_EATER] = (ctx) => sleepTurns(ctx.foeMon) === 0;
const redundantHeal = (ctx) => enemyMax(ctx);
REDUNDANT[E.EFFECT_HEAL] = redundantHeal;
REDUNDANT[E.EFFECT_MORNING_SUN] = redundantHeal;
REDUNDANT[E.EFFECT_SYNTHESIS] = redundantHeal;
REDUNDANT[E.EFFECT_MOONLIGHT] = redundantHeal;
REDUNDANT[E.EFFECT_LIGHT_SCREEN] = (ctx) => int(screens(ctx, ctx.fighter).lightScreen, 0) > 0;
REDUNDANT[E.EFFECT_MIST] = (ctx) => ctx.mon.mist === true;
REDUNDANT[E.EFFECT_FOCUS_ENERGY] = (ctx) => ctx.mon.focusEnergy === true;
REDUNDANT[E.EFFECT_CONFUSE] = (ctx) => {
  if (confused(ctx.foeMon)) return true;
  return int(screens(ctx, ctx.foe).safeguard, 0) > 0;
};
REDUNDANT[E.EFFECT_TRANSFORM] = (ctx) => ctx.mon.transformed === true;
REDUNDANT[E.EFFECT_REFLECT] = (ctx) => int(screens(ctx, ctx.fighter).reflect, 0) > 0;
REDUNDANT[E.EFFECT_SUBSTITUTE] = (ctx) => int(ctx.mon.substitute, 0) > 0;
REDUNDANT[E.EFFECT_LEECH_SEED] = (ctx) => ctx.foeMon.leechSeed !== null && ctx.foeMon.leechSeed !== undefined;
REDUNDANT[E.EFFECT_DISABLE] = (ctx) => {
  const d = ctx.foeMon.disable;
  return isTable(d) && int(d.turns, 0) > 0;
};
REDUNDANT[E.EFFECT_ENCORE] = (ctx) => ctx.foeMon.encore !== null && ctx.foeMon.encore !== undefined;
const redundantSnore = (ctx) => sleepTurns(ctx.mon) === 0;
REDUNDANT[E.EFFECT_SNORE] = redundantSnore;
REDUNDANT[E.EFFECT_SLEEP_TALK] = redundantSnore;
REDUNDANT[E.EFFECT_MEAN_LOOK] = (ctx) => ctx.mon.meanLook !== null && ctx.mon.meanLook !== undefined;
REDUNDANT[E.EFFECT_NIGHTMARE] = (ctx) => {
  if (statusByte(ctx.foeMon) === 0) return true;
  return ctx.foeMon.nightmare === true;
};
REDUNDANT[E.EFFECT_SPIKES] = (ctx) => screens(ctx, ctx.foe).spikes === true;
REDUNDANT[E.EFFECT_FORESIGHT] = (ctx) => ctx.foeMon.identified === true;
REDUNDANT[E.EFFECT_PERISH_SONG] = (ctx) => ctx.foeMon.perish !== null && ctx.foeMon.perish !== undefined;
REDUNDANT[E.EFFECT_SANDSTORM] = (ctx) => weather(ctx) === 'sandstorm';
REDUNDANT[E.EFFECT_ATTRACT] = (ctx) => {
  const mine = Effects.gender(ctx.foeMon);
  const theirs = Effects.gender(ctx.mon);
  if (!mine || !theirs || mine === theirs) return true;
  return ctx.foeMon.inLove !== null && ctx.foeMon.inLove !== undefined;
};
REDUNDANT[E.EFFECT_SAFEGUARD] = (ctx) => int(screens(ctx, ctx.fighter).safeguard, 0) > 0;
REDUNDANT[E.EFFECT_RAIN_DANCE] = (ctx) => weather(ctx) === 'rain';
REDUNDANT[E.EFFECT_SUNNY_DAY] = (ctx) => weather(ctx) === 'sun';
REDUNDANT[E.EFFECT_TELEPORT] = () => true;
REDUNDANT[E.EFFECT_SWAGGER] = (ctx) => confused(ctx.foeMon);
REDUNDANT[E.EFFECT_FUTURE_SIGHT] = () => false;

function present(value) {
  return value !== null && value !== undefined;
}

// ------------------------------------------------------------------
// the layers
// ------------------------------------------------------------------

function aiBasic(ctx) {
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec) return;
    const cur = load(ctx, rec);
    const redundant = REDUNDANT[cur.effect];
    if (redundant && redundant(ctx)) {
      dismiss(ctx, i);
    } else if (STATUS_ONLY_EFFECTS.has(cur.effect)) {
      if (statusByte(ctx.foeMon) !== 0 || int(screens(ctx, ctx.foe).safeguard, 0) > 0) {
        dismiss(ctx, i);
      }
    }
  }
}

function aiSetup(ctx) {
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec) return;
    const e = load(ctx, rec).effect;
    let kind = null;
    if (e >= E.EFFECT_ATTACK_UP && e <= E.EFFECT_EVASION_UP) {
      kind = 'up';
    } else if (e >= E.EFFECT_ATTACK_DOWN && e <= E.EFFECT_EVASION_DOWN) {
      kind = 'down';
    } else if (e >= E.EFFECT_ATTACK_UP_2 && e <= E.EFFECT_EVASION_UP_2) {
      kind = 'up';
    } else if (e >= E.EFFECT_ATTACK_DOWN_2 && e <= E.EFFECT_EVASION_DOWN_2) {
      kind = 'down';
    }
    if (kind) {
      const turns = (kind === 'up') ? turnsTaken(ctx.mon) : turnsTaken(ctx.foeMon);
      if (turns !== 0) {
        if (random(ctx) >= P12) add(ctx, i, 2);
      } else if (!ai5050(ctx)) {
        add(ctx, i, -2);
      }
    }
  }
}

function aiTypes(ctx) {
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec) return;
    const cur = load(ctx, rec);
    ctx.turn = 1;
    const m = battleCheckTypeMatchup(ctx);
    if (m === 0) {
      dismiss(ctx, i);
    } else if (m > EFFECTIVE) {
      if (cur.power !== 0) add(ctx, i, -1);
    } else if (m < EFFECTIVE) {
      const d = cur.type;
      let c = 0;
      for (let j = 1; j <= NUM_MOVES; j += 1) {
        const other = slot(ctx, j);
        if (!other) break;
        const o = load(ctx, other);
        if (o.type !== d && o.power !== 0) {
          c = o.power;
          break;
        }
      }
      if (c !== 0) add(ctx, i, 1);
    }
  }
}

function aiOffensive(ctx) {
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec) return;
    if (load(ctx, rec).power === 0) add(ctx, i, 2);
  }
}

function aiOpportunist(ctx) {
  if (enemyHalf(ctx)) return;
  if (enemyQuarter(ctx) && ai5050(ctx)) return;
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec) return;
    if (STALL_MOVES.has(Effects.moveKey(rec))) add(ctx, i, 1);
  }
}

function aiAggressive(ctx) {
  let best = 0;
  let bestSlot = 0;
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec) break;
    if (load(ctx, rec).power !== 0) {
      const dmg = damageCalc(ctx, true);
      if (dmg >= best) {
        best = dmg;
        bestSlot = i;
      }
    }
  }
  if (bestSlot === 0) return;
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (i !== bestSlot && rec) {
      const cur = load(ctx, rec);
      if (cur.power >= 2 && !RECKLESS_EFFECTS.has(cur.effect)) add(ctx, i, 1);
    }
  }
}

function aiCautious(ctx) {
  if (turnsTaken(ctx.mon) === 0) return;
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec) return;
    if (RESIDUAL_MOVES.has(Effects.moveKey(rec))) {
      if (random(ctx) >= P90P1) return;
      add(ctx, i, 1);
    }
  }
}

function aiStatus(ctx) {
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec) return;
    const cur = load(ctx, rec);
    const e = cur.effect;
    let check = false;
    if (e === E.EFFECT_TOXIC || e === E.EFFECT_POISON) {
      if (typeName(ctx, type1(ctx.foeMon)) === 'POISON'
          || typeName(ctx, type2(ctx.foeMon)) === 'POISON') {
        dismiss(ctx, i);
      } else {
        check = true;
      }
    } else if (e === E.EFFECT_SLEEP || e === E.EFFECT_PARALYZE) {
      check = true;
    } else if (cur.power !== 0) {
      check = true;
    }
    if (check) {
      ctx.turn = 1;
      if (battleCheckTypeMatchup(ctx) === 0) dismiss(ctx, i);
    }
  }
}

function aiRisky(ctx) {
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec) return;
    const cur = load(ctx, rec);
    if (cur.power !== 0) {
      let skip = false;
      if (RISKY_EFFECTS.has(cur.effect)) {
        if (enemyMax(ctx)) {
          skip = true;
        } else if (random(ctx) < P79M1) {
          skip = true;
        }
      }
      if (!skip) {
        const dmg = damageCalc(ctx, true);
        if (mod(int(ctx.foeMon.hp, 0), 65536) < dmg) add(ctx, i, -5);
      }
    }
  }
}

// ------------------------------------------------------------------
// AI_Smart's handlers
// ------------------------------------------------------------------

const SMART = {};

SMART[E.EFFECT_SLEEP] = (ctx, i) => {
  if (hasMoveEffect(ctx, E.EFFECT_DREAM_EATER) || hasMoveEffect(ctx, E.EFFECT_NIGHTMARE)) {
    if (!ai5050(ctx)) add(ctx, i, -2);
  }
};

SMART[E.EFFECT_LEECH_HIT] = (ctx, i) => {
  ctx.turn = 1;
  const m = battleCheckTypeMatchup(ctx);
  if (m < EFFECTIVE) {
    if (random(ctx) >= P39P1) add(ctx, i, 1);
    return;
  }
  if (m === EFFECTIVE) return;
  if (enemyMax(ctx)) return;
  if (!ai8020(ctx)) add(ctx, i, -1);
};

SMART[E.EFFECT_LOCK_ON] = (ctx, i) => {
  if (ctx.foeMon.lockOn === true) {
    for (let j = 1; j <= NUM_MOVES; j += 1) {
      const rec = slot(ctx, j);
      if (!rec) break;
      if (load(ctx, rec).acc < P71M1) add(ctx, j, -2);
    }
    dismiss(ctx, i);
    return;
  }
  if (!enemyQuarter(ctx)) { add(ctx, i, 1); return; }
  if (!enemyHalf(ctx) && !enemyFaster(ctx)) { add(ctx, i, 1); return; }
  let encourage = false;
  const pe = level(ctx.foeMon, 'eva');
  const ea = level(ctx.mon, 'acc');
  if (pe >= BASE_STAT_LEVEL + 3) {
    encourage = true;
  } else if (pe >= BASE_STAT_LEVEL + 1) {
    return;
  } else if (ea < BASE_STAT_LEVEL - 2) {
    encourage = true;
  } else if (ea < BASE_STAT_LEVEL) {
    return;
  } else {
    for (let j = 1; j <= NUM_MOVES; j += 1) {
      const rec = slot(ctx, j);
      if (!rec) break;
      if (load(ctx, rec).acc < P71M1) {
        ctx.turn = 1;
        if (battleCheckTypeMatchup(ctx) >= EFFECTIVE) return;
      }
    }
    add(ctx, i, 1);
    return;
  }
  if (encourage && !ai5050(ctx)) add(ctx, i, -2);
};

SMART[E.EFFECT_SELFDESTRUCT] = (ctx, i) => {
  if (ctx.family === 'crystal' && enemyLastMon(ctx) && playerHasOthers(ctx)) {
    add(ctx, i, 3);
    return;
  }
  if (enemyHalf(ctx)) { add(ctx, i, 3); return; }
  if (!enemyQuarter(ctx)) return;
  if (random(ctx) < P8) return;
  add(ctx, i, 3);
};

SMART[E.EFFECT_DREAM_EATER] = (ctx, i) => {
  if (random(ctx) < P10) return;
  add(ctx, i, -3);
};

function evasionShape(ctx, i, first, hpHalf, hpQuarter) {
  let greatly = false;
  let notEncouraged = false;
  if (first) {
    if (toxic(ctx.foeMon)) {
      greatly = true;
    } else if (random(ctx) >= P70) {
      notEncouraged = true;
    } else {
      greatly = true;
    }
  } else {
    let mismatch2 = false;
    if (!hpQuarter(ctx)) {
      mismatch2 = true;
    } else if (random(ctx) < P4) {
      greatly = true;
    } else if (!hpHalf(ctx)) {
      if (ai5050(ctx)) notEncouraged = true; else mismatch2 = true;
    } else if (ai8020(ctx)) {
      greatly = true;
    } else {
      notEncouraged = true;
    }
    if (mismatch2) {
      add(ctx, i, 2);
      notEncouraged = true;
    }
  }
  if (greatly) { add(ctx, i, -2); return; }
  if (!notEncouraged) return;
  if (toxic(ctx.foeMon)) {
    if (random(ctx) < P31P1) return;
    add(ctx, i, -2);
    return;
  }
  if (present(ctx.foeMon.leechSeed)) {
    if (!ai5050(ctx)) add(ctx, i, -1);
    return;
  }
  if (level(ctx.foeMon, 'acc') < level(ctx.mon, 'eva')) { add(ctx, i, 1); return; }
  if (byte(ctx.foeMon.furyCutter) !== 0 || rolling(ctx.foeMon)) { add(ctx, i, -2); return; }
  add(ctx, i, 1);
}

SMART[E.EFFECT_EVASION_UP] = (ctx, i) => {
  if (level(ctx.mon, 'eva') >= MAX_STAT_LEVEL) { dismiss(ctx, i); return; }
  evasionShape(ctx, i, enemyMax(ctx), enemyHalf, enemyQuarter);
};

SMART[E.EFFECT_ALWAYS_HIT] = (ctx, i) => {
  if (level(ctx.mon, 'acc') >= BASE_STAT_LEVEL - 2
      && level(ctx.foeMon, 'eva') < BASE_STAT_LEVEL + 3) {
    return;
  }
  if (!ai8020(ctx)) add(ctx, i, -2);
};

SMART[E.EFFECT_MIRROR_MOVE] = (ctx, i) => {
  const last = ctx.foeMon.lastCounterMove;
  if (blank(last)) {
    if (!enemyFaster(ctx)) return;
    dismiss(ctx, i);
    return;
  }
  if (!USEFUL_MOVES.has(Effects.moveKey(last))) return;
  if (ai5050(ctx)) return;
  add(ctx, i, -1);
  if (!enemyFaster(ctx)) return;
  if (random(ctx) < P10) return;
  add(ctx, i, -1);
};

SMART[E.EFFECT_ACCURACY_DOWN] = (ctx, i) => {
  evasionShape(ctx, i, playerMax(ctx) && enemyHalf(ctx), playerHalf, playerQuarter);
};

const STAT_LEVEL_KEYS = ['atk', 'def', 'spe', 'spa', 'spd', 'acc', 'eva'];
SMART[E.EFFECT_RESET_STATS] = (ctx, i) => {
  let encourage = false;
  for (const key of STAT_LEVEL_KEYS) {
    if (level(ctx.mon, key) < BASE_STAT_LEVEL - 2) { encourage = true; break; }
  }
  if (!encourage) {
    for (const key of STAT_LEVEL_KEYS) {
      if (level(ctx.foeMon, key) >= BASE_STAT_LEVEL + 3) { encourage = true; break; }
    }
  }
  if (!encourage) { add(ctx, i, 1); return; }
  if (random(ctx) < P16) return;
  add(ctx, i, -1);
};

SMART[E.EFFECT_BIDE] = (ctx, i) => {
  if (enemyMax(ctx)) return;
  if (random(ctx) < P10) return;
  add(ctx, i, 1);
};

function switchScoreDiscourage(ctx, i) {
  if (checkPlayerMoveTypeMatchups(ctx) < BASE_AI_SWITCH_SCORE) return;
  add(ctx, i, 1);
}
SMART[E.EFFECT_FORCE_SWITCH] = switchScoreDiscourage;
SMART[E.EFFECT_BATON_PASS] = switchScoreDiscourage;

function smartHeal(ctx, i) {
  if (!enemyQuarter(ctx)) {
    if (random(ctx) < P10) return;
    add(ctx, i, -2);
    return;
  }
  if (!enemyHalf(ctx)) return;
  add(ctx, i, 1);
}
SMART[E.EFFECT_HEAL] = smartHeal;
SMART[E.EFFECT_MORNING_SUN] = smartHeal;
SMART[E.EFFECT_SYNTHESIS] = smartHeal;
SMART[E.EFFECT_MOONLIGHT] = smartHeal;

function smartToxic(ctx, i) {
  if (playerHalf(ctx)) return;
  add(ctx, i, 1);
}
SMART[E.EFFECT_TOXIC] = smartToxic;
SMART[E.EFFECT_LEECH_SEED] = smartToxic;

function smartScreen(ctx, i) {
  if (enemyMax(ctx)) return;
  if (random(ctx) < P8) return;
  add(ctx, i, 1);
}
SMART[E.EFFECT_LIGHT_SCREEN] = smartScreen;
SMART[E.EFFECT_REFLECT] = smartScreen;

SMART[E.EFFECT_OHKO] = (ctx, i) => {
  if (byte(ctx.mon.level) < byte(ctx.foeMon.level)) { dismiss(ctx, i); return; }
  if (playerHalf(ctx)) return;
  add(ctx, i, 1);
};

function playerHeld(ctx) {
  const m = ctx.foeMon;
  return present(m.inLove) || rolling(m) || m.identified === true || m.nightmare === true;
}

SMART[E.EFFECT_TRAP_TARGET] = (ctx, i) => {
  const { trapped } = ctx.foeMon;
  let encourage = false;
  if (!(isTable(trapped) && mod(int(trapped.turns, 0), 256) !== 0)) {
    encourage = toxic(ctx.foeMon) || playerHeld(ctx) || turnsTaken(ctx.foeMon) === 0;
  }
  if (!encourage) {
    if (!ai5050(ctx)) add(ctx, i, 1);
    return;
  }
  if (!enemyQuarter(ctx)) return;
  if (ai5050(ctx)) return;
  add(ctx, i, -2);
};

function smartRazorWind(ctx, i) {
  if (present(ctx.mon.perish) && byte(ctx.mon.perish) < 3) { add(ctx, i, 1); return; }
  const used = Array.isArray(ctx.foeMon.usedMoves) ? ctx.foeMon.usedMoves : [];
  for (let k = 1; k <= NUM_MOVES; k += 1) {
    const rec = usedMove(ctx.foeMon, used[k - 1]);
    if (!rec) break;
    if (load(ctx, rec).effect === E.EFFECT_PROTECT) { add(ctx, i, 6); return; }
  }
  if (!confused(ctx.mon) && enemyHalf(ctx)) return;
  if (random(ctx) < P79M1) return;
  add(ctx, i, 1);
}
SMART[E.EFFECT_RAZOR_WIND] = smartRazorWind;
SMART[E.EFFECT_UNUSED_2B] = smartRazorWind;

SMART[E.EFFECT_CONFUSE] = (ctx, i) => {
  if (playerHalf(ctx)) return;
  if (random(ctx) >= P10) add(ctx, i, 1);
  if (playerQuarter(ctx)) return;
  add(ctx, i, 1);
};

SMART[E.EFFECT_SP_DEF_UP_2] = (ctx, i) => {
  if (!enemyHalf(ctx)) { add(ctx, i, 1); return; }
  const sd = level(ctx.mon, 'spd');
  if (sd >= BASE_STAT_LEVEL + 4) { add(ctx, i, 1); return; }
  if (sd >= BASE_STAT_LEVEL + 2) return;
  if (!special(ctx, type1(ctx.foeMon)) && !special(ctx, type2(ctx.foeMon))) return;
  if (ai8020(ctx)) return;
  add(ctx, i, -2);
};

// [vanished, into].
function vanished(ctx, mon) {
  const into = ctx.battle._vanishedInto(mon);
  return [into === 'FLY' || into === 'DIG', into];
}

SMART[E.EFFECT_FLY] = (ctx, i) => {
  if (!vanished(ctx, ctx.foeMon)[0]) return;
  if (!enemyFaster(ctx)) return;
  add(ctx, i, -3);
};

SMART[E.EFFECT_SUPER_FANG] = (ctx, i) => {
  if (playerQuarter(ctx)) return;
  add(ctx, i, 1);
};

SMART[E.EFFECT_PARALYZE] = (ctx, i) => {
  if (!playerQuarter(ctx)) {
    if (!ai5050(ctx)) add(ctx, i, 1);
    return;
  }
  if (enemyFaster(ctx)) return;
  if (!enemyQuarter(ctx)) return;
  if (ai8020(ctx)) return;
  add(ctx, i, -2);
};

SMART[E.EFFECT_SPEED_DOWN_HIT] = (ctx, i) => {
  if (ctx.cur.id !== 'ICY_WIND') return;
  if (!enemyQuarter(ctx)) return;
  if (turnsTaken(ctx.foeMon) !== 0) return;
  if (enemyFaster(ctx)) return;
  if (random(ctx) < P12) return;
  add(ctx, i, -2);
};

SMART[E.EFFECT_SUBSTITUTE] = (ctx, i) => {
  if (enemyHalf(ctx)) return;
  dismiss(ctx, i);
};

SMART[E.EFFECT_HYPER_BEAM] = (ctx, i) => {
  if (enemyHalf(ctx)) {
    const threshold = (ctx.family === 'crystal') ? P16 : P35P1;
    if (random(ctx) < threshold) return;
    add(ctx, i, 1);
    if (ai5050(ctx)) return;
    add(ctx, i, 1);
    return;
  }
  if (enemyQuarter(ctx)) return;
  if (ai5050(ctx)) return;
  add(ctx, i, -1);
};

SMART[E.EFFECT_RAGE] = (ctx, i) => {
  if (ctx.mon.raging === true) {
    if (!ai5050(ctx)) add(ctx, i, -1);
    const counter = byte(ctx.mon.rageCounter);
    if (counter < 2) return;
    add(ctx, i, -1);
    if (counter < 3) return;
    add(ctx, i, -1);
    return;
  }
  if (!enemyHalf(ctx)) { add(ctx, i, 1); return; }
  if (!ai8020(ctx)) return;
  add(ctx, i, -1);
};

SMART[E.EFFECT_MIMIC] = (ctx, i) => {
  const last = ctx.foeMon.lastCounterMove;
  if (blank(last)) {
    if (enemyFaster(ctx)) dismiss(ctx, i); else add(ctx, i, 1);
    return;
  }
  if (!enemyHalf(ctx)) { add(ctx, i, 1); return; }
  load(ctx, last);
  ctx.turn = 1;
  const m = battleCheckTypeMatchup(ctx);
  if (m < EFFECTIVE) { add(ctx, i, 1); return; }
  if (m !== EFFECTIVE && !ai5050(ctx)) add(ctx, i, -1);
  if (!USEFUL_MOVES.has(Effects.moveKey(last))) return;
  if (ai5050(ctx)) return;
  add(ctx, i, -1);
};

function counterShape(ctx, i, wantSpecial) {
  const used = Array.isArray(ctx.foeMon.usedMoves) ? ctx.foeMon.usedMoves : [];
  let b = 0;
  for (let k = 1; k <= NUM_MOVES; k += 1) {
    const rec = usedMove(ctx.foeMon, used[k - 1]);
    if (rec) {
      const cur = load(ctx, rec);
      if (cur.power !== 0 && special(ctx, cur.type) === wantSpecial) b += 1;
    }
  }
  if (b === 0) { add(ctx, i, 1); return; }
  if (b < 3) {
    const last = ctx.foeMon.lastCounterMove;
    if (blank(last)) return;
    const cur = load(ctx, last);
    if (cur.power === 0) return;
    if (special(ctx, cur.type) !== wantSpecial) return;
  }
  if (random(ctx) < P39P1) return;
  add(ctx, i, -1);
}
SMART[E.EFFECT_COUNTER] = (ctx, i) => counterShape(ctx, i, false);
SMART[E.EFFECT_MIRROR_COAT] = (ctx, i) => counterShape(ctx, i, true);

SMART[E.EFFECT_ENCORE] = (ctx, i) => {
  if (!enemyFaster(ctx)) { add(ctx, i, 3); return; }
  const last = ctx.foeMon.lastMove;
  if (blank(last)) { dismiss(ctx, i); return; }
  const cur = load(ctx, last);
  let weak = true;
  if (cur.power !== 0) {
    const m = checkTypeMatchup(ctx, ctx.mon);
    if (m < EFFECTIVE) {
      if (m !== 0) return;
      weak = false;
    }
  }
  if (weak) {
    const counter = ctx.foeMon.lastCounterMove;
    if (!(!blank(counter) && ENCORE_MOVES.has(Effects.moveKey(counter)))) {
      add(ctx, i, 3);
      return;
    }
  }
  if (random(ctx) < P28M1) return;
  add(ctx, i, -2);
};

SMART[E.EFFECT_PAIN_SPLIT] = (ctx, i) => {
  const double = mod(int(ctx.mon.hp, 0) * 2, 65536);
  if (mod(int(ctx.foeMon.hp, 0), 65536) >= double) return;
  add(ctx, i, 1);
};

function smartSnore(ctx, i) {
  if (sleepTurns(ctx.mon) === 1) add(ctx, i, 3); else add(ctx, i, -3);
}
SMART[E.EFFECT_SNORE] = smartSnore;
SMART[E.EFFECT_SLEEP_TALK] = smartSnore;

SMART[E.EFFECT_DEFROST_OPPONENT] = (ctx, i) => {
  if (band(statusByte(ctx.mon), FRZ_BIT) === 0) return;
  add(ctx, i, -3);
};

SMART[E.EFFECT_CONVERSION2] = (ctx, i) => {
  let m;
  if (!blank(ctx.foeMon.lastMove)) {
    m = null;
  } else {
    ctx.playerMoveType = null;
    ctx.turn = 0;
    m = battleCheckTypeMatchup(ctx);
    if (m === EFFECTIVE) return;
  }
  if (m === null || m < EFFECTIVE) {
    if (random(ctx) < P10) return;
    add(ctx, i, 1);
    return;
  }
  if (ai5050(ctx)) return;
  add(ctx, i, -1);
};

function smartLowHpOnly(ctx, i) {
  if (!enemyQuarter(ctx)) return;
  add(ctx, i, 1);
}
SMART[E.EFFECT_DESTINY_BOND] = smartLowHpOnly;
SMART[E.EFFECT_REVERSAL] = smartLowHpOnly;
SMART[E.EFFECT_SKULL_BASH] = smartLowHpOnly;

SMART[E.EFFECT_SPITE] = (ctx, i) => {
  const last = ctx.foeMon.lastCounterMove;
  if (blank(last)) {
    if (enemyFaster(ctx)) { dismiss(ctx, i); return; }
    if (ai5050(ctx)) return;
    add(ctx, i, 1);
    return;
  }
  const key = Effects.moveKey(last);
  let found = null;
  for (let k = 1; k <= NUM_MOVES; k += 1) {
    const rec = Array.isArray(ctx.foeMon.moves) ? ctx.foeMon.moves[k - 1] : null;
    if (isTable(rec) && Effects.moveKey(rec) === key) { found = rec; break; }
  }
  if (!found) return;
  const pp = Math.min(63, Math.max(0, int(found.pp, 0))) + 64 * mod(int(found.ppUps, 0), 4);
  if (pp < 6) {
    if (random(ctx) < P39P1) return;
    add(ctx, i, -2);
    return;
  }
  if (pp < 15 && random(ctx) >= P39P1) return;
  add(ctx, i, 1);
};

SMART[E.EFFECT_HEAL_BELL] = (ctx, i) => {
  let any = false;
  for (const m of ctx.fighter.mons) {
    if (int(m.hp, 0) !== 0 && statusByte(m) !== 0) any = true;
  }
  const own = statusByte(ctx.mon);
  if (!any) {
    if (own !== 0) return;
    dismiss(ctx, i);
    return;
  }
  if (own !== 0) add(ctx, i, -1);
  if (band(own, FRZ_BIT + SLP_MASK) === 0) return;
  if (ai5050(ctx)) return;
  add(ctx, i, -2);
};

SMART[E.EFFECT_PRIORITY_HIT] = (ctx, i) => {
  if (enemyFaster(ctx)) return;
  if (vanished(ctx, ctx.foeMon)[0]) { dismiss(ctx, i); return; }
  const dmg = damageCalc(ctx, false);
  if (mod(int(ctx.foeMon.hp, 0), 65536) >= dmg) return;
  add(ctx, i, -3);
};

SMART[E.EFFECT_THIEF] = (ctx, i) => add(ctx, i, 30);

SMART[E.EFFECT_MEAN_LOOK] = (ctx, i) => {
  if (!enemyHalf(ctx)) { add(ctx, i, 1); return; }
  if (!playerHasOthers(ctx)) { dismiss(ctx, i); return; }
  if (!(toxic(ctx.mon) || playerHeld(ctx))) {
    if (checkPlayerMoveTypeMatchups(ctx) >= BASE_AI_SWITCH_SCORE + 1) return;
    add(ctx, i, 1);
    return;
  }
  if (ai8020(ctx)) return;
  add(ctx, i, -3);
};

SMART[E.EFFECT_NIGHTMARE] = (ctx, i) => {
  if (ai5050(ctx)) return;
  add(ctx, i, -1);
};

SMART[E.EFFECT_FLAME_WHEEL] = (ctx, i) => {
  if (band(statusByte(ctx.mon), FRZ_BIT) === 0) return;
  add(ctx, i, -5);
};

SMART[E.EFFECT_CURSE] = (ctx, i) => {
  const { mon, foeMon } = ctx;
  if (typeName(ctx, type1(mon)) !== 'GHOST' && typeName(ctx, type2(mon)) !== 'GHOST') {
    if (!enemyHalf(ctx)) { add(ctx, i, 1); return; }
    const atk = level(mon, 'atk');
    if (atk >= BASE_STAT_LEVEL + 4) { add(ctx, i, 1); return; }
    if (atk >= BASE_STAT_LEVEL + 2) return;
    if (typeName(ctx, type1(foeMon)) === 'GHOST') { add(ctx, i, 2); return; }
    if (special(ctx, type1(foeMon))) return;
    if (special(ctx, type2(foeMon))) return;
    if (ai8020(ctx)) return;
    add(ctx, i, -2);
    return;
  }
  if (ctx.family !== 'crystal') {
    if (!enemyQuarter(ctx)) { dismiss(ctx, i); return; }
    if (!enemyHalf(ctx)) { add(ctx, i, 1); return; }
    if (foeMon.cursed === true) { dismiss(ctx, i); return; }
    if (turnsTaken(foeMon) !== 0) return;
    if (ai5050(ctx)) return;
    add(ctx, i, -2);
    return;
  }
  if (foeMon.cursed === true) { dismiss(ctx, i); return; }
  let encourage = false;
  if (enemyLastMon(ctx)) {
    if (playerHasOthers(ctx)) { add(ctx, i, 4); return; }
  } else if (!playerHasOthers(ctx)) {
    encourage = true;
  }
  if (!encourage) {
    if (!enemyQuarter(ctx)) { add(ctx, i, 4); return; }
    if (!enemyHalf(ctx)) { add(ctx, i, 2); return; }
    if (!enemyMax(ctx)) return;
    if (turnsTaken(foeMon) !== 0) return;
  }
  if (ai5050(ctx)) return;
  add(ctx, i, -2);
};

SMART[E.EFFECT_PROTECT] = (ctx, i) => {
  const { foeMon } = ctx;
  let discourage = false;
  let extra = 0;
  if (byte(ctx.mon.protectCount) !== 0) {
    discourage = true;
    extra = 1;
  } else if (foeMon.lockOn === true) {
    discourage = true;
  } else if (byte(foeMon.furyCutter) >= 3 || present(foeMon.charging) || toxic(foeMon)
             || present(foeMon.leechSeed) || foeMon.cursed === true) {
    discourage = false;
  } else if (!rolling(foeMon) || byte(foeMon.rollout && foeMon.rollout.count) < 3) {
    discourage = true;
  }
  if (discourage) {
    add(ctx, i, extra);
    if (random(ctx) < P8) return;
    add(ctx, i, 2);
    return;
  }
  if (ai8020(ctx)) return;
  add(ctx, i, -1);
};

SMART[E.EFFECT_FORESIGHT] = (ctx, i) => {
  const { foeMon } = ctx;
  if (level(ctx.mon, 'acc') < BASE_STAT_LEVEL - 2
      || level(foeMon, 'eva') >= BASE_STAT_LEVEL + 3
      || typeName(ctx, type1(foeMon)) === 'GHOST' || typeName(ctx, type2(foeMon)) === 'GHOST') {
    if (random(ctx) < P39P1) return;
    add(ctx, i, -2);
    return;
  }
  if (random(ctx) < P8) return;
  add(ctx, i, 1);
};

SMART[E.EFFECT_PERISH_SONG] = (ctx, i) => {
  if (enemyLastMon(ctx)) { add(ctx, i, 5); return; }
  if (present(ctx.foeMon.meanLook)) {
    if (ai5050(ctx)) return;
    add(ctx, i, -1);
    return;
  }
  if (checkPlayerMoveTypeMatchups(ctx) < BASE_AI_SWITCH_SCORE) return;
  if (ai5050(ctx)) return;
  add(ctx, i, 1);
};

const SANDSTORM_IMMUNE = new Set(['ROCK', 'GROUND', 'STEEL']);
SMART[E.EFFECT_SANDSTORM] = (ctx, i) => {
  if (SANDSTORM_IMMUNE.has(typeName(ctx, type1(ctx.foeMon)) || '')
      || SANDSTORM_IMMUNE.has(typeName(ctx, type2(ctx.foeMon)) || '')) {
    add(ctx, i, 2);
    return;
  }
  if (!playerHalf(ctx)) { add(ctx, i, 1); return; }
  if (ai5050(ctx)) return;
  add(ctx, i, -1);
};

SMART[E.EFFECT_ENDURE] = (ctx, i) => {
  if (byte(ctx.mon.protectCount) !== 0) { add(ctx, i, 2); return; }
  if (enemyMax(ctx)) { add(ctx, i, 2); return; }
  if (enemyQuarter(ctx)) { add(ctx, i, 1); return; }
  if (hasMoveEffect(ctx, E.EFFECT_REVERSAL)) {
    if (ai8020(ctx)) return;
    add(ctx, i, -3);
    return;
  }
  if (ctx.mon.lockOn !== true) return;
  if (ai5050(ctx)) return;
  add(ctx, i, -2);
};

function smartRollout(ctx, i) {
  const { mon } = ctx;
  const maybe = present(mon.inLove) || confused(mon) || band(statusByte(mon), PAR_BIT) !== 0
    || !enemyQuarter(ctx)
    || level(mon, 'acc') < BASE_STAT_LEVEL
    || level(ctx.foeMon, 'eva') >= BASE_STAT_LEVEL + 1;
  if (maybe) {
    if (ai8020(ctx)) return;
    add(ctx, i, 1);
    return;
  }
  if (random(ctx) >= P79M1) return;
  add(ctx, i, -2);
}
SMART[E.EFFECT_ROLLOUT] = smartRollout;

SMART[E.EFFECT_FURY_CUTTER] = (ctx, i) => {
  const count = byte(ctx.mon.furyCutter);
  if (count !== 0) {
    add(ctx, i, -1);
    if (count >= 2) {
      add(ctx, i, -2);
      if (count >= 3) add(ctx, i, -3);
    }
  }
  smartRollout(ctx, i);
};

function smartSwagger(ctx, i) {
  if (turnsTaken(ctx.foeMon) === 0) {
    if (random(ctx) >= P79M1) return;
    add(ctx, i, -1);
    return;
  }
  if (ai8020(ctx)) return;
  add(ctx, i, 1);
}
SMART[E.EFFECT_SWAGGER] = smartSwagger;
SMART[E.EFFECT_ATTRACT] = smartSwagger;

SMART[E.EFFECT_SAFEGUARD] = (ctx, i) => {
  if (playerHalf(ctx)) return;
  if (ai8020(ctx)) return;
  add(ctx, i, 1);
};

function smartAgainst(ctx, i, moveId) {
  const last = ctx.foeMon.lastCounterMove;
  if (blank(last) || Effects.moveKey(last) !== moveId) return;
  const into = vanished(ctx, ctx.foeMon)[1];
  if (into === moveId) {
    if (!enemyFaster(ctx)) return;
    add(ctx, i, -2);
    return;
  }
  if (enemyFaster(ctx)) return;
  if (ai5050(ctx)) return;
  add(ctx, i, -1);
}
SMART[E.EFFECT_MAGNITUDE] = (ctx, i) => smartAgainst(ctx, i, 'DIG');
SMART[E.EFFECT_EARTHQUAKE] = (ctx, i) => smartAgainst(ctx, i, 'DIG');
SMART[E.EFFECT_TWISTER] = (ctx, i) => smartAgainst(ctx, i, 'FLY');
SMART[E.EFFECT_GUST] = (ctx, i) => smartAgainst(ctx, i, 'FLY');

SMART[E.EFFECT_PURSUIT] = (ctx, i) => {
  if (!playerQuarter(ctx)) {
    if (ai5050(ctx)) return;
    add(ctx, i, -2);
    return;
  }
  if (ai8020(ctx)) return;
  add(ctx, i, 1);
};

SMART[E.EFFECT_RAPID_SPIN] = (ctx, i) => {
  const { trapped } = ctx.mon;
  if (!((isTable(trapped) && mod(int(trapped.turns, 0), 256) !== 0) || present(ctx.mon.leechSeed)
        || screens(ctx, ctx.fighter).spikes === true)) {
    return;
  }
  if (ai8020(ctx)) return;
  add(ctx, i, -2);
};

SMART[E.EFFECT_HIDDEN_POWER] = (ctx, i) => {
  ctx.turn = 1;
  const hp = Effects.hiddenPower(ctx.mon.dvs);
  const power = hp ? hp.power : null;
  const hpType = hp ? hp.type : null;
  const d = (power !== null && power !== undefined) ? power : ctx.cur.power;
  const index = hpType ? typeIndexOf(ctx.battle.typeIds, hpType) : null;
  if (index !== null) ctx.cur.type = index;
  const m = battleCheckTypeMatchup(ctx);
  if (m < EFFECTIVE || d < 50) { add(ctx, i, 1); return; }
  if (m < EFFECTIVE + 1 && d < 70) return;
  add(ctx, i, -1);
};

function goodWeather(ctx, i) {
  if (!playerHalf(ctx)) return;
  if (turnsTaken(ctx.foeMon) !== 0 && turnsTaken(ctx.mon) !== 0) return;
  add(ctx, i, -2);
}

function weatherMove(ctx, i, bad, good, list) {
  for (const t of [type1(ctx.foeMon), type2(ctx.foeMon)]) {
    const name = typeName(ctx, t);
    if (name === bad) { add(ctx, i, 3); return; }
    if (name === good) { goodWeather(ctx, i); return; }
  }
  if (!hasMoveInArray(ctx, list)) { add(ctx, i, 3); return; }
  if (!playerHalf(ctx)) { add(ctx, i, 3); return; }
  if (ai5050(ctx)) return;
  add(ctx, i, -1);
}
SMART[E.EFFECT_RAIN_DANCE] = (ctx, i) => {
  weatherMove(ctx, i, 'WATER', 'FIRE', RAIN_DANCE_MOVES);
};
SMART[E.EFFECT_SUNNY_DAY] = (ctx, i) => {
  weatherMove(ctx, i, 'FIRE', 'WATER', SUNNY_DAY_MOVES);
};

SMART[E.EFFECT_BELLY_DRUM] = (ctx, i) => {
  if (level(ctx.mon, 'atk') >= BASE_STAT_LEVEL + 3) { add(ctx, i, 5); return; }
  if (enemyMax(ctx)) return;
  add(ctx, i, 1);
  if (enemyHalf(ctx)) return;
  add(ctx, i, 5);
};

SMART[E.EFFECT_PSYCH_UP] = (ctx, i) => {
  let c = 100;
  let d = 100;
  for (const key of STAT_LEVEL_KEYS) {
    c = mod(c + level(ctx.mon, key) - BASE_STAT_LEVEL, 256);
    d = mod(d + level(ctx.foeMon, key) - BASE_STAT_LEVEL, 256);
  }
  const crystal = ctx.family === 'crystal';
  if (c >= d) { add(ctx, i, crystal ? 2 : 1); return; }
  if (level(ctx.foeMon, 'acc') < BASE_STAT_LEVEL - 1) return;
  if (crystal) {
    if (level(ctx.mon, 'eva') >= BASE_STAT_LEVEL + 1) return;
  } else {
    if (level(ctx.foeMon, 'eva') < BASE_STAT_LEVEL + 2) return;
    if (level(ctx.foeMon, 'eva') >= BASE_STAT_LEVEL + 1) return;
  }
  if (ai8020(ctx)) return;
  add(ctx, i, -1);
};

SMART[E.EFFECT_FUTURE_SIGHT] = (ctx, i) => {
  if (!enemyFaster(ctx)) return;
  if (!vanished(ctx, ctx.foeMon)[0]) return;
  add(ctx, i, -2);
};

SMART[E.EFFECT_STOMP] = (ctx, i) => {
  if (ctx.foeMon.minimized !== true) return;
  if (ai8020(ctx)) return;
  add(ctx, i, -1);
};

SMART[E.EFFECT_SOLARBEAM] = (ctx, i) => {
  const w = weather(ctx);
  if (w === 'sun') {
    if (ai8020(ctx)) return;
    add(ctx, i, -2);
    return;
  }
  if (w !== 'rain') return;
  if (random(ctx) < P10) return;
  add(ctx, i, 2);
};

SMART[E.EFFECT_THUNDER] = (ctx, i) => {
  if (weather(ctx) !== 'sun') return;
  if (random(ctx) < P10) return;
  add(ctx, i, 1);
};

SMART[E.EFFECT_DISABLE] = (ctx, i) => {
  if (enemyFaster(ctx)) {
    const last = ctx.foeMon.lastCounterMove;
    if (!blank(last) && USEFUL_MOVES.has(Effects.moveKey(last))) {
      if (random(ctx) < P39P1) return;
      add(ctx, i, -1);
      return;
    }
    if (ctx.cur.power !== 0) return;
  }
  if (random(ctx) < P8) return;
  add(ctx, i, 1);
};

function aiSmart(ctx) {
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec) return;
    const handler = SMART[load(ctx, rec).effect];
    if (handler) handler(ctx, i);
  }
}

const LAYER_FUNCS = [
  aiBasic, aiSetup, aiTypes, aiOffensive, aiSmart,
  aiOpportunist, aiAggressive, aiCautious, aiStatus, aiRisky,
];

// ------------------------------------------------------------------
// the state fields the referee does not keep
// ------------------------------------------------------------------

function turnsTaken(mon) {
  return byte(mon && mon.turnsTaken);
}

// CheckEnemyLockedIn.
function enemyLockedIn(mon) {
  if (!isTable(mon)) return false;
  if (mon.mustRecharge === true) return true;
  if (present(mon.charging)) return true;
  if (isTable(mon.thrashing) && int(mon.thrashing.turns, 0) > 0) return true;
  if (present(mon.bide)) return true;
  return rolling(mon);
}

function disabledKey(mon) {
  const d = mon.disable;
  if (!isTable(d) || int(d.turns, 0) <= 0) return null;
  const rec = Array.isArray(mon.moves) ? mon.moves[int(d.moveIndex, 0) - 1] : null;
  if (!isTable(rec)) return null;
  return Effects.moveKey(rec);
}

// ParseEnemyAction's `.continue`.
function usableMove(mon) {
  if (!isTable(mon)) return null;
  const disabled = disabledKey(mon);
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = Array.isArray(mon.moves) ? mon.moves[i - 1] : null;
    if (!isTable(rec)) return null;
    if (Effects.moveKey(rec) !== disabled && int(rec.pp, 0) > 0) return i;
  }
  return null;
}

// ------------------------------------------------------------------
// AIChooseMove
// ------------------------------------------------------------------

function familyOf(battle, opts) {
  if (opts.family === 'crystal' || opts.family === 'gs') return opts.family;
  if (battle.family === 'crystal') return 'crystal';
  return 'gs';
}

// AIChooseMove, scored and picked: { slot, reason, scores, layerDraws, draws }
// (the Lua twin documents each).
function evaluate(battle, fighter, foe, opts) {
  const o = isTable(opts) ? opts : {};
  const out = { slot: null, reason: null, scores: null, layerDraws: 0, draws: 0 };
  let { wild } = o;
  if (wild === null || wild === undefined) wild = Effects.isWildMode(battle.mode);
  if (wild) { out.reason = 'wild'; return out; }
  let { link } = o;
  if (link === null || link === undefined) link = LINK_MODES[battle.mode] === true;
  if (link) { out.reason = 'link'; return out; }
  const mon = (fighter && fighter.active && fighter.mons[fighter.active - 1]) || null;
  const foeMon = (foe && foe.active && foe.mons[foe.active - 1]) || null;
  if (!mon || !foeMon) { out.reason = 'nomon'; return out; }
  if (enemyLockedIn(mon)) { out.reason = 'locked'; return out; }

  const ctx = {
    battle, fighter, foe, mon, foeMon,
    family: familyOf(battle, o),
    scores: [BASE_SCORE, BASE_SCORE, BASE_SCORE, BASE_SCORE],
    turn: 1, cur: null, playerMoveType: null, draws: 0,
  };
  ctx.counter = { byte: () => random(ctx) };

  const disabled = disabledKey(mon);
  if (disabled !== null) {
    for (let i = 1; i <= NUM_MOVES; i += 1) {
      const rec = slot(ctx, i);
      if (rec && Effects.moveKey(rec) === disabled) {
        ctx.scores[i - 1] = UNUSABLE_SCORE;
        break;
      }
    }
  }
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    if (!rec || int(rec.pp, 0) <= 0) ctx.scores[i - 1] = UNUSABLE_SCORE;
  }

  let flags = int(o.aiFlags, null);
  if (flags === null) flags = int(fighter.aiFlags, 0);
  flags = mod(Math.max(0, flags), 65536);
  for (let bit = 0; bit < LAYER_SLOTS; bit += 1) {
    if (Math.floor(flags / 2 ** bit) % 2 === 1) {
      const layer = LAYER_FUNCS[bit];
      if (layer) layer(ctx);
    }
  }
  out.scores = ctx.scores.slice();
  out.layerDraws = ctx.draws;

  const sc = ctx.scores;
  if (!slot(ctx, 1)) {
    out.reason = 'nomoves';
    out.draws = ctx.draws;
    return out;
  }
  let hit = null;
  for (let round = 1; round <= 257; round += 1) {
    for (let i = 1; i <= NUM_MOVES; i += 1) {
      if (!slot(ctx, i)) break;
      sc[i - 1] = mod(sc[i - 1] - 1, 256);
      if (sc[i - 1] === 0) { hit = i; break; }
    }
    if (hit !== null) break;
  }
  for (let i = hit; i >= 1; i -= 1) sc[i - 1] = mod(sc[i - 1] + 1, 256);
  const keep = [];
  for (let i = 1; i <= NUM_MOVES; i += 1) {
    const rec = slot(ctx, i);
    keep[i - 1] = rec !== null && sc[i - 1] === 1;
  }
  let chosen = hit;
  for (let n = 0; n < REDRAW_LIMIT; n += 1) {
    const c = random(ctx) % 4;
    if (keep[c]) { chosen = c + 1; break; }
  }
  out.slot = chosen;
  out.draws = ctx.draws;
  return out;
}

function choose(battle, fighter, foe, opts) {
  return evaluate(battle, fighter, foe, opts).slot;
}

// ParseEnemyAction's wild `.loop2` (the Lua twin explains).
function wildPick(battle, fighter) {
  const mon = (fighter && fighter.active && fighter.mons[fighter.active - 1]) || null;
  const first = usableMove(mon);
  if (first === null) return null;
  const d = mon.disable;
  const disabledSlot = (isTable(d) && int(d.turns, 0) > 0) ? int(d.moveIndex, 0) : 0;
  for (let n = 0; n < REDRAW_LIMIT; n += 1) {
    const c = battle.rng.byte() % 4;
    const rec = mon.moves[c];
    if (c + 1 !== disabledSlot && isTable(rec) && int(rec.pp, 0) > 0) return c + 1;
  }
  return first;
}

module.exports = {
  NUM_MOVES,
  BASE_SCORE,
  UNUSABLE_SCORE,
  DISMISS,
  BASE_STAT_LEVEL,
  MAX_STAT_LEVEL,
  EFFECTIVE,
  BASE_AI_SWITCH_SCORE,
  LAYERS,
  LAYER_SLOTS,
  REDRAW_LIMIT,
  LINK_MODES,
  CART_EFFECTS,
  CART_EFFECT_NUM,
  FROM_REFEREE,
  STATUS_ONLY_EFFECTS,
  USEFUL_MOVES,
  ENCORE_MOVES,
  RAIN_DANCE_MOVES,
  SUNNY_DAY_MOVES,
  STALL_MOVES,
  RECKLESS_EFFECTS,
  CONSTANT_DAMAGE_EFFECTS,
  RESIDUAL_MOVES,
  RISKY_EFFECTS,
  REDUNDANT,
  SMART,
  LAYER_FUNCS,
  cartEffect,
  statusByte,
  usedMove,
  turnsTaken,
  enemyLockedIn,
  usableMove,
  evaluate,
  choose,
  wildPick,
};
