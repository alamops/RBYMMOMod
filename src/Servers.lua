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
-- still, and to a durable store of this mod's own that a save reload cannot
-- take away. Reads prefer the durable half, because a save reload is precisely
-- when mod.save holds the older answer.
--
-- That durable half was a JSON file beside the save until the mod sandbox
-- removed love's filesystem module; it is a mod.storage key now
-- (src/Store.lua), and one sentence that used to be here went with the file:
-- the list was machine-level state shared by every save slot on this copy, and
-- storage is scoped per playthrough, so a second game keeps a second list.
-- Everything else about the design is unchanged, including the rule the write
-- path is built on -- a read failure must never become a wipe.
--
-- mod.storage is absent under the headless test interpreter and answers
-- "nothing here" before a playthrough exists, and every path below treats both
-- as "no store" -- which leaves the mod.save half as the whole behaviour there
-- rather than failing.

local need, chunkMod = ...
local Config = need("Config")
local Gen = need("Gen")
local Wire = need("Wire")
local Store = need("Store")

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
--
-- Resolved on first use and remembered, rather than computed while this chunk
-- loads, because Config.DEFAULT_PORT is no longer settled by then: the PORT
-- option is applied during install, after every module here has been read
-- (Config.applyPort). A key baked at load would be keyed on the fallback port
-- while every later keyOf() used the one the player set -- one hub filed under
-- two keys, and isFeaturedAddress answering false for the official host.
-- FEATURED_SERVER_HOST carries an explicit port today, which makes that
-- harmless; this makes it harmless whatever that constant says next.
--
-- A table rather than a plain local so "not resolved yet" stays distinct from
-- "resolved to nil", which is what a malformed FEATURED_SERVER_HOST gives.
local featuredKeyMemo = {}
local function featuredKey()
  if not featuredKeyMemo.done then
    featuredKeyMemo.done = true
    featuredKeyMemo.key = keyOf(Config.FEATURED_SERVER_HOST)
  end
  return featuredKeyMemo.key
end

local function featuredEntry()
  return {
    key = featuredKey(),
    address = Config.FEATURED_SERVER_HOST,
    name = Config.FEATURED_SERVER_NAME,
    fav = false,
    code = Wire.code(Config.FEATURED_SERVER_CODE),
    last = 0,
    featured = true,
  }
end

local function featuredVisible(game)
  return Config.featuredServerAllowed(Gen.generation(game))
end

-- True when `address` is the product-owned official hub (any typing shape
-- that normalises to the same key). Used by Client to refuse a Gen 2 dial
-- that skipped the SERVERS menu.
function M.isFeaturedAddress(address)
  local id = keyOf(address)
  return id ~= nil and id == featuredKey()
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
    -- HOST. The write below folds in rows it finds in the store that it has
    -- never seen, and without this a row this session recorded a moment ago
    -- would walk back in the instant it was dropped here.
    dropped = {},
    loaded = false,
    -- Which of the store complaints below have already been said once. The
    -- store is re-read on every write, so a broken one is a standing condition
    -- and not a blip: unlatched, a player toggling FAVORITE would be told
    -- their server list is unreadable once per keypress, which buries the
    -- sentence that mattered under the sentence that mattered.
    said = {},
    -- Which hub this copy dials by itself on the way into a game -- one key,
    -- or none.
    --
    -- A scalar rather than a flag on each row, and that is the whole of the
    -- "only one server can auto-join" rule: two rows cannot both hold a value
    -- that has room for one answer, so there is no state a bug could leave
    -- where the list disagrees with itself. It also lets the *featured* row --
    -- which is product configuration and is deliberately never persisted as
    -- history -- be chosen, which a per-row flag could not.
    autoKey = nil,
  }, M)
end

-- Forget everything this instance is holding, so the next read starts over.
--
-- **This exists because the store is scoped to a playthrough and this object
-- is not.** One Servers is built when the mod loads and lives as long as the
-- process, while what it caches now belongs to whichever game is open: a
-- player who loads a different save -- or starts a new one -- would otherwise
-- keep seeing the previous playthrough's hubs, and the next hub they recorded
-- would write that whole list into the new playthrough's store. Under the old
-- machine-level file the cache and the data agreed and none of this was
-- needed; per-playthrough storage is what made the lifetimes differ.
--
-- Client calls it from saveLoaded, which the engine reaches through
-- save.loaded and through save.created -- NEW GAME emits only the second.
-- Every field M.new sets except the facade, which is the one thing here that
-- does belong to the process. autoKey included: which hub this copy dials on
-- the way in is written into the store beside the rows, so it is as much a
-- fact about one playthrough as they are -- and carrying it across would arm
-- the new game with the old one's choice, then persist it there on the next
-- write.
function M:reset()
  self.entries = {}
  self.dropped = {}
  self.said = {}
  self.loaded = false
  self.autoKey = nil
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

-- The stored rows, and second whether the store is *there and unreadable* --
-- which one nil cannot say on its own, because a key that was never written
-- and one that will not decode look the same from here. The two want opposite
-- things from the writer: there is nothing to lose by writing over a key that
-- does not exist, and everything to lose by writing over one that does and
-- would not open.
--
-- This was a JSON file until the mod sandbox took love's filesystem module
-- away, and the encoder went with it -- mod.storage hands back a decoded
-- table, so the src.link.Json round trip this used to do is simply gone. What
-- has not changed is the contract above, which the whole write path is built
-- on.
--
-- A store that will not decode is Storage's problem before it is ours: it
-- stages, verifies and keeps a backup generation, so the case that reaches
-- here is one where every copy is gone. Treating that as "there, leave it
-- alone" rather than as empty is the safe direction, and a list of addresses
-- is the cheapest thing in the mod to lose if that judgement is ever wrong.
-- Silent about the failure on purpose: _persist is the path that has to say
-- something, because it is the one where the player's change is at stake, and
-- one sentence said once beats the same sentence from both halves.
function M:_read()
  local stored, unreadable = Store.read(self.mod, Config.SERVERS_KEY)
  if unreadable then return nil, true end
  if type(stored) ~= "table" or type(stored.rows) ~= "table" then
    return nil, false
  end
  return stored.rows, false
end

-- The rows the save mirror is holding, in the same shape the store uses so one
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
--
-- The auto-join key rides in on the same rows, as an `auto` flag on the one
-- row that carries it, so both mirrors stay a plain array of servers and a
-- build that predates this reads them exactly as it always did.
-- It is read off `raw` rather than kept on the sanitised entry deliberately:
-- the store's answer to "which hub auto-joins" is self.autoKey and nothing
-- else, and a second copy of it sitting on a row is a second copy that could
-- disagree. Returned rather than assigned so _load can decide which reader's
-- answer wins.
--
-- Skipped entirely under `only`, which is the write path folding in rows the
-- store already holds: what this copy auto-joins is a setting this session is
-- in the middle of writing, and the rows being folded in are the older word.
function M:_ingest(rows, only)
  local auto = nil
  for _, raw in ipairs(rows or {}) do
    local entry = sanitise(raw)
    if entry and not only and raw.auto == true and auto == nil then
      auto = entry.key
    end
    -- Older builds may already have remembered the official address after a
    -- successful welcome. It is represented by the synthetic row now, so it
    -- is neither loaded into the persisted store nor counted by eviction --
    -- but its `auto` flag above is still read, because the featured row is
    -- exactly the row that has nowhere else to record one.
    if entry and entry.key ~= featuredKey() then
      local known = self.entries[entry.key] ~= nil or self.dropped[entry.key]
      if not (only and known) then self.entries[entry.key] = entry end
    end
  end
  return auto
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
    -- The auto-join key points at a row, so a row that goes takes it with it.
    -- Left behind it would be a setting naming a hub that is no longer on the
    -- list -- nothing would dial, and the menu would have no row to draw the
    -- mark on, so the player would have no way to see that it was still set.
    if self.autoKey == oldestKey then self.autoKey = nil end
    count = count - 1
  end
end

-- Read once a session. The save mirror goes in first and the store over the
-- top of it, key by key, because the store is the durable copy and mod.save is
-- the one a CONTINUE can rewind.
--
-- That order is also the upgrade path off the old JSON file: a player arriving
-- from a build that wrote one has an empty store and a populated mirror, so
-- the mirror is the whole answer for one session and the next recorded hub
-- writes it into the store.
--
-- Then the cap, because nothing so far has applied it: the two halves are
-- merged key by key and either of them may be longer than the list is allowed
-- to be -- a file hand-edited to forty rows, or two halves that overlap in
-- only some of theirs. Recording a hub is not the only way rows arrive, so it
-- cannot be the only place the cap is kept.
function M:_load()
  if self.loaded then return end
  self.loaded = true
  self.autoKey = self:_ingest(self:_saved())
  local rows = self:_read()
  if rows then
    -- The file is the durable half, so its answer wins -- but only when it
    -- actually has one. A file written by a build that predates auto-join
    -- carries no flag at all, and reading that silence as "off" would throw
    -- away a setting the mirror still remembers.
    self.autoKey = self:_ingest(rows) or self.autoKey
  end
  evict(self)
  -- A key that survived both readers but names no row is nothing this store
  -- can act on -- the row was evicted by the other half of the merge, or
  -- deleted in an earlier session. The featured row is the exception: it is
  -- synthetic and is always there to be dialled.
  if self.autoKey and self.autoKey ~= featuredKey()
      and not self.entries[self.autoKey] then
    self.autoKey = nil
  end
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

-- The array both mirrors are handed: _rows() with the auto-join flag stamped
-- back onto the row that holds it.
--
-- Copies rather than the live entries, because the flag is derived state --
-- self.autoKey is the answer -- and writing it onto the canonical tables
-- would put a second copy of it in every reader's hands, including the ones
-- list() and menuList() hand outside this file.
--
-- Copied field by field rather than field by *name*: before the flag existed
-- this wrote _rows() itself, so whatever sanitise defined was what got
-- persisted, by construction. Re-listing the fields here would make this a
-- second declaration of the row shape -- and the next field added to sanitise
-- would work perfectly in memory, vanish on relaunch, and fail no test,
-- because sanitise would just fill its default back in on the way in.
--
-- The featured row is appended when it is the one that auto-joins, and only
-- then. It is product configuration rather than history, so it is not on the
-- list and must not consume one of SERVER_LIST_MAX's slots -- but "I dial the
-- official hub on the way in" is a player setting like any other, and this
-- stub is the only place it can be written down. Nothing but the key and the
-- flag is persisted with it: the name, code and address stay canonical in
-- Config, and every reader of this file drops the row on the way back in.
function M:_persistRows()
  local out = {}
  for _, entry in ipairs(self:_rows()) do
    local row = {}
    for field, value in pairs(entry) do row[field] = value end
    if self.autoKey == entry.key then row.auto = true end
    out[#out + 1] = row
  end
  if self.autoKey == featuredKey() then
    out[#out + 1] = { key = featuredKey(),
                      address = Config.FEATURED_SERVER_HOST, auto = true }
  end
  return out
end

-- Write both halves, and in that order: the mirror always, the store
-- best-effort.
--
-- The store is re-read first. Under the old file that was load-bearing --
-- another save slot could have recorded a hub since we last looked, and
-- writing our cached table back over it would drop theirs. A storage key
-- belongs to one playthrough, so that particular race is gone; the re-read
-- stays because it costs a decode nobody notices and it is what makes this
-- path safe against a second writer arriving later, which is the direction
-- upstream would move if the machine-level gap is ever closed. Rows this
-- session dropped on purpose are not folded back in.
--
-- **The one thing this must never do is turn a read failure into a wipe.** The
-- write is the whole list, so a store that exists and would not open is left
-- exactly as it is: the mirror still took the change, and the store repairs
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

  local list = self:_persistRows()
  local save = self.mod and self.mod.save
  if save then pcall(save.set, save, SAVE_KEY, list) end

  if not Store.available(self.mod) then return false end
  if unreadable then
    self:_warnOnce("unreadable", "this copy's stored server list could not be "
      .. "read, so this session's list was not written over it and nothing in "
      .. "it was lost -- the list still works for this game")
    return false
  end

  local wrote, why = Store.write(self.mod, Config.SERVERS_KEY, { rows = list })
  if not wrote then
    -- Silent before a playthrough is identified: that is not a fault, it is
    -- the engine still deciding which game this is, and the mirror above
    -- already took the change.
    if why == Store.NO_PLAYTHROUGH then return false end
    self:_warn("could not store the server list (%s) -- hubs you connect to "
      .. "will be forgotten on relaunch unless the game is saved while "
      .. "connected", tostring(why))
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
-- `game` (optional) gates the official row by boot generation — Gen 2 hides
-- it while the public hub stays Gen 1-only.
function M:menuList(game)
  self:_load()
  local out = {}
  if featuredVisible(game) then
    out[#out + 1] = featuredEntry()
  end
  for _, entry in ipairs(self:_rows()) do
    -- `_ingest` and `record` already keep this key out of entries. Retain the
    -- guard at the projection boundary too: even a caller that has modified
    -- the public entries table cannot make the official server appear twice.
    if entry.key ~= featuredKey() then out[#out + 1] = entry end
  end
  return out
end

-- Resolves keys handed back by menuList(), including its synthetic first row.
-- Normal get() intentionally does not: it remains the persisted-recents API.
-- When the official row is generation-gated off, menuGet returns nil for its
-- key the same way a deleted recent would.
function M:menuGet(key, game)
  self:_load()
  local id = keyOf(key)
  if not id then return nil end
  if id == featuredKey() then
    if not featuredVisible(game) then return nil end
    return featuredEntry()
  end
  return self.entries[id]
end

-- ------- auto-join
--
-- One hub, dialled by the client on the way into a game rather than by the
-- player through four menus. The store's whole job here is the "one" -- what
-- to do about it is src/Client.lua's, and when is the moment a world comes
-- up, never a relaunch on its own.

-- The key that auto-joins, or nil. Normalised, so it can be compared against
-- anything menuList hands out.
function M:autoJoinKey()
  self:_load()
  return self.autoKey
end

-- Whether *this* row is the one. Takes a key or an address, like get().
function M:isAutoJoin(key)
  self:_load()
  local id = keyOf(key)
  return id ~= nil and id == self.autoKey
end

-- The row to dial, resolved the way the menu resolves one -- so a generation
-- that cannot see the featured server cannot auto-join it either, and a key
-- whose row went away answers nil rather than handing back a half-entry.
function M:autoJoinEntry(game)
  self:_load()
  if not self.autoKey then return nil end
  return self:menuGet(self.autoKey, game)
end

-- Turn it on for one row, or off.
--
-- Turning it on is what turns it off everywhere else, and no caller has to
-- ask: there is one key. A screen that wants to *tell* the player which hub
-- it is about to displace asks autoJoinEntry first -- that question is the
-- player's to answer, and answering it is not this store's job.
--
-- `on` false only clears the key when this row is the one holding it, so a
-- stale menu row cannot switch off a setting that has since moved.
--
-- `game` is the boot the row is being resolved against, and it is here for
-- the same reason menuGet takes one: the featured row is generation-gated, so
-- a Gold game must not be able to arm a dial at a hub it is not allowed to
-- see. Absent, it resolves as Gen 1 -- which is what every headless caller is.
function M:setAutoJoin(key, on, game)
  self:_load()
  local id = keyOf(key)
  if not id then
    self:_warn("could not set auto-join for a server with no address -- open "
      .. "START > MMO > SERVERS and pick a row that is on the list")
    return nil
  end

  if not on then
    local entry = self:menuGet(id, game)
    if self.autoKey == id then
      self.autoKey = nil
      self:_persist()
    end
    return entry or true
  end

  -- Only a row that exists: the key is what the client dials, and one naming
  -- nothing would be a setting that fails silently every launch.
  local entry = self:menuGet(id, game)
  if not entry then
    self:_warn("no server is stored for %s, so it cannot auto-join -- connect "
      .. "to it once from START > MMO > JOIN GAME", tostring(key))
    return nil
  end
  self.autoKey = id
  self:_persist(id)
  return entry
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
  if key == featuredKey() then
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
  if keyOf(key) == featuredKey() then
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
  if keyOf(key) == featuredKey() then
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
  if keyOf(key) == featuredKey() then
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
  if entry.featured or id == featuredKey() then
    self:_warn("the featured server's address is built in and cannot be changed")
    return nil
  end
  if id ~= entry.key then
    -- The auto-join key travels with the row for the reason the name and the
    -- favourite flag do: a hub that changed address is the same hub, and a
    -- player who set it to auto-join did not ask for that to lapse because
    -- its IP moved. Read before the re-key, written after, so the comparison
    -- is against the key the setting was actually stored under.
    local wasAuto = self.autoKey == entry.key
    self.entries[entry.key] = nil
    self.dropped[entry.key] = true
    self.entries[id] = entry
    self.dropped[id] = nil
    entry.key = id
    if wasAuto then self.autoKey = id end
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
  if keyOf(key) == featuredKey() then
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
-- eviction and EDIT HOST mark theirs: the write re-reads the store and folds
-- in rows it has never seen, so the copy of this row still sitting in it --
-- written by this session a moment ago -- would walk straight back in on the
-- very write that was meant to remove it. The mark is what makes a delete a
-- delete.
--
-- That list used to include "written by another save slot", and no longer
-- can: a storage key belongs to one playthrough, so this session is the only
-- writer. The mark is still load-bearing for the rest of it.
--
-- Nothing is handed to _persist as the row to keep, which every other mutator
-- does: this is the one write that wants the list shorter, so the eviction
-- that follows a fold-in has no row here to protect.
function M:remove(key)
  if keyOf(key) == featuredKey() then
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
  -- And the auto-join setting with it, for eviction's reason: a key naming a
  -- row nobody can see is a dial the player has no way to turn off.
  if self.autoKey == entry.key then self.autoKey = nil end
  self:_persist()
  return entry
end

return M
