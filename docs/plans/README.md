# Plans

Working notes for features that were (or are being) implemented in this repo.

**Live contract** is always `Config.PROTOCOL` / `server/lib/relay.js` `PROTOCOL`,
`CHANGELOG.md`, and the code. Plan files below are **not** the wire truth.

## Living

| Plan | Notes |
| --- | --- |
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
