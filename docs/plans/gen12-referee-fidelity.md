# Plan — Referee fidelity: Gen 1/2 stats, crits, screens, priority, obedience, Gold held items; Gen 3 item theft

| Field | Value |
| --- | --- |
| Date | 2026-10-02 |
| Source | "Fix/implement where applicable" on the six out-of-scope rows of `docs/plans/gen3-badge-rules.md` §9, widened by the owner at the grill (crits/screens, Gold held items, move priority) |
| Config | AGENTS_CONFIG.yml (quality preset, host `claude_code`) |
| Flags | none |
| Gates | grilled + approved by owner |
| Branch | `feature/firered-and-emerald-support` (unpushed, 1.5.0, PROTOCOL 30 unreleased) |
| Base SHA | `99a4c9e` (wave 1 `3d356c2`, wave 2 `7aeae6c`) |

**Rule source, decided by the owner:** the carts, read in pret (`pokered`, `pokecrystal`, `pokefirered`, `pokeemerald`). Copies are in `<scratchpad>/pret/`; fetch more with `curl -sfL https://raw.githubusercontent.com/pret/<repo>/master/<path>`. Documented cart quirks are reproduced. Where the engine ports disagree with pret, pret wins and the divergence is written down.

## 1. Objective & success criteria

1. **Badge boost vs stat stages.**
   - **Gen 1 (pokered):** use the stored-stat model:
     - A switch-in loads party stats, applies the burn/paralysis penalty, then badges.
     - A stage change rebuilds the changed stat from the unmodified stat × stage (999 cap, minimum 1), then re-runs badges on every stat. This is the **badge-stacking glitch**: it fires on the player's own stat-ups and on the enemy's drops to the player's stats, including side-effect drops, Rage, X items and accuracy/evasion.
     - After each stat move it re-applies the burn/paralysis penalty to the non-mover. This is the **re-penalty glitch**.
     - A stat-up on a stat already at 999 fails.
     - Haze, switching and fainting reset it all. Stages now also reset on switch-in and faint, which they never did.
   - **Gen 2 (pokecrystal `CalcPlayerStats`):** stage (999 cap) → badges (999 cap) → burn/paralysis, rebuilt from raw each time. No glitch.
2. **Crits.**
   - **Gen 1:** a crit reads party stats, ignoring stages, badges, burn and screens. Party stats means the pre-Transform stats (`partyStats`). The level is doubled. Focus Energy plus a high-crit move uses the cart's shift chain (the threshold becomes `4·floor(b0/2)`).
   - **Gen 2 (`CheckDamageStatsCritical`):** a crit uses the unmodified stats unless the defender's stage is strictly lower than the attacker's. Unmodified means no stages, badges, burn, paralysis or screens. The ×2 crit multiplier comes after the type-item boost and before the 997 cap.
3. **Screens.**
   - **Gen 1:** Reflect and Light Screen are per battler. They double the defending stat before the 255 scaling, are not applied on a crit and don't affect fixed-damage moves. A second cast fails. Haze clears both sides', and the holder loses its screen on leaving the field. The post-hoc halving is removed.
   - **Gen 2:** screens are per side and last 5 turns, ticking at the cart's between-turn point. A second cast fails. Switching and Haze don't clear them. They double the defense, and not on an unmodified crit.
4. **Damage tails.**
   - **Gen 1:** the 255 scaling uses low-byte wrap past 1024, with the divisor clamped to ≥ 1 so the cart's freeze is never reached. Explosion halves defense after the scaling. Damage is capped at 997 and then 2 is added.
   - **Gen 2:** `TruncateHL_BC` loops while either stat is over 255 (a single pass in link modes, with the wrap bug). Light Ball and Thick Club apply before truncation and Metal Powder after it, each with its quirks. The 997+2 cap applies.
5. **Confusion self-hit.**
   - **Gen 1:** stored stats (stages, badges, burn). The opponent's Reflect doubles your defense (cart quirk; in a 2v2, the battler opposite). No crit and no random roll.
   - **Gen 2:** stage, badge and burn stats; your own side's Reflect; no crit and no variation. The cart bugs are kept: Explosion or Self-Destruct as the selected move halves the self-hit's defense, and a type-boost item uses the selected move's type.
6. **Struggle.**
   - **Gen 2:** typeless. No STAB, no type effectiveness (it hits Ghosts), no weather and no badge type boost. A Normal type-boost item (Pink or Polkadot Bow) still applies. Recoil is 1/4 of the damage.
   - **Both gens:** a Metronome or Mirror Move call made with the last PP no longer gives the called move Struggle's recoil.
7. **Move priority** (new for both gens). These are the cart's priority brackets: Gen 1 (pokered) Quick Attack +1 and Counter −1; Gen 2 (pokecrystal `GetMovePriority` and its table). Turn order is the bracket, then (Gen 2) Quick Claw within the bracket, then speed, then the existing tie-break. This applies to every mode, PvP included.
8. **Gen 1/2 obedience** in fights against the computer (BADGE_MODES side a only, as Gen 3):
   - **Algorithm:** the cart's shared one. Traded means the OT id differs from the player id. Caps:
     - Gen 1: Earth = no cap, Marsh 70, Rainbow 50, Cascade 30, otherwise 10.
     - Gen 2: Rising = no cap, Storm 70, Fog 50, Hive 30, otherwise 10.
   - **Sequence:** R1/R2/R3, with the random "instead" move, the nap (overwrites status, 1–7 turns), the "won't obey" plus self-hit, and the four loaf lines.
   - **Gen 2's asleep case:** Snore or Sleep Talk while asleep prints "ignored orders…sleeping!".
   - **Lines:** printed as the referee's own `msg` lines in the cart's English. There is no new event kind.
   - **Badges sent:** Red clients also send CASCADEBADGE, RAINBOWBADGE, MARSHBADGE and EARTHBADGE.
9. **Gold held items** (new), per pokecrystal, in the cart's between-turn order:
   - **Speed and accuracy:** Quick Claw (60/256 within the bracket), Bright Powder (accuracy −20, Swift exempt).
   - **Damage:** the 17 type-boost items ×110/100 plus Pink and Polkadot Bow; Scope Lens; Lucky Punch and Stick (crit level *set* to 2); Light Ball, Thick Club and Metal Powder with their quirks.
   - **After a hit:** Focus Band (rolls on every hit), King's Rock (only after moves whose script ends in `kingsrock`: a static effect list in the referee).
   - **Recovery:** Leftovers; Berry, Gold Berry and Berry Juice (heal at 2·HP < max, consumed); the status berries (cure right after infliction and at end of turn, consumed); Bitter Berry; Mysteryberry (+5 PP).
   - **Other:** Berserk Gene (start of turn, Attack +2, 256-turn confusion bug); Thief, both ways, with Mail unstealable.
   - **Outside the fight:** Smoke Ball always flees a wild fight in Gold solo; Amulet Coin doubles the prize. Lucky Egg and Exp Share already exist client-side.
   - **Turn hygiene:** `mon.flinch` is now cleared at turn open.
   - **Persistence:** items consumed or stolen against the computer are written home. **PvP fights never write home** (owner decision).
10. **Gen 3 item theft** (pokeemerald `MOVE_EFFECT_STEAL_ITEM`, `Cmd_tryswapitems`, and pokefirered's): a side-b attacker in a non-link mode (wild, coop_wild, coop_npc) steals nothing with Thief or Covet, and its Trick fails. Knock Off is unchanged. Items the player steals are kept.
11. **Gen 3 asleep disobedience is covered live.** An e2e leg with a non-event Mew (`unfateful`), asleep, using Snore, deterministically reaches `ignores_asleep`.
12. **Twins and parity.** Every referee change is twinned Lua↔Node, with parity scenarios. Each existing expectation that changes is listed and explained. All suites, both hubs and the full e2e matrix pass.

## 2. Context & constraints (Phase 1 findings)

The pret evidence is in the five research briefs, summarised here with anchors to the copies in `<scratchpad>/pret/`. Engine paths are relative to `~/Projects/alamops/gen1recomp`.

- **Gen 1 sim today** (`src/BattleSim/Turn.lua`, mirrored in `server/lib/battle/Turn.js`):
  - Damage runs `badgeBoost` → `applyStage` → read-time burn → Explosion → `Damage.compute`, at `:2672-2712`.
  - A crit only doubles the level term.
  - Screens halve the final damage after the fixed-damage branch (`Effects.screenDamage`, `:2716`).
  - Speed runs badge → stage → paralysis (`_speedOf` `:1737`).
  - The self-hit (`_runGates` `:2295`) applies the badge only.
  - Stages are never reset on switch or faint. `Effects.applyStage` has no clamp.
  - No priority. No obedience.
- **Gen 2 sim** (`src/BattleSim2/Turn.lua`): the same shape, at `:2722-2775` and `:1774`.
  - No truncation and no priority.
  - `STRUGGLE` is a type-0 row given STAB and effectiveness.
  - `struggling = allPpEmpty(mon)` is recomputed when Metronome recurses (`:2565-2596`).
  - No held items: `copyMon :299` drops `heldItem`, Thief is plain damage, and there is no `held` event.
- **The Gold engine port diverges from pokecrystal** in several places; pret wins:
  - badge order;
  - the crit stage rule (it uses Gen 3's);
  - screens on a crit;
  - the between-turn order;
  - Focus Band only on lethal hits;
  - berries curing at end of turn only;
  - Lucky Punch and Stick being additive.
- **The Gen 1 engine port** models the badge glitch with a count model behind the `badgeBoostReapplyBug` flag. We port the cart's stored-stat model instead, because it reproduces the rounding and caps exactly.
- **Client:**
  - The Gen 1/2 sheet (`MediatedBattle.snapshotMons :832-910`) has no OT or traded field. Gen 2 sends `heldItem` (a string), which is inert today.
  - `applyHeld`, `ownItemSet` and `ownItem` are numeric-only, so effectively Gen 3 only.
  - `Wire.battleEvent` drops `held` for Gen 1/2.
  - Solo feeds raw events to the screen.
  - `LINK_MODES` = 1v1, coop_pvp. `KEEPS_HELD_MODES` = wild, coop_npc, coop_wild.
  - Hubs refuse any PROTOCOL other than 30, so 1.4.x clients never meet these additions.
- **Gen 3 theft today:** `src/BattleSim3/Effects.lua` `:405-421` (steal), `:1749-1773` (Trick), and their JS twins, ungated ("a mediated fight is a link fight").
- **Foe items on Gold:** the engine gives trainer and wild mons no held items (`Mon.lua:525` "not modeled"; the trainer data has no item field). Trainer items would need an engine importer change (Lane B). Wild items are rolled by the client (23% item 1, 2% item 2) **only if** the engine's species data carries the two item ids; otherwise the gap is recorded (§9).

## 3. Approach & key decisions

1. **Gen 1 uses a stored-stat model:** `mon.cur = {atk, def, spd, spc}`, plus `partyStats` for crits. It is seeded at create and at switch-in, rewritten by stage changes and Haze, and read by speed, damage and the self-hit. This is the cart's own data flow, so the glitches fall out exactly. **Rejected:** the engine's count model, because its rounding differs.
2. **Gen 2 stays read-time**, in the cart's order. This is equivalent because pokecrystal rebuilds from raw every time; the Baton Pass quirk is moot because Gen 2 has no Baton Pass in the referee.
3. **Gen 2 held items follow Gen 3's precedent.**
   - The sheet carries the item's effect token and parameter from the engine's item data, and the referee holds no item table (no ROM-derived values).
   - The referee keeps a static `HELD_*` rule module (`BattleSim2/Items.lua` ↔ `battle2/Items.js`) plus the id-keyed items (LIGHT_BALL, THICK_CLUB, METAL_POWDER, LUCKY_PUNCH, STICK, BERSERK_GENE, AMULET_COIN, SMOKE_BALL…).
   - King's Rock eligibility is a static effect-id list in the referee: the pokecrystal scripts ending in `kingsrock`.
4. **The Gen 2 `held` event** is `{slot, side, mon, text = <item id>, amount = 1 still held | 0 gone}`, followed by a `msg` with the cart's sentence. It goes in a Gen 2-only table, `BATTLE_EVENTS2`, in Wire and sanitize (Gen 1 keeps its exact vocabulary mirror).
5. **Gen 1/2 obedience emits `msg` lines only.** The Gen 1/2 screens have no text pack and already print the referee's English. The status (nap) and damage (self-hit) events already play.
6. **No PROTOCOL bump.** 30 is unreleased, and both hubs refuse 29.
7. **Cart freezes are never reproduced.** The 1024 divisor is clamped to at least 1. A wrap that the cart survives is reproduced.

### Contracts

- **K1 (Gen 1/2 mon sheet):** `traded = true | absent`.
  - Set only on the player's own non-link sheets.
  - True when the mon's 16-bit OT id differs from `save.player.id`; a nil OT id means absent.
  - Wire and sanitize accept it in the Gen 1/2 dialect: `true` is kept, `false` is dropped, anything else refuses the sheet. `copyMon` keeps it in all four referee files.
- **K2 (Gen 2 mon sheet):** these fields are added next to `heldItem` (string id):
  - `holdEffect`: the HELD_* token, e.g. `"HELD_LEFTOVERS"`, a string ≤ 32 characters;
  - `holdParam`: 0..255;
  - `itemName`: display text ≤ 12 characters;
  - `mail`: `true` or absent.

  They come from the engine's item data at sheet-build time, and are absent when no item is held. Wire and sanitize accept them in the Gen 2 dialect only.
- **K3 (Gen 2 event):** `held` as in decision 4. `BATTLE_EVENTS2 = { held = true }` (Wire) and `BATTLE_EVENT_TYPES2` (sanitize). Gen 2 readers accept it, and Gen 1 and Gen 3 readers don't. `twin_parity` pins it.
- **K4 (Gen 1 badges):** `Mediated.badgesOf` also sends CASCADEBADGE, RAINBOWBADGE, MARSHBADGE and EARTHBADGE in the same id style as BOULDERBADGE. Non-link modes only, as today.
- **K6 (Gen 2 cart lineage, added in wave 2):** a Gen 2 side entry may carry `family = "gs" | "crystal"`. Both hubs stamp it on human seats from the hello `version` they admitted (gold/silver → `gs`, crystal → `crystal`), as they already stamp Gen 3's `family`; it is never read off the wire. Solo stamps `Gen.family()`. The Gen 2 referee reads side a's first fighter (absent → `gs`) for the one rule the carts disagree on: `TruncateHL_BC` loops on Crystal outside link battles and folds once on Gold/Silver in every battle (pokegold `engine/battle/effect_commands.asm:2625` has no loop). Every held-item routine was diffed between pokegold and pokecrystal and is identical.
- **K5 (obedience lines):** the referee's `msg` text, in the cart's English (pokered `text_2.asm`, pokecrystal `data/text/battle.asm`), with the mon's name filled in.

## 4. Work breakdown — implementation tasks

| ID | Goal | Owns (exclusive) | Wave | Acceptance |
|---|---|---|---|---|
| G1a | Gen 1 referee: stored stats and both glitches; stage resets; `applyStage` clamp; crits (party stats, Focus Energy chain); screens; damage tails; self-hit | `src/BattleSim/*`, `server/lib/battle/*`, `tests/battle_sim_*.lua`, `server/battle_*.test.js` (Gen 1 only), `tests/fixtures/battle_turn_parity.json`, `tests/fixtures/battle_sim_vectors.json`, `tests/drivers/battle_turn_parity.lua` | 1 | §1 items 1–5 for Gen 1, with parity scenarios for each glitch trigger and reset, crit with stages/badges/burn/screens, screens fail/Haze/switch, 1024 wrap, Explosion order, 997 cap, self-hit Reflect quirk. Changed expectations listed. |
| G2a | Gen 2 referee: stat order; crit rule; truncation; screens per side; damage tails; self-hit quirks; typeless Struggle; Metronome recoil; move priority (Gen 2) | `src/BattleSim2/*`, `server/lib/battle2/*`, `tests/battle_sim2_*.lua`, `server/battle2_*.test.js`, `tests/fixtures/battle2_turn_parity.json`, `tests/fixtures/battle_sim2_vectors.json`, `tests/drivers/battle2_turn_parity.lua` | 1 | §1 items 1–7 for Gen 2. |
| G3t | Gen 3 theft gate (both twins) | `src/BattleSim3/Effects.lua`, `server/lib/battle3/Effects.js`, `tests/fixtures/battle3_turn_parity.json`, `docs/plans/gen3-battle-sheet.md` | 1 | Side-b Thief/Covet steal nothing and side-b Trick fails in BADGE_MODES; PvP is unchanged. Parity scenarios added. |
| W | Wire / sanitize / parity: K1, K2, K3 | `src/Wire.lua`, `server/lib/sanitize.js`, `server/twin_parity.test.js`, `tests/drivers/hub_protocol_parity.lua`, `server/hub_protocol_parity.test.js`, `tests/fixtures/hub_protocol_parity.json` | 1 | The new fields and kind are accepted per dialect and refused elsewhere; parity cases added; the fixture is regenerated. |
| G1b | Gen 1 referee: priority (+1 Quick Attack, −1 Counter); obedience; Metronome/Mirror Move recoil; `badgeRules` / `traded` | same files as G1a | 2 | §1 items 6–8 for Gen 1. |
| G2b | Gen 2 referee: held items (all of §1 item 9 that lives in the referee, Thief included); obedience (incl. asleep); flinch clear; `heldItem` / `holdEffect` / `holdParam` / `traded` kept by `copyMon` | same files as G2a, plus new `src/BattleSim2/Items.lua` and `server/lib/battle2/Items.js` | 2 | Parity scenarios for every item and obedience branch. |
| C | Client | `src/MediatedBattle.lua`, `src/CoopBattle.lua`, `src/SoloBattle.lua`, `src/Coop.lua` | 2 | <ul><li>K1 `traded` stamping (own, non-link) for Gen 1/2.</li><li>K2 item data on Gen 2 sheets, and the Gen 2 wild held-item roll if the species data allows it.</li><li>K4 badges.</li><li>Gen 2 `held` → `applyHeld2` (string ids, `ownItemSet2`, own seats only, KEEPS_HELD_MODES only) on both screens, solo included.</li><li>Smoke Ball in Gold solo escape; Amulet Coin in the Gen 2 prize path (solo and co-op).</li></ul> |
| D | Docs | `CHANGELOG.md`, `README.md`, `mod.card`, `docs/plans/*` (other than the sheet doc), the BattleSim/BattleSim2 header notes | 3 (me) | Added/Fixed entries; "Gen 1/2 wire reads byte-identical to 1.4.19" reworded; engine-port divergences listed; ledgers updated. |

## 5. Work breakdown — test tasks

| ID | Covers | Owns | What |
|---|---|---|---|
| TT-R | G1a/G1b/G2a/G2b/G3t | (inside the referee tasks) | Parity scenarios and vectors are the spec. Cross-check numbers against pret by hand and against the engine ports where they agree. |
| TT-C | C, W | `tests/mediated_battle_client.lua`, `tests/coop_mediated.lua`, `tests/solo_battle.lua`, `tests/hub_battle.lua`, `server/hub_battle.test.js`, `tests/rby_mmo_test.lua` (Gen 1/2 sections) | Traded stamping; the Gen 2 item sheet; `held` write-back per mode (solo and co-op write; PvP doesn't; partner seats aren't written); Smoke Ball; Amulet Coin; Gen 1 badges sent; hub pass-through. |
| TT-E | live | `tests/drivers/solo_battle_e2e.lua`, `tests/drivers/mmo_util.lua`, Gen 2 co-op drivers if needed | **Red solo:** a traded L50 mon disobeys with the cart's lines, and with EARTHBADGE it obeys; Quick Attack moves first. **Gold solo:** obedience, including Snore while asleep; Leftovers heals; a Berry is eaten and the save loses it; Quick Claw moves first; Thief by the foe takes the item and it is gone after the fight. **Gold co-op PvP (if a Gen 2 co-op leg exists):** an eaten berry is restored. **Gen 3:** a non-event Mew asleep with Snore gives `ignores_asleep`; a wild Thief user steals nothing. Screenshots. |

**e2e applies.** Recipe:
- **Engine view:** `$SP/e2e-engine` (vsync 0).
- **Gold and Red:** `run-solo-battle-e2e.sh --both`.
- **Gen 3:** `--gen3`.
- **Gold co-op:** `run-mmo-e2e-gen2.sh`.
- **Full matrix:** `final_run.sh`.

## 6. Execution waves

- **Wave 1:** G1a ∥ G2a ∥ G3t ∥ W. Then a barrier, the suites, and a commit.
- **Wave 2:** G1b ∥ G2b ∥ C. Then a barrier, the suites, and a commit.
- **Wave 3:** D.

After that: review (3 reviewers: the Gen 1 referee, the Gen 2 referee, client/wire), then TT-C ∥ TT-E, then the full matrix, then fixes.

## 7. Blast radius & risks

- **Gen 1/2 damage and turn order change in every fight, PvP included.** That is intended (cart rules). Existing parity expectations that move are listed per scenario. Known ones: Gen 1 `badges_npc` (the crit ignores badges), Gen 2 `badges_npc` and `badges_gold` (truncation and the crit rule), the Gen 1 Focus Energy vector (96 → 100), the Gen 2 Struggle damage tests (STAB removed), and the Reflect and badge tests (re-checked).
- **Hubs:** they pass sheets through. The new fields reach the referee in co-op and PvP; held items act in PvP but are never written home.
- **RNG draw order:** new draws happen only when an item, obedience or a bracket tie calls for them. Fights with no items, no traded mons and no priority moves draw exactly as before, with three intended exceptions, all cart order: on Gold, a flinched sleeping or frozen mon now draws its status gate first; a move called by METRONOME or MIRROR MOVE no longer runs the gates a second time (both gens); and Gold's paralysis gate moves after confusion (review fix).
- **Gold save write-back:** consumed and stolen items reach the save only in KEEPS_HELD_MODES and only for the client's own seats.

## 8. Open questions / assumptions

- **Wild held items on Gold** depend on the engine's species data carrying the item 1 and item 2 ids. C checks this and implements it, or records the gap.
- **Gen 1/2 obedience lines are the referee's English.** Cart-exact wording is copied from pret's text files, not read from the player's ROM (Gen 1/2 screens have no text pack).
- **The stale `wCriticalHit` on Gen 2's enemy confusion path is not modelled.** It is unreachable in practice (research §5).

## 9. Completeness ledger

| Candidate | Disposition |
|---|---|
| The six listed items | **in this run**: G1a/G2a/G1b/G2b/G3t/TT-E |
| Gen 1/2 crits and screens | **in this run** (owner): G1a/G2a |
| Gold held items, Thief, Smoke Ball, Amulet Coin | **in this run** (owner): G2b/C/W |
| Move priority, Gen 1/2 | **in this run** (owner): G2a/G1b |
| Stages never reset on switch-in or faint; `applyStage` has no clamp | **in this run**: G1a/G2a (blocks the glitch model) |
| `mon.flinch` never cleared at turn open | **in this run**: G2b (King's Rock exposes it); G1a checks Gen 1 too |
| Explosion order, 997+2 cap, 1024 wrap | **in this run**: G1a/G2a (the same damage block) |
| Gold PvP item persistence | **owner decision**: never written home |
| Gold trainer held items | **out of scope**: the engine's trainer data has no item field. An engine importer change (Lane B, an upstream RFC) |
| Gen 2 Baton Pass badge-loss quirk | **out of scope**: the Gen 2 referee has no Baton Pass |
| Stale `wCriticalHit` (Gen 2 enemy confusion) | **out of scope**: unreachable on the cart's normal command lists |
| A co-op joiner can't keep an item it steals from host-described NPCs (the `ownItem` guard) | **out of scope**: anti-forgery design; documented |
| Engine-port divergences from pret (Gold badge order, crit rule, screens on crit, between-turn order, Focus Band, berries, Lucky Punch) | **in this run**, documented only (D). An upstream report, not a mod change |
| Gold/Silver vs Crystal `TruncateHL_BC` (found by G2a) | **in this run**: K6, G2b + C |
| Gen 1 flinch-reset skip while the player's mon rages or recharges (pokered MainInBattleLoop) | **in this run**: G1b, side a of BADGE_MODES; link modes reset unconditionally |
| Co-op callouts parsed "used instead, X" as the move "instead, X" | **in this run**: C |
| Pre-existing referee gaps found on the way (Transform on switch-out, Gen 1 Haze side effects, the computer's 25% stat-down miss, ClearHyperBeam, self-hit into a Substitute, item/switch turn slots, Pay Day on Gen 1/2, RNG low bits, modded Gold priority moves, and the smaller rows) | **out of scope**: each is its own ticket; listed with code pointers in `docs/plans/gen12-referee-known-gaps.md` |

## 10. Where the referee follows pret over the engine ports

These are differences in Gen1Recomp's own battle code (`src/battle/` and `src/battle/gen2/`), not in this mod. They are recorded here for an upstream report; the mod's referees follow pret.

**Gen 1 (`src/battle/`):**

- **Badge stacking:** the port counts re-applications (`badgeBoostReapplyBug`) and applies them at read time as stage → badges×n → penalty; the cart writes stored values in event order, so rounding differs (paralysed Speed 61: 15 → 16 on the cart, 68 → 17 in the port).
- **Re-penalty:** the port counts `statusPenaltyStacks` and applies them after badges at read time; the cart writes them at each event.
- **999/1 walls:** the port's `changeStage` has neither wall nor the one-step wind-back.
- **Crit stats:** the port reads `curStats` at both ends; the cart reads the party struct for the attacker and `GetEnemyMonStat` for the defender.
- **Stat scaling:** the port floors both scaled stats at 1 and never wraps; the cart keeps the low byte.
- **Haze:** the port suppresses badges and penalties with a `hazeStatReset` flag; the cart copies the unmodified stats over.
- **Obedience:** the port has no Gen 1 disobedience at all.

**Gold (`src/battle/gen2/`):**

- **Stat order:** the port boosts badges before stages; pokecrystal `CalcPlayerStats` applies stages, then badges.
- **Crits:** the port uses Gen 3's rule (drops the attacker's negative and the defender's positive stages). The cart keeps both stages only when the defender's is strictly lower than the attacker's, and otherwise uses the raw stats.
- **Screens:** the port drops screens on any crit; the cart keeps them on the boosted crit path.
- **Between-turn order and berries:** the port's order differs from `HandleBetweenTurnEffects`, and its status berries cure only at end of turn (the cart also cures right after infliction). Its berry threshold is `2·HP ≤ max`; the cart's is strict `<`.
- **Focus Band:** the port rolls only on lethal hits; the cart rolls on every hit.
- **Lucky Punch / Stick:** the port adds 2 crit stages; the cart sets the level to 2.
- **Bright Powder:** the port applies it before stages with a floor of 1; the cart applies it after, and it can reach 0%.
- **Berserk Gene:** the port always uses 256 turns; the cart inherits the seat's leftover confusion count.
- **Healing items:** the port asks side a first; the cart's routines act on the battler opposite the current turn, so side b goes first.
- **Missing items and moves:** the port has no Light Ball, Thick Club, Metal Powder or Mysteryberry, and its Thief steals nothing.
- **Item lines:** the port prints "restored health!" and "ate the BERRY!"; the referee uses the cart's sentences.
- **Amulet Coin:** the port tests the item id; pret's `CheckAmuletCoin` tests the HELD_AMULET_COIN effect.
- **Wild held items:** the port gives wild mons none (`Mon.lua:525`); pret rolls them in `LoadEnemyMon .WildItem` (192/256, then 20/256).
- **High crit:** the port decides it by `def.effect == "EFFECT_ALWAYS_CRIT"` (`src/battle/gen2/Battle.lua:1167,1184`), an effect neither cart has, so offline Gold fights never use the high-crit rung; the carts look the move up in `CriticalHitMoves`.
- **Effect chance:** the port rolls `rand(100) < effectChance` (`Battle.lua:2012`); the carts compare `BattleRandom` with the byte, including the 1/256 miss at 100%.
- **Rage:** the port gives the rager +1 Attack per hit (`src/battle/gen2/Battle.lua:1372-1375`); pokecrystal / pokegold build a counter (`BattleCommand_BuildOpponentRage`) that multiplies RAGE's damage (`BattleCommand_RageDamage`).
- **Priority values:** the port uses relative values (+1 / +3 / −1) that order the same way; the referee uses the cart's raw `GetMovePriority` numbers.
