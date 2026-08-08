-- Every screen the mod puts on the stack.
--
-- All of them are registered in the `screens` registry and reached with
-- mod.ui.push, including the ones that only wrap a widget instance.  That
-- indirection is the point: pushing a state means touching game.stack,
-- which is engine internals, whereas Screens.push is the supported door and
-- takes its arguments straight through to the registered constructor.  So a
-- one-line screen like RbyMmoState -- whose whole job is to hand back a
-- state somebody else built -- buys the mod a supported way to show it.
--
-- Widgets come from mod.ui (the shared toolkit facade), never from a
-- private require.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local Chat = need("Chat")
local World = need("World")
local Chars = need("Chars")
local Cast = need("Cast")
local Places = need("Places")

local M = {}
M.__index = M

local SCREEN = {
  TEXT     = "RbyMmoText",
  CONFIRM  = "RbyMmoConfirm",
  STATE    = "RbyMmoState",
  MAIN     = "RbyMmoMain",
  ROSTER   = "RbyMmoRoster",
  ACTIONS  = "RbyMmoActions",
  CHATLOG  = "RbyMmoChatLog",
  PARTY    = "RbyMmoParty",
  MEMBERS  = "RbyMmoPartyList",
  SCOPE    = "RbyMmoScope",
  COMPOSE  = "RbyMmoCompose",
  PICK     = "RbyMmoPick",
  HOSTSET  = "RbyMmoHostSetup",
  HOSTSIZE = "RbyMmoHostSize",
  HOSTCODE = "RbyMmoHostCode",
  HOSTINFO = "RbyMmoHostInfo",
  JOINADDR = "RbyMmoJoinAddress",
  JOINCODE = "RbyMmoJoinCode",
  SERVERS  = "RbyMmoServers",
  SERVERACT = "RbyMmoServerActions",
  SERVEREDIT = "RbyMmoServerEdit",
  CHARSET  = "RbyMmoCharSetup",
  CHARPICK = "RbyMmoCharPick",
  PROFILE  = "RbyMmoProfile",
  RANK     = "RbyMmoRank",
  CHOOSE   = "RbyMmoChoose",
  MENU_CHOOSE = "RbyMmoChooseMenu",
}
M.SCREEN = SCREEN

-- ------- the digits page
--
-- The vanilla naming grid (src/ui/NamingScreen.lua) carries letters, space
-- and punctuation and *no digits at all*, so an address like
-- "192.168.1.20:7788" is literally untypeable on it. The ui.naming.grid
-- hook exists to replace a page, and its context carries the screen title,
-- so the swap below is scoped to the naming screens this mod pushes and
-- leaves rival-naming and mon nicknames exactly as they were.
--
-- Every glyph here survives Wire.text's sanitiser, so nothing can be typed
-- that the receiving end would silently strip.
local LETTERS = {
  { "A", "B", "C", "D", "E", "F", "G", "H", "I" },
  { "J", "K", "L", "M", "N", "O", "P", "Q", "R" },
  { "S", "T", "U", "V", "W", "X", "Y", "Z", " " },
  { "-", "?", "!", ",", ".", ":", ";", "/", "ED" },
  { "123" },
}

local DIGITS = {
  { "1", "2", "3", "4", "5", "6", "7", "8", "9" },
  { "0", ".", ":", "-", "/", "(", ")", ";", "," },
  { "?", "!", " ", "ED" },
  { "ABC" },
}

-- titles of naming screens this mod owns; the grid hook matches on these
-- rather than on a flag, so a cancelled screen cannot leave the swap armed
-- for whatever opens next
local ownedTitles = {}

-- remembered cursor rows, so reopening a menu lands where you left it
local cursor = {}

local function ownTitle(title)
  ownedTitles[title] = true
  return title
end

-- ------- the typed line, kept on the screen
--
-- NamingScreen draws the line it is typing into as `maxLen` slots of 8px
-- starting at a fixed x=56 (src/ui/NamingScreen.lua) -- a layout sized for
-- the vanilla seven-character name, which ends at 112 on a 160-wide screen
-- and so never had to think about the right edge.
--
-- Every grid this mod opens is longer than seven. An address is 32, which
-- runs the line out to 312: a player typing "192.168.1.20:7788" watches the
-- port -- the half they most need to check -- disappear off the screen, and
-- what is left sits hard against the right side rather than centred. Chat
-- at 16 overflows too, and the 12 of a join code stops exactly on the edge.
--
-- So this mod repaints that one row on its own screens: as many slots as
-- fit between the margins, centred, and -- once what is typed is longer
-- than the window -- the *end* of it, because the characters just entered
-- are the ones being checked. Nothing else on the page moves. The title
-- sits at y=8 and the grid starts at y=48, so the 8px row at y=24 is the
-- mod's to paint over.
local SCREEN_W = 160
local FIELD_Y = 24
local SLOT_W = 8
local FIELD_MARGIN = 8
local FIELD_SLOTS = math.floor((SCREEN_W - FIELD_MARGIN * 2) / SLOT_W)

-- Pure, and exported, so the arithmetic that decides "does this fit" is
-- pinned by the suite rather than by looking at a screenshot.
function M.fieldLayout(maxLen, glyphs)
  maxLen = math.max(tonumber(maxLen) or 0, 0)
  glyphs = type(glyphs) == "table" and glyphs or {}
  local slots = math.min(maxLen, FIELD_SLOTS)
  -- nothing scrolls until it has to: the window holds the whole line while
  -- it fits, and its last `slots` characters once it does not
  local skip = math.max(#glyphs - slots, 0)
  local cells = {}
  for i = 1, slots do
    cells[i] = glyphs[skip + i] or "-"
  end
  return math.floor((SCREEN_W - slots * SLOT_W) / 2), cells
end

-- ------- marking the characters that came with the mod
--
-- The CHARACTER list is 36 names the ROM carries and two the mod brings, and
-- nothing on the row says which is which. A mark in the cursor's own column
-- is what "this row is different" looks like in this game -- the hollow
-- arrow `▷` the engine already draws on a chosen row, one glyph, no new art
-- and nothing shifted, so `MIDDLE AGED WOMAN` still starts where every other
-- label starts.
--
-- The mark yields on the row the cursor is actually on: they share a cell,
-- and two triangles stacked in it would read worse than one. What that costs
-- is small -- every *other* special row still carries its mark, so the list
-- still says how many there are and where they are.
--
-- The row geometry is the widget's (src/ui/ListMenu.lua:draw): an 8px cursor
-- column at x=8, labels from x=16, row `n` at y = 8 + n * 16. Copied rather
-- than asked for, because the widget exposes no seam for a per-row
-- decoration -- so if upstream ever moves a row, this moves with it.
--
-- The mark keeps the cursor column even now that the rows carry a portrait
-- (see below): the art sits in the 16px to the *right* of that column, so
-- the two decorations never share a pixel and a mod character on an
-- unselected row still says so.
local MARK_X = 8
local MARK_Y0 = 8
local MARK_H = 16
local LIST_ROWS = 7

-- Which visible rows get the mark, as { row, y } pairs.
--
-- Pure, and exported, for the same reason M.fieldLayout is: the rule is
-- "ours, and not the one under the cursor", it has to hold while the list
-- scrolls, and a headless suite has no graphics context to read it off a
-- frame with.
function M.markedRows(menu)
  local out = {}
  if type(menu) ~= "table" or type(menu.items) ~= "table" then return out end
  local scroll = tonumber(menu.scroll) or 0
  local rows = tonumber(menu.rows) or LIST_ROWS
  for row = 1, rows do
    local i = scroll + row
    local item = menu.items[i]
    if not item then break end
    if i ~= menu.index and Cast.owns(item.value) then
      out[#out + 1] = { row = row, y = MARK_Y0 + row * MARK_H }
    end
  end
  return out
end

-- Wraps a list menu's draw to stamp the mark. Same shape as namingScreen
-- below: if the widget is not what this expects, the list still works and
-- the characters are merely unmarked.
local function markOwnCharacters(menu)
  local baseDraw = menu and menu.draw
  if type(baseDraw) ~= "function" then
    mod.log:warn("the character list is not the shape this mod marks, so the "
      .. "characters it adds will be listed without their mark -- update the "
      .. "mod for this engine build")
    return menu
  end

  menu.draw = function(self, ...)
    local out = baseDraw(self, ...)
    local Font, Theme = mod.ui.Font, mod.ui.Theme
    if not (Font and Font.drawCode and Theme and Theme.cursorHollow) then
      return out
    end
    -- the widget signs off in white, and the mark is the same black the
    -- labels are drawn in
    love.graphics.setColor(0, 0, 0, 1)
    for _, mark in ipairs(M.markedRows(self)) do
      Font.drawCode(Theme.cursorHollow, MARK_X, mark.y)
    end
    love.graphics.setColor(1, 1, 1, 1)
    return out
  end

  return menu
end

-- ------- showing each character on its own row
--
-- A list of 38 names asks the player to know what a MIDDLE AGED WOMAN or a
-- SILPH WORKER F looks like before choosing to be one. The picture is the
-- answer, and it is the same front-facing frame the trainer card and the
-- leaderboard already draw -- Chars.portrait owns the loading and the cache
-- for exactly this reason, so a third caller costs no second copy of a sheet.
--
-- Where it goes is decided by the widget. ListMenu draws every label at a
-- hardcoded x=16 and offers no offset (src/ui/ListMenu.lua:draw), so the only
-- way to open a gutter is to indent the label itself: two spaces are 16px,
-- which is exactly one portrait wide. The art then lands between the cursor
-- column and the name, and the gutter is the same width on every row whether
-- or not there is art to put in it -- a row that lost its picture must not
-- also lose its alignment.
--
-- What that costs is the widest name. From x=16 the row held eighteen glyphs
-- (16 + 18 * 8 = 160, the screen exactly); from x=32 it holds sixteen, and
-- the catalog's longest wearable label is MIDDLE AGED WOMAN at seventeen --
-- the same name the trainer card had to lay out around. It is trimmed to fit
-- rather than drawn past the edge, which is the trade the leaderboard's name
-- column already makes (M.nameRoom), and it is a trade the picture pays for:
-- the row that loses a glyph is a row that gained a face.
local PREVIEW_X = 16                    -- the gutter, right of the cursor
local PREVIEW_INDENT = "  "             -- two glyphs = 16px = the gutter
-- Where the widget itself starts a label: ListMenu:draw calls
-- Font.draw(item.label, 16, y) with the x hardcoded and no offset to pass
-- (src/ui/ListMenu.lua:draw). It is a fact about the widget rather than a
-- choice of ours, and it equals PREVIEW_X only by coincidence -- so how much
-- room a name has left is measured from here, not from where the art lands.
local LIST_LABEL_X = 16
-- The label is an 8px glyph drawn at the row's y and the art is 16px tall,
-- so the art is lifted 4px to put the two on the same middle line -- the
-- same centring the leaderboard does from the other side (RANK_TEXT_DY).
local PREVIEW_DY = -4
local PREVIEW_LABEL_MAX =
  math.floor((SCREEN_W - LIST_LABEL_X - #PREVIEW_INDENT * SLOT_W) / SLOT_W)

-- A character's row label: indented past the gutter, and never wider than
-- what is left of the row.
local function previewLabel(id)
  return PREVIEW_INDENT .. Chars.label(id):sub(1, PREVIEW_LABEL_MAX)
end

-- Which visible rows get a portrait, as { row, y, id } triples.
--
-- Pure, and exported, for the same reason M.markedRows is: the rule has to
-- hold while the list scrolls, and a headless suite has no graphics context
-- to read it off a frame with. It answers for every visible row that names a
-- character, including the one under the cursor -- a portrait is what the row
-- *is*, not a marker on it -- and leaves "is there art for this id" to the
-- wrap below, which is the only side that can load an image.
function M.previewRows(menu)
  local out = {}
  if type(menu) ~= "table" or type(menu.items) ~= "table" then return out end
  local scroll = tonumber(menu.scroll) or 0
  local rows = tonumber(menu.rows) or LIST_ROWS
  for row = 1, rows do
    local i = scroll + row
    local item = menu.items[i]
    if not item then break end
    if type(item.value) == "string" then
      out[#out + 1] = { row = row, y = MARK_Y0 + row * MARK_H, id = item.value }
    end
  end
  return out
end

-- Wraps a list menu's draw to fill the gutter. A second wrap rather than one
-- merged with markOwnCharacters above, because the two decorations are
-- independent -- different column, different rule for which rows get one --
-- and stacking them keeps each rule readable and separately testable.
--
-- A character with no art draws nothing and says nothing: the sheet is
-- missing for a whole class of reason the player already knows about (no ROM
-- imported yet), it is left out of the table below so nothing retries it, and
-- a warning on a draw path would repeat sixty times a second.
--
-- Which art each row gets is settled here, once, rather than per row per
-- frame. The list a picker is built with never changes for as long as the
-- screen is open, and while Chars.portrait caches the sheet it loads, asking
-- it again still costs a registry lookup wrapped in a closure and a pcall --
-- seven of those every frame for an answer that cannot have changed. What the
-- draw keeps is one table index.
local function previewCharacters(menu)
  local baseDraw = menu and menu.draw
  if type(baseDraw) ~= "function" then
    mod.log:warn("the character list is not the shape this mod draws "
      .. "portraits on, so the characters will be listed by name only -- "
      .. "update the mod for this engine build")
    return menu
  end

  -- id -> the { image, quad } Chars.portrait hands back. An id with no art is
  -- simply absent, which is the same miss the draw tested for before.
  local art = {}
  if type(menu.items) == "table" then
    for _, item in ipairs(menu.items) do
      local id = type(item) == "table" and item.value or nil
      if type(id) == "string" and art[id] == nil then
        art[id] = Chars.portrait(id)
      end
    end
  end

  menu.draw = function(self, ...)
    local out = baseDraw(self, ...)
    -- sprite art is drawn untinted, and the widget signs off in white
    -- anyway; set it explicitly so a caller's colour cannot stain a portrait
    love.graphics.setColor(1, 1, 1, 1)
    for _, preview in ipairs(M.previewRows(self)) do
      local pic = art[preview.id]
      if pic then
        love.graphics.draw(pic.image, pic.quad, PREVIEW_X,
                           preview.y + PREVIEW_DY)
      end
    end
    love.graphics.setColor(1, 1, 1, 1)
    return out
  end

  return menu
end

-- Every naming grid this mod opens, built here rather than at each call
-- site so a screen added later cannot quietly get the off-screen version.
local function namingScreen(game, opts)
  local screen = mod.ui.NamingScreen.new(game, opts)
  local baseDraw = screen.draw
  if type(baseDraw) ~= "function" then
    mod.log:warn("the naming screen is not the shape this mod wraps, so a "
      .. "long address may run off the right edge -- update the mod for "
      .. "this engine build")
    return screen
  end

  screen.draw = function(self, ...)
    local out = baseDraw(self, ...)
    local Font = mod.ui.Font
    if not (Font and Font.draw) then return out end
    local x, cells = M.fieldLayout(self.maxLen, self.glyphs)
    -- the widget paints its page white, so painting the row it drew back to
    -- white is what erases it; then the same black the rest of the page uses
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 0, FIELD_Y, SCREEN_W, SLOT_W)
    love.graphics.setColor(0, 0, 0, 1)
    for i = 1, #cells do
      Font.draw(cells[i], x + (i - 1) * SLOT_W, FIELD_Y)
    end
    love.graphics.setColor(1, 1, 1, 1)
    return out
  end

  return screen
end

-- A trainer card, for somebody else or for you.
--
-- The engine's own TrainerCard reads the local save, so it cannot be
-- pointed at a remote player; this draws the same fields from what they
-- sent when they joined. It is a plain state rather than a widget because
-- there is no widget for "a page of text with a border".
--
-- Your own card is the same screen with the same fields, so that what you
-- check before showing yourself off is literally what everybody else sees.
-- The one addition is MONEY, which is on the vanilla trainer card and is
-- never sent (Wire.profile drops it), so a card carrying money can only be
-- the local one -- see Client.ownCard.
local Card = {}
Card.__index = Card
Card.isOpaque = true

-- The character's own portrait, taken from the overworld sheet.
--
-- Where a full-width row runs out. The text column starts at x=16 and the
-- right border begins at 152, so 17 glyphs is a row -- and anything drawn
-- right-aligned is placed off this rather than off a guess.
local CARD_RIGHT = 152

-- Chars.portrait owns the loading and the cache, because the town map draws
-- the same front-facing pose at a party member's city and a second copy
-- would mean a second copy of every sheet -- on a path that draws each
-- frame.  The reasoning for why it is the overworld sheet and not a battle
-- pic lives there with it.
local portrait = Chars.portrait

function Card.new(game, player, onCancel)
  return setmetatable({ game = game, player = player, onCancel = onCancel }, Card)
end

function Card:update()
  local input = self.game.input
  if input:wasPressed("b") or input:wasPressed("a") then
    self.game.stack:pop()
    if self.onCancel then self.onCancel() end
  end
end

function Card:draw()
  local Font = mod.ui.Font
  if not (Font and Font.draw) then return end
  local p = self.player
  -- Full-height box, rows on a 16px grid from y=24. At 17 tiles the last
  -- row landed on the border and the dex line was cut in half.
  Font.drawBox(0, 0, 20, 18)
  Font.draw("TRAINER CARD", 24, 8)

  -- Why the rows are in this order, and the portrait is where it is.
  --
  -- Glyphs are 8px and the text column starts at x=16, so a full-width row
  -- holds 17 characters before it reaches the right border -- but a row
  -- level with the portrait (x=116..148) holds only 12. That makes "which
  -- rows may sit beside the art" a width question, not a taste one, and
  -- both of the rows that used to be there fail it: NAME is Config.NAME_MAX
  -- (10) plus "NAME/", and a character label runs to 17 ("MIDDLE AGED
  -- WOMAN"). That is how LOOK/COOLTRAINER M came to be drawn straight
  -- through the portrait.
  --
  -- IDNo and TIME are the only two rows whose width is bounded by their
  -- own format string -- 10 and 11 characters, whatever the values -- so
  -- the portrait sits beside those instead, and everything that varies
  -- with a player's choices gets the whole row.
  Font.draw(("NAME/%s"):format(tostring(p.name or "?")), 16, 24)

  -- The character, on its own row and with no "LOOK/" in front of it.
  -- The longest label in the catalog is exactly 17 characters -- the whole
  -- row -- so there is no prefix that fits every case, and one that appears
  -- only on short names would make the card change shape per character.
  -- Sat directly under the trainer's own name it reads the way the original
  -- prints a class before a name: ALPHA, a COOLTRAINER M.
  Font.draw(Chars.label(p.sprite or ""), 16, 40)

  -- Portrait on the right, level with the two fixed-width rows below.
  --
  -- y=52 and not 56, which is where it sat until the badge row grew a score.
  -- The art is 16px drawn at 2x, so from 56 its last row is y=87 and the row
  -- beneath it starts at y=88: no overlap, and no gap either, so the
  -- character's feet stood on the tops of the letters and read as a bug.
  -- Four pixels up buys 4px of air both above and below -- the character
  -- label above ends at y=48 -- and it centres the art better against the
  -- two rows it belongs to (56..80 has its middle at 68; so does 52..84).
  local art = portrait(p.sprite)
  if art then
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(art.image, art.quad, 116, 52, 0, 2, 2)
  end

  -- money is local-only, so it is also what tells the two cards apart
  local own = p.money ~= nil

  local card = p.profile
  if not card then
    -- An older build sends no card. Say so, rather than draw zeros that
    -- read as "this trainer has nothing".
    --
    -- Below the portrait, not beside it: the rows this message would
    -- otherwise use are the ones the art now occupies. "OLDER THAN YOURS."
    -- is 17 characters, which is the full row exactly.
    if own then
      -- Not reachable from the menu, which needs a running game to open --
      -- but a card with no save behind it must not accuse your own build
      -- of being out of date.
      Font.draw("NO SAVE LOADED.", 16, 88)
      return
    end
    Font.draw("NO CARD SENT.", 16, 88)
    Font.draw("THEIR BUILD IS", 16, 104)
    Font.draw("OLDER THAN YOURS.", 16, 120)
    return
  end

  -- The shared rows sit at the same y on both cards, so the one you check
  -- before showing yourself off is the one everybody else is reading.
  --
  -- These two are the fixed-width pair the portrait sits beside: "IDNo/"
  -- plus %05d is always 10, and %3d:%02d is always 11 because playtime is
  -- capped at 999 hours on the way in (Wire.profile).
  Font.draw(("IDNo/%05d"):format(card.idNo or 0), 16, 56)
  Font.draw(("TIME/%3d:%02d"):format(
    math.floor((card.playtime or 0) / 3600),
    math.floor(((card.playtime or 0) % 3600) / 60)), 16, 72)

  -- Back to the full width, below the art.
  --
  -- No money row on somebody else's: their wallet is not information this
  -- card is for, and it is not sent either -- transmitting a value nothing
  -- displays would be exposure for nothing.
  Font.draw(("BADGES/%d"):format(card.badges or 0), 16, 88)

  -- Ranked points share the badge row, right-aligned against the border.
  --
  -- There is no eighth row to give them: the box holds seven at the 16px
  -- spacing the rest of the card uses, and all seven were spoken for. The
  -- badge count is the one that leaves most of its row empty -- "BADGES/8"
  -- is eight glyphs of the seventeen -- so the score goes in the space it
  -- was already not using, and right-aligned means a four-figure rating
  -- grows towards the badges rather than through the border. It is on both
  -- cards at the same height, like every other shared row: what you check
  -- here is what everybody else is reading about you.
  --
  -- Points ride on presence, not on the card (Wire.presence), so this is the
  -- live number and not a snapshot of whoever joined an hour ago.
  local rank = ("RANK/%d"):format(p.points or 0)
  Font.draw(rank, CARD_RIGHT - 8 * #rank, 88)
  Font.draw(("SEEN/%d OWN/%d"):format(card.seen or 0, card.owned or 0), 16, 104)
  if own then
    -- last row of the 18-tile box: y=120 leaves the bottom border clear,
    -- the way the dex line does at 104
    Font.draw(("MONEY/¥%d"):format(p.money), 16, 120)
  end
end

-- ------- the leaderboard
--
-- `[position] [character] [name] [points]`, best first, the top ten as the
-- hub ranked them.
--
-- A hand-drawn state rather than a ListMenu, for one reason: the character
-- belongs in the row. A list row is a line of text, and a character *label*
-- does not fit beside a name and a score -- "MIDDLE AGED WOMAN" is seventeen
-- glyphs, the whole row on its own -- so the row shows the portrait instead,
-- the same front-facing frame the trainer card uses. That costs the row its
-- height: sixteen pixels of art means six rows on screen where text would
-- have given twelve, so the list scrolls with up and down.
--
-- Nothing here decides who is on the board. The hub sends ten rows already
-- sorted and already filtered to players with points, because it is the only
-- side that knows the ratings of players who are not online.
local Ranks = {}
Ranks.__index = Ranks
Ranks.isOpaque = true

-- The row, left to right, and why the gaps are where they are.
--
-- The box's interior is 8..152, which is eighteen glyphs. The four columns
-- want two (a place, up to "10"), two (the portrait, 16px), ten (a name at
-- Config.NAME_MAX) and four (a score at Config.RANK_MAX) -- exactly
-- eighteen, with nothing left for air. Packed that tightly the art touched
-- both its neighbours and read as a rendering fault rather than a layout.
--
-- So every column is given its air and the *name* pays for it, and only when
-- it has to: `nameRoom` works out how many glyphs are left before the score
-- and trims to fit. The budget works out at 16 + 2 + 16 + 2 + 80 + 4 + 24 =
-- 144, which is the row exactly -- so a full ten-character name and a
-- three-figure rating both fit whole, and only a four-figure one costs a
-- long name its last glyph.
local RANK_ROWS = 6        -- rows visible at once
local RANK_FIRST_Y = 24    -- the top one, under the title
local RANK_ROW_H = 16      -- one portrait tall
local RANK_POS_X = 8       -- "10", right up against the left border
local RANK_ART_X = 26      -- 2px clear of the place
local RANK_NAME_X = 44     -- 2px clear of the art
local RANK_RIGHT = 152     -- where a right-aligned score ends
local RANK_GAP = 4         -- kept between the name and the score
local RANK_TEXT_DY = 4     -- text centred against a 16px portrait
local RANK_FOOT_Y = 120

-- Exported so the suite asserts against the layout the screen actually
-- draws with, rather than a second copy of these numbers that can drift.
M.RANK_LAYOUT = {
  posX = RANK_POS_X, artX = RANK_ART_X, nameX = RANK_NAME_X,
  right = RANK_RIGHT, gap = RANK_GAP, rows = RANK_ROWS,
}

-- How much of a name fits before the score does, in glyphs.  Pure, so the
-- arithmetic that decides "does this fit" is pinned by the suite rather than
-- by looking at a screenshot -- the same reason M.fieldLayout is.
function M.nameRoom(points)
  local width = 8 * #tostring(points or 0)
  return math.max(math.floor(
    (RANK_RIGHT - width - RANK_GAP - RANK_NAME_X) / 8), 1)
end

function Ranks.new(game, client, onCancel)
  -- Asked for on the way in rather than pushed by the hub: the board moves
  -- on every battle anybody fights, and nobody is looking at it most of the
  -- time. The screen draws from the client's copy every frame, so the answer
  -- appears when it lands without anything having to wait for it.
  client:requestRanking()
  return setmetatable({
    game = game, client = client, onCancel = onCancel, offset = 0,
  }, Ranks)
end

function Ranks:entries()
  local rows = self.client:ranking()
  return type(rows) == "table" and rows or {}
end

function Ranks:update()
  local input = self.game.input
  local rows = self:entries()
  local maxOffset = math.max(#rows - RANK_ROWS, 0)
  -- clamped every frame, not only on input: an answer that arrives while the
  -- screen is open can make the list shorter than where it is scrolled to
  if self.offset > maxOffset then self.offset = maxOffset end

  if input:wasPressed("down") then
    self.offset = math.min(self.offset + 1, maxOffset)
  elseif input:wasPressed("up") then
    self.offset = math.max(self.offset - 1, 0)
  elseif input:wasPressed("b") or input:wasPressed("a") then
    self.game.stack:pop()
    if self.onCancel then self.onCancel() end
  end
end

function Ranks:draw()
  local Font = mod.ui.Font
  if not (Font and Font.draw) then return end
  Font.drawBox(0, 0, 20, 18)
  Font.draw("RANK", 16, 8)

  local rows = self:entries()
  local _, asked, seen = self.client:ranking()
  if #rows == 0 then
    -- Three silences that are one empty list to anything counting rows, and
    -- three different things to a player: nothing was asked (there is no hub
    -- to ask), the answer has not come back yet, or it came back empty.
    -- Saying "nobody has won" while the request is still in flight would
    -- send somebody looking for a bug that is not there.
    if not asked then
      Font.draw("NOT IN A GAME.", 16, 48)
      Font.draw("JOIN ONE FIRST.", 16, 64)
    elseif not self.client:isRanked() then
      -- The name this player joined under belongs to somebody else's copy on
      -- this hub, so their battles will not score. Said here, with the whole
      -- page to say it in, and with the thing to do about it -- a zero on a
      -- card cannot explain itself.
      Font.draw("THAT NAME IS TAKEN", 16, 48)
      Font.draw("ON THIS HUB, SO NO", 16, 64)
      Font.draw("BATTLES WILL SCORE.", 16, 80)
      Font.draw("PICK ANOTHER NAME.", 16, 96)
    elseif not seen then
      Font.draw("ASKING THE HUB...", 16, 48)
    else
      Font.draw("NOBODY HAS WON", 16, 48)
      Font.draw("A BATTLE HERE YET.", 16, 64)
    end
    return
  end

  local last = math.min(self.offset + RANK_ROWS, #rows)
  for slot = 1, last - self.offset do
    local place = self.offset + slot
    local row = rows[place]
    local y = RANK_FIRST_Y + (slot - 1) * RANK_ROW_H

    -- %2d so the ones and the tens line up under each other, the way the
    -- original right-aligns a quantity
    Font.draw(("%2d"):format(place), RANK_POS_X, y + RANK_TEXT_DY)

    local art = portrait(row.sprite)
    if art then
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.draw(art.image, art.quad, RANK_ART_X, y)
    end

    local points = tostring(row.points or 0)
    local name = tostring(row.name):sub(1, M.nameRoom(points))
    Font.draw(name, RANK_NAME_X, y + RANK_TEXT_DY)
    Font.draw(points, RANK_RIGHT - 8 * #points, y + RANK_TEXT_DY)
  end

  -- Only when there is something off-screen, and it says *which* part of the
  -- list is on screen rather than only that there is more: an arrow alone
  -- does not tell a player whether they are looking at the top ten or the
  -- bottom of it.
  -- One footer row, and being unranked wins it: which slice of the list is on
  -- screen is a nicety, and "nothing you do here counts" is not.
  if not self.client:isRanked() then
    Font.draw("NOT RANKED HERE.", 16, RANK_FOOT_Y)
  elseif #rows > RANK_ROWS then
    Font.draw(("%d-%d OF %d"):format(self.offset + 1, last, #rows),
              16, RANK_FOOT_Y)
  end
end

-- ------- where the people on the roster are
--
-- The roster row is a ListMenu row, so the geometry is the widget's
-- (src/ui/ListMenu.lua:draw): the label starts at x=16 and `right` is
-- right-aligned to end at 152.  The two share one 160-wide row, which on a
-- 20-tile screen leaves no room for both a full name and a full place name
-- -- ten glyphs of "KRABBYMAN" plus eleven of "PALLET TOWN" is half a
-- screen more than there is.
--
-- The name never pays.  It is what the player reads the row by and what
-- they press A on, so the place takes whatever is left over once the name
-- and a glyph of air have had theirs -- the opposite of the RANK row, where
-- the score is fixed-width and the name trims to it.  A name at
-- Config.NAME_MAX still leaves six glyphs, which is the PALLET of PALLET
-- TOWN; the short names most players pick leave the place whole.
local ROSTER_LABEL_X = 16   -- where ListMenu starts a label
local ROSTER_RIGHT = 152    -- where a right-aligned column ends
local ROSTER_GAP = 8        -- one glyph of air between the two
local ROSTER_PLACE_MIN = 3  -- below this a place name is not a name

-- Exported, like M.RANK_LAYOUT, so the suite asserts against the numbers
-- the screen actually draws with instead of a second copy of them.
M.ROSTER_LAYOUT = {
  labelX = ROSTER_LABEL_X, right = ROSTER_RIGHT,
  gap = ROSTER_GAP, min = ROSTER_PLACE_MIN,
}

-- How much of a place name fits beside a name, in glyphs.  Pure, for the
-- same reason M.nameRoom is: a headless suite has no frame to read the
-- answer off.
function M.placeRoom(name)
  local width = 8 * #tostring(name or "")
  return math.max(math.floor(
    (ROSTER_RIGHT - ROSTER_LABEL_X - width - ROSTER_GAP) / 8), 0)
end

-- Cut to that many glyphs, never bytes.  A name has been through Wire's
-- sanitiser and is ASCII by construction, but a place name has not been
-- through anything -- it comes from the player's own decoded data, where
-- the font's charmap can hand back a multi-byte glyph -- and a cut that
-- lands inside one hands the renderer a broken sequence.  Font.split is the
-- renderer's own multi-byte-aware pass, the same seam src/Overlay.lua clips
-- on; the byte path stays for a build without it.
local function clipPlace(text, room)
  local cut
  local Font = mod.ui and mod.ui.Font
  if type(Font) == "table" and type(Font.split) == "function" then
    local ok, spans = pcall(Font.split, text)
    if ok and type(spans) == "table" then
      if #spans <= room then return text end
      local last = spans[room]
      cut = text:sub(1, (last and last.to) or room)
    end
  end
  if not cut then
    if #text <= room then return text end
    cut = text:sub(1, room)
  end
  -- A cut that lands on a space -- the "PALLET " of PALLET TOWN -- would sit
  -- a glyph left of the right edge once ListMenu right-aligns it, out of
  -- line with the PARTY and BUSY rows above, and the space says nothing.
  return (cut:gsub("%s+$", ""))
end

-- The right-hand column for a player who is neither in your party nor busy:
-- where they are, trimmed to the room their name left.
local function placeColumn(game, player)
  local place = Places.name(game, player.map)
  if not place then return nil end
  local room = M.placeRoom(player.name)
  if room < ROSTER_PLACE_MIN then return nil end
  return clipPlace(place, room)
end

function M.new(ctx)
  -- ctx is filled in by Client once every part exists; holding the table
  -- rather than its fields is what lets Ui be built before Sessions
  return setmetatable({ ctx = ctx }, M)
end

-- ------- primitives other modules call

-- Returns the box it pushed, which is a screen on the engine's stack and so
-- something a caller can take back down again. Coop is the one that needs it:
-- its "Asked NAME for a 2-on-2 battle." dismisses itself when the player
-- presses A, and a player who does not press A is holding it when the battle
-- screen goes up on top of it.
function M:say(text, onDone)
  local game = self.ctx.game
  if not game then return nil end
  return mod.ui.push(game, SCREEN.TEXT, { text = text, onDone = onDone })
end

-- opts.defaultNo opens the box with the cursor on NO.
--
-- The engine's ChoiceBox starts on YES unless it is told otherwise, which is
-- right for a question whose yes is what the player just asked for -- a trade,
-- a team-up -- and wrong for one whose yes cannot be undone. Passed through
-- rather than decided here, and absent by default, so every existing caller
-- keeps the box it already had.
function M:confirm(game, text, onChoose, opts)
  game = game or self.ctx.game
  if not game then return nil end
  -- Returned so a caller can take the box back down -- Sessions holds the
  -- battle-invite prompt the same way Coop holds its ask box, and cancels
  -- or a peer going offline have to dismiss it rather than leave it buried.
  return mod.ui.push(game, SCREEN.CONFIRM, {
    text = text,
    onChoose = onChoose,
    defaultNo = opts and opts.defaultNo,
  })
end

-- A question with named answers, where **B is an answer and not an escape**.
--
-- CONFIRM is the yes/no box, and its B is a no that returns the player to
-- whatever they came from.  That is exactly wrong for a fight that has already
-- been triggered: the engine has committed to the encounter by the time the
-- mod is asked, so a prompt that could be backed out of would be a prompt that
-- skipped a trainer.  Here B selects the **last row** instead -- which the
-- callers order so that the last row is the one that costs the player nothing
-- they had not already accepted (BATTLE ALONE, or reopening the choice).
--
-- The rows are a Menu, not a TextBox choice, because there can be more than
-- two of them and because they are commands rather than an answer to a
-- sentence -- the same widget the ACTIONS box uses, for the same reason.
-- Which row B selects.  A named function with no widget in it, so the rule
-- can be asserted directly rather than only through a screen the headless
-- suite would have to build a game to construct -- and so there is exactly one
-- statement of it for the screen and the suite to share.
function M.cancelRow(items)
  if type(items) ~= "table" or #items == 0 then return nil end
  return items[#items]
end

function M:choose(game, text, items)
  game = game or self.ctx.game
  if not (game and items and #items > 0) then return nil end
  -- Returned for the same reason confirm is: a waiting box has to be
  -- dismissible from outside when the answer arrives (or the ask is
  -- cancelled) rather than only when the player presses a row.
  return mod.ui.push(game, SCREEN.CHOOSE, { text = text, items = items })
end

function M:pushState(game, state)
  game = game or self.ctx.game
  if not (game and state) then return end
  mod.ui.push(game, SCREEN.STATE, { state = state })
end

function M:pickPartyMon(game, trade, onPick)
  game = game or self.ctx.game
  if not game then return end
  mod.ui.push(game, SCREEN.PICK, { trade = trade, onPick = onPick })
end

-- ------- registration

function M:install()
  local ctx = self.ctx
  local screens = mod.content.screens

  -- Give this mod's naming screens a digits page.  Scoped by title: any
  -- screen the mod did not open -- naming your rival, nicknaming a mon --
  -- falls straight through to next() and keeps the vanilla grid.
  mod.hooks:wrap("ui.naming.grid", function(next, grid, ctxInfo)
    local out = next(grid, ctxInfo)
    if type(ctxInfo) ~= "table" or not ownedTitles[ctxInfo.title] then
      return out
    end
    -- SELECT flips between the two pages, so "lower" becomes "digits"
    return ctxInfo.lower and DIGITS or LETTERS
  end)

  -- The mod manager opens its own naming screen for a text option and
  -- titles it "<LABEL>?", which is a title this mod never pushes and so
  -- would fall through to the vanilla grid -- the one with no digits on it.
  -- A join code is half digits, so the JOIN CODE option row would be
  -- untypeable there. Claiming that title too is the whole fix.
  ownTitle("JOIN CODE?")

  -- Six characters fit anywhere a code is shown -- a text box is 18 columns
  -- and a list row's right column holds eight -- so there is no splitting
  -- left to do and this is Wire.formatCode with a safe answer for nil.  It
  -- stays a named seam because every screen that shows a code goes through
  -- it: the host reading it out and the guest typing it in are looking at
  -- the same thing, and if a display form ever comes back it comes back
  -- here.
  local function codeText(code)
    return Wire.formatCode(code) or ""
  end

  screens:register(SCREEN.TEXT, { new = function(game, opts)
    opts = opts or {}
    return mod.ui.TextBox.new(game, opts.text or "", opts.onDone)
  end })

  screens:register(SCREEN.CONFIRM, { new = function(game, opts)
    opts = opts or {}
    -- TextBox pushes the yes/no box itself once the text finishes printing
    -- and calls opts.choice with the answer, which is the vanilla prompt
    -- rhythm rather than two boxes appearing at once
    return mod.ui.TextBox.new(game, opts.text or "", nil, {
      choice = function(yes)
        if opts.onChoose then opts.onChoose(yes and true or false) end
      end,
      -- Normalised to a boolean rather than forwarded as it came: the
      -- engine reads this field for truthiness, and a caller who handed in
      -- a string would be opting into a default they never asked for.
      defaultNo = opts.defaultNo == true,
    })
  end })

  screens:register(SCREEN.STATE, { new = function(_, opts)
    return opts and opts.state
  end })

  -- The unescapable choice.  See M:choose for why B is a row and not a way
  -- out; this is that decision, spelled.
  --
  -- The sentence is printed first and the box opens under it, which is the
  -- vanilla rhythm CONFIRM already follows -- a question and its answers
  -- appearing at the same instant reads as two screens fighting over the
  -- bottom of the display.
  screens:register(SCREEN.CHOOSE, { new = function(game, opts)
    opts = opts or {}
    local items = opts.items or {}
    return mod.ui.TextBox.new(game, opts.text or "", function()
      mod.ui.push(game, SCREEN.MENU_CHOOSE,
        { items = items, last = M.cancelRow(items) })
    end)
  end })

  -- The box itself, split out so CHOOSE can print its line before opening it.
  -- Registered rather than pushed as a bare widget for the reason the file
  -- header gives: mod.ui.push is the supported door, game.stack is not.
  screens:register(SCREEN.MENU_CHOOSE, { new = function(game, opts)
    opts = opts or {}
    local items = opts.items or {}
    local last = opts.last
    return mod.ui.Menu.new(game, items, {
      tx = 11, ty = math.max(0, math.min(7, 18 - (#items * 2 + 2))), tw = 9,
      -- B is the last row, run as though it had been selected. Not nil, and
      -- not a close: a co-op prompt with a working cancel is a trainer the
      -- player walked away from mid-encounter.
      onCancel = function()
        if last and last.onSelect then last.onSelect() end
      end,
    })
  end })

  -- ------- the hubs this copy has already been on
  --
  -- The list itself lives in src/Servers.lua and is handed over on the ctx.
  -- Every screen here reaches it through these two rather than through
  -- ctx.servers directly, so a Client that predates the store -- an older
  -- build, or a suite that builds a ctx with only the parts it is testing --
  -- gets a menu with nothing on it instead of a screen that throws on the
  -- way up. The list comes back already sorted (favourites first, then by
  -- address); nothing here re-orders it.
  local function serverStore()
    local store = ctx.servers
    if type(store) ~= "table" then return nil end
    return store
  end

  local function serverMenuList()
    local store = serverStore()
    local list
    if store then
      if store.menuList then
        list = store:menuList()
      elseif store.list then
        list = store:list()
      end
    end
    return type(list) == "table" and list or {}
  end

  local function serverMenuGet(key)
    local store = serverStore()
    if not store then return nil end
    if store.menuGet then return store:menuGet(key) end
    if store.get then return store:get(key) end
    return nil
  end

  -- The mark on a favourite row.
  --
  -- Not the "*" a list like this would carry anywhere else: the extracted
  -- font has no glyph for it, and Font.draw silently draws nothing while
  -- Font.width still advances 8px -- the same trap the CHAT row fell into
  -- (see its note below). "▶" is on the sheet, right-aligned in the row's
  -- own second column, so a pinned server actually shows that it is one.
  --
  -- The trailing space is load-bearing, not a typo: ListMenu right-aligns
  -- the second column at 160 - 8 - width, and a name at the 16-glyph cap
  -- ends exactly where a one-glyph mark starts, so the two touch. The space
  -- is drawn as nothing and widens the column by one 8px cell, which shifts
  -- the arrow one cell left and leaves the gap a full-length name needs.
  local FAV_MARK = "▶ "

  -- ------- the main MMO menu

  -- The MMO menu is a START submenu, so it looks like one: a bordered box
  -- in the same corner, double-spaced rows, the blinking arrow, and B
  -- returning to START rather than dumping you into the world. Menu (not
  -- ListMenu) is the widget for that -- ListMenu is the full-screen
  -- inventory list the bag and the PC use, which is why this screen used to
  -- take over the whole display for four short commands.
  screens:register(SCREEN.MAIN, { new = function(game)
    local client = ctx.client
    local items = {}
    local hosting = client:isHosting()
    local connected = client:isConnected()

    -- Each row is gated on what it actually needs, not on one blanket
    -- "connected" test. Hosting and being connected are separate states: a
    -- listener can be up while this copy's own client is not on it, and
    -- gating everything on connected left that host with no way to read out
    -- their address or stop hosting -- the menu offered to start a game
    -- they were already running.
    if connected or hosting then
      if hosting then
        items[#items + 1] = {
          label = "ADDRESS",
          onSelect = function() mod.ui.push(game, SCREEN.HOSTINFO) end,
        }
      end
      if connected then
        items[#items + 1] = {
          label = "PLAYERS",
          onSelect = function() mod.ui.push(game, SCREEN.ROSTER) end,
        }
        -- No unread marker on this row. It carried "*" first, which the
        -- extracted font has no glyph for -- Font.draw silently drew
        -- nothing while Font.width still advanced 8px, so "CHAT*" showed
        -- as CHAT plus a blank column that read as a layout bug. Moving it
        -- to a leading "▶" fixed the blank but bought a worse confusion:
        -- "▶" *is* the menu cursor glyph, so an unread CHAT row looked
        -- like a second cursor sitting on a row the cursor was not on.
        -- The label is plain now; unread is still counted on Chat for
        -- anything that wants it, it just no longer decorates this row.
        items[#items + 1] = {
          label = "CHAT",
          onSelect = function() mod.ui.push(game, SCREEN.CHATLOG) end,
        }
        items[#items + 1] = {
          label = "SAY",
          onSelect = function() mod.ui.push(game, SCREEN.SCOPE) end,
        }
        -- Its own row rather than a corner of PLAYERS: a party is a standing
        -- arrangement with its own chat, its own list and its own way out,
        -- and burying all three under the roster would make the one thing
        -- you check most often the thing you have to go looking for.
        items[#items + 1] = {
          label = "PARTY",
          onSelect = function() mod.ui.push(game, SCREEN.PARTY) end,
        }
        -- The other side of PLAYERS: that one shows you everybody else's
        -- card, and until now there was no way to see the one they are
        -- reading about you. Same screen, same rows -- so what you check
        -- here is what they see.
        --
        -- Last of the four, and after PARTY, because the rows read outwards
        -- to inwards: everybody on the hub, then talking to them, then the
        -- one person you are travelling with, then yourself.
        items[#items + 1] = {
          label = "MY PROFILE",
          onSelect = function()
            mod.ui.push(game, SCREEN.PROFILE, {
              own = true,
              onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
            })
          end,
        }
        -- Under MY PROFILE, because that is where the points on your own
        -- card send you next: the card says what you are worth, this says
        -- against whom.
        items[#items + 1] = {
          label = "RANK",
          onSelect = function()
            mod.ui.push(game, SCREEN.RANK, {
              onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
            })
          end,
        }
        -- The end of the same walk inwards: everybody on the hub, then
        -- talking to them, then the one person you travel with, then your
        -- own card and where it ranks -- and then the character wearing all
        -- of it, which is the most-yourself row there is. So it sits last,
        -- just before the way out.
        --
        -- Inside `connected` rather than beside LEAVE, so the
        -- hosting-but-not-connected state above keeps its two rows: the
        -- occupant of a copy that is only running a listener is not on the
        -- hub as a player, and has nobody to show a new face to.
        --
        -- Same door as the offline row, and the same call behind it: the
        -- picker saves the choice and wears it on the spot, and the client
        -- tells the hub, which passes it to everyone else's roster and
        -- avatars.
        items[#items + 1] = {
          label = "CHARACTER",
          onSelect = function()
            mod.ui.push(game, SCREEN.CHARPICK, { backTo = SCREEN.MAIN })
          end,
        }
      end
      items[#items + 1] = {
        label = hosting and "END GAME" or "LEAVE",
        onSelect = function()
          -- Leaving someone else's game just disconnects: the save, the
          -- world and the party are untouched, so play carries straight on
          -- single-player. Ending a game you host is destructive for
          -- everyone else, so that one asks first.
          if not hosting then
            client:leave()
            return mod.ui.push(game, SCREEN.TEXT, {
              text = "You left.\nStill playing!",
            })
          end
          mod.ui.push(game, SCREEN.CONFIRM, {
            text = "End the game for\neveryone?",
            onChoose = function(yes)
              if not yes then return end
              client:leave()
              mod.ui.push(game, SCREEN.TEXT, { text = "The game ended." })
            end,
          })
        end,
      }
    else
      -- First on the menu, above HOST GAME, because it always has somewhere
      -- useful to go: the official server is a product-owned first row even
      -- on a new copy, and remembered hubs follow it with their address and
      -- code already filled in. Hosting and connected states stay in the
      -- branch above, where SERVERS is intentionally absent.
      items[#items + 1] = {
        label = "SERVERS",
        onSelect = function() mod.ui.push(game, SCREEN.SERVERS) end,
      }
      items[#items + 1] = {
        label = "HOST GAME",
        onSelect = function()
          mod.ui.push(game, SCREEN.CHARSET, {
            verb = "HOST",
            onReady = function() mod.ui.push(game, SCREEN.HOSTSET) end,
          })
        end,
      }
      items[#items + 1] = {
        label = "JOIN GAME",
        onSelect = function()
          mod.ui.push(game, SCREEN.CHARSET, {
            verb = "JOIN",
            onReady = function() mod.ui.push(game, SCREEN.JOINADDR) end,
          })
        end,
      }
      -- The third row is the character, and it is deliberately not the code.
      --
      -- JOIN GAME asks for the address and then the code, so a row called
      -- JOIN CODE sitting under it read as the other half of joining rather
      -- than as what it was -- somewhere to change a saved one without
      -- dialling. Two rows that both start a join, one of which does not, is
      -- a menu that has to be explained; the code that gets typed is now
      -- always the one on the way in, and the standing fallback is the JOIN
      -- CODE option row.
      --
      -- CHARACTER earns the row for the opposite reason: it starts nothing.
      -- Until now the picker could only be reached on the way into a game,
      -- through the TRAINER screen that HOST and JOIN both open, so "who am
      -- I" was a question a player could only answer while dialling somebody
      -- -- and answering it meant abandoning a setup flow they had already
      -- begun. The choice is saved and worn on the spot
      -- (Client.setSpriteChoice), so this row is where somebody not playing
      -- online today picks the character they will be tomorrow.
      --
      -- It belongs on the offline menu because you do not need a game to be
      -- yourself: the choice is saved and worn locally, so the row does its
      -- whole job with nothing connected and nobody to tell.
      --
      -- It is no longer the only door, though. The connected branch above
      -- carries the same row, because a change made mid-session now reaches
      -- the hub and everybody on it -- so these two are one option in two
      -- states, not an offline-only concession.
      items[#items + 1] = {
        label = "CHARACTER",
        onSelect = function()
          mod.ui.push(game, SCREEN.CHARPICK, { backTo = SCREEN.MAIN })
        end,
      }
    end

    local menu = mod.ui.Menu.new(game, items, {
      tx = 9, ty = 0, tw = 11,
      -- the same ceiling the START menu uses: (18 rows - 2 border) / 2
      maxVisible = 8,
      -- B goes back where it came from, like every vanilla submenu
      onCancel = function() mod.ui.push(game, "StartMenu") end,
    })
    -- the cursor survives closing the menu, as the original's does
    menu.index = math.min(cursor.main or 1, math.max(1, #items))
    menu:clampScroll()
    local baseUpdate = menu.update
    menu.update = function(self, dt)
      baseUpdate(self, dt)
      cursor.main = self.index
    end
    return menu
  end })

  -- ------- hosting: pick the limit, then start

  -- ------- character creation
  --
  -- Who you are online, asked before you host or join, rather than
  -- inheriting the save's trainer name and a sprite nobody chose. The name
  -- is separate from the save file's, so somebody can be ASH online without
  -- renaming their single-player game.
  --
  -- Asked here once, but only the name is settled here: the look half has a
  -- row of its own on the MMO menu, offline and connected alike, and a
  -- change made there is passed on to everyone already in the game. This
  -- screen is where both halves start, not where either of them ends.

  screens:register(SCREEN.CHARSET, { new = function(game, opts)
    opts = opts or {}
    local client = ctx.client
    local items = {
      { label = "NAME", right = client:playerName(game), key = "name" },
      { label = "LOOK", right = Chars.label(client:spriteChoice()), key = "look" },
      { label = opts.verb or "READY", key = "go" },
    }
    return mod.ui.ListMenu.new(game, "TRAINER", items, {
      onChoose = function(item, menu)
        menu:close()
        if item.key == "name" then
          mod.ui.push(game, SCREEN.COMPOSE,
            { scope = "name", back = SCREEN.CHARSET, backOpts = opts })
        elseif item.key == "look" then
          mod.ui.push(game, SCREEN.CHARPICK, { back = opts })
        elseif opts.onReady then
          opts.onReady()
        end
      end,
      onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
    })
  end })

  screens:register(SCREEN.CHARPICK, { new = function(game, opts)
    opts = opts or {}
    local client = ctx.client

    -- Where A and B go, which is wherever this was opened from.
    --
    -- The picker has two doors now. It is the middle of the TRAINER flow
    -- when a game is being started -- CHARSET pushes it and must get its own
    -- setup opts back, which is what `back` carries -- and it is the whole of
    -- it when the MMO menu's CHARACTER row opens it on its own. `backTo`
    -- names that second door by screen id; without it a player who only
    -- wanted to change character would be handed the host/join setup screen
    -- they never asked for. The old call site passes neither, so the default
    -- is the flow that was here first.
    local direct = type(opts.backTo) == "string"
    local backTo = direct and opts.backTo or SCREEN.CHARSET
    local backOpts = direct and {} or (opts.back or {})
    local function goBack() mod.ui.push(game, backTo, backOpts) end

    local current = client:spriteChoice()
    local items, start = {}, 1
    for i, id in ipairs(Chars.list()) do
      if id == current then start = i end
      -- previewLabel indents past the portrait gutter; the id itself stays
      -- in `value`, which is what both decorations and the choice read
      items[#items + 1] = { label = previewLabel(id), value = id }
    end
    local menu = mod.ui.ListMenu.new(game, "CHARACTER", items, {
      pageJump = true,
      onChoose = function(item, m)
        m:close()
        -- setSpriteChoice both records the choice and wears it, so there is
        -- nothing for this screen to apply -- and nothing here that could
        -- disagree with what the CHARSET flow does with the same call
        client:setSpriteChoice(item.value)
        goBack()
      end,
      onCancel = goBack,
    })
    menu.index = start
    return previewCharacters(markOwnCharacters(menu))
  end })

  -- ------- a trainer card: somebody else's, or your own

  -- One screen for both, because they are the same card. opts.own takes it
  -- from the local save instead of the roster -- which has no entry for you
  -- to look up, by design (Roster:isSelf).
  screens:register(SCREEN.PROFILE, { new = function(game, opts)
    opts = opts or {}
    -- Both sides of the merge added opts.own for the same reason -- the
    -- roster is everyone *but* you, so your own card has to be built rather
    -- than looked up -- and reached it from opposite ends: MY PROFILE on the
    -- menu, and the party members list, which lists both of you. One
    -- implementation, and it is main's early return: the branch version
    -- folded the two into a single expression, where an ownCard that came
    -- back nil would fall through to "They just went offline." about
    -- yourself.
    if opts.own then
      return Card.new(game, ctx.client:ownCard(game), opts.onCancel)
    end
    local player = ctx.roster:get(opts.playerId)
    if not player then
      return mod.ui.TextBox.new(game, "They just went\noffline.")
    end
    return Card.new(game, player, opts.onCancel)
  end })

  -- ------- the leaderboard

  screens:register(SCREEN.RANK, { new = function(game, opts)
    opts = opts or {}
    return Ranks.new(game, ctx.client, opts.onCancel)
  end })

  -- How many players, as a menu of sizes rather than a bare number box.
  --
  -- This was QuantityBox, the engine's *shop* quantity widget, which drew
  -- "x02" in a corner with nothing to say what it counted -- the player had
  -- no way to know they were choosing a room size. Named rows say it
  -- outright, and a bordered list is the shape the original uses for a
  -- choice like this anyway.
  local SIZES = { 2, 4, 8, 16, 32, 64 }

  -- What the game will be before it starts: how many people, and the code
  -- they will need to get in.
  --
  -- The code is not a setting any more, it is a requirement -- HostServer
  -- refuses to open the port without one -- so it is minted on the way in
  -- rather than offered as a choice a host could decline. The common path
  -- is therefore zero typing: the row already reads six characters the host
  -- can say out loud, and the screen behind it is only for changing them.
  -- Showing the code itself is what six characters bought; a list row's
  -- right column had no room for the old dashed form, which is why that row
  -- used to say ON and send the host somewhere else to find out what was.
  screens:register(SCREEN.HOSTSET, { new = function(game)
    local client = ctx.client
    local code = client:hostJoinCode()
    if not code then code = client:setHostJoinCode(client:newJoinCode()) end
    local items = {
      { label = "PLAYERS", right = tostring(client:maxPlayers()), key = "players" },
      -- "SET ONE" only when the pool could not mint one; the row still
      -- leads to the screen that fixes it, so the way out never moves
      { label = "JOIN CODE", right = code and codeText(code) or "SET ONE",
        key = "code" },
      { label = "START", key = "go" },
    }
    return mod.ui.ListMenu.new(game, "HOST", items, {
      onChoose = function(item, menu)
        menu:close()
        if item.key == "players" then
          mod.ui.push(game, SCREEN.HOSTSIZE)
        elseif item.key == "code" then
          mod.ui.push(game, SCREEN.HOSTCODE)
        elseif not code then
          -- client:host would surface HostServer's own refusal here, which
          -- is a sentence about a port; naming the row that fixes it is
          -- what the host can actually act on
          mod.ui.push(game, SCREEN.TEXT, {
            text = "Set a join code\nfirst -- players\nneed it to get in.",
            onDone = function() mod.ui.push(game, SCREEN.HOSTCODE) end,
          })
        elseif client:host(game) then
          -- and on failure client:host has already said why, in the same
          -- box every other refusal uses
          mod.ui.push(game, SCREEN.HOSTINFO)
        end
      end,
      onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
    })
  end })

  -- Changing the code, once there is one.
  --
  -- No "no code" row: a game with no code is one any stranger who can reach
  -- the port walks into, and the hub will not open a port without one, so
  -- the escape led nowhere but a refusal at START. Generating stays first
  -- because it is the answer nearly every host wants; typing is for a host
  -- who wants a code they chose, or one a friend already has.
  screens:register(SCREEN.HOSTCODE, { new = function(game)
    local client = ctx.client
    local items = {
      {
        label = "NEW CODE",
        onSelect = function()
          local code = client:setHostJoinCode(client:newJoinCode())
          if not code then
            -- newJoinCode already warned with a remediation; the player gets
            -- the short version and the other row still works
            return mod.ui.push(game, SCREEN.TEXT, {
              text = "Couldn't make a\ncode. Type one\ninstead.",
              onDone = function() mod.ui.push(game, SCREEN.HOSTCODE) end,
            })
          end
          mod.ui.push(game, SCREEN.TEXT, {
            text = ("Players will need:\n%s"):format(codeText(code)),
            onDone = function() mod.ui.push(game, SCREEN.HOSTSET) end,
          })
        end,
      },
      {
        label = "TYPE ONE",
        onSelect = function()
          mod.ui.push(game, SCREEN.JOINCODE, { host = true })
        end,
      },
    }
    return mod.ui.Menu.new(game, items, {
      tx = 8, ty = 0, tw = 12,
      onCancel = function() mod.ui.push(game, SCREEN.HOSTSET) end,
    })
  end })

  screens:register(SCREEN.HOSTSIZE, { new = function(game)
    local client = ctx.client
    local current = client:maxPlayers()

    local sizes = {}
    for _, n in ipairs(SIZES) do sizes[#sizes + 1] = n end
    -- a number set in the options pane is still reachable here, even if it
    -- is not one of the round ones
    local known = false
    for _, n in ipairs(sizes) do if n == current then known = true end end
    if not known then
      sizes[#sizes + 1] = current
      table.sort(sizes)
    end

    local items, start = {}, 1
    for i, n in ipairs(sizes) do
      if n == current then start = i end
      items[#items + 1] = {
        label = ("%d PLAYERS"):format(n),
        onSelect = function()
          client:setMaxPlayers(n)
          mod.ui.push(game, SCREEN.HOSTSET)
        end,
      }
    end

    local menu = mod.ui.Menu.new(game, items, {
      tx = 8, ty = 0, tw = 12, maxVisible = 8,
      onCancel = function() mod.ui.push(game, SCREEN.HOSTSET) end,
    })
    -- open on what is already configured, so confirming is one button
    menu.index = start
    menu:clampScroll()
    return menu
  end })

  screens:register(SCREEN.HOSTINFO, { new = function(game)
    local client = ctx.client
    if not client:isHosting() then
      return mod.ui.TextBox.new(game, "You aren't hosting.")
    end
    local address = client:hostAddress()
    -- The code belongs with the address, because they are read out in the
    -- same breath: a friend needs both to get in, and a host who set one and
    -- cannot find it again has a game nobody can join.
    local code = client:hostJoinCode()
    local codeRow = code and ("\nCODE: " .. codeText(code)) or ""
    -- Net.lanIP() answers nil when it cannot work out which interface faces
    -- the network, and "?:7788" tells a player nothing they can act on.
    -- Name the port instead -- it is the half they need to forward anyway.
    if type(address) ~= "string" or address:find("^%?") then
      return mod.ui.TextBox.new(game, ("Hosting on port %d.\nYour IP is "
        .. "hidden -- check\nyour network settings.%s")
        :format(Config.DEFAULT_PORT, codeRow))
    end
    return mod.ui.TextBox.new(game,
      ("Tell your friends:\n%s%s"):format(address, codeRow))
  end })

  -- ------- joining: where, then the code, then dial
  --
  -- Both halves are asked before a socket is opened. They used to be split
  -- across the connection -- address, dial, and then the hub's challenge
  -- pushing a code screen over a handshake that was already spending its
  -- ten-second budget. Asking for what a player has been told anyway (an
  -- address and a code, said in one breath) is one straight line, and the
  -- challenge path below survives as what a mistyped code lands on.

  -- ------- the way out of a naming grid
  --
  -- NamingScreen (src/ui/NamingScreen.lua) pops only from confirm(): it
  -- takes no onCancel, and its B is the backspace. That was survivable while
  -- the code screen appeared only over a live handshake; it is not now that
  -- JOIN GAME asks for the address and then the code on the way in. A player
  -- who opens either without the answer to hand was stuck on it, with no way
  -- back to the overworld short of quitting the game.
  --
  -- So B on an empty line leaves. B with nothing to erase is a press that
  -- already does nothing, so no typing is taken away to buy it, and backing
  -- out with B is what every other screen here does -- it is the button
  -- somebody stuck reaches for. What is on the line is the whole test: one
  -- glyph and B is an eraser again, so a mistyped code is fixed where it was
  -- made instead of being read as "gave up" and thrown back to the menu.
  --
  -- `emptyConfirm` reads START and the ED cell the same way. True for the
  -- code grid, where an empty line has never carried an answer: there is
  -- deliberately no `default` there, so confirm() submits the widget's own
  -- "A", which is refused, which puts the grid straight back -- the loop
  -- this fixes. False for the address grid, where an empty line means "the
  -- hub I already have" and START is how that is accepted.
  --
  -- Nothing here touches game.stack. The escape leaves by the widget's own
  -- confirm(), which pops itself and then calls onDone, so answering
  -- somewhere else is only a question of what onDone is; the fabricated name
  -- it passes is ignored.
  local function escapable(screen, onEscape, emptyConfirm)
    local baseUpdate, baseConfirm, baseDraw = screen.update, screen.confirm,
                                              screen.draw
    if type(baseUpdate) ~= "function" or type(baseConfirm) ~= "function"
       or type(baseDraw) ~= "function" then
      mod.log:warn("the naming screen is not the shape this mod wraps, so "
        .. "B-to-go-back is off on it -- update the mod for this engine build")
      return screen
    end

    local function empty(self)
      return type(self.glyphs) ~= "table" or #self.glyphs == 0
    end

    local function leave(self)
      self.onDone = onEscape
      return baseConfirm(self)
    end

    screen.confirm = function(self, ...)
      if emptyConfirm and empty(self) then return leave(self) end
      return baseConfirm(self, ...)
    end

    screen.update = function(self, dt)
      local input = self.game and self.game.input
      if input and input:wasPressed("b") and empty(self) then
        return leave(self)
      end
      return baseUpdate(self, dt)
    end

    -- Nothing in this game teaches "B on an empty line", so the screen says
    -- it, on the row both of this mod's pages leave free under the grid --
    -- and says something else the moment there is a character to erase,
    -- which is the rule itself, drawn. A page tall enough to reach that row
    -- keeps its own layout and goes without.
    screen.draw = function(self, ...)
      local out = baseDraw(self, ...)
      local Font = mod.ui.Font
      local rows = type(self.grid) == "function" and #self:grid() or 0
      local y = 32 + (rows + 1) * 16
      if not (Font and Font.draw) or rows == 0 or y > 136 then return out end
      -- the widget signs off with the colour set to white, which is the
      -- colour of its own background. Letters and spaces only: punctuation
      -- would ride on charmap entries a retheme is free to drop.
      love.graphics.setColor(0, 0, 0, 1)
      Font.draw(empty(self) and "B GOES BACK" or "B ERASES", 8, y)
      love.graphics.setColor(1, 1, 1, 1)
      return out
    end

    return screen
  end

  -- A refused attempt, put back on the line it was typed on.
  --
  -- Only ever the player's own keystrokes coming straight back -- never a
  -- stored code, which is a different thing and stays off (see the note on
  -- `default` below). One character wrong then costs one press to fix
  -- instead of six to retype, which is the whole difference between telling
  -- somebody they got it wrong and starting them over.
  local function seed(screen, text)
    if type(text) ~= "string" or type(screen.glyphs) ~= "table" then
      return screen
    end
    for i = 1, math.min(#text, tonumber(screen.maxLen) or 0) do
      local char = text:sub(i, i)
      local byte = char:byte()
      -- printable ASCII only: every glyph on this mod's pages is one byte,
      -- and anything else could only be half of a character the grid drew
      if byte >= 32 and byte <= 126 then
        screen.glyphs[#screen.glyphs + 1] = char
      end
    end
    return screen
  end

  -- How long an address may be typed.
  --
  -- An address or a hostname: "255.255.255.255:65535" is 21, but
  -- "mybox.example.com:7788" is 22, and a name is what a host on a LAN is
  -- likelier to read out. The grid carries the dot, the colon and the dash a
  -- hostname needs, and the name goes to the socket untouched, so the only
  -- thing that could refuse one is this number.
  --
  -- Named rather than written twice: the EDIT HOST grid is the same question
  -- asked about a hub already on the list, and a shorter line there would
  -- refuse an address the join screen accepted.
  local ADDRESS_MAX = 32

  screens:register(SCREEN.JOINADDR, { new = function(game)
    local client = ctx.client
    local screen = namingScreen(game, {
      title = ownTitle("JOIN"),
      maxLen = ADDRESS_MAX,
      default = client:joinAddress(),
      onDone = function(address)
        -- the *stored* form, not what was typed: setJoinAddress fills in
        -- the port, and the code is filed under the address connect dials
        local target = client:setJoinAddress(address)
        if not target then return end
        mod.ui.push(game, SCREEN.JOINCODE, { address = target, connect = true })
      end,
    })
    -- B on an empty line backs out to the MMO menu, which is one more B from
    -- the world. START is left alone: on an empty line it still submits the
    -- address already stored, which is what makes this screen answerable
    -- without typing a character.
    return escapable(screen, function() mod.ui.push(game, SCREEN.MAIN) end)
  end })

  -- ------- joining: the code that gets you past the door

  -- Reached three ways: from JOIN GAME, right after the address and before
  -- anything is dialled; automatically, when a hub challenges a copy whose
  -- code is absent or was refused; and from the host setup, to choose the
  -- code this copy will ask *for*. One grid every time -- the glyphs and the
  -- length are the same question -- and opts says where the answer goes:
  -- opts.host stores it as this copy's own code, opts.connect says a
  -- connection is waiting on it and dials rather than leaving the player to
  -- walk back through the menu, and opts.typed is an attempt this screen
  -- itself refused, coming back.
  --
  -- Every one of those three is a road somebody can walk without the code in
  -- front of them, which is why the screen has a door out (escapable, above)
  -- rather than only a way forward.
  screens:register(SCREEN.JOINCODE, { new = function(game, opts)
    opts = opts or {}
    local client = ctx.client
    local address = opts.address or client:joinAddress()
    local screen = namingScreen(game, {
      title = ownTitle("JOIN CODE"),
      -- the entry cap, not CODE_LEN: a code copied off a chat line or a
      -- screenshot arrives with spaces and stray punctuation around its six
      -- characters, and normalisation is what removes the difference
      maxLen = Config.CODE_ENTRY_MAX,
      -- Deliberately no `default`, on every path: NamingScreen uses it as
      -- the answer when nothing was typed, so a stored code would be
      -- silently re-submitted by pressing ED on an empty line -- and on the
      -- challenge path that is exactly the code that was just refused,
      -- resubmitted with no way to tell. Having no answer to give an empty
      -- line is what leaves it free to mean "let me out" instead.
      onDone = function(text)
        local code = Wire.code(text)
        if not code then
          -- Something was typed and it is not a code, which is a typo and
          -- not a change of mind -- the empty line is what means "out", and
          -- escapable has already taken it. So: say what shape a code is,
          -- and come back to the same grid with the same characters still on
          -- it. A code that vanished into nothing would look like it was
          -- accepted, and a menu would cost the player the five characters
          -- they got right.
          local again = { typed = text }
          for key, value in pairs(opts) do
            if again[key] == nil then again[key] = value end
          end
          return mod.ui.push(game, SCREEN.TEXT, {
            text = ("That isn't a join\ncode. It's %d\nletters and digits."):
              format(Config.CODE_LEN),
            onDone = function() mod.ui.push(game, SCREEN.JOINCODE, again) end,
          })
        end
        if opts.host then
          client:setHostJoinCode(code)
          return mod.ui.push(game, SCREEN.TEXT, {
            text = ("Players will need:\n%s"):format(codeText(code)),
            onDone = function() mod.ui.push(game, SCREEN.HOSTSET) end,
          })
        end
        client:setJoinCode(address, code)
        if opts.connect then
          client:connect(game)
          return
        end
        mod.ui.push(game, SCREEN.TEXT, {
          text = ("Join code saved:\n%s"):format(codeText(code)),
        })
      end,
    })
    -- Only what this screen refused a moment ago, and only from this screen:
    -- a code the hub refused comes back through Client.askJoinCode, which
    -- carries no `typed`, because there the six characters are exactly what
    -- is in question and putting them back would invite resubmitting them.
    seed(screen, opts.typed)
    -- Where B lands: the lock menu for a host who came here to choose the
    -- code they ask *for* -- the screen that opened this one -- and the MMO
    -- menu for everyone typing one in, which is the address screen's own way
    -- out and the only answer on the challenge path, where there is no
    -- screen behind this to go back to. Never a socket left half-dialled,
    -- because nothing has been dialled yet.
    return escapable(screen, function()
      mod.ui.push(game, opts.host and SCREEN.HOSTCODE or SCREEN.MAIN)
    end, true)
  end })

  -- ------- joining again: the hubs that already answered

  -- Every hub this copy actually got a welcome from, kept so the second join
  -- costs a press instead of the twenty-odd keystrokes the first one did --
  -- an address and a six-character code, both typed on a page that has to be
  -- flipped to reach the digits.
  --
  -- A ListMenu rather than the command box the MMO menu uses, for the reason
  -- PLAYERS is one: the length is not fixed and the row carries a second
  -- column. The order is the store's (favourites first, then by address);
  -- the rows are rebuilt on every push, so a rename, a re-address or a
  -- favourite toggle is already in place by the time B lands back here. The
  -- store prepends its synthetic official row before that saved ordering.
  screens:register(SCREEN.SERVERS, { new = function(game)
    local items = {}
    for _, entry in ipairs(serverMenuList()) do
      items[#items + 1] = {
        label = entry.name,
        right = entry.fav and FAV_MARK or nil,
        value = entry.key,
      }
    end
    return mod.ui.ListMenu.new(game, "SERVERS", items, {
      pageJump = true,
      onChoose = function(item, menu)
        menu:close()
        mod.ui.push(game, SCREEN.SERVERACT, { key = item.value })
      end,
      onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
    })
  end })

  -- ------- what you can do with one of them

  screens:register(SCREEN.SERVERACT, { new = function(game, opts)
    opts = opts or {}
    local store = serverStore()
    local entry = serverMenuGet(opts.key)
    if not entry then
      -- The key is derived from the address rather than chosen, so EDIT HOST
      -- moves an entry to a different one -- and a menu still holding the old
      -- key is asking after something that no longer exists. Eviction is the
      -- other way it goes. Either way, say so and hand back the list, rather
      -- than build five rows that would all refuse.
      return mod.ui.TextBox.new(game, "That server is\ngone.", function()
        mod.ui.push(game, SCREEN.SERVERS)
      end)
    end

    local key = entry.key
    local items = {
      -- CONNECT first: it is what the list is for, and every other row is a
      -- correction to make before pressing it.
      { label = "CONNECT", connect = true },
    }
    -- The featured row is product-owned: its label, address, code and place
    -- at the top are not player settings. CONNECT is therefore its complete
    -- action screen. Remembered rows keep the six actions they had before.
    if not entry.featured then
      -- The row says what pressing it does, not what the entry is -- the
      -- same rule the MMO menu's END GAME / LEAVE row follows.
      items[#items + 1] = {
        label = entry.fav and "UNFAVORITE" or "FAVORITE", fav = true,
      }
      items[#items + 1] = { label = "EDIT HOST", field = "host" }
      items[#items + 1] = { label = "EDIT CODE", field = "code" }
      items[#items + 1] = { label = "RENAME", field = "name" }
      -- Last, and last on purpose: it is the one row that cannot be undone
      -- by pressing it again, so it comes after the corrections rather than
      -- among them. Distance is not the guard, though -- Menu wraps, so row
      -- 6 is a single UP from where the cursor starts, which is why the
      -- confirm below has to open on NO.
      items[#items + 1] = { label = "DELETE", remove = true }
    end

    -- Reopening is what "rebuilt" means here (see the favourite row below),
    -- and a rebuild that forgets where the cursor was is a rebuild that
    -- parks it on CONNECT -- so a second press on the row you just pressed
    -- would dial a hub nobody asked for. `row` is carried back the way the
    -- MMO menu carries cursor.main, and is clamped on the way in.
    local reopen = function(row)
      mod.ui.push(game, SCREEN.SERVERACT, { key = key, row = row })
    end

    -- What JOIN GAME does, with both grids already answered.
    --
    -- The same order and the same calls, deliberately: CHARSET first,
    -- because who you are online is asked before you go anywhere; then the
    -- address through the same setJoinAddress the grid writes through; then
    -- the code, filed under the address connect will dial; then connect.
    -- Nothing here is a second way to join -- a hub that challenges a stale
    -- code still comes back through Client.askJoinCode exactly as it does on
    -- the typed path.
    local function dial()
      local client = ctx.client
      -- the stored form, not the entry's own string: setJoinAddress fills in
      -- the port, and the code has to be filed under what connect dials
      local target = client:setJoinAddress(entry.address)
      if not target then
        mod.log:warn("could not dial the saved server %s -- open it under "
          .. "SERVERS and give EDIT HOST an address like 1.2.3.4:7788",
          tostring(entry.address))
        return mod.ui.push(game, SCREEN.TEXT, {
          text = "That address is\nno good. Edit it\nand try again.",
          -- wrapped rather than passed straight, now that reopen takes a
          -- row: whatever the box hands its callback is not one, and this
          -- path came from CONNECT, which is where the cursor starts.
          onDone = function() reopen() end,
        })
      end
      -- Only when there is one: writing nil would be refused anyway, and a
      -- hub with no code never asks for one.
      if entry.code then client:setJoinCode(target, entry.code) end
      client:connect(game)
    end

    for row, item in ipairs(items) do
      local wantsConnect, wantsFav, field = item.connect, item.fav, item.field
      local wantsRemove = item.remove
      item.onSelect = function()
        if wantsConnect then
          mod.ui.push(game, SCREEN.CHARSET, { verb = "JOIN", onReady = dial })
        elseif wantsFav then
          if not (store.setFavorite and store:setFavorite(key, not entry.fav)) then
            mod.log:warn("could not change the favourite mark on the server "
              .. "%s -- back out to SERVERS, reopen it and try again",
              tostring(entry.name))
          end
          -- Straight back to this menu, where the row now reads the other
          -- way round: Menu pops itself before running a row, so reopening
          -- is what "rebuilt" means here -- the same thing ACTIONS does
          -- after a command that changes what its rows should say. The list
          -- behind it re-sorts when B lands on it, because that is a fresh
          -- push too. The cursor comes back to this row, not to CONNECT: a
          -- second press is far likelier to be "no, put it back" than a
          -- request to dial.
          reopen(row)
        elseif field then
          mod.ui.push(game, SCREEN.SERVEREDIT, { key = key, field = field })
        elseif wantsRemove then
          -- Asked before it happens, and the question names the row: this
          -- list is the only copy of an address somebody typed once, and a
          -- delete that landed on the press would be a delete found out
          -- about afterwards. Both mis-presses are free here: defaultNo
          -- opens the box with the cursor already on NO, and CONFIRM's B is
          -- a no as well -- so neither a stray A nor a stray B deletes
          -- anything. That is the whole reason the box is this one and not
          -- a plain TextBox.
          self:confirm(game, ("Forget the server\n%s?"):format(entry.name),
            function(yes)
              -- Back to this menu with the cursor still on DELETE, the way
              -- the favourite row comes back: "no" is an answer about this
              -- row, and dropping the cursor onto CONNECT would put a dial
              -- one press away from someone who just said no to something.
              if not yes then return reopen(row) end
              -- A store with no remove at all is not the same failure as a
              -- store that refused this key, and it must not be told as
              -- one: the row is still on the list and still works, so
              -- "That server is gone." would be a sentence the player can
              -- see is untrue. That is the older-build store the two
              -- helpers at the top of this section exist for -- say so in
              -- the log and hand the menu back unchanged.
              if not store.remove then
                mod.log:warn("could not delete the server %s -- this build's "
                  .. "server list cannot remove entries; back out to SERVERS, "
                  .. "reopen it and try again", tostring(entry.name))
                return reopen(row)
              end
              if not store:remove(key) then
                -- The entry went between the question and the answer --
                -- evicted by a hub recorded underneath, or re-keyed. Same
                -- sentence the menu opens with on a stale key, and the same
                -- place to land, because the list is where it can be seen
                -- that the row is already gone.
                mod.log:warn("could not delete the server %s -- it is no "
                  .. "longer on the list, so there is nothing left to "
                  .. "remove; reopen SERVERS to see what is", tostring(entry.name))
                return mod.ui.push(game, SCREEN.TEXT, {
                  text = "That server is\ngone.",
                  onDone = function() mod.ui.push(game, SCREEN.SERVERS) end,
                })
              end
              -- The row said "Forget", so the hub's passcode goes with it:
              -- the code is filed against the address rather than on the
              -- entry, and leaving it behind would keep a secret for a hub
              -- the player just said they were done with. The claim ticket
              -- stays -- see Client.forgetHub for why. A build whose client
              -- has no forgetHub only warns: the row is already deleted and
              -- has to land on the list either way.
              local client = ctx.client
              if type(client) == "table" and client.forgetHub then
                client:forgetHub(entry.address)
              else
                mod.log:warn("deleted the server %s but could not clear its "
                  .. "stored join code -- this build's client has no "
                  .. "forgetHub; clear it from the JOIN CODE option row if it "
                  .. "should not be kept", tostring(entry.name))
              end
              -- The list, not this menu: the entry this menu is about no
              -- longer exists, so reopening it would draw the "gone" box
              -- about a row the player just chose to be rid of. An empty
              -- list is ListMenu's own "Nothing here.", and the MMO menu
              -- drops the SERVERS row the next time it opens.
              mod.ui.push(game, SCREEN.SERVERS)
            end,
            -- The one confirm in this mod that opens on NO: see the note
            -- above the row.
            { defaultNo = true })
        end
      end
    end

    local menu = mod.ui.Menu.new(game, items, {
      -- ACTIONS' geometry, and its arithmetic for the same reason: Menu
      -- grows the box downwards to fit its rows (th = rows * 2 + 2), so ty
      -- is what keeps the last row on an 18-tile screen.
      tx = 11, ty = math.max(0, math.min(7, 18 - (#items * 2 + 2))), tw = 9,
      onCancel = function() mod.ui.push(game, SCREEN.SERVERS) end,
    })
    -- Where a reopen puts the cursor, clamped rather than trusted: the row
    -- count is fixed today, but an opts table is anybody's to hand in and a
    -- Menu with its index off the end draws no arrow at all.
    menu.index = math.min(math.max(tonumber(opts.row) or 1, 1), #items)
    menu:clampScroll()
    return menu
  end })

  -- ------- changing one of them

  -- One grid for all three fields, because they are one question -- what
  -- should this say instead -- and the only differences are the title, the
  -- length, and which mutator the answer goes to. Three registrations would
  -- be three copies of the refusal path.
  --
  -- Each title is claimed here rather than at the call site, and eagerly:
  -- ownedTitles is what gives this mod's grids their digits page, and an
  -- address and a join code are both mostly digits. `value` is what the line
  -- opens with, `apply` is the store call, `refusal` is what the player is
  -- told when the store says no, and `warn` is the remediation that goes to
  -- the log beside it.
  local EDIT_FIELDS = {
    host = {
      title = ownTitle("EDIT HOST"),
      maxLen = ADDRESS_MAX,
      value = function(entry) return entry.address end,
      apply = function(store, key, text)
        return store.setAddress and store:setAddress(key, text)
      end,
      refusal = "That isn't a hub\naddress. Try\n1.2.3.4:7788.",
      warn = "an address is a name or an IP, with or without a port",
    },
    code = {
      title = ownTitle("EDIT CODE"),
      -- the entry cap rather than CODE_LEN, for JOIN CODE's reason: a code
      -- copied off a chat line arrives with punctuation around its six
      -- characters, and normalisation is what removes the difference
      maxLen = Config.CODE_ENTRY_MAX,
      value = function(entry) return entry.code end,
      apply = function(store, key, text)
        return store.setCode and store:setCode(key, text)
      end,
      refusal = ("That isn't a join\ncode. It's %d\nletters and digits.")
        :format(Config.CODE_LEN),
      warn = ("a join code is %d letters and digits"):format(Config.CODE_LEN),
    },
    name = {
      title = ownTitle("RENAME"),
      maxLen = Config.SERVER_NAME_MAX,
      value = function(entry) return entry.name end,
      apply = function(store, key, text)
        return store.rename and store:rename(key, text)
      end,
      refusal = "A name needs a\nletter or a\ndigit in it.",
      warn = "a name needs at least one character the game's font carries",
    },
  }

  screens:register(SCREEN.SERVEREDIT, { new = function(game, opts)
    opts = opts or {}
    local spec = EDIT_FIELDS[opts.field]
    if not spec then
      -- Its own sentence, not the entry's: nothing has happened to the
      -- server, the caller asked for a field this screen does not have. The
      -- box says what the log says, and B lands on the entry's own menu --
      -- which is where the three rows that do work are.
      mod.log:warn("there is no server field called '%s' to edit -- this "
        .. "screen takes field = host, code or name", tostring(opts.field))
      return mod.ui.TextBox.new(game, "There is nothing\nto edit there.",
        function()
          mod.ui.push(game, SCREEN.SERVERACT, { key = opts.key })
        end)
    end
    local store = serverStore()
    local entry = store and store.get and store:get(opts.key)
    if not entry then
      -- Same sentence SERVERACT gives, and for its two reasons: the entry
      -- was re-keyed under another address, or it was evicted.
      return mod.ui.TextBox.new(game, "That server is\ngone.", function()
        mod.ui.push(game, SCREEN.SERVERS)
      end)
    end

    local key = entry.key
    local screen = namingScreen(game, {
      title = spec.title,
      maxLen = spec.maxLen,
      -- Deliberately no `default`, for JOINCODE's reason: NamingScreen uses
      -- it as the answer to an empty line, so erasing the whole line would
      -- silently rewrite the value with itself. Having no answer to give is
      -- what leaves the empty line free to mean "let me out" -- see the
      -- escapable() call below, which takes it.
      onDone = function(text)
        local updated = spec.apply(store, key, text)
        if type(updated) ~= "table" then
          -- Refused, and refused for a reason the player can act on -- the
          -- empty line is what means "out", and escapable has already taken
          -- it, so anything arriving here is a typo. Say what shape the
          -- answer is and come back to the same grid with the same
          -- characters still on it: one wrong character then costs one press
          -- to fix rather than a whole address to retype.
          -- What was typed does not go to the log, only how much of it: the
          -- code field is a secret (Client's askJoinCode keeps the same
          -- rule), and a refused code is a near-miss of one, which is the
          -- worst kind to write down. The count is what makes "too short"
          -- diagnosable without printing the characters.
          mod.log:warn("could not save what was typed as this server's %s "
            .. "(%d character(s)) -- %s",
            tostring(opts.field), #tostring(text), spec.warn)
          local again = { key = key, field = opts.field, typed = text }
          return mod.ui.push(game, SCREEN.TEXT, {
            text = spec.refusal,
            onDone = function() mod.ui.push(game, SCREEN.SERVEREDIT, again) end,
          })
        end
        -- The key it has now, not the one it had: EDIT HOST re-keys the
        -- entry in place, so reopening on `key` would land on the "that
        -- server is gone" box about the entry that was just edited.
        mod.ui.push(game, SCREEN.SERVERACT, { key = updated.key or key })
      end,
    })
    -- What is already there, on the line and editable. This is a change to a
    -- value that exists, so an empty line would mean retyping a whole
    -- address to correct one character of it -- and unlike a join code being
    -- typed for the first time, there is no secret here that putting it back
    -- would invite resubmitting blind. `opts.typed` wins: that is the
    -- attempt this screen refused a moment ago, coming back.
    seed(screen, opts.typed or spec.value(entry))
    -- B on an empty line goes back to the entry's own menu -- one more B
    -- from the list, two from the MMO menu -- and START on an empty line
    -- means the same thing, because there is nothing an empty line could
    -- usefully save.
    return escapable(screen, function()
      mod.ui.push(game, SCREEN.SERVERACT, { key = key })
    end, true)
  end })

  -- ------- your party

  -- What the PARTY row opens.  Two different screens behind one label,
  -- because "party" means two different things depending on whether you are
  -- in one, and a menu of greyed-out rows would be the worse answer: it
  -- would say what you cannot do without saying what you can.
  screens:register(SCREEN.PARTY, { new = function(game)
    local party = ctx.party
    if not party:has() then
      -- Not a dead end.  The sentence says how a party starts and then hands
      -- over the list to start one from, so the row leads somewhere even
      -- when there is nothing to show yet.
      return mod.ui.TextBox.new(game,
        "No party yet.\nPick a player to\ninvite.", function()
          mod.ui.push(game, SCREEN.ROSTER)
        end)
    end

    local items = {
      {
        label = "MEMBERS",
        onSelect = function() mod.ui.push(game, SCREEN.MEMBERS) end,
      },
      {
        label = "SAY",
        onSelect = function()
          mod.ui.push(game, SCREEN.COMPOSE, { scope = "party" })
        end,
      },
      {
        label = "LEAVE",
        onSelect = function()
          -- Asked first, and the question names them: leaving ends the party
          -- for both of you, which is not what "leave" usually implies and
          -- is not something to discover by pressing A.
          local name = party:partnerName() or "your friend"
          mod.ui.push(game, SCREEN.CONFIRM, {
            text = ("Leave the party\nwith %s?"):format(name),
            onChoose = function(yes)
              if not yes then return mod.ui.push(game, SCREEN.PARTY) end
              party:leave()
              mod.ui.push(game, SCREEN.TEXT, { text = "You left the party." })
            end,
          })
        end,
      },
    }
    return mod.ui.Menu.new(game, items, {
      tx = 9, ty = 0, tw = 11,
      onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
    })
  end })

  -- Who is in it, where they are, and their card.
  --
  -- Position is read from the roster rather than from the party, which holds
  -- names only: the roster is already being updated several times a second
  -- by mmo.move, and a second copy would be a slower answer to the same
  -- question that visibly disagreed with the map.
  screens:register(SCREEN.MEMBERS, { new = function(game)
    local party = ctx.party
    local current = World.current()
    local items = {}
    for _, member in ipairs(party:list()) do
      local mine, right = party:isSelf(member.id), nil
      if mine then
        right = "YOU"
      else
        local player = ctx.roster:get(member.id)
        if not player then
          -- On the list but not on the roster: they dropped a moment ago and
          -- the hub's mmo.party_end has not landed yet.
          right = "GONE"
        elseif player.busy then
          right = "BUSY"
        elseif current and player.map == current.mapId then
          right = "HERE"
        else
          right = "AWAY"
        end
      end
      items[#items + 1] = {
        label = member.name, right = right, value = member.id, mine = mine,
      }
    end
    if #items == 0 then
      items[#items + 1] = { label = "Nobody." }
    end
    return mod.ui.ListMenu.new(game, "PARTY", items, {
      onChoose = function(item, menu)
        if not item.value then return end
        menu:close()
        local back = function() mod.ui.push(game, SCREEN.MEMBERS) end
        mod.ui.push(game, SCREEN.PROFILE, {
          own = item.mine, playerId = item.value, onCancel = back,
        })
      end,
      onCancel = function() mod.ui.push(game, SCREEN.PARTY) end,
    })
  end })

  -- ------- who is online

  screens:register(SCREEN.ROSTER, { new = function(game)
    local items = {}
    for _, player in ipairs(ctx.roster:sorted()) do
      -- Party first: it is the one thing about a player that stays true
      -- while they walk in and out of your map, and it is what tells you the
      -- INVITE row will not be offered against them.  BUSY next, because a
      -- player who cannot be talked to is a fact about the row and their
      -- whereabouts is only context.
      --
      -- Otherwise: where they are.  This is what used to be HERE, and the
      -- place name says that better -- your own map's name against their
      -- row reads as "here" without having to be told, and it also answers
      -- the question HERE could not, which is where the rest of them went.
      -- A player with no map at all is in a battle or a menu; the column
      -- stays blank for them, exactly as it did before.
      local right
      if ctx.party:isPartner(player.id) then
        right = "PARTY"
      elseif player.busy then
        right = "BUSY"
      else
        right = placeColumn(game, player)
      end
      items[#items + 1] = {
        label = player.name,
        right = right,
        value = player.id,
      }
    end
    -- A roster is genuinely a list -- variable length, with a status
    -- column -- so this one stays the full-screen ListMenu the bag and the
    -- PC use, rather than a command box.
    return mod.ui.ListMenu.new(game, "PLAYERS", items, {
      pageJump = true,
      onChoose = function(item, menu)
        menu:close()
        local player = ctx.roster:get(item.value)
        if player then
          mod.ui.push(game, SCREEN.ACTIONS, {
            playerId = player.id,
            onCancel = function() mod.ui.push(game, SCREEN.ROSTER) end,
          })
        end
      end,
      onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
    })
  end })

  -- ------- what you can do with one of them

  screens:register(SCREEN.ACTIONS, { new = function(game, opts)
    local player = ctx.roster:get(opts and opts.playerId)
    if not player then
      return mod.ui.TextBox.new(game, "They just went\noffline.")
    end

    -- The commands about the person in front of you: a small box, the way
    -- the original asks CUT/SURF or a party submenu. Sized to the widest
    -- label by Menu itself and nudged on-screen, so it stays right however
    -- long a trainer's name is.
    -- PROFILE first: knowing who you are looking at should come before
    -- deciding to trade with them
    local items = { { label = "PROFILE", profile = true } }

    -- INVITE appears only when a party could actually be formed -- neither
    -- of you already in one. Offered-then-refused is the failure this
    -- avoids: the hub would answer with a decline, so a row that is always
    -- there would be a button whose usual result is a box saying no.
    -- Absent, not greyed: the menu is sized to its rows, and a permanently
    -- dead row in a four-line box is a line the useful commands do not get.
    if not (ctx.party:has() or player.party) then
      items[#items + 1] = { label = "INVITE", invite = true }
    end

    -- JOIN, and only against the partner who is actually standing at a fight
    -- waiting for us. This is the third way into the co-op yes/no in the
    -- brief -- walking up to the person who is waiting and pressing A -- and
    -- it is offered rather than always present for the same reason INVITE is:
    -- a row whose usual answer is "there is nothing to join" is a row the
    -- useful commands do not get.
    local offer = ctx.coop:pendingOffer()
    if offer and offer.from == player.id then
      items[#items + 1] = { label = "JOIN", join = true }
    end

    items[#items + 1] = { label = "TRADE", kind = "trade" }
    items[#items + 1] = { label = "BATTLE", kind = "battle" }
    -- Directly under BATTLE, which is where the brief puts it and where it
    -- belongs: it is the same verb with twice the people. Offered against
    -- almost everybody, and deliberately so -- unlike INVITE, whose refusals
    -- are facts about the two of you that the menu can see, most ways this one
    -- can be refused are a sentence naming what to fix (no party, they have no
    -- party, your friend is elsewhere), and a row that vanished would say none
    -- of it.
    --
    -- Your own partner is the exception, and the reason is that there is
    -- nothing to fix. A 2-on-2 is two parties and the two of you are one, so
    -- it is not a battle that could be arranged by moving somewhere or waiting
    -- for someone -- it is a battle that does not exist. Absent, like INVITE
    -- against someone already in a party.
    if not ctx.party:isPartner(player.id) then
      items[#items + 1] = { label = "PARTY BATTLE", party = true }
    end
    items[#items + 1] = { label = "WHISPER" }

    local reopen = function()
      mod.ui.push(game, SCREEN.ACTIONS,
        { playerId = player.id, onCancel = opts and opts.onCancel })
    end
    for _, item in ipairs(items) do
      local kind, wantsProfile, wantsInvite = item.kind, item.profile, item.invite
      local wantsJoin, wantsParty = item.join, item.party
      item.onSelect = function()
        if wantsProfile then
          mod.ui.push(game, SCREEN.PROFILE,
            { playerId = player.id, onCancel = reopen })
        elseif wantsInvite then
          ctx.party:invite(player)
        elseif wantsJoin then
          ctx.coop:joinFromMenu(game)
        elseif wantsParty then
          -- The current map is read here and handed down, because Coop holds
          -- no engine dependency of its own -- see M:challenge's header.
          local current = World.current()
          ctx.coop:challenge(game, player, current and current.mapId)
        elseif kind then
          ctx.sessions:request(player, kind)
        else
          mod.ui.push(game, SCREEN.COMPOSE,
            { scope = "private", to = player.id, toName = player.name })
        end
      end
    end

    return mod.ui.Menu.new(game, items, {
      -- low and to the right, clear of the two characters this menu is
      -- about: a command box that covers the person you are talking to
      -- reads as a bug even when it is not one.
      --
      -- ty is computed rather than fixed because the row count now varies.
      -- Menu grows its box downwards to fit (th = rows * 2 + 2) and nudges
      -- only sideways, so a fifth row at the old ty=7 ran off the bottom of
      -- an 18-tile screen; this keeps the box's last row on 18 and leaves
      -- the four-row case exactly where it was.
      tx = 11, ty = math.max(0, math.min(7, 18 - (#items * 2 + 2))), tw = 9,
      -- back to whatever opened this: the roster if you came from the menu,
      -- the world if you walked up and pressed A
      onCancel = opts and opts.onCancel,
    })
  end })

  -- ------- the chat log

  -- Chat lines are the one thing here that will not fit a Game Boy row.
  -- A 60-character message is three times the width of the screen, and
  -- ListMenu draws a label as one line, so it would simply run off the
  -- edge. Wrap on spaces and indent the continuations, the way the
  -- original's text boxes break a sentence.
  -- 15, not 18: ListMenu indents its rows past the cursor column, so the
  -- full screen width is not what a row actually gets. Wrapping to the
  -- theoretical width put the last word hard against the right edge.
  local CHAT_COLS = 15

  -- `first` and `rest` are indents, not seed text: seeding `line` with the
  -- indent made the opening row join it to the first word with a space, so
  -- it sat one column right of every row beneath it -- a ragged left edge
  -- on exactly the messages long enough to wrap.
  local function wrapLine(text, first, rest)
    local rows, line, indent = {}, "", first
    for word in tostring(text):gmatch("%S+") do
      local candidate = line == "" and (indent .. word) or (line .. " " .. word)
      if #candidate > CHAT_COLS and line ~= "" then
        rows[#rows + 1] = line
        indent = rest
        line = indent .. word
      else
        line = candidate
      end
    end
    if line ~= "" then rows[#rows + 1] = line end
    return rows
  end

  screens:register(SCREEN.CHATLOG, { new = function(game)
    ctx.chat:markRead()
    local items = {}
    for _, entry in ipairs(ctx.chat:recent(Config.CHAT_HISTORY)) do
      -- Speaker on its own row, message wrapped beneath it.
      --
      -- Running them together ate the width and, worse, merged the scope
      -- tag into the name: "G" + "HOSTY" read as "GHOSTY". Brackets keep
      -- the tag distinct, and giving the message its own rows means it gets
      -- the full 18 columns instead of whatever the name left over.
      local tag = Chat.TAG[entry.scope] or "?"
      items[#items + 1] = { label = ("[%s]%s:"):format(tag, entry.name) }
      for _, row in ipairs(wrapLine(entry.text, " ", " ")) do
        items[#items + 1] = { label = row }
      end
    end
    if #items == 0 then
      items[#items + 1] = { label = "No messages yet." }
    end
    -- newest last, so open on the bottom the way a chat log should read
    local menu = mod.ui.ListMenu.new(game, "CHAT", items, {
      pageJump = true,
      onChoose = function(_, menu) menu:close() end,
      onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
    })
    menu.index = #items
    return menu
  end })

  -- ------- pick a scope, then type

  screens:register(SCREEN.SCOPE, { new = function(game)
    local items = {
      { label = "EVERYONE", scope = "global" },
      { label = "NEARBY", scope = "local" },
    }
    -- Only while there is a party to say it to. The row is also on the PARTY
    -- menu; it is repeated here because SAY is where somebody who wants to
    -- talk goes, and having to leave it and find another menu to reach one
    -- of the four scopes would be the odd one out.
    if ctx.party:has() then
      items[#items + 1] = { label = "PARTY", scope = "party" }
    end
    for _, item in ipairs(items) do
      local scope = item.scope
      item.onSelect = function()
        mod.ui.push(game, SCREEN.COMPOSE, { scope = scope })
      end
    end
    return mod.ui.Menu.new(game, items, {
      tx = 9, ty = 0, tw = 11,
      onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
    })
  end })

  screens:register(SCREEN.COMPOSE, { new = function(game, opts)
    opts = opts or {}

    -- the same grid serves chat and the trainer name; only the title, the
    -- length and what happens on confirm differ
    if opts.scope == "name" then
      local client = ctx.client
      return namingScreen(game, {
        title = ownTitle("YOUR NAME"),
        maxLen = Config.NAME_MAX,
        default = client:playerName(game),
        onDone = function(name)
          client:setPlayerName(name)
          mod.ui.push(game, opts.back or SCREEN.CHARSET, opts.backOpts or {})
        end,
      })
    end

    local title = opts.scope == "private"
      and ("TO " .. tostring(opts.toName or "?"))
      or (opts.scope == "party" and "SAY TO PARTY")
      or (opts.scope == "local" and "SAY NEARBY" or "SAY TO ALL")
    return namingScreen(game, {
      title = ownTitle(title),
      maxLen = Config.COMPOSE_MAX,
      onDone = function(text)
        ctx.client:say(opts.scope, text, opts.to)
      end,
    })
  end })

  -- ------- trade: choose what to offer

  screens:register(SCREEN.PICK, { new = function(game, opts)
    opts = opts or {}
    local trade = opts.trade
    local items = {}
    for index, mon in ipairs(game.save.party or {}) do
      local blocked = trade and not trade:canPick(index)
      items[#items + 1] = {
        label = tostring(mon.species),
        -- the reason the other game would not rebuild this mon, so a greyed
        -- row explains itself instead of just refusing
        right = blocked and (trade.reasons[index] and "NO" or "NO") or
          ("L" .. tostring(mon.level)),
        value = index,
        blocked = blocked,
      }
    end
    return mod.ui.ListMenu.new(game, "TRADE WHICH?", items, {
      onChoose = function(item, menu)
        if item.blocked then return end
        menu:close()
        if opts.onPick then opts.onPick(item.value) end
      end,
      onCancel = function()
        if opts.onPick then opts.onPick(nil) end
      end,
    })
  end })
end

M.Chat = Chat

return M
