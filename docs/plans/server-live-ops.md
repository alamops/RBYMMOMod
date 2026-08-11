> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — Server live ops: watch, match history, admin socket, MOTD, web dashboard

| Field | Value |
| --- | --- |
| Date | 2026-08-05 |
| Source | /implement — "rby-mmo-hub watch · Match history · Admin channel · MOTD on welcome · Server Web dashboard (protected with auth)" |
| Config | AGENTS_CONFIG.yml (quality) |
| Branch | feature/enhance-server-features |
| Base SHA | 2e9a98223073016120bf42bf4723e210900d7904 |
| Mode | **Autonomous** — grill and approval gates bypassed (owner unreachable mid-task); every scope decision logged in §8. |

## 1. Objective & success criteria

Five operator-facing features on the hub, one release (0.8.0):

1. **`rby-mmo-hub watch`** — a live-refreshing players view in the terminal.
2. **Match history** — every settled ranked battle appended to `history.jsonl`,
   readable via `rby-mmo-hub history`; W/L columns on `ranking`.
3. **Admin channel** — a Unix socket in the data dir carrying live commands:
   `who`, `stats`, `kick <name>`, `broadcast <text>`, with CLI verbs for the
   last two.
4. **MOTD** — a config field the hub delivers on welcome; new clients show it
   as a HUB line in the chat log; hot-reloadable via SIGHUP.
5. **Web dashboard** — an optional in-process HTTP page (players, ranking,
   throttle stats), login-protected by the hub's existing join codes,
   default-off and loopback-bound.

Done = all suites green, modkit validate/lint/pack green, both e2e drivers
green (as regression), docs and CHANGELOG shipped, no protocol bump.

## 2. Context & constraints (grounded findings)

**Chat / MOTD:**
- `mmo.chat` payload is `{from, name, scope, text}` (`relay.js:261`); client
  handler requires only `name/text/scope` to sanitise — `from` may be nil
  (`Client.lua:1165-1173`); scrollback never reads `from` (`Chat.lua:44-46`,
  `Ui.lua:1604-1619`); a bubble for an unknown id is stored but never drawn
  and expires in 5s (`Overlay.lua:486-510`, `Chat.lua:72-77`). **A hub-
  originated chat with no `from` is provably safe on 0.7.0 clients.**
- `mmo.welcome` is assembled at `relay.js:733-746`; neither side strips
  unknown keys — an old client simply never reads a new `motd` field.
- The bump rule (`relay.js:54-57`, `Config.lua:8-40`) triggers only when a
  *client* can send something an older *hub* ignores. Nothing here adds a
  client→hub message ⇒ **PROTOCOL stays 5** (decision logged, §8.2).
- `cleanText`/`Wire.text` collapse newlines and cap at `MESSAGE_MAX = 60`
  (`sanitize.js:14-21,158`, `Wire.lua:98-106`); the MOTD gets its own larger
  cap (`MOTD_MAX = 120`), same charset, single line.
- config: new leaf ⇒ auto-valid for `config get/set` via `LEAF_PATHS`
  (`config.js:264`); `set` re-joins argv with spaces (`cli.js:1351`) so
  multi-word MOTDs work; **SIGHUP reload() re-applies exactly three fields
  today** (`server.js:995-997`) — `motd` becomes the fourth.

**Match history:**
- Settlement is `settleMatch()` (`relay.js:1051-1105`); at that moment
  `match` holds names/ranked flags/hashes/`startedAt`/`endedAt`/`reports`,
  and `Board.record` returns `{repeats, winner: {name, points, gained},
  loser: {name, points, lost}}` (`rank.js:302-337`). `settled` is passed to
  `onRankChange` but **server.js discards it** (`server.js:491` wires a
  zero-arg callback) — the record shape must be captured via a new hook
  *before* `match` is deleted (`relay.js:1060`).
- Draws/disagreements/impostor matches settle to `null` and score nothing
  (`relay.js:1070-1090`) — they are not history.
- The codebase has **zero append-file precedent and no rotation discipline**;
  everything is tmp+rename (`server.js:616-620,667-670`). One appended JSON
  line per record in a single `write` call, `mode 0o600` on create, is the
  safe idiom. Rotation is a new policy (§3.4).
- `Board.export()` rows already carry `played`/`won` (`rank.js:380-400`) —
  W/L on the `ranking` verb is projection, no new state.

**Admin socket:**
- Zero IPC today beyond signals; the data-dir path idiom is
  `path.join(path.dirname(configPath), NAME)` (`server.js:459-460`) and
  `dataFile(ctx, name)` CLI-side (`cli.js:1953-1955`).
- Node does **not** auto-unlink a stale Unix socket file → bind must handle
  `EADDRINUSE` by `statSync(path).isSocket()` → unlink → retry once, and
  clean `close()` must unlink. New plumbing, no precedent.
- Kick: `refuse()` (`relay.js:896-900`) is the model — `mmo.error` with a
  message (the client renders it), `close()`, `drop()`. `drop()` alone never
  closes sockets (`relay.js:753-775`).
- Names are unique only for *ranked* clients (`relay.js:590-598`); kick by
  name must match case-insensitively (`keyOf`, `rank.js:66-70`) and may hit
  several clients.
- `broadcast(type, payload, exceptId)` (`relay.js:902-906`) reaches every
  ready client; no hub-originated chat exists yet.
- Docker: `/data` is the writable volume; `/tmp` is per-container tmpfs — the
  socket must live in the data dir. compose `docker compose exec hub
  rby-mmo-hub kick …` shares the mount, so the socket is reachable.
- hub.test.js/server.test.js `Client` helpers work over `{path}` with a
  one-line change (`server.test.js:69-138`).

**watch:**
- `run(argv, io)` resolves to an exit code; `verbStart` shows the stay-alive
  shape (`cli.js:1025-1253`). No timer-verb precedent → `watch` needs
  `--once` (single frame, exits OK) to be testable, and ANSI clear/home gated
  on `ctx.stdout.isTTY` (test sinks have none). Reuse `dataFile`,
  `readJsonFile`, `snapshotAge`, `printTable`, `plain`, `mapName`,
  `humanAge` (`cli.js:1953-2075`) — `verbPlayers` (`cli.js:2077-2232`) is
  "render one frame" and gets refactored so both verbs share it.

**Dashboard:**
- Auth model: 6-char join codes stored plaintext in config, verified with
  `crypto.timingSafeEqual` (`auth.js:56-65,213-252`); `limits.noteAuthFailure
  / noteAuthSuccess(ip)` (`limits.js:681-731`) is the shared throttle the
  dashboard must feed. `limits.stats().auth` (`limits.js:849-874`) is live
  telemetry only an in-process consumer can show — the dashboard is the first.
- `start()` handle already exposes `relay`, `limits`, `stats()`
  (`server.js:1228-1261`); second listener slots into `start()`/`close()`
  with its own error handling; `reload()` stays credential-live automatically
  if the dashboard checks `config.auth.credentials` at login time.
- Security posture to honor: default **off**, default host **127.0.0.1**
  (compose thesis: "not possible to publish an open world by forgetting a
  step", compose.yml:10-14); no TLS exists anywhere (zero-dep constraint) —
  docs must say plaintext-HTTP + overlay-network advice as loudly as
  README:717-729 does for the game port; **HTML-escaping does not exist in
  the repo** — new helper, every dynamic value escaped (player names are the
  XSS vector).
- Docker: ports >1024 need no capability; HEALTHCHECK untouched; compose gets
  a commented-out second port mapping only.

**Testing/tooling:** worktree suites run through a private engine view
(never repoint the shared symlink); `luajit`/`node` at /opt/homebrew/bin;
e2e needs `.env` and a free port 7799; SHOT_DIR moved to scratchpad.

## 3. Approach & key decisions

1. **MOTD rides `mmo.welcome.motd`** (not a synthetic chat): no bump, old
   clients ignore it. The **new** client renders it as a chat-scrollback
   line `{name = "HUB", scope = "global", text}` with no `from` (no bubble,
   no modal). It does light the CHAT unread badge — deliberately, after
   review: a greeting nobody notices is a greeting nobody reads. Rests on
   traced client code, §2.
2. **The name `HUB` becomes reserved** at hello (case-insensitive refuse with
   a remediation message) so hub-originated lines can't be impersonated.
3. **Broadcast reuses `mmo.chat`** with `name: 'HUB'`, `scope: 'global'`, no
   `from` — safe on 0.7.0 clients today, styled like any chat line.
4. **History**: new relay hook `onMatchSettled(record)` fired inside
   `settleMatch()` while `match` is still in scope; server.js appends one
   JSON line to `history.jsonl` (data dir, 0600 on create). Rotation: before
   an append that would push the file past `HISTORY_MAX_BYTES = 512 * 1024`,
   rename it to `history.jsonl.1` (replacing any previous `.1`) and start
   fresh — bounded at ~1 MiB total, no timers, no new deps.
5. **Admin socket** `admin.sock` beside `config.json`; trust = filesystem
   (data dir is 0700, same UID); **no in-band auth** (§8.4). One-shot
   newline-JSON exchange per connection (request line → response line →
   close). New module `server/lib/admin.js`.
6. **Dashboard** is an optional in-process `http` listener, new module
   `server/lib/dashboard.js`; login with **any active join code** (shared
   credentials, shared throttle, shared lockdown — one set of rules); session
   = HttpOnly+SameSite=Strict cookie holding a random token in an in-memory
   map (12 h expiry, wiped on restart). Default `enabled: false`, host
   `127.0.0.1`, port `7790`.
7. **PROTOCOL stays 5**; version 0.6.3→**0.8.0** everywhere (manifest,
   CHANGELOG, server/package.json — bump both together per package.json note).
8. **The embedded in-game hub (`src/Hub.lua`) gets none of this** — these are
   dedicated-hub operator features; the in-game host has no config file or
   terminal. Documented as a scoped difference (§8.7).

### Fixed contracts (tasks build against these, not each other's code)

**history.jsonl record** (one per line, written by server.js from the hook):
```json
{ "at": 1754300012345, "startedAt": 1754300000000, "repeats": 0,
  "winner": { "name": "RED", "points": 27, "gained": 16 },
  "loser":  { "name": "BLUE", "points": 3, "lost": 16 } }
```
`points` are post-match. The relay hook receives exactly
`{ at, startedAt, repeats, winner: {name, points, gained}, loser: {name,
points, lost} }` — relay supplies data, server.js does disk.

**Admin socket protocol** (`admin.sock`, newline-JSON, one exchange per
connection, request line capped at 4096 bytes):
- `{"cmd":"who"}` → `{"ok":true,"players":[roster rows],"count":N,
  "maxPlayers":M,"uptimeMs":T}`
- `{"cmd":"stats"}` → `{"ok":true,"stats":{…server stats…,"limits":{…limits.stats()…}}}`
- `{"cmd":"kick","name":"RED","reason":"optional"}` →
  `{"ok":true,"kicked":N,"names":[…]}` (name matched case-insensitively via
  the board's key rule; N may be 0 or >1; kicked clients get `mmo.error`
  with the reason — default "An operator removed you from this hub." — then
  close+drop, mirroring `refuse()`)
- `{"cmd":"broadcast","text":"…"}` → `{"ok":true,"delivered":N}` (text via
  `cleanText(text, MESSAGE_MAX)`; refused empty after cleaning)
- anything else / malformed line → `{"ok":false,"error":"…"}`
All inbound strings sanitised server-side (`cleanText` caps).

**config additions** (`config.js` DEFAULTS):
```js
motd: '',                                   // '' = no MOTD
dashboard: { enabled: false, host: '127.0.0.1', port: 7790 },
```
`motd` validated to `MOTD_MAX = 120` chars, `cleanText` charset (new
sanitize.js constant + a bespoke validate() pass that truncates/strips,
warning-free). `dashboard.port` gets BOUNDS `[1, 65535]`;
`dashboard.enabled` boolean-validated; `dashboard.host` string.
No SCHEMA_VERSION bump (additive; validate() backfills).

**Dashboard HTTP contract** (`lib/dashboard.js` exports
`start({ config, relay, limits, stats, ranking, log }) → { host, port,
close() }`; `ranking` is a function returning projected rows
`{place, name, points, played, won}` — no tokenHash ever):
- `GET /` → login form (no session) or dashboard page (session).
- `POST /login` — form body `code=…`; verify against **active** credentials
  (unrevoked/unexpired/under budget) with timingSafeEqual over
  normalized codes; on failure `limits.noteAuthFailure(ip)` and 403 (or 429
  while throttled — check `limits` first); on success
  `limits.noteAuthSuccess(ip)`, set cookie, 303 → `/`.
- `GET /logout` → clears session, 303 → `/`.
- `GET /api/status` (session) → `{ ...stats(), players: relay.roster(),
  limits: limits.stats() }`.
- `GET /api/ranking` (session) → `{ entries: ranking() }`.
- Every response: `Cache-Control: no-store`, `X-Content-Type-Options:
  nosniff`, CSP `default-src 'none'; style-src 'unsafe-inline';
  script-src 'unsafe-inline'; connect-src 'self'`. One self-contained HTML
  page, inline CSS/JS, fetch-refresh every 5 s, **every dynamic value
  HTML-escaped** by a local `escapeHtml`.
- If enabled but no active credential exists, refuse to start the listener
  and log the remediation (a dashboard nobody can log into is a hole, not a
  feature).

**MOTD wire/client contract:** hub sends `motd` (cleaned,
`cleanText(motd, MOTD_MAX)`) on `mmo.welcome` only when non-empty. Client
(`Client.lua` welcome handler): `local motd = Wire.text(msg.motd,
Config.MOTD_MAX); if motd and motd ~= "" then ctx.chat:push({ name = "HUB",
scope = "global", text = motd }) end`. `Config.MOTD_MAX = 120` with a
comment explaining the larger-than-chat budget and the no-bump rationale.

## 4. Work breakdown — implementation tasks

**Wave 1 (file-disjoint):**
- **A — relay core** · owns `server/lib/relay.js`, `server/lib/sanitize.js`.
  Add `MOTD_MAX` to sanitize.js. Relay: mutable `this.motd` (constructor
  option + setter), welcome carries cleaned `motd` when non-empty; reserve
  name HUB at hello (refuse, remediation copy); `onMatchSettled` option +
  `noteMatchSettled(record)` fired in `settleMatch()` per contract;
  `kickByName(name, reason)` → `{kicked, names}` mirroring `refuse()`;
  `announce(text)` → cleaned hub chat broadcast, returns delivered count.
  Acceptance: existing suites green; no wire type added.
- **B — config schema** · owns `server/lib/config.js`. `motd` leaf +
  `dashboard` section per contract, validators, redaction check (no secret
  lives in dashboard config — nothing to redact), comments in the file's
  voice. Acceptance: config suite green; `config set motd hello world` valid.
- **C — admin module** · owns `server/lib/admin.js` (new). Implements the
  socket server per protocol contract: `start({ path, relay, stats, limits,
  log }) → { path, close() }`; stale-socket recovery (EADDRINUSE → isSocket
  → unlink → retry once, else loud failure), unlink on close, request-line
  cap, per-connection one-shot exchange, all errors as `{ok:false}` lines,
  never throws into the hub. Header comment explains the trust model
  (filesystem perms are the auth) in the repo's voice.
- **D — dashboard module** · owns `server/lib/dashboard.js` (new). Per HTTP
  contract above. Zero deps (node:http, node:crypto). `escapeHtml` local
  helper. Sessions in-memory with expiry sweep on access. Never logs codes
  or session tokens. Acceptance: module is self-contained and callable with
  stubbed deps (no import of server.js).

**Wave 2 (file-disjoint; builds on wave 1 landing):**
- **E — server wiring** · owns `server/lib/server.js`. Thread `motd` into
  Relay + add it to `reload()`'s re-applied set (update the "exactly three
  things" comment and warning table); wire `onMatchSettled` → append to
  `history.jsonl` per record contract (single write, 0600 on create,
  rotation at `HISTORY_MAX_BYTES = 512*1024` → rename to `.1`); start
  `admin.js` listener when `configPath` exists (socket `admin.sock` beside
  config), close it in `close()`; start `dashboard.js` when
  `config.dashboard.enabled` (refuse+log when no active credential), close
  it in `close()`; expose `historyPath`/`adminPath`/`dashboard` on the
  handle; export new filename constants beside the existing ones.
- **F — CLI verbs** · owns `server/lib/cli.js`. `watch [--interval <s>]
  [--once]` (default 2 s; reuses a `renderPlayersFrame` refactor of
  verbPlayers; ANSI clear gated on `isTTY`; SIGINT resolves cleanly; --once
  renders one frame and exits OK); `history [-n N] [--json]` (default 20,
  newest first, honest empty/missing copy); `kick <name> [--reason …]` and
  `broadcast <text…>` dialing `admin.sock` via `dataFile` (newline-JSON
  one-shot; honest copy when the socket is absent: hub not running or too
  old); `ranking` gains W/L columns (played/won projection; `--json` adds
  the fields — it already carries played/won, keep). Help text + dispatch
  entries in the existing voice.
- **G — client MOTD** · owns `src/Client.lua`, `src/Config.lua`.
  Per MOTD contract; `Config.MOTD_MAX = 120` documented; welcome handler
  addition is nil-safe and does nothing on hubs without the field.
- **H — docs & version** · owns `manifest.json`, `server/package.json`,
  `CHANGELOG.md`, `README.md`, `mod.card`, `server/README.md`,
  `server/compose.yml`. 0.8.0 both manifests; CHANGELOG narrative (five
  features, HUB name reservation, no wire bump); server/README: `watch`/
  `history`/`kick`/`broadcast` rows + sections beside `players`/`ranking`,
  a new `## Dashboard` section after The CLI (enable steps, join-code
  login, **plaintext-HTTP warning as loud as the game port's**, loopback
  default, overlay advice), admin socket + `history.jsonl`/rotation +
  `motd` under Configuration, reload() table gains motd; compose.yml
  commented-out dashboard port mapping + why it's off by default; mod.card
  differences entries; root README operator table rows.

## 5. Work breakdown — test tasks

- **T1 — relay tests** · owns `server/rank.test.js`: HUB name refusal;
  welcome motd (present when set, absent when empty, cleaned/truncated);
  onMatchSettled record shape (points/gained/lost arithmetic, repeats,
  fires only on agreed ranked settlements — not draws/disagreements/
  impostors); kickByName (0/1/many matches, case-insensitive, peer gets
  mmo.error + close, roster notified); announce (delivered count, cleaning,
  empty refused).
- **T2 — server + admin + dashboard tests** · owns `server/server.test.js`:
  history.jsonl lifecycle over real sockets (settled battle → line appended,
  shape, 0600; rotation at cap via a small injected/large fixture);
  admin.sock: who/stats/kick/broadcast round-trips via the Client helper
  with `{path}`, malformed line → ok:false, stale-socket recovery (pre-plant
  a dead socket file, hub still binds), unlink on close; dashboard: login
  (bad code → 403 + counted by limits, good code → cookie, api/status +
  api/ranking shapes, no-session → login page, headers present, player name
  with `<script>` arrives escaped in HTML), refuses to start with no active
  credential; motd SIGHUP reload (change file, HUP, next welcome carries it).
- **T3 — CLI tests** · owns `server/cli.test.js`: `watch --once` (renders a
  frame, exits 0, no ANSI in non-TTY sink); `history` (empty/missing/N/
  --json); `kick`/`broadcast` against a scratch Unix socket speaking the
  protocol (fixture server in the test), and honest copy with no socket;
  ranking W/L columns.
- **T4 — Lua tests** · owns `tests/rby_mmo_test.lua`: fake-hub welcome with
  `motd` → chat scrollback gains the HUB line (no bubble), absent/empty/
  over-long motd handled; Config.MOTD_MAX pinned; old-hub welcome (no motd
  field) unchanged.
- **e2e**: both existing drivers run as **regression** (MOTD/admin/dashboard
  intentionally not driver-asserted this round — §8.9). Run recipe: private
  engine view, `.env` copy, SHOT_DIR in scratchpad, port 7799 freed, then
  `node --test`, Lua suite, modkit validate/lint/pack, run-mmo-e2e.sh,
  run-hub-e2e.sh.

## 6. Execution waves

1. Wave 1: A, B, C, D (opus ×4, parallel).
2. Wave 2: E, F, G, H (opus ×4, parallel) — E/F build against wave-1 code
   and the §3 contracts.
3. Review (opus) over the whole diff → triage → fix round.
4. Tests: T1–T4 (sonnet ×4, parallel).
5. Full battery (haiku, background), fixes (opus) ≤3 rounds.

## 7. Blast radius & risks

- `reload()` grows a fourth re-applied field — the comment and README table
  must move together or drift (review checks).
- Admin socket: unlink-on-EADDRINUSE must never unlink a non-socket file;
  close() ordering with the game listener; socket path length limits
  (~104 bytes on darwin) — test temp dirs must stay short.
- Dashboard: XSS via player names (escape everything), session fixation
  (random token, HttpOnly, SameSite=Strict), throttle bypass (must check
  limits before verifying), plaintext HTTP (docs), accidental exposure
  (default off + loopback).
- History append: partial trailing line after a crash is tolerable — the
  CLI reader must skip unparsable lines without dying; rotation must be
  rename-based (atomic) and never lose the file being appended.
- watch: ANSI only on TTY; a corrupted status.json repainted every 2 s must
  still pass through `plain()`.
- HUB name reservation can refuse an existing player named HUB — CHANGELOG
  says so plainly.
- Kick of a mid-battle player exercises endSession/endParty paths — relay
  tests cover it.

## 8. Open questions / assumptions (autonomous mode)

1. Autonomous gates bypassed; this section is the audit trail.
2. **No protocol bump** for 0.8.0: nothing new travels client→hub; welcome
   field + hub chat are hub→client and proven old-client-safe. Recorded as
   a deliberate extension of the bump rule's silence on that direction.
3. **Dashboard auth reuses join codes** (shared credentials/throttle/
   lockdown) rather than a separate secret — one set of rules; rotating a
   code rotates dashboard access, documented.
4. **Admin socket has no in-band auth** — the 0700 data dir is the boundary,
   like config.json itself; documented.
5. **kick matches all case-insensitive name matches** and reports the count
   (names are only unique for ranked players).
6. **History rotation**: single previous generation at 512 KiB (~1 MiB
   ceiling) rather than unbounded growth or a ring.
7. **Embedded in-game hub unchanged** — these are dedicated-hub features.
8. Dashboard has **no env/flag overrides** this round (config-file only).
9. **e2e drivers unchanged** — new features covered at unit/integration
   level; drivers run as regression only.
10. MOTD is single-line (charset/collapse of cleanText) at 120 chars.
