# Red / Gold referee: where it still differs from the carts (after 1.5.0)

A backlog of what the Gen 1 and Gen 2 referees (`src/BattleSim` ↔
`server/lib/battle`, `src/BattleSim2` ↔ `server/lib/battle2`) still do
differently from pokered / pokecrystal after
`docs/plans/gen12-referee-fidelity.md`. Every one of these existed before that
plan; they were found while doing it and left out because each is its own
ticket. The rule source for fixing them is the same: the carts in pret, quirks
reproduced, freezes never, both twins line for line, and a parity scenario per
rule.

| # | Gap | Gen | Draws move? | Size |
|---|-----|-----|-------------|------|
| 1 | Transform isn't undone on switch-out | 1, 2 | no | M |
| 2 | Haze only resets stats and screens | 1 | no | S |
| 3 | The computer's stat-down moves skip the cart's extra miss | 1 | yes (side b only) | S |
| 4 | A recharge isn't cleared by a flinch, freeze or trap | 1 | no | S |
| 5 | Self-hits behind a Substitute | 1 | no | S |
| 6 | Items and switches resolve before every move | 1 | yes | M |
| 7 | Smaller Gen 1 differences | 1 | some | S each |
| 8 | Smaller Gen 2 differences | 2 | some | S each |
| 9 | Pay Day pays nothing on Red or Gold | 1, 2 | no | S |
| 10 | The RNG's low bits repeat | 1, 2 | **every fixture** | M |
| 11 | Modded Gold moves with a priority effect | 2 | no | S |
| 12 | Gold trainers hold no items | 2 | — | upstream |

---

## 1. Transform isn't undone on switch-out

On the cart a transformed POKéMON that leaves the field gets its own species,
types, moves and stats back. The referee restores the stats
(`Effects.loadBattleStats` from `partyStats`, Gen 1) but keeps the copied
types and moves; Gen 2 also keeps confusion and the copied stats across a
switch. The copied moves don't get the cart's 5 PP either, and Gen 1's crit
rate should read the copied species' base Speed (`CriticalHitTest` reads
`wBattleMonSpecies`). A transformed *enemy's* crit stat is a CalcStat over the
copied species, which the referee can't compute without a species table — the
client would have to send it.

## 2. Haze only resets stats and screens (Gen 1)

pokered `HazeEffect_` also cures the target's non-volatile status (a sleeping
or frozen target loses its move that turn) and clears confusion, X Accuracy,
Mist, Focus Energy, Leech Seed, toxic and Disable for both sides. In a 2v2 the
referee applies Haze to the user and the target only (policy, both gens).

## 3. The computer's stat-down moves skip the cart's extra miss (Gen 1)

Outside link battles pokered gives the enemy's stat-down moves a further 25%
miss (`StatModifierDownEffect`, the `BattleRandom` / `cp 25 percent + 1` before
`CantLowerAnymore`). Adding it adds a draw to every side-b stat-down move in a
fight against the computer, so those fixtures move.

## 4. A recharge isn't cleared by a flinch, freeze or trap (Gen 1)

pokered `ClearHyperBeam` runs when a flinch lands, when a freeze lands on the
player's side (the cart's own comment: "hyper beam bits aren't reset for
opponent's side") and when a trapping move starts. The referee never clears a
recharge. The freeze half is asymmetric between the two consoles, so a link
fight needs a decision before it can be modelled.
The parity scenario `g1_flinch_recharge` (`tests/drivers/battle_turn_parity.lua`)
pins today's behaviour — a recharging mon that was flinched — which the cart
never reaches; it is re-expected when this gap closes.

## 5. Self-hits behind a Substitute (Gen 1)

A confused or disobedient POKéMON that hits itself while behind a Substitute
damages the *opponent's* Substitute on the cart. Both self-hit routes in the
referee damage the mon itself.

## 6. Items and switches resolve before every move (Gen 1)

The cart's computer uses its item or switches in its own turn-order slot; the
referee resolves every item and switch before any move. Changing it moves the
turn order of every fight where the computer uses an item.

## 7. Smaller Gen 1 differences

- Side effects still apply to a target that just fainted (the cart skips them).
- A self-hit doesn't clear the other `BattleStatus1` bits.
- A move called by METRONOME or MIRROR MOVE that lasts several turns (FLY, DIG,
  THRASH, RAGE, BIDE) is recorded under the calling slot, so the replay rolls
  METRONOME again and a called FLY never lands. pokered's `MetronomePickMove`
  writes the called move into `wPlayerSelectedMove`; the fix is to keep the
  called move in the charging / thrashing / raging / Bide records.
- RAGE and THRASH spend PP every turn, and RAGE at 0 PP becomes STRUGGLE. On the
  cart `DecrementPP` returns early while `USING_RAGE` is set, and Thrash's
  continuation never decrements.
- A mid-fight level-up never reaches the referee's stats (the cart rebuilds them
  and re-runs badges).
- Asleep or frozen, the cart's selected move is last turn's, and priority reads
  it; the referee reads the submitted choice.
- `.chooseMove` reads the raw PP byte, so the cart can pick a 0-PP move that has
  PP Ups; the sheet carries no PP-Up count.
- The toxic counter outlives a disobedience nap on the cart; the referee keeps
  toxic in `status`, so the nap clears it.
- Counter's own damage rule (`HandleCounterMove`) isn't modelled, only its
  bracket.
- The `stat` event leaves `amount` off a negative stage (the wire's `amount` is
  unsigned); a signed stage needs a field like Gen 3's `stage` / `delta`.
- RAGE's text: the cart prints "<MON>'s RAGE is building!" at each build,
  then "ATTACK rose!"; the referee says it when it injects the forced choice.
- On drain, recoil, PAY DAY and EXPLOSION moves the cart runs
  `AlwaysHappenSideEffects` before the Rage build; the referee builds inside
  the hit loop, so its `stat` event comes first (the final state is the same).
- A primary drop at −6 or raise at +6 prints "Nothing happened!" on the cart;
  the referee prints "won't go any lower / higher".
- DISABLE: the cart picks a random move slot with PP (`BattleRandom & 3`) for
  1–8 turns, and a miss says "But it failed!"; the referee disables the
  target's last move for 2–5 turns.
- A hit that a 0.25× matchup drops to 0 is a miss on the cart
  (`AdjustDamageForMoveType`); the referee floors it at 1 and it lands.
- LEECH SEED's drain is multiplied by the TOXIC counter on the cart, and a mon
  that faints to poison or burn still feeds the seeder in the same residual.
- A hit that has already fallen to 0 or 1 damage still draws the random roll.
  pokered `RandomizeDamage` returns before drawing (`cp 2` / `ret c`), and so
  does pokecrystal `BattleCommand_DamageVariation`, so Gold has it too. The
  header of `src/BattleSim/Damage.lua` explains why it was skipped. Fixing it
  removes a draw, so the fixtures of both gens move.

## 8. Smaller Gen 2 differences

- Haze in a 2v2 resets only the user and the target.
- No recoil when the hit lands on a Substitute.
- Thrash or Rage at 0 PP turns into Struggle.
- Mirror Move reads `lastMoveIndex`, not the cart's last move used.
- A switch-in applies the status penalty after the badge boost on the cart; the
  referee is read-time (stage → badge → status) throughout (plan decision 2).
- Sleep Talk itself is unmodelled ("But nothing happened"), and Snore is a
  plain hit.
- Mysteryberry on a transformed mon is eaten but restores no PP (the referee
  has no party move list).
- A replacement sent in during the replace phase misses that turn's
  between-turn items.
- Seats on a forced skip (recharge, trap, Bide storing) roll no Quick Claw.
- Bright Powder works in the referee's percent domain (100% becomes 93%; the
  cart gives 91.8%) and also touches the OHKO accuracy roll.
- `HELD_PREVENT_*` effects aren't modelled; no Gold or Crystal item carries one.
- LEECH SEED saps 1/16 of max HP, Red's amount; pokecrystal saps 1/8
  (`GetEighthMaxHP`), and on a knockout heals the seeder only the HP actually
  taken (`SubtractHP`).
- A secondary stat drop at −6 prints "won't go any lower"; the cart prints
  nothing (Red's was fixed in this release).
- A move called by METRONOME that charges (FLY, DIG) stores the charge on the
  METRONOME slot, so the next turn re-runs METRONOME and the called move never
  lands (Red has the same, §7).
- Final damage is capped at 999 after the roll; the cart doesn't cap after
  STAB or RAGE's multiplier. Only BIDE and COUNTER can see the difference.
- A wrapped POKéMON can't move (Red's rule); Gold lets it attack.

## 9. Pay Day pays nothing on Red or Gold

Neither referee reports Pay Day coins, so no Gen 1/2 path pays them. When it is
added, Gold's payout is doubled under Amulet Coin (pokecrystal `CheckPayDay`) —
multiply by `MediatedBattle:amuletCoin2()`.

## 10. The RNG's low bits repeat

`Rng:below(n)` is `next() % n`, and the generator's low bits cycle. A crit at
chance 4 or 2, and the `% 16` damage roll, therefore follow fixed patterns: a
high-crit move's crit is decided by its draw position mod 4. Both gens share
it. A fix (take the high bits) moves every fixture in both twins at once.

## 11. Modded Gold moves with a priority effect

The Gen 2 priority table is keyed by vanilla move id (the Gold sheet sends the
five priority effects as 0), so a modded move with a priority effect moves at
base priority. The fix is the client stamping a `priority` on the move sheet,
with the sanitisers and hubs carrying it.

## 12. Gold trainers hold no items

The engine's Gold trainer data has no item field (`src/battle/gen2/Mon.lua`
"not modeled"), so a trainer's POKéMON never holds anything and a player's
Thief against a trainer steals nothing. It needs the engine's importer to read
the trainer item column — an upstream (Lane B) change.

## Smaller twin and client notes

- `src/Sessions.lua` `beginWildMediated` builds a wild sheet without
  `MediatedBattle.rollWildItem2`; nothing calls it today.
- A co-op joiner's catch from a host-described wild POKéMON gets no item: the
  anti-forgery rule only lets a client keep an item it uploaded.
- The Lua sanitiser truncates ids longer than 40 characters where the Node one
  refuses them.
