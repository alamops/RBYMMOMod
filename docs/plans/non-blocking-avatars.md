# Plan — Non-blocking avatars: remote players never block doors, local player draws on top

| Field | Value |
| --- | --- |
| Date | 2026-08-04 |
| Source | /implement: "fix the people blocking doors or points of map transitions… player char always the highest zIndex" |
| Config | AGENTS_CONFIG.yml (quality-ish: impl/review/fixes=opus, investigate/tests=sonnet, runner=haiku) |
| Branch | feature/blocking-doors |
| Base SHA | d85cca7a3825ad0c47324579b2b92b0d0024ab19 |
| Mode | **Autonomous** — grill and plan-approval gates bypassed; every assumption is logged in §8 |

## 1. Objective & success criteria

Remote-player avatars (runtime NPCs spawned by this mod) must never block the local
player's movement — most painfully on door/warp tiles — and when two player characters
occupy the same tile, the **local player must always draw on top**.

Done means:
- The local player can walk straight through any avatar, including onto a door/warp
  tile an avatar is standing on, and the warp fires normally.
- Ledge hops, the forced walk-out-of-a-door step, and boulder landings are likewise
  never blocked by an avatar (they use the same engine occupancy check).
- On a shared tile the local player renders above the avatar, deterministically —
  no frame-to-frame flicker.
- Despawn leaves zero residue on the engine's pooled NPC tables.
- Headless suite green; e2e driver proves the walk-through live.

## 2. Context & constraints (investigated, with anchors)

**Root cause.** `WorldAPI:spawnNpc` → `OverworldState:addRuntimeObject`
(`gen1recomp src/world/OverworldController.lua:3854-3874`) unconditionally pushes every
runtime NPC into `self.entities` — the exact list `Collision.occupied` walks
(`src/world/Collision.lua:20-30`). The player's step onto an avatar-occupied tile fails
inside `Collision.canMove`'s `verdict()` with `reason == "entity"`
(`Collision.lua:69-71`) *before* the player's cell changes, so `Warp.onArrive`
(`src/world/Warp.lua:17-23`, called from `OverworldController.lua:3207` post-step) never
runs. Warp logic itself never consults occupancy — clear the step and doors work.

**The engine's own escape hatch.** `Collision.occupied` skips any entity with
`e.passable` truthy (`Collision.lua:22`). That is exactly how the engine's
PikachuFollower avoids blocking the player (`src/world/PikachuFollower.lua:142`:
`npc.passable = true`). `spawnNpc`'s objDef does **not** surface this (no schema, no
copy in `NPC.new` — `src/world/NPC.lua:23-42`), and the `Handle` API has no setter —
but the mod already holds the live NPC via `handle.npc` (`src/Avatars.lua:85-89,139`)
and already writes engine fields on it directly, a documented precedent
(`src/Avatars.lua:10-12, 215-220`; commit 8766ad2).

**Why not a `movement.collision` hook wrapper instead.** The hook
(`Collision.lua:84-96`) only guards `Collision.canMove` callers. Ledge-hop landings
(`OverworldController.lua:1276`) and boulder landings (`:1210`) call
`Collision.occupied` *directly* — a hook wrapper leaves avatars blocking ledge hops.
`passable` covers every occupancy check, is per-entity-exact (a genuinely solid vanilla
NPC on the same tile still blocks), and is one field write.

**Draw order.** The overworld draw is a pure y-sort on `entity.py`
(`OverworldController.lua:4113` flat path; `:4494-4503` tilt path, same key). Lua's
`table.sort` is unstable, so equal `py` (the shared-tile case) is nondeterministic —
possible flicker. There is no z-index/layer/priority field or render hook (verified by
exhaustive grep). Measured fact: `NPC:update` recomputes `px/py` **only while
`self.moving`** (`NPC.lua:~54-95`); an idle NPC's `py` is untouched. Engine `py` values
are always whole pixels (`moved` is floored; landings snap to `cell*16`).

**Consequences for the fix:** the "player on top" lever is making avatar `py` sort
*strictly below* the player's on ties — a sub-pixel nudge. It must be applied
post-`NPC:update` (a nudge written from the mod's `input.step` pump is clobbered
mid-step before the draw sort), and it must be idempotent (only nudge when
`py % 1 == 0`), or idle avatars would drift 0.01px per frame.

**Side facts that shape the change:**
- Avatars are identified by `name = "mmo_" .. player.id` and tracked in
  `Avatars.spawned` (`src/Avatars.lua:100-116`); all removals flow through
  `M:despawn`/`M:clear` (`:119-130`), so cleanup has a single choke point.
- `addRuntimeObject` builds NPCs via `pooledNPC` (`OverworldController.lua:3868`) —
  tables are **reused**. Any field the mod sets must be cleared on despawn or a later
  vanilla NPC could be born passable.
- Avatars already overlap the *local* player one-way today: `Avatars:advance` writes
  `targetX/targetY` directly with no collision check (engine scripted moves are
  likewise unchecked, `OverworldController.lua:3934-3972`). This fix makes overlap
  symmetric.
- Interaction targeting uses the *facing* cell (`OverworldController.lua:1630-1657`)
  via `npcAtCell`, which ignores `passable` — you can still A-press an avatar in front
  of you. Sharing a tile does not corrupt targeting.
- `movement.collision` is not currently wrapped by the mod; the mod's hooks are
  `input.step`, `render.hud`, `ui.start_menu.items` (`src/Client.lua:1077-1102`) and
  `ui.naming.grid` (`src/Ui.lua:525`). This plan adds **no** new hook.
- Avatar spawn/advance/collision is historically verified by the two-instance e2e
  driver, not the headless suite (`tests/rby_mmo_test.lua:1907`; driver header
  `run-mmo-e2e.sh:5-9`). The headless suite covers pure helpers only.
- `affects_link` stays `false` — nothing here touches a link registry.

## 3. Approach & key decisions

**D1 — `passable = true` on the live avatar NPC (spike-grade evidence: engine source
read directly), not a `movement.collision` wrapper.** Exact engine semantics, covers
direct `Collision.occupied` call sites the hook misses, mirrors PikachuFollower, and
reuses the mod's documented reach-past-the-facade precedent. Rejected: hook wrapper
(coverage gap: ledge/boulder landings; needs cell→avatar reverse lookup); upstream RFC
for `objDef.passable` (right long-term, but Lane B — noted in §8, not blocking this
fix).

**D2 — Player-on-top via an idempotent sub-pixel `py` nudge in a per-instance
`update` override.** After the class `update` runs, if `py % 1 == 0`, set
`py = py - NUDGE` (NUDGE = 0.01, a Config constant). Ties with the player (always
whole-pixel) become strict "avatar first, player last → player on top"; real ≥1px
orderings are untouched; idle frames don't re-nudge (no drift); moving frames re-nudge
after each engine recompute. Rejected: nudging from the per-tick pump (clobbered
mid-step, measured); touching the local player's `py` (blast radius into engine
player logic).

**D3 — Zero-residue despawn.** `despawn` restores the pooled table before
`removeNpc`: clear `passable`, remove the per-instance `update` (rawset nil → falls
back to the class method), clear the marker flag. A recycled NPC must be
indistinguishable from vanilla.

**D4 — Self-healing decorate.** `advance` re-applies the decoration if the live NPC
lacks the marker (engine rebuilt/replaced the object). Idempotent, ~1 comparison per
tick per avatar.

**D5 — Version 0.4.1** (fix release), CHANGELOG heading to match manifest — repo rule.

## 4. Work breakdown — implementation

**Wave 1 — single task (opus), no fan-out** (cohesive change, one owner):

**IMPL-1** — Make avatars passable and depth-nudged; clean despawn.
- **Owns:** `src/Avatars.lua`, `src/Config.lua`, `manifest.json`, `CHANGELOG.md`.
- Add `Config.AVATAR_DEPTH_NUDGE = 0.01` with a comment stating both invariants it
  relies on (engine py is whole pixels; only nudge when `py % 1 == 0`).
- In `Avatars.lua`: module-level `M.decorate(npc)` / `M.undecorate(npc)` (module
  functions, not methods — headless-testable with a stub table, like `M.stepToward`):
  - `decorate`: if already marked, return. Set marker field, `npc.passable = true`,
    capture `local base = npc.update` (metatable resolution) and rawset a per-instance
    `update(self, ...)` that calls `base(self, ...)` then applies the idempotent nudge.
  - `undecorate`: clear marker + `passable`, rawset `update` to nil. Safe on a
    non-decorated table.
  - Call `decorate` at the end of `spawn` (via `self:handle`); call `undecorate` in
    `despawn` before `removeNpc`; in `advance`, after the npc-liveness check,
    re-`decorate` when the marker is absent (D4).
  - Comment style: match the file's existing discursive comments — say *why*
    (PikachuFollower precedent, pooled tables, unstable y-sort) at the decorate
    definition, not per-line narration.
- `manifest.json` version → `0.4.1`; CHANGELOG `## [0.4.1] - 2026-08-04` Fixed entry
  in the file's existing voice.
- **Acceptance:** decorated stub npc is passable and nudges only whole-pixel py;
  undecorate restores metatable `update` and clears both fields; mod loads clean.

## 5. Work breakdown — tests

**TEST-1 (sonnet)** — headless unit coverage. **Owns:** `tests/rby_mmo_test.lua`.
Extend the existing "Avatar step routing" section's style: stub npc table with an
`update` on its metatable that (a) leaves py alone (idle) and (b) recomputes an
integer py (moving). Assert: decorate marks/passables/nudges exactly once across many
idle updates (no drift); moving recompute re-nudges to `int - NUDGE`; ordering
`npc.py < player integer py` on the tie case; undecorate restores the metatable
method, clears `passable` + marker; decorate is idempotent; undecorate on a bare table
is a no-op.

**TEST-2 (sonnet)** — e2e walk-through assertion. **Owns:** `tests/drivers/`
(`mmo_util.lua`, `mmo_host.lua`, `mmo_guest.lua`, `run-mmo-e2e.sh` as needed).
Extend the existing open-world section: one side stands still, the other walks
*through/onto* the stander's tile; assert the walker's own position reaches the tile
(pre-fix this is impossible — the step is refused). Keep it deterministic (poll
positions via the existing `exports.avatarState`/util seams, no sleeps beyond the
driver's idiom). Do not attempt a door-warp scenario — the walk-through is the
mechanism the doors case reduces to.

E2e applies (user-visible overworld flow; two-instance harness exists). Run recipe
(from prior sessions' memory): build a **private engine view** — symlink every entry
of `~/Projects/alamops/gen1recomp` except `mods/` into a scratch dir, then symlink
this worktree in as `mods/rby_mmo`; never repoint the shared checkout's symlink.
`luajit`/`node` live at `/opt/homebrew/bin` (not on PATH); `love` at
`/Applications/love.app/Contents/MacOS/love`; copy `.env` from
`~/Projects/alamops/RBYMMOMod/.env` into the worktree; `SHOT_DIR` must point at the
scratchpad; kill any stale listener on 7799.

## 6. Execution waves

1. Wave 1: IMPL-1 (single agent).
2. Phase 5: review (opus) on `git diff d85cca7...HEAD`.
3. Wave 2: TEST-1 ∥ TEST-2 (disjoint files).
4. Phase 7: one runner (haiku): private view → headless suite, `modkit validate`
   + `lint` (with `MODKIT_LUAJIT`), `node server/hub.test.js`, then the e2e driver.
5. Phase 8 if needed (opus), then re-run.

## 7. Blast radius & risks

- **Pooled-table residue** (a vanilla NPC born passable) — the worst failure mode;
  mitigated by D3 + D4; TEST-1 pins undecorate. Exotic engine-side rebuild paths that
  bypass despawn leave at most a stale decoration on a table the engine then re-inits
  from `objDef` fields; marker-guarded nudge degrades to a 0.01px offset, and
  `passable` residue is bounded by despawn covering every mod-initiated removal
  (PART/MOVE/resync/sync-drop/map-change/disconnect all funnel through
  `despawn`/`clear`, verified).
- **Vanilla NPC wanderers can now stack onto an avatar's tile** (occupancy skips
  passable entities both ways). Accepted: remote players should not perturb the local
  world sim (§8 A2).
- **Nameplate math** reads `npc.py / 16` (`Avatars.lua:142`) — 0.01px shift,
  imperceptible.
- **Interacting with an avatar standing on your own tile** is impossible (facing-cell
  targeting) — cosmetic, pre-existing for the one-way overlap that already occurs.
- Trainer sight-line code was not fully traced; avatars carry no `trainerClass`, so
  engagement paths keyed on `npc.def` cannot fire for them (§8 A5).
- No wire/protocol change, no link registry touched — `affects_link` unchanged.

## 8. Open questions / assumptions (autonomous mode)

- **A1**: Mod-side fix using the established direct-NPC-write precedent is acceptable;
  the *right* long-term seam (`objDef.passable` in `spawnNpc`, or `Handle:setPassable`)
  is an upstream Lane B RFC — recommended as follow-up, not done here.
- **A2**: Letting vanilla NPCs path through avatars is desired (non-perturbation).
- **A3**: "Highest zIndex" is satisfied by deterministic player-on-top on shared
  tiles via sub-pixel depth, engine having no real z-order.
- **A4**: Patch version bump (0.4.1) is the right release shape for a fix.
- **A5**: Avatars can't trigger trainer-sight/battle paths (no `trainerClass` in
  their objDef) — asserted from engagement code read, not an exhaustive trace.
- **A6**: Avatar-vs-avatar same-tile flicker (both nudged equally) is acceptable;
  only the local player's supremacy was requested.
