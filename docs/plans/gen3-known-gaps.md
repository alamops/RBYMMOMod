# Gen 3 known gaps (after 1.5.0)

A backlog of what FireRed / LeafGreen / Emerald support shipped without. Each
one is also listed under **Known** in `CHANGELOG.md` [1.5.0]; this file adds
where it lives in the code and what closing it would take.

| # | Gap | Kind | Size |
|---|-----|------|------|
| 1 | LeafGreen never run live | verification (needs a ROM) | S |
| 2 | Solo battles leave some fights to the cart (done: only link fights and the e-Reader stay) | mod work, per fight type | done |
| 3 | Cross-region trades follow the post-game rule | cart-faithful, decision | S |
| 4 | Players across a seamless map edge (done) | mod work using native ghost pools | done |
| 5 | Party figures on the region map (done) | mod UI work | done |
| 6 | Badge boosts and obedience against the computer (done) | both referees and clients | done |
| 7 | Unfinished trainer draws do not complete a victory (done) | mod finish paths | done |
| 8 | Gen 3 reaches into engine internals | upstream RFC | L |
| 9 | A fainted monster is replaced after the end of turn, not after the action | referee turn flow, both twins | L |
| 10 | Two referee differences: Conversion 2's memory, a failed RUN's order in a wild double | referee, both twins | S each |
| 11 | Gen 3 presentation gaps (clips, cursors, menus, pics) | screens | S each |

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

## 2. Solo coverage for the remaining fight families (done)

- [x] **Lone doubles: done** (`docs/plans/gen3-solo-doubles.md`). This was on
      all three carts, not only Emerald; FireRed / LeafGreen lone doubles had
      been handed back too.
- [x] **Every other fight a player can walk into: done**
      (`docs/plans/gen3-solo-remaining-fights.md`, with its research and the
      contracts as built in `docs/plans/gen3-solo-remaining-fights-research.md`).

**Taken over by `SOLO BATTLES`, each family in its own module:**

| Family | Carts | Module |
|---|---|---|
| Two trainers at once; Steven beside the player | EM | `src/Solo3/Doubles.lua` |
| The Safari Zone | FR / LG, EM | `src/Solo3/Safari.lua` |
| Roamers, scripted wilds and legendaries, the POKéMON TOWER ghosts (veiled and unveiled) | both (ghosts FR / LG) | `src/Solo3/Legend.lua` |
| The Battle Frontier (all seven halls, the three Battle Tents), Trainer Hill, Secret Bases; Trainer Tower | EM; FR / LG | `src/Solo3/Facility.lua` |
| Battle Tower multis with a partner, the Battle Pike's two-trainer room | EM | `src/Solo3/FacilityMulti.lua` |
| The first battles (Oak's lab, Birch's ZIGZAGOON) | FR / LG, EM | `src/Solo3/First.lua` |
| The tutorials (the old man, WALLY, the POKé DUDE through the TEACHY TV) | FR / LG, EM | `src/Solo3/Tutorial.lua` |

**What stays on the cart, and why** (`Config.SOLO_REFUSED_GEN3`,
`src/Config.lua` ~l.985–1012, where each name has its reason):
- `link`, `unionRoom`, `spectate`, `multi` (the link multi) and
  `towerLinkMulti`: another cart fighting this one in lockstep over the
  engine's relay. Taking them would make this mod a party to the link, and
  `affects_link: false` promises it never is.
- `recordedLink`: a replay of the cart's own recorded inputs against its own
  RNG. There is nothing to decide, and the engine records none.
- `eReader`: Emerald's e-Reader trainer is not implemented by the engine, and
  FireRed / LeafGreen's needs a scanned e-Card no player or driver can reach.
  `CoopField.classify3` already classifies it as a facility (`facility3 =
  "eReader"`), so taking it is dropping this one name once a driver can stage
  one.

Co-op still refuses every family above (`Config.COOP_REFUSED_GEN3`, unchanged):
the carts have no two-player Safari, roamer, facility or tutorial, and any
co-op design would invent rules and need the hub and a PROTOCOL bump.

**Where it lives:**
- The doors: `CoopField.classify3` stamps every stand-in with `kind3` and its
  detail (`facility3`, `tutorial3`, `firstBattle3`, `ghost3`);
  `CoopField.refused3` reads the list it is given, so solo and co-op refuse
  separately. The TEACHY TV's start is wrapped (`installPokedude3`,
  `divertPokedude`) because the POKé DUDE never passes `BattleBridge.start`.
- The core: `SoloBattle.registerKind3` and `KIND_FILES3`
  (`src/SoloBattle.lua` ~l.2300); the hooks are listed in the research's §2.3.
- The referee: the solo-only create options, side fields, choices and events
  (`docs/plans/gen3-battle-sheet.md` §1.4, §1.5, §7.4).
- The engine reach-arounds this needed, and the engine-port divergences found
  on the way: `docs/upstream/gen3-spawn-npc.md` addendum D.

**Still different from the cart** (recorded during the work, not planned):
- Steven's monsters gain EXP as participants on the cart (they sit in
  `gPlayerParty[3..5]`) and can level mid-fight; the mod pays only the
  player's own monsters.
- Items 9–11 below, which every Gen 3 fight shares.
- What the engine port does differently from pret in these fights is the
  upstream's to fix: `docs/upstream/gen3-spawn-npc.md` addendum D.

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

## 4. Players across a seamless map edge (done)

- [x] Draw remote players on neighbouring maps from presence.

`src/Avatars.lua` uses the engine's `Map.world` placements to find visible
maps and injects each neighbouring avatar into that map's native ghost pool.
The engine animates and draws it there; `src/Overlay.lua` uses the same
offsets for its nameplate. Retired objects and captured copies are still
removed when a player or the local view changes maps, preventing frozen
duplicates. Neighbouring NPCs remain intact.

`tests/gen3_presence.lua` covers all four connection directions with signed
offsets, ghost animation, look refresh, crossing into the active map, and
removal when a map is no longer connected, on FireRed and Emerald.

## 5. Party figures on the region map (done)

- [x] Put a character per party member on the region map, as Red does on the
      town map.

`src/RegionMap3.lua` places partners using the cart's decoded section geometry,
filters the selected Kanto/Sevii page or Hoenn region, and projects through
PokéNav zoom and scrolling. `src/Overlay.lua` draws each partner's safe
character portrait and nickname on that cell; two partners sharing a cell
stand side by side. Indoor maps use the centre of their named section because
presence does not carry the remote save's last outdoor warp. Unknown sections,
other regions and moving caves that need remote weather vars are omitted.

`tests/gen3_presence.lua` checks placement and actual HUD drawing on both
families, page filtering, missing roster entries, shared cells, indoor maps,
and PokéNav screen gating, zoom, scrolling and letterbox placement. The older
party-map screenshots show the previous list presentation.

## 6. Badge boosts and obedience against the computer (done)

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

## 7. Unfinished trainer draws do not complete a victory (done)

- [x] A timeout, disconnect, forfeit, or any other draw while the party can
      still battle does not set the trainer flag, pay the prize, or run the
      post-battle script. The script is halted and the trainer stays unbeaten.
      A wiped draw is still a whiteout.
- [x] Promote only a knockout (`how` `ko` or `judge`, or `reason` `ko`) whose
      referee sheets and the save disagree: a sheet that still stands, or a
      save monster the sheets do not cover that still stands. Covered slots
      are read from the sheets, because reconcile has not run.
- [x] In co-op that decision is the referee's, once. A knockout draw whites
      every client out. Local party HP does not complete the trainer on one
      client. Facilities keep their own draw rules.

**Where:** `SoloBattle:_settle3`, `SoloBattle:_ended3`, `Solo3/Doubles`,
`Coop.finishBuriedBattle`, `Coop:onBattleOver`, `CoopBattle:onBattleOutcome`
and `CoopField.Stand:finish`.

## 8. Gen 3 reaches into engine internals

- [ ] Turn `docs/upstream/gen3-spawn-npc.md` into an upstream RFC, then move
      each reach-around onto the seam it gets.

**Why:** the game3 mod API has no public `spawnNpc`, `player.sprite`,
`screen.pushed` or battle-intercept seam, so the mod (declaring
`engine_internals`) does it directly:
- `Avatars` injects remote players as engine event objects;
- `Cast` wraps `OwSprites.playerGraphicsId` for the worn look;
- `CoopField` wraps `BattleBridge.start` to take trainer and wild fights;
- `CoopField` wraps `Pokedude.startTeachyTvBattle` to take the POKé DUDE's
  demonstrations, and covers the TEACHY TV the way the engine's own start
  does (its `Stack._layers` and the bag / START menus' `open` flags);
- the facility fights keep the engine's Frontier state straight
  (`Battle._nextFacility`, `lastFrontierBattle` and the Tower interview,
  `VAR_LAST_TALKED` on Trainer Hill) and read the Frontier's trainer records
  through `rse/frontier/trainers.lua`;
- `Avatars` shields the FireRed quest-log recorder and Emerald's rotating-tile
  puzzle from avatars.

Each of these is written up, with its cost and the seam that would replace
it, in `docs/upstream/gen3-spawn-npc.md` (the body, addendum A, addendum D).

Every wrap goes through `Gen3.wrapFn` / `unwrapFn` and every require through
`Gen3.engine`. An engine update that renames one of these internals breaks
that feature on Gen 3 until the mod follows.

**To do:**
1. Open the RFC against gen1recomp (`dev`) with the Lane B obligations:
   `docs/rfcs/NNNN-<slug>.md`, a backward-compatibility statement, a parity
   test pair (vanilla unchanged; the seam driven through the public mod API),
   regenerated registry docs, nothing removed.
2. ~~Include the seams items 4 and 7 want~~ Done: the proposal is one
   request, with the neighbour-map objects (addendum B) and the trainer draw
   answer (addendum C) beside the runtime objects, `player.sprite`,
   `screen.*` and `battle.intercept` (addendum A). Open it as one RFC.
3. After it lands, migrate one reach-around at a time, keeping the fallback
   for older engines.
4. Until then, re-run the Gen 3 e2e matrix after every engine update.

## 9. A fainted monster is replaced after the end of turn, not after the action

- [ ] Run the faint flow after every action, as the carts do, in both twins.

**The cart** (pret `pokeemerald` / `pokefirered`): every action's script ends
in `Cmd_end` (em `battle_script_commands.c:3950`, fr `:3798`), which hands the
action over as `B_ACTION_TRY_FINISH`; `HandleAction_TryFinish` (em
`battle_util.c:638`, fr `battle_main.c:4433`) runs `HandleFaintedMonActions`
(em `battle_util.c:1880`, fr `battle_util.c:1144`), and
`BattleScript_HandleFaintedMon` asks for and sends the replacement **right
then**, before the next action and before the end-of-turn effects.

**The referee** (`src/BattleSim3/Turn.lua` ↔ `server/lib/battle3/Turn.js`)
keeps BattleSim2's replace phase: a seat emptied mid-turn stays empty until
after the end-of-turn block, then `_openReplace` (Turn.lua ~l.2268, Turn.js
~l.2245) asks every owed seat at once. The same monsters end up standing, but
not through the same turn:
- the newcomer escapes what the cart would hit it with that turn: sandstorm
  or hail chip, and in a double a later move aimed at that seat;
- the end-of-turn effects of the fallen monster's side run with the seat
  empty instead of filled;
- one bench monster owed to two seats goes to the first in battler order
  rather than to the seat owed first.

The one exception is the Battle Arena (`rules.arena`): a replacement there
asks nobody (party order), so the referee already sends it right after the
action, as the cart does (`_arenaRefill`, `Arena.lua` ~l.217, called from
`_resolveFights`, Turn.lua ~l.2791).

`docs/plans/gen3-battle-sheet.md` §9.1 discloses it ("when a replacement comes
in"). It predates the work that took the remaining solo fights over, and
affects every Gen 3 fight, solo, co-op and between players. It is the Gen 3
twin of the Red / Gold gaps in `docs/plans/gen12-referee-known-gaps.md` §4 and
§8.

**To close it:** a replacement step inside `resolving` (after
`_afterAction`, `Move.lua` ~l.2607, and its JS twin) that solicits the owed
seat's pick before the next action — a human seat's pick then waits on the
choice clock mid-turn — plus the end of turn reading the refilled seat.
Every Gen 3 turn-parity scenario with a mid-turn faint changes order, so the
fixture is regenerated and fuzzed again; the screens must take a
replacement solicitation (`turn` with a `slot`) in the middle of a turn's
events.

## 10. Two referee differences

Both predate this release's solo work and affect every Gen 3 fight; both
twins carry them.

- [ ] **Conversion 2's memory.** pret clears the *actor's*
  `gLastLandedMoves` / `gLastHitByType` at the end of each of its actions
  (`HandleAction_ActionFinished`: fr `battle_main.c:4468-4469`, em
  `battle_util.c:675-676`), so Conversion 2 only reads a hit taken since the
  user last acted. BattleSim3 sets them on a landed hit (`Move.lua`
  ~l.2175-2176, `Move.js` ~l.2409) and never clears them, so CONVERSION 2
  (`Effects.lua` ~l.1718, `Effects.js` ~l.2095) can succeed off an older hit
  where the cart says "But it failed!". **To close:** clear both fields on the
  actor in the after-action step, plus a parity scenario.
- [ ] **A failed RUN's turn order in a wild double.** When the player's
  battler 0 (on Emerald, battler 2 too) chose RUN in a fight that is not a
  link battle, pret puts the RUN first and every other battler's action after
  it **in battler order, unsorted**: no item / switch hoist, no priority or
  speed sort (`SetActionsAndBattlersTurnOrder`: fr `battle_main.c:3559-3577`,
  em `:4785-4808`). The referee resolves runs first too (`_resolveRuns`,
  Turn.lua ~l.2289, Turn.js ~l.2266) and then orders the rest as on any turn.
  Only a *failed* RUN shows it (a successful one ends the fight), so it is
  reachable in co-op against a wild monster. FireRed / LeafGreen hoist battler
  0's RUN only. **To close:** under that condition, order the remaining
  actions by battler id in `_beginTurn`, plus parity scenarios for both carts.

## 11. Gen 3 presentation gaps

What the battle screens (`src/MediatedBattle.lua` and `src/ClassicBattle.lua`
for the single screen, `src/CoopBattle.lua` for the double one, `src/Vfx.lua`
and `src/Battlefield.lua` for the looks) still show differently from the
carts. None of them changes a result.

**Clips:**
- [ ] The general clips (Vfx `GENERAL_ANIMS3` / `Vfx.forGeneral3`) play no
  sound effects. There is no audio data on the development machine to check
  them against.
- [ ] The referee never sends some general clips the cart plays: weather
  continuing, LEECH SEED's drain, INGRAIN, WISH, KNOCK OFF, an item stolen,
  SNATCH, the FOCUS BAND, a held item's effect, the SMOKE BALL, MON_HIT,
  Castform's change, a stat change, the Substitute fading. Some of them are
  drawn from other events. Closing it is a `quiet` `anim` per clip in both
  twins, at pret's point.
- [ ] The Arena tremble has one height, and DOOM DESIRE's beats are collapsed
  into one.
- [ ] The double page (`CoopBattle`) has neither the GBA page's opening
  slide-in nor its send-out slide-out (`gen3Figures3` ~l.16516,
  `alliesUnseen3`); only the single screen's GBA page has them.
- [ ] `ClassicBattle`'s `drawThrows3` uses the singles geometry on the double
  field. No double sends a thrown look today.
- [ ] The slides move in whole pixels (`MediatedBattle.introSlideDx3`,
  `SLIDE_OUT3`); the cart's 8.8 fixed point can land a pixel apart.
- [ ] Not checked against the cart: Emerald's
  `B_ANIM_BALL_THROW_WITH_TRAINER` nudge, and a `trainerslideout` after the
  ending speech.

**Menus and cursors:**
- [ ] **Encore.** pret files an encored battler's move without opening the
  move list. Both screens open the list; whatever row is picked, the referee
  uses the encored move (`Turn.lua` `_normaliseChoice`, sheet §1.2).
- [ ] **The move list.** Ours moves linearly, up / down with a wrap; pret's
  is a 2×2 grid with no wrap (`MediatedBattle:updateMoveMenu`,
  `CoopBattle`'s move menu).
- [ ] **An empty bag.** Ours says "You have nothing to use!"
  (`MediatedBattle:updateItemMenu`, `CoopBattle`); the cart opens the bag
  anyway, with only CLOSE BAG / CANCEL.
- [ ] **The bag position.** The cart keeps the bag's pocket and cursor
  between opens (`gBagPosition`); ours starts at the top each time
  (`itemIndex`).
- [ ] **Cursors across battles.** The cart's action and move cursors carry
  from one battle to the next (`BattleStartClearSetData` does not clear
  them); ours start fresh with each fight. Within a fight both screens keep
  them as the cart does.

**Pics and picks:**
- [ ] **Trainer front pics.** The engine does not expose
  `gTrainerFrontPicCoords[id].size`, so the figure is placed with size 8
  (`CoopBattle` ~l.16500); a shorter pic sits a few pixels high.
- [ ] **The Battle Palace's pick** (`SoloBrain:_palace3`, ~l.2428) floors the
  move score once per script, where pret floors it after each command. The
  pick also draws from the referee-side generator rather than the cart's
  `Random()`, as every draw does.
- [ ] **The POKé DUDE's overrun.** His input scripts run on from one
  demonstration's rows into the next (STATUS into MATCHUPS, MATCHUPS into
  CATCHING), as on the cart, and that is kept. A demonstration that outlasts
  CATCHING's last row reads, on the cart, whatever bytes follow the table
  (`battle_controller_pokedude.c` `PokedudeSimulateInputChooseAction`). The
  engine's port throws there; `Tutorial.pdTakeAction3` plays FIGHT, which
  keeps the demonstration going.
