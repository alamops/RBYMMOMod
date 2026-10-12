-- rby_mmo's battle screens on a Gen 3 boot: the 640x360 arena
-- (src/Battlefield.lua), the cart-chrome CLASSIC page (src/ClassicBattle.lua
-- drawGen3) and the particle catalogue's Gen 3 door (src/Vfx.lua forMove3 /
-- forItem3 / chargeStyle3).
--
-- Three parts:
--
--   A. The modules through a plain resolver over a stub `Gen3` (every art
--      source answers a fake image, the engine modules the arm reads answer
--      synthetic tables): the theatre gate, the art resolvers, the icon
--      quads, the whole-pixel pic rule, the Gen 3 human box and its clearance
--      of the roster chips, the classic page's geometry (every rect inside
--      240x160, no HUD rect overlapping another), the command labels, the PP
--      bands, the ball row, and Vfx coverage over a sample of Gen 3 moves plus
--      every (type, effect) pair a Gen 3 sheet can carry.
--   B. The same modules resolved through the real headless loader on a Gen 3
--      boot (FireRed, then Emerald), so a cross-generation require would throw
--      exactly as in game; the classic page and the arena draw against a
--      recording love.graphics with the engine's own (cache-less) chrome.
--   C. A Gen 1 load: the Gen 3 arm stays shut -- no src.*.game3.* module is
--      asked for, the Gen 1 layout numbers are the ones they always were.
--
-- No pixels and no ROM here: every number is synthetic. The live frames are
-- tests/drivers/{battlefield,classic_battle}_shot.lua's Gen 3 arms
-- (tests/drivers/run-battlefield-e2e-gen3.sh).
--
-- Run from the engine checkout root:
--   luajit mods/rby_mmo/tests/gen3_battlefield.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"
do
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("(.+)[/\\]")
    if dir then
      local fallback = dir:gsub("[/\\]tests$", "")
      local handle = io.open(fallback .. "/src/Battlefield.lua", "rb")
      if handle then
        handle:close()
        MOD_PATH = fallback
      end
    end
  end
end

-- ------- love.graphics, recorded (no pixels headless)

local drawn = {}
local graphics = setmetatable({}, { __index = function(_, key)
  return function(...) drawn[#drawn + 1] = { key, ... } end
end })
graphics.newQuad = function(x, y, w, h)
  return { getViewport = function() return x, y, w, h end }
end
graphics.getColor = function() return 1, 1, 1, 1 end
graphics.getScissor = function() return nil end
graphics.getBlendMode = function() return "alpha", "alphamultiply" end
graphics.getFont = function() return nil end
local previousLove = _G.love
_G.love = { graphics = graphics, timer = { getTime = function() return 0 end } }

-- A stand-in image: dimensions only.
local function fakeImage(tag, w, h)
  return { tag = tag, getDimensions = function() return w or 64, h or 64 end,
           setFilter = function() end }
end

-- ------- A. a stub Gen 3 under a plain resolver

local engineAsked = {}
local picCoordsStub = { elev = { [92] = 4 } }             -- synthetic
-- The map the player stands on, and the cart's terrain rules, stood in: the
-- arena asks exactly these to pick its backdrop (battle_bridge.lua's inputs).
local terrainAsked = {}
local mapStub = {
  current = "FR_ROUTE1",
  currentDef = function() return { kind = "route", mapType = 3, battleType = 0 } end,
}
local SHEETS = { [0] = "grass", [7] = "cave", [8] = "building", [11] = "gym" }
local bgStub = {
  resolveFromBehavior = function(behavior, kind, mapType)
    terrainAsked.behavior, terrainAsked.kind, terrainAsked.mapType = behavior, kind, mapType
    return 0
  end,
  resolveOverride = function(terrain, opts)
    terrainAsked.scene = opts and opts.mapBattleScene
    if opts and opts.mapBattleScene == 1 then return 11 end
    return terrain
  end,
  sheetKey = function(terrain) return SHEETS[terrain] end,
}
local stubModules = {
  ["src.core.game3.battle.pic_coords"] = picCoordsStub,
  ["src.core.game3.map"] = mapStub,
  ["src.core.game3.collision"] = { behavior = function() return 0x02 end },
  ["src.core.game3.player"] = { cellX = 5, cellY = 6, moving = false },
  ["src.core.game3.battle.bg"] = bgStub,
}
local Gen3Stub = { on = true }
function Gen3Stub.active() return Gen3Stub.on end
function Gen3Stub.engine(name)
  engineAsked[#engineAsked + 1] = name
  if not Gen3Stub.on then return nil end
  return stubModules[name]
end
function Gen3Stub.frontPic(subject, opts)
  if not Gen3Stub.on then return nil end
  local key = type(subject) == "table" and ("mon:" .. tostring(subject.species)) or tostring(subject)
  return { image = fakeImage("front:" .. key), w = 64, h = 64, opts = opts }
end
function Gen3Stub.backPic(subject)
  if not Gen3Stub.on then return nil end
  return { image = fakeImage("back:" .. tostring(subject)), w = 64, h = 64 }
end
function Gen3Stub.icon(subject)
  if not Gen3Stub.on then return nil end
  return { image = fakeImage("icon:" .. tostring(subject), 32, 64), w = 32, h = 32,
           frames = 2, quads = { [0] = "q0:" .. tostring(subject), [1] = "q1:" .. tostring(subject) } }
end
function Gen3Stub.trainerPic(id)
  if not Gen3Stub.on then return nil end
  return { image = fakeImage("trainer:" .. tostring(id)), w = 64, h = 64 }
end
function Gen3Stub.trainerBackPic() return nil end
function Gen3Stub.viewerGfxFor() return nil end
function Gen3Stub.gfxId() return nil end
function Gen3Stub.typeName(t)
  local names = { [0] = "NORMAL", [13] = "ELECTRIC" }
  return names[tonumber(t)]
end
function Gen3Stub.speciesName() return nil end
function Gen3Stub.version() return "firered" end

local stubMod = {
  id = "rby_mmo",
  path = MOD_PATH,
  log = { info = function() end, warn = function() end, error = function() end },
  options = { get = function() return nil end },
  save = { get = function() return nil end, set = function() end },
  assets = { path = function(_, rel) return MOD_PATH .. "/" .. rel end },
}

local function resolverFor(gen3)
  local loadstr = loadstring or load
  local cache = {}
  local function need(name)
    if name == "Gen3" then return gen3 end
    if cache[name] ~= nil then return cache[name] end
    local handle = assert(io.open(MOD_PATH .. "/src/" .. name .. ".lua", "rb"))
    local body = handle:read("*a")
    handle:close()
    local chunk = assert(loadstr(body, "@" .. name .. ".lua"))
    local value = chunk(need, stubMod)
    cache[name] = value == nil and true or value
    return cache[name]
  end
  return need
end

local need = resolverFor(Gen3Stub)
local Battlefield = need("Battlefield")
local ClassicBattle = need("ClassicBattle")
local Vfx = need("Vfx")

-- ---- walkers: a local human's own graphic, a peer's fenced look
-- An NPC trainer's walker is this cart's data and is drawn as named; a
-- peer-described human (it carries `version` / `gender`) only reaches a
-- graphic through Gen3.viewerGfxFor, so a wire name can never pick a raw cart
-- graphic such as a Cut tree.
do
  local asked = {}
  local savedGfx, savedViewer = Gen3Stub.gfxId, Gen3Stub.viewerGfxFor
  Gen3Stub.gfxId = function(name) asked[#asked + 1] = "raw:" .. tostring(name); return 41 end
  Gen3Stub.viewerGfxFor = function(name) asked[#asked + 1] = "viewer:" .. tostring(name); return 0 end
  local owSprite = { image = fakeImage("ow"), quads = { [0] = "q" } }
  stubModules["src.core.game3.ow_sprites"] = {
    get = function(gid) asked[#asked + 1] = "draw:" .. tostring(gid); return owSprite end,
  }
  Battlefield.walker3({ spriteId = "OBJ_EVENT_GFX_BUG_CATCHER" })
  eq(asked[1], "raw:OBJ_EVENT_GFX_BUG_CATCHER", "walker: an NPC's own graphic is drawn as named")
  eq(asked[2], "draw:41", "walker: ...straight from the cart's sheet")
  asked = {}
  Battlefield.walker3({ spriteId = "OBJ_EVENT_GFX_CUT_TREE", version = "firered", gender = 0 })
  eq(asked[1], "viewer:OBJ_EVENT_GFX_CUT_TREE", "walker: a peer's look goes through the fence")
  for _, entry in ipairs(asked) do
    check(not entry:find("^raw:"), "walker: a peer's name never picks a raw cart graphic", entry)
  end
  eq(asked[#asked], "draw:0", "walker: ...and draws what the fence answered")
  stubModules["src.core.game3.ow_sprites"] = nil
  Gen3Stub.gfxId, Gen3Stub.viewerGfxFor = savedGfx, savedViewer
end

-- ---- the theatre gate
check(Battlefield.onGen3(), "the stub boot reads as Gen 3")
check(Battlefield.enabled({ generation = 3 }), "the theatre gate is up on a Gen 3 boot")
check(Battlefield.enabled({ data = {} }), "...and still up on a Gen 1-shaped game")
Gen3Stub.on = false
check(not Battlefield.enabled({ generation = 3 }),
  "a table that only says generation 3, on a boot that is not one, keeps the refusal")
Gen3Stub.on = true

-- ---- the backdrop: the cart's terrain for this spot, a drop-in first
local mctx = Battlefield.gen3MapContext()
eq(mctx.mapId, "FR_ROUTE1", "the arena reads the map the player is on")
eq(mctx.behavior, 0x02, "...and the metatile behaviour underfoot")
eq(Battlefield.gen3TerrainKey(mctx), "grass", "tall grass on a route is the cart's grass sheet")
eq(terrainAsked.behavior, 0x02, "the terrain rule got the behaviour")
eq(terrainAsked.kind, "route", "...the map kind")
eq(terrainAsked.mapType, 3, "...the map type")
eq(terrainAsked.scene, 0, "...and the map's battle scene")
mapStub.currentDef = function() return { kind = "indoor", mapType = 8, battleType = 1 } end
eq(Battlefield.gen3TerrainKey(), "gym", "a gym map's battle scene wins (the cart's override)")
mapStub.currentDef = function() return { kind = "route", mapType = 3, battleType = 0 } end
eq(Battlefield.arenaKindGen3("grass"), "wild", "grass is a wild arena for the drop-ins")
eq(Battlefield.arenaKindGen3("cave"), "wild", "...so is a cave")
eq(Battlefield.arenaKindGen3("gym"), "gym", "the gym sheet is the gym drop-in")
eq(Battlefield.arenaKindGen3("lance"), "gym", "...and so is a League room")
eq(Battlefield.arenaKindGen3("building"), "indoor", "a building is the indoor drop-in")
eq(Battlefield.arenaKindGen3(nil, { def = { mapType = 8 } }), "indoor",
  "an indoor map with no sheet to go on is indoor")
-- the ladder: a player's drop-in for this kind of place beats the cart's own
-- background, which beats the authored PNG
local imagesAsked = {}
local serve = {}
graphics.newImage = function(path)
  imagesAsked[#imagesAsked + 1] = path
  for pattern, img in pairs(serve) do
    if tostring(path):find(pattern, 1, true) then return img end
  end
  error("no such file " .. tostring(path))
end
local custom = fakeImage("custom-wild", 640, 360)
serve["custom/wild"] = custom
Battlefield.reloadArena()
eq(Battlefield.load(stubMod), custom, "a custom wild.png is the arena on a Gen 3 grass map")
eq(Battlefield.gen3Platform(), nil, "...and a drop-in paints its own ground (no cart platform)")
serve = { ["outdoor_grass_arena"] = fakeImage("authored", 640, 360) }
Battlefield.reloadArena()
eq(Battlefield.load(stubMod) and Battlefield.load(stubMod).tag, "authored",
  "with no drop-in and no cart background, the authored arena stands in")
mapStub.current, mapStub.currentDef = nil, function() return nil end
Battlefield.reloadArena()
eq(Battlefield.load(stubMod), nil, "before the map is known nothing is locked in")
mapStub.current = "FR_ROUTE1"
mapStub.currentDef = function() return { kind = "route", mapType = 3, battleType = 0 } end
graphics.newImage = nil
Battlefield.reloadArena()

-- ---- the art a seat carries
local front = Battlefield.gen3Front(25)
eq(front and front.tag, "front:25", "gen3Front answers the engine's front pic image")
eq(Battlefield.gen3Front({ species = 7 }).tag, "front:mon:7", "...mon-aware for a mon table")
eq(Battlefield.gen3Back(25).tag, "back:25", "gen3Back answers the back pic image")
local icon = Battlefield.gen3Icon(25)
check(icon ~= nil and icon.frames == 2, "gen3Icon hands back the engine's two-frame icon record")
eq(Battlefield.gen3TrainerPic(12).tag, "trainer:12", "gen3TrainerPic answers the trainer's front pic")
eq(Battlefield.gen3Elevation(92), 4, "gen3Elevation reads the cart's float height")
eq(Battlefield.gen3Elevation(25), nil, "...and nothing for a species that stands on the ground")
Gen3Stub.on = false
eq(Battlefield.gen3Front(25), nil, "off a Gen 3 boot there is no Gen 3 art to hand out")
eq(Battlefield.gen3Elevation(92), nil, "...nor an elevation")
Gen3Stub.on = true

-- ---- a trainer's back pic by the cart's TRAINER_BACK_PIC_* index (a solo
-- double's partner, W1-UC): the engine's TrainerPic.back by number, or by the
-- battle profile's backPics key; synthetic indices
do
  local backAsked = {}
  stubModules["src.core.game3.trainer_pic"] = {
    back = function(i)
      backAsked[#backAsked + 1] = i
      if i == 99 then return nil end
      return { image = fakeImage("trainerback:" .. tostring(i), 64, 256), w = 64, h = 256, frames = 4 }
    end,
  }
  stubModules["src.core.game3.battle.profile"] = {
    get = function() return { backPics = { steven = 7, wally = 6 } } end,
  }
  local entry = Battlefield.gen3TrainerBackPic(7)
  eq(entry and entry.image and entry.image.tag, "trainerback:7", "gen3TrainerBackPic: by index, the engine's strip")
  eq(entry and entry.frames, 4, "gen3TrainerBackPic: ...the whole entry (its frames)")
  eq(Battlefield.gen3TrainerBackPic("steven") and Battlefield.gen3TrainerBackPic("steven").image.tag,
     "trainerback:7", "gen3TrainerBackPic: the profile's key names the same pic")
  eq(Battlefield.gen3TrainerBackPic("wally").image.tag, "trainerback:6", "gen3TrainerBackPic: ...any key")
  eq(Battlefield.gen3TrainerBackPic(1).image.tag, "trainerback:1", "gen3TrainerBackPic: the player's, by gender")
  eq(Battlefield.gen3TrainerBackPic("nobody"), nil, "gen3TrainerBackPic: an unknown key is nothing")
  eq(Battlefield.gen3TrainerBackPic(-1), nil, "gen3TrainerBackPic: a negative index is nothing")
  eq(Battlefield.gen3TrainerBackPic(99), nil, "gen3TrainerBackPic: a pic the cache lacks is nothing")
  eq(Battlefield.gen3TrainerBackPic(nil), nil, "gen3TrainerBackPic: no pic named is nothing")
  Gen3Stub.on = false
  local asked = #backAsked
  eq(Battlefield.gen3TrainerBackPic(7), nil, "gen3TrainerBackPic: off a Gen 3 boot, nothing")
  eq(#backAsked, asked, "gen3TrainerBackPic: ...and the engine is not asked")
  Gen3Stub.on = true
  stubModules["src.core.game3.trainer_pic"] = nil
  stubModules["src.core.game3.battle.profile"] = nil
end

-- ---- a plate's owner tag (a side with two trainers on it, W1-UC)
do
  local tagged = Battlefield.plateModel({ name = "MEW", hp = 5, maxHp = 10, owner = "LASS MIA" })
  eq(tagged.owner, "LASS MIA", "plate owner: the trainer's label rides the plate model")
  eq(Battlefield.plateModel({ name = "MEW", hp = 5, maxHp = 10 }).owner, nil,
     "plate owner: a seat with no owner has none (the plate as it was)")
  eq(Battlefield.plateModel({ name = "MEW", hp = 5, maxHp = 10, owner = "" }).owner, nil,
     "plate owner: an empty label is none")
  local long = Battlefield.plateModel({ name = "MEW", hp = 5, maxHp = 10,
                                        owner = "PKMN TRAINER ALEXANDRIA" }).owner
  eq(#long, Battlefield.PLATE_OWNER_CHARS, "plate owner: cut to PLATE_OWNER_CHARS glyphs")
  eq(long:sub(-1), ".", "plate owner: ...with the cut mark")
  local layout = Battlefield.layout({
    mode = "coop_npc",
    allySeats = { { index = 1, name = "A", hp = 5, maxHp = 9 },
                  { index = 2, name = "B", hp = 5, maxHp = 9, owner = "STEVEN" } },
    foeSeats = { { index = 3, name = "C", hp = 5, maxHp = 9, owner = "DUO" },
                 { index = 4, name = "D", hp = 5, maxHp = 9, owner = "MIA" } },
  })
  local owners = {}
  for _, plate in ipairs(layout.plates) do owners[#owners + 1] = tostring(plate.model.owner) end
  eq(table.concat(owners, ","), "nil,STEVEN,DUO,MIA", "plate owner: the layout carries each seat's owner onto its plate")
  -- drawn into the status row, never over the HP figures
  drawn = {}
  local drewOwner = false
  local okDraw = pcall(Battlefield.draw, { gen3 = true }, {
    mode = "coop_npc", frame = 0,
    allySeats = { { index = 1, name = "A", hp = 5, maxHp = 9 } },
    foeSeats = { { index = 3, name = "C", hp = 5, maxHp = 9, owner = "DUO" } },
  })
  for _, call in ipairs(drawn) do
    if call[1] == "print" and tostring(call[2]):find("DUO", 1, true) then drewOwner = true end
  end
  check(okDraw, "plate owner: a plated arena with an owner tag draws")
  check(drewOwner, "plate owner: ...and prints the trainer's label on the foe plate")
end

-- ---- icon frames: the cart's two-frame bob
local img0, q0, size = Battlefield.gen3IconFrame(icon, 0)
eq(img0, icon.image, "an icon frame draws the record's own sheet")
eq(q0, "q0:25", "frame 0 is the record's first quad")
eq(select(2, Battlefield.gen3IconFrame(icon, 1)), "q1:25", "frame 1 is its second")
eq(select(2, Battlefield.gen3IconFrame(icon, 2)), "q0:25", "frames wrap")
eq(size, 32, "a Gen 3 icon cell is 32px")
eq(Battlefield.gen3IconBob(0), 0, "the bob starts on frame 0")
eq(Battlefield.gen3IconBob(10), 1, "...flips after ten ticks")
eq(Battlefield.gen3IconBob(20), 0, "...and back")
local sheet = fakeImage("sheet", 32, 64)
local simg, sq, ssize = Battlefield.gen3IconFrame(sheet, 1)
eq(simg, sheet, "a bare 32x64 sheet is its own image")
check(sq ~= nil and select(2, sq:getViewport()) == 32, "...its frame 1 is the lower 32x32 cell")
eq(ssize, 32, "...32px square")

-- ---- whole pixels
local p = Battlefield.monDrawParams({ x = 100, y = 100 }, 64, 64, { integer = true })
eq(p.scale, 1, "a 64px Gen 3 pic in the 60px seat box draws at 1x, not 0.94")
local pi = Battlefield.monDrawParams({ x = 100, y = 100 }, 32, 64, { iconFrame = true, iconSize = 32 })
eq(pi.scale, 2, "a 32px Gen 3 icon draws at 2x")
eq(pi.w, 64, "...64px wide")
local p1 = Battlefield.monDrawParams({ x = 100, y = 100 }, 56, 56, {})
eq(p1.scale, 1, "the Gen 1 56px fit is untouched")
local pc = Battlefield.monDrawParams({ x = 100, y = 100, drawW = 81 }, 64, 64, { integer = true })
eq(pc.scale, 1, "the evolve-centre box keeps a Gen 3 pic at 1x")

-- ---- the Gen 3 field: humans, chips, bubbles
local function seat(name) return { name = name, hp = 10, maxHp = 20, front = fakeImage("f") } end
local ctx = {
  mode = "coop_npc",
  allyHumans = { { name = "A", spriteId = "OBJ_EVENT_GFX_RED_NORMAL", party = "oo" },
                 { name = "B", spriteId = "OBJ_EVENT_GFX_GREEN_NORMAL", party = "o" } },
  foeHumans = { { name = "C", party = "oox" }, { name = "D", trainerPic = 7, party = "ox" } },
  allySeats = { seat("a1"), seat("a2") }, foeSeats = { seat("f1"), seat("f2") },
  bubbles = { { side = "ally", humanIndex = 1, text = "hi" } },
}
local lay = Battlefield.layout(ctx)
eq(#lay.humans, 4, "four trainers placed")
for _, h in ipairs(lay.humans) do
  eq(h.drawW, Battlefield.HUMAN_DRAW_W3, "a Gen 3 trainer is 32 wide (16x32 at 2x)")
  eq(h.drawH, Battlefield.HUMAN_DRAW_H3, "...and 64 tall")
  check(h.y <= Battlefield.FIELD_BOTTOM and h.y - (h.side == "foe" and 64 or Battlefield.HUMAN_REACH3)
    >= Battlefield.FIELD_TOP, ("the %s trainer %d stands wholly on the field"):format(h.side, h.index))
  for _, chip in ipairs(lay.rosters) do
    local reach = h.side == "foe" and 64 or Battlefield.HUMAN_REACH3
    local fig = { x = h.x - h.drawW / 2, y = h.y - reach, w = h.drawW, h = reach }
    local hit = fig.x < chip.x + chip.w and chip.x < fig.x + fig.w
      and fig.y < chip.y + chip.h and chip.y < fig.y + fig.h
    check(not hit, ("the %s trainer %d clears the %s roster chip"):format(h.side, h.index, chip.side))
  end
end
local npc = nil
for _, h in ipairs(lay.humans) do if h.side == "foe" and h.index == 2 then npc = h end end
eq(npc and npc.trainerPic, 7, "an NPC's trainer pic id rides the layout to the renderer")
eq(lay.allySeats, nil, "(layout keeps its own shape)")
check(#lay.bubbles == 1 and lay.bubbles[1].y == lay.humans[1].y - Battlefield.HUMAN_DRAW_H3 + 8,
  "a Gen 3 bubble's tail sits over the figure's head, not on its face")
local mon = lay.mons[1]
local seatWithElev = Battlefield.layout({ allySeats = { { name = "g", hp = 1, maxHp = 2, elevation = 4 } } })
eq(seatWithElev.mons[1].elevation, 4, "a seat's elevation reaches the placed mon")
check(mon ~= nil, "mons placed")
local cardLay = Battlefield.layout({ allySeats = { seat("a") }, foeSeats = { seat("f"), seat("g") },
  showTarget = true, targets = { seat("f"), seat("g") }, targetIndex = 1 })
check(cardLay.card == nil or cardLay.card.h == Battlefield.CARD_H3,
  "a Gen 3 target card is the tall one (its pic at 1x)")

-- ---- weather over the field, and the Substitute doll
eq(Battlefield.weatherKey("RAIN"), "RAIN", "the referee's RAIN is rain")
eq(Battlefield.weatherKey("rain"), "RAIN", "...so is a lower-case rain")
eq(Battlefield.weatherKey("sandstorm"), "SAND", "a sandstorm is SAND")
eq(Battlefield.weatherKey("SUNNY"), "SUN", "sunny is SUN")
eq(Battlefield.weatherKey("hail"), "HAIL", "hail is HAIL")
eq(Battlefield.weatherKey(nil), nil, "a clear sky is nil")
eq(Battlefield.weatherKey(false), nil, "...and so is false (the row that ended it)")
eq(Battlefield.layout({ weather = "rain" }).weather, "RAIN", "the layout carries the sky it was handed")
eq(Battlefield.layout({}).weather, nil, "...and none when there is none")
-- every sky paints inside its rect and nowhere else (no scissor: the arena
-- is drawn under a scale transform)
for _, sky in ipairs({ "RAIN", "SUN", "SAND", "HAIL" }) do
  for _, rectSpec in ipairs({ { 0, 0, 640, 280, 1 }, { 0, 0, 240, 112, 0.5 } }) do
    drawn = {}
    local rx, ry, rw, rh, unit = rectSpec[1], rectSpec[2], rectSpec[3], rectSpec[4], rectSpec[5]
    local painted = Battlefield.drawWeather(sky, rx, ry, rw, rh, 137, unit)
    check(painted, ("%s paints on a %dx%d field"):format(sky, rw, rh))
    local prims, outside = 0, 0
    for _, call in ipairs(drawn) do
      if call[1] == "rectangle" then
        prims = prims + 1
        local x, y, w, h = call[3], call[4], call[5], call[6]
        if x < rx - 0.5 or y < ry - 0.5 or x + w > rx + rw + 0.5 or y + h > ry + rh + 0.5 then
          outside = outside + 1
        end
      elseif call[1] == "polygon" and sky == "RAIN" then
        prims = prims + 1
        for k = 3, #call, 2 do
          if call[k] < rx - 0.5 or call[k] > rx + rw + 0.5
             or call[k + 1] < ry - 0.5 or call[k + 1] > ry + rh + 0.5 then
            outside = outside + 1
            break
          end
        end
      elseif call[1] == "circle" or call[1] == "polygon" then
        prims = prims + 1
      end
    end
    check(prims > 3, ("%s puts particles on the %dx%d field"):format(sky, rw, rh), prims)
    eq(outside, 0, ("%s stays inside its %dx%d rect"):format(sky, rw, rh))
  end
end
eq(Battlefield.drawWeather("FOG", 0, 0, 10, 10, 0, 1), false, "an unknown sky paints nothing")
local subLay = Battlefield.layout({ allySeats = { { name = "s", hp = 1, maxHp = 2, substitute = true } } })
eq(subLay.mons[1].substitute, true, "a seat's Substitute reaches the placed mon")
eq(Battlefield.gen3SubstituteDoll(false), nil, "no doll art without the cart's animation pack")
drawn = {}
Battlefield.drawDollStandIn(graphics, 100, 100, 40, 1, false)
local dollPrims = 0
for _, call in ipairs(drawn) do
  if call[1] == "ellipse" or call[1] == "circle" or call[1] == "polygon" then dollPrims = dollPrims + 1 end
end
check(dollPrims >= 6, "the plush stand-in doll is drawn from primitives", dollPrims)
local aliasLay = Battlefield.layout({ foeSeats = { seat("f") }, foeHumans = { { name = "N", picId = 9 } },
  mode = "1v1" })
eq(aliasLay.humans[1].trainerPic, 9, "an NPC's pic may arrive as picId")
local shown = ClassicBattle.gen3Printable("[G]BOB {x}")
check(not shown:find("[%[%]{}]"), "classic text meets the cart's charset (no brackets / braces)", shown)

-- ---- the classic page: geometry
local G = ClassicBattle.G3
eq(G.W, 240, "the classic Gen 3 page is 240 wide")
eq(G.H, 160, "...and 160 tall")
local function inside(r) return r.x >= 0 and r.y >= 0 and r.x + r.w <= G.W and r.y + r.h <= G.H end
local function overlaps(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end
local function strips(n)
  local seats = {}
  for i = 1, n do seats[i] = { icon = icon } end
  return { seats = seats, focus = 1 }
end
local shapes = {
  { name = "1v1", view = { foe = {}, ally = {}, foeParty = "oox" } },
  { name = "1v1 wild", view = { foe = {}, ally = {}, foeParty = "o", mode = "wild" } },
  { name = "2v2", view = { foe = {}, ally = {}, foeParty = "oo", foeStrip = strips(2), allyStrip = strips(2) } },
  { name = "3v3", view = { foe = {}, ally = {}, foeParty = "ooo", foeStrip = strips(3), allyStrip = strips(3) } },
  { name = "2v1", view = { foe = {}, ally = {}, foeStrip = strips(1), allyStrip = strips(2) } },
}
for _, shape in ipairs(shapes) do
  local L = ClassicBattle.gen3Layout(shape.view)
  local hud = { { "panel", L.panel } }
  if L.foeBox then hud[#hud + 1] = { "foeBox", L.foeBox } end
  if L.allyBox then hud[#hud + 1] = { "allyBox", L.allyBox } end
  if L.foeBalls then hud[#hud + 1] = { "foeBalls", L.foeBalls } end
  for i, c in ipairs(L.foeStrip) do hud[#hud + 1] = { "foeStrip" .. i, c } end
  for i, c in ipairs(L.allyStrip) do hud[#hud + 1] = { "allyStrip" .. i, c } end
  local all = { unpack(hud) }
  if L.foePic then all[#all + 1] = { "foePic", L.foePic } end
  if L.allyPic then all[#all + 1] = { "allyPic", L.allyPic } end
  for _, entry in ipairs(all) do
    check(inside(entry[2]), ("%s: %s lies inside 240x160"):format(shape.name, entry[1]))
  end
  for i = 1, #hud do
    for j = i + 1, #hud do
      check(not overlaps(hud[i][2], hud[j][2]),
        ("%s: %s and %s do not overlap"):format(shape.name, hud[i][1], hud[j][1]))
    end
  end
  -- the pics never sit under a healthbox or a rail (the cart's own rule; the
  -- textbox does cover the back pic's feet, which is why allyPic stops at it)
  for _, picKey in ipairs({ "foePic", "allyPic" }) do
    local pic = L[picKey]
    if pic then
      for _, entry in ipairs(hud) do
        local key = entry[1]
        if key ~= "panel" and key ~= "foeBalls" then
          check(not overlaps(pic, entry[2]),
            ("%s: the %s does not sit under %s"):format(shape.name, picKey, key))
        end
      end
    end
  end
  eq(L.foeBalls ~= nil, shape.view.foeParty ~= nil and shape.view.mode ~= "wild",
    shape.name .. ": the foe's ball row is up exactly when a non-wild foe has a party")
end
local L3 = ClassicBattle.gen3Layout({ foe = {}, ally = {}, foeStrip = strips(3), allyStrip = strips(3) })
for i = 2, 3 do
  eq(L3.foeStrip[i].y - L3.foeStrip[i - 1].y, L3.foeStrip[1].h, "3v3: the foe rail's cells are contiguous")
end
check(L3.allyStrip[3].y + L3.allyStrip[3].h <= G.PANEL_Y, "3v3: the ally rail ends above the textbox")
local Lw = ClassicBattle.gen3Layout({ foe = {}, ally = {}, list = { rows = { { label = "POTION" } } } })
check(Lw.list ~= nil and inside(Lw.list), "a bag / target list is a window inside the page")
check(not overlaps(Lw.list, Lw.panel), "...above the textbox, which carries its question")
local Lp = ClassicBattle.gen3Layout({ foe = {}, ally = {}, list = { rows = { { label = "PIKA", front = front } } } })
eq(Lp.list, nil, "a POKeMON list is the whole page, not a window")
check(ClassicBattle.gen3IsPartyList({ rows = { { label = "x", icon = icon } } }), "an icon row makes a party list")

-- ---- the classic page: words, PP, balls
eq(ClassicBattle.gen3CommandLabel("FIGHT"), "FIGHT", "FIGHT keeps its word")
eq(ClassicBattle.gen3CommandLabel("SWITCH"), "POKéMON", "SWITCH is the cart's POKéMON")
eq(ClassicBattle.gen3CommandLabel("PKMN"), "POKéMON", "...and so is PKMN")
eq(ClassicBattle.gen3CommandLabel("ITEM"), "BAG", "ITEM is the cart's BAG")
eq(ClassicBattle.gen3CommandLabel("CATCH"), "CATCH", "an unknown command keeps its own label")
eq(ClassicBattle.gen3PpState(20, 20), 3, "full PP is the plain colour band")
eq(ClassicBattle.gen3PpState(0, 20), 2, "empty PP is the red band")
eq(ClassicBattle.gen3PpState(5, 20), 1, "a quarter left is the orange band")
eq(ClassicBattle.gen3PpState(8, 20), 0, "under half is the yellow band")
eq(ClassicBattle.gen3PpState(1, 5), 1, "a 5-PP move with 1 left is the orange band")
local kinds = ClassicBattle.gen3BallKinds("oosx")
eq(table.concat(kinds, ","), "ok,ok,status,faint,empty,empty",
  "a referee roster reads as the cart's party-summary balls, empties to six")
eq(table.concat(ClassicBattle.gen3BallKinds({ { hp = 0 }, { hp = 5, status = "PSN" }, { hp = 5 } }), ","),
  "faint,status,ok,empty,empty,empty", "...and so does a list of mons")
eq(ClassicBattle.drawGen3({ foe = {}, ally = {} }), false,
  "with no cart chrome reachable the page says so (the screen draws its plain page)")

-- ---- Vfx: every Gen 3 move resolves to a drawable look
local function valid(spec)
  return type(spec) == "table" and Vfx.STYLES[spec.style] ~= nil
    and Vfx.PALETTES[spec.palette] ~= nil and Vfx.DELIVERIES[spec.delivery] == true
    and type(spec.scale) == "number" and type(spec.intensity) == "number"
end
-- synthetic rows in the C4 shape (type, power, effect, target)
local SAMPLE = {
  { "THUNDERBOLT", 13, 95, 6, 0, "beam", "ELECTRIC" },
  { "SURF", 11, 95, 0, 32, "field", "WATER" },
  { "CALM_MIND", 14, 0, 211, 16, "self", "PSYCHIC" },
  { "DRAGON_DANCE", 16, 0, 212, 16, "self", "DRAGON" },
  { "WILL-O-WISP", 10, 0, 167, 0, "projectile", "GHOST" },
  { "HEAT_WAVE", 10, 100, 4, 8, "field", "FIRE" },
  { "AERIAL_ACE", 2, 60, 17, 0, nil, "FLYING" },
  { "SHADOW_BALL", 7, 80, 72, 0, "projectile", "GHOST" },
  { "BLAZE_KICK", 10, 85, 200, 0, nil, "FIRE" },
  { "LEAF_BLADE", 12, 70, 43, 0, nil, "GRASS" },
  { "PSYCHO_BOOST", 14, 140, 204, 0, "beam", "PSYCHIC" },
  { "DOOM_DESIRE", 8, 120, 148, 0, "self", "STEEL" },
  { "HAIL", 15, 0, 164, 16, "field", "ICE" },
  { "WEATHER_BALL", 0, 50, 203, 0, "projectile", "NORMAL" },
  { "FAKE_OUT", 0, 40, 158, 0, nil, "NORMAL" },
  { "CURSE", 9, 0, 109, 16, "self", "GHOST" },
  { "TAIL_GLOW", 6, 0, 53, 16, "self", "BUG" },
  { "ROCK_TOMB", 5, 50, 70, 0, "projectile", nil },
  { "SPORE", 12, 0, 1, 0, "projectile", "GRASS" },
  { "SCREECH", 0, 0, 59, 0, "projectile", "STEEL" },
  { "SWORDS_DANCE", 0, 0, 50, 16, "self", "BUFF" },
  { "SOLAR_BEAM", 12, 120, 151, 0, "beam", "GRASS" },
  { "SELF_DESTRUCT", 0, 200, 7, 32, "self", "FIRE" },
  { "MUDDY_WATER", 11, 95, 73, 8, "field", "GROUND" },
  { "ZZZ_NOT_A_MOVE", 9, 0, 999, 0, nil, nil },
}
for _, row in ipairs(SAMPLE) do
  local spec = Vfx.forMove3(row[1], { type = row[2], power = row[3], effect = row[4], target = row[5] })
  check(valid(spec), row[1] .. ": resolves to a drawable Gen 3 look")
  if row[6] then eq(spec.delivery, row[6], row[1] .. ": delivered as " .. row[6]) end
  if row[7] then eq(spec.palette, row[7], row[1] .. ": in " .. row[7] .. "'s colours") end
end
eq(Vfx.forMove3("ZZ_DROP", { type = 0, power = 0, effect = 18, target = 8 }).style, "debuff",
  "an unnamed stat drop is the falling-arrow gesture")
eq(Vfx.forMove3("GROWL", { type = 0, power = 0, effect = 18, target = 8 }).style, "note",
  "...while a move the catalogue names keeps its own look (Growl's notes)")
eq(Vfx.forMove3("X", { type = 17, power = 60, effect = 0 }).palette, "DARK",
  "a pret type number is read as its type (17 = DARK)")
eq(Vfx.forMove3("X", { type = 9, power = 60 }).palette, "NORMAL",
  "MYSTERY (???) falls back to the neutral colours")
eq(Vfx.forMove3("X", { type = 13, power = 0 }, "FIRE").palette, "FIRE",
  "a type name the caller resolved wins over the row's number")
-- every (type, effect, target) a Gen 3 sheet can carry: never nil, never blank
local total, bad = 0, 0
for t = 0, 17 do
  for effect = 0, 213 do
    for _, target in ipairs({ 0, 8, 16, 32, 64 }) do
      for _, power in ipairs({ 0, 40, 120 }) do
        total = total + 1
        if not valid(Vfx.forMove3("MOVE_" .. effect, { type = t, power = power,
                                                       effect = effect, target = target })) then
          bad = bad + 1
        end
      end
    end
  end
end
eq(bad, 0, ("all %d (type, effect, target, power) rows resolve to a drawable look"):format(total))
check(Vfx.chargeStyle3("DIVE") ~= nil and Vfx.chargeStyle3("BOUNCE") ~= nil,
  "Dive and Bounce have a charge-turn look")
eq(Vfx.chargeStyle3("SOLAR_BEAM").style, "shine", "a pret spelling finds the classic charge row")
eq(Vfx.chargeStyle3("TACKLE"), nil, "a one-turn move has no charge look")
eq(Vfx.forItem3("POKé BALL"), nil, "a ball has no bag look (the throw is its own flow)")
eq(Vfx.forItem3("PARLYZ HEAL").style, "cure", "the cart's PARLYZ HEAL cures")
eq(Vfx.forItem3("SITRUS BERRY").style, "heal", "a Sitrus Berry heals")
eq(Vfx.forItem3("GUARD SPEC.").style, "shine", "GUARD SPEC. (with its dot) is found")
eq(Vfx.itemKey3("POKé DOLL"), "POKE_DOLL", "item names fold to keys")
eq(Vfx.forItem3("BIKE"), nil, "an item with no battle use plays nothing")
-- the Gen 1 / Gen 2 door is untouched by the Gen 3 tables
eq(Vfx.forItem("MOOMOO_MILK"), nil, "Gold's MOOMOO_MILK still has no look through forItem")
check(Vfx.forMove("CALM_MIND", { type = "PSYCHIC_TYPE", power = 0 }).delivery ~= "self",
  "forMove never reads the Gen 3 override table")
eq(Vfx.forMove("THUNDERBOLT", { type = "ELECTRIC", power = 95 }).delivery, "beam",
  "the Gen 1 Thunderbolt is still a beam")

-- ---- Vfx: Gen 3's general clips (W2-UC2; pret gBattleAnims_General, the
--      General_* scripts of data/battle_anim_scripts.s)
local GENERAL3 = { "MON_SCARED", "GHOST_GET_OUT", "SILPH_SCOPED", "BAIT_THROW", "ROCK_THROW",
                   "POKEBLOCK_THROW", "SAFARI_REACTION",
                   -- W3-UC3: the ones every fight can send
                   "TURN_TRAP", "FOCUS_PUNCH_SETUP", "FUTURE_SIGHT_HIT", "DOOM_DESIRE_HIT" }
for _, name in ipairs(GENERAL3) do
  local beats = Vfx.forGeneral3(name, 0)
  check(type(beats) == "table" and #beats > 0, "general: " .. name .. " has a look")
  for i, beat in ipairs(beats or {}) do
    local tag = ("general: %s beat %d"):format(name, i)
    check(Vfx.GENERAL_ROLES3[beat.on] == true, tag .. " plays on a cart role", tostring(beat.on))
    if beat.motion then
      check(Vfx.GENERAL_MOTIONS3[beat.motion] == true, tag .. " is a known motion")
      check((Battlefield.FX_MOTION_SPAN[beat.motion] or 0) > 0, tag .. "'s motion has a span the screens read")
    else
      check(valid(beat), tag .. " is a drawable look")
    end
  end
end
-- each one read off its own script
local scared = Vfx.forGeneral3("MON_SCARED")
eq(scared[1].on, "own", "general: MON_SCARED plays on our monster (DecideAnimSides 1: target PLAYER_LEFT)")
eq(scared[1].style .. "/" .. scared[1].palette, "splash/FEAR",
  "general: ...its sweat drops in a cold teal (gSprayWaterDropletSpriteTemplate, the palette blend)")
eq(scared[2] and (scared[2].motion .. "@" .. scared[2].on), "tremble@own",
  "general: ...and it shakes (AnimTask_ShakeMon2 on the target)")
local getOut = Vfx.forGeneral3("GHOST_GET_OUT")
eq(getOut[1].delivery .. "/" .. getOut[1].palette, "field/GHOST",
  "general: GHOST_GET_OUT darkens the whole field to the GHOST's (fadetobg BG_GHOST)")
eq(getOut[2].on .. "/" .. getOut[2].palette, "own/FEAR", "general: ...then our monster sweats (the target)")
eq(getOut[3] and getOut[3].motion, "tremble", "general: ...and shakes")
check(getOut[3] and (getOut[3].wait or 0) > 0, "general: ...once the background is up")
local scope = Vfx.forGeneral3("SILPH_SCOPED")
eq(scope[1].on, "event", "general: SILPH_SCOPED plays on the battler the event names (BS_OPPONENT1)")
local transform = Vfx.forMove("TRANSFORM", { type = "NORMAL", power = 0 })
eq(scope[1].style .. "/" .. scope[1].palette, transform.style .. "/" .. transform.palette,
  "general: ...as TRANSFORM's shimmer (AnimTask_TransformMon)")
for _, throw in ipairs({ { "BAIT_THROW", "BAIT", true }, { "ROCK_THROW", "ROCK", false },
                         { "POKEBLOCK_THROW", "POKEBLOCK", true } }) do
  local beats = Vfx.forGeneral3(throw[1])
  local tag = "general: " .. throw[1]
  eq(beats[1].from, "trainer", tag .. " is thrown by our trainer (PLAYER_LEFT is the trainer's pic)")
  eq(beats[1].on, "foe", tag .. " ...at their monster (OPPONENT_LEFT)")
  eq(beats[1].delivery, "projectile", tag .. " ...arcing over")
  eq(beats[1].palette, throw[2], tag .. " ...in its own colours")
  eq(beats[2] and beats[2].motion, throw[3] and "sway" or nil,
     tag .. (throw[3] and " then the monster sways (AnimTask_SwayMon)" or " then nothing (a hit splat only)"))
  if throw[3] then check((beats[2].wait or 0) > 0, tag .. " ...once it has landed (`delay 50`)") end
end
eq(Vfx.forGeneral3("SAFARI_REACTION", 0)[1].motion, "sway", "general: watching carefully turns side to side")
eq(Vfx.forGeneral3("SAFARI_REACTION", 1)[1].palette, "ANGER", "general: angry pops anger marks")
eq(Vfx.forGeneral3("SAFARI_REACTION", 2)[1].motion, "nod", "general: eating bobs")
eq(Vfx.forGeneral3("SAFARI_REACTION", 9)[1].motion, "sway",
  "general: a reaction past the table is watching (AnimTask_SafariGetReaction)")
eq(Vfx.forGeneral3("SAFARI_REACTION")[1].motion, "sway", "general: ...and so is none")
for _, n in ipairs({ 0, 1, 2 }) do
  eq(Vfx.forGeneral3("SAFARI_REACTION", n)[1].on, "foe", "general: reaction " .. n .. " plays on the wild monster")
end
local look1, look2 = Vfx.forGeneral3("BAIT_THROW"), Vfx.forGeneral3("BAIT_THROW")
check(look1[1] ~= look2[1], "general: every call answers fresh beats")
look1[1].style = "blast"
eq(Vfx.forGeneral3("BAIT_THROW")[1].style, "rock", "general: ...so stamping one never reaches the table")
eq(Vfx.forGeneral3("TACKLE"), nil, "general: a move has no general look")
eq(Vfx.forGeneral3("WISH_HEAL"), nil, "general: ...nor a clip outside this set (no referee sends WISH_HEAL)")
eq(Vfx.forGeneral3(nil), nil, "general: ...nor nothing")

-- ---- the general clips every fight can send (W3-UC3)
-- A trap's turn is keyed by the trapping move's number (sB_ANIM_ARG1 =
-- wrappedMove), turned into the branch the way AnimTask_GetTrappedMoveAnimId
-- does: FIRE_SPIN 83, WHIRLPOOL 250, CLAMP 128, SAND_TOMB 328 (pret moves.h),
-- anything else BIND / WRAP's.
eq(Vfx.trapAnim3(83), 1, "trap: FIRE SPIN is TRAP_ANIM_FIRE_SPIN")
eq(Vfx.trapAnim3(250), 2, "trap: WHIRLPOOL is TRAP_ANIM_WHIRLPOOL")
eq(Vfx.trapAnim3(128), 3, "trap: CLAMP is TRAP_ANIM_CLAMP")
eq(Vfx.trapAnim3(328), 4, "trap: SAND TOMB is TRAP_ANIM_SAND_TOMB")
eq(Vfx.trapAnim3(20), 0, "trap: BIND is TRAP_ANIM_BIND")
eq(Vfx.trapAnim3(35), 0, "trap: WRAP is too (TRAP_ANIM_WRAP == TRAP_ANIM_BIND)")
eq(Vfx.trapAnim3(nil), 0, "trap: no move is the script's fallthrough (goto Status_BindWrap)")
eq(Vfx.trapAnim3(1), 0, "trap: ...and so is any other move")
for _, case in ipairs({ { nil, "gust/NORMAL", "Status_BindWrap's tendrils" },
                        { 35, "gust/NORMAL", "WRAP squeezes as BIND does" },
                        { 83, "ember/FIRE", "Status_FireSpin's embers" },
                        { 250, "psi/WATER", "Status_Whirlpool's orbs, the move's own swirl" },
                        { 128, "impact/WATER", "Status_Clamp's jaws and hit splat" },
                        { 328, "quake/GROUND", "Status_SandTomb's dirt, SAND TOMB's own look" } }) do
  local beats = Vfx.forGeneral3("TURN_TRAP", case[1])
  local tag = "trap " .. tostring(case[1]) .. ": "
  eq(beats[1].style .. "/" .. beats[1].palette, case[2], tag .. case[3])
  eq(beats[2] and (beats[2].motion .. "@" .. beats[2].on), "tremble@event",
     tag .. "...then the trapped monster shakes (AnimTask_ShakeMon on ANIM_TARGET)")
  for i, beat in ipairs(beats) do
    eq(beat.on, "event", tag .. "beat " .. i .. " is on the trapped monster (attacker = target = it)")
    check(beat.from == nil and beat.delivery ~= "projectile" and beat.delivery ~= "beam",
          tag .. "beat " .. i .. " travels from nobody")
  end
end
check(Vfx.isGeneral3("TURN_TRAP") and Vfx.isGeneral3("FOCUS_PUNCH_SETUP")
      and Vfx.isGeneral3("FUTURE_SIGHT_HIT") and Vfx.isGeneral3("DOOM_DESIRE_HIT", true),
      "general: the four are general in any fight, Safari or not")
check(not Vfx.isGeneral3("FOCUS_PUNCH") and not Vfx.isGeneral3("FUTURE_SIGHT")
      and not Vfx.isGeneral3("DOOM_DESIRE"),
      "general: ...while the moves themselves stay moves")
local focus = Vfx.forGeneral3("FOCUS_PUNCH_SETUP")
local endure = Vfx.forMove("ENDURE", { type = "NORMAL", power = 0 })
eq(focus[1].on .. "/" .. focus[1].delivery, "event/self",
   "focus: General_FocusPunchSetUp plays on its user (ANIM_ATTACKER)")
eq(focus[1].style .. "/" .. focus[1].palette, endure.style .. "/" .. endure.palette,
   "focus: ...as ENDURE's rising energy (call EndureEffect)")
eq(focus[2] and (focus[2].motion .. "@" .. focus[2].on), "tremble@event",
   "focus: ...while the user shivers (AnimTask_ShakeMon2 ANIM_ATTACKER)")
local future = Vfx.forGeneral3("FUTURE_SIGHT_HIT")
eq(future[1].delivery .. "/" .. future[1].palette, "field/PSYCHIC",
   "future: FUTURE SIGHT's hit puts the PSYCHIC background behind the field")
eq(future[2] and (future[2].motion .. "@" .. future[2].on), "tremble@event",
   "future: ...and the monster it lands on shakes (SetAnimTargetToBattlerTarget, ShakeMon)")
eq(#future, 2, "future: ...and no sprite of its own")
local doom = Vfx.forGeneral3("DOOM_DESIRE_HIT")
local explosion = Vfx.forMove("EXPLOSION", { type = "NORMAL", power = 250 })
eq(doom[1].delivery .. "/" .. doom[1].palette, "field/STEEL",
   "doom: DOOM DESIRE's hit whites the background out under falling light")
eq(doom[2].on .. "/" .. doom[2].style .. "/" .. doom[2].palette,
   "event/" .. explosion.style .. "/" .. explosion.palette,
   "doom: ...then EXPLOSION's bursts on the monster it lands on (gExplosionSpriteTemplate)")
eq(doom[3] and doom[3].motion, "tremble", "doom: ...which shakes in place (ShakeMonInPlace)")
check(doom[3] and (doom[3].wait or 0) > 0, "doom: ...once the light has come down")
for _, name in ipairs({ "TURN_TRAP", "FOCUS_PUNCH_SETUP", "FUTURE_SIGHT_HIT", "DOOM_DESIRE_HIT" }) do
  for i, beat in ipairs(Vfx.forGeneral3(name)) do
    check(beat.from == nil and beat.delivery ~= "projectile" and beat.delivery ~= "beam",
          ("general: %s beat %d leaves nobody's hand"):format(name, i))
  end
end
-- A SUBSTITUTE on the battler a clip is launched for skips it
-- (TryHandleLaunchBattleTableAnimation); FUTURE SIGHT's is launched for its
-- user, whom the event does not name.
check(Vfx.subSilences3("TURN_TRAP") and Vfx.subSilences3("FOCUS_PUNCH_SETUP")
      and Vfx.subSilences3("MON_SCARED"),
      "sub: a doll on the event's battler silences its clip")
check(not Vfx.subSilences3("FUTURE_SIGHT_HIT") and not Vfx.subSilences3("DOOM_DESIRE_HIT"),
      "sub: ...not a delayed hit's (launched for the user's position)")
check(not Vfx.subSilences3("BAIT_THROW") and not Vfx.subSilences3("TACKLE")
      and not Vfx.subSilences3(nil), "sub: ...nor a Safari throw, a move or nothing")
check(Vfx.isGeneral3("MON_SCARED") and Vfx.isGeneral3("SAFARI_REACTION", false),
  "general: the clips no move shares a name with are general anywhere")
check(not Vfx.isGeneral3("ROCK_THROW"), "general: ROCK_THROW is the move ROCK THROW off a Safari")
check(Vfx.isGeneral3("ROCK_THROW", true), "general: ...and B_ANIM_ROCK_THROW on a Safari")
check(not Vfx.isGeneral3("TACKLE", true) and not Vfx.isGeneral3(nil), "general: a move never is")
-- the other doors answer as they did
eq(Vfx.forMove3("ROCK_THROW", { type = 5, power = 50 }).delivery, "projectile",
  "general: the move ROCK THROW keeps its own look (forMove3)")
eq(Vfx.forMove3("ROCK_THROW", { type = 5, power = 50 }).palette, "ROCK", "general: ...in the type's colours")
for _, name in ipairs(GENERAL3) do
  eq(Vfx.forStatusAnim(name), nil, "general: forStatusAnim stays shut to " .. name)
end
for _, name in ipairs({ "FEAR", "BAIT", "POKEBLOCK", "ANGER" }) do
  local pal = Vfx.PALETTES[name]
  check(type(pal) == "table" and #pal == 3, "general: the " .. name .. " palette is core, mid, edge")
end

-- ---- the monster's own motions (Battlefield sway / nod / tremble)
for _, fn in ipairs({ { "fxSway", Battlefield.fxSway }, { "fxNod", Battlefield.fxNod },
                      { "fxTremble", Battlefield.fxTremble } }) do
  check(math.abs(fn[2](0)) < 1e-9 and math.abs(fn[2](1)) < 1e-6, "motion: " .. fn[1] .. " rests at both ends")
  local peak = 0
  for i = 0, 200 do peak = math.max(peak, math.abs(fn[2](i / 200))) end
  check(peak > 0.5 and peak <= 1 + 1e-9, "motion: " .. fn[1] .. " moves, within its unit peak")
end
eq(Battlefield.fxWaited(0.3, 0.5), 0, "motion: a beat rests through its wait")
eq(Battlefield.fxWaited(0.75, 0.5), 0.5, "motion: ...then runs over what is left")
eq(Battlefield.fxWaited(0.4, nil), 0.4, "motion: no wait is no rest")
local swayFoe = Battlefield.fxSeat({ { kind = "sway", side = "foe", seatIndex = 1, t = 0.125 } }, "foe", 1)
check(swayFoe.dx < 0, "motion: a foe sways toward the midline first")
check(swayFoe.alpha == 1 and swayFoe.hidden == false and swayFoe.scale == 1,
  "motion: ...and nothing about it hides or shrinks the monster")
check(Battlefield.fxSeat({ { kind = "sway", side = "ally", seatIndex = 1, t = 0.125 } }, "ally", 1).dx > 0,
  "motion: an ally sways the other way, toward the midline too")
check(Battlefield.fxSeat({ { kind = "nod", side = "foe", seatIndex = 1, t = 0.25 } }, "foe", 1).dy > 0,
  "motion: a nod dips")
check(Battlefield.fxSeat({ { kind = "tremble", side = "ally", seatIndex = 1, t = 0.03 } }, "ally", 1).dx ~= 0,
  "motion: a tremble shivers")
eq(Battlefield.fxSeat({ { kind = "sway", side = "foe", seatIndex = 1, t = 0.3, wait = 0.5 } }, "foe", 1).dx, 0,
  "motion: a sway still waiting holds the monster still")
eq(Battlefield.fxSeat({ { kind = "sway", side = "foe", seatIndex = 1, t = 0.125 } }, "foe", 2).dx, 0,
  "motion: ...and only its own seat moves")

-- ---- a throw from our edge with nothing of ours out (W2-UC2: the Safari and
--      the old man's tutorial field no battler on side a; the cart's throw
--      there is the trainer's own, B_ANIM_BALL_THROW_WITH_TRAINER)
-- "x,y", whatever is missing (a nil fails the check rather than the run).
local function xy(x, y) return tostring(x) .. "," .. tostring(y) end

do
  local function wildSeat() return { name = "PIDGEY", hp = 20, maxHp = 20, level = 5, front = fakeImage("f") } end
  local safari = { mode = "wild", frame = 0, allyHumans = { { id = "self", name = "ANN" } },
                   allySeats = {}, foeSeats = { wildSeat() } }
  local layS = Battlefield.layout(safari)
  local me = layS.humans[1]
  check(me ~= nil and me.side == "ally", "no battler: our trainer stands on our edge")
  local handX, handY = me.x, me.y - math.floor(me.drawH / 2)
  local emptyX, emptyY = Battlefield.seatAnchor("ally", 1, { mons = 0, humans = 1, plates = 0 })
  local bx, by = Battlefield.ballOrigin(layS, "foe", false)
  eq(xy(bx, by), xy(handX, handY), "no battler: a catch ball leaves the trainer's hand")
  check(bx ~= emptyX or by ~= emptyY, "no battler: ...not the empty square a monster of ours would hold")
  drawn = {}
  safari.fx = { { kind = "ball", side = "foe", seatIndex = 1, t = 0.001 } }
  Battlefield.draw({ game = { generation = 3 } }, safari, nil)
  local firstBall
  for _, d in ipairs(drawn) do
    if d[1] == "circle" then firstBall = d; break end
  end
  check(firstBall and math.abs(firstBall[3] - handX) < 2 and math.abs(firstBall[4] - handY) < 2,
    "no battler: the arc drawn starts at the figure")
  local tx, ty = Battlefield.vfxOrigin(layS, { fromTrainer = "ally", delivery = "projectile" })
  eq(xy(tx, ty), xy(handX, handY), "no battler: a thrown bait leaves the trainer's hand (fromTrainer)")
  local sx, sy = Battlefield.vfxOrigin(layS, { fromSide = "ally", fromSeat = 1 })
  eq(xy(sx, sy), xy(handX, handY),
    "no battler: a throw from a side with nothing out leaves its trainer, not an empty square")
  drawn = {}
  safari.fx = { { kind = "vfx", side = "foe", seatIndex = 1, t = 0.2, style = "rock", palette = "BAIT",
                  delivery = "projectile", fromTrainer = "ally", seed = 3 } }
  local okThrow = pcall(Battlefield.draw, { game = { generation = 3 } }, safari, nil)
  check(okThrow and #drawn > 0, "no battler: a thrown look draws in flight")
  -- nobody on that edge: the edge column, as a catch ball always had
  local bare = Battlefield.layout({ mode = "wild", foeSeats = { wildSeat() } })
  local ex, ey = Battlefield.ballOrigin(bare, "foe", false)
  local ox, oy = Battlefield.vfxOrigin(bare, { fromTrainer = "ally" })
  eq(xy(ox, oy), xy(ex, ey), "no trainer: a thrown look keeps a ball's edge column")
  check(ex < Battlefield.MIDLINE, "no trainer: ...on our half")
  -- a side with a monster out throws from its seat, as ever
  local fielded = Battlefield.layout({ mode = "wild", allyHumans = { { name = "ANN" } },
                                       allySeats = { wildSeat() }, foeSeats = { wildSeat() } })
  local mine
  for _, m in ipairs(fielded.mons) do if m.side == "ally" then mine = m end end
  local fx, fy = Battlefield.vfxOrigin(fielded, { fromSide = "ally", fromSeat = 1 })
  eq(xy(fx, fy), xy(mine and mine.x, mine and mine.y), "fielded: a move still leaves its user's seat")
  eq(Battlefield.vfxOrigin(fielded, { delivery = "projectile" }), nil,
    "fielded: no origin named is none (a burst at the target, as ever)")
  -- and a send ball still leaves the trainer behind the seat (own)
  local sendX = Battlefield.ballOrigin(fielded, "ally", true, 1)
  eq(sendX, fielded.humans[1].x, "fielded: a send-out ball still leaves its own trainer")
end

-- ------- C. a Gen 1 boot: the Gen 3 arm stays shut

engineAsked = {}
local Gen1Stub = setmetatable({}, { __index = Gen3Stub })
Gen1Stub.active = function() return false end
Gen1Stub.engine = function(name) engineAsked[#engineAsked + 1] = name return nil end
local need1 = resolverFor(Gen1Stub)
local BF1 = need1("Battlefield")
local CB1 = need1("ClassicBattle")
check(not BF1.onGen3(), "a Gen 1 boot does not read as Gen 3")
local lay1 = BF1.layout({ mode = "1v1", allyHumans = { { name = "A" } }, foeHumans = { { name = "B" } },
  allySeats = { seat("a") }, foeSeats = { seat("b") } })
eq(lay1.humans[1].drawH, BF1.HUMAN_DRAW, "Gen 1 trainers keep their 32px box")
eq(lay1.humans[1].x, 36, "Gen 1 ally trainer column unchanged")
eq(lay1.humans[1].y, 140, "Gen 1 1v1 trainer row unchanged")
eq(lay1.mons[1].x, 220, "Gen 1 ally mon column unchanged")
drawn = {}
pcall(BF1.draw, { game = { data = {} } }, { mode = "1v1", allySeats = { seat("a") }, foeSeats = { seat("b") },
  allyHumans = { { name = "A" } }, foeHumans = { { name = "B" } } }, {})
eq(CB1.drawGen3({ foe = {}, ally = {} }), false, "the Gen 3 page refuses to draw on Gen 1")
-- The trainer launch for a side with nothing out is Gen 3's: a Gen 1 travelling
-- look from an empty seat lands where it always did.
local layNoAlly = BF1.layout({ mode = "1v1", allyHumans = { { name = "A" } }, foeHumans = { { name = "B" } },
  allySeats = {}, foeSeats = { seat("b") } })
local g1x, g1y = BF1.vfxOrigin(layNoAlly, { fromSide = "ally", fromSeat = 1 })
local a1x, a1y = BF1.seatAnchor("ally", 1, { mons = 0, humans = 1, plates = 0 })
eq(xy(g1x, g1y), xy(a1x, a1y), "Gen 1: a look from an empty seat still anchors on that seat")
eq(#engineAsked, 0, "no src.*.game3.* module was asked for on a Gen 1 boot")

-- ------- B. the real headless loader, generation 3

local GameVersion = require("src.core.GameVersion")
local makeRemapFs = dofile(MOD_PATH .. "/tests/mod_remap_fs.lua")
for _, version in ipairs({ "firered", "emerald" }) do
  GameVersion.set(version)
  local opts = { generation = 3, data = T.sdk.gen3Data() }
  if MOD_PATH ~= "mods/rby_mmo" then opts.fs = makeRemapFs(T, MOD_PATH) end
  local ok, run = pcall(T.sdk.loadMod, "mods/rby_mmo", opts)
  check(ok and run ~= nil, version .. ": the mod loads headless on a Gen 3 boot")
  if ok and run then
    run.loader.game = { generation = 3, phase = "field", session = { party = {} }, data = run.data }
    local api = run.loader:_api(run.mod)
    local env = run.loader:_modEnv(run.mod)
    local cache = {}
    local function needL(name)
      if cache[name] ~= nil then return cache[name] end
      local body = api:read("src/" .. name .. ".lua")
      local chunk = assert(env.loadstring(body, "@rby_mmo/src/" .. name .. ".lua"))
      local value = chunk(needL, api)
      cache[name] = value == nil and true or value
      return cache[name]
    end
    local okM, BFL = pcall(needL, "Battlefield")
    local okC, CBL = pcall(needL, "ClassicBattle")
    local okV, VL = pcall(needL, "Vfx")
    check(okM and type(BFL) == "table", version .. ": Battlefield resolves through the sandbox")
    check(okC and type(CBL) == "table", version .. ": ClassicBattle resolves through the sandbox")
    check(okV and type(VL) == "table", version .. ": Vfx resolves through the sandbox")
    if okM and okC then
      check(BFL.onGen3(), version .. ": the arena knows this is a Gen 3 boot")
      check(BFL.enabled(run.loader.game), version .. ": the theatre gate is up")
      -- the cache-less engine: every art source answers nil, nothing throws
      local okF = pcall(BFL.gen3Front, 25)
      check(okF, version .. ": a pic asked of a cache-less engine answers without throwing")
      drawn = {}
      local okD = pcall(BFL.draw, { game = run.loader.game }, {
        mode = "1v1", allySeats = { seat("a") }, foeSeats = { seat("b") },
        allyHumans = { { name = "A", spriteId = "OBJ_EVENT_GFX_RED_NORMAL" } },
        foeHumans = { { name = "B", trainerPic = 3 } },
      }, { game = run.loader.game })
      check(okD, version .. ": the arena draws on a Gen 3 boot without throwing")
      local okP, drew = pcall(CBL.drawGen3, {
        foe = { name = "BULBASAUR", level = 5, hp = 10, maxHp = 20, gender = "F" },
        ally = { name = "SPARKY", level = 7, hp = 5, maxHp = 22, expFrac = 0.5, status = "PAR" },
        prompt = "What will\nSPARKY do?", commands = { "FIGHT", "ITEM", "SWITCH", "RUN" },
        commandIndex = 2, foeParty = "oox",
        foeStrip = strips(2), allyStrip = strips(2),
      })
      check(okP, version .. ": the classic page draws without throwing")
      check(drew == true or drew == false, version .. ": ...and reports whether it drew")
      local okMv = pcall(CBL.drawGen3, { foe = {}, ally = {}, cursor = 2,
        moves = { { label = "TACKLE", type = 0, pp = 30, maxPp = 35 } } })
      check(okMv, version .. ": the move menu draws without throwing")
      local okL = pcall(CBL.drawGen3, { list = { title = "Choose", cursor = 1,
        rows = { { label = "PIKACHU", front = front, right = "20/30" } } } })
      check(okL, version .. ": the POKeMON page draws without throwing")
      for _, e in ipairs(run.errors or {}) do
        local text = tostring(type(e) == "table" and (e.message or e[1]) or e)
        check(not text:find("Battlefield") and not text:find("ClassicBattle") and not text:find("Vfx"),
          version .. ": no load error names the battle-screen modules", text)
      end
    end
    run.release()
  end
end
GameVersion.set("red")

_G.love = previousLove
T.finish("gen3_battlefield")
