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
