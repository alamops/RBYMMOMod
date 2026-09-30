-- Mid-battle (and after-battle) learn / replace.
--
-- A free slot is applied here. A full moveset is a choice only the owner
-- can make, so `open` puts the engine's own prompt on the stack -- Gen 1
-- `MoveLearnMenu`, Gen 2 `Game2:learnMoveOn`, Gen 3 the cart's LearnMove
-- exchange -- and calls back when it finishes. Both screens (MediatedBattle,
-- CoopBattle) teach through this so the two paths cannot drift on "already
-- knows" / "no room" / "missing record".
--
-- ------- Gen 3
--
-- FireRed / LeafGreen / Emerald keep a mon's moves as numbers (`moves`,
-- with `pp` / `maxPp` beside them) and have no MoveLearnMenu screen at all:
-- the whole exchange -- "X is trying to learn Y.", "But X can't learn more
-- than four moves.", "Delete a move to make room for Y?", the summary
-- screen's move picker, "Stop learning Y?", the HM refusal, "1, 2, and...
-- Poof!" -- is src/core/game3/battle/learn_move.lua `LearnMove.begin`, which
-- owns none of its screens: it is handed a message box, a yes/no and a move
-- picker.  The Gen 3 arm below hands it the mod's own boxes (the caller's
-- Ui instance, else src/Gen3Ui.lua's TextBox on the game3 stack) and the
-- summary screen's `select_move` picker, and asks for the battle wording
-- mid-fight -- the prompts the cart prints in its own battle.  The numeric
-- move id is the Gen 3 spelling; a string id never reaches this arm.

local need, mod = ...
local Gen = need("Gen")
local Gen3 = need("Gen3")
local Gen3Ui = need("Gen3Ui")

local M = {}

-- ------- Gen 3 helpers

local function engine(name) return Gen3.engine(name) end

local function moveIdAt(mon, i)
  local entry = type(mon.moves) == "table" and mon.moves[i] or nil
  if type(entry) == "table" then return tonumber(entry.id or entry.num) end
  return tonumber(entry)
end

-- The free-slot half on a Gen 3 mon: the engine's own Pokemon.teachMove
-- (which fills pp / maxPp and emits `pokemon.move_learned`), or the same
-- three writes by hand on a build without it.
local function applyGen3(mon, moveId)
  local id = math.floor(tonumber(moveId) or 0)
  if id <= 0 or not Gen3.moveInfo(id) then return "missing" end
  local P = engine("src.core.game3.pokemon")
  if P and type(P.knowsMove) == "function" then
    local okK, knows = pcall(P.knowsMove, mon, id)
    if okK and knows then return "known" end
    local okC, count = pcall(P.moveSlotCount, mon)
    if okC and tonumber(count) and tonumber(count) >= 4 then return "full" end
    local okT, taught = pcall(P.teachMove, mon, id)
    if okT and taught then return "learned" end
  end
  local free
  for i = 1, 4 do
    local have = moveIdAt(mon, i)
    if have == id then return "known" end
    if (not have or have == 0) and not free then free = i end
  end
  if not free then return "full" end
  local pp = (Gen3.moveInfo(id) or {}).pp or 0
  mon.moves = mon.moves or {}
  mon.pp = type(mon.pp) == "table" and mon.pp or {}
  mon.maxPp = type(mon.maxPp) == "table" and mon.maxPp or {}
  mon.moves[free], mon.pp[free], mon.maxPp[free] = id, pp, pp
  return "learned"
end

-- "learned" -- a free slot was filled on `mon.moves`.
-- "full"    -- four already known; the caller must open a forget prompt.
-- "known"   -- already on the set; nothing to do.
-- "missing" -- no mon, no move id, or this build has no record for it.
--
-- Gen 3 takes the numeric move id its own mons keep (see the header); every
-- other id, on every other boot, goes through the string path unchanged.
function M.apply(mon, moveId, data)
  if type(mon) == "table" and type(moveId) == "number" and Gen3.active() then
    return applyGen3(mon, moveId)
  end
  if type(mon) ~= "table" or type(moveId) ~= "string" or moveId == "" then
    return "missing"
  end
  local def = type(data) == "table" and type(data.moves) == "table"
    and data.moves[moveId] or nil
  if type(def) ~= "table" then return "missing" end
  mon.moves = mon.moves or {}
  for _, known in ipairs(mon.moves) do
    if known.id == moveId then return "known" end
  end
  if #mon.moves < 4 then
    mon.moves[#mon.moves + 1] = { id = moveId, pp = def.pp }
    return "learned"
  end
  return "full"
end

-- Drop the matching `{ mon, move }` entry from a toLearn list. Identity
-- on the mon table, because that is the save-party pointer the fight
-- banked -- an index into the party can move under a catch.
function M.drop(list, mon, moveId)
  if type(list) ~= "table" then return false end
  for i, entry in ipairs(list) do
    if type(entry) == "table" and entry.mon == mon and entry.move == moveId then
      table.remove(list, i)
      return true
    end
  end
  return false
end

-- A box on the game3 stack when the caller handed no Ui instance: the same
-- TextBox Ui.lua's RbyMmoText / RbyMmoConfirm screens build on Gen 3.
local function gen3Say(game, ui, text, cb)
  if ui and type(ui.say) == "function" then
    local ok, pushed = pcall(ui.say, ui, text, cb)
    if ok and type(pushed) == "table" then return true end
  end
  local box = Gen3Ui.TextBox and Gen3Ui.TextBox.new(game, text, cb)
  return box ~= nil and Gen3Ui.pushScreen(game, "RbyMmoText", box) ~= nil
end

local function gen3Confirm(game, ui, text, cb)
  if ui and type(ui.confirm) == "function" then
    local ok, pushed = pcall(ui.confirm, ui, game, text, cb)
    if ok and type(pushed) == "table" then return true end
  end
  local box = Gen3Ui.TextBox and Gen3Ui.TextBox.new(game, text, nil, {
    choice = function(yes) if cb then cb(yes == true) end end,
  })
  return box ~= nil and Gen3Ui.pushScreen(game, "RbyMmoConfirm", box) ~= nil
end

-- The Gen 3 exchange, through the cart's own LearnMove.begin.
--
-- opts: { ui = <Ui instance>, battle = true|false (the battle wording, default
-- true), pushMsg / askYesNo / askForget overrides }.  With no way to put a
-- box up at all (a headless load), LearnMove.begin runs headless: it fills a
-- free slot and declines otherwise, which is the answer its own item path
-- gives a TM with nobody to ask.
local function openGen3(game, mon, moveId, done, opts)
  local LearnMove = engine("src.core.game3.battle.learn_move")
  local id = tonumber(moveId)
  if not (LearnMove and type(LearnMove.begin) == "function" and id) then return false end
  opts = opts or {}
  local ui = opts.ui
  local hasUi = type(rawget(_G, "love")) == "table" and love.graphics ~= nil
    and (ui ~= nil or Gen3Ui.pushScreen ~= nil)
  local begin = {
    mon = mon,
    moveId = id,
    battleText = opts.battle ~= false,
    headless = not hasUi,
    onDone = done,
  }
  if hasUi then
    begin.pushMsg = opts.pushMsg or function(text, cb)
      if not gen3Say(game, ui, text, cb) and cb then cb() end
    end
    begin.askYesNo = opts.askYesNo or function(a, b)
      local cb = (type(a) == "function") and a or b
      local prompt = (type(a) == "string" and a ~= "") and a or ""
      if gen3Confirm(game, ui, prompt, cb) then return end
      -- No box could go up.  A bare "no" is not an answer that ends the
      -- exchange: "Delete a move?" -> no asks "Stop learning?", and that ->
      -- no goes back round (the battle wording re-asks from the top), so a
      -- confirm that keeps failing loops the prompts -- synchronously, since
      -- nothing waits on a box.  The exchange goes headless for the rest of
      -- this move instead (the engine's own "nobody to ask" answer, which
      -- begin() resets for the next one): the "no" leads to the cart's "did
      -- not learn" line and onDone(false).
      LearnMove._headless = true
      if cb then cb(false) end
    end
    begin.askForget = opts.askForget or function(_, cb, ctx)
      local SummaryMenu = engine("src.ui.game3.summary_menu")
      if not (SummaryMenu and type(SummaryMenu.openMenu) == "function") then
        -- No picker is a "no" to forgetting, which the engine turns into its
        -- own "Stop learning?" rather than a stranded prompt.
        if cb then cb(nil) end
        return
      end
      local ok = pcall(SummaryMenu.openMenu, { mon }, 1, {
        mode = "select_move",
        moveToLearn = (ctx and ctx.moveId) or id,
        onSelectMove = function(slot) if cb then cb(slot) end end,
      })
      if not ok and cb then cb(nil) end
    end
  end
  local ok, err = pcall(LearnMove.begin, begin)
  if not ok then
    mod.log:warn("the Gen 3 move-learning prompt failed to open (%s); the move "
      .. "can still be learned by levelling again or from the MOVE RELEARNER",
      tostring(err))
    return false
  end
  return true
end

-- Push the generation's own forget prompt. `onDone(learned)` fires on
-- both answers. Returns true when something is on the stack to call
-- back; false means the caller must fall back (bank toLearn, or
-- auto-fill a free slot).
--
-- `opts` is read on Gen 3 only (see openGen3); Gen 1 / Gen 2 callers need
-- not pass it.
function M.open(game, mon, moveId, onDone, opts)
  if not (type(game) == "table" and type(mon) == "table" and moveId) then
    return false
  end
  local finished = false
  local function done(learned)
    if finished then return end
    finished = true
    if onDone then onDone(learned == true) end
  end

  if Gen.generation(game) == 3 then
    return openGen3(game, mon, moveId, done, opts)
  end

  -- Gold's own LearnMove (engine/pokemon/learn.asm): Yes/No, the
  -- Gen2MoveDeleter list, HM refuse, "1, 2 and… Poof!". There is no
  -- Gen2MoveLearnMenu twin; this is the screen that replaces it.
  if Gen.generation(game) == 2 and type(game.learnMoveOn) == "function" then
    local ok = pcall(function()
      game:learnMoveOn(mon, moveId, done)
    end)
    if ok then return true end
  end

  local pushed
  local ok = pcall(function()
    pushed = mod.ui.push(game, "MoveLearnMenu", mon, moveId, done)
  end)
  return ok and type(pushed) == "table"
end

return M
