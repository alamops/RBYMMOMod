-- Shared helpers for the two MMO frame drivers.
--
-- Loaded with dofile from the engine checkout root, the same way
-- tests/drivers/util.lua is, so both drivers share one copy of the menu
-- navigation instead of each guessing at cursor arithmetic.

local U = dofile("tests/drivers/util.lua")

local M = { U = U }

-- Two instances play the overworld theme, a trade jingle and a whole battle
-- at each other for several minutes, and nothing in this test ever asserts
-- on a sound. Muting at load keeps a background run from taking over the
-- room; set MMO_SOUND=1 if a change to the audio path ever needs hearing.
if os.getenv("MMO_SOUND") ~= "1" then
  if love and love.audio and love.audio.setVolume then
    love.audio.setVolume(0)
  end
end

function M.top(game)
  return game.stack and game.stack:top() or nil
end

-- Spin until `predicate` is true, or give up. Returns whether it happened,
-- so a driver can log a real failure instead of walking on and producing a
-- confusing error three steps later.
--
-- Budgeted in FRAMES, so it is only correct for things that are actually
-- measured in frames: a menu opening, a transition playing, a socket binding
-- in this process. If what you are waiting for can only happen once the
-- *other* game does something, this is the wrong helper and waitSeconds is
-- the right one -- read the note above it before reaching for either.
function M.waitFor(game, predicate, frames, what)
  for _ = 1, frames or 300 do
    if predicate() then return true end
    U.wait(1)
  end
  U.log("TIMEOUT waiting for " .. tostring(what or "condition"))
  return false
end

-- Pick a row by its label rather than by counting taps.
--
-- The START menu's length depends on save state (POKéDEX only appears once
-- Oak hands it over), and this mod inserts its own row, so a driver that
-- tapped "down" a fixed number of times would break the moment the menu
-- changed shape. Menu and ListMenu both expose `items` and a 1-based
-- `index`, so the cursor distance can be computed instead.
-- Matches a row by label, tolerating an unread marker on either side of it:
-- the CHAT row reads "▶CHAT" while messages are unread, and a driver that
-- demanded an exact string would fail for the wrong reason.
--
-- Leading as well as trailing, because that marker moved to the front when
-- it stopped being "*" -- a character the extracted font cannot draw. It is
-- stripped by byte rather than matched as a class: "▶" is three UTF-8 bytes,
-- so a driver asking for "CHAT" against "▶CHAT" was comparing "CHAT" with
-- the marker's own bytes and never matching. The old trailing form is still
-- accepted so this util keeps working against an older build of the mod.
local MARKERS = { "\226\150\182" }   -- ▶ (U+25B6)

local function labelMatches(actual, wanted)
  if actual == wanted then return true end
  if type(actual) ~= "string" then return false end
  for _, marker in ipairs(MARKERS) do
    if actual:sub(1, #marker) == marker then
      actual = actual:sub(#marker + 1)
      break
    end
  end
  return actual:sub(1, #wanted) == wanted
    and actual:sub(#wanted + 1):match("^[%*%s]*$") ~= nil
end

-- Exported because a driver that re-implements this rule drifts from it.
-- mmo_guest.lua had its own two-line copy spelling the marker as a trailing
-- "*", which went on passing until the marker moved and changed character --
-- then failed as "no chat row" on a menu that plainly had one.
M.labelMatches = labelMatches

function M.selectLabel(game, label, frames)
  local ok = M.waitFor(game, function()
    local top = M.top(game)
    if not (top and type(top.items) == "table") then return false end
    for _, item in ipairs(top.items) do
      if labelMatches(item.label, label) then return true end
    end
    return false
  end, frames or 240, "menu row " .. label)
  if not ok then return false end

  local menu = M.top(game)
  local target
  for i, item in ipairs(menu.items) do
    if labelMatches(item.label, label) then target = i break end
  end

  local steps = (target - (menu.index or 1)) % #menu.items
  for _ = 1, steps do
    U.tap(game, "down")
    U.wait(2)
  end
  U.wait(2)
  U.tap(game, "a")
  U.wait(10)
  return true
end

-- The labels of whatever menu is on top, in order.
--
-- Worth having shared: "which rows exist" is an assertion in its own right
-- now that a row has been *removed* -- HOST > JOIN CODE no longer offers NO
-- CODE, because a game with no code is one the hub refuses to open a port
-- for. A driver can only check that by reading the whole list.
function M.menuLabels(game)
  local top = M.top(game)
  local labels = {}
  for _, item in ipairs((top and top.items) or {}) do
    labels[#labels + 1] = tostring(item.label)
  end
  return labels
end

-- Characters in `text` the font cannot draw, as a comma-separated string
-- ("" when every one of them renders).
--
-- This is the one bug class a driver asserting on strings is structurally
-- blind to. The charmap is extracted from the ROM and carries no "*" (nor
-- + # < > % =); Font.draw silently draws nothing for a character it cannot
-- map while Font.width still advances 8px, so a label reads correctly to
-- every assertion here and renders as a blank column on screen. The MMO
-- menu's unread marker was "CHAT*" and did exactly that.
--
-- Only answerable on a real dataset: the committed fixture font carries
-- letters and digits alone, so a headless suite cannot tell drawable from
-- not. Hence a driver helper rather than a unit test.
function M.undrawable(game, text)
  local ok, Font = pcall(require, "src.render.Font")
  if not (ok and Font and Font.split) then return "" end
  local missing = {}
  for _, span in ipairs(Font.split(tostring(text or "")) or {}) do
    if span.code == nil then
      missing[#missing + 1] = tostring(span.text or "?")
    end
  end
  return table.concat(missing, ",")
end

-- One row of the menu on top, by label, so its right-hand column can be
-- read. That column carries the join code itself on the HOST screen -- it
-- used to say ON -- and reading it back is the only way to check the thing a
-- host actually sees without reaching into the mod for a code it
-- deliberately keeps out of exports and logs.
function M.menuRow(game, label)
  local top = M.top(game)
  for _, item in ipairs((top and top.items) or {}) do
    if labelMatches(item.label, label) then return item end
  end
  return nil
end

function M.exports(game)
  local loader = game.mods
  return loader and loader.exports and loader.exports.rby_mmo or nil
end

-- The mod ships experimental, so a run where the wrapper forgot to enable
-- it would otherwise fail deep inside a menu that never appears. Say so up
-- front instead.
function M.requireMod(game, tag)
  local loader = game.mods
  local mod = loader and loader.mods and loader.mods.rby_mmo
  if not mod then
    U.log(tag, "FAIL rby_mmo was not discovered -- is it linked into mods/?")
    return nil
  end
  if mod.state ~= "loaded" then
    U.log(tag, ("FAIL rby_mmo is %s, not loaded -- it ships experimental, so "
      .. "options.lua must enable it"):format(tostring(mod.state)))
    return nil
  end
  local exports = M.exports(game)
  if not exports then
    U.log(tag, "FAIL rby_mmo published no exports")
    return nil
  end
  return exports
end

-- Dismiss whatever is on the stack until the overworld is on top again.
--
-- This matters for more than tidiness: StateStack updates only the top
-- state, so while any box or menu is up the overworld -- and every NPC in
-- it -- is frozen. An avatar mid-step stays mid-step, which is correct in
-- play but makes a driver that samples avatar movement behind an open text
-- box wait forever for a step that cannot finish.
function M.closeToOverworld(game, tries)
  for _ = 1, tries or 24 do
    local top = M.top(game)
    if top == nil or top == game.overworld or top.isOverworld then return true end
    -- a text box wants A to advance and close; a menu wants B to cancel
    U.tap(game, "b")
    U.wait(6)
    if M.top(game) == top then
      U.tap(game, "a")
      U.wait(6)
    end
  end
  local top = M.top(game)
  U.log("WARN could not get back to the overworld; top is",
        tostring(top and (top.title or "?")))
  return false
end

-- Wait on something the OTHER process has to get round to, in seconds.
--
-- Frames are the right unit for anything that is genuinely frame-shaped: a
-- menu opening, a battle transition, a socket binding -- so many frames
-- whatever the clock is doing. They are exactly the wrong unit for anything
-- whose completion depends on the other process. LOVE steps a driver once
-- per rendered frame, and two windows on one desktop do not render at the
-- same rate -- the focused one runs at the display's refresh while the
-- occluded one is throttled by the window server, by an order of magnitude
-- in the bad case. A frame budget is therefore an *unknown* number of
-- seconds, and comparing one against a barrier measured in seconds is
-- comparing nothing at all.
--
-- Two bugs have come out of that, both of them looking like something else:
--
--   * the host spent "60 * 420 frames" of patience waiting for the guest to
--     connect, burned it in half that many seconds on a 120Hz display, quit,
--     and the guest -- still crawling through the intro -- finally dialled a
--     port nobody was listening on and reported "connection refused";
--
--   * the trade ran "60 * 90 frames" against a partner waiting 120 seconds.
--     Below about 45fps the driver outlasts its partner, who walks off; the
--     abandoned side is left mid-cutscene talking to a peer that has moved
--     on, and reports a stalled trade that is really an abandonment. Either
--     side can lose, depending on which window the OS throttles, which is
--     exactly why it looked like a transport fault. It was not: the hub
--     logged zero drops through it.
--
-- So: anything whose completion depends on the other process waits on the
-- clock. Anything frame-shaped keeps waitFor, and says why at the call site.
function M.waitSeconds(game, predicate, seconds, what)
  seconds = seconds or 120
  local deadline = os.time() + seconds
  while os.time() < deadline do
    if predicate() then return true end
    U.wait(2)
  end
  U.log(("TIMEOUT waiting %ds for %s"):format(seconds, tostring(what or "condition")))
  return false
end

-- ------- join codes
--
-- The driver learns the code the way a friend does: off the screen the host
-- is looking at. Nothing reaches into the mod for it -- Client deliberately
-- keeps the code out of every log and out of exports, and a test that read
-- it from a private table would still pass on a build whose screen printed
-- nothing.

-- Config.CODE_ALPHABET, as a Lua character class. Crockford-style, so I, L,
-- O and U are absent -- which is also what stops "will" or "code" in the
-- surrounding sentence from looking like a code.
local CODE_CHAR = "[0-9A-HJKMNP-TV-Z]"
-- Config.CODE_LEN. Six ungrouped characters -- A7K3P9, not
-- ABCD-EFGH-JKMN-PQRS -- so there is no dash left anywhere to anchor a
-- match on, and Wire.formatCode is a passthrough.
M.CODE_LEN = 6

-- Pull a join code out of whatever a screen is showing.
--
-- Ui shows one as Wire.formatCode does, which at six characters is the code
-- itself, so what comes back from textOf is "Players will need: A7K3P9" and
-- the dashed pair this used to key on is gone. Whole alphanumeric *tokens*
-- are matched rather than any six-character window: a token counts only if
-- all of it is code characters, which is what stops six usable letters in
-- the middle of a longer word from being read as a code. Case does most of
-- the work on top of that -- every code character is upper case and the
-- mod's own prose is not -- so "Players" is refused before its length is
-- even considered.
function M.codeFrom(text)
  if type(text) ~= "string" then return nil end
  local shaped = "^" .. CODE_CHAR:rep(M.CODE_LEN) .. "$"
  for token in text:gmatch("%w+") do
    if #token == M.CODE_LEN and token:match(shaped) then return token end
  end
  return nil
end

-- The display form, for logs and for asserting a screen reads it back.
--
-- A passthrough, and it has to stay the mirror of Wire.formatCode: a driver
-- that dressed a code up in dashes the game no longer prints would compare
-- its own invention against the screen and fail for the wrong reason.
function M.formatCode(code)
  if type(code) ~= "string" then return "" end
  return code
end

-- A code of the right shape that is not the right code.
--
-- Derived from the real one rather than invented, so it is guaranteed to
-- normalise (Wire.code refuses anything that is not exactly six symbols of
-- the alphabet) and guaranteed to be wrong. A hand-written constant could
-- be neither.
function M.wrongCode(code)
  local first = code:sub(1, 1)
  return (first == "0" and "1" or "0") .. code:sub(2)
end

-- ------- typing on the naming grid
--
-- The join code screen is NamingScreen, so the only way to enter one is the
-- d-pad: move the cursor onto a cell and press A. That is worth driving
-- properly rather than writing the glyphs in directly -- "is the code
-- typeable at all" is exactly the question this screen answers, and the
-- alphabet was chosen (Config.CODE_ALPHABET) so that every symbol sits on
-- the mod's own grid pages.
local function findCell(grid, ch)
  for r, row in ipairs(grid) do
    for c, cell in ipairs(row) do
      if cell == ch then return r, c end
    end
  end
  return nil
end

-- Walks the cursor rather than computing a tap count. NamingScreen wraps
-- both axes and clamps the column when the row changes, and SELECT swaps in
-- a page with a different number of rows -- so arithmetic that was right on
-- the letters page lands somewhere else on the digits page. Stepping until
-- the cursor is where it should be is immune to all of that.
local function moveTo(game, screen, r, c)
  for _ = 1, 12 do
    if (screen.row or 1) == r then break end
    U.tap(game, "down")
    U.wait(1)
  end
  for _ = 1, 12 do
    if (screen.col or 1) == c then break end
    U.tap(game, "right")
    U.wait(1)
  end
  return (screen.row or 1) == r and (screen.col or 1) == c
end

function M.typeOnGrid(game, text)
  local screen = M.top(game)
  if not (screen and type(screen.glyphs) == "table" and screen.grid) then
    U.log("WARN not on a naming screen; cannot type")
    return false
  end
  for i = 1, #text do
    local ch = text:sub(i, i)
    local r, c = findCell(screen:grid(), ch)
    if not r then
      -- the other page. SELECT is what the case-switch row does, and the
      -- mod's grid hook reads the same flag to swap letters for digits
      U.tap(game, "select")
      U.wait(2)
      r, c = findCell(screen:grid(), ch)
    end
    if not r then
      U.log("WARN no cell on the naming grid for", ch)
      return false
    end
    if not moveTo(game, screen, r, c) then
      U.log("WARN could not reach the cell for", ch)
      return false
    end
    U.tap(game, "a")
    U.wait(2)
  end
  return true
end

-- Is a naming screen on top, and is it the one that wants a join code?
--
-- The title is the only thing that tells them apart, and telling them apart
-- became load-bearing when the join flow changed: JOIN GAME now asks for the
-- address and the code back to back on two naming screens, so "a grid is up"
-- no longer means "the grid that wants a code". Typing six characters into
-- the wrong one dials a hostname made of join code and reports a refused
-- connection. src/Ui.lua owns both titles (ownTitle).
local ADDRESS_TITLE = "JOIN"
local CODE_TITLE = "JOIN CODE"

M.ADDRESS_TITLE = ADDRESS_TITLE
M.CODE_TITLE = CODE_TITLE

local function namingScreen(game)
  local top = M.top(game)
  if not (top and type(top.glyphs) == "table" and top.grid) then return nil end
  return top
end

local function titledGrid(game, title)
  local screen = namingScreen(game)
  if not screen then return nil end
  if tostring(screen.title or "") ~= title then return nil end
  return screen
end

-- the screen that wants a hub address, and the screen that wants the code
-- for it -- in that order, both before anything is dialled
function M.addressGrid(game)
  return titledGrid(game, ADDRESS_TITLE)
end

function M.codeGrid(game)
  return titledGrid(game, CODE_TITLE)
end

-- Answer a join-code prompt: dismiss whatever box is asking, type the code
-- on the grid, and confirm with START.
--
-- Reached two ways now, and this handles both without being told which.
-- Straight after the address screen the grid is simply already up, because
-- that screen's onDone pushes it. On the challenge path -- a wrong code, or
-- one this copy never had -- a text box comes first and its onDone pushes
-- the grid, and a refusal arrives as two boxes rather than one (the hub's
-- sentence, then Transport's). So: keep pressing A until the grid is
-- actually there, rather than counting screens.
--
-- A *different* naming screen on top is waited out rather than pressed
-- through: A there would type a character into the address field instead of
-- advancing anything.
function M.enterJoinCode(game, code)
  local screen
  for _ = 1, 40 do
    screen = M.codeGrid(game)
    if screen then break end
    if namingScreen(game) then
      U.wait(10)
    else
      U.tap(game, "a")
      U.wait(10)
    end
  end
  if not screen then
    local top = M.top(game)
    U.log("WARN never reached the join-code grid; top is",
          tostring(top and (top.title or "?")))
    return false
  end
  if not M.typeOnGrid(game, code) then return false end
  local typed = table.concat(screen.glyphs)
  if typed ~= code then
    U.log("WARN the grid holds", typed, "not", M.formatCode(code))
    return false
  end
  U.tap(game, "start")
  U.wait(30)
  return true
end

-- ------- phase barriers
--
-- The two drivers are separate processes with no channel between them but
-- the filesystem. Polling "has the other side got there yet" with sleeps is
-- what made the early runs flaky, so each phase is gated on an explicit
-- marker instead.
--
-- THE RULE, and it is not optional:
--
--   A barrier's patience must outlast the worst-case wall-clock of the work
--   on the other side that it is waiting for, with margin.
--
-- Break it and the waiting side walks off while its partner is still
-- mid-flow. What gets reported is never "I gave up too early" -- it is
-- whatever the abandoned side was doing when its peer vanished, so a thin
-- barrier surfaces as a stalled trade, a battle that never started, or a
-- refused connection. That has cost two debugging sessions here already.
--
-- Two things follow, and both are load-bearing:
--
--   1. Both halves of the comparison are in seconds. Work budgets on the
--      other side are waitSeconds / drivePrompts, never frame counts, or the
--      comparison is between quantities in different units.
--   2. The patience lives in PHASE below, next to the work it was derived
--      from, rather than being spelled at the call site where the two sides
--      cannot see each other.
--
-- And the run checks itself rather than trusting the comment: signal()
-- records how long its side actually took, await() reads that back and warns
-- when the margin it was given is thinner than MARGIN. A run that is drifting
-- towards this bug says so before it fails.
local MARGIN = 1.5

-- barrier -> seconds of patience, and the budget on the other side it was
-- derived from. Where the work is a handful of frames the floor is 90s,
-- because a barrier that is generous costs a good run nothing -- it clears
-- the moment the marker lands -- and only ever delays the report of a hang.
local PHASE = {
  -- guest waits on the host finishing presence checks and avatar sampling
  host_walk_start        = 240,  -- 45 moved + 60 sampling + shots
  -- host waits on the guest reading one roster row
  guest_baseline_taken   =  90,  -- floor
  -- guest waits on three scripted steps
  host_walk_done         =  90,  -- floor
  -- host waits on the guest's presence checks, chat and teleport
  guest_left_map         = 300,  -- 45 + 45 + 90 chat + teleports
  -- guest waits on the host noticing the despawn
  host_saw_despawn       =  90,  -- 45 despawn
  -- host waits on the guest teleporting back
  guest_back_on_map      =  90,  -- floor
  -- guest waits on the host noticing the respawn
  host_ready_for_interact=  90,  -- 45 respawn
  -- host waits on the guest walking up, reading the card and closing it
  guest_interact_done    = 240,  -- 60 facing + menu + profile card
  -- host waits on the guest waiting for it to be free, then picking TRADE
  guest_trade_requested  = 120,  -- 45 free
  -- guest waits on the host driving its half of the trade
  host_trade_done        = 240,  -- 120 trade drive   <-- the one that broke
  -- host waits on the guest finishing its trade, then asking for a battle
  guest_battle_requested = 300,  -- 120 trade drive + 60 free
  -- guest waits on the host running a link battle to a decision
  host_battle_done       = 540,  -- 90 start + 240 run + transition
  -- guest waits on the host re-opening the MMO menu
  host_address_checked   = 150,  -- menus only
  -- host waits on the guest leaving and proving the world still works
  guest_left_game        = 240,  -- 60 leave drive + walk test

  -- ------- the dedicated-hub scenario (tests/drivers/run-hub-e2e.sh)
  --
  -- Two guests on server/bin/rby-mmo-hub.js and no in-game host anywhere.
  -- Both instances run one driver (tests/drivers/mmo_guest.lua) and meet at
  -- `hub_<role>_<tag>` markers, so almost every barrier here comes in an a/b
  -- pair: each side signals its own and waits for the other's.
  --
  -- The two `ready` budgets are the odd ones out, and deliberately large:
  -- phaseClock starts when the driver loads, so what they measure is a whole
  -- cold boot -- intro, naming, the MMO menus -- plus a join code typed one
  -- character at a time on a d-pad grid. Role a types two of them (a wrong
  -- one, then the right one); b types one, and gets the same budget because
  -- the boot dominates both.
  hub_a_ready            = 600,  -- boot + menus + a wrong code AND a right one
  hub_b_ready            = 600,  -- boot + menus + one code
  -- b waits on a reaching the walk leg
  hub_a_walk_start       =  90,  -- floor
  -- a waits on b taking its baseline before it moves
  hub_b_baseline         =  90,  -- floor
  -- b waits on a's three scripted steps
  hub_a_walk_done        = 120,  -- floor + the walk
  -- a waits on b judging the walk a cannot judge itself
  hub_a_walk             = 120,  -- floor
  hub_b_walk             = 240,  -- 60 roster move + 60 avatar catch-up
  -- both sides repeat their lines until they hear the other's, in two scopes
  hub_a_chat             = 300,  -- 150 chat drive
  hub_b_chat             = 300,  -- the same
  -- b waits on a walking the PLAYERS menu, reading the card and asking
  hub_a_trade_asked      = 180,  -- menus + profile card
  -- each waits on the other's half of the trade
  hub_a_trade            = 360,  -- 180 trade drive
  hub_b_trade            = 360,  -- 180 trade drive
  -- a waits on b waiting for it to be free, then asking for a battle
  hub_b_battle_asked     = 180,  -- 90 free + menus
  -- each waits on the other running a link battle to a decision
  hub_a_battle           = 540,  -- 120 start + 300 run + transition
  hub_b_battle           = 540,  -- the same
  -- b waits on a leaving first, so it can watch the roster empty
  hub_a_left             = 240,  -- menus + the chat log + LEAVE
  -- a waits on b noticing that, then leaving too
  hub_b_left             = 300,  -- 120 watching + menus + LEAVE
}

local SYNC_DIR = os.getenv("MMO_SYNC_DIR") or "/tmp/rby_mmo_sync"

-- when this side last crossed a barrier, so signal() can say how long the
-- segment it just finished actually took
local phaseClock = os.time()

function M.syncPath(name)
  return SYNC_DIR .. "/" .. name
end

function M.patience(name)
  return PHASE[name] or 180
end

function M.signal(name)
  local spent = os.time() - phaseClock
  phaseClock = os.time()
  os.execute('mkdir -p "' .. SYNC_DIR .. '" 2>/dev/null')
  local path = M.syncPath(name)
  -- written then renamed: the other side polls for this path to exist, and a
  -- file caught between open and write would read as a zero-second segment
  -- and quietly disarm the margin check
  local handle = io.open(path .. ".tmp", "w")
  if handle then
    handle:write(tostring(spent))
    handle:close()
    os.rename(path .. ".tmp", path)
  end
end

-- Seconds, not frames, and by default the seconds PHASE says. See the rule
-- above; `seconds` is here for a caller that genuinely knows better, not as
-- the normal way to set a budget.
function M.await(game, name, seconds)
  seconds = seconds or M.patience(name)
  local spent
  local ok = M.waitSeconds(game, function()
    local handle = io.open(M.syncPath(name), "r")
    if not handle then return false end
    spent = tonumber(handle:read("*a") or "")
    handle:close()
    return true
  end, seconds, "phase " .. name)
  phaseClock = os.time()
  -- The check that keeps the rule true. It fires whether or not the barrier
  -- was actually tested this run: "was my patience enough for their work" is
  -- answerable from the numbers alone, so a run that happened to be fast
  -- still reports a budget that would not survive a slow one.
  if ok and spent and spent > 0 and seconds < spent * MARGIN then
    U.log(("WARN barrier %s: %ds of patience for %ds of work on the other "
      .. "side (%.1fx, want %.1fx) -- raise it in mmo_util's PHASE table")
      :format(name, seconds, spent, seconds / spent, MARGIN))
  end
  return ok
end

-- this game's own player cell
function M.playerCell(game)
  local ow
  for i = #game.stack.states, 1, -1 do
    if game.stack.states[i].isOverworld then ow = game.stack.states[i] break end
  end
  ow = ow or game.overworld
  if not (ow and ow.map and ow.player) then return nil end
  return { mapId = ow.map.id, x = ow.player.cellX, y = ow.player.cellY }
end

-- The renderer this game's own player is drawn with, by identity.
--
-- Not which sprite was *chosen* -- exports.myLook already answers that, and
-- it kept answering correctly while the player was visibly wearing someone
-- else. This is the live object on the entity, which is the only thing that
-- says what is actually on screen, and comparing it to the one taken before
-- connecting is how "leaving gives you your own trainer back" is checkable
-- at all.
function M.playerSheet(game)
  local ow
  for i = #game.stack.states, 1, -1 do
    if game.stack.states[i].isOverworld then ow = game.stack.states[i] break end
  end
  ow = ow or game.overworld
  return ow and ow.player and ow.player.sprite or nil
end

-- the other side's avatar, as this game sees it
function M.avatarRow(exports, name)
  for _, row in ipairs(exports.avatarState() or {}) do
    if name == nil or row.name == name then return row end
  end
  return nil
end

-- ------- driving a session's prompts
--
-- A trade puts a sequence of boxes in front of both players -- "X wants to
-- trade!", the party picker, "Trade for Y?", then the result -- and the two
-- sides do not see them at the same moments. Rather than scripting an exact
-- order per side (which would be a different script for host and guest, and
-- would break the moment a prompt moved), both sides run this: answer
-- whatever is on top, affirmatively, until `done` says the flow finished.
--
-- The three shapes are distinguishable by their fields:
--   ListMenu / Menu -> has `items`      (the party picker)
--   ChoiceBox       -> has `onChoose` and `index` but no `items`
--   TextBox         -> neither
local function classify(top)
  if not top then return nil end
  if type(top.items) == "table" then return "menu" end
  if top.onChoose ~= nil and top.index ~= nil then return "choice" end
  return "text"
end

M.classify = classify

-- Budgeted in SECONDS, and it must be: a trade or a battle only finishes
-- when the other process answers its half, so this is a wait on the peer
-- wearing the clothes of a work loop. It was the last frame budget left in
-- the pair, and it was the one that broke -- 60 * 90 frames on one side
-- against a 120-second barrier on the other, which holds above 60fps and
-- silently inverts below about 45. See the rule at "phase barriers".
--
-- Returns whether `done` came true, and the sequence of prompt kinds it
-- answered on the way. A trade or battle that stalls is otherwise a bare
-- "did not happen": the sequence says whether the prompt never arrived, or
-- arrived and was answered and still went nowhere.
--
-- onStep(kind, top) is called for each prompt just before it is answered;
-- promptLog below is the standard one to hand it.
function M.drivePrompts(game, done, seconds, onStep)
  local seen = {}
  local function note(kind)
    if kind and seen[#seen] ~= kind then seen[#seen + 1] = kind end
  end
  local deadline = os.time() + (seconds or 120)
  while os.time() < deadline do
    if done and done() then return true, table.concat(seen, ">") end
    local top = M.top(game)

    -- The overworld is NOT a prompt. It has no `items` and no `onChoose`,
    -- so classify() called it a text box and this loop mashed A into the
    -- open world -- pressing A on doors and NPCs and walking into grass.
    -- One run wandered the host out of Red's house, through Pallet Town and
    -- Oak's lab, onto Route 1, and left it fighting wild Pokemon while the
    -- trade it was supposed to be answering timed out. Wait for a real
    -- prompt instead.
    if top == nil or top == game.overworld or top.isOverworld then
      U.wait(4)
      goto continue
    end

    -- onStep sees the prompt BEFORE it is answered, which is the only moment
    -- its text still exists: a box that has been dismissed cannot say what it
    -- asked. The kind sequence alone says a confirm was answered twice; only
    -- the text says whether it was the same question twice.
    local kind = classify(top)
    if onStep then onStep(kind, top) end
    if kind == "choice" then
      -- YES is index 1; walk the cursor there rather than assuming it
      local guard = 0
      while (M.top(game) == top) and (top.index or 1) > 1 and guard < 4 do
        U.tap(game, "up")
        U.wait(3)
        guard = guard + 1
      end
      U.tap(game, "a")
      U.wait(12)
    elseif kind == "menu" then
      -- the party picker: take whatever is under the cursor (slot 1)
      U.tap(game, "a")
      U.wait(12)
    elseif kind == "text" then
      U.tap(game, "a")
      U.wait(8)
    else
      U.wait(4)
    end
    note(kind)
    ::continue::
  end
  return (done and done() or false), table.concat(seen, ">")
end

-- An onStep for drivePrompts that records what each prompt actually said.
--
-- Returns the recorder and the list it fills. Consecutive repeats are kept,
-- not collapsed: "the same question twice" is exactly the observation worth
-- having when a session stalls, and a dedup would hide it. Choices carry the
-- cursor row, so an answer that went to NO can be told from one that went to
-- YES rather than assumed.
function M.promptLog()
  local seen = {}
  return function(kind, top)
    local what = kind
    if kind == "choice" then
      what = ("choice@%s"):format(tostring(top.index or 1))
    elseif kind == "text" then
      local text = M.textOf(top)
      if text ~= "" then what = '"' .. text .. '"' end
    elseif kind == "menu" then
      local labels = {}
      for _, item in ipairs(top.items or {}) do
        labels[#labels + 1] = tostring(item.label)
      end
      what = "menu[" .. table.concat(labels, ",") .. "]"
    end
    seen[#seen + 1] = what
  end, seen
end

-- Put the hardest-hitting move in slot 1.
--
-- drivePrompts answers a battle menu by taking whatever is under the
-- cursor: FIGHT, then move 1. Gen 1 leads do not cooperate -- CHARIZARD at
-- 50 opens with LEER and PIKACHU at 30 with GROWL, both zero power -- so
-- two driven parties would lower each other's stats until PP ran out and
-- the test burned its whole budget without a decision.
--
-- Reordering rather than injecting a move keeps the mon otherwise
-- authentic, and picking by power rather than by name means this works for
-- any species without hardcoding move ids that differ between versions.
function M.frontloadDamage(data, mon)
  local best, bestPower
  for i, mv in ipairs(mon.moves or {}) do
    local def = data.moves[mv.id]
    local power = def and def.power or 0
    if power > 0 and (bestPower == nil or power > bestPower) then
      best, bestPower = i, power
    end
  end
  if not best or best == 1 then
    return mon.moves and mon.moves[1] and mon.moves[1].id or nil
  end
  local mv = table.remove(mon.moves, best)
  table.insert(mon.moves, 1, mv)
  return mv.id
end

-- species in party order, for asserting a trade actually swapped something
function M.partySpecies(game)
  local out = {}
  for _, mon in ipairs((game.save and game.save.party) or {}) do
    out[#out + 1] = tostring(mon.species)
  end
  return out
end

-- Record engine events by wrapping Runtime.emit.
--
-- Same trick tests/drivers/online_match_host.lua uses. Subscribing through
-- the event bus would work too, but wrapping catches everything regardless
-- of which bus a mod installed, and a battle is exactly where an assertion
-- must not depend on this mod's own plumbing being correct.
--
-- link.desync is the one to watch: two games disagreeing mid-battle is the
-- failure a lockstep simulation exists to prevent, and it is silent
-- otherwise.
function M.captureEvents(names)
  local Runtime = require("src.mods.Runtime")
  local seen = {}
  for _, name in ipairs(names) do seen[name] = 0 end
  local realEmit = Runtime.emit
  Runtime.emit = function(name, payload)
    if seen[name] ~= nil then seen[name] = seen[name] + 1 end
    return realEmit(name, payload)
  end
  return seen
end

-- The visible contents of a TextBox, flattened. TextBox paginates into
-- self.pages, so this is how a driver checks that what the player is
-- actually being shown says what it should.
function M.textOf(top)
  if not (top and type(top.pages) == "table") then return "" end
  local out = {}
  for _, page in ipairs(top.pages) do
    if type(page) == "table" then
      for _, line in ipairs(page) do out[#out + 1] = tostring(line) end
    end
  end
  return table.concat(out, " ")
end

-- ------- capturing a text box that has finished saying its piece
--
-- textOf above reads `pages`, which is the whole script the box was built
-- with -- it is true from the frame the box is constructed, which is why the
-- assertions around these captures were always right. What is on the *screen*
-- is `shown`, filled one glyph every few frames by the typewriter in
-- TextBox:update, and a capture taken right after a box opens photographs
-- three words of a sentence. Two of the screenshots this project ships
-- (host-newcode, host-address) read "Players will" and "Tell your fri" for
-- exactly that reason: they were correct tests attached to useless pictures.
--
-- The widget already says when it has stopped typing, so nothing here needs
-- to guess at a delay. There are two ways it stops, and both mean the frame
-- is settled:
--
--   done    -- the last line of the last page is out; it is waiting for A to
--              close (src/render/TextBox.lua, `self.done = true`)
--   waiting -- the between-pages pause, blinking arrow and all
--
-- Note what `done` means for a three-line page like the address screen's:
-- the box holds two lines at a time and scrolls, so once it is done the
-- visible pair is the *last* two lines -- the address and the CODE row --
-- which is precisely the half a friend has to be told.
function M.printed(top)
  if not (top and type(top.pages) == "table") then return false end
  return top.done == true or top.waiting == true
end

-- Frames, and rightly: printing is a fixed number of characters at a fixed
-- cadence (the OPTION text speed) inside this process, with nothing on the
-- wire and no second process involved. 300 frames is five seconds at 60fps
-- against the longest box in the mod, which is about 60 characters.
function M.awaitPrinted(game, frames)
  return M.waitFor(game, function() return M.printed(M.top(game)) end,
                   frames or 300, "the text box to finish printing")
end

-- Capture, but only once the box has finished printing.
--
-- Deliberately still captures on a timeout: a box that never finished is
-- worth having a picture of, and a helper that silently skipped the shot
-- would leave the reader with no artefact and no explanation. waitFor has
-- already logged TIMEOUT by then.
function M.shotPrinted(game, path, frames)
  M.awaitPrinted(game, frames)
  return U.shot(game, path)
end

-- Erase a naming grid back to an empty line, one B at a time.
--
-- Bounded by what is actually on the line, and it has to be: this mod's
-- escape hatch makes B on an *empty* line leave the screen (src/Ui.lua,
-- `escapable`), so one press too many is not a no-op -- it pops the grid and
-- answers whatever was behind it. Returns whether the line ended up empty,
-- which is the state START's submit-the-default path needs.
function M.clearGrid(game, screen)
  screen = screen or M.top(game)
  if not (screen and type(screen.glyphs) == "table") then return false end
  for _ = 1, (tonumber(screen.maxLen) or 32) + 1 do
    if #screen.glyphs == 0 then return true end
    U.tap(game, "b")
    U.wait(2)
  end
  U.log("WARN could not clear the naming grid; it still holds",
        table.concat(screen.glyphs))
  return false
end

-- open the START menu and step into MMO
function M.openMmo(game)
  U.tap(game, "start")
  U.wait(15)
  return M.selectLabel(game, "MMO")
end

return M
