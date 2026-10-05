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
// Bag proofs use the hub's generation twin. Gen1 Effects remains the default
// when generation is omitted (compat). Gen2 item tables are selected when
// cleanBattleBag/Party run with generation:2 (relay passes relay.generation).
// Gen 3 has no Effects.itemEffect: its bag is lib/battle3/Items.BAG keyed by
// numeric pret item id (docs/plans/gen3-battle-sheet.md §4), put behind the
// same one-function shape here -- twin of Wire.lua's effectsFor.
const EffectsGen1 = require('./battle/Effects');
const EffectsGen2 = require('./battle2/Effects');
const Items3 = require('./battle3/Items');

const EffectsGen3 = { itemEffect: (id) => Items3.bagEffect(id) };

function effectsFor(generation) {
  if (generation === 3) return EffectsGen3;
  return generation === 2 ? EffectsGen2 : EffectsGen1;
}

/*
 * LuaJIT's tonumber on a string, which is what Wire.int calls: the reading the
 * Lua hub gives every numeric field, so the one this twin has to give too.
 *
 * Whitespace is ASCII only (tab, LF, VT, FF, CR, space) -- String#trim would
 * also strip a no-break space, which reaches Lua as the two bytes C2 A0 and is
 * no number there. A sign may lead any form, hex included ("-0x1" is -1; JS's
 * Number says NaN). Hex takes a fraction and a binary exponent ("0x1.8p1" is
 * 3), rounded once to the nearest double as strscan rounds it; "0b" binary
 * takes up to 64 significant digits. A written exponent of 2^20 or more is no
 * number at all, even "1e-9999999" -- strscan refuses it rather than calling
 * it 0. inf / nan (which Wire.int refuses anyway) come back null here.
 */
const LUA_SPACE = /^[\t\n\v\f\r ]+|[\t\n\v\f\r ]+$/g;
const LUA_DECIMAL = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE]([+-]?\d+))?$/;
const LUA_HEX = /^([+-]?)0[xX]([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?(?:[pP]([+-]?\d+))?$/;
const LUA_BINARY = /^([+-]?)0[bB]([01]+)$/;
const LUA_EXPONENT_LIMIT = 1048576;

function luaExponent(text) {
  const digits = text.replace(/^[+-]/, '').replace(/^0+/, '');
  if (digits.length > 7) return null;
  const n = Number(digits || '0');
  if (n >= LUA_EXPONENT_LIMIT) return null;
  return text[0] === '-' ? -n : n;
}

// mantissa * 2^exp2, rounded once (to nearest, ties to even) to a double.
function luaScale(mantissa, exp2) {
  if (mantissa === 0n) return 0;
  const top = mantissa.toString(2).length - 1 + exp2;
  if (top > 1023) return Infinity;
  const unit = Math.max(top - 52, -1074);
  const shift = unit - exp2;
  let q;
  if (shift <= 0) {
    q = mantissa << BigInt(-shift);
  } else {
    const big = BigInt(shift);
    q = mantissa >> big;
    const rest = mantissa - (q << big);
    const half = 1n << (big - 1n);
    if (rest > half || (rest === half && (q & 1n) === 1n)) q += 1n;
  }
  return Number(q) * 2 ** unit;
}

function luaNumber(value) {
  if (typeof value === 'number') return Number.isNaN(value) ? null : value;
  if (typeof value !== 'string') return null;
  const s = value.replace(LUA_SPACE, '');
  let m = LUA_DECIMAL.exec(s);
  if (m) {
    if (m[1] !== undefined && luaExponent(m[1]) === null) return null;
    return Number(s);
  }
  m = LUA_HEX.exec(s);
  if (m) {
    const [, sign, whole, fraction = '', exponent] = m;
    if (!whole && !fraction) return null;
    const exp = exponent === undefined ? 0 : luaExponent(exponent);
    if (exp === null) return null;
    const n = luaScale(BigInt(`0x${whole}${fraction}`), exp - 4 * fraction.length);
    return sign === '-' ? -n : n;
  }
  m = LUA_BINARY.exec(s);
  if (m) {
    const digits = m[2].replace(/^0+/, '');
    if (digits.length > 64) return null;
    const n = digits ? Number(BigInt(`0b${digits}`)) : 0;
    return m[1] === '-' && n !== 0 ? -n : n;
  }
  return null;
}

// Wire.int, spelled exactly: a JSON number or a string LuaJIT's tonumber reads
// (luaNumber), floored, inside [min, max] -- and nothing else. cleanInt takes
// Number(true) as 1 and '' as 0 where Lua says nil to both; the Gen 3 dialect
// below is new on both twins, so it is written against the stricter reading
// from the start.
function luaInt(value, min, max) {
  const n = luaNumber(value);
  if (n === null || !Number.isFinite(n)) return null;
  const i = Math.floor(n);
  if (min !== undefined && min !== null && i < min) return null;
  if (max !== undefined && max !== null && i > max) return null;
  return i;
}

/*
 * A list as src/Wire.lua is handed it, or null. The engine's Json.decode
 * appends nothing for a null element (`arr[#arr + 1] = nil`) and stores
 * nothing for a null value, so `[10, null, 12]` reaches the Lua hub as
 * `{ 10, 12 }` and `{}` or `{"a": null}` as the same empty table `[]` becomes.
 * The Lua side cannot see the hole, so the Gen 3 dialect reads its lists
 * through here: closed up the same way, an empty (or all-null) object taken as
 * the empty list, any other object refused -- Wire.lua's isList. Both twins
 * then judge one list, and refuse or keep it whole alike.
 */
function luaList(value) {
  if (Array.isArray(value)) return value.filter((v) => v !== null && v !== undefined);
  if (value === null || typeof value !== 'object') return null;
  for (const key of Object.keys(value)) {
    if (value[key] !== null && value[key] !== undefined) return null;
  }
  return [];
}

// The entries of a JSON object as Lua's decoder keeps them: a null value is
// no key at all. Twin reading for a Gen 3 map-shaped bag.
function luaEntries(value) {
  return Object.entries(value).filter(([, v]) => v !== null && v !== undefined);
}

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

// A map id: refused past 64 characters, never cut. Twin of Wire.mapId, which
// cut a long one to 64 until K13's twin (docs/plans/gen12-referee-gaps-fix.md)
// -- a player this hub left unplaced stood on a truncated map on the LAN host.
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

// Boot generation claimed on mmo.hello (PROTOCOL 20; 3 from PROTOCOL 30). The
// twin of Wire.generation, where the argument is written out in full.
//
// Missing is 1 -- the one-release compat reading PROTOCOL 20 made, so a
// legacy-shaped hello still joins a Gen 1 hub. Present but unknown is null,
// never 1: clamping is how a FireRed client (3, outside the old 1..2) was
// admitted into a Red room under PROTOCOL 29, and the hello handler refuses
// null in the same sentence it refuses a mismatch.
//
// A JSON number only. cleanInt alone would take Number(true) as 1, [2] as 2
// and "0b11" as 3, where Lua's tonumber says nil to all three -- one hello
// admitted by this hub and refused by its twin.
const GENERATION_MAX = 3;

function cleanGeneration(value) {
  if (value === undefined || value === null) return 1;
  if (typeof value !== 'number') return null;
  return cleanInt(value, 1, GENERATION_MAX);
}

// The cart a hello was sent from (PROTOCOL 30), keyed to the generation it
// belongs to. Twin of Wire.VERSIONS: GameVersion's own ids, a closed set,
// because a viewer maps a partner's sprite through it and an unknown cart has
// nothing to map. A Map rather than an object literal so "constructor" or
// "__proto__" off the wire is a miss rather than a prototype hit.
const VERSIONS = new Map([
  ['red', 1], ['blue', 1], ['yellow', 1],
  ['gold', 2], ['silver', 2], ['crystal', 2],
  ['firered', 3], ['leafgreen', 3], ['emerald', 3],
]);

// A version off the wire, or null. With `generation`, only a version of that
// generation survives: a Gen 3 room relays no "red" for anybody in it.
function cleanVersion(value, generation) {
  if (typeof value !== 'string') return null;
  const gen = VERSIONS.get(value);
  if (gen === undefined) return null;
  if (generation !== undefined && generation !== null && gen !== generation) {
    return null;
  }
  return value;
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

/*
 * Why an invite came back refused, when the refusal was not a human pressing
 * NO. A closed set rather than free text, for the reason COOP_REASONS is one:
 * every value picks a different sentence on the asker's screen, and an
 * unknown one has nothing to draw.
 *
 * **Absent is the important value.** No reason means a person read the box
 * and said no, which is the only refusal that was ever worth the flat 'X
 * refused to battle.' Every other one is a fact about the moment -- they are
 * mid-fight, mid-trade, already holding somebody else's ask, or no longer
 * here -- and telling the asker which is the difference between a sentence
 * they can act on and one that reads as a snub. Mirrors Wire.DECLINE_REASONS.
 */
const DECLINE_REASONS = {
  fighting: true, busy: true, asked: true, gone: true,
};

function cleanDeclineReason(value) {
  return DECLINE_REASONS[value] ? value : null;
}

// Up to three players. The rules that make a party feel solid follow from
// that size: a pair may invite a third when the target is unattached and the
// asker's party still has room; one of three leaving leaves a remainder of
// two; the group dissolves only when fewer than two remain. Three is the
// design, not a first step towards six. Kept in step with Config.PARTY_MAX.
const PARTY_MAX = 3;

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

// What a move is called, as opposed to what identifies it (PROTOCOL 26). Prose,
// so it borrows cleanText -- but with its own limit, because a move name is not
// a player name and NAME_MAX cuts "THUNDERSHOCK" to "THUNDERSHO". Twin of
// Config.MOVE_NAME_MAX / Wire.moveName.
const MOVE_NAME_MAX = 16;

function cleanMoveName(value) {
  return cleanText(value, MOVE_NAME_MAX);
}

function cleanBattleKey(value) {
  if (typeof value !== 'string') return null;
  if (value.length > COOP_KEY_MAX) return null;
  return /^[\w.\-:|]+$/.test(value) ? value : null;
}

// Optional wait/offer mode. Only coop_wild is meaningful; anything else
// (including absent) is null so the trainer invite path stays the default.
// Mirrors Wire.coopOfferMode.
function cleanCoopOfferMode(value) {
  return value === 'coop_wild' ? 'coop_wild' : null;
}

// Which side of a co-op battle somebody is on, and why an offer or an ask
// ended. Both are closed sets rather than free text: each value picks a
// different sentence on the client, and an unknown one has to degrade to the
// vague case rather than being printed raw.
const SIDES = { a: true, b: true };
const COOP_REASONS = {
  alone: true, left: true, started: true, no: true, gone: true, timeout: true,
  // party-vs-party size not equal / not 2-or-3 (hub refuse; T7 phrases)
  mismatch: true,
  // partner turned this kind of coop off; does not end the wait
  skip: true,
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
// Cap on ephemeral Metronome pools (mirrors Config.BATTLE_METRONOME_POOL_MAX,
// whose comment says why 256: Gold's 251 moves and the line they ride on).
const METRONOME_POOL_MAX = 256;

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

/*
 * The Gen 3 dialect's bounds (docs/plans/gen3-battle-sheet.md §2-§4, contract
 * C4), named as Wire.lua names them. The id caps mirror Config's GEN3_* numbers;
 * the move type keeps the generous 0..31 the older dialects use.
 */
const GEN3_SPECIES_MAX = 411; // Config.GEN3_SPECIES_MAX
const GEN3_MOVE_MAX = 354; // Config.GEN3_MOVE_MAX
const GEN3_ITEM_MAX = 376; // Config.GEN3_ITEM_MAX
const GEN3_ABILITY_MAX = 77; // Config.GEN3_ABILITY_MAX
const GEN3_NATURE_COUNT = 25; // Config.GEN3_NATURE_COUNT
const GEN3_IV_MAX = 31; // Config.GEN3_IV_MAX
const GEN3_EV_MAX = 255; // Config.GEN3_EV_MAX
const BATTLE_TYPE_TABLE3_MAX = 150; // Config.BATTLE_TYPE_TABLE3_MAX (triples)
const BATTLE_MOVE_POOL3_MAX = 360; // Config.BATTLE_MOVE_POOL3_MAX
const POWER3_MAX = 255;
const ACCURACY3_MAX = 100; // percent in Gen 3, not a 0..255 byte
const EFFECT3_MAX = 213; // EFFECT_* 0..213
const TARGET3_MAX = 255; // MOVE_TARGET_* bitmask
const PRIORITY3_MAX = 7; // signed: -7..7
const FLAGS3_MAX = 63; // FLAG_* bits
const HOLD_EFFECT3_MAX = 66; // HOLD_EFFECT_*
const HOLD_PARAM3_MAX = 255;
const WEIGHT3_MAX = 9999; // hectograms
const SLEEP3_MAX = 7;
const U32_MAX = 4294967295; // personality / OT id passthrough
const GENDERS3 = new Set(['M', 'F', 'U']);
// A type-table cell: a type id or the Foresight sentinel -1; a multiplier in
// tenths up to the 4x CHART_MAX allows a Gen 1 cell.
const TYPE_CELL3_MIN = -1;
const TYPE_MULT3_MAX = 40;
const TERRAIN3_MAX = 9; // BATTLE_TERRAIN_*
const WEATHERS3 = new Set(['RAIN', 'SUN', 'SAND', 'HAIL']);
const POOL_ENTRY3_MAX = 128;
// The stat a Gen 3 `stat` event names, and how far a stage sits / moves.
const EVENT_STATS3 = new Set(['atk', 'def', 'spe', 'spa', 'spd', 'acc', 'eva']);
const STAGE3_MAX = 6;
const DELTA3_MAX = 12;
// The outcome an `obey` event names (contract K3, docs/plans/gen3-battle-sheet.md
// §7.2.1): one per branch of the engine's `disobedient`, the four loaf lines
// among them. A closed set for the reason Wire.lua gives at M.OBEY_TOKENS3: the
// screens look each one up as a line of the cart's.
const OBEY_TOKENS3 = new Set(['ignores_asleep', 'uses_random_move', 'falls_asleep', 'hits_itself',
  'loafing', 'wont_obey', 'turned_away', 'pretend_not_notice']);

/*
 * The Gold sheet's held-item fields (contract K2 of
 * docs/plans/gen12-referee-fidelity.md), named as Wire.lua names them.
 * pokecrystal names its hold effects (HELD_LEFTOVERS) where pret's Gen 3
 * numbers them, so the effect is a prefixed identifier bounded by length; the
 * parameter is the u8 beside it in the cart's item attributes; the display
 * name is the cart's item name (ITEM_NAME_LENGTH 13, terminator included).
 */
const HOLD_EFFECT2_MAX = 32; // characters in a HELD_* token
const HOLD_PARAM2_MAX = 255;
const ITEM_NAME2_MAX = 12;

/*
 * The referee-gap additions' bounds (contracts K7-K10 of
 * docs/plans/gen12-referee-gaps-fix.md), Gen 1 / Gen 2 dialect only, each the
 * width the carts store the number in. Twin of the block beside Wire.lua's
 * ITEM_NAME2_MAX, where each is argued: a base stat is a byte, a DV a nibble,
 * a stat-exp word 16 bits, the PP Ups the top two bits of the PP byte
 * (PP_UP_MASK), Gold's priority the raw GetMovePriority byte (unsigned, unlike
 * Gen 3's -7..7), and a `stat` event's stage -6..6.
 */
const BASE_STAT_MAX = 255;
const DV_MAX = 15;
const STAT_EXP_MAX = 65535;
const PP_UPS_MAX = 3;
const PRIORITY2_MAX = 255;
const STAGE12_MAX = 6;
// A Gold monster's happiness (contract K14, added after wave 1): the one byte
// MON_HAPPINESS that pokecrystal's BattleCommand_HappinessPower /
// _FrustrationPower read. Gold only. Twin of Wire.HAPPINESS2_MAX.
const HAPPINESS2_MAX = 255;

// Contract K7's three blocks per dialect: `base` keyed like `stats` plus `hp`,
// `dvs` the cart's four DVs (Gold's one Special DV feeds both special stats),
// `statExp` the cart's five stat-exp words. Twin of Wire.lua's K7_KEYS1 /
// K7_KEYS2.
const K7_KEYS1 = {
  base: ['hp', 'atk', 'def', 'spd', 'spc'],
  dvs: ['atk', 'def', 'spd', 'spc'],
  statExp: ['hp', 'atk', 'def', 'spd', 'spc'],
};
const K7_KEYS2 = {
  base: ['hp', 'atk', 'def', 'spe', 'spa', 'spd'],
  dvs: ['atk', 'def', 'spe', 'spc'],
  statExp: ['hp', 'atk', 'def', 'spe', 'spc'],
};

// One Gen 2 hold effect, or null. Refused rather than trimmed past
// HOLD_EFFECT2_MAX (a cut token names no rule), and the HELD_ prefix is part of
// the shape. Twin of Wire.holdEffect2.
function cleanHoldEffect2(value) {
  if (typeof value !== 'string') return null;
  if (value.length > HOLD_EFFECT2_MAX) return null;
  return /^HELD_[A-Z0-9_]+$/.test(value) ? value : null;
}

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
 *   FIELD_MAX  a position *on the field* -- COOP_FIGHTERS slots (0-based),
 *              two parties of PARTY_MAX. What `choice.target` and `event.slot`
 *              are bounded by: an event is about somebody who is out, not about
 *              a bench position.
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
// How many shares an `exp` event may say a faint was split between.
//
// A ceiling on a *divisor* a stranger sent, which is why it has a floor of one
// as well: zero shares is not a smaller award, it is a division by zero inside
// the client's own Experience formula. Twelve rather than BATTLE_MON_MAX
// because vanilla pays every mon that was ever in against the fallen foe and is
// still alive, benched included -- so a co-op faint can be split across two
// full parties: BATTLE_MON_MAX * COOP_SIDE. One number that covers both shapes
// beats two that have to be kept in step; it bounds a foreign value before it
// enters a formula, it does not restate a game rule.
//
// **Gen 3 reads a zero**, and only Gen 3 (cleanBattleEvent's `generation`):
// the holders-only fact (docs/plans/gen3-battle-sheet.md §7.1) -- a seat whose
// fighters all fell still pays its Exp. Share holders, the way pret
// Cmd_getexp does with `viaSentIn` 0 behind a SAFE_DIV. The Gen 3 formula
// (src/Exp3.lua split) never divides by this field, so the zero is a fact
// there rather than a divisor; the older readings keep the floor of one.
// Twin of Wire.PARTICIPANTS_MAX.
const PARTICIPANTS_MAX = BATTLE_MON_MAX * COOP_SIDE;
// The most Pay Day coins an outcome may say side a picked up (Gen 3 only,
// cleanBattleOutcome). pret's gPaydayMoney is a u16 that saturates, so this is
// the cart's own ceiling rather than a guess; the Amulet Coin doubling is the
// client's, applied after the read. Twin of Wire.PAYDAY3_MAX.
const PAYDAY3_MAX = 65535;
// The same, read by a Gen 1 / Gen 2 reader (contract K11 of
// docs/plans/gen12-referee-gaps-fix.md). pokered's wTotalPayDayMoney is three
// BCD bytes that AddBCD saturates at 999999; pokecrystal's wPayDayMoney is a
// three-byte binary counter, but the wallet it is paid into is clamped to
// MAX_MONEY 999999 (AddBattleMoneyToAccount). Twin of Wire.PAYDAY12_MAX.
const PAYDAY12_MAX = 999999;
// How long a reason token this build has never heard of may be. Refused past it
// rather than trimmed -- a cut token matches nothing and is a value nobody sent.
const REASON_MAX = 32;

// Battle-stat keys. Gen 1: atk/def/spd/spc (spd = Speed, spc = Special).
// Gen 2: atk/def/spe/spa/spd (spe = Speed, spa/spd = Sp.Atk/Sp.Def). Both
// dialects are first-class — a classic four-key Gen 1 table must still clean,
// and a Gen 2 spa/spd sheet must not be refused as the wrong game.
const BATTLE_STATS_GEN1 = ['atk', 'def', 'spd', 'spc'];
const BATTLE_STATS_GEN2 = ['atk', 'def', 'spe', 'spa', 'spd'];
// Back-compat export alias (Gen 1 keys) for callers that still read BATTLE_STATS.
const BATTLE_STATS = BATTLE_STATS_GEN1;

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
 *   exp        a faint's spoils, as facts: who fell (species, level), how many
 *              shares split it, and which of the paid side's six is banking
 *              this share (`mon`, optional). Not an amount: the hub holds no
 *              species table and can never compute one, so the referee states
 *              the facts and each client runs its own Experience formula over
 *              its own party.
 *   team       a seat's party roster, as ball states: how many monsters it
 *              brought and which of them are healthy / statused / down. The
 *              referee is the only party to a mediated fight holding every
 *              party, so it is the only one that can say this about the seat
 *              opposite. Ball states and nothing else -- no species, no level,
 *              no moves -- which is exactly what the classic ball row reveals.
 *
 * Closed, because the vocabulary is the contract between the turn machine and
 * the screen: an unknown kind has no animation, no sentence and no state change
 * to apply, and an event nothing draws is a turn the two players saw
 * differently.
 */
const BATTLE_EVENT_TYPES = new Set([
  'msg', 'anim', 'damage', 'drain', 'faint', 'send', 'status', 'stat',
  'switch', 'item', 'run', 'turn', 'over', 'wait', 'reconnect',
  'chose', 'unchose', 'moves', 'exp', 'team',
]);

// Gen 3's seven kinds (docs/plans/gen3-battle-sheet.md §7.2): an ability acting,
// the weather, a held item (and what is left held), a picture change, the
// substitute doll, a ball's shakes, a disobedient mon (text = the §7.2.1
// token). Their own set for the reason Wire.lua gives at M.BATTLE_EVENTS3 (the
// Gen 1 sim mirrors the set above exactly); a kind in either set is an event
// cleanBattleEvent reads. Gold's `held` is BATTLE_EVENT_TYPES2 below: the same
// word, a different event.
const BATTLE_EVENT_TYPES3 = new Set(['ability', 'weather', 'held', 'form', 'sub', 'ball', 'obey']);

// Gold's one kind of its own (contract K3 of docs/plans/gen12-referee-fidelity.md),
// read by a generation 2 reader only. Wire.lua spells this M.BATTLE_EVENTS2.
//
//   held  a held item acted: slot / side / mon say whose, `text` is the item's
//         id (cleanId, like an `item` event's), `amount` is 1 when the mon
//         still holds it afterwards and 0 when it is gone. The referee's own
//         `msg` sentence follows it.
const BATTLE_EVENT_TYPES2 = new Set(['held']);

/*
 * The three ball states a roster is spelled in. Wire.lua spells this
 * M.TEAM_TOKENS.
 *
 *   o  standing, nothing wrong with it
 *   s  standing, carrying a status
 *   x  down
 *
 * No token for an empty slot. An empty slot is not a party member -- the roster
 * says that by being short, and its length is therefore the party size, which
 * is half of what the event is for.
 */
const TEAM_TOKENS = new Set(['o', 's', 'x']);

/*
 * A seat's roster.
 *
 * **Refused whole rather than trimmed to the part that parses**, which is the
 * opposite of what cleanText does, and the difference is what the value is for.
 * A truncated sentence is a shorter sentence; a truncated roster is a
 * *different party* -- three balls where the seat holds five -- and a client
 * would draw the other player as two monsters closer to beaten than they are.
 * There is no partially-correct reading of this field, so a malformed one is
 * dropped and the chip keeps the last roster it was told.
 *
 * Bounded by BATTLE_MON_MAX because that is the rule the referee builds parties
 * under, and empty is refused because a seat with no monsters is not a seat
 * that is in the fight.
 */
function cleanBattleTeam(value) {
  if (typeof value !== 'string') return null;
  if (value.length < 1 || value.length > BATTLE_MON_MAX) return null;
  for (const ch of value) {
    if (!TEAM_TOKENS.has(ch)) return null;
  }
  return value;
}

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

// The shapes a mediated fight comes in: two players with one monster each, a
// pair against a trainer somebody walked into, two pairs against each other,
// one player against a wild NPC seat, or two humans against one wild NPC seat
// (coop_wild). Named on the wire rather than inferred from how many ids
// arrived, because the co-op modes share field-slot shapes and differ in who
// owns a side -- and "guess the mode from the roster" is right until an NPC
// battle happens to have a spectatorless second slot.
const BATTLE_MODES = new Set(['1v1', 'coop_npc', 'coop_pvp', 'wild', 'coop_wild']);

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

// Prefer explicit generation (1|2); else sniff spa/spe → Gen 2, else Gen 1.
// Gen 1's spd (Speed) alone never claims Gen 2.
function statsGeneration(block, hint) {
  const gen = cleanInt(hint, 1, 2);
  if (gen !== null) return gen;
  if (block === null || typeof block !== 'object') return 1;
  if (block.spa !== undefined && block.spa !== null) return 2;
  if (block.spe !== undefined && block.spe !== null) return 2;
  return 1;
}

// One stat block — all keys of the dialect at the caller's width, and nothing
// else. Refused whole when any required key is missing: a battler fighting
// with three of its stats is a battler whose damage formula divides by an
// absent number.
function cleanStatBlock(value, min, max, generation) {
  if (value === null || typeof value !== 'object') return null;
  const keys = statsGeneration(value, generation) === 2
    ? BATTLE_STATS_GEN2 : BATTLE_STATS_GEN1;
  const out = {};
  for (const key of keys) {
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
/*
 * Gen 3's chart: the cart's ORDERED triples (atk, def, mult in tenths), the
 * Foresight sentinel -1, -1, 0 in place (docs/plans/gen3-battle-sheet.md
 * §3.1). Refused whole, never trimmed: a list cut mid-row shifts every later
 * row by one. Twin of Wire.lua's typeTable3.
 */
function cleanTypeTable3(value) {
  const raw = luaList(value);
  if (!raw) return null;
  const n = raw.length;
  if (n === 0 || n % 3 !== 0 || n > BATTLE_TYPE_TABLE3_MAX * 3) return null;
  const out = [];
  for (let i = 0; i < n; i += 3) {
    const a = luaInt(raw[i], TYPE_CELL3_MIN, MOVE_TYPE_MAX);
    const d = luaInt(raw[i + 1], TYPE_CELL3_MIN, MOVE_TYPE_MAX);
    const m = luaInt(raw[i + 2], 0, TYPE_MULT3_MAX);
    if (a === null || d === null || m === null) return null;
    if ((a === TYPE_CELL3_MIN) !== (d === TYPE_CELL3_MIN)) return null;
    out.push(a, d, m);
  }
  return out;
}

/*
 * One Gen 3 move-pool entry (§3.3): the packed
 * "num:effect:power:type:accuracy:pp:chance:target:priority:flags:id" string,
 * parsed with the sim's grammar, bounded like a sheet's move row and written
 * back canonically; or a move row. Twin of Wire.lua's poolEntry3.
 */
function cleanPoolEntry3(raw) {
  if (raw !== null && typeof raw === 'object') return cleanBattleMove(raw, 3);
  if (typeof raw !== 'string' || raw.length > POOL_ENTRY3_MAX) return null;
  const parts = raw.split(':');
  if (parts.length !== 11) return null;
  const n = [];
  for (let i = 0; i < 10; i += 1) {
    if (!/^-?\d+$/.test(parts[i])) return null;
    n.push(Number(parts[i]) + 0);
  }
  const row = cleanBattleMove({
    num: n[0],
    effect: n[1],
    power: n[2],
    type: n[3],
    accuracy: n[4],
    pp: n[5],
    chance: n[6],
    target: n[7],
    priority: n[8],
    flags: n[9],
    id: parts[10],
  }, 3);
  if (!row || row.id !== parts[10]) return null;
  return [row.num, row.effect, row.power, row.type, row.accuracy, row.pp, row.chance,
    row.target, row.priority, row.flags, row.id].join(':');
}

// Which dialect a ruleset is in: the hub's generation when given, else the
// message's, else a `typeTable` is Gen 3's shape. Twin of rulesetIsGen3.
function rulesetIsGen3(raw, generation) {
  const hub = luaInt(generation, 1, GENERATION_MAX);
  if (hub !== null) return hub === 3;
  const own = luaInt(raw.generation, 1, GENERATION_MAX);
  if (own !== null) return own === 3;
  return raw.typeTable !== undefined && raw.typeTable !== null;
}

/*
 * The Gen 3 ruleset: { generation: 3, typeTable?, seed?, specialTypes?,
 * movePool?, terrain?, weather?, underwater? }. `typeTable` is optional (the
 * sim reads its absence as every matchup neutral, and src/Sheet3.lua sends none
 * when a cart's chart cannot be read); every optional field that is present
 * and unreadable refuses the whole ruleset. Twin of Wire.lua's battleRuleset3.
 */
function cleanBattleRuleset3(raw) {
  const out = { generation: 3 };
  const present = (v) => v !== undefined && v !== null;
  if (present(raw.typeTable)) {
    const typeTable = cleanTypeTable3(raw.typeTable);
    if (!typeTable) return null;
    out.typeTable = typeTable;
  }
  if (present(raw.seed)) {
    const seed = luaInt(raw.seed, 1, SEED_MAX);
    if (seed === null) return null;
    out.seed = seed;
  }
  if (present(raw.specialTypes)) {
    const list = luaList(raw.specialTypes);
    if (!list) return null;
    const special = [];
    for (const entry of list) {
      const t = luaInt(entry, 0, BATTLE_TYPE_MAX - 1);
      if (t === null) return null;
      special.push(t);
    }
    out.specialTypes = special;
  }
  if (present(raw.movePool)) {
    const list = luaList(raw.movePool);
    if (!list) return null;
    const pool = [];
    for (const entry of list) {
      if (pool.length >= BATTLE_MOVE_POOL3_MAX) break;
      const clean = cleanPoolEntry3(entry);
      if (!clean) return null;
      pool.push(clean);
    }
    out.movePool = pool;
  }
  if (present(raw.terrain)) {
    const terrain = luaInt(raw.terrain, 0, TERRAIN3_MAX);
    if (terrain === null) return null;
    out.terrain = terrain;
  }
  if (present(raw.weather)) {
    if (!WEATHERS3.has(raw.weather)) return null;
    out.weather = raw.weather;
  }
  if (present(raw.underwater)) {
    if (typeof raw.underwater !== 'boolean') return null;
    if (raw.underwater) out.underwater = true;
  }
  return out;
}

// `generation` (optional) is the hub's; Gen 1 / Gen 2 rulesets are read
// exactly as before.
function cleanBattleRuleset(raw, generation) {
  if (raw === null || typeof raw !== 'object') return null;
  if (rulesetIsGen3(raw, generation)) return cleanBattleRuleset3(raw);
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
  // The chart's axis by name (`typeIds`): each chart index's type registry id,
  // in order, which a referee names a move's type through -- lib/battle2 for
  // Gold's badge type boost and side-effect type checks, lib/battle for Red's
  // POISON immunity and FIRE thaw. 1..BATTLE_TYPE_MAX ids (the chart's own width
  // cap), each a cleanId, all or nothing. Unreadable is DROPPED, not refused,
  // unlike specialTypes: the list only names types, the chart stands without
  // it, and a content mod's type id need not fit the wire's id alphabet
  // ("mymod.FAIRY") -- refusing would cost a modded install every refereed
  // fight to keep those few rules. Nulls are closed up first (luaList), as
  // Lua's JSON decoder does before Wire.lua ever sees the list. Twin of
  // Wire.lua's typeIdsOf.
  if (raw.typeIds !== undefined && raw.typeIds !== null) {
    const typeIds = cleanIdList(luaList(raw.typeIds), BATTLE_TYPE_MAX);
    if (typeIds) ruleset.typeIds = typeIds;
  }
  // Read in the older dialect by name, never by sniffing a row's `num`: this is
  // a Gen 1 / Gen 2 ruleset. Twin of Wire.battleRuleset.
  if (raw.metronomePool !== undefined && raw.metronomePool !== null) {
    if (!Array.isArray(raw.metronomePool)) return null;
    const rowGeneration = luaInt(generation, 1, 2) ?? 1;
    const pool = [];
    for (const entry of raw.metronomePool) {
      if (pool.length >= METRONOME_POOL_MAX) break;
      const move = cleanBattleMove(entry, rowGeneration);
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
/*
 * The Gen 3 move row (docs/plans/gen3-battle-sheet.md §2): Gen 3 widths plus
 * `num`, `target`, `priority` and `flags`, every one required; `maxPp` and
 * `name` optional. Twin of Wire.lua's battleMove3.
 */
function cleanBattleMove3(raw) {
  const move = {
    id: cleanId(raw.id),
    num: luaInt(raw.num, 1, GEN3_MOVE_MAX),
    pp: luaInt(raw.pp, 0, PP_MAX),
    power: luaInt(raw.power, 0, POWER3_MAX),
    accuracy: luaInt(raw.accuracy, 0, ACCURACY3_MAX),
    type: luaInt(raw.type, 0, MOVE_TYPE_MAX),
    effect: luaInt(raw.effect, 0, EFFECT3_MAX),
    chance: luaInt(raw.chance, 0, CHANCE_MAX),
    target: luaInt(raw.target, 0, TARGET3_MAX),
    priority: luaInt(raw.priority, -PRIORITY3_MAX, PRIORITY3_MAX),
    flags: luaInt(raw.flags, 0, FLAGS3_MAX),
  };
  if (!move.id) return null;
  for (const key of Object.keys(move)) {
    if (move[key] === null) return null;
  }
  if (raw.maxPp !== undefined && raw.maxPp !== null) {
    const maxPp = luaInt(raw.maxPp, 0, PP_MAX);
    if (maxPp === null) return null;
    move.maxPp = maxPp;
  }
  if (raw.name !== undefined && raw.name !== null) {
    const name = cleanMoveName(raw.name);
    if (!name) return null;
    move.name = name;
  }
  return move;
}

// `generation` (optional): 3 reads the Gen 3 row, 1 or 2 the older row whatever
// else it carries; absent, a row that states a `num` is a Gen 3 row (no Gen 1 /
// Gen 2 sheet carries one). Every reader that knows its generation passes it.
// Twin of Wire.battleMove.
function cleanBattleMove(raw, generation) {
  if (raw === null || typeof raw !== 'object') return null;
  const gen = luaInt(generation, 1, GENERATION_MAX);
  if (gen === 3 || (gen === null && raw.num !== undefined && raw.num !== null)) {
    return cleanBattleMove3(raw);
  }
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
  // `name` (PROTOCOL 26) is the one field here that may legitimately be absent
  // besides `maxPp`, and for the same reason: absence is a real answer. It is
  // what the referee narrates the move under -- a hub holds no move table to
  // look one up in and never will -- and a sender that states none is a
  // protocol-25 client, whose fight narrates under `id` exactly as it always
  // did. Present-but-unreadable is refused rather than dropped, on this
  // function's own rule.
  if (raw.name !== undefined && raw.name !== null) {
    const name = cleanMoveName(raw.name);
    if (!name) return null;
    move.name = name;
  }
  // Optional high-crit flag. The hub has no move table, so Slash / Karate
  // Chop / Razor Leaf / Crabhammer have to state this on the sheet. Absent
  // is a protocol-era client (ordinary odds). Present-but-unreadable refuses,
  // same posture as a mangled name.
  if (raw.highCrit !== undefined && raw.highCrit !== null) {
    if (raw.highCrit !== true && raw.highCrit !== false) return null;
    if (raw.highCrit === true) move.highCrit = true;
  }
  // Contract K8 (docs/plans/gen12-referee-gaps-fix.md), optional like highCrit
  // and refused like it when present and unreadable: `ppUps` (Gen 1 and Gen 2,
  // the top two bits of the PP byte -- the cart's move pick reads that raw
  // byte, so a 0-PP move with PP Ups is still selectable) and `priority` (Gen
  // 2 only, the cart's raw GetMovePriority byte, which the referee reads before
  // its vanilla-id table). A Gen 1 row's `priority` is neither copied nor
  // refused, and a caller that names no generation reads none. Read the way
  // Wire.int reads them (luaInt): new on both twins. Twin of Wire.battleMove.
  if (raw.ppUps !== undefined && raw.ppUps !== null) {
    const ppUps = luaInt(raw.ppUps, 0, PP_UPS_MAX);
    if (ppUps === null) return null;
    move.ppUps = ppUps;
  }
  if (gen === 2 && raw.priority !== undefined && raw.priority !== null) {
    const priority = luaInt(raw.priority, 0, PRIORITY2_MAX);
    if (priority === null) return null;
    move.priority = priority;
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
 * **Bags (PROTOCOL 15).** Optional `bag` on the party message. Held on the
 * fight record only (not a hub inventory) and dropped when the fight is.
 * Who sends what: 1v1 / coop_pvp — each human uploads their own bag with
 * their party. 1xNPC / 2xNPC — each human still uploads their own; the
 * initiator (host) also uploads the NPC party as side "b" with that NPC's
 * items from *their* game data. Nobody else may fill side "b". The hub
 * holds a stack on `item` choice accept and decrements only when the turn
 * resolves, so cancel/unchose never needs a refund. Entries must be
 * BattleSim-known (`itemEffect`), including vitamins (fight-local Stat Exp;
 * client writebacks save.statExp). Counts and battler sheets remain a claim
 * (inventing 99 POTION or a god team on upload is the accepted bound).
 * Absent `bag` means empty.
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
 * tracks no IVs is fine and common, while a snapshot with two of the required
 * keys is a bug on the sending side that accepting would silently zero the rest
 * of.
 *
 * Optional `generation` (1|2) selects the stats dialect; absent falls back to
 * shape sniff on `stats`. Optional `heldItem` is a Gen 2 item id.
 *
 * The referee-fidelity additions (docs/plans/gen12-referee-fidelity.md), each
 * optional, so a sheet that carries none of them reads byte for byte as it did
 * before they existed (twin of the header above Wire.lua's block3):
 *
 *   K1  `traded` (Gen 1 and Gen 2): the mon's OT id is not the player's. Gen
 *       3's reading -- true kept, false kept as absent, anything else refuses.
 *   K2  the Gold held item's data next to `heldItem` (Gen 2 only; a Gen 1
 *       reader copies none of it): `holdEffect` (a HELD_* token,
 *       cleanHoldEffect2), `holdParam` (0..255), `itemName` (display text,
 *       ITEM_NAME2_MAX) and `mail` (true or absent). Each refuses the mon when
 *       present and unreadable, as `heldItem` and Gen 3's hold effect do.
 */
// A Gen 3 stat-like block: every key at the caller's width, nothing else.
function cleanBlock3(value, keys, min, max) {
  if (value === null || typeof value !== 'object') return null;
  const out = {};
  for (const key of keys) {
    const n = luaInt(value[key], min, max);
    if (n === null) return null;
    out[key] = n;
  }
  return out;
}

const IV_KEYS3 = ['hp', 'atk', 'def', 'spe', 'spa', 'spd'];

/*
 * One Gen 3 battler (docs/plans/gen3-battle-sheet.md §2, contract C4). The Gen
 * 2 stat keys (final stats) plus what the Gen 3 sim reads off a sheet because
 * the hub holds no species, item or ability table -- all required. Optional,
 * each refused when present and unreadable: display names, slot, status /
 * sleepTurns, catchRate, the passthrough ivs / evs / personality / otId, the
 * caught sheet's ball, the obedience check's traded / unfateful (booleans, a
 * player's own sheet only), and weight / hiddenPower / beatUp -- which are
 * required on an *upload* (cleanBattleParty checks them) but not on an
 * outcome's caught sheet. Twin of Wire.lua's battleMon3.
 */
function cleanBattleMon3(raw) {
  const stats = cleanBlock3(raw.stats, BATTLE_STATS_GEN2, 1, STAT_MAX);
  if (!stats) return null;
  const status = cleanBattleStatus(raw.status);
  if (status === false) return null;

  const mon = {
    generation: 3,
    species: cleanText(raw.species, NAME_MAX),
    speciesNum: luaInt(raw.speciesNum, 1, GEN3_SPECIES_MAX),
    level: luaInt(raw.level, 1, LEVEL_MAX),
    hp: luaInt(raw.hp, 0, HP_MAX),
    maxHp: luaInt(raw.maxHp, 1, HP_MAX),
    stats,
    ability: luaInt(raw.ability, 0, GEN3_ABILITY_MAX),
    heldItem: luaInt(raw.heldItem, 0, GEN3_ITEM_MAX),
    holdEffect: luaInt(raw.holdEffect, 0, HOLD_EFFECT3_MAX),
    holdEffectParam: luaInt(raw.holdEffectParam, 0, HOLD_PARAM3_MAX),
    gender: GENDERS3.has(raw.gender) ? raw.gender : null,
    friendship: luaInt(raw.friendship, 0, 255),
    nature: luaInt(raw.nature, 0, GEN3_NATURE_COUNT - 1),
  };
  if (!mon.species) return null;
  for (const key of Object.keys(mon)) {
    if (mon[key] === null) return null;
  }
  if (mon.hp > mon.maxHp) return null;
  // Written only when there is one, as the older dialect does.
  if (status) mon.status = status;

  const typeList = luaList(raw.types);
  if (!typeList) return null;
  const types = [];
  for (const entry of typeList) {
    if (types.length >= 2) break;
    const t = luaInt(entry, 0, BATTLE_TYPE_MAX - 1);
    if (t === null) return null;
    types.push(t);
  }
  if (!types.length) return null;
  mon.types = types;

  const moveList = luaList(raw.moves);
  if (!moveList) return null;
  const moves = [];
  for (const entry of moveList) {
    if (moves.length >= BATTLE_MOVE_MAX) return null;
    const move = cleanBattleMove(entry, 3);
    if (!move) return null;
    moves.push(move);
  }
  if (!moves.length) return null;
  mon.moves = moves;

  const present = (v) => v !== undefined && v !== null;
  if (present(raw.speciesId)) {
    const speciesId = cleanId(raw.speciesId);
    if (!speciesId) return null;
    mon.speciesId = speciesId;
  }
  if (present(raw.slot)) {
    const slot = luaInt(raw.slot, 0, SLOT_MAX);
    if (slot === null) return null;
    mon.slot = slot;
  }
  if (present(raw.abilityName)) {
    const abilityName = cleanMoveName(raw.abilityName);
    if (!abilityName) return null;
    mon.abilityName = abilityName;
  }
  if (present(raw.itemName)) {
    const itemName = cleanMoveName(raw.itemName);
    if (!itemName) return null;
    mon.itemName = itemName;
  }
  if (present(raw.weight)) {
    const weight = luaInt(raw.weight, 0, WEIGHT3_MAX);
    if (weight === null) return null;
    mon.weight = weight;
  }
  if (present(raw.hiddenPower)) {
    if (typeof raw.hiddenPower !== 'object') return null;
    const type = luaInt(raw.hiddenPower.type, 0, MOVE_TYPE_MAX);
    const power = luaInt(raw.hiddenPower.power, 0, POWER3_MAX);
    if (type === null || power === null) return null;
    mon.hiddenPower = { type, power };
  }
  if (present(raw.beatUp)) {
    if (typeof raw.beatUp !== 'object') return null;
    const atk = luaInt(raw.beatUp.atk, 1, 255);
    const def = luaInt(raw.beatUp.def, 1, 255);
    if (atk === null || def === null) return null;
    mon.beatUp = { atk, def };
  }
  if (present(raw.sleepTurns)) {
    const sleepTurns = luaInt(raw.sleepTurns, 0, SLEEP3_MAX);
    if (sleepTurns === null) return null;
    mon.sleepTurns = sleepTurns;
  }
  if (present(raw.catchRate)) {
    const catchRate = luaInt(raw.catchRate, 0, 255);
    if (catchRate === null) return null;
    mon.catchRate = catchRate;
  }
  if (present(raw.ivs)) {
    const ivs = cleanBlock3(raw.ivs, IV_KEYS3, 0, GEN3_IV_MAX);
    if (!ivs) return null;
    mon.ivs = ivs;
  }
  if (present(raw.evs)) {
    const evs = cleanBlock3(raw.evs, IV_KEYS3, 0, GEN3_EV_MAX);
    if (!evs) return null;
    mon.evs = evs;
  }
  if (present(raw.personality)) {
    const personality = luaInt(raw.personality, 0, U32_MAX);
    if (personality === null) return null;
    mon.personality = personality;
  }
  if (present(raw.otId)) {
    const otId = luaInt(raw.otId, 0, U32_MAX);
    if (otId === null) return null;
    mon.otId = otId;
  }
  if (present(raw.ball)) {
    const ball = luaInt(raw.ball, 0, GEN3_ITEM_MAX);
    if (ball === null) return null;
    mon.ball = ball;
  }
  // The obedience check's facts about a player's own monster (contract K2,
  // docs/plans/gen3-badge-rules.md): true or absent, so a false is kept as
  // absent and anything that is not a boolean refuses the mon -- the ruleset's
  // `underwater` posture. `unfateful` names a Mew / Deoxys whose
  // fateful-encounter bit is explicitly clear (the engine's
  // `fatefulEncounter == false`); its absence is the ordinary rules, so the
  // retired `fateful` is not copied and a sheet still carrying one fights as
  // if it said nothing. `unfateful` is Gen 3's alone (neither Kanto nor Johto
  // cart has an event-Mew rule): the Gen 1 / Gen 2 reader builds its sheet
  // field by field and never copies it. `traded` it does copy, in this same
  // reading (contract K1 of docs/plans/gen12-referee-fidelity.md).
  if (present(raw.traded)) {
    if (typeof raw.traded !== 'boolean') return null;
    if (raw.traded) mon.traded = true;
  }
  if (present(raw.unfateful)) {
    if (typeof raw.unfateful !== 'boolean') return null;
    if (raw.unfateful) mon.unfateful = true;
  }
  return mon;
}

function cleanBattleMon(raw) {
  if (raw === null || typeof raw !== 'object') return null;
  // `generation` 3 selects the Gen 3 dialect (cleanBattleParty stamps it from
  // the hub's generation); 1 / 2 / absent is the older dialect below -- as it
  // read before Gen 3 had one, plus the optional K1 / K2 fields (see the header
  // above cleanBlock3), so a sheet that states none of them reads exactly as it
  // always did.
  if (luaInt(raw.generation, 3, 3) !== null) return cleanBattleMon3(raw);

  const generationHint = cleanInt(raw.generation, 1, 2);
  const stats = cleanStatBlock(raw.stats, 1, STAT_MAX, generationHint);
  if (!stats) return null;
  const generation = generationHint !== null
    ? generationHint
    : (stats.spa !== undefined ? 2 : 1);

  const status = cleanBattleStatus(raw.status);
  if (status === false) return null;

  const species = cleanText(raw.species, NAME_MAX);
  const level = cleanInt(raw.level, 1, LEVEL_MAX);
  const hp = cleanInt(raw.hp, 0, HP_MAX);
  const maxHp = cleanInt(raw.maxHp, 1, HP_MAX);
  if (!species || level === null || hp === null || maxHp === null) return null;
  if (hp > maxHp) return null;

  const mon = { species, level, hp, maxHp, stats, generation };
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
    const ivs = cleanStatBlock(raw.ivs, 0, IV_MAX, generation);
    if (!ivs) return null;
    mon.ivs = ivs;
  }
  if (raw.evs !== undefined && raw.evs !== null) {
    const evs = cleanStatBlock(raw.evs, 0, EV_MAX, generation);
    if (!evs) return null;
    if (raw.evs.hp !== undefined && raw.evs.hp !== null) {
      const hpEv = cleanInt(raw.evs.hp, 0, EV_MAX);
      if (hpEv === null) return null;
      evs.hp = hpEv;
    }
    mon.evs = evs;
  }

  if (!Array.isArray(raw.moves)) return null;
  if (raw.moves.length < 1 || raw.moves.length > BATTLE_MOVE_MAX) return null;
  const moves = [];
  for (const entry of raw.moves) {
    // This sheet's own dialect (1 or 2, resolved above), so a stray `num` on a
    // row is ignored rather than sending the row to the Gen 3 reader.
    const move = cleanBattleMove(entry, generation);
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

  if (raw.heldItem !== undefined && raw.heldItem !== null) {
    const heldItem = cleanId(raw.heldItem);
    if (!heldItem) return null;
    mon.heldItem = heldItem;
  }

  // What the Gold referee reads off that item (contract K2): the effect token,
  // its parameter, the name the box narrates under and whether it is Mail
  // (which Thief cannot take) -- the hub holds no item table. Gen 2 only, by
  // the dialect this sheet resolved to; a Gen 1 reader copies none of them.
  // Present and unreadable refuses the mon (`heldItem`'s posture); `mail` is
  // read the way `traded` is (below). New on both twins, so the parameter is
  // read the way Wire.int reads it (luaInt), not cleanInt.
  if (generation === 2) {
    if (raw.holdEffect !== undefined && raw.holdEffect !== null) {
      const holdEffect = cleanHoldEffect2(raw.holdEffect);
      if (!holdEffect) return null;
      mon.holdEffect = holdEffect;
    }
    if (raw.holdParam !== undefined && raw.holdParam !== null) {
      const holdParam = luaInt(raw.holdParam, 0, HOLD_PARAM2_MAX);
      if (holdParam === null) return null;
      mon.holdParam = holdParam;
    }
    if (raw.itemName !== undefined && raw.itemName !== null) {
      const itemName = cleanText(raw.itemName, ITEM_NAME2_MAX);
      if (!itemName) return null;
      mon.itemName = itemName;
    }
    if (raw.mail !== undefined && raw.mail !== null) {
      if (typeof raw.mail !== 'boolean') return null;
      if (raw.mail) mon.mail = true;
    }
  }

  // Optional registry id for the species, alongside the prose `species` above.
  //
  // `species` is what the fight is *narrated* under, which is the nickname when
  // the monster has one -- so it is the one field that cannot be resolved back
  // to a pokedex row, and a nicknamed monster arrived on the other player's
  // screen as a blank seat with no front pic and no level. The id is what art,
  // types and the exp base rate are actually looked up by, so it travels as its
  // own id-shaped field rather than overloading the prose one -- which is the
  // rule this file's own header states.
  //
  // Optional both ways: a PROTOCOL 21 client sends none, and present-but-
  // unreadable refuses the battler, the posture every other id-shaped field on
  // this sheet gets.
  if (raw.speciesId !== undefined && raw.speciesId !== null) {
    const speciesId = cleanId(raw.speciesId);
    if (!speciesId) return null;
    mon.speciesId = speciesId;
  }

  // Optional species base Speed for Gen 1 crit. The hub has no species table,
  // so this has to ride the sheet; Crit.check must not see battle Speed or the
  // Speed badge. Absent is a protocol-era client (sim falls back to stats.spd
  // without a badge boost). Present-but-unreadable refuses the battler.
  if (raw.baseSpd !== undefined && raw.baseSpd !== null) {
    const baseSpd = cleanInt(raw.baseSpd, 0, 255);
    if (baseSpd === null) return null;
    mon.baseSpd = baseSpd;
  }

  // The obedience check's one fact about a player's own monster (contract K1):
  // its 16-bit OT id is not the player's. Gen 1 and Gen 2 alike, read exactly as
  // cleanBattleMon3 reads Gen 3's -- true kept, false kept as absent, anything
  // that is not a boolean refuses the mon. No `unfateful` here: a Gen 3 rule.
  if (raw.traded !== undefined && raw.traded !== null) {
    if (typeof raw.traded !== 'boolean') return null;
    if (raw.traded) mon.traded = true;
  }

  // Contract K7 (docs/plans/gen12-referee-gaps-fix.md): what the cart computes
  // the stats from -- `base` (species base stats, keyed like `stats` plus hp,
  // 0..BASE_STAT_MAX), `dvs` (the cart's four DVs, 0..DV_MAX; the HP DV is
  // derived) and `statExp` (the cart's five stat-exp words, 0..STAT_EXP_MAX)
  // -- so the referee can run CalcMonStat itself (a transformed foe's crit
  // stat, the copied species' base Speed, a level-up rebuild). Each optional
  // and whole-or-refused (cleanBlock3's reading, `ivs` / `evs`' posture). Gen 1
  // / Gen 2 only: cleanBattleMon3 reads none of them. Twin of Wire.battleMon.
  const keys = generation === 2 ? K7_KEYS2 : K7_KEYS1;
  if (raw.base !== undefined && raw.base !== null) {
    const base = cleanBlock3(raw.base, keys.base, 0, BASE_STAT_MAX);
    if (!base) return null;
    mon.base = base;
  }
  if (raw.dvs !== undefined && raw.dvs !== null) {
    const dvs = cleanBlock3(raw.dvs, keys.dvs, 0, DV_MAX);
    if (!dvs) return null;
    mon.dvs = dvs;
  }
  if (raw.statExp !== undefined && raw.statExp !== null) {
    const statExp = cleanBlock3(raw.statExp, keys.statExp, 0, STAT_EXP_MAX);
    if (!statExp) return null;
    mon.statExp = statExp;
  }

  // Contract K14 (docs/plans/gen12-referee-gaps-fix.md, added after wave 1):
  // the monster's happiness, 0..HAPPINESS2_MAX, which Gold's RETURN and
  // FRUSTRATION turn into power (pokecrystal BattleCommand_HappinessPower /
  // _FrustrationPower read w*MonHappiness, never a species value). Gen 2 only,
  // by the dialect this sheet resolved to: a Gen 1 reader neither copies nor
  // refuses one (Red has no such byte), and cleanBattleMon3 reads Gen 3's own
  // `friendship`. Optional, and refused with the sheet when present and
  // unreadable -- K7's posture and holdParam's, for their reason: a dropped one
  // would have the referee fight with a number the owner never had. Read the
  // way Wire.int reads it (luaInt). Twin of Wire.battleMon.
  if (generation === 2 && raw.happiness !== undefined && raw.happiness !== null) {
    const happiness = luaInt(raw.happiness, 0, HAPPINESS2_MAX);
    if (happiness === null) return null;
    mon.happiness = happiness;
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
 * `generation` selects Effects.itemEffect (1 = Gen1, 2 = Gen2); omitted → 1.
 */
/*
 * A Gen 3 bag id: a pret item number, as a JSON number or the numeric string a
 * map key (or a choice) spells it as -- nothing else. Twin of Wire.itemId3.
 */
function cleanItemId3(value) {
  if (typeof value === 'string') {
    if (!/^\d+$/.test(value)) return null;
  } else if (typeof value !== 'number') {
    return null;
  }
  const n = Number(value);
  if (n !== Math.floor(n)) return null;
  return luaInt(n, 1, GEN3_ITEM_MAX);
}

/*
 * The Gen 3 bag (§4): list of { id, count, name? } or a map id -> count,
 * numeric pret ids restricted to lib/battle3's catalog. Out: { id: <number>,
 * count, name? } sorted by id. Twin of Wire.lua's battleBag3.
 */
function cleanBattleBag3(raw) {
  const out = [];
  const seen = new Set();
  const push = (id, count, name) => {
    if (id === null || count === null) return false;
    if (seen.has(id) || out.length >= BATTLE_BAG_MAX) return false;
    if (!EffectsGen3.itemEffect(id)) return false;
    seen.add(id);
    const entry = { id, count };
    if (name) entry.name = name;
    out.push(entry);
    return true;
  };
  // Lists and maps read as the Lua decoder leaves them (luaList, luaEntries):
  // a null element or value is not there at all.
  if (Array.isArray(raw)) {
    for (const entry of luaList(raw)) {
      if (entry === null || typeof entry !== 'object') return null;
      let name = null;
      if (entry.name !== undefined && entry.name !== null) {
        name = cleanMoveName(entry.name);
        if (!name) return null;
      }
      if (!push(cleanItemId3(entry.id), luaInt(entry.count, 1, BATTLE_BAG_COUNT_MAX), name)) {
        return null;
      }
    }
  } else {
    for (const [key, value] of luaEntries(raw)) {
      if (!push(cleanItemId3(key), luaInt(value, 1, BATTLE_BAG_COUNT_MAX), null)) return null;
    }
  }
  out.sort((a, b) => a.id - b.id);
  return out;
}

function cleanBattleBag(raw, generation) {
  if (raw === undefined || raw === null) return [];
  if (typeof raw !== 'object') return null;
  if (generation === 3) return cleanBattleBag3(raw);

  const Effects = effectsFor(generation);
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

// The three formula inputs a Gen 3 upload must carry (see cleanBattleMon3).
function uploadComplete3(mon) {
  return mon.weight !== undefined && mon.hiddenPower !== undefined
    && mon.beatUp !== undefined;
}

function cleanBattleParty(raw, hubGeneration) {
  if (raw === null || typeof raw !== 'object') return null;
  const battle = cleanId(raw.battle);
  if (!battle) return null;

  const party = { battle };
  const badges = cleanBadgeSet(raw.badges);
  if (badges) party.badges = badges;

  // Hub generation (second arg) is authoritative when provided: stamp
  // party.generation from it, and refuse when an explicit party/mon
  // generation disagrees (mirrors Wire.battleParty).
  // 1..GENERATION_MAX: a Gen 3 hub (PROTOCOL 30) reads its parties in the
  // Gen 3 dialect (cleanBattleMon3, cleanBattleBag3).
  const hubGen = hubGeneration !== undefined && hubGeneration !== null
    ? cleanInt(hubGeneration, 1, GENERATION_MAX)
    : null;
  if (hubGeneration !== undefined && hubGeneration !== null && hubGen === null) {
    return null;
  }
  // A Gen 3 hub reads the tags a sheet carries the way Wire.int does (luaInt:
  // the dialect is new on both twins); Gen 1 / Gen 2 keep cleanInt as ever.
  const genInt = hubGen === 3 ? luaInt : cleanInt;

  let partyGen = genInt(raw.generation, 1, GENERATION_MAX);
  if (raw.generation !== undefined && raw.generation !== null && partyGen === null) {
    return null;
  }
  if (hubGen !== null && partyGen !== null && partyGen !== hubGen) {
    return null;
  }
  if (hubGen !== null) {
    party.generation = hubGen;
    partyGen = hubGen;
  } else if (partyGen !== null) {
    party.generation = partyGen;
  }

  if (raw.side !== undefined && raw.side !== null) {
    const side = cleanSide(raw.side);
    if (!side) return null;
    party.side = side;
  }

  // A Gen 3 party's list is read as the Lua decoder leaves it (luaList).
  const monList = partyGen === 3 ? luaList(raw.mons) : raw.mons;
  if (!Array.isArray(monList)) return null;
  if (monList.length < 1 || monList.length > BATTLE_MON_MAX) return null;
  const mons = [];
  for (const entry of monList) {
    if (entry !== null && typeof entry === 'object'
        && entry.generation !== undefined && entry.generation !== null) {
      const monGen = genInt(entry.generation, 1, GENERATION_MAX);
      if (monGen === null) return null;
      if (hubGen !== null && monGen !== hubGen) return null;
    }
    let sheet = entry;
    if (partyGen !== null && entry !== null && typeof entry === 'object'
        && (entry.generation === undefined || entry.generation === null)) {
      sheet = { ...entry, generation: partyGen };
    }
    const mon = cleanBattleMon(sheet);
    if (!mon) return null;
    // A Gen 3 sheet has to be complete as an *upload* (weight, hiddenPower,
    // beatUp -- an outcome's caught sheet may leave them out), and a Gen 3
    // party holds no Gen 1 / Gen 2 mon. Twin of Wire.battleParty.
    if (mon.generation === 3 && !uploadComplete3(mon)) return null;
    if ((partyGen === 3) !== (mon.generation === 3)) return null;
    mons.push(mon);
  }
  party.mons = mons;

  const bag = cleanBattleBag(raw.bag, partyGen !== null ? partyGen : hubGen);
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
 *
 * `generation` (optional) is the hub's. Only 3 reads Gen 3's two extra fields,
 * and reads every index the way Wire.int does (luaInt); a Gen 1 / Gen 2 hub --
 * and a caller that names none -- reads a choice exactly as it did before Gen 3
 * existed, ignoring them whatever they hold. Twin of Wire.battleChoice.
 */
function cleanBattleChoice(raw, generation) {
  if (raw === null || typeof raw !== 'object') return null;
  const needs = BATTLE_ACTIONS.get(raw.action);
  if (!needs) return null;
  const battle = cleanId(raw.battle);
  if (!battle) return null;
  const gen3 = luaInt(generation, 3, 3) !== null;
  const readInt = gen3 ? luaInt : cleanInt;

  const choice = { battle, action: raw.action };
  if (raw.slot !== undefined && raw.slot !== null) {
    const slot = readInt(raw.slot, 0, SLOT_MAX);
    if (slot === null) return null;
    choice.slot = slot;
  }
  if (raw.move !== undefined && raw.move !== null) {
    const move = readInt(raw.move, 0, BATTLE_MOVE_MAX - 1);
    if (move === null) return null;
    choice.move = move;
  }
  if (raw.target !== undefined && raw.target !== null) {
    // A field slot, not a party slot: an event and a target both point at
    // somebody who is out, not at a bench position.
    const target = readInt(raw.target, 0, FIELD_MAX);
    if (target === null) return null;
    choice.target = target;
  }
  if (raw.item !== undefined && raw.item !== null) {
    const item = cleanId(raw.item);
    if (!item) return null;
    choice.item = item;
  }
  // Gen 3 (docs/plans/gen3-battle-sheet.md §1.2): Baton Pass's destination (a
  // *party* index, asked up front) and the thrower's word that its dex has the
  // wild species caught (Repeat Ball). A Gen 3 item rides in `item` as its
  // numeric id spelled as a string. Neither field exists in Gen 1 / Gen 2, so
  // neither is read there. Twin of Wire.battleChoice.
  if (gen3) {
    if (raw.pass !== undefined && raw.pass !== null) {
      const pass = luaInt(raw.pass, 0, SLOT_MAX);
      if (pass === null) return null;
      choice.pass = pass;
    }
    if (raw.dexCaught !== undefined && raw.dexCaught !== null) {
      if (typeof raw.dexCaught !== 'boolean') return null;
      choice.dexCaught = raw.dexCaught;
    }
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
 *
 * `generation` (optional) is the reader's own. 1 or 2 reads an event as it did
 * before Gen 3 had a stream: the older vocabulary only (none of Gen 3's seven
 * kinds), none of its six fields (target, spread, stat, stage, delta, holding),
 * and `moves` rows in the older dialect whatever `num` they carry. The one
 * addition since is Gold's own `held` (BATTLE_EVENT_TYPES2, contract K3), which
 * a generation 2 reader alone accepts -- a Gen 1 reader's vocabulary is
 * unchanged, and every event a Gold reader already accepted reads exactly as
 * before. 3, or none named, reads the union of the older vocabulary and Gen
 * 3's, so its `held` is Gen 3's. Twin of Wire.battleEvent.
 */
function cleanBattleEvent(raw, generation) {
  if (raw === null || typeof raw !== 'object') return null;
  const gen = luaInt(generation, 1, GENERATION_MAX);
  const older = gen === 1 || gen === 2;
  const gold = gen === 2;
  if (!BATTLE_EVENT_TYPES.has(raw.t) && !(!older && BATTLE_EVENT_TYPES3.has(raw.t))
      && !(gold && BATTLE_EVENT_TYPES2.has(raw.t))) return null;
  const battle = cleanId(raw.battle);
  const seq = cleanInt(raw.seq, 0, SEQ_MAX);
  if (!battle || seq === null) return null;

  const event = { battle, seq, t: raw.t };
  // A Gold `held` is the one kind whose shape depends on who reads it.
  const held2 = gold && raw.t === 'held';
  if (raw.text !== undefined && raw.text !== null) {
    // Item / anim `text` is an id (POKE_BALL, TOSS_ANIM, move id) — cleanText strips `_`.
    // A Gen 3 `ball` names its ball the way `item` does (the numeric id, "4"),
    // and so does a Gold `held` (LEFTOVERS): the client matches it against the
    // item its own save holds, where Gen 3's `held` text is the name it prints.
    // An `obey`'s is one of the eight outcome tokens or nothing (Wire.lua's
    // reading): dropped like any mangled field, never refused whole.
    let text;
    if (raw.t === 'item' || raw.t === 'anim' || raw.t === 'ball' || held2) text = cleanId(raw.text);
    else if (raw.t === 'obey') text = OBEY_TOKENS3.has(raw.text) ? raw.text : null;
    else text = cleanText(raw.text, MESSAGE_MAX);
    if (text) event.text = text;
  }
  if (raw.amount !== undefined && raw.amount !== null) {
    // A Gold `held`'s `amount` is a flag (1 still held, 0 gone), anything else
    // dropped -- a `held` with no `amount` changes nothing a client keeps. New
    // on both twins, so read the way Wire.int reads it (luaInt).
    const amount = held2 ? luaInt(raw.amount, 0, 1) : cleanInt(raw.amount, 0, AMOUNT_MAX);
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
  // What that HP is out of, on the events that can move it: `send` states it
  // for the monster walking on, and a `drain` states it when an HP UP raised
  // the ceiling itself. Optional, and its absence is not a zero: a client that
  // is told none falls back to the oldest reading of this wire -- the largest
  // HP it has ever seen on the seat -- which is right for a monster that came
  // out whole and wrong for one that came out hurt. Floored at 1 for the reason
  // cleanBattleMon floors it there: the bar divides by it.
  if (raw.maxHp !== undefined && raw.maxHp !== null) {
    const maxHp = cleanInt(raw.maxHp, 1, HP_MAX);
    if (maxHp !== null) event.maxHp = maxHp;
  }
  // `exp` carries the facts a client needs to run its own award: which monster
  // fell and how many shares split it. Same sanitisers a battler's own fields
  // get (cleanText over NAME_MAX / cleanInt over LEVEL_MAX), because they are
  // the same quantities read off the same monster -- an event is not a second
  // dialect for them.
  if (raw.species !== undefined && raw.species !== null) {
    const species = cleanText(raw.species, NAME_MAX);
    if (species) event.species = species;
  }
  // The same monster's registry id, and the reason it is a second field rather
  // than a spelling of the one above: `species` is prose (a nickname when the
  // monster has one), and prose resolves back to a pokedex row only by luck.
  // `send` / `switch` carry it so the seat opposite can draw a front pic and an
  // exp award can price a nicknamed monster; `exp` carries it for the award.
  // Optional -- an intermediator that predates it sends none, and every reader
  // falls back to matching the prose name exactly as it did before.
  if (raw.speciesId !== undefined && raw.speciesId !== null) {
    const speciesId = cleanId(raw.speciesId);
    if (speciesId) event.speciesId = speciesId;
  }
  if (raw.level !== undefined && raw.level !== null) {
    const level = cleanInt(raw.level, 1, LEVEL_MAX);
    if (level !== null) event.level = level;
  }
  if (raw.participants !== undefined && raw.participants !== null) {
    // Deliberately not `winners`: an outcome's winners is a list of player ids,
    // and one name over two shapes is the sanitiser bug that reads a count as a
    // roster. This one is a count, and on Gen 1 / Gen 2 it divides.
    //
    // Gen 3 (or none named) also reads 0: BattleSim3's holders-only fact (sheet
    // doc §7.1), which carries no `mon` -- see PARTICIPANTS_MAX. Read there the
    // way Wire.int reads it (luaInt), like the rest of the Gen 3 fields; the
    // older readings keep cleanInt, byte for byte.
    const participants = older
      ? cleanInt(raw.participants, 1, PARTICIPANTS_MAX)
      : luaInt(raw.participants, 0, PARTICIPANTS_MAX);
    if (participants !== null) event.participants = participants;
  }
  // Which of the winner's six the award is *for* -- a **party** index, bounded
  // by SLOT_MAX, and so the one field on an event that is not about the field.
  // It has to be: vanilla pays every mon that fought the fallen foe and lived,
  // and a benched one has no field slot to name. `slot` above still carries the
  // owning fighter's seat, which is what gates the award to a player; `mon`
  // says which of that player's monsters banks it.
  //
  // Optional, and its absence is meaningful rather than a defect: a PROTOCOL 21
  // referee that predates this field pays the mon that was standing at the
  // faint, so a client that gets no `mon` falls back to the active one.
  if (raw.mon !== undefined && raw.mon !== null) {
    const mon = cleanInt(raw.mon, 0, SLOT_MAX);
    if (mon !== null) event.mon = mon;
  }
  // The `team` event's roster (PROTOCOL 24), and the one field here that is
  // neither a number nor prose: a fixed alphabet, one character per party
  // member. Dropped rather than trimmed when it does not parse -- see
  // cleanBattleTeam, where a short roster is a different party rather than a
  // shorter sentence. A `team` event that loses its roster is an event with
  // nothing in it, which is exactly what a client ignores.
  if (raw.team !== undefined && raw.team !== null) {
    const team = cleanBattleTeam(raw.team);
    if (team) event.team = team;
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
  // Fight-local volatile, not a standing status: 1 confused, 0 snapped out.
  // Absent means "do not touch the chip". Never a party-sheet field.
  if (raw.confused !== undefined && raw.confused !== null) {
    const confused = cleanInt(raw.confused, 0, 1);
    if (confused !== null) event.confused = confused;
  }
  // Gen 3's six fields (§7.3), each dropped rather than fatal like the rest:
  // target (a field slot), spread (0/1), stat (which stat), stage (-6..6, where
  // it now sits), delta (-12..12, the change applied -- signed, where `amount`
  // is unsigned), holding (the item a `held` event leaves held, 0 = none). Read
  // the way Wire.int reads them (luaInt): they are new on both twins.
  if (!older) {
    if (raw.target !== undefined && raw.target !== null) {
      const target = luaInt(raw.target, 0, FIELD_MAX);
      if (target !== null) event.target = target;
    }
    if (raw.spread !== undefined && raw.spread !== null) {
      const spread = luaInt(raw.spread, 0, 1);
      if (spread !== null) event.spread = spread;
    }
    if (raw.stat !== undefined && raw.stat !== null && EVENT_STATS3.has(raw.stat)) {
      event.stat = raw.stat;
    }
    if (raw.stage !== undefined && raw.stage !== null) {
      const stage = luaInt(raw.stage, -STAGE3_MAX, STAGE3_MAX);
      if (stage !== null) event.stage = stage;
    }
    if (raw.delta !== undefined && raw.delta !== null) {
      const delta = luaInt(raw.delta, -DELTA3_MAX, DELTA3_MAX);
      if (delta !== null) event.delta = delta;
    }
    if (raw.holding !== undefined && raw.holding !== null) {
      const holding = luaInt(raw.holding, 0, GEN3_ITEM_MAX);
      if (holding !== null) event.holding = holding;
    }
  }
  // The one Gen 3 field the older dialect now reads too (contract K10 of
  // docs/plans/gen12-referee-gaps-fix.md): a `stat` event's signed stage, -6..6.
  // `amount` stays unsigned, so a stage below zero never fit in it. Dropped
  // like every mangled field here. Twin of Wire.battleEvent.
  if (older && raw.stage !== undefined && raw.stage !== null) {
    const stage = luaInt(raw.stage, -STAGE12_MAX, STAGE12_MAX);
    if (stage !== null) event.stage = stage;
  }
  if (raw.moves !== undefined && raw.moves !== null) {
    if (Array.isArray(raw.moves)) {
      const moves = [];
      for (const entry of raw.moves) {
        if (moves.length >= BATTLE_MOVE_MAX) break;
        const move = cleanBattleMove(entry, gen);
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
 *
 * `generation` (optional) is the reader's own, cleanBattleEvent's convention.
 * Every reader reads `payDay` (Gen 1 / Gen 2 from contract K11 of
 * docs/plans/gen12-referee-gaps-fix.md); the bound is the reader's cart's --
 * PAYDAY12_MAX for 1 or 2, PAYDAY3_MAX for 3 or none named, exactly as before.
 * Twin of Wire.battleOutcome.
 */
function cleanBattleOutcome(raw, generation) {
  if (raw === null || typeof raw !== 'object') return null;
  const gen = luaInt(generation, 1, GENERATION_MAX);
  const older = gen === 1 || gen === 2;
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
  // Optional catcher: who keeps the mon on a coop_wild catch. Absent is fine
  // (solo wild / KO outcomes need no thrower); present-and-bad refuses the
  // whole outcome -- same posture as winners/losers, since this is the name
  // a grant moves for.
  if (raw.catcher !== undefined && raw.catcher !== null) {
    const catcher = cleanId(raw.catcher);
    if (!catcher) return null;
    result.catcher = catcher;
  }
  // Pay Day coins (Gen 3: sheet doc §1, §6; Gen 1 / Gen 2: contract K11): side
  // a's total, present only on a knockout win in a wild / coop_wild / coop_npc
  // fight -- and, on Red alone, on a wild fight that ended in an escape (reason
  // `run`: pokered's EndOfBattle pays whenever wBattleResult is still 0, and a
  // Teleport / Whirlwind / Roar / POKE DOLL escape never writes it; Gold calls
  // every escape a DRAW and Gen 3 pays only from HandleEndTurn_BattleWon, so
  // both hubs keep the field off those -- Relay.settleMediated). Read on every
  // outcome alike, whatever the reason: which endings pay is the referee's to
  // say, and on a run the payees are side a's players whichever list names
  // them. **Dropped rather than fatal**, unlike the fields above: a wrong
  // winner or catcher moves a rating or a monster to the wrong player, where a
  // mangled coin count has no recipient of its own (side a of a fight against
  // the computer is every player in it), and refusing the whole outcome over
  // it would strand a finished fight on a screen with no way out to protect a
  // bonus. Read the way Wire.int reads it (luaInt). The Amulet Coin doubling is
  // the reader's, never the wire's. A zero is no coins, read as absent on every
  // cart. Twin of Wire.battleOutcome.
  if (raw.payDay !== undefined && raw.payDay !== null) {
    const payDay = luaInt(raw.payDay, 1, older ? PAYDAY12_MAX : PAYDAY3_MAX);
    if (payDay !== null) result.payDay = payDay;
  }
  return result;
}

// mmo.battle_moveset. One of the sender's own party members, as they now
// claim its moves (PROTOCOL 28). Bounded numbers, 1..BATTLE_MOVE_MAX long;
// a missing field refuses the message rather than applying a half-sheet
// over a live battler. The hub then allows only add-one or replace-one.
// `generation` (optional) is the hub's and picks the move-row dialect the way
// cleanBattleMove documents.
//
// A mid-fight level-up rides here too (contract K9 of
// docs/plans/gen12-referee-gaps-fix.md): generation 1 or 2 only, each optional
// and present-and-unreadable refusing the message like a mangled move --
// `level` (1..LEVEL_MAX), `stats` (the sheet's `stats` block in the hub's
// dialect) and `maxHp` (1..HP_MAX; the cart raises current HP by the step it
// raises the maximum, GainExperience). Moves that are the hub's own plus any of
// them is a level-up that taught nothing, as valid as a learn; plausibility is
// the referee's to judge (Relay.applyBattleMoveset forwards it). Read the way
// Wire.int reads them (luaInt, cleanBlock3): new on both twins. Twin of
// Wire.battleMoveset.
function cleanBattleMoveset(raw, generation) {
  if (raw === null || typeof raw !== 'object') return null;
  // Gen 3 reads its index and list the way Wire.lua is handed them (luaInt,
  // luaList); Gen 1 / Gen 2 exactly as before.
  const gen3 = luaInt(generation, 3, 3) !== null;
  const battle = cleanId(raw.battle);
  const mon = (gen3 ? luaInt : cleanInt)(raw.mon, 0, BATTLE_MON_MAX - 1);
  if (!battle || mon === null) return null;
  const list = gen3 ? luaList(raw.moves) : raw.moves;
  if (!Array.isArray(list) || list.length < 1) return null;
  const moves = [];
  for (const entry of list) {
    if (moves.length >= BATTLE_MOVE_MAX) return null;
    const move = cleanBattleMove(entry, generation);
    if (!move) return null;
    moves.push(move);
  }
  if (moves.length === 0) return null;
  const out = { battle, mon, moves };
  const gen = luaInt(generation, 1, GENERATION_MAX);
  if (gen === 1 || gen === 2) {
    if (raw.level !== undefined && raw.level !== null) {
      const level = luaInt(raw.level, 1, LEVEL_MAX);
      if (level === null) return null;
      out.level = level;
    }
    if (raw.stats !== undefined && raw.stats !== null) {
      const stats = cleanBlock3(raw.stats, gen === 2 ? BATTLE_STATS_GEN2 : BATTLE_STATS_GEN1, 1, STAT_MAX);
      if (!stats) return null;
      out.stats = stats;
    }
    if (raw.maxHp !== undefined && raw.maxHp !== null) {
      const maxHp = luaInt(raw.maxHp, 1, HP_MAX);
      if (maxHp === null) return null;
      out.maxHp = maxHp;
    }
  }
  return out;
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
  cleanCoopOfferMode,
  cleanLabel,
  cleanSide,
  cleanCoopReason,
  cleanDeclineReason,
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
  cleanBattleTeam,
  cleanBattleOutcome,
  cleanBattleReconnect,
  cleanBattleMoveset,
  payloadOk,
  FACINGS,
  KINDS,
  DECLINE_REASONS,
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
  MOVE_NAME_MAX,
  cleanMoveName,
  SIDES,
  COOP_REASONS,
  PARTY_EVENTS,
  LEVEL_MAX,
  // The hello's generation lock and cart (PROTOCOL 30).
  cleanGeneration,
  cleanVersion,
  GENERATION_MAX,
  VERSIONS,
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
  BATTLE_STATS_GEN1,
  BATTLE_STATS_GEN2,
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
  PARTICIPANTS_MAX,
  PAYDAY3_MAX,
  REASON_MAX,
  TEAM_TOKENS,
  // The Gen 3 dialect (PROTOCOL 30): the cleaners the hub and suites reach
  // directly, and the bounds, named as Wire.lua names them.
  BATTLE_EVENT_TYPES3,
  // Gold's held-item dialect (contracts K2 / K3 of
  // docs/plans/gen12-referee-fidelity.md), named as Wire.lua names it.
  BATTLE_EVENT_TYPES2,
  cleanHoldEffect2,
  HOLD_EFFECT2_MAX,
  HOLD_PARAM2_MAX,
  ITEM_NAME2_MAX,
  // The referee-gap dialect (contracts K7-K11 and K13 of
  // docs/plans/gen12-referee-gaps-fix.md), named as Wire.lua names it.
  BASE_STAT_MAX,
  DV_MAX,
  STAT_EXP_MAX,
  PP_UPS_MAX,
  PRIORITY2_MAX,
  STAGE12_MAX,
  PAYDAY12_MAX,
  HAPPINESS2_MAX,
  K7_KEYS1,
  K7_KEYS2,
  METRONOME_POOL_MAX,
  effectsFor,
  luaNumber,
  luaInt,
  luaList,
  cleanItemId3,
  cleanTypeTable3,
  cleanPoolEntry3,
  GEN3_SPECIES_MAX,
  GEN3_MOVE_MAX,
  GEN3_ITEM_MAX,
  GEN3_ABILITY_MAX,
  GEN3_NATURE_COUNT,
  GEN3_IV_MAX,
  GEN3_EV_MAX,
  BATTLE_TYPE_TABLE3_MAX,
  BATTLE_MOVE_POOL3_MAX,
  POWER3_MAX,
  ACCURACY3_MAX,
  EFFECT3_MAX,
  TARGET3_MAX,
  PRIORITY3_MAX,
  FLAGS3_MAX,
  HOLD_EFFECT3_MAX,
  HOLD_PARAM3_MAX,
  WEIGHT3_MAX,
  SLEEP3_MAX,
  U32_MAX,
  GENDERS3,
  TYPE_CELL3_MIN,
  TYPE_MULT3_MAX,
  TERRAIN3_MAX,
  WEATHERS3,
  POOL_ENTRY3_MAX,
  EVENT_STATS3,
  STAGE3_MAX,
  DELTA3_MAX,
  OBEY_TOKENS3,
};
