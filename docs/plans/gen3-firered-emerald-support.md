# Plan — Gen 3 (FireRed / LeafGreen / Emerald) support

| Field | Value |
| --- | --- |
| Date | 2026-09-30 |
| Source | Owner request 2026-09-30 ("Gen1Recomp announced FireRed + Emerald; every functionality and mechanic must work on them; e2e with screenshots") + owner grill (two passes, same day) |
| Config | `AGENTS_CONFIG.yml` (quality preset v3: builder/reviewer opus, test_author sonnet, test_runner haiku; host claude_code) |
| Flags | none |
| Gates | Grilled by the owner (7 answers, §8); plan approval pending |
| Branch | `feature/firered-and-emerald-support` |
| Base SHA | `ea822a5` |

## 1. Objective & success criteria

Every shipped `rby_mmo` surface works on **Gen 3** boots — FireRed, LeafGreen (engine
`game3`, layout `frlg`) and Emerald (layout `rse`) — as a first-class peer of Gen 1 and
Gen 2, exactly as the Gen 2 port made Gold a peer of Red (`docs/plans/gen2-compatibility.md`).

**Done means all of:**

1. `manifest.json` claims `"games": ["gen1", "gen2", "gen3"]`, and `modkit gen3check` reports
   no errors (warnings justified in §8).
2. Headless: `T.sdk.loadMod(..., { generation = 3, data = T.sdk.gen3Data() })` loads clean as
   FireRed **and** (with `GameVersion.set("emerald")`) as Emerald, and asserts the real Gen 3
   surfaces are installed (not only "no errors").
3. **Gen 3 hub** (`--generation 3`, and the in-game host on a Gen 3 boot) admits FireRed,
   LeafGreen and Emerald clients together and refuses Gen 1 / Gen 2 clients (and vice versa),
   under PROTOCOL 30. Chat, parties, friends, rank, trade and battles work **across** the three
   versions; overworld presence is region-scoped (Kanto `FR_*` maps vs Hoenn `EM_*` maps never
   mix).
4. Presence: remote players walk as **real Gen 3 overworld objects** (engine OW sprites, walk
   animation, correct layering), with nameplates, chat bubbles, toasts, party-on-map.
5. Every MMO screen (main menu, players, friends, chat/log/compose, profile/trainer card, rank,
   servers, host/join/code/QR, party, character pick, interact, trade, request prompts) renders
   natively on the 240×160 Gen 3 canvas with the cart's own font and window frames, and is
   reachable from a MMO row in the Gen 3 START menu.
6. **Battles** — mediated 1v1 PvP, co-op 2v2 (wild, NPC trainer, party-vs-party), solo — run under a
   new **full Gen 3 intermediator**: `src/BattleSim3` (Lua) + `server/lib/battle3` (Node) with
   abilities, held items, weather, natures/IV/EV-derived stats, Gen 3 damage/crit/type-chart
   order, all `EFFECT_*` move effects, doubles targeting/spread damage. Twin parity proven by
   shared vector + turn fixtures.
7. Battle screens: the widescreen arena (Gen 3 pics, backgrounds, trainer sprites) by default,
   and CLASSIC BATTLE UI draws a GBA-native (FireRed/Emerald-style) 240×160 battle layout.
8. Trade over the hub uses `Protocol.packMon3/unpackMon3` and applies received mons into the
   Gen 3 party/PC, dex, held item and mail, with trade evolution.
9. EXP, level-up, move learning, evolution after MMO battles use the Gen 3 engine rules.
10. Gen 1 and Gen 2 behaviour unchanged (headless suite + server tests + existing e2e green,
   modulo the known-red baseline in memory `main-is-red-in-two-known-places`).
11. **Live e2e with screenshots** on FireRed and Emerald (two driven LÖVE instances each),
    plus a Node-hub Gen 3 run mixing FireRed and Emerald clients; every leg captures PNGs into
    one local folder with an `index.html` contact sheet, and a curated set is cropped into
    `docs/screenshots/gen3/` (excluded from the packed archive by name).

## 2. Context & constraints (grounded, Phase 1)

Full research: scratchpad `research-{web,platform,battle,mod}.md` (2026-09-30). Engine
`~/Projects/alamops/gen1recomp` @ `fdea09dc` (= upstream `dev`).

### Engine facts
- `GameVersion`: firered/leafgreen `generation=3, engine="game3", layout="frlg"`; emerald
  `layout="rse"` (`src/core/GameVersion.lua:115-162`). Manifest token `"gen3"` covers all three
  (`src/mods/ModTargets.lua:44-58`).
- `mod.game` is the raw `Game3` (`generation=3`, `phase` boot|field|quest_log|arena, `session`
  live, `save` snapshot, **no `stack`, no `overworld`**) (`src/core/Game3.lua:40-52`,
  `Loader.lua:1717`). `mod.generation == 3`. Live state: `require("src.core.game3.runtime").getSession()`.
- `Gen3Compat` facades apply to **FRLG only** (`Gen3Compat.lua:94-100`); on Emerald every Gen 1
  module name (`src.core.Game`, `src.battle.BattleState`, …) logs a boot error and returns the
  dead Gen 1 module. ⇒ **the mod must reach Gen 3 through `src.core.game3.*` / `src.ui.game3.*`
  directly** (it declares `engine_internals`), lazily and only when `generation == 3`.
- Cross-generation require denial: a mod requiring `src.*.gen2.*` on a Gen 3 boot (or
  `src.*.game3.*` on Gen 1/2) **throws** (`Loader.lua:126-147, 268-275`). Unguarded today:
  `src/Chars.lua:165` (`src.world.gen2.Palettes`), `src/Gen.lua:450` (`src.core.gen2.Unown`).
- Registries gated on Gen 3 (writes dropped with a warning): `screens`, `sprites`,
  `battle_sprite_scales`, `link_fields`, `render_pipelines`, … (`Schemas.lua:676-697`).
- Events fired on Gen 3: `game.ready`, `save.loaded` (payload = raw session; after
  `map.entered` on continue), `save.created`, `save.writing`, `map.entered/exited/reloaded`,
  `player.warped`, `world.stepped`, `world.interacted`, `world.npc_spawned`, `battle.*`,
  `pokemon.caught/evolved/level_up/move_learned`, `flag.changed`. **Not fired:**
  `screen.pushed/popped`, `movement.speed`, `player.sprite`, `render.zones`,
  `ui.title_menu.items`, `ui.naming.grid`, `link.*`, `trade.completed`, `pokemon.received`.
- Hooks fired: `input.step (next, game, dt)` every phase; `input.key`; `render.hud (next, game,
  viewport)` (viewport lacks dpiX/dpiY; fires on title too); `ui.start_menu.items (next, game,
  items)` — rows `{ id, label, onSelect(game, session) }`, anchor on `id == "save"` (labels are ROM
  text); `encounter.roll` / `encounter.species` (`src/core/game3/encounters.lua:476-492`);
  `trainer.party`; `script.command` (every VM opcode incl. `trainerbattle`/`dotrainerbattle`,
  `scripting/ops_a.lua:2276-2281`); `world.talk (next, game, eo)`; `warp.destination`;
  battle/catch/exp hooks.
- UI: modal stack `src/ui/game3/stack.lua` — `Stack.push(id, tbl, {hideBelow, drawUnder,
  fullscreen})`, `pop(id)`, `top()`, `has(id)`, `busy()`. Layer `draw()` is called with no args
  into the **240×160** UI canvas; top layer gets `handleInput(input)` / `update(dt)`; the field is
  frozen while any layer is up; nothing on the stack draws during `phase == "boot"`.
  Toolkit: `src/ui/game3/window.lua` (`template`, `stdFrame`, `printPx`, `cursorPx`,
  `menuRowPx`), `frlg_font.lua` / `font.lua` (`Font.active()`; normal pitch 15, small font
  8px fixed advance, pitch 14), `message.lua`, `choice.lua`, `naming.lua`
  (`naming.open{title,maxLen,onDone}`), `list_menu.lua`.
- Save: `session.{name, gender(0/1), trainerId, secretId, money, coins, party, bag (pockets,
  numeric ids), dex{seen,owned,caught}, storage (14×30), flags/vars (live: Space.store),
  playtime, map/x/y/facing, modData}`; badges are flags (FRLG 0x820+, Emerald 0x867+; count
  via `scripting/flags.countBadges`). `mod.save` persists via `session.modData`.
- Maps: string ids `FR_<PRET>` (FireRed + LeafGreen) and `EM_<PRET>` (Emerald) — region-disjoint
  by prefix, so hub map scoping partitions presence for free. Display names via map section
  (`map_sections_extract.getInfo(secId,...)`, used by `map_name_popup.lua`).
- Objects: `src/core/game3/objects.lua` — `Objects.spawnFromDefs(defs, mapDef, mapId)`,
  `_byId/_order`, `startTrack`, `find`, `removeObject`; wiped on every `loadMap`. OW gfx ids:
  `Constants.of(version):id("event_objects", "OBJ_EVENT_GFX_*")`; FRLG `RED_NORMAL=0`,
  `GREEN_NORMAL=7`, `RS_BRENDAN=14`, `RS_MAY=15`; Emerald `BRENDAN_NORMAL=0`, `MAY_NORMAL=89`,
  `RED=230`, `LEAF=231`; cross-version `link/family.lua:linkPlayerGfx(viewer, partner, gender)`.
- Mon model: plain tables (`party.lua:223-257`, `save_mon.lua`): numeric internal `species`
  (1-411), numeric `moves` + `pp/maxPp`, `ivs/evs {hp,atk,def,spe,spa,spd}` (0-31 / 0-255),
  `personality`, `nature`, numeric `ability`, `gender`, `heldItem`, string `status`. Stats
  `Pokemon.calcStats`. Pics `Pokemon.frontPic/backPic(sp, form, shiny, personality)` →
  `{image,w=64,h=64}`, icons 32×32 ×2 frames. Moves `Moves.get(id)` (power, type, accuracy %,
  pp, effect, secondaryChance, target, priority, flags). Items `ItemsData.info`.
- Battle engine: `src/core/game3/battle/` (`damage.lua`, `rules.lua`, `types.lua` ordered
  chart, `effects/*` ~100 handlers over `EFFECT_*` 0-213, `abilities.lua`, `held_items.lua`,
  weather, doubles). Lua-only and ROM-pack-dependent ⇒ **port, don't call** (Node twin must
  match). Headless-runnable with injected rng for dev-machine cross-checks (engine tests do it).
- Trade: `Protocol.packMon3/packParty3/unpackMon3(data, packed, {strict})`
  (`src/link/Protocol.lua:571-867`); apply via `scripting/natives_trade.lua` (`tradeMons`,
  `tryTradeEvolution`) + `EvolutionScene`.
- EXP/learn/evolve: `battle/experience.lua` (`apply`, `gainFor`), `learn_move.lua`
  (`LearnMove.begin{mon,moveId,pushMsg,askYesNo,askForget,onDone}`), `evolution.lua` +
  `src/ui/game3/evolution_scene.lua`.
- Boot in drivers: `game:_handleBootAction({action="new_game", name=...})` while
  `phase=="boot"`; FireRed starts in `FR_PLAYERS_HOUSE_2F`, Emerald in `EM_INSIDE_OF_TRUCK`.

### Mod facts
- `Gen.generation()` **never returns 3** (`src/Gen.lua:40-57`); ~150 binary `== 2 → Gold, else
  Gen 1` branches; wire/hub clamp 3→1 (`Wire.lua:527-529`, `relay.js:414-417,1529-1530`,
  `config.js:446-463`) — a Gen 3 client is *admitted to a Gen 1 hub* today. Full site list:
  scratchpad `research-mod.md` §2 (every file:line). `PROTOCOL = 29` both twins.
- All screens go through `mod.content.screens` + `mod.ui.push` (`src/Ui.lua`, 111 push sites,
  widgets `TextBox/Menu/ListMenu/NamingScreen/Font/Theme`); 44 `game.stack` reads across
  Sessions, Coop, EvolveFx, Overlay, Gen, CoopBattle, Ui, MediatedBattle, Battlefield, Client.
- Existing Gold bugs found on the way (swept in, §9): `MediatedBattle.lua:852` sheetMoves drops
  the generation; `CoopBattle.lua:2425,2494,9741,10111` always load Gen 1 `BattleSim/Effects`;
  `Coop.lua:2565` writes `save.money` (Gold keeps `save.player.money`); `.modkitignore` lists no
  Gen 2 driver/suite.

### Spikes (measured 2026-09-30, engine fdea09dc, LÖVE 11.5, real FireRed Rev1 + Emerald caches)
- **S1 headless load** — mod copy claiming `gen3`: `state=loaded` as FireRed and as Emerald;
  only errors are the three gated registries (`sprites`, `battle_sprite_scales`, `screens`).
- **S2 avatar injection** — driver builds an eo via `Objects.spawnFromDefs({{localId=0x1001,
  x,y,graphicsId=GREEN_NORMAL(7)|MAY_NORMAL(89),movementType=0}})`, inserts into
  `Objects._byId/_order`, `passable=true`; `startTrack` two steps → drawn by the engine with
  **walk animation** on FireRed (`FR_PLAYERS_HOUSE_2F`) and Emerald (`EM_INSIDE_OF_TRUCK`),
  ends at the expected cell, `track done` fires. **Verdict: yes.**
- **S3 mod layer** — `Stack.push("spike", {draw, handleInput}, {hideBelow=false})`: frame via
  `Window.template/stdFrame`, text via `Window.printPx` in the cart's font; A/Down/B delivered;
  B pops; `Stack.busy()` false after. **Verdict: yes** (both games).
- **S4 start menu** — `StartMenu.ENTRIES` ids on both: `bag trainer save option mods exit`
  (no party/dex before they're obtained); START opens layer `start`.
- Caches imported: `~/Library/Application Support/LOVE/rby-mmo-g3-import-{fr,em}/{firered,emerald}/`
  (≈146 MB / 241 MB). ROMs: `.env` `FIRE_RED_ROM_PATH` (FireRed Rev1), `EMERALD_ROM_PATH`.

## 3. Approach & key decisions

1. **One Gen 3 hub generation (`3`) for FireRed + LeafGreen + Emerald** (owner). Hello carries
   `generation=3` plus `version` (`firered|leafgreen|emerald`) for display/sprite mapping.
   Region scoping of presence falls out of `FR_`/`EM_` map ids; nothing region-aware in the hub.
   PROTOCOL **30** (one bump for the whole branch; check the fleet first — collisions are
   routine).
2. **`Gen.generation()` → 1|2|3 + `Gen.family()`**; every binary branch becomes a 3-way
   decision. New Gen 3 code lives in **new modules** so edits to the giant files stay thin
   dispatch: `src/Gen3.lua` (engine adapters), `src/Gen3Ui.lua` (UI toolkit), `src/Sheet3.lua`
   (battle sheets), `src/Trade3.lua`, `src/Exp3.lua`, `src/BattleSim3/*`,
   `server/lib/battle3/*`. Reason: file-disjoint parallel waves + reviewable diffs.
3. **Avatars = injected real event objects** (owner; spike S2), localIds `0x1000+n`,
   `passable=true`, re-injected on `map.entered`/`map.reloaded`, driven with `Objects.startTrack`
   step tracks (mirrors how Gen 1/2 drive `scriptMove`). Plus `docs/upstream/gen3-spawn-npc.md`
   (Lane B proposal: public `spawnNpc` on game3 WorldAPI) — the reach-around is documented, not
   hidden. Own-look wearing on Gen 3 wraps `OwSprites.playerGraphicsId` behind the same flag
   (no `player.sprite` hook on Gen 3), same upstream note.
4. **Screens = mod-owned registry + Gen 3 stack layers** (spike S3). `Gen3Ui` exposes the same
   surface `Ui.lua` already uses from `mod.ui` (`push`, `TextBox.new`, `Menu.new`,
   `ListMenu.new`, `NamingScreen.new`, `Font`, `Theme`, `insertBefore`) implemented natively on
   `src.ui.game3.*` at 240×160. `Ui.lua` keeps one screen table and registers every screen in
   the engine registry (Gen 1/2) **and** in `Gen3Ui`'s local registry (Gen 3). Custom-drawn
   screens (trainer card, rank, host info, QR) get Gen 3 layouts. Driver contract (§5 C2).
5. **Encounter diversion on Gen 3 via public hooks**: wild → `encounter.roll` (return nil to
   cancel the engine fight, start the mod's co-op/solo fight with the rolled species/level);
   trainers → `script.command` on `trainerbattle`/`dotrainerbattle` (investigate VM wait/resume;
   if no public way to suspend the VM exists, fall back to letting the engine fight run and say
   so in §8 + upstream note — no silent skip).
6. **Battle intermediator = full Gen 3 port** (owner): fork `BattleSim2` → `BattleSim3`, port
   from `src/core/game3/battle/*` (damage, crit, accuracy, ordered type chart, status, 214
   effects, abilities, held items, weather, residuals, doubles). Hub holds no ROM tables: the
   client's sheet carries everything (§5 C4). Node twin mirrors the Lua line-for-line
   (no codegen, repo rule). Parity: vectors + turn fixtures run by both.
7. **Battle look** (owner): widescreen arena draws on Gen 3 via `render.hud` (window space,
   like Gold's `drawsWidescreen`) while a fullscreen input-owning stack layer freezes the
   field; CLASSIC BATTLE UI on Gen 3 draws a GBA-native layout into the 240×160 canvas from
   the cart's own battle chrome (`src/ui/game3/battle_chrome.lua`, `BattleChrome.*`).
8. **Trade** = hub `SessionNet` path (unchanged transport) + `Trade3` codec/apply over
   `packMon3/unpackMon3` and the engine's trade natives (mail, dex, trade evolution).
9. Rejected: relaying the engine's lockstep Gen 3 link battle (client-trusted, no co-op/NPC —
   breaks decision #2 in CLAUDE.md); drawing avatars in `render.hud` (no depth);
   Union Room VirtualObjects (no walk animation, cleared by union-room code).

## 4. Work breakdown — implementation tasks

File ownership is disjoint **within** a wave. "Owns" = the only files the task may edit.
Every brief carries the completeness clause (no TODO/stub for in-scope work; report
out-of-boundary remainder).

### Wave 1 — Foundation (1 agent)

**T1 · Generation core + Gen 3 adapters**
- Owns: `src/Gen.lua`, `src/Gen3.lua` (new), `src/Config.lua`, `src/World.lua`,
  `manifest.json`, `main.lua`.
- Goal: `Gen.generation` returns 3 (Handshake/Fingerprint/`mod.generation`/`game.generation`),
  `Gen.family(game)` (`gen1|gs|crystal|frlg|rse`), `Gen.version(game)`; every `Gen.lua` export
  gets a Gen 3 arm (money, dexCounts, badgeCount, freeRoam = `phase=="field"` and stack empty,
  startMenu reopen helper, nickname via `src.ui.game3.naming`, recordCatch, sprite catalog /
  default sprite (OW gfx names), sfx/battle music/victory/restore via game3 audio). Guard the
  gen2-only requires (`Gen.lua:450`). `Gen3.lua` = lazy, generation-3-only adapter API (C1).
  `Config`: `defaultSpriteFor(3)`, `ownCharAllowed`/`gensAllow` stop defaulting 3→1, NIRE
  `gens={1}` stays, solo-refusal vocab for Gen 3 battle types, any Gen 3 constants other waves
  need (declare them now: Config is frozen for other agents in wave 2 except T2's PROTOCOL line).
  `manifest.json` games `gen3`.
- Acceptance: headless load gen 1/2/3 (FR + EM) clean; `Gen.generation()==3` on a Gen 3 stub;
  `Gen3` functions unit-exercised against `T.sdk.gen3Data()` + stubs.

### Wave 2 — parallel (after T1)

**T2 · Hub generation lock + protocol + server ops**
- Owns: `src/Wire.lua` (hello/generation/presence/profile — *not* the battle sheet),
  `src/Hub.lua` (generation lock, sprite fallback — *not* sim selection), `src/HostServer.lua`,
  `src/Servers.lua`, `src/Config.lua` (PROTOCOL line only), `server/lib/{relay,sanitize,config,cli,server}.js`
  (non-battle parts), `server/hub.js`, `server/bin/*`, `server/Dockerfile`, `server/compose.yml`,
  `server/README.md`, `scripts/run-server.sh`, `scripts/upgrade-server.sh`,
  `server/{config,cli,server,hub,twin_parity,hub_protocol_parity}.test.js`,
  `tests/fixtures/hub_protocol_parity.json`, `tests/drivers/hub_protocol_parity.lua`.
- Goal: generation ∈ {1,2,3} everywhere (clamps removed, 3 refused on 1/2 hubs and vice
  versa, `--generation 3`, `RBY_MMO_GENERATION=3`, labels "3 (Gen 3 / FRLG+E)"), hello
  `version`, `defaultSpriteFor` twins, PROTOCOL 30, deploy scripts accept 3, parity fixture gets
  generation cases (admit, refuse 1↔3, 2↔3).
- Acceptance: `node server/*.test.js` green; Lua parity driver green; socket-level refusal test.

**T3 · Gen 3 UI toolkit + screens + client wiring**
- Owns: `src/Gen3Ui.lua` (new), `src/Ui.lua`, `src/Client.lua`, `src/Toast.lua`,
  `src/Chat.lua`, `src/Friends.lua`, `src/Rank.lua`, `src/Store.lua`, `src/Pairing.lua`,
  `src/Qr.lua`, `src/Roster.lua`, `src/Transport.lua`.
- Goal: `Gen3Ui` (C2) + every Ui.lua screen reachable and correct on Gen 3; START menu MMO row
  (anchored before `save`), closes the start layer and pushes MAIN; `reopenStartMenu` on Gen 3;
  hello sends generation 3 + version; profile (badges/dex/money/id) from `Gen`/`Gen3`;
  `narrateBattle/narrateCatch` read Gen 3 payloads; text entry through Gen 3 naming (+ digits for
  address/code entry: a mod-drawn keypad layer if the engine grid can't do digits); Gen 3-safe
  `input.step` pump and `render.hud` registration; no `game.stack` access on Gen 3.
  (Encounter diverts in Client.lua are **T11's** — leave the screen.pushed divert as is.)
- Acceptance: headless screen tests on a Gen 3 stub stack; live boot shows MMO row → MAIN.

**T4 · Presence, overlay, places, characters**
- Owns: `src/Avatars.lua`, `src/Overlay.lua`, `src/Places.lua`, `src/Chars.lua`, `src/Cast.lua`,
  `src/Party.lua`, `docs/upstream/gen3-spawn-npc.md` (new).
- Goal: avatars as injected event objects (C3), walk/turn/fast pace, busy/party flags, removal
  on leave/map change; nameplates + chat bubbles with Gen 3 camera math (field_view: camX/camY,
  bottom-anchored 16×32 sprites) inside the 240×160 game rect; party-on-map for Gen 3 (region map
  section names; Kanto/Hoenn); `Places.name` via map sections; `Chars` Gen 3 wearable catalog
  (player-trainer OW gfx per version + cross-version mapping), own look via
  `OwSprites.playerGraphicsId` wrap; `Chars.lua:165` gen2 require guarded; NIRE stays Gen 1.
- Acceptance: headless avatar tests against an Objects stub; live: two FR instances see each
  other walk.

**T5 · BattleSim3 (Lua intermediator)**
- Owns: `src/BattleSim3/*` (new), `tests/battle_sim3_vectors.lua`, `tests/battle_sim3_turn.lua`,
  `tests/fixtures/battle_sim3_vectors.json`, `tests/fixtures/battle3_turn_parity.json`,
  `docs/plans/gen3-battle-sheet.md` (new — the C4 sheet + C5 event spec, written first).
- Goal: full Gen 3 port (decision 6) with the same module shape/API as `BattleSim2`
  (`init`, `Rng`, `Damage`, `Crit`, `Accuracy`, `Status`, `Effects`, `Turn`, `events`) plus
  `Abilities`, `Items`, `Weather`/`Field`, `Types`. Singles + doubles (co-op 2v2 / party
  battles), catch formula for wild co-op, run/escape rules. Deterministic under the shared LCG.
- Acceptance: vectors (synthetic numbers, no ROM values) + turn fixtures pass; cross-checked on
  this machine against the engine's headless Gen 3 battle for a sample of damage rolls
  (evidence in the task report, nothing ROM-derived committed).

**T6 · Gen 3 trade**
- Owns: `src/Sessions.lua`, `src/Trade3.lua` (new), `src/SessionNet.lua`, `tests/trade3.lua` (new).
- Goal: trade offer/pick/confirm/apply on Gen 3 via `packMon3/unpackMon3` (strict), apply into
  party (or PC when full), dex seen/caught, held item, mail, trade evolution (engine
  `tryTradeEvolution` + `EvolutionScene`), Gen 3 fight-on-screen sniff (no `game.stack`);
  cross-version FR↔EM trades (species ids shared; Deoxys form by version).
- Acceptance: headless trade3 suite (loopback pair) green; Gen 1/Gen 2 trade tests unchanged.

### Wave 3 — parallel (after wave 2)

**T7 · Node battle3 twin + sheet sanitisers + sim selection**
- Owns: `server/lib/battle3/*` (new), `server/battle3_{vectors,turn}.test.js` (new),
  `src/Wire.lua` (battle sheet / move / ruleset Gen 3 dialect), `server/lib/sanitize.js` (same),
  `src/Hub.lua` + `server/lib/relay.js` (`battleSimFor` / sim selection, bag effect tables for 3),
  `server/twin_parity.test.js`, `tests/hub_battle.lua`, `server/hub_battle.test.js`.
- Goal: JS mirror of `BattleSim3`; both fixtures pass in Node; hubs pick sim by generation 3;
  sheet dialect per C4 (IVs 0-31, EVs 0-255, ability, held item + hold effect/param, gender,
  friendship, weight, nature-free final stats, move priority/target/flags/accuracy %).

**T8 · Mediated battle, EXP, learn move, evolution on Gen 3**
- Owns: `src/MediatedBattle.lua`, `src/Sheet3.lua` (new), `src/Exp3.lua` (new),
  `src/LearnMove.lua`, `src/EvolveFx.lua`, `tests/mediated_battle_client.lua`.
- Goal: Gen 3 arm end to end — sheets from `session.party` via `Sheet3`, bag upload from
  `session.bag` pockets (numeric ids), badge boosts off (link rules), item use, catch/grant into
  party/PC + dex + nickname prompt (Gen 3 naming), post-battle EXP/level-up/move-learn/evolution
  via `Exp3` on engine rules, music/SFX; existing Gold bug at `:852` fixed.

**T9 · Arena + classic GBA battle UI + VFX**
- Owns: `src/Battlefield.lua`, `src/ClassicBattle.lua`, `src/Vfx.lua`,
  `assets/battle/**` (only if an original asset is needed),
  `tests/drivers/battlefield_shot.lua`, `tests/drivers/classic_battle_shot.lua`.
- Goal: theatre gate includes Gen 3; Gen 3 front/back pics, 32×32 icons, trainer pics/OW walk
  strips, arena background composition for Gen 3 maps (or the drop-in custom arena PNGs),
  window-space draw via `render.hud` path; ClassicBattle GBA-native 240×160 layout (HP boxes,
  message box, FIGHT/BAG/POKéMON/RUN, move menu with type/PP) from `battle_chrome`.

**T10 · E2E infrastructure for Gen 3**
- Owns: `tests/drivers/mmo_util.lua`, `tools/env.sh`, `tests/drivers/run-mmo-e2e-gen3.sh` (new,
  `GEN3_GAME=firered|emerald`), `tests/drivers/mmo_host_gen3.lua`, `tests/drivers/mmo_join_gen3.lua`
  (new), `tests/drivers/run-trip-e2e-gen3.sh` + `mmo_trip_gen3.lua` (new: Node hub
  `--generation 3`, FR+FR+EM), `tests/drivers/mmo_mismatch_gen3.lua` (Gen 3 → Gen 1 hub refused),
  `tests/drivers/shots_index.py` (new: contact sheet generator).
- Goal: Gen 3 boot/new-game/teleport (Emerald: out of the truck to `EM_LITTLEROOT_TOWN`),
  stack-aware `top/selectLabel/closeToOverworld/openMmo`, party seeding (numeric species,
  Gen 3 mons), bag seeding, cache seeding per identity (copy imported cache — no re-import),
  screenshots named `g3-<game>-<role>-<leg>.png`; legs as far as waves 1-3 allow
  (presence, chat, menus, profile, friends, interact, trade, mediated 1v1, classic UI) — co-op
  and solo legs added in wave 5.

### Wave 4 — parallel (after wave 3)

**T11 · Co-op on Gen 3 + encounter diversion**
- Owns: `src/Coop.lua`, `src/CoopBattle.lua`, `src/CoopField.lua`, `src/CoopSim.lua`,
  `src/Client.lua` (divert wiring only), `tests/coop_mediated.lua`.
- Goal: Gen 3 co-op = mediated like Gen 2 (hub sim), doubles on BattleSim3; Gen 3 divert seams
  (decision 5) for wild + trainer, party-vs-party; rewards/money (`Gen.money`, fixes
  `Coop.lua:2565`), blackout, learn-move (no `MoveLearnMenu` on Gen 3), existing Gold bugs at
  `CoopBattle.lua:2425/2494/9741/10111`.

**T12 · Solo battles on Gen 3**
- Owns: `src/SoloBattle.lua`, `src/SoloBrain.lua`, `tests/solo_battle.lua`, `tests/solo_brain.lua`,
  `tests/drivers/solo_battle_e2e.lua`, `tests/drivers/run-solo-battle-e2e.sh`.
- Goal: SoloBattle kinds/turn sim → BattleSim3 on Gen 3; SoloBrain AI for Gen 3 (abilities,
  weather awareness at the level Gen 2's brain has); engine trainer party/AI flags for NPCs.

### Wave 5 — tests (see §5), Wave 6 — docs (T13)

**T13 · Docs, packaging, release**
- Owns: `README.md`, `CHANGELOG.md`, `mod.card`, `.modkitignore`, `server/package.json`,
  `docs/screenshots/gen3/*`, `docs/plans/README.md`, `CLAUDE.md` (layout + Gen 3 section).
- Goal: version 1.5.0 (four files per convention; never pin server/README clone), Gen 3 compat
  text, hub runbooks for `--generation 3`, `.modkitignore` lists every new test/driver/shot
  **and** the Gen 2 ones that were missing, curated screenshots cropped + optimized.

## 5. Work breakdown — test tasks, contracts, e2e

### Contracts every agent codes against

- **C1 `src/Gen3.lua`** (T1 defines, others consume; all functions return nil/0 safely off Gen 3):
  `session()`, `version()`, `family()`, `player()` → `{name, gender, trainerId, secretId}`,
  `position()` → `{mapId, x, y, facing, moving}`, `money.get/set`, `badgeCount()`,
  `dexCounts()`, `dexMark(species, seen, caught)`, `party()`, `partyCount()`,
  `bag.count/add/remove(itemId, n)`, `bag.list(pocket)`, `itemInfo(id)`, `itemName(id)`,
  `speciesName(id)`, `speciesInfo(id)`, `moveInfo(id)`, `moveName(id)`, `abilityName(id)`,
  `natureName(n)`, `frontPic/backPic(mon|species, opts)`, `icon(species)`, `trainerPic(id)`,
  `gfxId(name)`, `playerGfxName(gender, version)`, `viewerGfxFor(presenceSprite, partnerVersion, gender)`,
  `mapName(mapId)`, `region(mapId)` (`kanto|sevii|hoenn`), `stack()` (the game3 Stack module),
  `busy()`, `inField()`, `inBattle()`, `audio.*` wrappers. Lazy `require`s, guarded by
  generation 3.
- **C2 `src/Gen3Ui.lua`** (T3): `Gen3Ui.register(id, def)`, `push(game, id, opts)`,
  `pop(game, id?)`, `top()`, and widgets `TextBox.new(game, text, onDone, opts)`,
  `Menu.new(game, items, opts)`, `ListMenu.new(game, title, items, opts)`,
  `NamingScreen.new(game, opts)`, `Font`, `Theme` with the same option names Ui.lua uses.
  Layer ids `rby_mmo:<ScreenId>`. **Driver contract:** a menu layer exposes
  `layer.items[i].label` (plain text) and `layer.cursor` (1-based) so `mmo_util.selectLabel`
  can scroll and pick exactly as on Gen 1; text layers expose `layer.text`.
- **C3 presence on Gen 3** (T4 + T2): wire `sprite` is an OW gfx *name* from the sender's version
  (`OBJ_EVENT_GFX_*`), `version` rides on hello/profile; the viewer maps it through its own
  constants (fallback: `Family.linkPlayerGfx` by gender).
- **C4 Gen 3 sheet** and **C5 Gen 3 battle events** — `docs/plans/gen3-battle-sheet.md` (T5
  writes first; T7/T8/T9/T11/T12 consume). Additive: Gen 1/2 dialects untouched.

### Test tasks (Wave 5, parallel, file-disjoint)

| ID | Covers | Owns |
| --- | --- | --- |
| TT1 | Gen/Gen3/Config/manifest, UI toolkit, presence, trade, client wiring on Gen 3 stubs; dual → triple-gen load blocks (`{1,2,3}` + Emerald) | `tests/rby_mmo_test.lua` (new Gen 3 section appended; fix `:15554` meaning) |
| TT2 | BattleSim3 extra vectors (abilities/items/weather/doubles edge cases) | `tests/battle_sim3_*.lua`, fixtures |
| TT3 | Server: generation 3 admit/refuse at socket level, `--generation 3` cli/config, battle3 hub fight | `server/*.test.js` (new files only: `server/gen3.test.js`) |
| TT4 | Co-op/solo/mediated Gen 3 client tests | `tests/coop_mediated.lua`, `tests/solo_battle.lua`, `tests/mediated_battle_client.lua` |
| TT5 | **E2E legs** (below) | `tests/drivers/*gen3*` |

**E2E applies** (user-visible flows + process boundaries). Legs, each ending in a screenshot,
run on **FireRed and Emerald** (`run-mmo-e2e-gen3.sh GEN3_GAME=firered|emerald`, in-game host):
boot + MMO row → main menu → host/join by code → presence (see + walk) → nameplate/bubble →
chat + log → players/profile card/friends/rank → interact → trade (offer/pick/done, dex) →
mediated 1v1 (arena, move select, classic GBA UI variant, result, EXP/learn) → party invite /
members / party map → co-op wild 2v2 → co-op NPC trainer → solo battle. Plus
`run-trip-e2e-gen3.sh` (Node hub `--generation 3`, FR+FR+EM: cross-version chat/trade/battle,
region-scoped presence), and `mmo_mismatch_gen3.lua` (Gen 3 client refused by a Gen 1 hub,
message on screen). Existing Gen 1 (`run-mmo-e2e.sh`, `run-hub-e2e.sh`) and Gen 2
(`run-mmo-e2e-gen2.sh`) runs re-run for regressions.

**Run recipe** (engine view, never the shared symlink — memory `private-engine-view-for-tests`):
```sh
export PATH=/opt/homebrew/bin:$PATH MODKIT_LUAJIT=/opt/homebrew/bin/luajit
VIEW=<scratchpad>/engine   # symlink farm + mods/rby_mmo -> worktree (no .git)
cd $VIEW
luajit mods/rby_mmo/tests/rby_mmo_test.lua        # headless suite
luajit mods/rby_mmo/tests/battle_sim3_vectors.lua  # + every tests/*.lua
(cd mods/rby_mmo && for t in server/*.test.js; do node $t; done)
python3 tools/modkit.py validate mods/rby_mmo --base imported
python3 tools/modkit.py lint mods/rby_mmo && python3 tools/modkit.py gen3check mods/rby_mmo
SHOT_DIR=<scratchpad>/shots/fr GEN3_GAME=firered bash mods/rby_mmo/tests/drivers/run-mmo-e2e-gen3.sh
SHOT_DIR=<scratchpad>/shots/em GEN3_GAME=emerald bash mods/rby_mmo/tests/drivers/run-mmo-e2e-gen3.sh
SHOT_DIR=<scratchpad>/shots/trip bash mods/rby_mmo/tests/drivers/run-trip-e2e-gen3.sh
```
Prereqs: `.env` in the worktree (copied from the main checkout), ROM paths `FIRE_RED_ROM_PATH` /
`EMERALD_ROM_PATH`, imported caches (seeded per identity by copy), Mac unlocked (LÖVE stalls
when locked), e2e launched from the **main session** (subagent background children are reaped).

## 6. Execution waves

```
Wave 1:  T1                                   (foundation; everything reads Gen/Gen3/Config)
Wave 2:  T2 ∥ T3 ∥ T4 ∥ T5 ∥ T6               (T5 writes gen3-battle-sheet.md first)
Wave 3:  T7 ∥ T8 ∥ T9 ∥ T10                   (T7 mirrors T5; T8/T9 consume C4/C5)
Wave 4:  T11 ∥ T12
Wave 5:  TT1 ∥ TT2 ∥ TT3 ∥ TT4 ∥ TT5 (e2e legs) → review (Phase 5) → run all (Phase 7) → fix loop
Wave 6:  T13 (docs/screenshots, after green e2e)
```
Checkpoint commit per wave (`wave N: …`), headless suite + server tests run between waves;
live e2e smoke after wave 2 (presence/menus) and wave 3 (trade/1v1) from the main session.

## 7. Blast radius & risks

| Risk | Mitigation |
| --- | --- |
| Gen 1/2 regressions from 3-way refactors | New Gen 3 code in new modules; existing arms untouched; suite + Gen 1/2 e2e re-run |
| Engine internals churn (objects.lua, stack.lua, OwSprites are not public API) | All reach-arounds isolated in `Gen3.lua`/`Avatars.lua`/`Gen3Ui.lua` behind pcall + `docs/upstream/gen3-spawn-npc.md` Lane B proposal |
| BattleSim3 drift from cart rules | Port from engine sources (which cite pret lines); dev-machine cross-check vs engine headless battle; twin fixtures |
| BattleSim3 size (~6k lines × 2) | Largest single task; Lua first (wave 2), Node mirror (wave 3) against fixtures |
| PROTOCOL 30 breaks old clients/hubs | Existing exact-match refusal; hub runbooks updated; version bump |
| Trainer divert has no public VM-suspend seam | Investigate `script.command`; fallback recorded in §8 with an upstream note |
| Emerald's engine support is newest/beta | E2e on Emerald is first-class; engine bugs found are reported with repro, not patched here |
| LeafGreen claimed without a live run | Shares FireRed's layout/profile/cache format; headless coverage; stated in README/mod.card |
| Screenshots are ROM-derived pixels | Committed only under `docs/screenshots/gen3/` like existing shots, each listed in `.modkitignore` (never packed) |
| Rollback | Revert manifest `gen3` + PROTOCOL bump; Gen 1/2 paths unaffected |

## 8. Owner decisions (grill 2026-09-30) & assumptions

| # | Question | Answer (owner) |
| --- | --- | --- |
| 1 | Gen 3 hub admission | **One Gen 3 hub** for FR+LG+E; cross-version trade/battle/party/chat; presence region-scoped |
| 2 | Battle fidelity | **Full Gen 3 port** (abilities, items, weather, natures/IV/EV, all effects, doubles) |
| 3 | Avatars | **Real engine objects** (injected event objects) + upstream note |
| 4 | Games claim | **`gen3`** incl. LeafGreen (headless-covered, no live LG run) |
| 5 | Battle look | **Arena + GBA classic** |
| 6 | Screenshots | **Local folder + contact sheet, and commit curated `docs/screenshots/gen3/`** |
| 7 | Featured official Gen 3 hub | **No featured row** (one-line Config change later) |

Assumptions (verify in implementation, flip cheaply if wrong):
- A1 `encounter.roll` returning nil cancels the wild fight cleanly on both games (hook contract).
- A2 Trainer divert: `script.command` can intercept `trainerbattle` and resume the VM after the
  mod's fight; if not, decision 5 fallback (engine fight runs, documented) — **escalate to the
  owner before shipping the fallback**.
- A3 `render.hud` window-space drawing sits above the Gen 3 UI pass (arena over a fullscreen
  layer) — verify in wave 3 smoke.
- A4 Version bump to **1.5.0** (new supported generation = minor).
- A5 NIRE custom characters remain Gen 1 only (same as Gen 2 today).

## 9. Completeness ledger

| Candidate remainder | Disposition |
| --- | --- |
| Every binary gen branch in `research-mod.md` §2 (~150 sites) | In run — owned file-by-file by T1-T12 |
| Hub/CLI/config/Docker/deploy scripts accepting 3 | In run — T2 |
| `hub_protocol_parity.json` has no generation case | In run — T2 |
| Gold bug `MediatedBattle.lua:852` (sheetMoves no generation) | In run — T8 |
| Gold bug `CoopBattle.lua:2425/2494/9741/10111` Gen 1 Effects | In run — T11 |
| Gold bug `Coop.lua:2565` writes `save.money` | In run — T11 |
| `.modkitignore` missing Gen 2 drivers/suites | In run — T13 |
| `Chars.lua:165` / `Gen.lua:450` unguarded gen2 requires | In run — T4 / T1 |
| Encounter divert (screen.pushed not fired on Gen 3) | In run — T11 |
| Movement fast-pace reporting (`movement.speed` not fired) | In run — T4 (read `Player.running/biking`) |
| Party-on-map / Places on Gen 3 | In run — T4 |
| Classic battle UI on Gen 3 | In run — T9 (owner #5) |
| Solo battles on Gen 3 | In run — T12 |
| Docs/README/mod.card/CHANGELOG/version | In run — T13 |
| Upstream Lane B: public game3 `spawnNpc`, `player.sprite`, `screen.pushed` on Gen 3 | In run as a written proposal (`docs/upstream/gen3-spawn-npc.md`); the engine PR itself is **out of scope** (different repo) |
| Featured official Gen 3 server row | Out of scope — owner #7 (no hub deployed) |
| LeafGreen live e2e | Out of scope — no ROM on this machine (owner #4) |
| Gen 3 NIRE custom art | Out of scope — owner-consistent with Gen 2 (A5) |
