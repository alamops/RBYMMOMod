> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — NIRE back sprite loses pixel-perfect ratio in classic view

| Field | Value |
| --- | --- |
| Date | 2026-08-05 |
| Source | Player report (Mirasein) relayed by owner: "Any way to fix my back sprite on the classic view? It seems that pixels are losing perfect ratio" |
| Config | AGENTS_CONFIG.yml (quality preset) |
| Branch | fix/nire-pefect-ratio |
| Base SHA | 99a56f72cc3685d79e01333232881a733768d7f1 |
| Mode | **Autonomous** — grill and plan-approval gates bypassed; assumptions logged in §8 |

## 1. Objective & success criteria

The battle back pic of the mod's own characters (NIRE, NIRE HOOD — 48x48 original
art) must render with uniform, square pixels in the engine's plain ("classic")
battle view. Success: every source pixel of `back.png` maps to an identical NxN
block on the 160x144 canvas; headless suite green; e2e driver green.

## 2. Context & constraints (Phase 1 findings)

- The mod registers `battle_sprite_scales` entries `rby_mmo_nire_back` /
  `rby_mmo_nire_hood_back` with `scale = 64/48 ≈ 1.3333` (`src/Config.lua:249-254`
  via `src/Cast.lua:115-140`), chosen at introduction (commit 98bf16e) purely to
  keep vanilla's 64px on-screen footprint so the trainer doesn't stand in the
  text box.
- Engine (`gen1recomp` dev): `BattleState.resolveBattleScale`
  (`src/battle/BattleState.lua:4671-4695`) returns the registered value **raw**
  — image-level → species-level → default (`back = 2`). The classic/flat battle
  draw (`BattleState.lua:4786-4832`) feeds it straight into
  `love.graphics.draw(img, …, s, s)` on a nearest-neighbor canvas.
- A non-integer scale under nearest-neighbor maps source pixels to a mix of
  1-wide and 2-wide destination pixels — exactly "pixels losing perfect ratio".
- The engine's alternate 3D view (`mods/dramatic_shape/lib/OverworldBattle.lua:812-828`)
  **already rounds every battle scale to the nearest integer** ("a
  battle_sprite_scales entry that asks for 1.7x would … resample the sprite into
  mush"), so 1.333 → **1** there. The bug is classic-view-only because only the
  classic path uses the raw value.
- `backPlacement` pins feet at y=96 for any scale/size (`BattleState.lua:4696-4704`,
  dynamic transparent-padding scan) — no 32x32 assumption; any integer scale is safe.
- Schema allows 0.25–4.0, non-integers included (`src/mods/Schemas.lua:939-962`);
  the registry key must byte-match the hooked path (it does today).
- Tests currently pin the *fractional* behaviour: `tests/rby_mmo_test.lua:208-220`
  asserts `1 < scale < 2`; `:2950-2958` asserts `scale * 48 ≈ 64`.
- 48x48 back art is the mod's published character-sheet template (Mirasein's own
  sheets follow it), so changing the art contract would break player art.

## 3. Approach & key decisions

**Fix: integer back scale.** Set `backScale = 1` for both characters and snap any
non-integer scale defensively in `Cast.installScales`.

- No integer scale reproduces the 64px footprint from 48px art (48·1=48, 48·2=96).
  Re-authoring art at 32x32@2x loses the "half again the detail" intent; 64x64@1x
  breaks the 48x48 template players already draw against; 2x stands in the text
  box (rejected at introduction). `1` is the only choice that keeps the art
  contract, keeps out of the text box, and is pixel-perfect. (Evidence-based:
  engine draw path read directly; not spike-tested — see §8.)
- **Consistency bonus:** the 3D view already rounds 1.333 → 1, so players there
  already see the 48px back pic. This fix makes classic view match, instead of
  the two views disagreeing.
- **Defensive snap:** `installScales` rounds a non-integer `backScale` to the
  nearest integer ≥ 1 and `mod.log:warn`s with remediation, mirroring the
  engine's own `dramatic_shape` precedent — a future character entry cannot
  silently reintroduce the artifact. Loader rules: warn-with-remediation, never
  throw.
- Version: patch bump 0.6.3 → 0.6.4 (cosmetic fix; no wire, no link surface;
  `affects_link` untouched — `battle_sprite_scales` is not a link registry).

## 4. Work breakdown — implementation tasks

- **T1** (wave 1, opus): apply the fix.
  Owns: `src/Config.lua`, `src/Cast.lua`, `manifest.json`, `CHANGELOG.md`.
  - `Config.lua`: `backScale = 1` for both chars; rewrite the comment block
    (`:244-248`) to state the integer constraint and why (classic view draws the
    raw scale nearest-neighbor; the 3D view already rounds; 64/48 was the bug).
  - `Cast.lua`: in `installScales`, snap non-integer scales to
    `math.max(1, math.floor(scale + 0.5))` with a `mod.log:warn` naming the char
    and the remediation ("use a whole number in Config.OWN_CHARS.backScale");
    update the header comment (`:105-114`).
  - `manifest.json`: version 0.6.4. `CHANGELOG.md`: 0.6.4 Fixed entry.
  Acceptance: registered scale for both chars is exactly 1; a hypothetical
  fractional entry would be snapped and warned.

## 5. Work breakdown — test tasks

- **T2** (sonnet): update + extend the suite. Owns: `tests/rby_mmo_test.lua`.
  - Update `:208-220` (`1 < scale < 2`) and `:2950-2958` (`scale*48 ≈ 64`) to
    pin scale == 1 exactly, and keep the on-screen-height assertion (48·1 = 48 < 96
    text-box top → never stands in the text box).
  - New: every registered `battle_sprite_scales` entry has an integer scale
    (`scale % 1 == 0`) — the regression the report was about.
  - New: `installScales` snap path — a stubbed char with `backScale = 64/48`
    registers scale 1 and emits a warn (use the existing `stubScales` idiom).
- **E2e:** applies (real rendering is the bug surface). Existing driver
  `tests/drivers/run-mmo-e2e.sh` exercises battle/back-pic resolution; run it
  unchanged from a **private engine view** (never repoint the shared symlink;
  copy `.env` from `~/Projects/alamops/RBYMMOMod/.env`; `luajit`/`node` need
  `/opt/homebrew/bin` on PATH; `SHOT_DIR` moved into the scratchpad). E2e runs
  from the main session, not a subagent (background children are reaped).

## 6. Execution waves

Wave 1: T1 → checkpoint commit → Phase 5 review (opus) → wave 2: T2 →
Phase 7: headless suite + T4 via haiku runner; e2e by orchestrator. No
same-wave file overlap anywhere.

## 7. Blast radius & risks

- NIRE/NIRE HOOD back pic shrinks on screen from 64px (uneven) to 48px (crisp)
  in classic view; 3D view unchanged (already 48px). Cosmetic-only; no wire
  format, roster, or link-fingerprint impact.
- Tests that pinned the old arithmetic will fail until T2 lands (expected;
  sequenced in the same delivery).
- Players who drew 48x48 art against the template are unaffected — the template
  stays 48x48.

## 8. Open questions / assumptions (autonomous mode)

1. **Assumed** the owner prefers a smaller pixel-perfect back sprite (48px) over
   re-authoring art to 64x64@1x to keep the 64px footprint. If the size regression
   is unacceptable, the follow-up is an art task (64x64 back pics) — the code
   after this fix (integer snap) already supports it: re-export art, set
   `backScale = 1`, done.
2. **Assumed** Mirasein's "chars" are template-conformant (their sheets show
   48x48 backs), so the config/template fix covers them without shipping their art.
3. Not spike-tested: the uneven-pixel mechanism is asserted from reading the
   engine draw path (raw scale, nearest canvas), which two independent readers
   confirmed; e2e will visually verify the fix.
