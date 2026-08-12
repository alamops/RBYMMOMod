# Plan — Fix battle system v2 (Quarkst report)

| Field | Value |
| --- | --- |
| Date | 2026-08-11 |
| Source | Player report (Quarkst via `/implement`): no attack SFX; fainted Metapod “revives” under Gust then Ember to 0 while win music plays; joiner forced into immediate solo FIGHT UI after co-op win |
| Config | AGENTS_CONFIG.yml (quality preset, host: cursor) |
| Branch | `fix/fix-battle-system-v2-reported-by-quarkst` |
| Base SHA | `e8a5d08a712bb5221fb4bb4d3a1dff783e573dc2` (tree had only the approved plan file untracked) |

## 1. Objective & success criteria

Close three co-op / mediated battle defects so a Route 3 Bug Catcher 2v2 feels like a finished Gen1 fight for **both** waiter and joiner.

Done when:

1. **Attack audio** — CoopBattle and MediatedBattle 1v1 play move anim SFX (whoosh / cry), post-hit effectiveness thuds (Damage / Super_Effective / Not_Very_Effective), and catch-shake `SFX_TINK` via the same `AnimPlayer:pollEffects` contract solo `BattleState` uses. Missing `Sound` must not throw.
2. **No revive illusion** — On a multi-attacker final KO, win music does **not** start before that turn’s HP drains and faint sink finish. A foe at 0 truth never animates a drain *up* or a living bar after fanfare. Strip icons follow display faint, not premature `isDown`.
3. **No joiner rematch** — After a co-op NPC win, the joiner returns to overworld only. No buried `BattleState` resurfaces as an immediate FIGHT UI, and invite-path joiners (no local engine fight) still mark the trainer beaten, receive prize money, and run script/`afterBattle` like a solo win.
4. **Theatrical chrome (in scope)** — CoopBattle trainer intro gains the deferred foe/trainer theatrical frame (appear line + foe send-out chrome parity called out in `coop-battle-intro-anims.md`), without regressing existing ally ball chrome / Ball_Poof.
5. Suites green: Lua mod suite, node hub / twin parity as touched, `modkit validate/lint/pack` from the engine checkout when available. E2e drivers extended where headless can assert the rematch / music-order contracts.

## 2. Context & constraints

### Grounded findings (Phase 1)

**SFX gap.** Solo path: `BattleState` calls `animPlayer:update()` then `pollEffects()` → `applyAnimEffect` / `playAnimSound`, and `applyHitFx` after anim for effectiveness thuds. Coop holds anim at `src/CoopBattle.lua` (~989–998) with update only — no poll. MediatedBattle same omission (~1719–1735); `loadEngine` does not pull `Sound`. Intro Ball_Poof (`e8a5d08` / #34) is a one-off, not a general audio path. BattleSim emits `anim` + `damage` with no `sfx` field — clients can derive audio from move id + effectiveness without a PROTOCOL bump for SFX.

**HP / win-music race.** Design debt from historical `coop-battle-hp-sequencing.md` (two clocks). Truth HP applies immediately on replay/mediated (`CoopBattle.lua` ~2500–2526); display drains are queued. `over` calls `playVictoryMusic()` inline (~2620–2627) **before** remaining drains/faints in the message queue play — matches “win music, then Gust shows living Metapod, then Ember to 0.” Host-sim can also flicker via CoopField `fainted=true` cleared when the faint row runs (~2563–2567). Strip drop uses truth `isDown` (~3234–3241).

**Rematch.** Reporter was the **joiner**; rematch was an **immediate FIGHT UI** (not a leisurely overworld walk-up). That is the buried-stack failure mode `#20` / `26f358e` targeted for **walk-in** joiners (`joinedEngine` + unwind in `src/Coop.lua` ~1358–1366, ~1991–2013). Invite/same-map joiners intentionally keep `engine = nil`; `#20` left them without `defeatedTrainers` / `onFinish`. Owner now wants invite joiners to also get **prize money + script `afterBattle`**, not only the defeat flag. Immediate FIGHT strongly prioritizes hardening the walk-in unwind path under mediation (battle-key match / stack presence); sight re-engage remains a second failure mode if still standing on the sight line after an invite join.

**Branch state.** Tip equals `main` at `e8a5d08`; no commits yet on this branch name.

### Owner decisions (Phase 2)

| Topic | Decision |
| --- | --- |
| Rematch victim | Joiner; immediate FIGHT UI after co-op win |
| Invite-joiner cleanup | Full parity: defeat flag **and** prize money **and** script/`afterBattle` |
| SFX | Coop **and** MediatedBattle 1v1; move sounds + hit thuds |
| Catch `SFX_TINK` / theatrical chrome / PROTOCOL | **In scope** (PROTOCOL only if rematch wire needs overworld `npcId`) |

### Constraints

- Prefer **display/client** fixes for SFX and music/HP; avoid PROTOCOL for audio.
- Rematch invite path likely needs an additive wire field (overworld NPC id / event id from waiter’s `checkpointOrigin`) — bump PROTOCOL only for that, with Hub.lua ↔ relay.js twin parity.
- Do not write link registries; `affects_link` stays false.
- No bare `error()`/`assert()` in mod callbacks; Soft-fail Sound with `pcall`.
- Keep `mon.hp` truth instant; only display sequencing and when music starts may change.

## 3. Approach & key decisions

1. **SFX via poll + local hit FX (no SFX PROTOCOL).** Shared helper (or duplicated thin mirror) after each `animPlayer:update()` in CoopBattle + MediatedBattle: `pollEffects()` → play move/cry/`SFX_TINK` like `BattleState.playAnimSound`. On anim completion, play effectiveness thud from the pending hit / following effectiveness msg (mirror `applyHitFx`). Load `Sound` in MediatedBattle. Fallback: if `AnimPlayer.start` fails, play move SFX from `data.moves[id]` like solo’s no-player branch.

2. **Defer victory music into the message queue.** Replace inline `playVictoryMusic()` in the `over` branch with a queued `{ act = playVictoryMusic }` (or equivalent) after that batch’s drains/faint sink / defeat text ordering matches engine intent (“fanfare under defeat line,” not “fanfare before Gust’s bar”). Clamp drains so `to > shownHP` is ignored when a faint is already queued for that battler. Align strip elimination with display `fainted` / sink done.

3. **Rematch — two paths, one consume contract.**
   - **Walk-in:** Audit `joinedEngine` under mediated `coop_npc` (battle key, `onStack`, clearing `encounter`). Fix any mediation regression so `plan.engine` is set, unwind pops the buried fight, and `consume` → `onFinish` runs. Immediate FIGHT UI is the acceptance bar.
   - **Invite / menu join:** Carry authoritative overworld `npcId` (+ event flag if present) from waiter’s engine `checkpointOrigin` on `COOP_WAIT` / `COOP_BATTLE`. On joiner win with no `engineBattle`, build a **synthetic finish** that pays prize (same formula as `M:consume`), sets `defeatedTrainers` / event flag, and invokes the same post-battle script/`afterBattle` path the engine would have — without inventing a fake buried `BattleState` on the stack.

4. **Theatrical chrome:** Implement the deferred trainer/foe intro frame on CoopBattle (appear + foe send-out chrome) called out in `coop-battle-intro-anims.md`, after audio/HP/rematch waves so polish cannot block the three bug closes.

Alternatives rejected: putting every SFX on the wire (twin + PROTOCOL cost for data clients already have); refusing invite joins until walk-in (worse UX); only setting `defeatedTrainers` without prize/`afterBattle` (owner rejected).

## 4. Work breakdown — implementation tasks

### T1 — Shared battle SFX poll path
- **Owns:** `src/CoopBattle.lua` (anim hold + Sound usage), `src/MediatedBattle.lua` (load Sound; anim hold; hit thud)
- **Deps:** none
- **Accept:** Move anim tick plays `playMove`/cry; catch shake emits `SFX_TINK`; effectiveness thud after anim; missing Sound is no-op

### T2 — Victory music + HP/faint display race
- **Owns:** `src/CoopBattle.lua` (queue `over` music; drain clamp; stripShows predicate; host-sim faint flag display separation as needed)
- **Deps:** none (file overlap with T1 → **same wave only if sequenced, or one agent owns both T1+T2**)
- **Accept:** Multi-hit final KO never plays fanfare before drains/sink; no drain-up after faint queued; strip icon stays until display faint

### T3 — Joiner rematch: walk-in harden + invite synthetic finish
- **Owns:** `src/Coop.lua`, `src/Wire.lua`, `src/Hub.lua`, `server/lib/relay.js` (and twin parity fixtures if PROTOCOL bumps), optionally thin helpers for synthetic `onFinish`
- **Deps:** none for walk-in audit; PROTOCOL/`npcId` for invite path
- **Accept:** Walk-in joiner never sees immediate FIGHT after co-op win; invite joiner gets defeat flag + prize + afterBattle/script; host unchanged

### T4 — Trainer theatrical intro chrome
- **Owns:** `src/CoopBattle.lua` intro / appear / foe chrome draw path (disjoint sections from T1/T2 where possible — **wave after T1+T2** to avoid collisions)
- **Deps:** T1/T2 landed
- **Accept:** Trainer coop intro shows deferred foe/theatrical frame without breaking ally ball chrome / Ball_Poof

> **Partition note:** T1 and T2 both touch `CoopBattle.lua`. Run as **one builder agent (T1+T2)** or strict sequential waves. T3 is file-disjoint from MediatedBattle-only pieces of T1 but overlaps Coop.lua only. T4 after T1+T2.

## 5. Work breakdown — test tasks

### TT1 — SFX unit/integration
- **Covers:** T1
- **Owns:** `tests/rby_mmo_test.lua` (extend Coop/Mediated anim fixtures with fake AnimPlayer emitting `{ sound = … }` and assert Sound stubs called; SFX_TINK on shake anim)
- **E2e:** not required (audio stubs); ear-check note in CHANGELOG if assets missing

### TT2 — Music / HP order
- **Covers:** T2
- **Owns:** `tests/rby_mmo_test.lua` — final multi-attacker KO: assert victory music act runs only after drains/faint sink; drain clamp; stripShows while truth dead / display alive
- **E2e:** extend `tests/drivers/mmo_quad.lua` only if it can observe display clock; else document headless limit (truth `mon.hp` already watched)

### TT3 — Joiner rematch / rewards
- **Covers:** T3
- **Owns:** `tests/rby_mmo_test.lua` — walk-in: engine unwound + consume; invite: `defeatedTrainers` + money delta + afterBattle/script hook fired. Drivers: `mmo_guest.lua` / `mmo_join.lua` assert no post-battle re-engage / no leftover onStack BattleState for joiner
- **E2e:** applicable — joiner after coop_npc win must not immediately re-enter battle; run `bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh` from engine checkout when ROM present; if ROM absent, maximal headless subset + manual runbook

### TT4 — Theatrical chrome
- **Covers:** T4
- **Owns:** `tests/rby_mmo_test.lua` intro order assertions (foe chrome present during appear, cleared before Go!)

**E2e applicability:** Rematch (TT3) yes. SFX/music order mostly unit. Recipe: engine at `~/Projects/alamops/gen1recomp`, mod symlinked as `mods/rby_mmo`, ROM via `scripts/setup.sh`, then `bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh`. Also `luajit mods/rby_mmo/tests/rby_mmo_test.lua`, `node server/hub.test.js`, twin parity if Wire/Hub touched.

## 6. Execution waves

| Wave | Tasks | Barrier |
| --- | --- | --- |
| 1 | **T1+T2** (single agent, `CoopBattle`+`MediatedBattle`) | Checkpoint + commit |
| 2 | **T3** rematch/wire | Checkpoint + commit |
| 3 | **T4** theatrical chrome | Checkpoint + commit |
| 4 | **TT1–TT4** test authoring (parallel where file-disjoint; suite file may need one agent or sequential appends) | |
| 5 | Test run → fixes | |

## 7. Blast radius & risks

- **CoopBattle message queue** — music deferral must still play under defeat/parting text (engine parity), not only at `finish()`.
- **PROTOCOL bump** — Hub.lua + relay.js + parity fixtures; older clients ignore unknown fields if sanitiser allows.
- **Synthetic afterBattle** — must not double-pay prize or double-blackout when walk-in engine exists; gate on `engineBattle == nil`.
- **Ambiguous Bug Catchers on Route 3** — wire waiter’s concrete `npcId`, never fuzzy class+lead match.
- **Rollback** — revert branch commits; no save migration.

## 8. Open questions / assumptions

1. **Assumed:** Immediate FIGHT UI ⇒ walk-in buried stack (or sight engage so fast it feels instant). Plan fixes both walk-in unwind and invite defeat/rewards.
2. **Assumed:** Prize formula for invite joiners matches `M:consume` (best enemy level × `baseMoney`).
3. **Assumed:** Theatrical chrome = deferred trainer/foe intro frame from intro-anims plan, not a full LinkBattle theatrical rewrite.
4. **Assumed:** No SFX PROTOCOL; audio stays client-derived.
5. If joiner rematch still reproduces only on invite path after T3, treat stack path as verified and concentrate on synthetic finish + sight.
