# Plan — Party vs Wild (`coop_wild`)

| Field | Value |
| --- | --- |
| Date | 2026-08-10 |
| Source | `/implement` conversation — Party vs Wild (auto-join, ordered balls) |
| Config | AGENTS_CONFIG.yml (quality / v3, host=cursor) |
| Branch | `fix/party-wild-encounter` |
| Base SHA | `f9934515733c5eea936a517277b613b1205f071a` (tree had plan docs only before Wave 1) |

## 1. Objective & success criteria

Add a fifth mediated battle mode, **`coop_wild`**: two partied humans vs **one** wild mon.

Success when all of the following hold:

1. **Divert only when partied + partner online on the same map.** Otherwise the grass encounter stays on the **local engine** (solo wild contract unchanged).
2. **No invite / WAIT / ALONE.** The player who steps the encounter tile is host, uploads the wild sheet, and the partner is **auto-pulled** into the mediated fight immediately.
3. **Catch is legal** (unlike `coop_npc` / `coop_pvp`). Both players may choose a ball; a ball choice is the whole turn (no attack the same turn). Balls resolve **before** moves; among ball choices, order is **active-mon speed** (same tie policy as fight speed). First successful catch ends the turn/fight; later balls are not resolved.
4. **Whoever’s ball succeeds keeps the mon.** Outcome attributes a catcher; that client grants into their party. Only one catch can succeed (one wild).
5. **RUN:** either player can flee and end the battle (solo-wild semantics — no mutual consent).
6. **PROTOCOL bump** so older hubs refuse the new mode instead of silent-dropping.
7. **Tests:** Lua BattleSim + hub + Node twins/parity, plus an **e2e** driver path covering auto-join Party vs Wild.

## 2. Context & constraints

### Ground truth (Phase 1)

- Wire modes today: `1v1`, `coop_npc`, `coop_pvp`, `wild` — `Wire.BATTLE_MODES` (`src/Wire.lua` ~1679), mirrored in sanitize / BattleSim `Turn.MODES`.
- Solo `wild` is **protocol-only** (`Sessions:beginWildMediated`, Hub comments ~1252–1285): catch works in sim/tests; **no overworld divert**; **no production caller**.
- Party trainer divert is `screen.pushed` → `kind == "trainer"` → `Coop:onTrainerBattle` (`src/Client.lua` ~2008–2019, `src/Coop.lua` ~508+). Wild is never diverted; partner only gets `mmo.party_event` narration for solo grass.
- Coop battles are always mediated (`Config.MEDIATED_COOP = { coop_pvp, coop_npc }`). Balls fail outside wild modes via `Effects.isWildMode` (substring `"wild"`) — a mode named `coop_wild` already satisfies that check.
- Turn phases: `runs → switches → items → fights` (`Turn.lua` ~1324–1327). Item phase walks **fighter array order**, not speed. Fight phase sorts by speed. Ball XOR fight is already one choice/seat.
- Catch grant lives only on `MediatedBattle:grantCatch` (local `wildCatchMon`); `CoopBattle` `MED_REASONS` omits `catch`. Outcome winners = whole catching side, not thrower.
- Historical plans marked solo wild out of scope for the intermediator product path; **Party vs Wild was never planned** — greenfield.

### Locked owner decisions (Phase 2)

| # | Decision |
| --- | --- |
| Field | 2 humans vs **1** wild |
| Catch attempts | Both may throw; **one** successful catch |
| Ownership | **(a)** whoever’s ball succeeded |
| Same-turn balls | Speed order; **first success ends**; later ball never resolved |
| Partner off-map / offline | **Solo engine wild** |
| Host | Encounter stepper; uploads wild sheet; partner **auto-pulled, no prompt** |
| RUN | Either can flee and end it |
| Mode name | **`coop_wild`** |
| Solo overworld | Stays on local engine; divert only partied + same map |
| Acceptance | Unit/hub/parity **and e2e** |

### Assumptions (not re-asked)

- **PROTOCOL → 18** (new mode in closed `BATTLE_MODES`; older hubs must refuse).
- Ball order key = **active mon speed** (+ existing fight tie-break), not move priority (BattleSim fights ignore move priority today).
- Each player spends **their own** bag balls (existing per-seat bag sheets).
- Ranking: treat like a non-ranked wild / mirror how solo mediated wild / coop_npc non-rank paths behave — no new ranked ladder for catching wildlife unless an existing path already scores wild (it does not).
- Displace the engine wild screen the same family of way trainer divert freezes/replaces the stack once the mediated fight is ready (no WAIT menu).

## 3. Approach & key decisions

**New mode `coop_wild`**, not stretching `wild` or `coop_npc`.

| Concern | Choice | Why |
| --- | --- | --- |
| Seating | Side `a` = 2 memberIds; side `b` = **one** NPC seat | Matches 2v1; `wild` caps `perSide=1`; `coop_npc` uses two NPC seats |
| Catch legality | Rely on `isWildMode` substring + explicit mode in `MODES` | Avoid special-casing trainer coop |
| Item order | Sort **ball** item choices by active speed before resolving; non-ball items keep array order (or follow same sort if cheap) | Owner: “who would attack first” |
| Catcher | Add optional `catcher` (player id) on `mmo.battle_outcome` when `reason=catch` | Grant must not go to the whole side |
| Grant | Shared helper used by CoopBattle (and MediatedBattle if trivial); both clients stash a grantable wild mon / use `caught` sheet with engine rebuild | Partner did not own the engine encounter mon |
| Start path | New `Coop:onWildEncounter` (name TBD) from `screen.pushed` kind `wild`; auto-open hub battle; no invite wire | Distinct from WAIT/JOIN trainer flow |
| RUN | Direct `action=run` like solo wild; no `run_ask` | Owner decision |
| Solo `wild` mode | Leave as protocol/test stub | Owner: no product divert for solo |

Alternatives rejected:

- Reuse `coop_npc` + allow balls — wrong seating (2 NPC) and pollutes trainer rules.
- Stretch `wild` to 2 humans — breaks `perSide=1` assumptions and hub comments; naming would confuse solo stub.
- WAIT/ALONE for grass — owner forbade invite UX.

## 4. Work breakdown — implementation tasks

### T1 — Wire vocabulary + PROTOCOL 18
**Owns:** `src/Wire.lua`, `src/Config.lua` (PROTOCOL + comment + `MEDIATED_COOP`), `server/lib/sanitize.js`, `CHANGELOG.md` (Unreleased notes), `manifest.json` / `mod.card` protocol note if they cite PROTOCOL, `server/twin_parity.test.js` (constant lists only if asserted).
**Does:** Add `coop_wild` to `BATTLE_MODES`; optional outcome field `catcher` (clean via `Wire.id`); bump PROTOCOL 17→18 both sides’ comment blocks; add `coop_wild` to `Config.MEDIATED_COOP`.
**Deps:** none.
**Accept:** sanitize accepts/rejects correctly; twin constant parity green for mode set.

### T2 — Hub seating twins
**Owns:** `src/Hub.lua` (`openMediatedBattle` + any open helpers), `server/lib/relay.js` (same), tiny touch to `tests/fixtures/hub_protocol_parity.json` **only if** regenerating is required by this task’s open path (else leave for test wave).
**Does:** For `coop_wild`: one NPC id; sides `{ a = memberIds (2), b = npcIds (1) }`; host uploads side `"b"` wild party (same upload path as wild/coop_npc host). Refuse open if ≠2 humans when mode is coop_wild (or document host+partner membership from party).
**Deps:** T1 (mode token exists).
**Accept:** hub/relay open record shape matches; existing wild/coop_npc paths unchanged.

### T3 — BattleSim item/ball order + roster
**Owns:** `src/BattleSim/Turn.lua`, `server/lib/battle/Turn.js` (and `MODES` / `perSide` only).
**Does:**
- Register `coop_wild` in `MODES`.
- `perSide`: side `a` allows 2, side `b` allows 1 (or mode-specific caps — do not force 2v2).
- `_resolveItems`: collect ball choices, sort by active-mon speed (+ fight-equivalent tie-break), resolve in that order; abort when `self.result` set (already); on catch, set `finish.catcher = fighter.playerId` (or equivalent) before/with `_finish`.
- Non-wild modes unchanged; solo `wild` still 1v1 seating.
**Deps:** T1 for outcome catcher if sanitizer must allow the field through hub fan-out (hub may pass result opaque — confirm; if outcome is built in sim and sanitized on send, T1 must land first).
**Accept:** two humans both `item`+ball → faster mon’s ball resolves first; success stops second; bag spend only for resolved throws that entered resolve (failed shake still spends — existing rule).

### T4 — Overworld divert + auto-pull (no invite)
**Owns:** `src/Client.lua` (event wiring), `src/Coop.lua` (wild start / auto membership / busy gates).
**Does:**
- On `screen.pushed` with `state.kind == "wild"`: if transport ready, local player has a party partner **online and same map**, divert into mediated `coop_wild` (host = local stepper). Else no-op (engine wild proceeds).
- Open hub battle with `memberIds = { self, partner }`, `mode = coop_wild`, host = stepper.
- Partner client: on `mmo.coop_battle` / battle open for `coop_wild`, enter `CoopBattle` **without** confirm UI; displace any conflicting overworld state safely.
- Do **not** use `mmo.coop_wait` / join invite path.
- Offline / other-map partner → leave engine wild alone (already gated).
**Deps:** T2 (hub can open), T5 for screen class behavior ideally same wave barrier after T5 starts — prefer T5 before or with careful stubs; **wave order: T5 then T4** if CoopBattle must already understand the mode.
**Accept:** headless/unit hooks prove divert predicate; no invite messages on the wire for this path.

### T5 — CoopBattle wild UX / catch grant / run
**Owns:** `src/CoopBattle.lua`, small shared grant helper if extracted (`src/MediatedBattle.lua` only if sharing `grantCatch` without widening ownership — prefer extract to a tiny module **or** duplicate minimal grant in CoopBattle to keep file ownership clean; choose extract `src/CatchGrant.lua` only if both need edits — default: implement grant on CoopBattle + optional thin call from MediatedBattle in a follow-up only if needed).
**Does:**
- Treat `coop_wild` as mediated (already via Config once T1 lands).
- Host uploads wild party sheets to side `b` (from frozen engine encounter mon / snapshot).
- Both clients stash grant material (`wildCatchMon` or rebuild-from-sheet).
- On outcome `reason=catch`: only `catcher` id grants; others see Gotcha narration without adding a mon.
- RUN: no `run_ask`; commit `action=run` like wild.
- `MED_REASONS` / result copy for catch; balls offered in item menu (already) now succeed in sim.
**Deps:** T1–T3.
**Accept:** catcher-only grant; partner flee ends fight for both.

### T6 — Docs index
**Owns:** `docs/plans/README.md` (add this plan under Living).
**Deps:** none (can land anytime).
**Accept:** linked from README Living table.

## 5. Work breakdown — test tasks

### TT1 — BattleSim / turn parity
**Owns:** `tests/battle_sim_turn.lua`, `tests/drivers/battle_turn_parity.lua` fixtures as needed, `server/battle_turn.test.js`.
**Covers:** T3 — dual ball speed order; first catch wins; ball before move; balls legal in `coop_wild`; still illegal in `coop_npc`.
**E2E?** no.

### TT2 — Hub open + choice path
**Owns:** `tests/hub_battle.lua`, `server/hub_battle.test.js`, regenerate `tests/fixtures/hub_protocol_parity.json` if open/catcher paths are in the parity driver (`tests/drivers/hub_protocol_parity.lua` + Node twin).
**Covers:** T2 — `coop_wild` seating (2 humans, 1 npc); catcher on outcome; PROTOCOL 18 handshake refusal sketch if present in suite.
**E2E?** no.

### TT3 — Coop divert / CoopBattle unit
**Owns:** `tests/coop_mediated.lua` and/or `tests/rby_mmo_test.lua` sections for wild divert predicate + catch grant + run-without-consent.
**Covers:** T4–T5.
**E2E?** no.

### TT4 — E2E Party vs Wild
**Owns:** `tests/drivers/run-mmo-e2e.sh` **or** new `tests/drivers/run-party-wild-e2e.sh` + `tests/drivers/mmo_util.lua` barriers/tappers; prefer **dedicated script** mirroring `run-invite-refuse-e2e.sh` pattern so LAN coop trainer e2e stays stable.
**Covers:** two LOVE clients, party formed, same map, force/trigger wild encounter on host, assert hub log `coop_wild` started, both in battle, optional ball/catch or run end.
**Run recipe (from Phase 1):**
- Engine: `~/Projects/alamops/gen1recomp`, mod symlinked `mods/rby_mmo`.
- ROM imported via `scripts/setup.sh --rom "…"`.
- `bash mods/rby_mmo/tests/drivers/run-party-wild-e2e.sh` (name TBD) with `love` on PATH.
- Hub may be in-game Hub.lua (LAN) or Node — match whichever sibling e2e is closest; document in script header.
**E2E?** **yes — required for v1.**

## 6. Execution waves

| Wave | Tasks | Barrier |
| --- | --- | --- |
| 1 | **T1** ‖ **T6** | Vocabulary + docs index |
| 2 | **T2** ‖ **T3** | Hub seating + sim (disjoint files) |
| 3 | **T5** | CoopBattle understands mode/catch/run |
| 4 | **T4** | Divert wires into T5 screen |
| 5 | **TT1** ‖ **TT2** ‖ **TT3** | Unit/hub tests |
| 6 | **TT4** | E2E last (needs full stack) |

Checkpoint commit after each wave (`wave N: …`).

## 7. Blast radius & risks

| Risk | Mitigation |
| --- | --- |
| PROTOCOL 18 breaks mixed-version parties | Intentional refuse with version sentence; document in CHANGELOG |
| Partner auto-pulled while in a menu / movement | Reuse busy/in-battle gates; if partner is mid-trainer, do not divert host (predicate: partner free + same map) — **assumption:** if partner busy, host falls back to **solo engine wild** |
| Engine wild already dealing damage under frozen stack | Divert immediately on push (same as trainer prompt-on-top timing); replace/pop engine battle when mediated ready |
| Grant without engine mon on partner | Stash sheets at battle start; test sheet→party path |
| `isWildMode` false positive on future names | Accept for `coop_wild`; don’t name trainer modes `*wild*` |
| Twin drift Hub.lua ↔ relay.js | Same task owns both; parity tests |
| E2E flaky grass RNG | Driver forces encounter via existing tap/debug hooks if any; else map with high rate + retry budget — spike in TT4 if no force seam |

Rollback: revert PROTOCOL bump + mode; solo engine path remains default.

## 8. Open questions / assumptions

Resolved in Phase 2 — see §2 table.

Remaining soft assumptions (owner deferred by silence / “correct”):

1. If partner is **same map but busy** (menu, other battle), treat as “not available” → **solo engine wild** for the stepper.
2. Non-ball items in `coop_wild` keep Gen1 wild rules (doll flees, etc.) via existing `isWildMode` branches.
3. No ranked rating movement on `coop_wild` catch/run/ko.
4. E2e may be LAN in-game hub first; dedicated Node hub optional if timeboxed.

---

**Approval gate:** please confirm this plan (or note edits). No production code until you approve.
