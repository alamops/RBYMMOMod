# Investigation — Learning a new move during co-op battles
| Field | Value |
| --- | --- |
| Date | 2026-10-21 |
| Change | Fix issue #105: a Gen 2 co-op battle where a full moveset levels into a new move shows the "trying to learn" line with no YES/NO, then the screen sticks on white. Decide how the after-fight prompt is ordered against Gold's battle-return pop and fade. |
| Agents | inline (pipeline forbade subagents): codebase + engine read, 1 spike |
| Flags | none |

## 1. What we know

Issue [#105](https://github.com/alamops/RBYMMOMod/issues/105) (Crystal, confirmed on Gold): a Pokémon with four moves levels up in a co-op battle (Butterfree 12→13, Poisonpowder). The learn line appears with no replace/skip choice. After the battle the screen goes white and the game soft-locks; unsaved progress is lost on restart.

This is not "the new move never lands on the save." That was fixed in 1.1.10 (`84a09b9`, CHANGELOG around `CHANGELOG.md:347`). A free slot is taught during the fight and published as `mmo.battle_moveset`. A full set is a choice only the owner can make. Standing decision (2026-09-01): 1v1 and wild open that choice mid-award; co-op banks it and offers it after the fight, because a forget menu mid-fight would sit through the hub's choice timeout and stall the other humans.

What the player sees during the fight is only an announcement. `CoopBattle:teach` (`src/CoopBattle.lua:8401`) applies a free slot immediately, and on `"full"` appends `{ mon, move }` to `toLearn` and says `"<name> is trying to learn <move>!"` (`src/CoopBattle.lua:8414`). That line has no YES/NO. The real prompt is `Coop:offerForgets`, called from `Coop:onBattleOver` (`src/Coop.lua:2896`) after `CoopBattle:finish` has already popped the co-op screen (`src/CoopBattle.lua:4246`, exit at `src/CoopBattle.lua:1332`).

`offerForgets` (`src/Coop.lua:2954`) pushes the Gen 1 screen `MoveLearnMenu` and does not pass a completion callback. `MoveLearnMenu:enter` (`engine src/ui/MoveLearnMenu.lua:42`) immediately pushes a `TextBox` whose `opts.choice` is what creates the YES/NO `ChoiceBox` — on the text box's **next** update, once the page has typed out (`engine src/render/TextBox.lua:622`), not during `enter`.

Gen 2's buried battle is taken off the stack when the co-op fight **starts**, without calling its finisher, and held on `engineBattle` (`src/Coop.lua:2776`). `Client` aliases that state's `onDone` onto `onFinish` (`src/Client.lua:2602`). At the end, `finishBuriedBattle` (`src/Coop.lua:504`) calls that function. Gold's `World:startBattle` closure (`engine src/world/gen2/World.lua:6996`) **always** `game.stack:pop()`s, then, unless this is a whiteout or a script is still running, calls `battleReturnFade` (`engine src/world/gen2/World.lua:3701`), which sets the world fade to full white and arms `mapSetup`.

`onBattleOver` offers the forget prompt **before** that call (`src/Coop.lua:2896` then `src/Coop.lua:2921`). The pop therefore removes whatever `offerForgets` just put on top — the `TextBox` — and leaves `MoveLearnMenu` underneath. `MoveLearnMenu:update` returns immediately while `selecting` is false (`engine src/ui/MoveLearnMenu.lua:86`), so nothing is drawn and no input is accepted. `Game2`'s logic tick updates only the top state and returns (`engine src/core/Game2.lua:1314`), so `World:step` never runs and `mapSetup` never advances (`engine src/world/gen2/World.lua:11321`). The fade stays at full white.

A fight with an empty `toLearn` does not push a menu. The same pop hits an empty stack (Gen 2's overworld is not a stack state) and the fade is free to tick. That matches a report that only shows up when a fifth move is pending. Party-versus-party has no `engineBattle`, so `consume` is a no-op and would not hit this pop; wild and trainer walk-ins do. PvP does not grant EXP (`LEARN_MODES` is wild / coop_wild / coop_npc), so this is a PvE co-op level-up.

Gen 1's `onFinish` does not pop. `SoloBattle:_ended` already special-cases Gold: it runs the finisher (whose pop removes the battle, because solo leaves that battle on the stack) and only then calls `Coop.offerForgets` (`src/SoloBattle.lua:1251`, `src/SoloBattle.lua:1402`). Co-op cannot copy that stack shape. It removed the battle at the start so it would not resume when the co-op screen popped.

`LearnMove.open` (`src/LearnMove.lua:66`) is the path 1v1 uses, and on Gen 2 it calls `Game2:learnMoveOn` (`engine src/core/Game2.lua:592`): the cart's Yes/No, `Gen2MoveDeleter`, and the Gen 2 HM list (Waterfall, Whirlpool). `offerForgets` does not use it. Its own comment (`src/Coop.lua:2942`) says the Gen 1 screen "works on Gold." The YES/NO widget is the shared `TextBox` choice, so that can be true **if the text box is still on the stack when it updates**. Today's co-op ending removes it first. `MoveLearnMenu`'s HM set is also the Gen 1 one (no Waterfall / Whirlpool).

`Sessions:offerForgets` (`src/Sessions.lua:694`) is the 1v1 leftover twin. It pushes `MoveLearnMenu` with a completion callback and does not call the Gold `onDone`. It is not this lock. Solo shares `Coop.offerForgets` but orders the Gold pop first, so it does not hit this lock either.

## 2. What we proved

| Question | Verdict | Evidence | Versions | Artifact |
| --- | --- | --- | --- | --- |
| Does `onBattleOver` with a fifth move let the Gen 2 finisher pop the learn text and leave `MoveLearnMenu` up while the fade is armed? | Yes | `luajit /tmp/spikes/coop-learn-105/repro.lua` loaded real `Coop` and called `onBattleOver("win", …, toLearn)`. Output: `popped=TextBox left=MoveLearnMenu faded=true pushed=1`. | LuaJIT 2.1.1785192264, this worktree, stub `ui.push` that mirrors `MoveLearnMenu:enter` pushing a TextBox | `/tmp/spikes/coop-learn-105/repro.lua` (scratch, not in the repo) |
| Does the same ending with no fifth move pop a screen? | No | Same command, `toLearn` nil. Output: `popped=(empty) left= faded=true pushed=0`. | same | same |

The spike stubs the finisher as "pop top, arm fade." It does not boot Gold. The pop-then-fade behavior it stands in for is the closure quoted above, not an inference.

Not proved on a ROM: that a live Crystal client draws full white for a stuck `battleReturnFade`, or that Butterfree's level-13 learnset is Poisonpowder. The report states both, and the fade flag plus a menu that blocks `World:step` is the white lock the code can produce. A headless suite cannot paint that frame.

## 3. What we're assuming

- The "dialog with no YES/NO" the report describes is `CoopBattle:teach`'s announcement. The after-fight `MoveLearnMenu` text never gets a frame, because it is popped inside `onBattleOver` before the next draw. If a build somehow showed `MoveLearnMenu`'s own pages, the missing YES/NO would still be this pop: `ChoiceBox` is created on the text box's next update.
- Both clients in a same-map wild or trainer divert each hold a buried engine battle (the walk-in path stamps `plan.engine`; wait-and-join trainers each triggered their own). A joiner with no `engineBattle` would keep the menu and would not white-lock. The two reports matching is consistent with both players holding a battle.
- We keep the 2026-09-01 decision: co-op does not open the forget UI mid-award. The fix makes the after-fight prompt actually appear and lets the return fade finish. If that decision is reopened, the plan changes (hub choice clock, other humans, PROTOCOL unchanged).
- Recommended order, matching solo's Gold rule as far as co-op's already-popped battle allows: run `consume` / `syntheticFinish` **before** `offerForgets`, so the unconditional `stack:pop()` hits an empty stack, then open the prompt. The prompt's `update` will still pause `World:step`, so the white fade stays up **behind** the dialog and ticks only after the prompt closes. Waiting until the fade has finished and then opening over the map is the alternative; it needs a pump, and Gen 2 "back in the world" is an empty stack, not `top.isOverworld` (`src/Gen.lua` header; `pumpBlackout` at `src/Coop.lua:768` still waits for `isOverworld`).
- The prompt itself should go through `LearnMove.open` so Gen 2 uses `learnMoveOn`. Reordering alone leaves the Gen 1 HM list and `offerForgets`'s "push the next menu immediately" sequencing (`src/Coop.lua:2986` says `"..."` in the same call, not when the first menu finishes). `Sessions:offerForgets` stays a twin in shape (`{ mon, move }`) but is a different ending and is not required to switch in the same change unless we want one forget opener.

## 4. What we must ask the owner

1. **Keep the prompt after the fight?** The recorded decision says yes, because a mid-award Yes/No does not pause the hub choice clock and would stall the other players. The report's expected result ("YES/NO, and the battle ends normally") is satisfied either way. Reopening mid-award is a different change than #105. Confirm we do not reopen it.
2. **Where does that prompt sit relative to the white return fade?** (A) Open it as soon as the finisher has popped, on the white field; the map fades in after they answer. Smallest change; the dialog is visible because it draws over the world. (B) Let `battleReturnFade` finish, then open over the map. Reads more like "the battle ended, now choose," and needs a deferred pump that understands Gen 2's empty stack. This chooses the task, not a detail inside it.

## 5. Completeness inventory

- Callers of the after-fight prompt:
  - `Coop:onBattleOver` → `Coop:offerForgets` (`src/Coop.lua:2896`, `src/Coop.lua:2954`) — the bug.
  - `SoloBattle:_ended` → `Coop.offerForgets` (`src/SoloBattle.lua:1316`) — already orders the Gold pop first. Any signature or Gen 2 screen change inside `offerForgets` changes solo too.
  - `Sessions:offerForgets` (`src/Sessions.lua:694`) — 1v1 leftover twin. Does not call Gold `onDone`. Out of this bug unless the opener is unified.
- Who fills `toLearn`:
  - `CoopBattle:teach` (`src/CoopBattle.lua:8401`) — banks `"full"`, no mid-fight row.
  - `MediatedBattle:teach` / `startLearn` (`src/MediatedBattle.lua:3378`, `src/MediatedBattle.lua:3427`) — 1v1 opens `LearnMove.open` mid-award. Not this bug.
  - `EvolveFx.retarget` (`src/EvolveFx.lua:312`) moves a `toLearn` mon pointer when Gen 2 evolution replaces the party table. Must keep working if the prompt is deferred across the evolution offer. Today evolutions run inside `finishBuriedBattle` (`src/Coop.lua:524`), which is **after** `offerForgets` pushes a menu aimed at the pre-evolution mon. Swapping the order puts evolutions first; the prompt must use the post-evolution mon or `retarget` has to have already run. Load-bearing for the reorder.
- Finisher: `Coop.buriedFinisher` / `finishBuriedBattle` (`src/Coop.lua:464`, `src/Coop.lua:504`). Do not edit `World:startBattle`'s `onDone`. That pop is the cart's battle return. The mod has to call it when the top of the stack is the thing it is allowed to pop (nothing, on this path).
- Propagation: no wire change. `toLearn` stays `{ mon = save party mon, move = move id }`. No PROTOCOL bump. `affects_link` stays false; this does not write link registries.
- Existing data: none. No migration.
- Docs that describe today's behavior: `CHANGELOG.md` 1.1.10 (co-op banks the fifth move for after the fight). A fix note belongs in the changelog when the code changes, not in this brief. `src/Coop.lua:2932` and `src/SoloBattle.lua:1231` comments describe the order and will lie if the order changes.
- What a fix would orphan: the claim that pushing Gen 1 `MoveLearnMenu` is the Gen 2 co-op prompt (`src/Coop.lua:2942`). `LearnMove.open` already replaced that for 1v1.
- Tests that pin the old order and would not catch this:
  - `tests/rby_mmo_test.lua` around the co-op `"full"` teach (banks `toLearn`, asserts no mid-fight learn row).
  - `tests/rby_mmo_test.lua` `onBattleOver` walk-in (consume runs; `toLearn` is `{}`).
  - `tests/solo_battle.lua` Gold prompt-over-world cases. Those mock `offerForgets` and never call `Coop:onBattleOver`.
- No test asserts that a Gen 2 `onDone` pop during `onBattleOver` leaves an answerable prompt and does not leave a state with `update` above an armed fade.

## 6. Runnability

- Start locally: engine checkout `~/Projects/alamops/gen1recomp`, this tree symlinked as `mods/rby_mmo`. `scripts/setup.sh --rom "…"` once (Crystal or Gold for this bug), then `scripts/run.sh`. Hub: `node server/hub.test.js` or `scripts/run-server.sh`. Two clients for a real co-op fight.
- Tests: from the engine root, `luajit mods/rby_mmo/tests/rby_mmo_test.lua` (the suite resolves its own tree when `mods/rby_mmo` points elsewhere). `luajit mods/rby_mmo/tests/solo_battle.lua` for the solo ending order. `node server/hub.test.js` does not cover this UI.
- E2E harness: `bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh` after a ROM import. It drives two LÖVE instances. It applies to this bug (a player-visible battle ending that crosses the co-op screen, the state stack, and the Gen 2 world fade) but cannot be the only pin: it needs a ROM, two clients, and a scripted level-up into a full moveset. The headless stack test is the regression pin; a manual Crystal/Gold co-op pass is the confirmation the white frame is gone.

## 7. Risks & blast radius

- Reordering `onBattleOver` changes every co-op ending that holds `engineBattle`, not only fifth-move endings. The no-move case already pops an empty stack; moving `offerForgets` below `consume` must keep that pop empty. Pushing the prompt first is what makes the pop non-empty.
- `finishBuriedBattle` also offers evolutions before `onDone`. A mon that evolves and wants a fifth move must be prompted on the record evolution left in the party. `EvolveFx.retarget` only helps if the prompt is still a `toLearn` entry and not an already-pushed `MoveLearnMenu` aimed at the old table.
- A loss calls the same `onDone`, which may whiteout (heal, halve money, warp) instead of `battleReturnFade`. The prompt has to stay above that warp the way `pumpBlackout` already tries to wait out post-battle menus. `pumpBlackout`'s `isOverworld` check is the wrong "world is back" test on Gold; do not build the fade-wait on it without a Gen 2 empty-stack check.
- `offerForgets` is shared with solo. Switching it to `LearnMove.open` changes the solo Gen 2 prompt from `MoveLearnMenu` to `learnMoveOn`. That is the screen solo's 1v1 cousin already uses. The callback sequencing must still raise one prompt at a time, which solo's tests count (`tests/solo_battle.lua` expects one `MoveLearnMenu` push — those tests stub `ui.push` and will need to expect `learnMoveOn` or whatever the stub records).
- Do not change `World:startBattle` or `Game2:learnMoveOn`. Both are upstream.
- Rollback is reverting the mod's ending order. No save format and no PROTOCOL change.
