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
const OUTCOMES = new Set(['win', 'loss', 'draw']);

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
// A claim token: 16 bytes as lowercase hex, exactly. Held to the length the
// hub mints, because a short "token" is a truncated one -- it would fail
// every claim from then on, silently.
const RANK_TOKEN_HEX = 32;

function cleanToken(value) {
  const hex = cleanHex(value, RANK_TOKEN_HEX);
  return hex && hex.length === RANK_TOKEN_HEX ? hex : null;
}

function cleanPoints(value) {
  const n = cleanInt(value, 0, RANK_MAX);
  return n === null ? 0 : n;
}

const NAME_MAX = 10;
const MESSAGE_MAX = 60;
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

function cleanCoopReason(value) {
  return COOP_REASONS[value] ? value : null;
}

module.exports = {
  cleanText,
  cleanId,
  cleanMember,
  cleanBattleKey,
  cleanLabel,
  cleanSide,
  cleanCoopReason,
  cleanSpriteId,
  cleanMapId,
  cleanInt,
  cleanHex,
  cleanCode,
  cleanProfile,
  cleanOutcome,
  cleanPoints,
  cleanToken,
  payloadOk,
  FACINGS,
  KINDS,
  SCOPES,
  PARTY_MAX,
  OUTCOMES,
  RANK_MAX,
  RANK_TOKEN_HEX,
  NAME_MAX,
  MESSAGE_MAX,
  LOCAL_RADIUS,
  MAX_LINE,
  PAYLOAD_MAX_DEPTH,
  PAYLOAD_MAX_NODES,
  COOP_KEY_MAX,
  COOP_LABEL_MAX,
  SIDES,
  COOP_REASONS,
};
