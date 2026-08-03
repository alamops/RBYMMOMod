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
    await statusPrecedenceScenario();
    await secretsDisciplineScenario();
    await inviteScenario();
    await revokeScenario();
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
  }
  console.log(`\n  ${passed}/${passed} checks passed  (cli)\n`);
}

main().catch((err) => {
  console.error('\n  ' + err.message + '\n');
  process.exit(1);
});
