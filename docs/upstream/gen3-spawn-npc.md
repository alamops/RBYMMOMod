# Upstream proposal (Lane B) — the game3 seams `rby_mmo` needs: runtime objects, the player's look, screen events, battle takeover, neighbour-map objects and trainer draws

**For:** `bryanthaboi/gen1recomp`, the game3 (FireRed / LeafGreen / Emerald)
mod surface. Against `dev` @ `fdea09dc`.
**Found by:** `rby_mmo`, porting its shared overworld to Gen 3.
**Status:** a proposal. `rby_mmo` 1.5.0 ships on Gen 3 with the reach-arounds
described below, isolated in a handful of files (`src/Avatars.lua`,
`src/Cast.lua`, `src/CoopField.lua`, `src/Gen3Ui.lua`, all reaching the engine
through `src/Gen3.lua`) and each behind a `pcall`; every module-function wrap
goes through one discipline, `Gen3.wrapFn` / `unwrapFn`, which keeps the
original and re-applies rather than stacks on a hot reload. Nothing in this
document is a workaround we intend to keep once a seam exists.

**One request.** This is everything the Gen 3 port asks of the engine, meant to
go upstream as a single RFC rather than as separate asks:

1. **Runtime objects, `player.sprite` and `screen.*` on game3** (the body of
   this document), with the **battle takeover** seam, `battle.intercept`
   (addendum A).
2. **Runtime objects on a neighbouring map**, so a player across a seamless
   map edge is drawn (addendum B; closes `docs/plans/gen3-known-gaps.md` §4).
3. **A draw answer for `trainerbattle`**, so a mod-refereed fight that ends
   with nobody beaten leaves the trainer to be fought again without the mod
   stopping the script VM from outside (addendum C; closes §7).
4. **A demonstration seam for the TEACHY TV**, so the POKé DUDE's battles
   can be fought on a mod's screen without the mod lifting the modal stack,
   toggling menu singletons and swapping the save's party and bag itself
   (addendum D).

The two later seams build on the first: B is `spawnNpc` taught about the maps
the field already draws around the current one, and C is the third answer
`battle.intercept`'s `spec.finish("draw")` needs from the opcode.

## Summary

On a Gen 1 or Gen 2 boot a mod puts a remote player on the map with
`mod.world:spawnNpc`, drives it with a handle, dresses the local player through
the `player.sprite` hook, and learns that a battle or a menu arrived from
`screen.pushed`. On a game3 boot none of those four exists:

| Seam | Gen 1 / Gen 2 | game3 today |
|---|---|---|
| `mod.world:spawnNpc(mapId, def)` | runtime NPC, returns an id | `nil, "not supported on FireRed yet"` (`src/world/game3/WorldAPI.lua:432`) |
| `mod.world:removeNpc(id)` | removes the runtime NPC | hides a *template* object and sets its hide flag (`:453`) |
| `player.sprite` hook | the player's walking sheet | never raised (no call site under `src/core/game3`) |
| `screen.pushed` / `screen.popped` | every state push / pop | never raised; the game3 modal stack (`src/ui/game3/stack.lua`) has no emit |
| a runtime object on a neighbouring map | not needed (no objects are drawn across a Gen 1 / Gen 2 connection) | no way in: `spawnNpc` is unsupported and the neighbour pools are private (addendum B) |
| a draw answer from `trainerbattle` | not needed (the buried battle's own finish takes the result) | none: `"lose"` runs the bytes after the opcode, anything else marks the trainer beaten (addendum C) |

This asks for the smallest additive surface that closes the gap, in the shape
the Gen 1 / Gen 2 API already has, so a mod written against those carries over.

## What `rby_mmo` does today, and why each piece is fragile

### 1. Remote players as injected event objects (`src/Avatars.lua`)

A remote player is built exactly the way the engine builds its own objects —
`Objects.spawnFromDefs({ template }, mapDef, mapId)` from
`src/core/game3/objects.lua` — and then written into the live list by hand:

```lua
Objects._byId[lid] = eo
Objects._order[#Objects._order + 1] = lid
```

with `eo.passable = true` so `Objects.blocks` lets the player through, and a
localId of `0x1000 + n` so no script opcode (a byte) can address it and no
seamless-edge carry id (`FOREIGN_BASE` `0xC0..0xFE`) can collide with it.
Steps are started with `Objects.pushStep(eo, dir, frames)` at 16 / 8 / 4
frames a tile. From there the engine does everything: FieldView draws it with
the cart's own overworld sheet, sorts it against the player and the NPCs, and
animates its walk cycle.

What that costs:

- **`Objects.loadMap` wipes `_byId` / `_order` on every load and every same-map
  reload.** The mod re-checks every tick that the table under its localId is
  still its own and puts it back. One frame after a reload can draw without the
  avatar.
- **It depends on three private fields** (`_byId`, `_order`, `_tracks`) and on
  `pushStep`, none of which is documented, and any of which a refactor of
  `objects.lua` could rename.
- **`startTrack` could not be used** (it is what the spike used and what
  `Handle:scriptMove` uses): `Objects.carryOut` carries every object with a live
  track across a seamless map edge and renumbers it into the carry range, so an
  avatar mid-track while the local player crosses into the next town would
  follow them under a borrowed id.
- **The A press.** `Field.interact` only raises `world.talk` for an object with
  a `scriptKey` (`src/core/game3/field.lua:944`, raised at `:957`), so the template carries a key
  no map has (`"rby_mmo:avatar"`) purely to be asked, and the mod's
  `world.talk` link consumes the talk by not calling `next()`. Without the key,
  facing another player and pressing A does nothing at all — the
  `world.interacted` event the Gen 1 / Gen 2 flow opens the player menu from is
  never emitted for an object the engine considers mute.
- **Depth ties.** `FieldView` sorts equal priorities by `py`, then by
  `a.i` — the object's localId — and the player's actor has none (`src/core/game3/field_view.lua:501`). An avatar
  standing on the player's tile would be drawn *over* the player; the mod lifts
  a standing avatar's `py` by `0.01` (the Gen 1 rule, `Config.AVATAR_DEPTH_NUDGE`)
  so it loses the sort. That is a draw-order hack in a field the engine also
  uses as a position.
- **The FRLG quest-log recap** captures everything in `Objects.forDraw()`, so a
  recap would show another player standing where they stood — and, since the
  recap is saved, keep them in the save. The mod filters its own objects out
  (see "Quest-log persistence" at the end).

### 2. The player's own look (`src/Cast.lua`)

The player is drawn from one number per frame,
`OwSprites.playerGraphicsId(game, player)` (`src/core/game3/ow_sprites.lua:528`),
which picks the walking, bike, surf, fishing, field-move or VS Seeker graphic
for the avatar's state. With no `player.sprite` hook, the mod replaces that
module function with a wrapper: the engine's answer is kept unless it is the
plain walking graphic, in which case the chosen look's graphic is returned. The
original is stashed on the module (`__rby_mmo_playerGraphicsId`) so a hot
reload re-wraps the pristine function instead of stacking, and
`Cast.restoreLook3` puts it back (or, if another mod wrapped on top, retires the
wrapper in place). A wrapper left behind by an unloaded instance answers vanilla
because it checks `mod.find(id).exports == mod.exports` on every call.

This is the reach-around most likely to collide with another mod: any second
mod doing the same to the same function stacks in load order with no chain to
arbitrate it.

### 3. Screens and battles

`screen.pushed` has no game3 emit, so everything the Gen 1 / Gen 2 mod learns
from it (a battle arriving, a menu covering the field) is polled from
`src/ui/game3/stack.lua` and `src/core/game3/battle.lua` instead. Encounter
diversion is split: step wilds go through the public `encounter.roll` hook,
which does fire on game3, while trainers — and the wild fights that never pass
that hook (fishing, Rock Smash, Sweet Scent) — are taken by wrapping
`BattleBridge.start`, because a `script.command` link on `trainerbattle` could
only replace the whole opcode and would then have to suspend the VM through a
private poll. That wrap, its costs and the `battle.intercept` seam that would
replace it are described in the addendum at the end.

## Proposed API delta

All additive. Every existing call keeps its current behaviour when the new
arguments are absent.

### `WorldAPI:spawnNpc(mapId, def)` on game3

```lua
local id = mod.world:spawnNpc(mapId, {
  name = "mmo_42",                         -- WorldAPI:npc(mapId, name) finds it
  x = 7, y = 9, facing = "down",
  graphicsId = 14,                         -- or gfx = "OBJ_EVENT_GFX_RS_BRENDAN"
  movementType = 0,                        -- MOVEMENT_TYPE_NONE: stands, turns when driven
  passable = true,                         -- Objects.blocks skips it
  talk = true,                             -- raise world.talk for it without a scriptKey
})
```

- Allocates a localId from a range reserved for runtime objects (above `0xFF`,
  never in the carry range) and returns it.
- **The engine owns persistence across reloads:** a runtime object spawned on
  `mapId` is re-inserted by `Objects.loadMap(mapId)` after the template pass,
  where it stood, until `removeNpc` or a load of a *different* map. That is the
  whole of what the mod's per-tick re-injection exists for.
- `removeNpc(id)` on a runtime id removes it from `_byId` / `_order` / `_tracks`
  (no hide flag); on a template id it keeps today's behaviour.
- Runtime objects are never carried by `carryOut` unless spawned with
  `carry = true`.

### `Handle:stepNow(dir, frames)` — an optional pace

`Handle:stepNow` already starts one step with no track and no input lock,
which is the right primitive; it only lacks the pace. An optional `frames`
(one of `STEP_PIXELS`' rows: 16, 8, 4, …) closes that, and removes the mod's
last use of `Objects.pushStep`.

### `world.talk` for runtime objects

Raise `world.talk (next, game, eo)` for any object spawned with `talk = true`
even though it carries no `scriptKey`; vanilla (`next`) does nothing for such
an object. `world.interacted` then fires with `kind = "npc"` as it does today.

### Draw-order tie-break

Either sort the player actor ahead of runtime objects on a tie
(`a.i = PLAYER_LOCAL_ID` for the player actor would do it), or accept a
per-object `subpriority` bias on the spawn def. Either removes the `py` nudge.

### `player.sprite` on game3

Raise the existing hook from `OwSprites.playerGraphicsId`:

```lua
mod.hooks:wrap("player.sprite", function(next, value, ctx)
  -- game3: value = the graphic id the engine chose; ctx = { generation = 3,
  -- state = "NORMAL" | "MACH_BIKE" | "SURFING" | ..., gender = 0 | 1 }
  return next(value, ctx)
end)
```

The `ctx.generation` field keeps a Gen 1 / Gen 2 link (which expects a sheet
path) from misreading a number; the hook's Gen 1 / Gen 2 contract is
unchanged. Guarded by `Runtime.wantsHook("player.sprite")`, so an unhooked
frame allocates nothing.

### `screen.pushed` / `screen.popped` on game3

Emit from `Stack.push` / `Stack.pop` with `{ id = layerId, layer = mod }`
(the game3 layer, not a Gen 1 state), plus `battle.started` already covering
battles. Guarded by `Runtime.wants`.

## Backward compatibility

- No existing signature changes. `spawnNpc` on game3 goes from "unsupported" to
  supported; a mod that tested for `nil, "not supported"` and fell back keeps
  working, because the fallback is simply no longer taken.
- `removeNpc` on a *template* id is untouched; only runtime ids get the new
  removal.
- `stepNow(dir)` with no `frames` is today's call.
- `world.talk` fires for nothing it did not fire for before unless a mod asked
  for it (`talk = true`).
- `player.sprite` on game3 is a new call site for an existing hook, with the
  generation in `ctx`; no Gen 1 / Gen 2 call site moves.
- Addendum B changes nothing for a map with no runtime objects: the same pools
  are built, captured and adopted. Addendum C gives one new string a meaning
  in the `trainerbattle` continuation; every answer it took before keeps its
  meaning, and an unknown one still counts as a win.
- The link fingerprint is unaffected: none of this touches a
  `Manifest.LINK_REGISTRIES` registry.

## Obligations (CLAUDE.md, "If upstream itself needs to change")

1. **RFC** — one, `docs/rfcs/NNNN-game3-mod-seams.md`, covering the delta
   above and addenda A, B and C.
2. **Backward-compatibility statement** — the section above, in the RFC, with
   each addendum's own.
3. **Parity test pair** for each seam (addenda A, B and C state theirs):
   - *vanilla unchanged with no mod installed*: a game3 map load, A press on a
     template NPC, and a frame of `playerGraphicsId` produce the same objects,
     the same script start and the same graphic id as before;
   - *the new seam through the public mod API*: a `tests/modkit/cases/`
     case that spawns a runtime object through `mod.world:spawnNpc` on a
     headless game3 load, reloads the map and asserts it is still there,
     steps it with `stepNow(dir, 8)`, talks to it through `world.talk`, and
     wraps `player.sprite` to swap the walking graphic (and not the bike one).
4. **Regenerated docs** — `luajit tools/gen_registry_docs.lua` for the hook
   and event tables.
5. **Deprecation etiquette** — nothing is removed. `Objects._byId` / `_order`
   stay what they are; the engine simply stops being the thing a mod has to
   reach into.

## What `rby_mmo` removes when this lands

- `src/Avatars.lua`: `inject3` / `extract3` / the per-tick re-injection, the
  `TALK_KEY` template field and the `world.talk` link (becomes `talk = true`),
  `Objects.pushStep` (becomes `stepNow(dir, frames)`), and the depth nudge.
- `src/Cast.lua`: `installLook3` / `restoreLook3` (becomes a `player.sprite`
  link, as on Gen 1).
- The Gen 3 stack polling that stands in for `screen.pushed`.
- With the runtime-object marker asked for at the end of this document: the
  ghost-pool purge on every map change and the `QuestLogRecorder.capture` and
  `RotatingTilePuzzle.move` wraps. (The look fence stays either way: a remote
  player should be drawn as a walking person, not a boulder.)
- With addenda A–D: what each one's "What `rby_mmo` removes" lists.

## Addendum A — taking a battle over (`battle.intercept`)

**Found by:** `rby_mmo` wave 4 (co-op and solo battles on game3). Against the
same `dev` @ `fdea09dc`.

### What `rby_mmo` does today, and why

On Gen 1 / Gen 2 a co-op or solo fight *stands in* for the engine's own: the
engine pushes its BattleState, `screen.pushed` announces it, the mod buries it
under its own screen and, when its fight ends, calls the buried battle's
`onFinish(result)` — the overworld's whole post-battle flow (trainer flag,
prize, whiteout, the script waiting in front of the trainer). game3 has no
such moment: battles are module-driven (`battle_bridge.lua` →
`battle/init.lua`), and by the time one exists it is already the cart's.

- **Wild encounters** go through the public `encounter.roll` hook
  (`src/core/game3/encounters.lua` `Encounters.onStep`): the mod's link returns
  `nil`, the step starts no battle, and the mod starts its own with the rolled
  monster (built the way `battle/init.lua` `foe_mon_from` builds a foe). This
  needs nothing from upstream. Fishing, Rock Smash and Sweet Scent start their
  fights through `BattleBridge.startWild` without passing the hook, so they
  are taken at the same wrap trainers are (below), under the same refusals.
- **Trainers** are the reach-around. The `trainerbattle` / `dotrainerbattle`
  opcode (`scripting/ops_a.lua:1510`) does reach mods through `script.command`
  (`:2276`), but a hook there can only replace the *whole* opcode — rematch
  rules, the already-beaten skip, the double-battle check, the intro text, the
  trainer turning to face the player — and would then have to suspend the VM
  through its private `ctx.nativePoll`. The fight itself starts in exactly one
  place, `BattleBridge.start(mod, game, foe, opts)` (via the VM adapter's
  `startTrainerBattle`), with the opcode's continuation in `opts.done`. So
  `src/CoopField.lua` (`installStart3` / `restoreStart3`) wraps that one
  function:
  - the original is kept on the module under `__rby_mmo_start`, so a hot
    reload wraps the pristine original rather than a wrapper;
  - the wrapper is inert unless this mod instance is the loaded one
    (`mod.find(id).exports == mod.exports`), and answers the original for a
    link / headless start, a step encounter `encounter.roll` already offered,
    a start the mod itself makes to hand a fight back (its opts carry
    `CoopField.HANDBACK3` — a step wild handed back reaches `start` through
    `BattleBridge.startWild`, i.e. through this same wrapper), and every kind
    in `Config.SOLO_REFUSED_GEN3` (safari, roamers, scripted and legendary
    wilds, frontier, Trainer Tower, the first battle, two-opponent and partner
    fights, …);
  - the foe the mod fights is built the way the cart builds it: the
    `trainer.party` hook runs first (through the public `ModRuntime.call`, as
    `battle_bridge.lua`'s `hooked_trainer_party` does), then the trainer's
    name-hash personalities and row IVs (`SoloBattle.gen3HookedFoe` /
    `gen3TrainerParty`, which co-op and solo share), and the rival is named
    from `Trainers.info(id, { rivalName })`;
  - taking the fight is not beginning it: what `BattleBridge.start` does at a
    battle's start besides the battle — the match-call rematch clock (wild and
    trainer), the league's friendship, Emerald's TV tally — runs once, when the
    mod's own fight actually begins (`Stand:begin3`); a co-op wait that times
    out hands the fight back and the cart's start does all of it itself;
  - when the mod's fight ends it does what `BattleBridge.start`'s `finish`
    would have done for it — `battleOutcome`, `applyWhiteoutMoneyLoss` +
    `Field.respawnAtHeal` on a loss (or the `noWhiteout` / EARLY_RIVAL
    heal-and-carry-on), the map song, `Space.returnToField` — and calls the
    opcode's own `opts.done(result)`, so the trainer flag, the CONTINUE_SCRIPT
    jump and the VM tick are the opcode's, unchanged. A draw that leaves the
    player standing (a dropped link, a referee timeout) is *not* handed over:
    the opcode has no third answer (`"lose"` skips the flag but runs the bytes
    after `trainerbattle` — a leader's TM without the badge — and anything
    else marks the trainer beaten), so the mod halts the waiting script
    (`Space.vm:halt(true)`, what `Field.respawnAtHeal` does before its warp)
    and whites nobody out. A draw that wipes the player is the cart's whiteout
    (`IsPlayerDefeated` counts `B_OUTCOME_DREW`) and goes over as `"lose"`.
    A *won* fight never whites out, however it left one partner's team;
  - the stand-in is bound to the save it was met in (`Gen3.session()`): after
    a load, a CONTINUE or a return to the title nothing is handed back and no
    result is delivered — the old fight is never started in the new file;
  - nothing in production takes the wrap off: the loader has no unload
    callback for a mod, so the wrapper retires itself instead (a rolled-back
    mod has no exports, a hot-reloaded one has new ones, and `Gen3.wrapLive`
    notices a newer wrapper of ours) and is then a straight call to what it
    wrapped. `restoreStart3` is the explicit form of that retirement, kept for
    the suite and for a future unload point: it puts the original back when
    the slot still holds this wrapper, and one stacked on top by another mod
    keeps the slot while ours is retired in place.

What that costs: it depends on `BattleBridge.start`'s signature and on
`opts.done` being the opcode's continuation; it has to halt the script VM
itself for a draw (the opcode's poll is private); and `battle.started` /
`battle.ended` are not raised for a fight the engine never ran (a mod may not
emit an engine event).

### Proposed seam

One hook, raised at the top of `BattleBridge.start` (after the refusal checks
the bridge already makes, before `PartyView` / the transition):

```lua
mod.hooks:wrap("battle.intercept", function(next, game, spec)
  -- spec = { kind = "wild" | "trainer", foe = <foe record>, opts = <start opts,
  --          read-only>, trainerId?, mapId, finish = function(result) end }
  -- Return true to take the fight: the engine starts nothing, and the taker
  -- calls spec.finish(result) exactly once ("win" | "lose" | "draw" | "run" |
  -- "caught"), which runs the bridge's own finish (writeback of nothing,
  -- battleOutcome, whiteout, TV / roamer, battle.ended, map song,
  -- returnToField) and then opts.done.
  return next(game, spec)
end)
```

- Guarded by `Runtime.wantsHook("battle.intercept")`; vanilla (`next`)
  answers false and the bridge proceeds exactly as today.
- Raised for every start the bridge handles, so fishing / Rock Smash / Sweet
  Scent / scripted wilds are covered by the same seam (the spec's `opts` says
  which), and `trainer.party` runs before it so a taker sees the hooked party.
- `spec.finish("draw")` gets a real third answer in the opcode (trainer not
  marked beaten, no whiteout, script halted) instead of the mod halting the
  script VM from outside. That answer is addendum C, which also stands on its
  own for a mod still taking fights the way `rby_mmo` does today.

Parity pair: *vanilla unchanged* — a headless trainerbattle with no hook runs
the same battle and sets the same flag; *through the public API* — a
`tests/modkit/cases/` case wraps `battle.intercept`, takes a trainer fight,
calls `spec.finish("win")`, and asserts the trainer flag is set, the
CONTINUE_SCRIPT ran and no battle started.

### What `rby_mmo` removes when it lands

`CoopField.installStart3` / `restoreStart3` / `divertStart` (with the
`HANDBACK3` marker and `Stand:begin3`'s copy of the start's bookkeeping) and
the hand-written half of the finish ritual (`Stand:finish` keeps only the call
to `spec.finish`); the `encounter.roll` link can stay or move to the new hook.

## Additional costs of the reach-around (found in review, 2026-09-30)

**Ghost capture.** `Map.load` calls `Ghosts.capture(Map.current)` (map.lua:304) before `Objects.loadMap` (map.lua:510), copying the live object list into `Ghosts._pools[oldMap]`; `FieldView.collectNeighborActors` (field_view.lua:369, via `Objects.poolForDraw`) keeps drawing that pool while the old map is a neighbour. An injected runtime object is therefore drawn frozen on the far side of every seamless edge, and twice once its owner follows. The mod works around it by retiring an avatar it lets go (`hidden`/`visible`) and purging its marked objects from every ghost pool on each map change. **Ask:** spawnNpc objects should be runtime-owned (e.g. a `runtime = true` flag on the event object) and removed only on the spawner's request. Addendum B settles what capture does with them: rather than skipping them, `Ghosts.capture` / `adoptPool` carry each runtime object as a member of the map it was spawned on, so it is never copied and never left behind.

**Quest-log persistence.** `quest_log_recorder.capture` records `Objects.forDraw()` as actor frames into `session.questLog`, which is saved — so injected objects replay in the FireRed/LeafGreen CONTINUE recap. The mod wraps `QuestLogRecorder.capture` and drops actors whose id is in its local-id block (`GEN3_AVATAR_LOCAL_ID_BASE`..+0xFF). **Ask:** the recorder should skip runtime-flagged objects, or offer a `quest_log.capture` hook.

**Walkers.** Several engine passes walk `Objects._order` or key on graphics for their own ends: `RotatingTilePuzzle.move` shoves every visible object on an arrow tile, gives it a track and names it `lastMoved`; the VS Seeker charge completion (vs_seeker.lua:610-635) freezes every object and waits while any is moving; `Field.interact` offers Cut/Rock Smash/Strength by `def.graphicsId` before the script key. No marker is honoured by these but not by the renderer. The mod hides avatars around `RotatingTilePuzzle.move` and restricts avatar graphics to player looks. **Ask:** one engine predicate (e.g. `Objects.isMapObject(eo)`) that map logic checks, so a spawned object draws and collides like any other but is never moved, recorded or offered a field move.

## Addendum B — runtime objects on a neighbouring map (players across a seamless edge)

**Found by:** `rby_mmo` 1.5.0 review (`docs/plans/gen3-known-gaps.md` §4).
Against the same `dev` @ `fdea09dc`.

### What happens today

game3 draws the objects of every map placed around the current one, not only
the current map's:

- `Map.world` lists the maps around the current one with their offsets
  (`WorldAPI:liveMaps()` hands mods the same list).
- `Ghosts.sync` builds each neighbour a pool from its templates and
  `Ghosts.update` ticks it, so a neighbour's NPCs walk (`ghosts.lua:72`,
  `:101`, called from `field.lua:208`).
- `FieldView.collectNeighborActors` draws each pool at its map's offset
  (`field_view.lua:356`, `:369`).
- On a crossing, `Map.load` snapshots the live list into the map being left
  (`Ghosts.capture`, `map.lua:304`), loads the new map from its templates
  (`Objects.loadMap`, `:510`), and copies the walkers' motion back from that
  map's pool (`Ghosts.adopt` → `Objects.adoptPool`, `:512`, `objects.lua:2005`;
  WALK / BACK_FORTH / SEQUENCE objects only).

A remote player on a neighbouring map has no place in any of this. Presence
says which map and tile they stand on, but there is no public way to put an
object into a neighbour's pool: `spawnNpc` is unsupported. The avatars the
mod injects into the *current* map also end up in `Ghosts.capture`'s copy,
frozen and later doubled (the "Ghost capture" cost above).

So `rby_mmo` reaches into one more private table. On each map change it
purges its avatars from every pool (`Avatars.purgeGhosts3`), then writes each
player on a placed neighbour straight into that map's pool
(`Ghosts._pools[mapId]`, `Avatars` `avatarPool3`). A connected map with no
object events has no pool (`Ghosts.sync` builds none), so the mod builds one
with `Objects.spawnFromDefs`, and removes the ones it built when it clears
its avatars (`Avatars.dropPools3`). The engine then ticks and draws the avatar like that
map's NPCs. This closed known gap §4 (`docs/plans/gen3-known-gaps.md`), at
the cost of depending on `Ghosts._pools`, `Ghosts.sync`'s rebuild and
`Objects.spawnFromDefs` staying as they are.

Since `dev` @ `fcc8b5d1` an empty slot no longer means an empty map:
`Ghosts.sync` leaves a neighbour outside the visible rect unbuilt while
`prepareOffscreen` waits on the worker (`ghosts.lua:124`, `:147`), and it and
`Ghosts.blocksOn` only build into an empty slot. A pool the mod made there
hid that map's NPCs until the next map change. So the mod now also mirrors
the private `defsFor` (`ghosts.lua:29`, `Avatars` `neighbourDefs3`). It makes
a pool only for a map with no templates, waits a tick for the engine's pool
otherwise, and drops a made pool when its last avatar leaves (`dropPool3`).
That is one more private rule to track. The seam above removes it.

### Proposed seam: a runtime object belongs to its map

This extends `spawnNpc` above; it adds no new call.

- **Any live map.** `mod.world:spawnNpc(mapId, def)` accepts any map
  `liveMaps()` lists, not only the current one. A runtime object belongs to the
  map it was spawned on and lives in that map's object list:
  - while the map is current, in the live list;
  - while it is a neighbour, in its pool (`Ghosts._pools[mapId]`), ticked by
    `Ghosts.update` and drawn by `collectNeighborActors` exactly like that
    map's own NPCs.
- **Crossing an edge moves nothing.**
  - `Ghosts.capture` keeps the old map's runtime objects as members of its pool.
  - `Objects.loadMap(newMap)` re-inserts the new map's runtime objects after the
    templates (the reload rule above).
  - `adoptPool` carries a runtime object's motion state as it does a walker's
    (cell, `px` / `py`, `moving`, `progress`, `facing`), so a step in progress
    continues across the edge.

  Each runtime object exists once, in its own map's list.
- **Leaving the neighbourhood.** When `Ghosts.sync` drops a pool because its
  map is no longer placed, that map's runtime objects stay registered and come
  back when it is placed again. `removeNpc` is the only thing that ends one.
- **Driving it.** The handle (`WorldAPI:npc(mapId, name)`,
  `Handle:stepNow(dir, frames)`) resolves a runtime object in whichever list
  holds it, so an avatar on a neighbouring map walks there. A neighbour pool's
  collision (`Ghosts._contextFor` → `blocks`) already skips `passable` objects.
- **Moving to another map** is `removeNpc` followed by `spawnNpc` on the new
  map; the mod already knows when a remote player warps or crosses. An optional
  `Handle:relocate(mapId, x, y)` would save the reallocation, but nothing needs
  it.

Parity pair:

- **Vanilla unchanged:** a seamless crossing with no runtime objects builds the
  same pools, adopts the same walkers and draws the same neighbour actors.
- **Through the public API:** a `tests/modkit/cases/` case
  1. spawns a runtime object on a neighbouring map;
  2. asserts `collectNeighborActors` draws it at that map's offset;
  3. steps it with `stepNow(dir, 16)`;
  4. crosses into that map and asserts exactly one copy stands in the live list
     at the same cell, its step carried;
  5. crosses back and asserts it is a member of the pool again.

### What `rby_mmo` removes when it lands

- `Avatars.purgeGhosts3`, the per-map-change retirement of avatars
  (`retire3`), and their reinjection after a crossing.
- The writes into `Ghosts._pools` and the pools it builds itself
  (`avatarPool3`, `dropPools3`): a player on a neighbouring map is spawned
  there through `spawnNpc` from presence (the roster already carries every
  player's map and tile).

## Addendum C — a draw answer for `trainerbattle`

**Found by:** `rby_mmo` 1.5.0 review (`docs/plans/gen3-known-gaps.md` §7).
Against the same `dev` @ `fdea09dc`.

### What happens today

`trainerbattle` / `dotrainerbattle` (`scripting/ops_a.lua:1510`) starts the
fight through the adapter's `startTrainerBattle`. Its continuation (`:1653`)
writes an early rival's `VAR_RESULT` and clears the rematch state for every
answer (`:1656`–`:1662`), then knows two:

- **A loss** (`"lose"` / `"whiteout"` / `"blackout"`, `:1654`) sets no trainer
  flag and lets the VM run on past the opcode. That is right after a cart loss:
  the bridge's own finish has whited the player out, and `Field.respawnAtHeal`
  has already halted the script.
- **Anything else** is a win. The trainer flag is set and the
  CONTINUE_SCRIPT jump or the script's end follows (`:1663`–`:1690`).

The cart never needs a third answer. A battle that ends with the player still
standing and nobody beaten does not exist there: `IsPlayerDefeated` counts
`B_OUTCOME_DREW` as a loss, so a mutual KO is a whiteout.

A mod-refereed fight can end that way: a dropped link, a referee timeout, or a
co-op partner gone. `rby_mmo` cannot say so:

- `"lose"` would run the bytes after `trainerbattle` (a gym leader's TM without
  the badge);
- anything else marks the trainer beaten.

So it halts the script VM from outside (`Space.vm:halt(true)`, in `CoopField`'s
`haltScript3` and in `SoloBattle.haltScript3`) and never answers the
continuation.

### Proposed seam

The continuation accepts `"draw"` (and `"drew"`, the spellings
`Natives.outcome_to_code` already maps to `B_OUTCOME_DREW`):

- **No flags.** No trainer flag, no rematch flag, no `onTrainerBattleWon`, and
  `VAR_RESULT` untouched (the script halts before anything could read it); the
  rematch-state clear still runs, as for every answer.
- **The script halts** where it waits (`shouldHalt = true`, as after a
  rematch). The trainer stays on the map, unbeaten, and the cart's own sight
  check challenges the player again.
- **No whiteout and no heal.** Whatever finished the fight has already left the
  party as it is. The bridge's own finish never passes `"draw"` for a fight the
  engine ran.
- **The outcome is recorded.** `session.battleOutcome` is `B_OUTCOME_DREW`, and
  `battle.ended` carries it wherever the bridge's finish raises the event.

Every existing answer keeps its meaning, and an unknown string still counts as
a win. `battle.intercept`'s `spec.finish("draw")` (addendum A) is this answer
reached through the bridge.

Parity pair:

- **Vanilla unchanged:** a headless `trainerbattle` answered `"win"` sets the
  flag and jumps; answered `"lose"`, it sets no flag and falls through, exactly
  as today.
- **Through the public API:** a `tests/modkit/cases/` case answers the
  continuation `"draw"` and asserts:
  - no flag is set;
  - the VM is halted at the opcode, with none of the following bytes run;
  - `battleOutcome` is DREW;
  - the trainer's sight check starts the same battle again on the next step.

### What `rby_mmo` removes when it lands

`CoopField`'s and `SoloBattle`'s `haltScript3`: the mod answers
`opts.done("draw")` instead. That closes known gap §7. The trainer is still
unbeaten after a draw, which is the cart-faithful outcome, but the script now
ends by the engine's rule rather than the mod's.

## Addendum D — the TEACHY TV's demonstrations (`startTeachyTvBattle`)

**Found by:** `rby_mmo` 1.5.0 review (solo battles on FireRed / LeafGreen).
Against the same `dev` @ `fdea09dc`.

### What `rby_mmo` does today, and why

The POKé DUDE's battles never reach `BattleBridge.start`, so neither
`encounter.roll` nor the start wrap of addendum A sees them. The TEACHY TV
(`teachy_tv.lua` `startDemonstration`) calls
`battle/pokedude.lua` `Pokedude.startTeachyTvBattle(session, scriptId, opts)`,
which plays the music and the transition and then, in its own `start()`
(pret `teachy_tv.c:1172` `TeachyTvPrepBattle`), does four things around
`Battle.start` that a taker has to do too. The TEACHY TV's own
`onDemonstration` slot is one slot, a replacement rather than a chain, and the
engine's tests own it, so `src/CoopField.lua` (`installPokedude3` /
`restorePokedude3` / `divertPokedude`) wraps `startTeachyTvBattle` through
`Gen3.wrapFn` with addendum A's discipline, and with SOLO BATTLES on does
those four things itself before offering the fight to solo:

- **The modal stack, lifted whole.** `Stack._layers` (`src/ui/game3/stack.lua`)
  is swapped for an empty table, so the fight's screen is pushed onto an empty
  stack and the TEACHY TV under it neither draws nor takes input; the saved
  table is put back at the end (`Stand:coverTeachy3` / `uncoverTeachy3`,
  copying `start()` / `finish_battle`). `_layers` is the stack's private list.
- **The bag and START menus, closed.** `src.ui.game3.bag_menu` and
  `src.ui.game3.start_menu` keep their state on the module (`.open`), and the
  engine's `hide_menus` / `show_menus` flip it on whichever is already in
  `package.loaded`. The mod does the same through `Gen3.loaded` — the
  `Gen3.engine` gate (a Gen 3 boot, a `game3` module name) over
  `package.loaded`, never a `require`, because a menu nobody loaded cannot be
  open.
- **The POKé DUDE's bag in the save.** `TeachyTv.initPokedudeBag` /
  `restorePlayerBag` (pret `item_menu.c:2162` / `:2082`), the engine's own
  functions, swap `session.bag`'s pockets with `session.teachyBagBackup`.
- **The POKé DUDE's party in the save.** `startTeachyTvBattle` hands
  `Battle.start` his party as `playerParty`; the mod's referee, EXP pass and
  evolutions read `session.party`, so the mod swaps `session.party` itself
  (pret `SavePlayerParty`, `InitPokedudePartyAndOpponent` writing
  `gPlayerParty`, `LoadPlayerParty` at `teachy_tv.c:1208`).

What that costs:

- It depends on `startTeachyTvBattle`'s signature, on `Stack._layers` being a
  plain list the stack reads on every call, and on the two menus' `.open`
  flags.
- The party and the bag are the save. A fight that never reaches its end — a
  screen that threw and was popped, an F5 hot reload mid-demonstration —
  would leave the POKé DUDE's monsters and items in the session, and the next
  save would write them as the player's. The mod records each swap in a
  ledger on the session (`src/Borrow3.lua`; `Schema.toSaveTable` copies named
  fields only, so the ledger never reaches the file) and wraps the public
  `save.write` hook: a swap whose fight is gone is given back before the write,
  and the write is refused while the fight is really still on screen. The
  stack cover is *not* restored by that backstop — at save time the player is
  on the field with the START menu's own layers up, and swapping the TEACHY
  TV's back in would bury the save box — so the TEACHY TV is simply gone, as
  if left, and its `onDone` never runs.
- A taker that declines after the transition hands the demonstration back to
  the engine with `opts.headless`, the only way to get `start()` without a
  second intro.

### Proposed seam

One hook, raised inside `start()` after the transition and before anything is
lifted or swapped:

```lua
mod.hooks:wrap("teachy_tv.demonstration", function(next, game, spec)
  -- spec = { scriptId, session, playerParty = <his party>, foe = <his foe>,
  --          opts = <Battle.start's opts, read-only>,
  --          finish = function(result) end }
  -- Return true to take it: the engine has already lifted the TEACHY TV,
  -- hidden the menus and swapped in his bag and party (and keeps them
  -- swapped); the taker pushes its screen and calls spec.finish(result)
  -- exactly once, which runs finish_battle (bag, party, stack, menus back,
  -- the outcome code to the TEACHY TV).
  return next(game, spec)
end)
```

- Guarded by `Runtime.wantsHook("teachy_tv.demonstration")`; vanilla answers
  false and `start()` calls `Battle.start` exactly as today.
- The engine owns the swaps, so the engine owns giving them back: `Game3:save`
  (or `Schema.toSaveTable`) writes the backed-up party and bag while a
  demonstration is in progress, which closes the hole for the engine's own
  battle too (its `session.teachyBagBackup` has the same exposure today).
- `spec.finish` after a load or a soft reset is a no-op, as the bridge's own
  finish is.

Parity pair: *vanilla unchanged* — a headless demonstration with no hook runs
`Battle.start` with the same `playerParty` and the TEACHY TV reads the same
outcome code; *through the public API* — a `tests/modkit/cases/` case takes
the demonstration, asserts the TEACHY TV is off the stack and the session's
party is his, saves (the file holds the player's party and bag), calls
`spec.finish("win")`, and asserts the TEACHY TV is back with `B_OUTCOME_WON`.

### What `rby_mmo` removes when it lands

`CoopField.installPokedude3` / `restorePokedude3` / `divertPokedude` /
`teachyFallback3`, the stand's `coverTeachy3` / `uncoverTeachy3`,
`borrowTeachyBag3` / `returnTeachyBag3`, `borrowParty3` / `returnParty3`, the
`Gen3.loaded` menu reads, and `src/Borrow3.lua`'s TEACHY TV records (the
ledger stays only for borrows the mod still makes itself, such as the
tutorials' bags).
