-- Gen 1 / Gen 2 / Gen 3 helpers for presence, save fields, and UI ids.
--
-- One place for the shape differences that every presence/save call site
-- would otherwise hardcode: money lives on save vs save.player vs the Gen 3
-- session, dex uses owned vs caught, free-roam is "overworld on top" vs
-- "empty stack" vs "field phase with nothing in front of it", and spawn
-- movement is STAY+range vs numeric STANDING_* vs an event-object template.
-- Callers pass a game when they have one; generation falls back through
-- Handshake / Fingerprint and the loader's own generation, and defaults to 1
-- so a headless load without data stays Gen 1-shaped.
--
-- The Gen 3 arms ask src/Gen3.lua for every engine detail.  That file is the
-- only one that requires src.core.game3.* / src.ui.game3.*, lazily and only on
-- a Gen 3 boot -- the loader *throws* on a cross-generation require, so a
-- Gen 3 answer computed here must never be reached on Red or Gold, and a
-- Gen 1 or Gen 2 module (src.battle.BattleState, src.core.gen2.*, ...) must
-- never be required on FireRed or Emerald.  Every arm below is ordered so the
-- Gen 3 branch returns before the Gen 1 / Gen 2 code it sits above runs.

local need, mod = ...
local Config = need("Config")
local Gen3 = need("Gen3")

local M = {}

local RANGE_OF = {
  up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT",
}

-- Gen 2 SPRITEMOVEDATA: STANDING_DOWN/UP/LEFT/RIGHT (NPC.MOVE in gen2/NPC.lua).
-- Numeric values are required: World:pooledNpc calls NPC.new(mapId, obj)
-- directly, so a Gen 1 string like "STAY" never reaches fromGen1.
local STANDING = {
  down = 6, up = 7, left = 8, right = 9,
}

local function gameOf(game)
  if type(game) == "table" then return game end
  -- Prefer the loader facade: under Gold, mod.game is the Game2 instance
  -- while _G.Game (when present) is still the Gen 1 singleton and would
  -- make Handshake/Fingerprint answer generation 1 on a live Gold boot.
  local ok, live = pcall(function() return mod.game end)
  if ok and type(live) == "table" then return live end
  local g = rawget(_G, "Game")
  if type(g) == "table" then return g end
  return nil
end

-- The loader's own generation when it is 3, for a game that carries no word
-- of its own.
--
-- Handshake answers 1 both for a real Gen 1 game and for "nothing to go on"
-- (no game, a game with no `generation` and no data), so on its own it cannot
-- tell a headless Gen 3 load -- where mod.game is nil until a test injects
-- one -- from Red.  The loader can: its generation is fixed at construction
-- and a Gen 3 loader never runs a Gen 1 or Gen 2 game (the generation gate
-- skipped every mod that could not follow it there).  So when the game
-- does not *say* it is Gen 1, a Gen 3 loader's word wins.
--
-- Only 3.  A Gen 2 loader with no game has always read as 1 here and the Gold
-- suites are written against that; the Gen 3 port does not move it.
--
-- rawget: the facade answers `generation` as a plain field (no __index), and
-- this runs on per-frame paths where a pcall'd closure is what Battlefield
-- and CoopBattle already count against Gen.generation.
local function loaderSaysGen3(game)
  if type(mod) ~= "table" or tonumber(rawget(mod, "generation")) ~= 3 then
    return false
  end
  if type(game) == "table" then
    if tonumber(game.generation) == 1 then return false end
    local data = game.data
    if type(data) == "table" and tonumber(data.generation) == 1 then return false end
  end
  return true
end

-- 1, 2 or 3. Handshake.generation when present, else Fingerprint.generationOf
-- on the merged dataset, else a Gen 3 loader (above); anything else reads as
-- Gen 1.  Game3 carries generation = 3 on the instance and on its data, so a
-- live FireRed / LeafGreen / Emerald boot answers 3 from the first source.
function M.generation(game)
  game = gameOf(game)
  local gen, got = 1, false
  local ok = pcall(function()
    local Handshake = require("src.link.Handshake")
    if type(Handshake.generation) == "function" then
      gen = tonumber(Handshake.generation(game)) or 1
      got = true
    end
  end)
  if ok and got and (gen == 2 or gen == 3) then return gen end
  if ok and got and gen == 1 then
    if loaderSaysGen3(game) then return 3 end
    return 1
  end
  ok = pcall(function()
    local Fingerprint = require("src.link.Fingerprint")
    gen = tonumber(Fingerprint.generationOf(game and game.data)) or 1
  end)
  if ok and (gen == 2 or gen == 3) then return gen end
  if loaderSaysGen3(game) then return 3 end
  return 1
end

function M.isGen3(game)
  return M.generation(game) == 3
end

-- The cheap half of isGen3 for per-frame paths (freeRoam runs every draw):
-- a game that says 3, or a Gen 3 boot.  No pcall, no require.
local function onGen3(game)
  if type(game) == "table" and tonumber(game.generation) == 3 then return true end
  return Gen3.active()
end

local function gameVersionModule()
  local ok, GV = pcall(require, "src.core.GameVersion")
  if ok and type(GV) == "table" then return GV end
  return nil
end

-- The first cart of a generation in the launcher's own column order
-- (GameVersion.ORDER): Red, Gold, FireRed -- the carts each port was written
-- against.  Read from GameVersion rather than spelled here, so no version
-- string is allow-listed in this file (modkit MK409) and a reordered
-- launcher is followed rather than contradicted.
local function referenceVersion(GV, gen)
  if not (GV and type(GV.ORDER) == "table" and type(GV.VERSIONS) == "table") then
    return nil
  end
  for _, id in ipairs(GV.ORDER) do
    local row = GV.VERSIONS[id]
    if type(row) == "table" and (tonumber(row.generation) or 1) == gen then return id end
  end
  return nil
end

-- The cart: one of GameVersion.ORDER (red ... emerald).  GameVersion's
-- current pick when it is this generation's (the launcher sets it before any
-- mod loads); on Gen 3 the session's own stamp first (Gen3.version), since a
-- CONTINUE carries it; and the generation's reference cart when nothing says.
function M.version(game)
  local gen = M.generation(game)
  local GV = gameVersionModule()
  if gen == 3 then
    local live = gameOf(game)
    local sessionVersion = type(live) == "table" and type(live.session) == "table"
      and live.session.version or nil
    local row = GV and type(GV.VERSIONS) == "table" and GV.VERSIONS[sessionVersion] or nil
    if type(row) == "table" and tonumber(row.generation) == 3 then return sessionVersion end
    return Gen3.version() or referenceVersion(GV, 3)
  end
  local current = GV and type(GV.get) == "function" and GV.get() or nil
  local row = GV and type(GV.VERSIONS) == "table" and GV.VERSIONS[current] or nil
  if type(row) == "table" and (tonumber(row.generation) or 1) == gen then return current end
  return referenceVersion(GV, gen)
end

-- The lineage within a generation: "gen1" (Red / Blue / Yellow), "gs" (Gold /
-- Silver), "crystal", "frlg" (FireRed / LeafGreen), "rse" (Emerald).  Gen 1
-- and Gen 2 are GameVersion.engine of the running cart; Gen 3 is its layout,
-- because every Gen 3 cart shares the one "game3" engine and the layout is
-- what actually differs (maps, bag, start menu, battle profile).  A headless
-- Gen 3 load with no version reads as "frlg", the family it is folded
-- against.
local GEN2_LINEAGES = { gs = true, crystal = true }

function M.family(game)
  local gen = M.generation(game)
  local version = M.version(game)
  local GV = gameVersionModule()
  if gen == 3 then
    local layout = GV and type(GV.layout) == "function" and GV.layout(version) or nil
    if layout == "frlg" or layout == "rse" then return layout end
    return "frlg"
  end
  if gen == 2 then
    local ok, engine = pcall(function() return GV.engine(version) end)
    if ok and GEN2_LINEAGES[engine] then return engine end
    return "gs"
  end
  return "gen1"
end

-- A Gen 3 save or session: both carry engine = "game3" and generation = 3
-- (Schema.newGame / Schema.toSaveTable).
local function gen3Save(save)
  return type(save) == "table"
    and (save.engine == "game3" or tonumber(save.generation) == 3)
end

-- Gen 2 always writes player.money (even at 0); Gen 1 keeps save.money.
-- `create` is only true from money.set — get must never allocate save.player.
--
-- Gen 3 keeps it on the session, and `game.save` there is a *snapshot*
-- (Schema.toSaveTable, rebuilt at save time): money written into it is gone
-- at the next save, which is how a co-op prize would vanish.  So a Gen 3 save
-- resolves to the live session whenever there is one, and to itself only when
-- there is not (a headless test handing in a bare table).
local function moneyHost(save, create)
  if type(save) ~= "table" then return nil end
  if gen3Save(save) then
    return Gen3.session() or save
  end
  if save.generation == 2 then
    if type(save.player) == "table" then return save.player end
    if create then
      save.player = {}
      return save.player
    end
    return nil
  end
  local player = save.player
  if type(player) == "table" and player.money ~= nil then return player end
  return save
end

M.money = {}

function M.money.get(save)
  local host = moneyHost(save, false)
  if not host then return 0 end
  return math.floor(tonumber(host.money) or 0)
end

-- The cart's MAX_MONEY on Gen 3 (AddMoney caps there); Gen 1 and Gen 2 have
-- always been left to their callers, which cap at the same 999999.
local GEN3_MAX_MONEY = 999999

function M.money.set(save, n)
  local host = moneyHost(save, true)
  if not host then return end
  if gen3Save(save) then
    local v = math.floor(tonumber(n) or 0)
    if v < 0 then v = 0 end
    if v > GEN3_MAX_MONEY then v = GEN3_MAX_MONEY end
    host.money = v
    -- Keep the snapshot a caller handed in agreeing with the session, so a
    -- read of the same table later in this frame sees the new amount.
    if host ~= save then save.money = v end
    return
  end
  host.money = math.floor(tonumber(n) or 0)
end

-- seen, owned/caught. Profile wire still names the second field `owned`.
--
-- Gen 3: session.dex (the snapshot shares the same table), counted in
-- national mode by the engine's own dex module -- every species this save has
-- met, Hoenn ones a trade brought in included (see Gen3.dexCounts).
function M.dexCounts(save)
  if gen3Save(save) then
    if Gen3.session() then return Gen3.dexCounts() end
    local dex = type(save.dex) == "table" and save.dex or {}
    local seen, caught = 0, 0
    for _, on in pairs(dex.seen or {}) do
      if on and on ~= 0 then seen = seen + 1 end
    end
    for _, on in pairs(dex.caught or dex.owned or {}) do
      if on and on ~= 0 then caught = caught + 1 end
    end
    return seen, caught
  end
  local dex = save and save.pokedex or {}
  local seen, owned = 0, 0
  for _ in pairs(dex.seen or {}) do seen = seen + 1 end
  local bag = dex.caught or dex.owned or {}
  for _ in pairs(bag) do owned = owned + 1 end
  return seen, owned
end

-- Gen 2: count save.player.badges when that table exists. Otherwise the
-- engine's Badges.count (Gen 1 inventory keys), soft-failed.
--
-- Gen 3 badges are event flags, not a table, and the Gen 1 Badges module would
-- read FireRed's save as a Red inventory and answer 0; Gen3.badgeCount asks
-- the engine's flag module, per the running cart's own badge list.  Checked
-- first so src.inventory.Badges is never required on a Gen 3 boot.
function M.badgeCount(game, save)
  if gen3Save(save) or onGen3(game) then
    return Gen3.badgeCount()
  end
  local badges = save and save.player and save.player.badges
  if type(badges) == "table" then
    local n = 0
    for _, has in pairs(badges) do
      if has then n = n + 1 end
    end
    return n
  end
  local count = 0
  local ok = pcall(function()
    local Badges = require("src.inventory.Badges")
    count = Badges.count(game and game.data, save) or 0
  end)
  if not ok then return 0 end
  return count
end

-- Gen 2 World exposes acceptsMenuInput; Gen 1 OverworldState does not.
-- Used when Handshake has no game yet but an overworld is already up.
--
-- Never true on Gen 3: Game3 rides Game2's start-menu path (runtime.lua), so
-- a capability sniff is exactly the test that could read FireRed as Gold, and
-- mod.world:overworld() there is a Gen3Compat facade, not a world to sniff.
local function bootIsGen2(game)
  local gen = M.generation(game)
  if gen == 2 then return true end
  if gen == 3 then return false end
  local world = mod.world
  -- Guard: headless stubs often set mod.world to a fake without :overworld.
  local ow = world and type(world.overworld) == "function" and world:overworld() or nil
  return ow ~= nil and type(ow.acceptsMenuInput) == "function"
end

-- True when the player is looking at the world: Gen 1's overworld-on-top,
-- or Gen 2's empty stack with a live map (pipelineGate's free-roam case).
-- Empty-stack free-roam is Gen 2 only — Gen 1 still requires top == overworld.
--
-- Gen 3 has no game.stack for `top` to come from: the field phase with
-- nothing in front of it -- no game3 stack layer, no legacy module menu, no
-- message, fade or battle (Gen3.freeRoam, i.e. the engine's own Hud.busy).
-- `top` is ignored there.  onGen3 rather than Gen.generation because this
-- runs every draw.
function M.freeRoam(game, top)
  if onGen3(game) then return Gen3.freeRoam() end
  local world = mod.world
  local overworld = world and type(world.overworld) == "function" and world:overworld() or nil
  if top and overworld and top == overworld then return true end
  if not top and overworld and overworld.map
      and (M.generation(game) == 2 or bootIsGen2(game)) then
    return true
  end
  return false
end

-- The boot's START menu.  On Gen 1 / Gen 2 a screen id for mod.ui.push; on
-- Gen 3 the game3 stack layer id StartMenu.show pushes ("start",
-- src/ui/game3/start_menu.lua), which is what a caller tests Stack.has /
-- Stack.top against.  Re-opening it on Gen 3 is not a push at all -- it is
-- M.reopenStartMenu below.
function M.startMenuId(game)
  local gen = M.generation(game)
  if gen == 2 then return "Gen2StartMenu" end
  if gen == 3 then return "start" end
  -- Split so gen2check MK409 does not flag a bare Gen1 screen id literal
  -- in a helper that also returns Gen2StartMenu on Gold.
  return "Start" .. "Menu"
end

-- Gen 3 only: put START back up after leaving an MMO screen, the way the
-- START button does (Hud.openStartMenu, via Gen3.openStartMenu -- which
-- leaves an already-open menu alone, since the engine's opener toggles).  The
-- ui.start_menu.items hook runs on every open, so the MMO row comes back with
-- it.  False off Gen 3 and when the menu could not be opened; Gen 1 and Gen 2
-- keep their mod.ui.push paths in src/Ui.lua (reopenStartMenu).
function M.reopenStartMenu(game)
  if M.generation(game) ~= 3 then return false end
  return Gen3.openStartMenu(gameOf(game))
end

-- ------- the nickname a catch earns
--
-- A wild caught on the engine's own path is named through
-- BattleState:askNicknameUI: the caught text, then "Do you want to give a
-- nickname to X?", then the letter grid.  A wild caught in an MMO fight is
-- granted by this mod instead (MediatedBattle / CoopBattle `grantCatch`), and
-- until this existed the grant went straight into the party -- the catcher
-- never got the prompt every other catch in the game gives them.
--
-- The two generations differ in three ways that a single call site would
-- otherwise have to know: the screen id, the opts shape, and -- the one that
-- actually bites -- who pops the screen.  Gen 1's NamingScreen pops *itself*
-- before calling onDone (src/ui/NamingScreen.lua); Gold's does not, and its
-- callers pop for it (src/ui/gen2/BattleState.lua:answerNickname).  So this
-- pops on Gold and leaves Gen 1 alone: doing either on both generations
-- either strands the grid on the stack forever or takes the screen underneath
-- it down with the answer.
--
-- Gen 3 is Gen 1's shape on the third point: src/ui/game3/naming.lua's
-- Naming.close pops the "naming" layer *before* it calls onDone.  It differs
-- on the first two -- the grid is not a pushed screen but Naming.open, and it
-- is the cart's CAUGHT_MON template (the mon's icon, "<SPECIES>'s nickname?")
-- -- so askNickname opens it the way battle/init.lua's own catch flow does.

function M.nicknameScreenId(game)
  local gen = M.generation(game)
  if gen == 2 then return "Gen2NamingScreen" end
  -- The game3 stack layer Naming.open pushes, for a caller watching the stack.
  if gen == 3 then return "naming" end
  -- Split for the reason startMenuId's is: gen2check MK409 flags a bare Gen 1
  -- screen id literal in a helper that also answers with a Gen 2 one.
  return "Naming" .. "Screen"
end

-- The sentence the prompt asks, in the player's own copy's words where the
-- dataset carries them.
--
-- Gen 1 has the ROM string (_DoYouWantToNicknameText, whose CONT is a tab and
-- whose {RAM} token is the species); Gold's engine prints a plain sentence of
-- its own (Gen2 BattleState:askNickname), so there is nothing to look up and
-- the fallback *is* the line.  `displayName` is substituted through a function
-- so a name carrying `%` cannot blow up gsub's replacement parser.
--
-- Gen 3 asks STRINGID_GIVENICKNAMECAPTURED, the line battle/init.lua's
-- prompt_nickname prints, through the engine's own battle-text expansion; the
-- sentence below is only for a build whose text pack is not there.
function M.nicknamePromptText(game, displayName)
  local name = tostring(displayName or "")
  if name == "" then name = "POKeMON" end
  local gen = M.generation(game)
  if gen == 3 then
    return Gen3.battleText("STRINGID_GIVENICKNAMECAPTURED", { opponentMon1 = name })
      or ("Give a nickname to the\ncaptured " .. name .. "?")
  end
  if gen == 2 then
    return "Give a nickname to\n" .. name .. "?"
  end
  local text = game and game.data and game.data.text
    and game.data.text._DoYouWantToNicknameText
  if type(text) == "string" and text ~= "" then
    local out = text:gsub("\t", "\n"):gsub("{RAM:?[%w_]*}", function()
      return name
    end)
    return out
  end
  return "Do you want to\ngive a nickname\nto " .. name .. "?"
end

-- ------- catch pages on the battlefield
--
-- NamingScreen, SummaryMenu and the nickname confirm are 160×144 pages.
-- Game.lua keeps a wide battle's surface (640×360 here) and only X-centres
-- those pages (`classicOffset`), so after a catch they land as a postage
-- stamp in the middle of the arena. Claiming the wide-battle slot at GB
-- size with fill-scale makes the page fill the window the way every other
-- naming / status screen in this game does.
--
-- Only Gen 1, and only while a battlefield fight is actually on the stack:
-- Gold paints window-space via `drawsWidescreen`, and Oak / the NAME RATER
-- must keep the ordinary letterbox.
--
-- Gen 3 never needs the fit: its naming grid is a fullscreen game3 stack layer
-- drawn at the GBA's own 240x160 whatever is under it, so there is no postage
-- stamp to enlarge -- and there is no game.stack of states to find a
-- battlefield in.  catchPageOverBattlefield answers false there (the `~= 1`
-- below), fitCatchPage is a no-op, and showCaughtStatus puts no page up: the
-- cart's own catch flow shows no status screen, only the dex registration
-- page for a first catch (FireRed Pokedex.showRegistration, Emerald
-- rse/pokedex showCaughtMon), which belongs to the caller that knows the
-- catch was new.

M.CATCH_PAGE_W = 160
M.CATCH_PAGE_H = 144

function M.catchPageOverBattlefield(game)
  if M.generation(game) ~= 1 then return false end
  local states = game and game.stack and game.stack.states
  if type(states) ~= "table" then return false end
  for i = 1, #states do
    local state = states[i]
    if state and type(state.usesBattlefield) == "function" then
      local ok, yes = pcall(state.usesBattlefield, state)
      if ok and yes then return true end
    end
  end
  return false
end

function M.fitCatchPage(screen, game)
  if type(screen) ~= "table" then return screen end
  if not M.catchPageOverBattlefield(game) then return screen end
  screen.isWideBattleLayout = function() return true end
  screen.uiSize = function()
    return M.CATCH_PAGE_W, M.CATCH_PAGE_H
  end
  screen.wantsFillScale = function() return true end
  -- A TextBox only paints the bottom strip. The take-over canvas is
  -- 160×144; without paper the clipped 640×360 arena would show through
  -- the top 96px. Opaque pages already fill themselves.
  if not screen.isOpaque then
    local baseDraw = screen.draw
    if type(baseDraw) == "function" then
      screen.draw = function(self, ...)
        local love = rawget(_G, "love")
        local g = love and love.graphics
        if g and g.setColor and g.rectangle then
          g.setColor(1, 1, 1, 1)
          g.rectangle("fill", 0, 0, M.CATCH_PAGE_W, M.CATCH_PAGE_H)
        end
        return baseDraw(self, ...)
      end
    end
  end
  return screen
end

-- The status screen (HP, STATUS, ATTACK / DEFENSE / SPEED / SPECIAL) for
-- the monster just caught, sized the same way as the naming grid. `onDone`
-- runs after the player closes page 2. Returns false when no page went up
-- so the caller can go straight to the nickname prompt.
function M.showCaughtStatus(game, mon, onDone)
  if not (type(game) == "table" and type(mon) == "table") then return false end
  if not M.catchPageOverBattlefield(game) then return false end
  local pushed
  local ok = pcall(function()
    pushed = mod.ui.push(game, "SummaryMenu", mon)
  end)
  if not (ok and type(pushed) == "table") then return false end
  M.fitCatchPage(pushed, game)
  local baseUpdate = pushed.update
  if type(onDone) == "function" and type(baseUpdate) == "function" then
    local closed = false
    pushed.update = function(self, dt)
      local page = self.page
      local out = baseUpdate(self, dt)
      -- StatusScreen: A/B on page 2 pops. After that call the page is still
      -- 2 but the screen is gone; membership is the honest closed test.
      if not closed and page == 2 then
        local stack = self.game and self.game.stack and self.game.stack.states
        local still = false
        if type(stack) == "table" then
          for i = 1, #stack do
            if stack[i] == self then
              still = true
              break
            end
          end
        end
        if not still then
          closed = true
          onDone()
        end
      end
      return out
    end
  end
  return true
end

-- Put the letter grid up for `mon`, and write what was typed onto it.
--
-- `onDone` is called with the typed name (or nil) *after* the grid has left
-- the stack, so a caller can carry on sequencing from it.  Returns false when
-- no screen went up -- a build with no naming screen registered, or a push
-- that threw -- which is the caller's cue to say so rather than wait for an
-- answer that is never coming.
function M.askNickname(game, mon, displayName, onDone)
  if not (type(game) == "table" and type(mon) == "table") then return false end
  local gen = M.generation(game)
  if gen == 3 then return M.askNickname3(mon, displayName, onDone) end
  local gen2 = gen == 2
  local name = tostring(displayName or mon.species or "")

  -- Guarded because the two screens reach it differently (Gold's onCancel and
  -- onDone are both endings) and a nickname must not be written twice.
  local answered = false
  local function done(typed)
    if answered then return end
    answered = true
    if gen2 then
      pcall(function() game.stack:pop() end)
    end
    if type(typed) == "string" and typed ~= "" then mon.nickname = typed end
    if onDone then onDone(typed) end
  end

  local opts
  if gen2 then
    local data = game.data or {}
    local icons = data.gen2Icons
    local iconId = icons and icons.species and icons.species[mon.species]
    local entry = iconId and icons.icons and icons.icons[iconId]
    opts = {
      type = "nickname",
      monName = name,
      iconPath = entry and entry.image or nil,
      menuGfx = data.gen2MenuGfx,
      onDone = done,
      onCancel = function() done(nil) end,
    }
  else
    opts = {
      title = "NICKNAME?",
      maxLen = Config.NICKNAME_MAX,
      onDone = done,
    }
  end

  local pushed
  local ok = pcall(function()
    pushed = mod.ui.push(game, M.nicknameScreenId(game), opts)
  end)
  -- A pcall that succeeds but hands back nothing table-shaped is as
  -- screen-less as a throw (an unregistered id resolves to nil), and both
  -- leave the catcher waiting on a grid that never came up.
  if not (ok and type(pushed) == "table") then
    mod.log:warn("could not open the naming screen for the POKeMON you just "
      .. "caught; it keeps its species name and can be renamed at the NAME "
      .. "RATER")
    return false
  end
  M.fitCatchPage(pushed, game)
  return true
end

-- The Gen 3 grid, opened the way battle/init.lua's prompt_nickname opens it:
-- CAUGHT_MON template, the cart's ten-character POKeMON name, the species'
-- icon (species / gender / personality) and "<SPECIES>'s nickname?" in the
-- cart's words.  Naming pops itself before onDone, so nothing is popped here.
--
-- One Gen 3 rule the other two do not have: typing the species' own name is
-- not a nickname.  A Gen 3 mon keeps nickname = "" for "none" (the engine
-- shows the species name for it, and an evolution renames only those), so
-- the engine's catch flow writes the answer only when it differs from the
-- name it offered, and so does this.
function M.askNickname3(mon, displayName, onDone)
  if type(mon) ~= "table" then return false end
  local species = tonumber(mon.species or mon.speciesId)
  local speciesName = Gen3.speciesName(species)
  local name = tostring(displayName or speciesName or "")

  local answered = false
  local function done(typed)
    if answered then return end
    answered = true
    if type(typed) == "string" and typed ~= "" and typed ~= name then
      mon.nickname = typed
    end
    if onDone then onDone(typed) end
  end

  local opened = Gen3.openNaming({
    template = "CAUGHT_MON",
    maxLen = Config.NICKNAME_MAX,
    species = species,
    gender = mon.gender,
    personality = mon.personality,
    seed = name,
    title = Gen3.nicknameTitle(speciesName or name),
    onDone = done,
  })
  if not opened then
    mod.log:warn("could not open the naming screen for the POKeMON you just "
      .. "caught; it keeps its species name and can be renamed at the NAME "
      .. "RATER")
    return false
  end
  return true
end

-- ------- the rest of what a capture writes into the save
--
-- Adding the monster to the party is only the visible half of a catch. The
-- engine's own capture (`BattleState:storeCaughtMon` on Red,
-- `Gen2 BattleState:pushCaught` on Gold) also marks the #DEX, stamps the
-- catcher onto the mon as its original trainer, and -- on Gold -- registers
-- an UNOWN's form.  An MMO catch is granted by this mod, so none of it
-- happened: the caught monster was owned by nobody, the dex never moved, and
-- an UNOWN caught in a co-op fight never unlocked its letter.
--
-- All three are the same shape of question -- "which field does this
-- generation keep it in" -- so they live here together, and the engine's own
-- helpers do the writing wherever it exports one (`BattleState.stampOT`,
-- `Mon.stampOT`, `Unown.registerCatch`). The dex is written directly because
-- neither generation exports a marker: Gen 1's `markOwned` is a `BattleState`
-- static that reads `game.save.pokedex.owned`, Gold stamps
-- `pokedex.caught` inline, and the rule for which of the two a save carries
-- is already stated once in this file (see `dexCounts`).

-- The catcher's name and id on the monster they caught. `mon.traded` is
-- respected by both engine stamps: a traded mon keeps the id it arrived with.
local function stampOT(game, save, mon)
  if type(save.player) ~= "table" then return false end
  local path = (M.generation(game) == 2)
    and "src.battle.gen2.Mon" or "src.battle.BattleState"
  local stamped = false
  pcall(function()
    local engine = require(path)
    if type(engine.stampOT) == "function" then
      engine.stampOT(save, mon)
      stamped = true
    end
  end)
  if stamped then return true end
  -- No engine module to ask (a headless load, a build without it): the OT
  -- name is the half a player sees on the status screen, so it is written
  -- rather than dropped. The id is left alone -- inventing one here would be
  -- inventing the number the traded check turns on.
  mon.ot = mon.ot or save.player.name
  return mon.ot ~= nil
end

-- Seen + owned/caught, and whether this species was new.
--
-- `caught` when the save carries it or declares generation 2, `owned`
-- otherwise -- the same rule src/Trade2.lua marks a received trade under, and
-- the same pair `dexCounts` reads back out.
local function markDex(save, species)
  local dex = save.pokedex
  if not (type(dex) == "table" and type(species) == "string") then return nil end
  dex.seen = dex.seen or {}
  dex.seen[species] = true
  if dex.caught ~= nil or save.generation == 2 then
    dex.caught = dex.caught or {}
    local knew = dex.caught[species] and true or false
    dex.caught[species] = true
    return not knew
  end
  dex.owned = dex.owned or {}
  local knew = dex.owned[species] and true or false
  dex.owned[species] = true
  return not knew
end

-- Everything the engine's own capture does to the save except choosing the
-- monster's home, which is the caller's (party, then a box).
--
-- Returns whether the species was **new** to the dex, which is the answer the
-- "new #DEX data" line is asked for -- and nil when this save has no dex at
-- all, which is not the same as "already known".
--
-- Ordered the way the engine orders it: the dex and the OT are written before
-- the monster is put anywhere, so a catch that ends up with nowhere to go
-- still counted as seen (`storeCaughtMon` marks owned before `Party.add`).
--
-- Gen 3 writes into the live session, never game.save (a snapshot there), and
-- does it the way Catching.storeCaught does: OT name / id / secret id from the
-- session, met location and level, and Dex.registerCapture -- see
-- Gen3.recordCatch.  Its species is a number, which is why markDex (string
-- species only) is not the Gen 3 path.
function M.recordCatch(game, mon)
  if not (type(game) == "table" and type(mon) == "table") then return nil end
  if M.generation(game) == 3 then return Gen3.recordCatch(mon) end
  local save = game.save
  if type(save) ~= "table" then return nil end
  stampOT(game, save, mon)
  local isNew = markDex(save, mon.species)
  if M.generation(game) == 2 then
    -- AddPartyMon's `.registerunowndex`: the form list UNOWN MODE and
    -- VAR_UNOWNCOUNT read. A no-op for every species but UNOWN.
    pcall(function()
      local Unown = require("src.core.gen2.Unown")
      if type(Unown.registerCatch) == "function" then
        Unown.registerCatch(save, mon)
      end
    end)
  end
  return isNew
end

-- "This one is new", in each game's own words (_ItemUseBallText06 on Red,
-- NewDexDataText on Gold, STRINGID_PKMNDATAADDEDTODEX on FireRed / Emerald --
-- the line catch_seq.lua prints after a first catch, through the engine's own
-- battle-text expansion when its text pack is there).  The breaks are the
-- carts' `line` / `cont`: pokered data/text/text_6.asm _ItemUseBallText06
-- ("New #DEX data" / line "will be added for" / cont "<MON>!", `#` the cart's
-- POKé), pokecrystal and pokegold data/text/common_3.asm _NewDexDataText
-- (text_ram wEnemyMonNickname, "'s data" / line "was newly added to" / cont
-- "the #DEX.").
function M.dexAddedText(game, displayName)
  local name = tostring(displayName or "")
  if name == "" then name = "It" end
  local gen = M.generation(game)
  if gen == 3 then
    return Gen3.battleText("STRINGID_PKMNDATAADDEDTODEX", { opponentMon1 = name })
      or (name .. "'s data was\nadded to the POKéDEX.")
  end
  if gen == 2 then
    return name .. "'s data\nwas newly added to\nthe #DEX."
  end
  return "New POKéDEX data\nwill be added for\n" .. name .. "!"
end

-- The avatar's object name.  Generation-neutral: on Gen 3 it names the
-- injected event object's def, the way it names the runtime NPC on Red/Gold.
function M.avatarName(playerId)
  return "mmo_" .. tostring(playerId)
end

-- The object an avatar is spawned from.
--
-- Gen 1: mod.world:spawnNpc's STAY + range.  Gen 2: numeric STANDING_*.
-- Gen 3 has no spawnNpc (src/world/game3/WorldAPI.lua answers "not supported
-- on FireRed yet"): an avatar is an event object built by
-- Objects.spawnFromDefs and injected into the map's object list, so this
-- returns that builder's template -- cell, facing, the numeric
-- OBJ_EVENT_GFX_* id `sprite` names on this cart (Gen3.viewerGfxFor has
-- already mapped another version's name; a name this cart lacks falls to the
-- player's own look), movementType 0 (MOVEMENT_TYPE_NONE: stands where it is
-- put and turns only when driven).  The localId is the injector's to assign
-- (Config.GEN3_AVATAR_LOCAL_ID_BASE + n) and is left off.
function M.spawnObjDef(player, sprite, game)
  local facing = (player and player.facing) or "down"
  if M.generation(game or mod.game or gameOf(nil)) == 3 then
    if facing ~= "up" and facing ~= "left" and facing ~= "right" then facing = "down" end
    local graphicsId = Gen3.gfxId(sprite)
    local gfxName = graphicsId and (type(sprite) == "string" and sprite or Gen3.gfxName(graphicsId))
    if not graphicsId then
      local s = Gen3.session()
      gfxName = Gen3.playerGfxName(s and s.gender)
      graphicsId = Gen3.gfxId(gfxName)
    end
    return {
      x = player and player.x,
      y = player and player.y,
      facing = facing,
      graphicsId = graphicsId,
      gfxName = gfxName,
      movementType = 0,
      name = M.avatarName(player and player.id),
    }
  end
  local def = {
    sprite = sprite,
    x = player.x,
    y = player.y,
    name = M.avatarName(player and player.id),
  }
  -- Prefer an explicit game, then the live mod.game facade, then the
  -- overworld capability sniff (acceptsMenuInput is Gen 2-only).
  if bootIsGen2(game or mod.game or gameOf(nil)) then
    def.movement = STANDING[facing] or STANDING.down
  else
    def.movement = "STAY"
    def.range = RANGE_OF[facing] or "DOWN"
  end
  return def
end

local function spritePresent(spritesRegistry, id)
  if not (spritesRegistry and type(id) == "string") then return false end
  local ok, record = pcall(function() return spritesRegistry:get(id) end)
  return ok and record ~= nil
end

-- First Config.SPRITES id the catalog carries, then Chris / Red.
-- OWN_CHARS (NIRE, …) are never a boot default — on Gen 2 they are not
-- wearable yet, and even on Gen 1 the fallback should be an engine sprite.
--
-- Gen 3 has no SPRITE_* catalog (the sprites registry is gated there, and the
-- overworld draws OBJ_EVENT_GFX_* graphics by number), so the default is the
-- player's own look on this cart -- RED / GREEN on FireRed and LeafGreen,
-- BRENDAN / MAY on Emerald, by the save's gender -- which is also what this
-- client should say it looks like on the wire (contract C3).  The hub's
-- sprite-less token (Config.DEFAULT_SPRITE_GEN3) is only the last resort.
function M.defaultSprite(game, spritesRegistry)
  local gen = M.generation(game)
  if gen == 3 then
    local s = Gen3.session()
    return Gen3.playerGfxName(s and s.gender) or Config.defaultSpriteFor(3)
  end
  spritesRegistry = spritesRegistry or (mod.content and mod.content.sprites)
  for _, row in ipairs(Config.SPRITES or {}) do
    local id = row[2]
    local own = Config.ownCharId(id)
    if own and not Config.ownCharAllowed(own, gen) then
      -- gen-gated cast member
    elseif own then
      -- opt-in character, never the anonymous default
    elseif spritePresent(spritesRegistry, id) then
      return id
    end
  end
  if spritePresent(spritesRegistry, "SPRITE_CHRIS") then return "SPRITE_CHRIS" end
  if spritePresent(spritesRegistry, "SPRITE_RED") then return "SPRITE_RED" end
  return Config.defaultSpriteFor(gen)
end

-- Gen 3: a look (Gen3.lookAllowed: a row of the curated wardrobe, or a
-- player-trainer graphic) this cart has a graphic for is kept (a FireRed name
-- on Emerald is not -- Gen3.viewerGfxFor is the cross-version mapping, and it
-- is the viewer's to apply with the sender's version in hand); anything else
-- is the default look -- the Gen 1 SPRITE_* ids and the mod's own characters,
-- and every graphic of the cart's that is not a person to be (a Cut tree, a
-- boulder, a boat), because `requested` may have come off the wire.
function M.resolveSprite(game, requested, spritesRegistry)
  if M.generation(game) == 3 then
    if type(requested) == "string" and Gen3.lookAllowed(requested)
        and Gen3.gfxId(requested) then
      return requested
    end
    return M.defaultSprite(game, spritesRegistry)
  end
  spritesRegistry = spritesRegistry or (mod.content and mod.content.sprites)
  local own = Config.ownCharId(requested)
  if own and not Config.ownCharAllowed(own, M.generation(game)) then
    return M.defaultSprite(game, spritesRegistry)
  end
  if spritePresent(spritesRegistry, requested) then return requested end
  return M.defaultSprite(game, spritesRegistry)
end

-- Gen 1 clip labels → Gold/Silver/Crystal names (rom_manifest_gold.json).
-- Unmapped names stay as-is and soft-fail through Sound.play when absent.
local GEN2_SFX = {
  Super_Effective = "Sfx_SuperEffective",
  Not_Very_Effective = "Sfx_NotVeryEffective",
  Damage = "Sfx_Damage",
  Tink = "Sfx_BallWobble",
  Ball_Poof = "Sfx_BallPoof",
}

-- Gen 1 clip labels -> the game3 SE_* names the battle itself plays
-- (battle/anim_seq.lua: SUPER_EFFECTIVE / NOT_EFFECTIVE / EFFECTIVE for a
-- hit; battle/catch_seq.lua: SE_BALL for each wobble, SE_BALL_OPEN for the
-- break-out).  Played through Gen3.audio.playSe, which resolves the name
-- against the running cart's own SE table -- the numbers differ on Emerald.
local GEN3_SFX = {
  Super_Effective = "SE_SUPER_EFFECTIVE",
  Not_Very_Effective = "SE_NOT_EFFECTIVE",
  Damage = "SE_EFFECTIVE",
  Tink = "SE_BALL",
  Ball_Poof = "SE_BALL_OPEN",
}

-- Battle / catch SFX id for the live generation. Gen 1 keeps the RBY label.
-- Gen 3 answers an SE_* name; an unmapped label passes through and
-- soft-fails in Audio.playSe exactly as an unmapped Gold one does in
-- Sound.play.
function M.sfx(game, name)
  if type(name) ~= "string" then return name end
  local gen = M.generation(game)
  if gen == 3 then return GEN3_SFX[name] or name end
  if gen ~= 2 then return name end
  return GEN2_SFX[name] or name
end

-- Gen 2 trainer class id for BattleMusic (FALKNER), stripping Gen 1 OPP_.
local function gen2TrainerClass(opts)
  opts = opts or {}
  local t = opts.trainer
  local class = opts.class
    or opts.oppClass
    or (t and (t.classId or t.class or t.id))
  if type(class) ~= "string" then return nil end
  if class:sub(1, 4) == "OPP_" then class = class:sub(5) end
  return class
end

local function gen2MusicEnv(game)
  local landmark, daytime, members
  local ow = game and (game.overworld or game.world)
  if type(ow) == "table" then
    landmark = ow.map and ow.map.def and ow.map.def.landmark
    daytime = ow.daytime
    members = ow.constants and ow.constants.trainerClassMembers
  end
  return landmark, daytime, members
end

local function isWildMode(opts)
  local mode, kind = opts.mode, opts.kind
  return mode == "coop_wild" or mode == "wild" or kind == "wild"
end

local function isLinkMode(opts, class)
  local mode, kind = opts.mode, opts.kind
  if mode == "coop_pvp" or kind == "link" then return true end
  -- No trainer class and not wild → party-vs-party / 1v1 link cue.
  return not isWildMode(opts) and not class
end

-- Song label Gen 2 PlayBattleMusic would pick for this fight (or nil).
function M.gen2BattleSong(game, opts)
  opts = opts or {}
  local ok, BattleMusic = pcall(require, "src.battle.gen2.BattleMusic")
  if not (ok and BattleMusic and BattleMusic.battleSong) then return nil end
  local landmark, daytime, membersTbl = gen2MusicEnv(game)
  local class = gen2TrainerClass(opts)
  if isLinkMode(opts, class) then
    -- Gen 2 has no dedicated link theme; regional trainer battle matches
    -- "two parties" better than a wild cue.
    return BattleMusic.isKanto(landmark)
      and "Music_KantoTrainerBattle" or "Music_JohtoTrainerBattle"
  end
  if isWildMode(opts) then
    return BattleMusic.battleSong({ landmark = landmark, daytime = daytime })
  end
  local member = opts.member
    or (opts.trainer and (opts.trainer.memberId or opts.trainer.member))
  local members = class and membersTbl and membersTbl[class] or nil
  return BattleMusic.battleSong({
    class = class,
    member = member,
    members = members,
    landmark = landmark,
    daytime = daytime,
  })
end

function M.gen2VictorySong(game, opts)
  opts = opts or {}
  local ok, BattleMusic = pcall(require, "src.battle.gen2.BattleMusic")
  if not (ok and BattleMusic and BattleMusic.victorySong) then return nil end
  local class = gen2TrainerClass(opts)
  if isLinkMode(opts, class) then
    return "Music_TrainerVictory"
  end
  if isWildMode(opts) then
    return BattleMusic.victorySong({
      participantsFainted = opts.participantsFainted,
    })
  end
  return BattleMusic.victorySong({ class = class })
end

-- The mod's battle opts, in the terms Gen3.audio.battleSong / victorySong
-- take: which kind of fight (the same isWildMode / isLinkMode reading Gold's
-- songs get), and the trainer as a *numeric* Gen 3 id or class -- a Gen 1
-- OPP_* string has no row in scripting/trainers.lua and is left out rather
-- than guessed at.
local function gen3MusicOpts(opts)
  local t = opts.trainer
  local trainerId = tonumber(opts.trainerId)
    or (type(t) == "table" and tonumber(t.trainerId or t.id)) or nil
  local class = tonumber(opts.trainerClass or opts.class or opts.oppClass)
    or (type(t) == "table" and tonumber(t.trainerClass or t.classId or t.class)) or nil
  local wild = isWildMode(opts)
  -- An NPC fight whose trainer this cart cannot name is still an NPC fight:
  -- it takes the ordinary trainer theme, never the Cable Club's.
  local npc = opts.mode == "coop_npc" or opts.kind == "trainer"
    or trainerId ~= nil or class ~= nil
  return {
    wild = wild,
    link = not wild and not npc and isLinkMode(opts, nil),
    trainerId = trainerId,
    trainerClass = class,
    trainerName = type(t) == "table" and t.name or nil,
    species = tonumber(opts.species),
  }
end

-- Theatre: battle theme / win jingle / map restore.
-- Pass opts.Music (engine.Music) so headless suites can stub the boundary.
-- Gen 1 uses playBattle(kind) / playVictory(kind); Gen 2 plays song labels
-- from BattleMusic (data.audio.battle[kind] does not exist on Gold).
-- Gen 3 plays the song number Gen3.audio resolves the way battle_bridge.lua
-- does (Emerald's profile music table, else FireRed's roles), through the
-- game3 m4a player; opts.Audio stubs that boundary the way opts.Music stubs
-- the GB one.  It returns the song, like Gold's arm.

function M.playBattleMusic(game, opts)
  opts = opts or {}
  if M.generation(game) == 3 then
    local song = Gen3.audio.battleSong(gen3MusicOpts(opts))
    if song then
      local Audio = opts.Audio or Gen3.audio
      pcall(Audio.playSong, song)
    end
    return song
  end
  local Music = opts.Music
  if not Music then
    local ok, m = pcall(require, "src.core.Music")
    if not ok then return end
    Music = m
  end
  local data = game and game.data
  if not data then return end
  if M.generation(game) == 2 then
    local song = M.gen2BattleSong(game, opts)
    if song and Music.play then
      pcall(Music.play, data, song, true, { reason = "battle" })
    end
    return song
  end
  local kind = opts.kind or "trainer"
  local trainerId = opts.trainerId
    or (opts.trainer and opts.trainer.id)
  if Music.playBattle then
    pcall(Music.playBattle, data, kind, trainerId)
  end
end

function M.playVictoryMusic(game, opts)
  opts = opts or {}
  if M.generation(game) == 3 then
    local song = Gen3.audio.victorySong(gen3MusicOpts(opts))
    if song then
      local Audio = opts.Audio or Gen3.audio
      pcall(Audio.playSong, song)
    end
    return song
  end
  local Music = opts.Music
  if not Music then
    local ok, m = pcall(require, "src.core.Music")
    if not ok then return end
    Music = m
  end
  local data = game and game.data
  if not data then return end
  if M.generation(game) == 2 then
    local song = M.gen2VictorySong(game, opts)
    if song and Music.play then
      pcall(Music.play, data, song, true, { reason = "victory" })
    end
    return song
  end
  local kind = opts.kind or "trainer"
  if kind == "final" then kind = "gym" end
  local trainerId = opts.trainerId
    or (opts.trainer and opts.trainer.id)
  if Music.playVictory then
    pcall(Music.playVictory, data, kind, trainerId)
  end
end

-- The overworld walk-sheet catalog, by generation.
--
-- Gold keeps its sprite records on `data.gen2Sprites`; `data.sprites` is Gen 1's
-- table and on a Gold boot is either absent or the wrong shape. The engine's own
-- resolution is `rawget(data, "gen2Sprites") or data.sprites`
-- (`src/world/gen2/NPC.lua:195`) and this is that line, in one place, because
-- three call sites in this mod were reading `data.sprites` directly -- which is
-- why the arena's trainers were invisible on Gold: the record lookup found
-- nothing, `resolveHumanSheet` returned no sheet, and the figure simply never
-- drew. `rawget` and not a plain index for the reason the engine uses it: a
-- dataset may carry a metatable that would synthesise a Gen 1 answer.
--
-- Gen 3 has none to hand out: an overworld figure there is an OBJ_EVENT_GFX_*
-- graphic the engine draws by number (OwSprites), not a SPRITE_* sheet
-- record, and Game3's data carries no `sprites` table in either shape.  nil
-- is the honest answer, and it is the one a caller already treats as "no
-- catalog" -- a Gen 3 figure is resolved through Gen3.gfxId instead.
function M.spriteCatalog(game)
  -- onGen3, not Gen.generation: the battle screens ask this while drawing.
  if onGen3(game) then return nil end
  local data = game and game.data
  if type(data) ~= "table" then return nil end
  local gen2 = rawget(data, "gen2Sprites")
  if type(gen2) == "table" then return gen2 end
  local sprites = data.sprites
  if type(sprites) == "table" then return sprites end
  return nil
end

-- ------- trainer class -> overworld walk sheet
--
-- There is no class->sprite field anywhere in engine data. A trainer record
-- (`data.trainers`) carries the battle front pic, the parties and the prize
-- money, and says nothing about the overworld; the walk sheet is chosen per
-- **map object**, where `data.maps[*].objects[*]` pairs a `sprite` with the
-- `trainerClass` that object fights as. That is still a real mapping, just an
-- indirect one -- so it is read out of the data rather than hand-written here:
-- every object naming a class votes for the sheet it is drawn with, and the
-- class takes the sheet with the most votes.
--
-- Which is what the name transform below cannot do on its own. Red has no
-- SPRITE_LASS and no SPRITE_BUG_CATCHER -- those classes walk around as
-- SPRITE_COOLTRAINER_F and SPRITE_YOUNGSTER -- so `OPP_BUG_CATCHER` resolved to
-- nothing and the foe edge of the arena was left empty.
--
-- Ties break on id order so two clients never disagree about a class, and the
-- whole walk is memoised against the maps table it was built from: one pass
-- over ~250 maps per boot, and none at all once a battle is running.
--
-- **Lives here, and not in a battle screen**, because both of them ask it --
-- `CoopBattle:battlefieldFoeHumans` for a co-op NPC fight and
-- `MediatedBattle:battlefieldCtx` for the solo one -- and MediatedBattle cannot
-- require CoopBattle without closing a cycle. It sits next to `spriteCatalog`
-- for the reason that function exists: this is a walk-sheet question, and the
-- catalog it has to be answered against is generation-shaped.
local trainerSpriteVotes = nil
local trainerSpriteVotesFrom = nil

local function trainerSpritesByClass(data)
  local maps = type(data) == "table" and data.maps or nil
  if type(maps) ~= "table" then return nil end
  if trainerSpriteVotesFrom == maps then return trainerSpriteVotes end

  local votes = {}
  local ok = pcall(function()
    for _, map in pairs(maps) do
      if type(map) == "table" and type(map.objects) == "table" then
        for _, obj in pairs(map.objects) do
          if type(obj) == "table" then
            local class, sprite = obj.trainerClass, obj.sprite
            if type(class) == "string" and class ~= ""
               and type(sprite) == "string" and sprite ~= "" then
              local bucket = votes[class]
              if not bucket then
                bucket = {}
                votes[class] = bucket
              end
              bucket[sprite] = (bucket[sprite] or 0) + 1
            end
          end
        end
      end
    end
  end)
  if not ok then return nil end

  local out = {}
  for class, bucket in pairs(votes) do
    local best, bestN = nil, -1
    for sprite, n in pairs(bucket) do
      if n > bestN or (n == bestN and (best == nil or sprite < best)) then
        best, bestN = sprite, n
      end
    end
    out[class] = best
  end
  trainerSpriteVotes = out
  trainerSpriteVotesFrom = maps
  return out
end

-- Last resort, best first: a class nobody walks around as on any map (the
-- unused ones, and anything a mod adds without an overworld object) still gets
-- a body on the field rather than an empty foe edge. Probed against the
-- catalog, so a build without one of these falls to the next.
local GENERIC_TRAINER_SPRITES = {
  "SPRITE_COOLTRAINER_M", "SPRITE_YOUNGSTER", "SPRITE_GENTLEMAN",
}

-- The same last resort on a Gen 3 cart, spelled as its graphics and probed
-- against this version's table: FireRed has all three, Emerald has no
-- COOLTRAINER_M and falls to the YOUNGSTER.
local GENERIC_TRAINER_GFX = {
  "OBJ_EVENT_GFX_COOLTRAINER_M", "OBJ_EVENT_GFX_YOUNGSTER", "OBJ_EVENT_GFX_GENTLEMAN",
}

-- Gen 3: the graphic the trainer walks around as, as an OBJ_EVENT_GFX_* name
-- this cart has.  There is no class -> graphic table to vote from the way
-- there is above: a Gen 3 map object names its graphic and its script, and
-- the trainer id lives inside the script.  But a Gen 3 NPC fight always
-- starts from the object that spotted the player (trainerbattle runs in its
-- script), so the caller has the answer in hand -- `graphicsId` (a number)
-- or `gfxName` / `sprite` (a name) on the trainer table.  Without one, the
-- generic figure; without a trainer, nil.
local function trainerWalkGfx3(trainer)
  local name = trainer.gfxName or trainer.sprite or trainer.spriteId
  if type(name) == "string" and Gen3.gfxId(name) then return name end
  local id = tonumber(trainer.graphicsId)
  local byId = id and Gen3.gfxName(id)
  if byId then return byId end
  for _, generic in ipairs(GENERIC_TRAINER_GFX) do
    if Gen3.gfxId(generic) then return generic end
  end
  return nil
end

-- OPP_YOUNGSTER -> SPRITE_YOUNGSTER when the catalog has a walk sheet; the
-- overworld's own answer for the classes it does not (OPP_LASS,
-- OPP_BUG_CATCHER, ...); a generic trainer after that.
function M.trainerWalkSpriteId(trainer, game)
  if type(trainer) ~= "table" then return nil end
  if onGen3(game) then return trainerWalkGfx3(trainer) end
  local id = trainer.id or trainer.sprite or trainer.spriteId
  if type(id) ~= "string" or id == "" then return nil end
  local spriteId = id
  if spriteId:match("^OPP_") then
    spriteId = "SPRITE_" .. spriteId:sub(5)
  elseif not spriteId:match("^SPRITE_") then
    spriteId = "SPRITE_" .. spriteId
  end
  -- `M.spriteCatalog`, not `data.sprites`: Gold keeps its walk sheets on
  -- `data.gen2Sprites`, and reading Gen 1's table on a Gold boot proves nothing
  -- about a sheet that is really there.
  local sprites = M.spriteCatalog(game)
  if type(sprites) == "table" and type(sprites[spriteId]) == "table" then
    return spriteId
  end
  -- Soft: accept the id even if we cannot prove the sheet exists here;
  -- Battlefield.resolveHumanSheet will silhouette if load fails.
  if sprites == nil then return spriteId end
  if type(sprites) ~= "table" then return nil end

  -- **`game.data`, and it used to be a bare `data`** -- a name no scope here
  -- binds, so the lookup found the global nil, the vote table was never built
  -- and every class the name transform could not resolve fell straight past
  -- the overworld's own answer into the generic list. A LASS fought as a
  -- COOLTRAINER_M rather than as the SPRITE_COOLTRAINER_F she walks around
  -- as, which reads as a lazy fallback rather than as the dead branch it was.
  local byClass = trainerSpritesByClass(game and game.data)
  local mapped = byClass and byClass[id] or nil
  if type(mapped) == "string" and type(sprites[mapped]) == "table" then
    return mapped
  end
  for _, generic in ipairs(GENERIC_TRAINER_SPRITES) do
    if type(sprites[generic]) == "table" then return generic end
  end
  return nil
end

-- Gen 3: Audio.restoreMapSong, what battle_bridge.lua calls after every fight
-- (the map's song, or the surf / bike override, or a saved cue).
function M.restoreMapMusic(game, opts)
  opts = opts or {}
  if M.generation(game) == 3 then
    local Audio = opts.Audio or Gen3.audio
    pcall(Audio.restoreMapSong)
    return
  end
  local Music = opts.Music
  if not Music then
    local ok, m = pcall(require, "src.core.Music")
    if not ok then return end
    Music = m
  end
  local data = game and game.data
  if Music.restoreMap and data then
    pcall(Music.restoreMap, data)
  end
end

return M
