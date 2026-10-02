# Plan — Badge rules: Gen 3 boosts and obedience against the computer, link rules in PvP everywhere

| Field | Value |
| --- | --- |
| Date | 2026-10-01 |
| Source | "implement for gen 3" on gap #6 of `docs/plans/gen3-known-gaps.md` |
| Config | AGENTS_CONFIG.yml (quality preset, host `claude_code`) |
| Flags | none |
| Gates | grilled + approved by owner |
| Branch | `feature/firered-and-emerald-support` (unpushed, 1.5.0) |
| Base SHA | `306c9a0` (set in Phase 4) |

## 1. Objective & success criteria

The goal is to apply the carts' badge rules everywhere the cart would, and nowhere it wouldn't:

- **Gen 3 against the computer** gets **badge stat boosts** and **obedience**. This covers solo wild and trainer fights (singles and lone doubles), and co-op against an NPC or a wild POKéMON, on the in-game host and on the Node hub.
- **Every generation's player-vs-player fights** (`1v1`, `coop_pvp`) use link rules: no badge boosts and no disobedience. Gen 3 never had boosts there. Gen 1 and Gen 2 do today, which is the bug the owner asked us to fix too.

Done means:

1. **Boosts.** Each boost is ×1.1, rounded down:
   - badge 1 → Attack;
   - badge 5 → Defense;
   - badge 7 → Sp. Atk and Sp. Def;
   - badge 3 → Speed.

   They apply only to the player's side, the same on FireRed/LeafGreen and Emerald. Placement follows the engine:
   - **In damage:** after Huge Power / Pure Power and before held items and stat stages.
   - **In speed:** after weather and the stage, before Macho Brace and paralysis.

   Escape odds keep raw speed. A confusion or disobedience self-hit carries the boosts as the cart's does.
2. **Obedience.** It follows the engine's `Engine.disobedient`:
   - **Who it can affect:** only a traded mon (OT id or OT name differs from the player's).
   - **Level caps:** 10 with no badges; 30 with badge 2; 50 with badge 4; 70 with badge 6; no cap with badge 8.
   - **Mew and Deoxys:** without their fateful-encounter bit, they always disobey with cap 0.
   - **Below the cap:** a mon at or below it obeys without any RNG draw.
   - **Above the cap:** the cart's roll sequence (loaf lines, ignoring orders while asleep, calling another move, falling asleep, the typeless 40-power self-hit) in the engine's order and RNG draws.
   - **Focus Punch:** exempt on FireRed/LeafGreen, not on Emerald.
3. **Per-player badges.** Each human brings their own badges and traded flags (both seats of a solo double, each player in co-op). The foe side never gets either.
4. **The referee gates it, not the client.** The referee applies none of this in `1v1` / `coop_pvp` or to side b, whatever a client uploads. Clients also stop sending badges in link modes.
5. **No new protocol version.**
   - Badges travel as badge-number strings (`"1".."8"`) in the existing `badges` field, which the sanitisers already pass.
   - The per-mon `traded` / `fateful` flags and the obedience event are additions to the unreleased Gen 3 dialect (PROTOCOL 30).
   - Gen 1/2 lose PvP boosts hub-side, with no wire change.
6. **Nothing else moves.** Every existing parity / vector expectation holds unless it is a Gen 1/2 PvP case that carried badges, and each such change is explained. Headless suites, both hubs and the e2e matrix pass. The new behaviour is proven live on FireRed and Emerald.

## 2. Context & constraints (Phase 1 findings)

**The engine's rule** (`~/Projects/alamops/gen1recomp/src/core/game3/battle/`):

- **`Engine.hasBadge`** (`engine.lua:166-192`): false in link; FRLG reads `Flags.hasBadge`; Emerald reads `BattleProfile.badgeFlags`.
- **Damage** (`damage.lua:190-217`): the badge step runs after Huge Power (205) and before the items (218-265). Stages are applied later (276/302). It boosts the player-side attacker (badges 1, 7) and the player-side defender (badges 5, 7). Emerald also excludes the e-reader, secret base, frontier and recorded-link fights; all are already refused in solo.
- **Speed** (`engine.lua:203-232`): weather → stage → badge 3 → Macho Brace → paralysis → Quick Claw.
- **Obedience** (`engine.lua:1276-1349`, called at 1475-1490 after the PP-zero check):
  - `isTradedMon` compares otId and otName;
  - `obedienceFocusPunchExempt` is set in `profile.lua:34` (FRLG true) and `profiles/emerald/battle.lua:39` (false);
  - the Mew/Deoxys rule at 1299 is not profile-gated (see §8).

**The mod's Gen 3 referee** (`src/BattleSim3` ↔ `server/lib/battle3`, twins):

- **No boosts.** `Damage.lua:260` and `Damage.js:329` are comments only. So are `Field.lua:99` (speed is `M.speed`, 106-124), `Move.lua:21` and `Turn.lua:86`.
- **No obedience code at all.** `Damage.lua:580` and the generic `selfHitBase` are all there is.
- **Badges never reach a battler.** Fighters are built at `Turn.lua:513` / `Turn.js:554`; `_newBattler` is at `Turn.lua:374` / `Turn.js:379`; `entry.badges` is never read.
- **One speed path.** Every speed read goes through `Bm:_speedOf` → `Field.speed`.
- **Every damage path uses `Damage.base`:** `calc`, `selfHitBase`, Future Sight and Spit Up.
- **Mode sets.** The non-link modes are `wild`, `coop_wild` and `coop_npc` (as `EXP_MODES`, `Turn.lua:1972`). The link modes are `1v1` and `coop_pvp` (as `Mediated.LINK_MODES`, `MediatedBattle.lua:1736`).
- **Fixtures.** No fixture or vector carries badges today. There are 61 turn scenarios: 26 coop_npc, 4 wild, 2 coop_wild.

**The data path:**

- **Solo.** `SoloBattle.gen3Badges` (`:3041-3059`) returns a set `{[n]=true}`, and `_begin3` (`:2620-2632`) passes it on side a.
- **Hub clients.** `Mediated.badgesOf` (`MediatedBattle.lua:984-989`) returns nil on Gen 3 by design. Its callers are `MediatedBattle:start` (`:2609`), `CoopBattle:uploadMediated` (`:9949`) and `newSoloDouble`'s `start` (`:13749`).
- **Sanitisers.** `Wire.badges` (`:878`) and `sanitize.js cleanBadgeSet` (`:922`) take string ids matching `^[%w_%-]+$`, so `"1".."8"` already pass.
- **Hubs.** Both copy `party.badges` into the fighter entry with no generation or mode gate (`Hub.lua:1956`, `:1631`; `relay.js:3537`, `:3219`).
- **Traded.** `Sheet3.lua:521` carries `otId`; `Exp3.traded(mon)` (`Exp3.lua:162`) already decides traded client-side.

**Gen 1 / Gen 2:**

- **Who gets boosted.** `Effects.badgeBoost` (×9/8; BattleSim2 `Effects.lua:346-352`, BattleSim similar) applies to any fighter carrying `badges` (`copyBadges`, `Turn.lua:446/622`), with no mode gate. Clients upload badges in every mode, so mediated `1v1` / `coop_pvp` are boosted. The carts' link battles never boost: Gen 1 skips the badge step in link battles, and Gen 2's `BadgeStatBoosts` returns early in link mode. Only the legacy host-built co-op path strips badges for player-vs-player (`Coop.lua:2626-2650`).
- **Obedience.** No generation's referee has obedience code.

**E2e:**

- **Setting a badge:** `H.g3SetFlag(game, "FLAG_BADGE0n_GET", true)` (`mmo_util.lua:4005`) resolves the flag per cart.
- **Reading the result:** `solo.sim` is live (`_speedOf`, snapshots, events), and `solo.seedFn` fixes the RNG so a with/without comparison is deterministic.
- **Co-op:** the in-game host driver can read the hub's referee.

## 3. Approach & key decisions

1. **The referee owns the rule.**
   - **Where badges land.** `Turn.create` copies `entry.badges` onto side-a fighters only in non-link modes. It normalises a list or a set, with string or number keys, to `{[n]=true}` for n in 1..8; everything else is dropped. `_newBattler` sets `b.badges`.
   - **Who reads them.** `Damage.base` and `Field.speed` read `b.badges`, so no new options thread through, and vectors express badges on the battler spec.
   - **Obedience** is `Bm:_disobey` in `Move.run`, after the PP-zero check, reading `b.mon.traded`, `b.mon.fateful` and `b.badges`.
   - **Why the referee.** A hostile client can't buy boosts in PvP, and solo and both hubs share one rule.
   - **Rejected:** gating only on the client or the hub, which can be forged or drift.
2. **The wire stays as it is.**
   - **Badges:** a list of badge-number strings in the existing `badges` field.
   - **Traded / fateful:** the Gen 3 mon sheet gains `traded` and `fateful`, both `true` or absent. They are sanitised in the Gen 3 dialect of both sanitisers and kept by `copyMon` in both twins.
   - **The new event:** obedience emits one new Gen 3 event kind. **R3 defines it** (shape, reasons, field names, documented in `gen3-battle-sheet.md` §7), and the screens and sanitisers render and accept it in wave 2. Rejected: reusing a free-text `msg`, because the cart prints a fixed set of lines and the screens phrase events themselves.
3. **Clients send badges only where they count.** `Mediated.badgesOf(game, mode)` returns the Gen 3 list only for non-link modes, and Gen 1/2 also return nil for link modes. Solo uses the same helper. The referee gate makes this belt and braces.
4. **Gen 1/2 PvP fix:** `BattleSim` and `BattleSim2` (and their Node twins) ignore `badges` in `1v1` / `coop_pvp`, which is the same create-time gate. Fights against the computer are unchanged.
5. **Cart fidelity comes from the engine**, which cites pret; no pret source is local. Every formula and the RNG order are ported from the engine. Any spot where the engine may differ from pret goes in §8 rather than being guessed.

### Contracts

- **K1 (side entry).**
  ```lua
  { playerId, ..., badges = { "1", "3", "7" } }
  ```
  - The referee also accepts `{ [1] = true }` and numbers.
  - It applies badges only on side a in `wild`, `coop_wild` and `coop_npc`.
- **K2 (Gen 3 mon sheet).**
  - `traded = true | nil`: the OT id or OT name differs from this player's.
  - `fateful = true | nil`: the mon's fateful-encounter bit. It is read only for Mew (151) and Deoxys (410).
- **K3 (obedience event).** R3 defines it and documents it in the sheet doc §7. C3b renders it with the cart's own lines, in the cart's order.

## 4. Work breakdown — implementation tasks

| ID | Goal | Owns (exclusive) | Wave | Acceptance |
|---|---|---|---|---|
| R3 | **The Gen 3 referee, both twins.** Boosts, obedience, the K1/K2/K3 contracts, parity scenarios and vectors, the sheet doc. | `src/BattleSim3/*.lua`, `server/lib/battle3/*.js`, `tests/fixtures/battle_sim3_vectors.json`, `tests/fixtures/battle3_turn_parity.json`, `tests/battle_sim3_vectors.lua`, `tests/battle_sim3_turn.lua`, `server/battle3_*.test.js`, `docs/plans/gen3-battle-sheet.md` | 1 | <ul><li>Boost math and placement match the engine (vectors for each badge and stat, with Huge Power and with Choice Band).</li><li>Speed order flips with badge 3.</li><li>Obedience: caps by badge count; the Mew/Deoxys rule; no RNG at or under the cap; each outcome branch; the Focus Punch exemption per family.</li><li>`1v1` / `coop_pvp` and side b ignore badges and traded mons.</li><li>Existing expectations are unchanged. Lua and Node agree.</li></ul> |
| R12 | **The Gen 1/2 referees, both twins.** Ignore `badges` in `1v1` / `coop_pvp`. | `src/BattleSim/*.lua`, `src/BattleSim2/*.lua`, `server/lib/battle/*.js`, `server/lib/battle2/*.js`, their fixtures and runners (`tests/fixtures/battle_sim*_…`, `tests/battle_sim_*.lua`, `tests/battle_sim2_*.lua`, `server/battle*_….test.js` other than battle3) | 1 | <ul><li>A PvP scenario with badges deals the unboosted damage and takes the unboosted turn order.</li><li>The same scenario against the computer is still boosted.</li><li>Every changed expectation is listed and explained.</li></ul> |
| C3a | **The Gen 3 client data.** | `src/Gen3.lua`, `src/Sheet3.lua`, `src/MediatedBattle.lua`, `src/CoopBattle.lua`, `src/SoloBattle.lua`, `src/Wire.lua`, `server/lib/sanitize.js` | 1 | <ul><li>A Gen 3 badge-list helper (in `Gen3`, preferring `Space.store`, like the engine).</li><li>`Mediated.badgesOf(game, mode)`: Gen 3 list in non-link modes, nil in link modes, and nil in link modes for Gen 1/2 too.</li><li>Every caller passes its mode: `MediatedBattle:start`, `CoopBattle:uploadMediated`, `newSoloDouble` start, `SoloBattle._begin3`.</li><li>Sheet3 sets `traded` (via `Exp3.traded`) and `fateful`.</li><li>`Wire.battleMon` and `sanitize.js` accept `traded` / `fateful` in the Gen 3 dialect.</li><li>Stale comments fixed.</li></ul> |
| C3b | **Render the obedience event.** | `src/MediatedBattle.lua`, `src/CoopBattle.lua`, `src/Wire.lua`, `server/lib/sanitize.js`, `tests/drivers/hub_protocol_parity.lua`, `tests/fixtures/hub_protocol_parity.json` | 2 (after R3 + C3a) | <ul><li>`Wire.battleEvent` and `sanitize.js` accept the K3 event (Gen 3 dialect only).</li><li>Both screens print the cart's line for each outcome, and the self-hit and called-move rows follow.</li><li>Hub parity gains Gen 3 cases for badges, `traded` / `fateful` and the event; the fixture is regenerated.</li></ul> |
| R2b | **Gen 2 (Gold) badge rules, both twins** (added after wave 1: the owner approved it). The Gen 2 referee looked up Gen 1 badge names, so Gold's never matched and Gen 2 computer fights never had boosts. | `src/BattleSim2/*`, `server/lib/battle2/*`, their tests, fixtures and parity driver (+ the Gen 1 999 cap if it is missing) | 2 | <ul><li>BadgeStatBoosts per the Gold engine: Zephyr Atk, Mineral Def, Plain Spe, Glacier SpA plus the buggy SpD tail, 999 cap.</li><li>DoBadgeTypeBoosts: +1/8 for a move whose type's badge is owned, all 16 badges.</li><li>Side a in BADGE_MODES only.</li></ul> |
| H | **Hubs pass each Gen 3 seat's cart family** (wave 1 remainder: the referee's Focus Punch exemption reads `family`, and the hubs never set it). | `src/Hub.lua`, `server/lib/relay.js`, `tests/hub_battle.lua`, `server/hub_battle.test.js` | 2 | <ul><li>Human seats get `family` from their own hello `version` (emerald → rse, else frlg).</li><li>Twins identical; Gen 1/2 unchanged.</li></ul> |
| D | **Docs.** | `CHANGELOG.md`, `README.md`, `mod.card`, `docs/plans/gen3-known-gaps.md`, `docs/plans/gen3-firered-emerald-support.md`, `src/Config.lua` (comment) | 3 (me) | <ul><li>1.5.0 Added: Gen 3 badge boosts and obedience against the computer.</li><li>Fixed: Gen 1/2 PvP no longer gets badge boosts.</li><li>The Known link-rules bullet is rewritten.</li><li>Gap #6 is marked done.</li></ul> |

## 5. Work breakdown — test tasks

| ID | Covers | Owns | What |
|---|---|---|---|
| TT-R | R3, R12 | (inside R3 / R12) | Vectors and parity scenarios; they are the referee's spec. |
| TT-H | C3a, C3b | `tests/gen3_mediated.lua`, `tests/gen3_coop.lua`, `tests/gen3_solo.lua`, `tests/gen3_solo_double.lua`, `tests/hub_battle.lua`, `server/hub_battle.test.js` | <ul><li>`gen3_mediated:614` flips: Gen 3 non-link sends the list, link sends nil.</li><li>Uploads in each mode.</li><li>Solo singles and doubles reach the referee with badges and `traded`.</li><li>Both hubs pass badges through, and the referee ignores them in `coop_pvp` / `1v1`.</li><li>Gen 1/2 hub PvP has no boost.</li><li>The screens render each obedience outcome line.</li></ul> |
| TT-E | live | `tests/drivers/solo_battle_e2e.lua`, `tests/drivers/mmo_util.lua` (helpers), `tests/drivers/mmo_host_gen3.lua` (co-op assertion) | <ul><li>Solo, FireRed and Emerald: set badges 1 and 3 with a fixed seed. The foe's HP after an identical turn, and the move order, differ from the no-badge run exactly as the formula says.</li><li>Obedience: seed a traded L50 mon with no badges. The cart's disobedience lines appear and the fight still ends normally; with badge 8 it obeys.</li><li>Co-op (in-game host): the referee's side-a fighters carry the hosts' badges in `coop_npc`, and none in `coop_pvp`.</li><li>Screenshots of a disobedience line in the arena and in classic.</li></ul> |

**e2e applies.** Recipe:
- **Engine view:** `$SP/e2e-engine` (vsync 0).
- **Solo:** `GEN1RECOMP_ROOT=$V GEN3_GAME=… SOLO_LEGS=… run-solo-battle-e2e.sh --gen3`.
- **Co-op:** `GEN3_LEGS=coop run-mmo-e2e-gen3.sh`.
- **Full matrix:** `final_run.sh`, which also covers the Gen 1/2 PvP regression.

## 6. Execution waves

- **Wave 1** (parallel, disjoint): R3, R12, C3a. Then a barrier and a commit.
- **Wave 2:** C3b. Then a barrier and a commit.
- **Wave 3:** D (me).

After that: review (Phase 5), then TT-H and TT-E in parallel, then run, then fix.

## 7. Blast radius & risks

- **Every Gen 3 hub fight and every solo fight** runs the referee change. The risk is contained because one-seat fighters without `badges` / `traded` behave byte-identically (the existing fixtures). The new branches only fire on fields that never existed before.
- **Gen 1/2 PvP changes in released behaviour.** 1.4.x hubs apply badges in PvP, and this change removes that, so ranked fights get fairer. It is hub-side only, so a mixed client/hub keeps working.
- **Obedience RNG order** must match across the twins and the engine. The parity fixture enforces twin agreement; engine agreement is enforced by porting line by line, citing `engine.lua`.
- **A traded flag is self-reported by the client.** A cheater could only make their own mons obey against the computer. In PvP obedience never applies, so there's no fairness impact.

## 8. Open questions / assumptions

- **The Mew/Deoxys fateful rule.** The engine applies it on all carts (`engine.lua:1299`, not profile-gated). pret FRLG may lack it. **We follow the engine and document it.** That divergence is the engine's, not this mod's.
- **Emerald's exclusions.** It excludes e-reader, secret base and frontier fights from damage boosts but not speed boosts, per the engine. This is moot here, because those fights are refused in solo.
- **Badge reads at the divert moment** prefer `Space.store` when it is a table, as `Engine.hasBadge` does. The session flags are the fallback.

## 9. Completeness ledger

| Candidate | Disposition |
|---|---|
| Gen 3 boosts: solo singles, solo doubles, co-op NPC / wild, both hubs | **in this run**: R3, C3a |
| Gen 3 obedience in the same modes | **in this run**: R3, C3a, C3b |
| Gen 1/2 PvP badge leak | **in this run**: R12 (owner said fix it) |
| Clients still uploading badges in link modes | **in this run**: C3a (`badgesOf(game, mode)`) |
| A hostile side-b upload with badges | **in this run**: R3 / R12 gate side b |
| Hub protocol parity for the new Gen 3 fields and event | **in this run**: C3b |
| Stale comments and docs saying "link rules / badges ignored" (sheet doc :74/:105/:507/:735, `MediatedBattle.lua:53/985`, `SoloBattle.lua:2628`, `Turn.lua:86`, `Move.lua:21`, `Field.lua:99`, CHANGELOG Known, `mod.card`, the support plan :308/:642, known-gaps §6, the Config comment) | **in this run**: R3, C3a, D |
| Gen 1/2 obedience | **out of scope**: owner chose obedience for Gen 3 (gap #6); Gen 1/2 never had it, and it's a different ticket |
| The legacy host-built co-op path (`Coop:buildField`) for Gen 3 | **out of scope**: Gen 3 co-op is always hub-mediated; that path is Gen 1/2 only |
| Gen 2 computer fights never applied badge boosts (Gen 1 names; Gold's type boosts missing) | **in this run**: R2b (found by R12, owner approved) |
| Gen 2 client never sent Kanto badges (it read only `player.badges`) | **in this run**: C3b (`badgesOf` reads both stores, as the engine's `hasBadge` does) |
| The hubs build Gen 3 fighters without `family` (Emerald got FRLG's Focus Punch rule) | **in this run**: H |
| `fateful` sent unless the engine mon's `fatefulEncounter` is explicitly false (the engine ignores nil and never reads `modernFatefulEncounter`) | **in this run** (C3a), documented in the sheet doc §9.1. It follows the engine; a save-imported Mew/Deoxys without the event bit obeys here, where pret may not |
| Thief/Covet/Trick by side b in `wild` / `coop_npc` (pret may forbid an opponent-side steal outside link battles) | **out of scope**: item-theft rules, not badge rules. Unverified (no pret source); reported, a referee-fidelity ticket |
| Gen 1/2 obedience | **out of scope**: unchanged from the plan |
