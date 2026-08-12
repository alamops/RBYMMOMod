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

-- Field mons use battle FRONT pics (aspect-preserved inside this box).
-- Bag-icon sheets are 16×N and look smashed if forced into a square — do not
-- use them as the primary field art.
M.MON_DRAW = 72
-- Legacy alias kept for older layout asserts / callers.
M.ICON_SRC = 16
M.ICON_SCALE = 2
M.ICON_DRAW = M.MON_DRAW

-- Floating target card: room for name, Lxx, HP, status, ~56px front pic.
M.CARD_W = 120
M.CARD_H = 100
M.CARD_SPRITE = 56

-- Persistent seat plates (the arena HUD): one per side, always up. Ally sits
-- bottom-left of the field so it clears MENU_BAND; foe sits top-right.
M.PLATE_W = 176
M.PLATE_H = 48
M.PLATE_PAD = 12

M.HUMAN_SCALE = 2
M.HUMAN_SRC = 16
M.HUMAN_DRAW = M.HUMAN_SRC * M.HUMAN_SCALE

local arenaImage = nil
local arenaTried = false
local humanCache = {} -- spriteId -> { image, quads } | false
local iconCache = {} -- path string -> Image | false
local quadCache = {} -- image -> 16x16 frame-0 quad

-- Force a fresh arena load (e.g. after replacing outdoor_grass_arena.png).
function M.reloadArena()
  arenaImage = nil
  arenaTried = false
end

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

-- Shared by the card, the plates and the bubbles — declared here so the pure
-- model helpers below can reach it too.
local function truncate(text, maxChars)
  if type(text) ~= "string" then return "" end
  maxChars = maxChars or 12
  if #text <= maxChars then return text end
  return text:sub(1, math.max(1, maxChars - 1)) .. "."
end

-- ------- Gen1 gate

function M.enabled(game)
  local ok, gen = pcall(Gen.generation, game)
  if not ok then return false end
  return (tonumber(gen) or 1) == 1
end

-- ------- asset load

function M.load(modFacade)
  modFacade = modFacade or mod
  if arenaTried then return arenaImage end

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
    arenaTried = true
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

-- Draw geometry for one field mon. Pure (no love), so the headless suite can
-- assert the flip decision and the placement without a graphics context.
--   iw/ih  source image dimensions.
--   opts   x/y override the seat centre (bob + fx offsets); iconFrame selects
--          the 16×16 bag-icon fallback path; scale is an fx multiplier.
-- Ally seats carry facing == "right" and are mirrored so the two sides face
-- each other. Mirroring is a negative x-scale anchored at the sprite's right
-- edge — the engine's own idiom (SpriteRenderer.blitFrame, SummaryMenu).
function M.monDrawParams(mon, iw, ih, opts)
  mon = type(mon) == "table" and mon or {}
  opts = type(opts) == "table" and opts or {}
  local box = num(mon.drawW, M.MON_DRAW)
  iw = math.max(1, num(iw, M.ICON_SRC))
  ih = math.max(1, num(ih, M.ICON_SRC))
  local cx = num(opts.x, num(mon.x, 0))
  local cy = num(opts.y, num(mon.y, 0))
  local mul = num(opts.scale, 1)
  if mul < 0 then mul = 0 end

  local sc
  if opts.iconFrame then
    -- 16×16 menu frame, integer scale for crisp pixels.
    iw, ih = 16, 16
    sc = math.max(2, math.floor(box / 16))
  else
    -- Aspect-correct fit inside the mon box (no smash / stretch).
    sc = math.min(box / iw, box / ih)
    -- Prefer integer-ish scale when close, for GB sprite crispness.
    if sc >= 1 then
      local rounded = math.floor(sc + 0.15)
      if rounded >= 1 and math.abs(sc - rounded) < 0.2 then sc = rounded end
    end
  end
  sc = sc * mul

  local dw, dh = iw * sc, ih * sc
  -- Front pics anchor near the feet so the bob reads as a hop on the grass;
  -- the square icon frame stays centred.
  local top = opts.iconFrame and (cy - dh / 2) or (cy - dh * 0.85)
  local flip = mon.facing == "right"
  return {
    scale = sc,
    flip = flip,
    sx = flip and -sc or sc,
    sy = sc,
    w = dw,
    h = dh,
    x = flip and (cx + dw / 2) or (cx - dw / 2),
    y = top,
  }
end

-- Persistent seat-plate model. Pure. `shownHp` is the display clock the battle
-- drains toward `hp`; a seat without one falls back to `hp`, so a caller that
-- never animates (CoopBattle) reads the same as before.
function M.plateModel(seat)
  seat = type(seat) == "table" and seat or {}
  local base = M.cardModel(seat)
  local shown = clamp(math.floor(num(seat.shownHp, base.hp) + 0.5),
    0, base.maxHp)
  local frac = 0
  if base.maxHp > 0 then frac = clamp(shown / base.maxHp, 0, 1) end
  local side = seat.side == "foe" and "foe" or "ally"
  return {
    name = truncate(base.name, 10),
    level = base.level,
    hp = base.hp,
    shownHp = shown,
    maxHp = base.maxHp,
    frac = frac,
    status = base.status,
    side = side,
  }
end

-- ------- fx math
--
-- The battle owns the clock and hands each effect a progress t in 0..1; every
-- shape below is a pure function of t, so a frame is reproducible and the
-- suite can assert it headlessly.

M.FX_LUNGE = 14 -- peak px toward the midline, reached at t == 0.5
M.FX_SHAKE = 3 -- peak whole-field jolt, px
M.FX_FAINT_DROP = 0.5 -- fraction of the mon box a fainting seat sinks

local NO_FX = { dx = 0, dy = 0, alpha = 1, scale = 1, flash = 0 }

local function fxT(v)
  return clamp(num(v, 0), 0, 1)
end

-- Out and back, peaking mid-effect.
function M.fxLunge(t)
  return math.sin(math.pi * fxT(t))
end

-- Two white pulses across the effect, the second weaker.
function M.fxFlash(t)
  t = fxT(t)
  return math.abs(math.sin(t * math.pi * 2)) * (1 - t * 0.4)
end

-- Decaying wobble; the sign alternates so it reads as a jolt, not a slide.
function M.fxShake(t)
  t = fxT(t)
  return math.sin(t * math.pi * 6) * (1 - t)
end

-- Sink fraction (0..1 of FX_FAINT_DROP) and remaining alpha.
function M.fxFaint(t)
  t = fxT(t)
  return t * t, 1 - t
end

-- Scale-up with a slight overshoot (back-out): 0 at t == 0, 1 at t == 1.
function M.fxSpawn(t)
  local u = fxT(t) - 1
  local c1 = 1.70158
  return 1 + (c1 + 1) * u * u * u + c1 * u * u
end

-- Fold the ctx fx list into one seat's draw modifiers. An absent or empty list
-- yields the neutral record, so a caller that passes no fx draws unchanged.
-- An entry with no seatIndex applies to every seat on its side.
function M.fxSeat(fx, side, seatIndex)
  local out = { dx = 0, dy = 0, alpha = 1, scale = 1, flash = 0 }
  for _, e in ipairs(listOf(fx)) do
    if type(e) == "table" and e.side == side
       and (e.seatIndex == nil or e.seatIndex == seatIndex) then
      if e.kind == "lunge" then
        -- Toward the midline: allies charge right, foes left.
        local dir = side == "foe" and -1 or 1
        out.dx = out.dx + dir * M.FX_LUNGE * M.fxLunge(e.t)
      elseif e.kind == "flash" then
        local f = M.fxFlash(e.t)
        if f > out.flash then out.flash = f end
      elseif e.kind == "faint" then
        local drop, alpha = M.fxFaint(e.t)
        out.dy = out.dy + drop * M.MON_DRAW * M.FX_FAINT_DROP
        if alpha < out.alpha then out.alpha = alpha end
      elseif e.kind == "spawn" then
        out.scale = out.scale * M.fxSpawn(e.t)
      end
    end
  end
  if out.scale < 0 then out.scale = 0 end
  return out
end

-- Whole-field jolt. `shake` is field-wide, so side / seatIndex are ignored.
function M.fxFieldShake(fx)
  local dx, dy = 0, 0
  for _, e in ipairs(listOf(fx)) do
    if type(e) == "table" and e.kind == "shake" then
      local t = fxT(e.t)
      dx = dx + M.FX_SHAKE * M.fxShake(t)
      dy = dy + M.FX_SHAKE * 0.6 * math.cos(t * math.pi * 5) * (1 - t)
    end
  end
  return dx, dy
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

  local halfPad = 52
  local left, right
  if side == "ally" then
    left = halfPad + 56
    right = M.MIDLINE - halfPad - 8
  else
    left = M.MIDLINE + halfPad + 8
    right = M.WIDTH - halfPad - 56
  end
  local midY = M.FIELD_TOP + math.floor(M.FIELD_HEIGHT * 0.50)
  local rowSpread = math.min(56, math.floor(M.FIELD_HEIGHT * 0.20))

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
      -- Display clock; nil until a caller animates drains (see plateModel).
      shownHp = seat and seat.shownHp,
      maxHp = seat and seat.maxHp,
      status = seat and seat.status,
      species = seat and seat.species,
      icon = seat and seat.icon,
      front = seat and (seat.front or seat.frontImage or seat.sprite),
      acting = seat and seat.acting and true or false,
      x = x,
      y = midY + yOff,
      facing = facing,
      drawW = M.MON_DRAW,
      drawH = M.MON_DRAW,
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

  local showTarget = ctx.showTarget == true
  if not showTarget then
    local targets = ctx.targets
    if type(targets) == "table" and #targets > 0 and ctx.targetIndex then
      showTarget = true
    end
  end

  local targetMon = nil
  local arrow = nil
  local card = nil
  if showTarget then
    targetMon = findTargetMon(mons, ctx)
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
  end

  -- One persistent plate per side, on its primary (first placed) seat. A seat
  -- carrying no HP figures at all has nothing to plate — skip it rather than
  -- publish a 0/1 bar.
  local plates = {}
  local plated = {}
  for _, mon in ipairs(mons) do
    if not plated[mon.side]
       and (tonumber(mon.maxHp) or tonumber(mon.hp)) then
      plated[mon.side] = true
      local ally = mon.side ~= "foe"
      plates[#plates + 1] = {
        side = mon.side,
        x = ally and M.PLATE_PAD or (M.WIDTH - M.PLATE_W - M.PLATE_PAD),
        y = ally and (M.FIELD_BOTTOM - M.PLATE_H - M.PLATE_PAD) or M.PLATE_PAD,
        w = M.PLATE_W,
        h = M.PLATE_H,
        -- Exact hp/maxHp on your own side only, per series convention.
        numbers = ally,
        model = M.plateModel(mon),
        mon = mon,
      }
    end
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
    plates = plates,
    bubbles = bubbles,
    -- Empty unless the caller drives effects; renderers stay neutral then.
    fx = listOf(ctx.fx),
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

-- ------- trainer sheet colour
--
-- SpriteRenderer:resolveImage hands back DMG shades in every colour mode but
-- ADVANCED / OG RED: the engine expects the whole-canvas zone shader to colour
-- the sheet, and this canvas opts out of that shader (MediatedBattle:zones) so
-- the pre-baked mon pics survive. Left alone the trainers are grey. So bake the
-- OBJ palette here instead, ranked by fidelity, each rung falling through:
--   1. the engine already returned colour (trueColor record, or a mode that
--      bakes an OBJ palette itself) — keep that image;
--   2. the per-sprite OBJ palette the GBC port assigns this character
--      (PaletteFX.spriteObp), baked with SpriteRenderer.getObpImage's own
--      shade thresholds and its OBJ-colour-0 alpha key;
--   3. whatever the engine returned — today's DMG look, never a hard failure.
-- Requiring engine render modules through pcall is the pattern this file
-- already uses; a drift upstream costs colour, never the screen.
local function bakeSheetColor(record, spriteId)
  if type(record) ~= "table" or record.trueColor then return nil end
  if type(record.image) ~= "string" or record.image == "" then return nil end
  if not (love and love.image and love.image.newImageData
          and love.graphics and love.graphics.newImage) then
    return nil
  end
  local PF = nil
  do
    local ok, loaded = pcall(require, "src.render.PaletteFX")
    if ok then PF = loaded end
  end
  if type(PF) ~= "table" or not PF.spriteObp then return nil end

  local engineColored = false
  pcall(function()
    engineColored = (PF.usesGbcPack and PF.usesGbcPack() and true or false)
      or (PF.usesSpriteObp and PF.usesSpriteObp() and true or false)
  end)
  if engineColored then return nil end

  local colors = nil
  pcall(function() colors = PF.spriteObp(record, spriteId) end)
  if type(colors) ~= "table" or type(colors[4]) ~= "table" then return nil end

  local baked = nil
  pcall(function()
    local data = nil
    local okA, Assets = pcall(require, "src.render.Assets")
    if okA and type(Assets) == "table" and Assets.imageData then
      data = Assets.imageData(record.image)
    else
      data = love.image.newImageData(record.image)
    end
    if not (data and data.mapPixel) then return end
    data:mapPixel(function(_, _, r, gr, b, a)
      if a == 0 then return r, gr, b, a end
      -- OBJ colour 0 is unconditionally transparent on hardware, and the
      -- extracted sheets carry no alpha of their own.
      if r > 0.83 then return r, gr, b, 0 end
      local col = r > 0.5 and colors[2] or r > 0.17 and colors[3] or colors[4]
      return col[1] / 255, col[2] / 255, col[3] / 255, a
    end)
    baked = love.graphics.newImage(data)
    if baked.setFilter then
      pcall(function() baked:setFilter("nearest", "nearest") end)
    end
  end)
  return baked
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
    local colored = bakeSheetColor(record, spriteId)
    if colored then img = colored end

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
  -- Uniform scale — never stretch non-square sheets into a square.
  local sc = math.min(dest / math.max(iw, 1), dest / math.max(ih, 1))
  local dw, dh = iw * sc, ih * sc
  gfx.draw(icon, x - dw / 2, y - dh / 2, 0, sc, sc)
end

-- Party-menu icon sheets are often 16×32 (two frames). Crop frame 0.
local function iconFrameQuad(img)
  if not (img and img.getDimensions and love and love.graphics and love.graphics.newQuad) then
    return nil
  end
  local hit = quadCache[img]
  if hit ~= nil then return hit or nil end
  local iw, ih = img:getDimensions()
  local quad = nil
  if ih > 16 and iw >= 16 then
    local ok, q = pcall(love.graphics.newQuad, 0, 0, 16, 16, iw, ih)
    if ok then quad = q end
  end
  quadCache[img] = quad or false
  return quad
end

local function resolveDrawable(sprite)
  if sprite == nil then return nil, nil end
  if type(sprite) == "userdata" or (type(sprite) == "table" and sprite.typeOf) then
    return sprite, nil
  end
  if type(sprite) == "string" and love and love.graphics and love.graphics.newImage then
    local hit = iconCache[sprite]
    if hit == nil then
      local ok, img = pcall(love.graphics.newImage, sprite)
      hit = (ok and img) and img or false
      if hit and hit.setFilter then
        pcall(function() hit:setFilter("nearest", "nearest") end)
      end
      iconCache[sprite] = hit
    end
    return hit or nil, nil
  end
  return nil, nil
end

local function drawMonShadow(gfx, x, y, w, alpha)
  alpha = alpha == nil and 1 or clamp(num(alpha, 1), 0, 1)
  pcall(function()
    local rw = math.max(14, w * 0.42)
    local rh = math.max(5, w * 0.14)
    gfx.setColor(0, 0, 0, 0.35 * alpha)
    gfx.ellipse("fill", x, y + 2, rw, rh)
    gfx.setColor(1, 1, 1, 1)
  end)
end

-- fx: an M.fxSeat record, or nil for the neutral draw.
local function drawMonIcon(mon, frame, fx)
  local gfx = g()
  if not gfx then return end
  fx = type(fx) == "table" and fx or NO_FX
  local alpha = clamp(num(fx.alpha, 1), 0, 1)
  if alpha <= 0 then return end
  local bob = iconBob(frame, mon.acting)
  local x = mon.x + num(fx.dx, 0)
  local y = mon.y + bob + num(fx.dy, 0)
  local box = mon.drawW or M.MON_DRAW

  -- Prefer battle FRONT art; bag icons are a last resort (and must be cropped).
  local img = resolveDrawable(mon.front)
  local fromIcon = false
  if not img then
    img = resolveDrawable(mon.icon)
    fromIcon = img ~= nil
  end

  drawMonShadow(gfx, x, y + box * 0.28, box, alpha)

  local drawn = false
  if img then
    pcall(function()
      if img.setFilter then pcall(function() img:setFilter("nearest", "nearest") end) end
      local iw, ih = img:getDimensions()
      local quad = fromIcon and iconFrameQuad(img) or nil
      local p = M.monDrawParams(mon, iw, ih, {
        x = x, y = y, iconFrame = quad ~= nil, scale = fx.scale,
      })
      -- A spawn at t == 0 has nothing to draw yet; the shadow already marks
      -- the seat, so do not fall through to the placeholder box.
      if p.scale <= 0 then drawn = true; return end
      local function blit()
        if quad then
          gfx.draw(img, quad, p.x, p.y, 0, p.sx, p.sy)
        else
          gfx.draw(img, p.x, p.y, 0, p.sx, p.sy)
        end
      end
      gfx.setColor(1, 1, 1, alpha)
      blit()
      -- White pulse on a defender: one additive re-blit of the same geometry
      -- (no shader — this canvas has none of its own).
      local flash = clamp(num(fx.flash, 0), 0, 1)
      if flash > 0 and gfx.setBlendMode then
        local mode, alphaMode
        if gfx.getBlendMode then mode, alphaMode = gfx.getBlendMode() end
        gfx.setBlendMode("add")
        local f = flash * alpha
        gfx.setColor(f, f, f, 1)
        blit()
        if mode then gfx.setBlendMode(mode, alphaMode)
        else gfx.setBlendMode("alpha") end
      end
      gfx.setColor(1, 1, 1, 1)
      drawn = true
    end)
  end
  if drawn then return end

  pcall(function()
    gfx.setColor(0.95, 0.85, 0.2, 0.9 * alpha)
    gfx.rectangle("fill", x - box / 2, y - box / 2, box, box, 2, 2)
    gfx.setColor(0.2, 0.15, 0.05, alpha)
    gfx.rectangle("line", x - box / 2, y - box / 2, box, box, 2, 2)
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

-- Persistent seat plate, in drawCard's visual language (rounded white panel,
-- thresholded bar). The bar reads the display clock, so a caller that drains
-- `shownHp` animates here for free.
local function drawPlate(plate)
  local gfx = g()
  if not (gfx and plate) then return end
  local model = plate.model or M.plateModel(plate.mon)
  pcall(function()
    local x, y, w, h = plate.x, plate.y, plate.w, plate.h
    local font = gfx.getFont and gfx.getFont() or nil
    local function widthOf(text)
      if font and font.getWidth then return font:getWidth(text) end
      return #text * 6
    end

    gfx.setColor(0.06, 0.07, 0.11, 0.4)
    gfx.rectangle("fill", x + 2, y + 3, w, h, 6, 6)
    gfx.setColor(1, 1, 1, 0.94)
    gfx.rectangle("fill", x, y, w, h, 6, 6)
    gfx.setColor(0.1, 0.1, 0.15, 1)
    gfx.rectangle("line", x, y, w, h, 6, 6)

    local pad = 8
    local barW = w - pad * 2
    local barY = y + h - pad - 8
    gfx.setColor(0.05, 0.05, 0.1, 1)
    if gfx.print then
      gfx.print(model.name, x + pad, y + 4)
      local right = ("L%d"):format(model.level)
      if model.status then right = model.status:upper() .. " " .. right end
      gfx.print(right, x + w - pad - widthOf(right), y + 4)
      if plate.numbers then
        local hpText = ("%d/%d"):format(model.shownHp, model.maxHp)
        gfx.print(hpText, x + w - pad - widthOf(hpText), barY - 14)
      end
    end

    gfx.setColor(0.2, 0.2, 0.25, 1)
    gfx.rectangle("fill", x + pad, barY, barW, 8, 2, 2)
    local frac = clamp(num(model.frac, 0), 0, 1)
    if frac > 0.5 then
      gfx.setColor(0.3, 0.75, 0.35, 1)
    elseif frac > 0.2 then
      gfx.setColor(0.85, 0.7, 0.2, 1)
    else
      gfx.setColor(0.85, 0.25, 0.2, 1)
    end
    if frac > 0 then
      gfx.rectangle("fill", x + pad, barY, math.max(1, math.floor(barW * frac)),
        8, 2, 2)
    end
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

-- outset: px of ground drawn beyond every canvas edge. Non-zero only while a
-- shake translates the field layer, so the jolt never uncovers the canvas.
local function drawArena(outset)
  local gfx = g()
  if not gfx then return end
  outset = num(outset, 0)
  local ox, oy = -outset, -outset
  local ow, oh = M.WIDTH + outset * 2, M.HEIGHT + outset * 2
  local img = arenaImage or M.load(mod)
  if img then
    pcall(function()
      gfx.setColor(1, 1, 1, 1)
      local iw, ih = img:getDimensions()
      local sx = ow / math.max(iw, 1)
      local sy = oh / math.max(ih, 1)
      gfx.draw(img, ox, oy, 0, sx, sy)
    end)
    -- Soft grass plate so battle fronts read on the colorful arena.
    pcall(function()
      local gfx = love and love.graphics
      if not gfx then return end
      gfx.setColor(0.12, 0.22, 0.1, 0.22)
      gfx.ellipse("fill", M.MIDLINE, M.FIELD_TOP + M.FIELD_HEIGHT * 0.55,
        M.WIDTH * 0.38, M.FIELD_HEIGHT * 0.28)
      gfx.setColor(1, 1, 1, 1)
    end)
    return
  end
  -- Flat stand-in so layout still reads without the PNG.
  pcall(function()
    gfx.setColor(0.45, 0.7, 0.35, 1)
    gfx.rectangle("fill", ox, oy, ow, M.FIELD_BOTTOM + outset)
    gfx.setColor(0.2, 0.25, 0.3, 1)
    gfx.rectangle("fill", ox, M.FIELD_BOTTOM, ow, M.MENU_BAND + outset)
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
    local hasFx = #layout.fx > 0
    local gfx = g()

    -- Shake offsets the whole field layer (ground, humans, mons, plates) but
    -- never the menu band, which the battle screen draws after this returns.
    local shakeX, shakeY = 0, 0
    if hasFx then shakeX, shakeY = M.fxFieldShake(layout.fx) end
    local shaking = shakeX ~= 0 or shakeY ~= 0
    local pushed = false
    if shaking and gfx and gfx.push and gfx.translate then
      pushed = pcall(gfx.push)
      if pushed then pcall(gfx.translate, shakeX, shakeY) end
    end

    -- One pcall around the field layer so the pop below always runs: a leaked
    -- translate would drag the menu band the battle screen draws next.
    pcall(function()
      drawArena(shaking and (M.FX_SHAKE + 2) or 0)

      for _, h in ipairs(layout.humans) do
        pcall(drawHuman, h, layout.frame, eng)
      end
      for _, mon in ipairs(layout.mons) do
        pcall(drawMonIcon, mon, layout.frame,
          hasFx and M.fxSeat(layout.fx, mon.side, mon.seatIndex) or nil)
      end
      for _, plate in ipairs(layout.plates) do
        pcall(drawPlate, plate)
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
    if pushed and gfx and gfx.pop then pcall(gfx.pop) end
  end)
end

return M
