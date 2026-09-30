# Upstream proposal (Lane B) — runtime objects, the player's look and screen events on game3

**For:** `bryanthaboi/gen1recomp`, the game3 (FireRed / LeafGreen / Emerald)
mod surface. Against `dev` @ `fdea09dc`.
**Found by:** `rby_mmo`, porting its shared overworld to Gen 3.
**Status:** a proposal. `rby_mmo` ships on Gen 3 today with the reach-arounds
described below, isolated in three files and each behind a `pcall`; nothing in
this document is a workaround we intend to keep once a seam exists.

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
  recap can show another player standing where they stood — true, but not
  something the mod asked for.

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
`src/ui/game3/stack.lua` and `src/core/game3/battle.lua` instead. (Encounter
diversion itself goes through `encounter.roll` and `script.command`, which do
fire on game3.)

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
- The link fingerprint is unaffected: none of this touches a
  `Manifest.LINK_REGISTRIES` registry.

## Obligations (CLAUDE.md, "If upstream itself needs to change")

1. **RFC** — `docs/rfcs/NNNN-game3-runtime-objects.md` covering the delta above.
2. **Backward-compatibility statement** — the section above, in the RFC.
3. **Parity test pair** for each seam:
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
