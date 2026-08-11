> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — The admin join code: one credential for the dashboard and the game

| Field | Value |
| --- | --- |
| Date | 2026-08-06 |
| Source | conversation — "generate a specific admin-only join code; unlocks the web dashboard and, later, special in-game features (not built now, but open the possibility)" |
| Config | AGENTS_CONFIG.yml (quality) |
| Branch | feature/enhance-server-features |
| Base SHA | aadf696 (set at Phase 4 start) |
| Mode | Autonomous (owner set direction in-conversation; detail decisions logged in §8) |

## 1. Objective & success criteria

A credential can be minted as **admin**. That one join code:
1. is the only kind the **web dashboard** accepts (dashboard becomes
   admin-only);
2. still joins the game normally, and the hub marks that connection as
   admin — surfaced to the client itself on welcome and to operator views —
   so future in-game admin features have a flag to check (none built now).

Done = suites + modkit + both e2e drivers green, docs shipped, version
0.9.0, no protocol bump.

## 2. Context (verified anchors)

- `auth.verify(nonce, response, credentials)` → `{ ok, credentialId }`
  (`auth.js:213-251`); `relay.js:228` stores `client.credentialId`;
  `server.js:304-322` wraps verify and already finds the matched credential
  object by id (to charge uses). Identity plumbing exists end to end.
- `auth.newCredential(options)` (`auth.js:259`) mints credentials;
  `config.js:473 validateCredentials` normalizes the stored list;
  `auth.activeCredentials` filters live ones; the dashboard verifies against
  that set and refuses to start when it is empty (`dashboard.js:529`).
- Welcome already carries optional hub→client fields (`rankToken`, `motd`)
  with no bump — the same rule applies to an `admin` flag.
- `invite` / `invite list [--reveal]` / `revoke` are the credential verbs.

## 3. Approach & key decisions

1. **The flag lives on the credential**: `admin: true` on an
   `auth.credentials[]` entry, minted by `rby-mmo-hub invite --admin`,
   revoked/listed like any other. Absent means false; old configs need no
   migration.
2. **Dashboard accepts only admin credentials.** The start-time refusal
   becomes "no active **admin** credential" and its remediation names
   `invite --admin`. Anyone holding a player code loses dashboard access —
   a deliberate behavior change from 0.8.0, called out in the CHANGELOG.
3. **The game connection is marked**: server.js's verify wrapper returns
   `admin: Boolean(credential.admin)` alongside `credentialId`; relay sets
   `client.admin` at hello. Surfaced:
   - to the **client itself**: `admin: true` on `mmo.welcome` (only when
     true — the motd idiom; hub→client, **no protocol bump**);
   - to **operator views**: an `admin` boolean in `relay.roster()` (and so
     `status.json` / `who` / the dashboard players table, which may render
     it or not — carrying it is enough);
   - **never in `presenceOf`** — other players don't learn who holds power.
4. **Client**: store the flag, export `isAdmin` (mirrors `isRanked`), no UI.
   That is the whole "open the possibility" surface for future features.
5. **Unauthenticated hubs** (`auth.required: false`, legacy hub.js): nobody
   is admin — the flag rides the credential, no credential means no admin.
   Dashboard already effectively requires auth, unchanged.
6. Version → **0.9.0** (both manifests). Admin codes are ordinary 6-char
   codes (the in-game entry widget fixes the length); the README's existing
   sniffing caveat gets a sentence: an admin code raises what a sniffed
   handshake is worth — prefer `--expires`, rotate freely.

## 4. Work breakdown — implementation

**Wave 1 (file-disjoint):**
- **A — credential model** · `server/lib/auth.js`, `server/lib/config.js`.
  `newCredential({ admin })` stores `admin: true` only when truthy;
  `validateCredentials` preserves/normalizes the flag (absent → absent,
  truthy → true); redaction untouched (the flag is not a secret). Export
  nothing new unless a helper reads cleaner.
- **B — hub marking** · `server/lib/relay.js`, `server/lib/server.js`.
  server.js verify wrapper adds `admin` to its verdict (from the credential
  it already looks up); relay: `client.admin = Boolean(verdict.admin)` at
  the same site credentialId is stored, `admin: client.admin || undefined`
  on welcome, `admin: Boolean(client.admin)` in `roster()`, and NOT in
  `presenceOf` (comment why). status.json inherits via roster().
- **C — doors and verbs** · `server/lib/dashboard.js`, `server/lib/cli.js`.
  Dashboard: filter to admin credentials in both the start-time check and
  `codeAccepted` (one shared predicate); refusal copy names
  `invite --admin`. CLI: `invite --admin` flag (help + verb), `invite list`
  marks admin rows (plain ADMIN column/tag, shown with and without
  `--reveal`), and the dashboard section of `HELP` updated if it mentions
  join codes.

**Wave 2 (file-disjoint):**
- **D — client flag** · `src/Client.lua`. Read `msg.admin == true` in the
  welcome handler, keep it in state, clear on disconnect (mirror how
  `myPoints`/`ranked` are handled), export `isAdmin`.
- **E — docs & version** · `manifest.json`, `server/package.json`,
  `CHANGELOG.md`, `README.md`, `mod.card`, `server/README.md`,
  `.modkitignore` (add THIS plan file: docs/plans/admin-join-code.md).
  0.9.0; CHANGELOG: the admin code, the dashboard now admin-only (breaking
  vs 0.8.0's any-code login), the welcome flag with the no-bump argument,
  the future-features framing; server/README: invite --admin, dashboard
  section rewritten to admin codes, protocol table gains the welcome
  `admin` field, security caveat sentence.

## 5. Tests

- **T1** · `server/auth.test.js`, `server/rank.test.js`: newCredential
  admin flag shape + validate round-trip (auth.test); relay-level: admin
  verdict → client.admin, welcome carries `admin` only for admins (JSON
  round-trip idiom), roster() carries it, presence does NOT (rank.test).
- **T2** · `server/server.test.js`, `server/cli.test.js`: end-to-end over
  sockets — hello with an admin code → welcome admin flag; dashboard
  rejects a player code, accepts an admin code; start-refusal with only
  player codes (handle.dashboard null + remediation logged); status.json
  rows carry admin (server.test). invite --admin mints and lists with the
  marker; help text (cli.test).
- **T3** · `tests/rby_mmo_test.lua`: exports list gains isAdmin; the
  welcome-field sanitisation seam (admin true/absent) at whatever tier the
  suite reaches (same seams T4 used for motd).
- e2e: both drivers as regression (admin flow not driver-asserted).

## 6. Waves

A+B+C (opus ×3) → D+E (opus ×2) → review (opus) → T1+T2+T3 (sonnet ×3) →
full battery (haiku, foreground drivers) → fixes ≤3 rounds.

## 7. Risks

- Dashboard behavior change (player codes stop working) — CHANGELOG + README.
- The welcome `admin` flag must never be trusted hub-side from anything a
  client sends — it is derived from the credential only, set server-side.
- `admin` must stay out of presence (player-visible) — review checks.
- validateCredentials must not strip the flag on config round-trip (the
  save path rewrites credentials) — T1 pins it.

## 8. Assumptions (logged)

1. One flag, not roles — `admin: true`, nothing finer-grained yet.
2. Admin codes are normal 6-char codes; length unchanged (in-game entry
   widget constraint); risk documented instead.
3. `invite list` marks admin rows; no dedicated `admin` verb family needed.
4. roster()/status.json carry the flag (operator surfaces); presence never.
5. Dashboard login still does not charge a credential's use budget.
6. SQLite direction dropped per conversation; credentials stay in
   config.json.
