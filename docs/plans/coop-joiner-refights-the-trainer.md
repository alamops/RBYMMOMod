# Plan — the co-op joiner refights the trainer

| Field | Value |
| --- | --- |
| Date | 2026-08-06 |
| Source | player bug report via `/implement` |
| Config | AGENTS_CONFIG.yml (quality) |
| Branch | `fix/consequent-battle-for-second-player-afte` |
| Base SHA | `37fcc2fe29afecc59b5d29a8cc58102b9923e617` |

## 1. Objective & success criteria

Two players in a party walk into the same trainer. The first picks **WAIT**; the
second is asked to join and says yes; the 2-on-2 runs and ends. Today the second
player is dropped straight back into a 1-on-1 against the trainer they just beat.

Done when:

1. After a co-op battle against an NPC, **both** players are returned to the
   overworld. Neither is put back into a battle against that trainer.
2. Both players' own engine `BattleState` is handed the result exactly once —
   the defeated-trainer flag, the rewards, the whiteout on a wipe and the
   suspended map script all run on both clients, as they do today for the
   waiter.
3. Nothing changes for the menu-join path (a player who joins from `ACTIONS`
   without walking into a trainer), for party-vs-party battles, or for
   `BATTLE ALONE`.
4. The mod's Lua suite, T4, the node hub suite, `modkit validate/lint/pack`, and
   both e2e drivers (`run-mmo-e2e.sh`, `run-hub-e2e.sh`) are green.

## 2. Context & constraints

The co-op battle does not reimplement a trainer fight. It **displaces** the real
`BattleState` the engine pushed when the player walked into the trainer, holds
it, and hands it the result afterwards (`src/Coop.lua:147-226`). Both clients
build their own local `BattleState` — the engine pushes one on each machine when
each player interacts with the NPC — and each holds its own in
`self.encounter.engine` (`src/Coop.lua:519-526`).

- **The waiter** promotes that reference `encounter → self.waiting` in
  `M:beginWait` (`src/Coop.lua:590-600`) and `M:onJoined` threads it into the
  plan as `engine = waiting.engine` (`src/Coop.lua:899`).
- **The joiner** goes through `M:onBattle` instead (`src/Coop.lua:912-935`),
  whose plan table has **no `engine` field at all**. The joiner's own reference
  is still sitting in `self.encounter`, untouched — `askToJoin`'s "yes" branch
  never calls `release()`/`consume()` (`src/Coop.lua:661-685`).
- `M:startBattle` reads `battle.plan.engine` (`src/Coop.lua:1353`) and gates the
  unwind on it (`src/Coop.lua:1439-1442`). Its own comment states the bug:
  *"Left there it would resume the moment the co-op battle popped, and the
  player would fight the same trainer twice."*
- `CoopBattle:finish` pops only the co-op screen (`src/CoopBattle.lua:2200-2205`);
  `StateStack:pop` is synchronous and immediately exposes whatever is beneath
  (`gen1recomp/src/core/StateStack.lua:24-31`).
- `M:onBattleOver` only refreshes `self.encounter` from `self.engineBattle`
  (`src/Coop.lua:1488-1499`), which is nil for the joiner — so `M:consume` calls
  `onFinish` on a battle that is **still on the stack**, whereas the engine's own
  `BattleState:finish` pops first and only then calls `onFinish`.

Both hubs already send the battle key to the joiner: `src/Hub.lua:1446` and
`server/lib/relay.js:464` both put `battle` in the `mmo.coop_battle` payload, and
`Wire.battleKey` sanitises it (`src/Wire.lua:570-576`). No wire change is needed
— the engine reference is client-local and could never cross the wire anyway.

Related history: `docs/plans/coop-run-consent-and-blackout.md:135-138` already
flagged "drop the `if engine then` asymmetry", but what shipped was only the
unconditional `closeAskBox()` at `src/Coop.lua:1449` — the party-vs-party ask
box. The NPC path's real `BattleState` never got the same treatment.

## 3. Approach & key decisions

**Give the joiner's plan the engine battle the joiner already holds, keyed by the
battle the hub named.** `plan.engine` then means one thing on every path: *the
local trainer battle this client walked into, if any*.

- **Keyed, not unconditional.** `M:onBattle` adopts `self.encounter.engine` only
  when `self.encounter.battle` equals `Wire.battleKey(msg.battle)`. That is what
  keeps the menu-join path (no encounter → nil, correct) and party-vs-party
  (`foes` present → never adopted) untouched, and what stops a stale encounter
  for a *different* trainer being handed the wrong result.
- **Accept the three fields that come with it** (confirmed with the owner):
  `trainerPic`, `endBattleText` and `aiUses` are all derived from `plan.engine`
  (`src/Coop.lua:1359-1420`). The joiner walked into this trainer, so they should
  see the entrance picture and the defeat line exactly as the waiter does. All
  three are local-display/AI-allowance values — `trainerPic` is draw-only
  (`src/CoopBattle.lua:2463`, `3849`), `endBattleText` prints local message boxes
  after the result is already settled (`src/CoopBattle.lua:1915-1920`), and
  `aiUses` is only read by the simulating host (`src/CoopSim.lua:1468-1480`), so
  the joiner's copy now *matches* the host's instead of defaulting to 0. None can
  desync a host-authoritative replay. The "joined by invitation opens straight on
  the monsters" comment (`src/Coop.lua:1360-1366`) stays true — that is the
  menu-join path, which still has no encounter.
- **Hand ownership over cleanly.** When `startBattle` takes the engine battle off
  the stack into `self.engineBattle`, drop `self.encounter`. It now names a state
  that is no longer on the stack, and `M:release()` → `unwindTo(game, engine,
  false)` would pop up to 16 live states looking for it (`src/Coop.lua:139-145`,
  `542-552`). `M:reset` calls `release()` on a dropped connection
  (`src/Coop.lua:113-117`), so that window is reachable. This is a latent hazard
  on the waiter's path today, not something the joiner fix introduces.

Alternative rejected: keeping two separate engine references (one to unwind, one
for display) so the joiner's visuals stay byte-identical. It fixes the bug but
leaves two meanings for one thing in a file written as prose, and needs a
paragraph to explain why the player who walked into the trainer is shown no
trainer.

## 4. Work breakdown — implementation tasks

Single wave, single owner — the change is two hunks in one file plus the release
files. No parallel fan-out: the tasks are not file-disjoint in any useful way.

| ID | Goal | Files owned | Acceptance |
| --- | --- | --- | --- |
| I1 | `M:onBattle` adopts the joiner's own encounter engine for the NPC branch, keyed on the hub-named battle key. | `src/Coop.lua` | `plan.engine` non-nil for a joiner who walked into the trainer; nil for a menu join and for any party battle. |
| I2 | `M:startBattle` clears `self.encounter` when it takes ownership into `self.engineBattle`. | `src/Coop.lua` | No path can `unwindTo` a battle already off the stack. |
| I3 | Version bump + CHANGELOG entry. | `manifest.json`, `CHANGELOG.md` | 0.7.4; heading matches `manifest.version`; `affects_link` untouched. |

## 5. Work breakdown — test tasks

| ID | Goal | Files owned |
| --- | --- | --- |
| T1 | Headless: the joiner's plan carries an engine, and the joiner's own displaced battle gets its result back. Mirror of the existing waiter-only block at `tests/rby_mmo_test.lua:4941-4969`, plus an assertion on `bob.coop.lastPlan.engine` at the handoff block (`:4818-4838`), plus a negative case — a menu join / different-trainer encounter is **not** adopted. | `tests/rby_mmo_test.lua` |
| T2 | e2e: after the co-op battle ends, the joiner is back in the overworld and the state they staged is not on top of the stack. Both drivers already stage a real trainer on the joiner (`mmo_guest.lua:897`, `mmo_join.lua:698`) and already assert `handed` (`mmo_guest.lua:1092`, `mmo_join.lua:734`) — add the "not dropped back into the battle" check next to it. | `tests/drivers/mmo_guest.lua`, `tests/drivers/mmo_join.lua`, `tests/drivers/mmo_host.lua` |

**E2e applies** and is the layer that actually proves this: the headless suite
cannot reach `M:startBattle` (no LOVE engine under luajit — it `abandon()`s
first, per the comment at `tests/rby_mmo_test.lua:4830-4836`), so it can only pin
the plan and handoff halves.

**Run recipe.** `export PATH="/opt/homebrew/bin:$PATH"` first. From a **private**
engine view (never repoint the shared `~/Projects/alamops/gen1recomp/mods/rby_mmo`
symlink — other agents share it):

```sh
luajit mods/rby_mmo/tests/rby_mmo_test.lua
luajit tests/run_modkit.lua
python3 tools/modkit.py validate mods/rby_mmo
python3 tools/modkit.py lint mods/rby_mmo
python3 tools/modkit.py pack mods/rby_mmo
node <mod>/server/hub.test.js
MMO_ADDR_FILE=<unique> bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh
bash mods/rby_mmo/tests/drivers/run-hub-e2e.sh
```

`MMO_SKIP_COOP` must be unset. `MMO_ADDR_FILE` must be unique per run — it
defaults to the shared `/tmp/rby_mmo_addr.txt` (`run-mmo-e2e.sh:42`) and a
collision reads as three unexplained failures. E2e needs a ROM imported.

## 6. Execution waves

One wave: I1 + I2 + I3 (same file for I1/I2), then T1 + T2, then run. Review
between implementation and tests, per the pipeline.

## 7. Blast radius & risks

- **`M:onBattle` is the single entry point for both "we joined theirs" and "all
  four agreed"** (`src/Coop.lua:909-911`). The party branch must keep `engine =
  nil`; the `not foes` guard is what enforces that, and T1 asserts it.
- **A joiner whose encounter is for a different trainer** must not have it
  adopted. The battle-key match is the guard; the case is believed unreachable
  today (a waiting player cannot reach the ACTIONS menu) but is defended anyway.
- **Clearing `self.encounter` in `startBattle`** — verify nothing between
  `startBattle` and `onBattleOver` reads it. `onBattleOver` re-populates it from
  `self.engineBattle` before `consume()`, which is the only reader that matters.
- **The joiner's new trainer picture and defeat text** are visible behaviour
  changes. Screenshots in `docs/` taken from the co-op e2e leg may go stale
  (fleet memory: captures are cropped 1024x768 → 800x720); recheck after the run.
- No wire, hub, schema or link-registry change. `affects_link` stays `false`.
- Rollback is a one-file revert.

## 8. Open questions / assumptions

- `M:onJoined` reads `waiting.trainer` (`src/Coop.lua:900`) but `beginWait` never
  sets a `.trainer` field (`src/Coop.lua:590-600`), so `plan.trainer` is always
  nil on that path. Looks like dead code, unrelated to this bug — **not touched**,
  noted for a follow-up.
- The hub comments describing the joiner as the one who "has never seen the
  trainer" (`src/Hub.lua:1442-1444`, `server/lib/relay.js:462-463`) are inaccurate
  for the walk-in case. The host choice itself is fine; the comments are worth a
  later correction, out of scope here.
- Assumed the coop e2e drivers are currently **red** on this bug rather than
  green — to be confirmed by the first run.
