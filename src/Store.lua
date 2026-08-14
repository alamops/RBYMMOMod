-- Durable state that outlives a save reload, through the one door the mod
-- sandbox leaves open.
--
-- From the sandbox release a mod cannot open a file: the io library is gone,
-- so is love's filesystem module, and there is no permission that brings
-- either back. What replaces them is mod.storage -- data-only tables, encoded
-- by the engine, scoped to this mod and to the playthrough the player is in.
-- Three stores used to keep a JSON file of their own beside the save (the
-- recents list in src/Servers.lua, the friends lists in src/Friends.lua, the
-- player id in src/Client.lua); all three come through here now, and the shape
-- of the answer is deliberately the shape their old `_read` had, so the
-- callers' "never turn a read failure into a wipe" rule survives the change
-- unaltered.
--
-- What it costs, said plainly because those callers' comments used to promise
-- otherwise: a file was machine-level and a storage key is not. Two save slots
-- on one copy used to share one recents list, one friends list and one player
-- id, and they now each carry their own. That is a real regression, it is not
-- one this file can close, and it is written up for upstream in
-- docs/upstream/machine-level-storage.md rather than worked around here.
--
-- The upgrade path is the mod.save mirror that every one of those callers
-- already keeps and already reads first: a player coming from a build that
-- wrote files still has their list in the last save they took, and the first
-- write after that puts it into storage. Nothing is imported from the old
-- files, because reading them is precisely what a sandboxed mod cannot do.
--
-- Nothing here raises. Every failure reads as "no store", which leaves the
-- mod.save mirror as the whole behaviour -- the same answer the headless test
-- interpreter has always got out of the file half.

local need = ...            -- entry-chunk shape; this module resolves nothing

local M = {}

-- The engine scopes a storage key by the live Game, so every call needs one.
--
-- mod.game rather than a cached handle or src.core.Game: the loader resolves
-- it per touch and per generation (the Gen 1 singleton, the Game2 instance
-- Gold injects), and it is nil until the game is wired -- which is exactly
-- when storage would answer not_in_playthrough anyway.
local function gameOf(mod)
  if type(mod) ~= "table" then return nil end
  local ok, game = pcall(function() return mod.game end)
  if ok and type(game) == "table" then return game end
  return nil
end

-- The facade, or nil when there is none: an older engine, or a stub in the
-- suite that has no reason to carry one.
local function storageOf(mod)
  if type(mod) ~= "table" then return nil end
  local storage = mod.storage
  if type(storage) ~= "table" then return nil end
  if type(storage.read) ~= "function" or type(storage.write) ~= "function" then
    return nil
  end
  return storage
end

-- Whether a write has anywhere to land. Callers use it the way they used to
-- use `filesystem()`: to decide whether the durable half exists at all before
-- doing the work of building what would be written to it.
function M.available(mod)
  return storageOf(mod) ~= nil and gameOf(mod) ~= nil
end

-- Read one key.
--
-- Two answers, for the reason the file readers returned two: the value, and
-- whether the store is *there and would not open*. A missing key and a broken
-- one are the same nil, and they want opposite things from the writer -- there
-- is nothing to lose by writing over a key that was never there, and every
-- other slot's rows to lose by writing over one that exists and did not
-- decode.
--
-- `not_found` and `not_in_playthrough` are both "nothing here": the second is
-- the ordinary answer at the title screen and under the headless interpreter,
-- not a fault. Every other code is treated as the dangerous case, including
-- ones this engine does not raise yet, because the safe direction for an
-- unrecognised failure is to leave what is stored alone.
function M.read(mod, key)
  local storage, game = storageOf(mod), gameOf(mod)
  if not (storage and game) then return nil, false end

  local called, value, code = pcall(storage.read, storage, game, key)
  if not called then return nil, false end
  if type(value) == "table" then return value, false end
  if code == "not_found" or code == "not_in_playthrough" then return nil, false end
  return nil, true
end

-- Write one key, and say why not when it fails so the caller can name the
-- remediation in its own words -- a friends list and a recents list lose
-- different things and must not share one sentence.
--
-- Storage stages, verifies and keeps a backup generation of its own, so there
-- is no torn-write case left for a caller to handle.
--
-- `not_in_playthrough` comes back as M.NO_PLAYTHROUGH and not as a failure
-- code, because the read path above already treats that state as an ordinary
-- "nothing here" and the two must agree. It is what storage answers before a
-- playthrough is identified, and a caller that reported it would be telling a
-- player their hubs are about to be forgotten because the engine has not
-- finished deciding which game they are in -- once per keypress, in a sentence
-- that is not true.
M.NO_PLAYTHROUGH = "no_playthrough"

function M.write(mod, key, value)
  local storage, game = storageOf(mod), gameOf(mod)
  if not (storage and game) then return false, "unavailable" end
  if type(value) ~= "table" then return false, "encode_failed" end

  local called, ok, code = pcall(storage.write, storage, game, key, value)
  if not called then return false, "unavailable" end
  if ok then return true end
  if code == "not_in_playthrough" then return false, M.NO_PLAYTHROUGH end
  return false, code or "write_failed"
end

return M
