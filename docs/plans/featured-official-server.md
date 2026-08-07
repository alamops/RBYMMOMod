# Plan — Featured Official Server

| Field | Value |
| --- | --- |
| Date | 2026-08-07 |
| Source | `/implement` request: add an always-first featured RBY MMO official server |
| Config | `AGENTS_CONFIG.yml` (quality) |
| Branch | feature/rby-mmo-official-server |
| Base SHA | f81c4db7e569a4cd23660394c7f7b97ba79b2089 |

## 1. Objective & success criteria

Make `SERVERS` available to every disconnected, non-hosting player. Its first
entry is the built-in official RBY MMO server:

- label: `RBY MMO OFFICIAL`
- host: `play.rbymmo.com:7788`
- join code: `QG0251`

The entry is always first, including when the player has no saved recents. It
connects through the same address/code path as a remembered server, cannot be
deleted or edited, does not consume the saved-server cap, and never appears
twice after connecting to it. Saved/favourited servers remain below it.

## 2. Context & constraints

- The disconnected MMO menu currently adds `SERVERS` only when
  `#serverList() > 0` (`src/Ui.lua:1107-1125`); hosting and connected states
  intentionally omit it (`src/Ui.lua:997-1106`).
- `Servers:list()` is the ordered source for the list UI
  (`src/Servers.lua:305-316`, `src/Ui.lua:1712-1735`). Persisted rows are
  favourites first, then descending address.
- Server action screens currently expect every row to be a mutable saved row
  (`src/Ui.lua:1739-1875`). The featured row must therefore expose only
  `CONNECT`, rather than passing through saved-row mutators.
- `CONNECT` already supplies a row's `address` and `code` to the normal join
  flow (`src/Ui.lua:1791-1812`), so no client protocol change is required.
- Successful welcome records a dialled server (`src/Client.lua:1429-1464`),
  so presentation must deduplicate the official address against the persisted
  store rather than pre-seed it in persistent data.

## 3. Approach & key decisions

1. Put the official server's canonical metadata in `Config`, keeping it
   explicit about port `7788` so normal default-port configuration cannot
   change its identity.
2. Build a synthetic `featured` entry in `Servers:list()` and prepend it
   before all persisted rows. Filter any persisted row with the same normalized
   key. This guarantees ordering, avoids persistence/cap/eviction effects,
   and keeps the entry after a user deletes all recents.
3. Keep the list title as `SERVERS`; the first row's canonical label identifies
   the official feature without extending the shared list-menu component with
   selectable section headings.
4. Give featured entries a CONNECT-only action screen. The server address,
   code, name, ordering, and presence are product-owned, so no favorite,
   rename, host/code edit, or delete action is offered.
5. Preserve `SERVERS` visibility only while offline/not hosting; the existing
   connected and hosting exclusions remain unchanged.

## 4. Work breakdown — implementation

### Wave 1

**I1 — featured-server model and menu wiring**

- Owns: `src/Config.lua`, `src/Servers.lua`, `src/Ui.lua`
- Add canonical official-server configuration and list projection with
  synthetic featured entry, fixed first ordering, and persisted-key dedupe.
- Change the disconnected MMO menu to always show `SERVERS`.
- Render the featured entry normally and provide CONNECT-only actions; route
  through existing connection/code machinery.
- Acceptance: the player can select and connect to the official entry on a
  new install; it stays at index one before favourites and recents; it cannot
  be removed or altered; hosting/connected behavior is unchanged.

## 5. Work breakdown — tests

### Wave 2

**T1 — Lua store and UI coverage**

- Owns: `tests/rby_mmo_test.lua`
- Assert featured metadata, first ordering, empty-persistence visibility,
  dedupe after recording the official address, recents/favourites below it,
  CONNECT-only actions, and always-visible offline menu behavior.

**T2 — end-to-end driver expectation update**

- Owns: `tests/drivers/mmo_join.lua`
- Update the existing delete-to-empty-recents assertion: deleting the final
  remembered server leaves the built-in featured server and the `SERVERS`
  menu reachable. Do not dial the production official host in CI.

**E2E applicability:** applicable because this changes a player-visible menu
flow. Extend the existing deterministic driver assertion; it must not depend
on the live official server.

## 6. Execution waves

1. Implement I1.
2. Review the production diff.
3. Create T1 and T2 in parallel (disjoint files).
4. Run the Lua suite; run the MMO e2e driver when its engine/ROM prerequisites
   are available.

## 7. Blast radius & risks

- Existing store tests that count or index `list()` rows must account for the
  synthetic entry.
- Existing delete e2e expects `SERVERS` to disappear after the last saved row;
  that behavior intentionally changes.
- External `mod.exports.servers()` currently exposes stored recents. The
  feature will not change that persistence-facing API unless inspection during
  I1 proves UI and export must share the same projected list; this protects
  callers that rely on exports to mean saved history.
- The official server's success must not create a second visible entry; list
  projection handles this by normalized key.

## 8. Open questions / assumptions

- Assumed canonical display label: `RBY MMO OFFICIAL`.
- Assumed feature ownership: the official row is CONNECT-only and cannot be
  customized or deleted. This is the safest interpretation of “always.”
- No release-note or version bump is included: this is a focused behavioral
  change, not a requested release preparation.
