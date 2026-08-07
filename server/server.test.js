#!/usr/bin/env node
'use strict';

/*
 * End-to-end test for the hardened hub, over real TCP sockets.
 *
 * hub.test.js drives the unauthenticated relay -- roster, movement, chat
 * scopes, sessions -- against `node hub.js` as a child process. This file
 * drives everything Wave 2 (plan §3.1-3.6, `docs/plans/self-hosting-server-app.md`)
 * built around that relay: the HMAC challenge/response handshake, refusal
 * uniformity, replay resistance, the §3.6 seat-at-hello fix, per-IP and ban
 * enforcement, the handshake timeout, invite use-counting, and graceful
 * shutdown -- plus the authentication throttle that guards a 30-bit passcode,
 * and the refusal to start a hub anyone could walk into.
 *
 * Same idiom as hub.test.js on purpose: the throwing `ok()`, the
 * promise-based `Client` wrapper with `expect`/`expectSilence`, one scenario
 * function per behaviour, a final pass count. No test framework, no
 * dependencies beyond Node core.
 *
 * Most scenarios start `lib/server.js` in-process on an ephemeral port
 * (`listen.port: 0`) -- faster and immune to port collisions with any other
 * suite running alongside this one. Only the SIGTERM scenario spawns a real
 * child process, because signal handling cannot be exercised any other way;
 * that one child claims a fixed, pid-derived port picked to sit clear of the
 * range hub.test.js uses (PORT..PORT+2, i.e. 7801 + pid%200 .. +2).
 *
 * Run: node server/server.test.js
 */

const net = require('net');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('child_process');
const assert = require('assert');

const {
  start, STATUS_FILENAME, STATUS_HEARTBEAT_MS,
  HISTORY_FILENAME, HISTORY_MAX_BYTES, ADMIN_SOCKET_FILENAME,
} = require('./lib/server.js');
// Read from the relay rather than typed in, so a protocol bump is one edit
// in one file and not a hunt through two suites for the greeting that still
// says the old number.
const { PROTOCOL } = require('./lib/relay.js');

const CHILD_PORT = 8801 + (process.pid % 200); // clear of hub.test.js's 7801-8002
const SERVER_JS_PATH = path.join(__dirname, 'lib', 'server.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(50);
  }
  return false;
}

// ------------------------------------------------------------------ Client
// Copied verbatim in shape from hub.test.js: a thin promise-based wrapper
// around a real socket speaking the mod's newline-JSON.

class Client {
  // `host` is almost always the default. It is a parameter for exactly one
  // reason: the per-address throttle has to be shown sparing a *different*
  // address, and on a dual-stack listener ::1 is one. See secondLoopback().
  //
  // The one-line variant: pass `{ path }` instead of a port to speak to a
  // Unix socket -- the admin channel -- over the same inbox/expect machinery
  // every game-port scenario in this file already uses.
  constructor(portOrOptions, host = '127.0.0.1') {
    const options = (portOrOptions && typeof portOrOptions === 'object')
      ? portOrOptions : { port: portOrOptions, host };
    this.socket = net.createConnection(options);
    this.socket.setEncoding('utf8');
    this.buffer = '';
    this.inbox = [];
    this.socket.on('data', (chunk) => {
      this.buffer += chunk;
      let i;
      while ((i = this.buffer.indexOf('\n')) >= 0) {
        const line = this.buffer.slice(0, i);
        this.buffer = this.buffer.slice(i + 1);
        if (line) this.inbox.push(JSON.parse(line));
      }
    });
  }
  ready() {
    return new Promise((resolve, reject) => {
      this.socket.once('connect', resolve);
      this.socket.once('error', reject);
    });
  }
  send(type, payload) {
    this.socket.write(JSON.stringify(Object.assign({}, payload, { type })) + '\n');
  }
  // The admin socket's protocol has no `type` field (it dispatches on `cmd`,
  // and answers with `ok`), so it does not fit send()'s "merge a type in"
  // shape. This writes exactly the object it is given.
  sendRaw(text) {
    this.socket.write((typeof text === 'string' ? text : JSON.stringify(text)) + '\n');
  }
  // For a one-shot exchange (admin.sock: one request line, one response
  // line) where there is no `type` field to match on -- the inbox already
  // holds whatever parsed, this just waits for the first of it.
  async expectAny(timeoutMs = 1500) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.inbox.length) return this.inbox.shift();
      await sleep(10);
    }
    throw new Error('timed out waiting for any message');
  }
  async expect(type, timeoutMs = 1500) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const index = this.inbox.findIndex((m) => m.type === type);
      if (index >= 0) return this.inbox.splice(index, 1)[0];
      await sleep(10);
    }
    throw new Error(`timed out waiting for ${type}; saw ` +
      JSON.stringify(this.inbox.map((m) => m.type)));
  }
  // For the questions whose answer is "one of these two, and which one is the
  // point" -- welcome or error, admitted or refused.
  async expectEither(a, b, timeoutMs = 1500) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const index = this.inbox.findIndex((m) => m.type === a || m.type === b);
      if (index >= 0) return this.inbox.splice(index, 1)[0];
      await sleep(10);
    }
    throw new Error(`timed out waiting for ${a} or ${b}; saw ` +
      JSON.stringify(this.inbox.map((m) => m.type)));
  }
  async expectSilence(type, windowMs = 300) {
    const deadline = Date.now() + windowMs;
    while (Date.now() < deadline) {
      if (this.inbox.some((m) => m.type === type)) {
        throw new Error(`unexpectedly received ${type}`);
      }
      await sleep(10);
    }
    return true;
  }
  close() { this.socket.destroy(); }
}

function rawConnect(port) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ port, host: '127.0.0.1' });
    socket.once('connect', () => resolve(socket));
    socket.once('error', reject);
  });
}

// ------------------------------------------------------------- small helpers

// A short-named temp dir, straight under the OS temp root rather than a
// deeply-nested one of our own -- wave 2 starts an admin.sock beside every
// config file it is handed, and a Unix socket path is capped at ~104 bytes
// on darwin. A long prefix here is exactly how that cap gets hit by accident.
function shortTmpDir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

// -------------------------------------------------------------- HMAC, by hand
//
// The wire contract (server/lib/auth.js's header comment): key is the
// normalised join code as ASCII bytes, message is the nonce as its
// lowercase-hex ASCII *string*, response is 64 lowercase hex characters.
// Computed here with node:crypto directly -- never via auth.sign()/verify()
// -- so a bug in auth.js has an independent witness instead of grading its
// own homework.
function hmacHex(key, nonceHex) {
  return crypto.createHmac('sha256', Buffer.from(key, 'ascii'))
    .update(nonceHex, 'ascii')
    .digest('hex');
}

// Join codes, hand-picked from the mod's Crockford-style alphabet (0-9, A-Z
// minus I L O U) so every one of them is already in its normalised form.
//
// A passcode is six characters now, not sixteen: 2^30 rather than 2^80, taken
// deliberately because a code a player has to type on an in-game naming grid
// has to be short (server/lib/auth.js's header states the trade and what pays
// for it). At six characters the typed form and the normalised form are the
// same string, so there is no separate `_KEY` spelling any more -- the code
// *is* the HMAC key. WRONG_CODE is well-formed and belongs to no hub in this
// file, which is what "a wrong code" means to a player: not malformed, just
// not theirs.
const PRIMARY_CODE = 'A7K3P9';
const EXPIRED_CODE = 'TVWXYZ';
const REVOKED_CODE = 'GHJKMN';
const WRONG_CODE = 'ZZ9ZZ9';

// A credential in the shape config.json stores. Written out by hand rather
// than built with auth.newCredential(), for the same reason hmacHex() is: a
// suite that constructs its fixtures with the module under test grades its
// own homework.
function credential(id, secret, extra = {}) {
  return Object.assign({
    id,
    label: id,
    secret,
    createdAt: new Date().toISOString(),
    expiresAt: null,
    maxUses: null,
    uses: 0,
    revoked: false,
  }, extra);
}

// ------------------------------------------------------------- server helper

const NULL_LOG = { debug() {}, info() {}, warn() {}, error() {} };

// Same shape, but it keeps what it was told. Used where a test has to wait for
// something the hub does on its own schedule (a SIGHUP arriving) rather than
// on the test's -- polling the log is how that becomes observable without
// sleeping on a guess.
function recordingLog() {
  const lines = [];
  const record = (level) => (message) => lines.push(`${level}: ${message}`);
  return {
    lines,
    saw(pattern) { return lines.some((line) => pattern.test(line)); },
    debug: record('debug'),
    info: record('info'),
    warn: record('warn'),
    error: record('error'),
  };
}

function baseConfig(overrides = {}) {
  const cfg = {
    version: 1,
    listen: { host: '127.0.0.1', port: 0 },
    maxPlayers: 4,
    auth: { required: false, credentials: [] },
    limits: {},
    bans: [],
    allowlist: [],
    network: { upnp: { enabled: false, leaseSeconds: 3600 } },
    log: { level: 'silent' },
  };
  return Object.assign({}, cfg, overrides, {
    listen: Object.assign({}, cfg.listen, overrides.listen),
    auth: Object.assign({}, cfg.auth, overrides.auth),
    limits: Object.assign({}, cfg.limits, overrides.limits),
  });
}

/*
 * `allowUnauthenticated` is passed by default, and it is not a shortcut.
 *
 * start() refuses to bring up a hub anyone could walk into -- that is its own
 * scenario (passcodeRequiredTest), asserted there without this flag. Every
 * *other* scenario in this file is about something underneath that decision:
 * the seat-at-hello fix, the per-IP cap, the sweep, shutdown. Making each of
 * them mint a join code and run a handshake first would test the door three
 * times over and the subject once, and would hide which of the two a failure
 * came from. So the door is opted out of exactly where it is not the subject,
 * in as many words, which is the same thing the option asks of hub.js.
 */
function startServer(overrides = {}, extra = {}) {
  return start(Object.assign({
    config: baseConfig(overrides),
    log: NULL_LOG,
    handleSignals: false,
    allowUnauthenticated: true,
  }, extra));
}

// =========================================================================
// scenarios
// =========================================================================

// ------- the auth handshake: happy path, refusal uniformity, replay, edges

async function authHandshakeTest() {
  const handle = await startServer({
    // This scenario deliberately produces four wrong codes in a row from one
    // address -- wrong, expired, revoked, replayed -- and every one of them is
    // the subject of an assertion below. Under the shipped grace of three the
    // fourth would be met by the throttle instead of by the credential check,
    // and the handshake's own behaviour would stop being observable. The
    // throttle is not disabled, it is moved out of the frame; it has three
    // scenarios of its own further down.
    limits: { authFailureGrace: 100 },
    auth: {
      required: true,
      credentials: [
        {
          id: 'primary', label: 'Primary', secret: PRIMARY_CODE,
          createdAt: new Date().toISOString(), expiresAt: null,
          maxUses: null, uses: 0, revoked: false,
        },
        {
          id: 'expired', label: 'Expired', secret: EXPIRED_CODE,
          createdAt: new Date().toISOString(),
          expiresAt: new Date(Date.now() - 60000).toISOString(),
          maxUses: null, uses: 0, revoked: false,
        },
        {
          id: 'revoked', label: 'Revoked', secret: REVOKED_CODE,
          createdAt: new Date().toISOString(), expiresAt: null,
          maxUses: null, uses: 0, revoked: true,
        },
      ],
    },
  });
  const port = handle.port;

  try {
    // ---- happy path
    const good = new Client(port);
    await good.ready();
    good.send('mmo.hello', { proto: PROTOCOL, name: 'GOOD' });
    const challenge = await good.expect('mmo.challenge');
    ok(/^[0-9a-f]{32}$/.test(challenge.nonce),
      'the nonce is 32 lowercase hex characters');
    good.send('mmo.auth', { response: hmacHex(PRIMARY_CODE, challenge.nonce) });
    const welcome = await good.expect('mmo.welcome');
    ok(typeof welcome.id === 'string', 'a correctly-answered challenge is welcomed');
    good.close();

    // ---- wrong code
    const wrong = new Client(port);
    await wrong.ready();
    wrong.send('mmo.hello', { proto: PROTOCOL, name: 'WRONG' });
    const wrongChallenge = await wrong.expect('mmo.challenge');
    wrong.send('mmo.auth', {
      response: hmacHex(WRONG_CODE, wrongChallenge.nonce),
    });
    const wrongRefusal = await wrong.expect('mmo.error');
    wrong.close();

    // ---- a valid-but-expired code
    const expired = new Client(port);
    await expired.ready();
    expired.send('mmo.hello', { proto: PROTOCOL, name: 'EXPIRED' });
    const expiredChallenge = await expired.expect('mmo.challenge');
    expired.send('mmo.auth', {
      response: hmacHex(EXPIRED_CODE, expiredChallenge.nonce),
    });
    const expiredRefusal = await expired.expect('mmo.error');
    expired.close();

    // ---- a valid-but-revoked code
    const revoked = new Client(port);
    await revoked.ready();
    revoked.send('mmo.hello', { proto: PROTOCOL, name: 'REVOKED' });
    const revokedChallenge = await revoked.expect('mmo.challenge');
    revoked.send('mmo.auth', {
      response: hmacHex(REVOKED_CODE, revokedChallenge.nonce),
    });
    const revokedRefusal = await revoked.expect('mmo.error');
    revoked.close();

    ok(wrongRefusal.message === expiredRefusal.message,
      'a wrong code and an expired code produce the identical refusal sentence');
    ok(wrongRefusal.message === revokedRefusal.message,
      'a wrong code and a revoked code produce the identical refusal sentence');
    ok(typeof wrongRefusal.message === 'string' && wrongRefusal.message.length > 0,
      'the shared refusal sentence is not empty');

    // ---- replay: a captured (nonce, response) pair is worthless elsewhere
    const capture = new Client(port);
    await capture.ready();
    capture.send('mmo.hello', { proto: PROTOCOL, name: 'CAPTURE' });
    const capturedChallenge = await capture.expect('mmo.challenge');
    const capturedResponse = hmacHex(PRIMARY_CODE, capturedChallenge.nonce);
    capture.close(); // never finishes its own handshake

    const replay = new Client(port);
    await replay.ready();
    replay.send('mmo.hello', { proto: PROTOCOL, name: 'REPLAY' });
    const replayChallenge = await replay.expect('mmo.challenge');
    ok(replayChallenge.nonce !== capturedChallenge.nonce,
      'each connection is issued its own nonce');
    replay.send('mmo.auth', { response: capturedResponse });
    await replay.expect('mmo.error');
    ok(true, 'a captured response fails against a fresh connection\'s nonce');
    replay.close();

    // ---- a second mmo.auth on the same connection, after one was consumed
    const twice = new Client(port);
    await twice.ready();
    twice.send('mmo.hello', { proto: PROTOCOL, name: 'TWICE' });
    const twiceChallenge = await twice.expect('mmo.challenge');
    const twiceResponse = hmacHex(PRIMARY_CODE, twiceChallenge.nonce);
    twice.send('mmo.auth', { response: twiceResponse });
    await twice.expect('mmo.welcome');
    // the nonce was already consumed by the line above; a second mmo.auth
    // must not be answered at all, success or failure
    twice.send('mmo.auth', { response: twiceResponse });
    await twice.expectSilence('mmo.welcome', 300);
    await twice.expectSilence('mmo.error', 50);
    ok(true, 'a second mmo.auth after the challenge was consumed draws no reply');
    twice.close();

    // ---- mmo.auth with no outstanding challenge at all
    const unsolicited = new Client(port);
    await unsolicited.ready();
    unsolicited.send('mmo.auth', { response: hmacHex(PRIMARY_CODE, '00'.repeat(16)) });
    await unsolicited.expectSilence('mmo.error', 300);
    await unsolicited.expectSilence('mmo.welcome', 50);
    // and the connection is still usable afterwards -- ignored, not spent
    unsolicited.send('mmo.hello', { proto: PROTOCOL, name: 'LATER' });
    const laterChallenge = await unsolicited.expect('mmo.challenge');
    unsolicited.send('mmo.auth', {
      response: hmacHex(PRIMARY_CODE, laterChallenge.nonce),
    });
    await unsolicited.expect('mmo.welcome');
    ok(true, 'an unsolicited mmo.auth is ignored, not treated as a fatal error');
    unsolicited.close();
  } finally {
    await handle.close();
  }
}

// ------- auth off: byte-identical to the legacy no-auth handshake

async function authOffTest() {
  const handle = await startServer({ auth: { required: false, credentials: [] } });
  try {
    const client = new Client(handle.port);
    await client.ready();
    client.send('mmo.hello', { proto: PROTOCOL, name: 'OPEN' });
    const welcome = await client.expect('mmo.welcome');
    ok(typeof welcome.id === 'string', 'auth off: hello leads straight to welcome');
    ok(Array.isArray(welcome.players), 'the welcome still carries a roster');
    ok(!client.inbox.some((m) => m.type === 'mmo.challenge'),
      'no challenge was ever sent when auth is off');
    client.close();
  } finally {
    await handle.close();
  }
}

// ------- the §3.6 regression: ungreeted sockets cannot lock out a real player

async function silentSocketsDoNotLockOutTest() {
  // perIpConnections defaults to maxPlayers (4), and every socket here comes
  // from the same loopback address -- raised so the scenario under test is
  // the seat-at-hello fix, not an incidental collision with the per-IP cap
  // (exercised on its own in perIpCapTest).
  const handle = await startServer({ maxPlayers: 4, limits: { perIpConnections: 10 } });
  const port = handle.port;
  const ghosts = [];
  try {
    // Fill exactly maxPlayers worth of connections that never say hello.
    // Before the §3.6 fix, hub.js charged a seat at accept, so four silent
    // sockets on a four-player hub locked out everyone else for
    // TIMEOUT_MS (45s). The fix charges a seat at hello instead.
    for (let i = 0; i < 4; i++) {
      ghosts.push(await rawConnect(port));
    }

    const late = new Client(port);
    await late.ready();
    late.send('mmo.hello', { proto: PROTOCOL, name: 'LATE' });
    const welcome = await late.expect('mmo.welcome', 3000);
    ok(typeof welcome.id === 'string',
      'a real player still gets in with the cap full of silent sockets');
    ok(welcome.players.length === 0,
      'the silent sockets never appear as players either');
    late.close();
  } finally {
    for (const g of ghosts) g.destroy();
    await handle.close();
  }
}

// ------- the converse: a cap filled by *greeted* players refuses promptly

async function capFilledByGreetedPlayersTest() {
  // Five connections from the same loopback address; raised past the
  // default perIpConnections (4) so the refusal under test is the player
  // cap, not the per-IP cap (exercised on its own in perIpCapTest).
  const handle = await startServer({ maxPlayers: 4, limits: { perIpConnections: 10 } });
  const port = handle.port;
  const players = [];
  try {
    for (let i = 0; i < 4; i++) {
      const client = new Client(port);
      await client.ready();
      client.send('mmo.hello', { proto: PROTOCOL, name: 'P' + i });
      await client.expect('mmo.welcome');
      players.push(client);
    }
    ok(players.length === 4, 'four players fill the default-sized hub');

    const fifth = new Client(port);
    await fifth.ready();
    const startedAt = Date.now();
    const refused = await fifth.expect('mmo.error', 2000);
    const elapsedMs = Date.now() - startedAt;
    ok(/full/i.test(refused.message), 'a full hub names itself full');
    ok(/4/.test(refused.message), 'and names the limit');
    ok(elapsedMs < 1000,
      'a hub already full of greeted players refuses immediately, not after a timeout');
    fifth.close();
  } finally {
    for (const p of players) p.close();
    await handle.close();
  }
}

// ------- the cap holds on a hub that challenges, not just on an open one
//
// The regression this pins: the seat is charged in relay.admit(), but the
// only cap check used to live in the mmo.hello handler. On an open hub those
// are the same instant, so nothing showed. On a hub that requires a join
// code they are not: hello only issues a challenge, and every socket that
// greets while there is room passes the check -- then *all* of them become
// players when they answer. With maxPlayers 2 and six sockets greeting before
// any of them answered, six were welcomed and playerCount reached 6, bounded
// only by limits.maxPending. The fix moves the check into admit(), which is
// the one place every player passes through.

async function capHoldsWhenEveryoneGreetsBeforeAnswering() {
  const handle = await startServer({
    maxPlayers: 2,
    // Raised out of the way: this scenario is about the player cap, and six
    // sockets from one loopback address would otherwise meet the per-IP cap
    // (perIpCapTest) or the pending cap first.
    limits: { perIpConnections: 20, maxPending: 16 },
    auth: {
      required: true,
      credentials: [{
        id: 'primary', label: 'Primary', secret: PRIMARY_CODE,
        createdAt: new Date().toISOString(), expiresAt: null,
        maxUses: null, uses: 0, revoked: false,
      }],
    },
  });
  const port = handle.port;
  const clients = [];
  try {
    // Phase one: everybody greets. Nobody is a player yet, so every one of
    // them is inside the cap at this instant.
    const challenges = [];
    for (let i = 0; i < 6; i++) {
      const client = new Client(port);
      await client.ready();
      clients.push(client);
      client.send('mmo.hello', { proto: PROTOCOL, name: 'RUSH' + i });
      challenges.push(await client.expect('mmo.challenge'));
    }
    ok(challenges.length === 6,
      'six sockets can all be mid-handshake on a two-player hub');
    ok(handle.relay.playerCount === 0,
      'and none of them is a player while the challenge is outstanding');

    // Phase two: everybody answers, correctly.
    for (let i = 0; i < 6; i++) {
      clients[i].send('mmo.auth', { response: hmacHex(PRIMARY_CODE, challenges[i].nonce) });
    }

    const verdicts = await Promise.all(clients.map(
      (client) => client.expectEither('mmo.welcome', 'mmo.error', 2000)));

    const welcomed = verdicts.filter((m) => m.type === 'mmo.welcome');
    const refused = verdicts.filter((m) => m.type === 'mmo.error');

    ok(welcomed.length === 2,
      'exactly maxPlayers clients are welcomed, however many answered at once');
    ok(handle.relay.playerCount === 2,
      'and the hub counts exactly maxPlayers players');
    ok(refused.length === 4, 'every client over the cap is answered, not ignored');
    ok(refused.every((m) => /full/i.test(m.message) && /2/.test(m.message)),
      'and each is told the hub is full, naming the limit');
  } finally {
    for (const client of clients) client.close();
    await handle.close();
  }
}

// ------- per-IP cap

async function perIpCapTest() {
  const handle = await startServer({ limits: { perIpConnections: 2 } });
  const port = handle.port;
  const sockets = [];
  try {
    for (let i = 0; i < 2; i++) {
      sockets.push(await rawConnect(port));
    }
    const third = new Client(port);
    await third.ready();
    const refused = await third.expect('mmo.error');
    ok(/too many connections/i.test(refused.message),
      'a connection over the per-IP cap gets a message, not silence');
    ok(/2/.test(refused.message), 'and the message names the configured limit');
    third.close();
  } finally {
    for (const s of sockets) s.destroy();
    await handle.close();
  }
}

// ------- ban

async function banTest() {
  const handle = await startServer({});
  const port = handle.port;
  try {
    // admitted before the ban exists
    const before = new Client(port);
    await before.ready();
    before.send('mmo.hello', { proto: PROTOCOL, name: 'BEFORE' });
    await before.expect('mmo.welcome');

    // setBans affects new admissions only -- ban after this one is already in
    handle.limits.setBans(['127.0.0.1']);

    const after = new Client(port);
    await after.ready();
    after.send('mmo.hello', { proto: PROTOCOL, name: 'AFTER' });
    await after.expectSilence('mmo.welcome', 500);
    ok(true, 'a newly-banned address cannot join');

    // the connection admitted before the ban is untouched
    before.send('mmo.ping', {});
    await before.expect('mmo.pong');
    ok(true, 'setBans does not retroactively drop an already-admitted connection');

    before.close();
    after.close();
  } finally {
    await handle.close();
  }
}

// ------- handshake timeout

async function handshakeTimeoutTest() {
  const handle = await startServer({ limits: { handshakeTimeoutMs: 1000 } });
  const port = handle.port;
  const raw = await rawConnect(port);
  try {
    const closed = await new Promise((resolve) => {
      const timer = setTimeout(() => resolve(false), 3000);
      raw.once('close', () => { clearTimeout(timer); resolve(true); });
    });
    ok(closed, 'a connection that never speaks is dropped after handshakeTimeoutMs');
  } finally {
    raw.destroy();
    await handle.close();
  }
}

// ------- invite --uses: admits exactly maxUses clients, persists the count

async function inviteUsesPersistTest() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rby-mmo-server-test-'));
  const configPath = path.join(dir, 'config.json');
  const code = 'JKMN67';

  const cfg = baseConfig({
    auth: {
      required: true,
      credentials: [credential('limited', code, { label: 'One use', maxUses: 1 })],
    },
  });
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2), { mode: 0o600 });

  try {
    const handle = await start({
      config: cfg, log: NULL_LOG, configPath, handleSignals: false,
    });
    const port = handle.port;
    try {
      const first = new Client(port);
      await first.ready();
      first.send('mmo.hello', { proto: PROTOCOL, name: 'FIRST' });
      const firstChallenge = await first.expect('mmo.challenge');
      first.send('mmo.auth', { response: hmacHex(code, firstChallenge.nonce) });
      await first.expect('mmo.welcome');

      const second = new Client(port);
      await second.ready();
      second.send('mmo.hello', { proto: PROTOCOL, name: 'SECOND' });
      const secondChallenge = await second.expect('mmo.challenge');
      second.send('mmo.auth', { response: hmacHex(code, secondChallenge.nonce) });
      await second.expect('mmo.error');
      ok(true, 'a maxUses:1 credential admits exactly one client');
      second.close();

      // the write is coalesced on a ~1s timer -- poll rather than assert
      // instantly
      const persisted = await waitFor(() => {
        try {
          const onDisk = JSON.parse(fs.readFileSync(configPath, 'utf8'));
          return onDisk.auth.credentials[0].uses === 1;
        } catch (err) {
          return false;
        }
      }, 3000);
      ok(persisted, 'the use count reaches disk within the coalescing window');

      first.close();
    } finally {
      await handle.close();
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// ------- and the converse: no configPath, no write, ever

async function inviteUsesNoWriteWithoutConfigPathTest() {
  const code = 'PQRS45';
  const cfg = baseConfig({
    auth: {
      required: true,
      credentials: [credential('ephemeral', code, { label: 'No file' })],
    },
  });

  // No configPath is passed to start() below -- this is the hub.js shim's
  // world (no config, nothing that outlives the process). Spy on
  // fs.writeFileSync for the duration to prove nothing tries to persist.
  const originalWrite = fs.writeFileSync;
  let writeCalls = 0;
  fs.writeFileSync = function spy(...args) {
    writeCalls += 1;
    return originalWrite.apply(fs, args);
  };

  try {
    const handle = await start({ config: cfg, log: NULL_LOG, handleSignals: false });
    try {
      const client = new Client(handle.port);
      await client.ready();
      client.send('mmo.hello', { proto: PROTOCOL, name: 'EPHEMERAL' });
      const challenge = await client.expect('mmo.challenge');
      client.send('mmo.auth', { response: hmacHex(code, challenge.nonce) });
      await client.expect('mmo.welcome');
      // past the ~1s coalescing window a persisted write would have used
      await sleep(1300);
      ok(writeCalls === 0,
        'with no configPath, a credential use is never written to disk');
      client.close();
    } finally {
      await handle.close();
    }
  } finally {
    fs.writeFileSync = originalWrite;
  }
}

// ------- SIGHUP: revocations, bans and allowlists take effect without a restart
//
// Everything here is driven by a *real* signal against this process, which is
// why it is the one in-process scenario started with handleSignals left on.
// The point of the feature is that a host revoking a leaked code does not have
// to drop everyone mid-battle to make it stick, so nothing below restarts the
// hub or reconnects the player who is already on it.

async function sighupReloadTest() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rby-mmo-reload-test-'));
  const configPath = path.join(dir, 'config.json');

  const invite = 'JKMN67';
  const minted = 'QRST89';

  const write = (auth, bans) => fs.writeFileSync(configPath,
    JSON.stringify(baseConfig({ auth, bans }), null, 2), { mode: 0o600 });

  write({ required: true, credentials: [credential('invite', invite)] }, []);

  const log = recordingLog();
  const handle = await start({
    config: baseConfig({
      auth: { required: true, credentials: [credential('invite', invite)] },
    }),
    log,
    configPath,
    // The whole point: a real SIGHUP, delivered to this process.
    handleSignals: true,
  });
  const port = handle.port;

  const join = async (name, key) => {
    const client = new Client(port);
    await client.ready();
    client.send('mmo.hello', { proto: PROTOCOL, name });
    const challenge = await client.expect('mmo.challenge');
    client.send('mmo.auth', { response: hmacHex(key, challenge.nonce) });
    const verdict = await client.expectEither('mmo.welcome', 'mmo.error');
    return { client, verdict };
  };

  const hangup = async (label) => {
    const before = log.lines.length;
    process.kill(process.pid, 'SIGHUP');
    const done = await waitFor(
      () => log.lines.slice(before).some((line) => /reloaded /.test(line)), 2000);
    ok(done, `SIGHUP is handled and logs what it reloaded (${label})`);
  };

  try {
    const staying = await join('STAYING', invite);
    ok(staying.verdict.type === 'mmo.welcome',
      'the invite code works before it is revoked');

    // The hub is the writer of record for `uses` and flushes on a ~1s timer;
    // waiting for that write means the edit below is not the loser of a race
    // it has nothing to do with.
    await sleep(1300);

    // The host revokes the leaked code and mints a replacement -- the edit a
    // `revoke` + `invite` pair leaves behind -- and hangs up.
    write({
      required: true,
      credentials: [
        credential('invite', invite, { revoked: true }),
        credential('minted', minted),
      ],
    }, []);
    await hangup('credentials');

    const rejected = await join('REVOKED', invite);
    ok(rejected.verdict.type === 'mmo.error',
      'the revoked code is refused after SIGHUP, with no restart');
    ok(/not accepted/i.test(rejected.verdict.message),
      'and refused in the ordinary sentence, not a new one');
    rejected.client.close();

    const admitted = await join('MINTED', minted);
    ok(admitted.verdict.type === 'mmo.welcome',
      'a credential added by the same edit admits immediately');
    admitted.client.close();

    // The player who was already on the hub when the code was revoked is
    // untouched: revoking a code is not kicking everyone.
    staying.client.send('mmo.ping', {});
    await staying.client.expect('mmo.pong');
    ok(true, 'a player already connected is not disturbed by a reload');

    // Bans are the second of the three, and take effect the same way.
    await sleep(1300);
    write({
      required: true,
      credentials: [credential('minted', minted)],
    }, ['127.0.0.1']);
    await hangup('bans');

    const banned = new Client(port);
    await banned.ready();
    banned.send('mmo.hello', { proto: PROTOCOL, name: 'BANNED' });
    await banned.expectSilence('mmo.challenge', 500);
    ok(true, 'a ban added to the file takes effect on the next connection');
    banned.close();

    // A file that cannot be read changes nothing. The hazard is a config
    // edited in place and hung up on mid-save: a hub that emptied its ban
    // list over half a file would hold its own door open at the worst moment.
    fs.writeFileSync(configPath, '{ "bans": ["127.0.0', { mode: 0o600 });
    const before = log.lines.length;
    process.kill(process.pid, 'SIGHUP');
    const complained = await waitFor(
      () => log.lines.slice(before).some((line) => /reload: could not read/.test(line)),
      2000);
    ok(complained, 'a malformed config is reported rather than applied');

    const stillBanned = new Client(port);
    await stillBanned.ready();
    stillBanned.send('mmo.hello', { proto: PROTOCOL, name: 'STILLBANNED' });
    await stillBanned.expectSilence('mmo.challenge', 500);
    ok(true, 'and the ban list already in force survives the failed reload');
    stillBanned.close();

    staying.client.close();
  } finally {
    await handle.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// ------- onShutdown: awaited, bounded, once
//
// The CLI's UPnP unmap rides on this hook. It used to be fire-and-forget on a
// signal handler, where server.js's own process.exit(0) tore it down
// mid-SOAP -- so the port stayed forwarded on the router after every Ctrl-C
// (plan §3.7). The contract that fixes it is exactly this: close() does not
// resolve until the hook has finished or run out of time.

async function shutdownHookTest() {
  {
    let finished = false;
    let calls = 0;
    const handle = await startServer({}, {
      onShutdown: async () => {
        calls += 1;
        await sleep(150);
        finished = true;
      },
    });
    await handle.close();
    ok(finished, 'close() does not resolve until onShutdown has finished');
    // A second close() is the same close(); the hook is not a shutdown step
    // that can be run twice.
    await handle.close();
    ok(calls === 1, 'and onShutdown runs exactly once however often close() is called');
  }

  {
    // A router that never answers must not be able to wedge Ctrl-C.
    const handle = await startServer({}, { onShutdown: () => new Promise(() => {}) });
    const startedAt = Date.now();
    await handle.close();
    const elapsedMs = Date.now() - startedAt;
    ok(elapsedMs >= 1500,
      'a hook that never settles is waited on rather than skipped');
    ok(elapsedMs < 4000,
      'but only up to its own budget, so shutdown always completes');
  }

  {
    // A hook that throws is the caller's problem, never the hub's.
    const handle = await startServer({}, {
      onShutdown: () => Promise.reject(new Error('the router said no')),
    });
    let rejected = false;
    await handle.close().catch(() => { rejected = true; });
    ok(!rejected, 'a failing onShutdown does not make close() reject');
  }
}

// ------- graceful shutdown: in-process close()

async function gracefulShutdownInProcessTest() {
  const handle = await startServer({});
  const client = new Client(handle.port);
  try {
    await client.ready();
    client.send('mmo.hello', { proto: PROTOCOL, name: 'LEAVER' });
    await client.expect('mmo.welcome');

    const closing = handle.close();
    const goodbye = await client.expect('mmo.error', 2000);
    ok(/shutting down/i.test(goodbye.message),
      'a connected client is told the hub is shutting down');
    await closing;
  } finally {
    client.close();
  }
}

// ------- graceful shutdown: SIGTERM against a real child process
//
// The only honest way to exercise signal handling: an in-process start()
// with handleSignals left at its default (true) so the harness's own
// SIGTERM/SIGINT are not the ones under test.

function childHubScript(port) {
  const serverPath = JSON.stringify(SERVER_JS_PATH);
  return [
    "'use strict';",
    `const { start } = require(${serverPath});`,
    'start({',
    '  config: {',
    `    listen: { host: '127.0.0.1', port: ${port} },`,
    '    maxPlayers: 4,',
    '    auth: { required: false, credentials: [] },',
    '    limits: {},',
    '    bans: [],',
    '    allowlist: [],',
    '  },',
    '  log: { debug(){}, info(){}, warn(){}, error(){} },',
    // Same reason startServer() passes it: this scenario is about SIGTERM, and
    // a handshake in front of it would only add a second thing that can fail.
    '  allowUnauthenticated: true,',
    '}).then(() => {',
    "  process.stdout.write('listening\\n');",
    '}).catch((err) => {',
    "  process.stderr.write('start failed: ' + err.message + '\\n');",
    '  process.exit(1);',
    '});',
  ].join('\n');
}

function waitForListening(child, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const cleanup = () => {
      clearTimeout(timer);
      child.stdout.removeListener('data', onData);
      child.removeListener('exit', onExit);
    };
    const onData = (chunk) => {
      if (settled || !String(chunk).includes('listening')) return;
      settled = true;
      cleanup();
      resolve();
    };
    const onExit = (code) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error(`child hub exited early (code ${code})`));
    };
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error('child hub never printed "listening"'));
    }, timeoutMs);
    child.stdout.on('data', onData);
    child.once('exit', onExit);
  });
}

async function gracefulShutdownSigtermTest() {
  const child = spawn(process.execPath, ['-e', childHubScript(CHILD_PORT)],
    { stdio: 'pipe' });
  const stderrChunks = [];
  child.stderr.on('data', (d) => stderrChunks.push(d));

  try {
    await waitForListening(child);

    const client = new Client(CHILD_PORT);
    await client.ready();
    client.send('mmo.hello', { proto: PROTOCOL, name: 'SIGTERMEE' });
    await client.expect('mmo.welcome');

    const exitPromise = new Promise((resolve) => child.once('exit', resolve));
    child.kill('SIGTERM');

    const goodbye = await client.expect('mmo.error', 3000);
    ok(/shutting down/i.test(goodbye.message),
      'SIGTERM produces the same goodbye as an in-process close()');

    const exitCode = await exitPromise;
    ok(exitCode === 0,
      'the process exits cleanly (code 0) after handling SIGTERM: ' +
      Buffer.concat(stderrChunks).toString());

    client.close();
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
}

// =========================================================================
// the authentication throttle
// =========================================================================
//
// A passcode is 2^30 now, not 2^80 (server/lib/auth.js). Per-address limiting
// alone does not defend a number that small -- it tells an attacker how many
// addresses to rent -- so limits.js throttles wrong codes twice: an escalating
// per-address backoff shaped for humans who mistype, and a hub-wide ceiling
// that does not care how many addresses the attacker has. One scenario each,
// and then the one that matters most: what a tripped ceiling is *not* allowed
// to do to the people already playing.

/*
 * limits.js's knobs, scaled to a suite.
 *
 * The shipped values are shaped for a real evening: three free typos, a
 * two-second first backoff doubling to five minutes, a hundred wrong codes a
 * minute before the ceiling trips, and a minute of lockout. Every one of them
 * is set to its floor here, so the same code paths run in tenths of a second
 * and nothing below ever waits out a real lockout.
 */
const THROTTLE_LIMITS = Object.freeze({
  authFailureGrace: 0,        // no free typos: the first wrong code counts
  authFailureWindowMs: 60000,
  authBackoffBaseMs: 1000,    // the first backoff, doubling from there
  authBackoffMaxMs: 2000,
  authGlobalFailures: 6,      // six wrong codes hub-wide trips the ceiling
  authGlobalWindowMs: 60000,
  authLockoutMs: 1000,        // the shortest lockout the schema allows
  // Every socket in these scenarios dials the same loopback address, many
  // times over, and none of that is the subject.
  perIpConnections: 20,
  connectBurst: 200,
  connectPerMinute: 6000,
  maxPending: 32,
});

function startThrottleServer(overrides = {}) {
  return startServer(Object.assign({
    maxPlayers: 4,
    limits: THROTTLE_LIMITS,
    auth: { required: true, credentials: [credential('primary', PRIMARY_CODE)] },
  }, overrides));
}

/*
 * One join attempt, start to finish: hello, the challenge if one comes, the
 * response, and whatever verdict comes back.
 *
 * `challenged` is the fact these scenarios turn on. The relay mints its nonce
 * inside the hello handler, so a refusal that arrives *instead of* a challenge
 * is the throttle speaking, and one that arrives after the response is the
 * credential check. Telling those two apart is the whole point of putting the
 * limiter in front of the nonce rather than behind it.
 */
async function joinAttempt(port, name, code, host) {
  const client = new Client(port, host);
  await client.ready();
  client.send('mmo.hello', { proto: PROTOCOL, name });
  const first = await client.expectEither('mmo.challenge', 'mmo.error');
  if (first.type !== 'mmo.challenge') {
    return { client, verdict: first, challenged: false };
  }
  client.send('mmo.auth', { response: hmacHex(code, first.nonce) });
  const verdict = await client.expectEither('mmo.welcome', 'mmo.error');
  return { client, verdict, challenged: true };
}

/*
 * A second loopback address, where the host has one.
 *
 * The per-address backoff only means anything if a *different* address is
 * shown getting in while one is shut out, and every other socket in this file
 * comes from 127.0.0.1. A dual-stack listener supplies the second one for
 * free: it sees an IPv4 loopback connection as 127.0.0.1 and an IPv6 one as
 * ::1, two genuinely distinct addresses to the limiter, with no interface
 * aliasing and no privileges.
 *
 * A machine with IPv6 switched off simply has no second address, which is not
 * a fact about the hub -- so the scenario asks the limiter the same question
 * directly instead. Same assertion count either way, and the answer is read
 * off the same object the socket path consults one line before it mints a
 * nonce.
 */
let secondLoopbackProbe = null;
function secondLoopback() {
  if (secondLoopbackProbe) return secondLoopbackProbe;
  secondLoopbackProbe = new Promise((resolve) => {
    const server = net.createServer((socket) => socket.destroy());
    const answer = (value) => {
      try { server.close(); } catch (err) { /* it never bound */ }
      resolve(value);
    };
    server.once('error', () => answer(null));
    server.listen(0, '::', () => {
      const probe = net.createConnection({ port: server.address().port, host: '::1' });
      probe.once('error', () => { probe.destroy(); answer(null); });
      probe.once('connect', () => { probe.destroy(); answer('::1'); });
    });
  });
  return secondLoopbackProbe;
}

// ------- wrong codes back one address off, and only that address

async function authBackoffPerAddressTest() {
  const other = await secondLoopback();
  const handle = await startThrottleServer(
    other ? { listen: { host: '::', port: 0 } } : {});
  const port = handle.port;
  const opened = [];

  try {
    // ---- the first wrong code is answered by the credential check
    const typo = await joinAttempt(port, 'TYPO', WRONG_CODE);
    const failedAt = Date.now();
    opened.push(typo.client);
    ok(typo.challenged, 'a first wrong code is challenged like any other attempt');
    ok(/not accepted/i.test(typo.verdict.message),
      'and refused in the ordinary sentence, which names no throttle');

    // ---- the next one never reaches it. The code below is the *right* one:
    // a backed-off address is not being told its code is wrong, it is being
    // told to wait, and that has to be true even when it finally has the code.
    const again = await joinAttempt(port, 'AGAIN', PRIMARY_CODE);
    opened.push(again.client);
    ok(!again.challenged,
      'the next attempt from that address is refused before a nonce is minted');
    ok(/wrong join codes from your address/i.test(again.verdict.message),
      'and told that it is their address that is backed off');
    ok(/try again in/i.test(again.verdict.message),
      'with the one number that answers "so what do I do now"');

    // ---- meanwhile a different address is not throttled at all
    if (other) {
      const elsewhere = await joinAttempt(port, 'ELSEWHERE', PRIMARY_CODE, other);
      opened.push(elsewhere.client);
      ok(elsewhere.verdict.type === 'mmo.welcome',
        'a correct code from a different address still gets in meanwhile');
    } else {
      ok(handle.limits.authAllowed('198.51.100.9').ok,
        'a correct code from a different address still gets in meanwhile');
    }

    // ---- retrying into the closed door does not push the door further shut
    let refused = 0;
    for (let i = 0; i < 3; i++) {
      const retry = await joinAttempt(port, 'RETRY' + i, PRIMARY_CODE);
      opened.push(retry.client);
      if (!retry.challenged) refused += 1;
    }
    ok(refused === 3, 'every retry during the backoff is refused the same way');

    /*
     * ---- and the address recovers on its own schedule.
     *
     * One failure, so the backoff is authBackoffBaseMs (1s above) from the
     * instant of that failure. Had the four refusals since been recorded as
     * failures too, the wait would have doubled to the 2s ceiling and this
     * would still be shut -- which is exactly the collateral limits.js refuses
     * to inflict on an honest player who keeps trying.
     */
    await sleep(Math.max(0, failedAt + 1300 - Date.now()));
    const recovered = await joinAttempt(port, 'RECOVERED', PRIMARY_CODE);
    opened.push(recovered.client);
    ok(recovered.verdict.type === 'mmo.welcome',
      'and the address gets back in once its own backoff elapses, un-extended');
  } finally {
    for (const client of opened) client.close();
    await handle.close();
  }
}

// ------- the hub-wide ceiling: the half that survives a rented botnet

async function authGlobalCeilingTest() {
  const handle = await startThrottleServer();
  const port = handle.port;
  const opened = [];

  try {
    ok(!handle.limits.authLockdown, 'the ceiling starts untripped');

    /*
     * Six wrong codes from six different addresses.
     *
     * Driven through limits.noteAuthFailure -- the exact call lib/server.js's
     * auth port makes on a rejected verify, and nothing else -- because the
     * ceiling's entire premise is an attacker with more addresses than a
     * loopback interface has. Everything the ceiling then *does* is observed
     * below over real sockets, which is the half that could actually be wired
     * up wrong.
     */
    for (let i = 1; i <= 6; i += 1) handle.limits.noteAuthFailure(`203.0.113.${i}`);
    ok(handle.limits.authLockdown,
      'enough failures across enough distinct addresses trip the hub-wide ceiling');

    // 127.0.0.1 has failed nothing, so nothing but the ceiling can refuse it
    const correct = await joinAttempt(port, 'CORRECT', PRIMARY_CODE);
    opened.push(correct.client);
    ok(!correct.challenged,
      'while it is tripped a newcomer is turned away before a nonce is minted');
    ok(correct.verdict.type === 'mmo.error',
      'and a *correct* join code is refused, because the ceiling is not about them');
    ok(/paused new join attempts/i.test(correct.verdict.message),
      'in the hub-wide sentence, which says the hub paused joins');
    ok(!/your address/i.test(correct.verdict.message),
      'and never blames an address that has failed nothing');

    ok(handle.limits.stats().auth.trackedAddresses === 6,
      'a refusal is not recorded as a seventh address failing');

    // ---- and it releases on its own, without a restart
    await sleep(1200); // authLockoutMs is 1000 above
    ok(!handle.limits.authLockdown, 'the ceiling releases when the lockout elapses');
    const after = await joinAttempt(port, 'AFTER', PRIMARY_CODE);
    opened.push(after.client);
    ok(after.verdict.type === 'mmo.welcome',
      'and the correct code works again the moment it does');
  } finally {
    for (const client of opened) client.close();
    await handle.close();
  }
}

// ------- the collateral boundary, which is the point of the whole design
//
// A hub under attack goes temporarily closed to newcomers. It does not go
// down. Everything a tripped ceiling touches is the *authentication* path:
// limits.js never reads a connection record for it, never lists anyone in
// sweep() for it, and never consults it in admit(). This scenario is the
// end-to-end statement of that -- a friend group mid-session must not be able
// to tell that a stranger is grinding passcodes at the door, except by
// reading the host's log.

async function authLockdownSparesConnectedPlayersTest() {
  const handle = await startThrottleServer();
  const port = handle.port;
  const opened = [];

  try {
    // Two friends, in the world, authenticated before anything went wrong.
    const ann = await joinAttempt(port, 'ANN', PRIMARY_CODE);
    const bob = await joinAttempt(port, 'BOB', PRIMARY_CODE);
    opened.push(ann.client, bob.client);
    ok(ann.verdict.type === 'mmo.welcome' && bob.verdict.type === 'mmo.welcome',
      'two players are on the hub before the attack starts');

    // The attack: enough wrong codes, from enough addresses, to trip it.
    for (let i = 1; i <= 6; i += 1) handle.limits.noteAuthFailure(`198.51.100.${i}`);
    ok(handle.limits.authLockdown, 'the hub-wide ceiling is tripped');

    // Nobody was disconnected, and nobody was dropped from the roster.
    ok(handle.relay.playerCount === 2,
      'both players are still on the roster with the ceiling tripped');
    ok(!ann.client.socket.destroyed && !bob.client.socket.destroyed,
      'and neither socket was closed');

    // They can still be heard...
    ann.client.send('mmo.chat', { scope: 'global', text: 'still here' });
    const heard = await bob.client.expect('mmo.chat');
    ok(heard.text === 'still here',
      'a player who authenticated before the ceiling tripped can still send');

    // ...still get answers back...
    bob.client.send('mmo.ping', {});
    await bob.client.expect('mmo.pong');
    ok(true, 'and still gets an answer back from the hub');

    // ...and the world keeps moving for both of them.
    bob.client.send('mmo.move', { map: 'PALLET', x: 4, y: 7, facing: 'left' });
    const moved = await ann.client.expect('mmo.move');
    ok(moved.x === 4 && moved.facing === 'left',
      'and presence keeps flowing between the players who are in it');

    // Meanwhile the door really is shut: this is not a hub where nothing
    // happened, it is a hub that closed to newcomers and kept playing.
    const newcomer = await joinAttempt(port, 'NEWCOMER', PRIMARY_CODE);
    opened.push(newcomer.client);
    ok(newcomer.verdict.type === 'mmo.error',
      'while a newcomer holding the correct code is refused at the door');

    // And refusing them changed nothing for the two who were already in.
    ok(handle.relay.playerCount === 2,
      'which does not disturb the players already on the hub');
    bob.client.send('mmo.chat', { scope: 'global', text: 'after' });
    const stillHeard = await ann.client.expect('mmo.chat');
    ok(stillHeard.text === 'after',
      'and they are still talking to each other afterwards');
  } finally {
    for (const client of opened) client.close();
    await handle.close();
  }
}

// ------- "for both, the pass code is required"
//
// The in-game host refuses to start without a passcode; so does this. The
// configuration a player can walk into is not a malicious one -- it is
// `auth.required: false` left over from a LAN evening, or a hub whose only
// invite quietly expired -- so both are refused by name, and both name the
// command that fixes them rather than arriving as a stack trace.

async function passcodeRequiredTest() {
  // Runs start() and reports the error, or null if the hub came up. A hub that
  // does come up is closed immediately: a scenario about refusing to listen
  // must not leave a listener behind when it is wrong.
  const attempt = async (auth, extra) => {
    let handle = null;
    try {
      handle = await start(Object.assign({
        config: baseConfig({ auth }), log: NULL_LOG, handleSignals: false,
      }, extra));
      return null;
    } catch (err) {
      return err;
    } finally {
      if (handle) await handle.close();
    }
  };

  const off = await attempt({ required: false, credentials: [] });
  ok(off instanceof Error, 'start() refuses a hub with auth.required false');
  ok(/auth\.required is false/.test(off.message),
    'and names the setting that made it an open hub');
  ok(/rby-mmo-hub (init|invite)/.test(off.message),
    'and names the command that fixes it');

  const empty = await attempt({ required: true, credentials: [] });
  ok(empty instanceof Error,
    'and refuses one that requires a join code it does not have');
  ok(/rby-mmo-hub invite/.test(empty.message), 'naming `invite` as the fix');

  const unusable = await attempt({
    required: true,
    credentials: [
      credential('revoked', REVOKED_CODE, { revoked: true }),
      credential('expired', EXPIRED_CODE, {
        expiresAt: new Date(Date.now() - 60000).toISOString(),
      }),
      credential('spent', PRIMARY_CODE, { maxUses: 1, uses: 1 }),
    ],
  });
  ok(unusable instanceof Error,
    'three credentials that are revoked, expired and used up count as none');

  // The opt-out, and only the opt-out, gets past it. This is the option
  // server/hub.js -- the deprecated LAN front door that announces at startup
  // that it has no join code -- is the intended and only caller of.
  const opted = await attempt({ required: false, credentials: [] },
    { allowUnauthenticated: true });
  ok(opted === null, 'allowUnauthenticated: true is the one way past the check');

  const usable = await attempt({
    required: true, credentials: [credential('primary', PRIMARY_CODE)],
  });
  ok(usable === null, 'and a hub with a join code that works starts unremarkably');
}

// =========================================================================
// the status snapshot -- docs/plans/server-side-listing.md §3
// =========================================================================
//
// `players`/`ranking` (server/cli.test.js) read status.json/ranking.json by
// hand, against fixtures -- the contract is the interface, and that suite
// never starts a real hub. This is the other half: proving the hub actually
// writes the file that contract describes, at the moments it describes.
//
// Every scenario here needs a real configPath (statusPath is derived from
// it -- see lib/server.js), unlike startServer()'s ephemeral-port helper
// above, which never sets one at all.

function statusServerConfig(overrides = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rby-mmo-status-test-'));
  const configPath = path.join(dir, 'config.json');
  const cfg = baseConfig(overrides);
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2), { mode: 0o600 });
  return { dir, configPath, cfg };
}

async function startStatusServer(overrides = {}, extra = {}) {
  const { dir, configPath, cfg } = statusServerConfig(overrides);
  const handle = await start(Object.assign({
    config: cfg, log: NULL_LOG, configPath, handleSignals: false,
    allowUnauthenticated: true,
  }, extra));
  return { handle, dir };
}

function readStatus(handle) {
  return JSON.parse(fs.readFileSync(handle.statusPath, 'utf8'));
}

const STATUS_CONTRACT_FIELDS = [
  'name', 'sprite', 'map', 'x', 'y', 'busy', 'party', 'points', 'ranked',
  'admin',  // 0.9.0: which connection holds an admin code -- operator surfaces only
].sort();

async function statusSnapshotCreatedAtStartupTest() {
  const { handle, dir } = await startStatusServer();
  try {
    ok(handle.statusPath === path.join(dir, STATUS_FILENAME),
      'the status snapshot lives beside the config file, named as documented');
    ok(fs.existsSync(handle.statusPath),
      'a snapshot exists the moment the hub is listening, before any player arrives');

    const snapshot = readStatus(handle);
    ok(snapshot.version === 1, 'the snapshot is versioned');
    ok(Array.isArray(snapshot.players) && snapshot.players.length === 0,
      'and starts with an empty roster, not a missing key');
    ok(snapshot.stoppedAt === null, 'a running hub has not stopped');
    ok(snapshot.heartbeatMs === STATUS_HEARTBEAT_MS,
      'the snapshot names its own heartbeat schedule');
    ok(typeof snapshot.startedAt === 'number' && snapshot.startedAt > 0,
      'and timestamps when it started');
    ok(typeof snapshot.updatedAt === 'number' && snapshot.updatedAt > 0,
      'and when this copy was written');

    const mode = fs.statSync(handle.statusPath).mode & 0o777;
    ok(mode === 0o600, 'the file is written 0600, exactly like the ranking');
    ok(!fs.existsSync(`${handle.statusPath}.tmp`),
      'and the temporary file used for the atomic write is not left behind');
  } finally {
    await handle.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function statusUpdatesAfterJoinAndLeaveTest() {
  const { handle, dir } = await startStatusServer({ maxPlayers: 4 });
  const port = handle.port;
  try {
    const client = new Client(port);
    await client.ready();
    client.send('mmo.hello', { proto: PROTOCOL, name: 'JOINER' });
    await client.expect('mmo.welcome');

    // Bounded by the exported heartbeat, not a copied number: whatever the
    // hub's own debounce is, a heartbeat later is a moment the contract
    // guarantees the file is current -- waitFor exits the instant it is.
    const updated = await waitFor(() => {
      try {
        return readStatus(handle).players.length === 1;
      } catch (err) {
        return false;
      }
    }, STATUS_HEARTBEAT_MS);
    ok(updated, 'the snapshot picks up a join within its debounce budget');

    const entry = readStatus(handle).players[0];
    ok(entry.name === 'JOINER', 'and the joined player is the one it names');
    ok(JSON.stringify(Object.keys(entry).sort()) === JSON.stringify(STATUS_CONTRACT_FIELDS),
      `carrying exactly the ${STATUS_CONTRACT_FIELDS.length} contract fields, nothing else`);
    ok(!fs.existsSync(`${handle.statusPath}.tmp`),
      'that write leaves no temporary file behind either');

    client.close();
    const emptied = await waitFor(() => {
      try {
        return readStatus(handle).players.length === 0;
      } catch (err) {
        return false;
      }
    }, STATUS_HEARTBEAT_MS);
    ok(emptied, 'and the roster empties again once the player disconnects');
  } finally {
    await handle.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function statusStoppedAtOnCloseTest() {
  const { handle, dir } = await startStatusServer();
  const port = handle.port;
  try {
    const client = new Client(port);
    await client.ready();
    client.send('mmo.hello', { proto: PROTOCOL, name: 'LEAVER' });
    await client.expect('mmo.welcome');

    await handle.close();

    const snapshot = readStatus(handle);
    ok(typeof snapshot.stoppedAt === 'number' && snapshot.stoppedAt > 0,
      'a clean shutdown records when it stopped');
    ok(Array.isArray(snapshot.players) && snapshot.players.length === 0,
      'and the roster is emptied in the same write, whoever was still connected');
    ok(!fs.existsSync(`${handle.statusPath}.tmp`),
      'the final write leaves no temporary file behind either');

    client.close();
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function statusSnapshotCarriesNothingSensitiveTest() {
  const code = 'NPQR34';
  const { handle, dir } = await startStatusServer({
    auth: { required: true, credentials: [credential('primary', code)] },
  });
  const port = handle.port;
  try {
    const client = new Client(port);
    await client.ready();
    client.send('mmo.hello', { proto: PROTOCOL, name: 'SECRET' });
    const challenge = await client.expect('mmo.challenge');
    client.send('mmo.auth', { response: hmacHex(code, challenge.nonce) });
    await client.expect('mmo.welcome');

    const updated = await waitFor(() => {
      try {
        return readStatus(handle).players.length === 1;
      } catch (err) {
        return false;
      }
    }, STATUS_HEARTBEAT_MS);
    ok(updated, 'the authenticated player reaches the snapshot');

    const raw = fs.readFileSync(handle.statusPath, 'utf8');
    ok(!raw.includes(code), 'the join code used to authenticate never appears in the snapshot');
    ok(!/token/i.test(raw), 'nor any claim-token material');
    ok(!/credential/i.test(raw), 'nor a credential id');

    const entry = readStatus(handle).players[0];
    ok(!('id' in entry) && !('sessionId' in entry) && !('partyId' in entry)
      && !('address' in entry),
      'and the player entry itself carries no client id, session id, party id or address');

    client.close();
  } finally {
    await handle.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// ------- the admin flag on welcome, and in status.json, for a real pair
//
// authHandshakeTest and the throttle scenarios drive real challenge/response
// handshakes, but none of their credentials is an admin one. This scenario
// is the missing combination: two real clients on one hub, one holding an
// admin code and one holding a player code, so `welcome.admin` and the
// status snapshot's per-connection flag are checked against each other
// rather than in isolation.

async function authAdminWelcomeAndStatusTest() {
  const ADMIN_CODE = 'ADMN12';
  const PLAYER_CODE = 'PYQR34';
  const { handle, dir } = await startStatusServer({
    auth: {
      required: true,
      credentials: [
        credential('opadmin', ADMIN_CODE, { admin: true }),
        credential('opplayer', PLAYER_CODE),
      ],
    },
  });
  const port = handle.port;

  try {
    const admin = new Client(port);
    await admin.ready();
    admin.send('mmo.hello', { proto: PROTOCOL, name: 'OPADMIN' });
    const adminChallenge = await admin.expect('mmo.challenge');
    admin.send('mmo.auth', { response: hmacHex(ADMIN_CODE, adminChallenge.nonce) });
    const adminWelcome = await admin.expect('mmo.welcome');
    ok(adminWelcome.admin === true, 'an admin code\'s welcome carries admin: true');

    const player = new Client(port);
    await player.ready();
    player.send('mmo.hello', { proto: PROTOCOL, name: 'OPPLAYER' });
    const playerChallenge = await player.expect('mmo.challenge');
    player.send('mmo.auth', { response: hmacHex(PLAYER_CODE, playerChallenge.nonce) });
    const playerWelcome = await player.expect('mmo.welcome');
    ok(!('admin' in playerWelcome),
      'a sibling client with a player code gets no admin key at all -- absent, not false');

    const settled = await waitFor(() => {
      try {
        const byName = {};
        for (const row of readStatus(handle).players) byName[row.name] = row;
        return byName.OPADMIN && byName.OPADMIN.admin === true &&
          byName.OPPLAYER && byName.OPPLAYER.admin === false;
      } catch (err) {
        return false;
      }
    }, STATUS_HEARTBEAT_MS);
    ok(settled, 'status.json rows carry admin: true for the admin connection ' +
      'and admin: false for the player one');

    admin.close();
    player.close();
  } finally {
    await handle.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// =========================================================================
// wave 2: match history, the admin socket, MOTD reload
// -- docs/plans/server-live-ops.md §3
// =========================================================================
//
// rank.test.js pins the arithmetic and the anti-cheat by driving lib/relay.js
// directly with fake peer handles -- no sockets, no server.js. Nothing in
// this codebase yet drives a *ranked battle to a settlement* over real
// sockets, so playRankedBattle() below is that recipe, built from the wire
// handlers themselves (mmo.request/respond -> mmo.session -> mmo.result):
// two clients, a battle-kind session, and a result each side agrees on.
//
// Everything that needs a real data directory (history.jsonl, admin.sock)
// uses shortTmpDir(): server.js starts an admin socket beside *any*
// configPath now, and a Unix socket path is capped at ~104 bytes on darwin
// -- see the comment on shortTmpDir() above.

/*
 * A full ranked battle, start to finish, over real TCP: hello for both,
 * a battle request/response, the session both sides land in, and a result
 * each of them agrees on. Returns the connected clients (left open, for a
 * caller that wants to keep playing with them -- broadcast and kick both
 * want a live connection to observe) and the welcomes/session id.
 */
async function playRankedBattle(port, winnerName, loserName) {
  const winner = new Client(port);
  const loser = new Client(port);
  await winner.ready();
  await loser.ready();
  winner.send('mmo.hello', { proto: PROTOCOL, name: winnerName });
  loser.send('mmo.hello', { proto: PROTOCOL, name: loserName });
  const winnerWelcome = await winner.expect('mmo.welcome');
  const loserWelcome = await loser.expect('mmo.welcome');

  winner.send('mmo.request', { to: loserWelcome.id, kind: 'battle' });
  await loser.expect('mmo.request');
  loser.send('mmo.respond', { to: winnerWelcome.id, kind: 'battle', accept: true });

  const winnerSession = await winner.expect('mmo.session');
  await loser.expect('mmo.session');

  winner.send('mmo.result', { session: winnerSession.id, outcome: 'win' });
  loser.send('mmo.result', { session: winnerSession.id, outcome: 'loss' });

  // publishPoints() broadcasts one mmo.rank per side, to everyone ready --
  // each of these two included -- so both eventually see at least one.
  await winner.expect('mmo.rank');
  await loser.expect('mmo.rank');

  return { winner, loser, winnerWelcome, loserWelcome, sessionId: winnerSession.id };
}

// One JSON line, matching the fixed contract in the plan exactly: at,
// startedAt, repeats, winner{name,points,gained}, loser{name,points,lost} --
// nothing else on either level.
function assertHistoryRecordShape(record, winnerName, loserName) {
  ok(typeof record.at === 'number' && record.at > 0,
    'the record timestamps when the battle ended');
  ok(typeof record.startedAt === 'number' && record.startedAt > 0,
    'and when it started');
  ok(Object.keys(record).sort().join(',') === 'at,loser,repeats,startedAt,winner',
    'carrying exactly the five contract fields, nothing else');
  ok(record.winner.name === winnerName, 'the winner is named');
  ok(Object.keys(record.winner).sort().join(',') === 'gained,name,points',
    'the winner sub-object carries exactly its three contract fields');
  ok(record.loser.name === loserName, 'the loser is named');
  ok(Object.keys(record.loser).sort().join(',') === 'lost,name,points',
    'and the loser sub-object carries exactly its three');
}

// ------- history.jsonl: appended, 0600, one line per settled ranked battle

async function historyRecordAssertions(handle, winnerName, loserName) {
  ok(handle.historyPath === path.join(path.dirname(handle.configPath), HISTORY_FILENAME),
    'the ledger lives beside the config, named as documented');

  const written = await waitFor(() => {
    try { return fs.readFileSync(handle.historyPath, 'utf8').trim().length > 0; }
    catch (err) { return false; }
  }, 2000);
  ok(written, 'a settled ranked battle is appended to history.jsonl');

  const mode = fs.statSync(handle.historyPath).mode & 0o777;
  ok(mode === 0o600, 'the ledger is created 0600, exactly like the ranking and the snapshot');

  const lines = fs.readFileSync(handle.historyPath, 'utf8').split('\n').filter(Boolean);
  ok(lines.length === 1, 'exactly one line for exactly one settled battle');

  const record = JSON.parse(lines[0]);
  assertHistoryRecordShape(record, winnerName, loserName);
  ok(record.repeats === 0, 'a first meeting between these two names has no repeats');
  ok(record.winner.points === 16 && record.winner.gained === 16,
    'an even first match pays the winner half of RANK_K, the same number rank.test.js pins');
  ok(record.loser.points === 0 && record.loser.lost === 0,
    'and a brand-new loser has nothing to lose in the first place -- points floor at zero');
}

// ------- history.jsonl: rotation to .1 at HISTORY_MAX_BYTES

async function historyRotationTest() {
  const dir = shortTmpDir('rbyhist-');
  const configPath = path.join(dir, 'config.json');
  const cfg = baseConfig({});
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2), { mode: 0o600 });

  const historyPath = path.join(dir, HISTORY_FILENAME);
  const dummyRecord = {
    at: 1, startedAt: 1, repeats: 0,
    winner: { name: 'AAAA', points: 1, gained: 1 },
    loser: { name: 'BBBB', points: 0, lost: 1 },
  };
  const dummyLine = `${JSON.stringify(dummyRecord)}\n`;
  const lineBytes = Buffer.byteLength(dummyLine);
  // Just under the ceiling -- close enough that the next real record (a
  // little over a hundred bytes) is guaranteed to push it over, however its
  // exact length varies with the names and the timestamps involved.
  const target = HISTORY_MAX_BYTES - 60;
  const wholeLines = Math.floor(target / lineBytes);
  const remainder = target - wholeLines * lineBytes;
  const fixture = dummyLine.repeat(wholeLines) + 'F'.repeat(remainder);
  fs.writeFileSync(historyPath, fixture, { mode: 0o600 });
  ok(fs.statSync(historyPath).size === target,
    'the fixture is planted at a precise, known size just under the ceiling');

  const handle = await start({
    config: cfg, log: NULL_LOG, configPath, handleSignals: false, allowUnauthenticated: true,
  });
  const opened = [];
  try {
    ok(handle.historyPath === historyPath, 'the hub found the fixture already in place');

    const battle = await playRankedBattle(handle.port, 'ROTATEW', 'ROTATEL');
    opened.push(battle.winner, battle.loser);

    const rotated = await waitFor(() => fs.existsSync(`${historyPath}.1`), 2000);
    ok(rotated, 'the write that would cross the ceiling rotates the ledger first');

    ok(fs.readFileSync(`${historyPath}.1`, 'utf8') === fixture,
      'the previous generation is renamed intact, byte for byte');

    const freshLines = fs.readFileSync(historyPath, 'utf8').split('\n').filter(Boolean);
    ok(freshLines.length === 1, 'the fresh ledger holds exactly the one new line');
    const record = JSON.parse(freshLines[0]);
    ok(record.winner.name === 'ROTATEW',
      'and it is the battle whose write triggered the rotation');
  } finally {
    for (const client of opened) client.close();
    await handle.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// ------- admin.sock: who / stats / kick / broadcast / malformed / unknown

async function adminAsk(adminPath, payload, timeoutMs = 1500) {
  const client = new Client({ path: adminPath });
  await client.ready();
  client.sendRaw(payload);
  const response = await client.expectAny(timeoutMs);
  client.close();
  return response;
}

async function adminSocketTest(handle, battle) {
  ok(fs.existsSync(handle.adminPath), 'the admin socket file exists once the hub is up');
  const info = fs.lstatSync(handle.adminPath);
  ok(info.isSocket(), 'and it really is a socket, not a stray file');
  ok((info.mode & 0o777) === 0o600, 'restricted to its owner, exactly like the ranking file');

  const who = await adminAsk(handle.adminPath, { cmd: 'who' });
  ok(who.ok === true, 'who answers ok');
  ok(Array.isArray(who.players), 'carrying a players array');
  ok(who.count === who.players.length, 'whose count matches the array length');
  ok(who.players.some((p) => p.name === battle.winnerWelcome.name || p.name === 'RED'),
    'and the roster names the player from the ranked battle above');
  ok(typeof who.maxPlayers === 'number', 'plus the configured player cap');

  const stats = await adminAsk(handle.adminPath, { cmd: 'stats' });
  ok(stats.ok === true, 'stats answers ok');
  ok(stats.stats && typeof stats.stats.limits === 'object',
    'nesting the hardening counters under limits, not merged into the top level');
  ok('auth' in stats.stats.limits,
    'including the authentication throttle telemetry');

  // ---- kick: a connected player is told, then actually disconnected
  const target = new Client(handle.port);
  await target.ready();
  target.send('mmo.hello', { proto: PROTOCOL, name: 'KICKME' });
  await target.expect('mmo.welcome');
  const closed = new Promise((resolve) => target.socket.once('close', () => resolve(true)));

  const kick = await adminAsk(handle.adminPath, { cmd: 'kick', name: 'kickme' });
  ok(kick.ok === true && kick.kicked === 1,
    'kick matches the name case-insensitively and reports exactly one removal');
  ok(Array.isArray(kick.names) && kick.names[0] === 'KICKME',
    'and names who was removed, in the case they actually joined under');

  const goodbye = await target.expect('mmo.error');
  ok(/operator/i.test(goodbye.message), 'the kicked player is told an operator removed them');
  const socketEnded = await Promise.race([closed, sleep(2000).then(() => false)]);
  ok(socketEnded, 'and their socket is actually closed, not just told');
  target.close();

  // ---- broadcast: an ordinary HUB chat line, heard by whoever is connected
  const text = 'Server restarting in five minutes';
  const broadcast = await adminAsk(handle.adminPath, { cmd: 'broadcast', text });
  ok(broadcast.ok === true && broadcast.delivered >= 1,
    'broadcast reports how many players heard it');
  const heard = await battle.winner.expect('mmo.chat');
  ok(heard.name === 'HUB' && heard.scope === 'global' && heard.text === text,
    'and a connected player hears it as an ordinary hub-authored chat line');

  // ---- malformed line / unknown command
  const malformed = await adminAsk(handle.adminPath, 'this is not json at all');
  ok(malformed.ok === false, 'a line that is not JSON is answered, not dropped');

  const unknown = await adminAsk(handle.adminPath, { cmd: 'nonsense' });
  ok(unknown.ok === false, 'an unrecognised command is refused rather than guessed at');
}

// ------- admin.sock: stale-socket recovery, a non-socket squatter, and
// close() actually removing the file

function staleSocketHelperScript(socketPath) {
  return [
    "'use strict';",
    "const net = require('net');",
    'const s = net.createServer();',
    `s.listen(${JSON.stringify(socketPath)}, () => { process.stdout.write('up\\n'); });`,
  ].join('\n');
}

/*
 * Leaves a socket file at `socketPath` with nobody listening behind it --
 * the shape a crashed hub leaves, and the one admin.js's bind() recovery
 * (EADDRINUSE -> lstat -> isSocket -> unlink -> retry) exists for.
 *
 * SIGKILL, not close(): a graceful close() on this platform unlinks the file
 * itself (verified by hand against this Node), which would leave nothing
 * stale to recover from. A killed process is the honest way to reproduce it.
 */
function plantStaleSocket(socketPath) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['-e', staleSocketHelperScript(socketPath)],
      { stdio: ['ignore', 'pipe', 'inherit'] });
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error('the stale-socket helper never came up'));
    }, 3000);
    child.stdout.on('data', (chunk) => {
      if (!String(chunk).includes('up')) return;
      clearTimeout(timer);
      child.kill('SIGKILL');
      setTimeout(resolve, 200);
    });
  });
}

async function adminStaleSocketRecoveryTest() {
  const dir = shortTmpDir('rbyad1-');
  const configPath = path.join(dir, 'config.json');
  const cfg = baseConfig({});
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2), { mode: 0o600 });
  const adminPath = path.join(dir, ADMIN_SOCKET_FILENAME);

  await plantStaleSocket(adminPath);
  ok(fs.existsSync(adminPath), 'the stale socket file from the crashed helper is still there');

  const handle = await start({
    config: cfg, log: NULL_LOG, configPath, handleSignals: false, allowUnauthenticated: true,
  });
  try {
    ok(handle.adminPath === adminPath, 'the hub found the same path the stale socket occupied');
    const who = await adminAsk(adminPath, { cmd: 'who' });
    ok(who.ok === true,
      'a stale socket left by a crashed hub is recovered, not mistaken for a live one');
  } finally {
    await handle.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function adminNonSocketFileTest() {
  const dir = shortTmpDir('rbyad2-');
  const configPath = path.join(dir, 'config.json');
  const cfg = baseConfig({});
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2), { mode: 0o600 });
  const adminPath = path.join(dir, ADMIN_SOCKET_FILENAME);
  fs.writeFileSync(adminPath, 'not a socket, just a file\n');

  const log = recordingLog();
  const handle = await start({
    config: cfg, log, configPath, handleSignals: false, allowUnauthenticated: true,
  });
  try {
    ok(handle.port > 0, 'a plain file squatting the admin path does not stop the hub itself');
    ok(fs.readFileSync(adminPath, 'utf8') === 'not a socket, just a file\n',
      'this module will not delete a file it did not create');
    ok(log.saw(/admin socket did not start/i),
      'the admin socket is reported missing, in the log, rather than silently absent');

    const dialed = await new Promise((resolve) => {
      const socket = net.createConnection({ path: adminPath });
      socket.once('error', () => resolve(true));
      socket.once('connect', () => { socket.destroy(); resolve(false); });
    });
    ok(dialed, 'and nothing is actually listening at that path');
  } finally {
    await handle.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function adminCloseUnlinksSocketTest() {
  const dir = shortTmpDir('rbyad3-');
  const configPath = path.join(dir, 'config.json');
  const cfg = baseConfig({});
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2), { mode: 0o600 });
  const adminPath = path.join(dir, ADMIN_SOCKET_FILENAME);

  const handle = await start({
    config: cfg, log: NULL_LOG, configPath, handleSignals: false, allowUnauthenticated: true,
  });
  try {
    ok(fs.lstatSync(adminPath).isSocket(), 'the socket exists while the hub is up');
  } finally {
    await handle.close();
  }
  ok(!fs.existsSync(adminPath), 'and close() removes it');
  fs.rmSync(dir, { recursive: true, force: true });
}

// ------- the shared hub: history, admin, and MOTD reload together
//
// One hub, walked through all three in sequence, per plan §5/T2's own
// instruction to share a hub across these where isolation allows. Only the
// rotation test above needs a ledger pre-sized to the byte, which is not
// something a shared hub's history could offer once other scenarios have
// already written to it -- so that one keeps its own directory.

async function operatorFeaturesTest() {
  const dir = shortTmpDir('rbyops-');
  const configPath = path.join(dir, 'config.json');
  const cfg = baseConfig({ motd: '' });
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2), { mode: 0o600 });

  const handle = await start({
    config: cfg, log: NULL_LOG, configPath, handleSignals: false, allowUnauthenticated: true,
  });
  const opened = [];
  try {
    // ---- MOTD: absent before anyone edits the config
    const before = new Client(handle.port);
    opened.push(before);
    await before.ready();
    before.send('mmo.hello', { proto: PROTOCOL, name: 'FIRSTIN' });
    const beforeWelcome = await before.expect('mmo.welcome');
    ok(!('motd' in beforeWelcome), 'a hub started with no MOTD sends no motd field at all');

    // ---- match history: a real ranked battle over real sockets
    const battle = await playRankedBattle(handle.port, 'RED', 'BLUE');
    opened.push(battle.winner, battle.loser);
    await historyRecordAssertions(handle, 'RED', 'BLUE');

    // ---- the admin socket
    await adminSocketTest(handle, battle);

    // ---- MOTD: a SIGHUP-equivalent reload() picks up an edit, without
    // touching the player already connected
    const updatedConfig = Object.assign({}, cfg, {
      motd: 'Welcome trainers! Read the rules.',
    });
    fs.writeFileSync(configPath, JSON.stringify(updatedConfig, null, 2), { mode: 0o600 });
    const reloaded = handle.reload();
    ok(reloaded === true, 'reload() re-reads the file and reports success');

    const after = new Client(handle.port);
    opened.push(after);
    await after.ready();
    after.send('mmo.hello', { proto: PROTOCOL, name: 'SECONDIN' });
    const afterWelcome = await after.expect('mmo.welcome');
    ok(afterWelcome.motd === 'Welcome trainers! Read the rules.',
      'a client that joins after the reload gets the new MOTD, cleaned and verbatim');

    ok(!('motd' in beforeWelcome),
      'and the welcome the first client already received carries nothing retroactively');
    before.send('mmo.ping', {});
    await before.expect('mmo.pong');
    ok(true, 'the first client is still connected and entirely unaffected by the reload');
  } finally {
    for (const client of opened) client.close();
    await handle.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// =========================================================================
// driver
// =========================================================================

async function main() {
  await authHandshakeTest();
  await authOffTest();
  await silentSocketsDoNotLockOutTest();
  await capFilledByGreetedPlayersTest();
  await capHoldsWhenEveryoneGreetsBeforeAnswering();
  await perIpCapTest();
  await banTest();
  await handshakeTimeoutTest();
  await inviteUsesPersistTest();
  await inviteUsesNoWriteWithoutConfigPathTest();
  await authBackoffPerAddressTest();
  await authGlobalCeilingTest();
  await authLockdownSparesConnectedPlayersTest();
  await passcodeRequiredTest();
  await sighupReloadTest();
  await shutdownHookTest();
  await gracefulShutdownInProcessTest();
  await gracefulShutdownSigtermTest();
  await statusSnapshotCreatedAtStartupTest();
  await statusUpdatesAfterJoinAndLeaveTest();
  await statusStoppedAtOnCloseTest();
  await statusSnapshotCarriesNothingSensitiveTest();
  await authAdminWelcomeAndStatusTest();

  await historyRotationTest();
  await adminStaleSocketRecoveryTest();
  await adminNonSocketFileTest();
  await adminCloseUnlinksSocketTest();
  await operatorFeaturesTest();

  console.log(`\n  ${passed}/${passed} checks passed  (server)\n`);
}

main().catch((err) => {
  console.error('\n  ' + (err && err.stack || err) + '\n');
  process.exit(1);
});
