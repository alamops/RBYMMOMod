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

local function dummyMon(o)
  o = o or {}
  return {
    species = o.species or "Alpha",
    hp = o.hp or 100,
    maxHp = o.maxHp or 100,
    status = o.status,
    types = o.types or { 0 },
    stats = { atk = 40, def = 40, spd = 40, spc = 40 },
    stages = { atk = 0, def = 0, spd = 0, spc = 0, acc = 0, eva = 0 },
    moves = o.moves or {
      { id = "thump", name = "THUMP", pp = 10, power = 40,
        accuracy = 255, type = 0, effect = 0, chance = 0 },
    },
    lastMoveIndex = o.lastMoveIndex or 1,
    substitute = o.substitute or 0,
  }
end

local function dummyFighter(slot, side)
  return { slot = slot or 1, side = side or "a" }
end

local function apply(effectId, user, target)
  return Effects.applyPrimary({
    effectId = effectId,
    rng = { byte = function() return 0 end },
    userMon = user,
    targetMon = target,
    userFighter = dummyFighter(1, "a"),
    targetFighter = dummyFighter(2, "b"),
    moveIndex = 1,
  })
end

do
  local user = dummyMon()
  local target = dummyMon({ species = "Beta", substitute = 40 })
  local out = apply(32, user, target)
  eq(out.nothing, true, "SLEEP_EFFECT vs substitute is nothing")
  eq(target.status, nil, "SLEEP_EFFECT does not land through a substitute")
end

do
  local user = dummyMon()
  local target = dummyMon({ species = "Beta", substitute = 40 })
  local out = apply(18, user, target)
  eq(out.nothing, true, "Growl vs substitute is nothing")
  eq(target.stages.atk, 0, "Growl does not drop atk behind a substitute")
end

do
  local user = dummyMon()
  local target = dummyMon({ species = "Beta", substitute = 40, lastMoveIndex = 1 })
  local out = apply(86, user, target)
  eq(out.nothing, true, "DISABLE_EFFECT vs substitute is nothing")
  eq(target.disable, nil, "DISABLE_EFFECT does not lock a move behind a substitute")
end

do
  local user = dummyMon()
  local target = dummyMon({ species = "Beta", substitute = 40 })
  local out = apply(57, user, target)
  eq(out.nothing, true, "TRANSFORM_EFFECT vs substitute is nothing")
  eq(user.transformed, nil, "TRANSFORM_EFFECT does not copy through a substitute")
end

do
  local user = dummyMon()
  local target = dummyMon({ species = "Beta", substitute = 40, lastMoveIndex = 1 })
  local out = apply(82, user, target)
  eq(out.nothing, true, "MIMIC_EFFECT vs substitute is nothing")
  eq(user.moves[1] and user.moves[1].id, "thump", "MIMIC_EFFECT does not copy through a substitute")
end

do
  local user = dummyMon()
  local target = dummyMon({ species = "Beta", substitute = 40 })
  local out = apply(50, user, target)
  eq(out.nothing, false, "Swords Dance is not nothing against a foe substitute")
  eq(user.stages.atk, 2, "Swords Dance still raises the user's atk")
  eq(target.stages.atk, 0, "Swords Dance does not touch the foe behind a substitute")
end

do
  local user = dummyMon({ hp = 10, maxHp = 100 })
  local target = dummyMon({ species = "Beta", substitute = 40 })
  local out = apply(56, user, target)
  eq(out.nothing, false, "HEAL_EFFECT is not nothing against a foe substitute")
  eq(#out.heals, 1, "HEAL_EFFECT still queues a heal")
end

do
  local user = dummyMon({ hp = 100, maxHp = 100 })
  local target = dummyMon({ species = "Beta", substitute = 40 })
  local out = apply(79, user, target)
  eq(out.nothing, false, "SUBSTITUTE_EFFECT is not nothing against a foe substitute")
  eq(user.substitute > 0, true, "user can still make their own substitute")
end

do
  local user = dummyMon()
  user.stages.atk = 2
  local target = dummyMon({ species = "Beta", substitute = 40 })
  target.stages.def = 2
  local out = apply(25, user, target)
  eq(out.nothing, false, "HAZE_EFFECT is not nothing against a substitute")
  eq(user.stages.atk, 0, "HAZE_EFFECT still resets the user")
  eq(target.stages.def, 0, "HAZE_EFFECT still resets the foe behind a substitute")
end

do
  local user = dummyMon()
  local target = dummyMon({ species = "Beta" })
  local out = apply(32, user, target)
  eq(out.nothing, false, "SLEEP_EFFECT still lands with no substitute")
  eq(target.status, "sleep", "SLEEP_EFFECT sets sleep when the target is exposed")
end

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
