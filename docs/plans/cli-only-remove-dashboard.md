# Plan — CLI-only: remove the web dashboard

| Field | Value |
| --- | --- |
| Date | 2026-08-06 |
| Source | conversation — "let's get rid of the web dashboard, let's make it fully CLI only" (after weighing 80/443, Express/TS, Postgres — all declined) |
| Config | AGENTS_CONFIG.yml (quality) |
| Branch | feature/enhance-server-features |
| Base SHA | 1504c39 |
| Mode | Owner decided scope in-conversation; detail decisions logged in §8. |

## 1. Objective

Remove the web dashboard entirely. The operator surface is the CLI (over
SSH when remote): watch, players, ranking, history, kick, broadcast,
invite, doctor, config. **Admin join codes stay** — they mark connections
for the future in-game operator features and remain visible on operator
surfaces (roster/status.json/who); they simply lose their web consumer.

Done = no dashboard code, config, tests, or doc claims anywhere; all
suites + modkit + both e2e drivers green.

## 2. Scope map (from this session's own build — no investigation needed)

Remove:
- `server/lib/dashboard.js` — the whole module.
- server.js: require + start/close wiring, `handle.dashboard`,
  `rankingRows` projection (dashboard-only), the reload() dashboard-changed
  warning, related comments.
- config.js: `dashboard` DEFAULTS section, `dashboard.port` BOUNDS,
  boolean/host validation calls for it (keep the `validateHost` helper —
  listen.host uses it), comments. validate()'s unknown-key pruning silently
  cleans any config.json that carried a dashboard section — desired.
- cli.js: every dashboard mention — the invite `--admin` printed block
  ("opens two more things"), invite list footers ("the only kind the web
  dashboard admits"), HELP text. The `--admin` copy is REWRITTEN, not
  deleted: an admin code joins the game like any code, is marked on the
  connection for operator features that arrive in game later, and shows as
  ADMIN on operator views.
- compose.yml: the commented 7790 mapping block and its prose.
- Tests: all dashboard scenarios in server.test.js (dashboardTest,
  Disabled/NoCredential/SessionFollowsCredential/PlayerCodeRefused/
  OnlyPlayerCredentials, DASHBOARD_PORT* constants, httpRequest helper if
  dashboard-only); cli.test.js dashboard leaves in testValueFor + any
  invite-copy pins that referenced the dashboard.
- Docs: server/README.md `## Dashboard` section and every cross-reference
  (security posture paragraph, config rows, reload-table row, Docker/
  volume mentions, admin-codes section); root README rows/blurbs;
  mod.card entries. Remote-operation guidance becomes one line: SSH to the
  box and use the CLI.

Stays untouched: admin flag end-to-end (auth.js isAdminCredential,
config validateCredentials, relay client.admin/welcome/roster, client
isAdmin export, invite --admin/KIND), admin.sock, status.json, history,
MOTD, watch. Lua suite and e2e drivers have no dashboard surface.

## 3. Key decisions

1. **CHANGELOG: rewrite the unreleased 0.8.0/0.9.0 entries** as if the
   dashboard never existed (branch is unpushed, no tags, no release —
   the CHANGELOG describes releases, and none carrying a dashboard ever
   happened; git history keeps the truth). Version stays **0.9.0**.
   0.9.0's story becomes: admin codes mark connections for coming
   operator features. 0.8.0 loses its dashboard section.
2. `limits`' auth throttle keeps working unchanged (the dashboard was one
   consumer of noteAuthFailure; the game port remains).
3. docs/plans/* history files are left as-is (ignored from the archive);
   this plan is added to .modkitignore.

## 4. Waves

- **Wave 1** (file-disjoint, opus ×3):
  - **R1 — code removal** · owns `server/lib/dashboard.js` (delete),
    `server/lib/server.js`, `server/lib/config.js`.
  - **R2 — CLI copy** · owns `server/lib/cli.js`.
  - **R3 — docs** · owns `server/README.md`, `README.md`, `mod.card`,
    `CHANGELOG.md`, `server/compose.yml`, `.modkitignore` (add this plan).
- **Wave 2** (sonnet ×1): **R4 — tests** · owns `server/server.test.js`,
  `server/cli.test.js` — remove dashboard scenarios, realign any pins to
  R2's new copy, keep every non-dashboard admin-code test.
- Review (opus) → fixes if needed → full battery (haiku, foreground
  drivers).

## 5. Risks

- A leftover doc/copy claim that the dashboard exists (grep sweep in
  review: "dashboard", "7790", "rbyd").
- server.js close()/startExtras ordering must stay correct with only the
  admin socket as an extra.
- cli.test.js LEAF_PATHS sweep auto-shrinks with the config leaves —
  the explicit testValueFor dashboard entries must go or the sweep errors.
- manifest/package versions stay 0.9.0 — config.test.js parity unaffected.

## 6. Assumptions (logged)

1. Unreleased-entry rewrite over a "removed" entry (§3.1).
2. Admin codes keep their name/flag/KIND surface — not rolled back.
3. Remote operation story = SSH + CLI; no replacement web surface.
