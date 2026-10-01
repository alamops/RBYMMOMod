-- Committed e2e screenshot driver for the top-down battlefield arena
-- (src/Battlefield.lua) -- round 2: dark-slate plates/card, the modern band
-- widgets (drawMessagePanel/drawCommandGrid/drawListPanel) replacing the
-- stretched GB chrome, smaller mons (MON_DRAW 60), rounded-callout bubbles
-- with moveName emphasis, ball/wobble/poof/recall fx with a per-seat hidden
-- flag, and the nire/nire_hood walk-sheet requantize that stopped custom
-- chars rendering near-black. Captures PNGs to SHOT_DIR and pixel-asserts
-- these features rather than only eyeballing them.
--
--   SHOT_DIR=/path/to/inspect \
--   POKEPORT_IDENTITY=bfe2e POKEPORT_TOUCH=0 \
--   POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/battlefield_shot.lua \
--   love .
--
-- From the Gen1Recomp checkout root, with mods/rby_mmo -> RBYMMOMod. See
-- tests/drivers/run-battlefield-e2e.sh for the wrapped, gated invocation.
--
-- Unlike the throwaway spike this replaces, the mod stub below wires real
-- save/options/exports so MediatedBattle's selfSpriteId()/peerSpriteId()
-- resolve to real overworld sprite ids through their own production code
-- path -- no monkey-patching battlefieldCtx. Self reaches SPRITE_RED via
-- mod.save:get("sprite") -> Chars.resolve -> Gen.defaultSprite (Gen1
-- default when no sprite matches the stubbed registry) or, once switched to
-- SPRITE_NIRE for the third human-check frame, resolves for real through a
-- minimal mod.content.sprites registry populated by the mod's own
-- src/Cast.lua install() -- the exact path a94464f's requantize fix runs
-- through. The peer reaches SPRITE_BLUE directly through mod.exports.
-- players(), which MediatedBattle reads verbatim with no registry involved.
--
-- Captures, in order: idle (choose, RED/BLUE) -> action (choose, damage fx)
-- -> move (moves list) -> party (the switch list and its front-pic gutter)
-- -> ball (throw fx, target seat hidden from HIDEPIC on) -> bubble (rounded
-- callout) -> nire (self as SPRITE_NIRE, saturation pin) -> evolve-grace
-- (on-plate "is evolving!" before the flash) -> evolve-flash (white pulse
-- mid-swap) -> evolve-done (settled into form) -> evolve-bench (centered
-- pic for a mon that is not on a seat).
--
-- Coordinate approach (point 4 in the TT2 brief): the battlefield draws into
-- a 640x360 canvas that Renderer fill-scales to the window, aspect
-- preserved, letterboxed on whichever axis has slack
-- (src/render/Renderer.lua:700-728, `self.uiFill` branch -- Up = min(ph/uih,
-- pw/uiw)). Rather than hook render.hud (whose reported viewport is the
-- *non-fill* letterbox math and would be wrong here -- see Renderer.lua:1076-
-- 1082 vs the uiFill Up/uox/uoy a few lines above it), this driver
-- recomputes the same fill-scale transform directly from the screenshot's
-- own pixel dimensions: those stand in exactly for the physical pw/ph the
-- Renderer used, so `Up = min(imgH / Battlefield.HEIGHT, imgW /
-- Battlefield.WIDTH)` reproduces the letterbox with no dpi bookkeeping.

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

-- ======================================================================
-- Gen 3 (FireRed / Emerald): staged arena frames
-- ======================================================================
--
-- A Gen 3 boot has no `game.stack` and no MediatedBattle Gen 1 wiring to push,
-- so this arm stages the arena the way a battle screen hands it to the
-- renderer: a view ctx built from Gen 3 art (Battlefield.gen3Front / gen3Icon,
-- the OW walkers, an NPC trainer pic), drawn by a state pushed with
-- Gen3Ui.pushState whose drawsWidescreen() is true -- the live mod's render.hud
-- pass (Gen3Ui.drawWidescreen) paints it in window space, exactly the seam the
-- real screens use. Every frame is also rendered into a private 640x360 canvas
-- and pixel-asserted there, at the layout's own coordinates.
--
-- The module graph is a second one built on the live loader's sandbox
-- (loader:_api / _modEnv), so the mod facade says generation 3 and every
-- src.core.game3.* reach is the one the shipped code makes.
--
-- Frames: arena-idle (1v1, commands), arena-hit (flash + shake + a
-- Thunderbolt beam), arena-2v2 (two seats and two trainers a side), arena-npc
-- (an NPC trainer's own front pic on the foe edge), arena-party (the band's
-- POKeMON list with its front-pic gutter), and a SOLO DOUBLE
-- (docs/plans/gen3-solo-doubles.md): arena-solo-double (one player figure
-- behind two ally seats, one trainer behind two foes -- the shape
-- CoopBattle:battlefieldAllyHumans / battlefieldFoeHumans hand the arena),
-- arena-solo-double-1foe (the trainer's second seat empty) and
-- arena-solo-double-target (aiming, the partner among the targets), each with
-- its layout checks. SHOT_DIR/g3-<fr|em>-<frame>.png.
local function runGen3(game)
  io.stdout:setvbuf("no")
  local U = require("tests.drivers.util")
  local TAG = "BF_SHOT:"
  local function log(...)
    local parts = { TAG }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print(table.concat(parts, "\t"))
  end
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_bf_shots"
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

  -- ---- boot: title -> new game -> the field, then onto tall grass
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
  -- the arena's backdrop is the cart's terrain for the tile underfoot: stand in
  -- tall grass (pret MB_TALL_GRASS 0x02) so the fight is a grass one
  local grass = nil
  do
    local def = Map.currentDef and Map.currentDef()
    local layout = def and def.midLayout
    local w = layout and layout.width or 40
    local h = layout and layout.height or 40
    for y = 2, h - 3 do
      for x = 2, w - 3 do
        local ok, b = pcall(Collision.behavior, x, y)
        if ok and b == 0x02 then grass = { x = x, y = y }; break end
      end
      if grass then break end
    end
  end
  if grass then placeAt(route, grass.x, grass.y) end
  log("placed", route, grass and (grass.x .. "," .. grass.y) or "no grass found")

  -- ---- the mod's modules, on the live loader's sandbox
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
  local Battlefield = need("Battlefield")
  local Vfx = need("Vfx")
  local Gen3Ui = need("Gen3Ui")
  local Gen3 = need("Gen3")
  Battlefield.reloadArena()

  check(Battlefield.enabled(game), "the theatre gate is up on Gen 3",
    "generation " .. tostring(game.generation))

  -- ---- the art every seat and human wears
  local ALLY_SP, FOE_SP = 25, EM and 280 or 1          -- PIKACHU / TORCHIC | BULBASAUR
  local ALLY2_SP, FOE2_SP = 7, EM and 283 or 16         -- SQUIRTLE / MUDKIP | PIDGEY
  local BENCH = { 4, 19, EM and 277 or 10 }
  local function seat(sp, name, level, hp, maxHp, extra)
    local s = {
      name = name, level = level, hp = hp, maxHp = maxHp,
      front = Battlefield.gen3Front(sp), icon = Battlefield.gen3Icon(sp),
      elevation = Battlefield.gen3Elevation(sp),
    }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
  end
  local SELF_LOOK = EM and "OBJ_EVENT_GFX_BRENDAN_NORMAL" or "OBJ_EVENT_GFX_RED_NORMAL"
  local PEER_LOOK = EM and "OBJ_EVENT_GFX_MAY_NORMAL" or "OBJ_EVENT_GFX_GREEN_NORMAL"
  local PARTNER_LOOK = EM and "OBJ_EVENT_GFX_RED" or "OBJ_EVENT_GFX_RS_BRENDAN"
  local ally1 = seat(ALLY_SP, "SPARKY", 25, 40, 55, { expFrac = 0.6 })
  local foe1 = seat(FOE_SP, EM and "TORCHIC" or "BULBASAUR", 18, 32, 45)
  check(ally1.front ~= nil and foe1.front ~= nil, "Gen 3 front pics resolve for both seats")
  check(ally1.icon ~= nil, "a Gen 3 party icon record resolves", tostring(ally1.icon and ally1.icon.frames))

  -- an NPC trainer from the cart's own table, with a front pic that loads
  local npcPic, npcName = nil, "TRAINER"
  pcall(function()
    local Trainers = require("src.core.game3.scripting.trainers")
    for id = 1, 400 do
      local ok, info = pcall(Trainers.info, id)
      if ok and type(info) == "table" and info.pic ~= nil
         and Battlefield.gen3TrainerPic(info.pic) then
        npcPic = info.pic
        npcName = tostring(info.name or info.className or "TRAINER")
        break
      end
    end
  end)
  check(npcPic ~= nil, "an NPC trainer pic resolves from the cart", tostring(npcPic))

  -- ---- the staged screen
  local ctx, band = nil, nil
  local function drawBand()
    if not band then return end
    Battlefield.drawBandBackdrop()
    if band.kind == "grid" then
      Battlefield.drawCommandGrid(band.items, band.cursor or 1)
    elseif band.kind == "list" then
      Battlefield.drawListPanel(band.rows, band.cursor or 1, { title = band.title })
    else
      Battlefield.drawMessagePanel(band.text or "")
    end
  end
  local function drawArena()
    pcall(Battlefield.draw, { game = game }, ctx, { game = game })
    pcall(drawBand)
  end
  local state = {
    screenId = "BfShotGen3",
    drawsWidescreen = function() return true end,
    drawWidescreen = function(_, w, h)
      local G = love.graphics
      G.setColor(0, 0, 0, 1)
      G.rectangle("fill", 0, 0, w, h)
      local up = math.min(h / Battlefield.HEIGHT, w / Battlefield.WIDTH)
      local ox = math.floor((w - Battlefield.WIDTH * up) / 2)
      local oy = math.floor((h - Battlefield.HEIGHT * up) / 2)
      G.push()
      G.translate(ox, oy)
      G.scale(up, up)
      drawArena()
      G.pop()
      G.setColor(1, 1, 1, 1)
    end,
    draw = function() end,
    update = function() end,
  }

  -- The same frame into a private canvas, for pixel asserts at canvas
  -- coordinates (the window-space shot is for eyes).
  local function renderCanvas()
    local c = love.graphics.newCanvas(Battlefield.WIDTH, Battlefield.HEIGHT)
    love.graphics.push("all")
    love.graphics.setCanvas(c)
    love.graphics.origin()
    love.graphics.clear(0, 0, 0, 1)
    drawArena()
    love.graphics.pop()
    return c:newImageData()
  end
  local function maxSat(data, r)
    local best = 0
    local x0, y0 = math.max(0, math.floor(r.x)), math.max(0, math.floor(r.y))
    local x1 = math.min(Battlefield.WIDTH - 1, math.floor(r.x + r.w - 1))
    local y1 = math.min(Battlefield.HEIGHT - 1, math.floor(r.y + r.h - 1))
    for y = y0, y1 do
      for x = x0, x1 do
        local cr, cg, cb = data:getPixel(x, y)
        local s = math.max(math.abs(cr - cg), math.abs(cg - cb), math.abs(cr - cb))
        if s > best then best = s end
      end
    end
    return best
  end
  local function assertFrame(label)
    local ok, data = pcall(renderCanvas)
    if not (ok and data) then
      check(false, label .. ": the frame renders into a canvas", tostring(data))
      return nil
    end
    local layout = Battlefield.layout(ctx)
    for _, mon in ipairs(layout.mons) do
      if not mon.substitute then
        local r = { x = mon.x - 32, y = mon.y - 56, w = 64, h = 64 }
        local s = maxSat(data, r)
        check(s > 0.15, ("%s: %s seat %d draws saturated Gen 3 art"):format(label, mon.side, mon.seatIndex),
          ("max sat=%.2f"):format(s))
      end
    end
    for _, h in ipairs(layout.humans) do
      local r = { x = h.x - h.drawW / 2, y = h.y - h.drawH, w = h.drawW, h = h.drawH }
      if h.trainerPic ~= nil then r = { x = h.x - 32, y = h.y - 64, w = 64, h = 64 } end
      local s = maxSat(data, r)
      check(s > 0.12, ("%s: %s trainer %d is drawn (walker or trainer pic)"):format(label, h.side, h.index),
        ("max sat=%.2f"):format(s))
    end
    -- a 64px Gen 3 figure stays out of the roster chips' corner
    for _, h in ipairs(layout.humans) do
      local reach = (h.trainerPic ~= nil or h.side == "foe") and 64 or Battlefield.HUMAN_REACH3
      local fig = { x = h.x - h.drawW / 2, y = h.y - reach, w = h.drawW, h = reach }
      for _, chip in ipairs(layout.rosters) do
        local hit = fig.x < chip.x + chip.w and chip.x < fig.x + fig.w
          and fig.y < chip.y + chip.h and chip.y < fig.y + fig.h
        check(not hit, ("%s: %s trainer %d clears the %s roster chip"):format(
          label, h.side, h.index, chip.side), ("feet y=%d chip y=%d"):format(h.y, chip.y))
      end
    end
    -- the backdrop is the cart's wallpaper, not black and not the vector stand-in
    local top = maxSat(data, { x = 300, y = 4, w = 40, h = 20 })
    local r, g, b = data:getPixel(320, 200)
    check(r + g + b > 0.6, label .. ": the arena backdrop is painted", ("rgb=%.2f,%.2f,%.2f sat=%.2f"):format(r, g, b, top))
    return data, layout
  end

  local function shoot(name, label)
    U.wait(4)
    local path = ("%s/g3-%s-%s.png"):format(SHOT_DIR, V, name)
    local ok = U.shot(game, path)
    check(ok, label .. ": screenshot reached disk", path)
    return ok
  end

  local pushed = Gen3Ui.pushState(game, state)
  check(pushed ~= nil, "the staged widescreen state is on the Gen 3 stack")

  -- ---- frame 1: idle 1v1, the command grid
  ctx = {
    mode = "1v1",
    allyHumans = { { id = "self", name = "ALEX", spriteId = SELF_LOOK, party = "oosx" } },
    foeHumans = { { id = "peer", name = "BLUE", spriteId = PEER_LOOK, party = "oox",
                    version = VER, gender = 1 } },
    allySeats = { ally1 }, foeSeats = { foe1 }, frame = 0,
  }
  band = { kind = "grid", cursor = 1, items = {
    { label = "FIGHT" }, { label = "BAG" }, { label = "POKéMON" }, { label = "RUN" } } }
  U.wait(10)
  local data = assertFrame("idle")
  check(Battlefield.arena() ~= nil, "idle: the Gen 3 arena was composed from the cart's background")
  local plat = Battlefield.gen3Platform()
  check(plat ~= nil and plat.w > 64 and plat.h > 16,
    "idle: the cart's platform oval was cut out of its background",
    plat and (plat.w .. "x" .. plat.h .. " feetDy=" .. plat.feetDy) or "none")
  shoot("arena-idle", "idle")

  -- ---- frame 2: a hit -- flash + shake on the foe, and a Thunderbolt beam
  local spec = Vfx.forMove3("THUNDERBOLT", { type = 13, power = 95, effect = 6, target = 0 })
  check(spec.delivery == "beam" and spec.palette == "ELECTRIC",
    "hit: Thunderbolt resolves to its catalogue look on Gen 3", spec.style .. "/" .. spec.delivery)
  foe1.hp = 12
  foe1.shownHp = 20
  ctx.fx = {
    { kind = "flash", side = "foe", seatIndex = 1, t = 0.3 },
    { kind = "shake", side = "foe", seatIndex = 1, t = 0.35 },
    { kind = "vfx", side = "foe", seatIndex = 1, fromSide = "ally", fromSeat = 1,
      t = 0.55, style = spec.style, palette = spec.palette, delivery = spec.delivery,
      scale = spec.scale, intensity = spec.intensity, seed = 7 },
  }
  band = { kind = "message", text = "SPARKY used\nTHUNDERBOLT!" }
  U.wait(4)
  assertFrame("hit")
  shoot("arena-hit", "hit")
  ctx.fx = nil

  -- ---- frame 2b: rain over the field, and a Substitute doll in the foe seat
  ctx.fx = nil
  foe1.substitute = true
  ctx.weather = "RAIN"
  band = { kind = "message", text = "Rain continues to fall." }
  U.wait(4)
  local wdata = assertFrame("weather")
  local doll = Battlefield.gen3SubstituteDoll(false)
  check(doll ~= nil, "weather: the cart's Substitute doll resolves from the animation cache")
  if wdata then
    -- the rain's streak colour, in the corridor between the seats
    local hits = 0
    for y = 110, 250, 2 do
      for x = 280, 360, 2 do
        local r, g, b = wdata:getPixel(x, y)
        if b > 0.85 and r > 0.6 and r < 0.9 and b > r then hits = hits + 1 end
      end
    end
    check(hits > 3, "weather: rain streaks fall across the field", "hits=" .. hits)
  end
  shoot("arena-weather", "weather")
  foe1.substitute = nil
  ctx.weather = nil

  -- ---- frame 3: 2v2 -- two seats and two trainers a side
  local ally2 = seat(ALLY2_SP, EM and "MUDKIP" or "SQUIRTLE", 22, 50, 50)
  local foe2 = seat(FOE2_SP, EM and "MUDKIP" or "PIDGEY", 20, 9, 41, { status = "PSN" })
  ctx = {
    mode = "coop_npc",
    allyHumans = {
      { id = "self", name = "ALEX", spriteId = SELF_LOOK, party = "oos" },
      { id = "mate", name = "DEE", spriteId = PARTNER_LOOK, party = "oo",
        version = EM and "firered" or "emerald", gender = 0 },
    },
    foeHumans = {
      { id = "p1", name = "BLUE", spriteId = PEER_LOOK, party = "oox", version = VER, gender = 1 },
      { id = "p2", name = "ZED", spriteId = "OBJ_EVENT_GFX_YOUNGSTER", party = "ox" },
    },
    allySeats = { ally1, ally2 }, foeSeats = { foe1, foe2 }, frame = 30,
  }
  band = { kind = "message", text = "What will SPARKY do?" }
  U.wait(4)
  assertFrame("2v2")
  shoot("arena-2v2", "2v2")

  -- ---- frame 4: an NPC trainer, drawn as the cart's own front pic
  ctx = {
    mode = "1v1",
    allyHumans = { { id = "self", name = "ALEX", spriteId = SELF_LOOK, party = "oo" } },
    foeHumans = { { id = "npc", name = npcName, trainerPic = npcPic, party = "oox" } },
    allySeats = { ally1 }, foeSeats = { foe1 }, frame = 0,
  }
  band = { kind = "list", title = "MOVES", cursor = 1, rows = {
    { label = "THUNDERBOLT", tag = Gen3.typeName(13) or "ELECTRIC", right = "10/15" },
    { label = "QUICK ATTACK", tag = Gen3.typeName(0) or "NORMAL", right = "30/30" },
    { label = "THUNDER WAVE", tag = Gen3.typeName(13) or "ELECTRIC", right = "5/20" },
    { label = "GROWL", tag = Gen3.typeName(0) or "NORMAL", right = "40/40" },
  } }
  U.wait(4)
  local _, npcLayout = assertFrame("npc")
  local npcHuman = nil
  for _, h in ipairs(npcLayout and npcLayout.humans or {}) do
    if h.side == "foe" then npcHuman = h end
  end
  check(npcHuman ~= nil and npcHuman.trainerPic == npcPic,
    "npc: the foe edge carries the NPC's trainer pic id through the layout")
  shoot("arena-npc", "npc")

  -- ---- frame 5: the POKeMON list, with the front-pic gutter
  local rows = {}
  for i, sp in ipairs(BENCH) do
    rows[#rows + 1] = { label = Gen3.speciesName(sp) or ("MON " .. sp),
                        front = Battlefield.gen3Front(sp), right = (20 + i) .. "/" .. (30 + i) }
  end
  ctx = {
    mode = "1v1",
    allyHumans = { { id = "self", name = "ALEX", spriteId = SELF_LOOK, party = "oooo" } },
    foeHumans = { { id = "peer", name = "BLUE", spriteId = PEER_LOOK, party = "oox" } },
    allySeats = { ally1 }, foeSeats = { foe1 }, frame = 0,
  }
  band = { kind = "list", title = "POKeMON", cursor = 1, rows = rows }
  U.wait(4)
  data = assertFrame("party")
  local gutter = Battlefield.listPreviewRect()
  if data and gutter then
    local s = maxSat(data, { x = gutter.x, y = gutter.y, w = gutter.size, h = gutter.size })
    check(s > 0.15, "party: the gutter carries the highlighted mon's Gen 3 front pic",
      ("max sat=%.2f"):format(s))
  else
    check(false, "party: the band spares a preview gutter")
  end
  shoot("arena-party", "party")

  -- ---- frames 6-8: a SOLO DOUBLE -- one player behind two ally seats, one
  -- trainer behind two foes. The arena's layout is count-driven: a side with
  -- one figure and two seats gets the figure its own stack (centred on the
  -- field's centre line, between the pair's rows) where a side with a figure
  -- per seat pairs them row by row.
  --
  -- A real lone-double trainer from the cart's own book, by what the row says
  -- (doubleBattle, a party of two or more, a name, a front pic that loads).
  local twinPic, twinName = nil, "TRAINER"
  pcall(function()
    local Trainers = require("src.core.game3.scripting.trainers")
    local pack = Trainers.pack() or {}
    local bestId = nil
    for id, row in pairs(pack.trainers or {}) do
      local tid = tonumber(id)
      if tid and tid > 0 and type(row) == "table" and row.doubleBattle and type(row.party) == "table"
         and #row.party >= 2 and type(row.name) == "string" and row.name ~= ""
         and row.pic ~= nil and (bestId == nil or tid < bestId)
         and Battlefield.gen3TrainerPic(row.pic) then
        bestId = tid
        twinPic = row.pic
        twinName = row.name
      end
    end
  end)
  check(twinPic ~= nil, "solo double: a lone-double trainer's front pic resolves from the cart's book",
    twinName)
  twinPic = twinPic or npcPic

  -- the field slots the referee gives them: allies 0, 1; the trainer's 3, 4
  local function sdSeat(sp, name, level, hp, maxHp, index, extra)
    local e = { index = index }
    for k, v in pairs(extra or {}) do e[k] = v end
    return seat(sp, name, level, hp, maxHp, e)
  end
  local sd1 = sdSeat(ALLY_SP, "SPARKY", 25, 40, 55, 0, { expFrac = 0.6 })
  local sd2 = sdSeat(ALLY2_SP, Gen3.speciesName(ALLY2_SP) or "ALLY2", 22, 50, 50, 1, { expFrac = 0.3 })
  local sf1 = sdSeat(FOE_SP, Gen3.speciesName(FOE_SP) or "FOE1", 18, 32, 45, 3)
  local sf2 = sdSeat(FOE2_SP, Gen3.speciesName(FOE2_SP) or "FOE2", 20, 9, 41, 4, { status = "PSN" })
  local function soloCtx(foeSeats, extra)
    local c = {
      mode = "coop_npc",
      -- one player, whatever the number of seats (battlefieldAllyHumans folds
      -- the two seats of one owner into one figure) ...
      allyHumans = { { id = "solo_player", name = "ALEX", spriteId = SELF_LOOK, party = "oooo" } },
      -- ... and one trainer behind the foes (the NPC shape of
      -- battlefieldFoeHumans)
      foeHumans = { { id = "npc", name = twinName, trainerPic = twinPic, party = "ooox" } },
      allySeats = { sd1, sd2 }, foeSeats = foeSeats, frame = 0,
    }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
  end

  -- The rects the layout checks run on: a mon's 64px draw frame, a figure's
  -- reach (a walker's 16x32 frame is headroom for its top rows; a trainer
  -- pic or the foe edge reserve the whole frame), as assertFrame reads them.
  local function monBox(m) return { x = m.x - 32, y = m.y - 56, w = 64, h = 64 } end
  local function figureBox(h)
    local reach = (h.trainerPic ~= nil or h.side == "foe") and 64 or Battlefield.HUMAN_REACH3
    return { x = h.x - h.drawW / 2, y = h.y - reach, w = h.drawW, h = reach }
  end
  local function onCanvas(r)
    return r.x >= 0 and r.y >= 0 and r.x + r.w <= Battlefield.WIDTH and r.y + r.h <= Battlefield.HEIGHT
  end
  local function apart(a, b)
    return not (a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h)
  end
  local function rectStr(r) return ("%d,%d %dx%d"):format(r.x, r.y, r.w, r.h) end

  local function assertSoloDouble(label, layout, nAlly, nFoe)
    local mons, humans, things = {}, {}, {}
    local counts = { ally = 0, foe = 0, allyHumans = 0, foeHumans = 0 }
    for _, m in ipairs(layout.mons) do
      mons[#mons + 1] = { name = ("%s mon %d"):format(m.side, m.seatIndex), rect = monBox(m), m = m }
      counts[m.side] = counts[m.side] + 1
    end
    for _, h in ipairs(layout.humans) do
      humans[#humans + 1] = { name = ("%s figure %d"):format(h.side, h.index), rect = figureBox(h), h = h }
      counts[h.side .. "Humans"] = counts[h.side .. "Humans"] + 1
    end
    check(counts.ally == nAlly and counts.foe == nFoe,
      ("%s: %d ally and %d foe seats are placed"):format(label, nAlly, nFoe),
      ("got %d / %d"):format(counts.ally, counts.foe))
    check(counts.allyHumans == 1 and counts.foeHumans == 1,
      label .. ": one player figure and one trainer, whatever the seats",
      ("got %d / %d"):format(counts.allyHumans, counts.foeHumans))
    check(#layout.rosters == 2 and #layout.plates == nAlly + nFoe,
      label .. ": a roster chip for the player and the trainer, a plate per seat",
      ("%d chips, %d plates"):format(#layout.rosters, #layout.plates))

    -- everything is on the 640x360 canvas, and nothing stands in the menu band
    local off = {}
    local function onField(name, r)
      if not onCanvas(r) then off[#off + 1] = name .. "=" .. rectStr(r) end
    end
    for _, a in ipairs(mons) do onField(a.name, a.rect) end
    for _, a in ipairs(humans) do onField(a.name, a.rect) end
    for i, p in ipairs(layout.plates) do onField("plate " .. i, p) end
    for i, c in ipairs(layout.rosters) do onField("chip " .. i, c) end
    if layout.card then onField("card", layout.card) end
    check(#off == 0, label .. ": every mon, figure, plate, chip and card is on the canvas", table.concat(off, "; "))
    local lowest, lowName = 0, nil
    for _, a in ipairs(mons) do
      if a.rect.y + a.rect.h > lowest then lowest, lowName = a.rect.y + a.rect.h, a.name end
    end
    for _, a in ipairs(humans) do
      local feet = a.h.y
      if feet > lowest then lowest, lowName = feet, a.name end
    end
    check(lowest <= layout.field.y + layout.field.h,
      label .. ": nothing stands in the menu band", ("%s reaches y=%d, the field ends at %d"):format(
        tostring(lowName), lowest, layout.field.y + layout.field.h))

    -- no overlaps among what stands on the field ...
    local bad = {}
    local solids = {}
    for _, a in ipairs(mons) do solids[#solids + 1] = a end
    for _, a in ipairs(humans) do solids[#solids + 1] = a end
    for i = 1, #solids do
      for j = i + 1, #solids do
        if not apart(solids[i].rect, solids[j].rect) then
          bad[#bad + 1] = solids[i].name .. " x " .. solids[j].name
        end
      end
    end
    check(#bad == 0, label .. ": no two mons or figures overlap", table.concat(bad, "; "))
    -- ... nor among the HUD (plates, roster chips), nor the HUD over a figure
    local hud = {}
    for i, p in ipairs(layout.plates) do hud[#hud + 1] = { name = ("%s plate %d"):format(p.side, i), rect = p } end
    for i, c in ipairs(layout.rosters) do hud[#hud + 1] = { name = ("%s chip %d"):format(c.side, i), rect = c } end
    bad = {}
    for i = 1, #hud do
      for j = i + 1, #hud do
        if not apart(hud[i].rect, hud[j].rect) then bad[#bad + 1] = hud[i].name .. " x " .. hud[j].name end
      end
    end
    check(#bad == 0, label .. ": no two plates or roster chips overlap", table.concat(bad, "; "))
    bad = {}
    for _, f in ipairs(humans) do
      for _, p in ipairs(hud) do
        if not apart(f.rect, p.rect) then bad[#bad + 1] = f.name .. " x " .. p.name end
      end
    end
    check(#bad == 0, label .. ": no figure stands in a plate or a roster chip", table.concat(bad, "; "))
    bad = {}
    for _, a in ipairs(mons) do
      for _, p in ipairs(hud) do
        if not apart(a.rect, p.rect) then bad[#bad + 1] = a.name .. " x " .. p.name end
      end
    end
    check(#bad == 0, label .. ": no mon stands in a plate or a roster chip", table.concat(bad, "; "))

    -- the side's figure and its seats: a lone figure behind two seats stands
    -- within the pair's two rows (its own stack, on the field's centre line,
    -- pushed clear of the HUD); one behind one seat stands on its row
    for _, side in ipairs({ "ally", "foe" }) do
      local ys, fig = {}, nil
      for _, a in ipairs(mons) do if a.m.side == side then ys[#ys + 1] = a.m.y end end
      for _, a in ipairs(humans) do if a.h.side == side then fig = a.h end end
      if fig and #ys == 2 then
        check(math.min(ys[1], ys[2]) <= fig.y and fig.y <= math.max(ys[1], ys[2]),
          ("%s: the %s's lone figure stands within its two seats' rows"):format(label, side),
          ("figure y=%d, seats y=%d / %d"):format(fig.y, ys[1], ys[2]))
      elseif fig and #ys == 1 then
        check(fig.y == ys[1], ("%s: the %s's figure stands on its one seat's row"):format(label, side),
          ("figure y=%d, seat y=%d"):format(fig.y, ys[1]))
      end
    end
  end

  -- ---- frame 6: the whole double -- the command grid
  ctx = soloCtx({ sf1, sf2 })
  band = { kind = "grid", cursor = 1, items = {
    { label = "FIGHT" }, { label = "BAG" }, { label = "POKéMON" }, { label = "RUN" } } }
  U.wait(10)
  local _, soloLayout = assertFrame("solo double")
  if soloLayout then assertSoloDouble("solo double", soloLayout, 2, 2) end
  shoot("arena-solo-double", "solo double")

  -- ---- frame 7: the trainer's second seat empty (one foe left)
  ctx = soloCtx({ sf1 })
  band = { kind = "message", text = "What will SPARKY do?" }
  U.wait(4)
  local _, oneLayout = assertFrame("solo double 1 foe")
  if oneLayout then assertSoloDouble("solo double 1 foe", oneLayout, 2, 1) end
  shoot("arena-solo-double-1foe", "solo double 1 foe")

  -- ---- frame 8: aiming -- the partner is among the targets (the cart lets a
  -- single-target move hit it), the arrow and card over the one picked
  ctx = soloCtx({ sf1, sf2 }, {
    showTarget = true,
    targets = { { index = 3 }, { index = 4 }, { index = 1 } },
    targetIndex = 3,
  })
  band = { kind = "message", text = "Attack whom?" }
  U.wait(4)
  local _, aimLayout = assertFrame("solo double target")
  if aimLayout then
    assertSoloDouble("solo double target", aimLayout, 2, 2)
    local tm = aimLayout.target
    check(tm ~= nil and tm.side == "ally" and tm.seatIndex == 2,
      "solo double target: the picked target is the partner (ally seat 2)",
      tm and (tm.side .. " " .. tostring(tm.seatIndex)) or "no target")
    check(aimLayout.arrow ~= nil and tm ~= nil and aimLayout.arrow.x == tm.x
      and aimLayout.arrow.tipY < tm.y,
      "solo double target: the arrow points down at the partner from above")
    check(aimLayout.card ~= nil and onCanvas(aimLayout.card),
      "solo double target: the card for the picked target is on the canvas")
  end
  shoot("arena-solo-double-target", "solo double target")

  Gen3Ui.pop(game, state)
  U.wait(4)
  return finish()
end

return function(game)
  if tonumber(game and game.generation) == 3 then return runGen3(game) end
  local U = require("tests.drivers.util")
  -- H.waitFor: spin-until-predicate, budgeted in frames -- used below to
  -- drive the ball-flow queue on to HIDEPIC/wobble without pinning an exact
  -- frame count to each row's own dwell.
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local TAG = "BF_SHOT:"
  local function log(...)
    local parts = { TAG }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print(table.concat(parts, "\t"))
  end

  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_bf_shots"
  os.execute('mkdir -p "' .. SHOT_DIR .. '" 2>/dev/null')

  -- Boot to free-roam through the shared helper rather than `U.newGame`
  -- directly: Gold with POKEPORT_DRIVER already lands in free-roam (empty
  -- stack) and mashing A through a Gen 1 intro flow it does not have is how a
  -- Gold run wedges on an open Start menu. `H.bootToPlay` is the same door
  -- every other Gen 2 driver in this folder goes through.
  H.bootToPlay(game)
  local GEN = H.generation(game)
  log("generation =", tostring(GEN))
  if game.save and game.save.player then
    game.save.player.name = "RED"
  end

  local PEER_ID = "bf-e2e-peer"

  -- Minimal mod.content.sprites registry, in the exact shape src/Cast.lua's
  -- own M.install() registers (image/frames/walker/paletteSource) -- see
  -- that file's header for why those four fields are the whole contract.
  -- Without this, Chars.resolve("SPRITE_NIRE", ...) can never succeed (its
  -- M.available check needs mod.content.sprites:get to answer something),
  -- so switching saveData.sprite alone would silently keep drawing RED --
  -- Cast.install() below is what actually wires SPRITE_NIRE up for real.
  local spriteRows = {}
  local spriteRegistry = {
    register = function(_, id, record) spriteRows[id] = record end,
    get = function(_, id) return spriteRows[id] end,
    each = function(_)
      return function(_, k)
        local nk, nv = next(spriteRows, k)
        if nk then return nk, nv end
      end, spriteRows, nil
    end,
  }

  -- Proper mod facade stub: save/options/exports/content are real (if
  -- minimal) implementations rather than absent, so the production
  -- sprite-resolution code in MediatedBattle / Chars / Cast runs unmodified.
  -- The self look. Gold has no SPRITE_RED: its overworld catalog is its own,
  -- and `Gen.defaultSprite` is what every production call site resolves the
  -- boot's default walker through -- so the driver asks it rather than naming
  -- a Gen 1 id that would silently fall back and draw the wrong figure.
  -- Resolved after the resolver below exists; seeded here so the facade the
  -- resolver is handed is already shaped.
  local saveData = { sprite = nil }
  -- Forward-declared: `stub.exports.players` below closes over PEER_SPRITE,
  -- and a local declared after that closure would not be the same variable --
  -- the closure would read a global and hand the peer a nil look.
  local SELF_SPRITE, PEER_SPRITE = "SPRITE_RED", "SPRITE_BLUE"
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
    save = {
      get = function(_, key) return saveData[key] end,
      set = function(_, key, value) saveData[key] = value; return true end,
    },
    options = {
      -- Never hit for "sprite" (save answers first); kept real rather than
      -- absent so any other options:get call soft-fails to nil instead of
      -- throwing on a missing facade member.
      get = function(_, key) return nil end,
    },
    exports = {
      players = function()
        return { { id = PEER_ID, name = "BLUE", sprite = PEER_SPRITE } }
      end,
    },
    content = {
      sprites = spriteRegistry,
      -- Cast.installScales soft-fails without this (a warning, not an
      -- error) -- the top-down theatre draws humans from walk.png via
      -- resolveHumanSheet, never the battle back-pic scale, so it is not
      -- needed for anything this driver checks.
    },
  }
  local cache = {}
  local function resolve(name)
    if cache[name] then return cache[name] end
    local chunk = assert(loadfile("mods/rby_mmo/src/" .. name .. ".lua"))
    cache[name] = chunk(resolve, stub)
    return cache[name]
  end
  local Mediated = resolve("MediatedBattle")
  local Battlefield = resolve("Battlefield")
  local Cast = resolve("Cast")
  local GenMod = resolve("Gen")
  -- The particle catalogue, so this driver can ask for the same look the
  -- screen will emit rather than hard-coding a style name that would rot the
  -- first time the catalogue changed its mind about Thunderbolt.
  local Vfx = resolve("Vfx")

  -- Both looks, per generation. The peer's rides `mod.exports.players()`,
  -- which MediatedBattle reads verbatim with no registry involved, so it has
  -- to be an id the boot's catalog actually holds.
  do
    local ok, def = pcall(GenMod.defaultSprite, game)
    if ok and type(def) == "string" and def ~= "" then SELF_SPRITE = def end
    if GEN == 2 then
      -- A second, visibly different walker for the peer. Gold's catalog is
      -- keyed by its own ids, so the peer falls back to the boot default when
      -- the preferred one is absent -- two identical trainers is a worse
      -- picture than a wrong id is a failure.
      -- `Gen.spriteCatalog`, NOT `game.data.sprites` -- Gold keeps its walk
      -- sheets on `data.gen2Sprites`, and reading Gen 1's table here is the
      -- same bug this pass fixed in `src/`. It failed silently: the loop never
      -- matched, the fallback below rewrote the peer to the ally's own look,
      -- and the "foe trainer saturated" assertion then re-tested the ally
      -- while reading as if it had covered the peer.
      local sprites = GenMod.spriteCatalog(game)
      PEER_SPRITE = nil
      -- **Skipping SELF_SPRITE is the point.** `Gen.defaultSprite` answers
      -- SPRITE_CHRIS on Gold, and a candidate list that led with the same id
      -- picked it -- handing both sides the same walker while reading like it
      -- had chosen a second one. The assertion below is what caught that.
      for _, candidate in ipairs({ "SPRITE_KRIS", "SPRITE_LASS", "SPRITE_BLUE",
                                   "SPRITE_YOUNGSTER", "SPRITE_COOLTRAINER_F",
                                   "SPRITE_BUG_CATCHER" }) do
        if candidate ~= SELF_SPRITE
           and type(sprites) == "table" and sprites[candidate] then
          PEER_SPRITE = candidate
          break
        end
      end
      -- Last resort: any walker in this boot's catalog that is not our own,
      -- taken in sorted order so the pick is the same on every run.
      if not PEER_SPRITE and type(sprites) == "table" then
        local ids = {}
        for id in pairs(sprites) do
          if type(id) == "string" and id ~= SELF_SPRITE then
            ids[#ids + 1] = id
          end
        end
        table.sort(ids)
        PEER_SPRITE = ids[1]
      end
      if not PEER_SPRITE then
        -- Loud, because a silent fallback is what hid the bug above: two
        -- identical trainers still draw, so nothing else in this run would
        -- say the peer look was never independently resolved.
        log("warn", "no distinct Gen2 peer walker found; both sides will "
          .. "wear " .. tostring(SELF_SPRITE))
        PEER_SPRITE = SELF_SPRITE
      end
    end
  end
  saveData.sprite = SELF_SPRITE
  local distinctLooks = PEER_SPRITE ~= SELF_SPRITE
  log("self sprite =", SELF_SPRITE, "peer sprite =", PEER_SPRITE,
      "distinct=" .. tostring(distinctLooks))

  log("Battlefield.enabled(game) =", tostring(Battlefield.enabled(game)))
  local castOk = Cast.install()
  log("Cast.install() =", tostring(castOk), "ids=" .. table.concat(Cast.ids(), ","))

  local screen = Mediated.new({
    game = game,
    role = "host",
    peerId = PEER_ID,
    peerName = "BLUE",
    battle = "battlefield-e2e",
    transport = { send = function() return true end },
  })
  -- The two species the arena stands on. Kanto's 151 are in Gold's dex too,
  -- so the Gen 1 pair resolves on both boots -- but it is *checked* rather
  -- than assumed, because a species key the dataset does not hold resolves to
  -- no front pic and the frame under test would be an empty seat that still
  -- passed every colour assertion below.
  local MINE_SPECIES, FOE_SPECIES = "PIKACHU", "BULBASAUR"
  -- The bench the POKeMON frame lists. Three, so the panel is the shape the
  -- player actually sees (active filtered out of a four-monster party) rather
  -- than a one-row list that would never show the gutter doing its job.
  local BENCH_SPECIES = {}
  local speciesInDex = false
  do
    local pokedex = (game.data and game.data.pokemon) or {}
    local function firstPresent(...)
      for _, key in ipairs({ ... }) do
        if type(pokedex[key]) == "table" then return key end
      end
      return nil
    end
    MINE_SPECIES = firstPresent("PIKACHU", "CYNDAQUIL", "TOTODILE") or MINE_SPECIES
    FOE_SPECIES = firstPresent("BULBASAUR", "CHIKORITA", "SENTRET") or FOE_SPECIES
    BENCH_SPECIES = {
      firstPresent("NIDORINA", "RATTATA", "HOOTHOOT"),
      firstPresent("CHARMANDER", "PIDGEY", "MAREEP"),
      firstPresent("SQUIRTLE", "SPEAROW", "GEODUDE"),
    }
    log("species mine =", MINE_SPECIES, "foe =", FOE_SPECIES,
        "bench =", table.concat(BENCH_SPECIES, "/"))
    -- Recorded rather than asserted here: `check` is defined below, with the
    -- rest of the assertions, and the seed has to happen before the screen is
    -- pushed. Reported in the assertion block instead.
    speciesInDex = type(pokedex[MINE_SPECIES]) == "table"
      and type(pokedex[FOE_SPECIES]) == "table"
  end

  screen.phase = "choose"
  screen.uploaded = true
  screen.mine = {
    { species = MINE_SPECIES, level = 25, nickname = "SPARKY",
      hp = 40, stats = { hp = 55 },
      -- `maxPp`, not `ppMax`: M:bandMoveRows() (src/MediatedBattle.lua)
      -- reads `move.maxPp` for the PP column the moves-list frame
      -- exercises -- get this wrong and drawModernBand's pcall just
      -- swallows the mismatch and the frame silently falls back to the
      -- classic GB list instead of the widget under test.
      --
      -- Four moves, not one: the list draws its type and PP as *columns*
      -- measured across the visible rows, so a single-row sheet cannot show
      -- whether they line up. Two ELECTRIC and two NORMAL, with the widest
      -- name (THUNDERSHOCK) beside the widest type, is the row that runs out
      -- of width first.
      moves = {
        { id = "THUNDERSHOCK", pp = 25, maxPp = 30 },
        { id = "GROWL",        pp = 39, maxPp = 40 },
        { id = "THUNDER_WAVE", pp = 20, maxPp = 20 },
        { id = "QUICK_ATTACK", pp = 30, maxPp = 30 },
      } },
  }
  -- The bench, behind the active one. Nothing else on this screen reads past
  -- `active` (the moves list, the plates and the arena all index the seat),
  -- so these exist for the POKeMON frame alone.
  for i, key in ipairs(BENCH_SPECIES) do
    screen.mine[#screen.mine + 1] = {
      species = key, level = 20 + i, hp = 30 + i * 5, maxHp = 30 + i * 5,
      stats = { hp = 30 + i * 5 },
      moves = { { id = "THUNDERBOLT", pp = 15, maxPp = 15 } },
    }
  end
  screen.active = 1
  screen.slots[screen:foeSlot()] = {
    species = FOE_SPECIES, level = 18, hp = 32, maxHp = 45,
  }
  screen.slots[screen:mySlot()] = {
    species = MINE_SPECIES, level = 25, hp = 40, maxHp = 55,
  }
  -- The rosters the referee publishes (`team`, PROTOCOL 24), which is what
  -- the corner chips are drawn from. Seeded here rather than left to the
  -- `mine` fallback so BOTH chips are on the frame under test: the fallback
  -- only ever fills the player's own, and a foe chip that never drew is
  -- exactly the regression these assertions exist to catch. Mixed states on
  -- purpose -- a live ball, a statused one and a spent one -- so the frame
  -- exercises all three cap colours plus the empty rings past the party.
  screen.teams[screen:mySlot()] = "oosx"
  screen.teams[screen:foeSlot()] = "oox"

  -- The chip's ball run in canvas space: past the fixed name column, one
  -- pitch per slot, centred on the panel. Mirrors drawRoster's own arithmetic
  -- (src/Battlefield.lua) -- if the two ever disagree, this driver is
  -- measuring empty panel and would pass a frame with no balls on it.
  local function ballRunRect(chip)
    local x = chip.x + Battlefield.ROSTER_PAD + Battlefield.ROSTER_NAME_W
      + Battlefield.ROSTER_GAP
    local w = Battlefield.ROSTER_SLOTS * Battlefield.ROSTER_BALL_PITCH
    local r = Battlefield.ROSTER_BALL_R
    return { x = x, y = chip.y + chip.h / 2 - r, w = w, h = r * 2 }
  end

  game.stack:push(screen)
  U.wait(20)

  -- --------------------------------------------------------- assertions

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

  -- The deferred seed check (see the species block above): a key the dataset
  -- does not hold resolves to no front pic, and the frame under test would be
  -- an empty seat that still passed every colour assertion below.
  check(speciesInDex, "both seeded species are in this boot's dex",
        MINE_SPECIES .. "/" .. FOE_SPECIES)
  check(Battlefield.enabled(game),
        "the theatre gate is up for this boot", "generation " .. tostring(GEN))
  check(distinctLooks,
        "the two trainers wear different walkers, so the foe-side saturation "
        .. "checks below really do exercise the peer's own look",
        SELF_SPRITE .. " vs " .. PEER_SPRITE)

  -- Fill-scale letterbox transform, derived from the screenshot's own pixel
  -- dimensions (see header comment for why render.hud's viewport is not
  -- used here).
  local function fillTransform(imgW, imgH)
    local uiw, uih = Battlefield.WIDTH, Battlefield.HEIGHT
    local up = math.min(imgH / uih, imgW / uiw)
    local contentW, contentH = uiw * up, uih * up
    local originX = math.floor((imgW - contentW) / 2)
    local originY = math.floor((imgH - contentH) / 2)
    return function(cx, cy)
      return originX + cx * up, originY + cy * up
    end, up
  end

  local function clampInt(v, lo, hi)
    v = math.floor(v)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
  end

  -- Maximum |r-g|/|g-b|/|r-b| over a canvas-space rect, inset toward the
  -- center so alpha-keyed corners of a sprite's bounding box (which show the
  -- arena behind it, not the sprite) do not stand in for the sprite itself.
  local function maxSaturation(data, imgW, imgH, toScreen, rect, insetFrac)
    insetFrac = insetFrac or 0.25
    local ix = rect.w * insetFrac
    local iy = rect.h * insetFrac
    local x0, y0 = toScreen(rect.x + ix, rect.y + iy)
    local x1, y1 = toScreen(rect.x + rect.w - ix, rect.y + rect.h - iy)
    x0, y0 = clampInt(x0, 0, imgW - 1), clampInt(y0, 0, imgH - 1)
    x1, y1 = clampInt(x1, 0, imgW - 1), clampInt(y1, 0, imgH - 1)
    local best = 0
    for y = y0, y1 do
      for x = x0, x1 do
        local r, g, b = data:getPixel(x, y)
        local sat = math.max(math.abs(r - g), math.abs(g - b), math.abs(r - b))
        if sat > best then best = sat end
      end
    end
    return best, x1 - x0 + 1, y1 - y0 + 1
  end

  local function isNearWhite(r, g, b)
    local lo = math.min(r, g, b)
    local hi = math.max(r, g, b)
    return lo > 0.82 and (hi - lo) < 0.06
  end

  -- Antialiased 13px glyphs blend into the slate panel, so a strict
  -- near-white test sees almost nothing even when the name renders
  -- perfectly. Text detection wants "bright and neutral against a dark
  -- panel", not "paper white" -- keep isNearWhite strict for the GB-chrome
  -- check, where strictness is the point.
  local function isBrightText(r, g, b)
    local lo = math.min(r, g, b)
    local hi = math.max(r, g, b)
    return lo > 0.55 and (hi - lo) < 0.12
  end

  -- Fraction of near-white pixels over a canvas-space rect, inset a few
  -- pixels off the rounded-corner border.
  local function nearWhiteFraction(data, imgW, imgH, toScreen, rect, insetPx)
    insetPx = insetPx or 4
    local x0, y0 = toScreen(rect.x + insetPx, rect.y + insetPx)
    local x1, y1 = toScreen(rect.x + rect.w - insetPx, rect.y + rect.h - insetPx)
    x0, y0 = clampInt(x0, 0, imgW - 1), clampInt(y0, 0, imgH - 1)
    x1, y1 = clampInt(x1, 0, imgW - 1), clampInt(y1, 0, imgH - 1)
    local total, hit = 0, 0
    for y = y0, y1 do
      for x = x0, x1 do
        local r, g, b = data:getPixel(x, y)
        total = total + 1
        if isNearWhite(r, g, b) then hit = hit + 1 end
      end
    end
    if total == 0 then return 0 end
    return hit / total
  end

  -- Dark-panel test: PANEL_BG is rgb (0.078, 0.094, 0.125) at ~0.85 alpha
  -- (src/Battlefield.lua:78-83) composited over whatever the arena paints
  -- behind it, so a blended pixel stays dark and -- unlike the grass beneath
  -- it -- is never green-dominant: grass greens run g-highest, while the
  -- slate fill's own highest channel, if any, is blue. Both conditions must
  -- hold, so a bright saturated grass pixel reads as "not the panel" even if
  -- one test alone would have let it through.
  local function isSlateDark(r, g, b)
    local mx = math.max(r, g, b)
    if mx > 0.42 then return false end
    if g > r + 0.03 and g > b + 0.03 then return false end
    return true
  end

  local function darkPanelFraction(data, imgW, imgH, toScreen, rect, insetPx)
    insetPx = insetPx or 4
    local x0, y0 = toScreen(rect.x + insetPx, rect.y + insetPx)
    local x1, y1 = toScreen(rect.x + rect.w - insetPx, rect.y + rect.h - insetPx)
    x0, y0 = clampInt(x0, 0, imgW - 1), clampInt(y0, 0, imgH - 1)
    x1, y1 = clampInt(x1, 0, imgW - 1), clampInt(y1, 0, imgH - 1)
    local total, hit = 0, 0
    for y = y0, y1 do
      for x = x0, x1 do
        local r, g, b = data:getPixel(x, y)
        total = total + 1
        if isSlateDark(r, g, b) then hit = hit + 1 end
      end
    end
    if total == 0 then return 0 end
    return hit / total
  end

  -- Max, over the rows of a canvas-space rect, of that row's near-white
  -- pixel fraction. A solid dark panel reads ~0 on every row; the one row a
  -- white name/label prints on spikes -- so "does some row carry text"
  -- reads as a max rather than a whole-rect average, which the bars/pills/
  -- chips elsewhere on the same plate would dilute into looking empty.
  local function maxRowWhiteFraction(data, imgW, imgH, toScreen, rect, insetPx)
    insetPx = insetPx or 4
    local x0, y0 = toScreen(rect.x + insetPx, rect.y + insetPx)
    local x1, y1 = toScreen(rect.x + rect.w - insetPx, rect.y + rect.h - insetPx)
    x0, y0 = clampInt(x0, 0, imgW - 1), clampInt(y0, 0, imgH - 1)
    x1, y1 = clampInt(x1, 0, imgW - 1), clampInt(y1, 0, imgH - 1)
    local best = 0
    for y = y0, y1 do
      local hit, total = 0, 0
      for x = x0, x1 do
        local r, g, b = data:getPixel(x, y)
        total = total + 1
        if isBrightText(r, g, b) then hit = hit + 1 end
      end
      if total > 0 then
        local frac = hit / total
        if frac > best then best = frac end
      end
    end
    return best
  end

  local function humanRect(h)
    -- Matches drawHuman's anchor: bounding box is centered on x, feet at y
    -- (src/Battlefield.lua drawHuman -- ox = drawW/2, oy = drawH), the same
    -- box regardless of facing (a flip mirrors within the same box).
    return { x = h.x - h.drawW / 2, y = h.y - h.drawH, w = h.drawW, h = h.drawH }
  end

  -- love.image.newImageData(path) reads through love.filesystem, which is
  -- sandboxed to the save/game directory -- it cannot open the absolute
  -- SHOT_DIR path U.shot just wrote with plain io.open. Read the bytes back
  -- with io.open (same as U.shot's own existence check) and hand LOVE a
  -- FileData built from them instead.
  local function loadShot(path)
    local f, openErr = io.open(path, "rb")
    if not f then return nil, openErr end
    local bytes = f:read("*a")
    f:close()
    local ok, fileData = pcall(love.filesystem.newFileData, bytes, "shot.png")
    if not ok then return nil, fileData end
    return pcall(love.image.newImageData, fileData)
  end

  local function assertShots(path, label)
    local ok, data = loadShot(path)
    if not (ok and data) then
      check(false, label .. ": load screenshot", tostring(data))
      return
    end
    local imgW, imgH = data:getDimensions()
    local toScreen, up = fillTransform(imgW, imgH)
    log(label, "screenshot", imgW .. "x" .. imgH, "fillScale up=" .. tostring(up))

    local ctx = screen:battlefieldCtx()
    local layout = Battlefield.layout(ctx)

    -- (a) trainer regions carry saturated (non-gray) color -- both seats.
    for _, h in ipairs(layout.humans) do
      local rect = humanRect(h)
      local sat = maxSaturation(data, imgW, imgH, toScreen, rect)
      check(sat > 0.12, label .. ": " .. h.side .. " trainer saturated",
        ("max sat=%.3f rect=%d,%d %dx%d"):format(sat, rect.x, rect.y, rect.w, rect.h))
    end

    -- (b) ally plate panel is now a dark slate card (round 2 restyle), not
    -- the old near-white GB tile: assert it carries slate-dark panel fill
    -- (and is not secretly grass green showing through the translucent
    -- fill) AND still carries its white name-text row somewhere inside.
    local allyPlate = nil
    for _, p in ipairs(layout.plates) do
      if p.side == "ally" then allyPlate = p end
    end
    if allyPlate then
      local darkFrac = darkPanelFraction(data, imgW, imgH, toScreen, allyPlate)
      check(darkFrac > 0.25, label .. ": ally plate carries dark-panel fill",
        ("dark fraction=%.2f"):format(darkFrac))
      local textFrac = maxRowWhiteFraction(data, imgW, imgH, toScreen, allyPlate)
      check(textFrac > 0.03, label .. ": ally plate has a white name-text row",
        ("best row white fraction=%.3f"):format(textFrac))
    else
      check(false, label .. ": ally plate present")
    end

    -- (b2) the roster chips: one per trainer, in the two corners the plates
    -- do not use. Three things are asserted and each one fails a different
    -- regression: that both chips exist at all (the foe's is the one with no
    -- local fallback), that the panel is really painted (a layout entry with
    -- no draw behind it would pass every model test in the suite), and that
    -- the ball run inside it carries saturated colour -- a red cap -- rather
    -- than being an empty panel with a name on it.
    local chipsBySide = {}
    for _, chip in ipairs(layout.rosters) do chipsBySide[chip.side] = chip end
    for _, side in ipairs({ "ally", "foe" }) do
      local chip = chipsBySide[side]
      if chip then
        local darkFrac = darkPanelFraction(data, imgW, imgH, toScreen, chip, 3)
        check(darkFrac > 0.25, label .. ": " .. side .. " roster chip is painted",
          ("dark fraction=%.2f at %d,%d %dx%d"):format(
            darkFrac, chip.x, chip.y, chip.w, chip.h))
        local run = ballRunRect(chip)
        local sat = maxSaturation(data, imgW, imgH, toScreen, run, 0)
        check(sat > 0.12, label .. ": " .. side .. " roster chip has coloured balls",
          ("max sat=%.3f run=%d,%d %dx%d"):format(sat, run.x, run.y, run.w, run.h))
        local textFrac = maxRowWhiteFraction(data, imgW, imgH, toScreen, chip, 3)
        check(textFrac > 0.03, label .. ": " .. side .. " roster chip names its trainer",
          ("best row bright fraction=%.3f"):format(textFrac))
      else
        check(false, label .. ": " .. side .. " roster chip present")
      end
    end

    -- ...and the rule the corners were chosen for, restated against the frame
    -- that was actually drawn rather than against a hand-built layout.
    for _, chip in ipairs(layout.rosters) do
      for _, plate in ipairs(layout.plates) do
        local hit = chip.x < plate.x + plate.w and plate.x < chip.x + chip.w
          and chip.y < plate.y + plate.h and plate.y < chip.y + chip.h
        check(not hit, label .. ": no roster chip overlaps a HUD plate",
          ("chip %s at %d,%d vs %s plate at %d,%d"):format(
            chip.side, chip.x, chip.y, plate.side, plate.x, plate.y))
      end
    end

    -- (c) belt-and-braces: monDrawParams reports flip=true for the ally seat
    -- (facing == "right"), flip=false for the foe (facing == "left").
    for _, mon in ipairs(layout.mons) do
      local params = Battlefield.monDrawParams(mon, 56, 56)
      log(label, "monDrawParams", mon.side, "facing=" .. tostring(mon.facing),
        "flip=" .. tostring(params.flip))
      if mon.side == "ally" then
        check(params.flip == true, label .. ": ally mon flip==true",
          "facing=" .. tostring(mon.facing))
      else
        check(params.flip == false, label .. ": foe mon flip==false",
          "facing=" .. tostring(mon.facing))
      end
    end

    -- (d) the bottom band is modern dark-panel chrome, not the old GB
    -- white-tile chrome stretched 4x horizontally -- only meaningful while a
    -- band widget is actually up (phase == "choose" draws the FIGHT/PKMN/
    -- ITEM/RUN grid here; other phases are asserted where they're driven).
    if screen.phase == "choose" then
      local band = layout.menuBand
      local darkFrac = darkPanelFraction(data, imgW, imgH, toScreen, band, 6)
      check(darkFrac > 0.30, label .. ": menu band carries dark-panel fill",
        ("dark fraction=%.2f"):format(darkFrac))
      local whiteFrac = nearWhiteFraction(data, imgW, imgH, toScreen, band, 6)
      check(whiteFrac < 0.30,
        label .. ": menu band white fraction dropped (no GB chrome)",
        ("near-white fraction=%.2f"):format(whiteFrac))
    end
  end

  local path1 = SHOT_DIR .. "/battlefield-idle.png"
  if U.shot(game, path1) then
    log("captured", path1)
    assertShots(path1, "idle")
  else
    check(false, "idle: screenshot reached disk", path1)
  end

  -- Drive a damage frame: drop the foe's truth HP and hold the display clock
  -- part-way through the fall (mirrors what a live drain looks like
  -- mid-flight -- src/MediatedBattle.lua:2839 stepDrain -- without needing
  -- the full turn/message-queue machinery for a screenshot), plus a
  -- defender flash + field shake fx so the fx renderers get exercised too.
  local ok, err = pcall(function()
    local foeIdx = screen:foeSlot()
    local foeRow = screen.slots[foeIdx]
    foeRow.hp = 10       -- truth already moved (a move just landed)
    foeRow.shownHp = 20  -- display clock mid-fall between 32 and 10
    screen:emitFx("flash", foeIdx, "foe")
    screen:emitFx("shake", foeIdx, "foe")
  end)
  if not ok then
    log("warn", "could not drive damage frame:", tostring(err))
  end
  U.wait(6) -- let stepFx (run from screen:update each frame) advance t partway

  local path2 = SHOT_DIR .. "/battlefield-action.png"
  if U.shot(game, path2) then
    log("captured", path2)
    -- The idle-frame checks (a/b/c/d) still hold on the action frame -- fx
    -- and a lower HP must not break trainer color, plate panel, ally flip,
    -- or the band chrome.
    assertShots(path2, "action")
    local model = Battlefield.plateModel({ hp = 10, maxHp = 45, shownHp = 20 })
    check(model.frac < 0.5, "action: plate model reflects lower HP",
      ("frac=%.2f"):format(model.frac))
  else
    log("warn", "action frame did not reach disk -- idle-only run", path2)
  end

  -- ---- (b) moves-list frame: phase == "move", drawListPanel's MOVES list ----
  --
  -- The rows are asserted here rather than only photographed: the type column
  -- is resolved through the *real* TypeChart against this boot's own dataset,
  -- which is the half a fixture-stubbed unit test cannot reach. A move whose
  -- record this boot does not carry would silently drop its type and the
  -- screenshot would still look like a perfectly good moves list.
  screen.phase = "move"
  screen.cursor = 1
  do
    local moveRows = screen:bandMoveRows()
    check(#moveRows == 4, "move: one row per move on the sheet",
          "rows=" .. tostring(#moveRows))
    local tagged, tags = 0, {}
    for _, row in ipairs(moveRows) do
      if type(row.tag) == "string" and row.tag ~= "" then
        tagged = tagged + 1
        tags[#tags + 1] = row.tag
      end
    end
    check(tagged == #moveRows,
          "move: every row states its own type, resolved through the real "
          .. "TypeChart", table.concat(tags, "/"))
    check(moveRows[1].tag == "ELECTRIC" and moveRows[2].tag == "NORMAL",
          "move: the type on the row is the move's own, not the cursor's",
          tostring(moveRows[1].tag) .. " / " .. tostring(moveRows[2].tag))
    check(moveRows[1].right == "25/30",
          "move: PP still keeps its own column beside the type",
          tostring(moveRows[1].right))

    -- The cursor's memory, on the same live screen. Nothing is committed --
    -- `pickMove` is what writes it, and it opens the list where the player
    -- left it rather than back on row one.
    check(screen:rememberedMove() == 1,
          "move: a monster that has not attacked yet opens on its first move")
    screen.moveMemory = screen.moveMemory or {}
    screen.moveMemory[screen.active] = 3
    check(screen:rememberedMove() == 3,
          "move: and afterwards on the move it was last sent into a turn with")
    screen.moveMemory[screen.active] = nil
  end
  U.wait(6)
  local path3 = SHOT_DIR .. "/battlefield-move.png"
  if U.shot(game, path3) then
    log("captured", path3)
    -- Same baseline as idle/action (a/b/c); the band check inside skips
    -- itself here since screen.phase ~= "choose" -- the list panel's own
    -- shape is not asserted pixel-by-pixel, only that switching to it does
    -- not disturb the trainer/plate/flip contract.
    assertShots(path3, "move")
  else
    log("warn", "move frame did not reach disk", path3)
  end

  -- ---- (b2) POKeMON frame: the switch list, with its front-pic gutter ----
  -- The list the SWITCH command opens, which is the one list whose rows are
  -- monsters -- so `drawListPanel` reserves a gutter on its left and draws the
  -- highlighted row's battle FRONT pic in it, minimized off the same art the
  -- arena is standing on two panels up.
  --
  -- The assertion is colour, in the gutter's own rect: the band is slate and
  -- the rows are white-on-slate, so nothing else in that box is saturated. A
  -- pic that failed to resolve leaves the gutter empty, which every other
  -- check on the frame would still pass.
  screen.phase = "switch"
  screen.switchIndex = 1
  U.wait(6)
  local path3b = SHOT_DIR .. "/battlefield-party.png"
  if U.shot(game, path3b) then
    log("captured", path3b)
    assertShots(path3b, "party")
    local rows = screen:bandPartyRows(false)
    check(#rows == #BENCH_SPECIES,
      "party: the list is the bench, with the active one filtered out",
      ("%d rows"):format(#rows))
    check(type(rows[1]) == "table" and rows[1].front ~= nil,
      "party: the highlighted row carries a front pic for the gutter to draw",
      tostring(rows[1] and rows[1].front))
    local gutter = Battlefield.listPreviewRect()
    if gutter then
      local ok, data = loadShot(path3b)
      if ok and data then
        local imgW, imgH = data:getDimensions()
        local toScreen = fillTransform(imgW, imgH)
        local sat = maxSaturation(data, imgW, imgH, toScreen,
          { x = gutter.x, y = gutter.y, w = gutter.size, h = gutter.size }, 0.15)
        check(sat > 0.12,
          "party: the gutter carries a saturated monster, not empty slate",
          ("max sat=%.3f box=%d,%d %dx%d"):format(sat, gutter.x, gutter.y,
            gutter.size, gutter.size))
      else
        check(false, "party: reload screenshot for the gutter check",
          tostring(data))
      end
    else
      check(false, "party: the full-width band spares a preview gutter")
    end
  else
    log("warn", "party frame did not reach disk", path3b)
  end

  -- ---- (c) ball frame: TOSS visible in flight, hidden from HIDEPIC on ----
  -- Real chain is TOSS_ANIM -> POOF_ANIM -> HIDEPIC_ANIM -> SHAKE_ANIM x N ->
  -- ... (BattleSim/Turn.lua's _emitBallChain, mirrored in server/lib/battle).
  -- `ballTargetSlot` defaults the thrower to mySlot() when the row names
  -- neither slot nor side, so this throw lands on the foe seat.
  --
  -- The D-wave review fix retired the old "hidden the instant the ball is in
  -- the air" chronology: `hidden` is now carried by `wobble` alone
  -- (src/Battlefield.lua's fxSeat, the `wobble` branch comment) -- the arc is
  -- still a ball in the air with the mon standing where it is aimed, so TOSS
  -- reads visible; HIDEPIC's `recall` shrinks the mon into the ball through
  -- scale/alpha rather than the `hidden` flag, and only the SHAKE row that
  -- follows sets it. This drives the queue on to that row the way the unit
  -- tests do (tests/rby_mmo_test.lua's MediatedBattle wave-2 ball-flow-chain
  -- block) rather than pinning the retired chronology.
  screen.phase = "choose"
  screen.lines[#screen.lines + 1] = { anim = "TOSS_ANIM" }
  U.wait(14) -- ~0.23s @60Hz, inside the 0.60s ball hold -- lands mid-arc
  local tossFx = Battlefield.fxSeat(screen.fx, "foe", 1)
  check(tossFx.hidden == false,
    "ball: target (foe) seat stays visible while the ball is still in the air",
    "fxCount=" .. tostring(screen.fx and #screen.fx or 0))
  local throwerFx = Battlefield.fxSeat(screen.fx, "ally", 1)
  check(throwerFx.hidden == false, "ball: thrower (ally) seat stays visible")

  -- Drive the queue on: the ball opens (POOF), the mon is pulled into it
  -- (HIDEPIC), then the first wobble -- only that last row sets `hidden`.
  screen.lines[#screen.lines + 1] = { anim = "POOF_ANIM" }
  screen.lines[#screen.lines + 1] = { anim = "HIDEPIC_ANIM" }
  screen.lines[#screen.lines + 1] = { anim = "SHAKE_ANIM", amount = 1 }
  local reachedWobble = H.waitFor(game, function()
    return Battlefield.fxSeat(screen.fx, "foe", 1).hidden == true
  end, 200, "the SHAKE row's wobble to hide the foe seat")
  check(reachedWobble, "ball: the queue reaches the wobble row in bounded frames")
  local wobbleFx = Battlefield.fxSeat(screen.fx, "foe", 1)
  check(wobbleFx.hidden == true,
    "ball: the wobble that follows HIDEPIC hides the foe seat",
    "fxCount=" .. tostring(screen.fx and #screen.fx or 0))
  local path4 = SHOT_DIR .. "/battlefield-ball.png"
  if U.shot(game, path4) then
    log("captured", path4)
  else
    log("warn", "ball frame did not reach disk", path4)
  end

  -- ---- Dig / Fly vanish: charge hides the seat and holds it ----
  -- Drop the ball hold so a leftover wobble cannot steal the seat assert.
  -- The budgets are frames, and the fx clocks are seconds (the callout beat,
  -- then the dig / fly slide): a run with vsync off steps far more frames per
  -- second, so the budget is generous and the wait still ends the moment the
  -- seat hides.
  if screen.clearBallFlow then screen:clearBallFlow() end
  screen.fx = nil
  screen.ballFlow = nil
  screen.lines[#screen.lines + 1] = {
    anim = "DIG", slot = screen:mySlot(), side = "a", amount = 1,
  }
  local reachedDig = H.waitFor(game, function()
    return Battlefield.fxSeat(screen.fx, "ally", 1).hidden == true
  end, 400, "DIG charge to hide the ally seat")
  check(reachedDig, "dig: charge hides the ally seat")
  local pathDig = SHOT_DIR .. "/battlefield-dig.png"
  if U.shot(game, pathDig) then
    log("captured", pathDig)
  else
    log("warn", "dig frame did not reach disk", pathDig)
  end
  screen.lines[#screen.lines + 1] = {
    anim = "DIG", slot = screen:mySlot(), side = "a",
  }
  local emerged = H.waitFor(game, function()
    return Battlefield.fxSeat(screen.fx or {}, "ally", 1).hidden ~= true
  end, 400, "DIG release to show the ally seat")
  check(emerged, "dig: release clears the hide")

  screen.lines[#screen.lines + 1] = {
    anim = "FLY", slot = screen:foeSlot(), side = "b", amount = 1,
  }
  local reachedFly = H.waitFor(game, function()
    return Battlefield.fxSeat(screen.fx, "foe", 1).hidden == true
  end, 400, "FLY charge to hide the foe seat")
  check(reachedFly, "fly: charge hides the foe seat")

  -- ---- (d) bubble frame: rounded callout, moveName emphasised ----
  screen:noteBattlefieldBubble({ anim = "THUNDERBOLT", slot = screen:mySlot() })
  U.wait(3)
  local bubbleCtx = screen:battlefieldCtx()
  local bubbleLayout = Battlefield.layout(bubbleCtx)
  check(#bubbleLayout.bubbles >= 1, "bubble: at least one bubble placed",
    "count=" .. tostring(#bubbleLayout.bubbles))
  if bubbleLayout.bubbles[1] then
    check(bubbleLayout.bubbles[1].moveName ~= nil,
      "bubble: carries a moveName for the renderer to emphasise",
      "moveName=" .. tostring(bubbleLayout.bubbles[1].moveName))
    -- R3: the top line is the acting mon's own name ("PIKACHU!"), read off
    -- the slot noteBattlefieldBubble was told acted (screen.slots[mySlot()]
    -- is seeded PIKACHU above) -- not just the "used"/moveName pair.
    check(bubbleLayout.bubbles[1].name ~= nil,
      "bubble: carries the acting mon's name for the renderer's top line",
      "name=" .. tostring(bubbleLayout.bubbles[1].name))
  end
  local path5 = SHOT_DIR .. "/battlefield-bubble.png"
  if U.shot(game, path5) then
    log("captured", path5)
  else
    log("warn", "bubble frame did not reach disk", path5)
  end

  -- ---- (e) particles frame: a move's own effect, on the arena ----
  --
  -- The half of this feature a headless suite cannot see. `tests/rby_mmo_test`
  -- pins the catalogue, the particle math and (against a counting canvas) that
  -- every style issues primitives; what only a real LOVE can answer is whether
  -- those primitives land as *pixels on the arena*. So the frame is captured
  -- twice -- once with the effect list empty, once mid-effect -- and the two
  -- are compared for pixels in the move's own palette. Anything that leaves
  -- the effect invisible (a blend mode never restored, a colour left at zero
  -- alpha, a canvas the particles are drawn outside of) shows up as the two
  -- counts being equal.
  --
  -- Thunderbolt because the player's own move list already carries it: it is
  -- Electric, so the catalogue gives it a beam in a palette (near-white core,
  -- strong yellow body) that nothing else on a grass arena wears.
  screen.phase = "choose"
  screen.fx = nil
  screen.moveVfx = nil
  U.wait(3)

  -- **The corridor, not the whole frame.** Counting the move's colours over
  -- the entire image sounds simpler and is not usable: both monsters are drawn
  -- in it, PIKACHU is yellow, the sprites bob between two captures, and on
  -- Gold they are in full colour rather than DMG grey -- so the frame-wide
  -- count moves by more than the effect does and swings either way depending
  -- on the generation (measured: Gen 1 +143, Gold -51 for the same effect).
  --
  -- So the scan is the empty grass *between* the two seats, inset well clear
  -- of both monsters. Nothing but the arena is ever drawn there, which makes
  -- the baseline count a floor rather than a moving number, and a beam or a
  -- burst crossing it is the only thing that can raise it.
  local function corridorRect()
    local lay = Battlefield.layout(screen:battlefieldCtx())
    local ally, foe = nil, nil
    for _, mon in ipairs(lay.mons) do
      if mon.side == "ally" then ally = mon elseif mon.side == "foe" then foe = mon end
    end
    if not (ally and foe) then return nil end
    local x0 = math.min(ally.x, foe.x) + Battlefield.MON_DRAW
    local x1 = math.max(ally.x, foe.x) - Battlefield.MON_DRAW
    if x1 <= x0 then return nil end
    local cy = (ally.y + foe.y) / 2
    return { x = x0, y = cy - 18, w = x1 - x0, h = 36 }
  end

  -- Yellow, and bright: r and g high with b well behind them. Grass, slate
  -- panels and white glyphs all fail it.
  local function paletteYellowCount(data, imgW, imgH, toScreen, rect)
    if not rect then return nil end
    local x0, y0 = toScreen(rect.x, rect.y)
    local x1, y1 = toScreen(rect.x + rect.w, rect.y + rect.h)
    x0, y0 = clampInt(x0, 0, imgW - 1), clampInt(y0, 0, imgH - 1)
    x1, y1 = clampInt(x1, 0, imgW - 1), clampInt(y1, 0, imgH - 1)
    local n = 0
    for y = y0, y1 do
      for x = x0, x1 do
        local r, g, b = data:getPixel(x, y)
        if r > 0.72 and g > 0.55 and b < 0.42 and (g - b) > 0.2 then
          n = n + 1
        end
      end
    end
    return n
  end

  local corridor = corridorRect()
  check(corridor ~= nil, "particles: a corridor between the two seats to scan",
    corridor and ("x=%d w=%d"):format(corridor.x, corridor.w) or "none")

  local baseCount = nil
  local pathBase = SHOT_DIR .. "/battlefield-vfx-before.png"
  if U.shot(game, pathBase) then
    log("captured", pathBase)
    local okB, dataB = loadShot(pathBase)
    if okB and dataB then
      local wB, hB = dataB:getDimensions()
      local toScreenB = fillTransform(wB, hB)
      baseCount = paletteYellowCount(dataB, wB, hB, toScreenB, corridor)
      log("particles", "baseline corridor px", tostring(baseCount))
    end
  end

  local MOVE_ID = "THUNDERBOLT"
  local moveDef = screen:moveDefFor(MOVE_ID)
  check(moveDef ~= nil,
    "particles: the move resolves against the imported move table",
    "type=" .. tostring(moveDef and moveDef.type))
  local spec = Vfx.forMove(MOVE_ID, moveDef)
  check(spec ~= nil and spec.style ~= nil,
    "particles: the catalogue answers for it",
    "style=" .. tostring(spec and spec.style)
    .. " palette=" .. tostring(spec and spec.palette)
    .. " delivery=" .. tostring(spec and spec.delivery))

  -- `calledOut` spends the callout beat up front, so the lunge -- and the
  -- particles that ride it -- fire on this row's first pass through
  -- `startAnim`. The beat itself is what the bubble frame above covers.
  screen.lines[#screen.lines + 1] =
    { anim = MOVE_ID, slot = screen:mySlot(), side = "a", calledOut = true }
  local function liveVfx()
    for _, e in ipairs(screen.fx or {}) do
      if e.kind == "vfx" then return e end
    end
    return nil
  end
  local reachedVfx = H.waitFor(game, function() return liveVfx() ~= nil end,
    200, "the move's particles to reach the arena")
  check(reachedVfx, "particles: a move emits a vfx effect",
    "fxCount=" .. tostring(screen.fx and #screen.fx or 0))

  local entry = liveVfx()
  if entry then
    check(entry.style == spec.style,
      "particles: the effect carries the catalogue's look",
      "style=" .. tostring(entry.style))
    check(entry.palette == spec.palette,
      "particles: ...and its colours", "palette=" .. tostring(entry.palette))
    check(entry.side == "foe",
      "particles: aimed at the seat opposite the attacker",
      "side=" .. tostring(entry.side))
    check(entry.fromSide == "ally",
      "particles: launched from the attacker's own seat",
      "fromSide=" .. tostring(entry.fromSide))
    -- ...and it survives the ctx projection into the renderer's own list,
    -- which is the contract between this screen and Battlefield.
    local vfxLayout = Battlefield.layout(screen:battlefieldCtx())
    local published = nil
    for _, e in ipairs(vfxLayout.fx or {}) do
      if e.kind == "vfx" then published = e end
    end
    check(published ~= nil and published.style == spec.style,
      "particles: the effect reaches the layout the renderer draws from",
      "style=" .. tostring(published and published.style))
  end

  -- Held on the effect's own progress rather than on a frame count, so the
  -- capture lands at a known point in its life however fast the driver's
  -- clock happens to run.
  --
  -- **The timing is tuned to this move's delivery, and changing MOVE_ID means
  -- retiming it.** Thunderbolt is a beam, which is drawn at full width from
  -- t == 0.2 and starts fading at t == 0.55 -- just past the travel boundary
  -- is its brightest moment. A *thrown* move spends its first
  -- M.FX_VFX_TRAVEL as a small core out in mid-field and only then begins its
  -- burst, so the same instant catches it with almost nothing drawn and the
  -- pixel count below reads as a regression rather than as bad timing (tried;
  -- Ember lands 18 px over the baseline here against 143 for Thunderbolt).
  -- The exhaustive per-style, per-delivery coverage is the counting-canvas
  -- block in tests/rby_mmo_test.lua; this frame's job is the one thing that
  -- cannot be faked -- real pixels, on a real arena, out of a real LOVE.
  local opened = H.waitFor(game, function()
    local e = liveVfx()
    return e ~= nil and (tonumber(e.t) or 0) > Battlefield.FX_VFX_TRAVEL + 0.02
  end, 200, "the effect to reach the brightest part of its life")
  check(opened, "particles: the effect reaches its burst",
    "t=" .. tostring(liveVfx() and liveVfx().t))
  local path7 = SHOT_DIR .. "/battlefield-vfx.png"
  if U.shot(game, path7) then
    log("captured", path7)
    local ok7, data7 = loadShot(path7)
    if ok7 and data7 then
      local w7, h7 = data7:getDimensions()
      local toScreen7 = fillTransform(w7, h7)
      local fxCount = paletteYellowCount(data7, w7, h7, toScreen7, corridor)
      log("particles", "effect corridor px", tostring(fxCount))
      if baseCount and fxCount then
        -- The baseline is structurally zero -- the corridor is bare grass and
        -- nothing else is ever drawn there -- so the margin is a guard against
        -- a stray antialiased pixel rather than a tuned threshold.
        check(fxCount > baseCount + 20,
          "particles: the effect puts its own colours on the arena",
          ("baseline=%d effect=%d"):format(baseCount, fxCount))
      else
        check(false, "particles: baseline frame reached disk")
      end
    else
      check(false, "particles: load screenshot", tostring(data7))
    end
  else
    check(false, "particles: screenshot reached disk", path7)
  end

  -- ...and the effect retires on its own clock rather than sticking: a
  -- particle list that never empties is a frame that never goes quiet again.
  local retired = H.waitFor(game, function() return liveVfx() == nil end,
    200, "the effect to retire")
  check(retired, "particles: the effect retires when its span is spent",
    "fxCount=" .. tostring(screen.fx and #screen.fx or 0))

  -- ---- third human check: SELF as SPRITE_NIRE (requantize pin) ----
  -- RED and BLUE stayed the trainers for every frame above, so the (a)
  -- saturation checks there are directly comparable to wave-1's. This frame
  -- alone switches SELF to the mod's own custom character, which a94464f
  -- requantized (walk.png export residue pulled up to the exact 4 DMG
  -- shades) after it was found rendering near-black on the arena.
  screen.phase = "choose"
  saveData.sprite = "SPRITE_NIRE"
  U.wait(6)
  local path6 = SHOT_DIR .. "/battlefield-nire.png"
  if U.shot(game, path6) then
    log("captured", path6)
    local ok6, data6 = loadShot(path6)
    if ok6 and data6 then
      local imgW6, imgH6 = data6:getDimensions()
      local toScreen6 = fillTransform(imgW6, imgH6)
      local nireCtx = screen:battlefieldCtx()
      local nireLayout = Battlefield.layout(nireCtx)
      local ally = nil
      for _, h in ipairs(nireLayout.humans) do
        if h.side == "ally" then ally = h end
      end
      if ally then
        check(ally.spriteId == "SPRITE_NIRE",
          "nire: self resolved to SPRITE_NIRE (Cast.install + Chars.resolve)",
          "spriteId=" .. tostring(ally.spriteId))
        local sat = maxSaturation(data6, imgW6, imgH6, toScreen6, humanRect(ally))
        check(sat > 0.12, "nire: ally trainer saturated (requantize fix)",
          ("max sat=%.3f"):format(sat))
      else
        check(false, "nire: ally human placed")
      end
    else
      check(false, "nire: load screenshot", tostring(data6))
    end
  else
    log("warn", "nire frame did not reach disk", path6)
  end

  -- ---- mid-battle evolution movie (on-plate, then bench/center) ----
  --
  -- The rest of this driver never levels a mon, so the new EvolveFx path
  -- would otherwise leave no PNG. Stamp a well-formed movie on the live
  -- screen (same startEvolve the fight uses) and pin the clock so each
  -- capture is a known beat: grace, flash, settled, then a centered bench
  -- pic. Pixel asserts stay light -- these frames exist for eyeballing.
  local evolveOk, evolveErr = pcall(function()
    local EvolveFx = resolve("EvolveFx")
    local pokedex = (game.data and game.data.pokemon) or {}
    local function present(key)
      return type(pokedex[key]) == "table" and key or nil
    end
    local intoOnPlate = present("RAICHU") or present("CROBAT") or "RAICHU"
    local benchFrom = present(BENCH_SPECIES[1]) or present("NIDORINA")
      or present("CATERPIE") or BENCH_SPECIES[1]
    local benchInto = present("NIDOQUEEN") or present("METAPOD")
      or present("CHARMELEON") or intoOnPlate
    -- Real save mons so conclude/apply paints the evolved form. Gen 2 uses
    -- Mon.new; Gen 1 Pokemon.new. A plain table is enough for identity if
    -- both constructors miss, but then apply no-ops and the settled shot
    -- stays on "is evolving!".
    local function makeMon(species, level, nick)
      local mon
      if GEN == 2 then
        local ok, Mon = pcall(require, "src.battle.gen2.Mon")
        if ok and Mon and type(Mon.new) == "function" then
          local ran, result = pcall(Mon.new, game.data, species, level)
          if ran then mon = result end
        end
      else
        local ok, Pokemon = pcall(require, "src.pokemon.Pokemon")
        if ok and Pokemon and type(Pokemon.new) == "function" then
          local ran, result = pcall(Pokemon.new, game.data, species, level)
          if ran then mon = result end
        end
      end
      if type(mon) ~= "table" then
        mon = { species = species, level = level, hp = 40, stats = { hp = 55 } }
      end
      mon.nickname = nick
      return mon
    end
    local lead = makeMon(MINE_SPECIES, 25, "SPARKY")
    local benchMon = benchFrom and makeMon(benchFrom, 16, "BENCH") or nil
    game.save = game.save or {}
    game.save.party = { lead }
    screen.active = 1
    screen.phase = "messages"
    local started = screen:startEvolve({
      evolve = lead, from = MINE_SPECIES, into = intoOnPlate,
      via = "LEVEL", name = "SPARKY",
    })
    check(started == true, "evolve: startEvolve accepts an on-plate row")
    local movie = screen.evolving
    check(movie ~= nil and movie.center ~= true,
      "evolve: on-plate movie is tied to a seat, not centered")

    if movie then
      movie.frame = 40
      U.wait(2)
      local pathG = SHOT_DIR .. "/battlefield-evolve-grace.png"
      if U.shot(game, pathG) then
        log("captured", pathG)
        check(true, "evolve: grace frame reached disk")
      else
        check(false, "evolve: grace frame reached disk", pathG)
      end

      movie.frame = 140
      movie.done = false
      U.wait(2)
      local pathF = SHOT_DIR .. "/battlefield-evolve-flash.png"
      if U.shot(game, pathF) then
        log("captured", pathF)
        check(true, "evolve: flash frame reached disk")
      else
        check(false, "evolve: flash frame reached disk", pathF)
      end

      movie.frame = EvolveFx.FLASH_FRAMES
      movie.done = true
      movie.canceled = false
      U.wait(2)
      local pathD = SHOT_DIR .. "/battlefield-evolve-done.png"
      if U.shot(game, pathD) then
        log("captured", pathD)
        check(true, "evolve: settled frame reached disk")
      else
        check(false, "evolve: settled frame reached disk", pathD)
      end
    end

    screen.evolving = nil
    if benchMon then
      game.save.party = { lead, benchMon }
      local benchStarted = screen:startEvolve({
        evolve = benchMon, from = benchFrom, into = benchInto,
        via = "LEVEL", name = "BENCH",
      })
      check(benchStarted == true, "evolve: startEvolve accepts a bench row")
      local benchMovie = screen.evolving
      check(benchMovie ~= nil and benchMovie.center == true,
        "evolve: bench movie is centered (no seat)")
      if benchMovie then
        benchMovie.frame = 140
        benchMovie.done = false
        U.wait(2)
        local pathB = SHOT_DIR .. "/battlefield-evolve-bench.png"
        if U.shot(game, pathB) then
          log("captured", pathB)
          check(true, "evolve: bench-center frame reached disk")
        else
          check(false, "evolve: bench-center frame reached disk", pathB)
        end
      end
      screen.evolving = nil
    else
      check(false, "evolve: bench mon resolved from this boot's dex")
    end
  end)
  if not evolveOk then
    log("warn", "evolve frames threw:", tostring(evolveErr))
    check(false, "evolve: frames ran without throwing", tostring(evolveErr))
  end

  log("GAPS:" .. tostring(fail))
  log("SUMMARY", "pass=" .. pass, "fail=" .. fail)
  log("DONE")
  love.event.quit(fail > 0 and 1 or 0)
end
