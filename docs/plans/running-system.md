> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — B-Button Running System

| Field | Value |
| --- | --- |
| Date | 2026-08-04 |
| Source | /implement request: "running system when holding the game-B button… accelerate player movement… only when not riding the bike… supported by the online too" |
| Config | AGENTS_CONFIG.yml (quality preset) |
| Branch | feature/running-system |
| Base SHA | d85cca7a3825ad0c47324579b2b92b0d0024ab19 |
| Mode | Autonomous — Phase 2 grill and Phase 3 approval gates bypassed (owner not reachable mid-run); all assumptions logged in §8 |

## 1. Objective & success criteria

Hold B while walking → the player moves at 2× walk speed (bike-equivalent), exactly like the
Gen 3+ Running Shoes. Disabled while biking (and surfing). Online: remote players see your
avatar move at run speed when you run.

Done means:
- Local: holding B on foot halves the step duration (16 → 8 frames/tile); on the bike or while
  surfing, B does nothing to speed (bike stays 8; Cycling Road's held-B brake is untouched).
- Wire: `running` rides `mmo.move` (and presence snapshots), relayed by **both** hub
  implementations, and lands on the roster row.
- Avatars: a remote player flagged running steps at 8 frames/tile instead of the NPC default 16.
- All suites green: `tests/rby_mmo_test.lua`, `server/hub.test.js`, `modkit validate/lint`,
  and the two-instance e2e driver (per team rule: headless-only is not "verified").

## 2. Context & constraints (grounded findings)

Engine (gen1recomp, branch dev — read-only for us):
- `movement.speed` hook fires once per committed step in `Player:tryMove`
  (`src/world/Player.lua:105-120`). Signature `wrap("movement.speed", function(next, frames, ctx))`;
  `frames` is **frames-per-tile (lower = faster)**; result floored to ≥ 1. `ctx` carries
  `onBike`, `surfing`, `player`, `input` (the live Input module), `save`.
- Vanilla: walk 16, bike 8 (`src/world/FieldDefaults.lua:186-187`). Data packs can change these,
  so the run value must be computed **relative to the incoming `frames`**, not hardcoded.
- Held-B: `ctx.input:isDown("b")` (`src/core/Input.lua:262-264`). In the overworld, held B is
  vanilla-meaningful only as the Cycling Road brake **while on the bike**
  (`OverworldController.lua:1158-1166`) — our on-foot-only sprint cannot collide with it.
- NPCs have **no** `movement.speed` — per-frame `NPC:update` reads `self.stepFrames or 16` fresh
  (`src/world/NPC.lua:54-64`); Pikachu follower sets `npc.stepFrames` directly
  (`PikachuFollower.lua:493-506`). That is the supported way to speed up remote avatars.
- Animation cadence is deliberately decoupled from speed (`Player.lua:158-161`) — running looks
  like the bike: same leg cadence, faster translation. Accepted; no extra animation work.

Mod (this repo):
- `mmo.move` sent from `pushPresence` (`src/Client.lua:743-750`) every 0.125 s when
  `presenceChanged` (`Client.lua:721-728`) — the change-comparison must learn the new field or
  run-state flips won't be sent while standing on the same tile.
- **Hubs whitelist; nothing passes through.** Both `server/lib/relay.js:196-214` and
  `src/Hub.lua:823-836` rebuild the broadcast from `presenceOf(client)` with a fixed field list.
  A field added only client-side is silently dropped end-to-end. Both hubs change in lockstep.
- `Roster:move()` merges only `map/x/y/facing` (`src/Roster.lua:37-46`); the party feature
  shipped a bug from exactly this (`Roster.lua:63-73`). `running` changes with movement, so it
  is threaded **through `move()` itself** (like `facing`), not a separate setter.
- `Avatars:advance` (`src/Avatars.lua:179-223`) writes five NPC fields per step; adding
  `npc.stepFrames` there is one more field in the same write, per the Pikachu precedent.
  8 Hz presence ≈ 1 update per running tile (0.133 s/tile vs 0.125 s interval), and steps
  complete twice as fast, so `PRESENCE_INTERVAL` and `RESYNC_DISTANCE` stay unchanged.
- `PROTOCOL = 4` in `src/Config.lua:26` and `server/lib/relay.js:52`. Team canon (fleet decision,
  parties PR): bump when a client can send something an old hub would silently ignore — an old
  hub silently drops `running`, so **PROTOCOL 4 → 5**, both files together.
- Versioning convention (verified in git history): `feature:` commits bump `manifest.json`
  (0.4.0 → 0.5.0), `server/package.json` in lockstep (enforced by `server/config.test.js`),
  and `CHANGELOG.md`'s top heading must equal the manifest version.

## 3. Approach & key decisions

1. **Local sprint via `movement.speed` wrap** (evidence-based: hook signature read from the
   call site). Condition: `ctx.input:isDown("b")` and not `ctx.onBike` and not `ctx.surfing`
   and the `run` option enabled. Effect: `math.max(1, math.floor(frames / Config.RUN_DIVISOR))`
   with `RUN_DIVISOR = 2`. Relative math keeps data-pack overrides honest. Works offline too —
   sprint is a movement feature, not a connection feature.
2. **Wire = one additive boolean `running` on `mmo.move` + presence snapshots.** Client-truth
   (only the client knows B is held; no server-side signal to derive it from, unlike `busy`).
   Coercion `raw.running and true or false` in `Wire.presence`, same as `party`.
3. **Running-state tracking**: the `movement.speed` wrap records the flag ("my latest committed
   step was at run speed") on the Client module; `pushPresence` sends it and `presenceChanged`
   compares it. A stale `true` while standing still is harmless — a non-moving avatar has no
   steps to speed up — and clears on the next non-run step.
4. **Remote display**: `Avatars:advance` sets `npc.stepFrames = Config.RUN_STEP_FRAMES (8)`
   when the roster row says running, else clears it (nil → engine default 16).
5. **PROTOCOL 4 → 5** per fleet canon (a refusal naming both versions beats silent cosmetic
   degradation). Bumped in `src/Config.lua` and `server/lib/relay.js` together.
6. **Option toggle** `run` (default on) alongside the existing `bubbles` toggle — cheap escape
   hatch, follows the established options pattern.
7. **Not doing**: faster leg animation (no engine seam; bike has the same look), run-while-surf
   (modern-game parity), send-rate changes (not needed per the cadence math above).

## 4. Work breakdown — implementation tasks

**Wave 1** (all three run in parallel; files disjoint):

- **I1 — Lua client: sprint + wire + roster + avatars** (owns `src/Config.lua`, `src/Client.lua`,
  `src/Wire.lua`, `src/Roster.lua`, `src/Avatars.lua`)
  - Config: `PROTOCOL = 5` (comment citing the silent-drop rule), `RUN_DIVISOR = 2`,
    `RUN_STEP_FRAMES = 8` with rationale comments.
  - Client: wrap `movement.speed` in `install()` following the existing wrap idiom (pcall guard,
    always `return next(...)`); record run flag; `run` option row; send `running` in
    `pushPresence`; compare it in `presenceChanged`; read `msg.running` in the `MOVE` handler and
    pass to `roster:move`; include `running` per row in `exports.avatarState()`.
  - Wire: `running` coercion in `Wire.presence` (party-boolean pattern).
  - Roster: `move(id, map, x, y, facing, running)` threads the flag (header comment updated —
    this is the anti-party-bug choice).
  - Avatars: `advance` sets/clears `npc.stepFrames` per the roster row.
  - Acceptance: sprint math relative to incoming frames; bike/surf pass through untouched;
    no bare error/assert; every failure path logs with remediation.
- **I2 — Hubs in lockstep** (owns `server/lib/relay.js`, `server/lib/sanitize.js` if needed,
  `src/Hub.lua`, `server/package.json`)
  - Both `mmo.move` handlers: store `client.running` (boolean coercion, client-truth).
  - Both `presenceOf`: add `running` to the fixed field list.
  - relay.js: `PROTOCOL = 5`. package.json: `0.5.0`.
  - Acceptance: the two implementations byte-mirror each other's semantics, as today.
- **I3 — Docs & versioning** (owns `manifest.json`, `CHANGELOG.md`, `README.md`, `mod.card`)
  - manifest `0.5.0`; CHANGELOG `## [0.5.0] - 2026-08-04` describing the feature;
    README + mod.card mention hold-B running. (Routed to sonnet — mechanical; orchestrator
    override per `allow_orchestrator_override`.)

## 5. Work breakdown — test tasks

**Wave T1** (parallel; files disjoint):

- **TT1 — Lua suite** (owns `tests/rby_mmo_test.lua`): loader tier adds `movement.speed` to the
  wrapped-hooks assertion list and drives the chain with fake `(frames, ctx)` — on-foot+B → 8,
  onBike+B → unchanged, surfing+B → unchanged, option off → unchanged; pure tier: `Wire.presence`
  running coercion triplet (absent/true/junk — mirror the party tests at 394-398), roster
  `move()` threads running and it survives subsequent moves (mirror 615-630), avatars advance
  sets `npc.stepFrames = 8` for a running row and clears it for a walking row.
- **TT2 — Hub suites** (owns `server/hub.test.js`): over real sockets, A sends `mmo.move` with
  `running: true` → B's received broadcast carries `running: true`; absent field → `false`;
  junk value coerced. Protocol refusal already covered by existing tests — just confirm the
  bumped constant doesn't break them.
- **TT3 — e2e driver** (owns `tests/drivers/mmo_host.lua`, `tests/drivers/mmo_join.lua`,
  `tests/drivers/mmo_util.lua`): during the existing walk phase, host holds B; join asserts via
  `exports.avatarState()` that the host's avatar row shows `running = true` at least once.
  Keep it modest — flag propagation, not speed measurement.

E2e applies (user-visible flow crossing two processes + hub) and the harness exists. Run recipe
(from team memory): build a **private engine view** — symlink every top-level entry of
`~/Projects/alamops/gen1recomp` into `<scratchpad>/engine/` except `mods/`, then
`ln -s <this worktree> <view>/mods/rby_mmo`; never repoint the shared symlink. `luajit`/`node`
live at `/opt/homebrew/bin` (export on PATH); `love` at
`/Applications/love.app/Contents/MacOS/love`; copy `.env` from `~/Projects/alamops/RBYMMOMod/.env`
into the worktree; free port 7799 first; `SHOT_DIR=<scratchpad>/shots`.

## 6. Execution waves

1. Wave 1: I1 ∥ I2 ∥ I3 → commit → Phase 5 review of the full diff.
2. Wave T1: TT1 ∥ TT2 ∥ TT3 → commit.
3. Phase 7 (one agent): Lua suite + hub suites + `modkit validate --base imported` + `lint`
   from the private view, then the e2e driver. Phase 8 loops fixes (cap 3 rounds).

## 7. Blast radius & risks

- `affects_link` stays `false` — no link registry is touched; the byte-identical link-surface
  assertion in the suite must stay green.
- Old hub + new client: `running` silently dropped — mitigated by the PROTOCOL bump (refusal at
  hello names both versions).
- Cycling Road held-B brake: unreachable (sprint requires not-onBike; brake requires onBike).
- ~~Bike pace is not on the wire at all: a remote cyclist keeps stepping at 16 while their own
  game moves them at 8, so they shed ~3.75 tiles/s and trip `RESYNC_DISTANCE` repeatedly. A
  pre-existing gap this feature neither causes nor fixes.~~ **Closed by §9** — the flag was
  renamed to `fast` and a bike step now sets it.
- `presenceChanged` miss: forgetting the comparison field means run-state flips only piggyback
  on position changes — TT1/TT2 cover the flip explicitly.
- Peer overlap: `feature/nire-char` (new playable characters) may touch sprites/avatars;
  `feature/2x2-battles` touches battle code. Neither owns movement/wire files; no coordination
  message needed beyond the workdone log.

## 8. Open questions / assumptions (owner deferred — autonomous mode)

1. Run speed = 2× walk (bike-equivalent), the Gen 3+ convention. Not configurable beyond on/off.
2. Sprint also disabled while **surfing** (modern-game parity; the request literally says only
   "not riding the bike" — revisit if the owner wants B-sprint on water). *Still true of the
   speed after §9; the bike now reports its pace on the wire, but B still does nothing to it.*
3. Works offline as well as online (movement feature, not connection feature).
4. Added a `run` options toggle, default **on** (not requested; cheap and reversible).
5. PROTOCOL bumped 4 → 5 per fleet canon; the alternative reading ("cosmetic-only degradation,
   no bump") was considered and rejected for consistency with the parties precedent.
6. No walk-animation speed-up (engine has no seam; bike already looks this way).
7. Version bumped 0.4.0 → 0.5.0 (feature-commit convention observed in git history).

## 9. Follow-up (same release): the `fast` flag

Approved follow-up, landed on `feature/running-system` before 0.5.0 shipped.

**What changed.** The wire flag meant "B held on foot" and was called `running`. It now means
"this committed step was taken at the fast pace" and is called `fast`, set when the step was
sprinted **or** `moveCtx.onBike == true`. Run speed and bike speed are both 8 frames/tile, so
one boolean carries both and a watcher gets the only distinction they could ever draw. Surfing
stays not-fast (16 frames, like walking). The speed arithmetic is untouched: `runSpeed` still
refuses to divide a bike step, and the OR lives in the `movement.speed` wrap.

**Why it was free.** 0.5.0 and `PROTOCOL 5` are unreleased — no hub and no client anywhere has
ever spoken the old field name — so the rename is not a compatibility event. `PROTOCOL` stays
**5** and the version stays **0.5.0**; only the `Config.PROTOCOL` / `relay.js` comments record
that the field is `fast`.

**Bug it closes.** The §7 item struck above. Bike pace had never been on the wire, from the
mod's first version: a remote cyclist's avatar walked at 16 frames/tile while their real player
covered tiles at 8, fell behind at ~3.75 tiles/s, and hit `RESYNC_DISTANCE` every couple of
seconds — a despawn/respawn teleport pop for the length of the ride. A cyclist's presence now
says `fast`, `Avatars:advance` paces them at `FAST_STEP_FRAMES`, and they stay in step with
their own stream. The open item is closed.

**Renames.** `Client.runningNow` → `fastNow`; wire/roster/hub field `running` → `fast`
(`src/Wire.lua`, `src/Roster.lua:move`'s trailing arg, `src/Avatars.lua`, `src/Hub.lua`,
`server/lib/relay.js`, `exports.avatarState`); `Config.RUN_STEP_FRAMES` → `FAST_STEP_FRAMES`.
`RUN_DIVISOR` keeps its name — it is about the sprint divisor specifically, and the derived
constant is what serves both paces.

**Coercion.** Strict `== true` / `=== true` on every consumer now, including `Wire.presence`
(which used the truthy form). Both hubs must answer the same for the same bytes, and Lua and JS
disagree on `0` and `""`.
