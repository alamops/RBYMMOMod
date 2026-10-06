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
-- view model and which draws with the cart's battle chrome. A lone trainer's
-- double battle there is the cart's own double screen (M.G3D), not the
-- guild focus.

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

-- ------- glyphs, not bytes
--
-- A Red / Gold referee line carries the carts' own glyphs since wave 6 of
-- docs/plans/gen12-referee-gaps-fix.md (Wire.battleText: é, …, ♂, ♀ -- "Both
-- POKéMON will faint in 3 turns!", "COOLTRAINER♂ used X ATTACK on ...!"), and
-- the font draws each of them as ONE tile (the engine's Font.split: "POKéMON
-- is 8 bytes and 7 glyphs").  So everything on these screens that measures or
-- cuts referee text walks whole UTF-8 sequences: counted by bytes, a line
-- wrapped a column early; cut by bytes, it split a glyph into two invalid
-- bytes the ROM font draws as spaces and a LÖVE font refuses to draw at all.
-- A lead byte takes the continuation bytes that follow it (0x80..0xBF, up to
-- its length), so a stray byte is a glyph of its own and nothing is lost.

-- Where the glyph starting at byte `i` of `text` (length `n`) ends: the byte
-- after it.  The one walk `glyphs`, `glyphCount` and `glyphPrefix` share.
local function glyphEnd(text, i, n)
  local b = text:byte(i)
  local len = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
  local j = i + 1
  while j < i + len and j <= n do
    local c = text:byte(j)
    if c < 0x80 or c > 0xBF then break end
    j = j + 1
  end
  return j
end

-- The glyphs of `text`, in order, each a whole UTF-8 sequence.
function M.glyphs(text)
  text = tostring(text or "")
  local out, i, n = {}, 1, #text
  while i <= n do
    local j = glyphEnd(text, i, n)
    out[#out + 1] = text:sub(i, j - 1)
    i = j
  end
  return out
end

-- How many glyphs `text` is.  Counted in place, never through `glyphs`'
-- table: the arena measures its plates and bubbles every frame
-- (Battlefield's `truncate`, CoopBattle's wait line), and a line with no byte
-- past 0x7F -- nearly every one -- is its own length.
function M.glyphCount(text)
  text = tostring(text or "")
  if not text:find("[\128-\255]") then return #text end
  local count, i, n = 0, 1, #text
  while i <= n do
    i = glyphEnd(text, i, n)
    count = count + 1
  end
  return count
end

-- The first `count` glyphs of `text` (all of it when it has no more): one
-- `sub` at the last whole glyph, so a cut never splits one and nothing is
-- built to find it.
function M.glyphPrefix(text, count)
  text = tostring(text or "")
  count = math.max(0, math.floor(tonumber(count) or 0))
  if not text:find("[\128-\255]") then return text:sub(1, count) end
  local i, n = 1, #text
  while count > 0 and i <= n do
    i = glyphEnd(text, i, n)
    count = count - 1
  end
  return text:sub(1, i - 1)
end

-- Soft-wrap one string into lines that fit the bottom box.
--
-- Collapses runs of whitespace so a typewriter-spaced line does not paint
-- through the right border. Prefers a break at the last space that still
-- fits; otherwise hard-cuts. Author newlines stay paragraph breaks.  Columns
-- are glyphs (`M.glyphs`): one tile each, whatever its UTF-8 length.
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
      local g = M.glyphs(rest)
      while #g > width do
        -- The last space among the first `width` glyphs (the collapse above
        -- leaves single spaces only), else a hard cut at `width`.
        local breakAt = width
        for k = width, 2, -1 do
          if g[k] == " " then breakAt = k - 1; break end
        end
        lines[#lines + 1] = table.concat(g, "", 1, breakAt):gsub("%s+$", "")
        local from = breakAt + 1
        while g[from] == " " do from = from + 1 end
        local left = {}
        for k = from, #g do left[#left + 1] = g[k] end
        g = left
      end
      if #g > 0 then lines[#lines + 1] = table.concat(g) end
    end
  end
  if #lines == 0 then return { "" } end
  return lines
end

-- Pages of at most BOX_ROWS lines, each line already <= width.
--
-- `cartBreaks` (Red / Gold, contract K18 of
-- docs/plans/gen12-referee-remaining-gaps.md): an explicit `\n` is the cart's
-- own line break -- the referee writes one where the cart's text has `line`
-- or `cont`, and a `para` is a separate `msg`.  Two rows make a page; a third
-- row starts the next page the way the cart's `cont` does it -- `_ContText`
-- (pokered home/text.asm, pokecrystal the same) waits for the button and
-- scrolls the box one row, so the row above stays in sight under it: rows
-- r1 r2 r3 read as "r1\nr2", then "r2\nr3" (the shape `sentOutPages` already
-- gives Gold's BattleText_EnemySentOut).  A row too long for the box still
-- word-wraps, and its spill rows scroll in the same way.  Text with no `\n`
-- word-wraps and packs two rows a page exactly as it always has, and a caller
-- that does not ask (Gen 3, whose box breaks its own way) gets the old pager
-- whatever the text holds.
function M.pageBoxText(text, width, cartBreaks)
  local lines = M.wrapBoxLines(text, width or M.BOX_COLS)
  local pages = {}
  local scroll = cartBreaks == true and #lines > M.BOX_ROWS
    and tostring(text or ""):find("\n", 1, true) ~= nil
  -- A blank row is not a cart break (K18 never writes `\n\n`: a `para` is its
  -- own `msg`), so a text holding one pages the old way, blank row and all.
  for _, line in ipairs(scroll and lines or {}) do
    if line == "" then scroll = false; break end
  end
  if scroll then
    pages[1] = lines[1] .. "\n" .. lines[2]
    for i = 3, #lines do
      pages[#pages + 1] = lines[i - 1] .. "\n" .. lines[i]
    end
    return pages
  end
  for i = 1, #lines, M.BOX_ROWS do
    local page = lines[i]
    if lines[i + 1] then page = page .. "\n" .. lines[i + 1] end
    pages[#pages + 1] = page
  end
  if #pages == 0 then pages[1] = "" end
  return pages
end

-- ------- K17: the name marks in a Red / Gold referee line
--
-- The referee is one narrator for every seat, so where a cart prints a
-- battler's name through a prefixing macro it writes `^a` or `^b` -- the
-- monster's side -- straight before the name instead of a prefix (contract
-- K17 of docs/plans/gen12-referee-remaining-gaps.md), and each screen says
-- the mark the way its own cart would for its own player.  The macros are
-- pokered PlaceMoveUsersName / PlaceMoveTargetsName (`<USER>` / `<TARGET>`,
-- home/text.asm) and pokecrystal / pokegold PlaceBattlersName (the same two
-- characters): the player's own monster is printed bare (wBattleMonNick), and
-- the other one behind EnemyText, "Enemy @" -- on both carts, in every kind of
-- fight.  Neither cart's routine looks at the battle mode: there is no "Wild"
-- on this path (Gold's "Wild <MON>" lines -- WildPokemonAppearedText,
-- BattleText_WildFled -- are literal text the referee writes whole), and a
-- link battle prints "Enemy" for the other player's monster because each
-- console calls its own player's side the player.  `^` is never a name glyph
-- (Wire strips it from every name), so a mark is never part of a name.

-- What the other side's mark becomes, per generation and per kind of fight:
-- one row per cart and fight, so a cart rule that differs is one row.
-- `wild` / `trainer` / `link` are the three kinds `M.fightKind` reads off a
-- screen's mode.
M.FOE_MARK = {
  [1] = { wild = "Enemy ", trainer = "Enemy ", link = "Enemy " },  -- pokered EnemyText
  [2] = { wild = "Enemy ", trainer = "Enemy ", link = "Enemy " },  -- pokecrystal / pokegold EnemyText
}

-- The fights the cart fights under link rules (MediatedBattle.LINK_MODES'
-- set, restated here so this module needs nothing above it) and the wild ones.
local LINK_FIGHTS = { ["1v1"] = true, coop_pvp = true }
local WILD_FIGHTS = { wild = true, coop_wild = true }

-- "wild" | "trainer" | "link" for a screen's mode: anything that is neither
-- a link fight nor a wild one is a fight against a computer trainer.
function M.fightKind(mode)
  if LINK_FIGHTS[mode] then return "link" end
  if WILD_FIGHTS[mode] then return "wild" end
  return "trainer"
end

-- The word the other side's mark is said as on `generation`'s cart, in a
-- fight of `mode` ("" for a generation with no marks: Gen 3's referee writes
-- none).
function M.foeMarkWord(generation, mode)
  local row = M.FOE_MARK[tonumber(generation) or 0]
  if not row then return "" end
  return row[M.fightKind(mode)] or ""
end

-- ...and the side-word marks (K17's wave-2 bullet): where the cart prints a
-- *side* word rather than a battler's name -- pokecrystal / pokegold
-- HandleScreens' `.Your` ("Your@") / `.Enemy` ("Enemy@"), copied into
-- wStringBuffer1 ahead of "#MON's LIGHT SCREEN fell!" by whose screen it was,
-- and any other `Your@` / `Enemy@` pair the Gold referee writes -- the
-- referee writes `^A` (side a) or `^B` (side b) before the rest of the line.
-- Each console calls its own side "Your", so a viewer says its own side's
-- (a co-op partner's side is its own) "Your " and the other "Enemy ", on Red
-- as on Gold (Red's referee simply writes none).
M.SIDE_WORD_OWN = "Your "
M.SIDE_WORD_OTHER = "Enemy "

-- `text` with every mark taken out -- name marks and side-word marks alike --
-- and any `^` left over with it, so a stray or malformed mark never reaches
-- the box as a glyph.
function M.stripMarks(text)
  if type(text) ~= "string" then return text end
  if not text:find("^", 1, true) then return text end
  return (text:gsub("%^[abAB]", ""):gsub("%^", ""))
end

-- One referee line as a viewer reads it: a mark on `ownSide`'s monster is
-- nothing (the cart prints its own player's monster bare), a mark on the other
-- side's is `foeWord`; a side-word mark is "Your " on `ownSide` and "Enemy "
-- on the other.  `ownSide` nil reads every mark as the other side's.
function M.renderMarks(text, ownSide, foeWord)
  if type(text) ~= "string" then return text end
  if not text:find("^", 1, true) then return text end
  foeWord = tostring(foeWord or "")
  local out = text:gsub("%^([abAB])", function(mark)
    local side = mark:lower()
    if mark ~= side then
      return (side == ownSide) and M.SIDE_WORD_OWN or M.SIDE_WORD_OTHER
    end
    if side == ownSide then return "" end
    return foeWord
  end)
  return (out:gsub("%^", ""))
end

-- The line every client matcher reads (K17's "every line is read without its
-- marks", K18's breaks): Wire.plainBattleLine's reading, so the screens'
-- matchers, the suites and the e2e drivers all read one plain text -- the
-- marks out, a row broken after a hyphen joined whole ("super-\neffective!"
-- is "super-effective!", the word the cart split), and every other `\n` read
-- as the space between two words.  A `^` the wire would never carry (a stray
-- one in a line this client composed) is dropped too.  The one normaliser
-- the screens' line readers share, so a referee that starts breaking a line
-- or marking a name changes what the box shows and never what a matcher sees.
function M.plainLine(text)
  if type(text) ~= "string" then return text end
  local Wire = need("Wire")
  return M.stripMarks(Wire.plainBattleLine(text))
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
  if w <= 0 then w = M.glyphCount(text) * 8 end
  if w <= maxW then
    if Font and Font.draw then Font.draw(text, x, y) end
    return
  end
  local minScale = M.MOVE_NAME_MIN_SCALE or 0.75
  if maxW / w < minScale then
    local budget = math.max(1, math.floor(maxW / 8))
    if Font and Font.draw then
      if budget > 1 then
        Font.draw(M.glyphPrefix(text, budget - 1) .. ".", x, y)
      else
        Font.draw(M.glyphPrefix(text, 1), x, y)
      end
    end
    return
  end
  local g = love and love.graphics
  if not (g and g.push and g.scale and g.translate and g.pop) then
    local budget = math.max(1, math.floor(maxW / 8))
    if Font and Font.draw then Font.draw(M.glyphPrefix(text, budget), x, y) end
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

-- The three letters a status token is shown as, or nil for none.
--
-- Red and Gold have no badly-poisoned status of their own: TOXIC is a battle
-- flag beside the status byte's PSN bit (pokered BADLY_POISONED in
-- wPlayerBattleStatus3 / wEnemyBattleStatus3, pokecrystal SUBSTATUS_TOXIC in
-- the SubStatus5 bytes), and both carts' HUDs read the byte alone -- pokered
-- PrintStatusConditionNotFainted (called by core.asm's DrawPlayerHUDAndHPBar /
-- DrawEnemyHUDAndHPBar) and pokecrystal PlaceStatusString
-- (engine/pokemon/mon_stats.asm, PsnString) print "PSN" for it.  The
-- referee's TOX token (Wire.STATUSES) is that flag, so a Gen 1 / Gen 2 seat
-- shows PSN, as MediatedBattle.partyStatus12 already writes PSN into the
-- party.  Gen 3 keeps TOX: its status word holds STATUS1_TOXIC_POISON itself.
-- `gen3` is the caller's answer when it has one (else Gen3.active()).
-- Shared by every Gen 1 / Gen 2 status readout: this file's party picker, the
-- classic HUD plates (src/MediatedBattle.lua, src/CoopBattle.lua) and the
-- arena's chip (src/Battlefield.lua cardModel).
function M.statusLabel(status, gen3)
  if type(status) ~= "string" or status == "" then return nil end
  if gen3 == nil then
    gen3 = type(Gen3) == "table" and type(Gen3.active) == "function"
      and Gen3.active() == true
  end
  if status == "TOX" and not gen3 then return "PSN" end
  return status:sub(1, 3)
end

-- Healthy mons stay blank; only a real status (or FNT) is printed.
local function statusGlyph(row)
  if not row then return "" end
  if row.fainted or (tonumber(row.hp) or 1) <= 0 then return "FNT" end
  local status = row.status
  if type(status) == "string" and status ~= "" and status ~= "OK" then
    return M.statusLabel(status) or ""
  end
  return ""
end
M.statusGlyph = statusGlyph

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
-- **A lone trainer's double battle is the cart's double screen**
-- (docs/plans/gen3-solo-doubles.md, contract C4): four battlers at the cart's
-- doubles positions (AnimCoords.DOUBLES), drawn back to front, four doubles
-- healthboxes (name, gender, Lv, HP bar, status -- no EXP bar, and HP figures
-- only on the player's two boxes once START has swapped them in for the
-- bars), the battlers the hovered move will hit washing white in the move
-- menu, the battler being aimed at blinking while the move menu stays up,
-- and the monster choosing (plus, while aiming, the target's box) bobbing as
-- the cart bobs them.
--
-- ------- the contract (what MediatedBattle / CoopBattle call)
--
--   M.drawGen3(view, state) -> true when drawn; false when the cart chrome is
--       not reachable (not a Gen 3 boot, headless, no cache) so the caller
--       can draw a plain page instead. Draws into the current canvas at the
--       240x160 origin: call it from the screen's `draw()` while the state is
--       up through Gen3Ui.pushState and its `drawsWidescreen()` says false.
--   M.gen3Layout(view) -> the page's rects (pure; the suite asserts them).
--   M.gen3DoubleLayout(view) -> the double screen's rects (pure), for a view
--       carrying `double`.
--   M.gen3BlinkShown(blink, frame) -> whether the aimed-at battler is lit on
--       this frame (the cart's blink, pure).
--   M.gen3PreviewTargets(view) -> the battlers the hovered move would wash
--       ({ a1 = true, b2 = true ... }) and the fade's start (0..16), or nil, 0
--       when the double's move menu is not up (the cart's rule, pure).
--   M.gen3PreviewWash(startY, n) -> the wash n frames into one preview fade
--       (0..16 towards white) and the fade's whole length in frames (pure).
--   M.gen3CommandLabel(idOrLabel) -> the cart's own word for a command.
--   M.gen3YesNoLabels() -> the cart's two answers ({ "YES", "NO" } in its
--       own words, gText_BattleYesNoChoice).
--   M.gen3YesNoLayout() -> the YES / NO window's rects (pure).
--   M.G3 -> the geometry constants; M.G3D -> the double screen's.
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
--   moves           { { label | name, type (name or pret number), pp, maxPp,
--                     target, num } } -- `target` (the move's MOVE_TARGET_*
--                     byte as the cart's move menu reads it: a Ghost's CURSE
--                     is SELECTED) and `num` (its move number; else a
--                     numeric `id`) drive a double's hover preview; a row
--                     without `target` previews nothing
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
--   voiceover       true while Oak's lines are up (FireRed / LeafGreen's
--                   first battle): the field darkens halfway to black and
--                   the line prints in the voice-over frame, dark ink on the
--                   dialogue window, in place of the battle textbox (pret
--                   PrintOakTextWithMainBgDarkened, B_WIN_OAK_OLD_MAN)
--   voiceoverLit    "foe" | "ally" -- under some of his lines the cart lights
--                   one healthbox again over the darkened field (singles)
--   yesNo           { cursor = 1 | 2 } -- a yes / no is up: `message` stays
--                   in the textbox and the YES / NO window opens at its
--                   right (pret PlayerHandleYesNoBox, YESNOBOX_X_Y), the
--                   cursor on YES (1) or NO (2)
--   foe.sprite / foe.name   a Pokémon Tower GHOST is the caller's: the
--                   silhouette as `sprite`, gText_Ghost as `name`, no
--                   `gender` and `caught` false (MediatedBattle veilSeat3)
--   double          a lone trainer's double battle, in place of foe / ally /
--                   the strips (contract C4):
--                     foes   = { [1] = seat | nil, [2] = seat | nil } --
--                              [1] the opponent's first battler (field slot
--                              3, the cart's opponent left), [2] slot 4;
--                     allies = { [1] = seat | nil, [2] = seat | nil } --
--                              [1] slot 0 (player left), [2] slot 1;
--                     choosing = 1 | 2 | nil -- the ally whose command menu
--                              is up (it bobs, with its box);
--                     blink = { side = "a" | "b", index = 1 | 2, since } | nil
--                              -- the battler being aimed at ("a" an ally,
--                              "b" a foe); `since` (optional) is the `frame`
--                              the cursor landed on, which restarts the
--                              cart's blink, else the page clock phases it;
--                     hpText = true -- the player's two boxes show their HP
--                              figures in place of the bars (the cart's
--                              START in the action menu, healthbox.lua
--                              swapHpBarsWithHpText; the foes' never do).
--                   Seats are the shape above (the ally's `expFrac` is not
--                   drawn: the doubles box has no EXP bar). While the move
--                   menu is up (`moves`, no `commands` / `list`, phase not
--                   "target") the battlers the hovered move will hit wash
--                   white, by its `target` and `num`, on the cart's fade
--                   clock (kept on `state`; without one the page clock
--                   phases it). With phase "target" the move menu (`moves`,
--                   `cursor`) stays up and the target blinks; a `list` is
--                   not drawn then (the cart has no TARGET window).
--                   `foeParty` is not drawn: the cart shows that row only at
--                   the intro and on a switch, and the doubles field has no
--                   free room for a standing one.

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
  -- The YES / NO window, as Emerald -- the cart whose facilities ask it --
  -- lays it: HandleBattleWindow's YESNOBOX_X_Y frame (tiles 24..29 x 8..13,
  -- drawn here as the std frame around tiles 25..28 x 9..12), the answers in
  -- B_WIN_YESNO (pokeemerald battle_bg.c:273, tiles 26,9 3x4) a row of 16
  -- apart, the arrow on tile 25 ahead of them (BattleCreateYesNoCursorAt,
  -- battle_script_commands.c:10200).
  YESNO_TX = 25, YESNO_TY = 9, YESNO_TW = 4, YESNO_TH = 4,
  YESNO_TEXT_X = 208, YESNO_TEXT_Y = 72, YESNO_CURSOR_X = 200, YESNO_PITCH = 16,
  -- Oak's voice-over: the battle BGs fade 8/16 of the way to black under it
  -- (PrintOakTextWithMainBgDarkened's BeginNormalPaletteFade 0 -> 8), and the
  -- line prints in B_WIN_OAK_OLD_MAN (battle_bg.c:359, tiles 2,15 26x4 -- the
  -- dialogue window's rect) inside BtlCtrl_DrawVoiceoverMessageFrame's frame.
  VOICEOVER_DIM = 0.5, VOICEOVER_X = 16, VOICEOVER_Y = 120,
}
local G = M.G3

-- The double screen. Layout constants from the engine's doubles code (the
-- pret lines it cites), never a byte out of any ROM. The cart numbers its
-- battlers by position -- 0 player left, 1 opponent left, 2 player right, 3
-- opponent right -- so the view's foes[1] / foes[2] are battlers 1 / 3 and
-- allies[1] / allies[2] are 0 / 2; each pair below is { [1], [2] }.
-- Everything not here (the textbox, the trainer and the player's back pic --
-- a lone trainer stands where a singles one does, intro_seq.lua -- the
-- evolution and the weather) is the singles page's, from M.G3.
M.G3D = {
  -- AnimCoords.DOUBLES (pokefirered battle_anim_mons.c:31): foe (200,40) and
  -- (152,32), feet on base y + 31 as FOE_FEET_Y derives them
  FOE_PIC_X = { 200, 152 }, FOE_FEET_Y = { 71, 63 },
  -- the player's (32,80) and (90,88): base y + back offset + 4 as singles
  -- (ui.lua battler_sprite_center), feet on base y + 35
  ALLY_PIC_X = { 32, 90 }, ALLY_FEET_Y = { 115, 123 },
  -- battle_anim_mons.c:252: a player pic's centre sinks no lower than
  -- 160 - 64 + 8 - 4, so its top row no lower than 68
  ALLY_TOP_MAX = 68,
  -- Anim.substituteY (battle_anim_mons.c:286): base y + 16 / + 17
  FOE_DOLL_Y = { 56, 48 }, ALLY_DOLL_Y = { 97, 105 },
  -- Healthbox.CENTERS[true] (pokefirered battle_interface.c:726): foe
  -- (44,19) (32,44), player (159,75) (171,100); the sheet's corner is - (32,16)
  FOE_BOX_X = { 12, 0 }, FOE_BOX_Y = { 3, 28 },
  ALLY_BOX_X = { 127, 139 }, ALLY_BOX_Y = { 59, 84 },
  -- the drawn part of the doubles healthbox sheets (both sides; FireRed's is
  -- a row taller than Emerald's), for the layout checks
  BOX_VIS = { dx = 1, dy = 2, w = 100, h = 26 },
  -- the boxes of one side sit 25 rows apart, so FireRed's 26-row sheets share
  -- one: the first battler's box is drawn last and covers it
  SIDE_BOX_SHARE = 1,
  -- AnimCoords.DRAW_ORDER_DOUBLES { 3, 1, 0, 2 } (ui.lua draw_double_mons):
  -- back to front, the player's back pic between the sides
  DRAW_ORDER = { { "b", 2 }, { "b", 1 }, { "a", 1 }, { "a", 2 } },
  -- ui.lua draw_double_healthboxes (battle_interface.c:540): battlers 3..0
  BOX_ORDER = { { "b", 2 }, { "a", 2 }, { "b", 1 }, { "a", 1 } },
  -- ui.lua blink_start / tick_target (battle_main.c:2019): lit 8 frames,
  -- hidden 8, restarted lit whenever the cursor moves
  BLINK_FRAMES = 8,
  -- ui.lua start_bounce / tick_bounces (battle_main.c:2091, :2159; the
  -- callers battle_controller_player.c:223, :326): the choosing battler's
  -- box and pic, and while aiming the target's box
  BOUNCE_BOX = { idx = 128, delta = 7, amp = 1 },
  BOUNCE_MON = { idx = 192, delta = 7, amp = 1 },
  BOUNCE_TARGET_BOX = { idx = 128, delta = 15, amp = 1 },
  -- ui.lua preview_targets / tick_preview (battle_controller_player.c:2889,
  -- :442) over the cart's palette fade (ui.lua fade_begin / fade_update,
  -- palette.c:151, :393, :757): a hovered move's battlers wash towards white
  -- from startY 8/16, deltaY 2 lighter a step, each step a delay of 8 frames
  -- plus the fade's two passes (BG, then the OBJ palettes the battlers wear),
  -- then 5 frames finishing; the next fade begins the frame after
  PREVIEW_Y = 8, PREVIEW_DELTA = 2, PREVIEW_DELAY = 8, PREVIEW_FINISH = 5,
  -- the fade's blend colour, RGB_WHITE in the cart's 5-bit channels
  PREVIEW_RGB = { 31, 31, 31 },
  -- healthbox.lua draw_doubles / draw_hp_text_doubles (pokefirered
  -- battle_interface.c:864, :925): with the figures swapped in, "cur/" and
  -- "max" sit one 8px cell a character from the bar's left + 8 (the small
  -- font 3 rows higher than the bold digits), and the box's bottom-right
  -- corner tile goes to the corner + (96, 16)
  HP_TEXT_DX = 8, HP_TEXT_CELL = 8, HP_TEXT_FONT_DY = -3,
  HP_TEXT_CORNER_TILE = 116, HP_TEXT_CORNER_DX = 96,
}
local D = M.G3D

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
-- The HP bar's own ink, which a doubles box's swapped-in figures print in
-- when the cache has no bold HP digits (healthbox.lua BAR_FG / BAR_SHADOW).
local HB_HP_TEXT = {
  fg = { c5(7), c5(7), c5(7), 1 }, shadow = { c5(26), c5(25), c5(23), 1 },
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
  -- Whole glyphs off the end (M.glyphPrefix): dropping continuation bytes
  -- alone left the lead byte of "é" behind, half a UTF-8 sequence.  Cut in
  -- place, with no table of glyphs: a label that does not fit is cut again
  -- every frame it is drawn.
  local n = M.glyphCount(text)
  local cut = text
  while n > 1 and measure(F, cut, opts) > px do
    n = n - 1
    cut = M.glyphPrefix(text, n)
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

-- The battle's YES / NO, the way PlayerHandleYesNoBox prints it
-- (gText_BattleYesNoChoice, "YES\nNO"), broken on its newline -- the cart's
-- words when its text is reachable, else the two plain ones.
local yesNoCache = nil
function M.gen3YesNoLabels()
  if yesNoCache then return yesNoCache end
  local labels = {}
  local text = romPlain("gText_BattleYesNoChoice", nil)
  if type(text) == "string" then
    for line in (text .. "\n"):gmatch("(.-)\n") do
      local word = line:gsub("^%s+", ""):gsub("%s+$", "")
      if word ~= "" then labels[#labels + 1] = word end
    end
  end
  if #labels ~= 2 then labels = { "YES", "NO" } end
  -- Cached only once the cart has answered, so a first ask before the cache
  -- mounted does not pin the fallback for the session.
  if text then yesNoCache = labels end
  return labels
end

-- The YES / NO window's rects in pixels: `frame` (the std frame around the
-- text window), `rows` (each answer's text origin) and `cursor` (the arrow's
-- origin for each row).  Pure.
function M.gen3YesNoLayout()
  local rows, cursor = {}, {}
  for i = 1, 2 do
    local y = G.YESNO_TEXT_Y + (i - 1) * G.YESNO_PITCH
    rows[i] = { x = G.YESNO_TEXT_X, y = y }
    cursor[i] = { x = G.YESNO_CURSOR_X, y = y }
  end
  return {
    frame = { x = (G.YESNO_TX - 1) * 8, y = (G.YESNO_TY - 1) * 8,
              w = (G.YESNO_TW + 2) * 8, h = (G.YESNO_TH + 2) * 8 },
    rows = rows, cursor = cursor,
  }
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

local function doubleSeat(seats, i)
  local seat = type(seats) == "table" and seats[i] or nil
  return type(seat) == "table" and seat or nil
end

-- The battler a double's `blink` names: "a" / "b" and 1 / 2, else nil.
local function blinkTarget(blink)
  if type(blink) ~= "table" then return nil end
  local i = tonumber(blink.index)
  if i ~= 1 and i ~= 2 then return nil end
  if blink.side ~= "a" and blink.side ~= "b" then return nil end
  return blink.side, i
end

-- The cart's target blink (ui.lua tick_target): lit for BLINK_FRAMES from
-- the moment the cursor lands, hidden as long, and so on.
function M.gen3BlinkShown(blink, frame)
  if not blinkTarget(blink) then return true end
  local n = math.floor(num3(frame, 0) - num3(blink.since, 0))
  if n < 0 then return true end
  return math.floor(n / D.BLINK_FRAMES) % 2 == 0
end

-- MOVE_TARGET_* (the engine's ui.lua MT, pokefirered include/battle.h).
local MT = {
  SELECTED = 0, DEPENDS = 1, USER_OR_SELECTED = 2, RANDOM = 4, BOTH = 8,
  USER = 16, FOES_AND_ALLY = 32, OPPONENTS_FIELD = 64,
}
-- ui.lua PREVIEW_ALL / PREVIEW_ALLIES / MOVE_HELPING_HAND
-- (battle_controller_player.c:2889): the USER moves that touch the whole
-- field (Haze, Sandstorm, Perish Song, the weathers, the Sports), the user's
-- side (Safeguard, the screens, Mist, Heal Bell, Aromatherapy) or the
-- partner, by pret move number.
local PREVIEW_ALL = {
  [114] = true, [201] = true, [195] = true, [240] = true, [241] = true,
  [258] = true, [300] = true, [346] = true,
}
local PREVIEW_ALLIES = {
  [219] = true, [115] = true, [113] = true, [54] = true, [215] = true, [312] = true,
}
local MOVE_HELPING_HAND = 270

local function allFour() return { a1 = true, b1 = true, a2 = true, b2 = true } end

-- The cart's rule for one move (ui.lua preview_targets): an exact match on
-- the target byte, as the engine compares it. `chooser` is the ally whose
-- menu is up (1 | 2), its partner the other.
local function previewMask(move, chooser)
  local tt = math.floor(num3(move.target, 0))
  local num = math.floor(num3(move.num, num3(move.id, 0)))
  local partner = "a" .. (3 - chooser)
  if tt == MT.SELECTED or tt == MT.DEPENDS or tt == MT.USER_OR_SELECTED or tt == MT.RANDOM then
    -- still to be aimed (or the cart's own pick): all four from 0, which
    -- shows nothing -- the cart lights only what it already knows is hit
    return allFour(), 0
  elseif tt == MT.BOTH or tt == MT.OPPONENTS_FIELD then
    return { b1 = true, b2 = true }, D.PREVIEW_Y
  elseif tt == MT.USER then
    if PREVIEW_ALL[num] then return allFour(), D.PREVIEW_Y end
    if PREVIEW_ALLIES[num] then return { a1 = true, a2 = true }, D.PREVIEW_Y end
    if num == MOVE_HELPING_HAND then return { [partner] = true }, D.PREVIEW_Y end
    return { ["a" .. chooser] = true }, D.PREVIEW_Y
  elseif tt == MT.FOES_AND_ALLY then
    return { b1 = true, [partner] = true, b2 = true }, D.PREVIEW_Y
  end
  return {}, 0
end

-- The hovered move's preview in a double's move menu: the battlers keyed
-- "a1".."b2" (the view's allies / foes) and the fade's startY. The cart runs
-- it only in the move menu (ui.lua tick_preview: is_double and mode
-- "moves"), so not while aiming, nor over a list or the action menu.
function M.gen3PreviewTargets(view)
  view = type(view) == "table" and view or {}
  local double = type(view.double) == "table" and view.double or nil
  if not double or view.phase == "target" or view.commands ~= nil
     or type(view.list) == "table" or type(view.moves) ~= "table" then
    return nil, 0
  end
  local moves = view.moves
  local cursor = math.max(1, math.min(4, math.floor(num3(view.cursor or view.moveCursor, 1))))
  if #moves > 0 and cursor > #moves then cursor = #moves end
  local move = moves[cursor]
  if type(move) ~= "table" or tonumber(move.target) == nil then return nil, 0 end
  -- the engine's chooser is Ui._active or battler 0
  local chooser = tonumber(double.choosing)
  if chooser ~= 1 and chooser ~= 2 then chooser = 1 end
  return previewMask(move, chooser)
end

-- One preview fade, `n` frames in (ui.lua fade_begin / fade_update): startY
-- from the frame it begins, deltaY lighter every delay + 2 frames down to 0,
-- then the finishing frames; the cart's next fade begins the frame after
-- them, so a fade from 8 lasts 46 frames and one from 0 (nothing lit) 6.
function M.gen3PreviewWash(startY, n)
  startY = math.max(0, math.floor(num3(startY, 0)))
  local stepFrames = D.PREVIEW_DELAY + 2
  local lit = math.ceil(startY / D.PREVIEW_DELTA) * stepFrames
  local length = lit + D.PREVIEW_FINISH + 1
  n = math.floor(num3(n, 0))
  if n < 0 or n > lit then return 0, length end
  return math.max(0, startY - D.PREVIEW_DELTA * math.floor(n / stepFrames)), length
end

-- The double screen's rects: per battler its pic frame (64x64 on its feet;
-- the player's cut at the textbox as the cart cuts them) and its healthbox's
-- drawn part, keyed foePic1 / foeBox1 ... allyPic2 / allyBox2 for the seats
-- present; `blink` is the aimed-at battler's pic; `preview` the pics the
-- hovered move washes (a list, in the cart's battler order 0..3; absent when
-- the preview lights nothing); allyHp1 / allyHp2 the HP figures' cells when
-- `hpText` swaps them in; `list` a window the page draws. Bobbing (two
-- pixels at most) is not in them. On the cart the pics overlap one another
-- and the healthboxes cover the pics' edges by design; what holds is that
-- everything lies on the 240x160 page, no healthbox reaches the textbox, the
-- two sides' boxes stay apart, and the two boxes of one side share at most
-- SIDE_BOX_SHARE rows.
function M.gen3DoubleLayout(view)
  view = type(view) == "table" and view or {}
  local double = type(view.double) == "table" and view.double or {}
  local out = { panel = rect(0, G.PANEL_Y, G.W, G.PANEL_H) }
  local vis = D.BOX_VIS
  for i = 1, 2 do
    if doubleSeat(double.foes, i) then
      out["foeBox" .. i] = rect(D.FOE_BOX_X[i] + vis.dx, D.FOE_BOX_Y[i] + vis.dy, vis.w, vis.h)
      out["foePic" .. i] = rect(D.FOE_PIC_X[i] - G.PIC / 2, D.FOE_FEET_Y[i] + 1 - G.PIC, G.PIC, G.PIC)
    end
    if doubleSeat(double.allies, i) then
      out["allyBox" .. i] = rect(D.ALLY_BOX_X[i] + vis.dx, D.ALLY_BOX_Y[i] + vis.dy, vis.w, vis.h)
      local top = D.ALLY_FEET_Y[i] + 1 - G.PIC
      out["allyPic" .. i] = rect(D.ALLY_PIC_X[i] - G.PIC / 2, top, G.PIC, G.PANEL_Y - top)
      if double.hpText == true then
        -- seven cells from the bar's left + 8: "cur/" then "max"
        out["allyHp" .. i] = rect(D.ALLY_BOX_X[i] + 32 + D.HP_TEXT_DX, D.ALLY_BOX_Y[i] + 16,
          7 * D.HP_TEXT_CELL, D.HP_TEXT_CELL)
      end
    end
  end
  local side, index = blinkTarget(double.blink)
  if side then
    local pic = out[(side == "a" and "allyPic" or "foePic") .. index]
    if pic then out.blink = rect(pic.x, pic.y, pic.w, pic.h) end
  end
  local mask, startY = M.gen3PreviewTargets(view)
  if mask and startY > 0 then
    local lit = {}
    for _, key in ipairs({ "a1", "b1", "a2", "b2" }) do
      local pic = mask[key] and out[(key:sub(1, 1) == "a" and "allyPic" or "foePic") .. key:sub(2)]
      if pic then lit[#lit + 1] = rect(pic.x, pic.y, pic.w, pic.h) end
    end
    if #lit > 0 then out.preview = lit end
  end
  if type(view.list) == "table" and view.phase ~= "target" and not M.gen3IsPartyList(view.list) then
    out.list = rect((G.LIST_TX - 1) * 8, (G.LIST_TY - 1) * 8,
      (G.LIST_TW + 2) * 8, (G.LIST_TH + 2) * 8)
  end
  return out
end

-- ------- drawing pieces

-- A pic stood on its feet line: the art's lowest opaque row lands on `feetY`
-- (what the cart's pic offsets do), centred on `cx`. `maxTop` (the double
-- screen's player side) is the lowest the cart lets the frame's top sink.
local function drawStandingPic(gfx, BF, img, cx, feetY, seat, maxTop)
  if not img then return end
  seat = seat or {}
  local ok, iw, ih = pcall(img.getDimensions, img)
  if not ok then return end
  local pad = BF and BF.picFloorPad and BF.picFloorPad(img) or 0
  local x = math.floor(cx - iw / 2 + num3(seat.dx, 0))
  local top = feetY - (ih - 1 - pad) - num3(seat.elevation, 0)
  if maxTop and top > maxTop then top = maxTop end
  local y = math.floor(top + num3(seat.dy, 0))
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
-- `cx`, `cy`, `feetY` place it elsewhere (the double screen's battlers).
local function drawDoll(gfx, BF, back, seat, cx, cy, feetY)
  local img = BF and BF.gen3SubstituteDoll and BF.gen3SubstituteDoll(back) or nil
  cx = cx or (back and G.ALLY_PIC_X or G.FOE_PIC_X)
  cy = cy or (back and G.ALLY_DOLL_Y or G.FOE_DOLL_Y)
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
    BF.drawDollStandIn(gfx, cx, feetY or (back and G.PANEL_Y or G.FOE_FEET_Y), back and 48 or 40,
      alpha, false)
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

-- One doubles healthbox with its corner on (x, y), the way the engine's
-- healthbox.lua draw_doubles lays it (pokefirered battle_interface.c:1531,
-- :1608): the doubles sheet (BattleChrome.drawDoublesBox falls back to the
-- singles foe sheet itself when the cache has none), the HP bar with the
-- status border on either side, name and gender, Lv, the status icon. No EXP
-- bar, no caught ball; HP figures only where `hpText` (the player's boxes
-- after START) swaps them in for the bar.
--
-- The figures as healthbox.lua draw_hp_text_doubles prints them
-- (battle_interface.c:864): "%3d/" and "%3d", a character to an 8px cell
-- from the bar's left + 8, blanks skipped -- the cart's bold HP digits when
-- the cache has them, else the small font in the bar's ink.
local function drawDoubleHpText(C, F, hp, maxHp, bx, by)
  local text = ("%3d/%3d"):format(math.max(0, math.min(999, math.floor(hp))),
    math.max(0, math.min(999, math.floor(maxHp))))
  local bold = false
  if type(C.hasHpBoldDigits) == "function" and type(C.drawHpBoldChar) == "function" then
    local ok, has = pcall(C.hasHpBoldDigits)
    bold = ok and has == true
  end
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch ~= " " then
      local cx = bx + D.HP_TEXT_DX + (i - 1) * D.HP_TEXT_CELL
      if bold then
        pcall(C.drawHpBoldChar, ch, cx, by)
      else
        drawText(F, ch, cx, by + D.HP_TEXT_FONT_DY, { small = true, colors = HB_HP_TEXT })
      end
    end
  end
end

local function drawDoubleBox(gfx, C, F, seat, isPlayer, x, y, hpText)
  if type(C.drawDoublesBox) == "function" then
    pcall(C.drawDoublesBox, isPlayer, x, y)
  else
    pcall(C.drawEnemyBox, x, y)
  end
  eraseInk(gfx, x, y, isPlayer and INK.ally or INK.foe)
  local maxHp = math.max(1, num3(seat.maxHp, 1))
  local hp = math.max(0, math.min(maxHp, num3(seat.hp, 0)))
  local ailment = ailmentOf(seat)
  local statused = ailment >= 1 and ailment <= 6
  if hpText and isPlayer then
    -- the figures where the bar was, and the box's corner tile that closes
    -- them in (healthbox.lua draw_doubles, battle_interface.c:925)
    drawDoubleHpText(C, F, hp, maxHp, x + 32, y + 16)
    if type(C.drawElementTile) == "function" then
      pcall(C.drawElementTile, D.HP_TEXT_CORNER_TILE, x + D.HP_TEXT_CORNER_DX, y + 16, true)
    end
  else
    pcall(C.drawHpBar, x + (isPlayer and 32 or 24), y + 16, hp, maxHp, statused)
  end
  drawNameGender(F, tostring(seat.name or "?"), seat.gender, x + (isPlayer and 16 or 8), y + 3)
  drawLevel(F, seat.shownLevel or seat.level, x, y + 3, isPlayer and 72 or 64)
  local SummaryChrome = g3eng("src.ui.game3.summary_chrome")
  if statused and SummaryChrome then
    pcall(SummaryChrome.drawStatusIcon, x + (isPlayer and 10 or 2), y + 16, ailment)
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

-- The YES / NO window over the right of the field, its question still in the
-- textbox below (pret PlayerHandleYesNoBox / BattleCreateYesNoCursorAt).
local function drawYesNo(gfx, F, yesNo)
  local Gen3Ui = nil
  pcall(function() Gen3Ui = need("Gen3Ui") end)
  local box = M.gen3YesNoLayout()
  if Gen3Ui and type(Gen3Ui.frame) == "function" then
    Gen3Ui.frame(G.YESNO_TX, G.YESNO_TY, G.YESNO_TW, G.YESNO_TH)
  else
    gfx.setColor(1, 1, 1, 1)
    gfx.rectangle("fill", box.frame.x, box.frame.y, box.frame.w, box.frame.h)
  end
  local normal = F.COLOR and F.COLOR.NORMAL
  local labels = M.gen3YesNoLabels()
  for i = 1, 2 do
    drawText(F, labels[i] or "", box.rows[i].x, box.rows[i].y, { colors = normal })
  end
  local cursor = (type(yesNo) == "table" and tonumber(yesNo.cursor) == 2) and 2 or 1
  drawCursor(F, box.cursor[cursor].x, box.cursor[cursor].y, normal)
  gfx.setColor(1, 1, 1, 1)
end

-- Oak's line in the voice-over frame (B_WIN_OAK_OLD_MAN, the dialogue
-- window's rect): dark ink on the cart's dialogue window in place of the
-- battle textbox, two lines at most, the ▼ under a page still being read.
local function drawVoiceover(gfx, F, text, hint)
  local Gen3Ui = nil
  pcall(function() Gen3Ui = need("Gen3Ui") end)
  if Gen3Ui and type(Gen3Ui.dialogueFrame) == "function" then
    Gen3Ui.dialogueFrame()
  else
    gfx.setColor(1, 1, 1, 1)
    gfx.rectangle("fill", 8, G.PANEL_Y + 2, G.W - 16, G.PANEL_H - 4)
  end
  text = printable(text)
  if text == "" then return end
  local wrapped = text
  if type(F.wrap) == "function" then
    local ok, w = pcall(F.wrap, text, G.MSG_W)
    if ok and type(w) == "string" then wrapped = w end
  end
  local lines = {}
  for line in (wrapped .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
    if #lines >= 2 then break end
  end
  local colors = F.COLOR and F.COLOR.NORMAL
  local pitch = tonumber(F.LINE_PITCH) or 15
  local endX = G.VOICEOVER_X
  for i, line in ipairs(lines) do
    drawText(F, line, G.VOICEOVER_X, G.VOICEOVER_Y + (i - 1) * (pitch + 1), { colors = colors })
    if i == #lines then endX = G.VOICEOVER_X + measure(F, line) end
  end
  if hint and F.CHAR_DOWN_ARROW and type(F.drawGlyph) == "function" then
    pcall(F.drawGlyph, F.CHAR_DOWN_ARROW, math.min(endX + 2, 228),
      G.VOICEOVER_Y + (#lines - 1) * (pitch + 1), { colors = colors })
  end
  gfx.setColor(1, 1, 1, 1)
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

-- ------- the field (singles and doubles share these)

-- The foe trainer's front pic, where its monsters will stand (ui.lua
-- draw_enemy_trainer: (176, 40), a lone trainer's double included).
local function drawEnemyTrainer(gfx, BF, trainer)
  local picId = trainer.pic or trainer.picId
  local img = BF and picId ~= nil and BF.gen3TrainerPic(picId) or nil
  if img then
    local ok, iw, ih = pcall(img.getDimensions, img)
    if ok then
      gfx.setColor(1, 1, 1, 1)
      gfx.draw(img, G.TRAINER_X - math.floor(iw / 2), G.TRAINER_Y - math.floor(ih / 2))
    end
  end
end

-- The player's own back pic (the first frame of the sheet).
local function drawPlayerBack(gfx, playerBack)
  local entry = type(Gen3) == "table" and Gen3.trainerBackPic(playerBack.gender) or nil
  if type(entry) == "table" and entry.image then
    local quad = backQuad(gfx, entry.image)
    gfx.setColor(1, 1, 1, 1)
    if quad then
      gfx.draw(entry.image, quad, G.PLAYER_BACK_X - 32, G.PLAYER_BACK_Y - 32)
    end
  end
end

-- A foe's front pic on its platform: a floater hovers over it by the cart's
-- own elevation for it, when the screen did not say (a seat carrying its
-- species).
local function drawFoePic(gfx, BF, foe, cx, feetY)
  local stand = foe
  if foe.elevation == nil and BF and BF.gen3Elevation then
    local elev = BF.gen3Elevation(tonumber(foe.speciesId) or tonumber(foe.species))
    if elev then
      stand = setmetatable({ elevation = elev }, { __index = foe })
    end
  end
  drawStandingPic(gfx, BF, seatPic(BF, foe, false), cx, feetY, stand)
end

-- Over the battlers, under the healthboxes as the cart layers it: a bench
-- evolution mid-field, the weather (the arena's own painter, at the page's
-- scale), the evolution's flash.
local function drawFieldOverlays(gfx, BF, view, frame)
  if view.evolveFront then
    drawStandingPic(gfx, BF, view.evolveFront, G.W / 2, 88, nil)
  end
  if view.weather and BF and BF.drawWeather then
    BF.drawWeather(view.weather, 0, 0, G.W, G.PANEL_Y, frame, 0.5)
  end
  local flash = math.max(0, math.min(1, num3(view.evolveFlash, 0)))
  if flash > 0 then
    gfx.setColor(1, 1, 1, flash)
    gfx.rectangle("fill", 0, 0, G.W, G.PANEL_Y)
  end
  gfx.setColor(1, 1, 1, 1)
end

-- The singles field: the focused pair, the guild-focus rails (2v2 / 3v3),
-- the two healthboxes and the foe's remaining party under its box.
local function drawSingleField(gfx, C, F, BF, view, frame)
  local foe, ally = view.foe, view.ally
  -- the foe trainer, where the foe will stand
  if type(view.trainer) == "table" and (view.showTrainer or not foe) then
    drawEnemyTrainer(gfx, BF, view.trainer)
  end
  if type(foe) == "table" and not foe.hidden and not (view.showTrainer and view.trainer) then
    if foe.substitute then
      drawDoll(gfx, BF, false, foe)
    else
      drawFoePic(gfx, BF, foe, G.FOE_PIC_X, G.FOE_FEET_Y)
    end
  end
  -- the player's own back pic, while no monster is out
  if type(view.playerBack) == "table" and (view.showPlayer or not ally) then
    drawPlayerBack(gfx, view.playerBack)
  end
  if type(ally) == "table" and not ally.hidden and not (view.showPlayer and view.playerBack) then
    if ally.substitute then
      drawDoll(gfx, BF, true, ally)
    else
      drawStandingPic(gfx, BF, seatPic(BF, ally, true), G.ALLY_PIC_X, G.ALLY_FEET_Y, ally)
    end
  end
  drawFieldOverlays(gfx, BF, view, frame)

  -- the guild-focus rails (2v2 / 3v3)
  drawStrip(gfx, BF, F, "foe", view.foeStrip, frame)
  drawStrip(gfx, BF, F, "ally", view.allyStrip, frame)

  -- the healthboxes, and the foe's remaining party under its box
  if type(foe) == "table" then drawFoeBox(gfx, C, F, foe) end
  if type(ally) == "table" then drawAllyBox(gfx, C, F, ally) end
  if view.foeParty ~= nil and M.wantsFoeBalls(view.mode) then
    drawFoeBalls(C, view.foeParty)
  end
end

-- pokefirered trig.c:4 / battle_main.c:2159 (ui.lua sin_q8, tick_bounces):
-- sin(idx) * amp + amp, the index stepping `delta` a frame -- a bob of a
-- pixel or two, phased by the page clock.
local function bounce3(spec, frame)
  local idx = (spec.idx + spec.delta * math.floor(num3(frame, 0))) % 256
  local v = math.floor(math.sin(idx * math.pi / 128) * 256 + 0.5)
  return math.floor(v * spec.amp / 256) + spec.amp
end

-- What moves on the double screen this frame, by the cart's rules: while the
-- command or move menu is up the choosing battler's pic and box bob
-- (battle_controller_player.c:223); while aiming, the target's box bobs
-- instead of the chooser's (:326) and the target blinks.
-- -> hiddenKey ("a1".."b2" or nil), the bobbing pic's key and offset, the
--    bobbing box's key and offset.
local function doubleMotion(view, double, frame)
  local side, index = blinkTarget(double.blink)
  local hiddenKey = nil
  if side and not M.gen3BlinkShown(double.blink, frame) then hiddenKey = side .. index end
  local aiming = side ~= nil and view.phase == "target"
  local menuUp = aiming or view.commands ~= nil or view.moves ~= nil
  local choosing = tonumber(double.choosing)
  if choosing ~= 1 and choosing ~= 2 then choosing = nil end
  local picKey, picDy, boxKey, boxDy = nil, 0, nil, 0
  if menuUp and choosing then
    picKey, picDy = "a" .. choosing, bounce3(D.BOUNCE_MON, frame)
    boxKey, boxDy = "a" .. choosing, bounce3(D.BOUNCE_BOX, frame)
  end
  if aiming then
    boxKey, boxDy = side .. index, bounce3(D.BOUNCE_TARGET_BOX, frame)
  end
  return hiddenKey, picKey, picDy, boxKey, boxDy
end

-- The preview's wash this frame, { a1 = coeff, ... } for the battlers lit,
-- else nil. A cart fade, once begun, plays out with the mask it began with
-- (BeginNormalPaletteFade refuses while one runs, palette.c:151, the
-- clearing fade a cursor move asks for as well), so a cursor moved mid-fade
-- lets the old move's battlers finish first, and the next fade takes the
-- move hovered when it begins. That needs where the running fade began and
-- what it lights: kept on the screen's state (as the terrain is), restarted
-- when the menu opens; with no state the page clock phases it.
local PREVIEW_MEMO = "__g3PreviewFade"
local function previewWash(view, double, state, frame)
  local mask, startY = M.gen3PreviewTargets(view)
  local memo = type(state) == "table"
  if not mask then
    if memo and rawget(state, PREVIEW_MEMO) ~= nil then rawset(state, PREVIEW_MEMO, nil) end
    return nil
  end
  local f = math.floor(num3(frame, 0))
  local chooser = double.choosing
  local run = memo and rawget(state, PREVIEW_MEMO) or nil
  if type(run) ~= "table" or run.chooser ~= chooser or f < run.start then
    -- the menu just opened: the cart's first fade begins on this frame
    run = { start = f, mask = mask, startY = startY, chooser = chooser }
    if memo then
      rawset(state, PREVIEW_MEMO, run)
    else
      local _, length = M.gen3PreviewWash(startY, 0)
      run.start = f - f % length
    end
  else
    local _, length = M.gen3PreviewWash(run.startY, 0)
    if f >= run.start + length then
      -- the next fade, on the move hovered now (whole fades skipped between
      -- two draws are taken to have been this move's too)
      local _, nextLength = M.gen3PreviewWash(startY, 0)
      local begun = run.start + length
      run.start = begun + math.floor((f - begun) / nextLength) * nextLength
      run.mask, run.startY = mask, startY
    end
  end
  local coeff = M.gen3PreviewWash(run.startY, f - run.start)
  if coeff <= 0 then return nil end
  local lit = nil
  for key in pairs(run.mask) do
    lit = lit or {}
    lit[key] = coeff
  end
  return lit
end

-- The cart's palette blend for one battler (ui.lua draw_mon:
-- BallOpen.setBlendShader(coeff, 31, 31, 31), the engine's own BlendPalette
-- shader) -> true when it is on, for the caller to switch off again.
local function washOn(coeff)
  if not coeff or coeff <= 0 then return false end
  local BallOpen = g3eng("src.core.game3.battle.ball_open")
  if not (BallOpen and type(BallOpen.setBlendShader) == "function") then return false end
  local rgb = D.PREVIEW_RGB
  local ok, on = pcall(BallOpen.setBlendShader, coeff, rgb[1], rgb[2], rgb[3])
  return ok and on == true
end

-- The double screen's field (ui.lua draw_double_mons and
-- draw_double_healthboxes): the foe trainer first, the four battlers back to
-- front with the player's back pic between the sides (the move preview's
-- wash on the pics it lights, a doll too, as the cart blends the battler's
-- palette; `wash` is previewWash's), the overlays, then the four
-- healthboxes, the first battler of each side over its partner.
local function drawDoubleField(gfx, C, F, BF, view, double, frame, wash)
  local foes, allies = double.foes, double.allies
  local anyFoe = doubleSeat(foes, 1) or doubleSeat(foes, 2)
  local anyAlly = doubleSeat(allies, 1) or doubleSeat(allies, 2)
  local hiddenKey, picKey, picDy, boxKey, boxDy = doubleMotion(view, double, frame)
  if type(view.trainer) == "table" and (view.showTrainer or not anyFoe) then
    drawEnemyTrainer(gfx, BF, view.trainer)
  end
  local foesOut = not (view.showTrainer and view.trainer)
  local alliesOut = not (view.showPlayer and view.playerBack)
  local backDrawn = false
  for _, at in ipairs(D.DRAW_ORDER) do
    local side, i = at[1], at[2]
    local isPlayer = side == "a"
    if isPlayer and not backDrawn then
      backDrawn = true
      if type(view.playerBack) == "table" and (view.showPlayer or not anyAlly) then
        drawPlayerBack(gfx, view.playerBack)
      end
    end
    local seat = doubleSeat(isPlayer and allies or foes, i)
    local out = foesOut
    if isPlayer then out = alliesOut end
    if seat and out and not seat.hidden and hiddenKey ~= side .. i then
      local washed = wash ~= nil and washOn(wash[side .. i])
      if isPlayer then
        if seat.substitute then
          -- the cart stands a doll on its substitute line, unbobbed
          drawDoll(gfx, BF, true, seat, D.ALLY_PIC_X[i], D.ALLY_DOLL_Y[i], G.PANEL_Y)
        else
          local stand = seat
          if picKey == side .. i and picDy ~= 0 then
            stand = setmetatable({ dy = num3(seat.dy, 0) + picDy }, { __index = seat })
          end
          drawStandingPic(gfx, BF, seatPic(BF, seat, true), D.ALLY_PIC_X[i], D.ALLY_FEET_Y[i],
            stand, D.ALLY_TOP_MAX)
        end
      elseif seat.substitute then
        drawDoll(gfx, BF, false, seat, D.FOE_PIC_X[i], D.FOE_DOLL_Y[i], D.FOE_FEET_Y[i])
      else
        drawFoePic(gfx, BF, seat, D.FOE_PIC_X[i], D.FOE_FEET_Y[i])
      end
      if washed then pcall(gfx.setShader) end
    end
  end
  drawFieldOverlays(gfx, BF, view, frame)
  local hpText = double.hpText == true
  for _, at in ipairs(D.BOX_ORDER) do
    local side, i = at[1], at[2]
    local isPlayer = side == "a"
    local seat = doubleSeat(isPlayer and allies or foes, i)
    if seat then
      local x = isPlayer and D.ALLY_BOX_X[i] or D.FOE_BOX_X[i]
      local y = isPlayer and D.ALLY_BOX_Y[i] or D.FOE_BOX_Y[i]
      if boxKey == side .. i then y = y + boxDy end
      drawDoubleBox(gfx, C, F, seat, isPlayer, x, y, hpText)
    end
  end
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
      local double = type(view.double) == "table" and view.double or nil
      -- a double's aim keeps the move menu up and blinks the battler aimed
      -- at (ui.lua Ui.draw: "target" draws the move menu): the cart has no
      -- TARGET window, so the screen's list is not drawn then
      local list = view.list
      if double and view.phase == "target" then list = nil end
      -- the move preview's fade clock, run (and reset once the move menu
      -- goes) whatever the page shows, the POKéMON page included
      local wash = double and previewWash(view, double, state, frame) or nil
      -- a POKéMON list is the whole page
      if type(list) == "table" and M.gen3IsPartyList(list) then
        drawPartyPage(gfx, C, F, BF, list, frame)
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
      if double then
        drawDoubleField(gfx, C, F, BF, view, double, frame, wash)
      else
        drawSingleField(gfx, C, F, BF, view, frame)
      end
      -- Oak's voice-over: the field darkened under his line, which prints
      -- in its own frame in place of the textbox.
      if view.voiceover then
        gfx.setColor(0, 0, 0, G.VOICEOVER_DIM)
        gfx.rectangle("fill", 0, 0, G.W, G.PANEL_Y)
        gfx.setColor(1, 1, 1, 1)
        -- ...and the one healthbox the cart lights again under this line
        -- (`voiceoverLit`, DoLoadHealthboxPalsForLevelUp's fade back).
        if not double then
          if view.voiceoverLit == "foe" and type(view.foe) == "table" then
            drawFoeBox(gfx, C, F, view.foe)
          elseif view.voiceoverLit == "ally" and type(view.ally) == "table" then
            drawAllyBox(gfx, C, F, view.ally)
          end
        end
        if not (type(list) == "table" or view.commands or view.moves) then
          pcall(C.drawPanel, "none")
          drawVoiceover(gfx, F, view.message, view.hint == true and not view.hold)
          return
        end
      end

      -- the textbox
      if type(list) == "table" then
        drawListWindow(gfx, C, F, list)
        return
      end
      local mode = "none"
      if view.commands then mode = "menu"
      elseif view.moves then mode = "moves" end
      if double and view.phase == "target" and view.moves then mode = "moves" end
      pcall(C.drawPanel, mode)
      pcall(C.drawMenuFrames, mode)
      if view.yesNo and mode == "none" then
        -- a yes / no: the question stays in the textbox, the answers beside it
        drawMessage(F, view.message, false)
        drawYesNo(gfx, F, view.yesNo)
      elseif mode == "menu" then
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
