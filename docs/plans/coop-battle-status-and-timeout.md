> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — Status enforcement, turn deadline, target UI (round 3 findings)

| Field | Value |
| --- | --- |
| Date | 2026-08-05 |
| Source | owner's second play session — five findings + two investigation discoveries |
| Config | AGENTS_CONFIG.yml (quality) |
| Branch | feature/2x2-battles (uncommitted by owner's choice; snapshots to scratchpad `status-baseline/`) |
| Base SHA | working tree |

## 1. Objective & success criteria

1. **Statuses are enforced, not just applied.** A slept monster skips its turn
   with "is fast asleep!", its counter ticks, and it wakes with "woke up!";
   paralysis full-stops 63/256 with "fully paralyzed!"; freeze holds until a
   Fire-type hit; confusion rolls the 50% self-hit ("It hurt itself in its
   confusion!") with the engine's authentic mechanics; flinch eats the turn of
   a second mover; Disable ticks; trapping holds; a Hyper Beam recharge turn
   recharges instead of moving. All with the original's wording, prefixes and
   onomatopoeia animations, on all four clients.
2. **No infinite wait.** One deadline per turn (60 s), host-enforced for every
   player slot including the host's own. On expiry the host auto-files the
   late player's first usable move at the first living target (owner's chosen
   policy — mirrors the replacement force-pick), everyone is told it was the
   clock, and the countdown returns to the wait line on every client — honest
   now, because enforced.
3. **Target picker is vertical** — one opponent name per row, no clipping.
4. **Field feedback on target hover** — the hovered opponent draws on top
   (z-order), and foe sprites draw slightly smaller (0.85) to reduce overlap.
5. **Leech Seed actually drains** (to its seeder) and a residual tick can
   never silently swallow poison/burn damage again.

## 2. Context & constraints (all anchors from the investigation brief)

- **The gate exists and is complete**: `Status.beforeMove(battler, rng, battle)`
  → `(canMove, messages, selfHit)` (`Status.lua:158`), order sleep(40) →
  freeze(30) → held/bound → flinch → disable tick → confusion → paralysis(10).
  Sleep decrements **before** the move, no grace turn; freeze has no self-thaw.
- **The engine wrapper** `BattleState:statusInterrupt` (`BattleState.lua:2892`)
  routes messages via `sayStatusMsg` (Enemy-prefix + `statusOnomatopoeia`
  anims), computes the confusion self-hit (typeless 40 power, **opponent's**
  screens — the real Gen 1 glitch), applies damage + faint check, and calls
  `clearVolatiles` (full-paralysis variant preserves `invulnerable` — the
  Fly/Dig glitch). Recharge turns use the narrower `preRechargeChecks`
  (`:2855`); `clearTurnFlinches` (`:1359`) runs at turn top, sparing a
  recharging/raging battler (the Hyper Beam flinch glitch).
- **`performMove` does none of this** — verified by reading it whole; the
  co-op engine path (`CoopSim.runAction:687`) therefore has zero gating today.
- **The ritual is free through the adapter**: `sayNext`/`animNext` are already
  overridden by `CoopField` into event rows, so calling the engine's own
  wrapper through the field object emits the exact original text/anims as
  events with no new string tables. The adapter surface must be verified for
  what `statusInterrupt`/`preRechargeChecks` touch beyond the known 14
  methods, and extended where needed.
- **RNG**: `battle.rng` is an overridable field; `field.rng` and `sim.rng` are
  already the same closure (`CoopBattle.lua:245-280`), and host-authoritative
  replay means host-internal consistency suffices — pass `self.rng`/`field.rng`
  everywhere, never a fresh `love.math.random`.
- **Sleep already lands correctly** (`mon.status = "SLP"` + `sleepTurns` on
  the battler, `StatusRegistry.lua:21`, `Status.lua:74`): nothing to fix on
  the infliction side.
- **Discovered bug — residuals**: `CoopSim.runResidual:1023` passes
  `opponent = nil`; `Status.residual` (`Status.lua:219`) mutates PSN/BRN HP
  *then* indexes `opponent.mon.hp` for Leech Seed → throws for a seeded
  battler; the swallowing pcall drops the message AND the event for HP that
  already moved (desync vector), and seed never drains. 4-slot fix needs a
  seeder pointer: `battler.leechSeeded` is a bare boolean (`MoveEffects.lua:182`)
  — the sim records `seededBy = <slot index>` when an action flips it.
- **Known non-portable quirk (documented divergence)**: the engine skips a
  battler's residual when its (single) opponent fainted this turn
  (`BattleState.lua:2050`). "Opponent" is undefined on a 4-slot field; co-op
  runs residuals whenever the battler lives. Recorded here, deliberately.
- **Timeout today is backwards**: the only clock (`tickStalls` wait branch)
  makes the committed host forfeit ITSELF at 60 s; an idle host is bounded by
  nothing. Replaced wholesale by the per-turn deadline (owner's policy).

## 3. Approach & key decisions

1. **Adopt, don't reimplement** (evidence-based): the co-op sim calls the
   engine's own gate through the field adapter — `statusInterrupt` before an
   ordinary move, `preRechargeChecks` on a recharge turn — draining the rows
   it queues into events exactly as `performMove`'s already are. Skip
   `performMove` when interrupted. Faints from the confusion self-hit flow
   through the adapter's existing `onFaint`/`fainted` plumbing; verify.
2. **Recharge turns become real**: when `battler.mustRecharge`, the slot's
   action resolves as a recharge (gated by `preRechargeChecks`, flag consumed)
   regardless of the move picked — matching `executeAction:2775`. Implementer
   verifies how mustRecharge lands today and what the adapter needs.
3. **Flinch discipline**: `clearTurnFlinches`-equivalent at the top of
   `resolveTurn` over all four slots (sparing mustRecharge/rage); the gate
   runs inline per-slot in the existing execution loop, so a first mover's
   flinch bites a later mover the same turn — engine sequencing preserved.
4. **Residual repair**: `runResidual` passes the seeder's battler (from the
   new `seededBy` pointer, recorded in `runAction` when an action newly sets
   `target.leechSeeded`) as `opponent`; no pointer → pass nil BUT guard seed
   drain path (never let the pcall swallow PSN/BRN again — split the call or
   emit from a before/after HP diff, which `resolveTurn`'s `step()` wrapper
   already provides for events; the throw itself must go).
5. **Turn deadline** (owner-decided policy): host stamps `turnOpenedAt` when a
   turn becomes decidable; at +`COOP_TURN_TIMEOUT` it auto-files, for every
   player slot not in `pending` (its own included), `CoopSim:defaultAction(slot)`
   = first move with PP at first living target (falls to Struggle-by-sim if
   none), announces "<NAME> took too long!" (existing message pattern), and
   resolves. The self-forfeit branch is deleted. `waitingOn` returns the
   budget on every client again (deadline is real everywhere now), so the
   wait line reads `Waiting for\nALPHA... (37)` — name AND honest number.
   Late player's open menus close on the turn's events (the existing
   `res`-application path already snaps phase/menus; verify pickers).
6. **Vertical target list**: `drawTarget` lists one opponent per row (title
   "Attack who?", cursor, UP/DOWN moves, LEFT/RIGHT aliases, clamp). The
   generic `drawList` stays 2×2 for moves; the target picker gets its own
   vertical layout (or a `drawList` column mode — implementer's call, stated).
7. **Hover z-order + foe scale**: during the target phase the hovered slot is
   appended last in `drawField`'s paint order (existing `DEPTH_ORDER`/spotlight
   machinery); foe-side sprites draw at `FOE_SCALE = 0.85` (positions nudged
   so baselines hold; `drawSinking` divides its offset by the sprite's actual
   scale — it already parameterizes PIC_SCALE, extend for per-side scale).
8. **No wire changes**: status ritual rides existing `msg`/`anim`/`damage`
   events; auto-pick files ordinary actions host-side; deadline is display +
   host logic. Old clients remain compatible.

## 4. Work breakdown — implementation (one wave, two tasks, disjoint)

| ID | Goal | Owns | Acceptance |
| --- | --- | --- | --- |
| A | Status gate + recharge + flinch discipline + residual/Leech-Seed repair + `defaultAction(slot)` | `src/CoopSim.lua`, `src/CoopField.lua` | Slept mon skips with ritual events; recharge turn recharges; seed drains to seeder; no swallowed residuals; defaultAction returns a legal action for any live slot |
| B | Turn deadline + auto-file + honest countdown restore; vertical target list; hover z-order + foe scale | `src/CoopBattle.lua` | Idle player (host included) auto-picked at 60 s with "took too long!"; countdown shows names+numbers everywhere; target list vertical; hovered foe on top at 0.85 scale |

Contract A→B: `CoopSim:defaultAction(slotIndex)` → action table in the
existing wire shape, nil only for down/gone slots. B consumes it in the
deadline handler. No other cross-task surface.

## 5. Work breakdown — tests

| ID | Layer | Covers | Owns |
| --- | --- | --- | --- |
| T1 | headless suite | Status matrix with controlled rng: sleep gate + counter + wake message; paralysis full-stop both roll outcomes; freeze holds; confusion self-hit + snap-out + volatile clears; flinch bites second mover same turn and is cleared at turn top (sparing recharge); disable tick; recharge turn blocked + flag consumed; Leech Seed drains seeder-ward with events; PSN/BRN residual always emits (no swallow); replay conformance still signature-equal with statuses active. Deadline: auto-file at expiry incl. host's own slot; "took too long"; defaultAction legality; countdown restored on non-host. Target list vertical fit at NAME_MAX; hover z-order decision; foe scale applied (via testable draw-order/scale helpers). | `tests/rby_mmo_test.lua` |

E2e: existing three drivers as regression net (they mash A; statuses appear
naturally via NPC moves — no driver changes expected; SING-class scripted
scenario NOT added to e2e, covered headless). Full battery after T1.

## 6. Execution waves

Wave 1: A + B parallel → barrier (suite) → review (opus, code-review skill) →
T1 (sonnet) → fixes loop → full battery (orchestrator-run; the haiku runner is
bypassed after two wrong-checkout reports) → play session for the owner.

## 7. Blast radius & risks

- The status gate changes resolved-turn event streams (more msgs/anims, skipped
  moves) — replay conformance tests must stay signature-green; they replay
  host events so they will, but the suite's fixed-rng harness crits every roll
  (`rng(a) → a` returns max): paralysis/confusion rolls with that rng always
  fail/succeed deterministically — tests must inject purpose-built rngs.
- Auto-pick at deadline interacts with the stall force-pick (replacement) —
  two clocks, two mechanisms; keep them separate and named.
- The e2e drivers' battles get statuses enforced for the first time — an NPC
  putting a driver's mon to sleep lengthens battles; budgets have margin.
- Foe scale changes screenshots subtly; docs screenshots refresh at the end.
- Divergence documented: the opponent-fainted residual-skip quirk is not
  portable to four slots.

## 8. Open questions / assumptions

- Deadline duration = existing `COOP_TURN_TIMEOUT` (60 s) — assumed.
- Foe scale 0.85 — "reduce a bit", judgment call, constant.
- Freeze: faithful Gen 1 (no self-thaw) — assumed, matches "as in normal battle".
