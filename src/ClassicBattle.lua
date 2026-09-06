-- Classic 160×144 battle chrome, opted into from the mod manager.
--
-- The 640×360 Battlefield theatre is the default for every generation the
-- arena knows. This module is the other skin: engine Font.drawBox / HudTiles
-- drawn from the player's own decoded ROM (those pixels never ship here),
-- the guild-focus 1v1 center + side thumbnails of every living field
-- seat (including the focused pair) for 2x2 / 3x3, and a thin
-- EXP bar on the focused-ally HUD.
--
-- Owns the option key and label so src/Client.lua (which defines the row)
-- and the two battle screens (which read it) cannot drift. Same pattern as
-- SoloBattle.OPTION. The default lives on Config so a silent flip to on
-- has one constant a test can pin.

local need, mod = ...

local M = {}

M.OPTION = "classicui"
M.OPTION_LABEL = "CLASSIC BATTLE UI"

-- Read live. A fight latches the answer at construction (`latched`) so
-- flipping the row mid-battle cannot swap chrome under a live turn.
function M.wanted()
  local ok, on = pcall(function()
    return mod.options and mod.options:get(M.OPTION)
  end)
  return ok and on == true
end

-- `override` is for constructors and the headless suite: a boolean wins,
-- nil falls through to the live row (and so to off when there is no row).
function M.latched(override)
  if override ~= nil then return override == true end
  return M.wanted()
end

-- Bottom message / FIGHT pane. Same 18×2 inner grid CoopBattle wraps to.
M.BOX_COLS = 18
M.BOX_ROWS = 2

-- Soft-wrap one string into lines that fit the bottom box.
--
-- Collapses runs of whitespace so a typewriter-spaced line does not paint
-- through the right border. Prefers a break at the last space that still
-- fits; otherwise hard-cuts. Author newlines stay paragraph breaks.
function M.wrapBoxLines(text, width)
  width = width or M.BOX_COLS
  local lines = {}
  local raw = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  if raw == "" then return { "" } end
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    local rest = line:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "" then
      lines[#lines + 1] = ""
    else
      while #rest > width do
        local chunk = rest:sub(1, width)
        local space = chunk:match("^.*()%s")
        local breakAt = width
        if space and space > 1 then breakAt = space - 1 end
        lines[#lines + 1] = rest:sub(1, breakAt):gsub("%s+$", "")
        rest = rest:sub(breakAt + 1):gsub("^%s+", "")
      end
      if rest ~= "" then lines[#lines + 1] = rest end
    end
  end
  if #lines == 0 then return { "" } end
  return lines
end

-- Pages of at most BOX_ROWS lines, each line already <= width.
function M.pageBoxText(text, width)
  local lines = M.wrapBoxLines(text, width or M.BOX_COLS)
  local pages = {}
  for i = 1, #lines, M.BOX_ROWS do
    local page = lines[i]
    if lines[i + 1] then page = page .. "\n" .. lines[i + 1] end
    pages[#pages + 1] = page
  end
  if #pages == 0 then pages[1] = "" end
  return pages
end

-- Vanilla RBY FIGHT pane: names on the left, TYPE/ + PP of the cursor
-- on the right. Shared so MediatedBattle cannot drift from CoopBattle.
M.MOVE_NAME_Y = function(i) return 96 + i * 8 end
M.MOVE_NAME_X = 16
-- Ten tiles before the TYPE seam. 12-glyph names (THUNDERBOLT) used to
-- scale-squash into the glyphs; truncate with a dot instead.
M.MOVE_NAME_MAX_W = 80
M.MOVE_NAME_MIN_SCALE = 0.92
M.MOVE_TYPE_LABEL_Y = 112
M.MOVE_TYPE_NAME_Y = 120
M.MOVE_PP_Y = 128

-- Draw `text` at (x, y), scaling on X only when it would run past `maxW`.
function M.drawFittedText(Font, text, x, y, maxW)
  text = tostring(text or "")
  local w = 0
  if Font and Font.width then
    local ok, measured = pcall(Font.width, text)
    if ok and type(measured) == "number" then w = measured end
  end
  if w <= 0 then w = #text * 8 end
  if w <= maxW then
    if Font and Font.draw then Font.draw(text, x, y) end
    return
  end
  local minScale = M.MOVE_NAME_MIN_SCALE or 0.75
  if maxW / w < minScale then
    local budget = math.max(1, math.floor(maxW / 8))
    if Font and Font.draw then
      if budget > 1 then
        Font.draw(text:sub(1, budget - 1) .. ".", x, y)
      else
        Font.draw(text:sub(1, 1), x, y)
      end
    end
    return
  end
  local g = love and love.graphics
  if not (g and g.push and g.scale and g.translate and g.pop) then
    local budget = math.max(1, math.floor(maxW / 8))
    if Font and Font.draw then Font.draw(text:sub(1, budget), x, y) end
    return
  end
  local s = maxW / w
  g.push()
  g.translate(x, y)
  g.scale(s, 1)
  Font.draw(text, 0, 0)
  g.pop()
end

-- Referee roster string (`o` ok / `s` status / `x` fainted) or a party
-- table → the `{hp, status}` list engine `drawBallRow` reads.
--
-- Only real party members: unused sixth-slots stay off the row so a
-- two-mon NPC reads as two balls, not two plus four empties.
function M.partyFromRoster(team)
  local party = {}
  if type(team) == "string" then
    for i = 1, math.min(#team, 6) do
      local tok = team:sub(i, i)
      if tok == "x" then
        party[#party + 1] = { hp = 0 }
      elseif tok == "s" then
        party[#party + 1] = { hp = 1, status = "PSN" }
      elseif tok == "o" then
        party[#party + 1] = { hp = 1 }
      end
    end
  elseif type(team) == "table" then
    for i = 1, math.min(#team, 6) do
      local mon = team[i]
      if type(mon) == "table" then
        party[#party + 1] = {
          hp = tonumber(mon.hp) or 0,
          status = mon.status,
        }
      end
    end
  end
  if #party == 0 then return nil end
  return party
end

-- Flatten extra roster tokens onto `dst` (capped at 6). 2×2 / 3×3
-- trainers become one row instead of a stack that walks into the pics.
function M.appendRoster(dst, team)
  local extra = M.partyFromRoster(team)
  if not extra then return dst end
  dst = dst or {}
  for i = 1, #extra do
    if #dst >= 6 then break end
    dst[#dst + 1] = extra[i]
  end
  return dst
end

-- Wild fights have no remaining-party chrome (vanilla).
function M.wantsFoeBalls(mode)
  return mode ~= "wild" and mode ~= "coop_wild"
end

-- One row on the foe plate's bottom tile (tx=3, tw=8, th=5 → 24,32).
-- Six 8px tiles stay inside that 64px plate (foe pic at x=88) and
-- finish at STAGE_ALLY.y (40), so they sit under the HP bar instead
-- of on the ally back-pic.
M.FOE_BALL_X = 24
M.FOE_BALL_Y = 32
M.FOE_BALL_DX = 8
M.FOE_BALL_ROW = 8

-- Player-cache `balls.png` (same sheet BattleState uses). Only real
-- party members: the engine helper always stamps six tiles, which turned
-- a 2-mon NPC into two balls plus four empties across Charizard's head.
local ballQuads
local function loadBallQuads()
  if ballQuads then return ballQuads end
  -- Misses are not cached: the player cache may not exist on the first
  -- frame, and a sticky failure fell through to engine drawBallRow,
  -- which pads to six empties across the foe pic.
  if not (love and love.graphics and love.graphics.newImage) then
    return nil
  end
  local ok, img = pcall(love.graphics.newImage, "assets/generated/battle/balls.png")
  if not ok or not img then
    return nil
  end
  local quads = { img = img }
  local iw, ih = img:getDimensions()
  for i = 0, 3 do
    quads[i] = love.graphics.newQuad(i * 8, 0, 8, 8, iw, ih)
  end
  ballQuads = quads
  return quads
end

function M.drawBallRow(BattleState, party, x, y, dx)
  if type(party) ~= "table" or #party == 0 then return false end
  if not (love and love.graphics) then return false end
  dx = dx or -8
  local quads = loadBallQuads()
  if quads then
    love.graphics.setColor(1, 1, 1, 1)
    for i, mon in ipairs(party) do
      local tile = (tonumber(mon.hp) or 0) <= 0 and 2
        or (mon.status and 1) or 0
      love.graphics.draw(quads.img, quads[tile], x + (i - 1) * dx, y)
    end
    return true
  end
  -- Fallback: engine helper pads to 6. Better than nothing headless-with-ROM.
  if BattleState and BattleState.drawBallRow then
    return pcall(BattleState.drawBallRow, BattleState, party, x, y, dx) == true
  end
  return false
end

-- Outer span of HudTiles.drawHPBar's six fill tiles (not the HP: prefix).
M.HP_BAR_PX = 48

-- Left edge of those fill tiles, given the same tx drawHPBar was called with.
function M.hpBarFillX(tx)
  return (tonumber(tx) or 0) * 8 + 16
end

-- Gen 2 FillInExpBar: a 1px blue fill on a white track, black outline.
-- `width` is the outer frame — the same pixel span as the HP bar it sits
-- under — so the two share a left edge and a right edge. The 1px outline
-- lives inside that span (it used to hang 1px outside and read longer).
-- Headless: no-op.
function M.drawExpBar(fraction, px, py, width)
  local g = love and love.graphics
  if not (g and g.rectangle) then return false end
  width = math.max(3, math.floor(tonumber(width) or M.HP_BAR_PX))
  local inner = width - 2
  local frac = tonumber(fraction)
  if not frac or frac ~= frac then frac = 0 end
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  local pixels = math.floor(frac * inner)
  g.setColor(0, 0, 0, 1)
  g.rectangle("fill", px, py - 1, width, 3)
  g.setColor(1, 1, 1, 1)
  g.rectangle("fill", px + 1, py, inner, 1)
  if pixels > 0 then
    g.setColor(0.3, 0.55, 0.95, 1)
    g.rectangle("fill", px + 1, py, pixels, 1)
  end
  g.setColor(0, 0, 0, 1)
  return true
end

return M
