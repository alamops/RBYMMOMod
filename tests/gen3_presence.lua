-- Gen 3 presence: remote players as injected event objects, their plates,
-- the region-map party list, place names, the Gen 3 character catalog, and
-- the cast that stays off a Gen 3 boot.
--
-- Driven through the real headless loader on a Gen 3 boot (FireRed, then
-- Emerald), with the mod's modules resolved the way main.lua resolves them --
-- mod:read and the mod's own sandbox env -- so the loader's cross-generation
-- denial is live exactly as in game.  The engine's own object module
-- (src/core/game3/objects.lua) is the one under the avatars: it loads without
-- a ROM, and asserting against it -- the live list, Objects.at, Objects.blocks,
-- Objects.update's step -- is what proves an avatar is a real object and not
-- a table that merely looks like one.  The map, the player and the camera
-- inputs are synthetic numbers, never ROM values.
--
-- Run: luajit mods/rby_mmo/tests/gen3_presence.lua   (from the engine root)

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local GameVersion = require("src.core.GameVersion")

local MOD_PATH = "mods/rby_mmo"
do
  -- An out-of-tree checkout: prefer the tree this file was loaded from.
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("(.+)[/\\]")
    if dir then
      local fallback = dir:gsub("[/\\]tests$", "")
      local handle = io.open(fallback .. "/src/Gen.lua", "rb")
      if handle then
        handle:close()
        MOD_PATH = fallback
      end
    end
  end
end
local makeRemapFs = dofile(MOD_PATH .. "/tests/mod_remap_fs.lua")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. msg)
  end
end
local function eq(a, b, msg)
  check(a == b, ("%s (got %s, want %s)"):format(msg, tostring(a), tostring(b)))
end
local function near(a, b, msg)
  check(type(a) == "number" and math.abs(a - b) < 1e-6,
    ("%s (got %s, want %s)"):format(msg, tostring(a), tostring(b)))
end

-- The mod's modules on the loaded mod's facade and sandbox, one graph per
-- run.  A second graph beside the one main.lua built is what a hot reload
-- is, which the look wrapper test below leans on.
local function resolver(run)
  local api = run.loader:_api(run.mod)
  local env = run.loader:_modEnv(run.mod)
  local cache = {}
  local function need(name)
    if cache[name] ~= nil then return cache[name] end
    local body = api:read("src/" .. name .. ".lua")
    local chunk = assert(env.loadstring(body, "@rby_mmo/src/" .. name .. ".lua"))
    cache[name] = chunk(need, api)
    return cache[name]
  end
  return need, api
end

local function errorText(e)
  return tostring(type(e) == "table" and (e.message or e.msg or e[1]) or e)
end

local function contains(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then return true end
  end
  return false
end

-- A love.graphics that records what the overlay prints, and nothing else.
local function stubLove()
  local printed = {}
  local font = {
    getWidth = function(_, text) return #tostring(text) * 6 end,
    getHeight = function() return 10 end,
    setFilter = function() end,
  }
  local previous = rawget(_G, "love")
  _G.love = {
    graphics = {
      newFont = function() return font end,
      getFont = function() return font end,
      setFont = function() end,
      getShader = function() return nil end,
      setShader = function() end,
      getBlendMode = function() return "alpha" end,
      setBlendMode = function() end,
      setColor = function() end,
      rectangle = function() end,
      polygon = function() end,
      push = function() end,
      pop = function() end,
      translate = function() end,
      scale = function() end,
      draw = function() end,
      getDimensions = function() return 960, 640 end,
      print = function(text, x, y) printed[#printed + 1] = { text = text, x = x, y = y } end,
    },
  }
  return printed, function() _G.love = previous end
end

local MAP = "FR_OAKS_LAB"

-- ------------------------------------------------------------------ one cart
local function cart(version)
  local em = version == "emerald"
  GameVersion.set(version)
  local label = version
  local opts = { generation = 3, data = T.sdk.gen3Data() }
  if MOD_PATH ~= "mods/rby_mmo" then opts.fs = makeRemapFs(T, MOD_PATH) end
  local run = T.sdk.loadMod("mods/rby_mmo", opts)
  eq(run.mod and run.mod.state, "loaded", label .. ": the mod loads on a Gen 3 boot")

  -- The two registries the cast wrote to are gone from the load report: a
  -- row this boot may not wear is never written (Cast.install's Gen 3 gate).
  for _, e in ipairs(run.errors) do
    local text = errorText(e)
    check(not text:find("sprites registry", 1, true),
      label .. ": no sprites-registry warning (" .. text .. ")")
    check(not text:find("battle_sprite_scales registry", 1, true),
      label .. ": no battle_sprite_scales warning (" .. text .. ")")
  end
  local talkChain = run.loader.hooks.chains["world.talk"]
  check(talkChain ~= nil and #talkChain > 0, label .. ": the load wraps world.talk")

  local need, api = resolver(run)
  local Config, Gen, Gen3 = need("Config"), need("Gen"), need("Gen3")
  local Chars, Cast, Places = need("Chars"), need("Cast"), need("Places")
  local Avatars, Overlay, Roster = need("Avatars"), need("Overlay"), need("Roster")
  local World = need("World")

  -- a live Gen 3 game, as the loader would hand it over
  local session = {
    engine = "game3", version = version, generation = 3,
    name = "LEAF", gender = 0, trainerId = 4242, secretId = 2424, money = 0,
    dex = { seen = {}, owned = {}, caught = {} }, party = {},
    flags = {}, vars = {}, map = MAP, x = 5, y = 8, facing = "up",
  }
  local mapDef = run.data.maps[MAP]
  mapDef.midLayout = { width = 13, height = 12 }
  mapDef.objects = {
    { localId = 1, graphicsId = em and 64 or 71, x = 6, y = 3, movementType = 8,
      scriptKey = "TEST_OAK" },
  }
  local game = { generation = 3, phase = "field", session = session, data = run.data }
  run.loader.game = game

  local Objects = Gen3.engine("src.core.game3.objects")
  check(Objects ~= nil, label .. ": the engine's object module is reachable")
  local P = Gen3.engine("src.core.game3.player")
  check(P ~= nil, label .. ": the engine's player module is reachable")
  Objects.reset()
  Objects.loadMap(nil, MAP, mapDef)
  local oak = Objects.find(1)
  check(oak ~= nil, label .. ": the map's own object is live")

  local function gid(name) return Gen3.gfxId(name) end
  local youngster = gid("OBJ_EVENT_GFX_YOUNGSTER")
  check(youngster ~= nil, label .. ": YOUNGSTER exists on this cart")

  -- ------------------------------------------------ Chars: the Gen 3 catalog
  local list = Chars.list(game)
  eq(list[1], Gen.defaultSprite(game), label .. ": the player's own look is listed first")
  eq(list[1], em and "OBJ_EVENT_GFX_BRENDAN_NORMAL" or "OBJ_EVENT_GFX_RED_NORMAL",
     label .. ": which is the cart's hero")
  local seenNames, allGen3 = {}, true
  for _, name in ipairs(list) do
    if not name:find("^OBJ_EVENT_GFX_") or not gid(name) then allGen3 = false end
    check(not seenNames[name], label .. ": listed once: " .. name)
    seenNames[name] = true
  end
  check(allGen3, label .. ": every listed look is a graphic on this cart")
  check(#list >= 20, label .. ": a real choice of looks (" .. #list .. ")")
  for _, hero in ipairs(em and {
    "OBJ_EVENT_GFX_BRENDAN_NORMAL", "OBJ_EVENT_GFX_MAY_NORMAL", "OBJ_EVENT_GFX_RED", "OBJ_EVENT_GFX_LEAF",
  } or {
    "OBJ_EVENT_GFX_RED_NORMAL", "OBJ_EVENT_GFX_GREEN_NORMAL", "OBJ_EVENT_GFX_RS_BRENDAN", "OBJ_EVENT_GFX_RS_MAY",
  }) do
    check(seenNames[hero], label .. ": the four heroes are wearable: " .. hero)
  end
  check(not seenNames.SPRITE_NIRE and not seenNames.SPRITE_RED,
    label .. ": no Gen 1 sheet (and no NIRE) is offered")
  check(seenNames[em and "OBJ_EVENT_GFX_ROXANNE" or "OBJ_EVENT_GFX_BROCK"],
    label .. ": this family's leaders are offered")
  check(not seenNames[em and "OBJ_EVENT_GFX_BROCK" or "OBJ_EVENT_GFX_ROXANNE"],
    label .. ": the other family's are not")

  eq(Chars.label("OBJ_EVENT_GFX_GREEN_NORMAL"), "LEAF", label .. ": GREEN_NORMAL reads LEAF")
  eq(Chars.label("OBJ_EVENT_GFX_RS_BRENDAN"), "BRENDAN", label .. ": RS_BRENDAN reads BRENDAN")
  eq(Chars.label("OBJ_EVENT_GFX_LT_SURGE"), "LT. SURGE", label .. ": a labelled row")
  eq(Chars.label("OBJ_EVENT_GFX_OLD_WOMAN"), "OLD WOMAN", label .. ": an unlisted name still reads")
  eq(Chars.label("SPRITE_COOLTRAINER_M"), "COOLTRAINER M", label .. ": Gen 1 ids read as before")

  local otherRed = em and "OBJ_EVENT_GFX_RED_NORMAL" or "OBJ_EVENT_GFX_RED"
  local myRed = em and "OBJ_EVENT_GFX_RED" or "OBJ_EVENT_GFX_RED_NORMAL"
  eq(Chars.available(otherRed, game), false, label .. ": the other family's spelling is not a look here")
  eq(Chars.resolve(otherRed, game), myRed, label .. ": ...but resolves to this family's RED")
  eq(Chars.resolve(em and "OBJ_EVENT_GFX_RS_MAY" or "OBJ_EVENT_GFX_MAY_NORMAL", game),
     em and "OBJ_EVENT_GFX_MAY_NORMAL" or "OBJ_EVENT_GFX_RS_MAY", label .. ": MAY crosses families")
  eq(Chars.resolve("SPRITE_NIRE", game), Gen.defaultSprite(game), label .. ": NIRE resolves to the default")
  eq(Chars.resolve("OBJ_EVENT_GFX_BERRY_TREE", game), Gen.defaultSprite(game),
     label .. ": a non-person graphic is not wearable")
  eq(Chars.portrait(myRed), nil, label .. ": no portrait without a sprite cache (headless)")

  -- what another player looks like on this cart
  local fid, fname = Chars.gfxForViewer(otherRed, em and "firered" or "emerald", 0)
  eq(fname, myRed, label .. ": a RED from the other family is drawn as this cart's RED")
  eq(fid, gid(myRed), label .. ": ...by number")
  local _, mayName = Chars.gfxForViewer(em and "OBJ_EVENT_GFX_RS_MAY" or "OBJ_EVENT_GFX_MAY_NORMAL",
    em and "firered" or "emerald", 1)
  eq(mayName, em and "OBJ_EVENT_GFX_MAY_NORMAL" or "OBJ_EVENT_GFX_RS_MAY", label .. ": MAY across families")
  local _, leaderName = Chars.gfxForViewer(em and "OBJ_EVENT_GFX_BROCK" or "OBJ_EVENT_GFX_ROXANNE",
    em and "firered" or "emerald")
  eq(leaderName, em and "OBJ_EVENT_GFX_RED" or "OBJ_EVENT_GFX_RS_MAY",
     label .. ": a look this family lacks falls to the link rule, by the look's gender")
  local _, tokenName = Chars.gfxForViewer(Config.DEFAULT_SPRITE_GEN3, nil, 1)
  check(tokenName ~= nil, label .. ": the hub's sprite-less token still draws somebody")

  -- An untrusted `sprite` naming a graphic this cart has but that is not a
  -- look: never drawn as itself.  A FireRed Field.interact reads an object's
  -- graphic before its script, so a peer as a Cut tree would be offered to
  -- Cut (which removes the object) and a boulder to Strength.
  local hostile = em and {
    "OBJ_EVENT_GFX_CUTTABLE_TREE", "OBJ_EVENT_GFX_BREAKABLE_ROCK", "OBJ_EVENT_GFX_PUSHABLE_BOULDER",
    "OBJ_EVENT_GFX_SS_TIDAL", "OBJ_EVENT_GFX_TRUCK", "OBJ_EVENT_GFX_BERRY_TREE",
  } or {
    "OBJ_EVENT_GFX_CUT_TREE", "OBJ_EVENT_GFX_ROCK_SMASH_ROCK", "OBJ_EVENT_GFX_PUSHABLE_BOULDER",
    "OBJ_EVENT_GFX_SS_ANNE", "OBJ_EVENT_GFX_METEORITE",
  }
  local linkBoy = Chars.gfxForViewer(Config.DEFAULT_SPRITE_GEN3, version, 0)
  local tested = 0
  for _, name in ipairs(hostile) do
    local hid = gid(name)
    if hid then
      tested = tested + 1
      eq(Gen3.lookAllowed(name), false, label .. ": " .. name .. " is not a look")
      local vid = Gen3.viewerGfxFor(name, version, 0)
      check(vid ~= hid, label .. ": viewerGfxFor does not draw a peer as " .. name)
      eq(vid, linkBoy, label .. ": ...but as the link rule's player (" .. name .. ")")
      local cid = Chars.gfxForViewer(name, em and "firered" or "emerald", 1)
      check(cid ~= nil and cid ~= hid, label .. ": nor does Chars.gfxForViewer, from either family (" .. name .. ")")
      eq(Gen.resolveSprite(game, name), Gen.defaultSprite(game),
         label .. ": resolveSprite does not keep " .. name)
    end
  end
  check(tested >= 4, label .. ": the cart has the non-look graphics to test against (" .. tested .. ")")
  eq(Gen.resolveSprite(game, "OBJ_EVENT_GFX_YOUNGSTER"), "OBJ_EVENT_GFX_YOUNGSTER",
     label .. ": a look still resolves as itself")
  eq(Gen.resolveSprite(game, myRed), myRed, label .. ": ...and so does the hero")
  eq(Gen3.viewerGfxFor("OBJ_EVENT_GFX_YOUNGSTER", version, 0), youngster,
     label .. ": a look is still drawn as itself")
  check(Gen3.lookAllowed(em and "OBJ_EVENT_GFX_RIVAL_MAY_NORMAL" or "OBJ_EVENT_GFX_RS_MAY"),
        label .. ": a player-trainer graphic is allowed")

  -- ------------------------------------------------ Places
  eq(Places.name(game, "EM_LITTLEROOT_TOWN"), "LITTLEROOT TOWN", label .. ": an Emerald town is named")
  eq(Places.name(game, "FR_VIRIDIAN_CITY"), "VIRIDIAN CITY", label .. ": a FireRed city is named")
  eq(Places.name(game, "EM_PETALBURG_CITY_GYM"), "PETALBURG CITY GYM", label .. ": prefix off, words kept")
  check(Places.name(game, MAP) ~= nil and not Places.name(game, MAP):find("^FR_"),
    label .. ": this map's own name carries no prefix")
  eq(Places.name(game, "PALLET_TOWN"), "PALLET TOWN", label .. ": a Gen 1 id still reads as words")
  eq(Places.name(game, nil), nil, label .. ": no map, no name")

  -- ------------------------------------------------ Cast
  eq(#Cast.ids(), 0, label .. ": the cast registers nothing before install")
  Cast.install()
  eq(#Cast.ids(), 0, label .. ": ...and nothing after it: NIRE stays Gen 1")
  eq(Cast.pic("SPRITE_NIRE", "back"), nil, label .. ": no NIRE battle pic")

  -- the own-look wrapper (this graph re-installed it, the way a hot reload
  -- would -- over the pristine original, not over the first graph's wrapper)
  local OwSprites = Gen3.engine("src.core.game3.ow_sprites")
  local original = rawget(OwSprites, "__rby_mmo_playerGraphicsId")
  check(type(original) == "function", label .. ": the engine's original is kept on its module")
  check(OwSprites.playerGraphicsId ~= original, label .. ": and the slot holds the wrapper")
  P.biking, P.surfing, P.fishing, P.fieldMoveAnim, P.running = false, false, false, 0, false
  local walk = original(game, P)
  eq(walk, gid(Gen3.playerGfxName(0)), label .. ": on foot, the engine draws the hero")
  eq(OwSprites.playerGraphicsId(game, P), walk, label .. ": no choice made: nothing is worn")
  api.save:set("sprite", em and "OBJ_EVENT_GFX_WALLY" or "OBJ_EVENT_GFX_BLUE")
  local worn = gid(em and "OBJ_EVENT_GFX_WALLY" or "OBJ_EVENT_GFX_BLUE")
  eq(OwSprites.playerGraphicsId(game, P), worn, label .. ": a chosen look replaces the walking graphic")
  local wornId, isWorn = Cast.lookGfx3(game)
  eq(wornId, worn, label .. ": lookGfx3 reports it")
  eq(isWorn, true, label .. ": ...as worn")
  P.biking = true
  local bike = original(game, P)
  check(bike ~= walk, label .. ": the bike is its own graphic")
  eq(OwSprites.playerGraphicsId(game, P), bike, label .. ": on the bike the cart's own bike stays")
  P.biking = false
  api.save:set("sprite", em and "OBJ_EVENT_GFX_MAY_NORMAL" or "OBJ_EVENT_GFX_RS_MAY")
  eq(OwSprites.playerGraphicsId(game, P), gid(em and "OBJ_EVENT_GFX_MAY_NORMAL" or "OBJ_EVENT_GFX_RS_MAY"),
     label .. ": a changed choice is worn on the next frame")
  api.save:set("sprite", Gen3.playerGfxName(0))
  eq(OwSprites.playerGraphicsId(game, P), walk, label .. ": choosing your own hero is a restore")
  api.save:set("sprite", nil)
  eq(OwSprites.playerGraphicsId(game, P), walk, label .. ": clearing the choice takes the look off")
  api.save:set("sprite", em and "OBJ_EVENT_GFX_WALLY" or "OBJ_EVENT_GFX_BLUE")
  Cast.restoreLook3()
  eq(OwSprites.playerGraphicsId, original, label .. ": restoreLook3 puts the engine's function back")
  eq(rawget(OwSprites, "__rby_mmo_playerGraphicsId"), nil, label .. ": and forgets the stash")
  eq(OwSprites.playerGraphicsId(game, P), walk, label .. ": the engine draws the hero again")
  check(Cast.installLook3(), label .. ": installLook3 wraps it again")
  eq(OwSprites.playerGraphicsId(game, P), worn, label .. ": and wears the look again")

  -- The wrapper answers every drawn frame, three to five times: with the
  -- choice standing still it allocates nothing (no mod.find handle per call,
  -- no pcall closures reading the choice).
  -- measured with the JIT off: a trace's own bookkeeping counts as garbage,
  -- and allocation sinking would hide exactly the tables this looks for
  local jitWas = jit and jit.status and jit.status()
  if jit then jit.off(); jit.flush() end
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  for _ = 1, 2000 do OwSprites.playerGraphicsId(game, P) end
  local grew = collectgarbage("count") - before
  collectgarbage("restart")
  if jit and jitWas then jit.on() end
  check(grew < 4, label .. ": 2000 look-wrapper calls allocate nothing (" .. math.floor(grew * 1024) .. " bytes)")

  -- Another mod wraps on top of ours, then this mod is hot-reloaded: the new
  -- wrapper goes over *theirs*, not over the engine's original -- which would
  -- drop their wrapper from the chain -- and ours underneath it goes inert.
  local ours = OwSprites.playerGraphicsId
  local foreignCalls = 0
  local function foreign(g, p)
    foreignCalls = foreignCalls + 1
    return ours(g, p)
  end
  OwSprites.playerGraphicsId = foreign
  local need3 = resolver(run)
  local Cast3 = need3("Cast")
  check(Cast3.installLook3(), label .. ": a reloaded graph wraps again")
  check(OwSprites.playerGraphicsId ~= foreign, label .. ": ...on top of the other mod's wrapper")
  foreignCalls = 0
  eq(OwSprites.playerGraphicsId(game, P), worn, label .. ": the look is worn through the new wrapper")
  eq(foreignCalls, 1, label .. ": ...with the other mod's wrapper still in the chain")
  eq(rawget(OwSprites, "__rby_mmo_playerGraphicsId"), original,
     label .. ": the stash still holds the engine's own function")
  check(Cast3.restoreLook3(), label .. ": the reloaded graph restores")
  eq(OwSprites.playerGraphicsId, foreign, label .. ": ...putting back the other mod's wrapper, not the original")
  eq(OwSprites.playerGraphicsId(game, P), walk,
     label .. ": ...and our older wrapper under it answers as the engine would")
  -- the other mod takes its own wrapper off, the old graph's comes off after
  -- it, and the reloaded graph -- the live one now -- wears the look again
  OwSprites.playerGraphicsId = ours
  Cast.restoreLook3()
  eq(OwSprites.playerGraphicsId, original, label .. ": unwound to the engine's function")
  eq(rawget(OwSprites, "__rby_mmo_playerGraphicsId"), nil, label .. ": ...and the stash is gone")
  check(Cast3.installLook3(), label .. ": and wrapped once more")
  eq(OwSprites.playerGraphicsId(game, P), worn, label .. ": wearing the look")
  api.save:set("sprite", nil)

  -- ------------------------------------------------ Avatars
  local roster = Roster.new()
  local avatars = Avatars.new()
  local base = Config.GEN3_AVATAR_LOCAL_ID_BASE
  local here = { mapId = MAP, x = 5, y = 8, facing = "up" }
  local mySprite = em and "OBJ_EVENT_GFX_MAY_NORMAL" or "OBJ_EVENT_GFX_GREEN_NORMAL"
  roster:put({ id = "p1", name = "ASH", map = MAP, x = 4, y = 6, facing = "down",
               sprite = mySprite, version = version })

  avatars:sync(roster, here)
  local av = avatars.spawned.p1
  check(av ~= nil, label .. ": a player on this map gets an avatar")
  local eo = av and av.eo
  eq(av and av.lid, base, label .. ": under the first mod localId (past 0xFF)")
  check(av and av.lid > 0xFF, label .. ": which no script opcode can address")
  eq(Objects._byId[base], eo, label .. ": injected into the engine's live list")
  check(contains(Objects._order, base), label .. ": and its draw / update order")
  eq(Objects.find(base), eo, label .. ": Objects.find sees it")
  eq(eo and eo.graphicsId, gid(mySprite), label .. ": drawn as the sprite they sent")
  eq(eo and eo.passable, true, label .. ": passable")
  eq(Objects.blocks(4, 6), false, label .. ": never in the local player's way")
  eq(Objects.at(4, 6), eo, label .. ": but the A press finds it")
  eq(eo and eo.def.scriptKey, Avatars.TALK_KEY, label .. ": carrying the talk key")
  eq(eo and eo.facing, "down", label .. ": facing as they face")
  eq(eo and eo.cellX, 4, label .. ": at their cell x")
  eq(eo and eo.cellY, 6, label .. ": at their cell y")
  near(eo and eo.py, 6 * 16 - Config.AVATAR_DEPTH_NUDGE, label .. ": standing, nudged a hair up the draw sort")
  local ax, ay = avatars:cellOf("p1")
  eq(ax, 4, label .. ": cellOf x (the nudge taken back off)")
  eq(ay, 6, label .. ": cellOf y")
  eq(avatars:isWalking("p1"), false, label .. ": standing still")
  local drawn = false
  for _, o in ipairs(Objects.forDraw()) do if o == eo then drawn = true end end
  check(drawn, label .. ": the engine's draw list includes it")

  -- The engine passes that walk the same list for their own ends leave it
  -- out.  The quest log (FRLG's CONTINUE recap, saved with the game) records
  -- the draw list as actors: the map's own object stays, the avatar does not.
  local Recorder = Gen3.engine("src.core.game3.quest_log_recorder")
  check(Recorder ~= nil, label .. ": the engine's quest-log recorder is reachable")
  if Recorder then
    local frame = Recorder.capture(game, session)
    local sawOak, sawAvatar = false, false
    for _, actor in ipairs(frame and frame.actors or {}) do
      if actor.id == 1 then sawOak = true end
      if actor.id == base then sawAvatar = true end
    end
    check(sawOak, label .. ": the quest log still records the map's own object")
    check(not sawAvatar, label .. ": but not another player")
    drawn = false
    for _, o in ipairs(Objects.forDraw()) do if o == eo then drawn = true end end
    check(drawn, label .. ": ...and the avatar is still drawn after the capture")
  end
  -- Emerald's rotating-tile puzzle shoves every object standing on an arrow;
  -- another player standing on one is not the switch-presser's to move.
  if em then
    local Puzzle = Gen3.engine("src.core.game3.rotating_tile_puzzle")
    local Collision = Gen3.engine("src.core.game3.collision")
    local Constants = Gen3.engine("src.core.game3.constants")
    local okStart, arrow = pcall(function()
      return Constants.of(version):require("metatile_labels", "METATILE_MossdeepGym_YellowArrow_Right")
    end)
    check(Puzzle ~= nil and Collision ~= nil and okStart, label .. ": the puzzle is reachable headless")
    if Puzzle and Collision and okStart then
      local savedDef = Collision._mapDef
      -- a synthetic layout: an arrow under Oak and under the avatar, floor elsewhere
      Collision._mapDef = { midLayout = { midAt = function(_, x, y)
        if (x == 6 and y == 3) or (x == eo.cellX and y == eo.cellY) then return arrow end
        return 0
      end } }
      Puzzle.init(false)
      Puzzle.move(nil, 0)
      local movedLids = {}
      for _, o in ipairs(Puzzle._p and Puzzle._p.objects or {}) do movedLids[o.lid] = true end
      check(movedLids[1], label .. ": the puzzle still moves the map's own object")
      check(not movedLids[base], label .. ": but not another player")
      check(Puzzle.lastMoved ~= base, label .. ": ...who is never its lastMoved")
      eq(Objects._tracks[base], nil, label .. ": ...and gets no movement track")
      eq(eo.visible, true, label .. ": the avatar is visible again after the call")
      eq(eo.mmoShielded, nil, label .. ": ...with no shield left on it")
      -- an engine error inside the call still reaches its caller, and the
      -- avatar it left shielded is visible again on the next tick
      Collision._mapDef = { midLayout = { midAt = function() error("synthetic layout failure") end } }
      Puzzle.init(false)
      check(not pcall(Puzzle.move, nil, 0), label .. ": a puzzle error still reaches the engine")
      eq(eo.visible, false, label .. ": ...leaving the avatar shielded for the moment")
      avatars:sync(roster, here)
      eq(eo.visible, true, label .. ": the next tick lifts the shield")
      eq(eo.mmoShielded, nil, label .. ": ...and forgets it")
      Puzzle.free()
      Collision._mapDef = savedDef
      Objects.clearMovements()
      if type(Objects._perm) == "table" then Objects._perm[MAP] = nil end
    end
  end

  -- a step, walked by the engine
  roster:move("p1", MAP, 5, 6, "right", false)
  avatars:sync(roster, here)
  eq(eo.moving, true, label .. ": a move starts a step")
  eq(eo.targetX, 5, label .. ": toward the new cell")
  eq(eo.facing, "right", label .. ": facing the way it walks")
  eq(eo.stepFrames, Avatars.GEN3_WALK_FRAMES, label .. ": at walking pace")
  eq(avatars:isWalking("p1"), true, label .. ": isWalking while it does")
  eq(Objects._tracks[base], nil, label .. ": with no movement track (nothing for a seamless edge to carry)")
  -- The stride frame shows somewhere in the step (which frames is the
  -- engine's: Objects.walkPhase, its own step-anim cycle), so every frame of
  -- the step is looked at.
  local sawPhase = false
  for _ = 1, 8 do
    Objects.update(game)
    if Objects.walkPhase(eo) == 1 then sawPhase = true end
  end
  local midX = avatars:cellOf("p1")
  check(midX > 4 and midX < 5, label .. ": mid-step the plate's cell glides (" .. tostring(midX) .. ")")
  for _ = 1, 8 do
    Objects.update(game)
    if Objects.walkPhase(eo) == 1 then sawPhase = true end
  end
  eq(eo.moving, false, label .. ": the step lands after 16 frames")
  eq(eo.cellX, 5, label .. ": on the new cell")
  check(sawPhase, label .. ": with the engine's walk cycle")

  -- catch-up pacing
  eq(Avatars.stepFrames3(1, false), 16, label .. ": one tile behind walks")
  eq(Avatars.stepFrames3(1, true), 8, label .. ": a fast step runs")
  eq(Avatars.stepFrames3(2, false), 8, label .. ": two behind runs")
  eq(Avatars.stepFrames3(5, false), 4, label .. ": four or more rides")
  roster:move("p1", MAP, 8, 6, "right", false)
  avatars:sync(roster, here)
  eq(eo.stepFrames, 8, label .. ": three tiles behind catches up at 8")
  for _ = 1, 8 do Objects.update(game) end
  eq(eo.cellX, 6, label .. ": one tile in 8 frames")
  roster:move("p1", MAP, 11, 6, "right", false)
  avatars:sync(roster, here)
  eq(eo.stepFrames, 4, label .. ": five behind rides at 4")
  for _ = 1, 4 do Objects.update(game) end
  eq(eo.cellX, 7, label .. ": one tile in 4 frames")

  -- too far to walk: snapped
  roster:move("p1", MAP, 7, 11 + Config.RESYNC_DISTANCE, "up", false)
  avatars:sync(roster, here)
  eq(eo.cellY, 11 + Config.RESYNC_DISTANCE, label .. ": past RESYNC_DISTANCE it is placed, not walked")
  eq(eo.moving, false, label .. ": standing where it was placed")
  eq(avatars.spawned.p1.eo, eo, label .. ": the same object, not a new one")

  -- turning on the spot
  roster:move("p1", MAP, 7, 11 + Config.RESYNC_DISTANCE, "left", false)
  avatars:sync(roster, here)
  eq(eo.facing, "left", label .. ": a turn in place turns the avatar")
  eq(eo.moving, false, label .. ": without a step")

  -- a same-map reload wipes the engine's list; the next tick puts it back
  roster:move("p1", MAP, 7, 9, "left", false)
  avatars:sync(roster, here)
  Objects.loadMap(nil, MAP, mapDef)
  eq(Objects._byId[base], nil, label .. ": a reload wiped the list")
  avatars:sync(roster, here)
  eq(Objects._byId[base], eo, label .. ": re-injected on the next tick")
  check(contains(Objects._order, base), label .. ": back in the order list too")
  eq(eo.cellX, 7, label .. ": where it stood")

  -- a second player gets its own id
  roster:put({ id = "p2", name = "GARY", map = MAP, x = 2, y = 2, facing = "down",
               sprite = em and "OBJ_EVENT_GFX_RED_NORMAL" or "OBJ_EVENT_GFX_BRENDAN_NORMAL",
               version = em and "firered" or "emerald" })
  avatars:sync(roster, here)
  local av2 = avatars.spawned.p2
  eq(av2 and av2.lid, base + 1, label .. ": a second avatar takes the next id")
  eq(av2 and av2.eo.graphicsId, gid(em and "OBJ_EVENT_GFX_RED" or "OBJ_EVENT_GFX_RS_BRENDAN"),
     label .. ": a player from the other family, drawn in this family's spelling")

  -- a new look, swapped on the live object
  roster:setSprite("p2", em and "OBJ_EVENT_GFX_WALLY" or "OBJ_EVENT_GFX_BLUE")
  local p2 = roster:get("p2")
  p2.version = version
  avatars:refresh(p2)
  eq(av2.eo.graphicsId, gid(em and "OBJ_EVENT_GFX_WALLY" or "OBJ_EVENT_GFX_BLUE"),
     label .. ": refresh swaps the graphic in place")
  eq(Objects._byId[base + 1], av2.eo, label .. ": the same object stays in the list")

  -- the A press on an avatar is the mod's; on anything else, the engine's
  local talked = 0
  local function vanilla() talked = talked + 1 end
  run.loader.hooks:call("world.talk", vanilla, game, eo)
  eq(talked, 0, label .. ": talking to an avatar starts no engine script")
  run.loader.hooks:call("world.talk", vanilla, game, oak)
  eq(talked, 1, label .. ": talking to the map's own NPC still does")
  check(Avatars.isAvatar3(eo) and not Avatars.isAvatar3(oak), label .. ": isAvatar3 tells them apart")

  -- leaving: gone from the list, id freed
  roster:remove("p2")
  avatars:sync(roster, here)
  eq(avatars.spawned.p2, nil, label .. ": a player who left loses their avatar")
  eq(Objects._byId[base + 1], nil, label .. ": taken out of the engine's list")
  check(not contains(Objects._order, base + 1), label .. ": and its order list")
  eq(avatars.lids[base + 1], nil, label .. ": its id is free again")
  eq(av2.eo.hidden, true, label .. ": and the object let go is hidden for good")
  eq(av2.eo.visible, false, label .. ": ...not drawn from any list that still holds it")

  -- A peer who presents as a field-move object is not one: the avatar is
  -- built with a look, so the field never offers Cut / Rock Smash / Strength
  -- on another player, and the A press still reaches the ACTIONS menu.
  local cutName = em and "OBJ_EVENT_GFX_CUTTABLE_TREE" or "OBJ_EVENT_GFX_CUT_TREE"
  roster:put({ id = "evil", name = "TREE", map = MAP, x = 2, y = 9, facing = "down",
               sprite = cutName, version = version, gender = 0 })
  avatars:sync(roster, here)
  local evil = avatars.spawned.evil and avatars.spawned.evil.eo
  check(evil ~= nil, label .. ": a peer with a hostile sprite still gets an avatar")
  if evil then
    check(evil.graphicsId ~= gid(cutName), label .. ": ...but not drawn as a Cut tree")
    eq(evil.graphicsId, linkBoy, label .. ": ...drawn by the link rule instead")
    eq(evil.def.graphicsId, evil.graphicsId, label .. ": its template agrees (Field.interact reads that)")
    local FieldMoves = Gen3.engine("src.core.game3.field_moves")
    local ids = FieldMoves and FieldMoves.GFX_IDS
    if type(ids) == "table" then
      check(evil.def.graphicsId ~= ids.CUT_TREE and evil.def.graphicsId ~= ids.ROCK_SMASH_ROCK
            and evil.def.graphicsId ~= ids.PUSHABLE_BOULDER,
            label .. ": none of the graphics Field.interact offers a field move on")
    end
    local talkedEvil = 0
    run.loader.hooks:call("world.talk", function() talkedEvil = talkedEvil + 1 end, game, evil)
    eq(talkedEvil, 0, label .. ": the A press on it is still the mod's")
  end
  -- and a look change to a hostile graphic is refused the same way
  roster:setSprite("evil", em and "OBJ_EVENT_GFX_PUSHABLE_BOULDER" or "OBJ_EVENT_GFX_ROCK_SMASH_ROCK")
  local evilRow = roster:get("evil")
  evilRow.version, evilRow.gender = version, 0
  avatars:refresh(evilRow)
  if evil then
    eq(evil.graphicsId, linkBoy, label .. ": a refreshed hostile look is refused too")
  end
  roster:remove("evil")
  avatars:sync(roster, here)
  eq(avatars.spawned.evil, nil, label .. ": (the hostile peer leaves)")

  -- a player walking off to another map
  roster:move("p1", "FR_ROUTE_1", 3, 3, "up", false)
  avatars:sync(roster, here)
  eq(avatars.spawned.p1, nil, label .. ": a player on another map has no avatar here")
  eq(Objects._byId[base], nil, label .. ": and nothing in the list")

  -- ...and back, then the local player leaves the map
  roster:move("p1", MAP, 4, 4, "down", false)
  avatars:sync(roster, here)
  check(avatars.spawned.p1 ~= nil, label .. ": back on this map, back as an avatar")
  avatars:sync(roster, { mapId = "FR_PALLET_TOWN", x = 1, y = 1, facing = "down" })
  eq(next(avatars.spawned), nil, label .. ": a map change drops every avatar")
  eq(avatars.mapId, "FR_PALLET_TOWN", label .. ": and follows the local player")
  avatars:sync(roster, nil)
  eq(avatars.mapId, nil, label .. ": no world (title, a battle on Gen 1), no avatars")

  -- the engine's list still on the old map during a warp: nothing is spawned
  Objects.loadMap(nil, MAP, mapDef)
  avatars:sync(roster, { mapId = "FR_PALLET_TOWN", x = 1, y = 1, facing = "down" })
  roster:move("p1", "FR_PALLET_TOWN", 2, 2, "down", false)
  avatars:sync(roster, { mapId = "FR_PALLET_TOWN", x = 1, y = 1, facing = "down" })
  eq(avatars.spawned.p1, nil, label .. ": nothing is put into a list about to be wiped")
  roster:move("p1", MAP, 4, 6, "down", false)

  -- A seamless crossing.  Map.load snapshots the list it is leaving into
  -- that map's ghost pool (Ghosts.capture) before loading the next, and
  -- FieldView keeps drawing a neighbour's pool -- so an avatar left behind
  -- would stand frozen on the old map's side of the edge, and a player who
  -- followed would be drawn twice.  Driven with the engine's own Ghosts.
  local Ghosts = Gen3.engine("src.core.game3.ghosts")
  check(Ghosts ~= nil, label .. ": the engine's ghost pools are reachable")
  if Ghosts then
    local NEXT = "FR_PALLET_TOWN"
    local nextDef = { midLayout = { width = 20, height = 18 }, objects = {} }
    local nextHere = { mapId = NEXT, x = 3, y = 3, facing = "up" }
    local function ghostsOf(playerId)
      local n = 0
      for mapId in pairs(Ghosts._pools) do
        for _, o in ipairs(Ghosts.forDraw(mapId) or {}) do
          if o.mmoAvatar == playerId then n = n + 1 end
        end
      end
      return n
    end
    local function drawnOf(playerId)
      local n = ghostsOf(playerId)
      for _, o in ipairs(Objects.forDraw()) do
        if o.mmoAvatar == playerId then n = n + 1 end
      end
      return n
    end
    Ghosts.clear()
    avatars:sync(roster, here)
    local left = avatars.spawned.p1 and avatars.spawned.p1.eo
    check(left ~= nil, label .. ": (standing next to the edge)")
    Ghosts.capture(MAP)                        -- Map.load, on the way out
    eq(ghostsOf("p1"), 1, label .. ": the engine copies the avatar into the old map's ghost pool")
    Objects.loadMap(nil, NEXT, nextDef)       -- ...then loads the next map
    avatars:sync(roster, nextHere)            -- and the next tick
    eq(ghostsOf("p1"), 0, label .. ": no frozen copy is left drawn on the neighbouring map")
    eq(left and left.hidden, true, label .. ": the avatar let go is hidden")
    local pooled = false
    for _, pool in pairs(Ghosts._pools) do
      for _, lid in ipairs(pool.order or {}) do
        if Avatars.isAvatar3(pool.byId[lid]) then pooled = true end
      end
    end
    check(not pooled, label .. ": and no ghost pool holds an avatar at all")
    local oakPooled = false
    for _, lid in ipairs(Ghosts._pools[MAP] and Ghosts._pools[MAP].order or {}) do
      if lid == 1 then oakPooled = true end
    end
    check(oakPooled, label .. ": the map's own objects stay in its ghost pool")
    -- the other player follows across the edge: drawn exactly once
    roster:move("p1", NEXT, 3, 1, "up", false)
    avatars:sync(roster, nextHere)
    eq(drawnOf("p1"), 1, label .. ": a player who follows is drawn exactly once")
    avatars:clear()
    Ghosts.clear()
    Objects.loadMap(nil, MAP, mapDef)
    avatars:sync(roster, nil)
    roster:move("p1", MAP, 4, 6, "down", false)
  end

  -- Players on seamless neighbours use the engine's native ghost pools,
  -- animate in local cells, and project plates into the active map.
  do
    local Map = Gen3.engine("src.core.game3.map")
    local savedWorld, savedRoot = Map.world, Map._worldRoot
    local defs = { [MAP] = { midLayout = { width = 13, height = 12 }, connections = {} } }
    local expected = {
      north = { 2, -10 }, south = { -3, 12 },
      west = { -9, 4 }, east = { 13, -2 },
    }
    local oldDefs = {}
    for dir, offset in pairs(expected) do
      local id = "MMO_NEIGHBOUR_" .. dir
      oldDefs[id] = game.data.maps[id]
      local def = { midLayout = { width = 9, height = 10,
        collAt = function() return 0 end }, objects = {
        { localId = 1, graphicsId = gid(mySprite), x = 1, y = 1, movementType = 0 },
      } }
      defs[id], game.data.maps[id] = def, def
      local along = (dir == "north" or dir == "south") and offset[1] or offset[2]
      defs[MAP].connections[#defs[MAP].connections + 1] = { dir = dir, map = id, offset = along }
      roster:put({ id = dir, name = dir, map = id, x = 3, y = 4,
        facing = "down", sprite = mySprite, version = version })
    end
    Map.world = Map.computeWorld(defs, MAP, 1)
    Map._worldRoot = MAP
    Ghosts.clear()
    avatars:sync(roster, here)
    eq(#avatars:visiblePlayers3(roster, MAP), 5, label .. ": connected players included")
    for dir, offset in pairs(expected) do
      local neighbor = avatars.spawned[dir]
      local pool = Ghosts._pools[roster:get(dir).map]
      check(neighbor ~= nil, label .. ": " .. dir .. " avatar exists")
      eq(Objects._byId[neighbor.lid], nil, label .. ": neighbour stays out of live objects")
      eq(pool.byId[neighbor.lid], neighbor.eo, label .. ": neighbour injected into its pool")
      check(pool.byId[1] ~= nil, label .. ": neighbouring NPC preserved")
      check(contains(Ghosts.forDraw(roster:get(dir).map), neighbor.eo), label .. ": neighbour drawable")
      local x, y = avatars:cellOf(dir)
      eq(x, 3 + offset[1], label .. ": " .. dir .. " plate x offset")
      eq(y, 4 + offset[2], label .. ": " .. dir .. " plate y offset")
    end
    -- A neighbour near the edge gets a plate through the actual HUD draw.
    roster:move("west", roster:get("west").map, 8, 4, "down", false)
    Avatars.placeAt3(avatars.spawned.west.eo, 8, 4, "down")
    local printed, restoreLove = stubLove()
    local worldCurrent = World.current
    World.current = function() return here end
    local P = Gen3.engine("src.core.game3.player")
    local oldPx, oldPy = P.px, P.py
    P.px, P.py = here.x * 16, here.y * 16
    local overlay = Overlay.new({ roster = roster, avatars = avatars,
      client = { isConnected = function() return true end } })
    overlay:draw(game, { gameX = 0, gameY = 0, scale = 4 })
    local plate
    for _, line in ipairs(printed) do if line.text == "west" then plate = line end end
    check(plate ~= nil, label .. ": neighbouring player's nameplate is printed")
    eq(overlay:state().here, 5, label .. ": overlay includes connected players")
    P.px, P.py = oldPx, oldPy
    World.current = worldCurrent
    restoreLove()

    local north = avatars.spawned.north
    roster:move("north", roster:get("north").map, 4, 4, "right", false)
    avatars:sync(roster, here)
    check(north.eo.moving, label .. ": neighbour starts an animated step")
    for _ = 1, 16 do Ghosts.update(game) end
    eq(north.eo.cellX, 4, label .. ": ghost update finishes neighbour step")
    eq(north.eo.moving, false, label .. ": neighbour step lands")
    eq(avatars:refresh(roster:get("north")), north.lid, label .. ": neighbour look can refresh")
    local old = north.eo
    roster:move("north", MAP, 3, 4, "right", false)
    avatars:sync(roster, here)
    eq(old.hidden, true, label .. ": crossing retires old neighbour object")
    eq(Objects._byId[avatars.spawned.north.lid], avatars.spawned.north.eo,
      label .. ": crossing creates one live avatar")
    for _, pool in pairs(Ghosts._pools) do
      for _, object in pairs(pool.byId) do
        check(object.mmoAvatar ~= "north", label .. ": crossing leaves no duplicate in pools")
      end
    end
    Map.world = {}
    avatars:sync(roster, here)
    eq(avatars.spawned.east, nil, label .. ": disconnected neighbour removed")
    Map.world, Map._worldRoot = savedWorld, savedRoot
    for dir in pairs(expected) do
      roster:remove(dir)
      local id = "MMO_NEIGHBOUR_" .. dir
      game.data.maps[id] = oldDefs[id]
    end
    avatars:clear()
    Ghosts.clear()
  end

  -- A connected map with no object events gets no ghost pool from the
  -- engine (ghosts.lua defsFor answers nil), so avatarPool3 makes one to
  -- stand the avatar in.  A clear takes that pool back out of the engine's
  -- table -- and only that one: an engine-built pool, or a made one the
  -- engine has since replaced (Ghosts.capture), is left where it is.
  do
    local Map = Gen3.engine("src.core.game3.map")
    local savedWorld, savedRoot = Map.world, Map._worldRoot
    local BARE, FULL = "MMO_NEIGHBOUR_bare", "MMO_NEIGHBOUR_full"
    local defs = { [MAP] = { midLayout = { width = 13, height = 12 }, connections = {
      { dir = "north", map = BARE, offset = 0 },
      { dir = "south", map = FULL, offset = 0 },
    } } }
    defs[BARE] = { midLayout = { width = 9, height = 10, collAt = function() return 0 end } }
    defs[FULL] = { midLayout = { width = 9, height = 10, collAt = function() return 0 end },
      objects = { { localId = 1, graphicsId = gid(mySprite), x = 1, y = 1, movementType = 0 } } }
    local oldDefs = { [BARE] = game.data.maps[BARE], [FULL] = game.data.maps[FULL] }
    game.data.maps[BARE], game.data.maps[FULL] = defs[BARE], defs[FULL]
    roster:put({ id = "bare", name = "bare", map = BARE, x = 3, y = 4,
      facing = "down", sprite = mySprite, version = version })
    roster:put({ id = "full", name = "full", map = FULL, x = 3, y = 4,
      facing = "down", sprite = mySprite, version = version })
    Map.world = Map.computeWorld(defs, MAP, 1)
    Map._worldRoot = MAP
    Ghosts.clear()
    avatars:sync(roster, here)
    local made, built = Ghosts._pools[BARE], Ghosts._pools[FULL]
    local bare = avatars.spawned.bare
    check(made ~= nil and bare ~= nil and made.byId[bare.lid] == bare.eo,
      label .. ": a neighbour with no object events gets a pool the mod made")
    check(built ~= nil and built.byId[1] ~= nil, label .. ": a neighbour with objects keeps the engine's")
    avatars:clear()
    eq(Ghosts._pools[BARE], nil, label .. ": the pool the mod made is dropped on a clear")
    eq(Ghosts._pools[FULL], built, label .. ": the engine-built pool is left alone")
    check(built.byId[1] ~= nil, label .. ": its own NPC still in it")
    avatars:sync(roster, here)
    local remade = Ghosts._pools[BARE]
    check(remade ~= nil and remade ~= made, label .. ": the next sync makes a fresh one")
    local captured = { byId = {}, order = {} }
    Ghosts._pools[BARE] = captured
    avatars:clear()
    eq(Ghosts._pools[BARE], captured, label .. ": a made pool the engine has since replaced is the engine's")
    Map.world, Map._worldRoot = savedWorld, savedRoot
    roster:remove("bare")
    roster:remove("full")
    game.data.maps[BARE], game.data.maps[FULL] = oldDefs[BARE], oldDefs[FULL]
    avatars:clear()
    Ghosts.clear()
  end

  -- An empty slot is not an empty map: Ghosts.sync also leaves a neighbour
  -- with objects unbuilt while prepareOffscreen defers it to the worker (off
  -- screen, worker threads up).  A pool the mod made there would hide that
  -- map's NPCs until the next map change, so the player there waits for the
  -- engine's own pool -- whether the templates are on the map def or in the
  -- scripting bundle (ghosts.lua defsFor reads both).  A map with none still
  -- gets a made pool, and a made pool goes once its last avatar does.
  -- Driven through the engine's real Ghosts.sync with the deferral switched on.
  do
    local Map = Gen3.engine("src.core.game3.map")
    local savedWorld, savedRoot = Map.world, Map._worldRoot
    local savedRect, savedNear = Map.warmRect, Map.warmNear
    local Space = Gen3.engine("src.core.game3.scripting.space")
    local savedBundle = Space.bundle
    local BARE, FULL, EVENTS = "MMO_DEFER_bare", "MMO_DEFER_full", "MMO_DEFER_events"
    local npc = { localId = 1, graphicsId = gid(mySprite), x = 1, y = 1, movementType = 0 }
    local layout = function() return { width = 9, height = 10, collAt = function() return 0 end } end
    local defs = { [MAP] = { midLayout = { width = 13, height = 12 }, connections = {
      { dir = "north", map = BARE, offset = 0 },
      { dir = "south", map = FULL, offset = 0 },
      { dir = "east", map = EVENTS, offset = 0 },
    } } }
    defs[BARE] = { midLayout = layout() }
    defs[FULL] = { midLayout = layout(), objects = { npc } }
    defs[EVENTS] = { midLayout = layout() }
    local oldDefs = {}
    for _, id in ipairs({ BARE, FULL, EVENTS }) do
      oldDefs[id] = game.data.maps[id]
      game.data.maps[id] = defs[id]
    end
    Space.bundle = { events = { [EVENTS] = { objects = { npc } } } }
    for _, p in ipairs({ { "bare", BARE }, { "bare2", BARE }, { "full", FULL }, { "events", EVENTS } }) do
      roster:put({ id = p[1], name = p[1], map = p[2], x = 3, y = 4,
        facing = "down", sprite = mySprite, version = version })
    end
    local function defer(on)
      if on then
        Map.warmRect = function() return 0, 0, 1, 1 end
        Map.warmNear = function() return false end
        _G.love = { thread = { newThread = function() end } }
      else
        Map.warmRect, Map.warmNear = savedRect, savedNear
        _G.love = nil
      end
    end
    local savedLove = rawget(_G, "love")
    local function lidsOf(playerId)
      local n = 0
      for _, owner in pairs(avatars.lids) do if owner == playerId then n = n + 1 end end
      return n
    end
    Map.world = Map.computeWorld(defs, MAP, 1)
    Map._worldRoot = MAP
    Ghosts.clear()
    avatars.spawnWarned = nil
    defer(true)
    avatars:sync(roster, here)
    avatars:sync(roster, here)                 -- and the tick after: still waiting
    defer(false)
    _G.love = savedLove
    eq(Ghosts._pools[FULL], nil, label .. ": a deferred neighbour with objects gets no pool from the mod")
    eq(Ghosts._pools[EVENTS], nil, label .. ": nor one whose objects are in the scripting bundle")
    eq(avatars.spawned.full, nil, label .. ": its player waits for the engine's pool")
    eq(lidsOf("full"), 0, label .. ": with no object built and no localId held meanwhile")
    eq(avatars.spawnWarned, nil, label .. ": and nothing logged while waiting")
    local made = Ghosts._pools[BARE]
    local bare, bare2 = avatars.spawned.bare, avatars.spawned.bare2
    check(made ~= nil and bare ~= nil and bare2 ~= nil
      and made.byId[bare.lid] == bare.eo and made.byId[bare2.lid] == bare2.eo,
      label .. ": a neighbour with no objects still gets a made pool, deferred or not")
    avatars:sync(roster, here)                 -- the engine stops deferring
    local built, fromEvents = Ghosts._pools[FULL], Ghosts._pools[EVENTS]
    local full, events = avatars.spawned.full, avatars.spawned.events
    check(built ~= nil and full ~= nil and built.byId[full.lid] == full.eo,
      label .. ": once the engine builds the pool, the waiting player lands in it")
    check(built ~= nil and built.byId[1] ~= nil, label .. ": beside the map's own NPC")
    check(fromEvents ~= nil and events ~= nil and fromEvents.byId[events.lid] == events.eo
      and fromEvents.byId[1] ~= nil, label .. ": the bundle's map too, NPC and player")
    -- the made pool goes with its last avatar, not before
    roster:remove("bare2")
    avatars:sync(roster, here)
    eq(Ghosts._pools[BARE], made, label .. ": a made pool stays while an avatar stands in it")
    roster:move("bare", MAP, 4, 4, "down", false)
    avatars:sync(roster, here)
    eq(Ghosts._pools[BARE], nil, label .. ": and is dropped once its last avatar walks off")
    eq(Ghosts._pools[FULL], built, label .. ": the engine-built pools are left alone")
    roster:move("bare", BARE, 3, 4, "down", false)
    avatars:sync(roster, here)
    local remade = Ghosts._pools[BARE]
    check(remade ~= nil and remade ~= made, label .. ": a player back on the bare map gets a fresh one")
    local captured = { byId = {}, order = {} }
    Ghosts._pools[BARE] = captured
    roster:remove("bare")
    avatars:sync(roster, here)
    eq(Ghosts._pools[BARE], captured, label .. ": a made pool the engine replaced is not dropped with the avatar")
    Map.world, Map._worldRoot = savedWorld, savedRoot
    Space.bundle = savedBundle
    for _, id in ipairs({ "full", "events" }) do roster:remove(id) end
    for _, id in ipairs({ BARE, FULL, EVENTS }) do game.data.maps[id] = oldDefs[id] end
    avatars:clear()
    Ghosts.clear()
  end

  -- the local player's own pace, for presence
  P.biking, P.running, P.moving, P.stepFrames = false, false, false, 16
  eq(Avatars.localFast3(), false, label .. ": walking is not fast")
  P.running = true
  eq(Avatars.localFast3(), true, label .. ": running is fast")
  P.running, P.biking = false, true
  eq(Avatars.localFast3(), true, label .. ": a bike is fast")
  P.biking = false

  -- ------------------------------------------------ Overlay: the camera
  local cx, top = Overlay.screenOf3(80, 96, 80, 96, 32)
  eq(cx, 120, label .. ": the player's own sprite is centred on the frame")
  eq(top, 56, label .. ": its 32-pixel frame starts 16 above its cell (72 - 16)")
  cx, top = Overlay.screenOf3(80 + 16, 96 - 32, 80, 96, 32)
  eq(cx, 136, label .. ": one cell right is sixteen pixels right")
  eq(top, 24, label .. ": two cells up is thirty-two up")
  cx, top = Overlay.screenOf3(80 + 16, 96, 80, 96, 16)
  eq(top, 72, label .. ": a 16-pixel sprite starts on its own cell")
  cx, top = Overlay.screenOf3(80 + 16, 96 + 16, 80, 96, 32, 0, 0, 2)
  eq(cx, 152, label .. ": zoomed 2x, a cell is 32 frame pixels")
  eq(top, 64, label .. ": ...both ways (80 + (112 + 16 - 32 - 96 - 8) * 2)")
  cx, top = Overlay.screenOf3(80, 96, 80, 96, 32, 8, -16)
  eq(cx, 112, label .. ": a scripted pan moves the world the other way (x)")
  eq(top, 72, label .. ": ...and y")

  -- the whole draw, against a love that records what it prints
  local printed, restoreLove = stubLove()
  P.px, P.py, P.cellX, P.cellY, P.facing = 5 * 16, 8 * 16, 5, 8, "up"
  local worldCurrent = World.current
  World.current = function() return { mapId = MAP, x = 5, y = 8, facing = "up" } end
  roster:move("p1", MAP, 7, 8, "down", false)
  local drawAvatars = Avatars.new()
  Objects.loadMap(nil, MAP, mapDef)
  drawAvatars:sync(roster, here)
  local plateParty = {
    isPartner = function(_, id) return id == "p1" end,
    has = function() return true end,
    isSelf = function(_, id) return id == "me" end,
    list = function() return { { id = "me", name = "LEAF" }, { id = "p1", name = "ASH" } } end,
  }
  local overlay = Overlay.new({
    roster = roster, avatars = drawAvatars, party = plateParty,
    client = {
      isConnected = function() return true end,
      playerName = function() return "LEAF" end,
    },
  })
  local viewport = { gameX = 0, gameY = 0, scale = 4, width = 960, height = 640 }
  overlay:draw(game, viewport)
  local st = overlay:state()
  eq(st.reached, "labels", label .. ": plates drawn in free roam")
  eq(st.gen3, true, label .. ": through the Gen 3 arm")
  local plate, selfPlate
  for _, p in ipairs(printed) do
    if p.text == Overlay.PARTY_MARK .. "ASH" then plate = p end
    if p.text == "LEAF" then selfPlate = p end
  end
  check(plate ~= nil, label .. ": ASH's plate is printed (with the party mark)")
  check(selfPlate ~= nil, label .. ": and the player's own")
  if plate then
    -- the avatar two cells right of the player: centre 120 + 32 = 152, frame
    -- top 56 (no sheet to read an inset from headless), plate LABEL_GAP (2)
    -- above it, all at 4x
    local width = #plate.text * 6
    eq(plate.x, math.floor(152 * 4 - width / 2), label .. ": plate centred over the avatar")
    eq(plate.y, math.floor((56 - 2) * 4 - 10), label .. ": plate just over its head")
  end
  if selfPlate then
    eq(selfPlate.x, math.floor(120 * 4 - (#"LEAF" * 6) / 2), label .. ": own plate centred on the frame")
  end

  -- The partner's "!" rides the same head as their plate: the same camera,
  -- through the draw's projection for the mark.
  overlay.alert = { id = "p1", map = MAP, clock = 0, hold = 1 }
  local rects = {}
  local rectangle = love.graphics.rectangle
  love.graphics.rectangle = function(_, x, y, w, h) rects[#rects + 1] = { x = x, y = y, w = w, h = h } end
  overlay:draw(game, viewport)
  love.graphics.rectangle = rectangle
  eq(overlay:state().alert, "waiter", label .. ": the partner's mark is drawn")
  local body = rects[2]   -- after its shadow
  eq(body and (body.x + body.w / 2), 152 * 4, label .. ": ...centred over the partner's head, as the plate is")
  check(body and plate and body.y + body.h < plate.y, label .. ": ...and above the plate")
  overlay.alert = nil

  -- off the edge of the 240x160 frame: not drawn, not reported
  for i = #printed, 1, -1 do printed[i] = nil end
  roster:move("p1", MAP, 5 + 9, 8, "down", false)
  drawAvatars:sync(roster, here)
  Avatars.placeAt3(drawAvatars.spawned.p1.eo, 14, 8, "down")
  overlay:draw(game, viewport)
  local clipped = true
  for _, p in ipairs(printed) do
    if p.text:find("ASH", 1, true) then clipped = false end
  end
  check(clipped, label .. ": a plate that would cross the frame edge is not drawn")

  -- a menu over the field: nothing annotates the world
  local Stack = Gen3.stack()
  Stack.push("rby_mmo:Test", { draw = function() end })
  overlay:draw(game, viewport)
  eq(overlay:state().reached, "not-overworld", label .. ": a layer up hides the plates")
  Stack.pop("rby_mmo:Test")

  -- a perspective (TILT) world: the corner roster stands in for the plates.
  -- Read through Gen3.engine -- the sandbox's package.loaded is empty, so a
  -- package.loaded read never saw TILT on a live boot.
  local Tilt = Gen3.engine("src.render.Tilt")
  check(type(Tilt) == "table", label .. ": the Tilt module is reachable through Gen3.engine")
  if type(Tilt) == "table" then
    local active = Tilt.active
    Tilt.active = function() return true end
    overlay:draw(game, viewport)
    Tilt.active = active
    eq(overlay:state().reached, "roster", label .. ": under TILT the corner list stands in for the plates")
  end

  -- Region-map figures: grid placement, safe sprite mapping and real HUD
  -- drawing. Stand in only for ROM-derived geometry/art and open UI state.
  local RegionMap3 = need("RegionMap3")
  local ownMap = em and "EM_LITTLEROOT_TOWN" or "FR_PALLET_TOWN"
  local otherMap = em and "FR_VIRIDIAN_CITY" or "EM_LITTLEROOT_TOWN"
  local oldDef = game.data.maps[ownMap]
  game.data.maps[ownMap] = { regionMapSectionId = 0, mapType = 1, width = 40, height = 40 }
  local RM = Gen3.engine(em and "src.ui.game3.rse.region_map" or "src.ui.game3.region_map")
  local restoreMap
  local page = 0
  if em then
    local Sections = Gen3.engine("src.ui.game3.rse.mapsec")
    local oldEntry, oldManifest, oldActive = Sections.entry, RM.manifest, RM.active
    Sections.entry = function(id)
      if id == 0 then return { x = 4, y = 6, width = 2, height = 2 } end
    end
    RM.manifest = function() return { offMap = {99}, mapsecs = {} } end
    RM.active = function() return {} end
    restoreMap = function() Sections.entry, RM.manifest, RM.active = oldEntry, oldManifest, oldActive end
  else
    local Extract = Gen3.engine("src.import.gba.region_map_extract")
    local oldGeometry, oldLayouts, oldState = Extract.GEOMETRY, Extract.LAYOUTS, RM.state
    Extract.GEOMETRY = { dimensions = { [0] = {2, 2} }, topLeft = { [0] = {4, 8} } }
    Extract.LAYOUTS = { seviiMapsecs = { [0] = {}, {}, {} } }
    RM.state = function() return { selectedRegion = page } end
    restoreMap = function() Extract.GEOMETRY, Extract.LAYOUTS, RM.state = oldGeometry, oldLayouts, oldState end
  end
  local oldPortrait = Chars.portrait
  local art = { image = {}, quad = {}, w = 16, h = 32 }
  Chars.portrait = function() return art end
  local drawCalls, oldDraw = {}, love.graphics.draw
  love.graphics.draw = function(...) drawCalls[#drawCalls + 1] = {...} end
  roster:move("p1", ownMap, 25, 3, "down", false)
  local layer = em and "rse_region_map" or "region_map"
  Stack.push(layer, { draw = function() end })
  eq(overlay:regionMapState3(), em and "rse" or "frlg", label .. ": the region map is recognised")
  local marks = overlay:regionMapMarks3(game)
  eq(#marks, 1, label .. ": one partner marked, never yourself")
  eq(marks[1] and marks[1].x, em and 52 or 76, label .. ": route position uses scaled map width")
  eq(marks[1] and marks[1].y, em and 68 or 100, label .. ": section y on the cart's grid")
  for i = #printed, 1, -1 do printed[i] = nil end
  overlay:draw(game, viewport)
  eq(overlay:state().reached, "regionmap", label .. ": figures drawn on the region map")
  eq(overlay:state().drawn, 1, label .. ": one character drawn")
  eq(drawCalls[1] and drawCalls[1][1], art.image, label .. ": uses character art")
  eq(drawCalls[1] and drawCalls[1][6], 2, label .. ": 32-pixel figure fitted to 16 map pixels at 4x")
  local named = false
  for _, line in ipairs(printed) do if line.text == "ASH" then named = true end end
  check(named, label .. ": nameplate over the figure")
  local savedList = plateParty.list
  plateParty.list = function() return { {id = "me"}, {id = "p1", name = "ASH"}, {id = "p2", name = "MAY"} } end
  roster:put({ id = "p2", name = "MAY", map = ownMap, x = 25, y = 3,
    sprite = mySprite, version = version })
  marks = overlay:regionMapMarks3(game)
  eq(#marks, 2, label .. ": both partners get a figure")
  eq(marks[2].x - marks[1].x, 10, label .. ": partners in the same town stand side by side")
  eq(marks[1].y, marks[2].y, label .. ": co-located figures share their town row")
  roster:remove("p2")
  eq(#overlay:regionMapMarks3(game), 1, label .. ": missing roster member is omitted")
  plateParty.list = savedList
  game.data.maps[ownMap].mapType = 8
  marks = overlay:regionMapMarks3(game)
  eq(marks[1] and marks[1].x, em and 44 or 68, label .. ": indoor member placed in its named town section")
  game.data.maps[ownMap].mapType = 1
  roster:move("p1", otherMap, 3, 3, "down", false)
  eq(#overlay:regionMapMarks3(game), 0, label .. ": other region has no figure on this map")
  roster:move("p1", ownMap, 25, 3, "down", false)
  game.data.maps[ownMap].regionMapSectionId = 99
  eq(#overlay:regionMapMarks3(game), 0, label .. ": unknown/off-map section has no marker")
  game.data.maps[ownMap].regionMapSectionId = 0
  if not em then
    page = 1
    eq(#overlay:regionMapMarks3(game), 0, label .. ": Kanto partner hidden on a Sevii page")
    local Extract = Gen3.engine("src.import.gba.region_map_extract")
    local Sections = Gen3.engine("src.import.gba.map_sections_extract")
    local island = Sections.ID_TO_SECTION.MAPSEC_ONE_ISLAND
    local oldIslandDef = game.data.maps.FR_ONE_ISLAND
    game.data.maps.FR_ONE_ISLAND = { regionMapSectionId = island, mapType = 1, width = 40, height = 40 }
    Extract.GEOMETRY.dimensions[island], Extract.GEOMETRY.topLeft[island] = {2, 2}, {4, 8}
    Extract.LAYOUTS.seviiMapsecs[0] = { island }
    roster:move("p1", "FR_ONE_ISLAND", 25, 3, "down", false)
    eq(#overlay:regionMapMarks3(game), 1, label .. ": partner on the selected Sevii page is marked")
    page = 0
    eq(#overlay:regionMapMarks3(game), 0, label .. ": Sevii partner hidden on the Kanto page")
    roster:move("p1", ownMap, 25, 3, "down", false)
    game.data.maps.FR_ONE_ISLAND = oldIslandDef
  end
  Stack.pop(layer)

  -- PokéNav screen gating and zoom/scroll projection, including letterbox.
  if em then
    local Pokenav = require("src.ui.game3.rse.pokenav.init")
    local Host, savedShell = Pokenav.Host, Pokenav.Host._s
    local fading = false
    local screen = { visible = true, scale = 256, scrollX = 0, scrollY = 0, c = 0, d = 0 }
    local shell = { menuId = Pokenav.MENU.MAIN_MENU, phase = "menu", screen = screen,
      fadeActive = function() return fading end }
    Host._s = shell
    Stack.push(Pokenav.ID, { draw = function() end })
    eq(overlay:regionMapState3(), nil, label .. ": PokéNav main menu has no markers")
    shell.menuId = Pokenav.MENU.MATCH_CALL
    eq(overlay:regionMapState3(), nil, label .. ": MATCH CALL has no markers")
    shell.menuId = Pokenav.MENU.REGION_MAP
    eq(overlay:regionMapState3(), "pokenav", label .. ": HOENN MAP recognised")
    fading = true
    eq(overlay:regionMapState3(), nil, label .. ": markers hidden during fade")
    fading = false
    screen.visible = false
    eq(overlay:regionMapState3(), nil, label .. ": closed map has no markers")
    screen.visible = true
    shell.phase = "shutdown"
    eq(overlay:regionMapState3(), nil, label .. ": shutting PokéNav has no markers")
    shell.phase = "menu"
    overlay:draw(game, viewport)
    eq(overlay:state().drawn, 1, label .. ": character drawn on PokéNav map")
    local full = overlay:regionMapMarks3(game)[1]
    eq(full and full.x, 52, label .. ": unzoomed PokéNav x")
    screen.scale, screen.c, screen.d = 128, 56, 72
    screen.zoomed, screen.scrollX, screen.scrollY = true, 4, -2
    local zoomed = overlay:regionMapMarks3(game)[1]
    eq(zoomed and zoomed.x, 40, label .. ": zoomed marker follows horizontal scroll")
    eq(zoomed and zoomed.y, 66, label .. ": zoomed marker follows vertical scroll")
    local before = #drawCalls
    overlay:draw(game, { gameX = 40, gameY = 50, scale = 3 })
    local draw = drawCalls[before + 1]
    eq(draw and draw[3], 40 + (40 - 4) * 3, label .. ": figure respects letterbox x")
    eq(draw and draw[4], 50 + (66 - 8) * 3, label .. ": figure respects letterbox y")
    screen.scrollX = 100
    eq(#overlay:regionMapMarks3(game), 0, label .. ": scrolled-off marker hidden")
    screen.zoomDisabled = true
    eq(#overlay:regionMapMarks3(game), 0, label .. ": off-map PokéNav screen has no figures")
    shell.menuId = Pokenav.MENU.MAIN_MENU
    overlay:draw(game, viewport)
    eq(overlay:state().reached, "not-overworld", label .. ": returning to menu removes markers")
    Stack.pop(Pokenav.ID)
    Host._s = savedShell
  end
  Chars.portrait, love.graphics.draw = oldPortrait, oldDraw
  game.data.maps[ownMap] = oldDef
  restoreMap()

  World.current = worldCurrent
  restoreLove()

  Objects.reset()
  run.loader.game = nil
  run.release()
end

cart("firered")
cart("emerald")
GameVersion.set("red")

-- ------------------------------------------------------------------ Gen 1 / 2
-- The same modules on a Gen 1 and a Gen 2 boot: none of the Gen 3 arms runs,
-- and none of them requires a game3 module (the loader would throw there).
for _, gen in ipairs({ 1, 2 }) do
  local opts = { generation = gen }
  if MOD_PATH ~= "mods/rby_mmo" then opts.fs = makeRemapFs(T, MOD_PATH) end
  local run = T.sdk.loadMod("mods/rby_mmo", opts)
  eq(run.mod and run.mod.state, "loaded", "gen " .. gen .. ": loads")
  eq(#run.errors, 0, "gen " .. gen .. ": loads clean")
  local chain = run.loader.hooks.chains["world.talk"]
  check(chain == nil or #chain == 0, "gen " .. gen .. ": no world.talk link off Gen 3")
  local seen = {}
  local inner = _G.require
  _G.require = function(name, ...)
    if type(name) == "string" and name:find("%.game3%.") then seen[#seen + 1] = name end
    return inner(name, ...)
  end
  local need = resolver(run)
  local Avatars, Chars, Places, Overlay = need("Avatars"), need("Chars"), need("Places"), need("Overlay")
  local av = Avatars.new()
  eq(av.lids ~= nil, true, "gen " .. gen .. ": an Avatars instance")
  eq(Places.name(nil, "FR_VIRIDIAN_CITY"), "FR VIRIDIAN CITY", "gen " .. gen .. ": no Gen 3 naming off Gen 3")
  eq(Chars.label("SPRITE_RED"), "RED", "gen " .. gen .. ": labels as before")
  local cx = Overlay.screenOf(64, 64, 64, 64)
  eq(cx, Overlay.CAM_X + 8, "gen " .. gen .. ": the Game Boy camera is untouched")
  _G.require = inner
  eq(#seen, 0, "gen " .. gen .. ": no game3 module required")
  for _, n in ipairs(seen) do print("  required: " .. n) end
  run.release()
end

print(("%d/%d checks passed  (gen3_presence)"):format(passed, passed + failed))
os.exit(failed == 0 and 0 or 1)
