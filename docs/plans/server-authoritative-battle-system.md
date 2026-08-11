> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — Server-authoritative PVP / COOP Battle System

| Field | Value |
| --- | --- |
| Date | 2026-08-08 |
| Source | conversation — PVP Battle System v2 (1v1 + Party vs NPC + Party vs Party) |
| Config | AGENTS_CONFIG.yml (quality) |
| Branch | `fix/battle-system-v2` |
| Base SHA | `6afe6e6bc23a0269b42a798c15843933c86dbdeb` |

**Gates:** Phase 2 grill completed with owner; this plan awaits explicit approval before Phase 4 code.

## 1. Objective & success criteria

Replace client-trusted combat resolution for **all MMO-mediated fights** with an **intermediator** that owns hit/crit/damage/status/outcome:

| Mode | In scope |
| --- | --- |
| 1v1 PVP | Yes |
| Party vs NPC (2v2 co-op trainer) | Yes |
| Party vs Party (2v2 PVP) | Yes |
| Solo wild / solo trainer | **Out** — stay on local engine |

**Success means:**

1. Clients send **choices** + **battler snapshots**; intermediator emits **display events** and the **sole** win/loss/draw.
2. Works on **dedicated Node hub** and **in-game LAN Host** (Lua) with **byte-identical formula results** on shared synthetic fixtures.
3. **No fingerprint / `canBattle` refuse** for MMO-mediated battles (mods incompatibility gate removed for these paths).
4. **No ROM-derived tables** in the repo (species/move/type chart dumps forbidden). Type chart + global rules arrive as an **ephemeral ruleset upload** from the authority side for that battle only.
5. Disconnect: **grace reconnect**, then **forfeit** for the missing side.
6. Acceptance bar: synthetic unit parity (Lua↔JS), hub socket tests, multi-LÖVE e2e for 1v1 and 2v2, PROTOCOL bump + CHANGELOG.

## 2. Context & constraints

### Ground truth (Phase 1)

- **1v1 today:** `Sessions` → engine `Handshake`/`LinkBattle` over `SessionNet`; hub relays `mmo.relay` opaquely; both clients lockstep on a shared seed. Compat via `Sessions.canBattle` + fingerprint (`src/Sessions.lua`, `src/SessionNet.lua`).
- **2v2 today:** Host client runs `CoopSim` + engine `Damage`/`Status` via `CoopField`; others replay `mmo.coop_relay` events. Hub is membership + opaque fan-out only (`src/Coop*.lua`, `server/lib/relay.js`).
- **Hub doctrine (to be superseded for battle math only):** “relays only — never simulates” (`CLAUDE.md`, `server/README.md`). Rank already lives server-side; battle math does not.
- **Branch:** `fix/battle-system-v2` == `main` at investigation time; no prior v2 commits.

### Owner decisions (Phase 2)

| # | Decision |
| --- | --- |
| Authority | Full intermediator (A): choices in → rolls/events/outcome out |
| Runtime | Hybrid: Node dedicated **and** Lua LAN Host |
| Sheets | Client-submitted stats/moves/level/status/EV/IV; **trust for v1** |
| Ruleset | Ephemeral upload from **LAN Host** or dedicated session **host** (asker); no shipped Pokédex/move/type tables |
| NPC foes | Engaging player submits trainer party |
| Solo | Local engine unchanged |
| Wire | New PROTOCOL messages; thin client renderer; hard cut for mediated fights (no old lockstep fallback) |
| Rank | Intermediator settles; drop dual-client `mmo.result` vote for these battles |
| Disconnect | Grace reconnect, then forfeit |
| Legal | Formulas + synthetic tests only; no ROM bytes in git |
| Parity | Shared synthetic vectors must match Lua ↔ JS |

### Legal posture (non-negotiable)

- Ship **hand-authored Gen1 *formulas*** (pure numeric functions).
- Do **not** vendor species base stats, move lists, type charts, names, or any ROM extract.
- Clients (who already decoded their ROM via the engine) supply resolution numbers and the host’s ephemeral type-chart/rules blob for that match.
- Parity fixtures use **synthetic** numbers only.

### Residual cheat surface (accepted for v1)

A modified client can still lie on the **pre-fight sheet** (inflated Atk, bogus move power). Mid-fight damage/crit/status cheating and fingerprint refusal are removed.

## 3. Approach & key decisions

### 3.1 Intermediator shape

One conceptual service, two runtimes kept in lockstep:

```
src/BattleSim/          — Lua (LAN Host path; also unit-tested under luajit)
server/lib/battle/      — JS (dedicated hub path)
```

Both expose the same surface:

- `createBattle(spec)` — mode, sides, ruleset, snapshots, seed
- `submitChoice(playerId, choice)` — fight/item/switch/run (+ target)
- `tick(now)` — deadlines, reconnect grace, forced picks
- `pollEvents(playerId)` / push — ordered display events
- `outcome()` — `win|loss|draw|forfeit` + ranked payload when settled

**LAN:** `src/Hub.lua` owns the sim instance for sessions it brokers.  
**Dedicated:** `server/lib/relay.js` owns the sim; stop opaque-forwarding battle payloads for mediated fights.

### 3.2 Authority & ruleset

- **LAN Host process** = intermediator + canonical ruleset source.
- **Dedicated:** session `role=host` (asker) uploads ruleset once; guests play under it by joining.
- Battler snapshots: each combatant submits their own mons (NPC/trainer party: engaging player only).
- Drop `Sessions.canBattle` / fingerprint refuse on the MMO-mediated start path (trade fingerprint policy unchanged unless touched later).

### 3.3 Client role

- **1v1:** Stop handing off to `LinkBattle` for MMO battles. New thin driver (reuse battle UI / stack push patterns where practical) sends choices and applies intermediator events.
- **2v2:** Keep `CoopBattle` as the **screen/UX**; strip host-local `CoopSim` RNG authority — host client is no longer the sim when an intermediator is present (LAN Host or Node). `CoopSim` either becomes a library the Lua intermediator calls, or is folded into `src/BattleSim/` (prefer fold to one sim).
- Solo wild/trainer: untouched.

### 3.4 Wire (PROTOCOL 9 → 10)

Additive vocabulary (names indicative; finalize in implementation to match `Wire.lua` / `sanitize.js` style):

| Type | Direction | Role |
| --- | --- | --- |
| `mmo.battle_ruleset` | host client → intermediator | Ephemeral type chart + global constants for this match |
| `mmo.battle_party` | each combatant → intermediator | Battler snapshots (stats, moves+resolution fields, status, HP, level, IV/EV) |
| `mmo.battle_ready` | intermediator → clients | Field confirmed; first turn begins |
| `mmo.battle_choice` | client → intermediator | Per-turn action |
| `mmo.battle_event` | intermediator → clients | Ordered display/sim events (msg, anim, damage, faint, …) |
| `mmo.battle_outcome` | intermediator → clients (+ rank path) | Sole result; replaces dual `mmo.result` vote for these fights |
| `mmo.battle_reconnect` | client → intermediator | Rejoin within grace |

Invite/session/coop agreement messages (`mmo.request`, `mmo.coop_*` ask/join) stay; only the **in-fight** path changes. Bump `Config.PROTOCOL` and server config version in lockstep.

### 3.5 Disconnect policy

- Mark side disconnected; pause or auto-stall turn clock per design in impl.
- **Grace window** (constant in `Config`, mirrored in JS) to reconnect and resume.
- On expiry: that side **forfeits**; intermediator emits `battle_outcome`; rank settles from intermediator alone.

### 3.6 Alternatives rejected

| Alternative | Why not |
| --- | --- |
| Ship vanilla move/type DB on server | Violates legal posture / owner 5B |
| Keep LinkBattle lockstep + server RNG tickets only | Does not fully remove client math trust; weaker than owner 1A |
| Node-only intermediator | Breaks LAN Host requirement |
| Require fingerprint match for type chart | Reintroduces mods incompatibility |

## 4. Work breakdown — implementation tasks

File ownership is **disjoint within a wave**.

### Wave 0 — Scaffold & protocol

| ID | Goal | Owns | Depends | Acceptance |
| --- | --- | --- | --- | --- |
| I0a | PROTOCOL 10 vocabulary + sanitizers (Lua) | `src/Wire.lua`, `src/Config.lua` (PROTOCOL + grace/timeout constants) | — | New types documented; sanitizers reject bad shapes |
| I0b | Mirror sanitizers + protocol version (JS) | `server/lib/sanitize.js`, `server/lib/config.js` (version parity), `server/package.json` if versioned | I0a names frozen | Hub rejects/forwards new types correctly in isolation tests |
| I0c | Synthetic fixture pack (shared JSON) | `tests/fixtures/battle_sim_vectors.json` (and tiny loader notes in plan only) | — | No ROM-derived values; covers damage, accuracy, crit bands, status gates |

### Wave 1 — Core sim twins

| ID | Goal | Owns | Depends | Acceptance |
| --- | --- | --- | --- | --- |
| I1a | Lua BattleSim: battler model, RNG, damage, accuracy, crit, status before-move/residual (Gen1 formulas) | `src/BattleSim/**` (new) | I0c | Luajit vectors match fixture expected ranges |
| I1b | JS BattleSim: same API + formulas | `server/lib/battle/**` (new) | I0c | `node --test` vectors match **identical** expected outputs as I1a |
| I1c | Turn machine: choices, order, switches, items, run consent hooks, deadlines, reconnect/forfeit | Split: Lua turn machine under `src/BattleSim/`; JS under `server/lib/battle/` — **sequence I1c-lua then I1c-js** if shared event schema must freeze first: freeze event schema in `docs` comment inside `src/BattleSim/events.lua` owned by I1c-lua | I1a | Hosted 1v1 resolve in unit tests without engine |

### Wave 2 — Hub / Host integration

| ID | Goal | Owns | Depends | Acceptance |
| --- | --- | --- | --- | --- |
| I2a | Node relay: allocate sim on session/coop start; handle ruleset/party/choice/reconnect; emit events/outcome; stop opaque battle relay for mediated fights; rank from outcome | `server/lib/relay.js`, `server/lib/rank.js` (only if settle API needs a server-side entry) | I1b, I1c-js, I0b | Socket test: two clients fight; hub alone decides damage; rank updates without dual RESULT vote |
| I2b | Lua Hub twin of I2a | `src/Hub.lua` | I1a, I1c-lua, I0a | In-process hub test: LAN host decides; same event schema |
| I2c | Rank path: intermediator-only settle; retire dual-report requirement for mediated battles | `src/Hub.lua` settle bits **after** I2b **or** `server/lib/relay.js` settle — **do I2c as part of I2a/I2b** to avoid triple-touch; if split, I2c owns only `src/Rank.lua` docs/comments + shared settle helper used by both hubs | I2a, I2b | Disagreement of client RESULT ignored; outcome message scores |

*Note: Implement settle inside I2a/I2b; do not open a third parallel edit on both hub files.*

### Wave 3 — Client drivers

| ID | Goal | Owns | Depends | Acceptance |
| --- | --- | --- | --- | --- |
| I3a | 1v1: snapshot export, ruleset export (host), choice UX → wire, event apply, remove LinkBattle handoff + canBattle gate for MMO battle | `src/Sessions.lua`, `src/SessionNet.lua` (only if shim still useful for non-battle), new `src/MediatedBattle.lua` (thin client) | I2b (or stub transport for tests) | Headless: request→ready→choice→outcome without `LinkBattle` |
| I3b | Client wiring: dispatch new wire types, battle.ended/rank narration | `src/Client.lua` | I3a | Dispatch table complete; no dual RESULT send for mediated |
| I3c | 2v2: Coop agreement unchanged; battle screen becomes renderer; remove host-local sim authority; submit parties/choices; NPC foe submit from engagers | `src/Coop.lua`, `src/CoopBattle.lua`; delete or hollow `src/CoopSim.lua` / `src/CoopField.lua` as appropriated by BattleSim | I2a/I2b, I1 | Four-client unit flow: events identical; host client does not roll damage |
| I3d | Disconnect / reconnect UX + forfeit messaging | `src/MediatedBattle.lua`, `src/CoopBattle.lua`, Config constants | I2a/I2b | Grace then forfeit covered in tests |

### Wave 4 — Docs / version

| ID | Goal | Owns | Depends | Acceptance |
| --- | --- | --- | --- | --- |
| I4a | CHANGELOG + README battle section + server README doctrine update (“hub simulates mediated battles”) | `CHANGELOG.md`, `README.md`, `server/README.md` | feature complete | Version bump (e.g. 0.11.0); doctrine matches code |
| I4b | `manifest.json` version; CLAUDE.md three-decisions note if hub doctrine changes | `manifest.json`, `CLAUDE.md` | I4a | Versions align |

## 5. Work breakdown — test tasks

| ID | Layer | Covers | Owns | Recipe |
| --- | --- | --- | --- | --- |
| T1 | Unit | Formula vectors Lua | `tests/battle_sim_vectors.lua` (or section in `tests/rby_mmo_test.lua`) | `luajit mods/rby_mmo/tests/...` from engine root |
| T2 | Unit | Formula vectors JS | `server/battle.test.js` | `cd server && npm test` / `node --test` |
| T3 | Integration | Hub socket 1v1 mediated | extend `server/hub.test.js` | `node server/hub.test.js` |
| T4 | Integration | Lua Hub LAN 1v1 + 2v2 mediated | extend `tests/rby_mmo_test.lua` | luajit suite |
| T5 | E2E | 1v1 two LÖVE | extend `tests/drivers/run-mmo-e2e.sh` / host-guest drivers | needs ROM + engine checkout |
| T6 | E2E | Party vs Party quad | `tests/drivers/run-quad-e2e.sh` | ROM + engine |
| T7 | E2E | Party vs NPC path | existing join/wait drivers updated for new wire | ROM + engine |
| T8 | Compat | `tests/red_yellow_battle_compat.lua` rewritten: Red vs Yellow **allowed** via mediated path; linkModified no longer blocks MMO battle | that file | luajit |

**E2e applies** — mediated fights cross process boundaries (client ↔ hub). Run recipe from Phase 1: engine at `~/Projects/alamops/gen1recomp`, mod symlinked, ROM via `scripts/setup.sh`, hub via `node server/hub.js` or `bin/rby-mmo-hub.js`.

## 6. Execution waves

```
Wave 0: I0a || I0b || I0c
Wave 1: I1a || I1b ; then I1c-lua → I1c-js (event schema barrier)
Wave 2: I2a || I2b
Wave 3: I3a → I3b ; I3c || I3d (I3c after I2*; I3a after I2b)
Wave 4: I4a → I4b
Tests: T1/T2 with Wave 1; T3/T4 with Wave 2–3; T5–T8 after Wave 3; T8 can land with I3a
```

Barrier: do not start Wave 3 client cutover until Wave 2 hubs emit `battle_event` / `battle_outcome` in tests.

## 7. Blast radius & risks

| Risk | Mitigation |
| --- | --- |
| Lua↔JS formula drift | Shared JSON vectors; CI both suites; single event schema doc in BattleSim |
| Gen1 quirk incompleteness (256 miss, status order, etc.) | Port behavior from current `CoopSim` + engine call order; vectorize quirks explicitly |
| Large `CoopBattle.lua` rewrite | Keep draw/input; swap only resolution source |
| PROTOCOL break | Hard cut at 10; old clients cannot mediate — acceptable per owner E1 |
| `affects_link` | Remains `false`: client link registries untouched; mediated path is MMO-only |
| Cheaters inflate sheets | Accepted v1; document in README |
| Hub “never simulates” docs stale | I4a updates README/CLAUDE |
| Scope size | Ship formulas + 1v1 path vertical slice early if needed; plan still targets all three modes |

**Rollback:** revert PROTOCOL to 9 and restore LinkBattle/CoopSim host path; no DB migration (in-memory sims only).

## 8. Open questions / assumptions

| Item | Resolution |
| --- | --- |
| Ruleset contents | Assumption: type-effectiveness matrix + any global numeric constants the formulas need; move power lives on each move in the party snapshot |
| Item/berry Gen1 bag effects | Assumption: v1 supports the same item/switch/run set co-op already exposes; exotic glitch items best-effort |
| Spectators | Out of scope |
| Grace duration | Assumption: mirror existing session grace style — default **60s** reconnect grace unless owner retunes in review |
| `mmo.result` | Still accepted only for legacy edge cases during rollout? Assumption: **ignored** for mediated battles once outcome ships |
| Engine `LinkBattle` | Unused for MMO; still not vendored/reimplemented for cable club |

---

## Approval

**Owner:** reply **approve** (or request edits). No Phase 4 code until then.
