-- The Lua half of the **Gen 2** turn machine's cross-runtime parity check.
--
-- Run: luajit tests/drivers/battle2_turn_parity.lua .       (from this root)
--
-- Drives src/BattleSim2/Turn.lua through a fixed set of scenarios and prints
-- the event stream, the outcome and a snapshot digest as JSON on stdout.
-- server/battle2_turn.test.js builds the same scenarios against
-- server/lib/battle2/Turn.js and asserts the two are equal, event for event.
-- It spawns this file when luajit is on PATH and falls back to
-- tests/fixtures/battle2_turn_parity.json -- this script's own committed output
-- -- when it is not.
--
-- Same contract and the same JSON shape as its Gen 1 sibling
-- (`battle_turn_parity.lua`), which pins the *formula* draw sites. This one
-- scopes to the three referee rules `docs/plans/gen2-new-battle-system.md`
-- brought across from the Gen 1 twin, because those are the rules that are new
-- in this directory and therefore the ones that can drift:
--
--   * `exp_wild` / `exp_coop` -- who a faint pays, and the divisor. A stream
--     that differs from the JS one by a permutation of the `exp` rows is a
--     parity failure with no symptom anyone could read, which is exactly why
--     the events are compared in order rather than as a set.
--   * `replace` -- the phase between two turns: the solicitation's `slot`, the
--     turn number holding still across it, and the successor's party index on
--     `switch` / `send`.
--   * `retarget` -- a stolen KO. The slower ally's action must land on the
--     seat that is left, and it must land on it having drawn the same bytes.
--   * `badges_link` / `badges_coop_pvp` / `badges_npc` / `badges_gold` --
--     where an uploaded badge set counts (Turn.BADGE_MODES: side a of a fight
--     against the computer, never a link battle and never side b), and what
--     it does there: Crystal's stat boosts, Glacier's Sp. Def tail, the 999
--     cap and DoBadgeTypeBoosts.
--   * the pokecrystal fidelity pass (docs/plans/gen12-referee-fidelity.md):
--     `stage_badge_order` (CalcPlayerStats: stage, then badge, rounding and
--     the turn order it moves), `crit_stages` (CheckDamageStatsCritical both
--     ways, screens included / ignored), `truncate_wild` / `truncate_link`
--     (TruncateHL_BC's loop against its single link pass and wrap),
--     `screens_side` (per side, five turns, a failed recast, surviving a
--     switch and Haze), `self_hit` (own Reflect, the Explosion-selected
--     halving), `struggle_typeless`, `metronome_last_pp` and `priority`.
--
-- The snapshot digest carries `rngState`, which is the single number that says
-- both runtimes drew the same count: a faint that paid out must not move it,
-- and the retarget scenario exists partly to prove redirecting an action does
-- not spend a byte the other runtime would not have spent.
--
-- Standalone on purpose, like the suites beside it: it loads the shipped files
-- through the same `need`-shaped resolver main.lua uses, with no love, no
-- engine modules and no mod facade -- which is the claim src/BattleSim2/ makes.
--
-- Synthetic throughout: no species, move or item this repo may not name appears
-- anywhere below.
--
-- Invoked as: luajit <this file> <repo root>

local ROOT = arg and arg[1] or "."

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
  if not body then error("missing " .. path, 0) end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then error(tostring(err), 0) end
  cache[name] = chunk(need)
  return cache[name]
end

local Turn = need("BattleSim2/init").Turn

-- ------------------------------------------------------------------
-- canonical JSON out (byte-identical shape to battle_turn_parity.lua)
-- ------------------------------------------------------------------

local function encString(s)
  local body = s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    if c == '\n' then return '\\n' end
    if c == '\r' then return '\\r' end
    if c == '\t' then return '\\t' end
    return string.format('\\u%04x', c:byte())
  end)
  return '"' .. body .. '"'
end

local function encNumber(n)
  if n == math.floor(n) then return string.format("%d", n) end
  return string.format("%.17g", n)
end

local function encScalar(v)
  local t = type(v)
  if t == "string" then return encString(v) end
  if t == "number" then return encNumber(v) end
  if t == "boolean" then return v and "true" or "false" end
  return "null"
end

-- Flat until `moves` arrived.  A `moves` event (Transform / Mimic republishing
-- a live move list) is the one event kind carrying a table value, and encoding
-- it as `null` -- which is what encScalar does with any table -- would have made
-- every such event compare equal on both runtimes no matter what was in it.
-- One level of nesting is all the vocabulary has, so one level is all this
-- takes; a deeper value would still land as null, loudly, in a diff.
local function encObject(tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = tbl[k]
    if type(v) == "table" then
      local rows = {}
      for i = 1, #v do
        local row = v[i]
        if type(row) == "table" then
          local inner = {}
          for ik in pairs(row) do inner[#inner + 1] = ik end
          table.sort(inner)
          local cells = {}
          for _, ik in ipairs(inner) do
            cells[#cells + 1] = encString(ik) .. ":" .. encScalar(row[ik])
          end
          rows[i] = "{" .. table.concat(cells, ",") .. "}"
        else
          rows[i] = encScalar(row)
        end
      end
      parts[#parts + 1] = encString(k) .. ":[" .. table.concat(rows, ",") .. "]"
    else
      parts[#parts + 1] = encString(k) .. ":" .. encScalar(v)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function encList(list, encoder)
  local parts = {}
  for i = 1, #list do parts[i] = encoder(list[i]) end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function encOutcome(out)
  if not out then return "null" end
  local parts = {
    '"battle":' .. encString(out.battle),
    '"outcome":' .. encString(out.outcome),
    '"reason":' .. encString(out.reason),
  }
  if out.winners then
    parts[#parts + 1] = '"winners":' .. encList(out.winners, encString)
  end
  if out.losers then
    parts[#parts + 1] = '"losers":' .. encList(out.losers, encString)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- A digest rather than the whole snapshot: the RNG state is the part that
-- proves both runtimes drew the same number of bytes at the same points.
local function encSnapshot(battle)
  local snap = battle:snapshot()
  local rows = {}
  for _, entry in ipairs(snap.field) do
    rows[#rows + 1] = "{"
      .. '"slot":' .. encNumber(entry.slot) .. ","
      .. '"hp":' .. encNumber(entry.hp) .. ","
      .. '"party":' .. encList(entry.party, encNumber)
      .. "}"
  end
  return "{"
    .. '"phase":' .. encString(snap.phase) .. ","
    .. '"turn":' .. encNumber(snap.turn) .. ","
    .. '"seq":' .. encNumber(snap.seq) .. ","
    .. '"now":' .. encNumber(snap.now) .. ","
    .. '"deadline":' .. (snap.deadline and encNumber(snap.deadline) or "null") .. ","
    .. '"rngState":' .. encNumber(snap.rngState) .. ","
    .. '"field":[' .. table.concat(rows, ",") .. "]"
    .. "}"
end

-- ------------------------------------------------------------------
-- fixtures (synthetic: no species, move or item this repo may not name)
-- ------------------------------------------------------------------

local function mv(id, power, accuracy, ty, pp)
  return { id = id, pp = pp or 60, power = power, accuracy = accuracy,
           type = ty, effect = 0, chance = 0 }
end

-- Gen 2 sheet dialect throughout: spe / spa / spd, never the Gen 1
-- spd=Speed / spc=Special pair, so `copyMon` takes the Gen 2 branch.
local function mn(o)
  return {
    species = o.species, level = o.level or 20, hp = o.hp,
    maxHp = o.maxHp or 100, status = o.status, types = o.types,
    stats = { atk = o.atk or 40, def = o.def or 40,
              spe = o.spe or 40, spa = o.spa or 40, spd = o.spd or 40 },
    moves = o.moves,
    stages = o.stages, confusion = o.confusion, focusEnergy = o.focusEnergy,
  }
end

-- A move with an effect id (src/BattleSim2/Effects.lua numbering), which `mv`
-- leaves at 0.
local function fx(id, power, ty, effect, pp)
  return { id = id, pp = pp or 60, power = power, accuracy = 255,
           type = ty, effect = effect, chance = 0 }
end

local function build(opts)
  local battle, err = Turn.create(opts)
  if not battle then error("scenario refused: " .. tostring(err), 0) end
  return battle
end

-- ------------------------------------------------------------------
-- scenarios
-- ------------------------------------------------------------------

local scenarios = {}

local function scenario(name, fn)
  scenarios[#scenarios + 1] = { name = name, run = fn }
end

-- The events go into one flat list, and how many came out of each drain goes
-- into a second one beside it.  The counts are not decoration: they are the
-- only record of *when* an event was available, and a clock that fired a turn
-- early produces exactly the same events in exactly the same order, just one
-- drain sooner.
local batches = {}

local function drainInto(battle, events)
  local list = battle:drainEvents()
  for _, event in ipairs(list) do events[#events + 1] = event end
  batches[#batches + 1] = #list
end

-- 1. a wild fight that ends in a KO: one owner seat, one payout, and the
--    rngState afterwards proves the payout drew nothing.
scenario("exp_wild", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "expw", mode = "wild", seed = 4242,
    choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mn({ species = "Alpha", maxHp = 200, atk = 90, spe = 80,
                            moves = { thump() } }) } } },
      b = { { playerId = "wild", name = "Wild",
              mons = { mn({ species = "Beta", maxHp = 60, spe = 10,
                            moves = { thump() } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 8 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- 2. coop_wild: two owner seats standing at the KO, so two payouts in
--    field-slot order with a divisor of two.
scenario("exp_coop", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "expc", mode = "coop_wild", seed = 5150,
    choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mn({ species = "Alpha", maxHp = 200, atk = 90, spe = 80,
                        moves = { thump() } }) } },
        { playerId = "a2", name = "Abe",
          mons = { mn({ species = "Gamma", maxHp = 200, atk = 90, spe = 70,
                        moves = { thump() } }) } },
      },
      b = { { playerId = "wild", name = "Wild",
              mons = { mn({ species = "Beta", maxHp = 200, spe = 10,
                            moves = { thump() } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 8 do
    if battle:outcome() then break end
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    battle:autoPick("wild")
    drainInto(battle, events)
  end
  return battle
end)

-- 3. the replace phase: a foe seat with a bench falls, is solicited by field
--    slot, answers, and only then does the turn advance.  The party index on
--    `switch` / `send` is what stops a client re-fielding the fallen copy of a
--    duplicated species.
scenario("replace", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "rep", mode = "coop_npc", seed = 6161,
    choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mn({ species = "Alpha", maxHp = 200, atk = 95, spe = 90,
                        moves = { thump() } }) } },
        { playerId = "a2", name = "Abe",
          mons = { mn({ species = "Gamma", maxHp = 200, atk = 95, spe = 80,
                        moves = { thump() } }) } },
      },
      b = { { playerId = "npc", name = "Foe",
              mons = { mn({ species = "Beta", maxHp = 30, spe = 10,
                            moves = { thump() } }),
                       mn({ species = "Delta", maxHp = 400, spe = 10,
                            moves = { thump() } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 4 do
    if battle:outcome() then break end
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    -- Called twice on purpose: the first files the ordinary turn's answer, the
    -- second the replacement the KO opened.  A loop that stopped after one
    -- would leave the phase open, which is what `Hub:fillNpcChoices` does not.
    battle:autoPick("npc")
    battle:autoPick("npc")
    drainInto(battle, events)
  end
  return battle
end)

-- 4. a stolen KO.  `fast` empties foe seat 2; `slow` aimed there too and must
--    swing at seat 3 instead of fizzling -- and must do it having drawn the
--    same bytes the JS twin drew.
scenario("retarget", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "ret", mode = "coop_pvp", seed = 7272,
    choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "fast", name = "Fast",
          mons = { mn({ species = "Alpha", maxHp = 300, atk = 200, spe = 99,
                        moves = { thump() } }) } },
        { playerId = "slow", name = "Slow",
          mons = { mn({ species = "Gamma", maxHp = 300, atk = 200, spe = 90,
                        moves = { thump() } }) } },
      },
      b = {
        { playerId = "foeA", name = "FoeA",
          mons = { mn({ species = "Beta", maxHp = 1, spe = 5,
                        moves = { thump() } }) } },
        { playerId = "foeB", name = "FoeB",
          mons = { mn({ species = "Delta", maxHp = 400, spe = 5,
                        moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("fast", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("slow", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("foeA", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 0 })
  drainInto(battle, events)
  return battle
end)

-- 5. a whole trapping chain.  Gen1's 2..5 counter is a *total* attack count, so
--    the turn Wrap lands on deals the move's damage and no residual on top of
--    it; every later turn is one attack, forced on both seats and therefore
--    ticked rather than submitted.  The tail also pins that a referee-filled
--    answer cannot be cancelled away -- silently, so what shows up on the wire
--    is the absence of an `unchose`.
scenario("trap_chain", function(events)
  local wrap = function()
    return { id = "wrap", pp = 60, power = 5, accuracy = 255, type = 0,
             effect = 42, chance = 0 }
  end
  local battle = build({
    id = "trp", mode = "1v1", seed = 9999,
    choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mn({ species = "Alpha", maxHp = 400, spe = 120,
                            moves = { wrap() } }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mn({ species = "Beta", maxHp = 400, def = 200, spe = 1,
                            moves = { mv("tap", 40, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  for step = 1, 10 do
    battle:tick(step)
    drainInto(battle, events)
  end
  battle:submitChoice("p2", { action = "cancel" })
  battle:submitChoice("p2", { action = "switch", slot = 0 })
  drainInto(battle, events)
  return battle
end)

-- the display name a sheet carries (PROTOCOL 26), and the id it falls back to
-- when it carries none.  The Gen 1 pair next door explains the shape; this is
-- the Gen 2 twin of it, because BattleSim2 / lib/battle2 narrate a move from
-- their own copies of the same five call sites.
scenario("move_names", function(events)
  -- `mv` writes effect=0, so the two effect moves are built by hand.  86 is
  -- DISABLE_EFFECT and 82 is MIMIC_EFFECT (src/BattleSim2/Effects.lua).
  local swipe = function()
    return { id = "slow_swipe", name = "SLOW SWIPE", pp = 60, power = 10,
             accuracy = 255, type = 0, effect = 0, chance = 0 }
  end
  local lockdown = function()
    return { id = "lock_down", name = "LOCK DOWN", pp = 60, power = 0,
             accuracy = 255, type = 0, effect = 86, chance = 0 }
  end
  local copycat = function()
    return { id = "copy_cat", name = "COPY CAT", pp = 60, power = 0,
             accuracy = 255, type = 0, effect = 82, chance = 0 }
  end
  local thump = function()
    return { id = "thump", name = "THUMP HIT", pp = 60, power = 10,
             accuracy = 255, type = 0, effect = 0, chance = 0 }
  end
  -- No `name` at all: the protocol-25 sheet, narrated under its id.
  local nudge = function() return mv("nudge", 10, 255, 0) end
  local battle = build({
    id = "mn", mode = "1v1", seed = 4242, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 400, spe = 90,
             moves = { swipe(), lockdown(), copycat() } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, spe = 10,
             moves = { thump(), nudge() } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 1 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 2 })
  battle:submitChoice("p2", { action = "fight", move = 1 })
  drainInto(battle, events)
  for _ = 1, 5 do
    battle:submitChoice("p1", { action = "fight", move = 2 })
    battle:submitChoice("p2", { action = "fight", move = 1 })
    drainInto(battle, events)
  end
  return battle
end)

-- uploaded badge sets, and where the referee lets them count (Turn.BADGE_MODES
-- / Turn.BADGE_SIDE: side a of a fight against the computer, never a link
-- battle -- Crystal's BadgeStatBoosts returns early in one).  Every seat holds
-- all sixteen Gold badges and the ruleset names the types, so a leak would
-- show as a stat boost or a type boost.  Speeds sit a step apart so a PLAIN
-- that leaked would reorder the field rather than merely move a damage
-- number, and the npc fight carries a special move so GLACIER (Sp. Atk) and
-- VOLCANO's type boost are both read.  `badges_link` and `badges_coop_pvp`
-- fight as though nobody held a badge; `badges_npc` boosts side a and ignores
-- side b's upload; `badges_gold` drives the rules a plain fight never reaches
-- -- the 999 cap, Glacier's Sp. Def tail, a type boost on a move with no
-- stat badge behind it, and a confusion self-hit on boosted stats.
local function allBadges()
  return { ZEPHYR = true, HIVE = true, PLAIN = true, FOG = true,
           MINERAL = true, STORM = true, GLACIER = true, RISING = true,
           BOULDER = true, CASCADE = true, THUNDER = true, RAINBOW = true,
           SOUL = true, MARSH = true, VOLCANO = true, EARTH = true }
end

-- Chart index 0 is NORMAL (PLAIN's type), 1 FIRE (VOLCANO's, and Special),
-- 2 BUG (HIVE's).
local TYPE_IDS = { "NORMAL", "FIRE", "BUG" }

scenario("badges_link", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "bl", mode = "1v1", seed = 2718, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = TYPE_IDS,
    sides = {
      a = { { playerId = "p1", name = "Ann", badges = allBadges(), mons = {
        mn({ species = "Alpha", maxHp = 200, atk = 60, spe = 40, moves = { thump() } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 200, atk = 60, spe = 42, moves = { thump() } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 3 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

scenario("badges_coop_pvp", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "bp", mode = "coop_pvp", seed = 3141, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = TYPE_IDS,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", badges = allBadges(), mons = {
          mn({ species = "Alpha", maxHp = 300, atk = 60, spe = 40, moves = { thump() } }) } },
        { playerId = "a2", name = "Abe", badges = allBadges(), mons = {
          mn({ species = "Gamma", maxHp = 300, atk = 55, spe = 30, moves = { thump() } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", badges = allBadges(), mons = {
          mn({ species = "Beta", maxHp = 300, atk = 60, spe = 42, moves = { thump() } }) } },
        { playerId = "b2", name = "Bea", badges = allBadges(), mons = {
          mn({ species = "Delta", maxHp = 300, atk = 55, spe = 34, moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  for _ = 1, 2 do
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
    battle:submitChoice("b2", { action = "fight", move = 0, target = 1 })
    drainInto(battle, events)
  end
  return battle
end)

scenario("badges_npc", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local zap = function() return mv("zap", 40, 255, 1) end
  local battle = build({
    id = "bn", mode = "coop_npc", seed = 1618, choiceTimeout = 60, reconnectGrace = 60,
    specialTypes = { 1 },
    typeIds = TYPE_IDS,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", badges = allBadges(), mons = {
          mn({ species = "Alpha", maxHp = 300, atk = 60, spe = 40, moves = { thump() } }) } },
        { playerId = "a2", name = "Abe", badges = allBadges(), mons = {
          mn({ species = "Gamma", maxHp = 300, spa = 60, spd = 50, spe = 30,
               moves = { zap() } }) } },
      },
      b = {
        { playerId = "n1", name = "NpcA", badges = allBadges(), mons = {
          mn({ species = "Beta", maxHp = 300, atk = 60, spe = 42, moves = { thump() } }) } },
        { playerId = "n2", name = "NpcB", badges = allBadges(), mons = {
          mn({ species = "Delta", maxHp = 300, spa = 60, spd = 50, spe = 37,
               moves = { zap() } }) } },
      },
    },
  })
  drainInto(battle, events)
  for _ = 1, 2 do
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    battle:submitChoice("n1", { action = "fight", move = 0, target = 0 })
    battle:submitChoice("n2", { action = "fight", move = 0, target = 1 })
    drainInto(battle, events)
  end
  return battle
end)

scenario("badges_gold", function(events)
  local bite = function() return mv("bite", 40, 255, 2) end
  local thump = function() return mv("thump", 40, 255, 0) end
  local zap = function() return mv("zap", 40, 255, 1) end
  -- Abe is confused, so his turns spend the confusion byte and, on this seed,
  -- hit himself on MINERAL's boosted Defense.
  local abe = mn({ species = "Gamma", maxHp = 300, atk = 50, def = 40,
                   spa = 227, spd = 50, spe = 30, moves = { thump() } })
  abe.confusion = 4
  local battle = build({
    id = "bg", mode = "coop_npc", seed = 2027, choiceTimeout = 60, reconnectGrace = 60,
    specialTypes = { 1 },
    typeIds = TYPE_IDS,
    sides = {
      a = {
        -- 950 Attack under ZEPHYR is the 999 cap; HIVE type-boosts the BUG
        -- move, which no stat badge stands behind.
        { playerId = "a1", name = "Ann", badges = { ZEPHYR = true, PLAIN = true, HIVE = true },
          mons = { mn({ species = "Alpha", maxHp = 300, atk = 950, spe = 40,
                        moves = { bite() } }) } },
        -- Sp. Atk 227 boosts to 255 under GLACIER, which Glacier's tail reads
        -- as a Sp. Def boost too; MINERAL stands behind Defense.
        { playerId = "a2", name = "Abe", badges = { GLACIER = true, MINERAL = true },
          mons = { abe } },
      },
      b = {
        { playerId = "n1", name = "NpcA", badges = allBadges(), mons = {
          mn({ species = "Beta", maxHp = 400, spa = 70, spe = 42, moves = { zap() } }) } },
        { playerId = "n2", name = "NpcB", badges = allBadges(), mons = {
          mn({ species = "Delta", maxHp = 999, def = 600, atk = 70, spe = 37,
               moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  for _ = 1, 3 do
    battle:submitChoice("a1", { action = "fight", move = 0, target = 4 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("n1", { action = "fight", move = 0, target = 1 })
    battle:submitChoice("n2", { action = "fight", move = 0, target = 1 })
    drainInto(battle, events)
  end
  return battle
end)

-- CalcPlayerStats' order: the stage, then the badge.  Ann's Attack 100 at -1
-- is 66, which ZEPHYR lifts to 74 (badge first would be 112 -> 73), and her
-- Speed 100 at -1 is 66, which PLAIN lifts to 74 -- one point ahead of NpcA's
-- 73, so she moves first where badge-then-stage tied them.  Abe's Sp. Atk 152
-- at +1 is 228, which GLACIER lifts to 256: an odd tail, so his Sp. Def 100 is
-- boosted too (the unstaged 152 -> 171 would have left it alone).
scenario("stage_badge_order", function(events)
  local slam = function() return mv("slam", 100, 255, 0) end
  local zap = function() return mv("zap", 60, 255, 1) end
  local battle = build({
    id = "sb", mode = "coop_npc", seed = 4096, choiceTimeout = 60, reconnectGrace = 60,
    -- Index 0 names DARK, a type no held badge boosts, so PLAIN moves Speed
    -- and nothing else.
    specialTypes = { 1 }, typeIds = { "DARK", "FIRE" },
    sides = {
      a = {
        { playerId = "a1", name = "Ann", badges = { ZEPHYR = true, PLAIN = true },
          mons = { mn({ species = "Alpha", level = 50, maxHp = 400, atk = 100, spe = 100,
                        types = { 2 }, stages = { atk = -1, spe = -1 },
                        moves = { slam() } }) } },
        { playerId = "a2", name = "Abe", badges = { GLACIER = true },
          mons = { mn({ species = "Gamma", level = 50, maxHp = 400, spa = 152, spd = 100,
                        spe = 30, types = { 2 }, stages = { spa = 1 },
                        moves = { zap() } }) } },
      },
      b = {
        { playerId = "n1", name = "NpcA", mons = {
          mn({ species = "Beta", level = 50, maxHp = 400, def = 20, spe = 73,
               types = { 2 }, moves = { slam() } }) } },
        { playerId = "n2", name = "NpcB", mons = {
          mn({ species = "Delta", level = 50, maxHp = 400, spa = 120, spe = 20,
               types = { 2 }, moves = { zap() } }) } },
      },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
  battle:submitChoice("n1", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("n2", { action = "fight", move = 0, target = 1 })
  drainInto(battle, events)
  return battle
end)

-- CheckDamageStatsCritical, both ways, on a seed where each side crits once.
-- Both raise Reflect on turn 1.  Ann (Attack +1, Defense +2) crits Bob on
-- turn 3: Bob's Defense stage 0 is lower than her +1, so the boosted pair is
-- kept -- 120 against Bob's Reflect-doubled 160.  Bob (focus energy, for a
-- crit ladder that is not Ann's) crits Ann on turn 2: her +2 is not lower than
-- his 0, so the hit reads the unmodified 80 against 80, no stage and no
-- Reflect.
scenario("crit_stages", function(events)
  local slash = function()
    local m = mv("slash_hit", 70, 255, 0, 30); m.highCrit = true; return m
  end
  local wall = function() return fx("wall_up", 0, 1, 65, 20) end
  local battle = build({
    id = "cr", mode = "1v1", seed = 2, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", level = 30, maxHp = 400, atk = 80, def = 80, spe = 60,
             types = { 2 }, stages = { atk = 1, def = 2 }, moves = { slash(), wall() } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", level = 30, maxHp = 400, atk = 80, def = 80, spe = 50,
             types = { 2 }, focusEnergy = true, moves = { slash(), wall() } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 1 })
  battle:submitChoice("p2", { action = "fight", move = 1 })
  drainInto(battle, events)
  for _ = 1, 3 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- TruncateHL_BC.  Bob's Defense 600 under his Reflect is 1200; Ann's Attack is
-- 200.  Outside a link battle the loop folds twice: 12 against 75.  In one (the
-- cart's LINK_COLOSSEUM exit) it folds once and keeps the low bytes: 50
-- against 300 -> 44, the wrap bug.  Same sheets, same seed, only the mode.
local function truncation(mode, id, foeId)
  return function(events)
    local thump = function() return mv("thump", 70, 255, 0) end
    local wall = function() return fx("wall_up", 0, 1, 65, 20) end
    local battle = build({
      id = id, mode = mode, seed = 31337, choiceTimeout = 60, reconnectGrace = 60,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = {
          mn({ species = "Alpha", level = 30, maxHp = 400, atk = 200, spe = 50,
               types = { 2 }, moves = { thump() } }) } } },
        b = { { playerId = foeId, name = "Bob", mons = {
          mn({ species = "Beta", level = 30, maxHp = 400, def = 600, spe = 60,
               types = { 2 }, moves = { wall(), thump() } }) } } },
      },
    })
    drainInto(battle, events)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice(foeId, { action = "fight", move = 0 })
    drainInto(battle, events)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice(foeId, { action = "fight", move = 1 })
    drainInto(battle, events)
    return battle
  end
end
scenario("truncate_wild", truncation("wild", "tw", "wild"))
scenario("truncate_link", truncation("1v1", "tl", "p2"))

-- Screens belong to the SIDE.  Ann raises Reflect on turn 1 and her partner
-- Abe is covered by it; her recast on turn 2 fails; she switches out on turn 3
-- and Bob's Haze lands on turn 4, and neither takes it down; it fades at the
-- end of turn 5 (cast turn included), so turn 6 is unscreened.
scenario("screens_side", function(events)
  local thump = function() return mv("thump", 50, 255, 0) end
  local wall = function() return fx("wall_up", 0, 1, 65, 20) end
  local haze = function() return fx("reset_fog", 0, 1, 25, 20) end
  local battle = build({
    id = "ss", mode = "coop_pvp", seed = 8080, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 999, spe = 90, types = { 2 },
               moves = { wall(), thump() } }),
          mn({ species = "Gamma", maxHp = 999, spe = 85, types = { 2 },
               moves = { thump() } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mn({ species = "Eta", maxHp = 999, spe = 80, types = { 2 },
               moves = { thump() } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 999, atk = 60, spe = 50, types = { 2 },
               moves = { thump(), haze() } }) } },
        { playerId = "b2", name = "Bea", mons = {
          mn({ species = "Delta", maxHp = 999, atk = 60, spe = 40, types = { 2 },
               moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  -- Ann: Reflect, Reflect again, switch to Gamma, then Gamma's one hit.  Bob:
  -- a hit on Abe every turn but the fourth, which is Haze.
  for turn = 1, 6 do
    if turn == 3 then
      battle:submitChoice("a1", { action = "switch", slot = 1 })
    else
      battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    end
    battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    battle:submitChoice("b1", { action = "fight", move = (turn == 4) and 1 or 0, target = 1 })
    battle:submitChoice("b2", { action = "fight", move = 0, target = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- HitConfusion on both sides, on a seed where both confused seats hit
-- themselves on turn 1.  Abe (faster) raises Reflect first, so Ann's self-hit
-- reads her OWN side's Reflect; Bob selected Explosion, so his self-hit reads
-- his Defense halved (DamageCalc's EFFECT_SELFDESTRUCT check sees the
-- selected move).
scenario("self_hit", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local wall = function() return fx("wall_up", 0, 1, 65, 20) end
  local boom = function() return fx("big_boom", 250, 0, 7, 5) end
  local battle = build({
    id = "sh", mode = "coop_pvp", seed = 5, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 300, atk = 60, def = 60, spe = 50,
               types = { 2 }, confusion = 4, moves = { thump() } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mn({ species = "Gamma", maxHp = 300, spe = 90, types = { 2 },
               moves = { wall() } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 300, atk = 60, def = 60, spe = 40,
               types = { 2 }, confusion = 4, moves = { boom() } }) } },
        { playerId = "b2", name = "Bea", mons = {
          mn({ species = "Delta", maxHp = 300, spe = 30, types = { 2 },
               moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("b2", { action = "fight", move = 0, target = 1 })
  drainInto(battle, events)
  return battle
end)

-- Struggle is typeless.  Index 0 is NORMAL and NORMAL cannot touch a GHOST on
-- this chart; Ann (NORMAL) is out of PP, so her Struggle hits Bob (GHOST) with
-- no STAB, and its recoil is a quarter of what it dealt.
scenario("struggle_typeless", function(events)
  local battle = build({
    id = "st", mode = "1v1", seed = 5555, choiceTimeout = 60, reconnectGrace = 60,
    chart = { { 100, 0 }, { 100, 100 } },
    typeIds = { "NORMAL", "GHOST" },
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", level = 30, maxHp = 300, atk = 80, spe = 60,
             types = { 0 }, moves = { mv("thump", 40, 255, 0, 0) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", level = 30, maxHp = 300, def = 60, spe = 50,
             types = { 1 }, moves = { mv("haunt", 40, 255, 1) } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 2 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- Metronome with its last PP calls a plain hit: no recoil, because the called
-- move is not Struggle.  The turn after, every slot is empty, so it is.
scenario("metronome_last_pp", function(events)
  local battle = build({
    id = "mt", mode = "1v1", seed = 6060, choiceTimeout = 60, reconnectGrace = 60,
    metronomePool = { mv("pool_hit", 60, 255, 1, 10) },
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", level = 30, maxHp = 300, atk = 80, spe = 60,
             types = { 2 }, moves = { fx("wave_finger", 0, 0, 83, 1) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", level = 30, maxHp = 300, def = 60, spe = 50,
             types = { 2 }, moves = { mv("thump", 40, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 2 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- GetMovePriority's brackets on a four-seat field.  Turn 1: Bob's PROTECT (3)
-- is slowest and moves first, Ann's QUICK_ATTACK (2) next though she is slow,
-- Bea's plain hit (1), then Abe's VITAL_THROW (0) last though he is fastest.
-- Turn 2: EXTREMESPEED and QUICK_ATTACK share a bracket, so Speed decides
-- between them, and both still move before the faster plain hits.
scenario("priority", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "pr", mode = "coop_pvp", seed = 9090, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 300, spe = 10, types = { 2 },
               moves = { mv("QUICK_ATTACK", 40, 255, 0) } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mn({ species = "Gamma", maxHp = 300, spe = 99, types = { 2 },
               moves = { fx("VITAL_THROW", 70, 0, 17), thump() } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 300, spe = 5, types = { 2 },
               moves = { mv("PROTECT", 0, 255, 0), mv("EXTREMESPEED", 80, 255, 0) } }) } },
        { playerId = "b2", name = "Bea", mons = {
          mn({ species = "Delta", maxHp = 300, spe = 50, types = { 2 },
               moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
  battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("b2", { action = "fight", move = 0, target = 1 })
  drainInto(battle, events)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 1, target = 4 })
  battle:submitChoice("b1", { action = "fight", move = 1, target = 0 })
  battle:submitChoice("b2", { action = "fight", move = 0, target = 1 })
  drainInto(battle, events)
  return battle
end)

-- ------------------------------------------------------------------

local out = {}
for _, entry in ipairs(scenarios) do
  local events = {}
  batches = {}
  local battle = entry.run(events)
  out[#out + 1] = "{"
    .. '"name":' .. encString(entry.name) .. ","
    .. '"events":' .. encList(events, encObject) .. ","
    .. '"batches":' .. encList(batches, encNumber) .. ","
    .. '"outcome":' .. encOutcome(battle:outcome()) .. ","
    .. '"snapshot":' .. encSnapshot(battle)
    .. "}"
end

io.write("[" .. table.concat(out, ",") .. "]\n")
