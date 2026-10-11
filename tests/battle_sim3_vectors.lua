-- src/BattleSim3 against the Gen 3 vector pack.
--
-- Run: luajit tests/battle_sim3_vectors.lua      (from this folder's root)
--   or luajit mods/rby_mmo/tests/battle_sim3_vectors.lua  (from the engine)
--
-- Standalone for the reason tests/battle_sim2_vectors.lua gives: the claim
-- src/BattleSim3 makes is that it is pure arithmetic with no love, no engine
-- modules and no mod facade, so the suite loads the shipped files through the
-- same `need`-shaped resolver main.lua uses and parses the fixture with its own
-- small reader.
--
-- tests/fixtures/battle_sim3_vectors.json is the contract, not this file: the
-- Node twin (server/lib/battle3/, wave 3) runs the identical vectors.  Every
-- section is a list of { id, kind?, in, out }; only the keys `out` states are
-- asserted (an explicit null included), and array-valued keys compare element
-- by element.  Sections:
--
--   rng       Rng.new(seed) then roll(lo, hi) per draw -> values, state, count
--   types     Types.typeCalc over the fixture's synthetic ordered chart
--   damage    Damage.calc(Damage.battler(a), Damage.battler(d), move, opts)
--             (`opts.rolls` feed Rng.scripted in draw order; a spec's `badges`
--             is its trainer's, docs/plans/gen3-badge-rules.md K1; its
--             `noDamageBadges` / `noSpeedBadge` / `noSoulDew` and the opts'
--             `critGate` are Turn.create's `rules` / `firstBattle`, contract C3
--             of docs/plans/gen3-solo-remaining-fights.md)
--   base      Damage.base (CalculateBaseDamage, before crit/STAB/chart/roll;
--             the badge boosts' placement)
--   power     hidden power, flail, low kick, magnitude, psywave
--   crit      Crit.stage over a battler + move, Crit.check(stage, roll)
--   accuracy  Accuracy.calc + Accuracy.hit
--   speed     Field.speed (Swift Swim, stages, badge 3, paralysis, Macho Brace,
--             Quick Claw)
--   order     Field.sortRows: priority, speed, one tie roll per tied group
--   status    Status.chip / sleepTick / canApply
--   catch     Catch.multiplier / odds / shakeThreshold / attempt
--   items     Items.flavorRelation (confusion-berry dislikes from the nature)
--   badges    Damage.badgeSet (a K1 badges value -> the badge numbers held, or
--             null when none survive)
--   effects   Effects.forbidden, and which EFFECT_* have a status handler
--   safari    Safari.lua's factors and throws (contract C3's `safari`): the
--             catch / escape factors, a SAFARI BALL's catch rate, the flee
--             rate, BAIT / ROCK / the watching turn (FireRed / LeafGreen), GO
--             NEAR / the POKeBLOCK (Emerald, synthetic tables: the state's
--             lists are pret index i at JSON element i)
--
-- Synthetic numbers only: every stat, power and chart row is invented.

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
    io.stderr:write("battle_sim3_vectors: missing " .. path .. "\n")
    os.exit(1)
  end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then
    io.stderr:write("battle_sim3_vectors: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  cache[name] = chunk(need)
  return cache[name]
end

local Sim = need("BattleSim3/init")
local Damage, Types, Crit, Accuracy = Sim.Damage, Sim.Types, Sim.Crit, Sim.Accuracy
local Status, Catch, Items, Field = Sim.Status, Sim.Catch, Sim.Items, Sim.Field
local Rng, Effects, Safari = Sim.Rng, Sim.Effects, Sim.Safari

-- ------------------------------------------------------------------
-- a JSON reader, just enough for the fixture (null -> NULL, not nil)
-- ------------------------------------------------------------------

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

local FIXTURE = ROOT .. "/tests/fixtures/battle_sim3_vectors.json"
local raw = slurp(FIXTURE)
if not raw then
  io.stderr:write("battle_sim3_vectors: missing " .. FIXTURE .. "\n")
  os.exit(1)
end
local vectors = decodeValue(raw, 1)
local CHART = vectors.typeTable

-- ------------------------------------------------------------------
-- assertions
-- ------------------------------------------------------------------

local passed, failed = 0, 0

local function show(value)
  if value == NULL then return "null" end
  if value == nil then return "nil" end
  if type(value) == "table" then
    local parts = {}
    for i = 1, #value do parts[i] = show(value[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  return tostring(value)
end

local function fail(id, what, expected, actual)
  failed = failed + 1
  io.stderr:write(string.format("FAIL %s: %s expected %s, got %s\n",
    id, what, show(expected), show(actual)))
end

local function same(expected, actual)
  if expected == NULL then return actual == nil end
  if type(expected) == "table" then
    if type(actual) ~= "table" or #expected ~= #actual then return false end
    for i = 1, #expected do
      if not same(expected[i], actual[i]) then return false end
    end
    return true
  end
  return expected == actual
end

local function match(id, out, actual)
  local keys = {}
  for key in pairs(out) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    if same(out[key], actual[key]) then
      passed = passed + 1
    else
      fail(id, key, out[key], actual[key])
    end
  end
end

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
    local ok, actual = pcall(run, case["in"], case.kind)
    if not ok then
      failed = failed + 1
      io.stderr:write(string.format("FAIL %s: threw (%s)\n", case.id, tostring(actual)))
    else
      match(case.id, case.out, actual)
    end
  end
end

local function orNil(value)
  if value == NULL then return nil end
  return value
end

-- A fixture object with NULLs stripped (Damage.battler reads nil as absent).
local function clean(t)
  if type(t) ~= "table" then return orNil(t) end
  local out = {}
  for k, v in pairs(t) do
    if v ~= NULL then out[k] = (type(v) == "table") and clean(v) or v end
  end
  return out
end

-- ------------------------------------------------------------------
-- sections
-- ------------------------------------------------------------------

each("rng", function(input)
  local r = Rng.new(input.seed)
  local values = {}
  for i, d in ipairs(input.draws) do values[i] = r:roll(d[1], d[2]) end
  return { values = values, state = r:state(), count = r.draws }
end)

each("types", function(input)
  local dmg, flags, product = Types.typeCalc(CHART, input.atk, input.def1, orNil(input.def2),
    orNil(input.dmg), input.foresight)
  return { dmg = dmg, super = flags.super, notVery = flags.notVery, immune = flags.immune,
           product = product }
end)

each("damage", function(input)
  local opts = clean(input.opts)
  opts.typeTable = CHART
  if opts.rolls then opts.rng = Rng.scripted(opts.rolls) end
  local d, info = Damage.calc(Damage.battler(clean(input.attacker)),
    Damage.battler(clean(input.defender)), clean(input.move), opts)
  return {
    damage = d, critical = info.critical == true, effectiveness = info.effectiveness,
    moveType = info.moveType, power = info.power, stab = info.stab == true,
    failed = info.failed, status = info.status,
  }
end)

each("base", function(input)
  local opts = clean(input.opts)
  if opts.specialTypes then
    local set = {}
    for k, v in pairs(opts.specialTypes) do set[tonumber(k)] = v end
    opts.specialTypes = set
  end
  return { damage = Damage.base(Damage.battler(clean(input.attacker)),
    Damage.battler(clean(input.defender)), clean(input.move), opts) }
end)

each("power", function(input, kind)
  if kind == "hiddenPower" then
    local p, t = Damage.hiddenPower(input.ivs)
    return { power = p, type = t }
  elseif kind == "flail" then
    return { power = Damage.flailPower(input.hp, input.maxHp) }
  elseif kind == "lowKick" then
    return { power = Damage.lowKickPower(input.weight) }
  elseif kind == "magnitude" then
    local value, power = Damage.magnitude(input.roll)
    return { value = value, power = power }
  elseif kind == "psywave" then
    return { damage = Damage.psywave(input.level, input.roll) }
  end
  error("unknown power kind " .. tostring(kind), 0)
end)

each("crit", function(input, kind)
  if kind == "stage" then
    local stage = Crit.stage(Damage.battler(clean(input.attacker)), clean(input.move))
    return { stage = stage, chance = Crit.chance(stage) }
  elseif kind == "check" then
    local isCrit, chance = Crit.check(input.stage, input.roll)
    return { isCrit = isCrit, chance = chance }
  end
  error("unknown crit kind " .. tostring(kind), 0)
end)

each("accuracy", function(input)
  local o = clean(input)
  local calc = Accuracy.calc(o.accuracy, o)
  local hit = Accuracy.hit(calc, o.roll)
  return { calc = calc, hit = hit }
end)

each("speed", function(input)
  return { speed = Field.speed(Damage.battler(clean(input.battler)), orNil(input.weather),
    orNil(input.quickClawNumber)) }
end)

each("order", function(input)
  local rows = {}
  for i, r in ipairs(input.rows) do rows[i] = { pri = r.pri, spe = r.spe, order = i } end
  local rng = Rng.scripted(input.rolls)
  Field.sortRows(rows, rng, 128)
  local order = {}
  for i, r in ipairs(rows) do order[i] = r.order end
  return { order = order, draws = rng.draws }
end)

each("status", function(input, kind)
  if kind == "chip" then
    local amount, counter = Status.chip(input.status, input.maxHp, input.toxicCounter)
    return { amount = amount, counter = counter }
  elseif kind == "sleepTick" then
    local left, woke = Status.sleepTick(input.turns, input.earlyBird)
    return { left = left, woke = woke }
  elseif kind == "canApply" then
    local ok, reason = Status.canApply(Damage.battler(clean(input.battler)), input.status, clean(input.ctx))
    return { ok = ok, reason = reason }
  end
  error("unknown status kind " .. tostring(kind), 0)
end)

each("catch", function(input, kind)
  if kind == "multiplier" then
    return { multiplier = Catch.multiplier(input.ball, clean(input.ctx)) }
  elseif kind == "odds" then
    return { odds = Catch.odds(input.ball, input.catchRate, input.hp, input.maxHp,
      orNil(input.status), clean(input.ctx)) }
  elseif kind == "threshold" then
    return { threshold = Catch.shakeThreshold(input.odds) }
  elseif kind == "attempt" then
    local rng = Rng.scripted(input.rolls)
    local caught, shakes, odds = Catch.attempt(input.ball, { mon = clean(input.mon) }, rng, clean(input.ctx))
    return { caught = caught, shakes = shakes, odds = odds, draws = rng.draws }
  end
  error("unknown catch kind " .. tostring(kind), 0)
end)

each("items", function(input, kind)
  if kind == "flavor" then
    return { relation = Items.flavorRelation(input.nature, input.flavor) }
  end
  error("unknown items kind " .. tostring(kind), 0)
end)

each("badges", function(input)
  local set = Damage.badgeSet(clean(input.raw))
  if not set then return { held = nil } end
  local held = {}
  for n = 1, 8 do
    if set[n] == true then held[#held + 1] = n end
  end
  return { held = held }
end)

each("effects", function(input, kind)
  if kind == "forbidden" then
    return { forbidden = Effects.forbidden(input.num, input.stopAtSentinel) }
  elseif kind == "handles" then
    local handled = {}
    for id = input.from, input.to do handled[#handled + 1] = Effects.handles(id) end
    return { handled = handled }
  end
  error("unknown effects kind " .. tostring(kind), 0)
end)

each("safari", function(input, kind)
  if kind == "catchFactor" then
    return { factor = Safari.catchFactor(input.catchRate) }
  elseif kind == "escapeFactor" then
    return { factor = Safari.escapeFactor(input.fleeRate) }
  elseif kind == "ballCatchRate" then
    return { catchRate = Safari.ballCatchRate(input.factor) }
  elseif kind == "fleeRate" then
    return { rate = Safari.fleeRate(clean(input.state)) }
  elseif kind == "bait" or kind == "rock" then
    local s = clean(input.state)
    Safari[kind](s, input.roll)
    return { bait = s.bait, rock = s.rock, catchFactor = s.catchFactor }
  elseif kind == "watch" then
    local s = clean(input.state)
    local reaction = Safari.watch(s)
    return { reaction = reaction, rock = s.rock, bait = s.bait, catchFactor = s.catchFactor }
  elseif kind == "goNear" then
    local s = clean(input.state)
    local closer = Safari.goNear(s)
    return { closer = closer, goNear = s.goNear, catchFactor = s.catchFactor, escapeFactor = s.escapeFactor }
  elseif kind == "block" then
    local s = clean(input.state)
    Safari.block(s, input.verdict)
    return { escapeFactor = s.escapeFactor, pkblCounter = s.pkblCounter,
             pokeblockThrows = s.pokeblockThrows }
  end
  error("unknown safari kind " .. tostring(kind), 0)
end)

-- ------------------------------------------------------------------
-- Rng properties the fixture cannot state as values
-- ------------------------------------------------------------------

local function check(what, ok)
  if ok then passed = passed + 1 else fail("rng_" .. what, what, true, false) end
end

do
  local a, b = Rng.new(12345), Rng.new(12345)
  local sameStream = true
  for _ = 1, 64 do
    if a:roll(0, 255) ~= b:roll(0, 255) then sameStream = false end
  end
  check("same_seed_same_stream", sameStream)

  local e = Rng.new(99)
  local inBand = true
  for _ = 1, 512 do
    local r = e:damageRoll()
    if r < Damage.ROLL_MIN or r > Damage.ROLL_MAX then inBand = false end
  end
  check("damage_roll_stays_in_band", inBand)

  local live = Rng.new(7)
  for _ = 1, 10 do live:roll(0, 99) end
  local restored = Rng.new(0):setState(live:state())
  check("state_restores", live:roll(0, 65535) == restored:roll(0, 65535))

  -- A coin must not be a rota: over 256 flips both faces appear in runs.
  local c = Rng.new(1)
  local prev, runs = nil, 0
  for _ = 1, 256 do
    local v = c:roll(0, 1)
    if v == prev then runs = runs + 1 end
    prev = v
  end
  check("coin_is_not_alternating", runs > 64)
end

io.write(string.format("battle_sim3_vectors: %d passed, %d failed (%s)\n",
  passed, failed, table.concat(counts, " ")))
os.exit(failed == 0 and 0 or 1)
