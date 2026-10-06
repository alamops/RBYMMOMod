-- The Gen 3 turn machine: choices in, events out, and one party deciding.
--
-- Fork of src/BattleSim2/Turn.lua.  The public API is identical -- `create`,
-- `submitChoice`, `autoPick`, `tick`, `drainEvents`, `disconnect`, `reconnect`,
-- `outcome`, `snapshot` -- and so are the seat model, the phases (choice /
-- replace / resolving / over), the clock, the replace phase, participation and
-- the `exp` facts, the `team` rosters and the forced-lock-in pacing, so a hub
-- and a client switch simulators by generation only.  What is new is what
-- happens inside a turn: Move.lua resolves every action as the Gen 3 engine
-- does (src/core/game3/battle/engine.lua, pret-cited throughout), Residual.lua
-- runs the Gen 3 end of turn, and this file orders the turn and owns the bag,
-- running and catching.  Contracts C4 (sheet) and C5 (events):
-- docs/plans/gen3-battle-sheet.md.
--
-- **The RNG order is the contract.**  One generator per battle (`self.rng`) and
-- the aim stream (`self.aim`, used only by `_autoTarget`).  Every draw is
-- `rng:roll(lo, hi)` (Rng.lua: top bits; a one-value range draws nothing), and
-- the Node twin must draw at exactly these points, in this order:
--
--   0. a computer wild seat's choice, when it is asked (`autoPick` / the clock)
--      under `wildPick = "cart"` or a side entry's `ai` (`_cartWildChoice`):
--      the cart's random move roll(0,3) per draw until a usable slot, then
--      roll(0,1) for the target in a fight with two side-a seats (n-1 for
--      more); the AI's pick roll(0,n-1) over its best-scored slots.  None for
--      Struggle, an Encore, a lock-in, or a flee;
--   1. battle start: one roll(0,255) per speed-tied group of the switch-in order;
--      Trace's pick between two or more traceable foes, roll(0, n-1);
--   2. turn start: Quick Claw roll(0,65535) -- only when two or more seats
--      fight (a wild seat's flee counts) and one of them holds QUICK_CLAW; one
--      roll(0,255) per group of them tied on both priority and speed;
--   3. runs (wild modes): roll(0,255) for a runner slower than the wild mon
--      (no draw for Smoke Ball, Run Away, the faster runner or a veiled
--      GHOST's foe); under `rules.pyramidRun` every runner but a Smoke Ball
--      holder draws roll(0,255), Run Away too.  A wild seat's flee draws
--      nothing (it runs in step 6's order);
--   4. switches (and, interleaved in battler order, the bag items that are not
--      balls -- those draw nothing): any foe Pursuit aimed at the leaving seat
--      draws as a move, minus the canceller's and the accuracy draws;
--   5. bag: balls (after other items, fastest thrower first) draw up to four
--      roll(0,65535) (none for a Master Ball, odds > 254, or a GHOST's dodge);
--   6. moves -- and a wild seat's flee, which draws nothing -- in speed order,
--      each drawing only at the points it reaches:
--      canceller (freeze roll(0,4); a sleeper with no counter roll(0,3); confusion
--      roll(0,1) [+ self-hit roll(85,100) + Focus Band roll(0,99) when held];
--      paralysis roll(0,3); infatuation roll(0,1)); obedience, after the PP
--      check and only for a side-a mon against the computer that is traded and
--      over its badge cap, or a Mew / Deoxys flagged `unfateful` (none at or
--      under the cap): roll(0,255), then -- unless it is a sleeping Snore /
--      Sleep Talk -- roll(0,255), then either roll(0,3) per pick until a usable
--      slot (one roll(0,3) for the loaf line when none is) or roll(0,255) and
--      then sleep turns roll(0,3), the self-hit's roll(85,100) [+ Focus Band
--      roll(0,99)] or one roll(0,3) for the loaf line; random target over two or
--      more living foes roll(0,n-1); Metronome roll(1,511) until a pool move
--      (or roll(1,n) after 64 misses); Sleep Talk / Assist roll(1,n); Protect
--      streak roll(0,2^k-1); Magnitude roll(0,99); accuracy roll(1,100) (none
--      for side a under `firstBattle = "oak"` before its lesson, below);
--      multi-hit roll(0,3) (+ roll(0,3)); per strike Psywave roll(0,10), crit
--      roll(0,n-1) (not vs Battle / Shell Armor, not for fixed damage, not
--      under `firstBattle = "birch"`; under "oak" drawn and void until the
--      `damage` lesson), damage
--      roll(85,100), Present roll(0,255), Focus Band roll(0,99) (holder only),
--      Beat Up's crit (not vs Battle / Shell Armor) + damage per party member;
--      secondary roll(0,99) (not for certain effects); effect-internal draws
--      (sleep turns roll(0,3), confusion turns roll(0,3), trap turns roll(0,3),
--      Tri Attack roll(0,2), Thrash roll(0,1), Uproar roll(0,3), Disable
--      roll(0,3), Encore roll(0,3), Spite roll(0,3), Conversion / Conversion 2
--      roll(1,n), Roar's level check roll(0,255) and pick roll(1,n), OHKO
--      roll(1,100)); move end: Effect Spore roll(0,9) then roll(0,3) until
--      non-zero, Static / Flame Body / Poison Point / Cute Charm roll(0,2),
--      King's Rock roll(0,99) -- after EVERY strike of a multi-hit, Triple Kick
--      or Beat Up, plus King's Rock once more at a multi-hit's close; after the
--      action, Trace draws as in 1 (the post-action item pass is the cart's
--      moveTurn pass: no berry there draws);
--   7. end of turn: one roll(0,255) per tied group of the re-sort, then the
--      phases in order (Shed Skin roll(0,2), confusion-berry turns, Starf-type
--      berry roll(0,4) until raisable, Thrash fatigue roll(0,3), Yawn's sleep
--      roll(0,3), Future Sight accuracy roll(1,100) + roll(85,100) [+ Focus
--      Band roll(0,99)] -- a hit due on a seat emptied this turn draws them in
--      the replace phase instead, after the switch-ins).
--
-- Nothing else rolls.  A battle replays from its seed plus the choice log.
--
-- **Policies** (BattleSim2's, kept unless Gen 3 differs -- each written down in
-- docs/plans/gen3-battle-sheet.md §6):
--   * Seats, field slots and the replace phase are BattleSim2's.  A fight with
--     more than one seat on a side is a doubles fight (spread moves, doubled
--     screens, Helping Hand, Follow Me, Lightning Rod, Pressure counting).
--   * A shared team (a side entry with `seats = 2`, the cart's own double
--     battle) is two seats over ONE party and ONE bag: seat 2 is
--     `<playerId>#2`, both carry `owner`.  Neither seat benches the other's
--     active mon or the one it has claimed this turn; emptied seats refill in
--     battler order, so with one mon left only one seat is filled, and a
--     Revive refills a seat left empty; a mon earns EXP once per owner;
--     outcomes, `waiting` and `team` name owners.
--   * Order: runs, then switches and bag items together in battler order (each
--     switch after any Pursuit aimed at it), balls after them by speed, then
--     moves by priority then speed, Quick Claw first in its bracket; ties: one
--     roll(0,255) per group, >= 128 reverses.
--   * End of turn re-sorts the standing battlers by this turn's priority and
--     speed (the cart's ENDTURN_ORDER), not BattleSim2's field order.
--   * Running: 1v1 / coop_pvp concede; coop_npc refuses; wild modes run pret's
--     TryRunFromBattle and a failure spends the turn; trapped runs and switches
--     are refused at submit.  A wild seat's own `run` is the cart's opponent
--     RUN instead (pokefirered/src/battle_main.c:4317 HandleAction_Run): a turn
--     action sorted with the moves at priority 0, never refused at submit,
--     stopped only by a partial trap or Mean Look / Block / Spider Web when it
--     executes ("can't escape", the turn spent), else the fight ends `flee`.
--   * Forced lock-in (no menu): recharge, a two-turn release, Bide, Thrash-type
--     rampage, Uproar, Rollout.  A partial trap does not lock the victim.
--   * Badge rules (docs/plans/gen3-badge-rules.md K1-K3): against the computer
--     (M.BADGE_MODES: wild / coop_wild / coop_npc) side a's battlers carry their
--     own trainer's badges -- the x1.1 stat boosts (Damage.base, Field.speed) --
--     and obey by the cart's rule (Move.lua Bm:_disobey: a traded mon over the
--     badge level cap may not).  Link rules in 1v1 / coop_pvp and for side b
--     everywhere: no badge boosts, no disobedience, whatever an entry uploads;
--     and no exp and no Pay Day coins in 1v1 / coop_pvp (a won wild / coop_npc
--     fight reports side a's coins as `outcome().payDay`).  King's Rock keeps the
--     cart's battler-0 quirk.
--   * Timeout / NPC auto-pick: BattleSim2's heuristic on Gen 3 ids; a Ghost's
--     CURSE goes unaimed, as the cart's AI files it.  A wild seat picks as the
--     cart's opponent controller does when the create options ask for it
--     (`wildPick = "cart"`, a side entry's `ai`): `_cartWildChoice`.
--   * How a fight ended (contract C3 of docs/plans/gen3-solo-remaining-
--     fights.md): `outcome().how` is one of
--     M.HOW -- ko, run (RUN, Smoke Ball, Run Away, Poke Doll / Fluffy Tail, a
--     link concession), flee (a wild seat's own RUN), teleport (TELEPORT),
--     roar (ROAR / WHIRLWIND out of a wild fight), catch, forfeit (RUN under
--     `rules.forfeit`), judge (later: the Arena) -- absent for a disconnect or
--     a timeout; `outcome().by` is the side ("a" | "b") whose action ended it
--     (the KO side's winner; nil on a draw).  `reason` keeps its meaning.
--   * The solo-only create options (none of them is ever on a hub's wire;
--     absent, every fight is the one it always was):
--       wildPick = "cart"            the cart's random wild move (above);
--       firstBattle = "oak"|"birch"  the FireRed / LeafGreen lab rival
--         (pokefirered/src/battle_script_commands.c:1007, :1200; `lesson`
--         events at M.LESSONS) or Emerald's Birch rescue (pokeemerald
--         battle_script_commands.c:1281 no crits, battle_main.c:4078 no RUN);
--       ghost = "veiled"|"unveiled"  Pokemon Tower (wild modes only): veiled,
--         every move of both sides is cancelled (battle_util.c:1451), RUN
--         always works (battle_main.c:4252), no sand / hail chip on the ghost
--         (battle_script_commands.c:7218), no Intimidate / Trace
--         (battle_util.c:1698); both, a ball is dodged and spent (:9473);
--       rules = { bag, forfeit, exp, boosts = { damage, speed }, obedience,
--         theft, soulDew, pyramidRun, pyramidBag } -- the facility rules
--         (M.copyRules);
--     and three side-entry fields: `ai = "roamer" | "firstBattle"` (a wild
--     entry's AI script), `spare = true` (Steven: the side is down when every
--     other entry is), `bagFrom = "<playerId>"` (spend another entry's bag:
--     one pool, as a pair's A and B share A's items).
--
-- Nothing here raises.  Bad input is refused with nil-plus-reason from `create`
-- or a plain `false` from `submitChoice`.
--
-- No love, no engine modules, no mod facade.

local need = ...

local Rng       = need("BattleSim3/Rng")
local Types     = need("BattleSim3/Types")
local Damage    = need("BattleSim3/Damage")
local Status    = need("BattleSim3/Status")
local Abilities = need("BattleSim3/Abilities")
local Items     = need("BattleSim3/Items")
local Field     = need("BattleSim3/Field")
local Catch     = need("BattleSim3/Catch")
local Effects   = need("BattleSim3/Effects")
local Move      = need("BattleSim3/Move")
local Residual  = need("BattleSim3/Residual")
local Events    = need("BattleSim3/events")

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.VERSION = 1
M.GENERATION = 3

M.MONS_PER_PARTY      = 6     -- Config.BATTLE_MON_MAX
M.FIGHTERS_PER_SIDE   = 3     -- Config.COOP_SIDE
M.SEATS_PER_PARTY     = 2     -- a shared team fields at most two (the cart's double)
M.CHOICE_TIMEOUT      = 60    -- Config.BATTLE_CHOICE_TIMEOUT
M.RECONNECT_GRACE     = 60    -- Config.BATTLE_RECONNECT_GRACE
M.RESOLVE_TIMEOUT     = 30    -- Config.BATTLE_RESOLVE_TIMEOUT

M.TIE_BREAK_ROLL = 128
M.AIM_SEED_OFFSET = 1597334677

M.MODES = {
  ["1v1"] = true, coop_npc = true, coop_pvp = true, wild = true, coop_wild = true,
}
M.SIDES = { "a", "b" }

-- The fights against the computer -- the cart's non-link battles -- in which
-- side a keeps its trainers' badge rules (docs/plans/gen3-badge-rules.md K1):
-- the stat boosts and obedience.  1v1 / coop_pvp are link battles on the cart
-- (Engine.hasBadge and IsMonDisobedient both return early under
-- BATTLE_TYPE_LINK), so neither applies there whatever an entry uploads, and
-- side b is never the player's side.  The same three modes as EXP_MODES below.
M.BADGE_MODES = { wild = true, coop_wild = true, coop_npc = true }

-- The cart families whose obedience rules differ (engine BattleProfile.family):
-- FireRed / LeafGreen exempt Focus Punch from the random-move branch
-- (`obedienceFocusPunchExempt`, battle/profile.lua:34), Emerald does not
-- (profiles/emerald/battle.lua:39).  An entry without `family` plays by the
-- engine's default profile, "frlg".
M.FAMILIES = { frlg = true, rse = true }

-- Gen 3 statuses ride the wire in their own tokens, both ways.
M.STATUS_FROM_WIRE = { SLP = "SLP", PSN = "PSN", BRN = "BRN", FRZ = "FRZ", PAR = "PAR", TOX = "TOX" }
M.STATUS_TO_WIRE = M.STATUS_FROM_WIRE

local ACTIONS = { fight = true, item = true, switch = true, run = true, cancel = true }

-- Contract C3 (docs/plans/gen3-solo-remaining-fights.md): `outcome().how`.
-- `balls` (out of Safari Balls) and `judge` (the Arena) belong to later waves;
-- they are named here so the vocabulary is closed once.
M.HOW = {
  ko = true, run = true, flee = true, teleport = true, roar = true, catch = true,
  forfeit = true, balls = true, judge = true,
}

-- `firstBattle`: the FireRed / LeafGreen rival in Oak's lab (BATTLE_TYPE_FIRST_
-- BATTLE with the Oak / Old Man controller) and Emerald's rescue of Birch.
M.FIRST_BATTLES = { oak = true, birch = true }

-- PROF. OAK's eight lesson points, the `lesson` event's ids (`_lesson`), each
-- the cart's own moment (pokefirered/src/battle_controller_oak_old_man.c,
-- battle_controller_opponent.c:304, party_menu.c:5834):
--   intro   "Oh, for Pete's sake..." -- before the first action menu
--   damage  "Inflicting damage on the foe..." -- the foe's HP bar first moves
--           (flag 1: from now on the player's moves can miss by power, crits
--           count)
--   stat    "Lowering the foe's stats..." -- the first "foe's X fell!" a
--           side-a move prints (flag 2: the player's moves can miss)
--   potion  "Keep your eyes on your POKeMON's HP..." -- the first POTION chosen
--           (flag 4)
--   party   the first party menu (flag 8): the referee sees it at the first
--           filed switch or party-targeted bag item; a screen that opens the
--           menu earlier says it then and ignores the repeat
--   run     "No! There's no running away from a TRAINER..." -- every RUN
--           (refused at submit; the cart keeps the action menu)
--   win     "Hm! Excellent!..." -- after the prize line (the screen's)
--   lose    "Hm... How disappointing..." -- after the rival's win text (a draw
--           too: B_OUTCOME_DREW runs HandleEndTurn_BattleLost)
-- Every id but `run` is spoken once a battle.
M.LESSONS = { "intro", "damage", "stat", "potion", "party", "run", "win", "lose" }
M.ITEM_POTION = 13   -- pret ITEM_POTION (the Oak controller's flag-4 test)

-- `ghost` (FireRed / LeafGreen Pokemon Tower, BATTLE_TYPE_GHOST): without the
-- SILPH SCOPE the GHOST is veiled; with it, unveiled.
M.GHOSTS = { veiled = true, unveiled = true }

-- A wild side entry's AI script: AI_Roaming (roamers) or AI_FirstBattle
-- (Emerald's Birch rescue) -- the only wild battles the cart's opponent
-- controller runs an AI for (pokefirered/src/battle_controller_opponent.c:1355).
M.WILD_AI = { roamer = true, firstBattle = true }

-- How many `Random() & 3` draws `_cartWildChoice` makes before it settles on
-- the first usable slot: the cart loops until it hits one; a referee never
-- freezes.  Unreachable with a working generator (each draw is >= 1/4 usable).
M.WILD_PICK_CAP = 256

local E = Effects.E
local T = Move.TARGET

local function maxFighters(mode, side)
  if mode == "coop_wild" then
    return (side == "a") and M.FIGHTERS_PER_SIDE or 1
  end
  if mode == "1v1" or mode == "wild" then return 1 end
  return M.FIGHTERS_PER_SIDE
end

local WILD_SIDE = "b"

local function isWildMode(mode)
  return type(mode) == "string" and mode:find("wild", 1, true) ~= nil
end
M.isWildMode = isWildMode

local function isWildSeat(mode, fighter)
  return fighter ~= nil and fighter.side == WILD_SIDE and isWildMode(mode)
end

-- RUN finishes the fight in wild modes (a real escape attempt) and 1v1 /
-- coop_pvp (a concession); everywhere else it is the trainer refusal.
local function runEndsBattle(mode)
  return isWildMode(mode) or mode == "1v1" or mode == "coop_pvp"
end
M.runEndsBattle = runEndsBattle

-- One bit of a pret MOVE_TARGET_* byte.
local function hasBit(value, bit)
  return floor(value / bit) % 2 == 1
end

-- ------------------------------------------------------------------
-- coercion (the C4 sheet)
-- ------------------------------------------------------------------

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function str(value)
  if type(value) == "string" and value ~= "" then return value end
  return nil
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function copyMove(raw)
  if type(raw) ~= "table" then return nil end
  local pp = max(0, int(raw.pp, 0))
  return {
    id       = str(raw.id) or "MOVE",
    name     = str(raw.name),
    num      = max(0, int(raw.num, 0)),
    pp       = pp,
    maxPp    = max(pp, int(raw.maxPp, pp)),
    power    = max(0, int(raw.power, 0)),
    accuracy = max(0, int(raw.accuracy, 100)),
    type     = clamp(int(raw.type, 0), 0, 31),
    effect   = clamp(int(raw.effect, 0), 0, 255),
    chance   = clamp(int(raw.chance, 0), 0, 100),
    target   = max(0, int(raw.target, 0)),
    priority = clamp(int(raw.priority, 0), -7, 7),
    flags    = max(0, int(raw.flags, 0)),
  }
end
M.copyMove = copyMove

-- A pool entry: the packed "num:effect:power:type:accuracy:pp:chance:target:
-- priority:flags:id" string (sheet doc §3.3) or a row table.
local function parsePoolEntry(raw)
  if type(raw) == "table" then return copyMove(raw) end
  if type(raw) ~= "string" then return nil end
  local parts = {}
  for piece in (raw .. ":"):gmatch("([^:]*):") do parts[#parts + 1] = piece end
  if #parts ~= 11 then return nil end
  local nums = {}
  for i = 1, 10 do
    local n = tonumber(parts[i])
    if not n or n ~= floor(n) then return nil end
    nums[i] = n
  end
  local id = parts[11]
  if not id:match("^[%w_%-]+$") or #id > 40 then return nil end
  return copyMove({
    num = nums[1], effect = nums[2], power = nums[3], type = nums[4], accuracy = nums[5],
    pp = nums[6], maxPp = nums[6], chance = nums[7], target = nums[8], priority = nums[9],
    flags = nums[10], id = id,
  })
end
M.parsePoolEntry = parsePoolEntry

local function copyTypes(raw)
  if type(raw) ~= "table" then return { 0 } end
  local out = {}
  for i = 1, min(2, #raw) do out[i] = clamp(int(raw[i], 0), 0, 31) end
  if #out == 0 then return { 0 } end
  if out[2] == out[1] then out[2] = nil end
  return out
end

local function copyNumbers(raw)
  if type(raw) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(raw) do
    if type(k) == "string" and tonumber(v) then out[k] = int(v, 0) end
  end
  return out
end

local function copyMon(raw, fallback)
  if type(raw) ~= "table" then return nil end
  local stats = type(raw.stats) == "table" and raw.stats or {}
  local maxHp = max(1, int(raw.maxHp, 1))
  local hp = (raw.hp == nil) and maxHp or max(0, int(raw.hp, 0))
  if hp > maxHp then hp = maxHp end
  local status = Status.normalise(str(raw.status))
  local moves = {}
  if type(raw.moves) == "table" then
    for i = 1, #raw.moves do
      if #moves >= 4 then break end
      local mv = copyMove(raw.moves[i])
      if mv then moves[#moves + 1] = mv end
    end
  end
  local hp3 = nil
  if type(raw.hiddenPower) == "table" then
    hp3 = { type = clamp(int(raw.hiddenPower.type, 0), 0, 17),
            power = clamp(int(raw.hiddenPower.power, 70), 1, 255) }
  end
  local beatUp = nil
  if type(raw.beatUp) == "table" then
    beatUp = { atk = max(1, int(raw.beatUp.atk, 50)), def = max(1, int(raw.beatUp.def, 50)) }
  end
  local gender = raw.gender
  if gender ~= "M" and gender ~= "F" then gender = "U" end
  local out = {
    species = str(raw.species) or "?",
    speciesId = str(raw.speciesId),
    speciesNum = max(0, int(raw.speciesNum, 0)),
    slot = max(0, int(raw.slot, max(0, int(fallback, 0)))),
    level = clamp(int(raw.level, 1), 1, 100),
    hp = hp, maxHp = maxHp,
    stats = {
      atk = max(1, int(stats.atk, 1)), def = max(1, int(stats.def, 1)),
      spe = max(1, int(stats.spe, 1)), spa = max(1, int(stats.spa, 1)),
      spd = max(1, int(stats.spd, 1)),
    },
    types = copyTypes(raw.types),
    ability = clamp(int(raw.ability, 0), 0, 255),
    abilityName = str(raw.abilityName),
    heldItem = max(0, int(raw.heldItem, 0)),
    holdEffect = max(0, int(raw.holdEffect, 0)),
    holdParam = max(0, int(raw.holdEffectParam or raw.holdParam, 0)),
    itemName = str(raw.itemName),
    gender = gender,
    friendship = clamp(int(raw.friendship, 70), 0, 255),
    weight = max(0, int(raw.weight, 0)),
    nature = clamp(int(raw.nature, 0), 0, 24),
    hiddenPower = hp3,
    beatUp = beatUp,
    status = status,
    sleepTurns = (status == "SLP") and int(raw.sleepTurns, nil) or nil,
    catchRate = clamp(int(raw.catchRate, 255), 0, 255),
    moves = moves,
    ivs = copyNumbers(raw.ivs),
    evs = copyNumbers(raw.evs),
    personality = int(raw.personality, nil),
    otId = int(raw.otId, nil),
    -- K2' (docs/plans/gen3-battle-sheet.md §2): obedience's two facts about the
    -- mon, decided by its owner's client.  `traded`: the OT id or OT name is not
    -- this player's (pret IsOtherTrainer, engine Engine.isTradedMon);
    -- `unfateful`: the engine mon's `fatefulEncounter` is explicitly false (the
    -- only value engine.lua:1299 acts on), read for Mew and Deoxys only.  true or
    -- absent; absent never triggers the Mew / Deoxys rule.
    traded = (raw.traded == true) or nil,
    unfateful = (raw.unfateful == true) or nil,
  }
  if out.heldItem == 0 then out.holdEffect, out.holdParam = 0, 0 end
  return out
end
M.copyMon = copyMon

-- A bag sheet: { { id, count, name? } } or { [id] = count }, numeric ids.
local function copyBag(raw)
  if type(raw) ~= "table" then return nil end
  local out, names, any = {}, {}, false
  local function put(id, count, name)
    local n = Items.idOf(id)
    local c = int(count, 0)
    if not n or not c or c < 1 then return end
    out[n] = (out[n] or 0) + c
    if str(name) then names[n] = name end
    any = true
  end
  if #raw > 0 or raw[1] ~= nil then
    for _, entry in ipairs(raw) do
      if type(entry) == "table" then put(entry.id, entry.count, entry.name) end
    end
  else
    for id, count in pairs(raw) do put(id, count) end
  end
  if not any then return nil end
  return out, names
end

-- The facility rules (contract C3 of docs/plans/gen3-solo-remaining-fights.md),
-- normalised: a key absent, or holding anything but the value below, is
-- today's behaviour.  The carts these rules come from:
--   bag = false        no item from the bag, either side (pokeemerald battle_
--                      main.c:4221 FRONTIER_NO_PYRAMID | EREADER, "Items can't
--                      be used now." -- the screen's line); refused at submit
--   forfeit = true     a RUN in a trainer fight is a forfeit (pokeemerald
--                      battle_main.c:4321 asks, battle_util.c:448 always gets
--                      away, :5058 B_OUTCOME_FORFEITED): `how = "forfeit"`, the
--                      runner's side loses, traps or not
--   exp = false        no EXP (battle_script_commands.c:3270): no `exp` facts
--   boosts = { damage = false, speed = false } (boosts = false: both) -- no
--                      badge stat boosts (pokemon.c:3407 / battle_main.c:4640)
--   obedience = false  no disobedience but the Mew / Deoxys rule
--                      (battle_util.c:3924, inside the fateful arm)
--   theft = "foe"      the foe may Thief / Covet / Trick and the knocked-off
--                      check is lifted (FRONTIER, EREADER, SECRET_BASE,
--                      battle_script_commands.c:2746 / :9192); "none": nobody
--                      may (TRAINER_HILL, FRLG TRAINER_TOWER, :2740 / :9193)
--   soulDew = false    SOUL DEW inert (pokemon.c:3187, FRONTIER)
--   pyramidRun = n     the Battle Pyramid's run multiplier: a wild RUN, Run
--                      Away included, always rolls speed * n / foe speed + 30
--                      * tries (pokeemerald battle_util.c:427-458)
--   pyramidBag = true  the bag uploaded is the Pyramid bag: nothing changes
--                      here (the client writes the spends back)
local function copyRules(raw)
  local r = {}
  if type(raw) ~= "table" then return r end
  r.noBag = (raw.bag == false) or nil
  r.forfeit = (raw.forfeit == true) or nil
  r.noExp = (raw.exp == false) or nil
  local boosts = raw.boosts
  if boosts == false then
    r.noDamageBoost, r.noSpeedBoost = true, true
  elseif type(boosts) == "table" then
    r.noDamageBoost = (boosts.damage == false) or nil
    r.noSpeedBoost = (boosts.speed == false) or nil
  end
  r.noObedience = (raw.obedience == false) or nil
  if raw.theft == "foe" or raw.theft == "none" then r.theft = raw.theft end
  r.noSoulDew = (raw.soulDew == false) or nil
  local mult = int(raw.pyramidRun, nil)
  if mult and mult >= 1 then r.pyramidRun = clamp(mult, 1, 255) end
  r.pyramidBag = (raw.pyramidBag == true) or nil
  return r
end
M.copyRules = copyRules

-- ------------------------------------------------------------------
-- the battle
-- ------------------------------------------------------------------

local Battle = {}
Battle.__index = Battle
M.Battle = Battle

Move.install(Battle)
Residual.install(Battle)

Battle.TIE_BREAK_ROLL = M.TIE_BREAK_ROLL

local function firstLiving(mons, skip)
  for i = 1, #mons do
    if mons[i].hp > 0 and i ~= skip then return i end
  end
  return nil
end

-- The seat's standing mon (the party table), or nil.
local function activeMon(fighter)
  local b = fighter.b
  if b and b.mon.hp > 0 then return b.mon end
  return nil
end

local function partyIndexOf(fighter, wireSlot)
  for i = 1, #fighter.mons do
    if fighter.mons[i].slot == wireSlot then return i end
  end
  return wireSlot + 1
end

function Battle:_newBattler(fighter, index)
  local mon = fighter.mons[index]
  local t1, t2 = mon.types[1], mon.types[2]
  local b = {
    fighter = fighter, slot = fighter.slot, side = fighter.side, mon = mon,
    partyIndex = index, speciesNum = mon.speciesNum,
    type1 = t1, type2 = (t2 ~= nil and t2 ~= t1) and t2 or nil,
    ability = Abilities.nameOf(mon.ability), abilityName = mon.abilityName,
    stats = mon.stats, moves = mon.moves, overlay = false,
    stages = { atk = 0, def = 0, spe = 0, spa = 0, spd = 0, acc = 0, eva = 0 },
    isFirstTurn = 2, toxicCounter = 0,
    -- K1: its trainer's badges (nil off side a, in a link mode, or with none).
    badges = fighter.badges,
    -- The facility rules that live in the formulas (copyRules): no damage
    -- badge boosts (Damage.base), no speed badge boost (Field.speed), an inert
    -- SOUL DEW (Damage.base, attacker and defender alike).
    noDamageBadges = self.rules.noDamageBoost,
    noSpeedBadge = self.rules.noSpeedBoost,
    noSoulDew = self.rules.noSoulDew,
  }
  return b
end

function Battle:_sendEvent(fighter)
  local b = fighter.b
  local mon = b.mon
  self:_emit("send", {
    slot = fighter.slot, side = fighter.side, hp = mon.hp, maxHp = mon.maxHp,
    text = mon.species, speciesId = mon.speciesId, level = mon.level,
    mon = fighter.active - 1, status = mon.status,
    confused = (int(b.confusion, 0) > 0) and 1 or nil,
  })
end

-- opts:
--   id, mode, seed, typeTable (alias chart), specialTypes, movePool, terrain,
--   weather, underwater, choiceTimeout, reconnectGrace, resolveTimeout, now,
--   wildPick?, firstBattle?, ghost?, rules? (the header's solo-only options),
--   sides = { a = { { playerId, name, mons, bag, seats?, badges?, family?,
--                     spare?, bagFrom? } },
--             b = { { ..., ai? } } }
--
-- `ai` ("roamer" | "firstBattle") is read only on a wild seat (side b of a
-- wild mode) and dropped elsewhere, silently; `spare = true` takes the entry
-- out of its side's standing count (`_sideAlive`) -- a side of nothing but
-- spares is refused; `bagFrom` names another entry on the same side whose bag
-- this one spends (the same tables) -- an unknown id, the other side, the
-- entry itself or a lender that borrows in turn is refused.
--
-- `badges` (K1: a list of badge numbers, as strings or numbers, or a set) and
-- `family` ("frlg" | "rse") are read only for side a in M.BADGE_MODES and
-- dropped everywhere else; each fighter keeps `badgeRules` (true there),
-- `badges` (Damage.badgeSet) and `family`.
--
-- `seats = 2` makes one entry a shared team: two fighters over the same `mons`
-- and `bag` tables -- seat 1 keeps `playerId`, seat 2 is `playerId .. "#2"`,
-- both have `owner = playerId` -- which is how the cart fields one trainer's
-- party in a double battle (gPlayerParty / gEnemyParty behind battlers 0 and
-- 2, or 1 and 3).  The leads are the first two living mons; with only one,
-- seat 2 starts empty.  Every fighter carries `owner` and `seats` (the list of
-- seats over its party, in slot order: itself alone without `seats = 2`).
function M.create(opts)
  if type(opts) ~= "table" then return nil, "battle needs an options table" end

  local mode = M.MODES[opts.mode] and opts.mode or "1v1"

  local self = setmetatable({
    id             = str(opts.id) or "battle",
    mode           = mode,
    seed           = int(opts.seed, 0),
    rng            = Rng.new(int(opts.seed, 0)),
    aim            = Rng.new(int(opts.seed, 0) + M.AIM_SEED_OFFSET),
    typeTable      = Types.copyTable(opts.typeTable or opts.chart),
    specialTypes   = nil,
    pool           = nil,
    terrain        = clamp(int(opts.terrain, Field.DEFAULT_TERRAIN), 0, 9),
    initialWeather = Field.kind(opts.weather),
    underwater     = opts.underwater == true,
    field          = { weather = nil, weatherTurns = 0 },
    sides          = { a = Field.newSide(), b = Field.newSide() },
    choiceTimeout  = max(0, int(opts.choiceTimeout, M.CHOICE_TIMEOUT)),
    reconnectGrace = max(0, int(opts.reconnectGrace, M.RECONNECT_GRACE)),
    resolveTimeout = max(0, int(opts.resolveTimeout, M.RESOLVE_TIMEOUT)),
    now            = max(0, int(opts.now, 0)),
    phase          = "choice",
    turn           = 1,
    seq            = 0,
    buffer         = {},
    pendingExp     = {},
    fighters       = {},
    byId           = {},
    bySide         = { a = {}, b = {} },
    order          = {},
    result         = nil,
    resolveDeadline = nil,
    fleeAttempts   = 0,
    payDay         = { a = 0, b = 0 },  -- pret gPaydayMoney, per side (Effects PAYDAY)
    usedHeldItems  = {},                -- Recycle's memory, per field slot (Items.consume)
    -- The solo-only options (header; contract C3).
    wildPick       = (opts.wildPick == "cart") and "cart" or nil,
    firstBattle    = M.FIRST_BATTLES[opts.firstBattle] and opts.firstBattle or nil,
    ghost          = (isWildMode(mode) and M.GHOSTS[opts.ghost]) and opts.ghost or nil,
    rules          = copyRules(opts.rules),
    lessons        = {},                -- the Oak lessons already spoken (`_lesson`)
    mover          = nil,               -- the battler whose action is running (`_fightAction`)
  }, Battle)

  if type(opts.specialTypes) == "table" then
    local set = {}
    for i = 1, #opts.specialTypes do set[clamp(int(opts.specialTypes[i], 0), 0, 31)] = true end
    self.specialTypes = set
  end
  if type(opts.movePool) == "table" then
    local pool, any = {}, false
    for i = 1, #opts.movePool do
      local row = parsePoolEntry(opts.movePool[i])
      if row and row.num > 0 and not pool[row.num] then pool[row.num] = row; any = true end
    end
    if any then self.pool = pool end
  end

  local sides = type(opts.sides) == "table" and opts.sides or {}
  for _, side in ipairs(M.SIDES) do
    local roster = type(sides[side]) == "table" and sides[side] or {}
    if #roster == 0 then return nil, "side " .. side .. " has nobody on it" end
    if #roster > maxFighters(mode, side) then
      return nil, "side " .. side .. " has more fighters than " .. mode .. " allows"
    end
    if mode == "coop_wild" and side == "a" and #roster < 2 then
      return nil, "side a has fewer fighters than coop_wild allows"
    end
    for index = 1, #roster do
      local entry = roster[index]
      if type(entry) ~= "table" then return nil, "side " .. side .. " has a malformed fighter" end
      local playerId = str(entry.playerId)
      if not playerId then return nil, "a fighter on side " .. side .. " has no playerId" end
      if self.byId[playerId] then return nil, "duplicate playerId " .. playerId end
      local seats = (entry.seats == nil) and 1 or int(entry.seats, 0)
      if seats < 1 or seats > M.SEATS_PER_PARTY then
        return nil, playerId .. " has a bad seat count"
      end
      local bucket = self.bySide[side]
      if #bucket + seats > maxFighters(mode, side) then
        return nil, "side " .. side .. " has more fighters than " .. mode .. " allows"
      end
      for seat = 2, seats do
        if self.byId[playerId .. "#" .. seat] then
          return nil, "duplicate playerId " .. playerId .. "#" .. seat
        end
      end
      local mons = {}
      if type(entry.mons) == "table" then
        for i = 1, #entry.mons do
          if #mons >= M.MONS_PER_PARTY then break end
          local mon = copyMon(entry.mons[i], #mons)
          if mon then mons[#mons + 1] = mon end
        end
      end
      if #mons == 0 then return nil, playerId .. " brought no monsters" end
      local bag, bagNames = copyBag(entry.bag)
      bagNames = bagNames or {}
      -- K1: the cart's badge rules belong to the player's side of a fight against
      -- the computer and nowhere else -- a link mode or side b drops whatever the
      -- entry uploaded, silently (bad badges are not a reason to refuse a fight).
      -- Both seats of a shared team are the one trainer's.
      local badgeRules = side == "a" and M.BADGE_MODES[mode] == true
      local badges, family = nil, nil
      if badgeRules then
        badges = Damage.badgeSet(entry.badges)
        family = M.FAMILIES[entry.family] and entry.family or "frlg"
      end
      -- The side-entry fields of contract C3 (the header).
      local ai = (side == WILD_SIDE and isWildMode(mode) and M.WILD_AI[entry.ai]) and entry.ai or nil
      local spare = (entry.spare == true) or nil
      local bagFrom = str(entry.bagFrom)
      local party, lead = {}, nil
      for seat = 1, seats do
        -- The cart's leads: the first usable mon, then the next one after it
        -- (pokefirered/src/battle_controllers.c SetBattlePartyIds); none left,
        -- and the seat starts empty (pret's absent battler).
        local active = nil
        if seat == 1 then lead = firstLiving(mons); active = lead
        elseif lead then active = firstLiving(mons, lead) end
        local fighter = {
          playerId = (seat == 1) and playerId or (playerId .. "#" .. seat), owner = playerId,
          seats = party, name = str(entry.name) or playerId, side = side,
          index = #bucket + 1, slot = Events.fieldSlot(side, #bucket + 1), mons = mons,
          bag = bag, bagNames = bagNames, active = active,
          connected = true, graceEndsAt = nil, choice = nil, team = nil, fought = {},
          badgeRules = badgeRules or nil, badges = badges, family = family,
          ai = ai, spare = spare, bagFrom = bagFrom,
        }
        party[#party + 1] = fighter
        self.fighters[#self.fighters + 1] = fighter
        self.byId[fighter.playerId] = fighter
        bucket[#bucket + 1] = fighter
      end
    end
  end

  -- `bagFrom`: the entry spends the named entry's bag -- the same tables, so a
  -- count spent by either is spent for both and an item one has filed this
  -- turn is held back from the other (`_bagHas`).  A two-trainer fight's items
  -- are trainer A's four, one pool either foe battler may spend (pokeemerald
  -- battle_ai_script_commands.c:292, battle_ai_switch_items.c:808).
  for _, fighter in ipairs(self.fighters) do
    if fighter.bagFrom then
      local lender = self.byId[fighter.bagFrom]
      if not lender or lender.side ~= fighter.side or lender.owner == fighter.owner
          or lender.bagFrom then
        return nil, fighter.owner .. " has a bad bagFrom"
      end
      fighter.bag, fighter.bagNames = lender.bag, lender.bagNames
    end
  end
  for _, side in ipairs(M.SIDES) do
    local holds = false
    for _, fighter in ipairs(self.bySide[side]) do
      if not fighter.spare then holds = true end
    end
    if not holds then return nil, "side " .. side .. " has only spare fighters" end
  end

  -- pret battler ids interleave the sides: a1, b1, a2, b2, a3, b3.
  for i = 1, M.FIGHTERS_PER_SIDE do
    if self.bySide.a[i] then self.order[#self.order + 1] = self.bySide.a[i] end
    if self.bySide.b[i] then self.order[#self.order + 1] = self.bySide.b[i] end
  end
  self.double = #self.bySide.a > 1 or #self.bySide.b > 1

  for _, fighter in ipairs(self.fighters) do
    if fighter.active then fighter.b = self:_newBattler(fighter, fighter.active) end
  end
  for _, fighter in ipairs(self.fighters) do self:_refield(fighter) end
  for _, fighter in ipairs(self.fighters) do
    if fighter.b then self:_sendEvent(fighter) end
  end

  self.phase = "resolving"
  self:_battleStart()
  self:_drainExp()
  self.phase = "choice"
  -- pokefirered/src/battle_controller_oak_old_man.c:452: Oak speaks before the
  -- first action menu.
  if not self.result then self:_lesson("intro") end
  if not self.result and self:_anyMustReplace() then
    self:_openReplace()
    return self
  end
  self:_openTurn()
  return self
end

-- ------------------------------------------------------------------
-- events
-- ------------------------------------------------------------------

function Battle:_emit(kind, fields)
  local event = Events.build(kind, fields)
  if not event then return nil end
  self.seq = self.seq + 1
  event.battle = self.id
  event.seq = self.seq
  self.buffer[#self.buffer + 1] = event
  return event
end

-- One of PROF. OAK's lessons (M.LESSONS), under `firstBattle = "oak"` only:
-- each id once a battle, but `run`, which the cart says at every RUN press.
function Battle:_lesson(id)
  if self.firstBattle ~= "oak" then return end
  if id ~= "run" then
    if self.lessons[id] then return end
    self.lessons[id] = true
  end
  self:_emit("lesson", { text = id })
end

-- The lessons a side-a choice opens on the cart, said as it is filed: a party
-- menu (flag 8) for a switch or a bag item used on a party member
-- (pokefirered/src/party_menu.c:5834 OpenPartyMenuInTutorialBattle, :5875
-- EnterPartyFromItemMenuInBattle), then -- a POTION -- flag 4 when the bag
-- hands it back (battle_controller_oak_old_man.c:389 CompleteWhenChoseItem).
function Battle:_choiceLessons(choice)
  if choice.action == "switch" then
    self:_lesson("party")
    return
  end
  if choice.action ~= "item" then return end
  local effect = Items.bagEffect(choice.item)
  if effect and not (effect.ball or effect.escape or effect.flute or effect.activeOnly) then
    self:_lesson("party")
  end
  if choice.item == M.ITEM_POTION then self:_lesson("potion") end
end

-- One roster per party: a shared team's second seat holds the same list, so
-- its first seat speaks for both.
function Battle:_syncTeams()
  for _, fighter in ipairs(self.fighters) do
    if fighter.seats[1] == fighter then
      local roster = Events.teamString(fighter.mons)
      if roster ~= fighter.team then
        fighter.team = roster
        self:_emit("team", { slot = fighter.slot, side = fighter.side, team = roster })
      end
    end
  end
end

-- The seats one owner fields, in slot order: both of a shared team, else the
-- one fighter (a seat id finds its party too).  Empty for an unknown id.
function Battle:seatsOf(ownerId)
  local out = {}
  local fighter = self.byId[str(ownerId) or ""]
  if not fighter then return out end
  for i, seat in ipairs(fighter.seats) do out[i] = seat end
  return out
end

function Battle:drainEvents()
  local out = self.buffer
  self.buffer = {}
  return out
end

-- ------------------------------------------------------------------
-- the field
-- ------------------------------------------------------------------

function Battle:_foeSeats(fighter)
  local other = (fighter.side == "a") and "b" or "a"
  return self.bySide[other]
end

function Battle:_fighterAtSlot(slot)
  for _, fighter in ipairs(self.fighters) do
    if fighter.slot == slot then return fighter end
  end
  return nil
end

function Battle:_firstLivingFoe(fighter)
  for _, foe in ipairs(self:_foeSeats(fighter)) do
    if activeMon(foe) then return foe end
  end
  return nil
end

-- BattleSim2's aim stream: uniform over the living opposing seats, one byte
-- drawn only when two or more stand.
function Battle:_autoTarget(fighter)
  local living = {}
  for _, foe in ipairs(self:_foeSeats(fighter)) do
    if activeMon(foe) then living[#living + 1] = foe end
  end
  if #living == 0 then return nil end
  if #living == 1 then return living[1] end
  return living[(self.aim:byte() % #living) + 1]
end

-- A `spare` entry never holds its side up: pret's Cmd_checkteamslost counts
-- only the player's half beside an in-game partner (pokeemerald battle_script_
-- commands.c:3543), so the fight is lost when the player's mons are down
-- whatever Steven still has.
function Battle:_sideAlive(side)
  for _, fighter in ipairs(self.bySide[side]) do
    if not fighter.spare and firstLiving(fighter.mons) then return true end
  end
  return false
end

-- The side's players for an outcome: owners, each once (a shared team's two
-- seats are one player).
function Battle:_sidePlayers(side)
  local out, seen = {}, {}
  for _, fighter in ipairs(self.bySide[side]) do
    if not seen[fighter.owner] then
      seen[fighter.owner] = true
      out[#out + 1] = fighter.owner
    end
  end
  return out
end

-- Whether a seat that must replace has a mon to send.  A shared team refills
-- its emptied seats in battler order -- pret HandleFaintedMonActions walks the
-- battlers in order and HasNoMonsToSwitch counts the partner's
-- monToSwitchIntoId -- so a sibling ahead of this seat that is still owed a
-- mon takes one off the bench first.  With one mon left only one seat refills.
function Battle:_canRefill(fighter)
  local bench = #self:benchOf(fighter)
  for _, seat in ipairs(fighter.seats) do
    if seat == fighter then break end
    if seat.mustReplace and seat.choice == nil then bench = bench - 1 end
  end
  return bench > 0
end

-- A shared team's seat whose sibling took the last bench mon stands empty
-- (`vacant`: pret marks the battler absent, gAbsentBattlerFlags, and the
-- replacement stage passes it by) until a Revive gives its party a bench
-- again (`_refreshVacant`).  A one-seat fighter is only ever owed a mon it
-- still has.
function Battle:_vacateSeats()
  for _, fighter in ipairs(self.fighters) do
    if fighter.mustReplace and #fighter.seats > 1 and #self:benchOf(fighter) == 0 then
      fighter.mustReplace, fighter.pendingFought = nil, nil
      fighter.vacant = true
    end
  end
end

-- pret HandleFaintedMonActions case 0 (battle_util.c:1156; the engine's
-- Engine.refreshAbsent, engine.lua:2259): at the top of every faint flow --
-- after each action and at the end of the turn (init.lua D.faintFlow) -- an
-- absent battler whose party has a replacement again is present again, and
-- the replacement stage that follows asks it for one (init.lua:3202).  Here
-- the seat is owed a mon again; the replace phase asks it in battler order
-- (`_canRefill`), and a seat a sibling ahead took the mon from is vacated
-- again (`_vacateSeats`).  Only a Revive can give a vacant seat a bench
-- (every other living mon of its party is out on the sibling seat), so
-- `_resolveSwitches` re-checks after each bag action -- a Future Sight due on
-- the seat that turn then waits for the newcomer, as the cart sends it in
-- before the hit -- and `_resolveTurn` again with the end-of-turn faint flow
-- (D.endTurn).  The pending participation is the opposition standing now, as
-- for a seat emptied now (`_faintBattler`).  A seat that started empty is not
-- vacant: the engine fields no battler there to re-check (state.lua:382).
function Battle:_refreshVacant()
  for _, fighter in ipairs(self.order) do
    if fighter.vacant and #self:benchOf(fighter) > 0 then
      fighter.vacant = nil
      fighter.mustReplace = true
      fighter.pendingFought = self:_standingOpposition(fighter)
    end
  end
end

function Battle:_owes(fighter)
  if fighter.choice ~= nil then return false end
  if fighter.mustReplace then return self:_canRefill(fighter) end
  if self.phase == "replace" then return false end
  if activeMon(fighter) == nil then return false end
  return true
end

-- Forced lock-in (the cart withholds the menu): recharge, a two-turn release,
-- Bide, rampage, Uproar, Rollout.  The resolution narrates, not the fill.
function Battle:_fillForcedChoices()
  for _, fighter in ipairs(self.fighters) do
    local b = fighter.b
    if fighter.choice == nil and b and b.mon.hp > 0 then
      local choice = nil
      if b.mustRecharge then
        choice = { action = "fight", recharge = true, move = b.lastSlot or 1 }
      elseif b.lockedNum then
        choice = { action = "fight", locked = true, move = b.lockedSlot or 1 }
      end
      if choice then
        fighter.forced = true
        fighter.choice = choice
        self:_emit("chose", { slot = fighter.slot, side = fighter.side, text = fighter.name })
      end
    end
  end
end

function Battle:_anyDisconnected()
  for _, fighter in ipairs(self.fighters) do
    if not fighter.connected then return true end
  end
  return false
end

-- ------------------------------------------------------------------
-- choices
-- ------------------------------------------------------------------

-- Whether the bag still holds `item` for this seat.  A shared team has one
-- bag, and the cart takes a medicine out of it when it is CHOSEN -- the
-- engine's partner cancel cannot give a non-ball item back (init.lua
-- D.cancelPartner, pokefirered/src/battle_controller_player.c:286) -- so one
-- the sibling seat has filed this turn is not there to choose again.  The same
-- holds for every seat that spends this bag (`bagFrom`: the AI takes a trainer
-- item off BATTLE_HISTORY when it decides, pokeemerald battle_ai_switch_items.c
-- ShouldUseItem).  A flute is never spent, so it is never held back.
function Battle:_bagHas(fighter, item)
  if not fighter.bag then return false end
  local n = fighter.bag[item] or 0
  local effect = Items.bagEffect(item)
  if not (effect and effect.noConsume) then
    for _, seat in ipairs(self.fighters) do
      local c = seat.choice
      if seat ~= fighter and seat.bag == fighter.bag and c and c.action == "item"
          and c.item == item then
        n = n - 1
      end
    end
  end
  return n > 0
end

-- The battler party member `index` stands as: this seat's, or -- a shared
-- team -- the sibling seat's, so a medicine on the partner works on its
-- battler (the engine's items.lua active_for_slot finds battler 0 or 2).
function Battle:_partyBattler(fighter, index)
  local seat = self:fieldedSeat(fighter, index)
  return seat and seat.b or nil
end

function Battle:_spendBag(fighter, item)
  if not fighter.bag then return end
  local n = fighter.bag[item]
  if not n then return end
  if n <= 1 then fighter.bag[item] = nil else fighter.bag[item] = n - 1 end
end

-- Whether a bag item would do anything to this party member (the cart's
-- "It won't have any effect." refuses it before the turn is spent).
function Battle:_itemHasEffect(fighter, effect, index, moveIndex)
  local mon = fighter.mons[index]
  if not mon then return false end
  local b = self:_partyBattler(fighter, index)
  if effect.revive then return mon.hp <= 0 end
  if mon.hp <= 0 then return false end
  if effect.activeOnly then
    if not b then return false end
    if effect.stage then return b.stages[effect.stage] < 6 end
    if effect.focusEnergy then return not b.focusEnergy end
    if effect.mist then return int(self.sides[b.side].mistTurns, 0) == 0 end
    return false
  end
  local any = false
  if effect.heal or effect.healFull then any = any or mon.hp < mon.maxHp end
  if effect.cure then
    local s = Status.normalise(mon.status)
    any = any or (s ~= nil and effect.cure[s] == true)
  end
  if effect.confusion and b then any = any or int(b.confusion, 0) > 0 end
  if effect.attract and b then any = any or b.infatuatedWith ~= nil end
  local moves = (b and b.moves) or mon.moves
  if effect.pp or effect.ppFull then
    local mv = moves[moveIndex or 0]
    any = any or (mv ~= nil and mv.pp < mv.maxPp)
  end
  if effect.ppAll or effect.ppAllFull then
    for i = 1, #moves do if moves[i].pp < moves[i].maxPp then any = true end end
  end
  return any
end

function Battle:_switchBlocked(b)
  if not b then return false end
  if self:isTrapped(b) then return true end
  return Abilities.escapeBlocker(self, b) ~= nil
end

function Battle:_normaliseChoice(fighter, choice)
  local action = choice.action

  if fighter.mustReplace then
    if action ~= "switch" then return nil end
    local slot = int(choice.slot, nil)
    if slot == nil then return nil end
    local target = partyIndexOf(fighter, slot)
    local bench = fighter.mons[target]
    if not bench or bench.hp <= 0 then return nil end
    if self:partyTaken(fighter, target) then return nil end
    return { action = "switch", slot = target }
  end

  local b = fighter.b
  if not b or b.mon.hp <= 0 then return nil end

  if action == "run" then
    -- A wild seat's own RUN is the cart's opponent RUN: it reaches the cart as
    -- the move controller's AI_CHOICE_FLEE (pokefirered/src/battle_main.c:3268),
    -- past the selection's IsRunningFromBattleImpossible (:3236), so nothing
    -- refuses it here; it is ordered with the moves and re-checked when it
    -- runs (`_wildFlee`).
    if isWildSeat(self.mode, fighter) then return { action = "run", flee = true } end
    if isWildMode(self.mode) then
      -- pokeemerald/src/battle_main.c:4021 IsRunningFromBattleImpossible: a
      -- Smoke Ball or Run Away gets away first, then the traps, then Birch's
      -- "Don't leave me like this!" (FIRST_BATTLE, :4078 -- the screen's line).
      local he = Items.of(b)
      if he ~= Items.HOLD.CAN_ALWAYS_RUN and b.ability ~= "RUN_AWAY"
          and (self:_switchBlocked(b) or self.firstBattle == "birch") then
        return nil
      end
    end
    return { action = "run" }
  end

  if action == "item" then
    -- rules.bag = false: "Items can't be used now." at selection (pokeemerald
    -- battle_main.c:4221; the screen's line), for every seat.
    if self.rules.noBag then return nil end
    local item = Items.idOf(choice.item)
    if not item then return nil end
    if isWildSeat(self.mode, fighter) then return nil end
    if fighter.bag and not self:_bagHas(fighter, item) then return nil end
    local effect = Items.bagEffect(item)
    local out = { action = "item", item = item, dexCaught = choice.dexCaught == true }
    if not effect then return out end            -- "But it failed!", turn spent
    if effect.ball or effect.escape or effect.flute then return out end
    local index = fighter.active
    if choice.slot ~= nil then
      local slot = int(choice.slot, nil)
      if slot == nil then return nil end
      index = partyIndexOf(fighter, slot)
      if not fighter.mons[index] then return nil end
    end
    -- An X item / Dire Hit / Guard Spec. is the choosing battler's own, even
    -- in a double (pokefirered/src/item_use.c ItemUseInBattle_StatIncrease
    -- reads gBattlerInMenuId; the engine's items.lua user_battler); a
    -- medicine may name any party member, the partner's battler included.
    if effect.activeOnly and index ~= fighter.active then return nil end
    out.slot = index
    if choice.move ~= nil then
      local mv = int(choice.move, nil)
      if mv == nil then return nil end
      out.move = mv + 1
    elseif effect.needsMove then
      return nil
    end
    if not self:_itemHasEffect(fighter, effect, index, out.move) then return nil end
    return out
  end

  if action == "switch" then
    local slot = int(choice.slot, nil)
    if slot == nil then return nil end
    local target = partyIndexOf(fighter, slot)
    local bench = fighter.mons[target]
    if not bench or bench.hp <= 0 or self:partyTaken(fighter, target) then return nil end
    if self:_switchBlocked(b) then return nil end
    return { action = "switch", slot = target }
  end

  if action == "fight" then
    local index = int(choice.move, nil)
    if index == nil then return nil end
    local out = { action = "fight", move = index + 1 }
    if not self:hasUsableMove(b) then
      out.struggle = true
      out.move = 1
    else
      local encoreSlot = (int(b.encoreTurns, 0) > 0 and b.encoreNum) and self:slotOfNum(b, b.encoreNum) or nil
      if encoreSlot then
        out.move = encoreSlot
      else
        if not b.moves[index + 1] then return nil end
        local bad = self:moveLimitations(b)
        if bad[index + 1] then return nil end
      end
    end
    local row = out.struggle and Move.STRUGGLE or b.moves[out.move]
    -- Aimed as the cart's menu aims it: a Ghost's CURSE like a SELECTED move.
    local ttype = self:aimTarget(b, row)
    if ttype == T.SELECTED or ttype == T.USER_OR_SELECTED then
      local tf
      if choice.target ~= nil then
        tf = self:_fighterAtSlot(int(choice.target, -1))
        if not tf or tf == fighter then return nil end
        if not activeMon(tf) and not tf.mustReplace then return nil end
      else
        tf = self:_firstLivingFoe(fighter)
        if not tf then
          for _, foe in ipairs(self:_foeSeats(fighter)) do
            if foe.mustReplace then tf = foe; break end
          end
        end
      end
      if not tf then return { action = "skip" } end
      out.target = tf.slot
    else
      local tf = self:_firstLivingFoe(fighter)
      if tf then out.target = tf.slot end
    end
    if choice.pass ~= nil then
      local p = int(choice.pass, nil)
      if p ~= nil then
        local idx = partyIndexOf(fighter, p)
        if fighter.mons[idx] and fighter.mons[idx].hp > 0 and not self:partyTaken(fighter, idx) then
          out.pass = idx
        end
      end
    end
    return out
  end

  return nil
end

function Battle:submitChoice(playerId, choice)
  if self.phase ~= "choice" and self.phase ~= "replace" then return false end
  if type(choice) ~= "table" then return false end
  local fighter = self.byId[str(playerId) or ""]
  if not fighter then return false end
  if not fighter.connected then return false end
  if not ACTIONS[choice.action] then return false end
  if self.phase == "replace" and not self:_owes(fighter) then return false end

  if choice.action == "cancel" then
    if self.phase == "replace" then return false end
    if fighter.choice == nil then return false end
    if fighter.forced then return false end
    self:_emit("unchose", { slot = fighter.slot, side = fighter.side, text = fighter.name })
    fighter.choice = nil
    return true
  end

  if fighter.choice ~= nil then return false end
  if fighter.mustReplace then
    if choice.action ~= "switch" then return false end
  elseif not activeMon(fighter) then
    return false
  end

  -- Oak's lab: the trainer RUN is refused at selection, with Oak's line in
  -- place of the trainer's (pokefirered/data/battle_scripts_1.s:3024
  -- BattleScript_PrintCantRunFromTrainer -> STRINGID_DONTLEAVEBIRCH, which the
  -- Oak controller turns into PrintOakText_OakNoRunningFromATrainer) -- the
  -- action menu stays, so nothing is filed; the `run` lesson is the one event
  -- a refused choice leaves.
  if choice.action == "run" and self.firstBattle == "oak" and fighter.side == "a" then
    self:_lesson("run")
    return false
  end

  local normalised = self:_normaliseChoice(fighter, choice)
  if not normalised then return false end
  fighter.choice = normalised
  if self.firstBattle == "oak" and fighter.side == "a" then self:_choiceLessons(normalised) end
  self:_emit("chose", { slot = fighter.slot, side = fighter.side, text = fighter.name })
  self:_maybeResolve()
  return true
end

function Battle:_anyoneOwes()
  for _, fighter in ipairs(self.fighters) do
    if self:_owes(fighter) then return true end
  end
  return false
end

function Battle:_maybeResolve()
  if self.phase ~= "choice" and self.phase ~= "replace" then return false end
  if self:_anyDisconnected() then return false end
  for _, fighter in ipairs(self.fighters) do
    if self:_owes(fighter) then return false end
  end
  if self.phase == "replace" then
    self:_closeReplace()
    return true
  end
  self:_resolveTurn()
  return true
end

-- ------------------------------------------------------------------
-- the auto-pick (timeout / NPC): BattleSim2's heuristic on Gen 3 ids
-- ------------------------------------------------------------------

-- EFFECT_* status moves worth using, by preference.
local AUTO_STATUS_PRI = {
  [E.SLEEP] = 4, [E.PARALYZE] = 3, [E.TOXIC] = 3, [E.POISON] = 2, [E.WILL_O_WISP] = 2,
  [E.CONFUSE] = 1, [E.LEECH_SEED] = 1,
}
-- Self boosts / screens / Substitute: stat key, or true for a flag move.
local AUTO_SETUP = {
  [E.ATTACK_UP] = "atk", [E.DEFENSE_UP] = "def", [E.SPEED_UP] = "spe",
  [E.SPECIAL_ATTACK_UP] = "spa", [E.SPECIAL_DEFENSE_UP] = "spd",
  [E.ATTACK_UP_2] = "atk", [E.DEFENSE_UP_2] = "def", [E.SPEED_UP_2] = "spe",
  [E.SPECIAL_ATTACK_UP_2] = "spa", [E.SPECIAL_DEFENSE_UP_2] = "spd",
  [E.CALM_MIND] = "spa", [E.BULK_UP] = "atk", [E.DRAGON_DANCE] = "atk", [E.COSMIC_POWER] = "def",
  [E.FOCUS_ENERGY] = true, [E.LIGHT_SCREEN] = true, [E.REFLECT] = true, [E.SUBSTITUTE] = true,
}
-- Heal items, strongest first; cures by status; X items (Gen 3 ids).
local AUTO_HEAL_PREF = { 19, 20, 21, 31, 29, 28, 22, 27, 26, 30, 13, 44, 142, 139 }
local AUTO_STATUS_CURE = {
  PSN = { 19, 23, 32, 38, 141, 14, 135 }, TOX = { 19, 23, 32, 38, 141, 14, 135 },
  BRN = { 19, 23, 32, 38, 141, 15, 136 }, FRZ = { 19, 23, 32, 38, 141, 16, 137 },
  SLP = { 19, 23, 32, 38, 141, 17, 134, 39 }, PAR = { 19, 23, 32, 38, 141, 18, 133 },
}
local AUTO_X_ITEM = { 75, 76, 77, 79, 74, 73 }

function Battle:_effectivenessProduct(moveType, defender)
  local product = Types.effectivenessOf(self.typeTable, moveType, defender.type1, defender.type2,
    defender.identified)
  return product
end

function Battle:_bestSeBench(fighter, defender)
  if not defender then return nil end
  local best, bestEff = nil, 100
  for i = 1, #fighter.mons do
    if not self:partyTaken(fighter, i) then
      local bench = fighter.mons[i]
      if bench and bench.hp > 0 then
        local maxEff = 100
        for j = 1, #bench.moves do
          local m = bench.moves[j]
          if m.pp > 0 and m.power > 0 then
            local eff = self:_effectivenessProduct(m.type, defender)
            if eff > maxEff then maxEff = eff end
          end
        end
        if maxEff > 100 then
          if not best or maxEff > bestEff or (maxEff == bestEff and i < best) then
            best, bestEff = i, maxEff
          end
        end
      end
    end
  end
  return best
end

function Battle:_autoItemChoice(fighter, b)
  if not fighter.bag then return nil end
  if self.rules.noBag then return nil end
  if isWildSeat(self.mode, fighter) then return nil end
  local mon = b.mon
  local s = Status.normalise(mon.status)
  if s then
    for _, id in ipairs(AUTO_STATUS_CURE[s] or {}) do
      if self:_bagHas(fighter, id) then
        return { action = "item", item = id, slot = fighter.active }
      end
    end
  end
  if mon.hp < mon.maxHp and mon.hp * 2 <= mon.maxHp then
    for _, id in ipairs(AUTO_HEAL_PREF) do
      if self:_bagHas(fighter, id) then
        return { action = "item", item = id, slot = fighter.active }
      end
    end
  end
  local flat = b.stages.atk <= 0 and b.stages.def <= 0 and b.stages.spe <= 0 and b.stages.spa <= 0
  if flat and not b.focusEnergy then
    for _, id in ipairs(AUTO_X_ITEM) do
      if self:_bagHas(fighter, id) then
        local effect = Items.bagEffect(id)
        if effect and self:_itemHasEffect(fighter, effect, fighter.active) then
          return { action = "item", item = id, slot = fighter.active }
        end
      end
    end
  end
  return nil
end

-- An auto-picked move, aimed at the foe the heuristic drew -- except a
-- Ghost's CURSE, which is filed unaimed: the cart's AI aims every USER-row
-- move at itself (pokefirered/src/battle_controller_opponent.c:1370; the
-- engine's ai.lua:353), so its curse lands on the battler opposite
-- (`_pickTarget` and Effects CURSE; the engine's effects/setup.lua foeOf),
-- never on the random foe `_autoTarget` drew.  NPC seats and timed-out seats
-- alike.
function Battle:_autoFight(b, move, foe)
  if self:isGhostCurse(b, b.moves[move]) then return { action = "fight", move = move } end
  return { action = "fight", move = move, target = foe.slot }
end

function Battle:_autoChoice(fighter)
  if fighter.mustReplace then
    local foe = self:_autoTarget(fighter)
    local defender = foe and foe.b
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
    local next_ = self:benchOf(fighter)[1]
    if next_ then return { action = "switch", slot = next_ } end
    return nil
  end

  local b = fighter.b
  if not b or b.mon.hp <= 0 then return nil end
  if b.mustRecharge then return { action = "fight", recharge = true, move = b.lastSlot or 1 } end
  if b.lockedNum then return { action = "fight", locked = true, move = b.lockedSlot or 1 } end

  if isWildSeat(self.mode, fighter) and (fighter.ai or self.wildPick == "cart") then
    return self:_cartWildChoice(fighter, b)
  end

  local foe = self:_autoTarget(fighter)
  if not foe then
    for _, f in ipairs(self:_foeSeats(fighter)) do
      if f.mustReplace then foe = f; break end
    end
  end
  if not foe then return nil end

  if not self:hasUsableMove(b) then
    return { action = "fight", move = 1, struggle = true, target = foe.slot }
  end
  local defender = foe.b
  local bad = self:moveLimitations(b)
  if not defender or defender.mon.hp <= 0 then
    for i = 1, #b.moves do
      if not bad[i] then return self:_autoFight(b, i, foe) end
    end
    return { action = "fight", move = 1, struggle = true, target = foe.slot }
  end

  local itemPick = self:_autoItemChoice(fighter, b)
  if itemPick then return itemPick end

  local ds = defender.stages
  local foeBoosted = ds.atk >= 2 or ds.def >= 2 or ds.spe >= 2 or ds.spa >= 2 or defender.focusEnergy
  local foeSub = int(defender.substituteHP, 0) > 0
  local weSlower = self:_speedOf(b) < self:_speedOf(defender)
  local canSwitch = not self:_switchBlocked(b)

  if b.mon.hp * 4 <= b.mon.maxHp and canSwitch then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end
  if (foeBoosted or foeSub) and b.mon.hp * 2 <= b.mon.maxHp and canSwitch then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end

  local pick, pickEff, pickPow = nil, -1, -1
  for i = 1, #b.moves do
    local m = b.moves[i]
    if not bad[i] and m.power > 0 then
      local eff = self:_effectivenessProduct(m.type, defender)
      if not pick or eff > pickEff or (eff == pickEff and m.power > pickPow)
         or (eff == pickEff and m.power == pickPow and i < pick) then
        pick, pickEff, pickPow = i, eff, m.power
      end
    end
  end

  if ((not pick) or pickEff == 0) and canSwitch then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end
  if pick and pickEff > 100 then
    return self:_autoFight(b, pick, foe)
  end

  if not Status.normalise(defender.mon.status) and not foeSub then
    local statusPick, statusPri = nil, -1
    for i = 1, #b.moves do
      local m = b.moves[i]
      if not bad[i] and m.power == 0 then
        local pri = AUTO_STATUS_PRI[m.effect]
        if pri and pri > statusPri then statusPick, statusPri = i, pri end
      end
    end
    if statusPick and (weSlower or foeBoosted or not pick or pickEff <= 100) then
      return self:_autoFight(b, statusPick, foe)
    end
  end

  local flat = b.stages.atk <= 0 and b.stages.def <= 0 and b.stages.spe <= 0 and b.stages.spa <= 0
  if flat and not b.focusEnergy and not foeBoosted and not foeSub
     and not (weSlower and b.mon.hp * 2 <= b.mon.maxHp) then
    for i = 1, #b.moves do
      local m = b.moves[i]
      if not bad[i] and m.power == 0 then
        local kind = AUTO_SETUP[m.effect]
        if kind == true or (type(kind) == "string" and b.stages[kind] <= 0) then
          return self:_autoFight(b, i, foe)
        end
      end
    end
  end

  if not (pick and pickEff > 0) then
    pick, pickPow = nil, -1
    for i = 1, #b.moves do
      local m = b.moves[i]
      if not bad[i] and (not pick or m.power > pickPow) then pick, pickPow = i, m.power end
    end
  end
  return self:_autoFight(b, pick or 1, foe)
end

-- The cart's opponent controller for a wild seat (pokefirered/src/battle_
-- controller_opponent.c:1351 OpponentHandleChooseMove; pokeemerald :1551).
-- HandleTurnActionSelectionState (pokefirered/src/battle_main.c:3141) asks it
-- only when the battler has a move to choose: every slot unusable is Struggle
-- and an Encore is the encored move, with no controller, no AI and no draw
-- (:3143-3155); a lock-in never gets this far (`_fillForcedChoices`).
function Battle:_cartWildChoice(fighter, b)
  local foes = self:_foeSeats(fighter)
  local left = foes[1]   -- B_POSITION_PLAYER_LEFT
  if not self:hasUsableMove(b) then
    return { action = "fight", move = 1, struggle = true, target = left.slot }
  end
  local encoreSlot = (int(b.encoreTurns, 0) > 0 and b.encoreNum) and self:slotOfNum(b, b.encoreNum) or nil
  if encoreSlot then return self:_autoFight(b, encoreSlot, left) end
  if fighter.ai then return self:_wildAiChoice(fighter, b, left) end
  -- The wild arm (a wild battle that is not ROAMER / FIRST_BATTLE / SAFARI has
  -- no AI): `Random() & 3` until the slot holds a move; a move the selection
  -- refuses (TrySetCantSelectMoveBattleScript, battle_main.c:3277: disabled,
  -- tormented, taunted, sealed, Choice-locked, out of PP) sends the action
  -- back to the controller (stateIdAfterSelScript = STATE_WAIT_ACTION_CHOSEN),
  -- which draws again -- the opponent's selection line prints nothing
  -- (OpponentHandlePrintSelectionString).
  local bad = self:moveLimitations(b)
  local slot = nil
  for _ = 1, M.WILD_PICK_CAP do
    local s = self:roll(0, 3) + 1
    if b.moves[s] and not bad[s] then
      slot = s
      break
    end
  end
  if not slot then
    for i = 1, #b.moves do
      if not bad[i] then
        slot = i
        break
      end
    end
  end
  local ttype = int(b.moves[slot].target, 0)
  -- A USER / USER_OR_SELECTED row aims at the user (a Ghost's CURSE files
  -- unaimed, `_autoFight`); a double battle draws the player's position
  -- (`GetBattlerAtPosition(Random() & 2)`: one of the two side-a seats -- one
  -- of n with more); otherwise the player's left battler.
  if hasBit(ttype, T.USER_OR_SELECTED) or hasBit(ttype, T.USER) then
    return self:_autoFight(b, slot, left)
  end
  local aim = left
  if self.double then aim = foes[self:roll(0, #foes - 1) + 1] end
  return { action = "fight", move = slot, target = aim.slot }
end

-- AI_Roaming / AI_FirstBattle (pokefirered/data/battle_ai_scripts.s:3226,
-- pokeemerald :3233), the one script a ROAMER / FIRST_BATTLE wild battle runs
-- (pokefirered/src/battle_ai_script_commands.c:337, pokeemerald :365): flee, or
-- end with every usable move at the same score (BattleAI_SetupAIData: 100,
-- unusable 0) and pick among the best.  AI_TARGET is the battler opposite
-- (gBattlerAttacker ^ BIT_SIDE in a single battle).  The AI's other draws
-- (four simulatedRNG rolls per call, a double's target) feed nothing these
-- scripts read and are not drawn.
function Battle:_wildAiChoice(fighter, b, left)
  local target = self:oppositeFoe(b)
  if fighter.ai == "roamer" then
    if self:_roamerFlees(b, target) then return { action = "run", flee = true } end
  elseif fighter.ai == "firstBattle" then
    -- if_hp_equal / if_hp_less_than AI_TARGET, 20: 100 * hp / maxHP, floored
    -- (Cmd_if_hp_less_than), so 20% and under flees, whatever the speeds.
    if target and floor(100 * target.mon.hp / max(1, target.mon.maxHp)) <= 20 then
      return { action = "run", flee = true }
    end
  end
  return self:_autoFight(b, self:_aiBestSlot(b), target or left)
end

-- AI_Roaming: not while wrapped (STATUS2_WRAPPED) or held by Mean Look / Block
-- / Spider Web (STATUS2_ESCAPE_PREVENTION), not when the target has SHADOW
-- TAG; LEVITATE flees past an ARENA TRAP, which otherwise holds it.  Nothing
-- else is asked: not Ingrain, not Magnet Pull, not sleep or freeze -- a
-- sleeping roamer still runs (the run action has no canceller).
function Battle:_roamerFlees(b, target)
  if int(b.trapTurns, 0) > 0 or b.trappedBy ~= nil then return false end
  local tab = target and target.ability
  if tab == "SHADOW_TAG" then return false end
  if b.ability == "LEVITATE" then return true end
  if tab == "ARENA_TRAP" then return false end
  return true
end

-- BattleAI_ChooseMoveOrAction's single-battle pick over the scores (usable
-- 100, unusable or empty 0), in the cart family's own loop: FireRed /
-- LeafGreen raise the best THEN test the tie (pokefirered/src/battle_ai_script_
-- commands.c:401), so a new best is listed twice and the first usable slot
-- after an unusable first slot is twice as likely; Emerald tests the tie
-- first and skips an empty slot (pokeemerald :427).  The family is the
-- player's (side a's first entry: the cart the wild mon lives on).
function Battle:_aiBestSlot(b)
  local bad = self:moveLimitations(b)
  local function score(i)
    if b.moves[i] and not bad[i] then return 100 end
    return 0
  end
  local first = self.bySide.a[1]
  local frlg = not (first and first.family == "rse")
  local considered, n, best = { 1 }, 1, score(1)
  for i = 2, 4 do
    local sc = score(i)
    if frlg then
      if best < sc then
        n, best = 1, sc
        considered[1] = i
      end
      if best == sc then
        n = n + 1
        considered[n] = i
      end
    elseif b.moves[i] then
      if best == sc then
        n = n + 1
        considered[n] = i
      end
      if best < sc then
        n, best = 1, sc
        considered[1] = i
      end
    end
  end
  return considered[self:roll(0, n - 1) + 1]
end

function Battle:_autoChoiceOrSkip(fighter)
  local auto = self:_autoChoice(fighter)
  if auto then return auto end
  if self.phase == "choice" and activeMon(fighter) then return { action = "skip" } end
  return nil
end

function Battle:autoPick(playerId)
  if self.phase ~= "choice" and self.phase ~= "replace" then return false end
  local fighter = self.byId[str(playerId) or ""]
  if not fighter then return false end
  if fighter.choice ~= nil then return false end
  if self.phase == "replace" and not self:_owes(fighter) then return false end
  if not fighter.mustReplace and not activeMon(fighter) then return false end
  local auto = self:_autoChoiceOrSkip(fighter)
  if not auto then return false end
  fighter.choice = auto
  self:_emit("chose", { slot = fighter.slot, side = fighter.side, text = fighter.name })
  self:_maybeResolve()
  return true
end

-- ------------------------------------------------------------------
-- phases
-- ------------------------------------------------------------------

function Battle:_openTurn()
  if self:_checkOver() then return end
  self.phase = "choice"
  self.resolveDeadline = nil
  self.forcedPending = false
  for _, fighter in ipairs(self.fighters) do
    fighter.choice = nil
    fighter.forced = nil
    fighter.acted = nil
  end
  self.deadline = (self.choiceTimeout > 0) and (self.now + self.choiceTimeout) or nil
  self:_syncTeams()
  self:_emit("turn", { amount = self.turn })
  self:_fillForcedChoices()
  if not self:_anyoneOwes() then
    self.forcedPending = true
    self.deadline = nil
  end
end

function Battle:_anyMustReplace()
  for _, fighter in ipairs(self.fighters) do
    if fighter.mustReplace and self:_canRefill(fighter) then return true end
  end
  return false
end

function Battle:_openReplace()
  self.phase = "replace"
  self.resolveDeadline = nil
  self.forcedPending = false
  for _, fighter in ipairs(self.fighters) do
    fighter.choice = nil
    fighter.forced = nil
  end
  self.deadline = (self.choiceTimeout > 0) and (self.now + self.choiceTimeout) or nil
  self:_syncTeams()
  for _, fighter in ipairs(self.fighters) do
    if self:_owes(fighter) then
      self:_emit("turn", { amount = self.turn, slot = fighter.slot })
    end
  end
end

function Battle:_closeReplace()
  self.phase = "resolving"
  for _, fighter in ipairs(self.order) do
    local choice = fighter.choice
    if choice and choice.action == "switch" and not self.result then
      local mon = fighter.mons[choice.slot]
      if mon and mon.hp > 0 then
        local nb = self:_switchIn(fighter, choice.slot)
        self:switchInEffects(nb, { spikes = true })
        self:_faintSweep()
      end
    end
  end
  if not self.result then self:_vacateSeats() end
  -- A delayed hit that came due on an emptied seat lands on the newcomer, as
  -- the cart's replacement-first end of turn has it (Residual.lua); one due on
  -- a seat just vacated is dropped there.
  if not self.result then self:_landPendingFutureSight() end
  self:_drainExp()
  self.phase = "choice"
  if not self.result then self:_checkOver() end
  if self.result then return end
  if self:_anyMustReplace() then
    self:_openReplace()
    return
  end
  self.turn = self.turn + 1
  self:_openTurn()
end

-- ------------------------------------------------------------------
-- switching
-- ------------------------------------------------------------------

-- Drop every link another battler holds to one that is leaving
-- (pokefirered/src/battle_main.c:2329 SwitchInClearSetData / battle_script_
-- commands.c:4966).  `baton`: a Baton Pass keeps the passer's Mean Look-style
-- traps and Lock-Ons standing -- the cart stores them by battler POSITION, so
-- the newcomer inherits them (`_switchIn` re-points them).
function Battle:_unlink(old, baton)
  for _, f in ipairs(self.order) do
    local b = f.b
    if b and b ~= old then
      if b.infatuatedWith == old then b.infatuatedWith = nil end
      if b.trapSource == old then b.trapTurns, b.trapMove, b.trapSource = nil, nil, nil end
      if not baton then
        if b.trappedBy == old then b.trappedBy = nil end
        if b.lockedOnBy == old then b.lockedOnTurns, b.lockedOnBy = nil, nil end
      end
    end
  end
  for _, side in ipairs(M.SIDES) do
    if self.sides[side].followMe == old then self.sides[side].followMe = nil end
  end
end

-- Put party member `index` out on this seat (voluntary switch, replacement,
-- Roar, Baton Pass).  `baton` is the battler passing its volatiles on.
function Battle:_switchIn(fighter, index, baton)
  local old = fighter.b
  if old then
    if old.mon.hp > 0 then Abilities.switchOut(self, old) end
    self:_unlink(old, baton ~= nil)
    fighter.lastB = old
  end
  fighter.active = index
  fighter.mustReplace = nil
  fighter.vacant = nil   -- engine.lua:1951: a switch-in clears the absent flag
  local nb = self:_newBattler(fighter, index)
  if baton then
    -- pokefirered/src/battle_main.c:2350: status2 keeps confusion, Focus
    -- Energy, Substitute, escape prevention and Curse; status3 keeps Leech Seed,
    -- Lock-On, Perish Song, Ingrain and Mud / Water Sport.
    for k, v in pairs(baton.stages) do nb.stages[k] = v end
    nb.confusion = baton.confusion
    nb.focusEnergy = baton.focusEnergy
    nb.substituteHP = baton.substituteHP
    nb.seededBy = baton.seededBy
    nb.ingrain = baton.ingrain
    nb.perishTurns = baton.perishTurns
    nb.cursed = baton.cursed
    nb.trappedBy = baton.trappedBy
    nb.lockedOnTurns = baton.lockedOnTurns
    nb.lockedOnBy = baton.lockedOnBy
    nb.mudSport = baton.mudSport
    nb.waterSport = baton.waterSport
    -- ...and what the passer held on others moves with the position: a foe it
    -- trapped stays trapped, and a foe it Locked On to is re-armed for two
    -- turns for the newcomer (:2356, STATUS3_ALWAYS_HITS_TURN(2)).
    for _, f in ipairs(self.order) do
      local b = f.b
      if b and b ~= old then
        if b.trappedBy == old then b.trappedBy = nb end
        if b.lockedOnBy == old then
          b.lockedOnBy = nb
          if b.side ~= nb.side then b.lockedOnTurns = 2 end
        end
      end
    end
  end
  fighter.b = nb
  self:_refield(fighter)
  local mon = nb.mon
  self:_emit("switch", { slot = fighter.slot, side = fighter.side, text = mon.species,
                         speciesId = mon.speciesId, level = mon.level, mon = index - 1 })
  self:_sendEvent(fighter)
  return nb
end

-- Roar / Whirlwind / Baton Pass (Effects.lua).
function Battle:forceSwitch(fighter, index, reason, baton)
  if not fighter.mons[index] or fighter.mons[index].hp <= 0 then return nil end
  local nb = self:_switchIn(fighter, index, reason == "baton_pass" and baton or nil)
  if reason == "baton_pass" and fighter.lastB and int(fighter.lastB.substituteHP, 0) > 0 then
    self:_emit("sub", { slot = fighter.slot, side = fighter.side, amount = 1 })
  end
  return nb
end

-- Whirlwind / Roar blowing a battler out of a wild fight ends it
-- (pokefirered/data/battle_scripts_1.s:3283): `how = "roar"`, `by` the side
-- of the USER -- the side whose action ended it, which the cart's outcome
-- reads (pokeemerald battle_script_commands.c:6487 VARIOUS_SET_TELEPORT_
-- OUTCOME keys PLAYER_TELEPORTED / MON_TELEPORTED on the attacker's side).
function Battle:blownAway(b, user)
  local by = user and user.side or ((b.side == "a") and "b" or "a")
  self:_concedeRun(b.fighter, "roar", by)
end

-- Teleport out of a wild fight: `how = "teleport"`, `by` the user's side.
function Battle:concede(fighter)
  self:_concedeRun(fighter, "teleport", fighter.side)
end

function Battle:_concedeRun(fighter, how, by)
  self:_emit("run", { slot = fighter.slot, side = fighter.side, text = fighter.name })
  if fighter.side == "a" then
    self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "run", how, by)
  else
    self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "run", how, by)
  end
end

-- ------------------------------------------------------------------
-- resolution
-- ------------------------------------------------------------------

-- pokefirered/src/battle_main.c:3623 (engine clear_turn_flags)
function Battle:_clearTurnFlags(b)
  b.protected, b.enduring, b.magicCoat, b.snatch, b.helpingHand = nil, nil, nil, nil, nil
  b.flinched = nil
  b.lastPhysDmg, b.lastPhysBy, b.lastSpecDmg, b.lastSpecBy = nil, nil, nil, nil
  b.lightningRodRedirected = nil
  b.movedThisTurn = nil
  b.turnOrder = nil
  b.unableToMove = nil
  b.statLoweredMsg = nil
  if int(b.isFirstTurn, 0) > 0 then b.isFirstTurn = b.isFirstTurn - 1 end
  if b.rechargeTurns then
    b.rechargeTurns = b.rechargeTurns - 1
    if b.rechargeTurns <= 0 then b.rechargeTurns, b.mustRecharge = nil, nil end
  end
end

-- Order the turn (pokefirered/src/battle_main.c:3532 SetActionsAndBattlersTurnOrder).
function Battle:_beginTurn()
  for _, f in ipairs(self.order) do
    if f.b then self:_clearTurnFlags(f.b) end
  end
  self.sides.a.followMe, self.sides.b.followMe = nil, nil

  local rows = {}
  for i, f in ipairs(self.order) do
    local b = f.b
    local choice = f.choice
    if b and b.mon.hp > 0 and choice and choice.flee then
      -- A wild seat's RUN is ordered with the moves (pokefirered/src/battle_
      -- main.c:3546 hoists only battler 0's RUN), at priority 0 -- GetWho-
      -- StrikesFirst reads MOVE_NONE for any action but a move (:3485) -- by
      -- speed, Quick Claw and paralysis included.  MOVE_NONE is not Rage.
      b.rage = nil
      rows[#rows + 1] = { f = f, b = b, row = nil, pri = 0, order = i, flee = true }
    elseif b and b.mon.hp > 0 and choice and choice.action == "fight" then
      -- A recharge turn chooses no move (pokefirered/src/battle_main.c:3126
      -- withholds the menu; :2993 left gChosenMoveByBattler MOVE_NONE): Rage
      -- ends, no Focus Punch line, bracket 0 (the cart reads the stale chosen
      -- slot, :3490 -- the recharge move or its caller, priority 0 on every
      -- cart).  A branch, because `choice.recharge and nil or x` is always x.
      local row = nil
      if not choice.recharge then row = self:_actionMove(b, choice) end
      -- pokefirered/src/battle_util.c:1223: Rage ends unless Rage is used again
      local num = row and int(row.num, 0) or 0
      if b.rage and num ~= Move.MOVE.RAGE then b.rage = nil end
      rows[#rows + 1] = { f = f, b = b, row = row, pri = row and int(row.priority, 0) or 0, order = i }
    elseif b then
      -- A seat that chose no move (bag, switch, run) has gChosenMoveByBattler
      -- MOVE_NONE (battle_main.c:2993), which is not Rage.  The Fury Cutter
      -- counter is NOT cleared by choosing something else in Gen 3 (pret has
      -- no such check): a miss, the bag, a failed run, a switch or a canceller
      -- stop resets it (CancelMultiTurnMoves / ClearFuryCutterDestinyBondGrudge).
      b.rage = nil
    end
  end

  self.randomTurnNumber = nil
  if #rows >= 2 then
    local anyClaw = false
    for _, r in ipairs(rows) do
      if Items.has(r.b, Items.HOLD.QUICK_CLAW) then anyClaw = true end
    end
    if anyClaw then self.randomTurnNumber = self:roll(0, 0xFFFF) end
  end
  for _, r in ipairs(rows) do r.spe = self:_speedOf(r.b) end
  self:_orderRows(rows)

  -- Turn-order numbers (Protect / Magic Coat / Snatch "moved last" checks):
  -- meta actions first in battler order, then the fighters, then the rest.
  local list, seen = {}, {}
  for _, f in ipairs(self.order) do
    local a = f.choice and f.choice.action
    if (a == "switch" or a == "item" or a == "run") and not f.choice.flee then
      list[#list + 1] = f
      seen[f] = true
    end
  end
  for _, r in ipairs(rows) do list[#list + 1] = r.f; seen[r.f] = true end
  for _, f in ipairs(self.order) do
    if not seen[f] then list[#list + 1] = f end
  end
  for i, f in ipairs(list) do
    if f.b then f.b.turnOrder = i end
  end
  self.turnOrderFighters = list
  self.fightRows = rows
  self.turnPriority = {}
  for _, r in ipairs(rows) do self.turnPriority[r.b] = r.pri end

  -- pokefirered/src/battle_main.c:3669 CheckFocusPunch_ClearVarsBeforeTurnStarts
  for _, r in ipairs(rows) do
    if r.row and int(r.row.effect, -1) == E.FOCUS_PUNCH and not r.b.lockedNum
        and Status.normalise(r.b.mon.status) ~= "SLP" then
      self:_emit("anim", { slot = r.b.slot, side = r.b.side, text = "FOCUS_PUNCH_SETUP" })
      self:say(self:nameOf(r.b) .. " is tightening its focus!")
    end
  end
end

function Battle:_resolveTurn()
  self.phase = "resolving"
  self.resolveDeadline = (self.resolveTimeout > 0) and (self.now + self.resolveTimeout) or nil

  self:_beginTurn()
  if self:_resolveRuns() then return end
  self:_resolveSwitches()
  if not self.result then self:_resolveItems() end
  if not self.result then self:_resolveFights() end
  if not self.result then self:_endTurn() end
  self:_faintSweep()
  self:_drainExp()
  if not self.result then self:_checkOver() end
  if not self.result then self:_refreshVacant() end

  if not self.result and self:_anyMustReplace() then
    self:_openReplace()
    return
  end
  if not self.result then
    self.turn = self.turn + 1
    self:_openTurn()
  end
end

-- pokefirered/src/battle_main.c:4229 TryRunFromBattle (wild), a concession
-- (1v1 / coop_pvp), or the trainer refusal.
function Battle:_resolveRuns()
  local running = {}
  for _, fighter in ipairs(self.order) do
    if fighter.choice and fighter.choice.action == "run" and not fighter.choice.flee then
      running[#running + 1] = fighter
    end
  end
  if #running == 0 then return false end

  -- rules.forfeit: the Frontier / Trainer Hill trainer RUN (pokeemerald
  -- battle_main.c:4321 -- the "forfeit the match?" prompt is the screen's)
  -- always gets away (battle_util.c:448, traps or not) and ends as
  -- B_OUTCOME_FORFEITED, "{PLAYER} forfeited the match!" (:5058): the runner's
  -- side loses.  A wild fight's RUN stays a RUN.
  if self.rules.forfeit and not isWildMode(self.mode) then
    local sides = {}
    for _, fighter in ipairs(running) do
      sides[fighter.side] = true
      self:say(fighter.name .. " forfeited the match!")
      self:_emit("run", { slot = fighter.slot, side = fighter.side, text = fighter.name })
    end
    if sides.a and sides.b then
      self:_finish("draw", nil, nil, "run", "forfeit", nil)
    elseif sides.a then
      self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "run", "forfeit", "a")
    else
      self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "run", "forfeit", "b")
    end
    return true
  end

  if not runEndsBattle(self.mode) then
    self:say("No! There's no running from a trainer battle!")
    return false
  end

  if not isWildMode(self.mode) then
    local sides = {}
    for _, fighter in ipairs(running) do
      sides[fighter.side] = true
      self:_emit("run", { slot = fighter.slot, side = fighter.side, text = fighter.name })
    end
    if sides.a and sides.b then
      self:_finish("draw", nil, nil, "run", "run", nil)
    elseif sides.a then
      self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "run", "run", "a")
    else
      self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "run", "run", "b")
    end
    return true
  end

  for _, fighter in ipairs(running) do
    local b = fighter.b
    if b and b.mon.hp > 0 then
      fighter.acted = true
      local he = Items.of(b)
      local escaped = false
      if he == Items.HOLD.CAN_ALWAYS_RUN then
        local lbl = self:itemLabel(b)
        Items.heldEvent(self, b, int(b.mon.heldItem, 0), lbl)
        self:say(self:nameOf(b) .. " fled using its " .. lbl .. "!")
        escaped = true
      elseif b.ability == "RUN_AWAY" then
        if self.rules.pyramidRun then
          -- pokeemerald/src/battle_util.c:429: in the Pyramid Run Away rolls
          -- too, the try counted before the roll.
          self.fleeAttempts = self.fleeAttempts + 1
          escaped = self:_pyramidEscape(b)
          if escaped then
            self:emitAbility(b)
            self:say(self:nameOf(b) .. " fled using RUN AWAY!")
          end
        else
          self:emitAbility(b)
          self:say(self:nameOf(b) .. " fled using RUN AWAY!")
          escaped = true
        end
      elseif self.ghost == "veiled" and fighter.side == "a" then
        -- pokefirered/src/battle_main.c:4252: from a GHOST the player's side
        -- always gets away, no try counted.
        escaped = true
        self:say("Got away safely!")
      else
        local foe = self:foes(b)[1]
        local mySpe = int(b.mon.stats.spe, 0)
        local foeSpe = foe and int(foe.mon.stats.spe, 0) or 0
        if self.rules.pyramidRun then
          -- pokeemerald/src/battle_util.c:451: the Pyramid rolls whatever the
          -- speeds.
          escaped = self:_pyramidEscape(b)
        elseif mySpe < foeSpe then
          local speedVar = (floor(mySpe * 128 / max(1, foeSpe)) + self.fleeAttempts * 30) % 256
          escaped = speedVar > self:roll(0, 255)
        else
          escaped = true
        end
        self.fleeAttempts = self.fleeAttempts + 1
        if escaped then self:say("Got away safely!") end
      end
      if escaped then
        self:_emit("run", { slot = fighter.slot, side = fighter.side, text = fighter.name })
        local other = fighter.side == "a" and "b" or "a"
        self:_finish("win", self:_sidePlayers(other), self:_sidePlayers(fighter.side), "run",
          "run", fighter.side)
        return true
      end
      -- pokefirered/src/battle_main.c:4311: a failed escape clears Fury
      -- Cutter, Destiny Bond and Grudge like a bag action.
      b.furyCutter, b.destinyBond, b.grudge = nil, nil, nil
      self:say("Can't escape!")
    end
  end
  return false
end

-- The Pyramid's escape roll (pokeemerald/src/battle_util.c:434 / :453): speed
-- times the floor's multiplier over the foe's, plus 30 a try, as a byte.
function Battle:_pyramidEscape(b)
  local foe = self:foes(b)[1]
  local mySpe = int(b.mon.stats.spe, 0)
  local foeSpe = foe and int(foe.mon.stats.spe, 0) or 0
  local speedVar = (floor(mySpe * self.rules.pyramidRun / max(1, foeSpe)) + self.fleeAttempts * 30) % 256
  return speedVar > self:roll(0, 255)
end

-- A wild seat's RUN when its turn comes (pokefirered/src/battle_main.c:4317
-- HandleAction_Run, the opponent arm; pokeemerald battle_util.c:526): a
-- partial trap or Mean Look / Block / Spider Web holds it ("can't escape!",
-- B_MSG_ATTACKER_CANT_ESCAPE, the turn spent); nothing else is asked -- no
-- speed, no Smoke Ball, no Shadow Tag, no Ingrain, no sleep or freeze -- and it
-- is gone: B_OUTCOME_MON_FLED, `how = "flee"`.
function Battle:_wildFlee(fighter)
  local b = fighter.b
  if int(b.trapTurns, 0) > 0 or b.trappedBy ~= nil then
    self:say("Wild " .. self:nameOf(b) .. " can't escape!")
    return
  end
  self:say("Wild " .. self:nameOf(b) .. " fled!")
  self:_emit("run", { slot = fighter.slot, side = fighter.side, text = fighter.name })
  local other = fighter.side == "a" and "b" or "a"
  self:_finish("win", self:_sidePlayers(other), self:_sidePlayers(fighter.side), "run",
    "flee", fighter.side)
end

-- Pursuit aimed at a seat that is switching out strikes first, doubled
-- (engine init.lua D.pursuitRow / switchStep; pret Cmd_pursuitrelated).
function Battle:_pursuitBefore(fighter)
  local foes = self:_foeSeats(fighter)
  for i = #foes, 1, -1 do
    local foe = foes[i]
    local fb = foe.b
    local choice = foe.choice
    if fb and fb.mon.hp > 0 and choice and choice.action == "fight" and not foe.acted
        and fighter.b and fighter.b.mon.hp > 0 then
      local row = (not choice.recharge) and self:_actionMove(fb, choice) or nil
      local s = Status.normalise(fb.mon.status)
      if row and int(row.effect, -1) == E.PURSUIT and choice.target == fighter.slot
          and s ~= "SLP" and s ~= "FRZ" and int(fb.truantCounter, 0) == 0 then
        foe.acted = true
        self:_fightAction(foe, choice, { pursuit = true })
        self:_afterAction()
        self:_faintSweep()
        self:_drainExp()
        if not self.result then self:_checkOver() end
        if self.result then return end
      end
    end
  end
end

-- pokefirered/src/battle_main.c:3532 SetActionsAndBattlersTurnOrder: the
-- switch and bag actions go first, TOGETHER, in battler order (a1, b1, a2, ...),
-- ahead of every move -- a1's Potion before b1's switch.  Balls are the one
-- exception, BattleSim2's policy (sheet doc §6): they wait for the other bag
-- actions and are thrown fastest first (`_resolveItems`).
function Battle:_resolveSwitches()
  for _, fighter in ipairs(self.order) do
    if self.result then return end
    local choice = fighter.choice
    if choice and choice.action == "switch" then
      local mon = fighter.mons[choice.slot]
      if fighter.b and fighter.b.mon.hp > 0 then self:_pursuitBefore(fighter) end
      if self.result then return end
      if mon and mon.hp > 0 and (fighter.b == nil or fighter.b.mon.hp > 0) then
        fighter.acted = true
        local nb = self:_switchIn(fighter, choice.slot)
        self:switchInEffects(nb, { spikes = true })
        self:_faintSweep()
        self:_drainExp()
        if not self.result then self:_checkOver() end
      end
    elseif choice and choice.action == "item" then
      local effect = Items.bagEffect(choice.item)
      if not (effect and effect.ball) then
        self:_useItem(fighter)
        self:_refreshVacant()
      end
    end
  end
end

-- The balls, after every other bag action, fastest thrower first.
function Battle:_resolveItems()
  local balls = {}
  for i, fighter in ipairs(self.order) do
    local choice = fighter.choice
    if choice and choice.action == "item" then
      local effect = Items.bagEffect(choice.item)
      if effect and effect.ball then
        balls[#balls + 1] = { f = fighter, pri = 0, spe = fighter.b and self:_speedOf(fighter.b) or 0, order = i }
      end
    end
  end
  self:_orderRows(balls)
  for _, r in ipairs(balls) do
    if self.result then return end
    self:_useItem(r.f)
  end
end

local SHAKE_TEXT = {
  [0] = "Oh, no! The POKeMON broke free!", [1] = "Aww! It appeared to be caught!",
  [2] = "Aargh! Almost had it!", [3] = "Shoot! It was so close, too!",
}

function Battle:_caughtSheet(b, ball)
  local mon = b.mon
  local moves = {}
  for i = 1, #mon.moves do moves[i] = copyMove(mon.moves[i]) end
  return {
    generation = 3, species = mon.species, speciesId = mon.speciesId, speciesNum = mon.speciesNum,
    level = mon.level, hp = mon.hp, maxHp = mon.maxHp, status = mon.status,
    stats = { atk = mon.stats.atk, def = mon.stats.def, spe = mon.stats.spe,
              spa = mon.stats.spa, spd = mon.stats.spd },
    types = { mon.types[1], mon.types[2] }, ability = mon.ability, heldItem = mon.heldItem,
    holdEffect = mon.holdEffect, holdEffectParam = mon.holdParam, gender = mon.gender,
    friendship = mon.friendship, nature = mon.nature, catchRate = mon.catchRate,
    ivs = mon.ivs, evs = mon.evs, personality = mon.personality, otId = mon.otId,
    moves = moves, ball = ball,
  }
end

function Battle:_useItem(fighter)
  local choice = fighter.choice
  if not (choice and choice.action == "item") then return end
  fighter.acted = true
  -- pokefirered/src/battle_main.c:4155 HandleAction_UseItem:
  -- ClearFuryCutterDestinyBondGrudge on the seat's battler.
  if fighter.b then
    fighter.b.furyCutter, fighter.b.destinyBond, fighter.b.grudge = nil, nil, nil
  end
  local item = choice.item
  local effect = Items.bagEffect(item)
  self:_emit("item", { slot = fighter.slot, side = fighter.side, text = tostring(item) })
  local label = fighter.bagNames[item]
  self:say(fighter.name .. " used " .. (label or "an item") .. "!")
  if not (effect and effect.noConsume) then self:_spendBag(fighter, item) end

  if not effect then
    self:say("But it failed!")
    return
  end

  if effect.ball then
    local foe = isWildMode(self.mode) and self:_firstLivingFoe(fighter) or nil
    local target = foe and foe.b
    if not target then
      self:say("But it failed!")
      return
    end
    if self.ghost then
      -- pokefirered/src/battle_script_commands.c:9473: a GHOST dodges every
      -- ball, veiled or unveiled -- no roll, the ball spent ("It dodged the
      -- thrown BALL! This POKeMON can't be caught!").
      self:_emit("ball", { slot = fighter.slot, side = fighter.side, target = foe.slot,
                           amount = -1, text = tostring(item) })
      self:say("It dodged the thrown BALL! This POKeMON can't be caught!")
      return
    end
    local caught, shakes = Catch.attempt(item, target, self.rng, {
      types = target.mon.types, level = target.mon.level, turn = self.turn - 1,
      underwater = self.underwater, dexCaught = choice.dexCaught,
    })
    self:_emit("ball", { slot = fighter.slot, side = fighter.side, target = foe.slot,
                         amount = caught and 4 or shakes, text = tostring(item) })
    if caught then
      self:say("Gotcha! " .. self:nameOf(target) .. " was caught!")
      local finish = self:_finish("win", self:_sidePlayers(fighter.side),
        self:_sidePlayers(fighter.side == "a" and "b" or "a"), "catch", "catch", fighter.side)
      if finish then
        finish.caught = self:_caughtSheet(target, item)
        finish.catcher = fighter.owner
      end
    else
      self:say(SHAKE_TEXT[shakes] or SHAKE_TEXT[0])
    end
    return
  end

  if effect.escape then
    if isWildMode(self.mode) then
      self:say("Got away safely!")
      self:_finish("win", self:_sidePlayers(fighter.side),
        self:_sidePlayers(fighter.side == "a" and "b" or "a"), "run", "run", fighter.side)
    else
      self:say("But it failed!")
    end
    return
  end

  if effect.flute then
    local woke = false
    for _, seat in ipairs(self.order) do
      -- Each party once, from its first seat: a shared team's partner wakes
      -- on its own battler.
      if seat.seats[1] == seat then
        for i = 1, #seat.mons do
          local mon = seat.mons[i]
          if Status.normalise(mon.status) == "SLP" and mon.hp > 0 then
            woke = true
            local b = self:_partyBattler(seat, i)
            if b then
              self:cure(b, nil)
            else
              mon.status, mon.sleepTurns = nil, nil
            end
          end
        end
      end
    end
    self:say(woke and "All sleeping POKeMON woke up!" or "Nothing happened.")
    self:_syncTeams()
    return
  end

  local index = choice.slot or fighter.active
  local mon = fighter.mons[index]
  local b = self:_partyBattler(fighter, index)
  if not mon or not self:_itemHasEffect(fighter, effect, index, choice.move) then
    self:say("But it had no effect!")
    return
  end

  if effect.stage and b then
    Effects.changeStat(self, b, effect.stage, 1, { user = true })
    return
  end
  if effect.focusEnergy and b then
    b.focusEnergy = true
    self:say(self:nameOf(b) .. " is getting pumped!")
    return
  end
  if effect.mist and b then
    self.sides[b.side].mistTurns = Field.MIST_TURNS
    self:say(self:nameOf(b) .. "'s party became shrouded in MIST!")
    return
  end

  if effect.revive then
    local hp = (effect.revive == "full") and mon.maxHp or max(1, floor(mon.maxHp / 2))
    mon.hp = hp
    mon.status, mon.sleepTurns = nil, nil
    self:say(mon.species .. " was revived!")
    self:_syncTeams()
    return
  end

  if effect.pp or effect.ppFull or effect.ppAll or effect.ppAllFull then
    local moves = (b and b.moves) or mon.moves
    local function restore(mv, amount)
      if amount == true then mv.pp = mv.maxPp else mv.pp = min(mv.maxPp, mv.pp + amount) end
    end
    if effect.pp or effect.ppFull then
      restore(moves[choice.move], effect.ppFull and true or effect.pp)
    else
      for i = 1, #moves do restore(moves[i], effect.ppAllFull and true or effect.ppAll) end
    end
    self:say(mon.species .. "'s PP was restored.")
    if b then self:emitMovesOf(b) end
    return
  end

  if effect.healFull or effect.heal then
    local amount = effect.healFull and mon.maxHp or effect.heal
    if b then
      local gained = self:heal(b, amount)
      self:say(mon.species .. "'s HP was restored by " .. gained .. " point(s).")
    else
      local before = mon.hp
      mon.hp = min(mon.maxHp, mon.hp + amount)
      self:say(mon.species .. "'s HP was restored by " .. (mon.hp - before) .. " point(s).")
    end
  end
  local s = Status.normalise(mon.status)
  if effect.cure and s and effect.cure[s] then
    local text = mon.species .. " was cured of its " .. (Status.WORD[s] or "status") .. " problem."
    if b then
      b.nightmare = nil
      self:cure(b, text)
    else
      mon.status, mon.sleepTurns = nil, nil
      self:say(text)
    end
  end
  if effect.confusion and b and int(b.confusion, 0) > 0 then
    b.confusion = nil
    local text = mon.species .. " snapped out of confusion!"
    self:_emit("status", { slot = b.slot, side = b.side, confused = 0, text = text })
    self:say(text)
  end
  if effect.attract and b and b.infatuatedWith then
    b.infatuatedWith = nil
    self:say(mon.species .. " got over its infatuation.")
  end
  self:_syncTeams()
end

function Battle:_resolveFights()
  for _, r in ipairs(self.fightRows or {}) do
    if self.result then break end
    local f = r.f
    -- The battler that chose is the only one that acts: a replacement does not
    -- inherit the turn, and a Pursuit already spent it.
    if not f.acted and f.b == r.b and r.b.mon.hp > 0 then
      f.acted = true
      if r.flee then self:_wildFlee(f) else self:_fightAction(f, f.choice) end
      self:_afterAction()
    end
    self:_faintSweep()
    self:_drainExp()
    if not self.result then self:_checkOver() end
  end
end

-- ------------------------------------------------------------------
-- faints
-- ------------------------------------------------------------------

function Battle:_faintSweep()
  for _, f in ipairs(self.order) do
    local b = f.b
    if b and b.mon.hp <= 0 and not b.faintAnnounced then self:_faintBattler(b) end
  end
end

-- ------------------------------------------------------------------
-- participation (BattleSim2's, verbatim in behaviour)
-- ------------------------------------------------------------------

-- Participation is keyed by PARTY member, not by seat: pret's sentIn bits
-- (gSentPokesToOpponent) are party indices, so a shared team's mon that
-- fought from both seats is one participant.  The key names the party by its
-- first seat's slot -- a one-seat fighter's own.
local function foughtKey(fighter, index)
  return fighter.seats[1].slot .. ":" .. index
end

function Battle:_refield(fighter)
  fighter.fought = {}
  fighter.foughtSeats = nil
  local mine = activeMon(fighter) and fighter.active or nil
  local foes = self.bySide[fighter.side == "a" and "b" or "a"]
  for _, foe in ipairs(foes) do
    if activeMon(foe) then
      fighter.fought[foughtKey(foe, foe.active)] = true
      if mine then
        foe.fought = foe.fought or {}
        foe.fought[foughtKey(fighter, mine)] = true
      end
    end
  end
  local pending = fighter.pendingFought
  fighter.pendingFought = nil
  if pending then
    for i = 1, #pending do fighter.fought[pending[i]] = true end
  end
end

function Battle:_standingOpposition(fighter)
  local keys = {}
  local foes = self.bySide[fighter.side == "a" and "b" or "a"]
  for _, foe in ipairs(foes) do
    if activeMon(foe) then keys[#keys + 1] = foughtKey(foe, foe.active) end
  end
  return keys
end

-- A participant that faints stops being one (it earns nothing), but its SEAT
-- is remembered as having fought (`foughtSeats`): pret's sentIn bits outlive a
-- faint, and a seat whose participants all fell still pays its Exp. Share
-- holders (`_awardExp`).  A shared team is remembered as one seat, its first.
function Battle:_unfield(fighter, index)
  local key = foughtKey(fighter, index)
  for _, other in ipairs(self.fighters) do
    if other.fought and other.fought[key] then
      other.foughtSeats = other.foughtSeats or {}
      other.foughtSeats[fighter.seats[1].slot] = true
    end
    if other.fought then other.fought[key] = nil end
    local pending = other.pendingFought
    if pending then
      for i = #pending, 1, -1 do
        if pending[i] == key then table.remove(pending, i) end
      end
    end
  end
end

-- The non-link fights, where the cart pays EXP (and Pay Day); M.BADGE_MODES is
-- the same set, gating the badge rules at create.
local EXP_MODES = { wild = true, coop_wild = true, coop_npc = true }
local EXP_OWNER_SIDE = "a"

-- The field slot an `exp` fact names for party member `index`: the seat it is
-- out on, else (benched) its party's first seat.
function Battle:_expSlot(fighter, index)
  local seat = self:fieldedSeat(fighter, index) or fighter.seats[1]
  return seat.slot
end

-- One pass per PARTY (its first seat): a shared team's mon is one participant
-- however many seats it fought from, and gets one `exp` fact.
function Battle:_awardExp(fallen, mon)
  if not EXP_MODES[self.mode] then return end
  if self.rules.noExp then return end
  if fallen.side == EXP_OWNER_SIDE then return end
  local fought = fallen.fought or {}
  local participants, alive = 0, {}
  local seatFought, seatPaid = {}, {}
  for _, fighter in ipairs(self.bySide[EXP_OWNER_SIDE]) do
    if fighter.seats[1] == fighter then
      if fallen.foughtSeats and fallen.foughtSeats[fighter.slot] then seatFought[fighter] = true end
      for index = 1, #fighter.mons do
        if fought[foughtKey(fighter, index)] then
          participants = participants + 1
          seatFought[fighter] = true
          if fighter.mons[index].hp > 0 then
            alive[#alive + 1] = { fighter = fighter, index = index }
            seatPaid[fighter] = true
          end
        end
      end
    end
  end
  if participants == 0 then
    for _, fighter in ipairs(self.bySide[EXP_OWNER_SIDE]) do
      if activeMon(fighter) then
        participants = participants + 1
        alive[#alive + 1] = { fighter = fighter, index = fighter.active }
        seatFought[fighter.seats[1]], seatPaid[fighter.seats[1]] = true, true
      end
    end
  end
  for _, winner in ipairs(alive) do
    self:_emit("exp", {
      slot = self:_expSlot(winner.fighter, winner.index), species = mon.species,
      speciesId = mon.speciesId, level = mon.level, participants = participants,
      mon = winner.index - 1,
    })
  end
  -- pokefirered/src/battle_script_commands.c:3113 Cmd_getexp pays the living
  -- Exp. Share holders whether or not any participant still stands (viaSentIn
  -- 0 is a SAFE_DIV, :3170).  A seat that fought this foe but has nobody
  -- standing who did gets the holders-only fact: `participants` 0 and no
  -- `mon`.  Its client prices it as a knockout with an empty sentIn set, so
  -- only the holders' half is paid (sheet doc §7).
  for _, fighter in ipairs(self.bySide[EXP_OWNER_SIDE]) do
    if seatFought[fighter] and not seatPaid[fighter] and firstLiving(fighter.mons) then
      self:_emit("exp", {
        slot = fighter.slot, species = mon.species, speciesId = mon.speciesId,
        level = mon.level, participants = 0,
      })
    end
  end
end

function Battle:_drainExp()
  local queue = self.pendingExp
  if #queue == 0 then return end
  self.pendingExp = {}
  for i = 1, #queue do self:_awardExp(queue[i].fallen, queue[i].mon) end
end

-- A battler is down: the `faint` event, the participation bookkeeping, and the
-- seat's next step (BattleSim2 `_faint`).  Called at the engine's announcement
-- points (Move.lua tryFaint*, the residual steps, the action sweep).
function Battle:_faintBattler(b)
  if b.faintAnnounced then return end
  b.faintAnnounced = true
  local fighter = b.fighter
  if fighter.b ~= b then return end
  local mon = b.mon
  mon.hp = 0
  mon.status, mon.sleepTurns = nil, nil
  self:_unfield(fighter, b.partyIndex)
  self:_unlink(b)
  -- A shared team's bench leaves out the partner's active mon (`benchOf`).
  local next_ = self:benchOf(fighter)[1]
  self:_emit("faint", {
    slot = fighter.slot, side = fighter.side, text = mon.species, amount = next_ and 1 or nil,
  })
  self:_syncTeams()
  self.pendingExp[#self.pendingExp + 1] = { fallen = fighter, mon = mon }
  fighter.lastB = b
  fighter.b = nil
  fighter.active = nil
  if next_ then
    fighter.mustReplace = true
    fighter.pendingFought = self:_standingOpposition(fighter)
  else
    fighter.mustReplace = nil
    fighter.pendingFought = nil
    -- No bench: a shared team's seat is pret's absent battler until a Revive
    -- gives the party one again (`_refreshVacant`).
    if #fighter.seats > 1 then fighter.vacant = true end
  end
  if self.phase ~= "resolving" then
    self:_drainExp()
    self:_checkOver()
  end
end

-- ------------------------------------------------------------------
-- endings
-- ------------------------------------------------------------------

function Battle:_checkOver()
  if self.result then return true end
  local aliveA, aliveB = self:_sideAlive("a"), self:_sideAlive("b")
  if aliveA and aliveB then return false end
  if not aliveA and not aliveB then
    self:_finish("draw", nil, nil, "ko", "ko", nil)
  elseif aliveA then
    local result = self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "ko", "ko", "a")
    -- pokefirered/src/battle_main.c:3764: only a WON battle runs
    -- BattleScript_PayDayMoneyAndPickUpItems (Cmd_givepaydaymoney), and the
    -- coins are the player side's.  Link rules pay nothing (1v1 / coop_pvp); in
    -- the other modes side a is the player side.  The Amulet Coin doubling
    -- (gBattleStruct->moneyMultiplier) and the wallet are the client's.
    local coins = int(self.payDay and self.payDay.a, 0)
    if result and EXP_MODES[self.mode] and coins > 0 then result.payDay = coins end
  else
    self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "ko", "ko", "b")
  end
  return true
end

-- `how` (M.HOW) and `by` (the side whose action ended it) are contract C3's;
-- both nil for a disconnect or a timeout.  Oak's closing lesson comes right
-- before `over`: "win" on a KO side a won, "lose" on any other KO, a draw
-- included (HandleEndTurn_BattleLost runs for B_OUTCOME_DREW).
function Battle:_finish(outcome, winners, losers, reason, how, by)
  if self.result then return self.result end
  self.result = {
    battle = self.id, outcome = outcome, winners = winners, losers = losers, reason = reason,
    how = how, by = by,
  }
  self.phase = "over"
  self.deadline = nil
  self.resolveDeadline = nil
  if how == "ko" then self:_lesson((by == "a") and "win" or "lose") end
  self:_emit("over", { text = reason })
  return self.result
end

function Battle:outcome()
  return self.result
end

-- ------------------------------------------------------------------
-- the clock (BattleSim2's)
-- ------------------------------------------------------------------

function Battle:disconnect(playerId)
  local fighter = self.byId[str(playerId) or ""]
  if not fighter or not fighter.connected then return false end
  if self.result then return false end
  fighter.connected = false
  fighter.graceEndsAt = self.now + self.reconnectGrace
  self:_emit("wait", { side = fighter.side, text = fighter.name })
  return true
end

function Battle:reconnect(playerId)
  local fighter = self.byId[str(playerId) or ""]
  if not fighter or fighter.connected then return false end
  if self.result then return false end
  if fighter.graceEndsAt and self.now >= fighter.graceEndsAt then return false end
  fighter.connected = true
  fighter.graceEndsAt = nil
  self:_emit("reconnect", { side = fighter.side, text = fighter.name })
  if (self.phase == "choice" or self.phase == "replace")
     and not self:_anyDisconnected() and self.choiceTimeout > 0 then
    self.deadline = self.now + self.choiceTimeout
  end
  self:_maybeResolve()
  return true
end

function Battle:tick(nowSeconds)
  local now = int(nowSeconds, self.now)
  if now > self.now then self.now = now end
  if self.result then return false end

  if (self.phase == "choice" or self.phase == "replace") and self:_checkOver() then
    return true
  end

  if self.forcedPending and self.phase == "choice" and not self:_anyDisconnected() then
    self.forcedPending = false
    if not self:_anyoneOwes() then
      self:_maybeResolve()
      return true
    end
  end

  local expiredA, expiredB = false, false
  for _, fighter in ipairs(self.fighters) do
    if not fighter.connected and fighter.graceEndsAt and self.now >= fighter.graceEndsAt then
      if fighter.side == "a" then expiredA = true else expiredB = true end
    end
  end
  if expiredA or expiredB then
    if expiredA and expiredB then
      self:_finish("draw", nil, nil, "disconnect")
    elseif expiredA then
      self:_finish("forfeit", self:_sidePlayers("b"), self:_sidePlayers("a"), "disconnect")
    else
      self:_finish("forfeit", self:_sidePlayers("a"), self:_sidePlayers("b"), "disconnect")
    end
    return true
  end

  if self.phase == "resolving" and self.resolveDeadline and self.now >= self.resolveDeadline then
    self:_finish("draw", nil, nil, "timeout")
    return true
  end

  if (self.phase == "choice" or self.phase == "replace")
     and self.deadline and self.now >= self.deadline and not self:_anyDisconnected() then
    for _, fighter in ipairs(self.fighters) do
      if self:_owes(fighter) then
        local auto = self:_autoChoiceOrSkip(fighter)
        if auto then
          fighter.choice = auto
          self:_emit("chose", { slot = fighter.slot, side = fighter.side, text = fighter.name })
          self:say(fighter.name .. " ran out of time")
        end
      end
    end
    self:_maybeResolve()
    if (self.phase == "choice" or self.phase == "replace")
       and self.deadline and self.now >= self.deadline then
      self.deadline = self.now + self.choiceTimeout
    end
    return true
  end

  return false
end

-- ------------------------------------------------------------------
-- snapshot (tests and logs)
-- ------------------------------------------------------------------

function Battle:snapshot()
  local field, waiting, owing = {}, {}, {}
  for _, fighter in ipairs(self.fighters) do
    local b = fighter.b
    local mon = b and b.mon
    local party = {}
    for i = 1, #fighter.mons do party[i] = fighter.mons[i].hp end
    field[#field + 1] = {
      slot = fighter.slot, side = fighter.side, playerId = fighter.playerId, name = fighter.name,
      connected = fighter.connected, graceEndsAt = fighter.graceEndsAt,
      chose = fighter.choice ~= nil and fighter.choice.action or nil,
      mustReplace = fighter.mustReplace == true,
      species = mon and mon.species or nil,
      hp = mon and mon.hp or 0, maxHp = mon and mon.maxHp or 0,
      status = mon and mon.status or nil,
      party = party,
    }
    -- `waiting` names owners, each once: a shared team is one player.
    if self:_owes(fighter) and not owing[fighter.owner] then
      owing[fighter.owner] = true
      waiting[#waiting + 1] = fighter.owner
    end
  end
  return {
    battle = self.id, mode = self.mode, phase = self.phase, turn = self.turn, seq = self.seq,
    now = self.now, deadline = self.deadline, resolveDeadline = self.resolveDeadline,
    over = self.result ~= nil, reason = self.result and self.result.reason or nil,
    rngState = self.rng:state(), weather = self.field.weather,
    field = field, waiting = waiting,
    payDay = { a = self.payDay.a, b = self.payDay.b },
  }
end

return M
