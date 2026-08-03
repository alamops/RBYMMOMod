#!/usr/bin/env node
'use strict';

/*
 * Pin the configuration store in server/lib/config.js.
 *
 * Covers the precedence chain (flag > env > file > default), the legacy
 * RBY_MMO_* env vars hub.js has always read, clamping driven mechanically
 * from BOUNDS, the nesting of config.js's BOUNDS inside limits.js's BOUNDS,
 * the reachability of the authentication-failure throttle through env vars,
 * flags and LEAF_PATHS, the load()-never-throws contract, atomic/mode-0600 save() and its refusal
 * to write through anything planted at its temporary path, permission
 * checking, redaction that keeps no part of a join code, migration and the
 * manifest/package version-parity guard.
 *
 * Same bespoke idiom as server/hub.test.js and server/auth.test.js: a
 * throwing ok(cond, label) helper, plain scenario functions, a final
 * console.log of the pass count. No test framework, no dependencies beyond
 * node core. Everything that touches the filesystem writes to a scratch
 * directory under os.tmpdir(), cleaned up in a finally.
 *
 * Run: node server/config.test.js
 * Also runs under `npm test` (node --test) the same way hub.test.js and
 * auth.test.js do: no node:test imports, so the whole script is one
 * implicit test that passes as long as it exits 0.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('node:crypto');
const config = require('./lib/config.js');
const limits = require('./lib/limits.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

// ------------------------------------------------------------------ helpers

function writeConfig(file, object, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(object), { mode: mode || 0o600 });
}

function cloneDefaults() {
  return JSON.parse(JSON.stringify(config.DEFAULTS));
}

// A validated config carrying one known join code, so a scenario can go
// looking for that exact string on disk afterwards.
const SECRET = 'TVWX-2345-6789-JKMN';

function configWithSecret() {
  const validated = config.validate(config.DEFAULTS).config;
  validated.auth.credentials = [{
    id: 'known', label: 'Known', secret: SECRET, createdAt: null,
    expiresAt: null, maxUses: null, uses: 0, revoked: false,
  }];
  return validated;
}

/*
 * save()'s temp path carries six random bytes, which is exactly what makes it
 * unguessable -- and unpredictable for a test. Pinning crypto.randomBytes for
 * the duration of one scenario is the only way to plant something at the path
 * save() is about to try, which is the attack under test. config.js holds a
 * reference to the module object, not to the function, so replacing the
 * property is enough; it is restored in a finally.
 */
function withPinnedTempSuffix(fn) {
  const real = crypto.randomBytes;
  crypto.randomBytes = (size) => Buffer.alloc(size, 0);
  const suffix = `.${process.pid}.${Buffer.alloc(6, 0).toString('hex')}.tmp`;
  try {
    return fn(suffix);
  } finally {
    crypto.randomBytes = real;
  }
}

/** Every file directly inside `dir`, read as text. */
function contentsOf(dir) {
  return fs.readdirSync(dir).map((name) => {
    const full = path.join(dir, name);
    if (!fs.lstatSync(full).isFile()) return '';
    try {
      return fs.readFileSync(full, 'utf8');
    } catch (err) {
      return '';
    }
  });
}

// --------------------------------------------------------------- precedence

function testPrecedence(tmp) {
  const file = path.join(tmp, 'precedence.json');
  writeConfig(file, { version: 1, listen: { port: 1111 } });

  // All four sources supply the same key; the flag must win.
  const all = config.load({ path: file, env: { RBY_MMO_PORT: '2222' }, flags: { port: 3333 } });
  ok(all.config.listen.port === 3333, 'a flag beats env, file and default for the same key');
  ok(all.sources['listen.port'] === 'flag', 'sources reports "flag" for a flag-supplied leaf');

  const envOverFile = config.load({ path: file, env: { RBY_MMO_PORT: '2222' }, flags: {} });
  ok(envOverFile.config.listen.port === 2222, 'env beats file when no flag is given');
  ok(envOverFile.sources['listen.port'] === 'env', 'sources reports "env"');

  const fileOverDefault = config.load({ path: file, env: {}, flags: {} });
  ok(fileOverDefault.config.listen.port === 1111, 'the file beats the built-in default');
  ok(fileOverDefault.sources['listen.port'] === 'file', 'sources reports "file"');

  const missing = path.join(tmp, 'does-not-exist.json');
  const defaults = config.load({ path: missing, env: {}, flags: {} });
  ok(defaults.config.listen.port === config.DEFAULTS.listen.port,
    'the built-in default applies when nothing else supplies the key');
  ok(defaults.sources['listen.port'] === 'default', 'sources reports "default"');
}

// -------------------------------------------------------------- legacy envs

function testLegacyEnvVars(tmp) {
  const missing = path.join(tmp, 'legacy-does-not-exist.json');
  const result = config.load({
    path: missing,
    env: { RBY_MMO_PORT: '9001', RBY_MMO_HOST: '10.0.0.5', RBY_MMO_MAX: '12' },
    flags: {},
  });
  ok(result.config.listen.port === 9001, 'RBY_MMO_PORT still sets listen.port');
  ok(result.config.listen.host === '10.0.0.5', 'RBY_MMO_HOST still sets listen.host');
  ok(result.config.maxPlayers === 12, 'RBY_MMO_MAX still sets maxPlayers');
}

// ------------------------------------------------------------------ clamping

function testClamping() {
  for (const dotted of Object.keys(config.BOUNDS)) {
    const [min, max] = config.BOUNDS[dotted];

    const belowDefaults = cloneDefaults();
    config.setPath(belowDefaults, dotted, min - 1);
    const below = config.validate(belowDefaults);
    ok(config.getPath(below.config, dotted) === min,
      `${dotted}: a value below the minimum (${min - 1}) is raised to ${min}`);
    ok(below.warnings.some((w) => w.startsWith(dotted + ':')),
      `${dotted}: clamping down produces a warning naming the setting`);

    const aboveDefaults = cloneDefaults();
    config.setPath(aboveDefaults, dotted, max + 1);
    const above = config.validate(aboveDefaults);
    ok(config.getPath(above.config, dotted) === max,
      `${dotted}: a value above the maximum (${max + 1}) is lowered to ${max}`);
    ok(above.warnings.some((w) => w.startsWith(dotted + ':')),
      `${dotted}: clamping up produces a warning naming the setting`);
  }

  // This is the exact behaviour server/hub.test.js's clampTest scenario
  // depends on: a sub-floor RBY_MMO_MAX is raised to 2, not obeyed.
  const [maxPlayersMin, maxPlayersMax] = config.BOUNDS.maxPlayers;
  ok(maxPlayersMin === 2 && maxPlayersMax === 64, 'maxPlayers keeps its 2..64 bounds');
}

// ------------------------------------------------------------- bounds nesting

function testBoundsNesting() {
  // Driven from limits.js's BOUNDS, not config.js's: config.js's "limits."
  // namespace also carries chatIntervalMs, which is a flood-gate setting
  // consumed directly by lib/relay.js and never passed through the Limits
  // class (see lib/server.js:179, lib/relay.js:288-289) -- it has no
  // counterpart to nest inside and is correctly absent from limits.BOUNDS.
  // Every knob limits.js *does* bound must both exist in config.BOUNDS and
  // nest inside it, which is the actual "never silently re-clamped
  // downstream" guarantee this test exists to pin.
  let checked = 0;
  for (const bareKey of Object.keys(limits.BOUNDS)) {
    const dotted = 'limits.' + bareKey;
    const configRange = config.BOUNDS[dotted];
    ok(Array.isArray(configRange), `config.BOUNDS has a matching entry for ${dotted}`);
    const [cMin, cMax] = configRange;
    const [lMin, lMax] = limits.BOUNDS[bareKey];
    ok(cMin >= lMin && cMax <= lMax,
      `${dotted}: config's [${cMin}, ${cMax}] is a subset of limits.js's [${lMin}, ${lMax}]`);
    checked += 1;
  }
  ok(checked === Object.keys(limits.BOUNDS).length,
    'every knob limits.js bounds was checked for nesting inside config.js');
}

// ------------------------------------------------- the auth-throttle knobs
//
// The seven authentication-failure knobs are the newest arrivals in
// `limits.`, and most of what matters about them is already pinned by the
// two table-driven scenarios above: `testClamping` walks config.BOUNDS, so
// each one's clamp and its warning are covered the moment the entry exists,
// and `testBoundsNesting` walks limits.BOUNDS, so the entry existing at all
// is covered too. What neither can see is the rest of the reachability
// chain, which is what this pins:
//
//   * the default and the range are limits.js's *verbatim*, not merely
//     nested inside it. Nesting would still pass if config.js invented a
//     tighter range or a different default, and then a host reading the two
//     files would find two answers to the same question.
//   * the default is itself inside the range -- a default that needs
//     clamping is a default nobody ever runs.
//   * the key reached LEAF_PATHS, which is derived by walking DEFAULTS. That
//     is what `config set` enumerates (server/cli.test.js drives every leaf),
//     so a knob missing from it is a knob with no CLI and no test coverage,
//     silently.
//   * an env var and a short flag both actually land on the value, which is
//     the project's standing rule that every setting is reachable through the
//     software rather than only through a hand-edited file.
const AUTH_KNOBS = [
  ['authFailureGrace', 'RBY_MMO_AUTH_FAILURE_GRACE', 'authFailureGrace'],
  ['authFailureWindowMs', 'RBY_MMO_AUTH_FAILURE_WINDOW_MS', 'authFailureWindow'],
  ['authBackoffBaseMs', 'RBY_MMO_AUTH_BACKOFF_BASE_MS', 'authBackoffBase'],
  ['authBackoffMaxMs', 'RBY_MMO_AUTH_BACKOFF_MAX_MS', 'authBackoffMax'],
  ['authGlobalFailures', 'RBY_MMO_AUTH_GLOBAL_FAILURES', 'authGlobalFailures'],
  ['authGlobalWindowMs', 'RBY_MMO_AUTH_GLOBAL_WINDOW_MS', 'authGlobalWindow'],
  ['authLockoutMs', 'RBY_MMO_AUTH_LOCKOUT_MS', 'authLockout'],
];

function testAuthThrottleKeys(tmp) {
  const missing = path.join(tmp, 'auth-throttle-does-not-exist.json');

  for (const [bare, envName, flagName] of AUTH_KNOBS) {
    const dotted = 'limits.' + bare;

    ok(config.DEFAULTS.limits[bare] === limits.DEFAULTS[bare],
      `${dotted}: the default (${config.DEFAULTS.limits[bare]}) is limits.js's own, verbatim`);
    ok(JSON.stringify(config.BOUNDS[dotted]) === JSON.stringify(limits.BOUNDS[bare]),
      `${dotted}: the range ${JSON.stringify(config.BOUNDS[dotted])} is limits.js's own, verbatim`);

    const [min, max] = config.BOUNDS[dotted];
    const fallback = config.DEFAULTS.limits[bare];
    ok(fallback >= min && fallback <= max,
      `${dotted}: the built-in default sits inside its own range`);

    ok(config.LEAF_PATHS.includes(dotted),
      `${dotted}: LEAF_PATHS picked it up, so \`config set\` reaches it`);

    ok(config.ENV_MAP[envName] === dotted, `${envName} maps to ${dotted}`);
    const fromEnv = config.load({ path: missing, env: { [envName]: String(min) }, flags: {} });
    ok(config.getPath(fromEnv.config, dotted) === min,
      `${envName}=${min} sets ${dotted} (and is not re-clamped)`);
    ok(fromEnv.sources[dotted] === 'env', `${dotted}: sources reports "env" for it`);

    ok(config.FLAG_MAP[flagName] === dotted, `--${flagName} maps to ${dotted}`);
    const fromFlag = config.load({ path: missing, env: {}, flags: { [flagName]: max } });
    ok(config.getPath(fromFlag.config, dotted) === max,
      `--${flagName} ${max} sets ${dotted} (and is not re-clamped)`);
  }

  // The end of the chain: a config this module produced, handed to the class
  // that consumes it, comes back out unchanged. That is the "one wall inside
  // the other" guarantee stated as behaviour rather than as arithmetic.
  const loaded = config.load({ path: missing, env: {}, flags: {} }).config;
  const live = new limits.Limits(loaded.limits);
  ok(AUTH_KNOBS.every(([bare]) => live[bare] === loaded.limits[bare]),
    'every auth knob survives a round-trip through the Limits class unclamped');
}

// ----------------------------------------------------------- load never throws

function testLoadNeverThrows(tmp) {
  const badJson = path.join(tmp, 'bad.json');
  fs.writeFileSync(badJson, '{ this is not json', { mode: 0o600 });
  const malformed = config.load({ path: badJson, env: {}, flags: {} });
  ok(malformed.config.listen.port === config.DEFAULTS.listen.port,
    'malformed JSON falls back to defaults instead of throwing');
  ok(malformed.warnings.some((w) => /not valid JSON/.test(w)), 'and warns about it');

  const notObject = path.join(tmp, 'not-object.json');
  fs.writeFileSync(notObject, JSON.stringify([1, 2, 3]), { mode: 0o600 });
  const arrayResult = config.load({ path: notObject, env: {}, flags: {} });
  ok(arrayResult.config.listen.port === config.DEFAULTS.listen.port,
    'a JSON file that is not an object falls back to defaults');
  ok(arrayResult.warnings.some((w) => /not a JSON object/.test(w)), 'and warns about it');

  const canSimulateUnreadable =
    process.platform !== 'win32' && !(process.getuid && process.getuid() === 0);
  if (canSimulateUnreadable) {
    const unreadable = path.join(tmp, 'unreadable.json');
    fs.writeFileSync(unreadable, JSON.stringify(config.DEFAULTS), { mode: 0o600 });
    fs.chmodSync(unreadable, 0o000);
    try {
      const result = config.load({ path: unreadable, env: {}, flags: {} });
      ok(result.config.listen.port === config.DEFAULTS.listen.port,
        'an unreadable path falls back to defaults');
      ok(result.warnings.some((w) => /could not read/.test(w)), 'and warns about it');
    } finally {
      fs.chmodSync(unreadable, 0o600);
    }
  } else {
    console.log('  (skipped: unreadable-path check needs a non-root POSIX user)');
  }
}

// -------------------------------------------------------------- save/round-trip

function testSaveAndRoundTrip(tmp) {
  const validated = config.validate(config.DEFAULTS).config;
  const file = path.join(tmp, 'nested', 'dir', 'config.json');

  ok(!fs.existsSync(path.dirname(file)), 'the parent directory does not exist yet');
  config.save(file, validated);
  ok(fs.existsSync(path.dirname(file)), 'save() creates a missing parent directory');
  ok(fs.existsSync(file), 'save() writes the file');
  ok(!fs.existsSync(file + '.tmp'), 'save() leaves no .tmp file behind on success');
  // The temp name is no longer fixed, so the line above can no longer see a
  // stray one; scan the directory for any sibling ending in .tmp instead.
  ok(fs.readdirSync(path.dirname(file)).every((name) => !name.endsWith('.tmp')),
    'save() leaves no temporary sibling of any name behind on success');

  if (process.platform !== 'win32') {
    const mode = fs.statSync(file).mode & 0o777;
    ok(mode === 0o600, 'save() writes the file at mode 0600');
  }

  const reloaded = config.load({ path: file, env: {}, flags: {} });
  ok(JSON.stringify(reloaded.config) === JSON.stringify(validated),
    'a saved config reloads identically (round-trip)');
}

// ------------------------------------------------------- save: hostile tmp path

/*
 * The join codes are the hub's only door, and save() writes them in plaintext.
 * A fixed `<file>.tmp` made that write follow anything a local attacker cared
 * to put at that name -- a symlink pointed at a file of their own, or a stale
 * 0644 file whose mode writeFileSync would not tighten until after the
 * plaintext had already landed. save() now creates the temp file exclusively
 * and never through a link, so both are refused before a byte is written.
 */

function testSaveRefusesPlantedSymlink(tmp) {
  if (process.platform === 'win32') {
    console.log('  (skipped: symlink planting needs POSIX symlink semantics)');
    return;
  }
  const dir = path.join(tmp, 'symlink-attack');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'config.json');
  const stolen = path.join(dir, 'stolen.json');
  const bait = 'not the join codes\n';
  fs.writeFileSync(stolen, bait, { mode: 0o600 });

  withPinnedTempSuffix((suffix) => {
    const planted = file + suffix;
    fs.symlinkSync(stolen, planted);

    let threw = null;
    try {
      config.save(file, configWithSecret());
    } catch (err) {
      threw = err;
    }

    ok(threw !== null, 'save() throws rather than writing through a planted symlink');
    ok(fs.readFileSync(stolen, 'utf8') === bait,
      'the link target still holds its own content -- no join codes were written into it');
    ok(!fs.existsSync(file), 'and no config file was produced by the failed save');
    ok(fs.lstatSync(planted).isSymbolicLink(),
      'save() leaves the planted link alone rather than unlinking a file it did not create');
    ok(contentsOf(dir).every((text) => !text.includes(SECRET)),
      'the join code appears in no file in the directory');
  });
}

function testSaveRefusesStaleTempFile(tmp) {
  const dir = path.join(tmp, 'stale-tmp');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'config.json');

  // A good save first, so there is a real config to protect.
  const first = configWithSecret();
  config.save(file, first);
  const before = fs.readFileSync(file, 'utf8');

  withPinnedTempSuffix((suffix) => {
    const planted = file + suffix;
    fs.writeFileSync(planted, 'stale leftover\n');
    if (process.platform !== 'win32') fs.chmodSync(planted, 0o644);

    const second = configWithSecret();
    second.maxPlayers = 8;
    let threw = null;
    try {
      config.save(file, second);
    } catch (err) {
      threw = err;
    }

    ok(threw !== null, 'save() throws rather than reusing a stale file at its temp path');
    ok(fs.readFileSync(planted, 'utf8') === 'stale leftover\n',
      'the stale file is not written through');
    ok(fs.readFileSync(file, 'utf8') === before,
      'the existing config is left exactly as it was');
    if (process.platform !== 'win32') {
      ok((fs.statSync(file).mode & 0o777) === 0o600,
        'the config is still at mode 0600 after the refused save');
      ok((fs.statSync(planted).mode & 0o077) !== 0,
        'the stale 0644 file never became the config (it is still the loose one)');
    }
  });

  // With the leftover gone the next save succeeds, at 0600.
  const third = configWithSecret();
  third.maxPlayers = 8;
  config.save(file, third);
  ok(config.load({ path: file, env: {}, flags: {} }).config.maxPlayers === 8,
    'the next save succeeds once the leftover is cleared');
  if (process.platform !== 'win32') {
    ok((fs.statSync(file).mode & 0o777) === 0o600,
      'and lands at mode 0600, never looser');
  }
}

function testSaveIgnoresTheOldFixedTempPath(tmp) {
  if (process.platform === 'win32') {
    console.log('  (skipped: symlink planting needs POSIX symlink semantics)');
    return;
  }
  // The real-world version of the attack: the attacker knows `<file>.tmp`,
  // because that is the name the old code used. It is now nobody's path.
  const dir = path.join(tmp, 'legacy-tmp');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'config.json');
  const stolen = path.join(dir, 'stolen.json');
  fs.writeFileSync(stolen, 'bait\n', { mode: 0o600 });
  fs.symlinkSync(stolen, file + '.tmp');

  config.save(file, configWithSecret());

  ok(fs.readFileSync(stolen, 'utf8') === 'bait\n',
    'a symlink at the old fixed <file>.tmp receives nothing -- save() no longer uses that name');
  ok(fs.readFileSync(file, 'utf8').includes(SECRET), 'the real config was written');
  ok((fs.statSync(file).mode & 0o777) === 0o600, 'at mode 0600');
}

function testConcurrentSavesDoNotCollide(tmp) {
  // Two writers on one config file are real now: server.js persists
  // credential use-counts from the running hub while `rby-mmo-hub invite` may
  // be saving the same file. Two things are asserted -- that no two saves
  // ever pick the same temp path, and that a save landing in the middle of
  // another one leaves both of them successful.
  const dir = path.join(tmp, 'concurrent');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'config.json');

  const realOpen = fs.openSync;
  const seen = [];
  fs.openSync = function (target, ...rest) {
    if (typeof target === 'string' && target.endsWith('.tmp')) seen.push(target);
    return realOpen.call(fs, target, ...rest);
  };

  const realRename = fs.renameSync;
  let reentered = false;

  try {
    for (let i = 0; i < 16; i++) config.save(file, configWithSecret());
    ok(seen.length === 16, 'each save opened exactly one temporary file');
    ok(new Set(seen).size === seen.length, '16 saves of one file picked 16 distinct temp paths');
    ok(seen.every((p) => p !== file + '.tmp'),
      'and none of them is the old predictable <file>.tmp');
    ok(seen.every((p) => path.dirname(p) === dir),
      'every temp file is a sibling of the target, so the rename stays on one filesystem');

    // A second "process" saves while the first is between write and rename.
    const inner = configWithSecret();
    inner.maxPlayers = 9;
    const outer = configWithSecret();
    outer.maxPlayers = 7;

    fs.renameSync = function (from, to) {
      if (!reentered) {
        reentered = true;
        config.save(file, inner); // the other process, mid-flight
      }
      return realRename.call(fs, from, to);
    };

    config.save(file, outer);
    ok(reentered, 'the interleaved save really ran inside the outer one');
    ok(config.load({ path: file, env: {}, flags: {} }).config.maxPlayers === 7,
      'both saves completed without colliding; the later rename is the one that stands');
    ok(fs.readdirSync(dir).every((name) => !name.endsWith('.tmp')),
      'and neither left a temporary file behind');
  } finally {
    fs.openSync = realOpen;
    fs.renameSync = realRename;
  }
}

// ------------------------------------------------------------- checkPermissions

function testCheckPermissions(tmp) {
  if (process.platform === 'win32') {
    console.log('  (skipped: checkPermissions is a no-op on win32)');
    return;
  }
  const file = path.join(tmp, 'perm.json');
  fs.writeFileSync(file, '{}', { mode: 0o644 });
  fs.chmodSync(file, 0o644); // writeFileSync's mode is subject to umask; force it
  const warned = config.checkPermissions(file);
  ok(typeof warned === 'string' && warned.length > 0, 'a 0644 file gets a warning');

  fs.chmodSync(file, 0o600);
  const clean = config.checkPermissions(file);
  ok(clean === null, 'a 0600 file gets no warning');
}

// ------------------------------------------------------------------- redact

function testRedact() {
  const original = config.validate(config.DEFAULTS).config;
  original.auth.credentials = [
    { id: 'a', label: 'A', secret: 'ABCD-EFGH-JKMN-PQRS', createdAt: null,
      expiresAt: null, maxUses: null, uses: 0, revoked: false },
    { id: 'b', label: 'B', secret: 'WXYZ-2345-6789-CDEF', createdAt: null,
      expiresAt: null, maxUses: null, uses: 0, revoked: false },
  ];
  const snapshot = JSON.stringify(original);

  const redacted = config.redact(original);
  ok(JSON.stringify(original) === snapshot, 'redact() does not mutate its input');
  ok(redacted !== original, 'redact() returns a distinct object');

  for (let i = 0; i < original.auth.credentials.length; i++) {
    const real = original.auth.credentials[i].secret;
    const masked = redacted.auth.credentials[i].secret;
    ok(masked !== real, `credential ${i}'s secret is masked`);
    ok(!masked.includes(real), `credential ${i}'s masked form does not contain the full secret`);
  }
}

/*
 * The mask used to keep the first group -- ABCD-****-****-**** -- for the
 * stated purpose of telling two credentials apart in a listing. That is 4 of
 * 16 characters, 20 of 80 bits, printed into exactly the outputs the docs
 * call safe to screen-share; and `credential.id` is in the same table and
 * already does the disambiguating. Every character is hidden now, so the
 * assertion is the strong one: no run of the secret survives at all.
 */
function testMaskKeepsNoPartOfTheSecret() {
  const source = config.validate(config.DEFAULTS).config;
  source.auth.credentials = [{
    id: 'known', label: 'Known', secret: SECRET, createdAt: null,
    expiresAt: null, maxUses: null, uses: 0, revoked: false,
  }];

  const masked = config.redact(source).auth.credentials[0].secret;
  ok(masked === '******', 'the join code is masked as six ungrouped characters');

  const bare = SECRET.replace(/-/g, '');
  let windows = 0;
  for (const form of [SECRET, bare]) {
    for (let i = 0; i + 4 <= form.length; i++) {
      const run = form.slice(i, i + 4);
      ok(!masked.includes(run),
        `the masked form contains no four-character run of the secret ("${run}")`);
      windows++;
    }
  }
  ok(windows > 0, 'the run check actually examined some windows of the secret');

  // Two different codes mask identically: the mask carries no information
  // about what it hides, which is the point of leaning on `id` instead.
  const other = config.validate(config.DEFAULTS).config;
  other.auth.credentials = [{
    id: 'other', label: 'Other', secret: 'PQRS-6789-2345-TVWX', createdAt: null,
    expiresAt: null, maxUses: null, uses: 0, revoked: false,
  }];
  ok(config.redact(other).auth.credentials[0].secret === masked,
    'two different join codes mask to the same string');
  ok(config.redact(other).auth.credentials[0].id === 'other',
    'the id -- what a host actually disambiguates by, and what `revoke` takes -- is untouched');
}

// ------------------------------------------------------------------- migrate

function testMigrate() {
  const versionless = config.migrate({});
  ok(versionless.raw.version === config.SCHEMA_VERSION,
    'a versionless object is stamped with the current schema version');

  const nonObject = config.migrate(null);
  ok(nonObject.raw.version === config.SCHEMA_VERSION,
    'a non-object input is also stamped with the current schema version');
}

// -------------------------------------------------------------- version parity

function testVersionParity() {
  const manifestPath = path.join(__dirname, '..', 'manifest.json');
  if (!fs.existsSync(manifestPath)) {
    // manifest.json lives outside server/ and is absent in a standalone
    // server install -- skip rather than fail, per the plan.
    console.log('  (skipped: manifest.json not found -- standalone server install)');
    return;
  }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, 'package.json'), 'utf8'));
  ok(pkg.version === manifest.version,
    `server/package.json (${pkg.version}) matches manifest.json (${manifest.version})`);
}

// --------------------------------------------------------------------- main

function main() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'rby-mmo-config-test-'));
  try {
    testPrecedence(tmp);
    testLegacyEnvVars(tmp);
    testClamping();
    testBoundsNesting();
    testAuthThrottleKeys(tmp);
    testLoadNeverThrows(tmp);
    testSaveAndRoundTrip(tmp);
    testSaveRefusesPlantedSymlink(tmp);
    testSaveRefusesStaleTempFile(tmp);
    testSaveIgnoresTheOldFixedTempPath(tmp);
    testConcurrentSavesDoNotCollide(tmp);
    testCheckPermissions(tmp);
    testRedact();
    testMaskKeepsNoPartOfTheSecret();
    testMigrate();
    testVersionParity();
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  console.log(`\n  ${passed}/${passed} checks passed  (config)\n`);
}

try {
  main();
} catch (err) {
  console.error('\n  ' + err.message + '\n');
  process.exit(1);
}
