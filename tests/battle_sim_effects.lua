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

local function apply(effectId, user, target, extra)
  local ctx = {
    effectId = effectId,
    rng = { byte = function() return 0 end },
    userMon = user,
    targetMon = target,
    userFighter = dummyFighter(1, "a"),
    targetFighter = dummyFighter(2, "b"),
    moveIndex = 1,
  }
  for k, v in pairs(extra or {}) do ctx[k] = v end
  return Effects.applyPrimary(ctx)
end

-- R1c: only the routines that ask CheckTargetSubstitute -- the primary
-- stat drops, PoisonEffect, ConfusionEffect -- stop at a doll (effects.asm
-- :1436-1446).  SleepEffect, TransformEffect_ and MimicEffect never ask.
do
  local user = dummyMon()
  local target = dummyMon({ species = "Beta", substitute = 40 })
  -- A generator stuck on 0 would spin `.setSleepCounter` forever on the
  -- cart; the referee's REDRAW_GUARD answers 1 instead.
  local out = apply(32, user, target)
  eq(out.nothing, false, "SLEEP_EFFECT reaches the monster behind a substitute")
  eq(target.status, "sleep", "SLEEP_EFFECT lands through a substitute")
  eq(target.statusTurns, 1, "a stream of zero bytes is the guard's 1 turn, not a hang")
  eq(target.substitute, 40, "...and the doll stands")
end

do
  local user = dummyMon()
  local target = dummyMon({ species = "Beta", substitute = 40 })
  local out = apply(49, user, target)
  eq(out.nothing, true, "CONFUSION_EFFECT vs substitute is nothing (CheckTargetSubstitute)")
  eq(target.confusion, nil, "CONFUSION_EFFECT does not confuse through a substitute")
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
  -- DisableEffect never asks CheckTargetSubstitute (R1b, effects.asm
  -- :1286-1367): its only test is MoveHitTest, whose doll check is the
  -- broken drain one -- so it reaches the monster behind the doll.
  local out = apply(86, user, target)
  eq(out.nothing, false, "DISABLE_EFFECT is not stopped by a substitute")
  eq(target.disable ~= nil, true, "DISABLE_EFFECT locks a move behind a substitute")
end

do
  local user = dummyMon()
  local target = dummyMon({ species = "Beta", substitute = 40 })
  local out = apply(57, user, target)
  eq(out.nothing, false, "TRANSFORM_EFFECT goes through a substitute")
  eq(user.transformed, true, "TRANSFORM_EFFECT copies the monster behind a substitute")
end

do
  local user = dummyMon({ moves = {
    { id = "MIMIC", name = "MIMIC", pp = 7, maxPp = 10, ppUps = 0, power = 0,
      accuracy = 255, type = 0, effect = 82, chance = 0 },
  } })
  local target = dummyMon({ species = "Beta", substitute = 40 })
  local out = apply(82, user, target, { mimicSlot = 1 })
  eq(out.nothing, false, "MIMIC_EFFECT goes through a substitute")
  eq(user.moves[1] and user.moves[1].id, "thump", "MIMIC_EFFECT copies the picked move behind a doll")
  eq(user.moves[1] and user.moves[1].pp, 7, "...and the slot keeps MIMIC's PP (`ld [hl], a` writes the id alone)")
  Effects.restoreMoves(user)
  eq(user.moves[1] and user.moves[1].id .. ":" .. user.moves[1].pp, "MIMIC:7",
     "a switch-out gives the party's MIMIC back, at the slot's PP")
  local missed = apply(82, user, target, {})
  eq(missed.messages[1], "But it failed", "MIMIC with no pick fails")
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

-- The stored-stat machinery (Effects' "Stored battle stats" note), on bare
-- monster tables: CalculateModifiedStat's two clamps, StatModifierUp/Down's
-- one each, the walls, the penalty, and the glitch re-runs.
eq(Effects.applyStage(1, -6), 1, "applyStage floors at 1 (1 x 25/100 = 0)")
eq(Effects.applyStage(500, 2), 999, "applyStage caps at 999")
do
  local mon = dummyMon()
  Effects.ensureBattleStats(mon)
  eq(mon.cur.atk, 40, "a bare monster gets battle stats from its stats")
  eq(mon.partyStats.atk, 40, "...and a party struct")
  local seat = dummyFighter(0, "a")
  seat.badges = { BOULDERBADGE = true, SOULBADGE = true }
  local outcome, stage = Effects.changeStat({ mon = mon, fighter = seat, stat = "atk",
    delta = 1, mover = seat })
  eq(outcome, "rose", "a raise rises")
  eq(stage, 1, "...to +1")
  -- 40 x 150/100 = 60 -> +7 = 67; Speed 40 -> +5 = 45 (the badge re-run).
  eq(mon.cur.atk, 67, "the raised stat is rebuilt, then badge-boosted")
  eq(mon.cur.spd, 45, "...and every other badge stat is boosted too")

  local foe = dummyMon({ species = "Beta", status = "paralysis" })
  Effects.ensureBattleStats(foe)
  Effects.changeStat({ mon = mon, fighter = seat, stat = "acc", delta = 1,
    mover = seat, nonMover = foe })
  eq(foe.cur.spd, 10, "the re-penalty quarters the paralysed non-mover: 40 -> 10")

  mon.cur.atk = 999
  local before = mon.stages.atk
  outcome, stage = Effects.changeStat({ mon = mon, fighter = seat, stat = "atk",
    delta = 2, mover = seat })
  eq(outcome, "stuck", "a raise on 999 fails")
  eq(stage, before + 1, "...and a +2 nets +1")

  local low = dummyMon({ species = "Gamma" })
  Effects.ensureBattleStats(low)
  low.cur.def = 1
  outcome, stage = Effects.changeStat({ mon = low, fighter = dummyFighter(3, "b"),
    stat = "def", delta = -1, mover = seat })
  eq(outcome, "stuck", "a drop on 1 fails")
  eq(stage, 0, "...the stage wound back")
  low.stages.def = -6
  eq((Effects.changeStat({ mon = low, fighter = dummyFighter(3, "b"), stat = "def",
    delta = -1, mover = seat })), "min", "-6 cannot go lower")

  local burned = dummyMon({ status = "burn" })
  Effects.ensureBattleStats(burned)
  Effects.applyStatusPenalty(burned)
  eq(burned.cur.atk, 20, "a burn halves the stored Attack")
  Effects.loadBattleStats(burned, { BOULDERBADGE = true })
  eq(burned.cur.atk, 22, "a switch-in: 40 -> 20 -> +2 = 22")
end

-- CantLowerAnymore (pokered effects.asm): `cp ATTACK_DOWN_SIDE_EFFECT; ret nc`
-- -- a side-effect drop that finds the stage already at -6 fails without a
-- word, as it does at a stat of 1; a primary at -6 still prints its line.
do
  local function floored()
    local mon = dummyMon({ species = "Beta" })
    Effects.ensureBattleStats(mon)
    mon.stages.spd = -6
    return mon
  end
  local sideTarget = floored()
  local side = Effects.applySide({
    effectId = 70, chance = 100, rng = { byte = function() return 0 end },
    targetMon = sideTarget, targetFighter = dummyFighter(3, "b"),
    userFighter = dummyFighter(0, "a"),
  })
  eq(side.proc, true, "the side effect procs")
  eq(#side.messages, 0, "and says nothing at -6")
  eq(#side.events, 0, "nor emits a stat event")
  eq(sideTarget.stages.spd, -6, "the stage stays at -6")

  local primary = apply(20, dummyMon(), floored())
  -- CantLowerAnymore's NothingHappenedText (R1b, effects.asm :705-710).
  eq(primary.messages[1], "Nothing happened", "the primary at -6 says so")
  eq(#primary.messages, 1, "...once")
end

-- Red's side-effect odds, re-derived from the expressions pokered writes them
-- as (engine/battle/effects.asm, RGBDS `percent` = `* $ff / 100`), so a typo in
-- the table cannot hide behind a vector built from the same typo.
do
  local function percent(n) return math.floor(n * 255 / 100) end
  local CART = {
    [2] = percent(20) + 1, [77] = percent(20) + 1, [33] = percent(40) + 1,
    [4] = percent(10) + 1, [5] = percent(10) + 1, [6] = percent(10) + 1,
    [34] = percent(30) + 1, [35] = percent(30) + 1, [36] = percent(30) + 1,
    [31] = percent(10) + 1, [37] = percent(30) + 1,
    [68] = percent(33) + 1, [69] = percent(33) + 1, [70] = percent(33) + 1,
    [71] = percent(33) + 1, [76] = percent(10),
  }
  local count = 0
  for id, threshold in pairs(Effects.SIDE_THRESHOLD) do
    count = count + 1
    eq(threshold, CART[id], "SIDE_THRESHOLD[" .. id .. "] is the cart's expression")
    eq(Effects.sideThreshold(id, 0), CART[id], "chance 0 reads it for effect " .. id)
  end
  eq(count, 16, "sixteen side-effect ids, no more")
  eq(Effects.COMPUTER_DROP_MISS, percent(25) + 1, "the computer's drop miss is 25 percent + 1")
  eq(Effects.sideThreshold(4, 30), percent(30), "an explicit percent has no + 1")
  eq(Effects.sideThreshold(0, 100), 0, "no routine, no threshold")
end

eq(Effects.itemFailsOnFainted(Effects.itemEffect("POTION")), true,
   "Potion fails on a fainted mon")
eq(Effects.itemFailsOnFainted(Effects.itemEffect("ETHER")), true,
   "Ether fails on a fainted mon")
eq(Effects.itemFailsOnFainted(Effects.itemEffect("ANTIDOTE")), true,
   "Antidote fails on a fainted mon")
eq(Effects.itemFailsOnFainted(Effects.itemEffect("PROTEIN")), true,
   "Protein fails on a fainted mon")
eq(Effects.itemFailsOnFainted(Effects.itemEffect("REVIVE")), false,
   "Revive is faintedOnly, not a fail-on-fainted")
eq(Effects.itemFailsOnFainted(nil), false, "nil effect is not fail-on-fainted")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end

print("battle_sim_effects: ok")
