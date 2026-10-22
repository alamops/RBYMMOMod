# Grill — Learning a new move during co-op battles
| Field | Value |
| --- | --- |
| Date | 2026-10-21 |
| Source | Issue #105, `docs/plans/learning-new-move-during-co-op-battles-investigation.md` |
| Mode | interactive, question form skipped — proceeding on the recommended answers |
| Flags | none |

The owner was asked four questions and skipped the form. Each answer below is the recommendation from that pass, not a confirmed choice. The plan should follow them and keep §Assumptions at the top of its summary so they can be flipped before code.

## Decisions
| # | Topic | Question | Answer | Source |
| --- | --- | --- | --- | --- |
| 1 | When | Keep the fifth-move YES/NO after the co-op fight, or open it mid-award like 1v1? | After the fight. The in-fight line stays an announcement. A forget menu mid-fight would sit through the hub choice timeout and stall the other players. | Assumption. Standing behavior in `CHANGELOG.md` 1.1.10 (2026-09-01) and `src/Coop.lua:2932`. Reopening it was offered and not taken. |
| 2 | Where | Open that prompt on the white return fade, or only after the fade finishes over the map? | On the white field, as soon as Gold's return pop has run. The dialog draws over the white. The map fades in after the player answers. | Assumption. Recommended because it needs no deferred pump. `battleReturnFade` (`engine src/world/gen2/World.lua:3701`) only advances from `World:step`, and a screen on top stops that step (`engine src/core/Game2.lua:1314`). |
| 3 | Screen | `LearnMove.open`, or keep Gen 1 `MoveLearnMenu` and only fix the stack order? | `LearnMove.open`. One prompt at a time; the next move waits for the answer. Gen 2 uses `Game2:learnMoveOn`. Solo Gen 2, which shares `Coop.offerForgets`, moves to that same screen. Gen 1 still resolves to `MoveLearnMenu`. | Assumption. `src/LearnMove.lua:66`. Today's `offerForgets` pushes `MoveLearnMenu` with no completion callback and paces a second move with `"..."` in the same call (`src/Coop.lua:2986`), which does not wait for the menu. `MoveLearnMenu`'s HM list has no Waterfall or Whirlpool. |
| 4 | Evolve + learn | If one Pokémon evolves and also has a fifth move, fix both orders here, or only the learn prompt? | In this change. Run the return pop while nothing of ours is on the stack, let the evolution finish, then YES/NO for the live party record. | Assumption. Same pop deletes whichever screen was pushed first (`src/Coop.lua:524` then `src/Coop.lua:526`). Butterfree 12→13 does not evolve; the reported bug is the learn-only case. The combined case is in so the reorder does not teach the move onto a party table evolution then replaces. |

## Completeness dispositions
| Item | Disposition | Owner or reason |
| --- | --- | --- |
| `Coop:onBattleOver` offers the prompt before `consume`, so Gold's `onDone` pops the learn text and leaves `MoveLearnMenu` over an armed fade | In this change | The bug. Pop first, while the stack has no learn screen, then open the prompt. A fight with an empty `toLearn` must still pop nothing. |
| `offerForgets` pushes Gen 1 `MoveLearnMenu` and does not wait for it | In this change | Decision 3. Callback from `LearnMove.open`, including the fallback that already auto-fills a free slot or warns. |
| Gen 2 evolutions are pushed inside `finishBuriedBattle` immediately before the popping `onDone` | In this change | Decision 4. After the pop, evolution, then the learn prompt once that screen's `onDone` has run. |
| Learn prompt must name the post-evolution party record | In this change | `EvolveFx.retarget` (`src/EvolveFx.lua:312`) rewrites `holder.toLearn` only for mid-fight movies (`CoopBattle.lua:3913` passes the battle). The after-fight `Gen2EvolutionAnim` `onDone` (`src/EvolveFx.lua:527`) only pops and starts the next evolution. It does not call `retarget`. The prompt binds to the party record that exists when the evolution screen finishes. |
| Solo Gold shares `finishBuriedBattle` and `Coop.offerForgets` | In this change | `SoloBattle:_ended` already finishes before `offerForgets` when `ritualPops` (`src/SoloBattle.lua:1403`). Switching the opener changes the solo Gen 2 screen. Moving the evolution offer to after the pop changes solo Gold's evolution timing the same way. Gen 1 solo stays on `MoveLearnMenu` and must not gain a pop it does not have (`onFinish` does not pop). |
| Loss / whiteout with a fifth move already earned | In this change | Still offer YES/NO after the pop. Gen 2 `offerEvolutions` already returns false on a loss (`src/EvolveFx.lua:463`), so there is no evolution to wait for. The prompt sits above the center warp the way other post-battle screens do. |
| `pumpBlackout` waits for `top.isOverworld` | Out of scope | Gold's overworld is not a stack state (`src/Coop.lua:768`). A center warp that never sees `isOverworld` is a different ticket. This change does not retune that wait and does not build the fade-wait on it. |
| `Sessions:offerForgets` (`src/Sessions.lua:694`) | Out of scope | 1v1 leftover twin. It does not call Gold `onDone` and is not this lock. |
| Mid-award co-op forget UI, PROTOCOL, `affects_link`, `World:startBattle`, `Game2:learnMoveOn` | Out of scope | Decision 1. No wire change. Both engine functions are upstream. |
| Party-versus-party and a joiner with no `engineBattle` | In this change | `consume` is a no-op there, so there is no pop. The prompt must still appear. Do not require a buried battle to open it. |
| Comments that say co-op never had this pop, and that the Gen 1 screen is the Gold prompt (`src/SoloBattle.lua:1237`, `src/Coop.lua:2942`) | In this change | They describe the order this change replaces. |
| Changelog note for the fix | In this change | Written with the code change. 1.1.10's "co-op banks the fifth move" sentence stays true. |
| Headless regression: fifth move leaves an answerable prompt and does not leave a menu above an armed fade; empty `toLearn` still pops nothing | In this change | The pin. `tests/rby_mmo_test.lua` today banks `toLearn` and walks `onBattleOver` with an empty list. `tests/solo_battle.lua` Gold cases that count a `MoveLearnMenu` push have to expect `learnMoveOn` once the opener switches. |
| Live Crystal/Gold co-op pass (two clients, ROM, scripted level-up into a full moveset) | In this change as confirmation | The e2e harness applies (`bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh` from the engine root, after `scripts/setup.sh --rom`). It is not the only pin: it needs a ROM and two LÖVE instances. The headless stack test is the regression. |

## Assumptions still open
- **Decision 1.** If the owner wants the YES/NO mid-award, this plan is the wrong shape. The hub choice clock has to pause for every other human, and PROTOCOL stays unchanged only if the choice remains local.
- **Decision 2.** If the prompt should open over the map after the fade, the plan needs a deferred pump. Gen 2 "back in the world" is an empty stack, not `top.isOverworld`. Do not reuse `pumpBlackout` as that test.
- **Decision 3.** If the opener stays `MoveLearnMenu`, solo Gen 2 does not change screens, Waterfall and Whirlpool stay on the Gen 1 HM rules, and the second-move sequencing still has to grow a real completion callback.
- **Decision 4.** If evolution timing stays as it is, drop the `finishBuriedBattle` reorder. The learn prompt still has to open after the pop. A Pokémon that evolves and learns in one fight keeps today's evolution-before-pop behavior. This is the assumption most worth flipping: it is the only one that widens the edit past `onBattleOver` and `offerForgets` into the shared finisher solo also calls.
- **Loss warp.** After the prompt closes on Gold, `pumpBlackout` can still give up because the overworld is not `isOverworld`. That failure exists before this fix. Wrong if a reviewer treats "lost the fight and never reached the center" as part of #105.
- **`retarget`.** Wrong if some after-fight evolution path already rewrites the `toLearn` mon pointer. The anim callback at `src/EvolveFx.lua:527` does not. Mid-fight movies do, via `CoopBattle.lua:3913`.
