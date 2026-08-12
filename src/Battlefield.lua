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
-- Type only: Toast owns the mod's one per-size font cache (Rajdhani, linear
-- filter, engine-default fallback). Nothing else is borrowed from it.
local Toast = need("Toast")

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
-- 60, not 72: at 72 the four seats of a 2v2 crowd the plates and the arena
-- reads as a close-up rather than a field (R2 owner review).
M.MON_DRAW = 60
-- Legacy alias kept for older layout asserts / callers.
M.ICON_SRC = 16
M.ICON_SCALE = 2
M.ICON_DRAW = M.MON_DRAW

-- Floating target card: name + Lv pill row, centred front pic, status chip,
-- HP bar. The pic is 48 rather than 56 so the 120px card keeps real padding
-- around a proportional face at the new type sizes.
M.CARD_W = 120
M.CARD_H = 100
M.CARD_SPRITE = 48

-- Persistent seat plates (the arena HUD): one per placed seat, always up.
-- Ally plates stack upward from the field floor so they clear MENU_BAND; foe
-- plates stack downward from the top edge. A 2v2 shows four.
M.PLATE_W = 176
M.PLATE_H = 48
M.PLATE_PAD = 12
-- Gap between two stacked plates on the same side.
M.PLATE_GAP = 6

M.HUMAN_SCALE = 2
M.HUMAN_SRC = 16
M.HUMAN_DRAW = M.HUMAN_SRC * M.HUMAN_SCALE
-- Distance from the canvas edge to a trainer's column. Shared with the ball
-- arc, which starts at the thrower's column.
local HUMAN_PAD = 20

-- Type sizes, in canvas pixels (the canvas is 640×360 and fill-scaled, so a
-- size here is a size on screen at 1×). Named so they stay tunable in one
-- place: primary = names / buttons / the move callout, message = the band
-- line, secondary = HP numbers and list rows, micro = pills, chips, titles.
M.FONT_MESSAGE = 14
M.FONT_PRIMARY = 13
M.FONT_SECONDARY = 11
M.FONT_MICRO = 10

-- ------- visual language (shared by plates, card, bubbles, band widgets)
--
-- Dark translucent slate over the arena: the field art is bright and busy, and
-- a white panel on it flattened both. One palette, one radius, one shadow --
-- every panel in this file goes through the helpers below rather than picking
-- its own colours.
local PANEL_BG = { 0.078, 0.094, 0.125, 0.85 }
local PANEL_BG_HOT = { 0.16, 0.19, 0.25, 0.92 }
local PANEL_LINE = { 1, 1, 1, 0.18 }
local PANEL_LINE_HOT = { 1, 0.85, 0.42, 0.9 }
local PANEL_SHADOW = { 0, 0, 0, 0.35 }
local PANEL_R = 4
local TEXT_ON = { 1, 1, 1, 1 }
local TEXT_MUTED = { 1, 1, 1, 0.7 }
local TEXT_DIM = { 1, 1, 1, 0.35 }
local PILL_BG = { 1, 1, 1, 0.12 }
local BAR_TROUGH = { 0, 0, 0, 0.55 }
local HP_GREEN = { 0.36, 0.83, 0.42 }
local HP_YELLOW = { 0.95, 0.78, 0.25 }
local HP_RED = { 0.93, 0.32, 0.28 }
-- Muted enough to sit under white text on a dark plate, saturated enough to
-- be told apart at 10px. Keyed by cardModel's 3-letter status, lowercased.
M.STATUS_COLORS = {
  psn = { 0.60, 0.36, 0.85 },
  brn = { 0.92, 0.38, 0.22 },
  slp = { 0.48, 0.53, 0.61 },
  par = { 0.93, 0.75, 0.22 },
  frz = { 0.40, 0.78, 0.94 },
}
local STATUS_FALLBACK = { 0.55, 0.58, 0.65 }

local arenaImage = nil
local arenaTried = false
local humanCache = {} -- spriteId -> { image, quads } | false
local iconCache = {} -- path string -> Image | false
local quadCache = {} -- image -> 16x16 frame-0 quad

-- Force a fresh arena load (e.g. after replacing outdoor_grass_arena.png).
-- Also drops the derived sprite caches: fight entry is the one moment both the
-- arena art and the colour mode may have moved under them, and a baked trainer
-- sheet or icon image is only valid for the mode it was baked in.
function M.reloadArena()
  arenaImage = nil
  arenaTried = false
  humanCache = {}
  iconCache = {}
  -- Keyed by image, so it would otherwise pin the images just dropped above.
  quadCache = {}
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

-- Seat HP contract, shared by M.cardModel and M.plateModel:
--   `hp` MAY already be a display clock. MediatedBattle puts sim truth in `hp`
--   and the display clock in `shownHp`; CoopBattle drains in place and passes
--   only `hp`. So `shownHp`, when present, is authoritative for anything drawn
--   and every renderer must compare / draw via (shownHp or hp) -- never `hp`
--   alone, or the card and the plate disagree mid-drain.
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
  local shown = clamp(math.floor(num(seat.shownHp, hp) + 0.5), 0, maxHp)
  return {
    name = name,
    level = level,
    hp = hp,
    shownHp = shown,
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

-- Persistent seat-plate model. Pure. Reads the same display clock the card
-- does (see the seat HP contract above M.cardModel), so the two can never
-- disagree; a caller that never animates (CoopBattle) reads `hp` as before.
function M.plateModel(seat)
  seat = type(seat) == "table" and seat or {}
  local base = M.cardModel(seat)
  local shown = base.shownHp
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
M.FX_BALL_R = 5 -- pokéball radius (a ~10px ball on a 60px mon)
M.FX_BALL_LIFT = 46 -- peak px the arc rises above the straight line
M.FX_BALL_SPIN = math.pi * 2.5 -- radians of spin across the whole throw
M.FX_WOBBLE_ANGLE = 0.35 -- ≈20° peak rock, three rocks per SHAKE row
M.FX_POOF_R = 30 -- outer ring radius at the end of a poof

local NO_FX = {
  dx = 0, dy = 0, alpha = 1, scale = 1, flash = 0,
  -- The seat's mon is inside a ball (ball / wobble): draw nothing for it.
  hidden = false,
}

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

-- ------- ball-flow fx (throw → wobble → poof / recall)
--
-- Same rule as everything above: pure functions of t, so the arc, the rock and
-- the burst are reproducible frame by frame and assertable headlessly. The
-- ball itself is original vector art (see drawPokeball) -- no ROM pixels.

-- Travel fraction, arc lift (0..1, peaking at t == 0.5) and spin angle.
function M.fxBall(t)
  t = fxT(t)
  return t, 4 * t * (1 - t), t * M.FX_BALL_SPIN
end

-- The ball's position on a parabolic arc from (x0,y0) to (x1,y1), plus its
-- spin. Straight-line interpolation with the lift subtracted, so the landing
-- point is exact at t == 1 whatever the lift.
function M.fxBallPoint(x0, y0, x1, y1, t)
  x0, y0 = num(x0, 0), num(y0, 0)
  x1, y1 = num(x1, 0), num(y1, 0)
  local u, lift, spin = M.fxBall(t)
  return x0 + (x1 - x0) * u,
    y0 + (y1 - y0) * u - M.FX_BALL_LIFT * lift,
    spin
end

-- Rock angle, radians. Three half-swings with alternating sign, at rest at
-- both ends so consecutive SHAKE rows join without a snap.
function M.fxWobble(t)
  return math.sin(fxT(t) * math.pi * 3) * M.FX_WOBBLE_ANGLE
end

-- Expansion fraction (ease-out) and remaining alpha.
function M.fxPoof(t)
  t = fxT(t)
  local u = 1 - t
  return 1 - u * u, u
end

-- Shrink factor and remaining alpha for a mon being pulled into its ball.
-- No offset is needed: field pics are feet-anchored (monDrawParams), so a
-- shrinking sprite already collapses onto the spot the ball sits on.
function M.fxRecall(t)
  t = fxT(t)
  return 1 - t, 1 - t
end

-- Fold the ctx fx list into one seat's draw modifiers. An absent or empty list
-- yields the shared neutral record NO_FX, so a caller that passes no fx draws
-- unchanged; what fxSeat returns is read-only to callers, never mutated.
-- An entry with no seatIndex applies to every seat on its side.
function M.fxSeat(fx, side, seatIndex)
  local out = nil
  for _, e in ipairs(listOf(fx)) do
    if type(e) == "table" and e.side == side
       and (e.seatIndex == nil or e.seatIndex == seatIndex) then
      out = out or {
        dx = 0, dy = 0, alpha = 1, scale = 1, flash = 0, hidden = false,
      }
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
      elseif e.kind == "recall" then
        local s, alpha = M.fxRecall(e.t)
        out.scale = out.scale * s
        if alpha < out.alpha then out.alpha = alpha end
      elseif e.kind == "wobble" then
        -- The mon is inside the ball while it rocks on the ground: the seat
        -- draws nothing (not even its shadow) until a poof breaks it out.
        -- `ball` deliberately does NOT hide: the arc is still in the air, and
        -- the occupant only goes in when the recall (HIDEPIC) plays. Hiding on
        -- the throw put the mon inside the ball before the ball arrived, which
        -- is the chronology the flows in MediatedBattle / CoopBattle fixed. A
        -- ball aimed at an empty seat has nothing to hide either way, and a
        -- `recall` held at t == 1 still reads invisible through scale/alpha 0.
        out.hidden = true
      end
    end
  end
  if not out then return NO_FX end
  if out.scale < 0 then out.scale = 0 end
  return out
end

-- Whole-field jolt. `shake` is field-wide, so side / seatIndex are ignored.
-- The fold is clamped: a multi-hit move stacks three to five live shakes, and
-- their unclamped sum would walk the field past the outset drawArena reserves
-- and uncover the canvas edge.
function M.fxFieldShake(fx)
  local dx, dy = 0, 0
  for _, e in ipairs(listOf(fx)) do
    if type(e) == "table" and e.kind == "shake" then
      local t = fxT(e.t)
      dx = dx + M.FX_SHAKE * M.fxShake(t)
      dy = dy + M.FX_SHAKE * 0.6 * math.cos(t * math.pi * 5) * (1 - t)
    end
  end
  return clamp(dx, -M.FX_SHAKE, M.FX_SHAKE), clamp(dy, -M.FX_SHAKE, M.FX_SHAKE)
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
  local pad = HUMAN_PAD
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
      -- The card only earns its space when the pick is genuinely ambiguous
      -- (CoopBattle's multi-target selection). With a single candidate the
      -- plates already publish that seat's name / level / HP, so the card
      -- would only duplicate a plate and cover the sprite it points at.
      if #listOf(ctx.targets) > 1 then
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
  end

  -- One persistent plate per placed seat, stacked away from its own edge so a
  -- 2v2 (CoopBattle) keeps a HUD for every seat rather than only the primary
  -- one. A seat carrying no HP figures at all has nothing to plate — skip it
  -- rather than publish a 0/1 bar.
  local plates = {}
  local stackedAlly, stackedFoe = 0, 0
  for _, mon in ipairs(mons) do
    if tonumber(mon.maxHp) or tonumber(mon.hp) then
      local ally = mon.side ~= "foe"
      local step
      if ally then
        step = stackedAlly * (M.PLATE_H + M.PLATE_GAP)
        stackedAlly = stackedAlly + 1
      else
        step = stackedFoe * (M.PLATE_H + M.PLATE_GAP)
        stackedFoe = stackedFoe + 1
      end
      plates[#plates + 1] = {
        side = mon.side,
        x = ally and M.PLATE_PAD or (M.WIDTH - M.PLATE_W - M.PLATE_PAD),
        -- Allies climb from the field floor, foes descend from the top.
        y = ally and (M.FIELD_BOTTOM - M.PLATE_H - M.PLATE_PAD - step)
          or (M.PLATE_PAD + step),
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
          -- Optional emphasis line (the move that was used); the renderer
          -- gives it its own, larger line under the plain text.
          moveName = (type(b.moveName) == "string" and b.moveName ~= "")
            and b.moveName or nil,
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

-- ------- type
--
-- Toast owns the mod's font cache (one face per size, linear filter, engine
-- default when the bundled TTF is missing). Borrowing it keeps a single cache
-- and gives this file the same look as the rest of the mod's chrome. Headless
-- -- no love, or a Toast that could not build a font -- returns nil and every
-- caller below falls back to whatever font is already set.
local function uiFont(size)
  if not (Toast and Toast.font) then return nil end
  local ok, font = pcall(Toast.font, size)
  if ok and font then return font end
  return nil
end

local function widthWith(font, text)
  text = tostring(text or "")
  if font and font.getWidth then
    local ok, w = pcall(font.getWidth, font, text)
    if ok and type(w) == "number" then return w end
  end
  return #text * 6
end

local function heightWith(font)
  if font and font.getHeight then
    local ok, h = pcall(font.getHeight, font)
    if ok and type(h) == "number" then return h end
  end
  return 12
end

-- Every text block runs inside this: the face is set, the block draws, and the
-- caller's face goes back — always. The battle screen paints its own chrome
-- right after Battlefield.draw returns and must not inherit ours.
-- `fn` receives the font actually in effect, for measuring.
local function withFont(gfx, size, fn)
  local font = uiFont(size)
  local prev = nil
  if gfx.getFont then
    local ok, got = pcall(gfx.getFont)
    if ok then prev = got end
  end
  -- "We set a face" is tracked apart from "we read the old one": gating the
  -- restore on `prev` alone leaked our face into the caller's chrome whenever
  -- getFont was missing (or returned nothing) but setFont worked.
  local didSet = false
  if font and gfx.setFont then didSet = pcall(gfx.setFont, font) and true or false end
  local ok = pcall(fn, font or prev)
  if gfx.setFont and (prev or didSet) then
    if prev then
      pcall(gfx.setFont, prev)
    else
      -- Residual limit: with no readable previous face there is nothing exact
      -- to put back, so the best available reset is the argument-less setFont
      -- (LOVE's default face). If even that is refused the face stays ours —
      -- unavoidable on a context that can set a font but not report one.
      pcall(gfx.setFont)
    end
  end
  return ok
end

-- ------- panel primitives

local function setColor(gfx, c, alpha)
  local a = (c[4] or 1) * (alpha == nil and 1 or alpha)
  gfx.setColor(c[1], c[2], c[3], a)
end

-- The one panel shape: soft drop shadow, dark translucent slate, 1px light
-- border. `hot` lifts the fill and warms the border (a cursor); `alpha` scales
-- the whole thing (bubbles fade).
local function panel(gfx, x, y, w, h, hot, alpha)
  setColor(gfx, PANEL_SHADOW, alpha)
  gfx.rectangle("fill", x + 1, y + 2, w, h, PANEL_R, PANEL_R)
  setColor(gfx, hot and PANEL_BG_HOT or PANEL_BG, alpha)
  gfx.rectangle("fill", x, y, w, h, PANEL_R, PANEL_R)
  setColor(gfx, hot and PANEL_LINE_HOT or PANEL_LINE, alpha)
  gfx.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, PANEL_R, PANEL_R)
end

local function hpColor(frac)
  if frac > 0.5 then return HP_GREEN end
  if frac > 0.2 then return HP_YELLOW end
  return HP_RED
end

-- Rounded-cap HP bar over a darker trough. Thresholds unchanged from v1.
local function drawHpBar(gfx, x, y, w, h, frac)
  frac = clamp(num(frac, 0), 0, 1)
  local r = h / 2
  setColor(gfx, BAR_TROUGH)
  gfx.rectangle("fill", x, y, w, h, r, r)
  if frac > 0 then
    local fw = math.max(h, w * frac)
    setColor(gfx, hpColor(frac))
    gfx.rectangle("fill", x, y, fw, h, r, r)
    -- Top-edge sheen: one flat highlight, no gradient (no mesh on this path).
    gfx.setColor(1, 1, 1, 0.18)
    gfx.rectangle("fill", x + r * 0.6, y + 1, math.max(1, fw - r * 1.2), 1)
  end
  setColor(gfx, PANEL_LINE)
  gfx.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, r, r)
end

-- "Lv 25" in a faint capsule. Returns its width so a caller can reserve it.
local function pillWidth(font, level)
  return widthWith(font, "Lv " .. tostring(level)) + 10
end

local function drawLevelPill(gfx, font, level, x, y, h)
  local text = "Lv " .. tostring(level)
  local w = widthWith(font, text) + 10
  setColor(gfx, PILL_BG)
  gfx.rectangle("fill", x, y, w, h, h / 2, h / 2)
  setColor(gfx, TEXT_MUTED)
  gfx.print(text, x + 5, y + math.floor((h - heightWith(font)) / 2))
  return w
end

-- Status chip: filled in the status colour with near-black text, which is the
-- only pairing that stays readable across violet and amber alike.
local function drawStatusChip(gfx, font, status, x, y, h)
  local text = tostring(status):upper()
  local color = M.STATUS_COLORS[tostring(status):lower()] or STATUS_FALLBACK
  local w = widthWith(font, text) + 8
  gfx.setColor(color[1], color[2], color[3], 0.9)
  gfx.rectangle("fill", x, y, w, h, 2, 2)
  gfx.setColor(0.06, 0.07, 0.10, 1)
  gfx.print(text, x + 4, y + math.floor((h - heightWith(font)) / 2))
  return w
end

-- A small filled triangle, in place of a glyph: the bundled face has no
-- geometric arrows and the engine default cannot be relied on for them.
local function drawTriangle(gfx, x, y, size, dir, color, alpha)
  setColor(gfx, color or TEXT_MUTED, alpha)
  if dir == "up" then
    gfx.polygon("fill", x, y, x + size * 2, y, x + size, y - size)
  else
    gfx.polygon("fill", x, y, x + size * 2, y, x + size, y + size)
  end
end

-- Longest prefix of `text` that fits maxW, ellipsised when it had to cut.
-- The cut is binary-searched, not walked down one character at a time: a
-- 40-char label used to cost up to 40 measurements per frame per row, and a
-- list panel draws five of them. The candidate measured is still the whole
-- `prefix .. "..."` rather than a prefix against a pre-subtracted budget,
-- because Font:getWidth kerns — prefix width plus ellipsis width is not the
-- same number, and the output here has to be byte-identical to the walk.
-- Width is non-decreasing in the cut, which is what makes the search legal.
local function fitLine(font, text, maxW)
  text = tostring(text or "")
  if widthWith(font, text) <= maxW then return text, false end
  -- Floor of 1, as the walk had: something ellipsised beats an empty row.
  local lo, hi, cut = 1, #text, 1
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if widthWith(font, text:sub(1, mid) .. "...") <= maxW then
      cut = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return text:sub(1, cut) .. "...", true
end

-- Word wrap by measured width, honouring embedded newlines (battle text is
-- written with them). Returns at most `maxLines` lines plus whether anything
-- had to be dropped; the last kept line is ellipsised when so.
local function wrapLines(font, text, maxW, maxLines)
  local out = {}
  local overflow = false
  for chunk in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local line = nil
    for word in chunk:gmatch("%S+") do
      local candidate = line and (line .. " " .. word) or word
      if line and widthWith(font, candidate) > maxW then
        out[#out + 1] = line
        line = word
      else
        line = candidate
      end
    end
    if line then out[#out + 1] = line end
  end
  while #out > maxLines do
    table.remove(out)
    overflow = true
  end
  if #out > 0 then
    local last, cut = fitLine(font, out[#out], maxW)
    out[#out] = last
    overflow = overflow or cut
  end
  return out, overflow
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
local function paletteFX()
  local ok, loaded = pcall(require, "src.render.PaletteFX")
  if ok and type(loaded) == "table" then return loaded end
  return nil
end

-- The bake is colour-mode dependent and the mode can change between battles
-- (the options screen writes PaletteFX.mode live), so the mode is part of the
-- cache key — a sheet baked under the previous mode must not be handed back.
local function humanCacheKey(spriteId)
  local PF = paletteFX()
  return spriteId .. "|" .. tostring((PF and PF.mode) or "?")
end

local function bakeSheetColor(record, spriteId)
  if type(record) ~= "table" or record.trueColor then return nil end
  if type(record.image) ~= "string" or record.image == "" then return nil end
  if not (love and love.image and love.image.newImageData
          and love.graphics and love.graphics.newImage) then
    return nil
  end
  local PF = paletteFX()
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
  local key = humanCacheKey(spriteId)
  local hit = humanCache[key]
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

  humanCache[key] = entry
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
  -- Inside a ball: not even the shadow, or the seat reads as still occupied.
  if fx.hidden then return end
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
      -- (no shader — this canvas has none of its own). The re-blit gets its
      -- own pcall so the restore below always runs: a throw here unwinds past
      -- the enclosing pcall and would leave the whole screen in "add".
      local flash = clamp(num(fx.flash, 0), 0, 1)
      if flash > 0 and gfx.setBlendMode then
        local mode, alphaMode
        if gfx.getBlendMode then mode, alphaMode = gfx.getBlendMode() end
        gfx.setBlendMode("add")
        local f = flash * alpha
        gfx.setColor(f, f, f, 1)
        pcall(blit)
        pcall(gfx.setBlendMode, mode or "alpha", alphaMode)
        pcall(gfx.setColor, 1, 1, 1, alpha)
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

-- Target card: the plate language in a portrait box — name + Lv pill, the
-- front pic centred under them, status chip and HP bar on the floor.
local function drawCard(card, eng)
  local gfx = g()
  if not (gfx and card) then return end
  local model = card.model or M.cardModel(card.mon)
  pcall(function()
    local x, y, w, h = card.x, card.y, card.w, card.h
    panel(gfx, x, y, w, h)

    local pad = 7
    local sp = M.CARD_SPRITE
    local spriteY = y + 20
    local sprite = model.front
    if sprite then
      pcall(function()
        gfx.setColor(1, 1, 1, 1)
        local iw, ih = sp, sp
        if sprite.getDimensions then iw, ih = sprite:getDimensions() end
        local sc = math.min(sp / math.max(iw, 1), sp / math.max(ih, 1))
        gfx.draw(sprite, x + (w - iw * sc) / 2, spriteY + (sp - ih * sc) / 2,
          0, sc, sc)
      end)
    else
      gfx.setColor(1, 1, 1, 0.08)
      gfx.rectangle("fill", x + (w - sp) / 2, spriteY, sp, sp, 3, 3)
    end

    -- Display clock, not truth hp (see the seat HP contract on M.cardModel):
    -- the card and the plates must show the same bar mid-drain.
    local shown = num(model.shownHp, model.hp)
    local frac = 0
    if model.maxHp > 0 then frac = clamp(shown / model.maxHp, 0, 1) end
    local barY = y + h - pad - 7
    drawHpBar(gfx, x + pad, barY, w - pad * 2, 7, frac)

    withFont(gfx, M.FONT_MICRO, function(micro)
      local pillW = pillWidth(micro, model.level)
      drawLevelPill(gfx, micro, model.level, x + w - pad - pillW, y + 5, 13)
      if model.status then
        drawStatusChip(gfx, micro, model.status, x + pad, barY - 15, 12)
      end
      withFont(gfx, M.FONT_PRIMARY, function(primary)
        setColor(gfx, TEXT_ON)
        local name = fitLine(primary, model.name, w - pad * 2 - pillW - 4)
        gfx.print(name, x + pad, y + 4)
      end)
    end)
    gfx.setColor(1, 1, 1, 1)
  end)
end

-- Persistent seat plate: name + Lv pill, status chip and (ally only) exact
-- hp/maxHp, over a thresholded bar. The bar reads the display clock, so a
-- caller that drains `shownHp` animates here for free.
local function drawPlate(plate)
  local gfx = g()
  if not (gfx and plate) then return end
  local model = plate.model or M.plateModel(plate.mon)
  pcall(function()
    local x, y, w, h = plate.x, plate.y, plate.w, plate.h
    panel(gfx, x, y, w, h)

    local pad = 7
    local barY = y + h - pad - 7
    drawHpBar(gfx, x + pad, barY, w - pad * 2, 7, num(model.frac, 0))

    withFont(gfx, M.FONT_MICRO, function(micro)
      local pillW = pillWidth(micro, model.level)
      drawLevelPill(gfx, micro, model.level, x + w - pad - pillW, y + 4, 13)
      local chipRight = x + w - pad
      if model.status then
        drawStatusChip(gfx, micro, model.status, x + pad, y + 20, 12)
      end
      if plate.numbers then
        -- Exact figures on your own side only, per series convention.
        withFont(gfx, M.FONT_SECONDARY, function(secondary)
          local hpText = ("%d/%d"):format(model.shownHp, model.maxHp)
          setColor(gfx, TEXT_MUTED)
          gfx.print(hpText, chipRight - widthWith(secondary, hpText), y + 19)
        end)
      end
      withFont(gfx, M.FONT_PRIMARY, function(primary)
        setColor(gfx, TEXT_ON)
        local name = fitLine(primary, model.name, w - pad * 2 - pillW - 4)
        gfx.print(name, x + pad, y + 3)
      end)
    end)
    gfx.setColor(1, 1, 1, 1)
  end)
end

-- Trainer callout: a rounded near-white card with a tail toward the speaker.
-- Two lines at most — the plain text, then the move name emphasised under it.
-- Pure in t: scale-in, float and fade all read from the caller's clock (t
-- counts down from 1, so the callout settles in and drifts up as it expires).
local BUBBLE_MAX_W = 180
local BUBBLE_MAX_CHARS = 24
local BUBBLE_TAIL = 7

local function drawBubble(b)
  local gfx = g()
  if not gfx then return end
  local t = clamp(num(b.t, 1), 0, 1)
  if t <= 0 then return end
  -- One line each: callers write battle text with newlines in it, and a
  -- second line inside the plain text would print straight through the box.
  local line = truncate((tostring(b.text or ""):gsub("%s+", " ")),
    BUBBLE_MAX_CHARS)
  local move = nil
  if type(b.moveName) == "string" and b.moveName ~= "" then
    move = truncate(b.moveName, BUBBLE_MAX_CHARS)
  end
  if line == "" and not move then return end

  local scale = 0.55 + 0.45 * math.min(1, t * 1.6)
  local alpha = math.min(1, t * 3)
  local ax, ay = b.x, b.y + (1 - t) * -6

  -- The scale-in is a transform around the tail tip, so the callout grows out
  -- of the speaker's head. Pushed outside the body's pcall: a throw inside
  -- must never leave the transform on the stack for the next layer.
  local pushed = false
  if scale < 0.999 and gfx.push and gfx.translate and gfx.scale then
    pushed = pcall(gfx.push)
    if pushed then
      pcall(gfx.translate, ax, ay)
      pcall(gfx.scale, scale, scale)
      pcall(gfx.translate, -ax, -ay)
    end
  end

  pcall(function()
    withFont(gfx, M.FONT_SECONDARY, function(small)
      local moveFont = uiFont(M.FONT_PRIMARY)
      local w1 = line ~= "" and widthWith(small, line) or 0
      local w2 = move and widthWith(moveFont or small, move) or 0
      local h1 = line ~= "" and heightWith(small) or 0
      local h2 = move and heightWith(moveFont or small) or 0
      local bw = clamp(math.max(w1, w2) + 16, 34, BUBBLE_MAX_W)
      local bh = h1 + h2 + 10
      -- The body is clamped to the canvas while the tail stays on the
      -- speaker: edge seats (the humans sit ~36px from the border) would
      -- otherwise hang half the callout off-screen.
      local x = clamp(ax - bw / 2, 4, M.WIDTH - bw - 4)
      local y = math.max(4, ay - BUBBLE_TAIL - bh)

      gfx.setColor(0, 0, 0, 0.3 * alpha)
      gfx.rectangle("fill", x + 1, y + 2, bw, bh, PANEL_R, PANEL_R)
      gfx.setColor(0.97, 0.97, 0.98, 0.96 * alpha)
      gfx.rectangle("fill", x, y, bw, bh, PANEL_R, PANEL_R)
      gfx.polygon("fill",
        ax - 5, y + bh - 1,
        ax + 5, y + bh - 1,
        ax, y + bh + BUBBLE_TAIL)
      gfx.setColor(0.09, 0.10, 0.14, 0.85 * alpha)
      gfx.rectangle("line", x + 0.5, y + 0.5, bw - 1, bh - 1, PANEL_R, PANEL_R)

      local ty = y + 5
      if line ~= "" then
        gfx.setColor(0.20, 0.22, 0.28, alpha)
        gfx.print(fitLine(small, line, bw - 12), x + 6, ty)
        ty = ty + h1
      end
      if move then
        if moveFont and gfx.setFont then pcall(gfx.setFont, moveFont) end
        gfx.setColor(0.06, 0.07, 0.11, alpha)
        gfx.print(fitLine(moveFont or small, move, bw - 12), x + 6, ty)
      end
    end)
    gfx.setColor(1, 1, 1, 1)
  end)
  if pushed and gfx.pop then pcall(gfx.pop) end
end

-- ------- ball flow
--
-- ORIGINAL vector art: two hemispheres, an equator band and a button, built
-- from primitives. Nothing here is derived from ROM pixels, and nothing may
-- ever be. `angle` spins / rocks the ball; the band and button ride it.
local function drawPokeball(gfx, x, y, r, angle, alpha)
  alpha = clamp(num(alpha, 1), 0, 1)
  angle = num(angle, 0)
  local ca, sa = math.cos(angle), math.sin(angle)
  local function point(lx, ly)
    return x + lx * ca - ly * sa, y + lx * sa + ly * ca
  end

  -- No contact shadow here: the ball spends most of a throw in the air, and a
  -- shadow riding along under it kills the height the arc is drawing.
  -- Lower (white) hemisphere is the whole disc; the red cap covers the top.
  gfx.setColor(0.95, 0.95, 0.96, alpha)
  gfx.circle("fill", x, y, r)
  gfx.setColor(0.86, 0.22, 0.20, alpha)
  gfx.arc("fill", "pie", x, y, r, math.pi + angle, math.pi * 2 + angle)
  -- Equator band: a rotated strip, not a line, so it keeps its width spinning.
  local bx1, by1 = point(-r, -r * 0.22)
  local bx2, by2 = point(r, -r * 0.22)
  local bx3, by3 = point(r, r * 0.22)
  local bx4, by4 = point(-r, r * 0.22)
  gfx.setColor(0.10, 0.10, 0.13, alpha)
  gfx.polygon("fill", bx1, by1, bx2, by2, bx3, by3, bx4, by4)
  gfx.circle("fill", x, y, r * 0.34)
  gfx.setColor(0.97, 0.97, 0.98, alpha)
  gfx.circle("fill", x, y, r * 0.2)
  gfx.setColor(0.10, 0.10, 0.13, alpha)
  gfx.circle("line", x, y, r)
  gfx.setColor(1, 1, 1, 1)
end

-- Expanding ring plus a few motes: a materialise, never a burst of debris.
local function drawPoof(gfx, x, y, t)
  local e, alpha = M.fxPoof(t)
  if alpha <= 0 then return end
  local lw = gfx.getLineWidth and gfx.getLineWidth() or 1
  if gfx.setLineWidth then pcall(gfx.setLineWidth, 2) end
  -- The body gets its own pcall so the restore below always runs: a throw
  -- mid-body would unwind past drawFieldFx's pcall and leave every later
  -- outline on the frame at width 2 (same guard shape as drawMonIcon's
  -- blend-mode re-blit).
  pcall(function()
    gfx.setColor(1, 1, 1, 0.5 * alpha)
    gfx.circle("line", x, y, math.max(1, M.FX_POOF_R * e))
    for i = 1, 4 do
      local ang = (i / 4) * math.pi * 2 + e * 1.2
      local d = M.FX_POOF_R * e * 0.75
      gfx.setColor(1, 0.97, 0.86, 0.7 * alpha)
      gfx.circle("fill", x + math.cos(ang) * d, y + math.sin(ang) * d,
        math.max(1, 4 * (1 - e) + 1))
    end
  end)
  if gfx.setLineWidth then pcall(gfx.setLineWidth, lw) end
  pcall(gfx.setColor, 1, 1, 1, 1)
end

local function seatOf(layout, side, seatIndex)
  for _, mon in ipairs(layout.mons) do
    if mon.side == side and (seatIndex == nil or mon.seatIndex == seatIndex) then
      return mon
    end
  end
  return nil
end

-- The thrower stands on the side opposite the seat the ball is aimed at, so
-- the arc starts at that side's trainer column, at mid-field height.
local function ballOrigin(layout, targetSide)
  local side = targetSide == "foe" and "ally" or "foe"
  for _, h in ipairs(layout.humans) do
    if h.side == side then
      return h.x, h.y - math.floor(h.drawH / 2)
    end
  end
  local edge = HUMAN_PAD + math.floor(M.HUMAN_DRAW / 2)
  return side == "ally" and edge or (M.WIDTH - edge),
    M.FIELD_TOP + math.floor(M.FIELD_HEIGHT * 0.5)
end

-- Field-level fx that are not seat modifiers: the ball in flight, the ball
-- rocking on the ground, and the poof a mon materialises out of.
local function drawFieldFx(layout)
  local gfx = g()
  if not gfx then return end
  for _, e in ipairs(layout.fx) do
    if type(e) == "table" then
      local seat = nil
      if e.kind == "ball" or e.kind == "wobble" or e.kind == "poof" then
        seat = seatOf(layout, e.side, e.seatIndex)
      end
      if seat and e.kind == "ball" then
        local x0, y0 = ballOrigin(layout, e.side)
        local x, y, spin = M.fxBallPoint(x0, y0, seat.x, seat.y, e.t)
        pcall(drawPokeball, gfx, x, y, M.FX_BALL_R, spin, 1)
      elseif seat and e.kind == "wobble" then
        -- On the ground now, so it gets the contact shadow the arc refuses.
        pcall(function()
          gfx.setColor(0, 0, 0, 0.3)
          gfx.ellipse("fill", seat.x, seat.y + M.FX_BALL_R * 1.3,
            M.FX_BALL_R * 1.1, M.FX_BALL_R * 0.4)
          gfx.setColor(1, 1, 1, 1)
        end)
        pcall(drawPokeball, gfx, seat.x, seat.y, M.FX_BALL_R,
          M.fxWobble(e.t), 1)
      elseif seat and e.kind == "poof" then
        pcall(drawPoof, gfx, seat.x, seat.y, e.t)
      end
    end
  end
end

-- The ground is drawn K px beyond every canvas edge so a shake translate never
-- uncovers it. Unconditional, every frame: outsetting only while shaking would
-- rescale the arena image at the first and last frame of every jolt, which
-- reads as a zoom-pop. Everything painted on the ground (the soft grass plate)
-- rides the same transform, or it slides against it.
local function drawArena()
  local gfx = g()
  if not gfx then return end
  local K = M.FX_SHAKE + 2
  local ox, oy = -K, -K
  local ow, oh = M.WIDTH + K * 2, M.HEIGHT + K * 2
  local zx, zy = ow / M.WIDTH, oh / M.HEIGHT
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
      gfx.setColor(0.12, 0.22, 0.1, 0.22)
      gfx.ellipse("fill",
        ox + M.MIDLINE * zx,
        oy + (M.FIELD_TOP + M.FIELD_HEIGHT * 0.55) * zy,
        M.WIDTH * 0.38 * zx, M.FIELD_HEIGHT * 0.28 * zy)
      gfx.setColor(1, 1, 1, 1)
    end)
    return
  end
  -- Flat stand-in so layout still reads without the PNG.
  pcall(function()
    gfx.setColor(0.45, 0.7, 0.35, 1)
    gfx.rectangle("fill", ox, oy, ow, M.FIELD_BOTTOM + K)
    gfx.setColor(0.2, 0.25, 0.3, 1)
    gfx.rectangle("fill", ox, M.FIELD_BOTTOM, ow, M.MENU_BAND + K)
    gfx.setColor(1, 1, 1, 0.15)
    gfx.line(M.MIDLINE, 0, M.MIDLINE, M.FIELD_BOTTOM)
    gfx.setColor(1, 1, 1, 1)
  end)
end

-- ------- menu band widgets
--
-- The battlefield's bottom band. These replace the classic 20×6 GB box, which
-- both battles used to re-project into 640×80 (4× horizontally against 1.67×
-- vertically — the stretch the owner review called out). The classic 160×144
-- and Gen2 paths keep their GB chrome; only the battlefield path calls these.
--
-- Every widget draws inside MENU_BAND and nowhere else, is pcall-safe, and
-- no-ops without love.graphics. `opts.x/y/w/h` box a widget into part of the
-- band (a caller showing a message and a command grid at once), and default
-- to the whole band inset by the margins below.
--
-- Each widget returns true only when it actually painted, and false when it
-- bailed (no love.graphics, nothing to draw, a box too small) or when its
-- internal pcall caught a throw. Callers gate their GB-chrome fallback on
-- that: without a signal a widget that failed mid-body left an empty band
-- with the fallback never firing, which reads as the battle having frozen.

M.BAND_MARGIN_X = 10
M.BAND_MARGIN_Y = 4
-- Row height is derived, not fixed: the band is 80px and a title eats 12 of
-- them, so pinning a height would cost the fifth row on a bare list or the
-- fourth on a titled one. Floor 12 / ceiling 15 around FONT_SECONDARY.
local LIST_ROW_MIN = 12
local LIST_ROW_MAX = 15
local LIST_TITLE_H = 12
local LIST_PAD_X = 8
local LIST_PAD_Y = 4

-- The rect a band widget draws into, clamped to MENU_BAND so an opts override
-- can never paint over the field.
function M.bandRect(opts)
  opts = type(opts) == "table" and opts or {}
  local x = num(opts.x, M.BAND_MARGIN_X)
  local y = num(opts.y, M.FIELD_BOTTOM + M.BAND_MARGIN_Y)
  local w = num(opts.w, M.WIDTH - M.BAND_MARGIN_X * 2)
  local h = num(opts.h, M.MENU_BAND - M.BAND_MARGIN_Y * 2)
  y = clamp(y, M.FIELD_BOTTOM, M.HEIGHT)
  h = clamp(h, 1, M.HEIGHT - y)
  x = clamp(x, 0, M.WIDTH)
  w = clamp(w, 1, M.WIDTH - x)
  return x, y, w, h
end

-- Optional: one scrim over the whole band before the widgets go down. The
-- arena art runs edge to edge, so a caller that wants the band to read as
-- chrome rather than as panels floating on grass calls this once — once,
-- because two widgets each painting their own scrim would double-darken it.
function M.drawBandBackdrop()
  local gfx = g()
  if not gfx then return end
  pcall(function()
    gfx.setColor(0.03, 0.04, 0.06, 0.55)
    gfx.rectangle("fill", 0, M.FIELD_BOTTOM, M.WIDTH, M.MENU_BAND)
    setColor(gfx, PANEL_LINE)
    gfx.rectangle("fill", 0, M.FIELD_BOTTOM, M.WIDTH, 1)
    gfx.setColor(1, 1, 1, 1)
  end)
end

-- The battle line. Two lines at most; a third would not fit the band, and the
-- caller's message queue is what splits long text anyway.
-- opts.hint == false drops the continue triangle (a line nothing waits on).
function M.drawMessagePanel(text, opts)
  local gfx = g()
  if not gfx then return false end
  local x, y, w, h = M.bandRect(opts)
  opts = type(opts) == "table" and opts or {}
  -- `ok` only, never pcall's error string as a second return: a caller
  -- forwarding this into another call must not get a stray extra argument.
  local ok = pcall(function()
    panel(gfx, x, y, w, h)
    withFont(gfx, M.FONT_MESSAGE, function(font)
      local pad = 12
      local lines = wrapLines(font, text, w - pad * 2, 2)
      local lh = heightWith(font)
      local total = math.max(1, #lines) * lh + (#lines > 1 and 2 or 0)
      local ty = y + math.floor((h - total) / 2)
      setColor(gfx, TEXT_ON)
      for i, line in ipairs(lines) do
        gfx.print(line, x + pad, ty + (i - 1) * (lh + 2))
      end
      if opts.hint ~= false and #lines > 0 then
        drawTriangle(gfx, x + w - 16, y + h - 12, 4, "down", TEXT_MUTED)
      end
    end)
    gfx.setColor(1, 1, 1, 1)
  end)
  return ok
end

-- How many columns drawCommandGrid lays `n` items out in, for the same rect
-- `opts` describes. Exported because the cursor has to agree with the paint:
-- a left/right press that assumes four across while the band actually drew
-- 2×2 walks the highlight onto a slab that is not next to the one it left.
-- drawCommandGrid calls this too, so the two can never drift apart — one
-- definition, and every caller reads it rather than restating the rule.
-- Zero items means zero columns (nothing is laid out); the widget bails there.
function M.bandGridCols(n, opts)
  n = math.floor(num(n, 0))
  if n <= 0 then return 0 end
  local _, _, w = M.bandRect(opts)
  return (w >= 420 and n <= 4) and n or 2
end

-- FIGHT / PKMN / ITEM / RUN. Four across while the band is full width: 2×2
-- over the 620×72 band makes 307×33 slabs that read as list rows, not buttons,
-- where 150×72 is a button shape. A caller that boxes the grid into a narrower
-- slot falls back to two columns, where 4-across would be too tight to label.
-- `cursor` is the 1-based highlighted item; items are { label, disabled? }.
function M.drawCommandGrid(items, cursor, opts)
  local gfx = g()
  if not gfx then return false end
  items = listOf(items)
  local n = #items
  if n == 0 then return false end
  local x, y, w, h = M.bandRect(opts)
  cursor = math.floor(num(cursor, 0))
  -- Same opts, same rect, same rule as any caller's navigation asks for.
  local cols = M.bandGridCols(n, opts)
  if cols < 1 then return false end
  local rows = math.ceil(n / cols)
  local gap = 6
  local bw = math.floor((w - gap * (cols - 1)) / cols)
  local bh = math.floor((h - gap * (rows - 1)) / rows)
  if bw < 8 or bh < 8 then return false end
  local ok = pcall(function()
    withFont(gfx, M.FONT_PRIMARY, function(font)
      for i, item in ipairs(items) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local bx = x + col * (bw + gap)
        local by = y + row * (bh + gap)
        local label = item
        local dim = false
        if type(item) == "table" then
          label = item.label
          dim = item.disabled and true or false
        end
        label = fitLine(font, tostring(label or ""), bw - 10)
        -- A disabled item still shows the cursor when it is on it: the caller
        -- decides what a press does, and a vanished cursor reads as a freeze.
        local hot = (i == cursor)
        panel(gfx, bx, by, bw, bh, hot)
        setColor(gfx, dim and TEXT_DIM or TEXT_ON)
        gfx.print(label,
          bx + math.floor((bw - widthWith(font, label)) / 2),
          by + math.floor((bh - heightWith(font)) / 2))
      end
    end)
    gfx.setColor(1, 1, 1, 1)
  end)
  return ok
end

-- Moves / items / party: a scrolling list of { label, right?, dim? }. `right`
-- is right-aligned in the secondary colour (PP "12/15", a type name);
-- opts.title prints a small header, opts.visible overrides the row count.
function M.drawListPanel(rows, cursor, opts)
  local gfx = g()
  if not gfx then return false end
  rows = listOf(rows)
  opts = type(opts) == "table" and opts or {}
  local x, y, w, h = M.bandRect(opts)
  local pad = LIST_PAD_X
  local title = nil
  if type(opts.title) == "string" and opts.title ~= "" then title = opts.title end
  local top = y + LIST_PAD_Y + (title and LIST_TITLE_H or 0)
  local avail = h - LIST_PAD_Y * 2 - (title and LIST_TITLE_H or 0)
  local visible = clamp(math.floor(avail / LIST_ROW_MIN), 1, 5)
  if opts.visible then
    visible = clamp(math.floor(num(opts.visible, visible)), 1, visible)
  end
  local rowH = clamp(math.floor(avail / visible), LIST_ROW_MIN, LIST_ROW_MAX)
  local count = #rows
  cursor = clamp(math.floor(num(cursor, 1)), 1, math.max(1, count))
  local first = 1
  if cursor > visible then first = cursor - visible + 1 end
  first = math.min(first, math.max(1, count - visible + 1))

  -- An empty row list is still a success: the panel and its title are what a
  -- "no moves left" list is supposed to show, so it must not trip a fallback.
  local ok = pcall(function()
    panel(gfx, x, y, w, h)
    if title then
      withFont(gfx, M.FONT_MICRO, function(micro)
        setColor(gfx, TEXT_MUTED)
        gfx.print(tostring(title):upper(), x + pad + 2, y + LIST_PAD_Y - 1)
      end)
    end
    withFont(gfx, M.FONT_SECONDARY, function(font)
      local th = heightWith(font)
      for slot = 0, visible - 1 do
        local row = rows[first + slot]
        if row then
          local ry = top + slot * rowH
          local label = row
          local right, dim = nil, false
          if type(row) == "table" then
            label = row.label
            right = row.right
            dim = row.dim and true or false
          end
          local hot = (first + slot) == cursor
          if hot then
            gfx.setColor(1, 1, 1, 0.10)
            gfx.rectangle("fill", x + pad - 2, ry - 1, w - pad * 2 + 4,
              rowH, 2, 2)
            setColor(gfx, PANEL_LINE_HOT)
            gfx.rectangle("fill", x + pad - 2, ry, 2, rowH - 2)
          end
          local ty = ry + math.floor((rowH - th) / 2)
          local rightW = 0
          if right ~= nil and tostring(right) ~= "" then
            right = tostring(right)
            rightW = widthWith(font, right) + 8
            setColor(gfx, dim and TEXT_DIM or TEXT_MUTED)
            gfx.print(right, x + w - pad - rightW + 8, ty)
          end
          setColor(gfx, dim and TEXT_DIM or (hot and TEXT_ON or TEXT_MUTED))
          gfx.print(fitLine(font, tostring(label or ""),
            w - pad * 2 - rightW - 6), x + pad + 4, ty)
        end
      end
      -- Scroll thumb, only when there is something off-panel.
      if count > visible then
        local trackH = visible * rowH
        local thumbH = math.max(6, trackH * visible / count)
        local span = trackH - thumbH
        local at = (count > visible) and ((first - 1) / (count - visible)) or 0
        gfx.setColor(1, 1, 1, 0.10)
        gfx.rectangle("fill", x + w - pad + 1, top, 2, trackH, 1, 1)
        gfx.setColor(1, 1, 1, 0.45)
        gfx.rectangle("fill", x + w - pad + 1, top + span * at, 2, thumbH, 1, 1)
      end
    end)
    gfx.setColor(1, 1, 1, 1)
  end)
  return ok
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
      drawArena()

      for _, h in ipairs(layout.humans) do
        pcall(drawHuman, h, layout.frame, eng)
      end
      for _, mon in ipairs(layout.mons) do
        pcall(drawMonIcon, mon, layout.frame,
          hasFx and M.fxSeat(layout.fx, mon.side, mon.seatIndex) or nil)
      end
      -- Balls / poofs sit above the mons (a ball occludes the seat it lands
      -- on) but under the HUD, which never yields the field.
      if hasFx then pcall(drawFieldFx, layout) end
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
