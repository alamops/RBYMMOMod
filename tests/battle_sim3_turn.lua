-- src/BattleSim3/Turn.lua against the Gen 3 whole-turn parity fixture.
--
-- Run: luajit tests/battle_sim3_turn.lua            (from this folder's root)
--   or luajit mods/rby_mmo/tests/battle_sim3_turn.lua  (from the engine)
-- Regenerate the expectations after a deliberate rule change:
--      luajit tests/battle_sim3_turn.lua --update
--
-- tests/fixtures/battle3_turn_parity.json holds SCRIPTS, not just answers: each
-- scenario is `create` (the Turn.create options, verbatim) plus `steps`, and
-- `expect` is what src/BattleSim3 produced for it.  That is what makes the
-- fixture runtime-agnostic -- the Node twin (server/lib/battle3, wave 3) replays
-- the same steps against Turn.js and compares, event for event, without a
-- mirrored copy of any scenario (the Gen 2 pair keeps its scenarios twice; this
-- one keeps them once).
--
-- The step vocabulary (all a replayer needs):
--
--   { op = "drain" }                           drainEvents(); append the events,
--                                              append the count to `batches`
--   { op = "submit", player, choice }          submitChoice -> `results`
--   { op = "auto", player }                    autoPick -> `results`
--   { op = "tick", now }                       tick(now) -> `results`
--   { op = "disconnect" | "reconnect", player } -> `results`
--   { op = "repeat", times, untilOver, steps } run `steps` `times` times,
--                                              stopping first when untilOver and
--                                              outcome() is set
--
-- `create.typeTable == "$chart"` / `create.movePool == "$pool"` are replaced by
-- the fixture's shared `typeTable` / `movePool` before Turn.create.
--
-- `expect` = { events, batches, results, outcome, snapshot }, where snapshot is
-- the digest { phase, turn, seq, now, deadline, rngState, weather, field =
-- [{ slot, hp, party }] } -- rngState is the one number that proves both
-- runtimes drew the same count.  Events compare as canonical JSON (sorted keys),
-- so key order never matters and a missing or extra field always does.
--
-- Standalone (no engine, no love, no mod facade), like the vector suite.
-- Synthetic throughout: every species, move and number is invented.

local ROOT = "."
do
  local invoked = arg and arg[0]
  local dir = invoked and invoked:match("^(.*)[/\\]tests[/\\][^/\\]+$")
  if dir and dir ~= "" then ROOT = dir end
end
local UPDATE = false
for i = 1, #(arg or {}) do
  if arg[i] == "--update" then UPDATE = true end
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
    io.stderr:write("battle_sim3_turn: missing " .. path .. "\n")
    os.exit(1)
  end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then
    io.stderr:write("battle_sim3_turn: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  cache[name] = chunk(need)
  return cache[name]
end

local Sim = need("BattleSim3/init")
local Turn, Events = Sim.Turn, Sim.Events

-- ------------------------------------------------------------------
-- JSON: a reader (null -> NULL) and a canonical writer (sorted keys)
-- ------------------------------------------------------------------

local NULL = setmetatable({}, { __tostring = function() return "null" end })
local OBJECT = {}   -- metatable marking an empty table that must encode as {}

local decodeValue

local function skipSpace(text, i)
  local _, stop = text:find("^[ \t\r\n]*", i)
  return stop + 1
end

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function decodeString(text, i)
  local out, pos = {}, i + 1
  while true do
    local c = text:sub(pos, pos)
    if c == "" then error("unterminated string at " .. i, 0) end
    if c == '"' then return table.concat(out), pos + 1 end
    if c == "\\" then
      local esc = text:sub(pos + 1, pos + 1)
      if esc == "u" then error("\\u escapes are not supported by this reader", 0) end
      out[#out + 1] = ESCAPES[esc] or esc
      pos = pos + 2
    else
      out[#out + 1] = c
      pos = pos + 1
    end
  end
end

local function decodeNumber(text, i)
  local literal = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  return tonumber(literal), i + #literal
end

local function decodeArray(text, i)
  local out, pos = {}, skipSpace(text, i + 1)
  if text:sub(pos, pos) == "]" then return out, pos + 1 end
  while true do
    local value
    value, pos = decodeValue(text, pos)
    out[#out + 1] = value
    pos = skipSpace(text, pos)
    local c = text:sub(pos, pos)
    if c == "]" then return out, pos + 1 end
    if c ~= "," then error("expected , or ] at " .. pos, 0) end
    pos = skipSpace(text, pos + 1)
  end
end

local function decodeObject(text, i)
  local out, pos = setmetatable({}, OBJECT), skipSpace(text, i + 1)
  if text:sub(pos, pos) == "}" then return out, pos + 1 end
  while true do
    local key, value
    key, pos = decodeString(text, pos)
    pos = skipSpace(text, pos)
    if text:sub(pos, pos) ~= ":" then error("expected : at " .. pos, 0) end
    value, pos = decodeValue(text, skipSpace(text, pos + 1))
    out[key] = value
    pos = skipSpace(text, pos)
    local c = text:sub(pos, pos)
    if c == "}" then return out, pos + 1 end
    if c ~= "," then error("expected , or } at " .. pos, 0) end
    pos = skipSpace(text, pos + 1)
  end
end

function decodeValue(text, i)
  i = skipSpace(text, i)
  local c = text:sub(i, i)
  if c == "{" then return decodeObject(text, i) end
  if c == "[" then return decodeArray(text, i) end
  if c == '"' then return decodeString(text, i) end
  if text:sub(i, i + 3) == "true" then return true, i + 4 end
  if text:sub(i, i + 4) == "false" then return false, i + 5 end
  if text:sub(i, i + 3) == "null" then return NULL, i + 4 end
  return decodeNumber(text, i)
end

local function encString(s)
  return '"' .. s:gsub('[%c"\\]', function(ch)
    if ch == '"' then return '\\"' end
    if ch == '\\' then return '\\\\' end
    if ch == '\n' then return '\\n' end
    if ch == '\t' then return '\\t' end
    return string.format('\\u%04x', ch:byte())
  end) .. '"'
end

local function isArray(t)
  if getmetatable(t) == OBJECT then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

local encode
function encode(v)
  if v == nil or v == NULL then return "null" end
  local t = type(v)
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then
    if v == math.floor(v) then return string.format("%d", v) end
    return string.format("%.17g", v)
  end
  if t == "string" then return encString(v) end
  if next(v) == nil then return (getmetatable(v) == OBJECT) and "{}" or "[]" end
  if isArray(v) then
    local parts = {}
    for i = 1, #v do parts[i] = encode(v[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = encString(k) .. ":" .. encode(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- A decoded value back into plain Lua (NULL -> nil), for Turn.create.
local function plain(v)
  if v == NULL then return nil end
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do
    if x ~= NULL then out[k] = plain(x) end
  end
  return out
end

-- ------------------------------------------------------------------
-- replay
-- ------------------------------------------------------------------

local FIXTURE = ROOT .. "/tests/fixtures/battle3_turn_parity.json"
local raw = slurp(FIXTURE)
if not raw then
  io.stderr:write("battle_sim3_turn: missing " .. FIXTURE .. "\n")
  os.exit(1)
end
local fixture = decodeValue(raw, 1)

local function digest(battle)
  local snap = battle:snapshot()
  local field = {}
  for _, entry in ipairs(snap.field) do
    field[#field + 1] = { slot = entry.slot, hp = entry.hp, party = entry.party }
  end
  return {
    phase = snap.phase, turn = snap.turn, seq = snap.seq, now = snap.now,
    deadline = snap.deadline or NULL, rngState = snap.rngState,
    weather = snap.weather or NULL, field = field,
  }
end

local function outcomeOf(out)
  if not out then return NULL end
  local o = { battle = out.battle, outcome = out.outcome, reason = out.reason }
  if out.winners then o.winners = out.winners end
  if out.losers then o.losers = out.losers end
  if out.catcher then o.catcher = out.catcher end
  if out.caught then o.caughtSpecies = out.caught.species end
  return o
end

local function run(scn)
  local opts = plain(scn.create)
  if opts.typeTable == "$chart" then opts.typeTable = plain(fixture.typeTable) end
  if opts.movePool == "$pool" then opts.movePool = plain(fixture.movePool) end
  local battle, reason = Turn.create(opts)
  if not battle then return { refused = reason } end
  local got = { events = {}, batches = {}, results = {} }
  local bad = {}
  local function drain()
    local list = battle:drainEvents()
    for _, e in ipairs(list) do
      local ok, why = Events.check(e)
      if not ok then bad[#bad + 1] = tostring(e.seq) .. ": " .. tostring(why) end
      got.events[#got.events + 1] = e
    end
    got.batches[#got.batches + 1] = #list
  end
  local exec
  exec = function(steps)
    for _, st in ipairs(steps) do
      if st.op == "drain" then drain()
      elseif st.op == "submit" then got.results[#got.results + 1] = battle:submitChoice(st.player, plain(st.choice))
      elseif st.op == "auto" then got.results[#got.results + 1] = battle:autoPick(st.player)
      elseif st.op == "tick" then got.results[#got.results + 1] = battle:tick(st.now)
      elseif st.op == "disconnect" then got.results[#got.results + 1] = battle:disconnect(st.player)
      elseif st.op == "reconnect" then got.results[#got.results + 1] = battle:reconnect(st.player)
      elseif st.op == "repeat" then
        for _ = 1, st.times do
          if st.untilOver and battle:outcome() then break end
          exec(st.steps)
        end
      else
        error("unknown step op " .. tostring(st.op), 0)
      end
    end
  end
  exec(scn.steps)
  got.outcome = outcomeOf(battle:outcome())
  got.snapshot = digest(battle)
  got.badEvents = bad
  return got
end

-- ------------------------------------------------------------------
-- compare / update
-- ------------------------------------------------------------------

local passed, failed = 0, 0
local function fail(name, what)
  failed = failed + 1
  io.stderr:write("FAIL " .. name .. ": " .. what .. "\n")
end

local results = {}
for index, scn in ipairs(fixture.scenarios) do
  local ok, got = pcall(run, scn)
  if not ok then
    fail(scn.name, "threw: " .. tostring(got))
    results[index] = nil
  elseif got.refused then
    fail(scn.name, "create refused: " .. tostring(got.refused))
  else
    results[index] = got
    for _, why in ipairs(got.badEvents) do fail(scn.name, "event outside the C5 whitelist: " .. why) end
    if not UPDATE then
      local exp = scn.expect
      if type(exp) ~= "table" then
        fail(scn.name, "no expect block (run with --update)")
      else
        local n = math.max(#exp.events, #got.events)
        local shown = 0
        for i = 1, n do
          local a, b = encode(exp.events[i]), encode(got.events[i])
          if a ~= b then
            if shown < 3 then fail(scn.name, "event " .. i .. "\n  expected " .. a .. "\n  got      " .. b) end
            shown = shown + 1
          else
            passed = passed + 1
          end
        end
        for _, key in ipairs({ "batches", "results", "outcome", "snapshot" }) do
          local a, b = encode(exp[key]), encode(got[key])
          if a ~= b then fail(scn.name, key .. "\n  expected " .. a .. "\n  got      " .. b)
          else passed = passed + 1 end
        end
      end
    end
  end
end

if UPDATE then
  -- Rewrite the fixture: inputs as they were, expectations from this run,
  -- one event per line so a diff reads as a turn-by-turn change.
  local lines = { "{" }
  lines[#lines + 1] = '  "version": ' .. encode(fixture.version) .. ","
  lines[#lines + 1] = '  "generation": ' .. encode(fixture.generation) .. ","
  lines[#lines + 1] = '  "notes": ' .. encode(fixture.notes) .. ","
  lines[#lines + 1] = '  "typeTable": ' .. encode(fixture.typeTable) .. ","
  lines[#lines + 1] = '  "movePool": ' .. encode(fixture.movePool) .. ","
  lines[#lines + 1] = '  "scenarios": ['
  for index, scn in ipairs(fixture.scenarios) do
    local got = results[index]
    lines[#lines + 1] = "    {"
    lines[#lines + 1] = '      "name": ' .. encode(scn.name) .. ","
    lines[#lines + 1] = '      "create": ' .. encode(scn.create) .. ","
    lines[#lines + 1] = '      "steps": ' .. encode(scn.steps) .. ","
    lines[#lines + 1] = '      "expect": {'
    lines[#lines + 1] = '        "batches": ' .. encode(got and got.batches or {}) .. ","
    lines[#lines + 1] = '        "results": ' .. encode(got and got.results or {}) .. ","
    lines[#lines + 1] = '        "outcome": ' .. encode(got and got.outcome or NULL) .. ","
    lines[#lines + 1] = '        "snapshot": ' .. encode(got and got.snapshot or NULL) .. ","
    lines[#lines + 1] = '        "events": ['
    local evs = got and got.events or {}
    for i, e in ipairs(evs) do
      lines[#lines + 1] = "          " .. encode(e) .. ((i < #evs) and "," or "")
    end
    lines[#lines + 1] = "        ]"
    lines[#lines + 1] = "      }"
    lines[#lines + 1] = "    }" .. ((index < #fixture.scenarios) and "," or "")
  end
  lines[#lines + 1] = "  ]"
  lines[#lines + 1] = "}"
  local handle = io.open(FIXTURE, "wb")
  if not handle then
    io.stderr:write("battle_sim3_turn: cannot write " .. FIXTURE .. "\n")
    os.exit(1)
  end
  handle:write(table.concat(lines, "\n") .. "\n")
  handle:close()
  io.write(string.format("battle_sim3_turn: rewrote %s (%d scenarios)\n", FIXTURE, #fixture.scenarios))
  os.exit(failed == 0 and 0 or 1)
end

io.write(string.format("battle_sim3_turn: %d passed, %d failed (%d scenarios)\n",
  passed, failed, #fixture.scenarios))
os.exit(failed == 0 and 0 or 1)
