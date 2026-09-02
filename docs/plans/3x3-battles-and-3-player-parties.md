# Plan — 3×3 battles and 3-player parties

| Field | Value |
| --- | --- |
| Date | 2026-08-31 |
| Source | Implement 3×3 battles, 3×NPC, 3×Wild; party max 3; PvP 2×2 or 3×3 only |
| Config | AGENTS_CONFIG.yml (quality / v3, host=cursor) |
| Flags | none |
| Gates | grilled + approved by owner (leave = remainder of 2; 3×Wild = 3v1; gen2 6-client 3×3 PvP in run) |
| Branch | `feature/3x3-battles-and-3-player-parties` |
| Base SHA | `6e0be32e012ebcc57c76f903e5793344c690680d` (tree had plan docs only) |

## 1. Objective & success criteria

Raise standing parties from 2 to 3 players, and seat 3-wide mediated fights when the party (or both parties) is size 3.

Success when all of the following hold:

1. A 2-player party can invite a third. Membership is hub-authoritative; `Wire.members` still refuses `# > PARTY_MAX`.
2. One of three leaving leaves a party of two. The last two dissolve as today.
3. Party PvP is **2×2 or 3×3 only**. A 3-player party challenging a 2-player party (or the reverse) is refused with a **spoken party-size mismatch error** on the asker (and a clean decline on the hub — no silent timeout hang).
4. A 3-player party vs one trainer is **3×NPC**: up to 3 foe seats, one trainer party dealt across them (today’s deal/drop-empty, wider).
5. A 3-player party vs grass is **3×Wild**: 3 humans vs **1** wild (today’s `coop_wild` shape, one more human). Catch/RUN rules unchanged.
6. A 2-player party’s PvE stays **2-wide** (2v2 NPC / 2v1 wild). No silent 2v3.
7. Gen1 and Gen2 BattleSim twins move together. Lua hub and Node relay stay twins.
8. E2E covers: gen1 **and gen2** 6-client 3×3 PvP, gen1+gen2 3-client 3×NPC and 3×Wild, plus the gen1 mismatch error.

## 2. Context & constraints

Grounded in Phase 1 scouts (`party+PvP`, `seating`, `battlefield UI`, `e2e+git`).

- `Config.PARTY_MAX = 2` is documented as pair-only (`src/Config.lua:352-362`). `startParty(a,b)`, invite-while-`has()`, and leave-dissolves-all make size 3 **unreachable** even if the constant moves.
- `COOP_SIDE = PARTY_MAX` and `COOP_FIGHTERS = PARTY_MAX * 2` (`Config.lua:381-382`). Hub PvP today requires **both parties full** (`Hub.lua:2802`, `relay.js:1087`) — a naive bump to 3 **kills 2×2**.
- Challenge size failure is a **silent hub `return`**. Asker already printed “Asked … for a 2-on-2” and waits out `Nobody answered in time` (`Coop.lua:1501`, `1661-1662`).
- Turn twins hard-code `FIGHTERS_PER_SIDE = 2` / `SIDE_SLOTS = 2` (BattleSim, BattleSim2, `server/lib/battle`, `battle2`). `coop_wild` refuses `memberIds.length !== 2` (`Hub.lua:1295-1340`, `relay.js:2623-2675`).
- `coop_npc` = one trainer party dealt across up to `COOP_SIDE` synthetic seats; empty seats dropped. `coop_wild` = exactly one wild seat.
- Battlefield `layout` is count-generic (`rowStack`) but plate/row constants are tuned so **2 fits and 3 collides** (`Battlefield.lua` ~91, 964-1058). Extra slot in existing tables + constant retune, not a new theatre.
- Targeting / VFX / command grid already walk N seats. `FIELD_MAX` follows `COOP_FIGHTERS`.
- `PROTOCOL = 26` on this branch. Peer **misty-sand** is landing **PROTOCOL 27** (`mmo.battle_moveset`) on `fix/fix-learning-new-move-during-battle` and releasing the `MediatedBattle.lua` claim. This plan bumps **after** that tip: **27 if they have not merged, 28 if they have**.
- This branch has **0 commits** ahead of `origin/main`. No prior 3×3 attempt.
- E2E: `run-quad-e2e.sh` = 4 LOVE + Node hub, gen1 2×2 PvP only. `run-mmo-e2e.sh` / `-gen2` = 2 LOVE, party NPC + wild. No gen2 quad. Engine root: `~/Projects/alamops/gen1recomp`, this tree symlinked as `mods/rby_mmo`.

Peers in blast radius (different branches): Dig/Fly (`src/BattleSim`, `Battlefield`, `Vfx`) and learn-move (`MediatedBattle`, `CoopBattle`, `LearnMove.lua`). Rebase/merge those hunks; do not rewrite teach/sync.

## 3. Approach & key decisions

| Concern | Choice | Why |
| --- | --- | --- |
| Party growth | Invite allowed while `count < PARTY_MAX`; hub appends the new id | Size 3 is otherwise unreachable |
| Leave | Remainder stays if ≥2 remain; dissolve at <2 | Pair dissolve exists only because a remainder of 1 is not a party |
| PvP match | `#mine == #theirs` and that size ∈ {2, 3} | Owner: never 3×2 / 2×3; keep 2×2 after the cap moves |
| PvP refuse | Client pre-check + hub `coop_decline` / existing ask-decline with **reason** | Owner: display mismatch; today’s silence is a soft-lock |
| NPC width | Foe seats = **this fight’s human count**, not always `PARTY_MAX` | 2-player NPC stays 2v2; 3-player is 3v3. Avoids 2v3 |
| Wild width | Humans = party size on the map; **always 1 wild** | Extend 2v1; 3-wild catch is a different ticket |
| Thin trainer | Keep drop-empty-seats | 3 humans may face 1–2 actives (PvE, not the PvP square rule) |
| Sim cap | `FIGHTERS_PER_SIDE` / `SIDE_SLOTS` = `COOP_SIDE` (3) | Four twins + sanitize; field 0..5 |
| Layout | Extra seat in `allySeats`/`foeSeats`; retune `MON_ROW_GAP` / plate stack so n=3 does not eat the mon band | Scout: not a new architecture |
| PROTOCOL | Bump (closed seating contract + `FIELD_MAX` 3→5) | Mixed clients would disagree on legal opens/targets |
| Strings | Challenge copy becomes size-aware (`2-on-2` / `3-on-3`) | Hardcoded “2-on-2” would lie |

Alternatives rejected:

- Only bump `PARTY_MAX` — invite/leave/`startParty` still pair-only; 2×2 PvP dies.
- `COOP_SIDE` always 3 for every coop — 2-player NPC becomes 2v3.
- 3 wilds on `coop_wild` — new catch-ownership / multi-mon wild rules, out of scope.
- Dissolve-all at 3 — size 3 is unusable (one disconnect ends two innocent members).

## 4. Work breakdown — implementation tasks

### T1 — Constants and wire caps
- **Owns:** `src/Config.lua`, `server/lib/sanitize.js`, `src/Wire.lua` (caps / comments only), `CHANGELOG.md` Unreleased + PROTOCOL line, `server/twin_parity.test.js` if it locks PROTOCOL
- **Depends:** none
- **Do:** `PARTY_MAX = 3`; rewrite the pair-only comment; PROTOCOL +1 (27 or 28 per tip); `FIELD_MAX` / `battleReady` already follow Config — confirm and comment. Sanitize twin `PARTY_MAX`.
- **Accept:** twins agree; oversize `members` still refused.

### T2 — Party membership (client)
- **Owns:** `src/Party.lua`, `src/Ui.lua` (PARTY / INVITE / LEAVE / MEMBERS), `src/Overlay.lua` (town-map comment + 2 markers), `src/Client.lua` (party-chat / `partner()` gates only)
- **Depends:** T1
- **Do:** `partners()`; `invite` allowed if `count < MAX` and target unattached; LEAVE copy names the group when `count > 2`; chat fans to all partners.
- **Accept:** 2-person party can invite a third locally; invite-while-full still refused.

### T3 — Hub / relay party + PvP match
- **Owns:** `src/Hub.lua`, `server/lib/relay.js`
- **Depends:** T1, T2
- **Do:** `startParty` can create 2 **or append** a 3rd; invite from a member when `# < PARTY_MAX`; leave removes one, `endParty` only when `< 2`; `partnerOf` → all others. PvP: require `#mine == #theirs` and size ∈ {2,3}; on mismatch send a decline/reason (new or reuse `coop` ask-decline) — **never silent**. `coop_wild` gate = 2 or 3 humans (not `!== 2`). NPC mint loop = **human count**, not `COOP_SIDE` blindly. Twin comments in both files.
- **Accept:** 3-member `mmo.party`; leave-one-of-three leaves two; 3v2 challenge declined with reason; 2v2 still opens.

### T4 — BattleSim twins (Lua)
- **Owns:** `src/BattleSim/Turn.lua`, `src/BattleSim/events.lua`, `src/BattleSim2/Turn.lua`, `src/BattleSim2/events.lua`
- **Depends:** T1
- **Do:** `FIGHTERS_PER_SIDE` / `SIDE_SLOTS` = 3 (or `COOP_SIDE`); `maxFighters` / `fieldSlot` index 0..2 per side (slots 0..5); `coop_wild` still 1 foe seat; `coop_npc` / `coop_pvp` allow 3 per side.
- **Accept:** 3v3 field creates; 2v1 wild still creates; no slot collision.

### T5 — BattleSim twins (Node)
- **Owns:** `server/lib/battle/Turn.js`, `server/lib/battle/events.js`, `server/lib/battle2/Turn.js`, `server/lib/battle2/events.js`
- **Depends:** T1
- **Do:** Mirror T4 exactly (hub-twin-parity).
- **Accept:** `server/twin_parity.test.js` / turn parity still green after fixture updates in the test wave.

### T6 — Battlefield 3-wide layout
- **Owns:** `src/Battlefield.lua`
- **Depends:** T1
- **Do:** Retune `MON_ROW_GAP` / plate stack / dodge policy so n=3 keeps mons ≥ `MON_DRAW` apart and plates off the mon columns. Keep `rowStack` / `seatIndex` / fx. Export geometry; prove in existing shot tests (updated in test wave).
- **Accept:** Headless layout for `#column == 3` does not overlap plates vs mons.

### T7 — Coop / mediated UX
- **Owns:** `src/Coop.lua`, `src/CoopBattle.lua`, `src/MediatedBattle.lua` (strings / challenge pre-check / 1v1-only comments only — do **not** rewrite learn-move teach/sync)
- **Depends:** T3
- **Do:** Client fullness/size check **before** send; spoken mismatch (e.g. `Party sizes\ndon't match.`); size-aware “2-on-2” / “3-on-3”; clear `self.ask` on refuse. CoopBattle target list already N-wide.
- **Accept:** 3v2 never arms a hanging ask.

## 5. Work breakdown — test tasks

E2E **applies**. Run recipe: from `~/Projects/alamops/gen1recomp` with this tree as `mods/rby_mmo`. ROM via `scripts/setup.sh`; Gold via `GOLD_ROM_PATH` in `mods/rby_mmo/.env`.

| ID | Layer | Covers | Owns |
| --- | --- | --- | --- |
| U1 | Lua unit | Party grow/leave; members cap 3; PvP match/mismatch strings; Wire.members | `tests/rby_mmo_test.lua` (party + coop challenge sections) |
| U2 | Lua BattleSim | 3v3 create; 3v1 wild; 2v2 still; targeting 3 foes | `tests/battle_sim_turn.lua` (+ BattleSim2 if split) |
| U3 | Hub / Node | relay grow/leave; 3v2 decline reason; 3v3 open; wild 3 humans; twin PROTOCOL | `tests/hub_battle.lua`, `server/hub.test.js`, `server/hub_battle.test.js`, `server/twin_parity.test.js`, parity fixtures |
| E1 | e2e gen1 | 6 LOVE + hub: two parties of 3 → 3×3 `coop_pvp` (clone `run-quad-e2e.sh` / `mmo_quad.lua`) | `tests/drivers/run-hex-e2e.sh`, `mmo_hex.lua`, `mmo_util.lua` PHASE keys |
| E1b | e2e gen2 | Same 6 LOVE + Node hub on Gold (`GOLD_ROM_PATH`, gen2 drivers / identity) | `tests/drivers/run-hex-e2e-gen2.sh` + Gold hex driver (or gen2 flag on hex) |
| E2 | e2e gen1 | 3 LOVE: party of 3 → `coop_npc` and `coop_wild` | extend `run-mmo-e2e.sh` / host-join **or** thin 3-role drivers |
| E3 | e2e gen2 | 3 LOVE Gold: 3×NPC + 3×Wild | extend `run-mmo-e2e-gen2.sh` / `mmo_*_gen2.lua` |
| E4 | e2e gen1 | Size-mismatch: party-of-3 vs party-of-2 → reason substring, ask cleared (clone invite-refuse) | `run-party-mismatch-e2e.sh` + flag on existing drivers |
| L1 | layout | `battlefield_shot` / suite: n=3 plates vs mons | `tests/drivers/battlefield_shot.lua`, suite layout block |

**Gen2 6-client 3×3 PvP:** clone `run-quad-e2e.sh`’s Node-hub + all-JOIN shape (not the 2-client in-game Gold host). Six LOVE instances boot Gold (`GOLD_ROM_PATH` / import path from `run-mmo-e2e-gen2.sh`), `MMO_HUB_MAX≥8`, same 3+3 party + PARTY BATTLE choreography as gen1 hex. Gen2 2×2 PvP (a 4-client Gold quad) is still a different ticket.

**Commands (Phase 7):**

```sh
# this repo
luajit tests/rby_mmo_test.lua
node server/hub.test.js
node server/hub_battle.test.js
node server/twin_parity.test.js

# engine root
python3 tools/modkit.py validate mods/rby_mmo
python3 tools/modkit.py lint mods/rby_mmo
bash mods/rby_mmo/tests/drivers/run-hex-e2e.sh
bash mods/rby_mmo/tests/drivers/run-hex-e2e-gen2.sh
bash mods/rby_mmo/tests/drivers/run-party-mismatch-e2e.sh
bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh          # includes 3-party NPC/wild once E2 lands
bash mods/rby_mmo/tests/drivers/run-mmo-e2e-gen2.sh
```

## 6. Execution waves

| Wave | Parallel | Barrier |
| --- | --- | --- |
| 1 | T1 | Constants/PROTOCOL before anyone reads the new cap |
| 2 | T2, T4, T5, T6 | Client party + both sim stacks + layout; no shared files |
| 3 | T3 | Hub/relay after T1+T2 (party APIs exist) |
| 4 | T7 | UX after hub decline exists |
| 5 (Phase 6) | U1, U2, U3, L1 then E1–E4 | Tests after impl |

T3 is sequential because `Hub.lua` / `relay.js` are the party **and** seating twins.

## 7. Blast radius & risks

- **2×2 PvP regression** if the match rule stays “both == PARTY_MAX”.
- **2v3 NPC** if NPC seats mint `COOP_SIDE` (3) for a 2-human party.
- **PROTOCOL clash** with in-flight 27 (learn-move). Coordinate the number; do not reuse 27.
- **MediatedBattle / CoopBattle** merge with learn-move and Dig/Fly. Touch only seating/UX; leave teach/sync and two-turn vanish alone.
- **Leave remainder** must still `endParty` on disconnect of the last-but-one, and on hub drop.
- **Town map** draws every non-self member — 2 markers at size 3. Accept clutter; no new marker design.
- Rollback: PROTOCOL bump means old hubs refuse new clients (intended).

## 8. Open questions / assumptions

Owner skipped the grill. Locked from the request + Phase 1 + safer default:

| # | Question | Assumption | Source | Confidence |
| --- | --- | --- | --- | --- |
| 1 | 3×Wild seats? | 3 humans vs **1** wild (2-player stays 2v1) | **owner confirmed** | high |
| 2 | 3×NPC seats? | One trainer, foe seats = human count (3v3 / 2v2) | extend deal-across-seats | high |
| 3 | Leave at 3? | Remainder of 2 stays | **owner confirmed** | high |
| 4 | 2-player PvE width? | Stay 2-wide | avoid 2v3; reversible | high |
| 5 | Thin trainer? | Drop empty seats | today’s rule | high |
| 6 | Invite a 3rd? | Yes, while `count < 3` | required for the feature | high |
| 7 | Mismatch copy? | `Party sizes\ndon't match.` | owner asked for a displayed error | medium (wording) |
| 8 | PROTOCOL? | Bump; skip 27 if learn-move owns it | seating is wire-visible | high |
| 9 | Gen2 6-LOVE PvP? | **In this run** — Node hub + 6 Gold LOVE (clone quad, not in-game host) | **owner confirmed** | high |

**One-way doors:** none. PROTOCOL bump is additive refusal, not a destructive migration.

## 9. Completeness ledger

Not `--no-follow-ups`. Still finishing the change itself:

- All `partner()` callers that would name the wrong person — **in run** (T2, T7).
- Hub + Node twins — **in run** (T3, T5).
- Docs/comments that say “two is the whole design” — **in run** (T1).
- Gen2 6-instance 3×3 PvP — **in this run** (E1b).
- Gen2 4-client 2×2 PvP — **out** (different ticket; not requested).
- 3 wilds / 3 trainers as separate combatants — **out** (different product).
