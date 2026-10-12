-- src/SoloBrain.lua, Gen 3: one brain per trainer, on either side of the
-- field (contract C4 of docs/plans/gen3-solo-remaining-fights.md).
--
-- tests/gen3_solo.lua holds the Gen 3 brain's scripts, a lone trainer's
-- single and its lone double; this suite holds what the fights still left
-- to the cart add to it, each over a real BattleSim3 referee:
--
--   0. the positions: the referee's field slots against pret's battler ids
--      (M.battlerId3 and friends), the AI flags composed (a pair's A | B, a
--      facility's three scripts in either cart's layout), the move mask.
--   1. the constructor: flags from a list, a brain with no trainer row, the
--      item sources (own, a shared pool, none), the owner a brain answers
--      for, and an in-game partner's sheets (no disobedience).
--   2. the view any seat is asked with (built here as SoloBattle:_npcView3
--      builds it) -- a single, a lone double (the shared team's claims), a
--      spotted pair (the other trainer is the partner; its claims are never
--      this party's), Steven's (side a).
--   3. Emerald's spotted pair: two brains, each answering its own seat and
--      declining the other's, aiming at the other trainer as its ally, both
--      spending A's one item pool with the pool's live counts, the
--      rationing count and EXPLOSION's reserves read side-wide.
--   4. Emerald's Steven on side a: the opponents' flags, the foes on side b
--      aimed at in pret battler order, the player as his ally, a Ghost
--      CURSE opposite him, no items, switching allowed, and the send-out
--      typing quirk that reads the player's side (his own).
--   5. the Battle Palace seam: a move mask (BattleAI_SetupAIData's
--      defaultScoreMoves) and the move-only pick.
--
-- Legal: every species, move, trainer and item row below is invented here
-- with synthetic numbers; the only real values are pret enum numbers the
-- battle code branches on (TYPE_*, EFFECT_*, ABILITY_*, ITEM_* ids), the
-- policy docs/plans/gen3-battle-sheet.md states for the sim itself.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_solo_brain.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"
if not io.open(MOD_PATH .. "/src/SoloBrain.lua", "rb") then
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("(.+)[/\\]")
    if dir then MOD_PATH = dir:gsub("[/\\]tests$", "") end
  end
end

local warns = {}
local stubMod = {
  id = "rby_mmo",
  path = MOD_PATH,
  generation = 3,
  log = {
    info = function() end,
    warn = function(_, fmt, ...)
      local ok, line = pcall(string.format, fmt, ...)
      warns[#warns + 1] = ok and line or tostring(fmt)
    end,
    error = function(_, fmt, ...)
      local ok, line = pcall(string.format, fmt, ...)
      warns[#warns + 1] = "ERROR " .. (ok and line or tostring(fmt))
    end,
  },
  options = { get = function() return nil end },
  save = { get = function() return nil end },
  exports = {},
}

local loadstr = loadstring or load
local cache = {}
local function need(n)
  if cache[n] ~= nil then return cache[n] end
  local h = assert(io.open(MOD_PATH .. "/src/" .. n .. ".lua", "rb"))
  local body = h:read("*a")
  h:close()
  local chunk = assert(loadstr(body, "@" .. n .. ".lua"))
  local value = chunk(need, stubMod)
  cache[n] = value == nil and true or value
  return cache[n]
end

local function contains(list, needle)
  for _, line in ipairs(list) do
    if type(line) == "string" and line:find(needle, 1, true) then return true end
  end
  return false
end

local Brain = need("SoloBrain")
local Sim = need("BattleSim3/init")
local E = Sim.Effects.E

-- ===================================================================
-- the fixture
-- ===================================================================

-- A crafted ordered chart (synthetic rows in pret's triple format), the one
-- tests/gen3_solo.lua leans on.
local CHART = {
  4, 2, 0,      -- GROUND -> FLYING: immune
  13, 4, 0,     -- ELECTRIC -> GROUND: immune
  10, 12, 20,   -- FIRE -> GRASS
  10, 6, 20,    -- FIRE -> BUG
  11, 10, 20,   -- WATER -> FIRE
  10, 11, 5,    -- FIRE -> WATER
  12, 11, 20,   -- GRASS -> WATER
  13, 11, 20,   -- ELECTRIC -> WATER
  -1, -1, 0,    -- the Foresight sentinel
  0, 7, 0,      -- NORMAL -> GHOST: immune
}

local function mv(num, fields)
  local row = { id = "FIX_" .. num, num = num, pp = 10, maxPp = 10, power = 0, type = 0,
                accuracy = 100, effect = 0, chance = 0, target = 0, priority = 0, flags = 0 }
  for k, v in pairs(fields or {}) do row[k] = v end
  return row
end

local function sheet(fields)
  local s = {
    generation = 3, species = "FOO", speciesId = "1", speciesNum = 1, slot = 0,
    level = 50, hp = 100, maxHp = 100,
    stats = { atk = 80, def = 80, spe = 80, spa = 80, spd = 80 },
    types = { 0 }, ability = 0, heldItem = 0, holdEffect = 0, holdEffectParam = 0,
    gender = "M", friendship = 70, weight = 100, nature = 0,
    hiddenPower = { type = 1, power = 70 }, beatUp = { atk = 50, def = 50 },
    moves = { mv(1, { power = 40 }) },
  }
  for k, v in pairs(fields or {}) do s[k] = v end
  return s
end

local function tackle() return mv(33, { power = 40, type = 0 }) end

local FR = Brain.AI_BITS_FRLG
-- Emerald's AI_SCRIPT_* numbering (pokeemerald include/constants/battle_ai.h).
local EM = { CHECK_BAD_MOVE = 0, TRY_TO_FAINT = 1, CHECK_VIABILITY = 2, SETUP_FIRST_TURN = 3,
             RISKY = 4, PREFER_POWER_EXTREMES = 5, PREFER_BATON_PASS = 6, DOUBLE_BATTLE = 7,
             HP_AWARE = 8, TRY_SUNNY_DAY_START = 9 }

-- rng answering the bottom / the top of every range.
local function lowRng(lo, hi) if hi == nil then return 1 end return lo end
local function highRng(lo, hi) if hi == nil then return 1 end return hi end
-- answers the queued values first (clamped into the range asked), then the
-- bottom of every range
local function queued(values)
  local q = {}
  for i, v in ipairs(values) do q[i] = v end
  return function(lo, hi)
    if hi == nil then lo, hi = 1, lo end
    if #q > 0 then
      local v = table.remove(q, 1)
      if v < lo then v = lo end
      if v > hi then v = hi end
      return v
    end
    return lo
  end
end

local function brain3(flags, extra)
  extra = extra or {}
  local opts = { generation = 3, rng = extra.rng or lowRng, aiBits = extra.aiBits or EM }
  for k, v in pairs(extra) do
    if k ~= "rng" and k ~= "aiBits" then opts[k] = v end
  end
  if opts.trainer == nil and opts.aiFlags == nil then
    opts.trainer = { aiFlags = flags, items = extra.items or {} }
  end
  if opts.aiFlags == nil and opts.trainer then opts.trainer.aiFlags = opts.trainer.aiFlags or flags end
  return assert(Brain.new(opts))
end

-- The referee for each shape.  Every fight is coop_npc, the solo seating.
local function create(sides, extra)
  extra = extra or {}
  local battle = assert(Sim.Turn.create({
    id = "brain3", mode = "coop_npc", seed = extra.seed or 3, typeTable = CHART,
    weather = extra.weather, sides = sides,
  }))
  battle:drainEvents()
  return battle
end

-- A spotted pair: the player's shared team (two seats, slots 0 / 1) against
-- two trainers, one seat each -- A on slot 3, B on slot 4 -- each with its
-- own party (the halves) and A alone holding the items.
local function pairFight(player, aMons, bMons, extra)
  extra = extra or {}
  return create({
    a = { { playerId = "p", name = "P", seats = 2, mons = player } },
    b = { { playerId = "ta", name = "A", mons = aMons, bag = extra.bagA },
          { playerId = "tb", name = "B", mons = bMons, bag = extra.bagB } },
  }, extra)
end

-- Steven's multi battle: the player (slot 0) and Steven (slot 1) on side a,
-- two trainers on side b (slots 3, 4).
local function stevenFight(player, ally, aMons, bMons, extra)
  return create({
    a = { { playerId = "p", name = "P", mons = player },
          { playerId = "ally", name = "STEVEN", mons = ally } },
    b = { { playerId = "ta", name = "MAXIE", mons = aMons },
          { playerId = "tb", name = "TABITHA", mons = bMons } },
  }, extra)
end

-- The view SoloBattle's generic loop hands a brain for one computer seat
-- (SoloBattle:_npcView3, contract C4): a single's is the seat opposite, its
-- monster even when fainted; a double's adds the seat's side and slot, the
-- other battler standing on its side whoever commands it (`partner`,
-- `partnerSlot`), the other side's standing battlers by slot (`foes`), and
-- the switches a sibling seat of the SAME party has filed (`claimed`).
local function standing(fighter)
  local mon = fighter and fighter.mons and fighter.mons[fighter.active]
  if mon and ((tonumber(mon.hp) or 0) > 0 or mon.standing == true) then return mon end
  return nil
end

local function view3(sim, seat)
  if type(sim) ~= "table" or type(seat) ~= "table" then return nil end
  local side = seat.side == "a" and "a" or "b"
  local other = side == "a" and "b" or "a"
  local view = {
    mon = seat.active and seat.mons[seat.active] or nil,
    party = seat.mons, active = seat.active, bag = seat.bag,
    mustReplace = seat.mustReplace and true or false,
    sim = sim, battler = seat.b, fighter = seat, side = side,
  }
  if view.mon == nil and seat.lastB then view.mon = seat.lastB.mon end
  if not sim.double then
    local opp = sim.bySide[other][1]
    view.foe = opp and opp.mons and opp.active and opp.mons[opp.active] or nil
    view.foeBattler = opp and opp.b or nil
    return view
  end
  local foes = {}
  for _, p in ipairs(sim.bySide[other]) do
    if p.b and standing(p) then foes[#foes + 1] = { slot = p.slot, battler = p.b } end
  end
  local partner, partnerSlot = nil, nil
  for _, s in ipairs(sim.bySide[side]) do
    if s ~= seat and s.b and standing(s) and not partner then partner, partnerSlot = s.b, s.slot end
  end
  local claimed = {}
  for _, s in ipairs(seat.seats or {}) do
    if s ~= seat and type(s.choice) == "table" and s.choice.action == "switch"
        and tonumber(s.choice.slot) then
      claimed[tonumber(s.choice.slot)] = true
    end
  end
  local lead = foes[1]
  view.foe = lead and lead.battler.mon or nil
  view.foeBattler = lead and lead.battler or nil
  view.double, view.seat, view.partner, view.partnerSlot = true, seat.slot, partner, partnerSlot
  view.foes, view.claimed = foes, claimed
  return view
end

-- ===================================================================
-- 0. the positions, the flags, the mask
-- ===================================================================

do
  local Events = Sim.Events
  eq(Brain.SIDE_SLOTS3, Events.SIDE_SLOTS, "positions: the mirrored side width is the referee's")
  local slots = { Events.fieldSlot("a", 1), Events.fieldSlot("b", 1),
                  Events.fieldSlot("a", 2), Events.fieldSlot("b", 2) }
  for id = 0, 3 do
    eq(Brain.battlerId3(slots[id + 1]), id, "positions: field slot " .. slots[id + 1]
       .. " is pret battler " .. id .. " (a1 b1 a2 b2)")
    eq(Brain.slotOfBattler3(id), slots[id + 1], "positions: ...and back, battler " .. id)
  end
  eq(Brain.battlerId3(2), 4, "positions: side a's third slot is battler 4")
  eq(Brain.battlerId3(5), 5, "positions: side b's third slot is battler 5")
  eq(Brain.battlerId3(nil), nil, "positions: no slot, no battler")
  eq(Brain.sideOfSlot3(1), "a", "positions: slot 1 is side a")
  eq(Brain.sideOfSlot3(3), "b", "positions: slot 3 is side b")
  eq(Brain.sideOfSlot3(nil), nil, "positions: no slot, no side")
  eq(Brain.partnerSlot3(3), 4, "positions: the partner of slot 3 is slot 4")
  eq(Brain.partnerSlot3(4), 3, "positions: ...and of slot 4, slot 3")
  eq(Brain.partnerSlot3(1), 0, "positions: Steven's partner (slot 1) is the player (slot 0)")
  eq(Brain.partnerSlot3(0), 1, "positions: ...and the player's, Steven")
  eq(Brain.partnerSlot3(nil, "b"), 4, "positions: an unknown side-b seat reads as the left one")
  eq(Brain.partnerSlot3(nil, "a"), 1, "positions: ...a side-a one too")

  -- the referee's own battler order agrees
  local battle = stevenFight({ sheet() }, { sheet() }, { sheet() }, { sheet() })
  for k, fighter in ipairs(battle.order) do
    eq(Brain.battlerId3(fighter.slot), k - 1, "positions: the referee's order[" .. k .. "] is battler " .. (k - 1))
  end
end

do
  eq(Brain.orFlags3(1, 2), 3, "flags: 1 | 2")
  eq(Brain.orFlags3({ 5, 3 }), 7, "flags: a list ORs (the pair's { A, B })")
  eq(Brain.orFlags3({ 1, 4 }, 2), 7, "flags: lists and numbers together")
  eq(Brain.orFlags3(7, 7), 7, "flags: a bit set twice is set once")
  eq(Brain.orFlags3(2 ^ 31, 1), 2 ^ 31 + 1, "flags: bit 31 (FIRST_BATTLE's) survives")
  eq(Brain.orFlags3(nil, "x", -4, 0), 0, "flags: junk and negatives are nothing")
  eq(Brain.facilityFlags3(FR), 7, "flags: a facility's three scripts on FireRed's layout")
  eq(Brain.facilityFlags3(EM), 7, "flags: ...and on Emerald's, numbered the other way round")
  eq(Brain.flagsOf3({ "DOUBLE_BATTLE" }, EM), 128, "flags: a named script in a layout")
  eq(Brain.flagsOf3({ "HP_AWARE", "HP_AWARE" }, FR), 256, "flags: ...each once")
end

do
  local m = Brain.maskOf3(5)
  check(m and m[1] and m[3] and not m[2] and not m[4], "mask: pret's u8, bit i = move slot i + 1")
  local t = Brain.maskOf3({ [2] = true, [4] = false })
  check(t and t[2] and not t[4], "mask: a set, false entries dropped")
  eq(Brain.maskOf3(nil), nil, "mask: none is every move")
end

-- ===================================================================
-- 1. the constructor
-- ===================================================================

do
  eq(Brain.new({ generation = 3 }), nil, "new3: no trainer and no flags -- a wild seat is the referee's")
  local flagsOnly = Brain.new({ generation = 3, aiFlags = { 1, 4 }, aiBits = EM })
  check(flagsOnly ~= nil, "new3: flags alone build a brain (a facility trainer, a partner)")
  eq(flagsOnly and flagsOnly.aiFlags, 5, "new3: ...the list ORed")
  eq(flagsOnly and #flagsOnly.items3, 0, "new3: ...and with no row, no items")
  local num = Brain.new({ generation = 3, trainer = { aiFlags = 9 }, aiFlags = 3, aiBits = EM })
  eq(num and num.aiFlags, 3, "new3: an explicit number overrides the row's")
  local row = Brain.new({ generation = 3, trainer = { aiFlags = 9, items = { 13, 0, 21, 0 } }, aiBits = EM })
  eq(row and row.aiFlags, 9, "new3: ...absent, the row's own")
  eq(row and #row.items3, 2, "new3: the row's item slots, empties dropped")
  eq(row and row.itemsNo3, 2, "new3: ...itemsNo at the start")
  local own = Brain.new({ generation = 3, trainer = { items = { 13 } }, items = { 21, 21, 0 }, aiBits = EM })
  eq(own and #own.items3, 2, "new3: `items` overrides the row's")
  local none = Brain.new({ generation = 3, trainer = { items = { 13 } }, noItems = true,
                           pool = Brain.itemPool3({ 21 }), aiBits = EM })
  eq(none and #none.items3, 0, "new3: noItems spends nothing, a pool or not")
  check(none and none.noItems, "new3: ...and says so")

  local pool = Brain.itemPool3({ items = { 21, 0, 13, 0 } }, "ta")
  eq(#pool.items, 2, "itemPool3: a trainer row's slots, empties dropped (HandleItemUseBeforeAISetup)")
  eq(pool.itemsNo, 2, "itemPool3: ...itemsNo")
  eq(pool.owner, "ta", "itemPool3: ...and whose bag they come out of")
  local a = Brain.new({ generation = 3, aiFlags = 1, pool = pool, aiBits = EM })
  local b = Brain.new({ generation = 3, aiFlags = 1, pool = pool, aiBits = EM })
  check(a.items3 == b.items3 and a.items3 == pool.items, "itemPool3: two brains hold the one pool table")

  local owned = Brain.new({ generation = 3, aiFlags = 1, owner = "tb", aiBits = EM })
  check(owned:answers({ playerId = "tb", owner = "tb" }), "owner: a brain answers its own entry's seat")
  check(owned:answers({ playerId = "tb#2", owner = "tb" }), "owner: ...and that entry's second seat")
  check(not owned:answers({ playerId = "ta", owner = "ta" }), "owner: ...never another entry's")
  local anyone = Brain.new({ generation = 3, aiFlags = 1, aiBits = EM })
  check(anyone:answers({ playerId = "ta", owner = "ta" }), "owner: an owner-less brain answers any seat")

  local steven = Brain.new({ generation = 3, aiFlags = { 1, 2 }, noItems = true, noDisobey = true,
                             owner = "ally", side = "a", aiBits = EM })
  local sheets = { { traded = true, unfateful = true }, { traded = true } }
  check(steven:sheets3(sheets) == sheets, "sheets3: the same list, in place")
  eq(sheets[1].traded, nil, "sheets3: an in-game partner's monster is never 'traded' (IsMonDisobedient)")
  eq(sheets[1].unfateful, true, "sheets3: ...the fateful-encounter rule is the cart's earlier arm, kept")
  eq(sheets[2].traded, nil, "sheets3: ...every sheet")
  local kept = { { traded = true } }
  owned:sheets3(kept)
  eq(kept[1].traded, true, "sheets3: a trainer without noDisobey leaves its sheets alone")
  eq(steven.side3, "a", "new3: the side it fights on")
end

-- ===================================================================
-- 2. the view, any seat
-- ===================================================================

do -- a single: the seat opposite, even fainted
  local battle = create({
    a = { { playerId = "p", name = "P", mons = { sheet() } } },
    b = { { playerId = "n", name = "N", mons = { sheet(), sheet({ slot = 1 }) }, bag = { [21] = 1 } } },
  })
  local v = view3(battle, battle.byId.n)
  eq(v.double, nil, "view3 single: not a double")
  check(v.foeBattler == battle.byId.p.b, "view3 single: the battler opposite")
  check(v.foe == battle.byId.p.b.mon, "view3 single: ...and its monster")
  check(v.party == battle.byId.n.mons and v.bag == battle.byId.n.bag, "view3 single: the seat's party and bag")
  eq(v.side, "b", "view3 single: the seat's side")
  battle.byId.p.mons[1].hp = 0
  local v2 = view3(battle, battle.byId.n)
  check(v2.foe == battle.byId.p.mons[1], "view3 single: a fainted foe still stands in for the typing test")
end

do -- a lone double: the shared team's sibling claims
  local battle = create({
    a = { { playerId = "p", name = "P", seats = 2, mons = { sheet(), sheet({ slot = 1 }) } } },
    b = { { playerId = "n", name = "N", seats = 2,
            mons = { sheet(), sheet({ slot = 1 }), sheet({ slot = 2 }), sheet({ slot = 3 }) } } },
  })
  battle.byId["n#2"].choice = { action = "switch", slot = 3 }
  local v = view3(battle, battle.byId.n)
  eq(v.double, true, "view3 lone double: a double")
  eq(v.seat, 3, "view3 lone double: the seat's slot")
  check(v.partner == battle.byId["n#2"].b, "view3 lone double: its second seat is the partner")
  eq(#v.foes, 2, "view3 lone double: both player battlers")
  eq(v.foes[1].slot, 0, "view3 lone double: ...left first")
  eq(v.claimed[3], true, "view3 lone double: the sibling seat's switch is claimed")
  check(Brain.new({ generation = 3, aiFlags = 1, owner = "n", aiBits = EM }):answers(battle.byId["n#2"]),
        "view3 lone double: one owned brain answers both seats of its shared team")
end

do -- the pair: the other trainer is the partner, and its claims are its own party's
  local battle = pairFight({ sheet(), sheet({ slot = 1 }) },
    { sheet(), sheet({ slot = 1 }), sheet({ slot = 2 }) },
    { sheet(), sheet({ slot = 1 }), sheet({ slot = 2 }) })
  local ta, tb = battle.byId.ta, battle.byId.tb
  eq(ta.slot, 3, "view3 pair: A on slot 3")
  eq(tb.slot, 4, "view3 pair: B on slot 4")
  tb.choice = { action = "switch", slot = 2 }
  local v = view3(battle, ta)
  check(v.partner == tb.b, "view3 pair: A's partner is B's battler (BATTLE_PARTNER is a position)")
  eq(v.claimed[2], nil, "view3 pair: B's switch is an index into B's party, never A's claim")
  check(v.party == ta.mons, "view3 pair: A's own half")
  local vb = view3(battle, tb)
  check(vb.partner == ta.b, "view3 pair: ...and B's partner is A's")
  eq(vb.seat, 4, "view3 pair: B's seat")
end

do -- Steven: side a, the foes on side b, the player beside him
  local battle = stevenFight({ sheet() }, { sheet() }, { sheet() }, { sheet() })
  local ally = battle.byId.ally
  eq(ally.slot, 1, "view3 Steven: on slot 1")
  local v = view3(battle, ally)
  eq(v.side, "a", "view3 Steven: side a")
  eq(v.seat, 1, "view3 Steven: his slot")
  check(v.partner == battle.byId.p.b, "view3 Steven: the player is his partner")
  eq(#v.foes, 2, "view3 Steven: both foe trainers")
  eq(v.foes[1].slot, 3, "view3 Steven: ...Maxie's slot first")
  eq(v.foes[2].slot, 4, "view3 Steven: ...then Tabitha's")
  local vf = view3(battle, battle.byId.tb)
  eq(vf.foes[2].slot, 1, "view3 Steven's fight: a foe trainer sees Steven among its foes")
  check(vf.partner == battle.byId.ta.b, "view3 Steven's fight: ...and the other trainer as its partner")
end

-- ===================================================================
-- 3. Emerald's spotted pair: two brains
-- ===================================================================

do -- each brain its own seat; the other trainer's is declined
  local battle = pairFight({ sheet(), sheet({ slot = 1 }) }, { sheet({ moves = { tackle() } }) },
                           { sheet({ moves = { tackle() } }) })
  local A = brain3(1, { owner = "ta" })
  local B = brain3(1, { owner = "tb" })
  local ca = A:choose(view3(battle, battle.byId.ta))
  eq(ca and ca.action, "fight", "pair: A answers its seat")
  check(battle:submitChoice("ta", ca), "pair: ...and the referee takes it")
  local before = #warns
  eq(A:choose(view3(battle, battle.byId.tb)), nil, "pair: A declines B's seat")
  check(#warns == before + 1 and contains(warns, "another trainer"),
        "pair: ...with a warning naming the mix-up")
  local cb = B:choose(view3(battle, battle.byId.tb))
  check(cb and battle:submitChoice("tb", cb), "pair: B answers its own, and the referee takes it")
  -- the warning stands for the session; the rest of this file must add none
  for i = #warns, 1, -1 do
    if warns[i]:find("another trainer", 1, true) then table.remove(warns, i) end
  end
end

do -- the other trainer is the ally pass: a Fire move into B's unlit FLASH FIRE
  local fire = mv(53, { power = 90, type = 10 })
  local battle = pairFight({ sheet(), sheet({ slot = 1 }) },
    { sheet({ moves = { tackle(), fire } }) }, { sheet({ ability = 18 }) })
  local A = brain3(1, { owner = "ta" })
  local c = A:choose(view3(battle, battle.byId.ta))
  eq(c and c.target, 4, "pair: A feeds the other trainer's FLASH FIRE battler (slot 4), as an ally")
  eq(c and c.move, 1, "pair: ...with the Fire move (AI_TryOnAlly)")
  eq(A.lastScores3 and A.lastScores3[1], 70, "pair: ...and Tackle into it is -30")
  battle.byId.tb.b.flashFire = true
  local lit = brain3(1, { owner = "ta" }):choose(view3(battle, battle.byId.ta))
  check(lit and lit.target ~= 4, "pair: once lit, B is not fed another")
end

do -- the earthquake beside the other trainer's Fire type
  local quake = mv(89, { power = 100, type = 4, target = 32 })
  local battle = pairFight({ sheet(), sheet({ slot = 1 }) },
    { sheet({ moves = { quake, tackle() } }) }, { sheet({ types = { 10 } }) })
  local A = brain3(1, { owner = "ta" })
  local c = A:choose(view3(battle, battle.byId.ta))
  eq(A.lastScores3 and A.lastScores3[1], 90, "pair: EARTHQUAKE beside the other trainer's Fire type is -10")
  eq(c and c.move, 1, "pair: ...so Tackle")
end

do -- A's four items, one pool, either foe spends it
  local function low() return sheet({ hp = 10, moves = { tackle() } }) end
  local pool = Brain.itemPool3({ items = { 21, 0, 0, 0 } }, "ta")
  local battle = pairFight({ sheet(), sheet({ slot = 1 }) }, { low() }, { low() },
    { bagA = { [21] = 1 } })
  local A = brain3(1, { owner = "ta", pool = pool })
  local B = brain3(1, { owner = "tb", pool = pool })
  local cb = B:choose(view3(battle, battle.byId.tb))
  eq(cb and cb.action, "item", "pool: B, under a quarter HP, drinks from A's pool")
  eq(cb and cb.item, 21, "pool: ...A's HYPER POTION")
  eq(pool.items[1], 0, "pool: ...and the slot is spent in the one pool")
  local ca = A:choose(view3(battle, battle.byId.ta))
  eq(ca and ca.action, "fight", "pool: A finds the pool spent -- no second potion")
end

do -- the pool's live counts are its owner's bag, not the seat's own
  local function low() return sheet({ hp = 10, moves = { tackle() } }) end
  local function ask(bagA, bagB)
    local battle = pairFight({ sheet(), sheet({ slot = 1 }) }, { low() }, { low() },
      { bagA = bagA, bagB = bagB })
    local B = brain3(1, { owner = "tb", pool = Brain.itemPool3({ 21 }, "ta") })
    return B:choose(view3(battle, battle.byId.tb))
  end
  local c1 = ask({ [21] = 1 }, nil)
  eq(c1 and c1.action, "item", "pool: B's seat carries no bag; A's still holds the potion -> used")
  local c2 = ask({ [13] = 1 }, { [21] = 1 })
  eq(c2 and c2.action, "fight", "pool: A's bag has none left -> not used, whatever B's seat holds")
end

do -- the rationing count is the whole side's (validMons over all of gEnemyParty)
  local function low(slot) return sheet({ slot = slot or 0, hp = 10, moves = { tackle() } }) end
  -- slot 0 an item with no battle use (999, synthetic), slot 1 the potion:
  -- the second slot is reached only while the side has at most 2 standing
  local function ask(aMons, bMons)
    local battle = pairFight({ sheet(), sheet({ slot = 1 }) }, aMons, bMons, { bagA = { [21] = 1 } })
    local A = brain3(1, { owner = "ta", pool = Brain.itemPool3({ 999, 21 }, "ta") })
    return A:choose(view3(battle, battle.byId.ta))
  end
  local alone = ask({ low() }, { low() })
  eq(alone and alone.action, "item", "pool: one monster each -- 2 standing, the second slot is reached")
  local more = ask({ low(), sheet({ slot = 1 }) }, { low(), sheet({ slot = 1 }) })
  eq(more and more.action, "fight", "pool: two each -- 4 standing on the side, rationed (not A's 2 alone)")
end

do -- EXPLOSION's "last one standing" counts the other trainer's bench as the side's
  local boom = mv(153, { power = 250, effect = 7, target = 32 })
  local player = { sheet(), sheet({ slot = 1 }), sheet({ slot = 2 }) }
  local battle = pairFight(player, { sheet({ moves = { boom, tackle() } }) },
    { sheet(), sheet({ slot = 1 }) })
  local A = brain3(1, { owner = "ta" })
  A:choose(view3(battle, battle.byId.ta))
  eq(A.lastScores3 and A.lastScores3[1], 100,
     "pair: A's last monster is not the side's last -- B's bench counts (count_alive_pokemon)")
  local alone = pairFight(player, { sheet({ moves = { boom, tackle() } }) }, { sheet() })
  local A2 = brain3(1, { owner = "ta" })
  A2:choose(view3(alone, alone.byId.ta))
  eq(A2.lastScores3 and A2.lastScores3[1], 90, "pair: ...with no bench on the whole side, -10")
end

do -- a send-out comes from the trainer's own half
  local battle = pairFight({ sheet(), sheet({ slot = 1 }) },
    { sheet(), sheet({ slot = 1 }), sheet({ slot = 2 }) },
    { sheet(), sheet({ slot = 1 }) })
  local tb = battle.byId.tb
  local v = view3(battle, tb)
  v.mon.hp = 0
  v.mustReplace = true
  local c = brain3(1, { owner = "tb" }):choose(v)
  eq(c and c.action, "switch", "pair: B's emptied seat asks for a send-out")
  eq(c and c.slot, 1, "pair: ...from B's own party (its slot 1), never A's")
end

-- ===================================================================
-- 4. Emerald's Steven, on side a
-- ===================================================================

local function stevenBrain(extra)
  extra = extra or {}
  local opts = { aiFlags = extra.aiFlags or { 1, 2 }, noItems = true, noDisobey = true,
                 owner = "ally", side = "a", rng = extra.rng, items = extra.items }
  return brain3(nil, opts)
end

do
  local S = stevenBrain()
  eq(S.aiFlags, 3, "Steven: the opponents' flags, A | B")
end

do -- aims at the foe it can knock out, either one
  local function run(lowSlot)
    local battle = stevenFight({ sheet() }, { sheet({ moves = { mv(33, { power = 80, type = 0 }) } }) },
      { sheet({ hp = lowSlot == 3 and 5 or 100 }) }, { sheet({ hp = lowSlot == 4 and 5 or 100 }) })
    local S = stevenBrain()
    local c = S:choose(view3(battle, battle.byId.ally))
    check(c and battle:submitChoice("ally", c), "Steven: the referee takes his choice (" .. lowSlot .. ")")
    return c, S
  end
  local c4, s4 = run(4)
  eq(c4 and c4.target, 4, "Steven: aims at Tabitha's battler when it is the one he can knock out")
  eq(s4.lastScores3 and s4.lastScores3[1], 104, "Steven: ...+4 (TRY_TO_FAINT, the opponents' flag)")
  eq((run(3)).target, 3, "Steven: ...at Maxie's when that one is low")
end

do -- equal foes: pret battler order, the player (ally) never the target of a hit
  local function pick(rng)
    local battle = stevenFight({ sheet() }, { sheet({ moves = { tackle() } }) }, { sheet() }, { sheet() })
    return stevenBrain({ rng = rng }):choose(view3(battle, battle.byId.ally))
  end
  eq(pick(lowRng).target, 3, "Steven: a tie between the foes, a low roll -> battler 1 (slot 3)")
  eq(pick(highRng).target, 4, "Steven: ...a high roll -> battler 3 (slot 4); never the player")
end

do -- the flank roll (BattleAI_SetupAIData's double target) lands on side b from side a
  -- FireRed's layout here only to reach the flank path; no FireRed fight has a partner
  local function roll(r)
    local battle = stevenFight({ sheet() }, { sheet({ moves = { tackle() } }) }, { sheet() }, { sheet() })
    return brain3(1, { aiBits = FR, side = "a", owner = "ally", rng = queued({ r }) })
      :choose(view3(battle, battle.byId.ally))
  end
  eq(roll(0).target, 3, "Steven: the flank roll's left is the opponents' left (slot 3)")
  eq(roll(1).target, 4, "Steven: ...its right, slot 4")
end

do -- the player beside him is his ally pass: a Fire move into the player's unlit FLASH FIRE
  local fire = mv(53, { power = 90, type = 10 })
  local battle = stevenFight({ sheet({ ability = 18 }) }, { sheet({ moves = { tackle(), fire } }) },
    { sheet() }, { sheet() })
  local S = stevenBrain({ aiFlags = { 1, 0 } })
  local c = S:choose(view3(battle, battle.byId.ally))
  eq(c and c.target, 0, "Steven: feeds the player's FLASH FIRE battler (slot 0), as the cart's partner AI would")
  eq(c and c.move, 1, "Steven: ...the Fire move")
end

do -- a Ghost's CURSE lands on the foe opposite him (slot 1 faces slot 4)
  local curse = mv(174, { power = 0, type = 7, effect = E.CURSE, target = 16 })
  local battle = stevenFight({ sheet() }, { sheet({ types = { 7 }, moves = { curse } }) },
    { sheet() }, { sheet() })
  local c = stevenBrain():choose(view3(battle, battle.byId.ally))
  eq(c and c.target, 4, "Steven: his Ghost CURSE names slot 4, the foe opposite (referee's oppositeFoe)")
  -- the same off bare sheets, with no referee in the view
  local bare = {
    mon = sheet({ types = { 7 }, moves = { curse } }), party = {}, side = "a",
    double = true, seat = 1, partner = sheet(),
    foes = { { slot = 3, battler = sheet() }, { slot = 4, battler = sheet() } },
  }
  bare.party = { bare.mon }
  bare.foe = bare.foes[1].battler
  local cb = stevenBrain():choose(bare)
  eq(cb and cb.target, 4, "Steven: ...and off bare sheets, the same position rule")
  bare.side = nil
  local cs = stevenBrain():choose(bare)
  eq(cs and cs.target, 4, "Steven: ...a bare view's side read off its seat (slot 1 is side a)")
end

do -- a bare view with no seat either: the brain's own side places the foes
  local function bareRoll(r)
    local v = {
      mon = sheet({ moves = { tackle() } }), double = true,
      foes = { { slot = 3, battler = sheet() }, { slot = 4, battler = sheet() } },
    }
    v.party, v.foe = { v.mon }, v.foes[1].battler
    return brain3(1, { aiBits = FR, side = "a", rng = queued({ r }) }):choose(v)
  end
  eq(bareRoll(1).target, 4, "Steven: no seat, no side in the view -- the brain's side aims the roll (slot 4)")

  -- a view carrying only its referee fighter (no battler, no side, no seat):
  -- the fighter's side is the seat's
  local battle = stevenFight({ sheet() }, { sheet({ moves = { tackle() } }) }, { sheet() }, { sheet() })
  local v = view3(battle, battle.byId.ally)
  v.battler, v.side, v.seat, v.partner, v.partnerSlot = nil, nil, nil, nil, nil
  local c = brain3(1, { aiBits = FR, owner = "ally", rng = queued({ 1 }) }):choose(v)
  eq(c and c.target, 4, "Steven: a view with only its fighter reads the side off it (the roll's right: slot 4)")

  -- a bare partner sheet (no slot of its own): the seat's other position
  local fire = mv(53, { power = 90, type = 10 })
  local bare = {
    mon = sheet({ moves = { tackle(), fire } }), double = true, seat = 1, side = "a",
    partner = sheet({ ability = 18 }),
    foes = { { slot = 3, battler = sheet() }, { slot = 4, battler = sheet() } },
  }
  bare.party, bare.foe = { bare.mon }, bare.foes[1].battler
  local fed = stevenBrain({ aiFlags = { 1, 0 } }):choose(bare)
  eq(fed and fed.target, 0, "Steven: a bare partner sheet stands on his other position, slot 0")
end

do -- a partner seat at the left position: the walk is still pret battler order
  -- (an arrangement no cart makes -- Steven is always battler 2 -- pinned for
  -- the position rule itself: foe battler 1, the ally 2, foe battler 3)
  local battle = create({
    a = { { playerId = "ally", name = "ALLY", mons = { sheet({ moves = { tackle() } }) } },
          { playerId = "p", name = "P", mons = { sheet() } } },
    b = { { playerId = "ta", name = "A", mons = { sheet() } },
          { playerId = "tb", name = "B", mons = { sheet() } } },
  })
  local function pick(rng)
    local b = brain3(1, { side = "a", owner = "ally", rng = rng })
    b._scoreMoves3 = function(_, _, legal)
      local scores = {}
      for _, i in ipairs(legal) do scores[i] = 100 end
      return scores
    end
    return b:choose(view3(battle, battle.byId.ally))
  end
  eq(pick(lowRng).target, 3, "order: an all-equal walk from slot 0 starts at foe battler 1 (slot 3), not the ally")
  eq(pick(highRng).target, 4, "order: ...and ends at foe battler 3 (slot 4)")
end

do -- never an item, however low
  local battle = stevenFight({ sheet() }, { sheet({ hp = 5, moves = { tackle() } }) }, { sheet() }, { sheet() })
  local c = stevenBrain({ items = { 21, 21 } }):choose(view3(battle, battle.byId.ally))
  eq(c and c.action, "fight", "Steven: never uses an item (ShouldUseItem's INGAME_PARTNER arm)")
end

do -- he may switch; the send-out typing reads the player's side -- his own
  local grassActive = sheet({ types = { 12 }, moves = { tackle() } })
  local monG = sheet({ slot = 1, types = { 12 }, moves = { mv(55, { power = 40, type = 11 }) } })
  local monW = sheet({ slot = 2, types = { 11 }, moves = { mv(52, { power = 40, type = 10 }) } })
  local function ask(roll)
    local battle = stevenFight({ sheet({ types = { 10 } }) }, { grassActive, monG, monW },
      { sheet() }, { sheet() })
    battle.byId.ally.b.perishTurns = 0
    return stevenBrain({ rng = queued({ roll }) }):choose(view3(battle, battle.byId.ally))
  end
  local c0 = ask(0)
  eq(c0 and c0.action, "switch", "Steven: a perish count at 0 switches him out (partner AI may switch)")
  eq(c0 and c0.slot, 1, "Steven: the roll lands on the player (Fire) -> the Grass monster with a Water move")
  eq(ask(1).slot, 2, "Steven: the roll lands on his own position (Grass) -> the Water monster with a "
     .. "Fire move: GetMostSuitableMonToSwitchInto's player-side quirk, kept")

  -- his forced send-out: his own position is empty, so the roll flips to the player
  local function forced(roll)
    local battle = stevenFight({ sheet({ types = { 10 } }) },
      { sheet({ types = { 12 }, moves = { tackle() } }), monG, monW }, { sheet() }, { sheet() })
    local v = view3(battle, battle.byId.ally)
    v.mon.hp = 0
    v.mustReplace = true
    return stevenBrain({ rng = queued({ roll }) }):choose(v)
  end
  eq(forced(1).slot, 1, "Steven: a send-out rolled onto his emptied position flips to the player's")
  eq(forced(0).slot, 1, "Steven: ...as the player's own roll does")
end

do -- the foes of his fight: Emerald targets across both of side a
  local battle = stevenFight({ sheet({ hp = 5 }) }, { sheet() },
    { sheet({ moves = { mv(33, { power = 80, type = 0 }) } }) }, { sheet() })
  local M_ = brain3(nil, { aiFlags = { 2, 0 }, noItems = true, owner = "ta" })
  local c = M_:choose(view3(battle, battle.byId.ta))
  eq(c and c.target, 0, "Steven's fight: a foe aims at the low player (slot 0)")
  local battle2 = stevenFight({ sheet() }, { sheet({ hp = 5 }) },
    { sheet({ moves = { mv(33, { power = 80, type = 0 }) } }) }, { sheet() })
  local c2 = brain3(nil, { aiFlags = { 2, 0 }, noItems = true, owner = "ta" })
    :choose(view3(battle2, battle2.byId.ta))
  eq(c2 and c2.target, 1, "Steven's fight: ...or at Steven (slot 1) when he is the low one")
end

-- ===================================================================
-- 5. the Battle Palace seam: a move mask, the move alone
-- ===================================================================

do
  local function single(npcMons)
    local battle = create({
      a = { { playerId = "p", name = "P", mons = { sheet() } } },
      b = { { playerId = "n", name = "N", mons = npcMons } },
    })
    return battle, view3(battle, battle.byId.n)
  end
  local moves = { tackle(), mv(52, { power = 40, type = 10 }) }
  local _, v = single({ sheet({ moves = moves }), sheet({ slot = 1 }) })
  eq(brain3(1, { aiBits = FR }):choose(v).move, 0, "mask: none -- a tie goes to the first move")
  v.moveMask = 2
  local b = brain3(1, { aiBits = FR })
  eq(b:choose(v).move, 1, "mask: pret's u8 0b10 -- the second move alone starts at 100")
  eq(b.lastScores3 and b.lastScores3[1], 0, "mask: ...the masked-out move starts at 0, still scored")
  v.moveMask = { [1] = true }
  eq(brain3(1, { aiBits = FR }):choose(v).move, 0, "mask: a set -- the first")
  v.moveMask = { [2] = true }
  eq(brain3(0, { aiBits = FR }):choose(v).move, 1, "mask: no flags -- the random pick stays inside the mask")
  v.moveMask = 0
  eq(brain3(0, { aiBits = FR }):choose(v).move, 0, "mask: ...an empty mask ties every move at 0")

  local battle2, v2 = single({ sheet({ moves = moves }), sheet({ slot = 1 }) })
  battle2.byId.n.b.perishTurns = 0
  eq(brain3(1, { aiBits = FR }):choose(v2).action, "switch", "moveOnly: absent, the perish count switches")
  v2.moveOnly = true
  eq(brain3(1, { aiBits = FR }):choose(v2).action, "fight", "moveOnly: the move alone, no switch, no item")
end

-- ===================================================================
-- 6. the Battle Palace's pick (pokeemerald battle_gfx_sfx_util.c:109
--    ChooseMoveAndTargetInBattlePalace) and the Battle Arena's two rules
-- ===================================================================

-- The cart's Palace tables, invented: every nature's ATTACK / DEFENSE
-- thresholds 60 / 80 above half HP, 20 / 40 at or under; natures 0 / 1 / 2
-- prefer the STRONGER / WEAKER / a RANDOM target.
local PALACE = { likelihood = {}, moveTarget = {} }
for n = 1, 25 do
  PALACE.likelihood[n] = { 60, 80, 20, 40 }
  PALACE.moveTarget[n] = (n - 1) % 3
end
local FLAVOR = {}
for n = 1, 25 do FLAVOR[n] = 0 end

local function palaceFight(sides, extra)
  extra = extra or {}
  local battle = assert(Sim.Turn.create({
    id = "palace3", mode = "coop_npc", seed = 3, typeTable = CHART, sides = sides,
    rules = extra.rules or { palace = { flavor = FLAVOR } },
  }))
  battle:drainEvents()
  return battle
end

-- Three groups: SCRATCH-like (ATTACK), a status move at BOTH (SUPPORT), a
-- move at the user (DEFENSE).
local function attack(num) return mv(num or 10, { power = 40, type = 0, target = 0 }) end
local function support(num) return mv(num or 45, { power = 0, type = 0, target = 8, effect = 18 }) end
local function defense(num) return mv(num or 104, { power = 0, type = 0, target = 16, effect = 16 }) end

do
  local G = Brain.PALACE_GROUP
  local function group(fields) return Brain.palaceGroup3(mv(1, fields)) end
  eq(group({ power = 40, target = 0 }), G.ATTACK, "palace group: a damaging SELECTED move is ATTACK")
  eq(group({ power = 0, target = 0 }), G.SUPPORT, "palace group: a status SELECTED move is SUPPORT")
  eq(group({ power = 40, target = 8 }), G.ATTACK, "palace group: a damaging BOTH move is ATTACK")
  eq(group({ power = 0, target = 8 }), G.SUPPORT, "palace group: a status BOTH move is SUPPORT")
  eq(group({ power = 20, target = 4 }), G.ATTACK, "palace group: RANDOM, damaging: ATTACK")
  eq(group({ power = 0, target = 32 }), G.SUPPORT, "palace group: FOES_AND_ALLY, status: SUPPORT")
  eq(group({ power = 1, target = 1 }), G.SUPPORT, "palace group: DEPENDS is SUPPORT whatever its power")
  eq(group({ power = 0, target = 64 }), G.SUPPORT, "palace group: the foes' field is SUPPORT")
  eq(group({ power = 0, target = 16 }), G.DEFENSE, "palace group: a move at the user is DEFENSE")
  eq(group({ power = 90, target = 128 }), G.ATTACK, "palace group: any other target is ATTACK")

  eq(Brain.palaceTables3({ likelihood = {}, moveTarget = {} }), nil, "palace tables: short of 25 natures")
  local bad = { likelihood = PALACE.likelihood, moveTarget = {} }
  for n = 1, 25 do bad.moveTarget[n] = 3 end
  eq(Brain.palaceTables3(bad), nil, "palace tables: a target preference out of 0..2")
  check(Brain.palaceTables3(PALACE) ~= nil, "palace tables: the cart's shape")
  eq(Brain.new({ generation = 3, aiFlags = 7, aiBits = EM }).palace3, nil, "palace: none unless asked")
end

do -- the nature's group, the AI inside it, the low-HP half
  local function single(npcMoves, extraMons)
    local mons = { sheet({ moves = npcMoves }) }
    for _, m in ipairs(extraMons or {}) do mons[#mons + 1] = m end
    local battle = palaceFight({
      a = { { playerId = "p", name = "P", mons = { sheet() } } },
      b = { { playerId = "n", name = "N", mons = mons } },
    })
    return battle, view3(battle, battle.byId.n)
  end
  local function palaceBrain(values, extra)
    local opts = { aiBits = EM, palace = PALACE, rng = queued(values) }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return brain3(7, opts)
  end
  local moves = { attack(), support(), defense() }
  local _, v = single(moves)
  local b = palaceBrain({ 10 })
  eq(b:choose(v).move, 0, "palace: under 60 -- the ATTACK group, its one move")
  eq(b.lastPalace3.group, Brain.PALACE_GROUP.ATTACK, "palace: ...the group drawn")
  check(b.lastPalace3.mask[1] and not b.lastPalace3.mask[2], "palace: ...the AI's mask is the group")
  eq(b.lastScores3 and b.lastScores3[2], 0, "palace: ...the rest scored up from 0")
  eq(palaceBrain({ 70 }):choose(v).move, 2, "palace: 60..79 -- DEFENSE")
  eq(palaceBrain({ 90 }):choose(v).move, 1, "palace: 80 and over -- SUPPORT")

  local battle, lv = single(moves)
  battle.byId.n.b.palaceLow = true
  local lb = palaceBrain({ 30 })
  eq(lb:choose(lv).move, 2, "palace (low HP): the second pair -- 30 is DEFENSE there")
  eq(lb.lastPalace3.low, true, "palace (low HP): read off the referee's bit (Battle:palaceLow)")
  eq(palaceBrain({ 10 }):choose(lv).move, 0, "palace (low HP): under 20 still ATTACK")

  -- The trainer's AI_TrySwitchOrUseItem still runs first (the opponent's
  -- controller asks it before the move); a `moveOnly` view never switches.
  local sb, sv = single(moves, { sheet({ slot = 1 }) })
  sb.byId.n.b.perishTurns = 0
  eq(palaceBrain({ 10 }):choose(sv).action, "switch", "palace: the trainer's switch comes first")
  sv.moveOnly = true
  eq(palaceBrain({ 10 }):choose(sv).action, "fight", "palace: ...the player's monster only ever picks a move")

  -- An Encore: the controller is never asked; the encored move, nothing drawn.
  local eb, ev = single(moves)
  eb.byId.n.b.encoreTurns, eb.byId.n.b.encoreNum = 2, moves[2].num
  local enc = palaceBrain({ 10 })
  eq(enc:choose(ev).move, 1, "palace: an Encore's move")
  eq(enc.lastPalace3, nil, "palace: ...and no nature drawn")
  -- Nothing usable: Struggle, nothing drawn.
  local nb, nv = single({ mv(10, { power = 40, pp = 0 }) })
  local st = palaceBrain({ 10 })
  eq(st:choose(nv).move, 0, "palace: no usable move -- the referee's Struggle")
  eq(st.lastPalace3, nil, "palace: ...the controller never asked")
  check(nb ~= nil, "palace: (the fight)")
end

do -- the group's one move unusable: the pick may land on it, and fails there
  local battle = palaceFight({
    a = { { playerId = "p", name = "P", mons = { sheet() } } },
    b = { { playerId = "n", name = "N", mons = { sheet({ moves = { attack(), support() } }) } } },
  })
  local n = battle.byId.n
  n.b.disabledNum = 10
  local v = view3(battle, n)
  -- No scripts: every slot ties at 0 (the mask's one move is disabled), the
  -- pick is any of the two -- the first, by this generator.
  local b0 = brain3(0, { aiBits = EM, palace = PALACE, rng = queued({ 10 }) })
  local c = b0:choose(v)
  eq(c.move, 0, "palace (disabled): the drawn group's disabled move can be picked")
  check(battle:submitChoice("n", c), "palace (disabled): the referee takes the pick")
  eq(n.choice and n.choice.palace, "disabled", "palace (disabled): ...and fails it at selection")

  -- With the scripts, a masked-out move's score is never under 0 (Cmd_score
  -- flattens it): a NORMAL move into a GHOST is -10 to CHECK_BAD_MOVE.
  local ghost = palaceFight({
    a = { { playerId = "p", name = "P", mons = { sheet({ types = { 7 } }) } } },
    b = { { playerId = "n", name = "N", mons = { sheet({ moves = { attack(), support() } }) } } },
  })
  local gv = view3(ghost, ghost.byId.n)
  gv.moveMask = { [2] = true }
  local plain = brain3(1, { aiBits = EM, rng = queued({}) })
  plain:choose(gv)
  eq(plain.lastScores3 and plain.lastScores3[1], 0, "scores: a masked-out move CHECK_BAD_MOVE marks down stays at 0")
  gv.moveMask = nil
  plain:choose(gv)
  eq(plain.lastScores3 and plain.lastScores3[1], 90, "scores: ...from 100 it is the -10 it always was")
end

do -- no move of the group left: the fallback and its coin
  local function fallbackOf(moves, values)
    local battle = palaceFight({
      a = { { playerId = "p", name = "P", mons = { sheet() } } },
      b = { { playerId = "n", name = "N", mons = { sheet({ moves = moves }) } } },
    })
    local b = brain3(7, { aiBits = EM, palace = PALACE, rng = queued(values) })
    return b:choose(view3(battle, battle.byId.n)), b
  end
  -- DEFENSE drawn (70), none known: a random usable move (slot 2), the coin
  -- under 50 lets it through.
  local c, b = fallbackOf({ attack(), support() }, { 70, 1, 10 })
  eq(c.move, 1, "palace fallback: a random usable move")
  check(b.lastPalace3.fallback, "palace fallback: ...by the fallback")
  local u = fallbackOf({ attack(), support() }, { 70, 1, 50 })
  eq(u.unable, true, "palace fallback: the coin at 50 or over -- 'unable'")
  eq(u.move, nil, "palace fallback: ...no move named")
  -- Two SUPPORT moves are never "the one group with two": the cart's third
  -- test reads the DEFENSE count against 2 << 8 -- an ATTACK move is drawn
  -- as readily as either.
  local s = fallbackOf({ support(45), support(46), attack(10) }, { 70, 2, 10 })
  eq(s.move, 2, "palace fallback: two SUPPORT moves weigh nothing (the cart's bug)")
  -- Two ATTACK moves are: the draw is kept to them.
  local a = fallbackOf({ attack(10), attack(11), support(45) }, { 70, 2, 0, 10 })
  eq(a.move, 0, "palace fallback: two ATTACK moves -- a draw outside them is drawn again")
end

do -- a double: the nature's target (GetBattlePalaceTarget)
  local function double(natureN, hp1, hp2, values, npcMoves, foeFainted, npcTypes)
    local battle = palaceFight({
      a = { { playerId = "p", name = "P", seats = 2,
              mons = { sheet({ hp = hp1 }), sheet({ slot = 1, hp = hp2 }) } } },
      b = { { playerId = "n", name = "N", seats = 2,
              mons = { sheet({ nature = natureN, moves = npcMoves or { attack() }, types = npcTypes }),
                       sheet({ slot = 1, nature = natureN, moves = npcMoves or { attack() } }) } } },
    })
    if foeFainted then
      local seat = battle.byId["p#2"]
      seat.b.mon.hp = 0
    end
    local b = brain3(7, { aiBits = EM, palace = PALACE, rng = queued(values) })
    return b:choose(view3(battle, battle.byId.n))
  end
  eq(double(0, 100, 50, { 10 }).target, 0, "palace double: STRONGER -- the player's left, more HP")
  eq(double(0, 50, 100, { 10 }).target, 1, "palace double: STRONGER -- the right, more HP")
  eq(double(1, 100, 50, { 10 }).target, 1, "palace double: WEAKER -- the right, less HP")
  local r = double(2, 100, 50, { 10 })
  check(r.target == 0 or r.target == 1, "palace double: RANDOM -- either")
  check(double(0, 80, 80, { 10 }).target ~= nil, "palace double: equal HP -- one of them at random")
  eq(double(1, 100, 50, { 10 }, nil, true).target, 0,
     "palace double: WEAKER picks the fallen position -- the move is redirected to its partner")
  -- CURSE: a move at the user (DEFENSE); a Ghost's is aimed by the nature.
  local curse = mv(174, { power = 0, target = 16, effect = 109 })
  local plainCurse = double(0, 100, 50, { 70 }, { curse })
  eq(plainCurse.move, 0, "palace double: CURSE is drawn with DEFENSE")
  eq(plainCurse.target, nil, "palace double: ...a non-Ghost's names nobody (it is its own)")
  local ghostCurse = double(1, 100, 50, { 70 }, { curse }, nil, { 7 })
  eq(ghostCurse.move, 0, "palace double: a Ghost's CURSE, drawn with DEFENSE too")
  eq(ghostCurse.target, 1, "palace double: ...aimed as a SELECTED move, by the nature (WEAKER)")
end

do -- the Battle Arena: no switching, party order
  local judged = sheet({ slot = 1 })
  judged.judged = true
  local battle = palaceFight({
    a = { { playerId = "p", name = "P", mons = { sheet() } } },
    b = { { playerId = "n", name = "N", mons = { sheet(), judged, sheet({ slot = 2, types = { 10 } }) } } },
  }, { rules = { arena = true } })
  local n = battle.byId.n
  n.mons[2].judged = true
  n.b.perishTurns = 0
  local v = view3(battle, n)
  local b = brain3(7, { aiBits = EM })
  eq(b:choose(v).action, "fight", "arena: the referee's rules -- never a switch (ShouldSwitch's ARENA arm)")
  -- A send-out: the next standing, unjudged monster, no scoring.
  local bare = { mon = sheet(), foe = sheet(), party = { sheet(), judged, sheet({ slot = 2 }), sheet({ slot = 3 }) },
                 mustReplace = true }
  bare.party[1].hp = 0
  local pick = brain3(7, { aiBits = EM, arena = true }):choose(bare)
  eq(pick and pick.slot, 2, "arena: the send-out is the next in party order, the judged one passed over")
  -- Anywhere, a judged monster is down for good.
  local open = create({
    a = { { playerId = "p", name = "P", mons = { sheet() } } },
    b = { { playerId = "n", name = "N", mons = { sheet(), judged } } },
  })
  open.byId.n.b.perishTurns = 0
  eq(brain3(7, { aiBits = EM }):choose(view3(open, open.byId.n)).action, "switch",
     "judged: (a perish count switches to a standing bench monster)")
  open.byId.n.mons[2].judged = true
  eq(brain3(7, { aiBits = EM }):choose(view3(open, open.byId.n)).action, "fight",
     "judged: a judged monster -- the referee's mark -- is no bench to switch to")
end

-- ===================================================================

check(not contains(warns, "ERROR"), "no error was logged: " .. table.concat(warns, " / "))
eq(#warns, 0, "no warning fired beyond the one pinned above: " .. table.concat(warns, " / "))

T.finish("gen3_solo_brain")
