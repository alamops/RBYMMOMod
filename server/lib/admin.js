'use strict';

/*
 * The operator's door: a Unix socket beside config.json.
 *
 * `status.json` already lets a short-lived process (`rby-mmo-hub players`)
 * read the hub without a live channel into it, and that is the right shape
 * for a question. It is the wrong shape for an instruction: nobody can kick
 * a player or say something to everyone by reading a file. This module is
 * the other half -- a socket the running hub answers on, carrying the four
 * things an operator needs from a hub that is already up: who, stats, kick,
 * broadcast.
 *
 * **The trust model is filesystem permissions, and there is deliberately no
 * in-band auth** (plan §8.4). The socket is created inside the data
 * directory, which the CLI keeps at 0700, so the umask and the directory
 * mode are the whole boundary: a process that can open this socket can
 * already read config.json, which holds every join code the hub honours.
 * Adding a password here would protect nothing that is not already lost, and
 * would put a second secret in the same file as the first. On the Docker
 * side the same reasoning is what puts the socket in `/data` rather than
 * `/tmp`: the volume is shared with `docker compose exec`, the container's
 * tmpfs is not.
 *
 * One exchange per connection -- request line in, response line out, socket
 * ended by the hub. No sessions, no server-initiated frames, nothing to
 * resynchronise after a partial write; a CLI verb that dials, writes a line
 * and reads to EOF is the whole client. That also makes the request cap easy
 * to state and easy to defend: a line longer than MAX_REQUEST_BYTES is not a
 * command, and the connection is spent saying so.
 *
 * Nothing here may throw into the hub. This process is other people's game;
 * a malformed line, a peer that vanishes mid-answer, or a relay call that
 * fails must all end as a logged line and, where a socket is still there to
 * hear it, an `{"ok":false}` sentence naming what to do instead.
 *
 * No dependencies: node:net, node:fs, and this directory.
 */

const fs = require('node:fs');
const net = require('node:net');

const { createLog, safe } = require('./log.js');

// The ceiling on one request line. Every command this speaks is a verb and
// at most a short string; four kilobytes is orders of magnitude of headroom
// over the longest honest one, and small enough that a peer dribbling bytes
// with no newline is bounded to something the host never notices.
const MAX_REQUEST_BYTES = 4096;

// How long a connection may hold an fd without completing its exchange. The
// caller is a local CLI verb that writes its line immediately, so this is
// not a budget any honest client comes near -- it exists so a process that
// connects and then wanders off cannot accumulate descriptors on a hub that
// has no other way to notice.
const EXCHANGE_TIMEOUT_MS = 10000;

// The outer budget: how long a connection may exist at all, counted from
// accept and never extended. The idle timeout above is cleared the moment a
// reply starts, so that one alone leaves a peer which asks and then never
// reads holding a descriptor for as long as it likes. This is the one clock
// nothing resets -- generous enough that no local exchange is ever cut short,
// finite so an fd cannot be parked here.
const EXCHANGE_DEADLINE_MS = 60000;

// How many connections may be open at once. Each one is a request line and a
// reply; there is no honest reason for more than a handful, and a cap means a
// script that dials in a loop is refused at accept rather than left to grow
// the hub's descriptor table.
const MAX_CONNECTIONS = 16;

// The commands, named once so the "unknown command" sentence cannot drift
// away from what the dispatch table actually answers.
const COMMANDS = ['who', 'stats', 'kick', 'broadcast'];

// A value that arrived over the socket and is about to be quoted back to
// whoever sent it. Bounded, because the sentence is the point and not a
// faithful echo of however many bytes were spent on the mistake. JSON's own
// escaping handles the rest -- the response goes out through JSON.stringify,
// so a control byte in here becomes an escape, never a forged line.
function shortValue(value) {
  try {
    return String(value).slice(0, 32);
  } catch (err) {
    return '?';
  }
}

function fail(error) {
  return { ok: false, error };
}

/*
 * The four answers.
 *
 * Each one is a pure function of the injected dependencies, so a suite can
 * drive the whole vocabulary with three stubs and never bind a socket. The
 * two mutating verbs are the only place this module reaches into the relay,
 * and both check the method is there first: `kick` and `broadcast` are newer
 * than the socket protocol they ride on, and an operator pointed at a hub
 * too old to have them deserves that sentence rather than a stack trace.
 */
function handleWho(deps) {
  const players = deps.relay.roster();
  const snapshot = deps.stats() || {};
  return {
    ok: true,
    players,
    // Not snapshot.players: stats() spends that name on the *count* while
    // this response spends it on the roster, so taking the count from the
    // roster we are already returning is the one derivation that cannot
    // disagree with itself.
    count: Array.isArray(players) ? players.length : 0,
    maxPlayers: snapshot.maxPlayers === undefined
      ? deps.relay.maxPlayers : snapshot.maxPlayers,
    uptimeMs: snapshot.uptimeMs === undefined ? null : snapshot.uptimeMs,
  };
}

function handleStats(deps) {
  const snapshot = deps.stats() || {};
  // The hardening counters are live in-process telemetry that reaches no
  // file, so this socket is the only way to see them from outside. Nested
  // under `limits` rather than merged, so a future field on either side
  // cannot silently shadow the other's.
  return { ok: true, stats: Object.assign({}, snapshot, { limits: deps.limits.stats() }) };
}

function handleKick(request, deps) {
  if (typeof deps.relay.kickByName !== 'function') return fail('This hub cannot kick.');

  if (typeof request.name !== 'string') {
    return fail('kick needs a "name": the trainer name to remove.');
  }
  const name = request.name.trim();
  if (!name) return fail('kick needs a "name": the trainer name to remove.');

  if (request.reason !== undefined && request.reason !== null &&
      typeof request.reason !== 'string') {
    return fail('kick\'s "reason" must be a string, or left out for the default.');
  }
  const reason = typeof request.reason === 'string' ? request.reason : undefined;

  // The relay owns the matching rule (case-insensitive, by the board's key)
  // and the count, because names are unique only among ranked players and
  // one instruction may therefore land on nobody or on several people.
  const result = deps.relay.kickByName(name, reason) || {};
  const names = Array.isArray(result.names) ? result.names : [];
  const kicked = Number.isFinite(result.kicked) ? result.kicked : names.length;
  deps.log.info(`admin: kick ${safe(name)} removed ${kicked} ` +
    `${kicked === 1 ? 'player' : 'players'}`);
  return { ok: true, kicked, names };
}

function handleBroadcast(request, deps) {
  if (typeof deps.relay.announce !== 'function') return fail('This hub cannot broadcast.');

  if (typeof request.text !== 'string') {
    return fail('broadcast needs a "text": the line to send to everyone.');
  }
  if (!request.text.trim()) {
    return fail('broadcast needs a "text": the line to send to everyone.');
  }

  // Cleaning and the length cap belong to the relay, which already applies
  // exactly the charset every other chat line is held to. It may still
  // refuse a line that is empty once cleaned -- punctuation the charset
  // strips, say -- and a delivered count of zero is the honest report of it.
  const result = deps.relay.announce(request.text) || {};
  const delivered = Number.isFinite(result.delivered) ? result.delivered : 0;
  deps.log.info(`admin: broadcast reached ${delivered} ` +
    `${delivered === 1 ? 'player' : 'players'}`);
  return { ok: true, delivered };
}

/*
 * One request line to one response object. Never throws: a dependency that
 * fails is a logged error and a sentence, because the alternative is a
 * connection that hangs until the peer gives up on a hub that is otherwise
 * perfectly healthy.
 */
function answer(line, deps) {
  let request;
  try {
    request = JSON.parse(line);
  } catch (err) {
    return fail('That was not JSON. The admin socket takes one JSON object per line.');
  }

  if (!request || typeof request !== 'object' || Array.isArray(request)) {
    return fail('That JSON was not an object. Send {"cmd":"who"} and the like.');
  }
  if (typeof request.cmd !== 'string' || !request.cmd) {
    return fail(`Missing "cmd". This hub answers ${COMMANDS.join(', ')}.`);
  }

  const cmd = request.cmd;
  if (!COMMANDS.includes(cmd)) {
    return fail(`Unknown command "${shortValue(cmd)}". ` +
      `This hub answers ${COMMANDS.join(', ')}.`);
  }

  try {
    if (cmd === 'who') return handleWho(deps);
    if (cmd === 'stats') return handleStats(deps);
    if (cmd === 'kick') return handleKick(request, deps);
    return handleBroadcast(request, deps);
  } catch (err) {
    deps.log.error(`admin: ${safe(cmd)} failed: ` +
      `${safe(err && err.message ? err.message : err)}`);
    return fail(`This hub could not answer "${shortValue(cmd)}"; ` +
      'the hub log has the reason.');
  }
}

/*
 * Bind, with the one recovery a Unix socket needs.
 *
 * Node does not remove the socket file when the process dies, and bind()
 * against a path that already exists is EADDRINUSE whether or not anything
 * is listening on it -- so a hub that was killed rather than stopped would
 * otherwise never get its admin channel back. The recovery is deliberately
 * narrow: stat the path, and only unlink it *if it is a socket*, once. A
 * regular file at that path is somebody's data and this module will not
 * delete it to make room for itself; it says what is in the way and stops.
 *
 * The residual hazard is a second hub started against the same data
 * directory, which will take this socket from the first. That is the same
 * hazard ranking.json and status.json already carry -- one data directory is
 * one hub -- and it is worth less than a hub that needs a manual `rm` after
 * every crash.
 */
function bind(server, socketPath, log, mayRetry) {
  return new Promise((resolve, reject) => {
    const onError = (err) => {
      server.removeListener('error', onError);

      if (!mayRetry || !err || err.code !== 'EADDRINUSE') return reject(err);

      let info = null;
      try {
        // lstat, not stat: the question is what is *at* this path. A symlink
        // pointing somewhere that happens to be a socket would answer yes to
        // stat, and unlinking it would be this hub deleting a link somebody
        // else put here to reach a socket of their own.
        info = fs.lstatSync(socketPath);
      } catch (statErr) {
        info = null;
      }

      if (info && !info.isSocket()) {
        return reject(new Error(`${socketPath} is in the way and is not a ` +
          'socket. Move or delete that file yourself and start the hub again; ' +
          'this hub will not remove a file it did not create.'));
      }

      if (info) {
        let removed = true;
        try {
          fs.unlinkSync(socketPath);
        } catch (unlinkErr) {
          // ENOENT is the state this was trying to reach: something else --
          // another hub's shutdown, a host with a shell open -- got there
          // between the lstat and here, and the bind can simply proceed.
          if (!unlinkErr || unlinkErr.code !== 'ENOENT') {
            return reject(new Error(`${socketPath} is a leftover socket that ` +
              `could not be removed (${unlinkErr.message}). Delete it and start ` +
              'the hub again.'));
          }
          removed = false;
        }
        if (removed) log.info(`admin: removed a leftover socket at ${safe(socketPath)}`);
      }

      resolve(bind(server, socketPath, log, false));
    };

    server.once('error', onError);
    server.listen(socketPath, () => {
      server.removeListener('error', onError);
      /*
       * The socket enforces its own boundary.
       *
       * The header above promises the trust model is filesystem permissions,
       * and inside the container that is the 0700 data directory. Outside it
       * the directory may be older than this hub, or made by hand, or made
       * under a loose umask -- and the socket is created under that umask
       * too. 0600 says the thing the trust model already assumed: the owner
       * gets the verbs, nobody else does.
       *
       * A chmod that fails is not a reason to take the channel away -- the
       * caller only warns, so rejecting here would leave a bound socket with
       * no one watching it. It is a reason to say so loudly.
       */
      try {
        if (process.platform !== 'win32') fs.chmodSync(socketPath, 0o600);
      } catch (modeErr) {
        log.warn(`admin: could not restrict ${safe(socketPath)} to its owner ` +
          `(${safe(modeErr.message)}); anyone who can open that path can kick ` +
          'players and broadcast. Put the socket in a directory only you can ' +
          'enter (chmod 700) and restart the hub.');
      }
      resolve();
    });
  });
}

/*
 * start({ path, relay, stats, limits, log }) -> Promise<{ path, close() }>
 *
 * Promise-shaped like server.start(), and for the same reason: a bind either
 * happened or it did not, and a caller that has to wire a teardown wants to
 * know which before it continues. `stats` is the zero-argument function off
 * the server handle; `limits` is the Limits instance (only .stats() is used).
 */
function start(options = {}) {
  const socketPath = options.path;
  const relay = options.relay;
  const log = options.log || createLog();

  if (typeof socketPath !== 'string' || !socketPath) {
    return Promise.reject(new Error('admin.start needs a path for its socket.'));
  }
  if (!relay || typeof relay.roster !== 'function') {
    return Promise.reject(new Error('admin.start needs the relay it should report on.'));
  }
  if (typeof options.stats !== 'function') {
    return Promise.reject(new Error('admin.start needs a stats() function.'));
  }
  if (!options.limits || typeof options.limits.stats !== 'function') {
    return Promise.reject(new Error('admin.start needs the limits it should report on.'));
  }

  const deps = { relay, stats: options.stats, limits: options.limits, log };
  const sockets = new Set();
  let closePromise = null;

  const server = net.createServer((socket) => {
    sockets.add(socket);

    let chunks = Buffer.alloc(0);
    let spent = false;

    // A peer that goes away mid-exchange is an ordinary event on a socket
    // nobody is keeping, and must never reach the connection listener as a
    // throw. Debug, not warn: it is the operator's own terminal, and a
    // Ctrl-C in the middle of a `who` is not a hub problem.
    socket.on('error', (err) => {
      log.debug(`admin: connection error: ${safe(err && err.message ? err.message : err)}`);
    });
    socket.setTimeout(EXCHANGE_TIMEOUT_MS, () => {
      log.debug('admin: a connection said nothing in time and was dropped');
      socket.destroy();
    });

    // The idle clock above stops when the reply starts; this one does not
    // stop for anything but the close that ends the exchange, so a peer that
    // sends its line and then never reads the answer cannot hold a descriptor
    // open indefinitely. Unref'd: a deadline must never be the reason a
    // process stays alive.
    const deadline = setTimeout(() => {
      log.debug('admin: a connection outlived its deadline and was dropped');
      socket.destroy();
    }, EXCHANGE_DEADLINE_MS);
    if (typeof deadline.unref === 'function') deadline.unref();

    socket.on('close', () => {
      clearTimeout(deadline);
      sockets.delete(socket);
    });

    const reply = (payload) => {
      if (spent) return;
      spent = true;
      // The idle budget was about a peer that never asked; this one has, and
      // a slow reader must not have its own answer destroyed out from under
      // it at the ten-second mark.
      socket.setTimeout(0);
      try {
        // end(), not write(): one exchange per connection, and the EOF is
        // how the caller knows the response is whole without counting bytes.
        socket.end(JSON.stringify(payload) + '\n');
      } catch (err) {
        log.debug('admin: a reply could not be sent; the peer is gone');
        socket.destroy();
      }
    };

    socket.on('data', (chunk) => {
      if (spent) return;
      chunks = Buffer.concat([chunks, chunk]);

      const newline = chunks.indexOf(0x0a);
      if (newline >= 0 && newline <= MAX_REQUEST_BYTES) {
        return reply(answer(chunks.slice(0, newline).toString('utf8'), deps));
      }
      if (newline > MAX_REQUEST_BYTES || chunks.length > MAX_REQUEST_BYTES) {
        log.debug(`admin: a request line was over ${MAX_REQUEST_BYTES} bytes`);
        return reply(fail(`That request was over ${MAX_REQUEST_BYTES} bytes. ` +
          'The admin socket takes one short command per connection.'));
      }
    });

    // A caller that half-closes without a trailing newline still meant its
    // bytes as a request; answering them is friendlier than a silence the
    // peer would have to time out of, and cannot be confused with anything
    // else because the connection is over either way.
    socket.on('end', () => {
      if (spent) return;
      if (!chunks.length) return reply(fail('No command was sent.'));
      reply(answer(chunks.toString('utf8'), deps));
    });
  });

  server.maxConnections = MAX_CONNECTIONS;

  function removeSocketFile() {
    // Node unlinks the path on a graceful close, so this is usually a
    // no-op -- and is here for the case where it is not (a close that raced
    // an unlink, a path already cleaned up by hand). Its absence is the
    // desired state, never an error.
    try {
      fs.unlinkSync(socketPath);
    } catch (err) {
      if (err && err.code !== 'ENOENT') {
        log.warn(`admin: could not remove ${safe(socketPath)}: ${safe(err.message)}; ` +
          'delete it before starting the hub again.');
      }
    }
  }

  function close() {
    if (closePromise) return closePromise;
    closePromise = new Promise((resolve) => {
      // An exchange is a few hundred bytes and a few microseconds, but a
      // peer that connected and never spoke would hold server.close() open
      // for as long as it liked. Nobody is mid-anything worth waiting for.
      for (const socket of sockets) socket.destroy();
      sockets.clear();
      server.close(() => {
        removeSocketFile();
        resolve();
      });
    });
    return closePromise;
  }

  return bind(server, socketPath, log, true).then(() => {
    // After the bind, an error is something that happened to one accept, not
    // a reason to take the admin channel -- let alone the hub -- away.
    // Attached here rather than at construction so the EADDRINUSE that the
    // stale-socket recovery above expects, handles and recovers from is not
    // also logged as a hub error nobody needs to read.
    server.on('error', (err) => {
      log.error(`admin: listener error: ${safe(err && err.message ? err.message : err)}`);
    });

    log.info(`admin socket listening at ${safe(socketPath)}`);
    return { path: socketPath, close };
  });
}

// MAX_REQUEST_BYTES is exported for the same reason the server's budgets
// are: a suite (or a CLI verb) that has an opinion about the cap should name
// the one number rather than carry a copy of it.
module.exports = {
  start,
  MAX_REQUEST_BYTES,
  EXCHANGE_TIMEOUT_MS,
  EXCHANGE_DEADLINE_MS,
  MAX_CONNECTIONS,
  COMMANDS,
};
