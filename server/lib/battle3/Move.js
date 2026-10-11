'use strict';

/*
 * Gen 3 move resolution: from "this seat uses this move" to the last event.
 *
 * Node twin of src/BattleSim3/Move.lua, the port of engine
 * src/core/game3/battle/engine.lua (`resolveMove`, `run`, `canceller`
 * pokefirered/src/battle_util.c:1253, `Ctx:accuracyCheck`
 * battle_script_commands.c:1003, `charge_turn`, `ohko`, `try_bounce`,
 * `call_moves`, `move_end` battle_script_commands.c:4056, `forEachTarget`
 * :4308, `resolveTarget` battle_main.c:4024) and effects/hit.lua (`Hit.run`,
 * `hit_once`, `dealDamage` battle_script_commands.c:1744, `adjustDamage` :1577,
 * triple kick, beat up, spit up, present, rollout, fury cutter, drain, crash).
 *
 * This file also installs the battle's HELPER SURFACE -- the methods every
 * effect / ability / item behaviour talks to the field through (B.roll,
 * B.active, B.foes, B.say, B.heal, B.loseHp, B.inflict, ...). Turn.js owns the
 * machine and calls `Move.install(Battle)` once, before its own methods.
 *
 * Where this port follows pret rather than the engine, the Lua twin says so:
 * absorb abilities act before the accuracy roll (attackcanceler), Future Sight
 * is a delayed attack even though it has power, Facade / Revenge /
 * SmellingSalt double, Struggle is not stopped by Wonder Guard, a cancelled
 * move clears the last *resulting* move too (Protect's streak). Disobedience
 * (`Bm._disobey`, engine.lua:1291) and the badge boosts (Damage.js base,
 * Field.js speed) follow the engine, for side a against the computer only
 * (Turn.BADGE_MODES): link rules everywhere else. The first battles (Oak's
 * accuracy and crit gates, Birch's crits), the Pokemon Tower GHOST (the
 * canceller) and the tutorials (`tutorial`: the old man's and Wally's crits;
 * the POKe DUDE's crits, accuracy and obedience) follow pret.
 *
 * Multi-value returns as arrays: canInflict -> [ok, reason] (Status.canApply),
 * _adjustDamage -> [dmg, how], _actionMove -> [row, slot, why], and the local
 * hitOnce -> [dmg, info, status]. `moveLimitations` returns an object keyed by
 * the 1-based move slot (`bad[slot] === true`), exactly the Lua table.
 *
 * Nothing here throws.
 */

const Types = require('./Types.js');
const Damage = require('./Damage.js');
const Accuracy = require('./Accuracy.js');
const Crit = require('./Crit.js');
const Status = require('./Status.js');
const Abilities = require('./Abilities.js');
const Items = require('./Items.js');
const Field = require('./Field.js');
const Effects = require('./Effects.js');
const {
  int, truthy, isTable, mod, at,
} = require('./lua.js');

const M = {};

const { E } = Effects;

// pokefirered/include/constants/battle.h MOVE_TARGET_*
M.TARGET = {
  SELECTED: 0,
  DEPENDS: 1,
  USER_OR_SELECTED: 2,
  RANDOM: 4,
  BOTH: 8,
  USER: 16,
  FOES_AND_ALLY: 32,
  OPPONENTS_FIELD: 64,
};
const T = M.TARGET;

// pokefirered/include/constants/pokemon.h:238 FLAG_*
M.FLAG = {
  CONTACT: 1, PROTECT: 2, MAGIC_COAT: 4, SNATCH: 8, MIRROR_MOVE: 16, KINGS_ROCK: 32,
};
const F = M.FLAG;

// pret include/constants/moves.h, the ones this file branches on.
const MOVE = {
  FLY: 19,
  SURF: 57,
  DIG: 91,
  RAGE: 99,
  METRONOME: 118,
  MIRROR_MOVE: 119,
  SKY_ATTACK: 143,
  STRUGGLE: 165,
  SNORE: 173,
  CURSE: 174,
  SLEEP_TALK: 214,
  WHIRLPOOL: 250,
  UPROAR: 253,
  FOCUS_PUNCH: 264,
  ASSIST: 274,
  DIVE: 291,
  BOUNCE: 340,
};
M.MOVE = MOVE;

// The synthetic Struggle row (pret battle_moves.h MOVE_STRUGGLE; public facts).
M.STRUGGLE = {
  id: 'STRUGGLE',
  name: 'STRUGGLE',
  num: 165,
  power: 50,
  type: 0,
  accuracy: 100,
  pp: 1,
  maxPp: 1,
  effect: 48,
  chance: 0,
  target: 0,
  priority: 0,
  flags: 3,
};

const TWO_TURN = {
  [E.SKULL_BASH]: true,
  [E.RAZOR_WIND]: true,
  [E.SKY_ATTACK]: true,
  [E.SOLAR_BEAM]: true,
  [E.SEMI_INVULNERABLE]: true,
  [E.BIDE]: true,
};

// src/battle_message.c:1029 / battle_scripts_1.s:794 (our own words)
const CHARGE_TEXT = {
  [E.RAZOR_WIND]: ' whipped up a whirlwind!',
  [E.SOLAR_BEAM]: ' took in sunlight!',
  [E.SKULL_BASH]: ' lowered its head!',
  [E.SKY_ATTACK]: ' is glowing!',
};
const SEMI_TEXT = {
  [MOVE.FLY]: [' flew up high!', 'ON_AIR'],
  [MOVE.BOUNCE]: [' sprang up!', 'ON_AIR'],
  [MOVE.DIG]: [' dug a hole!', 'UNDERGROUND'],
  [MOVE.DIVE]: [' hid underwater!', 'UNDERWATER'],
};

// Type names for sentences (pret TYPE_* tokens, not ROM text).
const TYPE_LABEL = {
  0: 'NORMAL',
  1: 'FIGHTING',
  2: 'FLYING',
  3: 'POISON',
  4: 'GROUND',
  5: 'ROCK',
  6: 'BUG',
  7: 'GHOST',
  8: 'STEEL',
  9: '???',
  10: 'FIRE',
  11: 'WATER',
  12: 'GRASS',
  13: 'ELECTRIC',
  14: 'PSYCHIC',
  15: 'ICE',
  16: 'DRAGON',
  17: 'DARK',
};

function hasFlag(move, flag) {
  return mod(Math.floor(int(move ? move.flags : null, 0) / flag), 2) === 1;
}
M.hasFlag = hasFlag;

function isType(b, t) {
  return b != null && (b.type1 === t || b.type2 === t);
}

// ==================================================================
// the helper surface (installed on Battle)
// ==================================================================

const Bm = {};

Bm.roll = function roll(lo, hi) {
  return this.rng.roll(lo, hi);
};

// pret battler-id order: a1, b1, a2, b2, a3, b3 (only the seats that exist).
Bm.battlerOrder = function battlerOrder() {
  return this.order;
};

Bm.battlerCount = function battlerCount() {
  return this.fighters.length;
};

Bm.active = function active() {
  const out = [];
  for (const f of this.order) {
    const { b } = f;
    if (b && b.mon.hp > 0) out.push(b);
  }
  return out;
};

Bm.foes = function foes(b) {
  const out = [];
  for (const o of this.active()) {
    if (o.side !== b.side) out.push(o);
  }
  return out;
};

Bm.allies = function allies(b) {
  const out = [];
  for (const o of this.active()) {
    if (o.side === b.side && o !== b) out.push(o);
  }
  return out;
};

// The nearest standing ally seat (ties to the lower slot).
Bm.partner = function partner(b) {
  let best = null;
  let bestD = null;
  for (const o of this.allies(b)) {
    let d = o.slot - b.slot;
    if (d < 0) d = -d;
    if (bestD === null || d < bestD || (d === bestD && o.slot < best.slot)) {
      best = o;
      bestD = d;
    }
  }
  return best;
};

Bm.countStandingOnSide = function countStandingOnSide(side) {
  let n = 0;
  for (const o of this.active()) if (o.side === side) n += 1;
  return n;
};

Bm.sideState = function sideState(side) {
  return this.sides[side];
};

Bm.weather = function weather() {
  return Field.effective(this.field.weather, this.active());
};

Bm.uproarActive = function uproarActive() {
  for (const b of this.active()) {
    if (int(b.uproarTurns, 0) > 0) return b;
  }
  return null;
};

Bm.fieldSport = function fieldSport(key) {
  for (const b of this.active()) if (truthy(b[key])) return true;
  return false;
};

Bm.abilityOnField = function abilityOnField(name) {
  for (const b of this.active()) if (b.ability === name) return true;
  return false;
};

Bm.isWild = function isWild() {
  return typeof this.mode === 'string' && this.mode.includes('wild');
};

Bm.nameOf = function nameOf(b) {
  const species = (b && truthy(b.mon)) ? b.mon.species : null;
  return truthy(species) ? species : 'POKeMON';
};

Bm.abilityLabel = function abilityLabel(b) {
  return Abilities.label(b ? b.ability : b, b ? b.abilityName : b);
};

Bm.itemLabelOf = function itemLabelOf(id, name) {
  if (typeof name === 'string' && name !== '') return name;
  return `ITEM ${String(int(id, 0))}`;
};

Bm.itemLabel = function itemLabel(b) {
  return this.itemLabelOf(b ? b.mon.heldItem : b, b ? b.mon.itemName : b);
};

Bm.moveLabel = function moveLabel(mv) {
  if (!isTable(mv)) return 'MOVE';
  if (typeof mv.name === 'string' && mv.name !== '') return mv.name;
  if (typeof mv.id === 'string' && mv.id !== '') return mv.id.replace(/_/g, ' ');
  return 'MOVE';
};

Bm.moveLabelByNum = function moveLabelByNum(num) {
  const row = this.moveRowByNum(num);
  return truthy(row) ? this.moveLabel(row) : 'MOVE';
};

Bm.typeLabel = function typeLabel(t) {
  const label = TYPE_LABEL[int(t, 0)];
  return label !== undefined ? label : '???';
};

Bm.say = function say(text) {
  if (typeof text !== 'string' || text === '') return undefined;
  return this._emit('msg', { text });
};

Bm.emit = function emit(kind, fields) {
  return this._emit(kind, fields);
};

Bm.emitAbility = function emitAbility(b) {
  if (!truthy(b) || !truthy(b.ability)) return undefined;
  return this._emit('ability', {
    slot: b.slot, side: b.side, amount: Abilities.idOf(b.ability), text: this.abilityLabel(b),
  });
};

// HP moves in exactly one of these three places, so every change is an event.
Bm.heal = function heal(b, amountIn) {
  const amount = Math.max(0, int(amountIn, 0));
  if (amount <= 0 || !truthy(b)) return 0;
  const before = b.mon.hp;
  b.mon.hp = Math.min(b.mon.maxHp, b.mon.hp + amount);
  const gained = b.mon.hp - before;
  if (gained > 0) {
    this._emit('drain', {
      slot: b.slot, side: b.side, amount: gained, hp: b.mon.hp,
    });
    if (b.side === 'b') this._lesson('damage');
  }
  return gained;
};

Bm.loseHp = function loseHp(b, amountIn, opts) {
  let amount = Math.max(0, int(amountIn, 0));
  if (!truthy(b)) return 0;
  if (amount > b.mon.hp) amount = b.mon.hp;
  b.mon.hp -= amount;
  this._emit('damage', {
    slot: b.slot,
    side: b.side,
    amount,
    hp: b.mon.hp,
    status: (truthy(opts) && truthy(opts.status)) ? opts.status : null,
  });
  // Oak's flag 1: the foe's HP bar finishing ANY update (pokefirered/src/
  // battle_controller_opponent.c:304), a 0 one too; a doll's damage moves no bar.
  if (b.side === 'b') this._lesson('damage');
  return amount;
};

Bm.setHp = function setHp(b, valueIn) {
  const value = Math.max(0, Math.min(b.mon.maxHp, int(valueIn, 0)));
  if (value > b.mon.hp) {
    this.heal(b, value - b.mon.hp);
  } else if (value < b.mon.hp) {
    this.loseHp(b, b.mon.hp - value);
  }
};

// -> [ok, reason] (Status.canApply's two values).
Bm.canInflict = function canInflict(b, status, optsIn) {
  const opts = truthy(optsIn) ? optsIn : {};
  return Status.canApply(b, status, {
    sun: this.weather() === 'SUN',
    uproar: this.uproarActive() != null,
    safeguard: int(this.sides[b.side].safeguardTurns, 0) > 0,
    ignoreSafeguard: opts.ignoreSafeguard,
  });
};

// Set a major status (adapter applyStatus, battle_script_commands.c:2356).
// opts: turns (sleep counter), text (the sentence; default ours), silent (no
// sentence), source.
Bm.inflict = function inflict(b, statusIn, optsIn) {
  const opts = truthy(optsIn) ? optsIn : {};
  const status = Status.normalise(statusIn);
  if (!truthy(b) || !truthy(status)) return false;
  b.mon.status = status;
  if (status === 'TOX') b.toxicCounter = 0;
  if (status === 'SLP') {
    const turns = int(opts.turns, null);
    b.mon.sleepTurns = turns !== null ? turns : Status.sleepTurns(this.rng);
    this.cancelMultiTurn(b);
  } else if (status === 'FRZ') {
    this.cancelMultiTurn(b);
  }
  let text;
  if (truthy(opts.text)) {
    ({ text } = opts);
  } else {
    const tail = Status.INFLICT_TEXT[status];
    text = this.nameOf(b) + (truthy(tail) ? tail : ' is afflicted!');
  }
  this._emit('status', {
    slot: b.slot, side: b.side, status, text,
  });
  if (!truthy(opts.silent)) this.say(text);
  return true;
};

// Clear the major status. `text` null clears silently (the event still goes).
Bm.cure = function cure(b, text) {
  if (!truthy(b) || !truthy(Status.normalise(b.mon.status))) return false;
  delete b.mon.status;
  delete b.mon.sleepTurns;
  delete b.toxicCounter;
  this._emit('status', { slot: b.slot, side: b.side, text });
  if (truthy(text)) this.say(text);
  return true;
};

// pokefirered/src/battle_util.c:203 CancelMultiTurnMoves
Bm.cancelMultiTurn = function cancelMultiTurn(b) {
  if (!truthy(b)) return;
  delete b.lockedNum;
  delete b.lockedSlot;
  delete b.lockedTarget;
  delete b.rampageTurns;
  delete b.uproarTurns;
  delete b.bideTurns;
  delete b.twoTurnNum;
  delete b.twoTurnTarget;
  delete b.semi;
  delete b.rolloutTimer;
  delete b.furyCutter;
};

// ------------------------------------------------------------------
// move rows
// ------------------------------------------------------------------

Bm.copyMove = function copyMove(row) {
  if (!isTable(row)) return null;
  const out = {
    num: int(row.num, 0),
    pp: Math.max(0, int(row.pp, 0)),
    maxPp: Math.max(0, int(row.maxPp, int(row.pp, 0))),
    power: Math.max(0, int(row.power, 0)),
    accuracy: Math.max(0, int(row.accuracy, 0)),
    type: Math.max(0, int(row.type, 0)),
    effect: Math.max(0, int(row.effect, 0)),
    chance: Math.max(0, int(row.chance, 0)),
    target: Math.max(0, int(row.target, 0)),
    priority: int(row.priority, 0),
    flags: Math.max(0, int(row.flags, 0)),
  };
  // Lua `{ id = row.id, name = row.name }` leaves the key out when the value is nil.
  if (row.id != null) out.id = row.id;
  if (row.name != null) out.name = row.name;
  return out;
};

// The row a CALLED move resolves to (Nature Power's terrain move, Mirror Move,
// a locked move that was called): the caller's own list (overlay first), then
// the ruleset pool (the host's decoded move table -- pret reads gBattleMoves),
// then the caller's seat's party sheets (an Assist-called lock with no pool).
// Never another fighter's sheet: a row somebody else uploaded under a borrowed
// number (Swift carrying EFFECT_NATURE_POWER, a 255-power "Swift") can never
// become the caller's move.
Bm.calledRowByNum = function calledRowByNum(numIn, caller) {
  const num = int(numIn, 0);
  if (num === 0) return null;
  if (num === MOVE.STRUGGLE) return M.STRUGGLE;
  const scan = (list) => {
    const l = truthy(list) ? list : [];
    for (let i = 1; i <= l.length; i += 1) {
      if (int(l[i - 1].num, 0) === num) return l[i - 1];
    }
    return null;
  };
  let hit = truthy(caller) ? scan(caller.moves) : null;
  if (truthy(hit)) return hit;
  if (truthy(this.pool) && truthy(this.pool[num])) return this.pool[num];
  const mons = (truthy(caller) && truthy(caller.fighter) && truthy(caller.fighter.mons))
    ? caller.fighter.mons : [];
  for (const mon of mons) {
    hit = scan(mon.moves);
    if (truthy(hit)) return hit;
  }
  return null;
};

// A move row by number: the hint battler's list, every battler on the field,
// every party, then the ruleset pool.  Labels and look-ups only; a row that is
// going to be USED as a called move comes from `calledRowByNum`.
Bm.moveRowByNum = function moveRowByNum(numIn, hint) {
  const num = int(numIn, 0);
  if (num === 0) return null;
  if (num === MOVE.STRUGGLE) return M.STRUGGLE;
  const scan = (list) => {
    const l = truthy(list) ? list : [];
    for (let i = 1; i <= l.length; i += 1) {
      if (int(l[i - 1].num, 0) === num) return l[i - 1];
    }
    return null;
  };
  if (truthy(hint)) {
    let hit = scan(hint.moves);
    if (!truthy(hit)) hit = scan(truthy(hint.mon) ? hint.mon.moves : hint.mon);
    if (truthy(hit)) return hit;
  }
  for (const f of this.order) {
    if (truthy(f.b)) {
      const hit = scan(f.b.moves);
      if (truthy(hit)) return hit;
    }
    for (const mon of f.mons) {
      const hit = scan(mon.moves);
      if (truthy(hit)) return hit;
    }
  }
  if (truthy(this.pool) && truthy(this.pool[num])) return this.pool[num];
  return null;
};

Bm.slotOfNum = function slotOfNum(b, numIn) {
  const num = int(numIn, 0);
  if (num === 0 || !truthy(b)) return null;
  for (let i = 1; i <= b.moves.length; i += 1) {
    if (int(b.moves[i - 1].num, 0) === num) return i;
  }
  return null;
};

Bm.isTwoTurnNum = function isTwoTurnNum(num) {
  const row = this.moveRowByNum(num);
  return row != null && TWO_TURN[int(row.effect, -1)] === true;
};

// Transform / Mimic write into a battle-only copy of the move list.
Bm.overlayMoves = function overlayMoves(b) {
  if (truthy(b.overlay)) return;
  const copy = [];
  for (let i = 1; i <= b.moves.length; i += 1) copy[i - 1] = this.copyMove(b.moves[i - 1]);
  b.moves = copy;
  b.overlay = true;
};

// A `moves` event: `mon` when this is the party's real list, absent on an
// overlay (Transform / Mimic).
Bm.emitMovesOf = function emitMovesOf(b, real) {
  const list = [];
  for (let i = 1; i <= b.moves.length; i += 1) {
    const m = b.moves[i - 1];
    const row = this.copyMove(m);
    if (typeof row.id !== 'string' || row.id === '') row.id = 'MOVE';
    if (typeof m.name !== 'string' || m.name === '') delete row.name;
    list.push(row);
  }
  if (list.length === 0) return undefined;
  const fields = { slot: b.slot, side: b.side, moves: list };
  if (truthy(real) || !truthy(b.overlay)) fields.mon = b.partyIndex - 1;
  return this._emit('moves', fields);
};

// pokefirered/src/battle_util.c:361 CheckMoveLimitations: the slots this
// battler may NOT select, as { [slot]: true } over 1-based slots.  `ignorePP`
// is the ~MOVE_LIMITATION_PP mask Sleep Talk passes (battle_script_commands.c
// :7882): every limit but an empty slot's PP.
Bm.moveLimitations = function moveLimitations(b, ignorePP) {
  const bad = {};
  const [he] = Items.of(b);
  for (let i = 1; i <= b.moves.length; i += 1) {
    const mv = b.moves[i - 1];
    const n = int(mv.num, 0);
    if (n === 0 || (!truthy(ignorePP) && int(mv.pp, 0) <= 0)) bad[i] = true;
    if (truthy(b.disabledNum) && n === b.disabledNum) bad[i] = true;
    if (truthy(b.tormented) && n === b.lastMoveNum) bad[i] = true;
    if (int(b.tauntTurns, 0) > 0 && int(mv.power, 0) === 0) bad[i] = true;
    if (this.isImprisoned(b, n)) bad[i] = true;
    if (int(b.encoreTurns, 0) > 0 && truthy(b.encoreNum) && n !== b.encoreNum) bad[i] = true;
    if (he === Items.HOLD.CHOICE_BAND && truthy(b.choicedMove) && b.choicedMove !== n) bad[i] = true;
  }
  return bad;
};

Bm.hasUsableMove = function hasUsableMove(b) {
  const bad = this.moveLimitations(b);
  for (let i = 1; i <= b.moves.length; i += 1) {
    if (!truthy(bad[i])) return true;
  }
  return false;
};

// pokefirered/src/battle_util.c:427
Bm.isImprisoned = function isImprisoned(b, num) {
  if (!truthy(num) || num === 0) return false;
  for (const foe of this.foes(b)) {
    if (truthy(foe.imprison)) {
      for (let j = 1; j <= foe.moves.length; j += 1) {
        if (int(foe.moves[j - 1].num, 0) === num) return true;
      }
    }
  }
  return false;
};

// ------------------------------------------------------------------
// seats, switching, escape
// ------------------------------------------------------------------

// The seat that has party member `index` out, or null. A shared party (a side
// entry with `seats = 2`, Turn.create) fields two of its members, one per
// seat; every other fighter is its own one-seat list (`fighter.seats`).
Bm.fieldedSeat = function fieldedSeat(fighter, index) {
  if (index == null) return null;
  for (const seat of fighter.seats) {
    if (seat.active === index) return seat;
  }
  return null;
};

// Whether party member `index` is spoken for: out on one of the party's seats,
// or -- while choices are being filed -- the destination of a sibling seat's
// switch or replacement. The cart's party menu says "already in battle" for
// either battler's mon and "already selected" for the partner's pending one
// (pokefirered/src/party_menu.c:5934; engine.lua switchCandidates /
// replacementCandidates, both read monToSwitchIntoId). Once the turn
// resolves a filed switch has either happened or been dropped, so only the
// seats count then. A one-seat fighter only ever has its own active.
Bm.partyTaken = function partyTaken(fighter, index) {
  const filing = this.phase === 'choice' || this.phase === 'replace';
  for (const seat of fighter.seats) {
    if (seat.active === index) return true;
    const c = seat.choice;
    if (filing && seat !== fighter && c && c.action === 'switch' && c.slot === index) return true;
  }
  return false;
};

// Living bench party indices (1-based) of a seat, in party order: neither
// seat's active mon of a shared party, nor one its sibling has claimed
// (`partyTaken`; pret HasNoMonsToSwitch, battle_util.c, skips both battlers'
// party indices and the partner's monToSwitchIntoId).
Bm.benchOf = function benchOf(fighter) {
  const out = [];
  for (let i = 1; i <= fighter.mons.length; i += 1) {
    if (fighter.mons[i - 1].hp > 0 && !this.partyTaken(fighter, i)) out.push(i);
  }
  return out;
};

// Mean Look / Block / Spider Web, a partial trap, Ingrain.
Bm.isTrapped = function isTrapped(b) {
  return b.trappedBy != null || int(b.trapTurns, 0) > 0 || b.ingrain === true;
};

Bm.syncTeamsNow = function syncTeamsNow() {
  this._syncTeams();
};

// ==================================================================
// the move context
// ==================================================================

const Ctx = {};
M.Ctx = Ctx;

function newCtx(B, user, target, row, slot, opts) {
  const C = Object.create(Ctx);
  Object.assign(C, {
    B,
    user,
    target,
    move: row,
    mnum: int(row.num, 0),
    effect: int(row.effect, 0),
    slot,
    opts: truthy(opts) ? opts : {},
    moveType: int(row.type, 0),
    dmgMultiplier: 1,
    animTargetsHit: 0,
  });
  return C;
}
M.newCtx = newCtx;

Ctx.moveName = function moveName() {
  return this.B.moveLabel(this.move);
};

// pokefirered/src/battle_script_commands.c:1108 Cmd_attackstring
Ctx.attackString = function attackString() {
  if (truthy(this.printedUsed)) return;
  this.printedUsed = true;
  this.B.say(`${this.B.nameOf(this.user)} used ${this.moveName()}!`);
};

// pokefirered/src/battle_script_commands.c:1122 Cmd_ppreduce (Pressure costs one more)
Ctx.ppReduce = function ppReduce() {
  if (truthy(this.ppDone)) return;
  this.ppDone = true;
  if (truthy(this.noPP) || !truthy(this.slot)) return;
  const { B, user } = this;
  const mv = at(user.moves, this.slot);
  if (!truthy(mv)) return;
  let cost = 1;
  const ttype = int(this.move.target, 0);
  const { target } = this;
  if (truthy(B.double) && (ttype === T.FOES_AND_ALLY || ttype === T.BOTH || ttype === T.OPPONENTS_FIELD)) {
    for (const b of B.active()) {
      if (b !== user && b.ability === 'PRESSURE'
          && (ttype === T.FOES_AND_ALLY || b.side !== user.side)) {
        cost += 1;
      }
    }
  } else if (truthy(target) && target !== user && ttype !== T.USER && target.ability === 'PRESSURE') {
    cost = 2;
  }
  const before = int(mv.pp, 0);
  if (before > cost) mv.pp = before - cost; else mv.pp = 0;
  if (mv.pp !== before) B.emitMovesOf(user);
};

// pokefirered/src/battle_controller_player.c:2330 (one anim per target unless
// the move is a spread / depends move, whose later targets reuse the first)
Ctx.attackAnimation = function attackAnimation(amount) {
  const { B } = this;
  if (truthy(B.double) && this.animTargetsHit > 0) {
    const ttype = int(this.move.target, 0);
    if (ttype === T.BOTH || ttype === T.FOES_AND_ALLY || ttype === T.DEPENDS) return;
  }
  const { target } = this;
  B._emit('anim', {
    slot: this.user.slot,
    side: this.user.side,
    text: truthy(this.move.id) ? this.move.id : 'MOVE',
    amount,
    target: (truthy(target) && target !== this.user) ? target.slot : null,
    spread: truthy(this.spread) ? 1 : null,
  });
  this.animTargetsHit += 1;
};

Ctx.fail = function fail(text) {
  this.failed = true;
  this.B.say(truthy(text) ? text : 'But it failed!');
};

Ctx.isProtected = function isProtected() {
  const t = this.target;
  if (!truthy(t) || t === this.user || !truthy(t.protected)) return false;
  if (!hasFlag(this.move, F.PROTECT)) return false;
  if (this.mnum === MOVE.CURSE && !isType(this.user, Types.ID.GHOST)) return false;
  return true;
};

Ctx.lockOnActive = function lockOnActive() {
  const t = this.target;
  return t != null && int(t.lockedOnTurns, 0) > 0 && t.lockedOnBy === this.user;
};

// pokefirered/src/battle_script_commands.c:1003 Cmd_accuracycheck.
// mode "normal" | "noacc" | "lockon" (NO_ACC_CALC / NO_ACC_CALC_CHECK_LOCK_ON).
Ctx.accuracyCheck = function accuracyCheck(mode, printFail) {
  const { B, user, target } = this;
  const failMsg = (reason) => {
    this.missReason = reason;
    if (!truthy(printFail)) return;
    if (reason === 'protected') {
      B.say(`${B.nameOf(target)} protected itself!`);
    } else if (reason === 'fail') {
      this.failed = true;
      B.say('But it failed!');
    } else {
      B.say(`${B.nameOf(user)}'s attack missed!`);
    }
  };
  // pokefirered/src/battle_script_commands.c:1015: the TEACHY TV demos spare
  // every move of both sides the whole check -- NO_ACC_CALC, Protect and
  // semi-invulnerability included.
  if (B.tutorial === 'pokedude') return true;
  if (mode === 'noacc' || mode === 'lockon') {
    if (mode === 'lockon' && this.lockOnActive()) return true;
    if (truthy(target) && truthy(target.semi) && target !== user) {
      failMsg('fail');
      return false;
    }
    if (this.isProtected()) {
      failMsg('protected');
      return false;
    }
    return true;
  }
  // pokefirered/src/battle_script_commands.c:1007: Oak's lab spares the
  // player's moves the whole check until a lesson. pret reads
  // gBattleMoves[param].power before it resolves ACC_CURR_MOVE (0): MOVE_NONE's
  // power, 0, for every move script -- sure to hit until the `stat` lesson;
  // only Future Sight / Doom Desire read their own power and `damage`.
  if (B.firstBattle === 'oak' && user.side === 'a') {
    const power = truthy(this.opts.futureSight) ? int(this.move.power, 0) : 0;
    if ((power !== 0 && !truthy(B.lessons.damage)) || (power === 0 && !truthy(B.lessons.stat))) {
      return true;
    }
  }
  // pokefirered/src/battle_script_commands.c:896 JumpIfMoveAffectedByProtect
  if (this.isProtected()) {
    failMsg('protected');
    return false;
  }
  if (this.lockOnActive()) return true;
  const semi = (truthy(target) && target !== user) ? target.semi : null;
  if (semi === 'ON_AIR' && !truthy(this.ignoreOnAir)) {
    failMsg('miss');
    return false;
  }
  if (semi === 'UNDERGROUND' && !truthy(this.ignoreUnderground)) {
    failMsg('miss');
    return false;
  }
  if (semi === 'UNDERWATER' && !truthy(this.ignoreUnderwater)) {
    failMsg('miss');
    return false;
  }
  const weather = B.weather();
  const eff = this.effect;
  if ((weather === 'RAIN' && eff === E.THUNDER) || eff === E.ALWAYS_HIT || eff === E.VITAL_THROW) {
    return true;
  }
  let moveAcc = int(truthy(this.accOverride) ? this.accOverride : this.move.accuracy, 100);
  // Sheet contract: 0 never misses (every cart move with 0 is ALWAYS_HIT or
  // never reaches this check, so nothing on a cart changes).
  if (moveAcc <= 0) return true;
  if (weather === 'SUN' && eff === E.THUNDER) moveAcc = 50;
  const calc = Accuracy.forBattlers(moveAcc, user, target,
    Types.isPhysical(this.moveType, B.specialTypes), weather === 'SAND');
  const [hit] = Accuracy.hit(calc, B.roll(Accuracy.ROLL_MIN, Accuracy.ROLL_MAX));
  if (!hit) {
    failMsg('miss');
    return false;
  }
  return true;
};

// Faint announcements at the engine's points (battle_script_commands.c:2831).
Ctx.tryFaintTarget = function tryFaintTarget() {
  const { B, user, target } = this;
  if (!truthy(target) || target === user) return;
  if (target.mon.hp > 0 || truthy(target.faintAnnounced)) return;
  B._faintBattler(target);
  if (truthy(target.destinyBond) && user.side !== target.side && user.mon.hp > 0) {
    B.say(`${B.nameOf(target)} took its attacker down with it!`);
    B.loseHp(user, user.mon.hp);
    B._faintBattler(user);
  }
  // pokefirered/src/battle_script_commands.c:2894: a foe's Grudge, not
  // Struggle, and the PP of the slot the attacker CHOSE (chosenMovePositions:
  // Metronome's slot when Metronome called the KO).
  if (truthy(target.grudge) && truthy(this.chosenSlot) && user.side !== target.side && user.mon.hp > 0
      && this.mnum !== MOVE.STRUGGLE) {
    const mv = at(user.moves, this.chosenSlot);
    if (truthy(mv)) {
      mv.pp = 0;
      B.say(`${B.nameOf(user)}'s ${B.moveLabel(mv)} lost all its PP due to the GRUDGE!`);
      B.emitMovesOf(user);
    }
  }
};

Ctx.tryFaintUser = function tryFaintUser() {
  if (this.user.mon.hp <= 0 && !truthy(this.user.faintAnnounced)) {
    this.B._faintBattler(this.user);
  }
};

// ==================================================================
// target resolution (pokefirered/src/battle_main.c:4024, battle_util.c:3054)
// ==================================================================

// A uniform pick among living foes, drawn only when there are two or more.
Bm._randomFoe = function _randomFoe(user) {
  const foes = this.foes(user);
  if (foes.length === 0) return null;
  if (foes.length === 1) return foes[0];
  return foes[this.roll(0, foes.length - 1)];
};

function followMe(B, user) {
  const side = B.sides[user.side === 'a' ? 'b' : 'a'];
  const fm = side.followMe;
  if (truthy(fm) && fm.mon.hp > 0 && fm.fighter.b === fm) return fm;
  return null;
}

// A Ghost's CURSE: the cart's move menu offers it as MOVE_TARGET_SELECTED
// (pokefirered/src/battle_controller_player.c:444; engine ui.lua
// move_target_type) although its table target is USER. Read by number, as
// the cart does, and by the battler's type at the time.
function ghostCurse(b, row) {
  return row != null && int(row.num, 0) === MOVE.CURSE && isType(b, Types.ID.GHOST);
}

// The target kind a seat aims this row with: SELECTED for a Ghost's CURSE,
// else the row's own byte. The byte (USER for Curse) still rules everything
// the cart keys on gBattleMoves[].target: Follow Me, Lightning Rod, Pressure.
Bm.aimTarget = function aimTarget(b, row) {
  if (ghostCurse(b, row)) return T.SELECTED;
  return int(row != null ? row.target : null, 0);
};

// Whether this row, used by this battler, is a Ghost's CURSE (the auto-pick
// files one unaimed, Turn.js `_autoFight`).
Bm.isGhostCurse = function isGhostCurse(b, row) {
  return ghostCurse(b, row);
};

// A chosen aim whose battler is gone (a stolen KO, a switch): the same seat's
// newcomer, else the nearest foe to that seat (a foe's), else the first foe.
Bm._reaim = function _reaim(user, t) {
  if (truthy(t) && (t.mon.hp <= 0 || t.fighter.b !== t)) {
    const now = t.fighter.b;
    if (truthy(now) && now.mon.hp > 0) return now;
    if (t.side !== user.side) return this._nearestFoe(user, t.slot);
    return this.foes(user)[0];
  }
  return t;
};

// The battler opposite this one (the engine adapter's foeOf, State.OPPOSITE:
// battler 0 faces 1, 2 faces 3): the foe seat in the same position if it
// stands, else the nearest standing foe to that position.
Bm.oppositeFoe = function oppositeFoe(b) {
  const other = (b.side === 'a') ? 'b' : 'a';
  return this._nearestFoe(b, this.bySide[other][0].slot + b.fighter.index - 1);
};

// The battler an action lands on. `aimed` is the chosen / stored target
// battler (or null); `random` true re-picks a SELECTED move's target at random
// (a called or Encored move); `called` marks a called move (GetMoveTarget).
Bm._pickTarget = function _pickTarget(user, row, aimed, random, called) {
  const ttype = int(row.target, 0);
  // A Ghost's CURSE: HandleAction_UseMove (pokefirered/src/battle_main.c:4024,
  // engine resolveTarget) keeps the chosen battler -- the table target is
  // USER, so Follow Me and Lightning Rod pass it by -- and an emptied aim
  // moves on as a SELECTED one does. Nothing aimed (a called or Encored Curse
  // recomputes GetMoveTarget, which for USER is the user): the user, and the
  // effect turns on the battler opposite (BattleScript_GhostCurse's
  // getmovetarget; engine setup.lua curse).
  if (ghostCurse(user, row)) {
    if (truthy(random) || truthy(called) || aimed == null) return user;
    return this._reaim(user, aimed);
  }
  if (ttype === T.USER) return user;
  // An active Follow Me takes every MOVE_TARGET_SELECTED move, even one aimed
  // at the ally (pokefirered/src/battle_main.c:4027 HandleAction_UseMove), and
  // a called move's random target too (battle_util.c:3054 GetMoveTarget's
  // MOVE_TARGET_RANDOM arm); a chosen random-target move (Thrash, Uproar) is
  // not pulled.
  const fm = followMe(this, user);
  if (truthy(fm) && (ttype === T.SELECTED || (truthy(called) && ttype === T.RANDOM))) {
    return fm;
  }
  if (ttype === T.RANDOM) {
    return this._randomFoe(user);
  }
  if (ttype === T.SELECTED || ttype === T.USER_OR_SELECTED) {
    let t = aimed;
    if (truthy(random) || t == null) t = this._randomFoe(user);
    t = this._reaim(user, t);
    // Lightning Rod (doubles, no Follow Me): the earliest-moving foe with it.
    if (truthy(t) && truthy(this.double) && int(row.type, -1) === Types.ID.ELECTRIC
        && t.ability !== 'LIGHTNING_ROD') {
      let best = null;
      let bestN = null;
      for (const o of this.foes(user)) {
        if (o !== t && o.ability === 'LIGHTNING_ROD') {
          const n = int(o.turnOrder, 99);
          if (bestN === null || n < bestN) {
            best = o;
            bestN = n;
          }
        }
      }
      if (truthy(best)) {
        best.lightningRodRedirected = true;
        return best;
      }
    }
    return t;
  }
  // DEPENDS / BOTH / FOES_AND_ALLY / OPPONENTS_FIELD: the first standing foe.
  return this.foes(user)[0];
};

// BattleSim2's stolen-KO rule: the nearest living foe to the emptied seat,
// ties to the lower slot.
Bm._nearestFoe = function _nearestFoe(user, slot) {
  let best = null;
  let bestD = null;
  for (const o of this.foes(user)) {
    let d = o.slot - slot;
    if (d < 0) d = -d;
    if (bestD === null || d < bestD || (d === bestD && o.slot < best.slot)) {
      best = o;
      bestD = d;
    }
  }
  return best;
};

// ==================================================================
// resolution
// ==================================================================

// pokefirered/src/battle_util.c:1253 AtkCanceller_UnableToUseMove.
// Returns true (go on), false (stopped) or "bide" (Bide releases).
function canceller(C) {
  const { B, user } = C;
  delete user.destinyBond;
  delete user.grudge;
  const nm = B.nameOf(user);

  if (Status.normalise(user.mon.status) === 'SLP') {
    if (truthy(B.uproarActive()) && user.ability !== 'SOUNDPROOF') {
      delete user.nightmare;
      B.cure(user, `${nm} woke up in the UPROAR!`);
    } else {
      let turns = int(user.mon.sleepTurns, 0);
      if (turns <= 0) turns = Status.sleepTurns(B.rng);
      const [left, woke] = Status.sleepTick(turns, user.ability === 'EARLY_BIRD');
      user.mon.sleepTurns = left;
      if (!woke) {
        if (C.mnum !== MOVE.SNORE && C.mnum !== MOVE.SLEEP_TALK) {
          B.say(`${nm} is fast asleep.`);
          return false;
        }
      } else {
        delete user.nightmare;
        B.cure(user, `${nm} woke up!`);
      }
    }
  }

  if (Status.normalise(user.mon.status) === 'FRZ') {
    if (B.roll(0, Status.THAW_ROLL_MAX) !== 0) {
      if (C.effect !== E.THAW_HIT) {
        B.say(`${nm} is frozen solid!`);
        return false;
      }
    } else {
      B.cure(user, `${nm} was defrosted!`);
    }
  }

  if (Abilities.truantLoafs(user)) {
    B.cancelMultiTurn(user);
    B.emitAbility(user);
    B.say(`${nm} is loafing around!`);
    user.unableToMove = true;
    return false;
  }

  if (truthy(user.mustRecharge)) {
    delete user.mustRecharge;
    delete user.rechargeTurns;
    B.cancelMultiTurn(user);
    B.say(`${nm} must recharge!`);
    return false;
  }

  if (truthy(user.flinched)) {
    delete user.flinched;
    B.cancelMultiTurn(user);
    B.say(`${nm} flinched!`);
    user.unableToMove = true;
    return false;
  }

  if (truthy(user.disabledNum) && C.mnum === user.disabledNum) {
    B.cancelMultiTurn(user);
    B.say(`${nm}'s ${C.moveName()} is disabled!`);
    user.unableToMove = true;
    return false;
  }

  if (int(user.tauntTurns, 0) > 0 && int(C.move.power, 0) === 0) {
    B.cancelMultiTurn(user);
    B.say(`${nm} can't use ${C.moveName()} after the TAUNT!`);
    user.unableToMove = true;
    return false;
  }

  if (B.isImprisoned(user, C.mnum)) {
    B.cancelMultiTurn(user);
    B.say(`${nm} can't use the sealed ${C.moveName()}!`);
    user.unableToMove = true;
    return false;
  }

  if (int(user.confusion, 0) > 0) {
    user.confusion -= 1;
    if (user.confusion > 0) {
      B.say(`${nm} is confused!`);
      if (B.roll(0, 1) === 0) {
        B.cancelMultiTurn(user);
        B._selfHit(C);
        user.unableToMove = true;
        return false;
      }
    } else {
      delete user.confusion;
      B.emit('status', {
        slot: user.slot,
        side: user.side,
        confused: 0,
        text: `${nm} snapped out of confusion!`,
      });
      B.say(`${nm} snapped out of confusion!`);
    }
  }

  if (Status.normalise(user.mon.status) === 'PAR' && B.roll(0, Status.PARALYSIS_ROLL_MAX) === 0) {
    B.say(`${nm} is paralyzed! It can't move!`);
    user.unableToMove = true;
    return false;
  }

  // pokefirered/src/battle_util.c:1451 CANCELLER_GHOST: a veiled GHOST cancels
  // every move of both sides -- no attack string, no PP, and neither
  // HITMARKER_UNABLE_TO_USE_MOVE nor a multi-turn cancel.
  if (B.ghost === 'veiled') {
    if (user.side === 'a') {
      B.say(`${nm} is too scared to move!`);
      B.emit('anim', { slot: user.slot, side: user.side, text: 'MON_SCARED' });
    } else {
      B.say('GHOST: Get out...... Get out......');
      B.emit('anim', { slot: user.slot, side: user.side, text: 'GHOST_GET_OUT' });
    }
    return false;
  }

  if (truthy(user.infatuatedWith)) {
    B.say(`${nm} is in love with ${B.nameOf(user.infatuatedWith)}!`);
    if (B.roll(0, 1) === 0) {
      B.cancelMultiTurn(user);
      B.say(`${nm} is immobilized by love!`);
      user.unableToMove = true;
      return false;
    }
  }

  if (int(user.bideTurns, 0) > 0) {
    user.bideTurns -= 1;
    if (user.bideTurns > 0) {
      B.say(`${nm} is storing energy!`);
      return false;
    }
    return 'bide';
  }

  if (Status.normalise(user.mon.status) === 'FRZ' && C.effect === E.THAW_HIT) {
    B.cure(user, `${nm} was defrosted by ${C.moveName()}!`);
  }
  return true;
}
M.canceller = canceller;

// pokefirered/data/battle_scripts_1.s:3741 (confusion self-hit)
Bm._selfHit = function _selfHit(C) {
  const { user } = C;
  let dmg = Damage.selfHitBase(user);
  const r = this.roll(Damage.ROLL_MIN, Damage.ROLL_MAX);
  dmg = Math.floor(dmg * r / 100);
  if (dmg === 0) dmg = 1;
  const banded = Items.rollFocusBand(this, user);
  let hung = null;
  if (int(user.substituteHP, 0) <= 0 && (truthy(user.enduring) || truthy(banded)) && dmg >= user.mon.hp) {
    dmg = user.mon.hp - 1;
    hung = truthy(user.enduring) ? 'endured' : 'band';
  }
  delete user.focusBanded;
  this.say('It hurt itself in its confusion!');
  this.loseHp(user, dmg);
  if (hung === 'endured') {
    this.say(`${this.nameOf(user)} endured the hit!`);
  } else if (hung === 'band') {
    Items.focusBandMessage(this, user);
  }
  C.tryFaintUser();
};

// ------------------------------------------------------------------
// obedience (pokefirered/src/battle_util.c:3143 IsMonDisobedient)
// ------------------------------------------------------------------

const SPECIES_MEW = 151;
const SPECIES_DEOXYS = 410;

// src/battle_message.c:1180 gInobedientStringIds, by MULTISTRING_CHOOSER
// (`Random() & 3`): B_MSG_LOAFING, B_MSG_WONT_OBEY, B_MSG_TURNED_AWAY,
// B_MSG_PRETEND_NOT_NOTICE -- the engine's LOAF_TEXT, in its order. Each pair is
// the `obey` event's token and our sentence's tail.
const LOAF_LINES = [
  ['loafing', ' is loafing around!'],
  ['wont_obey', " won't obey!"],
  ['turned_away', ' turned away!'],
  ['pretend_not_notice', ' pretended not to notice!'],
];
M.LOAF_LINES = LOAF_LINES;

// One disobedience outcome: the `obey` event (K3, docs/plans/gen3-battle-sheet.md
// §7.2), then our sentence.
Bm._obeyLine = function _obeyLine(b, token, tail) {
  this._emit('obey', { slot: b.slot, side: b.side, text: token });
  this.say(this.nameOf(b) + tail);
};

// engine.lua:1291 `disobedient` (pret IsMonDisobedient), asked by `run` after
// the PP check for a move not already locked in. Returns [null] (it obeys),
// ['stop'] (the action is spent) or ['called', slot] (that usable slot runs
// instead). Only for a fighter with `badgeRules` (side a against the computer),
// badges or none; the rest is the engine line for line, its draws in its order,
// each only when reached. The Mew / Deoxys rule fires only on `unfateful`
// (K2': the engine mon's `fatefulEncounter` is explicitly false, engine.lua:1299),
// so a sheet that says nothing obeys under the ordinary traded / cap rule. See
// the Lua twin for the prose.
Bm._disobey = function _disobey(C) {
  const { user } = C;
  // pokefirered/src/battle_util.c:3149: nothing disobeys in a TEACHY TV demo.
  if (this.tutorial === 'pokedude') return [null];
  if (!truthy(user.fighter.badgeRules)) return [null];
  const { mon } = user;
  // pret reads the party mon's species, which Transform leaves alone.
  const species = int(mon.speciesNum, 0);
  let ob = 0;
  if (!((species === SPECIES_MEW || species === SPECIES_DEOXYS) && mon.unfateful === true)) {
    // rules.obedience = false: pokeemerald/src/battle_util.c:3924 returns for
    // BATTLE_TYPE_FRONTIER inside the fateful arm.
    if (truthy(this.rules.noObedience)) return [null];
    if (mon.traded !== true || Damage.hasBadge(user, 8)) return [null];
    ob = 10;
    if (Damage.hasBadge(user, 2)) ob = 30;
    if (Damage.hasBadge(user, 4)) ob = 50;
    if (Damage.hasBadge(user, 6)) ob = 70;
  }
  const lvl = int(mon.level, 1);
  if (lvl <= ob) return [null];
  if (Math.floor((lvl + ob) * this.roll(0, 255) / 256) < ob) return [null];
  if (C.mnum === MOVE.RAGE) delete user.rage;
  if (Status.normalise(mon.status) === 'SLP' && (C.mnum === MOVE.SNORE || C.mnum === MOVE.SLEEP_TALK)) {
    // BattleScript_IgnoresWhileAsleep
    this._obeyLine(user, 'ignores_asleep', ' ignored orders while asleep!');
    return ['stop'];
  }
  const exempt = user.fighter.family !== 'rse';
  if (Math.floor((lvl + ob) * this.roll(0, 255) / 256) < ob
      && (C.mnum !== MOVE.FOCUS_PUNCH || !exempt)) {
    // CheckMoveLimitations over the four slots (an empty slot is unusable) plus
    // the chosen one (gBitTable[gCurrMovePos]).
    const bad = this.moveLimitations(user);
    for (let i = user.moves.length + 1; i <= 4; i += 1) bad[i] = true;
    if (truthy(C.slot)) bad[C.slot] = true;
    if (truthy(bad[1]) && truthy(bad[2]) && truthy(bad[3]) && truthy(bad[4])) {
      // BattleScript_MoveUsedLoafingAround
      const line = LOAF_LINES[mod(this.roll(0, 3), 4)];
      this._obeyLine(user, line[0], line[1]);
      return ['stop'];
    }
    let slot;
    do {
      slot = mod(this.roll(0, 3), 4) + 1;
    } while (truthy(bad[slot]));
    // BattleScript_IgnoresAndUsesRandomMove
    this._obeyLine(user, 'uses_random_move', ' ignored orders!');
    return ['called', slot];
  }
  const diff = lvl - ob;
  let r = this.roll(0, 255);
  const ab = user.ability;
  if (r < diff && !truthy(Status.normalise(mon.status)) && ab !== 'VITAL_SPIRIT' && ab !== 'INSOMNIA'
      && !truthy(this.uproarActive())) {
    // BattleScript_IgnoresAndFallsAsleep (the sleep counter rolls as any sleep's)
    this._obeyLine(user, 'falls_asleep', ' began to nap!');
    this.inflict(user, 'SLP', { source: user });
    return ['stop'];
  }
  r -= diff;
  if (r < diff) {
    // BattleScript_IgnoresAndHitsItself: the typeless 40-power hit, as confusion's
    this._obeyLine(user, 'hits_itself', " won't obey!");
    this.cancelMultiTurn(user);
    this._selfHit(C);
    return ['stop'];
  }
  const line = LOAF_LINES[mod(this.roll(0, 3), 4)];
  this._obeyLine(user, line[0], line[1]);
  return ['stop'];
};

// The per-strike move end, defined with the move end below (forward).
let strikeEnd = null;

// pret GET_MOVE_TYPE: the type the move has in battle.  Hidden Power's
// `hiddenpowercalc` and Weather Ball's `setweatherballtype` run BEFORE
// attackcanceler (battle_scripts_1.s BattleScript_EffectHiddenPower /
// BattleScript_EffectWeatherBall), so the absorbing abilities, Levitate and
// Hustle's accuracy all read this, not the row's Normal.
function dynamicMoveType(C) {
  let mt = int(C.move.type, 0);
  if (C.effect === E.HIDDEN_POWER) {
    const hpw = C.user.mon.hiddenPower;
    if (isTable(hpw)) mt = int(hpw.type, mt);
  } else if (C.effect === E.WEATHER_BALL) {
    const w = C.B.weather();
    if (w === 'RAIN') mt = Types.ID.WATER;
    else if (w === 'SAND') mt = Types.ID.ROCK;
    else if (w === 'SUN') mt = Types.ID.FIRE;
    else if (w === 'HAIL') mt = Types.ID.ICE;
  }
  return mt;
}
M.dynamicMoveType = dynamicMoveType;

// ------------------------------------------------------------------
// the damaging path (effects/hit.lua)
// ------------------------------------------------------------------

// The first battles' crit rule (Damage.calc `critGate`): 'none' under Birch
// (pokeemerald battle_script_commands.c:1281 tests the type before Random()),
// 'void' in Oak's lab until the `damage` lesson (pokefirered :1200 draws
// Random() first), else null. The tutorials alike: 'none' for the old man
// (pokefirered :1198) and Wally (pokeemerald :1281), 'void' for the POKe DUDE
// (pokefirered :1201). Both sides alike.
Bm.critGate = function critGate() {
  if (this.firstBattle === 'birch') return 'none';
  if (this.firstBattle === 'oak' && !truthy(this.lessons.damage)) return 'void';
  if (this.tutorial === 'oldMan' || this.tutorial === 'wally') return 'none';
  if (this.tutorial === 'pokedude') return 'void';
  return null;
};

Bm._calcOpts = function _calcOpts(C, target, extra) {
  const side = this.sides[target.side];
  const twoDef = truthy(this.double) && this.countStandingOnSide(target.side) >= 2;
  const o = {
    typeTable: this.typeTable,
    specialTypes: this.specialTypes,
    rng: this.rng,
    weather: this.weather(),
    dmgMultiplier: C.dmgMultiplier,
    critGate: this.critGate(),
    reflect: int(side.reflectTurns, 0) > 0,
    lightScreen: int(side.lightScreenTurns, 0) > 0,
    doubleScreens: twoDef,
    spread: twoDef && int(C.move.target, 0) === T.BOTH,
    mudSport: this.fieldSport('mudSport'),
    waterSport: this.fieldSport('waterSport'),
    plusPartner: this.abilityOnField('PLUS'),
    minusPartner: this.abilityOnField('MINUS'),
    pursuitSwitch: C.opts.pursuit,
    defenderId: target.slot,
  };
  if (truthy(extra)) {
    for (const k of Object.keys(extra)) {
      if (extra[k] !== undefined && extra[k] !== null) o[k] = extra[k];
    }
  }
  return o;
};

// pokefirered/src/battle_script_commands.c:1744 (+ datahpupdate)
Bm._dealDamage = function _dealDamage(C, dmgIn, infoIn) {
  const { user, target } = C;
  const info = truthy(infoIn) ? infoIn : {};
  const dmg = Math.max(0, Math.floor(truthy(dmgIn) ? dmgIn : 0));
  if (int(target.substituteHP, 0) > 0 && !truthy(info.ignoreSub)) {
    const dealt = Math.min(dmg, target.substituteHP);
    target.substituteHP -= dealt;
    this._emit('damage', {
      slot: target.slot, side: target.side, amount: dealt, hp: target.mon.hp,
    });
    this.say(`The SUBSTITUTE took damage for ${this.nameOf(target)}!`);
    if (target.substituteHP <= 0) {
      target.substituteHP = 0;
      this._emit('sub', { slot: target.slot, side: target.side, amount: 0 });
      this.say(`${this.nameOf(target)}'s SUBSTITUTE faded!`);
    }
    C.hitSubstitute = true;
    // The strike landed on the doll: its STATUS2_SUBSTITUTE bit stays set until
    // this strike's move end (MOVEEND_SUBSTITUTE), even when the doll just broke,
    // so the strike's secondary and King's Rock are refused (SetMoveEffect).
    C.subStrike = true;
    if (int(C.firstDmg, 0) === 0) C.firstDmg = dmg;
    C.hpDealt = dealt;
    C.hitsLanded = int(C.hitsLanded, 0) + 1;
    return dealt;
  }
  const dealt = this.loseHp(target, dmg);
  if (int(C.firstDmg, 0) === 0) C.firstDmg = dealt;
  if (dealt > 0) C.targetDamaged = true;
  target.lastHitBy = user;
  let { physical } = info;
  if (physical == null) physical = Types.isPhysical(C.moveType, this.specialTypes);
  // pokefirered/src/battle_script_commands.c:1824
  if (truthy(physical)) {
    target.lastPhysDmg = dealt;
    target.lastPhysBy = user.slot;
  } else {
    target.lastSpecDmg = dealt;
    target.lastSpecBy = user.slot;
    C.specialHit = true;
  }
  if (int(target.bideTurns, 0) > 0) {
    target.bideDamage = int(target.bideDamage, 0) + dealt;
    target.bideTarget = user;
  }
  C.hpDealt = dealt;
  C.hitsLanded = int(C.hitsLanded, 0) + 1;
  return dealt;
};

// pokefirered/src/battle_script_commands.c:1577 (Endure / Focus Band hang on)
// -> [dmg, how] with how 'endured' | 'hung' | null.
Bm._adjustDamage = function _adjustDamage(C, target, dmg) {
  const banded = Items.rollFocusBand(this, target);
  delete target.focusBanded;
  if (int(target.substituteHP, 0) <= 0 && (truthy(target.enduring) || truthy(banded))
      && dmg >= target.mon.hp) {
    return [Math.max(0, target.mon.hp - 1), truthy(target.enduring) ? 'endured' : 'hung'];
  }
  return [dmg, null];
};

function effectivenessLine(B, flags) {
  if (!truthy(flags)) return;
  if (truthy(flags.super)) B.say("It's super effective!");
  else if (truthy(flags.notVery)) B.say("It's not very effective...");
}

Bm._applySetDamage = function _applySetDamage(C, dmgIn, flags) {
  const [dmg, hung] = this._adjustDamage(C, C.target, dmgIn);
  C.attackAnimation();
  this._dealDamage(C, dmg);
  if (hung === 'endured') {
    this.say(`${this.nameOf(C.target)} endured the hit!`);
  } else if (hung === 'hung') {
    Items.focusBandMessage(this, C.target);
  } else if (truthy(flags)) {
    effectivenessLine(this, flags);
  }
};

function fail(C, text) {
  C.attackString();
  C.ppReduce();
  C.failed = true;
  C.missed = true;
  C.B.say(truthy(text) ? text : 'But it failed!');
}

function calledBySleepTalk(C) {
  return truthy(C.opts.calledBy) && int(C.opts.calledBy.effect, -1) === E.SLEEP_TALK;
}

function preChecks(C) {
  const {
    B, user, target, effect: eff,
  } = C;
  if (eff === E.FAKE_OUT && int(user.isFirstTurn, 0) <= 0) {
    fail(C);
    return true;
  }
  if (eff === E.DREAM_EATER && (int(target.substituteHP, 0) > 0
      || Status.normalise(target.mon.status) !== 'SLP')) {
    fail(C, `${B.nameOf(target)} wasn't affected!`);
    return true;
  }
  if (eff === E.COUNTER || eff === E.MIRROR_COAT) {
    // pokefirered/src/battle_script_commands.c:7568: back at whoever hit it.
    const taken = (eff === E.COUNTER) ? int(user.lastPhysDmg, 0) : int(user.lastSpecDmg, 0);
    // Lua `(eff == COUNTER) and user.lastPhysBy or user.lastSpecBy`: a nil
    // lastPhysBy falls through to lastSpecBy, as the Lua idiom does.
    const by = (eff === E.COUNTER && truthy(user.lastPhysBy)) ? user.lastPhysBy : user.lastSpecBy;
    let foe = null;
    for (const o of B.foes(user)) {
      if (o.slot === by) foe = o;
    }
    if (truthy(foe)) {
      const fm = followMe(B, user);
      if (truthy(fm)) foe = fm;
    }
    if (taken <= 0 || !truthy(foe)) {
      fail(C);
      return true;
    }
    C.target = foe;
  }
  if (eff === E.SNORE) {
    if (Status.normalise(user.mon.status) !== 'SLP') {
      fail(C);
      return true;
    }
    if (!calledBySleepTalk(C)) {
      B.say(`${B.nameOf(user)} is fast asleep.`);
    }
  }
  if (eff === E.ENDEAVOR && target.mon.hp <= user.mon.hp) {
    fail(C);
    return true;
  }
  if (eff === E.SPIT_UP && C.isProtected()) {
    C.attackString();
    C.ppReduce();
    if (int(user.stockpile, 0) <= 0) {
      B.say('But it failed to SPIT UP a thing!');
    } else {
      user.stockpile = 0;
      B.say(`${B.nameOf(C.target)} protected itself!`);
    }
    C.missed = true;
    return true;
  }
  if (eff === E.EXPLOSION && !truthy(C.explosionStarted)) {
    for (const b of B.active()) {
      if (b.ability === 'DAMP') {
        C.stopTargets = true;
        C.attackString();
        C.ppReduce();
        B.emitAbility(b);
        B.say(`${B.nameOf(b)}'s DAMP prevents ${B.nameOf(user)} from using ${C.moveName()}!`);
        C.failed = true;
        return true;
      }
    }
  }
  return false;
}

function setMultipliers(C) {
  const { target, effect: eff } = C;
  const semi = truthy(target) ? target.semi : target;
  C.dmgMultiplier = 1;
  if (eff === E.GUST || eff === E.TWISTER) {
    if (semi === 'ON_AIR') {
      C.ignoreOnAir = true;
      C.dmgMultiplier = 2;
    }
  } else if (eff === E.EARTHQUAKE || eff === E.MAGNITUDE) {
    if (semi === 'UNDERGROUND') {
      C.ignoreUnderground = true;
      C.dmgMultiplier = 2;
    }
  } else if ((eff === E.HIT && C.mnum === MOVE.SURF) || (eff === E.TRAP && C.mnum === MOVE.WHIRLPOOL)) {
    if (semi === 'UNDERWATER') {
      C.ignoreUnderwater = true;
      C.dmgMultiplier = 2;
    }
  } else if (eff === E.FLINCH_MINIMIZE_HIT) {
    if (truthy(target.minimized)) C.dmgMultiplier = 2;
  } else if (eff === E.THUNDER || eff === E.SKY_UPPERCUT) {
    C.ignoreOnAir = true;
  }
}

// pokefirered/data/battle_scripts_1.s:848 (Jump Kick / Hi Jump Kick crash)
function crashDamage(C) {
  const { B, user, target } = C;
  const [, flags] = Types.typeCalc(B.typeTable, int(C.move.type, 0), target.type1, target.type2,
    null, target.identified);
  if (flags.immune && C.missReason !== 'protected') return;
  B.say(`${B.nameOf(user)} kept going and crashed!`);
  let [dmg] = Damage.calc(user, target, C.move, B._calcOpts(C, target, { forceCrit: false }));
  dmg = Math.floor(dmg / 2);
  if (dmg === 0) dmg = 1;
  const cap = Math.floor(target.mon.maxHp / 2);
  if (cap < dmg) dmg = cap;
  B.loseHp(user, dmg);
  C.tryFaintUser();
}

function onMiss(C) {
  const { B, user, effect: eff } = C;
  C.missed = true;
  C.noEffect = true;
  if (eff === E.RECOIL_IF_MISS && C.missReason !== 'absorbed') crashDamage(C);
  if (eff === E.RAGE) delete user.rage;
  if (eff === E.ROLLOUT) B.cancelMultiTurn(user);
  if (eff === E.FURY_CUTTER) user.furyCutter = 0;
  if (eff === E.SEMI_INVULNERABLE) delete user.semi;
}

function flagsImmune(C, info) {
  const { B, target } = C;
  const mt = int(truthy(info) ? info.moveType : info, C.moveType);
  if (target.ability === 'LEVITATE' && mt === Types.ID.GROUND) {
    B.emitAbility(target);
    B.say(`${B.nameOf(target)} makes GROUND moves miss with LEVITATE!`);
    return true;
  }
  if (truthy(info) && info.effectiveness === 0) {
    B.say(`It doesn't affect ${B.nameOf(target)}...`);
    return true;
  }
  return false;
}

// pokefirered/src/battle_script_commands.c:1274 (Wonder Guard; not Struggle,
// which returns before typecalc on the cart).  Also OHKO's typecalc.
function wonderGuard(C, info) {
  const { B } = C;
  if (C.target.ability !== 'WONDER_GUARD') return false;
  if (C.mnum === MOVE.STRUGGLE) return false;
  const f = (truthy(info) && truthy(info.typeFlags)) ? info.typeFlags : {};
  if (truthy(f.super) && !truthy(f.notVery)) return false;
  B.emitAbility(C.target);
  B.say(`${B.nameOf(C.target)} avoided damage with WONDER GUARD!`);
  return true;
}

// pokefirered/data/battle_scripts_1.s:325 (Absorb / Mega Drain / Giga Drain / Dream Eater)
function drain(C) {
  const { B, user, target } = C;
  if (truthy(C.noEffect)) return;
  let heal = Math.floor(int(C.hpDealt, 0) / 2);
  if (heal === 0) heal = 1;
  if (C.effect === E.ABSORB && target.ability === 'LIQUID_OOZE') {
    B.emitAbility(target);
    B.loseHp(user, heal);
    B.say(`${B.nameOf(user)} sucked up the liquid ooze!`);
    C.tryFaintUser();
    return;
  }
  B.heal(user, heal);
  if (C.effect === E.DREAM_EATER) {
    B.say(`${B.nameOf(target)}'s dream was eaten!`);
  } else {
    B.say(`${B.nameOf(target)} had its energy drained!`);
  }
}

// pokefirered/src/battle_script_commands.c:8238
function present(C) {
  const { B, target } = C;
  const r = B.roll(0, 255);
  if (r < 102) return 40;
  if (r < 178) return 80;
  if (r < 204) return 120;
  if (target.mon.hp >= target.mon.maxHp) {
    B.say(`${B.nameOf(target)}'s HP is full!`);
    return null;
  }
  C.attackAnimation();
  const heal = Math.max(1, Math.floor(target.mon.maxHp / 4));
  B.heal(target, heal);
  B.say(`${B.nameOf(target)} regained health!`);
  return null;
}

// pokefirered/src/battle_script_commands.c:8161
function rolloutPower(C) {
  const { user } = C;
  if (int(user.rolloutTimer, 0) <= 0) {
    user.rolloutTimer = 5;
    user.lockedNum = C.mnum;
    user.lockedSlot = C.slot;
    user.lockedTarget = C.target;
  }
  user.rolloutTimer -= 1;
  if (user.rolloutTimer === 0) {
    delete user.lockedNum;
    delete user.lockedSlot;
    delete user.lockedTarget;
  }
  let power = int(C.move.power, 30);
  for (let n = 1; n <= (5 - user.rolloutTimer) - 1; n += 1) power *= 2;
  if (truthy(user.defenseCurl)) power *= 2;
  return power;
}

// pokefirered/src/battle_script_commands.c:8205
function furyCutterPower(C) {
  const { user } = C;
  let c = int(user.furyCutter, 0);
  if (c !== 5) c += 1;
  user.furyCutter = c;
  let power = int(C.move.power, 10);
  for (let n = 1; n <= c - 1; n += 1) power *= 2;
  return power;
}

// -> [dmg | null, info, status] with status 'fail' | 'immune' | 'endured' |
// 'hung' | 'ok'.
function hitOnce(C, optsIn) {
  const { B } = C;
  const opts = truthy(optsIn) ? optsIn : {};
  let [dmg, info] = Damage.calc(C.user, C.target, C.move, B._calcOpts(C, C.target, opts.calc));
  C.moveType = int(info.moveType, C.moveType);
  if (truthy(info.failed)) {
    C.failed = true;
    B.say('But it failed!');
    return [null, info, 'fail'];
  }
  if (flagsImmune(C, info)) {
    C.noEffect = true;
    C.missed = true;
    return [null, info, 'immune'];
  }
  if (wonderGuard(C, info)) {
    C.noEffect = true;
    C.missed = true;
    return [null, info, 'immune'];
  }
  let hung;
  [dmg, hung] = B._adjustDamage(C, C.target, dmg);
  C.attackAnimation();
  if (truthy(opts.onAfterAnim)) opts.onAfterAnim();
  B._dealDamage(C, dmg, info);
  if (truthy(info.critical)) B.say('A critical hit!');
  return [dmg, info, truthy(hung) ? hung : 'ok'];
}

// pokefirered/src/battle_script_commands.c:6857 (2 and 3 at 3/8 each, 4 and 5 at 1/8)
function multiHitCount(C) {
  const r = C.B.roll(0, 3);
  if (r > 1) return C.B.roll(0, 3) + 2;
  return r + 2;
}

function tripleKick(C) {
  const { B, user, target } = C;
  let power = 0;
  let landed = 0;
  let lastInfo = null;
  for (let i = 1; i <= 3; i += 1) {
    if (user.mon.hp <= 0 || target.mon.hp <= 0) break;
    if (Status.normalise(user.mon.status) === 'SLP' && !calledBySleepTalk(C)) break;
    if (!C.accuracyCheck('normal', landed === 0)) {
      if (landed === 0) onMiss(C);
      break;
    }
    power += 10;
    const [, info, status] = hitOnce(C, { calc: { power } });
    lastInfo = info;
    if (status !== 'ok' && status !== 'endured' && status !== 'hung') break;
    landed += 1;
    if (status === 'hung') Items.focusBandMessage(B, target);
    // battle_scripts_1.s:1414 moveendto MOVEEND_NEXT_TARGET, every kick (the
    // endured one too: the FOE_ENDURED jump comes after it)
    strikeEnd(C);
    if (status === 'endured') {
      B.say(`${B.nameOf(target)} endured the hit!`);
      break;
    }
  }
  // battle_scripts_1.s:1433: the kick loop ends with moveendfrom
  // MOVEEND_UPDATE_LAST_MOVES only.
  C.endFrom = 'last';
  if (landed > 0) {
    effectivenessLine(B, truthy(lastInfo) ? lastInfo.typeFlags : lastInfo);
    B.say(`Hit ${landed} time(s)!`);
    C.tryFaintTarget();
  }
}

// pokefirered/src/battle_script_commands.c:8571: every healthy party member of
// the user's seat, by the sheet's base Attack against the target's base Defense.
function beatUp(C) {
  const { B, user, target } = C;
  if (!C.accuracyCheck('normal', true)) {
    onMiss(C);
    return;
  }
  let any = false;
  const dBase = truthy(target.mon.beatUp) ? target.mon.beatUp : {};
  const mons = user.fighter.mons;
  for (let i = 1; i <= mons.length; i += 1) {
    const mon = mons[i - 1];
    if (target.mon.hp <= 0) break;
    let { hp, status } = mon;
    if (i === user.partyIndex) {
      ({ hp, status } = user.mon);
    }
    if (hp > 0 && !truthy(Status.normalise(status))) {
      any = true;
      const aBase = truthy(mon.beatUp) ? mon.beatUp : {};
      const atk = Math.max(1, int(aBase.atk, 50));
      const def = Math.max(1, int(dBase.def, 50));
      const lvl = int(mon.level, 1);
      let dmg = atk * int(C.move.power, 10) * (Math.floor(lvl * 2 / 5) + 2);
      dmg = Math.floor(dmg / def);
      dmg = Math.floor(dmg / 50) + 2;
      // pokefirered/src/battle_script_commands.c:8606
      if (truthy(user.helpingHand)) dmg = Math.floor(dmg * 15 / 10);
      B.say(`${mon.species}'s attack!`);
      // pokefirered/data/battle_scripts_1.s:1947: a critcalc per member, and
      // Cmd_critcalc (battle_script_commands.c:1196) skips the roll entirely
      // against Battle Armor / Shell Armor, as Damage.calc does.
      let crit = false;
      const gate = B.critGate();
      if (target.ability !== 'BATTLE_ARMOR' && target.ability !== 'SHELL_ARMOR' && gate !== 'none') {
        const stage = Crit.stage(user, C.move);
        [crit] = Crit.check(stage, B.roll(0, Crit.chance(stage) - 1));
        if (gate === 'void') crit = false;
      }
      if (crit) dmg *= 2;
      const r = B.roll(Damage.ROLL_MIN, Damage.ROLL_MAX);
      dmg = Math.floor(dmg * r / 100);
      if (dmg === 0) dmg = 1;
      let hung;
      [dmg, hung] = B._adjustDamage(C, target, dmg);
      C.attackAnimation();
      B._dealDamage(C, dmg, { physical: false });
      if (crit) B.say('A critical hit!');
      if (hung === 'endured') B.say(`${B.nameOf(target)} endured the hit!`);
      else if (hung === 'hung') Items.focusBandMessage(B, target);
      C.tryFaintTarget();
      // battle_scripts_1.s:1964 moveendto MOVEEND_NEXT_TARGET per member; the
      // loop's own end (BattleScript_BeatUpEnd) runs no move end after it.
      strikeEnd(C);
      C.endFrom = 'last';
    }
  }
  if (!any) {
    C.failed = true;
    B.say('But it failed!');
  }
}

// pokefirered/data/battle_scripts_1.s:376 (Selfdestruct / Explosion)
function explosion(C) {
  const { B, user } = C;
  C.attackString();
  C.ppReduce();
  C.explosionStarted = true;
  const hpBefore = user.mon.hp;
  if (hpBefore > 0) B.loseHp(user, hpBefore);
  let [dmg, info] = Damage.calc(user, C.target, C.move, B._calcOpts(C, C.target));
  if (!C.accuracyCheck('normal', true)) {
    C.missed = true;
    C.noEffect = true;
    if (!truthy(C.deferUserFaint)) C.tryFaintUser();
    return;
  }
  if (flagsImmune(C, info)) {
    C.noEffect = true;
    if (!truthy(C.deferUserFaint)) C.tryFaintUser();
    return;
  }
  const { target } = C;
  let hung;
  [dmg, hung] = B._adjustDamage(C, target, dmg);
  C.attackAnimation();
  B._dealDamage(C, dmg, info);
  if (truthy(info.critical)) B.say('A critical hit!');
  if (hung === 'endured') B.say(`${B.nameOf(target)} endured the hit!`);
  else if (hung === 'hung') Items.focusBandMessage(B, target);
  else effectivenessLine(B, info.typeFlags);
  C.tryFaintTarget();
  if (!truthy(C.deferUserFaint)) C.tryFaintUser();
}

// effects/hit.lua Hit.run
M.hit = function hit(C) {
  const { B, user, effect: eff } = C;
  C.moveType = dynamicMoveType(C);

  if (preChecks(C)) return;
  setMultipliers(C);

  if ((eff === E.RAMPAGE && int(user.rampageTurns, 0) > 0)
      || (eff === E.UPROAR && int(user.uproarTurns, 0) > 0)
      || (eff === E.ROLLOUT && int(user.rolloutTimer, 0) > 0)) {
    C.noPP = true;
  }
  if (eff === E.RAMPAGE && int(user.rampageTurns, 0) <= 0) C.startRampage = true;

  if (eff === E.EXPLOSION) {
    explosion(C);
    return;
  }

  C.attackString();
  C.ppReduce();

  let { magnitude } = C;
  if (eff === E.MAGNITUDE && !truthy(magnitude)) {
    const [value, power] = Damage.magnitude(B.roll(0, 99));
    magnitude = { power, value };
    C.magnitude = magnitude;
    B.say(`MAGNITUDE ${value}!`);
  }

  if (eff === E.TRIPLE_KICK) {
    tripleKick(C);
    return;
  }
  if (eff === E.BEAT_UP) {
    beatUp(C);
    return;
  }

  // Pursuit on a switching target (battle_scripts_1.s:3081
  // BattleScript_PursuitDmgOnSwitchOut) draws no accuracy: attackstring,
  // ppreduce, then straight to critcalc / damagecalc.
  if (!truthy(C.opts.pursuit) && !C.accuracyCheck('normal', true)) {
    onMiss(C);
    return;
  }

  if (eff === E.SEMI_INVULNERABLE) delete user.semi;
  if (eff === E.RAGE) user.rage = true;

  const { target } = C;
  const calcExtra = {};
  if (truthy(magnitude)) calcExtra.power = magnitude.power;

  if (eff === E.ROLLOUT) {
    const [, f] = Types.typeCalc(B.typeTable, int(C.move.type, 0), target.type1, target.type2,
      null, target.identified);
    if (f.immune) {
      B.cancelMultiTurn(user);
      B.say(`It doesn't affect ${B.nameOf(target)}...`);
      C.noEffect = true;
      return;
    }
    calcExtra.power = rolloutPower(C);
  } else if (eff === E.FURY_CUTTER) {
    calcExtra.power = furyCutterPower(C);
  } else if (eff === E.PRESENT) {
    const p = present(C);
    if (!truthy(p)) return;
    calcExtra.power = p;
  } else if (eff === E.SPIT_UP) {
    // pokefirered/src/battle_script_commands.c:6586
    const n = int(user.stockpile, 0);
    if (n <= 0) {
      B.say('But it failed to SPIT UP a thing!');
      C.failed = true;
      return;
    }
    user.stockpile = 0;
    const o = B._calcOpts(C, target);
    let base = Damage.base(user, target, C.move, {
      weather: o.weather,
      reflect: o.reflect,
      lightScreen: o.lightScreen,
      doubleScreens: o.doubleScreens,
      specialTypes: B.specialTypes,
      mudSport: o.mudSport,
      waterSport: o.waterSport,
      plusPartner: o.plusPartner,
      minusPartner: o.minusPartner,
    }) * n;
    // pokefirered/src/battle_script_commands.c:6603
    if (truthy(user.helpingHand)) base = Math.floor(base * 15 / 10);
    if (isType(user, int(C.move.type, 0))) base = Math.floor(base * 15 / 10);
    const [dmg, flags] = Types.typeCalc(B.typeTable, int(C.move.type, 0), target.type1, target.type2,
      base, target.identified);
    if (flags.immune) {
      B.say(`It doesn't affect ${B.nameOf(target)}...`);
      C.noEffect = true;
      return;
    }
    B._applySetDamage(C, dmg, flags);
    C.tryFaintTarget();
    return;
  } else if (eff === E.BRICK_BREAK) {
    const side = B.sides[target.side];
    if (int(side.reflectTurns, 0) > 0 || int(side.lightScreenTurns, 0) > 0) {
      side.reflectTurns = 0;
      side.lightScreenTurns = 0;
      C.brokeWall = true;
    }
  }

  const fixed = eff === E.DRAGON_RAGE || eff === E.SONICBOOM || eff === E.LEVEL_DAMAGE
    || eff === E.SUPER_FANG || eff === E.PSYWAVE || eff === E.ENDEAVOR;
  const setDmg = fixed || eff === E.COUNTER || eff === E.MIRROR_COAT;

  let nHits = 1;
  let isMulti = false;
  if (eff === E.MULTI_HIT) {
    nHits = multiHitCount(C);
    isMulti = true;
  } else if (eff === E.DOUBLE_HIT || eff === E.TWINEEDLE) {
    nHits = 2;
    isMulti = true;
  }

  let landed = 0;
  let lastInfo = null;
  let lastStatus = null;
  for (let i = 1; i <= nHits; i += 1) {
    if (user.mon.hp <= 0 || target.mon.hp <= 0) break;
    if (isMulti && i > 1 && Status.normalise(user.mon.status) === 'SLP' && !calledBySleepTalk(C)) break;
    const [, info, status] = hitOnce(C, {
      calc: calcExtra,
      onAfterAnim: (i === 1 && truthy(C.brokeWall)) ? () => { B.say('It shattered the barrier!'); } : null,
    });
    lastInfo = info;
    lastStatus = status;
    if (status !== 'ok' && status !== 'endured' && status !== 'hung') break;
    landed += 1;
    if (status === 'endured') {
      // battle_scripts_1.s:638: a multi-hit strike's move end runs before the
      // FOE_ENDURED jump; a single hit prints it straight away.
      if (isMulti) strikeEnd(C);
      B.say(`${B.nameOf(target)} endured the hit!`);
      break;
    }
    if (status === 'hung') {
      Items.focusBandMessage(B, target);
    } else if (!isMulti) {
      let f = info.typeFlags;
      if (setDmg && !(eff === E.COUNTER || eff === E.MIRROR_COAT)) f = null;
      effectivenessLine(B, f);
    }
    // battle_scripts_1.s:638 moveendto MOVEEND_NEXT_TARGET after every strike:
    // Rage, contact abilities, the item checks, King's Rock / Shell Bell and
    // the Substitute update run per strike; the loop's end (:654) runs the
    // move end again from MOVEEND_SYNCHRONIZE_TARGET, skipping on-damage ones.
    if (isMulti) strikeEnd(C);
  }
  if (isMulti && landed > 0) C.endFrom = 'sync';
  if (isMulti && landed > 0) {
    if (lastStatus !== 'endured' && lastStatus !== 'hung') {
      effectivenessLine(B, truthy(lastInfo) ? lastInfo.typeFlags : lastInfo);
    }
    B.say(`Hit ${landed} time(s)!`);
  }
  if (landed === 0) {
    C.noEffect = true;
    if (eff === E.ROLLOUT) B.cancelMultiTurn(user);
    return;
  }

  if (eff === E.ABSORB || eff === E.DREAM_EATER) drain(C);
  Effects.secondaryAfter(C);
  C.tryFaintTarget();
  if (truthy(C.checkUserFaint)) C.tryFaintUser();
};

// ------------------------------------------------------------------
// the special shapes (engine.lua)
// ------------------------------------------------------------------

// pokefirered/data/battle_scripts_1.s:3251
function bideAttack(C) {
  const { B, user } = C;
  const stored = int(user.bideDamage, 0);
  const src = user.bideTarget;
  delete user.bideDamage;
  delete user.bideTarget;
  delete user.bideTurns;
  delete user.lockedNum;
  delete user.lockedSlot;
  delete user.lockedTarget;
  B.say(`${B.nameOf(user)} unleashed energy!`);
  if (stored <= 0) {
    C.failed = true;
    B.say('But it failed!');
    return;
  }
  if (truthy(src) && src.mon.hp > 0 && src.fighter.b === src) {
    C.target = src;
  } else if (truthy(src) && truthy(src.fighter.b) && src.fighter.b.mon.hp > 0) {
    C.target = src.fighter.b;
  } else {
    C.target = B.foes(user)[0];
  }
  if (!truthy(C.target)) {
    B.say('But it failed!');
    return;
  }
  const { target } = C;
  if (!C.accuracyCheck('normal', true)) return;
  const [, flags] = Types.typeCalc(B.typeTable, int(C.move.type, 0), target.type1, target.type2,
    null, target.identified);
  if (flags.immune) {
    B.say(`It doesn't affect ${B.nameOf(target)}...`);
    return;
  }
  B._applySetDamage(C, stored * 2);
  C.tryFaintTarget();
}

// pokefirered/data/battle_scripts_1.s:794 (the first turn of a two-turn move)
function chargeTurn(C) {
  const { B, user, effect: eff } = C;
  const isCharge = CHARGE_TEXT[eff] !== undefined || eff === E.SEMI_INVULNERABLE;
  if (!isCharge) return false;
  if (user.twoTurnNum != null && user.twoTurnNum === C.mnum) {
    delete user.twoTurnNum;
    delete user.twoTurnTarget;
    delete user.lockedNum;
    delete user.lockedSlot;
    delete user.lockedTarget;
    C.noPP = true;
    C.secondTurn = true;
    if (C.mnum === MOVE.SKY_ATTACK) C.extraEffect = { eff: 'FLINCH' };
    if (C.mnum === MOVE.BOUNCE) C.extraEffect = { eff: 'PARALYSIS' };
    return false;
  }
  if (eff === E.SOLAR_BEAM && B.weather() === 'SUN') {
    C.ppReduce();
    C.noPP = true;
    return false;
  }
  C.ppReduce();
  C.attackAnimation(1);
  user.twoTurnNum = C.mnum;
  user.twoTurnTarget = C.target;
  user.lockedNum = C.mnum;
  user.lockedSlot = C.slot;
  user.lockedTarget = C.target;
  if (eff === E.SEMI_INVULNERABLE) {
    const row = SEMI_TEXT[C.mnum] !== undefined ? SEMI_TEXT[C.mnum] : [' vanished!', 'ON_AIR'];
    B.say(B.nameOf(user) + row[0]);
    user.semi = row[1];
  } else {
    B.say(B.nameOf(user) + CHARGE_TEXT[eff]);
    if (eff === E.SKULL_BASH) {
      Effects.changeStat(B, user, 'def', 1, { user: true, allowPtr: true, noMsg: user.stages.def >= 6 });
    }
  }
  return true;
}

// pokefirered/data/battle_scripts_1.s:761 (+ Cmd_tryKO battle_script_commands.c:7104)
function ohko(C) {
  const { B, user, target } = C;
  C.attackString();
  C.ppReduce();
  if (!C.accuracyCheck('lockon', true)) {
    C.missed = true;
    return;
  }
  const [, flags] = Types.typeCalc(B.typeTable, int(C.move.type, 0), target.type1, target.type2,
    null, target.identified);
  if (flags.immune || (target.ability === 'LEVITATE' && int(C.move.type, 0) === Types.ID.GROUND)) {
    C.missed = true;
    B.say(`It doesn't affect ${B.nameOf(target)}...`);
    return;
  }
  // Cmd_typecalc (battle_scripts_1.s:766 runs it before tryKO) also applies
  // Wonder Guard to a move with power: an OHKO move that is not super
  // effective misses Shedinja.
  if (int(C.move.power, 0) !== 0 && wonderGuard(C, { typeFlags: flags })) {
    C.missed = true;
    return;
  }
  const banded = Items.rollFocusBand(B, target);
  delete target.focusBanded;
  if (target.ability === 'STURDY') {
    C.missed = true;
    B.emitAbility(target);
    B.say(`${B.nameOf(target)} was protected by STURDY!`);
    return;
  }
  const uLvl = int(user.mon.level, 1);
  const tLvl = int(target.mon.level, 1);
  let hit;
  if (C.lockOnActive() && uLvl >= tLvl) {
    hit = true;
  } else {
    const chance = int(C.move.accuracy, 30) + (uLvl - tLvl);
    hit = B.roll(1, 100) < chance && uLvl >= tLvl;
  }
  if (!hit) {
    C.missed = true;
    if (uLvl >= tLvl) {
      B.say(`${B.nameOf(user)}'s attack missed!`);
    } else {
      B.say(`${B.nameOf(target)} is unaffected!`);
    }
    return;
  }
  const hpBefore = target.mon.hp;
  let dmg = hpBefore;
  const endured = truthy(target.enduring);
  const hung = !endured && truthy(banded);
  if (endured || hung) dmg = Math.max(0, hpBefore - 1);
  C.attackAnimation();
  B._dealDamage(C, dmg, { physical: Types.isPhysical(int(C.move.type, 0), B.specialTypes) });
  if (endured) {
    B.say(`${B.nameOf(target)} endured the hit!`);
  } else if (hung) {
    Items.focusBandMessage(B, target);
  } else {
    B.say("It's a one-hit KO!");
  }
  C.tryFaintTarget();
}

// pokefirered/src/battle_script_commands.c:866 (Magic Coat, then Snatch)
function tryBounce(C) {
  const { B, user, target } = C;
  if (truthy(C.opts.bounced)) return false;
  if (truthy(target) && target !== user && truthy(target.magicCoat) && hasFlag(C.move, F.MAGIC_COAT)) {
    delete target.magicCoat;
    C.attackString();
    C.ppReduce();
    B.say(`${B.nameOf(user)}'s ${C.moveName()} was bounced back by MAGIC COAT!`);
    C.user = target;
    C.target = user;
    C.slot = null;
    C.chosenSlot = null;
    C.noPP = true;
    C.opts.bounced = true;
    return true;
  }
  if (hasFlag(C.move, F.SNATCH)) {
    for (const f of (truthy(B.turnOrderFighters) ? B.turnOrderFighters : [])) {
      const { b } = f;
      if (truthy(b) && b !== user && truthy(b.snatch) && b.mon.hp > 0) {
        delete b.snatch;
        C.attackString();
        C.ppReduce();
        B.say(`${B.nameOf(b)} snatched ${B.nameOf(user)}'s move!`);
        C.user = b;
        C.target = user;
        C.slot = null;
        C.chosenSlot = null;
        C.noPP = true;
        C.opts.bounced = true;
        return true;
      }
    }
  }
  return false;
}

// pokefirered/src/battle_script_commands.c:888
function lightningRodTook(C) {
  const t = C.target;
  if (!(truthy(t) && truthy(t.lightningRodRedirected))) return false;
  delete t.lightningRodRedirected;
  C.attackString();
  C.B.emitAbility(t);
  C.B.say(`${C.B.nameOf(t)}'s LIGHTNINGROD took the attack!`);
  return true;
}

// pokefirered/src/battle_util.c:1891 (attackcanceler's ABILITYEFFECT_ABSORBING,
// which the cart runs BEFORE the accuracy check)
function absorbCheck(C) {
  const { B, user, target } = C;
  if (!truthy(target) || target === user) return false;
  const mt = C.moveType;
  const power = int(C.move.power, 0);
  if (!((target.ability === 'VOLT_ABSORB' && mt === Types.ID.ELECTRIC && power !== 0)
      || (target.ability === 'WATER_ABSORB' && mt === Types.ID.WATER && power !== 0)
      || (target.ability === 'FLASH_FIRE' && mt === Types.ID.FIRE
          && Status.normalise(target.mon.status) !== 'FRZ'))) {
    return false;
  }
  C.attackString();
  C.ppReduce();
  Abilities.absorb(B, user, target, mt, power, C.moveName());
  C.absorbed = true;
  C.noEffect = true;
  C.missed = true;
  C.missReason = 'absorbed';
  return true;
}

// ------------------------------------------------------------------
// move end (pokefirered/src/battle_script_commands.c:4056 / :4121)
// ------------------------------------------------------------------

// MOVEEND_SYNCHRONIZE_TARGET .. MOVEEND_KINGSROCK_SHELLBELL.  `skipOnDamage`
// is the multi-hit loop's closing pass (moveendcase SYNCHRONIZE_TARGET, then
// moveendfrom IMMUNITY_ABILITIES), whose strikes already ran the contact
// abilities one by one.
function moveEndEffects(C, skipOnDamage) {
  const { B, user, target } = C;
  if (truthy(target) && target !== user) Abilities.synchronize(B, C, target, user);
  if (!truthy(skipOnDamage)) Abilities.onDamage(B, C);
  Abilities.immunityCure(B);
  if (truthy(target) && target !== user) Abilities.synchronize(B, C, user, target);
  const chosen = truthy(C.opts.calledBy) ? C.opts.calledBy : C.move;
  const chosenNum = int(chosen.num, 0);
  if (Items.has(user, Items.HOLD.CHOICE_BAND) && chosenNum !== MOVE.STRUGGLE && !truthy(user.choicedMove)) {
    if (!(int(chosen.effect, -1) === E.BATON_PASS && !truthy(C.failed))) {
      user.choicedMove = chosenNum;
    }
  }
  if (truthy(user.choicedMove) && !truthy(B.slotOfNum(user, user.choicedMove))) delete user.choicedMove;
  Items.moveEnd(B);
  // pokefirered/src/battle_util.c:2995 ITEMEFFECT_KINGSROCK_SHELLBELL
  if (truthy(target) && int(C.firstDmg, 0) !== 0) {
    const [he, param] = Items.of(user);
    if (he === Items.HOLD.FLINCH) {
      // The cart reads the flinch chance off battler 0's item (the call passes
      // battler 0), kept as the quirk it is: field slot 0's active mon.
      const first = truthy(B.order[0]) ? B.order[0].b : null;
      const [, p0] = Items.of(first);
      if (!truthy(C.noEffect) && truthy(C.targetDamaged) && target.mon.hp > 0) {
        if (B.roll(0, 99) < p0 && hasFlag(C.move, F.KINGS_ROCK)) {
          Effects.set(C, 'FLINCH', false, false, false);
        }
      }
    } else if (he === Items.HOLD.SHELL_BELL) {
      if (!truthy(C.noEffect) && user !== target && user.mon.hp !== user.mon.maxHp && user.mon.hp > 0) {
        let amt = Math.floor(C.firstDmg / Math.max(1, param));
        if (amt === 0) amt = 1;
        C.firstDmg = 0;
        const lbl = B.itemLabel(user);
        Items.heldEvent(B, user, int(user.mon.heldItem, 0), lbl);
        B.say(`${B.nameOf(user)}'s ${lbl} restored its HP a little!`);
        B.heal(user, amt);
      }
    }
  }
}

// MOVEEND_RAGE (TARGET_TURN_DAMAGED: a hit on the doll builds nothing) and
// MOVEEND_DEFROST.
function rageAndDefrost(C) {
  const { B, user, target } = C;
  if (truthy(target) && target !== user && truthy(target.rage) && target.mon.hp > 0
      && user.side !== target.side && !truthy(C.noEffect) && truthy(C.targetDamaged)
      && int(C.move.power, 0) > 0 && target.stages.atk < 6) {
    target.stages.atk += 1;
    const text = `${B.nameOf(target)}'s RAGE is building!`;
    B.emit('stat', {
      slot: target.slot,
      side: target.side,
      stat: 'atk',
      stage: target.stages.atk,
      delta: 1,
      text,
    });
    B.say(text);
  }
  if (truthy(target) && target !== user && Status.normalise(target.mon.status) === 'FRZ'
      && target.mon.hp > 0 && truthy(C.specialHit) && !truthy(C.noEffect)
      && C.moveType === Types.ID.FIRE) {
    B.cure(target, `${B.nameOf(target)} was defrosted!`);
  }
}

// One strike's move end (pret `moveendto MOVEEND_NEXT_TARGET` inside the
// multi-hit, Triple Kick and Beat Up loops): Rage, defrost, the contact
// abilities, the item checks, King's Rock / Shell Bell, then MOVEEND_SUBSTITUTE
// drops the strike's doll bit.  The last-move bookkeeping is left to the move's
// closing pass (the same values either way).
strikeEnd = function strikeEndFn(C) {
  rageAndDefrost(C);
  moveEndEffects(C, false);
  delete C.subStrike;
};

// The move's closing move end.  `C.endFrom` says where the move's own script
// resumes it: null = moveendall, 'sync' = the multi-hit close (no Rage / defrost
// / on-damage), 'last' = Triple Kick / Beat Up (MOVEEND_UPDATE_LAST_MOVES on).
function moveEnd(C) {
  const { user, target } = C;
  if (C.endFrom == null) rageAndDefrost(C);
  if (C.endFrom !== 'last') moveEndEffects(C, C.endFrom === 'sync');
  delete C.subStrike;
  const chosen = truthy(C.opts.calledBy) ? C.opts.calledBy : C.move;
  const chosenNum = int(chosen.num, 0);
  if (int(chosen.effect, -1) !== E.BATON_PASS) {
    user.lastMoveNum = chosenNum;
    user.lastResultingNum = C.mnum;
  }
  if (truthy(C.printedUsed)) user.lastPrinted = chosenNum;
  if (truthy(target) && target !== user && !truthy(C.noEffect) && !truthy(C.missed)
      && hasFlag(chosen, F.MIRROR_MOVE) && target.mon.hp > 0) {
    target.lastTakenMove = chosenNum;
  }
  if (truthy(target) && target !== user && !truthy(C.noEffect) && !truthy(C.missed)
      && int(C.hitsLanded, 0) > 0) {
    target.lastLandedMove = C.mnum;
    target.lastHitByType = C.moveType;
  }
}

function moveEndLite(C) {
  Abilities.immunityCure(C.B);
  Items.moveEnd(C.B);
}

// ------------------------------------------------------------------
// calling moves (engine.lua call_moves / run_called)
// ------------------------------------------------------------------

// How deep one action may nest called moves.  The deepest chain a cart can
// build is three calls (Metronome -> Assist -> Nature Power -> the terrain
// move: Metronome may pick Assist, Assist may pick Nature Power); a sheet or
// pool row that calls itself (Swift carrying EFFECT_NATURE_POWER, a
// "Sleep Talk" numbered like Pound) would otherwise recurse until the stack
// overflows and wedge the fight in `resolving`.  Past the cap the call says
// "But it failed!".
M.MAX_CALL_DEPTH = 3;

// extra: noPP (Sleep Talk's HITMARKER_NO_PPDEDUCT for the called slot),
// sameDepth (a disobedient pick: it replaces the chosen move, it is not called
// from inside one, so it nests no deeper).
function runCalled(C, row, slot, extra) {
  const { B } = C;
  const depth = int(C.opts.callDepth, 0) + ((truthy(extra) && truthy(extra.sameDepth)) ? 0 : 1);
  if (!truthy(row) || depth > M.MAX_CALL_DEPTH) {
    C.failed = true;
    B.say('But it failed!');
    return undefined;
  }
  const target = B._pickTarget(C.user, row, null, true, true);
  const opts = {
    called: true,
    calledBy: truthy(C.opts.calledBy) ? C.opts.calledBy : C.move,
    pursuit: C.opts.pursuit,
    callDepth: depth,
    chosenSlot: C.chosenSlot,
    noPP: (truthy(extra) && truthy(extra.noPP)) ? extra.noPP : null,
  };
  return B._resolveMove(C.user, target, row, slot, opts);
}

// pokefirered/src/battle_script_commands.c:7834 IsInvalidForSleepTalkOrAssist,
// by number as on the cart -- and by effect, so a row that carries one of the
// four calling effects under another number is refused the same way.
const CALLER_EFFECT = {
  [E.SLEEP_TALK]: true, [E.ASSIST]: true, [E.MIRROR_MOVE]: true, [E.METRONOME]: true,
};
function invalidSleepTalk(num, effect) {
  return num == null || num === 0 || num === MOVE.SLEEP_TALK || num === MOVE.ASSIST
    || num === MOVE.MIRROR_MOVE || num === MOVE.METRONOME || CALLER_EFFECT[int(effect, -1)] === true;
}

// pokefirered/src/battle_script_commands.c:7519: roll 1..511 until a legal pool
// move; after 64 misses, one pick over the legal list.
function pickMetronome(B) {
  if (!truthy(B.pool)) return null;
  for (let n = 1; n <= 64; n += 1) {
    const m = B.roll(1, 511);
    if (m < 355 && !Effects.forbidden(m, false) && truthy(B.pool[m])) return B.pool[m];
  }
  const list = [];
  for (let num = 1; num <= 354; num += 1) {
    if (truthy(B.pool[num]) && !Effects.forbidden(num, false)) list.push(num);
  }
  if (list.length === 0) return null;
  const picked = B.pool[list[B.roll(1, list.length) - 1]];
  return picked === undefined ? null : picked;
}

function callMoves(C) {
  const { B, user, effect: eff } = C;
  if (eff === E.METRONOME) {
    C.attackString();
    C.ppReduce();
    const row = pickMetronome(B);
    if (!truthy(row)) {
      C.failed = true;
      B.say('But it failed!');
      return undefined;
    }
    C.attackAnimation();
    return runCalled(C, row);
  }
  if (eff === E.SLEEP_TALK) {
    // pokefirered/data/battle_scripts_1.s:1307
    if (Status.normalise(user.mon.status) !== 'SLP') {
      C.attackString();
      C.ppReduce();
      C.failed = true;
      B.say('But it failed!');
      return undefined;
    }
    B.say(`${B.nameOf(user)} is fast asleep.`);
    C.attackString();
    C.ppReduce();
    // pokefirered/src/battle_script_commands.c:7866 Cmd_trychoosesleeptalkmove:
    // the four callers, Focus Punch, Uproar and the two-turn moves, then
    // CheckMoveLimitations with every limit but PP (Disable, Torment, Taunt,
    // Imprison, Encore, Choice Band).
    const bad = B.moveLimitations(user, true);
    const valid = [];
    for (let i = 1; i <= user.moves.length; i += 1) {
      const mv = user.moves[i - 1];
      const n = int(mv.num, 0);
      if (!truthy(bad[i]) && !invalidSleepTalk(n, mv.effect) && n !== MOVE.FOCUS_PUNCH
          && n !== MOVE.UPROAR && !truthy(TWO_TURN[int(mv.effect, -1)])) {
        valid.push({ row: mv, slot: i });
      }
    }
    if (valid.length === 0) {
      C.failed = true;
      B.say('But it failed!');
      return undefined;
    }
    const pick = valid[B.roll(1, valid.length) - 1];
    C.attackAnimation();
    // gCurrMovePos = the picked slot (Mimic / Sketch write there), with
    // HITMARKER_NO_PPDEDUCT: the called move spends no PP of its own.
    return runCalled(C, pick.row, pick.slot, { noPP: true });
  }
  if (eff === E.MIRROR_MOVE) {
    // pokefirered/src/battle_script_commands.c:6350
    C.attackString();
    const num = user.lastTakenMove;
    if (truthy(num) && num !== 0) {
      C.ppReduce();
      return runCalled(C, B.calledRowByNum(num, user));
    }
    C.ppReduce();
    C.failed = true;
    B.say('The MIRROR MOVE failed!');
    return undefined;
  }
  if (eff === E.ASSIST) {
    // pokefirered/src/battle_script_commands.c:9091
    C.attackString();
    const list = [];
    const mons = user.fighter.mons;
    for (let i = 1; i <= mons.length; i += 1) {
      const mon = mons[i - 1];
      if (i !== user.partyIndex) {
        const moves = truthy(mon.moves) ? mon.moves : [];
        for (let j = 1; j <= moves.length; j += 1) {
          const n = int(moves[j - 1].num, 0);
          if (n !== 0 && !invalidSleepTalk(n, moves[j - 1].effect) && !Effects.forbidden(n, false)) {
            list.push(moves[j - 1]);
          }
        }
      }
    }
    C.ppReduce();
    if (list.length === 0) {
      C.failed = true;
      B.say('But it failed!');
      return undefined;
    }
    C.attackAnimation();
    return runCalled(C, list[B.roll(1, list.length) - 1]);
  }
  if (eff === E.NATURE_POWER) {
    // pokefirered/src/battle_script_commands.c:8718
    C.attackString();
    const mapped = Field.NATURE_POWER_MOVE[B.terrain];
    const num = mapped !== undefined ? mapped : 129;
    const row = B.calledRowByNum(num, user);
    if (!truthy(row)) {
      C.ppReduce();
      C.failed = true;
      B.say('But it failed!');
      return undefined;
    }
    B.say(`NATURE POWER turned into ${B.moveLabel(row)}!`);
    return runCalled(C, row, C.slot);
  }
  return undefined;
}

// ------------------------------------------------------------------
// targets (pokefirered/src/battle_script_commands.c:4308 + :8532)
// ------------------------------------------------------------------

function resetTargetValues(C) {
  C.noEffect = null;
  C.missReason = null;
  C.failed = null;
  C.hitSubstitute = null;
  C.hpDealt = null;
  C.firstDmg = null;
  C.hitsLanded = null;
  C.targetDamaged = null;
  C.specialHit = null;
  C.dmgMultiplier = 1;
  C.ignoreOnAir = null;
  C.ignoreUnderground = null;
  C.ignoreUnderwater = null;
  C.brokeWall = null;
  C.missed = false;
  C.absorbed = null;
  C.endFrom = null;
  C.subStrike = null;
}

function forEachTarget(C, body) {
  const { B } = C;
  const ttype = int(C.move.target, 0);
  if (!truthy(B.double)) return body(C);
  if (ttype === T.FOES_AND_ALLY) {
    const list = [];
    for (const b of B.active()) {
      if (b !== C.user) list.push(b);
    }
    if (list.length === 0) return body(C);
    C.spread = list.length > 1;
    C.deferUserFaint = (C.effect === E.EXPLOSION);
    let anyLanded = false;
    for (let i = 1; i <= list.length; i += 1) {
      const b = list[i - 1];
      if (i > 1) resetTargetValues(C);
      C.target = b;
      delete b.statLoweredMsg;
      if (b.mon.hp > 0) {
        body(C);
        if (!truthy(C.missed)) anyLanded = true;
      }
      if (truthy(C.stopTargets)) break;
    }
    C.missed = !anyLanded;
    if (truthy(C.deferUserFaint)) {
      C.deferUserFaint = null;
      C.tryFaintUser();
    }
    return undefined;
  }
  if (ttype === T.BOTH) {
    const foes = B.foes(C.user);
    C.spread = foes.length > 1;
    const first = C.target;
    body(C);
    let firstMissed = C.missed;
    if (truthy(C.stopTargets)) return undefined;
    for (const b of foes) {
      if (b !== first && b.mon.hp > 0) {
        resetTargetValues(C);
        C.target = b;
        delete b.statLoweredMsg;
        body(C);
        // Lua `firstMissed = firstMissed and C.missed`
        firstMissed = truthy(firstMissed) ? C.missed : firstMissed;
      }
    }
    C.missed = firstMissed;
    return undefined;
  }
  return body(C);
}

// ------------------------------------------------------------------
// run (engine.lua run) and resolveMove
// ------------------------------------------------------------------

// pokefirered/src/battle_util.c:1874 ABILITYEFFECT_MOVES_BLOCK, which
// Cmd_attackcanceler runs for every target pass of a move (a spread move's
// second foe, a called move) -- BattleScript_SoundproofProtected, then the move
// end.  True when Soundproof stopped the move at this target.
function soundproofBlocked(C) {
  const { B, user, target } = C;
  C.soundproofSeen = target;
  if (!Abilities.soundproofBlocks((target !== user && truthy(target)) ? target : null, C.mnum)) return false;
  if (truthy(user.lockedNum)) C.noPP = true;
  C.attackString();
  C.ppReduce();
  B.emitAbility(target);
  B.say(`${B.nameOf(target)}'s SOUNDPROOF blocks ${C.moveName()}!`);
  C.missed = true;
  C.noEffect = true;
  moveEnd(C);
  return true;
}

function body(C) {
  const { B } = C;
  // Pursuit on a switching target skips attackcanceler whole (no Soundproof,
  // Magic Coat, Snatch, Lightning Rod or absorbing ability): battle_scripts_1.s
  // :3081 BattleScript_PursuitDmgOnSwitchOut.
  if (!truthy(C.opts.pursuit)) {
    if (C.soundproofSeen !== C.target && soundproofBlocked(C)) return;
    tryBounce(C);
    lightningRodTook(C);
    C.moveType = dynamicMoveType(C);
    if (absorbCheck(C)) {
      moveEnd(C);
      return;
    }
  }
  // The owner of the move context may have changed hands (Snatch / Magic Coat).
  const { user } = C;
  const eff = C.effect;
  if (eff === E.OHKO) {
    ohko(C);
    moveEnd(C);
    return;
  }
  if (eff === E.BIDE) {
    // pokefirered/data/battle_scripts_1.s:575
    C.attackString();
    C.ppReduce();
    C.attackAnimation();
    user.bideTurns = 2;
    user.bideDamage = 0;
    delete user.bideTarget;
    user.lockedNum = C.mnum;
    user.lockedSlot = C.slot;
    moveEnd(C);
    return;
  }
  // Future Sight / Doom Desire are delayed attacks on the cart even though they
  // have power (battle_scripts_1.s BattleScript_EffectFutureSight).
  if (int(C.move.power, 0) > 0 && eff !== E.FUTURE_SIGHT) {
    M.hit(C);
    moveEnd(C);
    return;
  }
  C.attackString();
  C.ppReduce();
  const handled = Effects.run(C);
  if (!truthy(handled)) {
    C.attackAnimation();
    B.say('But nothing happened!');
  }
  C.tryFaintTarget();
  C.tryFaintUser();
  moveEnd(C);
}

function run(C) {
  const { B, user } = C;
  const eff = C.effect;

  if (!truthy(C.opts.called)) {
    user.movedThisTurn = true;
  }
  // Pursuit on a switching target never meets the canceller: sleep / freeze /
  // Truant were checked when it was chosen to strike (Cmd_jumpifnopursuitswitchdmg)
  // and paralysis, confusion, love and flinching are not rolled at all
  // (battle_scripts_1.s:3081 has no attackcanceler).
  if (!truthy(C.opts.called) && !truthy(C.opts.pursuit)) {
    const c = canceller(C);
    if (c === false) {
      delete user.lastMoveNum;
      delete user.lastResultingNum;
      moveEndLite(C);
      return undefined;
    }
    if (c === 'bide') {
      bideAttack(C);
      moveEnd(C);
      return undefined;
    }
    // Soundproof at the first target (the rest are asked per target in
    // `body`); a doubles spread move asks every target there, the first too,
    // so one Soundproof foe does not stop the move for the other.
    const ttype = int(C.move.target, 0);
    const spread = truthy(B.double) && (ttype === T.BOTH || ttype === T.FOES_AND_ALLY);
    if (!spread && soundproofBlocked(C)) return undefined;
    if (truthy(C.slot) && truthy(at(user.moves, C.slot)) && int(at(user.moves, C.slot).pp, 0) === 0
        && !truthy(user.lockedNum) && C.mnum !== MOVE.STRUGGLE) {
      C.attackString();
      B.say('But there was no PP left for the move!');
      return undefined;
    }
    // Cmd_attackcanceler's IsMonDisobedient (engine.lua:1476): not for a move
    // already under way. A refusal ends the action as a canceller stop does; a
    // random pick runs as a called move from its slot, in place of the choice
    // (so it does not count against MAX_CALL_DEPTH).
    if (!truthy(user.lockedNum)) {
      const [d, slot] = B._disobey(C);
      if (d === 'stop') {
        delete user.lastMoveNum;
        delete user.lastResultingNum;
        moveEndLite(C);
        return undefined;
      }
      if (d === 'called') {
        return runCalled(C, at(user.moves, slot), slot, { sameDepth: true });
      }
    }
  }

  if (eff !== E.PROTECT && eff !== E.ENDURE) user.protectStreak = 0;

  if (chargeTurn(C)) {
    moveEnd(C);
    return undefined;
  }

  if (eff === E.METRONOME || eff === E.SLEEP_TALK || eff === E.MIRROR_MOVE || eff === E.ASSIST
      || eff === E.NATURE_POWER) {
    return callMoves(C);
  }

  if (eff === E.FOCUS_PUNCH && (int(user.lastPhysDmg, 0) > 0 || int(user.lastSpecDmg, 0) > 0)) {
    // pokefirered/data/battle_scripts_1.s:2255 (then BattleScript_MoveEnd)
    C.ppReduce();
    B.say(`${B.nameOf(user)} lost its focus and couldn't move!`);
    moveEnd(C);
    return undefined;
  }

  return forEachTarget(C, body);
}

// One move, start to finish (engine.lua resolveMove). `target` is already
// resolved; `opts` = { called, calledBy, pursuit, passSlot, chosenAlly, and for
// a called move callDepth, chosenSlot (the caller's), noPP (Sleep Talk) }.
Bm._resolveMove = function _resolveMove(user, target, row, slot, optsIn) {
  const opts = truthy(optsIn) ? optsIn : {};
  if (!truthy(user) || user.mon.hp <= 0 || user.fighter.b !== user) return undefined;
  const C = newCtx(this, user, target, row, slot, opts);
  C.passSlot = opts.passSlot;
  C.chosenAlly = opts.chosenAlly;
  // pret chosenMovePositions: the slot the seat chose, which a called move
  // inherits from its caller (Grudge empties that one).
  if (truthy(opts.called)) C.chosenSlot = opts.chosenSlot; else C.chosenSlot = slot;
  if (truthy(opts.noPP)) C.noPP = true;
  if (truthy(opts.called)) C.printedUsed = false;
  delete user.statLoweredMsg;
  if (truthy(target)) delete target.statLoweredMsg;
  if (!truthy(opts.called)) delete this.syncEffect;
  if (!truthy(target)) {
    // Nobody standing to aim at: the cart's "But there was no target..."
    C.attackString();
    C.ppReduce();
    this.say('But there was no target...');
    return C;
  }
  run(C);
  return C;
};

// pokefirered/src/battle_util.c:1208 (after every action that was not called):
// Intimidate / Trace, held-item checks (berries), Forecast -- one thing per
// pass, passes until nothing acts (the cart re-enters state 6 until it returns
// FALSE, so a 3v3 field's six Intimidates all resolve now).  M.PASS_CAP only
// bounds a runaway; every pass spends a pending flag, an item or a form change.
M.PASS_CAP = 64;
Bm._afterAction = function _afterAction() {
  if (truthy(this.result)) return;
  for (let pass = 1; pass <= M.PASS_CAP; pass += 1) {
    let did = false;
    did = truthy(did) ? did : Abilities.runIntimidate(this);
    did = truthy(did) ? did : Abilities.runTrace(this);
    if (!truthy(did)) {
      for (const b of this.active()) {
        if (truthy(Items.normal(this, b, true))) {
          did = true;
          break;
        }
      }
    }
    did = truthy(did) ? did : Abilities.forecast(this);
    if (!truthy(did)) break;
  }
};

// ==================================================================
// the action a seat chose (the engine's forced_move + resolveMove front end)
// ==================================================================

// Which move this action uses and from which slot: the locked move, then an
// Encore, then the Choice Band move, then Struggle, then the chosen slot.
// -> [row, slot, why] (slot and why may be null).
Bm._actionMove = function _actionMove(b, choice) {
  if (truthy(b.lockedNum)) {
    let slot = b.lockedSlot;
    let row = truthy(slot) ? at(b.moves, slot) : slot;
    if (!truthy(row) || int(row.num, 0) !== b.lockedNum) {
      row = this.calledRowByNum(b.lockedNum, b);
      slot = this.slotOfNum(b, b.lockedNum);
    }
    if (truthy(row)) return [row, slot, 'locked'];
  }
  if (truthy(choice.struggle) || !this.hasUsableMove(b)) {
    return [M.STRUGGLE, null, 'struggle'];
  }
  if (int(b.encoreTurns, 0) > 0 && truthy(b.encoreNum)) {
    const slot = this.slotOfNum(b, b.encoreNum);
    if (truthy(slot)) {
      const changed = slot !== choice.move;
      return [at(b.moves, slot), slot, changed ? 'encore' : null];
    }
  }
  if (truthy(b.choicedMove) && Items.has(b, Items.HOLD.CHOICE_BAND)) {
    const cur = at(b.moves, choice.move);
    if (truthy(cur) && int(cur.num, 0) !== b.choicedMove) {
      const cs = this.slotOfNum(b, b.choicedMove);
      if (truthy(cs) && int(at(b.moves, cs).pp, 0) > 0) return [at(b.moves, cs), cs, 'choice'];
    }
  }
  const row = at(b.moves, choice.move);
  if (!truthy(row)) return [M.STRUGGLE, null, 'struggle'];
  return [row, choice.move, null];
};

// A fight action. `opts.pursuit` marks a Pursuit resolved ahead of a switch.
Bm._fightAction = function _fightAction(fighter, choice, optsIn) {
  const opts = truthy(optsIn) ? optsIn : {};
  const user = fighter.b;
  if (!truthy(user) || user.mon.hp <= 0) return undefined;
  if (truthy(choice.recharge) && truthy(user.mustRecharge)) {
    // The recharge turn: the canceller says it; any move row will do.
    const last = at(user.moves, truthy(user.lastSlot) ? user.lastSlot : 1);
    const row = truthy(last) ? last : M.STRUGGLE;
    const firstFoe = this.foes(user)[0];
    const C = newCtx(this, user, truthy(firstFoe) ? firstFoe : user, row, null, {});
    user.movedThisTurn = true;
    canceller(C);
    return undefined;
  }
  const [row, slot, why] = this._actionMove(user, choice);
  let aimed = null;
  if (why === 'locked') {
    aimed = truthy(user.lockedTarget) ? user.lockedTarget : user.twoTurnTarget;
    if (int(row.target, 0) === T.RANDOM) aimed = null;
  } else if (choice.target != null) {
    const tf = this._fighterAtSlot(choice.target);
    aimed = (truthy(tf) && truthy(tf.b)) ? tf.b : null;
    if (aimed == null && truthy(tf)) aimed = tf.lastB;
  }
  let chosenAlly = null;
  if (truthy(aimed) && aimed.side === user.side && aimed !== user) chosenAlly = aimed;
  const target = this._pickTarget(user, row, aimed, why === 'encore', false);
  if (truthy(slot)) user.lastSlot = slot;
  // `mover`: whose action this is, for Oak's `stat` lesson (Effects.changeStat).
  const prev = this.mover;
  this.mover = user;
  const C = this._resolveMove(user, target, row, slot, {
    pursuit: opts.pursuit, passSlot: choice.pass, chosenAlly,
  });
  this.mover = prev;
  return C;
};

M.install = function install(Battle) {
  for (const k of Object.keys(Bm)) Battle.prototype[k] = Bm[k];
};

module.exports = M;
