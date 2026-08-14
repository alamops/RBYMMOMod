# Upstream issue draft — the mod manager doesn't honour the dev-engine exemption

**For:** `bryanthaboi/gen1recomp`. Small, and probably a two-line fix.
**Found by:** `rby_mmo`, taking the advice to floor `game_version` at the
current engine release (`>=0.1.86 <2.0.0`).

## The inconsistency

Three places compare `Version.engine` against a mod's `game_version`. Two of
them deliberately skip the check on a working-tree build, where `Version.engine`
is the `0.0.0-dev` placeholder that CI only stamps into the packed `game.love`:

- `src/mods/Loader.lua:496` — `elseif manifest.game_version and not devEngine()`
- `src/mods/LauncherMods.lua:78` — `Version.engine:match("^0%.0%.0%-") == nil`

The third does not:

- `src/mods/ManagerState.lua:114` —
  `if m.game_version and not Semver.satisfies(Version.engine, m.game_version)`

So on any developer checkout, a mod whose `game_version` has a real floor
loads fine (Loader exempts it) and shows no warning in the launcher
(LauncherMods exempts it), but **toggling it on in the F10 mod manager files a
`badVersion` and lands in `openBlocked`** — `0.0.0-dev` satisfies no range with
a nonzero floor.

## Why it bites now

Before the advice to floor `game_version` at the current release, most mods
carried something like `>=0.0.0-0`, which `0.0.0-dev` happens to satisfy — so
the missing exemption was invisible. Every mod that takes the advice trips it,
and it trips exactly the person best placed to be confused by it: someone
running the mod from a checkout, where the other two call sites have already
agreed the check does not apply.

## Suggested fix

Give `ManagerState` the same guard the other two have. If the intent is that
the manager should be stricter than the loader — enabling something the loader
would then refuse is a fair thing to warn about — then the dev case still needs
to be distinguished from the real mismatch, because on a dev engine the loader
will *not* refuse and the manager's block is simply wrong.

Either way, `devEngine()` currently lives as a local in `Loader.lua` and is
open-coded in `LauncherMods.lua`. Three call sites and two spellings is how the
third one came to be missed; `Version.isDev()` would make it one fact.

## Not a blocker for us

We are shipping `>=0.1.86 <2.0.0` regardless. Our end-to-end drivers enable the
mod through `options.lua` rather than the manager, so they are unaffected, and
the mod loads normally in a checkout. It is only the F10 path on a dev build.
