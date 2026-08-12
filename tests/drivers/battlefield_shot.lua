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
-- -> move (moves list) -> ball (throw fx, target seat hidden from HIDEPIC on)
-- -> bubble (rounded callout) -> nire (self as SPRITE_NIRE, saturation pin).
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

return function(game)
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

  U.newGame(game)
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
  local saveData = { sprite = "SPRITE_RED" }
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
        return { { id = PEER_ID, name = "BLUE", sprite = "SPRITE_BLUE" } }
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
  screen.phase = "choose"
  screen.uploaded = true
  screen.mine = {
    { species = "PIKACHU", level = 25, nickname = "SPARKY",
      hp = 40, stats = { hp = 55 },
      -- `maxPp`, not `ppMax`: M:bandMoveRows() (src/MediatedBattle.lua:3565)
      -- reads `move.maxPp` for the PP column the new moves-list frame
      -- exercises -- get this wrong and drawModernBand's pcall just
      -- swallows the mismatch and the frame silently falls back to the
      -- classic GB list instead of the widget under test.
      moves = { { id = "THUNDERBOLT", pp = 15, maxPp = 15 } } },
  }
  screen.active = 1
  screen.slots[screen:foeSlot()] = {
    species = "BULBASAUR", level = 18, hp = 32, maxHp = 45,
  }
  screen.slots[screen:mySlot()] = {
    species = "PIKACHU", level = 25, hp = 40, maxHp = 55,
  }

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
  screen.phase = "move"
  screen.cursor = 1
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

  log("GAPS:" .. tostring(fail))
  log("SUMMARY", "pass=" .. pass, "fail=" .. fail)
  log("DONE")
  love.event.quit(fail > 0 and 1 or 0)
end
