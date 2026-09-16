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
    local cx, cy, cw, ch = M.frontPicClip()
    pcall(g.setScissor, cx, cy, cw, ch)
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
    pcall(g.setScissor, 8, M.PICKER_LIST_Y, 144,
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

return M
