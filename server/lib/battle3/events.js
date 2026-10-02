'use strict';

/*
 * The event vocabulary a mediated Gen 3 battle speaks, frozen -- Node half.
 *
 * Twin of src/BattleSim3/events.lua, contract C5 (docs/plans/gen3-battle-sheet.md
 * §7). Every BattleSim2 kind is kept verbatim; Gen 3 adds seven kinds (`ability
 * weather held form sub ball obey`) and six fields (`target spread stat stage
 * delta holding`). Mirrored, not imported, for the reason lib/battle2/events.js
 * gives: Wire pulls in Config, the Lua sim runs where Config does not, and this
 * file runs where Lua does not. server/twin_parity.test.js holds the copies
 * together.
 *
 * `build` enforces the field whitelist at construction, so an invented field
 * fails the sim's own suite instead of vanishing at the Wire boundary.
 *
 * check -> [ok, why].
 *
 * Nothing here throws, and nothing here reads a clock: an event is a value.
 */

const { toNumber, isTable, own } = require('./lua.js');

// BattleSim2's twenty, then Gen 3's seven (see the Lua twin for the prose).
const KINDS = {
  msg: true,
  anim: true,
  damage: true,
  drain: true,
  faint: true,
  send: true,
  status: true,
  stat: true,
  switch: true,
  item: true,
  run: true,
  turn: true,
  over: true,
  wait: true,
  reconnect: true,
  chose: true,
  unchose: true,
  moves: true,
  exp: true,
  team: true,
  ability: true,
  weather: true,
  held: true,
  form: true,
  sub: true,
  ball: true,
  obey: true,
};

// Every key an event may carry, and its type. `battle` / `seq` are stamped by
// the turn machine, never passed in. The last six are Gen 3's.
const FIELDS = {
  battle: 'string',
  seq: 'number',
  t: 'string',
  text: 'string',
  amount: 'number',
  slot: 'number',
  hp: 'number',
  maxHp: 'number',
  side: 'string',
  status: 'string',
  species: 'string',
  speciesId: 'string',
  level: 'number',
  participants: 'number',
  mon: 'number',
  team: 'string',
  confused: 'number',
  target: 'number',
  spread: 'number',
  stat: 'string',
  stage: 'number',
  delta: 'number',
  holding: 'number',
};

// What each kind promises (docs/plans/gen3-battle-sheet.md §7 is the prose).
const SHAPES = {
  msg: { text: true },
  anim: {
    slot: true,
    side: true,
    text: 'move id',
    amount: '1 on a charge turn',
    target: "the move's first target (field slot), when it has one",
    spread: '1 when the animation covers several targets',
  },
  damage: {
    slot: true, side: true, amount: true, hp: 'hp left', status: 'set when a residual dealt it',
  },
  drain: {
    slot: true, side: true, amount: true, hp: true,
  },
  faint: {
    slot: true, side: true, text: true, amount: '1 when the seat still has a living bench (mustReplace)',
  },
  send: {
    slot: true,
    side: true,
    hp: true,
    maxHp: true,
    text: 'the species',
    speciesId: true,
    level: true,
    mon: 'party index',
    status: true,
    confused: true,
  },
  status: {
    slot: true, side: true, status: 'absent means cleared', text: true, confused: '1 inflicted, 0 snapped out',
  },
  stat: {
    slot: true, side: true, text: true, stat: true, stage: true, delta: true,
  },
  switch: {
    slot: true, side: true, text: true, speciesId: true, level: true, mon: true,
  },
  item: { slot: true, side: true, text: 'the numeric item id, as a string' },
  run: { slot: true, side: true, text: true },
  turn: { amount: 'the 1-based turn number', slot: 'present only on a replacement solicitation' },
  over: { text: 'the reason token' },
  wait: { side: true, text: true },
  reconnect: { side: true, text: true },
  chose: { slot: true, side: true, text: true },
  unchose: { slot: true, side: true, text: true },
  moves: {
    slot: true,
    side: true,
    moves: 'Gen 3 move rows',
    mon: 'party index on a PP change; absent on a Transform / Mimic overlay',
  },
  exp: {
    slot: true, species: true, speciesId: true, level: true, participants: true, mon: true,
  },
  team: { slot: true, side: true, team: 'o / s / x per party member' },
  ability: {
    slot: true, side: true, amount: 'ability id', text: 'ability name',
  },
  weather: {
    text: 'RAIN | SUN | SAND | HAIL', amount: '1 start, 2 continue, 0 end', slot: 'who started it', side: 'who started it',
  },
  held: {
    slot: true,
    side: true,
    mon: 'party index',
    amount: 'the item that acted',
    holding: 'held item id afterwards (0 none)',
    text: 'item name',
  },
  form: {
    slot: true,
    side: true,
    amount: 'Castform form 0..3',
    speciesId: 'Transform: the copied species',
    text: 'Transform: its name',
  },
  sub: { slot: true, side: true, amount: '1 made, 0 faded' },
  ball: {
    slot: 'thrower', side: true, target: 'wild slot', amount: 'shakes 0..3, 4 = caught', text: 'ball item id',
  },
  obey: { slot: true, side: true, text: 'the outcome token' },
};

// ------------------------------------------------------------------
// field slots (BattleSim2's numbering, unchanged)
// ------------------------------------------------------------------

const SIDE_SLOTS = 3;

function fieldSlot(side, index) {
  const base = (side === 'b') ? SIDE_SLOTS : 0;
  let n = toNumber(index);
  if (n === null) n = 1;
  return base + Math.max(0, Math.floor(n) - 1);
}

// ------------------------------------------------------------------
// team rosters (token-for-token with BattleSim2)
// ------------------------------------------------------------------

const TEAM_OK = 'o';
const TEAM_STATUS = 's';
const TEAM_FAINTED = 'x';
const TEAM_TOKENS = { o: true, s: true, x: true };

function teamToken(mon) {
  if (!isTable(mon)) return null;
  const hp = toNumber(mon.hp);
  if ((hp === null ? 0 : hp) <= 0) return TEAM_FAINTED;
  if (typeof mon.status === 'string' && mon.status !== '') return TEAM_STATUS;
  return TEAM_OK;
}

function teamString(mons) {
  if (!isTable(mons)) return '';
  let out = '';
  for (let i = 0; i < mons.length; i += 1) {
    out += teamToken(mons[i]) || TEAM_FAINTED;
  }
  return out;
}

// ------------------------------------------------------------------
// move rows on a `moves` event
// ------------------------------------------------------------------

const MOVE_FIELDS = {
  id: 'string',
  num: 'number',
  pp: 'number',
  maxPp: 'number',
  power: 'number',
  accuracy: 'number',
  type: 'number',
  effect: 'number',
  chance: 'number',
  target: 'number',
  priority: 'number',
  flags: 'number',
};

function checkMove(move) {
  if (!isTable(move)) return false;
  for (const key of Object.keys(MOVE_FIELDS)) {
    if (typeof move[key] !== MOVE_FIELDS[key]) return false;
  }
  if (move.name !== undefined && move.name !== null && typeof move.name !== 'string') return false;
  for (const key of Object.keys(move)) {
    if (move[key] === undefined || move[key] === null) continue;
    if (key !== 'name' && !own(MOVE_FIELDS, key)) return false;
  }
  return true;
}

function checkMoves(value) {
  if (!Array.isArray(value)) return false;
  for (const move of value) {
    if (!checkMove(move)) return false;
  }
  return value.length > 0;
}

// ------------------------------------------------------------------
// construction
// ------------------------------------------------------------------

function coerce(key, value) {
  if (key === 'moves') return undefined;
  if (!own(FIELDS, key)) return undefined;
  if (FIELDS[key] === 'number') {
    const n = toNumber(value);
    if (n === null) return undefined;
    return Math.floor(n);
  }
  if (typeof value !== 'string' || value === '') return undefined;
  return value;
}

// Builds one event, keeping only whitelisted keys that carry a usable value;
// null for an unknown kind (the turn machine treats null as "do not emit").
function build(kind, fields) {
  if (!own(KINDS, kind)) return null;
  const out = { t: kind };
  if (isTable(fields)) {
    for (const key of Object.keys(fields)) {
      const value = fields[key];
      if (key === 'moves' && isTable(value)) {
        out.moves = value;
      } else if (key !== 't' && key !== 'battle' && key !== 'seq') {
        const clean = coerce(key, value);
        if (clean !== undefined) out[key] = clean;
      }
    }
  }
  return out;
}

// [true, null] when an event is one Wire (with the Gen 3 additions) would
// accept, else [false, why].
function check(event) {
  if (!isTable(event)) return [false, 'not a table'];
  if (!own(KINDS, event.t)) return [false, 'unknown kind'];
  if (typeof event.battle !== 'string' || event.battle === '') {
    return [false, 'no battle id'];
  }
  if (typeof event.seq !== 'number' || event.seq < 0) return [false, 'no seq'];
  for (const key of Object.keys(event)) {
    const value = event[key];
    if (value === undefined || value === null) continue;
    if (key === 'moves') {
      if (!checkMoves(value)) return [false, 'bad moves list'];
    } else if (!own(FIELDS, key)) {
      return [false, `field not in the whitelist: ${key}`];
    } else if (typeof value !== FIELDS[key]) {
      return [false, `wrong type for ${key}`];
    }
  }
  return [true, null];
}

module.exports = {
  KINDS,
  FIELDS,
  SHAPES,
  SIDE_SLOTS,
  fieldSlot,
  TEAM_OK,
  TEAM_STATUS,
  TEAM_FAINTED,
  TEAM_TOKENS,
  teamToken,
  teamString,
  MOVE_FIELDS,
  build,
  check,
  toNumber,
};
