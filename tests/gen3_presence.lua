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

  -- a step, walked by the engine
  roster:move("p1", MAP, 5, 6, "right", false)
  avatars:sync(roster, here)
  eq(eo.moving, true, label .. ": a move starts a step")
  eq(eo.targetX, 5, label .. ": toward the new cell")
  eq(eo.facing, "right", label .. ": facing the way it walks")
  eq(eo.stepFrames, Avatars.GEN3_WALK_FRAMES, label .. ": at walking pace")
  eq(avatars:isWalking("p1"), true, label .. ": isWalking while it does")
  eq(Objects._tracks[base], nil, label .. ": with no movement track (nothing for a seamless edge to carry)")
  local sawPhase = false
  for _ = 1, 8 do Objects.update(game) end
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

  -- the region map: the party list, in words, whatever the family
  roster:move("p1", em and "FR_VIRIDIAN_CITY" or "EM_LITTLEROOT_TOWN", 3, 3, "down", false)
  Stack.push(em and "rse_region_map" or "region_map", { draw = function() end })
  eq(overlay:regionMapState3(), em and "rse" or "frlg", label .. ": the region map is recognised")
  local marks = overlay:regionMapMarks3(game)
  eq(#marks, 1, label .. ": one partner listed (never yourself)")
  eq(marks[1] and marks[1].place, em and "VIRIDIAN CITY" or "LITTLEROOT TOWN",
     label .. ": the other region's place, named in words")
  eq(marks[1] and marks[1].region, em and "kanto" or "hoenn", label .. ": and its region")
  for i = #printed, 1, -1 do printed[i] = nil end
  overlay:draw(game, viewport)
  eq(overlay:state().reached, "regionmap", label .. ": the party list is drawn over the region map")
  local listed = false
  for _, p in ipairs(printed) do
    if p.text == (em and "VIRIDIAN CITY" or "LITTLEROOT TOWN") then listed = true end
  end
  check(listed, label .. ": with the partner's place on it")
  Stack.pop(em and "rse_region_map" or "region_map")

  -- where the list stands, per layout (window pixels at 4x, rect at 0,0)
  local fx, fy = Overlay.regionPanel3("frlg", 100, 60, 4, 0, 0)
  eq(fx + 100, 194 * 4, label .. ": FRLG: the plate's right edge stops short of the region button")
  eq(fy + 60, (160 - 4) * 4, label .. ": FRLG: ...a margin above the bottom")
  local rx, ry = Overlay.regionPanel3("rse", 100, 60, 4, 0, 0)
  eq(rx, 4 * 4, label .. ": Emerald wall map: bottom-left")
  eq(ry + 60, (160 - 4) * 4, label .. ": Emerald wall map: ...a margin above the bottom")
  local px, py = Overlay.regionPanel3("pokenav", 100, 60, 4, 0, 0)
  eq(Overlay.POKENAV_HELP_TOP, 144, label .. ": the PokéNav help bar's top (22 tiles less the 32px header)")
  eq(px, rx, label .. ": PokéNav: the plate keeps the wall map's column (same picture under it)")
  eq(py + 60, (144 - 4) * 4, label .. ": PokéNav: ...its foot a margin above the help bar, not over it")
  check(px + 100 <= 136 * 4, label .. ": PokéNav: ...clear of the place-name box at tile 17")
  local ox, oy = Overlay.regionPanel3("pokenav", 100, 60, 3, 40, 50)
  eq(ox, 40 + 4 * 3, label .. ": PokéNav: placed inside the letterboxed rect (x)")
  eq(oy, 50 + (144 - 4) * 3 - 60, label .. ": PokéNav: ...and (y)")

  -- The PokéNav's HOENN MAP (Emerald): the whole PokéNav is one layer, so
  -- only its map screen counts, and only once the map is up and faded in.
  if em then
    local Pokenav = require("src.ui.game3.rse.pokenav.init")
    local Host = Pokenav.Host
    local savedShell = Host._s
    local fading = false
    local shell = {
      menuId = Pokenav.MENU.MAIN_MENU, phase = "menu", screen = { visible = true },
      fadeActive = function() return fading end,
    }
    Host._s = shell
    Stack.push(Pokenav.ID, { draw = function() end })
    eq(Pokenav.ID, "rse_pokenav", label .. ": the PokéNav's layer is rse_pokenav")
    eq(overlay:regionMapState3(), nil, label .. ": the PokéNav's main menu is not a map")
    shell.menuId = Pokenav.MENU.MATCH_CALL
    eq(overlay:regionMapState3(), nil, label .. ": ...nor is MATCH CALL")
    shell.menuId = Pokenav.MENU.REGION_MAP
    eq(overlay:regionMapState3(), "pokenav", label .. ": the HOENN MAP is recognised")
    fading = true
    eq(overlay:regionMapState3(), nil, label .. ": ...not while it is fading in or out")
    fading = false
    shell.screen.visible = false
    eq(overlay:regionMapState3(), nil, label .. ": ...not once the map has been taken down")
    shell.screen.visible = true
    shell.phase = "shutdown"
    eq(overlay:regionMapState3(), nil, label .. ": ...nor while the PokéNav shuts")
    shell.phase = "menu"
    for i = #printed, 1, -1 do printed[i] = nil end
    overlay:draw(game, viewport)
    local navState = overlay:state()
    eq(navState.reached, "regionmap", label .. ": the party list is drawn over the PokéNav's map")
    eq(navState.panel and navState.panel.layout, "pokenav", label .. ": ...in the PokéNav's corner")
    eq(navState.panel and navState.panel.x, 4 * 4, label .. ": ...in the wall map's column")
    check(navState.panel and navState.panel.y + navState.panel.h <= (Overlay.POKENAV_HELP_TOP - 4) * 4,
          label .. ": ...and above the help bar")
    local onNav = false
    for _, p in ipairs(printed) do
      if p.text == "VIRIDIAN CITY" then onNav = true end
    end
    check(onNav, label .. ": with the partner's place on it")
    shell.menuId = Pokenav.MENU.MAIN_MENU
    overlay:draw(game, viewport)
    eq(overlay:state().reached, "not-overworld", label .. ": back on the PokéNav's menu, no list")
    Stack.pop(Pokenav.ID)
    Host._s = savedShell
  end

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
