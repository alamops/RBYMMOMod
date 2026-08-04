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
  CHARSET  = "RbyMmoCharSetup",
  CHARPICK = "RbyMmoCharPick",
  PROFILE  = "RbyMmoProfile",
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

  -- portrait on the right, level with the two fixed-width rows below
  local art = portrait(p.sprite)
  if art then
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(art.image, art.quad, 116, 56, 0, 2, 2)
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
  Font.draw(("SEEN/%d OWN/%d"):format(card.seen or 0, card.owned or 0), 16, 104)
  if own then
    -- last row of the 18-tile box: y=120 leaves the bottom border clear,
    -- the way the dex line does at 104
    Font.draw(("MONEY/¥%d"):format(p.money), 16, 120)
  end
end

function M.new(ctx)
  -- ctx is filled in by Client once every part exists; holding the table
  -- rather than its fields is what lets Ui be built before Sessions
  return setmetatable({ ctx = ctx }, M)
end

-- ------- primitives other modules call

function M:say(text, onDone)
  local game = self.ctx.game
  if not game then return end
  mod.ui.push(game, SCREEN.TEXT, { text = text, onDone = onDone })
end

function M:confirm(game, text, onChoose)
  game = game or self.ctx.game
  if not game then return end
  mod.ui.push(game, SCREEN.CONFIRM, { text = text, onChoose = onChoose })
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
    })
  end })

  screens:register(SCREEN.STATE, { new = function(_, opts)
    return opts and opts.state
  end })

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
        -- A marker for unread, the way the original marks state in a label
        -- rather than with a second column the box has no room for.
        --
        -- The marker leads rather than trails, and is a triangle rather
        -- than the asterisk this used to carry: the extracted font has no
        -- glyph for "*", and Font.draw silently draws nothing for a
        -- character it cannot map while Font.width still advances 8px for
        -- it -- so "CHAT*" rendered as CHAT followed by a blank column that
        -- looked like a layout bug. "▶" is on the sheet (it is the same
        -- glyph the menu cursor uses), so the row now actually shows what
        -- it claims to.
        items[#items + 1] = {
          label = ctx.chat.unread > 0 and "▶CHAT" or "CHAT",
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
      -- There is deliberately no third row for the code. JOIN GAME asks for
      -- the address and then the code, so a row called JOIN CODE sitting
      -- under it read as the other half of joining rather than as what it
      -- was -- somewhere to change a saved one without dialling. Two rows
      -- that both start a join, one of which does not, is a menu that has to
      -- be explained; the code that gets typed is now always the one on the
      -- way in, and the standing fallback is the JOIN CODE option row.
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
  -- Who you are online, asked once before you host or join, rather than
  -- inheriting the save's trainer name and a sprite nobody chose. The name
  -- is separate from the save file's, so somebody can be ASH online without
  -- renaming their single-player game.

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
    local current = client:spriteChoice()
    local items, start = {}, 1
    for i, id in ipairs(Chars.list()) do
      if id == current then start = i end
      items[#items + 1] = { label = Chars.label(id), value = id }
    end
    local menu = mod.ui.ListMenu.new(game, "CHARACTER", items, {
      pageJump = true,
      onChoose = function(item, m)
        m:close()
        client:setSpriteChoice(item.value)
        mod.ui.push(game, SCREEN.CHARSET, opts.back or {})
      end,
      onCancel = function()
        mod.ui.push(game, SCREEN.CHARSET, opts.back or {})
      end,
    })
    menu.index = start
    return menu
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

  screens:register(SCREEN.JOINADDR, { new = function(game)
    local client = ctx.client
    local screen = namingScreen(game, {
      title = ownTitle("JOIN"),
      -- An address or a hostname: "255.255.255.255:65535" is 21, but
      -- "mybox.example.com:7788" is 22, and a name is what a host on a LAN
      -- is likelier to read out. The grid carries the dot, the colon and
      -- the dash a hostname needs, and the name goes to the socket
      -- untouched, so the only thing that could refuse one is this number.
      maxLen = 32,
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
    local current = World.current()
    local items = {}
    for _, player in ipairs(ctx.roster:sorted()) do
      local here = current and player.map == current.mapId
      -- Party first: it is the one thing about a player that stays true
      -- while they walk in and out of your map, and it is what tells you the
      -- INVITE row will not be offered against them.
      local right
      if ctx.party:isPartner(player.id) then
        right = "PARTY"
      elseif player.busy then
        right = "BUSY"
      elseif here then
        right = "HERE"
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

    items[#items + 1] = { label = "TRADE", kind = "trade" }
    items[#items + 1] = { label = "BATTLE", kind = "battle" }
    items[#items + 1] = { label = "WHISPER" }

    local reopen = function()
      mod.ui.push(game, SCREEN.ACTIONS,
        { playerId = player.id, onCancel = opts and opts.onCancel })
    end
    for _, item in ipairs(items) do
      local kind, wantsProfile, wantsInvite = item.kind, item.profile, item.invite
      item.onSelect = function()
        if wantsProfile then
          mod.ui.push(game, SCREEN.PROFILE,
            { playerId = player.id, onCancel = reopen })
        elseif wantsInvite then
          ctx.party:invite(player)
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
