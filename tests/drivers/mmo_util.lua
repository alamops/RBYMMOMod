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

-- ------- Gen 3 (FireRed / LeafGreen / Emerald)
--
-- A Game3 has no StateStack. Its menus live on the module-level modal stack
-- src/ui/game3/stack.lua (layers keyed by id, the top one alone getting
-- input), the cart's own dialogue is src/ui/game3/message.lua and its YES /
-- NO is src/ui/game3/choice.lua -- neither of those two is a layer. Every
-- helper below that reads "what is on screen" gets a Gen 3 arm that looks at
-- those three instead, and every arm is taken only on a Game3 (which carries
-- `generation = 3` on the instance itself), so a Gen 1 or Gen 2 run walks
-- exactly the code it always walked.
--
-- The mod's own screens need no translation: src/Gen3Ui.lua's driver
-- contract makes the layer's `mod` the screen object, with `items[i].label`,
-- `index` / `cursor`, `text` / `pages` / `waiting`, and the naming grid's
-- `glyphs` / `grid()` / `row` / `col` / `title` -- the Gen 1 widget fields
-- this file already reads. Engine layers are presented through small views:
-- START as a menu (its rows are StartMenu.ENTRIES, its cursor
-- StartMenu.cursor), the cart's message as a text box and its YES / NO as a
-- choice -- one stable table each, so "is the same thing still on top"
-- comparisons keep working across calls.
local function g3(game)
  return type(game) == "table" and rawget(game, "generation") == 3
end
M.isGen3 = g3

local function g3mod(name)
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then return mod end
  return nil
end

local g3Views = {}

local function g3StartView()
  if g3Views.start then return g3Views.start end
  g3Views.start = setmetatable({ id = "start", g3Engine = "start" }, {
    __index = function(_, key)
      local SM = package.loaded["src.ui.game3.start_menu"]
      if not SM then return nil end
      if key == "items" then return SM.ENTRIES end
      if key == "index" or key == "cursor" then return SM.cursor end
      return nil
    end,
  })
  return g3Views.start
end

local function g3MessageView()
  if g3Views.message then return g3Views.message end
  g3Views.message = setmetatable({ g3Engine = "message" }, {
    __index = function(_, key)
      local Message = package.loaded["src.ui.game3.message"]
      if not Message then return nil end
      if key == "pages" then
        local ok, page = pcall(Message.currentPage)
        local text = ok and page or nil
        if type(text) == "table" then text = table.concat(text, " ") end
        return { { tostring(text or "") } }
      end
      if key == "waiting" then return Message.isWaiting and Message.isWaiting() end
      return nil
    end,
  })
  return g3Views.message
end

local function g3ChoiceView()
  if g3Views.choice then return g3Views.choice end
  g3Views.choice = setmetatable({ g3Engine = "choice", onChoose = true }, {
    __index = function(_, key)
      local Choice = package.loaded["src.ui.game3.choice"]
      if key == "index" then return Choice and Choice.cursor or 1 end
      return nil
    end,
  })
  return g3Views.choice
end

-- The top layer itself ({ id, mod, ... }), for the ones that need its id.
function M.g3Layer()
  local Stack = package.loaded["src.ui.game3.stack"] or g3mod("src.ui.game3.stack")
  if not Stack then return nil end
  local ok, layer = pcall(Stack.top)
  return ok and type(layer) == "table" and layer or nil
end

function M.g3LayerId()
  local layer = M.g3Layer()
  return layer and layer.id or nil
end

function M.g3Has(id)
  local Stack = package.loaded["src.ui.game3.stack"]
  return Stack ~= nil and Stack.has(id) == true
end

function M.g3Top(game) -- luacheck: ignore game
  local layer = M.g3Layer()
  if layer then
    if layer.id == "start" then return g3StartView() end
    if type(layer.mod) == "table" then return layer.mod end
    return layer
  end
  local Message = package.loaded["src.ui.game3.message"]
  if Message and Message.isOpen and Message.isOpen() then return g3MessageView() end
  local Choice = package.loaded["src.ui.game3.choice"]
  if Choice and Choice.active then return g3ChoiceView() end
  return nil
end

-- Nothing up, nothing talking, nothing asking: the field is the player's.
function M.g3Idle(game)
  if not g3(game) or game.phase ~= "field" or game.session == nil then return false end
  local Stack = package.loaded["src.ui.game3.stack"]
  if Stack and Stack.busy() then return false end
  local Message = package.loaded["src.ui.game3.message"]
  if Message and Message.isOpen and Message.isOpen() then return false end
  local Choice = package.loaded["src.ui.game3.choice"]
  if Choice and Choice.active then return false end
  return true
end

-- The live session (game.save on a Game3 is only the snapshot of the last
-- SAVE; party, bag, dex and flags that matter are on the runtime session).
function M.g3Session(game)
  local Runtime = package.loaded["src.core.game3.runtime"] or g3mod("src.core.game3.runtime")
  local s = Runtime and Runtime.getSession and Runtime.getSession() or nil
  return s or (game and game.session) or nil
end

function M.top(game)
  if g3(game) and game.stack == nil then return M.g3Top(game) end
  return game.stack and game.stack:top() or nil
end

-- Is `target` anywhere in the state stack, not only on top?
--
-- StateStack:pop only ever removes the entry at the very end of the array, so
-- a state that got skipped past rather than unwound does not vanish -- it
-- stays exactly where it was, one slot down, waiting for whatever now sits
-- above it to clear. M.top alone cannot see that: it reads only the last
-- element, and a state buried one slot down looks identical to "gone" from up
-- there. A co-op leg needs the stronger claim -- that the real trainer battle
-- it displaced is off the stack *entirely*, not merely off the top -- because
-- the bug it exists to catch is exactly a battle that survived buried, and
-- every check that only ever asked what was on top would have missed it.
function M.onStack(game, target)
  if target == nil then return false end
  for _, state in ipairs((game.stack and game.stack.states) or {}) do
    if state == target then return true end
  end
  return false
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

-- Hold several buttons down together for n frames, then release all of
-- them.
--
-- tests/drivers/util.lua's U.hold only drives one input for its whole span;
-- running needs a direction and B held at the same moment, and two
-- sequential U.hold calls cannot express that -- they hold one, release it,
-- then hold the other, so B is never down while the step is in flight. Same
-- shape as U.hold underneath (raw pressQueue + state, one coroutine.yield
-- per frame), so it costs nothing against the frame-shaped waits around it.
function M.holdAll(game, btns, n)
  for _ = 1, n do
    for _, btn in ipairs(btns) do
      table.insert(game.input.pressQueue, btn)
      game.input.state[btn] = true
    end
    coroutine.yield()
  end
  for _, btn in ipairs(btns) do
    game.input.state[btn] = false
  end
end

-- Pick a row by its label rather than by counting taps.
--
-- The START menu's length depends on save state (POKéDEX only appears once
-- Oak hands it over), and this mod inserts its own row, so a driver that
-- tapped "down" a fixed number of times would break the moment the menu
-- changed shape. Menu and ListMenu both expose `items` and a 1-based
-- `index`, so the cursor distance can be computed instead.
-- Matches a row by label, tolerating a marker on either side of it. No row
-- carries one today -- the CHAT row's unread marker is gone, having read as
-- a second cursor once it became "▶" -- but the tolerance stays: a driver
-- that demanded an exact string would fail for the wrong reason against an
-- older build, or against the next row that decides to decorate itself.
--
-- Leading as well as trailing, because that marker moved to the front when
-- it stopped being "*" -- a character the extracted font cannot draw. It is
-- stripped by byte rather than matched as a class: "▶" is three UTF-8 bytes,
-- so a driver asking for "CHAT" against "▶CHAT" was comparing "CHAT" with
-- the marker's own bytes and never matching.
---
--- The second one is not hypothetical and is on a row drivers press: a
--- friend's nickname on the PLAYERS list carries "▷" in front of it
--- (src/Ui.lua's FRIEND_MARK). The moment a driver befriends somebody, every
--- later H.selectLabel(game, "GUESTY") against that list is asking for a
--- string the row no longer starts with -- one miss that took the party and
--- co-op legs down with it, all of them reported as "found the guest on the
--- PLAYERS list". Anything that decorates a label has to be added here.
local MARKERS = {
  "\226\150\182",   -- ▶ (U+25B6), the party marker
  "\226\150\183",   -- ▷ (U+25B7), the friend marker
}

-- Leading whitespace, on top of the marker: the CHARPICK rows now open a
-- 16px portrait gutter with a two-space indent (src/Ui.lua's PREVIEW_INDENT),
-- so a character that used to render as "NIRE" arrives as "  NIRE" -- and a
-- driver asking H.selectLabel/H.menuRow for the bare name would fail to find
-- it for the same reason the unmarked marker used to: comparing a wanted
-- string against one that starts with bytes the caller never asked about.
-- Stripped after the marker rather than before it, since the marker itself
-- carries no leading space of its own to confuse this with.
local function labelMatches(actual, wanted)
  if actual == wanted then return true end
  if type(actual) ~= "string" then return false end
  for _, marker in ipairs(MARKERS) do
    if actual:sub(1, #marker) == marker then
      actual = actual:sub(#marker + 1)
      break
    end
  end
  actual = actual:gsub("^%s+", "")
  return actual:sub(1, #wanted) == wanted
    and actual:sub(#wanted + 1):match("^[%*%s]*$") ~= nil
end

-- Exported because a driver that re-implements this rule drifts from it.
-- mmo_guest.lua had its own two-line copy spelling the marker as a trailing
-- "*", which went on passing until the marker moved and changed character --
-- then failed as "no chat row" on a menu that plainly had one.
M.labelMatches = labelMatches

-- What a menu is actually offering, for a failure message.  "TIMEOUT waiting
-- for menu row MMO" says only that the row was not there, which is the one
-- thing already known -- and a row that is missing because the *menu* is not
-- the one the driver thinks it is on reads exactly the same as a row that is
-- missing because the mod failed to add it.  Naming the rows separates those
-- two in the log, without a second run to find out.
local function stateName(state)
  if state == nil then return "nil" end
  for _, key in ipairs({ "name", "id", "kind", "label", "title" }) do
    if type(state[key]) == "string" then return state[key] end
  end
  local fields = {}
  for key, value in pairs(state) do
    if type(key) == "string" and type(value) ~= "function" then
      fields[#fields + 1] = key
    end
  end
  table.sort(fields)
  return "?{" .. table.concat(fields, ",", 1, math.min(#fields, 8)) .. "}"
end

-- Every state on the stack, bottom to top, for the same reason rowLabels
-- exists: "no items" does not say whether the menu failed to open or opened
-- as something else.
function M.stackNames(game)
  if g3(game) and game.stack == nil then
    local Stack = package.loaded["src.ui.game3.stack"]
    local ids = {}
    for _, layer in ipairs((Stack and Stack._layers) or {}) do
      ids[#ids + 1] = tostring(layer.id)
    end
    local Message = package.loaded["src.ui.game3.message"]
    if Message and Message.isOpen and Message.isOpen() then ids[#ids + 1] = "<message>" end
    local Choice = package.loaded["src.ui.game3.choice"]
    if Choice and Choice.active then ids[#ids + 1] = "<choice>" end
    if #ids == 0 then return "<empty stack>" end
    return table.concat(ids, " > ")
  end
  local out = {}
  for _, state in ipairs((game.stack and game.stack.states) or {}) do
    out[#out + 1] = stateName(state)
  end
  if #out == 0 then return "<empty stack>" end
  return table.concat(out, " > ")
end

function M.rowLabels(game)
  local top = M.top(game)
  if not (top and type(top.items) == "table") then
    return (top and "<top state has no items: " .. stateName(top) .. ">"
      or "<nothing on the stack>") .. "  stack: " .. M.stackNames(game)
  end
  local names = {}
  for _, item in ipairs(top.items) do
    names[#names + 1] = tostring(item.label)
  end
  if #names == 0 then return "<menu is empty>" end
  return table.concat(names, " | ")
end

function M.selectLabel(game, label, frames)
  local ok = M.waitFor(game, function()
    local top = M.top(game)
    if not (top and type(top.items) == "table") then return false end
    for _, item in ipairs(top.items) do
      if labelMatches(item.label, label) then return true end
    end
    return false
  end, frames or 240, "menu row " .. label)
  if not ok then
    U.log("  the menu on top offered: " .. M.rowLabels(game))
    return false
  end

  local menu = M.top(game)
  local target
  for i, item in ipairs(menu.items) do
    if labelMatches(item.label, label) then target = i break end
  end

  -- Gen 3: Gen3Ui's ListMenu does not wrap by default, so the downs-only
  -- arithmetic below would stop at the last row short of a target above the
  -- cursor. Walk the cursor there instead, watching it move.
  if g3(game) then
    for _ = 1, #menu.items * 2 + 2 do
      local at = menu.index or menu.cursor or 1
      if at == target then break end
      U.tap(game, at < target and "down" or "up")
      U.wait(2)
    end
    if (menu.index or menu.cursor or 1) ~= target then
      U.log("WARN the cursor did not reach row " .. tostring(label))
    end
    U.wait(2)
    U.tap(game, "a")
    U.wait(10)
    return true
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
--
-- **Both sides of the merge wrote this helper independently**, after being
-- bitten by the same silence -- main by "CHAT*" on the MMO menu, the party
-- branch by a "*" nameplate marker. Git kept both, and Lua kept whichever
-- was defined last, which is how two versions with *different return types*
-- -- a comma-joined string and a list -- ended up one `==` away from a
-- caller that could never pass. This is the one function, taking the better
-- half of each:
--
--   * main's signature and return value, because that is the published one
--     and `missing == ""` reads better than `#missing == 0` at a call site;
--   * the branch's character extraction, because a span carries `from`/`to`
--     into the source string and *not* the text it covers -- `span.text` is
--     nil, so the other version named every offending character "?" and
--     could not say which one was wrong;
--   * the branch's not-loaded guard, because Font.split resolves nothing
--     before Font.load has run: every span comes back code-less and an
--     unguarded version calls every character of every string undrawable.
--     In game the font is always loaded, so this only bites a standalone
--     probe -- but a wall of false failures blaming the caller's text is
--     worse than saying plainly that the font was not ready.
local UNDRAWABLE_CONTROL = "A"

function M.undrawable(game, text)
  local subject = tostring(text or "")
  if subject == "" then return "" end
  local ok, Font = pcall(require, "src.render.Font")
  if not (ok and Font and Font.split) then return "?FONT-UNAVAILABLE" end

  local function spansOf(s)
    local got, spans = pcall(Font.split, s)
    if got and type(spans) == "table" then return spans end
    return nil
  end

  local control = spansOf(UNDRAWABLE_CONTROL)
  if not (control and control[1] and control[1].code) then
    return "?FONT-NOT-LOADED"
  end

  local spans = spansOf(subject)
  if not spans then return "?FONT-SPLIT-FAILED" end

  local missing = {}
  for _, span in ipairs(spans) do
    if span.code == nil then
      local char = subject:sub(span.from or 1, span.to or 0)
      if char ~= " " and char ~= "" then missing[#missing + 1] = char end
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

-- The mod must be loaded for the driver to reach its menus. Say so up front
-- if discovery or enablement failed (options.lua / symlink / experimental
-- override).
function M.requireMod(game, tag)
  local loader = game.mods
  local mod = loader and loader.mods and loader.mods.rby_mmo
  if not mod then
    U.log(tag, "FAIL rby_mmo was not discovered -- is it linked into mods/?")
    return nil
  end
  if mod.state ~= "loaded" then
    U.log(tag, ("FAIL rby_mmo is %s, not loaded -- enable it in options.lua "
      .. "or the F10 mod manager"):format(tostring(mod.state)))
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
  -- Gen 3: the field is "on top" when no layer, message or choice is up. B
  -- first for the same reason as below (a menu cancels, a mod box and the
  -- cart's message both advance on it), then A when B changed nothing.
  if g3(game) and game.stack == nil then
    for _ = 1, tries or 24 do
      if M.g3Idle(game) then return true end
      local top = M.top(game)
      U.tap(game, "b")
      U.wait(6)
      if not M.g3Idle(game) and M.top(game) == top then
        U.tap(game, "a")
        U.wait(6)
      end
    end
    if M.g3Idle(game) then return true end
    U.log("WARN could not get back to the field; up is", M.stackNames(game))
    return false
  end
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

-- ------- the nickname prompt a catch earns
--
-- An MMO catch is granted by the mod (MediatedBattle / CoopBattle
-- `grantCatch`), and the catcher is asked to name what they caught exactly as
-- the engine's own catch asks: a yes/no box once the ending has finished
-- printing, then the letter grid behind a YES.
--
-- Driven properly rather than skipped, because "can the catcher actually name
-- it" is the question this leg exists to answer -- and because a prompt left
-- standing swallows the taps the rest of the leg makes to close the battle.

-- Which naming grid is on top, if either: the two generations are different
-- screens with different fields (Gen 1 keeps `glyphs` and a `grid()`; Gold
-- keeps the typed string on `text` and its board behind `rows()`).
function M.namingGridKind(top)
  if type(top) ~= "table" then return nil end
  if type(top.glyphs) == "table" and type(top.grid) == "function" then
    return "gen1"
  end
  if type(top.text) == "string" and type(top.rows) == "function"
     and type(top.characterAt) == "function" then
    return "gen2"
  end
  return nil
end

-- Gold's board, walked the way M.typeOnGrid walks Gen 1's: step the cursor
-- rather than compute a tap count, because both axes wrap and SELECT swaps in
-- a page with different rows. Cursor coordinates are 0-based here, and the
-- row past the last letter row is the fat case/DEL/END one.
local function gen2Cell(screen, ch)
  local grid = screen:rows()
  for r = 1, #grid do
    for c = 1, #(grid[r] or {}) do
      if grid[r][c] == ch then return r - 1, c - 1 end
    end
  end
  return nil
end

local function typeOnGen2Grid(game, screen, text)
  for i = 1, #text do
    local ch = text:sub(i, i)
    local r, c = gen2Cell(screen, ch)
    if not r then
      U.tap(game, "select") -- the other case page
      U.wait(2)
      r, c = gen2Cell(screen, ch)
    end
    if not r then
      U.log("WARN no cell on Gold's naming grid for", ch)
      return false
    end
    for _ = 1, 12 do
      if screen.row == r then break end
      U.tap(game, "down")
      U.wait(1)
    end
    for _ = 1, 12 do
      if screen.col == c then break end
      U.tap(game, "right")
      U.wait(1)
    end
    if screen.row ~= r or screen.col ~= c then
      U.log("WARN could not reach Gold's cell for", ch)
      return false
    end
    U.tap(game, "a")
    U.wait(2)
  end
  return true
end

-- Wait for the prompt, answer YES, type `name`, confirm.
--
-- Returns true only when the grid actually held what was typed -- the point
-- of the leg is that the catcher can name the monster, and a grid that came
-- up empty is a failure with a screenshot rather than a pass.
-- `onGrid` (optional) runs once the grid is up and before anything is typed,
-- which is the only moment an empty naming screen can be photographed.
function M.answerNicknamePrompt(game, name, seconds, onGrid)
  local asked = M.waitSeconds(game, function()
    local top = M.top(game)
    if M.namingGridKind(top) then return true end
    local text = (M.textOf(top) or ""):lower()
    return text:find("nickname", 1, true) ~= nil
  end, seconds or 90, "the nickname prompt after a catch")
  if not asked then
    U.log("WARN no nickname prompt after the catch")
    return false
  end

  -- A finishes the printing, and A again answers the yes/no under it. YES is
  -- where the box opens (the mod passes no defaultNo here), so this needs no
  -- cursor walk -- but it does need a bound, because pressing A into a grid
  -- types letters.
  local guard = 0
  while M.namingGridKind(M.top(game)) == nil and guard < 40 do
    U.tap(game, "a")
    U.wait(6)
    guard = guard + 1
  end
  local screen = M.top(game)
  local kind = M.namingGridKind(screen)
  if not kind then
    U.log("WARN the nickname question never opened a naming grid")
    return false
  end

  if onGrid then pcall(onGrid, screen, kind) end

  if kind == "gen1" then
    if not M.typeOnGrid(game, name) then return false end
    local typed = table.concat(screen.glyphs)
    if typed ~= name then
      U.log("WARN the grid holds", typed, "not", name)
      return false
    end
    -- START is the confirm on Gen 1 (or the ED cell); the screen pops itself.
    U.tap(game, "start")
  else
    if not typeOnGen2Grid(game, screen, name) then return false end
    if screen.text ~= name then
      U.log("WARN Gold's grid holds", tostring(screen.text), "not", name)
      return false
    end
    -- Gold's START only parks the cursor on END; A on END is the confirm.
    U.tap(game, "start")
    U.wait(4)
    U.tap(game, "a")
  end
  U.wait(30)
  return true
end

-- The party's own copy of the mon of `species` -- what a driver asserts the
-- catch's paperwork against (nickname, OT, whatever else lands on it).
function M.partyMon(game, species)
  if g3(game) then
    local session = M.g3Session(game)
    local want = M.g3Species(game, species)
    for _, mon in ipairs((session and session.party) or {}) do
      if mon.species == want then return mon end
    end
    return nil
  end
  local party = game.save and game.save.party or {}
  for _, mon in ipairs(party) do
    if mon.species == species then return mon end
  end
  return nil
end

-- What the party is calling the mon of `species` -- its nickname when it has
-- one, so a driver can assert the name it just typed actually landed.
function M.partyNickname(game, species)
  local mon = M.partyMon(game, species)
  return mon and mon.nickname
end

-- Is this species marked in the #DEX -- `caught` on Gold, `owned` on Red,
-- the same pair src/Gen.lua stamps and reads back.
function M.dexOwned(game, species)
  -- Gen 3: the live session's dex, keyed by numeric species, read with the
  -- cart's own predicate (caught, which is what a trade or catch registers)
  if g3(game) then
    local session = M.g3Session(game)
    local Dex = g3mod("src.core.game3.dex")
    local id = M.g3Species(game, species)
    if not (session and type(session.dex) == "table" and Dex and id) then return nil end
    local ok, caught = pcall(Dex.isCaught, session.dex, id)
    return ok and caught == true
  end
  local dex = game.save and game.save.pokedex
  if type(dex) ~= "table" then return nil end
  local bag = dex.caught or dex.owned or {}
  return bag[species] and true or false
end

-- Listen for real ENGINE events, by subscribing rather than by wrapping emit.
--
-- M.captureEvents above counts emits by patching Runtime.emit, which is
-- enough for an event the engine fires unconditionally. It is not enough here:
-- an emitter that guards on Runtime.wants (this mod's caught announcement
-- does, and every hot engine site does) emits **nothing** when no listener is
-- subscribed -- so a counter that never subscribes measures its own absence.
-- This subscribes for real, which is also the thing worth proving: another
-- mod listening for `pokemon.caught` hears an MMO catch.
--
-- Returns two tables keyed by event name: how many arrived, and the last
-- payload of each.
function M.listenForEvents(names)
  local Runtime = require("src.mods.Runtime")
  local bus = Runtime.events
  local counts, last = {}, {}
  for _, name in ipairs(names) do counts[name] = 0 end
  if type(bus) ~= "table" or type(bus.on) ~= "function" then
    U.log("WARN no live mod event bus; engine events cannot be heard")
    return counts, last
  end
  for _, name in ipairs(names) do
    bus:on(name, function(payload)
      counts[name] = counts[name] + 1
      last[name] = payload
    end, 0, "mmo_e2e")
  end
  return counts, last
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
  -- host waits on the guest walking through the host's own tile first
  -- (non-blocking avatars), then walking up, reading the card and closing it
  guest_interact_done    = 300,  -- 60 walk-through + 60 facing + menu + card
  -- host waits on the guest pressing ADD FRIEND and dismissing the box it
  -- puts up -- one menu row and one text box, no round trip yet
  guest_asked_friend     =  90,  -- floor
  -- guest waits on the host answering the yes/no box the ask opened
  host_answered_friend   = 150,  -- 90 drivePrompts + closing back out
  -- host waits on the guest reading the answer back, then opening FRIENDS
  -- and PLAYERS and reopening the interact menu
  guest_friend_checked   = 240,  -- 45 propagate + three screens + shots
  -- guest waits on the host reopening the MMO menu and picking a new
  -- character through it -- no network round trip on this side of the
  -- barrier, just the host's own menu frames
  host_char_changed      = 150,  -- menus + a pick, same order as host_address_checked
  -- host waits on the guest's roster and avatar rows to pick up the new
  -- sprite (the hub broadcast, then the roster write and avatar respawn)
  guest_saw_char_change  =  90,  -- 45 propagate + margin
  -- host waits on the guest waiting for it to be free, then picking TRADE
  guest_trade_requested  = 120,  -- 45 free
  -- guest waits on the host driving its half of the trade
  host_trade_done        = 240,  -- 120 trade drive   <-- the one that broke
  -- host waits on the guest finishing its trade, then asking for a battle
  guest_battle_requested = 300,  -- 120 trade drive + 60 free
  -- guest waits on the host running a link battle to a decision
  host_battle_done       = 540,  -- 90 start + 240 run + transition

  -- ------- invite-refuse e2e (tests/drivers/run-invite-refuse-e2e.sh)
  --
  -- Host stages a real trainer battle, guest asks to battle via PLAYERS.
  -- The ask must be auto-refused; neither side should sit on a yes/no over
  -- the fight. Short barriers: both are already connected and on the map.
  host_in_fight                 = 120,
  guest_asked_battle_in_fight   = 180,
  guest_saw_battle_refusal      = 120,
  -- guest waits on the host re-opening the MMO menu
  host_address_checked   = 150,  -- menus only
  -- host waits on the guest leaving and proving the world still works
  -- 60 leave drive + walk test, and then the whole way back in: the menus,
  -- the address screen, six characters of passcode on a d-pad grid, a second
  -- handshake, and out again. Then a THIRD round trip, out and back through
  -- SERVERS instead of JOIN GAME's grids (M.reconnectViaServers) -- no
  -- passcode to type there, but still a menu walk, a connection to open (up
  -- to 60s of patience of its own) and a LEAVE to drive. And then a FOURTH
  -- pass through SERVERS on top of that, this one destructive: reopen the
  -- entry, DELETE it, wait for CONFIRM's choice box, photograph it, answer
  -- YES, then reopen the MMO menu a last time to prove the SERVERS row is
  -- gone with it -- menu walks and a handful of frame-budgeted waits only,
  -- no connection to open, but signalled after all of it. A ceiling, not an
  -- expectation -- the host is released the moment the guest signals -- so
  -- the headroom costs a healthy run nothing and stops a slow machine
  -- reporting "incomplete" for a leg that was about to pass.
  guest_left_game        = 690,

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
  -- b waits on a walking the PLAYERS menu and picking INVITE
  hub_a_party_asked      = 180,  -- menus
  -- each waits on the other reaching the far side of the members screen:
  -- forming the party, watching the flag land, and walking two menus
  hub_a_party            = 300,  -- 90 forming + 60 flag + menus
  hub_b_party            = 300,  -- the same
  -- b presses LEAVE; a only watches, so its budget is the menus b walks
  hub_a_partyleft        = 180,  -- menus + the confirm box
  hub_b_partyleft        = 180,  -- the same
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
  hub_b_left             = 300,

  -- ------- the co-op leg of the LAN scenario (tests/drivers/run-mmo-e2e.sh)
  --
  -- The other transport. Everything above rides the dedicated Node hub; this
  -- pair rides `src/Hub.lua`, running *inside* one of the two games. The
  -- co-op handlers there have unit tests and had never carried a real battle
  -- between two real clients.
  -- the host waits on the guest coming off the RANK screen and standing still
  guest_ready_for_party  = 180,  -- menus + closeToOverworld
  host_party_asked       = 180,  -- menus
  guest_party_joined     = 180,  -- the invite box + the flag
  host_ready_for_sight   = 180,  -- party formed; about to warp to Route 3
  guest_on_sight_map     = 240,  -- warp settle on the sight map
  host_coop_waiting      = 240,  -- sight bang + WAIT prompt
  guest_coop_joined      = 300,  -- sight bang + walk-in join
  host_coop_done         = 420,  -- a whole 2-on-2 driven by two tappers
  guest_coop_done        = 420,  -- the same
  host_coop_left         = 180,  -- leaving the party afterwards  -- 120 watching + menus + LEAVE

  -- ------- party-wild e2e (tests/drivers/run-party-wild-e2e.sh)
  --
  -- Party on the same map, host stages a wild via stageWild, partner
  -- auto-joins into mediated coop_wild, host throws MASTER_BALL to catch.
  host_wild_waiting      = 180,  -- stageWild + coop_wild wait box
  guest_wild_joined      = 240,  -- auto-join + three-slot field up
  host_wild_done         = 360,  -- ITEM throw + drain to Gotcha / grant
  guest_wild_done        = 360,  -- partner FIGHTs while host catches

  -- ------- the four-client scenario (tests/drivers/run-quad-e2e.sh)
  --
  -- Four guests, two parties, one 2-on-2 between them. Written without the
  -- role in the key: every barrier here comes in a set of four rather than a
  -- pair, and four identical rows differing only in a letter would be four
  -- places to forget to raise together. `patience` folds quad_<role>_<tag>
  -- onto quad_<tag>, so the budget lives once, next to the work.
  --
  -- Every budget here is larger than its two-client cousin for a reason that
  -- has nothing to do with the mod: four LOVE instances share a machine. Four
  -- windows compositing, four Lua VMs and four copies of the game's data on
  -- the same cores is a slower frame each, so the same work takes longer in
  -- wall-clock even when nothing is waiting on anything.
  quad_ready             = 900,  -- cold boot + menus + a code, times four
  quad_seen              = 240,  -- three peers to arrive on each roster
  quad_paired            = 420,  -- two invitations at once + both flags
  quad_refused           = 420,  -- menus + the ask out to three + one no back
  quad_agreed            = 480,  -- the same again, then four parties to a host
  quad_fought            = 900,  -- a whole 2-on-2 driven by four tappers
  quad_ranked            = 360,  -- the hub scoring two winners and two losers
  quad_left              = 300,  -- menus + LEAVE

  -- ------- six-client 3×3 PvP (tests/drivers/run-hex-e2e.sh)
  --
  -- Two parties of three, one 3-on-3 between them. Budgets are quad's plus
  -- slack for six LOVE VMs on one machine and two invite rounds per party.
  hex_ready              = 1200, -- cold boot + menus + a code, times six
  hex_seen               = 360,  -- five peers to arrive on each roster
  hex_paired             = 720,  -- two invites per party + both flags
  hex_agreed             = 720,  -- six-way yes + six parties to a host
  hex_fought             = 1200, -- a whole 3-on-3 driven by six tappers
  hex_ranked             = 480,  -- the hub scoring three winners and losers
  hex_left               = 360,  -- menus + LEAVE

  -- ------- party-size mismatch (tests/drivers/run-party-mismatch-e2e.sh)
  --
  -- Five guests: party of three vs party of two. The ask must refuse with
  -- spoken mismatch copy and clear without hanging.
  mismatch_ready         = 900,  -- cold boot + menus + a code, times five
  mismatch_seen          = 300,  -- four peers on each roster
  mismatch_paired        = 600,  -- grow a 3-party and a 2-party at once
  mismatch_challenged    = 240,  -- menus + the bad PARTY BATTLE row
  mismatch_cleared       = 240,  -- the mismatch line + ask cleared
  mismatch_left          = 300,  -- menus + LEAVE

  -- ------- three-client PvE (tests/drivers/run-trip-e2e.sh)
  --
  -- One party of three on the Node hub: coop_npc then coop_wild field legs.
  trip_ready             = 900,  -- cold boot + menus + a code, times three
  trip_seen              = 240,  -- two peers on each roster
  trip_party             = 480,  -- two invites + party-of-three flag
  trip_npc               = 600,  -- stage trainer + 3-wide coop_npc field
  trip_wild              = 600,  -- stage wild + 4-slot coop_wild field
  trip_left              = 300,  -- menus + LEAVE

  -- ------- Gen 3 in-game host + guest (tests/drivers/run-mmo-e2e-gen3.sh)
  --
  -- FireRed or Emerald on both sides, the host's own HostServer as the hub.
  -- Every leg is driven through the real menus, so the budgets are menu walks
  -- plus the d-pad typing a Gen 3 grid costs (a chat line is ~15 cells, each
  -- up to a dozen steps away) -- small in wall-clock, generous here because a
  -- generous barrier costs a healthy run nothing.
  -- host waits on the guest connecting (menus + address + a code) and walking
  g3_guest_walked          = 300,
  -- guest waits on the host's presence checks, nameplate and toast shots
  g3_host_walk_start       = 180,
  g3_guest_baseline        =  90,  -- floor
  g3_host_walk_done        = 120,  -- a few running steps
  -- each side types a chat line on the grid; the other waits for it
  g3_host_said             = 240,  -- MMO > SAY > EVERYONE + ~15 cells
  g3_guest_said            = 300,  -- the toast check + the same typing
  -- host waits on the guest walking PLAYERS > card > ADD FRIEND
  g3_guest_asked_friend    = 240,
  -- guest waits on the host answering the yes/no the ask opened
  g3_host_answered_friend  = 180,  -- 90 drivePrompts + closing out
  -- host waits on the guest's FRIENDS / PLAYERS / MY PROFILE / RANK shots
  g3_guest_social_done     = 360,
  -- guest waits on the host standing still for the interact leg
  g3_host_ready_for_interact = 180,
  -- host waits on the guest teleporting beside it and asking for a trade
  g3_guest_trade_requested = 240,
  -- each side's half of the trade (drivePrompts 150 + shots)
  g3_host_trade_done       = 300,
  g3_guest_trade_done      = 300,
  -- guest waits on the host back in the field for the invite
  g3_host_ready_for_party  = 180,
  -- host waits on the guest asking it to team up
  g3_guest_party_invited   = 180,
  -- guest waits on the host having answered and read its own members list
  g3_host_party_checked    = 240,
  -- host waits on the guest's MEMBERS / region map / PARTY > LEAVE
  g3_guest_party_done      = 360,
  -- host waits on the guest leaving the game through MAIN > LEAVE
  g3_guest_left            = 240,

  -- ------- Gen 3 battle legs (wave 5): two 1v1s, then the party's two 2v2s
  --
  -- Each 1v1 (`arena`: the host asks, on the 640x360 arena; `classic`: the
  -- guest asks, on the GBA page) is: both reseed a lead and say so, the asker
  -- stands beside the other and picks BATTLE, both drive the fight to its
  -- result and say so.  The `done` budgets cover the other side's whole fight
  -- (prompts, a few turns of typed lines, the writeback checks, the ranking
  -- round trip): generous, because a fight costs a healthy run only its own
  -- length.
  g3_host_arena_ready      = 240,  -- closing the trade + a reseed
  g3_guest_arena_ready     = 240,  -- the same, then the guest's own reseed
  g3_host_arena_done       = 540,
  g3_guest_arena_done      = 540,
  g3_host_classic_ready    = 240,
  g3_guest_classic_ready   = 240,
  g3_host_classic_done     = 540,
  g3_guest_classic_done    = 540,
  -- co-op, inside the party the party leg formed: both reseed and stand on
  -- the wild map's grass / beside the trainer, the walker walks, both fight
  g3_host_wild_ready       = 420,  -- the guest's MEMBERS + region map first
  g3_guest_wild_ready      = 300,
  g3_host_wild_done        = 600,  -- a grass walk (up to 3 min) + a 2v1 fight
  g3_guest_wild_done       = 600,
  g3_host_catch_ready      = 300,
  g3_guest_catch_ready     = 300,
  g3_host_catch_done       = 600,  -- a second grass walk + a ball thrown + the nickname grid
  g3_guest_catch_done      = 600,
  g3_host_trainer_ready    = 300,
  g3_guest_trainer_ready   = 300,
  g3_host_trainer_done     = 600,  -- a sight walk + a 2v2 fight + the flags
  g3_guest_trainer_done    = 600,

  -- ------- Gen 3 three-client run on the Node hub (run-trip-e2e-gen3.sh)
  --
  -- FireRed A and B in Pallet Town, Emerald C in Littleroot, all JOIN. One
  -- budget per tag; `patience` folds g3trip_<role>_<tag> onto g3trip_<tag>.
  g3trip_ready             = 900,  -- cold boot + menus + a code, times three
  g3trip_seen              = 240,  -- both peers on each roster
  g3trip_presence          = 300,  -- avatars / region scoping / PLAYERS
  g3trip_chat              = 360,  -- menus + a typed line, then the toasts
  g3trip_traded            = 420,  -- menus + a cross-version trade
  g3trip_fightready        = 300,  -- closing the trade + a reseed
  g3trip_fought            = 600,  -- prompts + a whole fight + the writeback checks
  g3trip_left              = 300,  -- menus + LEAVE

  -- ------- Gen 3 generation mismatch (run-mismatch-e2e-gen3.sh)
  g3mismatch_done          = 600,
}

local SYNC_DIR = os.getenv("MMO_SYNC_DIR") or "/tmp/rby_mmo_sync"

-- when this side last crossed a barrier, so signal() can say how long the
-- segment it just finished actually took
local phaseClock = os.time()

function M.syncPath(name)
  return SYNC_DIR .. "/" .. name
end

function M.patience(name)
  if PHASE[name] then return PHASE[name] end
  -- A four-client barrier is named per role -- quad_c_fought -- but budgeted
  -- once. Four rows differing only in a letter would be four places to forget
  -- to raise together, and the first one forgotten is a run reporting
  -- "incomplete" about a leg that was working.
  local shared = name:match("^quad_%a_(.+)$")
  if shared and PHASE["quad_" .. shared] then return PHASE["quad_" .. shared] end
  shared = name:match("^hex_%a_(.+)$")
  if shared and PHASE["hex_" .. shared] then return PHASE["hex_" .. shared] end
  shared = name:match("^mismatch_%a_(.+)$")
  if shared and PHASE["mismatch_" .. shared] then return PHASE["mismatch_" .. shared] end
  shared = name:match("^trip_%a_(.+)$")
  if shared and PHASE["trip_" .. shared] then return PHASE["trip_" .. shared] end
  shared = name:match("^g3trip_%a_(.+)$")
  if shared and PHASE["g3trip_" .. shared] then return PHASE["g3trip_" .. shared] end
  return 180
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
--
-- `sample`, if given, is called on every poll tick while the barrier is
-- still open -- for a caller that needs to observe something on the far
-- side of the wire during exactly the window a barrier already bounds,
-- rather than only at the moment it clears. Optional and side-effecting
-- only: it does not change whether or how long this waits.
function M.await(game, name, seconds, sample)
  seconds = seconds or M.patience(name)
  local spent
  local ok = M.waitSeconds(game, function()
    if sample then sample() end
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

-- Live overworld controller: Gen 1 keeps it on the stack (and as
-- game.overworld); Gen 2 free-roam is an empty stack with game.world only.
function M.overworld(game)
  if not game then return nil end
  local stack = game.stack and game.stack.states
  if type(stack) == "table" then
    for i = #stack, 1, -1 do
      if stack[i] and stack[i].isOverworld then return stack[i] end
    end
  end
  return game.overworld or game.world
end

-- True when the player can open START / walk: Gen 1 overworld-on-top, or
-- Gen 2 empty stack with a loaded map (POKEPORT_DRIVER skips Gold cinema).
function M.inPlay(game)
  if not game then return false end
  if g3(game) then return M.g3Idle(game) end
  local ow = M.overworld(game)
  if not (ow and ow.map and ow.player) then return false end
  local top = M.top(game)
  if top == nil then return true end
  if top == ow or top.isOverworld then return true end
  return false
end

function M.generation(game)
  local ok, Handshake = pcall(require, "src.link.Handshake")
  if ok and Handshake and type(Handshake.generation) == "function" then
    return tonumber(Handshake.generation(game)) or 1
  end
  local data = game and game.data
  if data and data.gen2Statuses then return 2 end
  if data and data.type_chart and tonumber(data.type_chart.generation) == 2 then
    return 2
  end
  return 1
end

-- Walk the new-game intro to the overworld, and say so if it does not arrive.
--
-- This is `tests/drivers/util.lua`'s `U.newGame` with the two properties that
-- file cannot give it from where it sits.
--
-- **A budget that is not a guess.** `U.newGame` mashes A up to 400 times and
-- then returns whatever happened.  Measured on 2026-08-18 against engine `dev`,
-- the Gen 1 intro -- title, Oak's speech, YOUR NAME?, HIS NAME?, the shrink
-- beat -- needs **441**.  It outgrew the budget by about a tenth, so every MMO
-- driver was being handed a game still sitting in Oak's speech.
--
-- **A failure that says so.** That is the half that actually cost the day.
-- `U.newGame` returns nothing, so the caller walked on, read `game.save` (which
-- exists the whole time, seeded by the driver itself) and logged "in the
-- overworld as HOSTY with CHARIZARD" -- while OakSpeech was on screen.  The
-- first symptom came three steps later as `TIMEOUT waiting for menu row MMO`,
-- which reads exactly like a broken start-menu hook and sent the investigation
-- to the wrong file.  A driver that cannot reach the overworld has to say
-- *that*, at the moment it happens.
--
-- The budget below is ~3x the measured cost, not 1.1x, precisely because the
-- last one was set to the intro's length on the day it was written.  It costs
-- nothing on a healthy run: the loop stops the frame the overworld is on top.
M.INTRO_A_TAPS = 1500

function M.newGame(game, tag)
  -- Gen 3 has no intro to mash through: the title's own new-game action
  if g3(game) then return M.g3BootToPlay(game, { name = "PLAYER" }) end
  U.wait(5)
  U.tap(game, "start")             -- skip the intro movie
  U.wait(10)

  local title = M.top(game)
  for _ = 1, 90 do
    U.tap(game, "a")
    U.wait(5)
    if M.top(game) ~= title then break end
  end

  -- CONTINUE may or may not be on the menu; NEW GAME is first without a save.
  U.tap(game, "a")
  U.wait(10)

  for _ = 1, M.INTRO_A_TAPS do
    U.tap(game, "a")
    U.wait(2)
    if game.overworld and M.top(game) == game.overworld then
      U.wait(10)
      return true
    end
  end

  U.log(tag or "DRIVER",
    "FAIL the new-game intro never reached the overworld in "
    .. M.INTRO_A_TAPS .. " A taps -- still on: " .. M.stackNames(game))
  return false
end

-- Reach a playable overworld without thrashing an open Start menu.
--
-- Gen 2 + POKEPORT_DRIVER already lands in free-roam (empty stack). Gen 1
-- still needs U.newGame. Never mash A while StartMenu.list is up -- that is
-- how PACK flash-loops happen in a LOVE window.
function M.bootToPlay(game, opts)
  if g3(game) then return M.g3BootToPlay(game, opts) end
  U.wait(20)
  if M.inPlay(game) then return true end
  if M.generation(game) == 2 then
    for _ = 1, 600 do
      if M.inPlay(game) then
        U.wait(10)
        return true
      end
      local top = M.top(game)
      if top and top.list ~= nil and type(top.onClose) == "function" then
        U.tap(game, "b")
        U.wait(4)
      else
        U.tap(game, "a")
        U.wait(2)
      end
    end
    return M.inPlay(game)
  end
  M.newGame(game)
  return M.inPlay(game)
end

-- Seed a one-mon party the e2e can trade / fight with. Gen 2 uses Mon.new
-- (spa/spd sheets); Gen 1 keeps Pokemon.new.
function M.seedParty(game, species, level)
  if g3(game) then return M.g3SeedParty(game, species, level) end
  if not (game and game.save and game.data) then return nil end
  level = level or 50
  if M.generation(game) == 2 then
    local ok, Mon = pcall(require, "src.battle.gen2.Mon")
    if not (ok and Mon and type(Mon.new) == "function") then return nil end
    local mon = Mon.new(game.data, species, level)
    if not mon then return nil end
    game.save.party = { mon }
    return mon
  end
  local Pokemon = require("src.pokemon.Pokemon")
  local mon = Pokemon.new(game.data, species, level)
  game.save.party = { mon }
  return mon
end

-- this game's own player cell
function M.playerCell(game)
  if g3(game) then
    local Player = package.loaded["src.core.game3.player"]
    local Map = package.loaded["src.core.game3.map"]
    local session = M.g3Session(game)
    if not Player then return nil end
    local mapId = (Map and type(Map.current) == "string" and Map.current)
      or (session and session.map)
    return { mapId = mapId, x = Player.cellX, y = Player.cellY }
  end
  local ow = M.overworld(game)
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
  local ow = M.overworld(game)
  return ow and ow.player and ow.player.sprite or nil
end

-- Whether the live player is genuinely drawn as their standing choice --
-- by which sheet it draws from, not by object identity.
--
-- Client.applyLook (src/Client.lua) builds a brand-new SpriteRenderer every
-- time it runs, and it runs on every connect, every map change and every
-- disconnect now that the look survives leaving -- so two snapshots of the
-- very same character are never `==`, and a driver that compared identity
-- was only ever proving "a renderer was rebuilt", which is true whether or
-- not the character actually changed. What identifies a look is the sheet
-- path it draws from, which is stable across rebuilds of the same
-- character. mmo_host.lua's own-look check (its "the local player wears
-- the chosen character" leg) reads this straight off game.data.sprites, the
-- same catalog Client.lua reaches through mod.content.sprites -- reachable
-- here because a driver runs inside the engine process, behind no mod
-- facade.
--
-- Returns (matches, wornLook, wornImage): the id and image path are handed
-- back too so a caller can log what it actually saw, match or not.
function M.wornMatches(game, exports)
  local wornLook = exports and exports.wornLook and exports.wornLook() or nil
  if wornLook == nil then return false, nil, nil end
  -- Gen 3: a look is an OBJ_EVENT_GFX_* name, and what the player is drawn
  -- as is the graphics id the engine's OwSprites hands the field renderer --
  -- compared through this cart's own constants, the same resolution the mod
  -- applies when it wears the look.
  if g3(game) then
    local OwSprites = g3mod("src.core.game3.ow_sprites")
    local gid
    if OwSprites and type(OwSprites.playerGraphicsId) == "function" then
      local ok, value = pcall(OwSprites.playerGraphicsId, game)
      if ok then gid = value end
    end
    local want = M.g3Const(game, "event_objects", wornLook)
    return want ~= nil and gid == want, wornLook, gid
  end
  local record = game.data and game.data.sprites and game.data.sprites[wornLook]
  local worn = M.playerSheet(game)
  local wornImage = worn and (worn.def and worn.def.image or worn.image) or nil
  local ok = record ~= nil and wornImage ~= nil
    and tostring(wornImage):find(tostring(record.image), 1, true) ~= nil
  return ok, wornLook, wornImage
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

-- PROTOCOL 10 mediated 1v1 screen (src/MediatedBattle.lua). Not a BattleState:
-- no `.enemy`, no engine `battle.started` / `battle.ended`, no link.desync.
-- The marker Sessions.isFightState already keys on is what the drivers wait for.
function M.isMediatedBattle(top)
  return top ~= nil and top.mmoBattle == true
end

-- True while a mediated fight is on the stack or the session still holds it.
function M.inMediatedFight(game, exports)
  if M.isMediatedBattle(M.top(game)) then return true end
  if exports and exports.isFighting and exports.isFighting() then return true end
  return false
end

-- PROTOCOL 10 mediated 2-on-2 (src/CoopBattle.lua once mmo.battle_ready lands).
--
-- The screen still has `.sim` for drawing -- that is not the host running
-- CoopSim rolls. The referee flag is `.mediated`, set only by battle_ready,
-- and co-op battle ids on both hubs are `c` + n. Without this check a
-- Party-vs-NPC e2e can green while every roll still happened on the host.
function M.isMediatedCoop(top)
  if not (top and top.sim and top.mediated == true) then return false end
  local id = tostring(top.battleId or "")
  return id:match("^c") ~= nil
end

-- Wait until the hub has refereed the co-op field (optional mode pin).
function M.awaitMediatedCoop(game, seconds, wantMode)
  return M.waitSeconds(game, function()
    local top = M.top(game)
    if not M.isMediatedCoop(top) then return false end
    if wantMode and top.mode ~= wantMode then return false end
    return true
  end, seconds or 60, "the hub to referee the 2-on-2")
end

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
    -- Gen 3: a Gen3Ui text box with its YES / NO open exposes `items` (the
    -- driver contract), so it classifies as a menu -- and one opened with
    -- defaultNo would be answered NO by the menu branch's plain A. Walk the
    -- cursor onto YES first, the way the choice branch does.
    if g3(game) and kind == "menu" and top.kind == "text" and top.choosing then
      local guard = 0
      while M.top(game) == top and (top.index or 1) > 1 and guard < 4 do
        U.tap(game, "up")
        U.wait(3)
        guard = guard + 1
      end
    end
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
  -- Gen 3 party mons carry numeric move ids (Gen 1 / Gen 2 carry tables):
  -- power is read off the cart's own move rows, and moves / pp / maxPp move
  -- together.
  if type(mon) == "table" and type((mon.moves or {})[1]) == "number" then
    return M.g3FrontloadDamage(mon)
  end
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
  if g3(game) then
    local session = M.g3Session(game)
    for _, mon in ipairs((session and session.party) or {}) do
      out[#out + 1] = tostring(mon.species)
    end
    return out
  end
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

-- The trainer a co-op leg fights, chosen the same way on every instance.
--
-- The weakest trainer with at least two POKeMON, with the id as the tiebreak
-- so two processes reading the same dataset land on the same trainer without
-- talking to each other. Weakest because a co-op leg is a test of the
-- machinery around a battle rather than of the battle. One-monster trainers
-- are a valid product path (three-seat field) and are covered in the Lua
-- suite; e2e keeps the full 2v2 so SWITCH/ITEM and four-slot asserts stay
-- meaningful.
--
-- Gen 2 trainers live under data.trainers.classes[*].trainers[*].party (see
-- engine src/world/gen2/Trainers.lua). Return the class id string so
-- stageTrainer can look the class up and pick its weakest 2+ party member.
function M.coopTrainer(data)
  -- Gen 3 (Game3:load stamps `data.generation = 3`): the cart's own trainer
  -- book, by trainer id.
  if type(data) == "table" and data.generation == 3 then return M.g3CoopTrainer(data) end
  local classes = data and data.trainers and data.trainers.classes
  if type(classes) == "table" then
    local best
    for classId, class in pairs(classes) do
      if type(class) == "table" and type(class.trainers) == "table" then
        for _, row in ipairs(class.trainers) do
          local party = row and row.party
          if party and #party >= 2 then
            local total = 0
            for _, spec in ipairs(party) do
              total = total + (spec.level or 0)
            end
            if best == nil or total < best.total
               or (total == best.total and tostring(classId) < best.id) then
              best = { id = tostring(classId), total = total }
            end
          end
        end
      end
    end
    return best and best.id, best and best.total
  end
  local best
  for id, record in pairs(data.trainers or {}) do
    local party = record.parties and record.parties[1]
    if party and #party >= 2 then
      local total = 0
      for _, spec in ipairs(party) do total = total + (spec.level or 0) end
      if best == nil or total < best.total
         or (total == best.total and id < best.id) then
        best = { id = id, total = total }
      end
    end
  end
  return best and best.id, best and best.total
end

local function softenPartyHp(party)
  for _, mon in ipairs(party or {}) do
    local max = (mon.stats and mon.stats.hp) or mon.maxHp or 4
    mon.hp = math.max(1, math.floor(max / 4))
  end
end

local function isGen2Staging(game)
  if M.generation(game) == 2 then return true end
  local data = game and game.data
  if data and data.type_chart and tonumber(data.type_chart.generation) == 2 then
    return true
  end
  local ok = pcall(require, "src.ui.gen2.BattleState")
  if ok and data and data.trainers and data.trainers.classes then
    return true
  end
  return false
end

-- Pick the weakest Gen 2 class member with #party >= 2 (fallback: member 1).
local function gen2TrainerMember(classRec)
  local bestIdx, bestTotal
  for i, row in ipairs((classRec and classRec.trainers) or {}) do
    local party = row and row.party
    if party and #party >= 2 then
      local total = 0
      for _, spec in ipairs(party) do total = total + (spec.level or 0) end
      if bestIdx == nil or total < bestTotal then
        bestIdx, bestTotal = i, total
      end
    end
  end
  return bestIdx or 1
end

-- Put a real trainer battle on the stack, the way the overworld does.
--
-- Softened, not gutted: the engine's trainers are built for a full playthrough
-- and these drivers carry a starter, so without this a leg would be a
-- twenty-minute battle rather than a test of the machinery around one. A
-- quarter of full health still dies to one hit and still *looks* like a
-- monster that is alive -- exactly 1 HP drew both enemy bars empty, which
-- reads on a screenshot as a broken bar rather than a weakened opponent.
--
-- `onFinish` is attached here because the callers of newTrainer are what
-- normally attach it -- the overworld hangs the defeated flag and the rewards
-- on it -- and it is what lets a co-op leg assert the battle it displaced was
-- told how it went.
--
-- Gen 2: build via battle.gen2.Battle + Screens.push Gen2BattleState (onDone),
-- then stamp Gen1-shaped kind/oppClass/enemyParty/onFinish so Client/Coop
-- divert predicates see the same surface they do on Red.
function M.stageTrainer(game, class, onFinish)
  -- Gen 3: no state to push -- the cart's trainerbattle opcode calls
  -- BattleBridge.start with the foe the trainer book resolves, and the mod's
  -- divert is a wrap of exactly that call.  `class` is a trainer id
  -- (M.coopTrainer); `onFinish(result)` is the opcode's own `done`.
  if g3(game) then
    local BB = g3mod("src.core.game3.battle_bridge")
    local Trainers = g3mod("src.core.game3.scripting.trainers")
    local Runtime = g3mod("src.core.game3.runtime")
    local tid = tonumber(class)
    if not (BB and Trainers and Runtime and tid) then return nil end
    local okF, foe = pcall(Trainers.foeFromId, tid)
    if not (okF and type(foe) == "table") then return nil end
    local ok, started = pcall(BB.start, Runtime._mod, Runtime._game or game, foe, {
      wild = false, trainerId = tid, defeatText = foe.defeatText,
      victoryText = foe.victoryText, trainerName = foe.trainerName,
      trainerPicId = foe.trainerPicId,
      done = function(result) if onFinish then onFinish(result) end end,
    })
    if not (ok and started ~= false) then return nil end
    return { g3Staged = true, kind = "trainer", trainerId = tid, foe = foe }
  end
  if isGen2Staging(game) then
    local okB, Battle = pcall(require, "src.battle.gen2.Battle")
    local okT, Trainers = pcall(require, "src.world.gen2.Trainers")
    local okS, Screens = pcall(require, "src.ui.Screens")
    if not (okB and Battle and okT and Trainers and okS and Screens) then
      return nil
    end
    local data = game.data or {}
    local classes = data.trainers and data.trainers.classes
    local classRec = classes and classes[class]
    if not classRec and type(class) == "number" then
      classRec = Trainers.classIndex(data.trainers)[class]
    end
    if not classRec then return nil end
    local member = gen2TrainerMember(classRec)
    local entry = Trainers.lookup(data.trainers, classRec.index, member)
    if not entry then return nil end
    local party = Trainers.party(data, entry)
    if not (party and #party > 0) then return nil end
    softenPartyHp(party)
    local trainer = {
      class = entry.class,
      classId = entry.classId,
      memberId = entry.id,
      name = entry.name,
      className = entry.className,
      party = party,
      baseMoney = entry.baseMoney,
      attributes = entry.attributes,
      items = entry.items,
    }
    local battle = Battle.new({
      data = data,
      party = (game.save and game.save.party) or {},
      trainer = trainer,
      save = game.save,
    })
    local onDone = onFinish and function(outcome)
      onFinish(outcome)
    end or nil
    local state = Screens.push(game, "Gen2BattleState", {
      battle = battle,
      save = game.save,
      onDone = onDone,
    })
    state = state or (game.stack and game.stack:top())
    if not state then return nil end
    state.kind = "trainer"
    state.oppClass = trainer.classId or trainer.class
    state.enemyParty = battle.enemyParty or party
    state.trainer = trainer
    state.onDone = state.onDone or onDone
    state.onFinish = state.onFinish or onFinish or state.onDone
    return state
  end
  local BattleState = require("src.battle.BattleState")
  local ok, battle = pcall(BattleState.newTrainer, game, class, 1)
  if not (ok and battle) then return nil end
  softenPartyHp(battle.enemyParty)
  battle.onFinish = onFinish
  game.stack:push(battle)
  return battle
end

-- ------- sight-trainer co-op (Route 3 walk-in)
--
-- LAN e2e used to stageTrainer + invite-join. That never showed a "!" and the
-- joiner rematch asserts were vacuous. These helpers warp onto a real sight
-- line, wait for the emotion bubble, soften the engine party, and prove the
-- overworld stays on top after co-op (no buried FIGHT UI).

local SIGHT_FACING = {
  DOWN = "down", UP = "up", LEFT = "left", RIGHT = "right",
}
local SIGHT_OPPOSITE = {
  up = "down", down = "up", left = "right", right = "left",
}
local SIGHT_DIR = {
  up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 },
}

-- First STAY trainer on the map with a facing range and a party of 2+.
-- Route 3's first hit is ROUTE3_YOUNGSTER1 (Bug Catcher, range RIGHT).
function M.sightTrainerOn(data, mapId)
  local map = data and data.maps and data.maps[mapId]
  if not map then return nil end
  for _, obj in ipairs(map.objects or {}) do
    if obj.movement == "STAY" and obj.trainerClass
        and obj.range and obj.range ~= "NONE"
        and type(obj.x) == "number" and type(obj.y) == "number" then
      local rec = data.trainers and data.trainers[obj.trainerClass]
      local party = rec and rec.parties and rec.parties[obj.trainerParty or 1]
      if party and #party >= 2 then
        return obj
      end
    end
  end
  return nil
end

function M.sightNpcId(mapId, obj)
  if not (mapId and obj and obj.index) then return nil end
  return string.format("%s_obj_%d", mapId, obj.index)
end

function M.findNpcByName(game, name)
  local ow = game and game.overworld
  if not (ow and name) then return nil end
  for _, npc in ipairs(ow.npcs or {}) do
    if npc.def and npc.def.name == name then return npc end
  end
  for _, npc in pairs(ow.npcPool or {}) do
    if type(npc) == "table" and npc.def and npc.def.name == name then
      return npc
    end
  end
  return nil
end

-- The live Coop instance, via an export closure upvalue. Drivers need it only
-- to dismiss a same-map invite box *without* COOP_CANCEL so a walk-in can
-- still adopt the buried engine (considerOffer otherwise steals the confirm
-- before checkTrainerSight can fire).
function M.coopInstance(game)
  local exports = M.exports(game)
  local fn = exports and exports.coopOffer
  if type(fn) ~= "function" or not debug or not debug.getupvalue then
    return nil
  end
  local i = 1
  while true do
    local name, val = debug.getupvalue(fn, i)
    if not name then break end
    if name == "coop" then return val end
    i = i + 1
  end
  return nil
end

-- Drop the invite-path confirm without telling the waiter the partner said no.
--
-- Round 9 deleted the confirm this used to dismiss -- `coop.joinAsk` and
-- `coop:closeJoinBox` are both gone from src/Coop.lua (offers are taken
-- automatically now, with no box left for a walk-in to race). Left as an
-- explicit no-op rather than removed outright: callers already treat `false`
-- as "nothing to dismiss," which is now unconditionally the truth.
function M.dismissInviteForWalkIn(game) -- luacheck: ignore game
  return false
end

-- Warp onto (or beside) the trainer's facing line. `behind` steps further
-- along the line; `side` offsets perpendicular so the landing cell is not
-- already inside another STAY trainer's cone (Route 3's (14,6) is both
-- Bug Catcher RIGHT@2 *and* Youngster2 DOWN).
function M.warpToSightLine(game, mapId, obj, opts)
  opts = opts or {}
  if not (game and game.overworld and mapId and obj) then return nil end
  local facing = SIGHT_FACING[obj.range] or "down"
  local vec = SIGHT_DIR[facing]
  if not vec then return nil end
  local dist = opts.dist or 2
  local behind = opts.behind or 0
  local side = opts.side or 0
  -- Perpendicular: RIGHT/LEFT → north/south; UP/DOWN → east/west.
  local perp = { -vec[2], vec[1] }
  local x = obj.x + vec[1] * (dist + behind) + perp[1] * side
  local y = obj.y + vec[2] * (dist + behind) + perp[2] * side
  local look = SIGHT_OPPOSITE[facing] or "down"
  game.overworld:startWarpTo(mapId, x, y, look)
  return {
    x = x, y = y, facing = look, lineFacing = facing,
    dist = dist, lineX = obj.x + vec[1] * dist, lineY = obj.y + vec[2] * dist,
  }
end

function M.awaitOnMap(game, mapId, seconds)
  return M.waitSeconds(game, function()
    local ow = game.overworld
    if not (ow and ow.map and ow.map.id == mapId) then return false end
    if ow.transitioning then return false end
    -- Map id is enough: a same-frame TextBox / remote overlay must not fail
    -- the arrival barrier (guest previously timed out while already on ROUTE_3).
    return true
  end, seconds or 90, "arrive on " .. tostring(mapId))
end

function M.awaitTrainerBang(game, seconds)
  return M.waitSeconds(game, function()
    local ow = game.overworld
    if ow and ow.emote and ow.emote.npc then return true end
    -- Bubble already spent: walk-up, battle text, or BattleState.
    if ow and ow.engaging then return true end
    local top = M.top(game)
    if top and top.kind == "trainer" then return true end
    return false
  end, seconds or 30, "trainer ! emote")
end

-- Step onto the named trainer's sight cell, then force that NPC's approach
-- so a neighbouring cone cannot steal the engage.
function M.walkIntoTrainerSight(game, obj, opts)
  opts = opts or {}
  local ow = game.overworld
  if not (ow and obj) then return false end
  local facing = SIGHT_FACING[obj.range] or "down"
  local vec = SIGHT_DIR[facing]
  local dist = opts.dist or 2
  local lineX = obj.x + (vec and vec[1] or 0) * dist
  local lineY = obj.y + (vec and vec[2] or 0) * dist

  for _ = 1, 12 do
    if ow.emote and ow.emote.npc then return true end
    if ow.engaging then return true end
    local top = M.top(game)
    if top and top.kind == "trainer" then return true end
    local p = ow.player
    if p and p.cellX == lineX and p.cellY == lineY then
      break
    end
    local dir = nil
    if p then
      if p.cellX < lineX then dir = "right"
      elseif p.cellX > lineX then dir = "left"
      elseif p.cellY < lineY then dir = "down"
      elseif p.cellY > lineY then dir = "up"
      end
    end
    if dir then U.hold(game, dir, 18) end
    U.wait(8)
  end

  local npc = M.findNpcByName(game, obj.name)
  if npc and ow.startTrainerApproach and not ow.engaging
      and not (ow.emote and ow.emote.npc) then
    local p = ow.player
    local along = 1
    if p then
      along = math.max(1, math.abs(p.cellX - npc.cellX) + math.abs(p.cellY - npc.cellY))
    end
    ow:startTrainerApproach(npc, math.min(along, dist))
  end
  return M.awaitTrainerBang(game, opts.bangSeconds or 20)
end

function M.softenTopTrainer(game)
  local function soften(battle)
    if not (battle and battle.enemyParty) then return false end
    for _, mon in ipairs(battle.enemyParty) do
      mon.hp = math.max(1, math.floor((mon.stats and mon.stats.hp or 4) / 4))
    end
    return true
  end
  local top = M.top(game)
  if soften(top) then return true end
  for _, state in ipairs((game.stack and game.stack.states) or {}) do
    if state and state.kind == "trainer" and soften(state) then
      return true
    end
  end
  return false
end

function M.captureStagedTrainer(game)
  for _, state in ipairs((game.stack and game.stack.states) or {}) do
    if state and state.kind == "trainer" then return state end
  end
  return nil
end

function M.wrapBattleFinish(battle, sink)
  if not battle then return end
  local prev = battle.onFinish
  battle.onFinish = function(result)
    if type(sink) == "function" then sink(result) end
    if type(prev) == "function" then return prev(result) end
  end
end

-- After co-op: overworld on top, no buried trainer BattleState, defeated flag.
function M.assertNoRematch(game, npcId, frames, check)
  frames = frames or 120
  local buried = false
  local leftOverworld = false
  for _ = 1, frames do
    local top = M.top(game)
    if not (top == game.overworld or (top and top.isOverworld) == true) then
      leftOverworld = true
    end
    for _, state in ipairs((game.stack and game.stack.states) or {}) do
      if state and state.kind == "trainer" then
        buried = true
      end
    end
    U.wait(1)
  end
  local defeated = game.save and game.save.defeatedTrainers
      and npcId and game.save.defeatedTrainers[npcId] == true
  check(not leftOverworld,
        "overworld stayed on top after co-op (no immediate rematch UI)")
  check(not buried,
        "no trainer BattleState left buried under the overworld")
  check(defeated == true,
        "defeatedTrainers marks the sighted npc beaten")
  return not leftOverworld and not buried and defeated == true
end

-- Put a real wild battle on the stack, the way grass does.
--
-- StateStack:push emits screen.pushed, which is what src/Client.lua listens
-- for to call Coop:onWildEncounter when partied and on the same map. There is
-- no headless force-grass seam in the engine, so e2e stages the encounter
-- directly rather than walking Route 1 until RNG cooperates.
function M.stageWild(game, species, level, onFinish)
  species = species or "PIDGEY"
  level = level or 5
  -- Gen 3: a scripted wild battle -- the cart's own startWild entry, which the
  -- mod's BattleBridge.start wrap diverts the way it diverts a trainer.  (The
  -- co-op leg walks the grass for the `encounter.roll` door; this is the
  -- deterministic one for a leg that needs a chosen species.)
  if g3(game) then
    local BB = g3mod("src.core.game3.battle_bridge")
    local Runtime = g3mod("src.core.game3.runtime")
    local id = M.g3Species(game, species)
    if not (BB and Runtime and id) then return nil end
    local ok, started = pcall(BB.startWild, Runtime._mod, Runtime._game or game,
      { species = id, level = level },
      { done = function(result) if onFinish then onFinish(result) end end })
    if not (ok and started ~= false) then return nil end
    return { g3Staged = true, kind = "wild", species = id, level = level }
  end
  if isGen2Staging(game) then
    local okB, Battle = pcall(require, "src.battle.gen2.Battle")
    local okM, Mon = pcall(require, "src.battle.gen2.Mon")
    local okS, Screens = pcall(require, "src.ui.Screens")
    if not (okB and Battle and okM and Mon and okS and Screens) then
      return nil
    end
    local data = game.data or {}
    local wild = Mon.new(data, species, level)
    if not wild then return nil end
    softenPartyHp({ wild })
    local battle = Battle.new({
      data = data,
      party = (game.save and game.save.party) or {},
      wild = wild,
      save = game.save,
    })
    local onDone = onFinish and function(outcome)
      onFinish(outcome)
    end or nil
    local state = Screens.push(game, "Gen2BattleState", {
      battle = battle,
      save = game.save,
      onDone = onDone,
    })
    state = state or (game.stack and game.stack:top())
    if not state then return nil end
    state.kind = "wild"
    state.enemyParty = battle.enemyParty or { wild }
    state.onDone = state.onDone or onDone
    state.onFinish = state.onFinish or onFinish or state.onDone
    return state
  end
  local BattleState = require("src.battle.BattleState")
  local ok, battle = pcall(BattleState.newWild, game, species, level)
  if not (ok and battle and not battle.dead) then return nil end
  local mon = battle.enemy and battle.enemy.mon
  if mon then
    mon.hp = math.max(1, math.floor((mon.stats and mon.stats.hp or 4) / 4))
  end
  battle.onFinish = onFinish
  game.stack:push(battle)
  return battle
end

-- Drop the player onto a map. Gen 1 still uses U.teleport (pushes
-- OverworldController). Gen 2 must not -- Gold's World hangs off game.world
-- and is not a stack state; pushing the Gen 1 controller breaks free-roam.
function M.teleport(game, mapId, x, y, facing)
  facing = facing or "down"
  if g3(game) then return M.g3Teleport(game, mapId, x, y, facing) end
  if M.generation(game) ~= 2 then
    U.teleport(game, mapId, x, y, facing)
    return true
  end
  local okApi, WorldAPI = pcall(require, "src.world.gen2.WorldAPI")
  if okApi and WorldAPI and WorldAPI.new then
    local api = WorldAPI.new(game, "rby_mmo")
    local ok = api:warpTo(mapId, x, y, facing)
    if ok then
      U.wait(5)
      return true
    end
  end
  local ow = M.overworld(game)
  if ow and type(ow.setMap) == "function" then
    local ok = pcall(ow.setMap, ow, mapId, x, y, facing)
    if ok then
      U.wait(5)
      return true
    end
  end
  if ow and ow.player then
    if ow.map and ow.map.id == mapId then
      ow.player.cellX, ow.player.cellY = x, y
      ow.player.facing = facing
      U.wait(5)
      return true
    end
  end
  return false
end

-- Put a battle-usable item in the live bag (and clear the battle item cache).
-- Call before the mediated bag sheet is uploaded so the hub sees the count.
function M.giveItem(game, itemId, count)
  if g3(game) then return M.g3GiveItem(game, itemId, count) end
  if not (game and game.save and type(itemId) == "string") then return false end
  game.save.inventory = game.save.inventory or {}
  game.save.inventory[itemId] = (game.save.inventory[itemId] or 0)
    + (count or 1)
  local top = M.top(game)
  if top and top.itemList ~= nil then top.itemList = nil end
  return true
end

-- Count party mons matching a species id (or total party size when species is nil).
function M.partySpeciesCount(game, species)
  if g3(game) then
    local session = M.g3Session(game)
    local party = (session and session.party) or {}
    if species == nil then return #party end
    local want, n = M.g3Species(game, species), 0
    for _, mon in ipairs(party) do
      if mon and mon.species == want then n = n + 1 end
    end
    return n
  end
  local party = game and game.save and game.save.party or {}
  if species == nil then return #party end
  local n = 0
  for _, mon in ipairs(party) do
    if mon and mon.species == species then n = n + 1 end
  end
  return n
end

-- Command grid: FIGHT SWITCH / ITEM RUN. The battlefield band lays the four
-- commands in ONE row (Battlefield.bandGridCols == 4), so ITEM is two RIGHTs
-- from FIGHT there; the classic 2x2 keeps ITEM one DOWN. Ask the screen for
-- its live column count rather than assuming a shape -- the D-wave made draw
-- and navigation share it, and this helper walking the wrong grid is exactly
-- how the round-2 band silently broke the catch flow.
-- Another A commits the highlighted row. Balls need no party pick.
-- Prefer an empty-ish bag so the first row is the item under test.
function M.throwBattleItem(game, itemId)
  -- Gen 3: the command list names its own rows (M.COMMANDS3 on a co-op
  -- screen, commandList() on the 1v1), so ITEM is found by name, and the bag
  -- list is matched on the cart's numeric item id.
  if g3(game) then
    local top = M.g3Fight(game)
    if not (top and top.phase == "choose") then return false end
    local list = type(top.commandList) == "function" and top:commandList() or { "FIGHT", "ITEM" }
    for i, name in ipairs(list) do
      if name == "ITEM" then top.commandIndex = i end
    end
    U.tap(game, "a")
    U.wait(10)
    top = M.g3Fight(game)
    if not (top and top.phase == "item") then return false end
    local want = M.g3ItemId(game, itemId)
    local items = type(top.usableItems) == "function" and top:usableItems() or {}
    local at = 1
    for i, row in ipairs(items) do
      if want ~= nil and row.id == want then at = i break end
    end
    top.itemIndex = at
    U.tap(game, "a")
    U.wait(20)
    -- a heal asks whom (the first row is the lead); a ball is committed at once
    top = M.g3Fight(game)
    if top and top.phase == "item_party" then
      U.tap(game, "a")
      U.wait(20)
    end
    return want == nil or (items[at] ~= nil and items[at].id == want)
  end
  local top = M.top(game)
  if not (top and top.sim and top.phase == "choose") then return false end
  local U = M.U
  local cols = 2
  if top.commandCols then
    local ok, c = pcall(top.commandCols, top)
    if ok and tonumber(c) then cols = tonumber(c) end
  end
  if cols >= 4 then
    -- One row of four: FIGHT -> SWITCH -> ITEM.
    U.tap(game, "right"); U.wait(6)
    U.tap(game, "right"); U.wait(6)
  else
    U.tap(game, "down"); U.wait(6)
  end
  U.tap(game, "a");    U.wait(10)
  if top.phase ~= "item" then
    top = M.top(game)
    if not (top and top.phase == "item") then return false end
  end
  -- Walk the bag list to the requested id when present; otherwise take row 1.
  local items = top.usableItems and top:usableItems() or {}
  local want = 1
  for i, row in ipairs(items) do
    if row.id == itemId then want = i break end
  end
  top.itemIndex = want
  U.tap(game, "a"); U.wait(20)
  return true
end

-- Wait until the co-op command grid is really the thing on screen.
--
-- "2 on 2 battle!" holds the message box for up to its full dwell (1.6s, or
-- until somebody presses A), so the command box is *not* up the instant the
-- battle screen is. Two things went wrong without this, and both looked like
-- something else:
--
--   * a driver that tapped an arrow into the message phase moved nothing, and
--     every press behind it landed one step out of order -- a failure about
--     the driver's timing wearing the clothes of a failure about the menus;
--   * a screenshot taken on a fixed `U.wait(30)` photographed the opening
--     line instead of the grid. Those images are the shipped evidence of what
--     the 2x2 layout looks like, so a picture of a text box is a picture of
--     nothing anybody was asking about.
--
-- Hardened past "phase == choose", because that phase is reachable while the
-- grid is still not what the player is looking at: `replacing` outranks the
-- turn and draws the bench instead, and a battle that has already been decided
-- carries a `result` while its last messages drain. Both would have satisfied
-- the loose predicate and neither is a command grid.
--
-- Seconds, not frames, and it must be: the grid only opens once the *other*
-- clients have got there too. Returns whether it happened, so a caller can
-- `check` it rather than walking on into a menu that never opened.
function M.awaitCommandMenu(game, what)
  if g3(game) then
    return M.waitSeconds(game, function()
      local top = M.g3Fight(game)
      return top ~= nil and top.phase == "choose" and not top.replacing
        and not top.mustReplace and top.result == nil
    end, 30, what or "the Gen 3 command menu")
  end
  return M.waitSeconds(game, function()
    local top = M.top(game)
    return top ~= nil and top.sim ~= nil and top.phase == "choose"
      and not top.replacing and top.result == nil
  end, 30, what or "the co-op command menu")
end

-- ------- trainer kits and 0-PP (the two battle-system regressions)
--
-- Shared on purpose: solo_battle_e2e.lua, the Node-hub guest pair, and the
-- LAN host/join pair all have to see the same two bugs. A helper that lived
-- only in the solo driver would leave the 2v2 (eight healing items) untested
-- on the path that actually seats two NPC boxes.

-- Gym-style kit Turn.DEFAULT_NPC_BAG used to seed onto every NPC seat. Two
-- seats × that map is four POTIONs + two SUPER POTIONs + two FULL HEALs.
M.DEFAULT_NPC_KIT = {
  POTION = 2, SUPER_POTION = 1, FULL_HEAL = 1, X_ATTACK = 1,
}

function M.modCtx(game)
  local exports = M.exports(game)
  local fn = exports and exports.isFighting
  if type(fn) ~= "function" or not debug or not debug.getupvalue then
    return nil
  end
  local i = 1
  while true do
    local name, val = debug.getupvalue(fn, i)
    if not name then break end
    if name == "ctx" then return val end
    i = i + 1
  end
  return nil
end

function M.bagSummary(bag)
  if type(bag) ~= "table" then return "(none)" end
  -- Shape only. Item ids are the player's ROM sheet; they stay out of logs
  -- and dump files (legal floor: no ROM inventory table in this repo).
  if bag.heal ~= nil and bag.gym ~= nil then
    return string.format("empty=%s gym=%s heal=%s",
      bag.empty and "1" or "0", bag.gym and "1" or "0",
      tostring(bag.heal))
  end
  local empty = true
  for _, count in pairs(bag) do
    if (tonumber(count) or 0) > 0 then empty = false; break end
  end
  return string.format("empty=%s gym=%s heal=%s",
    empty and "1" or "0",
    M.matchesDefaultKit(bag, 1) and "1" or "0",
    tostring(M.bagHealCount(bag)))
end

function M.bagHealCount(bag)
  -- Gym-seed stacks that are not X-items. Derived from DEFAULT_NPC_KIT
  -- rather than a hardcoded heal list, so this helper does not name a ROM
  -- inventory. HYPER_POTION is not in the seed and does not count.
  local n = 0
  if type(bag) ~= "table" then return 0 end
  for id, count in pairs(bag) do
    if type(id) == "string" and M.DEFAULT_NPC_KIT[id]
        and not id:match("^X_") then
      n = n + (tonumber(count) or 0)
    end
  end
  return n
end

function M.matchesDefaultKit(bag, copies)
  copies = math.floor(tonumber(copies) or 1)
  if copies < 1 then copies = 1 end
  if type(bag) ~= "table" then return false end
  for id, n in pairs(M.DEFAULT_NPC_KIT) do
    if (tonumber(bag[id]) or 0) ~= n * copies then return false end
  end
  local extra = false
  for id, count in pairs(bag) do
    if type(id) == "string" and (tonumber(count) or 0) > 0
        and M.DEFAULT_NPC_KIT[id] == nil then
      extra = true
      break
    end
  end
  return not extra
end

-- ------- K16: what the computer's items are now
--
-- Contract K16 of docs/plans/gen12-referee-remaining-gaps.md: the Red and
-- Gold referees run the carts' own item / switch AI off the trainer's *class*,
-- so the client uploads no NPC bag on either cart and the referee keeps none
-- for the computer.  What a trainer can use is its class data on the seat:
--
--   Red   `aiClass`  the class's ai_classes record (pokered TrainerAI, the
--                    routine data/trainers/ai_pointers.asm names: wAICount
--                    `uses`, its `item`, ...) -- nil for a class
--                    ai_pointers.asm sends to GenericAI, which uses nothing;
--   Gold  `trainerItems` (wEnemyTrainerItem1 / 2), `aiFlags`
--                    (TRNATTR_AI_MOVE_WEIGHTS), `itemSwitch`
--                    (TRNATTR_AI_ITEM_SWITCH) -- the class's
--                    TrainerClassAttributes, which AI_SwitchOrTryItem and
--                    AIChooseMove read.
--
-- These read what the engine's own data says the class carries, the way the
-- client reads it (MediatedBattle.aiClass1 / trainerAi2), so a seat can be
-- held to it.  `known` false: the dataset has no table to read, and the leg
-- says so rather than guess.

-- Red: the ai_classes record for the trainer class `classId`, looked up the
-- way TrainerAI.classFor (and MediatedBattle.aiClass1 after it) looks it up:
-- the trainer record's `aiClass`, else its `id` -- the class id the driver
-- staged only when there is no trainer record to ask.  record, known.
function M.aiClassRecord1(game, classId)
  local data = game and game.data
  local classes = type(data) == "table" and data.ai_classes or nil
  if type(classes) ~= "table" or classId == nil then return nil, false end
  local trainer = type(data.trainers) == "table" and data.trainers[classId] or nil
  local key = classId
  if type(trainer) == "table" then key = trainer.aiClass or trainer.id end
  local record = key ~= nil and classes[key] or nil
  return type(record) == "table" and record or nil, true
end

-- A little-endian word out of two attribute bytes, or nil.
local function attrWord(lo, hi)
  lo, hi = tonumber(lo), tonumber(hi)
  if not (lo and hi) then return nil end
  return lo + hi * 256
end

-- The carried item ids of a two-slot list, in slot order -- NO_ITEM (an empty
-- slot 1 ahead of a filled slot 2) and anything that is not an id dropped.
local function carriedItems(list)
  local out = {}
  for i = 1, math.min(2, type(list) == "table" and #list or 0) do
    local id = list[i]
    if type(id) == "string" and id ~= "" and id ~= "NO_ITEM" then out[#out + 1] = id end
  end
  return out
end
M.carriedItems = carriedItems

-- Gold: the class's TrainerClassAttributes as the seat should carry them --
-- { items = carried ids, aiFlags = word?, itemSwitch = word? } -- off the
-- trainer-class record (`data.trainers.classes[classId]`: `items`,
-- `attributes`, src/world/gen2/Trainers.lookup's own source).  record, known.
function M.trainerAttrs2(game, classId)
  local data = game and game.data
  local classes = type(data) == "table" and type(data.trainers) == "table"
    and data.trainers.classes or nil
  if type(classes) ~= "table" or classId == nil then return nil, false end
  local rec = classes[classId]
  if type(rec) ~= "table" then return nil, false end
  local attributes = type(rec.attributes) == "table" and rec.attributes or nil
  return {
    items = carriedItems(rec.items),
    aiFlags = attributes and attrWord(attributes[4], attributes[5]) or nil,
    itemSwitch = attributes and attrWord(attributes[6], attributes[7]) or nil,
  }, true
end

-- The solo referee's computer seat, `solo_foe` (SoloBattle's FOE_SEAT); nil
-- when no solo fight is live.  The LAN hub's NPC seats are `hubNpcBags`'
-- `fighters`.
function M.soloFoeSeat(game)
  local ctx = M.modCtx(game)
  local solo = ctx and ctx.solo
  return solo and solo.sim and solo.sim.byId and solo.sim.byId.solo_foe or nil
end

function M.soloFoeBag(game)
  local foe = M.soloFoeSeat(game)
  return foe and foe.bag
end

function M.hubNpcBags(game)
  local ctx = M.modCtx(game)
  local hub = ctx and ctx.server and ctx.server.hub
  if not (hub and type(hub.battles) == "table") then return nil end
  for _, record in pairs(hub.battles) do
    if record and record.mode == "coop_npc" and record.sim
        and type(record.npcIds) == "table" and #record.npcIds >= 1 then
      local bags, fighters = {}, {}
      for i, seat in ipairs(record.npcIds) do
        local fighter = record.sim.byId and record.sim.byId[seat]
        fighters[i] = fighter
        bags[i] = (fighter and fighter.bag)
          or (record.bags and record.bags[seat])
      end
      local shared = #fighters >= 2
        and fighters[1] ~= nil and fighters[2] ~= nil
        and fighters[1].bag == fighters[2].bag
      return { bags = bags, shared = shared, n = #record.npcIds, fighters = fighters }
    end
  end
  return nil
end

-- Capture side-"b" mmo.battle_party uploads the host makes for the trainer:
-- whether a bag rode along, and (contract K16) whether the class data did --
-- Red's `aiClass` record, Gold's `trainerItems` (a count) and its two flag
-- words (present or not).  Shape only: no item id and no attribute byte ever
-- reaches a watch table that e2e prints.  Extra signal only: what the referee
-- holds is the Node dump (M.readBattleDump / MMO_BATTLE_DUMP).
function M.watchPartyUploads(game)
  local seen = { uploads = {} }
  local ctx = M.modCtx(game)
  local transport = ctx and ctx.client and ctx.client.transport
  if not (transport and type(transport.send) == "function") then
    return seen
  end
  local inner = transport.send
  transport.send = function(self, msgType, payload)
    if msgType == "mmo.battle_party" and type(payload) == "table" then
      -- Shape only: the bag itself is the player's game sheet and must
      -- not sit on a log or a watch table that e2e prints.
      local nonempty = false
      if type(payload.bag) == "table" then
        for _, entry in ipairs(payload.bag) do
          if type(entry) == "table" and (tonumber(entry.count) or 0) > 0 then
            nonempty = true
            break
          end
        end
      end
      seen.uploads[#seen.uploads + 1] = {
        side = payload.side,
        nonempty = nonempty,
        hasBag = payload.bag ~= nil,
        aiClass = type(payload.aiClass) == "table",
        trainerItems = type(payload.trainerItems) == "table" and #payload.trainerItems or nil,
        aiFlags = payload.aiFlags ~= nil,
        itemSwitch = payload.itemSwitch ~= nil,
      }
    end
    return inner(self, msgType, payload)
  end
  seen.stop = function()
    if transport.send ~= inner then transport.send = inner end
  end
  return seen
end

function M.uploadedTrainerBag(watch)
  if not (watch and watch.uploads) then return nil end
  for i = #watch.uploads, 1, -1 do
    local row = watch.uploads[i]
    if row and row.side == "b" then
      return {
        nonempty = row.nonempty == true, hasBag = row.hasBag == true,
        aiClass = row.aiClass == true, trainerItems = row.trainerItems,
        aiFlags = row.aiFlags == true, itemSwitch = row.itemSwitch == true,
      }
    end
  end
  return nil
end

local function bagIsEmpty(bag)
  if type(bag) ~= "table" then return true end
  for _, count in pairs(bag) do
    if (tonumber(count) or 0) > 0 then return false end
  end
  return true
end

-- Referee NPC-bag *shape* the Node hub wrote for LOVE e2e (MMO_BATTLE_DUMP).
-- Line 1 is `mode<TAB>shared<TAB>n`; each later line is
-- `seat<TAB>empty=<0|1><TAB>gym=<0|1><TAB>heal=<n>`. Item ids never appear:
-- those stacks are a client claim from the player's loaded game, and the
-- hub holds no ROM inventory table.
function M.readBattleDump(path)
  path = path or os.getenv("MMO_BATTLE_DUMP")
  if type(path) ~= "string" or path == "" then return nil end
  local handle = io.open(path, "r")
  if not handle then return nil end
  local header = handle:read("*l")
  if type(header) ~= "string" then handle:close(); return nil end
  local mode, sharedBit, n = header:match("^(%S+)\t([01])\t(%d+)$")
  n = tonumber(n) or 0
  local bags = {}
  local well = mode ~= nil
  for _ = 1, n do
    local line = handle:read("*l") or ""
    local rest = line:match("^[^\t]*\t(.*)$") or ""
    local empty, gym, heal = rest:match("^empty=([01])\tgym=([01])\theal=(%d+)$")
    heal = tonumber(heal)
    if not heal then well = false end
    bags[#bags + 1] = {
      empty = empty == "1",
      gym = gym == "1",
      heal = heal,
    }
  end
  handle:close()
  if not well then return nil end
  return {
    mode = mode,
    shared = sharedBit == "1",
    n = n,
    bags = bags,
  }
end

-- The computer's items on the referee, held to contract K16 (docs/plans/
-- gen12-referee-remaining-gaps.md).
--
-- Red / Gold: **no bag at all** on a computer seat -- the client uploads none
-- and the referee keeps none, since the carts' own AI spends the class's items
-- (pokered TrainerAI, pokecrystal AI_TryItem) -- and, where the seat lives in
-- this process (SoloBattle's referee, the LAN Hub.lua), the class data that AI
-- reads: Red's `aiClass` as the class's ai_classes record (nil for a GenericAI
-- class), Gold's `trainerItems` / `aiFlags` / `itemSwitch` as its
-- TrainerClassAttributes.  On a Node hub only the bag's shape leaves the
-- process (MMO_BATTLE_DUMP), so that is what is held there.  The old gym-kit
-- seed (DEFAULT_NPC_BAG) and "potion spam" both fail the no-bag check, which
-- is stricter than the two checks it replaces.  Gen 3 keeps its trainer's own
-- item list as a bag (`g3AssertTrainerKit`).
--
-- A 2v2's NPC seats are one trainer: the hubs copy one class record onto
-- every seat (as they do `aiMods`), so the seats must agree.
local function sameList(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- Gold's item slots live in the trainer's kit, one per trainer and shared by
-- its seats (BattleSim2 `trainerKitOf`: wEnemyTrainerItem1 / 2 and the base
-- reward); a seat built without one holds them itself.
local function seatTrainerItems(seat)
  local kit = type(seat) == "table" and seat.trainerKit or nil
  if type(kit) == "table" then return kit.trainerItems end
  return type(seat) == "table" and seat.trainerItems or nil
end

local function classData12(generation, seat)
  if type(seat) ~= "table" then return nil end
  if generation == 2 then
    return { items = carriedItems(seatTrainerItems(seat)), aiFlags = tonumber(seat.aiFlags),
             itemSwitch = tonumber(seat.itemSwitch) }
  end
  local class = type(seat.aiClass) == "table" and seat.aiClass or nil
  return { uses = class and tonumber(class.uses), item = class and class.item, has = class ~= nil }
end

local function sameClassData(generation, a, b)
  if not (a and b) then return false end
  if generation == 2 then
    return sameList(a.items, b.items) and a.aiFlags == b.aiFlags and a.itemSwitch == b.itemSwitch
  end
  return a.has == b.has and a.uses == b.uses and a.item == b.item
end

function M.assertTrainerKit(game, check, log, opts)
  opts = opts or {}
  if g3(game) then return M.g3AssertTrainerKit(game, check, log, opts) end
  local generation = M.generation(game)
  local K16 = "Red / Gold's trainer items are its class data (K16)"

  local dumpPath = os.getenv("MMO_BATTLE_DUMP")
  if dumpPath == "" then dumpPath = nil end

  local bags, seats, source = {}, {}, nil
  if opts.solo then
    local seat = M.soloFoeSeat(game)
    bags[1], seats[1], source = seat and seat.bag, seat, "solo foe"
  else
    local npc = M.hubNpcBags(game)
    if npc then
      bags, seats, source = npc.bags, npc.fighters or {}, "lan hub"
    else
      local dumped = M.readBattleDump(dumpPath)
      if dumped and dumped.mode and dumped.n >= 1 then
        -- Shape only: item ids never leave the hub.
        for i, row in ipairs(dumped.bags) do
          if log then
            log(("trainer bag on the referee (node hub dump), seat %d:"):format(i), M.bagSummary(row))
          end
          check(row.empty == true, "the computer carries no bag on the referee -- " .. K16,
                M.bagSummary(row))
        end
        return
      elseif dumpPath then
        check(false, "the Node hub dumped NPC bags for this fight", tostring(dumpPath))
        return
      else
        if log then log("skip trainer kit -- no in-process hub on this side") end
        return
      end
    end
  end

  for i = 1, math.max(1, #bags) do
    if log then
      log(("trainer bag on the referee (%s), seat %d:"):format(source, i), M.bagSummary(bags[i]))
    end
    check(bagIsEmpty(bags[i]), "the computer carries no bag on the referee -- " .. K16,
          M.bagSummary(bags[i]))
  end

  local seat = seats[1]
  check(type(seat) == "table", "the computer's seat is on the referee (" .. source .. ")")
  if type(seat) ~= "table" then return end
  local got = classData12(generation, seat)
  if generation == 2 then
    local want, known = M.trainerAttrs2(game, opts.class)
    if log then
      log(("trainer class data (%s): %d item(s), aiFlags %s, itemSwitch %s; the class states %s item(s)")
        :format(source, #got.items, got.aiFlags and "set" or "none", got.itemSwitch and "set" or "none",
          want and tostring(#want.items) or "?"))
    end
    check(type(seatTrainerItems(seat)) == "table",
          "the Gold computer seat carries its class's item slots (K16 `trainerItems`)",
          type(seatTrainerItems(seat)))
    if known and want then
      check(sameList(got.items, want.items),
            "...the class's own ITEM1 / ITEM2 (wEnemyTrainerItem1 / 2), in slot order",
            ("%d vs %d item(s)"):format(#got.items, #want.items))
      if want.aiFlags then
        check(got.aiFlags == want.aiFlags,
              "...its AI layers (TRNATTR_AI_MOVE_WEIGHTS, K16 `aiFlags`) as the class states them")
      end
      if want.itemSwitch then
        check(got.itemSwitch == want.itemSwitch,
              "...and its item / switch flags (TRNATTR_AI_ITEM_SWITCH, K16 `itemSwitch`)")
      end
    elseif log then
      log("skip the class-data match -- no trainer-class record for", tostring(opts.class))
    end
  else
    local want, known = M.aiClassRecord1(game, opts.class)
    if log then
      log(("trainer class data (%s): aiClass %s; the class %s"):format(source,
        got.has and ("uses=" .. tostring(got.uses) .. (got.item and " item=set" or " item=none")) or "none",
        not known and "is unknown here" or (want and "has a TrainerAI record" or "runs GenericAI")))
    end
    if not known then
      if log then log("skip the class-data match -- this dataset has no ai_classes table") end
    elseif want then
      check(got.has and got.uses == tonumber(want.uses) and got.item == want.item,
            "the Red computer seat carries its class's TrainerAI record (K16 `aiClass`: wAICount uses, its item)",
            got.has and ("uses %s"):format(tostring(got.uses)) or "none")
    else
      check(not got.has,
            "a GenericAI class (ai_pointers.asm) carries no record -- it uses no item and never switches",
            got.has and "a record" or "none")
    end
  end
  for i = 2, #seats do
    check(sameClassData(generation, got, classData12(generation, seats[i])),
          ("NPC seat %d carries the same trainer's class data as seat 1 -- one trainer, one record"):format(i))
  end
end

local function screenSays(top)
  if not top then return "" end
  local chunks = {}
  -- The live box: both screens pop the queue into `shown` on the next ticks,
  -- so a wait after the A tap will miss `lines` / `messages` and still have
  -- the PP sentence here.
  if type(top.shown) == "string" and top.shown ~= "" then
    chunks[#chunks + 1] = top.shown
  elseif type(top.shown) == "table" then
    for _, line in ipairs(top.shown) do
      chunks[#chunks + 1] = tostring(line)
    end
  end
  if type(top.lines) == "table" then
    for _, line in ipairs(top.lines) do
      chunks[#chunks + 1] = tostring(line)
    end
  end
  if type(top.messages) == "table" then
    for _, page in ipairs(top.messages) do
      if type(page) == "table" then
        for _, line in ipairs(page) do
          chunks[#chunks + 1] = tostring(line)
        end
      elseif type(page) == "string" then
        chunks[#chunks + 1] = page
      end
    end
  end
  return table.concat(chunks, "\n")
end

local function liveMovesOf(top)
  if not top then return nil end
  if top.mmoBattle == true then
    local mon = top.activeMon and top:activeMon()
    return mon and mon.moves
  end
  if type(top.liveMoves) == "function" then
    local ok, moves = pcall(top.liveMoves, top)
    if ok then return moves end
  end
  return nil
end

local function backToChoose(game)
  for _ = 1, 48 do
    local top = M.top(game)
    if not top then return false end
    if top.phase == "choose" then return true end
    if top.phase == "messages" then
      U.tap(game, "a")
    else
      U.tap(game, "b")
    end
    U.wait(4)
  end
  local top = M.top(game)
  return top ~= nil and top.phase == "choose"
end

-- Drain one move, pick it, and require the menu to stay put with a PP line.
-- Restore PP afterwards so the mash-A remainder of the leg can still finish.
-- A one-move lead gets a dummy empty slot so leftover PP still exists --
-- skipping that case would leave the stall untested on a starter.
function M.assertZeroPpRefused(game, check, log)
  local top = M.top(game)
  if not top or (top.phase ~= "choose" and top.phase ~= "move") then
    check(false, "the command grid is up for the 0-PP pick",
          tostring(top and top.phase))
    return
  end
  local moves = liveMovesOf(top)
  if type(moves) ~= "table" or #moves < 1 then
    check(false, "the lead has a move list for the 0-PP pick")
    return
  end
  local live = {}
  for i, move in ipairs(moves) do
    if (tonumber(move.pp) or 0) > 0 then live[#live + 1] = i end
  end
  if #live < 1 then
    check(false, "the lead has PP left on some other move so 0-PP is not Struggle")
    return
  end
  local emptyAt, saved, appended = nil, nil, false
  if #live >= 2 or #moves >= 2 then
    emptyAt = live[#live]
    if #live < 2 then
      -- Two slots, only one with PP: drain a slot that is not the leftover.
      for i = 1, #moves do
        if i ~= live[1] then emptyAt = i; break end
      end
    end
    saved = tonumber(moves[emptyAt].pp) or 0
    moves[emptyAt].pp = 0
  else
    local template = moves[live[1]]
    moves[#moves + 1] = {
      id = template.id, pp = 0, ppMax = template.ppMax or 0,
    }
    appended = true
    emptyAt = #moves
  end

  local function restore()
    if appended then
      table.remove(moves, emptyAt)
    elseif emptyAt and saved ~= nil then
      moves[emptyAt].pp = saved
    end
  end

  if top.phase == "choose" then
    top.commandIndex = 1
    U.tap(game, "a")
    U.wait(8)
    top = M.top(game)
  end
  if not (top and top.phase == "move") then
    restore()
    check(false, "FIGHT opened the move list for the 0-PP pick",
          tostring(top and top.phase))
    backToChoose(game)
    return
  end

  if top.mmoBattle == true then
    top.cursor = emptyAt
  else
    top.moveIndex = emptyAt
  end
  top.answeredTurn = top.answeredTurn or false
  U.tap(game, "a")
  U.wait(12)
  top = M.top(game)
  local text = screenSays(top)
  local phase = top and top.phase
  local stalled = phase == "play" or phase == "wait"
    or (top and top.answeredTurn == true)
  if log then
    log(("0-PP pick: phase=%s answered=%s text=%s"):format(
      tostring(phase), tostring(top and top.answeredTurn),
      text:gsub("%s+", " "):sub(1, 80)))
  end
  restore()

  check(not stalled,
        "a move with no PP is refused locally -- the turn is not spent",
        tostring(phase))
  check(phase == "move" or phase == "messages",
        "the player stays on the list (or the PP line) rather than waiting",
        tostring(phase))
  check(type(text) == "string" and text:find("PP", 1, true) ~= nil,
        "and is told the move has no PP left")
  check(backToChoose(game),
        "the command grid comes back so the fight can continue")
end

-- Listen for the mod's *own* events, the way another mod would.
--
-- Two buses, and they are not the same one. `Runtime.emit` carries the
-- engine's events and is what captureEvents wraps; a mod's own announcements
-- go through the loader's `events` bus instead, because `mod.events:emit` is
-- namespaced -- it refuses anything that is not `mod.<id>.*` so that no mod
-- can forge an engine event. A run that watched only Runtime saw a co-op
-- battle announce nothing and reported a hole that was not there.
--
-- Subscribing rather than wrapping the emitter on purpose: what is worth
-- asserting is that a *listener hears it*, which is the thing another mod
-- actually does. Returns a table of name -> count, and the payload of the
-- last one of each, so a test can check the shape as well as the fact.
function M.listenForModEvents(game, names)
  local loader = game and game.mods
  local bus = loader and loader.events
  local seen = { payloads = {} }
  for _, name in ipairs(names) do seen[name] = 0 end
  if not (bus and bus.on) then return seen end
  for _, name in ipairs(names) do
    bus:on(name, function(payload)
      seen[name] = seen[name] + 1
      seen.payloads[name] = payload
    end, 0, "mmo_driver")
  end
  return seen
end

-- ------- a Red / Gold referee line, as the battle screen reads it
--
-- The Red and Gold referees write a battle line the way the carts print it
-- (contracts K17 / K18 of docs/plans/gen12-referee-remaining-gaps.md):
--
--   * a battler's name the cart prints through a prefixing macro (pokered
--     <USER> / <TARGET>, pokecrystal PlaceBattlersName) carries its side's
--     mark, `^a` or `^b`, straight before it; a side word (pokecrystal
--     HandleScreens' "Your@" / "Enemy@") is `^A` / `^B`;
--   * a row break is `\n`, where the cart's text has `line` or `cont`.
--
-- A screen says a mark on its own side's monster as nothing and one on the
-- other side's as "Enemy " -- both carts, every kind of fight, link included
-- (pokered EnemyText, pokecrystal / pokegold PlaceBattlersName) -- and a side
-- word as "Your " / "Enemy " (src/ClassicBattle.lua renderMarks).  Its pager
-- shows two rows a page and scrolls a third in like `_ContText`, so a box never
-- holds a three-row line whole: read a line off what the screen was *handed*
-- (`say`), not off one page.  A driver that sits in a mod sandbox cannot
-- require the mod's own reader, so these restate it: Wire.plainBattleLine and
-- ClassicBattle.renderMarks, rule for rule.
--
-- Gen 3's referee writes no marks; every helper here leaves its lines as they
-- are (bar a stray `^`, which no screen ever draws either).

-- The other side's mark and the two side words, as both carts print them.
M.FOE_MARK_WORD = "Enemy "
M.SIDE_WORD_OWN = "Your "
M.SIDE_WORD_OTHER = "Enemy "

-- One sentence, the way a matcher reads it: every mark out (and a stray `^`
-- with them), a row broken after a hyphen joined whole ("super-\neffective!",
-- the word the cart split), every other break the space between two words.
-- Works on a referee line and on a screen's line alike -- the screen's has no
-- marks left, only its words and breaks.
function M.plainBattleLine(text)
  if type(text) ~= "string" then return text end
  local plain = text:gsub("%^[abAB]", ""):gsub("%^", ""):gsub("%-\n", "-"):gsub("\n", " ")
  return plain
end

-- A referee line as the screen of a player on `ownSide` ("a" | "b"; "a" when
-- nil -- the player's side in every fight against the computer) is handed it:
-- marks rendered, breaks kept.  Exactly the text that screen's `say` receives
-- for that `msg` (MediatedBattle:viewLine / CoopBattle's), so it compares with
-- `==`.  A co-op partner's side is its own, so both humans of a 2v2 pass the
-- same side.
function M.viewBattleLine(text, ownSide)
  if type(text) ~= "string" then return text end
  ownSide = ownSide or "a"
  local out = text:gsub("%^([abAB])", function(mark)
    local side = mark:lower()
    if mark ~= side then
      return (side == ownSide) and M.SIDE_WORD_OWN or M.SIDE_WORD_OTHER
    end
    if side == ownSide then return "" end
    return M.FOE_MARK_WORD
  end)
  return (out:gsub("%^", ""))
end

-- ...and that line as one sentence, for a leg about its words rather than its
-- breaks: "Enemy RATTATA stole NUGGET from its foe!" for side a.  A literal
-- with no marks reads as itself (bar its breaks), so a leg can hand either.
function M.readBattleLine(text, ownSide)
  return M.plainBattleLine(M.viewBattleLine(text, ownSide))
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

-- One screenshot per co-op battle phase the first time it is seen.
--
-- `shotFn(name)` is the driver's own `shot` so hub/quad filenames stay
-- namespaced per seat. `seen` is a table the caller keeps across ticks.
-- Settles two frames before capturing so the menu paint of that phase is up
-- (otherwise a phase transition shot lands on the previous box for a tick).
function M.shotCoopPhases(game, shotFn, seen)
  seen = seen or {}
  local now = M.top(game)
  -- Mid-battle evolution is not a phase: the movie sits on `evolving` while
  -- the screen is still in messages/wait. Capture it once so a live fight
  -- that actually levels into an evo leaves a reviewable frame.
  if now and now.evolving and not seen.evolving then
    seen.evolving = true
    U.wait(2)
    shotFn("phase-evolving")
  end
  if not (now and now.sim and type(now.phase) == "string") then return seen end
  local phase = now.phase
  if phase ~= "choose" and phase ~= "move" and phase ~= "target"
      and phase ~= "messages" and phase ~= "wait" and phase ~= "switch"
      and phase ~= "item" and phase ~= "replace" then
    return seen
  end
  if seen[phase] then return seen end
  seen[phase] = true
  U.wait(2)
  shotFn("phase-" .. phase)
  return seen
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

-- ------- ranked PVP, after a link battle
--
-- What this can assert is bounded by what a driver can know. Which side won
-- is the engine's business and neither driver is told; what both sides *can*
-- see is that the hub settled the match -- somebody's rating moved -- and
-- that the leaderboard it hands back has the winner on it.
--
-- So: read both ratings (this player's own through `points`, the other
-- player's off the roster, where presence now carries it), and only insist
-- on a board when the match was decisive. A link battle can legitimately end
-- in a draw -- a dropped link, a mutual run -- and a draw scores nothing by
-- design, so demanding a leaderboard after one would be demanding that the
-- design be different.
--
-- Returns mine, theirs.
function M.rankAfterBattle(game, exports, check, seconds)
  local function theirs()
    local best = 0
    for _, player in ipairs(exports.players() or {}) do
      best = math.max(best, tonumber(player.points) or 0)
    end
    return best
  end

  -- Both reports have to reach the hub and the answer has to come back, so
  -- this is seconds and not frames: there is another process in the loop.
  M.waitSeconds(game, function()
    return (tonumber(exports.points()) or 0) > 0 or theirs() > 0
  end, seconds or 60, "the hub to settle the battle")

  local mine, other = tonumber(exports.points()) or 0, theirs()
  U.log(("ranked points: mine=%d theirs=%d"):format(mine, other))

  exports.requestRanking()
  local arrived = M.waitSeconds(game, function()
    return #(exports.ranking() or {}) > 0
  end, 30, "the leaderboard to arrive")

  if mine + other > 0 then
    check(arrived, "a decided link battle put somebody on the leaderboard")
    local board = exports.ranking() or {}
    if #board > 0 then
      U.log(("leaderboard: 1. %s %d (%d row(s))"):format(
        tostring(board[1].name), tonumber(board[1].points) or -1, #board))
      check((tonumber(board[1].points) or 0) > 0,
            "and nobody at zero is on it")
      check(board[1].sprite ~= nil,
            "with a character to draw beside the name")
    end
  else
    -- Not a failure, and worth saying out loud: a draw is a real outcome
    -- here and it is worth nothing on purpose.
    U.log("the battle was a draw or was never settled; nothing was scored")
  end
  return mine, other
end

-- Photograph the character you are wearing, stood in the overworld facing
-- the camera, and hand back the sheet it drew from.
--
-- Deliberately taken while this side is alone on its map: a remote player
-- brings a nameplate, and a plate over the character would ruin a portrait
-- shot of what they are wearing.
--
-- The facing is set on the entity rather than walked into, because a tapped
-- direction moves a tile and the tile it moves to is not always free. Frame
-- 0 of an overworld sheet is stand-down (SpriteRenderer), so facing down is
-- what puts the character's front to the camera.
--
-- "Alone" cannot be arranged on the guest's side -- both trainers spend the
-- run in one room -- so the overlay is switched off for the length of the
-- shot instead, through the same option a player toggles, and switched back
-- immediately. Nothing else in the run is affected: every nameplate and
-- bubble assertion happens outside these few frames, and the option going
-- off and on again is itself the proof that BUBBLES reaches the overlay.
function M.shotLook(game, path)
  local ow
  for i = #game.stack.states, 1, -1 do
    if game.stack.states[i].isOverworld then ow = game.stack.states[i] break end
  end
  ow = ow or game.overworld
  local player = ow and ow.player
  if not player then return nil end

  local opts = game.mods and game.mods.modOptions
  local mine = opts and opts["rby_mmo"]
  local hadBubbles = mine and mine.bubbles
  if mine then mine.bubbles = false end

  M.closeToOverworld(game)
  player.facing = "down"
  U.wait(20)
  U.shot(game, path)

  if mine then mine.bubbles = hadBubbles end
  U.wait(5)

  local worn = player.sprite
  return worn and (worn.def and worn.def.image or worn.image) or nil
end

-- Mount the bicycle and photograph it, returning the sheet the player
-- actually posed from.
--
-- The third pic of a character, and the one with the quietest failure. The
-- bicycle is a whole second overworld sheet -- Player.new resolves
-- field.playerSprites.bike once and Player:pose prefers player.bikeSprite
-- while onBike -- so a character can be worn correctly everywhere this file
-- already looks and still turn back into RED the moment its rider mounts.
-- Nothing in either flow had ever been on a bicycle.
--
-- Mounted through save.onBike, which is what the bag's BICYCLE row writes
-- (src/ui/BagMenu.lua) and what OverworldController copies onto the player
-- every tick -- not a flag poked onto the player behind the engine's back.
-- Indoors is fine and is where both drivers stand: the mount check that
-- cares about the map runs on a warp, so the pose here is the same pose a
-- route would draw.
--
-- Call it with nothing in flight from the peer. It closes what is on top
-- before it mounts, and B on a request box is an answer: dropped between the
-- guest's trade ask and the host's reply, this refused the trade and the run
-- failed two legs later, in the trade, with nothing pointing back here.
--
-- The sheet is read back off pose() rather than off player.bikeSprite so the
-- answer is what the frame drew, not what was installed for it.
function M.shotBike(game, path)
  local ow
  for i = #game.stack.states, 1, -1 do
    if game.stack.states[i].isOverworld then ow = game.stack.states[i] break end
  end
  ow = ow or game.overworld
  local player = ow and ow.player
  if not (player and game.save) then return nil end

  local wasOnBike = game.save.onBike
  M.closeToOverworld(game)
  player.facing = "down"
  game.save.onBike = true
  U.wait(20)

  local drawn
  pcall(function()
    local sprite = (player:pose())
    drawn = sprite and (sprite.def and sprite.def.image or sprite.image) or nil
  end)
  U.shot(game, path)

  game.save.onBike = wasOnBike
  player.onBike = not not wasOnBike
  U.wait(10)
  return drawn
end

-- Open the game's own TRAINER CARD and photograph it, returning the path
-- the player pic resolved to.
--
-- This is the other half of the player.sprite hook. The back pic is checked
-- where it is drawn -- a battle -- but the *front* one, which the trainer
-- card, Oak's intro and the Hall of Fame all share, had nothing in either
-- flow that opened a screen carrying it. A character whose front pic never
-- resolved would have looked exactly like one that did, from here.
--
-- Pushed by id rather than driven through the START menu: that row is
-- labelled with the player's *name*, which each side chooses, so selecting
-- it by label would be a second thing to keep in sync for no gain.
function M.shotTrainerCard(game, path)
  local pic = require("src.pokemon.Sprites").playerPath(game.data, "front",
                                                        { kind = "trainer_card" })
  require("src.ui.Screens").push(game, "TrainerCard", {})
  U.wait(30)
  U.shot(game, path)
  M.closeToOverworld(game)
  U.wait(10)
  return pic
end

-- Open the RANK screen from the MMO menu and photograph it.
--
-- The row is only there while connected, so its absence is a real failure
-- rather than a variation. B backs out to the MMO menu, the way every other
-- screen here does.
function M.shotRank(game, path, check)
  if not M.selectLabel(game, "RANK") then
    check(false, "no RANK row on the MMO menu while connected")
    return false
  end
  -- the screen asks the hub on the way in, so give the answer a moment to
  -- land before the picture is taken
  U.wait(60)
  U.shot(game, path)
  if check then
    -- First row's portrait column (src/Ui.lua RANK_ART_X, RANK_FIRST_Y).
    M.assertPortraitColors(game, path, 26, 24, 16, 16, check,
      "the ranking list portrait is palette-correct")
  end
  check(M.top(game) ~= nil, "the RANK screen opened")
  U.tap(game, "b")
  U.wait(25)
  return true
end

-- Sample a screenshot for the lime-green skin that raw DMG-shade blits show.
-- Rect is in 160x144 game pixels, matching the mod UI layout.
local PORTRAIT_PROBE = "mods/rby_mmo/tests/drivers/portrait_color_probe.py"

function M.assertPortraitColors(game, path, x, y, w, h, check, what)
  local cmd = ('python3 "%s" "%s" %d %d %d %d 2>&1'):format(
    PORTRAIT_PROBE, path, x, y, w, h)
  local out = ""
  -- captureScreenshot lands asynchronously after U.shot returns; spin until
  -- the probe can read a real PNG or the budget runs out.
  for _ = 1, 40 do
    local f = io.popen(cmd)
    out = f and f:read("*a") or ""
    if f then f:close() end
    if out:match("^ok ") then break end
    -- Missing Pillow is a harness gap, not a palette bug -- fail the probe
    -- once and move on rather than spinning 40× on ModuleNotFoundError.
    if out:find("No module named 'PIL'", 1, true)
       or out:find("No module named \"PIL\"", 1, true) then
      break
    end
    if game then U.wait(2) end
  end
  if out:find("No module named 'PIL'", 1, true)
     or out:find("No module named \"PIL\"", 1, true) then
    U.log("portrait probe skipped: Pillow not installed "
      .. "(python3 -m pip install Pillow)")
    return true
  end
  local passed = out:match("^ok ") ~= nil
  if not passed then
    U.log("portrait probe failed:", (out:gsub("%s+$", "")))
  end
  check(passed, what or ("portrait colours look right in " .. path))
  return passed
end

-- Dial the same hub again, through the menus a player uses.
--
-- Exists for one assertion, and it is one no unit test can make: that a
-- returning player is recognised as themselves. The claim ticket is stored by
-- the client, keyed by the address it dialled, replayed on the next hello and
-- matched by the hub against a digest -- four separate files, none of which
-- errors when it is wrong. Driving the real menus is what makes the second
-- connection a genuine second connection.
--
-- Everything typed here is deliberately the short path: START on an empty
-- address line submits the stored default, and the code is typed out because
-- there is no other way past the door. Returns whether the connection opened.
function M.rejoin(game, exports, joinCode, check, log)
  -- Settle first, and this is not belt and braces: the leg before this one
  -- walks the player to prove single-player still works, and the overworld
  -- swallows START while a step is in flight -- so the first run of this
  -- reported "no MMO row" about a menu that was simply not listening yet.
  -- Back to the overworld, let the step land, and only then press anything.
  M.closeToOverworld(game)
  U.wait(30)

  local opened = false
  for _ = 1, 3 do
    if M.openMmo(game) then
      opened = true
      break
    end
    -- whatever came up instead goes away, and the press is tried again
    M.closeToOverworld(game)
    U.wait(20)
  end
  if not opened then
    check(false, "the MMO menu opens again after leaving")
    return false
  end
  if not M.selectLabel(game, "JOIN GAME") then
    check(false, "JOIN GAME is back on the menu once disconnected")
    return false
  end
  U.wait(20)
  if not M.selectLabel(game, "JOIN") then
    check(false, "character creation confirms on the way back in")
    return false
  end

  -- the address screen still carries the hub we just left as its default, so
  -- an empty line and START is the whole answer
  U.wait(40)
  if M.addressGrid(game) == nil then
    check(false, "the address screen opens on the way back in")
    return false
  end
  U.tap(game, "start")
  U.wait(60)

  if joinCode then
    local asked = M.waitFor(game, function()
      return M.codeGrid(game) ~= nil
    end, 240, "the join-code grid on the way back in")
    if asked and not M.enterJoinCode(game, joinCode) then
      check(false, "the code can be typed again")
      return false
    end
    U.wait(60)
  end

  local back = M.waitSeconds(game, function() return exports.isConnected() end,
                             60, "the second connection to open")
  check(back, "the same player can join the same game again")
  if not back and log then
    log("top state after the second attempt:",
        tostring(M.top(game) and (M.top(game).title or "?")))
  end
  return back
end

-- open the START menu and step into MMO
function M.openMmo(game)
  if g3(game) then return M.g3OpenMmo(game) end
  U.tap(game, "start")
  U.wait(15)
  return M.selectLabel(game, "MMO")
end

-- What the SERVERS list calls the hub at `address`.
--
-- A caller holding an address does *not* hold the row's label: a fresh entry
-- is named after its address with the standard port left off (src/Servers.lua
-- and the note above its `defaultName`), so a run that dials
-- 127.0.0.1:<RBY_MMO_PORT> -- which is what run-mmo-e2e.sh binds and what
-- Config.DEFAULT_PORT then reads back out of the environment -- has a row
-- reading "127.0.0.1" and a driver looking for the whole string finds
-- nothing. Handing the address in and deriving the label here is what keeps
-- that rule in one place.
--
-- The store itself is asked first, through mod.exports.servers, because that
-- answer cannot drift from src/Servers.lua at all -- it *is* the row. The
-- arithmetic below is the fallback for a build without that export, and is
-- deliberately the same three steps the mod takes: fill in the default port,
-- take it back off again when it is the default, cap what is left at the name
-- limit.
local SERVER_NAME_MAX = 16

local function defaultPort()
  local raw = os.getenv and os.getenv("RBY_MMO_PORT")
  local n = tonumber(raw or "")
  if n and n == math.floor(n) and n > 0 and n < 65536 then return n end
  return 7788
end

local function withDefaultPort(address)
  if type(address) ~= "string" then return nil end
  local clean = address:gsub("%s+", "")
  if clean == "" then return nil end
  if not clean:match(":%d+$") then
    clean = ("%s:%d"):format(clean, defaultPort())
  end
  return clean
end

local function defaultServerName(address)
  local shown = withDefaultPort(address)
  if not shown then return nil end
  local suffix = ":" .. tostring(defaultPort())
  if #shown > #suffix and shown:sub(-#suffix) == suffix then
    shown = shown:sub(1, #shown - #suffix)
  end
  return shown:sub(1, SERVER_NAME_MAX)
end

function M.serverLabel(exports, address)
  local want = withDefaultPort(address)
  if want and type(exports) == "table"
     and type(exports.servers) == "function" then
    local ok, rows = pcall(exports.servers)
    if ok and type(rows) == "table" then
      for _, entry in ipairs(rows) do
        if type(entry) == "table" and type(entry.address) == "string"
           and entry.address:lower() == want:lower()
           and type(entry.name) == "string" then
          return entry.name
        end
      end
    end
  end
  return defaultServerName(address)
end

-- Dial the same hub a third way: not JOIN GAME's grids, but the row that
-- exists precisely so a returning player never has to touch them again.
--
-- Mirrors M.rejoin's shape and reuses its "same player, same rating"
-- assertions -- see the comment there for why the ticket round trip is the
-- one thing worth checking. What differs is everything between "the MMO menu
-- is open" and "a connection is either up or it isn't": SERVERS -> the
-- recorded entry -> CONNECT goes through CHARSET exactly as JOIN GAME does
-- (src/Ui.lua's SERVERACT registration pushes the same SCREEN.CHARSET with
-- verb = "JOIN"), but the address and the join code are already on the
-- entry, so `dial()` calls `client:connect` directly with no address or code
-- grid in between. `address` is the string this player dialled the first
-- time; the row to press is derived from it by M.serverLabel above, never
-- assumed to be the address itself.
--
-- `joinCode`, if given, is a fallback only: a hub is not expected to
-- challenge a connect that is already carrying the code that worked before,
-- but if one ever does (the code changed hub-side since it was recorded),
-- this answers it exactly as a fresh join would rather than stalling on a
-- screen this leg did not expect. Returns whether the connection opened.
--
-- `shotDir`, if given, is where the two pictures of this list go.
function M.reconnectViaServers(game, exports, address, joinCode, check, log,
                                shotDir)
  local label = M.serverLabel(exports, address)
  if not label then
    check(false, "a dialled address (" .. tostring(address)
                   .. ") names a row on the SERVERS list")
    return false
  end
  -- Same reason M.rejoin settles first: a step in flight swallows START.
  M.closeToOverworld(game)
  U.wait(30)

  local opened = false
  for _ = 1, 3 do
    if M.openMmo(game) then
      opened = true
      break
    end
    M.closeToOverworld(game)
    U.wait(20)
  end
  if not opened then
    check(false, "the MMO menu opens again after leaving, for the SERVERS leg")
    return false
  end

  if not M.selectLabel(game, "SERVERS") then
    check(false, "SERVERS is on the menu once a hub has been recorded")
    return false
  end
  U.wait(20)

  -- Is the entry's row the one on top right now? The mark lives in the row's
  -- right-hand column rather than in its label, so this is the same question
  -- whether or not the hub is a favourite.
  local function onList()
    local top = M.top(game)
    if not (top and type(top.items) == "table") then return false end
    for _, item in ipairs(top.items) do
      if labelMatches(item.label, label) then return true end
    end
    return false
  end

  -- The favourite is set before the list is photographed, and that is the
  -- whole reason for this excursion: the ▶ mark is drawn in the row's
  -- right-hand column, so a picture taken before anything is marked
  -- photographs the one layout that column never has to hold -- and the mark
  -- is exactly what a reader of these shots is checking. One row press, one
  -- FAVORITE, one B, and the list is back with the mark on it.
  local marked = false
  if M.selectLabel(game, label) then
    U.wait(20)
    -- Idempotent, because this row is not a switch that says which way it is
    -- set -- it says what pressing it *does*. A run interrupted before the
    -- wrapper cleaned its save folder away leaves the hub already pinned, the
    -- row already reading UNFAVORITE, and a blind press would take the mark
    -- back off the picture this excursion exists to take.
    local already = false
    for _, existing in ipairs(M.menuLabels(game)) do
      if labelMatches(existing, "UNFAVORITE") then already = true end
    end
    if already then
      marked = true
    elseif M.selectLabel(game, "FAVORITE") then
      -- SERVERACT rebuilds itself after the toggle, with the cursor back on
      -- the row that was just pressed -- so this lands on UNFAVORITE, and B
      -- from there is the menu's own onCancel putting the list back.
      U.wait(20)
      marked = true
    end
  end
  -- Back to the list, however far the excursion above actually got: nothing
  -- in it is load-bearing for the connection, and a leg that gave up its
  -- picture must still be standing where CONNECT can be reached.
  for _ = 1, 3 do
    if onList() then break end
    U.tap(game, "b")
    U.wait(20)
  end

  if shotDir then U.shot(game, shotDir .. "/servers-list.png") end
  if marked and log then
    local top = M.top(game)
    for _, item in ipairs((top and top.items) or {}) do
      if labelMatches(item.label, label) then
        log("SERVERS row", tostring(item.label), "marked",
            tostring(item.right))
      end
    end
  end

  if not M.selectLabel(game, label) then
    check(false, "the recorded entry (" .. tostring(label)
                   .. ") is on the SERVERS list")
    return false
  end
  U.wait(20)
  if shotDir then U.shot(game, shotDir .. "/servers-submenu.png") end

  if not M.selectLabel(game, "CONNECT") then
    check(false, "CONNECT is on the entry's own submenu")
    return false
  end
  U.wait(20)

  if not M.selectLabel(game, "JOIN") then
    check(false, "character creation confirms on the way back in through "
                   .. "SERVERS")
    return false
  end
  U.wait(40)

  -- No address or code grid is expected here -- dial() applies both off the
  -- entry -- but a stale code is still answerable if the hub asks anyway,
  -- the same way an unexpected challenge is handled off the typed path.
  if joinCode then
    local askedOrConnected = M.waitFor(game, function()
      return M.codeGrid(game) ~= nil or exports.isConnected()
    end, 180, "either a SERVERS connection or an unexpected code challenge")
    if askedOrConnected and M.codeGrid(game) ~= nil and not exports.isConnected() then
      if not M.enterJoinCode(game, joinCode) then
        check(false, "an unexpected code challenge can still be answered")
        return false
      end
      U.wait(60)
    end
  end

  local back = M.waitSeconds(game, function() return exports.isConnected() end,
                             60, "the SERVERS connection to open")
  check(back, "the same player can reconnect through SERVERS")
  if not back and log then
    log("top state after the SERVERS reconnect attempt:",
        tostring(M.top(game) and (M.top(game).title or "?")))
  end
  return back
end

-- =====================================================================
-- ------- Gen 3 driver kit (FireRed / LeafGreen / Emerald)
--
-- What the Gen 3 drivers (mmo_host_gen3 / mmo_join_gen3 / mmo_trip_gen3 /
-- mmo_mismatch_gen3) call directly. Everything here runs inside the engine
-- process, behind no mod facade, and reaches the cart through src.core.game3
-- / src.ui.game3 -- the only way there is on a Game3, which has no
-- game.stack, no game.overworld and a session instead of game.save. None of
-- it is ever reached on a Gen 1 or Gen 2 boot.

-- Where each cart's scenario stands, and what it trades. Pallet Town and
-- Littleroot Town are the two home towns (region-disjoint map ids, so the
-- trip run can prove presence stays per region); the cells are measured open
-- ground (Littleroot's (10,9) is under the moving truck). The species are
-- each cart's own starters / mascot, none of which trade-evolves, so a trade
-- leg ends on the swap itself. `spare` rides in slot 2: the cart refuses to
-- trade away a party's only mon ("That's your only POKeMON for battle."), so
-- a one-mon party can never offer anything.
--
-- `battle` is what the fight legs stage.  The 1v1s: a lead each, the host's
-- the stronger, so a knockout lands in two or three turns and the weaker side
-- still gets a blow in (the writeback check needs damage on both).  The
-- guest leads a PIKACHU on both carts: its THUNDER WAVE is what puts a status
-- on the host's mon in the classic 1v1, so "a link battle leaves no status
-- behind" is asserted on a status that is really there.  The co-op
-- legs: leads that do not evolve on a level-up (the host's exp is set one
-- point short of the next level, so its first knockout levels it -- and a
-- mon due to evolve would put the evolution scene into the leg), the map with
-- grass the wild leg walks (Route 1 / Route 101), and the trainer of the
-- trainer leg -- one of the maps' own early trainers, by the object's local
-- id on `trainerMap` (probed: a plain single-battle trainer with two
-- monsters, standing in the open, sight 2-4).
M.G3_STAGE = {
  firered = {
    map = "FR_PALLET_TOWN", place = "PALLET",
    host = { 12, 10, "down" }, guest = { 10, 12, "up" },
    hostMon = "CHARMANDER", guestMon = "PIKACHU", spare = "RATTATA",
    battle = {
      host = "CHARMANDER", hostLevel = 30, guest = "PIKACHU", guestLevel = 20,
      coopHost = "PIKACHU", coopHostLevel = 30, coopGuest = "RATICATE", coopGuestLevel = 25,
      wildMap = "FR_ROUTE_1", trainerMap = "FR_ROUTE_3", trainerLid = 3,
    },
  },
  emerald = {
    map = "EM_LITTLEROOT_TOWN", place = "LITTLEROOT",
    host = { 9, 9, "down" }, guest = { 7, 11, "up" },
    hostMon = "TORCHIC", guestMon = "MUDKIP", spare = "ZIGZAGOON",
    battle = {
      host = "TORCHIC", hostLevel = 30, guest = "PIKACHU", guestLevel = 20,
      coopHost = "PIKACHU", coopHostLevel = 30, coopGuest = "RATICATE", coopGuestLevel = 25,
      wildMap = "EM_ROUTE101", trainerMap = "EM_ROUTE102", trainerLid = 3,
    },
  },
}
M.G3_STAGE.leafgreen = M.G3_STAGE.firered

-- Wall-clock settling for animations the cart times in seconds rather than
-- frames (fades, the region map's open): a driver steps faster than real time
-- when nothing throttles the window, so a frame count can end before a fade
-- has.
function M.settleSeconds(game, seconds) -- luacheck: ignore game
  local timer = love and love.timer
  if not (timer and timer.getTime) then
    U.wait(math.floor((seconds or 1) * 60))
    return
  end
  local deadline = timer.getTime() + (seconds or 1)
  while timer.getTime() < deadline do U.wait(1) end
end

-- firered | leafgreen | emerald
function M.g3Version(game)
  local session = M.g3Session(game)
  if session and type(session.version) == "string" then return session.version end
  local GameVersion = g3mod("src.core.GameVersion")
  return GameVersion and GameVersion.get and GameVersion.get() or "firered"
end

-- A pret constant (SPECIES_*, ITEM_*, FLAG_*, OBJ_EVENT_GFX_*) resolved in this
-- cart's own table -- the ids differ between FireRed and Emerald, so a driver
-- names things and asks.
function M.g3Const(game, kind, name)
  local Constants = g3mod("src.core.game3.constants")
  if not (Constants and type(name) == "string") then return nil end
  local ok, set = pcall(Constants.of, M.g3Version(game))
  if not ok or not set then return nil end
  local okId, id = pcall(set.id, set, kind, name)
  return okId and id or nil
end

local function prefixed(prefix, name)
  name = tostring(name):upper():gsub("[%s%.%-]", "_")
  if name:sub(1, #prefix) ~= prefix then name = prefix .. name end
  return name
end

-- A numeric species (the internal numbering party mons carry) from a number
-- or a name ("PIKACHU", "SPECIES_TORCHIC").
function M.g3Species(game, species)
  if type(species) == "number" then return species end
  if type(species) ~= "string" then return nil end
  if tonumber(species) then return tonumber(species) end
  return M.g3Const(game, "species", prefixed("SPECIES_", species))
end

function M.g3ItemId(game, item)
  if type(item) == "number" then return item end
  if type(item) ~= "string" then return nil end
  if tonumber(item) then return tonumber(item) end
  return M.g3Const(game, "items", prefixed("ITEM_", item))
end

-- Close whatever the cart itself has up (its message, its YES / NO) and let a
-- warp land. Frames: all of it is this process, nothing on the wire.
function M.g3Settle(game, frames)
  local Warp = package.loaded["src.core.game3.warp"]
  for _ = 1, frames or 600 do
    local busy = (Warp and Warp.isBusy and Warp.isBusy()) or not M.g3Idle(game)
    if not busy then return true end
    if not M.g3Idle(game) then
      U.tap(game, "b")
      U.wait(2)
    end
    U.wait(1)
  end
  return M.g3Idle(game)
end

-- Title to the field on a Game3, the way the engine's own game3 drivers do it:
-- wait for the boot screen, answer it with a new game (the title menu's own
-- action, carrying the name and gender the cart's intro would have asked),
-- then wait for the field. opts: name, gender (0 boy / 1 girl), map/x/y/facing
-- to stand somewhere other than the bedroom (FireRed) or the moving truck
-- (Emerald) the new game opens in.
function M.g3BootToPlay(game, opts)
  opts = opts or {}
  for _ = 1, 1800 do
    if game.phase == "boot" and game.boot then break end
    if game.phase == "field" and game.session then break end
    U.wait(1)
  end
  if game.phase == "boot" then
    if not game.boot then
      U.log("FAIL the Gen 3 title never came up (phase " .. tostring(game.phase) .. ")")
      return false
    end
    game:_handleBootAction({
      action = "new_game",
      name = opts.name or "PLAYER",
      gender = opts.gender or 0,
    })
  end
  local reached = false
  for _ = 1, 2400 do
    if game.phase == "field" and game.session then reached = true break end
    U.wait(1)
  end
  if not reached then
    U.log("FAIL the Gen 3 new game never reached the field (phase "
      .. tostring(game.phase) .. ")")
    return false
  end
  U.wait(90)
  M.g3Settle(game, 600)
  if opts.map then
    M.g3Teleport(game, opts.map, opts.x, opts.y, opts.facing or "down")
  end
  return M.g3Idle(game)
end

-- Stand on a map. The engine's own game3 drivers do exactly this (Map.load
-- with the destination, then the session and Player singletons put on the
-- cell), and it is also what a warp ends in -- map.entered fires, the mod
-- re-injects its avatars into the fresh object list.
function M.g3Teleport(game, mapId, x, y, facing)
  facing = facing or "down"
  M.g3Settle(game, 600)
  local Map = g3mod("src.core.game3.map")
  local Player = g3mod("src.core.game3.player")
  if not (Map and Player) then return false end
  local ok, err = pcall(Map.load, nil, game, mapId, { x = x, y = y, facing = facing })
  if not ok then
    U.log("WARN Map.load " .. tostring(mapId) .. " failed: " .. tostring(err))
  end
  local session = M.g3Session(game)
  if session then session.x, session.y, session.facing, session.map = x, y, facing, mapId end
  Player.cellX, Player.cellY = x, y
  Player.px, Player.py = x * 16, y * 16
  Player.targetX, Player.targetY = x, y
  Player.facing = facing
  U.wait(40)
  M.g3Settle(game, 600)
  local cell = M.playerCell(game)
  return ok and cell ~= nil and cell.mapId == mapId and cell.x == x and cell.y == y
end

-- Append one mon to the live party through the cart's own givemon.
function M.g3GiveMon(game, species, level, nickname)
  local session = M.g3Session(game)
  local Party = g3mod("src.core.game3.party")
  local id = M.g3Species(game, species)
  if not (session and Party and id) then return nil end
  local ok, given, _, mon = pcall(Party.giveMon, session, id, level or 50, nickname)
  if not (ok and given) then return nil end
  return mon
end

-- Replace the live party with one mon (the Gen 3 arm of M.seedParty).
function M.g3SeedParty(game, species, level)
  local session = M.g3Session(game)
  if not session then return nil end
  session.party = {}
  return M.g3GiveMon(game, species, level or 50)
end

function M.g3GiveItem(game, item, count)
  local session = M.g3Session(game)
  local Bag = g3mod("src.core.game3.bag")
  local id = M.g3ItemId(game, item)
  if not (session and Bag and id) then return false end
  session.bag = session.bag or Bag.new()
  local ok, added = pcall(Bag.add, session.bag, id, count or 1)
  return ok and added ~= false
end

-- A cart event flag, set in the LIVE flag store (Space.store) the running
-- game reads, and in the session's snapshot as well so a save carries it.
function M.g3SetFlag(game, name, on)
  if on == nil then on = true end
  local id = M.g3Const(game, "flags", name)
  local Flags = g3mod("src.core.game3.scripting.flags")
  local Space = g3mod("src.core.game3.scripting.space")
  if not (id and Flags) then return false end
  local store = Space and Space.store
  if type(store) == "table" then pcall(Flags.setFlag, store, nil, id, on) end
  local session = M.g3Session(game)
  if session then
    session.flags = session.flags or {}
    pcall(Flags.setFlag, session, nil, id, on)
  end
  return true
end

function M.g3Flag(game, name)
  local id = M.g3Const(game, "flags", name)
  local Flags = g3mod("src.core.game3.scripting.flags")
  local Space = g3mod("src.core.game3.scripting.space")
  if not (id and Flags and Space and type(Space.store) == "table") then return false end
  local ok, set = pcall(Flags.getFlag, Space.store, nil, id)
  return ok and set == true
end

-- ------- badges (docs/plans/gen3-badge-rules.md)
--
-- The cart's own badge flags, FLAG_BADGE01_GET .. FLAG_BADGE08_GET (the same
-- pret name on FireRed / LeafGreen and Emerald; M.g3Const resolves each to its
-- cart's id).  A badge is the flag, which is also where the mod reads it from
-- (Gen3.badgeList, the engine's Engine.hasBadge order), so setting the flag is
-- how a leg gives a player a badge -- never a field on the referee.

function M.g3BadgeFlag(n)
  return ("FLAG_BADGE%02d_GET"):format(n)
end

-- Exactly these badges and no others (the rest cleared).  `list` is badge
-- numbers 1..8; an empty list takes every badge away.  True when every flag
-- reads back as asked, which is the live store the mod's own reading uses.
function M.g3SetBadges(game, list)
  local want = {}
  for _, n in ipairs(list or {}) do want[n] = true end
  local ok = true
  for n = 1, 8 do
    local on = want[n] == true
    if not M.g3SetFlag(game, M.g3BadgeFlag(n), on) then ok = false end
    if M.g3Flag(game, M.g3BadgeFlag(n)) ~= on then ok = false end
  end
  return ok
end

-- The badge numbers the live flag store holds, ascending.
function M.g3BadgesHeld(game)
  local out = {}
  for n = 1, 8 do
    if M.g3Flag(game, M.g3BadgeFlag(n)) then out[#out + 1] = n end
  end
  return out
end

-- A named upvalue of a function (the way modCtx reaches the mod's `ctx`): how
-- a driver gets at the very module instance the mod's own code holds -- the
-- referee's Damage, say -- rather than loading a second copy of it.
function M.fnUpvalue(fn, name)
  if type(fn) ~= "function" or not (debug and debug.getupvalue) then return nil end
  local i = 1
  while true do
    local upName, value = debug.getupvalue(fn, i)
    if not upName then return nil end
    if upName == name then return value end
    i = i + 1
  end
end

-- A badge set as "1,3,7": a stable thing to compare and to print.  Takes the
-- referee's set ({ [n] = true }) and the wire's list ({ "1", "3" }) alike;
-- anything that is not a badge 1..8 is left out, and nothing is "".
function M.badgeString(set)
  if type(set) ~= "table" then return "" end
  local held = {}
  for k, v in pairs(set) do
    local n
    if v == true then n = tonumber(k) else n = tonumber(v) end
    if n and n >= 1 and n <= 8 and n == math.floor(n) then held[n] = true end
  end
  local out = {}
  for n = 1, 8 do
    if held[n] then out[#out + 1] = tostring(n) end
  end
  return table.concat(out, ",")
end

-- A hostile client, for the one question a headless suite cannot ask of a
-- live hub: `mmo.battle_party` uploads on this instance's transport carry
-- `badges` whatever the mod's own screens decided to send.  Every upload this
-- instance makes (or, with `opts.side`, those for that side of the field) goes
-- out with the given badge list; the uploaded party table is copied, never
-- touched.  Returns a function that takes the wrapper off and answers how many
-- uploads it altered, or nil when the transport cannot be reached.
function M.forgeBadgeUploads(game, badges, opts)
  opts = opts or {}
  local ctx = M.modCtx(game)
  local transport = ctx and ctx.client and ctx.client.transport
  if not (transport and type(transport.send) == "function") then return nil end
  local inner = transport.send
  local forged = 0
  transport.send = function(self, msgType, payload)
    if msgType == "mmo.battle_party" and type(payload) == "table"
       and (opts.side == nil or payload.side == opts.side) then
      local copy = {}
      for k, v in pairs(payload) do copy[k] = v end
      copy.badges = {}
      for i, n in ipairs(badges) do copy.badges[i] = tostring(n) end
      forged = forged + 1
      return inner(self, msgType, copy)
    end
    return inner(self, msgType, payload)
  end
  return function()
    if transport.send ~= inner then transport.send = inner end
    return forged
  end
end

-- The battles the in-game hub on THIS instance is refereeing right now, as the
-- rules each fighter was built with: `{ id, mode, sim, uploaded = { [seat] =
-- "1,3" }, fighters = { { id, side, badges = "1,3", hasBadges, badgeRules,
-- family, fighter }, ... } }` for every record that has a live referee.  The
-- fighters are the hub's own (the K1 entry the referee kept), so what they say
-- is what the turn machine applies; `uploaded` is what each seat's client sent
-- (the sanitised party's badges), the other half of the question.  Empty when
-- this instance is not hosting.
function M.hubBattleView(game)
  local ctx = M.modCtx(game)
  local hub = ctx and ctx.server and ctx.server.hub
  local out = {}
  if not (hub and type(hub.battles) == "table") then return out end
  for id, record in pairs(hub.battles) do
    local sim = record and record.sim
    if sim and type(sim.fighters) == "table" then
      local row = { id = id, mode = record.mode, sim = sim, fighters = {}, uploaded = {} }
      for seat, party in pairs(record.parties or {}) do
        row.uploaded[seat] = M.badgeString(party and party.badges)
      end
      for _, fighter in ipairs(sim.fighters) do
        row.fighters[#row.fighters + 1] = {
          id = fighter.playerId, side = fighter.side,
          badges = M.badgeString(fighter.badges),
          hasBadges = fighter.badges ~= nil,
          badgeRules = fighter.badgeRules == true,
          family = fighter.family,
          fighter = fighter,
        }
      end
      out[#out + 1] = row
    end
  end
  return out
end

-- The National Dex, the way the cart turns it on (Dex.enableNational: the
-- dex's own national bit, the magic var and the flag), applied to the live
-- store as well as the session snapshot.
function M.g3EnableNationalDex(game)
  local session = M.g3Session(game)
  local Dex = g3mod("src.core.game3.dex")
  if not (session and Dex and Dex.enableNational) then return false end
  local okS = pcall(Dex.enableNational, session)
  local Space = g3mod("src.core.game3.scripting.space")
  local store = Space and Space.store
  if type(store) == "table" then
    pcall(Dex.enableNational, setmetatable({
      version = session.version, dex = session.dex,
      flags = store.flags, vars = store.vars,
    }, { __index = session }))
  end
  return okS
end

-- What a cart needs before it trades across regions (pokefirered
-- trade.c:CanTradeSelectedMon / pokeemerald link.c InitLocalLinkPlayer): the
-- "may link with the other region" progress flag -- FLAG_SYS_CAN_LINK_WITH_RS
-- on FireRed / LeafGreen, FLAG_IS_CHAMPION on Emerald -- and the National Dex.
-- The story sets these (the Sevii ruby delivery / the Elite Four); a driver
-- that starts a new game sets them the way it seeds a party.
function M.g3AllowCrossRegionTrade(game)
  local version = M.g3Version(game)
  local flag = version == "emerald" and "FLAG_IS_CHAMPION" or "FLAG_SYS_CAN_LINK_WITH_RS"
  local okF = M.g3SetFlag(game, flag, true)
  local okD = M.g3EnableNationalDex(game)
  return okF and okD and M.g3Flag(game, flag)
end

-- START, the button, until the cart's START layer is up. The field ignores
-- START mid-step, so a press that lands during a step is retried.
function M.g3OpenStart(game)
  if not M.g3Idle(game) then M.closeToOverworld(game) end
  for _ = 1, 4 do
    U.tap(game, "start")
    if M.waitFor(game, function() return M.g3Has("start") end, 45, "the START menu") then
      U.wait(6)
      return true
    end
    U.wait(20)
  end
  return false
end

-- A START row by its id (the rows' labels are the cart's own text; ids are
-- stable -- "bag", "pokenav", "rby_mmo", ...).
function M.g3StartRow(game, id)
  local SM = package.loaded["src.ui.game3.start_menu"]
  if not (SM and M.g3Has("start")) then return false end
  local target
  for i, e in ipairs(SM.ENTRIES or {}) do
    if e.id == id then target = i break end
  end
  if not target then
    U.log("WARN no START row with id " .. tostring(id) .. ": " .. M.rowLabels(game))
    return false
  end
  for _ = 1, #SM.ENTRIES * 2 do
    if SM.cursor == target then break end
    U.tap(game, SM.cursor < target and "down" or "up")
    U.wait(3)
  end
  U.wait(2)
  U.tap(game, "a")
  U.wait(10)
  return true
end

-- START > MMO > the MAIN layer.
M.G3_MAIN = "rby_mmo:RbyMmoMain"

function M.g3OpenMmo(game)
  if not M.g3OpenStart(game) then
    U.log("WARN START did not open; up is " .. M.stackNames(game))
    return false
  end
  if not M.selectLabel(game, "MMO") then return false end
  return M.waitFor(game, function() return M.g3LayerId() == M.G3_MAIN end, 90,
                   "the MMO menu layer")
end

-- The injected event object standing in for `playerId` on this map (Avatars
-- marks it `mmoAvatar`), or nil.
function M.g3AvatarObject(playerId)
  local Objects = package.loaded["src.core.game3.objects"]
  if not Objects then return nil end
  for _, localId in ipairs(Objects._order or {}) do
    local eo = Objects._byId and Objects._byId[localId]
    if eo and eo.mmoAvatar == playerId then return eo, localId end
  end
  return nil
end

-- One step per direction; `run` holds B with it (running shoes permitting).
function M.g3Walk(game, dirs, run)
  for _, dir in ipairs(dirs) do
    if run then
      M.holdAll(game, { dir, "b" }, 12)
    else
      U.hold(game, dir, 16)
    end
    U.wait(6)
  end
end

-- The lines in the corner right now (Toast:state().lines).
function M.toastLines(exports)
  local out = {}
  local st = exports and exports.toasts and exports.toasts() or nil
  for _, line in ipairs((st and st.lines) or {}) do
    out[#out + 1] = tostring(type(line) == "table" and line.text or line)
  end
  return out
end

-- Wait (wall clock) for the corner to empty, so a screen photographed next
-- is not half hidden behind a toast -- the corner draws over the top rows of
-- a Gen 3 menu. The toast legs photograph the corner on purpose, before this.
function M.awaitToastsClear(game, exports, seconds)
  return M.waitSeconds(game, function() return #M.toastLines(exports) == 0 end,
                       seconds or 12, "the toasts to clear")
end

function M.toastSays(exports, needle)
  for _, line in ipairs(M.toastLines(exports)) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end

function M.chatHas(exports, text, name)
  for _, line in ipairs((exports and exports.chat and exports.chat()) or {}) do
    if line.text == text and (name == nil or line.name == name) then return true end
  end
  return false
end

-- Say something through the menus a player uses: MMO > SAY > <scope row> >
-- the letter grid > START. `scopeLabel` is EVERYONE / NEARBY / PARTY.
-- Returns whether the grid held exactly `text` when it was submitted.
function M.sayViaMenu(game, scopeLabel, text)
  if not M.openMmo(game) then return false end
  U.wait(10)
  if not M.selectLabel(game, "SAY") then return false end
  U.wait(15)
  if not M.selectLabel(game, scopeLabel or "EVERYONE") then return false end
  U.wait(20)
  local grid = M.top(game)
  if not (grid and type(grid.glyphs) == "table") then
    U.log("WARN SAY opened no letter grid; up is " .. M.stackNames(game))
    return false
  end
  if not M.typeOnGrid(game, text) then return false end
  local typed = table.concat(grid.glyphs)
  if typed ~= text then
    U.log("WARN the SAY grid holds " .. typed .. ", not " .. text)
    return false
  end
  U.tap(game, "start")
  U.wait(20)
  return true
end

-- Screenshots named g3-<game>-<role>-<NN>-<leg>.png, numbered in the order
-- the driver takes them, so a contact sheet sorts into the run's own order
-- and a leg appended later needs no renumbering. `printed` waits for a text
-- box to finish typing first (M.shotPrinted).
function M.g3Shooter(game, dir, gameName, role)
  local n = 0
  return function(leg, printed, dropIfBlack)
    n = n + 1
    local path = ("%s/g3-%s-%s-%02d-%s.png"):format(dir, gameName, role, n, leg)
    local ok
    if printed then ok = M.shotPrinted(game, path) else ok = U.shot(game, path) end
    -- a frame caught mid-fade (the cover a co-op divert holds while the
    -- battle transition plays) can be all black: a picture of nothing is
    -- dropped rather than shipped to the contact sheet
    if dropIfBlack and ok and M.pngIsBlack(path) then
      os.remove(path)
      return false
    end
    return ok
  end
end

-- Is this screenshot one flat black frame?  Sampled on a coarse grid.
function M.pngIsBlack(path)
  -- the shot is outside LOVE's filesystem: read the bytes, decode from memory
  local handle = io.open(path, "rb")
  if not handle then return false end
  local bytes = handle:read("*a")
  handle:close()
  local okImg, data = pcall(function()
    return love.image.newImageData(love.filesystem.newFileData(bytes, "shot.png"))
  end)
  if not (okImg and data) then return false end
  local w, h = data:getWidth(), data:getHeight()
  for y = 0, h - 1, 16 do
    for x = 0, w - 1, 16 do
      local r, g, b = data:getPixel(x, y)
      if r > 0.02 or g > 0.02 or b > 0.02 then return false end
    end
  end
  return true
end

-- The party list over the region map, reached the way a player reaches the
-- map. FireRed / LeafGreen: the TOWN MAP key item, used from the BAG (START >
-- BAG > KEY ITEMS > TOWN MAP > USE -- the cart's item_use "map" path). The
-- key item is seeded first, as a driver seeds a party. Emerald has no Town
-- Map item; its region map layer (rse_region_map) is the one the cart puts up
-- for a wall map (special FieldShowRegionMap) and for FLY, and it is opened
-- here through that special's own entry, RegionMap.show{ mode = "wall" }.
-- Returns the layer id that came up, or nil.
function M.g3OpenRegionMap(game)
  local version = M.g3Version(game)
  if version == "emerald" then
    M.closeToOverworld(game)
    local RseMap = g3mod("src.ui.game3.rse.region_map")
    if not RseMap then return nil end
    local ok, err = pcall(RseMap.show, { session = M.g3Session(game), mode = "wall" })
    if not ok then U.log("WARN rse region map: " .. tostring(err)) return nil end
    if M.waitFor(game, function() return M.g3Has("rse_region_map") end, 120,
                 "the Hoenn map") then
      U.wait(30)
      M.settleSeconds(game, 1.5)
      return "rse_region_map"
    end
    return nil
  end

  local TOWN_MAP = M.g3ItemId(game, "TOWN_MAP")
  local Bag = g3mod("src.core.game3.bag")
  local session = M.g3Session(game)
  if not (TOWN_MAP and Bag and session) then return nil end
  if not (session.bag and Bag.has(session.bag, TOWN_MAP, 1)) then
    M.g3GiveItem(game, TOWN_MAP, 1)
  end
  if not M.g3OpenStart(game) then return nil end
  if not M.g3StartRow(game, "bag") then return nil end
  local BagMenu = g3mod("src.ui.game3.bag_menu")
  if not (BagMenu and M.waitFor(game, function() return BagMenu.isOpen() end, 120, "the BAG")) then
    return nil
  end
  U.wait(40) -- the bag's open transition eats input for 23 frames
  for _ = 1, 8 do
    if BagMenu.currentPocket() == "KEY_ITEMS" then break end
    U.tap(game, "right")
    U.wait(24)
  end
  if BagMenu.currentPocket() ~= "KEY_ITEMS" then
    U.log("WARN the bag never reached KEY ITEMS (on " .. tostring(BagMenu.currentPocket()) .. ")")
    return nil
  end
  local row
  for i, r in ipairs(BagMenu.list() or {}) do
    if r.id == TOWN_MAP then row = i break end
  end
  if not row then
    U.log("WARN no TOWN MAP in KEY ITEMS")
    return nil
  end
  for _ = 1, 40 do
    if BagMenu.cursor == row then break end
    U.tap(game, BagMenu.cursor < row and "down" or "up")
    U.wait(4)
  end
  U.tap(game, "a")
  U.wait(12)
  if BagMenu.mode == "action" then
    local use
    for i, act in ipairs(BagMenu.ACTIONS or {}) do
      if act == "USE" then use = i break end
    end
    for _ = 1, 8 do
      if use == nil or BagMenu.actionCursor == use then break end
      U.tap(game, "down")
      U.wait(4)
    end
    U.tap(game, "a")
  end
  if M.waitFor(game, function() return M.g3Has("region_map") end, 240, "the Town Map") then
    U.wait(30)
    M.settleSeconds(game, 1.5)
    return "region_map"
  end
  return nil
end

-- B out of the region map and back to the field. Closing the Town Map lands
-- back in the BAG over START (the cart's own order, measured: "start > bag"),
-- so B backs out of both; the bag's exit transition and the field's resume
-- then take a moment before START is taken again -- waited out here, the way
-- a player waits for the screen to settle before pressing it.
function M.g3CloseRegionMap(game)
  for _ = 1, 6 do
    if not (M.g3Has("region_map") or M.g3Has("rse_region_map")) then break end
    U.tap(game, "b")
    U.wait(30)
  end
  local closed = M.closeToOverworld(game, 32)
  local Field = package.loaded["src.core.game3.field"]
  local Warp = package.loaded["src.core.game3.warp"]
  for _ = 1, 240 do
    local locked = (Field and Field.locked) or (Warp and Warp.isBusy and Warp.isBusy())
    if not locked then break end
    U.wait(1)
  end
  U.wait(45)
  return closed
end

-- =====================================================================
-- Gen 3 battle legs (wave 5): the mod's own battle screens on FireRed / Emerald
-- =====================================================================
--
-- A Gen 3 fight of this mod's is a Gen3Ui.pushState layer: the layer's `mod`
-- IS the screen (MediatedBattle for a 1v1, CoopBattle for a 2-on-2), so
-- M.g3Top returns it and every field a Gen 1 driver reads off those screens
-- (`phase`, `commandIndex`, `cursor` / `moveIndex`, `shown`, `draining`,
-- `result`, `gaps` / `medGaps`) is there under the same name.  What has no Gen 1
-- twin is how a fight *starts*: the cart raises no screen event, so a co-op
-- divert happens at `encounter.roll` (a wild) and at a wrap of
-- BattleBridge.start (a trainer), and the drivers below reach the second one
-- the way the cart's own script opcode does.

-- The mod's battle screen when it is the top layer, and which kind it is.
function M.g3Fight(game)
  local top = M.g3Top(game)
  if type(top) ~= "table" then return nil end
  if top.mmoBattle == true then return top, "1v1" end
  if top.sim ~= nil and top.mode ~= nil then return top, "coop" end
  return nil
end

-- Is `state` a layer anywhere on the game3 stack (not only on top)?  A move-
-- learn prompt or the nickname grid goes up *over* a fight that is not done.
function M.g3OnStack(state)
  if state == nil then return false end
  local Stack = package.loaded["src.ui.game3.stack"]
  for _, layer in ipairs((Stack and Stack._layers) or {}) do
    if layer.mod == state then return true end
  end
  return false
end

-- What a party looks like to the things a fight could change: the writeback
-- checks compare two of these.  Species and level identify the mon; hp,
-- exp, held item, status and PP are what a link battle must leave alone.
function M.g3PartyDigest(game)
  local out = {}
  local session = M.g3Session(game)
  for i, mon in ipairs((session and session.party) or {}) do
    local pp = {}
    for j, v in ipairs(mon.pp or {}) do pp[j] = tonumber(v) or 0 end
    local moves = {}
    for j, v in ipairs(mon.moves or {}) do moves[j] = tonumber(type(v) == "table" and v.id or v) or 0 end
    out[i] = {
      species = mon.species, level = tonumber(mon.level) or 0, hp = tonumber(mon.hp) or 0,
      maxHp = tonumber(mon.maxHp) or 0, exp = tonumber(mon.exp) or 0,
      item = tonumber(mon.heldItem or mon.item) or 0, status = mon.status,
      pp = table.concat(pp, ","), moves = table.concat(moves, ","),
    }
  end
  return out
end

-- The first difference between two digests as "party[1].hp 30 -> 12", or nil.
-- `fields` limits the comparison (default: all).
function M.g3DigestDiff(a, b, fields)
  fields = fields or { "species", "level", "hp", "maxHp", "exp", "item", "status", "pp", "moves" }
  if #a ~= #b then return ("party size %d -> %d"):format(#a, #b) end
  for i = 1, #a do
    for _, key in ipairs(fields) do
      if a[i][key] ~= b[i][key] then
        return ("party[%d].%s %s -> %s"):format(i, key, tostring(a[i][key]), tostring(b[i][key]))
      end
    end
  end
  return nil
end

-- Put the hardest-hitting move first (moves / pp / maxPp move together): the
-- Gen 3 twin of M.frontloadDamage, which reads Gen 1 / Gen 2 move tables.
-- Power comes from the cart's own move rows, so nothing here names a number.
function M.g3FrontloadDamage(mon)
  local Moves = g3mod("src.core.game3.battle.moves")
  if not (Moves and type(mon) == "table" and type(mon.moves) == "table") then return nil end
  local best, bestPower
  for i, id in ipairs(mon.moves) do
    local ok, row = pcall(Moves.get, tonumber(id))
    local power = ok and type(row) == "table" and tonumber(row.power) or 0
    if power > 0 and (bestPower == nil or power > bestPower) then best, bestPower = i, power end
  end
  if not best or best == 1 then return mon.moves[1] end
  for _, key in ipairs({ "moves", "pp", "maxPp" }) do
    local list = mon[key]
    if type(list) == "table" and list[best] ~= nil then
      table.insert(list, 1, table.remove(list, best))
    end
  end
  return mon.moves[1]
end

-- A fresh one-mon (plus optional spare) party that fights straight away:
-- full HP, no status, a damaging move first, and -- with `exp` -- the exp set
-- one point under the next level so the first knockout it earns levels it up.
function M.g3SeedLead(game, species, level, opts)
  opts = opts or {}
  local mon = M.g3SeedParty(game, species, level)
  if not mon then return nil end
  M.g3FrontloadDamage(mon)
  mon.hp = mon.maxHp
  mon.status = nil
  if opts.spare then M.g3GiveMon(game, opts.spare, opts.spareLevel or 5) end
  if opts.levelUpNext then
    local Experience = g3mod("src.core.game3.battle.experience")
    if Experience and Experience.expForLevel then
      local ok, threshold = pcall(Experience.expForLevel, mon, mon.level + 1)
      if ok and tonumber(threshold) then mon.exp = tonumber(threshold) - 1 end
    end
  end
  return mon
end

-- Stand next to another player's avatar the way a player does before pressing
-- A: one cell above (facing down) or below (facing up) their reported cell.
-- Returns the avatar object and its row.
function M.g3StandBeside(game, exports, name, side)
  local row = M.avatarRow(exports, name)
  if not (row and row.rosterX) then return nil end
  local dy, facing = -1, "down"
  if side == "below" then dy, facing = 1, "up" end
  M.g3Teleport(game, row.map or M.g3Session(game).map, row.rosterX, row.rosterY + dy, facing)
  U.wait(30)
  return row
end

-- Answer what the mod (or the cart) puts over a fight that is not finished:
-- the cart's YES / NO is answered YES (the move-learning exchange ends on it
-- either way: "Delete a move?" YES -> the picker -> B -> "Stop learning?" YES),
-- the forget picker is backed out of, the nickname grid keeps the species
-- name, and any text advances.
local function g3AnswerOver(game, top)
  local layerId = M.g3LayerId()
  if layerId == "naming" then
    U.tap(game, "start")
    U.wait(8)
    U.tap(game, "a")
    U.wait(8)
    return
  end
  if layerId == "summary" or layerId == "summary_menu" then
    U.tap(game, "b")
    U.wait(8)
    return
  end
  if type(top) ~= "table" then U.wait(4) return end
  local yes = type(top.items) == "table" or (top.onChoose ~= nil and top.index ~= nil)
  if yes then
    for _ = 1, 4 do
      if (top.index or top.cursor or 1) <= 1 or M.top(game) ~= top then break end
      U.tap(game, "up")
      U.wait(3)
    end
    U.tap(game, "a")
    U.wait(10)
    return
  end
  U.tap(game, "a")
  U.wait(8)
end

local function g3ShownText(top)
  local s = top and top.shown
  if type(s) == "table" then s = table.concat(s, " ") end
  return type(s) == "string" and s or ""
end

-- Drive a Gen 3 battle screen of this mod from its opening line to its last:
-- FIGHT with the strongest move that has PP, A through every line, one
-- screenshot the first time each of these is seen -- the opening line, the
-- command menu, the move list, a hit landing (the HP bar moving), a knockout,
-- EXP / a level-up, the result -- and a log of every distinct line it said.
-- The Gen 1 flows drove this with drivePrompts' blind A; a Gen 3 arena has to
-- be photographed at the moments it is worth photographing, so the taps here
-- are keyed on the screen's own `phase`.
--
-- opts: shot(name, printed) -- the driver's shooter; label -- prefix for the
-- shot names; seconds -- the whole fight's budget (wall clock); startSeconds --
-- how long to wait for the fight to appear; pick(top, moves) -> move index;
-- onChoose(top) -- called with every command menu, before FIGHT is pressed
-- (return "skip" to press nothing).  Returns
-- { kind, turns, result, said = {...}, seen = { intro, command, moves, hit,
-- faint, exp, levelup, result }, gaps, ended }.
function M.g3PilotFight(game, opts)
  opts = opts or {}
  local shot = opts.shot or function() end
  local label = opts.label or "fight"
  local out = { turns = 0, said = {}, seen = {}, ended = false }
  local startAt = os.time()
  local deadline = startAt + (opts.seconds or 300)
  local state, kind
  local lastShown = ""
  local lastA = 0
  local frame = 0
  local settleFrames = 0

  local function said(text)
    if text ~= "" and out.said[#out.said] ~= text then out.said[#out.said + 1] = text end
  end
  local function once(key, after)
    if out.seen[key] then return end
    out.seen[key] = true
    U.wait(after or 0)
    shot(label .. "-" .. key)
  end

  while os.time() < deadline do
    frame = frame + 1
    local top, k = M.g3Fight(game)
    if top ~= nil then
      if state == nil then state, kind = top, k end
      out.kind = kind
      out.gaps = tonumber(top.gaps) or tonumber(top.medGaps) or out.gaps
      out.result = top.result or out.result
      out.mode = top.mode or out.mode
      out.mediated = top.mediated == true or top.mmoBattle == true or out.mediated
      if top.sim and type(top.sim.slots) == "table" then out.slots = #top.sim.slots end
      local phase = top.phase
      local text = g3ShownText(top)
      if text ~= lastShown then said(text) lastShown = text end

      -- an arena that has not drawn a line yet is still in its entry
      if not out.seen.intro and text ~= "" and phase ~= "choose" then
        once("intro", 24)
      end
      if phase == "choose" and not (top.replacing or top.mustReplace) and top.result == nil then
        if not out.seen.command then
          U.wait(14)
          once("command")
        end
        local skip = opts.onChoose and opts.onChoose(top) == "skip"
        if not skip then
          top.commandIndex = 1
          U.tap(game, "a")
          U.wait(8)
        else
          U.wait(6)
        end
      elseif phase == "move" then
        if not out.seen.moves then
          U.wait(10)
          once("moves")
        end
        local moves = (function()
          if type(top.liveMoves) == "function" then
            local ok, list = pcall(top.liveMoves, top)
            if ok and type(list) == "table" then return list end
          end
          local mon = top.activeMon and top:activeMon()
          return mon and mon.moves or {}
        end)()
        local want = opts.pick and opts.pick(top, moves, out.turns + 1) or nil
        if not want then
          local bestPower = -1
          want = 1
          for i, mv in ipairs(moves) do
            local power = tonumber(mv.power) or 0
            if power > bestPower and (tonumber(mv.pp) or 0) > 0 then want, bestPower = i, power end
          end
        end
        for _ = 1, #moves + 1 do
          local at = top.cursor or top.moveIndex or 1
          if at == want or M.top(game) ~= top then break end
          U.tap(game, "down")
          U.wait(4)
        end
        U.tap(game, "a")
        U.wait(8)
        if top.phase ~= "move" then out.turns = out.turns + 1 end
      elseif phase == "target" or phase == "switch" or phase == "replace" then
        U.tap(game, "a")
        U.wait(8)
      else
        -- lines and animations: what is on screen decides the shot (the
        -- move's own line for a hit -- its effect plays and the bar falls
        -- behind it), A advances the text, and both are kept off the frame
        -- that matters
        local lower = text:lower()
        if lower:find(" used ", 1, true) and not out.seen.hit then once("hit", 26) end
        if lower:find("fainted", 1, true) and not out.seen.faint then once("faint", 28) end
        if (lower:find("exp", 1, true) and lower:find("gained", 1, true)) and not out.seen.exp then
          once("exp", 28)
        end
        if lower:find("grew to", 1, true) and not out.seen.levelup then once("levelup", 28) end
        -- the result is the ending's own last line: the outcome is known long
        -- before it is narrated, so wait for the queue to run dry with a line up
        local queued = #(top.lines or top.messages or {})
        if top.result ~= nil and queued == 0 and not top.draining and text ~= ""
           and not out.seen.result then
          once("result", 24)
        end
        if frame - lastA >= 5 then
          U.tap(game, "a")
          lastA = frame
        end
        U.wait(2)
      end
    elseif state ~= nil and M.g3OnStack(state) then
      -- the fight is still there, under a prompt it raised: one picture of
      -- each kind (the nickname question, the naming grid, a move to forget),
      -- then answer it
      local over = M.g3Top(game)
      local key = M.g3LayerId() or (type(over) == "table" and over.g3Engine) or "text"
      key = tostring(key):gsub("[^%w]+", "-")
      if not out.seen["prompt-" .. key] and (out.prompts or 0) < 4 then
        out.prompts = (out.prompts or 0) + 1
        out.seen["prompt-" .. key] = true
        U.wait(24)
        -- a text box is photographed once it has finished typing
        shot(label .. "-prompt-" .. key, type(over) == "table" and type(over.pages) == "table")
      end
      g3AnswerOver(game, M.g3Top(game))
    elseif state ~= nil then
      out.ended = true
      break
    else
      if os.time() - startAt > (opts.startSeconds or 120) then break end
      U.wait(4)
    end
  end
  return out
end

-- ------- Gen 3 co-op field helpers

-- The tall-grass cell on `mapId` with grass above and below it, so walking up
-- and down keeps rolling the step encounter, and the first cell beside it
-- (for a partner to stand on).  The engine's own game3_cut_grass driver finds
-- its patch the same way.
function M.g3GrassCells(game, mapId)
  local Map = g3mod("src.core.game3.map")
  local Collision = g3mod("src.core.game3.collision")
  local Objects = g3mod("src.core.game3.objects")
  local def = game and game.data and game.data.maps and game.data.maps[mapId]
  local L = type(def) == "table" and def.midLayout or nil
  if not (Map and Collision and Objects and L) then return nil end
  if Map.current ~= mapId then M.g3Teleport(game, mapId, 1, 1, "down") end
  local function grass(x, y)
    local ok, g = pcall(Collision.isGrass, x, y)
    return ok and g and not Objects.at(x, y)
  end
  for y = 2, (tonumber(L.height) or 0) - 3 do
    for x = 1, (tonumber(L.width) or 0) - 3 do
      if grass(x, y) and grass(x, y - 1) and grass(x, y + 1) and grass(x + 1, y)
         and grass(x + 1, y - 1) and grass(x + 1, y + 1) then
        return { x = x, y = y }, { x = x + 1, y = y }
      end
    end
  end
  return nil
end

-- The event object of the trainer who stands `cell` cells from the player's
-- line, by its map-local id (the probe: trainers are the objects with a sight
-- range and trainerType 1..3).  nil when it is not on the live map.
function M.g3ObjectById(localId)
  local Objects = package.loaded["src.core.game3.objects"]
  if not Objects then return nil end
  return Objects._byId and Objects._byId[localId] or nil
end

-- Has the cart marked this trainer beaten?  (trainer_sight.lua's own check:
-- FLAG_TRAINER_<id> in the live flag store.)
function M.g3TrainerDefeated(eo)
  local TrainerSight = g3mod("src.core.game3.trainer_sight")
  local Space = g3mod("src.core.game3.scripting.space")
  if not (TrainerSight and Space and eo) then return nil end
  local ok, done = pcall(TrainerSight.isDefeated, eo, Space.store, nil)
  if not ok then return nil end
  return done == true
end

-- The trainer id the cart's script names for this object (nil when unknown).
function M.g3TrainerId(eo)
  local TrainerSight = g3mod("src.core.game3.trainer_sight")
  if not (TrainerSight and eo) then return nil end
  local ok, tid = pcall(TrainerSight.getTrainerId, eo)
  return ok and tid or nil
end

-- Clear a trainer's beaten flag, so a leg can be run twice on one cart.
function M.g3ClearTrainer(eo)
  local tid = M.g3TrainerId(eo)
  local Flags = g3mod("src.core.game3.scripting.flags")
  local Space = g3mod("src.core.game3.scripting.space")
  if not (tid and Flags and Space and type(Space.store) == "table") then return false end
  local ok = pcall(Flags.setFlag, Space.store, nil, Flags.trainerFlagId(tid), false)
  return ok
end

-- The lowest-level trainer in the cart's book with a party of two or more (a
-- co-op 2-on-2 needs a foe for each seat) and a plain, single-battle class.
-- Ids only; nothing about what they hold is asserted anywhere.
function M.g3CoopTrainer(data)
  local Trainers = g3mod("src.core.game3.scripting.trainers")
  local GameVersion = g3mod("src.core.GameVersion")
  if not Trainers then return nil end
  local emerald = GameVersion and GameVersion.get and GameVersion.get() == "emerald"
  local pack = Trainers.pack() or {}
  local bestId, bestTotal
  for id, row in pairs(pack.trainers or {}) do
    local tid = tonumber(id)
    local party = type(row) == "table" and row.party or nil
    if tid and tid > 0 and type(party) == "table" and #party >= 2 and #party <= 3
       and not row.doubleBattle and type(row.name) == "string" and row.name ~= "" then
      local class = tonumber(row.class) or 0
      local plain = (emerald or (class >= 57 and class ~= 98)) and class ~= 81
        and class ~= 89 and class ~= 90
      local total = 0
      for _, spec in ipairs(party) do total = total + (tonumber(spec.level) or 0) end
      if plain and total >= 6 and (bestTotal == nil or total < bestTotal
         or (total == bestTotal and tid < bestId)) then
        bestId, bestTotal = tid, total
      end
    end
  end
  return bestId, bestTotal
end

-- The Gen 3 twin of assertTrainerKit: the trainer's own kit (the cart's trainer
-- record lists its items, numeric ids and a 0 for an empty slot) against what
-- the in-process referee seated for it.  Only the in-game host holds a hub to
-- look into; a guest skips, as on Gen 1.  `opts.class` is the trainer id.
-- Item ids stay out of the log: counts only.
function M.g3AssertTrainerKit(game, check, log, opts)
  local Trainers = g3mod("src.core.game3.scripting.trainers")
  local tid = tonumber(opts and opts.class)
  local expected
  if Trainers and tid then
    local ok, row = pcall(Trainers.get, tid)
    if ok and type(row) == "table" and type(row.items) == "table" then
      expected = 0
      for _, id in ipairs(row.items) do
        if (tonumber(id) or 0) > 0 then expected = expected + 1 end
      end
    end
  end
  local function total(bag)
    local n = 0
    for _, count in pairs(type(bag) == "table" and bag or {}) do n = n + (tonumber(count) or 0) end
    return n
  end
  local npc = M.hubNpcBags(game)
  if not npc then
    if log then log("skip trainer kit -- no in-process hub on this side") end
    return
  end
  local actual = total(npc.bags[1])
  if log then
    log(("trainer kit expected: %s item(s), actual: %d item(s) over %d seat(s)")
      :format(expected == nil and "?" or tostring(expected), actual, npc.n))
  end
  if npc.n >= 2 then
    check(npc.shared == true, "both NPC seats share one bag -- a 2v2 does not clone the kit",
          tostring(total(npc.bags[1])) .. " / " .. tostring(total(npc.bags[2])))
  end
  check(actual < 8, "the trainer is not carrying two gym kits", tostring(actual))
  if expected ~= nil then
    check(actual <= expected, "no more items than the trainer's own kit",
          ("%d > %d"):format(actual, expected))
    if expected == 0 then
      check(actual == 0, "a trainer with no items carries none -- not potion spam", tostring(actual))
    end
  end
end

-- A mod option, set the way the F10 manager row's step() does: the live store
-- `mod.options:get` reads (game.mods.modOptions).  Fights latch options at
-- construction, so a flip takes effect from the next fight.
function M.g3SetOption(game, key, value)
  local store = game and game.mods and game.mods.modOptions
  if type(store) ~= "table" then return false end
  store.rby_mmo = store.rby_mmo or {}
  store.rby_mmo[key] = value
  return true
end

-- Which legs a run drives, from GEN3_LEGS (comma list; default all).  Legs:
-- chat, social (ADD FRIEND / FRIENDS / RANK), trade, battle (the two 1v1s),
-- party (invite / members / region map / leave), coop (wild + trainer, which
-- need the party, so asking for coop asks for party).  Boot, hosting / joining
-- and presence always run: every other leg stands on them.
local ALL_LEGS = { "chat", "social", "trade", "battle", "party", "coop" }
function M.g3Leg(name)
  local raw = os.getenv("GEN3_LEGS")
  if raw == nil or raw == "" or raw == "all" then return true end
  local on = {}
  for part in raw:gmatch("[^,%s]+") do on[part:lower()] = true end
  if on.coop then on.party = true end
  return on[name] == true
end
M.G3_LEGS = ALL_LEGS

-- Has a marker been signalled (by either side)?  For a result one side leaves
-- for the other to read, next to the barriers that order the two.
function M.signaled(name)
  local handle = io.open(M.syncPath(name), "r")
  if not handle then return false end
  handle:close()
  return true
end

-- A walkable cell one step from (x, y), off every visible trainer's line of
-- sight on the live map, for a partner to stand on while the other walks into
-- a trainer.  nil when the map offers none.
function M.g3FreeCellNear(x, y)
  local Collision = g3mod("src.core.game3.collision")
  local Objects = g3mod("src.core.game3.objects")
  if not (Collision and Objects) then return nil end
  local vec = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
  local cone = {}
  for _, lid in ipairs(Objects._order or {}) do
    local eo = Objects._byId and Objects._byId[lid]
    local d = eo and vec[eo.facing or ""]
    if eo and d and (tonumber(eo.sight) or 0) > 0 and (tonumber(eo.trainerType) or 0) > 0 then
      for k = 1, tonumber(eo.sight) do cone[(eo.cellX + d[1] * k) .. "," .. (eo.cellY + d[2] * k)] = true end
    end
  end
  for _, step in ipairs({ { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 }, { 1, 1 }, { -1, 1 } }) do
    local cx, cy = x + step[1], y + step[2]
    local okW, walkable = pcall(Collision.isWalkable, cx, cy)
    local blocked = Objects.at and Objects.at(cx, cy)
    if okW and walkable and not blocked and not cone[cx .. "," .. cy] then return cx, cy end
  end
  return nil
end

-- Where to stand to walk into a trainer's line of sight, from the trainer's
-- event object: one cell past the end of the cone (sight + 1 along the way the
-- trainer faces), looking back at them -- so the next step in is a real
-- "walked into sight" rather than a teleport onto the cone.  Returns the cell
-- and the direction to walk.
function M.g3SightApproach(eo)
  local vec = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
  local back = { up = "down", down = "up", left = "right", right = "left" }
  local d = vec[eo.facing]
  if not d then return nil end
  local dist = (tonumber(eo.sight) or 1) + 1
  return eo.cellX + d[1] * dist, eo.cellY + d[2] * dist, back[eo.facing]
end

-- Is the cart's script VM running (a trainer talking, a door opening)?
function M.g3ScriptRunning()
  local Space = package.loaded["src.core.game3.scripting.space"]
  local vm = Space and Space.vm
  return vm ~= nil and type(vm.isRunning) == "function" and vm:isRunning() == true
end

-- The player is free to walk: nothing up, no script, no warp, no lock.
function M.g3Free(game)
  if not M.g3Idle(game) then return false end
  local Field = package.loaded["src.core.game3.field"]
  if Field and Field.locked then return false end
  local Warp = package.loaded["src.core.game3.warp"]
  if Warp and Warp.isBusy and Warp.isBusy() then return false end
  return not M.g3ScriptRunning()
end

-- Let the cart finish what it is saying: A on its message box (and nothing
-- else -- a YES / NO or one of the mod's layers is never answered here) until
-- the player is free again.  Wall clock: a trainer's approach and speech, and
-- the flags a win sets, are the cart's own pace.
function M.g3TalkUntilFree(game, seconds)
  return M.waitSeconds(game, function()
    if M.g3Free(game) then return true end
    local top = M.g3Top(game)
    if type(top) == "table" and top.g3Engine == "message" and M.g3Layer() == nil then
      U.tap(game, "a")
      U.wait(6)
    else
      U.wait(4)
    end
    return false
  end, seconds or 60, "the cart to finish talking")
end

-- How many of an item the live bag holds (item by name or number).
function M.g3BagCount(game, item)
  local Bag = g3mod("src.core.game3.bag")
  local session = M.g3Session(game)
  local id = M.g3ItemId(game, item)
  if not (Bag and session and session.bag and id) then return nil end
  local ok, n = pcall(Bag.get, session.bag, id)
  if not ok then return nil end
  if type(n) == "table" then n = n.qty or n.count or n.quantity end
  return tonumber(n) or 0
end

return M
