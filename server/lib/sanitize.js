'use strict';

/*
 * Everything here is untrusted: a client is somebody else's process, and a
 * modified one is a normal thing to encounter. Every field is re-derived
 * rather than checked in place.
 *
 * This is the Node half of src/Wire.lua. The two must agree, because the
 * same client talks to a dedicated hub and to a game hosting from inside
 * itself, and a field that only one of them accepts is a bug that only
 * shows up on one of the two hosting paths.
 */

const TEXT_OK = /[^A-Za-z0-9 .,!?'\-:;()/]/g;
const Effects = require('./battle/Effects');

function cleanText(value, limit) {
  if (typeof value !== 'string') return null;
  const clean = value.replace(TEXT_OK, '').replace(/\s+/g, ' ').trim();
  if (!clean) return null;
  return clean.slice(0, limit);
}

function cleanId(value) {
  if (typeof value !== 'string') return null;
  return /^[\w-]{1,40}$/.test(value) ? value : null;
}

// A sprite id is an engine identifier (SPRITE_RED), not prose. cleanText
// strips the underscore, turning it into SPRITERED, which then misses the
// catalog lookup and draws every player as the fallback -- invisibly,
// because the fallback works.
function cleanSpriteId(value) {
  if (typeof value !== 'string') return null;
  return /^\w{1,40}$/.test(value) ? value : null;
}

function cleanMapId(value) {
  if (typeof value !== 'string') return null;
  return /^[\w.-]{1,64}$/.test(value) ? value : null;
}

function cleanInt(value, min, max) {
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  const i = Math.floor(n);
  return i >= min && i <= max ? i : null;
}

// An HMAC response off the wire. Lowercase only, because that is what both
// Node's crypto and the mod's pure-Lua digest produce, and accepting the
// other case would mean two spellings of the same credential.
const HEX_MAX = 128;

function cleanHex(value, maxLen) {
  if (typeof value !== 'string') return null;
  const limit = maxLen === undefined ? HEX_MAX : maxLen;
  if (value.length > limit) return null;
  return /^[0-9a-f]+$/.test(value) ? value : null;
}

// The raw shape of a join code as typed. Uppercase alphanumeric plus the
// group separator is exactly what the mod's naming grid can produce
// (src/Ui.lua has no lowercase), so anything else was not typed in game.
// Normalising -- folding case, dropping the dashes -- belongs to auth.js;
// this only answers whether the field is the right shape to hand on.
function cleanCode(value) {
  if (typeof value !== 'string') return null;
  return /^[A-Z0-9-]{1,32}$/.test(value) ? value : null;
}

// The trainer-card fields a player shows other players.
//
// Every one is re-derived like anything else off the wire: these are drawn
// straight onto a card, so a hostile client could otherwise put a wild
// number in front of somebody. A field that fails is simply absent -- the
// profile screen says so plainly rather than rendering zeros as though they
// were real -- so a bad profile costs the card, never the connection.
//
// Bounds are Wire.profile's, field for field (src/Wire.lua:162-173). Money
// is deliberately not carried: the card never shows it, so a peer that
// sends one is ignored rather than having it stored and forwarded.
function cleanProfile(value) {
  if (value === null || typeof value !== 'object') return null;
  return {
    idNo: cleanInt(value.idNo, 0, 65535),
    badges: cleanInt(value.badges, 0, 99),
    seen: cleanInt(value.seen, 0, 9999),
    owned: cleanInt(value.owned, 0, 9999),
    playtime: cleanInt(value.playtime, 0, 999 * 3600),
  };
}

// Relay payloads are forwarded unread, so shape is all that can be judged.
// Iterative on purpose: a recursive check would blow the same stack it is
// meant to protect. Mirrors Wire.payloadOk on the Lua side.
const PAYLOAD_MAX_DEPTH = 32;
const PAYLOAD_MAX_NODES = 4096;

function payloadOk(value) {
  if (value === null || typeof value !== 'object') return false;
  const stack = [[value, 1]];
  let nodes = 0;
  while (stack.length) {
    const [node, depth] = stack.pop();
    if (depth > PAYLOAD_MAX_DEPTH) return false;
    for (const child of Object.values(node)) {
      if (++nodes > PAYLOAD_MAX_NODES) return false;
      if (child !== null && typeof child === 'object') {
        stack.push([child, depth + 1]);
      }
    }
  }
  return true;
}

const FACINGS = new Set(['up', 'down', 'left', 'right']);
const KINDS = new Set(['trade', 'battle']);
const SCOPES = new Set(['global', 'local', 'private', 'party']);

// You and one friend. The rules that make a party feel solid all follow from
// the pair -- an invite is only offered when both sides are unattached, and
// either member leaving ends it for both -- so this is the design, not a
// first step towards six. Kept in step with Config.PARTY_MAX.
const PARTY_MAX = 2;

// What a client may claim about a battle it just finished. 'draw' is a real
// answer rather than a refusal to answer: a dropped link, a mutual run and a
// desync all end that way, and all three score nothing.
//
// 'forfeit' arrived with the mediated battles at the bottom of this file, and
// it is the one value here that no client is believed about: it is said by an
// intermediator that watched a reconnect grace run out, on mmo.battle_outcome.
// It joins the same set rather than getting one of its own because one word
// for one idea is easier to keep in step across two hub implementations than
// two spellings of it -- and admitting it to the legacy mmo.result path buys
// nobody anything, because settleMatch pays out only on an explicit win/loss
// pair. A client claiming 'forfeit' there lands in the same "two clients
// telling different stories" branch a disagreement already lands in, and
// scores nothing, which is the same denial it already had by claiming 'win'.
const OUTCOMES = new Set(['win', 'loss', 'draw', 'forfeit']);

function cleanOutcome(value) {
  return OUTCOMES.has(value) ? value : null;
}

/*
 * A rating on its way out to a client. Bounded here as well as in rank.js so
 * the field on the wire is the field src/Wire.lua's Wire.points will accept:
 * a hub that sent a number outside the range would have it silently read as
 * zero on every card that drew it.
 */
const RANK_MAX = 9999;
// Persistent player identity (PROTOCOL 16): 16 random bytes as lowercase hex.
// Mirrors Config.PLAYER_ID_HEX and Wire.playerId on the Lua side.
const PLAYER_ID_HEX = 32;

function cleanPlayerId(value) {
  const hex = cleanHex(value, PLAYER_ID_HEX);
  return hex && hex.length === PLAYER_ID_HEX ? hex : null;
}

function cleanPoints(value) {
  const n = cleanInt(value, 0, RANK_MAX);
  return n === null ? 0 : n;
}

const NAME_MAX = 10;
const MESSAGE_MAX = 60;
// A message of the day is written once by an operator and read by everyone
// who joins, so it gets more room than a chat line -- but the same charset
// and the same collapse to a single line, because it lands in the same
// scrollback and is drawn by the same code.
const MOTD_MAX = 120;
const LOCAL_RADIUS = 12;
const MAX_LINE = 64 * 1024;

// One row of a party's members list. Mirrors Wire.member: identity only,
// never position -- where a member is standing already arrives several times
// a second as mmo.move, and a stale second copy would give the members
// screen an answer that visibly disagreed with the map.
function cleanMember(value) {
  if (value === null || typeof value !== 'object') return null;
  const id = cleanId(value.id);
  const name = cleanText(value.name, NAME_MAX);
  if (!id || !name) return null;
  return { id, name };
}

// The identity of one fight, as two partners standing in front of it derive
// it. Mirrors Wire.battleKey.
//
// The ':' and '|' are the point: the key is map and trainer joined with a
// separator, and cleanText would strip that separator and collapse two
// different trainers on one map into the same key -- which is the one thing
// this value exists to tell apart. So it gets a pattern of its own rather
// than borrowing the prose one.
const COOP_KEY_MAX = 64;

// What a fight is called, as opposed to what identifies it. Prose, so it
// borrows cleanText -- but with its own limit, because a trainer class is not
// a player name and NAME_MAX cuts "BUG CATCHER" to "BUG CATCHE".
const COOP_LABEL_MAX = 16;

function cleanLabel(value) {
  return cleanText(value, COOP_LABEL_MAX);
}

function cleanBattleKey(value) {
  if (typeof value !== 'string') return null;
  if (value.length > COOP_KEY_MAX) return null;
  return /^[\w.\-:|]+$/.test(value) ? value : null;
}

// Which side of a co-op battle somebody is on, and why an offer or an ask
// ended. Both are closed sets rather than free text: each value picks a
// different sentence on the client, and an unknown one has to degrade to the
// vague case rather than being printed raw.
const SIDES = { a: true, b: true };
const COOP_REASONS = {
  alone: true, left: true, started: true, no: true, gone: true, timeout: true,
};

function cleanSide(value) {
  return SIDES[value] ? value : null;
}

/*
 * The five things worth telling a travelling partner about, and what each one
 * needs in order to say it: 'mon' is a species and a level, 'trainer' is the
 * name the game shows on the opponent. Mirrors Wire.PARTY_EVENTS, because the
 * same client talks to this hub and to a game hosting from inside itself, and
 * a kind only one of them accepts is a note that arrives on one hosting path
 * and vanishes on the other.
 *
 * A Map rather than an object literal, and that is not a style choice: with a
 * literal, `kind: 'constructor'` finds Object's own property, reads as a
 * required-field group, and would be forwarded as a kind no Lua client can
 * draw -- Lua tables carry no prototype, so the two ends would disagree about
 * whether the message exists at all.
 */
const PARTY_EVENTS = new Map([
  ['defeat_wild', 'mon'],
  ['defeated_by_wild', 'mon'],
  ['capture', 'mon'],
  ['defeat_trainer', 'trainer'],
  ['defeated_by_trainer', 'trainer'],
]);

// Gen 1's cap. A bound on a number that is about to be printed on somebody
// else's screen rather than a rule about the game.
const LEVEL_MAX = 100;

/*
 * One thing that happened to a party member, rebuilt or refused whole.
 *
 * Carries only the fields the kind names, so a wild event can never travel
 * with a trainer on it: the client picks its sentence off `kind`, and a stray
 * field is one more thing that could disagree with the line being drawn. The
 * required fields are part of the kind rather than a check beside it, because
 * a half-filled event is the failure that reaches a player -- 'ANN defeated'
 * with nothing after it is a sentence that stops mid-way.
 *
 * `name` is deliberately not read here. The hub stamps it from the connection
 * the message arrived on, because it is the only identifying field in the
 * event and the whole thing is drawn as a sentence about a named player.
 */
function cleanPartyEvent(value) {
  if (value === null || typeof value !== 'object') return null;
  const needs = PARTY_EVENTS.get(value.kind);
  if (!needs) return null;

  if (needs === 'mon') {
    // Species is prose on its way into a line, and it gets NAME_MAX rather
    // than the label limit: a species and a trainer nick have the same room
    // on screen. Mirrors Wire.partyEvent field for field.
    const species = cleanText(value.species, NAME_MAX);
    const level = cleanInt(value.level, 1, LEVEL_MAX);
    if (!species || level === null) return null;
    return { kind: value.kind, species, level };
  }

  // ...and a trainer gets COOP_LABEL_MAX, because what arrives is the class
  // the game shows and NAME_MAX cuts 'BUG CATCHER' to 'BUG CATCHE'.
  const trainer = cleanLabel(value.trainer);
  if (!trainer) return null;
  return { kind: value.kind, trainer };
}

function cleanCoopReason(value) {
  return COOP_REASONS[value] ? value : null;
}

/*
 * ---------------------------------------------------------- mediated battles
 *
 * PROTOCOL 10's vocabulary: the seven types a fight uses once an
 * *intermediator* -- this hub, or a LAN game's host process -- owns the
 * simulation instead of one of the two clients.
 *
 *   mmo.battle_ruleset    host client -> intermediator. The type chart and the
 *                         global constants this one match runs under, uploaded
 *                         once. Ephemeral on purpose: nothing ROM-derived is
 *                         stored, and a modded chart is a thing two players
 *                         may agree on without either of them shipping it.
 *   mmo.battle_party      each combatant -> intermediator. The sheet they are
 *                         fighting with: stats, moves and the fields needed to
 *                         resolve them, status, HP, level, IVs and EVs.
 *   mmo.battle_ready      intermediator -> clients. The field is confirmed and
 *                         the first turn is open.
 *   mmo.battle_choice     client -> intermediator. One turn's action.
 *   mmo.battle_event      intermediator -> clients. The ordered stream a
 *                         client draws; `seq` is what makes it ordered.
 *   mmo.battle_outcome    intermediator -> clients. The *sole* result, which
 *                         is the whole point: it replaces the two-client
 *                         mmo.result vote for these fights.
 *   mmo.battle_reconnect  client -> intermediator. Rejoin inside the grace.
 *
 * Everything below is the Node half of the matching sanitisers in
 * src/Wire.lua, and the reason for that mirror is the one at the top of this
 * file, sharpened: a battle is now *decided* by whichever intermediator
 * happens to own it, so a field one of the two accepts and the other refuses
 * is not a cosmetic difference -- it is the same sheet producing a fight on
 * one hosting path and a refusal on the other.
 *
 * Two rules run through the lot:
 *
 *  - **A sheet is bounded, not believed.** Every ceiling here exists so that one
 *    client cannot make the process the weapon -- a 400-row type chart, a party
 *    of two hundred -- not so that it cannot cheat. Inflated sheets are a known,
 *    accepted v1 cost (see the README); what sanitising buys is coherence, so
 *    that every fight resolves and ends.
 *  - **Bounds and shapes are mirrored; judgement is not invented.** Where
 *    Wire.lua refuses a whole message this refuses the whole message, where it
 *    drops a field this drops the field, and where it declines to check something
 *    -- a chart's squareness, a cell against EFF_MULTS -- so does this. A rule
 *    that exists in only one of the two sanitisers is not caution, it is the
 *    divergence above wearing a helpful face: a sheet this hub refuses and a LAN
 *    host fights.
 *
 * The line that split between drop and refuse is worth holding on to, because it
 * is not uniform: a *message* whose optional field is present and unreadable is
 * refused whole (a party's `side`, a mon's `ivs`, a ruleset's `seed`), while an
 * **event** drops any optional field of its own -- see cleanBattleEvent for why a
 * hole in an ordered stream is worse than a blank in a sentence.
 */

/*
 * The type chart's ceilings, and the scale its cells are written on.
 *
 * Integer percent rather than a float, because this number crosses a JSON
 * boundary into two languages and is then multiplied into a damage figure: 0.5
 * and 2 survive that trip, but a chart carrying 0.1 would round differently on
 * the two ends and the same attack would do different damage depending on who
 * was hosting.
 *
 * EFF_MULTS names the six multipliers a Gen 1 chart is built out of and is
 * deliberately **not** a gate, matching Wire.lua's chartOf, which bounds a cell
 * and does not check membership. The reason is the legal posture rather than
 * laziness: the chart arrives from a player's own decoded data, a pack may
 * legitimately rebalance a matchup to 75, and refusing it would drop a coherent
 * modded ruleset in the name of catching a malformed one. Gen 1's own cells only
 * ever hold 0, 50, 100 or 200 -- the quarter and the quadruple come out of
 * composing two of them against a dual type, in the sim, not out of the chart.
 * It is exported for the sim and the fixtures to read, not to enforce here.
 *
 * The names mirror Wire.lua's, including the pairing that reads oddly out of
 * context: BATTLE_TYPE_MAX is how many *types* a chart may describe, while
 * CHART_MAX is the largest value one *cell* may hold.
 */
const EFF_NEUTRAL = 100;
const CHART_MAX = 400;
const EFF_MULTS = new Set([0, 25, 50, EFF_NEUTRAL, 200, CHART_MAX]);

// How many types a chart may describe. Gen 1 has fifteen; the slack is for a
// data pack that adds some, since a cap of exactly fifteen would refuse the
// modded ruleset rather than the malformed one. Mirrors Config.BATTLE_TYPE_MAX.
const BATTLE_TYPE_MAX = 20;
// Cap on ephemeral Metronome pools (mirrors Config.BATTLE_METRONOME_POOL_MAX).
const METRONOME_POOL_MAX = 200;

// The type a *move* may name, bounded generously and independently of the
// chart's width on purpose: a party naming a type the uploaded chart has no row
// for is still a well-formed party, and the sim reads that gap as neutral.
// Refusing somebody's whole team over one mismatched index would be a far worse
// answer.
const MOVE_TYPE_MAX = 31;

// The seed an authority client may propose, 1..2^30 -- the width src/link's own
// shared seeds use. The lower bound is 1 rather than 0 because 0 is what a
// missing field becomes once something upstream has helpfully defaulted it, and
// a "seed" every battle shares is the one worth refusing outright.
const SEED_MAX = 1073741824;

const PP_MAX = 99;
const POWER_MAX = 999;
// Gen 1 compares accuracy against a 0-255 roll, which is the whole mechanism
// behind the 1-in-256 miss -- so it is a byte here too, and 0 is a move that
// never lands rather than an absent field.
const ACCURACY_MAX = 255;
const EFFECT_MAX = 255;
const CHANCE_MAX = 100;
// hp, maxHp and the `hp` on a damage event are the same quantity seen from two
// ends of the wire, so they are one named number rather than three literals
// that were meant to agree.
const HP_MAX = 999;
const STAT_MAX = 999;
const IV_MAX = 15;
const EV_MAX = 65535;

// The party a combatant may submit, and the moves one of them may carry.
// Mirrors Config.BATTLE_MON_MAX, BATTLE_MOVE_MAX, and battle-bag caps.
const BATTLE_MON_MAX = 6;
const BATTLE_MOVE_MAX = 4;
const BATTLE_BAG_MAX = 40;
const BATTLE_BAG_COUNT_MAX = 99;
// Mirrors Config.COOP_BADGES_MAX.
const COOP_BADGES_MAX = 32;

/*
 * How wide a side is and how wide the field is -- written as products of
 * PARTY_MAX for the reason Config.lua writes them that way: the day a party
 * widens, the side and the field widen with it instead of being numbers somebody
 * has to remember.
 *
 * The three indices in this vocabulary, and the widths that tell them apart:
 *
 *   SLOT_MAX   a *party* index -- which of your six. What `mon.slot` and
 *              `choice.slot` are bounded by.
 *   FIELD_MAX  a position *on the field* -- four, because a party is a pair and
 *              two parties meet. What `choice.target` and `event.slot` are
 *              bounded by: an event is about somebody who is out, not about a
 *              bench position.
 *   ...and `choice.move`, bounded by BATTLE_MOVE_MAX - 1.
 *
 * **All of them are zero-based**, which is the one thing they do share, and it is
 * worth stating because guessing produces an off-by-one that silently spends the
 * wrong turn.
 */
const COOP_SIDE = PARTY_MAX;
const COOP_FIGHTERS = PARTY_MAX * 2;
const SLOT_MAX = BATTLE_MON_MAX - 1;
const FIELD_MAX = COOP_FIGHTERS - 1;

/*
 * A floor with no ceiling, which is Wire.lua's `M.int(x, 0)` -- an optional
 * maximum this file's cleanInt does not have.
 *
 * It exists for one field: an event's `seq`, which is only ever compared and
 * never sized, so an absurdly large one sorts late and does nothing else,
 * whereas a cap would be a battle length nobody chose. MAX_SAFE_INTEGER is where
 * JavaScript stops counting rather than a limit on battles; past it the two twins
 * disagree about a value no honest intermediator emits.
 */
const SEQ_MAX = Number.MAX_SAFE_INTEGER;
// What an event's `amount` may say: damage off a bar, or the size of a stat
// change. Unsigned, because which direction a stat moved is the event's kind and
// its sentence rather than the sign of this field.
const AMOUNT_MAX = 9999;
// How long a reason token this build has never heard of may be. Refused past it
// rather than trimmed -- a cut token matches nothing and is a value nobody sent.
const REASON_MAX = 32;

// Gen 1's four battle stats, in Gen 1's order rather than alphabetical. SPC is
// one stat and not two: Special did not split until Gen 2, so a snapshot
// carrying spa/spd would be describing a different game's battler. The list is
// the schema -- ivs and evs are these same four keys at their own widths, and
// no other key survives.
const BATTLE_STATS = ['atk', 'def', 'spd', 'spc'];

// Gen 1's status conditions as three-letter tokens. TOX is here alongside PSN
// because Gen 1 really does distinguish them (the doubling toxic counter) even
// though both read as PSN on the status box. Wire.lua spells this M.STATUSES.
const BATTLE_STATUSES = new Set(['SLP', 'PSN', 'BRN', 'FRZ', 'PAR', 'TOX']);

/*
 * What a player may ask for on their turn, and which field each ask needs in
 * order to mean anything. `true` means the action is complete on its own.
 *
 * Required-field-per-action rather than a check beside it, exactly as
 * PARTY_EVENTS is shaped and for the same reason: the incomplete case is the one
 * that reaches a player. A `fight` with no move index is not a defaultable choice
 * -- picking a move for somebody would be choosing their turn for them, and doing
 * nothing would stall a clock that forfeits.
 *
 * 'cancel' is a real action rather than the absence of one: a player backing out
 * of a choice they already submitted is something the turn machine has to be told
 * about, because it is holding a deadline open on their behalf.
 *
 * A Map rather than an object literal, for the reason spelled out at
 * PARTY_EVENTS: with a literal, `action: 'constructor'` finds Object's own
 * property, reads as a complete action, and would be forwarded as an action no
 * Lua client can perform.
 */
const BATTLE_ACTIONS = new Map([
  ['fight', 'move'],
  ['item', 'item'],
  ['switch', 'slot'],
  ['run', true],
  ['cancel', true],
]);

/*
 * Everything a mediated fight can tell a client to draw. Wire.lua spells this
 * M.BATTLE_EVENTS.
 *
 *   msg        a line of text for the box
 *   anim       play a move's animation
 *   damage     HP came off a slot
 *   drain      ...and some of it went onto another one
 *   faint      a slot is out
 *   send       a slot's next monster is on the field
 *   status     a condition was inflicted or cleared
 *   stat       a stat stage moved
 *   switch     a voluntary swap resolved
 *   item       a bag item was used
 *   run        somebody fled, or tried
 *   turn       a new turn is open; choices are wanted
 *   over       the field is done; an outcome is coming
 *   wait       the fight is paused on somebody, and who
 *   reconnect  a side that had dropped is back
 *
 * Closed, because the vocabulary is the contract between the turn machine and
 * the screen: an unknown kind has no animation, no sentence and no state change
 * to apply, and an event nothing draws is a turn the two players saw
 * differently.
 */
const BATTLE_EVENT_TYPES = new Set([
  'msg', 'anim', 'damage', 'drain', 'faint', 'send', 'status', 'stat',
  'switch', 'item', 'run', 'turn', 'over', 'wait', 'reconnect',
  'chose', 'unchose', 'moves',
]);

// The reasons a mediated fight ends that a screen currently has a sentence for:
// nobody answered in time, a side dropped and its grace ran out, somebody fled,
// a side has nothing left standing, both sides called it, or a side gave up.
//
// **Not a gate**, unlike every other named set here, and the difference is worth
// reading before adding one: this is the phrasebook a screen looks a reason up
// in, not the set the wire will accept. cleanBattleReason takes anything
// id-shaped, for the reason written above it. Adding an entry adds a sentence;
// it does not widen what arrives.
const BATTLE_REASONS = new Set([
  'timeout', 'disconnect', 'run', 'ko', 'agree', 'forfeit', 'catch',
]);

// The three shapes a mediated fight comes in: two players with one monster
// each, a pair against a trainer somebody walked into, or two pairs against
// each other. Named on the wire rather than inferred from how many ids arrived,
// because the two co-op modes have the same four field slots and differ only in
// whether one side has an owner.
const BATTLE_MODES = new Set(['1v1', 'coop_npc', 'coop_pvp', 'wild']);

/*
 * A roster: who is on a side, who won, who lost.
 *
 * Refused whole rather than filtered, and that is the opposite of how badges
 * are treated a few lines down -- deliberately. A badge that fails to clean is
 * inert; the boost table walks its own rows and asks the set, so a dropped
 * entry costs one stat multiplier. A roster is who receives events and whose
 * rating moves, so a name that fails to clean or a list longer than a side can
 * hold is a message that would put a fight on the field with the wrong people
 * in it -- a winners list missing a name is a fight somebody won and was not
 * told about. Refusing is loud, and loud is the failure to prefer.
 */
function cleanIdList(value, max) {
  if (!Array.isArray(value)) return null;
  if (value.length < 1 || value.length > max) return null;
  const out = [];
  for (const entry of value) {
    const id = cleanId(entry);
    if (!id) return null;
    out.push(id);
  }
  return out;
}

// The badges a combatant brings, sent as a list and rebuilt as a set, exactly
// as Wire.badges does it: the value is about to be indexed by id, and a set
// arriving off the wire is a table with arbitrary keys. Bad entries are
// dropped and the list is truncated rather than refused -- see the note above
// on why this one is the lenient half of the pair. No badges and an empty set
// are the same answer, and both are null.
function cleanBadgeSet(value) {
  if (!Array.isArray(value)) return null;
  const out = new Map();
  for (const entry of value) {
    const id = cleanId(entry);
    if (id && !out.has(id)) {
      out.set(id, true);
      if (out.size >= COOP_BADGES_MAX) break;
    }
  }
  if (!out.size) return null;
  // A plain object because this is what goes back on the wire and what the
  // boost table indexes -- built through a Map so that a badge id spelled
  // 'constructor' or '__proto__' cannot reach Object's prototype on the way.
  return Object.fromEntries(out);
}

// One stat block -- the four keys of BATTLE_STATS at the caller's width, and
// nothing else. Refused whole when any of the four is missing: a battler
// fighting with three of its stats is a battler whose damage formula divides
// by an absent number.
function cleanStatBlock(value, min, max) {
  if (value === null || typeof value !== 'object') return null;
  const out = {};
  for (const key of BATTLE_STATS) {
    const n = cleanInt(value[key], min, max);
    if (n === null) return null;
    out[key] = n;
  }
  return out;
}

/*
 * The chart itself: rows of integer-percent cells, rebuilt cell by cell rather
 * than measured and passed on.
 *
 * Uniform rows, with both axes bounded by BATTLE_TYPE_MAX. A ragged chart is the
 * failure that would not announce itself: the sim would read nothing out of the
 * short row and treat a super-effective matchup as neutral, in one direction
 * only.
 *
 * Squareness is *not* checked, even though a chart is indexed
 * attacker-by-defender out of one type space. What a type with no row means is a
 * question the sim has to answer regardless -- a move may name a type past the
 * chart's width, and reading that gap as neutral is its call -- so a rectangle of
 * numbers in range is what this owes, and it is what makes the table safe to walk
 * at all.
 */
function cleanChart(value) {
  if (!Array.isArray(value)) return null;

  const rows = [];
  let width = null;
  for (const row of value) {
    if (!Array.isArray(row)) return null;
    if (rows.length >= BATTLE_TYPE_MAX) return null;
    const cells = [];
    for (const raw of row) {
      if (cells.length >= BATTLE_TYPE_MAX) return null;
      const cell = cleanInt(raw, 0, CHART_MAX);
      if (cell === null) return null;
      cells.push(cell);
    }
    if (!cells.length) return null;
    if (width === null) width = cells.length;
    else if (cells.length !== width) return null;
    rows.push(cells);
  }
  if (!rows.length) return null;
  return rows;
}

/*
 * A battler's condition, where "healthy" is a real answer and so is "no".
 *
 * Three answers, mirroring Wire.lua's battleStatus, which needs all three: null
 * for healthy, the token itself when it is one, and `false` for a value that is
 * present and unrecognised. undefined, null and the empty string all mean
 * healthy, because that is how a client keeping no status field and one keeping a
 * cleared field each spell it, and neither is wrong.
 *
 * The `false` matters. Waving an unknown token through as healthy would hand the
 * sim a battler whose sender believes it is asleep and whose intermediator
 * believes it is fine, and the first turn would visibly disagree with the box the
 * player is looking at. Callers have to check for it explicitly.
 */
function cleanBattleStatus(value) {
  if (value === undefined || value === null || value === '') return null;
  return BATTLE_STATUSES.has(value) ? value : false;
}

/*
 * Why a fight ended: the phrasebook first, then a short bare token as a fallback
 * -- and the fallback is the design, not laziness.
 *
 * A reason is *narration*: it picks which sentence the end-of-battle box shows
 * and nothing else. If a newer intermediator names a reason this build cannot
 * phrase, refusing the whole outcome would leave the battle open forever on a
 * screen with no way out, over a field that was only ever a caption. So an
 * unknown reason survives as a token the box quietly declines to print, and the
 * result -- the part that matters -- still lands.
 */
function cleanBattleReason(value) {
  if (BATTLE_REASONS.has(value)) return value;
  if (typeof value !== 'string') return null;
  if (value.length > REASON_MAX) return null;
  return cleanId(value);
}

function cleanBattleMode(value) {
  return BATTLE_MODES.has(value) ? value : null;
}

/*
 * mmo.battle_ruleset. The chart is the message; a seed is an offer.
 *
 * Ephemeral, and that word is the legal posture rather than a performance note:
 * nothing in this repo ships a type chart, it arrives from the authority
 * client's own decoded copy for this match, and it is thrown away with the
 * battle.
 *
 * The chart is the message; a seed is an offer -- optional because the
 * intermediator is the sole authority on the RNG and picks its own when handed
 * nothing, so unlike the old lockstep pair there is no agreement here to get
 * wrong. But a seed that is *present and unreadable* takes the message with it: a
 * test or a replay sends one precisely because it needs that seed and no other,
 * so substituting a different one would answer the request with a run that looks
 * right and reproduces nothing.
 */
function cleanBattleRuleset(raw) {
  if (raw === null || typeof raw !== 'object') return null;
  const chart = cleanChart(raw.chart);
  if (!chart) return null;

  const ruleset = { chart };
  if (raw.seed !== undefined && raw.seed !== null) {
    const seed = cleanInt(raw.seed, 1, SEED_MAX);
    if (seed === null) return null;
    ruleset.seed = seed;
  }
  if (raw.specialTypes !== undefined && raw.specialTypes !== null) {
    if (!Array.isArray(raw.specialTypes)) return null;
    const special = [];
    for (const entry of raw.specialTypes) {
      const t = cleanInt(entry, 0, BATTLE_TYPE_MAX - 1);
      if (t === null) return null;
      special.push(t);
    }
    ruleset.specialTypes = special;
  }
  if (raw.metronomePool !== undefined && raw.metronomePool !== null) {
    if (!Array.isArray(raw.metronomePool)) return null;
    const pool = [];
    for (const entry of raw.metronomePool) {
      if (pool.length >= METRONOME_POOL_MAX) break;
      const move = cleanBattleMove(entry);
      if (!move) return null;
      pool.push(move);
    }
    ruleset.metronomePool = pool;
  }
  return ruleset;
}

/*
 * One move, carrying everything needed to resolve it.
 *
 * **There is no move table on either intermediator, and that is deliberate.**
 * Power, accuracy, type, effect and effect chance ride with the move rather than
 * being looked up by id, because a lookup table would be the ROM extract this
 * repo may not contain -- and because it is what lets a data pack's rebalanced
 * move resolve correctly on a hub that has never heard of it. `id` is along for
 * narration and logs only; nothing branches on it.
 *
 * Every field is required and none of them defaults. A move with no accuracy is
 * not a move that always hits, it is a move the sim cannot roll -- and the
 * difference between those two readings is a coin flip decided by whichever one
 * the twin happened to pick. So the missing field refuses the move, the move
 * refuses the battler, and the battler refuses the party: one loud failure at
 * the boundary instead of a quiet one three formulas in.
 */
function cleanBattleMove(raw) {
  if (raw === null || typeof raw !== 'object') return null;
  const id = cleanId(raw.id);
  const pp = cleanInt(raw.pp, 0, PP_MAX);
  const power = cleanInt(raw.power, 0, POWER_MAX);
  const accuracy = cleanInt(raw.accuracy, 0, ACCURACY_MAX);
  const type = cleanInt(raw.type, 0, MOVE_TYPE_MAX);
  const effect = cleanInt(raw.effect, 0, EFFECT_MAX);
  const chance = cleanInt(raw.chance, 0, CHANCE_MAX);
  if (!id || pp === null || power === null || accuracy === null
      || type === null || effect === null || chance === null) {
    return null;
  }
  const move = { id, pp, power, accuracy, type, effect, chance };
  if (raw.maxPp !== undefined && raw.maxPp !== null) {
    const maxPp = cleanInt(raw.maxPp, 0, PP_MAX);
    if (maxPp === null) return null;
    move.maxPp = maxPp;
  }
  return move;
}

/*
 * One battler, as its owner claims it.
 *
 * **Sheet trust is a locked decision**, not a v1 TODO. A modified client can
 * send a level-100 team with 999 in every stat and the intermediator will
 * fight it. What sanitising buys is not honesty, it is coherence -- every
 * number is a number, in a range the formulas survive, and the fight resolves
 * and ends. Mid-fight cheating is what the intermediator removes; the
 * pre-fight sheet stays a client claim because the hub holds no ROM species
 * table and never will (legal floor / no ROM bytes).
 *
 * **Bags (PROTOCOL 15).** Optional `bag` on the party message. The hub holds a
 * stack on `item` choice accept and decrements only when the turn resolves, so
 * cancel/unchose never needs a refund. Entries must be BattleSim-known
 * (`itemEffect`), including vitamins (fight-local Stat Exp; client writebacks
 * save.statExp). Counts and battler sheets remain a claim (inventing 99
 * POTION or a god team on upload is the accepted bound). Absent `bag`
 * means empty.
 *
 * `species` is prose rather than an id, and gets NAME_MAX like
 * Wire.partyEvent's, because what it is for is the name in "PIKACHU used ...",
 * drawn on somebody else's screen. An intermediator holds no species table to
 * look one up in (it has no ROM data and never will), so anything that needs an
 * id-shaped species has to carry its own field rather than reusing this one.
 *
 * `hp` above `maxHp` is refused even though both are individually in range,
 * because it is the one incoherence that reaches arithmetic rather than a screen:
 * the HP bar and several formulas divide by maxHp, and a battler at 300/100 draws
 * a bar past its own box and starts the fight already impossible to describe.
 * `maxHp` therefore starts at 1 while `hp` starts at 0 -- a fainted monster is
 * ordinary, a monster with no capacity is not.
 *
 * `status`, `ivs`, `evs` and `slot` are optional wholesale but not piecemeal, and
 * a present-but-unreadable one refuses the battler: a snapshot from a client that
 * tracks no IVs is fine and common, while a snapshot with two of the four is a bug
 * on the sending side that accepting would silently zero the rest of.
 */
function cleanBattleMon(raw) {
  if (raw === null || typeof raw !== 'object') return null;

  const stats = cleanStatBlock(raw.stats, 1, STAT_MAX);
  if (!stats) return null;

  const status = cleanBattleStatus(raw.status);
  if (status === false) return null;

  const species = cleanText(raw.species, NAME_MAX);
  const level = cleanInt(raw.level, 1, LEVEL_MAX);
  const hp = cleanInt(raw.hp, 0, HP_MAX);
  const maxHp = cleanInt(raw.maxHp, 1, HP_MAX);
  if (!species || level === null || hp === null || maxHp === null) return null;
  if (hp > maxHp) return null;

  const mon = { species, level, hp, maxHp, stats };
  // Written only when there is one, so that a healthy battler carries no status
  // field at all -- which is how Wire.lua spells it, and the shape a Lua decoder
  // reads back without a null sentinel to interpret.
  if (status) mon.status = status;

  if (raw.slot !== undefined && raw.slot !== null) {
    const slot = cleanInt(raw.slot, 0, SLOT_MAX);
    if (slot === null) return null;
    mon.slot = slot;
  }
  if (raw.ivs !== undefined && raw.ivs !== null) {
    const ivs = cleanStatBlock(raw.ivs, 0, IV_MAX);
    if (!ivs) return null;
    mon.ivs = ivs;
  }
  if (raw.evs !== undefined && raw.evs !== null) {
    const evs = cleanStatBlock(raw.evs, 0, EV_MAX);
    if (!evs) return null;
    if (raw.evs.hp !== undefined && raw.evs.hp !== null) {
      const hp = cleanInt(raw.evs.hp, 0, EV_MAX);
      if (hp === null) return null;
      evs.hp = hp;
    }
    mon.evs = evs;
  }

  if (!Array.isArray(raw.moves)) return null;
  if (raw.moves.length < 1 || raw.moves.length > BATTLE_MOVE_MAX) return null;
  const moves = [];
  for (const entry of raw.moves) {
    const move = cleanBattleMove(entry);
    if (!move) return null;
    moves.push(move);
  }
  mon.moves = moves;

  // Optional defender types as chart indices. Absent → sim default type 0.
  if (raw.types !== undefined && raw.types !== null) {
    if (!Array.isArray(raw.types)) return null;
    const types = [];
    for (const entry of raw.types) {
      if (types.length >= 2) break;
      const t = cleanInt(entry, 0, BATTLE_TYPE_MAX - 1);
      if (t === null) return null;
      types.push(t);
    }
    if (!types.length) return null;
    mon.types = types;
  }

  if (raw.catchRate !== undefined && raw.catchRate !== null) {
    const catchRate = cleanInt(raw.catchRate, 0, 255);
    if (catchRate === null) return null;
    mon.catchRate = catchRate;
  }

  return mon;
}

// mmo.battle_party. One combatant's team for one battle.
//
// The list is bounded and refused whole rather than delivered short, which is
// cleanMember's rule turned up a notch: a team the intermediator quietly
// shortened is a fight the owner loses to a monster they were told they had.
//
// `side` is optional because a 1v1 has none to name -- there are two combatants
// and the intermediator knows which is which from the session it brokered. It is
// required in practice for the two co-op modes, and that is the intermediator's
// check to make rather than this one's, because it is the only party that knows
// which mode this battle is. Present-and-malformed is still refused, because a
// side nobody can read is not the same thing as a side nobody stated.
/*
 * Optional battle bag on mmo.battle_party. Absent means empty. Array of
 * `{id, count}` or a map of id → count; duplicates and oversize refuse.
 */
function cleanBattleBag(raw) {
  if (raw === undefined || raw === null) return [];
  if (typeof raw !== 'object') return null;

  const out = [];
  const seen = new Set();
  const push = (id, count) => {
    if (seen.has(id) || out.length >= BATTLE_BAG_MAX) return false;
    const effect = Effects.itemEffect(id);
    if (!effect) return false;
    seen.add(id);
    out.push({ id, count });
    return true;
  };

  if (Array.isArray(raw)) {
    for (const entry of raw) {
      if (entry === null || typeof entry !== 'object') return null;
      const id = cleanId(entry.id);
      const count = cleanInt(entry.count, 1, BATTLE_BAG_COUNT_MAX);
      if (!id || count === null) return null;
      if (!push(id, count)) return null;
    }
  } else {
    for (const [key, value] of Object.entries(raw)) {
      const id = cleanId(key);
      const count = cleanInt(value, 1, BATTLE_BAG_COUNT_MAX);
      if (!id || count === null) return null;
      if (!push(id, count)) return null;
    }
  }

  out.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return out;
}

function cleanBattleParty(raw) {
  if (raw === null || typeof raw !== 'object') return null;
  const battle = cleanId(raw.battle);
  if (!battle) return null;

  const party = { battle };
  const badges = cleanBadgeSet(raw.badges);
  if (badges) party.badges = badges;

  if (raw.side !== undefined && raw.side !== null) {
    const side = cleanSide(raw.side);
    if (!side) return null;
    party.side = side;
  }

  if (!Array.isArray(raw.mons)) return null;
  if (raw.mons.length < 1 || raw.mons.length > BATTLE_MON_MAX) return null;
  const mons = [];
  for (const entry of raw.mons) {
    const mon = cleanBattleMon(entry);
    if (!mon) return null;
    mons.push(mon);
  }
  party.mons = mons;

  const bag = cleanBattleBag(raw.bag);
  if (!bag) return null;
  party.bag = bag;

  return party;
}

// mmo.battle_ready. The field is assembled and the first turn is open.
//
// The sides are named by the intermediator because it is the only party to the
// exchange that knows every combatant uploaded a party and is still connected at
// the moment it says so. Both are required even in a coop_npc fight where one of
// them is a trainer with no player behind it: the ids on that side are whoever
// submitted it, which is who a choice for those slots may arrive from.
function cleanBattleReady(raw) {
  if (raw === null || typeof raw !== 'object') return null;
  const battle = cleanId(raw.battle);
  const mode = cleanBattleMode(raw.mode);
  if (!battle || !mode) return null;
  if (raw.sides === null || typeof raw.sides !== 'object') return null;

  const a = cleanIdList(raw.sides.a, COOP_SIDE);
  const b = cleanIdList(raw.sides.b, COOP_SIDE);
  if (!a || !b) return null;
  return { battle, mode, sides: { a, b } };
}

/*
 * mmo.battle_choice. One player's intent for one turn -- a choice and never a
 * result: nothing here says what happened, only what was pressed.
 *
 * Note what is absent: there is no "who am I" field. Which combatant this is
 * comes from the connection it arrived on, the same way a party event's name
 * does, because an id in the payload is an id a modified client could set to
 * somebody else's and spend their turn with.
 *
 * The three indices are all zero-based and all differently bounded -- see the note
 * at SLOT_MAX for which is which. A present-but-out-of-range one refuses the
 * choice rather than being dropped, because dropping it would turn a `fight` into
 * an action with no move and stall a clock that forfeits.
 */
function cleanBattleChoice(raw) {
  if (raw === null || typeof raw !== 'object') return null;
  const needs = BATTLE_ACTIONS.get(raw.action);
  if (!needs) return null;
  const battle = cleanId(raw.battle);
  if (!battle) return null;

  const choice = { battle, action: raw.action };
  if (raw.slot !== undefined && raw.slot !== null) {
    const slot = cleanInt(raw.slot, 0, SLOT_MAX);
    if (slot === null) return null;
    choice.slot = slot;
  }
  if (raw.move !== undefined && raw.move !== null) {
    const move = cleanInt(raw.move, 0, BATTLE_MOVE_MAX - 1);
    if (move === null) return null;
    choice.move = move;
  }
  if (raw.target !== undefined && raw.target !== null) {
    // A field slot, not a party slot: an event and a target both point at
    // somebody who is out, not at a bench position.
    const target = cleanInt(raw.target, 0, FIELD_MAX);
    if (target === null) return null;
    choice.target = target;
  }
  if (raw.item !== undefined && raw.item !== null) {
    const item = cleanId(raw.item);
    if (!item) return null;
    choice.item = item;
  }

  if (needs !== true && choice[needs] === undefined) return null;
  return choice;
}

/*
 * mmo.battle_event. One thing to draw.
 *
 * Optional fields here are **dropped rather than fatal**, which is the one place
 * in this file that bends its own rule -- so here is why. Every other sanitised
 * message is a fact some module stores; an event is an instruction in an ordered
 * stream, and `seq` is what makes the stream readable. Refusing an event over a
 * mangled `text` would put a hole in that sequence, and a hole is exactly what a
 * client is built to read as lost messages: it would ask for a resync over a
 * cosmetic field. A blank in a sentence costs one line; a false gap costs the
 * battle a round trip and a warning about a hub that is fine.
 *
 * Unknown keys are dropped by construction -- the object is rebuilt from the
 * whitelist -- so a field a newer intermediator invents arrives at a client that
 * never sees it. That is deliberate: a whitelist is a vocabulary both twins can
 * mirror exactly, where passing an opaque blob through would be handing a screen
 * fields nothing had checked.
 *
 * `text` borrows MESSAGE_MAX because it lands in the same box a chat line does
 * and is drawn by the same code, even though an intermediator wrote it.
 */
function cleanBattleEvent(raw) {
  if (raw === null || typeof raw !== 'object') return null;
  if (!BATTLE_EVENT_TYPES.has(raw.t)) return null;
  const battle = cleanId(raw.battle);
  const seq = cleanInt(raw.seq, 0, SEQ_MAX);
  if (!battle || seq === null) return null;

  const event = { battle, seq, t: raw.t };
  if (raw.text !== undefined && raw.text !== null) {
    // Item events carry an id in `text`, not prose -- cleanText strips `_`.
    const text = raw.t === 'item'
      ? cleanId(raw.text)
      : cleanText(raw.text, MESSAGE_MAX);
    if (text) event.text = text;
  }
  if (raw.amount !== undefined && raw.amount !== null) {
    const amount = cleanInt(raw.amount, 0, AMOUNT_MAX);
    if (amount !== null) event.amount = amount;
  }
  if (raw.slot !== undefined && raw.slot !== null) {
    // A field slot here, unlike the party index a choice carries under the same
    // name: an event is about somebody who is out, not about a bench position.
    const slot = cleanInt(raw.slot, 0, FIELD_MAX);
    if (slot !== null) event.slot = slot;
  }
  if (raw.hp !== undefined && raw.hp !== null) {
    const hp = cleanInt(raw.hp, 0, HP_MAX);
    if (hp !== null) event.hp = hp;
  }
  if (raw.side !== undefined && raw.side !== null) {
    const side = cleanSide(raw.side);
    if (side) event.side = side;
  }
  if (raw.status !== undefined && raw.status !== null) {
    // cleanBattleStatus answers false for present-but-unknown, which is not a
    // status and must not be stored as one.
    const status = cleanBattleStatus(raw.status);
    if (status) event.status = status;
  }
  if (raw.moves !== undefined && raw.moves !== null) {
    if (Array.isArray(raw.moves)) {
      const moves = [];
      for (const entry of raw.moves) {
        if (moves.length >= BATTLE_MOVE_MAX) break;
        const move = cleanBattleMove(entry);
        if (move) moves.push(move);
      }
      if (moves.length > 0) event.moves = moves;
    }
  }
  return event;
}

/*
 * mmo.battle_outcome. How the fight ended, from the only party that knows.
 *
 * **This replaces the two-client vote.** mmo.result exists because neither peer
 * in a relayed battle could be believed about its own win, so the hub scored
 * nothing until both said the same thing. Here the intermediator did every roll,
 * so it is the only party with an opinion worth having -- and a client's
 * mmo.result about a mediated fight is ignored rather than weighed.
 *
 * `winners` and `losers` are optional because a 1v1 does not need them: the
 * outcome is stated from the recipient's own point of view and there is exactly
 * one other player. A 2v2 does need them, since "loss" alone does not say which
 * pair, and a rank settle has four ids to move. Present-and-malformed refuses the
 * message: these are the names a rating moves for.
 */
function cleanBattleOutcome(raw) {
  if (raw === null || typeof raw !== 'object') return null;
  const battle = cleanId(raw.battle);
  const outcome = cleanOutcome(raw.outcome);
  if (!battle || !outcome) return null;

  const result = { battle, outcome };
  if (raw.winners !== undefined && raw.winners !== null) {
    const winners = cleanIdList(raw.winners, COOP_FIGHTERS);
    if (!winners) return null;
    result.winners = winners;
  }
  if (raw.losers !== undefined && raw.losers !== null) {
    const losers = cleanIdList(raw.losers, COOP_FIGHTERS);
    if (!losers) return null;
    result.losers = losers;
  }
  if (raw.reason !== undefined && raw.reason !== null) {
    const reason = cleanBattleReason(raw.reason);
    if (!reason) return null;
    result.reason = reason;
  }
  if (raw.caught !== undefined && raw.caught !== null) {
    const caught = cleanBattleMon(raw.caught);
    if (!caught) return null;
    result.caught = caught;
  }
  return result;
}

// mmo.battle_reconnect. Names the fight and nothing else: who is rejoining is
// the connection it arrived on, and a client that supplied its own identity
// would be claiming somebody else's seat at the field.
function cleanBattleReconnect(raw) {
  if (raw === null || typeof raw !== 'object') return null;
  const battle = cleanId(raw.battle);
  if (!battle) return null;
  return { battle };
}

module.exports = {
  cleanText,
  cleanId,
  cleanMember,
  cleanBattleKey,
  cleanLabel,
  cleanSide,
  cleanCoopReason,
  cleanPartyEvent,
  cleanSpriteId,
  cleanMapId,
  cleanInt,
  cleanHex,
  cleanCode,
  cleanProfile,
  cleanOutcome,
  cleanPoints,
  cleanPlayerId,
  cleanIdList,
  cleanBadgeSet,
  cleanStatBlock,
  cleanChart,
  cleanBattleStatus,
  cleanBattleReason,
  cleanBattleMode,
  cleanBattleRuleset,
  cleanBattleMove,
  cleanBattleMon,
  cleanBattleBag,
  cleanBattleParty,
  cleanBattleReady,
  cleanBattleChoice,
  cleanBattleEvent,
  cleanBattleOutcome,
  cleanBattleReconnect,
  payloadOk,
  FACINGS,
  KINDS,
  SCOPES,
  PARTY_MAX,
  OUTCOMES,
  RANK_MAX,
  PLAYER_ID_HEX,
  NAME_MAX,
  MESSAGE_MAX,
  MOTD_MAX,
  LOCAL_RADIUS,
  MAX_LINE,
  PAYLOAD_MAX_DEPTH,
  PAYLOAD_MAX_NODES,
  COOP_KEY_MAX,
  COOP_LABEL_MAX,
  SIDES,
  COOP_REASONS,
  PARTY_EVENTS,
  LEVEL_MAX,
  // Mediated battles. The bounds are exported alongside the closed sets for the
  // reason relay.js exports PROTOCOL: a suite that names the constant still
  // asserts the current dialect after one of these moves, where a suite that
  // typed the number would quietly go on testing the old one. Names mirror
  // Wire.lua's, except that its M.STATUSES and M.BATTLE_EVENTS are spelled
  // BATTLE_STATUSES and BATTLE_EVENT_TYPES here.
  BATTLE_ACTIONS,
  BATTLE_EVENT_TYPES,
  BATTLE_STATUSES,
  BATTLE_REASONS,
  BATTLE_MODES,
  BATTLE_STATS,
  EFF_MULTS,
  EFF_NEUTRAL,
  CHART_MAX,
  BATTLE_TYPE_MAX,
  MOVE_TYPE_MAX,
  SEED_MAX,
  PP_MAX,
  POWER_MAX,
  ACCURACY_MAX,
  EFFECT_MAX,
  CHANCE_MAX,
  HP_MAX,
  STAT_MAX,
  IV_MAX,
  EV_MAX,
  BATTLE_MON_MAX,
  BATTLE_MOVE_MAX,
  BATTLE_BAG_MAX,
  BATTLE_BAG_COUNT_MAX,
  COOP_BADGES_MAX,
  COOP_SIDE,
  COOP_FIGHTERS,
  SLOT_MAX,
  FIELD_MAX,
  SEQ_MAX,
  AMOUNT_MAX,
  REASON_MAX,
};
