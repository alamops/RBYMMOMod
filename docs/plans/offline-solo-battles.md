# Plan — Offline / solo battles through the mod's own battle system

| Field | Value |
| --- | --- |
| Date | 2026-08-17 |
| Source | `/implement` — "our battle system for offline and solo play, default off, an option in the mods menu; when on, use our battle system for everything: wild mons, trainers, npcs" |
| Config | AGENTS_CONFIG.yml (quality preset, host `claude_code`) |
| Flags | none |
| Branch | `feature/battle-system-in-offline` |
| Base SHA | 9b73899 |

## 1. Objective & success criteria

Add one option row to the F10 mod manager, **default OFF**. With it ON, a player with no
hub connection and no partner fights **ordinary wild encounters and every trainer** through
this mod's own `BattleSim` referee and `MediatedBattle` screen, instead of the engine's
`BattleState`. With it OFF, or on a battle kind this mod does not model, the vanilla battle
runs and the mod is invisible.

Done means:

1. The row exists, defaults OFF, and flipping it mid-session takes effect on the next
   encounter with no relaunch.
2. Solo wild: encounter diverts, the fight plays on the mod's screen, and **catch, run,
   faint, exp and level-up all land on the real save**.
3. Solo trainer: every trainer — sight-line, talk-to, gym leader, rival, scripted —
   diverts, plays 1-v-1 with the trainer's real party, and pays out prize money, defeated
   flags, badges/TMs, evolution checks and script resume exactly as vanilla does.
4. A loss blacks out correctly. A win never leaves the player standing in the overworld
   with a fainted party.
5. Safari Zone, the Marowak ghost and the Viridian old-man demo are **left on the vanilla
   engine**, silently.
6. Both Gen 1 (Red/Blue/Yellow) and Gen 2 (Gold).
7. Nothing on the wire moves: no `Config.PROTOCOL` bump, no `Wire` vocabulary, no
   `server/` change, no new `BattleSim` mode.

Non-goals: online play is untouched; co-op keeps priority wherever it already applies;
`affects_link` stays `false`.

## 2. Context & constraints (grounded)

**One seam reaches every solo battle kind.** Wild (grass/surf/cave, fishing, static
legendary) and trainer (sight-line, talk-to, gym, rival, scripted `start_battle`) all become
a `BattleState` pushed onto the stack. The only mechanism reaching all of them is
push-on-top: let the engine build and push its battle, push ours over it, and let the real
one sit frozen underneath — `StateStack` only updates its top. **This mod already ships
exactly that** for co-op: `src/Client.lua:2417` (`screen.pushed`) → `Coop:onTrainerBattle`
(`src/Coop.lua:676`) / `Coop:onWildEncounter` (`src/Coop.lua:798`).

**The referee is pure and already headless.** `src/BattleSim/Turn.lua` requires nothing —
no love, no engine, no sockets (`src/BattleSim/init.lua:17-21`); the existing suites drive it
under plain `luajit`.

**The post-battle ritual is already written, and was earned.** `Coop:consume`
(`src/Coop.lua:300`) pays prize money itself ("the engine pays from inside its own battle
screen and so never gets to pay for one it did not run"), re-hangs the blackout safety net
that `BattleState:finish()` normally provides (`src/Coop.lua:355-370`, `M.blacksOut`), then
calls `onFinish` directly; `Coop:unwindTo` (`src/Coop.lua:908`) pops **by identity, not by
count**. Solo reuses this rather than re-deriving it.

**`Sessions:beginWildMediated` (`src/Sessions.lua:450`) is already the wild path's shape** —
builds `MediatedBattle` with `mode="wild"`, a `wildParty` sheet and `wildCatchMon`. It has no
production caller today because solo wild was explicitly scoped out
(`docs/plans/party-wild-encounter.md:29`).

### Spike evidence (measured, not assumed)

Three spikes, all headless `luajit`, scripts under the session scratchpad:

- **A one-member in-process `Hub` does run a mediated battle** (solo wild → real
  `{outcome="win", reason="ko"}`), driven by a synthetic clock. But `mode="1v1"` with one
  member **silently seats the same id on both sides** (`Hub.lua:1307`) with `npcIds = nil`,
  so nothing ever answers side b — it looks started and hangs forever.
- **Hub's dealer cannot express "one seat, multi-mon bench."** `openMediatedBattle` deals the
  NPC party round-robin across all `Config.COOP_SIDE` seats (`Hub.lua:1409`) *before* reading
  `plan.sides`, so narrowing `sides.b` silently orphans mons that are never fielded — a 3-mon
  trainer loses one. Graceful, but lossy.
- **`wild` mode is semantically wrong for trainers.** `Effects.isWildMode`
  (`src/BattleSim/Effects.lua:1097`) and `teleportRunAllowed` (`:1140`) gate catching and
  fleeing by plain `mode:find("wild")` — reusing `wild` seating for a trainer fight would let
  a player **catch Brock's Onix**.
- **Therefore: skip `Hub` entirely.** `Turn.create{ mode="coop_npc", sides={a={human},
  b={npc}} }` with one fighter per side constructs cleanly (the cap at `Turn.lua:127-133` is
  a ceiling), carries the NPC's whole 3-mon party on the single fighter, and runs through
  both faints and both replaces to a real outcome — **38 events, `MediatedBattle` consumed
  every one with zero throws and rendered 2 slots, not 4.** Throwing a Poké Ball hits
  `Turn.lua:1698` → "But it failed", item spent, turn consumed, no catch mechanics: correct
  Gen 1 trainer semantics for free, because `coop_npc` does not contain `"wild"`.

**Measured consequence: nothing forces a change to `Turn.lua`, `Hub.lua`, `Config.PROTOCOL`,
or the Node twin.** That is the single most important property of this plan.

## 3. Approach & key decisions

**D1 — Solo is its own local referee; it does not use `Hub`, `Transport`, or `Wire.`**
*(rests on spike evidence)* `SoloBattle` owns a `BattleSim` `Turn` instance in-process and
pumps it directly. This keeps the wire frozen, keeps `server/` untouched, and honours the
mod's own principle that an offline copy is "as close to absent as it can be"
(`src/Client.lua:1-8`).

**D2 — Both fight shapes use `mode = "coop_npc"` with one fighter per side.**
*(rests on spike evidence)* Not `1v1` (self-battle footgun), not `wild` for trainers
(catchable trainer mons). For solo **wild** the mod keeps `mode = "wild"`, which is correct
there — catching and fleeing are exactly what a wild fight wants.

**D3 — The opponent's brain is the engine's own `TrainerAI`, not `BattleSim:autoPick`.**
*(user decision)* Solo never crosses the wire, so the NPC's choice can be computed locally
with the engine's real per-trainer AI — scoring layers from `trainer.aiMods`, item/switch
budgets from `ai_classes`, and full `brain` records — then submitted as an ordinary
`submitChoice`. Gym leaders keep their real behaviour and `BattleSim/Turn.lua` stays
byte-identical, so no Node-twin drift. `autoPick` remains the fallback if the bridge cannot
answer.

**D4 — Reuse `Coop`'s post-battle ritual by extraction, not duplication.** The prize/blackout/
`onFinish`/unwind sequence is delicate and its comments record several rounds of bugs.
Wave 1 lifts it into reusable helpers **without changing co-op behaviour**; the existing
co-op suites and e2e drivers are the guard.

**D5 — Scope the divert; fall back silently.** *(user decision)* Divert ordinary wild and all
trainers. Refuse — and let vanilla run — for Safari (`state.safari`), ghost
(`state.ghost`/`state.noCatch`) and the old-man demo (`state.demo`), whose mechanics
`BattleSim` does not model. Any error on the divert path logs a warning and leaves the
engine's battle to run, matching the existing co-op divert's `pcall` posture
(`src/Client.lua:2424-2427`).

**D6 — One toggle, read lazily.** *(assumption — recommended default, unconfirmed)* A single
`type = "toggle"` row, default from `Config.SOLO_BATTLES_DEFAULT = false`, read at the
decision point so a mid-session flip needs no relaunch — matching every option in this mod
except `port`.

**D7 — Co-op keeps priority.** *(assumption)* The `screen.pushed` handler tries the co-op
divert first; solo only takes the encounter when co-op declined it (not connected, no
partner, or partner not on this map).

## 4. Work breakdown — implementation tasks

| ID | Goal | Owns (exclusively) | Depends on |
| --- | --- | --- | --- |
| **I1** | Config section + constants: `SOLO_BATTLES_DEFAULT = false`, divert-refusal predicates' constants, NPC bag default reference. | `src/Config.lua` | — |
| **I2** | `SoloBrain` — bridge the engine's `TrainerAI` to a `BattleSim` choice. Reads the frozen `BattleState`'s trainer record (`aiMods`, `aiClass`, `brain`, `aiUses`), maps the sim's fighter state into the shape `TrainerAI` expects, returns `{action=...}`. Falls back to `nil` so the caller can `autoPick`. Gen 1 + Gen 2. | `src/SoloBrain.lua` (new) | — |
| **I3** | Extract `Coop`'s post-battle ritual into reusable helpers (prize payout, `blacksOut`, `onFinish` dispatch, `unwindTo`) callable without a co-op encounter. **Behaviour-preserving** — co-op call sites keep identical semantics. | `src/Coop.lua` | — |
| **I4** | `SoloBattle` — the feature. Divert predicates (`onWildEncounter`, `onTrainerBattle`, incl. the Gen 2 `state.battle.trainer` aliasing at `src/Coop.lua:678-680`); build the sim via `Turn.create` per D2; snapshot the player's party and the enemy party into sheets; apply `Turn.DEFAULT_NPC_BAG` (`Turn.lua:402`) — the one thing `Hub.lua:1542` does that a no-Hub caller must do itself; own the per-frame pump (branch on `battle.phase` `choice`/`replace`, submit NPC choice from `SoloBrain` else `autoPick`, `tick(now)`, `drainEvents` after **both** the choice- and tick-driven paths); feed events to `MediatedBattle`; on outcome, reconcile results onto `game.save.party` and run the I3 ritual against the frozen `BattleState`. | `src/SoloBattle.lua` (new) | I1, I2, I3 |
| **I5** | Wire it up: the option row in `mod.options:define` (`src/Client.lua:2298`), `need("SoloBattle")` + singleton construction alongside `coop`, and extend the `screen.pushed` handler (`src/Client.lua:2417`) so solo takes an encounter co-op declined — preserving the existing `transport:isReady()` gate for the co-op path and the `pcall` fallback posture. | `src/Client.lua` | I4 |
| **I6** | Docs: this plan's index entry, a `CHANGELOG.md` `[Unreleased]` bullet, a `mod.card` line, and a README section. No version bump (this repo bumps at release-cut, not per feature). | `docs/plans/README.md`, `CHANGELOG.md`, `mod.card`, `README.md` | — |

## 5. Work breakdown — test tasks

| ID | Goal | Owns (exclusively) | Covers |
| --- | --- | --- | --- |
| **TT1** | New headless suite: sim construction per D2 (one fighter per side, whole bench on the NPC), the full pump loop to outcome through faint→replace, ball-refused-in-trainer-fight, and the wild path's catch/run. Follows `tests/battle_sim_turn.lua`'s standalone `need()` resolver. | `tests/solo_battle.lua` (new) | I4 |
| **TT2** | `SoloBrain` unit tests: layer/`aiClass`/`brain` dispatch, `aiUses` budget, and the `nil`→`autoPick` fallback. | `tests/solo_brain.lua` (new) | I2 |
| **TT3** | Extend the mod suite: the option row is defined, defaults `false`, and the divert predicates refuse Safari / ghost / demo and accept ordinary wild + trainer. Uses the existing `stubMod` facade (`tests/rby_mmo_test.lua:314-379`). | `tests/rby_mmo_test.lua` | I1, I5, D5 |
| **TT4** | Regression guard on I3: co-op's prize/blackout/unwind behaviour is unchanged. | `tests/coop_mediated.lua` | I3 |
| **TT5** | **e2e, single instance, no network** — modelled on `run-battlefield-e2e.sh` (the existing single-instance driver). Boots one LÖVE, turns the option ON, uses `mmo_util`'s `M.stageWild` / `M.stageTrainer` to stage deterministic encounters, asserts the mod's screen took the fight, plays it to a win, and asserts the save afterwards (exp gained, party HP, trainer marked defeated, prize money paid). Gen 1 and Gold. | `tests/drivers/solo_battle_e2e.lua` (new), `tests/drivers/run-solo-battle-e2e.sh` (new) | all |

**e2e applies** — this is a user-visible flow crossing overworld → battle → save, and the
repo has a working single-instance harness. Run recipe: from the engine root
`~/Projects/alamops/gen1recomp`, `bash mods/rby_mmo/tests/drivers/run-solo-battle-e2e.sh`,
with `ROM_PATH` (and `GOLD_ROM_PATH` for the Gen 2 leg) set in `mods/rby_mmo/.env`;
`export PATH=/opt/homebrew/bin:$PATH` for `luajit`.

## 6. Execution waves

- **Wave 1** — I1, I2, I3, I6 in parallel (four disjoint file sets).
- **Wave 2** — I4 alone (needs all of wave 1).
- **Wave 3** — I5 alone (needs I4).
- **Wave 4** — code review (Phase 5).
- **Wave 5** — TT1, TT2, TT3, TT4, TT5 in parallel (five disjoint file sets).
- **Wave 6** — run suites + e2e; fix to green.

## 7. Blast radius & risks

- **`src/Coop.lua` (I3) is the one risky edit** — it is live, shipped, partner-facing code.
  Mitigated by keeping the extraction behaviour-preserving, by TT4, and by re-running the
  co-op e2e drivers (`run-mmo-e2e.sh`, `run-party-wild-e2e.sh`) before landing.
- **This feature writes to the player's real save.** Exp, catches, HP, PP and status are
  written live onto `game.save.party` objects with no commit boundary
  (`BattleState.lua:511-551`); solo must reconcile onto the same objects or the party screen,
  PC and save file disagree. Highest-severity area for code review.
- **Mid-battle save (F1/F2).** `BattleCheckpoint` does not know the mod's screen. Solo
  battles should refuse checkpointing rather than write a state that cannot be restored.
- **A double intro.** The engine's battle has already queued its intro text and started the
  battle theme before `screen.pushed` fires. Co-op lives with this today; solo should match
  whatever co-op does rather than invent a second answer.
- **Unwind depth.** `unwindTo` pops "up to sixteen states" by identity — text boxes and
  transitions can sit between our screen and the frozen battle.
- **No wire, protocol or `server/` change**, so hub/twin parity, `affects_link` and the link
  fingerprint are all untouched by construction.

## 8. Open questions / assumptions

1. **(assumption, unconfirmed)** Both Gen 1 and Gen 2 are in scope — recommended default,
   offered to the owner and not answered. Halving to Gen 1 only would drop the Gold e2e leg.
2. **(assumption, unconfirmed)** A single ON/OFF row rather than a granular `OFF/WILD/
   TRAINERS/ALL` choice — recommended default, offered and not answered.
3. **(assumption)** Co-op keeps priority when connected and partnered (D7).
4. **(open)** Exact option label — proposing `SOLO BATTLES` (fits the ~18-char GB row
   alongside `MAX PLAYERS` / `B TO RUN`).
5. **(open)** Whether solo battles should emit the engine's `battle.*` events for other mods'
   benefit. Vanilla emits `battle.started` / `battle.ended` / `battle.exp_gained` etc.; a
   mod-run fight emits none automatically. Deferred — nothing in this repo consumes them
   today.
