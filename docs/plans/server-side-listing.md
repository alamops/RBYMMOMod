> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — Server-side listing: connected players (with locations) and the ranking

| Field | Value |
| --- | --- |
| Date | 2026-08-05 |
| Source | /implement — "enhance the server side features, including a feature to list the connected players and where they are in the world map (name location), include the feature to list the ranking" |
| Config | AGENTS_CONFIG.yml (quality) |
| Branch | feature/enhance-server-features |
| Base SHA | 99a56f72cc3685d79e01333232881a733768d7f1 |
| Mode | **Autonomous** — the grill and plan-approval gates were bypassed because the owner is not reachable mid-task; every scope decision is logged in §8. |

## 1. Objective & success criteria

Give the hub operator (and the players) a way to see who is connected and where
they are, by place name, and a way to read the ranking from the server side.

Done means:

1. `rby-mmo-hub players` prints every connected player with a human-readable
   location ("PALLET TOWN", not `PALLET_TOWN`), their status, and points —
   live from the running hub, honest about staleness when the hub is down.
2. `rby-mmo-hub ranking` prints the persisted leaderboard without needing a
   game client.
3. The in-game PLAYERS screen shows each player's location name, resolved from
   the local player's own ROM-decoded town-map data.
4. All server suites, the mod's Lua suite, modkit validate/lint/pack, and both
   e2e drivers are green.

## 2. Context & constraints (grounded findings)

- **Ranking already ships** (0.6.3): `server/lib/rank.js` `Board` with
  `top(RANK_TOP=10)` (`rank.js:348-363`), persisted to `ranking.json` beside
  `config.json` (`server/lib/server.js:99-100`, debounced 1s, tmp+rename at
  `server.js:574-597`), and served to game clients as `mmo.ranks` →
  `mmo.ranking` (`relay.js:435-443`, `:1058-1064`). **No operator surface
  exists** — no CLI verb touches the board or `ranking.json`.
- **The CLI is a separate short-lived process** with no live channel to the
  running hub (stated at `cli.js:648-661`); the only cross-process channel is
  SIGHUP → reload of credentials/bans (`server.js:853-909`). A live "who's
  online" needs a new channel.
- **The hub already knows each player's location**: per-client `map, x, y`
  (`relay.js:538-565`), where `map` is the engine's string map key
  (`PALLET_TOWN`), sanitised by `cleanMapId` (`sanitize.js:37-40`). `map/x/y`
  are null while in battle/menu (`relay.js:220-226`). Presence exposes only
  booleans for busy/party, never session ids (`relay.js:100-106`).
- **Client-side**: presence already carries `map` (`Wire.lua:338-381`), the
  Roster stores it (`Roster.lua:13-15`), and a PLAYERS screen exists
  (`Ui.lua:1381-1420`, `ROSTER = "RbyMmoRoster"`) showing name +
  `PARTY/BUSY/HERE` — no location name.
- **Map display names** (verified directly in the engine): the engine decodes
  them at runtime from the player's own ROM into `game.data.field.townMap`
  (`~/gen1recomp/src/ui/TownMap.lua:51-55` handles both `townMap` and
  `townMap.locations` shapes; `:104`), with `mapId:gsub("_"," ")` as the
  engine's own fallback (`:38-41`). Screens receive `game`, so this is plain
  table access — no `require` of engine internals needed for names.
- **Protocol discipline**: `PROTOCOL = 5` (`relay.js:60`, `Config.lua:41`).
  Unknown message types are silently ignored (`relay.js:1068-1080`). Nothing
  in this plan changes the wire, so **PROTOCOL stays 5**.
- **Test idioms**: relay-level socket-free tests (`rank.test.js` `makeHub`),
  real-TCP hub tests (`hub.test.js`), in-process CLI tests with captured io
  and temp dirs (`cli.test.js`); Lua side: headless loader registration
  checks (`rby_mmo_test.lua:115-131`), fake-hub protocol tests (`:909+`),
  exported layout constants instead of screenshots (`RANK_LAYOUT`,
  `nameRoom`), e2e drivers asserting diagnostic exports.
- **Legal**: no ROM-derived bytes may ship. Formatting `PALLET_TOWN →
  PALLET TOWN` on the hub is a pure string transform of runtime wire data —
  allowed. Real display names on the client come from the player's own
  runtime-decoded data — allowed. A committed id→name table would not be.
- **Stale doc**: `server/README.md:1001-1075` still says PROTOCOL 3 and omits
  the rank messages — fix while documenting the new verbs.
- Worktree testing: build a private engine view (symlink farm) — never
  repoint the shared `mods/rby_mmo` symlink; `luajit`/`node` live in
  `/opt/homebrew/bin`; e2e needs `.env` copied from the main checkout and
  `SHOT_DIR` moved to the scratchpad.

## 3. Approach & key decisions

1. **Live channel = status snapshot file** (`status.json` in the data dir,
   beside `config.json`/`ranking.json`). The hub writes it debounced on
   roster changes and refreshes it as a heartbeat even when idle; the CLI
   reads it and reports its age honestly. Chosen over an admin socket because
   it reuses the existing persistence idiom (debounce + tmp/rename), adds no
   network or auth surface, works unchanged under Docker's read-only rootfs
   (`/data` is the only writable mount), and degrades honestly (a stale
   heartbeat is detectable). *Rests on reasoning, not spike evidence.*
2. **`ranking` verb reads `ranking.json`** — already persisted within ~1s of
   any change; no new plumbing.
3. **Location names**: hub side formats the map id for display
   (`PALLET_TOWN` → `PALLET TOWN`); client side resolves real names from
   `game.data.field.townMap` with the same `gsub` fallback the engine uses.
   *The client access path was verified by reading the engine source.*
4. **No wire changes.** PROTOCOL stays 5; no new message types; `Wire.lua`
   untouched.
5. **Version → 0.7.0** (additive features), CHANGELOG heading to match.

### status.json contract (fixed here so tasks stay independent)

```json
{
  "version": 1,
  "startedAt": 1754300000000,
  "updatedAt": 1754300012345,
  "stoppedAt": null,
  "host": "0.0.0.0", "port": 7788, "protocol": 5, "maxPlayers": 8,
  "players": [
    { "name": "RED", "sprite": "…", "map": "PALLET_TOWN", "x": 5, "y": 6,
      "busy": false, "party": false, "points": 12, "ranked": true }
  ]
}
```

- Written atomically (tmp+rename, 0600 like ranking) on: start, roster/state
  change (debounced 1s), heartbeat every `STATUS_HEARTBEAT_MS = 10000`, and
  clean shutdown (final write with `stoppedAt` set and `players: []`).
- `map` stays the raw id in the file; formatting is a display concern.
- Staleness rule for readers: `stoppedAt` set → hub stopped then; else
  `now - updatedAt > 2.5 × heartbeat` → "hub appears to be down"; else live.

### CLI output contracts

- `rby-mmo-hub players [--json]` — header line with count and snapshot age;
  one row per player: NAME, LOCATION (formatted map name, or a dash while the
  player is in a battle/menu, since map is null there), STATUS
  (BUSY/PARTY/blank), POINTS (only when ranked). `--json` prints the snapshot
  players array verbatim. Exit 0 with "no one is online" when empty; honest
  message (not an error-looking crash) when the hub is down or `status.json`
  absent — mirror `doctor`'s tone.
- `rby-mmo-hub ranking [--json] [--all]` — reads `ranking.json`; default top
  10 by points desc (ties by name, matching `Board.top`), `--all` for every
  ranked player with points > 0; columns PLACE, NAME, POINTS. Honest empty
  and missing-file messages.

## 4. Work breakdown — implementation tasks (one wave, all file-disjoint)

- **A — hub snapshot** · `server/lib/relay.js`, `server/lib/server.js`.
  Add `Relay#roster()` (ready clients only, fields per contract, no ids or
  session/party ids or token material) and an `onRosterChanged` notification
  hook (or reuse existing broadcast points) so `server.js` can debounce; in
  `server.js`, write `status.json` per the contract (start, change, heartbeat
  timer — `unref()`d — and final write in `close()`), following
  `flushRanking`'s tmp+rename/0600 idiom. Expose the snapshot path alongside
  `RANKING_FILENAME`'s pattern. Acceptance: snapshot appears and updates as
  described; nothing sensitive in it; hub behavior otherwise unchanged.
- **B — CLI verbs** · `server/lib/cli.js` only.
  Add `players` and `ranking` verbs per the output contracts, wired into the
  dispatch table and help text in the existing verb style; read files from
  the same data dir resolution the other verbs use; implement the staleness
  rule; formatting helper `PALLET_TOWN → PALLET TOWN`. Acceptance: verbs
  work against files written by hand in a temp dir (the contract is the
  interface — do not import server.js).
- **C — client PLAYERS location** · `src/Places.lua` (new), `src/Ui.lua`.
  `Places.name(game, mapId)` → display name from
  `(game.data.field or {}).townMap` (handle both the `locations` sub-table
  and flat shapes, entries like `{x,y,name}`), falling back to
  `mapId:gsub("_"," ")`; nil-safe when mapId is nil (return nil; the screen
  shows the existing BUSY status then). Roster screen rows gain the location
  name (keep BUSY/PARTY precedence in the right column; location may replace
  HERE — the name already conveys sameness). Export a layout/width constant
  (à la `nameRoom`) so tests pin the arithmetic. Acceptance: PLAYERS rows
  show "PALLET TOWN"-style names for players in the overworld.
- **D — docs & version** · `manifest.json`, `CHANGELOG.md`, `README.md`,
  `mod.card`, `server/README.md`.
  Bump 0.6.3 → 0.7.0 with a matching CHANGELOG entry (keep-a-changelog
  voice, matching the file's existing narrative style); document both verbs
  in server/README (operator section + compose exec examples); fix the stale
  protocol table (says 3, is 5; missing rank messages and `fast`); update
  mod.card differences and README one-liners if they enumerate features.
  Acceptance: CHANGELOG heading matches manifest.version; no doc claims a
  feature this plan doesn't build.

## 5. Work breakdown — test tasks

- **T1 — server tests** · `server/server.test.js`, `server/cli.test.js`,
  `server/rank.test.js` (only if a relay-level helper needs pinning).
  Snapshot lifecycle (created at start, updates on join/leave, heartbeat,
  `stoppedAt` on close, atomicity, no sensitive fields), CLI verbs against
  hand-written fixture files (live, stale, stopped, missing, empty, --json,
  --all, top-10 cut), map-name formatting.
- **T2 — Lua tests** · `tests/rby_mmo_test.lua`.
  Places resolver (both townMap shapes, fallback, nil map), roster-screen
  layout constant, registration list unchanged plus any new export.
- **e2e**: applicable — the PLAYERS screen changed. Extend the existing
  driver assertions only if a diagnostic export exists for the roster screen;
  otherwise rely on the drivers' existing PLAYERS navigation plus the Lua
  layout pin. Run recipe (Phase 7): private engine view per §2, then
  `node --test` in `server/`, `luajit mods/rby_mmo/tests/rby_mmo_test.lua`,
  `python3 tools/modkit.py validate|lint|pack mods/rby_mmo`, and
  `bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh` (SHOT_DIR in scratchpad,
  `.env` copied, port 7799 free) plus the hub e2e (`run-hub-e2e.sh`) — both
  transports per standing guidance.

## 6. Execution waves

- **Wave 1**: A, B, C, D in parallel (opus ×4, file-disjoint; B builds
  against the §3 contracts, not against A's code).
- **Review** (opus) over the whole diff → triage.
- **Wave T**: T1, T2 in parallel (sonnet).
- **Run** (haiku background agent): suites + modkit + both e2e drivers.
- **Fixes** (opus) as needed, re-run to green, ≤3 rounds.

## 7. Blast radius & risks

- `server.js` gains a timer and a write path — must `unref()` the heartbeat
  so tests/CLI don't hang, and the final write must not throw during
  shutdown. Docker read-only rootfs: `/data` is writable, status.json lives
  there — fine.
- `status.json` is operator-readable state: keep names/points only — no
  credential ids, token hashes, session ids, or IPs.
- Roster screen row width: 20-tile screen; NAME + location must fit — the
  exported layout constant and T2 pin this.
- `players` shows a dash for battling players (map is null by design) — the
  CLI copy should say why, not look broken.
- Docs risk: D writes docs from this plan; I reconcile any deviation A–C
  report before commit.

## 8. Open questions / assumptions (autonomous mode)

1. **"Server side" read as operator-facing**: the deliverable is CLI verbs on
   the hub (`players`, `ranking`), not new wire messages — game clients
   already have both lists locally. Logged, not asked.
2. **Client PLAYERS screen also gains locations** — "where they are in the
   world map (name location)" is taken to include the player-visible list;
   scoped to the existing screen, no new screen.
3. Snapshot file over admin socket (see §3.1) — revisit if the operator later
   needs live *commands* (kick, broadcast), which a file can't carry.
4. Ranking verb accepts ~1s staleness from `ranking.json`; no live query.
5. Version 0.7.0; PROTOCOL unchanged at 5.
6. Feature suggestions requested by the user are delivered in the final
   report, not built here.
