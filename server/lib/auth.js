'use strict';

/*
 * Join codes and the challenge-response that proves one.
 *
 * The hub sends a random nonce; the client answers
 * HMAC-SHA256(joinCode, nonce). The join code itself never crosses the wire,
 * so a packet capture leaks nothing reusable and a captured response cannot
 * be replayed against the next connection's nonce.
 *
 * What that does *not* buy is confidentiality of the session, or any defence
 * against an active man in the middle who proxies the whole conversation.
 * The client's socket is plain TCP (src/link/Net.lua opens socket.tcp() and
 * LOVE ships no TLS), so the gap is real; only an overlay network like
 * WireGuard closes it. The docs say so in those words.
 *
 * Strength, stated plainly: a passcode is 6 characters from a 32-symbol
 * alphabet, so 32^6 = 2^30 -- 30 bits. That is a deliberate, accepted trade
 * against the 80-bit form it replaces, made because a 16-character code was
 * unusable UX. Two consequences follow, and only one of them is comfortable:
 *
 *   Online guessing is hopeless. limits.connectPerMinute defaults to 60, so
 *   2^30 codes take about 34 years to exhaust and about 17 to reach even odds
 *   -- and that is with the attacker holding the connection budget open the
 *   whole time, in full view of the host's logs. Nobody brute-forces a hub
 *   through its front door. (Raise connectPerMinute and this shrinks in
 *   proportion: at its 6000 ceiling, even odds arrive in about two months.)
 *
 *   Offline grinding is not. The game port carries no TLS, so anyone who can
 *   capture a single challenge/response pair off the wire -- a shared LAN, a
 *   hostile router, a VPS neighbour -- holds everything needed to test codes
 *   locally, where no rate limit exists. 2^30 HMAC-SHA256 evaluations is
 *   seconds of work on commodity hardware. A captured pair should be assumed
 *   to yield the passcode.
 *
 * So: the passcode keeps out strangers who merely find the port. It does not
 * survive an eavesdropper. Run the hub behind an overlay network if the
 * traffic can be captured.
 *
 * Every constant and every encoding decision below is a wire contract: a
 * pure-Lua SHA-256 reimplements this exactly on the client side, and the two
 * must agree byte for byte or a correct join code looks like a wrong one.
 *
 *   key      = the normalised join code, as ASCII bytes
 *   message  = the nonce, as its lowercase-hex ASCII *string* -- not the
 *              decoded bytes, so the Lua side never has to hex-decode
 *   response = the digest as 64 lowercase hex characters
 *
 * No dependencies: node:crypto only.
 */

const crypto = require('node:crypto');

// Crockford-style: uppercase, with I L O U removed so nothing is mistyped off
// a screenshot or a phone photo. Every character here also exists on the
// mod's in-game naming grid (src/Ui.lua:54-67), which is the real constraint
// -- a code a player cannot type is a code that does not work. Do not change
// this set without changing that grid.
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

// 6 chars from a 32-symbol alphabet = 32^6 = 2^30 exactly. Short enough to
// read down a phone line and type on the in-game grid; see the header for
// what those 30 bits do and do not buy. No grouping: at this length dashes
// cost more to explain than they save to read.
const CODE_LEN = 6;
const NONCE_BYTES = 16;

const HEX_RESPONSE = /^[0-9a-f]{64}$/;
const HEX_NONCE = /^[0-9a-f]+$/;

// ------------------------------------------------------------------- codes

function randomIndexes(count) {
  const out = [];
  // 256 % 32 === 0, so `byte % ALPHABET.length` happens to be uniform for
  // today's alphabet. Rejection sampling anyway: add or drop a single
  // character and modulo would quietly bias the low indexes, costing entropy
  // with nothing failing loudly enough to notice.
  const limit = 256 - (256 % ALPHABET.length);
  while (out.length < count) {
    for (const byte of crypto.randomBytes(count)) {
      if (byte >= limit) continue;
      out.push(byte % ALPHABET.length);
      if (out.length === count) break;
    }
  }
  return out;
}

/** A fresh passcode in its hand-it-to-a-friend form: 6 chars, e.g. A7K3P9. */
function generateJoinCode() {
  let code = '';
  for (const index of randomIndexes(CODE_LEN)) code += ALPHABET[index];
  return formatCode(code);
}

/**
 * Total and symmetric: uppercase, then drop everything outside the alphabet.
 * Dashes, spaces, lowercase and a stray quote from a chat client all survive
 * the round trip, because the player who reads the code out of a message
 * should get in without being taught a format first.
 *
 * Returns null when nothing usable is left, or when the result is not
 * exactly CODE_LEN -- a short code is a typo, not a shorter key, and a long
 * one (an invite minted under the old 16-character format) is not a passcode
 * this hub can check.
 */
function normalizeCode(value) {
  if (typeof value !== 'string') return null;
  let out = '';
  const upper = value.toUpperCase();
  for (const char of upper) {
    if (ALPHABET.indexOf(char) >= 0) out += char;
  }
  return out.length === CODE_LEN ? out : null;
}

/**
 * The display form of a normalised passcode. At 6 characters the canonical
 * and displayed spellings are the same string, so this is a passthrough --
 * kept rather than deleted because it is the name every caller already uses
 * for "render this code for a human" (lib/cli.js, src/Ui.lua's Lua twin), and
 * because it is the seam a future format change would go back through.
 *
 * It returns the whole code, so it is a formatter and never a mask. Anything
 * that must hide a code uses the whole-code mask in lib/config.js instead.
 */
function formatCode(normalized) {
  if (typeof normalized !== 'string') return '';
  return normalized;
}

// ------------------------------------------------------------- the exchange

/** A per-connection, single-use challenge: 32 lowercase hex characters. */
function newNonce() {
  return crypto.randomBytes(NONCE_BYTES).toString('hex');
}

/**
 * The response a client owes for `nonce`, given `code`. Accepts a raw or an
 * already-normalised code and normalises internally, so callers never have to
 * remember which form they are holding.
 *
 * Throws on an unnormalisable code: signing with a key nobody can type is a
 * programming error at the call site, not untrusted input to be swallowed.
 * Untrusted input arrives at verify(), which never throws.
 */
function sign(code, nonce) {
  const key = normalizeCode(code);
  if (key === null) {
    throw new TypeError(
      `join code is not usable: expected ${CODE_LEN} characters from ` +
      `${ALPHABET} after normalisation`);
  }
  if (typeof nonce !== 'string' || !nonce) {
    throw new TypeError('nonce must be a non-empty hex string');
  }
  return crypto
    .createHmac('sha256', Buffer.from(key, 'ascii'))
    .update(nonce, 'ascii')
    .digest('hex');
}

// --------------------------------------------------------------- credentials

/**
 * A credential admits only while it is un-revoked, unexpired, and under its
 * use budget. An expiry that will not parse counts as expired, and a use count
 * that will not read as a number counts as exhausted: a lifetime or a budget
 * the hub cannot read is not one to admit on. This is the last gate before
 * admission, so it has no fail-open branch -- every unreadable field resolves
 * to "not active".
 */
function isActive(credential, now = Date.now()) {
  if (!credential || typeof credential !== 'object') return false;
  if (credential.revoked) return false;
  if (typeof credential.secret !== 'string' || !credential.secret) return false;

  if (credential.expiresAt !== null && credential.expiresAt !== undefined) {
    const at = Date.parse(credential.expiresAt);
    if (!Number.isFinite(at) || at <= now) return false;
  }

  if (credential.maxUses !== null && credential.maxUses !== undefined) {
    const max = Number(credential.maxUses);
    if (!Number.isFinite(max) || max <= 0) return false;
    // Absent is zero uses -- that is every credential nobody has spent yet.
    // Anything else is read as a number and has to survive being one: `|| 0`
    // on its own would quietly turn NaN back into a fresh, unused credential,
    // which is the fail-open branch this gate must not have.
    const uses = credential.uses === undefined || credential.uses === null
      ? 0 : Number(credential.uses);
    if (!Number.isFinite(uses) || uses >= max) return false;
  }

  return true;
}

function activeCredentials(credentials, now = Date.now()) {
  if (!Array.isArray(credentials)) return [];
  return credentials.filter((credential) => isActive(credential, now));
}

/**
 * Check a client's `response` to `nonce` against every active credential.
 *
 * Failure reasons are deliberately coarse -- 'malformed', 'no_credentials',
 * 'rejected' -- and never name a credential. A wrong code, an expired invite
 * and a revoked one must look identical from outside, or the refusal itself
 * becomes an oracle for enumerating which invites a hub has issued.
 */
function verify(nonce, response, credentials, now = Date.now()) {
  if (typeof nonce !== 'string' || !nonce || !HEX_NONCE.test(nonce)) {
    return { ok: false, credentialId: null, reason: 'malformed' };
  }
  // Shape-check before any crypto: a 64-lowercase-hex string is the only
  // thing this can be, and rejecting the rest here keeps a peer from
  // spending the hub's HMACs on garbage.
  if (typeof response !== 'string' || !HEX_RESPONSE.test(response)) {
    return { ok: false, credentialId: null, reason: 'malformed' };
  }

  const active = activeCredentials(credentials, now);
  if (active.length === 0) {
    return { ok: false, credentialId: null, reason: 'no_credentials' };
  }

  const given = Buffer.from(response, 'ascii');
  let hit = null;

  for (const credential of active) {
    const key = normalizeCode(credential.secret);
    if (key === null) continue; // a stored secret that will not normalise

    const expected = Buffer.from(sign(key, nonce), 'ascii');
    // Length is equal by construction (both are 64 hex chars), but
    // timingSafeEqual throws rather than returning false on a mismatch, so
    // the guard stays.
    const same = expected.length === given.length &&
      crypto.timingSafeEqual(expected, given);

    // No early exit. Breaking here would make the hub answer faster for the
    // first credential in the list than for the last, which leaks the
    // position of the code that matched -- and, across many attempts, how
    // many credentials a hub is carrying.
    if (same && hit === null) hit = credential;
  }

  if (hit === null) return { ok: false, credentialId: null, reason: 'rejected' };
  return { ok: true, credentialId: hit.id || null, reason: null };
}

/**
 * A credential in the shape config.json stores (plan §3.5). The secret is
 * generated when none is given, so the common path -- `init`, `invite` --
 * never invents one by hand.
 */
function newCredential(options = {}) {
  const { label, secret, expiresAt = null, maxUses = null, admin = false } = options;

  let stored;
  if (secret === undefined || secret === null || secret === '') {
    stored = generateJoinCode();
  } else {
    const normalized = normalizeCode(secret);
    if (normalized === null) {
      throw new TypeError(
        `join code is not usable: expected ${CODE_LEN} characters from ` +
        `${ALPHABET} after normalisation`);
    }
    stored = formatCode(normalized);
  }

  let expires = null;
  if (expiresAt instanceof Date) {
    expires = expiresAt.toISOString();
  } else if (typeof expiresAt === 'string' && expiresAt) {
    const at = Date.parse(expiresAt);
    if (!Number.isFinite(at)) {
      throw new TypeError(`expiresAt is not a date: ${expiresAt}`);
    }
    expires = new Date(at).toISOString();
  } else if (typeof expiresAt === 'number' && Number.isFinite(expiresAt)) {
    expires = new Date(expiresAt).toISOString();
  }

  let uses = null;
  if (maxUses !== null && maxUses !== undefined) {
    const max = Math.floor(Number(maxUses));
    if (!Number.isFinite(max) || max < 1) {
      throw new TypeError(`maxUses must be a positive integer: ${maxUses}`);
    }
    uses = max;
  }

  const credential = {
    // Short and hex: it goes in log lines and `revoke <id>`, so it has to be
    // repeatable off a terminal without being guessable enough to matter --
    // and it is an identifier, not a secret.
    id: crypto.randomBytes(4).toString('hex'),
    label: typeof label === 'string' && label ? label : 'Join code',
    secret: stored,
    createdAt: new Date().toISOString(),
    expiresAt: expires,
    maxUses: uses,
    uses: 0,
    revoked: false,
  };

  // An admin credential is an ordinary join code that additionally marks the
  // connection it admits, so in-game operator features have a flag to check
  // when they exist -- and so operator views can already say who holds one.
  // Nothing about admission changes -- an admin code joins the game exactly
  // like a player's.
  //
  // The flag is written only when it is true, so a player's credential is the
  // byte-identical object it was before this field existed and no config
  // written by an older hub needs migrating: absent reads as false everywhere
  // (see isAdminCredential, and validateCredentials in lib/config.js).
  //
  // It is not itself a secret -- it says what a code unlocks, not what the
  // code is -- so redaction leaves it alone. The secret is still the code.
  if (admin) credential.admin = true;

  return credential;
}

/**
 * The one reading of the flag every consumer should use, so "is this an admin
 * credential?" cannot drift into six different truthiness tests.
 *
 * Strictly `true`, and that strictness is a backstop rather than the parser: a
 * credential the hub loaded has been through `validateCredentials`
 * (lib/config.js), which is where the generous spellings a human writes --
 * `"yes"`, `"true"`, `1` -- are canonicalised to `true` before this gate ever
 * sees them. What reaches here still spelled some other way is a credential
 * that skipped that step, and a value nobody canonicalised is not one to read
 * in favour of privilege. So this fails closed on exactly the inputs whose
 * meaning is a guess.
 */
function isAdminCredential(credential) {
  return Boolean(credential) && credential.admin === true;
}

module.exports = {
  ALPHABET,
  CODE_LEN,
  NONCE_BYTES,
  generateJoinCode,
  normalizeCode,
  formatCode,
  newNonce,
  sign,
  verify,
  isActive,
  activeCredentials,
  newCredential,
  isAdminCredential,
};
