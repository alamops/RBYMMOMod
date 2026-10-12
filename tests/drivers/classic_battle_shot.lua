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
--
-- Then the cart's own DOUBLE screen, the one a lone trainer's double battle
-- is fought on (docs/plans/gen3-solo-doubles.md, contract C4): classic-
-- double-command-1 / -2 (the action menu with the chooser on mon 1 / mon 2),
-- -hptext (START held: HP figures for the bars), -moves-spread / -single /
-- -foes-and-ally / -self (the move menu's hover preview of who a move hits),
-- -target-<ally1|ally2|foe2|foe1>-<lit|dim> (the aim: the move menu stays up
-- and the battler aimed at blinks, both blink phases), -1foe / -1foe-spread /
-- -1ally (an empty seat), -substitutes (the cart's dolls) and -trainer (the
-- intro: the trainer's pic and the player's back pic). Each is asserted on
-- its rects (ClassicBattle.gen3DoubleLayout) and on its pixels.
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

  -- ==================================================================
  -- a lone trainer's double battle: the cart's own double screen
  -- ==================================================================
  --
  -- The view carries `double` (foes / allies of two, choosing, blink, hpText)
  -- in place of foe / ally and the strips; the frames below are what
  -- CoopBattle:gen3DoubleView hands the page. Each is checked twice: its
  -- rects (ClassicBattle.gen3DoubleLayout, pure) and its pixels, by rendering
  -- the frame beside a twin that differs in ONE thing (the chooser, the
  -- hovered move, the blink phase, START, a substitute, an empty seat) and
  -- asserting the two differ where that thing is drawn and nowhere else.
  --
  -- The singles page's pairwise "no two rects overlap" loop does not apply
  -- here: on the cart the four pics overlap one another and the healthboxes
  -- cover the pics' edges. What holds is asserted instead -- every rect on the
  -- 240x160 page, no healthbox over the textbox, the two sides' boxes apart,
  -- one side's two boxes sharing at most G3D.SIDE_BOX_SHARE rows, the blink
  -- the aimed-at pic, the preview the lit battlers' pics.
  local G3, D = ClassicBattle.G3, ClassicBattle.G3D
  -- The page clocks the frames are staged at. The cart bobs the choosing
  -- battler's pic and box (and, aiming, the target's box) a pixel or two, and
  -- a clock at which a bob is zero would hide it from a diff: at 23 the
  -- choosing pic and its box are both a pixel down, at 12 the pic and the
  -- target's box are; 12 also finds the move preview's wash partway through
  -- its first fade.
  local FRAME_CMD, FRAME_MV = 23, 12

  local function grow(r, p) return { x = r.x - p, y = r.y - p, w = r.w + 2 * p, h = r.h + 2 * p } end
  local function inRect(x, y, r) return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end
  local function sameRect(a, b)
    return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
  end
  local function rectStr(r) return ("%d,%d %dx%d"):format(r.x, r.y, r.w, r.h) end
  -- the intersection's size, 0 x 0 when the rects are apart
  local function overlap(a, b)
    local w = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
    local h = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
    if w <= 0 or h <= 0 then return 0, 0 end
    return w, h
  end

  -- `v` rendered into a private 240x160 canvas -> its ImageData (nil, why).
  local function renderOf(v)
    local saved = view
    view = v
    local ok, drew, data = pcall(renderCanvas)
    view = saved
    if ok and drew == true and data then return data end
    return nil, tostring(ok and "drawGen3 refused the view" or drew)
  end

  -- The pixels two renders differ on in the field (above the textbox): how
  -- many fall in each of `rects` (each grown by `pad`: the cart's bobs move a
  -- pic a pixel or two outside its frame), and how many in none of them.
  local function diffIn(a, b, rects, pad)
    local grown, per = {}, {}
    for i, r in ipairs(rects) do grown[i] = grow(r, pad or 0); per[i] = 0 end
    local total, outside, first = 0, 0, nil
    for y = 0, G3.PANEL_Y - 1 do
      for x = 0, W - 1 do
        local r1, g1, b1 = a:getPixel(x, y)
        local r2, g2, b2 = b:getPixel(x, y)
        if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.04 then
          total = total + 1
          local hit = false
          for i, r in ipairs(grown) do
            if inRect(x, y, r) then per[i] = per[i] + 1; hit = true end
          end
          if not hit then
            outside = outside + 1
            first = first or (x .. "," .. y)
          end
        end
      end
    end
    return { total = total, per = per, outside = outside, first = first }
  end

  -- ---- the seats, and the moves the cart's own move table offers
  local function nameOf(sp, fallback) return Gen3.speciesName(sp) or fallback end
  local dAlly1 = seat(ALLY_SP, "SPARKY", 50, 142, 155, true, { gender = "M" })
  local dAlly2 = seat(ALLY2_SP, nameOf(ALLY2_SP, "ALLY2"), 22, 18, 50, true,
    { gender = "F", status = "PAR" })
  local dFoe1 = seat(FOE_SP, nameOf(FOE_SP, "FOE1"), 18, 32, 45, false, { gender = "F" })
  local dFoe2 = seat(FOE2_SP, nameOf(FOE2_SP, "FOE2"), 20, 9, 41, false, { status = "PSN" })
  check(dAlly2.sprite ~= nil and dFoe2.sprite ~= nil,
    "double: back / front pics resolve for the second pair")

  -- MOVE_TARGET_* (pokefirered include/battle.h), the byte the cart's move
  -- menu reads: the rows below come from the cart's move table by what a move
  -- does, not by a number a driver remembers.
  local MT = { SELECTED = 0, BOTH = 8, USER = 16, FOES_AND_ALLY = 32 }
  local picks = {}
  for id = 1, 354 do
    local info = Gen3.moveInfo(id)
    if info then
      if info.target == MT.SELECTED and info.power >= 60 and not picks.single then
        picks.single = info
      elseif info.target == MT.BOTH and info.power > 0 and not picks.spread then
        picks.spread = info
      elseif info.target == MT.FOES_AND_ALLY and info.power > 0 and not picks.foesAndAlly then
        picks.foesAndAlly = info
      elseif info.target == MT.USER and info.power == 0 and info.constName == "SWORDS_DANCE" then
        picks.self = info
      end
    end
  end
  check(picks.single and picks.spread and picks.foesAndAlly and picks.self,
    "double: the cart's move table holds a single-target, a spread, a foes-and-ally and a user move",
    ("%s / %s / %s / %s"):format(picks.single and picks.single.name or "-",
      picks.spread and picks.spread.name or "-", picks.foesAndAlly and picks.foesAndAlly.name or "-",
      picks.self and picks.self.name or "-"))
  if not (picks.single and picks.spread and picks.foesAndAlly and picks.self) then
    Gen3Ui.pop(game, state)
    U.wait(4)
    return finish()
  end
  local function moveRowOf(info)
    return { label = info.name or info.constName, type = info.type, pp = info.pp, maxPp = info.pp,
             target = info.target, num = info.id }
  end
  local DMOVES = { moveRowOf(picks.single), moveRowOf(picks.spread),
                   moveRowOf(picks.foesAndAlly), moveRowOf(picks.self) }

  -- ---- views, as CoopBattle:gen3DoubleView / gen3ClassicModel build them
  local function dview(o)
    local v = {
      mode = "coop_npc", phase = o.phase, frame = o.frame or FRAME_CMD,
      double = {
        foes = o.foes or { dFoe1, dFoe2 }, allies = o.allies or { dAlly1, dAlly2 },
        choosing = o.choosing, blink = o.blink, hpText = o.hpText,
      },
      prompt = o.prompt, commands = o.commands, commandIndex = o.commandIndex,
      moves = o.moves, cursor = o.cursor, message = o.message, hint = o.hint,
      trainer = o.trainer, showTrainer = o.showTrainer,
      playerBack = o.playerBack, showPlayer = o.showPlayer,
    }
    return v
  end
  local function chooserName(choosing, allies)
    local who = (allies or { dAlly1, dAlly2 })[choosing]
    return who and who.name or "?"
  end
  local function commandView(choosing, o)
    o = o or {}
    return dview({
      choosing = choosing, frame = FRAME_CMD, hpText = o.hpText, foes = o.foes, allies = o.allies,
      prompt = ("What will\n%s do?"):format(chooserName(choosing, o.allies)),
      commands = { "FIGHT", "BAG", "POKéMON", "RUN" }, commandIndex = 1,
    })
  end
  local function moveView(cursor, choosing, o)
    o = o or {}
    return dview({
      phase = "move", choosing = choosing, frame = FRAME_MV, foes = o.foes, allies = o.allies,
      moves = DMOVES, cursor = cursor,
    })
  end
  local function targetView(side, index, since, choosing)
    return dview({
      phase = "target", choosing = choosing, frame = FRAME_MV, moves = DMOVES, cursor = 1,
      blink = { side = side, index = index, since = since },
    })
  end
  -- the same view with the move rows' target bytes taken away: the hover
  -- preview then lights nothing, and the twin differs from the view in
  -- exactly the preview's wash
  local function withoutTargets(v)
    local twin = {}
    for k, val in pairs(v) do twin[k] = val end
    twin.moves = {}
    for i, row in ipairs(v.moves) do
      local r = {}
      for k, val in pairs(row) do if k ~= "target" then r[k] = val end end
      twin.moves[i] = r
    end
    return twin
  end
  -- "a1,b1,a2,b2" keys the hovered move lights, in the cart's battler order
  local function litKeys(v)
    local mask, startY = ClassicBattle.gen3PreviewTargets(v)
    local keys = {}
    if mask and startY > 0 then
      for _, key in ipairs({ "a1", "b1", "a2", "b2" }) do
        if mask[key] then keys[#keys + 1] = key end
      end
    end
    return table.concat(keys, ",")
  end

  -- ---- the rects of one double view (pure)
  local function checkDoubleLayout(label, v)
    local dbl = v.double
    local lay = ClassicBattle.gen3DoubleLayout(v)
    local named = {}
    for k, r in pairs(lay) do
      if k == "preview" then
        for i, p in ipairs(r) do named[#named + 1] = { "preview" .. i, p } end
      elseif type(r) == "table" and r.x ~= nil then
        named[#named + 1] = { k, r }
      end
    end
    table.sort(named, function(a, b) return a[1] < b[1] end)
    -- everything lies on the 240x160 page
    local off = {}
    for _, n in ipairs(named) do
      if not inside(n[2]) then off[#off + 1] = n[1] .. "=" .. rectStr(n[2]) end
    end
    check(#off == 0, ("%s: every rect (%d) lies inside 240x160"):format(label, #named),
      table.concat(off, "; "))
    -- a battler's pic and box are in the layout exactly when its seat is up
    for i = 1, 2 do
      check((dbl.foes[i] ~= nil) == (lay["foePic" .. i] ~= nil and lay["foeBox" .. i] ~= nil),
        ("%s: foe %d has a pic and a box exactly when its seat is up"):format(label, i))
      check((dbl.allies[i] ~= nil) == (lay["allyPic" .. i] ~= nil and lay["allyBox" .. i] ~= nil),
        ("%s: ally %d has a pic and a box exactly when its seat is up"):format(label, i))
    end
    -- no healthbox over the textbox, and no pic past it (the player's are cut
    -- at it, as the cart cuts them)
    local panel = lay.panel
    for _, side in ipairs({ "foe", "ally" }) do
      for i = 1, 2 do
        local box, pic = lay[side .. "Box" .. i], lay[side .. "Pic" .. i]
        if box then
          check(box.y + box.h <= panel.y, ("%s: %sBox%d stays off the textbox"):format(label, side, i),
            rectStr(box))
        end
        if pic then
          check(pic.y + pic.h <= panel.y, ("%s: %sPic%d ends at the textbox"):format(label, side, i),
            rectStr(pic))
        end
      end
    end
    -- the two sides' healthboxes are apart
    for fi = 1, 2 do
      for ai = 1, 2 do
        local f, a = lay["foeBox" .. fi], lay["allyBox" .. ai]
        if f and a then
          local w, h = overlap(f, a)
          check(w == 0 or h == 0, ("%s: foeBox%d and allyBox%d are disjoint"):format(label, fi, ai),
            rectStr(f) .. " vs " .. rectStr(a))
        end
      end
    end
    -- one side's two boxes share at most SIDE_BOX_SHARE rows
    for _, side in ipairs({ "foe", "ally" }) do
      local one, two = lay[side .. "Box1"], lay[side .. "Box2"]
      if one and two then
        local w, h = overlap(one, two)
        check(w == 0 or h <= D.SIDE_BOX_SHARE,
          ("%s: %s boxes share at most %d row(s)"):format(label, side, D.SIDE_BOX_SHARE),
          ("share %d row(s), %d wide"):format(h, w))
      end
    end
    -- the blink is the aimed-at battler's pic
    local blink = dbl.blink
    if blink then
      local key = (blink.side == "a" and "allyPic" or "foePic") .. blink.index
      check(lay[key] ~= nil and sameRect(lay.blink, lay[key]),
        ("%s: the blink rect is the aimed-at pic (%s)"):format(label, key),
        lay.blink and rectStr(lay.blink) or "no blink rect")
    else
      check(lay.blink == nil, label .. ": no blink rect without a target")
    end
    -- the preview rects are the lit battlers' pics, in the cart's battler order
    local mask, startY = ClassicBattle.gen3PreviewTargets(v)
    local want = {}
    for _, key in ipairs({ "a1", "b1", "a2", "b2" }) do
      if mask and startY > 0 and mask[key] then
        local pic = lay[(key:sub(1, 1) == "a" and "allyPic" or "foePic") .. key:sub(2)]
        if pic then want[#want + 1] = pic end
      end
    end
    local got = lay.preview or {}
    local same = #got == #want
    for i = 1, #want do same = same and sameRect(got[i], want[i]) end
    check(same, ("%s: the preview rects are the %d lit battler pic(s)"):format(label, #want),
      ("got %d"):format(#got))
    if #want == 0 then check(lay.preview == nil, label .. ": nothing lit, so no preview rect") end
    -- the HP figures' cells exist only with START held, inside their box
    for i = 1, 2 do
      local hp, box = lay["allyHp" .. i], lay["allyBox" .. i]
      check((hp ~= nil) == (dbl.hpText == true and dbl.allies[i] ~= nil),
        ("%s: ally %d's HP-figure cell exists only with START held"):format(label, i))
      if hp and box then
        check(hp.x >= box.x and hp.y >= box.y and hp.x + hp.w <= box.x + box.w
          and hp.y + hp.h <= box.y + box.h,
          ("%s: ally %d's HP figures sit inside its box"):format(label, i), rectStr(hp) .. " in " .. rectStr(box))
      end
    end
    return lay
  end

  -- ---- one frame: rects, then pixels. -> its ImageData and layout
  local function assertDouble(label, v, opts)
    opts = opts or {}
    local lay = checkDoubleLayout(label, v)
    local data, why = renderOf(v)
    check(data ~= nil, label .. ": ClassicBattle.drawGen3 drew the double page with the cart chrome",
      tostring(why or ""))
    if not data then return nil, lay end
    for _, side in ipairs({ "foe", "ally" }) do
      for i = 1, 2 do
        local seatOf = v.double[side == "foe" and "foes" or "allies"][i]
        local box, pic = lay[side .. "Box" .. i], lay[side .. "Pic" .. i]
        if box then
          local f = creamFraction(data, box)
          check(f > 0.25, ("%s: %s healthbox %d is the cart's (cream interior)"):format(label, side, i),
            ("%.2f"):format(f))
        end
        if pic and seatOf and not seatOf.substitute and not (opts.skipPic and opts.skipPic[side .. i]) then
          local s = maxSat(data, pic)
          check(s > 0.15, ("%s: %s pic %d is drawn"):format(label, side, i), ("sat=%.2f"):format(s))
        end
      end
    end
    -- the cart's backdrop, sampled where no pic or healthbox stands
    local spot = nil
    for y = 100, 4, -12 do
      for x = 6, W - 6, 12 do
        local clear = true
        for k, r in pairs(lay) do
          if k ~= "panel" and k ~= "preview" and k ~= "blink" and type(r) == "table" and r.x ~= nil
             and inRect(x, y, grow(r, 2)) then
            clear = false
            break
          end
        end
        if clear then spot = { x = x, y = y }; break end
      end
      if spot then break end
    end
    if spot then
      local r, g, b = data:getPixel(spot.x, spot.y)
      check(r + g + b > 0.5, label .. ": the cart's battle background fills the field",
        ("%d,%d rgb=%.2f,%.2f,%.2f"):format(spot.x, spot.y, r, g, b))
    end
    return data, lay
  end

  local function stage(v)
    view = v
    U.wait(4)
  end

  -- ---- the pure clock of the target blink
  do
    local blink = { side = "b", index = 1, since = 100 }
    local ok = true
    for n = 0, 7 do ok = ok and ClassicBattle.gen3BlinkShown(blink, 100 + n) == true end
    for n = 8, 15 do ok = ok and ClassicBattle.gen3BlinkShown(blink, 100 + n) == false end
    ok = ok and ClassicBattle.gen3BlinkShown(blink, 116) == true
    ok = ok and ClassicBattle.gen3BlinkShown(blink, 99) == true
    check(ok, "double: the blink is lit 8 frames, hidden 8, and lit again as the cursor lands")
    check(ClassicBattle.gen3BlinkShown(nil, 40) == true
      and ClassicBattle.gen3BlinkShown({ side = "x", index = 9 }, 40) == true,
      "double: with no battler aimed at nothing blinks")
  end

  -- ---- frames 7 / 8: the action menu, the chooser on mon 1 then mon 2
  local cmd1, cmd2 = commandView(1), commandView(2)
  stage(cmd1)
  local dataC1, layC = assertDouble("double command 1", cmd1)
  shoot("classic-double-command-1", "double command 1")
  stage(cmd2)
  local dataC2 = assertDouble("double command 2", cmd2)
  shoot("classic-double-command-2", "double command 2")
  if dataC1 and dataC2 and layC then
    -- the cart bobs the choosing battler's pic and box: moving the chooser
    -- moves that, on the player's two battlers and boxes and nowhere else
    local rep = diffIn(dataC1, dataC2, { layC.allyPic1, layC.allyPic2, layC.allyBox1, layC.allyBox2 }, 2)
    check(rep.outside == 0, "double command: the chooser changes only the player's two battlers and boxes",
      ("outside=%d first=%s"):format(rep.outside, tostring(rep.first)))
    for i, name in ipairs({ "pic 1", "pic 2", "box 1", "box 2" }) do
      check(rep.per[i] >= 5, "double command: the chooser bobs ally " .. name, "px=" .. rep.per[i])
    end
  end

  -- ---- frame 9: START held in the action menu -- HP figures for the bars
  local hpView = commandView(1, { hpText = true })
  stage(hpView)
  local dataH, layH = assertDouble("double hptext", hpView)
  local plainH = renderOf(commandView(1))
  if dataH and plainH and layH and layH.allyHp1 and layH.allyHp2 then
    -- the figures replace the bars on the player's two boxes and nowhere else
    local rep = diffIn(dataH, plainH,
      { layH.allyBox1, layH.allyBox2, layH.allyHp1, layH.allyHp2 }, 0)
    check(rep.outside == 0, "double hptext: START changes only the player's two healthboxes",
      ("outside=%d first=%s"):format(rep.outside, tostring(rep.first)))
    check(rep.per[3] >= 20 and rep.per[4] >= 20, "double hptext: the figures are printed in their cells",
      ("px=%d/%d"):format(rep.per[3], rep.per[4]))
  else
    check(false, "double hptext: the HP-figure cells and the plain twin both render")
  end
  shoot("classic-double-hptext", "double hptext")

  -- ---- frames 10-13: the move menu's hover preview of who a move hits
  local function previewFrame(name, label, v, lit, nLit)
    stage(v)
    local data, lay = assertDouble(label, v)
    check(litKeys(v) == lit, label .. ": the hovered move lights " .. (lit ~= "" and lit or "nothing"),
      "lit=" .. litKeys(v))
    local plain = renderOf(withoutTargets(v))
    if data and plain and lay then
      local rects = lay.preview or {}
      local rep = diffIn(data, plain, rects, 2)
      if #rects > 0 then
        check(rep.outside == 0, label .. ": the preview wash stays on the lit battlers",
          ("outside=%d first=%s"):format(rep.outside, tostring(rep.first)))
        for i = 1, #rects do
          check(rep.per[i] >= 40, ("%s: lit battler %d washes towards white"):format(label, i),
            "px=" .. rep.per[i])
        end
      else
        check(rep.total == 0, label .. ": a move that lights nothing leaves the field as it was",
          "px=" .. rep.total)
      end
      check(#rects == nLit, ("%s: %d battler(s) lit"):format(label, nLit), "got " .. #rects)
    end
    shoot(name, label)
  end
  -- the chooser is on mon 1 unless said: a partner is the OTHER ally
  previewFrame("classic-double-moves-spread", "double moves spread",
    moveView(2, 1), "b1,b2", 2)
  previewFrame("classic-double-moves-single", "double moves single",
    moveView(1, 1), "", 0)
  previewFrame("classic-double-moves-foes-and-ally", "double moves foes-and-ally",
    moveView(3, 2), "a1,b1,b2", 3)
  previewFrame("classic-double-moves-self", "double moves self",
    moveView(4, 1), "a1", 1)

  -- ---- frames 14-21: the aim -- the move menu stays up, the target blinks.
  -- In the cart's ring order (allies left to right, then foes right to left);
  -- the chooser is never the target, so the first ally is aimed at from mon 2.
  local aims = {
    { "ally1", "a", 1, 2 }, { "ally2", "a", 2, 1 }, { "foe2", "b", 2, 1 }, { "foe1", "b", 1, 1 },
  }
  for _, aim in ipairs(aims) do
    local who, side, index, choosing = aim[1], aim[2], aim[3], aim[4]
    local lit = targetView(side, index, FRAME_MV, choosing)
    local dim = targetView(side, index, FRAME_MV - D.BLINK_FRAMES, choosing)
    local key = side .. index
    check(ClassicBattle.gen3BlinkShown(lit.double.blink, lit.frame) == true
      and ClassicBattle.gen3BlinkShown(dim.double.blink, dim.frame) == false,
      ("double target %s: the two staged clocks are the lit and the hidden phase"):format(who))
    stage(lit)
    local dataL, layL = assertDouble("double target " .. who .. " lit", lit)
    shoot("classic-double-target-" .. who .. "-lit", "double target " .. who .. " lit")
    stage(dim)
    local dataD = assertDouble("double target " .. who .. " dim", dim, { skipPic = { [key] = true } })
    shoot("classic-double-target-" .. who .. "-dim", "double target " .. who .. " dim")
    if dataL and dataD and layL and layL.blink then
      -- the two blink phases differ in the aimed-at battler's pic and nothing
      -- else (the bobs run on the page clock, which is the same in both)
      local rep = diffIn(dataL, dataD, { layL.blink }, 2)
      check(rep.outside == 0, ("double target %s: the blink hides only the aimed-at battler"):format(who),
        ("outside=%d first=%s"):format(rep.outside, tostring(rep.first)))
      check(rep.per[1] >= 40, ("double target %s: the aimed-at battler's pic is what blinks"):format(who),
        "px=" .. rep.per[1])
    end
  end

  -- ---- frames 22-24: an empty seat. A one-foe double: the opponent's second
  -- battler is not there, and its pic and box with it.
  local full1 = commandView(1)
  local oneFoe = commandView(1, { foes = { dFoe1 } })
  stage(oneFoe)
  local dataF, layF = assertDouble("double 1 foe", oneFoe)
  local dataFull, layFull = renderOf(full1), ClassicBattle.gen3DoubleLayout(full1)
  if dataF and dataFull and layF and layFull.foePic2 and layFull.foeBox2 then
    check(layF.foePic2 == nil and layF.foeBox2 == nil, "double 1 foe: the empty seat has no pic and no box")
    local rep = diffIn(dataF, dataFull, { layFull.foePic2, layFull.foeBox2 }, 2)
    check(rep.outside == 0, "double 1 foe: only the second foe's pic and box are missing",
      ("outside=%d first=%s"):format(rep.outside, tostring(rep.first)))
    check(rep.per[1] >= 40 and rep.per[2] >= 40, "double 1 foe: the second foe is drawn in the full double",
      ("px=%d/%d"):format(rep.per[1], rep.per[2]))
  else
    check(false, "double 1 foe: the one-foe frame and the full twin both render")
  end
  shoot("classic-double-1foe", "double 1 foe")

  -- a spread move against one foe lights that one foe (and no ghost of a second)
  previewFrame("classic-double-1foe-spread", "double 1 foe spread",
    moveView(2, 1, { foes = { dFoe1 } }), "b1,b2", 1)

  -- the player's team down to one monster: one battler out, no second box
  local oneAlly = commandView(1, { allies = { dAlly1 } })
  stage(oneAlly)
  local dataA, layA = assertDouble("double 1 ally", oneAlly)
  if dataA and dataFull and layA and layFull.allyPic2 and layFull.allyBox2 then
    check(layA.allyPic2 == nil and layA.allyBox2 == nil, "double 1 ally: the empty seat has no pic and no box")
    local rep = diffIn(dataA, dataFull, { layFull.allyPic2, layFull.allyBox2 }, 2)
    check(rep.outside == 0, "double 1 ally: only the second ally's pic and box are missing",
      ("outside=%d first=%s"):format(rep.outside, tostring(rep.first)))
    check(rep.per[1] >= 40 and rep.per[2] >= 40, "double 1 ally: the second ally is drawn in the full double",
      ("px=%d/%d"):format(rep.per[1], rep.per[2]))
  else
    check(false, "double 1 ally: the one-ally frame and the full twin both render")
  end
  shoot("classic-double-1ally", "double 1 ally")

  -- ---- frame 25: substitutes -- the cart's doll stands in on either side
  local subAlly1 = setmetatable({ substitute = true }, { __index = dAlly1 })
  local subFoe2 = setmetatable({ substitute = true }, { __index = dFoe2 })
  local subs = commandView(1, { allies = { subAlly1, dAlly2 }, foes = { dFoe1, subFoe2 } })
  stage(subs)
  local dataS, layS = assertDouble("double substitutes", subs)
  local backDoll, frontDoll = Battlefield.gen3SubstituteDoll(true), Battlefield.gen3SubstituteDoll(false)
  check(backDoll ~= nil and frontDoll ~= nil, "double substitutes: the cart's back and front dolls resolve")
  if dataS and dataFull and layS and backDoll and frontDoll then
    -- where drawDoll stands them: centred on the cart's substitute line
    local function dollRect(img, cx, cy)
      local iw, ih = img:getDimensions()
      return { x = math.floor(cx - iw / 2), y = math.floor(cy - ih / 2), w = iw, h = ih }
    end
    local dollA = dollRect(backDoll, D.ALLY_PIC_X[1], D.ALLY_DOLL_Y[1])
    local dollF = dollRect(frontDoll, D.FOE_PIC_X[2], D.FOE_DOLL_Y[2])
    check(inside(dollA) and inside(dollF), "double substitutes: both dolls lie inside 240x160",
      rectStr(dollA) .. " / " .. rectStr(dollF))
    local rep = diffIn(dataS, dataFull, { layS.allyPic1, dollA, layS.foePic2, dollF }, 2)
    check(rep.outside == 0, "double substitutes: only the two substituted battlers change",
      ("outside=%d first=%s"):format(rep.outside, tostring(rep.first)))
    check(rep.per[2] >= 40 and rep.per[4] >= 40, "double substitutes: a doll is drawn where each pic stood",
      ("px=%d/%d"):format(rep.per[2], rep.per[4]))
  else
    check(false, "double substitutes: the frame, its twin and both dolls resolve")
  end
  shoot("classic-double-substitutes", "double substitutes")

  -- ---- frame 26: the intro -- the trainer's own pic where the foes will
  -- stand, the player's back pic, a line; no battler is out yet
  -- a real lone-double trainer from the cart's own book, by what the row says
  -- (doubleBattle, a party of two or more, a name, a front pic that loads)
  local twinPic, twinLine = nil, "The trainer would like to battle!"
  pcall(function()
    local Trainers = require("src.core.game3.scripting.trainers")
    local pack = Trainers.pack() or {}
    local bestId = nil
    for id, row in pairs(pack.trainers or {}) do
      local tid = tonumber(id)
      if tid and tid > 0 and type(row) == "table" and row.doubleBattle and type(row.party) == "table"
         and #row.party >= 2 and type(row.name) == "string" and row.name ~= ""
         and type(row.className) == "string" and row.pic ~= nil
         and (bestId == nil or tid < bestId) and Battlefield.gen3TrainerPic(row.pic) then
        bestId = tid
        twinPic = row.pic
        twinLine = ("%s %s would like to battle!"):format(row.className, row.name)
      end
    end
  end)
  check(twinPic ~= nil, "double trainer: a lone-double trainer's front pic resolves from the cart's book",
    twinLine)
  twinPic = twinPic or npcPic
  local introView = dview({
    foes = {}, allies = {}, frame = FRAME_CMD,
    trainer = { pic = twinPic }, showTrainer = true,
    playerBack = { gender = 0 }, showPlayer = true,
    message = twinLine, hint = true,
  })
  stage(introView)
  local dataT, layT = assertDouble("double trainer", introView)
  check(layT ~= nil and layT.foeBox1 == nil and layT.allyBox1 == nil,
    "double trainer: no healthbox is up before a battler is")
  local trainerImg = twinPic ~= nil and Battlefield.gen3TrainerPic(twinPic) or nil
  local backEntry = Gen3.trainerBackPic(0)
  check(trainerImg ~= nil and type(backEntry) == "table" and backEntry.image ~= nil,
    "double trainer: the trainer's front pic and the player's back pic resolve")
  -- each figure is checked against a twin that lacks it: the two differ in
  -- that figure's frame and nowhere else
  local function without(v, ...)
    local twin = {}
    for k, val in pairs(v) do twin[k] = val end
    for _, k in ipairs({ ... }) do twin[k] = nil end
    return twin
  end
  if dataT and trainerImg then
    local iw, ih = trainerImg:getDimensions()
    local tr = { x = G3.TRAINER_X - math.floor(iw / 2), y = G3.TRAINER_Y - math.floor(ih / 2), w = iw, h = ih }
    check(inside(tr), "double trainer: the trainer's pic lies inside 240x160", rectStr(tr))
    check(maxSat(dataT, tr) > 0.12, "double trainer: the NPC's own front pic is drawn")
    local bare = renderOf(without(introView, "trainer", "showTrainer"))
    if bare then
      local rep = diffIn(dataT, bare, { tr }, 0)
      check(rep.outside == 0 and rep.per[1] >= 200,
        "double trainer: the trainer's pic stands where the foes will, and nowhere else",
        ("in=%d outside=%d first=%s"):format(rep.per[1], rep.outside, tostring(rep.first)))
    end
  end
  if dataT and backEntry and backEntry.image then
    local pr = { x = G3.PLAYER_BACK_X - 32, y = G3.PLAYER_BACK_Y - 32, w = 64, h = 64 }
    check(inside(pr), "double trainer: the player's back pic lies inside 240x160", rectStr(pr))
    check(maxSat(dataT, pr) > 0.12, "double trainer: the player's back pic is drawn")
    local bare = renderOf(without(introView, "playerBack", "showPlayer"))
    if bare then
      local rep = diffIn(dataT, bare, { pr }, 0)
      check(rep.outside == 0 and rep.per[1] >= 200,
        "double trainer: the player's back pic is drawn in its frame, and nowhere else",
        ("in=%d outside=%d first=%s"):format(rep.per[1], rep.outside, tostring(rep.first)))
    end
  end
  shoot("classic-double-trainer", "double trainer")

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
