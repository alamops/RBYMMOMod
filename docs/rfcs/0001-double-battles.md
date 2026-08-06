# RFC 0001 — A battle-start seam that can defer, and a note on double battles

**Status:** draft, and **no longer blocking anything** — see "What changed".
**Lane:** B — this proposes an engine change.
**Raised by:** `rby_mmo` (RBYMMOMod), co-op 2-on-2 battles.

This RFC lives in the mod's repo because it is written here. It belongs
upstream, and the work it describes is upstream work.

---

## What changed since the first draft

The first version of this document asked upstream for two things: double-battle
support, and a cancellable battle-start hook. It argued that neither could be
done in a mod.

**Half of that was wrong, and the mod now proves it.** `rby_mmo` ships a working
2-on-2 — four battlers on one field, an ordering over all four, per-action
targeting, faints pulling the next mon out of that trainer's party — built on
top of the engine's own combat modules rather than around them. It did not need
a new engine seam, only `engine_internals` and the fact that `Damage`,
`TurnOrder`, `Status`, `TypeChart` and `BattleState.makeBattler` are all
usable from outside `BattleState`.

**And then the other half turned out to be wrong too.** The RFC went on to ask
for a cancellable battle-start hook, on the grounds that overworld trainer
engagement emits an event and an event cannot cancel. True — but it does not
need to be cancelled. Both ways a trainer battle starts end in
`game.stack:push(battle)`, and a `StateStack` only updates its *top*: so a mod
that listens for `screen.pushed` and pushes its own prompt on top gets a battle
that is frozen and completely untouched underneath, which is a better outcome
than cancelling one. `rby_mmo` does exactly that, and its prompt now appears in
front of every trainer in the game.

So this RFC now asks for **nothing that blocks a mod**. What follows is kept as
a report: two small additions that would still be genuine improvements, and a
record of what the outside-in version ran into.

## Would still be nice — a battle-start seam that can defer

A trainer battle starts two ways, and only one can be intervened in:

| Path | Seam | Can a mod hold it? |
|---|---|---|
| `Commands.start_battle` (`src/script/Commands.lua:263`) | `script.command` hook | **Yes** |
| `OverworldState:engageTrainer` (`src/world/OverworldController.lua:2769`) | `Runtime.emit("world.trainer_engaged", …)` | **No** |

The second is how most trainers in the game are fought — walking into their
line of sight, or talking to them. It emits an **event**, and an event cannot
cancel: a throwing listener is logged and skipped, and the emitting path always
completes. The full `Runtime.wantsHook` call-site list contains no battle-start
seam of any kind.

This is no longer a blocker — see above — but the push-on-top workaround has a
real cost worth naming: the battle has already been *constructed and entered*
by the time a mod can react, so a mod that ultimately replaces it has paid for
a battle nobody fought (sprites decoded, music started) and has to pop it. A
seam that let the decision happen before construction would be cheaper and less
surprising, and would not depend on the "only the top state updates" property
holding forever.

### Proposed shape

```lua
mod.hooks:wrap("battle.starting", function(next, game, request)
  -- request: { kind = "trainer"|"wild", trainerClass, partyIndex, npc, mapId }
  -- call next(...) to proceed; defer by not calling it yet
end)
```

Two properties matter more than the name:

- **Deferral, not cancellation.** A seam that let a mod silently skip an
  encounter would break progression. `rby_mmo` already relies on the
  deferral shape that exists: `Commands.start_battle` ends in `runner:yield()`,
  and a `script.command` link can yield the same coroutine and be resumed from
  a UI callback. `engageTrainer` has no coroutine to yield, which is exactly
  what makes it unreachable — so the hook needs a continuation of its own.
- **Both call sites.** `engageTrainer` and `start_battle` route through it, so
  a mod need not know which one a given trainer uses.

## The report — what a mod-side double battle cost, and what upstream might take from it

Offered as evidence, not as a request. Upstream may reasonably decide a
first-class double battle belongs in the engine; if so, this is what the
outside-in version ran into.

What was reusable as-is, and is the reason this was possible at all:

- `BattleState.makeBattler(data, mon, isPlayer, save)` is exported, and builds a
  battler complete with merged status records, badge rows, `curStats`/`curTypes`
  and a battle sprite.
- `Damage.compute(ruleset, attacker, defender, move, opts)` takes two battlers
  and nothing else — no battle object, no side state. Every part of the Gen 1
  formula came for free.
- `TurnOrder.effectiveSpeed(battler)` is exported separately from
  `firstMover`, which is the single most useful split in the file.
- `Status.beforeMove` / `Status.residual` take a battler and a `battle` whose
  only required field is `.data`.

What had to be written outside, because the shapes are pairwise:

- **Ordering over N.** `TurnOrder.firstMover(a, aMove, b, bMove, …)` answers
  "does a precede b". A four-way field needs "in what order do these four go",
  and a pairwise comparator cannot be lifted to that without also deciding the
  tie rule. A `TurnOrder.order(battlers, …)` with `firstMover` kept as the
  two-battler case would be the smallest useful addition upstream.
- **Targeting.** No move record carries a target, because in a 1v1 there is
  only one. A `target` field defaulting to "the one opposite" would leave every
  vanilla move byte-identical.
- **Nothing, as it turned out, in the effect system.** An earlier draft of
  this RFC claimed `MoveEffects`/`EffectRegistry` were bound to
  `battle.player`/`battle.enemy` and were the blocking piece. That was wrong,
  and worth correcting in the record: **neither module mentions either side
  anywhere.** `makeCtx` takes `user` and `target` as arguments, and everything
  else it wants it asks for through about fourteen battle methods. So does
  `performMove`.

  The mod therefore reuses all of it, by making its field object inherit from
  `BattleState` (`__index`) and overriding only the four things that genuinely
  assume two battlers — `onFaint`, `sideOf`, `cancelMoveAnim`, and the queue.
  The move that runs in a co-op battle *is* `BattleState.performMove`.

  The lesson for upstream is a compliment rather than a request: the effect
  surface was already written against an explicit user and target, and that is
  exactly what made a field shape it was never designed for possible from
  outside. The only additions that would have helped are `TurnOrder.order` and
  a move-record `target` field, both listed above.
- **Composition.** Four pics and four status panels do not fit the classic
  160×144 arrangement comfortably. The mod draws its own compact layout with
  the engine's `Font` and `HudTiles`, so palette and asset mods still own the
  look; a first-class version would probably want `WideBattle`'s 304 px.

If upstream does take double battles on, the compatibility bar is the same one
this RFC always stated: additive only, `self.player`/`self.enemy` and
`firstMover` unchanged forever, no vanilla battle differing by a single value,
and a parity test pair proving it.

## The five obligations

Per CLAUDE.md, a Lane B change carries five. For the seam actually being asked
for:

1. **RFC.** This document, upstream as `docs/rfcs/0001-battle-start-seam.md`.
2. **Backward compatibility.** Purely additive. `world.trainer_engaged` keeps
   being emitted alongside the new hook, and a mod that wraps neither sees no
   change.
3. **Parity test pair.** (a) vanilla unchanged with no mod installed — trainer
   engagement from both call sites, asserting identical behaviour; (b) the new
   seam driven through the *public* mod API, deferring and then resuming.
4. **Regenerated docs.** `luajit tools/gen_registry_docs.lua`, plus the wiki's
   hook table.
5. **Deprecation etiquette.** Nothing removed; the event stays forever.

## What would land in the mod if this were accepted

One listener moves. `src/Client.lua`'s `screen.pushed` listener becomes a
`battle.starting` link, and the mod stops having to pop a battle the engine had
already built. Nothing in `src/Coop.lua`, `src/CoopSim.lua`, `src/CoopField.lua`
or `src/CoopBattle.lua` changes — which is the point: the mod is not waiting on
this, it would just be tidier.
