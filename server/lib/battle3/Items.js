'use strict';

/*
 * Gen 3 items: hold effects (what a held item does in battle) and the bag
 * catalog (what a player may use from the bag mid-fight).
 *
 * Node twin of src/BattleSim3/Items.lua. Held items port engine
 * src/core/game3/battle/held_items.lua (pret battle_util.c ItemBattleEffects:
 * ITEMEFFECT_NORMAL :2557, ITEMEFFECT_MOVE_END :2851,
 * ITEMEFFECT_KINGSROCK_SHELLBELL :2995, ITEMEFFECT_ON_SWITCH_IN :2532, Focus
 * Band battle_script_commands.c:1596). The mapping item -> hold effect is ROM
 * data and rides on the sheet (`holdEffect`, `holdEffectParam`); the enum is
 * pret include/constants/hold_effects.h and is written out here.
 *
 * The bag catalog is the in-battle item set of docs/plans/gen3-battle-sheet.md
 * §4, keyed by pret item ids with the public in-battle amounts -- the same
 * hand-authored policy lib/battle2/Effects.itemEffect follows. The hub holds no
 * ROM, so the catalog states each item's class instead, and sanitize refuses
 * anything else.
 *
 * of -> [holdEffect, param, item].
 *
 * Nothing here throws.
 */

const Status = require('./Status.js');
const {
  int, truthy, own, at, fmt, toNumber, mod,
} = require('./lua.js');

const M = {};

// pokefirered/include/constants/hold_effects.h
M.HOLD = {
  RESTORE_HP: 1,
  CURE_PAR: 2,
  CURE_SLP: 3,
  CURE_PSN: 4,
  CURE_BRN: 5,
  CURE_FRZ: 6,
  RESTORE_PP: 7,
  CURE_CONFUSION: 8,
  CURE_STATUS: 9,
  CONFUSE_SPICY: 10,
  CONFUSE_DRY: 11,
  CONFUSE_SWEET: 12,
  CONFUSE_BITTER: 13,
  CONFUSE_SOUR: 14,
  ATTACK_UP: 15,
  DEFENSE_UP: 16,
  SPEED_UP: 17,
  SP_ATTACK_UP: 18,
  SP_DEFENSE_UP: 19,
  CRITICAL_UP: 20,
  RANDOM_STAT_UP: 21,
  EVASION_UP: 22,
  RESTORE_STATS: 23,
  MACHO_BRACE: 24,
  EXP_SHARE: 25,
  QUICK_CLAW: 26,
  FRIENDSHIP_UP: 27,
  CURE_ATTRACT: 28,
  CHOICE_BAND: 29,
  FLINCH: 30,
  BUG_POWER: 31,
  DOUBLE_PRIZE: 32,
  REPEL: 33,
  SOUL_DEW: 34,
  DEEP_SEA_TOOTH: 35,
  DEEP_SEA_SCALE: 36,
  CAN_ALWAYS_RUN: 37,
  PREVENT_EVOLVE: 38,
  FOCUS_BAND: 39,
  LUCKY_EGG: 40,
  SCOPE_LENS: 41,
  STEEL_POWER: 42,
  LEFTOVERS: 43,
  DRAGON_SCALE: 44,
  LIGHT_BALL: 45,
  GROUND_POWER: 46,
  ROCK_POWER: 47,
  GRASS_POWER: 48,
  DARK_POWER: 49,
  FIGHTING_POWER: 50,
  ELECTRIC_POWER: 51,
  WATER_POWER: 52,
  FLYING_POWER: 53,
  POISON_POWER: 54,
  ICE_POWER: 55,
  GHOST_POWER: 56,
  PSYCHIC_POWER: 57,
  FIRE_POWER: 58,
  DRAGON_POWER: 59,
  NORMAL_POWER: 60,
  UP_GRADE: 61,
  SHELL_BELL: 62,
  LUCKY_PUNCH: 63,
  METAL_POWDER: 64,
  THICK_CLUB: 65,
  STICK: 66,
};
const H = M.HOLD;
M.HOLD_MAX = 66;

// pret ITEM_* ids the battle code branches on.
M.ITEM_MAIL_FIRST = 121;
M.ITEM_MAIL_LAST = 132;
M.ITEM_ENIGMA_BERRY = 175;

// Stat order of the pinch berries (HOLD_EFFECT_ATTACK_UP .. SP_DEFENSE_UP) and
// of the Starf/Salac random raise (held_items.lua STAT_ORDER).
const STAT_ORDER = ['atk', 'def', 'spe', 'spa', 'spd'];
const STAT_LABEL = {
  atk: 'ATTACK',
  def: 'DEFENSE',
  spe: 'SPEED',
  spa: 'SP. ATK',
  spd: 'SP. DEF',
  acc: 'accuracy',
  eva: 'evasiveness',
};
M.STAT_LABEL = STAT_LABEL;

M.isMail = function isMail(idIn) {
  const id = int(idIn, 0);
  return id >= M.ITEM_MAIL_FIRST && id <= M.ITEM_MAIL_LAST;
};

// The effective hold effect of a battler: nothing once Knock Off has taken it.
// Returns [holdEffect, param, item].
M.of = function of(b) {
  if (!truthy(b) || !truthy(b.mon)) return [0, 0, 0];
  const item = int(b.mon.heldItem, 0);
  if (item === 0) return [0, 0, 0];
  return [int(b.mon.holdEffect, 0), int(b.mon.holdParam, 0), item];
};

M.has = function has(b, he) {
  return M.of(b)[0] === he;
};

// ------------------------------------------------------------------
// confusion-berry flavour (derived from the nature, see the sheet doc §5.4)
// ------------------------------------------------------------------

// Flavour f (0 Spicy, 1 Dry, 2 Sweet, 3 Bitter, 4 Sour) and the nature stat it
// tracks, in the nature order Atk 0, Def 1, Spe 2, SpA 3, SpD 4.
const FLAVOR_STAT = {
  0: 0, 1: 3, 2: 2, 3: 4, 4: 1,
};

// +1 likes, -1 dislikes, 0 neutral -- pret gPokeblockFlavorCompatibilityTable
// (pokemon.c:1398), which is exactly this rule over the nature table.
M.flavorRelation = function flavorRelation(nature, flavor) {
  const n = mod(int(nature, 0), 25);
  const up = Math.floor(n / 5);
  const down = n % 5;
  if (up === down) return 0;
  const stat = FLAVOR_STAT[int(flavor, 0)];
  if (stat === up) return 1;
  if (stat === down) return -1;
  return 0;
};

// ------------------------------------------------------------------
// consuming / swapping (battle_script_commands.c:5642 Cmd_removeitem)
// ------------------------------------------------------------------

// The mon's held item after a change, stated on a `held` event so every client
// can write it back.
function heldEvent(B, b, actedItem, text) {
  const knocked = int(b.mon.knockedOff, null);
  B.emit('held', {
    slot: b.slot,
    side: b.side,
    mon: b.partyIndex - 1,
    amount: actedItem,
    holding: knocked !== null ? knocked : int(b.mon.heldItem, 0),
    text,
  });
}
M.heldEvent = heldEvent;

M.consume = function consume(B, b) {
  const item = int(b.mon.heldItem, 0);
  if (item === 0) return;
  const side = B.sideState(b.side);
  // Recycle brings back the last item this SIDE used (pret gLastUsedItem per
  // battler, engine side.expUsedHeldItem); the hold effect rides with it.
  const used = {
    item, effect: int(b.mon.holdEffect, 0), param: int(b.mon.holdParam, 0), name: b.mon.itemName,
  };
  if (used.name == null) delete used.name;
  b.usedHeldItem = used;
  side.usedHeldItem = used;
  b.mon.heldItem = 0;
  b.mon.holdEffect = 0;
  b.mon.holdParam = 0;
  delete b.mon.itemName;
};

M.give = function give(b, row) {
  if (!truthy(row)) {
    b.mon.heldItem = 0;
    b.mon.holdEffect = 0;
    b.mon.holdParam = 0;
    delete b.mon.itemName;
    return;
  }
  b.mon.heldItem = int(row.item, 0);
  b.mon.holdEffect = int(row.effect, 0);
  b.mon.holdParam = int(row.param, 0);
  if (row.name == null) delete b.mon.itemName; else b.mon.itemName = row.name;
};

M.rowOf = function rowOf(b) {
  const item = int(b.mon.heldItem, 0);
  if (item === 0) return null;
  const row = {
    item, effect: int(b.mon.holdEffect, 0), param: int(b.mon.holdParam, 0), name: b.mon.itemName,
  };
  if (row.name == null) delete row.name;
  return row;
};

function label(B, b) {
  return B.itemLabel(b);
}

// ------------------------------------------------------------------
// the individual triggers
// ------------------------------------------------------------------

function statUp(B, b, stat, delta) {
  const item = int(b.mon.heldItem, 0);
  const lbl = label(B, b);
  b.stages[stat] = Math.min(6, b.stages[stat] + delta);
  const verb = delta >= 2 ? ' sharply rose!' : ' rose!';
  const text = `Using ${lbl}, the ${STAT_LABEL[stat]} of ${B.nameOf(b)}${verb}`;
  M.consume(B, b);
  heldEvent(B, b, item, lbl);
  B.emit('stat', {
    slot: b.slot, side: b.side, stat, stage: b.stages[stat], delta, text,
  });
  B.say(text);
}

// data/battle_scripts_1.s:4216
const CURE_TEXT = {
  [H.CURE_PAR]: "'s %s cured paralysis!",
  [H.CURE_PSN]: "'s %s cured poison!",
  [H.CURE_BRN]: "'s %s healed its burn!",
  [H.CURE_FRZ]: "'s %s defrosted it!",
  [H.CURE_SLP]: "'s %s woke it from its sleep!",
};

function cureStatusItem(B, b, he) {
  const s = Status.normalise(b.mon.status);
  const ok = (he === H.CURE_PAR && s === 'PAR') || (he === H.CURE_PSN && (s === 'PSN' || s === 'TOX'))
    || (he === H.CURE_BRN && s === 'BRN') || (he === H.CURE_FRZ && s === 'FRZ')
    || (he === H.CURE_SLP && s === 'SLP');
  if (!ok) return false;
  const item = int(b.mon.heldItem, 0);
  const lbl = label(B, b);
  if (he === H.CURE_SLP) delete b.nightmare;
  M.consume(B, b);
  heldEvent(B, b, item, lbl);
  B.cure(b, B.nameOf(b) + fmt(CURE_TEXT[he], lbl));
  return true;
}

// src/battle_util.c:2778 (Lum Berry)
function lum(B, b, allowNormalized) {
  const s = Status.normalise(b.mon.status);
  const confused = int(b.confusion, 0) > 0;
  if (!truthy(s) && !confused) return false;
  let count = 0;
  let word = null;
  if (truthy(s)) {
    word = own(Status.WORD, s) ? Status.WORD[s] : 'status';
    count += 1;
  }
  if (s === 'SLP') delete b.nightmare;
  if (confused) {
    word = 'confusion';
    count += 1;
  }
  const item = int(b.mon.heldItem, 0);
  const lbl = label(B, b);
  M.consume(B, b);
  heldEvent(B, b, item, lbl);
  let text;
  if (truthy(allowNormalized) && count > 1) {
    text = `${B.nameOf(b)}'s ${lbl} normalized its status!`;
  } else {
    text = `${B.nameOf(b)}'s ${lbl} cured its ${word} problem!`;
  }
  // Lua: `confused and nil or text` -- `nil or text` is text, so the sentence
  // is passed either way. Mirrored as written.
  if (truthy(s)) B.cure(b, text);
  if (confused) {
    delete b.confusion;
    B.emit('status', {
      slot: b.slot, side: b.side, confused: 0, text,
    });
    B.say(text);
  }
  return true;
}

function whiteHerb(B, b) {
  let any = false;
  for (const k of ['atk', 'def', 'spe', 'spa', 'spd', 'acc', 'eva']) {
    if (b.stages[k] < 0) {
      b.stages[k] = 0;
      any = true;
    }
  }
  if (!any) return false;
  const item = int(b.mon.heldItem, 0);
  const lbl = label(B, b);
  M.consume(B, b);
  heldEvent(B, b, item, lbl);
  B.say(`${B.nameOf(b)}'s ${lbl} restored its status!`);
  return true;
}

function mentalHerb(B, b) {
  if (!truthy(b.infatuatedWith)) return false;
  delete b.infatuatedWith;
  const item = int(b.mon.heldItem, 0);
  const lbl = label(B, b);
  M.consume(B, b);
  heldEvent(B, b, item, lbl);
  B.say(`${B.nameOf(b)}'s ${lbl} cured its love problem!`);
  return true;
}

function persim(B, b) {
  if (int(b.confusion, 0) <= 0) return false;
  delete b.confusion;
  const item = int(b.mon.heldItem, 0);
  const lbl = label(B, b);
  M.consume(B, b);
  heldEvent(B, b, item, lbl);
  const text = `${B.nameOf(b)}'s ${lbl} snapped it out of confusion!`;
  B.emit('status', {
    slot: b.slot, side: b.side, confused: 0, text,
  });
  B.say(text);
  return true;
}

// Leppa Berry: the first move slot at 0 PP (held_items.lua leppa).
function leppa(B, b, param) {
  let slot = null;
  for (let i = 1; i <= b.moves.length; i += 1) {
    const mv = b.moves[i - 1];
    if (truthy(mv) && int(mv.pp, 0) === 0) {
      slot = i;
      break;
    }
  }
  if (slot === null) return false;
  const mv = at(b.moves, slot);
  const base = int(mv.maxPp, param);
  const pp = Math.min(base, param);
  const item = int(b.mon.heldItem, 0);
  const lbl = label(B, b);
  M.consume(B, b);
  heldEvent(B, b, item, lbl);
  mv.pp = pp;
  B.say(`${B.nameOf(b)}'s ${lbl} restored ${B.moveLabel(mv)}'s PP!`);
  B.emitMovesOf(b);
  return true;
}

// Returns [item, label].
function healBerry(B, b, amount) {
  const item = int(b.mon.heldItem, 0);
  const lbl = label(B, b);
  B.say(`${B.nameOf(b)}'s ${lbl} restored health!`);
  B.heal(b, amount);
  return [item, lbl];
}

// pokefirered/src/battle_util.c:2557 ITEMEFFECT_NORMAL. `moveTurn` true is the
// after-action pass (Leftovers only ticks at the end of the turn).
M.normal = function normal(B, b, moveTurn) {
  if (!truthy(b) || int(b.mon.hp, 0) <= 0) return false;
  const [he, param] = M.of(b);
  if (he === 0) return false;
  const { hp, maxHp } = b.mon;
  if (he === H.RESTORE_HP) {
    if (hp <= Math.floor(maxHp / 2)) {
      let amt = param;
      if (hp + param > maxHp) amt = maxHp - hp;
      const [item, lbl] = healBerry(B, b, amt);
      M.consume(B, b);
      heldEvent(B, b, item, lbl);
      return true;
    }
  } else if (he === H.RESTORE_PP) {
    return leppa(B, b, param);
  } else if (he === H.RESTORE_STATS) {
    return whiteHerb(B, b);
  } else if (he === H.LEFTOVERS) {
    if (hp < maxHp && !truthy(moveTurn)) {
      let amt = Math.floor(maxHp / 16);
      if (amt === 0) amt = 1;
      const item = int(b.mon.heldItem, 0);
      const lbl = label(B, b);
      heldEvent(B, b, item, lbl);
      B.say(`${B.nameOf(b)}'s ${lbl} restored its HP a little!`);
      B.heal(b, amt);
      return true;
    }
  } else if (he >= H.CONFUSE_SPICY && he <= H.CONFUSE_SOUR) {
    if (hp <= Math.floor(maxHp / 2)) {
      const flavor = he - H.CONFUSE_SPICY;
      let amt = Math.floor(maxHp / Math.max(1, param));
      if (amt === 0) amt = 1;
      if (hp + amt > maxHp) amt = maxHp - hp;
      const [item, lbl] = healBerry(B, b, amt);
      if (M.flavorRelation(b.mon.nature, flavor) < 0) {
        // src/battle_message.c:2282
        B.say(`For ${B.nameOf(b)}, the ${lbl} was bad!`);
        if (b.ability !== 'OWN_TEMPO' && int(b.confusion, 0) <= 0) {
          b.confusion = B.roll(0, 3) + 2;
          const text = `${B.nameOf(b)} became confused!`;
          B.emit('status', {
            slot: b.slot, side: b.side, confused: 1, text,
          });
          B.say(text);
        }
      }
      M.consume(B, b);
      heldEvent(B, b, item, lbl);
      return true;
    }
  } else if (he >= H.ATTACK_UP && he <= H.SP_DEFENSE_UP) {
    const stat = STAT_ORDER[he - H.ATTACK_UP];
    if (hp <= Math.floor(maxHp / Math.max(1, param)) && b.stages[stat] < 6) {
      statUp(B, b, stat, 1);
      return true;
    }
  } else if (he === H.CRITICAL_UP) {
    if (hp <= Math.floor(maxHp / Math.max(1, param)) && !truthy(b.focusEnergy)) {
      b.focusEnergy = true;
      const item = int(b.mon.heldItem, 0);
      const lbl = label(B, b);
      M.consume(B, b);
      heldEvent(B, b, item, lbl);
      B.say(`${B.nameOf(b)} used ${lbl} to get pumped!`);
      return true;
    }
  } else if (he === H.RANDOM_STAT_UP) {
    if (hp <= Math.floor(maxHp / Math.max(1, param))) {
      let any = false;
      for (const s of STAT_ORDER) {
        if (b.stages[s] < 6) any = true;
      }
      if (any) {
        let stat;
        do {
          stat = STAT_ORDER[B.roll(0, 4)];
        } while (!(b.stages[stat] < 6));
        statUp(B, b, stat, 2);
        return true;
      }
    }
  } else if (he >= H.CURE_PAR && he <= H.CURE_FRZ) {
    return cureStatusItem(B, b, he);
  } else if (he === H.CURE_CONFUSION) {
    return persim(B, b);
  } else if (he === H.CURE_STATUS) {
    return lum(B, b, true);
  } else if (he === H.CURE_ATTRACT) {
    return mentalHerb(B, b);
  }
  return false;
};

// pokefirered/src/battle_util.c:2851 ITEMEFFECT_MOVE_END (every standing battler)
M.moveEnd = function moveEnd(B) {
  let any = false;
  for (const b of B.active()) {
    const [he] = M.of(b);
    let did = false;
    if (he >= H.CURE_PAR && he <= H.CURE_FRZ) {
      did = cureStatusItem(B, b, he);
    } else if (he === H.CURE_CONFUSION) {
      did = persim(B, b);
    } else if (he === H.CURE_ATTRACT) {
      did = mentalHerb(B, b);
    } else if (he === H.CURE_STATUS) {
      did = lum(B, b, false);
    } else if (he === H.RESTORE_STATS) {
      did = whiteHerb(B, b);
    }
    any = any || did;
  }
  return any;
};

// pokefirered/src/battle_util.c:2532 ITEMEFFECT_ON_SWITCH_IN (Amulet Coin's
// money multiplier has no meaning on a mediated field; White Herb does).
M.onSwitchIn = function onSwitchIn(B, b) {
  if (!truthy(b)) return false;
  const [he] = M.of(b);
  if (he === H.RESTORE_STATS) return whiteHerb(B, b);
  return false;
};

// pokefirered/src/battle_script_commands.c:1596. Draws only for a holder.
M.rollFocusBand = function rollFocusBand(B, target) {
  const [he, param] = M.of(target);
  if (he === H.FOCUS_BAND && B.roll(0, 99) < param) {
    target.focusBanded = true;
    return true;
  }
  return false;
};

M.focusBandMessage = function focusBandMessage(B, target) {
  const lbl = label(B, target);
  heldEvent(B, target, int(target.mon.heldItem, 0), lbl);
  B.say(`${B.nameOf(target)} hung on using its ${lbl}!`);
};

// ------------------------------------------------------------------
// the bag (docs/plans/gen3-battle-sheet.md §4)
// ------------------------------------------------------------------

const ALL = {
  SLP: true, PSN: true, BRN: true, FRZ: true, PAR: true, TOX: true,
};

M.BAG = {
  // balls
  1: { ball: true },
  2: { ball: true },
  3: { ball: true },
  4: { ball: true },
  6: { ball: true },
  7: { ball: true },
  8: { ball: true },
  9: { ball: true },
  10: { ball: true },
  11: { ball: true },
  12: { ball: true },
  // heals
  13: { heal: 20 },
  22: { heal: 50 },
  21: { heal: 200 },
  20: { healFull: true },
  26: { heal: 50 },
  27: { heal: 60 },
  28: { heal: 80 },
  29: { heal: 100 },
  30: { heal: 50 },
  31: { heal: 200 },
  44: { heal: 20 },
  139: { heal: 10 },
  142: { heal: 30 },
  19: { healFull: true, cure: ALL, confusion: true },
  // cures
  14: { cure: { PSN: true, TOX: true } },
  15: { cure: { BRN: true } },
  16: { cure: { FRZ: true } },
  17: { cure: { SLP: true } },
  18: { cure: { PAR: true } },
  23: { cure: ALL, confusion: true },
  32: { cure: ALL, confusion: true },
  38: { cure: ALL, confusion: true },
  133: { cure: { PAR: true } },
  134: { cure: { SLP: true } },
  135: { cure: { PSN: true, TOX: true } },
  136: { cure: { BRN: true } },
  137: { cure: { FRZ: true } },
  140: { confusion: true },
  141: { cure: ALL, confusion: true },
  39: { cure: { SLP: true } },
  40: { confusion: true },
  41: { attract: true },
  // revives (fainted only)
  24: { revive: 'half' },
  25: { revive: 'full' },
  33: { revive: 'full' },
  // PP
  34: { pp: 10, needsMove: true },
  35: { ppFull: true, needsMove: true },
  36: { ppAll: 10 },
  37: { ppAllFull: true },
  138: { pp: 10, needsMove: true },
  // battle stat items (+1 in Gen 3), active mon only
  73: { mist: true, activeOnly: true },
  74: { focusEnergy: true, activeOnly: true },
  75: { stage: 'atk', activeOnly: true },
  76: { stage: 'def', activeOnly: true },
  77: { stage: 'spe', activeOnly: true },
  78: { stage: 'acc', activeOnly: true },
  79: { stage: 'spa', activeOnly: true },
  // escape
  80: { escape: true },
  81: { escape: true },
  // FRLG Poke Flute (key item)
  350: { flute: true, noConsume: true },
};

// Numeric id from a number or a numeric string (the choice / Wire form).
M.idOf = function idOf(item) {
  let n = toNumber(item);
  if (n === null) return null;
  n = Math.floor(n);
  if (n < 1 || n > 999) return null;
  return n;
};

M.bagEffect = function bagEffect(item) {
  const id = M.idOf(item);
  return (id !== null && own(M.BAG, id)) ? M.BAG[id] : null;
};

// Items that cannot do anything for a fainted mon (everything but a revive).
M.failsOnFainted = function failsOnFainted(effect) {
  if (typeof effect !== 'object' || effect === null) return false;
  if (truthy(effect.revive)) return false;
  return truthy(effect.heal) || truthy(effect.healFull) || truthy(effect.cure)
    || truthy(effect.confusion) || truthy(effect.attract) || truthy(effect.pp)
    || truthy(effect.ppFull) || truthy(effect.ppAll) || truthy(effect.ppAllFull);
};

M.needsParty = function needsParty(effect) {
  if (typeof effect !== 'object' || effect === null) return false;
  return truthy(effect.heal) || truthy(effect.healFull) || truthy(effect.cure)
    || truthy(effect.confusion) || truthy(effect.attract) || truthy(effect.revive)
    || truthy(effect.pp) || truthy(effect.ppFull) || truthy(effect.ppAll)
    || truthy(effect.ppAllFull);
};

module.exports = M;
