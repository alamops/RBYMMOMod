'use strict';

/*
 * The one file a host configures, and the only module that reads or writes it.
 *
 * JSON rather than YAML or TOML because JSON.parse is core and the other two
 * would be this repo's first dependency -- a rule stated in hub.js, in
 * server/README.md and in CLAUDE.md, and one that holds here.
 *
 * Precedence, decided once and honoured everywhere:
 *
 *   CLI flag  >  RBY_MMO_* env var  >  config file  >  built-in default
 *
 * That order is not a preference, it is the order hub.js already has:
 * `node hub.js 9000` beats RBY_MMO_PORT, which beats the built-in 7788
 * (hub.js:28-29,54-56). A config file slots in underneath the env vars rather
 * than above them, so no existing deployment changes behaviour by growing a
 * config file next to it.
 *
 * Two rules run through everything below:
 *
 *  - Loading never throws. A hub that refuses to start over a stray comma is
 *    worse for its host than one that starts on defaults and says loudly what
 *    it could not read -- the host is on a phone, on a train, and the world
 *    is down either way.
 *  - Out-of-range is pulled to the nearest end and warned about, never
 *    obeyed, exactly the way clampPlayers already treats the player cap
 *    (hub.js:48-52). A config file is not a mechanism for setting a limit out
 *    of range.
 *
 * This module deliberately does not require ./auth.js. The CLI depends on
 * both; the dependency between the two stays one-directional so that reading
 * a config never pulls in crypto, and generating a credential is the CLI's
 * job, not the store's.
 *
 * No dependencies: node:fs, node:path and node:crypto only. node:crypto is
 * here for one thing -- the unpredictable suffix on the temp file save()
 * writes through -- not for anything cryptographic; minting and verifying
 * join codes remains auth.js's job.
 */

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const CONFIG_FILENAME = 'config.json';
// The container mounts its named volume here (plan §3.4/§3.5). Used only when
// it already exists, so a bare-metal host never gets pointed at /data.
const CONTAINER_DIR = '/data';

const SCHEMA_VERSION = 1;

const DEFAULTS = {
  version: SCHEMA_VERSION,
  listen: { host: '0.0.0.0', port: 7788 },
  maxPlayers: 4,
  // The one line the hub hands every player on arrival -- it rides on the
  // welcome and lands in their chat log as a HUB line. Empty means the hub
  // says nothing, which is the right default: a greeting the host never wrote
  // is worse than silence, and an empty string is also the signal the relay
  // reads to leave the field off the wire entirely.
  motd: '',
  auth: { required: true, credentials: [] },
  limits: {
    perIpConnections: 4,
    connectBurst: 10,
    connectPerMinute: 60,
    handshakeTimeoutMs: 10000,
    idleTimeoutMs: 45000,
    partialLineTimeoutMs: 10000,
    maxPending: 8,
    maxWriteBufferBytes: 262144,
    chatIntervalMs: 500,
    // The authentication-failure throttle. Values are limits.js's own
    // DEFAULTS verbatim -- that module owns what its knobs mean, and a
    // second opinion here would only be a way for the two to disagree.
    authFailureGrace: 3,
    authFailureWindowMs: 600000,
    authBackoffBaseMs: 2000,
    authBackoffMaxMs: 300000,
    authGlobalFailures: 100,
    authGlobalWindowMs: 60000,
    authLockoutMs: 60000,
  },
  bans: [],
  allowlist: [],
  network: { upnp: { enabled: false, leaseSeconds: 3600 } },
  log: { level: 'info' },
};

/*
 * How long a MOTD may be, and the only thing about it that is a hard number.
 *
 * 120 rather than the wire's MESSAGE_MAX of 60: a chat line is typed by a
 * player mid-game, a MOTD is written once by the host and is the only sentence
 * the hub gets to say for itself, so it gets twice the budget. It stays one
 * line and one charset with chat all the same, because it is delivered through
 * the same field a client already knows how to render.
 *
 * sanitize.js owns this contract -- MOTD_MAX and cleanText() there are what
 * the relay actually applies before the value goes on the wire. The value and
 * the character class are spelled out again here only because this module
 * deliberately requires nothing from its siblings (see the header note on
 * keeping that dependency one-directional), and a config store that pulled in
 * the wire sanitiser to check one string would trade that property for very
 * little. The copy is small, and the two are pinned together by the suite
 * rather than by an import: if they ever disagree, the config file is merely
 * stricter or looser than a value that gets cleaned again downstream anyway.
 */
const MOTD_MAX = 120;
const MOTD_ALLOWED = /[^A-Za-z0-9 .,!?'\-:;()/]/g;

const LOG_LEVELS = ['debug', 'info', 'warn', 'error', 'silent'];

/*
 * Clamp bounds. Each range is chosen so that both ends still describe a hub
 * that works: the low end is the smallest value that is not a
 * self-denial-of-service, the high end the largest that cannot be used to
 * make the process itself the weapon.
 *
 *   listen.port               1 .. 65535     the TCP port space
 *   maxPlayers                2 .. 64        unchanged from hub.js:44-45
 *   perIpConnections          1 .. 64        1 is workable; above the player
 *                                            cap it stops being a limit
 *   connectBurst              1 .. 1000      bucket depth
 *   connectPerMinute          1 .. 6000      100/s sustained is already past
 *                                            anything a friend group produces
 *   handshakeTimeoutMs     1000 .. 120000    under 1 s drops slow mobile
 *                                            links; over 2 min is not a
 *                                            timeout
 *   idleTimeoutMs          5000 .. 600000    the client has no auto-reconnect
 *                                            (src/Transport.lua:163), so a
 *                                            short idle timeout is a bug
 *   partialLineTimeoutMs   1000 .. 300000    limits.js's own range, adopted
 *                                            rather than re-derived -- see
 *                                            the note below
 *   maxPending                1 .. 256       ungreeted sockets, §3.6
 *   maxWriteBufferBytes   16384 .. 16777216  16 KiB holds a roster;
 *                                            16 MiB x maxPlayers is the worst
 *                                            case the host pays in RAM
 *   chatIntervalMs            0 .. 60000     0 disables the flood gate
 *   upnp.leaseSeconds        60 .. 604800    a lease shorter than a minute
 *                                            expires mid-game; a week is the
 *                                            longest a stale mapping should
 *                                            outlive the process
 *
 * And the authentication-failure throttle, every range of it taken verbatim
 * from limits.js for the reason in the paragraph below:
 *
 *   authFailureGrace          0 .. 100       free wrong codes before an
 *                                            address starts backing off
 *   authFailureWindowMs    1000 .. 86400000  how long one address's failures
 *                                            are remembered
 *   authBackoffBaseMs       100 .. 3600000   the first delay past the grace
 *   authBackoffMaxMs       1000 .. 86400000  the ceiling it escalates to
 *   authGlobalFailures        1 .. 1000000   hub-wide failures per window
 *                                            before the ceiling trips
 *   authGlobalWindowMs     1000 .. 3600000   the window they are counted over
 *   authLockoutMs          1000 .. 3600000   how long the ceiling stays
 *                                            tripped
 *
 * Every range above is a subset of the matching range in limits.js, so a
 * value this module accepts is never re-clamped downstream -- one wall sits
 * inside the other rather than beside it. partialLineTimeoutMs and the seven
 * auth* knobs are the ones taken verbatim from limits.js instead of
 * tightened: that module owns the slowloris sweep and the guess-rate
 * throttle and is the authority on what its own budgets mean, and two clamps
 * that disagree would be worse than one loose one.
 */
const BOUNDS = {
  'listen.port': [1, 65535],
  'maxPlayers': [2, 64],
  'limits.perIpConnections': [1, 64],
  'limits.connectBurst': [1, 1000],
  'limits.connectPerMinute': [1, 6000],
  'limits.handshakeTimeoutMs': [1000, 120000],
  'limits.idleTimeoutMs': [5000, 600000],
  'limits.partialLineTimeoutMs': [1000, 300000],
  'limits.maxPending': [1, 256],
  'limits.maxWriteBufferBytes': [16384, 16777216],
  'limits.chatIntervalMs': [0, 60000],
  'limits.authFailureGrace': [0, 100],
  'limits.authFailureWindowMs': [1000, 86400000],
  'limits.authBackoffBaseMs': [100, 3600000],
  'limits.authBackoffMaxMs': [1000, 86400000],
  'limits.authGlobalFailures': [1, 1000000],
  'limits.authGlobalWindowMs': [1000, 3600000],
  'limits.authLockoutMs': [1000, 3600000],
  'network.upnp.leaseSeconds': [60, 604800],
};

/*
 * Env var -> config path. RBY_MMO_PORT, RBY_MMO_HOST and RBY_MMO_MAX are
 * load-bearing names, not new ones: hub.js:28-29,54 already reads all three
 * and server/README.md documents them. They keep their spelling and their
 * position in the precedence order.
 *
 * RBY_MMO_CONFIG is the odd one out -- it names *where the file is*, not a
 * value inside it -- so it targets CONFIG_PATH_TARGET and is consumed by
 * resolvePath() instead of being merged.
 */
const CONFIG_PATH_TARGET = 'configPath';

const ENV_MAP = {
  RBY_MMO_CONFIG: CONFIG_PATH_TARGET,
  RBY_MMO_HOST: 'listen.host',
  RBY_MMO_PORT: 'listen.port',
  RBY_MMO_MAX: 'maxPlayers',
  RBY_MMO_AUTH_REQUIRED: 'auth.required',
  RBY_MMO_PER_IP: 'limits.perIpConnections',
  RBY_MMO_CONNECT_BURST: 'limits.connectBurst',
  RBY_MMO_CONNECT_PER_MINUTE: 'limits.connectPerMinute',
  RBY_MMO_HANDSHAKE_TIMEOUT_MS: 'limits.handshakeTimeoutMs',
  RBY_MMO_IDLE_TIMEOUT_MS: 'limits.idleTimeoutMs',
  RBY_MMO_PARTIAL_LINE_TIMEOUT_MS: 'limits.partialLineTimeoutMs',
  RBY_MMO_MAX_PENDING: 'limits.maxPending',
  RBY_MMO_MAX_WRITE_BUFFER_BYTES: 'limits.maxWriteBufferBytes',
  RBY_MMO_CHAT_INTERVAL_MS: 'limits.chatIntervalMs',
  RBY_MMO_AUTH_FAILURE_GRACE: 'limits.authFailureGrace',
  RBY_MMO_AUTH_FAILURE_WINDOW_MS: 'limits.authFailureWindowMs',
  RBY_MMO_AUTH_BACKOFF_BASE_MS: 'limits.authBackoffBaseMs',
  RBY_MMO_AUTH_BACKOFF_MAX_MS: 'limits.authBackoffMaxMs',
  RBY_MMO_AUTH_GLOBAL_FAILURES: 'limits.authGlobalFailures',
  RBY_MMO_AUTH_GLOBAL_WINDOW_MS: 'limits.authGlobalWindowMs',
  RBY_MMO_AUTH_LOCKOUT_MS: 'limits.authLockoutMs',
  RBY_MMO_UPNP: 'network.upnp.enabled',
  RBY_MMO_UPNP_LEASE_SECONDS: 'network.upnp.leaseSeconds',
  RBY_MMO_LOG_LEVEL: 'log.level',
};

/*
 * CLI flag -> config path, for the short spellings a host actually types.
 * Any dotted config path is also accepted verbatim, which is what makes
 * `rby-mmo-hub config set limits.maxPending 12` work without a flag entry
 * per knob.
 */
const FLAG_MAP = {
  config: CONFIG_PATH_TARGET,
  host: 'listen.host',
  port: 'listen.port',
  max: 'maxPlayers',
  maxPlayers: 'maxPlayers',
  auth: 'auth.required',
  perIp: 'limits.perIpConnections',
  connectBurst: 'limits.connectBurst',
  connectPerMinute: 'limits.connectPerMinute',
  handshakeTimeout: 'limits.handshakeTimeoutMs',
  idleTimeout: 'limits.idleTimeoutMs',
  partialLineTimeout: 'limits.partialLineTimeoutMs',
  maxPending: 'limits.maxPending',
  maxWriteBuffer: 'limits.maxWriteBufferBytes',
  chatInterval: 'limits.chatIntervalMs',
  // The `Ms` is dropped from the flag spelling the way handshakeTimeout and
  // partialLineTimeout already drop theirs; `authFailureGrace` and
  // `authGlobalFailures` are counts, so they keep their full names.
  authFailureGrace: 'limits.authFailureGrace',
  authFailureWindow: 'limits.authFailureWindowMs',
  authBackoffBase: 'limits.authBackoffBaseMs',
  authBackoffMax: 'limits.authBackoffMaxMs',
  authGlobalFailures: 'limits.authGlobalFailures',
  authGlobalWindow: 'limits.authGlobalWindowMs',
  authLockout: 'limits.authLockoutMs',
  upnp: 'network.upnp.enabled',
  upnpLease: 'network.upnp.leaseSeconds',
  logLevel: 'log.level',
};

// -------------------------------------------------------------- small tools

function clone(value) {
  // Round-tripping through JSON is the point, not a shortcut: the config is
  // defined as what survives a write and a read, so anything that would not
  // survive one should not be in the object in the first place.
  return JSON.parse(JSON.stringify(value));
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** Every leaf of DEFAULTS, dotted. Arrays count as leaves. */
function leafPaths(node, prefix) {
  const out = [];
  for (const [key, value] of Object.entries(node)) {
    const dotted = prefix ? `${prefix}.${key}` : key;
    if (isPlainObject(value)) out.push(...leafPaths(value, dotted));
    else out.push(dotted);
  }
  return out;
}

const LEAF_PATHS = leafPaths(DEFAULTS, '');

function getPath(object, dotted) {
  let node = object;
  for (const key of dotted.split('.')) {
    if (!isPlainObject(node) || !(key in node)) return undefined;
    node = node[key];
  }
  return node;
}

function setPath(object, dotted, value) {
  const keys = dotted.split('.');
  let node = object;
  for (const key of keys.slice(0, -1)) {
    if (!isPlainObject(node[key])) node[key] = {};
    node = node[key];
  }
  node[keys[keys.length - 1]] = value;
}

// Env vars are always strings and a flag from argv usually is too, so every
// coercion below has to accept the string spelling of its type.
function asBoolean(value) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  if (typeof value !== 'string') return null;
  const text = value.trim().toLowerCase();
  if (['true', '1', 'yes', 'on', 'y'].includes(text)) return true;
  if (['false', '0', 'no', 'off', 'n', ''].includes(text)) return false;
  return null;
}

function asInteger(value) {
  if (typeof value === 'boolean') return null;
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  return Math.floor(n);
}

// --------------------------------------------------------------- validation

function clampNumber(config, dotted, warnings) {
  const [min, max] = BOUNDS[dotted];
  const fallback = getPath(DEFAULTS, dotted);
  const raw = getPath(config, dotted);

  if (raw === undefined || raw === null || raw === '') {
    setPath(config, dotted, fallback);
    return;
  }
  const n = asInteger(raw);
  if (n === null) {
    warnings.push(`${dotted}: "${raw}" is not a number, using ${fallback}`);
    setPath(config, dotted, fallback);
    return;
  }
  if (n < min) {
    warnings.push(`${dotted}: ${n} is below the minimum, raised to ${min}`);
    setPath(config, dotted, min);
    return;
  }
  if (n > max) {
    warnings.push(`${dotted}: ${n} is above the maximum, lowered to ${max}`);
    setPath(config, dotted, max);
    return;
  }
  setPath(config, dotted, n);
}

function validateBoolean(config, dotted, warnings) {
  const fallback = getPath(DEFAULTS, dotted);
  const raw = getPath(config, dotted);
  if (raw === undefined || raw === null) {
    setPath(config, dotted, fallback);
    return;
  }
  const bool = asBoolean(raw);
  if (bool === null) {
    warnings.push(`${dotted}: "${raw}" is not true or false, using ${fallback}`);
    setPath(config, dotted, fallback);
    return;
  }
  setPath(config, dotted, bool);
}

/*
 * A bind address. Not resolved and not checked against this machine's
 * interfaces -- reachability.js is the module that has an opinion about
 * whether an address is *reachable*, and a config store guessing at it would
 * only be a second, worse answer. All this refuses is a value that cannot be
 * a host at all: a number, a list, a run of spaces.
 */
function validateHost(config, dotted, warnings) {
  const fallback = getPath(DEFAULTS, dotted);
  const raw = getPath(config, dotted);
  if (typeof raw !== 'string' || !raw.trim()) {
    if (raw !== undefined && raw !== null) {
      warnings.push(`${dotted}: "${raw}" is not an address, using ${fallback}`);
    }
    setPath(config, dotted, fallback);
    return;
  }
  setPath(config, dotted, raw.trim());
}

/*
 * The MOTD, normalised rather than judged -- the one leaf here that never
 * produces a warning.
 *
 * Everything else in this file that fixes a value also says so, because a host
 * who wrote 900000 for a timeout meant something by it and deserves to know it
 * did not happen. Prose is different: a MOTD with a tab in it, or a 200th
 * character, is not a host reaching past a limit, it is a host writing a
 * sentence. The relay would clean the same string the same way on its way to
 * the wire (sanitize.js's cleanText, MOTD_MAX), so warning here would only
 * report the cost of a rule the value was going to meet anyway. An over-long
 * MOTD becomes a truncated MOTD, quietly, and `config get motd` shows exactly
 * what the players will see.
 *
 * A non-string -- a number, a list, a leftover null -- is not a sentence at
 * all, so it becomes the empty default: no MOTD, which is the same thing an
 * absent field means.
 */
function validateMotd(config) {
  const raw = getPath(config, 'motd');
  if (typeof raw !== 'string') {
    setPath(config, 'motd', DEFAULTS.motd);
    return;
  }
  // Same order as cleanText: strip what the charset does not allow (which is
  // how control characters and newlines leave), then collapse the whitespace
  // that survives, then trim, then cap. Stripping first is what keeps a
  // newline from silently becoming a word break the wire would not agree with.
  const clean = raw.replace(MOTD_ALLOWED, '').replace(/\s+/g, ' ').trim();
  setPath(config, 'motd', clean.slice(0, MOTD_MAX));
}

function validateStringList(config, dotted, warnings) {
  const raw = getPath(config, dotted);
  if (raw === undefined || raw === null) {
    setPath(config, dotted, []);
    return;
  }
  if (!Array.isArray(raw)) {
    warnings.push(`${dotted}: not a list, ignored`);
    setPath(config, dotted, []);
    return;
  }
  const out = [];
  for (const entry of raw) {
    if (typeof entry === 'string' && entry.trim()) out.push(entry.trim());
    else warnings.push(`${dotted}: dropped an entry that is not an address`);
  }
  setPath(config, dotted, out);
}

/*
 * Credentials are shaped here, never minted here -- generating a join code is
 * the CLI's job (see the header note on the one-directional dependency). What
 * this does is refuse to hand the auth layer a credential it would have to
 * guess about: an entry with no secret cannot admit anyone, and an entry with
 * an unreadable expiry would be treated as expired anyway, so both are better
 * reported now than silently ignored at connect time.
 */
function validateCredentials(config, warnings) {
  const raw = getPath(config, 'auth.credentials');
  if (raw === undefined || raw === null) {
    setPath(config, 'auth.credentials', []);
    return;
  }
  if (!Array.isArray(raw)) {
    warnings.push('auth.credentials: not a list, ignored');
    setPath(config, 'auth.credentials', []);
    return;
  }

  const out = [];
  raw.forEach((entry, index) => {
    if (!isPlainObject(entry)) {
      warnings.push(`auth.credentials[${index}]: not an object, dropped`);
      return;
    }
    if (typeof entry.secret !== 'string' || !entry.secret.trim()) {
      warnings.push(`auth.credentials[${index}]: no join code, dropped`);
      return;
    }

    let expiresAt = null;
    if (entry.expiresAt !== null && entry.expiresAt !== undefined && entry.expiresAt !== '') {
      const at = Date.parse(entry.expiresAt);
      if (Number.isFinite(at)) {
        expiresAt = new Date(at).toISOString();
      } else {
        warnings.push(
          `auth.credentials[${index}]: expiresAt "${entry.expiresAt}" is not a ` +
          'date, treated as never expiring');
      }
    }

    let maxUses = null;
    if (entry.maxUses !== null && entry.maxUses !== undefined && entry.maxUses !== '') {
      const max = asInteger(entry.maxUses);
      if (max === null || max < 1) {
        warnings.push(
          `auth.credentials[${index}]: maxUses "${entry.maxUses}" is not a ` +
          'positive count, treated as unlimited');
      } else {
        maxUses = max;
      }
    }

    const uses = asInteger(entry.uses);

    const shaped = {
      id: typeof entry.id === 'string' && entry.id ? entry.id : `credential-${index}`,
      label: typeof entry.label === 'string' && entry.label ? entry.label : 'Join code',
      secret: entry.secret.trim(),
      createdAt: typeof entry.createdAt === 'string' ? entry.createdAt : null,
      expiresAt,
      maxUses,
      uses: uses !== null && uses > 0 ? uses : 0,
      revoked: asBoolean(entry.revoked) === true,
    };

    // `admin` marks a credential the in-game operator features arriving later
    // will admit. It has to survive this function untouched: the
    // save path rewrites every credential from the validated shape, so a flag
    // this rebuild forgot would be dropped the next time the hub persisted a
    // use count -- an admin quietly demoted to a player.
    //
    // Canonical form is present-and-true or absent, never `admin: false`, so
    // the credentials an older hub wrote stay byte-identical and a player's
    // code gains no field. Written only for a value that reads as true; a
    // `null` from asBoolean is an unreadable setting, and an unreadable
    // privilege flag is not one to resolve in favour of privilege.
    if (asBoolean(entry.admin) === true) shaped.admin = true;

    out.push(shaped);
  });

  setPath(config, 'auth.credentials', out);
}

/**
 * Coerce, clamp and prune. Returns a new object; the input is not touched.
 * Never throws, never rejects a config outright -- the worst outcome is a
 * config identical to DEFAULTS plus a list of warnings explaining why.
 */
function validate(config) {
  const warnings = [];
  const source = isPlainObject(config) ? config : {};
  if (!isPlainObject(config)) warnings.push('config is not an object, using defaults');

  let working;
  try {
    working = clone(source);
  } catch (err) {
    warnings.push(`config could not be copied (${err.message}), using defaults`);
    working = {};
  }

  // Unknown top-level keys are dropped rather than fatal: a key from a newer
  // version, or a typo, should cost the host a warning and not a hub.
  for (const key of Object.keys(working)) {
    if (!(key in DEFAULTS)) {
      warnings.push(`unknown setting "${key}" ignored`);
      delete working[key];
    }
  }

  const version = asInteger(working.version);
  if (version === null) working.version = SCHEMA_VERSION;
  else working.version = version;

  validateHost(working, 'listen.host', warnings);

  for (const dotted of Object.keys(BOUNDS)) clampNumber(working, dotted, warnings);

  validateBoolean(working, 'auth.required', warnings);
  validateBoolean(working, 'network.upnp.enabled', warnings);
  validateMotd(working);
  validateCredentials(working, warnings);
  validateStringList(working, 'bans', warnings);
  validateStringList(working, 'allowlist', warnings);

  const level = working.log && working.log.level;
  if (typeof level === 'string' && LOG_LEVELS.includes(level.trim().toLowerCase())) {
    setPath(working, 'log.level', level.trim().toLowerCase());
  } else {
    if (level !== undefined && level !== null) {
      warnings.push(
        `log.level: "${level}" is not one of ${LOG_LEVELS.join(', ')}, ` +
        `using ${DEFAULTS.log.level}`);
    }
    setPath(working, 'log.level', DEFAULTS.log.level);
  }

  // Anything the file never mentioned falls back to the built-in default, so
  // callers downstream can read every path without an existence check.
  for (const dotted of LEAF_PATHS) {
    if (getPath(working, dotted) === undefined) {
      setPath(working, dotted, clone(getPath(DEFAULTS, dotted)));
    }
  }

  return { config: working, warnings };
}

// ---------------------------------------------------------------- migration

/*
 * Version handling. Today there is exactly one version, so this is almost
 * nothing -- but it is the shape a second version drops into: add a
 * MIGRATIONS[1] that returns the v2 object, and the loop below walks a v1
 * file forward without any caller learning that it happened.
 */
const MIGRATIONS = {
  // 1: (raw) => ({ ...raw, version: 2, /* ... */ }),
};

function migrate(raw) {
  const warnings = [];
  if (!isPlainObject(raw)) {
    return { raw: { version: SCHEMA_VERSION }, warnings: [] };
  }

  let working = clone(raw);
  if (working.version === undefined || working.version === null) {
    // A versionless file is a v1 file: version was there from the first
    // release, so the only way to lack one is to have been hand-written.
    working.version = SCHEMA_VERSION;
  }

  let version = asInteger(working.version);
  if (version === null || version < 1) {
    warnings.push(
      `config version "${working.version}" is not a version, reading it as ${SCHEMA_VERSION}`);
    version = SCHEMA_VERSION;
    working.version = SCHEMA_VERSION;
  }

  while (version < SCHEMA_VERSION && MIGRATIONS[version]) {
    working = MIGRATIONS[version](working);
    version = asInteger(working.version) || version + 1;
  }

  if (version > SCHEMA_VERSION) {
    warnings.push(
      `config version ${version} was written by a newer hub; reading what ` +
      'this one understands and leaving the rest alone');
  } else if (version !== SCHEMA_VERSION) {
    warnings.push(`config version ${version} has no migration path, reading it as-is`);
  }

  return { raw: working, warnings };
}

// ------------------------------------------------------------------ location

/**
 * Where the config lives, in the order a host expects it to be looked for:
 * an explicit --config flag, then RBY_MMO_CONFIG, then a config.json in the
 * working directory, then the container's volume mount. The last step only
 * fires when /data is really a directory, so a bare-metal host is never
 * pointed at a path that does not exist on their machine.
 */
function resolvePath(options = {}) {
  const { flag, env = process.env, cwd = process.cwd() } = options;

  if (typeof flag === 'string' && flag.trim()) {
    return path.resolve(cwd, flag.trim());
  }
  const fromEnv = env && env.RBY_MMO_CONFIG;
  if (typeof fromEnv === 'string' && fromEnv.trim()) {
    return path.resolve(cwd, fromEnv.trim());
  }

  const local = path.resolve(cwd, CONFIG_FILENAME);
  try {
    if (fs.existsSync(local)) return local;
  } catch (err) {
    // an unreadable cwd is not a reason to fail; fall through
  }

  try {
    if (fs.statSync(CONTAINER_DIR).isDirectory()) {
      return path.join(CONTAINER_DIR, CONFIG_FILENAME);
    }
  } catch (err) {
    // no /data: not a container, nothing to say about it
  }

  // Nothing exists yet. Name where `init` should write, not where it isn't.
  return local;
}

// -------------------------------------------------------------------- files

function readRaw(file) {
  const warnings = [];
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return { raw: null, exists: false, warnings };
    warnings.push(`could not read ${file}: ${err.message}; using defaults`);
    return { raw: null, exists: true, warnings };
  }

  try {
    const parsed = JSON.parse(text);
    if (!isPlainObject(parsed)) {
      warnings.push(`${file} is not a JSON object; using defaults`);
      return { raw: null, exists: true, warnings };
    }
    return { raw: parsed, exists: true, warnings };
  } catch (err) {
    // Loud, and then carry on. The alternative -- refusing to start -- turns
    // one misplaced comma into an outage for everyone who was going to play.
    warnings.push(
      `${file} is not valid JSON (${err.message}); using defaults. ` +
      'The file was left untouched, so it can still be fixed by hand.');
    return { raw: null, exists: true, warnings };
  }
}

/**
 * Read the config and fold flag, env and file over the built-in defaults.
 *
 * Returns { config, path, exists, warnings, sources }, where `sources` maps
 * every leaf path to 'flag' | 'env' | 'file' | 'default' -- so `status` can
 * answer the question a confused host actually asks, which is not "what is
 * the port" but "why is it that".
 */
function load(options = {}) {
  const { env = process.env, flags = {}, cwd = process.cwd() } = options;
  const file = options.path || resolvePath({ flag: flags.config, env, cwd });

  const warnings = [];
  const sources = {};
  for (const dotted of LEAF_PATHS) sources[dotted] = 'default';

  const merged = clone(DEFAULTS);

  const read = readRaw(file);
  warnings.push(...read.warnings);

  if (read.raw) {
    const migrated = migrate(read.raw);
    warnings.push(...migrated.warnings);

    // Name every setting in the file this hub does not know. Only reading the
    // paths it recognises would be quieter, but a host who typed
    // `maxPlayer: 8` and got 4 deserves to be told which word was wrong
    // rather than left to wonder whether the file is being read at all.
    for (const dotted of leafPaths(migrated.raw, '')) {
      if (!LEAF_PATHS.includes(dotted)) {
        warnings.push(`${file}: unknown setting "${dotted}" ignored`);
      }
    }

    for (const dotted of LEAF_PATHS) {
      const value = getPath(migrated.raw, dotted);
      if (value === undefined) continue;
      setPath(merged, dotted, value);
      sources[dotted] = 'file';
    }
  }

  for (const [name, dotted] of Object.entries(ENV_MAP)) {
    if (dotted === CONFIG_PATH_TARGET) continue; // location, not a value
    const value = env ? env[name] : undefined;
    if (value === undefined || value === null || value === '') continue;
    setPath(merged, dotted, value);
    sources[dotted] = 'env';
  }

  for (const [name, value] of Object.entries(flags)) {
    if (value === undefined || value === null) continue;
    const dotted = FLAG_MAP[name] || (LEAF_PATHS.includes(name) ? name : null);
    if (dotted === CONFIG_PATH_TARGET) continue;
    if (!dotted) {
      warnings.push(`unknown option "${name}" ignored`);
      continue;
    }
    setPath(merged, dotted, value);
    sources[dotted] = 'flag';
  }

  const checked = validate(merged);
  warnings.push(...checked.warnings);

  if (read.exists) {
    const permission = checkPermissions(file);
    if (permission) warnings.push(permission);
  }

  return {
    config: checked.config,
    path: file,
    exists: read.exists,
    warnings,
    sources,
  };
}

/**
 * Write the config atomically, and only to the owner.
 *
 * The temporary file is a sibling so the rename stays inside one filesystem
 * -- across a mount boundary rename() fails and the guarantee is gone. A
 * crash mid-write then costs the tmp file and nothing else: the real config
 * is either the old one or the new one, never half of either, which matters
 * because the file holds the join codes that are the hub's only door.
 *
 * The tmp file is *created* rather than written to, and the difference is the
 * whole point:
 *
 *  - A fixed `<file>.tmp` is a name an attacker can occupy first. Anyone able
 *    to create a file in the config directory -- a shared /srv/hub, a
 *    world-writable cwd, a second service account -- could point that name at
 *    a file of their own and receive every join code, because writeFileSync
 *    follows symlinks. O_NOFOLLOW refuses the link, O_EXCL refuses any
 *    pre-existing file at all, and both refuse *before* a byte of plaintext
 *    exists on disk. A leftover tmp is a hard error now, not a target.
 *  - The mode is applied at creation. writeFileSync's `mode` option is
 *    ignored when the file already exists, so the old code repaired the mode
 *    with a chmod that ran only after the plaintext was already readable.
 *  - The suffix carries the pid and six random bytes because two writers are
 *    now real: server.js persists credential use-counts from the running hub
 *    while a `rby-mmo-hub invite` process may be saving the same file. One
 *    shared tmp name would have them clobber each other.
 *
 * Windows has no O_NOFOLLOW (fs.constants.O_NOFOLLOW is undefined there, and
 * OR-ing it in would produce NaN flags), so on win32 the flag is dropped and
 * the guarantee rests on O_EXCL plus the unpredictable name -- the same place
 * checkPermissions() already stops, since POSIX mode bits do not describe a
 * Windows ACL either.
 */
function save(file, config) {
  const directory = path.dirname(file);
  // 0700 when this call is the one that creates it: the directory ends up
  // holding the join codes, the match ledger and a live admin socket, and
  // mode applies only on creation -- a directory that already exists keeps
  // whatever the host gave it.
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });

  const temporary = `${file}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`;
  const text = `${JSON.stringify(config, null, 2)}\n`;

  let flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL;
  if (process.platform !== 'win32') flags |= fs.constants.O_NOFOLLOW;

  let fd;
  try {
    fd = fs.openSync(temporary, flags, 0o600);
  } catch (err) {
    // Nothing was created, so there is nothing to clean up -- and in
    // particular nothing of somebody else's to unlink.
    if (err && (err.code === 'EEXIST' || err.code === 'ELOOP')) {
      err.message =
        `${err.message} -- refused to write through the existing ${temporary}; ` +
        'delete it if it is a leftover of yours';
    }
    throw err;
  }

  try {
    try {
      fs.writeFileSync(fd, text);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    // The open mode is masked by the process umask, so a host running with
    // umask 0200 would otherwise end up at 0400. Now that the file is
    // provably ours and provably not a link, saying 0600 exactly is safe.
    if (process.platform !== 'win32') fs.chmodSync(temporary, 0o600);
    // rename is an inode operation: the target inherits the mode the fd was
    // created with, so no chmod on `file` is needed (and none should run
    // against a path that is only ours after the rename lands).
    fs.renameSync(temporary, file);
  } catch (err) {
    try {
      fs.unlinkSync(temporary);
    } catch (cleanupErr) {
      // nothing left to do; the real error is the one being rethrown
    }
    throw err;
  }

  return file;
}

/**
 * Returns null when the file is the host's alone, or a sentence to print when
 * it is not. The file holds join codes in plaintext -- it has to, since the
 * hub needs them to compute an HMAC -- so anyone who can read it can join.
 * On Windows the POSIX mode bits do not describe that, so the check is
 * skipped rather than guessed at.
 */
function checkPermissions(file) {
  if (process.platform === 'win32') return null;

  let stats;
  try {
    stats = fs.statSync(file);
  } catch (err) {
    return null; // no file is not an exposed file
  }

  const mode = stats.mode & 0o777;
  if ((mode & 0o077) === 0) return null;

  const who = [];
  if (mode & 0o070) who.push('the group');
  if (mode & 0o007) who.push('everyone else on this machine');
  return (
    `${file} is readable by ${who.join(' and ')} (mode ${mode.toString(8).padStart(3, '0')}). ` +
    'It holds join codes in plaintext; run `chmod 600` on it.'
  );
}

/**
 * A copy safe to print. Join codes are masked whole -- all six characters,
 * no prefix -- because the outputs this feeds (`status`, `config list`,
 * `invite list` without --reveal) are the ones documented as safe to
 * screen-share and safe to paste into a thread when asking for help.
 *
 * Telling two credentials apart is the `id` column's job. It is printed
 * beside the masked code in the same table, is not a secret, and is what
 * `revoke <id>` already takes -- so showing any part of the join code bought
 * nothing that id does not. That argument only got stronger when the code
 * shrank to 6 characters of a 32-symbol alphabet (2^30, lib/auth.js): there
 * is far less entropy left to spend on a prefix than there was.
 *
 * The mask is spelled out locally rather than imported from auth.js on
 * purpose; see the header note on keeping that dependency one-directional.
 */
function redact(config) {
  let copy;
  try {
    copy = clone(config);
  } catch (err) {
    return {};
  }

  const credentials = copy && copy.auth && copy.auth.credentials;
  if (Array.isArray(credentials)) {
    for (const credential of credentials) {
      if (!isPlainObject(credential)) continue;
      credential.secret = maskSecret(credential.secret);
    }
  }
  return copy;
}

// Deliberately independent of its argument: the printed shape is the same
// ****** whether the secret is well formed, malformed or absent, so the mask
// itself never becomes a side channel about what it hides. Fixed at
// CODE_LEN (auth.js) rather than derived from the secret's own length --
// deriving it would leak that length, and at a fixed six characters there is
// nothing to learn from doing so anyway.
function maskSecret(secret) {
  const CODE_LEN = 6;
  return '*'.repeat(CODE_LEN);
}

module.exports = {
  CONFIG_FILENAME,
  CONFIG_PATH_TARGET,
  SCHEMA_VERSION,
  DEFAULTS,
  BOUNDS,
  ENV_MAP,
  FLAG_MAP,
  LOG_LEVELS,
  LEAF_PATHS,
  resolvePath,
  load,
  validate,
  migrate,
  save,
  checkPermissions,
  redact,
  // exported because the CLI needs to read and write a single dotted key
  // (`config get`/`config set`) without duplicating the walk
  getPath,
  setPath,
};
