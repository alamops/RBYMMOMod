-- src/BattleSim2/AiMove.lua: pokecrystal's AIChooseMove over the Gold referee.
--
-- Run: luajit tests/battle_sim2_ai_move.lua              (from this folder's root)
--   or luajit mods/rby_mmo/tests/battle_sim2_ai_move.lua (from the engine)
--
-- Every scenario is a battle built through BattleSim2/Turn's `create` with a
-- synthetic sheet, the AI's state patched onto the monsters, and the RNG
-- replaced by a script of bytes -- so each threshold is pinned at the cart's
-- own byte (`cp 20 percent - 1` is 50, `cp 50 percent + 1` is 128, ...) and
-- the count of bytes the layers take is asserted with the scores.  Each
-- expectation is read off engine/battle/ai/move.asm / scoring.asm /
-- redundant.asm (pokecrystal; pokegold where Gold differs), never off the
-- module: the scenario names the label.  server/battle2_ai_move.test.js runs
-- the same scenarios against the Node twin.
--
-- Synthetic throughout: the chart, the stats and the species are invented;
-- the move ids are only the keys the cart's own lists name.

local ROOT = "."
do
  local invoked = arg and arg[0]
  local dir = invoked and invoked:match("^(.*)[/\\]tests[/\\][^/\\]+$")
  if dir and dir ~= "" then ROOT = dir end
end

local loadstr = loadstring or load
local cache = {}
local function need(name)
  if cache[name] ~= nil then return cache[name] end
  local path = ROOT .. "/src/" .. name .. ".lua"
  local handle = io.open(path, "rb")
  if not handle then
    io.stderr:write("battle_sim2_ai_move: missing " .. path .. "\n")
    os.exit(1)
  end
  local body = handle:read("*a")
  handle:close()
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then
    io.stderr:write("battle_sim2_ai_move: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  cache[name] = chunk(need)
  return cache[name]
end

local Turn = need("BattleSim2/Turn")
local Effects = need("BattleSim2/Effects")
local AiMove = need("BattleSim2/AiMove")

local passed, failed = 0, 0
local function eq(actual, expected, what)
  if actual == expected then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format("FAIL %s: expected %s, got %s\n",
      tostring(what), tostring(expected), tostring(actual)))
  end
end
local function listStr(list)
  if type(list) ~= "table" then return tostring(list) end
  local out = {}
  for i = 1, #list do out[i] = tostring(list[i]) end
  return table.concat(out, ",")
end

-- ------------------------------------------------------------------
-- the synthetic field
-- ------------------------------------------------------------------

local TYPES = { "NORMAL", "FIRE", "WATER", "GRASS", "GHOST", "POISON", "ROCK",
  "FIGHTING", "STEEL", "GROUND", "FLYING", "DARK" }
local T = {}
for i, name in ipairs(TYPES) do T[name] = i - 1 end
local CHART = {}
for a = 1, #TYPES do
  CHART[a] = {}
  for d = 1, #TYPES do CHART[a][d] = 100 end
end
local function cell(att, def, pct) CHART[T[att] + 1][T[def] + 1] = pct end
cell("FIRE", "GRASS", 200); cell("FIRE", "WATER", 50); cell("FIRE", "FIRE", 50); cell("FIRE", "ROCK", 50)
cell("WATER", "FIRE", 200); cell("WATER", "ROCK", 200); cell("WATER", "WATER", 50); cell("WATER", "GRASS", 50)
cell("GRASS", "WATER", 200); cell("GRASS", "FIRE", 50); cell("GRASS", "GRASS", 50)
cell("NORMAL", "GHOST", 0); cell("NORMAL", "ROCK", 50)
cell("FIGHTING", "GHOST", 0); cell("FIGHTING", "NORMAL", 200)
cell("POISON", "POISON", 50); cell("POISON", "STEEL", 0); cell("POISON", "GRASS", 200)
cell("GHOST", "NORMAL", 0); cell("ROCK", "FIRE", 200); cell("GROUND", "FLYING", 0)
local SPECIAL = { T.FIRE, T.WATER, T.GRASS, T.DARK }

local function fx(name)
  return Effects.idOf(name) or 0
end

-- A move: id, the cart effect it carries (by name), power, type, extras.
local function mv(id, effect, power, typeName, extra)
  local m = { id = id, pp = 10, power = power or 0, accuracy = 255,
              type = T[typeName or "NORMAL"], effect = fx(effect or "EFFECT_NORMAL_HIT") }
  for k, v in pairs(extra or {}) do m[k] = v end
  return m
end

-- A used / last move record (wPlayerUsedMoves, wLastPlayer*Move).
local function rec(id, effect, power, typeName)
  return { id = id, power = power or 0, type = T[typeName or "NORMAL"],
           effect = fx(effect or "EFFECT_NORMAL_HIT"), accuracy = 255 }
end

local SHEET_KEYS = { level = true, hp = true, maxHp = true, stats = true, types = true,
  moves = true, status = true, statusTurns = true, stages = true, dvs = true, base = true }

local function sheet(o, defaults)
  local s = {
    species = o.species or defaults.species, level = o.level or 50,
    hp = o.hp or 100, maxHp = o.maxHp or 100,
    stats = { atk = 50, def = 50, spe = o.spe or defaults.spe, spa = 50, spd = 50 },
    types = o.types or defaults.types, moves = o.moves or { mv("TACKLE", nil, 40) },
    status = o.status, statusTurns = o.statusTurns, stages = o.stages,
    dvs = o.dvs, base = o.base,
  }
  return s
end

local function patch(mon, o)
  for k, v in pairs(o) do
    if not SHEET_KEYS[k] and k ~= "spe" and k ~= "species" then mon[k] = v end
  end
end

-- A scripted Random: the bytes in order, then 0, 1, 2, 3, 0, ... -- the
-- low two bits `.ChooseMove` reads, so the pick ends on the first kept slot.
local function script(bytes)
  local s = { i = 0 }
  function s:byte()
    self.i = self.i + 1
    local b = bytes[self.i]
    if b == nil then return (self.i - #bytes - 1) % 4 end
    return b
  end
  return s
end

-- me: the computer's monster (side b); foe: the player's (side a).
local function fight(s)
  local meMons = { sheet(s.me or {}, { species = "ME", spe = 50, types = { T.DARK } }) }
  for _, extra in ipairs(s.meBench or {}) do
    meMons[#meMons + 1] = sheet(extra, { species = "MEB", spe = 10, types = { T.DARK } })
  end
  local foeMons = { sheet(s.foe or {}, { species = "FOE", spe = 60, types = { T.NORMAL } }) }
  for _, extra in ipairs(s.foeBench or {}) do
    foeMons[#foeMons + 1] = sheet(extra, { species = "FOEB", spe = 10, types = { T.NORMAL } })
  end
  local b, err = Turn.create({
    mode = s.mode or "coop_npc", seed = 1, chart = CHART, typeIds = TYPES,
    specialTypes = SPECIAL,
    sides = { a = { { playerId = "p", family = s.family or "gs", mons = foeMons } },
              b = { { playerId = "npc", mons = meMons } } },
  })
  if not b then error("create: " .. tostring(err)) end
  local p, npc = b.bySide.a[1], b.bySide.b[1]
  patch(npc.mons[1], s.me or {})
  patch(p.mons[1], s.foe or {})
  for i, extra in ipairs(s.meBench or {}) do patch(npc.mons[i + 1], extra) end
  if s.weather then b.weather = { kind = s.weather, turns = 3 } end
  for side, list in pairs(s.screens or {}) do
    for k, v in pairs(list) do b.screens[side][k] = v end
  end
  npc.aiFlags = s.flags
  return b, npc, p
end

local function run(s)
  local b, npc, p = fight(s)
  local rng = script(s.bytes or {})
  b.rng = rng
  local r = AiMove.evaluate(b, npc, p, s.opts)
  local tag = s.name
  if s.reason ~= nil then eq(r.reason, s.reason, tag .. " reason") end
  if s.scores then
    -- The slots past the sheet's moves have no PP: 80 (`.CheckMovePP`).
    local want = {}
    for i = 1, 4 do want[i] = s.scores[i] or 80 end
    eq(listStr(r.scores), listStr(want), tag .. " scores")
  end
  if s.draws then eq(r.layerDraws, s.draws, tag .. " layer draws") end
  if s.slot then eq(r.slot, s.slot, tag .. " slot") end
  if s.total then eq(r.draws, s.total, tag .. " draws") end
  eq(rng.i, r.draws, tag .. " every byte counted")
  return r, b, npc, p
end

-- ------------------------------------------------------------------
-- the scenarios
-- ------------------------------------------------------------------

local F = { BASIC = 1, SETUP = 2, TYPES = 4, OFFENSIVE = 8, SMART = 16, OPPORTUNIST = 32,
            AGGRESSIVE = 64, CAUTIOUS = 128, STATUS = 256, RISKY = 512 }

local SCENARIOS = {
  -- AIChooseMove: 20 a slot, 80 for wEnemyDisabledMove and for no PP (an
  -- empty slot too); the countdown stops at the first slot to reach 0, and
  -- `.ChooseMove` redraws until its low two bits name a slot scoring 1.
  { name = "frame: disabled and empty-PP slots", flags = 0,
    me = { moves = { mv("TACKLE", nil, 40), mv("SCRATCH", nil, 40, nil, { pp = 0 }), mv("POUND", nil, 40) },
           disable = { moveIndex = 3, turns = 2 } },
    bytes = { 3, 2, 1, 0 }, scores = { 20, 80, 80, 80 }, draws = 0, slot = 1, total = 4 },
  { name = "frame: the lowest scores share the pick", flags = F.OFFENSIVE,
    me = { moves = { mv("TACKLE", nil, 40), mv("GROWL", "EFFECT_ATTACK_DOWN"), mv("SCRATCH", nil, 40),
                     mv("LEER", "EFFECT_DEFENSE_DOWN") } },
    bytes = { 1, 3, 2 }, scores = { 20, 22, 20, 22 }, draws = 0, slot = 3, total = 3 },
  { name = "frame: wild monsters attack at random (no score, no byte)", mode = "wild", flags = 1023,
    reason = "wild", total = 0 },
  { name = "frame: a link battle picks nothing", mode = "1v1", flags = 1023, reason = "link", total = 0 },
  { name = "frame: CheckEnemyLockedIn (recharge)", flags = 1023, me = { mustRecharge = true },
    reason = "locked", total = 0 },
  { name = "frame: CheckEnemyLockedIn (ROLLOUT)", flags = 1023,
    me = { rollout = { count = 1, active = true, moveIndex = 1 } }, reason = "locked", total = 0 },
  { name = "frame: opts.aiFlags over fighter.aiFlags", flags = F.OFFENSIVE, opts = { aiFlags = 0 },
    me = { moves = { mv("TACKLE", nil, 40), mv("GROWL", "EFFECT_ATTACK_DOWN") } },
    bytes = { 0 }, scores = { 20, 20 }, draws = 0, slot = 1 },

  -- AI_Basic: AI_Redundant, then the status-only effects.
  { name = "AI_Basic: DREAM EATER awake, LIGHT SCREEN up, SLEEP statused, FUTURE SIGHT never",
    flags = F.BASIC,
    me = { moves = { mv("DREAM_EATER", "EFFECT_DREAM_EATER", 100, "DARK"),
                     mv("LIGHT_SCREEN", "EFFECT_LIGHT_SCREEN"), mv("HYPNOSIS", "EFFECT_SLEEP"),
                     mv("FUTURE_SIGHT", "EFFECT_FUTURE_SIGHT", 80, "DARK") } },
    foe = { status = "poison" }, screens = { b = { lightScreen = 3 } },
    scores = { 30, 30, 30, 20 }, draws = 0 },
  { name = "AI_Basic: NIGHTMARE passes any status (bug), TELEPORT, HEAL at max HP, CONFUSE vs SAFEGUARD",
    flags = F.BASIC,
    me = { moves = { mv("NIGHTMARE", "EFFECT_NIGHTMARE"), mv("TELEPORT", "EFFECT_TELEPORT"),
                     mv("RECOVER", "EFFECT_HEAL"), mv("SUPERSONIC", "EFFECT_CONFUSE") } },
    foe = { status = "poison" }, screens = { a = { safeguard = 2 } },
    scores = { 20, 30, 30, 30 }, draws = 0 },
  { name = "AI_Basic: genderless ATTRACT, SNORE awake, SLEEP into SAFEGUARD, MEAN LOOK held",
    flags = F.BASIC,
    me = { moves = { mv("ATTRACT", "EFFECT_ATTRACT"), mv("SNORE", "EFFECT_SNORE", 40),
                     mv("HYPNOSIS", "EFFECT_SLEEP"), mv("MEAN_LOOK", "EFFECT_MEAN_LOOK") },
           meanLook = { slot = 1 } },
    screens = { a = { safeguard = 3 } }, scores = { 30, 30, 30, 30 }, draws = 0 },
  { name = "AI_Basic: ATTRACT between opposite genders", flags = F.BASIC,
    me = { moves = { mv("ATTRACT", "EFFECT_ATTRACT") }, base = { gender = 0 },
           dvs = { atk = 1, def = 1, spe = 1, spc = 1 } },
    foe = { base = { gender = 254 }, dvs = { atk = 1, def = 1, spe = 1, spc = 1 } },
    scores = { 20 }, draws = 0 },
  { name = "AI_Basic: ATTRACT into a player already in love", flags = F.BASIC,
    me = { moves = { mv("ATTRACT", "EFFECT_ATTRACT") }, base = { gender = 0 },
           dvs = { atk = 1, def = 1, spe = 1, spc = 1 } },
    foe = { base = { gender = 254 }, dvs = { atk = 1, def = 1, spe = 1, spc = 1 }, inLove = { fromSlot = 1 } },
    scores = { 30 }, draws = 0 },

  -- AI_Setup: up on the enemy's first turn, down on the player's; `jr z`
  -- skips ALWAYS_HIT and TRANSFORM.
  { name = "AI_Setup: first-turn stat-up encouraged, later stat-down discouraged", flags = F.SETUP,
    me = { moves = { mv("MEDITATE", "EFFECT_ATTACK_UP"), mv("GROWL", "EFFECT_ATTACK_DOWN"),
                     mv("SWIFT", "EFFECT_ALWAYS_HIT", 60), mv("TRANSFORM", "EFFECT_TRANSFORM") },
           turnsTaken = 0 },
    foe = { turnsTaken = 2 }, bytes = { 128, 30 }, scores = { 18, 22, 20, 20 }, draws = 2 },
  { name = "AI_Setup: the bytes under 12 percent and 50 percent + 1 change nothing", flags = F.SETUP,
    me = { moves = { mv("AGILITY", "EFFECT_SPEED_UP_2"), mv("SWEET_SCENT", "EFFECT_EVASION_DOWN_2") },
           turnsTaken = 1 },
    foe = { turnsTaken = 0 }, bytes = { 29, 127 }, scores = { 20, 20 }, draws = 2 },
  { name = "AI_Setup: wEnemyTurnsTaken is a byte (256 is a first turn)", flags = F.SETUP,
    me = { moves = { mv("MEDITATE", "EFFECT_ATTACK_UP") }, turnsTaken = 256 },
    bytes = { 200 }, scores = { 18 }, draws = 1 },
  { name = "AI_Setup: the SP. DEF rows sit inside the ranges", flags = F.SETUP,
    me = { moves = { mv("SP_DEF_UP", "EFFECT_SP_DEF_UP"), mv("SP_DEF_DOWN2", "EFFECT_SP_DEF_DOWN_2") },
           turnsTaken = 1 },
    foe = { turnsTaken = 1 }, bytes = { 30, 31 }, scores = { 22, 22 }, draws = 2 },

  -- AI_Types.
  { name = "AI_Types: super-effective, not very effective, no power, neutral", flags = F.TYPES,
    me = { moves = { mv("EMBER", nil, 40, "FIRE"), mv("WATER_GUN", nil, 40, "WATER"),
                     mv("SUNNY_DAY", "EFFECT_SUNNY_DAY", 0, "FIRE"), mv("TACKLE", nil, 40) } },
    foe = { types = { T.GRASS } }, scores = { 19, 21, 20, 20 }, draws = 0 },
  { name = "AI_Types: an immune target dismisses", flags = F.TYPES,
    me = { moves = { mv("TACKLE", nil, 40), mv("LICK", nil, 20, "GHOST") } },
    foe = { types = { T.GHOST } }, scores = { 30, 20 }, draws = 0 },
  { name = "AI_Types: FORESIGHT's identified target reads NORMAL neutral", flags = F.TYPES,
    me = { moves = { mv("TACKLE", nil, 40), mv("LICK", nil, 20, "GHOST") } },
    foe = { types = { T.GHOST }, identified = true }, scores = { 20, 20 }, draws = 0 },
  { name = "AI_Types: not very effective with no other damaging type", flags = F.TYPES,
    me = { moves = { mv("EMBER", nil, 40, "FIRE"), mv("FLAMETHROWER", nil, 90, "FIRE"), mv("GROWL", "EFFECT_ATTACK_DOWN") } },
    foe = { types = { T.FIRE } }, scores = { 20, 20, 20 }, draws = 0 },
  { name = "AI_Types: two rows multiply (x2 x0.5 neutral, x0.5 x0.5 = 2)", flags = F.TYPES,
    me = { moves = { mv("EMBER", nil, 40, "FIRE"), mv("WATER_GUN", nil, 40, "WATER") } },
    foe = { types = { T.GRASS, T.WATER } }, scores = { 20, 21 }, draws = 0 },

  -- AI_Offensive.
  { name = "AI_Offensive: no power +2, power 1 nothing", flags = F.OFFENSIVE,
    me = { moves = { mv("GROWL", "EFFECT_ATTACK_DOWN"), mv("KARATE", nil, 1, "FIGHTING") } },
    scores = { 22, 20 }, draws = 0 },

  -- AI_Opportunist.
  { name = "AI_Opportunist: above half, nothing", flags = F.OPPORTUNIST,
    me = { hp = 60, moves = { mv("SWORDS_DANCE", "EFFECT_ATTACK_UP_2") } }, scores = { 20 }, draws = 0 },
  { name = "AI_Opportunist: between, the 50/50 keeps", flags = F.OPPORTUNIST,
    me = { hp = 40, moves = { mv("SWORDS_DANCE", "EFFECT_ATTACK_UP_2") } }, bytes = { 127 },
    scores = { 20 }, draws = 1 },
  { name = "AI_Opportunist: between, the 50/50 discourages StallMoves", flags = F.OPPORTUNIST,
    me = { hp = 40, moves = { mv("SWORDS_DANCE", "EFFECT_ATTACK_UP_2"), mv("TACKLE", nil, 40),
                              mv("MIST", "EFFECT_MIST"), mv("SUBSTITUTE", "EFFECT_SUBSTITUTE") } },
    bytes = { 128 }, scores = { 21, 20, 21, 21 }, draws = 1 },
  { name = "AI_Opportunist: at a quarter, no byte", flags = F.OPPORTUNIST,
    me = { hp = 25, moves = { mv("GROWL", "EFFECT_ATTACK_DOWN"), mv("TACKLE", nil, 40) } },
    scores = { 21, 20 }, draws = 0 },

  -- AI_Aggressive (AIDamageCalc: DamageCalc + Stab, no roll, no crit).
  { name = "AI_Aggressive: the strongest is spared, power 1 ignored", flags = F.AGGRESSIVE,
    me = { moves = { mv("TACKLE", nil, 40), mv("STRENGTH", nil, 80), mv("EMBER", nil, 60, "FIRE"),
                     mv("KARATE", nil, 1, "FIGHTING") } },
    scores = { 21, 20, 21, 20 }, draws = 0 },
  { name = "AI_Aggressive: a tie goes to the later slot", flags = F.AGGRESSIVE,
    me = { moves = { mv("STRENGTH", nil, 80), mv("SLAM", nil, 80) } }, scores = { 21, 20 }, draws = 0 },
  { name = "AI_Aggressive: RecklessMoves are spared", flags = F.AGGRESSIVE,
    me = { moves = { mv("THRASH", "EFFECT_RAMPAGE", 40), mv("STRENGTH", nil, 80) } },
    scores = { 20, 20 }, draws = 0 },
  { name = "AI_Aggressive: PSYWAVE draws its loop inside AIDamageCalc", flags = F.AGGRESSIVE,
    me = { moves = { mv("PSYWAVE", "EFFECT_PSYWAVE", 1, "DARK"), mv("STRENGTH", nil, 80) } },
    bytes = { 0, 80, 74 }, scores = { 20, 21 }, draws = 3 },
  { name = "AI_Aggressive: SUPER FANG ignores the matchup an immune STRENGTH meets", flags = F.AGGRESSIVE,
    me = { moves = { mv("SUPER_FANG", "EFFECT_SUPER_FANG", 1), mv("STRENGTH", nil, 80) } },
    foe = { types = { T.GHOST } }, scores = { 20, 21 }, draws = 0 },

  -- AI_Cautious.
  { name = "AI_Cautious: the enemy's first turn, nothing", flags = F.CAUTIOUS,
    me = { moves = { mv("MIST", "EFFECT_MIST") }, turnsTaken = 0 }, scores = { 20 }, draws = 0 },
  { name = "AI_Cautious: a byte past 90 percent ends the layer (bug)", flags = F.CAUTIOUS,
    me = { moves = { mv("MIST", "EFFECT_MIST"), mv("LEECH_SEED", "EFFECT_LEECH_SEED"), mv("TACKLE", nil, 40),
                     mv("SPIKES", "EFFECT_SPIKES") }, turnsTaken = 1 },
    bytes = { 229, 230 }, scores = { 21, 20, 20, 20 }, draws = 2 },

  -- AI_Status.
  { name = "AI_Status: TOXIC / POISON into a Poison type", flags = F.STATUS,
    me = { moves = { mv("TOXIC", "EFFECT_TOXIC", 0, "POISON"), mv("POISONPOWDER", "EFFECT_POISON", 0, "POISON"),
                     mv("HYPNOSIS", "EFFECT_SLEEP"), mv("EMBER", nil, 40, "FIRE") } },
    foe = { types = { T.POISON } }, scores = { 30, 30, 20, 20 }, draws = 0 },
  { name = "AI_Status: SLEEP / PARALYZE / a hit into an immunity; a status move skipped", flags = F.STATUS,
    me = { moves = { mv("HYPNOSIS", "EFFECT_SLEEP"), mv("GLARE", "EFFECT_PARALYZE"),
                     mv("LEER", "EFFECT_DEFENSE_DOWN"), mv("TACKLE", nil, 40) } },
    foe = { types = { T.GHOST } }, scores = { 30, 30, 20, 30 }, draws = 0 },
  { name = "AI_Status: TOXIC's own type against a Steel type", flags = F.STATUS,
    me = { moves = { mv("TOXIC", "EFFECT_TOXIC", 0, "POISON") } }, foe = { types = { T.STEEL } },
    scores = { 30 }, draws = 0 },

  -- AI_Risky: past the HP strictly; RiskyEffects skipped at max HP, 80% below.
  { name = "AI_Risky: 37 damage into 36 HP", flags = F.RISKY,
    me = { moves = { mv("STRENGTH", nil, 80) } }, foe = { hp = 36 }, scores = { 15 }, draws = 0 },
  { name = "AI_Risky: 37 damage into 37 HP is no KO", flags = F.RISKY,
    me = { moves = { mv("STRENGTH", nil, 80) } }, foe = { hp = 37 }, scores = { 20 }, draws = 0 },
  { name = "AI_Risky: below max HP the RiskyEffects byte", flags = F.RISKY,
    me = { hp = 99, moves = { mv("SELFDESTRUCT", "EFFECT_SELFDESTRUCT", 40), mv("FISSURE", "EFFECT_OHKO", 1, "GROUND") } },
    foe = { hp = 1 }, bytes = { 199, 200 }, scores = { 20, 15 }, draws = 2 },
  { name = "AI_Risky: at max HP the RiskyEffects are skipped", flags = F.RISKY,
    me = { moves = { mv("SELFDESTRUCT", "EFFECT_SELFDESTRUCT", 40), mv("FISSURE", "EFFECT_OHKO", 1, "GROUND") } },
    foe = { hp = 1 }, scores = { 20, 20 }, draws = 0 },

  -- AI_Smart: the handlers.
  { name = "Smart SLEEP (with DREAM EATER) and DREAM EATER", flags = F.SMART,
    me = { moves = { mv("HYPNOSIS", "EFFECT_SLEEP"), mv("DREAM_EATER", "EFFECT_DREAM_EATER", 100, "DARK") } },
    bytes = { 128, 25 }, scores = { 18, 17 }, draws = 2 },
  { name = "Smart SLEEP alone draws nothing", flags = F.SMART,
    me = { moves = { mv("HYPNOSIS", "EFFECT_SLEEP") } }, scores = { 20 }, draws = 0 },
  { name = "Smart LEECH_HIT not very effective", flags = F.SMART,
    me = { moves = { mv("GIGA_DRAIN", "EFFECT_LEECH_HIT", 20, "GRASS") } }, foe = { types = { T.FIRE } },
    bytes = { 100 }, scores = { 21 }, draws = 1 },
  { name = "Smart LEECH_HIT super effective, hurt", flags = F.SMART,
    me = { hp = 90, moves = { mv("GIGA_DRAIN", "EFFECT_LEECH_HIT", 20, "GRASS") } }, foe = { types = { T.WATER } },
    bytes = { 50 }, scores = { 19 }, draws = 1 },
  { name = "Smart SELFDESTRUCT, Crystal: the last monster against a bench", flags = F.SMART, family = "crystal",
    me = { hp = 40, moves = { mv("SELFDESTRUCT", "EFFECT_SELFDESTRUCT", 130) } }, foeBench = { { hp = 50 } },
    scores = { 23 }, draws = 0 },
  { name = "Smart SELFDESTRUCT, Gold: no last-monster test", flags = F.SMART, family = "gs",
    me = { hp = 40, moves = { mv("SELFDESTRUCT", "EFFECT_SELFDESTRUCT", 130) } }, foeBench = { { hp = 50 } },
    bytes = { 19 }, scores = { 20 }, draws = 1 },
  { name = "Smart HYPER_BEAM, Crystal: cp 16 percent", flags = F.SMART, family = "crystal",
    me = { moves = { mv("HYPER_BEAM", "EFFECT_HYPER_BEAM", 150) } }, bytes = { 40, 128 },
    scores = { 22 }, draws = 2 },
  { name = "Smart HYPER_BEAM, Gold: cp 35 percent + 1", flags = F.SMART, family = "gs",
    me = { moves = { mv("HYPER_BEAM", "EFFECT_HYPER_BEAM", 150) } }, bytes = { 40 },
    scores = { 20 }, draws = 1 },
  { name = "Smart CURSE (Ghost), Crystal: last monster against a bench", flags = F.SMART, family = "crystal",
    me = { types = { T.GHOST }, moves = { mv("CURSE", "EFFECT_CURSE") } }, foeBench = { { hp = 50 } },
    scores = { 24 }, draws = 0 },
  { name = "Smart CURSE (Ghost), Gold: the HP gates and the player's first turn", flags = F.SMART, family = "gs",
    me = { types = { T.GHOST }, moves = { mv("CURSE", "EFFECT_CURSE") } }, foeBench = { { hp = 50 } },
    foe = { turnsTaken = 0 }, bytes = { 128 }, scores = { 18 }, draws = 1 },
  { name = "Smart CURSE (not Ghost) against a Ghost", flags = F.SMART,
    me = { moves = { mv("CURSE", "EFFECT_CURSE") } }, foe = { types = { T.GHOST } },
    scores = { 22 }, draws = 0 },
  { name = "Smart PSYCH_UP, Crystal: the enemy's Evasion gate", flags = F.SMART, family = "crystal",
    me = { moves = { mv("PSYCH_UP", "EFFECT_PSYCH_UP") } }, foe = { stages = { atk = 2 } },
    bytes = { 50 }, scores = { 19 }, draws = 1 },
  { name = "Smart PSYCH_UP, Gold: the player's Evasion read twice", flags = F.SMART, family = "gs",
    me = { moves = { mv("PSYCH_UP", "EFFECT_PSYCH_UP") } }, foe = { stages = { atk = 2 } },
    scores = { 20 }, draws = 0 },
  { name = "Smart PSYCH_UP, Crystal: discouraged by 2", flags = F.SMART, family = "crystal",
    me = { moves = { mv("PSYCH_UP", "EFFECT_PSYCH_UP") }, stages = { atk = 1 } }, scores = { 22 }, draws = 0 },
  { name = "Smart PSYCH_UP, Gold: discouraged by 1", flags = F.SMART, family = "gs",
    me = { moves = { mv("PSYCH_UP", "EFFECT_PSYCH_UP") }, stages = { atk = 1 } }, scores = { 21 }, draws = 0 },
  { name = "Smart THIEF: add $1e", flags = F.SMART,
    me = { moves = { mv("THIEF", nil, 40, "DARK") } }, scores = { 50 }, draws = 0 },
  { name = "Smart MEAN_LOOK reads the enemy's own toxic (bug)", flags = F.SMART,
    me = { status = "toxic", moves = { mv("MEAN_LOOK", "EFFECT_MEAN_LOOK") } }, foeBench = { { hp = 50 } },
    bytes = { 50 }, scores = { 17 }, draws = 1 },
  { name = "Smart FORCE_SWITCH: CheckTypeMatchup reads the move being scored", flags = F.SMART,
    me = { types = { T.GRASS }, moves = { mv("ROAR", "EFFECT_FORCE_SWITCH"), mv("TACKLE", nil, 40) } },
    foe = { types = { T.FIRE }, usedMoves = { rec("EMBER", nil, 40, "FIRE") } },
    scores = { 21, 20 }, draws = 0 },
  { name = "Smart PERISH_SONG on the last monster", flags = F.SMART,
    me = { moves = { mv("PERISH_SONG", "EFFECT_PERISH_SONG") } }, scores = { 25 }, draws = 0 },
  { name = "Smart CONVERSION2 after a used move (inverted, bug)", flags = F.SMART,
    me = { moves = { mv("CONVERSION2", "EFFECT_CONVERSION2") } }, foe = { lastMove = rec("TACKLE", nil, 40) },
    bytes = { 25 }, scores = { 21 }, draws = 1 },
  { name = "Smart CONVERSION2 with no LAST_MOVE reads Moves[$ff]: no change, no byte", flags = F.SMART,
    me = { moves = { mv("CONVERSION2", "EFFECT_CONVERSION2") } }, scores = { 20 }, draws = 0 },
  { name = "Smart SNORE one turn from waking", flags = F.SMART,
    me = { status = "sleep", statusTurns = 1, moves = { mv("SNORE", "EFFECT_SNORE", 40) } },
    scores = { 23 }, draws = 0 },
  { name = "Smart SLEEP_TALK fast asleep", flags = F.SMART,
    me = { status = "sleep", statusTurns = 3, moves = { mv("SLEEP_TALK", "EFFECT_SLEEP_TALK") } },
    scores = { 17 }, draws = 0 },
  { name = "Smart HEAL_BELL asleep with a statused bench", flags = F.SMART,
    me = { status = "sleep", statusTurns = 2, moves = { mv("HEAL_BELL", "EFFECT_HEAL_BELL") } },
    meBench = { { hp = 30, status = "burn" } }, bytes = { 128 }, scores = { 17 }, draws = 1 },
  { name = "Smart HEAL_BELL with nobody statused", flags = F.SMART,
    me = { moves = { mv("HEAL_BELL", "EFFECT_HEAL_BELL") } }, scores = { 30 }, draws = 0 },
  { name = "Smart COUNTER after three physical moves", flags = F.SMART,
    me = { moves = { mv("COUNTER", "EFFECT_COUNTER", 1, "FIGHTING") } },
    foe = { usedMoves = { rec("TACKLE", nil, 40), rec("STRENGTH", nil, 80), rec("KARATE", nil, 50, "FIGHTING") } },
    bytes = { 100 }, scores = { 19 }, draws = 1 },
  { name = "Smart COUNTER with nothing used", flags = F.SMART,
    me = { moves = { mv("COUNTER", "EFFECT_COUNTER", 1, "FIGHTING") } }, scores = { 21 }, draws = 0 },
  { name = "Smart MIRROR_COAT after one special move", flags = F.SMART,
    me = { moves = { mv("MIRROR_COAT", "EFFECT_MIRROR_COAT", 1, "DARK") } },
    foe = { usedMoves = { rec("EMBER", nil, 40, "FIRE") }, lastCounterMove = rec("EMBER", nil, 40, "FIRE") },
    bytes = { 99 }, scores = { 20 }, draws = 1 },
  { name = "Smart RAZOR_WIND against a used PROTECT", flags = F.SMART,
    me = { moves = { mv("RAZOR_WIND", "EFFECT_RAZOR_WIND", 80) } },
    foe = { usedMoves = { rec("DETECT", "EFFECT_PROTECT") } }, scores = { 26 }, draws = 0 },
  { name = "Smart PRIORITY_HIT that knocks out", flags = F.SMART,
    me = { moves = { mv("QUICK_ATTACK", nil, 40) } }, foe = { hp = 10 }, scores = { 17 }, draws = 0 },
  { name = "Smart PRIORITY_HIT at a target in the sky", flags = F.SMART,
    me = { moves = { mv("QUICK_ATTACK", nil, 40) } },
    foe = { invulnerable = true, charging = { moveIndex = 1, effect = 43, moveId = "FLY" } },
    scores = { 30 }, draws = 0 },
  { name = "Smart LOCK_ON after the player was locked on", flags = F.SMART,
    me = { moves = { mv("LOCK_ON", "EFFECT_LOCK_ON"), mv("ZAP", nil, 100, "FIRE", { accuracy = 128 }),
                     mv("TACKLE", nil, 40, nil, { accuracy = 180 }) } },
    foe = { lockOn = true }, scores = { 30, 18, 20 }, draws = 0 },
  { name = "Smart PROTECT after a PROTECT", flags = F.SMART,
    me = { protectCount = 1, moves = { mv("PROTECT", "EFFECT_PROTECT") } }, bytes = { 20 },
    scores = { 23 }, draws = 1 },
  { name = "Smart ENDURE low with REVERSAL", flags = F.SMART,
    me = { hp = 20, moves = { mv("ENDURE", "EFFECT_ENDURE"), mv("FLAIL", "EFFECT_REVERSAL", 1) } },
    bytes = { 50 }, scores = { 17, 20 }, draws = 1 },
  { name = "Smart FURY_CUTTER at three, then ROLLOUT's tail", flags = F.SMART,
    me = { furyCutter = 3, moves = { mv("FURY_CUTTER", "EFFECT_FURY_CUTTER", 10) } }, bytes = { 199 },
    scores = { 12 }, draws = 1 },
  { name = "Smart EVASION_UP at +6", flags = F.SMART,
    me = { stages = { eva = 6 }, moves = { mv("DOUBLE_TEAM", "EFFECT_EVASION_UP") } }, scores = { 30 }, draws = 0 },
  { name = "Smart EVASION_UP at full HP, 70 percent", flags = F.SMART,
    me = { moves = { mv("DOUBLE_TEAM", "EFFECT_EVASION_UP") } }, bytes = { 177 }, scores = { 18 }, draws = 1 },
  { name = "Smart ACCURACY_DOWN into a badly poisoned player", flags = F.SMART,
    me = { moves = { mv("SAND_ATTACK", "EFFECT_ACCURACY_DOWN") } }, foe = { status = "toxic" },
    scores = { 18 }, draws = 0 },
  { name = "Smart SWAGGER on the player's first turn", flags = F.SMART,
    me = { moves = { mv("SWAGGER", "EFFECT_SWAGGER") } }, foe = { turnsTaken = 0 }, bytes = { 199 },
    scores = { 19 }, draws = 1 },
  { name = "Smart SUNNY_DAY against a Fire type", flags = F.SMART,
    me = { moves = { mv("SUNNY_DAY", "EFFECT_SUNNY_DAY", 0, "FIRE") } }, foe = { types = { T.FIRE } },
    scores = { 23 }, draws = 0 },
  { name = "Smart RAIN_DANCE against a Fire type on its first turn", flags = F.SMART,
    me = { moves = { mv("RAIN_DANCE", "EFFECT_RAIN_DANCE", 0, "WATER") } }, foe = { types = { T.FIRE }, turnsTaken = 0 },
    scores = { 18 }, draws = 0 },
  { name = "Smart RAIN_DANCE with no RainDanceMoves", flags = F.SMART,
    me = { moves = { mv("RAIN_DANCE", "EFFECT_RAIN_DANCE", 0, "WATER") } }, scores = { 23 }, draws = 0 },
  { name = "Smart SOLARBEAM in the rain, THUNDER in the sun", flags = F.SMART, weather = "rain",
    me = { moves = { mv("SOLARBEAM", "EFFECT_SOLARBEAM", 120, "GRASS"), mv("THUNDER", "EFFECT_THUNDER", 120) } },
    bytes = { 25 }, scores = { 22, 20 }, draws = 1 },
  { name = "Smart THUNDER in the sun", flags = F.SMART, weather = "sun",
    me = { moves = { mv("THUNDER", "EFFECT_THUNDER", 120) } }, bytes = { 25 }, scores = { 21 }, draws = 1 },
  { name = "Smart EARTHQUAKE at a DIG, faster", flags = F.SMART,
    me = { spe = 70, moves = { mv("EARTHQUAKE", "EFFECT_EARTHQUAKE", 100, "GROUND") } },
    foe = { lastCounterMove = rec("DIG", "EFFECT_FLY", 60, "GROUND"), invulnerable = true,
            charging = { moveIndex = 1, effect = 43, moveId = "DIG" } },
    scores = { 18 }, draws = 0 },
  { name = "Smart GUST after a FLY, the player on the ground, slower", flags = F.SMART,
    me = { moves = { mv("GUST", "EFFECT_GUST", 40, "FLYING") } },
    foe = { lastCounterMove = rec("FLY", "EFFECT_FLY", 70, "FLYING") }, bytes = { 128 },
    scores = { 19 }, draws = 1 },
  { name = "Smart HIDDEN_POWER: the DVs' FIRE 70 into a Grass type", flags = F.SMART,
    me = { dvs = { atk = 14, def = 12, spe = 15, spc = 15 }, moves = { mv("HIDDEN_POWER", "EFFECT_HIDDEN_POWER", 1) } },
    foe = { types = { T.GRASS } }, scores = { 19 }, draws = 0 },
  { name = "Smart HIDDEN_POWER: the DVs' FIRE into a Water type", flags = F.SMART,
    me = { dvs = { atk = 14, def = 12, spe = 15, spc = 15 }, moves = { mv("HIDDEN_POWER", "EFFECT_HIDDEN_POWER", 1) } },
    foe = { types = { T.WATER } }, scores = { 21 }, draws = 0 },
  { name = "Smart SPITE on a move with 5 PP", flags = F.SMART,
    me = { moves = { mv("SPITE", "EFFECT_SPITE", 0, "GHOST") } },
    foe = { lastCounterMove = rec("TACKLE", nil, 40), moves = { mv("TACKLE", nil, 40, nil, { pp = 5 }) } },
    bytes = { 100 }, scores = { 18 }, draws = 1 },
  { name = "Smart SPITE reads the PP Ups in the PP byte", flags = F.SMART,
    me = { moves = { mv("SPITE", "EFFECT_SPITE", 0, "GHOST") } },
    foe = { lastCounterMove = rec("TACKLE", nil, 40), moves = { mv("TACKLE", nil, 40, nil, { pp = 5, ppUps = 1 }) } },
    scores = { 21 }, draws = 0 },
  { name = "Smart DISABLE faster after a UsefulMoves move", flags = F.SMART,
    me = { spe = 70, moves = { mv("DISABLE", "EFFECT_DISABLE") } }, foe = { lastCounterMove = rec("SURF", nil, 95, "WATER") },
    bytes = { 100 }, scores = { 19 }, draws = 1 },
  { name = "Smart DISABLE slower", flags = F.SMART,
    me = { moves = { mv("DISABLE", "EFFECT_DISABLE") } }, bytes = { 20 }, scores = { 21 }, draws = 1 },
  { name = "Smart ENCORE: the last move cannot touch a Ghost", flags = F.SMART,
    me = { spe = 70, types = { T.GHOST }, moves = { mv("ENCORE", "EFFECT_ENCORE") } },
    foe = { lastMove = rec("TACKLE", nil, 40), lastCounterMove = rec("TACKLE", nil, 40) },
    bytes = { 70 }, scores = { 18 }, draws = 1 },
  { name = "Smart ENCORE: a neutral hit that is no EncoreMoves move", flags = F.SMART,
    me = { spe = 70, moves = { mv("ENCORE", "EFFECT_ENCORE") } },
    foe = { lastMove = rec("TACKLE", nil, 40), lastCounterMove = rec("TACKLE", nil, 40) },
    scores = { 23 }, draws = 0 },
  { name = "Smart MIMIC with nothing to copy, faster", flags = F.SMART,
    me = { spe = 70, moves = { mv("MIMIC", "EFFECT_MIMIC") } }, scores = { 30 }, draws = 0 },
  { name = "Smart MIRROR_MOVE after a UsefulMoves move, slower", flags = F.SMART,
    me = { moves = { mv("MIRROR_MOVE", "EFFECT_MIRROR_MOVE") } }, foe = { lastCounterMove = rec("SURF", nil, 95, "WATER") },
    bytes = { 128 }, scores = { 19 }, draws = 1 },
  { name = "Smart RESET_STATS with the enemy's Attack at -3", flags = F.SMART,
    me = { stages = { atk = -3 }, moves = { mv("HAZE", "EFFECT_RESET_STATS") } }, bytes = { 40 },
    scores = { 19 }, draws = 1 },
  { name = "Smart OHKO against a higher level", flags = F.SMART,
    me = { moves = { mv("FISSURE", "EFFECT_OHKO", 1, "GROUND") } }, foe = { level = 60 }, scores = { 30 }, draws = 0 },
  { name = "Smart TRAP_TARGET into a trapped player", flags = F.SMART,
    me = { moves = { mv("WRAP", "EFFECT_TRAP_TARGET", 15) } }, foe = { trapped = { turns = 2, fromSlot = 1 } },
    bytes = { 128 }, scores = { 21 }, draws = 1 },
  { name = "Smart CONFUSE at 40 percent", flags = F.SMART,
    me = { moves = { mv("SUPERSONIC", "EFFECT_CONFUSE") } }, foe = { hp = 40 }, bytes = { 25 },
    scores = { 21 }, draws = 1 },
  { name = "Smart SP_DEF_UP_2 against a special type", flags = F.SMART,
    me = { moves = { mv("AMNESIA", "EFFECT_SP_DEF_UP_2") } }, foe = { types = { T.FIRE } }, bytes = { 50 },
    scores = { 18 }, draws = 1 },
  { name = "Smart PARALYZE at a quarter", flags = F.SMART,
    me = { moves = { mv("GLARE", "EFFECT_PARALYZE") } }, foe = { hp = 20 }, bytes = { 128 },
    scores = { 21 }, draws = 1 },
  { name = "Smart SPEED_DOWN_HIT: ICY WIND, the player's first turn", flags = F.SMART,
    me = { moves = { mv("ICY_WIND", "EFFECT_SPEED_DOWN_HIT", 55), mv("BUBBLE", "EFFECT_SPEED_DOWN_HIT", 20, "WATER") } },
    foe = { turnsTaken = 0 }, bytes = { 30 }, scores = { 18, 20 }, draws = 1 },
  { name = "Smart SUBSTITUTE at half", flags = F.SMART,
    me = { hp = 50, moves = { mv("SUBSTITUTE", "EFFECT_SUBSTITUTE") } }, scores = { 30 }, draws = 0 },
  { name = "Smart RAGE building at 3", flags = F.SMART,
    me = { raging = true, rageCounter = 3, moves = { mv("RAGE", "EFFECT_RAGE", 20) } }, bytes = { 128 },
    scores = { 17 }, draws = 1 },
  { name = "Smart HEAL at a fifth", flags = F.SMART,
    me = { hp = 20, moves = { mv("RECOVER", "EFFECT_HEAL"), mv("MOONLIGHT", "EFFECT_MOONLIGHT") } },
    bytes = { 25, 24 }, scores = { 18, 20 }, draws = 2 },
  { name = "Smart HEAL above half", flags = F.SMART,
    me = { hp = 60, moves = { mv("RECOVER", "EFFECT_HEAL") } }, scores = { 21 }, draws = 0 },
  { name = "Smart TOXIC / LEECH_SEED at the player's half", flags = F.SMART,
    me = { moves = { mv("TOXIC", "EFFECT_TOXIC", 0, "POISON"), mv("LEECH_SEED", "EFFECT_LEECH_SEED", 0, "GRASS") } },
    foe = { hp = 50 }, scores = { 21, 21 }, draws = 0 },
  { name = "Smart REFLECT below full HP", flags = F.SMART,
    me = { hp = 99, moves = { mv("REFLECT", "EFFECT_REFLECT") } }, bytes = { 20 }, scores = { 21 }, draws = 1 },
  { name = "Smart ALWAYS_HIT with the enemy's Accuracy at -3", flags = F.SMART,
    me = { stages = { acc = -3 }, moves = { mv("SWIFT", "EFFECT_ALWAYS_HIT", 60) } }, bytes = { 50 },
    scores = { 18 }, draws = 1 },
  { name = "Smart SUPER_FANG at a quarter; PAIN_SPLIT; DESTINY_BOND", flags = F.SMART,
    me = { hp = 30, moves = { mv("SUPER_FANG", "EFFECT_SUPER_FANG", 1), mv("PAIN_SPLIT", "EFFECT_PAIN_SPLIT"),
                              mv("DESTINY_BOND", "EFFECT_DESTINY_BOND", 0, "GHOST") } },
    foe = { hp = 25 }, scores = { 21, 21, 21 }, draws = 0 },
  { name = "Smart PAIN_SPLIT below twice the enemy's HP", flags = F.SMART,
    me = { hp = 60, moves = { mv("PAIN_SPLIT", "EFFECT_PAIN_SPLIT") } }, scores = { 21 }, draws = 0 },
  { name = "Smart NIGHTMARE; FLAME_WHEEL frozen", flags = F.SMART,
    me = { status = "freeze", moves = { mv("NIGHTMARE", "EFFECT_NIGHTMARE", 0, "GHOST"), mv("FLAME_WHEEL", "EFFECT_FLAME_WHEEL", 60, "FIRE") } },
    bytes = { 128 }, scores = { 19, 15 }, draws = 1 },
  { name = "Smart FORESIGHT against a Ghost", flags = F.SMART,
    me = { moves = { mv("FORESIGHT", "EFFECT_FORESIGHT") } }, foe = { types = { T.GHOST } }, bytes = { 100 },
    scores = { 18 }, draws = 1 },
  { name = "Smart SANDSTORM against a Rock type", flags = F.SMART,
    me = { moves = { mv("SANDSTORM", "EFFECT_SANDSTORM", 0, "ROCK") } }, foe = { types = { T.ROCK } },
    scores = { 22 }, draws = 0 },
  { name = "Smart SAFEGUARD; PURSUIT at a quarter", flags = F.SMART,
    me = { moves = { mv("SAFEGUARD", "EFFECT_SAFEGUARD"), mv("PURSUIT", "EFFECT_PURSUIT", 40, "DARK") } },
    foe = { hp = 25 }, bytes = { 50, 128 }, scores = { 21, 18 }, draws = 2 },
  { name = "Smart RAPID_SPIN seeded", flags = F.SMART,
    me = { leechSeed = { fromSlot = 1 }, moves = { mv("RAPID_SPIN", "EFFECT_RAPID_SPIN", 20) } }, bytes = { 50 },
    scores = { 18 }, draws = 1 },
  { name = "Smart BELLY_DRUM at +3", flags = F.SMART,
    me = { stages = { atk = 3 }, moves = { mv("BELLY_DRUM", "EFFECT_BELLY_DRUM") } }, scores = { 25 }, draws = 0 },
  { name = "Smart FUTURE_SIGHT and FLY at a vanished, slower player", flags = F.SMART,
    me = { spe = 70, moves = { mv("FUTURE_SIGHT", "EFFECT_FUTURE_SIGHT", 80, "DARK"), mv("FLY", "EFFECT_FLY", 70, "FLYING") } },
    foe = { invulnerable = true, charging = { moveIndex = 1, effect = 43, moveId = "DIG" } },
    scores = { 18, 17 }, draws = 0 },
  { name = "Smart STOMP at a MINIMIZE", flags = F.SMART,
    me = { moves = { mv("STOMP", "EFFECT_STOMP", 65) } }, foe = { minimized = true }, bytes = { 50 },
    scores = { 19 }, draws = 1 },
  { name = "Smart BIDE below full HP", flags = F.SMART,
    me = { hp = 99, moves = { mv("BIDE", "EFFECT_BIDE") } }, bytes = { 25 }, scores = { 21 }, draws = 1 },
  { name = "Smart BATON_PASS: unknown moves, NORMAL against the enemy's types", flags = F.SMART,
    me = { moves = { mv("BATON_PASS", "EFFECT_BATON_PASS") } }, scores = { 20 }, draws = 0 },
}

for _, s in ipairs(SCENARIOS) do run(s) end

-- ------------------------------------------------------------------
-- the effect numbers
-- ------------------------------------------------------------------

do
  local seen, distinct = {}, true
  for id, num in pairs(AiMove.FROM_REFEREE) do
    if seen[num] then distinct = false end
    seen[num] = true
    eq(Effects.idOf(AiMove.CART_EFFECTS[num]), id, "FROM_REFEREE " .. tostring(id))
  end
  eq(distinct, true, "each referee id names one cart effect")
  eq(#AiMove.CART_EFFECTS, 156, "157 cart effects, 0..156")
  eq(AiMove.cartEffect({ id = "THIEF", effect = 0 }), AiMove.CART_EFFECT_NUM.EFFECT_THIEF, "THIEF by move id")
  eq(AiMove.cartEffect({ id = "QUICK_ATTACK", effect = 0 }), AiMove.CART_EFFECT_NUM.EFFECT_PRIORITY_HIT,
    "PRIORITY_HIT by GetMovePriority's 2")
  eq(AiMove.cartEffect({ id = "MOVE_X", effect = 0, priority = 2 }), AiMove.CART_EFFECT_NUM.EFFECT_PRIORITY_HIT,
    "PRIORITY_HIT by the K8 priority")
  eq(AiMove.cartEffect({ id = "TACKLE", effect = 0 }), 0, "NORMAL_HIT")
  eq(AiMove.cartEffect({ id = "MOVE_X", effect = 1 }), -1, "a Gen 1-only id is no cart effect")
  eq(AiMove.cartEffect({ id = "AGILITY", effect = fx("EFFECT_SPEED_UP_2") }), 52, "SPEED_UP_2 is 52")
  eq(AiMove.statusByte({ status = "sleep", statusTurns = 3 }), 3, "SLP turns")
  eq(AiMove.statusByte({ status = "toxic" }), 8, "badly poisoned is PSN")
  eq(AiMove.statusByte({ status = "paralysis" }), 64, "PAR")
end

-- ------------------------------------------------------------------
-- ParseEnemyAction's wild pick, the lock-in and the usable-move walk
-- ------------------------------------------------------------------

do
  local b, npc = fight({ mode = "wild",
    me = { moves = { mv("A", nil, 40), mv("B", nil, 40, nil, { pp = 0 }), mv("C", nil, 40), mv("D", nil, 40) },
           disable = { moveIndex = 3, turns = 2 } } })
  local rng = script({ 1, 2, 3 })
  b.rng = rng
  eq(AiMove.wildPick(b, npc), 4, "wild: the no-PP and disabled slots redrawn")
  eq(rng.i, 3, "wild: three bytes")

  b, npc = fight({ mode = "wild", me = { moves = { mv("A", nil, 40) } } })
  rng = script({ 3, 2, 1, 0 })
  b.rng = rng
  eq(AiMove.wildPick(b, npc), 1, "wild: empty slots redrawn")
  eq(rng.i, 4, "wild: four bytes")

  b, npc = fight({ mode = "wild",
    me = { moves = { mv("A", nil, 40, nil, { pp = 0 }), mv("B", nil, 40) }, disable = { moveIndex = 2, turns = 1 } } })
  rng = script({})
  b.rng = rng
  eq(AiMove.wildPick(b, npc), nil, "wild: no usable move is Struggle")
  eq(rng.i, 0, "wild: Struggle draws nothing")

  eq(AiMove.usableMove({ moves = { { id = "A", pp = 0 }, { id = "B", pp = 3 } } }), 2, "usableMove")
  eq(AiMove.enemyLockedIn({ bide = { turns = 1 } }), true, "locked: BIDE")
  eq(AiMove.enemyLockedIn({ thrashing = { turns = 0 } }), false, "a rampage at 0 turns is not locked")
  eq(AiMove.turnsTaken({ turnsTaken = 257 }), 1, "turnsTaken is a byte")
end

-- ------------------------------------------------------------------
-- nothing but the RNG moves
-- ------------------------------------------------------------------

do
  local function ser(v)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
      local value = v[k]
      if value == nil then value = v[tonumber(k)] end
      out[#out + 1] = k .. "=" .. ser(value)
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  local b, npc, p = fight({ flags = 1023, family = "crystal",
    me = { hp = 40, stages = { atk = 1, spe = -2 }, status = "paralysis",
           moves = { mv("PSYWAVE", "EFFECT_PSYWAVE", 1), mv("ROAR", "EFFECT_FORCE_SWITCH"),
                     mv("HIDDEN_POWER", "EFFECT_HIDDEN_POWER", 1), mv("STRENGTH", nil, 80) } },
    foe = { hp = 30, stages = { def = 2 }, usedMoves = { rec("EMBER", nil, 40, "FIRE") } } })
  local before = ser({ npc.mons, p.mons, b.screens, b.weather })
  local r = AiMove.evaluate(b, npc, p)
  eq(ser({ npc.mons, p.mons, b.screens, b.weather }), before, "evaluate changes no battle state")
  eq(r.slot ~= nil, true, "a slot is picked")
end

io.write(string.format("battle_sim2_ai_move: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
