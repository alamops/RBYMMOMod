# Plan — Co-op / 1v1 top-down battlefield (Gen1)

| Field | Value |
| --- | --- |
| Date | 2026-08-11 |
| Source | `/implement` + screenshot `screenshot-2026-08-12_03-19-15-133eeb53.png`; grill answers 2026-08-11 |
| Config | AGENTS_CONFIG.yml (quality preset, v3; host cursor) |
| Branch | fix/fix-battle-system-v2-reported-by-quarkst (Phase 4 on this worktree) |
| Base SHA | `e141484` (pre-battlefield; tree already had uncommitted Gen2 theatre work) |
| Autonomy | Interactive — Phase 2 answered; Phase 3 **approved** 2026-08-11 with amendments below |

### Approval amendments (2026-08-11)

- Arena asset filename: **`assets/battle/outdoor_grass_arena.png`** (not `arena.png`).
- **Animations in v1:** not attack/move AnimPlayer flashes. Include (1) Pokémon idle/act animations on field icons, (2) **animated speech bubbles above trainer heads** when that trainer’s mon acts / is ordered to attack. Wild fights: **no** trainer bubbles (no right-side human).

## 1. Objective & success criteria

Replace the classic Gen1 side-view CoopBattle **and** MediatedBattle 1v1 presentation with a **top-down arena battlefield**:

- Full-bleed arena art (left = player side, right = foe side).
- Human trainers on the far sides (overworld walk sheets, facing inward).
- Active battle mons on the grass as **party/bag icons**.
- Targeting: **cursor moves on the field**; animated arrow + floating status card (name, Lxx, HP, status, **front battle sprite**).
- Gen1 only in this delivery; Gen2 deferred until Gen1 is consolidated.

**Done when:**

1. Headless suite asserts layout helpers, seat placement, target cursor, and card fields.
2. E2e driver captures screenshots (coop NPC + 1v1 + wild) showing arena + actors + target card.
3. Owner live playtest checklist passes (see §5).

## 2. Context & constraints

### Grounded findings (Phase 1)

- Today: guild-focus classic stage + strips (`CoopBattle.lua` `STAGE_*`, `drawField`, white 160×144). Soft seam = `drawSafe` / `drawField` / target phase; sim untouched.
- Engine already supports wider UI surfaces via `isWideBattleLayout` + `uiSize()` (`Renderer:setUISize`, max **640×576**). `wantsFillScale` stretches that surface to the window (`BATTLE SIZE` fill).
- Arena screenshot: **1672×941** (~16:9). Ship under `assets/battle/` via `mod.assets` (same pattern as Cast / HUD fonts).
- Humans: OW walk sheets (`SpriteRenderer` / `data.sprites[id]`) — not battle trainer pics for mid-fight sides.
- Mons on field: `Sprites.iconPath` (party icons). Card: battle **front** via existing battler / `Sprites.path(..., "front")`.
- Legal: owner asserts the arena PNG is a shippable original asset. If `modkit lint` / review rejects it as ROM-derived, fall back to generated/procedural art (assumption A1).
- Gen2: no draw work this delivery (explicit).

### Locked product decisions (Phase 2)

| # | Decision |
| --- | --- |
| Art | Commit the provided arena asset first; generate only if it fails legal/load |
| Canvas | Wider + fill window (not 160×144 letterbox) |
| Scope | Hard-cut CoopBattle **and** MediatedBattle 1v1 |
| Humans | OW walk sheet, facing the opposite half |
| Mons | Active field seats only; bag icons on field; front sprite on card |
| Targeting | Field cursor + arrow + floating card |
| Modes | `coop_npc`, `coop_wild`, `coop_pvp`; wild = no right-side human |
| Gen2 | Deferred |
| Accept | Suite + e2e screenshots + live playtest |

## 3. Approach & key decisions

### Surface size (spike-backed reasoning, not measured)

Use a **fixed landscape UI canvas** within Renderer caps, then **fill-scale** to the window:

- Proposed: **640×360** (16:9, under `MAX_UI_WIDTH/HEIGHT`).
- CoopBattle / MediatedBattle always report:
  - `isWideBattleLayout() → true` (force wide surface while these screens are up; independent of save `battleLayout` option)
  - `uiSize() → 640, 360`
  - `wantsFillScale() → true` (fill window)
  - Keep `isOpaque = true`, `letterboxWhite` as needed so voids match arena edges

**Why not true window-pixel drawing via `render.hud`:** input, AnimPlayer, and message box still live in the screen state’s coordinate system; riding `uiSize` keeps one transform. **Why not 304×144 WideBattle alone:** too short for a readable top-down field + card; art is 16:9.

Alternative considered: keep guild-focus as toggle — **rejected** (hard-cut).

### Module split

New `src/Battlefield.lua` owns:

- Arena image load (`mod.assets`)
- Seat layout (ally left / foe right; human side pads; mon icon slots)
- Draw: background, humans, mon icons, target arrow, status card
- Pure helpers for tests: `seatRect`, `humanFacing`, `cardModel`, `targetOrder`

`CoopBattle.lua` / `MediatedBattle.lua` keep turn logic; swap `drawSafe`/`drawField`/`drawTarget`/`updateTarget` to Battlefield APIs.

### Targeting UX

- `target` phase: d-pad moves a **field cursor** among living foe seats (and ally seats if moves can target ally — match current target list rules).
- Animated arrow (bob/`0xED` or small drawn chevron) over the hovered seat.
- Floating card anchored near the hovered mon (clamp to canvas): name, `Lxx`, HP bar, status tag, front pic.
- Bottom command/move/message chrome remains; may sit in a reserved bottom band (~20% of 360) so the grass stays readable.

### Humans

| Mode | Left | Right |
| --- | --- | --- |
| `coop_npc` | self (+ partner if present) | trainer OW sprite if resolvable, else class pic / omit |
| `coop_pvp` | self + partner | opposing humans |
| `coop_wild` / mediated wild | self (+ partner) | **none** |
| mediated 1v1 | self | peer OW sprite if roster has sprite id; else omit |

Facing: left side faces **right**; right side faces **left** (walk sheet dir).

## 4. Work breakdown — implementation tasks

| ID | Goal | Owns (disjoint) | Depends | Acceptance |
| --- | --- | --- | --- | --- |
| I1 | Ship arena asset + Config path helper | `assets/battle/outdoor_grass_arena.png`, `src/Config.lua` (path constant only) | — | Image loads via `mod.assets:path`; documented in CHANGELOG legal note |
| I2 | `Battlefield` module: layout + draw + target helpers | `src/Battlefield.lua` (new) | I1 | Pure helpers cover seats/facing/card; draw functions pcall-safe when asset missing |
| I3 | Wire CoopBattle to Battlefield (draw + field target input + uiSize) | `src/CoopBattle.lua` | I2 | Hard-cut: no guild-focus stage; wide+fill; target moves on field |
| I4 | Wire MediatedBattle 1v1/wild same theatre | `src/MediatedBattle.lua` | I2 | Same canvas/API; 1v1 + wild layouts |
| I5 | Client/zones/CHANGELOG plumbing | `src/Client.lua` (zones wrap if needed), `CHANGELOG.md`, `main.lua`/`need` only if required | I3, I4 | Mod loads; CHANGELOG Unreleased entry |

**Wave A:** I1 + I2 (I1 first if same agent; or I1 then I2 sequential — asset before module). Prefer **one agent for I1→I2** to avoid Config/Battlefield race.  
**Wave B:** I3 ∥ I4 (disjoint files).  
**Wave C:** I5.

## 5. Work breakdown — test tasks

| ID | Goal | Owns | Covers | Notes |
| --- | --- | --- | --- | --- |
| T1 | Unit/layout asserts in suite | `tests/rby_mmo_test.lua` (new block) | I2–I4 | uiSize, seat sides, wild has no right human, target cursor order, card fields; Gen1-only |
| T2 | E2e screenshot driver | `tests/drivers/run-battlefield-e2e.sh` + lua harness under `tests/drivers/` | I3–I4 | Coop NPC + 1v1 + wild frames; write under `tmp/e2e-battlefield/` |
| T3 | Live playtest runbook | section in this plan + `docs/plans/coop-battlefield-layout.md` checklist | all | Manual; agent prepares ROM/hub commands |

**E2e applies:** yes — visual presentation is the feature; unit tests cannot prove the arena composites.

**Run recipe (from engine root, mod symlinked):**

```sh
# hub + two LOVE clients (existing pattern)
bash mods/rby_mmo/tests/drivers/run-battlefield-e2e.sh
# or extend run-hub-e2e / invite paths with screenshot hooks like guild-focus
```

Requires ROM import (`scripts/setup.sh --rom …`). Agent owns start → readiness → capture → tear-down where LOVE headless/driver allows; otherwise maximal automated subset + manual click steps.

**Live playtest checklist (owner):**

- [ ] Coop NPC: arena fills the window; self (+partner) left; trainer right; 2v2 bag icons on grass; icon bob
- [ ] Target: d-pad moves field cursor (wraps); arrow + card only while picking; card shows name/L/HP/status/front
- [ ] Trainer callout bubble above the human when their mon acts (NPC + PvP); **no** foe bubbles in wild
- [ ] Wild coop: no right human; wild icons on right half
- [ ] Mediated 1v1: humans both sides; fight/menu usable in bottom band
- [ ] Win/loss music restore still OK
- [ ] Drop screenshots in `tmp/e2e-battlefield/` (or `bash tests/drivers/run-battlefield-e2e.sh --play`)

**Known limitation (review should-fix, deferred):** classic 160×144 party/bag overlays opened mid-fight sit at the top of the 360-tall canvas rather than the menu band — keyboard still works; polish in a follow-up.

**E2e N/A?** No.

## 6. Execution waves

```
Wave A: I1 → I2 (sequential; asset then module)     [builder]
Barrier: Battlefield loads + helpers green in isolation
Wave B: I3 ∥ I4                                      [builder ×2]
Barrier: both screens enter/draw without throw
Wave C: I5                                           [builder]
Wave D: T1                                           [test_author]
Wave E: T2                                           [test_author]
Wave F: tests_running (suite + e2e)                  [test_runner]
Wave G: fixes if needed                              [builder]
```

Phase 5 review runs after Wave C (before or interleaved with T1 — skill says review production diff before tests; follow skill: review after I*, then T*).

## 7. Blast radius & risks

| Risk | Mitigation |
| --- | --- |
| Arena art fails legal lint | Generate replacement; keep layout API stable |
| `uiSize` 640×360 + fill looks soft | Nearest-neighbour already; tune size (480×270) if blurry |
| AnimPlayer / move flash assumes classic coords | Translate anim origins via Battlefield seat rects or disable stage anims v1 with message-only timing |
| Touch / hit-testing on wide surface | Reuse engine classicOffset pattern for non-wide menus; keep commands in reserved band |
| Guild-focus tests assert STAGE_* | Rewrite those asserts for Battlefield constants |
| Gen2 accidental break | No Gen2 branches; generation≠1 keeps current path **or** same draw if already sharing — prefer **Gen1-only gate** so Gold stays on old guild-focus until later |

**Assumption A2 (Gen1 gate):** If `Gen.generation(game) ~= 1`, CoopBattle/MediatedBattle keep **current** guild-focus / classic draw so Gen2 is not silently broken. Confirm on approval if you’d rather hard-cut Gen2 to a stub message instead.

**Rollback:** revert hard-cut to call old `drawField`; asset can remain unused.

## 8. Open questions / assumptions

1. **A1 — Art legal:** Treating the PNG as owner-approved original for `assets/battle/arena.png`. If CI/lint disagrees, generate a stand-in.
2. **A2 — Gen1 gate:** Gen2 keeps old draw until a later delivery (recommended).
3. **A3 — Animations (amended):** v1 includes Pokémon field-icon idle/act motion and trainer-head callout bubbles when a human’s mon acts. Attack AnimPlayer stage flashes remain out of scope. Wild: no trainer bubbles.
4. **A4 — Trainer OW sprite:** When NPC has no walk sprite, omit right human rather than inventing art.
5. **A5 — Canvas size:** Start at 640×360; adjust within Renderer max if e2e looks wrong.

---

**Approval gate:** Reply **approve** (or request changes). No production code until then.
