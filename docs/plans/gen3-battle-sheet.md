# Gen 3 battle sheet (C4), event vocabulary (C5) and the BattleSim3 contract

| Field | Value |
| --- | --- |
| Date | 2026-09-30 |
| Owner | T5 (`src/BattleSim3/*`, this document) |
| Parent plan | [`gen3-firered-emerald-support.md`](gen3-firered-emerald-support.md) §3 decision 6, §5 C4/C5 |
| Consumers | T7 (Node twin `server/lib/battle3`, Wire/sanitize Gen 3 dialect, hub sim selection), T8 (`Sheet3`, mediated client), T9 (arena / classic GBA UI), T11 (co-op), T12 (solo); the shared-team seats of §1.3 are contract C1 of [`gen3-solo-doubles.md`](gen3-solo-doubles.md); the solo-only options, fields, choices and events of §1.4–§1.6 and §7.2 are contracts C3 / C6 / C-W of [`gen3-solo-remaining-fights.md`](gen3-solo-remaining-fights.md) |
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
battle:outcome()                           -- nil | { battle, outcome, winners, losers, reason, how?, by?,
                                           --        caught?, catcher?, given?, payDay?, safari?, judged? } (§1.6)
battle:snapshot()                          -- tests / logs only (same shape as BattleSim2 + field digest;
                                           --   `palaceLow` per field entry, `arena` tallies under rules.arena)
battle:seatsOf(ownerId)                    -- the owner's seat fighters in slot order (§1.3); {} if unknown
battle:palaceLow(fieldSlot)                -- rules.palace: the battler's low-HP bit (§1.4)
```

The Node twin exposes `Turn.attempt(opts) -> { battle, reason }` as the Gen 2 twin does.

`Turn` also exports `MODES`, `VERSION`, `STATUS_FROM_WIRE` / `STATUS_TO_WIRE`,
`MONS_PER_PARTY` (6), `FIGHTERS_PER_SIDE` (3), `CHOICE_TIMEOUT`, `RECONNECT_GRACE`,
`RESOLVE_TIMEOUT`, `TIE_BREAK_ROLL` (128), `AIM_SEED_OFFSET` (1597334677) — same
values as BattleSim2 — and `SEATS_PER_PARTY` (2, §1.3). The solo-only vocabulary
of §1.4–§1.6 is exported as closed sets: `HOW`, `FIRST_BATTLES`, `LESSONS`,
`GHOSTS`, `WILD_AI`, `TUTORIALS`, `CATCHES`, plus `ITEM_POTION` (13, Oak's flag-4
item), `WILD_PICK_CAP` (256), `copyRules`, `isWildMode` and `runEndsBattle`.

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
| `wildPick` | `"cart"` | solo only (§1.4): a computer wild seat picks as the cart's opponent controller does |
| `firstBattle` | `"oak"`, `"birch"` | solo only (§1.4): the first battles' rules |
| `ghost` | `"veiled"`, `"unveiled"` | solo only, wild modes (§1.4): the POKéMON TOWER ghost |
| `rules` | table | solo only (§1.4): the facility rules, the Battle Palace and the Battle Arena |
| `safari` | table | solo only, `wild` (§1.4): the Safari Zone |
| `catch` | `"forced"` | solo only, wild modes (§1.4): every ball catches, nothing given |
| `tutorial` | `"oldMan"`, `"wally"`, `"pokedude"` | solo only, wild modes (§1.4): the tutorial battles |

A **fighter** (one seat): `{ playerId, name, mons = { sheet... (≤ 6) }, bag = bag?, seats = 1|2?, badges?, family?, ai?, spare?, bagFrom?, noBattler? }` (the last four: §1.5).

* `badges` (contract K1 of [`gen3-badge-rules.md`](gen3-badge-rules.md)) is the
  trainer's badges: a list of badge numbers as strings or numbers
  (`{ "1", "3", "7" }`, the wire form) or a set (`{ [1] = true }` /
  `{ ["1"] = true }`, the hub's sanitised form). `Damage.badgeSet` keeps the
  integers 1..8 and drops everything else silently — a bad value never refuses
  the battle.
* `family` (`"frlg"` | `"rse"`, absent ⇒ `"frlg"`, the engine's default
  `BattleProfile`) is the trainer's cart family; only obedience's Focus Punch
  rule reads it (§6). **A client never sends it.** SoloBattle sets it from
  the running cart, and both hubs set it per human seat from that client's
  own hello `version` (`CART_FAMILY` in `src/Hub.lua` / `server/lib/relay.js`:
  firered and leafgreen → frlg, emerald → rse).
* Both are read **only for side a in `wild`, `coop_wild` and `coop_npc`**
  (`Turn.BADGE_MODES`, the cart's non-link fights) and dropped everywhere else —
  in `1v1` / `coop_pvp` and on side b whatever an entry uploads (link rules,
  §6). Each fighter keeps `badgeRules` (true exactly there), `badges` and
  `family`; every battler it fields carries `b.badges`.

`seats = 2` makes the entry a **shared team** (§1.3); absent or `1` is one seat,
exactly as before. Anything else (`0`, `3`, …) refuses the battle with
`"<playerId> has a bad seat count"`, and both seats count against the side's
seat cap (`1v1` / `wild` allow one, so a shared team there is refused as
`"side a has more fighters than 1v1 allows"`).

### 1.2 Choices (zero-based on the wire, like BattleSim2)

| action | fields | notes |
| --- | --- | --- |
| `fight` | `move` 0..3 (index into the *current* move list), `target` field slot (optional), `pass` party index 0..5 (optional) | `target` is read only for `MOVE_TARGET_SELECTED` moves — and a **Ghost's CURSE**, which the cart's menu aims the same way (§6) — and may name a living **ally** (Gen 3 lets a player aim at the partner) or any living foe, never the user. Absent ⇒ first living foe. Other target kinds ignore it. `pass` is the Baton Pass destination (the cart opens the party menu mid-move; a mediated fight asks up front): a living bench mon; absent or not legal ⇒ the first living bench mon in party order. |
| `switch` | `slot` 0..5 (party index) | refused while trapped (Mean Look / Block / Spider Web, Ingrain, a partial trap, Shadow Tag, Arena Trap, Magnet Pull); a forced replacement is always legal |
| `item` | `item` numeric item id (number or numeric string), `slot` party index (optional), `move` 0..3 (PP items), `dexCaught` bool (Repeat Ball: the thrower's dex already has the species caught) | ids per §4 |
| `run` | — | wild modes: refused when trapped (unless Smoke Ball / Run Away); see §6. Under the solo options (§1.4): a forfeit under `rules.forfeit`, refused under `firstBattle` (Birch's silently unless a Smoke Ball or Run Away gets away first; Oak's with the `run` lesson), always away for a veiled GHOST's foe, a `noBattler` seat and a Safari trainer |
| `cancel` | — | same as BattleSim2 (in the Battle Palace the solo client also rewinds its pick, §1.4) |
| `safari` | `throw` = `ball` \| `bait` \| `rock` \| `near` \| `block`; `block` 1..40 (the POKéBLOCK case slot); referee-only `verdict` 0..2 and `blockName` | solo only (§1.4): the Safari Zone's one action. `bait` / `rock` are FireRed / LeafGreen's, `near` / `block` Emerald's; a throw of the other cart is refused, and so is `safari` in any fight that is not one. A `block` throw is refused without `verdict` (0 curious, 1 enthralled, 2 ignored: the client's reading of the block against the monster's nature); Wire carries neither `verdict` nor `blockName`, so the solo `choose` hook files the whole choice itself (`ctx.solo:file3`) |
| `wallyThrow` | — | solo only (§1.4): WALLY's turn-3 `B_ACTION_WALLY_THROW`. Accepted only under `tutorial = "wally"`, from WALLY's own seat alone — side a's first (`index` 1; pret's WALLY controller drives `B_POSITION_PLAYER_LEFT` only), standing and not replacing; refused everywhere else, side b's and a second side-a seat's (a coop partner, a shared team's `#2`) too, so one turn holds one throw |

Two extra readings of `fight`, both under `rules.palace` only (§1.4): a `move`
the move menu would refuse is accepted (the selection check fails it when its
turn comes), and `unable = true` is the client's own Palace failure (no `move`
needed; Wire does not carry it, so solo files it through `ctx.solo:file3`).

Move-select legality (pret `battle_util.c:302` `TrySelectMove` / `CheckMoveLimitations`):
a slot is refused when it has 0 PP, is Disabled, is Tormented (same as last move),
is a status move under Taunt, is Imprisoned by a foe, or is not the Choice Band
move. When **every** slot is refused the choice is Struggle (any index accepted).
Encore does not refuse: whatever index is chosen, the Encored move is used.

### 1.3 Shared teams (`seats = 2`) — the cart's own double battle

On the cart one trainer fields **two battlers from one party** (gPlayerParty
behind battlers 0 and 2, gEnemyParty behind 1 and 3). A side entry with
`seats = 2` is exactly that:

```lua
sides = {
  a = { { playerId = "solo_player", seats = 2, name, mons, bag, badges, family } },
  b = { { playerId = "solo_foe", seats = 2 --[[ or 1 ]], name, mons, bag } },
}
sim:submitChoice("solo_player#2", { action = "fight", move = 0, target = 3 })
```

* `create` expands it into **two fighters over the same `mons` table and the same
  bag** (counts and names). Seat 1 keeps `playerId`; seat 2 is `playerId .. "#2"`.
  Every fighter has `owner` (its entry's `playerId`, so both seats of a shared team
  name the same owner) and `seats` (the fighters over its party, in slot order —
  itself alone for an ordinary entry). `battle:seatsOf(id)` returns a copy of that
  list for an owner or a seat id.
* Seats take field slots in order like any other fighters (side a `0, 1`, side b
  `3, 4`, `Events.fieldSlot`), and battler order stays `a1 b1 a2 b2`. A side with
  two seats is a doubles fight (§6).
* **Choices, `autoPick`, the clock** are per seat, addressed by the seat's own id.
  No new choice field: `Wire.battleChoice` is unchanged.
* **Leads** (pret `SetBattlePartyIds`): seat 1 gets the first living mon, seat 2
  the next living one after it. With only one living mon seat 2 starts **empty**:
  no `send`, no battler, never owing.
* **The bench** of a seat is every living mon of the party except **both** seats'
  active mons and — while choices are being filed — the destination of the
  sibling seat's filed switch or replacement (pret `HasNoMonsToSwitch`; the party
  menu's "already in battle" / "already selected"). A `switch` or replacement
  naming the sibling's active, its claim, or the seat's own active is refused
  (`false`), even when the sibling is switching that mon out this turn. A
  `cancel` releases the claim. The same bench feeds Roar / Whirlwind, Baton Pass
  (`pass` naming a taken mon is dropped, as any illegal `pass` is), the auto-pick
  and the `faint` event's `amount` (1 = this party still has a bench mon).
* **Replacement** follows battler order (pret `HandleFaintedMonActions`): a
  fainted seat is asked (`turn` with its `slot`) only if the bench still has a mon
  after every sibling **ahead** of it that is owed one. Both seats down with one
  bench mon: only the first seat is asked and refills; the other is not asked
  and, once the replace phase's switch-ins are done, stands **empty** (pret's
  absent battler, `gAbsentBattlerFlags`) — no `mustReplace`, untargetable, never
  solicited, and a Future Sight due there is dropped. A seat whose mon falls with
  nothing on the bench is emptied the same way. With two or more bench mons both
  seats are asked and either may take any bench mon the other has not claimed.
* **A Revive refills an empty seat.** pret re-checks every absent battler at the
  top of each faint flow — after every action and at the end of the turn
  (`HandleFaintedMonActions` case 0, `battle_util.c:1156`; the engine's
  `Engine.refreshAbsent`) — and one whose party has a replacement again is asked
  for it. So right after a bag action that revives a party member, an empty seat
  is owed a mon again, and the replace phase that follows the turn asks it
  (`turn` with its `slot`); the newcomer is in the turn order from the next turn,
  and a Future Sight due on the seat that turn waits for it. The order rule above
  still holds: when the sibling also fell that turn and the revived mon is the
  only bench mon, the seat first in battler order takes it and the other stands
  empty (again) — §9.1 for the cart giving it to the seat owed first. A seat
  that **started** empty is never refilled (the engine fields no battler there to
  re-check). One-seat fighters are untouched: only a shared team has a sibling
  standing while a seat is empty.
* **The bag** is one bag. An item a sibling has filed this turn is held back
  from the other seat (the cart spends a medicine when it is *chosen*): two seats
  and one Potion, the second seat's Potion is refused until the first cancels.
  Flutes are never spent, so they are never held back.
* **Items on the partner**: a medicine, PP item or flute whose `slot` names the
  sibling seat's active mon works on that **battler** — `drain` / `status` /
  confusion and infatuation cures / `moves` at the partner's slot, exactly as on
  one's own (the engine's `active_for_slot`). X items, Dire Hit and Guard Spec.
  stay the choosing seat's own (pret `ItemUseInBattle_StatIncrease` reads
  `gBattlerInMenuId`): naming the partner refuses them.
* **EXP** is counted per party member (pret's sentIn bits are party indices): a
  mon that fought from both seats is one participant and gets one `exp` fact.
  Its `slot` is the seat it is out on, or the party's first seat when it is
  benched; `mon` is its party index. A party's holders-only fact (§7.1) comes
  once, on its first seat.
* **Owners, not seats**, are the players: `outcome().winners` / `losers`,
  `catcher` and `snapshot().waiting` list owner ids, each once
  (`"solo_player"`, never `"solo_player#2"`), and the `team` roster is emitted
  once per party, on its first seat's slot.
* Heal Bell / Aromatherapy from a shared team reaches the partner through its
  battler (the ally pass, with its battle ability) and the rest of the party as
  the bench; a Soundproof partner is not cured behind its back.
* **Badges** (K1): both seats are the one trainer's, so both carry the entry's
  `badges` and `family` — the boosts and obedience (§6) apply from either seat,
  per mon (a traded mon may disobey from seat 2 while seat 1's obeys).

### 1.4 The solo-only create options (the fights SOLO BATTLES took from the cart)

Contract C3 of [`gen3-solo-remaining-fights.md`](gen3-solo-remaining-fights.md),
as built (its research doc, Parts 2–5). Only solo's local referee is ever
created with these: no hub passes them, none rides the wire, and co-op refuses
every fight that needs one (`Config.COOP_REFUSED_GEN3`). Absent, every fight
is the one it always was. Both twins carry each option line for line, pinned
by turn-parity scenarios, and `src/BattleSim3/Turn.lua`'s header is the
normative list.

| option | values | what changes | read / refused |
| --- | --- | --- | --- |
| `wildPick` | `"cart"` | a computer wild seat, when asked (`autoPick`, the clock), picks as pret's opponent controller does for a wild battle with no AI (fr `battle_controller_opponent.c:1355`): `roll(0,3)` per draw until a usable slot (`WILD_PICK_CAP` = 256 draws, then the first usable one), then `roll(0,1)` for the target with two side-a seats. Without it, the auto-pick heuristic (§6). Solo passes it on every Gen 3 wild fight | wild seats only |
| `firstBattle` | `"oak"` | FireRed / LeafGreen's lab rival: side a's moves skip the whole accuracy check, Protect and semi-invulnerability included (no draw), until the `stat` lesson (FUTURE SIGHT / DOOM DESIRE until the `damage` lesson; pret reads move 0's power, fr `battle_script_commands.c:1007`); crits are drawn and void, both sides, until the `damage` lesson (`:1200`); side a's RUN is refused at submit, with the `run` lesson; `lesson` events at Oak's eight points (§7.2) | any mode |
| | `"birch"` | Emerald's Birch rescue: no crits on either side (no draw; em `battle_script_commands.c:1281`); side a's RUN is refused at submit unless a Smoke Ball or Run Away gets away first (em `battle_main.c:4078`) | |
| `ghost` | `"veiled"` | the POKéMON TOWER ghost without the SILPH SCOPE: both sides' moves are cancelled (side a: "<X> is too scared to move!" and `anim MON_SCARED`; side b: "GHOST: Get out...... Get out......" and `anim GHOST_GET_OUT`), side a's RUN always gets away (no draw), no sandstorm / hail chip on the ghost, Intimidate and Trace do nothing | wild modes; dropped elsewhere |
| | `"unveiled"` | the scoped Marowak: a normal fight | |
| | both | a thrown ball is dodged and spent: `ball` with `amount = -1` (no draw), then "It dodged the thrown BALL! This POKeMON can't be caught!" | |
| `rules` | table, below | the facility rules, the Battle Palace, the Battle Arena | any mode, but see below |
| `safari` | `{ family = "frlg" \| "rse", balls = 0..255, goNearCatch?, goNearEscape?, pkblToEscape?, catchFactor?, escapeFactor? }` | the Safari Zone, below | refused outside `wild`, without a family or a ball count, on Emerald without the cart's three tables (`goNearCatch[4]`, `goNearEscape[4]`, `pkblToEscape` as ≥ 4 rows of 3, each 1-based — pret index `i` at `[i + 1]`), and on FireRed / LeafGreen without the wild sheet's `safariFleeRate` (or an `escapeFactor`). It turns `firstBattle`, `ghost`, `catch` and `tutorial` off |
| `catch` | `"forced"` | every ball catches (pret's `BALL_3_SHAKES_SUCCESS`; `ball` with `amount = 4`), no draw; the monster is not the thrower's: `outcome().given = false` (fr `battle_script_commands.c:9485`, em `:9921`) | wild modes; dropped elsewhere |
| `tutorial` | `"oldMan"`, `"wally"`, `"pokedude"` | a forced catch, plus: no crits (no draw) under `oldMan` / `wally` (fr `battle_script_commands.c:1198`, em `:1281`); under `pokedude` crits drawn and void (fr `:1201`), every move of both sides skips the whole accuracy check, Protect and semi-invulnerability included (fr `:1015`), nobody disobeys (`battle_util.c:3149`), and no move effect but sleep lands on side b (`battle_script_commands.c:2128`); under `wally` WALLY's seat (side a's first) may file `wallyThrow` (§1.2, §7.2) | wild modes; dropped elsewhere |

**`rules`** (`Turn.copyRules`; a key absent, or holding anything but the value
shown, is today's behaviour). The carts these come from are Emerald's unless
named:

| key | normalised | effect |
| --- | --- | --- |
| `bag = false` | `noBag` | every bag item refused at submit, both sides (`battle_main.c:4221`); the screen says the cart's "Items can't be used now." |
| `forfeit = true` | `forfeit` | a RUN in a trainer fight is a forfeit (`battle_main.c:4321` asks, `battle_util.c:448` always gets away, `:5058` B_OUTCOME_FORFEITED): `how = "forfeit"`, the runner's side loses, traps or not |
| `exp = false` | `noExp` | no `exp` facts (`battle_script_commands.c:3270`) |
| `boosts = false`, or `{ damage = false, speed = false }` | `noDamageBoost`, `noSpeedBoost` | no badge stat boosts (`pokemon.c:3407`, `battle_main.c:4640`) |
| `obedience = false` | `noObedience` | nobody disobeys but under the Mew / Deoxys rule (`battle_util.c:3924`) |
| `theft = "foe"` | `theft` | the foe side may Thief / Covet / Trick, and the knocked-off check is lifted (Frontier, e-Reader, Secret Base; `battle_script_commands.c:2746`, `:9192`) |
| `theft = "none"` | `theft` | nobody may (Trainer Hill, FireRed's Trainer Tower; `:2740`, `:9193`) |
| `soulDew = false` | `noSoulDew` | SOUL DEW inert (`pokemon.c:3187`) |
| `pyramidRun = 1..255` | `pyramidRun` | the Battle Pyramid's run multiplier: a wild RUN, Run Away included, always rolls `speed * n / foe speed + 30 * tries` (`battle_util.c:427-458`); in a trainer fight under `forfeit`, a Run Away runner rolls before it may forfeit, and a failure is "Can't escape!" with the turn spent |
| `pyramidBag = true` | `pyramidBag` | nothing in the referee: the bag uploaded is the Pyramid bag, and the client writes the spends back |
| `palace = { flavor = { 25 × 0..3 } }` | `palace` | the Battle Palace (`Palace.lua`), below |
| `arena = true` | `arena` | the Battle Arena (`Arena.lua`), below |

What solo passes per hall (`src/Solo3/Facility.lua` `rulesFor`): every
Frontier hall and Battle Tent `{ exp = false, boosts = false, obedience =
false, theft = "foe", soulDew = false }`, plus `bag = false` (the Pyramid has
`pyramidBag` and `pyramidRun` instead), `forfeit` in a trainer fight, and
`palace` / `arena` in their halls; Trainer Hill `{ exp = false, theft =
"none", forfeit }` (trainer fights); FireRed / LeafGreen's Trainer Tower
`{ exp = false, theft = "none" }` (no forfeit: FRLG has no forfeit prompt);
a Secret Base `{ boosts = { damage = false }, theft = "foe" }`.

Refused: `rules.palace` without the cart's 25-entry flavor table ("rules.palace
needs the cart's flavor table (25 natures)"); `palace` and `arena` together;
either in a wild mode; `arena` with more than one seat a side.

**The Battle Palace** (`rules.palace`; pret em `battle_gfx_sfx_util.c:109`
`ChooseMoveAndTargetInBattlePalace`, `battle_util.c:975`). Neither trainer
picks a move on the cart: the nature does. That pick is the client's (solo's
`SoloBrain` from the player's cart's tables), and reaches the referee as a
`fight` choice. A slot the move menu would refuse is accepted and fails when
its turn comes, with the cart's selection line (disabled, Torment, Taunt,
Imprison); `unable = true` is the pick's own 50% failure, which runs the
"appears incapable of using its power!" path after the sleep / freeze escape
check (`palace` event `unable`). At each turn's end, in battler order, a
battler at or under half HP, not asleep and not yet flagged gets its low-HP
bit and the half-HP line its nature names (`palace` event `flavor`, `amount`
= the line's index). `battle:palaceLow(fieldSlot)` and the snapshot's
`palaceLow` give the bit, which the client's next pick reads. Struggle and an
Encore come first, as on the cart; no RNG of its own beyond the escape check's
and a random-target move's.

**The Battle Arena** (`rules.arena`; pret em `battle_arena.c`,
`battle_util.c:1856`). One seat a side. Switch submits are refused, Baton Pass
and Roar / Whirlwind fail, and a battler down is replaced at once in party
order (no choice is asked). At the end of a pairing's third turn, with both
standing, the judge scores Mind (each move row's `arenaMind`, §2), Skill (the
move results and the ability deductions) and Body (HP over HP at the pairing's
start): 2 points to the better, 1 each on a tie, the loser "faints" keeping its
HP and status (`mon.judged = true`, `team` token `x`), a tie judges both. A
judgment that empties a side ends the fight with `how = "judge"` (§1.6). Points
restart at every switch-in. `arena` events (§7.2) narrate every step. No RNG.

**The Safari Zone** (`safari`; pret fr `battle_main.c:2282`, `:4334-4429`, em
`battle_util.c:52-76`, `:541-634`; `Safari.lua`):
- Side a is the trainer alone (`noBattler`, implied; §1.5): no send-out, no
  faint, no EXP, no bag.
- The trainer files `{ action = "safari", throw = … }` (§1.2) or `run`, which
  always gets away. The monster is never asked: as each turn opens it rolls
  `roll(0,99)` against its flee rate, from the counters as they stand, and
  then flees or watches after the trainer's throw.
- Factors (pret's start values): catch `catchRate * 100 / 1275`; escape on
  FireRed / LeafGreen `safariFleeRate * 100 / 1275`, at least 2; on Emerald 3.
  `catchFactor` / `escapeFactor` override either (0..20).
- FireRed / LeafGreen: BAIT (`roll(0,4)`, a counter, the catch factor halved),
  ROCK (`roll(0,4)`, a counter, the catch factor doubled), and their flee-rate
  arms; the monster's reaction is `anim SAFARI_REACTION` (amount 0 watching, 1
  angry, 2 eating). Emerald: GO NEAR (from the cart's tables; "can't get any
  closer!" from the 4th step, `battle_util.c:604`) and a POKéBLOCK (the
  client's `verdict`; the cart's zero-escape glitch kept); no reaction clip.
- A SAFARI BALL: the count drops first (`item`, `amount` = the balls left),
  then up to four `roll(0,65535)` from the catch factor with the ball's ×1.5.
  If the last ball misses, the fight ends `how = "balls"` before the monster
  acts.
- Every ending carries `outcome().safari = { balls, pokeblockThrows }`, a
  disconnect included, so the balls thrown stay thrown.

### 1.5 The solo-only side-entry fields

| field | where | what it does |
| --- | --- | --- |
| `ai = "roamer"` | a wild seat (side b of a wild mode); dropped elsewhere | AI_Roaming: flee unless wrapped or escape-prevented, the foe has Shadow Tag, or the foe has Arena Trap and the roamer lacks Levitate; otherwise a random usable move. A sleeping or frozen roamer still flees; Encore, Struggle and a recharge stop it |
| `ai = "firstBattle"` | the same | AI_FirstBattle (Birch's ZIGZAGOON): flee when the player's monster is at 20% of its HP or under, whatever the speeds |
| `spare = true` | any side | the entry does not hold its side up: the side is down when every other entry is (Steven, pret `Cmd_checkteamslost` `battle_script_commands.c:3543`). A side of nothing but spares is refused (`"side <x> has only spare fighters"`) |
| `bagFrom = "<playerId>"` | any side | the entry spends another entry's bag on its own side: the same tables, so a count spent by either is spent for both and an item one has filed this turn is held back from the other (a pair's B spends A's four items). An unknown id, the other side, itself or a lender that borrows in turn is refused (`"<owner> has a bad bagFrom"`) |
| `noBattler = true` | side a of a `wild` fight only, with no `mons` (implied by `safari`) | a trainer with no battler (the old man, the Safari's player): it chooses every turn, holds its side up, gets away on every RUN, may use a bag item that needs no party member (a ball, an escape item, a flute), and sends no `send` / `team` / `faint` / `exp`. A seat facing only such entries passes its turn. Refused anywhere else, or with monsters |

**A wild seat's flee** (`ai`, or any `run` the wild seat files): it is the
cart's opponent RUN (fr `battle_main.c:4317` `HandleAction_Run`), sorted with
the moves at priority 0 by speed, never refused at submit, and re-checked when
it executes: a partial trap or Mean Look / Block / Spider Web says "Wild X
can't escape!" and spends the turn; otherwise "Wild X fled!", `run` with
`side = "b"`, and the fight ends `how = "flee"`. It draws nothing.

Nothing in the referee asks whether side a is a human: a scripted party there
(WALLY's ZIGZAGOON, the POKé DUDE's) is filed like any seat, and `wildPick` /
`ai` stay side b's.

### 1.6 How a fight ended: `outcome()`

| ending | `how` | `by` | `outcome` / `reason` |
| --- | --- | --- | --- |
| a KO | `ko` | the winning side (nil on a draw) | `win` / `draw`, `ko` |
| the player's RUN, Smoke Ball, Run Away, Poké Doll / Fluffy Tail, a link concession | `run` | the runner's side | the other side wins, `run` |
| a wild seat's flee | `flee` | `"b"` | side a "wins", `run` |
| TELEPORT out of a wild fight | `teleport` | the user's side | `run` |
| ROAR / WHIRLWIND out of a wild fight | `roar` | the user's side | `run` |
| a ball | `catch` | the thrower's side | `catch` |
| RUN under `rules.forfeit` | `forfeit` | the forfeiting side | the other side wins, `run` |
| the last SAFARI BALL missed | `balls` | `"a"` | side b wins, `run` |
| the Arena's judgment emptied a side | `judge` | the winning side (nil on a draw) | `win` / `draw`, `ko` |
| a disconnect or a timeout | absent | absent | as BattleSim2 |

`reason` keeps its BattleSim2 meaning. The other fields a solo option adds:
`given = false` on a forced catch (the monster is not the catcher's);
`safari = { balls, pokeblockThrows }` on every Safari ending; `judged = { a =
{ slot… }, b = { slot… } }`, the Arena's judged monsters by sheet slot, for a
side that lost one. The client maps `how` / `by` to the engine's outcome word
(`SoloBattle.gen3Words`, contract C5 of the plan), with each cart's TELEPORT /
ROAR rule.

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
| `safariFleeRate` | 0..255 | solo, wild seat | the species' `safariZoneFleeRate` (Sheet3 stamps it on a wild sheet); read only by a FireRed / LeafGreen `safari` fight for its escape factor (§1.4). Not on the wire: `Wire.battleMon` does not carry it, and no hub fight reads it |
| `fateful` | `true` or absent | solo, wild seat | the wild monster's fateful-encounter bit (a `seteventmon` wild); never read by the referee. The client keeps it on the caught monster it rebuilds from the sheet (`Sheet3.monFromSheet`). Not on the wire |
| `ivs`, `evs`, `personality`, `otId` | passthrough | opt | never read by a formula; copied onto the `caught` sheet so the catcher can rebuild the exact mon |
| `traded` | `true` or absent | opt | contract K2: the OT id or OT name is not this player's (pret `IsOtherTrainer`, engine `Engine.isTradedMon`; the client decides it in `Sheet3.tradedOf`, the engine's exact-name rule rather than `Exp3`'s prefix compare). Obedience (§6) reads it on side a against the computer |
| `unfateful` | `true` or absent | opt | contract K2' (it replaces K2's `fateful` of [`gen3-badge-rules.md`](gen3-badge-rules.md), PROTOCOL 30 being unreleased): the engine mon's `fatefulEncounter` is **explicitly** `false`, the one value the engine's Mew / Deoxys rule acts on (`engine.lua:1299`). Read only for Mew (151) and Deoxys (410): with it they obey nobody (§6). Absent means the rule does not apply, exactly as the engine's nil field: the mon obeys under the ordinary `traded` / badge-cap rule. A client sends it only when the field is `false`, never for a nil one |
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
| `arenaMind` | -1..1 (kept in -128..127) | opt, solo: the cart's Battle Arena Mind rating for the move (pret `sMindRatings`, read from the player's cart; Sheet3 stamps it). Read only by the Arena's judge (§1.4); a row without it takes the rule the table follows. Not on the wire |

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
| ball | 1 Master, 2 Ultra, 3 Great, 4 Poké, 6 Net, 7 Dive, 8 Nest, 9 Repeat, 10 Timer, 11 Luxury, 12 Premier (5 Safari is refused as a bag item: the Safari Zone's ball is the `safari` choice's `throw = "ball"`, §1.4, and no hub seats a Safari fight) |
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
  nearest living ally seat. A **shared team** (`seats = 2`, §1.3) is two of
  those seats over one party and one bag: a shared bench, battler-order refills
  (one mon left fills one seat), EXP once per party member, owners in outcomes.
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
  after the end of turn, or while its bench is empty (until a Revive, §1.3). The
  **target** seat follows the cart too: the cart sends replacements in *before*
  the Future Sight step (`HandleFaintedMonActions` precedes
  `HandleWishPerishSongOnTurnEnd`), so a hit due on a seat emptied — or re-armed
  by a Revive — this turn waits (turns 0) and lands on the newcomer right after
  the replace phase's switch-ins; a seat left empty drops it (pret skips an
  absent battler; §9.1 for one a Revive refills later).
* **Focus Punch** "is tightening its focus" lines are said right after ordering,
  before any switch (pret `CheckFocusPunch_ClearVarsBeforeTurnStarts`).
* **Running.** 1v1 / coop_pvp: RUN is a concession (always allowed). coop_npc: the
  trainer refusal, no finish. wild / coop_wild: refused at submit while trapped
  (Mean Look, Ingrain, partial trap, Shadow Tag, Arena Trap, Magnet Pull) unless the
  runner holds a Smoke Ball or has Run Away; otherwise pret `TryRunFromBattle`
  against the wild mon: slower runner escapes when
  `(floor(spe*128/foeSpe) + 30*attempts) % 256 > roll(0,255)` (attempts counted per
  battle); a failed attempt is "Can't escape!" and the turn is spent. A successful
  escape ends the fight for everyone (reason `run`, as in BattleSim2). Runs
  resolve before everything else; after a *failed* one the referee orders the
  rest of the turn as usual, where pret runs it in battler order, unsorted
  (§9.1). The solo options move RUN further (§1.2, §1.4: the forfeit, the
  first battles, the veiled GHOST, the Pyramid, the Safari, a `noBattler`
  seat), and a wild seat's own `run` is its flee (§1.5).
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
  ordered chart. A picked move is aimed at the foe the aim stream drew, except a
  Ghost's CURSE, which goes unaimed (below). A wild seat under `wildPick =
  "cart"` or an `ai` picks the cart's way instead (§1.4, §1.5), and a Safari
  monster is never asked.
* **Badge rules** (contracts K1–K3 of [`gen3-badge-rules.md`](gen3-badge-rules.md)).
  Against the computer (`wild`, `coop_wild`, `coop_npc`: `Turn.BADGE_MODES`) side a's
  battlers play by their own trainer's badges, as the engine does
  (`Engine.hasBadge`, `engine.lua:166`, is false only in a link battle):
  * **Boosts**, each ×110/100 floored and read off the battler's own trainer (each
    human brings their own; side b has none). Badge 1 raises the attacker's Attack,
    badge 5 the defender's Defense, badge 7 the attacker's Sp. Atk and the defender's
    Sp. Def. They sit in `Damage.base` after Huge Power / Pure Power and before the
    held items, the abilities and the stat stages (engine `damage.lua:205-217`), so
    every damage path carries them: `calc`, the confusion and disobedience self-hits
    (attacker and defender are one battler, so its badges 1 and 5 both apply),
    Future Sight (fixed at use from the user's) and Spit Up. Badge 3 raises Speed in
    `Field.speed` after the weather doubling and the stage, before Macho Brace and
    paralysis (`engine.lua:221`); every turn-order read, and the auto-pick's speed
    comparison, goes through it. Escape odds keep the raw stat (pret
    `TryRunFromBattle` reads `gBattleMons[].speed`).
  * **Obedience** (`Move.lua` `Bm:_disobey`, the engine's `disobedient`,
    `engine.lua:1291-1349`, pret `IsMonDisobedient` `battle_util.c:3143`) is asked
    after the PP check (`engine.lua:1476`) for a move not already under way — never
    for a called move, a Pursuit on a switching seat or a recharge turn — and only on
    side a against the computer, badges or none. A mon that is not `traded` obeys,
    and so does every mon once its trainer has badge 8. Otherwise the level cap is 10,
    or 30 with badge 2, 50 with badge 4, 70 with badge 6. A Mew (151) or Deoxys (410)
    flagged `unfateful` (§2, K2') has cap 0 whoever owns it, badge 8 or not (the
    engine's rule on every cart, §9.1); one without the flag is any other mon to this
    check, as the engine's nil `fatefulEncounter` is. **At or under the cap it obeys
    and draws nothing.** Above it,
    with `L` the level, the engine's sequence, each draw only when reached:
    1. `roll(0,255)`: obeys when `floor((L + cap) · r / 256) < cap`. Otherwise Rage
       ends, and an asleep mon using Snore / Sleep Talk stops: `ignores_asleep`.
    2. A second `roll(0,255)` under the same test — Focus Punch exempt on FireRed /
       LeafGreen (`family` ≠ `"rse"`, `obedienceFocusPunchExempt`) — picks another
       usable slot (`CheckMoveLimitations`, an empty slot and the chosen slot count as
       unusable; `roll(0,3)` per pick until a usable one). It runs as a called move
       from that slot (`uses_random_move`): its own PP and target, no canceller, and it
       does not count against `MAX_CALL_DEPTH` (it replaces the choice). With no
       usable slot it is a loaf line instead (`roll(0,3)`).
    3. Else a third `roll(0,255)` against `L − cap`. Below it, with no major status,
       not Vital Spirit / Insomnia and no Uproar, the mon falls asleep
       (`falls_asleep`; the sleep counter rolls as any sleep's). Below twice it, it
       hits itself (`hits_itself`): multi-turn moves are cancelled, then confusion's
       typeless 40-power self-hit with its `roll(85,100)` and Focus Band. Otherwise a
       loaf line, one of four by `roll(0,3)`.

    Every stop ends the action as a canceller stop does (the last move is cleared,
    the light move end runs). Each outcome is one `obey` event (§7.2) followed by our
    `msg`.
* **Link rules**: in `1v1` / `coop_pvp`, and for side b in every mode, no badge boosts
  and no disobedience, whatever an entry uploads (`badges`, `family`, `traded`,
  `unfateful` are dropped or never read). In `1v1` / `coop_pvp` no EXP and no Pay Day
  coins either. `exp` events are facts (BattleSim2).
* **Item theft** (pret `MOVE_EFFECT_STEAL_ITEM` and `Cmd_tryswapitems`, the same on
  FireRed / LeafGreen and Emerald; the engine's `secondary.lua` / `special.lua` agree).
  Against the computer (`Turn.BADGE_MODES`: the cart's regular battles) the foe side —
  side b, pret's `B_SIDE_OPPONENT` — takes nothing and swaps nothing. Its Thief / Covet
  still hits, but steals nothing and says nothing: the cart skips the effect before
  Sticky Hold is even asked. Its Trick says "But it failed!" after the Substitute and
  accuracy checks, with no animation. Side a steals and swaps as before, and keeps what
  it steals (the `held` event's `holding`, §7.2). In `1v1` / `coop_pvp` (link fights on
  the cart) either side may. Knock Off has no side rule on the cart and none here. A
  knocked-off mon may neither steal nor swap in any mode (§9.1). The sim reads the mode
  off side a's `badgeRules`, which is true exactly in `Turn.BADGE_MODES`.
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
* **A Ghost's CURSE** is aimed like a `MOVE_TARGET_SELECTED` move (pret
  `battle_controller_player.c:444` offers MOVE_CURSE as SELECTED when the user is a
  Ghost, by its type at the time): the filed `target` (a foe or the ally) is where
  the curse lands, the default is the first living foe (the menu cursor's start), and
  an aim whose battler fell or left moves on as a SELECTED move's does. Its table
  target stays `USER`, so Follow Me and Lightning Rod never pull it
  (`HandleAction_UseMove` reads the table byte). Pressure costs nothing for it
  either: the referee follows the engine's `Ctx:ppReduce` (`engine.lua:309`),
  whose single-target Pressure arm skips a `MOVE_TARGET_USER` row (`:329`). pret's
  `Cmd_ppreduce` may compare the attacker with the target battler instead — which
  a Ghost's curse sets to the foe — so the cart may charge a Pressure foe 2 PP;
  unverified here (no pret source is local). A Curse
  with nothing aimed — called by Sleep Talk / Metronome / Assist, or Encored —
  curses the battler **opposite** the user (`BattleScript_GhostCurse`'s
  `getmovetarget`; the engine's `foeOf`: battler 0 faces 1, 2 faces 3), or the
  nearest standing foe when that one is down. The **auto-pick** (NPC seats, a
  timed-out seat, `autoPick`) files a Ghost's CURSE with no `target`, so it takes
  the same unaimed path: the cart's AI aims every `USER`-row move at itself
  (`battle_controller_opponent.c:1370`; the engine's `ai.lua:353`), and its curse
  lands opposite, never on the random foe the heuristic drew. A non-Ghost CURSE is
  unchanged.
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
| `anim` | `slot`, `side`, `text` = move id, `amount` = 1 on a charge turn, **`target`** (field slot of the move's first target, when it has one), **`spread`** = 1 when one animation covers several targets | said *after* "X used Y!", as the cart does. `text` may instead be a general clip's token (pret `B_ANIM_*`, no "used" line): `TURN_TRAP` (`amount` = the trapping move's number), `FOCUS_PUNCH_SETUP`, `FUTURE_SIGHT_HIT`, `DOOM_DESIRE_HIT`; and, from the solo options (§1.4), `MON_SCARED` / `GHOST_GET_OUT` (the veiled GHOST), `BAIT_THROW` / `ROCK_THROW` / `POKEBLOCK_THROW` (the thrower's slot, `target` the wild slot) and `SAFARI_REACTION` (FireRed / LeafGreen, the wild slot, `amount` 0 watching / 1 angry / 2 eating) |
| `damage` | `slot`, `side`, `amount`, `hp`, `status` (residual token) | a hit on a Substitute is a `damage` with `hp` unchanged, then `sub` 0 when it breaks; spread moves emit one `damage` per target in battler order |
| `drain` | `slot`, `side`, `amount`, `hp` | every heal (drain, Leftovers, berries, Wish, Ingrain, abilities, items) |
| `status` | `slot`, `side`, `status`, `text`, `confused` | as BattleSim2 |
| `stat` | `slot`, `side`, `text`, **`stat`** (`atk def spe spa spd acc eva`), **`stage`** (−6..6, the resulting stage), **`delta`** (−12..12, the change actually applied) | `amount` is **not** sent on Gen 3 (it cannot carry a negative stage through Wire). One event per stat. "Won't go higher/lower" and prevented drops are `msg` (+ `ability` when an ability did it) |
| `send` / `switch` | as BattleSim2 | a switch-in's ability / Spikes / White Herb follow as their own events |
| `item` | `slot`, `side`, `text` = the numeric item id as a string, `amount` (a SAFARI BALL only: the balls left after it) | bag use (no vitamins in Gen 3 battles); a Safari throw of a ball (§1.4) |
| `moves` | `slot`, `side`, `moves` (Gen 3 move rows: `id name num pp maxPp power accuracy type effect chance target priority flags`), `mon` | `mon` present on a PP change of the real party list, absent on a Transform / Mimic overlay |
| `faint`, `turn`, `over`, `wait`, `reconnect`, `chose`, `unchose`, `run`, `team`, `msg` | unchanged | `over` reasons: `ko run catch disconnect timeout` (Roar/Whirlwind and Teleport out of a wild fight end it with `run`, and so do a forfeit, a wild seat's flee and the last SAFARI BALL missed: `outcome().how` tells them apart, §1.6). A wild seat's flee is `run` with `side = "b"`; a Safari monster files `chose` as each turn opens. An Arena loser's `faint` keeps its HP (`team` token `x`). A shared team (§1.3): `team` comes once per party on its first seat's slot; `faint`'s `amount` 1 says the party still has a bench mon (the replace phase's `turn` with a `slot` says which seat is asked) |
| `exp` | `slot`, `species`, `speciesId`, `level`, `participants`, `mon` | as BattleSim2: one per living participant (`mon` = its party index, `participants` = the share count). **New: the holders-only fact** -- `participants` **0** and **no `mon`** -- goes to a seat that fought the fallen foe but has no participant standing (all fainted, e.g. after Explosion), when it still has a living mon: pret `Cmd_getexp` pays the living Exp. Share holders regardless (`viaSentIn` 0 is a `SAFE_DIV`). The client prices it as a knockout with an **empty sentIn set**: `Exp3.split(calculated, 0, viaExpShare)` pays each living holder `floor(floor(calculated / 2) / viaExpShare)` (min 1) and nobody else. **Shared team** (§1.3): participation is per party member, so a mon that fought from both seats is one participant with one fact; its `slot` is the seat it is out on, else (benched) the party's first seat; the holders-only fact comes once per party, on its first seat. |

### 7.2 New kinds

| kind | fields | when |
| --- | --- | --- |
| `ability` | `slot`, `side`, `amount` = ability id (1..77), `text` = ability display name | an ability visibly acted: Intimidate, Drizzle/Drought/Sand Stream, Trace (the traced id), Speed Boost, Rain Dish, Shed Skin, Levitate / Wonder Guard / Volt Absorb / Water Absorb / Flash Fire / Lightning Rod / Soundproof / Damp / Sturdy / Suction Cups / Sticky Hold / Clear Body / Keen Eye / Hyper Cutter / Own Tempo / Oblivious / Insomnia / Vital Spirit / Limber / Immunity / Water Veil / Magma Armor / Inner Focus / Shield Dust-less prevention text, contact procs (Static, Flame Body, Poison Point, Effect Spore, Rough Skin, Cute Charm), Color Change, Synchronize, Natural Cure (no text on the cart; the event only), Liquid Ooze, Forecast, Truant loafing. Always followed or preceded by the `msg` that narrates it |
| `weather` | `text` = `RAIN` / `SUN` / `SAND` / `HAIL`, `amount` = 1 started, 2 continues, 0 ended, `slot`/`side` = the seat that started it (absent otherwise) | move or ability starts, each end-of-turn continue, expiry |
| `held` | `slot`, `side`, `mon` (party index), `amount` = item id that acted, **`holding`** = item id the mon holds once the battle is over (0 = none), `text` = item display name | Leftovers, Shell Bell, every berry, White Herb, Mental Herb, Focus Band (a Choice Band lock is a submit refusal, no event), Quick Claw is silent on the cart (no event), King's Rock is silent (the flinch is the effect), Thief / Covet steal (both mons), Knock Off, Trick (both), Recycle, Smoke Ball fleeing. `holding` is the client's writeback: consumed / stolen items persist after a `wild` / `coop_wild` / `coop_npc` fight (there only side a steals or swaps, §6 item theft); a PvP mode (`1v1` / `coop_pvp`) writes nothing home, as the cart reloads the party after a link battle (`cable_club.c` `LoadPlayerParty`). **Knock Off** is the exception to "now holds": the item is gone for the rest of the fight but comes back afterwards (pret keeps it in the party struct), so its `held` event says `holding` = the knocked-off id; Trick and Thief then fail against it, and the knocked-off mon itself can no longer steal with Thief / Covet (pret `knockedOffMons`: it would lose the item it still owns) |
| `form` | `slot`, `side`, `amount` = Castform form (0 normal, 1 sunny, 2 rainy, 3 snowy) **or** `speciesId` + `text` = species (Transform) | the battler's picture changes |
| `sub` | `slot`, `side`, `amount` = 1 made / 0 faded | draw / remove the substitute doll |
| `ball` | `slot` (thrower), `side`, **`target`** (wild field slot), `amount` = shakes 0..3, or 4 caught, or **-1 dodged** (a GHOST, §1.4; the ball is spent), `text` = ball item id | one per throw, after the `item` event and before the narration ("Oh, no! The POKeMON broke free!" / "Aww! It appeared to be caught!" / "Aargh! Almost had it!" / "Shoot! It was so close, too!" / "Gotcha! X was caught!" / "It dodged the thrown BALL! This POKeMON can't be caught!"). A caught fight ends `over` `catch` with `outcome().caught` = the wild sheet (with its `ball` id) |
| `obey` | `slot`, `side` (the disobeying battler; always side a), `text` = the outcome token (§7.2.1) | contract K3: a side-a mon disobeyed against the computer (§6 badge rules), in its action's place, after the PP check. Always followed by the `msg` that narrates it in our words; the screens phrase the token with the cart's own line(s) instead. No new field: `slot`, `side` and `text` are BattleSim2's |
| `lesson` | `text` = the lesson id: `intro`, `damage`, `stat`, `potion`, `party`, `run`, `win`, `lose` (`Turn.LESSONS`) | solo, `firstBattle = "oak"` (§1.4): one of PROF. OAK's eight moments came true; the screen speaks his page for it. `intro` before turn 1; `damage` after the first side-b HP-bar move (heals included); `stat` after the first "foe's X fell!" from a side-a move; `potion` / `party` when the choice that opens them is accepted; `run` at every refused side-a RUN; `win` / `lose` right before `over` (a draw says `lose`). Every id but `run` once a battle |
| `palace` | `slot`, `side`, `text` = `unable` \| `flavor`, `amount` (`flavor`: 0..3) | solo, `rules.palace` (§1.4): `unable` — "<X> appears incapable of using its power!" (pret `B_MSG_INCAPABLE_OF_POWER`, `battle_util.c:263`), the pick's failure; `flavor` — the half-HP line at a turn's end, `amount` = its index in `gBattlePalaceFlavorTextTable` (`battle_script_commands.c:6384`). Our `msg` follows either; the screen prints the cart's line |
| `arena` | `text` = `start` \| `judge` \| `mind` \| `skill` \| `body` \| `win` \| `draw`; `slot` / `side` on `mind` `skill` `body` `win`; `amount` on `mind` `skill` `body` | solo, `rules.arena` (§1.4): `start` ("Commence battling!", each pairing's first turn), `judge` ("That's it!"), then per category side a then side b with the points awarded (2 / 1 / 0, `battle_arena.c:470`), then `win` (the winner) or `draw`, our result `msg` and each loser's `faint` |
| `wallyThrow` | `slot` (WALLY's field slot), `side` = `"a"` — no seat id: only side a's first seat may throw | solo, `tutorial = "wally"` (§1.2, §1.4; wave 4b's contract C-W): WALLY's `B_ACTION_WALLY_THROW` ran in its turn order (pret em `battle_util.c:625` `HandleAction_WallyBallThrow`). It changes no state and draws nothing; it cancels the turn's *second* action slot (`gActionsByTurnOrder[1] = B_ACTION_FINISHED`), so a slower foe never acts that turn and a faster one already has. No `msg` follows: the recall, WALLY's slide-in and "You throw a BALL now, right?" are the screen's |

#### 7.2.1 The `obey` outcome tokens (K3)

One token per branch of the engine's `disobedient` (`engine.lua:1291-1349`, pret
`IsMonDisobedient`), in the cart's words by `STRINGID` (both carts carry every one;
the screens look them up through the engine's battle text, as for any other line).
The four loaf lines are pret `gInobedientStringIds`, picked by `roll(0,3)` in this
order (`Move.LOAF_LINES`, the engine's `LOAF_TEXT`, `engine.lua:1285`).

| token | engine branch | pret script | the cart's line(s) | what follows the `obey` event and its `msg` |
| --- | --- | --- | --- | --- |
| `ignores_asleep` | asleep and the chosen move is Snore / Sleep Talk (`:1310`) | `BattleScript_IgnoresWhileAsleep` | `STRINGID_PKMNIGNORESASLEEP` | nothing: the action ends |
| `uses_random_move` | the second roll under the cap with a usable slot (`:1314-1325`) | `BattleScript_IgnoresAndUsesRandomMove` | `STRINGID_PKMNIGNOREDORDERS` | the picked move as a called move: its "X used Y!" `msg`, the `moves` PP change at the picked slot, its `anim` / `damage` / effects |
| `falls_asleep` | the third roll under `L − cap` (`:1330-1335`) | `BattleScript_IgnoresAndFallsAsleep` | `STRINGID_PKMNBEGANTONAP`, then `STRINGID_PKMNFELLASLEEP` | the `status` `SLP` event (text "X fell asleep!") and its `msg` — the second cart line |
| `hits_itself` | the third roll's remainder under `L − cap` (`:1337-1345`) | `BattleScript_IgnoresAndHitsItself` | `STRINGID_PKMNWONTOBEY`, then `STRINGID_ITHURTCONFUSION` | the `msg` "It hurt itself in its confusion!" (the second cart line), the `damage` on itself, then any Endure / Focus Band line and `faint` |
| `loafing` | loaf line 1: no usable slot on the second roll's branch (`:1319`), or the third roll's rest (`:1347`) | `BattleScript_MoveUsedLoafingAround`, `B_MSG_LOAFING` | `STRINGID_PKMNLOAFING` | nothing |
| `wont_obey` | loaf line 2 (same two places) | the same, `B_MSG_WONT_OBEY` | `STRINGID_PKMNWONTOBEY` | nothing |
| `turned_away` | loaf line 3 | the same, `B_MSG_TURNED_AWAY` | `STRINGID_PKMNTURNEDAWAY` | nothing |
| `pretend_not_notice` | loaf line 4 | the same, `B_MSG_PRETEND_NOT_NOTICE` | `STRINGID_PKMNPRETENDNOTNOTICE` | nothing |

`hits_itself` and the `wont_obey` loaf line open with the same cart line; only
`hits_itself` is followed by the self-hit. `server/twin_parity.test.js` pins the
eight tokens on both sims.

**Deliberately not new kinds:** stat-change-prevented (a `msg`, plus `ability`
when an ability prevented it), doubles retargeting (the resolved target is
`anim.target`; Lightning Rod / Follow Me are an `ability` event / a `msg`),
side conditions (Reflect, Light Screen, Mist, Safeguard, Spikes — `msg`).

### 7.3 New fields for `Wire.battleEvent` (T7)

`target` (number, field slot 0..FIELD_MAX), `spread` (0/1), `stat` (string, the
seven keys), `stage` (number −6..6), `delta` (number −12..12), `holding`
(number 0..376). The new kinds `ability weather held form sub ball obey lesson
palace arena wallyThrow` live in their own Gen 3 whitelist, `Wire.BATTLE_EVENTS3` (twin:
`sanitize.BATTLE_EVENT_TYPES3`), beside the unchanged Gen 1/2
`Wire.BATTLE_EVENTS`; `Wire.battleEvent` accepts a kind from either for a Gen 3
(or unnamed) reader. `obey` adds no field; its `text` is one of the eight tokens
of §7.2.1, which a sanitiser may hold to that closed set.

### 7.4 The solo-only vocabulary on the wire

Every choice and event of §1.4–§1.6 is Gen 3 only, read by a generation 3 (or,
for events, unnamed) reader and refused or dropped by a Red / Gold one, and none
moved PROTOCOL: no hub seats a fight that needs them (only solo's local
referee does), so a hub never emits these events, and a Gen 3 hub that is sent
one of these choices reads it and its referee refuses it, as it refuses any
action its fight has no arm for. `server/twin_parity.test.js` holds the Lua and
JS sets equal.

| what | Wire (`src/Wire.lua`) ↔ sanitize (`server/lib/sanitize.js`) |
| --- | --- |
| choice `safari` | `BATTLE_ACTIONS3.safari = "throw"`; `throw` must be one of `SAFARI_THROWS3` (`ball bait rock near block`), an unknown one refuses the choice; `block` (a `block` throw only) 1..`POKEBLOCK3_MAX` (40), out of range refuses. `verdict` / `blockName` are not carried |
| choice `wallyThrow` | `BATTLE_ACTIONS3.wallyThrow = true`; no field |
| `fight`'s `unable` (Palace) | not carried: solo files it through `ctx.solo:file3` |
| event `lesson` | `BATTLE_EVENTS3`; `text` read as an id, a mangled one dropped |
| event `palace` | `BATTLE_EVENTS3`; `text` held to `PALACE_TOKENS3` (`unable flavor`) |
| event `arena` | `BATTLE_EVENTS3`; `text` held to `ARENA_TOKENS3` (`start judge mind skill body win draw`) |
| event `wallyThrow` | `BATTLE_EVENTS3`; no field of its own (`slot` / `side` as on every kind; a stray `seat` is dropped) |
| `ball` `amount = -1` | outside `amount`'s 0..`AMOUNT_MAX`, so Wire drops it. Harmless: only solo seats a GHOST, and solo hands its referee's events to the screen without Wire (`SoloBattle` `_feed` → `fight.onEvent`) |
| general `anim` tokens | ordinary `anim` `text` ids |
| sheet `safariFleeRate` / `fateful`, move-row `arenaMind` | not carried (`Wire.battleMon` / the move-row whitelist) |

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

0. **A computer wild seat's choice**, when it is asked (`autoPick` / the clock)
   under `wildPick = "cart"` or a side entry's `ai` (§1.4, §1.5): the cart's
   random move `roll(0,3)` per draw until a usable slot, then `roll(0,1)` for the
   target with two side-a seats (`roll(0,n−1)` for more); the AI's pick
   `roll(0,n−1)` over its best-scored slots. None for Struggle, an Encore, a
   lock-in or a flee, and none for a seat facing nobody (every foe seat
   `noBattler`: it passes). Under `safari` the monster is never asked: as each
   turn opens it rolls `roll(0,99)` against its flee rate, before anything else
   of that turn.
1. **Battle start**: tie groups of the switch-in order (`roll(0,255)` per tied
   group); Trace picking between two or more traceable foes (`roll(0,n−1)`).
2. **Turn start**: Quick Claw `roll(0,65535)` — only when ≥ 2 seats fight (a
   wild seat's flee and WALLY's throw count) and at least one fighting active
   mon holds QUICK_CLAW; then one `roll(0,255)` per group tied on both priority
   and speed.
3. **Runs** (wild modes): `roll(0,255)` for a runner slower than the wild mon (no
   draw for Smoke Ball, Run Away, a runner at least as fast, or a veiled
   GHOST's foe). Under `rules.pyramidRun` every runner but a Smoke Ball holder
   draws `roll(0,255)`, Run Away too; in a trainer fight under `rules.forfeit`
   only a Run Away runner does, before it may forfeit. A wild seat's flee draws
   nothing (it runs in step 6's order).
4. **Switches** (interleaved in battler order with the non-ball bag items, which
   draw nothing): a foe Pursuit aimed at the leaving seat draws like any move
   minus the canceller's and the accuracy draws (§6).
5. **Bag**: balls (after every other item, fastest thrower first) draw up to four
   `roll(0,65535)` — none for a Master Ball, odds > 254, a GHOST's dodge or a
   forced catch. Under `safari` steps 3–6 are the Safari turn instead: the
   trainer's throw (`roll(0,4)` for BAIT / ROCK, up to four `roll(0,65535)` for a
   SAFARI BALL, nothing for GO NEAR, a POKéBLOCK or RUN), then the monster's
   flee or watch, which draws nothing.
6. **Per move** — and a wild seat's flee or WALLY's throw, which draw nothing —
   in execution order, each only when reached (a Battle Palace pick that failed
   its selection check draws only a random-target move's target and, failing
   for `unable`, its sleeper's `roll(0,3)` with no counter or its frozen
   battler's `roll(0,4)`):
   canceller (freeze `roll(0,4)`, a sleeper with no counter `roll(0,3)`,
   confusion `roll(0,1)` [+ self-hit damage `roll(85,100)` + Focus Band
   `roll(0,99)` if held], paralysis `roll(0,3)`, infatuation `roll(0,1)`);
   obedience after the PP check (side a against the computer only: a `traded`
   mon over its badge cap, or a Mew / Deoxys flagged `unfateful`; nothing at or
   under the cap): `roll(0,255)`, then — unless it is a sleeper's Snore / Sleep
   Talk — `roll(0,255)`, then either `roll(0,3)` per pick until a usable slot
   (one `roll(0,3)` for the loaf line when none is) or `roll(0,255)` and then
   the sleep turns `roll(0,3)`, the self-hit's `roll(85,100)` [+ Focus Band
   `roll(0,99)`] or one `roll(0,3)` for the loaf line (§6);
   random target (`roll(0,n−1)` over ≥ 2 living foes for `RANDOM` moves);
   Metronome `roll(1,511)` until a pool move (`roll(1,n)` over the pool after 64
   misses), Sleep Talk / Assist `roll(1,n)`; Protect/Endure streak
   `roll(0, 2^k−1)`; Magnitude `roll(0,99)`; accuracy `roll(1,100)` (none for
   side a under `firstBattle = "oak"` before its lesson, none for anyone under
   `tutorial = "pokedude"`); multi-hit
   `roll(0,3)` (+ `roll(0,3)` when > 1); per strike: Psywave `roll(0,10)`, crit
   `roll(0,n−1)` (not vs Battle/Shell Armor, not for fixed damage, not under
   `firstBattle = "birch"` or `tutorial = "oldMan"` / `"wally"`; under Oak before
   the `damage` lesson and under `"pokedude"` drawn and void), damage
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
| Oak / Pokédude / ghost / Safari / facility branches | present | off in every mediated fight; solo turns each on with its option (§1.4) and follows pret where the engine port differs (`docs/upstream/gen3-spawn-npc.md` addendum D lists those places) |
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
| a Future Sight due on an empty seat | the counter stays (absent battler) | the token is dropped when it comes due there | equivalent while the seat stays empty; if a Revive refills it later (§1.3), the cart's hit still lands on the newcomer and the sim's is gone |
| when a replacement comes in | right after the action that emptied the seat (or, by a Revive, re-armed it): `HandleFaintedMonActions` runs after every action (the engine's `D.afterEach` faint flow), so the newcomer can be hit later that turn, and one bench mon owed to two seats goes to the seat owed first | the replace phase after the end of turn, in battler order (§1.3) | BattleSim2's replace phase (§6) asks every owed seat at once; the same mons stand, the last one possibly in the other seat. Not yet fixed for any fight but the Battle Arena, which replaces at once (§1.4): `docs/plans/gen3-known-gaps.md` §9 |
| a Revive on the mon that last stood in an empty seat | still "in battle": the absent battler keeps its party index (`gBattlerPartyIndexes`; the engine's `replacementCandidates`, `engine.lua:2228`, skips it), so neither seat can send it | an ordinary bench mon: it refills the empty seat | the cart's rule strands a living mon that no seat can field |
| Magnet Pull in doubles | FRLG: foes only; Emerald (`ABILITYEFFECT_CHECK_FIELD_EXCEPT_BATTLER` with no side check): the holder's Steel partner is trapped too | foes only, for every fight | the sim carries no cart version per battle (a fight may mix FireRed and Emerald players) |
| Roar / Whirlwind level check | applied in trainer fights too (`TryDoForceSwitchOut` runs in both branches of `Cmd_forcerandomswitch`, both carts) | the same | kept on purpose: it is the cart's rule, not a wild-only one |
| Fury Cutter after another move | not reset (Gen 3 has no `TryClearRageAndFuryCutter`; `TryClearRageStatuses` clears Rage only) | the same | kept on purpose |
| called-move depth | unbounded, but no cart row set nests deeper than 3 | "But it failed!" past 3 (a disobedient random pick is not a call: it replaces the choice, so Metronome → Assist → Nature Power still reaches the terrain move after one) | robustness: crafted rows must not recurse |
| whose badges a battler reads | the one player's badge flags, for the whole player side (and none in a link battle) | each battler's own trainer's `badges` (K1): each human's in co-op, the owner's on both seats of a shared team; none on side b or in `1v1` / `coop_pvp` | several humans stand on side a, each with their own save; with one trainer it is the cart's rule |
| `traded` / `unfateful` | the party struct: `IsOtherTrainer` on the OT id and name, the fateful-encounter bit | the client's flags on the sheet (K2, K2'), each `true` or absent | the referee holds no save. A client can only make its own mons obey, and only against the computer (obedience never applies in PvP). The OT id compared is the 16-bit visible trainer id, as the engine reads it (`otSecretId` aside), where pret compares the full 32-bit id: a mon with the same TID and OT name but another secret id counts as not traded here |
| a Mew / Deoxys without the fateful bit on FireRed / LeafGreen | pret's FRLG `IsMonDisobedient` may not have the check (unverified: no pret source is local) | cap 0 on every cart, as the engine has it (`engine.lua:1299`, not profile-gated), and on the engine's own trigger: the referee tests `unfateful == true` where the engine tests `fatefulEncounter == false` | the engine is the port this follows ([`gen3-badge-rules.md`](gen3-badge-rules.md) §8); a client sends `unfateful` only for an explicit `false`, never for a nil field (the engine ignores nil and never reads `modernFatefulEncounter`) |
| a Mew / Deoxys whose engine mon has no `fatefulEncounter` field (nil) | pret reads the bit itself: a clear bit is cap 0 | no `unfateful`: it obeys under the ordinary `traded` / badge-cap rule | the engine's reading (nil is not `false`); absent meaning "no rule" keeps a dropped or never-sent flag from turning an obedient mon disobedient |
| the last move after a disobedient stop | pret's move-end bookkeeping for a disobedient action (unverified here) | cleared, as the engine's stop does (`engine.lua:1478-1484`) and as a canceller stop does here | follows the engine |
| Emerald's boost exclusions | no damage boosts in e-reader / secret base / frontier / recorded battles, no badge-3 Speed in frontier / recorded ones | `rules.boosts` (§1.4): solo passes `boosts = false` for every Frontier hall and `{ damage = false }` for a Secret Base; no mediated fight passes it | the e-Reader and recorded battles stay on the cart |
| item theft outside link and regular battles | the foe side may steal / Trick in e-reader, frontier (FRLG: battle tower), secret base and recorded-link fights; Trainer Hill (Emerald) / Trainer Tower (FRLG) bar every side | `rules.theft` (§1.4): `"foe"` for the Frontier and a Secret Base, `"none"` for Trainer Hill and Trainer Tower, solo only; without it, the foe side is barred in `wild` / `coop_wild` / `coop_npc` and free in `1v1` / `coop_pvp` (§6 item theft) | the e-Reader and recorded battles stay on the cart |
| Conversion 2's memory | the actor's `gLastLandedMoves` / `gLastHitByType` are cleared after each of its actions (`HandleAction_ActionFinished`, fr `battle_main.c:4468-4469`, em `battle_util.c:675-676`) | kept until the next landed hit overwrites them (`Move.lua` ~l.2175), so CONVERSION 2 can use an older hit | not yet fixed: `docs/plans/gen3-known-gaps.md` §10 |
| the turn after a failed RUN in a wild double | the runner first, then every other action in battler order, unsorted (`SetActionsAndBattlersTurnOrder`, fr `battle_main.c:3559-3577` battler 0 only, em `:4785-4808` battler 0 or 2) | the runner first, then the usual order (switches and items in battler order, then moves by priority and speed) | not yet fixed: `docs/plans/gen3-known-gaps.md` §10; reachable in co-op against a wild monster |
| a knocked-off mon in `1v1` / `coop_pvp` | may still steal with Thief / Covet, use Trick and be Tricked (the `knockedOffMons` checks are skipped under `BATTLE_TYPE_LINK`) | may not, in every mode | the check guards the `holding` writeback after `wild` / `coop_wild` / `coop_npc` fights (Knock Off keeps `mon.knockedOff`, §7.2: an item stolen by a mon that still owns its knocked-off one would vanish), and it is not split by mode. PvP writes nothing home, so there only the fight itself differs |
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
