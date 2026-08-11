# Guild focus battle UI (CoopBattle)

Status: **complete** (suite green; e2e shots pending review)
Approved: 2026-08-10
Shipped: focus stage + side strips in `src/CoopBattle.lua`

## Locked decisions

- **Scope:** `CoopBattle` only. Classic `MediatedBattle` 1v1 layout unchanged.
- **Strips:** active **field seats** only (not full benches).
  - Party vs NPC: ally icons = living ally field seats; foe icons = living foe
    field seats (1–N; no empty pads when the trainer has one mon).
  - Party vs Party: one icon per party member’s active field seat.
- **Choose-phase center:** always **your** active mon on the player half;
  partner appears in center only when they act or are targeted.
- **Uneven foes:** right strip and center foe slot only show real living field
  foes.

## UX

- Center = classic Gen1 1v1 (one foe front + one ally back + single name/LV/HP).
- Left strip = ally field seats; right = foe field seats; arrows follow focus.
- Lateral slide in/out when the focused mon changes.
- Command box stays FIGHT / PKMN / ITEM / RUN.

## Focus rules (viewer-local)

| Situation | Ally focus | Foe focus |
|---|---|---|
| `choose` / `move` / item menus | `mine` | last foe / first living foe |
| `target` picker | `mine` | hovered target |
| `messages` / anim / drain | actor or hit ally | actor or hit foe |
| `wait` | `mine` | last foe |

## Out of scope

- MediatedBattle 1v1 layout
- Full 6-mon bench strips
- Spreading/scaling the old 4-sprite field
- Hub field seating rules
