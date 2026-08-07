-- The hubs this copy has played on: the list behind START > MMO > SERVERS.
--
-- An entry is written by the one event that proves a hub is real -- a welcome
-- off a dialled address -- and never by a dial that was refused, so the list
-- is "places you have actually been" rather than "addresses you have typed".
-- Everything else it carries (a name, a favourite flag, a join code) is the
-- player's, and is why the list exists at all: retyping 192.168.1.20:7788 on
-- a d-pad is the friction this replaces.
--
-- Plain state with no engine dependency beyond the mod facade it is handed,
-- so the suite can drive it directly the way it drives Roster and Chat.
--
-- ------- where it is kept, and why in two places
--
-- Twice, for the reason the rank claim tickets are (src/Client.lua's token
-- store, which this copies): mod.save is RAM the engine happens to flush with
-- the rest of a save, nothing in connecting writes one, and CONTINUE replaces
-- the whole table with whatever was last written -- so a hub recorded this
-- session and never saved would be gone by the next launch, which is exactly
-- the case a recents list exists for. So the list is written to mod.save,
-- still, and to one file of this mod's own that a save reload cannot take
-- away. Reads prefer the file, because a save reload is precisely when
-- mod.save holds the older answer.
--
-- That also settles what the list *is*: machine-level state, shared by every
-- save slot on this copy, not a fact about one trainer's game.
--
-- love is absent under the headless test interpreter, and every path here
-- answers "no file" when it is -- which leaves the mod.save half as the whole
-- behaviour there rather than failing.

local need, chunkMod = ...
local Config = need("Config")
local Wire = need("Wire")

local M = {}
M.__index = M

-- Where the mirror lives inside this mod's own save bucket.
local SAVE_KEY = "servers"

-- ------- addresses

-- The same normalisation the connect path applies, deliberately duplicated
-- rather than shared: withPort and codeKey are locals inside src/Client.lua,
-- and exporting them to reach them here would widen that file's surface for
-- one caller. What matters is that the answer agrees -- the key a hub is
-- filed under has to be the key its join code is filed under, or a player
-- typing "mybox" and a player typing "mybox:7788" would keep two rows for one
-- hub and only one of them would connect.
--
-- Whitespace goes first so the port test sees the end of the address, then
-- the port is filled in (Net's own fallback is the relay's 7778, which is not
-- a port any hub of ours is listening on), and the key is the lower-cased
-- result: one hub, however it was typed, is one row.
local function normalize(address)
  if type(address) ~= "string" then return nil end
  local clean = address:gsub("%s+", "")
  if clean == "" then return nil end

  local host, slot = clean:match("^(.*):([^:]*)$")
  if not host then return ("%s:%d"):format(clean, Config.DEFAULT_PORT) end
  if host == "" then return nil end

  local port = slot:match("^%d+$") and tonumber(slot)
  if port and port > 0 and port < 65536 then return clean end
  return ("%s:%d"):format(host, Config.DEFAULT_PORT)
end

local function keyOf(address)
  local clean = normalize(address)
  if not clean then return nil end
  return clean:lower()
end

-- The one row that belongs to the product rather than to the player's
-- history. A fresh table is returned every time so a caller of the exported
-- list cannot rename the canonical copy in memory. The key is made by the
-- same normaliser as every remembered hub, which is what lets ingestion and
-- presentation recognise an old saved copy as the same server.
local FEATURED_KEY = keyOf(Config.FEATURED_SERVER_HOST)
local function featuredEntry()
  return {
    key = FEATURED_KEY,
    address = Config.FEATURED_SERVER_HOST,
    name = Config.FEATURED_SERVER_NAME,
    fav = false,
    code = Wire.code(Config.FEATURED_SERVER_CODE),
    last = 0,
    featured = true,
  }
end

-- What a hub is called before anybody names it.
--
-- Its own address, which is the only thing known about it at record time and
-- the string the player was read out.
--
-- The default port comes off first, because the sanitiser truncates rather
-- than wraps and a bare truncation lies: at sixteen characters
-- "192.168.1.20:7788" is drawn as "192.168.1.20:778", which is a port nothing
-- is listening on and reads as an address the player could type. Eliding a
-- port that is the one every hub of ours uses anyway costs no information --
-- ":7788" is what normalize just filled in -- and buys five characters, which
-- is the difference between a name that is true and a name that is not.
-- Truncation is still the last resort for what does not fit even then.
--
-- Compared as plain text rather than matched, so the port never has to be
-- read as a pattern. Only the label is shortened: entry.address keeps the
-- whole dialable string, which is what CONNECT dials.
local function defaultName(address)
  local shown = address
  local suffix = ":" .. tostring(Config.DEFAULT_PORT)
  if #shown > #suffix and shown:sub(-#suffix) == suffix then
    shown = shown:sub(1, #shown - #suffix)
  end
  return Wire.text(shown, Config.SERVER_NAME_MAX) or shown
end

local function now()
  if type(os) ~= "table" or type(os.time) ~= "function" then return 0 end
  local ok, stamp = pcall(os.time)
  if ok and type(stamp) == "number" then return math.floor(stamp) end
  return 0
end

-- Everything that comes back off disk or out of a save has been outside this
-- process, so it is checked exactly as hard as a message off the wire: a
-- hand-edited file must not be able to put an unprintable name in a menu or a
-- half-code in a challenge answer.
local function sanitise(raw)
  if type(raw) ~= "table" then return nil end
  local clean = normalize(raw.address or raw.key)
  if not clean then return nil end
  local last = tonumber(raw.last)
  return {
    key = clean:lower(),
    address = clean,
    name = Wire.text(raw.name, Config.SERVER_NAME_MAX) or defaultName(clean),
    fav = raw.fav == true,
    code = Wire.code(raw.code),
    last = (last and last > 0) and math.floor(last) or 0,
  }
end

-- ------- the store

function M.new(ctx)
  return setmetatable({
    -- The facade is taken from ctx so the suite can drive this against its
    -- stub mod; the chunk's own is the fallback for a caller that passes
    -- nothing, and keeps a missing ctx from being a crash on the first log
    -- line.
    mod = (type(ctx) == "table" and ctx.mod) or chunkMod,
    entries = {},
    -- Keys this session removed on purpose -- evicted, or re-keyed by EDIT
    -- HOST. The write below folds in rows it finds on disk that it has never
    -- seen, and without this a row another copy still holds would walk back
    -- in the moment it was dropped here.
    dropped = {},
    loaded = false,
    -- Which of the file complaints below have already been said once. The
    -- file is re-read on every write, so a broken one is a standing condition
    -- and not a blip: unlatched, a player toggling FAVORITE would be told
    -- their save folder is unreadable once per keypress, which buries the
    -- sentence that mattered under the sentence that mattered.
    said = {},
  }, M)
end

function M:_warn(fmt, ...)
  local log = self.mod and self.mod.log
  if log and type(log.warn) == "function" then log:warn(fmt, ...) end
end

-- The same, for a complaint about the file itself: said the first time this
-- session and never again, however many writes go past it afterwards.
function M:_warnOnce(what, fmt, ...)
  if self.said[what] then return end
  self.said[what] = true
  self:_warn(fmt, ...)
end

-- ------- persistence

local function filesystem()
  if type(love) ~= "table" then return nil end
  if type(love.filesystem) ~= "table" then return nil end
  return love.filesystem
end

-- src.link.Json is already this mod's encoder, so a file of our own is not a
-- reason to carry a second one. Resolved once and remembered, including the
-- failure: under the headless interpreter there is no engine to require from
-- and asking again every write would be a pcall per keystroke.
local jsonModule, jsonTried = nil, false
local function json()
  if jsonTried then return jsonModule end
  jsonTried = true
  local ok, module = pcall(require, "src.link.Json")
  if ok and type(module) == "table" then jsonModule = module end
  return jsonModule
end

-- The file, and second whether it is *there and unreadable* -- which
-- love.filesystem.read cannot say on its own, because a missing file and a
-- failed read are the same nil. The two want opposite things from the writer:
-- there is nothing to lose by writing over a file that does not exist, and
-- everything to lose by writing over one that does and would not open.
--
-- A file that will not decode is a third case and is treated as empty, so the
-- next hub recorded rewrites it whole and repairs it. Refusing to remember
-- anything until the player deletes a file nobody told them about would be a
-- worse answer than losing a list of addresses.
function M:_read()
  local fs, Json = filesystem(), json()
  if not (fs and Json) then return nil, false end

  local ok, body = pcall(fs.read, Config.SERVERS_FILE)
  if not ok or type(body) ~= "string" then
    local exists = false
    if type(fs.getInfo) == "function" then
      local asked, info = pcall(fs.getInfo, Config.SERVERS_FILE)
      exists = asked and type(info) == "table"
    end
    return nil, exists
  end
  -- An empty file is readable and says nothing, which is the same as no file.
  if body == "" then return nil, false end

  local decoded = Json.decode(body)
  if type(decoded) ~= "table" then
    self:_warnOnce("decode", "%s is not readable as JSON -- delete it from the "
      .. "game's save folder to reset this copy's server list",
      Config.SERVERS_FILE)
    return nil, false
  end
  return decoded, false
end

-- The rows the save mirror is holding, in the same shape the file uses so one
-- sanitiser covers both.
function M:_saved()
  local save = self.mod and self.mod.save
  if not save then return nil end
  local ok, rows = pcall(save.get, save, SAVE_KEY)
  if not (ok and type(rows) == "table") then return nil end
  return rows
end

-- Applies rows to the table, newest reader wins. `only` restricts it to keys
-- this session has neither seen nor deliberately dropped, which is what the
-- write path needs and the load path does not.
function M:_ingest(rows, only)
  for _, raw in ipairs(rows or {}) do
    local entry = sanitise(raw)
    -- Older builds may already have remembered the official address after a
    -- successful welcome. It is represented by the synthetic row now, so it
    -- is neither loaded into the persisted store nor counted by eviction.
    if entry and entry.key ~= FEATURED_KEY then
      local known = self.entries[entry.key] ~= nil or self.dropped[entry.key]
      if not (only and known) then self.entries[entry.key] = entry end
    end
  end
end

-- The cap, applied by throwing away the hub you have not been to in longest.
--
-- A favourite is never a candidate: marking one is the player saying "keep
-- this", and a list that dropped it anyway would make the flag a decoration.
-- That means a player with SERVER_LIST_MAX favourites has a list that grows
-- past the cap, which is the right way round -- the cap exists to stop a
-- forgotten address accumulating forever, not to refuse the player a hub.
--
-- `keep` is the row the caller is in the middle of returning: the entry just
-- recorded is the newest of them all and cannot be the eviction, except in the
-- one case where every other row is a favourite and it is the only candidate.
-- Every caller that has such a row has to pass it, because "newest" is only
-- the tie-break when the clock is answering: under a degraded now() every row
-- reads as 0, the tie falls to the key, and the entry being returned is as
-- likely to lose it as any other.
--
-- Declared above the readers rather than beside the writers, which is where it
-- belongs by subject, because both of them apply it and a local is only in
-- scope below itself.
local function evict(self, keep)
  local count = 0
  for _ in pairs(self.entries) do count = count + 1 end
  while count > Config.SERVER_LIST_MAX do
    local oldestKey, oldest = nil, nil
    for key, entry in pairs(self.entries) do
      if not entry.fav and key ~= keep then
        -- The key breaks a tie, so two rows recorded in the same second are
        -- resolved the same way on every copy rather than by table order.
        if not oldest or entry.last < oldest.last
          or (entry.last == oldest.last and key > oldestKey) then
          oldestKey, oldest = key, entry
        end
      end
    end
    if not oldestKey then return end
    self.entries[oldestKey] = nil
    self.dropped[oldestKey] = true
    count = count - 1
  end
end

-- Read once a session. The save mirror goes in first and the file over the top
-- of it, key by key, because the file is the durable copy and mod.save is the
-- one a CONTINUE can rewind.
--
-- Then the cap, because nothing so far has applied it: the two halves are
-- merged key by key and either of them may be longer than the list is allowed
-- to be -- a file hand-edited to forty rows, or two halves that overlap in
-- only some of theirs. Recording a hub is not the only way rows arrive, so it
-- cannot be the only place the cap is kept.
function M:_load()
  if self.loaded then return end
  self.loaded = true
  self:_ingest(self:_saved())
  local rows = self:_read()
  if rows then self:_ingest(rows) end
  evict(self)
end

-- The persisted rows in their display order, and the exact array that gets
-- written: favourites first, and within each group the address descending.
-- The featured row is deliberately not made here, because this helper also
-- feeds both persistence mirrors and that row must never consume saved space.
function M:_rows()
  local out = {}
  for _, entry in pairs(self.entries) do out[#out + 1] = entry end
  table.sort(out, function(a, b)
    if a.fav ~= b.fav then return a.fav end
    return a.key > b.key
  end)
  return out
end

-- Write both halves, and in that order: the mirror always, the file
-- best-effort.
--
-- The file is re-read first, because another save slot -- or a second copy of
-- the game running under the same LOVE identity -- may have recorded a hub
-- since we last looked, and writing our cached table back over it would drop
-- theirs. Rows this session dropped on purpose are not folded back in.
--
-- **The one thing this must never do is turn a read failure into a wipe.** The
-- write is the whole list, so a file that exists and would not open is left
-- exactly as it is: the mirror still took the change, and the file repairs
-- itself the next time it reads.
--
-- `keep` is the caller's row, and it is here for the same reason it is on the
-- record path: folding another copy's rows in can push the list over the cap,
-- and the eviction that follows must not be allowed to throw away the very
-- hub this write exists to remember. Without it a degraded clock -- every
-- row's `last` reading 0, the tie falling to the key -- can drop the fresh
-- entry and hand the caller back a row that is no longer in the list.
function M:_persist(keep)
  local rows, unreadable = self:_read()
  if rows then
    self:_ingest(rows, true)
    evict(self, keep)
  end

  local list = self:_rows()
  local save = self.mod and self.mod.save
  if save then pcall(save.set, save, SAVE_KEY, list) end

  local fs, Json = filesystem(), json()
  if not (fs and Json) then return false end
  if unreadable then
    self:_warnOnce("unreadable", "%s could not be read, so this session's "
      .. "server list was not written to it and nothing in it was overwritten "
      .. "-- the list still works for this game; delete the file from the "
      .. "game's save folder if this repeats", Config.SERVERS_FILE)
    return false
  end

  local ok, encoded = pcall(Json.encode, list)
  if not (ok and type(encoded) == "string") then
    self:_warn("could not encode %s (%s) -- the server list will not survive a "
      .. "relaunch; delete the file from the game's save folder if this "
      .. "repeats", Config.SERVERS_FILE, tostring(encoded))
    return false
  end

  local called, wrote, why = pcall(fs.write, Config.SERVERS_FILE, encoded)
  if not (called and wrote) then
    self:_warn("could not write %s (%s) -- hubs you connect to will be "
      .. "forgotten on relaunch unless the game is saved while connected",
      Config.SERVERS_FILE, tostring(called and why or wrote))
    return false
  end
  return true
end

-- ------- persisted recents API
--
-- Client exposes list() through mod.exports.servers, so these two methods are
-- deliberately only the player's recorded history. Product-owned rows belong
-- to the menu projection below and must not leak into that existing API.

function M:list()
  self:_load()
  return self:_rows()
end

-- Takes a key or an address, because they normalise to the same string and a
-- caller holding one should not have to know which it is.
function M:get(key)
  self:_load()
  local id = keyOf(key)
  if not id then return nil end
  return self.entries[id]
end

-- The SERVERS screen has one product-owned row in addition to persisted
-- recents. Keep that projection separate from list/get so external callers
-- still see exactly the history they saw before the featured server existed.
function M:menuList()
  self:_load()
  local out = { featuredEntry() }
  for _, entry in ipairs(self:_rows()) do
    -- `_ingest` and `record` already keep this key out of entries. Retain the
    -- guard at the projection boundary too: even a caller that has modified
    -- the public entries table cannot make the official server appear twice.
    if entry.key ~= FEATURED_KEY then out[#out + 1] = entry end
  end
  return out
end

-- Resolves keys handed back by menuList(), including its synthetic first row.
-- Normal get() intentionally does not: it remains the persisted-recents API.
function M:menuGet(key)
  self:_load()
  local id = keyOf(key)
  if not id then return nil end
  if id == FEATURED_KEY then return featuredEntry() end
  return self.entries[id]
end

-- A hub answered our welcome, so it goes on the list.
--
-- Create or refresh: the player's own name and favourite flag survive a
-- reconnect untouched, because they are the two things on the row that were
-- never ours to write. The code is taken when there is one and left alone
-- when there is not -- a hub that dropped its code this session must not
-- erase the one the player typed.
function M:record(address, code)
  self:_load()
  local clean = normalize(address)
  if not clean then
    self:_warn("could not remember a hub with no address -- reconnect from "
      .. "START > MMO > JOIN GAME and it will be listed then")
    return nil
  end

  local key = clean:lower()
  -- A welcome from the official hub proves the synthetic row works; it does
  -- not turn product configuration into player history. In particular this
  -- skips persistence and eviction, and keeps the configured code canonical.
  if key == FEATURED_KEY then
    self.entries[key] = nil
    return featuredEntry()
  end
  local entry = self.entries[key]
  if not entry then
    entry = { key = key, address = clean, name = defaultName(clean),
              fav = false, code = nil, last = 0 }
    self.entries[key] = entry
  end
  entry.address = clean
  entry.last = now()
  entry.code = Wire.code(code) or entry.code
  self.dropped[key] = nil

  evict(self, key)
  -- Twice, and the second one is not redundant: _persist folds in rows this
  -- session has never seen before it writes, which can put the list back over
  -- the cap, and the eviction it runs then has to be told about this row too.
  self:_persist(key)
  return entry
end

-- What the row is called. Sanitised like any other text the player types, and
-- refused when nothing printable survives -- a blank row is a row nobody can
-- tell from the one above it.
function M:rename(key, name)
  if keyOf(key) == FEATURED_KEY then
    self:_warn("the featured server is built in and cannot be renamed")
    return nil
  end
  local entry = self:get(key)
  if not entry then
    self:_warn("no server is stored for %s, so it cannot be renamed -- connect "
      .. "to it once from START > MMO > JOIN GAME", tostring(key))
    return nil
  end
  if entry.featured then
    self:_warn("the featured server is built in and cannot be renamed")
    return nil
  end
  local clean = Wire.text(name, Config.SERVER_NAME_MAX)
  if not clean then
    self:_warn("that name has nothing in it the game can draw -- type letters "
      .. "or digits, or leave the name as it is")
    return nil
  end
  entry.name = clean
  self:_persist(entry.key)
  return entry
end

function M:setFavorite(key, fav)
  if keyOf(key) == FEATURED_KEY then
    self:_warn("the featured server is already pinned and cannot be changed")
    return nil
  end
  local entry = self:get(key)
  if not entry then
    self:_warn("no server is stored for %s, so it cannot be favourited -- "
      .. "connect to it once from START > MMO > JOIN GAME", tostring(key))
    return nil
  end
  if entry.featured then
    self:_warn("the featured server is already pinned and cannot be changed")
    return nil
  end
  entry.fav = fav and true or false
  self:_persist(entry.key)
  return entry
end

-- The hub moved -- a new IP, a new port, a name instead of an address.
--
-- The row is re-keyed rather than copied, so everything the player put on it
-- travels: a favourite hub that changed address is still favourite, still
-- named what they called it, and still holds the code they typed. A row
-- already sitting at the new address is replaced by this one, which is the
-- only answer that leaves one row per hub -- and the alternative, refusing the
-- edit, would strand the player with two rows and no way to merge them.
function M:setAddress(key, newAddress)
  if keyOf(key) == FEATURED_KEY then
    self:_warn("the featured server's address is built in and cannot be changed")
    return nil
  end
  local entry = self:get(key)
  if not entry then
    self:_warn("no server is stored for %s, so its address cannot be changed "
      .. "-- connect to it once from START > MMO > JOIN GAME", tostring(key))
    return nil
  end
  local clean = normalize(newAddress)
  if not clean then
    self:_warn("that is not an address this game can dial -- type it as an IP "
      .. "or a host name, with an optional :port")
    return nil
  end

  local id = clean:lower()
  if entry.featured or id == FEATURED_KEY then
    self:_warn("the featured server's address is built in and cannot be changed")
    return nil
  end
  if id ~= entry.key then
    self.entries[entry.key] = nil
    self.dropped[entry.key] = true
    self.entries[id] = entry
    self.dropped[id] = nil
    entry.key = id
  end
  entry.address = clean
  self:_persist(entry.key)
  return entry
end

-- The join code this hub asks for, kept on the row so it survives a save-slot
-- change the way the address does. Client keeps its own copy under a per-hub
-- key and that is still what the challenge is answered from; this is the copy
-- that can be handed back to it on CONNECT.
--
-- Refused unless it is a whole code: a half-code stored here would be written
-- through to the connect path and fail every challenge silently, which is the
-- failure this validation exists to turn into a sentence.
function M:setCode(key, code)
  if keyOf(key) == FEATURED_KEY then
    self:_warn("the featured server's join code is built in and cannot be changed")
    return nil
  end
  local entry = self:get(key)
  if not entry then
    self:_warn("no server is stored for %s, so its join code cannot be set -- "
      .. "connect to it once from START > MMO > JOIN GAME", tostring(key))
    return nil
  end
  if entry.featured then
    self:_warn("the featured server's join code is built in and cannot be changed")
    return nil
  end
  local clean = Wire.code(code)
  if not clean then
    self:_warn("that is not a join code -- it is %d characters from the code "
      .. "alphabet, as read out by whoever is hosting", Config.CODE_LEN)
    return nil
  end
  entry.code = clean
  self:_persist(entry.key)
  return entry
end

-- The player is finished with this hub.
--
-- Dropped rather than emptied, and marked as dropped for the same reason
-- eviction and EDIT HOST mark theirs: the write re-reads the file and folds
-- in rows it has never seen, so the copy of this row still sitting on disk --
-- written by another save slot, or by this session a moment ago -- would walk
-- straight back in on the very write that was meant to remove it. The mark is
-- what makes a delete a delete.
--
-- Nothing is handed to _persist as the row to keep, which every other mutator
-- does: this is the one write that wants the list shorter, so the eviction
-- that follows a fold-in has no row here to protect.
function M:remove(key)
  if keyOf(key) == FEATURED_KEY then
    self:_warn("the featured server is built in and cannot be deleted")
    return nil
  end
  local entry = self:get(key)
  if not entry then
    self:_warn("no server is stored for %s, so there is nothing to delete -- "
      .. "open START > MMO > SERVERS and pick a row that is on the list",
      tostring(key))
    return nil
  end
  if entry.featured then
    self:_warn("the featured server is built in and cannot be deleted")
    return nil
  end
  self.entries[entry.key] = nil
  self.dropped[entry.key] = true
  self:_persist()
  return entry
end

return M
