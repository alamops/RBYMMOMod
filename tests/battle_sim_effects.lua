-- src/BattleSim/Effects.lua: id lookup and stage multipliers.
--
-- Run: luajit tests/battle_sim_effects.lua            (from this folder's root)
--   or luajit mods/rby_mmo/tests/battle_sim_effects.lua  (from the engine)

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
  if not body then error("missing " .. path, 0) end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then error(tostring(err), 0) end
  cache[name] = chunk(need)
  return cache[name]
end

local Effects = need("BattleSim/Effects")

local failures = 0
local function eq(actual, expected, label)
  if actual ~= expected then
    failures = failures + 1
    io.stderr:write(string.format("FAIL %s: expected %s, got %s\n",
      label, tostring(expected), tostring(actual)))
  end
end

eq(Effects.idOf("SLEEP_EFFECT"), 32, "idOf SLEEP_EFFECT")
eq(Effects.nameOf(0), "NO_ADDITIONAL_EFFECT", "nameOf 0")
eq(Effects.nameOf(Effects.idOf("POISON_EFFECT")), "POISON_EFFECT", "round-trip POISON_EFFECT")
eq(Effects.STAGE_MULT[0], 100, "STAGE_MULT neutral")
eq(Effects.stageMult(0), 100, "stageMult neutral")
eq(Effects.stageMult(-6), 25, "stageMult -6")
eq(Effects.stageMult(6), 400, "stageMult +6")
eq(Effects.applyStage(100, 2), 200, "applyStage +2")
eq(Effects.category(32), "status_primary", "category SLEEP")
eq(Effects.category(72), "unused", "category unused slot")
eq(Effects.idOf("NOT_AN_EFFECT"), nil, "idOf unknown")
eq(Effects.nameOf(999), nil, "nameOf out of range")

do
  local effect = Effects.itemEffect("PROTEIN")
  eq(effect and effect.vitaminStat, "atk", "PROTEIN is a vitamin for atk")
  local mon = { level = 100, maxHp = 100, hp = 100, stats = { atk = 40 }, evs = {} }
  local result = Effects.applyVitamin(mon, "PROTEIN")
  eq(result and result.after, 2560, "PROTEIN adds 2560 Stat Exp")
  eq(mon.stats.atk, 52, "level-100 PROTEIN raises atk by 12")
  local capped = {
    level = 100, maxHp = 100, hp = 100, stats = { atk = 40 },
    evs = { atk = 25600 },
  }
  eq(Effects.applyVitamin(capped, "PROTEIN"), nil, "fails at Stat Exp ≥ 25600")
end

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end

print("battle_sim_effects: ok")
