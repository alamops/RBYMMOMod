-- Toasts: the short-lived lines stacked in the corner of the screen.
--
-- Chat, arrivals and departures, and what your party member just fought are
-- all things that happen while the player is doing something else, so none
-- of them may take the screen.  A toast is the whole answer to that: it
-- appears without being asked for, it is readable from wherever the player
-- already is, and it goes away on its own.
--
-- Drawn in *window* space rather than the game's 160x144, which is the one
-- way this differs from src/Overlay.lua.  A nameplate belongs to a character
-- standing on a tile, so it has to live in the same coordinates that
-- character does; a toast belongs to nobody on the map.  Window space also
-- buys the font a real pixel per glyph pixel at any window size, and this
-- font is the reason that matters -- Press Start 2P has the lowercase and
-- the punctuation the ROM font does not, and it is only legible if its 8x8
-- cells land on whole pixels.  The size is therefore a whole multiple of the
-- letterbox scale, never a fraction of it.
--
-- The queue is deliberately separable from the drawing: push/update/clear is
-- plain arithmetic on a list and is pinned by the headless suite, where
-- there is no love at all, and draw() is a no-op without a graphics context
-- rather than a crash.

local need, mod = ...
local Config = need("Config")

local M = {}
M.__index = M

-- Game Boy geometry, for the case where the viewport arrives without a
-- usable scale (another mod owning the world pass -- see Overlay's draw).
local VIEW_W, VIEW_H = 160, 144

-- Layout, in game pixels; every one of them is multiplied by the letterbox
-- scale before it reaches the screen.  GLYPH is Press Start 2P's design
-- size: the face is drawn on an 8x8 grid, so any whole multiple of 8 is
-- crisp and anything else is not.
local GLYPH = 8
local PAD = 2                       -- plate margin around the text
local INSET = 2                     -- gap between the plate and the corner
local ROW = GLYPH + PAD * 2
local STEP = ROW + 1

function M.new(ctx)
  return setmetatable({ ctx = ctx, queue = {} }, M)
end

-- ------- the queue

-- Oldest first, which is the order they are drawn and the order they
-- expire.  An overflowing stack drops from the front: the line the player
-- has not read yet is the newest one, so it is the oldest that can go.
function M:push(text)
  if type(text) ~= "string" or text == "" then return nil end
  local entry = { text = text, age = 0 }
  self.queue[#self.queue + 1] = entry
  while #self.queue > Config.TOAST_MAX do table.remove(self.queue, 1) end
  return entry
end

function M:update(dt)
  dt = tonumber(dt) or 0
  local index = 1
  while index <= #self.queue do
    local entry = self.queue[index]
    entry.age = entry.age + dt
    if entry.age >= Config.TOAST_SECONDS then
      table.remove(self.queue, index)
    else
      index = index + 1
    end
  end
end

function M:clear() self.queue = {} end

-- A copy, not the live list: this is what mod.exports hands a driver, and a
-- driver holding the queue itself could age or empty it by accident.
function M:list()
  local out = {}
  for index, entry in ipairs(self.queue) do
    out[index] = { text = entry.text, age = entry.age }
  end
  return out
end

-- What the last draw decided, so a driver can ask why nothing appeared
-- instead of inferring it from a screenshot -- the same seam Overlay:state
-- exists for.
function M:state()
  return {
    count = #self.queue,
    lines = self:list(),
    last = self.last or { reached = "never" },
  }
end

-- ------- the sentences
--
-- Every line a toast ever shows is built here, and that is deliberate: the
-- wire carries *what happened* -- a kind, a species, a level -- and never the
-- prose for it.  Prose on the wire would have to be written twice, once in
-- each hub (server/lib/relay.js and src/Hub.lua), and the two would drift;
-- worse, it would be a stranger's process choosing the words that appear on
-- this player's screen.  So the hub relays fields and this file decides how
-- they read.
--
-- Every one of these answers nil rather than a half-built sentence, and
-- push() ignores a nil, so a caller can hand a formatter straight to it
-- without a branch in between.

-- What somebody said, as it appears in the corner.
--
-- No scope tag, unlike the chat screen's own line (Chat:line).  The
-- scrollback is a log being read deliberately, where "was that whispered or
-- global" is worth a column of its own; a toast is read in passing, and the
-- only two questions it has room to answer are who spoke and what they said.
function M.chatLine(name, text)
  if type(name) ~= "string" or type(text) ~= "string" then return nil end
  return ("[%s]: %s"):format(name, text)
end

-- Arrivals and departures.  Everyone on the hub sees these, which is what
-- makes "the server" the right word for where somebody went: it is the whole
-- population being told, not the map.
function M.joinLine(name)
  if type(name) ~= "string" then return nil end
  return ("%s joined the server"):format(name)
end

function M.partLine(name)
  if type(name) ~= "string" then return nil end
  return ("%s left the server"):format(name)
end

-- One party event as a sentence.
--
-- Split the way Wire.PARTY_EVENTS splits it -- a kind either needs a species
-- and a level or it needs a trainer -- so that the two files disagree loudly
-- (an unknown kind draws nothing) rather than quietly (a sentence with a nil
-- in the middle of it).  A kind this build has never heard of has no
-- sentence to put it in, which is exactly why that set is closed.
local MON_LINE = {
  defeat_wild      = "%s defeated %s lv %d",
  defeated_by_wild = "%s was defeated by %s lv %d",
  capture          = "%s captured %s lv %d",
}

local TRAINER_LINE = {
  defeat_trainer      = "%s defeated %s",
  defeated_by_trainer = "%s was defeated by %s",
}

function M.partyLine(event)
  if type(event) ~= "table" then return nil end
  local name = event.name
  if type(name) ~= "string" then return nil end

  local mon = MON_LINE[event.kind]
  if mon then
    if not (event.species and event.level) then return nil end
    return mon:format(name, event.species, event.level)
  end

  local trainer = TRAINER_LINE[event.kind]
  if not (trainer and event.trainer) then return nil end
  return trainer:format(name, event.trainer)
end

-- ------- drawing

-- One font per size, because the size follows the window: resizing the
-- window asks for a new one, and going back asks for the first again.
local fonts = {}
local warned = false

local function assetFont(size)
  local path
  local assets = mod and mod.assets
  if assets and assets.path then
    local ok, resolved = pcall(function() return assets:path(Config.TOAST_FONT) end)
    if ok and type(resolved) == "string" and resolved ~= "" then path = resolved end
  end
  if not path then return nil end
  local ok, font = pcall(love.graphics.newFont, path, size)
  if ok then return font end
  return nil
end

-- The bundled face, or LOVE's own if it cannot be loaded.  A missing font
-- costs the toasts their look, never the message: the fallback is drawn at
-- the same place with the same plate, only in a face nobody chose.
function M.font(size)
  local hit = fonts[size]
  if hit then return hit end
  if not (love and love.graphics and love.graphics.newFont) then return nil end

  local font = assetFont(size)
  if not font then
    if not warned then
      warned = true
      if mod and mod.log then
        mod.log:warn("could not load %s; notifications fall back to the "
          .. "engine's default font -- reinstall the mod folder so "
          .. "assets/fonts is present", tostring(Config.TOAST_FONT))
      end
    end
    local ok, made = pcall(love.graphics.newFont, size)
    if not ok then return nil end
    font = made
  end

  -- A pixel face scaled with a smoothing filter is a blurry pixel face.
  pcall(font.setFilter, font, "nearest", "nearest")
  fonts[size] = font
  return font
end

-- Cut a line to what the plate has room for, on a character boundary.
--
-- Measured with the font rather than counted, because this face is bundled
-- and the fallback is not: the two do not agree on how wide anything is, and
-- a column count that fits one overflows the other.  The walk steps whole
-- UTF-8 sequences so a cut can never hand the renderer half a glyph -- names
-- are sanitised, but the party marker upstream is already three bytes and
-- nothing here should be the thing that assumes otherwise.
local TAIL = "..."

local function fit(font, text, maxWidth)
  if maxWidth <= 0 then return "" end
  if font:getWidth(text) <= maxWidth then return text end
  local budget = maxWidth - font:getWidth(TAIL)
  if budget <= 0 then return "" end

  local cut, index = 0, 1
  while index <= #text do
    local byte = text:byte(index)
    local size = 1
    if byte >= 0xF0 then size = 4
    elseif byte >= 0xE0 then size = 3
    elseif byte >= 0xC0 then size = 2 end
    local stop = index + size - 1
    if font:getWidth(text:sub(1, stop)) > budget then break end
    cut, index = stop, stop + 1
  end
  if cut == 0 then return "" end
  return text:sub(1, cut) .. TAIL
end

-- The letterbox, or the window when the viewport does not describe one.
-- Same fallback as Overlay's draw and for the same reason: with another
-- mod's pipeline owning the frame, scale can arrive unusable, and bailing
-- there would mean the toasts silently never appeared.
local function geometry(viewport)
  local scale = viewport and tonumber(viewport.scale) or nil
  local x = viewport and tonumber(viewport.gameX) or 0
  local y = viewport and tonumber(viewport.gameY) or 0
  local width = viewport and tonumber(viewport.gameWidth) or nil
  local derived = false

  if not scale or scale <= 0 then
    local windowW, windowH = love.graphics.getDimensions()
    scale = math.max(1, math.floor(math.min(windowW / VIEW_W, windowH / VIEW_H)))
    x = math.floor((windowW - VIEW_W * scale) / 2)
    y = math.floor((windowH - VIEW_H * scale) / 2)
    width = VIEW_W * scale
    derived = true
  end
  if not width or width <= 0 then width = VIEW_W * scale end
  return scale, x, y, width, derived
end

-- Reset the graphics state before drawing and put it back after.
--
-- push() saves the transform and nothing else, so a shader or blend mode
-- left bound by whoever composited the frame is still active here -- which
-- is how Overlay's labels once drew every frame and appeared nowhere.  The
-- transform itself is untouched: this draws in window pixels, which is what
-- render.hud already hands us.
local function beginFrame()
  local restore = {
    shader = love.graphics.getShader(),
    blend = love.graphics.getBlendMode(),
    font = love.graphics.getFont(),
  }
  love.graphics.setShader()
  love.graphics.setBlendMode("alpha")
  return restore
end

local function endFrame(restore)
  love.graphics.setColor(1, 1, 1, 1)
  if not restore then return end
  if restore.font then love.graphics.setFont(restore.font) end
  love.graphics.setBlendMode(restore.blend)
  love.graphics.setShader(restore.shader)
end

function M:draw(viewport)
  self.last = { reached = "entered", drawn = 0 }
  local last = self.last
  if not (love and love.graphics) then last.reached = "no-graphics" return end
  if #self.queue == 0 then last.reached = "empty" return end

  local scale, gameX, gameY, gameWidth, derived = geometry(viewport)
  last.scale, last.gameX, last.gameY, last.derived = scale, gameX, gameY, derived

  local font = M.font(GLYPH * scale)
  if not font then last.reached = "no-font" return end

  local maxWidth = gameWidth - (INSET * 2 + PAD * 2) * scale
  local restore = beginFrame()
  love.graphics.setFont(font)

  local x = gameX + INSET * scale
  local y = gameY + INSET * scale
  for _, entry in ipairs(self.queue) do
    local text = fit(font, entry.text, maxWidth)
    if text ~= "" then
      love.graphics.setColor(0, 0, 0, 0.65)
      love.graphics.rectangle("fill", x, y,
        font:getWidth(text) + PAD * 2 * scale, ROW * scale)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.print(text, x + PAD * scale, y + PAD * scale)
      last.drawn = last.drawn + 1
      last.lines = last.lines or {}
      last.lines[#last.lines + 1] = text
    end
    y = y + STEP * scale
  end

  endFrame(restore)
  last.reached = "drawn"
end

M.GLYPH, M.PAD, M.INSET, M.ROW, M.STEP = GLYPH, PAD, INSET, ROW, STEP
M.VIEW_W, M.VIEW_H = VIEW_W, VIEW_H

return M
