-- The Battle Frontier and its Battle Tents, Emerald's Trainer Hill and Secret
-- Bases, FireRed / LeafGreen's Trainer Tower, fought solo: the `facility`
-- family of the Gen 3 solo kind registry (contract C2 of
-- docs/plans/gen3-solo-remaining-fights.md; the research in §1.4 of
-- docs/plans/gen3-solo-remaining-fights-research.md, the wave-1 contracts
-- this builds on in its part 2).
--
-- One kind, `facility`, the name src/CoopField.lua's classify3 stamps on a
-- stand as `kind3`, with the hall as `facility3`:
--
--   tower dome factory pike pyramid   the Emerald Frontier halls (a tent is
--                                     its hall: Slateport's is `factory`)
--   palace arena                      the Frontier halls -- and Verdanturf /
--                                     Fallarbor's tents -- whose own battle
--                                     rules are wave 3's (K-FAC2 / R3): handed
--                                     back to the cart by `takes` for now
--   hill                              Emerald's Trainer Hill
--   trainerTower                      FireRed / LeafGreen's Trainer Tower
--   secretBase                        an Emerald Secret Base owner
--   eReader                           kept refused (Config.SOLO_REFUSED_GEN3)
--
-- Every one of them is the ordinary trainer fight -- or, in the Pike and the
-- Pyramid, the ordinary wild fight -- with the cart's rules moved by the
-- facility's battle-type flag.  This file is where each move is stated:
--
--   * seating -- the referee's `rules` (contract C3, Turn.copyRules) per hall;
--     the trainer's brain (the facility AI scripts, no items -- but Trainer
--     Hill's quirk); the screen's `rules` (BAG refused, RUN a forfeit); the
--     Pyramid's run multiplier and its own bag;
--   * the choices -- under `rules.forfeit` the trainer RUN is filed (the core
--     would otherwise park it as the trainer-RUN refusal);
--   * the ending -- the halls' own after-words (the Frontier's, the Tower's,
--     the Secret Base's prize), no prize / Pay Day / Pickup / EXP where the
--     facility has none, `draw` handed to the caller, the Pyramid bag written
--     back, Pyramid Pickup;
--   * the engine couplings -- Battle._nextFacility, sess.lastFrontierBattle,
--     sess.frontierDomeLastMoves, frontier.disableRecordBattle.
--
-- What stays the cart's around the battle: party selection, levels, heals,
-- streaks, prizes, swaps, the Dome bracket -- the scripts that called the
-- fight do all of it from the outcome word and the party this fight writes
-- back (the core's reconcile: HP, PP, status and the sleep counter, exactly
-- -- no EXP here means no HP growth to carry, so the Pike and the Pyramid
-- carry the fight's damage into the next room as the cart does).
--
-- Handed back to the cart (`takes` says no, nothing is built):
--   * the Battle Palace and the Battle Arena, their tents included (wave 3:
--     the Palace move-group pick and the Arena judge are rules this referee
--     does not have yet -- K-FAC2 / R3);
--   * any facility fight with two opponents or a partner: a Battle Tower
--     multi (`partner`) and the Pike's two-trainer double (`twoOpponents`)
--     wait for the pair / partner work (research §1.4, last bullet);
--   * a facility fight the engine shaped some way this file does not know.
--
-- Solo only: co-op refuses every facility (Config.COOP_REFUSED_GEN3, contract
-- C1), so nothing here is ever on a hub's wire.

local need, mod = ...
local Config = need("Config")
local Gen3 = need("Gen3")
local Sheet3 = need("Sheet3")
local SoloBrain = need("SoloBrain")

local M = {}

local floor, max, min = math.floor, math.max, math.min

-- The core's two fixed seat ids (research part 2 §2.3: side a's first entry
-- is `solo_player`, side b's `solo_foe`; src/SoloBattle.lua PLAYER_SEAT /
-- FOE_SEAT).
local PLAYER_SEAT = "solo_player"
local FOE_SEAT = "solo_foe"

-- pret include/constants/vars.h VAR_LAST_TALKED (gSpecialVar_LastTalked), the
-- special var the engine's own Trainer Hill battle reads its trainer by.
local VAR_LAST_TALKED = 0x800F
-- pret include/constants/trainer_hill.h HILL_TRAINERS_PER_FLOOR.
local HILL_TRAINERS_PER_FLOOR = 2
-- pret battle_script_commands.c:5586 GetTrainerMoneyToGive's Secret Base arm.
local SECRET_BASE_PRIZE_PER_LEVEL = 20

local function int(v, fallback)
  local n = tonumber(v)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function str(v)
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

local function set3(v) return v ~= nil and v ~= false end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value, second = pcall(fn, ...)
  if ok then return value, second end
  return nil
end

local function copyList(list)
  if type(list) ~= "table" then return nil end
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  return out
end

local function cleanText(text)
  if type(text) ~= "string" then return nil end
  local clean = Gen3.cleanText and Gen3.cleanText(text) or text
  if clean == "" then return nil end
  return clean
end

local warned = {}
local function warnOnce(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  if type(mod) == "table" and type(mod.log) == "table" then mod.log:warn(fmt, ...) end
end

-- ------------------------------------------------------------------
-- which hall
-- ------------------------------------------------------------------

-- The Emerald Frontier halls (pret include/constants/battle.h
-- BATTLE_TYPE_FRONTIER: TOWER | DOME | PALACE | ARENA | FACTORY | PIKE |
-- PYRAMID).  Every rule below that pret writes against BATTLE_TYPE_FRONTIER
-- is written against this set; a Battle Tent is started as its hall's own
-- type (pret battle_tent.c), so the tents are in it too.
M.FRONTIER_HALLS = {
  tower = true, dome = true, palace = true, arena = true, factory = true, pike = true, pyramid = true,
}

-- The halls whose own battle rules are wave 3's (the Palace's move-group pick
-- and "unable" turns, the Arena's three-turn judge): handed back for now.
M.WAVE3_HALLS = { palace = true, arena = true }

-- The halls with wild fights of their own (pret battle_setup.c:402 / :445,
-- BattleSetup_StartBattlePikeWildBattle / the Pyramid's step encounter).
M.WILD_HALLS = { pike = true, pyramid = true }

-- The halls this file seats, by the fight's entry: a trainer in any of
-- these, a wild only in M.WILD_HALLS.
M.TRAINER_HALLS = {
  tower = true, dome = true, factory = true, pike = true, pyramid = true,
  hill = true, trainerTower = true, secretBase = true,
}

-- The engine keys a facility start is spelled with, in the order
-- src/CoopField.lua's FACILITY_KEYS3 asks them (the halls before
-- `battleTower`: pret runs a Pike single as BATTLE_TOWER type and the engine
-- marks it `pike`), for a fight that arrives with no stand naming its hall.
M.HALL_KEYS = {
  { "dome", "dome" }, { "palace", "palace" }, { "arena", "arena" },
  { "factory", "factory" }, { "pike", "pike" }, { "pyramid", "pyramid" },
  { "battleTower", "tower" }, { "tower", "tower" },
  { "trainerHill", "hill" }, { "trainerTower", "trainerTower" },
  { "secretBase", "secretBase" }, { "eReader", "eReader" },
  { "frontier", "tower" },
}

-- The hall a fight is fought in: the stand's `facility3`, else the first
-- engine key set on the opts, the foe, or a `kinds` table on either.
function M.hallOf(ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local stand = type(ctx.stand) == "table" and ctx.stand or nil
  local named = str(ctx.facility3) or (stand and str(stand.facility3))
  if named then return named end
  local places, sources = {}, { ctx.opts or false, ctx.foe or false }
  for i = 1, 2 do
    local t = sources[i]
    if type(t) == "table" then
      places[#places + 1] = t
      if type(t.kinds) == "table" then places[#places + 1] = t.kinds end
    end
  end
  for _, row in ipairs(M.HALL_KEYS) do
    for _, place in ipairs(places) do
      if set3(place[row[1]]) then return row[2] end
    end
  end
  return nil
end

-- A facility fight with more than one trainer on a side: a Battle Tower
-- multi (`partner`, the engine's doTowerBattle MULTIS arm) or a two-trainer
-- double (the Pike's PIKE_DOUBLE, Tower.startBattle's `twoOpponents` /
-- `frontierTrainerB`).  -> "partner" | "twoOpponents" | nil.
function M.twoSided3(ctx)
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  local stand = type(ctx.stand) == "table" and ctx.stand or {}
  if set3(opts.partner) or set3(stand.partner) then return "partner" end
  if set3(opts.twoOpponents) or opts.trainerIdB ~= nil or opts.frontierTrainerB ~= nil
      or stand.trainerB ~= nil or stand.enemyPartyB ~= nil then
    return "twoOpponents"
  end
  return nil
end

-- ------------------------------------------------------------------
-- the rules (contract C3 `rules`, the referee's Turn.copyRules)
-- ------------------------------------------------------------------

-- The Battle Pyramid's run multiplier for the floor the player stands on
-- (pret battle_pyramid.c GetPyramidRunMultiplier: the floor template's
-- `runMultiplier`, a table the cart owns -- read from the player's cart
-- through the engine, never carried here).  nil when it cannot be read.
function M.pyramidRun3(sess)
  local Py = Gen3.engine("src.core.game3.rse.frontier.pyramid")
  local mult = Py and int(try(Py.runMultiplier, sess), nil) or nil
  if not mult or mult < 1 then return nil end
  return min(255, mult)
end

-- The referee's `rules` for a hall, per the carts:
--
--   Frontier (tower / dome / factory / pike / pyramid, and the wave-3 halls):
--     bag = false      pokeemerald battle_main.c:4221, B_ACTION_USE_ITEM under
--                      FRONTIER_NO_PYRAMID -- "Items can't be used now."; the
--                      Pyramid has its own bag instead (pyramidBag)
--     forfeit = true   battle_main.c:4321 BattleScript_AskIfWantsToForfeitMatch
--                      for a TRAINER under FRONTIER | TRAINER_HILL; :5058
--                      B_OUTCOME_FORFEITED (a wild RUN in the Pike / Pyramid
--                      stays a RUN: never set on a wild entry)
--     exp = false      battle_script_commands.c:3270 Cmd_getexp
--     boosts = false   pokemon.c:3407 ShouldGetStatBadgeBoost, battle_main.c:
--                      4640 GetWhoStrikesFirst's badge arm
--     obedience = false  battle_util.c:3924 IsMonDisobedient's FRONTIER arm
--     theft = "foe"    battle_script_commands.c:2746 MOVE_EFFECT_STEAL_ITEM /
--                      :9192 Cmd_tryswapitems -- the foe may steal, and the
--                      knocked-off check is lifted
--     soulDew = false  pokemon.c:3187 CalculateBaseDamage's SOUL DEW arm
--     pyramidRun = n   battle_util.c:429 / :456 TryRunFromBattle's Pyramid arm
--     pyramidBag = true  the bag the referee is handed is the Pyramid bag
--   Trainer Hill: the bag and the badge rules stay; no EXP (:3273); nobody
--     steals (:2740 / :9192: TRAINER_HILL first); RUN forfeits (battle_main.c:
--     4321, battle_util.c:448).
--   Trainer Tower (FireRed / LeafGreen): the bag and the badge rules stay
--     (pokefirered pokemon.c:2381 ShouldGetStatBadgeBoost is LINK | EREADER
--     only); no EXP (pokefirered battle_script_commands.c Cmd_getexp's
--     TRAINER_TOWER); nobody steals (:2612 / Cmd_tryswapitems); RUN refused
--     like any trainer's -- FireRed has no STRINGID_QUESTIONFORFEITMATCH, so
--     no `forfeit`.
--   Secret Base: an ordinary trainer fight, EXP and the bag included, except
--     that the foe may steal (battle_script_commands.c:2753 / :9197
--     SECRET_BASE) and the stat badge boosts are off (pokemon.c:3413
--     ShouldGetStatBadgeBoost's TRAINER_SECRET_BASE arm) while the speed one
--     stays (battle_main.c:4640 asks LINK | RECORDED_LINK | FRONTIER only).
--
-- -> rules, or nil + why when a hall cannot be seated.
function M.rulesFor(hall, kind, sess)
  if M.FRONTIER_HALLS[hall] then
    local r = { exp = false, boosts = false, obedience = false, theft = "foe", soulDew = false }
    if hall == "pyramid" then
      local mult = M.pyramidRun3(sess)
      if not mult then return nil, "the Battle Pyramid's run multiplier could not be read" end
      r.pyramidBag, r.pyramidRun = true, mult
    else
      r.bag = false
    end
    if kind == "trainer" then r.forfeit = true end
    return r
  end
  if hall == "hill" then
    return { exp = false, theft = "none", forfeit = (kind == "trainer") or nil }
  end
  if hall == "trainerTower" then
    return { exp = false, theft = "none" }
  end
  if hall == "secretBase" then
    return { boosts = { damage = false }, theft = "foe" }
  end
  return nil, "no rules for the hall '" .. tostring(hall) .. "'"
end

-- What the screen is told (MediatedBattle / CoopBattle's `rules` option): BAG
-- refused with the cart's line, RUN asked as a forfeit first.  nil when the
-- hall changes neither.
function M.screenRules3(rules)
  if type(rules) ~= "table" then return nil end
  local out, any = {}, false
  if rules.bag == false then out.bag, any = false, true end
  if rules.forfeit == true then out.forfeit, any = true, true end
  return any and out or nil
end

-- ------------------------------------------------------------------
-- the trainer
-- ------------------------------------------------------------------

-- A facility trainer is no gTrainers row: the record the stand built from
-- what the facility handed the start (CoopField.facilityRecord3), copied so
-- what this fight changes on it (Trainer Hill's items) stays this fight's;
-- else -- a caller with no stand -- the same fields read here: the start's
-- `frontierTrainer`, else its trainerName / trainerClass / trainerPicId, and
-- no items (pret battle_ai_script_commands.c:290: a facility trainer's item
-- history starts empty; the engine hands the start `trainerItems = {0,0,0,0}`).
function M.record3(ctx, hall)
  local stand = type(ctx.stand) == "table" and ctx.stand or nil
  local src = stand and type(stand.trainer) == "table" and stand.trainer or nil
  if src then
    local rec = {}
    for k, v in pairs(src) do rec[k] = v end
    rec.items = copyList(src.items) or { 0, 0, 0, 0 }
    return rec
  end
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  local foe = type(ctx.foe) == "table" and ctx.foe or {}
  local ft = type(opts.frontierTrainer) == "table" and opts.frontierTrainer or {}
  local class = int(ft.class, nil) or int(opts.trainerClass, nil) or int(foe.trainerClass, nil)
  local className = cleanText(ft.className) or cleanText(opts.trainerClassName)
    or cleanText(foe.trainerClassName)
  local name = cleanText(ft.name) or cleanText(opts.trainerName) or cleanText(foe.trainerName)
  local pic = int(ft.pic, nil) or int(opts.trainerPicId, nil) or int(foe.trainerPicId, nil)
    or int(foe.trainerPic, nil)
  local tid = int(opts.trainerId, nil) or int(foe.trainerId, nil)
  return {
    id = tid and tostring(tid) or nil, trainerId = tid,
    frontierTrainerId = int(foe.frontierTrainerId, nil),
    facility = hall,
    trainerClass = class, class = class, classId = class,
    className = className, trainerClassName = className,
    name = name or className or "TRAINER", trainerName = name,
    trainerPic = pic, pic = pic,
    items = { 0, 0, 0, 0 },
    aiFlags = int(opts.aiFlags, nil) or SoloBrain.facilityFlags3(),
    gender = foe.gender,
    defeatText = cleanText(opts.defeatText) or cleanText(foe.defeatText),
    victoryText = cleanText(opts.victoryText) or cleanText(foe.victoryText),
  }
end

-- Trainer Hill's item quirk (pokeemerald battle_ai_script_commands.c:290
-- BattleAI_HandleItemUseBeforeAISetup): the item history is filled for any
-- TRAINER fight outside LINK | SAFARI | BATTLE_TOWER | EREADER | SECRET_BASE |
-- FRONTIER | INGAME_PARTNER | RECORDED_LINK -- a list that lacks TRAINER_HILL
-- -- from gTrainers[gTrainerBattleOpponent_A].items, and on the Hill
-- gTrainerBattleOpponent_A is LocalIdToHillTrainerId(gSpecialVar_LastTalked)
-- (battle_setup.c:1171) = frontier.trainerIds[localId - 1], which
-- LoadTrainerHillObjectEventTemplates sets to localId itself (trainer_hill.c:
-- 658).  So a hill opponent spends the four item slots of the cart's trainer
-- row 1 or 2 -- an unrelated trainer's -- read here from the player's own cart
-- through the engine's trainer book (Trainers.info), never carried.
--
-- The local id is the one the engine's own hill battle reads
-- (rse/trainer_hill.lua Hill.trainerBattle: VAR_LAST_TALKED off the script
-- VM), else the hill trainer on this floor whose name is the fight's
-- (`trainer`, the fight's record; ctx.trainer when absent).
function M.hillLocalId3(ctx, trainer)
  local Space = Gen3.engine("src.core.game3.scripting.space")
  local Flags = Gen3.engine("src.core.game3.scripting.flags")
  local Hill = Gen3.engine("src.core.game3.rse.trainer_hill")
  local varId = (type(Hill) == "table" and int(Hill.VAR_LAST_TALKED, nil)) or VAR_LAST_TALKED
  local vm = type(Space) == "table" and Space.vm or nil
  if type(vm) == "table" and type(Flags) == "table" then
    local id = int(try(Flags.getVar, vm.store, vm.ctx, varId), 0)
    if id >= 1 and id <= HILL_TRAINERS_PER_FLOOR then return id end
  end
  trainer = type(trainer) == "table" and trainer or ctx.trainer
  local name = type(trainer) == "table" and str(trainer.trainerName) or nil
  if not (name and type(Hill) == "table" and type(Hill.trainer) == "function") then return nil end
  local found = nil
  for localId = 1, HILL_TRAINERS_PER_FLOOR do
    local t = try(Hill.trainer, ctx.session, localId)
    local tname = type(t) == "table" and (cleanText(t.name) or str(t.name)) or nil
    if tname == name then
      if found then return nil end
      found = localId
    end
  end
  return found
end

-- The four slots of the trainer row a hill opponent reads (above), or nil.
function M.hillItems3(ctx, trainer)
  local localId = M.hillLocalId3(ctx, trainer)
  if not localId then return nil end
  local Trainers = Gen3.engine("src.core.game3.scripting.trainers")
  local info = Trainers and try(Trainers.info, localId) or nil
  local items = type(info) == "table" and info.items or nil
  if type(items) ~= "table" then return nil end
  local out = {}
  for i = 1, 4 do out[i] = int(items[i], 0) end
  return out
end

-- The Secret Base owner's defeat words (pokeemerald battle_setup.c:1522
-- GetTrainerALoseText -> secret_base.c:1138 GetSecretBaseTrainerLoseText:
-- one of five script texts by the owner's type), read from the player's cart
-- through the engine (rse/secret_base.lua loseTextLabel, rom_text.lua).
function M.secretBaseLoseText3(sess)
  local SB = Gen3.engine("src.core.game3.rse.secret_base")
  local RomText = Gen3.engine("src.core.game3.rom_text")
  if not (type(SB) == "table" and type(RomText) == "table") then return nil end
  local label = str(try(SB.loseTextLabel, sess))
  if not label or try(RomText.has, label) ~= true then return nil end
  return cleanText(try(RomText.plain, label))
end

-- Every member an engine monster already (a species, a level, a move list):
-- the facility built them (createMon + applyStats) and they are fought as
-- they are.
local function prebuilt(party)
  if type(party) ~= "table" or #party == 0 then return nil end
  for _, mon in ipairs(party) do
    if not (type(mon) == "table" and int(mon.species, 0) > 0 and int(mon.level, 0) > 0
            and type(mon.moves) == "table" and #mon.moves > 0) then
      return nil
    end
  end
  return party
end

-- ------------------------------------------------------------------
-- the Pyramid bag
-- ------------------------------------------------------------------

-- The Battle Pyramid's bag as a referee bag sheet (Sheet3.bag's shape: §4
-- ids only, one entry per id, the count capped for the wire, by id), and the
-- counts it held -- pret battle_pyramid_bag.c: in the Pyramid the battle's
-- BAG is the Pyramid bag (CB2_PyramidBagMenuFromBattle), and the party's held
-- items were stored in it on the way in.  nil when it cannot be read.
function M.pyramidBag3(sess)
  local Py = Gen3.engine("src.core.game3.rse.frontier.pyramid")
  if not (type(Py) == "table" and type(Py.bagLists) == "function") then return nil end
  local ok, items, qty = pcall(Py.bagLists, sess)
  if not (ok and type(items) == "table" and type(qty) == "table") then return nil end
  local had = {}
  for i = 1, max(#items, #qty) do
    local id, q = int(items[i], 0), int(qty[i], 0)
    if id > 0 and q > 0 then had[id] = (had[id] or 0) + q end
  end
  local entries = {}
  for id, count in pairs(had) do
    if Sheet3.bagEffect(id) then
      entries[#entries + 1] = {
        id = id,
        count = min(count, Config.BATTLE_BAG_COUNT_MAX),
        name = Sheet3.wireName(Gen3.itemName(id) or "", "move") or nil,
      }
    end
  end
  table.sort(entries, function(a, b) return a.id < b.id end)
  while #entries > Config.BATTLE_BAG_MAX do entries[#entries] = nil end
  return entries, had
end

-- The Pyramid bag after the fight: what the referee spent from side a's bag
-- comes out of it, exactly once.  The screen debits each use as it is
-- confirmed (MediatedBattle confirmPendingItem3 -> Gen3.bag.remove), which the
-- engine's Bag routes to the Pyramid bag while the player is in the Pyramid
-- (bag.lua pyramidBag, pret item.c:136); this squares the bag with the
-- referee's count whatever the screen managed -- a use it did not land is
-- taken now, one it already took is not taken again.
function M.pyramidWriteback3(ctx)
  local state = ctx.pyramidBag3
  if not (type(state) == "table" and type(state.start) == "table") then return 0 end
  local Py = Gen3.engine("src.core.game3.rse.frontier.pyramid")
  if not (type(Py) == "table" and type(Py.bagCount) == "function") then return 0 end
  local sim = ctx.sim
  local fighter = type(sim) == "table" and type(sim.byId) == "table" and sim.byId[PLAYER_SEAT] or nil
  local left = type(fighter) == "table" and type(fighter.bag) == "table" and fighter.bag or {}
  local taken = 0
  for id, start in pairs(state.start) do
    local spent = max(0, int(start, 0) - int(left[id], 0))
    if spent > 0 then
      local target = max(0, int(state.had and state.had[id], 0) - spent)
      local now = int(try(Py.bagCount, ctx.session, id), 0)
      if now > target and try(Py.bagRemove, ctx.session, id, now - target) == true then
        taken = taken + (now - target)
      end
    end
  end
  return taken
end

-- Pickup in the Pyramid (pokeemerald battle_script_commands.c:9660 Cmd_pickup's
-- InBattlePyramid arm: a held item from GetBattlePyramidPickupItemId, the
-- floor's own table), run by the engine's own Prize.pickup with the session
-- it reads the table through (battle/init.lua's pickupRules.pyramidSession).
-- The core's Pickup is off for the Pyramid (`noPickup`), which would draw
-- the banded overworld items instead.
function M.pyramidPickup3(ctx)
  local sess = ctx.session
  local Prize = Gen3.engine("src.core.game3.battle.prize")
  if not (type(sess) == "table" and type(Prize) == "table") then return false end
  local BP = Gen3.engine("src.core.game3.battle.profile")
  local bp = BP and try(BP.get, sess) or nil
  local rules = {}
  for k, v in pairs(type(bp) == "table" and type(bp.rules) == "table" and bp.rules or {}) do
    rules[k] = v
  end
  rules.noPickup = nil
  rules.pyramidSession = sess
  return pcall(Prize.pickup, sess.party, nil, rules)
end

-- ------------------------------------------------------------------
-- the engine's couplings
-- ------------------------------------------------------------------

-- Battle._nextFacility: the Dome (and the Palace / Arena, handed back here)
-- hangs its rules object on the engine's battle module for the engine's own
-- Battle.start to take (rse/frontier/palace.lua startFacilityBattle;
-- battle/init.lua:743), and only that start clears it -- left there, the
-- next engine Frontier fight would inherit this one's.  The stand takes it as
-- the fight begins (CoopField Stand:begin3) and puts it back on a hand-back
-- (Stand:fightAlone -> giveBack3); this takes it once the mod's fight is on
-- screen whatever called it -- the first event the referee sends -- and puts
-- it back on the core's hand-back (`handBack`), so a fight with no stand
-- behind it holds to the same rule.  Taken twice is harmless: the stand only
-- clears what it recorded, and puts back the same object.
function M.takeNextFacility3(ctx)
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  if not set3(opts.frontier) then return false end
  local Battle = Gen3.engine("src.core.game3.battle")
  if type(Battle) ~= "table" then return false end
  local held = rawget(Battle, "_nextFacility")
  if held == nil then return false end
  Battle._nextFacility = nil
  ctx.nextFacility3 = held
  return true
end

function M.restoreNextFacility3(ctx)
  local held = ctx.nextFacility3
  if held == nil then return false end
  ctx.nextFacility3 = nil
  local Battle = Gen3.engine("src.core.game3.battle")
  if type(Battle) ~= "table" then return false end
  if rawget(Battle, "_nextFacility") == nil then Battle._nextFacility = held end
  return true
end

-- The Dome's last moves (pokeemerald battle_util.c:140 HandleAction_UseMove:
-- gBattleResults.lastUsedMovePlayer / lastUsedMoveOpponent = gCurrentMove for
-- every move action whose user still stands, read back by battle_dome.c:5199
-- DOME_FUNC_RESOLVE_WINNERS as the winning move; the engine's
-- battle/facility_dome.lua keeps them on sess.frontierDomeLastMoves).  The
-- move an action uses is the referee's own pick of it (Bm:_actionMove: the
-- locked move, Struggle, an Encore -- gCurrentMove's order), or the recharging
-- move's row on a recharge turn; a Pursuit landed on a switch is not an
-- action of its own on the cart (BattleScript_PursuitDmgOnSwitchOut) and is
-- not counted.  Read off the referee instance's action seam, the only place
-- an action is visible before the canceller prints anything.
function M.trackDomeMoves3(ctx)
  local sim = ctx.sim
  local last = { a = 0, b = 0 }
  ctx.domeLastMoves3 = last
  if not (type(sim) == "table" and type(sim._fightAction) == "function") then return false end
  local inner = sim._fightAction
  sim._fightAction = function(self, fighter, choice, opts)
    local user = type(fighter) == "table" and fighter.b or nil
    local pursuit = type(opts) == "table" and opts.pursuit
    if not pursuit and type(user) == "table" and type(user.mon) == "table"
        and int(user.mon.hp, 0) > 0 and type(choice) == "table"
        and (fighter.side == "a" or fighter.side == "b") then
      local row
      if choice.recharge and user.mustRecharge then
        row = type(user.moves) == "table" and user.moves[user.lastSlot or 1] or nil
      elseif type(self._actionMove) == "function" then
        local ok, picked = pcall(self._actionMove, self, user, choice)
        row = ok and picked or nil
      end
      local num = type(row) == "table" and int(row.num, nil) or nil
      if num and num > 0 then last[fighter.side] = num end
    end
    return inner(self, fighter, choice, opts)
  end
  return true
end

-- Pay Day: the referee counts side a's coins on a won fight
-- (`outcome().payDay`) and the screen pays them as the outcome reaches it.
-- The Frontier's and Trainer Hill's trainer win (pokeemerald
-- battle_scripts_1.s:3027 BattleScript_FrontierTrainerBattleWon) and the
-- Trainer Tower's (pokefirered battle_scripts_1.s BattleScript_BattleTower-
-- TrainerBattleWon) never run givepaydaymoney; a Frontier *wild* win does
-- (BattleScript_PayDayMoneyAndPickUpItems, HandleEndTurn_BattleWon's last
-- arm), and so does a Secret Base's (BattleScript_LocalTrainerBattleWon).
-- Taken off the verdict on its `over`, before the core hands it to the screen.
local function stripPayDay(ctx)
  local sim = ctx.sim
  local result = type(sim) == "table" and sim.result or nil
  if type(result) == "table" then result.payDay = nil end
end

-- pret frontier.disableRecordBattle (FRONTIER_DATA_RECORD_DISABLED): the
-- battle-room scripts offer to record the battle just fought unless it is
-- set.  The mod's fight has no recording to save, so it is always set.
function M.disableRecord3(sess)
  local Util = Gen3.engine("src.core.game3.rse.frontier.util")
  local f = Util and try(Util.frontier, sess) or nil
  if type(f) ~= "table" then
    if type(sess.frontier) ~= "table" then sess.frontier = {} end
    f = sess.frontier
  end
  f.disableRecordBattle = 1
  return true
end

local function speciesOf(mon)
  if type(mon) ~= "table" then return nil end
  return int(mon.species, nil) or int(mon.speciesId, nil)
end

local function nicknameOf(mon)
  if type(mon) ~= "table" then return nil end
  return str(mon.nickname) or str(mon.name) or str(Gen3.speciesName(speciesOf(mon)))
end

-- sess.lastFrontierBattle as the mod's fight left it (pokeemerald
-- battle_tower.c:2671 SetTowerInterviewData's reads: gEnemyParty[
-- gBattlerPartyIndexes[1]], gPlayerParty[gBattlerPartyIndexes[0]] and
-- gBattleMons[0].nickname -- each side's first battler as the fight ended).
-- The engine's Frontier `done` (rse/frontier/tower.lua Tower.startBattle)
-- rebuilds the record from its own battle state -- the last fight the
-- engine ran, never this one -- before it hands the script its result.
function M.lastFrontierBattle3(ending)
  ending = type(ending) == "table" and ending or {}
  return {
    opponentSpecies = speciesOf(ending.foeMon),
    playerSpecies = speciesOf(ending.playerMon),
    playerNickname = nicknameOf(ending.playerMon),
  }
end

-- ------------------------------------------------------------------
-- the after-words
-- ------------------------------------------------------------------

local function fill3(ctx)
  local t = type(ctx.trainer) == "table" and ctx.trainer or {}
  local player = Gen3.player()
  return {
    playerName = (player and str(player.name)) or "PLAYER",
    trainer = true,
    trainer1Class = str(t.className) or t.trainerClass,
    trainer1Name = t.trainerName,
  }
end

local function foeLabel(t)
  local class, name = str(t.className), str(t.trainerName)
  if class and name then return class .. " " .. name end
  return name or class or "TRAINER"
end

-- A line on the fight's screen.  A trainer's own words come with the trainer
-- slid back in (pret trainerslidein before STRINGID_TRAINER1LOSETEXT /
-- WINTEXT) where the screen draws that (the double's sayTrainer3).
local function sayLine(ctx, text, trainerLine)
  text = str(text)
  if not text then return false end
  local fight = ctx.fight
  if trainerLine and ctx.screen == "double" and type(fight) == "table"
      and type(fight.sayTrainer3) == "function" then
    local ok = pcall(fight.sayTrainer3, fight, "a", text)
    if ok then return true end
  end
  local solo = ctx.solo
  if type(solo) == "table" and type(solo.say3) == "function" then
    solo:say3(text)
    return true
  end
  return false
end

-- The money multiplier as the cart sets it (an Amulet Coin sent in on the
-- player's side; on FireRed / LeafGreen on either -- the engine's battle
-- profile rule amuletCoinPlayerOnly), from what the core noted at each send.
local function moneyMultiplier(ctx)
  if ctx.amuletPlayer then return 2 end
  if ctx.amuletFoe then
    local BP = Gen3.engine("src.core.game3.battle.profile")
    local bp = BP and try(BP.get, ctx.session) or nil
    local playerOnly = type(bp) == "table" and type(bp.rules) == "table"
      and bp.rules.amuletCoinPlayerOnly
    if not playerOnly then return 2 end
  end
  return 1
end

-- The Secret Base's prize (pokeemerald battle_script_commands.c:5586
-- GetTrainerMoneyToGive: 20 x the base party's first level x the money
-- multiplier -- no trainer row, no class value, no x2), paid and said the
-- way BattleScript_LocalTrainerBattleWon says it (STRINGID_PLAYERGOTMONEY).
-- The engine's Prize.rewardRse has no Secret Base arm and would pay nothing.
function M.secretBasePrize3(ctx)
  local sess = ctx.session
  local Prize = Gen3.engine("src.core.game3.battle.prize")
  if not (type(sess) == "table" and type(Prize) == "table") then return 0 end
  local lead = type(ctx.party) == "table" and ctx.party[1] or nil
  local level = max(1, int(type(lead) == "table" and lead.level, 1))
  local amount = SECRET_BASE_PRIZE_PER_LEVEL * level * moneyMultiplier(ctx)
  local gained = int(try(Prize.apply, sess, amount), 0)
  ctx.prize = gained
  local name = str(sess.name) or fill3(ctx).playerName
  sayLine(ctx, try(Prize.moneyMessage, name, amount))
  return gained
end

-- ------------------------------------------------------------------
-- the kind
-- ------------------------------------------------------------------

local Facility = {}

-- After the core's common gates, before anything is built: the hall, the
-- rules, the trainer, the flags the core's ending reads.
function Facility:takes(ctx) -- luacheck: ignore self
  local hall = M.hallOf(ctx)
  if not hall then return false, "no facility hall" end
  ctx.facility3 = hall
  if M.WAVE3_HALLS[hall] then
    return false, "the Battle " .. hall .. "'s own rules are not seated yet"
  end
  local two = M.twoSided3(ctx)
  if two then return false, "a facility fight with " .. two .. " is the cart's" end
  local kind = ctx.kind
  if kind == "wild" then
    if not M.WILD_HALLS[hall] then return false, "no wild fights in this hall" end
  elseif not M.TRAINER_HALLS[hall] then
    return false, "this hall is the cart's"
  end
  local rules, why = M.rulesFor(hall, kind, ctx.session)
  if not rules then
    warnOnce("rules:" .. tostring(hall), "this %s fight could not be set up with the cart's own "
      .. "rules (%s), so it is fought on the game's own battle screen; reimport the ROM cache "
      .. "if it keeps happening", tostring(hall), tostring(why))
    return false, why
  end
  local frontier = M.FRONTIER_HALLS[hall] == true
  ctx.facilityRules3 = rules
  -- No dex "seen" for a Frontier or Trainer Hill foe (pokeemerald
  -- battle_main.c:3442 BattleIntroRecordMonsToDex, battle_script_commands.c:
  -- 4680 Cmd_switchinanim: EREADER | FRONTIER | LINK | RECORDED_LINK |
  -- TRAINER_HILL); the Trainer Tower's and a Secret Base's are seen
  -- (pokefirered battle_main.c:2778 asks EREADER | POKEDUDE | LINK | GHOST |
  -- OLD_MAN | LEGENDARY only).
  ctx.noDexSeen = (frontier or hall == "hill") or nil
  -- Pickup: none after a Frontier or Trainer Hill trainer win
  -- (BattleScript_FrontierTrainerBattleWon's TryPickUpItems is the Pyramid's
  -- alone) nor in the Pike (Cmd_pickup's InBattlePike arm does nothing); the
  -- Pyramid's own table (M.pyramidPickup3, at `finish`); the core's for the
  -- Trainer Tower and a Secret Base.
  ctx.noPickup = (frontier or hall == "hill") or nil
  ctx.noPayDay3 = kind == "trainer" and (frontier or hall == "hill" or hall == "trainerTower")
  if kind == "trainer" then
    local rec = M.record3(ctx, hall)
    if hall == "hill" then
      local items = M.hillItems3(ctx, rec)
      if items then
        rec.items, ctx.hillItems3 = items, items
      else
        warnOnce("hillItems", "this Trainer Hill trainer's item slots could not be read from the "
          .. "game, so it fights without items; report it with the floor you were on")
      end
    elseif hall == "secretBase" and not rec.defeatText then
      rec.defeatText = M.secretBaseLoseText3(ctx.session)
    end
    ctx.trainer = rec
    -- A caller with no stand (no prebuilt `opts.party`) whose foe carries the
    -- facility's own monsters: fought as they are.
    local opts = type(ctx.opts) == "table" and ctx.opts or {}
    if opts.party == nil and type(ctx.foe) == "table" then
      ctx.party = prebuilt(ctx.foe.party) or ctx.party
    end
  end
  if hall == "pyramid" then
    local entries, had = M.pyramidBag3(ctx.session)
    if not entries then
      warnOnce("pyramidBag", "the Battle Pyramid's bag could not be read, so this fight is "
        .. "fought on the game's own battle screen; reimport the ROM cache if it keeps happening")
      return false, "no Pyramid bag"
    end
    ctx.pyramidBag3 = { entries = entries, had = had }
  end
  return true
end

-- The screen's facility prompts (contract C3 `rules`, research §2.4): the
-- single and the double read the same table.
function Facility:screen(ctx, screenOpts) -- luacheck: ignore self
  local r = M.screenRules3(ctx.facilityRules3)
  if r and type(screenOpts) == "table" then screenOpts.rules = r end
  return nil
end

-- The referee's rules, and the Pyramid's bag on side a.
function Facility:seat(ctx, create) -- luacheck: ignore self
  local rules = {}
  for k, v in pairs(ctx.facilityRules3 or {}) do rules[k] = v end
  local state = ctx.pyramidBag3
  if state and type(create) == "table" and type(create.sides) == "table" then
    local mine = type(create.sides.a) == "table" and create.sides.a[1] or nil
    local counts = {}
    local bag = {}
    for i, e in ipairs(state.entries) do
      bag[i] = { id = e.id, count = e.count, name = e.name }
      counts[e.id] = e.count
    end
    if type(mine) == "table" then mine.bag = (#bag > 0) and bag or nil end
    state.start = counts
    -- The single's item menu lists what was uploaded (MediatedBattle
    -- `bagSheet`, from the session's own pockets): the Pyramid bag is what
    -- the cart's BAG opens here, so the menu is pointed at it.  Its counts
    -- and debits already reach the Pyramid bag through the engine's Bag.
    local fight = ctx.fight
    if ctx.screen == "single" and type(fight) == "table" then
      local sheet = {}
      for id, n in pairs(counts) do sheet[id] = n end
      fight.bagSheet = sheet
      fight.itemList = nil
    end
  end
  return { rules = rules }
end

-- The trainer's mind (contract C4): the facility's AI scripts
-- (pokeemerald battle_ai_script_commands.c:371 BattleAI_SetupAIData's FRONTIER
-- | EREADER | TRAINER_HILL | SECRET_BASE arm, pokefirered :342 TRAINER_TOWER;
-- the Factory's per-challenge set arrives as the start's `aiFlags`), and no
-- items -- but Trainer Hill's quirk (M.hillItems3).  A Dome fight's actions
-- are watched for its last moves.
function Facility:brains(ctx, npcs) -- luacheck: ignore self npcs
  if ctx.facility3 == "dome" then M.trackDomeMoves3(ctx) end
  if ctx.kind ~= "trainer" then return nil end
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  local spec = {
    trainer = ctx.trainer,
    aiFlags = tonumber(opts.aiFlags) or SoloBrain.facilityFlags3(),
  }
  if ctx.hillItems3 then spec.items = ctx.hillItems3 else spec.noItems = true end
  local brain = SoloBrain.new3(spec)
  if not brain then return nil end
  return { [FOE_SEAT] = brain }
end

-- A RUN under `rules.forfeit` reaches the referee as the forfeit it is (the
-- screen asked "forfeit the match?" first); without this the core parks a
-- trainer RUN as the trainer-RUN refusal.  The Trainer Tower and a Secret
-- Base keep that refusal (no `forfeit`).
function Facility:choose(ctx, payload, seat) -- luacheck: ignore self
  local r = ctx.facilityRules3
  if not (type(r) == "table" and r.forfeit == true and ctx.kind == "trainer") then return false end
  if type(payload) ~= "table" or payload.action ~= "run" then return false end
  local solo = ctx.solo
  local taken = type(solo) == "table" and type(solo.file3) == "function"
    and solo:file3(payload, seat) or false
  return true, taken and true or false
end

function Facility:note(ctx, event) -- luacheck: ignore self
  if not ctx.facilityOnScreen3 then
    ctx.facilityOnScreen3 = true
    M.takeNextFacility3(ctx)
  end
  if type(event) == "table" and event.t == "over" and ctx.noPayDay3 then stripPayDay(ctx) end
end

-- The halls' own after-words, in place of the core's:
--   a trainer won:  "PLAYER defeated CLASS NAME!" and the trainer's defeat
--                   words (pokeemerald BattleScript_FrontierTrainerBattleWon
--                   for the Frontier and the Hill, pokefirered
--                   BattleScript_BattleTowerTrainerBattleWon for the Trainer
--                   Tower), no money; a Secret Base adds its prize
--                   (BattleScript_LocalTrainerBattleWon);
--   a trainer lost or drew:  the trainer's win words
--                   (BattleScript_LocalBattleLostPrintTrainersWinText for the
--                   Frontier and the Hill, BattleScript_BattleTowerLost for
--                   the Trainer Tower) and no whiteout lines; nothing for a
--                   Dome draw (BattleScript_CheckDomeDrew) or a Secret Base
--                   (BattleScript_LocalBattleLostEnd);
--   a forfeit:      nothing more ("PLAYER forfeited the match!" is the
--                   referee's, BattleScript_PrintPlayerForfeited).
-- A Pike / Pyramid wild is the core's (no words on a win; the whiteout lines
-- on a loss, BattleScript_LocalBattleLost's non-TRAINER arm).
--
-- The Trainer Tower's loss is no heal either: pokefirered trainer_tower.c:717
-- CB2_EndTrainerTowerBattle returns to the script, which heals and warps
-- later; the engine's start says `noWhiteout`, which the core reads as the
-- early rival's heal.
function Facility:settle(ctx, outcome) -- luacheck: ignore self
  if ctx.facility3 == "trainerTower" and ctx.healAfter then
    ctx.healAfter, ctx.deferHeal, ctx.scriptedLoss = false, nil, true
  end
  if ctx.kind ~= "trainer" then return nil end
  outcome = type(outcome) == "table" and outcome or {}
  if outcome.how == "forfeit" then return true end
  local t = type(ctx.trainer) == "table" and ctx.trainer or {}
  local hall = ctx.facility3
  if ctx.verdict == "win" then
    if outcome.reason == "ko" or outcome.how == "ko" then
      sayLine(ctx, Gen3.battleText("STRINGID_PLAYERDEFEATEDTRAINER1", fill3(ctx))
        or ("%s defeated\n%s!"):format(fill3(ctx).playerName, foeLabel(t)))
      sayLine(ctx, t.defeatText, true)
      if hall == "secretBase" then M.secretBasePrize3(ctx) end
    end
    return true
  end
  if hall == "secretBase" then return true end
  if hall == "dome" and ctx.verdict == "draw" then return true end
  sayLine(ctx, t.victoryText, true)
  return true
end

-- Contract C5: a facility's draw is "draw" to its caller -- every facility's
-- `done` is a native's continuation (Tower.startBattle's, the Hill's, the
-- Secret Base's, the Trainer Tower's runBattle), never the trainerbattle
-- opcode the core would otherwise halt -- and B_OUTCOME_DREW to the save.
function Facility:word(ctx, outcome, ending) -- luacheck: ignore self ctx outcome
  if type(ending) == "table" and ending.word == "draw" then return "draw" end
  return nil
end

-- The writeback and the engine's records, before the caller's `done`; the
-- one record `done` itself overwrites, after it.
function Facility:finish(ctx, outcome, ending) -- luacheck: ignore self
  outcome = type(outcome) == "table" and outcome or {}
  ending = type(ending) == "table" and ending or {}
  local sess = ctx.session
  if type(sess) ~= "table" then return nil end
  local hall = ctx.facility3
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  local won = ctx.verdict == "win" and outcome.reason == "ko"
  if hall == "pyramid" then
    M.pyramidWriteback3(ctx)
    if won then M.pyramidPickup3(ctx) end
  end
  if not set3(opts.frontier) then return nil end
  M.disableRecord3(sess)
  if hall == "dome" then
    local last = type(ctx.domeLastMoves3) == "table" and ctx.domeLastMoves3 or {}
    sess.frontierDomeLastMoves = {
      player = int(last.a, 0), opponent = int(last.b, 0), outcome = ending.result,
    }
  end
  if ctx.kind ~= "trainer" then return nil end
  local record = M.lastFrontierBattle3(ending)
  local tower = hall == "tower" and set3(opts.battleTower)
  return function()
    sess.lastFrontierBattle = record
    -- The battle room's script asked for the interview in the same tick the
    -- engine's `done` resumed it (pokeemerald BattleFrontier_BattleTower-
    -- BattleRoom_EventScript_DoTowerBattle: DoSpecialTrainerBattle, then
    -- tower_setinterviewdata with nothing waiting in between), from the
    -- record `done` had just rebuilt from the engine's stale battle state; it
    -- is asked again over this fight's.
    if tower then
      local Tower = Gen3.engine("src.core.game3.rse.frontier.tower")
      if type(Tower) == "table" and type(Tower.setInterviewData) == "function" then
        pcall(Tower.setInterviewData, sess)
      end
    end
  end
end

-- A fight the referee could not keep going goes back to the cart: what this
-- fight took from the engine is put back first; the core starts the cart's
-- battle (the stand's fightAlone, which gives back what the stand borrowed).
function Facility:handBack(ctx) -- luacheck: ignore self
  M.restoreNextFacility3(ctx)
  return false
end

M.Facility = Facility
M.kinds3 = { facility = Facility }

return M
