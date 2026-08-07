#!/usr/bin/env node
'use strict';

/*
 * Test for the hosting CLI -- the one place a host is supposed to be able to
 * configure anything (`server/lib/cli.js`). This is the suite that has to
 * prove the central claim: every setting is reachable through the software,
 * and secrets are handled carefully.
 *
 * `run(argv, io)` never touches process.exit or process.stdout directly, so
 * everything here drives it in-process with captured streams pointed at a
 * scratch directory -- no shell, no real config.json, no real terminal.
 * `server/bin/rby-mmo-hub.js` is spawned exactly once, at the bottom, purely
 * to prove the shim maps the code `run()` returns onto the real process exit
 * status; every other assertion goes through `cli.run()` directly.
 *
 * Same idiom as server/hub.test.js: no test framework, no dependencies, a
 * throwing ok(), scenario functions, a final pass count. Works both as
 * `node server/cli.test.js` and under `node --test` (server/package.json's
 * `test` script), which discovers *.test.js siblings and runs each as its
 * own process.
 *
 * Run: node server/cli.test.js
 */

const fs = require('node:fs');
const os = require('node:os');
const net = require('node:net');
const path = require('node:path');
const Module = require('node:module');
const { Readable } = require('node:stream');
const { spawn } = require('node:child_process');

const cli = require('./lib/cli.js');
const config = require('./lib/config.js');
const auth = require('./lib/auth.js');
const limits = require('./lib/limits.js');

const BIN = path.join(__dirname, 'bin', 'rby-mmo-hub.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

/*
 * A passcode in its printed form: CODE_LEN ungrouped characters from auth.js's
 * alphabet, standing alone. Both patterns are built from auth.js rather than
 * spelled out, so the day the format changes again this suite fails on the
 * assertions that are really about shape -- not on a regex nobody remembered.
 */
const CODE_RE = new RegExp(
  `(?<![${auth.ALPHABET}])[${auth.ALPHABET}]{${auth.CODE_LEN}}(?![${auth.ALPHABET}])`);

/*
 * The framed block `init` and `invite` draw is the only place a whole code is
 * printed on purpose, so extraction goes through it. Matching a bare six
 * characters anywhere in stdout would sooner or later pick up the random tail
 * of a mkdtemp path -- ~2% of runs, on a suite that then fails for a reason
 * that has nothing to do with the code.
 */
const BOXED_CODE_RE = new RegExp(
  `\\|\\s+([${auth.ALPHABET}]{${auth.CODE_LEN}})\\s+\\|`);

// The seven knobs the auth-failure throttle is configured with. Named here so
// the LEAF_PATHS sweep can assert it really drove every one of them, rather
// than reporting them as uncovered and still passing.
const AUTH_LIMIT_PATHS = [
  'limits.authFailureGrace',
  'limits.authFailureWindowMs',
  'limits.authBackoffBaseMs',
  'limits.authBackoffMaxMs',
  'limits.authGlobalFailures',
  'limits.authGlobalWindowMs',
  'limits.authLockoutMs',
];

const EXCEPT_PATHS = new Set(['auth.credentials', 'version']);

// ------------------------------------------------------------- scratch area

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'rby-mmo-cli-test-'));
let scratchCount = 0;
function scratchDir(label) {
  const dir = path.join(ROOT, `${String(++scratchCount).padStart(2, '0')}-${label}`);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function cleanEnv() {
  // A real shell may already export RBY_MMO_* variables; scrub them so every
  // scenario starts from a known, empty environment and opts in explicitly.
  const env = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (key.startsWith('RBY_MMO_')) continue;
    env[key] = value;
  }
  return env;
}

// A minimal writable sink: not a real stream, just something with a
// synchronous write() and a no-op on()/once() so cli.js's quiet(stream) call
// (`stream.on('error', ...)`) has something harmless to call.
function makeSink() {
  let text = '';
  const stream = {
    write(chunk) { text += String(chunk); return true; },
    on() { return stream; },
    once() { return stream; },
  };
  return { stream, read: () => text };
}

// Used whenever a scenario does not care about stdin (--yes, or any verb
// that never opens readline). Real interactivity is exercised separately,
// against a real stream, in the "scriptable init" scenario below.
const FAKE_STDIN = { on() {}, once() {}, pause() {}, resume() {}, removeListener() {} };

// A stdin that is already at EOF -- the shape `docker run` (without -t) and
// CI hand a process: readable, but with nothing coming and nothing to wait
// for.
function endedStdin() {
  const r = new Readable({ read() {} });
  r.push(null);
  return r;
}

async function runCli(argv, opts = {}) {
  const outSink = makeSink();
  const errSink = makeSink();
  const io = {
    stdout: outSink.stream,
    stderr: errSink.stream,
    stdin: opts.stdin || FAKE_STDIN,
    env: opts.env || cleanEnv(),
    cwd: opts.cwd || ROOT,
  };
  const code = await cli.run(argv, io);
  return { code, stdout: outSink.read(), stderr: errSink.read() };
}

function withTimeout(promise, ms, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out after ${ms}ms waiting for: ${label}`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function readConfigFile(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function fileMode(file) {
  return fs.statSync(file).mode & 0o777;
}

function countMatches(haystack, re) {
  const matches = haystack.match(new RegExp(re.source, 'gm'));
  return matches ? matches.length : 0;
}

/** Occurrences of an exact string -- the honest way to count a known secret. */
function countLiteral(haystack, needle) {
  return String(haystack).split(needle).length - 1;
}

/** The code out of the framed block, with the block's presence asserted. */
function extractCode(text, label) {
  const match = BOXED_CODE_RE.exec(text);
  ok(!!match, label);
  return match[1];
}

/*
 * A stdin that answers the wizard one line at a time and only then ends.
 *
 * Not the same thing as endedStdin(): Node's readline discards whatever is
 * still buffered when the stream ends, so pushing four answers at once answers
 * one question and defaults the rest (which is its own scenario, below). Pacing
 * them is the only way to exercise a question that is not the first one.
 */
function pacedStdin(answers) {
  const stream = new Readable({ read() {} });
  let index = 0;
  const timer = setInterval(() => {
    if (index < answers.length) {
      stream.push(`${answers[index++]}\n`);
      return;
    }
    clearInterval(timer);
    stream.push(null);
  }, 15);
  if (typeof timer.unref === 'function') timer.unref();
  return stream;
}

function same(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

// ------------------------------------------------- stubs for the start verb
//
// `start` is the one verb that binds a socket and talks to a router, and
// neither belongs in this suite: server.js has its own, and a test that
// contacted a real router would pass or fail on whose desk it ran. So both
// are replaced at their seams -- lib/server.js through require.cache (cli.js
// requires it lazily, inside the verb, so the swap is seen), and upnp.js by
// overwriting the two functions cli.js calls on the module object it already
// holds. Nothing here opens a port or sends a packet, and `upnp enable` is
// never invoked.

const SERVER_PATH = require.resolve('./lib/server.js');
const upnpModule = require('./lib/upnp.js');

function stubServer(exports) {
  const previous = require.cache[SERVER_PATH];
  const stub = new Module(SERVER_PATH, null);
  stub.filename = SERVER_PATH;
  stub.loaded = true;
  stub.exports = exports;
  require.cache[SERVER_PATH] = stub;
  return () => {
    if (previous) require.cache[SERVER_PATH] = previous;
    else delete require.cache[SERVER_PATH];
  };
}

function stubUpnp(patch) {
  const previous = {};
  for (const [key, value] of Object.entries(patch)) {
    previous[key] = upnpModule[key];
    upnpModule[key] = value;
  }
  return () => {
    for (const [key, value] of Object.entries(previous)) upnpModule[key] = value;
  };
}

const tick = () => new Promise((resolve) => setImmediate(resolve));

async function waitFor(predicate, label, ms = 5000) {
  const deadline = Date.now() + ms;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out after ${ms}ms waiting for: ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function spawnCli(args, opts = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [BIN, ...args], {
      stdio: 'ignore',
      env: opts.env || cleanEnv(),
      cwd: opts.cwd || ROOT,
    });
    child.on('error', reject);
    child.on('close', (code) => resolve(code));
  });
}

// =====================================================================
// init
// =====================================================================

async function initScenarios() {
  const dir = scratchDir('init');
  const file = path.join(dir, 'config.json');

  // --- writes the file at mode 0600, prints a join code exactly once, and
  //     the printed code round-trips against what is stored on disk
  const first = await runCli(['init', '--yes', '--config', file], { cwd: dir });
  ok(first.code === cli.OK, 'init --yes succeeds');
  ok(fs.existsSync(file), 'and writes the config file');
  ok(fileMode(file) === 0o600, 'the config file is written mode 0600');

  const printedCode = extractCode(first.stdout, 'init frames the passcode in a block of its own');
  const printedCount = countLiteral(first.stdout, printedCode);
  ok(printedCount === 1, `the join code is printed exactly once (saw ${printedCount})`);

  // The shape itself, asserted against auth.js rather than a literal: six
  // ungrouped characters, no dashes, nothing outside the alphabet.
  ok(printedCode.length === auth.CODE_LEN,
    `the printed passcode is ${auth.CODE_LEN} characters (got ${printedCode.length})`);
  ok(!printedCode.includes('-'), 'and is ungrouped -- no dashes in the printed form');
  ok(CODE_RE.test(printedCode), 'and uses only the alphabet auth.js publishes');
  ok(auth.normalizeCode(printedCode) === printedCode,
    'the printed form is already the normalised form, so a friend can type it back verbatim');

  const onDisk = readConfigFile(file);
  ok(onDisk.auth.credentials.length === 1, 'a primary credential is written');
  ok(onDisk.auth.credentials[0].id === 'primary', 'the first credential is named primary');
  ok(auth.normalizeCode(printedCode) === auth.normalizeCode(onDisk.auth.credentials[0].secret),
    'the printed code normalises to the same key as the credential stored in the file');

  // --- re-running without --force refuses and names the file
  const again = await runCli(['init', '--yes', '--config', file], { cwd: dir });
  ok(again.code === cli.ERROR, 'init without --force on an existing config is a runtime error');
  ok(again.stderr.includes(file), 'the refusal names the config file');
  ok(/--force/.test(again.stderr), 'and names the escape hatch');
  ok(readConfigFile(file).auth.credentials[0].secret === onDisk.auth.credentials[0].secret,
    'the existing config is untouched by the refused run');

  // --- with --force it overwrites (and actually rotates the code)
  const forced = await runCli(['init', '--yes', '--force', '--config', file], { cwd: dir });
  ok(forced.code === cli.OK, 'init --force overwrites');
  const forcedCode = extractCode(forced.stdout, 'the forced run frames a passcode too');
  ok(countLiteral(forced.stdout, forcedCode) === 1, 'the forced run also prints exactly one code');
  const secondOnDisk = readConfigFile(file);
  ok(secondOnDisk.auth.credentials[0].secret !== onDisk.auth.credentials[0].secret,
    '--force writes a fresh join code, not the old one');

  // --- the default is auth ON (so a careless first run is not an open hub)
  ok(config.DEFAULTS.auth.required === true, 'the built-in default requires a join code');
  ok(secondOnDisk.auth.required === true, 'a plain init --yes leaves auth on');

  // --- init is scriptable: no TTY, no stdin (docker run without -t, CI) --
  //     it must terminate, not hang forever on rl.question()
  const scriptedFile = path.join(dir, 'config-scripted.json');
  const scripted = await withTimeout(
    runCli(['init', '--config', scriptedFile], { cwd: dir, stdin: endedStdin() }),
    5000,
    'init with a closed stdin');
  ok(scripted.code === cli.OK, 'init on a closed stdin still terminates and succeeds');
  ok(fs.existsSync(scriptedFile), 'and still writes a config file, on the defaults');
  ok(/input ended/i.test(scripted.stderr),
    'and says plainly that it took defaults because the input ended');
  const scriptedOnDisk = readConfigFile(scriptedFile);
  ok(scriptedOnDisk.auth.required === true,
    'a config written with no input at all still requires a passcode');
  ok(scriptedOnDisk.auth.credentials.length === 1,
    'and still has one to admit somebody with -- the unattended path is not the open path');
  ok(!/--no-auth/.test(scripted.stderr),
    'and the scripted-run hint no longer advertises a flag that has been withdrawn');
}

// =====================================================================
// a passcode is required: init cannot be talked into an open hub
// =====================================================================

// A verb that edits a config which is not there must not answer "run init".
//
// This is a regression test for a real incident, not a hypothetical. A host set
// maxPlayers on a hub running in Docker, from the host shell rather than inside
// the container; the config was not there, the CLI said to run `init`, they
// did, and `init` minted a second config with a fresh passcode and the default
// cap. The hub they cared about never changed, so the setting "did not stick"
// and a healthy hub looked broken. `init` is the last resort here, never the
// opening suggestion.
async function missingConfigAdviceScenario() {
  const dir = scratchDir('missing-config');
  const absent = path.join(dir, 'nope.json');

  const bare = await runCli(['config', 'set', 'maxPlayers', '16', '--config', absent], { cwd: dir });
  ok(bare.code !== cli.OK, 'editing a config that is not there fails');
  ok(new RegExp(absent.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).test(bare.stderr),
    'and says which path it looked at, so a wrong --config is visible');
  ok(/docker compose exec/.test(bare.stderr),
    'it raises the container case, which is how most people arrive here');
  const initAt = bare.stderr.indexOf('init');
  const dockerAt = bare.stderr.indexOf('docker compose exec');
  ok(dockerAt !== -1 && (initAt === -1 || dockerAt < initAt),
    'and it never leads with init -- that is what mints a duplicate hub');
  ok(/fresh passcode|new passcode/i.test(bare.stderr),
    'when init is mentioned at all, it says it mints a passcode nobody has');

  // --- a config that exists somewhere obvious is named, and init is not
  //     suggested at all: there is nothing to create.
  const real = path.join(dir, 'config.json');
  const made = await runCli(['init', '--yes', '--config', real], { cwd: dir });
  ok(made.code === cli.OK, 'a real config exists to be found');

  const elsewhere = path.join(dir, 'elsewhere.json');
  const found = await runCli(['config', 'set', 'maxPlayers', '16', '--config', elsewhere],
    { cwd: dir, env: { RBY_MMO_CONFIG: real } });
  ok(found.code !== cli.OK, 'still refuses to edit the file that is not there');
  ok(found.stderr.includes(real),
    'but names the config it can actually see, by full path');
  ok(/--config/.test(found.stderr),
    'and says how to point at it');
  ok(!/\binit\b/.test(found.stderr),
    'and does not mention init at all -- there is nothing to create');
}

async function authIsMandatoryScenario() {
  const dir = scratchDir('auth-required');

  // --- --no-auth: a usage error that explains itself, not "unknown option",
  //     because people paste old commands out of their shell history
  const noAuthFile = path.join(dir, 'no-auth.json');
  const noAuth = await runCli(['init', '--yes', '--no-auth', '--config', noAuthFile], { cwd: dir });
  ok(noAuth.code === cli.USAGE, 'init --no-auth is a usage error (exit 2), not a quiet success');
  ok(!fs.existsSync(noAuthFile), 'and writes no config file at all');
  ok(/passcode is required/i.test(noAuth.stderr),
    'the refusal says a passcode is required, in as many words');
  ok(/--no-auth/.test(noAuth.stderr),
    'it names the flag the host actually typed, so they know which one went');
  ok(/--code/.test(noAuth.stderr),
    'and points at --code, which is the thing they probably wanted');

  // --- the other spellings of the same thing reach the same sentence
  for (const argv of [['--auth', 'false'], ['--auth=off'], ['--auth', 'no']]) {
    const file = path.join(dir, `spelling-${argv.join('')}.json`.replace(/[^\w.-]/g, ''));
    const result = await runCli(['init', '--yes', ...argv, '--config', file], { cwd: dir });
    ok(result.code === cli.USAGE, `init ${argv.join(' ')} is refused the same way`);
    ok(!fs.existsSync(file), `init ${argv.join(' ')} writes nothing`);
  }

  // --- and the environment cannot do it either: RBY_MMO_AUTH_REQUIRED=false
  //     is a real variable config.js honours, so init has to overrule it
  const envFile = path.join(dir, 'env.json');
  const env = Object.assign(cleanEnv(), { RBY_MMO_AUTH_REQUIRED: 'false' });
  const fromEnv = await runCli(['init', '--yes', '--config', envFile], { cwd: dir, env });
  ok(fromEnv.code === cli.OK, 'init still succeeds with RBY_MMO_AUTH_REQUIRED=false in the environment');
  const envOnDisk = readConfigFile(envFile);
  ok(envOnDisk.auth.required === true, 'but writes auth.required: true regardless');
  ok(envOnDisk.auth.credentials.length === 1, 'with a usable passcode in it');
  ok(/ignored/i.test(fromEnv.stderr),
    'and says the request for an open hub was ignored rather than silently overruling it');

  // --- the standing claim, stated once: no init produces a config without a
  //     passcode, whatever it is handed
  for (const argv of [['init', '--yes'], ['init', '--yes', '--force']]) {
    const file = path.join(dir, `always-${argv.length}.json`);
    await runCli([...argv, '--config', file], { cwd: dir });
    const written = readConfigFile(file);
    ok(written.auth.required === true && written.auth.credentials.length === 1,
      `\`${argv.join(' ')}\` produces a hub that requires a passcode and has one`);
  }
}

// =====================================================================
// a host may choose the passcode -- "the same passcode can be configured"
// =====================================================================

async function suppliedPasscodeScenario() {
  const dir = scratchDir('supplied-code');

  // --- init --code, in the untidy spelling a code arrives in from a chat
  //     message: lower case, with a dash through it
  const file = path.join(dir, 'chosen.json');
  const chosen = await runCli(['init', '--yes', '--code', 'a7k3-p9', '--config', file], { cwd: dir });
  ok(chosen.code === cli.OK, 'init --code succeeds');
  const printed = extractCode(chosen.stdout, 'init --code prints the passcode it was given');
  ok(printed === 'A7K3P9', `the supplied code round-trips, normalised (got ${printed})`);
  ok(readConfigFile(file).auth.credentials[0].secret === 'A7K3P9',
    'and is what lands on disk, in its normalised form -- not the spelling that was typed');
  ok(auth.normalizeCode('a7k3-p9') === readConfigFile(file).auth.credentials[0].secret,
    'so the hub answers to the code the host chose, however they spell it back');

  // --- a passcode that will not normalise is a usage error that names the
  //     alphabet, and never echoes what was typed
  const badFile = path.join(dir, 'bad.json');
  const bad = await runCli(['init', '--yes', '--code', 'A7K3P', '--config', badFile], { cwd: dir });
  ok(bad.code === cli.USAGE, 'a passcode that will not normalise is a usage error (exit 2)');
  ok(!fs.existsSync(badFile), 'and no config is written');
  ok(bad.stderr.includes(auth.ALPHABET), 'the refusal names the alphabet in full');
  ok(/I, L, O and U/.test(bad.stderr), 'and says which letters are missing from it, and why');
  ok(!bad.stderr.includes('A7K3P'),
    'but never echoes what was typed -- a near-miss passcode is still nearly a passcode');

  const noValue = await runCli(['init', '--yes', '--code', '--config', badFile], { cwd: dir });
  ok(noValue.code === cli.USAGE, '--code with nothing after it is a usage error too');

  // --- invite --code: the same choice, for a hub that already exists
  const invited = await runCli(
    ['invite', '--code', 'zz9 yy8', '--label', 'LAN game', '--config', file], { cwd: dir });
  ok(invited.code === cli.OK, 'invite --code succeeds');
  const invitedCode = extractCode(invited.stdout, 'invite --code prints the code it was given');
  ok(invitedCode === 'ZZ9YY8', `invite --code normalises the same way (got ${invitedCode})`);
  ok(readConfigFile(file).auth.credentials.some((c) => c.secret === 'ZZ9YY8'),
    'and the chosen code is on disk beside the first one');

  const badInvite = await runCli(['invite', '--code', 'nope!', '--config', file], { cwd: dir });
  ok(badInvite.code === cli.USAGE, 'invite --code refuses an unusable passcode with a usage error');
  ok(badInvite.stderr.includes(auth.ALPHABET), 'naming the alphabet there too');
  ok(readConfigFile(file).auth.credentials.length === 2,
    'and mints nothing when it refuses');

  // --- the same code twice is refused: verify() would match the first entry,
  //     so the second one's expiry and use budget would never be spent
  const duplicate = await runCli(['invite', '--code', 'ZZ9-YY8', '--config', file], { cwd: dir });
  ok(duplicate.code === cli.ERROR, 'a passcode already configured is refused');
  ok(/already configured/i.test(duplicate.stderr), 'and says so');
  ok(readConfigFile(file).auth.credentials.length === 2, 'without adding a duplicate');

  // --- and the wizard asks for one, rather than asking whether to require one
  const wizardFile = path.join(dir, 'wizard.json');
  const wizard = await withTimeout(
    runCli(['init', '--config', wizardFile], {
      cwd: dir,
      stdin: pacedStdin(['', '', 'q4w5e6', '']),
    }), 5000, 'the wizard to take a passcode');
  ok(wizard.code === cli.OK, 'the wizard finishes');
  ok(/Passcode/i.test(wizard.stdout), 'and asks for a passcode');
  ok(!/Require a join code/i.test(wizard.stdout),
    'and no longer asks whether to require one -- that question had a wrong answer');
  ok(readConfigFile(wizardFile).auth.credentials[0].secret === 'Q4W5E6',
    'the passcode typed at the prompt is the one stored');
  ok(readConfigFile(wizardFile).auth.required === true,
    'and the config it writes requires it');
}

// =====================================================================
// every LEAF_PATHS entry is reachable through config set / config get
// =====================================================================

function testValueFor(dotted) {
  if (dotted in config.BOUNDS) {
    const [min, max] = config.BOUNDS[dotted];
    const value = Math.min(max, min + 1);
    return { raw: String(value), expected: value };
  }
  switch (dotted) {
    case 'listen.host': return { raw: '127.0.0.2', expected: '127.0.0.2' };
    case 'auth.required': return { raw: 'false', expected: false };
    case 'network.upnp.enabled': return { raw: 'true', expected: true };
    case 'log.level': return { raw: 'debug', expected: 'debug' };
    case 'bans': return { raw: '203.0.113.9', expected: [limits.normalizeIp('203.0.113.9')] };
    case 'allowlist': return { raw: '198.51.100.4', expected: [limits.normalizeIp('198.51.100.4')] };
    // The wave-2 leaf (docs/plans/server-live-ops.md §3) the BOUNDS-only
    // sweep would miss.
    case 'motd': return { raw: 'Reboot at 10pm, back in five.', expected: 'Reboot at 10pm, back in five.' };
    default: return null;
  }
}

async function configLeafPathScenario() {
  const dir = scratchDir('leaf-paths');
  const file = path.join(dir, 'config.json');
  const init = await runCli(['init', '--yes', '--config', file], { cwd: dir });
  ok(init.code === cli.OK, 'a config exists to drive config set against');

  const driven = [];
  const refused = [];
  const cannotSet = [];

  for (const dotted of config.LEAF_PATHS) {
    if (EXCEPT_PATHS.has(dotted)) {
      const result = await runCli(['config', 'set', dotted, 'x', '--config', file], { cwd: dir });
      ok(result.code === cli.USAGE, `config set ${dotted} is refused with a usage exit code`);
      ok(result.stderr.trim().length > 0, `config set ${dotted} explains why it is refused`);
      refused.push(dotted);
      continue;
    }

    const tv = testValueFor(dotted);
    if (!tv) {
      cannotSet.push({ dotted, reason: 'no test value mapped for this leaf in this suite' });
      continue;
    }

    const setResult = await runCli(['config', 'set', dotted, tv.raw, '--config', file], { cwd: dir });
    ok(setResult.code === cli.OK, `config set ${dotted} ${tv.raw} succeeds`);

    const getResult = await runCli(['config', 'get', dotted, '--config', file], { cwd: dir });
    ok(getResult.code === cli.OK, `config get ${dotted} succeeds`);

    const printed = getResult.stdout.trim();
    const gotFromCli = Array.isArray(tv.expected) ? JSON.parse(printed) : printed;
    const expectedForCompare = Array.isArray(tv.expected) ? tv.expected : String(tv.expected);
    ok(same(gotFromCli, expectedForCompare),
      `config get ${dotted} reads back what was just set (got ${printed}, wanted ${JSON.stringify(expectedForCompare)})`);

    const onDiskValue = config.getPath(readConfigFile(file), dotted);
    ok(same(onDiskValue, tv.expected), `${dotted} is really on disk as ${JSON.stringify(tv.expected)}`);

    driven.push(dotted);
  }

  ok(driven.length + refused.length + cannotSet.length === config.LEAF_PATHS.length,
    'every LEAF_PATHS entry was accounted for (driven, refused-by-design, or reported as uncovered)');

  /*
   * The auth-failure throttle arrived as seven new leaves, and a knob that is
   * only reachable by hand-editing JSON is the exact thing this file exists to
   * catch. Named explicitly rather than left to the count above, which would
   * stay green if all seven quietly landed in `cannotSet`.
   */
  for (const dotted of AUTH_LIMIT_PATHS) {
    ok(config.LEAF_PATHS.includes(dotted), `${dotted} is a real setting`);
    ok(driven.includes(dotted), `${dotted} was really driven through config set / config get`);
    ok(dotted in config.BOUNDS, `${dotted} has a clamp range, so a wild value is pulled back`);
  }

  console.log(`\n  LEAF_PATHS driven (${driven.length}): ${driven.join(', ')}`);
  console.log(`  LEAF_PATHS refused by design (${refused.length}): ${refused.join(', ')}`);
  if (cannotSet.length) {
    console.log(`  LEAF_PATHS NOT covered (${cannotSet.length}):`);
    for (const { dotted, reason } of cannotSet) console.log(`    ${dotted}: ${reason}`);
  }
}

// =====================================================================
// config set reports clamping before saving
// =====================================================================

async function clampReportScenario() {
  const dir = scratchDir('clamp');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  const result = await runCli(['config', 'set', 'maxPlayers', '9999', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'an out-of-range value is accepted, not refused');
  ok(/adjusted:.*maxPlayers.*9999.*lowered to 64/.test(result.stdout),
    'the clamp is reported: the host is told what the value became');

  const adjustedAt = result.stdout.indexOf('adjusted:');
  const reportedAt = result.stdout.indexOf('maxPlayers = 64');
  ok(adjustedAt >= 0 && reportedAt > adjustedAt, 'the clamp note prints before the final value line');

  ok(readConfigFile(file).maxPlayers === 64, 'the clamped value, not the raw one, is what gets saved');
}

// =====================================================================
// config set motd -- reload, not restart (docs/plans/server-live-ops.md §3)
// =====================================================================

async function configSetMotdReloadRecipeScenario() {
  const dir = scratchDir('motd');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  const result = await runCli(
    ['config', 'set', 'motd', 'Back in five minutes.', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'config set motd succeeds');
  ok(readConfigFile(file).motd === 'Back in five minutes.', 'and the greeting lands on disk');

  ok(/kill -HUP/.test(result.stdout), 'the reload recipe is printed for a bare node hub');
  ok(/docker compose kill -s SIGHUP hub/.test(result.stdout), 'and for a docker one');
  ok(!/Restart the hub for this to take effect\./.test(result.stdout),
    'and the generic "restart the hub" line, which every other leaf gets, is not printed here -- ' +
    'a running hub picks the MOTD up on SIGHUP, not a restart');
}

// =====================================================================
// status shows where each value came from, and env outranks file
// =====================================================================

async function statusPrecedenceScenario() {
  const dir = scratchDir('status');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });
  await runCli(['config', 'set', 'maxPlayers', '5', '--config', file], { cwd: dir });

  const env = Object.assign(cleanEnv(), { RBY_MMO_MAX: '10' });
  const result = await runCli(['status', '--config', file], { cwd: dir, env });
  ok(result.code === cli.OK, 'status succeeds');
  ok(/^maxPlayers\s+10\s+env\b/m.test(result.stdout),
    'maxPlayers is set both by file (5) and env (10); status reports env as the winner, with its value');
}

// =====================================================================
// players / ranking -- fixture files written by hand, never a real hub
// =====================================================================
//
// Neither verb goes anywhere near lib/server.js (plan §3, docs/plans/
// server-side-listing.md): the contract *is* the interface, so every
// scenario below writes status.json / ranking.json into a scratch config
// dir exactly as the plan describes them, and drives `players` / `ranking`
// against that. server.test.js is where the hub is proven to write files
// this shape; this file only proves the CLI reads them honestly.

const CONTRACT_FIELDS = [
  'name', 'sprite', 'map', 'x', 'y', 'busy', 'party', 'points', 'ranked',
  'admin',  // 0.9.0: the roster's own flag, carried through to --json
].sort();

function writeJson(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

function statusFixture(overrides = {}) {
  return Object.assign({
    version: 1,
    startedAt: Date.now() - 60000,
    updatedAt: Date.now(),
    stoppedAt: null,
    heartbeatMs: 10000,
    host: '0.0.0.0',
    port: 7788,
    protocol: 5,
    maxPlayers: 8,
    players: [],
  }, overrides);
}

function playerRow(overrides = {}) {
  return Object.assign({
    name: 'RED', sprite: 'SPRITE_RED', map: 'PALLET_TOWN', x: 5, y: 6,
    busy: false, party: false, points: 12, ranked: true,
  }, overrides);
}

/*
 * "No raw control characters on stderr" does not mean "no newlines" --
 * ctx.warn() ends every line of its own output with one, and that is the
 * formatting the terminal is supposed to see. What must never reach it is a
 * byte that came out of a file somebody hand-edited and could move the
 * cursor or repaint the line -- an ESC among them. \n, \r and \t are the
 * CLI's own formatting and are excluded on purpose.
 */
function hasRawControlChars(text) {
  return /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(String(text));
}

async function playersLiveScenario() {
  const dir = scratchDir('players-live');
  const file = path.join(dir, 'config.json');
  writeJson(path.join(dir, 'status.json'), statusFixture({
    players: [
      playerRow({ name: 'RED', map: 'PALLET_TOWN', points: 12, ranked: true }),
      playerRow({
        name: 'BLUE', map: null, x: null, y: null, busy: true, points: 0, ranked: false,
      }),
    ],
  }));

  const result = await runCli(['players', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'a live snapshot succeeds');
  ok(/2 player\(s\) online/.test(result.stdout), 'and reports the count');
  ok(result.stdout.includes('PALLET TOWN'), 'PALLET_TOWN is formatted for reading');
  ok(!result.stdout.includes('PALLET_TOWN'),
    'and the underscored engine id itself is never shown');

  const redRow = result.stdout.split('\n').find((line) => line.startsWith('RED'));
  ok(!!redRow && /\b12\b/.test(redRow), 'a ranked player shows their points');

  const blueRow = result.stdout.split('\n').find((line) => line.startsWith('BLUE'));
  ok(!!blueRow, 'the second player has a row');
  const blueCells = blueRow.trimEnd().split(/\s{2,}/);
  ok(blueCells[1] === '-', 'a null map (in a battle or menu) prints as a dash for LOCATION');
  ok(/BUSY/.test(blueRow), 'and their BUSY status shows');
  ok(blueCells[blueCells.length - 1] !== '0',
    'an unranked player shows a blank POINTS cell, not a zero');
}

async function playersEmptyScenario() {
  const dir = scratchDir('players-empty');
  const file = path.join(dir, 'config.json');
  writeJson(path.join(dir, 'status.json'), statusFixture({ players: [] }));

  const result = await runCli(['players', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'an empty roster is not an error');
  ok(/Nobody is online/i.test(result.stdout), 'and says plainly that nobody is online');
}

async function playersStoppedScenario() {
  const dir = scratchDir('players-stopped');
  const file = path.join(dir, 'config.json');
  writeJson(path.join(dir, 'status.json'), statusFixture({
    stoppedAt: Date.now() - 5000, players: [],
  }));

  const result = await runCli(['players', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'a cleanly-stopped hub is not reported as an error');
  ok(/stopped/i.test(result.stdout), 'and says the hub stopped');
  ok(/nobody is online/i.test(result.stdout), 'because nobody can be, once it has');
}

async function playersStaleScenario() {
  const dir = scratchDir('players-stale');
  const file = path.join(dir, 'config.json');
  // default heartbeatMs is 10000, so 2.5x is 25000 -- 30s old is well past it.
  writeJson(path.join(dir, 'status.json'), statusFixture({
    updatedAt: Date.now() - 30000,
    players: [playerRow({ name: 'GHOST' })],
  }));

  const result = await runCli(['players', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'a stale snapshot is reported, not treated as an error');
  ok(/appears to be down/i.test(result.stdout), 'and says the hub appears to be down');
}

async function playersStaleRespectsNonstandardHeartbeatScenario() {
  const dir = scratchDir('players-heartbeat');
  const file = path.join(dir, 'config.json');
  const statusFile = path.join(dir, 'status.json');

  // heartbeatMs 30000 -> the 2.5x staleness ceiling is 75000ms, not the
  // built-in default's 25000 -- the snapshot's own schedule has to win.
  writeJson(statusFile, statusFixture({
    heartbeatMs: 30000, updatedAt: Date.now() - 60000, players: [],
  }));
  const live = await runCli(['players', '--config', file], { cwd: dir });
  ok(!/appears to be down/i.test(live.stdout),
    '60s old is still live against a 30s heartbeat (threshold 75s)');

  writeJson(statusFile, statusFixture({
    heartbeatMs: 30000, updatedAt: Date.now() - 100000, players: [],
  }));
  const stale = await runCli(['players', '--config', file], { cwd: dir });
  ok(/appears to be down/i.test(stale.stdout),
    '100s old is stale against the same 30s heartbeat (threshold 75s)');
}

async function playersMissingScenario() {
  const dir = scratchDir('players-missing');
  const file = path.join(dir, 'config.json');

  const result = await runCli(['players', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'a missing snapshot is not an error');
  ok(/No status snapshot/.test(result.stderr),
    'and says plainly that there is none, on stderr');
}

async function playersCorruptJsonScenario() {
  const dir = scratchDir('players-corrupt');
  const file = path.join(dir, 'config.json');
  // An ESC byte, deliberately: V8's JSON.parse error message quotes the
  // offending bytes back verbatim, and a hand-edited file is exactly the
  // thing this path exists to survive -- the hub's own writes are always
  // well-formed.
  fs.writeFileSync(path.join(dir, 'status.json'),
    `{"version":1,"players":[${String.fromCharCode(0x1b)}]}`);

  const result = await runCli(['players', '--config', file], { cwd: dir });
  ok(result.code === cli.ERROR, 'a corrupt snapshot is a runtime error');
  ok(/not readable as JSON/.test(result.stderr), 'naming what is wrong with it');
  ok(!hasRawControlChars(result.stderr),
    'and the parse error is sanitised before it reaches the terminal');
}

async function playersUndatedEmptyScenario() {
  const dir = scratchDir('players-undated');
  const file = path.join(dir, 'config.json');
  const fixture = statusFixture({ players: [] });
  delete fixture.updatedAt;
  writeJson(path.join(dir, 'status.json'), fixture);

  const result = await runCli(['players', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'an undated, empty snapshot is not an error');
  ok(/cannot be told/i.test(result.stdout), 'and says its age cannot be told');
  ok(/Nobody was online/i.test(result.stdout), 'short-circuiting straight to the empty case');
}

async function playersJsonScenario() {
  const dir = scratchDir('players-json');
  const file = path.join(dir, 'config.json');
  writeJson(path.join(dir, 'status.json'), statusFixture({
    players: [
      Object.assign(playerRow({ party: true, admin: true }), {
        // extras a newer hub, or a hand-edit, might carry -- none of this is
        // part of the contract and none of it may survive the projection.
        id: '1', sessionId: '2', partyId: '3', address: '203.0.113.1', tokenHash: 'x',
      }),
      // A hand-edit's idea of true. `admin` is read strictly, so this is a
      // player like any other and a script cannot be talked into believing
      // otherwise by a snapshot somebody wrote by hand.
      playerRow({ name: 'BLUE', admin: 'yes' }),
    ],
  }));

  const result = await runCli(['players', '--json', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, '--json succeeds against a live snapshot');
  const parsed = JSON.parse(result.stdout);
  ok(Array.isArray(parsed) && parsed.length === 2, 'the players array comes through');
  ok(parsed[0].admin === true, 'an admin connection is marked as one in --json');
  ok(parsed[1].admin === false, 'and a truthy spelling of the flag is not privilege');
  ok(JSON.stringify(Object.keys(parsed[0]).sort()) === JSON.stringify(CONTRACT_FIELDS),
    `--json emits exactly the ${CONTRACT_FIELDS.length} contract fields, in some order`);
  ok(!('id' in parsed[0]) && !('sessionId' in parsed[0]) && !('partyId' in parsed[0])
    && !('address' in parsed[0]) && !('tokenHash' in parsed[0]),
    'and every extra field is dropped rather than passed through');
}

async function playersHonoursConfigScenario() {
  const targetDir = scratchDir('players-config-target');
  const otherDir = scratchDir('players-config-other');
  const file = path.join(targetDir, 'config.json');

  writeJson(path.join(targetDir, 'status.json'),
    statusFixture({ players: [playerRow({ name: 'HERE' })] }));
  // A second, different snapshot sitting beside the *current working
  // directory* -- which must be ignored the moment --config points elsewhere.
  writeJson(path.join(otherDir, 'status.json'),
    statusFixture({ players: [playerRow({ name: 'WRONGDIR' })] }));

  const result = await runCli(['players', '--config', file], { cwd: otherDir });
  ok(result.code === cli.OK, 'players succeeds with an explicit --config');
  ok(result.stdout.includes('HERE'), 'and reads the snapshot beside the given config file');
  ok(!result.stdout.includes('WRONGDIR'),
    'never the one that happens to sit beside the current working directory');
}

// =====================================================================
// watch -- players on a timer; --once is the whole testable path
// =====================================================================
//
// The loop itself (Ctrl-C, repeated repaints) is not exercised here: it
// runs until a signal arrives, which is not a shape a suite should be
// racing against. `--once` is the path the plan built specifically so this
// file could assert on it -- render one frame, report that frame's own
// exit code, and stop.

function hasEsc(text) {
  return String(text).includes('\u001b');
}

async function watchOnceMatchesPlayersScenario() {
  const dir = scratchDir('watch-once');
  const file = path.join(dir, 'config.json');
  writeJson(path.join(dir, 'status.json'), statusFixture({
    players: [playerRow({ name: 'RED', map: 'PALLET_TOWN', points: 12, ranked: true })],
  }));

  const players = await runCli(['players', '--config', file], { cwd: dir });
  const watch = await runCli(['watch', '--once', '--config', file], { cwd: dir });

  ok(watch.code === cli.OK, 'watch --once succeeds');
  ok(watch.code === players.code, 'and its exit code matches `players`\' own');
  ok(watch.stdout === players.stdout,
    'watch --once renders exactly the frame `players` would, byte for byte');
  ok(watch.stderr === players.stderr, 'including anything said on stderr');

  ok(!hasEsc(watch.stdout) && !hasEsc(watch.stderr),
    'a non-TTY sink sees no ESC byte at all: the clear-screen sequence is gated on isTTY');
}

async function watchOnceJsonScenario() {
  const dir = scratchDir('watch-once-json');
  const file = path.join(dir, 'config.json');
  writeJson(path.join(dir, 'status.json'), statusFixture({
    players: [playerRow({ name: 'BLUE' })],
  }));

  const result = await runCli(['watch', '--once', '--json', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'watch --once --json succeeds');
  const parsed = JSON.parse(result.stdout);
  ok(Array.isArray(parsed) && parsed.length === 1, 'and prints one JSON frame, parseable whole');
  ok(!hasEsc(result.stdout) && !hasEsc(result.stderr), 'still no ESC byte in a --json frame');
}

async function watchBadIntervalScenario() {
  const dir = scratchDir('watch-bad-interval');
  const file = path.join(dir, 'config.json');
  writeJson(path.join(dir, 'status.json'), statusFixture({ players: [] }));

  const nonNumeric = await runCli(
    ['watch', '--once', '--interval', 'soon', '--config', file], { cwd: dir });
  ok(nonNumeric.code === cli.USAGE, '--interval "soon" is a usage error (exit 2)');
  ok(/not a number of seconds/.test(nonNumeric.stderr), 'and says why');

  const noValue = await runCli(
    ['watch', '--once', '--interval', '--config', file], { cwd: dir });
  ok(noValue.code === cli.USAGE, '--interval with nothing after it is a usage error too');

  /*
   * --interval 0 is a number, just outside the 1-60s range -- watchInterval()
   * clamps it the same way config.js clamps an out-of-range setting, rather
   * than refusing it. So this is the one "bad" interval that is NOT exit 2:
   * `--once` still renders its frame and exits OK, with the clamp reported.
   */
  const zero = await runCli(
    ['watch', '--once', '--interval', '0', '--config', file], { cwd: dir });
  ok(zero.code === cli.OK,
    '--interval 0 is clamped to the 1-60s range rather than refused, so --once still exits 0');
  ok(/adjusted:.*--interval 0.*using 1s/.test(zero.stderr),
    'and the clamp is reported, the same way an out-of-range config value would be');
}

// ---------------------------------------------------------------- ranking

async function rankingTopTenScenario() {
  const dir = scratchDir('ranking-top10');
  const file = path.join(dir, 'config.json');
  // Eleven ranked players plus one at zero: a tie at the cutoff boundary
  // (TWOA/TWOB, both 20) to pin the name-ascending tiebreak, and an 11th
  // ranked player (ONE) that only --all should surface.
  const players = [
    { name: 'TEN', points: 100 }, { name: 'NINE', points: 90 },
    { name: 'EIGHT', points: 80 }, { name: 'SEVEN', points: 70 },
    { name: 'SIX', points: 60 }, { name: 'FIVE', points: 50 },
    { name: 'FOUR', points: 40 }, { name: 'THREE', points: 30 },
    { name: 'TWOB', points: 20 }, { name: 'TWOA', points: 20 },
    { name: 'ONE', points: 10 }, { name: 'ZERO', points: 0 },
  ].map((row) => Object.assign({ sprite: 'SPRITE_RED', played: 1, won: 1 }, row));
  writeJson(path.join(dir, 'ranking.json'), { version: 1, players });

  // A table row is a place number followed by the column padding (2+
  // spaces); the closing "N ranked player(s) -- the whole board." sentence
  // also starts with a digit, but with a single space, so this tells them
  // apart without depending on how many rows are on screen.
  const rowNames = (stdout) => stdout.split('\n')
    .filter((line) => /^\d+\s{2,}/.test(line))
    .map((line) => line.trim().split(/\s+/)[1]);

  const top = await runCli(['ranking', '--config', file], { cwd: dir });
  ok(top.code === cli.OK, 'ranking succeeds against a fixture ranking.json');
  const topNames = rowNames(top.stdout);
  ok(topNames.length === 10, 'the default cut is ten rows');
  ok(topNames.join(',') === 'TEN,NINE,EIGHT,SEVEN,SIX,FIVE,FOUR,THREE,TWOA,TWOB',
    'sorted by points descending, ties broken by name ascending (TWOA before TWOB)');
  ok(!topNames.includes('ONE'), 'the 11th-ranked player is cut by the default top ten');
  ok(!top.stdout.includes('ZERO'), 'and a zero-point player never appears, cut or not');

  const all = await runCli(['ranking', '--all', '--config', file], { cwd: dir });
  ok(all.code === cli.OK, '--all succeeds');
  const allNames = rowNames(all.stdout);
  ok(allNames.length === 11, '--all prints every ranked player');
  ok(allNames.includes('ONE'), 'including the one the default cut left out');
  ok(!all.stdout.includes('ZERO'), 'but still never the zero-point player');
}

async function rankingJsonScenario() {
  const dir = scratchDir('ranking-json');
  const file = path.join(dir, 'config.json');
  writeJson(path.join(dir, 'ranking.json'), {
    version: 1,
    players: [
      { name: 'ASH', sprite: 'SPRITE_RED', points: 40, played: 3, won: 2, tokenHash: 'a'.repeat(64) },
      { name: 'GARY', sprite: 'SPRITE_RED', points: 0, played: 1, won: 0, tokenHash: 'b'.repeat(64) },
    ],
  });

  const result = await runCli(['ranking', '--json', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'ranking --json succeeds');
  const parsed = JSON.parse(result.stdout);
  ok(parsed.length === 1, 'the zero-point row is excluded from --json too');
  ok(parsed[0].name === 'ASH' && parsed[0].place === 1, 'the ranked player is named, with a place');
  ok(!('tokenHash' in parsed[0]),
    'the stored claim-ticket digest is the hub\'s business and never reaches this output');
}

async function rankingEmptyScenario() {
  const dir = scratchDir('ranking-empty');
  const file = path.join(dir, 'config.json');
  writeJson(path.join(dir, 'ranking.json'), { version: 1, players: [] });

  const result = await runCli(['ranking', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'an empty ranking is not an error');
  ok(/ranking is empty/i.test(result.stdout), 'and says so');

  const zeroDir = scratchDir('ranking-empty-allzero');
  const zeroFile = path.join(zeroDir, 'config.json');
  writeJson(path.join(zeroDir, 'ranking.json'),
    { version: 1, players: [{ name: 'NOBODY', points: 0 }] });
  const zeroResult = await runCli(['ranking', '--config', zeroFile], { cwd: zeroDir });
  ok(zeroResult.code === cli.OK, 'a board of nothing but zero-point rows is also empty');
  ok(/ranking is empty/i.test(zeroResult.stdout), 'and reported the same way');
}

async function rankingMissingScenario() {
  const dir = scratchDir('ranking-missing');
  const file = path.join(dir, 'config.json');

  const result = await runCli(['ranking', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'a missing ranking file is not an error');
  ok(/No ranking file/.test(result.stderr), 'and says plainly that there is none');
}

async function rankingHonoursConfigScenario() {
  const targetDir = scratchDir('ranking-config-target');
  const otherDir = scratchDir('ranking-config-other');
  const file = path.join(targetDir, 'config.json');

  writeJson(path.join(targetDir, 'ranking.json'),
    { version: 1, players: [{ name: 'HERE', points: 10 }] });
  writeJson(path.join(otherDir, 'ranking.json'),
    { version: 1, players: [{ name: 'WRONGDIR', points: 10 }] });

  const result = await runCli(['ranking', '--config', file], { cwd: otherDir });
  ok(result.code === cli.OK, 'ranking succeeds with an explicit --config');
  ok(result.stdout.includes('HERE'), 'and reads the ranking beside the given config file');
  ok(!result.stdout.includes('WRONGDIR'),
    'never the one that happens to sit beside the current working directory');
}

// --- W and L: a projection of played/won that has always been on the file,
//     never new state (plan §3, docs/plans/server-live-ops.md).

async function rankingWinLossScenario() {
  const dir = scratchDir('ranking-winloss');
  const file = path.join(dir, 'config.json');
  writeJson(path.join(dir, 'ranking.json'), {
    version: 1,
    players: [
      { name: 'ASH', sprite: 'SPRITE_RED', points: 40, played: 5, won: 3 },
      { name: 'MISTY', sprite: 'SPRITE_RED', points: 10, played: 1, won: 1 },
    ],
  });

  const findRow = (stdout, name) => stdout.split('\n')
    .filter((line) => /^\d+\s{2,}/.test(line))
    .map((line) => line.trim().split(/\s+/))
    .find((cells) => cells[1] === name);

  const result = await runCli(['ranking', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'ranking with played/won succeeds');
  ok(/\bW\b/.test(result.stdout) && /\bL\b/.test(result.stdout), 'W and L columns are printed');

  const ashRow = findRow(result.stdout, 'ASH');
  ok(!!ashRow, 'ASH has a row');
  ok(ashRow && ashRow[3] === '3', `ASH's W column is won (3), got ${ashRow && ashRow[3]}`);
  ok(ashRow && ashRow[4] === '2',
    `ASH's L column is played-won (5-3=2), got ${ashRow && ashRow[4]}`);

  const mistyRow = findRow(result.stdout, 'MISTY');
  ok(!!mistyRow, 'MISTY has a row');
  ok(mistyRow && mistyRow[3] === '1' && mistyRow[4] === '0',
    'a player who has never lost shows L as 0, not blank or negative');

  const jsonResult = await runCli(['ranking', '--json', '--config', file], { cwd: dir });
  ok(jsonResult.code === cli.OK, 'ranking --json succeeds');
  const rows = JSON.parse(jsonResult.stdout);
  const ash = rows.find((row) => row.name === 'ASH');
  ok(!!ash && ash.played === 5 && ash.won === 3,
    '--json carries played and won -- the fields W/L on the table are projected from');
}

// =====================================================================
// history -- settled ranked battles, both generations, newest first
// =====================================================================

function historyRecordFixture(label, atMs) {
  return {
    at: atMs,
    startedAt: atMs - 5000,
    repeats: 0,
    winner: { name: `${label}W`, points: 50, gained: 16 },
    loser: { name: `${label}L`, points: 10, lost: 16 },
  };
}

function writeHistoryFile(file, lines) {
  fs.writeFileSync(file, `${lines
    .map((line) => (typeof line === 'string' ? line : JSON.stringify(line)))
    .join('\n')}\n`);
}

async function historyBothGenerationsScenario() {
  const dir = scratchDir('history-both');
  const file = path.join(dir, 'config.json');
  const now = Date.now();

  // Older generation: two settled battles and one torn line, in file order.
  writeHistoryFile(path.join(dir, 'history.jsonl.1'), [
    historyRecordFixture('OLD1', now - 4000),
    '{not valid json',
    historyRecordFixture('OLD2', now - 3000),
  ]);
  // Current generation: same shape, newer battles.
  writeHistoryFile(path.join(dir, 'history.jsonl'), [
    historyRecordFixture('NEW1', now - 2000),
    '{also not valid',
    historyRecordFixture('NEW2', now - 1000),
  ]);

  const result = await runCli(['history', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'history over two generations succeeds');

  const winnerOrder = result.stdout.split('\n')
    .filter((line) => /\+16\/-16/.test(line))
    .map((line) => line.trim().split(/\s+/)[1]);
  ok(winnerOrder.join(',') === 'NEW2W,NEW1W,OLD2W,OLD1W',
    `newest first across both generations, oldest last (got ${winnerOrder.join(',')})`);

  ok(/4 settled ranked battle\(s\)/.test(result.stdout),
    'the footer count spans both generations (4, not 2 from either alone)');

  ok(/note: 2 line\(s\)/.test(result.stderr),
    'both torn lines are counted -- one per generation, not just the current one');
  ok(/history\.jsonl and history\.jsonl\.1/.test(result.stderr),
    'and the note names both files by name');
}

async function historyCountAndBadCountScenario() {
  const dir = scratchDir('history-count');
  const file = path.join(dir, 'config.json');
  const now = Date.now();
  writeHistoryFile(path.join(dir, 'history.jsonl.1'), [
    historyRecordFixture('OLD1', now - 4000),
    historyRecordFixture('OLD2', now - 3000),
  ]);
  writeHistoryFile(path.join(dir, 'history.jsonl'), [
    historyRecordFixture('NEW1', now - 2000),
    historyRecordFixture('NEW2', now - 1000),
  ]);

  const cut = await runCli(['history', '-n', '3', '--config', file], { cwd: dir });
  ok(cut.code === cli.OK, 'history -n 3 succeeds');
  const winnerOrder = cut.stdout.split('\n')
    .filter((line) => /\+16\/-16/.test(line))
    .map((line) => line.trim().split(/\s+/)[1]);
  ok(winnerOrder.join(',') === 'NEW2W,NEW1W,OLD2W',
    '-n 3 keeps the three newest, cutting across the generation boundary');

  const badNumber = await runCli(['history', '-n', 'abc', '--config', file], { cwd: dir });
  ok(badNumber.code === cli.USAGE, '-n abc is a usage error (exit 2)');

  const badZero = await runCli(['history', '-n', '0', '--config', file], { cwd: dir });
  ok(badZero.code === cli.USAGE, '-n 0 is a usage error too -- not one result, none at all');
}

async function historyJsonScenario() {
  const dir = scratchDir('history-json');
  const file = path.join(dir, 'config.json');
  const now = Date.now();
  writeHistoryFile(path.join(dir, 'history.jsonl'), [
    historyRecordFixture('SOLO', now - 1000),
  ]);

  const result = await runCli(['history', '--json', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'history --json succeeds');
  const parsed = JSON.parse(result.stdout);
  ok(Array.isArray(parsed) && parsed.length === 1, 'one record comes through, as a JSON array');
  const record = parsed[0];
  ok(record.winner.name === 'SOLOW' && record.winner.gained === 16,
    'the winner side carries name and gained, per the record contract');
  ok(record.loser.name === 'SOLOL' && record.loser.lost === 16,
    'the loser side carries name and lost');
  ok(typeof record.at === 'number' && typeof record.startedAt === 'number'
    && typeof record.repeats === 'number',
    'and the record-level fields (at, startedAt, repeats) are projected too');
}

async function historyRotatedOnlyScenario() {
  const dir = scratchDir('history-rotated-only');
  const file = path.join(dir, 'config.json');
  const now = Date.now();
  // No current history.jsonl at all -- a hub that rotated and has settled
  // nothing since, or a host who moved the current file aside by hand.
  writeHistoryFile(path.join(dir, 'history.jsonl.1'), [
    historyRecordFixture('ONLY', now - 1000),
  ]);

  const result = await runCli(['history', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'a .1-only ledger still reads');
  ok(result.stdout.includes('ONLYW'), 'and its record shows up');
  ok(/1 settled ranked battle/.test(result.stdout), 'counted as the one record it holds');
}

async function historyMissingScenario() {
  const dir = scratchDir('history-missing');
  const file = path.join(dir, 'config.json');

  const result = await runCli(['history', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'no history file at all is not an error');
  ok(/No match history/.test(result.stderr), 'and says plainly that there is none');

  const asJson = await runCli(['history', '--json', '--config', file], { cwd: dir });
  ok(asJson.code === cli.OK, 'and --json still succeeds when there is nothing to show');
  ok(asJson.stdout.trim() === '[]', 'emitting an empty array rather than nothing at all');
}

// =====================================================================
// kick / broadcast -- the admin socket, dialled from the CLI side
// =====================================================================
//
// lib/admin.js binds the real socket and has its own suite (server.test.js,
// T2); this section only proves the CLI's *client* half: it dials whatever
// is at admin.sock beside the config file and turns the answer -- or its
// absence -- into the right exit code and sentence. Every scenario below is
// a hand-rolled fixture speaking the newline-JSON protocol documented in
// docs/plans/server-live-ops.md §3; none of it goes through lib/admin.js.
//
// Unix domain socket paths are capped (~104 bytes on darwin), and the
// scratch tree everywhere else in this file -- mkdtemp under os.tmpdir(),
// plus a numbered subdirectory -- is already close enough to that ceiling
// that stacking "admin.sock" on top of it is not safe. So this section
// keeps its own short directories straight under os.tmpdir(), tracked here
// and swept in main()'s finally alongside ROOT.

const ADMIN_TMP_DIRS = [];
function adminScratchDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rby-a-'));
  ADMIN_TMP_DIRS.push(dir);
  return dir;
}

function cleanupAdminScratchDirs() {
  for (const dir of ADMIN_TMP_DIRS) {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch (err) { /* best effort -- a leftover temp dir costs nothing */ }
  }
}

/**
 * A fixture admin socket: one connection, one line in, `respond(request)`
 * decides the line out. `respond` returning `undefined` means "never
 * answer" -- how the CLI's own timeout path is driven, below.
 */
function startAdminFixture(socketPath, respond) {
  return new Promise((resolve, reject) => {
    const server = net.createServer((socket) => {
      let buffer = '';
      socket.on('error', () => { /* a client that vanishes mid-exchange is ordinary */ });
      socket.on('data', (chunk) => {
        buffer += chunk;
        const newline = buffer.indexOf('\n');
        if (newline < 0) return;
        let request = null;
        try {
          request = JSON.parse(buffer.slice(0, newline));
        } catch (err) { /* malformed on purpose, in some scenarios */ }
        const result = respond(request);
        if (result === undefined) return; // deliberately never answers
        try {
          socket.end(`${JSON.stringify(result)}\n`);
        } catch (err) { /* the peer is already gone */ }
      });
    });
    server.once('error', reject);
    server.listen(socketPath, () => {
      server.removeListener('error', reject);
      resolve(server);
    });
  });
}

function closeAdminFixture(server) {
  return new Promise((resolve) => server.close(resolve));
}

async function kickHappyScenario() {
  const dir = adminScratchDir();
  const file = path.join(dir, 'config.json');
  let seenRequest = null;
  const server = await startAdminFixture(path.join(dir, 'admin.sock'), (request) => {
    seenRequest = request;
    return { ok: true, kicked: 1, names: ['RED'] };
  });

  try {
    const result = await withTimeout(
      runCli(['kick', 'RED', '--config', file], { cwd: dir }), 5000, 'kick to answer');
    ok(result.code === cli.OK, 'a kick the hub grants exits 0');
    ok(result.stdout.includes('RED'), 'and the reply names who was kicked');
    ok(!!seenRequest && seenRequest.cmd === 'kick' && seenRequest.name === 'RED',
      'the request sent over the wire is {cmd:"kick", name: ...}');
  } finally {
    await closeAdminFixture(server);
  }
}

async function kickReasonScenario() {
  const dir = adminScratchDir();
  const file = path.join(dir, 'config.json');
  let seenRequest = null;
  const server = await startAdminFixture(path.join(dir, 'admin.sock'), (request) => {
    seenRequest = request;
    return { ok: true, kicked: 1, names: ['RED'] };
  });

  try {
    const result = await withTimeout(
      runCli(['kick', 'RED', '--reason', 'being', 'rude', '--config', file], { cwd: dir }),
      5000, 'kick --reason to answer');
    ok(result.code === cli.OK, 'kick with a multi-word reason still succeeds');
    ok(!!seenRequest && seenRequest.reason === 'being rude',
      'and the reason arrives joined back into one sentence, over the wire');
  } finally {
    await closeAdminFixture(server);
  }
}

async function kickNobodyScenario() {
  const dir = adminScratchDir();
  const file = path.join(dir, 'config.json');
  const server = await startAdminFixture(path.join(dir, 'admin.sock'),
    () => ({ ok: true, kicked: 0, names: [] }));

  try {
    const result = await withTimeout(
      runCli(['kick', 'NOBODY', '--config', file], { cwd: dir }), 5000, 'kick 0 to answer');
    ok(result.code === cli.OK, 'kicking nobody is still a success, not a failure');
    ok(/Nobody by that name is connected/.test(result.stdout), 'and says so honestly');
  } finally {
    await closeAdminFixture(server);
  }
}

async function broadcastHappyScenario() {
  const dir = adminScratchDir();
  const file = path.join(dir, 'config.json');
  let seenRequest = null;
  const server = await startAdminFixture(path.join(dir, 'admin.sock'), (request) => {
    seenRequest = request;
    return { ok: true, delivered: 3 };
  });

  try {
    const result = await withTimeout(
      runCli(['broadcast', 'back', 'in', 'five', '--config', file], { cwd: dir }),
      5000, 'broadcast to answer');
    ok(result.code === cli.OK, 'a broadcast the hub delivers exits 0');
    ok(/Delivered to 3 player\(s\)/.test(result.stdout), 'and reports the delivered count');
    ok(!!seenRequest && seenRequest.cmd === 'broadcast' && seenRequest.text === 'back in five',
      'the message arrives joined back into one line, as {cmd:"broadcast", text}');
  } finally {
    await closeAdminFixture(server);
  }
}

// ---------------------------------------------------------------- stats
//
// The one *question* on this channel, and the only reading no file holds.
// The fixture answers in the shape lib/admin.js's handleStats() really
// sends -- the server's stats() snapshot with the limiter's own counters
// nested under `limits` -- including the two `perIp` maps, which are the
// point of half of these checks: they arrive over the socket and must reach
// neither the table nor `--json`.

// Documentation addresses (RFC 5737), so a grep for either of them in this
// repo finds only this fixture and the assertions that they never escape it.
const STATS_ADDRESS_A = '198.51.100.23';
const STATS_ADDRESS_B = '203.0.113.9';

function statsFixture(overrides) {
  const perIp = { [STATS_ADDRESS_A]: 2, [STATS_ADDRESS_B]: 2 };
  return {
    ok: true,
    stats: Object.assign({
      host: '0.0.0.0',
      port: 7788,
      protocol: 5,
      maxPlayers: 8,
      players: 3,
      pending: 1,
      connections: 4,
      perIp,
      authRequired: true,
      startedAt: 1700000000000,
      uptimeMs: 7265000,
      limits: {
        connections: 4,
        pending: 1,
        perIp,
        auth: Object.assign({
          recentFailures: 12,
          failureThreshold: 100,
          windowMs: 60000,
          lockdown: false,
          lockdownMs: 0,
          throttledAddresses: 1,
          trackedAddresses: 2,
        }, (overrides || {}).auth),
      },
    }, (overrides || {}).stats),
  };
}

/** Every `perIp` anywhere in a parsed document, however deep it was nested. */
function findsPerIp(node) {
  if (!node || typeof node !== 'object') return false;
  if (!Array.isArray(node) && Object.prototype.hasOwnProperty.call(node, 'perIp')) return true;
  return Object.values(node).some((value) => findsPerIp(value));
}

async function statsScenario() {
  const dir = adminScratchDir();
  const file = path.join(dir, 'config.json');
  let seenRequest = null;
  const server = await startAdminFixture(path.join(dir, 'admin.sock'), (request) => {
    seenRequest = request;
    return statsFixture();
  });

  try {
    const result = await withTimeout(
      runCli(['stats', '--config', file], { cwd: dir }), 5000, 'stats to answer');
    ok(result.code === cli.OK, 'stats against a hub that answers exits 0');
    ok(!!seenRequest && seenRequest.cmd === 'stats',
      'the request sent over the wire is {cmd:"stats"}');

    // --- the hub half
    ok(/The hub/.test(result.stdout) && /The door/.test(result.stdout),
      'the table is split into the hub and the door');
    ok(/0\.0\.0\.0:7788/.test(result.stdout), 'the hub reports where it is bound');
    ok(/3 of 8/.test(result.stdout), 'and how many of its seats are taken');
    ok(/2h/.test(result.stdout), 'and its uptime, humanised rather than in milliseconds');
    ok(/1 connection\(s\) not in the world yet/.test(result.stdout),
      'and the connections that are not players yet');

    // --- the door half: every counter the page used to draw
    ok(/4 open/.test(result.stdout), 'the door reports open connections');
    ok(/from 2 address\(es\)/.test(result.stdout),
      'and how many addresses they came from -- a count, which is all a count is');
    ok(/1 connection\(s\) still to be greeted/.test(result.stdout),
      'and the handshakes the limiter has not seen finish');
    ok(/12 of 100 in the last 1m/.test(result.stdout),
      'and the recent wrong passcodes against the ceiling that trips, with its window');
    ok(/lockdown\s+no/.test(result.stdout), 'and says the ceiling is not tripped');
    ok(/1 address\(es\) backing off now/.test(result.stdout), 'and how many addresses are throttled');
    ok(/2 address\(es\) with failures remembered/.test(result.stdout),
      'and how many are still being remembered');

    // --- the roster discipline: the answer carried two addresses; neither
    //     may be anywhere in what a host could paste into a bug report
    for (const address of [STATS_ADDRESS_A, STATS_ADDRESS_B]) {
      ok(!result.stdout.includes(address) && !result.stderr.includes(address),
        `no address out of perIp reaches the terminal (${address})`);
    }
  } finally {
    await closeAdminFixture(server);
  }
}

async function statsLockdownScenario() {
  const dir = adminScratchDir();
  const file = path.join(dir, 'config.json');
  const server = await startAdminFixture(path.join(dir, 'admin.sock'),
    () => statsFixture({ auth: { lockdown: true, lockdownMs: 45000, recentFailures: 140 } }));

  try {
    const result = await withTimeout(
      runCli(['stats', '--config', file], { cwd: dir }), 5000, 'stats to answer');
    ok(result.code === cli.OK, 'a tripped ceiling is a reading, not a failure (exit 0)');
    ok(/lockdown\s+YES/.test(result.stdout), 'a tripped ceiling is shouted, not spelled "true"');
    ok(/for another 45s/.test(result.stdout), 'and says how much longer it has to run');
    ok(/new joins are refused/.test(result.stdout),
      'with a sentence saying what is actually being refused');
  } finally {
    await closeAdminFixture(server);
  }
}

async function statsJsonScenario() {
  const dir = adminScratchDir();
  const file = path.join(dir, 'config.json');
  const server = await startAdminFixture(path.join(dir, 'admin.sock'), () => statsFixture());

  try {
    const result = await withTimeout(
      runCli(['stats', '--json', '--config', file], { cwd: dir }), 5000, 'stats --json to answer');
    ok(result.code === cli.OK, 'stats --json exits 0');

    let parsed = null;
    try {
      parsed = JSON.parse(result.stdout);
    } catch (err) { /* asserted on next line */ }
    ok(!!parsed, 'and prints one JSON document a script can parse');
    ok(parsed.players === 3 && parsed.connections === 4 && parsed.limits.auth.recentFailures === 12,
      'carrying the hub\'s own counters through unchanged');

    ok(!findsPerIp(parsed), 'with no perIp key anywhere in it, at any depth');
    ok(parsed.addresses === 2 && parsed.limits.addresses === 2,
      'replaced at both levels by the count, which is the operational half of it');
    for (const address of [STATS_ADDRESS_A, STATS_ADDRESS_B]) {
      ok(!result.stdout.includes(address) && !result.stderr.includes(address),
        `and no address survives into the JSON either (${address})`);
    }
  } finally {
    await closeAdminFixture(server);
  }
}

async function statsRefusalScenario() {
  const dir = adminScratchDir();
  const file = path.join(dir, 'config.json');
  const server = await startAdminFixture(path.join(dir, 'admin.sock'),
    () => ({ ok: false, error: 'This hub could not answer "stats".' }));

  try {
    const result = await withTimeout(
      runCli(['stats', '--config', file], { cwd: dir }), 5000, 'the refusal to answer');
    ok(result.code === cli.ERROR, 'a hub that answers ok:false to stats is a refusal (exit 1)');
    ok(/could not answer/.test(result.stderr), 'and the reason travels to the terminal');
  } finally {
    await closeAdminFixture(server);
  }
}

async function adminRefusalScenario() {
  const dir = adminScratchDir();
  const file = path.join(dir, 'config.json');
  const server = await startAdminFixture(path.join(dir, 'admin.sock'),
    () => ({ ok: false, error: 'This hub cannot kick.' }));

  try {
    const result = await withTimeout(
      runCli(['kick', 'RED', '--config', file], { cwd: dir }), 5000, 'the refusal to answer');
    ok(result.code === cli.ERROR, 'a hub that answers ok:false is a real refusal (exit 1)');
    ok(/This hub cannot kick/.test(result.stderr), 'and the reason travels to the terminal');
  } finally {
    await closeAdminFixture(server);
  }
}

async function adminNoSocketScenario() {
  const dir = adminScratchDir();
  const file = path.join(dir, 'config.json');
  // No socket ever created at this path: the hub is not running, or it
  // predates the admin channel entirely.

  const kick = await runCli(['kick', 'RED', '--config', file], { cwd: dir });
  ok(kick.code === cli.OK, 'no admin socket at all is not an error for kick (exit 0)');
  ok(/No admin socket/.test(kick.stderr), 'and says plainly that there is none');
  ok(/no hub is running/.test(kick.stderr) && /predates/.test(kick.stderr),
    'naming both honest causes -- not running, or too old to have opened one');

  const broadcast = await runCli(['broadcast', 'hello', '--config', file], { cwd: dir });
  ok(broadcast.code === cli.OK, 'and the same is true for broadcast');
  ok(/No admin socket/.test(broadcast.stderr), 'with the same honest sentence');

  // `stats` is a question rather than an instruction, and gets the same
  // answer for the same reason: a hub that is not there is news, not a fault
  // of the host who asked.
  const stats = await runCli(['stats', '--config', file], { cwd: dir });
  ok(stats.code === cli.OK, 'and for stats, which asks rather than instructs (exit 0)');
  ok(/No admin socket/.test(stats.stderr), 'with that same honest copy');
  ok(/rby-mmo-hub stats/.test(stats.stderr),
    'and the Docker line it prints names the verb that was actually run');
  ok(stats.stdout === '', 'and nothing is printed on stdout, so a piped reading stays empty');
}

/**
 * A socket file that survives its process: bind it in a child, then SIGKILL
 * that child before it can close() and unlink its own socket. This is the
 * one shape a graceful close() in this same process cannot reproduce --
 * Node does remove the file on a clean close(), only not on a `kill -9`
 * (verified empirically before writing this: see the ECONNREFUSED handling
 * this exists to drive, cli.js's reportNoAdminSocket()).
 */
function spawnAdminSocketBinder(socketPath) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['-e', `
      const net = require('node:net');
      const server = net.createServer(() => {});
      server.listen(process.argv[1], () => { process.stdout.write('ready\\n'); });
    `, socketPath], { stdio: ['ignore', 'pipe', 'ignore'] });
    child.once('error', reject);
    child.stdout.once('data', () => resolve(child));
  });
}

async function adminStaleSocketScenario() {
  const dir = adminScratchDir();
  const file = path.join(dir, 'config.json');
  const socketPath = path.join(dir, 'admin.sock');

  const child = await spawnAdminSocketBinder(socketPath);
  // Wait for the *exit*, not just for the signal to be sent: SIGKILL is
  // asynchronous, and connecting while the process is still alive but not
  // yet reaped can have the kernel accept the connection into the listen
  // backlog before the process dies -- a real, if unanswered, exchange
  // rather than the ECONNREFUSED this scenario means to drive.
  const exited = new Promise((resolve) => child.once('exit', resolve));
  child.kill('SIGKILL');
  await withTimeout(exited, 5000, 'the killed admin-socket binder to exit');
  ok(fs.existsSync(socketPath), 'the socket file survives its own process dying');

  const result = await runCli(['kick', 'RED', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'a stale socket file with nothing listening is not an error (exit 0)');
  ok(/Nothing is listening/.test(result.stderr), 'and says the hub behind it is gone');
  ok(/killed rather than stopped/.test(result.stderr), 'naming why the file outlived the process');
}

async function adminTimeoutScenario() {
  const dir = adminScratchDir();
  const file = path.join(dir, 'config.json');
  // respond() returning undefined means "never answer" -- see startAdminFixture.
  const server = await startAdminFixture(path.join(dir, 'admin.sock'), () => undefined);

  try {
    /*
     * cli.js's ADMIN_TIMEOUT_MS (5s) is not exported, so there is no way to
     * shorten this from outside -- this scenario really does wait out the
     * clock. It is the one place in this suite that costs real wall time on
     * purpose; one such test is enough to prove the path exists at all.
     */
    const result = await withTimeout(
      runCli(['kick', 'RED', '--config', file], { cwd: dir }), 8000, 'the timeout itself to fire');
    ok(result.code === cli.ERROR, 'a hub that never answers is a runtime error (exit 1), not a hang');
    ok(/did not answer within/.test(result.stderr), 'and says it was a timeout, not a refusal');
  } finally {
    await closeAdminFixture(server);
  }
}

// =====================================================================
// secrets discipline
// =====================================================================

async function secretsDisciplineScenario() {
  const dir = scratchDir('secrets');
  const file = path.join(dir, 'config.json');
  const init = await runCli(['init', '--yes', '--config', file], { cwd: dir });
  const printedCode = extractCode(init.stdout, 'a known join code exists to test secrecy against');

  const status = await runCli(['status', '--config', file], { cwd: dir });
  const doctor = await runCli(['doctor', '--config', file], { cwd: dir });
  const listMasked = await runCli(['invite', 'list', '--config', file], { cwd: dir });

  for (const [label, result] of [['status', status], ['doctor', doctor], ['invite list', listMasked]]) {
    ok(!result.stdout.includes(printedCode) && !result.stderr.includes(printedCode),
      `${label} never prints the full join code`);
  }

  const listRevealed = await runCli(['invite', 'list', '--reveal', '--config', file], { cwd: dir });
  ok(listRevealed.stdout.includes(printedCode), 'invite list --reveal does print it in full');

  /*
   * The masked column is a mask, not a shortened code: at six characters there
   * is no prefix small enough to be safe, so nothing of the code may survive
   * into the masked listing. Asserted character by character rather than
   * against a literal, because the mask's spelling belongs to config.js.
   */
  const masked = listMasked.stdout.split('\n').find((line) => line.startsWith('primary'));
  ok(!!masked, 'the primary credential has a row in the masked listing');
  // Columns are joined by two spaces and the mask carries none, so the last
  // cell is the CODE column. Checked as a cell rather than as a substring of
  // the whole row, where a two-character prefix could collide with a date.
  const codeCell = masked.trimEnd().split(/\s{2,}/).pop();
  ok(!/[0-9A-Za-z]/.test(codeCell),
    `the masked CODE column carries no part of the code at all (saw "${codeCell}")`);
  ok(codeCell.includes('*'), 'and is visibly masked rather than blank');
  const revealedRow = listRevealed.stdout.split('\n').find((line) => line.startsWith('primary'));
  ok(revealedRow.trimEnd().split(/\s{2,}/).pop() === printedCode,
    'while --reveal puts the whole code in that same column');

  // The one place a code appears whole is still --reveal, and it is still
  // announced: a host who reveals should know the terminal now holds it.
  ok(/--reveal/.test(listMasked.stdout), 'the masked listing says how to see them in full');
  ok(/records this terminal/i.test(listRevealed.stdout),
    'and the revealed listing says what revealing them costs');
}

// =====================================================================
// invite
// =====================================================================

async function inviteScenario() {
  const dir = scratchDir('invite');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  const badExpiry = await runCli(['invite', '--expires', 'soon', '--config', file], { cwd: dir });
  ok(badExpiry.code === cli.USAGE, 'an unrecognised --expires duration is a usage error');
  ok(/30m/.test(badExpiry.stderr) && /24h/.test(badExpiry.stderr) && /7d/.test(badExpiry.stderr),
    'the accepted forms (30m/24h/7d) are named in the refusal');

  const good = await runCli(
    ['invite', '--expires', '24h', '--uses', '3', '--label', 'Friend', '--config', file], { cwd: dir });
  ok(good.code === cli.OK, 'a well-formed invite succeeds');
  const idMatch = /\(id ([0-9a-f]+),/.exec(good.stdout);
  ok(!!idMatch, 'the new credential id is printed');
  const id = idMatch[1];

  const list = await runCli(['invite', 'list', '--reveal', '--config', file], { cwd: dir });
  ok(list.code === cli.OK, 'invite list succeeds');
  ok(list.stdout.includes(id), 'the new credential appears in invite list');

  const stored = readConfigFile(file).auth.credentials.find((c) => c.id === id);
  ok(!!stored, 'the credential is on disk');
  ok(stored.maxUses === 3, '--uses is stored');
  ok(!!stored.expiresAt, '--expires is stored');
}

// =====================================================================
// invite --admin -- the credential that marks a connection
// =====================================================================

async function inviteAdminScenario() {
  const dir = scratchDir('invite-admin');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });
  const before = readConfigFile(file).auth.credentials.length;

  // --- a plain invite mints a credential that carries no admin flag at all
  const plain = await runCli(['invite', '--label', 'Friend', '--config', file], { cwd: dir });
  ok(plain.code === cli.OK, 'a plain invite succeeds');
  const plainId = /\(id ([0-9a-f]+),/.exec(plain.stdout)[1];
  const plainCredential = readConfigFile(file).auth.credentials.find((c) => c.id === plainId);
  ok(plainCredential.admin !== true, 'a plain invite does not carry admin: true');

  // --- --admin mints one that does, says so in the banner, and the printed
  //     block explains the mark it leaves on the connection rather than any
  //     web surface
  const admin = await runCli(['invite', '--admin', '--label', 'Op', '--config', file], { cwd: dir });
  ok(admin.code === cli.OK, 'invite --admin succeeds');
  ok(/New admin join code/.test(admin.stdout), 'the banner names it an admin code');
  ok(/mark on the connection/i.test(admin.stdout),
    'and the printed block describes the mark it leaves on the connection');
  ok(/\bADMIN\b/.test(admin.stdout) && /KIND column/i.test(admin.stdout),
    'naming the ADMIN mark and the KIND column of `invite list` where it shows');
  const adminId = /\(id ([0-9a-f]+),/.exec(admin.stdout)[1];
  const adminCredential = readConfigFile(file).auth.credentials.find((c) => c.id === adminId);
  ok(adminCredential.admin === true, 'and the credential really carries admin: true on disk');
  ok(adminId !== plainId, 'sanity: the two invites minted distinct credentials');

  const afterBoth = readConfigFile(file).auth.credentials.length;
  ok(afterBoth === before + 2, 'both invites really landed on disk');

  // --- --admin=garbage: neither a recognised yes nor a recognised no, so it
  //     is refused rather than guessed at, and nothing is minted
  const garbage = await runCli(['invite', '--admin=garbage', '--config', file], { cwd: dir });
  ok(garbage.code === cli.USAGE, '--admin=garbage is a usage error (exit 2)');
  ok(/--admin takes no value/.test(garbage.stderr), 'and says why');
  ok(readConfigFile(file).auth.credentials.length === afterBoth,
    'and nothing was minted by the refused attempt');
}

// =====================================================================
// invite list -- the KIND column
// =====================================================================

async function inviteListKindScenario() {
  const dir = scratchDir('invite-list-kind');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });
  await runCli(['invite', '--admin', '--label', 'Op', '--config', file], { cwd: dir });
  await runCli(['invite', '--label', 'Friend', '--config', file], { cwd: dir });

  // --- the column is there, and marks each row correctly, with and without
  //     --reveal -- what a code unlocks is not something --reveal gates
  for (const args of [['invite', 'list'], ['invite', 'list', '--reveal']]) {
    const result = await runCli([...args, '--config', file], { cwd: dir });
    ok(result.code === cli.OK, `${args.join(' ')} succeeds`);
    ok(/\bKIND\b/.test(result.stdout), `${args.join(' ')} prints a KIND column header`);
    ok(/\bADMIN\b/.test(result.stdout), `${args.join(' ')} marks the admin row ADMIN`);
    ok(/\bplayer\b/.test(result.stdout), `${args.join(' ')} marks a non-admin row player`);
    ok(/KIND ADMIN: joins the game like any code/.test(result.stdout),
      `${args.join(' ')} prints the footer note about the mark an admin code leaves`);
    ok(/`admin` flag on the connection/.test(result.stdout),
      `${args.join(' ')}: and the footer is precise about the rosters carrying a flag, not the word`);

    const rows = result.stdout.split('\n').filter((line) => /\b(ADMIN|player)\b/.test(line));
    ok(rows.some((line) => /\bOp\b/.test(line) && /\bADMIN\b/.test(line)),
      `${args.join(' ')}: the Op credential's own row is the one marked ADMIN`);
    ok(rows.some((line) => /\bFriend\b/.test(line) && /\bplayer\b/.test(line)),
      `${args.join(' ')}: and the Friend credential's row is marked player, not ADMIN`);
  }

  // --- the other footer note, when there is no admin credential to mark
  const otherDir = scratchDir('invite-list-kind-none');
  const otherFile = path.join(otherDir, 'config.json');
  await runCli(['init', '--yes', '--config', otherFile], { cwd: otherDir });
  const noAdmin = await runCli(['invite', 'list', '--config', otherFile], { cwd: otherDir });
  ok(noAdmin.code === cli.OK, 'invite list succeeds with no admin credential at all');
  ok(/none of these is an admin code/.test(noAdmin.stdout),
    'and prints the other footer note when there is nothing to mark ADMIN');
}

// =====================================================================
// revoke
// =====================================================================

async function revokeScenario() {
  const dir = scratchDir('revoke');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });
  const primaryId = readConfigFile(file).auth.credentials[0].id;

  const badId = await runCli(['revoke', 'this-id-does-not-exist', '--config', file], { cwd: dir });
  ok(badId.code === cli.ERROR, 'revoking an unknown id is an error');
  ok(/No join code/.test(badId.stderr), 'and says so');

  const revoke = await runCli(['revoke', primaryId, '--config', file], { cwd: dir });
  ok(revoke.code === cli.OK, 'revoking the last active credential still succeeds');
  ok(/last usable join code/.test(revoke.stderr), 'but warns that nobody can join now');
  ok(readConfigFile(file).auth.credentials[0].revoked === true,
    'the credential is marked revoked on disk');
}

// --- an admin code is revoked exactly like any other -- `revoke` has no
//     separate verb for it, per plan §8.3

async function revokeAdminScenario() {
  const dir = scratchDir('revoke-admin');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  const minted = await runCli(['invite', '--admin', '--label', 'Op', '--config', file], { cwd: dir });
  ok(minted.code === cli.OK, 'invite --admin succeeds, to have one to revoke');
  const adminId = /\(id ([0-9a-f]+),/.exec(minted.stdout)[1];

  const revoke = await runCli(['revoke', adminId, '--config', file], { cwd: dir });
  ok(revoke.code === cli.OK, 'revoking an admin code succeeds, the same as any other');

  const onDisk = readConfigFile(file).auth.credentials.find((c) => c.id === adminId);
  ok(!!onDisk, 'the credential is still on disk, revoked rather than removed');
  ok(onDisk.revoked === true, 'and its revoked flag is set');
  ok(onDisk.admin === true,
    'and it is still recognisable as the admin credential it was -- revoking does not strip the flag');
}

// =====================================================================
// ban / unban / allow
// =====================================================================

async function banAllowScenario() {
  const dir = scratchDir('ban-allow');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  const dualStack = '::ffff:203.0.113.7';
  const plain = limits.normalizeIp(dualStack);

  const ban = await runCli(['ban', dualStack, '--config', file], { cwd: dir });
  ok(ban.code === cli.OK, 'ban succeeds');
  let onDisk = readConfigFile(file);
  ok(onDisk.bans.includes(plain), `the address lands normalised on disk (${plain})`);
  ok(!onDisk.bans.includes(dualStack), 'not in its raw dual-stack spelling');

  const unban = await runCli(['unban', plain, '--config', file], { cwd: dir });
  ok(unban.code === cli.OK, 'unban succeeds');
  onDisk = readConfigFile(file);
  ok(!onDisk.bans.includes(plain), 'the address is gone from the file');

  const allow1 = await runCli(['allow', '203.0.113.9', '--config', file], { cwd: dir });
  ok(allow1.code === cli.OK, 'the first allow succeeds');
  ok(/ONLY the addresses below may connect/.test(allow1.stdout),
    'adding the first allowlist entry warns that it locks out everyone else');
  onDisk = readConfigFile(file);
  ok(onDisk.allowlist.length === 1, 'and the entry actually lands');

  const allowClear = await runCli(['allow', '--clear', '--config', file], { cwd: dir });
  ok(allowClear.code === cli.OK, 'allow --clear succeeds');
  ok(readConfigFile(file).allowlist.length === 0, 'the allowlist is empty again');
}

// =====================================================================
// start: it refuses an exposed config file, and it hands the UPnP unmap
// to server.js's shutdown hook rather than racing a signal handler
// =====================================================================

async function startRefusesExposedConfigScenario() {
  if (process.platform === 'win32') {
    console.log('  (skipped: file modes, and so this refusal, are a no-op on win32)');
    return;
  }

  const dir = scratchDir('start-permissions');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  // A stub hub, so "did it start" is answerable without binding anything.
  const starts = [];
  const restoreServer = stubServer({
    async start(options) {
      starts.push(options);
      return { closed: Promise.resolve() };
    },
  });

  try {
    // --- 0600: the refusal must not become a false positive that stops every
    //     host from ever starting a hub
    ok(fileMode(file) === 0o600, 'a freshly initialised config is 0600');
    const healthy = await runCli(['start', '--config', file], { cwd: dir });
    ok(healthy.code === cli.OK, 'start on a 0600 config runs the hub');
    ok(starts.length === 1, 'and really reached server.start()');
    ok(!/Refusing to start/.test(healthy.stderr), 'with no refusal in sight');

    // --- 0644: refuses, and the message is actionable on its own
    fs.chmodSync(file, 0o644);
    const refused = await runCli(['start', '--config', file], { cwd: dir });
    ok(refused.code === cli.ERROR,
      'start on a group/world-readable config exits with the runtime error code');
    ok(starts.length === 1, 'and never reaches server.start() -- it refuses, it does not warn');
    ok(/Refusing to start/.test(refused.stderr), 'the refusal says so in as many words');
    ok(refused.stderr.includes(file), 'the message names the config file');
    ok(/\b644\b/.test(refused.stderr), 'and the mode it actually found');
    ok(refused.stderr.includes(`chmod 600 ${file}`),
      'and gives the exact command that fixes it');
    ok(/--insecure-config/.test(refused.stderr), 'and names the escape hatch');

    // --- the escape hatch: starts anyway, having said what is being accepted
    const forced = await runCli(['start', '--config', file, '--insecure-config'], { cwd: dir });
    ok(forced.code === cli.OK, '--insecure-config starts anyway');
    ok(starts.length === 2, 'and really does reach server.start() that time');
    ok(/--insecure-config/.test(forced.stderr), 'the run says which flag it is honouring');
    ok(/accepting/i.test(forced.stderr) && /readable by/i.test(forced.stderr),
      'and spells out what the host is accepting: other users can read the file');
    ok(/join code/i.test(forced.stderr),
      'naming the thing actually at risk -- the join codes in it');

    fs.chmodSync(file, 0o600);
  } finally {
    restoreServer();
  }
}

async function startUnmapsThroughOnShutdownScenario() {
  const dir = scratchDir('start-upnp');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });
  // Written straight into the config, not through `upnp enable` -- enabling it
  // for real would send SSDP to whatever is on this network.
  const enabled = await runCli(
    ['config', 'set', 'network.upnp.enabled', 'true', '--config', file], { cwd: dir });
  ok(enabled.code === cli.OK, 'UPnP can be turned on in the config without touching a router');

  const MAPPED_PORT = readConfigFile(file).listen.port;
  const DEVICE = { router: 'http://192.0.2.1:5000/', stub: true };

  let removeCalls = 0;
  let removeArgs = null;
  let releaseRemove;
  const routerAnswered = new Promise((resolve) => { releaseRemove = resolve; });

  const restoreUpnp = stubUpnp({
    async addMapping({ port }) {
      return {
        ok: true,
        port,
        internalAddress: '192.0.2.55',
        leaseSeconds: 3600,
        permanent: false,
        device: DEVICE,
      };
    },
    async removeMapping(args) {
      removeCalls += 1;
      removeArgs = args;
      await routerAnswered; // the SOAP round trip, held open on purpose
      return { ok: true, port: args.port, alreadyGone: false, device: DEVICE };
    },
  });

  let started = null;
  let resolveClosed;
  const closed = new Promise((resolve) => { resolveClosed = resolve; });
  const restoreServer = stubServer({
    async start(options) {
      started = options;
      return { closed };
    },
  });

  try {
    const running = runCli(['start', '--config', file], { cwd: dir });
    await waitFor(() => started, 'the CLI to call server.start()');

    ok(typeof started.onShutdown === 'function',
      'the UPnP unmap is handed to server.start() as onShutdown, not hung off a signal');
    ok(started.configPath === file, 'and the rest of the start options still go through');

    // Drive the hook the way close() will, and prove it is awaitable: the
    // whole point of the fix is that shutdown does not run ahead of the SOAP
    // call the way a fire-and-forget signal handler did.
    let hookSettled = false;
    const hook = Promise.resolve(started.onShutdown()).then(() => { hookSettled = true; });

    await tick();
    ok(removeCalls === 1, 'calling the hook removes the mapping');
    ok(removeArgs && removeArgs.port === MAPPED_PORT,
      'for the port the hub actually forwarded');
    ok(removeArgs && removeArgs.device === DEVICE,
      'against the device discovered at start, so it is not rediscovered from scratch');

    await tick();
    await tick();
    ok(hookSettled === false,
      'and the hook is still pending while the router has not answered -- close() has ' +
      'something real to await');

    releaseRemove();
    await withTimeout(hook, 5000, 'the onShutdown hook to settle');
    ok(hookSettled === true, 'it resolves once the router has answered');

    resolveClosed();
    const result = await withTimeout(running, 5000, 'start to return after the hub closed');
    ok(result.code === cli.OK, 'and the run finishes cleanly');
    ok(removeCalls === 1,
      'the mapping is removed exactly once, even though the run also drops it on the way out');
    ok(/Removing the UPnP mapping/.test(result.stdout), 'the removal is reported to the host');
  } finally {
    restoreServer();
    restoreUpnp();
    releaseRemove();
  }
}

async function startSurvivesAnUnreachableRouterScenario() {
  const dir = scratchDir('start-upnp-dead-router');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });
  await runCli(['config', 'set', 'network.upnp.enabled', 'true', '--config', file], { cwd: dir });

  const restoreUpnp = stubUpnp({
    async addMapping({ port }) {
      return { ok: true, port, internalAddress: '192.0.2.55', leaseSeconds: 3600, device: {} };
    },
    async removeMapping() {
      return { ok: false, error: 'no router answered' };
    },
  });

  let started = null;
  const restoreServer = stubServer({
    async start(options) {
      started = options;
      return { closed: Promise.resolve() };
    },
  });

  try {
    const result = await withTimeout(
      runCli(['start', '--config', file], { cwd: dir }), 5000, 'start with a dead router');
    ok(result.code === cli.OK, 'a router that refuses the removal does not fail the shutdown');
    ok(!!started && typeof started.onShutdown === 'function',
      'the hook is wired even when the router is unreachable');
    ok(/could not remove it/.test(result.stderr), 'and the host is told the mapping is still up');
  } finally {
    restoreServer();
    restoreUpnp();
  }
}

// =====================================================================
// start refuses a hub anybody could join, before it binds anything
// =====================================================================

async function startRefusesALooseConfigScenario() {
  const dir = scratchDir('start-auth');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  const starts = [];
  const restoreServer = stubServer({
    async start(options) {
      starts.push(options);
      return { closed: Promise.resolve() };
    },
  });

  try {
    // --- the baseline: a hub with a passcode starts, so the refusals below
    //     are about the configuration and not about `start` being broken
    const healthy = await runCli(['start', '--config', file], { cwd: dir });
    ok(healthy.code === cli.OK, 'start runs a hub that requires a passcode and has one');
    ok(starts.length === 1, 'and reaches server.start()');

    // --- auth.required false: refused here, with the fix, rather than left to
    //     server.js to refuse further down where a host is not reading
    const off = await runCli(
      ['config', 'set', 'auth.required', 'false', '--config', file], { cwd: dir });
    ok(off.code === cli.OK, 'auth.required is still settable -- the tool does not fight a script');
    ok(/refuses/i.test(off.stderr), 'but says on the spot that the hub will not run like that');

    const openHub = await runCli(['start', '--config', file], { cwd: dir });
    ok(openHub.code === cli.ERROR, 'start on auth.required=false exits with the runtime error code');
    ok(starts.length === 1, 'and never reaches server.start() -- it refuses, it does not warn');
    ok(/Refusing to start/.test(openHub.stderr), 'the refusal says so in as many words');
    ok(/passcode is required/i.test(openHub.stderr), 'and why');
    ok(openHub.stderr.includes('rby-mmo-hub config set auth.required true'),
      'and gives the exact command that fixes it');
    ok(openHub.stderr.includes('rby-mmo-hub invite'),
      'and names `rby-mmo-hub invite`, which is the other half of the fix');

    // --- auth on, but nothing usable to authenticate with: the other way to
    //     end up with a hub nobody can use
    await runCli(['config', 'set', 'auth.required', 'true', '--config', file], { cwd: dir });
    const revoked = await runCli(['revoke', 'primary', '--config', file], { cwd: dir });
    ok(revoked.code === cli.OK, 'the only passcode can still be revoked');

    const noCode = await runCli(['start', '--config', file], { cwd: dir });
    ok(noCode.code === cli.ERROR, 'start with no usable passcode is a runtime error');
    ok(starts.length === 1, 'and still never reaches server.start()');
    ok(/Refusing to start/.test(noCode.stderr), 'refusing, in the same words');
    ok(noCode.stderr.includes('rby-mmo-hub invite'), 'and naming `rby-mmo-hub invite` as the fix');
    ok(/revoked/i.test(noCode.stderr),
      'and saying why the codes it has do not count, so the host is not left guessing');

    // --- and one `invite` really is enough to make it start again
    const minted = await runCli(['invite', '--config', file], { cwd: dir });
    ok(minted.code === cli.OK, 'invite mints a replacement');
    const recovered = await runCli(['start', '--config', file], { cwd: dir });
    ok(recovered.code === cli.OK, 'after which start runs again');
    ok(starts.length === 2, 'reaching server.start() a second time');
  } finally {
    restoreServer();
  }
}

// =====================================================================
// the wrong-passcode throttle is visible to a host
// =====================================================================

async function throttleVisibilityScenario() {
  const dir = scratchDir('throttle');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  const status = await runCli(['status', '--config', file], { cwd: dir });
  ok(status.code === cli.OK, 'status succeeds');
  ok(/throttle/i.test(status.stdout), 'status reports the wrong-passcode throttle');
  ok(/per address/.test(status.stdout) && /hub-wide/.test(status.stdout),
    'in both of its halves: the per-address backoff and the hub-wide ceiling');
  ok(new RegExp(String(config.DEFAULTS.limits.authGlobalFailures)).test(status.stdout),
    'with the numbers actually configured');
  ok(/running hub/i.test(status.stdout),
    'and is honest that the live counts belong to the running hub, not to this command');

  const doctor = await runCli(['doctor', '--config', file], { cwd: dir });
  ok(doctor.code === cli.OK, 'doctor is happy with the shipped throttle defaults');
  ok(/wrong passcodes are throttled/.test(doctor.stdout), 'and reports the throttle');
  ok(/only to the hub while it runs/.test(doctor.stdout),
    'saying plainly that it cannot see how many attempts have actually arrived');

  // --- a setting that would lock the host's own friends out is called out.
  //     maxPlayers defaults to 4, so a ceiling of 4 trips on four typos.
  const tightened = await runCli(
    ['config', 'set', 'limits.authGlobalFailures', '4', '--config', file], { cwd: dir });
  ok(tightened.code === cli.OK, 'the hub-wide ceiling can be set very low');
  const tight = await runCli(['doctor', '--config', file], { cwd: dir });
  ok(/\[warn\].*authGlobalFailures/.test(tight.stdout),
    'and doctor warns that a full house mistyping once would trip it');
  ok(tight.code === cli.OK, 'without failing -- it is a choice, not a broken config');

  // --- and the seven knobs are readable through the ordinary listing, so a
  //     host does not have to know they exist to find them
  const listed = await runCli(['config', 'list', '--config', file], { cwd: dir });
  for (const dotted of AUTH_LIMIT_PATHS) {
    ok(listed.stdout.includes(dotted), `config list shows ${dotted}`);
  }
}

// =====================================================================
// doctor
// =====================================================================

async function doctorScenario() {
  const dir = scratchDir('doctor');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  const healthy = await runCli(['doctor', '--config', file], { cwd: dir });
  ok(healthy.code === cli.OK, 'doctor exits zero on a healthy, freshly-initialised config');

  fs.chmodSync(file, 0o644);
  const broken = await runCli(['doctor', '--config', file], { cwd: dir });
  ok(broken.code === cli.ERROR, 'doctor exits non-zero when the config file is world-readable');
  ok(/\[fail\]/.test(broken.stdout), 'and marks it a failure rather than a warning');
  fs.chmodSync(file, 0o600);
}

// =====================================================================
// exit codes, unknown verb, bare invocation, --version
// =====================================================================

async function exitCodesScenario() {
  const dir = scratchDir('exit-codes');

  const bare = await runCli([], { cwd: dir });
  ok(bare.code === cli.OK, 'a bare invocation is not an error (exit 0)');
  ok(/Usage:/.test(bare.stdout), 'and it prints help');

  const unknown = await runCli(['bogus-verb'], { cwd: dir });
  ok(unknown.code === cli.USAGE, 'an unknown command is a usage error (exit 2)');

  const usageErr = await runCli(['config', 'set'], { cwd: dir });
  ok(usageErr.code === cli.USAGE, 'config set with no arguments is a usage error (exit 2)');

  const missingConfig = path.join(dir, 'no-such-config.json');
  const runtimeErr = await runCli(['revoke', 'anything', '--config', missingConfig], { cwd: dir });
  ok(runtimeErr.code === cli.ERROR, 'acting against a config that does not exist is a runtime error (exit 1)');

  const version = await runCli(['--version'], { cwd: dir });
  ok(version.code === cli.OK, '--version succeeds (exit 0)');
  const pkgVersion = JSON.parse(fs.readFileSync(path.join(__dirname, 'package.json'), 'utf8')).version;
  ok(version.stdout.trim() === `rby-mmo-hub ${pkgVersion}`,
    '--version prints the version from package.json');
}

// =====================================================================
// the shim: proving the real process exit status matches run()'s code
// =====================================================================

async function spawnExitCodeScenario() {
  const okCode = await spawnCli(['--version']);
  ok(okCode === 0, 'the spawned process exits 0 when run() resolves OK');

  const usageCode = await spawnCli(['bogus-verb']);
  ok(usageCode === 2, 'the spawned process exits 2 when run() resolves USAGE -- the shim maps it through');
}

// ------------------------------------------------------------------- runner

async function main() {
  try {
    await initScenarios();
    await authIsMandatoryScenario();
    await suppliedPasscodeScenario();
    await configLeafPathScenario();
    await clampReportScenario();
    await configSetMotdReloadRecipeScenario();
    await statusPrecedenceScenario();
    await playersLiveScenario();
    await playersEmptyScenario();
    await playersStoppedScenario();
    await playersStaleScenario();
    await playersStaleRespectsNonstandardHeartbeatScenario();
    await playersMissingScenario();
    await playersCorruptJsonScenario();
    await playersUndatedEmptyScenario();
    await playersJsonScenario();
    await playersHonoursConfigScenario();
    await watchOnceMatchesPlayersScenario();
    await watchOnceJsonScenario();
    await watchBadIntervalScenario();
    await rankingTopTenScenario();
    await rankingJsonScenario();
    await rankingEmptyScenario();
    await rankingMissingScenario();
    await rankingHonoursConfigScenario();
    await rankingWinLossScenario();
    await historyBothGenerationsScenario();
    await historyCountAndBadCountScenario();
    await historyJsonScenario();
    await historyRotatedOnlyScenario();
    await historyMissingScenario();
    await kickHappyScenario();
    await kickReasonScenario();
    await kickNobodyScenario();
    await broadcastHappyScenario();
    await statsScenario();
    await statsLockdownScenario();
    await statsJsonScenario();
    await statsRefusalScenario();
    await adminRefusalScenario();
    await adminNoSocketScenario();
    await adminStaleSocketScenario();
    await adminTimeoutScenario();
    await secretsDisciplineScenario();
    await inviteScenario();
    await inviteAdminScenario();
    await inviteListKindScenario();
    await revokeScenario();
    await revokeAdminScenario();
    await banAllowScenario();
    await startRefusesExposedConfigScenario();
    await startRefusesALooseConfigScenario();
    await startUnmapsThroughOnShutdownScenario();
    await startSurvivesAnUnreachableRouterScenario();
    await throttleVisibilityScenario();
    await doctorScenario();
    await missingConfigAdviceScenario();
    await exitCodesScenario();
    await spawnExitCodeScenario();
  } finally {
    fs.rmSync(ROOT, { recursive: true, force: true });
    cleanupAdminScratchDirs();
  }
  console.log(`\n  ${passed}/${passed} checks passed  (cli)\n`);
}

main().catch((err) => {
  console.error('\n  ' + err.message + '\n');
  process.exit(1);
});
