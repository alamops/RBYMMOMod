> **Historical plan.** Written against an older PROTOCOL / version than today.
> Not the live contract — see `Config.PROTOCOL`, `CHANGELOG.md`, and
> [`docs/plans/README.md`](README.md). Kept for design history.

# Plan — Run consent, blackout on loss, invite gating (round 4 findings)

| Field | Value |
| --- | --- |
| Date | 2026-08-05 |
| Source | owner's third play session — five findings |
| Config | AGENTS_CONFIG.yml (quality) |
| Branch | feature/2x2-battles (uncommitted by owner's choice; snapshots to scratchpad `run-blackout-baseline/`) |
| Base SHA | working tree |

## 1. Objective & success criteria

1. **You cannot ask your own partner for a 2-on-2.** The `PARTY BATTLE` row is
   absent from the interact menu for your own party member, and a guard in
   `challenge()` makes the state unreachable even if the row were forced. The
   ~70s "You already asked" soft-lock dies with it.
2. **Losing a co-op battle blacks you out, vanilla-style** (owner-decided):
   every player whose party lost — or who ended any co-op battle with zero
   healthy monsters — gets the full Gen 1 ritual: party healed, money halved,
   warp to *their own* last Pokémon Center. NPC path through the engine's own
   `afterBattle`; PvP path via a mod-side mirror of the same ritual. No player
   is ever left standing in the overworld with an all-fainted party.
3. **A dead party can't enter a 2-on-2.** Belt-and-braces: the battle host
   refuses to start a field where either party has no healthy monster, closing
   the group with a message instead of a broken battle. (After #2 the state
   should be unreachable; the guard is for the day it isn't.)
4. **RUN works, with consent** (owner-decided): in a party-vs-party battle,
   picking RUN prompts the partner in-battle with yes/no. Yes → the party
   flees: battle ends for all four, runners take a **ranked loss**, opponents
   the win. No → "BETA says NO!"-style message, asker back at the command
   menu, no turn consumed. Unanswered at the 60s deadline → counts as no, and
   normal auto-pick proceeds — the prompt can never deadlock the battle.
   Versus an NPC trainer the authentic refusal stays exactly as is.
5. **No stale "Asked <NAME> for a 2-on-2 battle." box** after a battle — the
   asker's message can no longer be buried by the battle screen and resurface
   when it pops.
6. **The "Waiting for … (0)" freeze is diagnosed and fixed** with a
   regression pin, whatever action kind triggers it.

## 2. Context & constraints (anchors from the two investigation briefs)

- **Partner invite**: `PARTY BATTLE` added unconditionally at `Ui.lua:1454`
  (comment says so); `ctx.party:isPartner(id)` exists and is already used at
  `Ui.lua:1377`. `Coop:challenge` (`Coop.lua:460-496`) never checks
  `peer.id ~= partner.id`. The hub silently drops a self-party challenge
  (`Hub.lua:1388`), so today the asker soft-locks ~70s
  (`COOP_ASK_TIMEOUT` 60 + `COOP_ASK_GRACE` 10) with no feedback.
- **Blackout — the shipping bug**: co-op reports `"loss"`
  (`CoopBattle.lua:1594-1599`) but the engine's
  `OverworldState:afterBattle` (`OverworldController.lua:3607-3648`) runs the
  blackout ritual only on `"lose"`. `Coop:consume` (`Coop.lua:147-177`) also
  calls `engine.onFinish` directly, bypassing `BattleState:finish()`'s
  zero-healthy safety net (`BattleState.lua:4121-4160`, whose comment names
  this exact "unrecoverable state"). **And `consume` returns false when there
  is no NPC encounter** (`Coop.lua:150-152`) — a PvP party battle has no
  engine battle at all, so no string fix can reach the ritual there.
- **The ritual's ingredients are reachable without engine requires**:
  `Game.save.lastHeal = {map,x,y}` (set by `nurseHeal`,
  `OverworldController.lua:2687-2694`; fallback `SaveData.defaultHeal`),
  `game.save.party` mons (the mod already reads them for `packParty`),
  `mod.world:warpTo` (`WorldAPI.lua:48-60`). There is **no facade heal
  primitive** — the PvP ritual writes save data the mod already holds
  (hp/status/PP fields + `save.money`), which trips no permission tripwire
  (that catches requires, not table writes). Logged as a candidate upstream
  RFC (`WorldAPI:blackout()`), not blocking.
- **No pre-battle aliveness data exists on the wire** (presence carries no HP
  — `Wire.lua:566-596`); the first point full HP exists is the battle host's
  `buildField` (`Coop.lua:800-848`). The refusal therefore lives there, not
  in a protocol change.
- **RUN today is a designed refusal**, not a gap: `CoopBattle.lua:923-928`
  commits `kind="run"`, `CoopSim:runFlee` (`CoopSim.lua:619-629`) emits the
  vanilla trainer-battle refusal and costs the turn. There is no success
  path; consent-run is **new functionality**. Engine: `tryRun`
  (`BattleState.lua:3810-3821`) refuses trainer battles before the hookable
  wild-escape roll — the refusal text is authentic.
- **Both hubs forward relay payloads unread** — `payloadOk` is shape-only
  (depth/node caps; `sanitize.js:99-114`, `Wire.lua:324`; handlers
  `relay.js:451-466`, `Hub.lua:1353-1368`). New `t` kinds inside the
  `COOP_RELAY`/`COOP_MSG` envelope need **no hub change on either side**;
  old clients ignore unknown kinds.
- **Yes/no skeleton to reuse**: ask-state + request msg + `confirm` + answer
  msg (`Party.lua:117-154`, `Coop.lua:460-538`). But the run prompt is
  *in-battle*: it renders inside `CoopBattle` (its own screen owns input), as
  a picker-style prompt, not an overworld `SCREEN.CONFIRM`.
- **Stale box mechanism**: the asker's `ui:say` (`Coop.lua:494`) pushes a
  self-owning TextBox on the engine stack; `startBattle` unwinds only when an
  NPC encounter exists (`Coop.lua:1027-1030` `if engine then`), so the
  challenge path buries the box under the battle screen (buried screens get
  no `update`), and it resurfaces at pop.
- **Stuck "(0)" leads**: `autoPickLate` (`CoopBattle.lua:2636-2710`) is
  all-or-nothing — one live slot with `defaultAction == nil` (no living
  target, `CoopSim.lua:1369-1373`) aborts the whole attempt and re-arms the
  deadline, in a loop, forever. In-code comment at `CoopBattle.lua:779-790`
  records a previously-fixed bug with this exact symptom. Diagnosis is task
  B's first step; the fix must cover whatever the reproduction shows.

## 3. Approach & key decisions

1. **Owner-decided policies** (grill, 2026-08-05): full vanilla blackout
   (heal + warp + money halving); runners take a ranked loss; NPC refusal
   stays; unanswered consent prompt = "no" at the deadline.
2. **Blackout, two paths, one rule.** Per client, compute the effective
   result: team lost → `lose`; team won/drew but own party has zero healthy
   mons → `lose` (the engine's own safety-net rule, adopted mod-side because
   `consume` bypasses `finish()`). NPC path: translate to the engine's
   vocabulary and let `engine.onFinish("lose")` run the engine's own ritual —
   adopt, don't reimplement. PvP path (no engine): a mod-side
   `blackoutRitual(game)` — heal every party mon (hp=max, status clear, PP
   restore, mirroring `Pokemon.heal`), halve `save.money` (floor, vanilla
   divisor), warp via `mod.world:warpTo` to `save.lastHeal` or the default
   heal fallback. Each client runs its own ritual — "each one to their own
   Center" falls out for free.
3. **Dead-party refusal at `buildField`** — first place HP truly exists. The
   battle host, on detecting a side with no healthy monster, does not send
   the field; it closes the group (existing `COOP_LEAVE` one-goodbye-closes-
   all path) and says why locally; remote members see the existing
   group-closed handling. No new wire vocabulary.
4. **Partner gating in two layers**: hide the `PARTY BATTLE` row when
   `ctx.party:isPartner(peer.id)` (menu truth), and an early guard in
   `challenge()` with a clear message (state truth). The hub's silent drop
   stays as the third, untrusting layer.
5. **Run consent rides the relay.** New in-battle payload kinds
   (`t="run_ask"` / `t="run_answer"`, fanned like every relay message;
   partner answers, others ignore). Asker picks RUN (PvP only) → local
   "asking partner" wait + relay ask → partner sees an in-battle yes/no
   prompt (CoopBattle-drawn, same picker input style) → yes: the **host**
   resolves the flee — emits the closing events ("<NAME>'s party fled!"),
   sets the result (runners lose / opponents win), normal ranked reporting
   and the new blackout rule then apply; no: relay answer back, asker
   returns to the command menu, nothing committed. Deadline: prompt and
   pending ask are torn down by the existing auto-pick moment and count as
   declined. Partner gone/disconnected → solo party, no consent needed.
   Partner present but fainted-spectating → still asked (they have a
   screen). NPC battles: `runFlee` refusal untouched.
6. **Stale box**: `startBattle` unwinds the pending ask box on the challenge
   path too (drop the `if engine then` asymmetry — unwind whatever the ask
   flow left on the stack before pushing the battle screen), and the ask
   lifecycle closes its own box when the ask resolves. Both ends covered.
7. **Stuck "(0)"**: reproduce first (headless: drive turns until the wait
   line freezes; the all-or-nothing abort loop is the prime suspect — e.g.
   auto-pick aborting forever because one slot has no living target while a
   replacement is pending). Fix per evidence — likely: a slot whose
   `defaultAction` is nil because it has nothing to do this turn must not
   veto auto-picking the slots that do. Regression-pin the exact frozen
   state from the screenshot.

## 4. Work breakdown — implementation (one wave, two tasks, disjoint)

| ID | Goal | Owns | Acceptance |
| --- | --- | --- | --- |
| A | Partner-invite gating (menu + guard); effective-result rule + NPC `"lose"` translation + PvP `blackoutRitual`; dead-party refusal at `buildField`; stale ask box (unwind + lifecycle close) | `src/Coop.lua`, `src/Ui.lua` | Partner row hidden + guarded; losing/zero-healthy players heal-warp on both paths; dead party refused with group close; no box survives a battle |
| B | Run-consent flow over the relay (ask/prompt/answer/flee resolution, ranked loss, deadline-declines); NPC refusal preserved; stuck-(0) reproduction + fix | `src/CoopBattle.lua`, `src/CoopSim.lua`, `src/Wire.lua` | RUN in PvP prompts partner; yes ends battle with runners' loss on every client; no/timeout cancels cleanly; NPC refusal byte-identical; the freeze is reproduced, fixed, and pinned |

Contract A→B: A never touches `Wire.lua`/battle files; B never touches
`Coop.lua`/`Ui.lua`. The flee outcome surfaces to A's code purely through
the existing `onDone(result)` — `"loss"`/`"win"` as today (B makes the flee
produce them; A maps them to the ritual). No other cross-task surface.

## 5. Work breakdown — tests

| ID | Layer | Covers | Owns |
| --- | --- | --- | --- |
| T1 | headless suite | Partner gating (row absent for partner, guard message, non-partner unaffected); effective-result matrix (loss→lose; win-with-zero-healthy→lose; win normal→win); PvP ritual (heal/status/PP, money halved with floor, warp target = own lastHeal, fallback when unset); NPC path passes `"lose"` to `engine.onFinish`; dead-party refusal (field never sent, group closed); stale-box unwind on the challenge path; run-consent state machine (ask sent PvP-only, prompt renders, yes→flee events + result loss/win on host and replayers, no→menu restored nothing committed, deadline→declined + auto-pick, partner-gone→no prompt needed, NPC→refusal unchanged); ranked reporting of the fled outcome; stuck-(0) regression pin from B's reproduction | `tests/rby_mmo_test.lua` |
| T1b | e2e drivers | Quad driver: losing bots now blackout-warp after the 2-on-2 — update post-battle assertions/legs accordingly (fresh fixtures have no `lastHeal` → they warp to the default heal point); optionally add a RUN-consent leg (ALPHA asks, BETA consents, battle ends) if the budget holds | `tests/drivers/mmo_quad.lua`, `tests/drivers/run-quad-e2e.sh` |

Full battery after T1 (suite, T4, node hub, validate/lint/pack, hub e2e,
quad e2e, LAN e2e), orchestrator-run.

## 6. Execution waves

Wave 1: A + B parallel → barrier (suite) → review (opus, code-review skill)
→ T1/T1b (sonnet) → fixes loop → battery → screenshots if stale → play
session for the owner.

## 7. Blast radius & risks

- The quad e2e's post-battle legs assume losers stay put — **they will warp
  now**; T1b owns updating the driver before the battery, or the battery
  fails honestly.
- The blackout writes the real save (`party`, `money`) on the PvP path —
  scoped to the exact fields vanilla touches, behind the effective-result
  rule; NPC path unchanged (engine's own code).
- Consent messages ride the opaque relay — old clients ignore unknown `t`
  kinds; a mixed-version battle degrades to today's refusal (asker's ask
  times out as declined at the deadline). No protocol bump.
- Ranked: the fled outcome reuses `loss`/`win` — no new outcome vocabulary,
  `rank.js`/`Rank.lua` untouched.
- The `finish()` bypass in `consume` stays (it is what lets the mod pay
  prize money correctly); the safety net it skipped is now mirrored by the
  effective-result rule.

## 8. Open questions / assumptions

- Money halving uses the vanilla divisor (2) on both paths — assumed.
- The flee message wording mirrors vanilla tone ("<NAME>'s party fled!") —
  wording is implementer's judgment, suite asserts substance not phrasing.
- The consent prompt is CoopBattle-drawn (in-battle), not an overworld
  confirm — required, since the battle screen owns input while up.
- Upstream RFC for `WorldAPI:blackout()` is worth filing later; this round
  ships the mod-side mirror (documented divergence, no engine requires).
