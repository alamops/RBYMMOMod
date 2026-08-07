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
-- lets the face stay small and antialiased at any window size -- Rajdhani
-- has the lowercase and punctuation the ROM font does not, and it is meant
-- to be read at ~12px with a linear filter, not scaled up with the letterbox.
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

-- Layout in *window* pixels.  Kept small on purpose: a toast is a glance,
-- not a second HUD, and growing with the letterbox scale made the old
-- pixel face dominate the corner on any window larger than 1x.
local PAD = 3                       -- plate margin around the text
local INSET = 6                     -- gap between the plate and the corner
local ROW_GAP = 2                   -- air between stacked rows

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

  -- Linear: this is a smooth HUD face at a small size, not a pixel sheet.
  pcall(font.setFilter, font, "linear", "linear")
  fonts[size] = font
  return font
end

-- Point size for the toast face.  Anchored in window pixels so a 4x window
-- does not get four times the type -- that was the whole complaint about
-- the previous face.  A tiny bump above 2x keeps it readable on a big
-- monitor without ever looking like a banner.
local function toastSize(scale)
  local base = tonumber(Config.TOAST_SIZE) or 12
  scale = tonumber(scale) or 1
  if scale >= 4 then return base + 2 end
  if scale >= 3 then return base + 1 end
  return base
end

-- The longest prefix of `text` that fits, and whatever is left of it.
--
-- Measured with the font rather than counted, because this face is bundled
-- and the fallback is not: the two do not agree on how wide anything is, and
-- a column count that fits one overflows the other.  The walk steps whole
-- UTF-8 sequences so a break can never hand the renderer half a glyph --
-- names are sanitised, but the party marker upstream is already three bytes
-- and nothing here should be the thing that assumes otherwise.
local TAIL = "..."

local function split(font, text, maxWidth)
  local cut, index = 0, 1
  while index <= #text do
    local byte = text:byte(index)
    local size = 1
    if byte >= 0xF0 then size = 4
    elseif byte >= 0xE0 then size = 3
    elseif byte >= 0xC0 then size = 2 end
    local stop = index + size - 1
    if font:getWidth(text:sub(1, stop)) > maxWidth then break end
    cut, index = stop, stop + 1
  end
  return text:sub(1, cut), text:sub(cut + 1)
end

-- Cut a line to what the plate has room for, with an ellipsis to say so.
-- Only ever reached for the last row of an entry that wrapped past its cap.
local function fit(font, text, maxWidth)
  if maxWidth <= 0 then return "" end
  if font:getWidth(text) <= maxWidth then return text end
  local budget = maxWidth - font:getWidth(TAIL)
  if budget <= 0 then return "" end
  local head = split(font, text, budget)
  if head == "" then return "" end
  return head .. TAIL
end

-- How many rows one queue entry may grow to.
--
-- A wrapped entry is still one entry against Config.TOAST_MAX -- it has to
-- be, or a chatty friend would push an arrival off the stack twice as fast
-- as a quiet one -- so the bound on how much screen the stack can eat has to
-- live here instead.  Three rows times five entries is fifteen, which is the
-- most the corner will ever hold, and a sentence that needs a fourth is the
-- one case still worth an ellipsis.
local WRAP_MAX = 3

-- Break a line into rows the plate has room for, on word boundaries.
--
-- Wrapping rather than cutting is the whole point: a chat line or a capture
-- sentence is longer than a nameplate-width plate, and a sentence broken
-- between words is read at a glance where the same sentence cut mid-way is
-- not read at all.
--
-- A single word too long for a row of its own is broken mid-word, because a
-- name or a species with no space in it must not be the thing that decides
-- how wide the plate is.
local function wrap(font, text, maxWidth)
  if maxWidth <= 0 then return {} end

  local words = {}
  for word in text:gmatch("%S+") do words[#words + 1] = word end

  local rows, line, index = {}, "", 1
  while index <= #words do
    local word = words[index]
    local candidate = line == "" and word or (line .. " " .. word)
    if font:getWidth(candidate) <= maxWidth then
      line, index = candidate, index + 1
    elseif line ~= "" then
      rows[#rows + 1] = line
      line = ""
    else
      local head, tail = split(font, word, maxWidth)
      -- Not even one glyph fits: there is no row to put anything on, and
      -- looping would spin forever on a word that never shrinks.
      if head == "" then return rows end
      rows[#rows + 1] = head
      words[index] = tail
    end
  end
  if line ~= "" then rows[#rows + 1] = line end

  if #rows > WRAP_MAX then
    -- Everything past the cap is folded back onto the last row it fits on,
    -- so the ellipsis lands where the sentence actually stops rather than at
    -- a word boundary the reader cannot see.
    local overflow = fit(font, table.concat(rows, " ", WRAP_MAX, #rows), maxWidth)
    for n = #rows, WRAP_MAX, -1 do rows[n] = nil end
    if overflow ~= "" then rows[WRAP_MAX] = overflow end
  end
  return rows
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

-- How wide one row of a toast may be, in window pixels.
--
-- Deliberately not the playfield.  A nameplate belongs to a character
-- standing on a tile and is therefore bounded by the tiles; a toast belongs
-- to nobody on the map and is drawn in window space, so the room it may use
-- is the room actually to its right -- which on any window worth playing on
-- is a good deal more than the 160 game pixels the letterbox is.
--
-- Capped at half again the playfield all the same: a maximised window would
-- otherwise let one chat line run the width of the desktop, and a toast that
-- has to be tracked across a monitor is no longer something read in passing.
local WIDE = 1.5

local function budgetWidth(viewport, scale, x, gameWidth)
  local room = gameWidth * WIDE
  local windowW = viewport and tonumber(viewport.width)
  if not (windowW and windowW > 0) then
    windowW = love.graphics.getWidth and love.graphics.getWidth() or nil
  end
  if windowW and windowW > 0 then
    room = math.min(room, windowW - x - INSET)
  end
  return math.max(0, room - PAD * 2)
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

-- The two verdicts that cost nothing to reach, answered from a shared table
-- rather than a fresh one.  draw() runs every frame and the queue is empty on
-- nearly all of them, so building a diagnostic nobody asked for on the idle
-- path is the allocation the engine's hot-path rule is about.  Read by
-- M:state and never written by it.
local EMPTY = { reached = "empty", drawn = 0 }
local NO_GRAPHICS = { reached = "no-graphics", drawn = 0 }

function M:draw(viewport)
  if not (love and love.graphics) then self.last = NO_GRAPHICS return end
  if #self.queue == 0 then self.last = EMPTY return end

  local last = { reached = "entered", drawn = 0 }
  self.last = last

  local scale, gameX, gameY, gameWidth, derived = geometry(viewport)
  last.scale, last.gameX, last.gameY, last.derived = scale, gameX, gameY, derived

  local font = M.font(toastSize(scale))
  if not font then last.reached = "no-font" return end

  local rowH = font:getHeight() + PAD * 2
  local step = rowH + ROW_GAP
  local x = gameX + INSET
  local maxWidth = budgetWidth(viewport, scale, x, gameWidth)
  local restore = beginFrame()
  love.graphics.setFont(font)

  -- One entry, one or more rows.  Each row gets a plate of its own, sized to
  -- its own text, so a wrapped sentence reads as a block in the corner rather
  -- than as one plate with a ragged line in it.
  local y = gameY + INSET
  for _, entry in ipairs(self.queue) do
    for _, row in ipairs(wrap(font, entry.text, maxWidth)) do
      love.graphics.setColor(0, 0, 0, 0.65)
      love.graphics.rectangle("fill", x, y,
        font:getWidth(row) + PAD * 2, rowH)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.print(row, x + PAD, y + PAD)
      last.drawn = last.drawn + 1
      last.lines = last.lines or {}
      last.lines[#last.lines + 1] = row
      y = y + step
    end
  end

  endFrame(restore)
  last.reached = "drawn"
end

M.PAD, M.INSET, M.ROW_GAP = PAD, INSET, ROW_GAP
M.VIEW_W, M.VIEW_H, M.WRAP_MAX = VIEW_W, VIEW_H, WRAP_MAX
M.toastSize = toastSize

return M
