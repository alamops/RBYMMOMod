# Plan — Classic battle UI follow-up

| Field | Value |
| --- | --- |
| Date | 2026-09-04 |
| Source | conversation (five post-1.3.0 classic shots / bugs) |
| Config | AGENTS_CONFIG.yml (quality / v3, host=cursor) |
| Flags | none (grill skipped — recommended defaults) |
| Gates | self-approved after skipped questions |
| Branch | fix/classic-ui-followup |
| Base | origin/main (`07f5ae4`, shipped 1.3.0 / #78) |

## 1. Objective & success criteria

Fix five classic-chrome bugs reported after 1.3.0 deployed. Theatre path stays as-is. `Battlefield.lua` is not edited.

1. FIGHT lists every known move and shows TYPE/ + PP of the selected one (vanilla RBY pane).
2. Battle text wraps inside the 18-column box (no clip, collapsed whitespace).
3. HP bar stays at the pre-hit value through the move anim, then crawls to truth.
4. Opponent remaining party is visible for trainers / PvP / 2×2 / 3×3 / NPCs (not wild).
5. Dig / Fly hide on the charge turn and only resolve (emerge + drain) on the release turn.

## 2. Approach

| Bug | Cause | Fix |
| --- | --- | --- |
| FIGHT empty right | `MediatedBattle.drawMoves` is `drawList` of ids, max 3 rows | Port Coop's two-pane TYPE/PP; 4 names |
| Message clip | `drawBox` paints one unwrapped line | `ClassicBattle.wrapBoxLines` at draw; 18×2 |
| HP snap | `noteSlot` welds `shownHp` when `not usesBattlefield()` | Stop welding; keep `queueDrain` (already ungated) |
| No remaining | Classic never drew live ball rows | One row on the foe plate bottom (`FOE_BALL` 24,32); flatten 2×2/3×3 |
| Dig/Fly instant | `startVanish` theatre-gated; classic plays full AnimPlayer | Vanish hold on classic; skip hit anim on charge |

## 3. Completeness ledger

| Item | Disposition |
| --- | --- |
| Mediated + Coop FIGHT / wrap / vanish / balls | in this run |
| `noteSlot` + classic drain test rewrite | in this run |
| Theatre / Battlefield.lua | out of scope |
| Wild ball row | out of scope (vanilla has none) |

## 4. Tests

Headless in `tests/rby_mmo_test.lua`: wrap, partyFromRoster, classic FIGHT rows, shownHp holds then drains, vanishFlow on classic DIG charge. E2e remains `run-classic-battle-e2e.sh` (visual).
