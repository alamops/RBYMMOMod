-- src/BattleSim against the shared vector pack.
--
-- Run: luajit tests/battle_sim_vectors.lua      (from this folder's root)
--   or luajit mods/rby_mmo/tests/battle_sim_vectors.lua  (from the engine)
--
-- This suite is deliberately standalone.  Every other test in this repo goes
-- through the engine's tests/modkit and therefore needs an engine checkout,
-- but the whole claim src/BattleSim makes is that it is pure arithmetic with
-- no love, no engine modules and no mod facade -- so a suite that needed any
-- of those to run would be testing something weaker than the claim.  It loads
-- the shipped files through the same `need`-shaped resolver main.lua uses, so
-- what runs here is what ships, and it parses the fixture JSON with the small
-- reader below rather than src/link/Json.lua for the same reason.
--
-- tests/fixtures/battle_sim_vectors.json is the contract, not this file: the
-- Node twin under server/lib/battle/ runs the identical vectors, and a case
-- that passes on one side and fails on the other is exactly the drift the
-- pack exists to catch.  Add a vector there before changing a formula here.
--
-- Every assertion compares only the keys the fixture's `out` actually states,
-- so the modules are free to return extra intermediates without the fixture
-- having to enumerate them -- but a key the fixture *does* state, including an
-- explicit null, has to match.

-- ------------------------------------------------------------------
-- where we are
-- ------------------------------------------------------------------

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

-- ------------------------------------------------------------------
-- the module graph, resolved the way main.lua resolves it
-- ------------------------------------------------------------------

local loadstr = loadstring or load
local cache = {}
local function need(name)
  if cache[name] ~= nil then return cache[name] end
  local path = ROOT .. "/src/" .. name .. ".lua"
  local body = slurp(path)
  if not body then
    io.stderr:write("battle_sim_vectors: missing " .. path .. "\n")
    os.exit(1)
  end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then
    io.stderr:write("battle_sim_vectors: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  cache[name] = chunk(need)
  return cache[name]
end

local BattleSim = need("BattleSim/init")
local Damage, Accuracy = BattleSim.Damage, BattleSim.Accuracy
local Crit, Status, Rng = BattleSim.Crit, BattleSim.Status, BattleSim.Rng

-- ------------------------------------------------------------------
-- a JSON reader, just enough for the fixture
-- ------------------------------------------------------------------
--
-- `null` decodes to the NULL sentinel rather than to nil, because the
-- difference matters here: `"damage": null` is an assertion that the band
-- case reports no single number, while a missing `damage` key is an
-- assertion about nothing at all.  Collapsing both to nil would make the
-- roll-band vectors pass vacuously.

local NULL = setmetatable({}, { __tostring = function() return "null" end })

local decodeValue

local function skipSpace(text, i)
  local _, stop = text:find("^[ \t\r\n]*", i)
  return stop + 1
end

local ESCAPES = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
  f = "\f", n = "\n", r = "\r", t = "\t",
}

local function decodeString(text, i)
  local out, pos = {}, i + 1
  while true do
    local c = text:sub(pos, pos)
    if c == "" then error("unterminated string at " .. i, 0) end
    if c == '"' then return table.concat(out), pos + 1 end
    if c == "\\" then
      local esc = text:sub(pos + 1, pos + 1)
      if esc == "u" then
        -- The fixture is ASCII; a \u escape would mean the pack grew content
        -- this reader was never meant to carry, so say so rather than guess.
        error("\\u escapes are not supported by this reader", 0)
      end
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
  local out, pos = {}, skipSpace(text, i + 1)
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

local FIXTURE = ROOT .. "/tests/fixtures/battle_sim_vectors.json"
local raw = slurp(FIXTURE)
if not raw then
  io.stderr:write("battle_sim_vectors: missing " .. FIXTURE .. "\n")
  os.exit(1)
end
local vectors = decodeValue(raw, 1)

-- ------------------------------------------------------------------
-- assertions
-- ------------------------------------------------------------------

local passed, failed = 0, 0

local function show(value)
  if value == NULL then return "null" end
  if value == nil then return "nil" end
  return tostring(value)
end

local function fail(id, what, expected, actual)
  failed = failed + 1
  io.stderr:write(string.format("FAIL %s: %s expected %s, got %s\n",
    id, what, show(expected), show(actual)))
end

-- One fixture field against one computed field.  A fixture `null` asserts the
-- module returned nothing at all, which is the case the roll-band and
-- always-hits vectors turn on.
local function field(id, key, expected, actual)
  if expected == NULL then
    if actual ~= nil then return fail(id, key, expected, actual) end
  elseif actual ~= expected then
    return fail(id, key, expected, actual)
  end
  passed = passed + 1
end

-- Compares every key the fixture states, and nothing else.
local function match(id, out, actual)
  local keys = {}
  for key in pairs(out) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do field(id, key, out[key], actual[key]) end
end

-- Case counts per section, printed at the end.  A section that decoded to
-- nothing -- a renamed key in the fixture, a reader that lost an array -- would
-- otherwise report a clean run having asserted nothing, which is the one
-- failure mode a green suite cannot tell you about itself.
local counts = {}

local function each(section, run)
  local cases = vectors[section]
  if type(cases) ~= "table" or #cases == 0 then
    failed = failed + 1
    io.stderr:write("FAIL " .. section .. ": no cases in the fixture\n")
    return
  end
  counts[#counts + 1] = string.format("%s=%d", section, #cases)
  for _, case in ipairs(cases) do
    local ok, actual = pcall(run, case["in"])
    if not ok then
      failed = failed + 1
      io.stderr:write(string.format("FAIL %s: threw (%s)\n",
        case.id, tostring(actual)))
    else
      match(case.id, case.out, actual)
    end
  end
end

-- A fixture null is "no value"; every module here takes nil for that.
local function orNil(value)
  if value == NULL then return nil end
  return value
end

-- ------------------------------------------------------------------
-- damage
-- ------------------------------------------------------------------

each("damage", function(input)
  return Damage.compute(
    { level = input.level, attack = input.attack },
    { defense = input.defense },
    { power = input.power },
    {
      crit = input.crit,
      stab = input.stab,
      typeEffect = input.typeEffect,
      roll = orNil(input.roll),
    })
end)

-- ------------------------------------------------------------------
-- accuracy
-- ------------------------------------------------------------------

each("accuracy", function(input)
  local hit, effective = Accuracy.hit(input.accuracy, input.roll, {
    accuracyMod = input.accuracyMod,
    evasionMod = input.evasionMod,
    alwaysHits = input.alwaysHits,
  })
  return { hit = hit, effectiveAccuracy = effective }
end)

-- ------------------------------------------------------------------
-- crit
-- ------------------------------------------------------------------

each("crit", function(input)
  local isCrit, threshold = Crit.check(input.baseSpeed, input.roll, {
    focusEnergy = input.focusEnergy,
    highCritMove = input.highCritMove,
  })
  return { isCrit = isCrit, threshold = threshold }
end)

-- ------------------------------------------------------------------
-- status
-- ------------------------------------------------------------------
--
-- The status section is not one shape: a paralysis case is either the
-- before-move gate or the speed cut depending on which field it carries, and
-- a burn case is either the residual or the attack cut.  Dispatching on the
-- fields present is what lets one fixture array cover both halves of a status
-- without inventing a second `kind` field the JS twin would also have to read.

local STATUS = {}

function STATUS.sleep(input)
  return Status.sleepTick(input.turnsRemaining)
end

function STATUS.freeze(input)
  return Status.freezeTick(input.roll)
end

function STATUS.paralysis(input)
  if input.speed ~= nil then
    return { speed = Status.paralysisSpeed(input.speed) }
  end
  return Status.paralysisTick(input.roll)
end

function STATUS.burn(input)
  if input.attack ~= nil then return { attack = Status.burnAttack(input.attack) } end
  return { residualDamage = Status.residualBurn(input.maxHp) }
end

function STATUS.poison(input)
  return { residualDamage = Status.residualPoison(input.maxHp) }
end

function STATUS.toxic(input)
  return { residualDamage = Status.residualToxic(input.maxHp, input.toxicCounter) }
end

function STATUS.confusion(input)
  return Status.confusionTick(input, input.roll)
end

each("status", function(input)
  local handler = STATUS[input.status]
  if not handler then error("no handler for status " .. tostring(input.status), 0) end
  return handler(input)
end)

-- ------------------------------------------------------------------
-- Rng: the one module the fixture cannot pin
-- ------------------------------------------------------------------
--
-- There are no RNG vectors, because a vector pack of raw draws would pin the
-- generator's identity rather than the game's rules -- and the rules are what
-- the two runtimes have to share.  What still has to hold is that the
-- generator is a *function of its seed*, since that is the property the whole
-- twin-runtime design rests on, so it is asserted directly here.  The JS twin
-- reproduces the same three checks against the same seeds.

local function rngCheck(what, expected, actual)
  if expected ~= actual then return fail("rng_" .. what, what, expected, actual) end
  passed = passed + 1
end

do
  local a, b = Rng.new(12345), Rng.new(12345)
  local same = true
  for _ = 1, 64 do
    if a:byte() ~= b:byte() then same = false end
  end
  rngCheck("same_seed_same_stream", true, same)

  local c, d = Rng.new(1), Rng.new(2)
  local differs = false
  for _ = 1, 64 do
    if c:byte() ~= d:byte() then differs = true end
  end
  rngCheck("different_seeds_diverge", true, differs)

  local e = Rng.new(99)
  local inBand, inByte = true, true
  for _ = 1, 512 do
    local roll = e:damageRoll()
    if roll < Damage.ROLL_MIN or roll > Damage.ROLL_MAX then inBand = false end
    local byte = e:byte()
    if byte < 0 or byte > 255 or byte ~= math.floor(byte) then inByte = false end
  end
  rngCheck("damage_roll_stays_in_band", true, inBand)
  rngCheck("byte_stays_in_range", true, inByte)

  -- A snapshot has to replay: this is what a reconnecting client is rebuilt
  -- from, so a restored generator that drifted would resolve the rest of the
  -- battle differently from the copy that never disconnected.
  local live = Rng.new(7)
  for _ = 1, 10 do live:byte() end
  local restored = Rng.new(0):setState(live:state())
  rngCheck("state_restores", live:byte(), restored:byte())
end

-- ------------------------------------------------------------------

io.write(string.format("battle_sim_vectors: %d passed, %d failed (%s)\n",
  passed, failed, table.concat(counts, " ")))
os.exit(failed == 0 and 0 or 1)
