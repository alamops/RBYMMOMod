# Gen 3 known gaps (after 1.5.0)

A backlog of what FireRed / LeafGreen / Emerald support shipped without. Each
one is also listed under **Known** in `CHANGELOG.md` [1.5.0]; this file adds
where it lives in the code and what closing it would take.

| # | Gap | Kind | Size |
|---|-----|------|------|
| 1 | LeafGreen never run live | verification (needs a ROM) | S |
| 2 | Solo battles leave some fights to the cart (lone doubles: done) | mod work, per fight type | M → XL |
| 3 | Cross-region trades follow the post-game rule | cart-faithful, decision | S |
| 4 | Players across a seamless map edge are not drawn | needs an engine seam | M |
| 5 | Party-on-map is a list, not a marker | mod UI work | M |
| 6 | Mod-refereed fights use link rules (done) | design choice, both twins | M |
| 7 | A trainer draw leaves the trainer unbeaten | engine limit | S / upstream |
| 8 | Gen 3 reaches into engine internals | upstream RFC | L |

---

## 1. LeafGreen has never been run live

- [ ] Add a LeafGreen ROM to `.env` and run the full Gen 3 matrix on it.

**Why:** there is no LeafGreen ROM on this machine. It shares FireRed's engine
path (`frlg` family) and passes every headless suite, but no live boot has
ever loaded it.

**Already in place:** `tools/env.sh` knows the game (`LEAF_GREEN_ROM_PATH`,
`LEAF_GREEN_ROM_VERSION`, SHA-1s for 1.0 and 1.1, cache short name `lg`), and
every Gen 3 runner takes `GEN3_GAME=leafgreen`.

**To do:**
1. Set `LEAF_GREEN_ROM_PATH` in the main checkout's `.env`.
2. Import once into the LÖVE identity `rby-mmo-g3-import-lg/leafgreen` so
   `seed_gen3_cache` can clone it (never re-import per run).
3. Run `GEN3_GAME=leafgreen` through `run-mmo-e2e-gen3.sh`,
   `run-solo-battle-e2e.sh --gen3` and `run-battlefield-e2e-gen3.sh`.
4. Add a LeafGreen client to the trip run (`run-trip-e2e-gen3.sh` is FireRed
   A + B and Emerald C today): LG ↔ FR trades freely, LG ↔ EM needs the
   post-game flags (`g3AllowCrossRegionTrade`).
5. Curate one or two `g3-lg-*` shots into `docs/screenshots/gen3/` (and list
   them in `.modkitignore`).

## 2. Solo battles leave some fights to the cart

- [x] **Lone doubles: done** (`docs/plans/gen3-solo-doubles.md`). This was on
      all three carts, not only Emerald; FireRed / LeafGreen lone doubles had
      been handed back too.
- [ ] Decide which of the rest are worth taking over, cheapest first.

**What is left to the cart today:**
- doubles against two trainers at once, or with Steven as a partner;
- the Safari Zone;
- roaming and scripted legendaries;
- the Battle Frontier, Trainer Tower / Trainer Hill;
- the first battle and the tutorial fights.

**Where:**
- `Config.SOLO_REFUSED_GEN3` (`src/Config.lua`, ~l.920–955) lists every
  refused start flag and why.
- `CoopField.refused3` (`src/CoopField.lua`) applies it; `divertStart` is the
  `BattleBridge.start` wrap that takes or hands back a fight.
- `SoloBattle.gen3TakesDouble` (`src/SoloBattle.lua`) takes a lone double
  with two usable monsters; `trainerIdB` (two trainers) is still handed back.

**Suggested order:**
1. ~~**Lone doubles.**~~ Done. The referee's twins share one team across
   two seats (`seats = 2`), and the screen is `CoopBattle.newSoloDouble`.
2. **Roamers and scripted legendaries.** Catch writeback exists (co-op
   catch); the extra work is the roamer's state (HP / status carried between
   encounters) and the script's own after-battle flags.
3. **Safari Zone.** A different action set (ball / bait / rock / run, no
   party), step and ball counters written back to the save.
4. **First battle / tutorials.** Fights meant to go one way on cue; taking
   them over risks the script. Probably keep on the cart.
5. **Partner / two-opponent doubles.** Needs a third AI seat (`partner`) or
   two trainer AIs and two defeat flags on one side (`twoOpponents`).
6. **Frontier, Trainer Tower, Trainer Hill.** Facility rules, rental parties
   and streak bookkeeping. Likely keep on the cart for good.

Each one taken over needs its key removed from `SOLO_REFUSED_GEN3`, a solo
e2e leg, and both battle twins kept in step.

## 3. Cross-region trades follow the carts' post-game rule

- [ ] Decide: keep as-is (recommended) or offer an opt-in house rule.

**Current behaviour:** FireRed / LeafGreen can trade with Emerald once the
cart could link with Ruby / Sapphire (the Sevii post-game), and Emerald once
the player is Champion. A POKéMON from outside a cart's regional dex, or an
egg, also needs that cart's National Dex. Trades within a region are free.

**Where:** `src/Trade3.lua`: the progress-flag nibbles (~l.400–430) and the
National Dex gate (~l.808).

**If relaxing it:** it has to be a hub-level rule both sides agree on, not a
client toggle. Test what the cart does with a mon it could not normally
receive: evolving it without the National Dex, the Pokédex entry, and the
summary screen.

## 4. Players across a seamless map edge are not drawn

- [ ] Draw remote players on neighbouring maps from presence.

**Why:** on a map change the engine copies live objects into the old map's
ghost pool (`Ghosts.capture`), and `FieldView` draws a neighbour's pool. Remote
avatars copied there stayed frozen and doubled, so `src/Avatars.lua` purges
them from every pool on each map change (see ~l.111, ~l.537, ~l.945). You
see another player only once you share a map.

**To do:** the roster already knows every player's map and tile. Either:
- **(preferred)** ask upstream for a seam to contribute live objects to a
  neighbour's draw pool each frame (add it to `docs/upstream/gen3-spawn-npc.md`),
  or
- draw them from the mod on `render.hud`, using the map-connection offsets
  to place them. That is more code and easy to get out of step with
  `FieldView`.

## 5. Party-on-map is a list over the region map

- [ ] Put a marker per party member on the region map, as Red does on the
      town map.

**Where:** `src/Overlay.lua` (~l.1316–1376 and ~l.1512) detects the top layer:
`frlg` town map, `rse` region map, or `pokenav`. Today's look:
`docs/screenshots/gen3/g3-fr-party-townmap.png`,
`g3-em-party-pokenav.png`.

**To do:** map each map id to its region-map section and cell (the carts'
mapsec → region-map position tables, as the engine decodes them), then draw a
marker per member. Three layouts to cover: FireRed / LeafGreen (Kanto plus the
Sevii pages), Emerald's region map, and the PokéNav map. Handle a partner on
another page or in another region (show them in the list, as today).

## 6. Every fight the mod referees uses link rules

- [x] **Done** (`docs/plans/gen3-badge-rules.md`). Fights against the
      computer get the carts' badge boosts and obedience on Gen 3, and every
      generation's fights between players are link battles. On the way it
      turned out Gen 2 had never applied badge boosts (the referee read Red's
      badge names). That is fixed too.

**Now:** fights against the computer apply the carts' badge boosts and
obedience, on Gen 1 (boosts), Gen 2 (Gold's boosts and type badges) and Gen 3
(boosts and obedience). Every generation's fights between players are link
battles. Where it lives: the referees' `BADGE_MODES` gate, the Gen 3 sheet's
`traded` / `unfateful`, and the `obey` event (`docs/plans/gen3-battle-sheet.md`
§6, §7.2.1).

## 7. A trainer draw with your team standing leaves the trainer unbeaten

- [ ] Accept it (document only), or ask upstream for a draw answer.

**Why:** the cart's `trainerbattle` opcode has no answer for a draw, so the
mod halts the trainer's script where it waited. You get no prize, flag, TM or
badge, and the trainer challenges you again through the cart's own sight
check. A draw that leaves your team on nothing is a whiteout, as on the cart.

**Where:** `SoloBattle.haltScript3` (`src/SoloBattle.lua` ~l.3060, reasoning
~l.2240) and `CoopField` `haltScript3` (`src/CoopField.lua` ~l.1211).

**To do:** probably nothing. A real fix is an engine seam that lets a mod
hand `trainerbattle` a draw outcome (Lane B; fold it into the RFC in item 8).

## 8. Gen 3 reaches into engine internals

- [ ] Turn `docs/upstream/gen3-spawn-npc.md` into an upstream RFC, then move
      each reach-around onto the seam it gets.

**Why:** the game3 mod API has no public `spawnNpc`, `player.sprite`,
`screen.pushed` or battle-intercept seam, so the mod (declaring
`engine_internals`) does it directly:
- `Avatars` injects remote players as engine event objects;
- `Cast` wraps `OwSprites.playerGraphicsId` for the worn look;
- `CoopField` wraps `BattleBridge.start` to take trainer and wild fights;
- `Avatars` shields the FireRed quest-log recorder and Emerald's rotating-tile
  puzzle from avatars.

Every wrap goes through `Gen3.wrapFn` / `unwrapFn` and every require through
`Gen3.engine`. An engine update that renames one of these internals breaks
that feature on Gen 3 until the mod follows.

**To do:**
1. Open the RFC against gen1recomp (`dev`) with the Lane B obligations:
   `docs/rfcs/NNNN-<slug>.md`, a backward-compatibility statement, a parity
   test pair (vanilla unchanged; the seam driven through the public mod API),
   regenerated registry docs, nothing removed.
2. Include the seams items 4 and 7 want (neighbour draw pool, trainer draw
   outcome).
3. After it lands, migrate one reach-around at a time, keeping the fallback
   for older engines.
4. Until then, re-run the Gen 3 e2e matrix after every engine update.
