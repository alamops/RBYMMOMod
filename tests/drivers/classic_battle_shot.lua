-- Classic 160×144 battle chrome screenshots (CLASSIC BATTLE UI on).
--
-- One LOVE instance, real ROM HUD tiles / party icons / battle pics.
-- Captures 1v1, 2x2, and 3x3 so a reviewer can see field scale, side-strip
-- bag icons, and HUD chrome without a two-client fight.
--
--   SHOT_DIR=/path/to/inspect \
--   POKEPORT_IDENTITY=classicui POKEPORT_TOUCH=0 \
--   POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/classic_battle_shot.lua \
--   love .
--
-- Wrapped by tests/drivers/run-classic-battle-e2e.sh.

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

-- ======================================================================
-- Gen 3 (FireRed / Emerald): the cart's own 240x160 battle page
-- ======================================================================
--
-- CLASSIC BATTLE UI on Gen 3 is ClassicBattle.drawGen3: the GBA battle screen
-- drawn from the cart's own battle chrome. This arm stages its views the way
-- the battle screens hand them over (a view model; see the contract in
-- src/ClassicBattle.lua) and puts them up through Gen3Ui.pushState on a state
-- whose drawsWidescreen() is false, so the engine draws it into its 240x160
-- UI canvas -- the seat the real screens use. Each frame is also drawn into a
-- private 240x160 canvas and pixel-asserted at the page's own coordinates.
--
-- Frames: classic-1v1 (the action menu), classic-moves (the move menu with PP
-- and TYPE), classic-2v2 (guild focus: both rails, the focused pair),
-- classic-party (the POKeMON page), classic-bag (the bag window), classic-
-- trainer (an NPC trainer's pic, the foe's ball row, a message).
-- SHOT_DIR/g3-<fr|em>-<frame>.png.
local function runGen3(game)
  io.stdout:setvbuf("no")
  local U = require("tests.drivers.util")
  local TAG = "CLASSIC_SHOT:"
  local function log(...)
    local parts = { TAG }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print(table.concat(parts, "\t"))
  end
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_classic_shots"
  os.execute('mkdir -p "' .. SHOT_DIR .. '" 2>/dev/null')
  local VER = os.getenv("POKEPORT_VERSION") or "firered"
  local EM = VER == "emerald"
  local V = EM and "em" or "fr"

  local pass, fail = 0, 0
  local function check(cond, label, detail)
    if cond then pass = pass + 1; log("PASS", label, detail or "")
    else fail = fail + 1; log("FAIL", label, detail or "") end
  end
  local function finish()
    log("GAPS:" .. tostring(fail))
    log("SUMMARY", "pass=" .. pass, "fail=" .. fail)
    log("DONE")
    love.event.quit(fail > 0 and 1 or 0)
  end

  -- ---- boot to the field, standing in tall grass (the page's backdrop is
  -- the cart's terrain for the tile underfoot)
  for _ = 1, 900 do
    if game.phase == "boot" and game.boot then break end
    U.wait(1)
  end
  pcall(game._handleBootAction, game, { action = "new_game", name = "ALEX" })
  for _ = 1, 1500 do
    if game.phase == "field" and game.session then break end
    U.wait(1)
  end
  U.wait(60)
  check(game.phase == "field", "Gen 3 boot reached the field", tostring(game.phase))
  local Map = require("src.core.game3.map")
  local Player = require("src.core.game3.player")
  local Runtime = require("src.core.game3.runtime")
  local Collision = require("src.core.game3.collision")
  local session = Runtime.getSession()
  local function placeAt(mapId, x, y)
    pcall(Map.load, nil, game, mapId, { x = x, y = y, facing = "down" })
    if session then session.x, session.y, session.facing = x, y, "down" end
    Player.cellX, Player.cellY = x, y
    Player.px, Player.py = x * 16, y * 16
    Player.targetX, Player.targetY = x, y
    Player.moving = false
    Player.facing = "down"
    U.wait(45)
  end
  local route = EM and "EM_ROUTE101" or "FR_ROUTE1"
  placeAt(route, 8, 8)
  do
    local def = Map.currentDef and Map.currentDef()
    local layout = def and def.midLayout
    local w = layout and layout.width or 40
    local h = layout and layout.height or 40
    local found = nil
    for y = 2, h - 3 do
      for x = 2, w - 3 do
        local ok, b = pcall(Collision.behavior, x, y)
        if ok and b == 0x02 then found = { x = x, y = y }; break end
      end
      if found then break end
    end
    if found then placeAt(route, found.x, found.y) end
    log("placed", route, found and (found.x .. "," .. found.y) or "no grass found")
  end

  local loader = game.mods
  local record = loader and loader.mods and loader.mods.rby_mmo
  check(record ~= nil, "the mod is loaded on this boot", record and tostring(record.state))
  if not record then return finish() end
  local api = loader:_api(record)
  local env = loader:_modEnv(record)
  local cache = {}
  local function need(name)
    if cache[name] ~= nil then return cache[name] end
    local body = api:read("src/" .. name .. ".lua")
    local chunk = assert(env.loadstring(body, "@rby_mmo/src/" .. name .. ".lua"))
    local value = chunk(need, api)
    cache[name] = value == nil and true or value
    return cache[name]
  end
  local ClassicBattle = need("ClassicBattle")
  local Battlefield = need("Battlefield")
  local Gen3Ui = need("Gen3Ui")
  local Gen3 = need("Gen3")

  -- ---- the seats
  local ALLY_SP, FOE_SP = 25, EM and 280 or 1
  local ALLY2_SP, FOE2_SP, FOE3_SP = 7, EM and 283 or 16, EM and 277 or 19
  local function seat(sp, name, level, hp, maxHp, back, extra)
    local s = {
      name = name, level = level, hp = hp, maxHp = maxHp,
      sprite = back and Battlefield.gen3Back(sp) or Battlefield.gen3Front(sp),
      speciesId = sp, elevation = (not back) and Battlefield.gen3Elevation(sp) or nil,
    }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
  end
  local ally = seat(ALLY_SP, "SPARKY", 25, 40, 55, true, { gender = "M", expFrac = 0.62 })
  local foe = seat(FOE_SP, Gen3.speciesName(FOE_SP) or "FOE", 18, 32, 45, false,
    { gender = "F", caught = true })
  check(ally.sprite ~= nil and foe.sprite ~= nil, "Gen 3 back / front pics resolve for the pair")
  local moves = {
    { label = "THUNDERBOLT", type = 13, pp = 10, maxPp = 15 },
    { label = "QUICK ATTACK", type = 0, pp = 30, maxPp = 30 },
    { label = "THUNDER WAVE", type = 13, pp = 2, maxPp = 20 },
    { label = "GROWL", type = 0, pp = 40, maxPp = 40 },
  }

  local view = nil
  local drewLast = nil
  local state = {
    screenId = "ClassicShotGen3",
    drawsWidescreen = function() return false end,
    draw = function()
      drewLast = ClassicBattle.drawGen3(view, nil)
    end,
    update = function() end,
  }

  local W, H = ClassicBattle.G3.W, ClassicBattle.G3.H
  local function renderCanvas()
    local c = love.graphics.newCanvas(W, H)
    local drew = false
    love.graphics.push("all")
    love.graphics.setCanvas(c)
    love.graphics.origin()
    love.graphics.clear(0, 0, 0, 1)
    drew = ClassicBattle.drawGen3(view, nil)
    love.graphics.pop()
    return drew, c:newImageData()
  end
  local function maxSat(data, r)
    local best = 0
    for y = math.max(0, r.y), math.min(H - 1, r.y + r.h - 1) do
      for x = math.max(0, r.x), math.min(W - 1, r.x + r.w - 1) do
        local cr, cg, cb = data:getPixel(x, y)
        local s = math.max(math.abs(cr - cg), math.abs(cg - cb), math.abs(cr - cb))
        if s > best then best = s end
      end
    end
    return best
  end
  -- The healthbox's cream (high red and green, blue a little lower): the box
  -- really drew, and the placeholder ink was painted over with it.
  local function creamFraction(data, r)
    local hit, total = 0, 0
    for y = math.max(0, r.y), math.min(H - 1, r.y + r.h - 1) do
      for x = math.max(0, r.x), math.min(W - 1, r.x + r.w - 1) do
        local cr, cg, cb = data:getPixel(x, y)
        total = total + 1
        if cr > 0.9 and cg > 0.9 and cb > 0.72 and cb < 0.95 then hit = hit + 1 end
      end
    end
    return total > 0 and hit / total or 0
  end
  local function inside(r)
    return r.x >= 0 and r.y >= 0 and r.x + r.w <= W and r.y + r.h <= H
  end
  local function overlaps(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
  end

  local function assertPage(label, opts)
    opts = opts or {}
    local ok, drew, data = pcall(renderCanvas)
    check(ok and drew == true, label .. ": ClassicBattle.drawGen3 drew the page with the cart chrome",
      tostring(ok and drew or drew))
    if not (ok and data) then return nil end
    local lay = ClassicBattle.gen3Layout(view)
    local boxes = {}
    for _, key in ipairs({ "foeBox", "allyBox", "panel", "foeBalls", "list" }) do
      if lay[key] then boxes[#boxes + 1] = { key, lay[key] } end
    end
    for i, cell in ipairs(lay.foeStrip or {}) do boxes[#boxes + 1] = { "foeStrip" .. i, cell } end
    for i, cell in ipairs(lay.allyStrip or {}) do boxes[#boxes + 1] = { "allyStrip" .. i, cell } end
    for _, b in ipairs(boxes) do
      check(inside(b[2]), ("%s: %s lies inside 240x160"):format(label, b[1]),
        ("%d,%d %dx%d"):format(b[2].x, b[2].y, b[2].w, b[2].h))
    end
    for i = 1, #boxes do
      for j = i + 1, #boxes do
        local a, b = boxes[i], boxes[j]
        -- the bag / target window is a modal over the field: it covers the
        -- HUD by design, the way the cart's own windows do
        local exempt = a[1] == "list" or b[1] == "list"
        if not exempt then
          check(not overlaps(a[2], b[2]), ("%s: %s and %s do not overlap"):format(label, a[1], b[1]))
        end
      end
    end
    if not opts.page and not opts.window then
      if lay.foeBox then
        local f = creamFraction(data, lay.foeBox)
        check(f > 0.25, label .. ": the foe healthbox is the cart's (cream interior)", ("%.2f"):format(f))
      end
      if lay.allyBox then
        local f = creamFraction(data, lay.allyBox)
        check(f > 0.25, label .. ": the player healthbox is the cart's (cream interior)", ("%.2f"):format(f))
      end
      if lay.foePic and view.foe and not opts.noFoePic and not view.foe.substitute then
        local s = maxSat(data, lay.foePic)
        check(s > 0.15, label .. ": the foe pic stands on its platform", ("sat=%.2f"):format(s))
      end
      if lay.allyPic and view.ally and not view.ally.substitute then
        local s = maxSat(data, lay.allyPic)
        check(s > 0.15, label .. ": the player's back pic is drawn", ("sat=%.2f"):format(s))
      end
      local r, g, b = data:getPixel(120, 60)
      check(r + g + b > 0.5, label .. ": the cart's battle background fills the field",
        ("rgb=%.2f,%.2f,%.2f"):format(r, g, b))
    end
    return data, lay
  end

  local function shoot(name, label)
    U.wait(4)
    local path = ("%s/g3-%s-%s.png"):format(SHOT_DIR, V, name)
    local ok = U.shot(game, path)
    check(ok, label .. ": screenshot reached disk", path)
    check(drewLast == true, label .. ": the live layer drew through drawGen3")
    return ok
  end

  -- ---- frame 1: 1v1, the action menu (FIGHT BAG / POKeMON RUN)
  view = {
    mode = "1v1", foe = foe, ally = ally, foeParty = "oox",
    prompt = "What will\nSPARKY do?",
    commands = { "FIGHT", "ITEM", "SWITCH", "RUN" }, commandIndex = 1,
  }
  check(ClassicBattle.gen3CommandLabel("SWITCH") ~= "SWITCH",
    "the POKeMON command wears the cart's own word", ClassicBattle.gen3CommandLabel("SWITCH"))
  local pushed = Gen3Ui.pushState(game, state)
  check(pushed ~= nil, "the staged classic state is on the Gen 3 stack")
  U.wait(8)
  assertPage("1v1")
  shoot("classic-1v1", "1v1")

  -- ---- frame 2: the move menu, PP in the cart's colour bands, TYPE/
  view = {
    mode = "1v1", foe = foe, ally = ally, foeParty = "oox",
    moves = moves, cursor = 3,
  }
  check(ClassicBattle.gen3PpState(2, 20) == 1 and ClassicBattle.gen3PpState(0, 20) == 2
    and ClassicBattle.gen3PpState(20, 20) == 3, "the PP colour bands follow the cart's rule")
  U.wait(4)
  assertPage("moves")
  shoot("classic-moves", "moves")

  -- ---- frame 2b: a sandstorm, and the player's Substitute doll
  local subAlly = setmetatable({ substitute = true }, { __index = ally })
  view = {
    mode = "1v1", foe = foe, ally = subAlly, foeParty = "oox", weather = "sandstorm",
    message = "The sandstorm rages.", hold = true,
  }
  U.wait(4)
  local dataW = assertPage("weather")
  if dataW then
    local hits = 0
    for y = 0, 110, 2 do
      for x = 0, 239, 2 do
        local r, g, b = dataW:getPixel(x, y)
        if r > 0.75 and g > 0.55 and g < 0.8 and b < 0.55 then hits = hits + 1 end
      end
    end
    check(hits > 5, "weather: sand drifts across the field", "hits=" .. hits)
  end
  check(Battlefield.gen3SubstituteDoll(true) ~= nil, "weather: the cart's back doll resolves")
  shoot("classic-weather", "weather")

  -- ---- frame 3: 2v2 guild focus -- both rails, the focused pair centre
  local foe2 = seat(FOE2_SP, Gen3.speciesName(FOE2_SP) or "FOE2", 20, 9, 41, false, { status = "PSN" })
  view = {
    mode = "coop_npc", foe = foe2, ally = ally, foeParty = "oo",
    foeStrip = { focus = 2, seats = {
      { icon = Battlefield.gen3Icon(FOE_SP), name = foe.name },
      { icon = Battlefield.gen3Icon(FOE2_SP), name = foe2.name },
    } },
    allyStrip = { focus = 1, seats = {
      { icon = Battlefield.gen3Icon(ALLY_SP), name = "SPARKY" },
      { icon = Battlefield.gen3Icon(ALLY2_SP), name = "SQUIRTLE" },
    } },
    message = "SPARKY used THUNDERBOLT!", hint = true,
  }
  U.wait(4)
  local data2, lay2 = assertPage("2v2")
  if data2 and lay2 then
    for i, cell in ipairs(lay2.foeStrip) do
      check(maxSat(data2, cell) > 0.15, ("2v2: foe rail icon %d is drawn"):format(i))
    end
    for i, cell in ipairs(lay2.allyStrip) do
      check(maxSat(data2, cell) > 0.15, ("2v2: ally rail icon %d is drawn"):format(i))
    end
  end
  shoot("classic-2v2", "2v2")

  -- ---- frame 3b: 3v3 rails (three a side still fit their rails)
  view.foeStrip.seats[3] = { icon = Battlefield.gen3Icon(FOE3_SP) }
  view.allyStrip.seats[3] = { icon = Battlefield.gen3Icon(4) }
  U.wait(4)
  assertPage("3v3")
  shoot("classic-3v3", "3v3")

  -- ---- frame 4: the POKeMON page
  local rows = {}
  for i, sp in ipairs({ ALLY_SP, ALLY2_SP, 4, EM and 277 or 10 }) do
    rows[#rows + 1] = {
      label = Gen3.speciesName(sp) or ("MON " .. sp), front = Battlefield.gen3Front(sp),
      icon = Battlefield.gen3Icon(sp), right = (20 + i * 5) .. "/" .. (40 + i * 5),
      level = 20 + i, status = (i == 3) and "PAR" or nil, dim = (i == 4) or nil,
    }
  end
  view = { mode = "1v1", foe = foe, ally = ally,
           list = { title = "Choose a POKeMON.", rows = rows, cursor = 2 } }
  U.wait(4)
  local data4 = assertPage("party", { page = true })
  if data4 then
    check(maxSat(data4, { x = 8, y = 8, w = 64, h = 64 }) > 0.15,
      "party: the highlighted mon's front pic is on the page")
    check(maxSat(data4, { x = 84, y = 8, w = 32, h = 96 }) > 0.15,
      "party: the party icons run down the list")
  end
  shoot("classic-party", "party")

  -- ---- frame 5: the bag, a window over the field and the question below
  view = { mode = "1v1", foe = foe, ally = ally, foeParty = "oox",
           list = { title = "Use which item?", cursor = 2, rows = {
             { label = "POTION", right = "x3" }, { label = "SUPER POTION", right = "x1" },
             { label = "FULL HEAL", right = "x2" }, { label = "POKé BALL", right = "x5", dim = true },
           } } }
  U.wait(4)
  -- the window covers the foe pic and the player's box, as the cart's do
  local data5, lay5 = assertPage("bag", { window = true })
  if data5 and lay5.list then
    local r, g, b = data5:getPixel(lay5.list.x + 40, lay5.list.y + 60)
    check(r > 0.9 and g > 0.9 and b > 0.9, "bag: the window is the cart's white std frame",
      ("rgb=%.2f,%.2f,%.2f"):format(r, g, b))
  end
  shoot("classic-bag", "bag")

  -- ---- frame 6: an NPC trainer's intro -- the trainer pic, the ball row
  local npcPic = nil
  pcall(function()
    local Trainers = require("src.core.game3.scripting.trainers")
    for id = 1, 400 do
      local ok, info = pcall(Trainers.info, id)
      if ok and type(info) == "table" and info.pic ~= nil
         and Battlefield.gen3TrainerPic(info.pic) then
        npcPic = info.pic
        break
      end
    end
  end)
  check(npcPic ~= nil, "an NPC trainer pic resolves from the cart", tostring(npcPic))
  view = { mode = "1v1", foe = foe, ally = ally, foeParty = "ooox",
           trainer = { pic = npcPic }, showTrainer = true,
           message = "YOUNGSTER BEN would like to battle!", hint = true }
  U.wait(4)
  local data6, lay6 = assertPage("trainer", { noFoePic = true })
  if data6 and lay6 and lay6.foePic then
    check(maxSat(data6, lay6.foePic) > 0.12, "trainer: the NPC's own front pic stands where the foe will")
  end
  shoot("classic-trainer", "trainer")

  Gen3Ui.pop(game, state)
  U.wait(4)
  return finish()
end

return function(game)
  if tonumber(game and game.generation) == 3 then return runGen3(game) end
  local U = require("tests.drivers.util")
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local Pokemon = require("src.pokemon.Pokemon")
  local TAG = "CLASSIC_SHOT:"
  local function log(...)
    local parts = { TAG }
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring(select(i, ...))
    end
    print(table.concat(parts, "\t"))
  end

  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_classic_shots"
  os.execute('mkdir -p "' .. SHOT_DIR .. '" 2>/dev/null')

  if not H.newGame(game, TAG) then
    log("FAIL could not reach the overworld")
    love.event.quit(1)
    return
  end
  if game.save and game.save.player then
    game.save.player.name = "CLASSIC"
  end

  local stub = {
    id = "rby_mmo",
    path = "mods/rby_mmo",
    log = {
      info = function() end,
      warn = function(_, fmt, ...)
        log("warn", string.format(tostring(fmt), ...))
      end,
      error = function(_, fmt, ...)
        log("error", string.format(tostring(fmt), ...))
      end,
    },
    assets = {
      path = function(_, rel) return "mods/rby_mmo/" .. rel end,
    },
    options = {
      get = function(_, key) return key == "classicui" end,
    },
  }
  local cache = {}
  local function resolve(name)
    if cache[name] then return cache[name] end
    local chunk = assert(loadfile("mods/rby_mmo/src/" .. name .. ".lua"))
    cache[name] = chunk(resolve, stub)
    return cache[name]
  end

  local pass, fail = 0, 0
  local function check(cond, label, detail)
    if cond then
      pass = pass + 1
      log("PASS", label, detail or "")
    else
      fail = fail + 1
      log("FAIL", label, detail or "")
    end
  end

  local function shot(name)
    local path = SHOT_DIR .. "/" .. name
    if U.shot(game, path) then
      log("captured", path)
      return path
    end
    log("FAIL", "screenshot missed", path)
    fail = fail + 1
    return nil
  end

  local function skipIntro(screen)
    screen.introHide = nil
    screen.introBalls = nil
    screen.messages = {}
    screen.shown = nil
    screen.phase = "choose"
  end

  local pokedex = (game.data and game.data.pokemon) or {}
  local function firstPresent(...)
    for _, key in ipairs({ ... }) do
      if type(pokedex[key]) == "table" then return key end
    end
    return nil
  end
  local function mon(id, level)
    return Pokemon.new(game.data, id, level)
  end

  -- --------------------------------------------------------- 1v1 classic
  local Mediated = resolve("MediatedBattle")
  local one = Mediated.new({
    game = game,
    role = "host",
    peerName = "FOE",
    battle = "classic-1v1",
    transport = { send = function() return true end },
    classicUi = true,
  })
  check(one.classicUi == true, "1v1 latched classicUi")
  check(one:usesBattlefield() == false, "1v1 usesBattlefield is false")
  local mineSp = firstPresent("PIKACHU", "SQUIRTLE", "CHARMANDER") or "PIKACHU"
  local foeSp = firstPresent("BULBASAUR", "PIDGEY", "RATTATA") or "BULBASAUR"
  one.phase = "choose"
  one.uploaded = true
  one.mine = {
    { species = mineSp, level = 25, nickname = "SPARKY",
      hp = 40, stats = { hp = 55 },
      moves = {
        { id = "THUNDERBOLT", pp = 10, maxPp = 15 },
        { id = "QUICK_ATTACK", pp = 30, maxPp = 30 },
        { id = "THUNDER_WAVE", pp = 5, maxPp = 20 },
        { id = "GROWL", pp = 40, maxPp = 40 },
      } },
  }
  one.active = 1
  one.slots[one:foeSlot()] = {
    species = foeSp, level = 18, hp = 32, maxHp = 45, shownHp = 32,
  }
  one.slots[one:mySlot()] = {
    species = mineSp, level = 25, hp = 40, maxHp = 55, shownHp = 40,
    shownExpFrac = 0.45,
  }
  -- Four living + two fainted so the foe ball row is readable.
  one.teams = one.teams or {}
  one.teams[one:foeSlot()] = "oooxxo"
  one.npcParty = {
    { hp = 20 }, { hp = 12 }, { hp = 8 }, { hp = 0 }, { hp = 0 }, { hp = 4 },
  }
  game.stack:push(one)
  U.wait(8)
  pcall(function() one:refreshSlotSprite(one:foeSlot(), false) end)
  pcall(function() one:refreshSlotSprite(one:mySlot(), true) end)
  skipIntro(one)
  one.phase = "choose"
  U.wait(20)
  local mineSlot = one.slots[one:mySlot()]
  local foeSlot = one.slots[one:foeSlot()]
  check(mineSlot and mineSlot.sprite ~= nil, "1v1 ally back sprite loaded",
    mineSp)
  check(foeSlot and foeSlot.sprite ~= nil, "1v1 foe front sprite loaded",
    foeSp)
  if mineSlot and mineSlot.sprite then
    local ok, w, h = pcall(mineSlot.sprite.getDimensions, mineSlot.sprite)
    local _, _, scale = one:playerPicXY(mineSlot.sprite)
    log("1v1 ally pic", tostring(w) .. "x" .. tostring(h),
      "scale=" .. tostring(scale))
    check(type(scale) == "number" and scale % 1 == 0,
      "1v1 ally scale is integer", tostring(scale))
    check(scale >= 1, "1v1 ally scale is not a shrink", tostring(scale))
  end
  shot("classic-1v1-choose.png")

  -- Full-page PKMN picker: living bench in the list, preview of the
  -- highlighted mon (front pic + types / status / LV / HP / EXP).
  local benchA = firstPresent("PIDGEY", "SPEAROW", "RATTATA") or "PIDGEY"
  local benchB = firstPresent("SQUIRTLE", "CHARMANDER", "BULBASAUR") or "SQUIRTLE"
  local benchC = firstPresent("ODDISH", "BELLSPROUT", "WEEDLE") or "ODDISH"
  local benchD = firstPresent("SPEAROW", "EKANS", "VULPIX") or "SPEAROW"
  local faintSp = firstPresent("RATTATA", "CATERPIE", "WEEDLE") or "RATTATA"
  one.mine = {
    { species = mineSp, speciesId = mineSp, level = 25,
      hp = 40, maxHp = 55,
      moves = one.mine[1].moves },
    { species = benchA, speciesId = benchA, level = 18, hp = 32, maxHp = 40 },
    { species = benchB, speciesId = benchB, level = 16, hp = 28, maxHp = 35,
      status = "PAR" },
    { species = benchC, speciesId = benchC, level = 14, hp = 22, maxHp = 28 },
    { species = benchD, speciesId = benchD, level = 12, hp = 18, maxHp = 24 },
    { species = faintSp, speciesId = faintSp, level = 8, hp = 0, maxHp = 22 },
  }
  one.active = 1
  if game.save then
    local saveParty = {
      mon(mineSp, 25), mon(benchA, 18), mon(benchB, 16),
      mon(benchC, 14), mon(benchD, 12), mon(faintSp, 8),
    }
    saveParty[1].hp = 40
    saveParty[3].status = "PAR"
    saveParty[6].hp = 0
    -- Pokemon.new parks exp on the level floor (0 fill). Push each mon
    -- partway to the next level so the picker EXP pill has a real fraction.
    pcall(function()
      local Growth = require("src.pokemon.Growth")
      local rates = game.data and game.data.growth_rates
      local fracs = { 0.45, 0.20, 0.70, 0.10, 0.85, 0 }
      for i, m in ipairs(saveParty) do
        local def = m.species and pokedex[m.species]
        if def and Growth and Growth.expForLevel then
          local base = Growth.expForLevel(def.growthRate, m.level, rates)
          local after = Growth.expForLevel(def.growthRate, (m.level or 1) + 1, rates)
          if type(base) == "number" and type(after) == "number" and after > base then
            m.exp = base + math.floor((after - base) * (fracs[i] or 0.45))
          end
        end
      end
    end)
    game.save.party = saveParty
  end
  one.shown = nil
  one.anim = nil
  one.phase = "switch"
  one.switchIndex = 1
  U.wait(16)
  shot("classic-1v1-pkmn.png")
  one.switchIndex = 2
  U.wait(8)
  shot("classic-1v1-pkmn-2.png")
  one.phase = "item_party"
  one.switchIndex = 1
  U.wait(8)
  shot("classic-1v1-item-party.png")
  one.switchIndex = 6
  U.wait(8)
  shot("classic-1v1-item-party-scroll.png")
  one.phase = "choose"
  one.switchIndex = 1

  -- FIGHT: all four moves + TYPE/PP of the cursor (the empty-right-pane bug).
  one.phase = "move"
  one.cursor = 1
  U.wait(8)
  shot("classic-1v1-fight.png")
  one.cursor = 3
  U.wait(4)
  shot("classic-1v1-fight-wave.png")

  -- Message wrap: the line that used to clip at "effect".
  one.phase = "choose"
  one.shown = "It's not very effective"
  U.wait(6)
  shot("classic-1v1-effective.png")
  one.shown = "It's  not  very  effective"
  U.wait(4)
  shot("classic-1v1-effective-spaces.png")
  one.shown = nil

  -- HP mid-drain: shownHp trails truth so the bar is visibly in-between.
  local drainSlot = one.slots[one:foeSlot()]
  if drainSlot then
    drainSlot.hp = 12
    drainSlot.shownHp = 32
    drainSlot.maxHp = 45
  end
  U.wait(6)
  shot("classic-1v1-hp-mid.png")
  if drainSlot then
    drainSlot.shownHp = 12
  end

  -- Dig charge: the user vanishes; the pic must not still be on stage.
  one:startVanish("dig", { slot = one:mySlot(), side = one.mySide })
  U.wait(6)
  check(one:seatVanished(one:mySlot()) == true, "1v1 Dig charge hides the ally")
  shot("classic-1v1-dig-hide.png")
  one:clearVanishAt(one:mySlot(), one.mySide)
  check(one:seatVanished(one:mySlot()) == false, "1v1 Dig release restores the ally")
  U.wait(4)
  shot("classic-1v1-dig-back.png")

  pcall(function() game.stack:pop() end)
  U.wait(4)

  -- --------------------------------------------------------- 2x2 / 3x3
  local CoopBattle = resolve("CoopBattle")

  local function buildCoop(slots, label)
    local screen, err = CoopBattle.new(game, {
      mine = 1,
      host = true,
      mode = "coop_npc",
      battleId = "classic-" .. label,
      selfId = "host",
      classicUi = true,
      slots = slots,
    })
    if not screen then
      log("FAIL CoopBattle.new", label, tostring(err))
      fail = fail + 1
      return nil
    end
    check(screen.classicUi == true, label .. " latched classicUi")
    check(screen:usesBattlefield() == false,
      label .. " usesBattlefield is false")
    return screen
  end

  local function afterPush(screen, label)
    local keepPhase = screen.phase
    skipIntro(screen)
    if keepPhase == "target" or keepPhase == "move" then
      screen.phase = keepPhase
    end
    screen.mediated = true
    local mine = screen.sim and screen.sim:slot(1)
    if mine and mine.battler then mine.battler.shownExpFrac = 0.45 end
    U.wait(16)
    local extrasAlly = CoopBattle.stripSeats(screen, false)
    local extrasFoe = CoopBattle.stripSeats(screen, true)
    log(label, "strip seats ally=" .. tostring(#(extrasAlly or {})),
      "foe=" .. tostring(#(extrasFoe or {})))
    local allyIdx = screen:desiredAllyFocus()
    local battler = allyIdx and screen:shownBattlerAt(allyIdx)
    local sprite = battler and battler.sprite
    if sprite then
      local x, y, scale = screen:picOriginFor(allyIdx, sprite)
      local ok, w, h = pcall(sprite.getDimensions, sprite)
      log(label, "ally field", tostring(w) .. "x" .. tostring(h),
        "scale=" .. tostring(scale), "xy=" .. tostring(x) .. "," .. tostring(y))
      check(type(scale) == "number" and scale % 1 == 0,
        label .. " ally field scale is integer", tostring(scale))
      check(scale >= 1, label .. " ally field is not shrunk", tostring(scale))
    else
      log("warn", label, "no ally sprite to measure")
    end
    for _, idx in ipairs(extrasAlly or {}) do
      local icon = screen:stripIconImage(idx)
      local shown = screen:shownBattlerAt(idx)
      local usedSprite = icon == nil and shown and shown.sprite ~= nil
      check(not usedSprite,
        label .. " strip " .. tostring(idx) .. " is not the stage pic")
    end
  end

  local fainted = mon(firstPresent("RATTATA", "PIDGEY") or "RATTATA", 12)
  fainted.hp = 0
  local two = buildCoop({
    { side = "a", owner = "host", name = "CLASSIC",
      party = {
        mon(firstPresent("CHARIZARD", "CHARMANDER") or "CHARMANDER", 50),
        mon(firstPresent("PIDGEY", "SPEAROW") or "PIDGEY", 22),
        mon(firstPresent("SQUIRTLE", "WARTORTLE") or "SQUIRTLE", 20),
        mon(firstPresent("ODDISH", "BELLSPROUT") or "ODDISH", 16),
      } },
    { side = "a", owner = "friend", name = "FRIEND",
      party = { mon(firstPresent("BLASTOISE", "SQUIRTLE") or "SQUIRTLE", 50) } },
    { side = "b", owner = nil, name = "FOE",
      party = {
        mon(firstPresent("VENUSAUR", "BULBASAUR") or "BULBASAUR", 50),
        mon(firstPresent("ODDISH", "BELLSPROUT") or "ODDISH", 20),
        fainted,
      } },
    { side = "b", owner = nil, name = "FOE2",
      party = {
        mon(firstPresent("PIDGEOT", "PIDGEY") or "PIDGEY", 45),
        mon(firstPresent("SPEAROW", "PIDGEY") or "SPEAROW", 18),
      } },
  }, "2x2")
  if two then
    game.stack:push(two)
    U.wait(8)
    afterPush(two, "2x2")
    two.phase = "choose"
    U.wait(10)
    shot("classic-2x2-choose.png")
    two.phase = "switch"
    two.switchIndex = 1
    U.wait(12)
    shot("classic-2x2-pkmn.png")
    two.phase = "choose"
    two.phase = "move"
    two.moveIndex = 1
    U.wait(8)
    shot("classic-2x2-fight.png")
    two.phase = "choose"
    two.phase = "target"
    two.targetIndex = 1
    two.stageFoe = nil
    two.slideFoe = nil
    two:beginFocusSlides()
    U.wait(10)
    afterPush(two, "2x2-target")
    shot("classic-2x2-target.png")
    two.targetIndex = 2
    two:beginFocusSlides()
    U.wait(6)
    shot("classic-2x2-target-slide.png")
    U.wait(10)
    afterPush(two, "2x2-target2")
    shot("classic-2x2-target2.png")
    pcall(function() game.stack:pop() end)
    U.wait(4)
  end

  local hexFaint = mon(firstPresent("CATERPIE", "WEEDLE") or "RATTATA", 8)
  hexFaint.hp = 0
  local hex = buildCoop({
    { side = "a", owner = "host", name = "CLASSIC",
      party = { mon(firstPresent("CHARIZARD", "CHARMANDER") or "CHARMANDER", 50) } },
    { side = "a", owner = "friend", name = "FRIEND",
      party = { mon(firstPresent("BLASTOISE", "SQUIRTLE") or "SQUIRTLE", 50) } },
    { side = "a", owner = "third", name = "THIRD",
      party = { mon(firstPresent("NIDOKING", "NIDORINO") or "RATTATA", 48) } },
    { side = "b", owner = nil, name = "FOE",
      party = {
        mon(firstPresent("VENUSAUR", "BULBASAUR") or "BULBASAUR", 50),
        hexFaint,
      } },
    { side = "b", owner = nil, name = "FOE2",
      party = {
        mon(firstPresent("PIDGEOT", "PIDGEY") or "PIDGEY", 45),
        mon(firstPresent("FEAROW", "SPEAROW") or "SPEAROW", 30),
      } },
    { side = "b", owner = nil, name = "FOE3",
      party = { mon(firstPresent("ARCANINE", "GROWLITHE") or "SPEAROW", 44) } },
  }, "3x3")
  if hex then
    game.stack:push(hex)
    U.wait(8)
    afterPush(hex, "3x3")
    hex.phase = "choose"
    U.wait(10)
    shot("classic-3x3-choose.png")
    hex.phase = "target"
    hex.targetIndex = 1
    hex.stageFoe = nil
    hex.slideFoe = nil
    hex:beginFocusSlides()
    U.wait(10)
    afterPush(hex, "3x3-target")
    shot("classic-3x3-target.png")
    hex.targetIndex = 2
    hex:beginFocusSlides()
    U.wait(6)
    shot("classic-3x3-target-slide.png")
    U.wait(10)
    afterPush(hex, "3x3-target2")
    shot("classic-3x3-target2.png")
    pcall(function() game.stack:pop() end)
  end

  log("GAPS:" .. tostring(fail))
  log("DONE", pass .. " pass", fail .. " fail")
  love.event.quit(fail == 0 and 0 or 1)
end
