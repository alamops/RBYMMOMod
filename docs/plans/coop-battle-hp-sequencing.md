# Plan — Sequenced HP drains & faints in co-op battles

| Field | Value |
| --- | --- |
| Date | 2026-08-05 |
| Source | user report: "move effects happen after Dragonite is already defeated; the HP bar must wait for the move effect; the battle is not waiting for effects or HP animations" |
| Config | AGENTS_CONFIG.yml (quality) |
| Branch | feature/2x2-battles (session branch; the whole feature is uncommitted here by the owner's choice, so no wave commits — baseline snapshots taken instead) |
| Base SHA | d85cca7a3825ad0c47324579b2b92b0d0024ab19 (tree dirty with the session's uncommitted feature work; review diffs against file snapshots in the scratchpad) |

## 1. Objective & success criteria

A co-op battle's *display* must sequence like the engine's own 1v1: the attack
animation plays, **then** the HP bar drains at the original's speed, **then**
the effectiveness text, **then** — on a KO — the monster sinks off the field
and "X fainted!" prints. Nothing on screen may jump ahead of the queue.

Success =
- The HP bar never moves before the move's animation/text for that hit.
- A fainted monster stays on screen until its faint row plays, then sinks over
  30 frames, exactly like the original.
- The bar drains at the engine's rate (`maxHP/96` per frame — 1 bar pixel per
  2 frames), blocking the queue while it moves; not skippable (engine rule).
- Sim truth (`mon.hp`), signatures, sync checks, exp, ranking: **byte-identical
  behaviour to today**. This is a display-only change.
- All suites green: Lua suite, T4, node hub, hub e2e, quad e2e, LAN e2e.

## 2. Context & constraints (grounded)

**Why it looks broken today (mod side):**
- `CoopBattle.playEvents` applies a `damage` event to `mon.hp` the moment a
  turn arrives (`src/CoopBattle.lua:951`); on the host the sim applied it even
  earlier, inside `resolveTurn`. The bar is drawn straight from `mon.hp`
  (`drawReadout`), so it empties before any message plays.
- The `faint` event the sim emits (`src/CoopSim.lua:931`) is **unhandled** by
  the client; sprite/panel hiding rides `sim:isDown(slot)` (hp ≤ 0), so the
  monster vanishes instantly and the animation replays over an empty field.
- `CoopField.drain` **drops** the engine's `drain` rows ("a row that only
  means something to a 1v1 screen"), discarding the exact sequencing
  information we need — including multi-hit per-strike stops.

**What the engine does (verified, file:line in the investigation brief):**
- Battlers carry `shownHP` (init `BattleState.lua:392`) — the displayed HP.
  A `{ drain = true, stopAt = … }` queue row blocks the whole queue while
  `stepHPDrain` (`BattleState.lua:791-813`) moves `shownHP` toward the goal at
  `max(1, maxHP)/96` per frame. Floor when draining down, ceil when up.
- Row order per hit: "used MOVE!" text → anim (hit blink after sub-anim) →
  **drain** → "Critical hit!"/effectiveness text → faint chain.
- Faint (`onFaint`, `BattleState.lua:3184-3231`): an `fn` row sets
  `battler.fainted = true` + starts a 30-frame downward **sink** (quad-clipped,
  2px/frame — `fxFaintOffset` `BattleState.lua:4232`), a `{wait=30}` row holds
  the queue, *then* "X fainted!" prints. Final hiding is the `fainted` flag.
- Drain/anim/wait are **not skippable**; only finished text pages advance on
  A/B. Menu idle snaps `shownHP = mon.hp` as a safety net
  (`BattleState.lua:1447-1461`).

**Hard constraints:**
- `mon.hp` must keep applying instantly: `signature()`, the desync check, the
  host's turn resolution, `spectating()`, and the e2e drivers' field watchers
  all read sim truth. Display and truth are two clocks; only display changes.
- New event kinds must be additive: `playEvents`' if/elseif chain ignores
  unknown kinds, so older clients degrade to today's behaviour (no protocol
  bump needed within 0.5.0).
- The replay-conformance suite compares `signature()` (sim truth) — display
  rows must not disturb it.

## 3. Approach & key decisions

**Two clocks, engine-style.** Sim truth applies instantly (unchanged). Display
truth — `battler.shownHP`, `battler.fainted` — advances only through the
message queue, which already has the right blocking discipline (`self.anim`).

Decisions (all rest on the investigation brief's measured findings):
1. **Emit `drain` events instead of dropping the rows** (`CoopField.drain`):
   `{ kind = "drain", slot = <index>, to = <stopAt> }`. This preserves the
   engine's own placement (drain *before* effectiveness text) and per-strike
   stops for multi-hit moves (engine bug ref #394). The `damage` event stays
   as the authoritative value-sync *and* as a catch-all display target for HP
   changes with no engine row (residuals, items); draining to an absolute
   target is idempotent, so both sources coexist without double-motion.
2. **`faint` display row.** Reorder `announceFaint` to emit the `faint` event
   *before* the "X fainted!" message (engine order: sink, then text). Client
   handles `faint` by queueing a display row; playing it sets
   `battler.fainted = true` and runs a 30-frame quad-clipped sink at the
   slot's position, blocking the queue — then the text row prints.
3. **Display predicate replaces `isDown` in drawing only.** `drawField` /
   `drawPanel` hide on `slot.gone or battler.fainted` — never on raw hp.
   (`spectating()`, stall clocks, watchers keep reading sim truth.)
4. **Drain mechanics mirror the engine exactly:** `max(1, maxHP/96)` per
   update tick (the mod updates on the same 60Hz fixed step), floor-down /
   ceil-up rounding at draw, queue blocked while moving, **not skippable** —
   A/B still advance finished text pages only.
5. **Text stays up through effects.** Today `shown` clears before the anim row
   pops, leaving the box blank during the flash. New pop rule: non-text rows
   (anim / drain / faintfx) pop and run even while a text line is displayed,
   leaving it on screen — the engine's look. Text rows still wait their turn.
6. **Snap points** (engine's menu-idle safety net): entering `choose`, after a
   resync `restore`, and at `finish` — set every `shownHP = mon.hp` and align
   `fainted` with `isDown`, so a dropped row can never wedge the display.
7. **Replacements need no work:** `sendOut` builds a fresh battler; the
   engine's `makeBattler` already sets `shownHP = mon.hp`. Add the same field
   to CoopSim's no-engine fallback battler for parity.

Alternative considered: animate the bar purely client-side on `damage` events
(no new event kind). Rejected — it loses the engine's drain placement and the
per-strike multi-hit stops, i.e. it would be smooth but wrong.

## 4. Work breakdown — implementation

One wave, two file-disjoint tasks, built to the contract in §3 (event shapes
`{kind="drain", slot, to}`; `faint` emitted before its message).

| ID | Goal | Owns (exclusively) | Acceptance |
| --- | --- | --- | --- |
| A | Display machinery: queue rows for drain/faint, `shownHP` stepping at engine rate, 30-frame sink render, display predicate in drawField/drawPanel/drawReadout, snap points, text-stays-up pop rule | `src/CoopBattle.lua` | Bar moves only when its row plays; faint hides only after sink; snaps on choose/resync/finish; suite still green |
| B | Emit engine drain rows as events; reorder faint-before-message; `shownHP` on the fallback battler | `src/CoopField.lua`, `src/CoopSim.lua` | Drain events carry the engine's stopAt per strike, in-queue order; conformance suite untouched (sim truth unchanged) |

Wave barrier, then integration check by orchestrator (suite run).

## 5. Work breakdown — test tasks

| ID | Layer | Covers | Owns |
| --- | --- | --- | --- |
| T1 | unit (headless suite) | damage event leaves `shownHP` untouched until its row plays; drain blocks the queue and steps at `maxHP/96`; heal drains upward; faint hides sprite only after its row; text-stays-up; snap on choose/resync; unknown event kinds ignored (old-client compat); conformance suite unchanged | `tests/rby_mmo_test.lua` |

**E2e applies** — the symptom was only ever visible in a real client. No new
e2e code: the existing three drivers are the regression net (they mash A, and
drains are unskippable, so runs get slower — the risk is PHASE-budget warnings,
not failures). Run recipes (recorded from earlier sessions): from the engine
view at `<scratchpad>/engine` with `/opt/homebrew/bin` on PATH:
`run-hub-e2e.sh` (MMO_TIMEOUT=2700), `run-quad-e2e.sh` (3600), `run-mmo-e2e.sh`
(1800, must run backgrounded — exceeds the 10-min tool limit).

## 6. Execution waves

- Wave 1: tasks A + B in parallel (disjoint files, shared contract from §3).
- Barrier → orchestrator sanity run (suite + T4).
- Phase 5 review → Phase 6 (T1) → Phase 7 (suite, node hub, hub e2e, quad e2e,
  LAN e2e backgrounded) → Phase 8 loop if needed.

## 7. Blast radius & risks

- **e2e duration/budgets:** unskippable drains add ~1–2s per exchange; the
  PHASE table's margins (`hub_a/b_battle` 540, `quad_fought` 900) should hold,
  but a `WARN barrier` means raising the budget, not reverting the feature.
- **Suite tests that replay then assert immediately** read `mon.hp` — safe by
  design (truth unchanged). Tests reading `messages` scan `.text` — drain rows
  carry none — safe.
- **Spectator flow:** phase stays `messages` until the queue (incl. sink)
  finishes, then the existing gates run — order preserved.
- **Old client vs new host:** unknown `drain` kind ignored → today's behaviour.
  New client vs old host: no drain events → the `damage` catch-all still
  animates the bar (smoother than today, less precise than full).
- **Rollback:** display-only; reverting A+B restores current behaviour.

## 8. Open questions / assumptions (owner skipped grill — logged)

- Mirror the engine exactly: 96-frame proportional drain, 30-frame sink,
  drain **not** skippable. "Like the original" is taken as the spec.
- No toggle to disable the animations (the engine offers none in-battle).
- Heals animate upward at the same rate (engine rule).
