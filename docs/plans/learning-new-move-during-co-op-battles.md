# Plan — Learning a new move during co-op battles
| Field | Value |
| --- | --- |
| Date | 2026-10-21 |
| Source | Issue #105, `docs/plans/learning-new-move-during-co-op-battles-investigation.md`, `docs/plans/learning-new-move-during-co-op-battles-grill.md` |
| Flags | none |
| Gates | Grilled; the owner skipped the form. Proceeding on the four assumptions in the grill record. |
| Branch | `fix/learning-new-move-during-co-op-battles-i` (worktree already on it) |
| Base SHA | `ea822a501b081244c72692176d4ee1f70878624d` |

## 1. Objective & success criteria

A Gen 2 co-op battle that levels a Pokémon with four moves into a new move ends with an answerable YES/NO (replace or skip). The battle's return fade then finishes and the player is back on the map. A fight with nothing to learn still ends as it does today. A Pokémon that also evolves is asked on the party record the evolution left behind.

Success:

- `Coop:onBattleOver` with a fifth move calls Gold's popping `onDone` while the learn screen is not on the stack, then opens one prompt, and that prompt is still the top of the stack when `onBattleOver` returns (or, if an evolution screen was pushed, when that screen's `onDone` has popped it).
- The same ending with an empty `toLearn` pushes no learn screen, and the pop still runs.
- Gen 2 uses `game:learnMoveOn`. Gen 1 still uses `MoveLearnMenu`. A second pending move opens only after the first answer.
- No PROTOCOL change, no `affects_link` change, no edit to `World:startBattle` or `Game2:learnMoveOn`.

## 2. Context & constraints

Grounded in the investigation. The spike (`/tmp/spikes/coop-learn-105/repro.lua`, not in the repo) loaded real `Coop` and called `onBattleOver`: with a fifth move the finisher popped the `TextBox` and left `MoveLearnMenu` up while the fade was armed; with no fifth move it popped nothing.

What the player sees during the fight is only the announcement. `CoopBattle:teach` (`src/CoopBattle.lua:8401`) fills a free slot immediately and, on `"full"`, appends `{ mon, move }` to `toLearn` and says the mon is trying to learn the move (`src/CoopBattle.lua:8414`). That line has no YES/NO. The real prompt is `Coop:offerForgets` (`src/Coop.lua:2954`), called from `Coop:onBattleOver` **before** `consume` (`src/Coop.lua:2896` then `src/Coop.lua:2921`).

`offerForgets` pushes Gen 1 `MoveLearnMenu` with no completion callback and paces a second move with `self.ui:say("...", nextOne)` in the same call (`src/Coop.lua:2986`). `MoveLearnMenu:enter` pushes a `TextBox`; the YES/NO `ChoiceBox` is created on that box's next update (`engine src/render/TextBox.lua:622`), not during `enter`. `MoveLearnMenu:update` returns immediately while `selecting` is false (`engine src/ui/MoveLearnMenu.lua:86`).

Gen 2's buried battle is taken off the stack when the co-op fight starts and held on `engineBattle` (`src/Coop.lua:2776`). `Client` aliases `onFinish` from `onDone` (`src/Client.lua:2602`). `finishBuriedBattle` (`src/Coop.lua:504`) calls that function. Gold's `World:startBattle` closure always `game.stack:pop()`s, then (unless this is a whiteout or a script is running) calls `battleReturnFade`, which sets the fade to full white and arms `mapSetup` (`engine src/world/gen2/World.lua:3701`). `Game2` updates only the top state (`engine src/core/Game2.lua:1314`), so a menu whose `update` does nothing keeps `World:step` from advancing the fade. That is the white lock.

`LearnMove.open` (`src/LearnMove.lua:55`) is the 1v1 path. On generation 2 with `game.learnMoveOn` it calls `game:learnMoveOn(mon, moveId, done)` (`src/LearnMove.lua:69`). Otherwise it pushes `MoveLearnMenu` with the same callback (`src/LearnMove.lua:78`). `Gen.generation` (`src/Gen.lua:40`) reads `Handshake.generation`, which returns `game.generation` when that field is a number (`engine src/link/Handshake.lua:174`). Do not change `LearnMove.lua`.

`finishBuriedBattle` offers evolutions **before** the popping callback (`src/Coop.lua:524` then `src/Coop.lua:526`). `syntheticFinish` does the same before `afterBattle` (`src/Coop.lua:2588`). Gen 2 `EvolveFx.offerEvolutions` pushes `Gen2EvolutionAnim` and returns (`src/EvolveFx.lua:516`). The anim's `onDone` wrapper pops and starts the next row (`src/EvolveFx.lua:527`). It does not call `EvolveFx.retarget`. The engine anim replaces `party[index]` inside `commit`, before it calls `onDone` (`engine src/ui/gen2/EvolutionAnim.lua:347`). Its own `onDone` wrapper in the mod pops first; the engine then pops only if the anim is still the top (`engine src/ui/gen2/EvolutionAnim.lua:328`). A learn screen pushed after that wrapper's pop is not what the engine's second check removes.

`EvolveFx.retarget` (`src/EvolveFx.lua:312`) rewrites `holder.toLearn` only when a caller passes the holder. The after-fight anim does not. Mid-fight movies do (`CoopBattle.lua:3913`).

`SoloBattle:_ended` already finishes before `offerForgets` when `ritualPops` (`src/SoloBattle.lua:1403`). It shares `Coop.offerForgets` and `Coop.finishBuriedBattle`. `tests/solo_battle.lua` blanks `package.path` (`tests/solo_battle.lua:32`), so `Gen.generation` returns 1 there even for a `gold = true` fixture. Those cases must stay on the Gen 1 screen. Do not un-blank that path.

`pumpBlackout` waits for `top.isOverworld` (`src/Coop.lua:768`). Gen 2's overworld is not a stack state, so that wait already gives up on Gold. Do not retune it. `M:blackout` calls `pumpBlackout(0)` immediately (`src/Coop.lua:741`). On Gen 1 the overworld **is** `isOverworld`, so a pump that runs before the learn screen is up warps on the same call.

`Sessions:offerForgets` (`src/Sessions.lua:694`) is the 1v1 leftover. It does not call Gold's `onDone`. Leave it.

No save migration. `toLearn` stays `{ mon, move }`. `affects_link` stays false.

## 3. Approach & key decisions

The four product choices are the grill's assumptions (evidence: changelog 1.1.10 and the stack behavior above). The shape below is what makes those choices true in this code.

1. **Prompt after the fight.** `CoopBattle:teach` stays an announcement. No hub clock change, no PROTOCOL bump. Evidence: standing decision, `src/Coop.lua:2932`.
2. **Open on the white fade, after the pop.** `onBattleOver` runs `consume` / `syntheticFinish` first, while nothing of ours is on the stack, then opens the prompt. The prompt's `update` holds `World:step`, so the fade stays white behind the dialog and ticks after the answer. No deferred "map is back" pump. Evidence: `battleReturnFade` only advances from `World:step`, and a screen on top stops that step.
3. **`LearnMove.open`, one move per callback.** Delete the `"..."` pace. Gen 2 reaches `learnMoveOn` (Yes/No, deleter, Waterfall, Whirlpool). Gen 1 still resolves to `MoveLearnMenu` inside `LearnMove.open`. If `open` returns false, keep today's free-slot autofill or the warn, then continue to the next entry. Evidence: `src/LearnMove.lua:66`, `src/Coop.lua:2965`.
4. **Evolution, then the prompt, on the live party record.** This is the assumption that widens the edit past `onBattleOver`. Gen 2 evolutions leave `finishBuriedBattle` and `syntheticFinish`. They run only once the pop (and, on solo, `settleStack`) has finished, because a screen pushed earlier is what Gold's `onDone` removes, and `settleStack` unwinds everything above a battle that is still there (`src/SoloBattle.lua:1392`). `EvolveFx.offerEvolutions` gains `opts.onSettled`, called once when no anim from that call remains. The prompt is that callback. Before the offer, stamp `entry.partyIndex` while `party[i] == entry.mon`. When the prompt opens, pass `party[partyIndex]` if it is a table. The engine anim has already replaced that slot. If the live mon already has the move (the anim's own `learnMoveOn` taught it), skip the entry. Gen 1 `Evolution.checkParty` stays where it is, before `onFinish` / `afterBattle`: Gen 1's finisher does not pop, and checkParty mutates the same table. Evidence: `src/Coop.lua:520`, `src/EvolveFx.lua:460`, `engine src/ui/gen2/EvolutionAnim.lua:347`.
5. **Blackout's first pump runs after the first learn screen is up.** `offerForgets` pushes the first screen and returns; the next move waits on the callback. Call `blackout` after that return, including from `onSettled` when the evolution anim deferred it. A Gen 1 loss otherwise warps inside `pumpBlackout(0)` before the menu exists. A Gen 2 loss offers no evolution (`src/EvolveFx.lua:463`), so `onSettled` is synchronous and the prompt is up in the same turn. Do not change `pumpBlackout`.

`LearnMove.open` is not edited. `Sessions.lua` is not edited. Callers that omit `onSettled` keep today's evolution behavior aside from *when* Gen 2 evolutions are offered, which is Coop's and Solo's job.

## 4. Work breakdown — implementation tasks

| ID | Goal | Owned files | Depends on | Acceptance |
| --- | --- | --- | --- | --- |
| T1 | Let an evolution offer report when its screens are gone | `src/EvolveFx.lua` | — | `opts.onSettled`, if it is a function, runs exactly once on every exit of `M.offerEvolutions`. It runs synchronously on every path that leaves no `Gen2EvolutionAnim` up, including: no `game` / no `leveledUp`, nothing flagged, Gen 2 loss or draw (`src/EvolveFx.lua:463`), missing module, empty `Evolution.plan`, missing `ui.push`, and a push that fails and drains the queue. It runs from the Gen 2 queue only when `nextOne` finds the pending list empty. The anim `onDone` at `src/EvolveFx.lua:527` still pops, then calls `nextOne`; it does not call `onSettled` itself. Gen 1 calls it synchronously after `checkParty` returns or after the failure note. Nil `onSettled` changes nothing observable. Do not call `retarget`. Do not edit the engine anim. |
| T2 | Pop on a clear stack, then evolve, then one `LearnMove` prompt on the live mon | `src/Coop.lua` | T1 | The contract in §3 is in this file for co-op. `need("LearnMove")` next to the other requires (`src/Coop.lua:65`). Export `M.stampLearnIndex(game, toLearn)`: for each entry whose `partyIndex` is nil, set it to the 1-based index where `party[i] == entry.mon`. `M.offerEvolutions` gains an optional 5th `opts` and forwards `opts.onSettled`; it still stamps `mod.log` and `mod.ui` itself. `finishBuriedBattle` calls `offerEvolutions` before `pcall(finish)` only when `Gen.generation(game) ~= 2`. `syntheticFinish` does the same before `afterBattle`. `onBattleOver` order: `blacksOut`; `consume`; `syntheticFinish` when `consume` did not handle a win that has `plan.npcId`; then, for generation 2, `stampLearnIndex` and one `offerEvolutions(game, state and state.leveledUp, result, state and state.evoResolved, { onSettled = after })`; for any other generation, `after()` directly. `after` calls `offerForgets` and then, if `blackout and not (handled and engineRitual)`, `self:blackout(game)`. That blackout call is not also made before `after`. `offerForgets` opens through `LearnMove.open(game, mon, move, nextOne)`. `mon` is `party[entry.partyIndex]` when that slot is a table, otherwise `entry.mon`. An entry whose live mon already has `move` is skipped. `open` returning false keeps the autofill-or-warn block (`src/Coop.lua:2966`) and then continues. `open` returning true does not continue until the callback. The `"..."` say is gone. Comments at `src/Coop.lua:2916`, `src/Coop.lua:2932`, and `src/Coop.lua:2942` describe this order. An empty `toLearn` still pops nothing of ours. A party fight with no `engineBattle` still opens the prompt. |
| T3 | Keep solo's Gold pop ahead of the prompt, and chain Gen 2 evolutions the same way | `src/SoloBattle.lua` | T1, T2's pinned names (`stampLearnIndex`, `offerEvolutions` 5th arg, Gen 2 no longer offered inside `finishBuriedBattle`) | `ritualPops` branch (`src/SoloBattle.lua:1403`): `finishEngine`, `settleStack`, then if `Gen.generation(game) == 2` call `Coop.stampLearnIndex` and `Coop.offerEvolutions` with `onSettled` that runs `offerForgets` and then the blackout that the function currently runs at `src/SoloBattle.lua:1413`. Otherwise call `offerForgets()` there, as today. The non-`ritualPops` branch stays `offerForgets`, `finishEngine`, `settleStack`, then the same blackout. Blackout runs once. The header from `src/SoloBattle.lua:1231` no longer says co-op never had this pop or that the prompt is unconditionally `MoveLearnMenu`. The `Client.lua` alias citation in that header is `src/Client.lua:2602`. Gen 1 still does not pop inside `onFinish`. |
| T6 | Note the fix at the next version | `CHANGELOG.md`, `manifest.json`, `server/package.json`, `README.md` | — | New `## [1.4.20] - 2026-10-21` Fixed entry: a Gold or Crystal co-op fight that levels a full moveset into a new move asks YES/NO after the battle, on the white return fade, and the map fades in after the answer; a Pokémon that also evolves is asked on the evolved form. `manifest.json` `"version"`, `server/package.json` `"version"`, the badge at `README.md:14`, and the version in `README.md:1642` all say `1.4.20`. The 1.1.10 sentence that co-op banks a fifth move until after the fight stays as it is. No other README prose. |

T2 and T3 are written against the signatures below. They do not edit `src/EvolveFx.lua`.

```lua
-- EvolveFx.offerEvolutions(game, leveledUp, result, evoResolved, opts)
-- opts.onSettled: function() | nil. Once. See T1.

-- Coop.offerEvolutions(game, leveledUp, result, evoResolved, opts)
-- opts.onSettled forwarded. ui and warn stay the wrapper's.

-- Coop.stampLearnIndex(game, toLearn) -> nil
-- Sets entry.partyIndex when party[i] == entry.mon and partyIndex is nil.

-- Coop:offerForgets(game, toLearn) -> boolean
-- Same return as today (false when there is nothing to offer).
-- Opens LearnMove.open one entry at a time. See T2.
```

`LearnMove.open(game, mon, moveId, onDone)` is unchanged (`src/LearnMove.lua:55`). It returns true when a screen will call `onDone`, false when the caller must fall back.

## 5. Work breakdown — test tasks

| ID | Layer | Covers | Owned files | Acceptance |
| --- | --- | --- | --- | --- |
| T4 | integration | T1, T2 | `tests/rby_mmo_test.lua` | A new section, run from the engine root (`luajit mods/rby_mmo/tests/rby_mmo_test.lua`). Fixture: `game.generation = 2`, empty stack, `learnMoveOn` pushes a marker state and records `(mon, moveId, done)` without calling `done`, `onFinish` and `onDone` are the same function that pops the top and sets a fade flag. (1) Fifth move, buried engine present: after `onBattleOver("win", game, nil, toLearn)` the fade flag is set, the pop did not remove the learn marker, the marker is top, and `learnMoveOn` was called once with that party mon and that move. (2) `toLearn` nil or `{}`: `learnMoveOn` was not called, the fade flag is set, the stack has no learn marker. (3) No `engineBattle` (party fight): `learnMoveOn` still runs once. (4) `"loss"` with a fifth move: `learnMoveOn` runs once, and `ui.push` was not asked for `Gen2EvolutionAnim`. (5) Two entries: the second `learnMoveOn` happens only inside the first `done(true)`. (6) Evolution: invented species, `evolutions = { { method = "EVOLVE_LEVEL", level = 7, into = "MOTH" } }`, party mon at level 7, `state.leveledUp` keyed by that mon, `toLearn` aimed at it. Stub `ui.push` of `Gen2EvolutionAnim` so it stores `onDone`, replaces `party[index]` with a new table, and does not call `onDone` yet. After `onBattleOver` returns, `learnMoveOn` has not been called. Calling the stored `onDone` pops and then `learnMoveOn` receives the **new** table. (7) Same, but the new table already has the move: `learnMoveOn` is not called. Existing `offerEvolutions` / `checkParty` cases (`tests/rby_mmo_test.lua` around 10472 and 10815) stay green. No ROM species names. |
| T5 | unit | T3 | `tests/solo_battle.lua` | Section 10 still expects exactly one prompt, after the pop, over the world. The screen name stays `"MoveLearnMenu"`: this file sets `package.path = ""` (`tests/solo_battle.lua:32`), so `Gen.generation` is 1 and `LearnMove.open` takes the Gen 1 arm. Do not un-blank `package.path` and do not expect `learnMoveOn` here. Update the stub at `tests/solo_battle.lua:80` so it records a 5th argument, and assert the Gold and Gen 1 cases pass a function (the completion callback). Update the comments at `tests/solo_battle.lua:75` and `tests/solo_battle.lua:1087` so they describe `LearnMove.open` rather than a direct `MoveLearnMenu` push. `luajit tests/solo_battle.lua` from this repo passes. |

E2e applies to the after-fight prompt: a player-visible ending that crosses the co-op screen, the state stack, and the Gen 2 fade. The harness is `bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh` from the engine root (`~/Projects/alamops/gen1recomp`), after `scripts/setup.sh --rom`, with this tree symlinked as `mods/rby_mmo`. It starts two LÖVE instances. It does not script a level-up into a full moveset, and this plan does not add that scene. The headless section in T4 is the regression. The live confirmation — Crystal or Gold, Butterfree 12→13, Poisonpowder, YES/NO, fade completes, no white lock — is the owner's pass, not a new driver.

Run recipe for the wave barrier, from the engine root:

```sh
luajit mods/rby_mmo/tests/rby_mmo_test.lua
luajit mods/rby_mmo/tests/solo_battle.lua
luajit mods/rby_mmo/tests/coop_mediated.lua
```

`solo_battle.lua` also runs from this repo as `luajit tests/solo_battle.lua`. `node server/hub.test.js` does not cover this UI. Do not run it for this change.

## 6. Execution waves

One checkpoint per wave. Do not checkpoint inside a wave: T2 alone makes the ending tests red until T4 and T5 land.

**Wave 1 — T1.** Additive callback. No caller passes it yet. Barrier: existing `rby_mmo_test.lua` evolution cases and `coop_mediated.lua`'s `finishBuriedBattle` cases still pass.

**Wave 2 — T2, T3, T4, T5, T6 in parallel.** Disjoint files. They code against the signatures in §4. Barrier: the three `luajit` commands in §5 pass, and the version strings agree.

Owned-file check: Wave 1 is only `src/EvolveFx.lua`. Wave 2 is `src/Coop.lua`, `src/SoloBattle.lua`, `tests/rby_mmo_test.lua`, `tests/solo_battle.lua`, and the four version files. No path appears twice in a wave.

## 7. Blast radius & risks

- Every co-op ending that holds `engineBattle` pops before the prompt, not only fifth-move endings. The empty-`toLearn` assertion in T4 is what keeps that pop from eating a screen we just pushed.
- Solo Gold (real generation 2) offers evolutions later: after `settleStack`, not before `onDone`. Solo Gen 1 order is unchanged. A Gold fixture in `tests/solo_battle.lua` is not generation 2; T3 must not treat `ritualPops` alone as "offer evolutions again" or those fixtures call `checkParty` twice and warn.
- `offerForgets` is shared. The Gen 2 screen change is inside it, gated by `LearnMove.open`'s generation check, so Gen 1 solo and Gen 1 co-op stay on `MoveLearnMenu`.
- Delaying `blackout` until the first prompt is up changes a Gen 1 **loss** that also has a fifth move: the warp pump used to see the menu because the menu was pushed first. T2 keeps that. A Gen 2 loss still never reaches the center through `pumpBlackout`'s `isOverworld` check. That failure is older than this fix.
- `Gen2EvolutionAnim` teaches the new species' level-up moves, and may itself call `learnMoveOn`, before `onDone`. Skipping an entry the live mon already knows avoids a second ask for that same move. It does not try to retarget mid-fight `toLearn` lists; `retarget` already does that.
- Rollback is reverting the mod. No save format and no PROTOCOL change.
- Do not edit `World:startBattle`, `Game2:learnMoveOn`, `src/LearnMove.lua`, `src/Sessions.lua`, or `pumpBlackout`.

## 8. Open questions / assumptions

The owner skipped the grill form. The plan locks these. Flip one only by changing this plan before code.

| # | Assumption | If it is wrong |
| --- | --- | --- |
| 1 | The YES/NO stays after the co-op fight. The in-fight line stays an announcement. | This plan is the wrong shape. The hub choice clock has to pause, and PROTOCOL stays unchanged only if the choice remains local. |
| 2 | The prompt opens on the white fade, as soon as the pop has run, not over the map after the fade. | Needs a deferred pump. Gen 2 "back in the world" is an empty stack, not `top.isOverworld`. Do not build that pump on `pumpBlackout`. |
| 3 | The opener is `LearnMove.open`. Solo Gen 2 moves to `learnMoveOn`. Gen 1 stays `MoveLearnMenu`. | Solo Gen 2 does not change screens. Waterfall and Whirlpool stay on the Gen 1 HM rules. The second move still needs a real completion callback. |
| 4 | Evolution, then YES/NO, in this change. Gen 2 evolutions move out of the shared finisher. | Drop the `finishBuriedBattle` / `syntheticFinish` / `SoloBattle:_ended` reorder (T1's callback and T3). The learn prompt still opens after the pop. A Pokémon that evolves and learns in one fight keeps today's evolution-before-pop behavior. This is the assumption that widens the edit. |

Also proceeding on, from the code rather than the form:

- **Loss warp.** After the prompt closes on Gold, `pumpBlackout` can still give up because the overworld is not `isOverworld`. Out of scope. Wrong if a reviewer treats "lost the fight and never reached the center" as part of #105.
- **Rebind.** The after-fight anim does not call `retarget`. The prompt reads `party[partyIndex]` after `onDone`. Wrong if some other after-fight path already rewrites the `toLearn` mon and also replaces the party slot with a different index.
- **Blackout timing** (§3.5) is a plan decision so Gen 1's immediate warp does not skip the menu. It is not a change to the wait itself.

## 9. Completeness ledger

| Item | Disposition | Task ID / reason / who deferred |
| --- | --- | --- |
| `onBattleOver` offers the prompt before `consume`, so Gold's `onDone` pops the learn text | In this run | T2 |
| `offerForgets` pushes `MoveLearnMenu` and does not wait | In this run | T2, via `LearnMove.open` |
| Gen 2 evolutions pushed inside `finishBuriedBattle` and `syntheticFinish` before the pop | In this run | T2 moves the call; T3 is the solo caller; T1 is the callback |
| Prompt must name the post-evolution party record | In this run | T2 `stampLearnIndex` + rebind. T4 case 6 |
| Solo Gold shares the finisher and `offerForgets` | In this run | T3, T5 |
| Loss / whiteout with a fifth move still offers YES/NO | In this run | T2, T4 case 4. The center warp on Gold stays broken; see the ledger row below |
| `pumpBlackout` waits for `top.isOverworld` | Out of scope | Gold's overworld is not a stack state (`src/Coop.lua:768`). A different ticket. This change does not build the fade-wait on it |
| `Sessions:offerForgets` | Out of scope | 1v1 leftover. It does not call Gold `onDone` |
| Mid-award co-op forget UI, PROTOCOL, `affects_link`, `World:startBattle`, `Game2:learnMoveOn` | Out of scope | Assumption 1. Both engine functions are upstream |
| `src/LearnMove.lua` | Out of scope | Already the right opener. T2 calls it |
| Party-versus-party and a joiner with no `engineBattle` | In this run | T2, T4 case 3. `consume` is a no-op; the prompt still opens |
| Comments that say co-op never had this pop, and that the Gen 1 screen is the Gold prompt | In this run | T2 (`src/Coop.lua:2932`, `src/Coop.lua:2942`), T3 (`src/SoloBattle.lua:1237`) |
| Stale `Client.lua:2523` citation in the solo header | In this run | T3, while that comment is rewritten. The alias is `src/Client.lua:2602` |
| Changelog and the version strings that must match it | In this run | T6. 1.1.10's banking sentence stays |
| Headless regression | In this run | T4. `tests/coop_mediated.lua` `finishBuriedBattle` cases are Gen 1-shaped and must stay green without that file being edited |
| `tests/solo_battle.lua` counts a `MoveLearnMenu` push | In this run | T5. Screen name stays, because this suite cannot see generation 2. The callback argument is the new pin |
| Second ask for a move the evolution anim already taught | In this run | T2 skip, T4 case 7. The anim's own `learnMoveOn` is upstream and stays |
| Live Crystal/Gold co-op pass | Owner confirmation, not a coded task | The e2e harness applies but does not script a full-moveset level-up. Adding that driver is a ROM scene, not this fix. T4 is the pin |
