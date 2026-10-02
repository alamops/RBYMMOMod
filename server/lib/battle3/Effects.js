'use strict';

/*
 * Gen 3 move effects: secondary effects, stat changes, and every status / setup
 * move handler, keyed by pret EFFECT_* number.
 *
 * Node twin of src/BattleSim3/Effects.lua (a port of the engine's
 * src/core/game3/battle/effects/*.lua and effect_ids.lua: 1:1 pret
 * include/constants/battle_move_effects.h numbering, `SECONDARY` after-hit
 * specs, `STAT_CHANGES`). Each handler cites the pret script or command it
 * mirrors.
 *
 * A handler receives the move context `C` built by Move.js:
 *   C.B (the battle), C.user, C.target (battlers), C.move (row), C.mnum,
 *   C.effect, C.slot, and the methods C.accuracyCheck(mode, printFail),
 *   C.attackAnimation(), C.fail(text?), C.isProtected(), C.tryFaintUser(),
 *   C.tryFaintTarget().
 * and talks to the field through the battle's helper surface (B.say, B.emit,
 * B.heal, B.loseHp, B.inflict, B.cure, B.roll, B.foes, B.sideState, ...).
 *
 * Every EFFECT_* 0..213 resolves: damaging effects go through Move.js's hit
 * pipeline and reach `M.secondaryAfter`; every non-damaging effect has a
 * handler in `M.HANDLERS`; the five unused slots (96, 110, 131, 141, 163) and
 * plain EFFECT_HIT with no power say "But nothing happened!", as the cart's
 * placeholder script does.
 *
 * Indices that are values (move slots from B.slotOfNum, party indices from
 * B.benchOf, roll(1, n) picks) stay 1-based as in the Lua; array reads
 * subtract one.
 *
 * Nothing here throws.
 */

const Types = require('./Types.js');
const Status = require('./Status.js');
const Abilities = require('./Abilities.js');
const Items = require('./Items.js');
const Field = require('./Field.js');
const Damage = require('./Damage.js');
const {
  int, truthy, own, fmt,
} = require('./lua.js');

const M = {};

// pret include/constants/battle_move_effects.h
M.E = {
  HIT: 0,
  SLEEP: 1,
  POISON_HIT: 2,
  ABSORB: 3,
  BURN_HIT: 4,
  FREEZE_HIT: 5,
  PARALYZE_HIT: 6,
  EXPLOSION: 7,
  DREAM_EATER: 8,
  MIRROR_MOVE: 9,
  ATTACK_UP: 10,
  DEFENSE_UP: 11,
  SPEED_UP: 12,
  SPECIAL_ATTACK_UP: 13,
  SPECIAL_DEFENSE_UP: 14,
  ACCURACY_UP: 15,
  EVASION_UP: 16,
  ALWAYS_HIT: 17,
  ATTACK_DOWN: 18,
  DEFENSE_DOWN: 19,
  SPEED_DOWN: 20,
  SPECIAL_ATTACK_DOWN: 21,
  SPECIAL_DEFENSE_DOWN: 22,
  ACCURACY_DOWN: 23,
  EVASION_DOWN: 24,
  HAZE: 25,
  BIDE: 26,
  RAMPAGE: 27,
  ROAR: 28,
  MULTI_HIT: 29,
  CONVERSION: 30,
  FLINCH_HIT: 31,
  RESTORE_HP: 32,
  TOXIC: 33,
  PAY_DAY: 34,
  LIGHT_SCREEN: 35,
  TRI_ATTACK: 36,
  REST: 37,
  OHKO: 38,
  RAZOR_WIND: 39,
  SUPER_FANG: 40,
  DRAGON_RAGE: 41,
  TRAP: 42,
  HIGH_CRITICAL: 43,
  DOUBLE_HIT: 44,
  RECOIL_IF_MISS: 45,
  MIST: 46,
  FOCUS_ENERGY: 47,
  RECOIL: 48,
  CONFUSE: 49,
  ATTACK_UP_2: 50,
  DEFENSE_UP_2: 51,
  SPEED_UP_2: 52,
  SPECIAL_ATTACK_UP_2: 53,
  SPECIAL_DEFENSE_UP_2: 54,
  ACCURACY_UP_2: 55,
  EVASION_UP_2: 56,
  TRANSFORM: 57,
  ATTACK_DOWN_2: 58,
  DEFENSE_DOWN_2: 59,
  SPEED_DOWN_2: 60,
  SPECIAL_ATTACK_DOWN_2: 61,
  SPECIAL_DEFENSE_DOWN_2: 62,
  ACCURACY_DOWN_2: 63,
  EVASION_DOWN_2: 64,
  REFLECT: 65,
  POISON: 66,
  PARALYZE: 67,
  ATTACK_DOWN_HIT: 68,
  DEFENSE_DOWN_HIT: 69,
  SPEED_DOWN_HIT: 70,
  SPECIAL_ATTACK_DOWN_HIT: 71,
  SPECIAL_DEFENSE_DOWN_HIT: 72,
  ACCURACY_DOWN_HIT: 73,
  EVASION_DOWN_HIT: 74,
  SKY_ATTACK: 75,
  CONFUSE_HIT: 76,
  TWINEEDLE: 77,
  VITAL_THROW: 78,
  SUBSTITUTE: 79,
  RECHARGE: 80,
  RAGE: 81,
  MIMIC: 82,
  METRONOME: 83,
  LEECH_SEED: 84,
  SPLASH: 85,
  DISABLE: 86,
  LEVEL_DAMAGE: 87,
  PSYWAVE: 88,
  COUNTER: 89,
  ENCORE: 90,
  PAIN_SPLIT: 91,
  SNORE: 92,
  CONVERSION_2: 93,
  LOCK_ON: 94,
  SKETCH: 95,
  UNUSED_60: 96,
  SLEEP_TALK: 97,
  DESTINY_BOND: 98,
  FLAIL: 99,
  SPITE: 100,
  FALSE_SWIPE: 101,
  HEAL_BELL: 102,
  QUICK_ATTACK: 103,
  TRIPLE_KICK: 104,
  THIEF: 105,
  MEAN_LOOK: 106,
  NIGHTMARE: 107,
  MINIMIZE: 108,
  CURSE: 109,
  UNUSED_6E: 110,
  PROTECT: 111,
  SPIKES: 112,
  FORESIGHT: 113,
  PERISH_SONG: 114,
  SANDSTORM: 115,
  ENDURE: 116,
  ROLLOUT: 117,
  SWAGGER: 118,
  FURY_CUTTER: 119,
  ATTRACT: 120,
  RETURN: 121,
  PRESENT: 122,
  FRUSTRATION: 123,
  SAFEGUARD: 124,
  THAW_HIT: 125,
  MAGNITUDE: 126,
  BATON_PASS: 127,
  PURSUIT: 128,
  RAPID_SPIN: 129,
  SONICBOOM: 130,
  UNUSED_83: 131,
  MORNING_SUN: 132,
  SYNTHESIS: 133,
  MOONLIGHT: 134,
  HIDDEN_POWER: 135,
  RAIN_DANCE: 136,
  SUNNY_DAY: 137,
  DEFENSE_UP_HIT: 138,
  ATTACK_UP_HIT: 139,
  ALL_STATS_UP_HIT: 140,
  UNUSED_8D: 141,
  BELLY_DRUM: 142,
  PSYCH_UP: 143,
  MIRROR_COAT: 144,
  SKULL_BASH: 145,
  TWISTER: 146,
  EARTHQUAKE: 147,
  FUTURE_SIGHT: 148,
  GUST: 149,
  FLINCH_MINIMIZE_HIT: 150,
  SOLAR_BEAM: 151,
  THUNDER: 152,
  TELEPORT: 153,
  BEAT_UP: 154,
  SEMI_INVULNERABLE: 155,
  DEFENSE_CURL: 156,
  SOFTBOILED: 157,
  FAKE_OUT: 158,
  UPROAR: 159,
  STOCKPILE: 160,
  SPIT_UP: 161,
  SWALLOW: 162,
  UNUSED_A3: 163,
  HAIL: 164,
  TORMENT: 165,
  FLATTER: 166,
  WILL_O_WISP: 167,
  MEMENTO: 168,
  FACADE: 169,
  FOCUS_PUNCH: 170,
  SMELLINGSALT: 171,
  FOLLOW_ME: 172,
  NATURE_POWER: 173,
  CHARGE: 174,
  TAUNT: 175,
  HELPING_HAND: 176,
  TRICK: 177,
  ROLE_PLAY: 178,
  WISH: 179,
  ASSIST: 180,
  INGRAIN: 181,
  SUPERPOWER: 182,
  MAGIC_COAT: 183,
  RECYCLE: 184,
  REVENGE: 185,
  BRICK_BREAK: 186,
  YAWN: 187,
  KNOCK_OFF: 188,
  ENDEAVOR: 189,
  ERUPTION: 190,
  SKILL_SWAP: 191,
  IMPRISON: 192,
  REFRESH: 193,
  GRUDGE: 194,
  SNATCH: 195,
  LOW_KICK: 196,
  SECRET_POWER: 197,
  DOUBLE_EDGE: 198,
  TEETER_DANCE: 199,
  BLAZE_KICK: 200,
  MUD_SPORT: 201,
  POISON_FANG: 202,
  WEATHER_BALL: 203,
  OVERHEAT: 204,
  TICKLE: 205,
  COSMIC_POWER: 206,
  SKY_UPPERCUT: 207,
  BULK_UP: 208,
  POISON_TAIL: 209,
  WATER_SPORT: 210,
  CALM_MIND: 211,
  DRAGON_DANCE: 212,
  CAMOUFLAGE: 213,
};
const { E } = M;
M.MAX = 213;

// After-hit secondary effects (pokefirered/data/battle_scripts_1.s:321; engine
// effect_ids.lua SECONDARY).
M.SECONDARY = {
  2: { eff: 'POISON' },
  4: { eff: 'BURN' },
  5: { eff: 'FREEZE' },
  6: { eff: 'PARALYSIS' },
  31: { eff: 'FLINCH' },
  34: { eff: 'PAYDAY' },
  36: { eff: 'TRI_ATTACK' },
  42: { eff: 'WRAP' },
  48: { eff: 'RECOIL_25', user: true, certain: true },
  68: { eff: 'ATK_MINUS_1' },
  69: { eff: 'DEF_MINUS_1' },
  70: { eff: 'SPD_MINUS_1' },
  71: { eff: 'SP_ATK_MINUS_1' },
  72: { eff: 'SP_DEF_MINUS_1' },
  73: { eff: 'ACC_MINUS_1' },
  74: { eff: 'EVS_MINUS_1' },
  76: { eff: 'CONFUSION' },
  77: { eff: 'POISON' },
  80: { eff: 'RECHARGE', user: true, certain: true },
  92: { eff: 'FLINCH' },
  105: { eff: 'STEAL_ITEM' },
  125: { eff: 'BURN' },
  129: { eff: 'RAPIDSPIN', user: true, certain: true },
  138: { eff: 'DEF_PLUS_1', user: true },
  139: { eff: 'ATK_PLUS_1', user: true },
  140: { eff: 'ALL_STATS_UP', user: true },
  146: { eff: 'FLINCH' },
  150: { eff: 'FLINCH' },
  152: { eff: 'PARALYSIS' },
  158: { eff: 'FLINCH', certain: true },
  159: { eff: 'UPROAR', user: true },
  171: { eff: 'REMOVE_PARALYSIS', certain: true },
  182: { eff: 'ATK_DEF_DOWN', user: true, certain: true },
  188: { eff: 'KNOCK_OFF' },
  198: { eff: 'RECOIL_33', user: true, certain: true },
  200: { eff: 'BURN' },
  202: { eff: 'TOXIC' },
  204: { eff: 'SP_ATK_TWO_DOWN', user: true, certain: true },
  209: { eff: 'POISON' },
};

// Stat effects the generic handler resolves (self = user, else target):
// [self, stat, delta] (the Lua's { true, "atk", 1 }, read 0-based here).
M.STAT_CHANGES = {
  10: [true, 'atk', 1],
  11: [true, 'def', 1],
  12: [true, 'spe', 1],
  13: [true, 'spa', 1],
  14: [true, 'spd', 1],
  15: [true, 'acc', 1],
  16: [true, 'eva', 1],
  18: [false, 'atk', -1],
  19: [false, 'def', -1],
  20: [false, 'spe', -1],
  21: [false, 'spa', -1],
  22: [false, 'spd', -1],
  23: [false, 'acc', -1],
  24: [false, 'eva', -1],
  50: [true, 'atk', 2],
  51: [true, 'def', 2],
  52: [true, 'spe', 2],
  53: [true, 'spa', 2],
  54: [true, 'spd', 2],
  55: [true, 'acc', 2],
  56: [true, 'eva', 2],
  58: [false, 'atk', -2],
  59: [false, 'def', -2],
  60: [false, 'spe', -2],
  61: [false, 'spa', -2],
  62: [false, 'spd', -2],
  63: [false, 'acc', -2],
  64: [false, 'eva', -2],
};

// pokefirered/src/battle_script_commands.c:707 sMovesForbiddenToCopy (the -1
// sentinel splits the Metronome list from Mimic's shorter one).
M.FORBIDDEN_TO_COPY = [
  118, 165, 166, 102, -1, 68, 243, 182, 197, 203, 194, 214, 168, 266, 289, 270, 343, 271, 264,
];

M.forbidden = function forbidden(num, stopAtSentinel) {
  for (const m of M.FORBIDDEN_TO_COPY) {
    if (m === -1) {
      if (truthy(stopAtSentinel)) return false;
    } else if (m === num) {
      return true;
    }
  }
  return false;
};

// Move numbers the handlers branch on (pret include/constants/moves.h).
const MOVE = {
  STRUGGLE: 165,
  SKETCH: 166,
  ENCORE: 227,
  MIRROR_MOVE: 119,
  HEAL_BELL: 215,
  DOOM_DESIRE: 353,
  PROTECT: 182,
  DETECT: 197,
  ENDURE: 203,
};
M.MOVE = MOVE;

const STAT_LABEL = {
  atk: 'ATTACK',
  def: 'DEFENSE',
  spe: 'SPEED',
  spa: 'SP. ATK',
  spd: 'SP. DEF',
  acc: 'ACCURACY',
  eva: 'EVASIVENESS',
};
M.STAT_LABEL = STAT_LABEL;
const STAT_ORDER = ['atk', 'def', 'spe', 'spa', 'spd', 'acc', 'eva'];

function isType(b, t) {
  return b != null && (b.type1 === t || b.type2 === t);
}

function nm(B, b) {
  return B.nameOf(b);
}

// The cart's "regular battle" rule for items (MOVE_EFFECT_STEAL_ITEM,
// battle_script_commands.c:2619; Cmd_tryswapitems, :8801 -- pokeemerald's
// same two): an attacker on the opponent side (B_SIDE_OPPONENT, side b) may not
// take or swap the player's items unless the fight is link / recorded link /
// e-reader / frontier (FRLG: battle tower) / secret base. None of those is a
// fight against the computer here, so the bar is Turn.BADGE_MODES (wild /
// coop_wild / coop_npc), read off side a's `badgeRules` -- true on its fighters
// exactly there (Turn requires this module, so it cannot read the set). 1v1 /
// coop_pvp are link fights: either side may. Trainer Hill / Trainer Tower,
// which bar everyone, are never mediated.
function foeItemsBarred(B, user) {
  if (user.side !== 'b') return false;
  const first = B.bySide && B.bySide.a && B.bySide.a[0];
  return first != null && first.badgeRules === true;
}

// ------------------------------------------------------------------
// stat changes (pokefirered/src/battle_script_commands.c:6655 ChangeStatBuffs)
// ------------------------------------------------------------------

// flags: user (the change is the user's own), certain (MOVE_EFFECT_CERTAIN),
//        curse (Curse's self-drop), allowPtr (a primary move: print why it
//        failed), noMsg, noEvent
// Returns "worked" | "blocked" | "wont".
M.changeStat = function changeStat(B, b, stat, delta, flagsIn) {
  const flags = truthy(flagsIn) ? flagsIn : {};
  if (!truthy(b) || !truthy(b.stages)) return 'blocked';
  const cur = truthy(b.stages[stat]) ? b.stages[stat] : 0;
  if (delta < 0) {
    const side = B.sideState(b.side);
    const ab = b.ability;
    if (int(side.mistTurns, 0) > 0 && !truthy(flags.certain) && !truthy(flags.curse)) {
      if (truthy(flags.allowPtr) && !truthy(b.statLoweredMsg)) {
        b.statLoweredMsg = true;
        B.say(nm(B, b) + ' is protected by MIST!');
      }
      return 'blocked';
    }
    if ((ab === 'CLEAR_BODY' || ab === 'WHITE_SMOKE') && !truthy(flags.certain) && !truthy(flags.curse)) {
      if (truthy(flags.allowPtr) && !truthy(b.statLoweredMsg)) {
        b.statLoweredMsg = true;
        B.emitAbility(b);
        B.say(nm(B, b) + "'s " + B.abilityLabel(b) + ' prevents stat loss!');
      }
      return 'blocked';
    }
    if (((ab === 'KEEN_EYE' && stat === 'acc') || (ab === 'HYPER_CUTTER' && stat === 'atk'))
        && !truthy(flags.certain)) {
      if (truthy(flags.allowPtr)) {
        B.emitAbility(b);
        B.say(nm(B, b) + "'s " + B.abilityLabel(b) + ' prevents ' + STAT_LABEL[stat] + ' loss!');
      }
      return 'blocked';
    }
    if (ab === 'SHIELD_DUST' && !truthy(flags.allowPtr) && !truthy(flags.user)) {
      return 'blocked';
    }
    if (cur <= -6) {
      if (!truthy(flags.noMsg)) B.say(nm(B, b) + "'s " + STAT_LABEL[stat] + " won't go lower!");
      return 'wont';
    }
  } else if (cur >= 6) {
    if (!truthy(flags.noMsg)) B.say(nm(B, b) + "'s " + STAT_LABEL[stat] + " won't go higher!");
    return 'wont';
  }
  let nxt = cur + delta;
  if (nxt < -6) nxt = -6; else if (nxt > 6) nxt = 6;
  b.stages[stat] = nxt;
  let text;
  if (delta >= 2) text = ' sharply rose!';
  else if (delta >= 1) text = ' rose!';
  else if (delta <= -2) text = ' harshly fell!';
  else text = ' fell!';
  text = nm(B, b) + "'s " + STAT_LABEL[stat] + text;
  if (!truthy(flags.noEvent)) {
    B.emit('stat', {
      slot: b.slot, side: b.side, stat, stage: nxt, delta: nxt - cur, text,
    });
  }
  if (!truthy(flags.noMsg)) B.say(text);
  return 'worked';
};

// ------------------------------------------------------------------
// secondary effects (pokefirered/src/battle_script_commands.c:2110 SetMoveEffect)
// ------------------------------------------------------------------

const EFFECT_TO_STATUS = {
  SLEEP: 'SLP', POISON: 'PSN', BURN: 'BRN', FREEZE: 'FRZ', PARALYSIS: 'PAR', TOXIC: 'TOX',
};

const STATUS_EFFECT_RANK = {
  SLEEP: 1,
  POISON: 2,
  BURN: 3,
  FREEZE: 4,
  PARALYSIS: 5,
  TOXIC: 6,
  CONFUSION: 7,
  FLINCH: 8,
  TRI_ATTACK: 9,
};

const STAT_EFFECTS = {
  ATK_PLUS_1: ['atk', 1],
  DEF_PLUS_1: ['def', 1],
  SPD_PLUS_1: ['spe', 1],
  SP_ATK_PLUS_1: ['spa', 1],
  SP_DEF_PLUS_1: ['spd', 1],
  ACC_PLUS_1: ['acc', 1],
  EVS_PLUS_1: ['eva', 1],
  ATK_MINUS_1: ['atk', -1],
  DEF_MINUS_1: ['def', -1],
  SPD_MINUS_1: ['spe', -1],
  SP_ATK_MINUS_1: ['spa', -1],
  SP_DEF_MINUS_1: ['spd', -1],
  ACC_MINUS_1: ['acc', -1],
  EVS_MINUS_1: ['eva', -1],
};

// src/battle_message.c:1042 (partial-trap sentences, by move number)
const TRAP_TEXT = {
  20: '%s was squeezed by %s!',
  35: '%s was wrapped by %s!',
  83: '%s was trapped in the vortex!',
  128: '%s clamped %s!',
  250: '%s was trapped in the vortex!',
  328: '%s was trapped by SAND TOMB!',
};

// The Tri Attack pick, keyed by roll(0, 2) (the Lua's { [0] = "BURN", ... }).
const TRI_ATTACK_PICK = ['BURN', 'FREEZE', 'PARALYSIS'];

function applyStatusEffect(C, eff, primary, certain, effBattler) {
  const { B } = C;
  const status = EFFECT_TO_STATUS[eff];
  const ab = effBattler.ability;
  const strict = truthy(primary) || truthy(certain);
  const prevent = (text) => {
    B.emitAbility(effBattler);
    B.say(text);
    return false;
  };
  if (status === 'PSN' || status === 'TOX') {
    if (ab === 'IMMUNITY' && strict) {
      return prevent(nm(B, effBattler) + "'s IMMUNITY prevents poisoning!");
    }
  } else if (status === 'BRN') {
    if (ab === 'WATER_VEIL' && strict) {
      return prevent(nm(B, effBattler) + "'s WATER VEIL prevents burns!");
    }
  } else if (status === 'PAR') {
    if (ab === 'LIMBER' && strict) {
      return prevent(nm(B, effBattler) + "'s LIMBER prevents paralysis!");
    }
  }
  const [canInflict] = B.canInflict(effBattler, status, { ignoreSafeguard: true });
  if (!truthy(canInflict)) {
    if (status === 'TOX' && !truthy(Status.normalise(effBattler.mon.status))
        && (isType(effBattler, Types.ID.POISON) || isType(effBattler, Types.ID.STEEL))) {
      C.doesntAffect = true;
    }
    return false;
  }
  B.inflict(effBattler, status, { source: C.user });
  // pokefirered/src/battle_script_commands.c:2376 (Synchronize bookkeeping)
  if (status === 'PSN' || status === 'TOX' || status === 'PAR' || status === 'BRN') {
    B.syncEffect = { status };
  }
  return true;
}

M.set = function set(C, eff, primary, certain, affectsUser) {
  const { B } = C;
  const { user, target } = C;
  const effBattler = (truthy(affectsUser) && truthy(user)) ? user : target;
  const rank = own(STATUS_EFFECT_RANK, eff) ? STATUS_EFFECT_RANK[eff] : null;
  if (!truthy(effBattler)) return false;
  if (rank !== null && rank <= 9 && !truthy(primary) && effBattler.ability === 'SHIELD_DUST'
      && !truthy(affectsUser)) {
    return false;
  }
  if (rank !== null && rank <= 7 && !truthy(primary) && !truthy(affectsUser)) {
    if (int(B.sideState(effBattler.side).safeguardTurns, 0) > 0) return false;
  }
  if (int(effBattler.mon.hp, 0) <= 0 && eff !== 'PAYDAY' && eff !== 'STEAL_ITEM') return false;
  // STATUS2_SUBSTITUTE: the doll is up, or this strike hit it (the bit outlives
  // a doll that just broke until MOVEEND_SUBSTITUTE -- Move.js C.subStrike).
  if (!truthy(affectsUser) && (int(effBattler.substituteHP, 0) > 0
      || (truthy(C.subStrike) && effBattler === C.target))) {
    return false;
  }

  if (own(EFFECT_TO_STATUS, eff)) {
    return applyStatusEffect(C, eff, primary, certain, effBattler);
  }

  if (eff === 'CONFUSION') {
    if (effBattler.ability === 'OWN_TEMPO' || int(effBattler.confusion, 0) > 0) return false;
    effBattler.confusion = B.roll(0, 3) + 2;
    const text = nm(B, effBattler) + ' became confused!';
    B.emit('status', {
      slot: effBattler.slot, side: effBattler.side, confused: 1, text,
    });
    B.say(text);
    return true;
  }
  if (eff === 'FLINCH') {
    if (effBattler.ability === 'INNER_FOCUS') {
      if (truthy(primary) || truthy(certain)) {
        B.emitAbility(effBattler);
        B.say(nm(B, effBattler) + "'s INNER FOCUS prevents flinching!");
      }
      return false;
    }
    if (!truthy(effBattler.movedThisTurn)) effBattler.flinched = true;
    return true;
  }
  if (eff === 'UPROAR') {
    if (int(effBattler.uproarTurns, 0) > 0) return false;
    effBattler.lockedNum = C.mnum;
    effBattler.lockedSlot = C.slot;
    effBattler.uproarTurns = B.roll(0, 3) + 2;
    B.say(nm(B, effBattler) + ' caused an UPROAR!');
    return true;
  }
  if (eff === 'PAYDAY') {
    // pokefirered/src/battle_script_commands.c:2455: level x 5 into
    // gPaydayMoney (a u16 that saturates) -- counted for either side here; who
    // is paid, and the Amulet Coin doubling, is the outcome's reader's rule
    // (Turn.js `_checkOver`, sheet doc §6).
    const pay = B.payDay;
    if (truthy(pay)) {
      const { side } = user;
      const before = int(pay[side], 0);
      let after = before + int(user.mon.level, 1) * 5;
      if (after > 0xFFFF) after = 0xFFFF;
      pay[side] = after;
    }
    B.say('Coins scattered everywhere!');
    return true;
  }
  if (eff === 'TRI_ATTACK') {
    if (truthy(Status.normalise(effBattler.mon.status))) return false;
    const r = B.roll(0, 2);
    const pick = TRI_ATTACK_PICK[r];
    return M.set(C, pick, false, false, false);
  }
  if (eff === 'WRAP') {
    if (int(effBattler.trapTurns, 0) > 0) return false;
    // pokefirered/src/battle_script_commands.c:2490 ((Random() & 3) + 3)
    effBattler.trapTurns = B.roll(0, 3) + 3;
    effBattler.trapMove = C.mnum;
    effBattler.trapSource = user;
    const pattern = own(TRAP_TEXT, C.mnum) ? TRAP_TEXT[C.mnum] : '%s was trapped by %s!';
    B.say(fmt(pattern, nm(B, effBattler), nm(B, user)));
    return true;
  }
  if (eff === 'RECOIL_25' || eff === 'RECOIL_33') {
    const div = (eff === 'RECOIL_25') ? 4 : 3;
    let dmg = Math.floor(int(C.hpDealt, 0) / div);
    if (dmg === 0) dmg = 1;
    if (C.mnum !== MOVE.STRUGGLE && user.ability === 'ROCK_HEAD') return false;
    B.loseHp(user, dmg);
    B.say(nm(B, user) + ' is hit with recoil!');
    C.checkUserFaint = true;
    return true;
  }
  if (own(STAT_EFFECTS, eff)) {
    // pokefirered/src/battle_script_commands.c:2544: ChangeStatBuffs gets
    // `affectsUser` alone, never MOVE_EFFECT_CERTAIN -- a 100% Icy Wind still
    // stops at Clear Body / White Smoke / Keen Eye / Hyper Cutter / Mist.
    const spec = STAT_EFFECTS[eff];
    const res = M.changeStat(B, effBattler, spec[0], spec[1], {
      user: affectsUser, certain: false, allowPtr: false,
    });
    return res === 'worked';
  }
  if (eff === 'RECHARGE') {
    effBattler.rechargeTurns = 2;
    effBattler.mustRecharge = true;
    return true;
  }
  if (eff === 'STEAL_ITEM') {
    // src/battle_script_commands.c:2610. Against the computer the foe's Thief /
    // Covet takes nothing and says nothing (:2619 skips the effect before Sticky
    // Hold is asked; foeItemsBarred): the hit has landed, the player keeps the
    // item. A link fight (1v1 / coop_pvp) lets either side steal. A mon whose
    // item was knocked off may not (:2628, pret knockedOffMons): it still owns
    // that item after the fight (Knock Off keeps `mon.knockedOff` for the
    // `holding` writeback), so a stolen item would vanish there. The cart skips
    // this check only in link fights; this one writes items back like a
    // non-link fight, so the check stands.
    if (foeItemsBarred(B, user)) return false;
    if (truthy(user.mon.knockedOff)) return false;
    const tItem = int(target.mon.heldItem, 0);
    if (tItem !== 0 && target.ability === 'STICKY_HOLD') {
      B.emitAbility(target);
      B.say(nm(B, target) + "'s STICKY HOLD made " + C.moveName() + ' ineffective!');
      return false;
    }
    if (int(user.mon.heldItem, 0) !== 0 || tItem === 0 || tItem === Items.ITEM_ENIGMA_BERRY
        || Items.isMail(tItem)) {
      return false;
    }
    const row = Items.rowOf(target);
    const lbl = B.itemLabel(target);
    Items.give(user, row);
    Items.give(target, null);
    // :2668: the robbed battler's Choice Band lock goes with the band
    delete target.choicedMove;
    Items.heldEvent(B, user, tItem, lbl);
    Items.heldEvent(B, target, tItem, lbl);
    B.say(nm(B, user) + ' stole ' + nm(B, target) + "'s " + lbl + '!');
    return true;
  }
  if (eff === 'ALL_STATS_UP') {
    const order = ['atk', 'def', 'spe', 'spa', 'spd'];
    let any = false;
    for (const s of order) {
      if (user.stages[s] < 6) any = true;
    }
    if (!any) return false;
    for (const s of order) {
      if (user.stages[s] < 6) M.changeStat(B, user, s, 1, { user: true });
    }
    return true;
  }
  if (eff === 'RAPIDSPIN') {
    // pokefirered/src/battle_script_commands.c:8435
    let did = false;
    if (int(user.trapTurns, 0) > 0) {
      const src = user.trapSource;
      B.say(nm(B, user) + ' got free of ' + (truthy(src) ? nm(B, src) : 'the foe') + "'s "
        + B.moveLabelByNum(user.trapMove) + '!');
      delete user.trapTurns;
      delete user.trapMove;
      delete user.trapSource;
      did = true;
    }
    if (truthy(user.seededBy)) {
      delete user.seededBy;
      B.say(nm(B, user) + ' was freed from LEECH SEED!');
      did = true;
    }
    const side = B.sideState(user.side);
    if (int(side.spikes, 0) > 0) {
      side.spikes = 0;
      B.say(nm(B, user) + ' blew away SPIKES!');
      did = true;
    }
    return did;
  }
  if (eff === 'REMOVE_PARALYSIS') {
    if (Status.normalise(target.mon.status) !== 'PAR') return false;
    B.cure(target, nm(B, target) + ' was cured of paralysis.');
    return true;
  }
  if (eff === 'ATK_DEF_DOWN') {
    M.changeStat(B, user, 'atk', -1, {
      user: true, certain: true, allowPtr: true, noMsg: user.stages.atk <= -6,
    });
    M.changeStat(B, user, 'def', -1, {
      user: true, certain: true, allowPtr: true, noMsg: user.stages.def <= -6,
    });
    return true;
  }
  if (eff === 'SP_ATK_TWO_DOWN') {
    if (user.stages.spa > -6) {
      M.changeStat(B, user, 'spa', -2, { user: true, certain: true, allowPtr: true });
    }
    return true;
  }
  if (eff === 'THRASH') {
    if (int(effBattler.rampageTurns, 0) > 0) return false;
    effBattler.lockedNum = C.mnum;
    effBattler.lockedSlot = C.slot;
    effBattler.rampageTurns = B.roll(0, 1) + 2;
    return true;
  }
  if (eff === 'KNOCK_OFF') {
    const tItem = int(effBattler.mon.heldItem, 0);
    if (effBattler.ability === 'STICKY_HOLD') {
      if (tItem === 0) return false;
      B.emitAbility(effBattler);
      B.say(nm(B, effBattler) + "'s STICKY HOLD made " + C.moveName() + ' ineffective!');
      return false;
    }
    if (tItem === 0) return false;
    // pokefirered/src/battle_script_commands.c:2730: gone for the rest of the
    // battle, still held in the party afterwards (`holding` says so).
    const lbl = B.itemLabel(effBattler);
    effBattler.mon.knockedOff = tItem;
    Items.give(effBattler, null);
    delete effBattler.choicedMove; // :2757
    Items.heldEvent(B, effBattler, tItem, lbl);
    B.say(nm(B, user) + ' knocked off ' + nm(B, effBattler) + "'s " + lbl + '!');
    return true;
  }
  return false;
};

// pokefirered/src/battle_script_commands.c:2774 Cmd_seteffectwithchance.
// `Random() % 100 <= chance`: the cart's off-by-one, so a 10% effect lands 11%.
M.withChance = function withChance(C, eff, certainFlag, affectsUser) {
  if (!truthy(eff)) return false;
  if (truthy(C.noEffect)) return false;
  let chance = int(truthy(C.move) ? C.move.chance : C.move, 0);
  if (C.user.ability === 'SERENE_GRACE') chance *= 2;
  if (truthy(certainFlag)) {
    return M.set(C, eff, false, true, affectsUser);
  }
  if (C.B.roll(0, 99) <= chance) {
    return M.set(C, eff, false, chance >= 100, affectsUser);
  }
  return false;
};

// engine effects/hit.lua secondary_after
M.secondaryAfter = function secondaryAfter(C) {
  if (truthy(C.noEffect)) return;
  const eff = C.effect;
  let spec = own(M.SECONDARY, eff) ? M.SECONDARY[eff] : null;
  if (eff === E.SMELLINGSALT && truthy(C.hitSubstitute)) spec = null;
  if (eff === E.SECRET_POWER) {
    const pick = Field.SECRET_POWER_EFFECT[C.B.terrain];
    spec = { eff: truthy(pick) ? pick : 'PARALYSIS' };
  }
  if (truthy(C.extraEffect)) spec = C.extraEffect;
  if (truthy(spec)) {
    M.withChance(C, spec.eff, spec.certain, spec.user);
  }
  if (eff === E.RAMPAGE && truthy(C.startRampage)) {
    M.set(C, 'THRASH', false, true, true);
  }
};

// ------------------------------------------------------------------
// handler helpers
// ------------------------------------------------------------------

function sub(b) {
  return int(truthy(b) ? b.substituteHP : b, 0) > 0;
}

function safeguarded(C, b) {
  if (int(C.B.sideState(b.side).safeguardTurns, 0) > 0) {
    C.B.say(nm(C.B, b) + ' is protected by SAFEGUARD!');
    return true;
  }
  return false;
}

function notAffected(C, b) {
  C.noEffect = true;
  C.B.say("It doesn't affect " + nm(C.B, b) + '...');
}

function primary(C, eff) {
  return M.set(C, eff, true, false, false);
}

// pokefirered/src/battle_script_commands.c:6546
function cantMakeAsleep(C, b) {
  const { B } = C;
  const ab = b.ability;
  if (truthy(B.uproarActive()) && ab !== 'SOUNDPROOF') {
    B.say('But the UPROAR kept ' + nm(B, b) + ' awake!');
    return true;
  }
  if (ab === 'INSOMNIA' || ab === 'VITAL_SPIRIT') {
    B.emitAbility(b);
    B.say(nm(B, b) + ' stayed awake using its ' + B.abilityLabel(b) + '!');
    return true;
  }
  return false;
}

// pokefirered/data/battle_scripts_1.s:491 (BattleScript_EffectStatUp)
function statUp(C, stat, delta) {
  const { B, user } = C;
  if (user.stages[stat] >= 6) {
    B.say(nm(B, user) + "'s " + STAT_LABEL[stat] + " won't go higher!");
    C.failed = true;
    return;
  }
  C.attackAnimation();
  M.changeStat(B, user, stat, delta, { user: true, allowPtr: true });
}

// pokefirered/data/battle_scripts_1.s:536 (BattleScript_EffectStatDown)
function statDown(C, stat, delta) {
  const { B } = C;
  const t = C.target;
  if (sub(t)) return C.fail();
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  const side = B.sideState(t.side);
  const ab = t.ability;
  const blocked = int(side.mistTurns, 0) > 0 || ab === 'CLEAR_BODY' || ab === 'WHITE_SMOKE'
    || (ab === 'KEEN_EYE' && stat === 'acc') || (ab === 'HYPER_CUTTER' && stat === 'atk');
  if (!blocked && t.stages[stat] > -6) C.attackAnimation();
  M.changeStat(B, t, stat, delta, { allowPtr: true });
  return undefined;
}

function multiUp(C, stats) {
  const { B, user } = C;
  let any = false;
  for (const s of stats) {
    if (user.stages[s] < 6) any = true;
  }
  if (!any) {
    C.failed = true;
    B.say(nm(B, user) + "'s stats won't go any higher!");
    return;
  }
  C.attackAnimation();
  for (const s of stats) {
    if (user.stages[s] < 6) {
      M.changeStat(B, user, s, 1, { user: true, allowPtr: true });
    }
  }
}

// engine effects/stats.lua swagger_like (pokefirered/data/battle_scripts_1.s:1604)
function swaggerLike(C, stat, delta) {
  const { B } = C;
  const t = C.target;
  if (sub(t)) {
    C.missed = true;
    B.say(nm(B, C.user) + "'s attack missed!");
    return undefined;
  }
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  if (int(t.confusion, 0) > 0 && t.stages[stat] >= 6) return C.fail();
  C.attackAnimation();
  if (t.stages[stat] < 6) {
    M.changeStat(B, t, stat, delta, { allowPtr: true });
  }
  if (t.ability === 'OWN_TEMPO') {
    B.emitAbility(t);
    B.say(nm(B, t) + "'s OWN TEMPO prevents confusion!");
    return undefined;
  }
  if (int(B.sideState(t.side).safeguardTurns, 0) > 0) {
    B.say(nm(B, t) + ' is protected by SAFEGUARD!');
    return undefined;
  }
  M.set(C, 'CONFUSION', true, false, false);
  return undefined;
}

// pokefirered/src/battle_script_commands.c:6220 (Protect / Detect / Endure)
function protectLike(C, onSuccess) {
  const { B, user } = C;
  const last = user.lastResultingNum;
  if (last !== MOVE.PROTECT && last !== MOVE.DETECT && last !== MOVE.ENDURE) {
    user.protectStreak = 0;
  }
  const streak = int(user.protectStreak, 0);
  let ok = user.turnOrder !== B.battlerCount();
  if (ok && streak > 0) {
    const denom = 2 ** Math.min(streak, 3);
    ok = B.roll(0, denom - 1) === 0;
  }
  if (!ok) {
    user.protectStreak = 0;
    return C.fail();
  }
  user.protectStreak = streak + 1;
  C.attackAnimation();
  onSuccess(user);
  return undefined;
}

// The weather moves (pokefirered/src/battle_script_commands.c:6399).
function setWeather(C, kind, text) {
  const { B } = C;
  if (B.field.weather === kind) return C.fail();
  B.field.weather = kind;
  B.field.weatherTurns = Field.WEATHER_TURNS;
  C.attackAnimation();
  B.emit('weather', {
    text: kind, amount: 1, slot: C.user.slot, side: C.user.side,
  });
  B.say(text);
  return undefined;
}

// The last move a battler used (pret gLastMoves), as a move row the user can
// read: [row, num], or [null, null].
function lastMoveRow(B, b) {
  const num = truthy(b) ? b.lastMoveNum : b;
  if (!truthy(num) || num === 0) return [null, null];
  return [B.moveRowByNum(num, b), num];
}

// ------------------------------------------------------------------
// the handlers, by effect number
// ------------------------------------------------------------------

const H = {};
M.HANDLERS = H;

// pokefirered/data/battle_scripts_1.s:287
H[E.SLEEP] = function effectSleep(C) {
  const { B } = C;
  const t = C.target;
  if (sub(t)) return C.fail();
  if (Status.normalise(t.mon.status) === 'SLP') {
    return B.say(nm(B, t) + ' is already asleep!');
  }
  if (cantMakeAsleep(C, t)) return undefined;
  if (truthy(Status.normalise(t.mon.status))) return C.fail();
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  if (safeguarded(C, t)) return undefined;
  C.attackAnimation();
  primary(C, 'SLEEP');
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:984
H[E.POISON] = function effectPoison(C) {
  const { B } = C;
  const t = C.target;
  if (t.ability === 'IMMUNITY') {
    B.emitAbility(t);
    return B.say(nm(B, t) + "'s IMMUNITY prevents poisoning!");
  }
  if (sub(t)) return C.fail();
  const s = Status.normalise(t.mon.status);
  if (s === 'PSN' || s === 'TOX') return B.say(nm(B, t) + ' is already poisoned.');
  if (isType(t, Types.ID.POISON) || isType(t, Types.ID.STEEL)) return notAffected(C, t);
  if (truthy(s)) return C.fail();
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  if (safeguarded(C, t)) return undefined;
  C.attackAnimation();
  primary(C, 'POISON');
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:687
H[E.TOXIC] = function effectToxic(C) {
  const { B } = C;
  const t = C.target;
  if (t.ability === 'IMMUNITY') {
    B.emitAbility(t);
    return B.say(nm(B, t) + "'s IMMUNITY prevents poisoning!");
  }
  if (sub(t)) return C.fail();
  const s = Status.normalise(t.mon.status);
  if (s === 'PSN' || s === 'TOX') return B.say(nm(B, t) + ' is already poisoned.');
  if (truthy(s)) return C.fail();
  if (isType(t, Types.ID.POISON) || isType(t, Types.ID.STEEL)) return notAffected(C, t);
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  if (safeguarded(C, t)) return undefined;
  C.attackAnimation();
  primary(C, 'TOXIC');
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:1005
H[E.PARALYZE] = function effectParalyze(C) {
  const { B } = C;
  const t = C.target;
  if (t.ability === 'LIMBER') {
    B.emitAbility(t);
    return B.say(nm(B, t) + "'s LIMBER prevents paralysis!");
  }
  if (sub(t)) return C.fail();
  const mt = int(C.move.type, 0);
  const [, flags] = Types.typeCalc(B.typeTable, mt, t.type1, t.type2, null, t.identified);
  if (flags.immune || (t.ability === 'LEVITATE' && mt === Types.ID.GROUND)) {
    return notAffected(C, t);
  }
  const s = Status.normalise(t.mon.status);
  if (s === 'PAR') return B.say(nm(B, t) + ' is already paralyzed!');
  if (truthy(s)) return C.fail();
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  if (safeguarded(C, t)) return undefined;
  C.attackAnimation();
  primary(C, 'PARALYSIS');
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:2170
H[E.WILL_O_WISP] = function effectWillOWisp(C) {
  const { B } = C;
  const t = C.target;
  if (sub(t)) return C.fail();
  const s = Status.normalise(t.mon.status);
  if (s === 'BRN') return B.say(nm(B, t) + ' already has a burn.');
  if (isType(t, Types.ID.FIRE)) return notAffected(C, t);
  if (t.ability === 'WATER_VEIL') {
    B.emitAbility(t);
    return B.say(nm(B, t) + "'s WATER VEIL prevents burns!");
  }
  if (truthy(s)) return C.fail();
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  if (safeguarded(C, t)) return undefined;
  C.attackAnimation();
  primary(C, 'BURN');
  return undefined;
};

// The generic stat moves (EXP_STAT_FROM_EFFECT) over every stat effect id.
// Each id is written once, so the walk order does not matter (as in the Lua,
// which walks with pairs).
for (const id of Object.keys(M.STAT_CHANGES)) {
  const spec = M.STAT_CHANGES[id];
  if (spec[0]) {
    H[id] = function effectStatUp(C) { statUp(C, spec[1], spec[2]); };
  } else {
    H[id] = function effectStatDown(C) { statDown(C, spec[1], spec[2]); };
  }
}

// pokefirered/data/battle_scripts_1.s:1472
H[E.MINIMIZE] = function effectMinimize(C) {
  C.user.minimized = true;
  statUp(C, 'eva', 1);
};

// pokefirered/data/battle_scripts_1.s:2010
H[E.DEFENSE_CURL] = function effectDefenseCurl(C) {
  C.user.defenseCurl = true;
  statUp(C, 'def', 1);
};

H[E.CALM_MIND] = function effectCalmMind(C) { multiUp(C, ['spa', 'spd']); };
H[E.BULK_UP] = function effectBulkUp(C) { multiUp(C, ['atk', 'def']); };
H[E.DRAGON_DANCE] = function effectDragonDance(C) { multiUp(C, ['atk', 'spe']); };
H[E.COSMIC_POWER] = function effectCosmicPower(C) { multiUp(C, ['def', 'spd']); };

// pokefirered/data/battle_scripts_1.s:2644
H[E.TICKLE] = function effectTickle(C) {
  const { B } = C;
  const t = C.target;
  if (t.stages.atk <= -6 && t.stages.def <= -6) {
    C.failed = true;
    return B.say(nm(B, t) + "'s stats won't go any lower!");
  }
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  C.attackAnimation();
  M.changeStat(B, t, 'atk', -1, { allowPtr: true, noMsg: t.stages.atk <= -6 });
  M.changeStat(B, t, 'def', -1, { allowPtr: true, noMsg: t.stages.def <= -6 });
  return undefined;
};

H[E.SWAGGER] = function effectSwagger(C) { swaggerLike(C, 'atk', 2); };
H[E.FLATTER] = function effectFlatter(C) { swaggerLike(C, 'spa', 1); };

// pokefirered/src/battle_script_commands.c:8423
H[E.PSYCH_UP] = function effectPsychUp(C) {
  const t = C.target;
  if (!truthy(t) || !truthy(t.stages)) return C.fail();
  for (const s of STAT_ORDER) C.user.stages[s] = truthy(t.stages[s]) ? t.stages[s] : 0;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + ' copied ' + nm(C.B, t) + "'s stat changes!");
  return undefined;
};

// pokefirered/src/battle_script_commands.c:6568
H[E.STOCKPILE] = function effectStockpile(C) {
  const n = int(C.user.stockpile, 0);
  if (n >= 3) {
    C.failed = true;
    return C.B.say(nm(C.B, C.user) + " can't STOCKPILE any more!");
  }
  C.user.stockpile = n + 1;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + ' STOCKPILED ' + String(n + 1) + '!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:8709
H[E.CHARGE] = function effectCharge(C) {
  C.user.charged = 2;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + ' began charging power!');
};

// pokefirered/data/battle_scripts_1.s:2199
H[E.MEMENTO] = function effectMemento(C) {
  const { B, user } = C;
  const t = C.target;
  const isProtected = C.isProtected();
  if (!truthy(isProtected) && t.stages.atk <= -6 && t.stages.spa <= -6) return C.fail();
  B.setHp(user, 0);
  if (truthy(isProtected)) {
    B.say(nm(B, t) + ' protected itself!');
  } else {
    C.attackAnimation();
    if (sub(t)) {
      B.say('But it had no effect!');
    } else {
      M.changeStat(B, t, 'atk', -2, { allowPtr: true, noMsg: t.stages.atk <= -6 });
      M.changeStat(B, t, 'spa', -2, { allowPtr: true, noMsg: t.stages.spa <= -6 });
    }
  }
  C.checkUserFaint = true;
  C.tryFaintUser();
  return undefined;
};

// pokefirered/src/battle_script_commands.c:8266
H[E.SAFEGUARD] = function effectSafeguard(C) {
  const side = C.B.sideState(C.user.side);
  if (int(side.safeguardTurns, 0) > 0) return C.fail();
  side.safeguardTurns = Field.SAFEGUARD_TURNS;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + "'s party is covered by a veil!");
  return undefined;
};

// pokefirered/src/battle_script_commands.c:6415 / :7082
function screen(C, key, what) {
  const { B } = C;
  const side = B.sideState(C.user.side);
  if (int(side[key], 0) > 0) return C.fail();
  side[key] = Field.SCREEN_TURNS;
  C.attackAnimation();
  const little = truthy(B.double) && B.countStandingOnSide(C.user.side) >= 2;
  B.say(C.moveName() + ' raised ' + what + (little ? ' a little!' : '!'));
  return undefined;
}
H[E.REFLECT] = function effectReflect(C) { screen(C, 'reflectTurns', 'DEFENSE'); };
H[E.LIGHT_SCREEN] = function effectLightScreen(C) { screen(C, 'lightScreenTurns', 'SP. DEF'); };

// pokefirered/data/battle_scripts_1.s:873
H[E.MIST] = function effectMist(C) {
  const side = C.B.sideState(C.user.side);
  if (int(side.mistTurns, 0) > 0) return C.fail();
  side.mistTurns = Field.MIST_TURNS;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + "'s party became shrouded in MIST!");
  return undefined;
};

// pokefirered/src/battle_script_commands.c:8110
H[E.SPIKES] = function effectSpikes(C) {
  const foeSide = C.B.sideState(C.user.side === 'a' ? 'b' : 'a');
  if (int(foeSide.spikes, 0) >= 3) return C.fail();
  foeSide.spikes = int(foeSide.spikes, 0) + 1;
  C.attackAnimation();
  C.B.say("SPIKES were scattered all around the opponent's side!");
  return undefined;
};

H[E.SUNNY_DAY] = function effectSunnyDay(C) { setWeather(C, 'SUN', 'The sunlight got bright!'); };
H[E.RAIN_DANCE] = function effectRainDance(C) { setWeather(C, 'RAIN', 'It started to rain!'); };
H[E.SANDSTORM] = function effectSandstorm(C) { setWeather(C, 'SAND', 'A sandstorm brewed!'); };
H[E.HAIL] = function effectHail(C) { setWeather(C, 'HAIL', 'It started to hail!'); };

// pokefirered/data/battle_scripts_1.s:2515
H[E.REFRESH] = function effectRefresh(C) {
  const s = Status.normalise(C.user.mon.status);
  if (!(s === 'BRN' || s === 'PSN' || s === 'PAR' || s === 'TOX')) return C.fail();
  C.attackAnimation();
  C.B.cure(C.user, nm(C.B, C.user) + "'s status returned to normal!");
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:2372
H[E.INGRAIN] = function effectIngrain(C) {
  if (truthy(C.user.ingrain)) return C.fail();
  C.user.ingrain = true;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + ' planted its roots!');
  return undefined;
};

function hpFull(C, b) {
  C.B.say(nm(C.B, b) + "'s HP is full!");
}

// pokefirered/src/battle_script_commands.c:6332
function recover(C) {
  const { B, user } = C;
  if (user.mon.hp >= user.mon.maxHp) return hpFull(C, user);
  let heal = Math.floor(user.mon.maxHp / 2);
  if (heal === 0) heal = 1;
  C.attackAnimation();
  B.heal(user, heal);
  B.say(nm(B, user) + ' regained health!');
  return undefined;
}
H[E.RESTORE_HP] = recover;
H[E.SOFTBOILED] = recover;

// pokefirered/src/battle_script_commands.c:8478
function morningSun(C) {
  const { B, user } = C;
  const { maxHp } = user.mon;
  if (user.mon.hp >= maxHp) return hpFull(C, user);
  const weather = B.weather();
  let heal;
  if (!truthy(weather)) heal = Math.floor(maxHp / 2);
  else if (weather === 'SUN') heal = Math.floor(20 * maxHp / 30);
  else heal = Math.floor(maxHp / 4);
  if (heal === 0) heal = 1;
  C.attackAnimation();
  B.heal(user, heal);
  B.say(nm(B, user) + ' regained health!');
  return undefined;
}
H[E.MORNING_SUN] = morningSun;
H[E.SYNTHESIS] = morningSun;
H[E.MOONLIGHT] = morningSun;

// pokefirered/data/battle_scripts_1.s:735
H[E.REST] = function effectRest(C) {
  const { B, user } = C;
  if (Status.normalise(user.mon.status) === 'SLP') {
    return B.say(nm(B, user) + ' is already asleep!');
  }
  if (cantMakeAsleep(C, user)) return undefined;
  const { maxHp, hp } = user.mon;
  if (hp >= maxHp) return hpFull(C, user);
  const had = Status.normalise(user.mon.status) != null;
  B.cure(user, null);
  // pokefirered/src/battle_script_commands.c:6480 (3 turns, so 2 asleep)
  B.inflict(user, 'SLP', {
    turns: 3, force: true, silent: true, source: user,
  });
  if (had) {
    B.say(nm(B, user) + ' slept and became healthy!');
  } else {
    B.say(nm(B, user) + ' went to sleep!');
  }
  C.attackAnimation();
  B.heal(user, maxHp - hp);
  B.say(nm(B, user) + ' regained health!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:8399
H[E.BELLY_DRUM] = function effectBellyDrum(C) {
  const { B, user } = C;
  let half = Math.floor(user.mon.maxHp / 2);
  if (half === 0) half = 1;
  if (user.stages.atk >= 6 || user.mon.hp <= half) return C.fail();
  const before = user.stages.atk;
  user.stages.atk = 6;
  C.attackAnimation();
  B.loseHp(user, half);
  const text = nm(B, user) + ' cut its own HP and maximized ATTACK!';
  B.emit('stat', {
    slot: user.slot, side: user.side, stat: 'atk', stage: 6, delta: 6 - before, text,
  });
  B.say(text);
  return undefined;
};

// pokefirered/src/battle_script_commands.c:8899
H[E.WISH] = function effectWish(C) {
  const { B } = C;
  const side = B.sideState(C.user.side);
  for (const tok of side.wish) {
    if (tok.slot === C.user.slot) return C.fail();
  }
  side.wish.push({ turns: 2, wisher: nm(B, C.user), slot: C.user.slot });
  C.attackAnimation();
  B.say(nm(B, C.user) + ' made a WISH!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:7995 (Heal Bell / Aromatherapy)
H[E.HEAL_BELL] = function effectHealBell(C) {
  const { B, user } = C;
  const isBell = C.mnum === MOVE.HEAL_BELL;
  const blocked = isBell && user.ability === 'SOUNDPROOF';
  if (!blocked && truthy(Status.normalise(user.mon.status))) {
    B.cure(user, null);
    delete user.nightmare;
  }
  const blockedAllies = [];
  for (const ally of B.allies(user)) {
    if (isBell && ally.ability === 'SOUNDPROOF') {
      blockedAllies.push(ally);
    } else if (truthy(Status.normalise(ally.mon.status))) {
      B.cure(ally, null);
      delete ally.nightmare;
    }
  }
  // The benched party: every mon of the user's seat that is not on the field,
  // except (Heal Bell only) a Soundproof one -- pokefirered/src/battle_script_
  // commands.c:7995 reads each party member's species ability. A shared
  // party's partner is out on the sibling seat: the ally pass above already
  // asked its battler's ability (the cart reads gBattleMons for the partner's
  // party index too), so a Soundproof partner is not cured here behind it.
  const { mons } = user.fighter;
  for (let i = 1; i <= mons.length; i += 1) {
    const mon = mons[i - 1];
    if (!B.fieldedSeat(user.fighter, i) && mon.hp > 0 && truthy(Status.normalise(mon.status))
        && !(isBell && Abilities.nameOf(mon.ability) === 'SOUNDPROOF')) {
      delete mon.status;
      delete mon.sleepTurns;
    }
  }
  C.attackAnimation();
  if (isBell) {
    B.say('A bell chimed!');
    if (blocked) {
      B.emitAbility(user);
      B.say(nm(B, user) + "'s SOUNDPROOF blocks the bell!");
    }
    for (const ally of blockedAllies) {
      B.emitAbility(ally);
      B.say(nm(B, ally) + "'s SOUNDPROOF blocks the bell!");
    }
  } else {
    B.say('A soothing aroma wafted through the area!');
  }
  B.syncTeamsNow();
};

// pokefirered/src/battle_script_commands.c:7674
H[E.PAIN_SPLIT] = function effectPainSplit(C) {
  const { B, user } = C;
  const t = C.target;
  if (!truthy(C.accuracyCheck('lockon', true))) return undefined;
  if (sub(t)) return C.fail();
  const avg = Math.floor((user.mon.hp + t.mon.hp) / 2);
  C.attackAnimation();
  B.setHp(user, Math.min(user.mon.maxHp, avg));
  B.setHp(t, Math.min(t.mon.maxHp, avg));
  B.say('The battlers shared their pain!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:6612
H[E.SWALLOW] = function effectSwallow(C) {
  const { B, user } = C;
  const n = int(user.stockpile, 0);
  if (n <= 0) return B.say('But it failed to SWALLOW a thing!');
  const { maxHp } = user.mon;
  user.stockpile = 0;
  if (user.mon.hp >= maxHp) return hpFull(C, user);
  let heal = Math.floor(maxHp / (2 ** (3 - n)));
  if (heal === 0) heal = 1;
  C.attackAnimation();
  B.heal(user, heal);
  B.say(nm(B, user) + ' regained health!');
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:1440 (Mean Look / Block / Spider Web)
H[E.MEAN_LOOK] = function effectMeanLook(C) {
  const { B } = C;
  const t = C.target;
  if (!truthy(t)) return C.fail();
  if (!truthy(C.accuracyCheck('noacc', true))) return undefined;
  if (truthy(t.trappedBy)) return C.fail();
  if (sub(t)) return C.fail();
  C.attackAnimation();
  t.trappedBy = C.user;
  B.say(nm(B, t) + " can't escape now!");
  return undefined;
};

// pokefirered/src/battle_script_commands.c:6436
H[E.LEECH_SEED] = function effectLeechSeed(C) {
  const { B } = C;
  const t = C.target;
  if (sub(t)) return C.fail();
  const hit = C.accuracyCheck('normal', false);
  C.attackAnimation();
  if (!truthy(hit) || truthy(t.seededBy)) {
    return B.say(nm(B, t) + ' evaded the attack!');
  }
  if (isType(t, Types.ID.GRASS)) {
    return B.say("It doesn't affect " + nm(B, t) + '...');
  }
  t.seededBy = C.user.slot;
  B.say(nm(B, t) + ' was seeded!');
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:1330
H[E.DESTINY_BOND] = function effectDestinyBond(C) {
  C.user.destinyBond = true;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + ' is trying to take its foe with it!');
};

// pokefirered/data/battle_scripts_1.s:1455
H[E.NIGHTMARE] = function effectNightmare(C) {
  const { B } = C;
  const t = C.target;
  if (sub(t)) return C.fail();
  if (truthy(t.nightmare)) return C.fail();
  if (Status.normalise(t.mon.status) !== 'SLP') return C.fail();
  C.attackAnimation();
  t.nightmare = true;
  B.say(nm(B, t) + ' began having a NIGHTMARE!');
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:884
H[E.FOCUS_ENERGY] = function effectFocusEnergy(C) {
  if (truthy(C.user.focusEnergy)) return C.fail();
  C.user.focusEnergy = true;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + ' is getting pumped!');
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:1551 (Foresight / Odor Sleuth)
H[E.FORESIGHT] = function effectForesight(C) {
  if (!truthy(C.accuracyCheck('normal', true))) return;
  C.target.identified = true;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + ' identified ' + nm(C.B, C.target) + '!');
};

// pokefirered/src/battle_script_commands.c:7759 (Lock-On / Mind Reader)
H[E.LOCK_ON] = function effectLockOn(C) {
  const t = C.target;
  if (sub(t)) return C.fail();
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  t.lockedOnTurns = 2;
  t.lockedOnBy = C.user;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + ' took aim at ' + nm(C.B, t) + '!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:9144 / :9160 (fail when last to move)
H[E.MAGIC_COAT] = function effectMagicCoat(C) {
  if (C.user.turnOrder === C.B.battlerCount()) return C.fail();
  C.user.magicCoat = true;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + ' shrouded itself in MAGIC COAT!');
  return undefined;
};

H[E.SNATCH] = function effectSnatch(C) {
  if (C.user.turnOrder === C.B.battlerCount()) return C.fail();
  C.user.snatch = true;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + ' waits for a target to make a move!');
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:2527
H[E.GRUDGE] = function effectGrudge(C) {
  if (truthy(C.user.grudge)) return C.fail();
  C.user.grudge = true;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + ' wants the opponent to bear a GRUDGE!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:9019
H[E.IMPRISON] = function effectImprison(C) {
  const { B, user } = C;
  if (truthy(user.imprison)) return C.fail();
  let shared = false;
  for (const foe of B.foes(user)) {
    for (let i = 1; i <= user.moves.length; i += 1) {
      const a = int(user.moves[i - 1].num, 0);
      if (a !== 0) {
        for (let j = 1; j <= foe.moves.length; j += 1) {
          if (int(foe.moves[j - 1].num, 0) === a) shared = true;
        }
      }
    }
  }
  if (!shared) return C.fail();
  user.imprison = true;
  C.attackAnimation();
  B.say(nm(B, user) + " sealed the opponent's move(s)!");
  return undefined;
};

// pokefirered/src/battle_script_commands.c:9316
H[E.MUD_SPORT] = function effectMudSport(C) {
  if (truthy(C.user.mudSport)) return C.fail();
  C.user.mudSport = true;
  C.attackAnimation();
  C.B.say("Electricity's power was weakened!");
  return undefined;
};

H[E.WATER_SPORT] = function effectWaterSport(C) {
  if (truthy(C.user.waterSport)) return C.fail();
  C.user.waterSport = true;
  C.attackAnimation();
  C.B.say("FIRE's power was weakened!");
  return undefined;
};

// pokefirered/src/battle_script_commands.c:9389
H[E.CAMOUFLAGE] = function effectCamouflage(C) {
  const { B, user } = C;
  const terrainType = Field.TERRAIN_TYPE[B.terrain];
  const t = truthy(terrainType) ? terrainType : Types.ID.NORMAL;
  if (isType(user, t)) return C.fail();
  user.type1 = t;
  delete user.type2;
  C.attackAnimation();
  B.say(nm(B, user) + ' transformed into the ' + B.typeLabel(t) + ' type!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:8884
H[E.ROLE_PLAY] = function effectRolePlay(C) {
  const { B } = C;
  if (!truthy(C.accuracyCheck('lockon', true))) return undefined;
  const foeAb = C.target.ability;
  if (!truthy(foeAb) || foeAb === 'WONDER_GUARD') return C.fail();
  C.user.ability = foeAb;
  C.user.abilityName = C.target.abilityName;
  C.attackAnimation();
  B.emitAbility(C.user);
  B.say(nm(B, C.user) + ' copied ' + nm(B, C.target) + "'s " + B.abilityLabel(C.target) + '!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:8999
H[E.SKILL_SWAP] = function effectSkillSwap(C) {
  const { B } = C;
  if (!truthy(C.accuracyCheck('lockon', true))) return undefined;
  const a = C.user.ability;
  const b = C.target.ability;
  if ((!truthy(a) && !truthy(b)) || a === 'WONDER_GUARD' || b === 'WONDER_GUARD') return C.fail();
  const an = C.user.abilityName;
  const bn = C.target.abilityName;
  C.user.ability = b;
  C.target.ability = a;
  C.user.abilityName = bn;
  C.target.abilityName = an;
  C.attackAnimation();
  B.emitAbility(C.user);
  B.emitAbility(C.target);
  B.say(nm(B, C.user) + ' swapped abilities with its opponent!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:8544 (Future Sight / Doom Desire):
// a delayed hit whose base damage is fixed now and rolled when it lands.
H[E.FUTURE_SIGHT] = function effectFutureSight(C) {
  const { B, user } = C;
  const t = C.target;
  const side = B.sideState(t.side);
  for (const tok of side.futureSight) {
    if (tok.targetSlot === t.slot) return C.fail();
  }
  const defSide = B.sideState(t.side);
  let dmg = Damage.base(user, t, C.move, {
    weather: B.weather(),
    specialTypes: B.specialTypes,
    reflect: int(defSide.reflectTurns, 0) > 0,
    lightScreen: int(defSide.lightScreenTurns, 0) > 0,
    doubleScreens: truthy(B.double) && B.countStandingOnSide(t.side) >= 2,
    mudSport: B.fieldSport('mudSport'),
    waterSport: B.fieldSport('waterSport'),
    plusPartner: B.abilityOnField('PLUS'),
    minusPartner: B.abilityOnField('MINUS'),
  });
  // pokefirered/src/battle_script_commands.c:8558
  if (truthy(user.helpingHand)) dmg = Math.floor(dmg * 15 / 10);
  const doom = C.mnum === MOVE.DOOM_DESIRE;
  side.futureSight.push({
    turns: 3,
    damage: dmg,
    move: C.move,
    attackerSlot: user.slot,
    targetSlot: t.slot,
    doom,
    attackerName: nm(B, user),
  });
  C.attackAnimation();
  if (doom) {
    B.say(nm(B, user) + ' chose DOOM DESIRE as its destiny!');
  } else {
    B.say(nm(B, user) + ' foresaw an attack!');
  }
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:1478
H[E.CURSE] = function effectCurse(C) {
  const { B, user } = C;
  if (isType(user, Types.ID.GHOST)) {
    // The aimed battler (Move.js `_pickTarget`); still the user when nothing
    // was aimed -- a called or Encored Curse -- and then the battler opposite
    // (BattleScript_GhostCurse's getmovetarget; engine setup.lua curse: foeOf).
    let t = C.target;
    if (t === user || !truthy(t)) {
      t = B.oppositeFoe(user);
      C.target = t;
    }
    if (!truthy(t)) return C.fail();
    if (sub(t)) return C.fail();
    if (!truthy(C.accuracyCheck('lockon', true))) return undefined;
    if (truthy(t.cursed)) return C.fail();
    t.cursed = true;
    let cost = Math.floor(user.mon.maxHp / 2);
    if (cost === 0) cost = 1;
    C.attackAnimation();
    B.loseHp(user, cost);
    B.say(nm(B, user) + ' cut its own HP and laid a CURSE on ' + nm(B, t) + '!');
    C.checkUserFaint = true;
    return undefined;
  }
  const s = user.stages;
  if (s.spe <= -6 && s.atk >= 6 && s.def >= 6) return C.fail();
  C.attackAnimation();
  M.changeStat(B, user, 'spe', -1, {
    user: true, allowPtr: true, curse: true, noMsg: s.spe <= -6,
  });
  M.changeStat(B, user, 'atk', 1, { user: true, allowPtr: true, noMsg: s.atk >= 6 });
  M.changeStat(B, user, 'def', 1, { user: true, allowPtr: true, noMsg: s.def >= 6 });
  return undefined;
};

// pokefirered/src/battle_script_commands.c:8779 (the nearest ally)
H[E.HELPING_HAND] = function effectHelpingHand(C) {
  const { B, user } = C;
  const partner = truthy(C.chosenAlly) ? C.chosenAlly : B.partner(user);
  if (!truthy(B.double) || !truthy(partner) || truthy(user.helpingHand) || truthy(partner.helpingHand)) {
    return C.fail();
  }
  partner.helpingHand = true;
  C.target = partner;
  C.attackAnimation();
  B.say(nm(B, user) + ' is ready to help ' + nm(B, partner) + '!');
  return undefined;
};

H[E.SPLASH] = function effectSplash(C) {
  C.attackAnimation();
  C.B.say('But nothing happened!');
};

// pokefirered/data/battle_scripts_1.s:902 (Supersonic / Confuse Ray / Sweet Kiss)
H[E.CONFUSE] = function effectConfuse(C) {
  const { B } = C;
  const t = C.target;
  if (t.ability === 'OWN_TEMPO') {
    B.emitAbility(t);
    return B.say(nm(B, t) + "'s OWN TEMPO prevents confusion!");
  }
  if (sub(t)) return C.fail();
  if (int(t.confusion, 0) > 0) return B.say(nm(B, t) + ' is already confused!');
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  if (safeguarded(C, t)) return undefined;
  C.attackAnimation();
  M.set(C, 'CONFUSION', true, false, false);
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:2566 (Teeter Dance: every other battler)
H[E.TEETER_DANCE] = function effectTeeterDance(C) {
  const { B } = C;
  const t = C.target;
  if (t.ability === 'OWN_TEMPO') {
    B.emitAbility(t);
    return B.say(nm(B, t) + "'s OWN TEMPO prevents confusion!");
  }
  if (sub(t)) return C.fail();
  if (int(t.confusion, 0) > 0) return B.say(nm(B, t) + ' is already confused!');
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  if (int(B.sideState(t.side).safeguardTurns, 0) > 0) {
    return B.say(nm(B, t) + ' is protected by SAFEGUARD!');
  }
  C.attackAnimation();
  M.set(C, 'CONFUSION', true, false, false);
  return undefined;
};

// pokefirered/src/battle_script_commands.c:6826
H[E.HAZE] = function effectHaze(C) {
  C.attackAnimation();
  for (const b of C.B.active()) {
    for (const k of STAT_ORDER) b.stages[k] = 0;
  }
  C.B.say('All stat changes were eliminated!');
};

// pokefirered/src/battle_script_commands.c:7442
H[E.SUBSTITUTE] = function effectSubstitute(C) {
  const { B, user } = C;
  if (sub(user)) return B.say(nm(B, user) + ' already has a SUBSTITUTE!');
  let cost = Math.floor(user.mon.maxHp / 4);
  if (cost === 0) cost = 1;
  if (user.mon.hp <= cost) {
    C.failed = true;
    return B.say('It was too weak to make a SUBSTITUTE!');
  }
  user.substituteHP = cost;
  delete user.trapTurns;
  delete user.trapMove;
  delete user.trapSource;
  C.attackAnimation();
  B.loseHp(user, cost);
  B.emit('sub', { slot: user.slot, side: user.side, amount: 1 });
  B.say(nm(B, user) + ' made a SUBSTITUTE!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:6220
H[E.PROTECT] = function effectProtect(C) {
  protectLike(C, (user) => {
    user.protected = true;
    C.B.say(nm(C.B, user) + ' protected itself!');
  });
};

H[E.ENDURE] = function effectEndure(C) {
  protectLike(C, (user) => {
    user.enduring = true;
    C.B.say(nm(C.B, user) + ' braced itself!');
  });
};

// pokefirered/src/battle_script_commands.c:7642
H[E.ENCORE] = function effectEncore(C) {
  const { B } = C;
  const t = C.target;
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  const last = int(t.lastMoveNum, 0);
  if (last === 0 || last === MOVE.STRUGGLE || last === MOVE.ENCORE || last === MOVE.MIRROR_MOVE) {
    return C.fail();
  }
  if (int(t.encoreTurns, 0) > 0) return C.fail();
  const slot = B.slotOfNum(t, last);
  if (!truthy(slot) || int(t.moves[slot - 1].pp, 0) <= 0) return C.fail();
  t.encoreNum = last;
  t.encoreSlot = slot;
  t.encoreTurns = B.roll(0, 3) + 3;
  C.attackAnimation();
  B.say(nm(B, t) + ' got an ENCORE!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:8133
H[E.PERISH_SONG] = function effectPerishSong(C) {
  const { B } = C;
  let affected = 0;
  const blocked = [];
  for (const b of B.active()) {
    if (b.ability === 'SOUNDPROOF') {
      blocked.push(b);
    } else if (b.perishTurns == null) {
      b.perishTurns = 3;
      affected += 1;
    }
  }
  if (affected === 0) return C.fail();
  C.attackAnimation();
  B.say('All affected POKeMON will faint in three turns!');
  for (const b of blocked) {
    B.emitAbility(b);
    B.say(nm(B, b) + "'s SOUNDPROOF blocks PERISH SONG!");
  }
  return undefined;
};

// pokefirered/src/battle_script_commands.c:7275
H[E.ATTRACT] = function effectAttract(C) {
  const { B } = C;
  const t = C.target;
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  if (t.ability === 'OBLIVIOUS') {
    B.emitAbility(t);
    return B.say(nm(B, t) + "'s OBLIVIOUS prevents romance!");
  }
  const ug = C.user.mon.gender;
  const tg = t.mon.gender;
  if (truthy(t.infatuatedWith) || !truthy(ug) || !truthy(tg) || ug === 'U' || tg === 'U' || ug === tg) {
    return C.fail();
  }
  t.infatuatedWith = C.user;
  C.attackAnimation();
  B.say(nm(B, t) + ' fell in love!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:7943
H[E.SPITE] = function effectSpite(C) {
  const { B } = C;
  const t = C.target;
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  const last = int(t.lastMoveNum, 0);
  const slot = last !== 0 ? B.slotOfNum(t, last) : null;
  if (!truthy(slot) || int(t.moves[slot - 1].pp, 0) <= 1) return C.fail();
  const mv = t.moves[slot - 1];
  let cut = B.roll(0, 3) + 2;
  if (mv.pp < cut) cut = mv.pp;
  mv.pp -= cut;
  if (mv.pp === 0) B.cancelMultiTurn(t);
  C.attackAnimation();
  B.say('It reduced the PP of ' + nm(B, t) + "'s " + B.moveLabel(mv) + ' by ' + String(cut) + '!');
  B.emitMovesOf(t);
  return undefined;
};

// pokefirered/src/battle_script_commands.c:8744
H[E.TORMENT] = function effectTorment(C) {
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  if (truthy(C.target.tormented)) return C.fail();
  C.target.tormented = true;
  C.attackAnimation();
  C.B.say(nm(C.B, C.target) + ' was subjected to TORMENT!');
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:2303
H[E.TAUNT] = function effectTaunt(C) {
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  if (int(C.target.tauntTurns, 0) > 0) return C.fail();
  // pokefirered/src/battle_script_commands.c:8765
  C.target.tauntTurns = 2;
  C.attackAnimation();
  C.B.say(nm(C.B, C.target) + ' fell for the TAUNT!');
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:2446
H[E.YAWN] = function effectYawn(C) {
  const { B } = C;
  const t = C.target;
  const ab = t.ability;
  if (ab === 'VITAL_SPIRIT' || ab === 'INSOMNIA') {
    B.emitAbility(t);
    return B.say(nm(B, t) + "'s " + B.abilityLabel(t) + ' made it ineffective!');
  }
  if (sub(t)) return C.fail();
  if (int(B.sideState(t.side).safeguardTurns, 0) > 0) {
    return B.say(nm(B, t) + ' is protected by SAFEGUARD!');
  }
  if (!truthy(C.accuracyCheck('lockon', true))) return undefined;
  if (truthy(B.uproarActive()) && ab !== 'SOUNDPROOF') return C.fail();
  if (int(t.yawnTurns, 0) > 0 || truthy(Status.normalise(t.mon.status))) return C.fail();
  t.yawnTurns = 2;
  C.attackAnimation();
  B.say(nm(B, C.user) + ' made ' + nm(B, t) + ' drowsy!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:6905 (Roar / Whirlwind)
H[E.ROAR] = function effectRoar(C) {
  const { B, user } = C;
  const t = C.target;
  if (t.ability === 'SUCTION_CUPS') {
    B.emitAbility(t);
    return B.say(nm(B, t) + ' anchors itself with SUCTION CUPS!');
  }
  if (truthy(t.ingrain)) return B.say(nm(B, t) + ' anchored itself with its roots!');
  if (!truthy(C.accuracyCheck('lockon', true))) return undefined;
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  const candidates = B.benchOf(t.fighter);
  if (!truthy(B.isWild()) && candidates.length < 1) return C.fail();
  const uLvl = int(user.mon.level, 1);
  const tLvl = int(t.mon.level, 1);
  if (uLvl < tLvl) {
    const r = B.roll(0, 255);
    if (Math.floor(r * (uLvl + tLvl) / 256) + 1 <= Math.floor(tLvl / 4)) return C.fail();
  }
  C.attackAnimation();
  if (truthy(B.isWild())) {
    // pokefirered/data/battle_scripts_1.s:3283: blown out of a wild fight
    B.blownAway(t);
    return undefined;
  }
  const slot = candidates[B.roll(1, candidates.length) - 1];
  const nb = B.forceSwitch(t.fighter, slot, 'roar');
  if (truthy(nb)) {
    C.target = nb;
    B.say(nm(B, nb) + ' was dragged out!');
    B.switchInEffects(nb, { spikes: true, deferIntimidate: true });
  }
  return undefined;
};

// pokefirered/src/battle_script_commands.c:7003
H[E.CONVERSION] = function effectConversion(C) {
  const { B, user } = C;
  const list = [];
  for (let i = 1; i <= user.moves.length; i += 1) {
    const mv = user.moves[i - 1];
    if (!truthy(mv) || int(mv.num, 0) === 0) break;
    let t = int(mv.type, 0);
    if (t === Types.ID.MYSTERY) {
      t = isType(user, Types.ID.GHOST) ? Types.ID.GHOST : Types.ID.NORMAL;
    }
    if (!isType(user, t)) list.push(t);
  }
  if (list.length === 0) return C.fail();
  const t = list[B.roll(1, list.length) - 1];
  user.type1 = t;
  delete user.type2;
  C.attackAnimation();
  B.say(nm(B, user) + ' transformed into the ' + B.typeLabel(t) + ' type!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:7699
H[E.CONVERSION_2] = function effectConversion2(C) {
  const { B, user } = C;
  const last = int(user.lastLandedMove, 0);
  const lastType = user.lastHitByType;
  if (last === 0 || lastType == null) return C.fail();
  const foe = user.lastHitBy;
  if (truthy(foe) && truthy(B.isTwoTurnNum(last)) && truthy(foe.twoTurnNum)) return C.fail();
  // The random draw (:7717) ranges over every row of gTypeEffectiveness, the
  // two after the Foresight marker included (Normal / Fighting -> Ghost): the
  // marker row itself never matches (its attack type is TYPE_FORESIGHT), and
  // the rows past it are ordinary resistances.
  const valid = [];
  const t = truthy(B.typeTable) ? B.typeTable : [];
  let i = 1;
  while (i + 2 <= t.length) {
    const a = t[i - 1];
    const d = t[i];
    const m = t[i + 1];
    if (a !== Types.FORESIGHT_SENTINEL && a === lastType && m <= 5 && !isType(user, d)) {
      valid.push(d);
    }
    i += 3;
  }
  if (valid.length === 0) return C.fail();
  const pick = valid[B.roll(1, valid.length) - 1];
  user.type1 = pick;
  delete user.type2;
  C.attackAnimation();
  B.say(nm(B, user) + ' transformed into the ' + B.typeLabel(pick) + ' type!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:7398
H[E.TRANSFORM] = function effectTransform(C) {
  const { B, user } = C;
  const t = C.target;
  if (truthy(t.transformed) || truthy(t.semi)) return C.fail();
  user.stats = {
    atk: t.stats.atk, def: t.stats.def, spe: t.stats.spe, spa: t.stats.spa, spd: t.stats.spd,
  };
  const moves = [];
  for (let i = 1; i <= t.moves.length; i += 1) {
    const src = t.moves[i - 1];
    const copy = B.copyMove(src);
    copy.pp = Math.min(5, int(src.maxPp, 5));
    copy.maxPp = copy.pp;
    moves[i - 1] = copy;
  }
  user.moves = moves;
  user.overlay = true;
  for (const k of STAT_ORDER) user.stages[k] = t.stages[k];
  user.type1 = t.type1;
  if (t.type2 == null) delete user.type2; else user.type2 = t.type2;
  user.ability = t.ability;
  user.abilityName = t.abilityName;
  // pret copies the whole battle struct from species on (the species too), so
  // species-keyed items follow the new species.
  user.speciesNum = t.speciesNum;
  user.transformed = true;
  delete user.disabledNum;
  delete user.disableTurns;
  C.attackAnimation();
  B.emit('form', {
    slot: user.slot, side: user.side, speciesId: t.mon.speciesId, text: t.mon.species,
  });
  B.say(nm(B, user) + ' transformed into ' + t.mon.species + '!');
  B.emitMovesOf(user);
  return undefined;
};

// pokefirered/src/battle_script_commands.c:7478
H[E.MIMIC] = function effectMimic(C) {
  const { B, user } = C;
  const t = C.target;
  if (sub(t)) return C.fail();
  if (!truthy(C.accuracyCheck('lockon', true))) return undefined;
  const [row, last] = lastMoveRow(B, t);
  if (!truthy(row) || truthy(user.transformed) || M.forbidden(last, true)) return C.fail();
  if (B.slotOfNum(user, last) != null) return C.fail();
  const { slot } = C;
  if (!truthy(slot)) return C.fail();
  B.overlayMoves(user);
  const copy = B.copyMove(row);
  copy.pp = Math.min(5, int(truthy(row.maxPp) ? row.maxPp : row.pp, 5));
  copy.maxPp = copy.pp;
  user.moves[slot - 1] = copy;
  C.attackAnimation();
  B.say(nm(B, user) + ' learned ' + B.moveLabel(copy) + '!');
  B.emitMovesOf(user);
  return undefined;
};

// pokefirered/src/battle_script_commands.c:7617
H[E.DISABLE] = function effectDisable(C) {
  const { B } = C;
  const t = C.target;
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  const last = int(t.lastMoveNum, 0);
  const slot = last !== 0 ? B.slotOfNum(t, last) : null;
  if (truthy(t.disabledNum) || !truthy(slot) || int(t.moves[slot - 1].pp, 0) <= 0) return C.fail();
  t.disabledNum = int(t.moves[slot - 1].num, 0);
  t.disableTurns = B.roll(0, 3) + 2;
  C.attackAnimation();
  B.say(nm(B, t) + "'s " + B.moveLabel(t.moves[slot - 1]) + ' was disabled!');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:7768 (permanent: the party learns it)
H[E.SKETCH] = function effectSketch(C) {
  const { B, user } = C;
  const t = C.target;
  if (sub(t)) return C.fail();
  const last = int(t.lastPrinted, 0);
  if (truthy(user.transformed) || last === 0 || last === MOVE.STRUGGLE || last === MOVE.SKETCH) {
    return C.fail();
  }
  for (let i = 1; i <= user.moves.length; i += 1) {
    const n = int(user.moves[i - 1].num, 0);
    if (n !== MOVE.SKETCH && n === last) return C.fail();
  }
  const { slot } = C;
  const row = B.moveRowByNum(last, t);
  if (!truthy(slot) || !truthy(row)) return C.fail();
  const copy = B.copyMove(row);
  copy.pp = int(truthy(row.maxPp) ? row.maxPp : row.pp, 5);
  copy.maxPp = copy.pp;
  user.mon.moves[slot - 1] = copy;
  if (!truthy(user.overlay)) user.moves = user.mon.moves; else user.moves[slot - 1] = B.copyMove(copy);
  C.attackAnimation();
  B.say(nm(B, user) + ' SKETCHED ' + B.moveLabel(copy) + '!');
  B.emitMovesOf(user, true);
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:1690
H[E.BATON_PASS] = function effectBatonPass(C) {
  const { B, user } = C;
  const candidates = B.benchOf(user.fighter);
  if (candidates.length === 0) return C.fail();
  C.attackAnimation();
  let slot = candidates[0];
  const want = C.passSlot;
  for (const c of candidates) {
    if (c === want) slot = want;
  }
  const nb = B.forceSwitch(user.fighter, slot, 'baton_pass', user);
  if (truthy(nb)) {
    C.user = nb;
    B.switchInEffects(nb, { spikes: true, deferIntimidate: true });
  }
  return undefined;
};

// pokefirered/data/battle_scripts_1.s:1921
H[E.TELEPORT] = function effectTeleport(C) {
  const { B, user } = C;
  if (!truthy(B.isWild())) return C.fail();
  const [he] = Items.of(user);
  if (!(user.ability === 'RUN_AWAY' || he === Items.HOLD.CAN_ALWAYS_RUN)) {
    const [holder] = Abilities.escapeBlocker(B, user);
    if (truthy(holder)) {
      B.emitAbility(holder);
      return B.say(nm(B, holder) + "'s " + B.abilityLabel(holder) + ' made it ineffective!');
    }
    if (truthy(B.isTrapped(user))) return C.fail();
  }
  C.attackAnimation();
  B.say(nm(B, user) + ' fled from battle!');
  B.concede(user.fighter);
  return undefined;
};

// pokefirered/src/battle_script_commands.c:8702
H[E.FOLLOW_ME] = function effectFollowMe(C) {
  const side = C.B.sideState(C.user.side);
  side.followMe = C.user;
  C.attackAnimation();
  C.B.say(nm(C.B, C.user) + ' became the center of attention!');
};

// pokefirered/src/battle_script_commands.c:8798 (Cmd_tryswapitems, after the
// Substitute and accuracy checks of BattleScript_EffectTrick). Against the
// computer the foe's Trick fails before anything else is asked (:8801,
// foeItemsBarred); a link fight (1v1 / coop_pvp) lets either side swap.
H[E.TRICK] = function effectTrick(C) {
  const { B, user } = C;
  const t = C.target;
  if (sub(t)) return C.fail();
  if (!truthy(C.accuracyCheck('normal', true))) return undefined;
  if (foeItemsBarred(B, user)) return C.fail();
  if (truthy(user.mon.knockedOff) || truthy(t.mon.knockedOff)) return C.fail();
  const ui = int(user.mon.heldItem, 0);
  const ti = int(t.mon.heldItem, 0);
  if ((ui === 0 && ti === 0) || ui === Items.ITEM_ENIGMA_BERRY || ti === Items.ITEM_ENIGMA_BERRY
      || Items.isMail(ui) || Items.isMail(ti)) {
    return C.fail();
  }
  if (t.ability === 'STICKY_HOLD') {
    B.emitAbility(t);
    return B.say(nm(B, t) + "'s STICKY HOLD made " + C.moveName() + ' ineffective!');
  }
  const urow = Items.rowOf(user);
  const trow = Items.rowOf(t);
  const ulbl = B.itemLabel(user);
  const tlbl = B.itemLabel(t);
  Items.give(user, trow);
  Items.give(t, urow);
  // :8862: both Choice Band locks are lifted
  delete user.choicedMove;
  delete t.choicedMove;
  C.attackAnimation();
  Items.heldEvent(B, user, ti, tlbl);
  Items.heldEvent(B, t, ui, ulbl);
  B.say(nm(B, user) + ' switched items with its opponent!');
  if (ti !== 0) B.say(nm(B, user) + ' obtained ' + tlbl + '.');
  if (ui !== 0) B.say(nm(B, t) + ' obtained ' + ulbl + '.');
  return undefined;
};

// pokefirered/src/battle_script_commands.c:9366: the last item consumed by
// whoever stood at this battler position (gBattleStruct->usedHeldItems is kept
// per position, not per mon or per side -- Items.consume).
H[E.RECYCLE] = function effectRecycle(C) {
  const { B, user } = C;
  const used = Items.usedAt(B, user.slot);
  if (!truthy(used) || int(user.mon.heldItem, 0) !== 0) return C.fail();
  Items.clearUsedAt(B, user.slot);
  Items.give(user, used);
  C.attackAnimation();
  const lbl = B.itemLabel(user);
  Items.heldEvent(B, user, used.item, lbl);
  B.say(nm(B, user) + ' found one ' + lbl + '!');
  return undefined;
};

// The unused slots and a power-0 plain hit: the cart's placeholder.
for (const id of [0, 96, 110, 131, 141, 163]) {
  H[id] = function effectPlaceholder(C) {
    C.attackAnimation();
    C.B.say('But nothing happened!');
  };
}

// Resolves a non-damaging effect. Returns false when there is no handler, so
// the caller can say "But nothing happened!" (the damaging and calling effects
// never reach here).
M.run = function run(C) {
  const fn = H[int(C.effect, -1)];
  if (fn === undefined) return false;
  fn(C);
  return true;
};

M.handles = function handles(effect) {
  return H[int(effect, -1)] !== undefined;
};

module.exports = M;
