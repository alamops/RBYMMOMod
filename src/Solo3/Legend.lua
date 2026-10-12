-- Roamers, scripted wilds, legendaries and the POKeMON TOWER ghosts, fought
-- solo: the Legend family of the Gen 3 solo kind registry (contract C2 of
-- docs/plans/gen3-solo-remaining-fights.md; the research in §1.3 of
-- docs/plans/gen3-solo-remaining-fights-research.md, the wave-1 contracts
-- this builds on in its part 2).
--
-- Four kinds, the names src/CoopField.lua's classify3 stamps on a stand as
-- `kind3` and src/SoloBattle.lua's KIND_FILES3 maps to this file:
--
--   roamer      FireRed / LeafGreen's beasts, Emerald's Latios / Latias
--               (BATTLE_TYPE_ROAMER, a step encounter's `enc.roamer`)
--   legendary   StartLegendaryBattle and Emerald's legend specials
--               (BATTLE_TYPE_LEGENDARY: the `legendary` / `specialWild` /
--               `regi` / `kyogreGroudon` ... keys)
--   scripted    setwildbattle + dowildbattle (BATTLE_TYPE_WILD_SCRIPTED: the
--               Snorlaxes, the Electrodes, the Hypno)
--   ghost       a POKeMON TOWER wild without the SILPH SCOPE, and the Marowak
--               (BATTLE_TYPE_GHOST, GHOST_UNVEILED with the scope)
--
-- Every one of them is the ordinary wild fight with a few rules moved, and
-- the core already plays most of them: the cart's random wild move on every
-- wild seat (`wildPick = "cart"`, pret battle_controller_opponent.c: no AI
-- outside TRAINER | FIRST_BATTLE | SAFARI | ROAMER -- so FireRed's legendary
-- AI flags are dead code on the cart), no held-item roll under LEGENDARY
-- (SoloBattle.gen3HeldRoll, at the stand), the `fateful` bit on the sheet,
-- and the engine's outcome word read off how the referee says the fight
-- ended, with each cart's TELEPORT / ROAR rule (SoloBattle.gen3Words).  What
-- is left is this file's:
--
--   * seating -- the roamer's AI_Roaming (side entry `ai = "roamer"`) over
--     the monster as the save holds it; the ghost's referee option and the
--     screen's;
--   * the music -- FireRed / LeafGreen's own themes, where the engine port
--     plays another (E4);
--   * the dex -- FireRed / LeafGreen mark no "seen" for a legendary or a
--     veiled ghost (E7);
--   * the roamer's writeback -- the engine's own Roamer.onBattleEnd, once,
--     with the cart's deactivation rule where the port "fixed" it (E1);
--   * the roamer's hand-back -- the cart's battle restarted as the roamer
--     encounter it was.
--
-- E1..E7 are the engine-port divergences of the research (§1.3); each one
-- this file meets is named beside the code that follows pret instead.
--
-- Solo only: co-op refuses every one of these kinds (Config.COOP_REFUSED_GEN3,
-- contract C1), so nothing here is ever on a hub's wire.

local need, mod = ...
local Gen3 = need("Gen3")

local M = {}

local floor, max, min = math.floor, math.max, math.min

local function int(v, fallback)
  local n = tonumber(v)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function set3(v) return v ~= nil and v ~= false end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

-- Siblings reached when a fight asks, never at load: this file is read by
-- SoloBattle.kind3 the first time a fight of one of its kinds is met, long
-- after the graph that needs SoloBattle and CoopField has loaded -- a
-- file-scope need() would be a cycle the mod's resolver refuses the day
-- anything reads this file earlier.
local function sibling(name)
  if type(need) ~= "function" then return nil end
  local ok, value = pcall(need, name)
  if ok and type(value) == "table" then return value end
  return nil
end

local function warn(fmt, ...)
  if type(mod) == "table" and type(mod.log) == "table" and type(mod.log.warn) == "function" then
    mod.log:warn(fmt, ...)
  end
end

local function familyOf(ctx)
  local f = type(ctx) == "table" and ctx.family or nil
  if f == "frlg" or f == "rse" then return f end
  return Gen3.family() or "frlg"
end

-- An engine monster the core would fight as it is (SoloBattle's prebuilt3):
-- a species, a level, a move list.
local function prebuilt(mon)
  return type(mon) == "table" and int(mon.species, 0) > 0 and int(mon.level, 0) > 0
    and type(mon.moves) == "table" and #mon.moves > 0
end

-- The referee's sheet of the wild monster (side b's only seat in a single).
local function foeSheet(ctx)
  local sim = type(ctx) == "table" and ctx.sim or nil
  local foe = sim and type(sim.byId) == "table" and sim.byId.solo_foe or nil
  return foe and type(foe.mons) == "table" and foe.mons[1] or nil
end

-- ------------------------------------------------------------------
-- the status byte a roamer keeps
-- ------------------------------------------------------------------
--
-- pret STATUS1_* (include/constants/battle.h): bits 0-2 the sleep counter,
-- then POISON 8, BURN 16, FREEZE 32, PARALYSIS 64, TOXIC_POISON 128.  The cart
-- banks the whole byte (UpdateRoamerHPStatus: ROAMER->status =
-- GetMonData(mon, MON_DATA_STATUS)), sleep counter included, and
-- CreateRoamerMonInstance hands it back to the next encounter -- so a roamer
-- put to sleep wakes on the turn the cart says, not on a fresh roll.  It is
-- the byte the engine's own save converters read (save_convert Gen3Save /
-- gen3_port rse: `statusNum`, else a numeric `status`) and the one
-- src/CoopField.lua's status3 decodes for the next stand.  A sleeping
-- monster whose counter nobody knows (an engine battle's word, banked
-- without one, and never ticked here) is handed on as that word: a byte
-- with a counter of 0 would be an awake monster, and a counter made up here
-- would be a roll the cart never made.  (The engine's Roamer.statusWord
-- then banks it with a counter of 1 -- its call, not this file's.)
M.STATUS1_BITS = { PSN = 8, BRN = 16, FRZ = 32, PAR = 64, TOX = 128 }

-- -> the byte, or nil for a sleeping monster with no known counter.
function M.statusByte3(status, sleep)
  if status == nil or status == 0 or status == "" then return 0 end
  if type(status) == "number" then return floor(status) % 256 end
  if type(status) ~= "string" then return 0 end
  local word = status:upper()
  if word == "SLP" or word == "SLEEP" then
    local turns = int(sleep, 0)
    if turns <= 0 then return nil end
    return min(7, turns)
  end
  if word == "POISON" then word = "PSN" elseif word == "BURN" then word = "BRN"
  elseif word == "FREEZE" then word = "FRZ" elseif word == "PARALYSIS" then word = "PAR"
  elseif word == "TOXIC" then word = "TOX" end
  return M.STATUS1_BITS[word] or 0
end

-- The roamer as the fight left it, in the shape Roamer.onBattleEnd reads
-- (`hp`, `status` and `sleep`; an engine from before roamer.lua's rewrite
-- read FireRed's `statusNum` too): the engine monster the core
-- wrote the referee's HP and status onto (SoloBattle M:_settle3,
-- Sheet3.applyToMon), and the sleep counter off the referee's own sheet --
-- applyToMon writes the word, not the counter (the core's _reconcile3 does
-- the same for the player's monsters).  The counter goes onto the engine
-- monster too: a roamer that was caught is that monster, now in the party.
function M.roamerState3(mon, sheet)
  mon = type(mon) == "table" and mon or nil
  sheet = type(sheet) == "table" and sheet or nil
  local hp = int(mon and mon.hp, nil)
  if hp == nil then hp = int(sheet and sheet.hp, 0) end
  local status = (mon and mon.status) or nil
  if mon == nil then status = sheet and sheet.status or nil end
  local sleep = nil
  if type(status) == "string" and status:upper() == "SLP" then
    sleep = int(sheet and sheet.sleepTurns, nil) or int(mon and (mon.sleep or mon.sleepTurns), nil)
    if mon and sleep and sleep > 0 then mon.sleep = sleep end
  end
  local byte = M.statusByte3(status, sleep)
  return {
    hp = max(0, hp),
    status = byte or status,
    statusNum = byte,
    sleep = sleep,
  }
end

-- ------------------------------------------------------------------
-- the music
-- ------------------------------------------------------------------
--
-- pret pokefirered battle_setup.c StartLegendaryBattle switches on the
-- species (the cart's internal id, read here through the engine's own
-- SPECIES_* table, so no number is written down); StartRoamerBattle starts
-- MUS_VS_LEGEND for every beast.  The engine's species table
-- (audio.lua LEGENDARY_BATTLE_SONGS) gives the beasts MUS_VS_DEOXYS (E4) --
-- pret wins.  Each entry is the engine's audio role first (a music pack's
-- own mapping, as Audio.legendaryBattleSong asks it), else the MUS_* name.
-- Emerald names its legends' themes on the start itself (`opts.song`, the
-- natives' BattleProfile.song), and its roamers play the ordinary wild theme
-- (BattleSetup_StartRoamerBattle starts song 0): nothing to add there.
M.FRLG_LEGEND_SONGS3 = {
  { "SPECIES_MEWTWO", "battleMewtwo", "MUS_VS_MEWTWO" },
  { "SPECIES_DEOXYS", "battleDeoxys", "MUS_VS_DEOXYS" },
  { "SPECIES_MOLTRES", "battleLegend", "MUS_VS_LEGEND" },
  { "SPECIES_ARTICUNO", "battleLegend", "MUS_VS_LEGEND" },
  { "SPECIES_ZAPDOS", "battleLegend", "MUS_VS_LEGEND" },
  { "SPECIES_HO_OH", "battleLegend", "MUS_VS_LEGEND" },
  { "SPECIES_LUGIA", "battleLegend", "MUS_VS_LEGEND" },
}
-- The switch's `default:` (and StartGroudonKyogreBattle / StartRegiBattle on
-- FireRed, should a cart ever reach them).
M.FRLG_LEGEND_DEFAULT3 = "MUS_RS_VS_TRAINER"
M.FRLG_ROAMER_SONG3 = { "battleLegend", "MUS_VS_LEGEND" }

local function roleOr(roleName, musName)
  local Audio = Gen3.engine("src.core.game3.audio")
  local id = Audio and int(try(Audio.role, roleName), nil)
  return id or musName
end

-- FireRed / LeafGreen's theme for a legendary of this species, or nil when
-- the cart's species names cannot be read (the screen then plays its own).
function M.frlgLegendSong3(species)
  local sp = int(species, nil)
  local Constants = Gen3.engine("src.core.game3.constants")
  local C = Constants and try(Constants.of, Gen3.version() or "firered")
  if not (sp and type(C) == "table" and type(C.id) == "function") then return nil end
  local readable = false
  for _, row in ipairs(M.FRLG_LEGEND_SONGS3) do
    local id = int(try(C.id, C, "species", row[1]), nil)
    if id then
      readable = true
      if id == sp then return roleOr(row[2], row[3]) end
    end
  end
  if not readable then return nil end
  return M.FRLG_LEGEND_DEFAULT3
end

-- The battle theme a kind's fight opens with: the start's own (`opts.song`,
-- already on ctx.song), else FireRed / LeafGreen's.
function M.song3(ctx, kindName)
  if ctx.song ~= nil then return ctx.song end
  if familyOf(ctx) ~= "frlg" then return nil end
  if kindName == "roamer" then return roleOr(M.FRLG_ROAMER_SONG3[1], M.FRLG_ROAMER_SONG3[2]) end
  if kindName == "legendary" then
    local mon = ctx.wildMon or (type(ctx.party) == "table" and ctx.party[1]) or nil
    local species = mon and (mon.species or mon.speciesId)
      or (type(ctx.foe) == "table" and (ctx.foe.species or ctx.foe.speciesId)) or nil
    return M.frlgLegendSong3(species)
  end
  return nil
end

local function screenSong(ctx, screenOpts, kindName)
  if screenOpts.song ~= nil then return end
  local song = M.song3(ctx, kindName)
  if song ~= nil then screenOpts.song = song end
end

-- ------------------------------------------------------------------
-- the dex
-- ------------------------------------------------------------------
--
-- pret pokefirered battle_main.c:2614-2631 (BattleIntroDrawTrainersOrMonsSprites'
-- wild arm): a GHOST battle marks the monster seen only with the SILPH
-- SCOPE (IS_BATTLE_TYPE_GHOST_WITHOUT_SCOPE), every other wild unless the
-- battle is LEGENDARY (or an e-Reader, the POKeDUDE, a link, the old man) --
-- the engine marks FireRed's legendaries seen (E7).  Emerald's list has no
-- LEGENDARY (pokeemerald battle_main.c:3456): its legends are seen.  A roamer
-- and a scripted wild are seen on both carts.
function M.noDexSeen3(kindName, family, ghost)
  if kindName == "legendary" then return family == "frlg" end
  if kindName == "ghost" then return ghost ~= "unveiled" end
  return false
end

-- ------------------------------------------------------------------
-- the ghost
-- ------------------------------------------------------------------

-- "veiled" | "unveiled": the stand's word (classify3: the start's
-- `ghostUnveiled`, the Marowak met with the SILPH SCOPE), else the same keys
-- on the start's opts or the foe, for a fight that arrived without a stand.
function M.ghostOf3(ctx)
  local g = type(ctx) == "table" and ctx.ghost3 or nil
  if g == "veiled" or g == "unveiled" then return g end
  local opts = type(ctx) == "table" and type(ctx.opts) == "table" and ctx.opts or {}
  local foe = type(ctx) == "table" and type(ctx.foe) == "table" and ctx.foe or {}
  if set3(opts.ghostUnveiled) or set3(foe.ghostUnveiled) then return "unveiled" end
  return "veiled"
end

-- ------------------------------------------------------------------
-- the roamer
-- ------------------------------------------------------------------

-- The save's descriptor of the roamer, as the encounter carried it
-- (Roamer.tryEncounter returns { species, level, roamer, foe = <descriptor> };
-- the stand keeps it as `roamerFoe`).
local function roamerFoe(ctx)
  local stand = type(ctx.stand) == "table" and ctx.stand or nil
  if stand and type(stand.roamerFoe) == "table" then return stand.roamerFoe end
  local enc = type(ctx.foe) == "table" and ctx.foe or nil
  if enc and type(enc.foe) == "table" then return enc.foe end
  return enc
end

-- The roamer the cart builds (pret CreateRoamerMonInstance: the saved
-- species, level, IVs and personality, then the saved HP and status) -- the
-- stand-in builds it so (CoopField.wildFoe3, pret over the engine's E5) and
-- hands it in as `opts.party` / `enc.mon`; a fight that arrived without one
-- (a direct caller) is built here by the very same builder, rather than by
-- the core's, which would build the encounter's outer species and level --
-- E5's re-rolled IVs and full HP.
local function ensureRoamer(ctx)
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  local enc = type(ctx.foe) == "table" and ctx.foe or nil
  if prebuilt(ctx.wildMon) then return end
  if type(opts.party) == "table" and prebuilt(opts.party[1]) then return end
  if enc and prebuilt(enc.mon) then return end
  if not enc then return end
  local CoopField = sibling("CoopField")
  if not (CoopField and type(CoopField.wildFoe3) == "function") then return end
  local ok, mon = pcall(CoopField.wildFoe3, { kind3 = "roamer" }, enc, ctx.session, opts)
  if ok and prebuilt(mon) then
    ctx.wildMon = mon
    ctx.party = { mon }
  end
end

-- The word gBattleOutcome holds at the end (Natives.outcome_to_code's
-- vocabulary): the core's save word, except a knockout on both sides, which
-- is DREW -- Cmd_checkteamslost ORs LOST and WON into 3 -- though the player
-- whites out for it (IsPlayerDefeated counts DREW) and the core words that
-- ending "lose".
function M.roamerWord3(ctx, outcome, ending)
  local word = type(ending) == "table" and ending.word or nil
  if type(ctx) == "table" and ctx.verdict == "draw" and type(outcome) == "table"
      and (outcome.how == "ko" or (outcome.how == nil and outcome.reason == "ko")) then
    return "draw"
  end
  return word
end

-- The writeback (pret ReturnFromBattleToOverworld, BATTLE_TYPE_ROAMER --
-- pokefirered battle_main.c:3927, pokeemerald :5232):
--
--   UpdateRoamerHPStatus(&gEnemyParty[0]);   -- HP, status byte, and
--                                            -- RoamerMoveToOtherLocationSet
--   if ((gBattleOutcome & B_OUTCOME_WON) || gBattleOutcome == B_OUTCOME_CAUGHT)
--       SetRoamerInactive();
--
-- The roamer always moves (the move comes first, while it is still active),
-- and any odd outcome -- WON 1, DREW 3, PLAYER_TELEPORTED 5, CAUGHT 7,
-- FORFEITED 9 -- puts it away for good: the vanilla bug a WHIRLWIND or a
-- roamer's own ROAR on FireRed trips (5), and a roamer that went down with
-- the player's last monster (DREW, M.roamerWord3) is never left roaming at
-- 0 HP.  It is FireRed / LeafGreen 1.0's rule and Emerald's; the 1.1
-- revisions fixed it (pokefirered `REVISION >= 0xA`: WON, CAUGHT or DREW),
-- and the engine reads every FRLG cart as its 1.0
-- (src/import/gba/versions_frlg.lua normalises a 1.1 ROM to its 1.0), so
-- 1.0 is the rule played.
--
-- The engine's own Roamer.onBattleEnd is called, once, for the HP and the
-- status.  Its arm is pret's on every cart (moveToOtherSet, then
-- `code % 2 == 1`; roamer.lua, with its config off the battle profile).  An
-- engine from before that rewrite (no Roamer.config) ran FireRed's arm its
-- own way: it kept the roamer for every ending but a catch or a knockout and
-- relocated only the roamer it kept (Roamer.jump) -- the port "fixed" the
-- bug (E1).  There, a FireRed roamer about to be put away is moved first
-- (what UpdateRoamerHPStatus does before the check); on either engine, one
-- left active on an odd outcome is put away after.
function M.roamerFinish3(ctx, outcome, ending)
  local session = ctx.session
  local roamer = type(session) == "table" and session.roamer or nil
  if type(roamer) ~= "table" or not roamer.active then return false end
  local Roamer = Gen3.engine("src.core.game3.roamer")
  if not (Roamer and type(Roamer.onBattleEnd) == "function") then
    warn("the roaming POKeMON's HP and whereabouts could not be saved after this battle (no "
      .. "roamer module on this build); it keeps the HP it had before -- update the game")
    return false
  end
  local word = M.roamerWord3(ctx, outcome, ending)
  local Natives = Gen3.engine("src.core.game3.scripting.natives")
  local code = int(Natives and try(Natives.outcome_to_code, word), nil) or int(session.battleOutcome, 0)
  local state = M.roamerState3(ctx.wildMon, foeSheet(ctx))
  local pretArm = type(Roamer.config) == "function"
    or (type(Roamer.rseConfig) == "function" and try(Roamer.rseConfig, session) ~= nil)
    or (Roamer.rseConfig == nil and familyOf(ctx) == "rse")
  if not pretArm and (word == "caught" or state.hp <= 0) and type(Roamer.jump) == "function" then
    pcall(Roamer.jump, session)
  end
  local ok, err = pcall(Roamer.onBattleEnd, session, state, word)
  if not ok then
    warn("the roaming POKeMON's HP and whereabouts could not be saved after this battle (%s); "
      .. "it keeps the HP it had before -- report this with the battle you were in", tostring(err))
    return false
  end
  if code % 2 == 1 and roamer.active then roamer.active = false end
  return true
end

-- The roamer encounter the cart's own battle restarts with: the monster
-- that was met (SoloBattle.gen3HandedFoe: its personality, IVs, nature,
-- moves ride on the row) as a roamer -- `roamer` on the foe, the save's
-- descriptor as its `foe`, and the HP and status it was met with -- so the
-- engine's battle banks its HP and moves it on at its end
-- (battle_bridge.lua finish: Roamer.onBattleEnd for `opts.roamer or
-- foe.roamer`).  The shape src/Client.lua's step-encounter hand-back
-- builds.
function M.handedRoamer3(ctx)
  local Solo = sibling("SoloBattle")
  local stand = type(ctx.stand) == "table" and ctx.stand or nil
  local enc = (stand and type(stand.encounter) == "table" and stand.encounter)
    or (type(ctx.foe) == "table" and ctx.foe) or {}
  local mon = ctx.wildMon or (type(ctx.party) == "table" and ctx.party[1]) or nil
  local foe
  if Solo and type(Solo.gen3HandedFoe) == "function" then
    foe = Solo.gen3HandedFoe(enc, mon)
  else
    foe = {}
    for k, v in pairs(enc) do foe[k] = v end
    foe.mon = nil
  end
  if foe == enc then
    foe = {}
    for k, v in pairs(enc) do foe[k] = v end
  end
  foe.roamer = true
  local descriptor = roamerFoe(ctx)
  foe.foe = (type(descriptor) == "table" and descriptor ~= enc) and descriptor or foe.foe
  if type(mon) == "table" then
    foe.hp, foe.status, foe.sleep = mon.hp, mon.status, mon.sleep
  end
  return foe
end

-- Hand-back (SoloBattle M:_reset3): the door's own restart when it gave one
-- (`opts.fallback` -- the stand-in's fightAlone, which src/Client.lua builds
-- as this same roamer encounter, with the stand's bookkeeping); else the
-- engine's wild start here, with the roamer encounter, marked as a hand-back
-- so no divert offers it again (CoopField.HANDBACK3; the core's own guard,
-- `handingBack3`, is up around this hook as well).
function M.roamerHandBack3(ctx)
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  if type(opts.fallback) == "function" then return false end
  local BB = Gen3.engine("src.core.game3.battle_bridge")
  if not (BB and type(BB.startWild) == "function") then return false end
  local startOpts = {}
  for k, v in pairs(opts) do
    if k ~= "fallback" and k ~= "done" and k ~= "mapId" and k ~= "party" and k ~= "stand3" then
      startOpts[k] = v
    end
  end
  startOpts.roamer = true
  startOpts.done = ctx.done
  local CoopField = sibling("CoopField")
  if CoopField and type(CoopField.HANDBACK3) == "string" then startOpts[CoopField.HANDBACK3] = true end
  local Runtime = Gen3.engine("src.core.game3.runtime")
  local ok, err = pcall(BB.startWild, Runtime and Runtime._mod,
    (Runtime and Runtime._game) or ctx.game, M.handedRoamer3(ctx), startOpts)
  if not ok then
    warn("the roaming POKeMON's battle could not be started again (%s); walk on and it will "
      .. "turn up again, or reload from your last save", tostring(err))
    -- battle_bridge's own failed start answers `done("win")`: whatever
    -- waits on the battle is released rather than left frozen.
    if type(ctx.done) == "function" then pcall(ctx.done, "win") end
  end
  return true
end

-- ------------------------------------------------------------------
-- the kinds
-- ------------------------------------------------------------------

local Roamer = {}

function Roamer:takes(ctx)
  ensureRoamer(ctx)
  ctx.noDexSeen = M.noDexSeen3("roamer", familyOf(ctx)) or nil
  return true
end

function Roamer:screen(ctx, screenOpts)
  screenSong(ctx, screenOpts, "roamer")
end

-- pret BattleAI_SetupFlags: BATTLE_TYPE_ROAMER runs AI_ROAMING on the wild
-- seat (pokefirered battle_ai_script_commands.c, pokeemerald likewise) --
-- the referee's `ai = "roamer"` (contract C3): flee unless wrapped /
-- escape-prevented / Shadow Tag / Arena Trap without Levitate, asleep or
-- frozen included; else the random usable move.  On the core's own side-b
-- entry, the monster it seats being the one the stand built.
function Roamer:seat(ctx, create)
  local b = type(create.sides) == "table" and type(create.sides.b) == "table" and create.sides.b[1]
  if type(b) == "table" then b.ai = "roamer" end
end

function Roamer:finish(ctx, outcome, ending)
  M.roamerFinish3(ctx, outcome, ending)
end

function Roamer:handBack(ctx)
  return M.roamerHandBack3(ctx)
end

local Legendary = {}

function Legendary:takes(ctx)
  ctx.noDexSeen = M.noDexSeen3("legendary", familyOf(ctx)) or nil
  return true
end

function Legendary:screen(ctx, screenOpts)
  screenSong(ctx, screenOpts, "legendary")
end

-- setwildbattle + dowildbattle: the ordinary wild fight on every count the
-- core plays (the cart's wild move, the held-item roll at the stand, a dex
-- "seen", the ordinary theme).  Registered so it is taken at all: a kind
-- nobody registered is the cart's.
local Scripted = {}

function Scripted:takes(ctx)
  return true
end

local Ghost = {}

function Ghost:takes(ctx)
  local ghost = M.ghostOf3(ctx)
  ctx.ghost3 = ghost
  ctx.noDexSeen = M.noDexSeen3("ghost", familyOf(ctx), ghost) or nil
  return true
end

-- The screen's `ghost` (MediatedBattle: the silhouette and "GHOST" until the
-- unveil, the cart's intro lines, the dodged ball and the scared lines).
function Ghost:screen(ctx, screenOpts)
  screenOpts.ghost = M.ghostOf3(ctx)
end

-- The referee's `ghost` (contract C3): veiled, every move of both sides is
-- cancelled, RUN always works, a ball is dodged and spent, no weather chip
-- on the ghost, no Intimidate / Trace; unveiled, a ball is still dodged.
-- The Marowak's script reads VAR_RESULT FALSE only on a win (pret
-- CB2_EndMarowakBattle; the engine's StartMarowakBattle sets it from
-- Natives.outcome_to_code of the word `done` is handed): the core's word is
-- the cart's gBattleOutcome -- "win" only for a knockout the player won --
-- so no word of this kind's own.
function Ghost:seat(ctx, create)
  return { ghost = M.ghostOf3(ctx) }
end

M.kinds3 = {
  roamer = Roamer,
  legendary = Legendary,
  scripted = Scripted,
  ghost = Ghost,
}

return M
