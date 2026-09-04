# Plan — Custom battle backgrounds (gym / indoor / wild)

| Field | Value |
| --- | --- |
| Date | 2026-09-02 |
| Source | conversation: support for battle custom bg/field |
| Config | AGENTS_CONFIG.yml (quality; host cursor) |
| Flags | none (grill questions skipped — proceed on logged assumptions) |
| Gates | assumptions logged after skipped grill; implementing on that basis |
| Branch | feature/support-for-battle-custom-bg |
| Base SHA | 93d2a3354ce1a3ae5db8401eabb8a36765f5d40f |

## 1. Objective & success criteria

Players can drop their own 640×360 PNGs so gym, indoor, and wild fights use
that art instead of the ROM-stamped two-platform arena. A missing file keeps
today's look. No new permission, no wire change, no ROM bytes shipped.

Success: a present `assets/battle/custom/wild.png` (or indoor/gym) is what
`Battlefield.load` returns for that kind, even when `composeRomArena` would
succeed; the suite pins kind, paths, and that load order.

## 2. Context & constraints

Live fights stamp the current overworld tileset into a 640×360 canvas
(`Battlefield.composeRomArena`). Classification already exists:

- Gym: `GYM` / `DOJO` / `TILESET_GYM` (Johto gyms stay gym even when
  `environment=INDOOR`) — `gymSheet` in `src/Battlefield.lua`
- Indoor: houses, marts, centers — `arenaIndoor`
- Wild: routes, caves, forest, overworld — everything else

Authored fallbacks (`assets/battle/outdoor_grass_arena.png`,
`indoor_house_arena.png`) only run when ROM compose fails. There is no gym
fallback PNG and no player-override hook. `love.filesystem` is sandboxed;
`mod.assets:path` is the load seam. Manifest has `network` +
`engine_internals`, not `filesystem`.

Legal: custom files are the player's. This repo still ships only the original
authored fallbacks.

Peer: `keen-cedar-021b` is on `Battlefield.lua` for a PP-HUD fix on
`fix/realtime-pp-fix`. This work stays in the arena-load / kind path.

## 3. Approach & key decisions

Grill was skipped. Assumptions (reversible except #2, which is the feature):

1. **Drop-in files**, not options and not `filesystem`. Fixed names under
   `assets/battle/custom/`. `mod.assets:path` + `love.graphics.newImage`.
2. **Custom beats ROM compose.** Otherwise an imported ROM (everyone) never
   sees the files.
3. **Three buckets** via existing classifiers. Caves → wild.
4. **`{kind}.png` is the full arena.** Optional `{kind}_field.png` composites
   on top (ROM/fallback underlay when only the field file exists).
5. **No shipped placeholders.** Presence means override. Directory kept with
   `.gitkeep`.
6. **No gym authored fallback** in this run. Gym without custom still uses
   ROM, then the outdoor PNG — same as today.
7. **Per-client cosmetic.** No hub message. Each player sees their own files.
8. **Next fight picks them up.** `reloadArena` already runs at fight entry.

Rejected: text-option paths (naming-grid UX), adding `filesystem`,
server-pushed BGs (protocol + legal), replacing only the no-ROM PNGs
(invisible on a real import).

## 4. Work breakdown — implementation

| ID | Goal | Files | Deps | Acceptance |
| --- | --- | --- | --- | --- |
| I1 | Path constants + custom dir | `src/Config.lua`, `assets/battle/custom/.gitkeep` | — | Six documented relative paths |
| I2 | Kind, custom load, ROM-second | `src/Battlefield.lua` | I1 | `arenaKind`; custom bg wins; field overlays; no-game still does not lock the authored PNG |
| I3 | Docs | `CHANGELOG.md`, `README.md`, `docs/plans/README.md`, `.modkitignore` | I1 | Unreleased note + drop-in convention |

## 5. Work breakdown — tests

E2e: not applicable (no new user-visible flow that needs LOVE + ROM; the
shot driver still captures the default three looks when custom files are
absent).

| ID | Covers | File |
| --- | --- | --- |
| T1 | `arenaKind` gym/indoor/wild; custom paths; `load` prefers stub custom over stub ROM; field-only composites onto ROM; missing custom unchanged | `tests/rby_mmo_test.lua` |

## 6. Execution waves

Wave 1: I1 + I2 + I3 + T1 (single surface; no fan-out).

## 7. Blast radius & risks

Callers of `Battlefield.load` / `reloadArena` (`MediatedBattle`, `CoopBattle`,
`drawArena`) pick up the new source automatically. A corrupt custom PNG
falls through to ROM/fallback (pcall). Pack stays clean: no new ROM-like
PNG, plan listed in `.modkitignore`.

## 8. Open questions / assumptions

| Question | Answer | Source | Confidence |
| --- | --- | --- | --- |
| How do players supply art? | Drop-in PNGs in the mod folder | sandbox + existing `mod.assets` | high |
| bg vs field layers? | Full `{kind}.png`; optional `{kind}_field.png` overlay | parse of “bg/field”; reversible | medium |
| Beat ROM or fallback-only? | Beat ROM | otherwise feature is invisible | high |
| Caves? | Wild | existing field bucket | high |
| Options / filesystem? | No | reversible later | high |

## 9. Completeness ledger

| Item | Disposition |
| --- | --- |
| `M.load` / `drawArena` / fight-entry reload | in this run (I2) |
| Kind classifier + paths + load-order tests | in this run (T1) |
| README / CHANGELOG / custom dir | in this run (I3) |
| Authored gym fallback PNG + generator | out of scope — different art ticket |
| Mod-manager file picker / `filesystem` | out of scope — different ticket |
| Hub-shared arena (both clients same art) | out of scope — protocol |
| `arena_bg_shot.lua` recapture | out of scope — defaults unchanged when custom absent |
| PP HUD work on same file | out of scope — other branch |
