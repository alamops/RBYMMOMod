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
  if o.baseSpd ~= nil then out.baseSpd = o.baseSpd end
  -- K1's `traded`, and raw sheet fields the shorthand above does not carry
  -- (reflect, disable, ...) -- both absent from every scenario before G1b's.
  if o.traded then out.traded = true end
  for key, value in pairs(o.extra or {}) do out[key] = value end
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

-- The stored battle stats behind the stream (the g1_* scenarios): every
-- standing seat's `cur` and stages, and its screens, at the point the scenario
-- asks -- the numbers the stream only shows second-hand, through a damage
-- figure or a turn order.  Only a scenario that calls this carries a `probes`
-- key at all, so every scenario that predates it encodes exactly as it did.
local probes = {}

local function probe(battle, at)
  for _, fighter in ipairs(battle.fighters) do
    local mon = fighter.active and fighter.mons[fighter.active]
    if mon and mon.hp > 0 then
      probes[#probes + 1] = {
        at = at, slot = fighter.slot,
        atk = mon.cur.atk, def = mon.cur.def, spd = mon.cur.spd, spc = mon.cur.spc,
        sAtk = mon.stages.atk, sDef = mon.stages.def, sSpd = mon.stages.spd,
        sSpc = mon.stages.spc, sAcc = mon.stages.acc, sEva = mon.stages.eva,
        reflect = mon.reflect == true, lightScreen = mon.lightScreen == true,
      }
    end
  end
end

-- A flinch the stream never shows (the g1_flinch_* scenarios): a standing
-- seat's FLINCHED bit, read between turns -- after one turn's events and the
-- next turn's open, which is where the reset does or does not happen.  Rows
-- of their own shape in the same `probes` list.
local function probeFlinch(battle, at)
  for _, fighter in ipairs(battle.fighters) do
    local mon = fighter.active and fighter.mons[fighter.active]
    if mon and mon.hp > 0 then
      probes[#probes + 1] = { at = at, slot = fighter.slot, flinch = mon.flinch == true }
    end
  end
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
    battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
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
  -- Both allies aim at foeA (slot 3). Fast (spd 90) KOs it; Slow (spd 10)
  -- resolves after and must retarget onto foeB (slot 4) rather than fizzle.
  battle:submitChoice("fast", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("slow", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("foeA", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 0 })
  drainInto(battle, events)
  return battle
end)

-- Who the referee swings at when nobody chose.  A coop_npc trainer holds two
-- seats with no connection behind them, so both file their own picks through
-- `autoPick` -- and until the aim stream existed, both picked "the lowest
-- living foe" and hammered seat 0 for the whole fight while the second player
-- was never attacked once.
--
-- Six turns is enough for the spread to show, and the fixture pins the aims
-- themselves rather than merely "they were not all seat 0": the aim draw is a
-- second generator, and a second generator is a second way for the runtimes to
-- part company.  The snapshot's `rngState` is the other half of the claim --
-- it must be exactly what it was before aims spread, because the draws come
-- off `aim` and never off `rng`.
scenario("coop_npc_aim", function(events)
  local battle = build({
    id = "aim", mode = "coop_npc", seed = 4242, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "p1", name = "One", mons = {
          mn({ species = "Alpha", maxHp = 400, spd = 10,
               moves = { mv("tap", 40, 255, 0) } }) } },
        { playerId = "p2", name = "Two", mons = {
          mn({ species = "Gamma", maxHp = 400, spd = 10,
               moves = { mv("tap", 40, 255, 0) } }) } },
      },
      b = {
        { playerId = "n1", name = "NpcA", mons = {
          mn({ species = "Beta", maxHp = 400, spd = 90,
               moves = { mv("thump", 40, 255, 0) } }) } },
        { playerId = "n2", name = "NpcB", mons = {
          mn({ species = "Delta", maxHp = 400, spd = 80,
               moves = { mv("thump", 40, 255, 0) } }) } },
      },
    },
  })
  drainInto(battle, events)
  for _ = 1, 6 do
    battle:submitChoice("p1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("p2", { action = "fight", move = 0, target = 4 })
    battle:autoPick("n1")
    battle:autoPick("n2")
    drainInto(battle, events)
  end
  return battle
end)

-- 25. a whole trapping chain: Wrap lands, the counter is Gen1's *total* attack
--     count, so the turn it lands on deals the move's damage and no residual on
--     top of it -- every later turn is one attack, narrated as a forced skip on
--     both seats.  A turn forced on every seat opens without a deadline and
--     waits for a `tick`, so this is also the one scenario where the batch
--     counts prove the two runtimes advance that chain in the same steps.
scenario("trap_chain", function(events)
  local wrap = function()
    return { id = "wrap", pp = 60, power = 5, accuracy = 255, type = 0,
             effect = 42, chance = 0 }
  end
  local battle = build({
    id = "xt", mode = "1v1", seed = 9999, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 400, spd = 120, moves = { wrap() } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, def = 200, spd = 1,
             moves = { mv("tap", 40, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  -- The forced turns resolve one tick at a time; ten is past the longest roll.
  for step = 1, 10 do
    battle:tick(step)
    drainInto(battle, events)
  end
  -- A referee-filled answer cannot be taken back -- the refusal is silent, so
  -- what this pins is that neither runtime emits an `unchose` for it.
  battle:submitChoice("p2", { action = "cancel" })
  battle:submitChoice("p2", { action = "switch", slot = 0 })
  drainInto(battle, events)
  return battle
end)

-- 26. the display name a sheet carries (PROTOCOL 26), and the id it falls back
--     to when it carries none.  Both spellings appear in one fight, because
--     both reach the same sentences: "used", the two halves of Disable, and
--     Mimic's "learned".  A protocol-25 client uploads moves with no `name` at
--     all, so the fallback is not a defensive branch -- it is what half the
--     fights on a mixed hub narrate under, and the two runtimes have to agree
--     on it word for word.
scenario("move_names", function(events)
  -- `mv` writes effect=0, so the two effect moves are built by hand the way
  -- `explode_double_ko` builds EXPLODE.  86 is DISABLE_EFFECT and 82 is
  -- MIMIC_EFFECT (src/BattleSim/Effects.lua).
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
        mn({ species = "Alpha", maxHp = 400, spd = 90,
             moves = { swipe(), lockdown(), copycat() } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, spd = 10,
             moves = { thump(), nudge() } }) } } },
    },
  })
  drainInto(battle, events)
  -- 1: both swing.  "Alpha used SLOW SWIPE" and "Beta used THUMP HIT" are the
  --    line this whole field exists for; before it they read "slow_swipe".
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  -- 2: Ann is faster, so Disable lands on the move Bob just used and then
  --    refuses the one he picked -- "THUMP HIT was disabled", "THUMP HIT is
  --    disabled", both under the same spelling the attack was.
  battle:submitChoice("p1", { action = "fight", move = 1 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  -- 3: Mimic copies Bob's last move.  The copy has to carry the name across
  --    with it, or "Alpha learned THUMP HIT" reverts to the slug here and on
  --    every turn the copy is used afterwards.  Bob falls back to the move
  --    that carries no name at all.
  battle:submitChoice("p1", { action = "fight", move = 2 })
  battle:submitChoice("p2", { action = "fight", move = 1 })
  drainInto(battle, events)
  -- 4-8: the copy is used, and Disable wears off somewhere in here ("THUMP
  --      HIT is no longer disabled") -- the one sentence that is written from
  --      a move nobody chose this turn.
  for _ = 1, 5 do
    battle:submitChoice("p1", { action = "fight", move = 2 })
    battle:submitChoice("p2", { action = "fight", move = 1 })
    drainInto(battle, events)
  end
  return battle
end)

-- 27-29. uploaded badge sets, and where the referee lets them count
--     (Turn.BADGE_MODES / Turn.BADGE_SIDE: side a of a fight against the
--     computer, never a link battle -- pokered's ApplyBadgeStatBoosts returns
--     early in one).  Speeds sit a step apart so a SOULBADGE that leaked would
--     reorder the field rather than merely move a damage number, and the npc
--     fight carries a special move so VOLCANOBADGE is read on both ends of a
--     hit.  `badges_link` and `badges_coop_pvp` fight as though nobody held a
--     badge; `badges_npc` boosts side a and ignores side b's upload.  Until
--     these, no scenario carried a badge at all, so the twins had never been
--     held to the same boost even where the boost is right.
local function allBadges()
  return { BOULDERBADGE = true, THUNDERBADGE = true, SOULBADGE = true,
           VOLCANOBADGE = true }
end

scenario("badges_link", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "bl", mode = "1v1", seed = 2718, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", badges = allBadges(), mons = {
        mn({ species = "Alpha", maxHp = 200, atk = 60, spd = 40, moves = { thump() } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 200, atk = 60, spd = 42, moves = { thump() } }) } } },
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
    sides = {
      a = {
        { playerId = "a1", name = "Ann", badges = allBadges(), mons = {
          mn({ species = "Alpha", maxHp = 300, atk = 60, spd = 40, moves = { thump() } }) } },
        { playerId = "a2", name = "Abe", badges = allBadges(), mons = {
          mn({ species = "Gamma", maxHp = 300, atk = 55, spd = 30, moves = { thump() } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", badges = allBadges(), mons = {
          mn({ species = "Beta", maxHp = 300, atk = 60, spd = 42, moves = { thump() } }) } },
        { playerId = "b2", name = "Bea", badges = allBadges(), mons = {
          mn({ species = "Delta", maxHp = 300, atk = 55, spd = 34, moves = { thump() } }) } },
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
    sides = {
      a = {
        { playerId = "a1", name = "Ann", badges = allBadges(), mons = {
          mn({ species = "Alpha", maxHp = 300, atk = 60, spd = 40, moves = { thump() } }) } },
        { playerId = "a2", name = "Abe", badges = allBadges(), mons = {
          mn({ species = "Gamma", maxHp = 300, spc = 60, spd = 30, moves = { zap() } }) } },
      },
      b = {
        { playerId = "n1", name = "NpcA", badges = allBadges(), mons = {
          mn({ species = "Beta", maxHp = 300, atk = 60, spd = 42, moves = { thump() } }) } },
        { playerId = "n2", name = "NpcB", badges = allBadges(), mons = {
          mn({ species = "Delta", maxHp = 300, spc = 60, spd = 37, moves = { zap() } }) } },
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

-- 30-41. Gen 1 stored battle stats (docs/plans/gen12-referee-fidelity.md §1
--     items 1-5, task G1a): every trigger of the badge-stacking glitch, the
--     re-penalty glitch, the resets, the 999 / 1 walls, critical hits on party
--     stats, Reflect and Light Screen in the defence, the 8-bit scaling, the
--     Explosion order, the 997 cap, the self-hit's borrowed Reflect and the
--     flinch reset at turn open.  `probe` pins the battle stats themselves;
--     tests/battle_sim_turn.lua (section 25) states the hand-checked numbers.
--     `baseSpd = 0` holds a crit off where it would blur a number, 255 with a
--     high-crit move forces one.
local function fx(id, power, effect, o)
  o = o or {}
  local out = { id = id, pp = o.pp or 60, power = power, accuracy = 255,
                type = o.type or 0, effect = effect, chance = o.chance or 0 }
  if o.highCrit then out.highCrit = true end
  return out
end

-- The player's own raise (50 = ATTACK_UP2) and an accuracy raise (14) each
-- re-run every badge; the wild monster's paralysis is re-quartered each time.
scenario("g1_stack_up", function(events)
  local battle = build({
    id = "g1u", mode = "wild", seed = 6101, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", badges = allBadges(), mons = {
        mn({ species = "Alpha", maxHp = 300, atk = 100, def = 80, spd = 60, spc = 50,
             baseSpd = 0, moves = { fx("sharpen", 0, 50), fx("aim", 0, 14),
                                    fx("thump", 40, 0) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 300, spd = 80, status = "PAR", baseSpd = 0,
             moves = { fx("splash", 0, 85) } }) } } },
    },
  })
  drainInto(battle, events)
  probe(battle, 0)
  for turn, move in ipairs({ 0, 1, 2 }) do
    battle:submitChoice("p1", { action = "fight", move = move })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    drainInto(battle, events)
    probe(battle, turn)
  end
  return battle
end)

-- The enemy's drops on the player: a primary (18), a side-effect drop (71,
-- Psychic's) and an accuracy drop (22) -- each re-runs the badges, and the
-- re-penalty halves the burned target's Attack again every time.
scenario("g1_stack_down", function(events)
  local battle = build({
    id = "g1d", mode = "wild", seed = 6102, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", badges = allBadges(), mons = {
        mn({ species = "Alpha", maxHp = 300, atk = 100, def = 80, spd = 60, spc = 50,
             status = "BRN", baseSpd = 0, moves = { fx("splash", 0, 85) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 300, spd = 90, baseSpd = 0,
             moves = { fx("growl", 0, 18), fx("psyray", 40, 71, { chance = 100 }),
                       fx("sand", 0, 22) } }) } } },
    },
  })
  drainInto(battle, events)
  probe(battle, 0)
  for turn, move in ipairs({ 0, 1, 2 }) do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = move })
    drainInto(battle, events)
    probe(battle, turn)
  end
  return battle
end)

-- An X item and Rage: both are the player's raises, so both re-run the badges;
-- the item's re-penalty lands on the battler opposite and Rage's on the
-- attacker that built it.
scenario("g1_rage_xitem", function(events)
  local battle = build({
    id = "g1r", mode = "wild", seed = 6103, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", badges = allBadges(), bag = { X_SPEED = 1 },
              mons = {
        mn({ species = "Alpha", maxHp = 400, atk = 100, def = 80, spd = 60, spc = 50,
             baseSpd = 0, moves = { fx("fury", 20, 81) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 400, atk = 80, spd = 50, status = "BRN",
             baseSpd = 0, moves = { fx("thump", 10, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  probe(battle, 0)
  battle:submitChoice("p1", { action = "item", item = "X_SPEED" })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  drainInto(battle, events)
  probe(battle, 1)
  for turn = 2, 3 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    drainInto(battle, events)
    probe(battle, turn)
  end
  return battle
end)

-- The resets: a switch-in reloads party -> badges with every stage at 0, and
-- Haze copies the unmodified stats over both battlers -- badges and the foe's
-- paralysis penalty lifted with the stages.
scenario("g1_resets", function(events)
  local battle = build({
    id = "g1z", mode = "wild", seed = 6104, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", badges = allBadges(), mons = {
        mn({ species = "Alpha", maxHp = 300, atk = 100, def = 80, spd = 60, spc = 50,
             baseSpd = 0, moves = { fx("sharpen", 0, 50), fx("haze", 0, 25) } }),
        mn({ species = "Gamma", maxHp = 300, baseSpd = 0, moves = { fx("splash", 0, 85) } }),
      } } },
      b = { { playerId = "wild", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 300, spd = 80, status = "PAR", baseSpd = 0,
             moves = { fx("splash", 0, 85) } }) } } },
    },
  })
  drainInto(battle, events)
  local plan = {
    { action = "fight", move = 0 },
    { action = "switch", slot = 1 },
    { action = "switch", slot = 0 },
    { action = "fight", move = 0 },
    { action = "fight", move = 1 },
  }
  for turn, choice in ipairs(plan) do
    battle:submitChoice("p1", choice)
    battle:submitChoice("wild", { action = "fight", move = 0 })
    drainInto(battle, events)
    probe(battle, turn)
  end
  return battle
end)

-- The walls, in a link fight (no badges; the re-penalty is unconditional): a
-- raise past 999 stores 999, the next raise on that 999 fails with the stage
-- wound back one step (+2 nets +1), and a drop on a stat already at 1 fails
-- the same way (-2 nets -1).
scenario("g1_walls", function(events)
  local battle = build({
    id = "g1w", mode = "1v1", seed = 6105, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 300, atk = 500, spd = 90, baseSpd = 0,
             moves = { fx("sharpen", 0, 50), fx("soften", 0, 19),
                       fx("crush", 0, 59) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 300, def = 1, spd = 60, status = "PAR",
             baseSpd = 0, moves = { fx("splash", 0, 85) } }) } } },
    },
  })
  drainInto(battle, events)
  probe(battle, 0)
  for turn, move in ipairs({ 0, 0, 1, 2 }) do
    battle:submitChoice("p1", { action = "fight", move = move })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
    probe(battle, turn)
  end
  return battle
end)

-- A critical hit reads both party stats: the raised, badged, burned Attack and
-- the foe's Reflect all fall away.
scenario("g1_crit_party", function(events)
  local battle = build({
    id = "g1c", mode = "wild", seed = 6106, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", badges = allBadges(), mons = {
        mn({ species = "Alpha", maxHp = 300, atk = 100, def = 80, spd = 60, spc = 50,
             status = "BRN", baseSpd = 255,
             moves = { fx("sharpen", 0, 50), fx("slash", 70, 0, { highCrit = true }) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 400, def = 100, spd = 30, baseSpd = 0,
             moves = { fx("wall", 0, 65), fx("splash", 0, 85) } }) } } },
    },
  })
  drainInto(battle, events)
  probe(battle, 0)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  drainInto(battle, events)
  probe(battle, 1)
  battle:submitChoice("p1", { action = "fight", move = 1 })
  battle:submitChoice("wild", { action = "fight", move = 1 })
  drainInto(battle, events)
  probe(battle, 2)
  return battle
end)

-- Transform copies the battle and unmodified stats, never the party ones: the
-- transformed monster's crit swings with its own pre-Transform Attack, and a
-- crit on it reads its own pre-Transform Defense.
scenario("g1_transform_crit", function(events)
  local battle = build({
    id = "g1t", mode = "1v1", seed = 6107, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 400, atk = 30, def = 30, spd = 90, spc = 30,
             baseSpd = 255, moves = { fx("mimicry", 0, 57) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, atk = 200, def = 100, spd = 40, spc = 100,
             baseSpd = 255, moves = { fx("slash", 70, 0, { highCrit = true }) } }) } } },
    },
  })
  drainInto(battle, events)
  for turn = 1, 2 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
    probe(battle, turn)
  end
  return battle
end)

-- Screens double the defence before the scaling: 512 x2 = 1024 wraps to a 0
-- byte and divides as 1.  A second Reflect fails, a fixed-damage move ignores
-- it, and Haze takes both screens down.
scenario("g1_screens", function(events)
  local battle = build({
    id = "g1s", mode = "1v1", seed = 6109, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 900, def = 512, spd = 90, baseSpd = 0,
             moves = { fx("wall", 0, 65), fx("glow", 0, 64), fx("splash", 0, 85) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, atk = 100, spd = 30, baseSpd = 0,
             moves = { fx("thump", 10, 0), fx("sonic", 20, 41), fx("haze", 0, 25) } }) } } },
    },
  })
  drainInto(battle, events)
  for turn, pair in ipairs({ { 0, 0 }, { 0, 1 }, { 1, 2 }, { 2, 0 } }) do
    battle:submitChoice("p1", { action = "fight", move = pair[1] })
    battle:submitChoice("p2", { action = "fight", move = pair[2] })
    drainInto(battle, events)
    probe(battle, turn)
  end
  return battle
end)

-- The 997 cap sits before the type chart and the roll: 4200 is held to 997+2
-- (a 999-HP target, so the event states the whole hit).
scenario("g1_cap", function(events)
  local battle = build({
    id = "g1k", mode = "1v1", seed = 6109, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 999, def = 10, spd = 90, types = { 2 },
             baseSpd = 0, moves = { fx("splash", 0, 85) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", level = 100, maxHp = 400, atk = 250, spd = 30,
             types = { 1 }, baseSpd = 0, moves = { fx("crush", 200, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  return battle
end)

-- Explosion halves the defence after the scaling: 300 -> 75 -> 37, not
-- 300 -> 150 unscaled.
scenario("g1_explode_order", function(events)
  local battle = build({
    id = "g1x", mode = "1v1", seed = 6110, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 900, def = 300, spd = 90, types = { 2 },
             baseSpd = 0, moves = { fx("splash", 0, 85) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", level = 50, maxHp = 400, atk = 100, spd = 30,
             types = { 1 }, baseSpd = 0, moves = { fx("blast", 170, 7) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  return battle
end)

-- The confusion self-hit borrows the OPPONENT's Reflect for its own Defense:
-- 160 against 9 x2 is 73 a hit rather than 144.
scenario("g1_self_hit_reflect", function(events)
  local battle = build({
    id = "g1h", mode = "1v1", seed = 6111, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 900, atk = 160, def = 9, spd = 30, confusion = 6,
             baseSpd = 0, moves = { fx("splash", 0, 85) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, spd = 90, baseSpd = 0,
             moves = { fx("wall", 0, 65), fx("splash", 0, 85) } }) } } },
    },
  })
  drainInto(battle, events)
  for turn = 1, 5 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = turn == 1 and 0 or 1 })
    drainInto(battle, events)
  end
  return battle
end)

-- ...and in a 2v2 the Reflect it borrows is the battler opposite's: Ann (seat
-- 0) faces Bob's Reflect, Abe (seat 1) faces Bea, who has none.
scenario("g1_opposite_reflect", function(events)
  local battle = build({
    id = "g1o", mode = "coop_pvp", seed = 6112, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 900, atk = 160, def = 9, spd = 30, confusion = 6,
               baseSpd = 0, moves = { fx("splash", 0, 85) } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mn({ species = "Gamma", maxHp = 900, atk = 160, def = 9, spd = 20, confusion = 6,
               baseSpd = 0, moves = { fx("splash", 0, 85) } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 400, spd = 90, baseSpd = 0,
               moves = { fx("wall", 0, 65), fx("splash", 0, 85) } }) } },
        { playerId = "b2", name = "Bea", mons = {
          mn({ species = "Delta", maxHp = 400, spd = 80, baseSpd = 0,
               moves = { fx("splash", 0, 85) } }) } },
      },
    },
  })
  drainInto(battle, events)
  for turn = 1, 5 do
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    battle:submitChoice("b1", { action = "fight", move = turn == 1 and 0 or 1, target = 0 })
    battle:submitChoice("b2", { action = "fight", move = 0, target = 1 })
    drainInto(battle, events)
  end
  probe(battle, 5)
  return battle
end)

-- A flinch landed on a monster that already moved dies at the next turn's
-- open (MainInBattleLoop) instead of costing it that turn.
scenario("g1_flinch_reset", function(events)
  local battle = build({
    id = "g1f", mode = "1v1", seed = 6113, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 400, spd = 90, baseSpd = 0,
             moves = { fx("thump", 10, 0) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, spd = 30, baseSpd = 0,
             moves = { fx("stomp", 10, 31, { chance = 100 }) } }) } } },
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

-- 42-58. Gen 1 priority, obedience, the called-move path and the flinch-reset
--     skip (docs/plans/gen12-referee-fidelity.md §1 items 6-8, task G1b).
--     Every obedience seed was picked by a scan to reach the branch its
--     comment names; tests/battle_sim_turn.lua (section 26) forces each branch
--     with scripted bytes and works the arithmetic, and the vector pack's
--     `obedience` section pins the rolls themselves.

-- Quick Attack +1, Counter -1, read off the selected move; the same move on
-- both sides falls to Speed.  1v1 is a link fight: priority is every mode's.
--   T1 QA vs thump: the slow QA first.   T2 QA vs QA: the faster first.
--   T3 thump vs COUNTER: the slow thump first.   T4 COUNTER vs COUNTER: Speed.
--   T5 QA vs COUNTER: QA first.
scenario("g1_priority", function(events)
  local function kit()
    return { fx("QUICK_ATTACK", 10, 0), fx("thump", 10, 0), fx("COUNTER", 10, 0) }
  end
  local battle = build({
    id = "g1q", mode = "1v1", seed = 6301, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 400, spd = 30, baseSpd = 0, moves = kit() }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, spd = 90, baseSpd = 0, moves = kit() }) } } },
    },
  })
  drainInto(battle, events)
  for _, pair in ipairs({ { 0, 1 }, { 0, 0 }, { 1, 2 }, { 2, 2 }, { 0, 2 } }) do
    battle:submitChoice("p1", { action = "fight", move = pair[1] })
    battle:submitChoice("p2", { action = "fight", move = pair[2] })
    drainInto(battle, events)
  end
  return battle
end)

-- Four actors in three brackets: the two Quick Attacks at Speed 20 are one
-- tie group (one byte: this seed's turn-1 byte is >= 128, NpcA's first; its
-- turn-2 byte is below, Ann's first), then the plain move, then the Counter
-- at Speed 99, last.
scenario("g1_priority_group", function(events)
  local battle = build({
    id = "g1g", mode = "coop_npc", seed = 6302, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 400, spd = 20, baseSpd = 0,
               moves = { fx("QUICK_ATTACK", 10, 0) } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mn({ species = "Gamma", maxHp = 400, spd = 50, baseSpd = 0,
               moves = { fx("thump", 10, 0) } }) } },
      },
      b = {
        { playerId = "n1", name = "NpcA", mons = {
          mn({ species = "Beta", maxHp = 400, spd = 20, baseSpd = 0,
               moves = { fx("QUICK_ATTACK", 10, 0) } }) } },
        { playerId = "n2", name = "NpcB", mons = {
          mn({ species = "Delta", maxHp = 400, spd = 99, baseSpd = 0,
               moves = { fx("COUNTER", 10, 0) } }) } },
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

-- A Metronome that calls Quick Attack moved at Metronome's bracket: the
-- faster foe goes first.  The call spends Alpha's last PP and takes no
-- Struggle recoil, and runs no second paralysis gate; the next turn's
-- Struggle is the real thing and does recoil.
scenario("g1_metronome_last_pp", function(events)
  local battle = build({
    id = "g1m", mode = "wild", seed = 6302, choiceTimeout = 60, reconnectGrace = 60,
    metronomePool = { fx("QUICK_ATTACK", 10, 0) },
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 400, spd = 120, status = "PAR", baseSpd = 0,
             moves = { fx("metronome", 0, 83, { pp = 1 }) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, spd = 90, baseSpd = 0,
             moves = { fx("thump", 10, 0) } }) } } },
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

-- The whole CheckForDisobedience ladder on one traded level-100 monster with
-- no badge (cap 10), paralysed, against a foe behind a Reflect.  Seed 6809's
-- twelve turns: loafing around; won't obey + the self-hit (Defense doubled by
-- the FOE's Reflect); ignored orders; an R1 pass (thump); a nap over the
-- paralysis (whose quartered Speed stays stored -- probe 5); asleep; woke up;
-- turned away; won't obey (the loaf line); won't obey + self-hit; loafing
-- around; a move used instead.
scenario("g1_obey_ladder", function(events)
  local battle = build({
    id = "g1l", mode = "wild", seed = 6809, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", level = 100, maxHp = 999, atk = 30, def = 60, spd = 90,
             status = "PAR", traded = true, baseSpd = 0,
             moves = { fx("thump", 10, 0), fx("chop", 10, 0), fx("splash", 0, 85) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 999, spd = 30, baseSpd = 0, extra = { reflect = true },
             moves = { fx("splash", 0, 85) } }) } } },
    },
  })
  drainInto(battle, events)
  for turn = 1, 12 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
    if turn == 5 then probe(battle, 5) end
  end
  return battle
end)

-- An R1 pass, then `.useRandomMove`: "used instead," and the PP comes off
-- the CHOSEN slot (thump 60 -> 59 -> 58; chop untouched), then a loaf line.
-- Level 60 under RAINBOWBADGE (cap 50).
scenario("g1_obey_instead", function(events)
  local battle = build({
    id = "g1i", mode = "wild", seed = 6316, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              badges = { CASCADEBADGE = true, RAINBOWBADGE = true }, mons = {
        mn({ species = "Alpha", level = 60, maxHp = 400, spd = 90, traded = true, baseSpd = 0,
             moves = { fx("thump", 10, 0), fx("chop", 10, 0), fx("splash", 0, 85) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, spd = 30, baseSpd = 0,
             moves = { fx("splash", 0, 85) } }) } } },
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

-- `.useRandomMove`'s four refusals, each on seed 6303 -- whose rolls answer
-- "use another move" -- and each falling to `.monDoesNothing` ("is loafing
-- around.") without a `.chooseMove` draw: one move known; a move disabled;
-- Struggle selected; no PP outside the chosen slot.
local function refusal(name, moves, extra)
  return function(events)
    local battle = build({
      id = name, mode = "wild", seed = 6303, choiceTimeout = 60, reconnectGrace = 60,
      sides = {
        a = { { playerId = "p1", name = "Ann",
                badges = { CASCADEBADGE = true, RAINBOWBADGE = true }, mons = {
          mn({ species = "Alpha", level = 60, maxHp = 400, spd = 90, traded = true,
               baseSpd = 0, moves = moves, extra = extra }) } } },
        b = { { playerId = "p2", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 400, spd = 30, baseSpd = 0,
               moves = { fx("splash", 0, 85) } }) } } },
      },
    })
    drainInto(battle, events)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
    return battle
  end
end
scenario("g1_obey_refuse_one", refusal("g1r1", { fx("thump", 10, 0) }))
scenario("g1_obey_refuse_disabled", refusal("g1r2",
  { fx("thump", 10, 0), fx("chop", 10, 0) }, { disable = { moveIndex = 2, turns = 5 } }))
scenario("g1_obey_refuse_struggle", refusal("g1r3",
  { fx("thump", 10, 0, { pp = 0 }), fx("chop", 10, 0, { pp = 0 }) }))
scenario("g1_obey_refuse_pp", refusal("g1r4",
  { fx("thump", 10, 0), fx("chop", 10, 0, { pp = 0 }) }))

-- No roll at all: EARTHBADGE's cap (101) over a level-100 traded monster, and
-- CASCADEBADGE's 30 over a level-30 one -- the cap compare comes first.
scenario("g1_obey_capped", function(events)
  local battle = build({
    id = "g1c", mode = "coop_wild", seed = 6302, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", badges = { EARTHBADGE = true }, mons = {
          mn({ species = "Alpha", level = 100, maxHp = 400, spd = 90, traded = true,
               baseSpd = 0, moves = { fx("thump", 10, 0), fx("chop", 10, 0) } }) } },
        { playerId = "a2", name = "Abe", badges = { CASCADEBADGE = true }, mons = {
          mn({ species = "Gamma", level = 30, maxHp = 400, spd = 70, traded = true,
               baseSpd = 0, moves = { fx("thump", 10, 0), fx("chop", 10, 0) } }) } },
      },
      b = { { playerId = "w", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 900, spd = 30, baseSpd = 0,
             moves = { fx("splash", 0, 85) } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 2 do
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("w", { action = "fight", move = 0, target = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- Never in a link fight (LINK_STATE_BATTLING returns before the check), and
-- never for side b (the computer's own party): both traded level-100s with
-- no badge obey every turn and draw nothing for it.
local function obeyNever(id, mode, aTraded)
  return function(events)
    local battle = build({
      id = id, mode = mode, seed = 6809, choiceTimeout = 60, reconnectGrace = 60,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = {
          mn({ species = "Alpha", level = 100, maxHp = 999, spd = 90, traded = aTraded,
               baseSpd = 0, moves = { fx("thump", 10, 0), fx("chop", 10, 0) } }) } } },
        b = { { playerId = "p2", name = "Bob", mons = {
          mn({ species = "Beta", level = 100, maxHp = 999, spd = 30, traded = true,
               baseSpd = 0, moves = { fx("thump", 10, 0), fx("chop", 10, 0) } }) } } },
      },
    })
    drainInto(battle, events)
    for _ = 1, 3 do
      battle:submitChoice("p1", { action = "fight", move = 0 })
      battle:submitChoice("p2", { action = "fight", move = 0 })
      drainInto(battle, events)
    end
    return battle
  end
end
scenario("g1_obey_link", obeyNever("g1k", "1v1", true))
scenario("g1_obey_side_b", obeyNever("g1b", "wild", false))

-- The flinch-reset skip.  A raging monster on the player's seat that a slower
-- Stomp flinches keeps the flinch through the next turn's open and loses its
-- Rage to it ("Alpha flinched", turn after turn: the Stomp lands every time).
local function rageFlinch(id, mode)
  return function(events)
    local battle = build({
      id = id, mode = mode, seed = 6303, choiceTimeout = 60, reconnectGrace = 60,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 400, spd = 90, baseSpd = 0,
               moves = { fx("fury", 20, 81) } }) } } },
        b = { { playerId = "p2", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 400, spd = 30, baseSpd = 0,
               moves = { fx("stomp", 10, 31, { chance = 100 }) } }) } } },
      },
    })
    drainInto(battle, events)
    for turn = 1, 3 do
      battle:submitChoice("p1", { action = "fight", move = 0 })
      battle:submitChoice("p2", { action = "fight", move = 0 })
      drainInto(battle, events)
      probeFlinch(battle, turn)
    end
    return battle
  end
end
scenario("g1_flinch_rage", rageFlinch("g1fr", "wild"))
-- ...and in a link fight the reset is unconditional: the Rage goes on.
scenario("g1_flinch_rage_link", rageFlinch("g1fl", "1v1"))

-- A Hyper Beam user that a slower Stomp flinches keeps that flinch through the
-- recharge turn's open (probe 1) -- the forced recharge reads no gate -- and
-- the turn after resets it (probe 2): the beam goes again, unflinched.
scenario("g1_flinch_recharge", function(events)
  local battle = build({
    id = "g1fh", mode = "wild", seed = 6303, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 400, spd = 90, baseSpd = 0,
             moves = { fx("beam", 20, 80) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, spd = 30, baseSpd = 0,
             moves = { fx("stomp", 10, 31, { chance = 100 }) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  probeFlinch(battle, 1)
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  probeFlinch(battle, 2)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  return battle
end)

-- ------------------------------------------------------------------

local out = {}
for _, entry in ipairs(scenarios) do
  local events = {}
  batches = {}
  probes = {}
  local battle = entry.run(events)
  local row = "{"
    .. '"name":' .. encString(entry.name) .. ","
    .. '"events":' .. encList(events, encObject) .. ","
    .. '"batches":' .. encList(batches, encNumber) .. ","
    .. '"outcome":' .. encOutcome(battle:outcome()) .. ","
    .. '"snapshot":' .. encSnapshot(battle)
  if #probes > 0 then row = row .. ',"probes":' .. encList(probes, encObject) end
  out[#out + 1] = row .. "}"
end

io.write("[" .. table.concat(out, ",") .. "]\n")
