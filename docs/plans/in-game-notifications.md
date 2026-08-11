> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — In-game toast notifications

| Field | Value |
| --- | --- |
| Date | 2026-08-07 |
| Source | /implement: notifications for chat, party combat/capture, join/leave |
| Config | AGENTS_CONFIG.yml (quality: impl/review/fixes=opus, investigate/tests-creation=sonnet, tests-running=haiku) |
| Branch | `fix/notifications` (shipped as **0.10.0**; PROTOCOL **8** — 7 was already taken on main) |
| Base SHA | `f81c4db7e569a4cd23660394c7f7b97ba79b2089` |
| Mode | Interactive — grill answers locked 2026-08-07 |

## 1. Objective & success criteria

Ship a **new HUD toast layer** (not ModUI / `Ui.lua` screens, not Pokémon `mod.ui.Font`) that shows transient lines in the **top-left**, low-opacity black plate + **white open-source gamer font**, auto-hiding after **5s**, stacking up to **5**.

| Event | Who sees it | Copy |
| --- | --- | --- |
| Chat (all scopes, incl. own outbound) | Local player | `[Name]: message` |
| Party member wins wild | Partner only | `<Name> defeated Pidgey lv 5` |
| Party member wins trainer | Partner only | `<Name> defeated <NPC>` |
| Party member loses to wild | Partner only | `<Name> was defeated by Pidgey lv 10` |
| Party member loses to trainer | Partner only | `<Name> was defeated by <NPC>` |
| Party member captures | Partner only | `<Name> captured Mewtwo lv 70` |
| Player joins hub | Everyone else on server | `<Name> joined the server` |
| Player leaves hub | Everyone else on server | `<Name> left the server` |

Done means:
- Toasts draw over the finished frame like other HUD (menus included).
- Speech bubbles over heads are **removed** (chat toasts replace them).
- Party combat/capture uses a **new** `mmo.party_event` wire type + hub party fan-out; **PROTOCOL 6 → 7**.
- Fighter does **not** toast their own combat/capture; partner does.
- Own chat lines toast locally (as well as inbound).
- Headless Lua suite + hub tests green; toast queue state exportable for drivers.

## 2. Context & constraints

**Draw path.** Only `Overlay` uses `render.hud` today (`Client.lua` wrap → `overlay:draw`). Viewport is window-space; Overlay remaps into 160×144 via `beginFrame`/`endFrame` (`Overlay.lua:263-282`). Roster already anchors top-left (`drawRoster`, ~185-201). Toasts should use **window/letterbox top-left** with `love.graphics.print` so they stay readable at any scale — not the ROM font (`mod.ui.Font`), which lacks common glyphs and caused the unread-marker removal in `37fcc2f`.

**No toast primitive yet.** Connect deliberately skips `ui:say` modals (`Client.lua` ~1126-1132). Join/leave only mutate roster (`handlers[Wire.JOIN/PART]`). Chat feeds history + bubbles; bubbles go away.

**Party combat has no wire path.** Solo wild/trainer fights produce no peer traffic. Engine events available: `battle.ended` `{ battle, result }`, `pokemon.caught` `{ species, mon, … }`, `world.blacked_out`. Co-op battles do **not** fire engine `battle.ended` (`CoopBattle.lua` comments) — out of scope for this toast path (no partner-solo narration needed for shared co-op fights).

**Font.** Bundle **Press Start 2P** (SIL Open Font License 1.1) under `assets/fonts/` + `OFL.txt`. Load via `mod.assets:path` + `love.graphics.newFont` (same asset-path pattern as `Cast.lua:39-47`). Fallback: LÖVE default font if the TTF fails to load (log warn + remediation).

**Protocol.** `Config.PROTOCOL` and `server/lib/relay.js` `PROTOCOL` must bump together (currently 6). Claim **7** for `mmo.party_event`.

**Branch.** `fix/notifications` tip is stale vs `main` (~5 commits). **Rebase onto `main` before any implementation commits.**

**Legal.** Font is original OFL; no ROM bytes. `affects_link` stays `false`.

## 3. Approach & key decisions

| Decision | Choice | Why |
| --- | --- | --- |
| UI surface | New `src/Toast.lua`, drawn from `render.hud` after `next()` | User: brand-new UI, not ModUI; matches HUD compositing |
| Font | Press Start 2P TTF in mod assets | User: open-source gamer font, not Pokémon font |
| TTL / stack | 5s, max 5, drop oldest on overflow | Owner answers |
| Chat | Toast all scopes + local echo; **delete speech bubbles** | Owner answers |
| Party combat fan-out | **(B)** `mmo.party_event` + hub party relay | Owner answers; not chat spam |
| Join/leave | Toast from existing JOIN/PART handlers (broadcast already) | No new wire |
| Fighter self-toast | No | Partner-only |
| Own chat toast | Yes | Owner answer |
| Version | Minor **0.8.0** (feature) | New capability; lockstep manifest / server package / CHANGELOG / README |

### `mmo.party_event` shape

Outbound (fighter → hub), hub stamps/fills `name` from the authenticated client (do not trust peer `name` for display identity beyond sanitised echo):

```lua
{
  type = "mmo.party_event",
  kind = "defeat_wild" | "defeat_trainer" | "defeated_by_wild"
       | "defeated_by_trainer" | "capture",
  species = <string|nil>,   -- wild / capture display name
  level   = <int|nil>,      -- 1..100
  trainer = <string|nil>,   -- NPC trainer display name
}
```

Inbound to partner: same fields + authoritative `name` (fighter’s nick).

Hub: require sender `ready` + `partyId`; fan out to other `partyMembers` only (mirror `mmo.chat` party branch at `relay.js:283-288`). Drop if not in a party.

Client emit gates:
- Only when `party:partner()` exists and transport ready.
- On `pokemon.caught` → `capture` (prefer this over `battle.ended`/`caught` to avoid double-send).
- On `battle.ended`: `win` → defeat_*; `lose` → defeated_by_*; skip `run`, `caught`, Sessions-owned link battles, and any battle already handled as capture.
- Derive wild vs trainer from `battle.kind` / trainer fields already on the battle object (match existing engine conventions used elsewhere in the mod if any; otherwise read `battle.kind == "wild"` vs trainer).

Formatters live in `Toast` (or a tiny helper next to Wire) so hub stays dumb.

### Bubble removal

- Stop calling `chat:bubble` from Client chat handler / say.
- Stop Overlay drawing bubble text above heads (nameplates only).
- Remove `bubbles` mod option (or leave dead — prefer remove to avoid a no-op toggle).
- Trim `Chat` bubble API + `Config.BUBBLE_SECONDS` if nothing else needs them; update tests/drivers that assert bubbles.

## 4. Work breakdown — implementation tasks

### T0 — Rebase (orchestrator)
- Rebase `fix/notifications` onto `main`; record Base SHA in this plan.
- Files: none (git only).

### T1 — Toast module + font asset
- **Owns:** `src/Toast.lua` (new), `assets/fonts/PressStart2P-Regular.ttf`, `assets/fonts/OFL.txt` (and any README note for the font).
- **Also owns (config slice):** `src/Config.lua` keys `TOAST_SECONDS=5`, `TOAST_MAX=5`, `TOAST_FONT=…` (path relative to assets). **Do not** bump PROTOCOL here if T2 is parallel — see waves: T1 runs alone first *or* T1+T2 are sequenced. Prefer **T1 then T2** on Config, or single agent for Config+Wire — see §6.
- API: `new(ctx)`, `push(text)`, `update(dt)`, `draw(viewport)`, `clear()`, `list()` / `state()` for exports.
- Draw: top-left letterbox inset, stacked downward, `rgba(0,0,0,~0.65)` plate + white text; clip/truncate long lines safely for the TTF metrics.
- Acceptance: pure logic (queue age/evict) unit-testable without `love.graphics`; draw guarded so missing `love` does not throw in headless.

### T2 — Wire + hub `mmo.party_event` + PROTOCOL 7
- **Owns:** `src/Wire.lua` (constant + sanitiser), `server/lib/relay.js` (PROTOCOL=7 + handler), `src/Config.lua` PROTOCOL comment/bump to 7 (coordinate with T1 — same wave barrier).
- Acceptance: bad payloads nil out; hub fans only to party peers; protocol mismatch still refuses with version names.

### T3 — Client wiring + Overlay/Chat bubble removal
- **Owns:** `src/Client.lua`, `src/Overlay.lua`, `src/Chat.lua`, option schema touch in Client; `main.lua` only if Toast must be resolved there.
- Wire `ctx.toast`, `render.hud` draw + `input.step`/`chat:update` tick for toast ages.
- Chat → toast (inbound + local `say` echo); JOIN/PART → toast; `handlers[Wire.PARTY_EVENT]` → toast; emit party_event from battle/caught listeners; `mod.exports.toasts`.
- Clear toasts on disconnect/leave with other session state.
- Acceptance: no bubble draw path remains; partner-only combat toasts; join/leave/chat behave per §1.

### T4 — Version / changelog lockstep
- **Owns:** `manifest.json`, `server/package.json`, `CHANGELOG.md`, `README.md` (version strings only as required by `testVersionParity`).
- Feature entry under 0.8.0 describing toasts, bubble removal, protocol 7.

## 5. Work breakdown — test tasks

### S1 — Lua unit / integration (`tests/rby_mmo_test.lua`)
- Toast queue: push, TTL expiry, max-5 eviction, clear.
- Wire `party_event` sanitiser round-trips / rejects junk.
- Client-facing formatters for the five party kinds + chat/join/leave strings.
- Chat no longer creates bubbles; overlay/export expectations updated.
- Covers: T1–T3.

### S2 — Hub (`server/` tests)
- `mmo.party_event` relayed to other party member only; ignored when unpartied; PROTOCOL 7 hello still works.
- Covers: T2.

### E2E
- **Applicable** for visual confirmation, but no new heavy harness: extend driver export via `mod.exports.toasts()` so a future/manual e2e can assert queue text without screenshot OCR.
- Full two-instance LÖVE e2e is environment-heavy (ROM); Phase 7 runs headless Lua + `node server/*.test.js` as the automated bar. Optional: note manual check with two clients if ROM present.
- Recorded run recipe: from engine root `luajit mods/rby_mmo/tests/rby_mmo_test.lua`; from repo `node server/hub.test.js` (and/or focused relay test file).

## 6. Execution waves

```
Wave 0: T0 rebase                    (orchestrator)
Wave 1: T1 Toast+font+TOAST config   then T2 Wire+hub+PROTOCOL
        (sequenced: both touch Config.lua)
Wave 2: T3 Client/Overlay/Chat       (after T1+T2)
Wave 3: T4 version bump              (after T3, or with T3 if careful)
Tests:  S1 || S2 after impl waves
```

Barrier: no T3 until T1+T2 merged; no pack/version until behavior lands.

## 7. Blast radius & risks

- **PROTOCOL 7** breaks old hubs/clients until both updated — intentional; refusal message must stay clear.
- **Bubble removal** changes UX for players who liked head bubbles — explicit product choice.
- **Font asset size** in packed mod — Press Start 2P is small; include OFL.
- **`battle.ended` vs catch:** must not double-notify; skip `result=="caught"` on ended when `pokemon.caught` already sent.
- **Link / ranked battles:** do not emit party_event for Sessions link fights (same filter spirit as `reportBattle`).
- **Co-op 2v2:** engine events absent — no party_event from those fights (acceptable; both sides already know).
- **Roster HUD vs toasts:** both top-left in voxel fallback — stack toasts below a small margin or accept overlap with rare roster strip; prefer toasts at a fixed window inset independent of Overlay’s 160×144 roster.
- Rollback: revert module + protocol bump together.

## 8. Open questions / assumptions

Resolved with owner (2026-08-07):
1. TTL 5s, max 5 — **locked**
2. Open-source gamer font in mod — **Press Start 2P (OFL)** assumed as the concrete face
3. Party fan-out **(B)** structured wire — **locked**
4. Partner-only combat; server-wide join/leave; all-scope chat; no bubbles — **locked**
5. Copy formats + own chat toast — **locked**
6. HUD compositing + rebase onto main — **locked**

Assumptions (audit if wrong):
- A. Press Start 2P is an acceptable “gamer font”; swap to another OFL pixel face only if owner objects after seeing it.
- B. Trainer display name comes from the battle/trainer object the engine already exposes on `battle` (to be confirmed when wiring; if missing, fall back to `"Trainer"`).
- C. Species display uses a human-readable name from the mon/species id (title-case / data name), not raw ids like `MEWTWO` unless that is what the game shows.
- D. E2E screenshot assertion is out of automated Phase 7; headless + hub tests are the merge bar.
- E. Branch name may stay `fix/notifications` even though the CHANGELOG treats this as a feature (0.8.0).
