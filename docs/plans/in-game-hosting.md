> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — In-game hosting with a host-chosen player limit

| Field | Value |
| --- | --- |
| Date | 2026-08-01 |
| Source | `/implement` — "the hub happening inside the game mods… player can decide to start a server during the game… when hosting, through the commands in game, they decide it" |
| Config | none — `AGENTS_CONFIG.yml` absent; built inline (see §3.4) |
| Branch | `main` — no branch cut |
| Base SHA | none — the repo has no commits yet |
| Status | Delivered. All tiers green; see §9. |

## 1. Objective & success criteria

A player with the mod enabled can **host a game from inside the game** and set the
player limit while doing it, or **join** someone else's. No terminal, no Node, no
separate process.

Done when:

1. `START > MMO` offers **HOST GAME** and **JOIN GAME** while offline.
2. Choosing HOST asks for a max-player count (2–64, default 4), starts a listener,
   and shows the address to share plus a live player count.
3. The host is a normal player in their own world — same avatars, chat, trade and
   battle as everyone else.
4. Another copy of the game joins by address and everything already shipped keeps
   working (presence, scoped chat, trade, battle).
5. The limit the host picked is enforced; the player over the cap is refused with a
   message naming the limit.
6. `server/hub.js` still works, unchanged in protocol, for a dedicated 24/7 hub.

Non-goals: NAT traversal / hole-punching, a lobby or server browser, accounts or
bans, host migration when the host quits, persistence across sessions.

## 2. Context & constraints (grounded)

- **The engine's `Net` is single-peer by construction.** `src/link/Net.lua:118`
  creates its ENet host with a peer count of `2`, and the object holds exactly one
  `self.peer`. It cannot be reused as an N-player server; only its *client* side
  (`connectTCP`, framing, pump) is reusable — which is what `src/Transport.lua`
  already uses.
- **luasocket is available and already used.** `src/link/Net.lua:173` does
  `socket.tcp()`; `require("socket")` succeeds inside LÖVE. `socket.bind` +
  `:settimeout(0)` + `:accept()` gives a non-blocking TCP listener with no new
  dependency.
- **Mods cannot add dev-console verbs.** `src/dev/Console.lua:273` dispatches from
  a closed local `VERBS` table, and `mod.commands:register` targets the *map-script*
  command registry (`src/mods/Schemas.lua:1124`, backed by `src.script.Commands`),
  not the console. Dev mode is also off for ordinary players. So the host's controls
  must live in the MMO menu, not in console commands.
- **`input.step` ticks inside `Game:update`** (`src/core/Game.lua:179`), before
  button edges are promoted — so a server pumped from it keeps running while the
  host is in a menu or a battle, which a host's server must.
- **The mod option system supports what we need.** `number` rows honour
  `min`/`max`/`step` and open a `QuantityBox` for direct entry
  (`src/mods/ManagerState.lua:866-889`), so a 2–64 limit is enforced by the row
  itself as well as in code.
- **The protocol already exists and is tested.** `server/hub.js` is the reference
  implementation; `server/hub.test.js` (35 checks) pins its behaviour. Whatever runs
  in-game must speak exactly the same `mmo.*` vocabulary so the two are
  interchangeable.

## 3. Approach & key decisions

### 3.1 One wire: TCP

The in-game host binds a **TCP** listener and speaks the same newline-delimited JSON
`hub.js` speaks.

*Alternative considered:* ENet, which is natively multi-peer
(`enet.host_create(addr, N, 1)`) and is the engine's own host path. Rejected because
it would fork the client into two join paths (ENet for in-game hosts, TCP for
`hub.js`) and strand the Node hub and its test suite on a dialect nothing else
speaks. With TCP, `Transport` is untouched on the joining side and the two server
implementations are drop-in equivalents.

*Accepted cost:* TCP head-of-line blocking. Acceptable — this traffic is presence
ticks, chat, and turn-based trade/battle, which is exactly what `hub.js` already
carries fine.

### 3.2 Split the hub into logic and socket

- **`src/Hub.lua` — pure protocol logic, no sockets.** Owns the client table,
  roster, chat scope routing, request/respond, sessions, relay, and the cap. Talks to
  *peer handles* that answer `:send(msg)` / `:close()`. This is a Lua port of
  `hub.js`'s handler layer.
- **`src/HostServer.lua` — the luasocket binding.** bind / accept / per-connection
  line buffering / disconnect detection, feeding `Hub`.

The split is what makes this testable: `Hub` runs headlessly under plain luajit with
fake peers, so the cap, the scope routing and the session pairing are pinned by tests
even though no socket exists in CI. It also keeps the one piece most likely to drift
from `hub.js` isolated and directly comparable.

### 3.3 The host plays too, over loopback

The host's own client attaches to its `Hub` **in-process**, with no socket. There is
precedent in the engine: `Net.loopbackPair()` exists for exactly this shape.
`Transport` already has an `:attach()` seam (added for tests) — the loopback peer
reuses it rather than growing a third code path.

*Alternative considered:* the host's client connecting to `127.0.0.1`. Rejected —
it burns a connection slot against the player's own cap and can fail on hosts with
odd loopback rules, for no benefit.

### 3.4 No agent fan-out

Built inline, sequentially. The work is a dependency chain — `Hub` ← `HostServer` ←
`Client` ← `Ui` — with almost nothing genuinely disjoint, which is the case
`/implement`'s own sizing guidance says not to force into parallel waves. Splitting
it across agents would mean each rediscovering context this session already holds,
at ~10–15× the tokens, for work that cannot run concurrently anyway.

## 4. Work breakdown — implementation

| ID | Goal | Owns | Depends on |
| --- | --- | --- | --- |
| I1 | Constants: limit bounds (2–64), default 4, default port, host/join defaults | `src/Config.lua` | — |
| I2 | `Hub` — pure protocol logic with peer handles, cap enforcement, scope routing, sessions, relay | `src/Hub.lua` (new) | I1 |
| I3 | `HostServer` — luasocket listener, accept loop, line framing, disconnects | `src/HostServer.lua` (new) | I1, I2 |
| I4 | Loopback attach so the host is a player on its own hub | `src/Transport.lua` | I2 |
| I5 | Wiring: `host()` / `stopHosting()`, tick the server, new options, exports | `src/Client.lua` | I2, I3, I4 |
| I6 | Menus: HOST / JOIN while offline; limit entry; hosting status + STOP HOSTING | `src/Ui.lua` | I5 |
| I7 | Node hub keeps parity: cap ceiling 64, message names the limit | `server/hub.js`, `server/README.md` | I1 |
| I8 | Docs: README, mod.card, CHANGELOG | `README.md`, `mod.card`, `CHANGELOG.md` | I1–I7 |

**Acceptance per task:** the file loads (`luajit -bl`), `modkit validate` stays green,
and the mod suite still passes.

## 5. Work breakdown — tests

| ID | Covers | Owns |
| --- | --- | --- |
| T1 | `Hub`: cap at the host's chosen limit, refusal names it, freed seat reopens, join/part, roster | `tests/rby_mmo_test.lua` |
| T2 | `Hub`: chat scope routing (global / local radius / private), flood gate | `tests/rby_mmo_test.lua` |
| T3 | `Hub`: request → respond → session roles, relay only within a session, teardown | `tests/rby_mmo_test.lua` |
| T4 | Loopback: the host is a player on its own hub and counts against the cap | `tests/rby_mmo_test.lua` |
| T5 | Existing: the mod still loads clean and installs its seams; link surface unchanged | `tests/rby_mmo_test.lua` |

`server/hub.test.js` stays as-is — it pins the Node implementation, which is now the
*second* implementation of the protocol and worth keeping honest.

## 6. Execution waves

Sequential, checkpointed: **I1 → I2 → I3+I4 → I5 → I6 → I7+I8 → T1–T5 → run.**
Verification after each: `luajit -bl` on changed Lua, then `modkit validate` and the
suite at the end of each wave.

## 7. Blast radius & risks

- **`Transport` is shared by joining and hosting.** The loopback path must not change
  behaviour for the TCP path; the existing transport tests guard this.
- **A server inside the game loop.** Accept/read for ≤64 sockets per tick is trivial
  at this traffic volume, but a blocking call would freeze the game — every socket
  call must be `settimeout(0)` and every one is wrapped so a socket error disconnects
  that peer instead of propagating into `input.step`.
- **Two implementations of one protocol** (`Hub.lua`, `hub.js`) can drift. Mitigated
  by both being pinned by test suites asserting the same behaviours; noted in
  `mod.card` as a maintenance cost.
- **No NAT traversal.** A host behind a router needs a forwarded port. This is a real
  usability limit and goes in the README rather than being hidden.
- **Rollback:** the feature is additive — JOIN via the `HUB` option and `hub.js` both
  keep working, so reverting the host path leaves the shipped 0.1.0 behaviour intact.

## 8. Open questions / assumptions

Assumptions made rather than asked, all cheap to reverse:

1. **`server/hub.js` is kept**, not deleted. It is the same protocol, already tested,
   and a dedicated always-on hub is a genuinely different use case from a player
   hosting during a session.
2. **Limit range 2–64, default 4.** 2 because a one-player multiplayer session is not
   a thing; 64 is the ceiling the request named.
3. **"Through the commands" = the in-game MMO menu**, not dev-console verbs — mods
   provably cannot register console verbs (§2), so this is settled by the engine.
4. **The host occupies a slot.** A limit of 4 means the host plus three friends.
5. **No host migration.** If the host stops, the session ends for everyone; clients
   are told rather than left hanging.
6. **Port fixed at 7788.** Planned as an option, then dropped: see §9.

## 9. What changed during the build

Three things the plan did not anticipate, all found by reading the engine
before writing against it.

- **The naming grid has no digits.** `src/ui/NamingScreen.lua:28-43` carries
  letters, space and punctuation only, so `192.168.1.20:7788` was literally
  untypeable — meaning the `HUB` option shipped in 0.1.0 could never have
  been edited by a player. Fixed by wrapping `ui.naming.grid` with a digits
  page, scoped by screen title so every other naming screen is untouched.
- **`mod.options` is read-only to mods.** The loader exposes `define` and
  `get` and nothing else (`src/mods/Loader.lua`), so the planned "write the
  chosen limit back to the option" was impossible. The option row is now the
  persisted *default*; an in-game change goes to `mod.save`, which mods may
  write. This is also why the port was dropped rather than exposed:
  `QuantityBox` steps by 1 with rollover, which is unusable for a 5-digit
  port, and a field nobody can set is worse than a documented constant.
- **A colon-call bug in the setters**, caught in review: `Ui` calls
  `client:setMaxPlayers(n)`, which lands the module table in the value slot;
  `clampPlayers` then turned it into the default, silently discarding the
  host's choice with no error. Fixed with the existing `arg1` shift (which
  had to move above its users to stop resolving as a nil global) and pinned
  by a regression test verified to fail against the old code.
