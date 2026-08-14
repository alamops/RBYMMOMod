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

local function encObject(tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = encString(k) .. ":" .. encScalar(tbl[k])
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
  }
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
    battle:submitChoice("a1", { action = "fight", move = 0, target = 2 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 2 })
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
    battle:submitChoice("a1", { action = "fight", move = 0, target = 2 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 2 })
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
  battle:submitChoice("fast", { action = "fight", move = 0, target = 2 })
  battle:submitChoice("slow", { action = "fight", move = 0, target = 2 })
  battle:submitChoice("foeA", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 0 })
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
