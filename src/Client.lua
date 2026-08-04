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
local Avatars = need("Avatars")
local Chat = need("Chat")
local Party = need("Party")
local Ui = need("Ui")
local Overlay = need("Overlay")
local Sessions = need("Sessions")
local World = need("World")
local HostServer = need("HostServer")
local Chars = need("Chars")
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
local ui = Ui.new(ctx)
local overlay = Overlay.new(ctx)
local sessions = Sessions.new(transport, ui)
local party = Party.new(transport, ui, ctx.chat)

ctx.client = M
ctx.ui = ui
ctx.sessions = sessions
ctx.party = party
ctx.server = server

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
local function withPort(address)
  if type(address) ~= "string" or address == "" then return nil end
  if address:match(":%d+$") then return address end
  return ("%s:%d"):format(address, Config.DEFAULT_PORT)
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
local function tokenKey(address)
  if type(address) ~= "string" or address == "" then return "rank:self" end
  local clean = address:lower():gsub("%s+", "")
  if clean == "" then return "rank:self" end
  return "rank:" .. clean
end

function M.rankToken(a, b)
  return Wire.token(mod.save:get(tokenKey(arg1(a, b))))
end

-- Stored only if it is the shape a hub mints. A half-token would fail every
-- claim from then on, and silently: the player would simply stop being
-- ranked, with nothing on screen to connect it to.
function M.setRankToken(a, b, c)
  local address, value
  if a == M then address, value = b, c else address, value = a, b end
  local token = Wire.token(value)
  if not token then return nil end
  mod.save:set(tokenKey(address), token)
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

function M.setSpriteChoice(a, b)
  local id = arg1(a, b)
  if not Chars.available(id) then return nil end
  mod.save:set("sprite", id)
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

-- ------- your own look, in your own game
--
-- Choosing a character has to change what *you* see too, not just what
-- everyone else sees, or the creator reads as broken.
--
-- The overworld player takes its sheet from field.playerSprites at
-- Player.new time (src/world/Player.lua), so there is no option to flip
-- once the player exists -- the renderer has to be swapped on the live
-- object. The original is kept so leaving a game puts your own trainer
-- back, rather than leaving you dressed as a Rocket grunt in single-player.
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
-- The gate is "already wearing one, or in a game and meant to be": the
-- second half keeps a look that failed to apply at connect time retrying on
-- the next map, which is what the transport check here used to do alone.
function M.refreshLook()
  if lookOwner == nil and not transport:isReady() then return false end
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
  transport:send(Wire.HELLO, {
    proto = Config.PROTOCOL,
    name = M.playerName(game),
    -- "this name is mine, and here is the ticket you gave me" -- absent on a
    -- first visit, which is what makes the hub mint one
    rankToken = M.rankToken(dialled),
    sprite = M.spriteChoice(),
    profile = M.profile(game),
    map = current and current.mapId,
    x = current and current.x,
    y = current and current.y,
    facing = current and current.facing,
  })
end

function M.disconnect()
  M.restoreLook()
  sessions:endSession(nil)
  party:reset()
  ctx.avatars:clear()
  ctx.roster:reset()
  ctx.chat:clear()
  transport:close()
  lastSent =
    { map = nil, x = nil, y = nil, facing = nil, busy = nil, fast = nil }
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
end

-- Leaving covers both shapes so callers never have to ask which they are:
-- a host stops the game for everyone, a guest just walks out.
function M.leave()
  if M.isHosting() then return M.stopHosting() end
  M.disconnect()
  return true
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
  ctx.chat:push({
    name = M.playerName(ctx.game),
    scope = scope,
    text = clean,
    outgoing = true,
  })
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
  -- your own rating, which cannot come from the roster: it has no entry for
  -- you, by design
  myPoints = Wire.points(msg.points)
  ranking, rankingAsked, rankingSeen = {}, false, false
  -- A hub that just claimed this name for us sends the ticket once and never
  -- again, so this is the only chance to keep it. Stored against the address
  -- we dialled -- the same key the next hello reads it back from.
  local granted = Wire.token(msg.rankToken)
  if granted then M.setRankToken(dialled, granted) end
  -- Absent means an older hub that does not score at all, which is not the
  -- same as being refused a name; treat silence as ranked and let the empty
  -- leaderboard speak for itself.
  rankedHere = msg.ranked ~= false
  for _, raw in ipairs(msg.players or {}) do
    ctx.roster:put(Wire.presence(raw))
  end
  transport:markReady()
  pushPresence(true)
  -- Deliberately not a text box. ui:say pushes a modal that sits over the
  -- world until someone presses A, and a routine status line is not worth
  -- interrupting play for -- the first real run left "Connected." covering
  -- the bottom third of the screen for the whole session. The player count
  -- is already on the MMO menu's PLAYERS row, which is where someone who
  -- cares will look. Errors still get a box; this does not.
  mod.log:info("connected -- %d other player(s) on", ctx.roster.count)
end

handlers[Wire.JOIN] = function(_, msg)
  local presence = Wire.presence(msg.player)
  if presence then ctx.roster:put(presence) end
end

handlers[Wire.PART] = function(_, msg)
  local id = Wire.id(msg.id)
  if not id then return end
  ctx.roster:remove(id)
  ctx.avatars:despawn(id)
  -- An invite in flight to somebody who just left will never be answered,
  -- and a client that kept waiting for that answer could never invite
  -- anybody again.
  party:onPeerGone(id)
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
  if from then ctx.chat:bubble(from, text, scope) end
end

handlers[Wire.PARTY_INVITE] = function(game, msg) party:onInvite(game, msg) end
handlers[Wire.PARTY_DECLINE] = function(_, msg) party:onDecline(msg) end
handlers[Wire.PARTY] = function(_, msg) party:onParty(msg) end
handlers[Wire.PARTY_END] = function(_, msg) party:onEnd(msg) end

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

handlers[Wire.RANKING] = function(_, msg)
  ranking = Wire.ranking(msg.entries)
  rankingAsked, rankingSeen = true, true
end

handlers[Wire.REQUEST] = function(game, msg) sessions:onRequest(game, msg) end
handlers[Wire.DECLINE] = function(_, msg) sessions:onDecline(msg) end
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

  ctx.chat:update(dt)
  sessions:update(game, dt)

  presenceClock = presenceClock + dt
  if presenceClock >= Config.PRESENCE_INTERVAL then
    presenceClock = 0
    pushPresence(false)
  end

  ctx.avatars:sync(ctx.roster, World.current())
end

-- ------- install

function M.install()
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
    { key = "bubbles", label = "BUBBLES", type = "toggle", default = true },
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

  mod.hooks:wrap("render.hud", function(next, game, viewport)
    local result = next(game, viewport)
    if mod.options:get("bubbles") ~= false then
      overlay:draw(game, viewport)
    end
    return result
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
  mod.events:on("battle.ended", function(payload)
    if not (payload and payload.battle) then return end
    if not transport:isReady() then return end
    M.reportBattle(payload.battle, payload.result)
  end)

  -- Leaving to the title screen or loading another save must not leave a
  -- stale roster pointing at a world that is gone -- and if this copy was
  -- hosting, the listener has to come down with it rather than serving a
  -- world nobody is standing in.
  mod.events:on("save.loaded", function() M.leave() end)

  mod.exports.isConnected = M.isConnected
  mod.exports.isHosting = M.isHosting
  -- nil unless this copy is hosting; a mod that wants to show the address
  -- somewhere of its own should not have to reach into HostServer for it
  mod.exports.hostAddress = function() return M.isHosting() and server:address() end
  mod.exports.players = function() return ctx.roster:sorted() end
  -- Who you are travelling with, you included, in the order the hub listed
  -- them -- empty when you are not in a party. The end-to-end driver reads
  -- this to tell "the invite was accepted" from "the box appeared".
  mod.exports.party = function() return party:list() end
  mod.exports.say = function(scope, text, to) return M.say(scope, text, to) end
  -- ranked PVP: this player's points, and the hub's top ten as last asked
  -- for. A mod that wants a leaderboard of its own reads these rather than
  -- inventing a second scoring system.
  mod.exports.points = function() return myPoints end
  mod.exports.isRanked = function() return rankedHere end
  mod.exports.ranking = function() return ranking end
  mod.exports.requestRanking = function() return M.requestRanking() end
  -- newest last, same order the chat screen scrolls
  mod.exports.chat = function() return ctx.chat:recent() end
  -- Where each remote player is according to the roster, and where their
  -- avatar actually stands. The two diverging is the signature of the
  -- avatar layer falling behind the network, which is invisible from the
  -- roster alone -- the end-to-end driver reads this to tell the two apart.
  mod.exports.traceAvatars = function(on) Avatars.TRACE = on and true or false end
  mod.exports.overlayState = function() return overlay:state() end
  -- what this player looks like in their own game, for tests and for a mod
  -- that wants to know
  mod.exports.myLook = function() return M.spriteChoice() end
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
        avatarMap = ctx.avatars.mapId,
      }
    end
    return out
  end
end

M.ctx = ctx
M.transport = transport

return M
