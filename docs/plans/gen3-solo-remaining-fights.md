# Gen 3 SOLO BATTLES: the fights still left to the cart

| | |
|---|---|
| Base SHA | `2288f2b` |
| Branch | `feature/firered-and-emerald-support` (1.5.0, unreleased) |
| Asked for | "Solo battles leave some fights to the game itself: Emerald double battles, the Safari Zone, roaming and scripted legendaries, the Battle Frontier, Trainer Tower and Trainer Hill, and the first and tutorial battles. Fix it." (`docs/plans/gen3-known-gaps.md` §2) |
| Research | `$SP/G3S/{ARCH,SAF,LEG,FAC,DBL}.md` (read-only research agents, pret / engine / mod anchors) |
| Rule source | pret `pokefirered` / `pokeemerald`; where the engine port disagrees, pret wins and the difference goes to `docs/upstream/gen3-spawn-npc.md` |

## Scope

Taken over by SOLO BATTLES (single player, local referee), on the carts that have them:

| Family | Refusal keys | Carts |
|---|---|---|
| Two-trainer pairs; Steven's multi battle | `twoOpponents`, `trainerIdB`, `partner` | EM (FRLG has neither) |
| Safari Zone | `safari` + `CoopField.safari3` | FR/LG, EM |
| Roamers | `roamer` + `enc.roamer` | FR/LG (beasts), EM (Latios / Latias) |
| Scripted wilds and legendaries | `wildScripted`, `legendary`, `regi`, `groudon`, `kyogre`, `kyogreGroudon`, `rayquaza` | both |
| Pokémon Tower ghosts, veiled and unveiled | `ghost`, `ghostBattle` + `CoopField.ghost3` | FR/LG |
| Facilities | `frontier`, `battleTower`, `dome`, `palace`, `arena`, `factory`, `pike`, `pyramid`, `trainerHill`, `trainerTower`, `secretBase` (tents included) | EM (frontier, tents, hill, secret base), FR/LG (tower) |
| First battles | `firstBattle` (Oak's lab), `firstBattleKind` (Birch) | FR/LG, EM |
| Tutorials (scripted replays) | `oldManTutorial`, `tutorialKind` / `tutorial` (Wally), `pokedude` (Teachy TV) | FR/LG, EM |

Owner decisions (2026-10-06): all three tutorials are replayed on the mod's screen, the Pokédude through a new `engine_internals` wrap of the Teachy TV start; the veiled ghost is taken too.

**Stays on the cart:** link, union room, spectate, recorded battles, `towerLinkMulti`, `multi` (link-only), and the Emerald e-Reader (not implemented by the engine; FR/LG's needs a scanned e-Card — kept refused unless a driver can reach it, see below). They are another cart in lockstep or a replay of the cart's own inputs; keeping them preserves `affects_link: false`.

**Not in scope:** co-op versions of any of these (two humans): the carts have no two-player Safari, roamer, facility or tutorial, and every design would invent rules and need the hub and a PROTOCOL bump. Co-op keeps refusing every key above (C1).

## Contracts

### C1 — two refusal lists

- `Config.COOP_REFUSED_GEN3` = today's `SOLO_REFUSED_GEN3`, unchanged: co-op refuses everything it refused.
- `Config.SOLO_REFUSED_GEN3` = only what stays on the cart: the link family (`link`, `multi`, `unionRoom`, `spectate`, `recordedLink`, `towerLinkMulti`) and `eReader`.
- `CoopField.refused3` takes the list to read; the stands (`wildStand3`, `trainerStand3`) refuse with the co-op list for co-op and the solo list for solo, and the hard-coded refusals (`safari3`, `ghost3`, `enc.foe`, `enc.roamer`) become kinds, refused by co-op only.
- `offerFight3` offers co-op only a fight co-op does not refuse; everything else goes straight to solo.
- Every stand carries `stand.kind3`: `"wild" | "trainer" | "safari" | "roamer" | "legendary" | "scripted" | "ghost" | "facility" | "pair" | "partner" | "firstBattle" | "tutorial"`, plus `stand.facility3` (the hall: `"tower" | "dome" | "palace" | "arena" | "factory" | "pike" | "pyramid" | "hill" | "trainerTower" | "secretBase"`, tents named by their hall) and `stand.tutorial3` (`"oldMan" | "wally" | "pokedude"`).

### C2 — the solo kind registry (`src/SoloBattle.lua`)

Each family lives in its own module `src/Solo3/<Family>.lua` and registers with `SoloBattle.registerKind3(name, kind)`. The core calls a kind's hooks, when present, at these points, and its own behaviour otherwise. W1-S fixes the exact signatures and reports them; the shape is:

- `takes(self, stand, opts) -> bool, why` — after the common gates, before seating.
- `seat(self, ctx) -> createOpts, sides` — adds create options (C3) and side entries (ally, second trainer).
- `brains(self, ctx)` — who answers which NPC seat (see C4).
- `word(self, ctx, outcome) -> word` — the engine outcome word (C5).
- `settle(self, ctx, outcome)` / `finish(self, ctx, outcome, word)` — prize, catch, whiteout or not, writeback, engine tails, before `done(word)`.
- `screen(self, ctx) -> screenOpts` — what the screen is told (safari, ghost, lesson, partner, two foes, facility rules, tutorial script).

### C3 — referee create options and side fields (both twins; never on a hub's wire unless stated)

- `wildPick = "cart"` — a computer *wild* seat picks a random usable move (pret: every wild battle but safari / roamer / first battle has no AI); solo passes it on every Gen 3 wild fight. Without it, today's heuristic.
- Side entry `ai = "roamer" | "firstBattle"` on a wild entry:
  - `roamer`: AI_Roaming — flee unless wrapped / escape-prevented, the foe has Shadow Tag, or Arena Trap without Levitate; else a random usable move. A sleeping or frozen roamer still flees; Encore / Struggle / recharge stop it.
  - `firstBattle`: AI_FirstBattle — flee when the player's monster is at ≤ 20% HP, ignoring speed.
- **A wild seat's flee** (a `run` filed for a side-b wild seat): sorted with the moves at priority 0 by speed, re-checked when it executes (wrap / Mean Look / Shadow Tag / Arena Trap), never the player's escape formula. Outcome `how = "flee"`.
- `outcome().how` and `outcome().by`: how the fight ended — `"ko" | "run" | "flee" | "teleport" | "roar" | "catch" | "forfeit" | "balls" | "judge"` — and which side's action ended it. `reason` keeps its meaning.
- Side entry `spare = true` (Steven): the side is down when every non-spare fighter is.
- Side entry `bagFrom = "<playerId>"` (a pair's B): spends from that fighter's bag (A's four items, one pool).
- `rules = { bag, forfeit, exp, boosts = { damage, speed }, obedience, theft, soulDew, pyramidBag }` — facility rules; absent = today's behaviour. `forfeit = true` turns RUN into a forfeit (`how = "forfeit"`, the forfeiting side loses).
- `firstBattle = "oak" | "birch"`:
  - `oak`: until the foe first loses HP, the player's damaging moves can't miss; until its first stat fall, status moves can't miss; no crits either side until the first damage; `lesson` events at the cart's eight points.
  - `birch`: no crits; the player's RUN is refused with "Don't leave me like this!".
- `ghost = "veiled" | "unveiled"`:
  - `veiled`: both sides' moves cancelled ("too scared to move" / "Get out… Get out…"), RUN always succeeds, a thrown ball is dodged and spent, no weather damage to the ghost, Intimidate and Trace do nothing.
  - `unveiled`: balls dodged; otherwise a normal fight.
  - A dodged ball is a `ball` event with `amount = -1`.
- `safari = { family, balls, catchFactor?, escapeFactor?, goNearCatch, goNearEscape, pkblToEscape }` (wave 2) — the Safari mode (`$SP/G3S/SAF.md` §3).
- Tutorials (wave 2): a side with **no battlers** (Safari shares it), a forced catch that gives nothing (`catch = "forced"`), and the scripted choices the solo driver files.
- `rules.palace`, `rules.arena` (wave 3) — `$SP/G3S/FAC.md` §3.

### C4 — who answers an NPC seat

- Trainers: one `SoloBrain` per trainer (a pair has two; Steven has one, on side a).
- Wild seats: the referee (`autoPick` → `wildPick` / `ai`).
- `SoloBrain` gets a slot → battler-id helper so a brain can sit on either side.

### C5 — the outcome word handed to `done`

From `outcome().how` / `by` and the cart's rules, never from the side alone:

- caught → `"caught"`; a wild flee → `"mon_fled"`;
- the player's RUN → `"run"`;
- TELEPORT / ROAR / WHIRLWIND: FRLG `"teleport_player"` whoever used it; EM `"teleport_player"` when the player used it, `"mon_teleported"` when the wild monster did;
- out of Safari Balls → `"no_safari_balls"`; a forfeit → `"forfeited"`;
- a facility draw → `"draw"` (not the trainer-script halt); a pair's draw → `"lose"` (its `done` is engagePair's finish, not a VM wait).

### C6 — new wire vocabulary (Wire / sanitize, both twins; no PROTOCOL bump — no hub emits these)

- **Event `lesson`** `{ text = <lesson id> }` (Oak's lab).
- **Choice action `safari`** `{ action = "safari", throw = "ball" | "bait" | "rock" | "near" | "block", block = <pokéblock index>? }`.
- **Wave 3:** event kinds `palace` and `arena` (shapes fixed by W3-R).

## Waves

File ownership is strict within a wave; later waves inherit.

| Wave | Id | Owns | Delivers |
|---|---|---|---|
| 1 | RF | `src/BattleSim3/*`, `server/lib/battle3/*`, `tests/battle_sim3_*`, `server/battle3_*.test.js`, `tests/fixtures/battle3_turn_parity.json`, `battle_sim3_vectors.json` | C3 except `safari`, tutorials and wave-3 rules; outcome `how` / `by`; parity scenarios; a Lua↔JS fuzzer for BattleSim3 |
| 1 | G | `src/Config.lua`, `src/CoopField.lua`, `src/Client.lua`, `src/Coop.lua`, `tests/gen3_coop.lua`, `tests/gen3_client.lua` | C1; the stands for every kind (facility trainer record from opts and its mons as the engine built them; pair, partner, roamer, ghost, safari, first battle, tutorial stands); the Pokédude wrap (`Gen3.wrapFn`) routed to solo |
| 1 | S | `src/SoloBattle.lua`, `src/Sheet3.lua`, `tests/gen3_solo.lua`, `tests/solo_battle.lua` | C2; C5's word mapping; the generic multi-owner brain loop (`_answerFoes3` for any NPC owners on either side); finish fixes every kind needs (the `birch` / `scriptedLoss` no-whiteout arms, `clearSavedSong`, real quest-log / TV / `battle.ended` kinds, `opts.song`); sheet fields (`safariFleeRate`, `fateful`, `arenaMind` per move, no held-item roll for legendaries, the FRLG common == rare roll) |
| 1 | B | `src/SoloBrain.lua`, `tests/solo_brain.lua` | C4: a brain on either side; one per trainer with its own flags / items or a shared pool |
| 1 | W | `src/Wire.lua`, `server/lib/sanitize.js`, `server/twin_parity.test.js`, `tests/rby_mmo_test.lua` | C6 (`lesson`, the `safari` action) |
| 1 | UM | `src/MediatedBattle.lua`, `src/ClassicBattle.lua`, `tests/mediated_battle_client.lua`, `tests/gen3_mediated.lua` | a fight with no own battler; facility prompts (bag refused, forfeit yes / no); the `lesson` voice-over; the ghost name, silhouette and unveil; first-battle lines |
| 1 | UC | `src/CoopBattle.lua`, `src/Battlefield.lua`, `src/Vfx.lua`, `tests/coop_mediated.lua`, `tests/gen3_solo_double.lua`, `tests/gen3_battlefield.lua` | two foe trainers (figures, names, intro / defeat lines); Steven on side a (back pic, send-out line, his slot); facility prompts on the double screen |
| 2 | R2 | the RF files | `safari` mode (new `Safari.lua` / `Safari.js`); the no-battler side and forced catch for tutorials |
| 2 | K-LEG | new `src/Solo3/Legend.lua`, new `tests/gen3_solo_legend.lua` | roamers (writeback through `Roamer.onBattleEnd`, hand-back with the original encounter, music), scripted / legendary wilds, ghosts; the dex-seen rules |
| 2 | K-SAF | new `src/Solo3/Safari.lua`, new `tests/gen3_solo_safari.lua` | the Safari block, ball writeback per throw, no whiteout / reconcile, the engine tails (`Safari.endBattleRse` / `outOfBallsMidBattle`), the Pokéblock case |
| 2 | K-FAC | new `src/Solo3/Facility.lua`, new `tests/gen3_solo_facility.lua` | the facility classifier → `rules`; `Battle._nextFacility` taken and restored; `lastFrontierBattle`, Dome last moves, `disableRecordBattle`; the Pyramid bag; exact party writeback; draws and forfeits |
| 2 | K-DBL | new `src/Solo3/Doubles.lua`, new `src/Solo3/First.lua`, new `tests/gen3_solo_pairs.lua` | pairs (B's party through the `trainer.party` hook, A's item pool, both defeat texts, prize A + B); Steven (ally seat, `spare`, EXP participants, `scriptedLoss`); Oak's lab; Birch |
| 2 | UM2 / UC2 | the UM / UC files | the Safari screen (menu, balls box, throws, Pokéblock case); dodged-ball and scared lines; anything K-* reports for the screens |
| 3 | R3 | the RF files + W's files | Palace and Arena rules, and their `palace` / `arena` events |
| 3 | K-FAC2 | `src/Solo3/Facility.lua`, `src/SoloBrain.lua` | the Palace move-group pick (client side, both sides) and the Arena judge glue |
| 3 | K-TUT | new `src/Solo3/Tutorial.lua`, new `tests/gen3_solo_tutorial.lua` | old man, Wally and Pokédude replays: the cart's scripted inputs on the cart's timing; the forced catch; no give |
| 3 | UM3 | the UM files | the Palace screen (no move menu), the Arena judgment window, the tutorial overlays and back pics |
| 4 | E | `tests/drivers/solo_battle_e2e.lua`, `tests/drivers/mmo_util.lua`, the Gen 3 runners | an e2e leg per family on FireRed and Emerald (real play where reachable, the engine's own entry with a prepared session where post-game) |
| 4 | D | docs | known gaps §2 closed; README, mod.card, CHANGELOG; the sheet contract; the new reach-arounds and engine divergences in `docs/upstream/gen3-spawn-npc.md` |

## Verification

- **Headless:** every Lua suite and Node test green.
- **Parity:** the parity fixtures regenerated and reproduced by both twins; a BattleSim3 Lua↔JS fuzzer at 0 mismatches.
- **e2e:** the full matrix green (Gen 1, Gen 2, Gen 3), with the new Gen 3 legs passing.
