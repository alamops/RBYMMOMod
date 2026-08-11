> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — A self-hosting server application for the RBY MMO hub

| Field | Value |
| --- | --- |
| Date | 2026-08-02 |
| Source | `/implement` — "software as part of the repo for people hosting the game, runnable in a docker container… all configurations through this software… extreme safe to run and connect to" |
| Config | `AGENTS_CONFIG.yml` (quality preset) |
| Branch | `feature/software-for-hosting` |
| Base SHA | `5ef7d6b33ee5128af7a211507290d8fe6f77cd06` |
| Tree at base | clean except untracked `AGENTS_CONFIG.yml` |

## 1. Objective & success criteria

A person who is not a developer can host an RBY MMO world for friends anywhere in the
world, configure **everything** through one piece of software that ships in this repo,
run it bare-metal or in Docker, and hand out a join code that keeps everyone else out.

Done when:

1. `node server/bin/rby-mmo-hub.js init` runs an interactive first-run wizard, generates a
   join code and writes `config.json` with mode `0600`. No file is hand-edited to get a
   working, authenticated hub.
2. Every setting the hub has — port, bind address, player cap, limits, credentials, bans,
   allowlist, UPnP, log level — is readable and writable through the CLI. No setting is
   reachable *only* by editing the file or exporting an env var.
3. `docker compose up` in `server/` produces a running, authenticated hub as a non-root
   user on a read-only rootfs with all capabilities dropped, persisting its config on a
   named volume.
4. A player joining from another continent types the join code once in-game and connects;
   a stranger who finds the port cannot join, and is told so in one sentence.
5. The hardening is real and tested: per-IP connection caps, connection-rate limiting, a
   handshake timeout separate from the idle timeout, slowloris defence, write-backpressure
   bounds, bans, and a cap that ungreeted sockets cannot consume.
6. `node server/hub.js` still starts a hub with no config and no arguments, and every one of
   `server/hub.test.js`'s 35 checks still passes.

   *Amended 2026-08-02, after Wave 1.* The original wording was "passes **unchanged**", which
   turned out to be impossible: the suite hard-codes `proto: 1` in seven places
   (`hub.test.js:110,120,142,216,282,309,337`), so bumping `PROTOCOL` to 2 (§3.2) necessarily
   invalidates that fixture. The literals may be updated to `2` — the `proto: 99` mismatch case
   at `hub.test.js:134` stays — and **no assertion, expectation or scenario may change**.
   Separately, the suite's cap tests (`hub.test.js:288-291,320-328`) refuse a client that never
   sends hello, which §3.6 would otherwise break; see §3.6 for how both are satisfied at once.
7. The in-game host (`START > MMO > HOST GAME`) gets the same optional join code, so the two
   hosting paths stay interchangeable.
8. `modkit validate` / `lint` / `pack` stay green and `affects_link` stays `false`.

**Non-goals.** Accounts or persistent player identity. A lobby or server browser. Host
migration. Moderation tooling beyond ban/kick/allowlist. TLS on the game port (see §3.1).
Web admin UI. Windows service / systemd unit generation.

## 2. Context & constraints (grounded)

- **TLS is not achievable on the game port.** `Net:connectTCP` opens a plain `socket.tcp()`
  (`gen1recomp/src/link/Net.lua:173-181`); luasec/`ssl` exists nowhere in the engine tree and
  LÖVE 11.5 (`gen1recomp/conf.lua:52`) does not bundle it. Any confidentiality story has to
  come from outside the game socket.
- **`server/README.md:96-98` is factually wrong today.** It claims an ungreeted connection does
  not hold a player seat. `src/Hub.lua:102-128` does implement that (`MAX_PENDING=8`,
  `HELLO_TIMEOUT=10`), but `hub.js:369-389` registers the socket in `clients` before hello, so
  the cap check at `hub.js:369` counts silent sockets. Four of them lock out a 4-player hub for
  `TIMEOUT_MS = 45000` at a time (`hub.js:35,392`). This is a live bug, not a doc nit.
- **No per-IP or per-rate control exists.** `MAX_CLIENTS` (`hub.js:54-56`) is the only limit; one
  address can take every seat.
- **`send()` ignores backpressure.** `hub.js:130` calls `socket.write(line)` and discards the
  boolean, so a peer that never reads grows the hub's write buffer without bound.
- **`log()` interpolates attacker-controlled strings raw** (`hub.js:66`, called with
  `client.name` at `hub.js:254,433` and `err.message` at `hub.js:419`) — log injection and ANSI
  escapes reach the host's terminal.
- **Zero third-party dependencies is a repo convention** stated in three places (`hub.js:22`,
  `server/README.md:12`, `CLAUDE.md`). Everything this plan needs — `net`, `crypto`, `dgram`,
  `readline/promises`, `os`, `fs` — is Node core. **The convention holds.**
- **`server/` deliberately ships inside the packed mod archive** (`.modkitignore:21`), and
  `.modkitignore` matches **literal relative paths, not directory globs** (`.modkitignore:3-5`,
  `gen1recomp/tools/modkit.py:161-182`). `modkit pack` treats warnings as fatal
  (`modkit.py:1112-1116`).
- **`src/Hub.lua` is a line-for-line Lua twin of `hub.js`'s protocol handlers**
  (`hub.js:231-364` ↔ `Hub.lua:199-338`); `src/Config.lua` mirrors its constants. Protocol
  changes must land in both or the two hosting paths stop being interchangeable
  (`docs/plans/in-game-hosting.md:139-141`).
- **The client already renders `mmo.error` to the player** (`src/Client.lua:463-467` →
  `ui:say`), so refusals need no new client surface.
- **The client has no auto-reconnect** (`src/Transport.lua:163`); a dropped connection is a
  manual reconnect. Hardening must not cycle healthy connections.
- **Text entry exists and is constrained.** The mod's `ui.naming.grid` hook (`src/Ui.lua:43-67,
  211-226`) offers `A-Z`, `0-9`, space and `- ? ! , . : ; / ( )` — **no lowercase**. A join code
  must be uppercase alphanumeric with dashes. `Wire.text` strips outside
  `[A-Za-z0-9 .,!?'-:;()/]` (`src/Wire.lua:54`) and `Wire.id` caps at 40 chars
  (`src/Wire.lua:82-85`), so a 64-char hex digest needs a **new** sanitiser.
- **No crypto primitive exists in Lua.** `src/link/Fingerprint.lua:21-63` is FNV-1a and
  explicitly non-cryptographic. `love.data.hash("sha256", …)` works in-game but `love.data` is
  **not stubbed** in `tests/love_stub.lua`, which the mod's headless suite installs
  (`gen1recomp/tests/modkit/init.lua:21`). A pure-Lua SHA-256 is therefore required so the game
  and the suite run identical code.
- **Lua dialect is LuaJIT / 5.1**: no `//`, no `~`; bit work goes through `require("bit")`
  (`gen1recomp/src/core/ChipSynth.lua:177`) or arithmetic peeling (`Fingerprint.lua:36-46`).
- **`Json.lua` escapes only `["\\` and control chars** (`gen1recomp/src/link/Json.lua:15-23`), so
  lowercase hex round-trips byte-for-byte.
- **Test idiom is bespoke and dependency-free**: `server/hub.test.js` spawns the real process on
  a `process.pid`-derived port, waits for the `listening` stdout line, drives real sockets, and
  asserts through a throwing `ok()` (`hub.test.js:20,24-27,29-94`). New tests copy this exactly.
- **CI runs nothing but the release packer** (`.github/workflows/release.yml`) — no tests gate
  merges today.
- Node on this machine: `v23.5.0` on `PATH`; nvm has `v24.16.0` and `v22.x`. Node 24 is Active
  LTS as of Aug 2026, 22 is the oldest supported line, 20 and below are EOL.

## 3. Approach & key decisions

### 3.1 Security model: HMAC challenge–response over plaintext, and say so plainly

The hub sends a fresh random nonce; the client answers `HMAC-SHA256(joinCode, nonce)`. The
join code itself never crosses the wire.

*Alternatives considered.* A bare shared secret in `mmo.hello` — rejected: one packet capture
leaks it permanently, for the same UI cost. Nothing at all (network reachability as the only
gate) — rejected: it fails the stated requirement. IP allowlist as the primary gate — rejected:
friends on mobile/CGNAT have no stable address; kept as an optional extra layer.

*What this buys, exactly.* Internet scanners and anyone who finds the port cannot join. A
passive eavesdropper cannot recover the join code (HMAC is one-way) and cannot replay a captured
response (the nonce is per-connection, single-use). **What it does not buy:** confidentiality of
gameplay traffic, and no defence against an active MITM who proxies the whole session. Because
no TLS is possible on this client (§2), that gap is real and the docs will say it in those
words, alongside a short note that a WireGuard-style overlay is the only way to close it. This
is an honesty requirement, not a marketing one.

*Constant time.* Both sides compare digests with a constant-time byte compare —
`crypto.timingSafeEqual` on the Node side (length-checked first, it throws on mismatched
lengths), a hand-written accumulate-then-compare on the Lua side.

### 3.2 Handshake shape: hello first, challenge second — additive, no reordering

```
client → hub   mmo.hello   { proto: 2, name, sprite, profile, map, x, y, facing }
hub    → client mmo.challenge { nonce }          ← only when auth is required
client → hub   mmo.auth    { response }
hub    → client mmo.welcome { id, players[] }    ← or mmo.error, which the client already shows
```

Challenging *after* hello rather than on connect means `Transport`/`Client` keep their current
send-hello-immediately flow (`src/Client.lua:296-308`) and the hub knows the peer's protocol
before spending a nonce. When auth is not required the exchange is byte-identical to today.

`PROTOCOL` goes **1 → 2** in `src/Config.lua:11` and `server/hub.js`. The hub keeps its existing
exact-match refusal and its existing message, so an un-updated mod gets "This hub speaks protocol
2; your mod speaks 1." — a sentence the player already sees rendered.

### 3.3 Join codes: typeable on a Gen-1 naming grid

Alphabet is Crockford-style uppercase — `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, dropping `I L O U`
so nothing is mistyped from a screenshot. Four groups of four = **80 bits**, formatted
`ABCD-EFGH-JKMN-PQRS`. Every character is on the mod's existing naming grid, and the dash is on
both pages (`src/Ui.lua:51-64`) so no page-flip is needed mid-code.

Normalisation is symmetric and total: uppercase, strip everything outside the alphabet, then use
the resulting bytes as the HMAC key. A player who types it without dashes, or in lowercase from a
chat message, still gets in.

Credentials are a **list**, not a single secret: a primary code plus invite codes with optional
expiry and use-count. The hub tries each active credential against the response in constant time
and admits on the first match, so revoking one friend's invite does not rotate everyone's code.

### 3.4 Shape: extract a core, keep `hub.js` alive

```
server/
  hub.js                  thin back-compat entry — `node server/hub.js [port]` still works
  bin/rby-mmo-hub.js      the CLI: init, start, status, config, invite, revoke, ban, unban,
                          allow, doctor, upnp
  lib/relay.js            the protocol core, lifted out of hub.js unchanged in behaviour
  lib/sanitize.js         the sanitisers from hub.js:68-111 + new hex/code sanitisers
  lib/limits.js           per-IP caps, connect-rate bucket, handshake timer, slowloris sweep,
                          write-backpressure guard
  lib/auth.js             nonce issue, HMAC verify, credential list, join-code generate/format
  lib/config.js           schema, defaults, load/save (0600), precedence, validation
  lib/server.js           binds relay + limits + auth + config to a real net.Server
  lib/reachability.js     interface classification, share-this-address advice
  lib/upnp.js             opt-in SSDP + SOAP port mapping (default off)
  lib/log.js              levelled, injection-safe logging
  package.json            name/bin/engines/scripts — still zero dependencies
  Dockerfile  compose.yml  .dockerignore
```

`hub.js` becomes ~30 lines that call `lib/server.js` with config-from-env defaults and auth
off, which is exactly what it does today — so `hub.test.js` passes untouched and every existing
`RBY_MMO_*` env var keeps working.

### 3.5 Configuration: one file, one precedence order, everything reachable from the CLI

`config.json` (JSON — `JSON.parse` is core; YAML/TOML would be the repo's first dependency).
Default location `${RBY_MMO_CONFIG}` → `./config.json` next to the CLI → `/data/config.json` in
the container. Written `0600`; the CLI refuses to start if the file is group/world-readable.

Precedence, documented once and honoured everywhere: **CLI flag > `RBY_MMO_*` env var > config
file > built-in default.** This preserves `hub.js`'s existing env behaviour rather than
reordering it.

```json
{
  "version": 1,
  "listen":  { "host": "0.0.0.0", "port": 7788 },
  "maxPlayers": 4,
  "auth": {
    "required": true,
    "credentials": [
      { "id": "primary", "label": "Primary join code", "secret": "ABCD-EFGH-JKMN-PQRS",
        "createdAt": "2026-08-02T00:00:00.000Z", "expiresAt": null,
        "maxUses": null, "uses": 0, "revoked": false }
    ]
  },
  "limits": {
    "perIpConnections": 4, "connectBurst": 10, "connectPerMinute": 60,
    "handshakeTimeoutMs": 10000, "idleTimeoutMs": 45000, "maxPending": 8,
    "maxWriteBufferBytes": 262144, "chatIntervalMs": 500
  },
  "bans": [], "allowlist": [],
  "network": { "upnp": { "enabled": false, "leaseSeconds": 3600 } },
  "log": { "level": "info" }
}
```

Numeric knobs are clamped on load the way `clampPlayers` already clamps the cap
(`hub.js:48-52`): out-of-range is pulled to the nearest end and warned about, never obeyed.

### 3.6 The cap bug, fixed the way `Hub.lua` already does it

Seats are charged at **hello**, not at accept. Ungreeted sockets are bounded separately by
`limits.maxPending` and reaped by `limits.handshakeTimeoutMs`, mirroring `src/Hub.lua:42-46,
349-369`. This makes `server/README.md:96-98` true for the first time and brings `hub.js` up to
the Lua port's already-correct model rather than the reverse.

*Refined after Wave 1.* Charging at hello alone would break `hub.test.js:288-291,320-328`, which
connect an extra client and expect `mmo.error` **without** sending hello. Both goals hold if
`server.js` keeps a **courtesy refusal at accept, but only when `relay.isFull()` is already
true** — i.e. when the cap is filled by *greeted players*. Ungreeted sockets still never count
toward `playerCount`, so the lock-out this section exists to fix cannot happen; a connection
arriving at a genuinely full hub is simply told so immediately instead of after a timeout, which
is the better experience anyway.

### 3.7 UPnP: built, opt-in, off by default, and warned about

You selected automatic port forwarding after reading the risk note, so it ships — as
`rby-mmo-hub upnp enable`, never as a default and never silently. Zero-dependency: SSDP
`M-SEARCH` over `node:dgram` to `239.255.255.250:1900`, then a SOAP `AddPortMapping` over
`node:http` to the discovered control URL, with a lease so a stale mapping expires. Enabling it
prints, in full: most home routers accept these requests without authentication, so any device on
the network — including an untrusted IoT or guest device — can open ports too; the mapping is
removed on clean shutdown and `upnp disable` removes it explicitly. `doctor` uses the router's
own `GetExternalIPAddress` when UPnP is enabled, which keeps reachability reporting local — the
software makes **no third-party network calls, ever**.

### 3.8 Reachability: tell the host what to share

`start` and `doctor` classify every interface from `os.networkInterfaces()` — loopback, RFC1918
private, `100.64.0.0/10` (CGNAT / Tailscale-shaped), and public — and print the address to hand
out, or say plainly that friends outside the network will not reach this port and name the three
ways to fix it (forward the port, run on a box with a public address, or use an overlay network).
No phone-home, no port-check service.

### 3.9 Lua side: one new pure-Lua module, mirrored vocabulary

`src/Sha256.lua` implements SHA-256, HMAC-SHA256, hex encoding and a constant-time compare in
pure Lua. It prefers `require("bit")` when present and falls back to arithmetic bit-peeling in
the style of `Fingerprint.lua:36-46`, so it runs under LuaJIT in-game, under LuaJIT in the mod's
suite, and under plain 5.4 if anything ever loads it there. It is pinned by RFC 6234 / RFC 4231
test vectors so a drift against Node's `crypto` is caught immediately.

The in-game host gets the same feature: an optional join code on the HOST screen, defaulting to
off (a LAN game between people in the same room should not need one) but generated and displayed
with one keypress.

## 4. Work breakdown — implementation tasks

### Wave 1 — foundations (5 tasks, fully independent)

| ID | Goal | Owns (exclusive) | Acceptance |
| --- | --- | --- | --- |
| **T1** | Lift the relay protocol core out of `hub.js` into a socket-agnostic module, behaviour-identical, plus injection-safe logging and the sanitiser set. | `server/lib/relay.js`, `server/lib/sanitize.js`, `server/lib/log.js` | `relay.js` exports a `Relay` class driven by peer handles (`send`/`close`), never touching `net` directly — same split `src/Hub.lua` uses. All eight `mmo.*` handlers behave exactly as `hub.js:231-364`. `log.js` escapes and truncates every interpolated value. |
| **T2** | Connection-level limits as a standalone, testable module. | `server/lib/limits.js` | Per-IP connection counter; token-bucket connect-rate limiter; pending-connection cap; handshake timer; slowloris sweep (buffer non-empty and no completed line within N ms); write-backpressure guard keyed on `socket.writableLength`. Pure logic + injected clock, so it is unit-testable without sockets. |
| **T3** | Config schema and the auth primitives. | `server/lib/config.js`, `server/lib/auth.js` | `config.js`: defaults, clamped load, `0600` save, permission check, precedence merge (flag > env > file > default), migration hook on `version`. `auth.js`: `generateJoinCode()`, `normalizeCode()`, `issueNonce()`, `verify(response, nonce, credentials)` using `crypto.randomBytes` + `crypto.timingSafeEqual`, credential expiry/use-count/revocation. |
| **T4** | Pure-Lua SHA-256 + HMAC. | `src/Sha256.lua` | `Sha256.hex(msg)`, `Sha256.hmacHex(key, msg)`, `Sha256.equals(a, b)` (constant time). Works under `luajit` with and without `bit`. Matches RFC 4231 vectors and Node's `crypto` byte-for-byte. No `love.*` reference anywhere. |
| **T5** | Protocol vocabulary and constants, both sides' shared truth. | `src/Wire.lua`, `src/Config.lua` | `PROTOCOL = 2`. New message types `CHALLENGE`/`AUTH`. New sanitisers `Wire.hex(v, max)` and `Wire.code(v)` (uppercase alnum + dash, ≤32). New constants for handshake timeout, max pending, join-code alphabet/format. Existing sanitisers untouched. |

### Wave 2 — the application (4 tasks, independent of each other)

| ID | Goal | Owns (exclusive) | Acceptance |
| --- | --- | --- | --- |
| **T6** | The CLI — the one place a host configures anything. | `server/bin/rby-mmo-hub.js`, `server/lib/cli.js`, `server/lib/reachability.js`, `server/lib/upnp.js` | Verbs: `init` (wizard via `node:readline/promises`), `start`, `status`, `config get|set|list`, `invite`, `revoke`, `ban`/`unban`/`allow`, `doctor`, `upnp enable|disable|status`, `--help`/`--version`. Every config key in §3.5 settable. Secrets printed once, never logged. Exit codes: 0 ok, 1 error, 2 usage. |
| **T7** | Bind the pieces to a real server, and keep `hub.js` working. | `server/hub.js`, `server/lib/server.js` | `server.js` wires relay + limits + auth + config onto `net.createServer`, sets `server.maxConnections`, charges seats at hello (§3.6), handles `SIGINT`/`SIGTERM` by refusing new connections then draining, and guards `uncaughtException`/`unhandledRejection` by logging and continuing. `hub.js` is a shim: `node server/hub.js`, `node server/hub.js 9000` and `RBY_MMO_MAX=8 node server/hub.js` behave as before, auth off. **`server/hub.test.js` passes unmodified.** |
| **T8** | Client-side auth and the join-code UI. | `src/Client.lua`, `src/Transport.lua`, `src/Ui.lua` | Handles `mmo.challenge` by computing `Sha256.hmacHex(normalizedCode, nonce)` and replying `mmo.auth`. Join code stored per-hub via `mod.save`, entered on a naming screen using the mod's own grid, offered automatically when a hub challenges and no code is stored. `mmo.error` on a bad code shows the hub's sentence. No `error()`/`assert()` in callbacks — `mod.log:warn` with a remediation, per the loader rule. |
| **T9** | The in-game host gets the same optional join code. | `src/Hub.lua`, `src/HostServer.lua` | `Hub` issues challenges when a code is configured, verifies with `Sha256`, and stays byte-compatible with `server/lib/relay.js`. Default off. Existing `MAX_PENDING`/`HELLO_TIMEOUT` behaviour preserved. |

### Wave 3 — packaging and documentation (2 tasks)

| ID | Goal | Owns (exclusive) | Acceptance |
| --- | --- | --- | --- |
| **T10** | Docker as a first-class path, and packaging hygiene. | `server/Dockerfile`, `server/compose.yml`, `server/.dockerignore`, `server/package.json`, `.modkitignore` | `node:24-alpine`, non-root UID `10001`, `tini`/`init: true`, `read_only: true`, `tmpfs: [/tmp]`, `cap_drop: [ALL]`, named volume at `/data`, TCP `HEALTHCHECK` using Node's own `net` (no `curl`/`nc` in the image). `package.json` declares `bin`, `engines: ">=22"`, `scripts.test`, and **no dependencies**. `.modkitignore` updated by literal path for anything that must not ship. |
| **T11** | Documentation that matches reality. | `server/README.md`, `README.md`, `CHANGELOG.md`, `manifest.json` | `server/README.md` rewritten: quick start, CLI reference, config table, the corrected security posture (§3.1 wording, including what HMAC does *not* protect), connectivity guide, Docker. Root `README.md` cross-links it. `CHANGELOG.md` gets an `### Added`/`### Changed`/`### Fixed` entry naming the protocol bump and the cap fix; `manifest.json` version bumped to match. |

## 5. Work breakdown — test tasks

| ID | Covers | Owns (exclusive) |
| --- | --- | --- |
| **X1** | `auth.js` + `config.js`: code generation entropy/alphabet, normalisation round-trip, HMAC verify against known vectors, expiry/use-count/revocation, constant-time path, config precedence, clamping, `0600` enforcement, migration. | `server/auth.test.js`, `server/config.test.js` |
| **X2** | `limits.js`: per-IP cap, token-bucket refill, pending cap, handshake timeout, slowloris sweep, backpressure — all against an injected clock. | `server/limits.test.js` |
| **X3** | End-to-end over real sockets: challenge/response happy path, wrong code refused with `mmo.error`, replayed nonce refused, ungreeted sockets cannot consume seats (the §3.6 regression), per-IP cap, ban enforcement, graceful shutdown. | `server/server.test.js` |
| **X4** | CLI: `init` non-interactively (`--yes` + flags), `config set/get` round-trip, `invite`/`revoke`, `ban`/`unban`, `doctor` output shape, exit codes, `--help`. | `server/cli.test.js` |
| **X5** | Lua: SHA-256/HMAC RFC vectors, cross-check against fixtures generated from Node's `crypto`; `Wire.hex`/`Wire.code` sanitisers; `Hub.lua` challenge/verify/refuse; join-code normalisation parity with `auth.js`. | `tests/rby_mmo_test.lua` (extend), `tests/fixtures/hmac_vectors.lua` (new) |

Test-task file ownership is disjoint; X5 is the only one that edits an existing file.

## 6. Execution waves

```
Wave 1  T1  T2  T3  T4  T5          ── barrier ──
Wave 2  T6  T7  T8  T9              ── barrier ──
Wave 3  T10 T11                     ── barrier ──
Review  Phase 5 over git diff 5ef7d6b...HEAD
Wave 4  X1  X2  X3  X4  X5          (tests)
Run     X-suite + luajit suite + modkit validate/lint/pack
```

Every task inside a wave owns a disjoint file set; the cross-wave dependencies are
T6/T7 → T1–T3, T8/T9 → T4–T5, T10/T11 → everything. All runners are in-tree Claude agents, so
no worktree isolation is needed.

## 7. Blast radius & risks

- **Protocol bump is a compatibility event.** An un-updated mod cannot join an updated hub and
  vice versa. Mitigated by the existing, already-rendered refusal sentence and a `CHANGELOG`
  entry; both halves ship together.
- **`src/Hub.lua` ↔ `server/lib/relay.js` drift** is the standing hazard in this repo. T9 and T1
  are written against the same §3.2 handshake spec, and X5 asserts the Lua side against fixtures
  generated from the Node side.
- **A pure-Lua SHA-256 that disagrees with Node's** would fail auth silently and look like a
  wrong join code. X5's cross-fixtures exist precisely to catch that before a player does.
- **Over-tight limits could disconnect real players**, and the client has no auto-reconnect
  (`src/Transport.lua:163`). Defaults are deliberately generous (4 connections/IP, 10-burst,
  10 s handshake) and every one is tunable from the CLI.
- **UPnP is the largest deliberate risk in this plan.** Off by default, explicit verb to enable,
  full warning at enable time, leased mapping, removed on shutdown.
- **`modkit pack` treats warnings as fatal** and `server/` ships in the archive. T10 verifies
  pack stays green rather than assuming it.
- **Rollback** is a plain revert of the branch; nothing outside this repo changes state, and the
  config file is created only by an explicit `init`.

## 8. Open questions / assumptions

1. **Tailscale/WireGuard was not selected as the documented primary path**, so the connectivity
   docs lead with port forwarding, a VPS, and UPnP. Because §3.1 leaves an honest MITM gap that
   only an overlay network closes, the security section will still name overlay networks in one
   sentence as the way to close it. Assumption: documenting the gap is wanted even though it is
   not the headline recommendation.
2. **`PROTOCOL` bumps to 2 with exact-match refusal** rather than a compatibility window.
   Assumption: mod and hub ship as a unit, so a version window buys nothing.
3. **The in-game host's join code defaults to off.** Assumption: two people on the same couch or
   LAN should not be forced through a code, while a dedicated hub — which is exposed to the
   internet — defaults it on.
4. **`server/package.json` lives in `server/`, not the repo root**, so the mod root stays a mod.
   Assumption: no one expects `npm install` at the repo root.
5. **Node floor is `>=22`**, built and tested on 24. The machine's `PATH` node is 23.5.0, which
   satisfies it.
6. **No third-party network calls, ever** — reachability is derived from local interfaces and,
   when UPnP is on, from the router itself. Assumption: a self-check that phones home would be
   unwelcome in software whose selling point is safety.
