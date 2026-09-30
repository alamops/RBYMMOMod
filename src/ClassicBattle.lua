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
--
-- On Gen 3 (FireRed / LeafGreen / Emerald) the classic skin is the cart's
-- own 240x160 battle page instead: see "Gen 3: the GBA battle page" at the
-- end of this file (M.drawGen3), which the two battle screens hand a plain
-- view model and which draws with the cart's battle chrome.

local need, mod = ...
-- Gen 3 engine reach (lazy, generation-guarded; nil off a Gen 3 boot).
local Gen3 = need("Gen3")

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

-- Same blue as Gen 2 FillInExpBar / the classic poke-card EXP strip.
M.EXP_BAR_BLUE = { 0.3, 0.55, 0.95, 1 }

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
-- Headless: no-op. Battle HUD only — the picker uses drawHudExpBar.
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
    g.setColor(M.EXP_BAR_BLUE)
    g.rectangle("fill", px + 1, py, pixels, 1)
  end
  g.setColor(0, 0, 0, 1)
  return true
end

-- Interior of the HP-pill fill trough. HudTiles' HP tiles are 8px:
-- black, white, black, *fill*, *fill*, black, white, black. A 4px slab
-- at y+2 painted over the inner black edges.
M.EXP_FILL_DY = 3
M.EXP_FILL_H = 2

-- Recolor the filled HP-pill interior. Tile tint clips the blue channel
-- (0.95 * 255/170 > 1) and leaks a pale second blue; a rectangle of
-- EXP_BAR_BLUE — the same RGB drawExpBar uses on the poke-card — is
-- painted into the 2px fill trough instead.
function M.paintExpFill(HudTiles, tx, ty, pixels)
  pixels = math.floor(tonumber(pixels) or 0)
  local g = love and love.graphics
  if not (g and g.rectangle) or pixels < 1 then return true end
  g.setColor(M.EXP_BAR_BLUE)
  g.rectangle("fill",
    M.hpBarFillX(tx), ty * 8 + M.EXP_FILL_DY,
    pixels, M.EXP_FILL_H)
  g.setColor(0, 0, 0, 1)
  return true
end

-- 0..HP_BAR_PX fill length for a HUD-style EXP bar. A nonzero fraction
-- always shows at least 1px — the same rule HudTiles.drawHPBar uses for HP.
function M.expBarPixels(fraction)
  local frac = tonumber(fraction)
  if not frac or frac ~= frac then return 0 end
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  local pixels = math.floor(frac * M.HP_BAR_PX)
  if frac > 0 and pixels < 1 then pixels = 1 end
  return pixels
end

-- 5px-tall HP / XP for the picker pills. Downscaling the 8px tile font
-- smears; these bitmaps stay crisp and sit in the $71 ligature slot,
-- flush with the $62 colon. `#` is a black pixel, `.` is empty.
M.HUD_BAR_LABELS = {
  HP = {
    "#.#.###",
    "###.#.#",
    "#.#.###",
    "#.#.#..",
    "#.#.#..",
  },
  XP = {
    "#.#.###",
    ".#..#.#",
    "#.#.###",
    ".#..#..",
    "#.#.#..",
  },
}

-- Replace drawHPBar's $71 ligature with a 5px HP/XP label. The $62 colon
-- tile stays, so both bars share the same chrome and the same origin.
function M.drawHudBarLetters(Font, text, tx, ty)
  tx = math.floor(tonumber(tx) or 0)
  ty = math.floor(tonumber(ty) or 0)
  text = tostring(text or "")
  local rows = M.HUD_BAR_LABELS[text]
  local g = love and love.graphics
  if g and g.rectangle then
    g.setColor(1, 1, 1, 1)
    g.rectangle("fill", tx * 8, ty * 8, 8, 8)
  end
  if rows and g and g.rectangle then
    local h = #rows
    local w = #rows[1]
    local x0 = tx * 8 + 8 - w - 1
    local y0 = ty * 8 + math.floor((8 - h) / 2)
    g.setColor(0, 0, 0, 1)
    for j, row in ipairs(rows) do
      for i = 1, #row do
        if row:sub(i, i) == "#" then
          g.rectangle("fill", x0 + i - 1, y0 + j - 1, 1, 1)
        end
      end
    end
    return true
  end
  if not (Font and Font.draw) then return false end
  if g and g.setColor then g.setColor(0, 0, 0, 1) end
  Font.draw(text, tx * 8 - 8, ty * 8)
  return true
end

-- Picker-only: the same 8px pill as HudTiles.drawHPBar (prefix + six
-- fill segments + cap). Fill is EXP_BAR_BLUE (the poke-card strip), not
-- HP green/yellow/red. The 1px Gen-2 strip stays on the battle HUD.
function M.drawHudExpBar(Font, HudTiles, data, tx, ty, fraction)
  local pixels = M.expBarPixels(fraction)
  tx = math.floor(tonumber(tx) or 0)
  ty = math.floor(tonumber(ty) or 0)
  local drew = false
  if HudTiles and HudTiles.drawHPBar and type(data) == "table" then
    local shown = { hp = pixels, stats = { hp = M.HP_BAR_PX } }
    drew = pcall(HudTiles.drawHPBar, data, tx, ty, shown, nil, true, 6, pixels)
  end
  local g = love and love.graphics
  if drew then
    M.paintExpFill(HudTiles, tx, ty, pixels)
    M.drawHudBarLetters(Font, "XP", tx, ty)
    return true
  end
  if not (g and g.rectangle) then return false end
  local px = M.hpBarFillX(tx)
  local py = ty * 8
  local width = M.HP_BAR_PX
  g.setColor(0, 0, 0, 1)
  g.rectangle("fill", px, py, width, 8)
  g.setColor(1, 1, 1, 1)
  g.rectangle("fill", px + 1, py + 1, width - 2, 6)
  if pixels > 0 then
    g.setColor(M.EXP_BAR_BLUE)
    g.rectangle("fill", px + 1, py + M.EXP_FILL_DY,
      math.min(pixels, width - 2), M.EXP_FILL_H)
  end
  g.setColor(0, 0, 0, 1)
  if Font and Font.draw then
    M.drawHudBarLetters(Font, "XP:", tx, ty)
  end
  return true
end

-- Full-page mid-battle party picker (classic 160×144).
--
-- PKMN / item-target / send-out used to be a three-row list in the bottom
-- command box. This is the opaque party screen instead: a top preview of
-- the highlighted mon (battle FRONT pic, the same art as the foe stage)
-- and a start-menu bag-icon list underneath. Layout is tile-aligned so
-- Font.drawBox / HudTiles / the party-menu icon painter stay on-grid.

M.PICKER_PREVIEW_TILES = 5
-- Preview band is 40px (5 tiles) of the full-screen box — no nested
-- drawBox, so that band is all content (the nested border ate a row
-- and sat the EXP pill on the divider). Six 16px bag-icon rows then
-- run y=40..136, the outer box's inner bottom.
M.PICKER_LIST_Y = 40
M.PICKER_ROW_H = 16
M.PICKER_VISIBLE = 6
M.PICKER_LIST_BOTTOM = 136
M.PICKER_FRONT_BOX = 56
M.PICKER_FRONT_X = 8
-- One tile under the outer box's top border. The 56px sheet is
-- scaled and scissored to the left slot so it never leaves the pane.
M.PICKER_FRONT_Y = 8
M.PICKER_NAME_X = 72
M.PICKER_NAME_Y = 8
-- LV is on every list row, so the preview spends this span on the name.
M.PICKER_NAME_MAX_W = 88
M.PICKER_TYPE_Y = 16
M.PICKER_TYPE_MAX_W = 64
-- Status sits on the type row, right of the fitted type label.
M.PICKER_META_Y = 16
M.PICKER_STATUS_X = 128
M.PICKER_LV_X = 120
M.PICKER_HP_TX = 9
M.PICKER_HP_TY = 3
M.PICKER_EXP_TY = 4
M.PICKER_CURSOR_X = 8
M.PICKER_ICON_X = 16
M.PICKER_ROW_NAME_X = 40
M.PICKER_ROW_LV_X = 120
M.PICKER_ROW_NAME_MAX_W = 72
-- 8px glyphs (name / LV / cursor) sit 4px down so they share the
-- horizontal midline of the 16px start-menu bag icon. Drawing them at
-- the icon's top y is what made PIKACHU read above the sprite.
M.PICKER_ROW_TEXT_DY = 4

-- First visible list index so `cursor` stays on-screen. Same rule as the
-- old 3-row command-box list: once you walk off the window, the highlight
-- sits on the last visible row.
function M.pickerScroll(cursor, count, visible)
  visible = math.max(1, math.floor(tonumber(visible) or M.PICKER_VISIBLE))
  cursor = math.max(1, math.floor(tonumber(cursor) or 1))
  count = math.max(0, math.floor(tonumber(count) or 0))
  if count <= visible then return 1 end
  local first = cursor - visible + 1
  if first < 1 then first = 1 end
  local last = count - visible + 1
  if first > last then first = last end
  return first
end

function M.pickerRowY(visibleIndex)
  local i = math.max(1, math.floor(tonumber(visibleIndex) or 1))
  return M.PICKER_LIST_Y + (i - 1) * M.PICKER_ROW_H
end

function M.pickerRowTextY(visibleIndex)
  return M.pickerRowY(visibleIndex) + M.PICKER_ROW_TEXT_DY
end

-- Species `types` as a single classic label ("FIRE", "FIRE/FLYING").
-- Strips the `_TYPE` suffix TypeChart ids carry (PSYCHIC_TYPE). Length is
-- the caller's problem: the preview runs the line through drawFittedText.
function M.typeLine(names)
  if type(names) ~= "table" then return "" end
  local function glyph(raw)
    local s = tostring(raw or ""):gsub("_TYPE$", "")
    if s == "" or s == "nil" then return nil end
    return s
  end
  local a = glyph(names[1])
  if not a then return "" end
  local b = glyph(names[2])
  if b and b ~= a then return a .. "/" .. b end
  return a
end

-- Display names for a species def's `types`, via TypeChart.displayName
-- when the engine module is present. Raw ids otherwise.
function M.typeNames(def, TypeChart)
  local types = def and def.types
  if type(types) ~= "table" then return {} end
  local out = {}
  for _, id in ipairs(types) do
    if #out >= 2 then break end
    local name = id
    if TypeChart and type(TypeChart.displayName) == "function" then
      local ok, shown = pcall(TypeChart.displayName, id)
      if ok and shown then name = shown end
    end
    name = tostring(name or ""):gsub("_TYPE$", "")
    if name ~= "" and name ~= "nil" then out[#out + 1] = name end
  end
  return out
end

-- Scissor a rect given in this page's own 160x144 coordinates.
--
-- `setScissor` takes WINDOW pixels. Gen 1 draws the page into a 160x144
-- canvas at the identity transform, so the two agree. Gold blits it straight
-- to the window under `translate + scale` (`Game2:drawScene`), where a raw
-- (0, 0, 160, 96) is a sliver of the window's corner -- it clipped our own
-- back pic away entirely. Mapped through the live transform the way Gold's own
-- `Chrome.clipTo` does, which is a no-op on Gen 1's canvas.
function M.setPageScissor(x, y, w, h)
  local g = love and love.graphics
  if not (g and g.setScissor) then return end
  if g.transformPoint then
    local okA, x1, y1 = pcall(g.transformPoint, x, y)
    local okB, x2, y2 = pcall(g.transformPoint, x + w, y + h)
    if okA and okB then
      -- Floor the near edge, ceil the far one, and measure between them: a
      -- width of ceil(|x2 - x1|) from a floored x falls a pixel short of a
      -- fractional far edge.
      x, y = math.floor(math.min(x1, x2)), math.floor(math.min(y1, y2))
      w = math.ceil(math.max(x1, x2)) - x
      h = math.ceil(math.max(y1, y2)) - y
    end
  end
  pcall(g.setScissor, x, y, w, h)
end

-- Left slot of the preview band (inside the outer 8px border, down to
-- the list). A 56px front sheet is taller than this; drawFrontPic
-- scales and scissors to it.
function M.frontPicClip()
  local border = 8
  return border, border, M.PICKER_FRONT_BOX, M.PICKER_LIST_Y - border
end

-- Scale a front sheet down so the whole figure fits the preview clip.
-- Never scales up — a small pic stays 1x and hangs from FRONT_Y.
function M.frontPicScale(w, h)
  w = math.max(1, math.floor(tonumber(w) or M.PICKER_FRONT_BOX))
  h = math.max(1, math.floor(tonumber(h) or M.PICKER_FRONT_BOX))
  local _, _, cw, ch = M.frontPicClip()
  local s = math.min(cw / w, ch / h, 1)
  if s ~= s or s <= 0 then return 1 end
  return s
end

-- Placement inside the preview slot. Center X, hang from FRONT_Y
-- (one tile under the top border). `w`/`h` are the *drawn* size
-- (already scaled); the clip still scissors any remainder.
function M.frontPicXY(w, h, boxX, boxY)
  boxX = math.floor(tonumber(boxX) or M.PICKER_FRONT_X)
  boxY = math.floor(tonumber(boxY) or M.PICKER_FRONT_Y)
  w = math.floor(tonumber(w) or M.PICKER_FRONT_BOX)
  h = math.floor(tonumber(h) or M.PICKER_FRONT_BOX)
  local _, _, cw = M.frontPicClip()
  local x = boxX + math.floor((cw - w) / 2)
  return x, boxY
end

function M.drawFrontPic(sprite, boxX, boxY)
  if not sprite then return false end
  local g = love and love.graphics
  if not (g and g.draw) then return false end
  if sprite.setFilter then pcall(function() sprite:setFilter("nearest", "nearest") end) end
  local ok, w, h = pcall(sprite.getDimensions, sprite)
  w = (ok and type(w) == "number" and w) or M.PICKER_FRONT_BOX
  h = (ok and type(h) == "number" and h) or M.PICKER_FRONT_BOX
  local scale = M.frontPicScale(w, h)
  local x, y = M.frontPicXY(w * scale, h * scale, boxX, boxY)
  g.setColor(1, 1, 1, 1)
  local scx, scy, scw, sch
  if g.getScissor then scx, scy, scw, sch = g.getScissor() end
  if g.setScissor then
    M.setPageScissor(M.frontPicClip())
  end
  local ok = pcall(g.draw, sprite, x, y, 0, scale, scale)
  if g.setScissor then
    if scw then pcall(g.setScissor, scx, scy, scw, sch)
    else pcall(g.setScissor) end
  end
  return ok == true
end

-- Start-menu bag icon (PartyMenu.drawIcon / PokemonIcon), falling back
-- to a 16×N sheet's first frame when the engine painter is missing (Gen 2
-- drawIcon is an instance method, not this function).
function M.drawPartyIcon(game, modules, row, x, y, selected, counter)
  if type(row) ~= "table" then return false end
  local g = love and love.graphics
  if not (g and g.draw) then return false end
  g.setColor(1, 1, 1, 1)
  local hp = math.floor(tonumber(row.hpForIcon or row.hp) or 0)
  local maxHp = math.floor(tonumber(row.maxHpForIcon or row.maxHp) or 0)
  if hp < 0 then hp = 0 end
  if maxHp < 1 then maxHp = 1 end
  if hp > maxHp then hp = maxHp end
  local species = row.species
  modules = modules or {}
  if type(game) == "table" and type(species) == "string" and species ~= "" then
    local PokemonIcon = modules.PokemonIcon
    if PokemonIcon and PokemonIcon.draw then
      local ok, drawn = pcall(PokemonIcon.draw, game, {
        species = species,
        hp = hp,
        maxHp = maxHp,
      }, x, y, { selected = selected == true, counter = counter or 0 })
      if ok and drawn == true then return true end
    end
    local PartyMenu = modules.PartyMenu
    if PartyMenu and type(PartyMenu.drawIcon) == "function" then
      local ok = pcall(PartyMenu.drawIcon, game, {
        species = species,
        hp = hp,
        stats = { hp = maxHp },
      }, x, y, selected == true, counter or 0)
      if ok then return true end
    end
  end
  local img = row.icon
  if not img then return false end
  if img.setFilter then pcall(function() img:setFilter("nearest", "nearest") end) end
  local ok, w, h = pcall(img.getDimensions, img)
  w = (ok and type(w) == "number" and w) or 16
  h = (ok and type(h) == "number" and h) or 16
  if h > 16 and w >= 16 and g.newQuad then
    local qok, quad = pcall(g.newQuad, 0, 0, 16, 16, w, h)
    if qok and quad then
      return pcall(g.draw, img, quad, x, y) == true
    end
  end
  return pcall(g.draw, img, x, y) == true
end

-- Healthy mons stay blank; only a real status (or FNT) is printed.
local function statusGlyph(row)
  if not row then return "" end
  if row.fainted or (tonumber(row.hp) or 1) <= 0 then return "FNT" end
  local status = row.status
  if type(status) == "string" and status ~= "" and status ~= "OK" then
    return status:sub(1, 3)
  end
  return ""
end

-- Opaque 160×144 party picker. `spec.rows` is the same ordered list the
-- input handler indexes (`switchIndex`); drawing a different set would
-- put the cursor on the monster above the one A sends out.
--
-- Returns false when there is nothing to pick, so the caller can keep
-- the "there's no one else" box.
function M.drawPartyPicker(Font, HudTiles, spec)
  spec = spec or {}
  local rows = spec.rows
  if type(rows) ~= "table" or #rows == 0 then return false end
  if not (Font and Font.draw) then return false end
  local g = love and love.graphics
  if g and g.setColor then g.setColor(1, 1, 1, 1) end
  if Font.drawBox then
    pcall(Font.drawBox, 0, 0, 20, 18)
  end

  local cursor = math.floor(tonumber(spec.cursor) or 1)
  if cursor < 1 then cursor = 1 end
  if cursor > #rows then cursor = #rows end
  local current = rows[cursor]
  local game = spec.game

  if current then
    M.drawFrontPic(current.front, M.PICKER_FRONT_X, M.PICKER_FRONT_Y)
    if g and g.setColor then g.setColor(0, 0, 0, 1) end
    local name = tostring(current.label or "")
    M.drawFittedText(Font, name, M.PICKER_NAME_X, M.PICKER_NAME_Y, M.PICKER_NAME_MAX_W)
    M.drawFittedText(Font, M.typeLine(current.types),
      M.PICKER_NAME_X, M.PICKER_TYPE_Y, M.PICKER_TYPE_MAX_W)
    local glyph = statusGlyph(current)
    if glyph ~= "" then
      Font.draw(glyph, M.PICKER_STATUS_X, M.PICKER_META_Y)
    end
    -- Level lives on the list rows; putting it in the preview squeezed
    -- the name to 6 glyphs (PIKAC.).
    local hp = tonumber(current.hp)
    local maxHp = tonumber(current.maxHp)
    if hp and maxHp then
      hp = math.floor(hp)
      maxHp = math.floor(maxHp)
      if maxHp < 1 then maxHp = 1 end
      local shown = { hp = hp, stats = { hp = maxHp } }
      local drew = HudTiles and game and game.data
        and pcall(HudTiles.drawHPBar, game.data, M.PICKER_HP_TX, M.PICKER_HP_TY,
          shown, nil, false)
      if drew then
        M.drawHudBarLetters(Font, "HP", M.PICKER_HP_TX, M.PICKER_HP_TY)
      end
      if g and g.setColor then g.setColor(0, 0, 0, 1) end
      -- The 5-tile preview has no spare row under the HP pill; the bar
      -- itself is the health readout. Fallback prints the fraction when
      -- HudTiles is missing (headless / stub Font).
      if not drew then
        Font.draw(("%d/%d"):format(hp, maxHp), M.PICKER_NAME_X, M.PICKER_HP_TY * 8)
      end
    end
    if current.expFrac ~= nil then
      M.drawHudExpBar(Font, HudTiles, game and game.data,
        M.PICKER_HP_TX, M.PICKER_EXP_TY, current.expFrac)
    end
  end

  if g and g.rectangle then
    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", 8, M.PICKER_LIST_Y, 144, 1)
  end

  local first = M.pickerScroll(cursor, #rows)
  local modules = spec.modules or {}
  local counter = spec.counter or 0
  local scx, scy, scw, sch
  if g and g.getScissor then
    scx, scy, scw, sch = g.getScissor()
  end
  if g and g.setScissor then
    -- Inner pane of the full-screen box: never let a 16px icon bleed
    -- onto the divider or the bottom border.
    M.setPageScissor(8, M.PICKER_LIST_Y, 144,
      M.PICKER_VISIBLE * M.PICKER_ROW_H)
  end
  for i = 0, M.PICKER_VISIBLE - 1 do
    local row = rows[first + i]
    if not row then break end
    local y = M.pickerRowY(i + 1)
    local textY = M.pickerRowTextY(i + 1)
    local selected = (first + i) == cursor
    M.drawPartyIcon(game, modules, row, M.PICKER_ICON_X, y, selected, counter)
    if g and g.setColor then g.setColor(0, 0, 0, 1) end
    M.drawFittedText(Font, tostring(row.label or ""),
      M.PICKER_ROW_NAME_X, textY, M.PICKER_ROW_NAME_MAX_W)
    local level = tonumber(row.level)
    if level then
      level = math.floor(level)
      if HudTiles and HudTiles.tile and level < 100 then
        pcall(HudTiles.tile, 0x6E, M.PICKER_ROW_LV_X, textY)
        Font.draw(tostring(level), M.PICKER_ROW_LV_X + 8, textY)
      else
        Font.draw(tostring(level), M.PICKER_ROW_LV_X, textY)
      end
    end
    if selected and Font.drawCode then
      Font.drawCode(0xED, M.PICKER_CURSOR_X, textY)
    end
  end
  if g and g.setScissor then
    if scx then pcall(g.setScissor, scx, scy, scw, sch)
    else pcall(g.setScissor) end
  end
  if g and g.setColor then g.setColor(1, 1, 1, 1) end
  return true
end

-- ======================================================================
-- Gen 3: the GBA battle page (FireRed / LeafGreen / Emerald)
-- ======================================================================
--
-- CLASSIC BATTLE UI on a Gen 3 boot is not the 160x144 GB page: it is the
-- cart's own 240x160 battle screen, drawn from the cart's own battle chrome
-- (src/ui/game3/battle_chrome.lua, read out of the player's import cache at
-- runtime -- no pixel of it is in this repo) at the positions the engine's
-- battle UI uses (src/core/game3/battle/ui.lua, healthbox.lua, which cite the
-- pret sources):
--
--   * the battle background for the map the fight started on, with its two
--     platforms (Battlefield.gen3TerrainKey -- the cart's own terrain rules);
--   * the foe's front pic on its platform (centre x 176, feet on y 71) and the
--     player's back pic on the near one (centre x 72, feet on y 115, under the
--     textbox exactly as the cart cuts it);
--   * the foe healthbox top-left (name, gender, Lv, HP bar, status icon, the
--     owned-ball marker) and the player's bottom-right (the same plus the HP
--     figures and the EXP bar);
--   * the 48px textbox: a message, the action menu (prompt + FIGHT / BAG /
--     POKéMON / RUN in the cart's order and words), or the move menu (four
--     names, PP in the cart's PP colours, TYPE/);
--   * pickers: POKéMON as a full page (front pic, HP bar, party icons), the
--     bag and target lists as a window over the field with the question in
--     the textbox.
--
-- **2v2 / 3v3 are the guild focus** (docs/plans/guild-focus-battle-ui.md,
-- classic-battle-ui-option.md), adapted to 240x160: the centre is the cart's
-- 1v1 stage for the focused pair, and every living field seat of a side is a
-- 32x32 party icon on a rail -- foes down the right edge above the player's
-- healthbox, allies down the left edge under the foe's -- with the focused one
-- animated, backed brighter and pointed at by the cart's arrow.
--
-- ------- the contract (what MediatedBattle / CoopBattle call)
--
--   M.drawGen3(view, state) -> true when drawn; false when the cart chrome is
--       not reachable (not a Gen 3 boot, headless, no cache) so the caller
--       can draw a plain page instead. Draws into the current canvas at the
--       240x160 origin: call it from the screen's `draw()` while the state is
--       up through Gen3Ui.pushState and its `drawsWidescreen()` says false.
--   M.gen3Layout(view) -> the page's rects (pure; the suite asserts them).
--   M.gen3CommandLabel(idOrLabel) -> the cart's own word for a command.
--   M.G3 -> the geometry constants.
--
-- `view` (every field optional unless marked):
--   foe, ally       the focused pair, each a seat:
--                     name, level | shownLevel, hp (the *shown* clock),
--                     maxHp, status ("PSN" "TOX" "PAR" "SLP" "FRZ" "BRN"),
--                     gender ("M" | "F" | nil), sprite | pic (the front pic
--                     for the foe, the back pic for the ally -- or mon /
--                     speciesId / species (+ form, shiny, personality) to
--                     resolve one; noPic = true says the caller already
--                     looked and there is none, so nothing is re-read each
--                     frame), elevation (else the cart's, from
--                     speciesId), substitute (the cart's doll stands in),
--                     hidden, alpha, dx, dy, flash (0..1), caught (foe: the
--                     owned-ball marker), expFrac (ally, 0..1); confused is
--                     accepted and not drawn (the cart's box has no mark)
--   message, hint   the textbox line (paged by the caller); hint draws ▼
--   hold            a wait line: never a ▼, whatever `hint` says
--   phase           accepted (the screen's own phase); the page reads the
--                   fields below instead
--   prompt          "What will\nX do?" (the action menu's question)
--   commands        labels in grid order (FIGHT BAG / POKéMON RUN), and
--   commandIndex    the cursor (1..4); aliases commandCursor
--   moves           { { label | name, type (name or pret number), pp, maxPp } }
--   cursor          the move cursor (1..4); alias moveCursor
--   list            { title, rows = { { label, right, dim, front, icon,
--                     level, hp, maxHp, status } }, cursor } -- a POKéMON
--                     list (rows with front / icon) is the full page, any
--                     other list is a window
--   foeStrip, allyStrip   2v2 / 3v3: { seats = { { icon | mon | species,
--                     name } ... }, focus = index } -- every living field seat
--   foeParty        the foe's remaining party for the ball row (a referee
--                   roster string "oosx" or a list of { hp, status }); drawn
--                   when mode is not a wild one
--   mode            "wild" / "coop_wild" suppress the ball row
--   trainer         { pic | picId = TRAINER_PIC id } -- the foe trainer, drawn where
--                   the foe stands while `showTrainer` is true or no foe
--                   seat is up
--   playerBack      { gender = 0|1 } -- the player's own back pic, drawn
--                   while `showPlayer` is true or no ally seat is up
--   weather         "RAIN" | "SUN" | "SAND" | "HAIL" (any case; "sandstorm",
--                   "sunny" too): the arena's weather painter over the field
--   evolveFront, evolveFlash   a bench evolution: a front pic mid-field
--   frame           an animation clock (60/s); else the state's, else time

-- pret / engine positions. Every number is a layout constant from the engine's
-- battle UI source (the pret lines it cites), not a byte out of any ROM.
M.G3 = {
  W = 240, H = 160,
  PANEL_Y = 112, PANEL_H = 48,           -- BattleChrome.drawPanel
  FOE_PIC_X = 176, FOE_FEET_Y = 71,      -- SINGLES[1] (176,40) + pic y-offset
  ALLY_PIC_X = 72, ALLY_FEET_Y = 115,    -- SINGLES[0] (72,80) + back offset + 4
  PIC = 64,
  FOE_BOX_X = 12, FOE_BOX_Y = 14,        -- healthbox centre (44,30) - (32,16)
  ALLY_BOX_X = 126, ALLY_BOX_Y = 72,     -- (158,88) - (32,16)
  -- the drawn part of each healthbox sheet (for the layout checks)
  FOE_BOX_VIS = { dx = 1, dy = 2, w = 100, h = 29 },
  ALLY_BOX_VIS = { dx = 0, dy = 2, w = 104, h = 37 },
  MSG_X = 10, MSG_Y = 122, MSG_W = 212,  -- the battle message printer
  BALLS_X = 40, BALLS_Y = 45, BALLS_DX = 10, BALL = 8,
  ICON = 32, ICON_TOP = 7,               -- icon art starts on row 7 or later
  STRIP_W = 32, STRIP_PITCH = 24,
  STRIP_FOE_X = 208, STRIP_FOE_Y = 0, STRIP_FOE_H = 72,
  STRIP_ALLY_X = 0, STRIP_ALLY_Y = 46, STRIP_ALLY_H = 66,
  TRAINER_X = 176, TRAINER_Y = 40,       -- draw_enemy_trainer centre
  FOE_DOLL_Y = 56, ALLY_DOLL_Y = 97,     -- Anim.substituteY: base + 16 / + 17
  PLAYER_BACK_X = 80, PLAYER_BACK_Y = 80,
  LIST_TX = 15, LIST_TY = 1, LIST_TW = 13, LIST_TH = 10, LIST_ROWS = 5,
  PARTY_ROWS = 5, PARTY_ROW_H = 24, PARTY_LIST_X = 84, PARTY_LIST_Y = 8,
  PARTY_PIC_X = 8, PARTY_PIC_Y = 8, PARTY_TITLE_Y = 138,
}
local G = M.G3

local function g3eng(name)
  if type(Gen3) ~= "table" or type(Gen3.engine) ~= "function" then return nil end
  return Gen3.engine(name)
end

-- Battlefield owns the picture arithmetic both skins share (pic bounds, icon
-- frames, the art resolvers, the terrain for this map). Reached at draw time:
-- the battle screens have always loaded it by then.
local function battlefield()
  local ok, BF = pcall(need, "Battlefield")
  if ok and type(BF) == "table" then return BF end
  return nil
end

local function gfx3()
  local l = rawget(_G, "love")
  return type(l) == "table" and l.graphics or nil
end

local function num3(v, fallback)
  local n = tonumber(v)
  if n == nil or n ~= n then return fallback end
  return n
end

-- ------- text

-- The healthbox's cream (the interior the "Lv" placeholder ink is painted
-- over, as healthbox.lua does) and its text / HP-figure colours. Plain colour
-- literals, the same ones the engine's healthbox code spells out.
local function c5(v) return math.floor(v * 255 / 31 + 0.5) / 255 end
local CREAM = { c5(31), c5(31), c5(27), 1 }
local HB_TEXT = {
  fg = { c5(8), c5(8), c5(8), 1 }, shadow = { c5(27), c5(26), c5(22), 1 },
}

-- The "Lv" placeholder the healthbox sheets bake (pret overwrites it with the
-- real level; healthbox.lua erases it pixel by pixel -- a rectangle eats the
-- border). Offsets inside the box, not pixel data.
local INK = {
  foe = {
    { 56, 10 }, { 56, 11 }, { 60, 11 }, { 62, 11 }, { 56, 12 }, { 60, 12 },
    { 62, 12 }, { 56, 13 }, { 60, 13 }, { 62, 13 }, { 56, 14 }, { 57, 14 },
    { 58, 14 }, { 59, 14 }, { 61, 14 }, { 57, 11 }, { 63, 11 }, { 57, 12 },
    { 63, 12 }, { 57, 13 }, { 63, 13 }, { 60, 14 }, { 62, 14 }, { 63, 14 },
    { 56, 15 }, { 57, 15 }, { 58, 15 }, { 59, 15 }, { 60, 15 }, { 61, 15 },
    { 62, 15 },
  },
  ally = {
    { 64, 10 }, { 64, 11 }, { 68, 11 }, { 70, 11 }, { 64, 12 }, { 68, 12 },
    { 70, 12 }, { 64, 13 }, { 68, 13 }, { 70, 13 }, { 64, 14 }, { 65, 14 },
    { 66, 14 }, { 67, 14 }, { 69, 14 }, { 65, 11 }, { 71, 11 }, { 65, 12 },
    { 71, 12 }, { 65, 13 }, { 71, 13 }, { 68, 14 }, { 70, 14 }, { 71, 14 },
    { 64, 15 }, { 65, 15 }, { 66, 15 }, { 67, 15 }, { 68, 15 }, { 69, 15 },
    { 70, 15 },
  },
}

local function eraseInk(gfx, x, y, pts)
  gfx.setColor(CREAM)
  for i = 1, #pts do
    gfx.rectangle("fill", x + pts[i][1], y + pts[i][2], 1, 1)
  end
  gfx.setColor(1, 1, 1, 1)
end

-- Every string meets the cart's charset first (Gen3Ui.printable): the font
-- prints a character it cannot map as a blank, and reads "{...}" as markup.
local printableFn = nil
local function printable(text)
  if printableFn == nil then
    local ok, Gen3Ui = pcall(need, "Gen3Ui")
    printableFn = (ok and type(Gen3Ui) == "table" and type(Gen3Ui.printable) == "function")
      and Gen3Ui.printable or false
  end
  text = tostring(text or "")
  if printableFn then
    local ok, out = pcall(printableFn, text)
    if ok and type(out) == "string" then return out end
  end
  return text
end
M.gen3Printable = printable

local function drawText(F, text, x, y, opts)
  if not (F and type(F.draw) == "function") then return 0 end
  local ok, w = pcall(F.draw, printable(text), x, y, opts)
  return ok and (tonumber(w) or 0) or 0
end

local function measure(F, text, opts)
  if F and type(F.measure) == "function" then
    local ok, w = pcall(F.measure, printable(text), opts)
    if ok and tonumber(w) then return tonumber(w) end
  end
  return #tostring(text or "") * 6
end

-- The longest prefix of `text` that measures within `px`.
local function fitText(F, text, px, opts)
  text = tostring(text or "")
  if measure(F, text, opts) <= px then return text end
  local cut = text
  while #cut > 1 and measure(F, cut, opts) > px do
    cut = cut:sub(1, -2)
    -- never leave half a UTF-8 sequence at the end
    while #cut > 1 and cut:byte(-1) and cut:byte(-1) >= 0x80 and cut:byte(-1) < 0xC0 do
      cut = cut:sub(1, -2)
    end
  end
  return cut
end

-- bgr555 -> rgba, for the Emerald text palettes the chrome manifest carries.
local function bgr555(v)
  v = tonumber(v) or 0
  return { c5(v % 32), c5(math.floor(v / 32) % 32), c5(math.floor(v / 1024) % 32), 1 }
end

-- Emerald's battle window text colours (pokeemerald battle_bg.c): the
-- manifest's windowTextPal, fg 13 / shadow 15.
local function rseWindowColors(C)
  local m = {}
  pcall(function() m = C.manifest() or {} end)
  local pal = m.windowTextPal or {}
  return { fg = bgr555(pal[14]), shadow = bgr555(pal[16]), bg = { 0, 0, 0, 0 } }
end

-- pokefirered battle_controller_player.c: the PP figure's colour band.
function M.gen3PpState(pp, maxPp)
  pp, maxPp = tonumber(pp) or 0, tonumber(maxPp) or 0
  if maxPp == pp then return 3 end
  if maxPp <= 2 then
    if pp > 1 then return 3 end
    return 2 - pp
  elseif maxPp <= 7 then
    if pp > 2 then return 3 end
    return 2 - pp
  end
  if pp == 0 then return 2 end
  if pp <= math.floor(maxPp / 4) then return 1 end
  if pp > math.floor(maxPp / 2) then return 3 end
  return 0
end
local PP_STATE_TO_ROW = { [0] = 1, [1] = 2, [2] = 3, [3] = 0 }

local function ppColors(C, F, pp, maxPp, rse)
  local state = M.gen3PpState(pp, maxPp)
  if rse then
    local c = rseWindowColors(C)
    local m = {}
    pcall(function() m = C.manifest() or {} end)
    local pp2 = m.ppTextPal
    if type(pp2) == "table" then
      c.fg = bgr555(pp2[state * 2 + 1])
      c.shadow = bgr555(pp2[state * 2 + 2])
    end
    return c
  end
  local SummaryChrome = g3eng("src.ui.game3.summary_chrome")
  local rows = nil
  pcall(function() rows = SummaryChrome.manifest().moveTextColors end)
  local row = type(rows) == "table" and rows[PP_STATE_TO_ROW[state]] or nil
  if type(row) ~= "table" or type(row.fg) ~= "table" then
    return F and F.COLOR and F.COLOR.NORMAL or nil
  end
  local function rgb(c) return { (c[1] or 0) / 255, (c[2] or 0) / 255, (c[3] or 0) / 255, 1 } end
  return { fg = rgb(row.fg), shadow = rgb(row.shadow or row.fg),
           bg = F and F.STDPAL and F.STDPAL[0] or { 0, 0, 0, 0 } }
end

-- A ROM text line, or the fallback when the text pack does not have it.
local function romPlain(key, fallback)
  local RomText = g3eng("src.core.game3.rom_text")
  if RomText and type(RomText.plain) == "function" then
    local ok, text = pcall(RomText.plain, key)
    if ok and type(text) == "string" and text ~= "" then return text end
  end
  return fallback
end

-- The battle menu's four labels, the way battle/ui.lua splits them out of
-- gText_BattleMenu: text and placeholder tags, broken on each newline.
local menuLabelsCache = nil
local function cartMenuLabels()
  if menuLabelsCache then return menuLabelsCache end
  local labels = {}
  local RomText = g3eng("src.core.game3.rom_text")
  if RomText and type(RomText.ir) == "function" then
    pcall(function()
      local buf = {}
      local function flush()
        if #buf > 0 then labels[#labels + 1] = table.concat(buf); buf = {} end
      end
      for _, seg in ipairs(RomText.ir("gText_BattleMenu")) do
        if seg.t == "text" then buf[#buf + 1] = seg.s
        elseif seg.t == "tag" and seg.tag then buf[#buf + 1] = seg.tag
        elseif seg.t == "nl" or (seg.t == "ext" and seg.cmd == 19) then flush() end
      end
      flush()
    end)
  end
  if #labels < 4 then labels = { "FIGHT", "BAG", "POKéMON", "RUN" } end
  menuLabelsCache = labels
  return labels
end

-- The cart's own word for a command id or a label a screen already has:
-- FIGHT, BAG (ITEM), POKéMON (SWITCH / PKMN), RUN. Anything else is kept.
local COMMAND_SLOT = {
  FIGHT = 1, ITEM = 2, BAG = 2, SWITCH = 3, PKMN = 3, POKEMON = 3,
  ["POKéMON"] = 3, RUN = 4,
}
function M.gen3CommandLabel(label)
  local key = tostring(label or ""):upper():gsub("\195\169", "E"):gsub("\195\137", "E")
  local slot = COMMAND_SLOT[key]
  if not slot then return tostring(label or "") end
  return cartMenuLabels()[slot] or tostring(label)
end

-- ------- the page's geometry (pure)

local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end

local function stripSeats(strip)
  if type(strip) ~= "table" then return {} end
  local seats = strip.seats or strip
  if type(seats) ~= "table" then return {} end
  return seats
end

-- The cells of one side's rail: 32 wide, one per seat, as tall as the rail
-- allows up to STRIP_PITCH (icon art is rows 7..31, so a 24px cell holds a
-- whole monster and a 22px one clips nothing that matters).
function M.gen3StripCells(side, count)
  count = math.max(0, math.floor(num3(count, 0)))
  local cells = {}
  if count == 0 then return cells end
  local x = (side == "foe") and G.STRIP_FOE_X or G.STRIP_ALLY_X
  local y0 = (side == "foe") and G.STRIP_FOE_Y or G.STRIP_ALLY_Y
  local room = (side == "foe") and G.STRIP_FOE_H or G.STRIP_ALLY_H
  local pitch = math.min(G.STRIP_PITCH, math.floor(room / count))
  for i = 1, count do
    cells[i] = rect(x, y0 + (i - 1) * pitch, G.STRIP_W, pitch)
  end
  return cells
end

function M.gen3Layout(view)
  view = type(view) == "table" and view or {}
  local out = {
    panel = rect(0, G.PANEL_Y, G.W, G.PANEL_H),
    foeStrip = M.gen3StripCells("foe", #stripSeats(view.foeStrip)),
    allyStrip = M.gen3StripCells("ally", #stripSeats(view.allyStrip)),
  }
  if view.foe then
    out.foeBox = rect(G.FOE_BOX_X + G.FOE_BOX_VIS.dx, G.FOE_BOX_Y + G.FOE_BOX_VIS.dy,
      G.FOE_BOX_VIS.w, G.FOE_BOX_VIS.h)
    out.foePic = rect(G.FOE_PIC_X - G.PIC / 2, G.FOE_FEET_Y + 1 - G.PIC, G.PIC, G.PIC)
  end
  if view.ally then
    out.allyBox = rect(G.ALLY_BOX_X + G.ALLY_BOX_VIS.dx, G.ALLY_BOX_Y + G.ALLY_BOX_VIS.dy,
      G.ALLY_BOX_VIS.w, G.ALLY_BOX_VIS.h)
    -- the part above the textbox: the cart hides the rest under it
    local top = G.ALLY_FEET_Y + 1 - G.PIC
    out.allyPic = rect(G.ALLY_PIC_X - G.PIC / 2, top, G.PIC, G.PANEL_Y - top)
  end
  if view.foeParty ~= nil and M.wantsFoeBalls(view.mode) then
    out.foeBalls = rect(G.BALLS_X, G.BALLS_Y, G.BALLS_DX * 5 + G.BALL, G.BALL)
  end
  if type(view.list) == "table" and not M.gen3IsPartyList(view.list) then
    out.list = rect((G.LIST_TX - 1) * 8, (G.LIST_TY - 1) * 8,
      (G.LIST_TW + 2) * 8, (G.LIST_TH + 2) * 8)
  end
  return out
end

-- A list whose rows are monsters (they carry a front pic or an icon) is the
-- POKéMON page; anything else is a window over the field.
function M.gen3IsPartyList(list)
  if type(list) ~= "table" or type(list.rows) ~= "table" then return false end
  for _, row in ipairs(list.rows) do
    if type(row) == "table" and (row.front ~= nil or row.icon ~= nil) then return true end
  end
  return false
end

-- ------- drawing pieces

-- A pic stood on its feet line: the art's lowest opaque row lands on `feetY`
-- (what the cart's pic offsets do), centred on `cx`.
local function drawStandingPic(gfx, BF, img, cx, feetY, seat)
  if not img then return end
  seat = seat or {}
  local ok, iw, ih = pcall(img.getDimensions, img)
  if not ok then return end
  local pad = BF and BF.picFloorPad and BF.picFloorPad(img) or 0
  local x = math.floor(cx - iw / 2 + num3(seat.dx, 0))
  local y = math.floor(feetY - (ih - 1 - pad) - num3(seat.elevation, 0) + num3(seat.dy, 0))
  local alpha = math.max(0, math.min(1, num3(seat.alpha, 1)))
  if alpha <= 0 then return end
  pcall(function() img:setFilter("nearest", "nearest") end)
  gfx.setColor(1, 1, 1, alpha)
  gfx.draw(img, x, y)
  local flash = math.max(0, math.min(1, num3(seat.flash, 0)))
  if flash > 0 and gfx.setBlendMode then
    local mode, alphaMode
    if gfx.getBlendMode then mode, alphaMode = gfx.getBlendMode() end
    gfx.setBlendMode("add")
    gfx.setColor(flash * alpha, flash * alpha, flash * alpha, 1)
    pcall(gfx.draw, img, x, y)
    pcall(gfx.setBlendMode, mode or "alpha", alphaMode)
  end
  gfx.setColor(1, 1, 1, 1)
end

-- The cart's Substitute doll in a seat, where the cart stands it
-- (pokefirered battle_anim_mons.c:286 substituteY: the foe's centred on
-- (176, 56), the player's on (72, 97)); the plush stand-in without the cache.
local function drawDoll(gfx, BF, back, seat)
  local img = BF and BF.gen3SubstituteDoll and BF.gen3SubstituteDoll(back) or nil
  local cx = back and G.ALLY_PIC_X or G.FOE_PIC_X
  local cy = back and G.ALLY_DOLL_Y or G.FOE_DOLL_Y
  local alpha = math.max(0, math.min(1, num3(seat and seat.alpha, 1)))
  if img then
    local ok, iw, ih = pcall(img.getDimensions, img)
    if ok then
      gfx.setColor(1, 1, 1, alpha)
      gfx.draw(img, math.floor(cx - iw / 2 + num3(seat and seat.dx, 0)),
        math.floor(cy - ih / 2 + num3(seat and seat.dy, 0)))
      gfx.setColor(1, 1, 1, 1)
      return
    end
  end
  if BF and BF.drawDollStandIn then
    BF.drawDollStandIn(gfx, cx, back and G.PANEL_Y or G.FOE_FEET_Y, back and 48 or 40, alpha, false)
  end
end

-- The first 64x64 frame of the player's back-pic sheet, one Quad per sheet
-- image for the life of the image rather than one per drawn frame (weak keys:
-- a sheet the engine drops takes its quad with it).
local backQuads = setmetatable({}, { __mode = "k" })
local function backQuad(gfx, image)
  local quad = backQuads[image]
  if quad ~= nil then return quad or nil end
  pcall(function()
    local iw, ih = image:getDimensions()
    quad = gfx.newQuad(0, 0, math.min(64, iw), math.min(64, ih), iw, ih)
  end)
  backQuads[image] = quad or false
  return quad
end

-- The seat's pic: what the screen resolved, else the art resolved here.
local function seatPic(BF, seat, back)
  if type(seat) ~= "table" then return nil end
  local img = seat.sprite or seat.pic
  if img then return img end
  if not BF or seat.noPic then return nil end
  local subject = seat.mon or tonumber(seat.speciesId) or tonumber(seat.species)
  if subject == nil then return nil end
  local opts = { form = seat.form, shiny = seat.shiny, personality = seat.personality }
  if back then return BF.gen3Back(subject, opts) end
  return BF.gen3Front(subject, opts)
end

local function ailmentOf(seat)
  local SummaryData = g3eng("src.core.game3.summary_data")
  if not (SummaryData and type(SummaryData.statusAilment) == "function") then return 0 end
  local ok, a = pcall(SummaryData.statusAilment,
    { status = seat.status, hp = math.max(1, num3(seat.hp, 1)) })
  return ok and (tonumber(a) or 0) or 0
end

local function drawNameGender(F, name, gender, x, y)
  local opts = { small = true, colors = HB_TEXT }
  drawText(F, name, x, y, opts)
  if gender ~= "M" and gender ~= "F" then return end
  local nw = measure(F, name, { small = true })
  local colors = F.COLOR and (gender == "M" and F.COLOR.PARTY_MALE or F.COLOR.PARTY_FEMALE)
  local glyph = gender == "M" and F.CHAR_MALE or F.CHAR_FEMALE
  if glyph and type(F.drawGlyph) == "function" then
    pcall(F.drawGlyph, glyph, x + nw, y, { small = true, colors = colors })
  end
end

-- pokefirered battle_interface.c:759 UpdateLvlInHealthbox: the Lv glyph and
-- the digits, right-aligned on the box's level column.
local function drawLevel(F, level, boxX, y, column)
  local digits = tostring(math.max(0, math.min(999, math.floor(num3(level, 1)))))
  local x = boxX + column + 5 * (3 - #digits)
  local lvW = 0
  if F.CHAR_LV_2 and type(F.advance) == "function" then
    local ok, w = pcall(F.advance, F.CHAR_LV_2, { small = true })
    lvW = ok and (tonumber(w) or 0) or 0
    pcall(F.drawGlyph, F.CHAR_LV_2, x, y, { small = true, colors = HB_TEXT })
  end
  if lvW <= 0 then lvW = 10 end
  drawText(F, digits, x + lvW, y, { small = true, colors = HB_TEXT })
end

local function drawFoeBox(gfx, C, F, seat)
  local x, y = G.FOE_BOX_X, G.FOE_BOX_Y
  pcall(C.drawEnemyBox, x, y)
  eraseInk(gfx, x, y, INK.foe)
  local maxHp = math.max(1, num3(seat.maxHp, 1))
  local hp = math.max(0, math.min(maxHp, num3(seat.hp, 0)))
  local ailment = ailmentOf(seat)
  local statused = ailment >= 1 and ailment <= 6
  pcall(C.drawHpBar, x + 24, y + 16, hp, maxHp, statused)
  drawNameGender(F, tostring(seat.name or "?"), seat.gender, x + 8, y + 3)
  drawLevel(F, seat.shownLevel or seat.level, x, y + 3, 64)
  local SummaryChrome = g3eng("src.ui.game3.summary_chrome")
  if statused and SummaryChrome then
    pcall(SummaryChrome.drawStatusIcon, x + 2, y + 16, ailment)
  elseif seat.caught and type(C.drawPartyBall) == "function" then
    pcall(C.drawPartyBall, x + 8, y + 16, "caught")
  end
  gfx.setColor(1, 1, 1, 1)
end

local function drawAllyBox(gfx, C, F, seat)
  local x, y = G.ALLY_BOX_X, G.ALLY_BOX_Y
  pcall(C.drawPlayerBox, x, y)
  eraseInk(gfx, x, y, INK.ally)
  -- the HP-figure window, cleared before the figures (erase_hp_window)
  gfx.setColor(CREAM)
  gfx.rectangle("fill", x + 56, y + 21, 40, 11)
  gfx.setColor(1, 1, 1, 1)
  local maxHp = math.max(1, num3(seat.maxHp, 1))
  local hp = math.max(0, math.min(maxHp, num3(seat.hp, 0)))
  pcall(C.drawHpBar, x + 32, y + 16, hp, maxHp, false)
  drawNameGender(F, tostring(seat.name or "?"), seat.gender, x + 16, y + 3)
  drawLevel(F, seat.shownLevel or seat.level, x, y + 3, 72)
  drawText(F, ("%3d/"):format(math.floor(hp)), x + 60, y + 21, { small = true, colors = HB_TEXT })
  drawText(F, ("%3d"):format(math.floor(maxHp)), x + 80, y + 21, { small = true, colors = HB_TEXT })
  local ailment = ailmentOf(seat)
  local SummaryChrome = g3eng("src.ui.game3.summary_chrome")
  if ailment >= 1 and ailment <= 6 and SummaryChrome then
    pcall(SummaryChrome.drawStatusIcon, x + 10, y + 24, ailment)
  end
  if seat.expFrac ~= nil and type(C.drawExpBar) == "function" then
    local frac = math.max(0, math.min(1, num3(seat.expFrac, 0)))
    pcall(C.drawExpBar, x + 32, y + 32, frac)
  end
  gfx.setColor(1, 1, 1, 1)
end

-- The foe's remaining party as the cart's party-summary balls (ok / status /
-- fainted, empty past the end of the party), under the foe's box.
local function ballKinds(party)
  local kinds = {}
  if type(party) == "string" then
    for i = 1, math.min(#party, 6) do
      local t = party:sub(i, i)
      kinds[i] = (t == "x" and "faint") or (t == "s" and "status") or "ok"
    end
  elseif type(party) == "table" then
    for i = 1, math.min(#party, 6) do
      local mon = party[i]
      if type(mon) == "table" then
        local hp = tonumber(mon.hp)
        if hp ~= nil and hp <= 0 then kinds[#kinds + 1] = "faint"
        elseif type(mon.status) == "string" and mon.status ~= "" then kinds[#kinds + 1] = "status"
        else kinds[#kinds + 1] = "ok" end
      end
    end
  end
  for i = #kinds + 1, 6 do kinds[i] = "empty" end
  return kinds
end
M.gen3BallKinds = ballKinds

local function drawFoeBalls(C, party)
  if type(C.drawPartyBall) ~= "function" then return end
  for i, kind in ipairs(ballKinds(party)) do
    pcall(C.drawPartyBall, G.BALLS_X + (i - 1) * G.BALLS_DX, G.BALLS_Y, kind)
  end
end

-- One side's rail of party icons.
local function drawStrip(gfx, BF, F, side, strip, frame)
  local seats = stripSeats(strip)
  if #seats == 0 or not BF then return end
  local cells = M.gen3StripCells(side, #seats)
  local focus = math.floor(num3(type(strip) == "table" and strip.focus, 0))
  local first, last = cells[1], cells[#cells]
  -- a cream rail with the healthbox's own dark edge behind the icons, so a
  -- pic behind it cannot muddy them
  gfx.setColor(CREAM)
  gfx.rectangle("fill", first.x, first.y, G.STRIP_W, last.y + last.h - first.y)
  gfx.setColor(c5(10), c5(13), c5(12), 1)
  gfx.rectangle("line", first.x + 0.5, first.y + 0.5, G.STRIP_W - 1,
    last.y + last.h - first.y - 1)
  local ok, sx, sy, sw, sh = pcall(function() return gfx.getScissor() end)
  for i, seat in ipairs(seats) do
    local cell = cells[i]
    local focused = i == focus
    if focused then
      gfx.setColor(1, 1, 1, 1)
      gfx.rectangle("fill", cell.x + 1, cell.y + 1, cell.w - 2, cell.h - 2)
    end
    local icon = type(seat) == "table" and seat.icon or nil
    if icon == nil and type(seat) == "table" then
      local subject = seat.mon or tonumber(seat.speciesId) or tonumber(seat.species)
      if subject ~= nil then icon = BF.gen3Icon(subject) end
    end
    local img, quad = BF.gen3IconFrame(icon, focused and BF.gen3IconBob(frame) or 0)
    if img then
      pcall(gfx.setScissor, cell.x, cell.y, cell.w, cell.h)
      gfx.setColor(1, 1, 1, 1)
      if quad then
        pcall(gfx.draw, img, quad, cell.x, cell.y - G.ICON_TOP)
      else
        pcall(gfx.draw, img, cell.x, cell.y - G.ICON_TOP)
      end
      if ok and sw then pcall(gfx.setScissor, sx, sy, sw, sh) else pcall(gfx.setScissor) end
    end
    if focused then
      -- the cart's arrow, pointing at the seat from the field side
      local ay = cell.y + math.floor((cell.h - 14) / 2)
      if side == "foe" then
        pcall(F.drawGlyph, F.CHAR_RIGHT_ARROW or 0x7C, cell.x - 8, ay, { colors = F.COLOR and F.COLOR.NORMAL })
      else
        pcall(F.drawGlyph, F.CHAR_LEFT_ARROW or 0x7B, cell.x + cell.w + 1, ay, { colors = F.COLOR and F.COLOR.NORMAL })
      end
    end
  end
  gfx.setColor(1, 1, 1, 1)
end

-- The message box line(s): wrapped to the printer's width, two lines at most.
local function drawMessage(F, text, hint)
  text = printable(text)
  if text == "" then return end
  local lines = {}
  local wrapped = text
  if type(F.wrap) == "function" then
    local ok, w = pcall(F.wrap, text, G.MSG_W)
    if ok and type(w) == "string" then wrapped = w end
  end
  for line in (wrapped .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
    if #lines >= 2 then break end
  end
  local colors = F.COLOR and F.COLOR.WHITE
  local pitch = tonumber(F.LINE_PITCH) or 15
  local endX = G.MSG_X
  for i, line in ipairs(lines) do
    drawText(F, line, G.MSG_X, G.MSG_Y + (i - 1) * (pitch + 1), { colors = colors })
    if i == #lines then endX = G.MSG_X + measure(F, line) end
  end
  if hint and F.CHAR_DOWN_ARROW and type(F.drawGlyph) == "function" then
    pcall(F.drawGlyph, F.CHAR_DOWN_ARROW, math.min(endX + 2, 228),
      G.MSG_Y + (#lines - 1) * (pitch + 1), { colors = colors })
  end
end

local function drawCursor(F, x, y, colors)
  local Window = g3eng("src.ui.game3.window")
  if Window and type(Window.cursorPx) == "function"
     and pcall(Window.cursorPx, x, y, { colors = colors }) then
    return
  end
  if F and F.CHAR_SELECTOR_ARROW then
    pcall(F.drawGlyph, F.CHAR_SELECTOR_ARROW, x, y, { colors = colors })
  end
end

local function drawCommands(C, F, view, rse)
  local labels = {}
  for i = 1, 4 do
    local label = type(view.commands) == "table" and view.commands[i] or nil
    labels[i] = M.gen3CommandLabel(label or cartMenuLabels()[i])
  end
  local cursor = math.max(1, math.min(4, math.floor(num3(view.commandIndex or view.commandCursor, 1))))
  local prompt = tostring(view.prompt or "")
  if rse and type(C.textOrigin) == "function" then
    local W = C.WIN or {}
    local okP, px, py = pcall(C.textOrigin, W.ACTION_PROMPT or 1)
    local colors = nil
    pcall(function() colors = C.textboxColors(1, 6) end)
    if okP then drawText(F, prompt, px, py, { colors = colors }) end
    local okM, mx, my = pcall(C.textOrigin, W.ACTION_MENU or 2)
    if okM then
      local wc = rseWindowColors(C)
      local c = cursor - 1
      drawCursor(F, 8 * (7 * (c % 2) + 16), my + 16 * math.floor(c / 2), wc)
      for i = 1, 4 do
        local cc, rr = (i - 1) % 2, math.floor((i - 1) / 2)
        drawText(F, labels[i], mx + 56 * cc, my + 16 * rr, { colors = wc })
      end
    end
    return
  end
  drawText(F, prompt, 10, 122, { colors = F.COLOR and F.COLOR.WHITE })
  local pos = { { 136, 122 }, { 184, 122 }, { 136, 138 }, { 184, 138 } }
  local cur = { { 128, 122 }, { 176, 122 }, { 128, 138 }, { 176, 138 } }
  local normal = F.COLOR and F.COLOR.NORMAL
  drawCursor(F, cur[cursor][1], cur[cursor][2], normal)
  for i = 1, 4 do drawText(F, labels[i], pos[i][1], pos[i][2], { colors = normal }) end
end

local function typeNameOf(value)
  if type(value) == "string" and value ~= "" then return value end
  local n = tonumber(value)
  if n and type(Gen3) == "table" and type(Gen3.typeName) == "function" then
    return Gen3.typeName(n)
  end
  return nil
end

local function drawMoves(C, F, view, rse)
  local moves = type(view.moves) == "table" and view.moves or {}
  local cursor = math.max(1, math.min(4, math.floor(num3(view.cursor or view.moveCursor, 1))))
  if #moves > 0 and cursor > #moves then cursor = #moves end
  local ppLabel = romPlain("gText_MoveInterfacePP", "PP")
  local typeLabel = romPlain("gText_MoveInterfaceType", "TYPE/")
  local pick = moves[cursor]
  if rse and type(C.textOrigin) == "function" then
    local W = C.WIN or {}
    local wc = rseWindowColors(C)
    local okC, _, cy = pcall(C.textOrigin, W.MOVE_NAME_1 or 3)
    if okC and #moves > 0 then
      local c = cursor - 1
      drawCursor(F, 8 * (9 * (c % 2) + 1), cy + 16 * math.floor(c / 2), wc)
    end
    for i = 1, 4 do
      local mv = moves[i]
      local label = mv and (mv.label or mv.name) or "-"
      local ok, x, y, _, narrow = pcall(C.textOrigin, (W.MOVE_NAME_1 or 3) + i - 1)
      if ok then drawText(F, label, x, y, { colors = wc, font = narrow and "narrow" or nil }) end
    end
    if pick then
      local pc = ppColors(C, F, pick.pp, pick.maxPp, true)
      local ok, x, y, _, narrow = pcall(C.textOrigin, W.PP or 7)
      if ok then drawText(F, ppLabel, x, y, { colors = pc, font = narrow and "narrow" or nil }) end
      if pick.pp ~= nil and pick.maxPp ~= nil then
        ok, x, y = pcall(C.textOrigin, W.PP_REMAINING or 9)
        if ok then
          drawText(F, ("%2d/%2d"):format(num3(pick.pp, 0), num3(pick.maxPp, 0)), x, y, { colors = pc })
        end
      end
      ok, x, y, _, narrow = pcall(C.textOrigin, W.MOVE_TYPE or 10)
      if ok then
        drawText(F, typeLabel, x, y, { colors = wc, font = "narrow" })
        local tw = measure(F, typeLabel, { font = "narrow" })
        drawText(F, typeNameOf(pick.type) or "", x + tw, y, { colors = wc })
      end
    end
    return
  end
  local normal = F.COLOR and F.COLOR.NORMAL
  local pos = { { 16, 122 }, { 88, 122 }, { 16, 138 }, { 88, 138 } }
  if #moves > 0 then
    drawCursor(F, pos[cursor][1] - 8, pos[cursor][2], normal)
  end
  for i = 1, 4 do
    local mv = moves[i]
    local label = mv and (mv.label or mv.name) or "-"
    drawText(F, fitText(F, label, 64, { small = true }), pos[i][1], pos[i][2],
      { small = true, colors = normal })
  end
  if pick then
    drawText(F, ppLabel, 168, 122, { small = true, colors = normal })
    if pick.pp ~= nil and pick.maxPp ~= nil then
      drawText(F, ("%2d/%2d"):format(num3(pick.pp, 0), num3(pick.maxPp, 0)), 202, 122,
        { colors = ppColors(C, F, pick.pp, pick.maxPp, false) })
    end
    drawText(F, typeLabel .. (typeNameOf(pick.type) or ""), 168, 138,
      { small = true, colors = normal })
  end
end

-- The bag / target list: a window over the field, the question in the box.
local function drawListWindow(gfx, C, F, list)
  local Gen3Ui = nil
  pcall(function() Gen3Ui = need("Gen3Ui") end)
  local rows = type(list.rows) == "table" and list.rows or {}
  local tx, ty, tw, th = G.LIST_TX, G.LIST_TY, G.LIST_TW, G.LIST_TH
  if Gen3Ui and type(Gen3Ui.frame) == "function" then
    Gen3Ui.frame(tx, ty, tw, th)
  else
    gfx.setColor(1, 1, 1, 1)
    gfx.rectangle("fill", (tx - 1) * 8, (ty - 1) * 8, (tw + 2) * 8, (th + 2) * 8)
  end
  local cursor = math.max(1, math.min(#rows, math.floor(num3(list.cursor, 1))))
  local visible = G.LIST_ROWS
  local first = 1
  if cursor > visible then first = cursor - visible + 1 end
  first = math.max(1, math.min(first, math.max(1, #rows - visible + 1)))
  local left, top = tx * 8, ty * 8
  local normal = F.COLOR and F.COLOR.NORMAL
  local muted = { fg = { 0.58, 0.58, 0.58, 1 },
                  shadow = (F.STDPAL and F.STDPAL[3]) or { 0.84, 0.84, 0.8, 1 },
                  bg = { 0, 0, 0, 0 } }
  for i = 0, visible - 1 do
    local row = rows[first + i]
    if row then
      local y = top + i * 16
      local label = type(row) == "table" and (row.label or row.name) or tostring(row)
      local right = type(row) == "table" and row.right or nil
      local colors = (type(row) == "table" and row.dim) and muted or normal
      local rightW = right and measure(F, tostring(right)) or 0
      drawText(F, fitText(F, label, tw * 8 - 12 - rightW - 4), left + 8, y, { colors = colors })
      if right then drawText(F, tostring(right), left + tw * 8 - rightW, y, { colors = colors }) end
      if first + i == cursor then drawCursor(F, left, y, normal) end
    end
  end
  if Gen3Ui and type(Gen3Ui.scrollArrows) == "function" then
    pcall(Gen3Ui.scrollArrows, tx, ty, tw, th, first > 1, first + visible - 1 < #rows)
  end
  pcall(C.drawPanel, "none")
  drawMessage(F, list.title or "", false)
end

-- "12/34" (a row's `right`) -> 12, 34.
local function hpOfRow(row)
  local hp, maxHp = tonumber(row.hp), tonumber(row.maxHp)
  if not (hp and maxHp) and type(row.right) == "string" then
    local a, b = row.right:match("(%d+)%s*/%s*(%d+)")
    hp, maxHp = tonumber(a), tonumber(b)
  end
  return hp, maxHp
end

-- The POKéMON page: the highlighted monster on the left (front pic, name,
-- level, HP bar and figures, condition), the party down the right as the
-- cart's party icons, the highlighted one bobbing.
local function drawPartyPage(gfx, C, F, BF, list, frame)
  local Gen3Ui = nil
  pcall(function() Gen3Ui = need("Gen3Ui") end)
  local rows = type(list.rows) == "table" and list.rows or {}
  if Gen3Ui and type(Gen3Ui.frame) == "function" then
    Gen3Ui.frame(1, 1, 28, 18)
  else
    gfx.setColor(1, 1, 1, 1)
    gfx.rectangle("fill", 0, 0, G.W, G.H)
  end
  local cursor = math.max(1, math.min(#rows, math.floor(num3(list.cursor, 1))))
  local normal = F.COLOR and F.COLOR.NORMAL
  local pick = rows[cursor]
  if type(pick) == "table" then
    local img = pick.front
    if img then
      drawStandingPic(gfx, BF, img, G.PARTY_PIC_X + G.PIC / 2, G.PARTY_PIC_Y + G.PIC - 1,
        { alpha = pick.dim and 0.5 or 1 })
    end
    local name = tostring(pick.label or pick.name or "?")
    drawText(F, fitText(F, name, 68), 8, 76, { colors = normal })
    if pick.level then
      drawText(F, "Lv" .. tostring(pick.level), 8, 90, { small = true, colors = normal })
    end
    local hp, maxHp = hpOfRow(pick)
    if hp and maxHp then
      pcall(C.drawHpBar, 8, 106, hp, math.max(1, maxHp), false)
      drawText(F, ("%d/%d"):format(hp, maxHp), 8, 116, { colors = normal })
    end
    if type(pick.status) == "string" and pick.status ~= "" then
      local SummaryChrome = g3eng("src.ui.game3.summary_chrome")
      local ailment = ailmentOf({ status = pick.status, hp = hp or 1 })
      if SummaryChrome and ailment >= 1 then pcall(SummaryChrome.drawStatusIcon, 40, 92, ailment) end
    end
  end
  if list.title then
    -- the question across the foot of the page, the party menu's own line
    drawText(F, fitText(F, tostring(list.title), G.W - 24), 8, G.PARTY_TITLE_Y,
      { colors = F.COLOR and F.COLOR.BLUE or normal })
  end
  local visible = G.PARTY_ROWS
  local first = 1
  if cursor > visible then first = cursor - visible + 1 end
  first = math.max(1, math.min(first, math.max(1, #rows - visible + 1)))
  local muted = { fg = { 0.58, 0.58, 0.58, 1 },
                  shadow = (F.STDPAL and F.STDPAL[3]) or { 0.84, 0.84, 0.8, 1 },
                  bg = { 0, 0, 0, 0 } }
  local ok, sx, sy, sw, sh = pcall(function() return gfx.getScissor() end)
  for i = 0, visible - 1 do
    local row = rows[first + i]
    if row then
      local y = G.PARTY_LIST_Y + i * G.PARTY_ROW_H
      local hot = first + i == cursor
      if type(row) == "table" and BF then
        local icon = row.icon
        if icon == nil then
          local subject = row.mon or tonumber(row.speciesId) or tonumber(row.species)
          if subject ~= nil then icon = BF.gen3Icon(subject) end
        end
        local img, quad = BF.gen3IconFrame(icon, hot and BF.gen3IconBob(frame) or 0)
        if img then
          pcall(gfx.setScissor, G.PARTY_LIST_X, y, G.ICON, G.PARTY_ROW_H)
          gfx.setColor(1, 1, 1, row.dim and 0.5 or 1)
          if quad then pcall(gfx.draw, img, quad, G.PARTY_LIST_X, y - G.ICON_TOP)
          else pcall(gfx.draw, img, G.PARTY_LIST_X, y - G.ICON_TOP) end
          gfx.setColor(1, 1, 1, 1)
          if ok and sw then pcall(gfx.setScissor, sx, sy, sw, sh) else pcall(gfx.setScissor) end
        end
      end
      local label = type(row) == "table" and (row.label or row.name) or tostring(row)
      local right = type(row) == "table" and row.right or nil
      local colors = (type(row) == "table" and row.dim) and muted or normal
      local rightW = right and measure(F, tostring(right), { small = true }) or 0
      drawText(F, fitText(F, label, 228 - 120 - rightW - 4), 120, y + 4, { colors = colors })
      if right then
        drawText(F, tostring(right), 228 - rightW, y + 6, { small = true, colors = colors })
      end
      if hot then drawCursor(F, G.PARTY_LIST_X - 8, y + 4, normal) end
    end
  end
  -- more of the party above / below the five shown
  if type(F.drawGlyph) == "function" then
    if first > 1 and F.CHAR_UP_ARROW then
      pcall(F.drawGlyph, F.CHAR_UP_ARROW, 220, 0, { colors = normal })
    end
    if first + visible - 1 < #rows and F.CHAR_DOWN_ARROW then
      pcall(F.drawGlyph, F.CHAR_DOWN_ARROW, 220, G.PARTY_LIST_Y + visible * G.PARTY_ROW_H - 4,
        { colors = normal })
    end
  end
end

-- The terrain sheet for this fight: asked once per fight (remembered on the
-- screen that is drawing, which a new fight replaces) rather than per frame --
-- the player does not move under a battle, and a sheet picked per frame would
-- re-run the map lookups sixty times a second. A caller with no screen object
-- is remembered per map.
local terrainMemo = { map = nil, key = nil }
local function terrainKey(BF, view, state)
  if type(view.terrain) == "string" then return view.terrain end
  if not BF then return nil end
  if type(state) == "table" then
    local hit = rawget(state, "__g3TerrainKey")
    if hit ~= nil then return hit or nil end
    local key = BF.gen3TerrainKey and BF.gen3TerrainKey() or nil
    rawset(state, "__g3TerrainKey", key or false)
    return key
  end
  local ctx = BF.gen3MapContext and BF.gen3MapContext() or {}
  local map = ctx.mapId or "?"
  if terrainMemo.map ~= map or terrainMemo.key == nil then
    terrainMemo.map = map
    terrainMemo.key = BF.gen3TerrainKey and BF.gen3TerrainKey(ctx) or nil
  end
  return terrainMemo.key
end

local function frameOf(view, state)
  local f = tonumber(view.frame) or (type(state) == "table" and tonumber(state.frame))
  if f then return f end
  local t = 0
  pcall(function() t = love.timer.getTime() * 60 end)
  return t
end

-- Draw the whole Gen 3 page. See the contract above.
function M.drawGen3(view, state)
  -- off a Gen 3 boot there is no cart chrome to draw with, and nothing here
  -- may even ask for a src.*.game3.* module
  if not (type(Gen3) == "table" and type(Gen3.active) == "function" and Gen3.active()) then
    return false
  end
  local gfx = gfx3()
  local C = g3eng("src.ui.game3.battle_chrome")
  local F = g3eng("src.ui.game3.frlg_font")
  if not (gfx and C and F and type(view) == "table") then return false end
  local okI = pcall(function()
    if type(C.manifest) == "function" then C.manifest() end
  end)
  if not okI then return false end
  local BF = battlefield()
  local rse = false
  pcall(function() rse = C.isRse() == true end)
  local frame = frameOf(view, state)

  local drew = pcall(function()
    gfx.push("all")
    local okAll, err = pcall(function()
      gfx.setColor(1, 1, 1, 1)
      -- a POKéMON list is the whole page
      if type(view.list) == "table" and M.gen3IsPartyList(view.list) then
        drawPartyPage(gfx, C, F, BF, view.list, frame)
        return
      end

      -- the field
      local key = terrainKey(BF, view, state)
      local okT, drawnT = pcall(C.drawTerrain, key or "building", 0, 0, 0)
      if not (okT and drawnT) then
        gfx.setColor(0.92, 0.94, 0.96, 1)
        gfx.rectangle("fill", 0, 0, G.W, G.PANEL_Y)
        gfx.setColor(1, 1, 1, 1)
      end

      local foe, ally = view.foe, view.ally
      -- the foe trainer, where the foe will stand
      if type(view.trainer) == "table" and (view.showTrainer or not foe) then
        local picId = view.trainer.pic or view.trainer.picId
        local img = BF and picId ~= nil and BF.gen3TrainerPic(picId) or nil
        if img then
          local ok, iw, ih = pcall(img.getDimensions, img)
          if ok then
            gfx.setColor(1, 1, 1, 1)
            gfx.draw(img, G.TRAINER_X - math.floor(iw / 2), G.TRAINER_Y - math.floor(ih / 2))
          end
        end
      end
      if type(foe) == "table" and not foe.hidden and not (view.showTrainer and view.trainer) then
        if foe.substitute then
          drawDoll(gfx, BF, false, foe)
        else
          -- a floater hovers over its platform by the cart's own elevation
          -- for it, when the screen did not say (a seat carrying its species)
          local stand = foe
          if foe.elevation == nil and BF and BF.gen3Elevation then
            local elev = BF.gen3Elevation(tonumber(foe.speciesId) or tonumber(foe.species))
            if elev then
              stand = setmetatable({ elevation = elev }, { __index = foe })
            end
          end
          drawStandingPic(gfx, BF, seatPic(BF, foe, false), G.FOE_PIC_X, G.FOE_FEET_Y, stand)
        end
      end
      -- the player's own back pic, while no monster is out
      if type(view.playerBack) == "table" and (view.showPlayer or not ally) then
        local entry = type(Gen3) == "table" and Gen3.trainerBackPic(view.playerBack.gender) or nil
        if type(entry) == "table" and entry.image then
          local quad = backQuad(gfx, entry.image)
          gfx.setColor(1, 1, 1, 1)
          if quad then
            gfx.draw(entry.image, quad, G.PLAYER_BACK_X - 32, G.PLAYER_BACK_Y - 32)
          end
        end
      end
      if type(ally) == "table" and not ally.hidden and not (view.showPlayer and view.playerBack) then
        if ally.substitute then
          drawDoll(gfx, BF, true, ally)
        else
          drawStandingPic(gfx, BF, seatPic(BF, ally, true), G.ALLY_PIC_X, G.ALLY_FEET_Y, ally)
        end
      end
      if view.evolveFront then
        drawStandingPic(gfx, BF, view.evolveFront, G.W / 2, 88, nil)
      end
      -- the weather over the field (the arena's own painter, at the page's
      -- scale), under the healthboxes as the cart layers it
      if view.weather and BF and BF.drawWeather then
        BF.drawWeather(view.weather, 0, 0, G.W, G.PANEL_Y, frame, 0.5)
      end
      local flash = math.max(0, math.min(1, num3(view.evolveFlash, 0)))
      if flash > 0 then
        gfx.setColor(1, 1, 1, flash)
        gfx.rectangle("fill", 0, 0, G.W, G.PANEL_Y)
      end
      gfx.setColor(1, 1, 1, 1)

      -- the guild-focus rails (2v2 / 3v3)
      drawStrip(gfx, BF, F, "foe", view.foeStrip, frame)
      drawStrip(gfx, BF, F, "ally", view.allyStrip, frame)

      -- the healthboxes, and the foe's remaining party under its box
      if type(foe) == "table" then drawFoeBox(gfx, C, F, foe) end
      if type(ally) == "table" then drawAllyBox(gfx, C, F, ally) end
      if view.foeParty ~= nil and M.wantsFoeBalls(view.mode) then
        drawFoeBalls(C, view.foeParty)
      end

      -- the textbox
      if type(view.list) == "table" then
        drawListWindow(gfx, C, F, view.list)
        return
      end
      local mode = "none"
      if view.commands then mode = "menu"
      elseif view.moves then mode = "moves" end
      pcall(C.drawPanel, mode)
      pcall(C.drawMenuFrames, mode)
      if mode == "menu" then
        drawCommands(C, F, view, rse)
      elseif mode == "moves" then
        drawMoves(C, F, view, rse)
      else
        drawMessage(F, view.message, view.hint == true and not view.hold)
      end
    end)
    gfx.pop()
    if not okAll then error(err, 0) end
  end)
  if not drew then return false end
  return true
end

return M
