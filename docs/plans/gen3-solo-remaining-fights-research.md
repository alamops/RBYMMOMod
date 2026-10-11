# Gen 3 solo, the fights left to the cart: research findings and wave-1 contracts

Companion to `docs/plans/gen3-solo-remaining-fights.md`.

- **Part 1** is the research (2026-10-06), condensed from five read-only research reports. The full reports were scratch files and are gone, so this is now the reference.
- **Part 2** is what wave 1 actually built (commits `eb2b198`..`59fbe2a`). Wave 2 onward builds against it.

Line anchors are in three forms:
- **mod:** `File.lua:N`, at the commit named;
- **engine:** gen1recomp `dev` @ `fdea09dc`, under `src/core/game3/` unless stated;
- **pret:** `pokefirered` (fr) / `pokeemerald` (em).

## Part 1: research

### 1.1 How a Gen 3 fight is taken (before wave 1)

**Two doors**, both in `src/Client.lua`:
- the `encounter.roll` wrap, for step wilds;
- `CoopField.installStart3` → `divertStart`, wrapping `BattleBridge.start` / `startWild`. Every other kind comes in through this one.

**The Pokédude never passes either door.** `battle/pokedude.lua:611` calls `Battle.start` directly, so it needs its own wrap.

**Stand-ins:**
- `wildStand3` and `trainerStand3` build them.
- `offerFight3` (`Client.lua` ~2683) offers co-op first, then solo.
- Solo enters through `fromGen3Trainer` / `fromGen3Encounter`, then `_begin3`, which seats the fight.
- The fight runs through `_choose` / `_submit3` and `_answerFoe`.
- `_settle3` is the first half of the finish (catch, prize, whiteout decision).
- `_ended3` is the second half: it reconciles the party, writes `battleOutcome` through `Natives.outcome_to_code`, then whiteout, Pickup, learn / evolve, `_finishEffects3`, and finally `done(word)`.

**Engine outcome words** (`scripting/natives.lua:198`):

| Code | Words |
|---|---|
| 1 | win |
| 2 | lose |
| 3 | draw |
| 4 | run |
| 5 | player_teleported |
| 6 | fled / mon_fled |
| 7 | caught |
| 8 | no_safari_balls |
| 9 | forfeited |
| 10 | mon_teleported |

**What the engine's own finish does** (`BattleBridge.finish`, `battle_bridge.lua:405`):
- `Roamer.onBattleEnd` (`:415`);
- `Audio.clearSavedSong` for first battles (`:433`);
- the no-whiteout arms for `firstBattleKind == "birch"` and `scriptedLoss` (`:247`–`249`);
- the TV battle-type flags and real `kinds`.

Solo replayed none of these before wave 1.

**BattleSim3 before wave 1:**
- Wild foes in solo used the mod's effectiveness heuristic. The carts pick a random usable move for every wild battle except Safari, roamer and first battle (fr `battle_controller_opponent.c:1355`, em `:1563`).
- A wild seat's RUN used the player's escape formula.
- Several entries on one side already worked in `coop_npc`. That is the co-op 2v2 shape, and it is what a pair and Steven are built on.

**Engine start opts by kind** (what the start wrap sees):

| Kind | Opts |
|---|---|
| trainer | `trainerId`, `defeatText`, `victoryText`, `earlyRival`, `rivalFlags`, `firstBattle`, `noWhiteout`, `double`, `trainerTower`, `eReader` |
| em pair | `trainerIdB`, `twoOpponents`, `defeatTextB` (from `trainer_sight.lua:605`; its own `finishBattle` sets both flags) |
| Steven | `twoOpponents`, `partner`, `playerHalf`, `partnerTrainerId`, `partnerBackPic`, `trainerItems = {0,0,0,0}`, `scriptedLoss` (from `natives_frontier_story.lua:258`). His three mons are appended to `sess.party`. |
| scripted wild | `foe.wildScripted` |
| fr legendary | `legendary` |
| em legendary | `legendary`, `transitionId`, `song`, plus the row kind (`kyogre`, `groudon`, `rayquaza`, `regi`, `kyogreGroudon`) |
| Marowak | `wildScripted`, `foe.ghost`, `foe.ghostUnveiled` |
| old man | `oldManTutorial` |
| Wally | `tutorialKind = "wally"` |
| Birch | `firstBattleKind = "birch"` |
| Trainer Tower | `trainerTower` |
| Trainer Hill | `trainerHill`, `frontierTrainer` |
| Secret Base | `secretBase`, `noWhiteout`, `deferHeal` |
| Frontier halls | `frontier`, `<hall> = true`, `frontierTrainer[B]`, plus `twoOpponents` / `frontierFoeHalf` / `partner` / `playerHalf` for multis |
| Pike / Pyramid wild | `pike` \| `pyramid`, `frontier`, `scriptedLoss`. These bypass `encounter.roll`. |
| roamer | `enc.roamer`, through the roll hook |
| Safari | nothing on the encounter; the session's Safari mode decides |

### 1.2 Safari Zone

**In battle** (fr `battle_main.c:2281,2565,3537,4334-4429`; em `battle_util.c:52-76,541-622`; `battle_controller_safari.c`; `safari_zone.c`):

- **The player's battler is zeroed.** No send-out, no faint handling, no EXP. The trainer back pic stays up, and a "SAFARI BALLS / Left: NN" box takes the place of the player's healthbox.
- **Menus:**
  - FRLG: BALL / BAIT / ROCK / RUN, with the prompt "What will\nPLAYER\nthrow?".
  - EM: BALL / POKéBLOCK / GO NEAR / RUN, with the prompt `gText_WhatWillPkmnDo2`.
  - No FIGHT, BAG or POKéMON. BALL is refused at selection while the party and every box are full.
- **Factors:**
  - Catch factor: `catchRate * 100 / 1275`.
  - Escape factor, FRLG: `safariZoneFleeRate * 100 / 1275`, floored at 2.
  - Escape factor, EM: always 3.
- **FRLG throws:**
  - Bait: a counter of +2..6 (max 6), and the catch factor halved (floor 3), never undone.
  - Rock: a counter of +2..6, and the catch factor doubled (max 20), reset to the species value when the rock counter runs out.
- **EM throws:**
  - Go Near: catch +4 / 3 / 2 / 1, escape +4 (max 20). The fifth and later say "can't get any closer!".
  - Pokéblock: the verdict (curious / enthralled / ignored, by nature) is decided client-side before the battle engine. The block leaves the save at once. Escape is reduced from a small table, keeping the vanilla glitch where escape can reach 0.
- **Turn order:** the player always acts first, then the wild monster.
- **The wild monster's action** is decided at selection, from the counters as the turn opened. It flees, or watches / eats / gets angry (FRLG reaction animations; EM "watching carefully").
  - FRLG flee chance: escape × 5. With a rock out: min(20, esc × 2) × 5. With bait out: max(1, esc / 4) × 5.
  - EM flee chance: escape × 5.
- **Ball:**
  - The count drops first.
  - The catch rate is `catchFactor * 1275 / 100`, with the Safari Ball's ×1.5.
  - It is not counted in catch attempts or the capture stat.
  - If the last ball misses: "out of SAFARI BALLS! Game over!" and the outcome is NO_SAFARI_BALLS (8), before the wild monster acts.
- **RUN** always succeeds.
- **Start and end:**
  - No battle stats, TV daily count or rematch tick at the start.
  - EM: no TV at the end; Pokérus still applies. FRLG: the quest log records a catch.
  - EM Safari Fan Club counters.
  - Out of balls mid-battle: the out-of-balls script and a warp to the entrance.
  - The step counter is never touched.
- **Engine:** `battle_bridge.lua:27,493-507` marks a standard wild as Safari while the mode is on. The battle code is `battle/init.lua:719-737,2091-2240,445-455`, `battle/rules.lua:86-249` and `ai.lua:326`. The session side is `safari.lua` (`endBattleRse:173`, `outOfBallsMidBattle:235`, `outOfBalls:290`), with `field.lua:1781` `pollSafariBalls`. Emerald's tables are read from the cart (`rse_tables.lua`).
- **Engine vs pret:** the engine counts the daily wild and ticks rematch on a Safari start, has no full-box refusal, and floors the catch odds at 1.
- **Design:**
  - A `safari` mode in both twins (new `Safari.lua` / `Safari.js`) with thin `Turn` hooks; side a fields no battler.
  - Create option `safari = { family, balls, goNearCatch, goNearEscape, pkblToEscape, escapeFactor }`.
  - Choices `{action = "safari", throw = ...}` and `{action = "run"}`.
  - RNG order: the flee roll `roll(0,99)` first, then the player's action (`roll(0,4)` for bait or rock; up to four `roll(0,65535)` for a ball), then the wild monster's flee or watch.
  - No new event kinds:
    - `item.amount` carries the balls left;
    - new anims `BAIT_THROW`, `ROCK_THROW`, `POKEBLOCK_THROW`, `SAFARI_REACTION` (amount 0/1/2);
    - an `over` reason `balls`, and a side-b `run` for the monster fleeing.
  - The outcome carries `safari = { balls, pokeblockThrows }`.
  - Solo glue:
    - no whiteout, no reconcile;
    - write `session.safari.balls` back on every throw, and don't count the Safari Ball in catch stats;
    - map the outcome to `no_safari_balls`;
    - engine tails: EM `Safari.endBattleRse`; FRLG `Safari.outOfBallsMidBattle` when out of balls.
  - Screen: a Safari arm on `MediatedBattle`. The Pokéblock picker is the engine's own case (`chooseForBattle`, `pokeblock_case.lua:470`).
  - Decisions taken:
    - solo only;
    - EM tables travel in the create opts, read from the cart;
    - follow pret wherever the engine differs, including the full-box BALL refusal;
    - on a referee fault, hand the fight back with the balls already spent.

### 1.3 Roamers, scripted wilds, legendaries, ghosts

**The outcome code is what matters.** Post-battle scripts branch on `GetBattleOutcome`:
- WON, RAN or PLAYER_TELEPORTED (5) means "defeated" or "ran"; any other code falls through to the "caught / fought" flags.
- TELEPORT / ROAR / WHIRLWIND give 5 on FRLG whoever used them. On EM they give 5 when the player used them and MON_TELEPORTED (10) when the wild monster did (`VARIOUS_SET_TELEPORT_OUTCOME`).
- EM Mew's script tests 10 explicitly.
- Getting this wrong loses a legendary (for example, Mew read as caught).

**Scripted wilds and legendaries:**
- No rule changes in battle; they can be run from and caught.
- No wild held-item roll.
- A random move: the AI is gated to TRAINER / FIRST / SAFARI / ROAMER only, so the FRLG legendary AI flags are dead code.
- FRLG doesn't mark the legendary seen at the intro.
- `fatefulEncounter` is set; special songs and transitions apply.
- Lost or drew: the script whites out.

**Roamers:**
- AI_Roaming flees unless the roamer is wrapped or escape-prevented, the foe has Shadow Tag, or the foe has Arena Trap and the roamer lacks Levitate. Otherwise it uses a random usable move.
- The flee is ordered with the moves at priority 0 by speed and re-checked when it executes.
- A sleeping or frozen roamer still flees; Encore, Struggle and recharge stop it.
- After the battle: HP and status are saved, and the roamer always relocates.
- Any odd outcome code (1, 3, 5, 7, 9) deactivates it — the vanilla Roar / Teleport bug.
- FRLG plays MUS_VS_LEGEND.

**Ghost (FRLG Pokémon Tower):**
- **Veiled** (no SILPH SCOPE):
  - Both sides' moves are cancelled ("too scared" / "Get out… Get out…"), and RUN always works.
  - Balls are dodged and spent.
  - The ghost takes no weather damage, and Intimidate and Trace do nothing.
  - No dex "seen".
- **Unveiled Marowak:** a normal fight, except balls are dodged, and extra intro lines. VAR_RESULT is FALSE only on a win.

**Engine** (`battle_bridge.lua` finish, `natives.lua:432-499`, `natives_frontier_story.lua:200-340`, ghost rules in `battle/engine.lua:689` and `init.lua:2386`) differs from pret in seven places, E1–E7:
1. The FRLG roamer deactivation bug is "fixed".
2. A sleeping roamer can't flee.
3. FRLG legendaries use AI scripts.
4. The beasts get MUS_VS_DEOXYS.
5. The FRLG roamer `pid` and IV keys are mismatched, and the step-encounter roamer battle rebuilds the monster from species and level only (personality and IVs re-rolled, HP and status full). pret's CreateRoamerMonInstance restores them.
6. The FRLG item roll ignores LEGENDARY and the common == rare → always rule.
7. FRLG legendaries are marked seen.

**Design:**
- The referee's `how` / `by` (done in wave 1); the wild flee and `ai = "roamer"` (wave 1); `ghost` (wave 1).
- Solo glue:
  - the word comes from `how` / `by` plus the cart's teleport rule (done in wave 1);
  - roamer writeback calls the engine's own `Roamer.onBattleEnd` once, after `Sheet3.applyToMon`, including the sleep counter;
  - a roamer handed back restarts with the original encounter;
  - music is `opts.song`, else the FRLG species table, else MUS_VS_LEGEND for FRLG roamers;
  - no dex "seen" for FRLG legendaries or veiled ghosts.
- Decisions:
  - follow pret on deactivation, by calling the engine's `onBattleEnd`;
  - solo only;
  - EM legendary backgrounds and transitions are deferred.

### 1.4 Facilities

**Every Emerald Frontier fight** (Tower, Dome, Palace, Arena, Factory, Pike, Pyramid, and the Battle Tents):
- **Rules:**
  - The bag is refused, except in the Pyramid, which uses the Pyramid bag.
  - RUN asks "forfeit the match?" and gives outcome 9.
  - No EXP, prize or Pay Day.
  - No badge boosts and no disobedience; Soul Dew does nothing.
  - The foe may Thief or Trick. There are no trainer items and no dex "seen".
- **AI:** flags BAD | VIABILITY | TRY_TO_FAINT (the Factory sets them per challenge).
- **A loss is scripted:** no whiteout, no heal, and the trainer says its win line.
- **Palace:**
  - The player's FIGHT skips the move menu.
  - Both sides pick a move group by nature; the AI scores only inside it.
  - 50% "unable" fail, and a flavour line at half HP.
- **Arena:**
  - No switching; replacement is in party order.
  - After 3 turns, a Mind / Skill / Body judge "faints" the loser, who keeps their HP.
- **Dome:** the facility reads back the last move each side used.
- **Battle Tents:** Verdanturf uses Palace rules, Fallarbor Arena rules, Slateport Factory rules.

**Trainer Hill (EM):**
- Bag allowed, badge rules apply, no EXP.
- No Thief or Trick on either side.
- RUN forfeits.
- Cart quirk: the item-setup exclusion list lacks TRAINER_HILL, so hill opponents read `gTrainers[<hill local id>].items`, an unrelated trainer's items. Confirm in pret and reproduce.

**Trainer Tower (FRLG):**
- Bag allowed, badge rules apply, no EXP, no theft.
- RUN is refused like any trainer's. **Not** a forfeit: FRLG has no `STRINGID_QUESTIONFORFEITMATCH`.
- Pays Pickup, no money.
- Its double is a lone double. A loss or draw heals the party and warps to the lobby.

**Secret Base (EM):**
- An ordinary trainer fight: EXP, a prize of 20 × lead level, the foe may steal.
- No whiteout.
- It needs record-mixed bases.

**e-Reader:** FRLG needs a scanned e-Card; EM's is not implemented by the engine. **Kept refused.**

**Left to the cart around the battle:** party selection, levels, heals, streaks, prizes, swaps, the Dome bracket.

**Handed back:** `opts.done(word)` with `win` / `lose` / `draw` / `forfeited`, plus an exact party write-back. Pike and Pyramid don't heal between battles.

**Engine:**
- Every facility exists (`rse/frontier/*`, `battle/facility_{palace,arena,dome}.lua`, `trainer_hill.lua`, `trainer_tower.lua`, `secret_base.lua`), but it is less faithful than pret in battle:
  - the bag is usable in the Frontier;
  - disobedience stays on in the Frontier;
  - Secret Base fights lose the badge damage boosts;
  - AI flags fall back to 1 for the Tower and e-Reader, where pret uses 7;
  - there are no two-trainer fights in the Pyramid or Hill.
- **Two couplings the mod must handle:**
  - `Battle._nextFacility`: Palace, Arena and Dome set this module global before the start, and only the engine's own battle clears it. Take it on take, and restore it on hand-back.
  - The Frontier's `done` rebuilds `sess.lastFrontierBattle` (the Tower interview) from stale engine state. Overwrite it after `done`.
- **Also write:**
  - `sess.frontierDomeLastMoves = {player, opponent, outcome}`;
  - `frontier.disableRecordBattle = 1`.
- **Palace design:**
  - The move pick happens on the client, for both sides, from the player's cart's tables (`f2_data.palace()`).
  - The referee runs only the "unable" path and the half-HP event, and accepts a disabled-move pick under `rules.palace`.
- **Arena design:**
  - The referee runs the judge, tracks the judged mons, auto-replaces them and refuses switches.
  - Each move row carries `arenaMind`, from the player's cart.
  - Arena AI: never switches, sends out in party order.
  - Palace targeting follows `GetBattlePalaceTarget`.
- **New event kinds** `palace` / `arena`, in Wire / sanitize.
- **Order:** the base and the simple halls first, Pike / Pyramid wilds next, then Palace, then Arena.
- **Tower multis and the Pike double** wait for the partner / two-opponent work.

### 1.5 Pairs, Steven, first battles, tutorials

**EM pair** (em `battle_setup.c:1273`; engine `trainer_sight.lua:554` `engagePair`):
- Each trainer fields their first three mons. A is battler 1 and B is battler 3, and each switches only within their own half.
- AI flags A | B | DOUBLE for both.
- Items: only A's four, as one pool either foe can spend.
- Prize A + B, with **no ×2**. Both defeat texts; both flags set (B, then A).
- A draw must call `done("lose")`: halting leaves `F.locked` set and freezes the player.
- Add a Pyramid / Trainer Hill guard.

**Steven** (em `battle_tower.c:2122`; engine `natives_frontier_story.lua:258`):
- The player brings three mons and Steven fields his fixed three. Foes are Maxie and Tabitha, with no items.
- Steven's AI uses the opponents' flags, may switch, never uses items, never disobeys.
- **The fight is lost when the player's three are down, even if Steven's still stand** (em `battle_script_commands.c:3543`).
- Steven's mons share EXP as participants.
- The script reads VAR_RESULT and whites out itself on anything but a win (`scriptedLoss`). No mod whiteout, and always `done(word)`.

**Oak's lab** (FRLG first battle; the engine models it in `oak_advice.lua`, `engine.lua:421`, `rules.lua:341`):
- Every player move is sure to hit until the first stat fall. This includes Protect, because pret reads `gBattleMoves[0].power`.
- Crits are drawn and voided until the first damage.
- Oak's voice-over comes at eight points.
- A loss heals the party: no whiteout, no money lost.

**Birch's Zigzagoon** (EM, level 2):
- No crits; RUN is refused with "Don't leave me like this!". A Smoke Ball or Run Away still escapes (em `battle_main.c:4021`).
- AI_FirstBattle flees when the player's monster is at ≤ 20% HP, ignoring speed.
- EXP is given; no TV and no whiteout.
- pret rolls a held item (FIRST_BATTLE isn't exempt from SetWildMonHeldItem); the engine passes `item = 0`.

**Tutorials** (owner decision: replay all three on the mod's screen):
- **Old man** (FRLG Viridian): a Weedle L5 catch, played out automatically. Uses `gText_WhatWillOldManDo` and the old man's back pic. The catch is forced and the mon is never given.
- **Wally** (EM): his Zigzagoon weakens a Ralts and he catches it. Simulated inputs; the catch is forced, nothing is given.
- **Pokédude** (FRLG Teachy TV): demos started from `Pokedude.startTeachyTvBattle`, with the Pokédude's own party. On-screen tutorial text; the bag is restored afterwards.
  - The engine's `finish_battle` (`battle/pokedude.lua:585`) compares the result to "catch", so the done word must be "catch".
  - Codes: WON 1, LOST 2, DREW 3, RAN 4, CAUGHT 7.
- **Design:** the no-battler side (shared with Safari), a forced catch that gives nothing, and a scripted-seat driver that files the cart's inputs on the cart's timing.

**Kept refused:** `multi` (it only arrives with `opts.link`) and `towerLinkMulti`.

## Part 2: wave-1 contracts, as built

### 2.1 Referee (`eb2b198`; `src/BattleSim3/Turn.lua` ↔ `server/lib/battle3/Turn.js`)

**Create options** (absent = old behaviour; never on a hub's wire):
- `wildPick = "cart"`
- `firstBattle = "oak" | "birch"`
- `ghost = "veiled" | "unveiled"` (wild modes only)
- `rules = { bag = false, forfeit = true, exp = false, boosts = false | {damage = false, speed = false}, obedience = false, theft = "foe" | "none", soulDew = false, pyramidRun = 1..255, pyramidBag = true }`
  - Normalised onto `battle.rules`: `noBag`, `forfeit`, `noExp`, `noDamageBoost`, `noSpeedBoost`, `noObedience`, `theft`, `noSoulDew`, `pyramidRun`, `pyramidBag`.
  - `pyramidBag` does nothing in the referee.

**Side-entry fields:**
- `ai = "roamer" | "firstBattle"`: honoured only on a wild seat.
- `spare = true`.
- `bagFrom = "<playerId>"`.
- New refusals: `"<owner> has a bad bagFrom"`, `"side <x> has only spare fighters"`.

**Outcome** — `outcome().how` / `outcome().by`:

| Ending | `how` | `by` |
|---|---|---|
| player RUN, Smoke Ball, Run Away, Poké Doll, a link concession | `run` | the runner's side |
| wild seat's flee | `flee` | `"b"` |
| TELEPORT | `teleport` | the user's side |
| ROAR / WHIRLWIND | `roar` | the user's side |
| ball | `catch` | the thrower's side |
| RUN under `rules.forfeit` | `forfeit` | the forfeiting side |
| KO | `ko` | the winner (nil on a draw) |

- `balls` and `judge` are reserved for later waves.
- `how` is absent after a disconnect or timeout.

**Events:**
- **`lesson {text}`**, with ids `intro`, `damage`, `stat`, `potion`, `party`, `run`, `win`, `lose`. Each fires once a battle, except `run`.
  - `intro` comes before turn 1.
  - `damage` follows any side-b HP-bar update, heals included.
  - `stat` follows the first "foe's X fell!" in a side-a action.
  - `party` and `potion` come when a choice is accepted.
  - `run` comes on every refused side-a RUN.
  - `win` / `lose` come right before `over`.
- **A dodged ball** is `ball` with `amount = -1`, then msg "It dodged the thrown BALL! This POKeMON can't be caught!".
- **Veiled cancel:**
  - side a: msg "<X> is too scared to move!" plus `anim MON_SCARED`;
  - side b: msg "GHOST: Get out...... Get out......" plus `anim GHOST_GET_OUT`.
- **Flee:** msg "Wild X fled!" then `run {side = "b"}`, or msg "Wild X can't escape!".

**Silent refusals:** Birch's side-a RUN; every item under `rules.bag = false`; Oak's side-a RUN (which leaves the `run` lesson).

**Exports:** `Turn.HOW`, `LESSONS`, `FIRST_BATTLES`, `GHOSTS`, `WILD_AI`, `ITEM_POTION`, `copyRules`, `battle.lessons`.

**Deviations from the plan's C3** (all follow pret):
- Oak: every move sure-hit until `stat`.
- The flee's execution check covers wrap and escape prevention only; Shadow Tag and Arena Trap are AI_Roaming's choice-time checks.
- In doubles, `wildPick` draws over all side-a seats.

**Parity:** 183 scenarios in `tests/fixtures/battle3_turn_parity.json`. They are hand-authored inputs; `--update` writes the `expect` fields. There is a Lua↔JS fuzzer recipe (gen.py → fz.lua + fz.js → cmp; the scratch copy is lost, so re-create one as needed).

**Wire** (`3ccf2ad`, plan C6): the `lesson` event on Gen 3 readers. The `safari` choice is `{action = "safari", throw = "ball" | "bait" | "rock" | "near" | "block", block = 1..40?}`, accepted only when the generation reads 3. Family gating is the referee's job.

### 2.2 Doors (`4aee25a`; `src/CoopField.lua`, `src/Client.lua`, `src/Config.lua`, `src/Coop.lua`)

**Lists:** `Config.COOP_REFUSED_GEN3` is the old list. `Config.SOLO_REFUSED_GEN3` is `link`, `multi`, `unionRoom`, `spectate`, `recordedLink`, `towerLinkMulti`, `eReader`.

**Listening:** `wants(kind, mapId)` returns `false`, `true` (co-op only) or `"solo"`. The builders take `ctx.solo`.

**What solo receives** through `fromGen3Trainer` / `fromGen3Encounter`:
- `opts.stand3`, `opts.party = stand.enemyParty`, `opts.done`, `opts.fallback = stand:fightAlone`, `opts.mapId`.
- For Safari: `opts.safari` and `enc.safari`.
- `enc.mon` is the built lead.
- The Pokédude comes through `fromGen3Encounter` with `enc = {species, speciesId, level, pokedude = true, mon}` and `opts = {wild, pokedude, pdScriptNum}`.

**Stand fields:**
- **Every stand:** `kind`, `kind3`, `facility3`, `tutorial3` ("oldMan" | "wally" | "pokedude"), `firstBattle3` (oak | birch), `ghost3` (veiled | unveiled), `coopRefused3`, `scriptedLoss`, `opts`, `enemyParty`, `trainer`, `encounter`, `foe`.
- **Safari:** `safari`.
- **Roamer:** `roamer`, `roamerFoe`.
- **Pair:** `trainerIdB`, `trainerB`, `enemyPartyB`, `defeatTextB`.
- **Partner:** `partner`, `playerHalf`, `partnerTrainerId`, `partnerBackPic`, `partnerTrainer`, `partnerParty`. Steven's three mons are lifted out of `session.party` and restored before any hand-back.
- **Facility:** `nextFacility3`, and a `facilityRecord3` trainer that adds `facility`, `frontierTrainerId`, `defeatText`, `victoryText`.
- **Pokédude:** `pokedudeScript`, `playerParty`, `teachyOpts`. `done(word)` calls `TeachyTv.restorePlayerBag`, then `opts.onDone(code)`.

**Stand methods:** `begin3()` takes `_nextFacility` and does the per-kind start bookkeeping per pret `battle_setup.c`: no wild tick for Safari or Wally; no rematch tick for Frontier halls, Secret Base or Steven. `giveBack3()`; `fightAlone()`.

**`CoopField.buildMon`** depends on `SoloBattle.gen3WildItem(species, random16)` and `SoloBattle.gen3HeldRoll(opts, spec)`.

### 2.3 Solo core (`db67b7a`; `src/SoloBattle.lua`, `src/Sheet3.lua`, `src/SoloBrain.lua`)

**Kind registry:**
- `SoloBattle.registerKind3(name, kind)`.
- A family module `src/Solo3/<Family>.lua` returns `{ kinds3 = { name = kind } }`, or registers itself.
- Modules are loaded lazily from `KIND_FILES3`, and only when `mod:read` finds the file.
- The kind name is taken from `opts.stand3.kind3`, then `opts.kind3`, then the engine keys.
- A non-default name with no kind registered is handed back to the cart.

**ctx (`self.gen3`):**
- **From the entry:** `solo`, `game`, `kind` ("wild" / "trainer"), `name`, `hooks3`, `stand`, `facility3`, `tutorial3`, `firstBattle3`, `ghost3`, `opts`, `foe`, `trainerId`, `done`, `session`, `family`, `song`, `parties[ownerId]`.
- **After seating:** `party`, `wildMon`, `trainer`, `enemySheets`, `pending`, `fight`, `create`, `sim`, `npcs`, `double`, `foeSeats`, `screen` ("single" / "double").
- **After the verdict:** `outcome`, `verdict`, `whiteout`, `healAfter`, `deferHeal`, `scriptedLoss`.
- **Flags a kind may set:** `partyless`, `noReconcile`, `lossless`, `noPickup`, `noDexSeen`.

**Hooks**, called as `kind:hook(ctx, ...)`:

| Hook | Arguments | Returns |
|---|---|---|
| `takes` | — | ok |
| `screen` | screenOpts | extra? |
| `seat` | create | extra?, sides? (appended) |
| `brains` | npcs | extra? |
| `choose` | payload, seat | handled, taken |
| `note` | event | — |
| `settle` | outcome | handled |
| `word` | outcome, ending | doneWord? (replaces the result and lifts the halt) |
| `finish` | outcome, ending | after? (runs after `done`) |
| `handBack` | — | handled |

- The order is takes → screen → seat → brains → (choose / note) → settle → word → finish → done → after.
- A throw in the first four hooks hands the fight back. A later throw is said once and the fight goes on.
- `ending = {result, word, halt, playerMon, foeMon, playerMon2, lastFoeMon}`.

**Answerers:**
- `npcs[owner]` is a `SoloBrain`, a `function(view, seat)`, `"referee"` or `false`.
- The seat ids are fixed: side a's first entry is `solo_player`, side b's is `solo_foe`.
- `ctx.solo:file3(...)` files a choice, and `ctx.solo:parkLine3(text)` parks a line.

**Exports:** `gen3Words`, `teleportBySide3`, `gen3HeldRoll`, `gen3FoeMon(row, {wild, heldRoll})`, `engineFlags3`, `engineKinds3`, `tvBattleType3`, `sideIds3`, `loadKinds3`.

**Sheet3:** wild sheets carry `safariFleeRate` and `fateful`. There is `arenaMind` on move rows (`stampArenaMind`, `moves(..., {arena})`).

**SoloBrain** (C4):
- `SoloBrain.new3{ trainer, aiFlags (a number, or a list ORed together), items | pool = itemPool3(A, ownerId), noItems, noDisobey, owner, side, rng }`.
- `brain:sheets3()` clears `traded` for Steven.
- `facilityFlags3()` gives the facility default.
- The Palace seam is `view.moveMask` / `view.moveOnly`.
- Examples:
  - **Pair:** `solo_foe = new3{trainer = A, aiFlags = {A, B}, pool, owner = "solo_foe"}` and `solo_foe_b = new3{trainer = B, aiFlags = {A, B}, pool, owner = "solo_foe_b"}`. In the referee, A has `bag`, and B has `bagFrom = "solo_foe"`.
  - **Steven:** `solo_ally = new3{aiFlags = {maxie, tabitha}, noItems, noDisobey, owner = "solo_ally", side = "a"}`. The foe brains get `noItems` too.
  - **Facility:** `new3{trainer = rec, aiFlags = opts.aiFlags or facilityFlags3(), noItems = true}`.
- Not yet: Arena's never-switch rule and party-order send-out, and Palace targeting. These are wave 3.

### 2.4 Screens (`59fbe2a`)

**Single screen** (`MediatedBattle.new(opts)` or `fight:applyScreenOptions(opts)`):
- **Options:** `noOwnBattler`, `commands = {ids ≤ 4}`, `commandLabels`, `commandHandlers[id] = fn(screen, id)`, `prompt`, `rules {bag = false, forfeit = true}`, `firstBattle`, `ghost`, `song`.
- **Methods:** `sayLesson3(id)`, `noteLesson3`, `flushLessons3`, `runCommand(id)`, `ask(text, fn(yes), {defaultNo = true})`, `ghostVeiled()`.
- **Statics:** `ghostName3`, `dodgeLine3`, `isDodgeLine3`, `GENERAL_ANIMS3` (MON_SCARED, GHOST_GET_OUT, SILPH_SCOPED), `ITEM_POTION3`.
- **Stream:** a side with no battler sends no side-a `send` / `faint` / `exp`.

**Double screen** (`CoopBattle.newSoloDouble`):
- **Options:** `trainerB`, `npcPartyB`, `peerNameB`; `partner` (`name`, `className`, `backPic` | `partnerBackPic = "steven"`, `gfxName = "OBJ_EVENT_GFX_STEVEN"`), `partnerParty`, `partnerName`, `playerHalf`; `rules`; `song`.
- **Slots:** 1 = field 0; 2 = field 1 (the player's second, or Steven); 3 and 4 = fields 3 and 4.
- **Forfeit:** `{action = "run", seat}`.
- **Methods:** `sayPairDefeated3()`, `sayTrainer3("a" | "b" | nil, text)`, `isPartnerSeat3`, `seatTrainer3`.
- **Kinds must:**
  - order the sides in field order;
  - seat B's and the ally's referee entries from the same sheets they pass the screen;
  - end a pair with `sayPairDefeated3()` plus the summed prize.

### 2.5 Remainders handed to wave 2

**K-FAC:**
- Under `rules.forfeit`, file the trainer's RUN through `ctx.solo:file3` in the `choose` hook. Otherwise `_choose` parks it as the trainer-RUN refusal.
- FRLG Trainer Tower must not set `forfeit`.
- Confirm the Trainer Hill items quirk.

**K-DBL:**
- In the First `choose` hook, Birch's refused RUN parks `Gen3.battleText("STRINGID_DONTLEAVEBIRCH")` or "PROF. BIRCH: Don't leave me like this!".
- Birch's Zigzagoon gets the pret held-item roll.
- A pair ends with `sayPairDefeated3()`.

**K-LEG:**
- Altering Cave held items: `rules.wildHeldItem(species, {})` without `alteringCave` never rolls them.
- Roamer writeback, roamer hand-back, music, dex-seen rules.

**Safari and tutorials:** `ctx.partyless = true`, screen `noOwnBattler`, the Safari grid through `commands` / `commandHandlers`, and the balls box (UM2). Prompts are per cart.

**UC2:**
- Looks for MON_SCARED, GHOST_GET_OUT, SILPH_SCOPED.
- The ball throw starts from the trainer figure when there is no own seat.
- Lone-double wording: the opening and mid-fight send-out lines should use the cart's text, and the classic page should slide the trainer back in for its defeat text.

**Wave D (Tower multis):**
- The Frontier multi partner's classic pics follow pret (his front pic at x 32, the player's front pic flipped at x 90).
- `Gen3.trainerBackPic` only reaches indices 0 and 1.
- Check the party reload after a solo-won Tower multi.

**Docs:**
- The sheet contract gains `how` / `by`, the new create options, `lesson`, `ball -1`, the anim tokens, the `safari` choice, `safariFleeRate`, `fateful`, `arenaMind`.
- Upstream notes gain:
  - the TEACHY TV wrap;
  - LEG E1–E7, the start-bookkeeping ticks, Trainer Tower mons ignoring `abilityNum` / `ppBonuses` / nickname, fixed-nature personality, AI flag fallbacks;
  - Oak's accuracy, Oak's crit draw and the unveiled-ghost run;
  - Oak's `litHealthbox`;
  - `BattleBridge.tvBattleEnd`'s shifted arguments;
  - the facility couplings (`_nextFacility`, `lastFrontierBattle`).

## Part 3: wave-2 contracts as built, and remainders (commits `1ad1a88`..`4d2c346`)

### 3.1 Referee: Safari and tutorials (`1ad1a88`)

**`safari` create option** (wild mode only):
- **Required:** `family = "frlg" | "rse"`, `balls` (0..255).
- **Emerald also needs:** `goNearCatch[4]`, `goNearEscape[4]` and `pkblToEscape` (a 1-based list of at least 4 rows of 3, converted from the engine's 0-keyed `pkblToEscapeFactor`).
- **Optional:** `catchFactor` and `escapeFactor` overrides.
- **FRLG** reads the wild sheet's `safariFleeRate`.
- **Side a** is `{playerId, name}` with no mons; `noBattler` is implied.

**Choices:**
- `{action = "safari", throw = "ball" | "bait" | "rock" | "near" | "block"}`, gated by family.
- `block` needs `verdict` (0 curious, 1 enthralled, 2 ignored) and an optional `blockName`. Wire strips both, so the solo `choose` hook builds the block choice and files it with `ctx.solo:file3`.
- `{action = "run"}` always succeeds.

**Outcome:**
- `how = "catch" | "balls" | "flee" | "run"`.
- `safari = {balls, pokeblockThrows}` is present on every ending.

**Events:**
- A ball throw is `item {slot 0, side "a", text "5", amount = balls left}`, then `ball {target 3, amount = shakes, or 4 for a catch}`.
- Throws are `anim BAIT_THROW | ROCK_THROW | POKEBLOCK_THROW {slot 0, side "a", target 3}`.
- FRLG only: `anim SAFARI_REACTION {slot 3, side "b", amount 0 | 1 | 2}`.
- The wild seat files `chose` as each turn opens.
- Go Near's "can't get any closer!" comes from the **4th** step (pret `battle_util.c:604`), not the 5th as §1.2 said.

**Tutorials:**
- **Side-entry `noBattler = true`** (side a of a wild fight, no mons):
  - RUN always gets away.
  - Only party-free bag items are allowed.
  - A seat facing only no-battler seats passes its turn.
- **`catch = "forced"`:** the ball shakes three times and catches; the outcome carries `given = false`.
- **`tutorial = "oldMan" | "wally" | "pokedude"`:** a forced catch plus each tutorial's rules:
  - old man and Wally: no crits;
  - Pokédude: crits drawn but voided, sure hits on both sides, no disobedience, side-b effects gated except sleep.
- **NPC-driven side a:** `wildPick` and `ai` stay off side a.

### 3.2 Family modules (`3d84b26`, `7984b9b`, `9155379`)

Each family is a `src/Solo3/*.lua` module returning `kinds3`; `KIND_FILES3` maps every kind name to its file.

| Module | Kinds | Main helpers |
|---|---|---|
| `Legend.lua` | `roamer`, `legendary`, `scripted`, `ghost` | `roamerFinish3`, `roamerHandBack3`, `statusByte3`, `song3`, `noDexSeen3`, `ghostOf3` |
| `Facility.lua` | `facility` | `rulesFor(hall, kind, sess)`, `screenRules3`, `hillItems3`, `pyramidBag3` / `pyramidWriteback3`, `lastFrontierBattle3`, `trackDomeMoves3`; hall sets `FRONTIER_HALLS`, `WAVE3_HALLS = {palace, arena}`, `WILD_HALLS`, `TRAINER_HALLS` |
| `Doubles.lua` | `pair`, `partner` | `seatPair`, `sayWon`, `payPrize`, `inPyramidOrHill`, `restorePartner` |
| `First.lua` | `firstBattle` | `which`, `rollHeldItem`, `cantRunText` |

- **Seat ids:** `solo_foe_b` is the second trainer (slot 4); `solo_ally` is Steven (slot 1, `spare`).
- **Shared rig:** `tests/fixtures/gen3_solo_dbl_rig.lua`.
- **Facility ctx fields:** `facility3`, `facilityRules3`, `noPayDay3`, `pyramidBag3`, `nextFacility3`, `domeLastMoves3`.

### 3.3 Screens (`4d2c346`)

- **`Vfx`:** `Vfx.forGeneral3(anim, amount)` returns beats; `Vfx.isGeneral3(anim, safari)` (`ROCK_THROW` counts only in a Safari fight).
- **`Battlefield`:**
  - seat motions `sway`, `nod` and `tremble`, each taking `wait`;
  - a vfx `fromTrainer = "ally" | "foe"`;
  - `ballOrigin` and `vfxOrigin` exported.
- **`CoopBattle`:** `emitVfx(spec, target, from, fromTrainer)`, `startGeneralLook3(row)`, `slideInForSpeech3`.

### 3.4 Remainders routed to waves 3 and 4

**CORE** (wave 3):
- **Altering Cave held items:**
  - `SoloBattle` `gen3WildItem(species, random16, opts)`;
  - every `wildHeldItem` call passes `{alteringCave = ...}`, computed from `mapId == "EM_ALTERING_CAVE"`, with the stand / `foeMon3` / `wildFoe3` / `wildStand3` forwarding it.
- **`gen3Words`:** a double-KO whiteout saves "draw" (DREW 3) while `done` stays "lose".
- **`applyToMon`:** carries a caught wild monster's sleep counter.
- **`owes()`:** a `noBattler` seat owes a choice only in the choice phase.
- **Emerald `SetWildMonHeldItem`** overwrites a scripted `setwildbattle` item for a non-legendary wild.
- **`loadKinds3`:** call it at boot.

**R3** (wave 3):
- Palace and Arena rules, and their `palace` / `arena` events (Wire / sanitize).
- Under `rules.forfeit` + `pyramidRun`, a Run Away runner rolls `_pyramidEscape` first (pret em `battle_util.c:427-447`).

**K-SAF** (wave 3):
- The Pokéblock choice comes from the engine's case:
  - the verdict is set by the wild monster's nature;
  - the block leaves the save.
- The full-box BALL refusal at selection.
- Ball writeback on each `item` event and from `outcome.safari.balls`.
- The engine tails.

**UM3** (wave 3):
- The Safari screen: the per-cart grid and prompt, the balls box, the Pokéblock case.
- `grantCatch` only when `msg.given ~= false`.
- The general looks on the single screen (a twin of `startGeneralLook3`; `FX_SPAN` sway / nod / tremble; `VFX_KEYS` `fromTrainer` / `wait`).
- The single screen's trainer slide-in for the win / lose speech.
- A `bag` screen option (the Pyramid bag).
- Frontier victory music: MUS_VICTORY_TRAINER, and MUS_VICTORY_GYM_LEADER for a Frontier Brain.
- The ClassicBattle GBA page draws no general look yet.

**UC3** (wave 3): `TURN_TRAP`, `FOCUS_PUNCH_SETUP`, `FUTURE_SIGHT_HIT` and `DOOM_DESIRE_HIT` should be quiet general looks; today they raise a callout and a lunge.

**K-TUT / UM4** (wave 4):
- Wally's turn-3 recall. File the ball as turn 3's choice; the screen plays the recall and slide-in, and the foe doesn't act.
- The seat names ("The old man", "The POKe DUDE", "WALLY") and a bag with names.
- The Pokédude:
  - `rules = {exp = false}` if wanted;
  - its done word is "catch";
  - `TeachyTv.restorePlayerBag` runs through the stand's `done`.

**K-FAC2** (wave 4):
- Palace and Arena taken over: drop them from `WAVE3_HALLS` and add them to `rulesFor`.
- Tower multis with an NPC partner, and the Pike two-trainer double, taken through the pair / partner seats.
- The Frontier multi partner's classic pics (pret: his front pic at x 32, the player's front pic flipped at x 90).
- `Gen3.trainerBackPic` only reaches indices 0 and 1.

**Docs and upstream** (wave 5):
- **E-FAC1–5:**
  1. The stale `lastFrontierBattle`.
  2. FRLG Trainer Tower texts are missing.
  3. The Secret Base prize arm is missing.
  4. FRLG Trainer Tower `noWhiteout` heals at the end.
  5. There is no Secret Base defeat text.
- **Roamers (engine vs pret 1.0):**
  - Deactivation and relocation differ.
  - The status is banked as a word.
  - `opts.alteringCave` is never set.
- **The early rival:** pret sets the trainer flag on a loss too.
- **Missing engine arms:** `engagePair` has no Pyramid / Hill arm; Steven's defeat texts are missing (check them in e2e).
- **Emerald `SAFARI_REACTION`:** the engine plays one; pret has none.
- **Engine check order:** Pokédude accuracy; old man crits.
- **New reach-arounds:** the `sim._fightAction` instance wrap, the `Tower.setInterviewData` re-run, `VAR_LAST_TALKED`.

**Known gaps** (not planned):
- Steven's monsters can level mid-battle on the cart from the EXP they share; the mod pays only the player's own slots.
- A Safari monster that arrives with a status or under weather can faint at the end of a turn.
