# Gen 3 battle sheet (C4), event vocabulary (C5) and the BattleSim3 contract

| Field | Value |
| --- | --- |
| Date | 2026-09-30 |
| Owner | T5 (`src/BattleSim3/*`, this document) |
| Parent plan | [`gen3-firered-emerald-support.md`](gen3-firered-emerald-support.md) §3 decision 6, §5 C4/C5 |
| Consumers | T7 (Node twin `server/lib/battle3`, Wire/sanitize Gen 3 dialect, hub sim selection), T8 (`Sheet3`, mediated client), T9 (arena / classic GBA UI), T11 (co-op), T12 (solo) |
| Reference | engine `~/Projects/alamops/gen1recomp/src/core/game3/battle/` (pret-cited), pret `pokefirered` / `pokeemerald` |

This is the contract every Gen 3 battle surface codes against. `src/BattleSim3/`
is its reference implementation; `server/lib/battle3/` (T7) mirrors it line for
line, and both are held to it by `tests/fixtures/battle_sim3_vectors.json` and
`tests/fixtures/battle3_turn_parity.json`.

**Legal posture.** The hub holds no ROM tables. Everything a formula needs rides
on the sheet or the ruleset, decoded by the *client* from its own cart. What the
sim does hard-code is code, not data: pret enum values (`TYPE_*`, `EFFECT_*`,
`ABILITY_*`, `HOLD_EFFECT_*`, `MOVE_TARGET_*`, a handful of `SPECIES_*` / `MOVE_*`
/ `ITEM_*` ids the battle code itself branches on) and the public in-battle bag
item amounts (Potion heals 20), exactly the policy `BattleSim2` already runs
under. The type chart, move rows, species stats, catch rates, item hold effects
and the Metronome pool all arrive per battle and are thrown away with it.

---------------------------------------------------------------------------------------------------

## 1. The sim API (identical shape to `src/BattleSim2`)

Loaded through `need` exactly like BattleSim2 (`need("BattleSim3/init")`,
`need("BattleSim3/Turn")`). Pure: no `love.*`, no engine module, no I/O, no mod
facade. A hub or client switches simulators by generation only.

```lua
local Sim  = need("BattleSim3/init")   -- { VERSION, GENERATION = 3, Rng, Types, Damage, Crit,
                                        --   Accuracy, Status, Abilities, Items, Field, Catch,
                                        --   Effects, Move, Events, Turn }
local Turn = Sim.Turn

local battle, reason = Turn.create(opts)   -- battle | nil, "why"
battle:submitChoice(playerId, choice)      -- true | false   (false is the whole error report)
battle:autoPick(playerId)                  -- true when a choice was filed (NPC / timeout pick)
battle:tick(nowSeconds)                    -- true when something happened
battle:drainEvents()                       -- { event, ... } since the last drain
battle:disconnect(playerId) / battle:reconnect(playerId)
battle:outcome()                           -- nil | { battle, outcome, winners, losers, reason, caught?, catcher?, payDay? }
battle:snapshot()                          -- tests / logs only (same shape as BattleSim2 + field digest)
```

The Node twin exposes `Turn.attempt(opts) -> { battle, reason }` as the Gen 2 twin does.

`Turn` also exports `MODES`, `VERSION`, `STATUS_FROM_WIRE` / `STATUS_TO_WIRE`,
`MONS_PER_PARTY` (6), `FIGHTERS_PER_SIDE` (3), `CHOICE_TIMEOUT`, `RECONNECT_GRACE`,
`RESOLVE_TIMEOUT`, `TIE_BREAK_ROLL` (128), `AIM_SEED_OFFSET` (1597334677) — same
values as BattleSim2.

### 1.1 `create(opts)`

| key | type | meaning |
| --- | --- | --- |
| `id` | string | battle id stamped on every event |
| `mode` | `"1v1"`, `"wild"`, `"coop_pvp"`, `"coop_npc"`, `"coop_wild"` | same five modes, same seat caps as BattleSim2 (`1v1`/`wild` 1 seat a side; `coop_wild` 2–3 humans on side a vs one wild seat on side b; others ≤ 3 per side) |
| `seed` | int | battle RNG seed (the aim stream is `seed + AIM_SEED_OFFSET`) |
| `typeTable` | int[] (flat triples) | **required for real fights** — see §3.1. Absent ⇒ every matchup neutral |
| `specialTypes` | int[] | optional override of the physical/special split (§3.2) |
| `movePool` | string[] or row[] | optional Metronome / Nature Power / Sketch pool (§3.3) |
| `terrain` | int 0..9 | pret `BATTLE_TERRAIN_*` for Nature Power / Secret Power / Camouflage; default **8** (building) |
| `weather` | `"RAIN"`, `"SUN"`, `"SAND"`, `"HAIL"` | optional overworld weather seeding a wild fight (announced at start, never expires) |
| `underwater` | bool | Dive Ball bonus (wild fight on an underwater map) |
| `choiceTimeout`, `reconnectGrace`, `resolveTimeout`, `now` | ints | same clock as BattleSim2 |
| `sides` | `{ a = { fighter... }, b = { fighter... } }` | fighters, below |

A **fighter** (one seat): `{ playerId, name, mons = { sheet... (≤ 6) }, bag = bag? }`.
`badges` is accepted and ignored (§6: badge boosts are off in mediated fights).

### 1.2 Choices (zero-based on the wire, like BattleSim2)

| action | fields | notes |
| --- | --- | --- |
| `fight` | `move` 0..3 (index into the *current* move list), `target` field slot (optional), `pass` party index 0..5 (optional) | `target` is read only for `MOVE_TARGET_SELECTED` moves and may name a living **ally** (Gen 3 lets a player aim at the partner) or any living foe, never the user. Absent ⇒ first living foe. Other target kinds ignore it. `pass` is the Baton Pass destination (the cart opens the party menu mid-move; a mediated fight asks up front): a living bench mon; absent or not legal ⇒ the first living bench mon in party order. |
| `switch` | `slot` 0..5 (party index) | refused while trapped (Mean Look / Block / Spider Web, Ingrain, a partial trap, Shadow Tag, Arena Trap, Magnet Pull); a forced replacement is always legal |
| `item` | `item` numeric item id (number or numeric string), `slot` party index (optional), `move` 0..3 (PP items), `dexCaught` bool (Repeat Ball: the thrower's dex already has the species caught) | ids per §4 |
| `run` | — | wild modes: refused when trapped (unless Smoke Ball / Run Away); see §6 |
| `cancel` | — | same as BattleSim2 |

Move-select legality (pret `battle_util.c:302` `TrySelectMove` / `CheckMoveLimitations`):
a slot is refused when it has 0 PP, is Disabled, is Tormented (same as last move),
is a status move under Taunt, is Imprisoned by a foe, or is not the Choice Band
move. When **every** slot is refused the choice is Struggle (any index accepted).
Encore does not refuse: whatever index is chosen, the Encored move is used.

---------------------------------------------------------------------------------------------------

## 2. C4 — the Gen 3 battle sheet (one POKeMON)

All numbers are integers. `Wire.battleMon` (T7) sanitises this dialect when
`generation == 3`; the sim itself coerces defensively (a missing optional is
read as the neutral value named below, never an error).

| field | type / range | required | meaning / who reads it |
| --- | --- | --- | --- |
| `generation` | 3 | yes | dialect tag |
| `species` | string ≤ 10 | yes | prose name (nickname when the mon has one); narration only |
| `speciesId` | id string | opt | registry / art id passed through to `send`/`switch`/`exp` events (T8 decides: the internal species number as a string) |
| `speciesNum` | int 1..411 | yes | pret internal `SPECIES_*`; the sim branches on 25 Pikachu (Light Ball), 83 Farfetch'd (Stick), 104/105 Cubone/Marowak (Thick Club), 113 Chansey (Lucky Punch), 132 Ditto (Metal Powder), 373 Clamperl (DeepSea items), 385 Castform (Forecast), 407/408 Latias/Latios (Soul Dew) |
| `slot` | 0..5 | opt | sender's party index (defaults to upload order) |
| `level` | 1..100 | yes | |
| `hp`, `maxHp` | 0..999 / 1..999 | yes | |
| `stats` | `{ atk, def, spe, spa, spd }` 1..999 | yes | **final** stats (nature, IVs, EVs already applied client-side by `Pokemon.calcStats`; Deoxys cross-version PvP must use its link stats) |
| `types` | `{ t1 }` or `{ t1, t2 }` 0..17 | yes | pret `TYPE_*` (MYSTERY = 9). A second type equal to the first is dropped |
| `ability` | 0..77 | yes | pret `ABILITY_*` id (0 = none); the sim maps ids to names itself (§5.3) |
| `abilityName` | string | opt | display name for `ability` events / sentences (fallback: the pret token with `_` → space) |
| `heldItem` | 0..376 | yes | pret `ITEM_*` id (0 = none). Mail = 121..132, Enigma Berry = 175 (the sim branches on these for Thief / Trick) |
| `holdEffect` | 0..66 | yes | `HOLD_EFFECT_*` of `heldItem`, from `ItemsData.info(id).holdEffect` |
| `holdEffectParam` | 0..255 | yes | `ItemsData.info(id).holdEffectParam` |
| `itemName` | string | opt | display name for `held` events (fallback `ITEM <n>`) |
| `gender` | `"M"`, `"F"`, `"U"` | yes | Attract / Cute Charm |
| `friendship` | 0..255 | yes | Return / Frustration |
| `weight` | 0..9999 (hectograms) | yes | Low Kick (`Pokemon.dexEntry(sp).weight`) |
| `nature` | 0..24 | yes | `personality % 25`; confusion-berry flavour dislike (§5.4) |
| `hiddenPower` | `{ type = 0..17, power = 30..70 }` | yes | IV-derived (engine `Damage.hiddenPower(mon)`); the only IV-derived value any formula reads |
| `beatUp` | `{ atk, def }` 1..255 | yes | the species' **base** Attack / Defense (Deoxys: link-stat row) — Beat Up reads the base stats of every party member and of the target |
| `status` | `"SLP"`, `"PSN"`, `"BRN"`, `"FRZ"`, `"PAR"`, `"TOX"` | opt | standing condition |
| `sleepTurns` | 0..7 | opt | remaining sleep counter when `status == "SLP"` (absent ⇒ rolled 2..5 on the first sleep check, like the engine) |
| `catchRate` | 0..255 | wild seat | species catch rate (the wild sheet only) |
| `ivs`, `evs`, `personality`, `otId` | passthrough | opt | never read by a formula; copied onto the `caught` sheet so the catcher can rebuild the exact mon |
| `moves` | 1..4 move rows (below) | yes | |

**Move row** (same row shape in `moves`, the `moves` event and the pool):

| field | type / range | meaning |
| --- | --- | --- |
| `id` | id string | token (`THUNDERBOLT`); the `anim` event carries it |
| `name` | string ≤ 16 | opt, narration (fallback: `id` with `_` → space) |
| `num` | 1..354 | pret `MOVE_*` number — the sim branches on it (Struggle 165, Curse 174, Snore 173, Sleep Talk 214, Heal Bell 215, Fly 19, Dig 91, Dive 291, Bounce 340, Sky Attack 143, Surf 57, Whirlpool 250, Doom Desire 353, Rage 99, Focus Punch 264, Protect 182, Detect 197, Endure 203, the sound-move and copy-forbidden lists, the partial-trap message set 20/35/83/128/250/328) |
| `power` | 0..255 | |
| `type` | 0..17 | |
| `accuracy` | 0..100 | **percent**; 0 = never misses |
| `pp`, `maxPp` | 0..64 | |
| `effect` | 0..213 | pret `EFFECT_*` (1:1 `battle_move_effects.h`) |
| `chance` | 0..100 | `secondaryEffectChance` |
| `target` | bitmask | `SELECTED 0, DEPENDS 1, USER_OR_SELECTED 2, RANDOM 4, BOTH 8, USER 16, FOES_AND_ALLY 32, OPPONENTS_FIELD 64` |
| `priority` | -7..7 | signed |
| `flags` | 0..63 | `CONTACT 1, PROTECT 2, MAGIC_COAT 4, SNATCH 8, MIRROR_MOVE 16, KINGS_ROCK 32` |

A party is up to six sheets; a **bag** is `{ { id = <item id>, count = 1..99, name = "POTION"? }, ... }`
(or `{ [id] = count }`), numeric ids restricted to §4. `name` (optional, the
client's display name) narrates "Ann used POTION!"; without it the sentence is
"Ann used an item!". The `item` event always carries the numeric id.

---------------------------------------------------------------------------------------------------

## 3. The ruleset

### 3.1 `typeTable` — the ordered chart

A flat list of integer triples `atk, def, mult` in **cart order** (pret
`gTypeEffectiveness`, engine `battle/types.lua` `Types.TABLE`), multipliers in
tenths (`0`, `5`, `10`, `20`), including the Foresight sentinel `-1, -1, 0` and
the two entries after it (Normal→Ghost, Fighting→Ghost). The client reads it
from `require("src.core.game3.battle.types").TABLE` and uploads it as-is.

`typeCalc(table, atkType, def1, def2, dmg, foresight)` walks the list **in order**
and applies each matching row as `dmg = floor(dmg * mult / 10)` (a non-immune
result of 0 becomes 1), row by row — `def1` then `def2` within a row, `def2`
only when it differs from `def1`. Reaching the sentinel with `foresight` set
(the defender was Foresighted / Odor Sleuthed) stops the walk, so the two ghost
immunities are skipped. The flags `{ super, notVery, immune }` follow pret
(`battle_script_commands.c:1274`). Order matters: a percent matrix applied in
defender order does **not** reproduce the cart's floors.

Cap for Wire / Config: **`BATTLE_TYPE_TABLE3_MAX = 150` triples (450 ints)**; the cart has 112.

### 3.2 Physical vs special

By type, pret `IS_TYPE_PHYSICAL`: types `0..8` physical, `9` (MYSTERY) deals no
damage, `10..17` special. `specialTypes` (optional int list) overrides the
special set for a data pack; when present, every other type except 9 is physical.

### 3.3 `movePool` — Metronome, Nature Power, Sketch

The pool is the host's decoded move table, used whenever the sim must resolve a
move no sheet on the field carries: Metronome (any move not in pret
`sMovesForbiddenToCopy`), Nature Power (the terrain's move), Sketch (the target's
last *printed* move may be a called one), Mirror Move / Mimic of a called move.

**Compact encoding.** Gen 3 has ~340 Metronome-eligible moves; as full row tables
that is ~4000 nodes, over `PAYLOAD_MAX_NODES` (4096) with the rest of a battle
start. Each pool entry is therefore **one string**:

```
"<num>:<effect>:<power>:<type>:<accuracy>:<pp>:<chance>:<target>:<priority>:<flags>:<id>"
e.g.  "85:6:95:13:100:15:10:0:0:18:THUNDERBOLT"      "68:89:1:1:100:20:0:1:-5:3:COUNTER"
```

`id` matches `^[%w_%-]+$` (≤ 40); the narrated name is `id` with `_` → space.
A row table (the move-row shape of §2) is also accepted. The sim ignores entries
that do not parse. **New cap: `Config.BATTLE_MOVE_POOL3_MAX = 360`** entries (one
node each; ~13 KB as JSON, well inside the 64 KiB line). Gen 1/2 keep
`BATTLE_METRONOME_POOL_MAX = 200` untouched. Without a pool, Metronome and
Nature Power say "But it failed!" and spend the turn.

---------------------------------------------------------------------------------------------------

## 4. Bag items (in-battle use)

Numeric pret item ids (shared by FireRed, LeafGreen and Emerald). Anything not
listed is refused by `Wire.battleBag` and answers "But it failed!" in the sim.
Amounts are the public in-battle amounts (hand-authored, as in BattleSim2).

| class | ids |
| --- | --- |
| ball | 1 Master, 2 Ultra, 3 Great, 4 Poké, 6 Net, 7 Dive, 8 Nest, 9 Repeat, 10 Timer, 11 Luxury, 12 Premier (5 Safari is refused: safari fights are not mediated) |
| heal (HP) | 13 Potion 20, 22 Super Potion 50, 21 Hyper Potion 200, 20 Max Potion full, 26 Fresh Water 50, 27 Soda Pop 60, 28 Lemonade 80, 29 Moomoo Milk 100, 30 EnergyPowder 50, 31 Energy Root 200, 44 Berry Juice 20, 139 Oran Berry 10, 142 Sitrus Berry 30 |
| heal + cure | 19 Full Restore (full HP, all status, confusion) |
| cure | 14 Antidote PSN/TOX, 15 Burn Heal, 16 Ice Heal, 17 Awakening, 18 Parlyz Heal, 23 Full Heal (all + confusion), 32 Heal Powder (all + confusion), 38 Lava Cookie (all + confusion), 133 Cheri PAR, 134 Chesto SLP, 135 Pecha PSN/TOX, 136 Rawst BRN, 137 Aspear FRZ, 140 Persim confusion, 141 Lum (all + confusion), 39 Blue Flute SLP, 40 Yellow Flute confusion, 41 Red Flute infatuation |
| revive (fainted only) | 24 Revive ½, 25 Max Revive full, 33 Revival Herb full |
| PP | 34 Ether +10 one move, 35 Max Ether full one move, 36 Elixir +10 all, 37 Max Elixir full all, 138 Leppa Berry +10 one move |
| battle stat | 73 Guard Spec. (Mist, 5 turns, user's side), 74 Dire Hit (Focus Energy), 75 X Attack, 76 X Defend, 77 X Speed, 78 X Accuracy, 79 X Special (Sp. Atk) — each **+1** stage (Gen 3), active mon only |
| escape (wild) | 80 Poké Doll, 81 Fluffy Tail |
| field | 350 Poké Flute (FRLG key item: wakes every sleeper, never consumed) |

Items are spent after the announce, win or fail (BattleSim2). Non-ball items run
with the switches, in battler order (§6); balls resolve in speed order after
every other bag action (BattleSim2's policy, §9.1). Poké Flute (350) and the
Blue / Yellow / Red Flutes (39–41) are never spent (`noConsume`; pret
`party_menu.c` `IsItemFlute`). Inside the sim `fighter.bag` is a map keyed by the **numeric**
id (`{ [13] = 2 }`); `create` accepts the list form or a map keyed by numbers or
numeric strings. A hub that proves / spends bags by string key converts with
`tostring` / `tonumber`, and its item-effect lookup is `Items.bagEffect(id)`
(BattleSim3's catalog, the Gen 3 counterpart of `BattleSim2/Effects.itemEffect`).

---------------------------------------------------------------------------------------------------

## 5. Formulas (what the vectors pin)

### 5.1 Damage — pret `CalculateBaseDamage` (`pokemon.c:2385`) + `Cmd_damagecalc` / `Cmd_typecalc` / `Cmd_adjustnormaldamage`

Stages `STAGE_RATIO[-6..6] = 10/40 .. 10/10 .. 40/10` (`pokemon.c:1442`),
`applyStage(stat, s) = floor(stat * num / den)`.

1. Variable power: Magnitude (roll 0..99 → 10/30/50/70/90/110/150), Return
   `floor(10*F/25)`, Frustration `floor(10*(255-F)/25)`, Eruption/Water Spout
   `max(1, floor(hp*power/maxHp))`, Flail/Reversal (`floor(hp*48/maxHp)` bands
   → 200/150/100/80/40/20), Low Kick (weight < 100/250/500/1000/2000 → 20/40/60/80/100, else 120),
   Hidden Power (sheet), Weather Ball (×2 and typed by weather), Rollout /
   Ice Ball (×2 per turn, ×2 after Defense Curl), Fury Cutter (×2 per hit, cap 5),
   Triple Kick (10/20/30), Present (roll 0..255 <102 → 40, <178 → 80, <204 → 120, else heal).
2. `dmgMultiplier`: Pursuit on a switching target ×2, Facade (BRN/PAR/PSN/TOX) ×2,
   Revenge (hurt this turn by that target) ×2, SmellingSalt (PAR, no sub) ×2,
   Gust/Twister on ON_AIR ×2, Earthquake/Magnitude on UNDERGROUND ×2, Surf/Whirlpool on UNDERWATER ×2,
   Stomp/Extrasensory (`FLINCH_MINIMIZE_HIT`) on a Minimized target ×2.
3. Fixed damage (after the type check for immunity only): Dragon Rage 40,
   SonicBoom 20, Seismic Toss/Night Shade = level, Super Fang `max(1, floor(hp/2))`,
   Endeavor `targetHp - userHp` (fails when ≤ 0), Psywave `floor(L*(10r+50)/100)` r = 0..10,
   Counter / Mirror Coat `2 × last physical / special damage taken`, Bide `2 × stored`.
4. Base: attack/defense chosen by the move type (§3.2); Huge Power / Pure Power ×2 Atk;
   type-boost hold effect `+param%` to Atk (physical type) or SpA; Choice Band ×1.5 Atk;
   Soul Dew ×1.5 SpA/SpD (Latias/Latios); DeepSeaTooth ×2 SpA / DeepSeaScale ×2 SpD
   (Clamperl); Light Ball ×2 SpA (Pikachu); Metal Powder ×2 Def (Ditto); Thick Club
   ×2 Atk (Cubone/Marowak); Thick Fat halves SpA vs Fire/Ice; Hustle ×1.5 Atk;
   Plus/Minus ×1.5 SpA with the other on the field; Guts ×1.5 Atk when statused;
   Marvel Scale ×1.5 Def when statused; Mud Sport halves Electric power, Water Sport
   halves Fire power; Overgrow/Blaze/Torrent/Swarm ×1.5 power at `hp ≤ floor(maxHp/3)`;
   Explosion/Selfdestruct halve Defense.
   `levelFactor = floor(2L/5) + 2`; physical: `d = floor(floor(applyStage(atk,s)*power*levelFactor / max(1,applyStage(def,s))) / 50)`;
   a critical hit ignores an attacker stage ≤ 0 and a defender stage ≥ 0; burn halves
   (not with Guts); Reflect/Light Screen halve, or `2*floor(d/3)` when the
   defending side has ≥ 2 standing (not on a crit); spread (`BOTH`) halves when
   the defending side has ≥ 2 standing; physical minimum 1; MYSTERY deals 0;
   special: Rain ×1.5 Water / ×0.5 Fire, Sun the reverse, SolarBeam halved in
   Rain/Sand/Hail, Flash Fire ×1.5 Fire. **`+2`**.
5. `× critMultiplier (2) × dmgMultiplier`; Charge ×2 Electric; Helping Hand `floor(×15/10)`.
6. STAB `floor(×15/10)` (not Struggle), then `typeCalc` (not Struggle). Levitate
   vs Ground and Wonder Guard (anything not strictly super effective) make the move miss.
7. Random: `floor(d * r / 100)`, r = 85..100, min 1 (skipped when d = 0).
8. False Swipe leaves 1 HP (not through a substitute); Endure / Focus Band (roll
   0..99 < param) hang on at 1.

### 5.2 Critical hits — `battle_script_commands.c:1170`

Stage = +2 Focus Energy / Dire Hit, +1 high-crit effect (43 HIGH_CRITICAL, 75
SKY_ATTACK, 200 BLAZE_KICK, 209 POISON_TAIL), +1 Scope Lens (hold effect 41),
+2 Lucky Punch (63) on Chansey, +2 Stick (66) on Farfetch'd; cap 4.
Chance 1 in `{16, 8, 4, 3, 2}`; crit when `roll(0, n-1) == 0`. Battle Armor and
Shell Armor skip the roll entirely. Fixed-damage moves never crit.

### 5.3 Accuracy — `battle_script_commands.c:1003`

Never-miss: accuracy 0, `ALWAYS_HIT` (17), `VITAL_THROW` (78), Thunder in rain,
Lock-On/Mind Reader against its target. Protect (flag 2) blocks first;
semi-invulnerable targets are missed unless the move reaches them (Gust/Twister/
Thunder/Sky Uppercut → ON_AIR, Earthquake/Magnitude → UNDERGROUND,
Surf/Whirlpool → UNDERWATER). Otherwise `buff = accStage - evaStage` (evasion
ignored when Foresighted) clamped −6..6, `ACCURACY_STAGE` =
33/100, 36/100, 43/100, 50/100, 60/100, 75/100, 1/1, 133/100, 166/100, 2/1,
233/100, 133/50, 3/1; Thunder in sun is 50%; `calc = floor(num*acc/den)`, then
Compound Eyes ×130/100, Sand Veil in sand ×80/100, Hustle on physical ×80/100,
BrightPowder / Lax Incense (hold effect 22) `×(100 − param)/100`. Hit when
`roll(1, 100) <= calc`. Volt/Water Absorb and Flash Fire swallow the move
**before** the check (pret `Cmd_attackcanceler`), so an absorbed move draws no
accuracy roll.

### 5.4 Status, residuals, abilities, items

Sleep 2..5 turns (`roll(0,3)+2`), Early Bird counts down twice; freeze thaws
`roll(0,4) == 0` (and on a Fire hit / THAW_HIT user); paralysis stops
`roll(0,3) == 0` and quarters Speed; confusion 2..5 turns, self-hit 50%
(`roll(0,1) == 0`) as a typeless 40-power physical hit on itself with its own
85..100 roll; infatuation 50%; burn and poison `max(1, floor(maxHp/8))`, toxic
`max(1, floor(maxHp/16)) × n` (n = 1..15, reset on switch); Leech Seed 1/8;
Nightmare / Curse 1/4; partial trap 1/16 for 3..6 turns (`roll(0,3)+3`, counting
the turn it lands); sand / hail 1/16 (Rock/Ground/Steel / Sand Veil and Ice immune,
Dig/Dive hidden immune); weather from moves lasts 5 turns, from abilities forever.

Confusion-berry flavour dislike: nature `n` raises stat `floor(n/5)` and lowers
stat `n % 5` in the order Atk, Def, Spe, SpA, SpD (equal ⇒ neutral); the berry
flavour of hold effect `10+f` maps f = 0 Spicy→Atk, 1 Dry→SpA, 2 Sweet→Spe,
3 Bitter→SpD, 4 Sour→Def. A nature that *lowers* that stat dislikes it (confuses).

Held items act at the cart's points (pret `ItemBattleEffects`): the status cures
(Cheri … Lum, Persim), White Herb and Mental Herb act at every move end
(`ITEMEFFECT_MOVE_END`, every battler) and on the post-action / `ENDTURN_ITEMS2`
passes; the HP berries (Oran, Sitrus), Leppa, Leftovers, the confusion berries,
the pinch stat berries, Lansat and Starf test `!moveTurn` and so act **only at the
end of the turn** (`ENDTURN_ITEMS1`) -- a Sitrus holder knocked under half eats it
after the turn's moves, not right after the blow.

Lum Berry (hold effect 9) says **one** sentence however much it cures (pret
`BattleScript_BerryCureChosenStatusRet`): "X's ITEM normalized its status!" when the
post-action / end-of-turn check (`ITEMEFFECT_NORMAL`) cures a status and confusion
together, otherwise "X's ITEM cured its WORD problem!" — always that one at move end
(`ITEMEFFECT_MOVE_END`), WORD being the last condition cured in pret's order
(poison, sleep, paralysis, burn, freeze, confusion).

Ability ids (pret `abilities.h`) 1 STENCH … 77 AIR_LOCK. Hold effects (pret
`hold_effects.h`) 1 RESTORE_HP … 66 STICK. Both tables are written out in
`src/BattleSim3/Abilities.lua` and `Items.lua`.

### 5.5 Catch — pret `Cmd_handleballthrow`

Ball multiplier ×10: Ultra 20, Great 15, Poké/Luxury/Premier 10, Net 30 vs
Water/Bug else 10, Dive 35 when `underwater` else 10, Nest `max(10, 40 − L)` when
L < 40 else 10, Repeat 30 with `dexCaught` else 10, Timer `min(40, 10 + turn)`
where `turn` counts completed turns (0 during the first turn, pret
`gBattleResults.battleTurnCounter`).
`odds = floor(floor(catchRate * mult / 10) * (3M − 2H) / (3M))`, ×2 SLP/FRZ,
`floor(×15/10)` PSN/TOX/BRN/PAR. Master Ball or odds > 254 catches. Otherwise
`b = floor(1048560 / isqrt(isqrt(floor(16711680 / odds))))` and up to four draws
`roll(0, 65535) < b` count shakes; four shakes catch. (odds 0 never shakes.)

---------------------------------------------------------------------------------------------------

## 6. Policies (BattleSim2's, kept unless Gen 3 differs — each one written down)

* **Seats.** Same seat model as BattleSim2: one active mon per seat, field slots
  `a` 0..2 / `b` 3..5, up to three seats a side. A fight is **doubles** whenever a
  side has more than one seat (co-op 2v2, coop_wild 2–3 humans vs one wild):
  spread moves, doubled screens, Helping Hand, Follow Me, Lightning Rod redirection,
  Pressure counting and the "moved last" checks apply. `BOTH` hits every standing
  foe; `FOES_AND_ALLY` hits every other standing battler; "partner" means the
  nearest living ally seat.
* **Turn order** (pret `SetActionsAndBattlersTurnOrder`, `battle_main.c:3532`): runs,
  then the switches and the bag items **together, in battler order** (a1, b1, a2, …;
  each switch preceded by any foe Pursuit aimed at it) -- a1's Potion comes before
  b1's switch -- then the balls (after every other bag action, fastest thrower first:
  BattleSim2's policy, §9.1), then moves by priority bracket then speed (Quick Claw
  puts its holder first in its bracket). **Speed ties** break on one `roll(0,255)`
  per tied group, `>= 128` reverses the group (BattleSim2's policy, priority
  brackets added).
* **End of turn** runs Gen 3's order (field timers, wish, weather; then per battler
  ingrain, abilities, `ENDTURN_ITEMS1` (the `!moveTurn` pass: HP / PP / confusion /
  pinch berries, Leftovers), leech seed … taunt, yawn, `ENDTURN_ITEMS2` (the
  `moveTurn` pass: status cures -- a Yawn sleep is cured by a Chesto in the same end
  of turn); then the fainted-actions step (Intimidate / Trace / held items (moveTurn)
  / Forecast, repeated until nothing acts), Future Sight, Perish Song) over the
  battlers re-sorted by this turn's move priority and speed with the same tie policy
  — not BattleSim2's field order. This is the cart's `ENDTURN_ORDER`. The same
  fainted-actions step runs after every action (`battle_util.c:1208`), with no cap
  on its passes (a 3v3 field's six Intimidates all resolve at once).
* **Future Sight / Doom Desire** lands from its user's *seat* (pret stores a
  battler position, `futureSightAttacker`). The damage was fixed at use from the
  user's stats and level; at landing the attacker (its accuracy stage, Compound
  Eyes, who hit whom) is the seat's current occupant, or — when the user fainted
  and the seat is still empty — the fainted user itself, and the hit still lands.
  The user's seat is empty either until the `replace` phase, which the sim runs
  after the end of turn, or for good when the bench is empty. The **target**
  seat follows the cart too: the cart sends replacements in *before* the Future
  Sight step (`HandleFaintedMonActions` precedes `HandleWishPerishSongOnTurnEnd`),
  so a hit due on a seat emptied this turn waits (turns 0) and lands on the
  newcomer right after the replace phase's switch-ins; a seat that will never be
  refilled drops it (pret skips an absent battler for good).
* **Focus Punch** "is tightening its focus" lines are said right after ordering,
  before any switch (pret `CheckFocusPunch_ClearVarsBeforeTurnStarts`).
* **Running.** 1v1 / coop_pvp: RUN is a concession (always allowed). coop_npc: the
  trainer refusal, no finish. wild / coop_wild: refused at submit while trapped
  (Mean Look, Ingrain, partial trap, Shadow Tag, Arena Trap, Magnet Pull) unless the
  runner holds a Smoke Ball or has Run Away; otherwise pret `TryRunFromBattle`
  against the wild mon: slower runner escapes when
  `(floor(spe*128/foeSpe) + 30*attempts) % 256 > roll(0,255)` (attempts counted per
  battle); a failed attempt is "Can't escape!" and the turn is spent. A successful
  escape ends the fight for everyone (reason `run`, as in BattleSim2).
* **Forced lock-in** fills the seat at turn open (no menu): recharge, the release
  turn of a two-turn move, Bide, Thrash/Petal Dance/Outrage, Uproar, Rollout/Ice
  Ball. A partial trap does **not** lock the victim in Gen 3 (it can still attack;
  it cannot switch or flee). Forced-only turns wait for the next `tick` exactly as
  in BattleSim2. A **recharge** turn chooses no move (pret leaves
  `gChosenMoveByBattler` `MOVE_NONE`): Rage ends, no Focus Punch line, and it sorts
  in priority bracket 0 (the cart reads the stale chosen slot — the recharge move
  or the move that called it — priority 0 on every cart).
* **Faint** asks the seat for a replacement in the `replace` phase (BattleSim2).
* **Timeout / NPC** auto-pick: BattleSim2's heuristic (bag cures/heals, super-effective
  damage, status/setup, SE bench switch) using Gen 3 effect ids, item ids and the
  ordered chart.
* **Link rules**: no badge boosts, no disobedience, no EXP and no Pay Day coins in
  1v1 / coop_pvp. `exp` events are facts (BattleSim2).
* **Pay Day** adds `level × 5` to its side's tally (pret `gPaydayMoney`, a u16 that
  saturates at 65535) and always says "Coins scattered everywhere!". Only a battle
  side a **wins by KO** in `wild` / `coop_wild` / `coop_npc` pays (pret runs
  `Cmd_givepaydaymoney` on `B_OUTCOME_WON` only): `outcome().payDay` is side a's
  total, absent when 0 or in a PvP mode. The Amulet Coin doubling
  (`moneyMultiplier`) and the wallet are the client's; `snapshot().payDay` shows
  both sides' tallies for tests / logs.
* **King's Rock** keeps the cart quirk: the flinch chance reads the hold-effect
  parameter of *battler 0* (field slot 0's active mon), pret
  `ItemBattleEffects(ITEMEFFECT_KINGSROCK_SHELLBELL, 0, …)`.
* **Struggle**: synthetic row (num 165, power 50, Normal, accuracy 100, EFFECT_RECOIL,
  contact | protect), typeless (no STAB, no chart), recoil `max(1, floor(dealt/4))`
  even through Rock Head.
* **Pursuit** on a switching seat: the foe seats are asked in reverse field order;
  each Pursuit aimed at the leaving seat strikes first, doubled, and counts as that
  seat's action for the turn. Like the cart's `BattleScript_PursuitDmgOnSwitchOut`
  it has no `attackcanceler` and no `accuracycheck`: sleep / freeze / Truant were
  checked when it was picked to strike, and paralysis, confusion, love, flinching,
  Soundproof, absorbing abilities and the accuracy roll are not.
* **Baton Pass** takes the `pass` party index from the fight choice (§1.2) instead
  of opening a menu mid-move. Passed on (pret `SwitchInClearSetData`,
  `battle_main.c:2329`): stat stages, confusion, Focus Energy, Substitute, Leech
  Seed, Ingrain, the Perish count, Curse, Mud Sport / Water Sport, being trapped
  (Mean Look) and being Locked On. What the **passer holds on others** stays too,
  because the cart stores it by battler position: a foe it trapped stays trapped
  (its switch is refused), and a foe it Locked On to stays locked for the newcomer,
  re-armed for two turns (`STATUS3_ALWAYS_HITS_TURN(2)`). Everything else ends with
  the user. The switch-in then runs Spikes and its abilities.
* **Roar / Whirlwind / Teleport** out of a wild fight end it for everyone with
  reason `run` (the cart ends a wild battle there); in a trainer / PvP fight Roar
  drags in a random living bench mon.
* **Called moves** (Metronome, Sleep Talk, Mirror Move, Assist, Nature Power) nest
  at most **3** deep (`Move.MAX_CALL_DEPTH`; the deepest cart chain is Metronome →
  Assist → Nature Power → the terrain move); a deeper call says "But it failed!"
  -- a sheet or pool row that calls itself can no longer recurse. A called row is
  resolved from the caller's own move list, then the ruleset pool (pret reads
  `gBattleMoves`), then the caller's own seat's party sheets -- never another
  fighter's sheet. Sleep Talk and Assist refuse the four calling moves by number
  (pret `IsInvalidForSleepTalkOrAssist`) **and by effect** (a calling effect under a
  borrowed number); Sleep Talk also applies `CheckMoveLimitations` except PP
  (Disable, Torment, Taunt, Imprison, Encore, Choice Band), and the called move
  runs at the picked slot (`gCurrMovePos`: Mimic / Sketch write there) spending no
  PP of its own.
* **Grudge** empties the slot the attacker *chose* (`chosenMovePositions`: Metronome's
  slot when Metronome called the knockout), only for a foe, never for Struggle.
* **Follow Me** takes every `MOVE_TARGET_SELECTED` move and a *called* move's random
  target (`GetMoveTarget`); a chosen random-target move (Thrash, Uproar) is not
  pulled.
* **Soundproof** is asked per target (`attackcanceler` runs for each target pass):
  one Soundproof foe blocks a spread sound move for itself only, and a called
  sound move is blocked too.
* **Rage** ends at turn start unless the seat chose Rage (a bag / switch / run
  choice is `MOVE_NONE`). **Fury Cutter** is not reset by choosing another move --
  pret has no such check in Gen 3 -- but by a miss, a canceller stop
  (`CancelMultiTurnMoves`), the bag or a failed run (`ClearFuryCutterDestinyBondGrudge`,
  which also clears Destiny Bond and Grudge) or a switch.
* **Multi-hit, Triple Kick and Beat Up** run the move end after **every strike**
  (`moveendto MOVEEND_NEXT_TARGET`): Rage builds, contact abilities (Rough Skin,
  Static, …) proc, the item checks run and King's Rock / Shell Bell act per strike;
  the single secondary still comes at the end. Rage builds only on a hit that
  reached the mon (`TARGET_TURN_DAMAGED`).
* **A hit on the Substitute** leaves the doll's `STATUS2_SUBSTITUTE` bit set until
  that strike's move end even when the doll just broke, so that strike's secondary
  (a 100% Body Slam paralysis) and King's Rock are refused. A 100% *stat-drop*
  secondary is not `MOVE_EFFECT_CERTAIN` on the cart (`ChangeStatBuffs` never gets
  it): Clear Body / White Smoke / Keen Eye / Hyper Cutter / Mist stop it.
* **Hidden Power / Weather Ball** have their in-battle type (sheet `hiddenPower.type`,
  the weather's) *before* `attackcanceler`, so Volt / Water Absorb and Flash Fire,
  Levitate and Hustle's accuracy read it. **OHKO** moves run `typecalc`, so a move
  that is not super effective misses **Wonder Guard**.
* **Recycle** brings back the last item consumed at the user's **battler position**
  (pret `usedHeldItems[battler]`): the next mon to stand there may recycle it, the
  partner in another seat may not. Thief, Knock Off and Trick lift the Choice Band
  lock of whoever lost (or swapped) the band.
* Nothing raises: bad input is `nil, reason` from `create` and `false` from
  `submitChoice`.

---------------------------------------------------------------------------------------------------

## 7. C5 — events

Every event is `{ t = kind, battle, seq, ... }`, built by
`src/BattleSim3/events.lua` (`M.build` whitelist, `M.check`). **All BattleSim2
kinds keep their meaning and fields** (`msg anim damage drain faint send status
stat switch item run turn over wait reconnect chose unchose moves exp team`);
`msg` sentences are the sim's own English (not ROM text), ≤ 60 characters.

### 7.1 Reused kinds, Gen 3 notes

| kind | fields (Gen 3) | notes |
| --- | --- | --- |
| `anim` | `slot`, `side`, `text` = move id, `amount` = 1 on a charge turn, **`target`** (field slot of the move's first target, when it has one), **`spread`** = 1 when one animation covers several targets | said *after* "X used Y!", as the cart does |
| `damage` | `slot`, `side`, `amount`, `hp`, `status` (residual token) | a hit on a Substitute is a `damage` with `hp` unchanged, then `sub` 0 when it breaks; spread moves emit one `damage` per target in battler order |
| `drain` | `slot`, `side`, `amount`, `hp` | every heal (drain, Leftovers, berries, Wish, Ingrain, abilities, items) |
| `status` | `slot`, `side`, `status`, `text`, `confused` | as BattleSim2 |
| `stat` | `slot`, `side`, `text`, **`stat`** (`atk def spe spa spd acc eva`), **`stage`** (−6..6, the resulting stage), **`delta`** (−12..12, the change actually applied) | `amount` is **not** sent on Gen 3 (it cannot carry a negative stage through Wire). One event per stat. "Won't go higher/lower" and prevented drops are `msg` (+ `ability` when an ability did it) |
| `send` / `switch` | as BattleSim2 | a switch-in's ability / Spikes / White Herb follow as their own events |
| `item` | `slot`, `side`, `text` = the numeric item id as a string | bag use (no vitamins in Gen 3 battles) |
| `moves` | `slot`, `side`, `moves` (Gen 3 move rows: `id name num pp maxPp power accuracy type effect chance target priority flags`), `mon` | `mon` present on a PP change of the real party list, absent on a Transform / Mimic overlay |
| `faint`, `turn`, `over`, `wait`, `reconnect`, `chose`, `unchose`, `run`, `team`, `msg` | unchanged | `over` reasons: `ko run catch disconnect timeout` (Roar/Whirlwind and Teleport out of a wild fight end it with `run`) |
| `exp` | `slot`, `species`, `speciesId`, `level`, `participants`, `mon` | as BattleSim2: one per living participant (`mon` = its party index, `participants` = the share count). **New: the holders-only fact** -- `participants` **0** and **no `mon`** -- goes to a seat that fought the fallen foe but has no participant standing (all fainted, e.g. after Explosion), when it still has a living mon: pret `Cmd_getexp` pays the living Exp. Share holders regardless (`viaSentIn` 0 is a `SAFE_DIV`). The client prices it as a knockout with an **empty sentIn set**: `Exp3.split(calculated, 0, viaExpShare)` pays each living holder `floor(floor(calculated / 2) / viaExpShare)` (min 1) and nobody else. |

### 7.2 New kinds

| kind | fields | when |
| --- | --- | --- |
| `ability` | `slot`, `side`, `amount` = ability id (1..77), `text` = ability display name | an ability visibly acted: Intimidate, Drizzle/Drought/Sand Stream, Trace (the traced id), Speed Boost, Rain Dish, Shed Skin, Levitate / Wonder Guard / Volt Absorb / Water Absorb / Flash Fire / Lightning Rod / Soundproof / Damp / Sturdy / Suction Cups / Sticky Hold / Clear Body / Keen Eye / Hyper Cutter / Own Tempo / Oblivious / Insomnia / Vital Spirit / Limber / Immunity / Water Veil / Magma Armor / Inner Focus / Shield Dust-less prevention text, contact procs (Static, Flame Body, Poison Point, Effect Spore, Rough Skin, Cute Charm), Color Change, Synchronize, Natural Cure (no text on the cart; the event only), Liquid Ooze, Forecast, Truant loafing. Always followed or preceded by the `msg` that narrates it |
| `weather` | `text` = `RAIN` / `SUN` / `SAND` / `HAIL`, `amount` = 1 started, 2 continues, 0 ended, `slot`/`side` = the seat that started it (absent otherwise) | move or ability starts, each end-of-turn continue, expiry |
| `held` | `slot`, `side`, `mon` (party index), `amount` = item id that acted, **`holding`** = item id the mon holds once the battle is over (0 = none), `text` = item display name | Leftovers, Shell Bell, every berry, White Herb, Mental Herb, Focus Band (a Choice Band lock is a submit refusal, no event), Quick Claw is silent on the cart (no event), King's Rock is silent (the flinch is the effect), Thief / Covet steal (both mons), Knock Off, Trick (both), Recycle, Smoke Ball fleeing. `holding` is the client's writeback: consumed / stolen items persist after a `wild` / `coop_wild` / `coop_npc` fight; a PvP mode (`1v1` / `coop_pvp`) writes nothing home, as the cart reloads the party after a link battle (`cable_club.c` `LoadPlayerParty`). **Knock Off** is the exception to "now holds": the item is gone for the rest of the fight but comes back afterwards (pret keeps it in the party struct), so its `held` event says `holding` = the knocked-off id; Trick and Thief then fail against it, and the knocked-off mon itself can no longer steal with Thief / Covet (pret `knockedOffMons`: it would lose the item it still owns) |
| `form` | `slot`, `side`, `amount` = Castform form (0 normal, 1 sunny, 2 rainy, 3 snowy) **or** `speciesId` + `text` = species (Transform) | the battler's picture changes |
| `sub` | `slot`, `side`, `amount` = 1 made / 0 faded | draw / remove the substitute doll |
| `ball` | `slot` (thrower), `side`, **`target`** (wild field slot), `amount` = shakes 0..3, or 4 caught, `text` = ball item id | one per throw, after the `item` event and before the narration ("Oh, no! The POKeMON broke free!" / "Aww! It appeared to be caught!" / "Aargh! Almost had it!" / "Shoot! It was so close, too!" / "Gotcha! X was caught!"). A caught fight ends `over` `catch` with `outcome().caught` = the wild sheet (with its `ball` id) |

**Deliberately not new kinds:** stat-change-prevented (a `msg`, plus `ability`
when an ability prevented it), doubles retargeting (the resolved target is
`anim.target`; Lightning Rod / Follow Me are an `ability` event / a `msg`),
side conditions (Reflect, Light Screen, Mist, Safeguard, Spikes — `msg`).

### 7.3 New fields for `Wire.battleEvent` (T7)

`target` (number, field slot 0..FIELD_MAX), `spread` (0/1), `stat` (string, the
seven keys), `stage` (number −6..6), `delta` (number −12..12), `holding`
(number 0..376). The new kinds `ability weather held form sub ball` live in their
own Gen 3 whitelist, `Wire.BATTLE_EVENTS3` (twin: `sanitize.BATTLE_EVENT_TYPES3`),
beside the unchanged Gen 1/2 `Wire.BATTLE_EVENTS`; `Wire.battleEvent` accepts a
kind from either.

---------------------------------------------------------------------------------------------------

## 8. RNG draw-order contract

One generator per battle (`Rng.new(seed)`, the BattleSim2 LCG
`s = (1664525 s + 1013904223) mod 2^32`) and the aim stream (`seed +
AIM_SEED_OFFSET`, used only by `_autoTarget` exactly as in BattleSim2).
**Every draw is `roll(lo, hi) = lo + floor(s * (hi − lo + 1) / 2^32)` taken from
the next state** (top bits, so a coin flip does not alternate). `hi < lo` or a
one-value range draws nothing. The Node twin must draw at exactly these points,
in this order, and nowhere else; the list in the header of
`src/BattleSim3/Turn.lua` is normative and is repeated here:

1. **Battle start**: tie groups of the switch-in order (`roll(0,255)` per tied
   group); Trace picking between two or more traceable foes (`roll(0,n−1)`).
2. **Turn start**: Quick Claw `roll(0,65535)` — only when ≥ 2 seats fight and at
   least one fighting active mon holds QUICK_CLAW; then one `roll(0,255)` per
   group tied on both priority and speed.
3. **Runs** (wild modes): `roll(0,255)` for a runner slower than the wild mon (no
   draw for Smoke Ball, Run Away or a runner at least as fast).
4. **Switches** (interleaved in battler order with the non-ball bag items, which
   draw nothing): a foe Pursuit aimed at the leaving seat draws like any move
   minus the canceller's and the accuracy draws (§6).
5. **Bag**: balls (after every other item, fastest thrower first) draw up to four
   `roll(0,65535)` — none for a Master Ball or odds > 254.
6. **Per move**, in execution order, each only when reached:
   canceller (freeze `roll(0,4)`, a sleeper with no counter `roll(0,3)`,
   confusion `roll(0,1)` [+ self-hit damage `roll(85,100)` + Focus Band
   `roll(0,99)` if held], paralysis `roll(0,3)`, infatuation `roll(0,1)`);
   random target (`roll(0,n−1)` over ≥ 2 living foes for `RANDOM` moves);
   Metronome `roll(1,511)` until a pool move (`roll(1,n)` over the pool after 64
   misses), Sleep Talk / Assist `roll(1,n)`; Protect/Endure streak
   `roll(0, 2^k−1)`; Magnitude `roll(0,99)`; accuracy `roll(1,100)`; multi-hit
   `roll(0,3)` (+ `roll(0,3)` when > 1); per strike: Psywave `roll(0,10)`, crit
   `roll(0,n−1)` (not vs Battle/Shell Armor, not for fixed damage), damage
   `roll(85,100)` (non-zero damage), Present `roll(0,255)`, Focus Band
   `roll(0,99)` (holder only), Beat Up's crit (not vs Battle/Shell Armor,
   pret `critcalc` per member) + damage per party member;
   secondary `roll(0,99)` (not certain, not blocked); effect-internal draws
   (sleep turns `roll(0,3)`, confusion turns `roll(0,3)`, trap turns
   `roll(0,3)`, Tri Attack `roll(0,2)`, Thrash turns `roll(0,1)`, Uproar
   `roll(0,3)`, Disable / Encore / Spite `roll(0,3)`, Conversion / Conversion 2
   `roll(1,n)`, Roar's level check `roll(0,255)` and pick `roll(1,n)`, OHKO
   `roll(1,100)`); move end: contact abilities (Effect Spore `roll(0,9)` then
   `roll(0,3)` until non-zero, Static / Flame Body / Poison Point / Cute Charm
   `roll(0,2)`), King's Rock `roll(0,99)` -- after **every strike** of a
   multi-hit, Triple Kick or Beat Up, plus King's Rock once more at a
   multi-hit's close; after the action, Trace draws as in 1 (the post-action
   item pass is the cart's `moveTurn` pass: no berry there draws). Sleep Talk's
   `roll(1,n)` is over the slots that survive its exclusions (§6).
7. **End of turn**: one `roll(0,255)` per tied group of the re-sort; then, in
   phase order, Shed Skin `roll(0,2)`, confusion-berry turns, Starf-type berry
   `roll(0,4)` until a raisable stat, Thrash fatigue confusion turns
   `roll(0,3)`, Yawn's sleep turns `roll(0,3)`, Future Sight accuracy
   `roll(1,100)` then `roll(85,100)` [+ Focus Band `roll(0,99)`] -- a hit due on
   a seat emptied this turn draws them in the replace phase, after its
   switch-ins (§6).
8. Residuals, switches, exp, items other than balls, and the clock draw nothing
   else. A battle replays from its seed plus the choice log.

---------------------------------------------------------------------------------------------------

## 9. Where BattleSim3 follows pret over the engine port

The engine (`src/core/game3/battle/`) is the port this sim was forked from; where
it differs from the cart, the sim follows pret and the line in the source says so.
The Node twin follows the sim, not the engine.

| topic | engine | BattleSim3 (pret) |
| --- | --- | --- |
| Volt / Water Absorb, Flash Fire | after the accuracy roll | before it (`Cmd_attackcanceler`) — no accuracy draw |
| Future Sight / Doom Desire | a damaging move because power > 0 | always the delayed attack (`BattleScript_EffectFutureSight`), damage computed at use, `roll(85,100)` + accuracy on landing |
| Facade / Revenge / SmellingSalt | guarded by `not opts.dmgMultiplier`, never doubles in battle | doubles (the move scripts set `sDMG_MULTIPLIER`) |
| Revenge | side (singles) / id (doubles) | hurt this turn by *this target* (`Cmd_doubledamagedealtifdamaged`) |
| Struggle vs Wonder Guard | blocked | goes through (`Cmd_typecalc` skips Struggle) |
| a cancelled move | keeps `lastResultingMove` | clears it too (Protect's streak resets) |
| catch odds | float order, float square roots | integer order `floor(rate*mult/10)` first, integer `Sqrt` (§5.5) |
| crit items | held item id | hold effect (identical on every cart item; the sheet carries the hold effect) |
| disobedience, badge boosts, Oak / Pokédude / ghost branches | present | off (link rules) |
| Pay Day money | present (the engine pays) | reported on a won wild / NPC outcome (`outcome().payDay`) and paid by the client (§9.1), none under link rules |

**Corrected in RF5** (fidelity review R5; both twins, pinned by the turn fixture's
RF5 scenarios): what the sim did before, and what it does now (pret).

| topic | before | now (pret) |
| --- | --- | --- |
| HP / PP / confusion / pinch berries, Lansat, Starf | also fire on the post-action pass | only at the end of turn (`!moveTurn`, `ENDTURN_ITEMS1`); `ENDTURN_ITEMS2` after Yawn |
| Baton Pass | drops the passer's traps and Lock-Ons; Mud / Water Sport end | the passer's traps and Lock-Ons stay (re-armed 2 turns); Mud / Water Sport pass (`SwitchInClearSetData`) |
| multi-hit / Triple Kick / Beat Up move end | once, after the last strike | after every strike (`moveendto MOVEEND_NEXT_TARGET`) |
| a strike that breaks a Substitute | its secondary applies | refused (the doll's bit lasts to the strike's move end) |
| 100% stat-drop secondaries | `MOVE_EFFECT_CERTAIN`, pierce Clear Body / Mist | not certain (`ChangeStatBuffs` gets `affectsUser` only) |
| Hidden Power / Weather Ball vs absorbers, Hustle | the row's type | the in-battle type (`hiddenpowercalc` / `setweatherballtype` precede `attackcanceler`) |
| OHKO vs Wonder Guard | ignored | `typecalc` applies it |
| Pursuit on a switching seat | canceller and accuracy run | neither (`BattleScript_PursuitDmgOnSwitchOut`) |
| Grudge | the called move's slot; either side | the chosen slot (`chosenMovePositions`); a foe only; not Struggle |
| Follow Me | pulls random-target moves | only `SELECTED` (and a called move's random target) |
| Soundproof vs a spread / called sound move | first target only; called moves unchecked | every target pass (`attackcanceler`) |
| Rage vs a bag / switch / run choice | kept | ends (`gChosenMoveByBattler` `MOVE_NONE`) |
| Fury Cutter, Destiny Bond, Grudge on a bag action / failed run | kept | cleared (`ClearFuryCutterDestinyBondGrudge`) |
| switches vs bag items | switches first | together, in battler order (`SetActionsAndBattlersTurnOrder`) |
| Future Sight due on a seat emptied this turn | dropped | lands on the replacement (the cart replaces first) |
| Intimidate / Trace passes | capped at 4 | until nothing acts |
| Conversion 2 | stops at the Foresight marker | every row but the marker (Normal / Fighting → Ghost reachable) |
| Heal Bell | cures a benched Soundproof mon | not (the party member's ability is read) |
| Recycle | per side | per battler position (`usedHeldItems[battler]`) |
| Thief / Knock Off / Trick | keep the Choice Band lock | lift it (`choicedMove` cleared) |
| Blue / Yellow / Red Flute | consumed | never spent (`IsItemFlute`) |
| Exp. Share with no participant standing | nothing | the holders are paid (holders-only `exp` fact, §7) |

### 9.1 Remaining differences from the cart (disclosed)

What the sim still does differently from pret, and why:

| topic | cart (pret) | BattleSim3 | why |
| --- | --- | --- | --- |
| balls vs other bag actions | one bag action each, in battler order | balls after every other bag action, fastest thrower first | BattleSim2's mediated-fight policy for co-op throws (several humans may throw at one wild mon) |
| post-action held-item pass | reads **battler 0** only (`ItemBattleEffects(ITEMEFFECT_NORMAL, 0, TRUE)`, `battle_util.c:1211`) | every standing battler, first that acts | the engine port's reading; on that pass only status cures and White / Mental Herb act, and `ITEMEFFECT_MOVE_END` already runs them for every battler at every move end, so a difference needs a condition set outside any move |
| Future Sight vs Perish Song with a replacement pending | replacement, then Future Sight, then Perish Song | Perish Song at the end of turn, then the replace phase, then the waiting hit | the sim's replace phase follows the end of turn; only the order of the lines differs |
| a Future Sight seat that is never refilled | the counter stays forever (absent battler) | the token is dropped | equivalent: nobody ever stands there again |
| Magnet Pull in doubles | FRLG: foes only; Emerald (`ABILITYEFFECT_CHECK_FIELD_EXCEPT_BATTLER` with no side check): the holder's Steel partner is trapped too | foes only, for every fight | the sim carries no cart version per battle (a fight may mix FireRed and Emerald players) |
| Roar / Whirlwind level check | applied in trainer fights too (`TryDoForceSwitchOut` runs in both branches of `Cmd_forcerandomswitch`, both carts) | the same | kept on purpose: it is the cart's rule, not a wild-only one |
| Fury Cutter after another move | not reset (Gen 3 has no `TryClearRageAndFuryCutter`; `TryClearRageStatuses` clears Rage only) | the same | kept on purpose |
| called-move depth | unbounded, but no cart row set nests deeper than 3 | "But it failed!" past 3 | robustness: crafted rows must not recurse |
| where a called row comes from | `gBattleMoves` | the caller's own list, the pool, the caller's own party | the hub holds no move table; never another fighter's sheet |
| Sleep Talk / Assist exclusions | by move number | by number and by calling effect | identical for cart rows; refuses crafted rows |
| Conversion 2's draw | `Random() & 0x7F` rejection sampling (≤ 1000 tries), then a fixed scan | one `roll(1,n)` over the matching rows | the same set of results, a single draw |
| Pursuit's move end on a switching seat | `moveendfromto ON_DAMAGE_ABILITIES, CHOICE_MOVE` only (contact abilities, immunity cures, attacker Synchronize) | the whole move end | not reproduced: the sim also runs defrost, target Synchronize, the item checks, King's Rock / Shell Bell and the last-move bookkeeping (a Shell Bell Pursuer heals, and its `lastMoveNum` becomes Pursuit, where the cart's do not) |
| Hidden Power after Transform | the target's IVs (Transform copies the battle struct) | the user's own sheet `hiddenPower` | the sheet carries no IVs for the hub to recompute from |
| King's Rock flinch chance | battler 0's hold-effect parameter | the same (§6) | kept as the quirk it is |
| Pay Day's Amulet Coin doubling, the wallet | `moneyMultiplier`, `AddMoney` | the sim reports the coins (`outcome().payDay`); the client doubles and pays them | the client owns the save, so the split is where the money lands, not what is paid: the 1v1 / `SOLO BATTLES` client (`MediatedBattle:payDay3`) and co-op (`CoopBattle:payDay3`) pay a won `wild` / `coop_wild` / `coop_npc` outcome's `payDay` through the engine's `Prize.payDay`, × 2 for an Amulet Coin the cart counts (the player's own holder sent out; on FireRed / LeafGreen a foe's too), after the cart's ending lines and in its words (`STRINGID_PLAYERPICKEDUPMONEY`); nothing in a PvP mode |

**Engine cross-check** (run locally against the engine checkout with an imported
FireRed cache; nothing it reads is committed): `Damage.calc` identical on all 81
vector cases and on a 2000-case random sweep over the real chart and real
battlers; crit stages 8/8; accuracy 13/13.

---------------------------------------------------------------------------------------------------

## 10. Coverage

* **Move effects**: all 214 `EFFECT_*` (0..213) resolve. The damaging and calling
  effects run through the hit pipeline / call-move path; every non-damaging
  effect has a handler. `EFFECT_HIT` with power 0 and the unused slots 96, 110,
  131, 141, 163 do what the cart's placeholder script does: the animation and
  "But nothing happened!". A sheet that gives a damaging effect power 0 gets the
  same sentence.
* **Abilities**: all 77 (`Abilities.BY_ID`). With no battle effect on the cart,
  so never an event: STENCH, ILLUMINATE, PICKUP (overworld / after-battle only)
  and CACOPHONY (unused; Soundproof is its own check). RUN_AWAY acts only when
  running or Teleporting.
* **Hold effects**: all 66. With no battle effect (never an event): EXP_SHARE,
  LUCKY_EGG, FRIENDSHIP_UP (exp / friendship are the client's, from the `exp`
  facts), DOUBLE_PRIZE (the Amulet Coin doubling of `outcome().payDay` and of
  trainer prize money is the client's), REPEL (Cleanse Tag),
  PREVENT_EVOLVE, DRAGON_SCALE, UP_GRADE. Mail (item ids 121..132) has no hold
  effect; Thief / Covet and Trick refuse it and the Enigma Berry (175).
* **Bag**: §4 in full.
