-- The Safari Zone, fought by SOLO BATTLES: the `safari` kind of the Gen 3
-- solo kind registry (contract C2 of docs/plans/gen3-solo-remaining-fights.md;
-- the research in §1.2 of docs/plans/gen3-solo-remaining-fights-research.md,
-- the referee's Safari mode as built in its §3.1, this file's remainder in
-- §3.4 K-SAF).
--
-- A wild monster met while the Safari Zone's mode is on (src/CoopField.lua's
-- classify3: `safari` on the start, or a standard wild with the session's
-- Safari mode on -- battle_bridge.lua safari_mode_active) is the cart's
-- BATTLE_TYPE_SAFARI: the player's battler zeroed (pret pokefirered
-- battle_main.c:2565), a menu of throws, the player always first.  The
-- referee plays all of it (src/BattleSim3/Safari.lua, Turn.create's `safari`
-- option); the screen draws it (MediatedBattle's `safari` screen option).
-- What is this file's:
--
--   * seating -- the referee's `safari` option, read from the player's own
--     cart and save through the engine: the family, the SAFARI BALLS the
--     session carries, and Emerald's three tables (sGoNearCounterToCatchFactor,
--     sGoNearCounterToEscapeFactor, sPkblToEscapeFactor) out of the engine's
--     own cache of them (Rules.safari.rseTables -- the cart's bytes, decoded
--     at import, never written down here); side a the trainer alone; the
--     screen told it fields nothing and which menu to draw;
--   * the POKeBLOCK (Emerald) -- the case slot the screen names, read off the
--     save; the cart's verdict from the wild monster's nature; the block out
--     of the save at once, as the case takes it (pret pokeblock.c:1256
--     PokeblockAction_UseInBattle);
--   * the full BOX -- a BALL refused at selection, nothing spent (pret
--     HandleTurnActionSelectionState's B_ACTION_SAFARI_BALL arm, pokefirered
--     battle_main.c:3223, pokeemerald :4269);
--   * the SAFARI BALLS home -- on every throw, as the engine's own battle
--     syncs them (battle/init.lua safari_sync_balls), and from the referee's
--     summary at the end;
--   * the end -- the engine's own Safari tails, after the caller's `done`,
--     in the order battle/init.lua runs them after its battle's callback:
--     Emerald's Safari.endBattleRse (the Fan Club's counters, and the out-of-
--     balls scripts -- pret pokeemerald safari_zone.c:97 CB2_EndSafariBattle),
--     FireRed / LeafGreen's Safari.outOfBallsMidBattle when the last ball
--     missed (pret pokefirered safari_zone.c:66, CB2_EndSafariBattle's
--     NO_SAFARI_BALLS arm; its CAUGHT arm, :73, is the field's own poll,
--     Field.pollSafariBalls).
--
-- What the core already does for a Safari fight and needs nothing here: the
-- word (SoloBattle.gen3Words off the referee's `how`: "balls" ->
-- no_safari_balls 8, "catch" -> caught 7, "flee" -> mon_fled 6, "run" -> run
-- 4); the SAFARI BALL left out of gBattleResults' catch counts (M:_note3,
-- pret Cmd_handleballthrow's ITEM_SAFARI_BALL test); the quest log's caught
-- scene on FireRed / LeafGreen and no POKeMON TODAY on Emerald (the battle
-- type it tells both carries `safari` -- SoloBattle.engineFlags3 -- and the
-- TV leaves it out, pret battle_main.c:5102); Emerald's Pokérus; the start's
-- bookkeeping (CoopField Stand:begin3: no wild-battle tick for a Safari
-- start).  No EXP (side a fields no battler), and the flags below take the
-- rest away: no reconcile, no whiteout, no Pickup.
--
-- Solo only: co-op refuses the Safari Zone (Config.COOP_REFUSED_GEN3,
-- contract C1), so nothing here is ever on a hub's wire.
--
-- Loaded lazily by src/SoloBattle.lua (KIND_FILES3: safari -> "Solo3/Safari").

local need, mod = ...
local Gen3 = need("Gen3")

local M = {}

local floor, max, min = math.floor, math.max, math.min

local function int(v, fallback)
  local n = tonumber(v)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

-- Siblings reached when a fight asks, never at load (src/Solo3/Legend.lua's
-- reason: this file is read by SoloBattle.kind3 long after the graph that
-- needs SoloBattle has loaded, and a file-scope need() would be a cycle the
-- day anything reads it earlier).
local function sibling(name)
  if type(need) ~= "function" then return nil end
  local ok, value = pcall(need, name)
  if ok and type(value) == "table" then return value end
  return nil
end

-- Said once a fight where the core can say it (its per-fight `warn`), else
-- through the facade's log.
local function warn(ctx, key, fmt, ...)
  local solo = type(ctx) == "table" and ctx.solo or nil
  if type(solo) == "table" and type(solo.warn) == "function" then
    return solo:warn("safari3:" .. key, fmt, ...)
  end
  if type(mod) == "table" and type(mod.log) == "table" and type(mod.log.warn) == "function" then
    mod.log:warn(fmt, ...)
  end
end

local function familyOf(ctx)
  local f = type(ctx) == "table" and ctx.family or nil
  if f == "frlg" or f == "rse" then return f end
  return Gen3.family() or "frlg"
end

local function profile(session)
  local BP = Gen3.engine("src.core.game3.battle.profile")
  local bp = BP and try(BP.get, session or Gen3.session()) or nil
  return type(bp) == "table" and bp or nil
end

-- pret ITEM_SAFARI_BALL: the one item a Safari fight's `item` events name
-- (the referee's Catch.SAFARI).
M.ITEM_SAFARI_BALL = 5
-- pret gNumSafariBalls is a u8.
M.BALLS_MAX = 255
-- pret PARTY_SIZE.
M.PARTY_SIZE = 6
-- pret POKEBLOCKS_COUNT (include/constants/global.h): the case's slots, which
-- the screen names 1-based (Wire.POKEBLOCK3_MAX).
M.POKEBLOCKS = 40
-- pret NUM_NATURES (GetNatureFromPersonality: personality % 25).
M.NATURES = 25
-- The referee's POKeBLOCK verdicts (BattleSim3/Safari.lua; pret
-- include/constants/battle_string_ids.h B_MSG_MON_CURIOUS / ENTHRALLED /
-- IGNORED).
M.CURIOUS, M.ENTHRALLED, M.IGNORED = 0, 1, 2

-- pret BattleScript_PrintFullBox's STRINGID_BOXISFULL (both carts'
-- battle_message.c sText_BoxIsFull), when the player's text pack cannot say
-- it.
M.BOX_FULL = "STRINGID_BOXISFULL"
M.BOX_FULL_TEXT = "The BOX is full!\nYou can't catch any more!"

-- ------------------------------------------------------------------
-- the referee's `safari` option, from the player's cart and save
-- ------------------------------------------------------------------

-- Emerald's three tables in the referee's shape (BattleSim3/Safari.lua
-- M.options: 1-based lists, pret index i at list[i + 1]), from the engine's
-- decoding of the player's cart (src/import/gba/rse/safari_rse_extract.lua:
-- the go-near lists 1-based already, sPkblToEscapeFactor's rows 0-keyed,
-- each a 1-based list of three).  -> { goNearCatch, goNearEscape,
-- pkblToEscape }, or nil when the cache does not hold them whole.
function M.rseTables3(t)
  if type(t) ~= "table" then return nil end
  local function list(raw, n)
    if type(raw) ~= "table" then return nil end
    local out = {}
    for i = 1, n do
      local v = int(raw[i], nil)
      if v == nil then return nil end
      out[i] = v
    end
    return out
  end
  -- The referee's own lengths: four go-near steps (counter 0..3), four rows
  -- the pokeblock counter can reach (0..3; the cart's table has a fifth,
  -- copied too), three verdicts a row.
  local goNearCatch = list(t.goNearCounterToCatchFactor, 4)
  local goNearEscape = list(t.goNearCounterToEscapeFactor, 4)
  local rows = type(t.pkblToEscapeFactor) == "table" and t.pkblToEscapeFactor or nil
  if not (goNearCatch and goNearEscape and rows) then return nil end
  local pkbl = {}
  local r = 0
  while rows[r] ~= nil do
    local row = list(rows[r], 3)
    if not row then return nil end
    pkbl[r + 1] = row
    r = r + 1
  end
  if #pkbl < 4 then return nil end
  return { goNearCatch = goNearCatch, goNearEscape = goNearEscape, pkblToEscape = pkbl }
end

-- The SAFARI BALLS this fight opens with: the session's (pret gNumSafariBalls;
-- the engine's battle start, battle/init.lua:735, carries
-- session.safari.balls over its own default), else the engine's own start
-- default -- Emerald's battle-profile row (EnterSafariMode's 30, cfg.balls),
-- FireRed / LeafGreen's Rules.safari.BALLS.  nil when none can be read.
function M.balls3(session, family, cfg)
  local state = type(session) == "table" and type(session.safari) == "table" and session.safari or nil
  local carried = state and int(state.balls, nil)
  if carried ~= nil then return min(M.BALLS_MAX, max(0, carried)) end
  if family == "rse" then
    local n = type(cfg) == "table" and int(cfg.balls, nil) or nil
    if n then return min(M.BALLS_MAX, max(0, n)) end
    return nil
  end
  local Rules = Gen3.engine("src.core.game3.battle.rules")
  local n = Rules and type(Rules.safari) == "table" and int(Rules.safari.BALLS, nil) or nil
  if n then return min(M.BALLS_MAX, max(0, n)) end
  return nil
end

-- The whole option (BattleSim3/Safari.lua M.options):
--   { family = "frlg" | "rse", balls,
--     goNearCatch, goNearEscape, pkblToEscape }   (the last three Emerald's)
-- plus, kept on the side for the POKeBLOCK's verdict, the engine's decoded
-- tables (`tables`, whose flavorCompatibility is
-- gPokeblockFlavorCompatibilityTable).  -> option, tables | nil, why.
function M.option3(ctx)
  local session = ctx.session or Gen3.session()
  local family = familyOf(ctx)
  local cfg, tables = nil, nil
  local opt = { family = family }
  if family == "rse" then
    local bp = profile(session)
    cfg = bp and type(bp.safari) == "table" and bp.safari or nil
    if not cfg then return nil, "this game's battle profile has no Safari Zone row" end
    local Rules = Gen3.engine("src.core.game3.battle.rules")
    local read = Rules and type(Rules.safari) == "table" and Rules.safari.rseTables or nil
    tables = try(read, cfg)
    local lists = M.rseTables3(tables)
    if not lists then
      return nil, "the Safari Zone's GO NEAR and POKeBLOCK tables are missing from this game's "
        .. "imported data"
    end
    opt.goNearCatch, opt.goNearEscape, opt.pkblToEscape =
      lists.goNearCatch, lists.goNearEscape, lists.pkblToEscape
  end
  opt.balls = M.balls3(session, family, cfg)
  if opt.balls == nil then return nil, "the SAFARI BALLS this save carries could not be read" end
  return opt, tables
end

-- ------------------------------------------------------------------
-- the full BOX
-- ------------------------------------------------------------------

-- pret IsPlayerPartyAndPokemonStorageFull (pokeemerald pokemon.c:4609; FireRed
-- / LeafGreen the same): every party slot holds a species -- an EGG counts --
-- and IsPokemonStorageFull finds no empty box slot.  The box half is the
-- engine's own question (Storage.findOpenSlot over Storage.ensure, as its
-- catch asks it -- battle/catching.lua).  False when either half cannot be
-- asked: a throw refused for a module this build lacks would be a Safari the
-- player cannot play.
function M.boxFull3(session)
  local party = type(session) == "table" and session.party or nil
  if type(party) ~= "table" then return false end
  for i = 1, M.PARTY_SIZE do
    local mon = party[i]
    if type(mon) ~= "table" or int(mon.species or mon.speciesId, 0) <= 0 then return false end
  end
  local Storage = Gen3.engine("src.core.game3.storage")
  if not (Storage and type(Storage.ensure) == "function"
          and type(Storage.findOpenSlot) == "function") then
    return false
  end
  local storage = try(Storage.ensure, session)
  if type(storage) ~= "table" then return false end
  local ok, box = pcall(Storage.findOpenSlot, storage)
  if not ok then return false end
  return box == nil
end

-- The line BattleScript_PrintFullBox prints (printselectionstring
-- STRINGID_BOXISFULL), in the player's cart's words.
function M.boxFullText3()
  return Gen3.battleText(M.BOX_FULL) or M.BOX_FULL_TEXT
end

-- ------------------------------------------------------------------
-- the POKeBLOCK (Emerald)
-- ------------------------------------------------------------------

-- pret GetNature(&gEnemyParty[0]): the personality's nature
-- (GetNatureFromPersonality, % NUM_NATURES); a monster that carries none is
-- read by its own `nature`.
function M.nature3(mon)
  if type(mon) ~= "table" then return 0 end
  local p = int(mon.personality, nil)
  if p ~= nil then return p % M.NATURES end
  return int(mon.nature, 0) % M.NATURES
end

-- PokeblockAction_UseInBattle (pret pokeblock.c:1256): gain 0 -> curious,
-- above 0 -> enthralled, below -> ignored (the controller's gSpecialVar_ItemId
-- + 1 / + 2 / + 3, battle_util.c:566's `- 1`).
function M.verdict3(gain)
  gain = tonumber(gain)
  if gain == nil then return nil end
  if gain == 0 then return M.CURIOUS end
  if gain > 0 then return M.ENTHRALLED end
  return M.IGNORED
end

-- pret PokeblockGetGain(nature, block) (pokeblock.c:1407) against the cart's
-- gPokeblockFlavorCompatibilityTable: the engine's own Pokeblock.gain over the
-- table this fight read (`tables.flavorCompatibility`), else its battle
-- rules' Rules.safari.pokeblockGain over the same tables.  nil when neither
-- can be asked.
function M.gain3(tables, nature, block)
  local Pokeblock = Gen3.engine("src.core.game3.rse.pokeblock")
  local compat = type(tables) == "table" and tables.flavorCompatibility or nil
  if Pokeblock and type(Pokeblock.gain) == "function" and type(compat) == "table" then
    local g = try(Pokeblock.gain, nature, block, compat)
    if g ~= nil then return g end
  end
  local Rules = Gen3.engine("src.core.game3.battle.rules")
  local fn = Rules and type(Rules.safari) == "table" and Rules.safari.pokeblockGain or nil
  if type(fn) == "function" and type(tables) == "table" and Pokeblock
     and type(Pokeblock.flavors) == "function" then
    return try(fn, tables, nature, try(Pokeblock.flavors, block))
  end
  return nil
end

-- The block's name as the battle prints it (gBattleTextBuff1 =
-- gPokeblockNames[color], copied before the block is cleared), cleaned for a
-- mod box; nil leaves the referee's default.
local function blockName3(Pokeblock, block)
  local name = try(Pokeblock.name, block)
  if type(name) ~= "string" then return nil end
  name = Gen3.cleanText(name)
  if name == "" then return nil end
  return name
end

-- A POKeBLOCK throw: the screen's choice names the case slot the player used
-- (`block`, 1-based, the cart's gSpecialVar_ItemId + 1).  The block is read
-- off the save, the verdict decided from the wild monster's nature, the
-- referee's choice filed with it -- Wire would strip `verdict` and
-- `blockName`, `file3` hands them through -- and the block leaves the save
-- the moment the throw is taken (PokeblockAction_UseInBattle's
-- TryClearPokeblock: before the battle engine even reads the action).  A slot
-- with no block in it, or a block that cannot be weighed, is refused: the
-- menu stays open and the save is untouched.  -> taken.
function M.throwBlock3(ctx, payload, seat)
  local opt = ctx.safari3
  if not (type(opt) == "table" and opt.family == "rse") then return false end
  local slot = int(payload.block, nil)
  if not slot or slot < 1 or slot > M.POKEBLOCKS then return false end
  local session = ctx.session
  local Pokeblock = Gen3.engine("src.core.game3.rse.pokeblock")
  if not (type(session) == "table" and Pokeblock and type(Pokeblock.get) == "function"
          and type(Pokeblock.tryClear) == "function") then
    warn(ctx, "pokeblock", "the POKeBLOCK CASE could not be read in this Safari battle, so "
      .. "no POKeBLOCK can be thrown; the other commands still work -- update the game")
    return false
  end
  local block = try(Pokeblock.get, session, slot - 1)
  if type(block) ~= "table" or int(block.color, 0) == 0 then return false end
  local verdict = M.verdict3(M.gain3(ctx.safariTables3, M.nature3(ctx.wildMon), block))
  if verdict == nil then
    warn(ctx, "gain", "how the wild POKeMON takes to a POKeBLOCK could not be worked out (its "
      .. "flavor table is missing from this game's imported data), so no POKeBLOCK can be "
      .. "thrown; re-import your Emerald ROM to restore it")
    return false
  end
  local choice = { action = "safari", throw = "block", verdict = verdict,
                   blockName = blockName3(Pokeblock, block) }
  if not ctx.solo:file3(choice, seat) then return false end
  if not try(Pokeblock.tryClear, session, slot - 1) then
    warn(ctx, "clear", "the POKeBLOCK just thrown could not be taken out of the POKeBLOCK "
      .. "CASE; throw it away from the case yourself, or reload from your last save")
  end
  return true
end

-- ------------------------------------------------------------------
-- the SAFARI BALLS home
-- ------------------------------------------------------------------

-- battle/init.lua safari_sync_balls: session.safari.balls is the count, made
-- if the session has no Safari state yet.
function M.writeBalls3(session, balls)
  local n = int(balls, nil)
  if type(session) ~= "table" or n == nil then return false end
  if type(session.safari) ~= "table" then session.safari = {} end
  session.safari.balls = min(M.BALLS_MAX, max(0, n))
  return true
end

-- ------------------------------------------------------------------
-- the end
-- ------------------------------------------------------------------

-- The engine battle state's fields its Safari tails read (battle/init.lua's
-- `st`: `result` in its own words -- "catch" for a catch; `endReason`
-- "no_safari_balls" for the last ball missed, "enemy_fled" for a flight;
-- `safariState` with the balls and gBattleResults.pokeblockThrows).
function M.tailState3(session, family, how, word, balls, throws)
  local Solo = sibling("SoloBattle")
  local words = Solo and type(Solo.ENGINE_RESULT3) == "table" and Solo.ENGINE_RESULT3 or {}
  local endReason = nil
  if how == "balls" then endReason = "no_safari_balls"
  elseif how == "flee" then endReason = "enemy_fled" end
  -- A catch is the engine's "catch" whatever the caller's word for it.
  local result = (how == "catch") and "catch" or (words[word] or word)
  return {
    safari = true, session = session, wild = true,
    result = result, endReason = endReason,
    safariState = { rse = (family == "rse") or nil, balls = balls, pokeblockThrows = throws },
  }
end

-- After the caller's `done`, as battle/init.lua runs them after its battle's
-- callback (BattleBridge's finish, and with it `done`):
--   * Emerald: Safari.endBattleRse, every Safari fight -- the Fan Club's
--     POKeBLOCK and catch counts, then, with no SAFARI BALLS left, the
--     out-of-balls-mid-battle script and its warp (:106), or a catch with the
--     last ball's out-of-balls script (:113) (pret pokeemerald
--     safari_zone.c:97 CB2_EndSafariBattle);
--   * FireRed / LeafGreen: the last ball missed (gBattleOutcome
--     NO_SAFARI_BALLS) and the Safari still on -- Safari.outOfBallsMidBattle
--     (pret pokefirered safari_zone.c:66); a catch with the last ball is the
--     field's to notice (Field.pollSafariBalls, CB2_EndSafariBattle's CAUGHT
--     arm, :73), and anything else ends nothing.
function M.tail3(ctx, family, how, word, balls, throws)
  -- FireRed / LeafGreen end nothing from the battle but a missed last ball.
  if family ~= "rse" and how ~= "balls" then return false end
  local session = ctx.session
  local Zone = Gen3.engine("src.core.game3.safari")
  if not (type(session) == "table" and Zone) then
    warn(ctx, "tail", "the Safari Zone could not be told how this battle ended (no Safari "
      .. "module on this build); leave the Safari Zone through its gate -- update the game")
    return false
  end
  if family == "rse" then
    if type(Zone.endBattleRse) ~= "function" then return false end
    local ok, err = pcall(Zone.endBattleRse, session,
      M.tailState3(session, family, how, word, balls, throws))
    if not ok then
      warn(ctx, "tail", "the Safari Zone could not be told how this battle ended (%s); if you "
        .. "are out of SAFARI BALLS, leave through the gate -- report it with the battle you "
        .. "were in", tostring(err))
      return false
    end
    return true
  end
  -- battle/init.lua's own guard (pret GetSafariZoneFlag): a Safari already
  -- over has no gate to send the player to.
  if not (type(Zone.isActive) == "function" and try(Zone.isActive, session) == true) then
    return false
  end
  local ok, err = pcall(Zone.outOfBallsMidBattle, session, ctx.game)
  if not ok then
    warn(ctx, "tail", "the trip back to the Safari Zone's gate after running out of SAFARI "
      .. "BALLS failed (%s); walk out through the gate -- report it with the battle you "
      .. "were in", tostring(err))
    return false
  end
  return true
end

-- ------------------------------------------------------------------
-- the kind
-- ------------------------------------------------------------------

local Safari = {}

-- A wild fight only (BATTLE_TYPE_SAFARI is a wild battle type; the referee
-- refuses `safari` anywhere else).  The option is read here, before anything
-- is built: a cart whose tables cannot be read is the cart's own fight.
function Safari:takes(ctx)
  if ctx.kind ~= "wild" then return false, "the Safari Zone is a wild battle" end
  local opt, tables = M.option3(ctx)
  if not opt then
    warn(ctx, "option", "this Safari Zone battle is fought the ordinary way: %s -- re-import "
      .. "your ROM to restore it", tostring(tables))
    return false, tables
  end
  ctx.safari3, ctx.safariTables3 = opt, tables
  -- The balls and POKeBLOCK throws the fight has spent so far (M:note), for a
  -- hand-back before the referee's own summary.
  ctx.safariBalls3, ctx.safariBlocks3 = opt.balls, 0
  -- The player's party is not in this fight (pret battle_main.c:2565 zeroes
  -- the battler): nothing uploaded, nothing brought home, nothing lost when
  -- the fight ends with nobody of ours standing, no Pickup.
  ctx.partyless, ctx.noReconcile, ctx.lossless, ctx.noPickup = true, true, true, true
  return true
end

-- The screen: no battler of ours, and which cart's Safari to draw -- the
-- per-cart menu and prompt, and the SAFARI BALLS box with the count it opens
-- on (MediatedBattle's `safari` option).
function Safari:screen(ctx, screenOpts)
  local opt = ctx.safari3
  screenOpts.noOwnBattler = true
  screenOpts.safari = { family = opt.family, balls = opt.balls }
end

-- The referee's `safari` option, and side a as the cart fields it: the
-- trainer alone, no monsters (the screen uploaded the party anyway: a catch
-- asks it for room), no bag.
function Safari:seat(ctx, create)
  local a = create.sides.a[1]
  create.sides.a[1] = { playerId = a.playerId, name = a.name }
  local opt = {}
  for k, v in pairs(ctx.safari3) do opt[k] = v end
  return { safari = opt }
end

-- The choices the screen files that are this file's, before the referee
-- reads them:
--   * BALL with the party and every box full -- the cart's selection script
--     instead of the action (pokefirered battle_main.c:3223, pokeemerald
--     :4269: gSelectionBattleScripts = BattleScript_PrintFullBox, back to
--     STATE_BEFORE_ACTION_CHOSEN): the line, the menu back, nothing filed and
--     nothing spent;
--   * POKeBLOCK -- M.throwBlock3.
-- Every other throw and RUN goes to the referee as the screen sent it.
function Safari:choose(ctx, payload, seat)
  if type(payload) ~= "table" or payload.action ~= "safari" then return false end
  if payload.throw == "ball" then
    if not M.boxFull3(ctx.session) then return false end
    ctx.solo:parkLine3(M.boxFullText3())
    return true, true
  end
  if payload.throw == "block" then return true, M.throwBlock3(ctx, payload, seat) end
  return false
end

-- Every throw spends a ball before it is rolled (pret
-- HandleAction_SafariZoneBallThrow: gNumSafariBalls--), and the engine's own
-- battle writes the count home there and then (safari_sync_balls): so here,
-- on the referee's `item` (`amount` = the SAFARI BALLS left).  The POKeBLOCK
-- throws are counted for a hand-back.
function Safari:note(ctx, event)
  if type(event) ~= "table" or event.side ~= "a" then return end
  if event.t == "item" and int(event.text, nil) == M.ITEM_SAFARI_BALL then
    local left = int(event.amount, nil)
    if left == nil then return end
    ctx.safariBalls3 = left
    M.writeBalls3(ctx.session, left)
  elseif event.t == "anim" and event.text == "POKEBLOCK_THROW" then
    ctx.safariBlocks3 = int(ctx.safariBlocks3, 0) + 1
  end
end

-- The balls as the referee's summary says them (`outcome.safari`, on every
-- ending), then the engine's tails once `done` has returned.
function Safari:finish(ctx, outcome, ending)
  outcome = type(outcome) == "table" and outcome or {}
  local summary = type(outcome.safari) == "table" and outcome.safari or {}
  local balls = int(summary.balls, nil) or int(ctx.safariBalls3, nil)
  if balls ~= nil then M.writeBalls3(ctx.session, balls) end
  local throws = int(summary.pokeblockThrows, nil) or int(ctx.safariBlocks3, 0)
  local family = (type(ctx.safari3) == "table" and ctx.safari3.family) or familyOf(ctx)
  local how = outcome.how
  local word = type(ending) == "table" and ending.result or nil
  return function() M.tail3(ctx, family, how, word, balls, throws) end
end

-- A fight the referee could not keep going goes to the cart's own battle
-- (the core's hand-back: the door's restart, a standard wild the engine
-- seats as Safari again from the session), with the SAFARI BALLS already
-- spent -- each was written home as it was thrown, and the engine's start
-- carries session.safari.balls over -- and the POKeBLOCKs thrown already
-- gone from the case.  Emerald's Fan Club counts those throws through the
-- engine's own end of a Safari battle (Safari.endBattleRse, which, with
-- neither a catch nor an out-of-balls ending, only counts): the cart's
-- battle would have, at its end, and the one that takes over counts only its
-- own.  Not handled here: the core starts the cart's battle.
function Safari:handBack(ctx)
  local opt = ctx.safari3
  local throws = int(ctx.safariBlocks3, 0)
  if type(opt) ~= "table" or opt.family ~= "rse" or throws <= 0 then return false end
  local session = ctx.session
  local Zone = Gen3.engine("src.core.game3.safari")
  if type(session) == "table" and Zone and type(Zone.endBattleRse) == "function" then
    pcall(Zone.endBattleRse, session, {
      safari = true, session = session, wild = true,
      safariState = { rse = true, balls = ctx.safariBalls3, pokeblockThrows = throws },
    })
  end
  return false
end

M.Safari = Safari
M.kinds3 = { safari = Safari }

return M
