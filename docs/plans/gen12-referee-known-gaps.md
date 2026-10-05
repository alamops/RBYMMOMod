# Red / Gold referee: where it still differs from the carts

The Gen 1 and Gen 2 referees (`src/BattleSim` ↔ `server/lib/battle`, `src/BattleSim2` ↔ `server/lib/battle2`), checked against pokered and pokecrystal / pokegold.

## History

The first version of this file (after `docs/plans/gen12-referee-fidelity.md`) listed fourteen gaps. All of them are closed, as are about a hundred more found while closing them, by `docs/plans/gen12-referee-gaps-fix.md`:

- **Waves 1–5:** `e51c48d`, `fda141f`, `d7294a8`, `3fb4b82`, `3714826`.
- **Wave 6 and later:** see `git log`.

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
| 1 | The computer's item and switch choices | 1, 2 | AI |
| 2 | Lines that depend on the viewer | 1, 2 | presentation |
| 3 | Faint timing on a knockout | 1, 2 | event order |
| 4 | Animations not emitted | 1, 2 | presentation |
| 5 | Red's trapper and held mon still show the move list | 1 | client signal |
| 6 | Red METRONOME's draw | 1 | needs a wire field |
| 7 | Gold dual-type rounding per chart row | 2 | needs a wire field |
| 8 | A Gold successor misses some between-turn routines | 2 | turn flow |
| 9 | Gold battle types | 2 | data |
| 10 | Smaller differences | 1, 2 | various |
| 11 | The random-number generator | 1, 2 | by design |

### 1. The computer's item and switch choices

The computer's moves are picked as on the carts. Its items and switches are not.

- **Moves:**
  - wild mons use `.chooseRandomMove`;
  - co-op trainers use pokered's move-choice layers 1–3, from the trainer's `aiMods`;
  - solo trainers use `src/SoloBrain.lua`.
- **Items and switches** still come from the referee's heuristic (`_autoChoice`), not from the cart's routines:
  - pokered `TrainerAI`: the per-class routines, `wAICount`, the `Random` byte drawn every turn while uses remain, Juggler and Cooltrainer switches, the class HP fractions;
  - pokecrystal `AI_SwitchOrTryItem` and item AI, e.g. the toxic-count Full Heal check.
- **What a port needs:** the class's item list and AI flags on the NPC side entry (engine data, client-stamped like `aiMods`), and the routines in both referees.

### 2. Lines that depend on the viewer

The referee is one shared narrator, so it can't do what each cart does for its own player:

- the "Enemy" / "Wild" prefixes on the foe's names;
- the cart's line breaks and pauses;
- in a link battle, "Enemy <MON> ran!" for the player whose foe fled (the mod says "You forfeited" / "Someone ran away!").

The wire also caps a battle line at 60 characters. Each client could add the prefixes itself, since it knows which seats are its own.

### 3. Faint timing on a knockout

The target's `faint` event comes before the same hit's tail lines (drain, recoil, Pay Day, Thief). The cart prints those first and faints the target after the move.

- **Gold:** only Destiny Bond defers the faint.
- **Red:** keeps the existing order.

Changing this moves every KO's event order in both fixtures.

### 4. Animations not emitted

These are presentation only:

- **Red:** STATUS_AFFECTED_ANIM (a cancelled FLY or charge), XSTATITEM_ANIM, ABSORB from the seeder, TOSS_ANIM for a ball a trainer blocks.
- **Gold:** the move animations of the new Gold effects beyond what the screens already play.

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

Special battle types aren't modelled: the shiny GYARADOS, trap, CELEBI and SUICUNE fights. They change ForceSwitch and running on the cart. The mod refereeing those fights would need the battle type on the ruleset.

### 10. Smaller differences

**Red:**
- **COUNTER and the menu cursor:** the cart reads whatever move the player's FIGHT cursor last hovered. For a player who opened FIGHT and then switched, used an item or ran, that's unknowable; the referee keeps the previous selection.
- **The AI's type lookup** without `chartOrder` checks the target's type 1, then type 2.
- **A transformed mon's IncrementMovePP refund** reaches the client only at the switch-out restore.
- **Item names** are derived from item ids.
- **Catch follow-ups** (Pokédex, PC transfer, box full) are client-side.

**Both:**
- **A SUBSTITUTE made at exactly ¼ HP:** the cart's 0-HP doll glitch isn't reproduced; the referee refuses with "too weak".
- **Vitamins in battle:** the carts refuse them (ItemUseNotTime) and keep the turn; the referee applies them. The mod's bag rule.
- **The bag in a fight between players:** this is the mod's rule; the carts lock the bag in a link battle (CHANGELOG Known).
- **POKé DOLL in a trainer fight:** the client refuses it; a crafted choice is spent by the referee with the cart's line.

**Gold:**
- **Link-battle check order:** with the external clock, faints, Perish Song and Leftovers are checked enemy-first; the referee always checks side a first.
- **PursuitSwitch** doesn't end Destiny Bonds on the cart.
- **PRESENT's failure line** depends on the battle-scene option; the referee assumes animations are on.
- **The `team` roster** shows a standing (0-HP, not yet fainted) mon as fainted.
- **`IgnoredOrders2Text`** (a disobedient move landing on a charge move) isn't emitted.
- **Bag text:** the item lines (the use line, ball wobbles, "It won't have any effect.", the party-menu cure lines) are the referee's own.

### 11. The random-number generator

The referees use their own LCG (Numerical Recipes constants, high bits), not the carts' `Random` (rDIV plus an add-with-carry). Every draw point and every byte→outcome mapping follows pret; the byte values themselves can't, because the seed is the referee's. This is by design: the referee's seed is what makes a fight replayable and the Lua and Node twins provably identical.

## Engine-port divergences

Places where Gen1Recomp's own battle code disagrees with pret are listed in `docs/plans/gen12-referee-fidelity.md` §10 and `docs/plans/gen12-referee-gaps-fix.md` §10. They belong in an upstream report, not a mod change.
