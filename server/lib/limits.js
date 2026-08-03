'use strict';

/*
 * Connection-level limits for the hub.
 *
 * This is the difference between a relay for friends and something that can
 * be left listening on a public address. `hub.js` today has exactly one
 * limit -- a global player cap -- so a single address can take every seat,
 * an unlimited number of connections can be attempted per second, and one
 * `socket.setTimeout(45000)` doubles as both the handshake budget and the
 * idle timeout. All of that is closed here.
 *
 * A second question sits beside the connection ones and is answered by the
 * same object: how fast may passcodes be *guessed*. `authAllowed` /
 * `noteAuthFailure` / `noteAuthSuccess` are that half -- see
 * "authentication failures" below for why a per-IP limit alone cannot
 * answer it.
 *
 * **No sockets appear anywhere below, and no timers.** Everything is pure
 * bookkeeping over an injected clock, driven by the caller: `admit` before a
 * client record exists, `register`/`markGreeted`/`noteActivity`/`release`
 * across the connection's life, `authAllowed` before a challenge is minted
 * and `noteAuthFailure`/`noteAuthSuccess` on its answer, and `sweep` on
 * whatever tick the server already runs. That is the same split
 * `src/Hub.lua` uses for the relay
 * itself, and for the same reason: it makes every rule testable under a
 * plain unit test with no port opened and no wall clock waited on.
 *
 * The caller owns the sockets. Nothing here destroys anything; `sweep`
 * reports who should go and `writeAllowed` reports who has stopped reading,
 * and closing those connections calls back into `release`.
 *
 * The one require is `node:net`, and only for its `isIPv6` validator -- no
 * socket is created here.
 */

const net = require('node:net');

// ------------------------------------------------------------------- bounds
//
// Every numeric option is clamped, in the spirit of `clampPlayers` in
// hub.js: an out-of-range value is pulled to the nearest sane end, never
// obeyed and never rejected. The caller (the CLI, the config loader) has
// already validated its input -- this is the second wall, for the case where
// a config file was hand-edited or an env var was typed wrong. Refusing to
// start over a bad number would be worse than quietly running safe.
//
// The bounds themselves are picked so that both ends are survivable:
//
//   perIpConnections    1 .. 256      1 is "one connection per address";
//                                     256 is past any honest NAT.
//   connectBurst        1 .. 1000     a bucket that cannot hold a token is
//                                     a bucket that admits nobody.
//   connectPerMinute    1 .. 60000    60000/min is 1000/s, i.e. off.
//   maxPending          1 .. 1024     must be >= 1 or no one can ever
//                                     complete a handshake.
//   handshakeTimeoutMs  1000 .. 300000   under a second would reap players
//                                     on a slow link; 5 min is "disabled".
//   idleTimeoutMs       5000 .. 3600000  the client has no auto-reconnect
//                                     (src/Transport.lua:163), so the floor
//                                     is deliberately well above the mod's
//                                     own heartbeat interval.
//   partialLineTimeoutMs 1000 .. 300000  same reasoning as the handshake.
//   maxWriteBufferBytes 4096 .. 67108864  the floor is above one max-size
//                                     line (hub.js MAX_LINE is 64 KiB) so
//                                     the guard cannot fire on a legitimate
//                                     single message.
//
// The `auth*` knobs are the same idea applied to *wrong passcodes* rather
// than connections; see "authentication failures" below for what each one
// governs and why its default is where it is.
//
//   authFailureGrace       0 .. 100        0 backs off from the first wrong
//                                     code; 100 is "per-IP backoff off".
//   authFailureWindowMs 1000 .. 86400000   how long one address's failures
//                                     are remembered. A day is the ceiling
//                                     because a grudge longer than that is
//                                     a ban, and bans have their own verb.
//   authBackoffBaseMs    100 .. 3600000    the first delay past the grace.
//   authBackoffMaxMs    1000 .. 86400000   the ceiling that delay escalates
//                                     to. Below the base is harmless -- the
//                                     `Math.min` simply makes the ceiling
//                                     win, which is what a host who set it
//                                     that way asked for.
//   authGlobalFailures     1 .. 1000000    hub-wide failures per window
//                                     before the ceiling trips. The top of
//                                     the range is "effectively off".
//   authGlobalWindowMs  1000 .. 3600000    the window they are counted over.
//   authLockoutMs       1000 .. 3600000    how long the ceiling stays
//                                     tripped. An hour is the longest a
//                                     refusal should outlive the burst that
//                                     caused it without a human looking.
const BOUNDS = Object.freeze({
  perIpConnections: [1, 256],
  connectBurst: [1, 1000],
  connectPerMinute: [1, 60000],
  maxPending: [1, 1024],
  handshakeTimeoutMs: [1000, 300000],
  idleTimeoutMs: [5000, 3600000],
  partialLineTimeoutMs: [1000, 300000],
  maxWriteBufferBytes: [4096, 67108864],
  authFailureGrace: [0, 100],
  authFailureWindowMs: [1000, 86400000],
  authBackoffBaseMs: [100, 3600000],
  authBackoffMaxMs: [1000, 86400000],
  authGlobalFailures: [1, 1000000],
  authGlobalWindowMs: [1000, 3600000],
  authLockoutMs: [1000, 3600000],
});

const DEFAULTS = Object.freeze({
  perIpConnections: 4,
  connectBurst: 10,
  connectPerMinute: 60,
  maxPending: 8,
  handshakeTimeoutMs: 10000,
  idleTimeoutMs: 45000,
  partialLineTimeoutMs: 10000,
  maxWriteBufferBytes: 262144,

  // Three free failures inside ten minutes. A friend reading a code off a
  // phone photo gets a typo, a stale invite and one more before anything
  // slows down; a fourth wrong code inside ten minutes is not how humans
  // fail. The window is long enough that pausing half a minute does not
  // launder the count, and short enough that someone who gave up, made tea
  // and came back is clean.
  authFailureGrace: 3,
  authFailureWindowMs: 600000,

  // 2s, 4s, 8s ... capped at 5 minutes, which arrives on the twelfth wrong
  // code. From there one address gets at most twelve guesses an hour, so
  // 2^30 codes is about 10^4 years from a single peer, half that for even
  // odds -- an order of magnitude less than this comment first claimed, and
  // still far past the point where a lone attacker is the threat. The first
  // step is deliberately small: the honest player who fat-fingered a fourth
  // time waits two seconds and never notices.
  authBackoffBaseMs: 2000,
  authBackoffMaxMs: 300000,

  // The control that survives an attacker renting addresses. A hundred wrong
  // passcodes hub-wide in one minute is not a thing a friend group produces
  // -- a four-seat hub sees a handful across an entire evening -- so the
  // threshold sits far above honest traffic and far below the volume a
  // distributed grind needs. With a one-minute cooling period the whole
  // internet together gets ~100 guesses a minute, which puts even odds on a
  // 30-bit code at roughly a decade, with the host's log screaming the whole
  // time. That number does not improve when the attacker rents more hosts,
  // which is the entire point of the ceiling being global.
  authGlobalFailures: 100,
  authGlobalWindowMs: 60000,
  authLockoutMs: 60000,
});

function clamp(name, value) {
  const [min, max] = BOUNDS[name];
  const n = Math.floor(Number(value));
  if (!Number.isFinite(n)) return DEFAULTS[name];
  return Math.min(max, Math.max(min, n));
}

// How many rate buckets may exist at once, and how often the sweep for dead
// ones is allowed to run. Both are internal: a host has no reason to tune
// the shape of a memory guard, and exposing them would only widen the
// surface a bad config can damage.
const MAX_BUCKETS = 4096;
const MAX_AUTH_RECORDS = 4096;
const PRUNE_INTERVAL_MS = 30000;

// ------------------------------------------------------------- address keys
//
// Node hands back `::ffff:203.0.113.7` for an IPv4 client on a dual-stack
// listener, and the bare dotted quad for the same client on an IPv4-only
// one. Keying, banning or counting without folding those together means the
// per-IP cap and the ban list both silently miss half the time -- the worst
// kind of failure, because everything still looks like it is working.
//
// The mapped form also has a hex spelling (`::ffff:cb00:7107`) that some
// stacks produce, and addresses can arrive with a `[...]` wrapper or a
// `%iface` zone index. All of it is folded to one canonical string. Zone
// indices are dropped rather than kept: a human writing a ban list writes
// `fe80::1`, not `fe80::1%en0`, and a ban that misses because of an
// interface name is a ban that did not happen.
//
// IPv6 makes the same point far more loudly, because one address has many
// legal spellings: `2001:db8::1`, `2001:0db8:0000:0000:0000:0000:0000:0001`
// and `2001:DB8:0:0:0:0:0:1` are one host. A ban list is typed by a human
// reading a log, and a log that expanded the address produces a key
// `socket.remoteAddress` will never emit -- so the ban reports success and
// then never fires, which is worse than having no ban verb at all. Every
// IPv6 address is therefore parsed and re-emitted in canonical RFC 5952
// form: leading zeros dropped, lowercase hex, and the *longest* run of zero
// groups compressed to `::` (leftmost wins a tie; a single zero group is
// never compressed).
//
// **Nothing here throws.** This runs on the accept path against whatever
// bytes an attacker's kernel felt like reporting, and a crash in the
// admission check is a worse outcome than a key that misses, so anything
// that does not parse is handed back exactly as it arrived.
const V4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
const HEX_GROUP = /^[0-9a-f]{1,4}$/;

/*
 * `text` -> eight 16-bit numbers, or null if it is not an IPv6 address.
 *
 * `net.isIPv6` is the gate rather than a regex of our own: it is the same
 * C-level `inet_pton` the rest of Node validates with, it is linear in the
 * input, and it cannot be walked into catastrophic backtracking by a hostile
 * 200 KB "address". Everything after it is plain splitting on text already
 * known to be well-formed.
 */
function parseIpv6(text) {
  if (!net.isIPv6(text)) return null;

  let body = text;

  // A dotted-quad tail (`::ffff:1.2.3.4`) is two groups written in decimal.
  // Rewrite it to hex first so the rest of the parse sees eight uniform
  // groups and the mapped-address check below is spelling-independent.
  if (body.indexOf('.') >= 0) {
    const cut = body.lastIndexOf(':');
    const quad = V4.exec(body.slice(cut + 1));
    if (!quad) return null;
    const o = [quad[1], quad[2], quad[3], quad[4]].map(Number);
    if (!o.every((n) => n <= 255)) return null;
    const hi = ((o[0] << 8) | o[1]).toString(16);
    const lo = ((o[2] << 8) | o[3]).toString(16);
    body = `${body.slice(0, cut + 1)}${hi}:${lo}`;
  }

  const halves = body.split('::');
  if (halves.length > 2) return null;

  const head = halves[0] ? halves[0].split(':') : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];

  let groups;
  if (halves.length === 1) {
    if (head.length !== 8) return null;
    groups = head;
  } else {
    const fill = 8 - head.length - tail.length;
    if (fill < 1) return null;
    groups = head.concat(new Array(fill).fill('0'), tail);
  }

  const out = new Array(8);
  for (let i = 0; i < 8; i += 1) {
    if (!HEX_GROUP.test(groups[i])) return null;
    out[i] = parseInt(groups[i], 16);
  }
  return out;
}

/* Eight groups -> the one RFC 5952 spelling of them. */
function formatIpv6(groups) {
  // Longest run of zero groups, leftmost on a tie -- `>` rather than `>=` is
  // what makes the tie go left, and a run of one is left uncompressed
  // because `2001:db8:0:1:...` is shorter and clearer than `2001:db8::1:...`
  // and, more to the point, is what everything else emits.
  let bestAt = -1;
  let bestLen = 0;
  let runAt = -1;
  let runLen = 0;
  for (let i = 0; i < 8; i += 1) {
    if (groups[i] === 0) {
      if (runAt < 0) runAt = i;
      runLen += 1;
      if (runLen > bestLen) {
        bestLen = runLen;
        bestAt = runAt;
      }
    } else {
      runAt = -1;
      runLen = 0;
    }
  }
  if (bestLen < 2) return groups.map((g) => g.toString(16)).join(':');

  const head = groups.slice(0, bestAt).map((g) => g.toString(16)).join(':');
  const tail = groups.slice(bestAt + bestLen).map((g) => g.toString(16)).join(':');
  return `${head}::${tail}`;
}

/*
 * The IPv4 hiding inside an IPv6 address, or null.
 *
 * The mapped form (`::ffff:a.b.c.d`) is decided numerically, so every
 * spelling of it -- dotted, hex, or fully expanded -- folds to the same
 * dotted quad. The deprecated compatible form (`::a.b.c.d`) is decided on
 * the presence of a literal dot instead, and deliberately so: numerically it
 * is indistinguishable from `::1`, and folding the loopback address to
 * `0.0.0.1` would be a considerably worse bug than the one being fixed.
 */
function embeddedIpv4(groups, text) {
  for (let i = 0; i < 5; i += 1) if (groups[i] !== 0) return null;
  const mapped = groups[5] === 0xffff;
  const compatible = groups[5] === 0 && text.indexOf('.') >= 0;
  if (!mapped && !compatible) return null;
  const hi = groups[6];
  const lo = groups[7];
  return `${hi >> 8}.${hi & 255}.${lo >> 8}.${lo & 255}`;
}

/*
 * The exact-address key. This is the identity a host means when they type an
 * address: bans, the allowlist, and anything a human compares by eye.
 */
function normalizeIp(value) {
  if (typeof value !== 'string') return '';
  let ip = value.trim();
  if (!ip) return '';

  if (ip.startsWith('[')) {
    const close = ip.indexOf(']');
    if (close > 0) ip = ip.slice(1, close);
  }
  const zone = ip.indexOf('%');
  if (zone >= 0) ip = ip.slice(0, zone);

  // IPv6 is case-insensitive; IPv4 has no letters. One lowercase pass makes
  // both halves comparable without needing to know which one this is.
  ip = ip.toLowerCase();

  // No colon means it is not IPv6, so there is nothing left to canonicalise:
  // a dotted quad is already its own canonical form, and anything else is
  // input we do not recognise and must not mangle.
  if (ip.indexOf(':') < 0) return ip;

  const groups = parseIpv6(ip);
  if (!groups) return ip;

  return embeddedIpv4(groups, ip) || formatIpv6(groups);
}

// --------------------------------------------------------------- /64 keying
//
// Bans and the allowlist are exact addresses. Connection *counting* is not,
// and the split is deliberate:
//
//   * A ban is a host's judgement about one peer. Widening it to a /64 would
//     silently ban a friend's entire ISP-assigned block on the strength of
//     one address, and the host would have no way to tell from the config
//     file that they had. Same for the allowlist in the other direction: a
//     /64 allow entry would admit every address in a block the host only
//     meant to name one member of. Exact, both ways.
//
//   * `perIpConnections` exists to bound *one household*, and a household is
//     a /64 -- that is the smallest block any residential IPv6 assignment
//     hands out. Keyed by the full /128 the cap is not a cap at all: a
//     client with a normal /64 has 2^64 source addresses to rotate through
//     and can open a connection from each. The rate bucket is keyed the same
//     way and for the same reason, plus one of its own -- per-/128 buckets
//     would let a single peer churn `MAX_BUCKETS` worth of the hub's memory
//     without ever tripping a limit.
//
// The `/64` suffix is part of the key on purpose: it keeps a prefix key from
// ever colliding with a real address (`2001:db8::/64` is not `2001:db8::`),
// and it makes `stats().perIp` say plainly what it counted. IPv4 keeps
// counting per exact address -- an IPv4 host is one address, not a block.
const PREFIX_BITS = 64;

/* Assumes an already-normalized address; `ipCountKey` is the public door. */
function countKeyOf(addr) {
  if (!addr || addr.indexOf(':') < 0) return addr;
  const groups = parseIpv6(addr);
  if (!groups) return addr;
  const prefix = groups.slice(0, PREFIX_BITS / 16).concat([0, 0, 0, 0]);
  return `${formatIpv6(prefix)}/${PREFIX_BITS}`;
}

/*
 * The key a connection is *counted* under: the exact address for IPv4, the
 * /64 prefix for IPv6. Exported so callers pick a key deliberately rather
 * than by accident -- ban/allow verbs want `normalizeIp`, anything that
 * counts or rate-limits wants this.
 */
function ipCountKey(value) {
  return countKeyOf(normalizeIp(value));
}

function toIpSet(list) {
  const set = new Set();
  if (!Array.isArray(list)) return set;
  for (const entry of list) {
    const ip = normalizeIp(entry);
    if (ip) set.add(ip);
  }
  return set;
}

// ------------------------------------------------------------------ verdicts
//
// A rejected connection must cost nothing but the bucket update -- otherwise
// a flooder gets to allocate on the hub's heap once per SYN, which is the
// thing this module exists to prevent. So every verdict is a frozen
// singleton handed back by reference, not a fresh object. Callers read
// `.ok`/`.reason` and must not write to them.
const OK = Object.freeze({ ok: true });
const REJECT = Object.freeze({
  banned: Object.freeze({ ok: false, reason: 'banned' }),
  not_allowed: Object.freeze({ ok: false, reason: 'not_allowed' }),
  per_ip: Object.freeze({ ok: false, reason: 'per_ip' }),
  rate: Object.freeze({ ok: false, reason: 'rate' }),
  pending: Object.freeze({ ok: false, reason: 'pending' }),
  // This address is serving out its own backoff after wrong passcodes.
  auth_backoff: Object.freeze({ ok: false, reason: 'auth_backoff' }),
  // Nobody is being authenticated right now: the hub-wide ceiling is tripped.
  auth_lockdown: Object.freeze({ ok: false, reason: 'auth_lockdown' }),
});

// -------------------------------------------------------------------- Limits

class Limits {
  constructor(options = {}) {
    const opts = options || {};
    this.perIpConnections = clamp('perIpConnections', opts.perIpConnections);
    this.connectBurst = clamp('connectBurst', opts.connectBurst);
    this.connectPerMinute = clamp('connectPerMinute', opts.connectPerMinute);
    this.maxPending = clamp('maxPending', opts.maxPending);
    this.handshakeTimeoutMs = clamp('handshakeTimeoutMs', opts.handshakeTimeoutMs);
    this.idleTimeoutMs = clamp('idleTimeoutMs', opts.idleTimeoutMs);
    this.partialLineTimeoutMs =
      clamp('partialLineTimeoutMs', opts.partialLineTimeoutMs);
    this.maxWriteBufferBytes =
      clamp('maxWriteBufferBytes', opts.maxWriteBufferBytes);

    this.authFailureGrace = clamp('authFailureGrace', opts.authFailureGrace);
    this.authFailureWindowMs =
      clamp('authFailureWindowMs', opts.authFailureWindowMs);
    this.authBackoffBaseMs = clamp('authBackoffBaseMs', opts.authBackoffBaseMs);
    this.authBackoffMaxMs = clamp('authBackoffMaxMs', opts.authBackoffMaxMs);
    this.authGlobalFailures =
      clamp('authGlobalFailures', opts.authGlobalFailures);
    this.authGlobalWindowMs =
      clamp('authGlobalWindowMs', opts.authGlobalWindowMs);
    this.authLockoutMs = clamp('authLockoutMs', opts.authLockoutMs);

    // The clock is injected so a test can advance time by an hour without
    // waiting one. Anything that is not callable falls back to the real one
    // rather than throwing -- a hub that will not start because of a bad
    // clock argument is a worse outcome than one that ignores it.
    this.now = typeof opts.now === 'function' ? opts.now : Date.now;

    this._tokensPerMs = this.connectPerMinute / 60000;

    /** key -> { ip, countKey, at, greeted, lastActivity, partialSince } */
    this._conns = new Map();
    /** count key (exact IPv4 / IPv6 /64) -> live connection count */
    this._perIp = new Map();
    /** count key -> { tokens, last } */
    this._buckets = new Map();

    this._pending = 0;
    this._prunedAt = -Infinity;

    this._bans = new Set();
    this._allow = new Set();

    /** count key -> { failures, last, until } -- wrong-passcode history */
    this._authFails = new Map();
    /** the hub-wide failure counter; see _authRoll for the window shape */
    this._authWindow = { start: -Infinity, count: 0, prev: 0 };
    /** 0, or the instant the tripped ceiling releases */
    this._authTrippedUntil = 0;
  }

  // ------------------------------------------------------------ admission

  /*
   * Called before a single byte of client state is allocated.
   *
   * The order is cheapest-and-most-decisive first: a banned address is a
   * settled question and costs a set lookup; an allowlist miss likewise. The
   * rate bucket comes next because it is the only check that must run even
   * on a doomed connection -- a rejected attempt still spends a token, or a
   * flooder who is over the per-IP cap gets unlimited free retries and the
   * cap becomes a busy-loop rather than a limit. Bans deliberately sit
   * *before* the bucket so a banned address never causes a bucket to be
   * created: that is the one attacker who must not be able to allocate.
   *
   * Bans always beat the allowlist. An empty allowlist means "everyone",
   * which is what a hub with no allowlist configured wants.
   *
   * Two keys are in play and the order above is why: the policy checks read
   * the exact address, because that is what a host banned or allowed, and
   * everything below them reads the /64 count key, because that is the unit
   * a cap has to bound to mean anything. See "/64 keying" above.
   */
  admit(ip) {
    const addr = normalizeIp(ip);
    if (this._bans.has(addr)) return REJECT.banned;
    if (this._allow.size > 0 && !this._allow.has(addr)) return REJECT.not_allowed;

    const key = countKeyOf(addr);
    const now = this.now();
    this._prune(now);
    if (!this._spendToken(key, now)) return REJECT.rate;

    if ((this._perIp.get(key) || 0) >= this.perIpConnections) {
      return REJECT.per_ip;
    }
    if (this._pending >= this.maxPending) return REJECT.pending;
    return OK;
  }

  // ------------------------------------------------------ connection life

  /*
   * Record an admitted connection. The key is opaque and chosen by the
   * caller (a socket id, the client id, the socket object itself) so this
   * module never needs to know what a connection actually is.
   *
   * Registering a key twice is a caller bug, not a security event, so it is
   * absorbed: the second call is a no-op rather than a second seat charged
   * against the address.
   */
  register(key, ip) {
    if (this._conns.has(key)) return;
    const addr = normalizeIp(ip);
    const countKey = countKeyOf(addr);
    const now = this.now();
    // Both keys are stored: `countKey` is what the cap is charged against,
    // and `ip` is the exact address, kept so a caller that wants to report
    // or ban this peer has the identity it actually connected from rather
    // than the block it was counted under.
    this._conns.set(key, {
      ip: addr,
      countKey,
      at: now,
      greeted: false,
      lastActivity: now,
      partialSince: null,
    });
    this._perIp.set(countKey, (this._perIp.get(countKey) || 0) + 1);
    this._pending += 1;
  }

  /*
   * The connection is gone. Deleting from `_conns` first is what makes this
   * idempotent: a socket that emits both `error` and `close` -- which is the
   * normal case, not the exotic one -- calls this twice, and a per-IP
   * counter that went down twice would eventually go negative and hand that
   * address an unlimited cap.
   */
  release(key) {
    const rec = this._conns.get(key);
    if (!rec) return false;
    this._conns.delete(key);
    if (!rec.greeted) this._pending -= 1;

    const left = (this._perIp.get(rec.countKey) || 1) - 1;
    if (left > 0) this._perIp.set(rec.countKey, left);
    else this._perIp.delete(rec.countKey);
    return true;
  }

  /*
   * Handshake complete. This is the moment the connection stops being a
   * pending slot and starts being judged on idleness instead -- the two
   * clocks that `socket.setTimeout(45000)` used to conflate, which is how a
   * silent socket held a slot for 45 seconds.
   */
  markGreeted(key) {
    const rec = this._conns.get(key);
    if (!rec || rec.greeted) return false;
    rec.greeted = true;
    rec.lastActivity = this.now();
    this._pending -= 1;
    return true;
  }

  /*
   * Called on every inbound chunk.
   *
   * Two separate facts are tracked, because they answer different questions.
   * `lastActivity` answers "is this peer alive". `partialSince` answers "has
   * this peer produced a complete line since it started buffering" -- which
   * is what catches the client dribbling one byte a minute, forever, under
   * the 64 KiB buffer cap and under any idle timeout.
   *
   * `completedLine` wins over `bytes` when both are set: a chunk that closed
   * a line has proved the peer can finish a sentence, and the leftover tail
   * gets its own clock from the next chunk that arrives without one.
   */
  noteActivity(key, info) {
    const rec = this._conns.get(key);
    if (!rec) return false;
    const now = this.now();
    rec.lastActivity = now;

    const opts = info || {};
    if (opts.completedLine) {
      rec.partialSince = null;
    } else if (Number(opts.bytes) > 0 && rec.partialSince === null) {
      rec.partialSince = now;
    }
    return true;
  }

  // ------------------------------------------------ authentication failures
  //
  // A wrong passcode is not an ordinary connection and must not be limited
  // like one. The join code is 6 characters from a 32-symbol alphabet -- 2^30
  // exactly (lib/auth.js) -- and the connect bucket is keyed per address, so
  // per-IP limiting alone does not bound the guess rate at all: it tells an
  // attacker precisely how many addresses to rent. At the default 60/min one
  // address needs decades, a thousand addresses need a fortnight, and the
  // difference is a hosting invoice.
  //
  // So failures are throttled twice, and the second one is the load-bearing
  // half:
  //
  //   Per address -- an escalating backoff past a small grace. This is the
  //     part shaped for humans: a friend who fat-fingers the code twice
  //     notices nothing, and someone grinding stops making progress.
  //
  //   Hub-wide -- a ceiling on total failures per window, and a cooling
  //     period once it trips. This is the part that does not care how many
  //     addresses the attacker has, which is the only reason the 30-bit code
  //     is defensible online. Nobody legitimate produces a hundred wrong
  //     passcodes across a whole hub in a minute.
  //
  // **What a tripped ceiling does, exactly:** `authAllowed` starts refusing.
  // That is the entire blast radius. It does not touch `admit`, so
  // connections are still accepted; it does not appear in `sweep`, so nobody
  // is disconnected for it; it does not read or alter any connection record,
  // so **every already-authenticated player keeps playing, un-disconnected
  // and unthrottled, for the whole lockout**. A hub under attack goes
  // temporarily closed to newcomers, not down. The accepted cost is that a
  // player holding the *correct* code, arriving mid-attack, is turned away
  // until the cooling period ends -- a minute by default, and the honest
  // alternative (keep answering challenges) is the attack succeeding.
  //
  // Keyed by the /64 count key rather than the exact address, for the reason
  // in "/64 keying" above: a per-/128 backoff is not a backoff, because the
  // attacker has 2^64 addresses to spend one failure each from.

  /*
   * May this address attempt authentication right now?
   *
   * Asked *before* a nonce is issued and again is not necessary -- one call
   * per attempt, on the path that would otherwise mint a challenge. The
   * global ceiling is checked first: it is one comparison, it is the more
   * decisive fact, and it makes the refusal uniform for everybody rather
   * than dependent on who is asking.
   *
   * Verdicts are the same frozen singletons `admit` hands back, so a refusal
   * allocates nothing even when the hub is being hammered. The "how long"
   * that a log line or a client message wants is a separate question with a
   * separate, allocation-free answer: `authRetryAfterMs`.
   */
  authAllowed(ip) {
    const now = this.now();
    if (this._authTick(now)) return REJECT.auth_lockdown;

    const rec = this._authFails.get(ipCountKey(ip));
    if (rec && now < rec.until) return REJECT.auth_backoff;
    return OK;
  }

  /*
   * Record one rejected passcode. Returns true only on the edge where this
   * failure trips the global ceiling, so a caller can log the event once
   * instead of once per attempt.
   *
   * **Only genuine credential rejections belong here.** A refusal handed
   * down by `authAllowed` is not a failure and must not be recorded: an
   * attacker gains nothing by retrying into a closed door, while an honest
   * player who retries during their own backoff would otherwise extend it
   * every time and be locked out for the evening -- which is precisely the
   * collateral this design exists to avoid.
   *
   * A refused attempt also does **not** spend a connect token. The
   * connection it arrived on already spent one in `admit`, and charging a
   * second would drain a shared household's whole connection budget over one
   * roommate's typo while making `connectPerMinute` mean something other
   * than what it says. Auth failures are governed by these knobs; connection
   * volume is governed by the bucket. Two limiters, two budgets, no hidden
   * coupling where tuning one quietly retunes the other.
   */
  noteAuthFailure(ip) {
    const now = this.now();
    this._prune(now);
    const tripped = this._authTick(now);

    const key = ipCountKey(ip);
    let rec = this._authFails.get(key);
    // A record whose window has lapsed *and* whose backoff has run out is
    // indistinguishable from an address that has never failed -- that is the
    // recovery path, and it is why an honest player is never permanently
    // locked out. Both halves are checked because a hand-edited config can
    // set a backoff longer than the window it is remembered over.
    if (!rec ||
        (now - rec.last >= this.authFailureWindowMs && now >= rec.until)) {
      rec = { failures: 0, last: now, until: 0 };
      this._authFails.set(key, rec);
    }
    rec.failures += 1;
    rec.last = now;

    const excess = rec.failures - this.authFailureGrace;
    if (excess > 0) {
      // Doubling, capped. `Math.pow` overflowing to Infinity on a long grind
      // is harmless: the ceiling wins the `min`, which is what it is for.
      const delay = Math.min(
        this.authBackoffMaxMs,
        this.authBackoffBaseMs * Math.pow(2, excess - 1));
      rec.until = now + delay;
    }

    this._authWindow.count += 1;
    if (!tripped && this._authRate(now) >= this.authGlobalFailures) {
      this._authTrippedUntil = now + this.authLockoutMs;
      return true;
    }
    return false;
  }

  /*
   * This address just proved it holds a valid code, so its failure history
   * goes. There is no way to reach here without having been allowed to try,
   * so clearing cannot be used to launder a backoff.
   *
   * The hub-wide counter is deliberately *not* decremented. It measures how
   * much wrong-passcode traffic the hub is absorbing, and one friend getting
   * in does not make a thousand failures elsewhere benign; the window is
   * what forgives them, on its own schedule.
   */
  noteAuthSuccess(ip) {
    return this._authFails.delete(ipCountKey(ip));
  }

  /** Is the hub-wide ceiling tripped right now? */
  get authLockdown() {
    return this._authTick(this.now());
  }

  /*
   * Milliseconds until this address may attempt authentication again; 0 when
   * it may right now. The larger of the two clocks, because both have to
   * elapse. For a message to a human, not a control -- `authAllowed` is the
   * decision.
   */
  authRetryAfterMs(ip) {
    const now = this.now();
    let wait = this._authTick(now) ? this._authTrippedUntil - now : 0;
    const rec = this._authFails.get(ipCountKey(ip));
    if (rec && now < rec.until) wait = Math.max(wait, rec.until - now);
    return Math.max(0, wait);
  }

  // ----------------------------------------------------------------- sweep

  /*
   * Who should be destroyed right now, and why.
   *
   * Pure by design: it reads the clock, returns a list, and releases
   * nothing. The caller closes the sockets, and closing them calls
   * `release` through the normal `close` handler -- so there is exactly one
   * path out of this table and no way for the two to disagree.
   *
   * Reasons are ordered most-specific-first. A connection that has not
   * greeted is judged only on its handshake budget, because "silent" and
   * "dribbling" are the same failure before hello and the handshake budget
   * is the tighter of the two. After hello, a stalled partial line is a
   * more precise diagnosis than plain idleness, and its clock is shorter,
   * so it is reported in preference.
   */
  sweep() {
    const now = this.now();
    this._prune(now);

    const doomed = [];
    for (const [key, rec] of this._conns) {
      if (!rec.greeted) {
        if (now - rec.at > this.handshakeTimeoutMs) {
          doomed.push({ key, reason: 'handshake_timeout' });
        }
        continue;
      }
      if (rec.partialSince !== null &&
          now - rec.partialSince > this.partialLineTimeoutMs) {
        doomed.push({ key, reason: 'slowloris' });
        continue;
      }
      if (now - rec.lastActivity > this.idleTimeoutMs) {
        doomed.push({ key, reason: 'idle_timeout' });
      }
    }
    return doomed;
  }

  /*
   * Backpressure. `socket.write()` returns false once the kernel buffer is
   * full and Node starts queueing in userland; hub.js discards that boolean,
   * so a peer that connects and never reads makes the hub's memory grow
   * without bound while looking, from the outside, like a healthy player.
   *
   * The caller passes `socket.writableLength` and destroys the connection on
   * false. Deliberately not keyed on any stored state -- an unknown key is
   * still judged on its buffer, because the buffer is the actual hazard.
   */
  writeAllowed(key, writableLength) {
    const n = Number(writableLength);
    if (!Number.isFinite(n)) return true;
    return n <= this.maxWriteBufferBytes;
  }

  // ------------------------------------------------------------- policy

  setBans(list) {
    this._bans = toIpSet(list);
  }

  setAllowlist(list) {
    this._allow = toIpSet(list);
  }

  // ------------------------------------------------------------ reporting

  get pendingCount() {
    return this._pending;
  }

  /*
   * Live connections charged against this address's budget -- so for IPv6
   * this is the count for its whole /64, which is the number the cap is
   * actually compared against. Asking with any address in the block gives
   * the same answer, by design.
   */
  connectionsFrom(ip) {
    return this._perIp.get(ipCountKey(ip)) || 0;
  }

  /**
   * The shape the CLI's `status` verb prints. `perIp` is keyed the way the
   * cap counts: an exact address for IPv4, a `2001:db8::/64`-style prefix
   * for IPv6.
   *
   * `auth` is what lets `status` and `doctor` say "someone is hammering your
   * hub" rather than leaving the host to guess from the log. It is the whole
   * picture in five numbers: how many wrong passcodes arrived recently and
   * what the ceiling is (so the reading has a scale), whether the ceiling is
   * currently tripped and for how much longer, and how many individual
   * addresses are backed off (so a host can tell one grinder from a rented
   * fleet). Rounded, because the recent count is a windowed estimate and a
   * fraction of a failure is not a thing to print at a human.
   */
  stats() {
    const perIp = {};
    for (const [ip, count] of this._perIp) perIp[ip] = count;

    const now = this.now();
    const lockdown = this._authTick(now);
    let throttled = 0;
    for (const rec of this._authFails.values()) {
      if (now < rec.until) throttled += 1;
    }

    return {
      connections: this._conns.size,
      pending: this._pending,
      perIp,
      auth: {
        recentFailures: Math.round(this._authRate(now)),
        failureThreshold: this.authGlobalFailures,
        windowMs: this.authGlobalWindowMs,
        lockdown,
        lockdownMs: lockdown ? this._authTrippedUntil - now : 0,
        throttledAddresses: throttled,
        trackedAddresses: this._authFails.size,
      },
    };
  }

  // ------------------------------------------------------------- internals

  /*
   * Roll the hub-wide failure window forward and release an expired trip.
   * Returns whether the ceiling is tripped *after* rolling, which is the
   * answer every public auth method actually wants.
   *
   * Releasing zeroes the counters rather than letting them keep decaying:
   * the failures that caused the trip have already been paid for with a
   * lockout, and carrying them into the next window would re-trip the hub
   * instantly on a single stray attempt.
   *
   * The backwards-clock guard is the same concern as the token bucket's
   * `Math.max(0, ...)`. An NTP step backwards would otherwise leave
   * `_authTrippedUntil` arbitrarily far in the future and close the hub to
   * new players until it caught up; re-anchoring to one lockout from now
   * bounds the damage to the lockout the host configured.
   */
  _authTick(now) {
    if (this._authTrippedUntil !== 0) {
      if (this._authTrippedUntil - now > this.authLockoutMs) {
        this._authTrippedUntil = now + this.authLockoutMs;
      } else if (now >= this._authTrippedUntil) {
        this._authTrippedUntil = 0;
        this._authWindow = { start: now, count: 0, prev: 0 };
      }
    }
    this._authRoll(now);
    return this._authTrippedUntil !== 0;
  }

  /*
   * The window is two counters, current and previous, and `_authRate`
   * reads them as a sliding estimate. Neither of the obvious alternatives
   * works here: a plain fixed window is blind to a burst straddling its
   * boundary, so an attacker who fails `threshold - 1` times either side of
   * the tick gets nearly double the ceiling for free, and a list of failure
   * timestamps is a Map an attacker writes to once per guess -- a memory
   * leak inside a memory-leak guard. Two integers and a division do neither.
   */
  _authRoll(now) {
    const w = this.authGlobalWindowMs;
    const win = this._authWindow;
    if (now < win.start) {
      // The clock moved backwards; there is no honest way to age a window
      // across that, so start a fresh one rather than invent a rate.
      this._authWindow = { start: now, count: 0, prev: 0 };
      return;
    }
    const elapsed = now - win.start;
    if (elapsed >= 2 * w) {
      // Two whole windows of silence: nothing recent survives.
      this._authWindow = { start: now, count: 0, prev: 0 };
    } else if (elapsed >= w) {
      win.prev = win.count;
      win.count = 0;
      win.start += w;
    }
  }

  /* Estimated failures over the trailing window. Assumes `_authRoll` ran. */
  _authRate(now) {
    const w = this.authGlobalWindowMs;
    const win = this._authWindow;
    const into = Math.min(w, Math.max(0, now - win.start));
    return win.count + win.prev * (1 - into / w);
  }

  /*
   * A token bucket per count key -- one address for IPv4, one /64 for IPv6:
   * `connectBurst` capacity, refilled at `connectPerMinute`. A fresh key
   * starts full, so the first connection from anyone is never rate-limited.
   */
  _spendToken(ip, now) {
    let bucket = this._buckets.get(ip);
    if (!bucket) {
      bucket = { tokens: this.connectBurst, last: now };
      this._buckets.set(ip, bucket);
    } else {
      // `Math.max(0, ...)` because the clock is injected and an injected
      // clock can run backwards -- as can the real one, across an NTP step.
      // Negative elapsed time would drain a bucket nobody touched.
      const elapsed = Math.max(0, now - bucket.last);
      bucket.tokens = Math.min(
        this.connectBurst, bucket.tokens + elapsed * this._tokensPerMs);
      bucket.last = now;
    }
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
  }

  /*
   * Buckets are keyed by count key and a flooder can cycle blocks, so
   * without this the rate limiter is itself a memory leak -- an unbounded
   * Map written to once per hostile connect.
   *
   * The rule that makes pruning safe is that **a full bucket carries no
   * information**: an address whose bucket has refilled to capacity is
   * indistinguishable from an address that has never connected, because a
   * fresh bucket starts full. Deleting it grants the attacker nothing.
   *
   * Doing that scan on every `admit` would make admission O(buckets), which
   * hands the flooder a different lever, so it is interval-gated and forced
   * only when the map is over its hard cap. No timer: the caller's own
   * traffic drives it, which means an idle hub does no work at all.
   */
  _prune(now, force) {
    const over = this._buckets.size > MAX_BUCKETS ||
      this._authFails.size > MAX_AUTH_RECORDS;
    if (!force && !over && now - this._prunedAt < PRUNE_INTERVAL_MS) return;
    this._prunedAt = now;

    this._pruneAuth(now);

    for (const [ip, bucket] of this._buckets) {
      const elapsed = Math.max(0, now - bucket.last);
      if (bucket.tokens + elapsed * this._tokensPerMs >= this.connectBurst) {
        this._buckets.delete(ip);
      }
    }
    if (this._buckets.size <= MAX_BUCKETS) return;

    // Still over the cap means there really are that many addresses mid-
    // flood. Memory has to win, so the fullest buckets go first: they are
    // the closest to being free to drop, and the furthest from the
    // attackers actually being throttled.
    const ranked = [...this._buckets.entries()]
      .sort((a, b) => b[1].tokens - a[1].tokens);
    const target = Math.floor(MAX_BUCKETS * 0.9);
    for (let i = 0; i < ranked.length && this._buckets.size > target; i += 1) {
      this._buckets.delete(ranked[i][0]);
    }
  }

  /*
   * The same guard for the failure map, on the same rule: a record whose
   * window has lapsed and whose backoff has run out carries no information,
   * because a fresh address is treated identically. Dropping it grants the
   * attacker nothing.
   *
   * Over the hard cap, the *least*-throttled records go first -- mirror
   * image of the bucket eviction above, and for the mirror reason: they are
   * the closest to being free to drop and the furthest from anyone actually
   * being held back. Ties break on the staler record.
   *
   * Eviction is safe here only because the hub-wide ceiling exists. An
   * attacker who cycles addresses fast enough to force it is, by
   * construction, producing failures fast enough to trip the global ceiling
   * long before the per-IP records they are flushing would have mattered.
   * That is the division of labour: the per-IP map shapes the honest case,
   * the global counter holds the line when the map cannot.
   */
  _pruneAuth(now) {
    for (const [key, rec] of this._authFails) {
      if (now < rec.until) continue;
      if (now - rec.last < this.authFailureWindowMs) continue;
      this._authFails.delete(key);
    }
    if (this._authFails.size <= MAX_AUTH_RECORDS) return;

    const ranked = [...this._authFails.entries()]
      .sort((a, b) => (a[1].until - b[1].until) || (a[1].last - b[1].last));
    const target = Math.floor(MAX_AUTH_RECORDS * 0.9);
    for (let i = 0; i < ranked.length && this._authFails.size > target; i += 1) {
      this._authFails.delete(ranked[i][0]);
    }
  }
}

module.exports = { Limits, normalizeIp, ipCountKey, DEFAULTS, BOUNDS };
