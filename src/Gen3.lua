-- Gen 3 engine adapters: FireRed / LeafGreen ("frlg") and Emerald ("rse").
--
-- Everything the mod needs from a Gen 3 boot, reached in one place and always
-- the same way.  src/Gen.lua is where a *generation-shaped question* is asked
-- ("where does this save keep its money?"); this file is where the Gen 3
-- answer is fetched from the engine.  Every other module that grows a Gen 3
-- arm calls in here rather than requiring src.core.game3.* itself, so the
-- reach-arounds this port needs are listed in exactly one file.
--
-- ------- why the engine modules, and not the mod API
--
-- mod.game on a Gen 3 boot is the raw Game3 instance: no `stack`, no
-- `overworld`, and a `save` that is only a snapshot rebuilt at save time
-- (Schema.toSaveTable).  The live state is the runtime session.  The Gen 1
-- module names a mod would reach for (src.core.Game, src.battle.BattleState,
-- ...) are answered by Gen3Compat facades on FireRed and LeafGreen *only*
-- (Gen3Compat.FAMILIES = { frlg = true }); on Emerald the same require logs a
-- boot error and hands back the dead Gen 1 module.  So a mod that has to work
-- on all three reaches src.core.game3.* / src.ui.game3.* directly, which is
-- what the manifest's engine_internals permission is declared for.
--
-- ------- why every require here is lazy and guarded
--
-- The loader denies cross-generation requires outright (Loader.lua
-- crossGenerationDenial): a mod-attributed require of src.<x>.game3.<y> on a
-- Gen 1 or Gen 2 boot *throws*.  So no engine module is required at load, and
-- none is required unless `M.active()` says this is a Gen 3 boot; each one is
-- pcall'd once and remembered (hit or miss), because a per-frame caller
-- (busy, freeRoam) must not re-run a failing require sixty times a second.
--
-- Off Gen 3, and whenever the engine module is missing (a headless load, an
-- engine build that moved it), every function answers nil / 0 / false /
-- empty rather than raising: the mod being unable to see a Gen 3 detail must
-- never be the reason a hook throws.
--
-- ------- two shapes of the same data
--
-- Game3 publishes the engine modules themselves on game.data as gen3Pokemon /
-- gen3Moves / gen3Items (Game3:_exposeModData).  The headless SDK fixture
-- (tests/modkit/sdk.lua Sdk.gen3Data) publishes the *tables* those modules
-- keep (`_names`, `_rom`, `_byId`, ...) without the functions.  The species,
-- move and item readers below take the module's functions when it has them and
-- read the tables when it does not, so the same adapter answers on a live boot
-- and in the suite.  Nothing here ever carries ROM data of its own.
--
-- ------- the API (contract C1, docs/plans/gen3-firered-emerald-support.md)
--
--   active()                        is this a Gen 3 boot at all
--   engine(moduleName)              the guarded lazy require every arm shares
--   session() version() family()    live session; "firered"|"leafgreen"|"emerald"; "frlg"|"rse"
--   player()                        { name, gender (0/1), trainerId, secretId }
--   position()                      { mapId, x, y, facing, moving }
--   money.get() / money.set(n)      session.money, 0..999999
--   badgeCount()  dexCounts()       flags-backed badges; national seen / caught
--   badgeList()                     the held badge numbers { "1", "3", ... } (K1)
--   dexMark(sp, seen, caught, p)    HandleSetPokedexFlag; true when newly caught
--   recordCatch(mon)                what Catching.storeCaught writes besides the slot
--   party()  partyCount()           session.party (the live table) and its size
--   bag.count/add/remove(id, n)     Bag.get / add / remove over session.bag
--   bag.list(pocket)  bag.pockets() Bag.listPocket rows; the profile's pocket order
--   itemInfo(id)  itemName(id)      ItemsData.info / displayName
--   speciesName(id)  speciesInfo(id) national(id)
--   moveInfo(id)  moveName(id)      Moves.get (+ name); Pokemon.moveName
--   abilityName(id) natureName(n) typeName(t)
--   frontPic/backPic(monOrSpecies, opts)  icon(monOrSpecies)
--   trainerPic(picId)  trainerBackPic(gender)
--   gfxId(name)  gfxName(id)  playerGfxName(gender, version)
--   viewerGfxFor(sprite, partnerVersion, gender)
--   LOOKS  look(name)  lookAllowed(name)   the curated wardrobe (Chars lists it)
--   wrapFn(module, field, stashKey, build) / wrapLive(h) / unwrapFn(h)
--                                   the one way an engine function is wrapped
--   mapName(mapId)  region(mapId)   "kanto"|"sevii"|"hoenn"
--   stack() busy() inField() inBattle() freeRoam()
--   openStartMenu(game)  openNaming(opts)  nicknameTitle(speciesName)
--   battleText(stringId, fill)      the cart's line, printer codes cleaned
--   cleanText(text)                 \p -> blank line, \l / \n -> newline
--   audio.playSe/playSong/songId/playCry/restoreMapSong/battleSong/victorySong

local need, mod = ...
local Config = need("Config")

local M = {}

-- ------- is this a Gen 3 boot

-- mod.game through the facade.  pcall because the facade's __index resolves
-- the game per generation and a half-built loader can throw from it.  The
-- read is a named function rather than a closure: this runs from per-frame
-- paths (inField under the toast corner and the overlay), and a closure per
-- call is an allocation per frame.
local function readGame() return mod.game end
local function liveGame()
  local ok, game = pcall(readGame)
  if ok and type(game) == "table" then return game end
  return nil
end

-- The loader's own generation when there is one (it is fixed at Loader
-- construction and is the boot's truth), else the live game's.  rawget,
-- because the facade answers `generation` as a plain field and a stub mod in
-- a test may not carry it at all -- which must read as "not Gen 3", never as
-- a require of a Gen 3 module on a Gen 1 test run.
function M.active()
  if type(mod) ~= "table" then return false end
  local gen = tonumber(rawget(mod, "generation"))
  if gen then return gen == 3 end
  local game = liveGame()
  return game ~= nil and tonumber(game.generation) == 3
end

-- pcall'd require, remembered either way.  Only ever attempted on a Gen 3
-- boot (see the header on cross-generation denial).
--
-- Exported as M.engine for the other Gen 3 arms (the avatar injector, the UI
-- toolkit) that need an engine module this file has no wrapper for: the
-- guard, the pcall and the miss cache then live in one place for all of them.
local modules, missing = {}, {}
local function engine(name)
  if not M.active() then return nil end
  local hit = modules[name]
  if hit then return hit end
  if missing[name] then return nil end
  local ok, value = pcall(require, name)
  if ok and type(value) == "table" then
    modules[name] = value
    return value
  end
  missing[name] = true
  return nil
end
M.engine = engine

-- Call an engine function that may throw (most of them raise on a missing ROM
-- row: Pokemon.name, Moves.get, Constants:require).  First value, or nil.
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

local function gameData()
  local game = liveGame()
  local data = game and game.data
  if type(data) == "table" then return data end
  return nil
end

-- ------- wrapping an engine function
--
-- Where a Gen 3 seam is missing, this port wraps the one engine function that
-- decides the thing (OwSprites.playerGraphicsId for the worn look, the quest
-- log's capture and the rotating-tile puzzle's walker for the avatars).
-- Every such wrap is done here, one way, because three things have to hold
-- for each of them and each is easy to get wrong alone:
--
--   * A hot reload re-runs the installer against a slot that may already
--     hold this mod's previous wrapper.  That wrapper is peeled off -- the
--     new one goes over whatever it wrapped -- so wrappers never stack.
--   * But the slot may hold *another mod's* wrapper, stacked on ours.  Only
--     this mod's own wrappers are peeled, and only from the top: the moment
--     the walk meets a function that is not ours, that is what gets wrapped.
--     Wrapping the stashed original instead would silently drop the other
--     mod's wrapper from the chain.  Ours underneath it stays in place and
--     goes inert (wrapLive below), so the chain still reaches the engine.
--   * Removing ours puts back exactly what it wrapped -- and only when the
--     slot still holds it; with somebody else on top the caller retires it
--     in place instead (the caller's flag, read by its own wrapper).
--
-- Which functions are ours is a weak-keyed table kept on the engine module
-- itself (WRAPS_KEY), so every graph of this mod -- the one a hot reload
-- builds included -- sees the same registry.  `stashKey` keeps the pristine
-- original on the module for readers that want the engine's own answer; it
-- goes when the last of ours is unwrapped.  `stashKey .. ":live"` names the
-- newest wrapper installed under that key: an older one still in some chain
-- answers as if it were not there.
local WRAPS_KEY = "__rby_mmo_wraps"

local function wrapsOf(module)
  local tags = rawget(module, WRAPS_KEY)
  if type(tags) ~= "table" then
    tags = setmetatable({}, { __mode = "k" })
    rawset(module, WRAPS_KEY, tags)
  end
  return tags
end

-- Install build(inner) into module[field]; a handle { module, field, stash,
-- liveKey, wrapper, inner }, or nil when there is no such function.
function M.wrapFn(module, field, stashKey, build)
  if type(module) ~= "table" or type(build) ~= "function" then return nil end
  local current = module[field]
  if type(current) ~= "function" then return nil end
  local tags = wrapsOf(module)
  local inner = current
  while tags[inner] ~= nil do inner = tags[inner] end
  if rawget(module, stashKey) == nil then rawset(module, stashKey, inner) end
  local wrapper = build(inner)
  if type(wrapper) ~= "function" then return nil end
  tags[wrapper] = inner
  local liveKey = stashKey .. ":live"
  rawset(module, liveKey, wrapper)
  module[field] = wrapper
  return {
    module = module, field = field, stash = stashKey, liveKey = liveKey,
    wrapper = wrapper, inner = inner,
  }
end

-- Is this still the newest wrapper under its key?  One rawget: this is asked
-- from inside the wrapper, every call.
function M.wrapLive(handle)
  return type(handle) == "table"
    and rawget(handle.module, handle.liveKey) == handle.wrapper
end

-- Put back what the wrapper wrapped, when the slot still holds it: true.
-- False (nothing touched) when somebody else's wrapper is on top.
function M.unwrapFn(handle)
  if type(handle) ~= "table" then return false end
  local module = handle.module
  if module[handle.field] ~= handle.wrapper then return false end
  module[handle.field] = handle.inner
  wrapsOf(module)[handle.wrapper] = nil
  if rawget(module, handle.liveKey) == handle.wrapper then
    rawset(module, handle.liveKey, nil)
  end
  if rawget(module, handle.stash) == handle.inner then
    rawset(module, handle.stash, nil)
  end
  return true
end

-- ------- session, version, family

function M.session()
  if not M.active() then return nil end
  local Runtime = engine("src.core.game3.runtime")
  local s = Runtime and try(Runtime.getSession)
  if type(s) == "table" then return s end
  local game = liveGame()
  s = game and game.session
  if type(s) == "table" then return s end
  return nil
end

local function gameVersion()
  if not M.active() then return nil end
  return engine("src.core.GameVersion")
end

-- True for an id GameVersion knows as a Gen 3 cart.  Asked of GameVersion
-- rather than listed here, so a Gen 3 version the engine adds later is one
-- this file already accepts.
local function isGen3Version(id)
  if type(id) ~= "string" then return false end
  local GV = gameVersion()
  local row = GV and type(GV.VERSIONS) == "table" and GV.VERSIONS[id] or nil
  return type(row) == "table" and tonumber(row.generation) == 3
end

-- The running cart: the session says (it is stamped at new game and survives
-- a CONTINUE), else the launcher's pick, else FireRed -- the version a
-- headless Gen 3 load is folded against (Loader.apiModule's GEN3_API_DEFAULT).
function M.version()
  if not M.active() then return nil end
  local s = M.session()
  if s and isGen3Version(s.version) then return s.version end
  local GV = gameVersion()
  local current = GV and try(GV.get)
  if isGen3Version(current) then return current end
  return "firered"
end

local function familyOf(version)
  if not isGen3Version(version) then return nil end
  local GV = gameVersion()
  local layout = GV and try(GV.layout, version)
  if layout == "frlg" or layout == "rse" then return layout end
  return nil
end
M.familyOf = familyOf

-- "frlg" (FireRed, LeafGreen) or "rse" (Emerald).
function M.family()
  if not M.active() then return nil end
  return familyOf(M.version()) or "frlg"
end

-- ------- the player

-- session.gender is 0/1 on a fresh save; older paths wrote "female"/"F".
local function genderOf(value)
  if value == 1 or value == "female" or value == "F" or value == "f" then return 1 end
  return 0
end
M.genderOf = genderOf

function M.player()
  local s = M.session()
  if not s then return nil end
  return {
    name = s.name,
    gender = genderOf(s.gender),
    trainerId = tonumber(s.trainerId or s.id or s.playerId),
    secretId = tonumber(s.secretId),
  }
end

-- Where the player stands.  The live Map / Player modules while the field
-- runs (they are ahead of the session, which mirrors them only after each
-- step), the session's own copy otherwise.  The map id stays raw -- FR_* /
-- SEVII_* on FireRed and LeafGreen, EM_* on Emerald -- because that prefix is
-- what keeps the two regions apart on a shared hub.
function M.position()
  local s = M.session()
  if not s then return nil end
  local Map = M.inField() and engine("src.core.game3.map") or nil
  local live = Map and type(Map.current) == "string" and Map.current ~= ""
  -- The Player module is only the player once a map is up: before that it is
  -- a loaded module at its defaults (cell 0,0), which is not a position.
  local P = live and engine("src.core.game3.player") or nil
  local mapId = (live and Map.current) or s.map
  if type(mapId) ~= "string" or mapId == "" then return nil end
  local x = tonumber(P and P.cellX) or tonumber(s.x)
  local y = tonumber(P and P.cellY) or tonumber(s.y)
  if not (x and y) then return nil end
  local facing = (P and P.facing) or s.facing
  if facing ~= "up" and facing ~= "down" and facing ~= "left" and facing ~= "right" then
    facing = "down"
  end
  return { mapId = mapId, x = x, y = y, facing = facing, moving = (P and P.moving) == true }
end

-- ------- money, badges, dex

-- pokefirered/include/constants/global.h MAX_MONEY: the cart's AddMoney caps
-- here, so a reward that would overflow it lands where the cart would.
local MAX_MONEY = 999999

M.money = {}

function M.money.get()
  local s = M.session()
  if not s then return 0 end
  return math.floor(tonumber(s.money) or 0)
end

function M.money.set(n)
  local s = M.session()
  if not s then return false end
  local v = math.floor(tonumber(n) or 0)
  if v < 0 then v = 0 end
  if v > MAX_MONEY then v = MAX_MONEY end
  s.money = v
  return true
end

-- Badges are event flags on Gen 3 (FLAG_BADGE01_GET.. -- 0x820 on FireRed,
-- 0x867 on Emerald), not a table on the save.  Flags.countBadges walks the
-- *active profile's* badge list, so it is version-correct where a flag name
-- looked up through Gen3Compat would resolve against FireRed's table on
-- Emerald.  The live flag store (Space.store) while the field runs; the
-- session's serialised flags before that, which getFlag reads the same way.
function M.badgeCount()
  local s = M.session()
  if not s then return 0 end
  local Flags = engine("src.core.game3.scripting.flags")
  if not (Flags and type(Flags.countBadges) == "function") then return 0 end
  local store = s
  if M.inField() then
    local Space = engine("src.core.game3.scripting.space")
    if Space and type(Space.store) == "table" then store = Space.store end
  end
  return tonumber(try(Flags.countBadges, store)) or 0
end

-- The badges this save holds, as the badge numbers the referee's side entry
-- carries ({ "1", "3", ... } in order -- contract K1 of
-- docs/plans/gen3-badge-rules.md, the shape Wire.badges / sanitize.js
-- cleanBadgeSet already pass), or nil for none or on a build that cannot say.
--
-- Read the way the engine's own battle reads them (battle/engine.lua:166
-- Engine.hasBadge, pokefirered/src/pokemon.c:2381): an Emerald battle profile
-- names its badge flags outright (`badgeFlags`, FLAG_BADGE01_GET + n - 1 off
-- the cart's profile row; pokeemerald/src/battle_util.c:3930) and is asked
-- flag by flag, FireRed / LeafGreen go through Flags.hasBadge.  The flag store
-- is Space.store whenever it is a table, as there -- not only while the field
-- is the top phase (badgeCount's gate), because the moment a fight is diverted
-- is exactly the moment the field may have stepped aside -- and the session's
-- serialised flags otherwise, which getFlag reads the same way.
function M.badgeList()
  local s = M.session()
  if not s then return nil end
  local Flags = engine("src.core.game3.scripting.flags")
  if not Flags then return nil end
  local Space = engine("src.core.game3.scripting.space")
  local store = (Space and type(Space.store) == "table") and Space.store or s
  local BP = engine("src.core.game3.battle.profile")
  local prof = BP and try(BP.get, s)
  local badgeFlags = type(prof) == "table" and type(prof.badgeFlags) == "table"
    and prof.badgeFlags or nil
  local out = {}
  for n = 1, 8 do
    local has
    if badgeFlags then
      local flag = badgeFlags[n]
      has = flag ~= nil and try(Flags.getFlag, store, nil, flag) and true or false
    else
      has = try(Flags.hasBadge, store, n) == true
    end
    if has then out[#out + 1] = tostring(n) end
  end
  if #out == 0 then return nil end
  return out
end

local function countTrue(t)
  local n = 0
  if type(t) ~= "table" then return 0 end
  for _, on in pairs(t) do
    if on and on ~= 0 then n = n + 1 end
  end
  return n
end

-- seen, caught.  National mode: every species this save has met, which is the
-- number a profile card means -- a FireRed player who has not unlocked the
-- National Dex has still seen the Hoenn mon a trade brought them.
function M.dexCounts()
  local s = M.session()
  local dex = s and s.dex
  if type(dex) ~= "table" then return 0, 0 end
  local Dex = engine("src.core.game3.dex")
  if Dex and type(Dex.countSeen) == "function" and type(Dex.countCaught) == "function" then
    local seen = try(Dex.countSeen, dex, "national")
    local caught = try(Dex.countCaught, dex, "national")
    if seen and caught then return seen, caught end
  end
  return countTrue(dex.seen), countTrue(dex.caught or dex.owned)
end

local function dexOf(s)
  if type(s.dex) ~= "table" then
    local Dex = engine("src.core.game3.dex")
    s.dex = (Dex and try(Dex.new)) or { seen = {}, owned = {}, caught = {} }
  end
  return s.dex
end

-- pokefirered/src/pokemon.c:6233 HandleSetPokedexFlag, the one the trade and
-- gift paths use: seen, then caught, each only if not already set, with the
-- Unown / Spinda personality recorded on the first sighting.  No National Dex
-- gate -- the cart sets the bits and lets the dex screen decide what to show.
-- Returns true when `caught` made this species newly caught.
function M.dexMark(species, seen, caught, personality)
  local s = M.session()
  local sp = tonumber(species)
  if not (s and sp) then return false end
  local Dex = engine("src.core.game3.dex")
  if not (Dex and type(Dex.handleSetPokedexFlag) == "function") then return false end
  local dex = dexOf(s)
  local knew = try(Dex.isCaught, dex, sp) == true
  if seen ~= false then try(Dex.handleSetPokedexFlag, dex, sp, false, personality) end
  if caught then try(Dex.handleSetPokedexFlag, dex, sp, true, personality) end
  return caught and not knew and try(Dex.isCaught, dex, sp) == true or false
end

-- Everything Catching.storeCaught (src/core/game3/battle/catching.lua) writes
-- onto a caught mon and the save *except* choosing its home: the catcher as
-- original trainer (name, id, secret id, and gender -- CreateBoxMon stamps the
-- player's), where and at what level it was met, and the dex capture through
-- Dex.registerCapture -- the same call, with the same nil session, so the
-- FireRed "no Hoenn entries before the National Dex" gate behaves as it does
-- for a ball thrown in the engine's own battle.  A mon marked `traded` keeps
-- the trainer it arrived with, as the Gen 1 and Gen 2 stamps do.
--
-- Returns true when the species was new to the dex, false when it was known,
-- nil when there is no session to write into.
function M.recordCatch(mon)
  local s = M.session()
  if not (s and type(mon) == "table") then return nil end
  if not mon.traded then
    local name = s.name or s.playerName
    if name then
      mon.ot = name
      mon.otName = name
    end
    local tid = tonumber(s.trainerId or s.id or s.playerId)
    if tid then mon.otId = tid end
    local Catching = engine("src.core.game3.battle.catching")
    local sid = Catching and try(Catching.playerSecretId, s)
    mon.otSecretId = tonumber(sid) or tonumber(s.secretId) or mon.otSecretId
    if mon.otGender == nil and s.gender ~= nil then mon.otGender = genderOf(s.gender) end
  end
  local P = engine("src.core.game3.pokemon")
  local sec = P and try(P.currentMapSec, s)
  if sec then mon.metLocation = sec end
  mon.metLevel = tonumber(mon.level) or tonumber(mon.metLevel)
  local species = tonumber(mon.species or mon.speciesId)
  if not species then return nil end
  local Dex = engine("src.core.game3.dex")
  if not (Dex and type(Dex.registerCapture) == "function") then return nil end
  local ok, wasCaught = pcall(Dex.registerCapture, dexOf(s), species, nil, mon.personality)
  if not ok then return nil end
  return not wasCaught
end

-- ------- party and bag

function M.party()
  local s = M.session()
  if not s then return nil end
  if type(s.party) ~= "table" then s.party = {} end
  return s.party
end

function M.partyCount()
  local party = M.party()
  return party and #party or 0
end

M.bag = {}

local function bagOf()
  local s = M.session()
  local bag = s and s.bag
  if type(bag) ~= "table" then return nil end
  return bag
end

function M.bag.count(itemId)
  local bag, Bag = bagOf(), engine("src.core.game3.bag")
  if not (bag and Bag and itemId ~= nil) then return 0 end
  return tonumber(try(Bag.get, bag, itemId)) or 0
end

-- True, and how many landed, when the bag took them; Bag.add refuses (false,
-- 0) when the pocket is full, exactly as the cart's AddBagItem does.
function M.bag.add(itemId, n)
  local bag, Bag = bagOf(), engine("src.core.game3.bag")
  if not (bag and Bag and itemId ~= nil) then return false, 0 end
  local ok, took, placed = pcall(Bag.add, bag, itemId, math.max(1, math.floor(tonumber(n) or 1)))
  if not ok then return false, 0 end
  return took == true, tonumber(placed) or 0
end

function M.bag.remove(itemId, n)
  local bag, Bag = bagOf(), engine("src.core.game3.bag")
  if not (bag and Bag and itemId ~= nil) then return false end
  return try(Bag.remove, bag, itemId, math.max(1, math.floor(tonumber(n) or 1))) == true
end

-- { id, qty, name, info, description } per slot, in the pocket's own order.
function M.bag.list(pocket)
  local bag, Bag = bagOf(), engine("src.core.game3.bag")
  if not (bag and Bag) then return {} end
  local rows = try(Bag.listPocket, bag, pocket)
  return type(rows) == "table" and rows or {}
end

-- The running profile's pockets, in bag order ("ITEMS", "KEY_ITEMS",
-- "POKE_BALLS", "TM_CASE", "BERRY_POUCH" on FireRed; Emerald names its own).
function M.bag.pockets()
  local ItemsData = engine("src.core.game3.items_data")
  local order = ItemsData and ItemsData.POCKET_ORDER
  local out = {}
  if type(order) == "table" then
    for i = 1, #order do out[i] = order[i] end
  end
  return out
end

-- ------- species, moves, items, abilities

-- The engine module (live) or the fixture's tables (headless); see header.
local function source(dataKey, moduleName, probe)
  local data = gameData()
  local published = data and data[dataKey]
  if type(published) == "table" then
    if type(published[probe]) == "function" then return published, nil end
    return nil, published
  end
  return engine(moduleName), nil
end

local function pokemon()
  return source("gen3Pokemon", "src.core.game3.pokemon", "name")
end

local function movesModule()
  return source("gen3Moves", "src.core.game3.battle.moves", "get")
end

local function itemsModule()
  return source("gen3Items", "src.core.game3.items_data", "info")
end

local function row(tables, key, id)
  local t = tables and tables[key]
  if type(t) ~= "table" then return nil end
  return t[id]
end

function M.speciesName(species)
  local sp = tonumber(species)
  if not (M.active() and sp) then return nil end
  local P, T = pokemon()
  if P then return try(P.name, sp) end
  local name = row(T, "_names", sp)
  return type(name) == "string" and name or nil
end

function M.national(species)
  local sp = tonumber(species)
  if not (M.active() and sp) then return nil end
  local P, T = pokemon()
  if P then return tonumber(try(P.national, sp)) end
  local nat = T and T._national
  if type(nat) == "table" and type(nat.toNational) == "table" then
    return tonumber(nat.toNational[sp])
  end
  if sp <= 251 then return sp end
  return nil
end

local STAT_KEYS = { "hp", "atk", "def", "spe", "spa", "spd" }

-- Everything a battle sheet or a dex line needs about a species, as numbers:
-- types (pret TYPE_* ids), base stats keyed hp/atk/def/spe/spa/spd, both
-- ability slots, and the BaseStats extras (catch rate, exp yield, gender
-- ratio, growth rate, egg cycles, base friendship, egg groups, EV yield, wild
-- held items).  Weight/height from the dex entry ride along because Low Kick
-- reads the weight.  nil when the species has no row.
function M.speciesInfo(species)
  local sp = tonumber(species)
  if not (M.active() and sp) then return nil end
  local P, T = pokemon()
  local types, stats, abilities, meta, dexEntry
  if P then
    types = try(P.types, sp)
    stats = try(P.stats, sp)
    abilities = try(P.abilities, sp)
    meta = try(P.speciesMeta, sp)
    dexEntry = try(P.dexEntry, sp)
  else
    types = row(T, "_types", sp)
    stats = row(T, "_stats", sp)
    abilities = row(T, "_abilities", sp)
    meta = row(T, "_speciesMeta", sp)
    dexEntry = row(T, "_dex", sp)
  end
  if type(stats) ~= "table" then return nil end
  local base = {}
  for _, k in ipairs(STAT_KEYS) do base[k] = tonumber(stats[k]) or 0 end
  types = type(types) == "table" and types or {}
  abilities = type(abilities) == "table" and abilities or {}
  meta = type(meta) == "table" and meta or {}
  dexEntry = type(dexEntry) == "table" and dexEntry or {}
  return {
    id = sp,
    name = M.speciesName(sp),
    national = M.national(sp),
    types = { tonumber(types[1]) or 0, tonumber(types[2]) or tonumber(types[1]) or 0 },
    baseStats = base,
    abilities = { tonumber(abilities[1]) or 0, tonumber(abilities[2]) or 0 },
    catchRate = tonumber(meta.catchRate),
    expYield = tonumber(meta.expYield),
    genderRatio = tonumber(meta.genderRatio),
    growthRate = tonumber(meta.growthRate),
    eggCycles = tonumber(meta.eggCycles),
    baseFriendship = tonumber(meta.friendship),
    eggGroups = { tonumber(meta.eggGroup1), tonumber(meta.eggGroup2) },
    evYield = {
      hp = tonumber(meta.evHp) or 0, atk = tonumber(meta.evAtk) or 0,
      def = tonumber(meta.evDef) or 0, spe = tonumber(meta.evSpe) or 0,
      spa = tonumber(meta.evSpa) or 0, spd = tonumber(meta.evSpd) or 0,
    },
    heldItems = { common = tonumber(meta.itemCommon) or 0, rare = tonumber(meta.itemRare) or 0 },
    weight = tonumber(dexEntry.weight),
    height = tonumber(dexEntry.height),
  }
end

function M.moveName(moveId)
  local id = tonumber(moveId)
  if not (M.active() and id) then return nil end
  local P, T = pokemon()
  if P then return try(P.moveName, id) end
  local name = row(T, "_moveNames", id)
  return type(name) == "string" and name or nil
end

-- Gen 3 physical / special is by type (pret IS_TYPE_PHYSICAL), and a move
-- with no power is a status move whatever its type.  Only used for the
-- fixture shape: the live Moves.get already answers `category`.
local function categoryOf(power, typeId)
  if (tonumber(power) or 0) == 0 then return "status" end
  local Types = engine("src.core.game3.battle.types")
  if Types and type(Types.isPhysical) == "function" then
    return try(Types.isPhysical, typeId) and "physical" or "special"
  end
  return (tonumber(typeId) or 0) < 9 and "physical" or "special"
end

-- The gBattleMoves row: power, type, accuracy (percent; 0 = never misses),
-- pp, effect (EFFECT_* 0..213), secondaryChance, target (MOVE_TARGET_*
-- bits), priority (signed), flags (contact / protect / magic coat / snatch /
-- mirror move / king's rock bits), plus category and display name.
function M.moveInfo(moveId)
  local id = tonumber(moveId)
  if not (M.active() and id and id > 0) then return nil end
  local Mv, T = movesModule()
  local r
  if Mv then
    r = try(Mv.get, id)
  else
    r = row(T, "_rom", id)
  end
  if type(r) ~= "table" then return nil end
  return {
    id = id,
    constName = type(r.id) == "string" and r.id or nil,
    name = M.moveName(id),
    power = tonumber(r.power) or 0,
    type = tonumber(r.type) or 0,
    accuracy = tonumber(r.accuracy) or 0,
    pp = tonumber(r.pp) or 0,
    effect = tonumber(r.effect) or 0,
    secondaryChance = tonumber(r.secondaryChance) or 0,
    target = tonumber(r.target) or 0,
    priority = tonumber(r.priority) or 0,
    flags = tonumber(r.flags) or 0,
    category = r.category or categoryOf(r.power, r.type),
  }
end

function M.itemInfo(itemId)
  if not (M.active() and itemId ~= nil) then return nil end
  local I, T = itemsModule()
  if I then
    local info = try(I.info, itemId)
    return type(info) == "table" and info or nil
  end
  local id = tonumber(itemId)
  local r = id and row(T, "_byId", id)
  if type(r) ~= "table" then return nil end
  return {
    id = id, name = r.name, pocket = r.pocket, price = tonumber(r.price),
    holdEffect = tonumber(r.holdEffect), holdEffectParam = tonumber(r.holdEffectParam),
    battleUsage = tonumber(r.battleUsage), description = r.description,
  }
end

function M.itemName(itemId)
  if not (M.active() and itemId ~= nil) then return nil end
  local I = itemsModule()
  if I then return try(I.displayName, itemId) end
  local info = M.itemInfo(itemId)
  return info and info.name or nil
end

function M.abilityName(abilityId)
  local id = tonumber(abilityId)
  if not (M.active() and id) then return nil end
  local P, T = pokemon()
  if P then return try(P.abilityName, id) end
  local name = row(T, "_abilityNames", id)
  return type(name) == "string" and name or nil
end

-- gNatureNamePointers, from the player's own ROM text (0..24).
function M.natureName(nature)
  local n = tonumber(nature)
  if not (M.active() and n and n >= 0 and n <= 24) then return nil end
  local RomText = engine("src.core.game3.rom_text")
  local name = RomText and try(RomText.at, "gNatureNamePointers", n)
  return type(name) == "string" and name ~= "" and name or nil
end

-- gTypeNames, from the player's own ROM text.
function M.typeName(typeId)
  local t = tonumber(typeId)
  if not (M.active() and t) then return nil end
  local Types = engine("src.core.game3.battle.types")
  local name = Types and try(Types.name, t)
  return type(name) == "string" and name ~= "" and name or nil
end

-- ------- pictures

-- { image, w, h } (64x64 battle pics).  A mon table gets the engine's own
-- mon-aware pick (egg, Unown letter, Spinda spots, shiny from OT + PID); a
-- bare species reads opts.form / opts.shiny / opts.personality.  The engine
-- module, never the fixture: there are no pixels in a fixture.
function M.frontPic(subject, opts)
  if not M.active() then return nil end
  opts = opts or {}
  local P = engine("src.core.game3.pokemon")
  if not P then return nil end
  if type(subject) == "table" then return try(P.monFrontPic, subject, opts.form) end
  local sp = tonumber(subject)
  if not sp then return nil end
  return try(P.frontPic, sp, opts.form, opts.shiny == true, opts.personality)
end

function M.backPic(subject, opts)
  if not M.active() then return nil end
  opts = opts or {}
  local P = engine("src.core.game3.pokemon")
  if not P then return nil end
  if type(subject) == "table" then return try(P.monBackPic, subject, opts.form) end
  local sp = tonumber(subject)
  if not sp then return nil end
  return try(P.backPic, sp, opts.form, opts.shiny == true)
end

-- { image, w = 32, h = 32, sheetH, frames, quads[0..frames-1] }: the party
-- menu's two-frame bob.
function M.icon(subject)
  if not M.active() then return nil end
  local P = engine("src.core.game3.pokemon")
  if not P then return nil end
  if type(subject) == "table" then return try(P.monIcon, subject) end
  local sp = tonumber(subject)
  if not sp then return nil end
  return try(P.icon, sp)
end

-- Opponent trainer front pic, 64x64, by TRAINER_PIC_* id.
function M.trainerPic(picId)
  if not M.active() then return nil end
  local TrainerPic = engine("src.core.game3.trainer_pic")
  return TrainerPic and try(TrainerPic.front, tonumber(picId)) or nil
end

-- The player's back-pic strip (64 wide, one 64x64 frame per throw pose).
function M.trainerBackPic(gender)
  if not M.active() then return nil end
  local TrainerPic = engine("src.core.game3.trainer_pic")
  return TrainerPic and try(TrainerPic.back, genderOf(gender)) or nil
end

-- ------- overworld graphics

local function constantsFor(version)
  local C = engine("src.core.game3.constants")
  if not C then return nil end
  return try(C.of, version or M.version())
end

-- OBJ_EVENT_GFX_* name -> this cart's numeric id (they differ per version:
-- FireRed's RED_NORMAL is 0, Emerald has no such name).  A number passes
-- through.  nil when this version has no such graphic.
function M.gfxId(name, version)
  if type(name) == "number" then return name end
  if type(name) ~= "string" or not M.active() then return nil end
  local C = constantsFor(version)
  local id = C and try(C.id, C, "event_objects", name)
  return tonumber(id)
end

function M.gfxName(id, version)
  local n = tonumber(id)
  if not (n and M.active()) then return nil end
  local C = constantsFor(version)
  local name = C and try(C.name, C, "event_objects", n, "OBJ_EVENT_GFX_")
  return type(name) == "string" and name or nil
end

-- The player's own overworld look, per family and gender.  FireRed / LeafGreen
-- draw RED / GREEN (the "Leaf" sprite is GREEN_* in pret), Emerald draws
-- BRENDAN / MAY -- the NORMAL (walking) graphic, not the bike or surf one,
-- because a look is what a player *is*, and the state is the engine's to add.
local PLAYER_GFX = {
  frlg = { "OBJ_EVENT_GFX_RED_NORMAL", "OBJ_EVENT_GFX_GREEN_NORMAL" },
  rse = { "OBJ_EVENT_GFX_BRENDAN_NORMAL", "OBJ_EVENT_GFX_MAY_NORMAL" },
}
M.PLAYER_GFX = PLAYER_GFX

-- Pure over its arguments when `version` is given (no engine module is read),
-- so a hub or a test can ask it about any Gen 3 cart; with no version it is
-- this boot's, and nil off Gen 3.
function M.playerGfxName(gender, version)
  version = version or M.version()
  local family
  if version == "firered" or version == "leafgreen" then
    family = "frlg"
  elseif version == "emerald" then
    family = "rse"
  else
    family = familyOf(version)
  end
  local pair = family and PLAYER_GFX[family]
  if not pair then return nil end
  return pair[genderOf(gender) + 1]
end

-- The avatar each cart sends as its player's own look, and where it comes
-- from -- so a viewer whose hub did not relay the sender's version can still
-- tell a FireRed RED from an Emerald BRENDAN.
local SENT_AVATARS = {
  OBJ_EVENT_GFX_RED_NORMAL = { gender = 0, from = "firered" },
  OBJ_EVENT_GFX_GREEN_NORMAL = { gender = 1, from = "firered" },
  OBJ_EVENT_GFX_BRENDAN_NORMAL = { gender = 0, from = "emerald" },
  OBJ_EVENT_GFX_MAY_NORMAL = { gender = 1, from = "emerald" },
}

-- ------- the looks a player may wear
--
-- One row per look a player may wear on a Gen 3 cart: the label the
-- CHARACTER screen shows, the graphic's name on each family (`frlg` for
-- FireRed / LeafGreen, `rse` for Emerald, `both` when pret spells it the same
-- on the two), and the gender the cart's link rule should fall back to when
-- a viewer's family has no such look at all (a FireRed screen showing an
-- Emerald player dressed as ROXANNE draws the R/S girl, as a Cable Club
-- would).
--
-- Chosen, not generated, and chosen for one property: every one is a
-- *walking* person on its cart.  An event-object graphic can be a sitting
-- child, a doll, a berry tree or a boat, and a remote player worn as one of
-- those would slide from tile to tile without a step cycle.  Where the cache
-- is up, Chars.walks3 checks the frame count as well, so a build whose sheet
-- turned out to be stationary drops the row instead of drawing it wrong.
--
-- It lives here, beside the viewer mapping, rather than in src/Chars.lua
-- (which lists it for the CHARACTER screen as Chars.LOOKS) because it is also
-- the fence on what a *remote* player may be drawn as.  `sprite` arrives from
-- a peer, and the object an avatar is built from is a real event object: a
-- FireRed Field.interact reads its graphic before its script, so a peer
-- presenting as OBJ_EVENT_GFX_CUT_TREE would be offered to Cut -- and Cut
-- removes the object -- and ROCK_SMASH_ROCK / PUSHABLE_BOULDER the same, with
-- the ACTIONS menu unreachable behind them.  viewerGfxFor draws a name as
-- itself only when it is a row here or a player-trainer graphic; anything
-- else is drawn by the link rule.  Gen3 cannot need Chars (Chars needs Gen3),
-- so the table has to be on this side of that edge.
--
-- Order is the order the CHARACTER screen lists them in: the four heroes
-- first, then the rivals and professors, the trainer classes, and the gym
-- leaders and Elite Four at the end.
local LOOKS = {
  { label = "RED", frlg = "OBJ_EVENT_GFX_RED_NORMAL", rse = "OBJ_EVENT_GFX_RED", gender = 0 },
  { label = "LEAF", frlg = "OBJ_EVENT_GFX_GREEN_NORMAL", rse = "OBJ_EVENT_GFX_LEAF", gender = 1 },
  { label = "BRENDAN", frlg = "OBJ_EVENT_GFX_RS_BRENDAN", rse = "OBJ_EVENT_GFX_BRENDAN_NORMAL", gender = 0 },
  { label = "MAY", frlg = "OBJ_EVENT_GFX_RS_MAY", rse = "OBJ_EVENT_GFX_MAY_NORMAL", gender = 1 },
  { label = "BLUE", frlg = "OBJ_EVENT_GFX_BLUE", gender = 0 },
  { label = "WALLY", rse = "OBJ_EVENT_GFX_WALLY", gender = 0 },
  { label = "PROF. OAK", frlg = "OBJ_EVENT_GFX_PROF_OAK", gender = 0 },
  { label = "PROF. BIRCH", rse = "OBJ_EVENT_GFX_PROF_BIRCH", gender = 0 },
  { label = "BILL", frlg = "OBJ_EVENT_GFX_BILL", gender = 0 },
  { label = "STEVEN", rse = "OBJ_EVENT_GFX_STEVEN", gender = 0 },
  { label = "YOUNGSTER", both = "OBJ_EVENT_GFX_YOUNGSTER", gender = 0 },
  { label = "BUG CATCHER", both = "OBJ_EVENT_GFX_BUG_CATCHER", gender = 0 },
  { label = "LASS", both = "OBJ_EVENT_GFX_LASS", gender = 1 },
  { label = "CAMPER", both = "OBJ_EVENT_GFX_CAMPER", gender = 0 },
  { label = "PICNICKER", both = "OBJ_EVENT_GFX_PICNICKER", gender = 1 },
  { label = "BEAUTY", both = "OBJ_EVENT_GFX_BEAUTY", gender = 1 },
  { label = "BLACK BELT", both = "OBJ_EVENT_GFX_BLACK_BELT", gender = 0 },
  { label = "HIKER", both = "OBJ_EVENT_GFX_HIKER", gender = 0 },
  { label = "SAILOR", both = "OBJ_EVENT_GFX_SAILOR", gender = 0 },
  { label = "GENTLEMAN", both = "OBJ_EVENT_GFX_GENTLEMAN", gender = 0 },
  { label = "SCIENTIST", frlg = "OBJ_EVENT_GFX_SCIENTIST", rse = "OBJ_EVENT_GFX_SCIENTIST_1", gender = 0 },
  { label = "FISHERMAN", frlg = "OBJ_EVENT_GFX_FISHER", rse = "OBJ_EVENT_GFX_FISHERMAN", gender = 0 },
  { label = "COOLTRAINER M", frlg = "OBJ_EVENT_GFX_COOLTRAINER_M", gender = 0 },
  { label = "COOLTRAINER F", frlg = "OBJ_EVENT_GFX_COOLTRAINER_F", gender = 1 },
  { label = "BIKER", frlg = "OBJ_EVENT_GFX_BIKER", gender = 0 },
  { label = "ROCKER", frlg = "OBJ_EVENT_GFX_ROCKER", gender = 0 },
  { label = "POKEMANIAC", frlg = "OBJ_EVENT_GFX_POKE_MANIAC", rse = "OBJ_EVENT_GFX_MANIAC", gender = 0 },
  { label = "CHANNELER", frlg = "OBJ_EVENT_GFX_CHANNELER", gender = 1 },
  { label = "ROCKET M", frlg = "OBJ_EVENT_GFX_ROCKET_M", gender = 0 },
  { label = "ROCKET F", frlg = "OBJ_EVENT_GFX_ROCKET_F", gender = 1 },
  { label = "EXPERT M", rse = "OBJ_EVENT_GFX_EXPERT_M", gender = 0 },
  { label = "EXPERT F", rse = "OBJ_EVENT_GFX_EXPERT_F", gender = 1 },
  { label = "PSYCHIC", rse = "OBJ_EVENT_GFX_PSYCHIC_M", gender = 0 },
  { label = "HEX MANIAC", rse = "OBJ_EVENT_GFX_HEX_MANIAC", gender = 1 },
  { label = "NINJA BOY", rse = "OBJ_EVENT_GFX_NINJA_BOY", gender = 0 },
  { label = "RICH BOY", rse = "OBJ_EVENT_GFX_RICH_BOY", gender = 0 },
  { label = "SCHOOL KID", rse = "OBJ_EVENT_GFX_SCHOOL_KID_M", gender = 0 },
  { label = "AQUA M", rse = "OBJ_EVENT_GFX_AQUA_MEMBER_M", gender = 0 },
  { label = "AQUA F", rse = "OBJ_EVENT_GFX_AQUA_MEMBER_F", gender = 1 },
  { label = "MAGMA M", rse = "OBJ_EVENT_GFX_MAGMA_MEMBER_M", gender = 0 },
  { label = "MAGMA F", rse = "OBJ_EVENT_GFX_MAGMA_MEMBER_F", gender = 1 },
  { label = "ARCHIE", rse = "OBJ_EVENT_GFX_ARCHIE", gender = 0 },
  { label = "MAXIE", rse = "OBJ_EVENT_GFX_MAXIE", gender = 0 },
  { label = "GIOVANNI", frlg = "OBJ_EVENT_GFX_GIOVANNI", gender = 0 },
  { label = "BROCK", frlg = "OBJ_EVENT_GFX_BROCK", gender = 0 },
  { label = "MISTY", frlg = "OBJ_EVENT_GFX_MISTY", gender = 1 },
  { label = "LT. SURGE", frlg = "OBJ_EVENT_GFX_LT_SURGE", gender = 0 },
  { label = "ERIKA", frlg = "OBJ_EVENT_GFX_ERIKA", gender = 1 },
  { label = "KOGA", frlg = "OBJ_EVENT_GFX_KOGA", gender = 0 },
  { label = "SABRINA", frlg = "OBJ_EVENT_GFX_SABRINA", gender = 1 },
  { label = "BLAINE", frlg = "OBJ_EVENT_GFX_BLAINE", gender = 0 },
  { label = "LORELEI", frlg = "OBJ_EVENT_GFX_LORELEI", gender = 1 },
  { label = "BRUNO", frlg = "OBJ_EVENT_GFX_BRUNO", gender = 0 },
  { label = "AGATHA", frlg = "OBJ_EVENT_GFX_AGATHA", gender = 1 },
  { label = "LANCE", frlg = "OBJ_EVENT_GFX_LANCE", gender = 0 },
  { label = "ROXANNE", rse = "OBJ_EVENT_GFX_ROXANNE", gender = 1 },
  { label = "BRAWLY", rse = "OBJ_EVENT_GFX_BRAWLY", gender = 0 },
  { label = "WATTSON", rse = "OBJ_EVENT_GFX_WATTSON", gender = 0 },
  { label = "FLANNERY", rse = "OBJ_EVENT_GFX_FLANNERY", gender = 1 },
  { label = "NORMAN", rse = "OBJ_EVENT_GFX_NORMAN", gender = 0 },
  { label = "WINONA", rse = "OBJ_EVENT_GFX_WINONA", gender = 1 },
  { label = "TATE", rse = "OBJ_EVENT_GFX_TATE", gender = 0 },
  { label = "LIZA", rse = "OBJ_EVENT_GFX_LIZA", gender = 1 },
  { label = "JUAN", rse = "OBJ_EVENT_GFX_JUAN", gender = 0 },
  { label = "SIDNEY", rse = "OBJ_EVENT_GFX_SIDNEY", gender = 0 },
  { label = "PHOEBE", rse = "OBJ_EVENT_GFX_PHOEBE", gender = 1 },
  { label = "GLACIA", rse = "OBJ_EVENT_GFX_GLACIA", gender = 1 },
  { label = "DRAKE", rse = "OBJ_EVENT_GFX_DRAKE", gender = 0 },
  { label = "WALLACE", rse = "OBJ_EVENT_GFX_WALLACE", gender = 0 },
}
M.LOOKS = LOOKS

-- name -> row, for every spelling a row carries (either family's).  Built
-- once: the table above is static, and this is asked from a draw path.
local lookByName = {}
for _, row in ipairs(LOOKS) do
  for _, key in ipairs({ "both", "frlg", "rse" }) do
    local name = row[key]
    if name then lookByName[name] = row end
  end
end

-- The graphics a player-trainer is drawn with somewhere on a Gen 3 cart:
-- each family's own hero (what a player who chose nobody sends), and every
-- name the carts' Cable Club rule (Family.LINK_PLAYER_GFX) draws a partner
-- as.  Walking people all, and each one a thing a legitimate peer's `sprite`
-- can be.
local PLAYER_TRAINER_GFX = {
  OBJ_EVENT_GFX_RED_NORMAL = true, OBJ_EVENT_GFX_GREEN_NORMAL = true,
  OBJ_EVENT_GFX_BRENDAN_NORMAL = true, OBJ_EVENT_GFX_MAY_NORMAL = true,
  OBJ_EVENT_GFX_RS_BRENDAN = true, OBJ_EVENT_GFX_RS_MAY = true,
  OBJ_EVENT_GFX_RED = true, OBJ_EVENT_GFX_LEAF = true,
  OBJ_EVENT_GFX_LINK_RS_BRENDAN = true, OBJ_EVENT_GFX_LINK_RS_MAY = true,
  OBJ_EVENT_GFX_RIVAL_BRENDAN_NORMAL = true, OBJ_EVENT_GFX_RIVAL_MAY_NORMAL = true,
}

-- The row a graphic name belongs to, whichever family spelled it; nil for a
-- name no row carries.
function M.look(name)
  if type(name) ~= "string" then return nil end
  return lookByName[name]
end

-- May a remote player be drawn as `name` itself?  A look row (either
-- family's spelling) or a player-trainer graphic; never an arbitrary graphic
-- of the cart's, and never the hub's sprite-less token (that one is the link
-- rule's by definition).
function M.lookAllowed(name)
  if type(name) ~= "string" then return false end
  return lookByName[name] ~= nil or PLAYER_TRAINER_GFX[name] == true
end

-- The cart's own link-player rule: pokefirered/src/overworld.c:3516 draws an
-- Emerald partner as RS_BRENDAN / RS_MAY, pokeemerald/src/overworld.c:3167
-- draws a FireRed partner as RED / LEAF and another Emerald as the rival
-- sprites.  Family.linkPlayerGfx is that table; the fallback is the viewer's
-- own player look for the gender, which every Gen 3 cart carries.
local function linkGfx(viewer, partner, gender)
  local Family = engine("src.core.game3.link.family")
  if Family and type(Family.linkPlayerGfx) == "function" then
    local ok, id, name = pcall(Family.linkPlayerGfx, viewer, partner, genderOf(gender))
    if ok and tonumber(id) then return tonumber(id), name end
  end
  local name = M.playerGfxName(gender, viewer)
  local id = name and M.gfxId(name, viewer)
  if id then return id, name end
  return nil
end

-- What another player looks like on *this* cart: (numeric id, name).
--
-- `sprite` is the OBJ_EVENT_GFX_* name the sender's own version drew them
-- with (contract C3), `partnerVersion` the version their hello carried, and
-- `gender` 0/1.  A player avatar from another family goes through the link
-- rule above (a FireRed RED_NORMAL is RED on Emerald, where RED_NORMAL does
-- not exist); a look row is drawn in this family's spelling of it, or as the
-- name itself when this cart has that; a player-trainer graphic this cart has
-- is drawn as itself.  Anything else falls to the link rule by gender:
-- Config.DEFAULT_SPRITE_GEN3, the token a hub stamps when a hello carried no
-- sprite; a Gen 1 SPRITE_* id; a graphic this version lacks -- and every
-- graphic of the cart's that is not a look at all (a Cut tree, a boulder, a
-- boat: see "the looks a player may wear" above for why that fence is here).
-- An unknown partner version is read as the viewer's own, which is the right
-- guess for the name-less token.
function M.viewerGfxFor(sprite, partnerVersion, gender)
  if not M.active() then return nil end
  local viewer = M.version()
  local ownFamily = familyOf(viewer)
  local partner = isGen3Version(partnerVersion) and partnerVersion or nil
  if type(sprite) == "string" and sprite ~= Config.DEFAULT_SPRITE_GEN3 then
    local sent = SENT_AVATARS[sprite]
    if sent then
      local from = partner or sent.from
      if familyOf(from) == ownFamily then
        local id = M.gfxId(sprite, viewer)
        if id then return id, sprite end
      end
      return linkGfx(viewer, from, sent.gender)
    end
    local row = lookByName[sprite]
    if row then
      local mine = row.both or row[ownFamily or "frlg"]
      local id = mine and M.gfxId(mine, viewer)
      if id then return id, mine end
      -- the row's gender is the better guess for the link rule than none: a
      -- FireRed viewer with an Emerald ROXANNE draws a girl
      if gender == nil then gender = row.gender end
    end
    if row or PLAYER_TRAINER_GFX[sprite] then
      local id = M.gfxId(sprite, viewer)
      if id then return id, sprite end
    end
  end
  return linkGfx(viewer, partner or viewer, gender)
end

-- ------- maps

local function mapDef(mapId)
  local data = gameData()
  local maps = data and data.maps
  local def = type(maps) == "table" and maps[mapId] or nil
  return type(def) == "table" and def or nil
end

local function mapFamily(mapId)
  if type(mapId) ~= "string" then return nil end
  if mapId:find("^EM_") then return "rse" end
  if mapId:find("^FR_") or mapId:find("^SEVII_") then return "frlg" end
  return nil
end

-- The map id as words, the way map_name_popup.lua's cleanMapName spells a map
-- it could not identify: prefix off, CamelCase and digits split, underscores
-- to spaces.
local function cleanName(mapId)
  local s = tostring(mapId):gsub("^FR_", ""):gsub("^EM_", ""):gsub("^SEVII_", "")
  s = s:gsub("(%l)(%u)", "%1 %2"):gsub("(%a)(%d)", "%1 %2"):gsub("(%d)(%a)", "%1 %2")
  s = s:gsub("_", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return s:upper()
end

-- The place name the map-name popup would show, then the plain place (no
-- floor suffix).  FireRed and LeafGreen resolve through the region-map
-- sections (map_sections_extract.getInfo, as map_name_popup.lua does, floor
-- label included); Emerald through its own mapsec pack
-- (src/ui/game3/rse/mapsec.lua, which is all its popup prints).  A map from
-- the *other* family -- an Emerald player's Hoenn town on a FireRed screen --
-- has no row in this cart's sections, so it is spelled from its id.
function M.mapName(mapId)
  if not (M.active() and type(mapId) == "string" and mapId ~= "") then return nil end
  local family = mapFamily(mapId)
  local def = mapDef(mapId)
  local sec = def and tonumber(def.regionMapSectionId or def.region_map_section_id or def.mapsec)
  local floor = def and tonumber(def.floorNum or def.floor_num or def.floor) or 0
  if family ~= nil and family == M.family() then
    if family == "rse" then
      local Mapsec = sec and engine("src.ui.game3.rse.mapsec")
      local name = Mapsec and try(Mapsec.name, sec)
      if type(name) == "string" and name ~= "" then return name, name end
    else
      local Sections = engine("src.import.gba.map_sections_extract")
      local info = Sections and try(Sections.getInfo, sec, mapId, floor)
      if type(info) == "table" and info.resolved ~= false and type(info.name) == "string"
          and info.name ~= "" and info.name ~= "???" then
        return info.name, info.rawName or info.name
      end
    end
  end
  local clean = cleanName(mapId)
  return clean, clean
end

-- pokefirered/include/constants/region_map_sections.h: the Sevii Islands are
-- the contiguous run MAPSEC_ONE_ISLAND .. MAPSEC_EMBER_SPA; everything below
-- it on a FireRed cart is Kanto.  Asked of the engine's committed constant
-- tables (not ROM data) so the bounds are pret's, not a number typed here.
local function seviiSection(sec)
  local C = constantsFor("firered")
  if not C then return nil end
  local first = tonumber(try(C.id, C, "region_map_sections", "MAPSEC_ONE_ISLAND"))
  local last = tonumber(try(C.id, C, "region_map_sections", "MAPSEC_EMBER_SPA"))
  if not (first and last) then return nil end
  return sec >= first and sec <= last
end

-- Without a map def (a remote player's map this cart never loaded), the id
-- says it: every Sevii map in pret's FireRed tree is named after its island
-- or one of the four landmarks that sit on none (checked against all 425 map
-- headers; the PROTOTYPE_SEVII_ISLE_* rows are the unused prototypes).
local SEVII_NAMES = {
  "^ONE_ISLAND", "^TWO_ISLAND", "^THREE_ISLAND", "^FOUR_ISLAND", "^FIVE_ISLAND",
  "^SIX_ISLAND", "^SEVEN_ISLAND", "^SEVII_ISLE", "^PROTOTYPE_SEVII_ISLE",
  "^NAVEL_ROCK", "^BIRTH_ISLAND", "^MT_EMBER", "^TRAINER_TOWER",
}

-- "kanto" | "sevii" | "hoenn" | nil.  Emerald is all Hoenn (its Battle
-- Frontier and the event islands included); FireRed / LeafGreen is Kanto
-- plus the Sevii Islands.  The prefix is pure, so this answers for any map id
-- a roster row carries; the section lookup only runs on a Gen 3 boot.
function M.region(mapId)
  if type(mapId) ~= "string" then return nil end
  local family = mapFamily(mapId)
  if family == "rse" then return "hoenn" end
  if family ~= "frlg" then return nil end
  if mapId:find("^SEVII_") then return "sevii" end
  local def = M.active() and mapDef(mapId) or nil
  local sec = def and tonumber(def.regionMapSectionId or def.region_map_section_id or def.mapsec)
  if sec then
    local sevii = seviiSection(sec)
    if sevii ~= nil then return sevii and "sevii" or "kanto" end
  end
  local bare = mapId:gsub("^FR_", "")
  for _, pattern in ipairs(SEVII_NAMES) do
    if bare:find(pattern) then return "sevii" end
  end
  return "kanto"
end

-- ------- the screen

-- src/ui/game3/stack.lua: push(id, layer, opts) / pop(id) / top() / has(id) /
-- busy() / depth().  A layer is drawn with no arguments into the 240x160 UI
-- canvas, and the top one alone gets handleInput(input) / update(dt).
function M.stack()
  return engine("src.ui.game3.stack")
end

-- The field is running (not the title / boot menus, not the FRLG quest-log
-- recap, not the engine's online arena).  Battles run *inside* the field
-- phase on Gen 3, so this is true under a battle too -- inBattle says which.
function M.inField()
  if not M.active() then return false end
  local game = liveGame()
  return game ~= nil and game.phase == "field"
end

function M.inBattle()
  local Battle = engine("src.core.game3.battle")
  return Battle ~= nil and try(Battle.isActive) == true
end

-- Something owns the screen: a stack layer, one of the legacy module menus
-- (bag, party, dex ... which draw while the stack is empty), a message or a
-- yes/no, a fade, a battle.  Hud.busy is the engine's own answer to "may the
-- player walk"; the bare stack is the fallback when the HUD module is absent.
function M.busy()
  if not M.active() then return false end
  local Hud = engine("src.ui.game3.hud")
  if Hud and type(Hud.busy) == "function" then
    local ok, busy = pcall(Hud.busy)
    if ok then return busy == true end
  end
  local Stack = M.stack()
  return Stack ~= nil and try(Stack.busy) == true
end

-- The player is looking at the world with nothing in front of it -- Gen 1's
-- "overworld on top", Gold's "empty stack over a live map".
function M.freeRoam()
  return M.inField() and not M.busy()
end

-- Re-open START.  Hud.openStartMenu is a *toggle* (a second call closes it),
-- so an open menu is left alone.  Emerald's rows come through the same module
-- (the profile swaps the row data, not the menu), and the ui.start_menu.items
-- hook runs on every open, so the MMO row is back too.
function M.openStartMenu(game)
  if not M.active() then return false end
  local StartMenu = engine("src.ui.game3.start_menu")
  if StartMenu and try(StartMenu.isOpen) == true then return true end
  local Hud = engine("src.ui.game3.hud")
  if not (Hud and type(Hud.openStartMenu) == "function") then return false end
  local ok = pcall(Hud.openStartMenu, game or liveGame(), M.session())
  if not ok then return false end
  return StartMenu == nil or try(StartMenu.isOpen) == true
end

-- src/ui/game3/naming.lua Naming.open{ title, maxLen, initialText, template,
-- species, gender, personality, seed, onDone }: a fullscreen "naming" layer
-- that pops *itself* and then calls onDone(text) -- Gen 1's contract, not
-- Gold's.  True when the grid went up.
function M.openNaming(opts)
  if not M.active() then return false end
  local Naming = engine("src.ui.game3.naming")
  if not (Naming and type(Naming.open) == "function") then return false end
  local ok, st = pcall(Naming.open, opts or {})
  return ok and st ~= nil
end

-- "<SPECIES>'s nickname?" in the cart's own words (gText_PkmnsNickname).
function M.nicknameTitle(speciesName)
  local Naming = engine("src.ui.game3.naming")
  local title = Naming and try(Naming.monTitle, speciesName)
  return type(title) == "string" and title ~= "" and title or nil
end

-- A line of the cart's text as the mod's boxes print it.
--
-- The engine's text pack hands a string back with the message printer's own
-- control codes still in it (TextIR.toAscii: `\p` next page, `\l` scroll a
-- line, plus the odd literal `\n`) -- codes the cart's printer acts on and a
-- mod box would print as two characters ("Give a nickname to the captured
-- PIDGEY?\p").  A page break becomes a blank line, which is the paragraph
-- break Gen3Ui's TextBox pages on (Gen3Ui.paginate); the other two become a
-- line break, which it rejoins and re-wraps to the window; and one trailing
-- the sentence goes altogether.  Pure, and idempotent: a clean line comes
-- back as it went in.  src/Exp3.lua's cleanText is the same rule, kept there
-- for its own callers.
function M.cleanText(text)
  if type(text) ~= "string" then return text end
  text = text:gsub("\\[pl]%s*$", ""):gsub("\\p", "\n\n"):gsub("\\[ln]", "\n")
  return (text:gsub("%s+$", ""))
end

-- A battle string (STRINGID_*) in the cart's words, the same expansion the
-- engine's battle box prints (BattleText.get), cleaned for a mod box
-- (M.cleanText).  nil when the text pack is not there, so the caller can fall
-- back to a sentence of its own.
function M.battleText(stringId, fill)
  if not M.active() then return nil end
  local BattleText = engine("src.core.game3.battle.battle_text")
  local text = BattleText and try(BattleText.get, stringId, fill or {})
  if type(text) ~= "string" then return nil end
  text = M.cleanText(text)
  if text == "" then return nil end
  return text
end

-- ------- sound

M.audio = {}

local function audioModule()
  return engine("src.core.game3.audio")
end

-- MUS_* / SE_* name -> this cart's song number (they differ per version).
function M.audio.songId(name)
  if type(name) == "number" then return name end
  if type(name) ~= "string" or not M.active() then return nil end
  local C = constantsFor()
  return tonumber(C and try(C.song, C, name))
end

-- The engine's players answer nothing useful on success (nil or true) and
-- false when they refused, so "did not throw and did not say false" is the
-- success test -- `try` alone cannot tell a throw from a nil return.
local function played(fn, ...)
  if type(fn) ~= "function" then return false end
  local ok, result = pcall(fn, ...)
  return ok and result ~= false
end

function M.audio.playSong(song)
  local Audio = audioModule()
  local id = M.audio.songId(song)
  if not (Audio and id) then return false end
  return played(Audio.playSong, id)
end

-- SE_* by name; Audio.playSe resolves it through the version-selected SE
-- table (se_ids.lua), so Emerald's numbering is honoured.
function M.audio.playSe(name)
  local Audio = audioModule()
  if not (Audio and name ~= nil) then return false end
  return played(Audio.playSe, name)
end

function M.audio.playCry(species)
  local Audio = audioModule()
  local sp = tonumber(species)
  if not (Audio and sp) then return false end
  return played(Audio.playCry, sp)
end

-- What battle_bridge.lua does after every fight: the map's own song (or the
-- surf / bike override, or the song saved before a scripted cue).
function M.audio.restoreMapSong()
  local Audio = audioModule()
  if not Audio then return false end
  return played(Audio.restoreMapSong)
end

local function role(name)
  local Audio = audioModule()
  return Audio and tonumber(try(Audio.role, name)) or nil
end

local function battleProfile()
  local BP = engine("src.core.game3.battle.profile")
  if not BP then return nil, nil end
  local bp = try(BP.get, M.session())
  return BP, type(bp) == "table" and bp or nil
end

-- A numeric Gen 3 trainer id's class and name (scripting/trainers.lua); a
-- caller that already knows the class passes it instead.
local function trainerInfo(opts)
  local class, name = tonumber(opts.trainerClass), opts.trainerName
  local tid = tonumber(opts.trainerId)
  if tid and not class then
    local Trainers = engine("src.core.game3.scripting.trainers")
    local info = Trainers and try(Trainers.info, tid)
    if type(info) == "table" then
      class = tonumber(info.class)
      name = name or info.name
    end
  end
  return tid, class, name
end

-- The battle theme the cart would start for this fight, as a song number.
--
-- opts: { wild, link, trainerId (numeric Gen 3 id), trainerClass,
-- trainerName, species (wild legendary themes) }.  The same order
-- battle_bridge.lua resolve_battle_song uses: Emerald's profile music table
-- first (pokeemerald/src/pokemon.c:6426), then FireRed's legendary / role
-- lookups.  A link fight takes the Cable Club's own theme
-- (Family.linkBattleSongs: pokefirered/src/cable_club.c:656).
function M.audio.battleSong(opts)
  if not M.active() then return nil end
  opts = opts or {}
  local tid, class, name = trainerInfo(opts)
  local BP, bp = battleProfile()
  if bp and bp.music then
    local song = try(BP.battleSong, bp, {
      wild = opts.wild == true, link = opts.link == true,
      trainerClass = class, trainerName = name,
    })
    if tonumber(song) then return tonumber(song) end
  end
  if opts.wild then
    local Audio = audioModule()
    local legend = Audio and tonumber(try(Audio.legendaryBattleSong, tonumber(opts.species)))
    return legend or role("battleWild") or M.audio.songId("MUS_VS_WILD")
  end
  if opts.link then
    local Family = engine("src.core.game3.link.family")
    local songs = Family and try(Family.linkBattleSongs, M.version())
    local song = type(songs) == "table" and M.audio.songId(songs.trainer)
    if song then return song end
  end
  if tid then
    local Trainers = engine("src.core.game3.scripting.trainers")
    if Trainers and type(Trainers.getBattleMusicRole) == "function" then
      local ok, roleName, fallback = pcall(Trainers.getBattleMusicRole, tid)
      if ok then return role(roleName) or tonumber(fallback) end
    end
  end
  return role("battleTrainer") or M.audio.songId("MUS_VS_TRAINER")
end

-- The win jingle, same rules: Emerald's profile table, else FireRed's roles
-- (Trainers.getVictoryMusicRole: gym leaders and the champion get their own).
-- A link fight has no jingle on the cart; it takes the trainer one, the same
-- choice Gen.lua makes for Gold.
function M.audio.victorySong(opts)
  if not M.active() then return nil end
  opts = opts or {}
  local tid, class = trainerInfo(opts)
  local BP, bp = battleProfile()
  if bp and bp.music then
    local song = try(BP.victorySong, bp, { wild = opts.wild == true, trainerClass = class })
    if tonumber(song) then return tonumber(song) end
  end
  if opts.wild then
    return role("victoryWild") or M.audio.songId("MUS_VICTORY_WILD")
  end
  if tid and not opts.link then
    local Trainers = engine("src.core.game3.scripting.trainers")
    if Trainers and type(Trainers.getVictoryMusicRole) == "function" then
      local ok, roleName, fallback = pcall(Trainers.getVictoryMusicRole, tid)
      if ok then return role(roleName) or tonumber(fallback) end
    end
  end
  return role("victoryTrainer") or M.audio.songId("MUS_VICTORY_TRAINER")
end

return M
