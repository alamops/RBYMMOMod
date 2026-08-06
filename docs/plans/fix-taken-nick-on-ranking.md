# Plan — Fix spurious "THAT NAME IS TAKEN" on the RANK screen

| Field | Value |
| --- | --- |
| Date | 2026-08-04 |
| Source | /implement — bug report + screenshot (RANK screen showing the taken-name message for the player's own name) |
| Config | AGENTS_CONFIG.yml (quality preset) |
| Branch | fix/taken-nick-bug-on-ranking |
| Base SHA | d85cca7a3825ad0c47324579b2b92b0d0024ab19 (tree clean at start; only this plan file untracked) |
| Mode | **Autonomous** — the grill (Phase 2) and plan-approval (Phase 3) gates were bypassed because no owner was reachable mid-task. Every decision an owner would normally make is recorded in §8. |

## 1. Objective & success criteria

A player who rightfully owns a name on a hub must never be branded an impostor by
ordinary play. Concretely, after this fix:

- Quit-to-title + CONTINUE (or a full relaunch) **without an intervening in-game save**,
  then reconnecting to the same hub, keeps the player ranked under their name.
- A first-connection welcome that never reaches the client (crash, dropped socket)
  does not permanently lock the name.
- A hub restart before the player's first scored battle does not orphan the claim.
- A name that has **scored** (settled ranked battles) remains protected exactly as
  today: wrong/missing token → impostor, no reclaim. Anti-cheat posture unchanged.
- All existing suites stay green; the twin claim implementations stay pinned by the
  same cases in both suites.

## 2. Context & constraints (grounded findings)

**The message** renders when the last `mmo.welcome` carried `ranked=false`
(`src/Ui.lua:430-438`, footer echo `src/Ui.lua:476-477`; flag set at
`src/Client.lua:838`, exposed via `M.isRanked()` `src/Client.lua:453-455`).

**Root cause (client):** the claim token granted in `mmo.welcome` is stored only in
the in-memory `mod.save` table (`src/Client.lua:833-834` → `M.setRankToken`
`src/Client.lua:234-241`, key from `tokenKey` `src/Client.lua:220-225`). The engine's
`mod.save` facade is fire-and-forget RAM (`gen1recomp src/mods/Loader.lua:567-580`);
it reaches disk only via a full `Game:writeSave()` (START→SAVE, PC box, Hall-of-Fame
script, link-trade autosave — none triggered by MMO connect/disconnect), and
CONTINUE/`restoreSave` replaces the backing table outright
(`gen1recomp src/core/Game.lua:660-681`). So: connect → claim minted → quit without
saving → CONTINUE → token gone → next hello has no token → hub answers `impostor`
(`server/lib/rank.js:171-188`) → permanent lockout under the player's own name.
The e2e rejoin test covers only same-session LEAVE+rejoin — the safe path.

**Aggravators (hub):**
- The claim is committed to the in-memory board *before* the welcome is confirmed
  delivered (`server/lib/relay.js:558-590`); a lost welcome self-locks the name.
- Claims persist to `ranking.json` only when a battle settles
  (`server/lib/server.js:432-458`, `561-592`; trigger only in `settleMatch`
  `relay.js:906-926`) — a hub restart before first score silently reopens the name
  and whoever reconnects first wins it.
- No dedupe of concurrent hellos for one unclaimed name (self-collision race).
- `Board.claim`'s open branch never inspects the presented token
  (`rank.js:185-187` / `src/Rank.lua:192-196`).

**Twin drift found:** JS `import()` requires token hashes to be exactly 64 lowercase
hex (`rank.js:359`); Lua accepts any-length hex (`src/Rank.lua:395-396`).

**Engine seam audit (measured, gen1recomp @ dev):** no public `mod.save` flush exists.
Two viable persistence avenues: (a) a mod-registered script command calling
`ctx.game:writeSave()` via `queueScript` — but that silently writes the **whole game
save** (an un-asked-for checkpoint; unacceptable side effect), and needs a live,
script-free overworld; (b) direct `love.filesystem` writes of a mod-owned file — not
part of the `mod.*` facade but unsandboxed by design today, with shipped precedent in
the engine's own bundled mods (`mods/dramatic_shape/lib/Perf.lua:318-327` writes JSON
with no `filesystem` permission declared; `mods/nuzlocke/main.lua:210-212` similar).
The `filesystem` permission is a recognized manifest key (closed set,
`src/mods/Manifest.lua:11`), currently decorative (Mod Manager glyph only).

**Ruled out:** address-normalization drift within one connection (hello read and
welcome write share the `dialled` upvalue); UI race before welcome (flag and
readiness set in the same handler call); stale `rankedHere=false` across connections
(`M.disconnect` resets it, `src/Client.lua:673`); commit #5 (drawing-only fix).

## 3. Approach & key decisions

**D1 — Client: persist tokens in a mod-owned file via `love.filesystem` (rests on the
seam audit).** Write the token to `rby_mmo_rank_tokens.json` in the LÖVE save
directory the moment the welcome grants it, in addition to the existing `mod.save`
write (kept for back-compat with tokens already inside players' saves). Read path:
file entry first, `mod.save` fallback. File entries are keyed by
`"<normalized addr>|<UPPER name>"` — per-name keying because the file, unlike
`mod.save`, is shared by every save slot (and by two instances in the e2e rig if they
share a save dir). All access guarded `love and love.filesystem` + `pcall` (headless
suite runs under plain luajit; tests stub it). Declare `"filesystem"` in
`manifest.json` permissions — functionally decorative today, but honest, and
future-proof against an enforcement pass.
*Rejected:* silent full `Game:writeSave()` (side effects on the player's actual save;
players on deliberate no-save runs would get checkpointed without consent);
upstream-RFC-only (correct long-term for a clean `mod.save:flush()`, but leaves the
bug live; noted in §8 as follow-up).

**D2 — Hub (both twins): a claim is provisional until proven.** Add a `confirmed`
flag to board entries. It becomes true when (a) a later hello presents the token
successfully (verdict `owner`), or (b) a ranked battle settles for that name.
`Board.claim` gains one rule: hello with missing/wrong token for a name whose claim
is **unconfirmed and unscored** (no settled wins/losses) → re-mint and transfer the
claim (verdict `claimed`, fresh token in welcome) instead of `impostor`. This closes
the lost-welcome lockout, the hub-restart orphan, the self-collision race, and the
client-side token loss for names that haven't scored yet. Names with settled battles
keep today's hard protection.
*Anti-cheat check:* an unscored, unconfirmed name holds nothing of value; the reclaim
rule means the *currently connected* player holds it, and a rightful owner who lost
the race just reconnects and re-mints. Stealing a **scored** name still requires the
original token. Strictly better for owners, no new theft surface for anything worth
stealing.

**D3 — Hub: persist claims when they change, not only when battles settle.** Mint,
reclaim, and confirm all trigger the existing debounced `ranking.json` flush
(`noteRankChange` path). Closes the restart-orphan window. Export/import carry
`confirmed` additively; on import, an entry with settled battles but no `confirmed`
field (legacy file) is treated as confirmed; an unscored entry without it stays
provisional (which is exactly the leniency we want for legacy claims).

**D4 — Fix the twin drift:** Lua `import()` tightens to exactly-64 lowercase hex,
matching JS.

**No wire/protocol change:** no new message types or fields (`rankToken`/`ranked`
already exist on hello/welcome; a reclaim just re-sends `rankToken` in welcome, which
the client already stores — `src/Client.lua:830-834`). PROTOCOL stays 3.
`affects_link` stays `false` (no link registry touched). Version → 0.4.1 with a
CHANGELOG entry.

**UI unchanged:** with false positives gone, the "taken" verdict genuinely means
"someone else confirmed/scored under this name," and the existing message plus the
"NOT RANKED HERE." footer are accurate. (The message being gated on an empty
leaderboard is a visibility gap, noted in §8, not this bug.)

## 4. Work breakdown — implementation tasks

**Wave 1 (parallel, disjoint):**

- **I1 — Board twins + hub wiring (one agent, to keep the twin rule identical).**
  Files owned: `server/lib/rank.js`, `server/lib/relay.js`, `server/lib/server.js`,
  `src/Rank.lua`, `src/Hub.lua`.
  - `rank.js` + `Rank.lua` `Board`: `confirmed` on entries; `claim()` returns
    `owner` → mark confirmed; missing/wrong token + unconfirmed + no settled
    wins/losses → re-mint, replace hash, verdict `claimed`; settle path marks
    confirmed; `export`/`import` carry `confirmed` per D3; Lua import hash
    validation tightened to `^[0-9a-f]{64}$`-equivalent (D4).
  - `relay.js`: claim mutations (mint/reclaim/owner-confirm) fire the rank-change
    persistence callback; welcome still sends `rankToken` whenever verdict is
    `claimed` (now including reclaims).
  - `server.js`: ensure the persistence callback wiring covers claim-time changes.
  - `Hub.lua` (Lua-hosted twin): same verdict handling; board is session-scoped so
    no persistence, but reclaim + confirm must behave identically in-session.
  - Acceptance: same rule expressed identically in both twins; no wire vocabulary
    changes; no bare `error()`/`assert()` in mod callbacks; failure paths use
    `mod.log` with remediation.

- **I2 — Client token durability.**
  Files owned: `src/Client.lua`, `src/Config.lua`.
  - Token store module logic inside `Client.lua` (or minimal helper kept in the same
    file): load/save `rby_mmo_rank_tokens.json` via guarded `love.filesystem`
    (`pcall`, decode failures → warn + treat as empty, then overwrite on next write);
    filename constant in `Config.lua`.
  - Key: `"<tokenKey addr form>|<UPPER trainer name>"`; write on welcome grant
    (alongside existing `mod.save` write); read at hello: file first, `mod.save`
    fallback. Name read from the same source hello uses for the player name.
  - Acceptance: headless-safe (no `love` global → behaves as before, `mod.save`
    only); a granted token survives a simulated save-reload (mod.save wiped) when
    the stubbed file store is present.

**Wave 2 (orchestrator, inline):** `manifest.json` (version 0.4.1, add
`"filesystem"` permission), `CHANGELOG.md` (0.4.1 entry — heading must match
manifest), `mod.card` compat note if applicable.

## 5. Work breakdown — test tasks

**Wave T (parallel, disjoint):**

- **T1 — Node suites.** Files owned: `server/rank.test.js`.
  Cases (pinning the shared rule): fresh claim unconfirmed; owner return confirms;
  unconfirmed+unscored + tokenless hello → reclaimed with fresh token, old token now
  impostor; confirmed-but-unscored name → NOT reclaimable (owner returned once);
  scored name → never reclaimed regardless; settle marks confirmed; export/import
  round-trips `confirmed`; legacy import (no `confirmed`): scored → confirmed,
  unscored → provisional; claim-time persistence trigger fires (mint/reclaim/confirm
  each cause a flush request); over-the-wire variant of the reclaim scenario.
- **T2 — Lua suite.** Files owned: `tests/rby_mmo_test.lua` (+ `tests/` helpers if
  the suite splits files).
  Same board cases mirrored against `src/Rank.lua` (twin-pinning); import rejects
  non-64-length hashes; client-side: welcome grant writes the token file (stubbed
  `love.filesystem`); hello prefers file token after `mod.save` wipe (simulated
  CONTINUE); headless no-`love` path unchanged; Lua-hosted hub reclaim behaves as
  the node hub does.

**E2E:** applies — the bug is a cross-process flow. Run recipe (from memory,
verified last session): private engine view over the worktree (never repoint the
shared symlink), `export PATH="/opt/homebrew/bin:$PATH"`, copy `.env` from
`~/Projects/alamops/RBYMMOMod/.env`, `SHOT_DIR` moved to scratchpad, kill stale
listeners on 7799. Run the existing `run-mmo-e2e.sh` (covers LEAVE+rejoin ranked
assertion) as regression. Extending the driver to a full quit+CONTINUE cycle is out
of scope for this fix (driver has no reload helper today; the CONTINUE semantics are
pinned headlessly in T2 by simulating the `mod.save` wipe) — recorded in §8.

## 6. Execution waves

1. Wave 1: I1 ∥ I2 (disjoint files) → checkpoint commit.
2. Wave 2: metadata (orchestrator) → commit.
3. Phase 5 review (opus) on `git diff <base>...HEAD` → triage.
4. Wave T: T1 ∥ T2 → commit.
5. Phase 7: full verification (haiku agent): node suites, Lua suite + T4 via private
   view, `modkit validate --base imported` / `lint` / `pack`, then the mmo e2e
   driver. Fix loop (opus) ≤3 rounds.

## 7. Blast radius & risks

- `Board.claim` verdicts feed `client.ranked`, welcome fields, and match scoring
  (`matches` impostor checks) — reclaim must not let a mid-session token swap change
  an in-flight match's identity assumptions (review point).
- `ranking.json` schema gains `confirmed` — additive; old hubs reading new files
  ignore it (JS import copies known fields only — verify), new hubs reading old
  files use the legacy rule in D3.
- Client file store is shared across save slots by design; keying includes the
  trainer name to prevent cross-slot collisions. Two instances sharing one LÖVE save
  dir (e2e rig) write the same file — last-writer-wins per key is acceptable
  (distinct names → distinct keys).
- `affects_link` stays false; no link registries touched; fingerprint unmoved.
- Rollback: revert the branch; `ranking.json` written by the new hub remains
  readable by the old hub (unknown field tolerated — verify in review).

## 8. Open questions / assumptions (owner-facing, decided autonomously)

1. **Assumed the field report matches the CONTINUE-without-save scenario** (most
   probable confirmed path). The fix also covers lost-welcome and hub-restart
   variants, so the repair holds even if the exact trigger differed.
2. **Decided:** unscored+unconfirmed names are reclaimable (D2). Tradeoff accepted:
   an attacker can squat an unscored name's claim, but gains nothing and loses it
   back the same way; rightful owners stop being locked out. Reversible by policy
   change on the hub alone.
3. **Decided:** direct `love.filesystem` persistence with the `filesystem` manifest
   permission declared, over a silent full-game save. A clean `mod.save:flush()`
   upstream RFC (Lane B) is the long-term fix — follow-up, not blocking.
4. **Deferred:** the "taken" message is only visible when the leaderboard is empty
   (visibility gap, `src/Ui.lua:430`); a hub with scores shows only the footer.
   Cosmetic, separate change if wanted.
5. **Deferred:** e2e driver extension for a real quit+CONTINUE cycle; scored-name
   welcome-loss lockout (unrecoverable by design, protects scored names).
6. **Assumed** version 0.4.1 (patch) is the right bump; no protocol change.
