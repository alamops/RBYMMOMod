# Hub twin parity (Hub.lua ↔ relay.js)

Two hosting paths speak one protocol: the in-game LAN host (`src/Hub.lua`) and
the dedicated Node hub (`server/lib/relay.js`). A joining client must not be
able to tell which one refereed the session. Drift is the standing hazard.

## What stays twin

| Surface | Lua | Node | Guard |
|---|---|---|---|
| PROTOCOL / identity length / battle clocks / default sprite | `src/Config.lua` | `server/lib/relay.js`, `server/lib/sanitize.js` | `server/twin_parity.test.js` |
| Shared hello refuse wording | `src/Hub.lua` | `server/lib/relay.js` | twin_parity + hub_protocol_parity |
| Admit / duplicate playerId / mediated settle / relay hard-cut / bag proofs / sprite+chat gates / coop 2v2 / ranking ids | `src/Hub.lua` | `server/lib/relay.js` | `tests/drivers/hub_protocol_parity.lua` → `tests/fixtures/hub_protocol_parity.json` ↔ `server/hub_protocol_parity.test.js` |
| Inbound client→hub type list | `src/Wire.lua` + Hub handlers | `relay.js` handlers | `server/twin_parity.test.js` |
| BattleSim formulas + turn machine | `src/BattleSim/` | `server/lib/battle/` | `battle.test.js`, `battle_turn.test.js` |
| Rank board math | `src/Rank.lua` | `server/lib/rank.js` | `rank.test.js` + hub parity board digests |
| Wire sanitizers | `src/Wire.lua` | `server/lib/sanitize.js` | suites + PLAYER_ID_HEX gate |

## Intentional Node-only (not twins)

Live-ops that only exist on the dedicated hub:

- Admin control socket (`kick`, `broadcast`, player listing)
- Bans / allowlist / auth throttle / join-code CSPRNG
- UPnP, Docker packaging, `rby-mmo-hub` CLI, config file schema
- Log redaction and structured ops logging

Do **not** invent a Lua twin for these. Document a new Node-only surface here
when you add one.

## Process gate (every twin edit)

1. Edit **both** halves in the same change (or the pure core both call).
2. If PROTOCOL / PLAYER_ID_HEX / battle grace / refuse copy moves, run
   `node --test server/twin_parity.test.js`.
3. If admit / settle / hard-cut behaviour moves, regenerate and commit the
   hub fixture:

```sh
luajit tests/drivers/hub_protocol_parity.lua . > tests/fixtures/hub_protocol_parity.json
node --test server/hub_protocol_parity.test.js
```

4. If BattleSim draw sites move, regenerate `battle_turn_parity.json` the same way.
5. Do **not** codegen or transpile Lua↔JS. Keep extracting pure cores when a
   third copy appears.

## Related

- `docs/plans/self-hosting-server-app.md` — dedicated hub product plan
- `mod.card` known-jank — player-facing twin-upkeep note
