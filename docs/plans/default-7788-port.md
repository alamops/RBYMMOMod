> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — JOIN address defaults to port 7788

| Field | Value |
| --- | --- |
| Date | 2026-08-06 |
| Source | `/implement make sure that if no port is added to the JOIN host, it defaults to the 7788 please` |
| Config | none — small single-file change, run inline rather than fanned out |
| Branch | `feature/default-7788-port` |
| Base SHA | b737dfd |

## 1. Objective & success criteria

A JOIN address that carries no usable port is dialled on `Config.DEFAULT_PORT`
(7788) rather than on the engine's own fallback, 7778 — the *pokeserver relay's*
port, where no hub of this mod is ever listening.

Done when: every JOIN address that reaches `Transport:connect` ends in a port
this mod chose, and the mod's suite pins that for a bare host, a bare IP, and
each way a player can type a colon without typing a port behind it.

## 2. Context & constraints

- `src/Client.lua:172` `withPort` already fills in `Config.DEFAULT_PORT` for an
  address with no colon at all, and is applied on both the read
  (`joinAddress`) and the write (`setJoinAddress`) — so the happy path,
  `mybox` → `mybox:7788`, works today and is not what this task is about.
- `src/Config.lua:56` `DEFAULT_PORT = portFromEnv(7788)`; `RBY_MMO_PORT`
  overrides it so two e2e runs can host on one machine. The literal 7788 stays
  the fallback; tests assert against the symbol, not the number.
- Engine `src/link/Net.lua:170` parses `^(.-):(%d+)$` and falls back to **7778**.
  That fallback is the failure this guard exists to prevent.
- The only path to the socket is `Ui` JOINADDR → `Client.setJoinAddress` →
  `Client.joinAddress` → `Transport:connect`. Both ends of that already run
  through `withPort`, so no new call site is needed.
- `Client.codeKey` (`src/Client.lua:201`) lowercases the address and strips
  whitespace before filing the passcode under it. `withPort` does not strip
  whitespace, so a typed trailing space produces a code filed under one string
  and a dial to another.
- The naming grid carries a space glyph and a colon, so both reach the string
  the player submits (`src/Ui.lua:1237`).

Measured (probe over the current `withPort`, luajit):

| typed | stored today | what Net dials today |
| --- | --- | --- |
| `mybox` | `mybox:7788` | `mybox` : 7788 ✅ |
| `mybox:7788` | `mybox:7788` | `mybox` : 7788 ✅ |
| `mybox:` | `mybox::7788` | host `mybox:` ❌ |
| `mybox ` | `mybox :7788` | host `mybox ` ❌ |
| `mybox:abc` | `mybox:abc:7788` | host `mybox:abc` ❌ |
| `mybox:99999` | `mybox:99999` | port 99999 ❌ |
| `:7788` | `:7788` | empty host ❌ |

## 3. Approach & key decisions

Widen `withPort` from "has a trailing `:<digits>`?" to "does the port slot hold
a port the engine can dial?", and trim first.

- **Trim surrounding whitespace before anything else.** Makes the dialled
  string and the `codeKey` it is filed under the same string, which they are
  not today.
- **The port slot is what follows the *last* colon.** If it is not a number in
  1–65535 — empty, non-numeric, or out of range — no port was given, so
  `DEFAULT_PORT` fills it in. One rule for every way of failing to type a port
  beats three, and none of them can be dialled as typed.
  *Judgment call:* `mybox:99999` is therefore dialled as `mybox:7788` rather
  than echoed back in a connect error naming 99999. Reaching a working hub is
  worth more here than preserving a typo the player cannot act on.
- **An address with no host (`:7788`, `:`) is refused**, returning `nil` — the
  same answer `""` already gets, and the screen already handles it by leaving
  the player on the grid.
  *Judgment call:* today it is stored and dialled with an empty host, which
  can only fail.
- **A valid explicit port is never touched**, including `::1`, which keeps
  today's behaviour exactly.

## 4. Work breakdown — implementation

- **T1** — `src/Client.lua`: rewrite `withPort` per §3, extend its comment to
  say why the port slot is re-checked rather than merely detected.

## 5. Work breakdown — tests

- **T2** — `tests/rby_mmo_test.lua`: extend the settings block (~line 3545)
  with the table in §2 as assertions, against `Config.DEFAULT_PORT` rather
  than the literal, plus an option row typed without a port reading back with
  one.

E2e: **not applicable as a new flow.** No screen, message type or hook changes;
the existing `tests/drivers/mmo_join.lua` already drives a real JOIN through
this function, so running the driver is regression cover, not new coverage.

## 6. Execution waves

One wave: T1 then T2 (same session, sequential — the suite asserts T1).

## 7. Blast radius & risks

- `Client.joinAddress` / `setJoinAddress` — the only callers of `withPort`.
- `Client.codeKey` and the rank-token key are keyed off the stored address;
  trimming makes those keys *more* stable, and no already-stored address
  changes shape unless it held whitespace, which could not be dialled anyway.
- A peer is building `feature/last-connected-servers`, which stores hub
  addresses and elides `Config.DEFAULT_PORT` when naming a row. Canonical
  stored addresses strengthen that assumption; both touch `src/Client.lua`, so
  the merge is worth a heads-up.
- No wire, registry or link-fingerprint surface is touched; `affects_link`
  stays `false`.

## 8. Open questions / assumptions

- Assumed the two judgment calls in §3 (out-of-range port → default;
  host-less address → refused) rather than blocking on them; both are stated
  above and are one line each to reverse.
