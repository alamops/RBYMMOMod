# Plan — Better battle UI: arena HUD, sprite facing, trainer color, animations

| Field | Value |
| --- | --- |
| Date | 2026-08-12 |
| Source | /implement request: "review the gen1 field battle UI, use HUD and a modern UI, flip left-side pokemon to look right, fix the trainer chars, fix the animations" |
| Config | AGENTS_CONFIG.yml (quality preset, host=claude_code) |
| Branch | feature/better-battle-ui |
| Base SHA | 201ca00 |
| Mode | **Autonomous** — the grill and plan-approval gates were bypassed (owner unreachable mid-run). Every unknown is resolved as a logged assumption in §8. |

## 1. Objective & success criteria

Polish the day-old top-down battle arena (`src/Battlefield.lua`, commit `201ca00`) that Gen1
CoopBattle and MediatedBattle draw through:

1. **Left-seat (ally) mons face right** toward their opponent via horizontal flip; foe seats
   unchanged.
2. **Trainer figures render colored** (not DMG grayscale) with correct alpha, both sides.
3. **A modern persistent HUD** on the arena: per-side plates with name, level, HP bar
   (color-thresholded), status — visible during normal play, not only in the target card.
4. **Animations stop looking poor**: HP bars drain over time (two-clock model), fainting mons
   sink/fade instead of vanishing, attackers lunge, defenders flash, damaging hits nudge the
   field. All deterministic, frame-based, soft-fail.

Verified by: mod suite green (baseline 3082/3082), new unit assertions, a committed battlefield
screenshot driver whose pixel checks prove trainer color + ally flip, and a full
`run-mmo-e2e.sh` pass.

## 2. Context & constraints (spike-verified)

- **Mon flip gap (measured):** `placeMons` computes `facing` ("right" for ally, "left" for foe)
  and stores `side` (src/Battlefield.lua:253-258), but `drawMonIcon` (:613-668) never reads it —
  both seats draw the identical unflipped front pic. Confirmed visually by spike screenshot
  (`spike-shots/battlefield-idle.png`).
- **Trainer grayscale root cause (measured):** `resolveHumanSheet` (:467-517) uses
  `SpriteRenderer:resolveImage()`, which in default color modes returns the walk sheet in raw
  DMG shades by design, expecting the whole-canvas zone shader to recolor it
  (engine `src/render/SpriteRenderer.lua:249-255`). MediatedBattle registers a full-canvas
  `colors = false` zone opt-out (src/MediatedBattle.lua:2711-2728) to protect the pre-baked
  true-color mon pics — which also strands trainer sprites in grayscale. Spike crops confirm
  zero saturation on both trainers while mons/arena are colored.
- **Trainer facing already correct:** `drawHuman` (:519-553) flips frame 2 (stand-left) with
  negative x-scale for `facing == "right"` — matches engine convention
  (`SpriteRenderer.STAND = {down=0, up=1, left=2, right=2}`, right = flipped left).
- **No arena HUD exists:** `drawEnemyHUD`/`drawPlayerHUD` run only on the classic 160×144 path
  (src/MediatedBattle.lua:2989-2991); the battlefield path draws no HP/name/level at all outside
  the transient target card (`drawCard`, src/Battlefield.lua:684-742).
- **Animation gaps:** battlefield path skips AnimPlayer entirely
  (src/MediatedBattle.lua:2543-2547 — a **locked** v1 decision in
  `docs/plans/coop-battlefield-layout.md`, do not port AnimPlayer); MediatedBattle snaps HP
  instantly (`noteSlot`/`syncMineHp`, :1614-1657) unlike CoopBattle's `startDrain`/`stepDrain`
  (src/CoopBattle.lua:2972-3073) and the engine (maxHP/96-per-frame steps); faint just nils the
  sprite (`releasePic`, :2576-2582). Only `iconBob` exists as an arena animation primitive.
- **Settled decisions honored** (from prior plans — do not re-litigate): front sprites for field
  mons (never bag icons); uniform scale only, integer-preferred (never stretch);
  `battle_sprite_scales` entries must be whole numbers; walk-sheet humans (no invented art —
  omit humans with no sheet); two-clock HP model (`hp` = sim truth instant, shown HP =
  display-only, advances through the message queue); victory music queued after drains/faints;
  no engine tween/shake library exists — the mod writes its own; `battle_anims`/`battle.overlay`
  are vanilla-loop-only and unusable here.
- **Engine flip idiom:** `love.graphics.draw(img, x + w*scale, y, 0, -scale, scale)` (right-edge
  anchored negative x-scale) — used by engine SummaryMenu and Battlefield's own `drawHuman`.
- Everything soft-fails (`pcall`) and must stay headless-safe (plain LuaJIT suite has no
  `love.image`/`love.graphics`).

## 3. Approach & key decisions

- **All presentation fixes live in `Battlefield.lua`**; MediatedBattle only feeds it state.
  CoopBattle inherits the flip, trainer color, and plates for free (both flows call
  `Battlefield.draw`). (Spike-backed for the two bugs; reasoning for the rest.)
- **Mon flip:** extract a pure, exported helper `M.monDrawParams(mon, iw, ih)` returning
  scale/position/flip so the decision is unit-testable headlessly; `drawMonIcon` consumes it.
  Flip when `mon.facing == "right"`. Applies to both the front-pic path and the icon-quad
  fallback path. Classic 160×144 back pics untouched (series convention — back art is distinct
  art, never mirrored front art).
- **Trainer color:** bake color into the sheet at `resolveHumanSheet` time, ranked by fidelity,
  every rung pcall-guarded and headless-safe (fall through to the current behavior when
  `love.image` is absent):
  1. If the engine already returns a colored image (true-color record, GBC pack active), keep it.
  2. Otherwise resolve per-sprite OBJ colors the way the engine itself would
     (`PaletteFX.spriteObp(record, seed)` / `record.paletteSource` via `GbcPalette`) and bake
     with the same shade→color + white→alpha mapping as the engine's `getObpImage`.
  3. Last resort: keep the DMG bake (today's look) — never a hard failure.
  The builder verifies the exact PaletteFX surface against the engine checkout
  (~/Projects/alamops/gen1recomp/src/render/PaletteFX.lua) and mirrors it in mod code rather
  than requiring deep engine internals beyond the already-established
  `SpriteRenderer`/`Assets` pattern.
- **Modern HUD:** two persistent plates in the visual language of the existing target card
  (rounded white panel, thresholded HP bar): ally plate bottom-left of the field (above the
  menu band), foe plate top-right. Name, `L%d`, HP bar, status chip; exact `hp/maxHp` numbers
  on the ally plate only (classic convention). Plates read `seat.shownHp or seat.hp` so the
  drain clock animates them. GB menu band stays as-is (familiar, tested; modernizing input
  menus is out of scope — §8 A2).
- **Animation model — battle owns time, Battlefield owns pixels:** MediatedBattle advances
  effect timers in `update(dt)` and passes `ctx.fx`, a list of
  `{kind, side, seatIndex, t}` with `t` in 0..1
  (`kind ∈ lunge | flash | shake | faint | spawn`). Battlefield renders each kind as a pure
  function of `t`: lunge = eased offset toward the midline and back; flash = white tint pulse
  on the defender; shake = small field offset (damaging hits); faint = sink + alpha fade;
  spawn = scale-up pop on send-out/switch. Deterministic, no wall-clock, unit-testable.
- **HP drain (two-clock):** per-seat `shownHp` advancing toward `hp` at the engine-familiar
  rate (max(1, maxHp/96) per frame), sequenced through the existing message queue so drains
  finish before faint/victory text — mirroring `coop-battle-hp-sequencing.md` and
  CoopBattle's implementation. Faint sequence: drain to 0 → faint fx (sink/fade) → "fainted!"
  text → clearPic.
- **Alternatives rejected:** porting AnimPlayer to the arena (locked decision, heavy);
  drawing HUD via engine HudTiles on the arena (GB tiles fight the modern look; card idiom
  already exists); flipping via pre-flipped ImageData copies (negative x-scale is the
  established idiom and free).

## 4. Work breakdown — implementation

Contract shared by T1/T2 (pinned here so the wave can run parallel):
seat records gain optional `shownHp` (number, display clock; renderers fall back to `hp`);
`ctx.fx` = array of `{kind="lunge"|"flash"|"shake"|"faint"|"spawn", side="ally"|"foe",
seatIndex=<1-based>, t=<0..1 progress>}`; Battlefield must tolerate `ctx.fx` absent/empty
(CoopBattle passes none today).

- **T1 — Battlefield presentation** (owns `src/Battlefield.lua` ONLY)
  Mon flip via exported pure `M.monDrawParams`; trainer color bake in `resolveHumanSheet`
  (ranked options above); persistent ally/foe plates (new `drawPlate` + exported pure
  `M.plateModel(seat)` for tests); fx rendering (`lunge/flash/shake/faint/spawn` as pure
  functions of `t`; shake offsets the whole field layer); keep every draw pcall-wrapped and
  headless-safe. Acceptance: exported helpers return flip=true only for facing=="right";
  plates render from seat data alone; no behavior change when `ctx.fx` is absent.
- **T2 — MediatedBattle state & sequencing** (owns `src/MediatedBattle.lua` ONLY)
  Two-clock `shownHp` (init on upload/send, step in update at max(1, maxHp/96)/frame, queue-
  sequenced before faint/over text per hp-sequencing doc); faint fx before `clearPic`; emit fx
  on move start (attacker lunge), on damage application (defender flash + field shake), on
  send/switch (spawn); extend `battlefieldSeat`/`battlefieldCtx` to carry `shownHp` + `ctx.fx`;
  hold anim/message dwell long enough for fx to read (reuse existing `MSG_MIN_DWELL`/anim hold
  — do not lower it). Victory-music-after-drain ordering (#36) must be preserved. Acceptance:
  headless state-machine tests can drive damage→drain→faint and observe shownHp stepping and
  fx lifecycles.

Wave 1 = T1 + T2 in parallel (disjoint files, contract pinned above).

## 5. Work breakdown — tests

- **TT1 — unit suite** (owns `tests/rby_mmo_test.lua` ONLY): assertions for
  `monDrawParams` (ally flip / foe no-flip / icon-quad path), `plateModel`, fx `t` math
  (pure renders don't throw headless), MediatedBattle shownHp drain stepping + sequencing
  (drain completes before faint text), fx emission on damage/send events, trainer-sheet
  color-path selection degrading gracefully headless. Covers T1+T2.
- **TT2 — e2e screenshot driver** (owns `tests/drivers/battlefield_shot.lua` (new) +
  `tests/drivers/run-battlefield-e2e.sh` ONLY): a committed, clean rewrite of the spike driver
  (proper stub with save/options/exports so spriteIds resolve — no monkey-patching); captures
  idle + move + faint frames to `SHOT_DIR`; pixel-asserts (ImageData sampling): trainer crop
  regions contain saturated (non-gray) pixels, ally-mon region differs from a horizontally
  mirrored foe draw (or asserts via logged `monDrawParams`). Wire into
  `run-battlefield-e2e.sh` as the screenshot hook its header reserves.

E2e applies (user-visible UI): run recipe — private engine view at `<scratchpad>/engine`
(shared `mods/rby_mmo` symlink must NOT be repointed), `PATH=/opt/homebrew/bin:$PATH`,
LÖVE at `/Applications/love.app/Contents/MacOS/love`, `ROM_PATH` from `.env`
(`/Users/alamosaravali/Downloads/ROMs/Pokemon_Red.gb`), `SHOT_DIR` in scratchpad (never the
shared /tmp default), driver invocation
`POKEPORT_DRIVER=... POKEPORT_IDENTITY=bfe2e POKEPORT_TOUCH=0 love .`; full suite:
`luajit mods/rby_mmo/tests/rby_mmo_test.lua` from the view; full MMO e2e:
`bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh` (must run in the foreground of whichever
session owns it — background runs inside a finished subagent get reaped).

## 6. Execution waves

1. Wave 1: T1 ∥ T2 (implementation).
2. Checkpoint: suite run + battlefield screenshot spike re-run to eyeball the four fixes;
   commit.
3. Phase 5 review of the full diff.
4. Wave 2: TT1 ∥ TT2 (tests; disjoint files).
5. Phase 7: full suite + battlefield driver + run-mmo-e2e.sh; Phase 8 fixes to green.

## 7. Blast radius & risks

- `Battlefield.draw` is shared with CoopBattle — plates/flip/trainer color appear there too
  (intended); CoopBattle passes no `ctx.fx`, so fx must be strictly opt-in. Regression risk on
  CoopBattle covered by existing layout asserts (tests/rby_mmo_test.lua:11261-11287) + suite.
- Gen2 and classic 160×144 paths must be byte-identical in behavior (gate at
  src/MediatedBattle.lua:1012-1029 untouched).
- `affects_link` stays false — nothing here touches link registries; the suite asserts the
  link surface is unchanged.
- Trainer color bake touches an engine-internal surface (PaletteFX) — every call pcall-guarded
  with the DMG bake as fallback, so an engine drift costs color, never the screen.
- HP drain changes message sequencing — the #36 victory-music-after-drain fix has suite
  coverage; TT1 re-asserts ordering.
- README/docs screenshots of the arena (if any) go stale — regenerate from the e2e run if the
  battle shots changed (check during Phase 7).

## 8. Open questions / assumptions (autonomous mode)

- **A1:** "gen1 field battle UI" = the top-down Battlefield arena; classic + Gen2 paths
  untouched.
- **A2:** "HUD and a modern UI" = persistent modern seat plates + existing card idiom; the GB
  menu band (commands/moves/message) is retained — replacing input menus is out of scope.
- **A3:** "left side pokemon" = ally seats; flip only on the arena. Classic back pics stay
  unflipped (series convention).
- **A4:** "fix the trainer chars" = the grayscale bug (spike-proven); facing was already
  correct.
- **A5:** Animation scope = lunge/flash/shake/faint/spawn + HP drain; no AnimPlayer port
  (locked decision).
- **A6:** No version bump on this branch (release-time concern; four files carry it).
- **A7:** CoopBattle gets the shared Battlefield improvements but no new fx wiring this pass —
  logged as a follow-up.
- **A8:** 640×360 canvas stays (its own open question in coop-battlefield-layout.md, separate
  thread).

---

# Round 2 — "I want it perfect" (2026-08-12, autonomous)

Owner review of the live UI: shrink the mons a bit; improve the plate/card UI; replace the
stretched GB message box + bottom menus with a modern HUD; make the pokéball animation work
and keep every animation chronological; make sure all trainers face correctly; redesign the
trainer speech bubble. **Overturns round-1 assumption A2** (GB band kept) — the band goes
modern on the battlefield path; classic 160×144 and Gen2 keep GB chrome untouched.

## R2 findings (scout-verified)

- The band is a duplicated twin: MediatedBattle `withMenuBand`/`drawBattlefieldMenus`
  (src/MediatedBattle.lua:1384-1410, :3323-3373) and CoopBattle `drawMenuBand`/
  `drawMenusClassic` (src/CoopBattle.lua:4668-4721) both re-project the classic 20×6 tile
  box — the visible "stretch" (160→640 is 4× horizontal vs ~1.67× vertical).
- Ball throws render NOTHING on the arena in both flows: mediated's `playMoveAnimFallback`
  finds no move for `TOSS_ANIM`/`SHAKE_ANIM` rows; coop starts AnimPlayer with
  ball/shake opts (src/CoopBattle.lua:4944-4950) but `drawBattlefieldSafe` never calls
  `drawAnim`. Wire order per throw: item(ball) → HIDEPIC → TOSS → SHAKE×N(amount) →
  [SHOWPIC + "broke free" | over(reason=catch) + "Gotcha!"] — already queue-ordered.
- Latent coop bubble bug: TOSS/SHAKE anim rows aren't excluded from `noteBattlefieldBubble`
  (src/CoopBattle.lua:4899-4901) — would print "used TOSS_ANIM!".
- CoopBattle has no ctx.fx wiring at all (no flash/shake/lunge/spawn on the arena); its
  queue architecture was ordered from day one, so wiring fx at startDrain/startAnim is safe.
- Letterbox leak (coop only): `letterboxWhite = true` (src/CoopBattle.lua:4310) vs
  mediated's deliberate black, plus coop's missing full-canvas fill before Battlefield.draw.
- Trainer facing/darkness: frame conventions and palette plumbing are CORRECT (verified by
  pixel extraction — frame 2 is stand-left in nire sheets too; spriteObp resolves group 0).
  The defect is the assets: assets/chars/nire*/walk.png carry ~9 gray tones instead of the
  exact 4 DMG shades, so >50% of opaque pixels bin darkest and NIRE renders near-black
  (which also *reads* as facing wrong). Fix: re-quantize the sheets to exactly
  (0,0,0)/(85,85,85)/(170,170,170)/(255,255,255); audit front.png/back.png the same way.
- Fonts: adopt the established `Toast.font(size)` pattern (Rajdhani TTF, per-size cache,
  linear filter, graceful fallback) for all Battlefield text; today plates/bubbles inherit
  whatever font is coincidentally active.

## R2 contract (pinned)

- `M.MON_DRAW` 72 → 60.
- fx kinds extended: `ball` (arc, thrower side → target seat), `wobble` (rock at target;
  one fx per SHAKE row), `poof` (materialize/burst), `recall` (shrink+fade on HIDEPIC).
  Same `{kind, side, seatIndex, t}` shape; battle advances t; renderers pure. The pokéball
  is drawn as ORIGINAL vector art (circles/band/button) — no ROM pixels.
- Band widget API in Battlefield (both battles consume it on the battlefield path only):
  `M.drawMessagePanel(text)`, `M.drawCommandGrid(items, cursor)` (items:
  `{label, disabled?}`), `M.drawListPanel(rows, cursor, opts)` (rows:
  `{label, right?, dim?}`, opts: `{title?}`). All render inside MENU_BAND, pcall-safe,
  headless-safe, Toast-font with default-font fallback.
- Bubble ctx entries gain optional `{moveName}`; renderer emphasizes the move line.
- Visual language: dark translucent slate panels (~rgba 20,24,32,0.85), 1px light border,
  rounded corners, drop shadow; white primary text, muted secondary; HP bars keep
  green/yellow/red thresholds with rounded caps; colored status chips (PSN/BRN/SLP/PAR/FRZ).
  Plates, target card, band widgets and bubbles share it. (Assumption R2-A1: dark modern
  HUD; the old plates were plain white.)

## R2 waves

- **A1** src/Battlefield.lua — scale, font adoption, plates/card v2, bubble v2, ball/wobble/
  poof/recall renderers, band widgets.
- **A2** src/MediatedBattle.lua — switch battlefield menus to band widgets (moves list gains
  PP), emit ball-flow fx from the queued anim rows (hold each row for its fx), bubble
  moveName, keep classic path byte-identical.
- **A3** assets/chars/nire*/ — re-quantize walk sheets (+front/back if dirty) to exact DMG
  shades. (Routed to a sonnet runner — mechanical; orchestrator override per config.)
- **B1** src/CoopBattle.lua (after A) — adopt band widgets; letterbox fix (white → black on
  the battlefield path + full-canvas fill); wire ctx.fx (flash/shake at startDrain, lunge on
  move anims, spawn on POOF, ball flow from its anim rows); exclude TOSS/SHAKE from bubbles;
  pass shownHp explicitly.
- **C** tests + screenshot driver update (drive NIRE, capture band/bubble/ball frames).
- Review → fixes → full e2e.

Assumptions: R2-A1 dark HUD (above); R2-A2 mon box 60px ("a bit" smaller); R2-A3 no version
bump this branch; R2-A4 recall visual added for chronology completeness (HIDEPIC row).

---

# Round 3 — owner playtest feedback (2026-08-12)

Live-play findings from the owner, with root causes established:

1. **NIRE faces the wrong way (owner-diagnosed, pixel-confirmed).** The nire/nire_hood
   walk sheets were authored MIRRORED vs engine convention: the stand-left slot (frame 2)
   contained a right-facing pose (RED's faces left). Fixed at the asset level — frames 2
   (stand-left) and 5 (walk-left) flipped horizontally in both sheets; overworld facing
   fixed too. Round-1 scout's "visually confirmed left-facing" was wrong.
2. **Second ally human renders above the arena** — the recurring "letterbox sprite" in
   every coop shot was placeHumans' multi-human band placing seat 2 outside the field.
   Fix: humans vertically centered on the field, stacked seats inside it (owner also
   asked for trainers "more on vertical center" generally).
3. **2-mon sides hug the edges** — seat 1 sits half-clipped at the arena border while
   seat 2 crowds the midline. Fix: pull the pair into their half (roughly 0.18/0.34
   width fractions, mirrored), keep the y stagger, everything fully inside the field.
4. **coop_npc shows no foe trainer** — the NPC fight renders an empty right side.
   Fix in CoopBattle: place a foe-side human for the NPC trainer (sprite resolved from
   trainer class where a mapping exists; generic trainer sprite fallback).
5. **Bubble format** — owner wants "PIKACHU!" / "THUNDERBOLT!": line 1 is the acting
   mon's display name, line 2 the emphasized move, both with exclamation marks; "used"
   dropped. Emitters pass `name`; renderer owns punctuation.

Wave E: E1 Battlefield (2+3+5 renderer), E2 CoopBattle (4 + name emission), E3
MediatedBattle (name emission) — disjoint; then E4 tests/driver; verify suite + driver
+ full e2e (display available).

---

# Round 4 — EXP bar on the ally plates (2026-08-12, autonomous)

Owner ask: an EXP bar as part of the player pokémon card, animating after the
"gained N EXP" message (which follows an opponent faint).

Scout-verified ground truth: exp is COOP-ONLY (mediated has no exp award, no wire
field — Wire.battleMon carries none; assumption R4-A1: plates without expFrac render
no strip, no tri-state). CoopSim emits {kind="exp", slot, species, level, winners};
clients recompute via eng.Experience.apply (mutates mon.exp/level/stats INSTANTLY —
the same value-vs-denominator hazard the HP climb fix at CoopBattle:6194-6205
documents, so the bar reads display clocks only). Fraction math ports the engine's
Gen2 HpBar.expFraction over Growth.expForLevel (grab("Growth","src.pokemon.Growth")
mirroring the existing Experience grab) with data.pokemon[species].growthRate.

Pinned design:
- Battlefield: PLATE_H stays 48 — a taller plate compresses the paired 2v2 ally
  rows below the 60px mon pitch (see Battlefield.lua's constants comment), so the
  3px blue EXP strip (no thresholds) is absorbed into the plate's bottom inset
  under the HP bar. Ally (numbers) plates only — and only the seat whose client
  drives the clock (own mon; partner/foe plates carry no strip). plateModel gains
  optional expFrac + shownLevel (level pill prefers shownLevel).
- CoopBattle chronology (engine-reference order, R4-A2: fills first then text):
  say("gained N EXP") → queued {expfill} row: startExpFill/stepExpFill twin of the
  drain machinery drives battler.shownExpFrac from the pre-award progress through
  each level (fill to 1 → reset to 0 → bump battler.shownLevel → continue) to the
  final fraction → then the existing "grew to level N!"/teach pages → then the HP
  climb drain row. expfill blocks the queue like draining; rows stay ahead of the
  act/fanfare row. Seats carry expFrac/shownLevel from the display clocks, seeded
  at first sight from mon.exp.
- R4-A3: no MediatedBattle changes (static level pill stays; wire/server exp
  pipeline out of scope).

Wave R4-1: Battlefield.lua ∥ CoopBattle.lua (disjoint). Wave R4-2: tests. Then
review → fixes → suite + driver + full e2e.

---

# Round 5 — exp in mediated battles ("apply to all cases", 2026-08-12, autonomous)

Owner: extend the EXP bar/progression to mediated battles. Scout-verified ground:
the hub holds NO ROM species table (Wire.lua:1277-1284, locked legal floor) — the
referee can never compute exp amounts. Design (mirrors coop + the vitamin/catch
trust precedents): the referee emits FACTS after a faint — {kind="exp", slot,
species, level, participants} one event per standing owner-slot winner — and each
client computes its own share (Experience.gainFor) and applies it to its own
game.save.party mon (Experience.apply), mid-battle at event receipt (finish isn't
guaranteed on disconnect/timeout paths; vitamin writeback precedent :732-825).

Pinned decisions / assumptions:
- R5-A1: exp-awarding modes = wild, coop_npc, coop_wild — the modes where vanilla
  awards exp. 1v1 and coop_pvp NEVER emit (mode-gated in the referee, mirroring
  CoopSim's owner-guard) — vanilla link parity + no PvP farming loop.
- R5-A2: Gen1 twins only (BattleSim/Turn.lua + server/lib/battle/Turn.js). The
  Gen2 twins (BattleSim2/battle2) are untouched — Gen2 mediated stays exp-free;
  doubling the twin surface for a classic-rendered path is a separate decision.
- R5-A3: wire field named `participants` (count), NOT `winners` — battleOutcome's
  `winners` is an id-list; same-name-different-shape invites sanitiser bugs.
- R5-A4: the level-up cascade (grew-text, move learning via coop's teach pattern)
  is inherited scope, client-side, mirroring CoopBattle exactly. Evolution stays
  out (coop's own behavior is the ceiling).
- R5-A5: the expfill display machinery ports into MediatedBattle WITH the H-wave
  fixes baked in (row-start targets, live-clock precedence, own-slot-only
  seeding). Battlefield renderer needs zero changes (plate is generic over
  seat.expFrac/shownLevel). Classic-Gen1 mediated still awards+persists exp with
  text only (no strip — classic has no plates).
- Twin obligations: `exp` added to Wire.BATTLE_EVENTS + sanitize.js
  BATTLE_EVENT_TYPES in lockstep (twin_parity.test.js); battleEvent sanitiser
  gains species (M.name), level (int 1..LEVEL_MAX), participants (bounded int);
  battle_turn_parity.json regenerated (event stream changes); hub_protocol_parity
  fixtures checked (open Q: do mediated_ko_settle snapshots carry raw streams).
  Old-hub/old-client tolerance verified: unknown kinds must drop gracefully both
  directions; report whether PROTOCOL must bump.
- Latent-drift note: mine[] index ↔ save.party 1:1 assumption (snapshotMons skip
  case) — document at the exp writeback site, consistent with vitamin's.

Waves: R5-W1a Wire.lua + server/lib/sanitize.js ∥ R5-W1b src/BattleSim/Turn.lua +
server/lib/battle/Turn.js ∥ R5-W1c src/MediatedBattle.lua (event shape pinned
above; all file-disjoint). R5-W2 tests (unit + parity fixture regen + node
suites). Review → fixes → full verify.

---

# Round 6 — vanilla exp participation (2026-08-12, owner-directed)

Owner: exp sharing must equal vanilla — any of your mons that was ever in
against the fainted foe and is still alive splits the award, benched included.
Round 5 paid only mons standing at the faint (inherited from CoopSim).

Ground rule for every agent: **the engine's own solo-battle award logic is the
vanilla reference** (src/battle/BattleState + Experience in gen1recomp — its
participation flags, their reset-on-foe-switch semantics, the alive-at-faint
rule, and how the divisor counts). Mirror IT; do not trust recalled RBY lore.
Verify each semantic against that code and cite lines.

Pinned design:
- Referee twins track, per foe seat, the SET of opposing (side, partyIndex)
  pairs fielded against its current mon; the set resets when that seat's mon
  changes (foe switch/replacement mirrors the engine's flag reset). On faint:
  participants = set members whose mon is still alive (referee-authoritative
  hp); emit one exp event PER alive participant — new wire field `mon` =
  0-based party index of the paid mon on the winner's side; `slot` stays the
  owning fighter's seat (ownership gate). `participants` = alive-set size per
  the engine's divisor rule (verify: does vanilla count fainted participants
  in the divisor? mirror exactly).
- Wire: battleEvent gains `mon` (int 0..5); PARTICIPANTS_MAX rises 8→12 (two
  6-mon parties can share in coop). Sanitize twin in lockstep. Same `exp`
  kind — vocabulary unchanged, no PROTOCOL bump needed beyond 21 (R6-A1: the
  addition is a field on an event only 21+ hubs emit; 21 clients without the
  field-aware build drop the unknown field harmlessly via the sanitiser —
  agents verify and flag if wrong).
- CoopSim host-sim adopts the same participation semantics (consistency).
- Clients: pay the event-designated party mon (benched included) via the
  sheet.slot/party-index machinery; the EXP BAR/fill only animates when the
  paid mon IS the active one — a benched award shows text only (its bar is
  not on screen; its level-up text + forget prompt still run). Faint ledger
  capacity per faint rises to one full party (6).
- R6-A2: Gen2 twins still untouched (R5-A2 stands).

Waves: R6-W1 referee twins + fixtures (opus) ∥ R6-W2 CoopSim.lua (opus) ∥
R6-W3 Wire+sanitize `mon` field (opus). Then R6-W4 MediatedBattle ∥ R6-W5
CoopBattle. Then tests → review → fixes → battery.

---

# Round 9 — partner auto-joins coop fights (2026-08-13, owner-directed)

Owner: in 2xNPC and 2xWild the partner must be pulled in automatically after the
waiter picks WAIT — no interaction with the NPC, no confirm box. Scout ground
truth: coop_wild ALREADY auto-joins by design (Coop.lua:13-18) but only at
offer-arrival instant — an offer landing while the partner is busy is NEVER
retried (the gap the owner almost certainly hit); coop_npc raises an
askToJoin confirm the partner must answer. Hubs are neutral relays — client-only
fix in src/Coop.lua.

Pinned decisions (scout's open questions):
- R9-A1: coop_npc adopts coop_wild's silent auto-join (generalize autoJoinWild
  into a mode-agnostic autoJoin; considerOffer's trainer branch calls it instead
  of askToJoin). The ACTIONS→JOIN row stays as a manual fallback.
- R9-A2: THE RETRY — M:update polls a standing self.offer and re-attempts
  auto-join once the partner is free (gates: inFight/stack-fight, self.ask,
  self.waiting, AND Sessions:isBusy() — mid-trade becomes a gate, closing a
  pre-existing hole). This also fixes the wild-mode failure the owner saw.
- R9-A3: the trainer wait gains the wild path's COOP_ASK_TIMEOUT
  withdraw+release fallback (the confirm's human-decline used to be the escape
  hatch; auto-join removes it, so the waiter must self-release to solo).
  [Superseded by Round 13: the cover this "self-release" acted on is deleted
  outright, and the clock is SOLO_FALLBACK_AFTER (6s), not COOP_ASK_TIMEOUT
  (60s) — see below.]
- R9-A4: mutual-wait arbitration (lexicographic playerId, the wild rule)
  applies to trainer waits too.
- R9-A5: the partner's 300s offer expiry now sends COOP_CANCEL so the waiter
  hears it instead of a stale box.
- R9-A6: the quad four-way ask stays fully manual (a challenge against another
  party is a different consent surface). Untouched.
- Drivers: mmo_guest.lua's coop_npc leg flips from driving the confirm to
  ASSERTING silent auto-join (template: mmo_join.lua:466-479's party-wild leg,
  including the no-confirm-text assertion).

Wave R9-P1: src/Coop.lua (+Client.lua only if the re-check hook needs it).
Then R9-P2: drivers + unit pins. Then battery + a live play session.

# Round 13 — the waiting cover is deleted (2026-08-13, owner-directed)

Round 11 left a "Waiting for NAME..." cover (single ALONE row) in front of
both the trainer and wild waits. Round 13 removes it outright — the
round-trip is sub-second on a live hub, and a box up for a fraction of a
second was a flicker, not a screen. Three changes, one orchestrator
unification:

- **The cover is gone.** `Coop:showWaiting` / `showWildWaiting` are deleted; a
  wait now runs invisibly behind the engine's own encounter (the trainer
  battle, or the wild grass) with nothing pushed above it. The clock that
  ends an unanswered wait moves from `Config.COOP_ASK_TIMEOUT` (60s) to a new
  local `SOLO_FALLBACK_AFTER` (6s, `src/Coop.lua`) — the ALONE row's job, done
  by a shorter clock instead of a button.
- **Same-map is now a hard gate on the trainer path too**, mirroring what
  Party vs Wild's `onWildEncounter` already required: an off-map partner
  never gets an offer posted at all — no wait, no wire traffic, one line
  ("X was too far to join!") over the vanilla fight that proceeds underneath.
- **Unification**: the wild path's own SOLO_FALLBACK_AFTER fallback used to
  release silently; it now says the same one line the trainer path does
  ("X couldn't join!") rather than handing the wild back without a word.

Joiner (and waiter) entry: a 24-frame veil (`CoopBattle.ENTRY_FRAMES` /
`CoopBattle.entryAlpha`) painted via `game.renderer.screenVeil` covers the
hard cut into the co-op arena — 6 frames held black while the field builds
its first frame, 18 fading off it, under half a second.

`src/Coop.lua` + `src/CoopBattle.lua` only; no wire/hub changes (COOP_WAIT /
COOP_JOIN / COOP_CANCEL payloads untouched, so `twin_parity` and
`hub_protocol_parity` are unaffected).
