# Plan — Persistent character selection, offline picker row, portrait previews

| Field | Value |
| --- | --- |
| Date | 2026-08-05 |
| Source | /implement request (this conversation) |
| Config | AGENTS_CONFIG.yml (quality preset) |
| Branch | feature/new-char-selection |
| Base SHA | 99a56f72cc3685d79e01333232881a733768d7f1 |
| Mode | **Autonomous** — the grill gate (Phase 2) and plan-approval gate (Phase 3) were bypassed because the session runs unattended; every unresolved question is logged in §8 as an explicit assumption. |

## 1. Objective & success criteria

Three player-facing changes, one release (0.6.3 → 0.7.0):

1. **The chosen character survives disconnecting.** Leaving a game (deliberately or by a
   dropped transport) no longer restores the vanilla trainer; the player keeps wearing the
   character they picked, in the overworld, in battle pics and on their own trainer card.
2. **A third MMO-menu row, below HOST GAME and JOIN GAME, selects the character.** It works
   fully offline, applies the look immediately, and the choice persists in the save (it
   already writes `mod.save:set("sprite")` — the row makes that reachable without starting
   a host/join flow).
3. **The character picker shows each character's 16×16 frontal portrait to the left of its
   name**, reusing `Chars.portrait` exactly as the trainer card and leaderboard do.

Success = headless suite green (incl. flipped disconnect assertion), modkit
validate/lint/pack clean, both e2e drivers green with a new "look survives leaving" and
"offline picker" assertion, stale screenshots regenerated.

## 2. Context & constraints (grounded)

- The *choice* already persists per-save: `Client.spriteChoice()` reads
  `mod.save:get("sprite")` with a fallback to the global `mod.options:get("sprite")`, then
  `Chars.resolve` (src/Client.lua:549-555). `setSpriteChoice` validates via
  `Chars.available` and writes the save field (src/Client.lua:557-562).
- What reverts is the *worn look*: `M.disconnect()` calls `M.restoreLook()` first thing
  (src/Client.lua:872-873), and `M.wornLook()` (src/Client.lua:768-771) is nil unless
  `lookOwner` is set, which gates the `player.sprite` battle-pic hook
  (src/Client.lua:1428-1432). Offline = vanilla everywhere, by design until now.
- Stash safety: `applyLook` pins `originalLook` to `lookOwner` (the entity it came from)
  and only re-stashes when the entity changed (src/Client.lua:710-731); `restoreLook` only
  writes back onto the same entity (751-759). `refreshLook` re-wears on `map.entered`
  (746-749, wired at 1447-1450). This machinery stays; only the policy around it changes.
  (Fleet knowledge: the engine reuses one player entity across map changes — never
  re-stash on map.entered; keep the lookOwner keying intact.)
- `save.loaded` → `M.leave()` (src/Client.lua:1486): CONTINUE/title-load tears the session
  down. The new save may hold a *different* sprite choice.
- Menu: HOST/JOIN rows live in the not-connected `else` branch of SCREEN.MAIN
  (src/Ui.lua:762-779); the house row pattern is
  `items[#items+1] = { label=..., onSelect=function() mod.ui.push(game, SCREEN.X, {...}) end }`.
- Picker: SCREEN.CHARPICK (src/Ui.lua:840-862) lists `Chars.list()`, calls
  `client:setSpriteChoice(item.value)` on choose, always returns to SCREEN.CHARSET.
  It is already draw-wrapped once by `markOwnCharacters` (src/Ui.lua:179-205) with the
  pure exported rule `Ui.markedRows` (160-174) for headless tests. `mod.ui.ListMenu` (the
  engine widget) has **no per-row icon seam** — decoration must be a draw-wrap; row
  geometry is `y = 8 + row*16`, 16px rows.
- Portraits: `Chars.portrait(id)` returns a cached `{image, quad}` of the 16×16 front
  frame or nil (src/Chars.lua:114-136); the leaderboard draws it at 1× per 16px row
  (src/Ui.lua:535-539) — the exact pattern the picker rows need.
- Wire: no protocol change. `sendHello` reads `M.spriteChoice()` fresh at connect
  (src/Client.lua:851-870); `Wire.spriteId` sanitises inbound (src/Wire.lua:112-123).
- The suite pins the *old* behavior: "disconnecting puts the trainer back"
  (tests/rby_mmo_test.lua:4221-4224) — must flip with the feature.
- E2e: `run-mmo-e2e.sh` configures each side's sprite via generated `options.lua`
  (`MMO_HOST_SPRITE`/`MMO_GUEST_SPRITE`); `mmo_util.lua` has `H.playerSheet(game)` to
  assert the *rendered* sheet by object identity, and screen-push-by-id + screenshot
  helpers. Screenshots under docs/screenshots are regenerated from e2e runs.
- Environment: tests run from a **private engine view** (never repoint the shared
  `gen1recomp/mods/rby_mmo` symlink); `luajit`/`node` at `/opt/homebrew/bin`; `love` at
  `/Applications/love.app/Contents/MacOS/love`; e2e needs `.env` copied from
  `~/Projects/alamops/RBYMMOMod/.env`; run-mmo-e2e exceeds the 10-min bash limit → run in
  background and poll for `^  RESULT:`. Touching src/Client.lua obliges running **both**
  e2e drivers (mmo + hub).

## 3. Approach & key decisions

1. **The worn look follows the standing choice, always.** New policy function
   `M.syncLook()` in Client.lua: if an *explicit* choice exists → `applyLook`; else →
   `restoreLook`. An explicit choice exists when `mod.save:get("sprite")` is a non-empty
   string, or the global option differs from `Config.DEFAULT_SPRITE`. Rationale: players
   who never touched the mod keep the untouched vanilla renderer (no silent
   renderer swap for everyone), and picking RED explicitly still wears RED harmlessly.
2. **`disconnect()` calls `syncLook()` instead of `restoreLook()`.** One teardown path
   covers leave/stopHosting/dropped transport (that unification is deliberate house
   history — keep it).
3. **`setSpriteChoice` itself syncs the look** after a successful write. Both the CHARSET
   flow and the new offline row get immediate wear for free; UI stays thin. Signature
   unchanged.
4. **`refreshLook` gate widens**: re-wear on map.entered when already wearing, in a game,
   *or an explicit choice exists* — this is what wears the look when a save spawns in
   offline. `save.loaded` handler becomes `M.leave(); M.restoreLook(); M.syncLook()` —
   drop the old save's stash (guarded by entity identity, so a torn-down world is a no-op)
   and adopt the loaded save's choice (applyLook may fail before the world exists; the
   widened refreshLook catches it on first map.entered).
5. **`wornLook()` unchanged mechanically** — it already answers from `lookOwner`, which
   will now be set offline too, so battle pics and the own trainer card follow. This is
   the *intended* behavior change ("keep their char in place, even disconnected").
6. **Menu row `CHARACTER`** in the offline `else` branch, third under HOST/JOIN, pushing
   SCREEN.CHARPICK with a new opt so cancel/choose return to SCREEN.MAIN instead of
   CHARSET. Reuse the existing screen rather than a new one (house pattern: PROFILE
   reuse via opts).
7. **Previews via a second draw-wrap** on CHARPICK (layered like `markOwnCharacters`,
   or merged into one wrap — implementer's call), drawing `Chars.portrait` at 1× in each
   row, with a pure exported helper `Ui.previewRows(menu)` (shape `{row, y, id}` pairs)
   for headless assertions. Labels get indented to open a 16px gutter (e.g. two-space
   prefix or the widget's label offset if one exists — implementer inspects the engine's
   ListMenu.lua); the own-char marker must remain visible (may relocate). nil portrait
   (no ROM import) degrades to the indent with no art — never an error.
8. **No wire change, no new permission, no PR-#14 JSON file.** `mod.save` semantics match
   the ask ("persist on saves"); durability beyond the engine's save cycle is explicitly
   out of scope (§8 A2).

## 4. Work breakdown — implementation (Wave 1, runner: claude/opus)

- **T1 — Client look policy.** Owns **src/Client.lua** only.
  Implement §3 items 1–5: `explicit choice` predicate, `M.syncLook()`, disconnect swap,
  setSpriteChoice side effect, refreshLook gate, save.loaded handler. Keep
  lookOwner/originalLook keying intact. No bare error/assert; failures log via
  `mod.log:warn` with remediation. Acceptance: disconnect keeps look iff explicit choice;
  no choice → teardown restores; save.loaded adopts the new save's choice.
- **T2 — Ui row + previews.** Owns **src/Ui.lua** only.
  Implement §3 items 6–7. CHARACTER row below JOIN GAME (offline branch only); CHARPICK
  back-target opt (default unchanged: CHARSET); portrait gutter + `M.previewRows` pure
  export; reconcile with markOwnCharacters. Relies on contract: `client:setSpriteChoice(id)`
  (unchanged signature) now applies the look itself — the row adds no look calls. Update
  the "deliberately no third row" comment (src/Ui.lua:780-786) so it doesn't contradict
  the new row (it argued against a *join-code* row; keep its point, scope it).
- **T3 — Release metadata.** Owns **manifest.json, CHANGELOG.md, README.md, mod.card**.
  Version 0.6.3 → 0.7.0 everywhere it must match; CHANGELOG `## [0.7.0] - 2026-08-05`
  with player-facing Added/Changed prose (keep-look-on-leave is a behavior *change* —
  say so); README section + mod.card features bullet (and a limitations note: a peer on
  an older mod copy still sees RED for mod-owned chars; vanilla chars need the ROM).

No two tasks share a file → valid single wave.

## 5. Work breakdown — tests (Phase 6, runner: claude/sonnet)

- **T4 — Headless suite.** Owns **tests/rby_mmo_test.lua**.
  Flip tests/rby_mmo_test.lua:4221-4224 to the new rule; add: keep-on-disconnect with
  explicit choice; restore-on-disconnect without one; offline wear via widened
  refreshLook; save.loaded re-sync across saves with different choices; setSpriteChoice
  applies immediately; `Ui.previewRows` rule (scroll, cursor-independence, nil-portrait
  degrade); MAIN menu offline branch contains a CHARACTER row that pushes CHARPICK.
  Follow the existing stub/IIFE idioms in the applyLook section (4168-4258).
- **T5 — E2e drivers + screenshots.** Owns **tests/drivers/*, docs/screenshots/*,
  .modkitignore (only if a new screenshot is added)**.
  Add a leg asserting the guest (or host) still wears the chosen sheet **after leaving**
  (`H.playerSheet` identity check post-`leave()`); add an offline-picker leg (push
  SCREEN.MAIN by id, walk to CHARACTER, or push CHARPICK directly per the
  shotTrainerCard precedent) asserting the choice + look apply offline; regenerate stale
  screenshots: `mmo-menu.png` (new row) and `character-picker.png` (portraits);
  two-tier assertions (unconditional resolve + conditional-on-worn-character), per the
  PR #12 pattern.

**E2e applies** (user-visible flow, two live instances). Run recipe (Phase 7):
private engine view per §2; `PATH=/opt/homebrew/bin:$PATH`; copy `.env` from the main
checkout; `bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh` in background, poll log for
`^  RESULT:`; also `node server/hub.test.js` and `run-hub-e2e.sh` (Client.lua touched →
both transports; kill stale listener on 7799 first).

## 6. Execution waves

1. Wave 1: T1 ∥ T2 ∥ T3 → checkpoint commit.
2. Phase 5: code review (opus) on `git diff 99a56f7...HEAD`.
3. Phase 6: T4 ∥ T5 (file-disjoint) → checkpoint commit.
4. Phase 7: test run (haiku): headless suite, T4 tier, modkit validate/lint/pack,
   hub node suite, both e2e drivers.
5. Phase 8: fix loop (opus), re-run, cap 3 rounds.

## 7. Blast radius & risks

- `wornLook()` now non-nil offline → the `player.sprite` hook decorates battle/card pics
  in single-player when a mod char is worn. Intended, but it widens where Cast pics draw;
  vanilla ids still return nil from `Cast.pic` so vanilla saves are untouched.
- Default-choice players must see zero change (no renderer swap): guarded by the explicit-
  choice predicate; T4 must pin this.
- `affects_link` stays false — none of this touches link registries; the suite's
  byte-identical link-surface assertion must stay green.
- The e2e drivers configure sprite via `options.lua` (global fallback) — that path still
  works; new legs must not break the existing sprite hand-off assertions
  (`MMO_EXPECT_GUEST_SPRITE` in mmo_host.lua:325).
- Screenshots: only regenerate the stale ones; each committed shot stays listed by name
  in `.modkitignore` with the why-comment.

## 8. Open questions / assumptions (autonomous mode)

- **A1** "Persist on saves" = the existing `mod.save` field semantics (tied to the
  engine's save cycle). A pick made and never saved is lost with the rest of the unsaved
  game — consistent with every other save field. The PR #14 belt-and-braces JSON file is
  *not* replicated for the sprite.
- **A2** The look is worn offline **only when an explicit choice exists** (save field
  set, or global option ≠ default). Players who never used the mod see zero change.
- **A3** Row label is `CHARACTER` (matches the CHARPICK screen title and house all-caps
  labels). Placed only in the offline branch; while connected, the picker stays
  unreachable (changing chars mid-game is out of scope — the hub only learns the sprite
  at hello).
- **A4** Preview scope is the CHARPICK list only (the ask: "left side of the char name").
  The CHARSET "LOOK" row keeps its text-only `right` value.
- **A5** Version bump is minor (0.7.0): user-visible feature + behavior change.
