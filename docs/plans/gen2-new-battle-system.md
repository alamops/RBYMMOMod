# Plan — the new battle system, mechanics and UI on Gen 2

> **Status (2026-08-14):** **landed** on `feature/new-battle-system-for-gen2`.
> Base SHA `79bcc7d` (`feature: close Gen2 Gold e2e product loop on live LOVE`).
>
> Verified: mod suite 4436/4436; T4 22/22 suites; `node --test` 257/259 (the
> two failures, `auth.test.js` and `server.test.js`, fail identically on the
> unmodified base SHA); `modkit validate` / `lint` / `pack` clean. Live LOVE:
> `run-battlefield-e2e.sh` **and** `run-battlefield-e2e-gen2.sh` both 34/34
> GAPS:0 on the same driver; `run-mmo-e2e.sh` and `run-mmo-e2e-gen2.sh` both
> 0 failures, the latter including the arena on both clients and a refereed
> Gen 2 exp payout that persisted to the save (27000 → 27032, 2 awards).
>
> **The one thing this pass discovered that the plan did not predict:** the
> theatre gate was not the only switch. `src/core/Game2.lua` has no
> `uiSize` / `wantsFillScale` seam at all, so flipping the gate alone
> rendered the arena into a 160-wide surface. Gold's own seam is
> `drawsWidescreen()` / `drawWidescreen(w, h)` — see §3.

| Field | Value |
| --- | --- |
| Date | 2026-08-14 |
| Branch | `feature/new-battle-system-for-gen2` |
| Base SHA | `79bcc7dc` |
| Predecessors | [`gen2-compatibility.md`](gen2-compatibility.md) (Waves 0–4, shipped), [`better-battle-ui.md`](better-battle-ui.md), [`guild-focus-battle-ui.md`](guild-focus-battle-ui.md) |

## 1. Objective

`gen2-compatibility` made Gen 2 a first-class *product* surface — gen-locked
hubs, `BattleSim2` + `server/lib/battle2`, Gen 2 trade, Gen 2 co-op replay, a
live Gold e2e. It deliberately deferred one thing, in its own words:

> Gen2 keeps the classic guild-focus / 160×144 path until a later pass.

This is that pass. Everything the Gen 1 line has gained since — the top-down
battlefield theatre, the modern battle band, the fx/throw choreography, and
the PROTOCOL 21 experience loop — becomes generation-agnostic, and the Gen 2
e2e grows the legs that prove it on a live Gold boot.

**Done means all of:**

1. A mediated 1v1 and a mediated co-op fight on a **Gen 2 hub** draw on the
   top-down arena with plates, band, fx and throws — the same presentation a
   Gen 1 fight gets, not the 160×144 GB chrome.
2. `BattleSim2` and `server/lib/battle2` emit the **same `exp` event stream**
   the Gen 1 twins do, in the same order, under the same mode gate
   (`wild` / `coop_wild` / `coop_npc`), and pin it in shared fixtures.
3. A stolen KO **retargets** on Gen 2 exactly as it does on Gen 1.
4. Each Gen 2 client applies its own award with the **Gen 2** formula
   (`src/battle/gen2/Mon.gainExperience` + Gen 2 stat exp + the Exp Share
   halved pass), never Gen 1's `src/battle/Experience`.
5. Gen 1 behaviour is byte-identical: Gen 1 vectors, twin parity, the Gen 1
   suite and `run-mmo-e2e.sh` all stay green.
6. `run-mmo-e2e-gen2.sh` asserts the arena and the award on live Gold, and a
   Gold counterpart to `run-battlefield-e2e.sh` screenshots the Gold arena.
   Both still exit 0 when the Gold cache is absent.

## 2. Grounded findings (what is actually Gen 1-only today)

| Gap | Evidence |
| --- | --- |
| The whole theatre | `src/Battlefield.lua` `M.enabled(game)` returns `gen == 1`. `MediatedBattle:usesBattlefield` and `CoopBattle:usesBattlefield` are both one-liners over it, and `uiSize` / `wantsFillScale` / `isWideBattleLayout` hang off those. **Read at plan time as "the gate is the only switch" — that was wrong**, and §3 records the correction: `uiSize` / `wantsFillScale` are Gen 1 seams that `src/core/Game2.lua` does not have, so the gate turns the theatre on and Gold still needs a surface to draw it into. |
| Front pics | `MediatedBattle:seatFront` probes `eng.BattleState.makeBattler` (Gen 1). Gold resolves a front from `data.pokemon[key].spriteFront` (`src/ui/gen2/BattleState.lua:442`). |
| Experience | `fought` / `foughtKey` / `pendingFought` / `_unfield` / `_awardExp` / `EXP_MODES` exist in `src/BattleSim/Turn.lua` and `server/lib/battle/Turn.js`; **zero occurrences** in either Gen 2 twin. No `exp` event is ever emitted on a Gen 2 hub. |
| Client apply | `MediatedBattle` / `CoopBattle` price the award with `src.battle.Experience.apply`, which is Gen 1. Gen 2's award lives inside `src/battle/gen2/Battle.lua` (`giveExperiencePass` / `awardExperience`) rather than a standalone module, and differs: Gen 2 stat exp, the Exp Share **halved second pass**, the traded and Lucky Egg boosts. |
| Retargeting | `_retarget` in both Gen 1 twins; absent from both Gen 2 twins, so a stolen KO in a Gen 2 2v2 still fizzles with "has no target". |
| e2e | No Gen 2 leg draws or asserts the arena; `run-battlefield-e2e.sh` boots Red only. |

Two things this pass does **not** need:

- **No PROTOCOL bump.** `exp` already joined `Wire.BATTLE_EVENTS` and
  `server/lib/sanitize.js`'s whitelist at PROTOCOL 21, and it is not
  generation-tagged. A Gen 2 hub that starts emitting it is speaking a
  vocabulary its clients already parse.
- **No `affects_link` change.** Nothing here writes a link registry.

## 3. Approach

### The exp referee is already generation-agnostic

The hub holds no species table — by the legal floor, it never will — so
`_awardExp` emits **facts, not an amount**: which monster fell, its level, and
how many shares split it. Nothing in that is Gen 1-shaped. The port is
therefore a faithful mirror of the Gen 1 participation machinery into
`BattleSim2`, not a re-derivation, and the generation difference lands
entirely on the client, where the formula and the save both live.

That also means the parity contract is unchanged in kind: the Lua and Node
Gen 2 twins must emit the identical list in the identical order, pinned by
`tests/fixtures/battle_sim2_vectors.json`.

### The theatre gate is one function — and one surface

**Corrected during implementation.** The gate really is one function, but
turning it on is only half the job on Gold, and the half the plan missed is
the bigger one.

`Battlefield.enabled` becomes a capability question rather than a generation
one: the arena needs a front pic per seat and a walk sheet per human, and both
resolve on Gold. The Gen 1-only *sources* move behind `Gen.lua` helpers so
`Battlefield.lua` itself stays presentation-neutral (it already is — its only
engine reaches are `PaletteFX`, `Assets` and `SpriteRenderer`, all dual-gen).

**The surface is the real difference.** `src/core/Game.lua:471` widens the
render surface for any state that answers `uiSize()` and fill-scales it when
it answers `wantsFillScale()`. `src/core/Game2.lua` does neither — it never
calls `setUISize`, and `src/ui/gen2/Chrome.lua:fitScale` hardcodes the
160×144 panel grid. With the gate up and nothing else changed, the arena drew
into a 160-wide surface and the window showed its top-left corner at 6×.

What Gold has instead is `drawsWidescreen()` / `drawWidescreen(w, h)`: a state
that opts in paints the **whole window, in window units**, and its GB panel
blits on the integer grid over that (`Game2:drawScene`, the `wide` branch).
That is the same seam Gold's own battle screen uses
(`src/ui/gen2/BattleState.lua:3133`), so this is a public state contract — not
an `engine_internals` reach-around, and not a Lane B change. Both mediated
screens implement it, reproducing Renderer's `uiFill` arithmetic
(`Up = min(ph/uih, pw/uiw)`, centred) in window space so a Gold arena and a
Red arena are the same picture at the same aspect. `drawSafe` no-ops when
`drawsWidescreen()` is true, or a text box pushed over the fight would put a
second 160×144 copy of the arena on the panel grid.

One consequence worth stating separately, because it is easy to get wrong in
the same way twice: **a zone rect is in the receiving generation's space, not
the space the state drew in.** Gen 1's are the widened UI canvas' own
coordinates; Gold's are always 160×144 screen space, because `Game2:blitZones`
scales every rect by `w/160, h/144` before it scissors. Handing Gold the
arena's 640×360 meant four times the window — it rendered correctly only
because the blit clamps, and it forced every frame onto the present-canvas
path (a render-target bind plus a full-screen blit) that a Gold frame with no
zones does not pay. Both screens now state 160×144 on Gen 2; the `colors =
false` opt-out the zone exists for works at any size.

Two further Gold-only sources turned up the same way, both found by the live
driver rather than by reading:

- **Front pics.** Gen 1 gets a keyed, coloured pic as a side effect of
  `BattleState.makeBattler`. Gold's `def.spriteFront` is a raw four-shade
  sheet whose colour 0 is WHITE, so loaded straight it is a grey monster in an
  opaque white box. `Battlefield.gen2FrontImage` does the two steps the
  hardware does: key colour 0, then map the rest onto `Palettes.monColors`.
- **Walk sheets.** Three sites read `data.sprites` — Gen 1's table. Gold keeps
  its sheets on `data.gen2Sprites`, so the lookup found nothing and the
  trainers simply never drew. `Gen.spriteCatalog` is the engine's own
  resolution (`src/world/gen2/NPC.lua:195`) in one place.

### Gen 2 exp apply

A thin mod-owned `Exp2` path mirrors `src/battle/gen2/Battle.lua`'s
`giveExperiencePass` over the mod's own party, because the engine exposes the
Gen 2 award only as a method on a live `Battle`. Same shape as `Trade2`: the
mod owns the apply, the engine owns the formula primitives
(`Mon.gainExperience`, the growth curve, stat exp).

## 4. Waves

| Wave | Work | Owns |
| --- | --- | --- |
| **W1** | Exp participation + `_awardExp` + `_retarget` in the Lua Gen 2 sim | `src/BattleSim2/Turn.lua` |
| **W2** | The hand-written Node twin of W1 | `server/lib/battle2/Turn.js` |
| **W3** | Vectors + twin parity for both | `tests/fixtures/battle_sim2_vectors.json`, `tests/battle_sim2_vectors.lua`, `server/battle2_vectors.test.js`, `tests/hub_battle.lua`, `server/hub_battle.test.js` |
| **W4** | Gen 2 client apply + the EXP strip on Gold | `src/Exp2.lua` (new), `src/MediatedBattle.lua`, `src/CoopBattle.lua` |
| **W5** | Arena + band on Gen 2 — the gate, the **widescreen surface**, Gold front-pic bake, `Gen.spriteCatalog`, Gold OBJ palettes for trainer sheets | `src/Battlefield.lua`, `src/Gen.lua`, `src/MediatedBattle.lua`, `src/CoopBattle.lua` |
| **W6** | e2e | `tests/drivers/run-mmo-e2e-gen2.sh`, `tests/drivers/mmo_host_gen2.lua`, `tests/drivers/mmo_join_gen2.lua`, `tests/drivers/battlefield_shot.lua` (made generation-aware, so ONE driver asserts both carts), `tests/drivers/run-battlefield-e2e-gen2.sh` (new), plus `expPaid` on `exports.coopSync` so an award is assertable at all |
| **W7** | Docs + version | `CHANGELOG.md`, `mod.card`, `README.md`, `server/README.md`, `manifest.json`, `server/package.json` |

**Barriers:** W1 before W2 (the Lua side authors the fixture); W1+W2 agree
before W3 closes; W5 after W4 only because both touch the same two screens.

## 5. Blast radius & risks

| Risk | Mitigation |
| --- | --- |
| Gen 1 regression from shared-file edits | Gen 1 vectors + twin parity + the 4392-check suite + `run-mmo-e2e.sh` all run before the branch is called done |
| Gen 2 exp drifting from the cart | Formula primitives come from the engine's own `gen2/Mon`; the mod only orchestrates the passes |
| Arena assumes a Gen 1 engine seam somewhere unmapped | The gate flip lands with the Gold arena e2e in the same wave, so a missing seam fails loudly on a real boot rather than silently degrading |
| Gold ROM absent in CI | Both drivers keep the existing clean-skip contract |

**Rollback:** revert the `Battlefield.enabled` gen check to `== 1` and the
`EXP_MODES` table in `BattleSim2` to an empty gate — Gen 2 returns to GB
chrome and pays no exp, with no wire change to undo.
