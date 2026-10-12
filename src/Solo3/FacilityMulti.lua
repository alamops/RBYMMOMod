-- The Battle Frontier's two-sided fights, fought solo: the half of the
-- `facility` kind (src/Solo3/Facility.lua) that has more than one trainer on
-- a side (contract C2 of docs/plans/gen3-solo-remaining-fights.md, K-FAC2;
-- research §1.4 / §1.5 / §3.4 of docs/plans/gen3-solo-remaining-fights-research.md).
--
--   partner        a Battle Tower multi with the partner chosen in the lobby
--                  (pret battle_tower.c:2025 DoSpecialTrainerBattle's
--                  FRONTIER_MODE_MULTIS: TRAINER | BATTLE_TOWER | DOUBLE |
--                  INGAME_PARTNER | MULTI | TWO_OPPONENTS; the engine's
--                  rse/frontier/tower.lua doTowerBattle: `partner`,
--                  `playerHalf`, `frontierPartner`, `partnerName`,
--                  `partnerPicId`, `frontierOpponentB`)
--   twoOpponents   the Battle Pike's two-trainer room (pret battle_tower.c:2115
--                  SPECIAL_BATTLE_PIKE_DOUBLE: TRAINER | BATTLE_TOWER | DOUBLE |
--                  TWO_OPPONENTS, FillFrontierTrainersParties(1) -- one monster
--                  each; the engine's rse/frontier/pike.lua doSpecialBattle)
--
-- Not a kind of its own: Facility.lua hands every hook of these two fights
-- here (`FacilityMulti.<hook>(ctx, ...)`, the kind-hook contract of
-- src/SoloBattle.lua -- `ctx` is the fight's state table), so the hall's
-- rules, its forfeit, its silence about money and its records stay the
-- facility's, and the seats are the pair / partner shape of
-- src/Solo3/Doubles.lua:
--
--   side a   the player (slot 0) -- two seats over their own party in the
--            Pike; one seat in a multi, with the partner beside it on slot 1
--            ("solo_ally", gPlayerParty[3..5] on the cart)
--   side b   trainer A on slot 3 ("solo_foe", gEnemyParty[0..2]) and trainer
--            B on slot 4 ("solo_foe_b", gEnemyParty[3..5]), each switching
--            only within its own half (battle_main.c:1977)
--
-- What differs from the field's pair and from Steven, all of it the Frontier's:
--
--   * Frontier rules on the referee (Facility.rulesFor: no BAG, RUN a
--     forfeit, no EXP, no badge boosts, no disobedience, the foe may steal,
--     no SOUL DEW) and on the screen (BAG refused, RUN asked);
--   * no trainer items for anybody and the Frontier's AI scripts for all three
--     computer minds (battle_ai_script_commands.c:290 / :371: BATTLE_TOWER |
--     FRONTIER | INGAME_PARTNER skip the item history; the FRONTIER arm wins
--     over TWO_OPPONENTS);
--   * the partner is NOT `spare`: the cart counts every gPlayerParty slot for
--     a partner who is not Steven (battle_script_commands.c:3543
--     Cmd_checkteamslost: only gPartnerTrainerId == TRAINER_STEVEN_PARTNER
--     skips his monsters), so the fight goes on while the partner stands;
--   * no EXP, no prize, no Pay Day, no Pickup;
--   * the Frontier's words: won -- "A and B were defeated!", A slides in with
--     its lose text, then B with its own (battle_scripts_1.s:3027
--     BattleScript_FrontierTrainerBattleWon_TwoDefeated); lost or drew -- A's
--     win text, then B's (:2960 BattleScript_LocalBattleLostPrintTrainers-
--     WinText), never the whiteout lines; a forfeit -- nothing more;
--   * the outcome word the hall's continuation waits on (Tower.startBattle's
--     `done`: win / lose / draw / forfeited) and no whiteout ever: the
--     challenge's script answers a loss itself.
--
-- The partner's monsters: the engine appends them to session.party behind
-- the player's (doTowerBattle; pret FillPartnerParty, gPlayerParty[3..]), and
-- the door's stand-in lifts them out for the fight (src/CoopField.lua
-- Stand:detachPartner3).  They go back behind the player's -- carrying the
-- fight's damage, as the cart's battle leaves gPlayerParty -- before the
-- caller's `done`, and on a hand-back.  The battle room's own script reloads
-- the party afterwards either way (BattleFrontier_BattleTowerMultiBattleRoom
-- RestoreParty: LoadPlayerParty, frontier_setpartyorder; a loss warps to the
-- lobby), so nothing here outlives the next script line but what the cart
-- itself would leave.
--
-- Emerald only, solo only (co-op refuses every facility, contract C1).

local need, mod = ...
local Gen3 = need("Gen3")
local Sheet3 = need("Sheet3")
local SoloBrain = need("SoloBrain")
local Solo = need("SoloBattle")
-- Read-only helpers of the field's pair and Steven (seat ids, the cart test,
-- the partner's monsters and their way back).  Optional, as every family
-- module is: without it nothing here can seat, and `takes` says so.
local Doubles = need("Solo3/Doubles", true)

local M = {}

local floor = math.floor

M.PLAYER = "solo_player"
M.FOE_A = "solo_foe"
M.FOE_B = "solo_foe_b"
M.ALLY = "solo_ally"

-- The two shapes, by Facility.twoSided3's answer.
M.PARTNER = "partner"
M.TWO_OPPONENTS = "twoOpponents"

-- The halls each shape is met in (pret: FRONTIER_MODE_MULTIS is the Battle
-- Tower's alone, SPECIAL_BATTLE_PIKE_DOUBLE the Pike's); any other hall with
-- two trainers on a side is no fight the carts have, and goes back.
M.HALLS = {
  partner = { tower = true },
  twoOpponents = { pike = true },
}

-- pret include/constants/songs.h MUS_VICTORY_TRAINER: the jingle a Frontier
-- trainer win plays (battle_main.c:4978 HandleEndTurn_BattleWon's FRONTIER |
-- TRAINER_HILL | EREADER arm -- MUS_VICTORY_GYM_LEADER only when opponent A
-- is TRAINER_FRONTIER_BRAIN, which neither of these fights has).
M.VICTORY_SONG = "MUS_VICTORY_TRAINER"

-- pret include/constants/battle_frontier.h FRONTIER_FACILITY_TOWER: the hall
-- whose trainer tables a Tower partner is read from (GetFrontierOpponentClass
-- (gPartnerTrainerId) over the Tower's gFacilityTrainers).
local FACILITY_TOWER = 0
-- The speech a frontier trainer says when the player lost
-- (FRONTIER_PLAYER_LOST_TEXT; the engine's D.trainerSpeech `which` 1, the
-- one Tower.startBattle reads A's `victoryText` with).
local SPEECH_PLAYER_LOST = 1

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
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

local function cleanText(text)
  if type(text) ~= "string" then return nil end
  local clean = Gen3.cleanText and Gen3.cleanText(text) or text
  if clean == "" then return nil end
  return clean
end

local function copy(t)
  local out = {}
  for k, v in pairs(type(t) == "table" and t or {}) do out[k] = v end
  return out
end

local warned = {}
local function warnOnce(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  if type(mod) == "table" and type(mod.log) == "table" then mod.log:warn(fmt, ...) end
end

-- The facility module, asked for when a hook runs rather than at load:
-- Facility.lua is the one that reads this file, so a load-time require of it
-- here would be a cycle the resolver refuses.
local function facility()
  local ok, F = pcall(need, "Solo3/Facility", true)
  if ok and type(F) == "table" then return F end
  return nil
end

-- Every built monster: a species, a level, a move list (the facility made
-- them with createMon + applyStats).
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

local function slice(list, from, to)
  local out = {}
  for i = from, math.min(to, #list) do out[#out + 1] = list[i] end
  return out
end

-- ------------------------------------------------------------------
-- which fight
-- ------------------------------------------------------------------

-- "partner" | "twoOpponents" | nil: the shape of the fight ctx describes
-- (Facility.twoSided3, restated when that module cannot be asked).
function M.shapeOf(ctx)
  local F = facility()
  if F and type(F.twoSided3) == "function" then
    local ok, two = pcall(F.twoSided3, ctx)
    if ok then return two end
  end
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  local stand = type(ctx.stand) == "table" and ctx.stand or {}
  if set3(opts.partner) or set3(stand.partner) then return M.PARTNER end
  if set3(opts.twoOpponents) or opts.frontierTrainerB ~= nil or stand.enemyPartyB ~= nil then
    return M.TWO_OPPONENTS
  end
  return nil
end

local function hallOf(ctx)
  local F = facility()
  local hall = F and type(F.hallOf) == "function" and try(F.hallOf, ctx) or nil
  return str(hall) or str(ctx.facility3)
end

-- ------------------------------------------------------------------
-- the trainers
-- ------------------------------------------------------------------

-- Trainer A's record: the facility's own reading of it (Facility.record3 --
-- the stand-in's facilityRecord3 copied, no items), or the stand's copy.
local function recordA(ctx, hall)
  local F = facility()
  if F and type(F.record3) == "function" then
    local ok, rec = pcall(F.record3, ctx, hall)
    if ok and type(rec) == "table" then return rec end
  end
  local stand = type(ctx.stand) == "table" and ctx.stand or {}
  if type(stand.trainer) == "table" then
    local rec = copy(stand.trainer)
    rec.items = { 0, 0, 0, 0 }
    return rec
  end
  return nil
end

-- The engine's frontier trainer book (rse/frontier/trainers.lua), for what
-- the start never handed over.
local function frontierBook()
  local D = Gen3.engine("src.core.game3.rse.frontier.trainers")
  return type(D) == "table" and D or nil
end

-- What a frontier trainer says when the player lost, read from the player's
-- cart through the engine (pret CopyFrontierTrainerText(FRONTIER_PLAYER_LOST_TEXT,
-- id), battle_message.c:2713 B_TXT_TRAINER2_WIN_TEXT's FRONTIER arm; the
-- engine's D.trainerSpeech over the hall VAR_FRONTIER_FACILITY names, the
-- same reading Tower.startBattle gives A's `victoryText`).  nil when it
-- cannot be read.
function M.frontierWinText3(sess, trainerId)
  local D = frontierBook()
  local TextIR = Gen3.engine("src.core.game3.scripting.text_ir")
  trainerId = int(trainerId, nil)
  if not (D and TextIR and trainerId and type(sess) == "table") then return nil end
  local ir = try(D.trainerSpeech, sess, trainerId, SPEECH_PLAYER_LOST, nil)
  if ir == nil then return nil end
  return cleanText(try(TextIR.toPlain, ir, {}))
end

-- Trainer B's record: the stand-in's (CoopField.facilityRecord3 "B": the
-- start's frontierTrainerB and defeatTextB), else the same fields read off the
-- start here; its win text -- which the engine's start never hands over
-- (Tower.startBattle sets defeatTextB alone) -- read through the engine.
local function recordB(ctx, hall)
  local stand = type(ctx.stand) == "table" and ctx.stand or {}
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  local rec
  if type(stand.trainerB) == "table" then
    rec = copy(stand.trainerB)
  else
    local ft = type(opts.frontierTrainerB) == "table" and opts.frontierTrainerB or nil
    if not ft then return nil end
    local class = int(ft.class, nil)
    local className = cleanText(ft.className)
    local name = cleanText(ft.name)
    local pic = int(ft.pic, nil)
    rec = {
      facility = hall,
      trainerClass = class, class = class, classId = class,
      className = className, trainerClassName = className,
      name = name or className or "TRAINER", trainerName = name,
      trainerPic = pic, pic = pic,
      aiFlags = int(opts.aiFlags, nil) or SoloBrain.facilityFlags3(),
      defeatText = cleanText(opts.defeatTextB),
    }
  end
  rec.items = { 0, 0, 0, 0 }
  rec.frontierTrainerId = int(rec.frontierTrainerId, nil) or int(opts.frontierOpponentB, nil)
  if not str(rec.defeatText) then rec.defeatText = cleanText(stand.defeatTextB or opts.defeatTextB) end
  if not str(rec.victoryText) then
    rec.victoryText = cleanText(opts.victoryTextB)
      or M.frontierWinText3(ctx.session or Gen3.session(),
           rec.frontierTrainerId or (type(ctx.session) == "table" and ctx.session.frontierOpponentB))
  end
  return rec
end

-- The two halves of side b: the stand-in's (A's `enemyParty`, `enemyPartyB`,
-- already split at the start's `frontierFoeHalf`), else the one party the
-- start hands over, cut there (battle_bridge.lua: A's half first).
local function halves(ctx)
  local stand = type(ctx.stand) == "table" and ctx.stand or {}
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  local a = prebuilt(ctx.party) or prebuilt(opts.party) or prebuilt(stand.enemyParty)
  local b = prebuilt(stand.enemyPartyB)
  if a and b then return a, b end
  local all = prebuilt(type(ctx.foe) == "table" and ctx.foe.party or nil)
  local half = int(opts.frontierFoeHalf, nil)
  if all and half and half > 0 and half < #all then
    return slice(all, 1, half), slice(all, half + 1, #all)
  end
  return nil, nil
end

-- ------------------------------------------------------------------
-- the partner
-- ------------------------------------------------------------------

-- The Tower partner as the double screen and his brain read him: his name and
-- front pic (the start's `partnerName` / `partnerPicId`, kept on the stand-in
-- as `partnerTrainer`), his class (pret battle_message.c:2725
-- B_TXT_PARTNER_CLASS = gTrainerClassNames[GetFrontierOpponentClass(
-- gPartnerTrainerId)]) and his walker (battle_tower.c:2665 SetMultiPartnerGfx
-- -> the facility class's object), both read through the engine's
-- frontier book.  No back pic: a partner who is not Steven has none, and the
-- cart draws him by his front pic (battle_controller_player_partner.c:1309).
function M.partnerRecord3(ctx, hall)
  local stand = type(ctx.stand) == "table" and ctx.stand or {}
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  local given = type(stand.partnerTrainer) == "table" and stand.partnerTrainer or {}
  local pid = int(given.frontierTrainerId, nil) or int(opts.frontierPartner, nil)
  local name = cleanText(given.trainerName or given.name) or cleanText(opts.partnerName)
  local pic = int(given.trainerPic or given.pic, nil) or int(opts.partnerPicId, nil)
  local class, className, gfx
  local D = frontierBook()
  local sess = ctx.session or Gen3.session()
  if D and pid and type(sess) == "table" then
    local fac = type(D.FACILITY) == "table" and int(D.FACILITY.TOWER, nil) or FACILITY_TOWER
    class = int(try(D.opponentClass, sess, pid, fac), nil)
    if class then className = cleanText(try(D.className, sess, class)) end
    gfx = int(try(D.gfxId, sess, pid, fac), nil)
    name = name or cleanText(try(D.trainerName, sess, pid, fac))
    pic = pic or int(try(D.frontSpriteId, sess, pid, fac), nil)
  end
  className = className or cleanText(given.className)
  return {
    id = pid and ("frontier_" .. pid) or nil,
    frontierTrainerId = pid, facility = hall,
    name = name or className or "PARTNER", trainerName = name,
    className = className, trainerClassName = className,
    trainerClass = class, class = class, classId = class,
    trainerPic = pic, pic = pic,
    graphicsId = gfx,
  }
end

-- ------------------------------------------------------------------
-- the hooks (contract C2, the kind-hook signatures of src/SoloBattle.lua)
-- ------------------------------------------------------------------

local Hooks = {}

-- After the core's gates, before anything is built: the shape, the hall, the
-- rules, both trainers and their monsters, the partner, the three minds.
-- `shape` is the facility's own reading of the fight (Facility.takes3 hands
-- it over after its common part -- the hall, the rules, the flags, A's
-- record); read here again when absent.  Everything is (re)stated here, so a
-- caller that skipped that part seats the same fight.
function Hooks.takes(ctx, shape)
  if not (type(Doubles) == "table" and type(Doubles.emerald) == "function") then
    return false, "the two-trainer battles could not be loaded"
  end
  local two = (shape == M.PARTNER or shape == M.TWO_OPPONENTS) and shape or M.shapeOf(ctx)
  if not two then return false, "not a two-sided facility fight" end
  ctx.multi3 = two
  if not Doubles.emerald() then return false, "this cart has no two-sided Frontier battles" end
  if ctx.kind ~= "trainer" then return false, "a two-sided facility fight is a trainer fight" end
  local hall = hallOf(ctx)
  if not (hall and M.HALLS[two] and M.HALLS[two][hall]) then
    return false, "the cart has no such two-sided " .. tostring(hall) .. " fight"
  end
  ctx.facility3 = hall
  local F = facility()
  local rules, why
  if F and type(F.rulesFor) == "function" then rules, why = F.rulesFor(hall, "trainer", ctx.session) end
  if not rules then
    warnOnce("rules:" .. hall, "this %s fight could not be set up with the Frontier's own rules (%s), "
      .. "so it is fought on the game's own battle screen; reinstall the mod folder if it keeps "
      .. "happening", hall, tostring(why or "no facility module"))
    return false, why or "no facility rules"
  end
  local session = ctx.session or Gen3.session()
  -- pret battle_pike.c:1052: the Pike offers its double room only while two
  -- of the player's monsters can fight (AtLeastTwoAliveMons); a multi's
  -- player brings their own two.
  --
  -- The player's own, and only those.  A multi with no stand-in still has the
  -- partner's monsters in session.party past `playerHalf` (doTowerBattle
  -- appends them; Doubles.partnerMons reads them there and leaves them in
  -- place), so the whole list would count his as the player's -- and a
  -- player whose own half is all fainted would be seated on monsters that
  -- are not theirs (pret Cmd_checkteamslost's INGAME_PARTNER branch counts
  -- the player's half alone).  A stand-in lifted his out already
  -- (Stand:detachPartner3); its own `playerHalf` is read for that case.
  local party = session and session.party
  local half = two == M.PARTNER and (int(ctx.opts and ctx.opts.playerHalf, nil)
    or int(type(ctx.stand) == "table" and ctx.stand.playerHalf or nil, nil)) or nil
  if half and type(party) == "table" then
    local own = {}
    for i = 1, math.min(half, #party) do own[i] = party[i] end
    party = own
  end
  local mine = Solo.gen3UsableMons(party)
  if two == M.TWO_OPPONENTS and mine < 2 then return false, "need two mons" end
  if mine < 1 then return false, "no usable mon" end
  local partyA, partyB = halves(ctx)
  if not (partyA and partyB) then return false, "the two trainers' parties could not be split" end
  local recA, recB = recordA(ctx, hall), recordB(ctx, hall)
  if not (recA and recB) then return false, "the two trainers could not be named" end
  local sheetsB = Sheet3.mons(ctx.game, partyB, { wild = false })
  if type(sheetsB) ~= "table" or #sheetsB == 0 then
    return false, "the second trainer's party could not be described"
  end
  local flags = tonumber(ctx.opts and ctx.opts.aiFlags) or SoloBrain.facilityFlags3()
  local dbl = {
    shape = two, recordB = recB, partyB = partyB, sheetsB = sheetsB,
    labelB = Solo.gen3FoeLabel(recB), flags = flags,
  }
  if two == M.PARTNER then
    local mons, half = Doubles.partnerMons(ctx)
    if not mons then return false, "no partner party" end
    local partner = M.partnerRecord3(ctx, hall)
    -- His mind: the Frontier's scripts (BattleAI_SetupAIData runs for his
    -- controller too, battle_controller_player_partner.c:1518), no items
    -- (INGAME_PARTNER), never disobeys (battle_util.c:3922).
    local ally = SoloBrain.new3({ trainer = partner, aiFlags = flags, noItems = true,
                                  noDisobey = true, owner = M.ALLY, side = "a" })
    local sheets = Sheet3.mons(ctx.game, mons, { wild = false, own = true })
    if type(sheets) ~= "table" or #sheets == 0 then return false, "no partner sheets" end
    if ally then ally:sheets3(sheets) else
      for _, sheet in ipairs(sheets) do sheet.traded = nil end
    end
    dbl.partner, dbl.partnerMons, dbl.partnerSheets = partner, mons, sheets
    dbl.playerHalf = half
    dbl.ally = ally
  end
  dbl.brains = {
    [M.FOE_A] = SoloBrain.new3({ trainer = recA, aiFlags = flags, noItems = true,
                                 owner = M.FOE_A, side = "b" }),
    [M.FOE_B] = SoloBrain.new3({ trainer = recB, aiFlags = flags, noItems = true,
                                 owner = M.FOE_B, side = "b" }),
    [M.ALLY] = dbl.ally,
  }
  ctx.dbl = dbl
  ctx.party = partyA
  ctx.trainer = recA
  ctx.double, ctx.foeSeats = true, 1
  ctx.parties = type(ctx.parties) == "table" and ctx.parties or {}
  ctx.parties[M.FOE_B] = partyB
  ctx.facilityRules3 = rules
  -- The Frontier's quiet ending (Facility:takes states each): no dex "seen",
  -- no Pickup, no Pay Day for a trainer win.
  ctx.noDexSeen, ctx.noPickup, ctx.noPayDay3 = true, true, true
  return true
end

-- The screen: the facility's own options first (Facility's screen body,
-- `own3.screen`, where that module has one: the prompts, the jingle), then
-- the second trainer and the partner -- and the prompts and the Frontier's
-- jingle stated here too when the facility said nothing of them.
function Hooks.screen(ctx, screenOpts)
  if type(screenOpts) ~= "table" then return nil end
  local d = ctx.dbl
  local F = facility()
  local own = F and type(F.own3) == "table" and F.own3.screen or nil
  if type(own) == "function" then
    local ok, extra = pcall(own, ctx, screenOpts)
    if ok and type(extra) == "table" then
      for k, v in pairs(extra) do screenOpts[k] = v end
    end
  end
  local r = F and type(F.screenRules3) == "function" and try(F.screenRules3, ctx.facilityRules3) or nil
  if r and screenOpts.rules == nil then screenOpts.rules = r end
  screenOpts.trainerB = d.recordB
  screenOpts.npcPartyB = d.sheetsB
  screenOpts.peerNameB = d.labelB
  if d.partner then
    screenOpts.partner = d.partner
    screenOpts.partnerParty = d.partnerSheets
    screenOpts.partnerName = d.partner.name
    screenOpts.playerHalf = d.playerHalf
  end
  if screenOpts.victorySong == nil then screenOpts.victorySong = M.VICTORY_SONG end
  return nil
end

-- The referee: the Frontier's rules; side b in field order (A on slot 3, no
-- bag; B on slot 4); a multi's side a the player's one seat and the partner's
-- -- not `spare` (the head of this file).
function Hooks.seat(ctx, create)
  local d = ctx.dbl
  local sides = create and create.sides or {}
  local a = type(sides.b) == "table" and sides.b[1] or nil
  if a then a.seats, a.bag = nil, nil end
  local out = {
    b = { { playerId = M.FOE_B, name = d.labelB or "TRAINER", mons = d.sheetsB } },
  }
  if d.partner then
    local mine = type(sides.a) == "table" and sides.a[1] or nil
    if mine then mine.seats = nil end
    out.a = { {
      playerId = M.ALLY,
      name = d.partner.name,
      mons = d.partnerSheets,
      badges = Gen3.badgeList(),
      family = Gen3.family(),
    } }
  end
  return { rules = copy(ctx.facilityRules3) }, out
end

function Hooks.brains(ctx)
  local d = ctx.dbl or {}
  local out = {}
  for owner, brain in pairs(d.brains or {}) do out[owner] = brain end
  -- A mind that could not be built (no BattleSim3 modules: never in play)
  -- leaves its seat to the referee's own trainer AI.
  if out[M.FOE_A] == nil then out[M.FOE_A] = "referee" end
  if out[M.FOE_B] == nil then out[M.FOE_B] = "referee" end
  if d.partner and out[M.ALLY] == nil then out[M.ALLY] = "referee" end
  return out
end

-- RUN is the Frontier's forfeit (pret battle_main.c:4321: TRAINER under
-- FRONTIER -- a multi's included -- asks BattleScript_AskIfWantsToForfeitMatch;
-- the screen asked first): filed as it is, or the core would park it as the
-- trainer-RUN refusal.
function Hooks.choose(ctx, payload, seat)
  local r = ctx.facilityRules3
  if not (type(r) == "table" and r.forfeit == true) then return false end
  if type(payload) ~= "table" or payload.action ~= "run" then return false end
  local solo = ctx.solo
  local taken = type(solo) == "table" and type(solo.file3) == "function"
    and solo:file3(payload, seat) or false
  return true, taken and true or false
end

-- Battle._nextFacility as the facility takes it (a Tower or Pike start has
-- none, but the rule is the hall's); Pay Day off the verdict (the Frontier's
-- trainer win never runs givepaydaymoney, BattleScript_FrontierTrainerBattleWon).
function Hooks.note(ctx, event)
  if not ctx.facilityOnScreen3 then
    ctx.facilityOnScreen3 = true
    local F = facility()
    if F and type(F.takeNextFacility3) == "function" then pcall(F.takeNextFacility3, ctx) end
  end
  if type(event) == "table" and event.t == "over" and ctx.noPayDay3 then
    local result = type(ctx.sim) == "table" and ctx.sim.result or nil
    if type(result) == "table" then result.payDay = nil end
  end
end

-- One trainer's line with that trainer slid in (the double screen's
-- sayTrainer3), else said plainly.
local function sayTrainer(ctx, which, text)
  local fight = ctx.fight
  if type(fight) == "table" and type(fight.sayTrainer3) == "function" then
    local ok, res = pcall(fight.sayTrainer3, fight, which, text)
    if ok and res == true then return true end
  end
  if str(text) and type(ctx.solo) == "table" and type(ctx.solo.say3) == "function" then
    ctx.solo:say3(text)
    return true
  end
  return false
end

-- The after-words (the head of this file), in place of the core's.  A
-- Frontier loss is never a whiteout: the challenge's script answers it
-- (Tower.startBattle's `scriptedLoss`; held here whatever the start said).
function Hooks.settle(ctx, outcome)
  outcome = type(outcome) == "table" and outcome or {}
  if ctx.whiteout then ctx.whiteout, ctx.scriptedLoss = false, true end
  ctx.healAfter, ctx.deferHeal = false, nil
  if outcome.how == "forfeit" then return true end
  local d = ctx.dbl or {}
  local recA = type(ctx.trainer) == "table" and ctx.trainer or {}
  local recB = type(d.recordB) == "table" and d.recordB or {}
  if ctx.verdict == "win" then
    if outcome.reason == "ko" or outcome.how == "ko" then
      local fight = ctx.fight
      local said = false
      if type(fight) == "table" and type(fight.sayPairDefeated3) == "function" then
        local ok, res = pcall(fight.sayPairDefeated3, fight)
        said = ok and res == true
      end
      if not said and type(ctx.solo) == "table" then
        ctx.solo:say3(("%s and\n%s\nwere defeated!"):format(Solo.gen3FoeLabel(recA),
          tostring(d.labelB)))
        ctx.solo:say3(recA.defeatText)
        ctx.solo:say3(recB.defeatText)
      end
    end
    return true
  end
  sayTrainer(ctx, "a", recA.victoryText)
  sayTrainer(ctx, "b", recB.victoryText)
  return true
end

-- Contract C5: the hall's continuation hears "draw" for a draw (B_OUTCOME_DREW,
-- VAR_RESULT 3), never the trainer-script halt; every other word is the
-- core's (win, lose, forfeited).
function Hooks.word(ctx, outcome, ending) -- luacheck: ignore ctx outcome
  if type(ending) == "table" and ending.word == "draw" then return "draw" end
  return nil
end

-- The partner's monsters as the fight left them: HP, status and PP from his
-- referee entry onto his engine monsters (by each sheet's place in his list),
-- as the cart's battle leaves gPlayerParty[3..].
local function partnerWriteback(ctx)
  local d = ctx.dbl
  local sim = ctx.sim
  local fighter = type(sim) == "table" and type(sim.byId) == "table" and sim.byId[M.ALLY] or nil
  if not (d and type(d.partnerMons) == "table" and type(fighter) == "table") then return 0 end
  local n = 0
  for i, sheet in ipairs(type(fighter.mons) == "table" and fighter.mons or {}) do
    local target = d.partnerMons[int(sheet.slot, i - 1) + 1]
    if type(target) == "table" then
      Sheet3.applyToMon(target, { hp = sheet.hp, status = sheet.status, moves = sheet.moves })
      n = n + 1
    end
  end
  return n
end

-- Before the caller's `done`: the partner's monsters back behind the
-- player's, the record-battle offer switched off (Facility.disableRecord3);
-- after it, sess.lastFrontierBattle over the stale one `done` rebuilds
-- (Facility.lastFrontierBattle3).  The interview itself is the singles' alone
-- (pret battle_tower.c:2676 SetTowerInterviewData returns for any other mode),
-- so it is not asked again.
function Hooks.finish(ctx, outcome, ending) -- luacheck: ignore outcome
  partnerWriteback(ctx)
  if type(Doubles) == "table" and type(Doubles.restorePartner) == "function" then
    Doubles.restorePartner(ctx)
  end
  local sess = ctx.session
  if type(sess) ~= "table" then return nil end
  local F = facility()
  if F and type(F.disableRecord3) == "function" then pcall(F.disableRecord3, sess) end
  local record = F and type(F.lastFrontierBattle3) == "function"
    and try(F.lastFrontierBattle3, ending) or nil
  if type(record) ~= "table" then return nil end
  return function() sess.lastFrontierBattle = record end
end

-- A fight the referee could not keep going: the partner's monsters back
-- where the engine left them (the stand-in's fightAlone does the same,
-- idempotently) and whatever the facility took, and the core starts the
-- cart's battle.
function Hooks.handBack(ctx)
  if type(Doubles) == "table" and type(Doubles.restorePartner) == "function" then
    Doubles.restorePartner(ctx)
  end
  local F = facility()
  if F and type(F.restoreNextFacility3) == "function" then pcall(F.restoreNextFacility3, ctx) end
  return false
end

-- Every hook answers `M.<hook>(ctx, ...)` and `M:<hook>(ctx, ...)` alike, and
-- a caller that hands its own kind table first (`kind:hook(ctx, ...)` passed
-- straight on) is read the same way: the first table that carries a `takes`
-- function is a hook table, never a fight's ctx.
local function hookTable(t)
  return type(t) == "table" and (t == M or type(rawget(t, "takes")) == "function")
end
M.HOOKS = { "takes", "screen", "seat", "brains", "choose", "note", "settle", "word", "finish",
            "handBack" }
for _, name in ipairs(M.HOOKS) do
  local fn = Hooks[name]
  M[name] = function(first, ...)
    if hookTable(first) then return fn(...) end
    return fn(first, ...)
  end
end

-- The hooks as a kind table (`kind:hook(ctx, ...)`), for a caller that would
-- rather register or delegate to a kind than call the functions above.
M.kind = {}
for _, name in ipairs(M.HOOKS) do
  local fn = Hooks[name]
  M.kind[name] = function(_, ...) return fn(...) end
end

return M
