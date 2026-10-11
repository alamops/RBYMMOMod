-- Emerald's two other doubles, fought by SOLO BATTLES (contract C2 of
-- docs/plans/gen3-solo-remaining-fights.md, research §1.5 / §2.3):
--
--   pair     two trainers who spot the player at once (pret
--            BATTLE_TYPE_DOUBLE | TWO_OPPONENTS | TRAINER, pokeemerald
--            battle_setup.c:1273; the engine's trainer_sight.lua engagePair)
--   partner  Steven beside the player in the Space Center against MAXIE and
--            TABITHA (TRAINER | DOUBLE | TWO_OPPONENTS | MULTI |
--            INGAME_PARTNER, battle_tower.c:2122; the engine's
--            natives_frontier_story.lua doStevenBattle)
--
-- Both are the core's double (src/SoloBattle.lua M:_begin3 on CoopBattle's
-- solo double screen) with the seats moved: side b is two one-seat trainers
-- -- A on battler 1 (field slot 3) with gEnemyParty[0..2], B on battler 3
-- (slot 4) with gEnemyParty[3..5] (pret battle_main.c:1977, each fielding
-- min(partySize, 3) and switching only within its own half) -- and Steven's
-- fight adds his three on side a, battler 2 (slot 1), beside the player's one
-- seat.  FireRed / LeafGreen have neither shape; a fight of either kind there
-- is handed back.
--
-- Everything the cart's battle would read is seated from the one place: the
-- second trainer's monsters (src/CoopField.lua's stand built them through the
-- `trainer.party` hook with B's own id, cut to three -- else built here the
-- same way, SoloBattle.gen3HookedFoe / gen3TrainerParty) become ONE list of
-- sheets that the referee's B entry and the screen's `npcPartyB` both hold,
-- and Steven's likewise for the ally entry and `partnerParty` (contract C3 of
-- CoopBattle.newSoloDouble: "seat B's and the ally's referee entries from the
-- same sheets they pass the screen").
--
-- Loaded lazily by src/SoloBattle.lua (KIND_FILES3: pair / partner ->
-- "Solo3/Doubles"), only when a fight asks for one of these kinds.

local need, mod = ...
local Gen3 = need("Gen3")
local Sheet3 = need("Sheet3")
local SoloBrain = need("SoloBrain")
local Solo = need("SoloBattle")

local M = {}

local floor = math.floor

-- The referee owners (src/SoloBattle.lua's PLAYER_SEAT / FOE_SEAT, and the
-- two entries this file adds -- word characters only, as every seat id).
M.PLAYER = "solo_player"
M.FOE_A = "solo_foe"
M.FOE_B = "solo_foe_b"
M.ALLY = "solo_ally"

-- pret PARTY_SIZE / 2: what each of two trainers fields (battle_main.c:1977)
-- and how many monsters the player brings to Steven's fight.
M.HALF = 3

-- Steven's look on the double screen (CoopBattle.newSoloDouble `partner`):
-- the battle profile's back-pic key the engine's doStevenBattle passes as
-- `partnerBackPic`, and his overworld walker.
M.STEVEN_BACK_PIC = "steven"
M.STEVEN_GFX = "OBJ_EVENT_GFX_STEVEN"

-- The cart's word for a pair's B_OUTCOME_DREW in the engine's vocabulary:
-- engagePair's finishBattle sets both trainer flags on anything but a loss,
-- and the cart sets none on a draw (pokeemerald battle_setup.c:1335
-- CB2_EndTrainerBattle: IsPlayerDefeated(B_OUTCOME_DREW) is a whiteout).
M.PAIR_DRAW_WORD = "lose"

local function int(v, fallback)
  local n = tonumber(v)
  if n == nil then return fallback end
  return floor(n)
end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

-- An engine monster, as src/SoloBattle.lua's prebuilt3 reads one.
local function prebuiltMon(mon)
  return type(mon) == "table" and int(mon.species, 0) > 0 and int(mon.level, 0) > 0
    and type(mon.moves) == "table" and #mon.moves > 0
end

-- A list of engine monsters, every one of them built; nil otherwise.
local function prebuilt(party)
  if type(party) ~= "table" or #party == 0 then return nil end
  for _, mon in ipairs(party) do
    if not prebuiltMon(mon) then return nil end
  end
  return party
end

-- The first `n` of a list (a new list, the same monster tables).
local function first(list, n)
  local out = {}
  for i = 1, math.min(n, #list) do out[i] = list[i] end
  return out
end

-- Is the running cart Emerald?  The battle profile's family when the engine
-- states one, else the session's cart.
local function emerald()
  local BP = Gen3.engine("src.core.game3.battle.profile")
  local bp = BP and try(BP.get, Gen3.session()) or nil
  if type(bp) == "table" and type(bp.family) == "string" then return bp.family == "rse", bp end
  return Gen3.family() == "rse", bp
end
M.emerald = emerald

local function warn(fmt, ...)
  if type(mod) == "table" and type(mod.log) == "table" then mod.log:warn(fmt, ...) end
end

-- ------------------------------------------------------------------
-- where a pair is not the field's: the Battle Pyramid and Trainer Hill
-- ------------------------------------------------------------------
--
-- Inside either, two trainers who spot the player are the facility's own
-- (pokeemerald battle_setup.c:1272 BattleSetup_StartTrainerBattle: PYRAMID /
-- TRAINER_HILL ORed in, FillFrontierTrainersParties / FillHillTrainersParties,
-- DoBattlePyramidTrainerHillBattle, and no trainer flags at the end --
-- CB2_EndTrainerBattle:1335).  The engine's engagePair has no such arm (it
-- fights the gTrainers rows its object events name), so a pair met there is
-- handed back rather than fought as an ordinary pair; the facility's own fights
-- arrive with their hall's keys and are src/Solo3/Facility.lua's.
function M.inPyramidOrHill(session)
  session = session or Gen3.session()
  if type(session) ~= "table" then return false end
  -- pokeemerald battle_pyramid.c:1423 CurrentBattlePyramidLocation
  local Pyramid = Gen3.engine("src.core.game3.rse.frontier.pyramid")
  if Pyramid and try(Pyramid.inPyramid, session) == true then return true end
  -- pokeemerald trainer_hill.c:554 InTrainerHillChallenge
  local Hill = Gen3.engine("src.core.game3.rse.trainer_hill")
  if Hill and try(Hill.inChallenge, session) == true then return true end
  return false
end

-- ------------------------------------------------------------------
-- the two trainers
-- ------------------------------------------------------------------

-- The engine's foe record for a trainer id (Trainers.foeFromId), or nil.
local function foeOf(trainerId)
  local Trainers = Gen3.engine("src.core.game3.scripting.trainers")
  return Trainers and trainerId and try(Trainers.foeFromId, trainerId) or nil
end

-- A trainer's first three, as the cart builds them for a two-trainer fight:
-- the `prebuilt` list when the caller has one (the stand-in's, already
-- through the `trainer.party` hook), else the engine row through the hook
-- with this trainer's own id and the pret personalities
-- (SoloBattle.gen3HookedFoe / gen3TrainerParty) -- cut to min(partySize, 3)
-- (pokeemerald battle_main.c:1978).  -> party, hooked foe.
local function threeOf(foe, trainerId, given)
  local party = prebuilt(given)
  local hooked = foe
  if not party then
    if type(foe) ~= "table" then return nil, nil end
    hooked = Solo.gen3HookedFoe(foe, trainerId) or foe
    party = Solo.gen3TrainerParty(hooked, trainerId)
  end
  if type(party) ~= "table" or #party == 0 then return nil, hooked end
  return first(party, M.HALF), hooked
end

-- Seat both trainers on ctx (src/SoloBattle.lua's fight state), from the
-- stand-in when there is one (src/CoopField.lua trainerStand3: `enemyParty`
-- A's three, `enemyPartyB`, `trainerIdB`, `defeatTextB`) and from the engine's
-- opts otherwise.  Sets:
--   ctx.party        A's three (the core seats them on "solo_foe")
--   ctx.trainer      A's record (SoloBattle.gen3TrainerRecord)
--   ctx.double       true, ctx.foeSeats 1 (A stands behind one seat)
--   ctx.parties[B]   B's three, for the dex and the TV
--   ctx.dbl          { tidA, tidB, recordB, partyB, sheetsB, labelB }
-- -> true, or false and why.
function M.seatPair(ctx)
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  local stand = type(ctx.stand) == "table" and ctx.stand or {}
  local tidA = int(ctx.trainerId, nil) or int(opts.trainerId, nil)
  local tidB = int(stand.trainerIdB, nil) or int(opts.trainerIdB, nil)
  if not (tidA and tidB) then return false, "a two-trainer battle names both trainers" end
  local partyA, hookedA = threeOf(ctx.foe, tidA, ctx.party or opts.party)
  if not partyA then return false, "the first trainer's party could not be built" end
  local foeB = foeOf(tidB)
  local partyB, hookedB = threeOf(foeB, tidB, stand.enemyPartyB)
  if not partyB then return false, "the second trainer's party could not be built" end
  local sheetsB = Sheet3.mons(ctx.game, partyB, { wild = false })
  if type(sheetsB) ~= "table" or #sheetsB == 0 then
    return false, "the second trainer's party could not be described"
  end
  -- Both records by the core's one builder, so the two trainers read alike
  -- everywhere: the name the cart prints, the class, the pic, the AI flags,
  -- the lose text -- A's off the engine's `defeatText`, B's off `defeatTextB`
  -- (engagePair; pokeemerald battle_setup.c:1530 GetTrainerBLoseText).
  local recordA = ctx.trainer or Solo.gen3TrainerRecord(hookedA or ctx.foe, tidA, opts)
  local recordB
  if type(hookedB or foeB) == "table" then
    recordB = Solo.gen3TrainerRecord(hookedB or foeB, tidB, {
      defeatText = opts.defeatTextB or stand.defeatTextB,
      victoryText = opts.victoryTextB,
      rivalName = opts.rivalName,
    })
  elseif type(stand.trainerB) == "table" then
    -- No engine row to read (a caller's own stand-in): the stand-in's record.
    local t = stand.trainerB
    recordB = {
      id = tidB, trainerId = tidB, trainerClass = t.trainerClass or t.class,
      classId = t.trainerClass or t.class, className = t.className,
      trainerClassName = t.className, trainerName = t.trainerName or t.name,
      name = t.name or t.trainerName or "TRAINER", trainerPic = t.trainerPic or t.pic,
      items = t.items, aiFlags = int(t.aiFlags, 0), gender = t.gender,
      defeatText = t.defeatText or stand.defeatTextB,
    }
  end
  if type(recordB) ~= "table" then return false, "the second trainer could not be named" end
  ctx.party = partyA
  ctx.trainer = recordA
  ctx.double, ctx.foeSeats = true, 1
  ctx.parties = type(ctx.parties) == "table" and ctx.parties or {}
  ctx.parties[M.FOE_B] = partyB
  ctx.dbl = {
    tidA = tidA, tidB = tidB,
    recordB = recordB, partyB = partyB, sheetsB = sheetsB,
    labelB = Solo.gen3FoeLabel(recordB),
  }
  return true
end

-- The AI scripts both foes run: A's | B's (pokeemerald
-- battle_ai_script_commands.c:373 BattleAI_SetupAIData's TWO_OPPONENTS arm;
-- DOUBLE_BATTLE is ORed in by the brain itself on a double, SoloBrain
-- M:_double3), and the same set for Steven (battle_controller_player_partner.c:1518
-- runs BattleAI_SetupAIData too, so his mind is the opponents' scripts).
local function pairFlags(ctx)
  local a = type(ctx.trainer) == "table" and int(ctx.trainer.aiFlags, 0) or 0
  local b = ctx.dbl and type(ctx.dbl.recordB) == "table" and int(ctx.dbl.recordB.aiFlags, 0) or 0
  return { a, b }
end
M.pairFlags = pairFlags

-- B's referee entry, from the same sheets the screen is handed (`npcPartyB`).
local function entryB(ctx, bagFrom)
  local d = ctx.dbl
  return {
    playerId = M.FOE_B,
    name = d.labelB or "TRAINER",
    mons = d.sheetsB,
    -- pokeemerald battle_ai_script_commands.c:292: A's four items are the
    -- fight's one pool, either foe battler spends it (battle_ai_switch_items.c
    -- ShouldUseItem; B's own row is never read).
    bagFrom = bagFrom,
  }
end

-- The screen's half of the second trainer (CoopBattle.newSoloDouble).
local function screenPair(ctx, screenOpts)
  local d = ctx.dbl
  screenOpts.trainerB = d.recordB
  screenOpts.npcPartyB = d.sheetsB
  screenOpts.peerNameB = d.labelB
end

-- ------------------------------------------------------------------
-- the ending a two-trainer fight shares
-- ------------------------------------------------------------------

-- The prize both carts' two-trainer fights pay: A's and B's summed, with no
-- x2 for the double (pokeemerald battle_script_commands.c:5624
-- GetTrainerMoneyToGive's TWO_OPPONENTS arm, :5635 Cmd_getmoneyreward), the
-- Amulet Coin's multiplier on each (the core's own reading of it,
-- SoloBattle M:_moneyMultiplier3).  The engine's Prize.rewardRse states the
-- same sum.  Said always (STRINGID_PLAYERGOTMONEY, BattleScript_LocalBattle
-- WonReward has no zero test).  -> the money gained.
function M.payPrize(ctx, bp)
  local session = Gen3.session()
  local Prize = Gen3.engine("src.core.game3.battle.prize")
  local d = ctx.dbl
  if not (session and Prize and d) then return 0 end
  local mult = 1
  if ctx.solo and type(ctx.solo._moneyMultiplier3) == "function" then
    local ok, m = pcall(ctx.solo._moneyMultiplier3, ctx.solo, bp)
    if ok and tonumber(m) then mult = tonumber(m) end
  end
  local amount = int(try(Prize.rewardRse, d.tidA, {
    double = true, twoOpponents = true, trainerIdB = d.tidB, moneyMultiplier = mult,
  }), 0)
  local gained = int(try(Prize.apply, session, amount), 0)
  ctx.prize = gained
  local player = Gen3.player()
  local name = session.name or (player and player.name) or "PLAYER"
  local line = try(Prize.moneyMessage, name, amount)
  if ctx.solo then ctx.solo:say3(line) end
  return gained
end

-- The won ending (pokeemerald data/battle_scripts_1.s:2920
-- BattleScript_LocalTrainerBattleWon, TWO_OPPONENTS): "<A> and <B> were
-- defeated!", A slides in with its lose text, then B with its own -- the
-- screen's own sayPairDefeated3 -- then the summed prize.  A screen without it
-- (never in play) is told the same three lines through `say`.
function M.sayWon(ctx, bp)
  local fight = ctx.fight
  local said = false
  if type(fight) == "table" and type(fight.sayPairDefeated3) == "function" then
    local ok, res = pcall(fight.sayPairDefeated3, fight)
    said = ok and res == true
  end
  if not said and ctx.solo then
    local d = ctx.dbl or {}
    local labelA = Solo.gen3FoeLabel(ctx.trainer)
    ctx.solo:say3(("%s and\n%s\nwere defeated!"):format(labelA, tostring(d.labelB)))
    if type(ctx.trainer) == "table" then ctx.solo:say3(ctx.trainer.defeatText) end
    if type(d.recordB) == "table" then ctx.solo:say3(d.recordB.defeatText) end
  end
  M.payPrize(ctx, bp)
end

-- settle: a KO win is the cart's two-trainer ending; anything else is the
-- core's (a loss's two whiteout lines, BattleScript_LocalBattleLost).
local function settleTwo(ctx, outcome)
  if not (ctx.verdict == "win" and type(outcome) == "table"
          and (outcome.reason == "ko" or outcome.how == "judge")) then
    return false
  end
  local _, bp = emerald()
  M.sayWon(ctx, bp)
  return true
end

-- ------------------------------------------------------------------
-- pair
-- ------------------------------------------------------------------

local Pair = {}

-- Emerald only; never inside the Pyramid or Trainer Hill (above); the player
-- able to put two monsters out, the engine's own start gate for any double
-- (battle_bridge.lua BattleBridge.start, pret PLAYER_HAS_TWO_USABLE_MONS --
-- engagePair is only reached when it holds, trainer_see.c:191).
function Pair:takes(ctx)
  if not emerald() then return false, "this cart has no two-trainer battles" end
  local session = ctx.session or Gen3.session()
  if M.inPyramidOrHill(session) then return false, "the facility's own pair" end
  if Solo.gen3UsableMons(session and session.party) < 2 then return false, "need two mons" end
  local ok, why = M.seatPair(ctx)
  if not ok then
    warn("two trainers at once could not be set up for SOLO BATTLES (%s), so the game's own "
      .. "battle fights them; report it with the trainers you met", tostring(why))
    return false, why
  end
  -- One item pool, A's, and the two brains that share it (SoloBrain C4's
  -- pair example), built before the referee so `brains` only hands them over.
  local flags = pairFlags(ctx)
  local pool = SoloBrain.itemPool3(ctx.trainer, M.FOE_A)
  ctx.dbl.brains = {
    [M.FOE_A] = SoloBrain.new3({ trainer = ctx.trainer, aiFlags = flags, pool = pool,
                                 owner = M.FOE_A, side = "b" }),
    [M.FOE_B] = SoloBrain.new3({ trainer = ctx.dbl.recordB, aiFlags = flags, pool = pool,
                                 owner = M.FOE_B, side = "b" }),
  }
  return true
end

function Pair:screen(ctx, screenOpts)
  screenPair(ctx, screenOpts)
end

-- Side b in field order: A (the core's own entry, one seat, A's bag) on slot
-- 3, B on slot 4 spending A's bag.
function Pair:seat(ctx, create)
  local a = create.sides.b[1]
  a.seats = nil
  return nil, { b = { entryB(ctx, M.FOE_A) } }
end

function Pair:brains(ctx)
  local out = {}
  for owner, brain in pairs(ctx.dbl.brains or {}) do out[owner] = brain end
  -- A brain that could not be built (no BattleSim3 modules: never in play)
  -- leaves its seat to the referee's own trainer AI.
  if out[M.FOE_B] == nil then out[M.FOE_B] = "referee" end
  return out
end

Pair.settle = function(_, ctx, outcome) return settleTwo(ctx, outcome) end

-- The cart's word, never the trainer-script halt: engagePair's finishBattle
-- is a native waiting on its callback (F.locked, both trainers frozen), and
-- only a word releases it -- "win" sets both flags (B then A,
-- battle_setup.c:1245 SetBattledTrainersFlags) and starts their scripts,
-- anything else is a loss to it.  A draw is the cart's loss (above).
function Pair:word(_, _, ending)
  if type(ending) == "table" and ending.result == "win" then return "win" end
  return M.PAIR_DRAW_WORD
end

-- ------------------------------------------------------------------
-- partner (Steven)
-- ------------------------------------------------------------------

local Partner = {}

-- Steven's three, as engine monsters: the ones the stand-in lifted out of
-- session.party (src/CoopField.lua Stand:detachPartner3, `partnerParty`), else
-- -- a fight that came with no stand-in -- the engine's own layout,
-- session.party past `playerHalf` (doStevenBattle appends them there), left
-- where it is.
function M.partnerMons(ctx)
  local stand = type(ctx.stand) == "table" and ctx.stand or {}
  local mons = prebuilt(stand.partnerParty)
  if mons then return mons, int(stand.playerHalf, nil) end
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  local half = int(opts.playerHalf, nil)
  local session = ctx.session or Gen3.session()
  local party = type(session) == "table" and session.party or nil
  if not (half and type(party) == "table" and #party > half) then return nil, half end
  local tail = {}
  for i = half + 1, #party do tail[#tail + 1] = party[i] end
  return prebuilt(tail), half
end

-- Steven's record for the screen and his brain: the trainer book's
-- (SoloBattle.gen3TrainerRecord over TRAINER_STEVEN_PARTNER, the id the
-- engine hands as `partnerTrainerId`), filled from the stand-in's where the
-- book is silent, with the look the double screen draws him by (pret
-- battle_controller_player_partner.c:1301 his back pic; the engine's battle
-- profile `backPics.steven`, `partnerBackPic`).
function M.partnerRecord(ctx)
  local stand = type(ctx.stand) == "table" and ctx.stand or {}
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  local tid = int(stand.partnerTrainerId, nil) or int(opts.partnerTrainerId, nil)
  local rec = {}
  if tid then
    rec = Solo.gen3TrainerRecord(foeOf(tid) or {}, tid, {}) or {}
  end
  local given = type(stand.partnerTrainer) == "table" and stand.partnerTrainer or {}
  rec.trainerName = rec.trainerName or given.trainerName or given.name
  rec.name = rec.trainerName or rec.name or given.name or "STEVEN"
  rec.className = rec.className or given.className
  rec.trainerPic = rec.trainerPic or int(given.trainerPic or given.pic, nil)
  rec.partnerBackPic = stand.partnerBackPic or opts.partnerBackPic or M.STEVEN_BACK_PIC
  rec.gfxName = rec.gfxName or M.STEVEN_GFX
  return rec
end

-- Emerald only; MAXIE and TABITHA seated as a pair (no Pyramid guard: the
-- Space Center is no facility), Steven's three beside the player's.
function Partner:takes(ctx)
  if not emerald() then return false, "this cart has no partner battles" end
  local session = ctx.session or Gen3.session()
  if Solo.gen3UsableMons(session and session.party) < 1 then return false, "no usable mon" end
  local mons, half = M.partnerMons(ctx)
  if not mons then return false, "no partner party" end
  local ok, why = M.seatPair(ctx)
  if not ok then
    warn("STEVEN's battle could not be set up for SOLO BATTLES (%s), so the game's own "
      .. "battle fights it; report it with the save you were playing", tostring(why))
    return false, why
  end
  -- pokeemerald battle_ai_script_commands.c:283 BattleAI_HandleItemUseBeforeAI
  -- Setup: no items in an INGAME_PARTNER fight, for anybody (the engine passes
  -- `trainerItems = {0,0,0,0}` too) -- so MAXIE's record carries none, and the
  -- screen's upload of his kit is empty.
  ctx.trainer.items = { 0, 0, 0, 0 }
  local flags = pairFlags(ctx)
  local partner = M.partnerRecord(ctx)
  -- His mind: the opponents' scripts, no items, never disobeys (pret
  -- IsMonDisobedient's INGAME_PARTNER arm, battle_util.c:3922) -- `sheets3` clears
  -- the obedience fact on his sheets, built as the player's side's are.
  local ally = SoloBrain.new3({ trainer = partner, aiFlags = flags, noItems = true,
                                noDisobey = true, owner = M.ALLY, side = "a" })
  local sheets = Sheet3.mons(ctx.game, mons, { wild = false, own = true })
  if type(sheets) ~= "table" or #sheets == 0 then return false, "no partner sheets" end
  if ally then ally:sheets3(sheets) else
    for _, sheet in ipairs(sheets) do sheet.traded = nil end
  end
  ctx.dbl.partner = partner
  ctx.dbl.partnerMons = mons
  ctx.dbl.partnerSheets = sheets
  ctx.dbl.playerHalf = half
  ctx.dbl.brains = {
    [M.FOE_A] = SoloBrain.new3({ trainer = ctx.trainer, aiFlags = flags, noItems = true,
                                 owner = M.FOE_A, side = "b" }),
    [M.FOE_B] = SoloBrain.new3({ trainer = ctx.dbl.recordB, aiFlags = flags, noItems = true,
                                 owner = M.FOE_B, side = "b" }),
    [M.ALLY] = ally,
  }
  return true
end

function Partner:screen(ctx, screenOpts)
  screenPair(ctx, screenOpts)
  local d = ctx.dbl
  screenOpts.partner = d.partner
  screenOpts.partnerParty = d.partnerSheets
  screenOpts.partnerName = d.partner.name
  screenOpts.playerHalf = d.playerHalf
end

-- Side a: the player's one seat (slot 0) and Steven's (slot 1), `spare` --
-- the fight is lost when the player's three are down whatever Steven still
-- has (pokeemerald battle_script_commands.c:3543 Cmd_checkteamslost's
-- INGAME_PARTNER branch) -- with the player's badges, whose boosts pret gives
-- every battler on B_SIDE_PLAYER (pokemon.c:3407 ShouldGetStatBadgeBoost,
-- battle_main.c:4639's speed).  Side b: MAXIE and TABITHA, no bag.
function Partner:seat(ctx, create)
  local d = ctx.dbl
  create.sides.a[1].seats = nil
  local a = create.sides.b[1]
  a.seats, a.bag = nil, nil
  return nil, {
    a = { {
      playerId = M.ALLY,
      name = d.partner.name,
      mons = d.partnerSheets,
      spare = true,
      badges = Gen3.badgeList(),
      family = Gen3.family(),
    } },
    b = { entryB(ctx, nil) },
  }
end

function Partner:brains(ctx)
  local out = {}
  for owner, brain in pairs(ctx.dbl.brains or {}) do out[owner] = brain end
  if out[M.FOE_B] == nil then out[M.FOE_B] = "referee" end
  if out[M.ALLY] == nil then out[M.ALLY] = "referee" end
  return out
end

Partner.settle = function(_, ctx, outcome) return settleTwo(ctx, outcome) end

-- The cart's gBattleOutcome as the script reads it: doStevenBattle's native
-- puts the code in VAR_RESULT (battle_main.c:5228), and the Space Center
-- script whites out itself on anything but 1 (`scriptedLoss`: no whiteout
-- here, MossdeepCity_SpaceCenter_2F scripts.inc SetCB2WhiteOut) -- so a draw
-- stays B_OUTCOME_DREW, 3, never halted.
function Partner:word(_, _, ending)
  local w = type(ending) == "table" and ending.word or nil
  if w == "win" or w == "draw" then return w end
  return "lose"
end

-- Steven's three go back behind the player's before the script reads the
-- party (the stand-in's Stand:restorePartner3, a no-op when nothing was
-- lifted): at the cart's end of battle gPlayerParty is the player's three and
-- his, and the script's frontier_saveparty / LoadPlayerParty
-- (MossdeepCity_SpaceCenter_2F scripts.inc) read it from there.
function M.restorePartner(ctx)
  local stand = type(ctx.stand) == "table" and ctx.stand or nil
  if stand and type(stand.restorePartner3) == "function" then
    local ok, put = pcall(stand.restorePartner3, stand)
    return ok and put == true
  end
  return false
end

function Partner:finish(ctx)
  M.restorePartner(ctx)
end

-- A hand-back: the party as the cart's start expects it (his three behind the
-- player's: battle_bridge's own `playerHalf` read), put back after the core's
-- own party snapshot is restored; the stand-in's fightAlone would do the same
-- (idempotent).  The core then starts the cart's battle.
function Partner:handBack(ctx)
  M.restorePartner(ctx)
  return false
end

M.Pair = Pair
M.Partner = Partner
M.kinds3 = { pair = Pair, partner = Partner }

return M
