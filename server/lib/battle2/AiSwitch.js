'use strict';

/*
 * The computer's switches and items on Gold / Silver / Crystal: the cart's
 * AI_SwitchOrTryItem (engine/battle/ai/items.asm), CheckAbleToSwitch and its
 * helpers (engine/battle/ai/switch.asm) and FindMonInOTPartyToSwitchIntoBattle
 * (engine/battle/core.asm), as a pure module over the referee's battle state
 * (contract K16 of docs/plans/gen12-referee-remaining-gaps.md).
 *
 * Node twin of src/BattleSim2/AiSwitch.lua, line for line; the Lua header
 * carries the reasoning, every pokecrystal / pokegold citation, the quirks
 * reproduced (the AI's false assumption about CheckTypeMatchup, the
 * base-reward bug, the three AI_HealStatus bugs, the quarter-HP `srl c / rl b`,
 * `e` never cleared, Gold's wOTPartyCount walks and `.loop5` bound, RaiseStat's
 * stale wAttackMissed) and the fields the hook maintains (trainerItems,
 * baseReward, itemSwitch, aiMove, turnsTaken, usedMoves, countSpeciesTypes,
 * lastAttackMissed / lastEffectFailed). Arrays here are 0-based where the Lua
 * twin's are 1-based; party indices, `trainerSlot` and `fighter.active` are
 * 1-based in both.
 *
 * Draws come off `battle.rng` (`.byte()`) in the cart's order. Nothing here
 * holds state.
 */

const Effects = require('./Effects.js');

function int(value, fallback) {
  if (value === null || value === undefined || typeof value === 'boolean') return fallback;
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.floor(n);
}

// ------------------------------------------------------------------
// the cart's constants
// ------------------------------------------------------------------

const BASE_AI_SWITCH_SCORE = 10;
const EFFECTIVE = 10;
const SUPER_EFFECTIVE = 11;
const PARTY_LENGTH = 6;
const NUM_MOVES = 4;

const SWITCH_OFTEN = 0x01;
const SWITCH_RARELY = 0x02;
const SWITCH_SOMETIMES = 0x04;
const ALWAYS_USE = 0x10;
const UNKNOWN_USE = 0x20;
const CONTEXT_USE = 0x40;

const PERCENT_4 = 10;
const PERCENT_8 = 20;
const PERCENT_12 = 30;
const PERCENT_20_MINUS_1 = 50;
const PERCENT_50_PLUS_1 = 128;
const PERCENT_79_MINUS_1 = 200;

const SWITCH_ODDS = {
  often: [PERCENT_50_PLUS_1, PERCENT_79_MINUS_1, PERCENT_4],
  rarely: [PERCENT_8, PERCENT_12, PERCENT_79_MINUS_1],
  sometimes: [PERCENT_20_MINUS_1, PERCENT_50_PLUS_1, PERCENT_20_MINUS_1],
};

const TOXIC_CONTEXT_COUNT = 4;

const REDRAW_LIMIT = 1024;

const AI_ITEMS = [
  { id: 'FULL_RESTORE', num: 0x0e, routine: 'fullRestore', use: 'fullRestore' },
  { id: 'MAX_POTION', num: 0x0f, routine: 'healItem', use: 'maxPotion' },
  { id: 'HYPER_POTION', num: 0x10, routine: 'healItem', use: 'potion', heal: 200 },
  { id: 'SUPER_POTION', num: 0x11, routine: 'healItem', use: 'potion', heal: 50 },
  { id: 'POTION', num: 0x12, routine: 'healItem', use: 'potion', heal: 20 },
  { id: 'X_ACCURACY', num: 0x21, routine: 'xItem', use: 'flag', flag: 'xAccuracy' },
  { id: 'FULL_HEAL', num: 0x26, routine: 'status', use: 'fullHeal' },
  { id: 'GUARD_SPEC', num: 0x29, routine: 'xItem', use: 'flag', flag: 'mist' },
  { id: 'DIRE_HIT', num: 0x2c, routine: 'xItem', use: 'flag', flag: 'focusEnergy' },
  { id: 'X_ATTACK', num: 0x31, routine: 'xItem', use: 'stat', stat: 'atk' },
  { id: 'X_DEFEND', num: 0x33, routine: 'xItem', use: 'stat', stat: 'def' },
  { id: 'X_SPEED', num: 0x34, routine: 'xItem', use: 'stat', stat: 'spe' },
  { id: 'X_SPECIAL', num: 0x35, routine: 'xItem', use: 'stat', stat: 'spa' },
];

const BY_ID = {};
for (const entry of AI_ITEMS) BY_ID[entry.id] = entry;

const NOT_LISTED = 256;
function itemByte(value) {
  if (value === null || value === undefined || value === false || value === '' || value === 'NO_ITEM') return 0;
  if (typeof value === 'number') return ((int(value, 0) % 256) + 256) % 256;
  if (typeof value === 'string') {
    const entry = Object.prototype.hasOwnProperty.call(BY_ID, value) ? BY_ID[value] : null;
    return entry ? entry.num : NOT_LISTED;
  }
  return NOT_LISTED;
}

const LINK_MODES = { '1v1': true, coop_pvp: true };
const PLAYER_SIDE = 'a';

// ------------------------------------------------------------------
// byte arithmetic
// ------------------------------------------------------------------

function hasBit(value, bitValue) {
  return Math.floor(value / bitValue) % 2 === 1;
}

function setBit(value, bitValue) {
  if (hasBit(value, bitValue)) return value;
  return value + bitValue;
}

function clearBit(value, bitValue) {
  if (hasBit(value, bitValue)) return value - bitValue;
  return value;
}

function band(a, b) {
  return a & b & 0xff;
}

// `sla`: [the byte shifted left, the carry].
function sla(value) {
  return [(value * 2) % 256, value >= 128];
}

function slotOfHighest(mask) {
  let value = (mask * 4) % 256;
  let slot = -1;
  let carry = false;
  do {
    slot += 1;
    [value, carry] = sla(value);
  } while (!(carry || slot > 7));
  return slot;
}

// ------------------------------------------------------------------
// reading the referee
// ------------------------------------------------------------------

function activeMon(fighter) {
  if (!fighter || !fighter.active) return null;
  const mon = fighter.mons[fighter.active - 1];
  if (mon && (mon.hp > 0 || mon.standing)) return mon;
  return null;
}

function hpOf(mon) {
  if (!mon || typeof mon !== 'object') return 0;
  return Math.max(0, int(mon.hp, 0));
}

function powerOf(move) {
  if (!move || typeof move !== 'object') return 0;
  return Math.max(0, int(move.power, 0));
}

function typeIndexOf(battle, id) {
  const ids = battle.typeIds;
  if (!Array.isArray(ids) || typeof id !== 'string') return null;
  for (let i = 0; i < ids.length; i += 1) {
    if (ids[i] === id) return i;
  }
  return null;
}

function moveTypeOf(battle, move) {
  if (!move || typeof move !== 'object') return null;
  if (typeof move.typeId === 'string') {
    const index = typeIndexOf(battle, move.typeId);
    if (index !== null) return index;
  }
  return Math.max(0, int(move.type, 0));
}

function typePair(types) {
  if (!Array.isArray(types)) return [0, 0];
  const t1 = Math.max(0, int(types[0], 0));
  const t2 = (types[1] !== undefined && types[1] !== null) ? Math.max(0, int(types[1], t1)) : t1;
  return [t1, t2];
}

function baseTypes(mon) {
  if (!mon || typeof mon !== 'object') return null;
  return mon.homeTypes || mon.types;
}

function typeMatchup(battle, attackType, types, identified) {
  const [t1, t2] = typePair(types);
  const defender = { identified: identified === true };
  let value = EFFECTIVE;
  value = Math.floor(value * battle._matchupCell(attackType, t1, defender) / 100) % 256;
  if (t2 !== t1) {
    value = Math.floor(value * battle._matchupCell(attackType, t2, defender) / 100) % 256;
  }
  return value;
}

const STRUGGLE_ROW = { id: 'STRUGGLE', power: 50, type: 0, typeId: 'NORMAL' };

function structMoveType(battle, fighter, mon) {
  let move = fighter.aiMove;
  if (!move || typeof move !== 'object') {
    move = null;
    const choice = fighter.choice;
    if (choice && typeof choice === 'object' && choice.action === 'fight' && mon) {
      if (choice.struggle) {
        move = STRUGGLE_ROW;
      } else {
        move = mon.moves[int(choice.move, 0) - 1];
      }
    }
  }
  const index = moveTypeOf(battle, move);
  if (index !== null) return index;
  const normal = typeIndexOf(battle, 'NORMAL');
  return normal !== null ? normal : 0;
}

function viewOf(battle, fighter, foe) {
  const mon = activeMon(fighter);
  const foeMon = foe ? activeMon(foe) : null;
  const view = {
    battle,
    fighter,
    mons: fighter.mons,
    count: Math.min(fighter.mons.length, PARTY_LENGTH),
    cur: fighter.active,
    mon,
    foeMon,
    gold: battle.family !== 'crystal',
    identified: foeMon !== null && foeMon.identified === true,
    flags: Math.max(0, int(fighter.itemSwitch, 0)) % 256,
    score: 0,
    param: 0,
  };
  view.moveType = structMoveType(battle, fighter, mon);
  return view;
}

function aiMatchup(view, types) {
  return typeMatchup(view.battle, view.moveType, types, view.identified);
}

function foeTypes(view) {
  return view.foeMon ? view.foeMon.types : [];
}

function draw(view) {
  return view.battle.rng.byte();
}

// ------------------------------------------------------------------
// switch.asm
// ------------------------------------------------------------------

function usedMoveRow(foeMon, entry) {
  if (entry === null || entry === undefined || entry === false) return null;
  if (typeof entry === 'object') return entry;
  const key = Effects.moveKey(entry);
  if (key === '') return null;
  const moves = (foeMon && Array.isArray(foeMon.moves)) ? foeMon.moves : [];
  for (const row of moves) {
    if (row && typeof row === 'object' && Effects.moveKey(row) === key) return row;
  }
  return { id: key, power: 0, type: 0 };
}

function checkPlayerMoveTypeMatchups(view) {
  let score = BASE_AI_SWITCH_SCORE;
  const used = (view.foeMon && Array.isArray(view.foeMon.usedMoves))
    ? view.foeMon.usedMoves : [];
  const selfTypes = view.mon ? view.mon.types : [];
  if (!usedMoveRow(view.foeMon, used[0])) {
    const [t1, t2] = typePair(foeTypes(view));
    if (aiMatchup(view, selfTypes) >= SUPER_EFFECTIVE) score -= 1;
    if (t2 !== t1 && aiMatchup(view, selfTypes) >= SUPER_EFFECTIVE) {
      score -= 1;
    }
  } else {
    let e = 0;
    let broke = false;
    for (let i = 0; i < NUM_MOVES; i += 1) {
      const move = usedMoveRow(view.foeMon, used[i]);
      if (!move) break;
      if (powerOf(move) > 0) {
        const matchup = aiMatchup(view, selfTypes);
        if (matchup >= SUPER_EFFECTIVE) {
          score -= 1;
          broke = true;
          break;
        } else if (matchup === 0) {
          // immune: `.next`
        } else if (matchup >= EFFECTIVE) {
          e = 2;
        } else if (e < 1) {
          e = 1;
        }
      }
    }
    if (!broke && e !== 2) {
      score += 1;
      if (e === 0) score += 1;
    }
  }
  let c = 0;
  const moves = view.mon ? view.mon.moves : [];
  for (let i = 0; i < NUM_MOVES; i += 1) {
    const move = moves[i];
    if (!move) break;
    if (powerOf(move) > 0) {
      const matchup = aiMatchup(view, foeTypes(view));
      if (matchup !== 0) {
        c += 1;
        if (matchup >= EFFECTIVE) {
          c += 5;
          if (matchup !== EFFECTIVE) c = 100;
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
  view.score = ((score % 256) + 256) % 256;
  return view.score;
}

function findAliveEnemyMons(view) {
  if (view.count < 2) return [0, true];
  let b = 0x20;
  let c = 0;
  for (let slot = 1; slot <= view.count; slot += 1) {
    if (slot !== view.cur && hpOf(view.mons[slot - 1]) > 0) c = setBit(c, b);
    b = Math.floor(b / 2);
  }
  return [c, c === 0];
}

function findEnemyMonsImmuneToLastCounterMove(view) {
  let mask = 0;
  let c = 0x20;
  const last = view.foeMon ? view.foeMon.lastCounterMove : null;
  for (let slot = 1; slot <= view.count; slot += 1) {
    const mon = view.mons[slot - 1];
    if (slot !== view.cur && hpOf(mon) > 0 && powerOf(last) > 0
        && aiMatchup(view, baseTypes(mon)) === 0) {
      mask = setBit(mask, c);
    }
    c = Math.floor(c / 2);
  }
  view.score = mask;
  return mask;
}

function findEnemyMonsWithASuperEffectiveMove(view, c) {
  view.score = 0xff;
  let b = 0x20;
  let d = 0;
  let e = 0;
  let hit = null;
  for (let slot = 1; slot <= PARTY_LENGTH; slot += 1) {
    if (band(b, c) !== 0) {
      const mon = view.mons[slot - 1];
      const moves = (mon && typeof mon === 'object' && mon.moves) || [];
      for (let k = 0; k < NUM_MOVES; k += 1) {
        const move = moves[k];
        if (!move) break;
        if (powerOf(move) > 0) {
          const matchup = aiMatchup(view, foeTypes(view));
          if (matchup >= EFFECTIVE) {
            e = 1;
            if (matchup >= SUPER_EFFECTIVE) {
              e = 2;
              break;
            }
          }
        }
      }
      if (e === 2) {
        hit = b;
        break;
      }
      if (e === 1) d = setBit(d, b);
    }
    b = Math.floor(b / 2);
  }
  if (hit === null) {
    if (d === 0) return e;
    hit = d;
  }
  view.score = slotOfHighest(hit);
  return e;
}

function findAliveEnemyMonsWithASuperEffectiveMove(view, c) {
  let alive = 0;
  let b = 0x20;
  for (let slot = 1; slot <= view.count; slot += 1) {
    if (hpOf(view.mons[slot - 1]) > 0) alive = setBit(alive, b);
    b = Math.floor(b / 2);
  }
  return findEnemyMonsWithASuperEffectiveMove(view, band(alive, c));
}

function resistTypes(view, i) {
  if (!view.gold) return baseTypes(view.mons[i]);
  if (i === 0) {
    const stated = view.fighter.countSpeciesTypes;
    if (Array.isArray(stated)) return stated;
    return baseTypes(view.mons[0]);
  }
  return baseTypes(view.mons[i - 1]);
}

function findEnemyMonsThatResistPlayer(view, c) {
  let b = 0x20;
  let out = 0;
  const iterations = view.gold ? view.count + 1 : view.count;
  for (let i = 0; i <= iterations - 1; i += 1) {
    // (Gold's seventh pass, at six, has shifted its bit away: `b` is 0.)
    if (b > 0 && aiMatchup(view, resistTypes(view, i)) < SUPER_EFFECTIVE) {
      out = setBit(out, b);
    }
    b = Math.floor(b / 2);
  }
  return band(out, c);
}

function quarterValue(hp) {
  hp = Math.max(0, int(hp, 0)) % 65536;
  const hi = Math.floor(hp / 256);
  const lo = hp % 256;
  const c1 = Math.floor(lo / 2);
  const b1 = (hi * 2 + lo % 2) % 256;
  const c2 = Math.floor(c1 / 2);
  const b2 = (b1 * 2 + c1 % 2) % 256;
  return b2 * 256 + c2;
}

function findEnemyMonsWithAtLeastQuarterMaxHP(view, c) {
  let b = 0x20;
  let out = 0;
  const iterations = view.gold ? view.count + 1 : view.count;
  for (let i = 1; i <= iterations; i += 1) {
    const mon = view.mons[i - 1];
    const maxHp = (mon && typeof mon === 'object') ? Math.max(0, int(mon.maxHp, 0)) : 0;
    if (b > 0 && quarterValue(hpOf(mon)) > maxHp) out = setBit(out, b);
    b = Math.floor(b / 2);
  }
  return band(out, c);
}

function benchChain(view) {
  let [c] = findAliveEnemyMons(view);
  c = findEnemyMonsWithAtLeastQuarterMaxHP(view, c);
  c = findEnemyMonsThatResistPlayer(view, c);
  return findAliveEnemyMonsWithASuperEffectiveMove(view, c);
}

function checkAbleToSwitch(view) {
  view.param = 0;
  const [, only] = findAliveEnemyMons(view);
  if (only) return 0;

  const mon = view.mon;
  if (mon && mon.perish !== null && mon.perish !== undefined && int(mon.perish, 0) === 1) {
    const e = benchChain(view);
    if (e === 2) {
      view.param = (view.score + 0x30) % 256;
      return view.param;
    }
    const [c] = findAliveEnemyMons(view);
    view.param = 0x30 + slotOfHighest(c);
    return view.param;
  }

  checkPlayerMoveTypeMatchups(view);
  if (view.score >= SUPER_EFFECTIVE) return 0;

  const last = view.foeMon ? view.foeMon.lastCounterMove : null;
  if (last) {
    findEnemyMonsImmuneToLastCounterMove(view);
    if (view.score !== 0) {
      const e = findEnemyMonsWithASuperEffectiveMove(view, view.score);
      if (view.score === 0xff) return 0;
      const b = view.score;
      if (e === 2) {
        let c = 0x10;
        checkPlayerMoveTypeMatchups(view);
        if (view.score < BASE_AI_SWITCH_SCORE) c = 0x20;
        view.param = (b + c) % 256;
        return view.param;
      }
      checkPlayerMoveTypeMatchups(view);
      if (view.score >= BASE_AI_SWITCH_SCORE) return 0;
      view.param = (b + 0x10) % 256;
      return view.param;
    }
  }

  checkPlayerMoveTypeMatchups(view);
  if (view.score >= BASE_AI_SWITCH_SCORE) return 0;
  const e = benchChain(view);
  if (e !== 2) return 0;
  view.param = (view.score + 0x10) % 256;
  return view.param;
}

// ------------------------------------------------------------------
// items.asm: the decision
// ------------------------------------------------------------------

function aboveHalf(mon) {
  return Math.max(0, int(mon.maxHp, 0)) < (hpOf(mon) * 2) % 65536;
}

function aboveQuarter(mon) {
  return Math.max(0, int(mon.maxHp, 0)) < (hpOf(mon) * 4) % 65536;
}

function toxicBit(mon) {
  return mon.status === 'toxic' || mon.toxicLatent === true;
}

function toxicCount(mon) {
  return Math.max(0, int(mon.toxicCounter, 1) - 1);
}

const ROUTINES = {};

ROUTINES.status = (view) => {
  const mon = view.mon;
  if (!mon.status) return false;
  if (hasBit(view.flags, CONTEXT_USE)) {
    if (toxicBit(mon) && toxicCount(mon) >= TOXIC_CONTEXT_COUNT) {
      if (draw(view) < PERCENT_50_PLUS_1) return true;
    }
    return mon.status === 'freeze' || mon.status === 'sleep';
  }
  if (hasBit(view.flags, ALWAYS_USE)) return true;
  return draw(view) < PERCENT_20_MINUS_1;
};

ROUTINES.healItem = (view) => {
  const mon = view.mon;
  if (hasBit(view.flags, CONTEXT_USE)) {
    if (aboveHalf(mon)) return false;
    if (!aboveQuarter(mon)) return true;
    return draw(view) < PERCENT_20_MINUS_1;
  }
  if (aboveHalf(mon)) return false;
  if (hasBit(view.flags, UNKNOWN_USE)) {
    if (aboveQuarter(mon)) return false;
    return draw(view) >= PERCENT_20_MINUS_1;
  }
  if (!aboveQuarter(mon)) return true;
  return draw(view) < PERCENT_50_PLUS_1;
};

ROUTINES.fullRestore = (view) => {
  if (ROUTINES.healItem(view)) return true;
  if (!hasBit(view.flags, CONTEXT_USE)) return false;
  return ROUTINES.status(view);
};

ROUTINES.xItem = (view) => {
  const turns = Math.max(0, int(view.mon.turnsTaken, 0));
  if (turns === 0) {
    if (hasBit(view.flags, ALWAYS_USE)) return true;
    if (draw(view) < PERCENT_50_PLUS_1) return false;
    if (hasBit(view.flags, CONTEXT_USE)) return true;
    if (draw(view) < PERCENT_50_PLUS_1) return false;
    return true;
  }
  if (!hasBit(view.flags, ALWAYS_USE)) return false;
  return draw(view) < PERCENT_20_MINUS_1;
};

function isHighestLevel(view) {
  let top = 0;
  for (let slot = 1; slot <= view.count; slot += 1) {
    const level = Math.max(0, int(view.mons[slot - 1].level, 0));
    if (level >= top) top = level;
  }
  const own = view.mons[view.cur - 1];
  return own !== undefined && own !== null && Math.max(0, int(own.level, 0)) >= top;
}

function tryItem(view) {
  const fighter = view.fighter;
  const items = Array.isArray(fighter.trainerItems) ? fighter.trainerItems : [];
  const bytes = [
    itemByte(items[0]), itemByte(items[1]),
    Math.max(0, int(fighter.baseReward, 0)) % 256, 0,
  ];
  if (bytes[0] === 0 && bytes[1] === 0) return null;
  if (!isHighestLevel(view)) return null;
  let de = 1;
  for (const entry of AI_ITEMS) {
    let has = false;
    if (bytes[de - 1] === entry.num) {
      has = true;
    } else {
      de += 1;
      if (bytes[de - 1] === entry.num) has = true; else de -= 1;
    }
    if (has && ROUTINES[entry.routine](view)) {
      return { action: 'item', item: entry.id, trainerSlot: de };
    }
  }
  return null;
}

function lockedIn(mon) {
  return mon.mustRecharge === true || (mon.charging !== null && mon.charging !== undefined)
    || (mon.bide !== null && mon.bide !== undefined)
    || (mon.thrashing !== null && mon.thrashing !== undefined && int(mon.thrashing.turns, 0) > 0)
    || (mon.rollout !== null && mon.rollout !== undefined && mon.rollout.active === true);
}

function canSwitch(view) {
  let alive = 0;
  for (let slot = 1; slot <= view.count; slot += 1) {
    if (hpOf(view.mons[slot - 1]) > 0) alive += 1;
  }
  return alive >= 2;
}

function switchOrTryItem(battle, fighter, foe) {
  if (!battle || typeof battle !== 'object' || !fighter || typeof fighter !== 'object') return null;
  if (Effects.isWildMode(battle.mode)) return null;
  if (LINK_MODES[battle.mode] || fighter.side === PLAYER_SIDE) return null;
  const mon = activeMon(fighter);
  if (!mon) return null;
  if (lockedIn(mon)) return null;

  const view = viewOf(battle, fighter, foe);
  const wrapped = mon.trapped !== null && mon.trapped !== undefined && int(mon.trapped.turns, 0) > 0;
  if (wrapped || battle._heldBy(fighter)) return tryItem(view);

  let odds;
  if (hasBit(view.flags, SWITCH_OFTEN)) {
    odds = SWITCH_ODDS.often;
  } else if (hasBit(view.flags, SWITCH_RARELY)) {
    odds = SWITCH_ODDS.rarely;
  } else if (hasBit(view.flags, SWITCH_SOMETIMES)) {
    odds = SWITCH_ODDS.sometimes;
  } else {
    return tryItem(view);
  }

  checkAbleToSwitch(view);
  const strength = Math.floor(view.param / 16);
  if (strength === 0) return tryItem(view);
  const byte = draw(view);
  let go;
  if (strength === 1) {
    go = byte < odds[0];
  } else if (strength === 2) {
    go = byte < odds[1];
  } else {
    go = byte >= odds[2];
  }
  if (!go) return tryItem(view);

  if (!canSwitch(view)) return null;
  return { action: 'switch', slot: view.param % 16 + 1 };
}

// ------------------------------------------------------------------
// items.asm: the effect
// ------------------------------------------------------------------

function itemName(id) {
  let label = id.replace(/_/g, ' ');
  if (label === 'GUARD SPEC') label = 'GUARD SPEC.';
  return label;
}

function usedOnLine(fighter, itemId, mon) {
  return `${fighter.name}\nused ${itemName(itemId)}\non ${mon.species}!`;
}

function withdrewLine(fighter, mon) {
  return `${fighter.name}\nwithdrew\n${mon.species}!`;
}

function healStatus(fighter, mon) {
  const had = mon.status !== null && mon.status !== undefined;
  Effects.setStatusOn(mon, fighter, null);
  mon.statusTurns = 0;
  mon.toxicLatent = null;
  return had;
}

function itemEvent(battle, fighter, id) {
  battle._emit('item', { slot: fighter.slot, side: fighter.side, text: id });
}

function recoveredEvent(battle, fighter, mon, confused) {
  const fields = { slot: fighter.slot, side: fighter.side, text: `${mon.species} recovered` };
  if (confused) fields.confused = 0;
  battle._emit('status', fields);
}

function useItem(battle, fighter, decision) {
  if (!battle || typeof battle !== 'object' || !fighter || typeof fighter !== 'object') return false;
  if (!decision || typeof decision !== 'object' || decision.action !== 'item') return false;
  const entry = Object.prototype.hasOwnProperty.call(BY_ID, decision.item) ? BY_ID[decision.item] : null;
  const mon = activeMon(fighter);
  if (!entry || !mon) return false;
  const line = usedOnLine(fighter, entry.id, mon);

  if (entry.use === 'fullHeal') {
    itemEvent(battle, fighter, entry.id);
    const had = healStatus(fighter, mon);
    battle._say(line);
    if (had) recoveredEvent(battle, fighter, mon, false);
  } else if (entry.use === 'fullRestore') {
    const had = healStatus(fighter, mon);
    const confused = int(mon.confusion, 0) > 0;
    mon.confusion = 0;
    battle._say(line);
    itemEvent(battle, fighter, entry.id);
    battle._heal(fighter, mon, mon.maxHp - mon.hp);
    if (had) recoveredEvent(battle, fighter, mon, false);
    if (confused) recoveredEvent(battle, fighter, mon, true);
  } else if (entry.use === 'maxPotion') {
    battle._say(line);
    itemEvent(battle, fighter, entry.id);
    battle._heal(fighter, mon, mon.maxHp - mon.hp);
  } else if (entry.use === 'potion') {
    battle._say(line);
    itemEvent(battle, fighter, entry.id);
    battle._heal(fighter, mon, entry.heal);
  } else if (entry.use === 'flag') {
    itemEvent(battle, fighter, entry.id);
    mon[entry.flag] = true;
    battle._say(line);
  } else if (entry.use === 'stat') {
    battle._say(line);
    itemEvent(battle, fighter, entry.id);
    if (!(battle.lastAttackMissed === true || battle.lastEffectFailed === true)) {
      const r = Effects.raiseStat(mon, fighter.badges, entry.stat, 1);
      if (r.raised) {
        battle._emit('stat', {
          slot: fighter.slot, side: fighter.side, amount: r.stage, stage: r.stage,
          text: Effects.statUpLine(mon, entry.stat, 1),
        });
      } else {
        battle.lastAttackMissed = true;
      }
    }
  }

  const slot = int(decision.trainerSlot, 0);
  if (slot === 1 || slot === 2) {
    if (!Array.isArray(fighter.trainerItems)) fighter.trainerItems = [];
    for (let i = 1; i <= slot - 1; i += 1) {
      if (fighter.trainerItems[i - 1] === undefined || fighter.trainerItems[i - 1] === null) {
        fighter.trainerItems[i - 1] = 'NO_ITEM';
      }
    }
    fighter.trainerItems[slot - 1] = 'NO_ITEM';
  } else if (slot === 3) {
    fighter.baseReward = 0;
  }
  mon.bide = null;
  mon.furyCutter = 0;
  mon.protectCount = 0;
  mon.rageCounter = 0;
  mon.raging = false;
  if (battle.family === 'crystal') mon.lastCounterMove = null;
  return true;
}

function recordUsedMove(mon, move) {
  if (!mon || typeof mon !== 'object' || !move || typeof move !== 'object') return;
  if (!Array.isArray(mon.usedMoves)) mon.usedMoves = [];
  const list = mon.usedMoves;
  const row = { id: move.id, power: move.power, type: move.type, typeId: move.typeId };
  for (let i = 0; i < NUM_MOVES; i += 1) {
    const seen = list[i];
    if (!seen) {
      list[i] = row;
      return;
    }
    if (seen.id === row.id) return;
  }
  [list[0], list[1], list[2], list[3]] = [list[1], list[2], list[3], row];
}

// ------------------------------------------------------------------
// core.asm: the successor after a faint
// ------------------------------------------------------------------

function replacement(battle, fighter, foe) {
  if (!battle || typeof battle !== 'object' || !fighter || typeof fighter !== 'object') return null;
  const mons = fighter.mons;
  const count = Math.min(mons.length, PARTY_LENGTH);
  const cur = fighter.active;
  const foeMon = foe ? activeMon(foe) : null;
  const playerTypes = foeMon ? foeMon.types : [];
  const [t1, t2] = typePair(playerTypes);
  const identified = foeMon !== null && foeMon.identified === true;
  const gold = battle.family !== 'crystal';

  let enemyEff = 1;
  let playerEff = 1;
  let playerMoveType = null;
  let b = -1;
  for (;;) {
    [enemyEff] = sla(enemyEff);
    [playerEff] = sla(playerEff);
    b += 1;
    if (b === count) break;
    const mon = mons[b];
    if (b + 1 === cur || hpOf(mon) === 0) {
      playerEff = setBit(playerEff, 1);
    } else {
      const moves = mon.moves || [];
      for (let k = 0; k < NUM_MOVES; k += 1) {
        const move = moves[k];
        if (!move) break;
        if (typeMatchup(battle, moveTypeOf(battle, move), playerTypes, identified)
            >= SUPER_EFFECTIVE) {
          enemyEff = setBit(enemyEff, 1);
          break;
        }
      }
      const home = baseTypes(mon);
      let superEffective = false;
      playerMoveType = t1;
      if (typeMatchup(battle, t1, home, false) >= SUPER_EFFECTIVE) {
        superEffective = true;
      } else {
        playerMoveType = t2;
        if (typeMatchup(battle, t2, home, false) >= SUPER_EFFECTIVE) {
          superEffective = true;
        }
      }
      if (superEffective) {
        if (hasBit(enemyEff, 1)) {
          enemyEff = clearBit(enemyEff, 1);
        } else {
          playerEff = setBit(playerEff, 1);
        }
      }
    }
  }

  let carry = false;
  do {
    [enemyEff] = sla(enemyEff);
    [playerEff, carry] = sla(playerEff);
  } while (!carry);

  let c = playerEff;
  let left = count;
  let allDiscouraged = false;
  for (;;) {
    let out;
    [c, out] = sla(c);
    if (!out) break;
    left -= 1;
    if (left === 0) {
      allDiscouraged = true;
      break;
    }
  }

  let pick = null;
  if (!allDiscouraged) {
    let value = (enemyEff !== 0) ? enemyEff : playerEff;
    let slot = -1;
    const want = enemyEff !== 0;
    let bitOut;
    do {
      slot += 1;
      [value, bitOut] = sla(value);
    } while (!(bitOut === want || slot > 7));
    pick = slot;
  } else {
    const limit = gold ? PARTY_LENGTH : count;
    for (let i = 0; i < REDRAW_LIMIT; i += 1) {
      const a = battle.rng.byte() % 8;
      if (a < limit && a + 1 !== cur && hpOf(mons[a]) > 0) {
        pick = a;
        break;
      }
    }
    if (pick === null) {
      for (let slot = 1; slot <= count; slot += 1) {
        if (slot !== cur && hpOf(mons[slot - 1]) > 0) {
          pick = slot - 1;
          break;
        }
      }
    }
  }
  if (pick === null) return null;
  return { action: 'switch', slot: pick + 1, playerMoveType };
}

module.exports = {
  BASE_AI_SWITCH_SCORE,
  EFFECTIVE,
  SUPER_EFFECTIVE,
  PARTY_LENGTH,
  NUM_MOVES,
  SWITCH_OFTEN,
  SWITCH_RARELY,
  SWITCH_SOMETIMES,
  ALWAYS_USE,
  UNKNOWN_USE,
  CONTEXT_USE,
  PERCENT_4,
  PERCENT_8,
  PERCENT_12,
  PERCENT_20_MINUS_1,
  PERCENT_50_PLUS_1,
  PERCENT_79_MINUS_1,
  SWITCH_ODDS,
  TOXIC_CONTEXT_COUNT,
  REDRAW_LIMIT,
  AI_ITEMS,
  itemByte,
  moveTypeOf,
  typeMatchup,
  viewOf,
  checkPlayerMoveTypeMatchups,
  findAliveEnemyMons,
  findEnemyMonsImmuneToLastCounterMove,
  findEnemyMonsWithASuperEffectiveMove,
  findAliveEnemyMonsWithASuperEffectiveMove,
  findEnemyMonsThatResistPlayer,
  quarterValue,
  findEnemyMonsWithAtLeastQuarterMaxHP,
  checkAbleToSwitch,
  tryItem,
  switchOrTryItem,
  usedOnLine,
  withdrewLine,
  useItem,
  recordUsedMove,
  replacement,
};
