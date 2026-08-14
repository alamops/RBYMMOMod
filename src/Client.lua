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
local Friends = need("Friends")
local Coop = need("Coop")
-- For one flag it owns. Required rather than reached through `coop.state`,
-- which is an *instance* and is nil between battles -- which is exactly when
-- a save is loaded.
local CoopBattle = need("CoopBattle")
local Ui = need("Ui")
local Overlay = need("Overlay")
local Sessions = need("Sessions")
local World = need("World")
local Gen = need("Gen")
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
-- The people this copy keeps between sessions, for the hub it is on. Handed
-- the mod facade because it owns a file (and the mod.save mirror behind it),
-- which is the one thing Party does not need.
local friends = Friends.new(transport, ui, { mod = mod })
-- When a friend ask has to wait. A yes/no box over a live battle, a trade or
-- another prompt is the failure Sessions already refuses invites to avoid --
-- and unlike an invite, a friend ask can afford to wait: the hub is holding
-- it, so nothing is lost by asking a minute later. Wired here rather than
-- inside Friends because "busy" is a fact about the session and the stack,
-- which is exactly what Sessions is for and what Friends deliberately has no
-- engine dependency to see.
friends.busy = function(game)
  return sessions:isBusy() or sessions.incoming ~= nil
    or sessions:inFight(game or ctx.game)
end
local coop = Coop.new(transport, ui, party, ctx.roster, ctx.chat)
-- Co-op can be mid-handoff with no screen yet (running/state set, stack
-- still overworld). Sessions asks this so a 1v1 invite is refused there
-- the same way a wild battle on the stack is.
sessions.fighting = function()
  return coop.running == true or coop.state ~= nil
end
-- The other direction, and the same reason. A co-op join pushes a battle over
-- whatever is on screen with nobody asked first, so it has to know about a
-- trade the way Sessions knows about a fight -- a battle dropped on top of a
-- live trade is a third player watching a screen that stopped answering.
-- Wired here because "busy" is a fact about the session, which Coop holds no
-- dependency on; the join is deferred rather than lost (Coop:retryOffer).
coop.busy = function()
  return sessions:isBusy()
end
-- Where this player is standing, for that same retry. Coop is handed the map
-- at every other call site (onOffer, map.entered) and cannot ask the world
-- itself -- see Coop:challenge's header -- but the fixed step has nobody to
-- hand it one, so it gets a way to ask.
coop.here = function()
  local current = World.current()
  return current and current.mapId
end
-- The corner, for the one co-op line that has no time to be found anywhere
-- else. Wired the same way and for the same reason as the two above: Coop owns
-- no renderer, and the toast queue is built here. The join is the only line
-- that takes this door -- it is said in the last fraction of a second before a
-- battle nobody asked for covers this player's overworld, which is also the
-- last fraction of a second the partner's "!" mark is drawable (see
-- Overlay.ALERT_MIN). A toast is drawn after the overlay inside the same
-- render.hud wrap and behind no free-roam gate, so it is the half of that
-- signal that survives the push.
coop.toast = function(text)
  toast:push(text)
end

ctx.client = M
ctx.ui = ui
ctx.toast = toast
ctx.sessions = sessions
ctx.party = party
ctx.friends = friends
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
-- Survives drop teardown (disconnect) so a rejoin after a lost transport
-- stays silent; cleared only on intentional leave / stopHosting.
local connectedAnnounced = false

-- ------- auto-join
--
-- One hub, dialled by this file rather than by four menu presses. Which hub
-- is src/Servers.lua's answer (one key, so "only one server auto-joins" is
-- structural rather than enforced); *when* is this table.
--
-- `armed` is set when a world takes over -- CONTINUE and NEW GAME, which are
-- the two ways a player enters a game -- and spent on the first tick that
-- finds them actually standing in it. It is deliberately not set at load: a
-- copy sitting on the title screen has not entered anything, and dialling a
-- hub for a save nobody has opened would put this player on somebody's roster
-- while they read the menu.
--
-- `dialling` is true from the dial until the hub either welcomes us or
-- refuses, and it is what turns every failure sentence on that path into one
-- that names the auto-join. A player who pressed nothing and is handed
-- "could not reach 10.0.0.4:7788" has no way to know why their game tried.
--
-- `quiet` diverts the connect path's own sentence into `message` for exactly
-- that rewrite, rather than letting two boxes stack up over a game that has
-- only just come up.
local autoJoin = {
  armed = false,
  dialling = false,
  name = nil,
  quiet = false,
  message = nil,
}

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

-- The friends store for the hub this copy is on.
--
-- The store itself and not a copy of its rows, for the reason M.servers hands
-- back the store: its readers both read it and write to it (ask, remove), and
-- two lists that could disagree would be one bug waiting for a player to
-- reopen a menu. The screens reach it as ctx.friends; this is the same object
-- for anything holding the Client instead -- the suite, and any caller with no
-- ctx. Outside the mod it is the rows and not the store (mod.exports.friends).
function M.friends()
  return friends
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
-- The rank claim ticket is deliberately NOT cleared — PROTOCOL 16 identity
-- is the persistent playerId (PLAYER_ID_FILE / mod.save), not a per-hub
-- ticket. Deleting a bookmark must not cost a rating.
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

-- ------- persistent playerId (PROTOCOL 16)
--
-- One UUID-shaped hex string per LOVE save folder. Survives CONTINUE
-- (durable JSON + mod.save mirror). The hub seats you under this id; ranking
-- keys on it; a second live connection with the same id is refused.

local playerIdStore = { loaded = false, id = nil, unreadable = false }

local function loadPlayerIdFile()
  if playerIdStore.loaded then
    return playerIdStore.id, playerIdStore.unreadable
  end
  playerIdStore.loaded = true
  local fs, Json = filesystem(), json()
  if not (fs and Json) then return nil, false end
  local ok, body = pcall(fs.read, Config.PLAYER_ID_FILE)
  if not ok then
    playerIdStore.unreadable = true
    mod.log:warn("%s could not be read -- this copy will mint a player id "
      .. "into mod.save only until the file is readable again; delete it "
      .. "from the game's save folder to reset identity", Config.PLAYER_ID_FILE)
    return nil, true
  end
  if type(body) ~= "string" or body == "" then return nil, false end
  local decoded
  local dok, result = pcall(Json.decode, body)
  if dok and type(result) == "table" then decoded = result end
  if not decoded then
    playerIdStore.unreadable = true
    return nil, true
  end
  local id = Wire.playerId(decoded.id)
  playerIdStore.id = id
  return id, false
end

local function storePlayerIdFile(id)
  local fs, Json = filesystem(), json()
  if not (fs and Json) then return false end
  if playerIdStore.unreadable then return false end
  local encoded
  local ok, result = pcall(Json.encode, { id = id })
  if ok and type(result) == "string" then encoded = result end
  if not encoded then return false end
  local called, wrote = pcall(fs.write, Config.PLAYER_ID_FILE, encoded)
  if not (called and wrote) then return false end
  playerIdStore.loaded, playerIdStore.id = true, id
  return true
end

local playerIdSeq = 0

-- Mint or recall the persistent player id. Never raises.
function M.playerId()
  local fromSave = Wire.playerId(mod.save:get("playerId"))
  if fromSave then return fromSave end
  local fromFile = loadPlayerIdFile()
  if fromFile then
    mod.save:set("playerId", fromFile)
    return fromFile
  end
  playerIdSeq = playerIdSeq + 1
  local raw = Hub.Entropy.shared:bytes(16)
  local digest
  if type(raw) == "string" then
    digest = Sha256.hex(raw .. "|playerid|" .. tostring(playerIdSeq)
      .. "|" .. tostring(os.time()) .. "|" .. tostring(os.clock()))
  end
  if type(digest) ~= "string" then
    digest = Sha256.hex("playerid|fallback|" .. tostring(playerIdSeq)
      .. "|" .. tostring(os.clock()))
  end
  local id = type(digest) == "string" and digest:sub(1, Config.PLAYER_ID_HEX) or nil
  id = Wire.playerId(id)
  if not id then
    mod.log:warn("could not mint a player id -- reconnecting may fail until "
      .. "the entropy pool has more state; keep playing a moment and retry")
    return nil
  end
  mod.save:set("playerId", id)
  storePlayerIdFile(id)
  return id
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
  local fallback = Gen.defaultSprite(ctx.game, mod.content and mod.content.sprites)
  if id == fallback or id == Config.DEFAULT_SPRITE then return nil end
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
  local seen, owned = Gen.dexCounts(save)
  local badges = Gen.badgeCount(game, save)

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
    money = Gen.money.get(save),
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
  local ow = world and type(world.overworld) == "function" and world:overworld() or nil
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
  -- Gen 2 World:applySpritePalette reads spriteDef; without it the worn
  -- sheet stays DMG greyscale (same class of bug as Chars.portrait).
  player.spriteDef = record
  if Gen.generation(game) == 2 and type(renderer.setObjPalette) == "function" then
    local ow = mod.world and type(mod.world.overworld) == "function"
      and mod.world:overworld() or nil
    local pals = game and game.data and game.data.gen2Palettes
    if type(pals) == "table" then
      local okPal, Palettes = pcall(require, "src.world.gen2.Palettes")
      if okPal and Palettes and type(Palettes.spritePalette) == "function" then
        local daytime = "DAY"
        if ow and type(ow.daytime) == "string" then daytime = ow.daytime end
        local colors = Palettes.spritePalette(pals, daytime, record)
        if colors then
          local pid = tonumber(record.paletteId) or 0
          renderer:setObjPalette(colors,
            ("gen2:%s:%d"):format(tostring(daytime), pid))
        end
      end
    end
    if ow and type(ow.applySpritePalette) == "function" then
      pcall(function() ow:applySpritePalette(player) end)
    end
  end
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

-- What a refused dial says, and to whom.
--
-- Ordinarily the player, in a box, exactly as before. During an auto-join the
-- sentence is kept instead, so autoJoinFailed below can put it under a line
-- that says which server this was and that nobody asked for it -- one box
-- rather than two, and one that makes sense to a player who has just pressed
-- CONTINUE and pressed nothing since.
local function connectSay(text)
  if autoJoin.quiet then
    autoJoin.message = text
    return
  end
  ui:say(text)
end

-- The auto-join dial is over, one way or another.
--
-- Called from the success path and from every refusal, and by M.leave, so
-- `dialling` can never outlive the connection it describes -- a stale one
-- would put "Couldn't auto-join" in front of a failure the player caused
-- themselves an hour later.
local function autoJoinSettled()
  autoJoin.dialling, autoJoin.name = false, nil
  autoJoin.quiet, autoJoin.message = false, nil
end

-- The one dismissible box the whole feature can produce.
--
-- Everything a hub can refuse a connection with funnels here -- an address
-- that will not dial, a socket that will not open, a challenge we have no
-- code for, an mmo.error, a hang-up mid-handshake -- because the player did
-- not ask for any of it and the only useful thing to tell them is which
-- server it was and what it said. The remediation goes to the log beside it,
-- which is where a sentence too long for a text box belongs.
local function autoJoinFailed(reason)
  local name = autoJoin.name
  autoJoinSettled()
  mod.log:warn("auto-join to %s failed (%s) -- open START > MMO > SERVERS and "
    .. "either fix that row's address and join code or turn its AUTOJOIN row "
    .. "off", tostring(name or "the saved server"),
    tostring(reason or "no reason given"))
  local text = ("Couldn't auto-join\n%s."):format(name or "that server")
  local why = reason and tostring(reason) or nil
  if why and why ~= "" then text = text .. "\n" .. why end
  ui:say(text)
end

-- connect(game) / connect(game, address), and the colon form of both.
--
-- `address` is optional and is dialled *without* being stored -- see the
-- comment on `address` below for why that distinction exists at all. The
-- argument shuffle is arg1's, done by hand because there are two values to
-- shift rather than one.
function M.connect(a, b, c)
  local game, wanted
  if a == M then game, wanted = b, c else game, wanted = a, b end
  game = game or ctx.game
  if not game then return false end
  -- Any dial the player asked for cancels whatever the auto-join was in the
  -- middle of: it is the same transport, so a connection that is theirs must
  -- not be reported as this feature's when it goes wrong.
  if not autoJoin.quiet then autoJoinSettled() end
  if transport:isOpen() or M.isHosting() then
    connectSay("You're already in\na game.")
    return false
  end

  -- Dial *this* address, without adopting it.
  --
  -- The stored one is the default and stays the default: every caller that
  -- has always dialled "wherever JOIN GAME points" passes nothing and gets
  -- exactly that, and the two menu paths that pick a hub deliberately write
  -- it first (setJoinAddress) because choosing a row *is* the player saying
  -- where they join from now on.
  --
  -- What needs the other answer is the dial nobody pressed: auto-join runs
  -- unattended on every entry into a game, and writing its row through would
  -- silently replace whatever the player last typed into JOIN GAME with a
  -- hub they never chose as their default.
  local address = withPort(wanted) or M.joinAddress()
  -- Official public hub is Gen 1-only until a Gen 2 deploy exists. Refuse
  -- here (not only by hiding the SERVERS row) so a typed / options JOIN to
  -- play.rbymmo.com on Gold gets a clear sentence instead of a generation
  -- mismatch from the hub.
  if Servers.isFeaturedAddress(address)
      and not Config.featuredServerAllowed(Gen.generation(game)) then
    connectSay(
      "Official server is\nGen 1 only for now.\nHost a Gold game\ninstead.")
    return false
  end

  local ok, err = transport:connect(address)
  if not ok then
    connectSay(tostring(err or "Couldn't connect."))
    return false
  end

  dialled, authSent = address, false
  M.sendHello(game)
  M.applyLook(game)
  return true
end

-- The dial nobody pressed.
--
-- Runs off the fixed step rather than off the save event that armed it,
-- because "entered the game" is not a thing an event can prove: save.loaded
-- lands while the world is still being built (M.applyLook above says the same
-- about the same moment), and NEW GAME fires save.created before Oak has
-- finished asking who you are. World.current() answering is the proof --
-- there is an overworld and this player is standing in it -- and it costs one
-- field read on the ticks between a save landing and a world coming up.
--
-- Spent whatever happens, including when there is nothing to do: the flag
-- means "a world was entered and the dial has not been considered yet", so
-- leaving it set after a decision would re-dial on the next map, and after a
-- LEAVE it would drag the player back into the game they just walked out of.
--
-- CONNECT's own pre-flight is deliberately not repeated here beyond the two
-- that decide whether to try at all -- M.connect refuses an open transport
-- and a Gen 2 boot dialling the official hub itself, and its sentences are
-- the ones the box ends up carrying.
local function tryAutoJoin(game)
  if not World.current() then return end
  autoJoin.armed = false
  -- Already somewhere: a player who hosted or joined between the save landing
  -- and their feet hitting the ground has answered this question themselves.
  if transport:isOpen() or M.isHosting() then return end

  local entry, armed
  local ok, why = pcall(function()
    entry = servers:autoJoinEntry(game)
    armed = servers:autoJoinKey()
  end)
  if not ok then
    mod.log:warn("could not read the auto-join server (%s) -- nothing was "
      .. "dialled; set it again under START > MMO > SERVERS", tostring(why))
    return
  end
  if not entry then
    -- Armed, but at a row this boot cannot resolve: today that is only the
    -- official hub on a Gen 2 game, which the menu hides and menuGet refuses
    -- for the same reason M.connect would refuse the dial. Doing nothing is
    -- the right answer -- there is nothing to reach -- but doing it *silently*
    -- leaves a player who set this on Red wondering why Gold never connects,
    -- with nothing in the log to find. No box: nobody pressed anything, and
    -- this is a standing condition rather than a failure of this launch.
    if armed then
      mod.log:warn("auto-join is set to %s, which this game cannot reach -- "
        .. "the official server is Gen 1 only for now; host a Gold game or "
        .. "point AUTOJOIN at another row under START > MMO > SERVERS",
        tostring(armed))
    end
    return
  end

  autoJoin.name = entry.name
  -- Normalised but deliberately NOT stored: the port has to be filled in
  -- before the join code is filed, because the code is keyed on exactly the
  -- string the transport dials. What the SERVERS menu's CONNECT does here
  -- instead is setJoinAddress -- adopting the row as the standing JOIN GAME
  -- target -- which is right for a row the player just chose and wrong for a
  -- dial that happens by itself on every entry into a game.
  local target = withPort(entry.address)
  if not target then
    return autoJoinFailed("That address is\nno good.")
  end
  if entry.code then M.setJoinCode(target, entry.code) end

  autoJoin.quiet, autoJoin.message = true, nil
  local dialledOk = M.connect(game, target)
  autoJoin.quiet = false
  if not dialledOk then
    local said = autoJoin.message
    autoJoin.message = nil
    return autoJoinFailed(said)
  end
  -- The socket is open and the hello is away. Everything that can still go
  -- wrong -- a challenge with no code, an mmo.error, a hang-up -- is a
  -- message away, so the flag stays up until the welcome lands.
  autoJoin.dialling = true
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
  -- HostServer locks the hub from Gen.generation(game); pass the live boot
  -- so Gold cannot bind a Gen 1 hub and refuse its own hello.
  ctx.game = game
  local ok, err = server:start(Config.DEFAULT_PORT, limit, M.hostJoinCode(), game)
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
  connectedAnnounced = false
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
    -- Hub generation lock (PROTOCOL 20). 1 = Red/Blue/Yellow, 2 = Gold.
    generation = Gen.generation(game),
    name = name,
    -- Persistent identity (PROTOCOL 16). Hub uses this as client.id and the
    -- rank-board key. Minted once per install; survives CONTINUE via file.
    playerId = M.playerId(),
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
  -- The list itself is on disk and stays there; what goes is the *open*
  -- bucket, because which list is open is a fact about one connection. Leaving
  -- it open offline would let a stale prompt answer to a hub that is no longer
  -- listening, and would leave FRIENDS drawing one hub's people while the
  -- player is on their way to another.
  friends:reset()
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
  -- Walking out is an answer to the auto-join too: the dial it describes is
  -- the one being torn down, and a flag left standing would flavour the next
  -- unrelated failure as this feature's. The *setting* is untouched -- it is
  -- about the next time a world comes up, not about this session.
  autoJoinSettled()
  if M.isHosting() then return M.stopHosting() end
  M.disconnect()
  connectedAnnounced = false
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
  -- A world is taking over, which is the one thing "entered the game" can
  -- mean: CONTINUE and NEW GAME both arrive here, and nothing else does. The
  -- dial itself waits for the tick that finds the player standing in it --
  -- see tryAutoJoin for why the event is too early to act on.
  --
  -- After M.leave above, deliberately: leaving is what clears the last
  -- session's flag, and arming before it would be armed and then spent on a
  -- teardown that has nothing to do with this save.
  autoJoin.armed = true
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
    -- An auto-join is told, not asked. The code grid is the right answer for
    -- a player who just pressed CONNECT and is standing in front of the
    -- screen; dropping it in front of somebody who pressed CONTINUE and got
    -- a world is a demand for six characters they did not come here to type.
    -- The row is theirs to fix under SERVERS, and the box says so.
    if autoJoin.dialling then
      return autoJoinFailed("It needs a join\ncode.")
    end
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
    if autoJoin.dialling then
      return autoJoinFailed("Couldn't answer\nits join code.")
    end
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
  -- Which friends list this session is about. It is filed under the hub and
  -- the trainer name we joined as -- the same two halves the rank ticket is,
  -- and for the same reason: a name is what a friendship is keyed on, and one
  -- hub's ANN is not another's. Opened here rather than at connect because
  -- until the welcome lands there is no proof this hub let us in at all, and a
  -- list opened against a hub that refused us is a list nothing would ever
  -- write to.
  --
  -- Before the hub's own held friend traffic can arrive, which it does
  -- immediately after this welcome: Friends.onAsk refuses an ask with no list
  -- open, so opening it late would silently drop the very asks that were held
  -- for this player while they were away.
  friends:setHub(dialled, M.playerName(game))
  -- your own rating, which cannot come from the roster: it has no entry for
  -- you, by design
  myPoints = Wire.points(msg.points)
  ranking, rankingAsked, rankingSeen = {}, false, false
  -- Absent means an older hub that does not score at all, which is not the
  -- same as being refused a name; treat silence as ranked and let the empty
  -- leaderboard speak for itself. PROTOCOL 16 hubs always send ranked=true.
  rankedHere = msg.ranked ~= false
  -- Kept exactly as sent and compared rather than coerced: only a literal
  -- true is an operator. Absent -- an older hub, or a plain player code --
  -- is false, and so is anything else that arrives in the field.
  myAdmin = msg.admin == true
  for _, raw in ipairs(msg.players or {}) do
    ctx.roster:put(Wire.presence(raw))
  end
  transport:markReady()
  -- The auto-join, if this was one, is over and it worked: nothing after this
  -- point is a failure of it, and the player is told they are connected by
  -- the same toast every other arrival gets.
  autoJoinSettled()
  pushPresence(true)
  -- A mediated fight that survived a brief drop asks the intermediator to
  -- resume: both hubs already honour mmo.battle_reconnect inside the grace.
  sessions:onTransportReady()
  coop:onTransportReady()
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
  -- the bottom third of the screen for the whole session. Toast + HUB
  -- scrollback below are the replacement; the player count is already on
  -- the MMO menu's PLAYERS row. Errors still get a box; this does not.
  if not connectedAnnounced then
    local line = Toast.connectedLine()
    toast:push(line)
    ctx.chat:push({ name = "HUB", scope = "global", text = line })
    connectedAnnounced = true
  end
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
  -- Same sentence for everybody, and the blue is the whole difference: on a
  -- busy hub the corner is a stream of names, and "was that anybody I know" is
  -- the one question worth answering there without being read.
  toast:push(Toast.joinLine(presence.name),
             Toast.joinColor(friends:isFriend(presence.name)))
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

-- Friends.  Three types, and the client half of each is one line, because the
-- interesting parts are elsewhere: the hub decides whether an ask may be
-- carried and holds it for somebody who is offline, and Friends decides
-- whether this is a moment to ask a human anything.
handlers[Wire.FRIEND_ASK] = function(game, msg) friends:onAsk(game, msg) end
handlers[Wire.FRIEND_ANSWER] = function(_, msg) friends:onAnswer(msg) end
handlers[Wire.FRIEND_REMOVE] = function(_, msg) friends:onRemoved(msg) end

handlers[Wire.COOP_OFFER] = function(game, msg)
  local current = World.current()
  coop:onOffer(game, msg, current and current.mapId)
end
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

-- The three things an intermediator says during a mediated fight. There is no
-- inbound handler for the ruleset, the party or a choice: those travel the
-- other way, and a client that received one would be receiving a message the
-- hub has no reason to send it.
--
-- Offered to both, because there are two kinds of refereed fight -- the 1v1 that
-- Sessions holds and the 2-on-2 that Coop does -- and this message names which
-- one it is about. Both ends check that name against the battle they uploaded to
-- and ignore anything else, which is what makes offering it to both correct
-- rather than merely harmless: the id on the message decides, not the order of
-- these two lines.
handlers[Wire.BATTLE_READY] = function(_, msg)
  sessions:onBattleReady(msg)
  coop:onBattleReady(msg)
end
handlers[Wire.BATTLE_EVENT] = function(_, msg)
  sessions:onBattleEvent(msg)
  coop:onBattleEvent(msg)
end
handlers[Wire.BATTLE_OUTCOME] = function(_, msg)
  sessions:onBattleOutcome(msg)
  coop:onBattleOutcome(msg)
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
  -- An auto-join says nothing here on purpose. transport:fail has closed the
  -- socket, so the tick that is running this handler falls straight into its
  -- own lost-connection branch a few lines later -- which is the one place
  -- that turns a dead transport into the auto-join's single box, and saying
  -- it twice would stack two boxes over a game that has only just come up.
  if autoJoin.dialling then return end
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

  -- One field read on every step this mod is installed for, and false on all
  -- but the handful that follow a save landing. It has to sit above the
  -- "not open" return: a copy with no connection is exactly the copy this is
  -- for.
  if autoJoin.armed then tryAutoJoin(game) end

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
    -- Read up front, beside the reason, so the two halves of the sentence
    -- this branch may have to say are taken from the same instant.
    local wasAutoJoin = autoJoin.dialling
    -- Logged so a headless / e2e run can see *why* the socket went away --
    -- hub hang-up, idle timeout, write error -- rather than only noticing
    -- later that a co-op prompt never appeared over a solo trainer fight.
    if reason then
      mod.log:warn("hub connection lost: %s", tostring(reason))
    else
      mod.log:warn("hub connection lost (no reason from the transport)")
    end
    M.disconnect()
    -- Every way a hub can refuse a connection it never welcomed arrives here
    -- -- mmo.error, a hang-up, a handshake that ran out -- so this is the one
    -- place the auto-join has to speak, and it speaks even when the transport
    -- gave no reason at all: the player pressed nothing, so silence would
    -- leave them in a single-player game with no idea the dial happened.
    if wasAutoJoin then
      autoJoinFailed(reason)
    elseif reason then
      ui:say(tostring(reason))
    end
    return
  end

  if not transport:isReady() then return end

  -- Ageing the corner, where the bubbles used to be aged.  Toasts expire on
  -- the fixed step rather than on drawn frames, so a line stays up for the
  -- five seconds Config says and not for however many frames the machine
  -- managed in them.
  toast:update(dt)
  -- And the partner's "!", for the same reason: the mark over a friend's
  -- trainer bobs on the fixed step, and -- more to the point -- it has to keep
  -- ageing while the world is *not* being drawn, because the overlay's draw
  -- bails at the free-roam gate and a partner sitting in a menu would
  -- otherwise meet a full-length mark on closing it.
  overlay:update(dt)
  sessions:update(game, dt)
  -- Handed the stack as well as the clock: a partner's offer that landed while
  -- this player was busy is re-attempted from in there, and the only way to
  -- know they are free again is to look. Two field reads on a tick with no
  -- offer standing -- see Coop:retryOffer.
  coop:update(dt, game)
  -- A friend ask that arrived mid-battle, put on screen now that the battle is
  -- over. Two field reads on every other tick: the queue is empty on all but a
  -- handful of them, and _drain answers on the first one.
  friends:update(game, dt)

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

  -- Prefer the live catalog (Gold walkers + Cast chars) over the Gen1-only
  -- Config.SPRITES list — CHARACTER already uses Chars.list; options must match.
  local spriteChoices = {}
  for _, id in ipairs(Chars.list(ctx.game)) do
    spriteChoices[#spriteChoices + 1] = { Chars.label(id), id }
  end
  if #spriteChoices == 0 then
    for _, row in ipairs(Config.SPRITES) do
      spriteChoices[#spriteChoices + 1] = { row[1], row[2] }
    end
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
      default = Gen.defaultSprite(ctx.game, mod.content and mod.content.sprites),
      choices = spriteChoices },
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

  -- Co-op against an NPC: hand the trainer to Coop before the player presses
  -- anything.
  --
  -- **Watched rather than intercepted, and that is what makes it reach every
  -- trainer.** An earlier version wrapped `script.command` and yielded the
  -- script runner's coroutine, which worked -- and only for script-driven
  -- battles. The other way a trainer starts, walking into one in the
  -- overworld, goes through `OverworldState:engageTrainer`, which emits an
  -- event and cannot be cancelled; there is no seam there to hold at.
  --
  -- Both paths end in the same place: `game.stack:push(battle)`. So this
  -- listens for the push instead of trying to prevent it. There is no cover
  -- pushed over what just arrived any more (round 13 deleted it): a partied
  -- player's wait runs invisibly behind the engine's own encounter, which is
  -- why a player who is not in a party -- or whose partner is on some other
  -- map -- never notices any of this happened, or is told once and left to
  -- fight what is already on screen.
  --
  -- src/Coop.lua's onTrainerBattle / onWildEncounter is where the answers
  -- diverge, and their headers explain what the co-op path does with the
  -- battle it took. Both refuse an off-map partner outright now; wild's
  -- divert is otherwise the same same-map auto-join into coop_wild, else the
  -- engine wild is left alone.
  -- Gen 2's ui/gen2/BattleState has no `.kind` (Gen 1 BattleState does).  The
  -- fight shape lives on `state.battle` instead: `.wild` / `.trainer`.  Stamp
  -- Gen1-shaped aliases so Coop's onTrainerBattle / onWildEncounter and
  -- consume()'s onFinish path keep working without a Gen2 fork at every gate.
  local function stampGen2FightAliases(state)
    local battle = state.battle
    if type(battle) ~= "table" then return end
    if state.kind == nil then
      if battle.wild then
        state.kind = "wild"
      elseif battle.trainer then
        state.kind = "trainer"
      end
    end
    if state.kind == "trainer" and battle.trainer then
      if state.oppClass == nil then
        state.oppClass = battle.trainer.classId or battle.trainer.class
      end
      if state.trainer == nil then
        state.trainer = battle.trainer
      end
    end
    if state.enemyParty == nil and battle.enemyParty then
      state.enemyParty = battle.enemyParty
    end
    -- Gen 2 keeps the face on enemyTrainerImage; CoopBattle reads trainerPic.
    if state.trainerPic == nil and state.enemyTrainerImage then
      state.trainerPic = state.enemyTrainerImage
    end
    -- Gen 2 finishes via onDone; Coop.consume calls onFinish.  Alias, keep both.
    if state.onFinish == nil and type(state.onDone) == "function" then
      state.onFinish = state.onDone
    end
  end

  mod.events:on("screen.pushed", function(payload)
    local state = payload and payload.state
    if not state then return end
    if not transport:isReady() then return end
    stampGen2FightAliases(state)
    local current = World.current()
    local mapId = current and current.mapId
    if state.kind == "trainer" then
      local ok, err = pcall(function()
        coop:onTrainerBattle(ctx.game, state, mapId)
      end)
      if not ok then
        mod.log:warn("the co-op prompt failed (%s); this trainer is fought the "
          .. "ordinary way -- the battle itself is unaffected", tostring(err))
      end
    elseif state.kind == "wild" then
      local ok, err = pcall(function()
        coop:onWildEncounter(ctx.game, state, mapId)
      end)
      if not ok then
        mod.log:warn("the party wild divert failed (%s); this encounter is "
          .. "fought the ordinary way -- the battle itself is unaffected",
          tostring(err))
      end
    end
  end)

  -- Palette zones for mediated battle screens (1v1 and 2-on-2).
  --
  -- Game.lua prefers a top state's sgbPalettes when present (MediatedBattle
  -- supplies that). This hook still covers CoopBattle, which only exposes
  -- zones(), and backs 1v1 if a build ever relies on the hook alone.
  --
  -- Without the opt-out, OG / CLASSIC invent a GRAYS whole-screen remap over
  -- already-paletted pics -- pink paper and black outlines on one client while
  -- another (different COLORS mode) looked fine. WideBattle takes the same
  -- `colors = false` escape for the same reason.
  mod.hooks:wrap("render.zones", function(next, game, zones)
    local out = next(game, zones)
    local top = game and game.stack and game.stack:top()
    -- CoopBattle has .sim; MediatedBattle has .refreshSlotSprite.
    if top and top.zones and (top.sim or top.refreshSlotSprite) then
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
      -- Gen 2 Menu Account draws desc for the highlighted row; without it the
      -- previous entry's box stays on screen when the cursor lands on MMO.
      desc = { "Play with", "friends" },
      onSelect = function()
        -- Gen 1's StartMenu pops itself before onSelect; Gen 2's leaves the
        -- menu under the mod row. Pop it first so MAIN's cancel reopens one
        -- StartMenu with a real onClose, instead of stacking a second
        -- Gen2StartMenu that cannot leave the stack (Ui.reopenStartMenu).
        if Gen.generation(game) == 2 and game and game.stack
            and type(game.stack.top) == "function" then
          local top = game.stack:top()
          if top and type(top.close) == "function"
              and type(top.onClose) == "function" and top.list ~= nil then
            pcall(function() top:close() end)
          end
        end
        mod.ui.push(game, Ui.SCREEN.MAIN)
      end,
    })
  end)

  -- A warp is the one movement the tile-by-tile presence stream cannot
  -- describe, so it is announced the moment it lands instead of waiting for
  -- the next interval.
  mod.events:on("player.warped", function() pushPresence(true) end)
  mod.events:on("map.entered", function()
    pushPresence(true)
    M.refreshLook()
    -- A partner's NPC invite that arrived while we were off-map (or that we
    -- walked onto) becomes the same confirm a same-map offer raises on sight.
    local current = World.current()
    if current and ctx.game then
      coop:considerOffer(ctx.game, current.mapId)
    end
  end)

  -- Facing a remote player and pressing A opens the same menu the roster
  -- does.  The engine's talkTo has already run by this point and found
  -- nothing to say (these NPCs carry no text), so this adds the interaction
  -- rather than replacing one.
  --
  -- Gen 2 nuance: World:interactBody only emits kind="npc" when the object
  -- has a scriptKey. Avatar NPCs are scriptless, so Gold falls through to
  -- kind="none" after freezing them -- still the face-cell coords. Accept
  -- both; roster:at decides whether a remote player is there.
  mod.events:on("world.interacted", function(payload)
    -- An A-press is a human deciding to press A, which is the least
    -- predictable timing this process ever sees; it goes into the pool
    -- before anything else here can return early.
    stirEntropy(0)
    if not payload then return end
    if payload.kind ~= "npc" and payload.kind ~= "none" then return end
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
  -- Drivers (and any peer mod) leave the same way the LEAVE row does —
  -- intentional teardown, not a dropped transport.
  mod.exports.leave = function() return M.leave() end
  -- nil unless this copy is hosting; a mod that wants to show the address
  -- somewhere of its own should not have to reach into HostServer for it
  mod.exports.hostAddress = function() return M.isHosting() and server:address() end
  -- The hubs this copy has been welcomed by, in the order SERVERS draws them.
  -- The rows and not the store, so nothing outside this mod can rename or
  -- evict what the player collected -- and so the end-to-end driver can assert
  -- that connecting actually recorded a hub, which is otherwise only visible
  -- by opening a menu.
  mod.exports.servers = function() return servers:list() end
  -- Which hub this copy dials on the way into a game, or nil. The key rather
  -- than the row, because that is the whole of the setting -- and because it
  -- is the one thing about auto-join a test can read without a world: whether
  -- it *fired* is visible in isConnected, but whether it was ever armed is
  -- otherwise only visible by opening a menu.
  mod.exports.autoJoinServer = function() return servers:autoJoinKey() end
  mod.exports.players = function() return ctx.roster:sorted() end
  -- The people this copy keeps on the hub it is on, newest friend first --
  -- rows, never the store, so nothing outside this mod can add to or empty
  -- what the player agreed to. Empty offline, because a friends list is a fact
  -- about one hub and there is no hub to have one on. The end-to-end driver
  -- reads it to tell "the ask was accepted" from "the box appeared".
  mod.exports.friends = function() return friends:list() end
  -- Who you are travelling with, you included, in the order the hub listed
  -- them -- empty when you are not in a party. The end-to-end driver reads
  -- this to tell "the invite was accepted" from "the box appeared".
  mod.exports.party = function() return party:list() end
  -- Leave the standing party the same way the PARTY > LEAVE row does. The
  -- Gen2 e2e falls back here when Start → MMO → PARTY is unscannable after a
  -- long fight stack (same role as exports.leave when LEAVE misses).
  mod.exports.leaveParty = function() return party:leave() end
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
      -- Where the fight is, and what kind it is. `map` is the gate the
      -- overlay's "!" is placed behind (src/Overlay.lua's offerMark): without
      -- it a driver watching the bubble can see it appear but not that it
      -- appeared for the right reason. `npcId` renders nothing -- the mark
      -- anchors to the waiter's avatar, never to a ROM-derived object -- and is
      -- carried only so a failed synthetic finish can be diagnosed against the
      -- id the plan actually named.
      map = offer.map, mode = offer.mode, npcId = offer.npcId,
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
      -- How many experience awards this copy actually applied.
      --
      -- Exp is the one part of a refereed fight with no visible artefact a
      -- driver can wait for: the referee emits facts (it holds no species
      -- table and can never price a faint), the client prices them, and the
      -- result lands in a save field. Watching `save.party[i].experience`
      -- climb is weaker than it looks -- it would pass on a fight that never
      -- emitted anything and would *fail* on one that ended by catch, where
      -- paying nothing is right. This is the count of awards applied, which
      -- is the fact an e2e wants to assert. Zero offline and zero in the
      -- non-paying modes (1v1, coop_pvp) by design.
      --
      -- **Unlike its siblings above, this one survives the fight.** They read
      -- `coop.state`, which is nil the moment the battle leaves the stack, so
      -- they answer 0 for the whole window in which somebody would naturally
      -- ask. `Coop.finish` latches this count on the way out, so a caller can
      -- read it during the fight OR after it and get the same number.
      expPaid = (state and tonumber(state.expPaid))
        or (coop and tonumber(coop.lastExpPaid)) or 0,
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
