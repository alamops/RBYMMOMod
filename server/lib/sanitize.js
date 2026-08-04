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

module.exports = {
  cleanText,
  cleanId,
  cleanMember,
  cleanSpriteId,
  cleanMapId,
  cleanInt,
  cleanHex,
  cleanCode,
  cleanProfile,
  payloadOk,
  FACINGS,
  KINDS,
  SCOPES,
  PARTY_MAX,
  NAME_MAX,
  MESSAGE_MAX,
  LOCAL_RADIUS,
  MAX_LINE,
  PAYLOAD_MAX_DEPTH,
  PAYLOAD_MAX_NODES,
};
