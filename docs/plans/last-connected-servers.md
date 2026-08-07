# Plan — Last Connected Servers (recents + favorites on the MMO menu)

| Field | Value |
| --- | --- |
| Date | 2026-08-06 |
| Source | /implement request (conversation) |
| Config | AGENTS_CONFIG.yml (quality preset) |
| Branch | feature/last-connected-servers |
| Base SHA | b737dfd6407076b91f3d243e18b1f7b8cfd135ad |
| Mode | Autonomous — grill and plan-approval gates bypassed; every assumption is logged in §8 |

## 1. Objective & success criteria

When the player is **not** connected, the MMO menu offers a `SERVERS` row listing every hub
they have successfully connected to before — favorites pinned on top, each group sorted by
address descending. Choosing an entry opens a submenu: `CONNECT`, `FAVORITE`/`UNFAVORITE`,
`EDIT HOST`, `EDIT CODE`, `RENAME`. A new connection records its entry automatically,
default-named by its host address; the name is renameable. The list survives quit/relaunch
and save-slot changes.

Done means: headless suite green (incl. new sections), modkit validate/lint/pack clean,
link surface still byte-identical (`affects_link=false` untouched), and a full
`run-mmo-e2e.sh` pass including a new recents-reconnect leg.

## 2. Context & constraints (grounded findings)

- Disconnected MMO menu = `SCREEN.MAIN`, `src/Ui.lua:727-874`; bordered `mod.ui.Menu`
  (items `{ label, onSelect }`), max 8 visible rows; cursor memory in `cursor.main`
  (`src/Ui.lua:85, 866-872`). HOST GAME / JOIN GAME rows at `src/Ui.lua:831-848`, each
  pushes `SCREEN.CHARSET` first.
- Per-entry submenu precedent: `SCREEN.ACTIONS` (`src/Ui.lua:1493-1592`) — conditional
  `Menu` reached from `SCREEN.ROSTER`'s `onChoose` (`src/Ui.lua:1477-1486`); dynamic
  `ty = math.max(0, math.min(7, 18 - (#items*2+2)))`.
- Scrollable list precedent: `SCREEN.ROSTER` (`src/Ui.lua:1450-1489`) — `mod.ui.ListMenu`
  rows `{ label, right, value }`, `opts.onChoose(item)`.
- Text entry: `namingScreen(game, opts)` wrapper (`src/Ui.lua:211-239`), `opts =
  { title, maxLen, default, onDone }`. New grids must claim their title via `ownTitle(...)`
  (`src/Ui.lua:637-651`) for the digits page + field repaint, use `escapable(...)`
  (`src/Ui.lua:1159-1212`) and `seed(...)` (`src/Ui.lua:1221-1235`).
- Connect flow: `SCREEN.JOINADDR` → `client:setJoinAddress` (`src/Client.lua:186-191`,
  `withPort` normalization at 172-176) → `SCREEN.JOINCODE{connect=true}` →
  `client:setJoinCode` (`src/Client.lua:224-232`, key `"code:"..addr:lower()`, whitespace
  stripped) → `client:connect(game)` (`src/Client.lua:782-801`). Connection is only real at
  `handlers[Wire.WELCOME]` (`src/Client.lua:1093-1133`), where `transport:markReady()`
  fires; upvalue `dialled` (`src/Client.lua:108, 797`) holds the exact `ip:port`, and is
  nil for self-hosted loopback — **the recording hook is WELCOME, gated `dialled ~= nil`**.
- Persistence: `mod.save` is per-save-slot and lost on CONTINUE (`src/Client.lua:260-279`).
  Durable pattern = dual-write with a JSON file via `love.filesystem` + `src.link.Json`,
  file wins on read, never destructively overwrite an unreadable file, headless-guarded by
  `type(love) ~= "table"` (`src/Client.lua:280-413`, `Config.RANK_TOKEN_FILE`).
- Sanitisers: `Wire.text(value, limit)` (`src/Wire.lua:186-192`), `Wire.code(value)`
  (`src/Wire.lua:253-264`, exactly 6 chars of `Config.CODE_ALPHABET` or nil).
  `Config.CODE_ENTRY_MAX = 12` is the grid cap.
- Tests: Tier-1 asserts every screen id registers (`tests/rby_mmo_test.lua:114-124`);
  Tier-2 drives modules against `stubMod` (save/options/events stubs at `:263-330`); the
  screen-driving pattern (register-stub + `def.new({}, opts)` → inspect `.items`) is at
  `:5080-5119`. Stubbed fields must be restored, never nil'd (fleet memory).
  E2e drivers select rows by exact label (`tests/drivers/mmo_util.lua:103-136`), type on
  grids (`:377-499`), and already drive START→MMO→JOIN GAME (`M.rejoin`, `:1317-1345`).
- Conventions (git history): version bump per landed commit → next is **0.8.0**;
  CHANGELOG heading must match; Ui + Client change together; tests and e2e grow in the
  same commit; plan doc listed in `.modkitignore`.

## 3. Approach & key decisions

- **New `src/Servers.lua` store module** (mirrors Roster/Chat module shape), constructed by
  Client, exposed to Ui via ctx. Chosen over inlining in Client to keep Client.lua's already
  large surface stable and the store unit-testable in isolation.
- **Dual-write persistence** (mod.save mirror + `rby_mmo_servers.json`, file wins) — the
  request says entries persist across "connections/sessions"; a server list is machine-level
  state, and the rank-token pattern is the house answer. Decision rests on codebase evidence,
  not spike (no spike needed — pattern already proven in-tree).
- **List lives one level down** (`SERVERS` row → ListMenu screen), not inline in MAIN —
  MAIN's Menu shares an 8-row budget and the list is variable-length.
- **Codes ride on the entry** (so they survive save-slot changes) and are written through
  `client:setJoinCode` on CONNECT so the existing challenge/re-ask path is untouched.
- **Recording only at WELCOME** — recording in `connect()` would log failed/refused dials.
- Sorting is pure-Lua string compare, exported as a pure helper for direct unit pinning
  (house style: `Ui.markedRows` precedent).

## 4. Work breakdown — implementation (Wave 1, parallel, opus)

### API contract (both tasks build to this — do not deviate)

`Servers.new(ctx)` → store; `ctx = { mod = <mod facade> }`. Entry shape:
`{ key, address, name, fav, code, last }`; `key = address:lower():gsub("%s+","")` after
`withPort`-style normalization; `name` defaults to the normalized address; `last` = epoch
seconds. Store API (all mutators persist immediately and return the entry, or nil+no-op on
bad input; every refusal logs `mod.log:warn` with a remediation — never bare error/assert):

- `store:list()` → sorted array: favorites first; within each group address DESC
  (lexicographic on `key`).
- `store:get(key)` → entry | nil
- `store:record(address, code)` → entry — create or refresh (existing name/fav kept;
  `last` updated; `code` updated when non-nil). Evict least-recently-connected non-favorite
  beyond `Config.SERVER_LIST_MAX`; favorites never evicted.
- `store:rename(key, name)` — `Wire.text(name, Config.SERVER_NAME_MAX)`; empty result → nil.
- `store:setFavorite(key, fav)`
- `store:setAddress(key, newAddress)` — normalize + re-key; keeps name/fav/code/last; if an
  entry already sits at the new key it is replaced by this one.
- `store:setCode(key, code)` — `Wire.code`-validated; invalid → nil.

New Config constants: `SERVER_NAME_MAX = 16`, `SERVER_LIST_MAX = 16`,
`SERVERS_FILE = "rby_mmo_servers.json"` (each with a one-line why, house style).

### T1 — store + client wiring (owns: `src/Servers.lua` [new], `src/Config.lua`, `src/Client.lua`)
Implement the store with dual-write persistence copied from the rank-token pattern
(headless-safe `type(love) ~= "table"` guard → mod.save only). Wire into Client:
construct in install, expose on the ctx handed to Ui and via `M.servers()` accessor;
in `handlers[Wire.WELCOME]`, when `dialled ~= nil`, call
`servers:record(dialled, M.joinCode(dialled))`. Acceptance: store round-trips through
stub save; WELCOME on a dialled connection records; self-host records nothing.

### T2 — screens (owns: `src/Ui.lua`)
- `SCREEN.SERVERS`: ListMenu titled `SERVERS`, rows from `ctx.servers:list()` —
  `label = entry.name`, `right` = favorite marker (`*`) for favorites, `value = entry.key`;
  `onChoose` pushes `SCREEN.SERVERACT { key = ... }`; rebuild rows on re-entry.
- `SCREEN.SERVERACT`: Menu with `CONNECT`, `FAVORITE`/`UNFAVORITE` (state-dependent label,
  `END GAME`/`LEAVE` precedent), `EDIT HOST`, `EDIT CODE`, `RENAME`; dynamic ty like
  ACTIONS. CONNECT mirrors JOIN GAME: push `SCREEN.CHARSET` continuing into
  `client:setJoinAddress(entry.address)`, `client:setJoinCode(entry.address, entry.code)`
  when a code is stored, then `client:connect(game)` — read JOIN GAME's exact CHARSET
  chaining at `src/Ui.lua:840-848` and reproduce it.
- `SCREEN.SERVEREDIT`: one naming-grid screen parameterized by `opts.field`
  (`host` | `code` | `name`), titles `EDIT HOST` / `EDIT CODE` / `RENAME` (each through
  `ownTitle`), `escapable`, seeded with the current value; maxLen: host = JOINADDR's cap,
  code = `Config.CODE_ENTRY_MAX`, name = `Config.SERVER_NAME_MAX`. On done: call the
  matching store mutator; a refused value re-seeds the grid (JOINCODE precedent).
- `SCREEN.MAIN`: insert `SERVERS` row (between JOIN GAME and the trailing rows) only when
  disconnected/not hosting **and** `ctx.servers:list()` is non-empty.
- Use `ctx.servers` exactly per the contract; do not touch `src/Client.lua` (T1 owns it).
Acceptance: all three new screens register; MAIN row conditional; labels ALL CAPS.

## 5. Work breakdown — tests (Wave 2, parallel, sonnet)

### T3 — headless suite (owns: `tests/rby_mmo_test.lua`)
Tier-1: add the three new screen ids to the existence list. Tier-2 sections: store CRUD +
sort order (favorites first, address DESC) + eviction cap + name sanitisation + code
validation + re-key collision; WELCOME recording gated on dialled (drive Client with stub
transport as existing sections do); SCREEN.MAIN row presence/absence; SERVERACT items incl.
FAVORITE/UNFAVORITE label flip (screen-driving stub pattern `:5080-5119`; restore every
swapped stubMod field).

### T4 — e2e driver leg (owns: `tests/drivers/mmo_join.lua`, `tests/drivers/mmo_util.lua`, `tests/drivers/mmo_guest.lua` as needed)
After an existing join/leave cycle, add a recents leg: reopen MMO → `SERVERS` → select the
recorded entry (label = its address) → `CONNECT` → assert reconnected (reuse `M.rejoin`'s
assertions). Sample baselines before signaling barriers; absolute assertions (fleet memory).

### T5 — docs/version (owns: `manifest.json`, `CHANGELOG.md`, `README.md`, `mod.card`, `.modkitignore`)
Bump to 0.8.0 + matching CHANGELOG section; README/mod.card blurb for the SERVERS menu;
add `docs/plans/last-connected-servers.md` to `.modkitignore`'s plans block.

E2e **applies** (user-visible menu flow over real sockets). Run recipe: private engine view
(symlink farm in scratchpad; never repoint the shared `mods/rby_mmo` symlink), `export
PATH="/opt/homebrew/bin:$PATH"`, copy `.env` from `~/Projects/alamops/RBYMMOMod/.env`,
`SHOT_DIR` moved into scratchpad; suite = `luajit mods/rby_mmo/tests/rby_mmo_test.lua`;
e2e = `bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh` — e2e runs from the orchestrator's
main session (subagent background e2e gets reaped).

## 6. Execution waves

1. Wave 1: T1 ∥ T2 (disjoint files; shared API pinned in §4). Barrier: orchestrator
   integration check + suite smoke, checkpoint commit.
2. Phase 5: code review of full diff (opus). Must-fixes queue for Phase 8.
3. Wave 2: T3 ∥ T4 ∥ T5 (disjoint files). Checkpoint commit.
4. Phase 7: headless suite + modkit via haiku agent (private view); e2e by orchestrator.
5. Phase 8: fix loop to green (max 3 rounds).

## 7. Blast radius & risks

- `SCREEN.MAIN` row list changes → suite assertions on MAIN row counts may need updating;
  e2e `selectLabel` flows must still find HOST/JOIN rows.
- `Wire.WELCOME` handler is hot path for every connect — recording must never throw
  (store mutators log-and-refuse; loader skips throwing listeners but that's a bug, not a
  net).
- New JSON file in save dir — must degrade headless (`type(love)` guard) and never
  destructively overwrite an unreadable file.
- `affects_link` stays `false`; none of the link registries are touched; fingerprint
  neutrality assertion must stay green.
- Screenshots: MAIN gains a row only when recents exist, and docs screenshots are taken on
  fresh profiles — check during T5; regenerate from the e2e run if any shot goes stale.

## 9. Addendum (2026-08-06, follow-up request): DELETE with confirmation

Owner asked for a DELETE row, last on the per-entry submenu, behind a Yes/No
confirmation. Base for this increment: 8052c96.

- `src/Servers.lua`: public `remove(key)` — entry or nil+warn; deletes the row,
  marks `dropped[key]` so `_persist`'s file fold-in cannot resurrect it, persists.
- `src/Ui.lua` SERVERACT: `DELETE` appended after RENAME (6 rows now); pushes the
  existing `SCREEN.CONFIRM` (`M:confirm`, src/Ui.lua:585 — B is a no) asking about
  the entry by name; yes → `store:remove` then back to SCREEN.SERVERS; no →
  re-push SERVERACT with the cursor on DELETE (row-carry precedent).
- Decisions (corrected after review): the confirm box must OPEN ON NO — the engine
  ChoiceBox defaults its cursor to YES unless `defaultNo` is passed, so `M:confirm`
  gains an opts pass-through and the DELETE caller sets `defaultNo = true` (B is
  also a no; both mis-presses are now free). Favorites deletable (the confirm is
  the guard). DELETE clears the hub's stored join code via a small
  `Client.forgetHub(address)` (`code:` key — the button says "Forget" and the
  passcode is the hub's secret) but KEEPS the rank claim ticket: that is the
  player's own earned identity, clearing it would silently destroy their rating on
  a future rejoin, and it also lives in the durable token file. Post-delete lands
  on the list (empty list → widget empty state; MAIN row gone next open).
- Tests: re-pin SERVERACT rows (6, DELETE last, ty recalc); `remove` CRUD incl.
  dropped-set resurrection guard and unknown-key refusal; confirm wiring both
  branches. E2e: extend the recents leg after the third LEAVE — SERVERS → entry →
  DELETE → YES → `#exports.servers() == 0` and the MMO menu no longer offers
  SERVERS. Recapture docs/screenshots/servers-submenu.png (row count changed).

## 8. Open questions / assumptions (autonomous mode — owner audit list)

1. "DESC-sorted based on the IPs" read as descending lexicographic order of the normalized
   `ip:port` string (favorites pinned above, same order within groups) — not recency order.
2. List is global across save slots (dual-write file pattern), not per-save.
3. `SERVERS` row hidden while the list is empty; hidden while hosting/connected.
4. EDIT HOST re-keys in place; collision replaces the entry at the target address.
5. CONNECT passes through CHARSET (name/look) like JOIN GAME, then dials directly.
6. Cap 16 entries, evict oldest-`last` non-favorite; favorites never evicted.
7. Duplicate display names allowed (e2e tests use unique names).
8. No DELETE row — not requested; eviction is the only removal path.
