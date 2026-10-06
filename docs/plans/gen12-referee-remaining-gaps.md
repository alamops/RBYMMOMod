# Red / Gold referee: closing the remaining known gaps

| | |
|---|---|
| Base SHA | `fd7b31e` |
| Branch | `feature/firered-and-emerald-support` (1.5.0, PROTOCOL 30, unreleased) |
| Asked for | rows 1–4 of `docs/plans/gen12-referee-known-gaps.md` and the LURE / HEAVY BALL row of §10b |
| Rule source | pret (pokered, pokecrystal, pokegold where Gold differs); quirks reproduced, freezes never; twins line for line; a parity scenario per rule; a Lua↔JS fuzzer run |

## Scope

1. **The computer's choices** (row 1).
   - **Red:** TrainerAI (`engine/battle/trainer_ai.asm`) at the computer's slot in the move order, with its `Random` byte while `wAICount` > 0 (every trainer class, GenericAI included); EnemySendOut's party-order replacement.
   - **Gold:** AI_SwitchOrTryItem (`engine/battle/ai/items.asm`, `switch.asm`) at Battle_PlayerFirst / Battle_EnemyFirst; FindMonInOTPartyToSwitchIntoBattle for the replacement; **and AIChooseMove** (`engine/battle/ai/move.asm`, `scoring.asm`, `redundant.asm`), plus ParseEnemyAction's random pick for wild monsters.
   - Gold's moves are in scope because the referee picks them by the mod's heuristic today, for wild and trainer alike, which the docs wrongly say it does not (the known-gaps "Moves" bullet and the CHANGELOG "A wild POKéMON picks its move at random" line are Red-only truths).
   - A **human** seat that times out keeps the mod's heuristic (`_autoChoice`): that is the mod's rule for a player who did not answer, not a cart behaviour.
2. **Lines that depend on the viewer** (row 2): the Enemy / Wild prefixes, the cart's line breaks, and the link-battle run lines, per viewer.
3. **Faint timing** (row 3): a knockout's `faint` follows the move's tail (drain, recoil, Pay Day, Thief, rage, the hit count), where the cart's HandleEnemyMonFainted / HasEnemyFainted runs.
4. **Animations** (row 4):
   - Red: STATUS_AFFECTED_ANIM, XSTATITEM_ANIM, ABSORB from the seeder, TOSS_ANIM for a blocked ball.
   - Gold: the cart's ANIM_* status, residual and weather animations.
5. **LURE / HEAVY BALL** (§10b): the battle type and the species weight on the wire; LOVE BALL on a transformed wild monster reads the copied DVs.

Out of scope (each stays in the known-gaps doc): faint-check order in link battles, Gold battle types beyond carrying `battleType`, Crystal's HEAVY BALL dex-bank bug (needs ROM bytes from the wrong bank), the RNG.

## Contracts

### K16: the computer's trainer data on the NPC seat

These ride on the side-b NPC `BATTLE_PARTY` upload, like `aiMods` and `name`. The hubs copy them onto the NPC seats alone (Hub:fillBattleParty / tryStartSim, relay twin). The referee reads them from `fighter`.

**Red: `aiClass`.**
- Shape: the engine's `ai_classes` record for the trainer's class (`TrainerAI.classFor`: `trainer.aiClass or trainer.id`), copied field for field: `{ uses = 1..255, chance = 0..256?, switchChance = 0..256?, item = itemId?, switch = true?, onStatus = true?, hpBelow = 1..255?, switchBelow = 1..255? }`.
- The engine's table matches pret's `ai_pointers.asm` and the class routines row for row (checked at planning).
- A trainer with no record runs GenericAI: it still draws the byte every turn, `wAICount` 3, never spent.
- Unreadable present → refuse the party (K7's posture).

**Gold: four fields.**
- `trainerItems`: an ordered list of 0–2 item ids (wEnemyTrainerItem1, 2).
- `aiFlags`: TRNATTR_AI_MOVE_WEIGHTS, 0..65535.
- `itemSwitch`: TRNATTR_AI_ITEM_SWITCH, 0..65535.
- `baseReward`: TRNATTR_BASEMONEY, 0..255, for AI_TryItem's base-reward bug.
- The client reads the class's TrainerClassAttributes off the engine (`attributes[1..7]`).
- No fields on an NPC seat → no item, no switch, and AIChooseMove with no layers (flags 0).
- **One trainer, one kit (decided in wave 3):** seats handed the same `trainerItems` object — the hubs hand every NPC seat of one trainer the same one — share one copy of wEnemyTrainerItem1/2 and the base reward (`trainerKitOf`, `fighter.trainerKit`), as the old NPC bag was shared, so a co-op 2v2 against one trainer has the cart's two items. `aiFlags`, `itemSwitch`, `countSpeciesTypes` and Red's `aiClass` / `aiCount` stay per seat (wAICount reloads per send-out; Red's items are not consumed).

**Elsewhere:**
- The referee no longer reads an NPC seat's `bag` for the computer's choices on Red / Gold, keeps none for a computer seat, and refuses an item or a voluntary switch filed for one (`2b50a05` Red, `a179654` Gold): the computer's items and switches are its AI's alone. Forced replacements still go through `autoPick`.
- The client stops uploading an NPC bag on Red / Gold.
- **Solo fights (decided in wave 2):** on Red / Gold `SoloBrain` no longer answers the computer's move either. The referee now holds the carts' own move choice (Red: AIEnemyTrainerChooseMoves + SelectEnemyMove from `aiMods`; Gold: AIChooseMove from `aiFlags`), drawing at the carts' points, while the engine's Gen 2 port (`src/battle/gen2/Ai.lua`) departs from pret in layer order, rolls and filtering (W1-A2m §5), and either engine port draws from the client's RNG at the wrong point. So a solo NPC seat goes through the same `autoPick` path as a hub's NPC seat. The one exception is a mod-registered `brain` function on a Red trainer or class (the engine's ai_classes seam): `SoloBrain` still files that brain's move, so another mod's custom AI keeps working. This supersedes `docs/plans/offline-solo-battles.md` D3 for Red / Gold; D3's reason (a trainer plays like itself, not like a generic picker) is better served by the cart's own routine. Gen 3 is unchanged.

### K17: name marks in battle text

**The mark:**
- Where the cart prints a battler's name through a prefixing macro, the referee writes `^a` or `^b` (the monster's side) immediately before the name.
  - The macros: pokered `<USER>` / `<TARGET>` / PlaceMoveUsersName / PlaceMoveTargetsName, and `Enemy @` / `text_ram wEnemyMonNick` lines; pokecrystal `<USER>` / `<TARGET>` / `<ENEMY>` / PlaceBattlersName / PlaceEnemysName.
- Nothing is written where the cart prints a bare name, e.g. "Go! X!" or "<TRAINER> sent out X!".
- `^` is never a name glyph. Wire / sanitize strip it from every name field.

**What the client prints for a mark:**
- **Its own side:** nothing.
- **The other side, Red:** "Enemy " (wild or trainer, link included).
- **The other side, Gold:** "Enemy " in every mode. pokecrystal / pokegold PlaceBattlersName always places EnemyText ("Enemy @"); PlaceEnemysName tests wLinkMode / wTrainerClass and places a *trainer's* name, never a monster's. (The first draft of this contract said "Wild " in wild fights; W1-C found it wrong against `home/text.asm`, and the client follows the cart.)
- **Side-word marks (added in wave 2):** where the cart prints a *side* word rather than a battler name (pokecrystal HandleScreens' `.Your` / `.Enemy` strings before "#MON's\nLIGHT SCREEN fell!", and any other `Your@` / `Enemy@` pair the Gold referee's audit finds), the referee writes `^A` (side a) or `^B` (side b) immediately before the rest. The client renders it "Your " on its own side (a co-op partner's side counts as its own) and "Enemy " on the other; plain reading drops it. Wire / sanitize keep `^A` / `^B` exactly as they keep `^a` / `^b`.
- **Referee obligations:** a mark goes before a battler's name only (a mark before a trainer's name would render "Enemy <TRAINER>"); the `faint` event's text stays the bare species and the referee emits no "fainted!" line of its own (the client composes "Enemy X\nfainted!" / "X\nfainted!" per viewer); `run` events carry the runner's slot and side.

**Every line is read without its marks:**
- the client's line matchers (weather, Bide, Disable, item flags, escape, drag-out);
- the e2e drivers;
- every test that matches text.

### K18: the cart's line breaks

- A battle line may carry `\n` where the cart's text has `line` / `cont`. A `para` is a separate `msg`, as today.
- `Wire.battleText` keeps `\n` (a space next to it collapses; never leading, trailing or doubled). Gen 3's sanitising is unchanged.
- Battle event text is capped at `BATTLE_LINE_MAX = 80` glyphs, marks and breaks included. `Config.MESSAGE_MAX` stays 60 for chat.
- The client's pager honours an explicit `\n` (two rows a page). Without one it word-wraps, as today.

### K19: faint timing

A monster a move knocks out keeps its 0 HP on the field until the move has finished.

**Where its `faint` is emitted:**
- **Red:** where MainInBattleLoop's `ld a, b / and a / jp z, HandleEnemyMonFainted` runs, after ExecutePlayerMove / ExecuteEnemyMove returns.
- **Gold:** at HasEnemyFainted / HasPlayerFainted after the turn routine.

**What comes before it:** drain, recoil, the Pay Day line, Thief / Covet, the hit count, rage and Destiny Bond.

**What doesn't move:**
- Residual knockouts keep their current points.
- Explosion's user and Destiny Bond keep the cart's own order.
- The fixtures and every test that pins event order move with this.

### K20: the new animation ids

`anim` events whose `text` ends in `_ANIM` are cart animations, not moves.

- **Red:**
  - `STATUS_AFFECTED_ANIM`;
  - `XSTATITEM_ANIM` on the user's seat, for X items: the player's and the AI's;
  - `TOSS_ANIM` before "The trainer blocked the BALL!";
  - the move id `ABSORB` on the **seeder's** seat for a Leech Seed sap (HandlePoisonBurnLeechSeed's flipped hWhoseTurn).
- **Gold:** pokecrystal `ANIM_<X>` is sent as `<X>_ANIM`, with `_PLAYER_` variants where the cart has two. The full list is the Gold referee's report (W1-T2); the expected set is:
  - BRN, PSN, SAP, FRZ, PAR;
  - IN_LOVE, IN_SANDSTORM, IN_NIGHTMARE, IN_WHIRLPOOL, UNDER_CURSE;
  - MISS, ENEMY_STAT_DOWN, PLAYER_STAT_DOWN, HIT_CONFUSION.
- **Moves:** a move's own animation for a residual or weather beat (a trap's per-turn hit, a weather turn) is the move id.
- **Client:** every id has a look (Vfx / Battlefield). An unknown `_ANIM` id is skipped, as today.

### K22: quiet animations (added in wave 2)

- An `anim` event whose id is a move id but which is **not** the acting monster's own use of its move carries `quiet = true`: Leech Seed's residual ABSORB on the seeder's seat, a charge turn's TELEPORT (pokered ChargeEffect for FLY), a trap's per-turn hit, a weather turn's move animation, and any other residual / charge beat the referees send as a move id.
- Meaning: play the look only. No trainer callout bubble, no lunge. `_ANIM` ids are never callouts already.
- Optional boolean on `anim` in both referees' events FIELDS, read by Wire / sanitize on Gen 1 / 2 readers only.
- Also from wave 1's audit: the cart plays **no** move animation for a move that missed (pokered `handleIfPlayerMoveMissed`, EXPLODE_EFFECT excepted; pokecrystal BattleCommand_MoveAnim's `wAttackMissed` test), BLOCKBALL_ANIM follows TOSS_ANIM, and ChargeEffect / BideEffect play their own turn-1 animations (XSTATITEM_ANIM, TELEPORT for FLY, SLIDE_DOWN_ANIM for DIG).

### K23: Gold's slot-1 resist reading

- Gold's FindEnemyMonsThatResistPlayer starts at wOTPartyCount, so its first iteration reads the party **count** as a species number. The NPC `BATTLE_PARTY` gains `countSpeciesTypes`: the 1–2 type ids of the species whose national number is the party's size, stamped by the client on Gold (family `gs`) only. Crystal (fixed walk) ignores it.

### K21: LURE / HEAVY BALL fields

- **Gen 2 mon sheet:** gains `weight` (0..65535, the Pokédex weight word). The client stamps it on the wild foe, and on the player's own Gold sheets in wild / coop_wild fights (a TRANSFORMed wild monster is weighed as the species it copied), from the Gen 2 Pokédex entry.
- **Gen 2 ruleset:** gains `battleType` (0..255, the engine battle's own id). The hubs hand it to the referee's `opts.battleType`, which BattleSim2 already reads.

## Waves

File ownership is strict within a wave.

| Wave | Id | Owns | Delivers |
|---|---|---|---|
| 1 | T1 | `src/BattleSim/*` (existing files), `server/lib/battle/*` (existing), `tests/battle_sim_turn.lua`, `tests/battle_sim_effects.lua`, `tests/battle_sim_vectors.lua`, `server/battle_turn.test.js`, `server/battle_charge.test.js`, `server/battle.test.js`, `tests/drivers/battle_turn_parity.lua`, `tests/fixtures/battle_turn_parity.json` | K17 / K18 on every Red line, K19, K20 (Red, existing paths) |
| 1 | T2 | `src/BattleSim2/*` (existing), `server/lib/battle2/*` (existing), `tests/battle_sim2_turn.lua`, `tests/battle_sim2_vectors.lua`, `server/battle2_turn.test.js`, `server/battle2_vectors.test.js`, `tests/drivers/battle2_turn_parity.lua`, `tests/fixtures/battle2_turn_parity.json` | K17 / K18 on every Gold line, K19, K20 (Gold) |
| 1 | A2m | new `src/BattleSim2/AiMove.lua`, `server/lib/battle2/AiMove.js`, `tests/battle_sim2_ai_move.lua`, `server/battle2_ai_move.test.js` | AIChooseMove + every scoring layer + AI_Redundant, as a module over the referee's battle state |
| 1 | A2s | new `src/BattleSim2/AiSwitch.lua`, `server/lib/battle2/AiSwitch.js`, `tests/battle_sim2_ai_switch.lua`, `server/battle2_ai_switch.test.js` | AI_SwitchOrTryItem, CheckAbleToSwitch, AI_TryItem with every item routine's decision, FindMonInOTPartyToSwitchIntoBattle |
| 1 | W | `src/Wire.lua`, `server/lib/sanitize.js`, `src/Hub.lua`, `server/lib/relay.js`, `src/Config.lua`, `tests/rby_mmo_test.lua`, `server/twin_parity.test.js`, `server/hub.test.js`, `server/limits.test.js`, `tests/drivers/hub_protocol_parity.lua`, `server/hub_protocol_parity.test.js`, `tests/fixtures/hub_protocol_parity.json` | K16, K17 / K18 sanitising, K21, hub copies |
| 1 | C | `src/MediatedBattle.lua`, `src/CoopBattle.lua`, `src/SoloBattle.lua`, `src/SoloBrain.lua`, `src/ClassicBattle.lua`, `src/Battlefield.lua`, `src/Vfx.lua`, `src/Coop.lua`, `src/Sessions.lua`, `tests/mediated_battle_client.lua`, `tests/coop_mediated.lua`, `tests/solo_battle.lua`, `tests/solo_brain.lua` | K17 rendering, K18 paging, line matchers on unmarked text, link run lines, K20 looks, K16 / K21 stamping, SoloBrain answers moves only on Red / Gold, no NPC bag |
| 2 | FX | `tests/hub_battle.lua`, `server/hub_battle.test.js` + wave-1 cross-file expectation fixes | hub suites on the new event order and text |
| 2 | H1 | Gen 1 referee files (as T1) | TrainerAI at the slot (K16), EnemySendOut order, XSTATITEM_ANIM on the AI's X items, the AI's item lines |
| 2 | H2 | Gen 2 referee files (as T2) + A2m / A2s files | AIChooseMove / ParseEnemyAction wild pick / AI_SwitchOrTryItem / replacement hooked at the cart's points; LOVE BALL on a transformed foe |
| 3 | — | e2e drivers, docs | drivers on marked text; known-gaps, CHANGELOG, mod.card; full matrix |

## Verification

- Every Lua and Node suite green.
- The three parity fixtures regenerated and reproduced by both twins.
- Lua↔JS fuzzers with 0 mismatches on the changed referees; the stall drivers clean.
- The full e2e matrix, judged against the known pre-existing reds (`docs/plans/gen12-referee-gaps-fix.md`'s delivery notes).

## Delivery

### Commits

| Commit | What |
|---|---|
| `e69bfe2` | Red referee: K17–K20; Wire / hubs: K16, K18, K21; client: K17 rendering, K18 paging, link run lines, K20 looks, K16 / K21 stamping; Gold AiSwitch module |
| `1033bc2` | Gold AiMove module (AIChooseMove, every layer, AI_Smart, AI_Redundant, the wild pick) |
| `a7babc2` | Gold referee: K17–K20 |
| `f935871` | Wire / client: K22 quiet anims, `^A` / `^B`, K23, callouts on the used line |
| `2b50a05` | Red TrainerAI, EnemySendOut, charge / miss / blocked-ball anims |
| `9cdebb2` | Solo Red / Gold: the referee answers the computer |
| `700d22b` | e2e drivers on marked text and K16 |
| `9c80683` | Gold AIChooseMove / wild pick / AI_SwitchOrTryItem / replacement hooked; LOVE / HEAVY on a transformed foe |
| `18adc88` | Red per-hit anims, THRASH's square, side-effect shakes |
| `a179654` | Gold: computer files no item / switch; LAST_MOVE skips a called move (CheckUserIsCharging); a clip per multi-hit hit with wBattleAnimParam |
| `fbffada` | Gold: one trainer's kit shared across its seats; BEAT UP's clip per swing; TRIPLE KICK ×2/×3/×4 behind the user's own SUBSTITUTE |
| `bb24685` | Hub suites on K16 and marked text |
| `af92e62`, `c02cc95` | Docs; the Gold trainer-kit e2e check reads the shared kit |
| `c193e36` | Client: own Gold sheets' weight, Red follow-on shakes and link-fight shake mapping, traded EXP by OT id (co-op too) |

### Decisions taken during the run

- **Gold "Enemy", not "Wild".** The first K17 draft said Gold prints "Wild " before a wild monster; pret's PlaceBattlersName always places EnemyText. Corrected in K17.
- **Solo fights use the referee's computer on Red / Gold** (K16 "Elsewhere"), superseding `offline-solo-battles.md` D3 there.
- **K22 / K23 and the side-word marks** were added in wave 2 from wave 1's findings.
- **Faint suppression in a Red double KO** is left (known gaps §3): it differs per viewer.

### Engine-port divergences found (pret followed; for an upstream report)

- **Red (`src/battle/TrainerAI.lua`, `src/inventory/ItemEffects.lua`):** GenericAI draws no byte without a record; AI X items skip StatModifierUpEffect (no "Nothing happened!" at +6 / 999, the anim regardless); GUARD SPEC prints a line pret's AIUseGuardSpec doesn't; FULL HEAL / FULL RESTORE clear the toxic counter; UNUSED_JUGGLER falls to GenericAI; the AI item line's fallback drops "on <MON>"; ItemUseXStat has no XSTATITEM_ANIM and no 999 wall; no STATUS_AFFECTED_ANIM anywhere; FreezeBurnParalyzeEffect's row lacks the follow-on light shake.
- **Gold (`src/battle/gen2/Ai.lua`, `Battle.lua`, `src/ui/gen2/BattleState.lua`):** AIChooseMove's layers run per move in a different order, rolls are `random(100)` rather than bytes against `percent`, 0-PP and disabled moves are filtered, the final pick is "lowest, random tie", flags 0 is a random move, and AI_Basic / Types / Aggressive / Status / Risky / Opportunist / Cautious each differ in detail (pokegold variants only); switch scoring uses real matchups without the quarter-HP test, the immune arm or the ≥ 11 gate, with percent odds; item choice ignores the use flags, Full Heal clears confusion, X items do nothing, no base-reward bug; the replacement is the first healthy monster; HEAVY BALL reads `gen2Pokedex[species]` though the import nests entries under `.entries`; "Wild %s fainted!" where pret prints "Enemy @"; the new-#DEX line is unbroken; HitConfusion always animates; Selfdestruct doesn't reset the foe's DESTINY BOND.

### Verification (HEAD `c02cc95`)

- **Headless:** every Lua suite and every Node test file green (hub_battle 875/0, rby_mmo_test 6288/6288, battle_sim_turn 1564/0, battle_sim2_turn 1137/0, battle_sim2_ai_move 540/0, battle_sim2_ai_switch 247/0, mediated_battle_client 1730/1730, coop_mediated 1100/1100, solo_battle 551/0, solo_brain 84/0, Node battle_turn 422/0, battle2_turn 550/0, twin_parity 64/0, hub_protocol_parity 94/0); the three parity fixtures reproduced byte for byte; T4 and the server scripts' self-tests green; modkit lint / validate / pack show only the known MK301 / MK302 lines, gen2check only MK409 warnings on `"crystal"` family tests.
- **Lua↔JS fuzz, 0 mismatches:** Red 24.8k (T1) + 23k (H1) + 21k (H1b) battles; Gold 1.5k (T2) + 20k (H2) + 15k (H2 follow-up) + 10k (kit / BEAT UP / TRIPLE KICK) fights; AiMove 55k and AiSwitch 56k states; Wire↔sanitize 34k (W) + 84k (CL). Stall drivers clean on both referees, including 2v2 coop_npc against two Gold NPC seats.
- **e2e matrix:** Gen 3 (FireRed / Emerald MMO, trip, mismatch, solo, battlefield) all passed; Gen 2 MMO passed; Red solo GAPS:0; Gen 1 MMO and hub runs show only the known address-scrape (2 host) and registry-id (3 guest-b) reds; Gold solo shows only the known walk-sheet red. The Gold solo rules legs (obey, priority, held items, PAY DAY, trainer item, SLEEP TALK, level-up, weather, BATON PASS) all ran green on the cart AI.

