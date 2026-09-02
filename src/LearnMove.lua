-- Mid-battle (and after-battle) learn / replace.
--
-- A free slot is applied here. A full moveset is a choice only the owner
-- can make, so `open` puts the engine's own prompt on the stack -- Gen 1
-- `MoveLearnMenu`, Gen 2 `Game2:learnMoveOn` -- and calls back when it
-- finishes. Both screens (MediatedBattle, CoopBattle) teach through this
-- so the two paths cannot drift on "already knows" / "no room" / "missing
-- record".

local need, mod = ...
local Gen = need("Gen")

local M = {}

-- "learned" -- a free slot was filled on `mon.moves`.
-- "full"    -- four already known; the caller must open a forget prompt.
-- "known"   -- already on the set; nothing to do.
-- "missing" -- no mon, no move id, or this build has no record for it.
function M.apply(mon, moveId, data)
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

-- Push the generation's own forget prompt. `onDone(learned)` fires on
-- both answers. Returns true when something is on the stack to call
-- back; false means the caller must fall back (bank toLearn, or
-- auto-fill a free slot).
function M.open(game, mon, moveId, onDone)
  if not (type(game) == "table" and type(mon) == "table" and moveId) then
    return false
  end
  local finished = false
  local function done(learned)
    if finished then return end
    finished = true
    if onDone then onDone(learned == true) end
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
