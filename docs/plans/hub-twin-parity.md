# Hub twin parity (Hub.lua ↔ relay.js)

Two hosting paths speak one protocol: the in-game LAN host (`src/Hub.lua`) and
the dedicated Node hub (`server/lib/relay.js`). A joining client must not be
able to tell which one refereed the session. Drift is the standing hazard.

## What stays twin

| Surface | Lua | Node | Guard |
|---|---|---|---|
| PROTOCOL / identity length / battle clocks / default sprite | `src/Config.lua` | `server/lib/relay.js`, `server/lib/sanitize.js` | `server/twin_parity.test.js` |
| Generation lock (1\|2\|3; an unknown generation refused, not clamped; a missing one read as 1) + the cart `version` vocabulary on hello / presence (kept only when it belongs to the admitted generation) | `src/Config.lua`, `src/Wire.lua`, `src/Hub.lua` | `server/lib/config.js`, `server/lib/sanitize.js`, `server/lib/relay.js` | `server/twin_parity.test.js` (`GENERATION_MAX`, `VERSIONS`, `defaultSpriteFor`), `hub_protocol_parity` `generation_*` cases (Gen 3 hub seats every Gen 3 cart; 1↔3 and 2↔3 refused; unknown refused, missing is 1), `server/gen3.test.js` (real sockets, `--generation 3` and `RBY_MMO_GENERATION=3`) |
| Gen 3 battle dialect: the sheet / ruleset / bag / choice / event reads (C4, C5), sim selection by generation (`battleSimFor`), numeric bags kept in step with the sim | `src/Wire.lua`, `src/Hub.lua` | `server/lib/sanitize.js`, `server/lib/relay.js` | `hub_protocol_parity` `gen3_dialect`, `gen3_wire_edges`, `gen3_event_stream`, `gen3_mediated_fight`, and `gen12_read_paths` (a stray Gen 3 field never changes a Gen 1/2 reading); `server/hub_battle.test.js` + `tests/hub_battle.lua` |
| Shared hello refuse wording | `src/Hub.lua` | `server/lib/relay.js` | twin_parity + hub_protocol_parity |
| Admit / duplicate playerId / mediated settle / relay hard-cut / bag proofs / sprite+chat gates / coop 2v2 / ranking ids | `src/Hub.lua` | `server/lib/relay.js` | `tests/drivers/hub_protocol_parity.lua` → `tests/fixtures/hub_protocol_parity.json` ↔ `server/hub_protocol_parity.test.js` |
| Inbound client→hub type list | `src/Wire.lua` + Hub handlers | `relay.js` handlers | `server/twin_parity.test.js` |
| BattleSim formulas + turn machine | `src/BattleSim/` | `server/lib/battle/` | `battle.test.js`, `battle_turn.test.js` |
| BattleSim2 (Gold) | `src/BattleSim2/` | `server/lib/battle2/` | `battle2_vectors.test.js`, `battle2_turn.test.js` |
| BattleSim3 (FireRed / LeafGreen / Emerald) | `src/BattleSim3/` | `server/lib/battle3/` | `tests/fixtures/battle_sim3_vectors.json` + `battle3_turn_parity.json`, run by `tests/battle_sim3_*.lua` and `server/battle3_*.test.js`; contract `docs/plans/gen3-battle-sheet.md` |
| Rank board math | `src/Rank.lua` | `server/lib/rank.js` | `rank.test.js` + hub parity board digests |
| Wire sanitizers | `src/Wire.lua` | `server/lib/sanitize.js` | suites + PLAYER_ID_HEX gate |

## Intentional Node-only (not twins)

Live-ops that only exist on the dedicated hub:

- Admin control socket (`kick`, `broadcast`, player listing)
- Bans / allowlist / auth throttle / join-code CSPRNG
- UPnP, Docker packaging, `rby-mmo-hub` CLI, config file schema
- Log redaction and structured ops logging
- The settled-battle ledger (`history.jsonl`) and the `onMatchSettled` hook
  that feeds it. The in-game host scores battles the same way — `ranking ids`
  above is a real twin — but it keeps no ledger file, so there is deliberately
  no Lua half of `Relay.noteMatchSettled`. That method owns the record's shape
  for both of its callers (`settleMediated` and `settleMatch`); it used to be
  spelled out at each, which meant only one of the two was ever executed by a
  test. Pinned now by `server/rank.test.js` (both paths) and
  `server/server.test.js` (over real sockets).

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
   **`BattleSim2` has its own pair** — regenerate `battle2_turn_parity.json`
   whenever a Gen 2 draw site, the `exp` payout, the replace phase or
   `_retarget` moves:

```sh
luajit tests/drivers/battle2_turn_parity.lua . > tests/fixtures/battle2_turn_parity.json
node --test server/battle2_turn.test.js
```

   **`BattleSim3` keeps its scenarios once**, as scripts in the fixture: the
   Lua suite writes the expectations and the Node suite replays the same steps
   against `Turn.js`. After a deliberate rule change in *both* twins:

```sh
luajit tests/battle_sim3_turn.lua --update
node --test server/battle3_turn.test.js server/battle3_vectors.test.js
```

5. Do **not** codegen or transpile Lua↔JS. Keep extracting pure cores when a
   third copy appears.

## Related

- `docs/plans/self-hosting-server-app.md` — dedicated hub product plan
- `mod.card` known-jank — player-facing twin-upkeep note
