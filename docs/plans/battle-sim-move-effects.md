# BattleSim move effects + mediated wait-line track

Status: **complete** (Waves A–C7; hub + quad e2e green 2026-08-09)
Owner routing: Grok 4.5 plans/reviews/tests; Composer 2.5 applies code.

## Locked decisions

- Wait line: **rotate** one missing name every `COOP_WAIT_ROTATE` seconds.
- Effects: **full** Gen1 set (68 effect ids that real moves use).
- Metronome: picks from host-uploaded `metronomePool` on the ruleset (from
  `MediatedBattle.snapshotRuleset`); without a pool → "But nothing happened".

## Waves

| Wave | Scope | Status |
|------|--------|--------|
| A | PROTOCOL 11, `unchose`, medFlush/`acted`, countdown sync, rotate, e2e | done |
| B | Struggle, mediated anims, auto-pick heuristic, upload effect/chance | done |
| C0–C7 | Effect classifier → full handlers → docs cutover | done |

## Wave A checklist

- [x] `PROTOCOL` 10 → 11 (`Config.lua`, `relay.js`) + CHANGELOG
- [x] `unchose` in Wire / Events / Turn cancel emit
- [x] CoopBattle: apply `unchose`, clear `acted` on empty `medFlush`, mediated countdown, rotate
- [x] `mmo_quad` asserts peer drops from `missingActors` mid-wait
- [x] Suites green

## Wave C phases (detail)

| Phase | Scope | Status |
|-------|--------|--------|
| C0 | Effect id table, categories, stage multipliers | done |
| C1 | Primary stat stages + primary status inflict | done |
| C2 | Side-chance effects + flinch | done |
| C3 | Multi-hit / drain / fixed / recoil | done |
| C4 | Multi-turn / charge | done |
| C5 | Volatiles (mist, substitute, screens) | done |
| C6 | Meta / flow (bide, explode, jump kick, teleport, pay day, mirror, mimic) | done |
| C7 | Docs cutover | done |

See conversation plan for handler inventory.

### Phase C4 (done)

Multi-turn state machines mirrored in `Effects` + `Turn` (Lua/JS):

- **CHARGE (39) / FLY (43):** turn-one setup (`charging`, `invulnerable` for Fly), auto-release turn two, no second PP spend.
- **HYPER_BEAM (80):** `mustRecharge` after a damaging hit that leaves the foe standing; next turn auto-skips with "must recharge".
- **TRAPPING (42):** `trapped` on the victim and `trapping` on the user; both lock out the menu. Victim: "can't move". User: continue narration + `anim` for the locked move (no `_useMove` re-roll). Residual trap damage on the victim at turn end uses the **first-hit damage store** (Gen1).
- **THRASH (27):** `thrashing { turns, moveIndex }` forces repeat; ends in confusion.
- **RAGE (81):** `raging` + `rageMove` forces repeat; +1 atk stage on taking damage.

Forced injection is the mediated stand-in for “cartridge opens no menu,” not a
damage-model shortcut. Trap residual remains the Gen1 damage path.

### Phase C5 (done)

Volatiles mirrored in `Effects` + `Turn` (Lua/JS):

- **SUBSTITUTE (79):** costs `floor(maxHp/4)` HP; fails at `hp <= cost` or if a sub already exists; `mon.substitute` HP pool absorbs hits in `_damage` (overflow on break does not hit the mon).
- **REFLECT (65) / LIGHT_SCREEN (64):** `mon.reflect` / `mon.lightScreen`; `Effects.screenDamage` halves physical (Reflect) or Special (Light Screen) when `specialTypes` is uploaded (MediatedBattle always derives Gen1 Special indices from the host type chart). Absent `specialTypes`, every move is treated as Physical (synthetic fixtures only — live hosts warn if the chart has types but zero Special name matches).
- **MIST (46):** `mon.mist`; foe stat drops fail with "But it failed".
- **FOCUS_ENERGY (47):** `mon.focusEnergy`; passed into `Crit.check` (Gen1 bug preserved).
- **CONVERSION (24):** copies foe's first type onto the user.
- **TRANSFORM (57):** copies foe stats, types, stages, and move list (with PP); sets `mon.transformed`. Emits `moves` for mediated clients.

Cleared on switch-out / faint.

### Phase C6 (done)

Meta / flow handlers mirrored in `Effects` + `Turn` (Lua/JS):

- **BIDE (26):** `mon.bide = { turns, stored, moveIndex, targetSlot }`; turn one stores with no damage; forced skips while `turns > 0` accumulate damage into `stored`; release deals `2 * stored` (fails at 0).
- **EXPLODE (7):** halves foe defense for the damage calc; user faints after the attempt even on miss/immune.
- **JUMP_KICK (45):** on miss or immune, crash damage `max(1, floor(maxHp/8))` to self.
- **SWITCH_AND_TELEPORT (28):** succeeds as run only when `mode` contains `"wild"`; always "But it failed" in mediated `1v1` / `coop_*`.
- **PAY_DAY (16):** damaging only; cosmetic "Coins scattered" after a hit.
- **MIRROR_MOVE (9):** fails without foe `lastMoveIndex`; otherwise re-enters `_useMove` with a copy of that move.
- **MIMIC (82):** replaces the used slot with a deep copy of foe's last move; emits `moves`.
- **METRONOME (83):** picks from host-uploaded `metronomePool` (see Metronome below); empty/absent pool → "But nothing happened".
- **EFFECT_01 / EFFECT_1E / UNUSED:** no-op, "But nothing happened".

`mon.lastMoveIndex` is set whenever a move completes past gates.

## Metronome

Host uploads an ephemeral `metronomePool` (move sheets) with the ruleset via
`MediatedBattle.snapshotRuleset` (sorted host `data.moves`, excluding Metronome
and Struggle, capped at `BATTLE_METRONOME_POOL_MAX`). Metronome picks one with a
RNG byte and re-enters `_useMove` like Mirror Move. Empty/absent pool → "But
nothing happened" (and the client warns if the move table was non-empty but the
pool came out empty).

## Locked decisions (mediated BattleSim — not open gaps)

These are standing architecture / legal choices. Closing them by shipping a hub
species dex, engine `move_effects` / `ItemEffects` tables, or ROM-derived
content is out of bounds for this mod (`affects_link` stays false; no
ROM bytes).

- **Sheet trust.** Party battler sheets and bag counts are client claims.
  Sanitize enforces coherence (types, ranges, `hp ≤ maxHp`, BattleSim-known
  item ids). Bag proofs (PROTOCOL 15) only stop mid-fight free heals without a
  matching uploaded stack. Inventing a plausible god team or bag on upload
  remains possible because the hub holds **no** species / inventory truth to
  check against — and must not grow one.
- **Forced lock-in.** Recharge / trap / thrash / bide inject a `skip` (or forced
  fight) in `_fillForcedChoices` rather than mirroring every engine multi-turn
  UI path — that is cartridge-shaped (no menu), not a damage shortcut. Trap
  residual uses the first-hit store; the trapper emits continue `msg` + `anim`
  without re-rolling the move. Narration rides beside inject-skip so the screen
  still feels locked; clients keep the command menu closed via own-seat `chose`.
  Solo and host-sim co-op keep the engine UI.
- **Faint replacement.** With bench left, `_faint` clears `active`, sets
  `mustReplace`, and emits `faint` with `amount=1` (authoritative for clients).
  Empty bench omits `amount`. The next choice window accepts only `switch`
  for that seat (timeout / NPC auto-pick still lands firstLiving, preferring
  an SE bench). Switches still resolve before fights. MediatedBattle and
  mediated CoopBattle open the replace picker from `amount=1` after faint
  narration drains (msg → picker → send); empty-bench never arms the picker.
  Both sides losing their last mon on the same action (KO + recoil / explode)
  or in the residual batch is a draw (`ko`); an empty-bench KO still ends
  before the slower seat moves.
- **Not byte-identical to the engine.** BattleSim is a hand-authored Lua/JS
  twin of the 68 Gen1 effect ids plus a public heal/status item table. Clients
  upload each move’s `effect` / `chance` / power from their local engine decode;
  what we claim is Lua↔JS event parity on synthetic fixtures — not a copy of
  engine `move_effects` / `ItemEffects`. Host-sim co-op (when mediation is off)
  still drives the engine registries.

## Documented behavior (mediated BattleSim)

Other intentional deltas vs a full engine port (still not claimed
byte-identical):

- **Forced-choice pacing:** forced-only turns wait for the next `tick` before
  resolving so wait-lines and anims see a turn boundary instead of a multi-turn
  dump. Regenerate `tests/fixtures/battle_turn_parity.json` when item/catch RNG
  draw sites move
  (`luajit tests/drivers/battle_turn_parity.lua . > tests/fixtures/battle_turn_parity.json`).
- **Items:** hand-authored Gen1 heal/status table; X-items / Dire Hit / Guard Spec;
  party-target Revive/Max Revive / Ether/Max Ether / Elixer/Max Elixer; optional
  Poké Flute (wakes sleep on both parties, never consumed); **vitamins**
  (HP_UP / PROTEIN / IRON / CARBOS / CALCIUM) mutate fight-local sheet Stat Exp
  (+2560, fail at ≥25600) and battle stats via Gen1 √EV contribution; the client
  writebacks `save.statExp` on hub `item` confirm when `amount=1` (applied) and
  recalcs engine `stats` / `hp` via `Stats.calc` so the party screen does not lag;
  failed vitamins still spend the bag stack but omit `amount` so the client
  does not bump Stat Exp (hub has no permanent EV store);
  balls catch in `wild` mode (Master Ball auto), fail in 1v1/coop; POKE_DOLL
  escapes wild only. **Unknown / non-battle ids** (PP Up, evolutionary stones,
  Rare Candy, Repels, Escape Rope, HM/TM, etc.) are omitted from bag upload and
  announce "But it failed" if somehow chosen (still spend the turn — no silent
  soft-stall).
- **Co-op ITEM UX:** mediated `CoopBattle` mirrors MediatedBattle party / move
  pickers for heals, Revive, Ether, vitamins (`item_party` / `item_move`); balls /
  doll / flute / X-items commit without a bench pick; `partySlot` / `move` ride
  the wire the same way as 1v1.
- **Timeout / NPC auto-pick:** bag cures → heals at ≤50% HP → X-items while
  stages are flat (when a bag sheet is present; coop_npc seats without an
  upload get `DEFAULT_NPC_BAG`); else SE damage; else primary status / leech /
  confusion if the foe is clear and not behind a Substitute (prefer when
  slower or the foe is set up); else self-boost / screen / substitute while
  stages are flat (skipped into a boosted / subbed foe or while slower at
  mid-low HP); else SE bench switch when immuned, at critical HP, or behind a
  boosted foe at mid-low HP. Deterministic twin heuristics — not a full
  TrainerAI port. Fighter bags decrement on item resolve; hub sheets sync from
  the sim after the turn leaves choice.
- **Mediated 1v1 field:** classic Gen1 layout (foe front + top-left HUD, ally
  back + bottom HUD with HP numbers, split command box). Battle sprites via
  `BattleState.makeBattler` when engine art loads; HUD-only degrade otherwise.
- **Co-op mediation:** modes in `Config.MEDIATED_COOP` never fall back to
  host-sim when upload fails — the fight ends as a draw ("could not be
  refereed") so BattleSim and engine `ItemEffects` cannot diverge mid-match.
- **Bag proofs (PROTOCOL 15):** clients upload a battle-usable `bag` with
  `mmo.battle_party` (BattleSim-known ids, vitamins included). The hub
  *holds* a stack on `item` accept; after resolve the fighter bag (spent by
  Turn) is synced back onto the hub sheet, so `cancel`/`unchose` drops the
  hold without a refund and NPC auto-item use stays consistent. ITEM menus
  follow the uploaded sheet; local inventory debits only after the hub `item`
  event.
- **Disable:** disables the target's last-used move for 2–5 turns; choice refusal + auto-pick skip.
- **Leech Seed:** `fromSlot` tracks the seeder for residual drain/heal.
- **`moves` event (PROTOCOL 12):** `{ slot, side, moves: [{id,pp,power,accuracy,type,effect,chance},…] }` after Transform/Mimic.
- **`specialTypes` / `metronomePool` (PROTOCOL 13):** ruleset fields for Gen1
  phys/spec and Metronome. Live hosts always derive them in
  `MediatedBattle.snapshotRuleset`; optional on the wire so synthetic fixtures
  can omit them.
- **Badge boosts:** clients upload earned badges on `mmo.battle_party`; hub passes
  `party.badges` into `Turn.create`. `Effects.badgeBoost` applies Gen1
  `ApplyBadgeStatBoosts` (×9/8, floored) to atk/def/spd/spc before stages in
  damage and speed (including crit speed).
