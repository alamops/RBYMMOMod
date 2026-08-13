-- The Lua half of the turn machine's cross-runtime parity check.
--
-- Run: luajit tests/drivers/battle_turn_parity.lua .        (from this root)
--
-- Drives src/BattleSim/Turn.lua through a fixed set of scenarios and prints the
-- event stream, the outcome and a snapshot digest as JSON on stdout.
-- server/battle_turn.test.js builds the same scenarios against
-- server/lib/battle/Turn.js and asserts the two are equal, event for event.
-- It spawns this file when luajit is on PATH and falls back to
-- tests/fixtures/battle_turn_parity.json -- this script's own committed output
-- -- when it is not.
--
-- The scenarios are not a sample of the interesting cases, they are the draw
-- sites: every one of them exists to spend an RNG byte somewhere the two
-- runtimes could disagree about *whether* to spend it. `ko` and `coop` pay the
-- speed tie-break byte (for a pair and for a group of four); `status` runs a
-- paralysis gate, a confusion gate, a miss that must not go on to draw a crit
-- byte, and a power-0 move that must not draw a damage roll; `immune` proves
-- the damage roll is drawn anyway when the type chart says zero, because in
-- Turn.lua that roll is an argument and arguments are evaluated before the call
-- discovers it did not matter. The snapshot digest carries `rngState`, which is
-- the single number that says both runtimes drew the same count.
--
-- Standalone on purpose, like the suites beside it: it loads the shipped files
-- through the same `need`-shaped resolver main.lua uses, with no love, no
-- engine modules and no mod facade -- which is the claim src/BattleSim/ makes.
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

local Turn = need("BattleSim/init").Turn

-- ------------------------------------------------------------------
-- canonical JSON out
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
  -- Catch sheet digest only: full move lists would bloat the fixture without
  -- proving anything the rngState / event stream do not already pin.
  if out.caught then
    parts[#parts + 1] = '"caught":{'
      .. '"species":' .. encString(out.caught.species) .. ","
      .. '"level":' .. encNumber(out.caught.level) .. ","
      .. '"hp":' .. encNumber(out.caught.hp) .. ","
      .. '"maxHp":' .. encNumber(out.caught.maxHp)
      .. "}"
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

local function mn(o)
  local out = {
    species = o.species, level = o.level or 20, hp = o.hp,
    maxHp = o.maxHp or 100, status = o.status, statusTurns = o.statusTurns,
    confusion = o.confusion, toxicCounter = o.toxicCounter, types = o.types,
    stats = { atk = o.atk or 40, def = o.def or 40,
              spd = o.spd or 40, spc = o.spc or 40 },
    moves = o.moves,
  }
  if o.catchRate ~= nil then out.catchRate = o.catchRate end
  if o.evs then out.evs = o.evs end
  return out
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

-- After a faint with bench left the seat owes a switch, not a fight.
local function fightOrReplace(battle, playerId)
  local snap = battle:snapshot()
  for _, f in ipairs(snap.field or {}) do
    if f.playerId == playerId then
      if f.mustReplace then
        local slot = nil
        for i, hp in ipairs(f.party or {}) do
          if (hp or 0) > 0 then slot = i - 1; break end
        end
        if slot ~= nil then
          return battle:submitChoice(playerId, { action = "switch", slot = slot })
        end
        return false
      end
      break
    end
  end
  return battle:submitChoice(playerId, { action = "fight", move = 0 })
end

-- 1. a deterministic KO fight between two equally fast sides, so the speed
--    tie-break byte is spent on every turn and faint replacement runs.
scenario("ko", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "ko", mode = "1v1", seed = 4242, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 120, atk = 60, spd = 55, moves = { thump() } }),
        mn({ species = "Gamma", maxHp = 90, moves = { thump() } }),
      } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 120, atk = 58, spd = 55, moves = { thump() } }),
        mn({ species = "Delta", maxHp = 90, moves = { thump() } }),
      } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 40 do
    if battle:outcome() then break end
    fightOrReplace(battle, "p1")
    fightOrReplace(battle, "p2")
    drainInto(battle, events)
  end
  return battle
end)

-- 2. a side drops and the grace runs out: forfeit, no rolls at all.
scenario("forfeit", function(events)
  local battle = build({
    id = "ff", mode = "1v1", seed = 7, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", moves = { mv("thump", 40, 255, 0) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", moves = { mv("thump", 40, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:disconnect("p2")
  drainInto(battle, events)
  battle:tick(30)
  drainInto(battle, events)
  battle:tick(61)
  drainInto(battle, events)
  return battle
end)

-- 3. a drop that comes back inside the window, and the fight carries on.
scenario("reconnect", function(events)
  local battle = build({
    id = "rc", mode = "1v1", seed = 11, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 200, spd = 60,
             moves = { mv("thump", 40, 255, 0) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 200, spd = 30,
             moves = { mv("thump", 40, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:disconnect("p1")
  battle:tick(30)
  battle:reconnect("p1")
  drainInto(battle, events)
  -- Past the deadline the drop started, inside the one the return restarted:
  -- nothing may fire here, which is the whole claim about a resumed clock.
  battle:tick(80)
  drainInto(battle, events)
  battle:tick(120)
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  return battle
end)

-- 4. the awkward turn: a burn residual, a paralysis gate, confusion, a type
--    chart with both directions on it, an item, a status move, a switch and a
--    deadline that expires with one side still owing a choice.
scenario("status", function(events)
  local battle = build({
    id = "st", mode = "1v1", seed = 99, choiceTimeout = 10, reconnectGrace = 60,
    chart = { { 100, 200, 50 }, { 50, 100, 200 }, { 200, 50, 100 } },
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", level = 25, maxHp = 160, atk = 70, def = 45,
             spd = 50, types = { 0 }, status = "BRN", moves = {
               mv("thump", 40, 255, 0), mv("hex", 0, 255, 1), mv("weak", 35, 200, 2),
             } }),
        mn({ species = "Gamma", maxHp = 100, spd = 30, types = { 2 },
             moves = { mv("thump", 40, 255, 0) } }),
      } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", level = 25, maxHp = 150, atk = 65, def = 50,
             spd = 50, types = { 1 }, status = "PAR", confusion = 3,
             moves = { mv("thump", 40, 255, 1) } }),
      } } },
    },
  })
  drainInto(battle, events)

  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)

  battle:submitChoice("p1", { action = "item", item = "restore" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)

  battle:submitChoice("p1", { action = "fight", move = 1 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)

  battle:submitChoice("p1", { action = "fight", move = 2 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)

  battle:submitChoice("p1", { action = "switch", slot = 1 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)

  -- Only one side answers; the clock spends the other one's turn.
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:tick(1000)
  drainInto(battle, events)

  for _ = 1, 25 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- 5. an immunity row, a sleep counter that runs out, and toxic stacking until
--    it kills the side carrying it.
scenario("immune", function(events)
  local battle = build({
    id = "im", mode = "1v1", seed = 31, choiceTimeout = 60, reconnectGrace = 60,
    chart = { { 100, 0 }, { 100, 100 } },
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 200, types = { 0 }, status = "SLP",
             statusTurns = 2, moves = { mv("thump", 40, 255, 0) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 200, spd = 5, types = { 1 }, status = "TOX",
             moves = { mv("thump", 40, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 20 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- 6. running: one side concedes, and then a fixture where both do.
scenario("run_one", function(events)
  local battle = build({
    id = "r1", mode = "1v1", seed = 5, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", moves = { mv("thump", 40, 255, 0) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", moves = { mv("thump", 40, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "run" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  return battle
end)

scenario("run_both", function(events)
  local battle = build({
    id = "r2", mode = "1v1", seed = 5, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", moves = { mv("thump", 40, 255, 0) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", moves = { mv("thump", 40, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "run" })
  battle:submitChoice("p2", { action = "run" })
  drainInto(battle, events)
  return battle
end)

-- 7. the tie-break byte at its boundary, from both sides of it.  The two seeds
--    are chosen so the first draw of the battle -- which in a tied 1v1 is the
--    tie-break byte itself -- is 127 and then 128, the two values that decide
--    whether the group reverses.  Without these a threshold that had drifted by
--    one would still agree with the Lua on every other fixture here.
local function tie(id, seed)
  return function(events)
    local battle = build({
      id = id, mode = "1v1", seed = seed, choiceTimeout = 60, reconnectGrace = 60,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 200, atk = 60, spd = 50,
               moves = { mv("thump", 40, 255, 0) } }) } } },
        b = { { playerId = "p2", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 200, atk = 45, spd = 50,
               moves = { mv("thump", 40, 255, 0) } }) } } },
      },
    })
    drainInto(battle, events)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
    return battle
  end
end

scenario("tie_low", tie("tl", 172))   -- first byte 127: side a keeps the lead
scenario("tie_high", tie("th", 41))   -- first byte 128: the group reverses

-- 8. a residual on each side at once, which is the only way the end-of-turn
--    order is observable: residuals run in field order, not in the speed order
--    the moves used, and with one burn in the fixture that claim is untestable.
scenario("residual_both", function(events)
  local battle = build({
    id = "rb", mode = "1v1", seed = 23, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 160, spd = 40, status = "BRN",
             moves = { mv("thump", 40, 255, 0) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 160, spd = 90, status = "PSN",
             moves = { mv("thump", 40, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  return battle
end)

-- 9. a switch and an item in the same turn, on opposite sides.  Both resolve
--    before any move and neither rolls, so the only thing this fixture states
--    is the order of the two passes -- which is the only thing about them that
--    the two runtimes could get differently.
scenario("switch_item", function(events)
  local battle = build({
    id = "si", mode = "1v1", seed = 13, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 200, moves = { mv("thump", 40, 255, 0) } }),
        mn({ species = "Gamma", maxHp = 180, moves = { mv("thump", 40, 255, 0) } }),
      } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 200, moves = { mv("thump", 40, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "switch", slot = 1 })
  battle:submitChoice("p2", { action = "item", item = "restore" })
  drainInto(battle, events)
  return battle
end)

-- 10. sleep with no counter on it.  A party can arrive carrying SLP and no
--     number, and the two runtimes have to invent the same length or one of
--     them spends a turn the other one does not -- so this fixture states the
--     default out loud rather than leaving it to the copy step's comment.
scenario("sleep_default", function(events)
  local battle = build({
    id = "sd", mode = "1v1", seed = 61, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 200, spd = 60, status = "SLP",
             moves = { mv("thump", 40, 255, 0) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 200, spd = 10,
             moves = { mv("thump", 40, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 3 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- 11. PP running out, on both of the paths that can happen down.  Side a spends
--     its last PP on move one and the deadline then has to auto-pick move two;
--     side b starts with nothing left anywhere and every one of its turns falls
--     through to the first move on empty PP, because a turn that cannot pick
--     has to resolve rather than hang.  A port that forgot to decrement would
--     keep picking side a's first move and agree with nothing here.
scenario("pp", function(events)
  local battle = build({
    id = "pp", mode = "1v1", seed = 88, choiceTimeout = 10, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 300, spd = 60, moves = {
          mv("last", 40, 255, 0, 1), mv("spare", 30, 255, 0, 5),
        } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 300, spd = 10, moves = {
          mv("empty", 20, 255, 0, 0),
        } }) } } },
    },
  })
  drainInto(battle, events)
  local clock = 0
  for _ = 1, 3 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    clock = clock + 20
    battle:tick(clock)
    drainInto(battle, events)
  end
  return battle
end)

-- 12. a 2v2 across four field slots with every actor at the same speed, so the
--     tie-break reverses a group of four rather than a pair.
scenario("coop", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "cc", mode = "coop_pvp", seed = 777, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 150, spd = 50, moves = { thump() } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mn({ species = "Gamma", maxHp = 150, spd = 50, moves = { thump() } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 150, spd = 50, moves = { thump() } }) } },
        { playerId = "b2", name = "Bea", mons = {
          mn({ species = "Delta", maxHp = 150, spd = 50, moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  for _ = 1, 4 do
    if battle:outcome() then break end
    battle:submitChoice("a1", { action = "fight", move = 0 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("b1", { action = "fight", move = 0 })
    battle:submitChoice("b2", { action = "fight", move = 0, target = 1 })
    drainInto(battle, events)
  end
  battle:disconnect("b1")
  battle:tick(1000)
  drainInto(battle, events)
  return battle
end)

-- 13. wild catch: MASTER_BALL ends without catch rolls; still a new mode and
--     outcome.reason / caught digest the prior fixtures never touched.
scenario("wild_master", function(events)
  local battle = build({
    id = "wm", mode = "wild", seed = 51, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 200, spd = 80,
             moves = { mv("splash", 0, 255, 0) } }) } } },
      b = { { playerId = "p2", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 40, hp = 10, spd = 10, catchRate = 255,
             moves = { mv("splash", 0, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "item", item = "MASTER_BALL" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  return battle
end)

-- 14. wild POKE_BALL: catchAttempt draws from the RNG (rate roll, then HP
--     roll when the rate check passes). Seed chosen so the stream is stable;
--     regenerate the fixture whenever catch/item draw sites move.
scenario("wild_ball", function(events)
  local battle = build({
    id = "wb", mode = "wild", seed = 88, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 200, spd = 80,
             moves = { mv("splash", 0, 255, 0) } }) } } },
      b = { { playerId = "p2", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 100, hp = 25, spd = 10, catchRate = 45,
             moves = { mv("splash", 0, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "item", item = "POKE_BALL" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  if not battle:outcome() then
    battle:submitChoice("p1", { action = "item", item = "MASTER_BALL" })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- 15. vitamins: fight-local Stat Exp on the sheet (+2560); Gen1 stat delta.
scenario("vitamin", function(events)
  local battle = build({
    id = "vt", mode = "1v1", seed = 3, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", level = 100, maxHp = 200, spd = 80, atk = 40,
             moves = { mv("splash", 0, 255, 0) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 200, spd = 10,
             moves = { mv("splash", 0, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "item", item = "PROTEIN" })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  return battle
end)

-- 16. round 5: wild-mode KO. The faint on the synthetic side b is the one
--     `_awardExp` pays for -- one `exp` event for the sole owner-slot winner
--     (slot 0), split one way (participants = 1). Looped like `ko` rather
--     than aimed at an exact turn count, so the fixture survives a damage
--     formula tweak without a hand-tuned HP number going stale.
scenario("wild_ko", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "wk", mode = "wild", seed = 5001, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 200, atk = 90, spd = 80, moves = { thump() } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 60, spd = 10, moves = { thump() } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 10 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- 17. round 5: coop_wild 2v1 KO. Both owner slots are standing when the
--     wild mon falls, so `_awardExp` walks bySide.a twice -- slot 0 (a1)
--     then slot 1 (a2), field-slot order -- and each event names
--     participants = 2, the share count the split is over.
scenario("coop_wild_ko", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "cwk", mode = "coop_wild", seed = 5002, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 200, atk = 90, spd = 80, moves = { thump() } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mn({ species = "Gamma", maxHp = 200, atk = 90, spd = 70, moves = { thump() } }) } },
      },
      b = { { playerId = "wild", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 200, spd = 10, moves = { thump() } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 10 do
    if battle:outcome() then break end
    battle:submitChoice("a1", { action = "fight", move = 0 })
    battle:submitChoice("a2", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- 18. round 6: participation KO. Mon A fights, switches out alive, and its
--     replacement (mon B) lands the KO. Vanilla still owes mon A a share --
--     it was in against this foe (`Battle:_refield` / `Battle:_awardExp`) --
--     so the referee pays both, on the one seat that owns them, each event
--     naming which party index (`mon`, 0-based) is banking it: 0 for Alpha,
--     1 for Gamma, both against a divisor of 2.
scenario("participation_ko", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local tap = function() return mv("tap", 5, 255, 0) end
  local battle = build({
    id = "pko", mode = "wild", seed = 101, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 200, atk = 90, spd = 80, moves = { thump() } }),
        mn({ species = "Gamma", maxHp = 200, atk = 90, spd = 80, moves = { thump() } }),
      } } },
      b = { { playerId = "wild", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 90, spd = 10, moves = { tap() } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "switch", slot = 1 })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  drainInto(battle, events)
  for _ = 1, 10 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- 19. an Explosion-style double-KO in coop_wild: a1's move fells the wild mon
--     AND a1 itself in the same action. `_faint`/`_unfield` take the
--     self-KO'er out of every participation set before `_drainExp` counts
--     anyone (`Battle:_faint`'s own comment: "the user was still standing,
--     still flagged, and still in the divisor" is exactly the bug this
--     ordering pins shut) -- so a1 is neither paid nor counted, and the
--     wild mon's one exp event names only a2, participants = 1.
scenario("explode_double_ko", function(events)
  -- This file's own `mv` always writes effect=0 (its pp default lives in that
  -- slot instead) -- every other scenario here is fine with that, but EXPLODE
  -- is effect 7 (src/BattleSim/Effects.lua's EXPLODE_EFFECT), so `boom` is
  -- built by hand rather than through the shared helper.
  local boom = function()
    return { id = "boom", pp = 60, power = 250, accuracy = 255, type = 0,
             effect = 7, chance = 0 }
  end
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "xa", mode = "coop_wild", seed = 4242, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 200, atk = 200, spd = 90, moves = { boom() } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mn({ species = "Gamma", maxHp = 200, atk = 40, spd = 80, moves = { thump() } }) } },
      },
      b = { { playerId = "wild", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 60, spd = 10, moves = { thump() } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("a1", { action = "fight", move = 0 })
  battle:submitChoice("a2", { action = "fight", move = 0 })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  drainInto(battle, events)
  return battle
end)

-- 20. the replacement mark: a1 KOs b1, then on the very next turn a switches
--     to a2 (still alive, a1 was never fainted) the same turn b fields b2.
--     Vanilla still marks a1 -- it was standing when b1 fell -- and the
--     send-out's own mark lands on a2 too (`Battle:_refield`'s "pendingFought"
--     comment), so when a2 finishes off b2 both a1 and a2 are paid, on the
--     one seat, divisor 2.
scenario("replacement_mark", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local tap = function() return mv("tap", 5, 255, 0) end
  local battle = build({
    id = "xd", mode = "coop_npc", seed = 101, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 300, atk = 200, spd = 80, moves = { thump() } }),
        mn({ species = "Gamma", maxHp = 300, atk = 200, spd = 80, moves = { thump() } }),
      } } },
      b = { { playerId = "npc", name = "Rival", mons = {
        mn({ species = "Beta", maxHp = 40, spd = 10, moves = { tap() } }),
        mn({ species = "Delta", maxHp = 40, spd = 10, moves = { tap() } }),
      } } },
    },
  })
  drainInto(battle, events)
  -- turn 1: a1 KOs b1
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("npc", { action = "fight", move = 0 })
  drainInto(battle, events)
  -- turn 2: npc's fallen b1 owes a replacement first -- close the replace
  -- phase (b fields b2) -- THEN p1 files its voluntary switch to a2 on the
  -- turn-2 window that the closed replace phase opens.
  battle:submitChoice("npc", { action = "switch", slot = 1 })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "switch", slot = 1 })
  drainInto(battle, events)
  -- turn 3+: a2 KOs b2
  for _ = 1, 6 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("npc", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- 21. dead-target retargeting (U-wave): a faster ally KOs the seat a slower
--     ally aimed at, in the same turn. `_retarget` (Turn.lua:646-690) is the
--     only reason the slower ally's action does not fizzle -- it redraws no
--     RNG of its own, but its target resolution runs on every runtime and
--     nothing here reached it before: U1 found no existing scenario landed
--     an action on a seat that died mid-turn, which is why the bug (a fizzle,
--     "has no target", where a real attack belonged) lived undetected. The
--     retargeted hit still draws the same accuracy/damage/crit bytes a
--     same-turn attack always would, so this also exercises those draws from
--     a target the choice never named.
scenario("retarget_ko", function(events)
  local battle = build({
    id = "rk", mode = "coop_pvp", seed = 4242, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "fast", name = "Fast", mons = {
          mn({ species = "Alpha", maxHp = 200, atk = 200, spd = 90,
               moves = { mv("bigsmash", 150, 255, 0) } }) } },
        { playerId = "slow", name = "Slow", mons = {
          mn({ species = "Gamma", maxHp = 200, atk = 60, spd = 10,
               moves = { mv("tap", 40, 255, 0) } }) } },
      },
      b = {
        { playerId = "foeA", name = "FoeA", mons = {
          mn({ species = "Beta", maxHp = 12, spd = 5,
               moves = { mv("thump", 40, 255, 0) } }) } },
        { playerId = "foeB", name = "FoeB", mons = {
          mn({ species = "Delta", maxHp = 200, spd = 4,
               moves = { mv("thump", 40, 255, 0) } }) } },
      },
    },
  })
  drainInto(battle, events)
  -- Both allies aim at foeA (slot 2). Fast (spd 90) KOs it; Slow (spd 10)
  -- resolves after and must retarget onto foeB (slot 3) rather than fizzle.
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
