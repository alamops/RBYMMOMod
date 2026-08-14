# Plans

Working notes for features that were (or are being) implemented in this repo.

**Live contract** is always `Config.PROTOCOL` / `server/lib/relay.js` `PROTOCOL`,
`CHANGELOG.md`, and the code. Plan files below are **not** the wire truth.

## Living

| Plan | Notes |
| --- | --- |
| [`fix-battle-system-v2-quarkst.md`](fix-battle-system-v2-quarkst.md) | Attack SFX, win-music/HP race, joiner rematch (PROTOCOL 20) |
| [`gen2-compatibility.md`](gen2-compatibility.md) | Dual Gen1+Gen2 hubs, BattleSim2, trade, co-op, e2e — shipped |
| [`gen2-new-battle-system.md`](gen2-new-battle-system.md) | The arena, the band, exp and retargeting on Gold — shipped |
| [`party-wild-encounter.md`](party-wild-encounter.md) | Party vs Wild (`coop_wild`) — in progress |
| [`coop-battle-intro-anims.md`](coop-battle-intro-anims.md) | CoopBattle intro balls + sequential Go!/POOF — implemented |
| [`guild-focus-battle-ui.md`](guild-focus-battle-ui.md) | CoopBattle focus stage + side strips |
| [`hub-twin-parity.md`](hub-twin-parity.md) | Hub.lua ↔ relay.js drift process + carve-outs |
| [`battle-sim-move-effects.md`](battle-sim-move-effects.md) | Complete; locked BattleSim decisions |

## Historical

Everything else under this folder is a **shipped or superseded** design note.
Many cite PROTOCOL numbers or product versions that are no longer current.
Each file starts with a historical banner; keep them for design history, do
not treat line citations as today's API.

Notable:

| Plan | Was about | Superseded by |
| --- | --- | --- |
| `server-authoritative-battle-system.md` | PROTOCOL 10 intermediator | Shipped; see BattleSim + CHANGELOG |
| `server-side-listing.md` / `server-live-ops.md` | CLI players/ranking/history | Shipped; PROTOCOL was 5 then |
| `self-hosting-server-app.md` | Dedicated hub packaging | Shipped; PROTOCOL 2 era |
| `running-system.md` / `online-char-selection.md` / `in-game-notifications.md` | Early protocol bumps | Shipped; see CHANGELOG PROTOCOL history |
| Coop UX plans (`coop-*.md`) | Pre-mediation co-op polish | Mediated coop always-on |

When starting new work, prefer a new plan (or extend a living one) over editing
historical files as if they were the backlog.
