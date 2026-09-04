# Plan — Classic battle UI option

| Field | Value |
| --- | --- |
| Date | 2026-09-02 |
| Source | conversation (screenshot + "classic battle UI" toggle) |
| Config | AGENTS_CONFIG.yml (quality / v3, host=cursor) |
| Flags | none (grill skipped by owner — assumptions logged in §8) |
| Gates | self-approved after skipped grill |
| Branch | feature/classic-battle-ui-option |
| Base SHA | 93d2a3354ce1a3ae5db8401eabb8a36765f5d40f |

## 1. Objective & success criteria

Add a **default-off** mod-manager toggle that switches MMO fights from the 640×360 Battlefield theatre to the existing classic 160×144 Gen 1 chrome (engine `Font.drawBox` / `HudTiles` from the player's ROM). 2x2 / 3x3 use guild-focus: one center pair + side thumbnails of **every living field seat** (including the focused pair); the arrow marks who is in the middle.

Success when:

1. The row is off by default and flipping it does not change a fight already on screen.
2. With it on, 1v1 / solo / 2x2 / 3x3 / coop NPC+wild all use 160×144 chrome.
3. Turns, items, status, PP, switch, run, targeting, wait lines, learn-move, and evolution still work.
4. The focused-ally HUD shows an EXP bar that crawls on award.
5. No ROM-derived bytes are added to the repo. `Battlefield.enabled` (generation gate) is untouched — peers hold that file.

## 2. Context & constraints

- `Battlefield.enabled` is true for Gen 1 and Gen 2. Classic chrome is the `usesBattlefield() == false` fallback, already implemented in `MediatedBattle` (1v1) and `CoopBattle` (guild-focus strips).
- Guild-focus (`docs/plans/guild-focus-battle-ui.md`) is the screenshot: center 1v1 + left/right field-seat strips + FIGHT/PKMN/ITEM/RUN.
- Legal: HUD tiles and boxes come from the player's decoded ROM via engine `HudTiles` / `Font`. Same rule as `composeRomArena`.
- Peers: yellow-bay claims `src/Battlefield.lua` (custom BGs); keen-cedar is on HUD PP. This plan does **not** edit `Battlefield.lua`.

## 3. Approach & key decisions

| Concern | Choice | Why |
| --- | --- | --- |
| Skin switch | Latch `classicUi` at screen construct; `usesBattlefield()` returns false | Avoids mid-fight chrome swap; does not touch `Battlefield.enabled` |
| Scope | Every MMO battle screen | "our battle system" |
| 2x2 / 3x3 | Guild-focus strips of **every** living seat; arrow on the focus | Rail is the whole side; center pair is not omitted |
| EXP | Queue the existing fill on classic; draw a Gen2-style 1px bar on the ally HUD | Feature parity; authentic RBY had no bar |
| Option home | `src/ClassicBattle.lua` owns key/label (SoloBattle pattern) | Client defines the row; both screens read the same constant |

## 4. Work breakdown — implementation

- **T1** `src/ClassicBattle.lua` + `src/Config.lua` + `src/Client.lua` — option row, `wanted` / `latched` / `drawExpBar`
- **T2** `src/MediatedBattle.lua` — latch, gate, classic EXP draw + fill
- **T3** `src/CoopBattle.lua` — latch, gate, `enter()` load, side strips (`stripSeats`), ally EXP, fill + snap weld
- **T4** tests + CHANGELOG

## 5. Tests

Unit/integration in `tests/rby_mmo_test.lua` (option schema, gate, `stripSeats`, classic expfill). Visual skin: `tests/drivers/run-classic-battle-e2e.sh` (one LOVE instance, GAPS:0 on `classic_battle_shot.lua`). Headless suite cannot assert ROM HUD pixels; that driver photographs them.

## 6. Execution waves

Single wave (tightly coupled; orchestrator implements to avoid Battlefield collision).

## 7. Blast radius

`usesBattlefield()` is the existing switch. Tests that stub it stay valid. Tests that documented "classic has no exp strip" are updated — that was the old decision.

## 8. Open questions / assumptions (grill skipped)

| Question | Assumption | Source | Confidence |
| --- | --- | --- | --- |
| Which fights? | All MMO screens | recommended | high |
| When does the flip apply? | Next battle (latched) | SOLO BATTLES convention | high |
| EXP look? | Ally HUD bar + crawl | owner asked for exp bar | medium |
| Label? | CLASSIC BATTLE UI | matches ask | high |

## 9. Completeness ledger

| Item | Disposition |
| --- | --- |
| Option schema + Client row | in this run (T1) |
| MediatedBattle + CoopBattle gates | in this run (T2/T3) |
| 2x2/3x3 thumbnails | every living seat + bag icons (T3); e2e via `run-classic-battle-e2e.sh` |
| EXP fill + draw on classic | in this run (T2/T3) |
| Tests that pinned "no classic exp" | in this run (T4) — updated, not left stale |
| Custom arena / Battlefield.lua | out of scope (peer branch; generation gate unchanged) |
| Shipping ROM HUD art | out of scope (illegal) |
