'use strict';

/*
 * The hosting software: the one place a host configures anything.
 *
 * The rule this file exists to keep is simple and absolute -- **no setting is
 * reachable only by hand-editing JSON**. Every knob in config.js has a verb
 * here, every list has an add and a remove, and the two things that must never
 * be edited as text (join codes, bans) have verbs that normalise them properly
 * on the way in. A host who opens the config file at all should be doing it out
 * of curiosity, never out of necessity.
 *
 * Three structural decisions, none of them cosmetic:
 *
 *  - `run(argv, io)` returns an exit code and **never calls process.exit**, and
 *    never writes to process.stdout directly. Everything goes through the
 *    injected streams. That is what lets a test suite drive every verb
 *    in-process, without spawning a shell, and assert on the exact bytes a host
 *    would see.
 *  - Nothing here reimplements config merging, clamping, code generation or IP
 *    normalisation. config.js, auth.js and limits.js own those; this file is
 *    the front door to them, and a second implementation of any of them would
 *    be a second set of rules to drift apart.
 *  - `lib/server.js` is required lazily, inside the verb that needs it. It is
 *    written in parallel with this file, so a `require` at module scope would
 *    take every other verb down with it if it were missing or momentarily
 *    broken. `start` reports that clearly instead.
 *
 * Secrets discipline: a join code is printed by exactly three things -- `init`,
 * `invite`, and `invite list --reveal`. It never goes through the logger (log
 * lines get piped into files, journals and, in a container, into whatever the
 * orchestrator collects), never appears in `status` or `doctor`, and never
 * appears in an error message -- not even the one that refuses a mistyped
 * `--code`, which names the alphabet rather than echoing what was typed.
 * `status` and `invite list` mask through config.redact so a host can
 * screen-share either one.
 *
 * A passcode is not optional. The owner's rule is that both halves of this
 * software -- the in-game LAN host and this one -- require one, so there is no
 * `--no-auth`, no wizard question that can turn it off, and `start` refuses a
 * configuration that would admit anybody. The old flag is still *recognised*,
 * because people paste old commands out of their shell history, but only so it
 * can be answered with a sentence instead of "unknown option".
 *
 * Exit codes: 0 success, 1 runtime error, 2 usage error.
 *
 * Three verbs need the hub itself rather than a file. `kick` and `broadcast`
 * are instructions, and a file cannot carry an instruction; `stats` is a
 * question, but about counters that live in the hub's memory and reach no
 * file at all. All three dial the running hub's admin socket (lib/admin.js):
 * one JSON line out, one JSON line back, connection closed. That is the only
 * thing here that talks to a live hub; everything else still reads a file and
 * says how old it is.
 *
 * No dependencies: node:fs, node:net, node:path, node:readline/promises.
 */

const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const readline = require('node:readline/promises');

const config = require('./config.js');
const auth = require('./auth.js');
const limits = require('./limits.js');
const log = require('./log.js');
const rank = require('./rank.js');
const reachability = require('./reachability.js');
const upnp = require('./upnp.js');

const OK = 0;
const ERROR = 1;
const USAGE = 2;

const PROGRAM = 'rby-mmo-hub';
const FALLBACK_VERSION = '0.0.0-dev';

// Flags that are switches, so `--yes start` does not eat `start` as a value.
const SWITCHES = new Set([
  'yes', 'force', 'reveal', 'clear', 'help', 'version', 'quiet', 'insecureConfig',
  'json', 'all', 'once', 'admin',
]);

/*
 * The two files the hub writes for itself, beside the config file: the
 * leaderboard it has always kept, and the roster snapshot `players` reads.
 *
 * Both are read here and written nowhere here -- this process is not the hub
 * (see throttleLines() for the long version of that). The snapshot's contract
 * is fixed in the plan (docs/plans/server-side-listing.md §3): a JSON object
 * with `version`, `updatedAt`, `stoppedAt` and a `players` array carrying
 * name / map / x / y / busy / party / points / ranked, written atomically on
 * every roster change and refreshed as a heartbeat every STATUS_HEARTBEAT_MS
 * so that its *age* is the honest answer to "is the hub still there".
 *
 * The staleness ceiling is 2.5 heartbeats. One missed write is a busy event
 * loop or a slow disk and means nothing; two and a half missed writes in a
 * row is a hub that has stopped without saying so -- a crash, a `kill -9`, a
 * container that went away -- and that is worth saying out loud rather than
 * printing a roster from an hour ago as if it were the truth.
 *
 * Which heartbeat, though, is the snapshot's own to say: it carries
 * `heartbeatMs`, and snapshotAge() measures against that. The constant below
 * is the default for a file written before the hub started saying, and the
 * number the help text quotes when there is no file to ask.
 */
const STATUS_FILENAME = 'status.json';
const RANKING_FILENAME = 'ranking.json';
const STATUS_HEARTBEAT_MS = 10000;
const STATUS_STALE_MS = STATUS_HEARTBEAT_MS * 2.5;

/*
 * The other two things beside the config file, both newer than the pair
 * above and both read the same way: follow the config path, never guess.
 *
 * `history.jsonl` is append-only and deliberately not JSON as a whole -- one
 * record per line, so a hub that dies mid-write costs the reader one torn
 * line rather than the whole file. That shape is only worth having if the
 * reader honours it, which is why readHistoryFile() skips a line it cannot
 * parse instead of refusing the file the way readJsonFile() rightly does.
 *
 * It arrives in two generations, because the hub rotates it: see
 * readHistoryLedger() for why both are read and what it would cost not to.
 *
 * `admin.sock` is the one live channel this process has. It exists only while
 * a hub is running, so its absence is ordinary news and not an error.
 */
const HISTORY_FILENAME = 'history.jsonl';
const HISTORY_ROTATED_SUFFIX = '.1';
const ADMIN_FILENAME = 'admin.sock';

/*
 * `watch` is `players` on a timer, and the timer is the only number it owns.
 * Two seconds is under the hub's own heartbeat, so a repaint never has to
 * wait for news; the floor keeps a host from turning their terminal into a
 * busy loop over a file, and the ceiling keeps `--interval 86400` from
 * looking like a hang. Out-of-range values are pulled to the nearest end and
 * said out loud, the way config.js clamps rather than refuses.
 */
const WATCH_INTERVAL_S = 2;
const WATCH_INTERVAL_MIN_S = 1;
const WATCH_INTERVAL_MAX_S = 60;

/*
 * How many settled battles `history` prints when nobody says. A screenful,
 * because the file holds thousands and the question behind the verb is
 * almost always "what just happened".
 */
const HISTORY_DEFAULT = 20;

/*
 * How long an admin verb waits for the hub to answer one line. The hub is on
 * the other end of a Unix socket on this machine and answers from memory, so
 * this is not a budget an honest exchange comes near -- it is there so a hub
 * wedged mid-answer costs an operator five seconds and a sentence rather than
 * a terminal that never comes back.
 */
const ADMIN_TIMEOUT_MS = 5000;

/*
 * The ceiling on a reply this reads before giving up on it. `kick` and
 * `broadcast` answer in a few dozen bytes and `stats` in a few hundred;
 * anything past this is not the hub speaking the protocol, and reading it
 * into memory unbounded would be the one thing a CLI verb has no excuse for.
 */
const ADMIN_MAX_RESPONSE_BYTES = 1024 * 1024;

/*
 * How long `start` will wait for the router to acknowledge the removal of its
 * port mapping before giving up and shutting down anyway. SSDP discovery plus
 * a SOAP POST is a real network round trip, and a router that has gone away
 * (or gone to sleep) must never be the reason a host cannot stop their hub:
 * an unremoved mapping expires with its lease, a wedged shutdown does not
 * expire at all.
 *
 * Deliberately *inside* server.js's own SHUTDOWN_HOOK_MS (2000). That one is
 * the real ceiling on the Ctrl-C path -- close() abandons the hook when it
 * elapses -- so a longer budget here would only mean the host never gets told
 * why the mapping is still up.
 */
const UNMAP_TIMEOUT_MS = 1500;

const TIMED_OUT = Symbol('timed out');

function withDeadline(promise, ms) {
  let timer = null;
  const deadline = new Promise((resolve) => {
    timer = setTimeout(() => resolve(TIMED_OUT), ms);
    // Never a reason for the process to stay up on its own account.
    if (timer && typeof timer.unref === 'function') timer.unref();
  });
  return Promise.race([Promise.resolve(promise), deadline])
    .then((value) => { if (timer) clearTimeout(timer); return value; },
      (err) => { if (timer) clearTimeout(timer); throw err; });
}

// --------------------------------------------------------------- arguments

function camel(name) {
  // A dotted name is a config path (`--limits.maxPending 12`) and must survive
  // verbatim; config.js accepts those directly, which is what keeps every leaf
  // settable without a hand-written flag per knob.
  if (name.includes('.')) return name;
  return name.replace(/-([a-z0-9])/gi, (match, char) => char.toUpperCase());
}

/**
 * A small, predictable parser: `--flag`, `--flag value`, `--flag=value`,
 * `--no-flag`, and `--` to stop. No short options -- this is a tool a host
 * types a handful of times, and unambiguous beats terse.
 */
function parseArgs(argv) {
  const positional = [];
  const flags = {};

  for (let i = 0; i < argv.length; i += 1) {
    const arg = String(argv[i]);

    if (arg === '--') {
      positional.push(...argv.slice(i + 1).map(String));
      break;
    }
    if (!arg.startsWith('--')) {
      positional.push(arg);
      continue;
    }

    let name = arg.slice(2);
    let value;
    const equals = name.indexOf('=');
    if (equals >= 0) {
      value = name.slice(equals + 1);
      name = name.slice(0, equals);
    }

    let negated = false;
    if (name.startsWith('no-')) {
      negated = true;
      name = name.slice(3);
    }
    if (!name) continue;

    const key = camel(name);
    if (negated) {
      flags[key] = false;
      continue;
    }
    if (value !== undefined) {
      flags[key] = value;
      continue;
    }

    const next = argv[i + 1];
    if (SWITCHES.has(key) || next === undefined || String(next).startsWith('--')) {
      flags[key] = true;
    } else {
      flags[key] = String(next);
      i += 1;
    }
  }

  return { positional, flags };
}

/**
 * The subset of the parsed flags that config.js understands. Passing the rest
 * (`--yes`, `--reveal`) would earn an "unknown option" warning per invocation,
 * which trains a host to ignore warnings -- the opposite of what they are for.
 */
function configFlags(flags) {
  const out = {};
  for (const [key, value] of Object.entries(flags)) {
    if (key in config.FLAG_MAP || config.LEAF_PATHS.includes(key)) out[key] = value;
  }
  return out;
}

function parseDuration(text) {
  const match = /^(\d{1,7})\s*([mhd])$/i.exec(String(text).trim());
  if (!match) return null;
  const amount = Number(match[1]);
  if (!Number.isFinite(amount) || amount < 1) return null;
  const unit = match[2].toLowerCase();
  const ms = unit === 'm' ? 60000 : unit === 'h' ? 3600000 : 86400000;
  return amount * ms;
}

/** A duration a host can read at a glance. Exact, never rounded. */
function humanMs(value) {
  const ms = Number(value);
  if (!Number.isFinite(ms) || ms < 0) return String(value);
  if (ms === 0) return '0ms';
  if (ms % 86400000 === 0) return `${ms / 86400000}d`;
  if (ms % 3600000 === 0) return `${ms / 3600000}h`;
  if (ms % 60000 === 0) return `${ms / 60000}m`;
  if (ms % 1000 === 0) return `${ms / 1000}s`;
  return `${ms}ms`;
}

/*
 * The same false-ish spellings config.js accepts, recognised here so that
 * `--no-auth`, `--auth false` and `--auth=off` all reach the one sentence that
 * explains the flag is gone -- rather than three different outcomes, one of
 * which would quietly write an open hub.
 */
function saysNo(value) {
  if (value === false) return true;
  if (typeof value !== 'string') return false;
  return ['false', '0', 'no', 'off', 'n', ''].includes(value.trim().toLowerCase());
}

/**
 * A passcode a host supplied on the command line, normalised, or an error to
 * print. `--code` is the documented spelling; `--passcode` is accepted because
 * it is the word the in-game screen uses and half the people who reach for the
 * flag will type it.
 *
 * The refusal never echoes what was typed: a mistyped passcode is still very
 * nearly a passcode, and this text can end up in a terminal recording or a
 * pasted bug report.
 */
function suppliedCode(flags) {
  const raw = flags.code !== undefined ? flags.code : flags.passcode;
  const flag = flags.code !== undefined ? '--code' : '--passcode';
  if (raw === undefined) return { given: false, code: null, error: null };
  if (raw === true || raw === false || String(raw).trim() === '') {
    return {
      given: true,
      code: null,
      error: [`${flag} needs a passcode after it, e.g. \`${flag} A7K3P9\`.`],
    };
  }
  const normalized = auth.normalizeCode(String(raw));
  if (normalized === null) {
    return {
      given: true,
      code: null,
      error: [
        `${flag}: that is not a passcode this hub can use.`,
        `A passcode is ${auth.CODE_LEN} characters from ${auth.ALPHABET}`,
        '-- the digits and the capital letters except I, L, O and U, which are',
        'left out so nothing is mistyped off a screenshot. Dashes, spaces and',
        'lower case are fine; they are normalised away.',
      ],
    };
  }
  return { given: true, code: normalized, error: null };
}

// ------------------------------------------------------------------- output

/*
 * `rby-mmo-hub invite | head -1` closes the pipe under us mid-write, and on a
 * socket-backed stdout the resulting EPIPE arrives *asynchronously*, as an
 * 'error' event -- so a try/catch around write() never sees it and Node kills
 * the process over an unhandled event. Silencing the stream's error event is
 * the only thing that actually stops that, and losing output that nobody is
 * reading any more is the correct outcome. Marked so repeated runs in one
 * process (the test suite) do not stack listeners.
 */
const QUIET = Symbol.for('rby_mmo.cli.quietStream');

function quiet(stream) {
  if (!stream || typeof stream.on !== 'function' || stream[QUIET]) return;
  try {
    stream[QUIET] = true;
    stream.on('error', () => {});
  } catch (err) {
    /* a frozen or fake stream: nothing to silence */
  }
}

function makeIo(io) {
  const streams = io || {};
  const stdout = streams.stdout || process.stdout;
  const stderr = streams.stderr || process.stderr;
  quiet(stdout);
  quiet(stderr);

  const push = (stream, text) => {
    // The synchronous half of the same problem: a stream already destroyed
    // throws from write() rather than emitting.
    try {
      stream.write(text);
    } catch (err) {
      /* nothing useful can be printed about a broken output stream */
    }
  };

  return {
    stdout,
    stderr,
    stdin: streams.stdin || process.stdin,
    env: streams.env || process.env,
    cwd: streams.cwd || process.cwd(),
    say: (line) => push(stdout, `${line === undefined ? '' : line}\n`),
    warn: (line) => push(stderr, `${line === undefined ? '' : line}\n`),
  };
}

function pad(text, width) {
  const value = String(text);
  return value.length >= width ? value : value + ' '.repeat(width - value.length);
}

function printLines(ctx, lines) {
  for (const line of lines) ctx.say(line);
}

/**
 * `silent` is a level config.js accepts and log.js does not know about (its
 * ladder stops at `error`), so it is honoured here rather than being quietly
 * downgraded to `info` -- a host who asked for silence and got chatter would
 * reasonably conclude the setting does nothing.
 */
function makeLog(cfg, stream) {
  const level = cfg && cfg.log ? cfg.log.level : 'info';
  if (level === 'silent') {
    const nothing = () => {};
    return { level: 'silent', error: nothing, warn: nothing, info: nothing, debug: nothing };
  }
  return log.createLog({ level, stream });
}

function version() {
  // T10 writes server/package.json. Until it does -- and if it is ever removed
  // from a packed archive -- a missing file reports a placeholder rather than
  // taking `--version` down.
  try {
    const parsed = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'));
    if (parsed && typeof parsed.version === 'string' && parsed.version) return parsed.version;
  } catch (err) {
    /* no package.json here: fall through */
  }
  return FALLBACK_VERSION;
}

// --------------------------------------------------------------------- help

const HELP = {
  '': [
    `${PROGRAM} -- run and configure an RBY MMO hub`,
    '',
    `Usage: ${PROGRAM} <command> [options]`,
    '',
    'Getting started',
    '  init                        first-run wizard: writes the config file and',
    '                              prints the passcode (once)',
    '  start                       run the hub',
    '  doctor                      check the configuration and report who can',
    '                              reach this machine',
    '',
    'Configuration',
    '  status                      the effective settings, and where each one',
    '                              came from (flag / env / file / default)',
    '  config list                 every setting and its current value',
    '  config get <path>           one setting, e.g. limits.maxPending',
    '  config set <path> <value>   change one setting (clamped, then saved)',
    '',
    'Who is playing',
    '  players [--json]            who is connected and where they are standing,',
    '                              from the snapshot the running hub writes',
    '  watch [--interval S]        that same view, repainted every few seconds',
    '  ranking [--json] [--all]    the leaderboard, read off the disk',
    '  history [-n N] [--json]     settled ranked battles, newest first',
    '',
    'While the hub is running',
    '  stats [--json]              its live counters: seats, connections, and',
    '                              the wrong-passcode throttle as it stands now',
    '  kick <name> [--reason X]    remove somebody who is connected now',
    '  broadcast <text>            say one line to everybody in the world',
    '',
    '  All three need the hub itself and not a file: the last two are',
    '  instructions, and no file can carry one; the counters `stats` prints',
    '  live in the hub\'s memory and are written nowhere. They speak to the',
    '  admin socket it keeps beside its config file. Run them where the hub',
    `  runs -- in Docker, that is \`docker compose exec hub ${PROGRAM} ...\`.`,
    '',
    'Who may join',
    '  invite [options]            mint a new join code and print it once',
    '  invite --admin              the same, but the hub marks the connection',
    '                              and the code shows as ADMIN on these views',
    '  invite list [--reveal]      list join codes; masked unless --reveal',
    '  revoke <id>                 revoke one join code, admin or not',
    '  ban <ip> [--reason X]       refuse an address',
    '  unban <ip>                  stop refusing an address',
    '  allow [<ip>|--clear]        allowlist: when it has entries, ONLY those',
    '                              addresses may connect',
    '',
    `  A passcode is always required -- ${auth.CODE_LEN} characters, e.g. A7K3P9. Nothing`,
    '  turns it off; `start` refuses a config that would admit anybody. Both',
    '  `init` and `invite` take --code CODE if you would rather choose it.',
    '',
    'Router',
    '  upnp enable|disable|status  ask the router to forward the port (off by',
    '                              default; read the warning first)',
    '',
    'Other',
    '  help [command]              this text, or a command\'s own',
    '  --version                   print the version',
    '',
    'Global options',
    '  --config <file>   which config file to use. Default: $RBY_MMO_CONFIG,',
    '                    then ./config.json, then /data/config.json in a container.',
    '',
    'Precedence, everywhere: command-line flag > RBY_MMO_* env var > config file',
    '> built-in default.',
    '',
    'Exit codes: 0 success, 1 error, 2 wrong usage.',
  ],
  init: [
    `Usage: ${PROGRAM} init [--force] [--yes] [--port N] [--max N] [--code CODE]`,
    '                       [--log-level debug|info|warn|error|silent]',
    '',
    'Asks four questions, writes the config file with mode 0600, and prints the',
    'passcode once. Refuses to overwrite an existing config without --force.',
    '',
    '  --yes         do not ask; take the flags and the defaults. This is the',
    '                path a Dockerfile or a test suite uses.',
    '  --force       replace an existing config file.',
    '  --code CODE   use this passcode instead of a generated one.',
    `                ${auth.CODE_LEN} characters from ${auth.ALPHABET}`,
    '                -- no I, L, O or U. Dashes, spaces and lower case are',
    '                normalised away, so a code copied out of a chat message',
    '                works. This is how you make the hub answer to the same',
    '                passcode as your in-game LAN game.',
    '',
    'There is no --no-auth. A passcode is required, here and in game.',
  ],
  start: [
    `Usage: ${PROGRAM} start [--port N] [--host ADDR] [--max N] [...]`,
    '                        [--insecure-config]',
    '',
    'Loads the configuration, prints who can reach this machine, and runs the',
    'hub until it is stopped. Any config path may be overridden for this run',
    'with a flag -- `--limits.maxPending 12` works as well as `--max 8`.',
    '',
    'Two things stop it before it binds anything:',
    '',
    '  - a config file readable by the group or by everyone else on this',
    '    machine. It holds every passcode in plaintext; the fix it prints is',
    '    `chmod 600 <file>`.',
    '  - a configuration that would admit anybody: auth.required off, or no',
    `    usable passcode. The fix it prints is \`${PROGRAM} invite\`.`,
    '',
    '  --insecure-config   start anyway on a group- or world-readable config.',
    '                      For a host who genuinely has an unusual setup; it',
    '                      prints exactly what is being accepted. It does not',
    '                      waive the passcode -- nothing does.',
  ],
  status: [
    `Usage: ${PROGRAM} status`,
    '',
    'Prints every setting with the value in force and where it came from, so',
    '"why is it still 4 players" has an answer, then the wrong-passcode',
    'throttle in plain words. Passcodes are masked.',
  ],
  players: [
    `Usage: ${PROGRAM} players [--json]`,
    '',
    'Who is connected right now, where each of them is standing, and what they',
    `are scored at. Read from ${STATUS_FILENAME}, which the running hub writes`,
    'beside its config file -- on every join and leave, and every',
    `${humanMs(STATUS_HEARTBEAT_MS)} as a heartbeat.`,
    '',
    'This command is not the hub and has no line to it, so the one thing it can',
    'be sure of is how old that file is -- and it says so. A snapshot older',
    `than ${humanMs(STATUS_STALE_MS)} is reported as a hub that appears to be down, rather`,
    'than as an empty world.',
    '',
    '  LOCATION  the map the player is on. A dash means the hub cannot see one',
    '            -- they are in a battle or a menu, where no position is sent.',
    '  STATUS    BUSY (in a trade or battle), PARTY (in a two-player party),',
    '            or blank.',
    '  POINTS    the ranked score; blank for a player who is not ranked.',
    '',
    '  --json    print the snapshot\'s player list as JSON, for a script.',
    '',
    `  \`${PROGRAM} watch\` prints this same view on a timer.`,
  ],
  watch: [
    `Usage: ${PROGRAM} watch [--interval SECONDS] [--once] [--json]`,
    '',
    `Exactly what \`${PROGRAM} players\` prints, drawn again every ${WATCH_INTERVAL_S} seconds`,
    'until you stop it with Ctrl-C. Same file, same reading, same honesty about',
    'how old it is -- this is a view of a snapshot, not a line into the hub, and',
    'a hub that dies mid-watch shows up as an ageing heartbeat rather than as an',
    'empty world.',
    '',
    `  --interval S  seconds between repaints. ${WATCH_INTERVAL_MIN_S} to ${WATCH_INTERVAL_MAX_S}; ` +
      'anything outside that is',
    '                pulled to the nearest end and reported.',
    '  --once        draw one frame and exit. For a script, a screenshot, or a',
    '                terminal that should not be held open.',
    '  --json        one JSON document per frame instead of the table.',
    '',
    'On a terminal each frame clears the screen first. Piped or redirected, it',
    'does not: the frames follow one another as plain text, with no escape',
    'sequences to clean out of the file afterwards.',
  ],
  history: [
    `Usage: ${PROGRAM} history [-n N] [--json]`,
    '',
    `Settled ranked battles, newest first, read from ${HISTORY_FILENAME} beside the`,
    'config file. The hub appends one line to it as each result is scored, so',
    'this is the record of what the ranking is made of -- who beat whom, when,',
    'and for how many points.',
    '',
    `Last ${HISTORY_DEFAULT} by default.`,
    '',
    'The hub keeps that ledger in two generations: past a size ceiling it',
    `renames it to ${HISTORY_FILENAME}${HISTORY_ROTATED_SUFFIX} and starts a fresh one. Both are read`,
    'here, older generation first, so a rotation costs nothing to read across.',
    '',
    '  WHEN      how long ago the battle settled.',
    '  POINTS    what the winner gained and the loser lost, e.g. +16/-16.',
    '  REMATCH   shown only when a pair had met recently: x3 is the third time',
    '            these two have settled a battle inside the window the hub',
    '            counts. The winner gains less each time, so this column is',
    '            usually the answer to "why was that worth so little".',
    '',
    '  -n N      how many to print. Both generations are kept bounded by the',
    '            hub, so a large N simply prints everything there is.',
    '  --json    print the records as one JSON array, newest first, same cut.',
    '',
    'Only agreed, ranked results are here. A draw, a disagreement between the',
    'two clients, or an unranked battle scores nothing and writes nothing.',
    'A line the reader cannot parse is skipped rather than fatal: the ledger is',
    'appended to, so a hub that was killed mid-write leaves a torn last line --',
    'in either generation, since a rotation freezes whatever it left behind.',
  ],
  stats: [
    `Usage: ${PROGRAM} stats [--json]`,
    '',
    'The counters of the hub that is running right now, asked of the hub',
    `itself. What \`${PROGRAM} status\` prints about limits is what they are`,
    '*configured* to be; this is what they *are* -- numbers that live in the',
    'hub\'s memory, are written to no file, and go when the process does.',
    '',
    '  The hub    where it is bound, how long it has been up, the protocol it',
    '             speaks, how many of its seats are taken, and how many',
    '             connections are still finding their way into the world.',
    '  The door   connections open and handshakes not finished yet, how many',
    '             wrong passcodes have arrived recently against the ceiling',
    '             that trips, whether that ceiling is tripped this second, and',
    '             how many addresses are backing off or still remembered.',
    '',
    '  --json    the hub\'s own answer, as JSON, for a script.',
    '',
    'Addresses are counted here and never printed, in either form -- the same',
    `discipline the rosters keep. \`${PROGRAM} players\` is who is connected, by`,
    'name; `ban` and `unban` are what an address is for.',
    '',
    `Needs the hub running on this machine (${ADMIN_FILENAME}, beside the config`,
    'file). In Docker:',
    `    docker compose exec hub ${PROGRAM} stats`,
  ],
  kick: [
    `Usage: ${PROGRAM} kick <name> [--reason TEXT]`,
    '',
    'Removes a connected player: the hub shows them why, closes their',
    'connection and tells everybody else they left. It is not a ban -- they can',
    'reconnect immediately with the same passcode. To keep somebody out, `ban`',
    'their address (or `revoke` the code they used) and then kick them.',
    '',
    'Names are matched without regard to case, and a name is unique only among',
    'ranked players -- so this may remove nobody, one player, or several. It',
    'says which, by name.',
    '',
    '  --reason TEXT   the sentence the player is shown. Put it last: every',
    '                  word after it is part of the reason. Left out, the hub',
    '                  uses its own wording.',
    '',
    `This needs the hub running on this machine: it speaks to ${ADMIN_FILENAME},`,
    'which the hub keeps beside its config file while it is up. In Docker the',
    'socket is inside the container:',
    `    docker compose exec hub ${PROGRAM} kick RED`,
  ],
  broadcast: [
    `Usage: ${PROGRAM} broadcast <text>`,
    '',
    'Says one line to everybody in the world, from HUB. It arrives as an',
    'ordinary global chat line -- no modal, no interruption -- so it is the way',
    'to announce a restart before pulling the plug on a shared world.',
    '',
    'The text is held to exactly the charset and length every other chat line',
    'is: one line, plain characters, no newlines. A line that is empty once',
    'cleaned is refused rather than sent as a blank.',
    '',
    'It prints how many players it reached, which is the honest measure -- a',
    'world with nobody in it delivers to nobody.',
    '',
    `Needs the hub running on this machine (${ADMIN_FILENAME}, beside the config`,
    'file). In Docker:',
    `    docker compose exec hub ${PROGRAM} broadcast back in five minutes`,
    '',
    'For a line every player sees on the way in instead, set the MOTD:',
    `\`${PROGRAM} config set motd <text>\`, which a running hub picks up on a`,
    'reload rather than a restart.',
  ],
  ranking: [
    `Usage: ${PROGRAM} ranking [--json] [--all]`,
    '',
    `The leaderboard, read from ${RANKING_FILENAME} beside the config file --`,
    'the same file the hub reloads when it restarts, so it survives one. The',
    'hub saves it within a second of a ranked battle being settled; nothing',
    'here is live, and nothing here needs a game client.',
    '',
    `Top ${rank.RANK_TOP} by default, best first, ties broken by name -- the same order`,
    'players see in game.',
    '',
    '  W and L  settled ranked battles won and lost. Both read 0 for a player',
    '           carried over from a board saved before the hub counted them;',
    `           \`${PROGRAM} history\` is where the individual results are.`,
    '',
    '  --all     every ranked player, not just the top ' + `${rank.RANK_TOP}.`,
    '  --json    print the rows as JSON. The stored token digest is not among',
    '            the fields; it is the hub\'s business and nobody else\'s.',
    '',
    'A player who has never won a point is not on the board at all: zero means',
    '"never won" and "lost it all back" alike, and neither is a placing.',
  ],
  config: [
    `Usage: ${PROGRAM} config list`,
    `       ${PROGRAM} config get <path>`,
    `       ${PROGRAM} config set <path> <value>`,
    '',
    'Paths are dotted, e.g. listen.port, maxPlayers, limits.maxPending,',
    'network.upnp.leaseSeconds, log.level.',
    '',
    'Out-of-range numbers are pulled to the nearest end and reported before',
    'anything is written. Join codes are not settable here -- use `invite` and',
    '`revoke`, which generate and normalise them properly.',
  ],
  invite: [
    `Usage: ${PROGRAM} invite [--label TEXT] [--expires 30m|24h|7d] [--uses N]`,
    '                         [--code CODE] [--admin]',
    `       ${PROGRAM} invite list [--reveal]`,
    '',
    'Mints a join code and prints it once. Codes are masked in `invite list`',
    'unless --reveal is given, so the list is safe to screen-share; the KIND',
    'column marks admin codes either way, since what a code opens is not a',
    'secret.',
    '',
    '  --expires   30m, 24h, 7d -- minutes, hours or days. Nothing else.',
    '  --uses N    how many times it may be used to join the game before it',
    '              stops working. Joins are the only thing that spends a use,',
    '              on an admin code as much as on a player\'s.',
    '  --code CODE use this passcode rather than a generated one:',
    `              ${auth.CODE_LEN} characters from ${auth.ALPHABET}.`,
    '              Dashes, spaces and lower case are normalised away. Use it',
    '              to reuse the passcode from your in-game LAN game, or to',
    '              pick one your friends can remember.',
    '  --admin     mint an admin code. It joins the game exactly like any',
    '              other code; what differs is that the hub marks the',
    '              connection, so the operator features that arrive in game',
    '              later will look for it. Until then the mark shows as ADMIN',
    '              on this hub\'s own views. Consider pairing it with',
    '              --expires: an admin code is worth more to a thief than a',
    '              player\'s is.',
    '',
    'Every code is revoked the same way, admin or not: `revoke <id>`, with the',
    'id from `invite list`.',
  ],
  revoke: [
    `Usage: ${PROGRAM} revoke <id>`,
    '',
    'Ids come from `invite list`. A unique prefix is enough.',
  ],
  ban: [
    `Usage: ${PROGRAM} ban <ip> [--reason TEXT]`,
    '',
    'Addresses are normalised first, so ::ffff:203.0.113.7 and 203.0.113.7 are',
    'the same ban and a dual-stack client cannot slip past it.',
  ],
  unban: [`Usage: ${PROGRAM} unban <ip>`],
  allow: [
    `Usage: ${PROGRAM} allow [<ip>] [--clear]`,
    '',
    'With no argument, prints the allowlist. An allowlist with entries is',
    'exclusive: only those addresses may connect. --clear empties it.',
  ],
  doctor: [
    `Usage: ${PROGRAM} doctor`,
    '',
    'Configuration sanity plus a reachability report. Exit code 1 if something',
    'would stop players connecting; 0 if only warnings.',
  ],
  upnp: [
    `Usage: ${PROGRAM} upnp enable|disable|status`,
    '',
    'Automatic port forwarding, off by default. `enable` prints the full risk',
    'note before it does anything.',
  ],
};

function help(ctx, verb) {
  const lines = HELP[verb] || HELP[''];
  printLines(ctx, lines);
  return OK;
}

// ---------------------------------------------------------------- config i/o

function resolveConfigPath(ctx) {
  return config.resolvePath({ flag: ctx.flags.config, env: ctx.env, cwd: ctx.cwd });
}

/** Full precedence: flag > env > file > default. What the hub will actually run with. */
function loadEffective(ctx) {
  return config.load({
    path: ctx.file,
    env: ctx.env,
    flags: configFlags(ctx.flags),
    cwd: ctx.cwd,
  });
}

/**
 * The file, plus defaults, and nothing else -- deliberately env-free and
 * flag-free.
 *
 * Every verb that *writes* uses this. Editing through the effective config
 * would freeze the host's shell into the file: `RBY_MMO_PORT=9000` in one
 * terminal, an unrelated `config set log.level debug`, and the port is silently
 * pinned at 9000 for everyone forever after.
 */
function loadForEdit(ctx) {
  return config.load({ path: ctx.file, env: {}, flags: {}, cwd: ctx.cwd });
}

/**
 * The other places a config plausibly is, when it is not where we looked.
 *
 * Only paths that exist and are not the one already tried, so this can only
 * ever name a real file. `/data/config.json` is on the list because it is
 * where the container image puts one, and the commonest way to arrive here is
 * running a verb on the host that belongs inside the container.
 */
function configsElsewhere(ctx) {
  const candidates = [
    ctx.env.RBY_MMO_CONFIG,
    path.join(ctx.cwd, 'config.json'),
    '/data/config.json',
  ];
  const seen = new Set([path.resolve(ctx.file)]);
  const found = [];
  for (const candidate of candidates) {
    if (!candidate) continue;
    const full = path.resolve(candidate);
    if (seen.has(full)) continue;
    seen.add(full);
    try {
      if (fs.statSync(full).isFile()) found.push(full);
    } catch { /* not there, or not ours to read -- either way, not a lead */ }
  }
  return found;
}

/**
 * Refuse a verb that edits a config which is not there -- and, crucially, do
 * not answer with "run init".
 *
 * That advice used to be the first line, and it is the wrong first move
 * roughly whenever it is read. Standing in the wrong directory, or running a
 * verb on the host that belongs inside a container, lands here with a perfectly
 * good hub a few metres away; `init` then mints a *second* config with a *new
 * passcode*, and the hub the host actually cares about carries on unchanged
 * with the old one. They then change a setting, restart, and watch nothing
 * happen -- which is exactly the report that produced this comment.
 *
 * So: say where we looked, name any config we can actually see, and mention
 * `init` last and only when there is nothing to find -- with what it costs.
 */
function requireExistingConfig(ctx) {
  const loaded = loadForEdit(ctx);
  if (!loaded.exists) {
    ctx.warn(`No configuration at ${ctx.file}.`);
    const elsewhere = configsElsewhere(ctx);
    if (elsewhere.length) {
      ctx.warn('There is one here, though:');
      for (const other of elsewhere) ctx.warn(`    ${other}`);
      ctx.warn(`Point at it with \`--config <path>\`, or run from its directory.`);
    } else {
      ctx.warn('If this hub runs in Docker, its config is inside the container');
      ctx.warn('and not on this machine at all:');
      ctx.warn(`    docker compose exec hub ${PROGRAM} <command>`);
      ctx.warn(`Only if this is a brand new hub, \`${PROGRAM} init\` writes one --`);
      ctx.warn('it mints a fresh passcode, which nobody you play with has yet.');
    }
    return null;
  }
  return loaded;
}

function reportWarnings(ctx, warnings, prefix) {
  for (const warning of warnings || []) ctx.warn(`${prefix || 'note'}: ${warning}`);
}

/**
 * config.load already folds the file-permission complaint into its warnings.
 * Every verb that also reports permissions in its own voice pulls it back out
 * here, so a host is told once rather than twice -- a report that repeats
 * itself reads as a report that is not sure.
 */
function splitWarnings(loaded) {
  const permission = config.checkPermissions(loaded.path);
  return {
    permission,
    warnings: permission
      ? loaded.warnings.filter((warning) => warning !== permission)
      : loaded.warnings,
  };
}

function saveConfig(ctx, cfg) {
  try {
    config.save(ctx.file, cfg);
    return true;
  } catch (err) {
    ctx.warn(`Could not write ${ctx.file}: ${err.message}`);
    return false;
  }
}

/** Masked copies, via the same masking `status` uses. */
function maskedCredentials(credentials) {
  const copy = config.redact({ auth: { credentials } });
  return (copy && copy.auth && copy.auth.credentials) || [];
}

function limitOf(cfg, key) {
  const value = cfg && cfg.limits ? cfg.limits[key] : undefined;
  return value === undefined || value === null ? config.DEFAULTS.limits[key] : value;
}

/*
 * The wrong-passcode throttle, in words a host can act on.
 *
 * Honest about what it is: **the configured policy, not a live reading.**
 * limits.js does keep the live picture -- `stats().auth` carries
 * recentFailures, lockdown, throttledAddresses and the rest -- but that object
 * lives inside the running hub's process, reached only through the handle
 * `server.start()` resolves. `status` and `doctor` are separate short-lived
 * processes that read a config file; there is no admin socket and no signal
 * that answers, so they have nothing to read those counters from. Inventing a
 * number here would be worse than not printing one.
 *
 * The status snapshot `players` reads is not a way round this. It carries the
 * roster the hub is willing to publish -- who is online, and where -- and
 * deliberately not the limiter's internals, so the throttle's live counts are
 * still the hub's log's business and nobody else's.
 *
 * What a host who is being hammered actually sees is the hub's own log, which
 * is where limits.js's decisions surface. These lines tell them what those
 * decisions will be, which is the part that is knowable from here -- and the
 * part they can change.
 *
 * A 30-bit passcode (auth.js) is only as safe as this throttle, so the numbers
 * belong somewhere a host reads without being told to go looking.
 */
function throttleLines(cfg) {
  const grace = limitOf(cfg, 'authFailureGrace');
  return [
    'Wrong-passcode throttle (configured here; the live counts belong to the',
    'running hub and show up in its log, not in this command):',
    `  per address   ${grace === 0 ? 'no free attempts' : `${grace} free attempt(s)`} ` +
      `per ${humanMs(limitOf(cfg, 'authFailureWindowMs'))}, then a wait from ` +
      `${humanMs(limitOf(cfg, 'authBackoffBaseMs'))} doubling to ` +
      `${humanMs(limitOf(cfg, 'authBackoffMaxMs'))}`,
    `  hub-wide      ${limitOf(cfg, 'authGlobalFailures')} failures in ` +
      `${humanMs(limitOf(cfg, 'authGlobalWindowMs'))} shuts new joins for ` +
      `${humanMs(limitOf(cfg, 'authLockoutMs'))}`,
  ];
}

/**
 * Throttle settings that will bite the host rather than an attacker. Each one
 * is a comparison between two knobs that individually look reasonable, which
 * is exactly the kind of thing nobody spots by reading a table of numbers.
 *
 * Deliberately not here: anything derived from limits.connectPerMinute. That
 * bucket is charged per address (limits.js:492-495), so it says nothing about
 * how many wrong passcodes the *hub* can be shown by a roomful of addresses --
 * which is the number the hub-wide ceiling is about.
 */
function throttleConcerns(cfg) {
  const out = [];
  const grace = limitOf(cfg, 'authFailureGrace');
  const ceiling = limitOf(cfg, 'authGlobalFailures');
  const base = limitOf(cfg, 'authBackoffBaseMs');
  const max = limitOf(cfg, 'authBackoffMaxMs');
  const maxPlayers = cfg && cfg.maxPlayers !== undefined ? cfg.maxPlayers : config.DEFAULTS.maxPlayers;

  if (grace >= 50) {
    out.push(`limits.authFailureGrace is ${grace}: one address gets that many ` +
      'wrong passcodes per window before anything slows it down');
  }
  if (ceiling <= maxPlayers) {
    out.push(`limits.authGlobalFailures (${ceiling}) is no higher than maxPlayers ` +
      `(${maxPlayers}), so a full house mistyping the passcode once each would ` +
      `shut new joins for ${humanMs(limitOf(cfg, 'authLockoutMs'))}`);
  }
  if (max <= base) {
    out.push(`limits.authBackoffMaxMs (${humanMs(max)}) is not above ` +
      `limits.authBackoffBaseMs (${humanMs(base)}), so the per-address wait ` +
      'never escalates past its first step');
  }
  return out;
}

// -------------------------------------------------------------------- init

/*
 * The passcode, framed.
 *
 * This used to be a 60-column rule above and below a lone code, which was
 * sized for the 19-character grouped form and leaves a 6-character passcode
 * looking like a stray character in an empty field -- the one line on the page
 * a host must copy correctly, and the least emphatic thing on it. The box is
 * drawn to the code instead, so it stays deliberate at any length the format
 * ever takes.
 *
 * `options.admin` swaps the paragraph under the box, and only the paragraph:
 * an admin code is typed into the same in-game screen, in the same format, and
 * the one thing that differs about it is the mark it leaves on the connection
 * -- so that is the one thing the text differs about.
 */
function joinCodeBlock(ctx, code, extra, options) {
  const admin = Boolean(options && options.admin);
  const inner = `   ${String(code)}   `;
  const rule = `+${'-'.repeat(inner.length)}+`;
  ctx.say('');
  ctx.say(`      ${rule}`);
  ctx.say(`      |${inner}|`);
  ctx.say(`      ${rule}`);
  ctx.say('');
  if (admin) {
    ctx.say('  That is an admin code. It joins the world exactly like any other');
    ctx.say('  code -- typed once, in game, on the screen where this hub\'s address');
    ctx.say('  goes -- and what it adds is a mark on the connection:');
    ctx.say('');
    ctx.say('    - whatever operator features arrive in game later. Nothing uses');
    ctx.say('      it there yet; the hub already marks the connection, so when');
    ctx.say('      those exist this code is what they will look for.');
    ctx.say('    - today the mark is visible where you watch from: ADMIN in the');
    ctx.say(`      KIND column of \`${PROGRAM} invite list\`, and on the connection`);
    ctx.say('      in the rosters -- status.json, `players --json`, and the');
    ctx.say('      `who` answer on the admin socket.');
    ctx.say('');
    ctx.say('  Give it only to someone you would hand the hub itself to.');
  } else {
    ctx.say('  Give that to the friends you want in your world. They type it once,');
    ctx.say('  in game, on the screen where they enter this hub\'s address. Anyone');
    ctx.say('  without it is refused, in one sentence, and cannot get in.');
  }
  // An empty note is a deliberate blank line between two groups of them, not
  // an indent with nothing after it.
  for (const line of extra || []) ctx.say(line ? `  ${line}` : '');
  ctx.say('');
  ctx.say('  This is the only time it is printed in full. To see it again:');
  ctx.say(`      ${PROGRAM} invite list --reveal`);
  ctx.say('');
}

/**
 * A question that always finishes.
 *
 * `rl.question()` on a stream that has already ended returns a promise that
 * never settles -- so a wizard built on it hangs forever the moment stdin is a
 * pipe rather than a terminal, which is exactly what `docker run` without `-t`,
 * a CI job and `printf ... | rby-mmo-hub init` all are. Racing each question
 * against the interface's own close event turns that hang into "take the
 * default and move on", which is what a host who pressed Ctrl-D meant anyway.
 */
function makePrompter(rl) {
  const state = { closed: false, truncated: false };
  rl.on('close', () => { state.closed = true; });

  const ask = async (question, fallback) => {
    if (state.closed) {
      state.truncated = true;
      return fallback;
    }
    try {
      const ended = new Promise((resolve) => {
        rl.once('close', () => resolve(undefined));
      });
      const answer = await Promise.race([rl.question(question), ended]);
      if (answer === undefined) {
        state.truncated = true;
        return fallback;
      }
      const text = String(answer).trim();
      return text === '' ? fallback : text;
    } catch (err) {
      state.truncated = true;
      return fallback;
    }
  };

  ask.state = state;
  return ask;
}

/*
 * `--no-auth` was a real flag, and a host who used it once has it in their
 * shell history and in whatever notes they wrote for themselves. Letting it
 * fall through to config.js would be worse than an unknown-option error: it
 * maps to auth.required and would write exactly the open hub this software no
 * longer supports. So it is caught here, by name, and answered.
 *
 * Every false-ish spelling counts -- `--no-auth`, `--auth false`, `--auth=off`
 * -- because they all mean the same thing to config.js.
 */
function refuseNoAuth(ctx, verb) {
  if (!('auth' in ctx.flags) || !saysNo(ctx.flags.auth)) return false;
  ctx.warn('A passcode is required, so there is no way to turn it off.');
  ctx.warn('');
  ctx.warn('  --no-auth (and --auth false) used to write a hub anyone who found the');
  ctx.warn('  port could join. Both halves of this software now require a passcode:');
  ctx.warn('  the in-game LAN host asks for one, and this hub refuses to start');
  ctx.warn('  without one.');
  ctx.warn('');
  ctx.warn(`  Run \`${PROGRAM} ${verb}\` without it and a passcode is generated for you,`);
  ctx.warn(`  or \`${PROGRAM} ${verb} --code A7K3P9\` to choose your own.`);
  return true;
}

async function verbInit(ctx) {
  if (refuseNoAuth(ctx, 'init')) return USAGE;

  const supplied = suppliedCode(ctx.flags);
  if (supplied.error) {
    for (const line of supplied.error) ctx.warn(line);
    return USAGE;
  }

  if (fs.existsSync(ctx.file) && ctx.flags.force !== true) {
    ctx.warn(`There is already a configuration at ${ctx.file}.`);
    ctx.warn('Re-run with --force to replace it -- that writes a new join code and');
    ctx.warn('everyone using the old one stops being able to join. To change one');
    ctx.warn(`setting instead, use \`${PROGRAM} config set\`.`);
    return ERROR;
  }

  // Start from what this hub would actually run with, so a container that sets
  // RBY_MMO_PORT gets that port written into the file it just created rather
  // than a default that only looks wrong.
  const loaded = loadEffective(ctx);
  const cfg = loaded.config;
  reportWarnings(ctx, loaded.warnings, 'config');

  // Not a question any more, and not a setting init will write either way: the
  // wizard's third question used to be "require a join code?", and a host who
  // answered n got a hub anyone could walk into. What it asks now is *which*
  // passcode, which is the choice that was actually missing.
  let chosen = supplied.code;

  if (ctx.flags.yes !== true) {
    ctx.say(`${PROGRAM} -- first-run setup`);
    ctx.say('');
    ctx.say('Four questions. Everything stays on this machine; nothing is sent');
    ctx.say('anywhere, now or later.');
    ctx.say('');

    const rl = readline.createInterface({ input: ctx.stdin, output: ctx.stdout });
    const ask = makePrompter(rl);
    let typed = null;
    try {
      cfg.listen.port = await ask(`  Port to listen on [${cfg.listen.port}]: `, cfg.listen.port);
      cfg.maxPlayers = await ask(`  How many players at once, 2-64 [${cfg.maxPlayers}]: `, cfg.maxPlayers);

      typed = await ask(
        `  Passcode friends will type, ${auth.CODE_LEN} characters ` +
        `[${chosen || 'make one up for me'}]: `, chosen || '');

      cfg.log.level = await ask(
        `  Log level -- debug, info, warn, error, silent [${cfg.log.level}]: `, cfg.log.level);
    } finally {
      try { rl.close(); } catch (err) { /* already closed */ }
      // readline resumes stdin; leave it paused so the process can exit on its
      // own when this verb returns.
      if (ctx.stdin && typeof ctx.stdin.pause === 'function') {
        try { ctx.stdin.pause(); } catch (err) { /* not a real tty */ }
      }
    }
    ctx.say('');

    if (typeof typed === 'string' && typed.trim() !== '' && typed !== chosen) {
      const normalized = auth.normalizeCode(typed);
      if (normalized === null) {
        ctx.warn('That is not a passcode this hub can use, so nothing has been');
        ctx.warn(`written. A passcode is ${auth.CODE_LEN} characters from`);
        ctx.warn(`${auth.ALPHABET} -- the digits and the capitals`);
        ctx.warn('except I, L, O and U. Run init again, or pass `--code CODE`.');
        return USAGE;
      }
      chosen = normalized;
    }

    if (ask.state.truncated) {
      // Node's readline throws away whatever else was buffered once the input
      // stream ends, so piping four answers in one go answers one question and
      // silently defaults the rest. Saying so beats a config that looks like it
      // took input it did not.
      ctx.warn('note: the input ended before every question was answered, so the');
      ctx.warn('      rest took their defaults. For a scripted run use the flags:');
      ctx.warn(`      ${PROGRAM} init --yes --port N --max N [--code CODE] [--log-level L]`);
    }
  }

  /*
   * The passcode is not negotiable, so init writes `auth.required: true` no
   * matter what arrived from the file, the environment or a flag. Anything
   * that said otherwise is overruled out loud rather than silently: a host who
   * exported RBY_MMO_AUTH_REQUIRED=false has a reason to believe it did
   * something, and deserves to be told it no longer does.
   */
  const askedForOpen = cfg.auth.required === false;
  cfg.auth.required = true;

  const checked = config.validate(cfg);
  reportWarnings(ctx, checked.warnings, 'adjusted');
  const final = checked.config;
  final.auth.required = true;

  if (askedForOpen) {
    ctx.warn('note: something in this environment asked for a hub with no passcode');
    ctx.warn('      (auth.required false). It is required now, so that was ignored.');
  }

  let credential;
  try {
    credential = auth.newCredential({ label: 'Primary join code', secret: chosen });
  } catch (err) {
    // suppliedCode() and the wizard both normalise first, so reaching here
    // means auth.js rejected something they accepted -- report it, do not
    // write a config with no way in.
    ctx.warn(`Could not use that passcode: ${err.message}`);
    return ERROR;
  }
  // A stable, memorable id for the one credential a host will most often
  // name, matching the shape the plan documents (§3.5). Invites get random
  // ids; there is only ever one primary.
  credential.id = 'primary';
  final.auth.credentials = [credential];

  if (!saveConfig(ctx, final)) return ERROR;

  ctx.say(`Configuration written to ${ctx.file} (mode 0600, readable only by you).`);
  ctx.say('');
  ctx.say(`  listening on   ${final.listen.host}:${final.listen.port}`);
  ctx.say(`  players        up to ${final.maxPlayers}`);
  ctx.say('  join code      required (always -- there is no open-hub setting)');
  ctx.say(`  log level      ${final.log.level}`);

  ctx.say('');
  ctx.say(chosen ? 'Your join code, the one you chose' : 'Your join code');
  joinCodeBlock(ctx, credential.secret);

  ctx.say('Next:');
  ctx.say(`  ${PROGRAM} doctor      -- check the configuration and who can reach you`);
  ctx.say(`  ${PROGRAM} start       -- run the hub`);
  return OK;
}

// -------------------------------------------------------------------- start

async function verbStart(ctx) {
  const loaded = loadEffective(ctx);
  const cfg = loaded.config;
  const split = splitWarnings(loaded);
  reportWarnings(ctx, split.warnings, 'config');

  if (!loaded.exists) {
    ctx.warn(`No configuration at ${ctx.file}; running on defaults. \`${PROGRAM} init\` writes one.`);
  }
  /*
   * A group- or world-readable config file stops the hub, it does not merely
   * annoy it.
   *
   * This file is the hub's entire door: every join code is in it, in plaintext,
   * and anyone on this machine who can read it can walk in. Warning and
   * starting anyway would leave the exposure in place for as long as the hub
   * runs -- which is the whole time it matters. `doctor` already calls this a
   * [fail], the plan (§3.5) says the CLI refuses, and server/Dockerfile leans on
   * that promise as the reason /data may be 0700; all three now agree.
   *
   * The escape hatch is deliberately spelled for what it is rather than
   * `--force`: a host who types it is not forcing a step through, they are
   * accepting an insecure config file.
   */
  if (split.permission) {
    if (ctx.flags.insecureConfig !== true) {
      ctx.warn('');
      ctx.warn(`Refusing to start: ${split.permission}`);
      ctx.warn('');
      ctx.warn(`      chmod 600 ${loaded.path}`);
      ctx.warn('');
      ctx.warn(`  then run \`${PROGRAM} start\` again. Until then, anyone else on this`);
      ctx.warn('  machine can read a join code out of that file and walk in.');
      ctx.warn('');
      ctx.warn('  If this machine genuinely needs a looser mode, start with');
      ctx.warn('  --insecure-config and the hub will run on it.');
      ctx.warn('');
      return ERROR;
    }
    ctx.warn('');
    ctx.warn(`warning: --insecure-config. ${split.permission}`);
    ctx.warn('         Starting anyway, on your say-so. What you are accepting: every');
    ctx.warn('         join code in that file is readable by other users of this');
    ctx.warn('         machine, and anyone who reads one can join this hub as a player.');
    ctx.warn(`         \`chmod 600 ${loaded.path}\` ends that at any time.`);
    ctx.warn('');
  }

  /*
   * The passcode gate, checked here rather than left to server.js.
   *
   * server.js has its own refusal and keeps it -- an embedder that calls
   * start() directly must not be able to bypass this. But a host never reads
   * that one: they read whatever this command printed before it exited, so
   * this is where the sentence with the fix in it belongs. Both are refusals,
   * not warnings, because the two failure modes here are "anyone can walk in"
   * and "nobody can get in", and a hub that runs in either state is a hub
   * whose symptoms show up hours later, on someone else's screen.
   */
  const active = auth.activeCredentials(cfg.auth.credentials);
  if (!cfg.auth.required) {
    ctx.warn('');
    ctx.warn('Refusing to start: auth.required is false, and a passcode is required.');
    ctx.warn('');
    ctx.warn(`      ${PROGRAM} config set auth.required true`);
    ctx.warn(`      ${PROGRAM} invite`);
    ctx.warn('');
    ctx.warn('  A hub with no passcode admits anyone who finds the port, which is');
    ctx.warn('  not something this software supports any more -- in game or here.');
    ctx.warn(`  \`${PROGRAM} invite\` prints a code to hand to your friends;`);
    ctx.warn(`  \`${PROGRAM} invite --code A7K3P9\` sets one you choose.`);
    ctx.warn('');
    return ERROR;
  }
  if (active.length === 0) {
    ctx.warn('');
    ctx.warn('Refusing to start: this hub has no usable passcode, so nobody could');
    ctx.warn('join it.');
    ctx.warn('');
    ctx.warn(`      ${PROGRAM} invite`);
    ctx.warn('');
    const total = Array.isArray(cfg.auth.credentials) ? cfg.auth.credentials.length : 0;
    if (total > 0) {
      ctx.warn(`  ${total} code(s) are configured and every one of them is revoked,`);
      ctx.warn(`  expired or used up. \`${PROGRAM} invite list\` says which is which.`);
    } else {
      ctx.warn(`  There are no codes configured at all. \`${PROGRAM} invite\` mints one,`);
      ctx.warn(`  or \`${PROGRAM} invite --code A7K3P9\` sets one you choose.`);
    }
    ctx.warn('');
    return ERROR;
  }

  if (Array.isArray(cfg.allowlist) && cfg.allowlist.length > 0) {
    ctx.say(`Allowlist is active: only ${cfg.allowlist.length} address(es) may connect.`);
  }
  printLines(ctx, throttleLines(cfg));
  ctx.say('');

  printLines(ctx, reachability.summary({
    port: cfg.listen.port,
    host: cfg.listen.host,
  }));
  ctx.say('');

  const logger = makeLog(cfg, ctx.stdout);

  let mapping = null;
  if (cfg.network.upnp.enabled) {
    ctx.say('UPnP is enabled; asking the router to forward the port...');
    const result = await upnp.addMapping({
      port: cfg.listen.port,
      leaseSeconds: cfg.network.upnp.leaseSeconds,
      description: 'RBY MMO hub',
    });
    if (result.ok) {
      mapping = result;
      ctx.say(`  forwarded TCP ${result.port} to ${result.internalAddress}` +
        (result.permanent
          ? ' with a permanent mapping (this router refuses leases; `upnp disable` removes it)'
          : ` for ${result.leaseSeconds}s, renewed by the router until this hub stops`));
    } else {
      ctx.warn(`  UPnP failed: ${result.error}`);
      ctx.warn('  The hub still starts; friends outside this network may not reach it.');
    }
    ctx.say('');
  }

  /*
   * Give the port back before the process goes.
   *
   * This used to be registered on SIGINT/SIGTERM here and fired
   * fire-and-forget, which never actually worked: removeMapping needs an SSDP
   * discovery *and* a SOAP POST, while server.js's own signal handler calls
   * process.exit(0) the moment close() settles -- so the removal was torn down
   * mid-flight, and process.exit does not fire 'beforeExit' either, so that
   * fallback never ran. The port stayed forwarded on the router after every
   * Ctrl-C and every `docker stop`, which is exactly the residual exposure the
   * removal exists to bound (plan §3.7) and exactly what `upnp enable` promises
   * does not happen.
   *
   * So it is handed to server.js's `onShutdown` hook instead: close() awaits it
   * before resolving, and the signal handler exits only after close() resolves.
   * One place, awaited, ahead of the exit.
   *
   * Bounded, and never fatal: an unreachable router costs a line of output and
   * the mapping's own lease cleans up after it. A hub that will not stop would
   * be the worse bug.
   */
  let unmapped = false;
  const dropMapping = async () => {
    if (unmapped || !mapping) return;
    unmapped = true; // once, whichever path gets here first
    const { port, device } = mapping;
    mapping = null;

    ctx.say(`Removing the UPnP mapping for TCP ${port}...`);
    try {
      const result = await withDeadline(upnp.removeMapping({ port, device }), UNMAP_TIMEOUT_MS);
      if (result === TIMED_OUT) {
        ctx.warn(`  the router did not answer within ${UNMAP_TIMEOUT_MS}ms; stopping ` +
          'anyway. A leased mapping expires on its own; `upnp disable` removes a permanent one.');
      } else if (result && result.ok) {
        ctx.say(result.alreadyGone ? '  there was no mapping left to remove' : '  removed');
      } else {
        ctx.warn(`  could not remove it: ${result && result.error ? result.error : 'unknown error'}`);
        ctx.warn(`  \`${PROGRAM} upnp disable\` tries again; a leased mapping expires on its own.`);
      }
    } catch (err) {
      ctx.warn(`  could not remove it: ${err && err.message ? err.message : err}`);
    }
  };

  let server;
  try {
    // Lazily required: see the header. Everything else in this CLI has to keep
    // working when this module is missing or mid-rewrite.
    server = require('./server.js');
  } catch (err) {
    ctx.warn(`Could not start: the server module is not available (${err.message}).`);
    ctx.warn('Every other command still works; this is the one that needs it.');
    return ERROR;
  }
  if (!server || typeof server.start !== 'function') {
    ctx.warn('Could not start: lib/server.js does not export start().');
    return ERROR;
  }

  let handle;
  try {
    handle = await server.start({
      config: cfg,
      log: logger,
      configPath: ctx.file,
      // Awaited by close(), bounded by server.js's own shutdown budget on top
      // of this one's. See dropMapping above for why it cannot live on a
      // signal handler here.
      onShutdown: dropMapping,
    });
  } catch (err) {
    ctx.warn(`The hub failed to start: ${err && err.message ? err.message : err}`);
    return ERROR;
  }

  // The handle's shape belongs to server.js, not here. Wait on whichever of
  // the usual spellings it offers; if it offers none, the listening socket is
  // holding the event loop open and this process ends when the hub does.
  try {
    if (handle && typeof handle.closed === 'object' && handle.closed &&
        typeof handle.closed.then === 'function') {
      await handle.closed;
    } else if (handle && typeof handle.wait === 'function') {
      await handle.wait();
    } else if (handle && typeof handle.done === 'object' && handle.done &&
        typeof handle.done.then === 'function') {
      await handle.done;
    } else {
      await new Promise(() => {});
    }
  } catch (err) {
    ctx.warn(`The hub stopped with an error: ${err && err.message ? err.message : err}`);
    return ERROR;
  }

  // Belt and braces for the path that never goes through close() -- a hub that
  // ended on its own. A no-op when onShutdown already ran.
  await dropMapping();
  return OK;
}

// ------------------------------------------------------------------- status

function describeValue(dotted, value) {
  if (dotted === 'auth.credentials') {
    const count = Array.isArray(value) ? value.length : 0;
    const active = auth.activeCredentials(value).length;
    return `${count} code(s), ${active} usable  (invite / revoke / invite list)`;
  }
  if (Array.isArray(value)) {
    return value.length === 0 ? '(empty)' : value.join(', ');
  }
  return String(value);
}

function verbStatus(ctx) {
  const loaded = loadEffective(ctx);
  const split = splitWarnings(loaded);
  reportWarnings(ctx, split.warnings, 'config');

  // Redacted, always. `status` is the command a host runs while somebody is
  // watching their screen.
  const shown = config.redact(loaded.config);

  ctx.say(`Configuration file: ${loaded.path}${loaded.exists ? '' : '  (does not exist yet)'}`);
  if (split.permission) ctx.say(`  warning: ${split.permission}`);
  ctx.say('');

  const rows = config.LEAF_PATHS.map((dotted) => [
    dotted,
    describeValue(dotted, config.getPath(shown, dotted)),
    loaded.sources[dotted] || 'default',
  ]);

  const nameWidth = Math.max(...rows.map((row) => row[0].length), 'SETTING'.length);
  const valueWidth = Math.max(...rows.map((row) => row[1].length), 'VALUE'.length);

  ctx.say(`${pad('SETTING', nameWidth)}  ${pad('VALUE', valueWidth)}  FROM`);
  for (const [name, value, source] of rows) {
    ctx.say(`${pad(name, nameWidth)}  ${pad(value, valueWidth)}  ${source}`);
  }

  ctx.say('');
  ctx.say('FROM: flag = this command line, env = an RBY_MMO_* variable,');
  ctx.say('      file = the configuration file, default = built in.');
  ctx.say('Join codes are masked here. `invite list --reveal` prints them.');

  ctx.say('');
  printLines(ctx, throttleLines(loaded.config));
  for (const concern of throttleConcerns(loaded.config)) ctx.say(`  note: ${concern}`);
  return OK;
}

// ------------------------------------------------------------------- config

const UNSETTABLE = {
  'auth.credentials':
    'Join codes are not edited as text -- a mistyped one locks everybody out ' +
    `silently. Use \`${PROGRAM} invite\` to mint one and \`${PROGRAM} revoke <id>\` ` +
    'to withdraw it.',
};

function verbConfig(ctx, rest) {
  const action = rest[0];

  if (!action || action === 'list') {
    const loaded = loadEffective(ctx);
    reportWarnings(ctx, loaded.warnings, 'config');
    const shown = config.redact(loaded.config);
    const width = Math.max(...config.LEAF_PATHS.map((p) => p.length));
    for (const dotted of config.LEAF_PATHS) {
      const bounds = config.BOUNDS[dotted];
      const range = bounds ? `   (${bounds[0]}-${bounds[1]})` : '';
      ctx.say(`${pad(dotted, width)}  ${describeValue(dotted, config.getPath(shown, dotted))}${range}`);
    }
    return OK;
  }

  if (action === 'get') {
    const dotted = rest[1];
    if (!dotted) {
      ctx.warn(`Usage: ${PROGRAM} config get <path>`);
      return USAGE;
    }
    if (!config.LEAF_PATHS.includes(dotted)) {
      ctx.warn(`Unknown setting "${dotted}". \`${PROGRAM} config list\` prints every one.`);
      return USAGE;
    }
    const loaded = loadEffective(ctx);
    const shown = config.redact(loaded.config);
    const value = config.getPath(shown, dotted);
    ctx.say(typeof value === 'object' ? JSON.stringify(value, null, 2) : String(value));
    return OK;
  }

  if (action === 'set') {
    const dotted = rest[1];
    const raw = rest.length > 2 ? rest.slice(2).join(' ') : undefined;
    if (!dotted || raw === undefined) {
      ctx.warn(`Usage: ${PROGRAM} config set <path> <value>`);
      return USAGE;
    }
    if (UNSETTABLE[dotted] || dotted.startsWith('auth.credentials')) {
      ctx.warn(UNSETTABLE['auth.credentials']);
      return USAGE;
    }
    if (!config.LEAF_PATHS.includes(dotted)) {
      ctx.warn(`Unknown setting "${dotted}". \`${PROGRAM} config list\` prints every one.`);
      return USAGE;
    }
    if (dotted === 'version') {
      ctx.warn('version is the config file\'s schema version, not a setting. It is');
      ctx.warn('maintained by this software so older files keep loading.');
      return USAGE;
    }

    const loaded = requireExistingConfig(ctx);
    if (!loaded) return ERROR;
    const cfg = loaded.config;

    let value = raw;
    if (dotted === 'bans' || dotted === 'allowlist') {
      // Lists go through the same normaliser the ban verb uses, so a value set
      // this way cannot end up in a shape the limiter will not match.
      const entries = [];
      for (const piece of String(raw).split(/[\s,]+/)) {
        if (!piece) continue;
        const ip = limits.normalizeIp(piece);
        if (!ip) {
          ctx.warn(`"${piece}" is not an address this can normalise.`);
          return USAGE;
        }
        entries.push(ip);
      }
      value = entries;
    }

    const before = JSON.stringify(config.getPath(cfg, dotted));
    config.setPath(cfg, dotted, value);

    // Validate *before* saving and report every adjustment, so a host who
    // typed 9999 is told it became 64 now, rather than discovering it later
    // from a log line they were not reading.
    const checked = config.validate(cfg);
    const after = config.getPath(checked.config, dotted);
    for (const warning of checked.warnings) ctx.say(`adjusted: ${warning}`);

    if (!saveConfig(ctx, checked.config)) return ERROR;

    ctx.say(`${dotted} = ${describeValue(dotted, after)}`);
    if (JSON.stringify(after) === before) {
      ctx.say('(unchanged -- it was already that)');
    }
    /*
     * Still settable -- a config file is a config file, and a host who is
     * scripting one, or reproducing a report, should not be fought by their
     * own tool. But it is a configuration the hub will not run, so it is
     * answered here rather than half an hour later at `start`.
     */
    if (dotted === 'auth.required' && after === false) {
      ctx.warn('warning: a passcode is required, so this is a configuration the hub');
      ctx.warn(`         will not run -- \`${PROGRAM} start\` refuses it and says so.`);
      ctx.warn(`         \`${PROGRAM} config set auth.required true\` puts it back.`);
    }
    if (config.ENV_MAP && Object.values(config.ENV_MAP).includes(dotted)) {
      const name = Object.keys(config.ENV_MAP).find((key) => config.ENV_MAP[key] === dotted);
      if (ctx.env && ctx.env[name] !== undefined && ctx.env[name] !== '') {
        ctx.say(`note: ${name} is set in this environment and outranks the file,`);
        ctx.say(`      so the hub will still use ${ctx.env[name]} until it is unset.`);
      }
    }
    /*
     * "Restart the hub" is the honest answer for a bind-time parameter and
     * the wrong one for the MOTD, which reload() re-applies along with the
     * join codes, bans and the allowlist. A host told to restart a shared
     * world to change a greeting would either do it -- and throw everybody
     * out over a sentence -- or learn to ignore this line.
     */
    if (dotted === 'motd') {
      ctx.say('A running hub picks this up on a reload; no restart, nobody dropped:');
      ctx.say(`    kill -HUP $(pgrep -f '${PROGRAM}.js start')   # bare node`);
      ctx.say('    docker compose kill -s SIGHUP hub              # docker');
      ctx.say('Players already in the world keep the greeting they were shown; the');
      ctx.say('new one goes to everybody who joins after the reload.');
    } else {
      ctx.say('Restart the hub for this to take effect.');
    }
    return OK;
  }

  ctx.warn(`Unknown config command "${action}".`);
  printLines(ctx, HELP.config);
  return USAGE;
}

// ------------------------------------------------------------------ invites

function credentialState(credential, now) {
  if (credential.revoked) return 'revoked';
  if (credential.expiresAt) {
    const at = Date.parse(credential.expiresAt);
    if (!Number.isFinite(at)) return 'unreadable expiry';
    if (at <= now) return 'expired';
  }
  if (credential.maxUses !== null && credential.maxUses !== undefined &&
      Number(credential.uses || 0) >= Number(credential.maxUses)) {
    return 'used up';
  }
  return auth.isActive(credential, now) ? 'active' : 'unusable';
}

function shortDate(value) {
  if (!value) return '-';
  const at = Date.parse(value);
  if (!Number.isFinite(at)) return String(value).slice(0, 19);
  return new Date(at).toISOString().replace('T', ' ').slice(0, 16);
}

function verbInviteList(ctx) {
  const loaded = loadEffective(ctx);
  reportWarnings(ctx, loaded.warnings, 'config');

  const credentials = loaded.config.auth.credentials;
  if (!credentials.length) {
    ctx.say('No join codes.');
    if (loaded.config.auth.required) {
      ctx.say(`This hub requires one, so nobody can join. \`${PROGRAM} invite\` mints one.`);
    }
    return OK;
  }

  const reveal = ctx.flags.reveal === true;
  const shown = reveal ? credentials : maskedCredentials(credentials);
  const now = Date.now();

  /*
   * KIND, not a bare yes/no: this column answers "what does this code open",
   * and both of its answers should be readable without the header. ADMIN is
   * shouted and `player` is not, on purpose -- the row worth noticing in a
   * list of twenty is the privileged one, and it is marked whether or not
   * --reveal was given, because what a code unlocks is not a secret. Read
   * through auth.isAdminCredential so this table and the door that marks the
   * connection cannot come to different readings of the same flag.
   */
  const rows = credentials.map((credential, index) => [
    credential.id || '-',
    credential.label || '-',
    shortDate(credential.createdAt),
    credential.expiresAt ? shortDate(credential.expiresAt) : 'never',
    credential.maxUses ? `${credential.uses || 0}/${credential.maxUses}` : String(credential.uses || 0),
    credentialState(credential, now),
    auth.isAdminCredential(credential) ? 'ADMIN' : 'player',
    shown[index] ? shown[index].secret : '-',
  ]);

  const headers = ['ID', 'LABEL', 'CREATED', 'EXPIRES', 'USES', 'STATUS', 'KIND', 'CODE'];
  const widths = headers.map((header, column) =>
    Math.max(header.length, ...rows.map((row) => String(row[column]).length)));

  ctx.say(headers.map((header, column) => pad(header, widths[column])).join('  ').trimEnd());
  for (const row of rows) {
    ctx.say(row.map((cell, column) => pad(cell, widths[column])).join('  ').trimEnd());
  }

  ctx.say('');
  if (credentials.some((credential) => auth.isAdminCredential(credential))) {
    ctx.say('KIND ADMIN: joins the game like any code, but the hub marks the');
    ctx.say('connection for the operator features arriving in game later. Here that');
    ctx.say('mark is the word ADMIN in this column; in the rosters -- status.json,');
    ctx.say('`players --json`, and the `who` answer on the admin socket -- it is an');
    ctx.say(`\`admin\` flag on the connection. \`${PROGRAM} revoke <id>\` takes one back.`);
  } else {
    ctx.say(`KIND: none of these is an admin code. \`${PROGRAM} invite --admin\` mints`);
    ctx.say('one; the hub marks that connection, and this column reads ADMIN for it.');
  }
  ctx.say('');
  if (reveal) {
    ctx.say('Codes are shown in full because --reveal was given. Anything that');
    ctx.say('records this terminal now holds them.');
  } else {
    ctx.say('Codes are masked. --reveal prints them in full.');
  }
  return OK;
}

function verbInvite(ctx, rest) {
  if (rest[0] === 'list') return verbInviteList(ctx);
  if (rest[0]) {
    ctx.warn(`Unknown invite command "${rest[0]}".`);
    printLines(ctx, HELP.invite);
    return USAGE;
  }

  if (refuseNoAuth(ctx, 'invite')) return USAGE;

  const supplied = suppliedCode(ctx.flags);
  if (supplied.error) {
    for (const line of supplied.error) ctx.warn(line);
    return USAGE;
  }

  let expiresAt = null;
  if (ctx.flags.expires !== undefined && ctx.flags.expires !== false) {
    const ms = parseDuration(ctx.flags.expires);
    if (ms === null) {
      ctx.warn(`--expires "${ctx.flags.expires}" is not a duration this understands.`);
      ctx.warn('Accepted forms: 30m (minutes), 24h (hours), 7d (days).');
      return USAGE;
    }
    expiresAt = new Date(Date.now() + ms).toISOString();
  }

  let maxUses = null;
  if (ctx.flags.uses !== undefined && ctx.flags.uses !== false) {
    const n = Math.floor(Number(ctx.flags.uses));
    if (!Number.isFinite(n) || n < 1) {
      ctx.warn(`--uses "${ctx.flags.uses}" is not a positive whole number.`);
      return USAGE;
    }
    maxUses = n;
  }

  /*
   * `--admin` is a switch (see SWITCHES), so the plain spelling arrives as
   * `true` and `--no-admin` as `false`. `--admin=true` and `--admin=off` are
   * still handed through as *strings* by the parser, and those are read here
   * rather than quietly discarded: a host who typed `--admin=true`, was given
   * a player's code, and read "New join code" without the word admin in it
   * has been told the truth in a way that is very easy to miss. Anything that
   * is neither a yes nor a no is a usage error -- this flag never guesses in
   * favour of privilege.
   */
  let admin = false;
  if (ctx.flags.admin !== undefined) {
    const spelled = String(ctx.flags.admin).trim().toLowerCase();
    if (ctx.flags.admin === true || ['true', 'yes', 'on', 'y', '1'].includes(spelled)) {
      admin = true;
    } else if (!saysNo(ctx.flags.admin)) {
      ctx.warn(`--admin takes no value: write \`${PROGRAM} invite --admin\`.`);
      ctx.warn('Nothing has been minted, because an admin code is not something to');
      ctx.warn('hand out on a guess at what was meant.');
      return USAGE;
    }
  }

  const label = typeof ctx.flags.label === 'string' && ctx.flags.label
    ? ctx.flags.label
    : (admin ? 'Admin' : 'Invite');

  const loaded = requireExistingConfig(ctx);
  if (!loaded) return ERROR;
  const cfg = loaded.config;

  /*
   * Two credentials holding the same passcode is a state with no good
   * behaviour: verify() matches whichever comes first, so the second one's
   * expiry and use budget are quietly never spent, and revoking "the" code
   * leaves the other one letting people in. Refused rather than merged --
   * merging would mean silently choosing which of the two sets of limits the
   * host meant.
   */
  if (supplied.code) {
    const clash = cfg.auth.credentials.find((credential) =>
      auth.normalizeCode(credential.secret) === supplied.code);
    if (clash) {
      ctx.warn(`That passcode is already configured, as ${clash.id} (${clash.label}).`);
      ctx.warn(`\`${PROGRAM} invite list\` shows it${clash.revoked ? '; it is revoked' : ''}. ` +
        `Revoke it with \`${PROGRAM} revoke ${clash.id}\` before reusing the code,`);
      ctx.warn('or pick another one -- two entries with the same code cannot both');
      ctx.warn('carry their own expiry and use count.');
      return ERROR;
    }
  }

  let credential;
  try {
    credential = auth.newCredential({ label, expiresAt, maxUses, admin, secret: supplied.code });
  } catch (err) {
    ctx.warn(`Could not mint a join code: ${err.message}`);
    return ERROR;
  }

  cfg.auth.credentials.push(credential);
  if (!saveConfig(ctx, cfg)) return ERROR;

  const notes = [];
  if (expiresAt) notes.push(`It stops working at ${shortDate(expiresAt)} UTC.`);
  if (maxUses) notes.push(`It can be used ${maxUses} time(s).`);
  if (admin && !expiresAt) {
    // Said once, where the code is, and only when there is no expiry to say
    // instead: a stolen admin code is worth more than a stolen player's, and
    // an end date is the one protection that does not depend on noticing.
    notes.push('');
    notes.push('It has no expiry. An admin code is worth more to a thief than a');
    notes.push('player\'s one is, so if this is for one evening or one person,');
    notes.push('mint it with `--expires 24h` and let it stop working on its own.');
  }

  ctx.say(`New ${admin ? 'admin ' : ''}join code (id ${credential.id}, ${credential.label})`);
  joinCodeBlock(ctx, credential.secret, notes, { admin });

  if (!cfg.auth.required) {
    ctx.warn('warning: auth.required is false in this config, and a passcode is');
    ctx.warn(`         required -- \`${PROGRAM} start\` refuses to run like this.`);
    ctx.warn(`         \`${PROGRAM} config set auth.required true\` fixes it.`);
  }
  /*
   * Both paths are true and the reload is the cheaper one, so both are said.
   * reload() re-reads the credential list along with the bans, the allowlist
   * and the MOTD -- a running world does not have to be emptied to add a
   * player. "Restart the hub" on its own taught hosts to drop everybody over
   * an invite.
   */
  ctx.say('A running hub picks this code up on a reload; a restart works too:');
  ctx.say(`    kill -HUP $(pgrep -f '${PROGRAM}.js start')   # bare node`);
  ctx.say('    docker compose kill -s SIGHUP hub              # docker');
  if (admin) {
    // Nothing extra to bring up for an admin code: the mark is read off the
    // credential at join time, so a reload is the whole of it.
    ctx.say('That is all an admin code needs: the mark is read off the credential');
    ctx.say('when somebody joins with it, so there is nothing further to start.');
  }
  return OK;
}

function verbRevoke(ctx, rest) {
  const id = rest[0];
  if (!id) {
    ctx.warn(`Usage: ${PROGRAM} revoke <id>   (ids come from \`${PROGRAM} invite list\`)`);
    return USAGE;
  }

  const loaded = requireExistingConfig(ctx);
  if (!loaded) return ERROR;
  const cfg = loaded.config;

  const exact = cfg.auth.credentials.filter((credential) => credential.id === id);
  const prefixed = cfg.auth.credentials.filter((credential) =>
    typeof credential.id === 'string' && credential.id.startsWith(id));
  const matches = exact.length ? exact : prefixed;

  if (matches.length === 0) {
    ctx.warn(`No join code with id "${id}". \`${PROGRAM} invite list\` shows them.`);
    return ERROR;
  }
  if (matches.length > 1) {
    ctx.warn(`"${id}" matches ${matches.length} join codes: ` +
      `${matches.map((credential) => credential.id).join(', ')}. Give a longer id.`);
    return ERROR;
  }

  const credential = matches[0];
  if (credential.revoked) {
    ctx.say(`${credential.id} was already revoked.`);
    return OK;
  }
  credential.revoked = true;
  if (!saveConfig(ctx, cfg)) return ERROR;

  ctx.say(`Revoked ${credential.id} (${credential.label}). Anyone holding that code`);
  ctx.say('is refused from the next reload onwards -- or the next restart:');
  ctx.say(`    kill -HUP $(pgrep -f '${PROGRAM}.js start')   # bare node`);
  ctx.say('    docker compose kill -s SIGHUP hub              # docker');
  ctx.say('Players already connected keep the connection they have (`kick` ends');
  ctx.say('that), and a connection that joined on an admin code keeps its mark');
  ctx.say('until it ends. Revoking decides who may join next, not who is in.');

  // A warning, not a refusal: locking yourself out is sometimes exactly what
  // you meant to do, and the software should not argue with a deliberate act.
  const remaining = auth.activeCredentials(cfg.auth.credentials).length;
  if (remaining === 0 && cfg.auth.required) {
    ctx.warn('');
    ctx.warn('warning: that was the last usable join code. This hub requires one,');
    ctx.warn(`         so nobody can join until you run \`${PROGRAM} invite\`.`);
  }
  return OK;
}

// ------------------------------------------------------------ bans, allowlist

function printList(ctx, title, entries) {
  if (!entries.length) {
    ctx.say(`${title}: (empty)`);
    return;
  }
  ctx.say(`${title}:`);
  for (const entry of entries) ctx.say(`  ${entry}`);
}

function verbBan(ctx, rest) {
  const given = rest[0];
  if (!given) {
    ctx.warn(`Usage: ${PROGRAM} ban <ip> [--reason TEXT]`);
    return USAGE;
  }
  // Normalised first, always: ::ffff:203.0.113.7 and 203.0.113.7 are the same
  // peer, and a ban stored in one spelling silently misses the other.
  const ip = limits.normalizeIp(given);
  if (!ip) {
    ctx.warn(`"${given}" is not an address this can normalise.`);
    return USAGE;
  }

  const loaded = requireExistingConfig(ctx);
  if (!loaded) return ERROR;
  const cfg = loaded.config;

  if (cfg.bans.includes(ip)) {
    ctx.say(`${ip} was already banned.`);
  } else {
    cfg.bans.push(ip);
    if (!saveConfig(ctx, cfg)) return ERROR;
    ctx.say(`Banned ${ip}.`);
  }
  if (typeof ctx.flags.reason === 'string' && ctx.flags.reason) {
    // Honest about the schema: the ban list holds addresses, so the reason is
    // for this terminal only. Storing it inline would break the normalised
    // comparison the limiter does.
    ctx.say(`Reason (not stored -- the ban list holds addresses only): ${ctx.flags.reason}`);
  }
  printList(ctx, 'Banned addresses', cfg.bans);
  ctx.say('Restart the hub to apply it to connections already open.');
  return OK;
}

function verbUnban(ctx, rest) {
  const given = rest[0];
  if (!given) {
    ctx.warn(`Usage: ${PROGRAM} unban <ip>`);
    return USAGE;
  }
  const ip = limits.normalizeIp(given);
  if (!ip) {
    ctx.warn(`"${given}" is not an address this can normalise.`);
    return USAGE;
  }

  const loaded = requireExistingConfig(ctx);
  if (!loaded) return ERROR;
  const cfg = loaded.config;

  const before = cfg.bans.length;
  cfg.bans = cfg.bans.filter((entry) => limits.normalizeIp(entry) !== ip);
  if (cfg.bans.length === before) {
    ctx.say(`${ip} was not banned; nothing to do.`);
    printList(ctx, 'Banned addresses', cfg.bans);
    return OK;
  }
  if (!saveConfig(ctx, cfg)) return ERROR;
  ctx.say(`Unbanned ${ip}.`);
  printList(ctx, 'Banned addresses', cfg.bans);
  return OK;
}

function verbAllow(ctx, rest) {
  const given = rest[0];

  if (!given && ctx.flags.clear !== true) {
    const loaded = loadEffective(ctx);
    reportWarnings(ctx, loaded.warnings, 'config');
    printList(ctx, 'Allowlist', loaded.config.allowlist);
    if (loaded.config.allowlist.length) {
      ctx.say('');
      ctx.say('The allowlist has entries, so ONLY those addresses may connect.');
    } else {
      ctx.say('');
      ctx.say('Empty, so any address may connect (subject to the join code and bans).');
    }
    return OK;
  }

  const loaded = requireExistingConfig(ctx);
  if (!loaded) return ERROR;
  const cfg = loaded.config;

  if (ctx.flags.clear === true) {
    cfg.allowlist = [];
    if (!saveConfig(ctx, cfg)) return ERROR;
    ctx.say('Allowlist cleared. Any address may connect again.');
    printList(ctx, 'Allowlist', cfg.allowlist);
    return OK;
  }

  const ip = limits.normalizeIp(given);
  if (!ip) {
    ctx.warn(`"${given}" is not an address this can normalise.`);
    return USAGE;
  }

  const wasEmpty = cfg.allowlist.length === 0;
  if (cfg.allowlist.includes(ip)) {
    ctx.say(`${ip} was already on the allowlist.`);
  } else {
    if (wasEmpty) {
      // Said before the change lands, plainly, because this is the one command
      // here that can lock a host out of their own hub from a friend's phone.
      ctx.say('This is the first allowlist entry. An allowlist with entries is');
      ctx.say('exclusive: from now on ONLY the addresses below may connect, and');
      ctx.say(`everyone else is refused. \`${PROGRAM} allow --clear\` undoes that.`);
      ctx.say('');
    }
    cfg.allowlist.push(ip);
    if (!saveConfig(ctx, cfg)) return ERROR;
    ctx.say(`Allowed ${ip}.`);
  }
  printList(ctx, 'Allowlist', cfg.allowlist);
  return OK;
}

// ------------------------------------------------------------------- doctor

function mark(ctx, level, line) {
  const tags = { ok: '[ ok ]', warn: '[warn]', fail: '[fail]' };
  ctx.say(`  ${tags[level]} ${line}`);
}

async function verbDoctor(ctx) {
  const loaded = loadEffective(ctx);
  const cfg = loaded.config;
  let failed = false;

  ctx.say(`${PROGRAM} doctor`);
  ctx.say('');
  ctx.say('Configuration');

  if (loaded.exists) {
    mark(ctx, 'ok', `${loaded.path}`);
  } else {
    mark(ctx, 'warn', `no file at ${loaded.path}; running on defaults ` +
      `(\`${PROGRAM} init\` writes one)`);
  }
  const split = splitWarnings(loaded);
  for (const warning of split.warnings) mark(ctx, 'warn', warning);

  if (split.permission) {
    failed = true;
    mark(ctx, 'fail', split.permission);
  } else if (loaded.exists) {
    mark(ctx, 'ok', 'the file is readable only by its owner');
  }

  // Auth. Deliberately counts, never codes -- doctor output is the thing a
  // host pastes into a forum thread when asking for help.
  const credentials = cfg.auth.credentials;
  const active = auth.activeCredentials(credentials);
  if (!cfg.auth.required) {
    // A [fail], not a [warn]: `start` refuses this configuration outright, so
    // doctor saying "warning" about it would be the gentler of two answers
    // that disagree.
    failed = true;
    mark(ctx, 'fail', 'auth.required is false: a passcode is required, and `start` ' +
      `will refuse this config -- run \`${PROGRAM} config set auth.required true\` ` +
      `then \`${PROGRAM} invite\``);
  } else if (active.length === 0) {
    failed = true;
    mark(ctx, 'fail', 'a join code is required and none is usable, so nobody can ' +
      `join -- run \`${PROGRAM} invite\``);
  } else {
    mark(ctx, 'ok', `a join code is required; ${active.length} usable of ${credentials.length}`);
  }

  const now = Date.now();
  const stale = credentials.filter((credential) => {
    const state = credentialState(credential, now);
    return state === 'expired' || state === 'used up' || state === 'unreadable expiry';
  });
  if (stale.length) {
    mark(ctx, 'warn', `${stale.length} join code(s) no longer work ` +
      `(${stale.map((credential) => `${credential.id}: ${credentialState(credential, now)}`).join(', ')})`);
  }

  /*
   * The guess-rate throttle. Configured values only -- see throttleLines():
   * the live counters (`stats().auth`) exist only inside a running hub, and
   * this process is not it. That is stated in the output rather than papered
   * over, because "doctor said nothing about it" must not read as "nobody is
   * trying".
   */
  mark(ctx, 'ok', 'wrong passcodes are throttled: ' +
    `${limitOf(cfg, 'authFailureGrace')} free per address per ` +
    `${humanMs(limitOf(cfg, 'authFailureWindowMs'))}, backing off from ` +
    `${humanMs(limitOf(cfg, 'authBackoffBaseMs'))} to ` +
    `${humanMs(limitOf(cfg, 'authBackoffMaxMs'))}; ` +
    `${limitOf(cfg, 'authGlobalFailures')} hub-wide in ` +
    `${humanMs(limitOf(cfg, 'authGlobalWindowMs'))} shuts new joins for ` +
    `${humanMs(limitOf(cfg, 'authLockoutMs'))}`);
  for (const concern of throttleConcerns(cfg)) mark(ctx, 'warn', concern);
  mark(ctx, 'ok', 'those are the configured limits -- how many wrong passcodes have ' +
    'actually arrived is known only to the hub while it runs, and shows up in its log');

  // Port and bind address.
  const port = cfg.listen.port;
  if (port < 1024) {
    mark(ctx, 'warn', `port ${port} is privileged: on Linux and macOS the hub has ` +
      'to run as root or hold CAP_NET_BIND_SERVICE to bind it');
  } else {
    mark(ctx, 'ok', `port ${port} is in the unprivileged range`);
  }

  const host = cfg.listen.host;
  if (host === '0.0.0.0' || host === '::') {
    mark(ctx, 'ok', `bound to ${host}: every address on this machine accepts connections`);
  } else if (reachability.classifyAddress(host, host.includes(':') ? 'IPv6' : 'IPv4') ===
      reachability.LOOPBACK) {
    failed = true;
    mark(ctx, 'fail', `bound to ${host}, which is this machine talking to itself: ` +
      'no friend can connect. Set listen.host to 0.0.0.0');
  } else {
    mark(ctx, 'warn', `bound to ${host} only; connections to this machine's other ` +
      'addresses are refused');
  }

  // Limits worth a second look.
  if (cfg.limits.perIpConnections >= cfg.maxPlayers) {
    mark(ctx, 'warn', `limits.perIpConnections (${cfg.limits.perIpConnections}) is not ` +
      `below maxPlayers (${cfg.maxPlayers}), so one address could take every seat`);
  }
  if (cfg.limits.idleTimeoutMs <= cfg.limits.handshakeTimeoutMs) {
    mark(ctx, 'warn', 'limits.idleTimeoutMs is not greater than ' +
      'limits.handshakeTimeoutMs, which makes the handshake budget meaningless');
  }
  if (cfg.limits.chatIntervalMs === 0) {
    mark(ctx, 'warn', 'limits.chatIntervalMs is 0: the chat flood gate is off');
  }
  if (cfg.allowlist.length) {
    mark(ctx, 'warn', `the allowlist has ${cfg.allowlist.length} entr(y/ies), so ONLY ` +
      'those addresses may connect');
  }
  if (cfg.bans.length) {
    mark(ctx, 'ok', `${cfg.bans.length} address(es) banned`);
  }

  // Router. Only asked when the host turned UPnP on -- see upnp.js's header.
  ctx.say('');
  ctx.say('Router');
  let external = null;
  if (cfg.network.upnp.enabled) {
    const found = await upnp.discover({ timeoutMs: 3000 });
    if (!found.ok) {
      mark(ctx, 'warn', `UPnP is enabled but no router answered: ${found.error}`);
    } else {
      mark(ctx, 'ok', `router at ${found.router} speaks UPnP`);
      const mapping = await upnp.getMapping({ port, device: found });
      if (mapping.ok && mapping.mapped) {
        mark(ctx, 'ok', `TCP ${port} is forwarded to ${mapping.internalAddress}:` +
          `${mapping.internalPort}` +
          (mapping.leaseSeconds ? ` (lease ${mapping.leaseSeconds}s)` : ' (permanent)'));
      } else if (mapping.ok) {
        mark(ctx, 'warn', `TCP ${port} is not currently forwarded; \`${PROGRAM} start\` ` +
          'asks for it, or `upnp enable` asks now');
      } else {
        mark(ctx, 'warn', `could not read the mapping: ${mapping.error}`);
      }
      const ip = await upnp.externalIp({ device: found });
      if (ip.ok && ip.up) {
        external = ip.address;
        mark(ctx, 'ok', `the router's external address is ${ip.address}`);
      } else if (ip.ok) {
        mark(ctx, 'warn', 'the router reports no external address; its own uplink may be down');
      } else {
        mark(ctx, 'warn', `could not ask the router for its address: ${ip.error}`);
      }
    }
  } else {
    mark(ctx, 'ok', 'UPnP is off. Nothing on this machine asks the router for ' +
      `anything (\`${PROGRAM} upnp enable\` changes that)`);
  }

  ctx.say('');
  printLines(ctx, reachability.summary({ port, host, external }));

  ctx.say('');
  ctx.say(failed
    ? 'Something above would stop players connecting. Fix the [fail] lines.'
    : 'Nothing here would stop players connecting.');
  return failed ? ERROR : OK;
}

// ------------------------------------------------- who is playing, and where

/**
 * A file the hub keeps beside its config. The config path is the one thing a
 * host has already told us (flag, env, cwd, /data in a container), and
 * server.js derives the ranking path from it the same way -- so following it
 * is what makes `--config` point both verbs at the right hub with no second
 * flag to get wrong.
 */
function dataFile(ctx, name) {
  return path.join(path.dirname(path.resolve(ctx.file)), name);
}

/**
 * Read one of them. Three outcomes worth telling apart: not there (which is
 * usually a hub that has never run, and is not an error), there but not
 * readable or not JSON (which is), and a document.
 */
function readJsonFile(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    if (err && err.code === 'ENOENT') return { missing: true };
    return { error: err && err.message ? err.message : String(err) };
  }
  try {
    return { data: JSON.parse(text) };
  } catch (err) {
    return { corrupt: true, error: err && err.message ? err.message : String(err) };
  }
}

function finite(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

/** An age a host reads at a glance. Coarse on purpose: seconds, then minutes. */
function humanAge(ms) {
  const seconds = Math.max(0, Math.round(Number(ms) / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

/*
 * Text out of a file anybody can edit, on its way to a terminal. Control
 * characters in a name would move the cursor, repaint the line or worse, and
 * a trainer name is at most a handful of characters anyway -- so they are
 * flattened and the field is capped. The hub sanitises names on the way in;
 * this is the second half of that, for the file it wrote them to.
 */
function plain(value, max) {
  if (value === null || value === undefined) return '';
  const text = String(value).replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
  const cap = max || 24;
  return text.length > cap ? text.slice(0, cap) : text;
}

/**
 * `PALLET_TOWN` -> `PALLET TOWN`. A display transform and nothing else: the
 * file keeps the engine's own map id, because that is the thing the hub was
 * told and the thing a bug report needs. Null is not a missing value here --
 * it is the hub saying the player is in a battle or a menu, where no position
 * is sent at all (that is why the column shows a dash rather than a blank).
 */
function mapName(value) {
  if (typeof value !== 'string') return null;
  const name = plain(value.replace(/_+/g, ' '), 28).replace(/\s+/g, ' ');
  return name === '' ? null : name;
}

/**
 * How old the snapshot is, and what that means. The three answers are the
 * three states a reader can honestly be in: the hub said goodbye, the hub has
 * gone quiet, or the hub is writing.
 */
function snapshotAge(snapshot, now) {
  // The file says how often it is refreshed, so overdue is measured against
  // the schedule the writer actually keeps rather than the one compiled in
  // here. STATUS_HEARTBEAT_MS is only the answer for a file written before
  // the hub started saying.
  const beat = finite(snapshot.heartbeatMs);
  const heartbeatMs = beat !== null && beat > 0 ? beat : STATUS_HEARTBEAT_MS;
  const staleMs = heartbeatMs * 2.5;

  const stoppedAt = finite(snapshot.stoppedAt);
  if (stoppedAt !== null && stoppedAt > 0) {
    return {
      state: 'stopped', at: stoppedAt, age: Math.max(0, now - stoppedAt), heartbeatMs,
    };
  }
  const updatedAt = finite(snapshot.updatedAt);
  if (updatedAt === null || updatedAt <= 0) return { state: 'undated', age: null, heartbeatMs };
  const age = Math.max(0, now - updatedAt);
  return { state: age > staleMs ? 'stale' : 'live', at: updatedAt, age, heartbeatMs };
}

function printTable(ctx, headers, rows) {
  const widths = headers.map((header, column) =>
    Math.max(header.length, ...rows.map((row) => String(row[column]).length)));
  ctx.say(headers.map((header, column) => pad(header, widths[column])).join('  ').trimEnd());
  for (const row of rows) {
    ctx.say(row.map((cell, column) => pad(cell, widths[column])).join('  ').trimEnd());
  }
}

/*
 * Where to look when the snapshot is not where we looked -- the same shape of
 * answer requireExistingConfig() gives, and for the same reason: the commonest
 * way to arrive here is running the verb on the host when the hub is in a
 * container, and "the hub is not running" would be a confident wrong answer.
 */
function noSnapshotLines(file) {
  return [
    `No status snapshot at ${file}.`,
    '',
    '  The hub writes that file while it runs -- at startup, whenever somebody',
    `  joins or leaves, and every ${humanMs(STATUS_HEARTBEAT_MS)} as a heartbeat -- and leaves it`,
    '  behind on the way out. So there being none means one of three things:',
    '  this hub has not been started since the software gained the file, it',
    '  keeps its files somewhere else, or it has never run at all.',
    '',
    `  The snapshot sits beside the config file, so \`--config <path>\` moves`,
    '  both. If the hub runs in Docker, its files are inside the container:',
    `      docker compose exec hub ${PROGRAM} players`,
  ];
}

/*
 * One frame of the roster, written straight to the streams.
 *
 * `players` is one call of this; `watch` is a call every couple of seconds.
 * It is a function rather than the body of a verb because two commands that
 * read the same file and disagreed about how to say "the hub appears to be
 * down" would be two answers to one question -- and the difficult half of
 * this output is exactly those sentences, not the table.
 *
 * Every borrowed value goes through plain() / mapName() on the way out, on
 * every frame. A repaint is not a reason to start trusting a file, and
 * `watch` is precisely the command that would otherwise keep re-drawing a
 * hand-edited one until something in it moved the cursor.
 *
 * Returns `{ code, state }`: the exit code the single-shot verb reports, and
 * what was found -- so a caller that is going to draw again knows whether it
 * is looking at a hub, at a corpse, or at a file it cannot read.
 */
function renderPlayersFrame(ctx, options = {}) {
  const wantsJson = options.json === true;
  const file = dataFile(ctx, STATUS_FILENAME);
  const read = readJsonFile(file);

  if (read.missing) {
    // Nothing to show is not a failure -- `invite list` with no codes exits 0
    // too. The explanation goes to stderr so `--json` still emits a document
    // a script can parse.
    if (wantsJson) ctx.say('[]');
    for (const line of noSnapshotLines(file)) ctx.warn(line);
    return { code: OK, state: 'missing' };
  }
  if (read.corrupt) {
    // Node quotes the offending bytes back at you in that message, and those
    // bytes came out of a file anybody can edit -- so they go through plain()
    // like every other borrowed string here, generously capped because the
    // position and the snippet are the useful half of the answer.
    ctx.warn(`${file} is not readable as JSON: ${plain(read.error, 200)}`);
    ctx.warn('The hub writes it whole and renames it into place, so a half-written');
    ctx.warn('one should not be possible -- this is a file that has been edited, or');
    ctx.warn('a disk that lost it. Deleting it costs nothing: the hub writes a fresh');
    ctx.warn('one on its next heartbeat.');
    return { code: ERROR, state: 'corrupt' };
  }
  if (read.error) {
    ctx.warn(`Could not read ${file}: ${read.error}`);
    return { code: ERROR, state: 'unreadable' };
  }

  const snapshot = read.data && typeof read.data === 'object' && !Array.isArray(read.data)
    ? read.data : null;
  if (!snapshot) {
    ctx.warn(`${file} does not hold a status snapshot (expected a JSON object).`);
    return { code: ERROR, state: 'not-a-snapshot' };
  }

  const players = Array.isArray(snapshot.players) ? snapshot.players : [];
  const now = options.now === undefined ? Date.now() : options.now;
  const age = snapshotAge(snapshot, now);

  const version = finite(snapshot.version);
  const newer = version !== null && version > 1;

  if (wantsJson) {
    /*
     * Projected, never republished. What goes out is exactly the ten fields
     * the contract names (docs/plans/server-side-listing.md §3, plus `admin`
     * from 0.9.0), read through the same sanitisers the table uses -- so a
     * field a newer hub added, or one a hand-edit slipped in, does not become
     * part of what scripts here are entitled to. `map` keeps the engine's own
     * id rather than the display spelling: the reader wants the thing the hub
     * was told.
     */
    const projected = players.map((player) => {
      const entry = player && typeof player === 'object' ? player : {};
      return {
        name: plain(entry.name) || '-',
        sprite: typeof entry.sprite === 'string' ? plain(entry.sprite, 32) : null,
        map: typeof entry.map === 'string' ? plain(entry.map, 28) : null,
        // Guarded on the type rather than coerced: null here is the hub
        // saying the player is in a battle or a menu and sends no position,
        // and finite(null) is 0 -- a tile nobody is standing on.
        x: typeof entry.x === 'number' ? finite(entry.x) : null,
        y: typeof entry.y === 'number' ? finite(entry.y) : null,
        busy: Boolean(entry.busy),
        party: Boolean(entry.party),
        points: finite(entry.points) || 0,
        ranked: Boolean(entry.ranked),
        // Strictly `true`, the same reading auth.isAdminCredential gives the
        // flag on the credential it came from: a snapshot a hand-edit put a
        // truthy string into does not make a script here believe somebody is
        // an operator. The table does not draw this column; a script that
        // wants to spot the operator's own connection can.
        admin: entry.admin === true,
      };
    });
    ctx.say(JSON.stringify(projected, null, 2));
    // Every honesty note goes to stderr in this mode: the point of --json is
    // that stdout is exactly the array and nothing else.
    if (age.state === 'stopped') {
      ctx.warn(`note: the hub stopped ${humanAge(age.age)} ago; this list is what it left behind.`);
    } else if (age.state === 'stale') {
      ctx.warn(`note: last heartbeat ${humanAge(age.age)} ago, so the hub appears to be down; ` +
        'this list is the last thing it wrote.');
    } else if (age.state === 'undated') {
      ctx.warn('note: the snapshot does not say when it was written, so its age is unknown.');
    }
    if (newer) ctx.warn(`note: snapshot version ${version}; this command reads version 1.`);
    return { code: OK, state: age.state };
  }

  if (newer) {
    ctx.warn(`note: ${file} says version ${version}; this command knows version 1, so`);
    ctx.warn('      anything newer in it is not shown here.');
  }

  const where = [];
  if (snapshot.host !== undefined && snapshot.port !== undefined) {
    where.push(`${plain(snapshot.host, 45)}:${plain(snapshot.port, 5)}`);
  }
  const maxPlayers = finite(snapshot.maxPlayers);

  if (age.state === 'stopped') {
    ctx.say(`The hub stopped ${humanAge(age.age)} ago${where.length ? ` (${where[0]})` : ''}, ` +
      'so nobody is online.');
    ctx.say(`It said so itself, on the way out. \`${PROGRAM} start\` runs it again.`);
    return { code: OK, state: age.state };
  }
  if (age.state === 'stale') {
    ctx.say(`The hub appears to be down: the last heartbeat was ${humanAge(age.age)} ago,`);
    ctx.say(`and a running hub writes one every ${humanMs(age.heartbeatMs)}. It did not stop cleanly --`);
    ctx.say('there is no shutdown recorded in the snapshot -- so this is a crash, a');
    ctx.say('kill, or a machine that went away.');
    ctx.say('');
    if (!players.length) {
      ctx.say('Nobody was online in the last thing it wrote.');
      return { code: OK, state: age.state };
    }
    ctx.say('The last thing it wrote, which is not who is online now:');
    ctx.say('');
  } else if (age.state === 'undated') {
    ctx.say(`${file} does not say when it was written, so how current this is`);
    if (!players.length) {
      // No table to take at face value, and no legend worth printing under an
      // empty one.
      ctx.say('cannot be told from here. Nobody was online in it.');
      return { code: OK, state: age.state };
    }
    ctx.say('cannot be told from here. Taking it at face value:');
    ctx.say('');
  } else if (!players.length) {
    ctx.say(`Nobody is online${where.length ? ` on ${where[0]}` : ''} ` +
      `(snapshot ${humanAge(age.age)} old).`);
    return { code: OK, state: age.state };
  } else {
    const seats = maxPlayers !== null ? ` of ${maxPlayers}` : '';
    ctx.say(`${players.length} player(s) online${seats}` +
      `${where.length ? ` on ${where[0]}` : ''}, snapshot ${humanAge(age.age)} old.`);
    ctx.say('');
  }

  const rows = players.map((player) => {
    const entry = player && typeof player === 'object' ? player : {};
    const location = mapName(entry.map);
    const status = entry.busy ? 'BUSY' : (entry.party ? 'PARTY' : '');
    const points = entry.ranked ? String(finite(entry.points) === null ? 0 : finite(entry.points)) : '';
    return [plain(entry.name) || '-', location || '-', status, points];
  });

  printTable(ctx, ['NAME', 'LOCATION', 'STATUS', 'POINTS'], rows);

  ctx.say('');
  if (rows.some((row) => row[1] === '-')) {
    ctx.say('A dash for LOCATION is a player in a battle or a menu: the hub is not');
    ctx.say('sent a position while they are there, so it does not have one to show.');
  }
  ctx.say('STATUS is BUSY in a trade or battle, PARTY in a two-player party.');
  ctx.say('POINTS is the ranked score, blank for a player who is not ranked --');
  ctx.say(`\`${PROGRAM} ranking\` prints the whole board, including the players`);
  ctx.say('who are not online now.');
  return { code: OK, state: age.state };
}

function verbPlayers(ctx) {
  return renderPlayersFrame(ctx, { json: ctx.flags.json === true }).code;
}

// -------------------------------------------------------------------- watch

/*
 * Clear and home, on a terminal and nowhere else.
 *
 * `watch` piped into a file, or into a test's sink, must produce text a human
 * can read afterwards -- and an escape sequence in a log is at best noise and
 * at worst a cursor movement in whatever eventually cats it. isTTY is the
 * only honest signal for "somebody is looking at this right now", so it is
 * the whole gate. Written straight at the stream rather than through say(),
 * which would append a newline the sequence does not want.
 */
function clearScreen(ctx) {
  if (!ctx.stdout || !ctx.stdout.isTTY) return false;
  try {
    ctx.stdout.write('\u001b[H\u001b[2J');
  } catch (err) {
    /* a stream that will not take an escape sequence will not take a frame
     * either; the write below reports that in its own way */
    return false;
  }
  return true;
}

/** HH:MM:SS, local, so "last read" means something at a glance. */
function clockTime(date) {
  const pair = (value) => String(value).padStart(2, '0');
  return `${pair(date.getHours())}:${pair(date.getMinutes())}:${pair(date.getSeconds())}`;
}

/**
 * `--interval`, clamped rather than refused -- the same bargain config.js
 * makes with every out-of-range number: take what was meant, say what it
 * became. A value that is not a number at all is a different thing and is a
 * usage error, because there is nothing to take.
 */
function watchInterval(raw) {
  if (raw === undefined) return { seconds: WATCH_INTERVAL_S };
  if (raw === true || raw === false || String(raw).trim() === '') {
    return { error: '--interval needs a number of seconds after it, e.g. `--interval 5`.' };
  }
  const asked = Number(String(raw).trim());
  if (!Number.isFinite(asked)) {
    return { error: `--interval "${plain(raw, 16)}" is not a number of seconds.` };
  }
  const rounded = Math.round(asked);
  const seconds = Math.min(WATCH_INTERVAL_MAX_S, Math.max(WATCH_INTERVAL_MIN_S, rounded));
  return { seconds, adjusted: seconds !== rounded ? rounded : null };
}

async function verbWatch(ctx) {
  const interval = watchInterval(ctx.flags.interval);
  if (interval.error) {
    ctx.warn(interval.error);
    return USAGE;
  }
  if (interval.adjusted !== null && interval.adjusted !== undefined) {
    ctx.warn(`adjusted: --interval ${interval.adjusted} is outside ` +
      `${WATCH_INTERVAL_MIN_S}-${WATCH_INTERVAL_MAX_S}s; using ${interval.seconds}s.`);
  }

  const options = { json: ctx.flags.json === true };

  /*
   * One frame and out. This is the path a script takes, the path a suite can
   * assert on, and the only path that has an exit code worth reading -- so it
   * reports the frame's own, exactly as `players` would.
   */
  if (ctx.flags.once === true) {
    clearScreen(ctx);
    return renderPlayersFrame(ctx, options).code;
  }

  /*
   * Otherwise this runs until it is told to stop, and the only thing that
   * tells it is a signal. Handlers are attached for the duration and removed
   * in a finally -- run() is called in-process by the test suite and by
   * anything that embeds this CLI, and a verb that left a listener on
   * `process` behind would leak one per invocation and, worse, keep
   * answering Ctrl-C after it had returned.
   *
   * Stopping is a success: the host asked for a view and then closed it.
   */
  let stopped = false;
  let wake = null;
  const onSignal = () => {
    stopped = true;
    if (wake) wake();
  };
  const signals = ['SIGINT', 'SIGTERM'];
  const canSignal = typeof process !== 'undefined' && typeof process.on === 'function';
  if (canSignal) for (const name of signals) process.on(name, onSignal);

  try {
    let first = true;
    while (!stopped) {
      // Without a terminal to clear, frames simply follow one another; a
      // blank line between them is the whole separator, and it is one a
      // reader (or a grep) can live with.
      if (!clearScreen(ctx) && !first) ctx.say('');
      first = false;

      renderPlayersFrame(ctx, options);
      if (!options.json) {
        ctx.say('');
        ctx.say(`Read at ${clockTime(new Date())}, again in ${interval.seconds}s. ` +
          'Ctrl-C stops.');
      }

      if (stopped) break;
      await new Promise((resolve) => {
        const timer = setTimeout(() => { wake = null; resolve(); }, interval.seconds * 1000);
        wake = () => { clearTimeout(timer); wake = null; resolve(); };
      });
    }
  } finally {
    if (canSignal) for (const name of signals) process.removeListener(name, onSignal);
  }

  ctx.say('');
  ctx.say('Stopped watching. Nothing here ever spoke to the hub -- it only read');
  ctx.say('the file, so the world carries on exactly as it was.');
  return OK;
}

// ------------------------------------------------------------------ ranking

function verbRanking(ctx) {
  const wantsJson = ctx.flags.json === true;
  const wantsAll = ctx.flags.all === true;
  const file = dataFile(ctx, RANKING_FILENAME);
  const read = readJsonFile(file);

  if (read.missing) {
    if (wantsJson) ctx.say('[]');
    ctx.warn(`No ranking file at ${file}.`);
    ctx.warn('');
    ctx.warn('  The hub writes one within a second of the first ranked battle being');
    ctx.warn('  settled, and not before -- so this is a hub where nobody has finished');
    ctx.warn('  a ranked battle yet, or one whose files live somewhere else.');
    ctx.warn(`  The ranking sits beside the config file, so \`--config <path>\` moves both;`);
    ctx.warn('  in Docker it is inside the container:');
    ctx.warn(`      docker compose exec hub ${PROGRAM} ranking`);
    return OK;
  }
  if (read.corrupt) {
    // Sanitised for the same reason verbPlayers does it: the parse error
    // carries the file's own bytes, escapes and all.
    ctx.warn(`${file} is not readable as JSON: ${plain(read.error, 200)}`);
    ctx.warn('The hub writes it whole and renames it into place, so this is a file');
    ctx.warn('that has been edited by hand or damaged. The hub will refuse to load');
    ctx.warn('it too, and start the season empty rather than guess.');
    return ERROR;
  }
  if (read.error) {
    ctx.warn(`Could not read ${file}: ${read.error}`);
    return ERROR;
  }

  // Both shapes the hub itself accepts on the way in: the documented
  // `{ version, players }` object, and a bare array from an older file.
  const raw = read.data;
  const stored = Array.isArray(raw) ? raw : (raw && Array.isArray(raw.players) ? raw.players : null);
  if (!stored) {
    ctx.warn(`${file} does not hold a ranking (expected { "version": 1, "players": [...] }).`);
    return ERROR;
  }

  /*
   * Zero is filtered, and the order is points-then-name, because that is what
   * Board.top does (rank.js) and what every player already sees in game. Two
   * lists of the same board that disagree about who is third would be worse
   * than one list that is a second out of date.
   */
  const ranked = stored
    .filter((row) => row && typeof row === 'object' && (finite(row.points) || 0) > 0)
    .map((row) => ({
      name: plain(row.name) || '-',
      sprite: typeof row.sprite === 'string' ? plain(row.sprite, 32) : null,
      points: finite(row.points) || 0,
      played: Math.max(0, Math.floor(finite(row.played) || 0)),
      won: Math.max(0, Math.floor(finite(row.won) || 0)),
    }))
    .sort((a, b) => (b.points - a.points) || (a.name < b.name ? -1 : 1));

  if (!ranked.length) {
    if (wantsJson) ctx.say('[]');
    else {
      ctx.say('The ranking is empty: no ranked battle has been settled on this hub');
      ctx.say('yet, or every result since has been lost back. A player only appears');
      ctx.say('here once they are above zero.');
    }
    return OK;
  }

  const shown = wantsAll ? ranked : ranked.slice(0, rank.RANK_TOP);

  if (wantsJson) {
    // Deliberately not the stored rows: ranking.json also carries the token
    // digest that proves who owns a name, and that is the hub's business
    // alone -- rank.js keeps it off the wire for the same reason.
    ctx.say(JSON.stringify(shown.map((row, index) => Object.assign({ place: index + 1 }, row)), null, 2));
    return OK;
  }

  /*
   * W and L are a projection of two counters the board has always kept, not
   * new state: `played` and `won` are already in the file and already in
   * --json, and L is the subtraction nobody should have to do in their head.
   * Floored at zero because the arithmetic is over two numbers out of a file
   * a host can edit, and "-3 losses" would be a worse answer than 0.
   */
  printTable(ctx, ['PLACE', 'NAME', 'POINTS', 'W', 'L'], shown.map((row, index) => [
    String(index + 1), row.name, String(row.points),
    String(row.won), String(Math.max(0, row.played - row.won)),
  ]));

  ctx.say('');
  if (shown.length < ranked.length) {
    ctx.say(`Top ${shown.length} of ${ranked.length} ranked player(s). --all prints every one.`);
  } else {
    ctx.say(`${ranked.length} ranked player(s) -- the whole board.`);
  }
  ctx.say('W and L are settled ranked battles won and lost; both read 0 for a');
  ctx.say(`player carried over from an older board. \`${PROGRAM} history\` has the`);
  ctx.say('results themselves.');
  ctx.say('Read from the file the hub keeps, which it saves within a second of');
  ctx.say('each result. A battle settled in the last moment may not be in it yet.');
  return OK;
}

// ------------------------------------------------------------------ history

/*
 * The one file here that is not a document.
 *
 * `history.jsonl` is appended to, one record per line, while a hub runs --
 * which is exactly why it is not JSON as a whole: a hub killed mid-write
 * costs this reader the last line and nothing else, where a single JSON
 * array would be unreadable from the first byte. That bargain is only worth
 * anything if the reader keeps its half, so an unparsable line is *skipped*,
 * counted, and mentioned once -- never fatal. readJsonFile()'s refusal is
 * right for a file written whole and renamed into place; it would be wrong
 * here.
 */
function readHistoryFile(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    if (err && err.code === 'ENOENT') return { missing: true };
    return { error: err && err.message ? err.message : String(err) };
  }

  const records = [];
  let skipped = 0;
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch (err) {
      skipped += 1;
      continue;
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      skipped += 1;
      continue;
    }
    records.push(parsed);
  }
  return { records, skipped };
}

/*
 * The ledger, both generations of it, oldest line first.
 *
 * The hub does not let the file grow forever: past its ceiling the write that
 * would cross it renames `history.jsonl` to `history.jsonl.1` and starts a
 * fresh one (server.js, appendHistory). So at any moment after the first
 * rotation, up to half of everything the hub has kept is in the older file --
 * and a reader that opened only the current one would answer "all of them"
 * over a ledger it had read half of, which is worse than reading none.
 *
 * The two are one append-only stream, so `.1` is read first and its records
 * sit before the current file's; the reversal in verbHistory then puts the
 * newest of *both* at the top and `-n` cuts across the pair.
 *
 * Absence is ordinary in both directions -- there is no `.1` before the first
 * rotation, and no current file for a host who moved one aside by hand -- so
 * only both missing is "no match history". The skipped count spans both, for
 * the same reason: a rotation freezes whatever torn line the crash left in
 * the generation it moved.
 */
function readHistoryLedger(file) {
  const records = [];
  const present = [];
  let skipped = 0;

  for (const generation of [`${file}${HISTORY_ROTATED_SUFFIX}`, file]) {
    const read = readHistoryFile(generation);
    if (read.missing) continue;
    if (read.error) return { error: read.error, errorFile: generation };
    present.push(generation);
    for (const record of read.records) records.push(record);
    skipped += read.skipped;
  }

  if (!present.length) return { missing: true };
  return { records, skipped, present };
}

/*
 * A stored record, projected -- the same discipline `players --json` keeps.
 * What comes out is exactly the fields the contract names (plan §3), read
 * through plain() and finite(), so a field a newer hub added or a hand-edit
 * slipped in is not quietly republished as part of this output.
 */
function historyRecord(raw) {
  const side = (value, gainKey) => {
    const entry = value && typeof value === 'object' ? value : {};
    const points = finite(entry.points);
    const moved = finite(entry[gainKey]);
    return {
      name: plain(entry.name) || '-',
      points: points === null ? 0 : points,
      [gainKey]: moved === null ? 0 : moved,
    };
  };
  return {
    at: finite(raw.at),
    startedAt: finite(raw.startedAt),
    repeats: Math.max(0, Math.floor(finite(raw.repeats) || 0)),
    winner: side(raw.winner, 'gained'),
    loser: side(raw.loser, 'lost'),
  };
}

/**
 * `-n N`, which the parser leaves as positionals: it knows `--flag` and
 * nothing shorter, and inventing short options for one verb would be a
 * second parser to keep in step. `--n N` is accepted too, because somebody
 * will type it.
 */
function historyCount(ctx, rest) {
  let raw;
  let given = false;
  for (let i = 0; i < rest.length; i += 1) {
    const token = String(rest[i]);
    if (token === '-n') {
      raw = rest[i + 1];
      given = true;
      i += 1;
      continue;
    }
    if (token.startsWith('-n')) {
      raw = token.slice(2).replace(/^=/, '');
      given = true;
    }
  }
  if (ctx.flags.n !== undefined) {
    raw = ctx.flags.n;
    given = true;
  }

  if (!given) return { count: HISTORY_DEFAULT };
  if (raw === undefined || raw === true || raw === false || String(raw).trim() === '') {
    return { error: '-n needs a number after it, e.g. `-n 50`.' };
  }
  const wanted = Number(String(raw).trim());
  if (!Number.isFinite(wanted) || Math.floor(wanted) !== wanted || wanted < 1) {
    return { error: `-n "${plain(raw, 16)}" is not a whole number of results (1 or more).` };
  }
  return { count: wanted };
}

function noHistoryLines(file) {
  return [
    `No match history at ${file}.`,
    '',
    '  The hub appends one line to that file as each ranked battle is scored,',
    '  and creates it on the first one -- so there being none means one of',
    '  three things: no ranked battle has been settled on this hub yet, this',
    '  hub predates the file, or it keeps its files somewhere else.',
    '',
    '  It sits beside the config file, so `--config <path>` moves both. If the',
    '  hub runs in Docker, its files are inside the container:',
    `      docker compose exec hub ${PROGRAM} history`,
  ];
}

function verbHistory(ctx, rest) {
  const wantsJson = ctx.flags.json === true;
  const wanted = historyCount(ctx, rest);
  if (wanted.error) {
    ctx.warn(wanted.error);
    return USAGE;
  }

  const file = dataFile(ctx, HISTORY_FILENAME);
  const read = readHistoryLedger(file);

  if (read.missing) {
    // Nothing to show is not a failure, and --json still gets a document.
    if (wantsJson) ctx.say('[]');
    for (const line of noHistoryLines(file)) ctx.warn(line);
    return OK;
  }
  if (read.error) {
    ctx.warn(`Could not read ${read.errorFile}: ${read.error}`);
    return ERROR;
  }

  /*
   * Newest first, by file order reversed rather than by sorting on `at`.
   * The hub appends in the order it settles battles, which is the truth; a
   * sort would let one record with a hand-edited timestamp reorder the lot.
   */
  const records = read.records.map(historyRecord).reverse();
  const shown = records.slice(0, wanted.count);

  // Said once, on stderr, so it cannot be mistaken for a result -- and said
  // at all, because a reader that silently dropped lines would be a reader
  // nobody could trust about the ones it kept.
  if (read.skipped) {
    const where = read.present.length > 1
      ? `${HISTORY_FILENAME} and ${HISTORY_FILENAME}${HISTORY_ROTATED_SUFFIX}`
      : path.basename(read.present[0]);
    ctx.warn(`note: ${read.skipped} line(s) in ${where} could not be read, and were`);
    ctx.warn('      skipped. One torn last line per generation is normal after a hub');
    ctx.warn('      was killed mid-write; more than that means it has been edited.');
  }

  if (!records.length) {
    if (wantsJson) ctx.say('[]');
    else {
      const where = read.present.length > 1
        ? 'The match history beside the config file'
        : read.present[0];
      ctx.say(`${where} is there, but holds no results yet.`);
      ctx.say('The hub writes a line only when a ranked battle settles and both');
      ctx.say('clients agree on who won. A draw, a disagreement, or an unranked');
      ctx.say('battle scores nothing and is not history.');
    }
    return OK;
  }

  if (wantsJson) {
    ctx.say(JSON.stringify(shown, null, 2));
    return OK;
  }

  const now = Date.now();
  const rematches = shown.some((record) => record.repeats > 0);
  const headers = ['WHEN', 'WINNER', 'LOSER', 'POINTS'];
  if (rematches) headers.push('REMATCH');

  const rows = shown.map((record) => {
    const row = [
      record.at === null ? '-' : humanAge(Math.max(0, now - record.at)),
      record.winner.name,
      record.loser.name,
      `+${record.winner.gained}/-${record.loser.lost}`,
    ];
    // repeats counts the pair's prior meetings inside the hub's discount
    // window, so the second battle between them is x2 -- the ordinal a
    // player would use out loud, and the reason the gain was halved.
    if (rematches) row.push(record.repeats > 0 ? `x${record.repeats + 1}` : '');
    return row;
  });

  // "all the ledger holds", not "all of them": both generations are counted
  // here, and what fell off the older end of a rotated ledger is gone.
  ctx.say(shown.length < records.length
    ? `The last ${shown.length} of ${records.length} settled ranked battle(s), newest first.`
    : `${records.length} settled ranked battle(s), newest first -- all the ledger holds.`);
  ctx.say('');
  printTable(ctx, headers, rows);

  ctx.say('');
  ctx.say('WHEN is how long ago the battle settled. POINTS is what the winner');
  ctx.say(`gained and the loser lost; \`${PROGRAM} ranking\` has the totals.`);
  if (rematches) {
    ctx.say('REMATCH marks a pair who had met recently -- x2 is the second of');
    ctx.say('those, and the winner gains less for each one after the first.');
  }
  ctx.say('Only agreed, ranked results are here: a draw, a disagreement between');
  ctx.say('the two clients, or an unranked battle scores nothing and writes');
  ctx.say('nothing.');
  return OK;
}

// ---------------------------------------------- speaking to a running hub

/*
 * The other half of the CLI's relationship with the hub.
 *
 * Everything above reads a file and is honest about its age, which is the
 * right shape for most questions and useless for an instruction: no file can
 * remove a player, and no file holds a counter the hub keeps only in memory.
 * `stats`, `kick` and `broadcast` dial the admin socket lib/admin.js binds
 * beside the config file -- one JSON line out, one JSON line back,
 * connection closed. No auth travels here: the socket lives in the data
 * directory, and anybody who can open it can already read every join code in
 * config.json (plan §8.4).
 *
 * The absence of that socket is the interesting case, and it is not an
 * error. A hub that is not running has none; so does a hub old enough to
 * predate the channel. Both are answered with a sentence and exit 0, the
 * same way `players` answers a missing snapshot -- an operator who typed a
 * command against a hub that is not there has made no mistake worth a
 * failing exit code. A hub that *answers* and refuses is different: that is
 * a real refusal, and it exits 1.
 */
function askAdmin(ctx, request) {
  const file = dataFile(ctx, ADMIN_FILENAME);
  return new Promise((resolve) => {
    let settled = false;
    let buffer = '';
    let socket;

    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        if (socket) socket.destroy();
      } catch (err) {
        /* already gone */
      }
      resolve(Object.assign({ file }, result));
    };

    const timer = setTimeout(() => finish({
      error: `the hub did not answer within ${humanMs(ADMIN_TIMEOUT_MS)}`,
    }), ADMIN_TIMEOUT_MS);
    // A verb waiting on an answer is the only thing this process is doing,
    // but the timer itself must never be the reason it stays up.
    if (timer && typeof timer.unref === 'function') timer.unref();

    try {
      socket = net.createConnection({ path: file });
    } catch (err) {
      return finish({ failure: err });
    }

    socket.setEncoding('utf8');
    socket.on('connect', () => {
      try {
        socket.write(`${JSON.stringify(request)}\n`);
      } catch (err) {
        finish({ error: `the instruction could not be sent (${err.message})` });
      }
    });
    socket.on('data', (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf('\n');
      if (newline >= 0) return finish({ line: buffer.slice(0, newline) });
      if (buffer.length > ADMIN_MAX_RESPONSE_BYTES) {
        finish({ error: 'the answer was longer than one line and was abandoned' });
      }
    });
    // A hub that closes without a newline still meant its bytes as the
    // answer; admin.js ends the socket right behind the line, so this is the
    // ordinary way a short reply arrives.
    socket.on('end', () => {
      if (buffer.trim()) return finish({ line: buffer });
      finish({ error: 'the hub closed the connection without answering' });
    });
    socket.on('error', (err) => finish({ failure: err }));
  });
}

/*
 * Not-there, said in the words of whichever not-there it is. ENOENT is a hub
 * that is not running (or one too old to open the channel); ECONNREFUSED is
 * the file left behind by a hub that was killed, which is a different
 * sentence and a different fix. Both exit 0.
 */
function reportNoAdminSocket(ctx, file, failure, example) {
  const code = failure && failure.code;
  if (code === 'ECONNREFUSED') {
    ctx.warn(`Nothing is listening on ${file}.`);
    ctx.warn('');
    ctx.warn('  The socket file is there but the hub behind it is gone -- it was');
    ctx.warn('  killed rather than stopped, and Unix sockets outlive the process');
    ctx.warn(`  that made them. Starting the hub again clears it: \`${PROGRAM} start\``);
    ctx.warn('  removes a leftover socket and binds a fresh one.');
    return OK;
  }
  if (code === 'ENOTSOCK') {
    // Something that is not a socket is sitting on the path. admin.js will
    // not delete a file it did not create either, and neither will this --
    // it is somebody's data until they say otherwise.
    ctx.warn(`${file} is not a socket.`);
    ctx.warn('');
    ctx.warn('  Something else is at the path the hub uses for its admin channel,');
    ctx.warn('  and the hub will refuse to bind over it for the same reason this');
    ctx.warn('  will not delete it: it is not a file this software wrote. Move it');
    ctx.warn('  out of the way yourself, then start the hub again.');
    return ERROR;
  }
  if (code && code !== 'ENOENT') {
    // EACCES and friends: the socket is there and this process may not use
    // it. That is a real failure with a real fix, not an absent hub.
    ctx.warn(`Could not reach the hub at ${file}: ${plain(failure.message, 200)}`);
    ctx.warn('The socket belongs to the user the hub runs as, and the data');
    ctx.warn('directory is kept private on purpose. Run this as that user -- in');
    ctx.warn(`Docker, \`docker compose exec hub ${PROGRAM} ...\` already does.`);
    return ERROR;
  }

  ctx.warn(`No admin socket at ${file}.`);
  ctx.warn('');
  ctx.warn('  The hub opens that socket while it runs and removes it on the way');
  ctx.warn('  out, so there being none means one of two things: no hub is running');
  ctx.warn('  against this config file, or the hub that is running predates the');
  ctx.warn('  admin channel and has to be restarted before it will open one.');
  ctx.warn('');
  ctx.warn('  It sits beside the config file, so `--config <path>` moves both. If');
  ctx.warn('  the hub runs in Docker, the socket is inside the container:');
  ctx.warn(`      docker compose exec hub ${PROGRAM} ${example}`);
  return OK;
}

/**
 * One exchange, with every way it can go wrong turned into an exit code and
 * a sentence. Returns `{ code }` when the caller has nothing left to do, or
 * `{ response }` when the hub answered `ok: true`.
 */
async function adminExchange(ctx, request, example) {
  const answer = await askAdmin(ctx, request);

  if (answer.failure) {
    return { code: reportNoAdminSocket(ctx, answer.file, answer.failure, example) };
  }
  if (answer.error) {
    ctx.warn(`Could not complete that instruction: ${plain(answer.error, 200)}.`);
    ctx.warn('The socket accepted the connection, so a hub is there -- its own log');
    ctx.warn('is where the reason will be.');
    return { code: ERROR };
  }

  let parsed;
  try {
    parsed = JSON.parse(answer.line);
  } catch (err) {
    // Borrowed bytes on their way to a terminal, so through plain() like
    // every other line that came from outside this process.
    ctx.warn(`The hub answered something that is not JSON: ${plain(answer.line, 120)}`);
    return { code: ERROR };
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    ctx.warn('The hub answered JSON that is not a response object.');
    return { code: ERROR };
  }
  if (parsed.ok !== true) {
    ctx.warn(`The hub refused: ${plain(parsed.error, 200) || 'no reason given'}`);
    return { code: ERROR };
  }
  return { response: parsed };
}

/**
 * A label/value block, aligned. Two columns and no header, because these are
 * not rows of a list -- each line is one counter and its reading, and a
 * `COUNTER  VALUE` header over six of them would be furniture.
 */
function printPairs(ctx, pairs) {
  const width = Math.max(...pairs.map(([label]) => label.length));
  for (const [label, value] of pairs) ctx.say(`  ${pad(label, width)}  ${value}`);
}

/** An object the hub sent, or an empty one. Never an array, never a string. */
function asObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

/**
 * How many addresses a `perIp` map counted -- never which ones.
 */
function addressCount(node) {
  const perIp = node && typeof node.perIp === 'object' && node.perIp !== null
    ? node.perIp : null;
  return perIp === null ? null : Object.keys(perIp).length;
}

/**
 * `3 connection(s) not in the world yet`, or a dash for a hub that did not
 * say. The noun carries its own plural, because "address(es)" and
 * "connection(s)" do not take the same one and a counter is not worth a
 * pluralisation rule.
 */
function countOf(value, noun, tail) {
  const count = finite(value);
  if (count === null) return '-';
  return `${count} ${noun} ${tail}`;
}

/*
 * The hub's answer, with the addresses taken out of it.
 *
 * `perIp` -- at both the levels it appears on, the hub's own and the
 * limiter's -- is a map keyed by the address each connection came from, and
 * other people's addresses are not output material here: the rosters do not
 * carry them, `players` does not print them, and a `stats` a host might paste
 * into a bug report must not be the one place they leak from. What is
 * operationally useful about that map is how many keys it has, so a count
 * takes its place under a name that cannot be mistaken for the map itself.
 *
 * Dropped explicitly rather than by projecting an allowlist of fields: a
 * counter the hub grows later should reach a script through here without
 * anybody remembering to add it, while this one still does not.
 */
function statsWithoutAddresses(stats) {
  const strip = (node) => {
    const copy = Object.assign({}, node);
    const count = addressCount(node);
    delete copy.perIp;
    if (count !== null) copy.addresses = count;
    return copy;
  };

  const out = strip(stats);
  if (stats.limits && typeof stats.limits === 'object' && !Array.isArray(stats.limits)) {
    out.limits = strip(stats.limits);
  }
  return out;
}

/*
 * The question this channel answers that no file can.
 *
 * `status` prints what the limits are configured to be, off the config file,
 * and is honest that they are configured numbers. The live readings -- open
 * connections, handshakes in flight, how many wrong passcodes have actually
 * arrived and whether the hub-wide ceiling is tripped this second -- exist
 * only in the running process and are written nowhere, so this verb is the
 * whole of the answer to "what is happening at the door right now".
 */
async function verbStats(ctx) {
  const result = await adminExchange(ctx, { cmd: 'stats' }, 'stats');
  if (result.code !== undefined) return result.code;

  const stats = asObject(result.response.stats);
  const door = asObject(stats.limits);
  const guesses = asObject(door.auth);

  if (ctx.flags.json === true) {
    ctx.say(JSON.stringify(statsWithoutAddresses(stats), null, 2));
    return OK;
  }

  const players = finite(stats.players);
  const maxPlayers = finite(stats.maxPlayers);
  const uptimeMs = finite(stats.uptimeMs);
  const where = stats.host === undefined || stats.port === undefined
    ? '-' : `${plain(stats.host, 45)}:${plain(stats.port, 5)}`;

  ctx.say('The hub');
  printPairs(ctx, [
    ['address', where],
    ['uptime', uptimeMs === null ? '-' : humanAge(uptimeMs)],
    ['protocol', plain(stats.protocol, 12) || '-'],
    ['players', players === null ? '-'
      : `${players}${maxPlayers === null ? '' : ` of ${maxPlayers}`}`],
    ['pending', countOf(stats.pending, 'connection(s)', 'not in the world yet')],
  ]);

  const connections = finite(door.connections);
  const addresses = addressCount(door);
  const recent = finite(guesses.recentFailures);
  const threshold = finite(guesses.failureThreshold);
  const windowMs = finite(guesses.windowMs);
  const lockdownMs = finite(guesses.lockdownMs);

  ctx.say('');
  ctx.say('The door');
  printPairs(ctx, [
    ['connections', connections === null ? '-'
      : `${connections} open` +
        (addresses === null ? '' : `, from ${addresses} address(es)`)],
    ['handshakes', countOf(door.pending, 'connection(s)', 'still to be greeted')],
    ['wrong codes', recent === null ? '-'
      : `${recent}${threshold === null ? '' : ` of ${threshold}`}` +
        (windowMs === null ? '' : ` in the last ${humanMs(windowMs)}`)],
    ['lockdown', guesses.lockdown === true
      ? `YES -- new joins refused${lockdownMs ? ` for another ${humanAge(lockdownMs)}` : ''}`
      : 'no'],
    ['throttled', countOf(guesses.throttledAddresses, 'address(es)', 'backing off now')],
    ['tracked', countOf(guesses.trackedAddresses, 'address(es)', 'with failures remembered')],
  ]);

  ctx.say('');
  ctx.say('Live counters, read from the hub itself: they are kept in its memory,');
  ctx.say(`written to no file, and gone when it stops. \`${PROGRAM} status\` prints`);
  ctx.say('what the same limits are *configured* to be, which is the other half of');
  ctx.say('the reading. Two pendings, because they are counted either side of the');
  ctx.say('handshake and a connection in flight is briefly in one and not the other.');
  if (guesses.lockdown === true) {
    ctx.say('');
    ctx.say('The hub-wide ceiling is tripped: new joins are refused until it lifts.');
    ctx.say('Players already in the world are untouched by it, and it lifts on its');
    ctx.say('own -- `config set limits.authLockoutMs` is how long for.');
  }
  ctx.say('');
  ctx.say('Addresses are counted and never printed. Who is connected, by name, is');
  ctx.say(`\`${PROGRAM} players\`.`);
  return OK;
}

async function verbKick(ctx, rest) {
  const name = rest.length ? String(rest[0]).trim() : '';
  if (!name) {
    ctx.warn(`Usage: ${PROGRAM} kick <name> [--reason TEXT]`);
    ctx.warn(`\`${PROGRAM} players\` lists who is connected.`);
    return USAGE;
  }

  /*
   * The reason is prose, and prose arrives as several argv tokens. Joining
   * with spaces is the idiom `config set` already uses for a multi-word
   * value; everything after the name is part of it, whether it followed
   * --reason or not, so `kick RED --reason being rude` says what it looks
   * like it says.
   */
  const pieces = [];
  if (typeof ctx.flags.reason === 'string') pieces.push(ctx.flags.reason);
  for (const extra of rest.slice(1)) pieces.push(String(extra));
  const reason = pieces.join(' ').trim();

  if (ctx.flags.reason === true) {
    ctx.warn('--reason needs the sentence to show the player after it.');
    return USAGE;
  }

  const request = { cmd: 'kick', name };
  if (reason) request.reason = reason;

  const result = await adminExchange(ctx, request, `kick ${name}`);
  if (result.code !== undefined) return result.code;

  const names = Array.isArray(result.response.names) ? result.response.names : [];
  const kicked = Number.isFinite(result.response.kicked)
    ? result.response.kicked : names.length;

  if (!kicked) {
    ctx.say('Nobody by that name is connected. Nothing was done.');
    ctx.say(`\`${PROGRAM} players\` lists who is, spelled the way the hub has them.`);
    return OK;
  }

  const listed = names.map((entry) => plain(entry) || '-').join(', ');
  ctx.say(`Kicked ${kicked} player(s)${listed ? `: ${listed}` : ''}.`);
  if (reason) ctx.say(`They were shown: ${plain(reason, 120)}`);
  ctx.say('A kick is not a ban: the same passcode gets them back in. `ban <ip>`');
  ctx.say('or `revoke <id>`, then a reload, is what keeps somebody out.');
  return OK;
}

async function verbBroadcast(ctx, rest) {
  // Same joining rule as `config set` and as --reason above: the message is
  // prose and the shell has already taken it apart.
  const text = rest.map((piece) => String(piece)).join(' ').trim();
  if (!text) {
    ctx.warn(`Usage: ${PROGRAM} broadcast <text>`);
    ctx.warn('Everything after the verb is the message; quotes are optional.');
    return USAGE;
  }

  const result = await adminExchange(ctx, { cmd: 'broadcast', text }, 'broadcast hello');
  if (result.code !== undefined) return result.code;

  const delivered = Number.isFinite(result.response.delivered) ? result.response.delivered : 0;
  ctx.say(`Delivered to ${delivered} player(s).`);
  if (!delivered) {
    ctx.say('Either nobody is in the world right now, or nothing survived the');
    ctx.say('cleaning every chat line goes through -- letters, digits and simple');
    ctx.say('punctuation, one line.');
  }
  return OK;
}

// --------------------------------------------------------------------- upnp

async function verbUpnp(ctx, rest) {
  const action = rest[0];
  if (!action || !['enable', 'disable', 'status'].includes(action)) {
    ctx.warn(`Usage: ${PROGRAM} upnp enable|disable|status`);
    return USAGE;
  }

  const loaded = action === 'status' ? loadEffective(ctx) : requireExistingConfig(ctx);
  if (!loaded) return ERROR;
  const cfg = loaded.config;
  const port = cfg.listen.port;

  if (action === 'status') {
    ctx.say(`UPnP is ${cfg.network.upnp.enabled ? 'enabled' : 'disabled'} in the ` +
      `configuration (lease ${cfg.network.upnp.leaseSeconds}s).`);
    ctx.say('Asking the router...');
    const found = await upnp.discover({ timeoutMs: 3000 });
    if (!found.ok) {
      ctx.say(`  ${found.error}`);
      return OK;
    }
    ctx.say(`  router: ${found.router} (${found.serviceType})`);
    const mapping = await upnp.getMapping({ port, device: found });
    if (mapping.ok && mapping.mapped) {
      ctx.say(`  mapping: TCP ${port} -> ${mapping.internalAddress}:${mapping.internalPort}` +
        (mapping.description ? `  "${mapping.description}"` : '') +
        (mapping.leaseSeconds ? `  lease ${mapping.leaseSeconds}s` : '  permanent'));
    } else if (mapping.ok) {
      ctx.say(`  mapping: none for TCP ${port}`);
    } else {
      ctx.say(`  mapping: could not be read (${mapping.error})`);
    }
    const ip = await upnp.externalIp({ device: found });
    if (ip.ok) {
      ctx.say(`  external address: ${ip.address}${ip.up ? '' : '  (the uplink looks down)'}`);
    } else {
      ctx.say(`  external address: unknown (${ip.error})`);
    }
    return OK;
  }

  if (action === 'enable') {
    // The warning comes first and in full, before a single packet is sent.
    printLines(ctx, upnp.ENABLE_WARNING);
    ctx.say('');
    ctx.say(`Asking the router to forward TCP ${port}...`);

    const result = await upnp.addMapping({
      port,
      leaseSeconds: cfg.network.upnp.leaseSeconds,
      description: 'RBY MMO hub',
    });
    if (!result.ok) {
      ctx.warn(`  failed: ${result.error}`);
      ctx.warn('  UPnP has been left disabled in the configuration. Forward TCP');
      ctx.warn(`  ${port} on the router by hand instead -- the hub does not care`);
      ctx.warn('  which way the port got opened.');
      return ERROR;
    }

    ctx.say(`  forwarded TCP ${result.port} to ${result.internalAddress}` +
      (result.permanent
        ? ' as a PERMANENT mapping -- this router refuses leases, so it will'
        : ` on a ${result.leaseSeconds}s lease`));
    if (result.permanent) {
      ctx.say('  outlive this process. `upnp disable` removes it.');
    }

    cfg.network.upnp.enabled = true;
    if (!saveConfig(ctx, cfg)) return ERROR;
    ctx.say(`UPnP enabled. \`${PROGRAM} start\` will renew the mapping and remove it`);
    ctx.say('on a clean shutdown.');
    return OK;
  }

  // disable
  ctx.say(`Removing any mapping for TCP ${port}...`);
  const removed = await upnp.removeMapping({ port });
  if (removed.ok) {
    ctx.say(removed.alreadyGone ? '  there was no mapping to remove' : '  removed');
  } else {
    ctx.say(`  could not remove it: ${removed.error}`);
    ctx.say('  A leased mapping expires on its own; a permanent one has to be');
    ctx.say('  removed on the router.');
  }
  cfg.network.upnp.enabled = false;
  if (!saveConfig(ctx, cfg)) return ERROR;
  ctx.say('UPnP disabled. Nothing here will ask the router for anything again.');
  return OK;
}

// ---------------------------------------------------------------- the runner

/**
 * @param {string[]} argv  arguments after the program name
 * @param {object} io      { stdout, stderr, stdin, env?, cwd? }
 * @returns {Promise<number>} 0 success, 1 runtime error, 2 usage error
 */
async function run(argv, io) {
  const base = makeIo(io);
  const { positional, flags } = parseArgs(Array.isArray(argv) ? argv : []);

  const ctx = Object.assign({}, base, { flags, positional, file: null });

  if (flags.version === true) {
    ctx.say(`${PROGRAM} ${version()}`);
    return OK;
  }

  const verb = positional[0];
  const rest = positional.slice(1);

  if (!verb) {
    // A bare invocation is somebody looking for the manual, not an error.
    return help(ctx, '');
  }
  if (verb === 'help') return help(ctx, rest[0] || '');
  if (flags.help === true) return help(ctx, verb);

  try {
    ctx.file = resolveConfigPath(ctx);
  } catch (err) {
    ctx.warn(`Could not work out which config file to use: ${err.message}`);
    return ERROR;
  }

  try {
    switch (verb) {
      case 'init': return await verbInit(ctx);
      case 'start': return await verbStart(ctx);
      case 'status': return verbStatus(ctx);
      case 'players': return verbPlayers(ctx);
      case 'watch': return await verbWatch(ctx);
      case 'ranking': return verbRanking(ctx);
      case 'history': return verbHistory(ctx, rest);
      case 'stats': return await verbStats(ctx);
      case 'kick': return await verbKick(ctx, rest);
      case 'broadcast': return await verbBroadcast(ctx, rest);
      case 'config': return verbConfig(ctx, rest);
      case 'invite': return verbInvite(ctx, rest);
      case 'revoke': return verbRevoke(ctx, rest);
      case 'ban': return verbBan(ctx, rest);
      case 'unban': return verbUnban(ctx, rest);
      case 'allow': return verbAllow(ctx, rest);
      case 'doctor': return await verbDoctor(ctx);
      case 'upnp': return await verbUpnp(ctx, rest);
      case 'version': ctx.say(`${PROGRAM} ${version()}`); return OK;
      default:
        ctx.warn(`Unknown command "${verb}".`);
        ctx.warn(`\`${PROGRAM} help\` lists them.`);
        return USAGE;
    }
  } catch (err) {
    // The last wall. A verb that throws is a bug in this software, not the
    // host's fault, so it reports a sentence rather than a stack trace -- and
    // it reports it on stderr, so a piped `config get` stays machine-readable.
    ctx.warn(`${PROGRAM} ${verb} failed: ${err && err.message ? err.message : String(err)}`);
    if (ctx.env && ctx.env.RBY_MMO_DEBUG && err && err.stack) ctx.warn(err.stack);
    return ERROR;
  }
}

module.exports = {
  run,
  // exported for the test suite, which drives the parser directly rather than
  // inferring its behaviour from a verb's output
  parseArgs,
  parseDuration,
  version,
  OK,
  ERROR,
  USAGE,
};
