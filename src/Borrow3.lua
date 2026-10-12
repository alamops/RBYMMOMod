-- What a Gen 3 fight borrows from the live save, and the backstop that keeps
-- a borrow out of a save file.
--
-- The TEACHY TV door (src/CoopField.lua Stand:borrowParty3 /
-- borrowTeachyBag3) and the old man's and WALLY's tutorials
-- (src/Solo3/Tutorial.lua borrowBag3) put a demonstration's party or bag in
-- place of the player's while the fight runs, as the cart does (pret
-- SavePlayerParty / BackUpPlayerBag).  Their own ends give everything back.
-- A fight that never reaches one -- a screen that throws and is popped, an F5
-- hot reload mid-fight -- would leave the swap in the session, and the next
-- save would write the demonstration's monsters and items as the player's.
--
-- Each borrow is recorded here, on the session itself (the engine's
-- Schema.toSaveTable copies named fields only, so the ledger never reaches
-- the file), with the function that gives it back.  The `save.write` hook
-- settles the ledger before every write: a borrow whose fight is over, or
-- that an earlier load of this mod made (a hot reload), is given back; one
-- whose fight is still running vetoes the write.
local need, mod = ...
local Gen3 = need("Gen3")
local M = {}

M.KEY = "_rbyMmoBorrows3"

-- This load of the mod.  A record made by an earlier load (F5) is stale
-- whatever its `alive` says: the screen that held it is gone with that load.
local EPOCH = {}

local function ledger(session, make)
  if type(session) ~= "table" then return nil end
  local l = rawget(session, M.KEY)
  if type(l) ~= "table" and make then
    l = {}
    session[M.KEY] = l
  end
  return type(l) == "table" and l or nil
end

-- Record a borrow under `name` (one per name: each owner keeps its own,
-- "pokedude.party", "tutorial.bag", so one owner's record is never written
-- over another's).  `giveBack()` puts the player's own back; `alive()`
-- answers true while the fight that holds it is still running.  Both are
-- called under pcall.  `label` (optional, else the name) is what a refused
-- save calls it to the player: "party", "bag".
--
-- A caller borrows over a clean slate: settle first (a stale record under
-- the same name would otherwise be replaced, and what it held never given
-- back) -- src/CoopField.lua divertPokedude does, before it swaps anything.
function M.hold(session, name, giveBack, alive, label)
  local l = ledger(session, true)
  if not l or type(name) ~= "string" or type(giveBack) ~= "function" then return false end
  l[name] = { giveBack = giveBack, alive = alive, epoch = EPOCH,
              label = type(label) == "string" and label or name }
  return true
end

-- The owner gave it back itself: forget the record.
function M.release(session, name)
  local l = ledger(session, false)
  if not l then return false end
  local had = l[name] ~= nil
  l[name] = nil
  if next(l) == nil then session[M.KEY] = nil end
  return had
end

function M.held(session, name)
  local l = ledger(session, false)
  return l ~= nil and l[name] ~= nil
end

local function isAlive(record)
  if record.epoch ~= EPOCH then return false end
  if type(record.alive) ~= "function" then return false end
  local ok, alive = pcall(record.alive)
  return ok and alive == true
end

-- Give back every borrow whose fight is over.  Returns how many went back,
-- the names still held by a running fight (a list, empty when none), and
-- those names' labels in the same order.  A giveBack may release its own
-- record (the owner's ordinary return does): the loop walks a sorted copy of
-- the names and re-reads each record, so that is harmless.
function M.settle(session)
  local l = ledger(session, false)
  if not l then return 0, {}, {} end
  local names = {}
  for name in pairs(l) do names[#names + 1] = name end
  table.sort(names)
  local restored, live, labels = 0, {}, {}
  for _, name in ipairs(names) do
    local record = l[name]
    if record == nil then
      -- given back already, by an earlier record's giveBack
    elseif isAlive(record) then
      live[#live + 1] = name
      labels[#labels + 1] = record.label or name
    else
      local ok, err = pcall(record.giveBack)
      l[name] = nil
      if ok then
        restored = restored + 1
      elseif mod then
        mod.log:warn("could not give back the %s a battle borrowed (%s); reload "
          .. "your last save before saving again", record.label or name, tostring(err))
      end
    end
  end
  if next(l) == nil and rawget(session, M.KEY) == l then session[M.KEY] = nil end
  return restored, live, labels
end

-- The labels as one phrase for the refusal line: each said once (a tutorial
-- and a demonstration both hold "bag"), in the order settle read them, and
-- joined as a sentence -- "bag", "bag and party", "bag, party and box".
function M.phrase(labels)
  local seen, out = {}, {}
  for _, label in ipairs(type(labels) == "table" and labels or {}) do
    if type(label) == "string" and label ~= "" and not seen[label] then
      seen[label] = true
      out[#out + 1] = label
    end
  end
  if #out <= 1 then return out[1] or "save" end
  return table.concat(out, ", ", 1, #out - 1) .. " and " .. out[#out]
end

-- The save.write link: settle, then veto a write while a running fight still
-- holds part of the save.
function M.beforeSave(nextLink, game, ...)
  local session = Gen3.session()
  if session then
    local restored, live, labels = M.settle(session)
    if restored > 0 and mod then
      mod.log:info("gave back %d item(s) a finished battle had borrowed before saving",
        restored)
    end
    if #live > 0 then
      if mod then
        mod.log:warn("not saving while a battle still holds your %s; finish the "
          .. "battle, then save", M.phrase(labels))
      end
      return false
    end
  end
  return nextLink(game, ...)
end

function M.install()
  if not (mod and mod.hooks) then return false end
  mod.hooks:wrap("save.write", M.beforeSave)
  return true
end

return M
