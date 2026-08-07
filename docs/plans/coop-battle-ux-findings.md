# Plan — Co-op battle UX findings (menus, targeting, flicker)

| Field | Value |
| --- | --- |
| Date | 2026-08-05 |
| Source | owner's hands-on play session — four findings |
| Config | AGENTS_CONFIG.yml (quality) |
| Branch | feature/2x2-battles (session branch, owner keeps it uncommitted) |
| Base SHA | working tree; pre-change snapshots to scratchpad `ux-baseline/` |

## 1. Objective & success criteria

Four fixes, each with a crisp done-state:

1. **No flickered messages.** "You have nothing to use!" (and the empty-SWITCH
   line, and every other freshly shown battle line) cannot be dismissed in the
   same instant it appears; it stays readable until a deliberate press or the
   normal 1.6 s dwell.
2. **Self-only moves skip "Attack who?".** Swords Dance, Rest, Recover, Light
   Screen, Reflect, Mist, Substitute, Focus Energy and every other proven
   self-only move commit immediately from the move menu. Enemy-targeting
   status moves (Growl, Thunder Wave, Toxic, Sleep Powder, Leech Seed,
   Confuse Ray…) and the three proven exceptions (Haze, Conversion,
   Transform) keep the picker.
3. **The target picker shows both options.** "Attack who?" lists both living
   opponents side by side with a cursor, like every other picker — not one
   name at a time.
4. **Grid navigation, engine semantics.** The FIGHT/ITEM/SWITCH/RUN box
   navigates as the engine's own 2×2: UP/DOWN vertical neighbor, LEFT/RIGHT
   horizontal neighbor, clamped (no wrap). The move list (drawn 2×2 here)
   follows the engine's Wide-layout grid rule: same arrows, and a direction
   pointing at a slot beyond the move count holds position. The target pair
   navigates with LEFT/RIGHT as well as UP/DOWN.

5. **(Owner-added mid-build, from live play.)** The wait line never freezes
   at "(0)". A countdown is shown only where a clock actually enforces it
   (the host's forfeit clock; the replacement choice clock, which the host
   enforces for everybody). The general "waiting for the others" case names
   **who** hasn't acted instead of counting down — the information is on the
   wire already: `act` payloads fan out to every member, non-hosts just
   ignore them today. Format fits the 18-column box.

All suites stay green; e2e drivers unaffected (they navigate by first-row
taps, which clamp preserves).

## 2. Context & constraints (grounded, from the investigation brief)

- **Engine command menu** `gen1recomp/src/battle/BattleState.lua:1544-1557`:
  col/row decomposition, clamp on every edge, index row-major (1 TL, 2 TR,
  3 BL, 4 RN). Our `M.COMMANDS = {FIGHT, ITEM, SWITCH, RUN}` draws the same
  row-major 2×2, so the engine mapping transfers directly.
- **Engine move menu**: classic = wrapping 1-column list
  (`BattleState.lua:1594-1607`); Wide layout = 2×2 clamp/hold grid
  (`WideBattle.lua:351-377`). Ours is drawn 2×2 (`drawList`), so the Wide
  grid rule is the matching precedent.
- **Self-move predicate** (`MoveEffects.lua:377-388, 726-742`;
  `BattleState.lua:3066-3080`): a zero-power move whose merged effect record
  has `kind == "primary"` and NOT `accuracyChecked` is self-targeting **by
  construction** — except `HAZE_EFFECT`, `CONVERSION_EFFECT`,
  `TRANSFORM_EFFECT`, which read the chosen target. `kind == "full"` records
  (Roar/Whirlwind/Teleport, Mimic, Metronome) are not classifiable this way —
  they keep the picker. For true self-moves the chosen target is
  **semantically inert** in `CoopSim.runAction` (passed through to
  `performMove`, never read), so skipping the picker changes no outcome.
- **Flicker mechanism** (`CoopBattle.lua` messages phase + `Input.lua`
  edge model): input edges are one-tick clean; the gap is that a freshly
  shown line evaluates its dismiss condition on the tick it is created, with
  no dwell floor, and `updateItem`'s empty branch auto-advances with no tick
  spent. Fix at the messages phase: dwell floor before A/B may dismiss.
- **No engine precedent for a multi-battler picker** — the target UI is the
  mod's own; consistency target is the mod's `drawList`.

## 3. Approach & key decisions

1. **Dwell floor** (`MSG_MIN_DWELL = 0.25` s, file-local): in the messages
   phase, `wasPressed("a")/("b")` only dismisses when `msgClock >=` the
   floor. The 1.6 s auto-advance is unchanged. Fixes finding 1 globally (item,
   switch, every say()) rather than patching one branch. Evidence-based: the
   cascade is created at line-creation tick; a floor of any visible length
   closes it.
2. **`M.needsTarget(self, moveInst)`**: resolves the move record and its
   merged effect record; returns false only for
   `power == 0 and record.kind == "primary" and not record.accuracyChecked
   and effect not in { HAZE_EFFECT, CONVERSION_EFFECT, TRANSFORM_EFFECT }`.
   Conservative by design: unknown/absent records, `kind=="full"`, damaging
   moves → true. When false, `updateMove` commits directly with the first
   living opponent as the (inert) wire target — the sim's existing redirect
   path already tolerates it. The exception list carries the why as comments
   with the MoveEffects anchors.
3. **Target picker as a proper list**: `updateTarget`/target drawing use
   `drawList` with the living opponents' names ("Attack who?" as title),
   cursor on `targetIndex`; LEFT/RIGHT and UP/DOWN both move between the two
   entries (a two-entry grid: horizontal pair, clamp).
4. **Grid navigation**: `updateCommand` re-implemented as the engine's
   col/row clamp mapping; `updateMove` as the Wide-layout grid (clamp; hold
   when the target slot exceeds `#moves`). B/A behavior unchanged.
5. **No sim/wire changes**: everything is client-side UI. No event shapes,
   no CoopSim semantics, no signature impact. (The one near-exception —
   committing a self-move with an auto-picked target — uses the existing
   action shape.)

### Finding-5 mechanics (grounded)

- `waitingOn()` returns `COOP_TURN_TIMEOUT` for the wait phase on every
  client, but only the host's `tickStalls` acts on that budget (its own
  forfeit). On a replayer the number is theatre; when the missing player is
  the *host itself* still choosing (deliberately unclocked), the display
  bottoms out at (0) and sits there — the reported bug, reproduced from the
  play session (a bot window, committed, waiting on the human host).
- Fix: track acted slots per turn on every client — own commit; host's
  `pending`; and on replayers, observe the `act` messages already arriving
  in `drainNet` (currently host-only-consumed) to mark `action.slot`.
  Reset on turn application and at the choose handover. The wait line then
  says `Waiting for
<NAME>...` (first missing name; `+N` if several fit
  poorly), with no countdown; countdowns remain only for the two waits a
  clock really enforces.

## 4. Work breakdown — implementation

Single wave, single task (all four fixes live in one file's UI layer;
splitting them would manufacture a collision):

| ID | Goal | Owns | Acceptance |
| --- | --- | --- | --- |
| A | All four fixes in the battle screen | `src/CoopBattle.lua` | §1's four done-states; suite stays 1437/1437 |

## 5. Work breakdown — tests

| ID | Layer | Covers | Owns |
| --- | --- | --- | --- |
| T1 | headless suite | dwell floor (fresh line survives same-tick and next-tick A; dismisses after floor; 1.6 s auto-advance intact); needsTarget truth table (Swords Dance/Rest/Light Screen false; Growl/Thunder Wave/Toxic true; Haze/Conversion/Transform true; damaging true; unknown record true); self-move commits straight from move menu with inert target; target picker lists both opponents and navigates LEFT/RIGHT; command-box clamp grid (all 4 positions × 4 arrows = engine truth table); move-grid hold rule with 3 moves | `tests/rby_mmo_test.lua` |

E2e: the existing three drivers are the regression net (they tap row-one
A-paths, which clamp navigation preserves — verified as part of Phase 7).
A feel-check via the play-mode session is offered to the owner at the end.

## 6. Execution waves

Wave 1: task A → barrier (suite) → review → T1 → full battery.

## 7. Blast radius & risks

- e2e drivers assume FIGHT is reachable and A commits row one — clamp keeps
  index 1 stable at rest; SWITCH/ITEM navigation in `mmo_guest.lua` uses
  down-taps from FIGHT: **down from FIGHT now lands on SWITCH (vertical)
  instead of ITEM (linear)** — the two driver sequences that navigate to
  SWITCH ("down down a") and ITEM ("down a") MUST be re-checked and updated
  as part of task A's acceptance (they live in `tests/drivers/mmo_guest.lua`,
  owned by T1's file set — see note below).
- The dwell floor delays dismissal of every battle line by 0.25 s — drivers
  that mash A still advance (their taps land past the floor at 60 fps
  spacing? 0.25 s = 15 ticks; drivePrompts taps every ~8-12 ticks — some
  presses will land inside the floor and be ignored, slowing driven battles
  slightly; budgets have held through larger slowdowns).
- Self-move skip commits an action whose target the player never chose —
  inert by evidence, and the wire shape is unchanged.

Note on driver file: `tests/drivers/mmo_guest.lua` navigation sequences must
match the new grid. To keep the wave collision-free, task A owns that file
too (it is not touched by T1).

## 8. Open questions / assumptions

- Grid scope (asked at the gate): recommendation is command box + move grid +
  target pair, mirroring the engine everywhere it has a rule.
- Dwell floor 0.25 s — judgment call, adjustable by constant.
