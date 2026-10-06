# Red / Gold referee: where it still differs from the carts

The Gen 1 and Gen 2 referees (`src/BattleSim` ↔ `server/lib/battle`, `src/BattleSim2` ↔ `server/lib/battle2`), checked against pokered and pokecrystal / pokegold.

## History

The first version of this file (after `docs/plans/gen12-referee-fidelity.md`) listed fourteen gaps. All of them are closed, as are about a hundred more found while closing them, by `docs/plans/gen12-referee-gaps-fix.md`:

- **Waves 1–5:** `e51c48d`, `fda141f`, `d7294a8`, `3fb4b82`, `3714826`.
- **Wave 6 and later:** see `git log`.

The second version's rows 1–4 (the computer's item and switch choices, lines that depend on the viewer, faint timing, animations not emitted) and §10b's LURE / HEAVY BALL row were closed by `docs/plans/gen12-referee-remaining-gaps.md` (`e69bfe2` onward), together with Gold's move choice, which the referee had been making with the mod's heuristic. What that run found and left is folded in below.

What remains is below. Each item is either a design choice, needs data the mod doesn't have, or is presentation only.

The rule source for fixing any of them is unchanged:

- the carts in pret;
- quirks reproduced, freezes never;
- both twins line for line;
- a parity scenario per rule;
- a Lua↔JS fuzzer run.

## Still open

| # | Gap | Gen | Kind |
|---|-----|-----|------|
| 1 | A move's animation comes before its "used" line | 1, 2 | event order |
| 2 | Screens the client still words its own way | 1, 2 | presentation |
| 3 | Viewer-dependent beats a shared stream can't carry | 1 | presentation |
| 4 | Gold's computer replacement is chosen in the replace phase | 2 | turn flow |
| 5 | Red's trapper and held mon still show the move list | 1 | client signal |
| 6 | Red METRONOME's draw | 1 | needs a wire field |
| 7 | Gold dual-type rounding per chart row | 2 | needs a wire field |
| 8 | A Gold successor misses some between-turn routines | 2 | turn flow |
| 9 | Gold battle types | 2 | data |
| 10 | Smaller differences | 1, 2 | various |
| 11 | The random-number generator | 1, 2 | by design |

### 1. A move's animation comes before its "used" line

Both referees send a move's `anim` ahead of its "X used Y!" `msg`, and take it back when the move misses or fails. The carts print the used line first and animate after the hit test. The arena's trainer callout hangs off the used line, so what the player sees is the animation, then the line. The one stream in the cart's order is Red's THRASH / PETAL DANCE first turn (used line, SHRINKING_SQUARE_ANIM, the move). Moving every move's anim behind its line reorders both fixtures, every hub suite and the e2e drivers; the client already plays a move anim that arrives after its line (`f935871`).

### 2. Screens the client still words its own way

- **Send-out:** the carts vary "Go! X!" by the foe's HP (pokered PrintSendOutMonMessage: "Do it!" / "Get'm!" / "The enemy's weak!"; pokecrystal SendOutMonText: "Go for it," / "Your foe's weak!"). The client always says "Go!".
- **EXP.ALL (Red):** the cart prints "X gained\nwith EXP.ALL,\nN EXP. Points!" for each member; the client prints nothing for that pass.
- **Catch follow-ups:** neither cart prints an "added to the party" line; Red's box line is "X was\ntransferred to\nBILL's PC!" (or "someone's PC!"), Gold's "X was\nsent to BILL's PC.".
- **Link result:** "You won!" / "You lost!" stand in for the carts' YOU WIN / YOU LOSE / DRAW screen.
- **Hit and shake shapes (Red arena):** the damaging moves' animation types 1/2/4/5 (vertical, heavy, blink, light) all draw as the arena's one hit beat; a status move's own PlayCurrentMoveAnimation2 slow shake, and BIDE's start follow-on shake, aren't drawn; the type-5 follow-on replays PlayApplyingAttackSound on the cart and is silent here. Gold's after-animation damage shake (MoveAnimNoSub's wBattleAfterAnim, BATTLEANIM_ENEMY_DAMAGE / PLAYER_DAMAGE) isn't carried either; the arena's hit beat stands in.

### 3. Viewer-dependent beats a shared stream can't carry

- **Red double KO:** when HandleEnemyMonFainted catches both monsters at 0 HP, RemoveFaintedPlayerMon returns before the player's own "fainted!" text (core.asm :1037-1039), so each player sees only the foe's faint line. The client prints both.

### 4. Gold's computer replacement is chosen in the replace phase

FindMonInOTPartyToSwitchIntoBattle (and its `.loop5` draws) runs at the cart's faint check, mid-turn. The referee runs it in the replace phase, after the whole between-turn block, as it sends every successor (see 8). The pick itself is the cart's.

### 5. Red's trapper and held mon still show the move list

During a Bide the client now sends FIGHT at once. A trapper with turns left, or a mon held while awake, still sees the move list. The referee overrides the pick, so it costs a screen, never a turn.

The wire has no signal that a trap still has turns left: each continuation prints the same "attack continues!", and the end is silent. The fix is a per-seat `locked = {fieldSlot…}` on Gen 1 `turn` events (`BattleSim/Turn.lua` `_openTurn`, carried by Wire and sanitize), with the client sending FIGHT at once for those seats.

### 6. Red METRONOME's draw

pokered `MetronomePickMove` redraws `BattleRandom` until the byte is a move number in 1..STRUGGLE−1 other than METRONOME. The Red referee takes `rng:byte() % #pool + 1` (`BattleSim/Turn.lua`), so both the draw count and the pick differ. Gold already does this the cart's way. The fix is a Gen 1 pool `num` on the wire (as Gold's) plus the cart's pick loop.

### 7. Gold dual-type rounding per chart row

pokecrystal `BattleCommand_Stab` multiplies and floors once per `TypeMatchups` row, in table order. `_typePercents` applies type 1, then type 2. Red now uploads the chart's row order (`chartOrder`) for exactly this; Gold would need the same field, widening the Gen 1-only gate in Wire, sanitize and the hubs.

### 8. A Gold successor misses some between-turn routines

A mon sent in at the replace phase gets its held items and its defrost roll. It does not get the routines it would face on the cart right after a faint mid-turn: sandstorm damage, wrap, Perish Song. The referee sends successors after the whole between-turn block, not at the faint check.

### 9. Gold battle types

Special battle types aren't modelled: the shiny GYARADOS, trap, CELEBI and SUICUNE fights. They change ForceSwitch and running on the cart. The Gold ruleset now carries the engine's `battleType` (LURE BALL reads it), so the remaining work is the rules those types change, not the data.

### 10. Smaller differences

**Red:**
- **The Bide store at a faint:** FaintEnemyPokemon zeroes only the high byte of the player's BIDE damage (a bug) and RemoveFaintedPlayerMon zeroes the enemy's; the referee leaves a standing BIDE's store untouched.
- **COUNTER and the menu cursor:** the cart reads whatever move the player's FIGHT cursor last hovered. For a player who opened FIGHT and then switched, used an item or ran, that's unknowable; the referee keeps the previous selection.
- **The AI's type lookup** without `chartOrder` checks the target's type 1, then type 2.
- **A transformed mon's IncrementMovePP refund** reaches the client only at the switch-out restore.
- **Item names** are derived from item ids.
- **Catch follow-ups** (Pokédex, PC transfer, box full) are client-side.

**Both:**
- **Mod-registered AI layers:** the referees run the carts' own move layers; a non-vanilla `aiMods` / Gold layer another mod registers is not run (co-op never ran them; solo did through the engine until `9cdebb2`). A Red trainer's registered `brain` function still picks its move in a solo fight.
- **A SUBSTITUTE made at exactly ¼ HP:** the cart's 0-HP doll glitch isn't reproduced; the referee refuses with "too weak".
- **Vitamins in battle:** the carts refuse them (ItemUseNotTime) and keep the turn; the referee applies them. The mod's bag rule.
- **The bag in a fight between players:** this is the mod's rule; the carts lock the bag in a link battle (CHANGELOG Known).
- **POKé DOLL in a trainer fight:** the client refuses it; a crafted choice is spent by the referee with the cart's line.

**Gold:**
- **Link-battle check order:** with the external clock, faints, Perish Song and Leftovers are checked enemy-first; the referee always checks side a first.
- **PursuitSwitch** doesn't end Destiny Bonds on the cart.
- **The battle-scene option:** PRESENT's failure line and `lowersub`'s animation parameter depend on it; the referee assumes animations are on.
- **Shift mode:** OfferSwitch, the prompt offering the player a switch after the computer picks its successor, isn't modelled; the referee plays Set.
- **A pursuer at 0 HP** can be healed by the computer's item before HasEnemyFainted on the cart; the referee faints it first.
- **`IgnoredOrders2Text`** (a disobedient move landing on a charge move) isn't emitted.
- **Bag text:** the item lines (the use line, ball wobbles, "It won't have any effect.", the party-menu cure lines) are the referee's own.

### 10b. Found in the final review, left for later

**Red:**
- **A self-KO with a residual:** a mon whose own move took it to 0 HP while poisoned or seeded still runs HandlePoisonBurnLeechSeed on the cart. The referee faints it inside its slot.
- **ETHER on a fainted mon:** the cart allows it; the mod refuses it (`itemFailsOnFainted`, older than this work).
- **Evolution after a RUN or a catch:** pokered skips the after-battle evolution whenever `wBattleResult` ≠ 0; the client still offers it after a run or a catch.

**Both:**
- **Items on a benched mon:** a POTION, REVIVE or HP UP used on a benched mon emits `drain` on the fighter's seat with no `mon`, so the client applies it to the active mon's sheet until the next sync. The fix is a `mon` index on `drain` (Wire, sanitize and both referees) routed by the client.
- **Victory fanfare after a catch:** neither cart plays it; the client does.

**Gold:**
- **A second ETHER under Transform** on the same slot can be sent and then silently refused: the own-move PP only reaches the client when the overlay drops.
- **Kurt's balls:** Crystal's HEAVY BALL dex-bank bug (it reads weights from the wrong bank, which needs ROM bytes) and FRIEND BALL's happiness, which is set client-side. LURE BALL, HEAVY BALL and a LOVE BALL on a transformed wild mon are the cart's since `9c80683`.
- **HEAL POWDER** has no battle effect entry.
- **A mid-fight learn and Disable / Encore:** a learn rewrites the move list in place, so a `disable` / `encore` index can point at the new move.

### 11. The random-number generator

The referees use their own LCG (Numerical Recipes constants, high bits), not the carts' `Random` (rDIV plus an add-with-carry). Every draw point and every byte→outcome mapping follows pret; the byte values themselves can't, because the seed is the referee's. This is by design: the referee's seed is what makes a fight replayable and the Lua and Node twins provably identical.

## Engine-port divergences

Places where Gen1Recomp's own battle code disagrees with pret are listed in `docs/plans/gen12-referee-fidelity.md` §10, `docs/plans/gen12-referee-gaps-fix.md` §10 and `docs/plans/gen12-referee-remaining-gaps.md` ("Delivery"). They belong in an upstream report, not a mod change.
