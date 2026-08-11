# Plan — CoopBattle intro anims (balls + sequential Go! / POOF)

| Field | Value |
| --- | --- |
| Date | 2026-08-11 |
| Source | `/implement` after catch-path e2e; missing intro vs solo wild |
| Config | AGENTS_CONFIG.yml (quality/v3, host=cursor) |
| Branch | `fix/party-wild-encounter` |
| Base SHA | 243ee6de38b63bddeb745c10a9a12c85a4202962 (dirty tree: ball-chain + catch e2e already present) |

## 1. Objective & success criteria

Bring CoopBattle openings closer to Gen1 wild/trainer feel **without** silhouette slide or trainer-back walk-off:

1. **Intro ball chrome** for **both** humans’ parties while the opening line is up, then clear.
2. **Sequential ally send-out:** local `"Go! X!"` → `POOF_ANIM` + `Ball_Poof` → grow-in + entrance cry; then partner `"Name sent out Y!"` → same POOF/grow/cry.
3. **`Ball_Poof` SFX** on every `POOF_ANIM` (intro **and** catch chain).
4. Applies to **all CoopBattle modes** (`coop_wild`, `coop_npc`, party-vs-party, etc.) — not MediatedBattle 1v1.

**Done when:** headless tests assert ordered intro lines + POOF for `coop_wild` and one non-wild mode; `startAnim` plays `Ball_Poof`; party-wild e2e still reaches command menu (longer intro dwell OK); no PROTOCOL bump.

## 2. Context & constraints

- Solo engine sequence (BattleState): slide → appear + **local** balls → clear → gap → back off → Go! → POOF/`Ball_Poof` → grow-in + cry. Wild foe is already on field (no enemy ball send-out).
- Coop today: music + one line (`Wild X appeared!` / `2 on 2 battle!`) → choose. Mons already full-size from `CoopSim:sendOut` at construct.
- Catch toss/shake already uncommitted on this branch — intro work must not break `_emitBallChain` / `medBall` / `foePicHidden`.
- Guild-focus layout stays; intro must not invent a second stage system.
- Owner decisions (Phase 2): **all modes**; **both allies sequential**; **skip introSlide/back**; **both parties’ ball chrome**.

## 3. Approach & key decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Scope | All `CoopBattle` modes | Owner |
| Slide / trainer-back | **Skip** | Owner C; avoids fighting 2-ally layout |
| Ball chrome | Both humans’ parties | Owner B — two rows (or one row each side) under appear text |
| Go! | Local then partner `"sent out"` | Owner B; matches Mediated mid-send split |
| Grow-in | Hide ally pics until their send-out step (`sendingOut` / per-slot flag), then scale 0→full over ~12f | Otherwise full-size mons flash under the appear line |
| Foe intro | No trainer/enemy ball send-out in this pass | Wild foe already visible; trainer foe chrome deferred |
| MediatedBattle | Out of scope | Owner: CoopBattle only |
| SFX | Load `Sound` in `loadEngine`; `Ball_Poof` on `POOF_ANIM` in `startAnim` | Shared with catch |
| Queue | Local cinematic in `enter()` via existing messages/anim/`act`-like rows **before** `after=choose`; do not wait on hub `send` | Intro is presentation, seats already exist |
| Timing | Approximate engine: short gap (~40f) between appear dismiss and first Go!; POOF uses AnimPlayer | Exact 72f slide unused |

**Opening copy (unchanged):**
- `coop_wild` → `Wild %s\nappeared!`
- else → `2 on 2 battle!`

## 4. Work breakdown — implementation

### T1 — Sound + Ball_Poof on POOF
- **Owns:** `src/CoopBattle.lua` (`loadEngine`, `startAnim` only for SFX hook)
- **Does:** grab `Sound`; on `POOF_ANIM`, `pcall(Sound.play, data, "Ball_Poof")` (nil-safe headless).
- **Accept:** catch and intro POOFs both attempt SFX; no throw without Sound.

### T2 — Intro state + ball chrome draw
- **Owns:** `src/CoopBattle.lua` (flags, `draw` / HUD path for balls)
- **Does:** `introBalls` (or equivalent) true for opening line; draw **two** player ball rows (local + partner party HP/alive counts via HudTiles / engine ball-row helper if exposable, else minimal replicate); clear when appear text advances.
- **Accept:** chrome visible only during opening message; cleared before Go!.

### T3 — Sequential Go! / POOF / grow-in queue
- **Owns:** `src/CoopBattle.lua` (`enter`, message/`act` queue, draw gates for `sendingOut` / `growIn`)
- **Does:** After appear + clear balls: wait → local Go! → queue `POOF_ANIM` → grow-in + cry for **mine**; then partner line → POOF → grow-in + cry for partner seat; hide those ally sprites until their step; then `after=choose`.
- **Accept:** order stable; partner line uses roster name; single-human edge (if any) skips partner step; `coop_wild` foe never gets a send-out POOF from intro.

**Wave note:** T1–T3 all touch `CoopBattle.lua` → **one sequential wave** (single builder agent), not three parallel agents.

## 5. Work breakdown — tests

### TT1 — Unit / headless
- **Owns:** `tests/rby_mmo_test.lua` and/or `tests/coop_mediated.lua`
- **Does:** Construct CoopBattle `coop_wild` + one non-wild mode; stub Sound; drain update until `choose`; assert message order (`Wild…`/`2 on 2` → `Go!` → partner `sent out`); assert a `POOF_ANIM` was started; stub records `Ball_Poof`.
- **E2e:** existing `run-party-wild-e2e.sh` — no new driver required; may need slightly longer patience to command menu. Assert e2e still green (optional log that intro reached Go! if easy).

E2e applies: party-wild already exercises CoopBattle open; re-run after impl.

## 6. Execution waves

1. **Wave A:** T1+T2+T3 in one agent (single-file ownership).
2. **Wave B:** TT1 tests + re-run unit suite + party-wild e2e.

## 7. Blast radius & risks

- Longer intro delays first choice — e2e/command-menu waits must tolerate dwell.
- Both-party ball chrome on guild-focus layout may need compact placement; prefer classic bottom-box adjacent positions.
- Grow-in hide must not blank partner forever if intro interrupted (forfeit / disconnect) — clear flags on `exit` / `over`.
- Do not emit new wire events; intro is client-local (both clients run the same local cinematic from their seat view — each client’s “local” is themselves, so each hears their own Go! first). **Clarify:** each client runs intro from **viewer** perspective: my Go! then partner sent-out. That keeps asymmetry correct without hub sync.

## 8. Open questions / assumptions

- **Assumed:** “Both parties” chrome = two Gen1-style ball icon rows (local + partner), not foe trainer balls.
- **Assumed:** Non-wild modes keep `"2 on 2 battle!"` as the appear line (no trainer theatrical frame this pass).
- **Assumed:** Grow-in scale can approximate engine 0 / 3/7 / 5/7 over ~12 frames without pixel-perfect feet pin.
- **Deferred:** `introSlide`, trainer-back, MediatedBattle wild parity, foe trainer send-out grow-in.
