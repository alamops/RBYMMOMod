# Upstream issue draft — mod storage that belongs to the copy, not the playthrough

**For:** `bryanthaboi/gen1recomp`, against the mod sandbox release.
**From:** `rby_mmo` (RBY MMO), which has moved off the filesystem and is
shipping under the sandbox with a regression it cannot fix from this side.

Filed the way the announcement asked for it — "if there is a real thing mods
need to do that the sandbox blocks, that is a gap in the API and we want to fix
it properly, with a scoped engine call rather than a hole." This is a request
for a scoped call, not for filesystem access. **We do not want a `filesystem`
permission back and we are not asking for paths.**

## What we did

Everything the announcement asked for, and it was mostly one line per site:

| Was | Is |
|---|---|
| `love`'s filesystem module × 3 stores | `mod.storage` via one shared `src/Store.lua` |
| `os.getenv("RBY_MMO_PORT")` | a `port` row in `mod.options` |
| `"filesystem"` in `manifest.permissions` | removed |

The grep in the announcement is clean, `modkit validate --base imported`,
`lint` and `pack` are green, and the mod's own suite gained 33 checks for the
durable half — which, ironically, is now *easier* to test than it was as a
file, because a four-method facade is something a headless stub can stand up.

No complaints about any of that. The sandbox is the right call and the
migration was cheap.

## The gap

`mod.storage` is scoped `mod_storage/<gameVersion>/<playthroughId>/<modId>`,
and `Storage:_scope` answers `not_in_playthrough` outside an identified save.
That is exactly right for what RFC 0003 set out to hold — replay captures,
checkpoint histories, recovery records. All of those *are* facts about one
playthrough.

We have three stores that are not, and never were:

| Store | What it is | Why it is not per-playthrough |
|---|---|---|
| Recent hubs | addresses this copy has connected to | you type an address on a d-pad once; a second save file should not have to retype it |
| Friends lists | people you agreed to keep, per hub | a friendship is between two humans, not between two save files |
| **Player id** | 16 random bytes, `client.id` on the wire | **the hub seats you under it, the rank board keys on it, and a duplicate live connection is refused by it** |

The player id is the one that actually hurts. It is closer to an account than
to progress. Under per-playthrough scoping, one human with two save files is
two players as far as any hub is concerned: two rows on the leaderboard, two
histories, and — because a hub refuses a second live connection with the same
id — the *absence* of the check that stops one person occupying two seats.

There is also a smaller ordering problem: `START > MMO > SERVERS` is reachable
before the engine has an identified playthrough, and the recents list is one of
the few things a player wants to see *before* deciding which game to load.
`not_in_playthrough` is the correct answer from the current API and the wrong
answer for the screen.

## What we are asking for

A sibling scope, not a new capability. Everything else about `mod.storage` —
data-only tables, engine-owned encoding, no paths, no handles, per-mod
namespacing — is what we want and should not change.

The shape that would close it, keeping the existing call's ergonomics:

```lua
-- Same four methods, same value contract, one scope up: keyed by mod id and
-- game version, with no playthrough segment.
mod.storage:writeShared(game, "identity", { id = playerId })
local saved = mod.storage:readShared(game, "identity")
```

Or, if a second method set is unappealing, an options table on the existing
calls (`{ scope = "copy" }`), defaulting to the current behaviour so nothing
that compiles today changes meaning.

Two properties we would need either way:

1. **Readable without an identified playthrough.** The recents list is asked
   for from a menu that can be reached before a save is chosen. If that is
   genuinely impossible, we would rather be told so than guess — we can move
   the menu.
2. **Still data-only and still engine-scoped.** We do not need to know where it
   lands, and we would rather not be able to find out.

We are not asking for cross-*mod* sharing. `mod.exports` covers that and covers
it better.

## What we are doing meanwhile

Shipping on `mod.storage` as it stands, with the regression documented in the
CHANGELOG and in `src/Store.lua`, and with the `mod.save` mirror each of these
three stores already keeps doing double duty as the upgrade path — a player
updating the mod keeps whatever their last save holds, so nobody loses a player
id or a friends list by installing the sandbox release. What they lose is the
sharing *between* save files, quietly, and there is no sentence we can put in
front of them that makes that a setting rather than a surprise.

Happy to write the patch against `Storage.lua` / `Loader.lua` and the RFC that
extends 0003, if the shape above is one you would take.
