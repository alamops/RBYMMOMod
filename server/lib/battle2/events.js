'use strict';

/*
 * The event vocabulary a mediated battle speaks, frozen -- Node half.
 *
 * Twin of src/BattleSim2/events.lua (kind-compatible with Gen1 / Wire), which is itself a mirror of src/Wire.lua's
 * `BATTLE_EVENTS` whitelist rather than an import of it. Three copies of one
 * vocabulary sounds like a mistake and is not: Wire pulls in Config, the Lua
 * sim has to run where Config does not, and this file has to run where Lua does
 * not. What holds them together is that the suites round-trip real events
 * through every copy -- tests/battle_sim_turn.lua against Wire, and
 * server/battle_turn.test.js against the Lua twin's own output.
 *
 * The field whitelist is the sharp edge. `build` rebuilds an event from a fixed
 * set of keys, so a field invented in the turn machine does not arrive at the
 * client looking optional -- it does not arrive at all, and the parity suite
 * sees the absence rather than a player seeing a blank line.
 *
 * Nothing here throws, and nothing here reads a clock: an event is a value.
 */

const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

// tonumber(), spelled out. Lua's coercion accepts a numeric string and refuses
// everything else including booleans, which `Number()` would happily turn into
// 0 and 1 -- so the type test comes first.
function toNumber(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (trimmed === '') return null;
    const n = Number(trimmed);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

// ------------------------------------------------------------------
// the closed set
// ------------------------------------------------------------------
//
// A subset of Wire.BATTLE_EVENTS, not a mirror of it exactly: `exp` is
// Gen1-only (see docs/plans/better-battle-ui.md R5-A2 -- Gen2 mediated stays
// exp-free, and only the Gen1 side carries a mirror-assertion test), so
// adding a kind to Wire does NOT automatically belong here. Adding a kind
// that *does* belong here is still a wire change: the Lua twin, Wire's
// whitelist and the screen all have to learn it in the same version, so the
// set is written out longhand rather than derived.
//
//   msg        -- a line of text for the box
//   anim       -- play a move's animation
//   damage     -- HP came off a slot
//   drain      -- ...and some of it went onto another one
//   faint      -- a slot is out
//   send       -- a slot's next monster is on the field
//   status     -- a condition was inflicted or cleared
//   stat       -- a stat stage moved
//   switch     -- a voluntary swap resolved
//   item       -- a bag item was used
//   run        -- somebody fled, or tried
//   turn       -- a new turn is open; choices are wanted
//   over       -- the field is done; an OUTCOME is coming
//   wait       -- the fight is paused on somebody, and who
//   reconnect  -- a side that had dropped is back
//   chose      -- a seat filed this turn's answer (wait-line peer accuracy)
//   unchose    -- cancel cleared a filed answer
//   moves      -- mid-fight move-list sync after Transform/Mimic
const KINDS = {
  msg: true, anim: true, damage: true, drain: true, faint: true,
  send: true, status: true, stat: true, switch: true, item: true,
  run: true, turn: true, over: true, wait: true, reconnect: true,
  chose: true, unchose: true, moves: true,
};

// Every key an event may carry, and the type it carries. `battle` and `seq` are
// stamped by the turn machine rather than passed to `build`, because a caller
// that could choose its own sequence number could put a hole in the stream, and
// a hole is what a client reads as lost messages.
const FIELDS = {
  battle: 'string',
  seq: 'number',
  t: 'string',
  text: 'string',
  amount: 'number',
  slot: 'number',
  hp: 'number',
  side: 'string',
  status: 'string',
};

// ------------------------------------------------------------------
// what each kind actually means
// ------------------------------------------------------------------
//
// The whitelist says what *may* be present; this table says what the turn
// machine promises to send. The two readings that are easy to get backwards:
//
//   * `slot` on an event is a **field slot** (0..3: side a takes 0 and 1, side
//     b takes 2 and 3) -- it is *not* the party index a `switch` choice names.
//   * a `status` event with a `status` field means the condition was
//     *inflicted*; the same event with no `status` field means it **cleared**.
//     `text` carries the sentence either way.
const SHAPES = {
  msg: { text: true },
  anim: { slot: true, side: true, text: 'move or ball-anim id',
    amount: 'shake count on SHAKE_ANIM (0-3)' },
  damage: {
    slot: true, side: true, amount: true, hp: 'hp left',
    status: 'set when a residual dealt it',
  },
  drain: { slot: true, side: true, amount: true, hp: true },
  faint: { slot: true, side: true, text: true,
    amount: '1 when the seat still has a living bench (mustReplace)' },
  send: { slot: true, side: true, hp: true, text: 'the species' },
  status: { slot: true, side: true, status: 'absent means cleared', text: true },
  stat: { slot: true, side: true, amount: true, text: true },
  switch: { slot: true, side: true, text: 'the species coming in' },
  item: { slot: true, side: true, text: 'the item id',
    amount: '1 when a vitamin applied (client save writeback)' },
  run: { slot: true, side: true, text: true },
  turn: { amount: 'the 1-based turn number' },
  over: { text: 'the reason token' },
  wait: { side: true, text: 'who is being waited on' },
  reconnect: { side: true, text: true },
  chose: { slot: true, side: true, text: 'who answered' },
  unchose: { slot: true, side: true, text: 'who answered' },
  moves: { slot: true, side: true, moves: 'sanitised move list' },
};

// ------------------------------------------------------------------
// field slots
// ------------------------------------------------------------------
//
// A 1v1 uses slots 0 and 2 and leaves the odd ones empty, which keeps one
// numbering across all three modes -- packing a 1v1 into 0 and 1 would make a
// client's "which box is this" change meaning with the mode.
const SIDE_SLOTS = 2;

function fieldSlot(side, index) {
  const base = side === 'b' ? SIDE_SLOTS : 0;
  let n = toNumber(index);
  if (n === null) n = 1;
  return base + Math.max(0, Math.floor(n) - 1);
}

const MOVE_FIELDS = {
  id: 'string', pp: 'number', power: 'number', accuracy: 'number',
  type: 'number', effect: 'number', chance: 'number',
};

function checkMove(move) {
  if (!move || typeof move !== 'object') return false;
  for (const key of Object.keys(MOVE_FIELDS)) {
    if (typeof move[key] !== MOVE_FIELDS[key]) return false;
  }
  return true;
}

function checkMoves(value) {
  if (!Array.isArray(value) || value.length < 1) return false;
  for (const move of value) {
    if (!checkMove(move)) return false;
  }
  return true;
}

// ------------------------------------------------------------------
// construction
// ------------------------------------------------------------------

// undefined means "drop it": not whitelisted, or not a usable value for the
// type this key carries.
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

/*
 * Builds one event, keeping only whitelisted keys that carry a usable value.
 *
 * Returns null for an unknown kind rather than throwing: the turn machine
 * treats null as "do not emit" and carries on, and the suites assert null never
 * happens for the kinds it actually sends.
 */
function build(kind, fields) {
  if (!own(KINDS, kind)) return null;
  const out = { t: kind };
  if (fields && typeof fields === 'object') {
    for (const key of Object.keys(fields)) {
      if (key === 'moves' && Array.isArray(fields.moves)) {
        out.moves = fields.moves;
      } else if (key === 't' || key === 'battle' || key === 'seq') {
        // stamped by the turn machine
      } else {
        const clean = coerce(key, fields[key]);
        if (clean !== undefined) out[key] = clean;
      }
    }
  }
  return out;
}

/*
 * True when an event is something Wire would accept: a known kind, a stamped
 * battle and seq, and not one stray key. Returns [ok, reason] so a failure can
 * say which key spoiled it.
 */
function check(event) {
  if (!event || typeof event !== 'object') return [false, 'not a table'];
  if (!own(KINDS, event.t)) return [false, 'unknown kind'];
  if (typeof event.battle !== 'string' || event.battle === '') {
    return [false, 'no battle id'];
  }
  if (typeof event.seq !== 'number' || event.seq < 0) return [false, 'no seq'];
  for (const key of Object.keys(event)) {
    if (key === 'moves') {
      if (!checkMoves(event.moves)) return [false, 'bad moves list'];
    } else if (!own(FIELDS, key)) {
      return [false, `field not in the whitelist: ${key}`];
    } else if (typeof event[key] !== FIELDS[key]) {
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
  build,
  check,
  toNumber,
};
