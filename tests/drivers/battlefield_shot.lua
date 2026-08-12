-- Committed e2e screenshot driver for the top-down battlefield arena
-- (src/Battlefield.lua) — wave-1 checks: colored trainers, ally mon flipped
-- to face right, persistent HUD plates, fx. Captures PNGs to SHOT_DIR and
-- pixel-asserts the wave-1 features rather than only eyeballing them.
--
--   SHOT_DIR=/path/to/inspect \
--   POKEPORT_IDENTITY=bfe2e POKEPORT_TOUCH=0 \
--   POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/battlefield_shot.lua \
--   love .
--
-- From the Gen1Recomp checkout root, with mods/rby_mmo → RBYMMOMod. See
-- tests/drivers/run-battlefield-e2e.sh for the wrapped, gated invocation.
--
-- Unlike the throwaway spike this replaces, the mod stub below wires real
-- save/options/exports so MediatedBattle's selfSpriteId()/peerSpriteId()
-- resolve to real overworld sprite ids through their own production code
-- path — no monkey-patching battlefieldCtx. Self reaches SPRITE_RED via
-- mod.save:get("sprite") -> Chars.resolve -> Gen.defaultSprite (Gen1
-- default when no sprite registry is stubbed); the peer reaches SPRITE_BLUE
-- directly through mod.exports.players(), which MediatedBattle reads
-- verbatim with no registry involved.
--
-- Coordinate approach (point 4 in the TT2 brief): the battlefield draws into
-- a 640x360 canvas that Renderer fill-scales to the window, aspect
-- preserved, letterboxed on whichever axis has slack
-- (src/render/Renderer.lua:700-728, `self.uiFill` branch — Up = min(ph/uih,
-- pw/uiw)). Rather than hook render.hud (whose reported viewport is the
-- *non-fill* letterbox math and would be wrong here — see Renderer.lua:1076-
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

  -- Proper mod facade stub: save/options/exports are real (if minimal)
  -- implementations rather than absent, so the production sprite-resolution
  -- code in MediatedBattle runs unmodified.
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

  log("Battlefield.enabled(game) =", tostring(Battlefield.enabled(game)))

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
      moves = { { id = "THUNDERBOLT", pp = 15, ppMax = 15 } } },
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
        local lo = math.min(r, g, b)
        local hi = math.max(r, g, b)
        if lo > 0.82 and (hi - lo) < 0.06 then hit = hit + 1 end
      end
    end
    if total == 0 then return 0 end
    return hit / total
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

    -- (a) trainer regions carry saturated (non-gray) color — both seats.
    for _, h in ipairs(layout.humans) do
      local rect = humanRect(h)
      local sat = maxSaturation(data, imgW, imgH, toScreen, rect)
      check(sat > 0.12, label .. ": " .. h.side .. " trainer saturated",
        ("max sat=%.3f rect=%d,%d %dx%d"):format(sat, rect.x, rect.y, rect.w, rect.h))
    end

    -- (b) ally plate panel reads as a near-white HUD card.
    local allyPlate = nil
    for _, p in ipairs(layout.plates) do
      if p.side == "ally" then allyPlate = p end
    end
    if allyPlate then
      local frac = nearWhiteFraction(data, imgW, imgH, toScreen, allyPlate)
      check(frac > 0.5, label .. ": ally plate near-white",
        ("near-white fraction=%.2f"):format(frac))
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
    -- The idle-frame checks (a/b/c) still hold on the action frame -- fx and
    -- a lower HP must not break trainer color, plate panel, or ally flip.
    assertShots(path2, "action")
    local model = Battlefield.plateModel({ hp = 10, maxHp = 45, shownHp = 20 })
    check(model.frac < 0.5, "action: plate model reflects lower HP",
      ("frac=%.2f"):format(model.frac))
  else
    log("warn", "action frame did not reach disk -- idle-only run", path2)
  end

  log("GAPS:" .. tostring(fail))
  log("SUMMARY", "pass=" .. pass, "fail=" .. fail)
  log("DONE")
  love.event.quit(fail > 0 and 1 or 0)
end
