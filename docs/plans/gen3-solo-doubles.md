# Plan — Gen 3 solo double battles

| Field | Value |
| --- | --- |
| Date | 2026-10-01 |
| Source | "do it" on gap #2 of `docs/plans/gen3-known-gaps.md` (lone doubles, the cheapest solo take-over) |
| Config | AGENTS_CONFIG.yml (quality preset, host `claude_code`) |
| Flags | none |
| Gates | grilled + approved by owner |
| Branch | `feature/firered-and-emerald-support` (unpushed, 1.5.0) |
| Base SHA | `229da2b` (the plan + known-gaps commit on top of `78e695a`; review diffs against it) |

## 1. Objective & success criteria

SOLO BATTLES takes over every **lone** Gen 3 trainer double battle on FireRed,
LeafGreen and Emerald, instead of handing it back to the cart. A lone double is
one trainer (one party, one AI, one defeat flag) with the double flag; the player
fights it with two monsters out from one shared team.

Done means:
- A lone double is fought on the mod's referee in both UIs: the arena, and a
  **GBA-native double screen** on the classic UI (two monsters a side at the
  cart's positions, two healthboxes a side, the targeted monster blinking).
- **Shared team, as on the cart.** Either slot can switch in any bench monster.
  A fainted slot is refilled from the whole bench. When only one monster
  remains, only one slot is filled. The same holds for the trainer's side.
- **Two commands a turn**, mon 1 then mon 2. B on mon 2's command menu goes
  back to mon 1's choice.
- **Targets.** You aim single-target moves at either foe or your partner, and
  only get asked when more than one other battler stands. Spread moves follow
  the referee's existing Gen 3 rules.
- **Trainer AI follows the carts.** FireRed/LeafGreen pick a random target;
  Emerald scores each target. The DOUBLE_BATTLE AI script runs when the cart
  would run it. The AI never sends out a monster that is already out or
  already claimed.
- **Cart-faithful ending:** prize ×2, EXP split per participant, Pay Day,
  Amulet Coin, the defeat flag, the beaten script (types 4/6/8, so Tate & Liza's
  badge too), whiteout, a draw that halts the script, learn-move and evolution
  prompts, Emerald TV with the second monster.
- **Fewer than two usable monsters** (non-egg, HP > 0): the fight is handed back
  to the cart, which refuses as it does today.
- **Still refused:** two trainers at once (`twoOpponents`) and Steven
  (`partner`).
- **Nothing else changes:** 1v1 solo, co-op (Gen 1/2/3), the hubs and every
  existing referee scenario stay byte-identical.
- **Verified:** headless suites green, Lua↔Node parity green, and e2e on
  FireRed + Emerald, arena and classic, with screenshots.

## 2. Context & constraints (Phase 1 findings)

**Divert and solo entry**
- `CoopField.divertStart` (`src/CoopField.lua:1420`) wraps `BattleBridge.start`.
- `trainerStand3` (`:1331`) sets `stand.double` (`:1349`).
- `Client.lua:2683 offerFight3` offers co-op, then calls
  `solo:fromGen3Trainer` (`SoloBattle.lua:2352`).
- `gen3Double` (`:1861`) declines doubles at `:2369`. It declines them for
  **all three carts**; the docs saying "Emerald" were wrong.
- The engine gates doubles on two usable monsters: `battle_bridge.lua:384`
  `monsStateToDoubles`; `ops_a.lua:1576-1605` prints "not enough mons" and
  halts.

**The referee** (`src/BattleSim3/Turn.lua` ↔ `server/lib/battle3/Turn.js`)
- A fighter is one seat: `playerId`, one `mons`, one `active`, one `b`
  (`Turn.lua:474`). `byId` is unique (`:468`). Battler order is a1 b1 a2 b2
  (`:484`). `self.double` is set at `:492`. Field slots are a 0..2 and
  b 3..5.
- Doubles mechanics already exist in both twins:
  - Spread: damage is halved for `BOTH` only when two stand
    (`Move.lua:934`, `Damage.lua:329/350`; the engine port agrees,
    `battle/effects/hit.lua:169`).
  - Follow Me, Lightning Rod, Helping Hand.
  - Retargeting (`_pickTarget`, `Move.lua:681`).
  - Doubled screens; Pressure; Intimidate on all foes; Heal Bell on the
    partner.
  - Six-battler speed order and residual order.
- `choice.target` is a field slot and may name the ally (`Turn.lua:757-778`).
- Replacement: `_faintBattler` (`:1861`) → `_openReplace` (`:1111`), one
  `turn{slot}` per owing seat → `_closeReplace` (`:1128`).
- **No shared bench exists.** `benchOf` (`Move.lua:475`) excludes only its own
  `active`. Co-op deals a trainer's party round-robin across NPC seats
  (`Hub.lua:1594-1640`).
- EXP is per field slot. `_awardExp` (`:1801`) is double-correct for separate
  parties. It would double-count one monster that fought from both seats of a
  shared team.

**Solo** (`src/SoloBattle.lua`)
- `_begin3` (`:2400`) builds `MediatedBattle` with a local table transport
  (`_transport`, `:748`). That transport catches `BATTLE_RULESET`,
  `BATTLE_PARTY` (side nil = player, side b = trainer kit) and `BATTLE_CHOICE`
  (→ `_choose` → `_submit3` → `sim:submitChoice(PLAYER_SEAT, …)`).
- It seats one fighter per side (`:2465-2494`) and calls
  `fight:onReady{sides={a={PLAYER_SEAT}, b={FOE_SEAT}}}`.
- The screen contract solo uses is narrow: `start(game)`, `onReady`,
  `onEvent`, `onOutcome`, the `onDone(result,toLearn)` field, `evoResolved`,
  `cachedMusicKind`.
- Single-seat assumptions to change:
  - `_answerFoe` (`:1251`), and the brain gets one `view.foe`.
  - `_onSend3`, `_applyMoveset3`, `_cantEscapeText3`, `_spendTurn`,
    `_trackPlayer`.
  - `_settle3` (`:2747`), `_reconcile3` (`:2879`), `endMon3` (`:2937`),
    `_ended3` (`:2958`).
  - `_finishEffects3` (`:3096`): `playerMon2Species = 0`.
  - `_trainerWon3` (`:2810`): hard-coded `double = false` at `:2825`/`:2840`.
  - `gen3TrainerRecord` (`:2117`) lacks `doubleBattle`.

**AI** (`src/SoloBrain.lua`)
- `_decideGen3` (`:1523`) is 1v1, with no target.
- `_bench3` (`:1562`) and `_replacement3` (`:1748`) exclude only the own
  active.
- The `DOUBLE_BATTLE` flag (`:1202`) is never read.
- Engine reference (`battle/ai.lua`):
  - FRLG: a random target, `Random() & 2`, flipped if absent (`:317-333`).
  - Emerald: `Ai.chooseDoubles` scores each target (`:290`, `:403`).
  - Emerald ORs DOUBLE_BATTLE in for doubles (`:472`).

**Screens**
- `MediatedBattle` is strictly 1v1: about 130 own-slot sites, and target
  picking is dormant.
- `CoopBattle` is slot-indexed two-a-side, with:
  - target pickers in both UIs: `needsTarget3` `:11571`, `targetChoices`
    `:2761`, `updateTarget` `:2768`;
  - per-seat replacement pickers: `updateReplace` `:2486`;
  - the Gen 3 replay arms;
  - the one-trainer-behind-two-mons arena shape: `battlefieldFoeHumans`
    `:6271`; `Battlefield` unpaired branch `:1407-1428`.
- `mine` is one slot (`:1571`). `benchOf` (`:2468`) excludes only the slot's
  own active. `gainExp` is gated on `self.mine` (`:8350`).
- The mediated path is `onBattleReady`/`medMap` (`:9856-9910`), `medRows`,
  `sendMediatedChoice` (`:10732`) and `uploadMediated` (`:9746`).
- `ClassicBattle` Gen 3 is singles only (`G3` `:860-884`, `drawGen3` `:1742`).
  Co-op classic uses the "guild focus" strips (`gen3ClassicModel`,
  `CoopBattle.lua:12287`).
- The engine's doubles layout:
  - pics at `AnimCoords.DOUBLES` (`anim_coords.lua:9`): ally (32,80) (90,88),
    foe (200,40) (152,32);
  - healthbox centres at `healthbox.lua:19-29`;
  - `BattleChrome.drawDoublesBox` (`battle_chrome.lua:243`);
  - target blink at `ui.lua:1051`/`:1325`;
  - partner cancel at `battle/init.lua:2875`/`:2910`.

**Test fixtures**
- `gen3_solo.lua` `TRAINERS[902]` is already a two-mon double row (`:378`).
- `:1116` asserts the hand-back, and must flip.
- `:1087-1088` and `solo_battle.lua:1322` assert the `gen3Double` statics.

**e2e**
- `tests/drivers/solo_battle_e2e.lua` `runGen3` calls
  `solo:fromGen3Trainer(game,id,…)` directly. Its trainer scans skip double
  rows (`:288`, `:924`).
- Real-flow legs use `H.g3Teleport` + `H.g3SightApproach` + `U.hold`.
- Shots are `g3-<fr|em>-solo-NN-<leg>.png`.
- Lone doubles to use:
  - FireRed: **#484 TWINS ELI & ANNE**, CLEFAIRY + JIGGLYPUFF L22,
    `FR_ROUTE_8` lids 12/13.
  - Emerald: **#483 TWINS GINA & MIA**, SEEDOT + LOTAD L6, `EM_ROUTE104`
    lids 23/24, trainerbattle type 4.
  - The driver picks by scanning `Trainers.pack()`; it never hard-codes a ROM
    value it asserts on.

**Release:** 1.5.0 is unreleased, so no version bump. No PROTOCOL bump: solo is
local, and nothing new crosses the wire.

## 3. Approach & key decisions

1. **A shared-team seat model in the referee (owner decision), both twins.**
   - A side entry may say `seats = 2`. `create` expands it into two fighters
     that **share one `mons` table and one bag**:
     - seat 1 keeps `playerId`; seat 2 is `playerId .. "#2"`;
     - both carry `owner = playerId`.
   - Choices are addressed by the seat's own id, so there is no new choice
     field and no `Wire`/`sanitize` change.
   - One-seat entries keep every current code path, so existing parity
     scenarios are byte-identical.
   - Rejected: splitting the team per seat (unfaithful; owner said no), and a
     `choice.seat` field (it would leak into `Wire.battleChoice`).
2. **The screen is `CoopBattle` with `ownSlots`** (both side-a slots owned by
   this client, one shared party), constructed for solo behind the same narrow
   contract `MediatedBattle` serves. `ownSlots == nil` keeps every co-op path
   unchanged.
   - Rejected: generalising `MediatedBattle` (about 130 single-slot sites, and
     risk to every 1v1); a new screen (it would re-import thousands of lines
     of replay code).
3. **The classic UI gets a real GBA double layout** in `ClassicBattle` (owner
   decision). It is fed by a new `view.double` model from `CoopBattle`, and
   co-op keeps its focus strips.
4. **The AI follows the carts** (owner decision): the per-family target rule,
   the DOUBLE_BATTLE script when on, and claim-aware switching and
   replacement.
5. **Two commands a turn, each filed at choice time** (reversed after review;
   it first buffered mon 1 until mon 2 confirmed). The cart checks each
   battler's action as it is chosen (`HandleTurnActionSelectionState`): a
   Disabled / Taunted / Tormented / sealed / Choice-locked move, a medicine
   that would do nothing, a trapped switch is refused there with its line and
   that battler's menu stays up; the next battler is asked only once it has an
   action. Buffering let those refusals arrive after mon 2 had chosen, where
   both were dropped and mon 1 reopened with no line (a POTION on a full-HP
   mon 1 looped forever). So each command goes to the referee the moment it is
   confirmed; a refusal keeps that seat's menu with the cart's line (SoloBattle
   words it, `refusalText3`, and hands it back on the transport); B on mon 2's
   command menu sends the referee's `cancel` for mon 1, which unfiles the
   choice and releases its claim, and reopens mon 1 (still refused after a
   non-ball item, as on the cart). Mon 2's bench and bag leave out what mon 1
   filed, as the referee does.
6. **Fewer than two usable monsters means hand back**, mirroring
   `monsStateToDoubles`. `trainerIdB`/`twoOpponents`/`partner` stay refused.
7. **Spread damage stays as the referee has it.** Only `BOTH` is halved in Gen 3
   (pret `CalculateBaseDamage` checks `MOVE_TARGET_BOTH`). Earthquake and Surf
   are not halved. This rests on reasoning plus the engine port's agreement,
   not a spike (§8).

### Contracts the parallel tasks build against

**C1 — referee sides (T1 provides, T3 consumes)**
```lua
sides = {
  a = { { playerId = "solo_player", seats = 2, name, mons, bag, badges } },
  b = { { playerId = "solo_foe", seats = 2 --[[1 if the trainer has one mon]], name, mons, bag } },
}
-- seat ids: "solo_player", "solo_player#2", "solo_foe", "solo_foe#2"
-- field slots: a 0,1  b 3,4 (Events.fieldSlot); each fighter has .owner
sim:submitChoice("solo_player#2", { action = "fight", move = 0, target = 3 })
sim:fighter(id) / sim.byId[id]   -- seat fighters; .owner on both
```
- **Leads:** seat 1 gets the first usable monster; seat 2 the next usable one;
  with none left, seat 2 starts empty.
- **Bench:** every living monster except both seats' actives and any monster
  the sibling seat has a pending switch or replace into.
- **EXP:** deduplicated per owner+monster. The `exp` event's `slot` is the
  slot of the seat the monster is on, or the owner's first seat's slot when
  benched; `mon` is the party index.
- **Outcomes:** `winners`/`losers`/`waiting` list owners, deduplicated.

**C2 — brain view (T3 builds, T2 consumes).** On top of today's view, for a
double:
```lua
view.double = true
view.seat = <field slot of the choosing foe seat>
view.partner = <the foe side's other battler or nil>
view.foes = { { slot = 0, battler = ... }, { slot = 1, battler = ... } }  -- living player battlers
view.claimed = { [partyIndex] = true }   -- the sibling's pending switch/replace this turn
-- returns { action="fight", move=i, target=slot? } | { action="switch", index=k } | { action="item", ... }
-- brain:replacement(view) honours view.claimed and both actives
```
The 1v1 view and returns are unchanged when `view.double` is nil.

**C3 — solo screen (T4 provides, T3 consumes).**
```lua
CoopBattle.newSoloDouble(game, {
  transport, ui, battle = battleId, trainer, npcParty = enemySheets,
  mode = "coop_npc", selfId = "solo_player", foeId = "solo_foe",
  foeSeats = 1|2, onDone = function(result, toLearn) end,
})
```
- It exposes `start(game)`, which sends `BATTLE_RULESET`, `BATTLE_PARTY`
  (side nil: `{mons, bag}`) and `BATTLE_PARTY` (side `"b"`: the trainer kit
  with `bag`), exactly as `MediatedBattle:start` does.
- It also exposes `onReady(msg)`, `onEvent(event)`, `onOutcome(outcome)`, and
  the fields `onDone`, `evoResolved`, `cachedMusicKind` and `battle`.
- Choices go out as `BATTLE_CHOICE` with an extra local field
  `seat = <field slot>`. T3's `_choose` maps 0→`solo_player`,
  1→`solo_player#2`.
- Each choice is filed at choice time (decision 5): the table transport
  answers the referee's verdict synchronously, and on a refusal sets
  `transport.refusal` to the cart's line for it (the screen clears it before
  each choice and says it, keeping that seat's menu). Partner cancel is
  `{ action = "cancel", seat = <mon 1's field slot> }`, the referee's own.
- A re-armed empty seat (a Revive gave the party a bench) is solicited like any
  replacement (`turn` with its slot); the screen writes the revive's HP onto
  the live party mon at the referee's `item` and frees the fainted battler, so
  the seat's picker lists it.
- The backstop (`SoloBattle:_backstop3`): when a player seat owes the referee
  a choice while the screen reports `waitingOnReferee()` for 3 s of pump time,
  the screen is asked to `reopenOwed(field, replace)` once per seat per
  window, else the referee `autoPick`s it; both are logged with a remediation.
  It never fires in a fight where the two agree.

**C4 — classic double view (T4 builds, T5 draws).** `model.double` is present
instead of `foe`/`ally`/strips:
```lua
model.double = {
  foes   = { [1] = seatModel|nil, [2] = seatModel|nil },  -- [1] = field slot 3, [2] = slot 4
  allies = { [1] = seatModel|nil, [2] = seatModel|nil },  -- [1] = slot 0, [2] = slot 1
  choosing = 1|2|nil,                 -- whose command menu is up
  blink = { side = "a"|"b", index = 1|2 } | nil,   -- the battler being aimed at
}
```
- `seatModel` is the shape `gen3SeatModel` returns today.
- Every other model field (`phase`, `message`, `commands`, `moves`, `list`,
  `prompt`, `trainer`, `weather`, `frame`) keeps its meaning.

**C4 additions after wave 1** (from T5's report; T4 supplies them, T5b draws them):
- In phase `"target"` the model still carries `moves` + `cursor`. The cart keeps
  the move menu up while aiming, and without them the textbox would be empty.
- `double.blink.since = frame`, set each time the target cursor moves, restarts
  the 8-frame blink from "shown", as on the cart.
- `moves[i].target` is the move's target byte (`MOVE_TARGET_*`), so hovering a
  move previews the battlers it will hit (engine `ui.lua` `preview_targets`).
- `double.hpText = true` while START is held swaps the bars for HP numbers
  (engine `healthbox.lua` `swapHpBarsWithHpText`).

**Shared-team facts T3/T4 code against** (from T1's report):
- A filed choice's `slot` is the 1-based party index after normalisation, so
  `view.claimed` comes from `sim:seatsOf(id)[k].choice`.
- `team` events arrive only on a party's first slot (0 or 3).
- Winners, losers, `waiting` and `catcher` carry owner ids.
- X items, Dire Hit and Guard Spec. are refused on the partner, as on the cart
  (`gBattlerInMenuId`).

**Brain facts T3 codes against** (from T2's report):
- **One** brain instance answers both trainer seats, because the trainer's item
  uses are per-trainer.
- A switch is `{ action = "switch", slot = <party index> }`.
- `view.partner` is the living partner, or nil.

## 4. Work breakdown — implementation tasks

| ID | Goal | Owns (exclusive) | Depends on | Acceptance |
|---|---|---|---|---|
| T1 | The shared-team seat model in both referee twins (C1), plus parity scenarios and the sheet-contract doc | `src/BattleSim3/Turn.lua`, `src/BattleSim3/Move.lua`, `src/BattleSim3/Effects.lua`, `server/lib/battle3/Turn.js`, `server/lib/battle3/Move.js`, `server/lib/battle3/Effects.js`, `tests/fixtures/battle3_turn_parity.json`, `tests/battle_sim3_turn.lua`, `server/battle3_turn.test.js`, `docs/plans/gen3-battle-sheet.md` | — | Every existing scenario's expectations are unchanged. New scenarios: a `seats=2` trainer double; a shared-bench faint plus replace from either slot; the last monster (one seat refilled); a sibling switch conflict; EXP dedupe; bag reservation (two seats, one Potion); an item on the partner's active; a double KO with one bench monster. Lua and Node agree on all of them. |
| T2 | Doubles in the Gen 3 trainer AI (C2), the cart's rule per family | `src/SoloBrain.lua` | — | FRLG picks a random target per the engine's rule, and Emerald scores per target. DOUBLE_BATTLE runs when the cart would. Switching and replacement honour `claimed` and both actives. The 1v1 view keeps today's behaviour. |
| T5 | The GBA-native classic double layout (C4) | `src/ClassicBattle.lua` | — | `drawGen3` draws four pics and four doubles healthboxes at the engine positions, plus the target blink, when `view.double` is set. `M.gen3DoubleLayout(view)` is exposed for layout checks. Singles rendering is unchanged. |
| T3 | Solo takes lone doubles (C1+C2+C3 consumer) | `src/SoloBattle.lua`, `src/Config.lua` (the `SOLO_REFUSED_GEN3` comment only) | T1 (and C2/C3 by contract) | A double with ≥2 usable monsters is taken. It runs two seats a side, a claim-aware `_answerFoe`, `seat`-mapped choices, prize ×2 (from the fight's own `double`; review dropped the record's unread `doubleBattle`), both seats reconciled, Emerald TV mon 2, and the whiteout/draw/halt rules. A double with <2 usable monsters is handed back. `trainerIdB` is handed back. 1v1 is unchanged. |
| T4 | The solo-double screen on `CoopBattle` (C3), building C4 | `src/CoopBattle.lua`, `src/CoopSim.lua`, `src/Battlefield.lua` (only if the one-human-two-seats ally side needs it) | T1 (event shapes) | `newSoloDouble` meets C3. `ownSlots` gives a chooser cursor, choices filed at choice time with the referee's `cancel` for partner cancel (decision 5), bench exclusion with an "already in battle" refusal, targets including the ally, per-seat replacement, EXP/learn/evolve for both own slots, trainer and "Go! X and Y!" intro lines, and C4 for classic. `ownSlots == nil` leaves co-op untouched. |
| T5b | Two more GBA-double behaviours: move-target preview and the START HP-number swap (C4 additions) | `src/ClassicBattle.lua` | T5 | Hovering a move in a double highlights the battlers it will hit, per its target byte; holding START shows HP numbers instead of the four bars; singles are unchanged. |
| T6 | Docs | `CHANGELOG.md`, `README.md`, `mod.card`, `docs/plans/gen3-known-gaps.md`, `docs/plans/gen3-firered-emerald-support.md`, `.modkitignore` | T3, T4 | The 1.5.0 Added entry is written; the Known bullet is reworded (lone doubles are taken, and FR/LG were never only Emerald); gap #2 is marked done; new files are listed in `.modkitignore`. |

## 5. Work breakdown — test tasks

| ID | Covers | Owns | What |
|---|---|---|---|
| TT1 | T1 | (in T1) | The parity scenarios above. They are part of the referee's spec, so the referee task writes them. |
| TT2 | T2, T3 | `tests/gen3_solo.lua`, `tests/solo_battle.lua` | Flip the `:1116` hand-back. Keep the `gen3Double` statics and add the take-over predicate. Use row 902 with two seeded monsters to cover: both seats out; a switch to any bench monster; refill after a faint; prize ×2 (`double=true` reaches Prize); EXP split; both monsters reconciled; whiteout and draw; Emerald TV mon 2. Also cover the hand-back cases: a one-usable-monster party, and `trainerIdB`. AI cases: the FRLG random target, the Emerald best-target choice, DOUBLE_BATTLE avoiding hitting the partner, and no claimed or out monster sent in. Add a second-seat choice helper to `drive`. |
| TT3 | T4 | `tests/gen3_solo_double.lua` (new; add a `.modkitignore` line) | The screen through the real `CoopBattle` with a local referee: the chooser order, B returning to mon 1, bench exclusion with the "already in battle" line, the target list including the ally, per-seat replacement, the C4 model shape, and both own slots gaining EXP. Run `gen3_coop.lua`/`coop_mediated.lua` unchanged as the regression. |
| TT4 | T5, T4 | `tests/drivers/classic_battle_shot.lua`, `tests/drivers/battlefield_shot.lua` | Staged frames: a GBA double (with the blink), and a solo-double arena (one human, two ally seats, a trainer behind two foes). Layout checks: no overlaps, everything on screen. |
| TT5 | e2e | `tests/drivers/solo_battle_e2e.lua` (+ `mmo_util.lua` only if a helper is missing) | Legs on FireRed (#484-class pick) and Emerald (#483-class pick): arena, then classic. Cover: two commands with one B-back; aiming at each foe; a switch; a KO and refill from the bench; the win with prize ×2 and EXP asserted; the defeat flag set. Plus an Emerald real-flow leg: Route 104 sight approach to the end. Plus a one-usable-monster hand-back. Screenshots as `g3-<fr|em>-solo-NN-double-*.png`; curate 3–4 into `docs/screenshots/gen3/` with `.modkitignore` lines. |

**e2e applies:** this is a user-visible flow that crosses the referee, the screen,
the save and the script VM. Run recipe (from this session, not a subagent):
- **Engine view:** private, with a vsync=0 `conf.lua` copy.
- **Headless first:** `luajit mods/rby_mmo/tests/gen3_solo.lua`.
- **e2e:** `GEN1RECOMP_ROOT=$VIEW GEN3_GAME="firered emerald" SHOT_DIR=<scratch>/shots caffeinate -dimsu bash mods/rby_mmo/tests/drivers/run-solo-battle-e2e.sh --gen3`.
- **Gate:** `GAPS:0`.
- **Also run:** `run-battlefield-e2e-gen3.sh` (both games),
  `run-classic-battle-e2e.sh`, and the Gen 3 MMO co-op legs as the co-op
  regression.
- **ROMs and caches:** `.env` carries `FIRE_RED_ROM_PATH`/`EMERALD_ROM_PATH`,
  and the caches clone from `rby-mmo-g3-import-{fr,em}`.

## 6. Execution waves

- **Wave 1** (parallel, disjoint): **T1**, **T2**, **T5**. A barrier follows,
  then a commit, `wave 1: shared-team referee, doubles AI, GBA double layout`.
- **Wave 2** (parallel, disjoint): **T3**, **T4**, **T5b**. T3 and T4 depend on T1's real
  referee and code to C2/C3/C4. A barrier follows, then integration by me:
  wire solo → screen → referee, a headless smoke run, and fixes to the glue.
  Then commit.
- **Wave 3:** **T6** docs (by me), then commit.
- After that: review (Phase 5), then **TT2–TT5** in parallel (file-disjoint),
  then run, then fix.

## 7. Blast radius & risks

- **Referee twins:** every hub fight (1v1, co-op Gen 3) runs this code. This
  is mitigated by the one-seat path being byte-identical, which the full
  existing parity fixture checks in both languages.
- **`CoopBattle`/`CoopSim`:** every co-op fight on all three generations uses
  them. Mitigations:
  - `ownSlots == nil` is the only path co-op takes;
  - the `rby_mmo_test`, `gen3_coop`, `coop_mediated` and
    `mediated_battle_client` suites must stay green;
  - the co-op e2e legs (Gen 1 mmo/hub, Gen 3 FR/EM `coop`) must be no worse
    than baseline.
- **`SoloBrain`:** Gen 1/2/3 1v1 decisions must be unchanged
  (`solo_brain.lua`, `gen3_solo` section 1).
- **`ClassicBattle`:** singles drawing must be unchanged (classic shot driver,
  Gen 3 solo classic leg).
- **Script flow:** types 6/8 continue after the fight exactly as for singles.
  Tate & Liza is the heaviest case; it is covered headless through the
  existing post-battle path, and live only if the driver can reach it cheaply.
- **Rollback:** the hand-back predicate is one line. Reverting T3's take-over
  restores today's behaviour with everything else inert.

## 8. Open questions / assumptions

- **Gen 3 halves spread damage only for `MOVE_TARGET_BOTH`**, so Earthquake and
  Surf are not halved. This is the referee's existing behaviour, agreed by
  the engine port. No pret source is local, so it is not re-verified here,
  and it is not a change in this run.
- **The quest log and `battle.ended`** take one player monster and one enemy in
  the engine API (`quest_log_recorder.lua:87`). The lead of seat 1 and of the
  foe's seat 1 are passed.
- **LeafGreen** is covered headless only (no ROM on this machine).

## 9. Completeness ledger

| Candidate | Disposition |
|---|---|
| FireRed/LeafGreen lone doubles (the docs said only Emerald) | **in this run**: T3; docs T6 |
| trainerbattle types 6/8 after a double (continue / post scripts, gym doubles) | **in this run**: T3 (same path as singles), TT2 |
| <2 usable monsters | **in this run**: T3 hand-back, TT2/TT5 |
| prize ×2 (`g3.double`; the record's `doubleBattle` was dropped in review, nothing read it) | **in this run**: T3 |
| EXP dedupe for a monster that fought from both slots | **in this run**: T1 |
| Bag: two seats on the last item; items on the partner's active | **in this run**: T1 |
| Emerald TV `playerMon2Species` | **in this run**: T3 |
| "X sent out Y and Z!", "Go! Y and Z!" | **in this run**: T4 |
| e2e scans skip double rows (`solo_battle_e2e.lua:288/924`) | **in this run**: TT5 (the solo double legs pick doubles; the singles legs keep skipping them) |
| `gen3Double` statics/tests, `Config` comment, known-gaps §2, the CHANGELOG Known bullet, README:1060, `mod.card`:397, `gen3-firered-emerald-support.md`:562/649 | **in this run**: T3/T6/TT2 |
| Two trainers at once (`twoOpponents`) and Steven (`partner`) | **out of scope**: a third AI seat / two defeat flags. A different ticket, kept refused. |
| Co-op's round-robin split of a trainer's party | **out of scope**: that is co-op's design (it turns any trainer into a 2v2), not this bug |
| The GBA double layout for co-op classic | **out of scope**: co-op keeps its focus view; a different ticket |
| Safari, roamers, legendaries, Frontier, Trainer Tower/Hill, first/tutorial fights | **out of scope**: the other rows of gap #2 |
| A LeafGreen live run | **out of scope**: no ROM on this machine |
| An empty seat sorts last in turn order while `battlerCount()` counts every seat (`Move.lua:115`, `_beginTurn`). "Moved last" checks (Protect, Magic Coat, Snatch) can be off whenever a doubles side has an empty seat; pret sorts absent battlers by speed | **out of scope**: pre-existing. Co-op 2v2 has had it since the referee landed; T1 found it, this change did not create it. A referee fidelity ticket |
| Hub-hosted shared teams (`Hub.lua:1736` disconnects one seat id) | **out of scope**: no hub ever passes `seats`. Only relevant if co-op adopts shared teams |
