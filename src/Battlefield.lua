-- Top-down battlefield theatre for Gen1 co-op / mediated fights.
--
-- Owns arena load, seat layout, and draw helpers. CoopBattle and
-- MediatedBattle keep turn logic; they call into this for uiSize-shaped
-- presentation (640×360 fill-scale canvas). Gen2 stays on the classic
-- guild-focus path via M.enabled.
--
-- Soft-fail everywhere: a missing arena, SpriteRenderer, or icon costs
-- that layer only — never the battle screen.

local need, mod = ...
local Config = need("Config")
local Gen = need("Gen")

local M = {}

M.WIDTH = tonumber(Config.BATTLEFIELD_WIDTH) or 640
M.HEIGHT = tonumber(Config.BATTLEFIELD_HEIGHT) or 360
-- Bottom band reserved for message / command / move menus.
M.MENU_BAND = 80
M.FIELD_TOP = 0
M.FIELD_BOTTOM = M.HEIGHT - M.MENU_BAND
M.FIELD_HEIGHT = M.FIELD_BOTTOM - M.FIELD_TOP
M.MIDLINE = math.floor(M.WIDTH / 2)

-- Bag icons are 16×16; draw at 2× on the wide canvas.
M.ICON_SRC = 16
M.ICON_SCALE = 2
M.ICON_DRAW = M.ICON_SRC * M.ICON_SCALE

-- Floating target card: room for name, Lxx, HP, status, ~56px front pic.
M.CARD_W = 120
M.CARD_H = 100
M.CARD_SPRITE = 56

M.HUMAN_SCALE = 2
M.HUMAN_SRC = 16
M.HUMAN_DRAW = M.HUMAN_SRC * M.HUMAN_SCALE

local arenaImage = nil
local arenaTried = false
local humanCache = {} -- spriteId -> { image, quads } | false

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function num(v, fallback)
  local n = tonumber(v)
  if n == nil then return fallback end
  return n
end

local function listOf(t)
  if type(t) ~= "table" then return {} end
  return t
end

-- ------- Gen1 gate

function M.enabled(game)
  local ok, gen = pcall(Gen.generation, game)
  if not ok then return true end
  return (tonumber(gen) or 1) == 1
end

-- ------- asset load

function M.load(modFacade)
  modFacade = modFacade or mod
  if arenaTried then return arenaImage end
  arenaTried = true
  arenaImage = nil

  local path = Config.BATTLEFIELD_ARENA
  if type(path) ~= "string" or path == "" then return nil end

  local resolved = path
  local assets = modFacade and modFacade.assets
  if assets and assets.path then
    local ok, got = pcall(function() return assets:path(path) end)
    if ok and type(got) == "string" and got ~= "" then
      resolved = got
    end
  end

  if not (love and love.graphics and love.graphics.newImage) then
    return nil
  end

  local ok, img = pcall(love.graphics.newImage, resolved)
  if ok and img then
    pcall(function()
      if img.setFilter then img:setFilter("nearest", "nearest") end
    end)
    arenaImage = img
    return arenaImage
  end

  if modFacade and modFacade.log and modFacade.log.warn then
    modFacade.log:warn("could not load battlefield arena %s; top-down "
      .. "theatre draws without the grass plate -- reinstall the mod so "
      .. "%s is present", tostring(path), tostring(path))
  end
  return nil
end

function M.arena()
  return arenaImage
end

-- ------- pure helpers

function M.cardModel(seat)
  seat = type(seat) == "table" and seat or {}
  local name = seat.name
  if type(name) ~= "string" or name == "" then
    name = type(seat.species) == "string" and seat.species or "?"
  end
  local level = math.max(1, math.floor(num(seat.level, 1)))
  local hp = math.max(0, math.floor(num(seat.hp, 0)))
  local maxHp = math.max(1, math.floor(num(seat.maxHp, hp > 0 and hp or 1)))
  if hp > maxHp then hp = maxHp end
  local status = seat.status
  if type(status) ~= "string" or status == "" then
    status = nil
  else
    status = status:sub(1, 3)
  end
  local species = seat.species
  if type(species) ~= "string" then species = nil end
  return {
    name = name,
    level = level,
    hp = hp,
    maxHp = maxHp,
    status = status,
    species = species,
    index = seat.index,
    icon = seat.icon,
    front = seat.front or seat.frontImage or seat.sprite,
  }
end

-- dir -1 / +1; wraps. `current` is 1-based index into `targets`, or a seat
-- table matched by identity / index. Returns the new 1-based index (or nil).
function M.nextTarget(targets, current, dir)
  targets = listOf(targets)
  local n = #targets
  if n == 0 then return nil end
  dir = (tonumber(dir) or 1) >= 0 and 1 or -1

  local idx = nil
  if type(current) == "number" then
    idx = math.floor(current)
  elseif type(current) == "table" then
    for i, seat in ipairs(targets) do
      if seat == current then
        idx = i
        break
      end
      if seat and current.index ~= nil and seat.index == current.index then
        idx = i
        break
      end
    end
  end
  if not idx or idx < 1 or idx > n then idx = 1 end
  local nextIdx = ((idx - 1 + dir) % n) + 1
  return nextIdx
end

local function humanFacing(side)
  if side == "foe" then return "left" end
  return "right"
end

local function placeHumans(humans, side, out)
  humans = listOf(humans)
  local count = #humans
  if count == 0 then return end

  local facing = humanFacing(side)
  local pad = 20
  local x
  if side == "ally" then
    x = pad + math.floor(M.HUMAN_DRAW / 2)
  else
    x = M.WIDTH - pad - math.floor(M.HUMAN_DRAW / 2)
  end

  local bandTop = M.FIELD_TOP + 28
  local bandBot = M.FIELD_BOTTOM - 36
  local span = math.max(1, bandBot - bandTop)
  for i, human in ipairs(humans) do
    local t = count == 1 and 0.5 or ((i - 1) / (count - 1))
    local y = math.floor(bandTop + t * span)
    out[#out + 1] = {
      side = side,
      index = i,
      id = human and human.id,
      name = human and human.name,
      spriteId = human and human.spriteId,
      x = x,
      y = y,
      facing = facing,
      drawW = M.HUMAN_DRAW,
      drawH = M.HUMAN_DRAW,
    }
  end
end

local function placeMons(seats, side, out)
  seats = listOf(seats)
  local count = #seats
  if count == 0 then return end

  local halfPad = 36
  local left, right
  if side == "ally" then
    left = halfPad + 48
    right = M.MIDLINE - halfPad
  else
    left = M.MIDLINE + halfPad
    right = M.WIDTH - halfPad - 48
  end
  local midY = M.FIELD_TOP + math.floor(M.FIELD_HEIGHT * 0.52)
  local rowSpread = math.min(48, math.floor(M.FIELD_HEIGHT * 0.18))

  for i, seat in ipairs(seats) do
    local t = count == 1 and 0.5 or ((i - 1) / (count - 1))
    local x = math.floor(left + t * (right - left))
    local yOff = 0
    if count >= 3 then
      -- Zigzag slightly so 3–4 seats do not sit on one line.
      yOff = ((i % 2 == 0) and 1 or -1) * math.floor(rowSpread * 0.35)
    elseif count == 2 then
      yOff = (i == 1) and -math.floor(rowSpread * 0.25) or math.floor(rowSpread * 0.25)
    end
    local facing = seat and seat.facing
    if type(facing) ~= "string" then
      facing = side == "ally" and "right" or "left"
    end
    out[#out + 1] = {
      side = side,
      seatIndex = i,
      index = seat and seat.index,
      name = seat and seat.name,
      level = seat and seat.level,
      hp = seat and seat.hp,
      maxHp = seat and seat.maxHp,
      status = seat and seat.status,
      species = seat and seat.species,
      icon = seat and seat.icon,
      front = seat and (seat.front or seat.frontImage or seat.sprite),
      acting = seat and seat.acting and true or false,
      x = x,
      y = midY + yOff,
      facing = facing,
      drawW = M.ICON_DRAW,
      drawH = M.ICON_DRAW,
    }
  end
end

local function findTargetMon(mons, ctx)
  local targets = listOf(ctx.targets)
  local tip = nil
  if ctx.targetIndex ~= nil and targets[ctx.targetIndex] then
    tip = targets[ctx.targetIndex]
  elseif type(ctx.targetIndex) == "number" then
    for _, mon in ipairs(mons) do
      if mon.index == ctx.targetIndex or mon.seatIndex == ctx.targetIndex then
        tip = mon
        break
      end
    end
  end
  if tip and tip.x == nil then
    -- Target list entry may be a raw seat; match placed mon by index.
    for _, mon in ipairs(mons) do
      if tip == mon then return mon end
      if tip.index ~= nil and mon.index == tip.index then return mon end
      if tip.side and tip.seatIndex and mon.side == tip.side
          and mon.seatIndex == tip.seatIndex then
        return mon
      end
    end
    return nil
  end
  if tip then return tip end
  -- Fallback: first foe mon, else first targetable.
  for _, mon in ipairs(mons) do
    if mon.side == "foe" then return mon end
  end
  return mons[1]
end

function M.layout(ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local mode = ctx.mode
  local allyHumans = listOf(ctx.allyHumans)
  local foeHumans = listOf(ctx.foeHumans)
  -- Wild / no right-side trainers: omit foe humans even if a stale list sneaks in.
  if mode == "coop_wild" or mode == "wild" or #foeHumans == 0 then
    foeHumans = {}
  end

  local humans, mons = {}, {}
  placeHumans(allyHumans, "ally", humans)
  placeHumans(foeHumans, "foe", humans)
  placeMons(ctx.allySeats, "ally", mons)
  placeMons(ctx.foeSeats, "foe", mons)

  local targetMon = findTargetMon(mons, ctx)
  local arrow = nil
  local card = nil
  if targetMon then
    local bob = math.sin(num(ctx.frame, 0) * 0.2) * 3
    arrow = {
      x = targetMon.x,
      y = targetMon.y - math.floor(targetMon.drawH / 2) - 10 + bob,
      tipY = targetMon.y - math.floor(targetMon.drawH / 2) - 4 + bob,
    }
    local model = M.cardModel(targetMon)
    local cx = targetMon.x + 28
    local cy = targetMon.y - M.CARD_H - 8
    cx = clamp(cx, 4, M.WIDTH - M.CARD_W - 4)
    cy = clamp(cy, 4, M.FIELD_BOTTOM - M.CARD_H - 4)
    -- Prefer parking the card toward canvas center if near an edge.
    if targetMon.x > M.MIDLINE then
      cx = clamp(targetMon.x - M.CARD_W - 20, 4, M.WIDTH - M.CARD_W - 4)
    end
    card = {
      x = cx,
      y = cy,
      w = M.CARD_W,
      h = M.CARD_H,
      model = model,
      mon = targetMon,
    }
  end

  local bubbles = {}
  for _, b in ipairs(listOf(ctx.bubbles)) do
    if type(b) == "table" and (b.side == "ally" or b.side == "foe") then
      local hi = math.floor(num(b.humanIndex, 1))
      local host = nil
      for _, h in ipairs(humans) do
        if h.side == b.side and h.index == hi then
          host = h
          break
        end
      end
      if host then
        bubbles[#bubbles + 1] = {
          side = b.side,
          humanIndex = hi,
          text = type(b.text) == "string" and b.text or "",
          t = clamp(num(b.t, 1), 0, 1),
          x = host.x,
          y = host.y - math.floor(host.drawH / 2) - 6,
          human = host,
        }
      end
    end
  end

  return {
    width = M.WIDTH,
    height = M.HEIGHT,
    field = {
      x = 0,
      y = M.FIELD_TOP,
      w = M.WIDTH,
      h = M.FIELD_HEIGHT,
    },
    menuBand = {
      x = 0,
      y = M.FIELD_BOTTOM,
      w = M.WIDTH,
      h = M.MENU_BAND,
    },
    midline = M.MIDLINE,
    mode = mode,
    humans = humans,
    mons = mons,
    target = targetMon,
    arrow = arrow,
    card = card,
    bubbles = bubbles,
    frame = num(ctx.frame, 0),
  }
end

-- Aliases the plan / future callers may use.
M.seatRect = function(layoutOrMon, maybeMon)
  local mon = maybeMon or layoutOrMon
  if type(mon) ~= "table" or mon.x == nil then return nil end
  local w = mon.drawW or M.ICON_DRAW
  local h = mon.drawH or M.ICON_DRAW
  return {
    x = mon.x - math.floor(w / 2),
    y = mon.y - math.floor(h / 2),
    w = w,
    h = h,
  }
end

M.humanFacing = humanFacing

function M.targetOrder(ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local targets = listOf(ctx.targets)
  if #targets > 0 then return targets end
  local out = {}
  for _, seat in ipairs(listOf(ctx.foeSeats)) do out[#out + 1] = seat end
  for _, seat in ipairs(listOf(ctx.allySeats)) do out[#out + 1] = seat end
  return out
end

-- ------- draw helpers (all soft-fail)

local function g()
  return love and love.graphics
end

local function iconBob(frame, acting)
  local base = math.sin(frame * 0.15) * 2
  if acting then
    return base + math.abs(math.sin(frame * 0.35)) * 4
  end
  return base
end

local function truncate(text, maxChars)
  if type(text) ~= "string" then return "" end
  maxChars = maxChars or 12
  if #text <= maxChars then return text end
  return text:sub(1, math.max(1, maxChars - 1)) .. "."
end

local function resolveHumanSheet(spriteId, eng)
  if type(spriteId) ~= "string" or spriteId == "" then return nil end
  local hit = humanCache[spriteId]
  if hit ~= nil then return hit or nil end

  local entry = false
  pcall(function()
    local record = nil
    if eng and eng.sprites and type(eng.sprites[spriteId]) == "table" then
      record = eng.sprites[spriteId]
    elseif mod and mod.content and mod.content.sprites and mod.content.sprites.get then
      record = mod.content.sprites:get(spriteId)
    end
    if type(record) ~= "table" then return end

    local img = nil
    local SpriteRenderer = eng and eng.SpriteRenderer
    if not SpriteRenderer then
      local ok, SR = pcall(require, "src.render.SpriteRenderer")
      if ok then SpriteRenderer = SR end
    end
    if SpriteRenderer and SpriteRenderer.new then
      local renderer = SpriteRenderer.new(record, spriteId)
      if renderer.resolveImage then
        img = renderer:resolveImage()
      else
        img = renderer.image
      end
    end
    if not img and type(record.image) == "string" and love and love.graphics then
      local ok, loaded = pcall(love.graphics.newImage, record.image)
      if ok then img = loaded end
    end
    if not img then return end

    local fw = tonumber(record.frameWidth) or M.HUMAN_SRC
    local fh = tonumber(record.frameHeight) or M.HUMAN_SRC
    local frames = tonumber(record.frames) or 6
    local quads = {}
    if love and love.graphics and love.graphics.newQuad then
      local iw, ih = img:getDimensions()
      for f = 0, frames - 1 do
        quads[f] = love.graphics.newQuad(0, f * fh, fw, fh, iw, ih)
      end
    end
    entry = { image = img, quads = quads, fw = fw, fh = fh }
  end)

  humanCache[spriteId] = entry
  return entry or nil
end

local function drawHuman(h, frame, eng)
  local gfx = g()
  if not gfx then return end
  local sheet = resolveHumanSheet(h.spriteId, eng)
  local scale = M.HUMAN_SCALE
  local ox = math.floor(M.HUMAN_DRAW / 2)
  local oy = M.HUMAN_DRAW
  local x, y = h.x, h.y

  if sheet and sheet.image then
    local facing = h.facing or "right"
    -- Stand-left is frame 2; right is the same frame flipped.
    local frameIdx = 2
    local flip = (facing == "right")
    local quad = sheet.quads and sheet.quads[frameIdx]
    local ok = pcall(function()
      gfx.setColor(1, 1, 1, 1)
      if quad then
        local sx = flip and -scale or scale
        local dx = flip and x + ox or x - ox
        gfx.draw(sheet.image, quad, dx, y - oy, 0, sx, scale)
      else
        gfx.draw(sheet.image, x - ox, y - oy, 0, scale, scale)
      end
    end)
    if ok then return end
  end

  -- Placeholder silhouette when the walk sheet is missing.
  pcall(function()
    gfx.setColor(0.15, 0.15, 0.2, 0.85)
    gfx.rectangle("fill", x - ox, y - oy, M.HUMAN_DRAW, M.HUMAN_DRAW, 2, 2)
    gfx.setColor(1, 1, 1, 1)
  end)
end

local function drawDrawableIcon(gfx, icon, x, y, dest)
  local iw, ih = M.ICON_SRC, M.ICON_SRC
  if icon.getDimensions then
    iw, ih = icon:getDimensions()
  end
  local sx = dest / math.max(iw, 1)
  local sy = dest / math.max(ih, 1)
  gfx.draw(icon, x - dest / 2, y - dest / 2, 0, sx, sy)
end

local function drawMonIcon(mon, frame)
  local gfx = g()
  if not gfx then return end
  local bob = iconBob(frame, mon.acting)
  local x = mon.x
  local y = mon.y + bob
  local w = mon.drawW or M.ICON_DRAW
  local h = mon.drawH or M.ICON_DRAW
  local icon = mon.icon

  local drawn = false
  if icon ~= nil then
    pcall(function()
      gfx.setColor(1, 1, 1, 1)
      if type(icon) == "userdata" or (type(icon) == "table" and icon.typeOf) then
        drawDrawableIcon(gfx, icon, x, y, w)
        drawn = true
      elseif type(icon) == "string" and love.graphics.newImage then
        local ok, img = pcall(love.graphics.newImage, icon)
        if ok and img then
          drawDrawableIcon(gfx, img, x, y, w)
          drawn = true
        end
      end
    end)
  end
  if drawn then return end

  pcall(function()
    gfx.setColor(0.95, 0.85, 0.2, 0.9)
    gfx.rectangle("fill", x - w / 2, y - h / 2, w, h, 2, 2)
    gfx.setColor(0.2, 0.15, 0.05, 1)
    gfx.rectangle("line", x - w / 2, y - h / 2, w, h, 2, 2)
    gfx.setColor(1, 1, 1, 1)
  end)
end

local function drawArrow(arrow)
  local gfx = g()
  if not (gfx and arrow) then return end
  pcall(function()
    local x, y = arrow.x, arrow.tipY or arrow.y
    gfx.setColor(1, 0.2, 0.15, 1)
    gfx.polygon("fill",
      x, y + 10,
      x - 6, y,
      x + 6, y)
    gfx.setColor(1, 1, 1, 1)
  end)
end

local function drawCard(card, eng)
  local gfx = g()
  if not (gfx and card) then return end
  local model = card.model or M.cardModel(card.mon)
  pcall(function()
    local x, y, w, h = card.x, card.y, card.w, card.h
    gfx.setColor(1, 1, 1, 0.95)
    gfx.rectangle("fill", x, y, w, h, 4, 4)
    gfx.setColor(0.1, 0.1, 0.15, 1)
    gfx.rectangle("line", x, y, w, h, 4, 4)

    local pad = 6
    local sprite = model.front
    local sp = M.CARD_SPRITE
    local sx = x + w - pad - sp
    local sy = y + pad
    if sprite then
      pcall(function()
        gfx.setColor(1, 1, 1, 1)
        local iw, ih = sp, sp
        if sprite.getDimensions then iw, ih = sprite:getDimensions() end
        local sc = math.min(sp / math.max(iw, 1), sp / math.max(ih, 1))
        gfx.draw(sprite, sx, sy, 0, sc, sc)
      end)
    else
      gfx.setColor(0.85, 0.85, 0.9, 1)
      gfx.rectangle("fill", sx, sy, sp, sp)
    end

    gfx.setColor(0.05, 0.05, 0.1, 1)
    local name = truncate(model.name, 10)
    local line1 = name
    local line2 = ("L%d"):format(model.level)
    if model.status then line2 = line2 .. " " .. model.status end
    if gfx.print then
      gfx.print(line1, x + pad, y + pad)
      gfx.print(line2, x + pad, y + pad + 12)
    end

    -- HP bar
    local barX = x + pad
    local barY = y + h - pad - 10
    local barW = w - pad * 2 - (sprite and (sp + 4) or 0)
    if barW < 40 then barW = w - pad * 2 end
    local frac = 0
    if model.maxHp > 0 then frac = clamp(model.hp / model.maxHp, 0, 1) end
    gfx.setColor(0.2, 0.2, 0.25, 1)
    gfx.rectangle("fill", barX, barY, barW, 6)
    if frac > 0.5 then
      gfx.setColor(0.3, 0.75, 0.35, 1)
    elseif frac > 0.2 then
      gfx.setColor(0.85, 0.7, 0.2, 1)
    else
      gfx.setColor(0.85, 0.25, 0.2, 1)
    end
    gfx.rectangle("fill", barX, barY, math.floor(barW * frac), 6)
    gfx.setColor(1, 1, 1, 1)
  end)
end

local function drawBubble(b)
  local gfx = g()
  if not gfx then return end
  local t = clamp(num(b.t, 1), 0, 1)
  if t <= 0 then return end
  local text = truncate(b.text, 14)
  if text == "" then return end

  pcall(function()
    local scale = 0.55 + 0.45 * math.min(1, t * 1.6)
    local float = (1 - t) * -6
    local font = gfx.getFont and gfx.getFont() or nil
    local tw = font and font:getWidth(text) or (#text * 6)
    local th = font and font:getHeight() or 8
    local bw = math.max(28, tw + 12) * scale
    local bh = math.max(14, th + 8) * scale
    local x = b.x - bw / 2
    local y = b.y - bh - 4 + float

    gfx.setColor(1, 1, 1, 0.92)
    gfx.ellipse("fill", b.x, y + bh / 2, bw / 2, bh / 2)
    -- Tail
    gfx.polygon("fill",
      b.x - 4, y + bh - 2,
      b.x + 4, y + bh - 2,
      b.x, y + bh + 6)
    gfx.setColor(0.1, 0.1, 0.15, 1)
    gfx.ellipse("line", b.x, y + bh / 2, bw / 2, bh / 2)
    if gfx.print then
      gfx.print(text, b.x - tw / 2, y + (bh - th) / 2)
    end
    gfx.setColor(1, 1, 1, 1)
  end)
end

local function drawArena()
  local gfx = g()
  if not gfx then return end
  local img = arenaImage or M.load(mod)
  if img then
    pcall(function()
      gfx.setColor(1, 1, 1, 1)
      local iw, ih = img:getDimensions()
      local sx = M.WIDTH / math.max(iw, 1)
      local sy = M.HEIGHT / math.max(ih, 1)
      gfx.draw(img, 0, 0, 0, sx, sy)
    end)
    return
  end
  -- Flat stand-in so layout still reads without the PNG.
  pcall(function()
    gfx.setColor(0.45, 0.7, 0.35, 1)
    gfx.rectangle("fill", 0, 0, M.WIDTH, M.FIELD_BOTTOM)
    gfx.setColor(0.2, 0.25, 0.3, 1)
    gfx.rectangle("fill", 0, M.FIELD_BOTTOM, M.WIDTH, M.MENU_BAND)
    gfx.setColor(1, 1, 1, 0.15)
    gfx.line(M.MIDLINE, 0, M.MIDLINE, M.FIELD_BOTTOM)
    gfx.setColor(1, 1, 1, 1)
  end)
end

-- battle: screen state (unused for pure layout; reserved for callers).
-- ctx: layout context (see plan).
-- eng: optional engine bag (Font, Sprites, SpriteRenderer, …).
function M.draw(battle, ctx, eng)
  pcall(function()
    if not M.enabled(battle and battle.game or (eng and eng.game)) then
      return
    end
    local layout = M.layout(ctx)
    drawArena()

    for _, h in ipairs(layout.humans) do
      pcall(drawHuman, h, layout.frame, eng)
    end
    for _, mon in ipairs(layout.mons) do
      pcall(drawMonIcon, mon, layout.frame)
    end
    if layout.arrow then
      pcall(drawArrow, layout.arrow)
    end
    if layout.card then
      pcall(drawCard, layout.card, eng)
    end
    for _, b in ipairs(layout.bubbles) do
      pcall(drawBubble, b)
    end
  end)
end

return M
