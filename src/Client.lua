-- Wiring: options, the hooks and events the mod subscribes to, and the
-- dispatch table that turns hub messages into state changes.
--
-- One rule runs through all of it: the mod never takes over a frame it does
-- not own.  Every hook calls next() and returns what the chain gave it, and
-- every per-tick cost is skipped outright when the player is not connected,
-- so an installed-but-offline copy of this mod is as close to absent as it
-- can be.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local Sha256 = need("Sha256")
local Transport = need("Transport")
local Roster = need("Roster")
local Servers = need("Servers")
local Avatars = need("Avatars")
local Chat = need("Chat")
local Toast = need("Toast")
local Party = need("Party")
local Coop = need("Coop")
-- For one flag it owns. Required rather than reached through `coop.state`,
-- which is an *instance* and is nil between battles -- which is exactly when
-- a save is loaded.
local CoopBattle = need("CoopBattle")
local Ui = need("Ui")
local Overlay = need("Overlay")
local Sessions = need("Sessions")
local World = need("World")
local HostServer = need("HostServer")
local Chars = need("Chars")
local Cast = need("Cast")
-- Only for its entropy pool: this file mints join codes and Hub mints
-- challenge nonces, and both have to come off one pool (see Hub.lua's
-- "the entropy pool" header for why it lives there and what it is worth).
-- Hub is already in this file's dependency graph through HostServer, so
-- naming it costs nothing.
local Hub = need("Hub")

local M = {}

local ctx = {
  game = nil,
  roster = Roster.new(),
  chat = Chat.new(),
  avatars = Avatars.new(),
}

local transport = Transport.new()
local server = HostServer.new()
-- Handed its own one-field table rather than the ctx above: the store wants
-- the mod facade and nothing else, which is what lets the suite construct one
-- against a stub without standing up a client first.
local servers = Servers.new({ mod = mod })
local ui = Ui.new(ctx)
local overlay = Overlay.new(ctx)
-- The corner of the screen, and the one place in this mod that may speak
-- without being asked to.  Everything that used to have nowhere to go --
-- somebody arriving, a whisper from another map, what your partner just
-- fought -- ends up here, because none of it is worth a modal and none of it
-- survives being put behind a menu nobody opened.
local toast = Toast.new(ctx)
local sessions = Sessions.new(transport, ui)
local party = Party.new(transport, ui, ctx.chat)
local coop = Coop.new(transport, ui, party, ctx.roster, ctx.chat)
-- Co-op can be mid-handoff with no screen yet (running/state set, stack
-- still overworld). Sessions asks this so a 1v1 invite is refused there
-- the same way a wild battle on the stack is.
sessions.fighting = function()
  return coop.running == true or coop.state ~= nil
end

ctx.client = M
ctx.ui = ui
ctx.toast = toast
ctx.sessions = sessions
ctx.party = party
ctx.coop = coop
ctx.server = server
ctx.servers = servers

local presenceClock = 0
local lastSent =
  { map = nil, x = nil, y = nil, facing = nil, busy = nil, fast = nil }

-- Whether the last step this player committed was a fast one -- sprinted
-- with B on foot, *or* taken on the bike.  Not "was it a run": a run and a
-- bike both cost 8 frames a tile, so one boolean says everything a watcher
-- needs and asking which would only give them a distinction they cannot
-- draw.  Written by the movement.speed wrap, which is the only place that
-- can know it -- held B is a fact about the local keyboard and moveCtx.onBike
-- is a fact about the step, and nothing else in the process sees either.
-- Read by pushPresence, so everyone else's copy paces the avatar to match.
--
-- Surfing is not fast: it is a 16-frame step like walking, so it stays
-- false and a surfer's avatar keeps the engine's own default pace.
--
-- It is deliberately "the last step", not "B is down right now": a stale
-- true while standing still costs nothing, because an avatar that is not
-- stepping has no step to speed up, and the next ordinary step clears it.
M.fastNow = false

-- Ranked PVP, as this client sees it.
--
-- Both are the hub's answers held for the screens to draw, never worked out
-- locally: the hub owns every rating, so a client that computed its own
-- would be showing the player a number nobody else agrees with. `myPoints`
-- arrives in the welcome and moves on mmo.rank; `ranking` is whatever the
-- last mmo.ranks request came back with. The two flags are what let the RANK
-- screen tell three silences apart -- not in a game, waiting on the hub, and
-- a hub where nobody has won anything yet -- which are one empty list to
-- anything that only counts rows.
local myPoints = Config.RANK_START
local ranking = {}
local rankingAsked = false
local rankingSeen = false
-- Whether this hub is scoring us at all. False means the trainer name we
-- joined under is claimed by somebody else's copy, which is a thing the RANK
-- screen says out loud rather than leaving to be inferred from a zero.
local rankedHere = true

-- Whether the hub considers this connection an operator's.
--
-- Derived by the hub from the credential the connection authenticated with,
-- never from anything this client sent -- a client that could assert it
-- would be a client that promotes itself. Older hubs and ordinary player
-- codes send nothing, and both read as false, which is the honest answer in
-- either case.
--
-- Nothing in the mod uses it yet. It exists so the operator features that
-- arrive later have one fact to check instead of each inventing its own
-- notion of who is in charge.
local myAdmin = false

-- Which hub this connection is talking to, and whether its challenge has
-- already been answered.  Both belong to exactly one connection: an
-- mmo.error means "wrong join code" only when it lands after we answered a
-- challenge and before we were welcomed, and only the hub we dialled may be
-- offered the code stored for it.  nil while hosting -- the local net has no
-- address, so the host's own copy answers with the option row's code.
local dialled = nil
local authSent = false

-- ------- helpers

-- Every entry point below is reachable both ways: menu code calls
-- client:foo(x) and internal code calls M.foo(x). The colon form passes M
-- as the first argument, so anything taking a value has to shift it or the
-- value silently becomes the module table. Declared first because several
-- functions below close over it.
local function arg1(a, b)
  if a == M then return b end
  return a
end

function M.isConnected()
  return transport:isReady()
end

function M.isHosting()
  return server.running == true
end

-- what the host reads out to their friends, once hosting
function M.hostAddress()
  return server:address()
end

function M.hostLimit()
  return server:limit()
end

-- The hubs this copy has been welcomed by.
--
-- The store itself, not a copy of its rows: its readers both read it and
-- write to it (rename, favourite, edit), and two lists that could disagree
-- would be one bug waiting for a player to reopen a menu. The screens reach
-- it as ctx.servers; this is the same object for anything holding the Client
-- instead -- the suite, and any caller that has no ctx.
--
-- Outside this mod it is the rows and not the store: mod.exports.servers,
-- below, so nothing else can rename or evict what the player collected.
function M.servers()
  return servers
end

-- Settings that the player can change from inside the game.
--
-- mod.options is READ-ONLY to a mod -- the loader exposes define and get
-- and nothing else -- so the option row is the persisted *default*, edited
-- in the mod manager, and an in-game change is written to mod.save, which
-- mods may write and which persists with the save file. Reads prefer the
-- in-game value and fall back to the option.
function M.maxPlayers()
  local stored = mod.save:get("maxplayers")
  if stored ~= nil then return Config.clampPlayers(stored) end
  return Config.clampPlayers(mod.options:get("maxplayers"))
end

-- arg1 so the colon form the menus use (client:setMaxPlayers(n)) does not
-- land `self` in the value slot, where clampPlayers would quietly turn the
-- host's choice back into the default
function M.setMaxPlayers(a, b)
  local limit = Config.clampPlayers(arg1(a, b))
  mod.save:set("maxplayers", limit)
  return limit
end

-- An address with its port filled in.
--
-- An IP and a hostname both reach the socket untouched -- Net:connectTCP
-- splits a trailing ":<digits>" off and hands the rest to luasocket, which
-- resolves a name -- so the only half this mod has to supply is the port a
-- bare "mybox" does not carry. It matters which: Net's own fallback is
-- 7778, the *pokeserver relay's*, and a player who typed the name they were
-- read out would dial a port nothing is listening on and be told the relay
-- was unreachable. Applied on every read and every write, so the string
-- that is dialled is also the string a join code is filed under.
--
-- The question is not "is there a colon" but "is there a port behind it".
-- The grid carries a space glyph, a colon and no obligation to use either
-- well, so a player types "mybox:" as readily as "mybox", and both mean the
-- same thing: they did not choose a port. Detecting only ":<digits>" turned
-- the first into "mybox::7788" -- a *different* broken address, dialled at
-- host "mybox:", which reads to the player as the hub being down. So the
-- slot after the last colon is checked rather than merely spotted, and
-- anything that is not a number luasocket can dial -- empty, non-numeric,
-- or out of range -- means no port was given and 7788 fills it in. An
-- explicit, dialable port is never touched.
--
-- Every space goes, not just the ones on the ends, because codeKey (below)
-- already strips whitespace and this did not: a space anywhere filed the
-- passcode under one string and dialled another. No address wants one --
-- neither a hostname nor an IP may contain a space, so a space is only ever
-- something the grid made easy to type. Taking them all out is also what
-- lets "mybox: 7788" keep the port it plainly means, rather than reading as
-- a port that was never given. An address with no host at all (":7788") is
-- refused rather than completed, because there is nothing there to dial and
-- nothing this function could invent -- the same answer "" already gets.
local function withPort(address)
  if type(address) ~= "string" then return nil end
  local clean = address:gsub("%s+", "")
  if clean == "" then return nil end

  local host, slot = clean:match("^(.*):([^:]*)$")
  if not host then return ("%s:%d"):format(clean, Config.DEFAULT_PORT) end
  if host == "" then return nil end

  -- Digits first, then the number: tonumber alone accepts "0x1E", "1e3" and
  -- "+7788", none of which Net's own ":%d+" would match on the way back out.
  -- Reading the slot more liberally than the code downstream of it is how an
  -- address gets called complete and then dialled on 7778.
  local port = slot:match("^%d+$") and tonumber(slot)
  if port and port > 0 and port < 65536 then return clean end
  return ("%s:%d"):format(host, Config.DEFAULT_PORT)
end

function M.joinAddress()
  local stored = withPort(mod.save:get("hub"))
  if stored then return stored end
  local option = withPort(mod.options:get("hub"))
  if option then return option end
  return Config.DEFAULT_HUB
end

function M.setJoinAddress(a, b)
  local address = withPort(arg1(a, b))
  if not address then return nil end
  mod.save:set("hub", address)
  return address
end

-- Where a hub's join code is kept.
--
-- One key per hub, because a player who plays on two of them should not have
-- to retype either -- and because the code is a secret that belongs to one
-- hub: keying it to the address it was typed for is what stops one hub being
-- handed another's. The address is lower-cased and stripped of spaces so the
-- same hub, typed twice, is one key; nothing else is inferred from it (a
-- guessed default port would key a hub the transport never dials).
local function codeKey(address)
  if type(address) ~= "string" then return nil end
  local clean = address:lower():gsub("%s+", "")
  if clean == "" then return nil end
  return "code:" .. clean
end

-- The join code for a hub, normalised into the bytes the HMAC is keyed with.
--
-- No address means no per-hub code -- hosting, where the local net has no
-- address -- and falls through to the option row, which is the standing code
-- for a player who only ever plays on one hub. Same shape as joinAddress:
-- the in-game value wins, the option is the default.
function M.joinCode(a, b)
  local key = codeKey(arg1(a, b))
  local stored = key and mod.save:get(key)
  return Wire.code(stored) or Wire.code(mod.options:get("code"))
end

-- Stores the *normalised* form, never what was typed: the dashes, the case
-- and any punctuation that came with a pasted code are all noise the HMAC
-- key must not carry. Refuses anything that is not a code rather than
-- storing a half-code that would fail every challenge silently.
function M.setJoinCode(a, b, c)
  local address, value
  if a == M then address, value = b, c else address, value = a, b end
  local code = Wire.code(value)
  local key = codeKey(address)
  if not (code and key) then return nil end
  mod.save:set(key, code)
  return code
end

-- Forgets what this copy is holding *for* a hub, when its row is deleted.
--
-- Today that is exactly the join code. The code is the hub's secret rather
-- than the player's: they were read it out, it is filed under the address it
-- was typed for, and a player who deletes the row has said they are done with
-- that hub -- so keeping it would be keeping somebody else's passcode for a
-- server no longer on the list. Cleared with a nil set, the same way
-- setHostJoinCode drops its code.
--
-- The rank claim ticket is deliberately NOT cleared. It is the opposite kind
-- of thing: the ticket is the player's own earned identity on that hub, and
-- dropping it would silently destroy their rating the next time they came
-- back -- the hub would answer the name's rightful owner as an impostor.
-- Deleting a bookmark must not cost a rating. It also lives in the durable
-- token file, which outlives every save slot, so clearing the mod.save half
-- would only half-forget it anyway.
--
-- arg1 for the reason the setters above give: reached as
-- client:forgetHub(address) from the menus, and as M.forgetHub(address) from
-- the suite.
function M.forgetHub(a, b)
  local key = codeKey(arg1(a, b))
  if not key then return nil end
  mod.save:set(key, nil)
  return true
end

-- Where a hub's claim ticket is kept.
--
-- One key per hub, like the join code and for the same reason: the ticket
-- only means anything to the hub that minted it, and a player who plays on
-- two of them holds two. Keyed off the address that was dialled, so the
-- ticket presented is the one the hub in question issued.
--
-- Hosting has no address -- the local net is in-process -- so it falls back
-- to a fixed key. That copy's board is rebuilt every time it starts hosting
-- anyway, so what the ticket buys there is one session's worth of "this name
-- is mine" against the friends who joined, which is exactly the case it is
-- for.
--
-- The address half of both keys below, and "self" when there is no address:
-- lower-cased and stripped of spaces, so one hub typed twice is one key.
local function tokenAddr(address)
  if type(address) ~= "string" or address == "" then return "self" end
  local clean = address:lower():gsub("%s+", "")
  if clean == "" then return "self" end
  return clean
end

local function tokenKey(address)
  return "rank:" .. tokenAddr(address)
end

-- ...and the same ticket, kept where a save file cannot lose it.
--
-- mod.save alone is not durable enough to hold a claim. It is RAM until the
-- engine writes a save, nothing in connecting or disconnecting writes one,
-- and CONTINUE replaces the table wholesale -- so a ticket minted this
-- session and never saved is gone by the next connect, and the hub answers
-- the name's rightful owner as an impostor. The ticket is therefore written
-- twice: to mod.save, still, because that is where every ticket already
-- issued lives, and to one file of this mod's own that a reload cannot take
-- away. Reads prefer the file and fall back to mod.save.
--
-- That file outlives any one save slot and is shared by all of them -- and by
-- any two copies of the game running under one LOVE identity, which is the
-- shape the e2e rig would have if its two sides were not given identities of
-- their own -- so its entries are keyed by hub *and* trainer name,
-- "<hub>|<NAME>", where mod.save can key by hub alone.
--
-- love is absent under the headless test interpreter and every path here
-- answers "no file" when it is, leaving the mod.save behaviour above as the
-- whole behaviour there.
local tokenStore = { loaded = false, entries = {}, unreadable = false }
local jsonModule, jsonTried = nil, false

local function filesystem()
  if type(love) ~= "table" then return nil end
  if type(love.filesystem) ~= "table" then return nil end
  return love.filesystem
end

-- src.link.Json is already this mod's encoder -- HostServer speaks the wire
-- with it -- so a file of our own is not a reason to carry a second one.
local function json()
  if jsonTried then return jsonModule end
  jsonTried = true
  local ok, module = pcall(require, "src.link.Json")
  if ok and type(module) == "table" then jsonModule = module end
  return jsonModule
end

-- Upper-cased because the engine's own trainer names are, and because the
-- read and the write have to agree on one spelling or the ticket is filed
-- where nothing looks for it.
local function tokenFileKey(address, name)
  local who = Wire.name(name) or M.playerName()
  return tokenAddr(address) .. "|" .. who:upper()
end

-- Read once a session; hello runs this on every connect and the file does not
-- change under us between them.
--
-- Answers the entries and, second, whether the file is *there and unreadable*
-- -- which love.filesystem.read cannot say on its own, because a missing file
-- and a failed read are the same nil. The two want opposite things from the
-- writer below (overwrite freely / do not touch it), so getInfo is asked
-- which one this is.
--
-- A file that will not *decode* is a third case and keeps its old answer:
-- reported once and treated as empty, so the next ticket minted rewrites it
-- whole and repairs it. Refusing to store anything until the player deletes a
-- file nobody told them about is the lockout this exists to end.
local function loadTokens()
  if tokenStore.loaded then return tokenStore.entries, tokenStore.unreadable end
  tokenStore.loaded, tokenStore.unreadable = true, false
  local fs, Json = filesystem(), json()
  if not (fs and Json) then return tokenStore.entries, false end
  local ok, body = pcall(fs.read, Config.RANK_TOKEN_FILE)
  if not ok or type(body) ~= "string" then
    -- Nothing came back. If the file exists, this copy just failed to read a
    -- file it must not then overwrite.
    local exists = false
    if type(fs.getInfo) == "function" then
      local asked, info = pcall(fs.getInfo, Config.RANK_TOKEN_FILE)
      exists = asked and type(info) == "table"
    end
    tokenStore.unreadable = exists
    return tokenStore.entries, exists
  end
  -- An empty file is readable and says nothing, which is the same as no file:
  -- there is nothing in it to lose by writing over it.
  if body == "" then return tokenStore.entries, false end
  local decoded = Json.decode(body)
  if type(decoded) ~= "table" then
    mod.log:warn("%s is not readable as JSON -- delete it from the game's "
      .. "save folder to reset this copy's hub name claims",
      Config.RANK_TOKEN_FILE)
    return tokenStore.entries
  end
  for key, value in pairs(decoded) do
    local token = Wire.token(value)
    if type(key) == "string" and token then tokenStore.entries[key] = token end
  end
  return tokenStore.entries
end

-- Load, modify, write the whole table -- and re-read first, because another
-- save slot, or a second copy running under the same LOVE identity, may have
-- added a key since we last looked, and writing our cached copy back would
-- drop it. This runs once per welcome, so the extra read is not on any path
-- worth counting.
--
-- **The one thing this must never do is turn a read failure into a wipe.**
-- The write below is the whole table, so a re-read that came back empty
-- because the file could not be opened -- rather than because there is no
-- file -- would hand back a file holding one key and throw away every other
-- hub's ticket. loadTokens says which of the two happened, and the unreadable
-- one writes nothing at all.
--
-- Every failure path drops this key from the in-session cache before it
-- returns. The cache may be holding an *older* ticket for it, read off the
-- file; leaving that there would let it shadow the newer token M.setRankToken
-- has just put in mod.save, and after a real save and relaunch the stale one
-- would be the answer.
local function storeToken(address, name, token)
  local fs, Json = filesystem(), json()
  if not (fs and Json) then return false end
  local key = tokenFileKey(address, name)

  local kept = tokenStore.entries
  tokenStore.loaded, tokenStore.entries = false, {}
  local entries, unreadable = loadTokens()
  if unreadable then
    -- The file is there and would not open. This session keeps what it had,
    -- minus this key, and the ticket lives in mod.save until the file reads
    -- again.
    tokenStore.loaded, tokenStore.entries = true, kept
    kept[key] = nil
    mod.log:warn("%s could not be read, so this hub's claim ticket was not "
      .. "added to it -- nothing was overwritten (the other hubs' tickets are "
      .. "still in there); save the game while connected, and delete the file "
      .. "from the game's save folder if this repeats", Config.RANK_TOKEN_FILE)
    return false
  end
  entries[key] = token

  local encoded
  local ok, result = pcall(Json.encode, entries)
  if ok and type(result) == "string" then encoded = result end
  if not encoded then
    entries[key] = nil
    mod.log:warn("could not encode %s (%s) -- delete it from the game's save "
      .. "folder if this repeats", Config.RANK_TOKEN_FILE, tostring(result))
    return false
  end

  local called, wrote, why = pcall(fs.write, Config.RANK_TOKEN_FILE, encoded)
  if not (called and wrote) then
    entries[key] = nil
    mod.log:warn("could not write %s (%s) -- this hub will stop scoring you "
      .. "under this name after a reload unless the game is saved while "
      .. "connected", Config.RANK_TOKEN_FILE, tostring(called and why or wrote))
    return false
  end
  return true
end

-- The file wins over mod.save: a save reload is exactly the case where
-- mod.save has the older answer.
--
-- The two can disagree, and this is which way it is settled when they do. A
-- welcome writes both, so ordinarily they say the same thing; a welcome whose
-- file write failed wrote only mod.save, and storeToken drops that key from
-- the cache on its way out precisely so this read falls through to the newer
-- answer instead of finding a stale one in front of it.
function M.rankToken(a, b, c)
  local address, name
  if a == M then address, name = b, c else address, name = a, b end
  local kept = loadTokens()[tokenFileKey(address, name)]
  if kept then return kept end
  return Wire.token(mod.save:get(tokenKey(address)))
end

-- Stored only if it is the shape a hub mints. A half-token would fail every
-- claim from then on, and silently: the player would simply stop being
-- ranked, with nothing on screen to connect it to.
--
-- The file write is best-effort and never gates the mod.save one: a copy that
-- cannot write to its save folder is no worse off than it was before this
-- file existed.
function M.setRankToken(a, b, c, d)
  local address, value, name
  if a == M then address, value, name = b, c, d else address, value, name = a, b, c end
  local token = Wire.token(value)
  if not token then return nil end
  mod.save:set(tokenKey(address), token)
  storeToken(address, name, token)
  return token
end

-- The code this copy asks for when it hosts.
--
-- One key, not one per address: there is only ever one game this copy is
-- running. A code is required now rather than optional, so absent is not a
-- setting -- it is a game that cannot start, and the host screen mints one
-- on the way in so the usual answer is six characters nobody had to invent.
function M.hostJoinCode()
  return Wire.code(mod.save:get("hostcode"))
end

-- nil or "" clears the stored code; anything else is stored normalised or
-- refused. No screen clears it any more, but the path stays: a code left by
-- an older build that will not normalise has to be droppable, and clearing
-- it stops a game rather than opening one. Refused, never stored
-- half-formed: a host who believes their game is locked and finds it open
-- is the failure this whole feature exists to prevent.
function M.setHostJoinCode(a, b)
  local value = arg1(a, b)
  if value == nil or value == "" then
    mod.save:set("hostcode", nil)
    return nil
  end
  local code = Wire.code(value)
  if not code then return nil end
  mod.save:set("hostcode", code)
  return code
end

-- A fresh code for the host to read out, so nobody has to invent one on a
-- d-pad.
--
-- The code *is* the credential, and the attack on a weak one is offline:
-- anyone who captures a single mmo.challenge/mmo.auth pair can grind
-- candidate codes locally against HMAC(code, nonce) at hardware speed, where
-- none of the hub's connect-rate or per-IP limits apply. So the bytes come
-- off the session entropy pool -- fed on every fixed step with frame
-- timings, clock deltas, heap size and the player's own button presses --
-- and not from one instantaneous sample the way they used to.
--
-- **It is still not a CSPRNG**, and the honest numbers are in Hub.lua's pool
-- header rather than here so there is one copy of them: about 35-45 bits if
-- something contrives to draw before a single frame has run, and a claimed
-- 64 from a game that has been playing for more than a moment, which is
-- every game that has reached this screen. At six characters the code
-- itself carries 30 bits (Config.CODE_LEN), so on that second path the
-- length is the binding constraint and not the pool -- what a code is worth
-- is argued out in Config, next to the number that decides it. A host who
-- wants a code they chose types their own.
function M.newJoinCode()
  local code, why = Hub.Entropy.shared:code()
  -- The pool answers nil plus a reason rather than raising. `why` never
  -- carries a drawn byte, and the code itself never reaches a log -- here or
  -- anywhere else -- which is the whole reason this returns it instead of
  -- reporting it.
  if type(code) ~= "string" then
    mod.log:warn("could not generate a join code (%s) -- type one instead "
      .. "from START > MMO > HOST GAME > JOIN CODE", tostring(why))
    return nil
  end
  return code
end

-- Put the player in front of the code screen.
--
-- The fallback, not the main road: JOIN GAME now asks for a code straight
-- after the address, so this is what a mistyped one lands on -- a hub asking
-- for a code this copy does not have, or refusing the one it does. Either
-- way the alternative is a connection that simply stops, with nothing on
-- screen to act on.
function M.askJoinCode(game, address, reconnect)
  game = game or ctx.game
  if not game then return false end
  mod.ui.push(game, Ui.SCREEN.JOINCODE, {
    address = address,
    connect = reconnect and true or false,
  })
  return true
end

-- The name other players see.
--
-- Separate from the save's trainer name on purpose: character creation lets
-- someone be "ASH" online without renaming their single-player file. It
-- falls back to the save name, so a player who never opens the creator is
-- still recognisable.
-- arg1 for the same reason setMaxPlayers has it: the menus call
-- client:playerName(game), which would otherwise land the module table in
-- the game slot and lose the save-name fallback to "PLAYER".
function M.playerName(a, b)
  local chosen = mod.save:get("name")
  if type(chosen) == "string" and chosen ~= "" then
    return Wire.name(chosen) or "PLAYER"
  end
  local game = arg1(a, b) or ctx.game
  local name = game and game.save and game.save.player and game.save.player.name
  return Wire.name(name) or "PLAYER"
end

function M.setPlayerName(a, b)
  local name = Wire.name(arg1(a, b))
  if not name then return nil end
  mod.save:set("name", name)
  return name
end

-- The character other players see you as. Resolved against this game's own
-- catalog, so a value carried over from a save made against a different ROM
-- degrades to RED instead of failing to draw.
function M.spriteChoice()
  local chosen = mod.save:get("sprite")
  if type(chosen) ~= "string" or chosen == "" then
    chosen = mod.options:get("sprite")
  end
  return Chars.resolve(chosen)
end

-- The same choice, but nil when the player is not asking to be anybody else.
--
-- spriteChoice always has an answer, because everybody has to be drawn as
-- somebody. This one separates "asked for a character" from "left it to the
-- game", which is what decides whether a look is worn outside a session at
-- all: a save that says nothing and a global option still sitting on the
-- default mean this player never touched the character side of the mod, and
-- their single-player game keeps the renderer the engine built for it.
-- Installing the mod must not silently swap anybody's trainer.
--
-- The rule is that explicitness is a property of what would actually be
-- *worn*, not of the string as it was typed. Whichever of the two sources
-- answers is resolved first, and a value that resolves to RED comes back as
-- nil -- because RED is the trainer the engine already draws, so putting it
-- on is a restore rather than a wear, and syncLook reads that nil as exactly
-- the restore it is. That is what makes picking RED in the creator really
-- hand the engine's own renderer back, which is what the card and the README
-- promise. Deciding it after the resolve is also what keeps a value carried
-- over from another ROM honest: an id this catalog cannot draw degrades to
-- RED, and "leave them alone" is the right reading of it, not "explicitly
-- RED" -- a choice nobody here ever made.
--
-- Resolved like spriteChoice, so what does come back is always a character
-- this game can actually draw.
function M.explicitChoice()
  local chosen = mod.save:get("sprite")
  if type(chosen) ~= "string" or chosen == "" then
    chosen = mod.options:get("sprite")
  end
  if type(chosen) ~= "string" or chosen == "" then return nil end
  local id = Chars.resolve(chosen)
  if id == Config.DEFAULT_SPRITE then return nil end
  return id
end

-- ------- telling the hub which character you are
--
-- The character the hub has confirmed for us, and how long ago we last said
-- it.
--
-- A push is one message into a gate: both hubs refuse a second character
-- change from one client inside half a second (src/Hub.lua's SPRITE_GATE and
-- server/lib/relay.js, both the CHAT_GATE window), and a refused one is
-- silent. Fire and forget therefore had a permanent failure in it -- the
-- player wears the new character in their own game while the hub goes on
-- putting the old one in every mmo.move, for the rest of the session, with
-- nothing that would ever say it again.
--
-- So the character is reconciled rather than announced. `spriteAcked` is what
-- we know the hub is holding; the tick re-pushes while the choice has moved
-- away from it and stops the moment the two agree. Only two things write it
-- -- the hello that seeds it, and the hub's own broadcast of our change --
-- so it is always the hub's answer and never our own optimism, which is what
-- keeps the loop from chasing itself.
--
-- The same loop is also the only thing that carries a change made from the
-- global MY SPRITE row in the mod manager: that writes the option and calls
-- nothing, so without this a player who changed character there told nobody.
-- Anything else that moves spriteChoice in future is carried for free.
--
-- The clock is seconds since the last push, not a running session time: every
-- push resets it, so a retry can never land inside the window that refused
-- the last one. It also paces how often the choice is *read* -- resolving one
-- costs a pcall through the sprite registry (Chars.available), which is not
-- something to do sixty times a second for an answer that only changes when
-- the player does something.
local spriteAcked = nil
local spriteClock = 0
-- Twice the gate, so a re-push is always clear of it rather than racing it.
-- Named off CHAT_GATE because that is the window both hubs actually gate a
-- character change with (Hub.lua's SPRITE_GATE header says so out loud), and
-- a retry paced off anything else would drift away from it silently.
local SPRITE_RETRY = Config.CHAT_GATE * 2

-- Tell the hub which character you are now.
--
-- Sent at the moment of the change, and re-sent by the tick for as long as
-- the hub has not confirmed it. Not presence, though: there is nothing
-- periodic here, because once the hub has stored a character every later
-- broadcast carries it anyway -- a player who joins afterwards is told by the
-- ordinary presence stream, with nothing extra sent from here.
--
-- What goes on the wire is always the *resolved choice* (M.spriteChoice()),
-- never the worn/not-worn distinction M.explicitChoice() draws. Picking RED
-- mid-session broadcasts SPRITE_RED to everyone else while syncLook hands the
-- engine's own renderer back locally -- the two are assumed to draw the same
-- picture, which is the assumption explicitChoice's header states and this is
-- its echo at the wire boundary. If those two ever stop matching, they stop
-- matching here first.
--
-- Offline is silence, not a failure: picking a character outside a game is
-- the ordinary case, the choice is saved and worn either way, and there is
-- simply nobody to tell.
function M.pushSprite()
  if not transport:isReady() then return false end
  -- before the send, so a send that throws still costs the retry its full
  -- window rather than re-firing on the next tick
  spriteClock = 0
  transport:send(Wire.SPRITE, { sprite = M.spriteChoice() })
  return true
end

-- Choosing a character wears it there and then, and tells the hub.
--
-- The picker is reachable outside a game now, so a screen that changed who
-- you are without changing what you see would read as broken -- and the
-- older path, where the look only appeared at connect time, was that same
-- delay in a place nobody noticed it. The same argument reaches one step
-- further: the hub used to learn your character once, in your hello, so a
-- character picked mid-game was one only you could see. Three lines in one
-- order -- save it, wear it, say it -- so that what goes on the wire is the
-- choice that was actually kept. The contract callers rely on is unchanged
-- (the id on success, nil for a character this game does not have), so no
-- screen has to know a look was applied or a message sent.
function M.setSpriteChoice(a, b)
  local id = arg1(a, b)
  if not Chars.available(id) then return nil end
  mod.save:set("sprite", id)
  M.syncLook()
  M.pushSprite()
  return id
end

-- The trainer-card fields this player shows to others. Read from the save
-- at hello time, so it is a snapshot of who you were when you joined.
function M.profile(a, b)
  local game = arg1(a, b) or ctx.game
  local save = game and game.save
  if not save then return nil end
  local dex = save.pokedex or {}
  local seen, owned = 0, 0
  for _ in pairs(dex.seen or {}) do seen = seen + 1 end
  for _ in pairs(dex.owned or {}) do owned = owned + 1 end

  -- Badges are counted through the engine's own list rather than assumed to
  -- be the eight Kanto ones, so a mod that adds a badge is counted too.
  local badges = 0
  local ok = pcall(function()
    local Badges = require("src.inventory.Badges")
    badges = Badges.count(game.data, save) or 0
  end)
  if not ok then badges = 0 end

  -- Deliberately no money: the card does not show another player's wallet,
  -- so there is no reason to put it on the wire.
  --
  -- playTime, not playtime: the engine's field is camel-cased
  -- (src/core/SaveData.lua, and every screen that shows a clock reads it
  -- that way). The lowercase spelling read nil, so every card this mod
  -- ever sent said TIME/  0:00. The old key is still consulted so a save
  -- written by something that used it is not thrown away.
  return {
    idNo = tonumber(save.player and save.player.id) or 0,
    badges = badges,
    seen = seen,
    owned = owned,
    playtime = math.floor(tonumber(save.playTime or save.playtime) or 0),
  }
end

-- Your own trainer card, shaped like a roster entry so the same screen can
-- draw it.
--
-- Built here rather than looked up: the roster deliberately drops your own
-- presence (Roster:isSelf) so you are not spawned as your own avatar, which
-- leaves nothing to point the card screen at.
--
-- Money rides along, and only here. It is the one field Wire.profile
-- refuses to carry, so it can never arrive from the wire -- which is what
-- makes its presence the honest test for "this card is mine", and keeps
-- another player's wallet unreachable by construction.
--
-- Two callers now, arrived at independently and wanting the same thing:
-- MY PROFILE on the MMO menu, and the party members list, which lists both
-- members and would otherwise open "they just went offline" against
-- yourself. The party branch built a second copy of this without the money
-- row; there is one, and it is this one, because a card that is missing the
-- field that identifies it as yours is the weaker of the two.
function M.ownCard(a, b)
  local game = arg1(a, b) or ctx.game
  local save = game and game.save
  return {
    id = ctx.roster.selfId,
    name = M.playerName(game),
    sprite = M.spriteChoice(),
    profile = M.profile(game),
    money = save and math.floor(tonumber(save.money) or 0) or 0,
    -- the hub's number, not a local one: this is the row everybody else is
    -- reading off your card
    points = myPoints,
  }
end

-- ------- ranked PVP

-- What this player is worth on the hub they are on.  Zero while offline: a
-- rating is a fact about a hub, and there is no hub to have one on.
function M.points()
  return myPoints
end

-- The last leaderboard the hub sent, newest first, and whether one has been
-- asked for yet.  The screen draws from here every frame, so an answer that
-- arrives while it is open simply appears.
function M.ranking()
  return ranking, rankingAsked, rankingSeen
end

-- Is this hub scoring us?  False only when the name we joined under belongs
-- to somebody else's copy here.
function M.isRanked()
  return rankedHere
end

function M.requestRanking()
  if not transport:isReady() then return false end
  rankingAsked = true
  transport:send(Wire.RANKS, {})
  return true
end

-- Tell the hub how a ranked battle ended.
--
-- Sent by both players, and worth nothing on its own: the hub scores a match
-- only when the two reports agree (see Hub:settleMatch), so this is a vote,
-- not a verdict. Reported even when it is a loss -- a client that could
-- withhold one would be a client that never loses points.
-- The transport is checked *before* the claim, not after: claiming is what
-- spends it, so asking a closed connection to carry a report would throw the
-- battle away rather than leaving it reportable.
function M.reportBattle(state, result)
  if not transport:isReady() then return false end
  local battle = sessions:claimBattle(state)
  if not (battle and battle.id) then return false end
  local outcome = "draw"
  if result == "win" then outcome = "win"
  elseif result == "lose" then outcome = "loss" end
  transport:send(Wire.RESULT, { session = battle.id, outcome = outcome })
  return true
end

-- ------- telling your partner what you just fought
--
-- Solo battles produce no peer traffic at all -- a wild encounter is entirely
-- a fact about one client -- so travelling together used to mean walking
-- beside somebody whose evening you knew nothing about.  What follows is the
-- whole of the fix: the engine's own battle events, turned into the five
-- sentences src/Toast.lua knows how to draw, sent to the hub, and fanned out
-- to the one person who is travelling with us.
--
-- Nothing here toasts locally.  The fighter watched the battle happen; a line
-- in their own corner saying so would be the game narrating what is already
-- on screen, and both hubs deliberately leave the sender out of the fan-out
-- for the same reason.

-- The gate every party event passes.
--
-- A party is checked here as well as at the hub, and not out of distrust: an
-- unpartied player fights most of the battles anybody ever fights, and every
-- one of them would be a packet built, encoded and sent for a hub to drop on
-- arrival.  `partner()` as well as `has()`, because the two answer different
-- questions: a members list that came back holding nobody but us is still a
-- party, and there is no one in it to tell.
local function sendPartyEvent(fields)
  if not transport:isReady() then return false end
  if not (party:has() and party:partner()) then return false end
  transport:send(Wire.PARTY_EVENT, fields)
  return true
end

-- The species and level on the other side of a battle, as the game spells
-- them.
--
-- `def.name` rather than the battler's own `name`, and the difference is a
-- capture: a battler is named for its nickname when it has one, and the
-- nickname prompt runs on the way out of the very battle this is read for --
-- so a player who renames their new MEWTWO would otherwise tell their partner
-- they caught somebody called BOB.  The species id is the fallback for a
-- build whose battler carries no def, which is the same word in capitals for
-- every vanilla species.
local function enemyMon(battle)
  if type(battle) ~= "table" or type(battle.enemy) ~= "table" then
    return nil, nil
  end
  local enemy = battle.enemy
  local mon = type(enemy.mon) == "table" and enemy.mon or nil
  local def = type(enemy.def) == "table" and enemy.def or nil
  local species = (def and def.name) or (mon and mon.species)
  if type(species) ~= "string" then species = nil end
  return species, mon and tonumber(mon.level) or nil
end

-- ...and the name on the other side of a trainer battle.
--
-- The record's own name, which is what the intro text says out loud ("%s
-- wants to fight!"), so the sentence a partner reads names the opponent the
-- fighter actually saw.  A battle whose trainer record cannot be read still
-- gets a sentence rather than none: the fight happened either way, and "was
-- defeated by Trainer" is a true thing to say about it.
local function trainerName(battle)
  local trainer = type(battle) == "table" and battle.trainer
  if type(trainer) == "table" and type(trainer.name) == "string"
     and trainer.name ~= "" then
    return trainer.name
  end
  return "Trainer"
end

-- Tell your partner how a fight went.
--
-- Which of the four sentences is picked comes entirely off the battle the
-- engine just finished -- `kind` says wild or trainer, `result` says which way
-- it went -- rather than off anything this mod was tracking alongside it.
--
-- Three endings are deliberately silent.  A run is not a defeat.  A capture
-- is not one either, and it has already been narrated by pokemon.caught,
-- which is the event that knows *what* was caught; sending from both would
-- put one capture on the partner's screen twice.  And a link battle belongs
-- to Sessions -- M.reportBattle above is what that one is worth -- so it is
-- ruled out here by name rather than left to fall through the wild branch as
-- a "wild" fight against another trainer's lead.
function M.narrateBattle(battle, result)
  if type(battle) ~= "table" then return false end
  if battle.kind == "link" then return false end
  if not (result == "win" or result == "lose") then return false end
  local won = result == "win"

  if battle.kind == "trainer" then
    return sendPartyEvent({
      kind = won and "defeat_trainer" or "defeated_by_trainer",
      trainer = trainerName(battle),
    })
  end

  -- Everything that is not a trainer or a link is fought against a single
  -- wild mon -- the Safari Zone and the old man's demo are both kind ==
  -- "wild" in the engine -- so a species and a level is the whole of what
  -- there is to say. Missing either is silence: the hub refuses a half-filled
  -- event anyway, and a sentence that stops mid-way is the one failure of
  -- this feature a player would actually see.
  local species, level = enemyMon(battle)
  if not (species and level) then return false end
  return sendPartyEvent({
    kind = won and "defeat_wild" or "defeated_by_wild",
    species = species,
    level = level,
  })
end

-- ...and what you just caught.
--
-- Read from the battle first and the payload second, because the two answer
-- different halves well: the battle knows the name the game shows, while the
-- event carries the species id and the mon itself and still answers on a
-- build that hands over one without the other.
function M.narrateCatch(payload)
  if type(payload) ~= "table" then return false end
  -- Ruled out by name, exactly as narrateBattle rules it out: a link battle
  -- belongs to Sessions, and nothing is caught in one anyway -- a build that
  -- fired pokemon.caught during one would put a sentence about a capture that
  -- did not happen on a partner's screen.
  local battle = payload.battle
  if type(battle) == "table" and battle.kind == "link" then return false end
  local species, level = enemyMon(payload.battle)
  local mon = type(payload.mon) == "table" and payload.mon or nil
  if not species and type(payload.species) == "string" then
    species = payload.species
  end
  if not level and mon then level = tonumber(mon.level) end
  if not (species and level) then return false end
  return sendPartyEvent({ kind = "capture", species = species, level = level })
end

-- ------- your own look, in your own game
--
-- Choosing a character has to change what *you* see too, not just what
-- everyone else sees, or the creator reads as broken.
--
-- The overworld player takes its sheet from field.playerSprites at
-- Player.new time (src/world/Player.lua), so there is no option to flip
-- once the player exists -- the renderer has to be swapped on the live
-- object. The original is kept because the look is not always on: a player
-- who never chose a character has theirs put back the moment there is
-- nothing standing to wear (M.syncLook), rather than being left dressed as a
-- Rocket grunt in a single-player game they never asked to change.
--
-- It is kept *against the entity it was taken from*. The overworld reuses
-- one player object across map changes -- OverworldController:setMap only
-- calls Player.new when it has none -- so re-wearing the look on map.entered
-- reads back the renderer this mod installed a moment ago. Stashing that as
-- "the original" is what used to hand a leaving player their hub character
-- instead of their trainer; the owner is what tells a genuinely rebuilt
-- player, from a new save or a new controller, apart from the same one
-- walking through a door.
local originalLook = nil
local lookOwner = nil

local function playerEntity()
  local world = mod.world
  local ow = world and world:overworld()
  return ow and ow.player or nil
end

function M.applyLook(game)
  local player = playerEntity()
  if not player then return false end
  local id = M.spriteChoice()
  local record = mod.content.sprites and mod.content.sprites:get(id)
  if not record then return false end

  local ok, renderer = pcall(function()
    local SpriteRenderer = require("src.render.SpriteRenderer")
    return SpriteRenderer.new(record, "player")
  end)
  if not (ok and renderer) then
    mod.log:warn("could not wear %s; staying as you are", tostring(id))
    return false
  end
  if lookOwner ~= player then
    originalLook = player.sprite
    lookOwner = player
  end
  player.sprite = renderer
  return true
end

-- Entering a map can rebuild the player, taking the chosen look with it, so
-- the look is re-worn from map.entered rather than watched for.
--
-- It is a named function and not a line inside that listener because this is
-- where the bug was: the listener used to clear the stashed original first,
-- and since the overworld usually hands back the *same* player object, what
-- applyLook then stashed was the mod's own renderer. One door and the real
-- trainer was gone. applyLook re-reads the original only when the entity
-- really changed, so the re-wear is safe now -- and the suite can say so.
--
-- The gate is "already wearing one, in a game and meant to be, or standing
-- on a choice". The middle clause keeps a look that failed to apply at
-- connect time retrying on the next map, which is what the transport check
-- here used to do alone. The last one is how an offline save gets dressed at
-- all: nothing is worn yet and no transport will ever open, but the choice
-- was made long ago and the first map is the first moment there is a player
-- object to put it on.
function M.refreshLook()
  if lookOwner == nil and not transport:isReady()
     and not M.explicitChoice() then
    return false
  end
  return M.applyLook(ctx.game)
end

function M.restoreLook()
  -- Only onto the entity the original was taken from: a player rebuilt
  -- since then is already wearing its own sheet, and writing a stale
  -- renderer over it would be this same bug pointing the other way.
  if lookOwner and originalLook ~= nil and playerEntity() == lookOwner then
    lookOwner.sprite = originalLook
  end
  originalLook, lookOwner = nil, nil
end

-- Put the player in whatever their standing choice says they are.
--
-- The one place that policy lives, so every path that could change the
-- answer -- leaving a game, picking a character, another save taking over --
-- asks the same question instead of each deciding for itself. Named, and
-- not a line inside the callers, because the rule is the interesting part
-- and the suite has to be able to state it.
--
-- The rule: a choice outlives the session that first wore it. Leaving used
-- to hand every player their trainer back, which meant a character chosen in
-- the creator existed only while connected -- you could not see your own
-- character in your own game. Now only a player with no choice at all is
-- undressed, and for them this is exactly the restore it replaced.
--
-- Answers true when a chosen look is on the player afterwards.
function M.syncLook()
  if not M.explicitChoice() then
    M.restoreLook()
    return false
  end
  return M.applyLook(ctx.game)
end

-- The character you are wearing right now, or nil.
--
-- Not the same question as M.spriteChoice(): the choice is what you picked
-- and keeps its answer forever, while this is only true between applyLook
-- and restoreLook -- that is, whenever a look is actually installed on the
-- player, which now includes a single-player game nobody ever connected in.
-- The battle and trainer-card pics below hang off *this* one, so a save
-- whose player never chose a character still draws exactly what vanilla
-- draws, and one that did carries the character everywhere the pics go.
function M.wornLook()
  if lookOwner == nil then return nil end
  return M.spriteChoice()
end

-- ------- connect / disconnect

function M.connect(a, b)
  local game = arg1(a, b) or ctx.game
  if not game then return false end
  if transport:isOpen() or M.isHosting() then
    ui:say("You're already in\na game.")
    return false
  end

  local address = M.joinAddress()
  local ok, err = transport:connect(address)
  if not ok then
    ui:say(tostring(err or "Couldn't connect."))
    return false
  end

  dialled, authSent = address, false
  M.sendHello(game)
  M.applyLook(game)
  return true
end

-- ------- hosting
--
-- Start a listener, then join it as an ordinary player over loopback. From
-- the moment the local net is attached, nothing downstream knows or cares
-- that this copy of the game is also the server: the host walks around,
-- chats, trades and battles through exactly the same client code a joining
-- player runs.
function M.host(a, b)
  local game = arg1(a, b) or ctx.game
  if not game then return false end
  if transport:isOpen() or M.isHosting() then
    ui:say("You're already in\na game.")
    return false
  end

  local limit = M.maxPlayers()
  -- The code goes in at start, so the hub is locked from its first accept
  -- rather than from whenever the host got round to it. HostServer refuses
  -- to open the port at all on a code that is missing or unusable, which is
  -- the right answer -- a game the host believes is locked and is not would
  -- be worse than one that did not start -- so its sentence is read out on
  -- screen like any other refusal rather than failing silently. The host
  -- screen mints a code before START is reachable, so a player only meets
  -- that sentence when the entropy pool could not produce one.
  local ok, err = server:start(Config.DEFAULT_PORT, limit, M.hostJoinCode())
  if not ok then
    ui:say(tostring(err or "Couldn't start hosting."))
    return false
  end

  local net, netErr = server:localNet()
  if not net then
    server:stop()
    ui:say(tostring(netErr or "Couldn't join your own game."))
    return false
  end

  transport:attach(net)
  dialled, authSent = nil, false
  M.sendHello(game)
  M.applyLook(game)
  return true
end

function M.stopHosting()
  if not M.isHosting() then return false end
  -- tear the local client down first, so the host leaves its own roster
  -- cleanly before the hub tells everyone else the game is over
  M.disconnect()
  server:stop("The host ended the game.")
  return true
end

-- The one hello, used by both paths -- a host and a joiner introduce
-- themselves identically, because to the hub they are the same thing.
function M.sendHello(game)
  local current = World.current()
  -- Read once and used twice on purpose: the ticket is filed under the name
  -- it was minted for, so the name claimed and the name the ticket is looked
  -- up by have to be the same string, not two calls that could disagree.
  local name = M.playerName(game)
  -- Read once and sent once, for the same reason the name above is: this is
  -- also the value spriteAcked starts at, and seeding it from a second call
  -- would be seeding it with an answer we did not actually send.
  --
  -- The hub stores what hello says and broadcasts nothing back for it, so
  -- this is the one write to spriteAcked that is not the hub's own word --
  -- and it is the hub's state all the same, because storing it is all the
  -- hub does with it. Without the seed the reconcile below would open every
  -- session by re-pushing a character the hub already has.
  local sprite = M.spriteChoice()
  spriteAcked, spriteClock = sprite, 0
  transport:send(Wire.HELLO, {
    proto = Config.PROTOCOL,
    name = name,
    -- "this name is mine, and here is the ticket you gave me" -- absent on a
    -- first visit, which is what makes the hub mint one
    rankToken = M.rankToken(dialled, name),
    -- who you are walking in as, and no longer the only chance to say it:
    -- mmo.sprite moves it mid-game (M.pushSprite), so this is the opening
    -- value rather than the whole of the answer
    sprite = sprite,
    profile = M.profile(game),
    map = current and current.mapId,
    x = current and current.x,
    y = current and current.y,
    facing = current and current.facing,
  })
end

function M.disconnect()
  -- Not a plain restore any more: the character belongs to the player, not
  -- to the session, so every way out of a game -- walking out, stopping a
  -- host, or the tick funnelling a dropped transport through here -- leaves
  -- it on. A player who never chose one still gets their trainer back,
  -- because for them syncLook *is* the restore.
  M.syncLook()
  sessions:endSession(nil)
  party:reset()
  coop:reset()
  ctx.avatars:clear()
  ctx.roster:reset()
  ctx.chat:clear()
  -- With the scrollback, and for the same reason: every toast this session
  -- put up is news about a hub this copy is no longer on, so leaving one
  -- floating over a single-player game would be the mod narrating a world
  -- that is gone.
  toast:clear()
  transport:close()
  lastSent =
    { map = nil, x = nil, y = nil, facing = nil, busy = nil, fast = nil }
  -- Cleared for the same reason lastSent is: what a hub is holding for us is
  -- a fact about one connection. Carrying it across would have the next
  -- session's reconcile weigh the choice against a hub that never heard it --
  -- silent when it should push, if the two happened to agree. The next hello
  -- seeds it again, so nil is only ever read while offline, where the tick
  -- that would read it does not run.
  spriteAcked, spriteClock = nil, 0
  -- Cleared with the rest of it, because "the last step was a fast one" is
  -- only true of a session: a player who sprinted or cycled, left, and
  -- rejoined standing still would otherwise advertise fast=true in their
  -- hello and go on doing so until they took a step to clear it.
  M.fastNow = false
  dialled, authSent = nil, false
  -- A rating belongs to the hub that keeps it, so leaving takes it off the
  -- screen rather than leaving a stale number on your own card in
  -- single-player.
  myPoints, ranking = Config.RANK_START, {}
  rankingAsked, rankingSeen = false, false
  rankedHere = true
  -- Cleared with the rating, and for a sharper reason: being an operator is
  -- a fact about one connection's credential, so carrying it out of that
  -- connection would let a code used once quietly grant powers on the next
  -- hub -- or in single-player -- until something happened to overwrite it.
  myAdmin = false
end

-- Leaving covers both shapes so callers never have to ask which they are:
-- a host stops the game for everyone, a guest just walks out.
function M.leave()
  if M.isHosting() then return M.stopHosting() end
  M.disconnect()
  return true
end

-- Another save has taken over the world.
--
-- Three steps, and the order is the whole of it. The session belongs to the
-- world that is going away, so it comes down first. The stashed original
-- belongs to *that* world's player entity, so it is dropped rather than
-- carried across -- restoreLook writes back only onto the entity it was
-- taken from, which makes a torn-down world a no-op and clears the stale
-- stash either way. Only then does the freshly loaded save get to say who it
-- is, which may be a different character, or nobody.
--
-- applyLook can come up empty here, because the new world often does not
-- exist yet when the event lands. That is not a failure worth reporting:
-- refreshLook wears the choice on the first map.entered instead.
function M.saveLoaded()
  M.leave()
  M.restoreLook()
  M.syncLook()
  -- "Once per session" for the unranked explanation meant once per
  -- *process*, so a player who loaded a different save was never told why a
  -- co-op trainer win paid nothing -- which is precisely the player who has
  -- not heard it. Reset with the save -- and a fresh file counts: NEW GAME
  -- routes through here too, and its player has heard nothing at all.
  CoopBattle.saidUnranked = nil
end

-- ------- outgoing chat

function M.say(a, b, c, d)
  local scope, text, to
  if a == M then scope, text, to = b, c, d else scope, text, to = a, b, c end
  if not transport:isReady() then return false end
  if not Wire.SCOPES[scope] then return false end
  -- The hub drops a party line from somebody with no party, which is right
  -- -- but the local echo below would still put it in the scrollback, so the
  -- player would watch their own message land and assume it went somewhere.
  if scope == "party" and not party:has() then
    ui:say("You're not in\na party.")
    return false
  end

  local clean = Wire.text(text, Config.MESSAGE_MAX)
  if not clean then
    ui:say("Nothing to say.")
    return false
  end

  transport:send(Wire.CHAT, { scope = scope, to = to, text = clean })

  -- Echoed locally rather than waiting for the hub to reflect it back: the
  -- player should see their own line the instant they send it, and the hub
  -- does not echo (which would double every message).
  local name = M.playerName(ctx.game)
  ctx.chat:push({
    name = name,
    scope = scope,
    text = clean,
    outgoing = true,
  })
  -- The same line in the corner, in the same breath and for the same reason:
  -- the scrollback is behind a menu, so a message that appears nowhere until
  -- somebody answers it reads as one that was never sent.  Your own name on
  -- your own toast, rather than a bare line, so that a conversation reads as
  -- a conversation on the one surface both halves of it appear on.
  toast:push(Toast.chatLine(name, clean))
  return true
end

-- ------- running

-- One-shot latch for the failure warn below, in the shape Avatars uses for
-- an unknown sprite.  A step's speed is asked for several times a second,
-- and everything that can make runSpeed throw -- an options table that no
-- longer answers, a moveCtx of an unexpected shape -- is a standing
-- condition rather than a blip, so an unlatched warn would say the same
-- sentence a few times a second for as long as the game is open.  Once is
-- the whole message; the fallback below keeps working either way.
local runSpeedWarned = false

-- What a step should cost in frames, and whether that is a sprint.
--
-- Declared out here rather than inside the wrap so the hot path can pcall it
-- by name and allocate nothing per step. The arithmetic is deliberately
-- relative: the engine hands us this game's walk speed, and dividing it is
-- the only way that stays true on a data pack that says a tile is not 16
-- frames. `frames` is frames-per-tile, so lower is faster.
--
-- Everything that is not a plain on-foot step falls through untouched. The
-- bike is excluded because it is already this fast and because held B is
-- taken there -- it is Cycling Road's brake -- and surfing because a sprint
-- across water is not a thing any of these games has.
--
-- "Untouched" is about the *speed*, not about the wire: a bike step still
-- goes out as a fast one, because it is one. The wrap below is what ORs the
-- two together, so this function stays the one answer to "how long does this
-- step take" and never has to say why.
local function runSpeed(frames, moveCtx)
  if mod.options:get("run") == false then return frames, false end
  if type(frames) ~= "number" then return frames, false end
  if not moveCtx or moveCtx.onBike or moveCtx.surfing then return frames, false end
  local input = moveCtx.input
  if not (input and input.isDown and input:isDown("b")) then
    return frames, false
  end
  return math.max(1, math.floor(frames / Config.RUN_DIVISOR)), true
end

-- ------- presence

local function presenceChanged(current, busy, fast)
  local mapId = current and current.mapId
  local x = current and current.x
  local y = current and current.y
  local facing = current and current.facing
  return lastSent.map ~= mapId or lastSent.x ~= x or lastSent.y ~= y
    or lastSent.facing ~= facing or lastSent.busy ~= busy
    -- Compared like the rest of them, defensively rather than because a
    -- known path needs it.  Every write to fastNow happens outside this
    -- function, in the movement.speed wrap, and that wrap only runs for a
    -- step the engine has committed -- a turn on the spot and a step into a
    -- wall are answered "turned"/"blocked" before the speed is ever asked
    -- for, so neither can flip the flag.  A committed step changes the cell
    -- too, so today the checks above would carry it; the field is compared
    -- anyway so that a future writer of fastNow cannot silently strand a
    -- pace change until the next move.
    or lastSent.fast ~= fast
end

local function pushPresence(force)
  if not transport:isReady() then return end
  local current = World.current()
  local busy = sessions:isBusy()
  local fast = M.fastNow and true or false
  if not force and not presenceChanged(current, busy, fast) then return end

  lastSent = {
    map = current and current.mapId,
    x = current and current.x,
    y = current and current.y,
    facing = current and current.facing,
    busy = busy,
    fast = fast,
  }
  transport:send(Wire.MOVE, {
    map = lastSent.map,
    x = lastSent.x,
    y = lastSent.y,
    facing = lastSent.facing,
    busy = busy,
    fast = fast,
  })
end

-- ------- inbound dispatch

local handlers = {}

-- The hub wants a join code before it will let anyone in.
--
-- It sends a nonce; the answer is an HMAC of that nonce keyed by the code,
-- so the code itself never crosses the wire -- a capture cannot be replayed
-- (the nonce is single-use) and cannot be turned back into the code. The
-- exact contract is mirrored by server/lib/auth.js: key is the normalised
-- code as ASCII, message is the nonce as its lowercase-hex *string*, and a
-- drift in either reaches the player as nothing but "wrong join code".
--
-- Every hub this mod ships now requires a code, and the join flow asks for
-- one before it dials, so in the ordinary case this arrives with an answer
-- already in hand and the player never sees it. What it still handles is
-- the case that made it: a stored code that is absent or wrong, and a
-- third-party hub that runs without one and never sends this at all.
handlers[Wire.CHALLENGE] = function(game, msg)
  -- the hub is a stranger's process like every other peer, so its framing
  -- is checked exactly as hard as a player's
  local nonce = Wire.hex(msg.nonce, Config.NONCE_HEX)
  if not nonce then
    mod.log:warn("the hub sent a challenge we cannot read; ignoring it -- if "
      .. "joining keeps failing, the hub is running a different build")
    return
  end

  local address = dialled
  local code = M.joinCode(address)
  if not code then
    -- Nothing to answer with. Hang up first: a hub gives the whole handshake
    -- ten seconds (Config.HANDSHAKE_TIMEOUT), measured from when the socket
    -- landed and not extended for the challenge -- both hosting paths, the
    -- one in src/Hub.lua and the one in server/lib/limits.js, hold to that
    -- same budget. Some of it is already spent by the time this arrives, and
    -- even six characters on a d-pad is not reliably under what is left, so
    -- holding the socket open only buys the player a connection that dies
    -- behind the screen they are still typing on.
    M.disconnect()
    ui:say("This game needs a\njoin code.", function()
      M.askJoinCode(game, address, address ~= nil)
    end)
    return
  end

  local response, why = Sha256.hmacHex(code, nonce)
  if not response then
    -- `why` names the argument, never its value: the code does not go to the
    -- log, here or anywhere else
    mod.log:warn("could not answer the hub's challenge (%s) -- re-enter the "
      .. "code from START > MMO > JOIN GAME", tostring(why))
    M.disconnect()
    ui:say("Couldn't answer\nthis game's code.")
    return
  end

  authSent = true
  transport:send(Wire.AUTH, { response = response })
end

handlers[Wire.WELCOME] = function(game, msg)
  local id = Wire.id(msg.id)
  if not id then
    transport:fail("the hub sent a malformed welcome")
    return
  end
  ctx.roster:reset()
  ctx.roster:setSelf(id)
  -- A party never survives a connection, so it starts empty -- but the party
  -- has to be told which id is ours, because it is the one list that
  -- includes us and the roster deliberately does not.
  party:reset()
  party:setSelf(id)
  coop:reset()
  -- your own rating, which cannot come from the roster: it has no entry for
  -- you, by design
  myPoints = Wire.points(msg.points)
  ranking, rankingAsked, rankingSeen = {}, false, false
  -- A hub that just claimed this name for us sends the ticket once and never
  -- again, so this is the only chance to keep it. Stored against the address
  -- we dialled and the name we claimed -- the same two halves the next hello
  -- reads it back by.
  local granted = Wire.token(msg.rankToken)
  if granted then M.setRankToken(dialled, granted, M.playerName(game)) end
  -- Absent means an older hub that does not score at all, which is not the
  -- same as being refused a name; treat silence as ranked and let the empty
  -- leaderboard speak for itself.
  rankedHere = msg.ranked ~= false
  -- Kept exactly as sent and compared rather than coerced: only a literal
  -- true is an operator. Absent -- an older hub, or a plain player code --
  -- is false, and so is anything else that arrives in the field.
  myAdmin = msg.admin == true
  for _, raw in ipairs(msg.players or {}) do
    ctx.roster:put(Wire.presence(raw))
  end
  transport:markReady()
  pushPresence(true)
  -- Remember the hub, now that it has actually let us in.
  --
  -- Here and not in M.connect, because a dial is not a connection: recording
  -- there would fill the SERVERS list with addresses that refused us, timed
  -- out, or wanted a code we did not have. And after markReady rather than
  -- before, because until then the welcome could still turn out to be
  -- malformed and this connection never happened.
  --
  -- Only a dialled address: hosting has none -- the local net is in-process --
  -- and a row that reconnects you to yourself is not a hub anybody wants
  -- listed.
  --
  -- A code goes on the row only when this connection actually answered a
  -- challenge with one, which is what authSent records. M.joinCode falls back
  -- to the standing JOIN CODE option when a hub has no code of its own, so
  -- recording its answer unconditionally would stamp that option onto every
  -- open hub the player ever joins -- and the row's copy is then pinned under
  -- the per-hub key, where it outranks the option it came from. A hub that
  -- never asked for a code gets nil, and the store leaves entry.code alone on
  -- nil, so a code the player typed themselves still survives.
  --
  -- Wrapped, and the whole point of the wrapping is that this is bookkeeping
  -- on the one path every single connection takes. The store refuses rather
  -- than raises, so nothing here is expected to throw -- but a save folder
  -- this copy cannot write must never be the reason a player is not in the
  -- game they just joined.
  if dialled then
    local kept, why = pcall(function()
      servers:record(dialled, authSent and M.joinCode(dialled) or nil)
    end)
    if not kept then
      mod.log:warn("could not add %s to the server list (%s) -- it will not "
        .. "appear under START > MMO > SERVERS; rejoin it with JOIN GAME",
        tostring(dialled), tostring(why))
    end
  end
  -- The hub gets the first word: its message of the day goes into the
  -- scrollback above the connection's own status line, so the first thing
  -- read on arrival is what the operator wrote rather than a count.
  --
  -- Pushed with no `from` on purpose: the hub is not a player.  It stands on
  -- no map, owns no avatar and has no roster row, so anything that draws
  -- against a sender id has nobody to draw it against, and the honest place
  -- for what it says is the log.  A hub with nothing to say, or one too old
  -- to have the field at all, sends nothing and this does nothing.
  local motd = Wire.text(msg.motd, Config.MOTD_MAX)
  if motd and motd ~= "" then
    ctx.chat:push({ name = "HUB", scope = "global", text = motd })
  end
  -- Deliberately not a text box. ui:say pushes a modal that sits over the
  -- world until someone presses A, and a routine status line is not worth
  -- interrupting play for -- the first real run left "Connected." covering
  -- the bottom third of the screen for the whole session. The player count
  -- is already on the MMO menu's PLAYERS row, which is where someone who
  -- cares will look. Errors still get a box; this does not.
  mod.log:info("connected -- %d other player(s) on", ctx.roster.count)
end

-- Somebody arrived.  Announced in the corner as well as recorded, because
-- "who else is here" is otherwise a menu the player has to think to open --
-- and the moment a friend walks in is precisely the moment nobody is looking
-- at a menu.
--
-- The roster's own answer decides it rather than a second check of our own:
-- Roster:put drops our own presence, so a welcome echo of ourselves is not
-- somebody arriving and is not announced as one.
handlers[Wire.JOIN] = function(_, msg)
  local presence = Wire.presence(msg.player)
  if not presence then return end
  if not ctx.roster:put(presence) then return end
  toast:push(Toast.joinLine(presence.name))
end

handlers[Wire.PART] = function(_, msg)
  local id = Wire.id(msg.id)
  if not id then return end
  -- Removed first and read from what came back, because the name only exists
  -- while the row does: an id on its own is not a sentence anybody can read,
  -- and asking the roster after the row is gone would answer nil every time.
  -- A player nobody had a row for -- one who left before their join was
  -- processed, or our own id, which the roster never stores -- simply is not
  -- announced, rather than being announced as somebody with no name.
  local gone = ctx.roster:remove(id)
  if gone then toast:push(Toast.partLine(gone.name)) end
  ctx.avatars:despawn(id)
  -- An invite in flight to somebody who just left will never be answered,
  -- and a client that kept waiting for that answer could never invite
  -- anybody again.
  party:onPeerGone(id)
  -- Same shape, one feature along: an offer from somebody who is gone can
  -- never be joined, and a four-way ask is short a player.
  coop:onPeerGone(id)
  -- And the same again for a trade/battle ask: without this the asker stays
  -- busy forever after the person they asked disconnects, because the hub
  -- clears pendingTo in silence and never sends a decline.
  sessions:onPeerGone(id)
end

handlers[Wire.MOVE] = function(_, msg)
  local id = Wire.id(msg.id)
  if not id then return end
  local map = Wire.mapId(msg.map)
  local x, y = Wire.int(msg.x, 0, 4096), Wire.int(msg.y, 0, 4096)
  local facing = Wire.facing(msg.facing)
  ctx.roster:setBusy(id, msg.busy)
  ctx.roster:setParty(id, msg.party)
  -- Coerced here rather than trusted: this is the raw message, and the
  -- roster stores what it is given.  Strict, the way Wire.presence and both
  -- hubs are -- only a literal true is a fast step, so a client sending 0 or
  -- "" is read the same here as it is everywhere else on the wire.
  local fast = msg.fast == true
  if map and x and y then
    ctx.roster:move(id, map, x, y, facing, fast)
  else
    -- no cell: the player is in a battle or a menu, so they leave the world
    -- without leaving the roster
    ctx.roster:move(id, nil, nil, nil, facing, fast)
    ctx.avatars:despawn(id)
  end
end

handlers[Wire.CHAT] = function(_, msg)
  local from = Wire.id(msg.from)
  local name = Wire.name(msg.name)
  local text = Wire.text(msg.text, Config.MESSAGE_MAX)
  local scope = Wire.SCOPES[msg.scope] and msg.scope or nil
  if not (name and text and scope) then return end
  ctx.chat:push({ from = from, name = name, scope = scope, text = text })
  -- ...and in the corner, where it is read without opening anything.  Every
  -- scope, the whisper included -- which is the one a bubble could never
  -- carry, because a bubble is drawn over the sender's head in a world other
  -- people are standing in.  A toast is drawn in this player's own corner and
  -- nowhere else, so a private line stays private.
  toast:push(Toast.chatLine(name, text))
end

handlers[Wire.PARTY_INVITE] = function(game, msg) party:onInvite(game, msg) end
handlers[Wire.PARTY_DECLINE] = function(_, msg) party:onDecline(msg) end
handlers[Wire.PARTY] = function(_, msg) party:onParty(msg) end

-- The party ending takes the co-op state with it, and in that order: an offer
-- outliving the party it was made inside is an offer with nobody left who
-- could accept it.
handlers[Wire.PARTY_END] = function(_, msg)
  party:onEnd(msg)
  coop:onPartyEnd()
end

-- What the person you are travelling with just did in a fight.
--
-- Straight to the corner and nowhere else.  It is news about somebody who is
-- not on this screen -- they are in a battle of their own, which is exactly
-- why their avatar is not standing anywhere to draw it over -- and it is not
-- worth a box: a partner who fights ten trainers on a route would otherwise
-- hand their friend ten modals to dismiss.
--
-- The hub already fanned this to the party and left the fighter out, so
-- arriving at all is the whole of the audience check.  The sanitiser is the
-- gate on the words: an event whose kind this build has never heard of, or
-- one missing the field its sentence needs, draws nothing rather than a line
-- that stops half way.
handlers[Wire.PARTY_EVENT] = function(_, msg)
  local event = Wire.partyEvent(msg)
  if not event then return end
  toast:push(Toast.partyLine(event))
end

handlers[Wire.COOP_OFFER] = function(_, msg) coop:onOffer(msg) end
handlers[Wire.COOP_OFFER_END] = function(_, msg) coop:onOfferEnd(msg) end
handlers[Wire.COOP_JOINED] = function(game, msg) coop:onJoined(game, msg) end
handlers[Wire.COOP_ASK] = function(game, msg) coop:onAsk(game, msg) end
handlers[Wire.COOP_DECLINE] = function(_, msg) coop:onDecline(msg) end
handlers[Wire.COOP_BATTLE] = function(game, msg) coop:onBattle(game, msg) end
-- Battle traffic from one of the other three. Coop keeps the party exchange
-- and hands everything else to the live battle's inbox.
handlers[Wire.COOP_MSG] = function(game, msg) coop:onMessage(game, msg) end

-- A rating moved -- ours or somebody else's.  One message covers both, so a
-- battle's two halves land on every screen in the same frame.
handlers[Wire.RANK] = function(_, msg)
  local id = Wire.id(msg.id)
  if not id then return end
  local points = Wire.points(msg.points)
  if ctx.roster:isSelf(id) then
    myPoints = points
  else
    ctx.roster:setPoints(id, points)
  end
end

-- Somebody changed character in the middle of the game.
--
-- Broadcast with no exception, the way a rating is, so the player it is about
-- hears it too -- and that copy is not a curiosity, it is the acknowledgement.
-- Nothing else on the wire says "the hub took your change": a push that hit
-- the half-second gate is refused in silence, so the one thing that tells the
-- two apart is whether this message came back. The self branch records it and
-- stops there. There is nothing to draw -- our own copy is already wearing
-- the new character, because setSpriteChoice puts it on before it tells the
-- hub -- and nothing to spawn, because our own presence is not in our own
-- roster.
--
-- The refresh is the part that is not optional. An avatar reads its sprite
-- once, when it is spawned, and neither advance nor sync ever looks again --
-- so writing the roster alone would move every screen that draws from the
-- roster and leave the character walking around the overworld as whoever they
-- used to be. Avatars:refresh is a no-op unless that player's avatar is
-- actually up, so a player standing on another map costs nothing here and
-- simply spawns as their new self when they come into view.
handlers[Wire.SPRITE] = function(_, msg)
  local id = Wire.id(msg.id)
  if not id then return end
  -- an identifier, so the identifier sanitiser -- Wire.text would eat the
  -- underscore and quietly turn everyone into RED; see Wire.spriteId
  local sprite = Wire.spriteId(msg.sprite)
  if not sprite then return end
  if ctx.roster:isSelf(id) then
    -- the hub's word on what it is holding for us, which is what the tick
    -- reconciles the choice against
    spriteAcked = sprite
    return
  end
  local player = ctx.roster:setSprite(id, sprite)
  if player then ctx.avatars:refresh(player) end
end

handlers[Wire.RANKING] = function(_, msg)
  ranking = Wire.ranking(msg.entries)
  rankingAsked, rankingSeen = true, true
end

handlers[Wire.REQUEST] = function(game, msg) sessions:onRequest(game, msg) end
handlers[Wire.DECLINE] = function(_, msg) sessions:onDecline(msg) end
handlers[Wire.REQUEST_CANCEL] = function(_, msg) sessions:onCancel(msg) end
handlers[Wire.SESSION] = function(game, msg) sessions:onSession(game, msg) end
handlers[Wire.RELAY] = function(_, msg) sessions:onRelay(msg) end

handlers[Wire.SESSION_END] = function(_, msg)
  sessions:onSessionEnd(msg and msg.reason)
end

handlers[Wire.ERROR] = function(game, msg)
  local text = Wire.text(msg.message, 120) or "The hub refused the connection."
  -- A refusal that lands after we answered a challenge and before we were
  -- welcomed is the wrong join code, whatever sentence the hub chose to say
  -- it in -- so the hub's words are shown, and then the code screen, rather
  -- than a refusal with nowhere to go from. The stored code is kept: a typo
  -- is likelier than a rotated code, and clearing it would cost the player
  -- the one they had.
  local wrongCode = authSent and not transport:isReady()
  local address = dialled
  transport:fail(text)
  if wrongCode then
    ui:say(text, function() M.askJoinCode(game, address, address ~= nil) end)
  else
    ui:say(text)
  end
end

-- ------- the tick

-- Feeding the entropy pool.
--
-- The pool is only worth what goes into it, and the cheapest genuinely
-- varying material this process can see is right here: how long the last
-- step took, where the CPU clock stands and how far it moved, and how big
-- the heap is -- plus love.math.random() in game, which is a seeded xorshift
-- and worth little on its own but whose position in its own sequence is not
-- something an outsider knows.
--
-- This runs on every fixed step whether or not the player is connected, so
-- by the time anyone reaches the HOST screen the pool has absorbed thousands
-- of samples. It therefore obeys the hot-path rule: four numbers written
-- into a table the pool allocated once, no strings, no garbage. The hashing
-- happens on the pool's own schedule (one fold per 24 stirs), not here.
--
-- Nothing below can raise: every source is looked up before it is called and
-- a missing one is simply not stirred.
local lastClock = 0
local loveRandom = nil
local loveChecked = false

local function stirEntropy(dt)
  if not loveChecked then
    loveChecked = true
    if type(love) == "table" and type(love.math) == "table"
       and type(love.math.random) == "function" then
      loveRandom = love.math.random
    end
  end
  local clock = (os and os.clock) and os.clock() or 0
  local delta = clock - lastClock
  lastClock = clock
  -- The fourth slot is love.math.random() where there is a LOVE to ask, and
  -- the step-to-step clock delta where there is not (the headless suite):
  -- the delta is derivable from consecutive clock samples the pool already
  -- has, so nothing is lost by trading it for the one that is not.
  Hub.Entropy.shared:stir(dt, clock, collectgarbage("count"),
    loveRandom and loveRandom() or delta)
end

local function tick(game, dt)
  ctx.game = game
  dt = dt or 0
  stirEntropy(dt)

  -- The server pumps first. Reading sockets and running the hub is what
  -- fills the host's own loopback inbox, so doing it after the client poll
  -- would put every hosted message one tick behind.
  if server.running then server:update(dt) end

  if not transport:isOpen() then return end

  for _, msg in ipairs(transport:update(dt)) do
    local handler = handlers[msg.type]
    if handler then handler(game, msg) end
  end

  -- A failure surfaced inside update (timeout, socket error, the hub
  -- hanging up) is a leave the player did not choose, so it tears down
  -- exactly what an asked-for leave does -- their own trainer back
  -- included. Tearing down only part of it left a dropped player standing
  -- in single-player wearing whoever they picked for the hub, and a trade
  -- session still open on a socket that is gone.
  if not transport:isOpen() then
    -- M.disconnect(), not a partial teardown. Both sides of the merge were
    -- fixing the same shape of bug -- a dropped player left holding state a
    -- deliberate LEAVE would have cleared -- and main's answer subsumes the
    -- party branch's: the party reset this used to do inline lives inside
    -- disconnect() with the roster, the avatars, the session and the
    -- restored look, so there is now one teardown and no second list to
    -- keep in step with it.
    local reason = transport.error
    M.disconnect()
    if reason then ui:say(tostring(reason)) end
    return
  end

  if not transport:isReady() then return end

  -- Ageing the corner, where the bubbles used to be aged.  Toasts expire on
  -- the fixed step rather than on drawn frames, so a line stays up for the
  -- five seconds Config says and not for however many frames the machine
  -- managed in them.
  toast:update(dt)
  sessions:update(game, dt)
  coop:update(dt)

  presenceClock = presenceClock + dt
  if presenceClock >= Config.PRESENCE_INTERVAL then
    presenceClock = 0
    pushPresence(false)
  end

  -- The character, reconciled rather than resent. Shaped like the presence
  -- block above it -- accumulate, cross, reset -- and quiet in exactly the
  -- same way: the send happens only when the hub's answer and the choice
  -- actually disagree, which is never, apart from the seconds after a push
  -- the gate refused or an option row nobody told the hub about. Two numbers
  -- and a string compare on the ticks in between; no closure, no table.
  spriteClock = spriteClock + dt
  if spriteClock >= SPRITE_RETRY then
    spriteClock = 0
    if M.spriteChoice() ~= spriteAcked then M.pushSprite() end
  end

  ctx.avatars:sync(ctx.roster, World.current())
end

-- ------- install

function M.install()
  -- First, because everything that reads the character catalog reads it
  -- after this: the options row built two lines down offers these ids, and
  -- the CHARACTER screen lists whatever the catalog holds when it opens.
  Cast.install()

  local spriteChoices = {}
  for _, row in ipairs(Config.SPRITES) do
    spriteChoices[#spriteChoices + 1] = { row[1], row[2] }
  end

  mod.options:define({
    -- The cap the host picks. min/max make the row itself refuse anything
    -- outside 2..64, so the clamp in Config is a backstop against a hand
    -- edited options file rather than the only guard.
    { key = "maxplayers", label = "MAX PLAYERS", type = "number",
      default = Config.DEFAULT_PLAYERS,
      min = Config.MIN_PLAYERS, max = Config.MAX_PLAYERS, step = 1 },
    { key = "hub", label = "JOIN", type = "text", default = Config.DEFAULT_HUB },
    -- The standing join code, so it can be seen and changed deliberately
    -- rather than only when a hub happens to ask for it -- and, since the
    -- MMO menu no longer carries a JOIN CODE row of its own, the only place
    -- a code is set without dialling something. A code typed for a
    -- particular hub is stored against that hub (see M.joinCode); this row
    -- is the fallback, and the one a player who only ever plays on one hub
    -- ever needs. maxLen so the manager's own naming screen -- which
    -- defaults to seven -- takes a whole code plus whatever punctuation a
    -- pasted one brings, rather than cutting it short.
    { key = "code", label = "JOIN CODE", type = "text", default = "",
      maxLen = Config.CODE_ENTRY_MAX },
    { key = "sprite", label = "MY SPRITE", type = "choice",
      default = Config.DEFAULT_SPRITE, choices = spriteChoices },
    -- Holding B to run.  On by default because it is the reason the feature
    -- exists, and a row at all because B already means "cancel" everywhere
    -- else -- a player who finds their walk unexpectedly fast should have
    -- somewhere to turn it off without uninstalling the mod.
    { key = "run", label = "B TO RUN", type = "toggle", default = true },
  })

  ui:install()

  -- One game-logic tick.  This runs before queued button edges are
  -- promoted, which is the documented place for a tool that has to act once
  -- per fixed step rather than once per drawn frame.
  mod.hooks:wrap("input.step", function(next, game, dt)
    local ok, err = pcall(tick, game, dt)
    if not ok then
      mod.log:warn("multiplayer tick failed (%s); leaving the game to keep "
        .. "playing", tostring(err))
      pcall(M.leave)
    end
    return next(game, dt)
  end)

  -- Co-op against an NPC: the wait/alone choice, in front of any trainer.
  --
  -- **Watched rather than intercepted, and that is what makes it reach every
  -- trainer.** An earlier version wrapped `script.command` and yielded the
  -- script runner's coroutine, which worked -- and only for script-driven
  -- battles. The other way a trainer starts, walking into one in the
  -- overworld, goes through `OverworldState:engageTrainer`, which emits an
  -- event and cannot be cancelled; there is no seam there to hold at.
  --
  -- Both paths end in the same place: `game.stack:push(battle)`. So this
  -- listens for the push instead of trying to prevent it, and puts the prompt
  -- **on top of** the battle that just arrived. A StateStack only updates its
  -- top, so the battle underneath is frozen and completely untouched -- which
  -- is why BATTLE ALONE costs nothing but closing a menu, and why a player who
  -- is not in a party never notices any of this happened.
  --
  -- src/Coop.lua's onTrainerBattle is where the two answers diverge, and its
  -- header explains what the co-op one does with the battle it took.
  mod.events:on("screen.pushed", function(payload)
    local state = payload and payload.state
    if not (state and state.kind == "trainer") then return end
    if not transport:isReady() then return end
    local current = World.current()
    local ok, err = pcall(function()
      coop:onTrainerBattle(ctx.game, state, current and current.mapId)
    end)
    if not ok then
      mod.log:warn("the co-op prompt failed (%s); this trainer is fought the "
        .. "ordinary way -- the battle itself is unaffected", tostring(err))
    end
  end)

  -- Palette zones for the 2-on-2 screen.
  --
  -- **A state cannot supply its own.** The colourising display modes take their
  -- zones from the engine, and Game.lua offers exactly one seam to change them
  -- -- this hook. Without it a co-op battle inherits whatever the current mode
  -- decided for a surface it knows nothing about, which is why the same battle
  -- came out in colour on one client and pink monochrome on another: the two
  -- players simply had different display modes.
  --
  -- The answer is the true-colour opt-out WideBattle takes for the same
  -- reason. Every pixel on this screen is already palette-correct -- the
  -- pictures come out of the engine's cache with their species palette applied
  -- and the boxes and glyphs are the engine's own -- so there is nothing left
  -- to remap, and remapping it anyway is what broke it.
  mod.hooks:wrap("render.zones", function(next, game, zones)
    local out = next(game, zones)
    local top = game and game.stack and game.stack:top()
    if top and top.sim and top.zones then
      local ok, mine = pcall(top.zones, top)
      if ok and mine then return mine end
    end
    return out
  end)

  -- One committed step's speed.  The engine asks once per step, never per
  -- frame, and floors whatever comes back to at least 1.
  --
  -- Not gated on being connected: running is a movement feature that the
  -- network happens to report, not a multiplayer one, so it works the same
  -- in a single-player game with the hub switched off. What crosses the wire
  -- is only the flag recorded here.
  --
  -- The flag is "this step was fast", not "B was held": a bike step is fast
  -- without a sprint and without this wrap changing its speed at all, so it
  -- is ORed in below. Reading onBike out here rather than inside runSpeed is
  -- what keeps it true of the step whatever runSpeed decided -- including
  -- the failure branch, where the pace is still known even though the speed
  -- was not -- and the type test is what stops a moveCtx of an unexpected
  -- shape turning a field read into a throw of its own.
  mod.hooks:wrap("movement.speed", function(next, frames, moveCtx)
    local onBike = type(moveCtx) == "table" and moveCtx.onBike == true
    local ok, speed, sprint = pcall(runSpeed, frames, moveCtx)
    if not ok then
      -- pcall has put the error where the speed would have been. Whatever
      -- went wrong, the step still has to happen at *some* speed, and the
      -- honest one is the speed we were handed.
      if not runSpeedWarned then
        runSpeedWarned = true
        mod.log:warn("could not work out a running speed (%s); walking this "
          .. "step -- turn B TO RUN off under START > OPTIONS if it repeats",
          tostring(speed))
      end
      M.fastNow = onBike
      return next(frames, moveCtx)
    end
    M.fastNow = sprint == true or onBike
    return next(speed, moveCtx)
  end)

  -- The two things this mod draws over a finished frame: the nameplates that
  -- annotate the world, and the toasts that annotate the session.
  --
  -- Neither is behind an option any more.  A nameplate only appears when
  -- another player is standing in front of you, and a toast only when
  -- something happened -- so the switch that used to gate them was a switch
  -- for turning off the only evidence that anyone else is in the game.
  --
  -- Toasts last, so a line the player is meant to read is never underneath a
  -- nameplate: they share the top-left corner in the fallback layout, and the
  -- transient one has to win.
  mod.hooks:wrap("render.hud", function(next, game, viewport)
    local result = next(game, viewport)
    overlay:draw(game, viewport)
    toast:draw(viewport)
    return result
  end)

  -- The rest of the character, for the three screens the sprite catalog does
  -- not reach: the battle back pic, the trainer card and Oak's intro all ask
  -- Sprites.playerPath for a pic, and this hook is the last word on what it
  -- answers. Only while you are wearing one of the mod's own characters --
  -- Cast.pic returns nil for every vanilla id, so picking COOLTRAINER still
  -- fights as Red, exactly as it always has.
  --
  -- Decorating after next() rather than instead of it: a mod that replaced
  -- the pic for a reason of its own still runs, and still wins whenever this
  -- player is not wearing a NIRE.
  mod.hooks:wrap("player.sprite", function(next, path, ctx)
    local drawn = next(path, ctx)
    local mine = Cast.pic(M.wornLook(), ctx and ctx.side)
    return mine or drawn
  end)

  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" then return out end
    return mod.ui.insertBefore(out, "SAVE", {
      label = "MMO",
      onSelect = function() mod.ui.push(game, Ui.SCREEN.MAIN) end,
    })
  end)

  -- A warp is the one movement the tile-by-tile presence stream cannot
  -- describe, so it is announced the moment it lands instead of waiting for
  -- the next interval.
  mod.events:on("player.warped", function() pushPresence(true) end)
  mod.events:on("map.entered", function()
    pushPresence(true)
    M.refreshLook()
  end)

  -- Facing a remote player and pressing A opens the same menu the roster
  -- does.  The engine's talkTo has already run by this point and found
  -- nothing to say (these NPCs carry no text), so this adds the interaction
  -- rather than replacing one.
  mod.events:on("world.interacted", function(payload)
    -- An A-press is a human deciding to press A, which is the least
    -- predictable timing this process ever sees; it goes into the pool
    -- before anything else here can return early.
    stirEntropy(0)
    if not (payload and payload.kind == "npc") then return end
    if not transport:isReady() then return end
    local player = ctx.roster:at(payload.mapId, payload.x, payload.y)
    if player and ctx.game then
      mod.ui.push(ctx.game, Ui.SCREEN.ACTIONS, { playerId = player.id })
    end
  end)

  -- A ranked battle just ended, so tell the hub how it went.
  --
  -- The engine's own event, carrying the state that finished and the result
  -- its simulation reached -- so what is reported is what the game decided,
  -- not what this mod thought was happening. Sessions matches the state
  -- against the one it handed over, so a wild encounter or a cable-club link
  -- fought while connected reports nothing.
  --
  -- The same event carries the second half of this, and the two are kept in
  -- one listener rather than two so that the order is stated rather than left
  -- to registration: the ranked report claims the battle from Sessions, which
  -- is what spends it, and the party line below reads the battle without
  -- claiming anything -- which is why a link battle is ruled out by name in
  -- there rather than by whether a claim succeeded.
  mod.events:on("battle.ended", function(payload)
    if not (payload and payload.battle) then return end
    if not transport:isReady() then return end
    M.reportBattle(payload.battle, payload.result)
    M.narrateBattle(payload.battle, payload.result)
  end)

  -- A capture, told from the catch rather than from the battle that ended.
  --
  -- This is the event that knows what was caught; battle.ended's "caught"
  -- result says only that the battle stopped that way, and by then the
  -- interesting half is a nickname prompt away from being renamed. One
  -- capture is one line on a partner's screen, which is why narrateBattle
  -- answers to nothing but a win and a loss.
  mod.events:on("pokemon.caught", function(payload)
    if not transport:isReady() then return end
    M.narrateCatch(payload)
  end)

  -- Leaving to the title screen or loading another save must not leave a
  -- stale roster pointing at a world that is gone -- and if this copy was
  -- hosting, the listener has to come down with it rather than serving a
  -- world nobody is standing in. The character goes with the save too: the
  -- one being loaded may have chosen somebody else, or nobody.
  mod.events:on("save.loaded", function() M.saveLoaded() end)

  -- NEW GAME needs the very same resync, and it does not announce itself the
  -- same way: starting a fresh file emits save.created, never save.loaded, so
  -- listening for one alone leaves the other world half torn down. It matters
  -- here because the overworld keeps *one* player entity for the life of the
  -- process -- setMap only builds a new one when it has none -- so a stash
  -- taken before QUIT is still standing after the title screen, and the mod's
  -- own renderer still on the player. The fresh save has chosen nobody, and
  -- dropping the stash is what lets that non-choice be honoured instead of
  -- refreshLook re-wearing the last game's character on the first map.
  mod.events:on("save.created", function() M.saveLoaded() end)

  mod.exports.isConnected = M.isConnected
  mod.exports.isHosting = M.isHosting
  -- nil unless this copy is hosting; a mod that wants to show the address
  -- somewhere of its own should not have to reach into HostServer for it
  mod.exports.hostAddress = function() return M.isHosting() and server:address() end
  -- The hubs this copy has been welcomed by, in the order SERVERS draws them.
  -- The rows and not the store, so nothing outside this mod can rename or
  -- evict what the player collected -- and so the end-to-end driver can assert
  -- that connecting actually recorded a hub, which is otherwise only visible
  -- by opening a menu.
  mod.exports.servers = function() return servers:list() end
  mod.exports.players = function() return ctx.roster:sorted() end
  -- Who you are travelling with, you included, in the order the hub listed
  -- them -- empty when you are not in a party. The end-to-end driver reads
  -- this to tell "the invite was accepted" from "the box appeared".
  mod.exports.party = function() return party:list() end
  -- Co-op, as the end-to-end driver has to be able to read it: whether this
  -- client is standing at a fight waiting, what its partner is offering, and
  -- the plan the last agreement produced. Three separate answers because the
  -- three failures they catch are separate -- an offer that was never sent, an
  -- offer that arrived and was never shown, and an agreement that was reached
  -- and never handed over.
  mod.exports.coopWaiting = function()
    local waiting = coop.waiting
    if not waiting then return nil end
    return { battle = waiting.battle, label = waiting.label, map = waiting.map }
  end
  mod.exports.coopOffer = function()
    local offer = coop:pendingOffer()
    if not offer then return nil end
    return {
      from = offer.from, name = offer.name,
      battle = offer.battle, label = offer.label,
    }
  end
  mod.exports.coopPlan = function() return coop.lastPlan end
  -- The four-way PARTY BATTLE ask, while it is in flight.
  --
  -- One player asks and the other three are put a question; the asker is
  -- never asked. Without this there is no way for a test to tell "the ask
  -- reached all three" from "the ask reached nobody and the battle started
  -- for an unrelated reason", nor to see a refusal clear it -- both of which
  -- are the whole of the four-way handshake.
  mod.exports.coopAsk = function()
    local ask = coop.ask
    if not ask then return nil end
    return { role = ask.role, name = ask.name, side = ask.side }
  end
  -- Whether the 2-on-2 screen ever failed to draw.
  --
  -- draw() is guarded so a broken renderer cannot stop the game, and that
  -- guard is exactly why this export has to exist: without it a layout bug
  -- degrades to one log line and a blank battle, and an end-to-end run sails
  -- past it green. That is precisely what happened -- a dangling PANEL_POS
  -- drew nothing for a whole battle and the run never said so.
  -- How the last co-op battle held together on the wire: turns missed, and
  -- turns that arrived but left this copy disagreeing with the host. Both
  -- should be zero on a healthy connection, and both are silent by design --
  -- the battle recovers rather than stopping -- so without an export nothing
  -- could ever assert they did not happen.
  mod.exports.coopSync = function()
    local state = coop.state
    return {
      gaps = (state and state.gaps) or 0,
      desyncs = (state and state.desyncs) or 0,
      resyncs = (state and state.resyncs) or 0,
    }
  end
  mod.exports.coopDrawFailed = function()
    return coop.state ~= nil and coop.state.drawFailed or false
  end
  mod.exports.say = function(scope, text, to) return M.say(scope, text, to) end
  -- ranked PVP: this player's points, and the hub's top ten as last asked
  -- for. A mod that wants a leaderboard of its own reads these rather than
  -- inventing a second scoring system.
  mod.exports.points = function() return myPoints end
  mod.exports.isRanked = function() return rankedHere end
  mod.exports.ranking = function() return ranking end
  -- Whether the hub this copy is on treats it as an operator's connection.
  -- False offline, false on every hub that was joined with a player code --
  -- a mod building an operator feature gates on this rather than on a list
  -- of names it keeps itself.
  mod.exports.isAdmin = function() return myAdmin == true end
  mod.exports.requestRanking = function() return M.requestRanking() end
  -- newest last, same order the chat screen scrolls
  mod.exports.chat = function() return ctx.chat:recent() end
  -- Where each remote player is according to the roster, and where their
  -- avatar actually stands. The two diverging is the signature of the
  -- avatar layer falling behind the network, which is invisible from the
  -- roster alone -- the end-to-end driver reads this to tell the two apart.
  mod.exports.traceAvatars = function(on) Avatars.TRACE = on and true or false end
  mod.exports.overlayState = function() return overlay:state() end
  -- What is in the corner right now, and what the last draw of it decided.
  --
  -- The queue is the only record a toast leaves: it is not a screen anything
  -- can be pushed onto and it is gone five seconds later, so without this the
  -- one way to assert that a chat line, an arrival or a partner's battle
  -- actually reached the player would be reading pixels off a screenshot.
  -- A copy of the lines, never the queue itself -- a reader that held the
  -- live list could age or empty it by accident.
  mod.exports.toasts = function() return ctx.toast:state() end
  -- Whether a trade/battle ask is sitting unanswered on this client, and
  -- whether a fight is on screen (or a co-op handoff is in flight). The
  -- invite-refuse e2e reads both: a request that arrived mid-fight must
  -- leave neither an incoming prompt nor a held ask.
  mod.exports.hasIncomingRequest = function()
    return sessions.incoming ~= nil
  end
  mod.exports.isFighting = function()
    return sessions:inFight(ctx.game)
  end
  mod.exports.isSessionBusy = function()
    return sessions:isBusy()
  end
  -- what this player looks like in their own game, for tests and for a mod
  -- that wants to know
  mod.exports.myLook = function() return M.spriteChoice() end
  -- What you are wearing rather than what you picked -- nil until a look is
  -- actually on the player, which happens offline too once a character has
  -- been chosen. The end-to-end driver reads this to tell "the character was
  -- chosen" from "the character is actually being worn", which is the
  -- difference the battle and trainer-card pics hang off.
  mod.exports.wornLook = function() return M.wornLook() end
  mod.exports.avatarState = function()
    local out = {}
    for _, player in ipairs(ctx.roster:sorted()) do
      local ax, ay = ctx.avatars:cellOf(player.id)
      out[#out + 1] = {
        id = player.id, name = player.name, map = player.map,
        rosterX = player.x, rosterY = player.y,
        avatarX = ax, avatarY = ay,
        spawned = ctx.avatars.spawned[player.id] ~= nil,
        walking = ctx.avatars:isWalking(player.id),
        -- the roster's word, not the NPC's: this is what the sender said
        -- about the pace of their own last step, which is what the drivers
        -- assert on
        fast = player.fast and true or false,
        -- Who this avatar is drawn as. The roster's word again, and honest
        -- about it: the avatar layer bakes the sprite in at spawn and is
        -- rebuilt whenever this value moves (Avatars:refresh), so for a
        -- spawned player the two agree by construction -- what the roster
        -- says is what was last spawned with. The one gap is a sprite this
        -- game's catalog does not carry, which spriteFor draws as the
        -- fallback while the roster keeps the id its owner actually chose.
        -- Read it beside `spawned`: a character change is only on screen
        -- when both have moved.
        sprite = player.sprite,
        avatarMap = ctx.avatars.mapId,
      }
    end
    return out
  end
end

M.ctx = ctx
M.transport = transport

return M
