# Plan — You're connected message

| Field | Value |
| --- | --- |
| Date | 2026-08-11 |
| Source | /implement: display "You're connected" once connected to the server |
| Config | AGENTS_CONFIG.yml (quality: Cursor host → scout/builder/reviewer=`cursor-grok-4.5-high`, test_author/runner=`composer-2.5`) |
| Branch | `feature/connected-message` (already checked out; tip of main) |
| Base SHA | `f9934515733c5eea936a517277b613b1205f071a` |
| Mode | Interactive — grill answers locked 2026-08-11 |

## 1. Objective & success criteria

When the hub admits the player (`mmo.welcome` → `transport:markReady()`), show **"You're connected"** once — as a corner toast **and** a chat scrollback `HUB` line — on both join and host paths.

Done means:
- Exact copy `"You're connected"` on both surfaces (no player count / server name).
- Announced only on the **first** successful welcome of an intentional connection session; a drop that tears down via `M.disconnect()` then a manual rejoin does **not** announce again.
- An intentional leave (`M.leave` / stop hosting) clears the latch so the next join/host announces again.
- No modal (`ui:say`) — that path already failed in production (blocks play).
- Headless suite pins the toast formatter (if added) and the chat push shape; no e2e required.

## 2. Context & constraints

**Connection is ready only after WELCOME.** `Client.isConnected()` = `transport:isReady()`, set inside `handlers[Wire.WELCOME]` at `Client.lua:1508`. TCP open / hello are not enough.

**Success is silent today.** After MOTD (optional `HUB` chat line, `1559–1561`), the handler only `mod.log:info("connected -- …")` (`1569`). Comment at `1550–1568` already describes a “connection’s own status line” under the MOTD and explicitly forbids `ui:say` for routine connect status.

**Toast layer already ships** (`src/Toast.lua`, 0.10.0): `toast:push(text)`, 5s TTL, max 5, drawn from `render.hud`. JOIN/PART toast others only; self-connect was never added. `toast:clear()` runs in `M.disconnect()` (`1215`).

**Drop always full-tears-down.** Lost transport → `M.disconnect()` + optional `ui:say(reason)` (`1877–1895`). There is no silent re-welcome without a new dial; “don’t re-announce after drop + re-welcome” therefore requires a latch that **survives** `disconnect()` and is cleared only on intentional leave.

**Host and guest share WELCOME.** Hosting’s loopback still delivers `mmo.welcome`; one hook covers both (grill: same message).

**Tests.** Suite avoids driving the live WELCOME handler end-to-end (needs full `install()` facade). Convention: pin Chat/`Toast` seams and shapes the handler will call (`tests/rby_mmo_test.lua` ~981–999 MOTD; ~1073+ `Toast.joinLine`). Fake-net Client path exists (~14080+) if a thin end-to-end through Client is cheap; prefer seam pins first.

## 3. Approach & key decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Surfaces | Toast **and** chat `HUB` line | Owner |
| Copy | Exact `"You're connected"` | Owner |
| Hook | `handlers[Wire.WELCOME]`, after MOTD push, before/beside `mod.log:info` | Single ready-gate; matches existing comment |
| Host vs join | Same | Shared WELCOME |
| Re-announce | Latch `connectedAnnounced`; skip if set | Owner: first only |
| Latch clear | Intentional leave only (`M.leave` / `stopHosting` path that ends the session for the player) — **not** `M.disconnect()` | Drop uses `disconnect()`; leave must reset so a later join announces |
| Modal | Never | Historical failure |
| Formatter | Small `Toast.connectedLine()` returning the constant (or nil-safe no-op) | Matches `joinLine`/`partLine` testability |
| Chat shape | `{ name = "HUB", scope = "global", text = "You're connected" }` | Same as MOTD; hub is not a player (`from` omitted) |
| Protocol / version | No PROTOCOL bump; patch-level CHANGELOG note only if repo convention requires for user-facing UX — prefer a short CHANGELOG entry under Unreleased / next patch | Additive client UX only |
| e2e | Not applicable | Owner; unit/seam coverage enough |

### Latch semantics (assumption locked from grill)

```
WELCOME:
  if not connectedAnnounced then
    toast:push(Toast.connectedLine())   -- "You're connected"
    chat:push({ name = "HUB", scope = "global", text = "You're connected" })
    connectedAnnounced = true
  end
  -- MOTD still always pushed when present (unchanged), before this block

disconnect() [drop OR leave teardown]:
  does NOT clear connectedAnnounced

leave() / stopHosting() [intentional]:
  clear connectedAnnounced (before or after disconnect teardown)
```

So: first welcome after an intentional join/host → announce; drop → disconnect → rejoin → silent; leave → join again → announce.

## 4. Work breakdown — implementation tasks

### T1 — Toast formatter + Client WELCOME/leave latch
- **Owns:** `src/Toast.lua` (`connectedLine`), `src/Client.lua` (module latch; WELCOME announce after MOTD; clear latch on intentional leave/stopHosting; do **not** clear in `disconnect`)
- **Does not own:** tests, CHANGELOG (T2 / docs task)
- Acceptance:
  - `Toast.connectedLine()` → `"You're connected"`
  - First WELCOME (host or guest) pushes toast + HUB chat once
  - Second WELCOME without intentional leave pushes neither
  - After `M.leave()` (or stop-host equivalent), next WELCOME announces again
  - MOTD order unchanged (MOTD above the status line in scrollback)
  - No `ui:say` on this path

## 5. Work breakdown — test tasks

### TT1 — Seam pins for connected message
- **Owns:** `tests/rby_mmo_test.lua` (additions near MOTD chat shape ~981 and Toast formatters ~1073)
- Covers T1
- Acceptance:
  - `Toast.connectedLine()` exact string (+ nil/garbage refusal if the helper mirrors siblings)
  - Chat push shape for the status line matches MOTD style (`HUB` / `global` / exact text) at the Chat seam
  - If a cheap Client-level latch test exists without full install scaffolding, pin announce-once + leave-clears; otherwise document reliance on seam + code review of the latch sites
- **e2e:** not applicable (no new user-flow harness; in-game toast/chat already covered by existing toast suite patterns)

## 6. Execution waves

| Wave | Tasks | Barrier |
| --- | --- | --- |
| 1 | T1 | Impl done before tests that assert new API |
| 2 | TT1 | After T1 |

Single-agent waves are fine — file ownership does not fan out.

## 7. Blast radius & risks

- **WELCOME is hot path for every admission** — keep pushes cheap; no modal.
- **Chat unread:** `HUB` lines without `outgoing` may bump unread like MOTD; acceptable (same as MOTD).
- **Toast stack:** join spam + connected toast can coexist; max-5 eviction already handled.
- **Latch wrong clear:** clearing in `disconnect()` would re-announce after every drop — avoid.
- **Latch never clear:** forgetting leave clear would silence every later server join until restart — clear on intentional leave only.
- **Rollback:** revert Client + Toast + test hunks; no wire/protocol change.

## 8. Open questions / assumptions

- **Latch clear on intentional leave only** — inferred from “not after drop + re-welcome” plus shared `disconnect()` on drops. If you’d rather announce at most once per game launch (never again after leave+rejoin), say so before Phase 4.
- CHANGELOG: add a one-line Unreleased / patch note unless you prefer silence for this tiny UX.
- No e2e (confirmed).
