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
-- an immunity draws no damage roll either (pokered RandomizeDamage returns on
-- the 0 AdjustDamageForMoveType left, `cp 2` / `ret c` -- before 1.5.0 the
-- roll was an argument evaluated ahead of the call, and was drawn). The
-- snapshot digest carries `rngState`, which is the single number that says
-- both runtimes drew the same count.
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
  -- K11: the Pay Day pile a won fight against the computer reports.
  if out.payDay then
    parts[#parts + 1] = '"payDay":' .. encNumber(out.payDay)
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
--     on it word for word.  DISABLE picks its slot at random (DisableEffect's
--     `BattleRandom & 3`, R1b): seed 4243 picks THUMP HIT.
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
    id = "mn", mode = "1v1", seed = 4243, choiceTimeout = 60, reconnectGrace = 60,
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
--   T5 QA vs COUNTER: QA first.  (Since 1.5.0 COUNTER is HandleCounterMove's:
--   T3 and T5 strike back twice the hit, and in T4 both miss -- a COUNTER
--   never counters a COUNTER; the order is the bracket's all the same.)
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
-- turn-2 byte is below, Ann's first -- 6304 since COUNTER draws only its hit
-- test, 6302 before), then the plain move, then the Counter at Speed 99,
-- last.
scenario("g1_priority_group", function(events)
  local battle = build({
    id = "g1g", mode = "coop_npc", seed = 6304, choiceTimeout = 60, reconnectGrace = 60,
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
-- ...and in a link fight too: both sides are "the player" by the owner's rule
-- (R1b), each console skipping the reset for its own raging monster.
scenario("g1_flinch_rage_link", rageFlinch("g1fl", "1v1"))

-- A Hyper Beam user that a slower Stomp flinches does not recharge:
-- FlinchSideEffect calls ClearHyperBeam on its target (effects.asm :991), so
-- at the next open the beam user is neither recharging nor raging, the reset
-- takes the flinch (probe 1), and it fires again -- to be flinched again
-- (probe 2), turn after turn.  (Gap 4 of
-- docs/plans/gen12-referee-known-gaps.md, closed by R1b; this scenario used
-- to pin the referee's kept recharge.)
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
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  probeFlinch(battle, 2)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  return battle
end)

-- 59-66. The Gen 1 review fixes (task FX1).  tests/battle_sim_turn.lua
--     (section 27) states the numbers behind each one.
--
-- A Leech Seed tick that knocks the seeded monster out.  `_faint` clears
-- `leechSeed`, so the seeder is read before the damage -- and still healed by
-- the whole 1/16 (HandlePoisonBurnLeechSeed drains, heals, and only then looks
-- at the faint).  This used to throw out of the residual.
scenario("g1_leech_ko", function(events)
  local battle = build({
    id = "g1ls", mode = "1v1", seed = 6501, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", hp = 50, maxHp = 100, spd = 90, baseSpd = 0,
             moves = { fx("seed", 0, 84) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", hp = 3, maxHp = 100, spd = 10, baseSpd = 0,
             moves = { fx("splash", 0, 85) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  return battle
end)

-- Rage builds only after an opponent's move lands (HandleBuildingRage's two
-- callers, core.asm :3243 / :5643): the raging monster's own poison, the Leech
-- Seed on it and its confusion self-hits build nothing (probes: ATTACK and
-- its stage stay where they started).
scenario("g1_rage_quiet", function(events)
  local battle = build({
    id = "g1rq", mode = "wild", seed = 6509, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", badges = allBadges(), mons = {
        mn({ species = "Alpha", maxHp = 400, atk = 100, def = 80, spd = 90, spc = 50,
             status = "PSN", confusion = 4, baseSpd = 0, moves = { fx("fury", 20, 81) },
             extra = { raging = true, rageMove = 1, leechSeed = { fromSlot = 3 } } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 400, spd = 10, baseSpd = 0,
             moves = { fx("splash", 0, 85) } }) } } },
    },
  })
  drainInto(battle, events)
  probe(battle, 0)
  for turn = 1, 3 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    drainInto(battle, events)
    probe(battle, turn)
  end
  return battle
end)

-- The hit that knocks the raging monster out builds nothing (`ret z` on the
-- target's HP), so the burned attacker is not halved a second time by the
-- re-penalty (probe 1: Beta's ATTACK is still 100).
scenario("g1_rage_lethal", function(events)
  local battle = build({
    id = "g1rl", mode = "wild", seed = 6503, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", badges = allBadges(), mons = {
        mn({ species = "Alpha", hp = 20, maxHp = 300, atk = 100, def = 80, spd = 90,
             spc = 50, baseSpd = 0, moves = { fx("fury", 20, 81) } }),
        mn({ species = "Gamma", maxHp = 300, baseSpd = 0,
             moves = { fx("splash", 0, 85) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = {
        mn({ species = "Beta", maxHp = 300, atk = 200, spd = 10, status = "BRN",
             baseSpd = 0, moves = { fx("thump", 80, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  probe(battle, 0)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("wild", { action = "fight", move = 0 })
  drainInto(battle, events)
  probe(battle, 1)
  return battle
end)

-- A Substitute that soaks the hit does not stop the build (AttackSubstitute
-- returns to the same caller), and a two-hit move builds once per hit.  The
-- kicks hit for 7 to 9.  A 5-HP doll breaks on the first hit, which ends the
-- move (`.nullifyEffect` zeroed the effect before TwoToFiveAttacksEffect
-- could mark it multi-hit): one hit, one build -- +1, Alpha untouched.  A
-- 12-HP doll (g1_rage_sub_late) soaks the first and breaks on the second:
-- both thrown, both build -- +2.
local function rageSub(id, seed, doll)
  return function(events)
    local battle = build({
      id = id, mode = "1v1", seed = seed, choiceTimeout = 60, reconnectGrace = 60,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 400, spd = 90, baseSpd = 0,
               moves = { fx("fury", 20, 81) },
               extra = { raging = true, rageMove = 1, substitute = doll } }) } } },
        b = { { playerId = "p2", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 400, spd = 10, baseSpd = 0,
               moves = { fx("kicks", 20, 44) } }) } } },
      },
    })
    drainInto(battle, events)
    probe(battle, 0)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
    probe(battle, 1)
    return battle
  end
end
scenario("g1_rage_sub", rageSub("g1rs", 6504, 5))
scenario("g1_rage_sub_late", rageSub("g1rsl", 6504, 12))

-- The two builds no hit carries.  A Disable reaches HandleBuildingRage before
-- its own hit test (power 0: CalculateDamage goes round MoveHitTest), so a
-- raging target builds though the Disable misses (probe 1); an Explosion that
-- misses still runs its effect and then the build (`.notDone`), so the target
-- builds again as the exploder goes down (probe 2).
scenario("g1_rage_misses", function(events)
  local function blind(id, power, effect)
    local out = fx(id, power, effect)
    out.accuracy = 0
    return out
  end
  local battle = build({
    id = "g1rm", mode = "1v1", seed = 6505, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 400, spd = 90, baseSpd = 0,
             moves = { fx("fury", 20, 81) },
             extra = { raging = true, rageMove = 1, lastMoveIndex = 1 } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, spd = 10, baseSpd = 0,
             moves = { blind("numb", 0, 86), blind("boom", 130, 7) } }) } } },
    },
  })
  drainInto(battle, events)
  probe(battle, 0)
  for turn, move in ipairs({ 0, 1 }) do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = move })
    drainInto(battle, events)
    probe(battle, turn)
  end
  return battle
end)

-- A trap's later turns are the trapper's own attack on the cart
-- (`.MultiturnMoveCheck` -> GetPlayerAnimationType), so each tick builds the
-- raging, trapped monster's Rage and the re-penalty finds the trapper -- Delta
-- at slot 4, not Beta standing opposite at slot 3.  Both are burned, so the
-- probes show whose ATTACK is halved again.
scenario("g1_rage_trap", function(events)
  local battle = build({
    id = "g1rt", mode = "coop_pvp", seed = 6506, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 400, spd = 90, baseSpd = 0,
               moves = { fx("fury", 20, 81) },
               extra = { raging = true, rageMove = 1 } }) } },
        { playerId = "a2", name = "Amy", mons = {
          mn({ species = "Gamma", maxHp = 400, spd = 80, baseSpd = 0,
               moves = { fx("splash", 0, 85) } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 400, atk = 200, spd = 20, status = "BRN",
               baseSpd = 0, moves = { fx("splash", 0, 85) } }) } },
        { playerId = "b2", name = "Bea", mons = {
          mn({ species = "Delta", maxHp = 400, atk = 200, spd = 10, status = "BRN",
               baseSpd = 0, moves = { fx("wrap", 5, 42) } }) } },
      },
    },
  })
  drainInto(battle, events)
  probe(battle, 0)
  for turn = 1, 4 do
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
    battle:submitChoice("b2", { action = "fight", move = 0, target = 0 })
    for step = 1, 3 do battle:tick(turn * 10 + step) end
    drainInto(battle, events)
    probe(battle, turn)
  end
  return battle
end)

-- A Bide aimed at field slot 0 is released at slot 0.  Slot 0 is a real seat,
-- and Turn.js once read it as "no aim" (`targetSlot || foe.slot`) and let the
-- spread aim pick: on this seed the release went to slot 1 there and to slot 0
-- here.
scenario("g1_bide_slot0", function(events)
  local battle = build({
    id = "g1bz", mode = "coop_pvp", seed = 3, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 400, spd = 90, baseSpd = 0,
               moves = { fx("tap", 10, 0) } }) } },
        { playerId = "a2", name = "Amy", mons = {
          mn({ species = "Gamma", maxHp = 400, spd = 80, baseSpd = 0,
               moves = { fx("splash", 0, 85) } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 400, spd = 10, baseSpd = 0,
               moves = { fx("bide", 0, 26) } }) } },
        { playerId = "b2", name = "Bea", mons = {
          mn({ species = "Delta", maxHp = 400, spd = 5, baseSpd = 0,
               moves = { fx("splash", 0, 85) } }) } },
      },
    },
  })
  drainInto(battle, events)
  for turn = 1, 4 do
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
    battle:submitChoice("b2", { action = "fight", move = 0, target = 0 })
    for step = 1, 3 do battle:tick(turn * 10 + step) end
    drainInto(battle, events)
  end
  return battle
end)

-- A side-effect drop at -6 says nothing (CantLowerAnymore returns before its
-- text for a side effect); only a primary prints the line -- "Nothing
-- happened!" (R1b: CantLowerAnymore's NothingHappenedText).
scenario("g1_side_min", function(events)
  local battle = build({
    id = "g1sm", mode = "1v1", seed = 6507, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 400, spd = 90, baseSpd = 0,
             moves = { fx("bubble", 10, 70, { chance = 100 }), fx("goo", 0, 20) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, spd = 10, baseSpd = 0,
             moves = { fx("splash", 0, 85) },
             extra = { stages = { atk = 0, def = 0, spd = -6, spc = 0, acc = 0, eva = 0 } } }) } } },
    },
  })
  drainInto(battle, events)
  for _, move in ipairs({ 0, 1 }) do
    battle:submitChoice("p1", { action = "fight", move = move })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- 67-80. Gen 1 side-effect odds (task FX4).  Red's move records carry no
--     chance, so every Red move reaches the referee at chance 0 and the odds
--     are each pokered routine's own constant (Effects.SIDE_THRESHOLD).  A
--     g1_odds_* scenario fights one turn per seed -- a fast Alpha's
--     side-effect move into a slow Beta, chance 0 -- with seeds a scan picked
--     so the routine's byte is exactly threshold - 1 (it lands) and then
--     exactly the threshold (it does not).  `probeSide` pins every battle's
--     draw count (`rng`) and the target's condition.  tests/battle_sim_turn.lua
--     (section 28) forces the same bytes with a scripted generator and counts
--     the draws.

-- After each battle's turn: its RNG state, then every standing seat's
-- condition, confusion, flinch and the two stages a side-effect drop moves.
local function probeSide(battle, at)
  probes[#probes + 1] = { at = at, rng = battle.rng:state() }
  for _, fighter in ipairs(battle.fighters) do
    local mon = fighter.active and fighter.mons[fighter.active]
    if mon and mon.hp > 0 then
      probes[#probes + 1] = {
        at = at, slot = fighter.slot, status = mon.status or "",
        confusion = mon.confusion or 0, flinch = mon.flinch == true,
        sSpd = mon.stages.spd, sSpc = mon.stages.spc,
      }
    end
  end
end

-- One turn per entry, every battle's events into the one stream: Alpha (p1,
-- fast) uses `move`, Beta (p2, slow) splashes.  An entry may swap either move
-- (`aMove` / `bMove`), the speeds, the mode, the ruleset's `typeIds`, and
-- Beta's HP, status, types and raw sheet fields (`bExtra`).
local function sideTurns(id, entries)
  return function(events)
    local battle
    for i, e in ipairs(entries) do
      battle = build({
        id = id .. i, mode = e.mode or "1v1", seed = e.seed, choiceTimeout = 60,
        reconnectGrace = 60, typeIds = e.typeIds,
        sides = {
          a = { { playerId = "p1", name = "Ann", mons = {
            mn({ species = "Alpha", maxHp = 400, spd = e.aSpd or 90, types = { 1 },
                 baseSpd = 0, moves = { e.aMove or e.move } }) } } },
          b = { { playerId = "p2", name = "Bob", mons = {
            mn({ species = "Beta", hp = e.bHp, maxHp = 400, spd = e.bSpd or 10,
                 baseSpd = 0, types = e.bTypes or { 1 }, status = e.bStatus,
                 moves = { e.bMove or fx("splash", 0, 85) }, extra = e.bExtra }) } } },
        },
      })
      drainInto(battle, events)
      battle:submitChoice("p1", { action = "fight", move = 0 })
      battle:submitChoice("p2", { action = "fight", move = 0 })
      drainInto(battle, events)
      probeSide(battle, i)
    end
    return battle
  end
end

local function hit(effect, o)
  o = o or {}
  return fx("hit", 10, effect, { chance = o.chance, type = o.type })
end

-- Each pair: the byte at threshold - 1, then at the threshold.  The scan's
-- seeds put the routine's byte at the same draw (acc, crit, roll, then the
-- side byte), so one seed serves every family whose threshold it straddles.
local function odds(id, effect, below, at)
  return sideTurns(id, { { seed = below, move = hit(effect) },
                         { seed = at, move = hit(effect) } })
end
scenario("g1_odds_poison1", odds("g1op1", 2, 11078, 6227))      -- 51 / 52
scenario("g1_odds_poison2", odds("g1op2", 33, 192, 3))          -- 102 / 103
scenario("g1_odds_twineedle", odds("g1otw", 77, 11078, 6227))   -- 51 / 52
scenario("g1_odds_burn1", odds("g1ob1", 4, 18957, 14106))       -- 25 / 26
scenario("g1_odds_freeze1", odds("g1of1", 5, 18957, 14106))     -- 25 / 26
scenario("g1_odds_paralyze2", odds("g1op2p", 36, 8071, 3220))   -- 76 / 77
scenario("g1_odds_flinch1", odds("g1ofl1", 31, 18957, 14106))   -- 25 / 26
scenario("g1_odds_flinch2", odds("g1ofl2", 37, 8071, 3220))     -- 76 / 77
scenario("g1_odds_drop", odds("g1odr", 71, 28460, 23588))       -- 84 / 85
scenario("g1_odds_confuse", odds("g1ocf", 76, 23829, 18957))    -- 24 / 25

-- The computer's drop (wild Beta, fast, lowers Alpha's Speed): the extra miss
-- byte comes first -- 63 misses and draws nothing more; 64 passes, and the
-- side byte 84 then lands.  g1_odds_drop is the link fight that never draws
-- it.
scenario("g1_odds_computer_drop", sideTurns("g1ocd", {
  { seed = 12021, mode = "wild", aSpd = 10, bSpd = 90,
    aMove = fx("splash", 0, 85), bMove = hit(70) },
  { seed = 9921, mode = "wild", aSpd = 10, bSpd = 90,
    aMove = fx("splash", 0, 85), bMove = hit(70) },
}))

-- Precedence on one seed (the side byte is 50): chance 0 is the cart's 26 and
-- misses; an explicit 20 is floor(20 * 255 / 100) = 51 and lands; 19 is 48
-- and misses.  A chance on an effect with no side routine draws nothing --
-- the last two battles end on the same RNG state.
scenario("g1_side_precedence", sideTurns("g1sp", {
  { seed = 15950, move = hit(4) },
  { seed = 15950, move = hit(4, { chance = 20 }) },
  { seed = 15950, move = hit(4, { chance = 19 }) },
  { seed = 15950, move = hit(0, { chance = 100 }) },
  { seed = 15950, move = hit(0) },
}))

-- What each routine checks before it draws, on one seed whose side byte is 0
-- -- any draw would land -- so a battle that ends on battle 1's RNG state
-- (the plain hit) drew nothing:
--   2 burn vs a poisoned target, 3 burn vs a target of the move's type,
--   4 poison vs a Poison-type target (typeIds names it) -- and 5, the same
--   without typeIds, which draws and poisons; 6-9 burn / flinch / poison /
--   a drop into a Substitute that holds; 10 confusion into the same
--   Substitute draws and confuses the monster behind it; 11 a burn whose hit
--   breaks the Substitute and 12 a Twineedle whose first hit does (the move
--   ends there: no second hit, no poison); 13 a Fire burn move thaws a frozen
--   target, drawing nothing; 14 a drop into Mist lands (Mist stops primaries
--   only); 15 / 16 a knockout with and without a burn effect end alike.
local POISON_AXIS = { "NORMAL", "POISON" }
local FIRE_AXIS = { "NORMAL", "FIRE" }
local SUB = { substitute = 200 }
local DOLL = { substitute = 1 }
scenario("g1_side_gates", sideTurns("g1sg", {
  { seed = 21964, move = hit(0) },
  { seed = 21964, move = hit(4), bStatus = "PSN" },
  { seed = 21964, move = hit(4), bTypes = { 0 } },
  { seed = 21964, move = hit(2), typeIds = POISON_AXIS },
  { seed = 21964, move = hit(2) },
  { seed = 21964, move = hit(4), bExtra = SUB },
  { seed = 21964, move = hit(31), bExtra = SUB },
  { seed = 21964, move = hit(2), bExtra = SUB },
  { seed = 21964, move = hit(71), bExtra = SUB },
  { seed = 21964, move = hit(76), bExtra = SUB },
  { seed = 21964, move = hit(4), bExtra = DOLL },
  { seed = 21964, move = hit(77), bExtra = DOLL },
  { seed = 21964, move = hit(4, { type = 1 }), typeIds = FIRE_AXIS,
    bStatus = "FRZ", bTypes = { 0 } },
  { seed = 21964, move = hit(71), bExtra = { mist = true } },
  { seed = 21964, move = hit(0), bHp = 1 },
  { seed = 21964, move = hit(4), bHp = 1 },
}))

-- Multi-hit moves after a broken Substitute.  The cart marks a move as
-- hitting more than once only after its first hit (TwoToFiveAttacksEffect,
-- from the AlwaysHappenSideEffects lookup at `.notDone`), and a first hit
-- that breaks a Substitute has zeroed the effect first (`.nullifyEffect`): the
-- move ends after that one hit.  A later break leaves the move going, its
-- remaining hits on the monster, the effect still gone.  Power 40 hits for 8
-- to 10, so a 5-HP doll breaks on hit 1 and a 15-HP doll on hit 2.  The
-- two-to-five count is drawn where the cart draws it, after hit 1
-- (TwoToFiveAttacksEffect: `& 3`, and a second `& 3` on a 2 or 3).
--   1-3 two-to-five (29) on seed 29011, whose count bytes are 182 then 151
--   (2, redrawn; 3): five hits.  No doll (five hits on Beta), a 5-HP doll
--   (one hit and no count byte at all, so the RNG state is two bytes short
--   of battle 1's), a 15-HP doll (hits 3-5 on Beta, battle 1's state);
--   4-6 DOUBLE KICK (44): no doll, 5 HP (one hit), 15 HP (both on the doll);
--   7-9 TWINEEDLE (77) on seed 11078, whose side byte is 51 and lands: no
--   doll (poisoned), 5 HP (one hit, no poison), 15 HP (two hits, no poison)
--   -- 8 and 9 end on battle 10's RNG state, a plain hit's: no side byte;
--   10 a plain hit on the same seed;
--   11 two-to-five into a 9-HP doll, a hit for exactly its HP: the doll
--   stands at 0 (AttackSubstitute `sub [hl]` / `ret nc`), so the count is
--   drawn (battle 1's state), hit 2 breaks it and hits 3-5 land on Beta;
--   12 DOUBLE KICK into an 8-HP doll on seed 29007: hit 1 leaves it at 0,
--   hit 2 breaks it.
local function multi(effect) return fx("multi", 40, effect) end
scenario("g1_multi_sub", sideTurns("g1ms", {
  { seed = 29011, move = multi(29) },
  { seed = 29011, move = multi(29), bExtra = { substitute = 5 } },
  { seed = 29011, move = multi(29), bExtra = { substitute = 15 } },
  { seed = 29007, move = multi(44) },
  { seed = 29007, move = multi(44), bExtra = { substitute = 5 } },
  { seed = 29007, move = multi(44), bExtra = { substitute = 15 } },
  { seed = 11078, move = multi(77) },
  { seed = 11078, move = multi(77), bExtra = { substitute = 5 } },
  { seed = 11078, move = multi(77), bExtra = { substitute = 15 } },
  { seed = 11078, move = multi(0) },
  { seed = 29011, move = multi(29), bExtra = { substitute = 9 } },
  { seed = 29007, move = multi(44), bExtra = { substitute = 8 } },
}))

-- ------------------------------------------------------------------
-- R1a (gen12-referee-gaps-fix): the damage tails, AlwaysHappenSideEffects,
-- COUNTER, RAGE / THRASH PP, called multi-turn moves, Leech Seed, Pay Day
-- and the self-hit -- each against pokered, one battle per case.
-- ------------------------------------------------------------------

-- After each turn of a `duels` battle: the RNG state, wDamage (`lastDamage`)
-- and the Pay Day pile, then every seat's monster -- standing or not -- with
-- the volatiles these rows move.  `pp` is the slots' PP, comma-joined.
local function probeDuel(battle, at, turn)
  probes[#probes + 1] = { at = at, turn = turn, rng = battle.rng:state(),
                          last = battle.lastDamage, payA = battle.payDay.a,
                          payB = battle.payDay.b }
  for _, fighter in ipairs(battle.fighters) do
    for index, mon in ipairs(fighter.mons) do
      local pp = {}
      for i = 1, #mon.moves do pp[i] = tostring(mon.moves[i].pp) end
      probes[#probes + 1] = {
        at = at, turn = turn, slot = fighter.slot, mon = index, hp = mon.hp,
        sub = mon.substitute or 0, zero = mon.subAtZero == true,
        raging = mon.raging == true, recharge = mon.mustRecharge == true,
        charging = mon.charging ~= nil, invuln = mon.invulnerable == true,
        thrash = mon.thrashing ~= nil, bide = mon.bide ~= nil,
        conf = mon.confusion or 0, tox = mon.toxicCounter or 0,
        sAtk = mon.stages.atk, pp = table.concat(pp, ","),
      }
    end
  end
end

-- One battle per entry, every battle's events into the one stream: Ann's
-- Alpha (p1) against Bob's Beta (p2), each a raw `mn` sheet (`a` / `b`), on
-- the entry's seed, mode, chart, typeIds and METRONOME pool.  `turns` lists
-- each turn's two move slots (0-based), one game turn apiece: a seat whose
-- turn is forced refuses its submission, Bob is not asked once Ann's choice
-- has resolved the turn (it would land in the next one), and a turn with
-- every seat forced resolves on the clock.
-- `probeDuel` after each turn, and a closing row with the battle's outcome
-- (its `payDay` -- K11 -- included) when it ended.
local function duels(id, entries)
  return function(events)
    local battle
    for i, e in ipairs(entries) do
      battle = build({
        id = id .. i, mode = e.mode or "1v1", seed = e.seed, choiceTimeout = 60,
        reconnectGrace = 60, typeIds = e.typeIds, chart = e.chart,
        metronomePool = e.pool,
        sides = {
          a = { { playerId = "p1", name = "Ann", mons = { mn(e.a) } } },
          b = { { playerId = "p2", name = "Bob", mons = { mn(e.b) } } },
        },
      })
      drainInto(battle, events)
      for t, pair in ipairs(e.turns or { { 0, 0 } }) do
        if battle:outcome() then break end
        local turnNo = battle.turn
        battle:submitChoice("p1", { action = "fight", move = pair[1] })
        if battle.turn == turnNo then
          battle:submitChoice("p2", { action = "fight", move = pair[2] })
        end
        if battle.forcedPending then battle:tick(battle.now) end
        drainInto(battle, events)
        probeDuel(battle, i, t)
      end
      local o = battle:outcome()
      if o then
        probes[#probes + 1] = { at = i, outcome = o.outcome, reason = o.reason,
                                winner = o.winners and o.winners[1] or "",
                                payDay = o.payDay or 0 }
      end
    end
    return battle
  end
end

local SPLASH = fx("splash", 0, 85)
-- A fast attacker and a slow target, 400 HP each, base Speed 0 (no crit).
local function fast(moves, extra, o)
  o = o or {}
  return { species = "Alpha", maxHp = 400, hp = o.hp, level = o.level, atk = o.atk,
           spd = 90, baseSpd = 0, types = o.types or { 1 }, moves = moves,
           status = o.status, confusion = o.confusion, toxicCounter = o.toxicCounter,
           extra = extra }
end
local function slow(moves, extra, o)
  o = o or {}
  return { species = "Beta", maxHp = o.maxHp or 400, hp = o.hp, def = o.def,
           spd = 10, baseSpd = 0, types = o.types or { 1 }, moves = moves or { SPLASH },
           status = o.status, confusion = o.confusion, toxicCounter = o.toxicCounter,
           extra = extra }
end

-- The damage tails (core.asm :5075-5185 AdjustDamageForMoveType, :5420-5455
-- RandomizeDamage), on one seed: a level-2, Attack-5 hit into Defense 200 is
-- a base 2.  1 its type step halves to 1 (0.5x): it lands for 1 and draws no
-- roll; 2 halved twice (0.5x against each of Beta's two types) it reaches 0 -- "missed", no roll; 3 neutral,
-- it rolls; 4 an immunity draws no roll either ("doesn't affect").  1, 2 and
-- 4 end on one RNG state (acc + crit, then Beta's acc); 3 is a byte past it.
-- 5 a doll of exactly the hit's HP takes it and stands at 0 (`ret nc`); the
-- second turn's hit breaks it.
local TAIL_CHART = { { 100, 100, 100 }, { 100, 50, 100 }, { 100, 50, 50 }, { 100, 0, 100 } }
local TAIL_TYPES = { 1, 2 }
local function tail(ty) return fx("tap", 10, 0, { type = ty }) end
local function weak(moves, extra) return { species = "Alpha", maxHp = 400, level = 2,
  atk = 5, spd = 90, baseSpd = 0, types = { 0 }, moves = moves, extra = extra } end
scenario("g1_damage_tails", duels("g1dt", {
  { seed = 7101, chart = TAIL_CHART, a = weak({ tail(1) }), b = slow(nil, nil, { def = 200, types = TAIL_TYPES }) },
  { seed = 7101, chart = TAIL_CHART, a = weak({ tail(2) }), b = slow(nil, nil, { def = 200, types = TAIL_TYPES }) },
  { seed = 7101, chart = TAIL_CHART, a = weak({ tail(0) }), b = slow(nil, nil, { def = 200, types = TAIL_TYPES }) },
  { seed = 7101, chart = TAIL_CHART, a = weak({ tail(3) }), b = slow(nil, nil, { def = 200, types = TAIL_TYPES }) },
  { seed = 7101, a = fast({ fx("thump", 40, 0) }), b = slow(nil, { substitute = 9 }),
    turns = { { 0, 0 }, { 0, 0 } } },
}))

-- AlwaysHappenSideEffects (data/battle/always_happen_effects.asm) run at
-- `.notDone` after the hit, before HandleBuildingRage -- unless the hit broke a
-- Substitute, whose `.nullifyEffect` zeroed the effect first.  Alpha (fast,
-- 300 of 400 HP) into Beta behind a 200-HP doll that holds (H) or a 1-HP doll
-- the hit breaks (B), one turn each unless noted:
--   1 H drain (3): Alpha heals half the whole hit (wDamage is the whole hit
--     against a doll); 2 B drain: no heal;
--   3 H recoil (48): a quarter of the whole hit; 4 B recoil: none;
--   5 H STRUGGLE (every slot at 0 PP): HALF the whole hit (RecoilEffect_'s
--     `cp STRUGGLE`); 6 B STRUGGLE: none;
--   7 H HYPER BEAM (80), two turns: Alpha must recharge; 8 B: no recharge,
--     Alpha fires again;
--   9 H EXPLOSION (7): Alpha faints; 10 B EXPLOSION: Alpha lives;
--   11 H RAGE (81): raging; 12 B RAGE: never starts raging;
--   13 Beta raging, no doll, Alpha drains: the drain comes before Beta's RAGE
--     lines (drain is AlwaysHappen, the build after it);
--   14 Alpha behind its own 30-HP doll, recoil into an H doll: the recoil
--     comes off Alpha's HP, never its doll (RecoilEffect_ writes the HP);
--   15 the same with EXPLOSION: Alpha faints, its doll does not soak it.
local HOLD, BREAK = { substitute = 200 }, { substitute = 1 }
local function hurt(moves, extra) return fast(moves, extra, { hp = 300 }) end
local ZERO_PP = { fx("thump", 40, 0, { pp = 0 }) }
scenario("g1_always_happen", duels("g1ah", {
  { seed = 7201, a = hurt({ fx("leech", 40, 3) }), b = slow(nil, HOLD) },
  { seed = 7201, a = hurt({ fx("leech", 40, 3) }), b = slow(nil, BREAK) },
  { seed = 7201, a = hurt({ fx("ram", 40, 48) }), b = slow(nil, HOLD) },
  { seed = 7201, a = hurt({ fx("ram", 40, 48) }), b = slow(nil, BREAK) },
  { seed = 7201, a = hurt(ZERO_PP), b = slow(nil, HOLD) },
  { seed = 7201, a = hurt(ZERO_PP), b = slow(nil, BREAK) },
  { seed = 7201, a = hurt({ fx("beam", 60, 80) }), b = slow(nil, HOLD), turns = { { 0, 0 }, { 0, 0 } } },
  { seed = 7201, a = hurt({ fx("beam", 60, 80) }), b = slow(nil, BREAK), turns = { { 0, 0 }, { 0, 0 } } },
  { seed = 7201, a = hurt({ fx("blast", 60, 7) }), b = slow(nil, HOLD) },
  { seed = 7201, a = hurt({ fx("blast", 60, 7) }), b = slow(nil, BREAK) },
  { seed = 7201, a = hurt({ fx("RAGE", 20, 81) }), b = slow(nil, HOLD) },
  { seed = 7201, a = hurt({ fx("RAGE", 20, 81) }), b = slow(nil, BREAK) },
  { seed = 7201, a = hurt({ fx("leech", 40, 3) }),
    b = slow({ fx("RAGE", 20, 81) }, { raging = true, rageMove = 1 }) },
  { seed = 7201, a = hurt({ fx("ram", 40, 48) }, { substitute = 30 }), b = slow(nil, HOLD) },
  { seed = 7201, a = hurt({ fx("blast", 60, 7) }, { substitute = 30 }), b = slow(nil, HOLD) },
}))

-- Pay Day (PayDayEffect_: level x 2, `add a`, per landed use, either side's
-- turn, into wTotalPayDayMoney; EndOfBattle pays the pile on a won fight
-- outside a link battle).  Alpha (L20, 80 power) and Beta (10 power) both
-- use PAY DAY; Beta (40 HP) falls on Alpha's third hit:
--   1 wild: Alpha 3 x 40 + Beta 2 x 40 -- the computer's coins are in the
--     pile too -- so the outcome's payDay is 200;
--   2 1v1: the same fight, a link battle -- no payDay;
--   3 wild, Alpha's first hit breaks a doll -- no coins for it (the effect
--     was zeroed); the rest still count: 3 x 40 + 3 x 40 = 240;
--   4 wild, Alpha at level 140: 280 wraps the 8-bit `add a` to 24 a use;
--   5 wild, Beta wins (Alpha 40 HP, Beta's hits heavy): side b's win pays
--     nothing.
local function payer(o) return { species = "Alpha", maxHp = 400, hp = o.hp, level = o.level,
  spd = 90, baseSpd = 0, types = { 1 }, moves = { fx("coin", 80, 16) } } end
local function payee(o) return { species = "Beta", maxHp = 400, hp = o.hp or 40, atk = o.atk,
  spd = 10, baseSpd = 0, types = { 1 }, moves = { fx("coin", o.power or 10, 16) }, extra = o.extra } end
local TWO = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }
scenario("g1_pay_day", duels("g1pd", {
  { seed = 7401, mode = "wild", a = payer({}), b = payee({}), turns = TWO },
  { seed = 7401, mode = "1v1", a = payer({}), b = payee({}), turns = TWO },
  { seed = 7401, mode = "wild", a = payer({}), b = payee({ extra = { substitute = 1 } }), turns = TWO },
  { seed = 7401, mode = "wild", a = payer({ level = 140 }), b = payee({}), turns = TWO },
  { seed = 7401, mode = "wild", a = payer({ hp = 40 }), b = payee({ hp = 400, atk = 250, power = 120 }),
    turns = TWO },
}))

-- COUNTER (HandleCounterMove, core.asm :4547-4610): Ann's slow Alpha counters
-- Bob's fast Beta.  wDamage is the last damage dealt; the target's selected
-- move must be Normal or Fighting with power, and not COUNTER:
--   1 Beta's Normal thump lands: Alpha deals twice that hit, untyped, unrolled;
--   2 a Fire (type 2) hit: COUNTER misses, drawing no hit test;
--   3 Beta counters too: both miss;
--   4 Beta's thump misses (accuracy 0): wDamage 0, COUNTER misses;
--   5 Beta's thump into Alpha's 200-HP doll: wDamage is the whole hit, doubled;
--   6 Beta is a Ghost to Fighting (chart 0): COUNTER hits it anyway;
--   7 two turns: a thump (countered), then a 0-power Normal move -- the stale
--     wDamage is there, the power is not: a miss;
--   8 a Fighting (type 1) hit: countered;
--   9 typeIds puts NORMAL at index 3: Beta's type-0 thump is not Normal, a miss.
local CTR = fx("COUNTER", 1, 0, { type = 1 })
local function counterer(extra) return { species = "Alpha", maxHp = 400, spd = 10, baseSpd = 0,
  types = { 1 }, moves = { CTR }, extra = extra } end
local function striker(moves, types) return { species = "Beta", maxHp = 400, spd = 90, baseSpd = 0,
  types = types or { 1 }, moves = moves } end
local THUMP = fx("thump", 40, 0)
local GHOST_CHART = { { 100, 100, 100 }, { 100, 100, 0 }, { 100, 100, 100 } }
local function missing() local m = fx("thump", 40, 0); m.accuracy = 0; return m end
scenario("g1_counter", duels("g1ct", {
  { seed = 7501, a = counterer(), b = striker({ THUMP }) },
  { seed = 7501, a = counterer(), b = striker({ fx("flame", 40, 0, { type = 2 }) }) },
  { seed = 7501, a = counterer(), b = striker({ CTR }) },
  { seed = 7501, a = counterer(), b = striker({ missing() }) },
  { seed = 7501, a = counterer({ substitute = 200 }), b = striker({ THUMP }) },
  { seed = 7501, chart = GHOST_CHART, a = counterer(), b = striker({ THUMP }, { 2 }) },
  { seed = 7501, a = counterer(), b = striker({ THUMP, fx("growl", 0, 18) }),
    turns = { { 0, 0 }, { 0, 1 } } },
  { seed = 7501, a = counterer(), b = striker({ fx("chop", 40, 0, { type = 1 }) }) },
  { seed = 7501, typeIds = { "FIRE", "FIGHTING", "WATER", "NORMAL" }, a = counterer(),
    b = striker({ THUMP }) },
}))

-- RAGE and THRASH spend PP on their first turn only: DecrementPP returns while
-- USING_RAGE / THRASHING_ABOUT is set, and the thrash's continuation skips it
-- outright (`.ThrashingAboutCheck`).  The forced turns open no menu, so a RAGE
-- at 0 PP stays RAGE -- never STRUGGLE.  HandleBuildingRage says "<MON>'s
-- RAGE is building!" at each build, then the stat line; nothing at +6.
--   1 RAGE at 1 PP, three turns, Beta thumping it: 1 -> 0 on turn 1, RAGE
--     (not STRUGGLE) on turns 2 and 3, a building line per hit taken;
--   2 THRASH at 1 PP: 1 -> 0 on turn 1 and no more, confused at its end;
--   3 a raging Alpha at +6 Attack: built on, silent.
scenario("g1_rage_thrash_pp", duels("g1rp", {
  { seed = 7601, a = fast({ fx("RAGE", 20, 81, { pp = 1 }) }), b = slow({ fx("thump", 10, 0) }),
    turns = { { 0, 0 }, { 0, 0 }, { 0, 0 } } },
  { seed = 7601, a = fast({ fx("THRASH", 30, 27, { pp = 1 }) }), b = slow(),
    turns = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } } },
  { seed = 7601, a = fast({ fx("RAGE", 20, 81) }, { raging = true, rageMove = 1, stages = { atk = 6 } }),
    b = slow({ fx("thump", 10, 0) }) },
}))

-- A multi-turn move METRONOME or MIRROR MOVE called keeps the called move in
-- its record (MetronomePickMove / MirrorMoveCopyMove wrote it into
-- wPlayerSelectedMove), so the forced turns replay it rather than the calling
-- slot.  Each METRONOME pool holds the one move, so the pick is certain:
--   1 FLY: up on turn 1, lands FLY on turn 2; METRONOME's PP spent once;
--   2 DIG (CHARGE + the id): the same;
--   3 THRASH: replayed, no PP, confused at its end;
--   4 RAGE: replayed as RAGE on turns 2 and 3;
--   5 BIDE: stores, then unleashes as BIDE;
--   6 MIRROR MOVE: Beta (fast) flies up and Alpha's MIRROR MOVE fails (no
--     move used yet); turn 2 Beta's FLY lands and Alpha mirrors it, going up;
--     turn 3 Beta splashes and Alpha's forced FLY lands -- FLY, not MIRROR
--     MOVE again, and no PP.
local function metro() return fx("METRONOME", 0, 83) end
local FOUR = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }
local function poolOf(m) return { m } end
scenario("g1_called_multiturn", duels("g1cm", {
  { seed = 7701, pool = poolOf(fx("FLY", 90, 43)), a = fast({ metro() }), b = slow(), turns = FOUR },
  { seed = 7701, pool = poolOf(fx("DIG", 100, 39)), a = fast({ metro() }), b = slow(), turns = FOUR },
  { seed = 7701, pool = poolOf(fx("THRASH", 30, 27)), a = fast({ metro() }), b = slow(), turns = FOUR },
  { seed = 7701, pool = poolOf(fx("RAGE", 20, 81)), a = fast({ metro() }),
    b = slow({ fx("thump", 10, 0) }), turns = FOUR },
  { seed = 7701, pool = poolOf(fx("BIDE", 0, 26)), a = fast({ metro() }),
    b = slow({ fx("thump", 10, 0) }), turns = FOUR },
  { seed = 7701, a = { species = "Alpha", maxHp = 400, spd = 10, baseSpd = 0, types = { 1 },
      moves = { fx("MIRROR_MOVE", 0, 9) } },
    b = { species = "Beta", maxHp = 400, spd = 90, baseSpd = 0, types = { 1 },
      moves = { fx("FLY", 90, 43), SPLASH } }, turns = { { 0, 0 }, { 0, 0 }, { 0, 1 } } },
}))

-- LEECH SEED (HandlePoisonBurnLeechSeed, core.asm :470-548): the poison /
-- burn tick, then the seed tick, then -- only then -- the faint check.  The
-- seed's sixteenth is multiplied by the toxic counter, incremented again, and
-- the seeder gets the whole amount.  Beta (400 max HP, so 25 a sixteenth) is
-- seeded by Alpha (300 of 400 HP), which splashes:
--   1 badly poisoned, two turns: poison x1 then seed x2 (Alpha +50); poison x3
--     then seed x4 (Alpha +100);
--   2 poisoned at 20 HP: the poison knocks it out, and Alpha is still fed 25;
--   3 burned at 20 HP: the same;
--   4 behind a 50-HP doll, poisoned: both ticks come off Beta's HP, never the
--     doll.
local SEEDED = { leechSeed = { fromSlot = 0 } }
local function seeder() return fast({ SPLASH }, nil, { hp = 300 }) end
scenario("g1_leech_toxic", duels("g1lt", {
  { seed = 7801, a = seeder(), b = slow(nil, SEEDED, { status = "TOX", toxicCounter = 1 }),
    turns = { { 0, 0 }, { 0, 0 } } },
  { seed = 7801, a = seeder(), b = slow(nil, SEEDED, { status = "PSN", hp = 20 }) },
  { seed = 7801, a = seeder(), b = slow(nil, SEEDED, { status = "BRN", hp = 20 }) },
  { seed = 7801, a = seeder(), b = slow(nil, { leechSeed = { fromSlot = 0 }, substitute = 50 },
    { status = "PSN" }) },
}))

-- The confusion self-hit (seed 7304: Alpha's confusion byte is 22, a hit).  It
-- is 10 here (level 20, 40 / 40, the fixed max roll).  HandleSelfConfusionDamage
-- ends on ApplyDamageToPlayerPokemon, whose doll branch takes the OTHER side's
-- doll (AttackSubstitute picks it by hWhoseTurn), and `.IsConfused` clears
-- every other wPlayerBattleStatus1 bit first:
--   1 Alpha behind a 30-HP doll, Beta behind a 10-HP doll: Beta's doll takes
--     the 10 and stands at 0; Alpha and its doll untouched;
--   2 Beta's doll at 5: it breaks;
--   3 no doll across: nothing moves at all;
--   4 Alpha with no doll: Alpha takes the 10;
--   5 Alpha charging FLY, vanished: the self-hit drops the charge and the
--     vanish -- turn 2 is Alpha's own choice, not a forced release;
--   6 Alpha thrashing: the thrash is gone, and with it the confusion at its end;
--   7 Alpha about to unleash a Bide: the Bide is gone, nothing unleashed.
local function dizzy(extra, moves) return fast(moves or { SPLASH }, extra, { confusion = 4 }) end
scenario("g1_self_hit", duels("g1sh", {
  { seed = 7304, a = dizzy({ substitute = 30 }), b = slow(nil, { substitute = 10 }) },
  { seed = 7304, a = dizzy({ substitute = 30 }), b = slow(nil, { substitute = 5 }) },
  { seed = 7304, a = dizzy({ substitute = 30 }), b = slow() },
  { seed = 7304, a = dizzy(nil), b = slow(nil, { substitute = 10 }) },
  { seed = 7304, a = dizzy({ charging = { moveIndex = 1, effect = 43, targetSlot = 3, moveId = "FLY" },
      invulnerable = true }, { fx("FLY", 90, 43) }), b = slow(), turns = { { 0, 0 }, { 0, 0 } } },
  { seed = 7304, a = dizzy({ thrashing = { turns = 1, moveIndex = 1 } }, { fx("THRASH", 30, 27) }),
    b = slow(), turns = { { 0, 0 }, { 0, 0 } } },
  { seed = 7304, a = dizzy({ bide = { turns = 0, stored = 30, moveIndex = 1, targetSlot = 3 } },
      { fx("BIDE", 0, 26) }), b = slow(), turns = { { 0, 0 }, { 0, 0 } } },
}))

-- ------------------------------------------------------------------
-- R1b (gen12-referee-gaps-fix wave 2): Transform, Haze, the computer's
-- stat-drop miss and turn slot, ClearHyperBeam, DISABLE, PoisonEffect,
-- the gate order, Bide, the trap's start, MIRROR MOVE, the set-damage
-- moves, Pay Day on an escape and the K9 level-up -- each against pokered,
-- one battle per entry.  Every sheet is written out whole (the Node twin
-- carries the same literals).
-- ------------------------------------------------------------------

-- After each row of a `fights` battle: the RNG state and wDamage, then every
-- monster of every seat with the state these rows move.
local function probeR1b(battle, at, turn)
  probes[#probes + 1] = { at = at, turn = turn, rng = battle.rng:state(),
                          last = battle.lastDamage }
  for _, fighter in ipairs(battle.fighters) do
    for index, mon in ipairs(fighter.mons) do
      local moves, types = {}, {}
      for i = 1, #mon.moves do moves[i] = mon.moves[i].id .. ":" .. mon.moves[i].pp end
      for i = 1, #mon.types do types[i] = tostring(mon.types[i]) end
      local st = mon.stages
      probes[#probes + 1] = {
        at = at, turn = turn, slot = fighter.slot, mon = index,
        hp = mon.hp, maxHp = mon.maxHp, level = mon.level,
        status = mon.status or "", tox = mon.toxicCounter or 0,
        linger = mon.toxicLinger == true, conf = mon.confusion or 0,
        moves = table.concat(moves, ","), types = table.concat(types, ","),
        transformed = mon.transformed == true, recharge = mon.mustRecharge == true,
        invuln = mon.invulnerable == true, charging = mon.charging ~= nil,
        disable = mon.disable and (mon.disable.moveIndex .. "/" .. mon.disable.turns) or "",
        used = mon.lastUsedMove and mon.lastUsedMove.id or "",
        cur = mon.cur.atk .. "/" .. mon.cur.def .. "/" .. mon.cur.spd .. "/" .. mon.cur.spc,
        party = mon.partyStats.atk .. "/" .. mon.partyStats.def .. "/"
          .. mon.partyStats.spd .. "/" .. mon.partyStats.spc,
        stages = st.atk .. "/" .. st.def .. "/" .. st.spd .. "/" .. st.spc .. "/"
          .. st.acc .. "/" .. st.eva,
        flags = (mon.mist and "m" or "") .. (mon.xAccuracy and "x" or "")
          .. (mon.focusEnergy and "f" or "") .. (mon.leechSeed and "s" or "")
          .. (mon.reflect and "r" or "") .. (mon.lightScreen and "l" or ""),
        sub = mon.substitute or 0,
        trapped = mon.trapped and (mon.trapped.turns .. "/" .. mon.trapped.damage) or "",
        trapping = mon.trapping and tostring(mon.trapping.turns) or "",
        thrash = mon.thrashing and mon.thrashing.turns or -1,
        bide = mon.bide and (mon.bide.turns .. "/" .. mon.bide.stored) or "",
      }
    end
  end
end

-- One battle per entry, every battle's events into the one stream.  An
-- entry names its seats ({ pid, side, mons, bag, badges }, field order) and
-- its rows: each row maps a pid to a choice (a number is a FIGHT slot) and
-- may carry `lv`, a K9 level-up ({ pid, monIndex, level, stats, maxHp })
-- the referee is handed before the row's choices.  A seat's choice is filed
-- only while the turn it was written for is still open; a row with every
-- seat forced resolves on the clock.  `probeR1b` after each row, and the
-- outcome (Pay Day included) at the end.
local function fights(id, entries)
  return function(events)
    local battle
    for i, e in ipairs(entries) do
      local sides = { a = {}, b = {} }
      for _, seat in ipairs(e.seats) do
        local list = sides[seat.side]
        list[#list + 1] = { playerId = seat.pid, name = seat.pid, mons = seat.mons,
                            bag = seat.bag, badges = seat.badges }
      end
      battle = build({
        id = id .. i, mode = e.mode or "1v1", seed = e.seed, choiceTimeout = 60,
        reconnectGrace = 60, typeIds = e.typeIds, chart = e.chart,
        metronomePool = e.pool, sides = sides,
      })
      drainInto(battle, events)
      for t, row in ipairs(e.turns) do
        if battle:outcome() then break end
        if row.lv then
          local lv = row.lv
          probes[#probes + 1] = { at = i, turn = t,
            levelUp = battle:levelUp(lv[1], lv[2], lv[3], lv[4], lv[5]) }
          drainInto(battle, events)
        end
        local turnNo, phase = battle.turn, battle.phase
        for _, seat in ipairs(e.seats) do
          local c = row[seat.pid]
          if c ~= nil and battle.turn == turnNo and battle.phase == phase then
            if type(c) == "number" then c = { action = "fight", move = c } end
            battle:submitChoice(seat.pid, c)
          end
        end
        if battle.forcedPending then battle:tick(battle.now) end
        drainInto(battle, events)
        probeR1b(battle, i, t)
      end
      local o = battle:outcome()
      if o then
        probes[#probes + 1] = { at = i, outcome = o.outcome, reason = o.reason,
                                winner = o.winners and o.winners[1] or "",
                                payDay = o.payDay or 0 }
      end
    end
    return battle
  end
end

-- A move: 60 PP and accuracy 255 unless `o` says otherwise (`o.ppUps` is
-- contract K8's).
local function r1m(id, power, effect, o)
  o = o or {}
  local m = { id = id, pp = o.pp or 60, power = power, accuracy = o.accuracy or 255,
              type = o.type or 0, effect = effect, chance = o.chance or 0 }
  if o.highCrit then m.highCrit = true end
  if o.ppUps then m.ppUps = o.ppUps end
  return m
end

-- A sheet: level 20, 400 HP, 40 across, type 1 and base Speed 0 (no crits)
-- unless `o` says otherwise; every other key of `o` is a raw sheet field
-- (status, stages, K7's base / dvs, a Substitute, ...).
local R1S_SHORT = { level = true, maxHp = true, hp = true, atk = true, def = true,
                    spd = true, spc = true, types = true, baseSpd = true }
local function r1s(species, moves, o)
  o = o or {}
  local out = { species = species, level = o.level or 20, hp = o.hp, maxHp = o.maxHp or 400,
                stats = { atk = o.atk or 40, def = o.def or 40, spd = o.spd or 40,
                          spc = o.spc or 40 },
                types = o.types or { 1 }, baseSpd = o.baseSpd or 0, moves = moves }
  for key, value in pairs(o) do
    if not R1S_SHORT[key] then out[key] = value end
  end
  return out
end

-- The 1v1 shape of a `fights` entry: Ann (p1) on side a, Bob (p2) on side b,
-- `o.aSeat` / `o.bSeat` their bag and badges, the rest of `o` the entry's.
local function r1duo(a, b, o)
  local aSeat, bSeat = o.aSeat or {}, o.bSeat or {}
  local e = { seats = {
    { pid = "p1", side = "a", mons = a, bag = aSeat.bag, badges = aSeat.badges },
    { pid = "p2", side = "b", mons = b, bag = bSeat.bag, badges = bSeat.badges },
  } }
  for key, value in pairs(o) do
    if key ~= "aSeat" and key ~= "bSeat" then e[key] = value end
  end
  return e
end

-- TRANSFORM (transform.asm) and the switch-out that undoes it:
--   1 1v1: Alpha transforms into Beta -- Beta's moves at 5 PP each
--     (`.copyPPLoop`), Beta's types -- then switches out and back in: its
--     own moves (the PP it had), its own types (LoadBattleMonFromParty);
--   2 wild: the wild Beta transforms into Alpha and takes Alpha's K7 base
--     stats, DVs and base Speed with the species byte; Alpha's crits on it
--     read GetEnemyMonStat -- a CalcStat over Alpha's base Defense and DVs at
--     Beta's level 30, no stat exp -- and Beta's own crits Alpha's base Speed;
--   3 the same without K7: the party stats, as before.
scenario("g1_transform_restore", fights("g1tf", {
  r1duo(
    {
      r1s("Alpha", { r1m("morph", 0, 57), r1m("tap", 10, 0) }, { spd = 90, types = { 1 } }),
      r1s("Gamma", { r1m("splash", 0, 85) }, { spd = 90 }),
    },
    {
      r1s("Beta", { r1m("thump", 10, 0, { pp = 12 }), r1m("chop", 10, 0, { pp = 3 }) },
        { spd = 10, types = { 2 } }),
    },
    {
      seed = 8101,
      turns = {
        { p1 = 0, p2 = 0 },
        { p1 = { action = "switch", slot = 1 }, p2 = 0 },
        { p1 = { action = "switch", slot = 0 }, p2 = 0 },
        { p1 = 1, p2 = 0 },
      },
    }),
  r1duo(
    {
      r1s("Alpha", { r1m("slash", 70, 0, { highCrit = true }) },
        {
          spd = 90,
          baseSpd = 255,
          base = { hp = 60, atk = 80, def = 70, spd = 120, spc = 90 },
          dvs = { atk = 12, def = 9, spd = 15, spc = 6 },
        }),
    },
    {
      r1s("Beta", { r1m("morph", 0, 57) },
        {
          level = 30,
          spd = 10,
          base = { hp = 48, atk = 48, def = 48, spd = 48, spc = 48 },
          dvs = { atk = 3, def = 4, spd = 5, spc = 6 },
        }),
    },
    {
      mode = "wild",
      seed = 8102,
      turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } },
    }),
  r1duo(
    { r1s("Alpha", { r1m("slash", 70, 0, { highCrit = true }) }, { spd = 90, baseSpd = 255 }) },
    { r1s("Beta", { r1m("morph", 0, 57) }, { level = 30, spd = 10 }) },
    {
      mode = "wild",
      seed = 8102,
      turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } },
    }),
}))

-- HazeEffect_ (move_effects/haze.asm): every stage and battle stat reset,
-- confusion, X Accuracy, Mist, Focus Energy, Leech Seed, Bad Poison, Reflect,
-- Light Screen and Disable gone on both battlers, and the TARGET's status
-- cured -- a sleeping or frozen target loses the move it has not used yet
-- (CANNOT_MOVE in its selected move):
--   1 1v1: Alpha (badly poisoned, staged, behind Reflect) hazes a sleeping,
--     confused, Misted, pumped, seeded, disabled Beta: Alpha is left plainly
--     poisoned, Beta wakes and does not move;
--   2 1v1: a frozen Beta is thawed and loses its move;
--   3 coop_pvp: all four battlers -- Gamma's confusion and stages, Delta's
--     Bad Poison and seed -- and only Beta, the target, is cured.
scenario("g1_haze_full", fights("g1hz", {
  r1duo(
    {
      r1s("Alpha", { r1m("haze", 0, 25) },
        {
          spd = 90,
          status = "TOX",
          toxicCounter = 3,
          stages = { atk = 2, def = -1, spd = 0, spc = 0, acc = 1, eva = 0 },
          reflect = true,
          focusEnergy = true,
        }),
    },
    {
      r1s("Beta", { r1m("thump", 10, 0) },
        {
          spd = 10,
          status = "SLP",
          statusTurns = 5,
          confusion = 4,
          mist = true,
          focusEnergy = true,
          xAccuracy = true,
          leechSeed = { fromSlot = 0 },
          disable = { moveIndex = 1, turns = 4 },
          stages = { atk = -2, def = 3, spd = 0, spc = 0, acc = 0, eva = 2 },
        }),
    },
    { seed = 8201, turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("haze", 0, 25) }, { spd = 90 }) },
    { r1s("Beta", { r1m("thump", 10, 0) }, { spd = 10, status = "FRZ" }) },
    { seed = 8202, turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } } }),
  {
    mode = "coop_pvp",
    seed = 8203,
    seats = {
      { pid = "a1", side = "a", mons = { r1s("Alpha", { r1m("haze", 0, 25) }, { spd = 90 }) } },
      {
        pid = "a2",
        side = "a",
        mons = {
          r1s("Gamma", { r1m("splash", 0, 85) },
            {
              spd = 80,
              confusion = 3,
              stages = { atk = 0, def = 0, spd = 4, spc = 0, acc = 0, eva = 0 },
            }),
        },
      },
      {
        pid = "b1",
        side = "b",
        mons = { r1s("Beta", { r1m("thump", 10, 0) }, { spd = 10, status = "PAR", mist = true }) },
      },
      {
        pid = "b2",
        side = "b",
        mons = {
          r1s("Delta", { r1m("splash", 0, 85) },
            {
              spd = 5,
              status = "TOX",
              toxicCounter = 2,
              leechSeed = { fromSlot = 0 },
              stages = { atk = -3, def = 0, spd = 0, spc = 0, acc = 0, eva = 0 },
            }),
        },
      },
    },
    turns = {
      {
        a1 = { action = "fight", move = 0, target = 3 },
        a2 = { action = "fight", move = 0, target = 3 },
        b1 = { action = "fight", move = 0, target = 0 },
        b2 = { action = "fight", move = 0, target = 0 },
      },
    },
  },
}))

-- StatModifierDownEffect's primary branch (effects.asm :539-716), in its
-- order: the computer's extra 25% miss byte (outside a link battle), a
-- Substitute, then MoveHitTest -- Mist before its accuracy byte, X Accuracy
-- with none -- each "But it failed!", and a stage at -6 "Nothing happened!":
--   1 wild: the wild Beta growls four times (the miss byte every turn);
--   2 1v1: the same growls, no miss byte;
--   3 wild: into Alpha's Mist -- no accuracy byte;
--   4 1v1: Alpha growls at Beta's doll -- no accuracy byte;
--   5 1v1: Alpha at -6 Attack; Alpha (X Accuracy) growls with no byte;
--   6 1v1: a SWORDS DANCE at +6 says "Nothing happened!", and draws nothing.
scenario("g1_stat_drop_primary", fights("g1sd", {
  r1duo(
    { r1s("Alpha", { r1m("splash", 0, 85) }, { spd = 10 }) },
    { r1s("Beta", { r1m("growl", 0, 18) }, { spd = 90 }) },
    {
      mode = "wild",
      seed = 8301,
      turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } },
    }),
  r1duo(
    { r1s("Alpha", { r1m("splash", 0, 85) }, { spd = 10 }) },
    { r1s("Beta", { r1m("growl", 0, 18) }, { spd = 90 }) },
    {
      seed = 8301,
      turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } },
    }),
  r1duo(
    { r1s("Alpha", { r1m("splash", 0, 85) }, { spd = 10, mist = true }) },
    { r1s("Beta", { r1m("growl", 0, 18) }, { spd = 90 }) },
    { mode = "wild", seed = 8302, turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("growl", 0, 18) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10, substitute = 30 }) },
    { seed = 8303, turns = { { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("growl", 0, 18) }, { spd = 90, xAccuracy = true }) },
    {
      r1s("Beta", { r1m("growl", 0, 18) },
        { spd = 10, stages = { atk = 0, def = 0, spd = 0, spc = 0, acc = 0, eva = 0 } }),
    },
    { seed = 8304, turns = { { p1 = 0, p2 = 0 } } }),
  r1duo(
    {
      r1s("Alpha", { r1m("dance", 0, 50) },
        { spd = 90, stages = { atk = 6, def = 0, spd = 0, spc = 0, acc = 0, eva = 0 } }),
    },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10 }) },
    { seed = 8305, turns = { { p1 = 0, p2 = 0 } } }),
}))

-- ClearHyperBeam (effects.asm :1181-1191), beyond the flinch
-- (g1_flinch_recharge): a freeze on the player's turn (`.freeze1`; the
-- computer's `.freeze2` leaves it) and a trap that starts -- before its hit
-- test, so even one that misses:
--   1 wild: the wild Beta beams, Alpha (the player) freezes it: no recharge;
--   2 wild: Alpha beams, the wild Beta freezes it: Alpha still recharges;
--   3 1v1: the same, a link fight: both sides are the player, it is cleared;
--   4 wild: Alpha beams, the wild Beta's Wrap misses: no recharge.
scenario("g1_clear_recharge", fights("g1cr", {
  r1duo(
    { r1s("Alpha", { r1m("chill", 10, 35, { chance = 100 }) }, { spd = 10 }) },
    { r1s("Beta", { r1m("beam", 20, 80) }, { spd = 90 }) },
    { mode = "wild", seed = 8401, turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("beam", 20, 80) }, { spd = 90 }) },
    { r1s("Beta", { r1m("chill", 10, 35, { chance = 100 }) }, { spd = 10 }) },
    { mode = "wild", seed = 8401, turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("beam", 20, 80) }, { spd = 90 }) },
    { r1s("Beta", { r1m("chill", 10, 35, { chance = 100 }) }, { spd = 10 }) },
    { seed = 8401, turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("beam", 20, 80) }, { spd = 90 }) },
    { r1s("Beta", { r1m("wrap", 10, 42, { accuracy = 0 }) }, { spd = 10 }) },
    { mode = "wild", seed = 8402, turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } } }),
}))

-- The computer's item and switch in its own slot of the order
-- (MainInBattleLoop -> TrainerAI at `.enemyMovesFirst` / after
-- ExecutePlayerMove), a coop_npc trainer on side b:
--   1 a slower Beta's SUPER POTION lands after Alpha's hit;
--   2 a faster Beta switches to Delta before Alpha moves: the hit finds Delta;
--   3 a slower Beta that Alpha knocks out never switches (the AI's turn is
--     gone with it); its send-out follows;
--   4 the same Speed: the tie byte is drawn for the item as for a move.
scenario("g1_computer_turn_slot", fights("g1ct", {
  r1duo(
    { r1s("Alpha", { r1m("tap", 20, 0) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10, hp = 100 }) },
    {
      mode = "coop_npc",
      seed = 8501,
      bSeat = { bag = { SUPER_POTION = 1 } },
      turns = { { p1 = 0, p2 = { action = "item", item = "SUPER_POTION" } } },
    }),
  r1duo(
    { r1s("Alpha", { r1m("tap", 20, 0) }, { spd = 10 }) },
    {
      r1s("Beta", { r1m("splash", 0, 85) }, { spd = 90 }),
      r1s("Delta", { r1m("splash", 0, 85) }, { spd = 5 }),
    },
    {
      mode = "coop_npc",
      seed = 8502,
      turns = { { p1 = 0, p2 = { action = "switch", slot = 1 } } },
    }),
  r1duo(
    { r1s("Alpha", { r1m("tap", 200, 0) }, { spd = 90, atk = 200 }) },
    {
      r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10, hp = 5 }),
      r1s("Delta", { r1m("splash", 0, 85) }, { spd = 5 }),
    },
    {
      mode = "coop_npc",
      seed = 8503,
      turns = {
        { p1 = 0, p2 = { action = "switch", slot = 1 } },
        { p2 = { action = "switch", slot = 1 } },
      },
    }),
  r1duo(
    { r1s("Alpha", { r1m("tap", 20, 0) }, { spd = 40 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 40, hp = 100 }) },
    {
      mode = "coop_npc",
      seed = 8504,
      bSeat = { bag = { SUPER_POTION = 1 } },
      turns = { { p1 = 0, p2 = { action = "item", item = "SUPER_POTION" } } },
    }),
}))

-- Asleep or frozen, the move menu is skipped (MainInBattleLoop :308-311,
-- SelectEnemyMove :2946-2948): last turn's selection stands and the bracket
-- reads it.  Alpha (slow) taps on turn 1 and is put to sleep; on turn 2 its
-- QUICK ATTACK choice still moves in tap's bracket, after Beta.  MIRROR MOVE
-- then finds Alpha's used move zeroed by the fast-asleep turn.
scenario("g1_asleep_selection", fights("g1as", {
  r1duo(
    { r1s("Alpha", { r1m("tap", 10, 0), r1m("QUICK_ATTACK", 10, 0) }, { spd = 10 }) },
    {
      r1s("Beta", { r1m("lull", 0, 32), r1m("thump", 10, 0), r1m("MIRROR_MOVE", 0, 9) },
        { spd = 90 }),
    },
    { seed = 8601, turns = { { p1 = 0, p2 = 0 }, { p1 = 1, p2 = 1 }, { p1 = 1, p2 = 2 } } }),
}))

-- AnyMoveToSelect (core.asm :2713-2753) with a move disabled ORs the other
-- slots' raw PP bytes: a 0-PP move with no PP Ups leaves nothing -- STRUGGLE
-- -- even with the disabled move's PP full.
scenario("g1_struggle_disabled", fights("g1sg", {
  r1duo(
    {
      r1s("Alpha", { r1m("tap", 10, 0, { pp = 0 }), r1m("chop", 10, 0, { pp = 10 }) },
        { spd = 90, disable = { moveIndex = 2, turns = 5 } }),
    },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10 }) },
    { seed = 8701, turns = { { p1 = 0, p2 = 0 }, { p1 = 1, p2 = 0 } } }),
}))

-- DisableEffect (effects.asm :1286-1367): its MoveHitTest, then a random
-- slot (`BattleRandom & 3`, redrawn until it holds a move -- and, when the
-- target is the player's, has a raw PP byte: PP Ups count), for 1..8 steps
-- of `.AnyMoveDisabledCheck`, each in the disabled monster's own turn:
--   1 1v1: Beta's THUMP / CHOP / SLAM, disabled and worn off over six turns;
--   2 1v1: a 0-PP move with PP Ups is pickable, a bare 0-PP one never is;
--   3 wild: the player disables the wild Beta, whose PP is never read;
--   4 1v1: accuracy 0 -- "But it failed!"; a doll does not stop it.
scenario("g1_disable", fights("g1ds", {
  r1duo(
    { r1s("Alpha", { r1m("lock", 0, 86), r1m("splash", 0, 85) }, { spd = 90 }) },
    {
      r1s("Beta", { r1m("thump", 10, 0), r1m("chop", 10, 0), r1m("slam", 10, 0) }, { spd = 10 }),
    },
    {
      seed = 8801,
      turns = {
        { p1 = 0, p2 = 0 },
        { p1 = 1, p2 = 0 },
        { p1 = 1, p2 = 0 },
        { p1 = 1, p2 = 0 },
        { p1 = 1, p2 = 0 },
        { p1 = 1, p2 = 0 },
      },
    }),
  r1duo(
    { r1s("Alpha", { r1m("lock", 0, 86) }, { spd = 90 }) },
    {
      r1s(
        "Beta",
        {
          r1m("thump", 10, 0, { pp = 0, ppUps = 2 }),
          r1m("chop", 10, 0, { pp = 0 }),
          r1m("slam", 10, 0, { pp = 5 }),
        },
        { spd = 10 }),
    },
    { seed = 8802, turns = { { p1 = 0, p2 = 2 } } }),
  r1duo(
    { r1s("Alpha", { r1m("lock", 0, 86) }, { spd = 90 }) },
    {
      r1s("Beta", { r1m("thump", 10, 0, { pp = 0 }), r1m("chop", 10, 0, { pp = 0 }) },
        { spd = 10 }),
    },
    { mode = "wild", seed = 8803, turns = { { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("lock", 0, 86, { accuracy = 0 }), r1m("lock", 0, 86) }, { spd = 90 }) },
    { r1s("Beta", { r1m("thump", 10, 0) }, { spd = 10, substitute = 30 }) },
    { seed = 8804, turns = { { p1 = 0, p2 = 0 }, { p1 = 1, p2 = 0 } } }),
}))

-- PoisonEffect's primary branch (effects.asm :78-162): a doll, a status or a
-- Poison type turn it away before its MoveHitTest ("It didn't affect"), and
-- TOXIC -- the move, by its id -- badly poisons:
--   1 a Poison-type Beta (typeIds names index 1): no byte drawn;
--   2 a Normal-type Beta: poisoned;
--   3 TOXIC: badly poisoned, the counter climbing;
--   4 a doll: turned away.
scenario("g1_poison_primary", fights("g1pp", {
  r1duo(
    { r1s("Alpha", { r1m("powder", 0, 66) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10, types = { 1 } }) },
    { seed = 8901, typeIds = { "NORMAL", "POISON" }, turns = { { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("powder", 0, 66) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10, types = { 0 } }) },
    { seed = 8901, typeIds = { "NORMAL", "POISON" }, turns = { { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("TOXIC", 0, 66) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10, types = { 0 } }) },
    {
      seed = 8902,
      typeIds = { "NORMAL", "POISON" },
      turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } },
    }),
  r1duo(
    { r1s("Alpha", { r1m("powder", 0, 66) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10, types = { 0 }, substitute = 30 }) },
    { seed = 8903, typeIds = { "NORMAL", "POISON" }, turns = { { p1 = 0, p2 = 0 } } }),
}))

-- "Hit the enemy N times!" (_MultiHitText, the player's) and "Hit N
-- times!" (_HitXTimesText, the computer's), with the drawn count, once the
-- hits run out with the target standing; a knockout returns before it:
--   1 1v1: Alpha's DOUBLE KICK;
--   2 wild: the wild Beta's;
--   3 1v1: a two-to-five move that knocks Beta out says nothing;
--   4 1v1: a power-0 two-to-five move still hits (CalculateDamage's 2).
scenario("g1_multihit_lines", fights("g1mh", {
  r1duo(
    { r1s("Alpha", { r1m("kicks", 20, 44) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10 }) },
    { seed = 9001, turns = { { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("splash", 0, 85) }, { spd = 10 }) },
    { r1s("Beta", { r1m("kicks", 20, 44) }, { spd = 90 }) },
    { mode = "wild", seed = 9001, turns = { { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("pelt", 40, 29) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10, hp = 12 }) },
    { seed = 9002, turns = { { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("pelt", 0, 29) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10 }) },
    { seed = 9003, turns = { { p1 = 0, p2 = 0 } } }),
}))

-- Contract K9, the rebuild experience.asm makes after a level-up in battle:
--   1 wild: the fielded Alpha (burned, at +1 Attack, every badge) grows to
--     level 21 with stated stats and max HP: the party stats, the HP step,
--     then CalculateModifiedStats, the burn and the badges; the benched
--     Gamma grows from its K7 sheet alone (no stats stated); a claim with a
--     stat that went down, a level that did not go up, and side b's are
--     refused;
--   2 1v1: a link fight earns no experience -- refused.
scenario("g1_level_up", fights("g1lu", {
  r1duo(
    {
      r1s("Alpha", { r1m("tap", 10, 0) },
        {
          spd = 90,
          atk = 60,
          spc = 55,
          maxHp = 60,
          hp = 30,
          status = "BRN",
          stages = { atk = 1, def = 0, spd = 0, spc = 0, acc = 0, eva = 0 },
          def = 50,
        }),
      r1s("Gamma", { r1m("splash", 0, 85) },
        {
          level = 15,
          atk = 22,
          spd = 22,
          spc = 28,
          maxHp = 38,
          base = { hp = 45, atk = 49, def = 49, spd = 45, spc = 65 },
          dvs = { atk = 10, def = 8, spd = 12, spc = 14 },
          def = 22,
        }),
    },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10 }) },
    {
      mode = "wild",
      seed = 9101,
      aSeat = {
        badges = { BOULDERBADGE = true, THUNDERBADGE = true, SOULBADGE = true, VOLCANOBADGE = true },
      },
      turns = {
        { p1 = 0, p2 = 0, lv = { "p1", 1, 21, { atk = 63, def = 52, spd = 94, spc = 57 }, 63 } },
        { p1 = 0, p2 = 0, lv = { "p1", 2, 16, nil, nil } },
        { p1 = 0, p2 = 0, lv = { "p1", 1, 22, { atk = 62, def = 53, spd = 95, spc = 58 }, 64 } },
        { p1 = 0, p2 = 0, lv = { "p1", 1, 21, { atk = 64, def = 53, spd = 95, spc = 58 }, 64 } },
        {
          p1 = 0,
          p2 = 0,
          lv = { "p2", 1, 21, { atk = 41, def = 41, spd = 41, spc = 41 }, 401 },
        },
      },
    }),
  r1duo(
    { r1s("Alpha", { r1m("tap", 10, 0) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10 }) },
    {
      seed = 9102,
      turns = {
        {
          p1 = 0,
          p2 = 0,
          lv = { "p1", 1, 21, { atk = 42, def = 42, spd = 92, spc = 42 }, 402 },
        },
      },
    }),
}))

-- JUMP KICK's crash is 1 HP (PrintMoveFailureText: wDamage is 0 by then) and
-- goes the self-hit's way past the crasher's own doll to the opposing one;
-- SetDamageEffects draw no crit, no roll and ignore the chart, and
-- `.specialDamage` reads the move id:
--   1 a missed JUMP KICK: 1 HP;  2 behind its own doll: Beta's doll takes it;
--   3 into a Ghost (chart 0): "doesn't affect", then the crash;
--   4 SEISMIC TOSS (level 30) and SONICBOOM into a Ghost: 30, then 20;
--   5 DRAGON RAGE, then SUPER FANG: 40, then half what is left;
--   6 PSYWAVE (level 30): BattleRandom until it is in 1..44.
scenario("g1_crash_and_set_damage", fights("g1cs", {
  r1duo(
    { r1s("Alpha", { r1m("leap", 70, 45, { accuracy = 0 }) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10 }) },
    { seed = 9201, turns = { { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("leap", 70, 45, { accuracy = 0 }) }, { spd = 90, substitute = 40 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10, substitute = 10 }) },
    { seed = 9201, turns = { { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("leap", 70, 45, { type = 1 }) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10, types = { 2 } }) },
    {
      seed = 9202,
      chart = { { 100, 100, 100 }, { 100, 100, 0 }, { 100, 100, 100 } },
      turns = { { p1 = 0, p2 = 0 } },
    }),
  r1duo(
    {
      r1s("Alpha", { r1m("SEISMIC_TOSS", 1, 41, { type = 1 }), r1m("SONICBOOM", 1, 41) },
        { level = 30, spd = 90 }),
    },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10, types = { 2 } }) },
    {
      seed = 9203,
      chart = { { 100, 100, 0 }, { 100, 100, 0 }, { 100, 100, 100 } },
      turns = { { p1 = 0, p2 = 0 }, { p1 = 1, p2 = 0 } },
    }),
  r1duo(
    { r1s("Alpha", { r1m("DRAGON_RAGE", 1, 41), r1m("fang", 1, 40) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10 }) },
    { seed = 9204, turns = { { p1 = 0, p2 = 0 }, { p1 = 1, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("PSYWAVE", 1, 41) }, { level = 30, spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10 }) },
    { seed = 9205, turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } } }),
}))

-- OneHitKOEffect_ fails only on a SLOWER user (`jr c`): a Speed tie lands;
-- a full paralysis (`.MonHurtItselfOrFullyParalysed`) drops a charge but not
-- INVULNERABLE:
--   1 1v1, both at Speed 40: the OHKO lands;
--   2 a paralysed Alpha in the air with FLY is fully paralysed on the release
--     turn (seed 9309): no charge, still invulnerable -- Beta's thump fails --
--     and turn 2 is Alpha's own choice, a fresh FLY.
scenario("g1_ohko_paralysis", fights("g1op", {
  r1duo(
    { r1s("Alpha", { r1m("drill", 1, 38) }, { spd = 40 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 40 }) },
    { seed = 9301, turns = { { p1 = 0, p2 = 0 } } }),
  r1duo(
    {
      r1s("Alpha", { r1m("FLY", 90, 43) },
        {
          spd = 90,
          status = "PAR",
          charging = { moveIndex = 1, effect = 43, targetSlot = 3, moveId = "FLY" },
          invulnerable = true,
        }),
    },
    { r1s("Beta", { r1m("thump", 10, 0) }, { spd = 10 }) },
    { seed = 9309, turns = { { p2 = 0 }, { p1 = 0, p2 = 0 } } }),
}))

-- TrappingEffect runs before the hit (SpecialEffectsCont): only MoveHitTest's
-- miss takes it back -- a doll that holds keeps the trap, an immunity leaves
-- it at 0 a turn -- and its counter is the two-to-five odds:
--   1 Wrap into a 50-HP doll that holds: Beta held;
--   2 Wrap, accuracy 0: no trap;
--   3 Wrap into a Ghost (chart 0): "doesn't affect", Beta held at 0;
--   4 Wrap breaking a 3-HP doll: Beta held all the same.
scenario("g1_trap_start", fights("g1ts", {
  r1duo(
    { r1s("Alpha", { r1m("wrap", 15, 42) }, { spd = 90 }) },
    { r1s("Beta", { r1m("thump", 10, 0) }, { spd = 10, substitute = 50 }) },
    { seed = 9401, turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("wrap", 15, 42, { accuracy = 0 }) }, { spd = 90 }) },
    { r1s("Beta", { r1m("thump", 10, 0) }, { spd = 10 }) },
    { seed = 9402, turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("wrap", 15, 42) }, { spd = 90 }) },
    { r1s("Beta", { r1m("thump", 10, 0) }, { spd = 10, types = { 2 } }) },
    {
      seed = 9403,
      chart = { { 100, 100, 0 }, { 100, 100, 100 }, { 100, 100, 100 } },
      turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } },
    }),
  r1duo(
    { r1s("Alpha", { r1m("wrap", 15, 42) }, { spd = 90 }) },
    { r1s("Beta", { r1m("thump", 10, 0) }, { spd = 10, substitute = 3 }) },
    { seed = 9404, turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } } }),
}))

-- MIRROR MOVE copies wEnemyUsedMove -- the last move the target printed a
-- "used" line for: after its METRONOME called THRASH it is THRASH, and
-- Alpha, mirroring, thrashes too (a MIRROR MOVE of METRONOME would have
-- called again).
scenario("g1_mirror_used", fights("g1mu", {
  r1duo(
    { r1s("Alpha", { r1m("MIRROR_MOVE", 0, 9) }, { spd = 10 }) },
    { r1s("Beta", { r1m("METRONOME", 0, 83) }, { spd = 90 }) },
    {
      seed = 9501,
      pool = { r1m("THRASH", 30, 27) },
      turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 0 } },
    }),
}))

-- EndOfBattle pays the Pay Day pile whenever wBattleResult is still 0: an
-- escape by TELEPORT / ROAR / WHIRLWIND -- either side's -- pays; the
-- player's RUN (TryRunningFromBattle writes 2) does not:
--   1 wild: Alpha's PAY DAY, then the wild Beta teleports away;
--   2 wild: Alpha's PAY DAY, then Alpha teleports;
--   3 wild: Alpha's PAY DAY, then Alpha runs.
scenario("g1_pay_day_escape", fights("g1pe", {
  r1duo(
    { r1s("Alpha", { r1m("coins", 20, 16) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85), r1m("warp", 0, 28) }, { spd = 10 }) },
    { mode = "wild", seed = 9601, turns = { { p1 = 0, p2 = 0 }, { p1 = 0, p2 = 1 } } }),
  r1duo(
    { r1s("Alpha", { r1m("coins", 20, 16), r1m("warp", 0, 28) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10 }) },
    { mode = "wild", seed = 9601, turns = { { p1 = 0, p2 = 0 }, { p1 = 1, p2 = 0 } } }),
  r1duo(
    { r1s("Alpha", { r1m("coins", 20, 16) }, { spd = 90 }) },
    { r1s("Beta", { r1m("splash", 0, 85) }, { spd = 10 }) },
    {
      mode = "wild",
      seed = 9601,
      turns = { { p1 = 0, p2 = 0 }, { p1 = { action = "run" }, p2 = 0 } },
    }),
}))

-- A power-0 move whose routine never calls MoveHitTest draws no accuracy
-- byte and is not stopped by FLY: Beta (fast) is up on turns 1 and 3, where
-- Alpha's effect-less move goes ahead and its GROWL fails (MoveHitTest's
-- INVULNERABLE); SWORDS DANCE and HAZE draw nothing either.
scenario("g1_no_hit_test", fights("g1nh", {
  r1duo(
    {
      r1s(
        "Alpha",
        { r1m("wave", 0, 0), r1m("dance", 0, 50), r1m("haze", 0, 25), r1m("growl", 0, 18) },
        { spd = 10 }),
    },
    { r1s("Beta", { r1m("FLY", 90, 43) }, { spd = 90 }) },
    {
      seed = 9701,
      turns = { { p1 = 0, p2 = 0 }, { p1 = 1, p2 = 0 }, { p1 = 3, p2 = 0 }, { p1 = 2, p2 = 0 } },
    }),
}))

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
