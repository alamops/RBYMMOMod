# Plan — Close every Red / Gold referee gap

| Field | Value |
| --- | --- |
| Date | 2026-10-03 |
| Source | "fix all" on `docs/plans/gen12-referee-known-gaps.md` (every row, §1–§14 and the client notes) |
| Config | AGENTS_CONFIG.yml (quality preset, host `claude_code`) |
| Flags | none |
| Gates | grilled (owner decisions below) + approved; scope widened by the owner after wave 1 |
| Branch | `feature/firered-and-emerald-support` (unpushed, 1.5.0, PROTOCOL 30 unreleased — no bump) |
| Base SHA | `24af23a` (plan); delivered in `e51c48d`..`17a802b` (six waves, polish, review fixes, e2e) |

**Rule source:** the carts in pret (`pokered`, `pokecrystal`, `pokegold` where it differs), quirks reproduced, freezes never, both twins line for line, a parity scenario per rule. Copies in `<scratchpad>/pret/`.

**Owner decision (grill):** cart rules that touch only the *player's* side apply to **both sides in a link fight** (1v1, coop_pvp), as each player's own cart shows it for their own mon. In fights against the computer, side a is the player. This covers `ClearHyperBeam` on a freeze and Red's turn-open flinch-reset skip, and changes today's link behaviour for the latter (it resets unconditionally).

**Scope widened by the owner after wave 1:** the Gold referee implements none of ~40 Gold-only move effects and has no weather. Wave 1 found this; the owner chose to **include it now** (the Gold track, waves 3–4 below).

**Found while grilling (no owner decision needed):**
- **Gold trainer items already ride the sheets.** The engine gives trainer mons their item (`src/world/gen2/Trainers.lua:87`), and `MediatedBattle.snapshotMons` stamps it (`:1141`). The 1.5.0 "Known" line saying otherwise is wrong. Gap #12 becomes: prove it (a test and an e2e leg) and correct the docs.
- **Mid-fight level-ups** reuse the existing `mmo.battle_moveset` message (K9). There's no new message type.
- **The co-op joiner's item** is validated against the joiner's own data: a species' wild item slots, or the named trainer's party item. The anti-forgery guard stays; the gap closes.

## 1. Objective & success criteria

Every row of `docs/plans/gen12-referee-known-gaps.md` is fixed, or shown to be already fixed, in both twins. Each fix has a parity scenario or vector, and every expectation that moves is listed. Specifically:

1. **Red (Gen 1) referee:**
   - **Transform:** switch-out restores species, types and moves; copied moves get 5 PP; crits read the copied species' base Speed; a transformed computer foe's crit stat is a CalcStat over the copied species with its own DVs (K7).
   - **Haze:** the full `HazeEffect_` (cures the target's status, clears confusion, X Accuracy, Mist, Focus Energy, Leech Seed, toxic and Disable on both sides; all four battlers in a 2v2).
   - **The computer's primary stat-down miss:** 25%, as its side-effect drops already have.
   - **`ClearHyperBeam`:** on a flinch, a freeze (player side; both sides in link), and a trap start.
   - **Self-hit behind a Substitute:** hits the opponent's Substitute.
   - **Item and switch turn slots:** the computer's item and switch follow pokered's turn order.
   - **Every smaller row in §7.**
   - **Pay Day** coins are reported (K11).
   - **The RNG** takes its high bits (K12).
2. **Gold (Gen 2) referee:**
   - **Transform:** undone on switch-out (types, moves, stats, confusion), with 5 PP on copied moves.
   - **Haze:** in a 2v2, all four battlers.
   - **Every row in §8**, including:
     - SLEEP TALK and SNORE as the cart's;
     - Bright Powder in the byte domain;
     - `HELD_PREVENT_*`, LOCK-ON and SAFEGUARD;
     - per-hit draws for multi-hit moves;
     - LEECH SEED at 1/8;
     - switch-in status-before-badge.
   - **Pay Day** with Amulet Coin.
   - **The Gold-native secondary-effect table (§13):** SP. DEF / ACCURACY down; ATTACK / DEFENSE / ALL up; FLAME WHEEL and SACRED FIRE; STOMP, TWISTER and SNORE flinch; THUNDER paralysis; TRI ATTACK with its reroll loop; `effectchance` drawn on a miss.
   - **Modded priority:** from the sheet (K8).
   - **The RNG** takes its high bits (K12).
3. **Client, wire and hubs:**
   - K7–K13 carried end to end.
   - Pay Day paid in fights against the computer only (×2 under Amulet Coin on Gold).
   - Level-ups sent mid-fight.
   - The Metronome pool covers all 251 Gold moves and excludes the cart's banned moves.
   - The co-op joiner keeps a validated item.
   - The Gold co-op target picker asks for every targeted status move.
   - PP Ups are capped at the cart's 7 per move.
   - `Sessions:beginWildMediated` rolls the wild item.
   - Lua's `Wire.id` refuses ids over 40 characters, as Node does.
4. **Gold move effects and weather (owner, after wave 1).** Every Gold `EFFECT_*` the referee maps to nothing gets the cart's implementation, in both twins, with a parity scenario each:
   - **Damage formulas:** RETURN and FRUSTRATION (happiness, K14), HIDDEN POWER (DVs, K7), FLAIL and REVERSAL, MAGNITUDE, PRESENT, TRIPLE KICK, FURY CUTTER, ROLLOUT, BEAT UP (the party's base Attack and level, K7), PURSUIT, FALSE SWIPE, FUTURE SIGHT, COUNTER and MIRROR COAT.
   - **Protection:** PROTECT, DETECT, ENDURE.
   - **Weather:** RAIN DANCE, SUNNY DAY, SANDSTORM, with their damage, accuracy (THUNDER), SOLARBEAM, MORNING SUN / SYNTHESIS / MOONLIGHT and sandstorm-damage rules.
   - **Status and field:** ATTRACT, BATON PASS, BELLY DRUM, CONVERSION2, CURSE, DESTINY BOND, ENCORE, FORESIGHT, HEAL BELL, MEAN LOOK / SPIDER WEB, NIGHTMARE, PAIN SPLIT, PERISH SONG, PSYCH UP, RAPID SPIN, SKETCH (written home in fights against the computer), SPIKES, SPITE, AMNESIA (SP. DEF +2), SWAGGER, TELEPORT.
   - **Output:** the referee's own `msg` lines in the cart's English (no new event kind), plus the existing `moves` / `status` / `stat` / `damage` events.
5. **The docs say so:**
   - `gen12-referee-known-gaps.md` is rewritten: every row resolved, or kept with the reason it can't be.
   - CHANGELOG 1.5.0 is updated, and the wrong "Gold trainers hold no items" line is corrected.
   - The plan ledgers are updated.
6. **Everything passes:**
   - All headless suites and both hubs.
   - The parity fixtures reproduce byte for byte.
   - Lua↔JS fuzzers show 0 mismatches.
   - The full e2e matrix shows only the known pre-existing failures.
   - New e2e legs cover Pay Day (Red, and Gold with Amulet Coin), a Gold trainer's held item, and SLEEP TALK.

## 2. Context (from the known-gaps doc and the grill)

- Both twins hold the rules today: `src/BattleSim/*` ↔ `server/lib/battle/*`, and `src/BattleSim2/*` ↔ `server/lib/battle2/*`.
- Gen 3 has its own RNG (`BattleSim3/Rng.lua` `roll`). The RNG fix is Red/Gold only, and no Gen 3 fixture moves.
- The referees emit `exp`, and the client works out levels. `mmo.battle_moveset` already carries mid-fight move changes from the client to the referee (`MediatedBattle.lua:1265`).
- Pay Day precedent: `BattleSim3` reports `outcome().payDay` (side a's coins, fights against the computer only), and `MediatedBattle:payDay3` pays it.
- The Metronome pool cap is 200 (`Config.lua:706` ↔ `sanitize.js:595`); Gold has 251 moves. Check the wire size with the Node preload probe before raising it.
- `Sessions:beginWildMediated` has no `src` caller, but it is a tested API (`tests/mediated_battle_client.lua:922`), so it is fixed rather than deleted.

## 3. Contracts (wave 1 lands them; every agent codes against them)

- **K7 (Gen 1/2 mon sheet):**
  - `base = { hp, atk, def, spd, spc }` (Gen 2: `spa`, `spd` split, as `stats`) — the species' base stats;
  - `dvs = { atk, def, spd, spc }` (Gold's four DVs);
  - `statExp` (five values, optional).
  - The client fills these from the engine mon and species data on every sheet it builds. Wire and sanitize accept them in the Gen 1/2 dialect with the same bounds as `stats`, and `copyMon` keeps them.
  - Used for: the Transform crit stat (`GetEnemyMonStat`), the copied species' crit base Speed, and level-up rebuilds when the client sends no stats.
- **K8 (Gen 1/2 move sheet):**
  - `ppUps` (0..3), from the PP-Up bits the engine keeps.
  - Gold only: `priority` (the cart's raw `GetMovePriority` number, 0..255), from the move's effect via pokecrystal's table. A modded move's own field wins.
  - The referee uses the sheet's `priority` before its move-id table.
- **K9 (`mmo.battle_moveset`):** gains `level` and `stats` (the client's new stats after a mid-fight level-up) next to the moves. The referee rebuilds the battle stats exactly as the cart does after a level-up in battle.
- **K10 (Gen 1/2 `stat` event):** gains a signed `stage` (−6..6), so a negative stage is no longer stripped. `twin_parity` pins it.
- **K11 (Gen 1/2 outcome):** `payDay` (coins, ≥ 0) on a won fight against the computer, side a only. The client pays it in KEEPS_HELD_MODES; Gold doubles it under `amuletCoin2()`.
- **K12 (Gen 1/2 RNG):** `below(n)` and `nextInt` take the high bits (`floor(next() / 65536) % n`, or a multiply-shift; the agent picks the one exact in both twins). This moves every Red/Gold fixture, and the run regenerates them once in wave 1.
- **K14 (Gold mon sheet, added after wave 1):** `happiness` 0..255, from the engine mon. RETURN and FRUSTRATION read it. Wire and sanitize accept it in the Gen 2 dialect only; `copyMon` keeps it.
- **K13 (wire hygiene):**
  - Lua `Wire.id` refuses an id over 40 characters (Node's `cleanId`), with the hub parity fixture extended.
  - `BATTLE_METRONOME_POOL_MAX` rises to cover 251 moves, on both twins, after a measured wire-size check.

## 4. Work breakdown — implementation tasks

| ID | Wave | Owns (exclusive) | Goal |
|---|---|---|---|
| W | 1 | `src/Wire.lua`, `server/lib/sanitize.js`, `src/Config.lua`, `src/Hub.lua`, `server/lib/relay.js`, `server/twin_parity.test.js`, `tests/drivers/hub_protocol_parity.lua`, `server/hub_protocol_parity.test.js`, `tests/fixtures/hub_protocol_parity.json`, `tests/hub_battle.lua`, `server/hub_battle.test.js` | K7–K11 accepted in the Gen 1/2 dialect (refused elsewhere); K9 relayed to the referee by both hubs; K11 on the outcome; K13; parity scenarios |
| R1a | 1 | `src/BattleSim/*`, `server/lib/battle/*`, Gen 1 tests, fixtures and drivers | RNG high bits (K12, regenerate the fixtures first); damage tails (no roll at 0/1, 0.25× → 0 is a miss, a Substitute at exactly its HP survives at 0); AlwaysHappenSideEffects order and its cancellation by a broken Substitute (EXPLOSION user survives, RAGE not started); drain / recoil / Pay Day / recharge against a holding Substitute; 2–5 hit distribution and draw timing; EFFECT_1E; Pay Day coins (K11); COUNTER's damage rule; RAGE / THRASH PP and RAGE's lines; METRONOME / MIRROR MOVE-called multi-turn moves; LEECH SEED × TOXIC and the faint feed; self-hit behind a Substitute; self-hit clears BattleStatus1 |
| R2a | 1 | `src/BattleSim2/*`, `server/lib/battle2/*`, Gen 2 tests, fixtures and drivers | RNG high bits (K12); the Gold-native secondary-effect table (§13, TRI ATTACK, `effectchance` on a miss); per-hit draws for multi-hit moves; LEECH SEED 1/8 and the knockout heal; no 999 cap after STAB / RAGE; wrap lets the target attack; recoil into a Substitute; THRASH / RAGE at 0 PP; MIRROR MOVE's last move used; METRONOME-called charge moves; Pay Day coins (K11) |
| C | 2 | `src/MediatedBattle.lua`, `src/CoopBattle.lua`, `src/SoloBattle.lua`, `src/Coop.lua`, `src/Sessions.lua`, `src/Exp2.lua`, `tests/mediated_battle_client.lua`, `tests/coop_mediated.lua`, `tests/solo_battle.lua`, `tests/rby_mmo_test.lua` | K7 / K8 stamped; K9 sent on a mid-fight level-up (Gen 1 and Gold, own seats); K10 read where the screen shows stages; K11 paid (fights against the computer, own side, Amulet Coin on Gold); Metronome pool exclusions and the full Gold pool; co-op joiner item validation; Gold co-op target picker; PP Up cap; `beginWildMediated` wild item; Gold trainer item proven by a test |
| R1b | 2 | Gen 1 referee files and tests (as R1a) | Transform (K7); full Haze, all four in a 2v2; the computer's primary stat-down miss; ClearHyperBeam on flinch / freeze / trap with the owner's link rule, and the flinch-skip link rule; the computer's item / switch turn slot; asleep or frozen selects last turn's move; PP Ups in `.chooseMove` (K8); toxic outlives a nap; primary ±6 "Nothing happened!"; DISABLE (random slot with PP, 1–8 turns, "But it failed!"); primary POISON vs a Poison type; a primary drop into MIST misses before the accuracy byte; signed `stat` stage (K10); level-up rebuild (K9) |
| R2b | 2 | Gen 2 referee files and tests (as R2a) | Transform; Haze in a 2v2; switch-in status-before-badge; SLEEP TALK and SNORE; MYSTERYBERRY scans the party moves under Transform; a replacement gets that turn's between-turn items; forced-skip seats roll QUICK CLAW; Bright Powder in the byte domain, OHKO included; `HELD_PREVENT_*`; LOCK-ON and SAFEGUARD; primary stat-down lines; modded priority (K8); signed `stat` stage (K10); level-up rebuild (K9) |
| W2 | 2 | `src/Wire.lua`, `server/lib/sanitize.js`, `src/Hub.lua`, `server/lib/relay.js`, `server/twin_parity.test.js`, hub parity driver / fixture / Node twin, `tests/hub_battle.lua`, `server/hub_battle.test.js` | K14; `Wire.mapId` refuses past 64 like Node (K13's twin); a Gen 1 `run` outcome carries `payDay` (Red pays on a flee) |
| R2c | 3 | Gold referee files and tests | Gold move effects, part 1: the damage formulas, protection, COUNTER / MIRROR COAT, FUTURE SIGHT, PURSUIT, and weather |
| R2d | 4 | Gold referee files and tests | Gold move effects, part 2: the status and field effects, SKETCH included |
| C2 | 4 | client files (as C) | SKETCH written home (fights against the computer, own seats), plus any client follow-ups from waves 2–3 |
| D | 5 (me) | `CHANGELOG.md`, `README.md`, `mod.card`, `docs/plans/*`, referee header notes | Docs per §1 item 4 |

## 5. Tests

- **TT-R (inside R1a, R1b, R2a and R2b):**
  - parity scenarios and vectors per rule, hand-checked against pret;
  - a Lua↔JS fuzzer run (`$SP/review-rf/R1`, `$SP/FX2/fz`, `$SP/review-rf/R4/gen4.py`): 0 mismatches.
- **TT-C (inside W and C):** wire acceptance and refusal per dialect; hub pass-through; client stamping and payouts per mode.
- **TT-E (after wave 2, run from the main session):** new `run-solo-battle-e2e.sh` legs:
  - Pay Day, on Red and on Gold (with Amulet Coin);
  - a Gold trainer holding an item (the sheet carries it, and THIEF can take it);
  - SLEEP TALK;
  - a mid-fight level-up whose stats reach the referee.

  The existing legs are re-run, and the full matrix runs through `final_run.sh`.

## 6. Waves

1. **Wave 1:** W ∥ R1a ∥ R2a. Then a barrier and a commit (`e51c48d`).
2. **Wave 2:** C ∥ R1b ∥ R2b ∥ W2. Then a barrier and a commit.
3. **Wave 3:** R2c. Then a barrier and a commit.
4. **Wave 4:** R2d ∥ C2. Then a barrier and a commit.
5. **Wave 5:** D.

After that: review (Gen 1 referee, Gen 2 referee, client/wire), fixes, TT-E, the full matrix, and fixes again.

## 7. Blast radius & risks

- **K12 changes the RNG stream of every Red/Gold fight.** Seeds are random in play, so nobody can see it. Every fixture is regenerated once, in wave 1, by R1a and R2a, before any other rule changes, so later diffs stay readable. e2e legs that pinned seeds re-scan them.
- **Several rules add or remove draws:**
  - the 0/1 roll skip;
  - the computer's primary miss;
  - DISABLE;
  - the per-hit multi-hit draws;
  - `effectchance` on a miss;
  - TRI ATTACK's reroll loop.

  Each one lists the expectations it moves.
- **Wire growth:**
  - **K7** adds roughly 15 numbers per mon.
  - **The Metronome pool** goes from 200 to 251 rows.

  Both are measured with the Node preload probe against the hub's line limit before landing.
- **The link-quirk decision** changes Red link fights' flinch reset on a raging or recharging mon (intended, owner).
- **Gen 3 is untouched.** No BattleSim3 file moves, and every gen3_* suite plus the Gen 3 e2e must stay green.

## 8. Open questions / assumptions

- **K7's `statExp`** is optional. A foe the client describes from the engine (a wild or trainer mon) has engine stat exp. Where none exists, the cart's computer uses 0 (`GetEnemyMonStat`), and so does the referee.
- **The Gold priority table for K8** comes from pokecrystal's `MoveEffectPriorities`, plus VITAL THROW by id. A modded effect not in it gets the base priority unless its move record states `priority`.

## 9. Completeness ledger

| Candidate | Disposition |
|---|---|
| Every row of `gen12-referee-known-gaps.md` §1–§14 and the client notes | **in this run** (owner: "fix all"), per the task map in §4 |
| Gold trainers hold no items (§12) | **already fixed** by 1.5.0 wave 2; proven in this run (C test, TT-E leg); docs corrected |
| The link-fight player-only quirks | **owner decision**: both sides |
| Engine-port divergences from pret (plan `gen12-referee-fidelity.md` §10) | **out of scope**: the engine's own code; an upstream report, not a mod change |
| Gen 3 "Wild PIDGEY used THIEF!" prefix (TT-E observation, unverified) | **out of scope**: Gen 3 text, not a Red/Gold referee gap; noted for a Gen 3 ticket |
| ~40 Gold-only move effects and weather the referee never implemented (found in wave 1) | **in this run** (owner): R2c, R2d, C2, K14 |
| Red cart differences found in wave 1 (JUMP KICK's 1-HP crash; fixed-damage moves ignore immunity and draw no crit or roll; OHKO on a Speed tie; confusion before paralysis; full paralysis vs FLY; trap before the hit; MIRROR MOVE after a called move; BIDE on wDamage; Pay Day on a flee; power-0 multi-hit; effect-less moves vs a vanished target; the "Hit N times!" line) | **in this run**: R1b, W2, C |
| Gold differences found in wave 1 (the freeze thaw point; DRAIN / DREAM EATER misses and SapHealth's minimum; TOXIC; LEECH SEED vs Grass; the 999 stat-up failure for primaries; a storing BIDE vs CantMove; MIRROR MOVE's failure line; the "Hit N times!" line) | **in this run**: R2b |
| THUNDER's rain / sun accuracy | **in this run**: R2c (with weather) |
| Co-op Pay Day: the referee reports one pot | **decision (owner's link-quirk rule applied)**: every human seat on side a is paid the pot, as each player's own cart would pay its player |
| Cart differences found in waves 1–5 beyond the original backlog (about a hundred rows across both referees, the wire and the client) | **in this run**: routed into the next wave each time (R1b–R1e, R2b–R2e, C, C2a, C2b, C3, C4, W2–W5) |
| Differences found after wave 5 | **out of scope by run policy** (the owner's "fix all" was bounded at the start of wave 5: later findings go to the known-gaps doc unless review marks them must-fix); listed in `docs/plans/gen12-referee-known-gaps.md` |

## 10. Engine-port divergences found in this run

These are differences in Gen1Recomp's own battle code from pret, recorded for an upstream report. The mod's referees follow pret.

**Gen 1 (`src/battle/`, `src/pokemon/`, `src/core/`, `src/inventory/`, `src/ui/`):**
- **Max PP:** computed uncapped (`base + ups·floor(base/5)`) in `Pokemon.lua:98`, `BattleState.lua:6919`, `WideBattle.lua:255`, `BattleAPI.lua:121`, `ui/SummaryMenu.lua:234`, `inventory/ItemEffects.lua:383` and `core/SaveData.lua:2755`. pokered `AddBonusPP` caps each PP Up's bonus at 7.
- **Draw order:**
  - `EffectRegistry.runDamaging` draws accuracy before crit and damage; pokered draws crit and the roll before `MoveHitTest`.
  - `BattleState` (~4404-4416) runs the accuracy roll before a status move's own turn-aways.
- **Confusion:** `Status.lua:370-371`'s self-hit side is inverted (the comment says ≥128, the code hurts on <128).
- **Trainer AI:** `TrainerAI.lua:276-321` picks uniformly; pret maps one byte at 63/127/190. It also excludes 0-PP moves (`SelectEnemyMove` never reads PP), and its layer 2 counts selections, not executed turns.
- **Multi-hit vs a doll:** `EffectRegistry.lua:313` stops a multi-hit move at a doll broken on any hit; pret stops only on hit 1. It also prints "Hit the enemy N times!" after a knockout.
- **Side effects:** `MoveEffects.lua` `statusSide` thaws before the Substitute check and draws before its own checks; `CONFUSION_SIDE_EFFECT` skips the draw on a confused target; `TWINEEDLE_EFFECT` skips PoisonEffect's checks.
- **Fixed damage:** JUMP KICK's crash is floor(maxHp/8) (pret: 1 HP, wDamage=0); the FIXED_DAMAGE tables differ; SEISMIC TOSS / SONICBOOM's power-1 records dealt 1 HP to the old referee.

**Gold (`src/battle/gen2/`, `src/world/gen2/`):**
- **Freeze:** `Battle.lua:61-62,3268` thaws 1-in-5 when the mon tries to move; pokecrystal thaws 10% between turns in `HandleDefrost`.
- **Accuracy:** `Damage.lua:339` `rollHit` works in a percent domain (clamped 1..100, `random(100)`); the cart works on bytes and draws nothing at 255.
- **Gender:** `Mon.lua:613-620` `vanillaGender` compares the Attack DV alone with floor(ratio/16); pokecrystal `GetGender` combines the Attack and Speed nybbles and special-cases F0 / F100 / UNKNOWN.
- **ForceSwitch:** the trainer branch (~2933) sets `forcedSwitch`, skipping the between-turn effects (pret sets it only in the wild arm), and picks uniformly instead of the `& 7` reject loop.
- **Baton Pass:** (~2660) prints "%s passed the baton!", a line pret doesn't have, and passes to the first living member.
- **Curse:** the can't-raise line reads "ATTACK" where pret prints "ABILITY".
- **Time of day:** `BattleState.startEvolutions` / `Game2:729` call `Palettes.clockDaytime()` with no hour, reading the host clock without the save's RTC base (the engine's own comment says callers should pass the hour).
- **Catching:** `src/battle/gen2/Catching.lua` keeps the HP step and status bonus for the Level Ball, catches only on `roll < rate` (the cart also catches on equal), floors the ball rate at 1 before the HP step, doesn't wrap B−C to a byte or take the quotient's low byte, and avoids the cart's divide hang with a floor on the tripled max HP.
- **Red items:** `src/inventory/ItemEffects.lua:383-385` restores PP only when `pp < maxPP`, so it never brings a wrapped 63 back down and has no MAX ETHER whole-byte compare.
- **Evolution after a loss:** `src/battle/BattleState.lua:5743-5748` (`finish`) runs `Evolution.checkParty` whatever the result; pokered `EndOfBattle` skips it whenever `wBattleResult` ≠ 0.
