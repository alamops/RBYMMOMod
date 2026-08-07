# Plan — Submit RBY MMO to gen1recomp-mod-index

| Field | Value |
| --- | --- |
| Date | 2026-08-06 |
| Source | /implement — "submit our mod to the gen1recomp mod index as a PR" |
| Config | AGENTS_CONFIG.yml (quality preset) |
| Branch | feature/submit-our-mod-to-mod-index |
| Base SHA | b737dfd |
| Mode | **Autonomous** — grill + plan-approval gates bypassed; assumptions logged in §8 |

## 1. Objective & success criteria

Get `RBY MMO` listed on https://github.com/bryanthaboi/gen1recomp-mod-index:
a PR adding `mods/alamops@rby_mmo/{meta.json,description.md}` that passes the
index's CI (`scripts/validate.mjs`, check-duplicates, check-links, build-index)
and honestly satisfies its PR checklist. Secondary: leave our own repo's next
release clean (no stray test drivers in the zip) via a hygiene PR on this branch.

## 2. Context & constraints (verified)

- Index submission = one folder `mods/<Author>@<id>/` with `meta.json`
  (schema-validated, `additionalProperties: false`), `description.md` (≤64 KB),
  optional single `thumbnail.png|jpg` ≤2 MB. No multi-screenshot support.
- **Index policy: no ROM-derived content in the index repo.** All of our
  `docs/screenshots/*.png` are ROM-composited frames → none may be committed
  as thumbnail. (User asked for the co-op battle shot "if they accept
  screenshots" — they don't, in the committed sense; see §8 A1.)
- Distribution: `github: alamops/RBYMMOMod` + GitHub Releases with asset
  `rby_mmo-<version>.zip`. **Verified live:** 16 releases exist; latest
  v0.7.1 with `rby_mmo-0.7.1.zip`. Version bumps never need index PRs
  (nightly re-read, `automatic_version_check` default true).
- **Verified gates:** `modkit validate --strict` → ok; `modkit lint` → ok
  (run 2026-08-06 from the engine checkout against this worktree; an earlier
  agent-reported MK302 failure did not reproduce and is discarded).
- **Verified zip contents (v0.7.1):** clean except `tests/drivers/mmo_quad.lua`
  and `tests/drivers/run-quad-e2e.sh` — missing from `.modkitignore` since
  PR #15. Also missing (affects local `modkit pack` only, since release.yml
  drops `docs/` wholesale): 7 screenshots — coop-battle, coop-item,
  coop-switch, party-ask, party-battle, party-spectating, two-parties.
- Our `.github/workflows/release.yml` is **correct** (it strips
  `.modkitignore` entries + docs/; it is ahead of the engine's template —
  an agent's "drift" claim had the diff direction backwards).
- Stale doc versions: `README.md:965` ("Known jank" says 0.5.0),
  `server/README.md:751` (clone pin v0.2.2). Version truth: manifest /
  CHANGELOG / server/package.json all 0.7.1; latest tag v0.7.1 == HEAD.
- Release bump rule (fleet knowledge): a bump touches manifest.json,
  server/package.json, README "Known jank" line, server/README clone pin,
  + CHANGELOG heading.
- PR mechanics: SSH push as alamops works (`github-alamops.com`); **no** gh
  CLI, no API token, no fork of the index repo yet. PR creation needs the
  user's browser session or a one-click handoff.

## 3. Approach & key decisions

- **Two deliverables, decoupled:** (a) index-entry PR against v0.7.1 as
  currently released — the two stray test-driver files are inert Lua/shell,
  not ROM-derived, so the entry is honest today; (b) hygiene fixes + bump to
  0.7.2 on this branch so the *next* release zip is fully clean. Decision
  rests on measured zip contents, not on the checklist claims.
- **No thumbnail** in the index PR; instead `description.md` links the
  co-op battle and two-parties screenshots hosted in our own repo (same
  posture our repo already takes: ROM-composited shots illustrate a GitHub
  page, never ship in an archive).
- meta.json `version: 0.7.1` (the currently-released version); the nightly
  index rebuild tracks future releases automatically.
- Index PR authored in a scratchpad clone, validated with the index's own
  `node scripts/validate.mjs mods/alamops@rby_mmo` before submission.

## 4. Work breakdown — implementation

- **T1 (agent, opus) — mod-repo hygiene, this worktree only.**
  Files owned: `.modkitignore`, `manifest.json`, `server/package.json`,
  `README.md`, `server/README.md`, `CHANGELOG.md`.
  Add 9 missing `.modkitignore` entries (2 test drivers with rationale
  comments matching file style, 7 screenshots in the screenshots block);
  bump 0.7.1→0.7.2 in manifest + server/package.json; fix README:965 to
  0.7.2; fix server/README:751 pin to v0.7.2; add CHANGELOG `## [0.7.2]`
  entry (packaging fix). Acceptance: all five version sites agree at 0.7.2.
- **T2 (orchestrator) — index entry.** Clone index repo to scratchpad, write
  `mods/alamops@rby_mmo/meta.json` + `description.md`, run their validator.
  Files owned: scratchpad clone only.

T1 ∥ T2 — disjoint trees, one wave.

## 5. Work breakdown — tests

No new tests: no `src/` or `server/` code changes (metadata/docs/packaging
only), so the e2e drivers are **not applicable** (their trigger is behavior
changes; nothing here alters behavior). Existing gates to run:
- **T3 (agent, haiku):** `luajit mods/rby_mmo/tests/rby_mmo_test.lua`,
  `luajit tests/run_modkit.lua`, `modkit validate --strict`, `lint`, `pack`
  from the engine checkout + verify the packed archive contains no
  `tests/drivers/mmo_quad*`, no `run-quad-e2e.sh`, no `docs/screenshots/*`.
- **T4 (orchestrator):** `node scripts/validate.mjs mods/alamops@rby_mmo` in
  the index clone (already part of T2 acceptance).

## 6. Execution waves

Wave 1: T1 ∥ T2. Barrier. Wave 2: T3 (+ Phase 5 review of the mod-repo
diff). Wave 3: delivery — push branch, create both PRs (browser-session
path; else handoff URLs).

## 7. Blast radius & risks

- `.modkitignore` additions only shrink the packed/released archive; the
  release workflow reads it at build time — next tag ships clean.
- Version bump to 0.7.2: merging this branch to main auto-tags v0.7.2 and
  publishes a release (workflow trigger). That is the *intended* effect and
  is gated on the user merging.
- Index PR: reviewed by the upstream maintainer; CI check-links hits our
  v0.7.1 release asset (exists, verified).
- Identity risk on browser path: must verify github.com session is
  `alamops` before any fork/PR action; abort to handoff otherwise.

## 8. Open questions / assumptions (autonomous mode)

- **A1 — screenshots:** committing ROM-derived screenshots to the index is
  prohibited by their policy and our repo's legal posture, so the user's
  "send the COOP battle one" is honored as *links* in description.md, not
  committed pixels. If the user disagrees, the only compliant alternative
  is an original-art thumbnail (mod's own NIRE art on a neutral background).
- **A2 — meta.json version** pinned to released 0.7.1 (not the in-flight
  0.7.2) so the entry is truthful the moment the PR opens.
- **A3 — categories** `["GAMEPLAY"]`, tags `mmo, multiplayer, online,
  co-op, chat, trading` (index enum has no MECHANIC; GAMEPLAY is the fit).
- **A4 — version bump to 0.7.2** treated as in-scope prep ("prepare it for
  auto update"), since it is the only way the leaked test drivers leave the
  distributed zip.
- **A5 — both hard gates self-approved** per autonomous invocation.
