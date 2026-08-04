'use strict';

/*
 * The socket layer, and only the socket layer.
 *
 * Everything that decides *anything* already lives somewhere else: the
 * protocol in lib/relay.js, the hardening in lib/limits.js, the crypto in
 * lib/auth.js, the file in lib/config.js. This module owns the one thing
 * none of them may touch -- a real net.Server -- and hands them the bytes.
 *
 * Keeping the split that strict is what makes the hub testable at all. The
 * relay is driven by peer handles, so a suite can pair two of them in memory
 * and never bind a port; the limits are pure bookkeeping over an injected
 * clock, so an hour of idleness costs a test nothing. Reintroducing a policy
 * decision down here would quietly move it back out of reach of both.
 *
 * Three behaviours below are deliberate and easy to mistake for oversights:
 *
 *  - **A seat is charged at hello, not at accept** (plan §3.6). Ungreeted
 *    sockets are bounded by limits.maxPending and reaped by
 *    limits.handshakeTimeoutMs instead, so four silent sockets can no longer
 *    lock everyone out of a four-player hub the way hub.js:369 allowed. The
 *    one courtesy exception is spelled out at its call site.
 *  - **Registered sockets carry no timers of their own**, only the ~1 s
 *    sweep. Per-socket timers were how the old hub conflated "has not
 *    finished its handshake" with "has said nothing for a while", which are
 *    different failures with different budgets. The two exceptions are
 *    sockets nobody is keeping -- the one-second forced-close budget on
 *    shutdown, and the quarter-second a refusal gets to reach the wire --
 *    where there is exactly one budget and nothing to conflate it with.
 *  - **A rejected connection is destroyed without a reply when the rejection
 *    is a flood signal**, and answered in one sentence when it is not. Bytes
 *    spent on a flooder are the attack; bytes spent on an honest friend
 *    behind the same NAT are the whole point of having a message at all.
 *  - **The authentication throttle is asked before a nonce is minted, and
 *    told only about genuine credential rejections.** Both halves matter: a
 *    refusal that got recorded as a failure would let an honest player extend
 *    their own backoff by retrying, and a check that ran after the challenge
 *    was sent would not be a throttle at all. What a tripped hub-wide ceiling
 *    must *not* do is touch anybody already playing; see the call site.
 *
 * No dependencies: node:net plus this directory.
 */

const fs = require('node:fs');
const net = require('node:net');
const process = require('node:process');

const path = require('node:path');

const { Relay, parseLine } = require('./relay.js');
const { Board } = require('./rank.js');
const { Limits, normalizeIp } = require('./limits.js');
const {
  save: saveConfig,
  validate: validateConfig,
  migrate: migrateConfig,
} = require('./config.js');
const auth = require('./auth.js');
const { createLog, safe } = require('./log.js');

// The ceiling on a single unterminated line, unchanged from hub.js:34. A
// peer that buffers more than this without a newline is not sending a
// message, and the buffer is charged to the host's memory either way.
const MAX_LINE = 64 * 1024;

// How often the sweep asks limits.js who has run out of time. A second is
// far finer than any of the budgets it enforces (the shortest is ten
// seconds) and coarse enough that an idle hub does no measurable work.
const SWEEP_INTERVAL_MS = 1000;

// How long a goodbye gets to reach the wire before the socket is taken away.
// A peer that never closes its own half would otherwise leave server.close()
// waiting forever; hub.js:459 has always drawn that line at one second.
const FORCE_CLOSE_MS = 1000;

// Headroom over the app-level caps for the libuv-level backstop: sockets
// mid-refusal, and the gap between a peer disappearing and the close event
// arriving, are both real and neither should be able to make the backstop
// fire before the checks that produce a sentence do.
const CONNECTION_SLACK = 8;

// How long a run of successful logins is allowed to accumulate before the
// use counts reach the disk. Long enough that a party of eight arriving at
// once costs one write; short enough that a kill -9 loses at most a second
// of counting.
const CREDENTIAL_SAVE_INTERVAL_MS = 1000;

// The leaderboard file, beside config.json, and how long a run of battles
// may accumulate before it reaches the disk.
//
// A file of its own rather than a section of config.json, for two reasons
// that both come down to ownership: config.json is a file a *host* edits and
// the CLI rewrites wholesale (`invite`, `ban`), so a hub writing ratings
// into it would race the host's own edits; and ratings are state, not
// configuration -- deleting this file resets the season and changes nothing
// about how the hub runs. Same debounce as the credential counts, and for
// the same reason: a player must never be waiting on a filesystem.
const RANKING_FILENAME = 'ranking.json';
const RANKING_SAVE_INTERVAL_MS = 1000;

// How long a refused socket may sit between its goodbye and its destruction.
// It is invisible to limits.js on purpose (charging a refusal would let a
// flooder fill the table it was just refused by), but it is *not* invisible to
// libuv: it counts against server.maxConnections until it is gone. Leaving
// that to the 1 s sweep let a second's worth of refusals push the backstop
// over, and the backstop cannot produce a sentence. A quarter second is far
// longer than one short line needs and four times less residency.
const FAREWELL_MS = 250;

// How long close() waits on the caller's onShutdown hook before giving up on
// it. The hook's job is to undo something outside this process -- a UPnP
// mapping on a router that may simply not answer -- and a router that does not
// answer must not be able to wedge Ctrl-C.
const SHUTDOWN_HOOK_MS = 2000;

// A rejection that is a flood signal costs the sender nothing but the
// SYN. A rejection an honest player could plausibly hit gets a sentence,
// because the client already renders mmo.error (src/Client.lua:463-467) and
// a friend behind the same NAT as three other friends deserves to know why.
function refusalFor(reason, limits) {
  switch (reason) {
    case 'per_ip':
      return `Too many connections from your address ` +
        `(${limits.perIpConnections}).`;
    case 'pending':
      return 'This hub is busy letting other players in; try again in a moment.';
    case 'not_allowed':
      // Not silent, unlike a ban: the common case is not a stranger but a
      // friend whose address moved, and a scanner learns nothing here it
      // did not already learn by finding the port open.
      return 'This hub only accepts connections from addresses its host has allowed.';
    default:
      return null; // 'banned', 'rate' -- answered with silence
  }
}

// "3 seconds", "1 second". A throttled player is being told how long to wait,
// and a sentence that says "1 seconds" reads like a bug in the hub they are
// already unhappy with.
function seconds(ms) {
  const whole = Math.max(1, Math.ceil(ms / 1000));
  return whole === 1 ? '1 second' : `${whole} seconds`;
}

/*
 * The two sentences a throttled join attempt gets, and they are deliberately
 * different.
 *
 * `auth_lockdown` is about the hub: the hub-wide ceiling has tripped, so
 * *nobody* is being authenticated for a moment, and a player holding the
 * right code is being turned away through no fault of their own. Telling
 * them "your code was wrong too many times" there would be a lie they would
 * act on -- by re-reading a code that is perfectly good.
 *
 * `auth_backoff` is about them: this address has produced wrong codes, and
 * the fix is to check the code before trying again.
 *
 * Neither names a credential, a count or a threshold. The wait is the one
 * number worth giving, because it is the only one that answers "so what do I
 * do now".
 */
function authRefusalFor(reason, retryAfterMs) {
  if (reason === 'auth_lockdown') {
    return 'This hub has paused new join attempts for a moment: too many wrong ' +
      `join codes have been tried on it. Try again in ${seconds(retryAfterMs)}. ` +
      'Players already on the hub are unaffected.';
  }
  return 'Too many wrong join codes from your address. Check the code with ' +
    `whoever is hosting, then try again in ${seconds(retryAfterMs)}.`;
}

// --------------------------------------------------- the door has to be locked
//
// The owner's instruction, for both hosting paths: the passcode is required.
// The in-game host refuses to start without one; so does this.

/*
 * Would this configuration admit anyone who found the port? Returns the
 * sentence to fail with, or null when the door has a lock on it.
 *
 * Two ways in, and a player can walk into either without meaning to:
 * `auth.required` off, and `auth.required` on with nothing behind it -- every
 * credential revoked, expired, spent, or never minted. The second is the one
 * worth catching by hand, because it *looks* configured.
 *
 * Both name the command that fixes them. A hub that will not start is only a
 * good outcome if the host learns what to type next.
 */
function openDoorRefusal(config) {
  const settings = (config && config.auth) || {};
  if (!settings.required) {
    return 'this hub would let in anyone who finds the port: auth.required is ' +
      'false. Run `rby-mmo-hub init` to write a config with a join code in it, ' +
      'or `rby-mmo-hub invite` to add one to the config you already have.';
  }
  if (auth.activeCredentials(settings.credentials).length === 0) {
    return 'this hub requires a join code and has none that still works -- ' +
      'every credential is missing, revoked, expired or used up -- so nobody ' +
      'could join it. Run `rby-mmo-hub invite` to mint one.';
  }
  return null;
}

/*
 * The auth port the relay expects: null, or exactly newNonce() and
 * verify(nonce, response). The relay knows the shape of the handshake and
 * nothing about the cryptography behind it, which is what lets a suite drive
 * the challenge with a stub.
 *
 * Null when auth is off, rather than a port that admits everyone -- with no
 * port at all the exchange is byte-identical to the one hub.js has always
 * spoken, so a LAN game gains no round trip it did not ask for.
 *
 * This is also the only place in the program that learns an authentication
 * actually succeeded, so it is where a use count is charged. `invite --uses
 * 1` has to mean one use: a limit that is offered and quietly does nothing is
 * worse than one that was never offered, because the host stops watching the
 * door on the strength of it.
 *
 * The count is charged against the live credential object, which is the same
 * one auth.activeCredentials() filters on the next connection -- so a
 * credential that has just spent its last use is already inactive by the time
 * the next peer answers a challenge, with no separate re-check to keep in
 * step. Persistence is somebody else's tick; see noteCredentialUse().
 *
 * **The credential list is read on every verify, never captured.** Whether
 * auth is required at all is a bind-time fact -- the relay is handed a port or
 * null once -- but *which codes open the door* is a security decision a host
 * has to be able to change while friends are mid-session, so reload() (SIGHUP)
 * replaces config.auth.credentials in place and the very next challenge is
 * judged against the new list.
 */
function authPort(config, onUse, throttle) {
  const settings = (config && config.auth) || {};
  if (!settings.required) return null;
  const liveCredentials = () => {
    const current = config && config.auth && config.auth.credentials;
    return Array.isArray(current) ? current : [];
  };
  return {
    newNonce() {
      return auth.newNonce();
    },
    verify(nonce, response) {
      const credentials = liveCredentials();
      const verdict = auth.verify(nonce, response, credentials);
      /*
       * The one place in the program that learns a *passcode was wrong*, as
       * opposed to "this connection did not become a player" -- which is a
       * far larger set: a peer that answered a stale challenge, one the
       * throttle turned away before a nonce was minted, one whose socket died
       * mid-handshake. Only a rejection from here is a guess at the code, so
       * only a rejection from here is charged to the address that made it.
       */
      if (!verdict || !verdict.ok) {
        throttle.failed();
        return verdict;
      }
      throttle.passed();

      const used = credentials.find(
        (credential) => credential && credential.id === verdict.credentialId);
      if (used) {
        used.uses = (Number(used.uses) || 0) + 1;
        onUse(used);
      }
      return verdict;
    },
  };
}

// config.js accepts 'silent' as a log level; log.js knows four levels and
// reads anything else as 'info'. Rather than let a host who asked for
// silence get chatter, silence is spelled here as a stream that discards --
// the level vocabulary belongs to config.js and the writing to log.js, and
// neither should have to learn the other's spelling.
const NULL_STREAM = { write() {} };

function logFor(config) {
  const level = (config && config.log && config.log.level) || 'info';
  if (level === 'silent') return createLog({ level: 'error', stream: NULL_STREAM });
  return createLog({ level });
}

/**
 * Bind a hub to a port.
 *
 * Resolves to { port, host, close(), reload(), relay, limits, stats() } once the
 * listener is up, and rejects if it never comes up -- so a caller can report
 * "address already in use" as the one thing that actually went wrong rather
 * than as a stack trace.
 *
 * `handleSignals` defaults to true, which is what a process whose whole job
 * is the hub wants. An embedded caller -- a suite starting three hubs in one
 * process -- passes false, so stopping one of them does not hijack SIGINT
 * for the rest. It also arms SIGHUP, which re-reads the config file and
 * re-applies the three things that are security decisions rather than
 * bind-time parameters; see reload().
 *
 * `onShutdown` is an optional async function belonging to the caller --
 * today, the CLI's UPnP unmap. close() **awaits it before resolving**,
 * bounded by SHUTDOWN_HOOK_MS, and never lets it reject: the signal handler
 * exits only once close() resolves, so a hook that hangs would otherwise be a
 * hub that will not stop. It runs at most once per start().
 *
 * The config is put through config.validate() here rather than trusted.
 * `hub.js` and the CLI both validate before calling, so for the shipped paths
 * this changes nothing (validate is idempotent and never throws) -- but start()
 * is this package's main, and an embedding caller must not be able to reach
 * authPort's "no auth section means admit everyone" branch by passing a
 * half-built object.
 *
 * **A hub that would admit anyone does not start.** `auth.required` off, or on
 * with no credential that still works, is refused here with a sentence naming
 * the command that fixes it -- see openDoorRefusal(). `allowUnauthenticated:
 * true` is the one way past it, and it exists for exactly one caller: the
 * legacy `hub.js` shim, which passes it explicitly and says out loud at
 * startup that it has no join code. Anything else that sets it is making the
 * same choice deliberately and in writing, which is the whole difference
 * between a decision and an accident.
 */
function start(options = {}) {
  const opts = options || {};
  const given = opts.config || {};

  // Asked before validate() fills it in from the defaults. An absent auth
  // section is not a decision, it is a gap, and the defaults resolve it the
  // safe way (required) rather than the convenient one.
  const authWasMissing = !given || typeof given.auth !== 'object' ||
    given.auth === null || Array.isArray(given.auth);

  /*
   * Port 0 is not a config-file value, it is the programmatic "ask the OS for
   * a free port" that every in-process suite binds on. config.js's range is
   * 1..65535 and rightly so -- a host who types 0 into config.json meant
   * something else -- so the ephemeral case is carried around validate()
   * rather than clamped to port 1, which is what a caller passing 0 would
   * otherwise get, complete with EACCES.
   */
  const ephemeralPort = Boolean(given.listen) && Number(given.listen.port) === 0;
  const checked = validateConfig(ephemeralPort
    ? Object.assign({}, given, {
      listen: Object.assign({}, given.listen, { port: undefined }),
    })
    : given);
  const config = checked.config;
  if (ephemeralPort) config.listen.port = 0;

  const listen = config.listen || {};
  const log = opts.log || logFor(config);
  const configPath = opts.configPath || null;
  const handleSignals = opts.handleSignals !== false;
  const onShutdown = typeof opts.onShutdown === 'function' ? opts.onShutdown : null;

  const unauthenticatedAllowed = opts.allowUnauthenticated === true;

  for (const warning of checked.warnings) log.warn(`config: ${warning}`);
  if (authWasMissing) {
    log.warn('config: no auth section was given, so this hub is defaulting to ' +
      `requiring a join code and has none -- nobody can join. Pass ` +
      `auth.credentials from \`rby-mmo-hub invite\`, or auth: { required: ` +
      `false } together with allowUnauthenticated: true if this really is an ` +
      'open hub on a trusted LAN.');
  }

  if (!unauthenticatedAllowed) {
    const refusal = openDoorRefusal(config);
    if (refusal) {
      /*
       * Rejected, not thrown. Every caller in this package reaches start()
       * through .then/.catch -- bin/rby-mmo-hub.js turns a rejection into
       * "The hub failed to start: <sentence>", hub.js into "hub failed to
       * start: <sentence>" -- and a synchronous throw would reach both of
       * them as a stack trace instead, which is precisely the outcome this
       * check exists to avoid. Nothing has been allocated yet, so there is
       * nothing to unwind: no listener, no limits, no relay, no handlers.
       */
      return Promise.reject(new Error(refusal));
    }
  }

  const limits = new Limits(config.limits || {});
  limits.setBans(config.bans);
  limits.setAllowlist(config.allowlist);

  /*
   * The address whose line the relay is processing right now, or null.
   *
   * The auth port relay.js calls back into is handed a nonce and a response
   * and nothing else -- that port contract is relay.js's, and relay.js is not
   * this module's file to widen. But the throttle is *per address*, so the
   * address has to reach it somehow.
   *
   * It rides as a call-scoped parameter. `relay.handle()` is synchronous end
   * to end -- it parses, dispatches and writes without ever yielding -- and
   * node runs one of them at a time, so between the assignment below and the
   * `finally` that clears it there is exactly one connection in flight and
   * this is its address. It is not shared mutable state; it is an argument
   * with nowhere else to ride.
   */
  let activeAddress = null;

  /*
   * What the auth port tells the throttle. Two calls, both about the *result
   * of a credential check* and nothing else -- see authPort's verify().
   */
  const authThrottle = {
    failed() {
      // No connection in flight means the port is being driven directly (a
      // suite with a stub). There is no address to charge, and inventing one
      // would put a fictional entry in a table that decides who gets in.
      if (!activeAddress) return;
      // The return value is the *edge*: true only on the failure that trips
      // the hub-wide ceiling, so this says so once rather than once per
      // attempt for the whole lockout. Neither the code nor the response is
      // ever logged -- the point of a challenge is that they do not leak.
      if (limits.noteAuthFailure(activeAddress)) {
        log.warn('too many wrong join codes across this hub ' +
          `(${limits.authGlobalFailures} within ` +
          `${Math.round(limits.authGlobalWindowMs / 1000)}s): new join attempts ` +
          `are refused for the next ${seconds(limits.authLockoutMs)}. Players ` +
          'already connected are not affected and stay in the game.');
      }
    },
    passed() {
      if (!activeAddress) return;
      limits.noteAuthSuccess(activeAddress);
    },
  };

  /*
   * The season, loaded from beside the config file.
   *
   * A hub that forgot every rating when it restarted would not be a ranking,
   * so this is read once at start and written back (debounced) whenever a
   * battle moves somebody. A file that is missing is a fresh season, which
   * is the ordinary first run; a file that is corrupt is *named* and then
   * treated as a fresh season, because refusing to start would take a whole
   * hub off the air over a leaderboard.
   */
  const rankingPath = configPath
    ? path.join(path.dirname(configPath), RANKING_FILENAME) : null;
  const board = new Board();
  if (rankingPath) {
    try {
      const raw = JSON.parse(fs.readFileSync(rankingPath, 'utf8'));
      board.import(Array.isArray(raw) ? raw : raw && raw.players);
      log.info(`loaded ${board.export().length} ranked player(s) from ` +
        `${safe(rankingPath)}`);
    } catch (err) {
      if (err && err.code !== 'ENOENT') {
        log.error(`could not read ${safe(rankingPath)} (${safe(err.message)}); ` +
          'starting from an empty ranking. Move the file aside if you want to ' +
          'keep it, or delete it to silence this.');
      }
    }
  }

  const relay = new Relay({
    maxPlayers: config.maxPlayers,
    chatIntervalMs: config.limits && config.limits.chatIntervalMs,
    board,
    onRankChange: () => noteRankChange(),
    // Not a config.json setting: `protocol` is an embedding/test seam the
    // schema deliberately does not know about, so it is read from the object
    // as given rather than from the validated copy validate() pruned it out of.
    protocol: given.protocol,
    auth: authPort(config, noteCredentialUse, authThrottle),
    log,
  });

  /** Registered sockets, so shutdown can reach the ones that will not leave. */
  const sockets = new Set();
  /*
   * Sockets refused before they were ever registered. They are invisible to
   * limits.js by design -- charging a refusal would let a flooder fill the
   * table it was just refused by -- so they are parked here and destroyed
   * FAREWELL_MS after their goodbye, whether or not the peer ever read it.
   * Shutdown reaches them through this set too, and so does the sweep, which
   * stays as the belt to the timer's braces.
   */
  const farewells = new Set();

  const startedAt = Date.now();
  // What the listener actually got, which is not always what was asked for
  // (port 0, or a host the OS spelled differently). Filled in on bind; read by
  // reload() and stats(), both of which only run after that.
  let boundHost = null;
  let boundPort = null;
  let closePromise = null;
  let stopping = false;
  let creditTimer = null;
  let creditsDirty = false;
  let rankTimer = null;
  let rankDirty = false;

  // -------------------------------------------------------- use counting

  /*
   * A credential was just spent. The count is already correct in memory --
   * that happened in authPort, on the connection's own path -- and all that
   * is left is getting it onto the disk.
   *
   * Deferred and coalesced, because config.save() is a synchronous
   * write-and-rename and a player waiting on a challenge must never be
   * waiting on a filesystem. A party of eight arriving together costs one
   * write, and the timer is unref'd so a use count can never be the reason
   * the process stays up. close() flushes, so an orderly shutdown loses
   * nothing.
   *
   * **While it runs, the hub is the writer of record for `uses`.** A
   * concurrent `rby-mmo-hub invite` reads the file, adds a credential and
   * writes the whole thing back, so it can overwrite counts the hub charged
   * in the seconds before -- the losing direction is always *undercounting*,
   * never admitting on a code that is spent or revoked, because the CLI's
   * copy of a revoked credential is still revoked. That is the right trade
   * against locking the file on the hot path; a host who wants an exact
   * count stops the hub first.
   */
  function noteCredentialUse() {
    // No file, nothing to persist to. This is the hub.js shim's world: no
    // config, no credentials, and nothing that outlives the process.
    if (!configPath) return;
    creditsDirty = true;
    if (creditTimer) return;
    creditTimer = setTimeout(flushCredentials, CREDENTIAL_SAVE_INTERVAL_MS);
    creditTimer.unref();
  }

  function flushCredentials() {
    if (creditTimer) {
      clearTimeout(creditTimer);
      creditTimer = null;
    }
    if (!creditsDirty || !configPath) return;
    creditsDirty = false;
    try {
      saveConfig(configPath, config);
    } catch (err) {
      // A full disk, a read-only mount, a volume that went away. None of
      // those are a reason to stop letting friends in -- the in-memory count
      // is still authoritative for this run, so the limit still holds; it
      // just will not survive a restart.
      log.error(`could not record credential use in ${safe(configPath)}: ` +
        `${safe(err.message)}`);
    }
  }

  // ------------------------------------------------------------ the season

  /*
   * A battle moved somebody's rating. The board is already correct in
   * memory -- that happened on the connection's own path, inside the relay
   * -- and all that is left is getting it onto the disk, which is deferred
   * and coalesced for the same reason the credential counts are: a tournament
   * running through a hub must never be waiting on a filesystem. The timer
   * is unref'd, so a pending write can never be why the process stays up, and
   * close() flushes so an orderly shutdown loses nothing.
   */
  function noteRankChange() {
    if (!rankingPath) return;      // an embedded hub keeps its season in RAM
    rankDirty = true;
    if (rankTimer) return;
    rankTimer = setTimeout(flushRanking, RANKING_SAVE_INTERVAL_MS);
    rankTimer.unref();
  }

  function flushRanking() {
    if (rankTimer) {
      clearTimeout(rankTimer);
      rankTimer = null;
    }
    if (!rankDirty || !rankingPath) return;
    rankDirty = false;
    try {
      // Written whole and then renamed over the old file, so a hub killed
      // mid-write leaves the previous season intact rather than half a JSON
      // document that will not parse on the way back up.
      const temporary = `${rankingPath}.tmp`;
      fs.writeFileSync(temporary,
        `${JSON.stringify({ version: 1, players: board.export() }, null, 2)}\n`,
        { mode: 0o600 });
      fs.renameSync(temporary, rankingPath);
    } catch (err) {
      // A full disk, a read-only mount, a volume that went away. None of
      // those is a reason to stop scoring battles: the board in memory is
      // still authoritative for this run, it just will not survive a restart.
      log.error(`could not save the ranking to ${safe(rankingPath)}: ` +
        `${safe(err.message)}`);
    }
  }

  // ------------------------------------------------------------ refusals

  function farewell(socket, message) {
    // A peer can vanish between accept and this write; that is its problem,
    // not the hub's, and it must not reach the connection listener as a throw.
    socket.on('error', () => {});

    /*
     * A budget of its own, rather than the next sweep.
     *
     * A refused socket is invisible to limits.js but not to libuv: it counts
     * against server.maxConnections until it is destroyed, and that ceiling is
     * only maxPlayers + maxPending + slack. Leaving these to the 1 s sweep let
     * a second's worth of refusals push the backstop over -- and the backstop
     * destroys connections silently, ahead of every check that could produce a
     * sentence. FAREWELL_MS is four times less residency for the same courtesy.
     *
     * Not the flush callback, deliberately: destroying the instant the write
     * drains would land while the peer's own hello is still arriving unread,
     * and a destroy with unread data queued is an RST -- which is exactly how
     * a peer loses the sentence this whole path exists to deliver.
     */
    let timer = null;
    socket.on('close', () => {
      if (timer) clearTimeout(timer);
      timer = null;
      farewells.delete(socket);
    });

    try {
      socket.end(JSON.stringify({ type: 'mmo.error', message }) + '\n');
      farewells.add(socket);
      timer = setTimeout(() => {
        timer = null;
        farewells.delete(socket);
        socket.destroy();
      }, FAREWELL_MS);
      // Never a reason to keep the process alive: the goodbye is a courtesy,
      // and a hub with nothing else left to do should still exit.
      timer.unref();
    } catch (err) {
      socket.destroy();
    }
  }

  // ---------------------------------------------------------- connections

  function onConnection(socket) {
    const ip = normalizeIp(socket.remoteAddress);

    const verdict = limits.admit(ip);
    if (!verdict.ok) {
      const message = refusalFor(verdict.reason, limits);
      log.debug(`refused ${safe(ip)}: ${verdict.reason}`);
      if (message === null) return socket.destroy();
      return farewell(socket, message);
    }

    /*
     * The one place a connection is turned away before it has said anything.
     *
     * This is safe precisely because isFull() counts *greeted players*: a
     * silent socket is not a player and cannot make this true, so the
     * lock-out §3.6 exists to fix cannot happen through it. What it buys is
     * that someone arriving at a genuinely full hub is told so now instead
     * of after a handshake nobody has room for -- which is both the better
     * experience and the sentence hub.js has always sent here.
     */
    if (relay.isFull()) {
      return farewell(socket, `This hub is full (${relay.maxPlayers} players).`);
    }

    limits.register(socket, ip);
    sockets.add(socket);

    socket.setNoDelay(true);
    socket.setEncoding('utf8');

    const peer = {
      remoteAddress: ip,
      send(message) {
        if (socket.destroyed) return;
        /*
         * hub.js:130 called socket.write() and discarded the boolean, so a
         * peer that connected and never read grew the hub's write buffer
         * without bound while looking, from outside, like a healthy player.
         * The buffer is the hazard, so the buffer is what is judged.
         */
        if (!limits.writeAllowed(socket, socket.writableLength)) {
          log.warn(`dropping ${safe(ip)}: ${socket.writableLength} bytes queued, ` +
            `over the ${limits.maxWriteBufferBytes} byte ceiling`);
          socket.destroy();
          return;
        }
        // May throw on a message that will not serialise; the relay catches
        // that and spends the connection rather than the hub.
        socket.write(JSON.stringify(message) + '\n');
      },
      close() {
        socket.end();
      },
    };

    const id = relay.accept(peer);
    let greeted = false;
    let buffer = '';

    socket.on('data', (chunk) => {
      buffer += chunk;
      const completedLine = buffer.indexOf('\n') >= 0;
      // Two clocks, not one: "is this peer alive" and "has it finished a
      // sentence since it started one". The second is what catches a client
      // dribbling a byte a minute under both the buffer cap and the idle
      // timeout.
      limits.noteActivity(socket, { bytes: chunk.length, completedLine });

      if (buffer.length > MAX_LINE) {
        const client = relay.get(id);
        if (client) relay.refuse(client, 'Message too long.');
        else socket.destroy();
        return;
      }

      let index;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (!line) continue;

        const msg = parseLine(line);
        if (!msg) continue; // a malformed line is dropped, never fatal

        /*
         * The authentication throttle, and the only place this module reads a
         * message type.
         *
         * It has to be asked on the path that would *mint a nonce*, and that
         * path is relay.js's `mmo.hello` handler -- so either this check sits
         * inside relay.js, or it sits in front of the call that reaches it.
         * In front is the better of the two even ignoring file ownership: the
         * relay's refusal for a nonce it could not issue is one generic
         * sentence, and `auth_lockdown` and `auth_backoff` are two different
         * situations that deserve two different things said to the player.
         *
         * `greeted` is the guard against charging the gate twice: an already
         * admitted player's stray hello is a no-op inside the relay and must
         * not be read as a fresh attempt to authenticate.
         *
         * Answered in a sentence rather than destroyed in silence, unlike the
         * flood refusals at the top of this file. The population here is not
         * the same: a lockdown turns away everyone including the friend who
         * has the right code, and a backoff is most often somebody who read a
         * character wrong. The connect-rate bucket already bounds how often
         * either of them can arrive, so the sentence costs one short line per
         * connection an attacker was going to be allowed to make anyway.
         */
        if (relay.auth && msg.type === 'mmo.hello' && !relay.greeted(id)) {
          const attempt = limits.authAllowed(ip);
          if (!attempt.ok) {
            // Refused, and deliberately *not* recorded as a failure: retrying
            // into a closed door is not a guess at the code, and counting it
            // would let an honest player extend their own backoff forever.
            log.debug(`refused a join attempt from ${safe(ip)}: ${attempt.reason}`);
            const client = relay.get(id);
            const message = authRefusalFor(attempt.reason, limits.authRetryAfterMs(ip));
            if (client) relay.refuse(client, message);
            else socket.destroy();
            return;
          }
        }

        // See `activeAddress`: the address rides here, scoped to this one
        // synchronous dispatch, because the auth port has no parameter for it.
        activeAddress = ip;
        try {
          relay.handle(id, msg);
        } finally {
          activeAddress = null;
        }

        /*
         * The seam for "the handshake is over". relay.js exposes no event
         * for it and should not grow one for the socket layer's benefit --
         * greeted(id) is the same fact, asked rather than announced, and it
         * covers both doors into ready: straight from hello on an open hub,
         * and from a passing mmo.auth on one that challenges.
         */
        if (!greeted && relay.greeted(id)) {
          greeted = true;
          limits.markGreeted(socket);
        }
      }
    });

    // Both fire for a socket that errors, which is the normal case rather
    // than the exotic one; both sides of this are idempotent for exactly
    // that reason.
    const done = () => {
      sockets.delete(socket);
      limits.release(socket);
      relay.drop(id);
    };
    socket.on('error', done);
    socket.on('close', done);
  }

  const server = net.createServer(onConnection);

  // The libuv-level backstop, underneath every check above. It cannot
  // produce a sentence, so it is set high enough that the checks that can
  // are always the ones that fire first.
  server.maxConnections = relay.maxPlayers + limits.maxPending + CONNECTION_SLACK;

  // ---------------------------------------------------------------- sweep

  const sweeper = setInterval(() => {
    for (const doomed of limits.sweep()) {
      log.debug(`closing a connection: ${doomed.reason}`);
      doomed.key.destroy();
    }
    for (const socket of farewells) socket.destroy();
    farewells.clear();
  }, SWEEP_INTERVAL_MS);
  // An unref'd interval never keeps the process alive on its own account,
  // so the hub still exits the moment the listener and its sockets are gone.
  sweeper.unref();

  // --------------------------------------------------------------- reload

  /*
   * SIGHUP: re-read the file and re-apply the decisions in it that are about
   * *who may be here*, without touching the ones that are about *what is
   * bound*.
   *
   * A host who revokes a leaked join code, bans someone mid-session or tightens
   * an allowlist is doing it because something is happening right now. Until
   * this existed, none of the three took effect until the hub was restarted --
   * which means dropping everyone mid-battle to eject one person, so in
   * practice it meant the change did not happen at all.
   *
   * Exactly three things are re-applied: auth.credentials, bans, allowlist.
   *
   * Not the port, the bind address or the player cap. Those cannot change
   * under a live listener -- and a reload that silently ignored a host's edit
   * to `listen.port` while claiming to have reloaded the file would be worse
   * than not offering a reload at all. They are named in the log instead, so
   * the answer to "why is it still on the old port" is on screen rather than
   * inferred.
   *
   * A reload that cannot be completed changes nothing. Config files are edited
   * in place and read at an arbitrary instant, so half a file is a normal
   * thing to meet; a hub that reacted to one by emptying its ban list would
   * hold its own door open because someone was mid-save.
   */
  function reload() {
    if (!configPath) {
      log.warn('reload: this hub was started without a config file, so there ' +
        'is nothing to re-read. Start it through bin/rby-mmo-hub.js for a ' +
        'hub whose credentials, bans and allowlist can be reloaded.');
      return false;
    }

    let raw;
    try {
      raw = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    } catch (err) {
      log.error(`reload: could not read ${safe(configPath)} ` +
        `(${safe(err.message)}); keeping the credentials, bans and allowlist ` +
        'already in force. Fix the file and send SIGHUP again.');
      return false;
    }
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      log.error(`reload: ${safe(configPath)} is not a JSON object; keeping the ` +
        'credentials, bans and allowlist already in force.');
      return false;
    }

    const migrated = migrateConfig(raw);
    const fresh = validateConfig(migrated.raw);
    for (const warning of migrated.warnings) log.warn(`reload: ${safe(warning)}`);
    for (const warning of fresh.warnings) log.warn(`reload: ${safe(warning)}`);
    const next = fresh.config;

    // In place, not by rebinding `config`: authPort reads config.auth.credentials
    // on every verify, and flushCredentials writes this same object back.
    config.auth.credentials = next.auth.credentials;
    config.bans = next.bans;
    config.allowlist = next.allowlist;
    limits.setBans(config.bans);
    limits.setAllowlist(config.allowlist);

    const total = config.auth.credentials.length;
    const usable = auth.activeCredentials(config.auth.credentials).length;
    log.info(`reloaded ${safe(configPath)}: ${total} join code(s), ${usable} ` +
      `usable; ${config.bans.length} ban(s); ` +
      `${config.allowlist.length} allowlist entr(y/ies)`);

    if (Boolean(next.auth.required) !== Boolean(relay.auth)) {
      log.warn(`reload: auth.required is now ${next.auth.required} but this hub ` +
        `is running with it ${relay.auth ? 'on' : 'off'}; that one takes a restart.`);
    }
    const portMoved = !ephemeralPort && Number(next.listen.port) !== boundPort;
    if (portMoved || next.listen.host !== host ||
        Number(next.maxPlayers) !== relay.maxPlayers) {
      log.warn('reload: listen.host, listen.port and maxPlayers were not ' +
        're-applied -- they cannot change under a live listener. This hub is ' +
        `still ${boundHost}:${boundPort} for ${relay.maxPlayers} players ` +
        'until it is restarted.');
    }
    return true;
  }

  // ------------------------------------------------------------- shutdown

  /*
   * The caller's own teardown -- today the CLI's UPnP unmap, which has to
   * finish before the process goes or the port stays forwarded on the router
   * after every Ctrl-C (plan §3.7). Awaited, at most once, and bounded: a
   * router that does not answer must not be able to wedge shutdown.
   */
  function runShutdownHook() {
    if (!onShutdown) return Promise.resolve();
    return new Promise((resolve) => {
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve();
      };
      // Not unref'd: this is the one timer whose whole job is to be waited on.
      // An unref'd one would let the process exit out from under the hook,
      // which is the bug this hook exists to fix.
      const timer = setTimeout(() => {
        log.warn(`shutdown hook did not finish within ${SHUTDOWN_HOOK_MS}ms; ` +
          'stopping anyway.');
        finish();
      }, SHUTDOWN_HOOK_MS);

      try {
        Promise.resolve(onShutdown()).then(finish, (err) => {
          log.error(`shutdown hook failed: ` +
            `${safe(err && err.message ? err.message : err)}`);
          finish();
        });
      } catch (err) {
        log.error(`shutdown hook failed: ${safe(err && err.message ? err.message : err)}`);
        finish();
      }
    });
  }

  function close() {
    if (closePromise) return closePromise;
    clearInterval(sweeper);
    detach();
    // Before anything else: a use charged in the last second is a use, and
    // losing it on a clean shutdown would hand a spent invite back out. The
    // same goes for a battle somebody won a moment ago.
    flushCredentials();
    flushRanking();

    // Started here rather than after the sockets are gone: undoing a port
    // mapping and saying goodbye to the players are independent, and shutdown
    // should cost max(the two budgets), not their sum. Nothing below depends
    // on it, and it cannot reject.
    const hookDone = runShutdownHook();

    const socketsDone = new Promise((resolve) => {
      let forced = null;
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        if (forced) clearTimeout(forced);
        resolve();
      };

      // Stop accepting first, so nobody joins a hub that is leaving, and
      // only then say goodbye -- in that order the players still on the wire
      // actually receive it. There is no host migration, so saying so is the
      // honest thing rather than leaving clients talking to a dead listener.
      server.close(finish);
      relay.shutdown();
      for (const socket of farewells) socket.destroy();
      farewells.clear();

      forced = setTimeout(() => {
        for (const socket of sockets) socket.destroy();
        sockets.clear();
        finish();
      }, FORCE_CLOSE_MS);
      forced.unref();
    });

    closePromise = Promise.all([socketsDone, hookDone]).then(() => undefined);
    return closePromise;
  }

  // ---------------------------------------------------- process handlers

  const onSignal = () => {
    if (stopping) return; // a second ^C must not race the first one's exit
    stopping = true;
    log.info('shutting down');
    const exit = () => process.exit(0);
    close().then(exit, exit);
  };

  /*
   * SIGHUP is the conventional "re-read your config" signal, and it is the
   * only one a host can send while friends are connected without ending their
   * session. Guarded by the same handleSignals opt-in as the rest: a suite
   * running three hubs in one process must not have one of them answering for
   * the others.
   */
  const onHangup = () => {
    if (stopping) return;
    log.info('SIGHUP: re-reading the config');
    reload();
  };

  /*
   * One bad code path must not end everyone's session. A hub is a thing
   * friends are in the middle of using; a crash costs them a battle, a trade
   * and a reconnect the client cannot even do for them
   * (src/Transport.lua:163). Logging and carrying on is strictly better than
   * dying, and every path that can actually corrupt state already spends its
   * own connection rather than the process.
   */
  const onUncaught = (err) => {
    log.error(`uncaught error, continuing: ${safe(err && err.message ? err.message : err)}`);
  };
  const onUnhandled = (reason) => {
    log.error(`unhandled rejection, continuing: ` +
      `${safe(reason && reason.message ? reason.message : reason)}`);
  };

  function attach() {
    if (!handleSignals) return;
    process.on('SIGINT', onSignal);
    process.on('SIGTERM', onSignal);
    process.on('SIGHUP', onHangup);
    process.on('uncaughtException', onUncaught);
    process.on('unhandledRejection', onUnhandled);
  }

  function detach() {
    if (!handleSignals) return;
    process.removeListener('SIGINT', onSignal);
    process.removeListener('SIGTERM', onSignal);
    process.removeListener('SIGHUP', onHangup);
    process.removeListener('uncaughtException', onUncaught);
    process.removeListener('unhandledRejection', onUnhandled);
  }

  // --------------------------------------------------------------- listen

  const host = typeof listen.host === 'string' && listen.host
    ? listen.host : '0.0.0.0';
  const port = Number(listen.port);

  return new Promise((resolve, reject) => {
    const onListenError = (err) => {
      clearInterval(sweeper);
      detach();
      reject(err);
    };
    server.once('error', onListenError);

    server.listen(port, host, () => {
      server.removeListener('error', onListenError);
      // After the bind, an error is something that happened to one accept
      // (EMFILE, ECONNABORTED), not a reason to take the hub away from the
      // players already on it.
      server.on('error', (err) => log.error(`listener error: ${safe(err.message)}`));

      const address = server.address();
      boundHost = address && address.address ? address.address : host;
      boundPort = address && address.port ? address.port : port;

      attach();
      log.info(`RBY MMO hub listening on ${boundHost}:${boundPort} ` +
        `(protocol ${relay.protocol})`);

      resolve({
        host: boundHost,
        port: boundPort,
        configPath,
        // where the season is kept, so a caller (the CLI, a suite) can say
        // which file it is talking about rather than re-deriving the path
        rankingPath,
        relay,
        limits,
        close,
        // The same thing SIGHUP does, for a caller that has no signal to send
        // (an embedder, a suite). Returns whether the file was re-read.
        reload,
        // The shape the CLI's `status` verb prints. Derived on every call so
        // it can never be a stale copy of the thing it is describing.
        stats() {
          const counts = limits.stats();
          return {
            host: boundHost,
            port: boundPort,
            protocol: relay.protocol,
            maxPlayers: relay.maxPlayers,
            players: relay.playerCount,
            pending: relay.pendingCount,
            connections: counts.connections,
            perIp: counts.perIp,
            authRequired: Boolean(relay.auth),
            startedAt,
            uptimeMs: Date.now() - startedAt,
          };
        },
      });
    });
  });
}

module.exports = { start, MAX_LINE, SWEEP_INTERVAL_MS };
