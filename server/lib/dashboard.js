'use strict';

/*
 * The optional web dashboard: one page, one login, no dependencies.
 *
 * What it is: an in-process `node:http` listener that shows a host who is
 * online, what the season looks like, and how hard the door is being knocked
 * on. Everything it draws is already in memory -- `stats()`, `relay.roster()`,
 * `limits.stats()`, the ranking projection -- so this module owns no state
 * except its sessions and reads no file. It never writes to the hub: there is
 * no kick button, no config editor, no verb of any kind. A page that can only
 * *look* is a page whose worst failure is a leak, not a takeover, and that is
 * the trade this thing is built on. Operator actions live on the admin socket,
 * behind filesystem permissions, where they can be reasoned about separately.
 *
 * Who gets in: anyone holding an **active join code** -- the same codes
 * players type, filtered the same way (`auth.activeCredentials`), read live
 * out of `config.auth.credentials` at every login so SIGHUP's replacement of
 * that array takes effect on the next attempt and a revoked code stops
 * working here at the same moment it stops working on the game port. One set
 * of credentials, one throttle, one lockdown: a wrong code typed at this page
 * is charged to `limits.noteAuthFailure` exactly like a wrong code answered on
 * the wire, and the hub-wide ceiling turns both away together. There is
 * deliberately no second secret to rotate and forget.
 *
 * **This page is plain HTTP and there is no TLS anywhere in this program.**
 * That is not an oversight to be fixed with a flag: the whole server is Node
 * core and zero dependencies, and the game port has the same gap for the same
 * reason (README, "The link is still not encrypted"). So the join code, the
 * session cookie and every roster line cross the network in the clear, and
 * anyone on the path can read them and replay the cookie. Which is why the
 * default bind is 127.0.0.1 and the default state is off: on loopback the
 * "network" is the host's own machine. **A public bind is not supported by
 * anything here.** Reach it from elsewhere over an encrypted overlay network
 * (WireGuard, Tailscale, ZeroTier) or an SSH tunnel and leave the listener on
 * loopback -- the same advice the README gives the game port, for exactly the
 * same reason.
 *
 * Untrusted values: a player name is a string a stranger chose, and it lands
 * in a browser here. Every dynamic value therefore either goes through
 * `escapeHtml` (server-rendered HTML) or is assigned to `.textContent` (the
 * page's own script, which never touches `innerHTML`). The CSP is
 * `default-src 'none'` with inline style and script allowed and `connect-src
 * 'self'`, so even a hole in that discipline has nowhere to send anything.
 *
 * Nothing here logs a join code, a session token, or a request body. The only
 * thing an attempt writes to the log is that it happened, from what address,
 * and how many have failed since start.
 */

const http = require('node:http');
const crypto = require('node:crypto');

const { activeCredentials, normalizeCode } = require('./auth');
const { safe } = require('./log');

// The cookie is short and unmemorable on purpose: it is not a brand, it is a
// name that will not collide with something else on 127.0.0.1, where a host
// may well be running other local tools on other ports and cookies are not
// isolated by port.
const COOKIE_NAME = 'rbyd';

// Long enough that a host watching a session through an evening does not get
// logged out mid-look; short enough that a forgotten browser tab is not a
// standing key. Sessions live in memory only, so a restart ends all of them.
const SESSION_TTL_MS = 12 * 60 * 60 * 1000;

// A ceiling on live sessions. Minting one requires a valid code, so this is
// not an anti-abuse measure -- it is the promise that a script logging in on
// a loop cannot grow the hub's memory. The soonest-to-expire goes first.
const SESSION_MAX = 64;

// A login form is a few dozen bytes. 4 KiB is generous by three orders of
// magnitude and still refuses to buffer anything a browser would not send.
const BODY_MAX_BYTES = 4096;

// How often the page re-fetches. Slow enough to be invisible on a hub with
// players on it, fast enough that a roster change is not stale news.
const REFRESH_MS = 5000;

// config.js owns the real defaults (`dashboard.host` / `dashboard.port`);
// these are the fallbacks for a caller that hands over a partial config --
// a suite with a stub, most likely. They are the same numbers on purpose: two
// spellings of a default that disagree is a bug nobody finds until the day
// the config is incomplete.
const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 7790;

const SECURITY_HEADERS = Object.freeze({
  // Nothing here is cacheable: it is a live view behind a login, and a proxy
  // or a back button holding on to a copy of the roster is a copy nobody
  // asked for.
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  // The JSON APIs answer with names a stranger chose. `nosniff` above stops a
  // browser from deciding one of them is HTML; this stops anything that did
  // get parsed from reaching the network. `connect-src 'self'` is what the
  // page's own fetch loop needs and the only network permission granted, and
  // `frame-ancestors 'none'` is the frame protection itself -- the page has no
  // frames and belongs in none, so no other document may embed it and collect
  // a logged-in host's clicks.
  'Content-Security-Policy':
    "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; " +
    "connect-src 'self'; frame-ancestors 'none'",
  // There is no other origin this page has anything to say to, and a URL from
  // a hub's dashboard is not a fact worth handing out.
  'Referrer-Policy': 'no-referrer',
});

const HTML = 'text/html; charset=utf-8';
const JSON_TYPE = 'application/json; charset=utf-8';
const TEXT = 'text/plain; charset=utf-8';

// ------------------------------------------------------------------ helpers

/**
 * The five characters that can turn a value into markup. `'` and `"` are here
 * because a value can land in an attribute as well as in text, and a helper
 * that is only safe in one of the two positions is a helper somebody will use
 * in the other one.
 */
function escapeHtml(value) {
  return String(value === null || value === undefined ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/** Whole seconds, in the spelling lib/server.js uses for the same refusals. */
function seconds(ms) {
  const whole = Math.max(1, Math.ceil(Number(ms) / 1000 || 0));
  return whole === 1 ? '1 second' : `${whole} seconds`;
}

/**
 * The address this request came from, as the throttle will key it.
 *
 * Handed to `limits` raw: `ipCountKey` normalises and, for IPv6, folds to the
 * /64 -- the same treatment the game port's addresses get. Doing our own
 * normalisation here would risk producing a second spelling of the same
 * address and splitting one attacker's backoff across two records.
 *
 * `X-Forwarded-For` is deliberately ignored. Trusting it would let anyone who
 * can reach the port choose which address gets charged for their guesses.
 */
function remoteIp(req) {
  const socket = req && req.socket;
  return (socket && socket.remoteAddress) || '';
}

/**
 * The Host header, lowercased and always carrying a port.
 *
 * A header with no port means the scheme's default, and this listener only
 * ever speaks plain HTTP, so that is 80 -- spelling it out keeps the
 * comparison one string equality instead of two cases. IPv6 authorities
 * arrive bracketed (`[::1]:7790`), so the port is the colon *after* the
 * bracket and never one inside the address.
 */
function hostAuthority(value) {
  if (typeof value !== 'string') return null;
  const header = value.trim().toLowerCase();
  if (!header) return null;
  const afterBracket = header.startsWith('[') ? header.indexOf(']') : 0;
  if (afterBracket < 0) return null; // an unclosed bracket is not an authority
  return header.indexOf(':', afterBracket) >= 0 ? header : `${header}:80`;
}

/** The authority a browser would type for one bind, IPv6 bracketed. */
function authorityOf(host, port) {
  const name = String(host === null || host === undefined ? '' : host);
  const bracketed = name.includes(':') && !name.startsWith('[') ? `[${name}]` : name;
  return `${bracketed}:${port}`.toLowerCase();
}

function cookieToken(req) {
  const header = req && req.headers && req.headers.cookie;
  if (typeof header !== 'string' || !header) return null;
  for (const part of header.split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() !== COOKIE_NAME) continue;
    const value = part.slice(eq + 1).trim();
    return value || null;
  }
  return null;
}

// No `Secure` flag: this listener speaks plain HTTP and always will (see the
// header), and a cookie a browser refuses to send is a page nobody can log
// into. HttpOnly keeps it out of scripts; SameSite=Strict keeps another site
// from riding it -- those two are the ones that still mean something without
// TLS.
function setCookie(token) {
  return `${COOKIE_NAME}=${token}; HttpOnly; SameSite=Strict; Path=/`;
}

function clearCookie() {
  return `${COOKIE_NAME}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0`;
}

// --------------------------------------------------------------------- page

const STYLE = `
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body {
  margin: 0; padding: 1.5rem;
  background: #10131a; color: #d8dee9;
  font: 15px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
main { max-width: 60rem; margin: 0 auto; }
h1 { font-size: 1.2rem; margin: 0 0 .25rem; letter-spacing: .08em; }
h2 { font-size: .95rem; margin: 2rem 0 .5rem; letter-spacing: .08em; color: #9aa5b1; }
a { color: #7fb2e5; }
.lede, .note, .fine { color: #9aa5b1; }
.fine { font-size: .85rem; margin-top: 2rem; }
.note { margin: 1rem 0 0; color: #e5a3a3; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: .35rem .75rem .35rem 0; border-bottom: 1px solid #232833; }
th { color: #7d8796; font-weight: normal; font-size: .8rem; letter-spacing: .06em; }
td.num { text-align: right; padding-right: 1.5rem; font-variant-numeric: tabular-nums; }
th.num { text-align: right; padding-right: 1.5rem; }
.empty { color: #7d8796; padding: .5rem 0; }
.panel { display: flex; flex-wrap: wrap; gap: 1.5rem; margin-top: .5rem; }
.panel div { min-width: 8rem; }
.panel dt { color: #7d8796; font-size: .8rem; letter-spacing: .06em; }
.panel dd { margin: .1rem 0 0; font-size: 1.1rem; }
.alarm { color: #e5a3a3; }
form { margin: 1.25rem 0 0; display: flex; gap: .5rem; flex-wrap: wrap; }
input {
  font: inherit; padding: .5rem .6rem; width: 12rem;
  background: #0b0e14; color: #d8dee9;
  border: 1px solid #303747; border-radius: 3px;
  text-transform: uppercase; letter-spacing: .2em;
}
button {
  font: inherit; padding: .5rem 1rem; cursor: pointer;
  background: #2c3a4f; color: #d8dee9;
  border: 1px solid #3d4d66; border-radius: 3px;
}
button:hover { background: #364763; }
`.trim();

function page(title, body) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>${escapeHtml(title)}</title>
<style>
${STYLE}
</style>
</head>
<body>
<main>
${body}
</main>
</body>
</html>
`;
}

/**
 * The login form. `message` is the one dynamic value on this page and it is
 * always a sentence this module wrote -- escaped anyway, because the day
 * somebody passes a borrowed string through here should not be the day this
 * page starts rendering markup.
 */
function loginPage(message) {
  const note = message
    ? `<p class="note">${escapeHtml(message)}</p>`
    : '';
  return page('RBY MMO hub', `<h1>RBY MMO HUB</h1>
<p class="lede">Sign in with a join code &mdash; the same code players type to
get on the hub. Revoking a code closes this page to it too.</p>
<form method="post" action="/login">
<input name="code" aria-label="Join code" autocomplete="off"
 autocapitalize="characters" autocorrect="off" spellcheck="false"
 maxlength="32" autofocus>
<button type="submit">Sign in</button>
</form>
${note}
<p class="fine">This page is served over plain HTTP: there is no TLS anywhere
in this hub. On 127.0.0.1 that is fine. Anywhere else, the code you are about
to type is readable by whoever is on the path &mdash; reach this page over an
encrypted overlay network or an SSH tunnel instead.</p>`);
}

/*
 * The dashboard itself. The server renders no data into it at all: the tables
 * arrive from /api/status and /api/ranking and are written with textContent,
 * so a player name containing markup has no path into the document. That is
 * why this function takes no arguments -- the only thing it could interpolate
 * is a string a stranger chose.
 */
function dashboardPage() {
  return page('RBY MMO hub', `<h1>RBY MMO HUB</h1>
<p class="lede" id="summary">Loading&hellip;</p>

<h2>PLAYERS</h2>
<table>
<thead><tr><th>NAME</th><th>LOCATION</th><th>STATUS</th><th class="num">POINTS</th></tr></thead>
<tbody id="players"></tbody>
</table>

<h2>RANKING</h2>
<table>
<thead><tr><th class="num">#</th><th>NAME</th><th class="num">POINTS</th><th class="num">W</th><th class="num">L</th></tr></thead>
<tbody id="ranking"></tbody>
</table>

<h2>THE DOOR</h2>
<dl class="panel">
<div><dt>CONNECTIONS</dt><dd id="connections">&ndash;</dd></div>
<div><dt>PENDING</dt><dd id="pending">&ndash;</dd></div>
<div><dt>WRONG CODES</dt><dd id="failures">&ndash;</dd></div>
<div><dt>LOCKDOWN</dt><dd id="lockdown">&ndash;</dd></div>
</dl>

<p class="fine">Refreshes every ${Math.round(REFRESH_MS / 1000)}s.
<a href="/logout">Sign out</a>.
This page is read-only and served over plain HTTP &mdash; keep it on loopback
or behind an encrypted overlay network.</p>

<script>
${PAGE_SCRIPT}
</script>`);
}

/*
 * The page's own script. Every value it receives came off the wire from
 * strangers, so it goes into the document through textContent and never
 * through innerHTML -- there is no escaping to get wrong because there is no
 * HTML being built. The CSP forbids reaching any origin but this one.
 *
 * Kept as a template string rather than a file: the whole point of this
 * module is one self-contained document with no second request in it.
 */
const PAGE_SCRIPT = `
'use strict';
var REFRESH = ${REFRESH_MS};

function el(id) { return document.getElementById(id); }

function cell(row, value, numeric) {
  var td = document.createElement('td');
  td.textContent = value === null || value === undefined || value === '' ? '-' : String(value);
  if (numeric) td.className = 'num';
  row.appendChild(td);
  return td;
}

function fill(tbody, rows, columns, emptyText) {
  tbody.textContent = '';
  if (!rows.length) {
    var tr = document.createElement('tr');
    var td = document.createElement('td');
    td.colSpan = columns;
    td.className = 'empty';
    td.textContent = emptyText;
    tr.appendChild(td);
    tbody.appendChild(tr);
    return;
  }
  for (var i = 0; i < rows.length; i++) tbody.appendChild(rows[i]);
}

// The engine's map ids are SHOUTED_WITH_UNDERSCORES; a human reads them
// better with spaces, and that is the only transformation applied.
function place(map) {
  if (typeof map !== 'string' || !map) return '-';
  return map.replace(/_+/g, ' ').trim() || '-';
}

function number(value) {
  return typeof value === 'number' && isFinite(value) ? value : 0;
}

function renderStatus(data) {
  var players = Array.isArray(data.players) ? data.players : [];
  var seats = number(data.maxPlayers) ? ' of ' + number(data.maxPlayers) : '';
  var where = data.host ? ' on ' + data.host + ':' + data.port : '';
  el('summary').textContent =
    players.length + ' player(s) online' + seats + where + '.';

  var rows = players.map(function (player) {
    var entry = player && typeof player === 'object' ? player : {};
    var tr = document.createElement('tr');
    cell(tr, entry.name);
    cell(tr, place(entry.map));
    cell(tr, entry.busy ? 'BUSY' : (entry.party ? 'PARTY' : ''), false);
    cell(tr, entry.ranked ? number(entry.points) : '', true);
    return tr;
  });
  fill(el('players'), rows, 4, 'Nobody is online.');

  var limits = data.limits && typeof data.limits === 'object' ? data.limits : {};
  var auth = limits.auth && typeof limits.auth === 'object' ? limits.auth : {};
  el('connections').textContent = String(number(limits.connections));
  el('pending').textContent = String(number(limits.pending));
  el('failures').textContent =
    number(auth.recentFailures) + ' / ' + number(auth.failureThreshold);
  var lockdown = el('lockdown');
  lockdown.textContent = auth.lockdown
    ? 'YES (' + Math.ceil(number(auth.lockdownMs) / 1000) + 's)'
    : 'no';
  lockdown.className = auth.lockdown ? 'alarm' : '';
}

function renderRanking(data) {
  var entries = Array.isArray(data.entries) ? data.entries : [];
  var rows = entries.map(function (entry, index) {
    var row = entry && typeof entry === 'object' ? entry : {};
    var played = number(row.played);
    var won = number(row.won);
    var tr = document.createElement('tr');
    cell(tr, number(row.place) || index + 1, true);
    cell(tr, row.name);
    cell(tr, number(row.points), true);
    cell(tr, won, true);
    cell(tr, Math.max(0, played - won), true);
    return tr;
  });
  fill(el('ranking'), rows, 5, 'Nobody has finished a ranked battle yet.');
}

function refresh() {
  Promise.all([
    fetch('/api/status', { credentials: 'same-origin' }),
    fetch('/api/ranking', { credentials: 'same-origin' })
  ]).then(function (responses) {
    // The session expired or was signed out in another tab. '/' is the login
    // form now, so going there says so without inventing a message here.
    if (responses[0].status === 401 || responses[1].status === 401) {
      window.location.href = '/';
      return null;
    }
    if (!responses[0].ok || !responses[1].ok) throw new Error('bad response');
    return Promise.all([responses[0].json(), responses[1].json()]);
  }).then(function (bodies) {
    if (!bodies) return;
    renderStatus(bodies[0]);
    renderRanking(bodies[1]);
  }).catch(function () {
    // A hub that stopped, a network that blinked. Say so and keep trying --
    // the next tick repairs the page on its own if it comes back.
    el('summary').textContent = 'Cannot reach the hub right now.';
  });
}

refresh();
setInterval(refresh, REFRESH);
`.trim();

// ------------------------------------------------------------------- server

/**
 * Start the dashboard listener.
 *
 * Every dependency is injected and none of them is imported: this module must
 * be drivable from a suite with four stubs and no hub behind it.
 *
 *   config   the live config object -- `config.dashboard` for the bind,
 *            `config.auth.credentials` read afresh at every login
 *   relay    only `roster()` is called
 *   limits   `authAllowed` / `authRetryAfterMs` / `noteAuthFailure` /
 *            `noteAuthSuccess` / `stats`
 *   stats    the handle's `stats()` -- called, never stored
 *   ranking  a function returning projected rows
 *            {place, name, points, played, won}
 *   log      a lib/log.js logger
 *
 * Resolves to `{ host, port, close() }`; rejects with an honest message if
 * the bind fails, in the shape lib/server.js's own listen does.
 */
function start(options = {}) {
  const { config, relay, limits, stats, ranking, log } = options;

  const settings = (config && config.dashboard) || {};
  const host = typeof settings.host === 'string' && settings.host
    ? settings.host : DEFAULT_HOST;
  const port = Number.isFinite(Number(settings.port))
    ? Number(settings.port) : DEFAULT_PORT;

  /*
   * The names this listener answers to, and why it checks at all.
   *
   * A browser can be sent to a name the attacker controls and then have that
   * name re-resolved to 127.0.0.1 -- DNS rebinding -- at which point every
   * request the attacker's script makes is same-origin with *their* name, the
   * session cookie rides along, and SameSite has nothing to say because there
   * is no cross-site anything happening. Checking the Host header is the
   * standard mitigation for a loopback HTTP server: a request has to name the
   * address this hub was actually reached at, which an attacker's domain
   * never does. It is refreshed from the bound address after listen, because
   * with `dashboard.port: 0` the configured port is not the port a browser
   * will type.
   */
  const authoritiesFor = (boundHost, boundPort) => new Set([
    authorityOf(host, port),
    authorityOf(boundHost, boundPort),
    `127.0.0.1:${boundPort}`,
    `[::1]:${boundPort}`,
    `localhost:${boundPort}`,
  ]);
  let allowedHosts = authoritiesFor(host, port);

  const liveCredentials = () => {
    const current = config && config.auth && config.auth.credentials;
    return Array.isArray(current) ? current : [];
  };

  /*
   * A dashboard with no code that opens it is not a locked door, it is a
   * listener nobody can use -- an open port with a login form on it and
   * nothing behind the form. Refuse rather than serve that, and name the
   * command that fixes it, in the spirit of lib/server.js's openDoorRefusal.
   *
   * This is a *start-time* check on purpose, and the only one: the login path
   * re-reads the credential list every time, so revoking the last code while
   * the hub runs correctly leaves the page up and refusing everybody rather
   * than tearing a listener down under a host who is mid-look.
   */
  if (activeCredentials(liveCredentials()).length === 0) {
    const refusal = 'the dashboard has no join code that still works, so ' +
      'nobody could log into it. Run `rby-mmo-hub invite` to add one, or set ' +
      'dashboard.enabled to false.';
    if (log) log.error(refusal);
    return Promise.reject(new Error(refusal));
  }

  // token -> expiry. In memory only: a restart signs everybody out, which is
  // the correct behaviour for a session whose only backing was this process.
  const sessions = new Map();
  let failedLogins = 0;

  function sweepSessions(now) {
    for (const [token, expiresAt] of sessions) {
      if (expiresAt <= now) sessions.delete(token);
    }
  }

  /*
   * The token is 32 random bytes -- 256 bits -- so the lookup is a plain Map
   * get rather than a constant-time scan. A hash lookup does leak timing, but
   * there is nothing to learn from it: the attacker cannot refine a guess
   * character by character the way a byte-by-byte comparison would let them,
   * and guessing a whole 256-bit token outright is not a thing that happens.
   * The comparison worth doing in constant time is the join code, which is 30
   * bits and typed by humans; that one uses timingSafeEqual below.
   */
  function sessionOf(req) {
    const token = cookieToken(req);
    if (!token) return null;
    const now = Date.now();
    sweepSessions(now);
    const expiresAt = sessions.get(token);
    if (expiresAt === undefined || expiresAt <= now) return null;
    return token;
  }

  function mintSession() {
    const now = Date.now();
    sweepSessions(now);
    while (sessions.size >= SESSION_MAX) {
      let oldest = null;
      let oldestAt = Infinity;
      for (const [token, expiresAt] of sessions) {
        if (expiresAt < oldestAt) { oldest = token; oldestAt = expiresAt; }
      }
      if (oldest === null) break;
      sessions.delete(oldest);
    }
    const token = crypto.randomBytes(32).toString('hex');
    sessions.set(token, now + SESSION_TTL_MS);
    return token;
  }

  // ------------------------------------------------------------ responding

  function send(res, status, type, body, extra, after) {
    const payload = typeof body === 'string' ? body : String(body);
    const headers = Object.assign({}, SECURITY_HEADERS, {
      'Content-Type': type,
      'Content-Length': Buffer.byteLength(payload),
    }, extra || {});
    try {
      res.writeHead(status, headers);
      res.end(payload, after);
    } catch (err) {
      // The browser went away mid-write. Losing a response costs a repaint;
      // throwing here would cost the hub.
      if (log) log.debug(`dashboard response dropped: ${safe(err.message)}`);
    }
  }

  function sendJson(res, status, value) {
    let body;
    try {
      body = JSON.stringify(value);
    } catch (err) {
      if (log) log.error(`dashboard could not serialise a response: ${safe(err.message)}`);
      send(res, 500, TEXT, 'The hub could not describe itself just now.\n');
      return;
    }
    send(res, status, JSON_TYPE, body);
  }

  function sendLogin(res, status, message, extra) {
    send(res, status, HTML, loginPage(message), extra);
  }

  function redirect(res, location, extra) {
    // 303: a POST that succeeded must not be re-submitted by a reload.
    send(res, 303, TEXT, '', Object.assign({ Location: location }, extra || {}));
  }

  // ---------------------------------------------------------------- login

  /*
   * The passcode check, and the two ways it differs from the game port's.
   *
   * A browser cannot answer a challenge -- there is no HMAC step it could
   * perform without shipping the code to it first -- so the code is submitted
   * directly and compared. Over plain HTTP that means the code itself crosses
   * the network, which is the sharpest edge of the caveat in the header and
   * the reason this listener is loopback by default.
   *
   * What it keeps from lib/auth.js is the discipline: normalise first, only
   * active credentials are considered, timingSafeEqual over equal-length
   * buffers, and **no early exit** -- matching the first credential must take
   * the same time as matching the last, or the refusal becomes an oracle for
   * how many codes a hub is carrying and which one opened it.
   */
  function codeAccepted(submitted) {
    const given = normalizeCode(submitted);
    // Shape before secret, the idiom lib/auth.js uses: a null here is a
    // submission that is not a join code at all, and refusing it up front
    // leaks only the code's *format* -- six characters of a published
    // alphabet, printed on every invite and written down in the README. What
    // stays constant-time and exit-free is the part that is actually secret,
    // which is *which* six characters, compared below.
    if (given === null) return false;

    const active = activeCredentials(liveCredentials());
    let hit = false;

    for (const credential of active) {
      const key = normalizeCode(credential.secret);
      if (key === null) continue; // a stored secret that will not normalise
      const expected = Buffer.from(key, 'ascii');
      const offered = Buffer.from(given, 'ascii');
      const same = expected.length === offered.length &&
        crypto.timingSafeEqual(expected, offered);
      if (same) hit = true;
    }
    return hit;
  }

  function handleLogin(req, res, body) {
    const ip = remoteIp(req);

    /*
     * The throttle is consulted **before** anything is verified, exactly as
     * the game port does it (lib/server.js, the `mmo.hello` gate): a refusal
     * that arrives after the comparison is a refusal that still let the
     * attempt happen. A refused attempt is not recorded as a failure either,
     * for the reason limits.js gives -- retrying into a closed door is not a
     * guess, and counting it would let an honest host extend their own
     * backoff forever.
     */
    const attempt = limits && typeof limits.authAllowed === 'function'
      ? limits.authAllowed(ip) : { ok: true };
    if (!attempt || !attempt.ok) {
      const waitMs = limits && typeof limits.authRetryAfterMs === 'function'
        ? limits.authRetryAfterMs(ip) : 0;
      const message = attempt && attempt.reason === 'auth_lockdown'
        ? 'This hub has paused new join attempts for a moment: too many wrong ' +
          `join codes have been tried on it. Try again in ${seconds(waitMs)}.`
        : 'Too many wrong join codes from your address. Check the code, then ' +
          `try again in ${seconds(waitMs)}.`;
      if (log) log.debug(`dashboard login refused for ${safe(ip)}: ${attempt.reason}`);
      // 429 with the wait in the sentence and **no Retry-After header**: the
      // only reader of that header would be a script retrying on schedule,
      // and the human this page is for gets the same fact in words.
      sendLogin(res, 429, message);
      return;
    }

    let submitted = null;
    try {
      submitted = new URLSearchParams(body).get('code');
    } catch (err) {
      submitted = null; // an unparsable body is a wrong code, not an error
    }

    if (!codeAccepted(submitted)) {
      failedLogins += 1;
      // Never the code, never the body. The address and the running count are
      // the whole of what a host needs to see a grind starting.
      if (log) {
        log.debug(`dashboard: wrong join code from ${safe(ip)} ` +
          `(${failedLogins} failed login(s) since start)`);
      }
      if (limits && typeof limits.noteAuthFailure === 'function' &&
          limits.noteAuthFailure(ip) && log) {
        // The edge, not every attempt: true only on the failure that trips
        // the hub-wide ceiling, so this is said once per lockout.
        log.warn('too many wrong join codes across this hub: new join ' +
          'attempts, including this dashboard, are refused for a moment. ' +
          'Players already connected are not affected.');
      }
      sendLogin(res, 403, 'That join code was not accepted.');
      return;
    }

    if (limits && typeof limits.noteAuthSuccess === 'function') {
      limits.noteAuthSuccess(ip);
    }
    /*
     * A dashboard login deliberately does **not** spend a credential's use
     * budget. `invite --uses 1` means one player gets on the hub; charging it
     * for a look at a web page would consume the invite before it was ever
     * handed out. The hub is the writer of record for `uses` (lib/server.js)
     * and this module has no path to persist a change anyway -- so it does
     * not pretend to make one.
     */
    if (log) log.info(`dashboard login from ${safe(ip)}`);
    redirect(res, '/', { 'Set-Cookie': setCookie(mintSession()) });
  }

  /*
   * Read a form body under a hard cap. Anything larger is refused before it
   * is buffered -- the bytes already read are dropped rather than kept, so a
   * peer cannot grow the hub's memory by sending a body it knows will be
   * rejected.
   */
  function readBody(req, res, done) {
    let size = 0;
    let text = '';
    let finished = false;

    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      if (finished) return;
      size += Buffer.byteLength(chunk);
      if (size > BODY_MAX_BYTES) {
        finished = true;
        text = '';
        send(res, 413, TEXT,
          'That is larger than this page accepts. A login form is a few ' +
          'dozen bytes.\n',
          { Connection: 'close' },
          () => req.socket.destroy());
        return;
      }
      text += chunk;
    });
    req.on('end', () => {
      if (finished) return;
      finished = true;
      done(text);
    });
    req.on('error', (err) => {
      if (finished) return;
      finished = true;
      if (log) log.debug(`dashboard request ended early: ${safe(err.message)}`);
    });
  }

  // --------------------------------------------------------------- routing

  function route(req, res) {
    // Before anything else, including the method check: a request that names
    // a host this page is not is not a request for this page, and nothing
    // about it -- not a session, not a login, not a 405 -- should be answered.
    // See `authoritiesFor` above for the rebinding attack this closes.
    const authority = hostAuthority(req.headers && req.headers.host);
    if (!authority || !allowedHosts.has(authority)) {
      send(res, 403, TEXT,
        'This page only answers to the address it is bound to, or to ' +
        'localhost on this machine.\n');
      return;
    }

    const method = req.method || 'GET';

    /*
     * Two methods exist here and no more. HEAD and OPTIONS are refused with
     * the rest: this is a page for a browser to render and a fetch loop to
     * read, and answering a method nobody uses is surface with no purpose.
     */
    if (method !== 'GET' && method !== 'POST') {
      send(res, 405, TEXT, 'This page answers GET and POST.\n',
        { Allow: 'GET, POST' });
      return;
    }

    const raw = typeof req.url === 'string' ? req.url : '/';
    const query = raw.indexOf('?');
    const path = query >= 0 ? raw.slice(0, query) : raw;

    if (path === '/') {
      if (method !== 'GET') {
        send(res, 405, TEXT, 'This page answers GET.\n', { Allow: 'GET' });
        return;
      }
      if (sessionOf(req)) send(res, 200, HTML, dashboardPage());
      else sendLogin(res, 200, null);
      return;
    }

    if (path === '/login') {
      if (method !== 'POST') {
        send(res, 405, TEXT, 'Sign in with a POST from the form on /.\n',
          { Allow: 'POST' });
        return;
      }
      readBody(req, res, (body) => handleLogin(req, res, body));
      return;
    }

    if (path === '/logout') {
      if (method !== 'GET') {
        send(res, 405, TEXT, 'This page answers GET.\n', { Allow: 'GET' });
        return;
      }
      const token = cookieToken(req);
      if (token) sessions.delete(token);
      redirect(res, '/', { 'Set-Cookie': clearCookie() });
      return;
    }

    if (path === '/api/status' || path === '/api/ranking') {
      if (method !== 'GET') {
        send(res, 405, TEXT, 'This endpoint answers GET.\n', { Allow: 'GET' });
        return;
      }
      if (!sessionOf(req)) {
        // 401 rather than a redirect: the caller is the page's fetch loop,
        // and it needs a status it can branch on, not a login form parsed as
        // JSON.
        sendJson(res, 401, { error: 'not_signed_in' });
        return;
      }
      if (path === '/api/status') {
        /*
         * Projected to what the page draws, not spread.
         *
         * `stats()` carries `perIp` -- the throttle's table of who is
         * connected from which address -- and `limits.stats()` carries the
         * same table again. Anyone holding a join code can log in here, which
         * is every player on the hub, and other players' addresses are not
         * theirs to read: the roster is deliberately built without them
         * (relay.js roster(), "no addresses, no token material") and this
         * endpoint must not put back what that projection left out. Naming
         * the fields means a future counter added to either stats() cannot
         * arrive on this page by accident.
         */
        const base = stats ? stats() : {};
        const counts = limits && typeof limits.stats === 'function' ? limits.stats() : {};
        sendJson(res, 200, {
          host: base.host,
          port: base.port,
          maxPlayers: base.maxPlayers,
          players: relay && typeof relay.roster === 'function' ? relay.roster() : [],
          limits: {
            connections: counts.connections,
            pending: counts.pending,
            auth: counts.auth,
          },
        });
      } else {
        /*
         * Projected to exactly the five fields the page draws, rather than
         * forwarded. The board's own rows carry a `tokenHash` -- the digest
         * that stands in for a player's identity -- and it must never leave
         * the process. The caller is contracted to project already; doing it
         * again here costs a map and means a future caller who forgets cannot
         * leak one through this endpoint.
         */
        const rows = ranking && typeof ranking === 'function' ? ranking() : [];
        const entries = (Array.isArray(rows) ? rows : []).map((row, index) => {
          const entry = row && typeof row === 'object' ? row : {};
          return {
            place: Number.isFinite(Number(entry.place)) ? Number(entry.place) : index + 1,
            name: typeof entry.name === 'string' ? entry.name : '',
            points: Number(entry.points) || 0,
            played: Number(entry.played) || 0,
            won: Number(entry.won) || 0,
          };
        });
        sendJson(res, 200, { entries });
      }
      return;
    }

    send(res, 404, TEXT, 'There is no page here.\n');
  }

  const server = http.createServer((req, res) => {
    try {
      route(req, res);
    } catch (err) {
      /*
       * A handler that throws must cost one response, never the hub. The
       * message goes to the log and not to the browser: an internal error
       * string can name paths and internals, and the person reading this page
       * is not always the person who owns the machine.
       */
      if (log) log.error(`dashboard request failed: ${safe(err && err.message)}`);
      if (!res.headersSent) {
        send(res, 500, TEXT, 'The hub could not answer that just now.\n');
      } else {
        try { res.end(); } catch (ignored) { /* already gone */ }
      }
    }
  });

  // A browser holding a keep-alive socket open is normal; a peer holding one
  // open and never speaking is the slowloris shape. Both are bounded by the
  // same short budgets, well under the game port's, because everything here
  // is a local request that finishes immediately.
  server.headersTimeout = 10000;
  server.requestTimeout = 20000;
  server.keepAliveTimeout = 5000;

  let closing = null;

  function close() {
    if (closing) return closing;
    sessions.clear();
    closing = new Promise((resolve) => {
      server.close(() => {
        if (log) log.info('dashboard stopped');
        resolve();
      });
      // Keep-alive sockets would otherwise hold the port past close(). The
      // page is stateless between requests, so nothing is lost by cutting
      // them; the alternative is a hub that will not exit.
      if (typeof server.closeAllConnections === 'function') {
        server.closeAllConnections();
      }
    });
    return closing;
  }

  return new Promise((resolve, reject) => {
    const onListenError = (err) => {
      const why = err && err.code === 'EADDRINUSE'
        ? `the dashboard cannot bind ${host}:${port}: something is already ` +
          'listening there. Change dashboard.port, or stop the other program.'
        : `the dashboard cannot bind ${host}:${port}: ${err && err.message}`;
      if (log) log.error(why);
      reject(new Error(why));
    };
    server.once('error', onListenError);

    server.listen(port, host, () => {
      server.removeListener('error', onListenError);
      // After the bind, an error belongs to one accept and is not a reason to
      // take the page away -- the same rule the game listener follows.
      server.on('error', (err) => {
        if (log) log.error(`dashboard listener error: ${safe(err.message)}`);
      });

      const address = server.address();
      const boundHost = address && address.address ? address.address : host;
      const boundPort = address && address.port ? address.port : port;
      allowedHosts = authoritiesFor(boundHost, boundPort);

      if (log) {
        log.info(`dashboard listening on http://${boundHost}:${boundPort} ` +
          '(plain HTTP, join-code login)');
        if (boundHost !== '127.0.0.1' && boundHost !== '::1' &&
            boundHost !== 'localhost') {
          log.warn(`the dashboard is bound to ${safe(boundHost)}, not loopback: ` +
            'it speaks plain HTTP, so the join code typed into it and the ' +
            'session cookie it hands back are readable by anyone on the path. ' +
            'Bind 127.0.0.1 and reach it over an SSH tunnel or an encrypted ' +
            'overlay network instead.');
        }
      }

      resolve({ host: boundHost, port: boundPort, close });
    });
  });
}

// The constants are exported for the same reason lib/server.js exports its
// filenames: a suite that asserts on the cookie or the body cap should name
// the budget rather than carry its own copy of the number.
module.exports = {
  start,
  escapeHtml,
  COOKIE_NAME,
  SESSION_TTL_MS,
  SESSION_MAX,
  BODY_MAX_BYTES,
  REFRESH_MS,
  DEFAULT_HOST,
  DEFAULT_PORT,
};
