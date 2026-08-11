> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — Character selection from the connected MMO menu, propagated live

| Field | Value |
| --- | --- |
| Date | 2026-08-05 |
| Source | /implement follow-up to docs/plans/new-char-selection.md |
| Config | AGENTS_CONFIG.yml (quality preset) |
| Branch | feature/new-char-selection |
| Base SHA | 6f1914e8e2d7c6bfab2a9e95d9d20cec1b72105d |
| Mode | **Autonomous** — grill/approval gates bypassed (unattended session); assumptions in §8. |

## 1. Objective & success criteria

A connected player can open the MMO menu, pick a character, and **everyone in the game sees
the change live**: hub roster, walking avatars on other screens, trainer cards, town-map
markers. Works for guests and the in-game host, over both hubs (in-game `src/Hub.lua` and
the node `server/lib/relay.js`). Success = both hub suites pin the mirrored behavior with
identical assertion strings, the Lua suite pins client/roster/avatars/UI, both e2e drivers
green including a new mid-session change-and-peer-sees-it leg.

## 2. Context & constraints (grounded)

- Sprite crosses the wire once: `sendHello` (src/Client.lua:929-948, field at 941). Both
  hubs store it only at admit (`src/Hub.lua:519`, `server/lib/relay.js:590`) and echo it
  forever via `presenceOf` (Hub.lua:396-423, relay.js:91-125) in WELCOME/JOIN/MOVE.
- Unknown message types are silently dropped by both hubs (Hub.lua:1136-1141,
  relay.js:1068-1080) and by the client (Client.lua:1381-1384). Repo rule (decision entry
  + Config.lua:8-41 header, three precedents): a client sending something an old hub
  silently ignores ⇒ **bump PROTOCOL**. Currently 5, defined in src/Config.lua and
  exported from server/lib/relay.js:41-60,1086 — bumped together. Refusal happens only at
  hello (Hub.lua:851-854, relay.js:138-140); suites read the constant, so happy-path
  tests need no edits.
- The mid-session broadcast template is `publishPoints`/`Wire.RANK`: hub stores + broadcasts
  **with no exception** so the subject hears it too (Hub.lua:768-779, relay.js:954-959);
  client handler forks self/other (Client.lua:1282-1293); roster setter mutates the entry
  **in place** (`setPoints`, Roster.lua:60-67) — never `put()` (table replace), because
  `Card.new` holds the entry by reference (Ui.lua:398) and an open card must keep updating.
- Avatars bake `player.sprite` at spawn only (Avatars.lua:208-225); `advance`/`sync` never
  re-read it; the only re-render mechanism is despawn+respawn (`resync`, Avatars.lua:310-313).
  `spriteFor` (88-100) already degrades unknown ids safely.
- Leaderboard sprite is seeded once at hello via `Board:seen` (Hub.lua:565, Rank.lua:269-273);
  the RANKING snapshot client-side refreshes only on request — same staleness points already
  have.
- Connected menu (src/Ui.lua:799-889): guest = 7 rows, hosting = 8 rows (exactly
  `maxVisible = 8`, Ui.lua:942). Adding CHARACTER ⇒ 8 / **9 (first-ever scroll on this
  screen)** — Menu:clampScroll supports it; verify visually in e2e. House ordering
  rationale (Ui.lua:838-845, "outward → inward, ending at yourself") puts CHARACTER after
  RANK, before LEAVE/END GAME (insert before Ui.lua:867). The hosting-but-not-connected
  edge state (Ui.lua:793-798, ADDRESS+END GAME only) does NOT get the row.
- CHARPICK is connection-agnostic and already has the `backTo` door (Ui.lua:990-1031,
  1004-1007). Mid-session `setSpriteChoice` → `syncLook` → `applyLook` is stash-safe:
  `lookOwner` is already the live entity, so no re-stash (Client.lua:771). **The only
  missing piece is telling the hub.**
- Stale prose to fix: the offline row's comment (Ui.lua:925-930) and the 0.7.0
  CHANGELOG/README/mod.card text explain the row is offline-only *because the hub is told
  at hello and never again* — this feature deletes that rationale.
- Suite anchors: section 14 currently pins the CHARACTER row's **absence** while
  connected/hosting (tests/rby_mmo_test.lua:4539-4554). Mirrored hub-test convention with
  identical assertion strings: e.g. rank settlement (rby_mmo_test.lua:2075-2096 ↔
  server/rank.test.js:718-738). Protocol-mismatch templates: rby_mmo_test.lua:1595-1602 ↔
  hub.test.js:145-150.
- E2e: the natural slot is after host leg 4 ("hold still / interact", mmo_host.lua:501-508)
  and before leg 5 (trade) — connected, avatars settled, not busy. Helper gap: nothing
  reads a REMOTE avatar's rendered sheet; `exports.avatarState()` (Client.lua:1637-1655)
  carries no sprite field. Roster-level wire value is already asserted at
  mmo_host.lua:325-332.

## 3. Approach & key decisions

1. **One additive message type, `Wire.SPRITE = "mmo.sprite"`,** used both directions
   (CHAT-style): client→hub `{ sprite = <id> }`; hub→all (no exception, RANK-style)
   `{ id = <playerId>, sprite = <id> }`. Sanitised with `Wire.spriteId` at every boundary
   (never `Wire.text` — the underscore-stripping trap is documented at Wire.lua:112-118).
   Invalid or unchanged values cost the sender nothing (house rule): ignored, no error.
2. **PROTOCOL 5 → 6** in src/Config.lua and server/lib/relay.js together, with a new
   paragraph in each header naming this bump's reason (fourth instance of the same rule).
   Old-hub compat = refusal at hello, like every prior bump; no degraded mode (§8 A3).
3. **Client outbound**: after a successful `setSpriteChoice` (save + syncLook), if
   `transport:isReady()`, send `Wire.SPRITE`. Named function (house rule), not inline.
4. **Client inbound**: `handlers[Wire.SPRITE]` — `Wire.id` + `Wire.spriteId`, drop if
   either fails; `isSelf` → nothing (own state is already live); else
   `roster:setSprite(id, sprite)` and, if the sprite actually changed and an avatar is
   up, `avatars:refresh(player)`.
5. **`Roster:setSprite(id, sprite)`** — exact `setPoints` shape: in-place field write,
   return the entry. **`Avatars:refresh(player)`** — despawn+respawn only if that id is
   currently spawned, else no-op (a map-mismatched player just spawns normally later via
   `sync`).
6. **Hub handler (both hubs, mirrored)**: only for admitted/ready clients; sanitise; no-op
   when unchanged; store `client.sprite`; re-seed the rank board (`board:seen(name,
   sprite)` — the Lua and node boards both learn the new face for future RANKING answers);
   broadcast to all including the sender. **Gated** against spam (despawn/respawn churn on
   every viewer) following the existing chat/ranks gate pattern in each hub (§8 A2).
7. **UI**: CHARACTER row in the connected branch after RANK, before LEAVE/END GAME,
   pushing CHARPICK with `backTo = SCREEN.MAIN` — the same door the offline row uses.
   Rescope the offline row's comment (its "and never again" rationale is now false —
   the offline row remains for the not-in-a-game state, the connected row is the new
   counterpart). No new gate on busy states (§8 A1).
8. **Docs**: extend the unreleased 0.7.0 CHANGELOG entry, README, and mod.card — the
   offline-only caveats become "change it any time, everyone sees it"; note the protocol
   bump (older hub/client pairs refuse at hello, naming both versions).
9. **exports.avatarState** gains the spawned avatar's sprite id, so the e2e can assert a
   peer's *rendered* avatar switched, not just the roster value.

## 4. Work breakdown — implementation (Wave 1, runner: claude/opus)

- **A — wire + client.** Owns **src/Wire.lua, src/Config.lua, src/Client.lua**.
  Wire.SPRITE constant + any inbound accessor needed; PROTOCOL 6 + header paragraph;
  outbound named push after setSpriteChoice when ready; inbound handler per §3.4;
  avatarState sprite field. Acceptance: choosing while connected sends exactly one
  sanitised message; inbound self is a no-op; inbound other updates roster in place and
  refreshes the avatar via the C-owned seams (`roster:setSprite`, `avatars:refresh` —
  call them; C guarantees they exist).
- **B — both hubs.** Owns **src/Hub.lua, server/lib/relay.js**. Handler per §3.6 in both,
  mirrored shape and comments; PROTOCOL 6 in relay.js (Config.lua is A's file — Lua hub
  reads Config.PROTOCOL already); gate constants following each hub's existing gate
  precedent; board re-seed on both sides.
- **C — roster/avatars/UI.** Owns **src/Roster.lua, src/Avatars.lua, src/Ui.lua**.
  `Roster:setSprite` (setPoints shape); `Avatars:refresh(player)` (spawned-only
  despawn+respawn, reuse resync internals); CHARACTER row in the connected branch (not in
  the hosting-not-connected edge state) + offline-comment rescope.
- **D — release metadata.** Owns **CHANGELOG.md, README.md, mod.card**. Extend the 0.7.0
  entry (unreleased — same release, no version bump; §8 A5); update the offline-only
  claims; document the protocol consequence for players.

File-disjoint across A/B/C/D → one wave.

## 5. Work breakdown — test tasks (runner: claude/sonnet)

- **T-A — Lua suite.** Owns **tests/rby_mmo_test.lua**. Flip the absence pins
  (4539-4554) into: connected row list contains CHARACTER after RANK (8 rows), hosting 9
  rows, hosting-not-connected still 2; CHARPICK backTo unchanged. Client: outbound sent
  only when ready; inbound self/other fork; unchanged-sprite no-refresh. Roster:
  setSprite mutates in place (pin object identity — an open Card must see it). Avatars:
  refresh respawns only when spawned. Hub (Lua side): stores, broadcasts with no
  exception (sender hears it), sanitiser rejects bad ids, gate holds, board re-seeded,
  protocol-mismatch template still green with PROTOCOL 6. Use the mirrored assertion
  strings agreed with T-B.
- **T-B — node suite.** Owns **server/*.test.js** (extend hub.test.js or add
  sprite.test.js per local convention). Mirror T-A's hub cases with identical assertion
  strings (store, no-exception broadcast, sanitise, gate, board re-seed).
- **T-C — e2e drivers.** Owns **tests/drivers/***. New leg between host legs 4 and 5:
  one side changes character mid-session through the real menu (CHARACTER row via
  H.selectLabel — the matcher already strips the picker indent); the changer asserts its
  own worn look switched; the peer asserts the roster sprite updated AND
  `exports.avatarState` shows the avatar re-rendered with the new sprite. Also assert the
  hosting menu at 9 rows still reaches END GAME (scroll works). Screenshot the connected
  menu into SHOT_DIR for visual check (no committed doc-shot change planned).

E2e applies (multi-process, user-visible). Run recipe: unchanged from
docs/plans/new-char-selection.md §5 — private engine view, PATH, .env, background run
from the orchestrating session (never inside a subagent), poll for `^  RESULT:`; both
drivers (Client/Wire/hubs all touched).

## 6. Execution waves

1. Wave 1: A ∥ B ∥ C ∥ D → sanity + checkpoint commit.
2. Phase 5: review (opus) on the wave diff.
3. Fix wave if needed → Phase 6: T-A ∥ T-B ∥ T-C.
4. Phase 7 (orchestrator-run): Lua suite, modkit validate/lint/pack, node suites, both
   e2e drivers. Phase 8 loop, cap 3.

## 7. Blast radius & risks

- PROTOCOL 6 refuses hello against 0.6.x-era hubs/clients — intended, precedented; must
  be in the CHANGELOG.
- In-place roster mutation is the contract (open Card by-reference); a `put()`-based
  implementation would pass naive tests and break live cards — T-A pins identity.
- Avatar churn: despawn/respawn per change on every viewer — bounded by the hub gate.
- MOVE echoes `client.sprite` via presenceOf: after the hub stores the new value, every
  subsequent MOVE broadcast self-heals late joiners/missed messages — no extra work, but
  T-A should not accidentally pin the old single-shot behavior.
- Leaderboard open-screen staleness unchanged (matches points behavior).
- `affects_link` stays false; nothing touches link registries.

## 8. Open questions / assumptions (autonomous mode)

- **A1** No mod-layer busy-gate on changing character (mid-trade/battle): the engine's
  modal screen stack already keeps the START menu unreachable during link sessions, the
  change is cosmetic-only, and no other menu row gates on `sessions:isBusy()` either.
- **A2** Hub-side rate gate on sprite changes, mirroring each hub's existing gate
  pattern (chat/ranks) — prevents respawn-churn spam. Exact window: follow the chat
  gate's constants.
- **A3** Old-hub compatibility is hello refusal (PROTOCOL 6), matching all three prior
  bumps. No degraded "connect but no live sprite" mode.
- **A4** An open leaderboard shows the old portrait until the next RANKS request — same
  staleness points already have; acceptable.
- **A5** Same unreleased 0.7.0 release: extend the CHANGELOG entry rather than bump
  again. (A peer branch also claims 0.7.0 — merge-order rebump noted in the previous
  plan's report.)
- **A6** Row placement after RANK; hosting menu scrolls at 9 rows (first time) —
  verified visually in the e2e rather than redesigning the menu.
