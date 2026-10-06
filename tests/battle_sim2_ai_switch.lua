-- src/BattleSim2/AiSwitch.lua: the computer's switches and items on Gold /
-- Silver / Crystal (AI_SwitchOrTryItem, CheckAbleToSwitch,
-- FindMonInOTPartyToSwitchIntoBattle), routine by routine.
--
-- Run: luajit tests/battle_sim2_ai_switch.lua              (from this folder's root)
--   or luajit mods/rby_mmo/tests/battle_sim2_ai_switch.lua (from the engine)
--
-- Every scenario builds a real referee battle (BattleSim2/Turn's `create`) on
-- synthetic sheets, sets the K16 fields the hook keeps, and asks the module.
-- The draws are scripted (`script`): a branch the cart decides by a Random
-- byte is pinned on both sides of its threshold, and the count of bytes taken
-- is pinned with it -- the order of the draws is the contract the Node twin
-- (server/battle2_ai_switch.test.js, the same scenarios) is held to.
--
-- Synthetic throughout: the types are NORMAL / FIGHTING / GHOST (the names the
-- Foresight rows key on) and three invented ones, the chart's cells are
-- invented, and no species, move or ROM value appears.

local ROOT = "."
do
  local invoked = arg and arg[0]
  local dir = invoked and invoked:match("^(.*)[/\\]tests[/\\][^/\\]+$")
  if dir and dir ~= "" then ROOT = dir end
end

local function slurp(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local body = handle:read("*a")
  handle:close()
  return body
end

local loadstr = loadstring or load
local cache = {}
local function need(name)
  if cache[name] ~= nil then return cache[name] end
  local path = ROOT .. "/src/" .. name .. ".lua"
  local body = slurp(path)
  if not body then
    io.stderr:write("battle_sim2_ai_switch: missing " .. path .. "\n")
    os.exit(1)
  end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then
    io.stderr:write("battle_sim2_ai_switch: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  cache[name] = chunk(need)
  return cache[name]
end

local Turn = need("BattleSim2/init").Turn
local Effects = need("BattleSim2/Effects")
local A = need("BattleSim2/AiSwitch")

-- ------------------------------------------------------------------
-- assertions
-- ------------------------------------------------------------------

local passed, failed = 0, 0

local function ok(condition, what)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write("FAIL " .. tostring(what) .. "\n")
  end
end

local function eq(actual, expected, what)
  if actual == expected then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format("FAIL %s: expected %s, got %s\n",
      tostring(what), tostring(expected), tostring(actual)))
  end
end

-- A decision as one string: "nil", "switch 3", "item POTION 2".
local function said(decision)
  if decision == nil then return "nil" end
  if decision.action == "switch" then return "switch " .. tostring(decision.slot) end
  return "item " .. tostring(decision.item) .. " " .. tostring(decision.trainerSlot)
end

-- ------------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------------

local TYPE_IDS = { "NORMAL", "FIGHTING", "GHOST", "ALPHA", "BETA", "GAMMA" }
local N, F, G, AL, BE, GA = 0, 1, 2, 3, 4, 5

-- An invented chart: ALPHA is super effective on BETA, weak on GAMMA, nothing
-- on GHOST; BETA beats ALPHA; GAMMA beats BETA; the two Foresight rows.
local function chartOf(cells)
  local rows = {}
  for i = 1, #TYPE_IDS do
    rows[i] = {}
    for j = 1, #TYPE_IDS do rows[i][j] = 100 end
  end
  for _, cell in ipairs(cells) do rows[cell[1] + 1][cell[2] + 1] = cell[3] end
  return rows
end

local CHART = chartOf({
  { AL, BE, 200 }, { AL, GA, 50 }, { AL, G, 0 },
  { BE, AL, 200 }, { BE, GA, 50 },
  { GA, BE, 200 }, { GA, AL, 50 },
  { N, G, 0 }, { F, G, 0 }, { F, N, 200 },
})

local function mv(o)
  o = o or {}
  return {
    id = o.id or "hit", pp = 10, power = o.power ~= nil and o.power or 40,
    accuracy = 255, type = o.type or N, effect = 0, chance = 0,
  }
end

local function mn(o)
  o = o or {}
  return {
    species = o.species or "Mon", level = o.level or 20,
    hp = o.hp, maxHp = o.maxHp or 100, types = o.types or { N },
    status = o.status, statusTurns = o.statusTurns, confusion = o.confusion,
    stats = { atk = o.atk or 40, def = 40, spe = o.spe or 40, spa = 40, spd = 40 },
    moves = o.moves or { mv() },
  }
end

-- A coop_npc fight: the player's seat "p1" (side a) against the computer's
-- "npc" (side b, "LASS AMY").  `o.fields` lands on the computer's seat,
-- `o.mon` on its active monster, `o.foeMon` on the player's, `o.battle` on the
-- battle; `o.bytes` scripts the draws.
local function fight(o)
  local battle = Turn.create({
    id = "ai", mode = o.mode or "coop_npc", seed = 7, chart = o.chart or CHART,
    typeIds = TYPE_IDS,
    sides = {
      a = { { playerId = "p1", name = "Ann", family = o.family or "gs",
              mons = o.foe or { mn({ species = "Foe", types = o.foeTypes or { N } }) } } },
      b = { { playerId = "npc", name = "LASS AMY", mons = o.npc or { mn() } } },
    },
  })
  if not battle then error("fixture refused", 0) end
  battle:drainEvents()
  local npc, foe = battle.byId.npc, battle.byId.p1
  if o.active then npc.active = o.active end
  for k, v in pairs(o.fields or {}) do npc[k] = v end
  local mon = npc.mons[npc.active]
  for k, v in pairs(o.mon or {}) do mon[k] = v end
  local foeMon = foe.mons[foe.active]
  for k, v in pairs(o.foeMon or {}) do foeMon[k] = v end
  for k, v in pairs(o.battle or {}) do battle[k] = v end
  local queue, taken = {}, { n = 0, over = false }
  for i, b in ipairs(o.bytes or {}) do queue[i] = b end
  battle.rng = {
    byte = function()
      taken.n = taken.n + 1
      local b = table.remove(queue, 1)
      if b == nil then taken.over = true; return 0 end
      return b
    end,
    state = function() return 0 end,
  }
  return { battle = battle, npc = npc, foe = foe, mon = mon, foeMon = foeMon,
           taken = taken, left = queue }
end

local function decide(f)
  return A.switchOrTryItem(f.battle, f.npc, f.foe)
end

local function viewOf(f)
  return A.viewOf(f.battle, f.npc, f.foe)
end

local function texts(battle, kind)
  local out = {}
  for _, e in ipairs(battle:drainEvents()) do
    if kind == nil or e.t == kind then out[#out + 1] = e end
  end
  return out
end

-- ------------------------------------------------------------------
-- 1. the guards before any check (AI_SwitchOrTryItem's head)
-- ------------------------------------------------------------------

-- What every guard scenario would otherwise do: a POTION it uses at a quarter
-- of its HP with no draw (`.HealItem`, no flags).
local LOW = { hp = 20 }

do
  local f = fight({ mode = "wild", npc = { mn({ hp = 20 }) }, fields = { trainerItems = { "POTION" } } })
  eq(said(decide(f)), "nil", "wild: wBattleMode's `dec a / ret z`, no item")
  eq(f.taken.n, 0, "...and no byte")
end

do
  local f = fight({ mode = "1v1", npc = { mn({ hp = 20 }) }, fields = { trainerItems = { "POTION" } } })
  eq(said(decide(f)), "nil", "link (1v1): wLinkMode's `ret nz`")
end

do
  local f = fight({ npc = { mn({ hp = 20 }) }, fields = { trainerItems = { "POTION" } } })
  eq(said(A.switchOrTryItem(f.battle, f.foe, f.npc)), "nil", "the player's own seat is never the AI's")
  eq(said(decide(f)), "item POTION 1", "...the computer's is")
end

for _, lock in ipairs({
  { "SUBSTATUS_RECHARGE", { mustRecharge = true } },
  { "SUBSTATUS_CHARGED", { charging = { moveIndex = 1, effect = 0 } } },
  { "SUBSTATUS_BIDE", { bide = { turns = 1, stored = 0, moveIndex = 1 } } },
  { "SUBSTATUS_RAMPAGE", { thrashing = { turns = 1, moveIndex = 1 } } },
  { "SUBSTATUS_ROLLOUT", { rollout = { active = true, moveIndex = 1 } } },
}) do
  local f = fight({ npc = { mn({ hp = 20 }) }, mon = lock[2], fields = { trainerItems = { "POTION" } } })
  eq(said(decide(f)), "nil", "CheckEnemyLockedIn (" .. lock[1] .. "): no switch, no item")
end

do
  local f = fight({ npc = { mn({ hp = 20 }) }, fields = { trainerItems = { "POTION" } },
                    mon = { thrashing = { turns = 0, moveIndex = 1 }, rollout = { active = false } } })
  eq(said(decide(f)), "item POTION 1", "a finished rampage or a stopped ROLLOUT is no lock-in")
end

-- The player's MEAN LOOK on this seat (wPlayerSubStatus5's SUBSTATUS_CANT_RUN)
-- and a wrap on it (wEnemyWrapCount): `DontSwitch` -- the item check alone,
-- with no switch byte, where a perish count of 1 would otherwise switch.
local function perishParty()
  return { mn({ species = "Lead", hp = 20 }), mn({ species = "Back" }) }
end

do
  local f = fight({ npc = perishParty(),
                    fields = { trainerItems = { "POTION" }, itemSwitch = A.SWITCH_OFTEN },
                    mon = { perish = 1 } })
  f.foeMon.meanLook = { slot = f.npc.slot }
  eq(said(decide(f)), "item POTION 1", "held by the player's MEAN LOOK: the item, never the switch")
  eq(f.taken.n, 0, "...and no switch byte")
end

do
  local f = fight({ npc = perishParty(),
                    fields = { trainerItems = { "POTION" }, itemSwitch = A.SWITCH_OFTEN },
                    mon = { perish = 1, trapped = { turns = 2 } } })
  eq(said(decide(f)), "item POTION 1", "wrapped (wEnemyWrapCount): the item, never the switch")
  eq(f.taken.n, 0, "...and no switch byte")
end

do
  local f = fight({ npc = perishParty(), fields = { itemSwitch = A.SWITCH_OFTEN },
                    mon = { perish = 1, trapped = { turns = 0 } }, bytes = { 10 } })
  eq(said(decide(f)), "switch 2", "a wrap count of 0 holds nothing")
end

-- ------------------------------------------------------------------
-- 2. CheckPlayerMoveTypeMatchups, and the false assumption under it
-- ------------------------------------------------------------------
--
-- Every matchup reads the type in wEnemyMoveStruct (here `aiMove`, ALPHA):
-- the type of a move the player used never matters, only its power.

local function score(o)
  o.fields = o.fields or {}
  o.fields.aiMove = o.fields.aiMove or mv({ type = AL })
  local f = fight(o)
  return A.checkPlayerMoveTypeMatchups(viewOf(f))
end

eq(score({ npc = { mn({ types = { BE } }) }, foeTypes = { N } }), 9,
   "unknown moves: ALPHA beats the enemy's own BETA -- once for a single-typed player")
eq(score({ npc = { mn({ types = { BE } }) }, foeTypes = { N, F } }), 8,
   "...and the same check again for a player with a second type (`cp b`)")
eq(score({ npc = { mn({ types = { BE } }) }, foeTypes = { N },
           foeMon = { usedMoves = { mv({ type = N }) } } }), 9,
   "a used move with power: super effective (the struct's type on BETA), down one")
eq(score({ npc = { mn({ types = { N } }) }, foeTypes = { N },
           foeMon = { usedMoves = { mv({ type = BE }) } } }), 10,
   "neutral: unchanged -- the used move's own BETA is never read")
eq(score({ npc = { mn({ types = { GA } }) }, foeTypes = { N },
           foeMon = { usedMoves = { mv() } } }), 11, "not very effective: up one")
eq(score({ npc = { mn({ types = { G } }) }, foeTypes = { N },
           foeMon = { usedMoves = { mv() } } }), 12, "immune: up two")
eq(score({ npc = { mn({ types = { BE } }) }, foeTypes = { N },
           foeMon = { usedMoves = { mv({ power = 0 }), mv({ power = 0 }) } } }), 12,
   "used moves with no power at all: up two, however the type falls")
eq(score({ npc = { mn({ types = { BE } }) }, foeTypes = { N },
           foe = { mn({ types = { N }, moves = { mv({ id = "jab", power = 40 }) } }) },
           foeMon = { usedMoves = { "jab" } } }), 9,
   "a used move stated by id: the player's own row of it, with power (AiMove's reading)")
eq(score({ npc = { mn({ types = { BE } }) }, foeTypes = { N },
           foeMon = { usedMoves = { "gone" } } }), 12,
   "...an id the player no longer knows: no power, up two")
eq(score({ npc = { mn({ types = { BE } }) }, foeTypes = { N, F },
           foeMon = { usedMoves = { "" } } }), 8,
   "...an empty id is the list's end: unknown moves")
eq(score({ npc = { mn({ types = { N }, moves = { mv({ power = 0 }) } }) }, foeTypes = { N } }), 8,
   "`.CheckEnemyMoveMatchups`: no damaging move -- down two")
eq(score({ npc = { mn({ types = { N } }) }, foeTypes = { GA } }), 9,
   "...the enemy's moves not very effective on the player: down one")
eq(score({ npc = { mn({ types = { N } }) }, foeTypes = { BE } }), 11,
   "...super effective: up one")
eq(score({ npc = { mn({ types = { N } }) }, foeTypes = { G } }), 8,
   "...the player immune: counted as none, down two")

-- Foresight: the GHOST rows read neutral while the PLAYER is identified
-- (BATTLE_VARS_SUBSTATUS1_OPP on the enemy's turn), whoever defends.
eq(A.typeMatchup(fight({}).battle, N, { G }, false), 0, "NORMAL on GHOST: 0")
eq(A.typeMatchup(fight({}).battle, N, { G }, true), 10, "...identified: the -2 rows skipped")
eq(score({ npc = { mn({ types = { G } }) }, foeTypes = { N }, fields = { aiMove = mv({ type = N }) },
           foeMon = { usedMoves = { mv() } } }), 12, "NORMAL struct on the enemy's GHOST: immune, up two")
eq(score({ npc = { mn({ types = { G } }) }, foeTypes = { N }, fields = { aiMove = mv({ type = N }) },
           foeMon = { usedMoves = { mv() }, identified = true } }), 10,
   "...the player identified: the enemy's own GHOST loses its immunity too")

-- The struct's type: `aiMove`, else the filed fight choice, else NORMAL.
do
  local f = fight({ npc = { mn({ moves = { mv({ type = GA }), mv({ type = BE }) } }) } })
  f.npc.choice = { action = "fight", move = 2 }
  eq(viewOf(f).moveType, BE, "no aiMove: the filed choice's move")
  f.npc.choice = { action = "fight", move = 1, struggle = true }
  eq(viewOf(f).moveType, N, "...a Struggle: its row's NORMAL")
  f.npc.choice = nil
  eq(viewOf(f).moveType, N, "...nothing filed: NORMAL")
  f.npc.aiMove = mv({ type = GA })
  eq(viewOf(f).moveType, GA, "aiMove wins")
end

-- ------------------------------------------------------------------
-- 3. the bench helpers
-- ------------------------------------------------------------------

-- "bc = [CurHP] * 4" is `srl c / rl b` twice.
eq(A.quarterValue(100), 25, "quarterValue(100): the low byte >> 2, no bits rolled")
eq(A.quarterValue(101), 537, "quarterValue(101): bit 0 rolled into the high byte")
eq(A.quarterValue(102), 281, "quarterValue(102)")
eq(A.quarterValue(103), 793, "quarterValue(103)")
eq(A.quarterValue(256), 1024, "quarterValue(256)")
eq(A.quarterValue(0), 0, "quarterValue(0)")

do
  local f = fight({ npc = {
    mn({ species = "Lead" }),                -- 25 at full HP: not counted
    mn({ hp = 100, maxHp = 300 }),           -- 25: not counted, at a third of its HP
    mn({ hp = 101, maxHp = 300 }),           -- 537: counted
    mn({ hp = 75, maxHp = 80 }),             -- 786: counted
    mn({ hp = 0, maxHp = 1 }),               -- 0: never
  } })
  eq(A.findEnemyMonsWithAtLeastQuarterMaxHP(viewOf(f), 0x3e), 0x08 + 0x04,
     "FindEnemyMonsWithAtLeastQuarterMaxHP counts by the bug's value, not the HP")
  f.battle.family = "crystal"
  eq(A.findEnemyMonsWithAtLeastQuarterMaxHP(viewOf(f), 0x3e), 0x08 + 0x04,
     "...Gold's one-late terminator changes nothing inside the party")
end

-- Gold's FindEnemyMonsThatResistPlayer starts at wOTPartyCount: slot 1 is
-- judged by the species numbered by the party count, every other slot by the
-- species before it.
do
  local party = { mn({ types = { BE } }), mn({ types = { GA } }), mn({ types = { GA } }) }
  local f = fight({ npc = party, family = "crystal", fields = { aiMove = mv({ type = AL }) } })
  eq(A.findEnemyMonsThatResistPlayer(viewOf(f), 0x3f), 0x10 + 0x08,
     "Crystal: each slot by its own species")
  -- (Gold's fourth pass reads slot 3's species for a slot past the party,
  -- bit $04, which the living mask the chain hands in never holds.)
  f = fight({ npc = party, family = "gs", fields = { aiMove = mv({ type = AL }) } })
  eq(A.findEnemyMonsThatResistPlayer(viewOf(f), 0x38), 0x08,
     "Gold: slot 2 judged by slot 1's BETA, slot 3 by slot 2's GAMMA")
  eq(A.findEnemyMonsThatResistPlayer(viewOf(f), 0x3f), 0x08 + 0x04,
     "...the pass past the party sets its own bit, for the mask to drop")
  f.npc.countSpeciesTypes = { GA }
  eq(A.findEnemyMonsThatResistPlayer(viewOf(f), 0x38), 0x20 + 0x08,
     "...and slot 1 by `countSpeciesTypes`")
  f = fight({ npc = party, family = "crystal", fields = { aiMove = mv({ type = AL }) },
              mon = { types = { GA } } })
  eq(A.findEnemyMonsThatResistPlayer(viewOf(f), 0x3f), 0x10 + 0x08,
     "GetBaseData's types: a CONVERSION on the one out changes nothing")
end

-- FindEnemyMonsWithASuperEffectiveMove: the first slot with a damaging move,
-- by whether the struct's type beats the player.
do
  local party = { mn(), mn({ moves = { mv({ power = 0 }) } }), mn(), mn() }
  local f = fight({ npc = party, foeTypes = { BE }, fields = { aiMove = mv({ type = AL }) } })
  local view = viewOf(f)
  eq(A.findEnemyMonsWithASuperEffectiveMove(view, 0x1c), 2, "super effective: e = 2")
  eq(view.score, 2, "...the first slot in the mask with power (slot 2 has none)")
  f = fight({ npc = party, foeTypes = { N }, fields = { aiMove = mv({ type = AL }) } })
  view = viewOf(f)
  eq(A.findEnemyMonsWithASuperEffectiveMove(view, 0x1c), 1, "neutral: e = 1")
  eq(view.score, 2, "...the same first slot")
  f = fight({ npc = party, foeTypes = { GA }, fields = { aiMove = mv({ type = AL }) } })
  view = viewOf(f)
  eq(A.findEnemyMonsWithASuperEffectiveMove(view, 0x1c), 0, "not very effective: e = 0")
  eq(view.score, 0xff, "...and $ff")
end

-- ------------------------------------------------------------------
-- 4. CheckAbleToSwitch, branch by branch
-- ------------------------------------------------------------------

local function param(o)
  local f = fight(o)
  return A.checkAbleToSwitch(viewOf(f))
end

eq(param({ npc = { mn() }, mon = { perish = 1 } }), 0, "a party of one: FindAliveEnemyMons' carry")
eq(param({ npc = { mn(), mn({ hp = 0 }) }, mon = { perish = 1 } }), 0, "...or nobody living on the bench")

-- Perish count 1, nothing with a super-effective move: the first living
-- bench slot at $30.
eq(param({ npc = { mn(), mn({ hp = 0 }), mn() }, mon = { perish = 1 } }), 0x32,
   "perish 1, no super-effective bench: $30 + the first living slot")
-- ...with one: that slot.
eq(param({ npc = { mn({ types = { GA } }),
                   mn({ hp = 101, maxHp = 300, types = { GA }, moves = { mv({ power = 0 }) } }),
                   mn({ hp = 103, maxHp = 300, types = { GA } }) },
           foeTypes = { BE }, mon = { perish = 1 }, fields = { aiMove = mv({ type = AL }) } }), 0x32,
   "perish 1, a super-effective bench slot: $30 + that slot")
eq(param({ npc = { mn({ types = { GA } }),
                   mn({ hp = 101, maxHp = 300, types = { GA } }),
                   mn({ hp = 103, maxHp = 300, types = { GA } }) },
           foeTypes = { BE }, mon = { perish = 2 }, fields = { aiMove = mv({ type = AL }) } }), 0,
   "perish 2: the ordinary reading (score 11, no switch)")

-- The ordinary reading: score at 11 or over, nothing.
eq(param({ npc = { mn(), mn() }, foeTypes = { BE }, fields = { aiMove = mv({ type = AL }) } }), 0,
   "score 11 (the enemy's moves super effective): no switch")

-- `.no_last_counter_move`: score under 10 and a quarter-HP, resisting bench
-- slot with a super-effective move -> $10.
local NO_LAST = {
  npc = { mn({ moves = { mv({ power = 0 }) } }),
          mn({ hp = 101, maxHp = 300, types = { GA } }) },
  foeTypes = { BE }, fields = { aiMove = mv({ type = AL }) },
}
eq(param(NO_LAST), 0x11, "no last counter move: score 8, the chain finds slot 2 -> $11")
do
  local o = { npc = { mn({ moves = { mv({ power = 0 }) } }), mn({ hp = 100, maxHp = 300, types = { GA } }) },
              foeTypes = { BE }, fields = { aiMove = mv({ type = AL }) } }
  eq(param(o), 0, "...slot 2 at 100 HP fails the bug's quarter test: nothing")
end

-- The immune arm: wLastPlayerCounterMove with power, a bench slot whose base
-- types take 0 from the struct's type.
local function immune(o)
  o.npc = o.npc or { mn({ moves = { mv({ power = 0 }) } }), mn({ types = { G }, hp = 101, maxHp = 300 }) }
  o.foeTypes = o.foeTypes or { BE }
  o.fields = { aiMove = mv({ type = AL }) }
  o.foeMon = o.foeMon or { lastCounterMove = mv() }
  return param(o)
end
eq(immune({}), 0x21, "immune slot, super-effective move, score under 10: $20")
eq(immune({ npc = { mn({ types = { BE } }), mn({ types = { G } }) } }), 0x11,
   "...score 10 on the recheck: $10")
eq(immune({ npc = { mn({ types = { BE } }), mn({ types = { G } }) }, foeTypes = { N } }), 0x11,
   "neutral move (e = 1), score 9: $10")
eq(immune({ npc = { mn(), mn({ types = { G } }) }, foeTypes = { N } }), 0,
   "...score 10: nothing")
eq(immune({ npc = { mn(), mn({ types = { G } }) }, foeTypes = { GA } }), 0,
   "no neutral move either ($ff): nothing")
eq(immune({ foeMon = { lastCounterMove = mv({ power = 0 }) } }), 0x11,
   "a last counter move with no power: no immune slot -- the no-counter arm's $10")

-- ------------------------------------------------------------------
-- 5. SwitchOften / Rarely / Sometimes: every band, both sides of each byte
-- ------------------------------------------------------------------

local function band30(flags, byte)
  local f = fight({ npc = { mn(), mn({ hp = 0 }), mn() }, mon = { perish = 1 },
                    fields = { itemSwitch = flags }, bytes = { byte } })
  return said(decide(f)), f.taken.n
end
local function band10(flags, byte)
  local o = { npc = NO_LAST.npc, foeTypes = NO_LAST.foeTypes,
              fields = { aiMove = NO_LAST.fields.aiMove, itemSwitch = flags }, bytes = { byte } }
  local f = fight(o)
  return said(decide(f)), f.taken.n
end
local function band20(flags, byte)
  local f = fight({ npc = { mn({ moves = { mv({ power = 0 }) } }), mn({ types = { G } }) },
                    foeTypes = { BE }, foeMon = { lastCounterMove = mv() },
                    fields = { aiMove = mv({ type = AL }), itemSwitch = flags }, bytes = { byte } })
  return said(decide(f)), f.taken.n
end

for _, row in ipairs({
  { "OFTEN", A.SWITCH_OFTEN, band10, 127, 128 }, { "OFTEN", A.SWITCH_OFTEN, band20, 199, 200 },
  { "RARELY", A.SWITCH_RARELY, band10, 19, 20 }, { "RARELY", A.SWITCH_RARELY, band20, 29, 30 },
  { "SOMETIMES", A.SWITCH_SOMETIMES, band10, 49, 50 }, { "SOMETIMES", A.SWITCH_SOMETIMES, band20, 127, 128 },
}) do
  local name, flags, run, take, stay = row[1], row[2], row[3], row[4], row[5]
  local band = (run == band10) and "$10" or "$20"
  local d, n = run(flags, take)
  eq(d, "switch 2", name .. " " .. band .. ": byte " .. take .. " switches")
  eq(n, 1, "...one byte")
  d = run(flags, stay)
  eq(d, "nil", name .. " " .. band .. ": byte " .. stay .. " stays")
end
for _, row in ipairs({
  { "OFTEN", A.SWITCH_OFTEN, 9, 10 }, { "RARELY", A.SWITCH_RARELY, 199, 200 },
  { "SOMETIMES", A.SWITCH_SOMETIMES, 49, 50 },
}) do
  eq(band30(row[2], row[3]), "nil", row[1] .. " $30: byte " .. row[3] .. " is the chance to stay")
  eq(band30(row[2], row[4]), "switch 3", row[1] .. " $30: byte " .. row[4] .. " switches")
end
eq(band30(A.SWITCH_OFTEN + A.SWITCH_RARELY, 10), "switch 3", "OFTEN is asked before RARELY")
eq(band30(A.SWITCH_RARELY + A.SWITCH_SOMETIMES, 50), "nil", "...RARELY before SOMETIMES")
do
  local d, n = band30(0x0100, 10)
  eq(d, "nil", "the flags are TRNATTR_AI_ITEM_SWITCH's low byte (`bit` on [hl])")
  eq(n, 0, "...no switch flag, no byte")
end
do
  -- The stay falls through to AI_TryItem: its own routine's byte follows.
  local f = fight({ npc = { mn({ hp = 40 }), mn({ hp = 0 }), mn() }, mon = { perish = 1 },
                    fields = { itemSwitch = A.SWITCH_OFTEN, trainerItems = { "POTION" } },
                    bytes = { 9, 127 } })
  eq(said(decide(f)), "item POTION 1", "a stay goes on to the item check")
  eq(f.taken.n, 2, "...the switch byte, then `.HealItem`'s")
end

-- ------------------------------------------------------------------
-- 6. AI_TryItem: every routine, every flag
-- ------------------------------------------------------------------

local function item(o)
  o.fields = o.fields or {}
  o.fields.trainerItems = o.fields.trainerItems or { o.id or "POTION" }
  o.fields.itemSwitch = o.flags or 0
  local f = fight(o)
  local d = decide(f)
  return said(d), f.taken.n, f, d
end

eq(item({ fields = { trainerItems = {} }, mon = LOW }), "nil", "no trainer items: nothing")
eq(item({ fields = { trainerItems = { "NO_ITEM", "NO_ITEM" } }, mon = LOW }), "nil", "...two NO_ITEMs: nothing")
do
  local d, n = item({ npc = { mn({ level = 20 }), mn({ level = 21 }) }, mon = LOW })
  eq(d, "nil", "`.IsHighestLevel`: a higher level on the bench, no item")
  eq(n, 0, "...and no byte")
  d = item({ npc = { mn({ level = 21 }), mn({ level = 21, hp = 0 }) }, mon = LOW })
  eq(d, "item POTION 1", "...a level tie (fainted or not) still counts as the highest")
end

-- `.HealItem`, CONTEXT_USE: above half no; a quarter or less yes; between, a
-- byte under 20 percent - 1.
local function heal(flags, hp, bytes) return item({ flags = flags, mon = { hp = hp }, bytes = bytes }) end
eq(heal(A.CONTEXT_USE, 51), "nil", "CONTEXT_USE above half: no")
eq(heal(A.CONTEXT_USE, 50, { 49 }), "item POTION 1", "CONTEXT_USE at half (not above): byte 49 uses")
eq(heal(A.CONTEXT_USE, 40, { 50 }), "nil", "...byte 50 does not")
do
  local d, n = heal(A.CONTEXT_USE, 25)
  eq(d, "item POTION 1", "CONTEXT_USE at a quarter: used")
  eq(n, 0, "...with no byte")
end
-- UNKNOWN_USE: above a quarter no; at it, a byte at 20 percent - 1 or over.
eq(heal(A.UNKNOWN_USE, 40), "nil", "UNKNOWN_USE above a quarter: no")
eq(heal(A.UNKNOWN_USE, 25, { 49 }), "nil", "UNKNOWN_USE at a quarter: byte 49 does not")
eq(heal(A.UNKNOWN_USE, 25, { 50 }), "item POTION 1", "...byte 50 uses")
-- Neither: a quarter or less yes; to half, a byte under 50 percent + 1.
eq(heal(0, 25), "item POTION 1", "no flags at a quarter: used")
eq(heal(0, 40, { 127 }), "item POTION 1", "no flags to half: byte 127 uses")
eq(heal(0, 40, { 128 }), "nil", "...byte 128 does not")
eq(heal(0, 51), "nil", "no flags above half: no")
for _, id in ipairs({ "MAX_POTION", "HYPER_POTION", "SUPER_POTION" }) do
  eq(item({ id = id, mon = { hp = 25 } }), "item " .. id .. " 1", id .. " reads `.HealItem` too")
end

-- `.FullRestore`: the heal reading, else (CONTEXT_USE) the status one.
eq(item({ id = "FULL_RESTORE", mon = { hp = 25 } }), "item FULL_RESTORE 1", "FULL RESTORE at a quarter")
eq(item({ id = "FULL_RESTORE", mon = { status = "sleep" } }), "nil",
   "FULL RESTORE at full HP without CONTEXT_USE: the status is never asked")
eq(item({ id = "FULL_RESTORE", flags = A.CONTEXT_USE, mon = { status = "sleep", statusTurns = 2 } }),
   "item FULL_RESTORE 1", "...with it, sleep is reason enough")
eq(item({ id = "FULL_RESTORE", flags = A.CONTEXT_USE, mon = { status = "poison" } }), "nil",
   "...a plain poison is not")

-- `.Status` (FULL HEAL).
do
  local d, n = item({ id = "FULL_HEAL", flags = A.ALWAYS_USE })
  eq(d, "nil", "FULL HEAL with no status: no")
  eq(n, 0, "...no byte")
end
eq(item({ id = "FULL_HEAL", flags = A.ALWAYS_USE, mon = { status = "poison" } }), "item FULL_HEAL 1",
   "ALWAYS_USE: any status")
eq(item({ id = "FULL_HEAL", mon = { status = "burn" }, bytes = { 49 } }), "item FULL_HEAL 1",
   "no flags: byte 49 uses")
eq(item({ id = "FULL_HEAL", mon = { status = "burn" }, bytes = { 50 } }), "nil", "...byte 50 does not")
eq(item({ id = "FULL_HEAL", flags = A.CONTEXT_USE, mon = { status = "freeze" } }), "item FULL_HEAL 1",
   "CONTEXT_USE: freeze")
do
  -- The referee counts the toxic multiplier from 1: wEnemyToxicCount is one less.
  local d, n = item({ id = "FULL_HEAL", flags = A.CONTEXT_USE, mon = { status = "toxic", toxicCounter = 4 } })
  eq(d, "nil", "CONTEXT_USE, toxic count 3: no byte, and a poison is not sleep or freeze")
  eq(n, 0, "...no byte")
  d, n = item({ id = "FULL_HEAL", flags = A.CONTEXT_USE, mon = { status = "toxic", toxicCounter = 5 },
                bytes = { 127 } })
  eq(d, "item FULL_HEAL 1", "toxic count 4: byte 127 uses")
  d, n = item({ id = "FULL_HEAL", flags = A.CONTEXT_USE, mon = { status = "toxic", toxicCounter = 5 },
                bytes = { 128 } })
  eq(d, "nil", "...byte 128 falls to `.FailToxicCheck`")
  eq(n, 1, "...one byte")
  d = item({ id = "FULL_HEAL", flags = A.CONTEXT_USE,
             mon = { status = "burn", toxicLatent = true, toxicCounter = 9 }, bytes = { 0 } })
  eq(d, "item FULL_HEAL 1", "SUBSTATUS_TOXIC under a burn counts too")
end

-- `.XItem` (X ACCURACY .. X SPECIAL, GUARD SPEC., DIRE HIT).
for _, id in ipairs({ "X_ACCURACY", "GUARD_SPEC", "DIRE_HIT", "X_ATTACK", "X_DEFEND", "X_SPEED", "X_SPECIAL" }) do
  local d, n = item({ id = id, flags = A.ALWAYS_USE })
  eq(d, "item " .. id .. " 1", id .. ": first turn out, ALWAYS_USE")
  eq(n, 0, "...no byte")
end
do
  local d, n = item({ id = "X_ATTACK", flags = A.CONTEXT_USE, bytes = { 127 } })
  eq(d, "nil", "first turn, CONTEXT_USE: byte 127 refuses")
  d, n = item({ id = "X_ATTACK", flags = A.CONTEXT_USE, bytes = { 128 } })
  eq(d, "item X_ATTACK 1", "...byte 128 uses")
  eq(n, 1, "...one byte")
  d, n = item({ id = "X_ATTACK", bytes = { 128, 127 } })
  eq(d, "nil", "first turn, no flags: a second byte, 127 refuses")
  eq(n, 2, "...two bytes")
  d = item({ id = "X_ATTACK", bytes = { 128, 128 } })
  eq(d, "item X_ATTACK 1", "...128 uses")
  d, n = item({ id = "X_ATTACK", mon = { turnsTaken = 1 } })
  eq(d, "nil", "later turns without ALWAYS_USE: no")
  eq(n, 0, "...no byte")
  d = item({ id = "X_ATTACK", flags = A.ALWAYS_USE, mon = { turnsTaken = 3 }, bytes = { 49 } })
  eq(d, "item X_ATTACK 1", "later turns, ALWAYS_USE: byte 49 uses")
  d = item({ id = "X_ATTACK", flags = A.ALWAYS_USE, mon = { turnsTaken = 3 }, bytes = { 50 } })
  eq(d, "nil", "...byte 50 does not")
end

-- AI_Items' order, not the trainer's: POTION's row comes before X ATTACK's.
eq(item({ fields = { trainerItems = { "X_ATTACK", "POTION" } }, flags = A.ALWAYS_USE, mon = LOW }),
   "item POTION 2", "the table's order decides")

-- "AI might use its base reward value as an item".
do
  local d, _, f, decision = item({ fields = { trainerItems = { "NO_ITEM", "POTION" }, baseReward = 0x26 },
                                   flags = A.ALWAYS_USE, mon = { status = "poison" } })
  eq(d, "item FULL_HEAL 3", "a POTION it will not use leaves `de` on item 2: the base reward 0x26 is FULL HEAL")
  A.useItem(f.battle, f.npc, decision)
  eq(f.npc.baseReward, 0, "...and the base reward byte is what it clears")
  eq(f.npc.trainerItems[2], "POTION", "...the POTION stays")
  eq(f.mon.status, nil, "...and the FULL HEAL works")
end
eq(item({ fields = { trainerItems = { "FULL_HEAL", "POTION" } }, flags = A.ALWAYS_USE,
          mon = { status = "poison" } }), "nil",
   "...item 1 is never looked at again once `de` moved: its FULL HEAL goes unused")
eq(item({ fields = { trainerItems = { "POTION", "FULL_HEAL" } }, flags = A.ALWAYS_USE,
          mon = { status = "poison" } }), "item FULL_HEAL 2",
   "...the other way round `de` never moved")
eq(item({ fields = { trainerItems = { "NO_ITEM", "MAX_POTION" }, baseReward = 0x12 },
          flags = A.CONTEXT_USE, mon = { hp = 40 }, bytes = { 50, 49 } }), "item POTION 3",
   "a refused MAX POTION, then the base reward 0x12 read as POTION, with its own byte")
eq(item({ fields = { trainerItems = { 0x12 } }, mon = LOW }), "item POTION 1", "an item stated by its number")
eq(A.itemByte("RARE_CANDY") ~= 0, true, "an item AI_Items does not list is still not NO_ITEM")
eq(item({ fields = { trainerItems = { "RARE_CANDY" }, baseReward = 0x12 }, mon = LOW }), "nil",
   "...and matches no row (the bug needs item 2 to have matched)")

-- ------------------------------------------------------------------
-- 7. the effect: each EnemyUsed* routine and AI_TryItem's tail
-- ------------------------------------------------------------------

local function use(o)
  local _, _, f, d = item(o)
  f.battle:drainEvents()
  local applied = A.useItem(f.battle, f.npc, d)
  return f, f.battle:drainEvents(), applied
end

local function kinds(events)
  local out = {}
  for _, e in ipairs(events) do out[#out + 1] = e.t end
  return table.concat(out, ",")
end

do
  local f, events, applied = use({ npc = { mn({ species = "Ace", hp = 10 }) } })
  eq(applied, true, "useItem applies")
  eq(kinds(events), "msg,item,drain", "POTION: the line, the sound (item), the HP bar")
  eq(events[1].text, "LASS AMY\nused POTION\non Ace!", "_EnemyUsedOnText, `line` and `cont` as K18 breaks")
  eq(events[3].amount, 20, "...20 HP")
  eq(f.mon.hp, 30, "...on the monster")
  eq(f.npc.trainerItems[1], "NO_ITEM", "...and the slot is cleared")
end
do
  local f, events = use({ id = "HYPER_POTION", mon = { hp = 25 } })
  eq(f.mon.hp, 100, "HYPER POTION: +200 held at the max")
  eq(events[3].amount, 75, "...the bar moves by what it healed")
  f = use({ id = "SUPER_POTION", mon = { hp = 10 } })
  eq(f.mon.hp, 60, "SUPER POTION: +50")
  f, events = use({ id = "MAX_POTION", mon = { hp = 1 } })
  eq(f.mon.hp, 100, "MAX POTION: to the max")
  eq(kinds(events), "msg,item,drain", "...the same three")
end
do
  local f = fight({ npc = { mn({ species = "Ace", hp = 25, status = "BRN", confusion = 3 }) },
                    fields = { trainerItems = { "FULL_RESTORE" } } })
  f.mon.nightmare = true
  local burnt = Effects.currentStats(f.mon, nil).atk
  local d = decide(f)
  f.battle:drainEvents()
  A.useItem(f.battle, f.npc, d)
  local events = f.battle:drainEvents()
  eq(kinds(events), "msg,item,drain,status,status",
     "FULL RESTORE: the line, the sound, the bar, the HUD's status and confusion")
  eq(events[5].confused, 0, "...the confusion it clears")
  eq(f.mon.hp, 100, "...the HP to max")
  eq(f.mon.status, nil, "...the burn gone")
  eq(f.mon.confusion, 0, "...and the confusion (EnemyUsedFullRestore's own `res`)")
  eq(Effects.currentStats(f.mon, nil).atk, burnt, "...but the burn's Attack cut stays (no CalcEnemyStats)")
  eq(f.mon.nightmare, true, "...and the nightmare stays (AI_HealStatus never clears it)")
end
do
  local f = fight({ npc = { mn({ species = "Ace", status = "PAR", confusion = 2, spe = 80 }) },
                    fields = { trainerItems = { "FULL_HEAL" }, itemSwitch = A.ALWAYS_USE } })
  f.mon.toxicLatent = true
  local slow = Effects.currentStats(f.mon, nil).spe
  local d = decide(f)
  f.battle:drainEvents()
  A.useItem(f.battle, f.npc, d)
  local events = f.battle:drainEvents()
  eq(kinds(events), "item,msg,status", "FULL HEAL: the sound, the line, the HUD")
  eq(events[2].text, "LASS AMY\nused FULL HEAL\non Ace!", "...its line")
  eq(f.mon.status, nil, "...the paralysis gone")
  eq(f.mon.toxicLatent, nil, "...SUBSTATUS_TOXIC off")
  eq(f.mon.confusion, 2, "...the confusion left (the AI's FULL HEAL never clears it)")
  eq(Effects.currentStats(f.mon, nil).spe, slow, "...and the paralysis' Speed cut stays")
end
for _, row in ipairs({ { "X_ACCURACY", "xAccuracy", "X ACCURACY" }, { "GUARD_SPEC", "mist", "GUARD SPEC." },
                       { "DIRE_HIT", "focusEnergy", "DIRE HIT" } }) do
  local f, events = use({ id = row[1], flags = A.ALWAYS_USE, npc = { mn({ species = "Ace" }) } })
  eq(kinds(events), "item,msg", row[1] .. ": the sound, then the line")
  eq(events[2].text, "LASS AMY\nused " .. row[3] .. "\non Ace!", "...named " .. row[3])
  eq(f.mon[row[2]], true, "...its SubStatus4 bit")
end
do
  local f, events = use({ id = "X_SPECIAL", flags = A.ALWAYS_USE })
  eq(kinds(events), "msg,item,stat", "X SPECIAL: the line, no sound on the cart, the stage")
  eq(f.mon.stages.spa, 1, "...SP_ATTACK up one")
  eq(events[3].stage, 1, "...the stat event's stage")
  f, events = use({ id = "X_SPEED", flags = A.ALWAYS_USE, mon = {} })
  eq(f.mon.stages.spe, 1, "X SPEED: SPEED")
  f = use({ id = "X_DEFEND", flags = A.ALWAYS_USE })
  eq(f.mon.stages.def, 1, "X DEFEND: DEFENSE")
end
do
  local _, _, f, d = item({ id = "X_ATTACK", flags = A.ALWAYS_USE })
  f.mon.stages.atk = 6
  f.battle:drainEvents()
  A.useItem(f.battle, f.npc, d)
  local events = f.battle:drainEvents()
  eq(kinds(events), "msg,item", "X ATTACK at +6: `.cant_raise_stat`, nothing more said")
  eq(f.mon.stages.atk, 6, "...the stage stays")
  eq(f.battle.lastAttackMissed, true, "...and RaiseStat leaves wAttackMissed set")
end
for _, flag in ipairs({ "lastAttackMissed", "lastEffectFailed" }) do
  local f, events = use({ id = "X_ATTACK", flags = A.ALWAYS_USE, battle = { [flag] = true } })
  eq(f.mon.stages.atk, 0, "a " .. flag .. " the last move left: RaiseStat's `.stat_raise_failed`")
  eq(kinds(events), "msg,item", "...and nothing more")
end
for _, family in ipairs({ "gs", "crystal" }) do
  local f = use({ family = family, mon = { hp = 10, furyCutter = 3, protectCount = 2, rageCounter = 2,
                                         raging = true, lastCounterMove = mv({ id = "last" }) } })
  eq(f.mon.furyCutter, 0, family .. ": the Fury Cutter count")
  eq(f.mon.protectCount, 0, family .. ": the Protect count")
  eq(f.mon.rageCounter, 0, family .. ": the Rage count")
  eq(f.mon.raging, false, family .. ": SUBSTATUS_RAGE")
  if family == "crystal" then
    eq(f.mon.lastCounterMove, nil, "crystal: wLastEnemyCounterMove cleared")
  else
    ok(f.mon.lastCounterMove ~= nil, "gs: wLastEnemyCounterMove kept (pokegold has no clear)")
  end
end
do
  local f = fight({})
  eq(A.useItem(f.battle, f.npc, { action = "item", item = "RARE_CANDY" }), false, "an id AI_Items lacks: nothing")
  eq(A.useItem(f.battle, f.npc, nil), false, "no decision: nothing")
  eq(A.withdrewLine(f.npc, f.mon), "LASS AMY\nwithdrew\nMon!", "_EnemyWithdrewText for AI_Switch")
end

-- ------------------------------------------------------------------
-- 8. FindMonInOTPartyToSwitchIntoBattle
-- ------------------------------------------------------------------

local function successor(o)
  o.foeTypes = o.foeTypes or { BE }
  local f = fight(o)
  f.mon.hp = 0
  local r = A.replacement(f.battle, f.npc, f.foe)
  return r and r.slot or nil, f.taken.n, r
end

do
  local slot, n, r = successor({ npc = { mn(), mn({ types = { AL } }), mn({ types = { GA }, moves = { mv({ type = GA }) } }) } })
  eq(slot, 3, "an enemy move super effective on the player wins (slot 3's GAMMA)")
  eq(n, 0, "...no byte")
  eq(r.action, "switch", "...as a switch choice")
  eq(r.playerMoveType, BE, "...wPlayerMoveStruct's type left as the player's last type tried")
end
eq(successor({ npc = { mn(), mn({ types = { AL }, moves = { mv({ type = AL }) } }),
                       mn({ types = { GA }, moves = { mv({ type = GA }) } }) } }), 3,
   "a super-effective move the player's type cancels (`.reset`) loses to one it does not")
eq(successor({ npc = { mn(), mn({ types = { AL }, moves = { mv({ type = AL }) } }), mn() } }), 2,
   "...and the cancelled slot reads neutral -- the first not discouraged")
eq(successor({ npc = { mn(), mn({ types = { AL } }), mn({ types = { N } }) } }), 3,
   "no enemy edge: the first slot the player's types do not beat")
eq(successor({ npc = { mn(), mn(), mn({ moves = { mv({ type = GA, power = 0 }) } }) } }), 3,
   "a move with no power still counts (LookUpTheEffectivenessOfEveryMove reads no power)")
do
  local party = { mn(), mn({ types = { AL } }), mn({ types = { AL } }) }
  for _, family in ipairs({ "crystal", "gs" }) do
    local slot, n = successor({ family = family, npc = party, bytes = { 11, 8, 10 } })
    eq(slot, 3, family .. ": every slot discouraged -- BattleRandom & 7 until a living one")
    eq(n, 3, family .. ": ...3 out of range, 0 the fainted one, 2 -- three bytes (Gold's bound draws the same)")
  end
end
do
  local f = fight({ npc = { mn(), mn({ types = { BE } }) }, foe = { mn({ types = { AL, GA } }) } })
  f.mon.hp = 0
  local r = A.replacement(f.battle, f.npc, f.foe)
  eq(r.playerMoveType, AL, "a type 1 super effective stops there: wPlayerMoveStruct keeps it")
end
eq(successor({ npc = { mn(), mn({ hp = 0 }) } }), nil, "no living bench: nil")

-- ------------------------------------------------------------------
-- 9. UpdateUsedMoves
-- ------------------------------------------------------------------

do
  local mon = {}
  for _, id in ipairs({ "a", "b", "a", "c", "d" }) do A.recordUsedMove(mon, mv({ id = id })) end
  local ids = {}
  for i, row in ipairs(mon.usedMoves) do ids[i] = row.id end
  eq(table.concat(ids, ","), "a,b,c,d", "appended once each")
  A.recordUsedMove(mon, mv({ id = "e" }))
  ids = {}
  for i, row in ipairs(mon.usedMoves) do ids[i] = row.id end
  eq(table.concat(ids, ","), "b,c,d,e", "a fifth shifts the oldest out")
  A.recordUsedMove(mon, mv({ id = "c" }))
  eq(#mon.usedMoves, 4, "one already there changes nothing")
end

-- ------------------------------------------------------------------

io.write(string.format("battle_sim2_ai_switch: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
