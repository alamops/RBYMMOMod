'use strict';

/*
 * The event vocabulary a mediated battle speaks, frozen -- Node half.
 *
 * Twin of src/BattleSim/events.lua, which is itself a mirror of src/Wire.lua's
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
// Mirrors Wire.BATTLE_EVENTS exactly. Adding a kind is a wire change: the Lua
// twin, Wire's whitelist and the screen all have to learn it in the same
// version, so the set is written out longhand rather than derived.
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
//   exp        -- a faint's spoils, as facts: who fell (species, level), how
//                 many shares split it, and which of the paid side's six banks
//                 this share (`mon`). Never an amount: the intermediator holds
//                 no species table, so each client runs its own formula over
//                 its own party.
//   team       -- a seat's party roster, as ball states: how many monsters it
//                 brought and which of them are healthy / statused / down.
//                 The referee is the only party to a mediated fight that holds
//                 every party, so it is the only one that can say this about
//                 the seat *opposite* -- and the roster chip on the arena is
//                 the whole reason it is said. Deliberately states nothing else
//                 about a bench monster: no species, no level, no moves. The
//                 classic ball row reveals exactly this much and no more, and a
//                 hub that leaked a bench sheet would be handing one player the
//                 other's team preview.
const KINDS = {
  msg: true, anim: true, damage: true, drain: true, faint: true,
  send: true, status: true, stat: true, switch: true, item: true,
  run: true, turn: true, over: true, wait: true, reconnect: true,
  chose: true, unchose: true, moves: true, exp: true, team: true,
};

// Every key an event may carry, and the type it carries. `battle` and `seq` are
// stamped by the turn machine rather than passed to `build`, because a caller
// that could choose its own sequence number could put a hole in the stream, and
// a hole is what a client reads as lost messages.
//
// `species`, `level`, `participants` and `mon` are the `exp` event's facts.
// They are separate keys rather than a reuse of `text` / `amount` because they
// travel together into a formula: a client that read a species out of `text`
// would be reading the same field a faint uses for a sentence, and the first
// build to change one of those sentences would silently change an award.
//
// `mon` is the one key here that is a **party** index (0..5) rather than a
// field slot: vanilla pays every mon that fought the fallen foe and lived,
// benched included, and a benched one has no field slot to name. It rides
// alongside `slot`, which stays the owning fighter's seat.
//
// `send` and `switch` carry it for a different reason: they used to name the
// monster coming in by species alone, and a party holding two of a species has
// no way to say which. A client resolving the name picked the first match,
// which is how a fainted duplicate walked back onto the field. The referee
// already knows the index it chose, so it says it.
//
// `maxHp` rides on `send`, and it is the field whose absence used to be read as
// a value. An event states current HP; a client had no other handle on what a
// bar was out of, so it took the largest HP it had ever seen for that seat as
// the maximum -- correct for a monster that walks out whole, and wrong for
// every one that does not. A party mon that ended the last fight on 42 of 200
// opened the next one drawing a *full* bar over the number 42. The referee
// holds the real maximum from the moment it builds the battler, so it says it,
// and the guess stays behind only as the fallback for a stream that carries
// none.
//
// `status` rides on `send` for the same walk-in reason. A `status` *event* is
// an inflict or a lift; a monster that *arrived* poisoned is not an event, it
// is a fact about the occupant, and without it on the send the plate draws a
// healthy card over a condition the referee has been fighting with since
// `create`.
//
// `confused` is the fight-local volatile (not a Wire.STATUSES token): 1 on
// send when the newcomer is already confused, and 1/0 on a status event for
// inflict / snap-out. It never occupies `status`, so PSN and confusion coexist.
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
};

// ------------------------------------------------------------------
// what each kind actually means
// ------------------------------------------------------------------
//
// The whitelist says what *may* be present; this table says what the turn
// machine promises to send. The two readings that are easy to get backwards:
//
//   * `slot` on an event is a **field slot** (0..5: side a takes 0..2, side
//     b takes 3..5) -- it is *not* the party index a `switch` choice names.
//   * a `status` event with a `status` field means the condition was
//     *inflicted*; the same event with no `status` field means it **cleared**.
//     `text` carries the sentence either way.
//
// `turn` carries a second, optional reading, and it is the client contract for
// the referee's replace phase:
//
//   * `turn` **with** `slot` is a *replacement solicitation* -- the seat at that
//     field slot fainted with a bench left and is being asked for a send-out.
//     Its own client opens the switch picker, every other client holds on
//     "X is choosing who to send out...", and no menu opens for anybody else.
//     One is emitted per owing seat, in ascending field-slot order, and the
//     turn number does not advance for it (`amount` repeats the turn the faint
//     happened on).
//   * `turn` **without** `slot` is the ordinary choice window opening.
//
// It is deliberately expressed in a field the whitelist already carried: a
// client written before the replace phase existed ignores `slot` and reads both
// as "a turn opened", which is exactly the behaviour it had.
const SHAPES = {
  msg: { text: true },
  anim: { slot: true, side: true, text: 'move or ball-anim id',
    amount: 'shake count on SHAKE_ANIM (0-3)' },
  damage: {
    slot: true, side: true, amount: true, hp: 'hp left',
    status: 'set when a residual dealt it',
  },
  drain: { slot: true, side: true, amount: true, hp: true,
    maxHp: 'set only when an HP UP moved the ceiling itself' },
  faint: { slot: true, side: true, text: true,
    amount: '1 when the seat still has a living bench (mustReplace)' },
  send: { slot: true, side: true, hp: true,
    maxHp: 'what that HP is out of, so the bar is a fraction rather than a guess',
    text: 'the species',
    speciesId: 'registry id for the art, when the sheet named one',
    level: "the monster's level, for the seat opposite's pill",
    mon: 'party index (0-5) of the mon the referee fielded',
    status: "the newcomer's condition when it already has one; absent is healthy",
    confused: '1 when the newcomer is confused (a volatile, not a standing status)' },
  status: { slot: true, side: true, status: 'absent means cleared', text: true,
    confused: '1 inflicted, 0 snapped out; independent of status' },
  stat: { slot: true, side: true, amount: true, text: true },
  switch: { slot: true, side: true, text: 'the species coming in',
    speciesId: 'registry id for the art, when the sheet named one',
    level: "the monster's level, for the seat opposite's pill",
    mon: 'party index (0-5) of the mon coming in' },
  item: { slot: true, side: true, text: 'the item id',
    amount: '1 when a vitamin applied (client save writeback)' },
  run: { slot: true, side: true, text: true },
  turn: { amount: 'the 1-based turn number',
    slot: 'present only on a replacement solicitation: the field slot being asked' },
  over: { text: 'the reason token' },
  wait: { side: true, text: 'who is being waited on' },
  reconnect: { side: true, text: true },
  chose: { slot: true, side: true, text: 'who answered' },
  unchose: { slot: true, side: true, text: 'who answered' },
  moves: { slot: true, side: true, moves: 'sanitised move list' },
  exp: { slot: 'the winner being paid', species: 'the monster that fell',
    speciesId: 'its registry id, when the sheet named one',
    level: 'its level', participants: 'how many shares split it',
    mon: 'party index (0-5) of the mon banking this share; absent means the active one' },
  team: { slot: 'the seat whose roster this is', side: true,
    team: 'one token per party member, in party order: o / s / x' },
};

// ------------------------------------------------------------------
// field slots
// ------------------------------------------------------------------
//
// A 1v1 uses slots 0 and 3 and leaves the middle ones empty, which keeps one
// numbering across all modes -- packing a 1v1 into 0 and 1 would make a
// client's "which box is this" change meaning with the mode. Side a is 0..2,
// side b is 3..5 (SIDE_SLOTS = Config.COOP_SIDE).
const SIDE_SLOTS = 3;

function fieldSlot(side, index) {
  const base = side === 'b' ? SIDE_SLOTS : 0;
  let n = toNumber(index);
  if (n === null) n = 1;
  return base + Math.max(0, Math.floor(n) - 1);
}

// ------------------------------------------------------------------
// team rosters
// ------------------------------------------------------------------
//
// One character per party member, in party order:
//
//   o  -- standing, and nothing wrong with it
//   s  -- standing, carrying a status
//   x  -- down
//
// Three tokens and no fourth, because the fourth ball the classic row draws
// ("this slot is empty") is not a party member at all -- it is the *absence* of
// one, and the roster says that by being short. A five-mon party is five
// characters; the renderer pads. That is what keeps the length meaningful:
// the roster's length is the party size, which is the first half of the
// question this event exists to answer.
const TEAM_OK = 'o';
const TEAM_STATUS = 's';
const TEAM_FAINTED = 'x';
const TEAM_TOKENS = { o: true, s: true, x: true };

// A monster's ball state. Fainted first: a fainted monster's status field is
// still whatever put it there in the original, and asking about the status
// first would draw a down monster as merely poisoned.
function teamToken(mon) {
  if (!mon || typeof mon !== 'object') return null;
  const hp = toNumber(mon.hp);
  if (hp === null || hp <= 0) return TEAM_FAINTED;
  if (typeof mon.status === 'string' && mon.status !== '') return TEAM_STATUS;
  return TEAM_OK;
}

// The whole roster, as one string. A member this cannot describe is `x` rather
// than dropped: dropping would shorten the roster, and the length is the party
// size -- a monster nobody can read is still a monster the seat brought, and
// drawing it as spent is the reading that never overstates what the other
// player has left.
function teamString(mons) {
  if (!Array.isArray(mons)) return '';
  let out = '';
  for (let i = 0; i < mons.length; i += 1) {
    out += teamToken(mons[i]) || TEAM_FAINTED;
  }
  return out;
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
  TEAM_OK,
  TEAM_STATUS,
  TEAM_FAINTED,
  TEAM_TOKENS,
  teamToken,
  teamString,
  build,
  check,
  toNumber,
};
