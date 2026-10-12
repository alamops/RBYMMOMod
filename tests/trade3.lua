-- Headless Gen 3 trade (Wave 2 T6): src/Trade3.lua and the Gen 3 arms of
-- src/Sessions.lua.
--
-- Two tiers in one file.
--
--   A. Always.  Two Gen 3 players trade through two real Sessions over a
--      Net.loopbackPair standing in for the hub -- every relay payload is
--      re-encoded through JSON on the way, exactly like the wire.  Trade3 runs
--      on the engine's *real* Gen 3 trade rules (link/family.lua
--      canTradeSelectedMon / gameProgressForLinkTrade), mail pool
--      (game3/mail.lua) and TradeMons (scripting/natives_trade.lua), which are
--      plain Lua and need no ROM.  Only what would need an imported cache is
--      stood in for: the mon codec, the evolution table, the evolution scene,
--      the learn-move prompts.  The mons are synthetic numbers.
--
--   B. When an imported FireRed cache can be mounted -- the engine's own
--      tests/game3_cache rule: POKEPORT_IDENTITY naming a LOVE identity that
--      holds one, or POKEPORT_GBA_CACHE -- the REAL packMon3 -> JSON -> strict
--      unpackMon3, the real trade-evolution rules and the real TradeMons on mons
--      built by Party.giveMon.  With RBY_MMO_EMERALD_CACHE pointing at an
--      imported Emerald cache directory (the one holding its meta.json) as
--      well, the FireRed -> Emerald round trip too, DEOXYS forme included.  Skipped (with a line saying so)
--      otherwise; nothing ROM-derived is committed either way.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/trade3.lua
--   POKEPORT_IDENTITY=<id> RBY_MMO_EMERALD_CACHE=<dir> luajit mods/rby_mmo/tests/trade3.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"
if not io.open(MOD_PATH .. "/src/Trade3.lua", "rb") then
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("(.+)[/\\]")
    if dir then MOD_PATH = dir:gsub("[/\\]tests$", "") end
  end
end

local Json = require("src.link.Json")
local Net = require("src.link.Net")

local warns = {}
local stubMod = {
  -- A Gen 3 boot: src/Gen3.lua's guard reads this field.
  generation = 3,
  log = {
    info = function() end,
    warn = function(_, fmt, ...)
      local ok, line = pcall(string.format, fmt, ...)
      warns[#warns + 1] = ok and line or tostring(fmt)
    end,
    error = function() end,
  },
}

-- A fresh module graph each time, so a tier's engine stubs are the ones its
-- Gen3.lua caches (Gen3.engine remembers every module it resolves).
local loadstr = loadstring or load
local function newNeed()
  local cache = {}
  local function need(n)
    if cache[n] ~= nil then return cache[n] end
    local h = assert(io.open(MOD_PATH .. "/src/" .. n .. ".lua", "rb"))
    local body = h:read("*a")
    h:close()
    local chunk = assert(loadstr(body, "@" .. n .. ".lua"))
    local value = chunk(need, stubMod)
    cache[n] = value == nil and true or value
    return cache[n]
  end
  return need
end

local saved = {}
local function stub(name, value)
  if saved[name] == nil then saved[name] = package.loaded[name] or false end
  package.loaded[name] = value
end
local function unstubAll()
  for name, original in pairs(saved) do
    package.loaded[name] = original or nil
  end
  saved = {}
end

local function contains(list, needle)
  for _, line in ipairs(list) do
    if type(line) == "string" and line:find(needle, 1, true) then return true end
  end
  return false
end

-- ===================================================================
-- Tier A -- the real rules, a stand-in codec
-- ===================================================================

-- The codec stand-in: packMon3 keeps the fields the real one sends, and
-- unpackMon3 refuses what the real one's first checks refuse (a species off
-- the internal table, a level off 1..100) -- tier B runs the real thing.
local FakeProtocol = {}
local PACKED = { "species", "nickname", "level", "exp", "hp", "personality",
  "otId", "otSecretId", "otName", "otGender", "gender", "friendship" }
function FakeProtocol.packMon3(mon)
  local out = {}
  for _, k in ipairs(PACKED) do out[k] = mon[k] end
  out.item = tonumber(mon.item or mon.heldItem) or 0
  out.isEgg = mon.isEgg == true
  out.fatefulEncounter = mon.fatefulEncounter == true
  out.moves = { { id = 33, pp = 35, ppUps = 0 } }
  return out
end
function FakeProtocol.packParty3(party, indices)
  local out = {}
  for _, i in ipairs(indices) do
    if party[i] then out[#out + 1] = FakeProtocol.packMon3(party[i]) end
  end
  return out
end
function FakeProtocol.unpackMon3(_, packed, opts)
  FakeProtocol.lastStrict = opts and opts.strict
  if type(packed) ~= "table" then return nil, "bad mon" end
  local sp = tonumber(packed.species)
  if not sp or sp < 1 or sp > 411 then return nil, "unknown species" end
  local lv = tonumber(packed.level)
  if not lv or lv < 1 or lv > 100 then return nil, "bad level" end
  local mon = {}
  for k, v in pairs(packed) do mon[k] = v end
  mon.speciesId = sp
  mon.heldItem = mon.item
  mon.maxHp = tonumber(packed.hp) or 20
  mon.moves = { 33 }
  return mon
end

local FakePokemon = { SPECIES_EGG = 412 }
function FakePokemon.isEgg(mon)
  return type(mon) == "table" and (mon.isEgg == true or mon.species == 412)
end
function FakePokemon.name(species) return "SPECIES" .. tostring(species) end
function FakePokemon.displayMonName(mon)
  if FakePokemon.isEgg(mon) then return "EGG" end
  if type(mon.nickname) == "string" and mon.nickname ~= "" then return mon.nickname end
  return FakePokemon.name(mon.species)
end

-- The trade rows the stand-in knows, by the carts' own species / item
-- numbers: KADABRA (64) evolves by trade, ONIX (95) by trade holding a METAL
-- COAT (199, consumed), and an EVERSTONE (195) refuses either.
local evolutions = {}
local FakeEvolution = {}
function FakeEvolution.tradeTarget(mon)
  local item = tonumber(mon.item) or 0
  if item == 195 then return nil end
  if mon.species == 64 then return 65 end
  if mon.species == 95 and item == 199 then
    mon.item, mon.heldItem = 0, 0
    return 208
  end
  return nil
end
function FakeEvolution.apply(mon, target, _, _, via)
  evolutions[#evolutions + 1] = { mon = mon, target = target, via = via }
  mon.species, mon.speciesId = target, target
  return true
end

local scenes = {}
local FakeScene = {}
function FakeScene.start(mon, target, opts)
  scenes[#scenes + 1] = { mon = mon, target = target, opts = opts }
  return true
end

local battleActive = false
local questEvents = {}

stub("src.link.Protocol", FakeProtocol)
stub("src.link.Handshake", {
  generation = function(game) return type(game) == "table" and game.generation or 1 end,
  hello = function(game, kind)
    return { type = "hello", generation = 3, fingerprint = game.fingerprint, mode = kind }
  end,
  checkCompat = function(mine, theirs)
    if (theirs.generation or 1) ~= mine.generation then return "refused" end
    if mine.fingerprint == theirs.fingerprint then return "full" end
    return "subset"
  end,
  tradeAllowed = function(verdict) return verdict ~= "refused" end,
  strict = function(verdict) return verdict ~= "vanilla_peer" end,
})
stub("src.link.LinkBattle", {})
stub("src.core.game3.pokemon", FakePokemon)
stub("src.core.game3.evolution", FakeEvolution)
stub("src.ui.game3.evolution_scene", FakeScene)
stub("src.core.game3.battle", { isActive = function() return battleActive end })
stub("src.core.game3.runtime", { getSession = function() return nil end })
stub("src.core.game3.quest_log_recorder", {
  event = function(session, key) questEvents[#questEvents + 1] = { session = session, key = key } end,
})

local Family = require("src.core.game3.link.family")
local Mail = require("src.core.game3.mail")
local Dex = require("src.core.game3.dex")
local Stack = require("src.ui.game3.stack")

local need = newNeed()
local Trade3 = need("Trade3")
local Sessions = need("Sessions")
local Wire = need("Wire")

-- ------- fixtures

local function mon(species, level, extra)
  local m = {
    species = species, speciesId = species, level = level, exp = level * 100,
    hp = 20, maxHp = 20, nickname = "", personality = species * 7919,
    otId = 100, otSecretId = 7, otName = "OT", otGender = 0, gender = "M",
    item = 0, heldItem = 0, friendship = 50, isEgg = false,
  }
  for k, v in pairs(extra or {}) do m[k] = v end
  return m
end

-- A Gen 3 session.  `national` unlocks the National Dex the way the cart's
-- EnableNationalPokedex does; `linkRegions` sets the flag that lets this
-- save meet the other region (FLAG_SYS_CAN_LINK_WITH_RS / FLAG_IS_CHAMPION),
-- looked up by name in the engine's own constants.
local function newSession(opts)
  local s = {
    version = opts.version or "firered", name = opts.name or "RED",
    trainerId = opts.trainerId or 1, secretId = 2, gender = 0,
    party = opts.party or {}, dex = { seen = {}, owned = {}, caught = {} },
    flags = {}, vars = {}, bag = {},
  }
  if opts.national then
    pcall(Dex.enableNational, s)
    s.national_dex_unlocked = true
  end
  if opts.linkRegions then
    local id = Family.flag(s.version, Family.PROGRESS_FLAG[Family.of(s.version)])
    s.flags[id] = true
  end
  return s
end

local function giveMail(session, partyMon, words, from)
  local pool = Mail.pool(session)
  pool[1] = { words = words, playerName = from, trainerId = 4242,
              species = partyMon.species, itemId = 121, design = 0 }
  partyMon.mail = 0
  partyMon.item, partyMon.heldItem = 121, 121
end

-- ------- mail on the wire

eq(Trade3.sanitizeMail(nil), nil, "nil mail stays nil")
eq(Trade3.sanitizeMail(false), nil, "false mail stays nil")
eq(Trade3.sanitizeMail({ itemId = 13, words = {} }), nil,
  "a record whose item is not a mail item is refused")
do
  local clean = Trade3.sanitizeMail({
    itemId = 124, words = { 1, -5, 70000, "x", 5 }, playerName = "LONGNAME\n!",
    trainerId = 5, species = 30003, design = 99,
  })
  check(clean ~= nil, "a mail record sanitises")
  eq(clean.words[1], 1, "a real easy-chat word survives")
  eq(clean.words[2], 0xFFFF, "a negative word reads as EC_WORD_UNDEFINED")
  eq(clean.words[3], 0xFFFF, "an out-of-range word reads as EC_WORD_UNDEFINED")
  eq(#clean.words, 9, "always nine words")
  eq(clean.playerName, "LONGNAM", "sender name clipped to PLAYER_NAME_LENGTH, controls stripped")
  eq(clean.species, 30003, "an Unown letter species rides as the cart writes it")
  eq(clean.design, 3, "design follows from the item, never from the wire")
end

do
  local s = newSession({ party = { mon(16, 5), mon(25, 12) } })
  giveMail(s, s.party[2], { 7, 7, 7, 7, 7, 7, 7, 7, 7 }, "ANN")
  local packed = Trade3.packMail(s, { 1, 2 })
  eq(packed[1], false, "a mon with no mail is false, so JSON keeps the positions")
  eq(packed[2] and packed[2].playerName, "ANN", "the held mail rides at its mon's position")
  local round = Trade3.unpackMailList(Json.decode(Json.encode(packed)))
  eq(round[1], nil, "false reads back as no mail")
  eq(round[2] and round[2].words[1], 7, "and the words survive the wire")
end

-- ------- who is trading

do
  local fr = Trade3.localInfo(newSession({ national = true }), "firered")
  eq(fr.version, 4, "FireRed is VERSION_FIRE_RED on the cable")
  eq(fr.family, "frlg", "in the FRLG family")
  eq(fr.progressFlags % 16, 1, "the National Dex is the progress low nibble")
  local fr2 = Trade3.localInfo(newSession({ national = true, linkRegions = true }), "firered")
  eq(math.floor(fr2.progressFlags / 16) % 16, 1,
    "FLAG_SYS_CAN_LINK_WITH_RS is the high nibble")
  local em = Trade3.localInfo(newSession({ version = "emerald", national = true,
    linkRegions = true }), "emerald")
  eq(em.version, 3, "Emerald is VERSION_EMERALD")
  eq(em.family, "rse", "in the RSE family")
  eq(em.progressFlags, 0x11, "national and champion")
end

-- The running game's session is read through the script engine's live flag
-- store even when it carries a `store` of its own: every Emerald session has
-- one (src/core/game3/time_events.lua's `{flags, vars}` fallback), and it is
-- not Space.store.  Reading it made a Champion's FireRed <-> Emerald trade
-- refuse ("You can't trade with that game yet.") in the live trip e2e.
do
  local Space = require("src.core.game3.scripting.space")
  local Runtime = package.loaded["src.core.game3.runtime"]
  local savedGet, savedStore = Runtime.getSession, Space.store
  local s = newSession({ version = "emerald", national = true })
  s.store = { flags = {}, vars = {} }
  local live = { flags = {}, vars = {} }
  live.flags[Family.flag("emerald", Family.PROGRESS_FLAG[Family.of("emerald")])] = true
  Space.store = live
  Runtime.getSession = function() return s end
  local info = Trade3.localInfo(s, "emerald")
  eq(math.floor(info.progressFlags / 16) % 16, 1,
    "the live session's champion flag comes from Space.store, not its stale store")
  local peer = newSession({ version = "emerald", national = true })
  peer.store = { flags = {}, vars = {} }
  eq(math.floor(Trade3.localInfo(peer, "emerald").progressFlags / 16) % 16, 0,
    "any other session is read as it is, its own store included")
  Runtime.getSession, Space.store = savedGet, savedStore
end

-- ------- the loopback hub

local function newPlayer(id, name, session, fingerprint, netEnd)
  local ui = { said = {}, confirms = {}, picks = {}, ctx = {}, sayDone = {} }
  function ui:say(text, onDone)
    self.said[#self.said + 1] = text
    if onDone then self.sayDone[#self.sayDone + 1] = onDone end
    return { text = text }
  end
  function ui:confirm(_, text, onChoose)
    self.asked = (self.asked or 0) + 1
    local box = { text = text, onChoose = onChoose }
    self.confirms[#self.confirms + 1] = box
    return box
  end
  function ui:choose(_, text) return { text = text } end
  function ui:pickPartyMon(_, trade, onPick)
    self.picks[#self.picks + 1] = { trade = trade, onPick = onPick }
  end
  function ui:pushState() end
  local transport = { net = netEnd, sent = {} }
  function transport:send(kind, body)
    self.sent[#self.sent + 1] = { kind = kind, body = body }
    self.net:send({ kind = kind, body = body })
    return true
  end
  function transport:isReady() return true end
  local game = { generation = 3, phase = "field", session = session,
                 data = { generation = 3 }, fingerprint = fingerprint, saves = 0 }
  function game:saveGame()
    self.saves = self.saves + 1
    return true
  end
  ui.ctx.game = game
  return { id = id, name = name, ui = ui, transport = transport, game = game,
           session = session, sessions = Sessions.new(transport, ui) }
end

-- What the hub does with a player's lines: forward the relays to the peer,
-- and tell the peer when this side leaves the pairing.
local function deliver(from, to)
  for _, msg in ipairs(to.transport.net:poll()) do
    if msg.kind == Wire.RELAY then
      to.sessions:onRelay({ from = from.id, payload = msg.body and msg.body.payload })
    elseif msg.kind == Wire.SESSION_LEAVE then
      to.sessions:onSessionEnd("peer_left")
    end
  end
end

-- A player at the controls: picks `plan.pick`, answers every confirm with
-- `plan.confirm`, dismisses every box (not with `plan.keepBoxes`).
-- `plan.beforePick(trade)` runs as the picker is answered and
-- `plan.afterConfirm(trade)` right after the confirm is -- the moments a
-- player could have the party open.
local function answer(p, plan)
  local pick = table.remove(p.ui.picks, 1)
  if pick then
    if plan.beforePick then plan.beforePick(pick.trade) end
    pick.onPick(plan.pick)
  end
  local box = table.remove(p.ui.confirms, 1)
  if box then
    box.onChoose(plan.confirm ~= false)
    if plan.afterConfirm then plan.afterConfirm() end
  end
  if plan.keepBoxes then return end
  local done = table.remove(p.ui.sayDone, 1)
  if done then done() end
end

local function trade(a, b, planA, planB, steps)
  local netA, netB = Net.loopbackPair()
  a.transport.net, b.transport.net = netA, netB
  a.sessions:onSession(a.game, { peer = b.id, peerName = b.name, kind = "trade",
                                 role = "host", id = "s1" })
  b.sessions:onSession(b.game, { peer = a.id, peerName = a.name, kind = "trade",
                                 role = "guest", id = "s1" })
  for _ = 1, steps or 40 do
    deliver(a, b)
    deliver(b, a)
    a.sessions:update(a.game, 0.25)
    b.sessions:update(b.game, 0.25)
    answer(a, planA)
    answer(b, planB)
  end
end

local function players(sessionA, sessionB, fpA, fpB)
  local a = newPlayer("p1", "ANN", sessionA, fpA or "fr", nil)
  local b = newPlayer("p2", "BOB", sessionB, fpB or "fr", nil)
  return a, b
end

-- ------- FireRed <-> FireRed: held item, mail, dex, friendship, evolution

do
  scenes, evolutions, questEvents = {}, {}, {}
  local sa = newSession({ name = "ANN", trainerId = 11, national = true,
    party = { mon(64, 20, { nickname = "KADABRA" }), mon(16, 5) } })
  local sb = newSession({ name = "BOB", trainerId = 22, national = true,
    party = { mon(25, 12, { nickname = "SPARKY" }), mon(19, 4) } })
  giveMail(sb, sb.party[1], { 1, 2, 3, 4, 5, 6, 7, 8, 9 }, "BOB")
  local kadabra, pikachu = sa.party[1], sb.party[1]
  local a, b = players(sa, sb)
  local shownA
  trade(a, b, { pick = 1, beforePick = function(t) shownA = t:entries() end },
    { pick = 1 })

  check(shownA ~= nil and #shownA == 2, "the picker is handed one row per party slot")
  local row = shownA and shownA[1] or {}
  eq(row.index, 1, "row index is the party slot")
  eq(row.name, "KADABRA", "row name is what the cart prints")
  eq(row.species, 64, "row species is the internal number")
  eq(row.level, 20, "row level")
  eq(row.iconSpecies, 64, "icon species")
  eq(row.heldItem, 0, "held item number")
  eq(row.isEgg, false, "egg flag")
  eq(row.blocked, false, "a tradeable mon is not blocked")

  eq(FakeProtocol.lastStrict, true, "every received mon is unpacked strictly")
  eq(sa.party[1].species, 25, "ANN now holds BOB's PIKACHU")
  eq(sa.party[1].nickname, "SPARKY", "nickname kept")
  eq(sa.party[1].otName, "OT", "OT kept")
  eq(sa.party[1].item, 121, "held mail item kept")
  eq(sa.party[1].friendship, 70, "friendship set to the traded 70 (trade_scene.c:1075)")
  local got = Mail.get(sa, sa.party[1].mail)
  check(got ~= nil, "the mail was installed into ANN's mail pool")
  eq(got and got.playerName, "BOB", "written by BOB")
  eq(got and got.words[9], 9, "every word arrived")
  eq(sa.dex.seen[25], true, "PIKACHU seen")
  check(Dex.isCaught(sa.dex, 25), "PIKACHU caught (HandleSetPokedexFlag)")
  eq(sa.party[2].species, 16, "the rest of ANN's party is untouched")

  eq(sb.party[1].species, 64, "BOB holds ANN's KADABRA")
  check(sb.party[1] ~= pikachu, "BOB no longer holds PIKACHU")
  eq(Mail.get(sb, 0), nil, "BOB's outgoing mail left with the mon (the slot is cleared)")
  eq(#scenes, 1, "exactly one evolution scene, on BOB's side")
  eq(scenes[1] and scenes[1].target, 65, "into ALAKAZAM")
  eq(scenes[1] and scenes[1].opts.canStop, false, "a trade evolution cannot be cancelled")
  eq(scenes[1] and scenes[1].opts.via, "trade", "and says it came from a trade")
  eq(scenes[1] and scenes[1].opts.session, sb, "on BOB's live session")
  eq(a.game.saves, 1, "ANN's trade was saved once")
  eq(b.game.saves, 1, "BOB's once before the evolution plays")
  -- The real scene applies the evolution itself and then calls back.
  if scenes[1] then
    FakeEvolution.apply(scenes[1].mon, scenes[1].target, sb, sb.bag, "trade")
    scenes[1].opts.onDone("evolved", scenes[1].mon)
  end
  eq(sb.party[1].species, 65, "the scene evolved the mon in BOB's party slot")
  eq(b.game.saves, 2, "and the evolved species is saved once it has")
  eq(kadabra.species, 64, "ANN's old table was never mutated -- the swap moved it")

  eq(#questEvents, 2, "each side logs the link trade for the quest log")
  eq(sa.gameStats and sa.gameStats[21], 1, "GAME_STAT_POKEMON_TRADES counted")
  check(contains(a.ui.said, "SPARKY was\ntraded over!"),
    "the received mon is named by its nickname, not a species number")
  eq(a.ui.asked, 1, "ANN was asked to confirm once")
  eq(b.ui.asked, 1, "and BOB once")
  eq(a.sessions.active, nil, "ANN's session settled and closed")
  eq(b.sessions.active, nil, "BOB's too")
end

-- ------- the confirm names their mon

do
  local sa = newSession({ national = true, party = { mon(16, 5), mon(19, 4) } })
  local sb = newSession({ national = true, party = { mon(25, 12, { nickname = "ZAP" }), mon(19, 4) } })
  local a, b = players(sa, sb)
  local asked
  local netA, netB = Net.loopbackPair()
  a.transport.net, b.transport.net = netA, netB
  a.sessions:onSession(a.game, { peer = "p2", peerName = "BOB", kind = "trade", role = "host", id = "s2" })
  b.sessions:onSession(b.game, { peer = "p1", peerName = "ANN", kind = "trade", role = "guest", id = "s2" })
  for _ = 1, 12 do
    deliver(a, b)
    deliver(b, a)
    a.sessions:update(a.game, 0.1)
    b.sessions:update(b.game, 0.1)
    local pa, pb = table.remove(a.ui.picks, 1), table.remove(b.ui.picks, 1)
    if pa then pa.onPick(1) end
    if pb then pb.onPick(1) end
    if a.ui.confirms[1] and not asked then asked = a.ui.confirms[1].text end
  end
  eq(asked, "Trade for\nZAP?", "the confirm names the offered mon the way the cart does")
  a.sessions:endSession(nil)
  b.sessions:endSession(nil)
end

-- ------- an Everstone refuses; a trade item is consumed

do
  scenes, evolutions = {}, {}
  local sa = newSession({ national = true,
    party = { mon(64, 20, { item = 195, heldItem = 195 }), mon(95, 30, { item = 199, heldItem = 199 }), mon(16, 5) } })
  local sb = newSession({ national = true, party = { mon(19, 4), mon(20, 22) } })
  local a, b = players(sa, sb)
  trade(a, b, { pick = 1 }, { pick = 1 })
  eq(sb.party[1].species, 64, "an EVERSTONE KADABRA stays a KADABRA")
  eq(sb.party[1].item, 195, "and keeps its EVERSTONE")
  eq(#scenes, 0, "no evolution scene")

  local sc = newSession({ national = true, party = { mon(19, 4), mon(20, 22) } })
  local a2, c = players(sa, sc)
  trade(a2, c, { pick = 2 }, { pick = 1 })
  eq(#scenes, 1, "ONIX holding a METAL COAT evolves")
  eq(scenes[1] and scenes[1].target, 208, "into STEELIX")
  eq(sc.party[1].item, 0, "and the METAL COAT is used up, as the cart uses it")
end

-- ------- strict refusal of a malformed mon

do
  local sa = newSession({ national = true, party = { mon(16, 5), mon(19, 4) } })
  local sb = newSession({ national = true, party = { mon(999, 5), mon(19, 4) } })
  local before = sa.party[1]
  local a, b = players(sa, sb)
  trade(a, b, { pick = 1 }, { pick = 2 })
  check(contains(a.ui.said, "The trade stopped:\nunknown species"),
    "a mon the cart would not rebuild stops the trade, naming why")
  eq(sa.party[1], before, "nothing was applied")
  eq(a.game.saves, 0, "and nothing saved")
  eq(a.sessions.active, nil, "the session is gone")
  eq(b.sessions.active, nil, "on both sides")
end

-- ------- the National Dex rules

do
  -- Sender: a FireRed without the National Dex cannot offer a Hoenn mon.
  local s = newSession({ party = { mon(277, 10), mon(16, 5) } })
  local t = Trade3.TradeSession.new({ generation = 3, session = s, data = {} }, {})
  check(t:refusal(1) ~= nil, "no National Dex: a Hoenn mon cannot be offered")
  eq(t:canPick(1), false, "so the picker greys it")
  check(t.reasons[1] ~= nil, "and has the cart's reason for it")
  eq(t:refusal(2), nil, "a Kanto mon can be")
  local rows = t:entries()
  eq(rows[1].blocked, true, "entries mark the Hoenn mon blocked")
  eq(rows[1].reason, t.reasons[1], "with the same reason")

  -- The last mon able to battle stays behind.
  local lone = newSession({ party = { mon(16, 5), mon(19, 4, { hp = 0 }) } })
  local t2 = Trade3.TradeSession.new({ generation = 3, session = lone, data = {} }, {})
  check(t2:refusal(1) ~= nil, "the only healthy mon cannot be offered")

  -- Partner: a FireRed WITH the National Dex cannot send a Hoenn mon to a
  -- partner who has not got one (the partner's progress low nibble).
  local sa = newSession({ national = true, party = { mon(277, 10), mon(16, 5) } })
  local sb = newSession({ party = { mon(19, 4), mon(20, 22) } })
  local ta = Trade3.TradeSession.new({ generation = 3, session = sa, data = {} }, {})
  local tb = Trade3.TradeSession.new({ generation = 3, session = sb, data = {} }, {})
  ta:handle(Json.decode(Json.encode(tb:partyMessage())))
  tb:handle(Json.decode(Json.encode(ta:partyMessage())))
  eq(ta.stage, "picking", "both parties exchanged")
  check(ta:refusal(1) ~= nil, "a partner without the National Dex cannot be offered a Hoenn mon")
  eq(ta:refusal(2), nil, "but can be offered a Kanto one")

  -- Receiver: the same rule on the far side, for a peer that skipped its own
  -- check.  BOB (no National Dex) is picked a Hoenn mon anyway.
  tb:handle({ type = "pick", index = 1 })
  tb:pick(1)
  check(tb:theirRefusal() ~= nil, "the receiving cart refuses a mon it may not take")
  local reply = tb:confirm(true)
  eq(reply.ok, false, "and a yes is answered no on the player's behalf")
  check(tb.error ~= nil, "with the cart's reason kept")
end

do
  -- ...and through Sessions: ANN's build skips the rule, BOB's cart says no.
  local sa = newSession({ name = "ANN", national = true, party = { mon(277, 10), mon(16, 5) } })
  local sb = newSession({ name = "BOB", party = { mon(19, 4), mon(20, 22) } })
  local a, b = players(sa, sb)
  local bobBefore, annBefore = sb.party[1], sa.party[1]
  trade(a, b, { pick = 1, beforePick = function(t) t.refusal = false end }, { pick = 1 })
  check(contains(b.ui.said, "The trade stopped:"),
    "BOB is told the trade stopped, not asked to agree to it")
  eq(b.ui.asked, nil, "no yes / no was ever put to BOB")
  eq(sb.party[1], bobBefore, "BOB's party is untouched")
  eq(sa.party[1], annBefore, "and so is ANN's")
  eq(a.game.saves + b.game.saves, 0, "nothing was saved on either side")
end

-- ------- event-only MEW / DEOXYS

do
  local sa = newSession({ national = true,
    party = { mon(151, 30, { fatefulEncounter = false }), mon(16, 5) } })
  local sb = newSession({ national = true, party = { mon(19, 4), mon(20, 22) } })
  local ta = Trade3.TradeSession.new({ generation = 3, session = sa, data = {} }, {})
  local tb = Trade3.TradeSession.new({ generation = 3, session = sb, data = {} }, {})
  ta:handle(Json.decode(Json.encode(tb:partyMessage())))
  tb:handle(Json.decode(Json.encode(ta:partyMessage())))
  check(ta:refusal(1) ~= nil, "a MEW that is not from the event cannot be offered")
  tb:handle({ type = "pick", index = 1 })
  tb:pick(1)
  check(tb:theirRefusal() ~= nil, "nor received")
  sa.party[1].fatefulEncounter = true
  eq(ta:refusal(1), nil, "an event MEW can")
end

-- ------- FireRed <-> Emerald

do
  local original = Family.gameProgressForLinkTrade
  local helpers = {
    { name = "engine rules", fn = original },
    { name = "missing helper" },
    { name = "failed helper", fn = function() error("unavailable") end },
    { name = "empty answer", fn = function() return nil end },
  }
  for _, helper in ipairs(helpers) do
    Family.gameProgressForLinkTrade = helper.fn
    for _, mine in ipairs({ "firered", "leafgreen", "emerald" }) do
      for _, theirs in ipairs({ "firered", "leafgreen", "emerald" }) do
        for _, mineReady in ipairs({ false, true }) do
          for _, theirsReady in ipairs({ false, true }) do
            local s = newSession({ version = mine, national = true, linkRegions = mineReady })
            local peer = newSession({ version = theirs, national = true, linkRegions = theirsReady })
            local tr = Trade3.TradeSession.new({ session = s })
            tr.theirInfo = Trade3.sanitizeInfo(Trade3.localInfo(peer, theirs))
            local expected
            if Family.of(mine) ~= Family.of(theirs) then
              if not mineReady then expected = "You can't trade\nwith that game yet."
              elseif not theirsReady then expected = "The other game\ncan't trade with\nyou yet." end
            end
            eq(tr:versionGate(), expected,
              helper.name .. ": " .. mine .. " -> " .. theirs
                .. " readiness " .. tostring(mineReady) .. "/" .. tostring(theirsReady))
          end
        end
      end
    end
  end
  Family.gameProgressForLinkTrade = original
end

-- localInfo's last resort (localLinkPlayer missing, or it throws) rebuilds
-- the high nibble from Family.canLinkNationally, so the gate -- which
-- enforces that nibble whatever gameProgressForLinkTrade says -- still lets
-- an unlocked save across and still stops a locked one.  When even that
-- cannot answer, the side is marked linkUnknown (it rides the wire) and is
-- not refused for a nibble nobody could read.
do
  local originalLLP, originalCan = Family.localLinkPlayer, Family.canLinkNationally
  local paths = {
    { name = "missing localLinkPlayer" },
    { name = "throwing localLinkPlayer", fn = function() error("unavailable") end },
  }
  for _, path in ipairs(paths) do
    Family.localLinkPlayer = path.fn
    for _, pair in ipairs({ { "firered", "emerald" }, { "emerald", "leafgreen" } }) do
      for _, ready in ipairs({ false, true }) do
        local s = newSession({ version = pair[1], national = true, linkRegions = ready })
        local peer = newSession({ version = pair[2], national = true, linkRegions = true })
        local me = Trade3.localInfo(s, pair[1])
        eq(me.progressFlags, ready and 0x11 or 0x01,
          path.name .. ": " .. pair[1] .. " rebuilds both nibbles, unlocked " .. tostring(ready))
        eq(me.linkUnknown, nil, path.name .. ": the unlock was read, so it is known")
        local tr = Trade3.TradeSession.new({ session = s })
        tr.theirInfo = Trade3.sanitizeInfo(Json.decode(Json.encode(Trade3.localInfo(peer, pair[2]))))
        eq(tr:versionGate(), (not ready) and "You can't trade\nwith that game yet." or nil,
          path.name .. ": " .. pair[1] .. " -> " .. pair[2] .. " unlocked " .. tostring(ready))
        -- And the same save as the partner: a locked one is the other side's refusal.
        local other = Trade3.TradeSession.new({ session = peer })
        other.theirInfo = Trade3.sanitizeInfo(Json.decode(Json.encode(me)))
        eq(other:versionGate(), (not ready) and "The other game\ncan't trade with\nyou yet." or nil,
          path.name .. ": " .. pair[2] .. " <- " .. pair[1] .. " unlocked " .. tostring(ready))
      end
    end
  end

  -- Neither helper answers: the unlock is unknown, said so on the wire, and
  -- not held against either side -- while a known, locked partner still is.
  Family.localLinkPlayer = nil
  Family.canLinkNationally = function() error("unavailable") end
  local s = newSession({ version = "firered", national = true })
  local me = Trade3.localInfo(s, "firered")
  eq(me.progressFlags, 0x01, "no unlock could be read: the low nibble alone")
  eq(me.linkUnknown, true, "and the info says the unlock is unknown")
  local wire = Json.decode(Json.encode(Trade3.TradeSession.new({ session = s }):partyMessage().gen3))
  eq(wire.linkUnknown, true, "linkUnknown rides the party message")
  eq(Trade3.sanitizeInfo(wire).linkUnknown, true, "and survives sanitizeInfo")
  eq(Trade3.sanitizeInfo({ version = 4, progressFlags = 1, linkUnknown = "yes" }).linkUnknown, nil,
    "only a literal true reads as unknown")
  local tr = Trade3.TradeSession.new({ session = s })
  Family.canLinkNationally = originalCan
  tr.theirInfo = Trade3.sanitizeInfo(Trade3.localInfo(
    newSession({ version = "emerald", national = true, linkRegions = true }), "emerald"))
  eq(tr:versionGate(), nil, "an unknown unlock on this side is not refused")
  tr.theirInfo = Trade3.sanitizeInfo(Trade3.localInfo(
    newSession({ version = "emerald", national = true }), "emerald"))
  eq(tr:versionGate(), "The other game\ncan't trade with\nyou yet.",
    "a known, locked partner still is")
  local em = Trade3.TradeSession.new({
    session = newSession({ version = "emerald", national = true, linkRegions = true }) })
  em.theirInfo = Trade3.sanitizeInfo(wire)
  eq(em:versionGate(), nil, "and a partner whose unlock is unknown is not refused either")
  Family.localLinkPlayer, Family.canLinkNationally = originalLLP, originalCan
end

do
  -- Before FireRed may link with the other region: both sides refuse.
  local sa = newSession({ name = "ANN", national = true, party = { mon(16, 5), mon(19, 4) } })
  local sb = newSession({ name = "MAY", version = "emerald", national = true, linkRegions = true,
    party = { mon(277, 10), mon(19, 4) } })
  local before = sa.party[1]
  local a, b = players(sa, sb, "fr", "em")
  trade(a, b, { pick = 1 }, { pick = 1 })
  check(contains(a.ui.said, "The trade stopped:\nYou can't trade\nwith that game yet."),
    "FireRed short of FLAG_SYS_CAN_LINK_WITH_RS cannot trade with Emerald")
  check(contains(b.ui.said, "The trade stopped:\nThe other game\ncan't trade with\nyou yet."),
    "and Emerald is told it is the other side")
  eq(sa.party[1], before, "nothing changed hands")

  -- Once it may: a Hoenn mon crosses from Emerald, a Kanto one the other way.
  local sc = newSession({ name = "ANN", national = true, linkRegions = true,
    party = { mon(16, 5, { nickname = "PIDGE" }), mon(19, 4) } })
  local sd = newSession({ name = "MAY", version = "emerald", national = true, linkRegions = true,
    party = { mon(277, 10, { nickname = "LEAFY" }), mon(19, 4) } })
  local c, d = players(sc, sd, "fr", "em")
  trade(c, d, { pick = 1 }, { pick = 1 })
  eq(sc.party[1].species, 277, "the FireRed now holds Emerald's TREECKO")
  eq(sc.party[1].nickname, "LEAFY", "nickname intact")
  eq(sd.party[1].species, 16, "and Emerald holds the PIDGEY")
  eq(sc.dex.seen[277], true, "TREECKO is in FireRed's dex")
  eq(sd.dex.seen[16], true, "PIDGEY in Emerald's")
end

-- ------- the party the peer saw is the party that trades
--
-- The party message is packed at opening(); the picker and the confirm wait
-- for the cart's menus (Ui.occupied), where START > POKéMON can reorder the
-- party and the BAG can take a held item.  Trading by slot number then sent
-- the peer the snapshot mon while removing whatever stood at that slot now.

local function count(list, species)
  local n = 0
  for _, m in ipairs(list) do if m.species == species then n = n + 1 end end
  return n
end

do
  -- Reordered while the picker waited: the row the player picks is mapped
  -- to the index the peer was shown, and that very mon is the one that goes.
  local sa = newSession({ name = "ANN", national = true,
    party = { mon(64, 20, { nickname = "KADABRA" }), mon(16, 5, { nickname = "PIDGEY" }) } })
  local sb = newSession({ name = "BOB", national = true, party = { mon(25, 12), mon(19, 4) } })
  local a, b = players(sa, sb)
  local sentWire
  trade(a, b, { pick = 1, beforePick = function(t)
      -- START > POKéMON > SWITCH: PIDGEY to the front
      sa.party[1], sa.party[2] = sa.party[2], sa.party[1]
    end }, { pick = 1 })
  for _, entry in ipairs(a.transport.sent) do
    local payload = entry.body and entry.body.payload
    if type(payload) == "table" and payload.type == "pick" then sentWire = payload.index end
  end
  eq(sentWire, 2, "a pick of PIDGEY (now first) names it by the index BOB was shown")
  eq(sb.party[1].species, 16, "BOB received the PIDGEY ANN picked")
  eq(count(sa.party, 64), 1, "ANN still has her KADABRA")
  eq(count(sa.party, 16), 0, "and the PIDGEY left her party")
  eq(count(sb.party, 64), 0, "no KADABRA was copied into BOB's party")
  eq(sa.party[1].species, 25, "BOB's PIKACHU landed where the PIDGEY stood")
end

do
  -- A mon the peer was never shown (withdrawn from the PC while the picker
  -- waited) cancels the trade on both sides; nothing moves.
  local sa = newSession({ name = "ANN", national = true, party = { mon(64, 20), mon(16, 5) } })
  local sb = newSession({ name = "BOB", national = true, party = { mon(25, 12), mon(19, 4) } })
  local annBefore, bobBefore = sa.party[2], sb.party[1]
  local a, b = players(sa, sb)
  trade(a, b, { pick = 1, beforePick = function()
      sa.party[1] = mon(150, 70)   -- the PC swap: KADABRA out, MEWTWO in
    end }, { pick = 1 })
  check(contains(a.ui.said, "The trade stopped:\n" .. tostring(Trade3.PARTY_CHANGED)),
    "ANN is told her party changed")
  eq(sa.party[1].species, 150, "ANN keeps the MEWTWO")
  eq(sa.party[2], annBefore, "and the rest of her party")
  eq(sb.party[1], bobBefore, "BOB's party is untouched")
  eq(count(sb.party, 150) + count(sb.party, 64), 0, "BOB received nothing")
  eq(a.game.saves + b.game.saves, 0, "nothing was saved on either side")
  eq(a.sessions.active, nil, "ANN's session ended")
  eq(b.sessions.active, nil, "and BOB's")
end

do
  -- A held item taken off after the snapshot: the mon BOB was shown holds a
  -- NUGGET (110) that is back in ANN's BAG -- trading it would copy the item.
  local sa = newSession({ name = "ANN", national = true,
    party = { mon(64, 20, { item = 110, heldItem = 110 }), mon(16, 5) } })
  local sb = newSession({ name = "BOB", national = true, party = { mon(25, 12), mon(19, 4) } })
  local a, b = players(sa, sb)
  trade(a, b, { pick = 1, beforePick = function()
      sa.party[1].item, sa.party[1].heldItem = 0, 0
    end }, { pick = 1 })
  check(contains(a.ui.said, "The trade stopped:\n" .. tostring(Trade3.PARTY_CHANGED)),
    "a mon that lost its held item since BOB saw it is not traded")
  eq(count(sb.party, 64), 0, "BOB did not receive the KADABRA (nor the NUGGET it no longer holds)")
  eq(sa.party[1].species, 64, "ANN keeps it")
end

do
  -- Changed after the pick (the belt under Sessions' hold): moved, it is
  -- found by identity -- the yes stands and the right mon goes; gone, the
  -- yes becomes a no.
  local sa = newSession({ national = true, party = { mon(64, 20), mon(16, 5), mon(19, 4) } })
  local sb = newSession({ national = true, party = { mon(25, 12), mon(20, 22) } })
  local ta = Trade3.TradeSession.new({ generation = 3, session = sa, data = {} }, {})
  local tb = Trade3.TradeSession.new({ generation = 3, session = sb, data = {} }, {})
  local wire = function(m) return Json.decode(Json.encode(m)) end
  tb:handle(wire(ta:opening()))
  ta:handle(wire(tb:opening()))
  local kadabra = sa.party[1]
  tb:handle(wire(ta:pick(1)))
  ta:handle(wire(tb:pick(1)))
  eq(ta.stage, "confirming", "both picked")
  sa.party[1], sa.party[3] = sa.party[3], sa.party[1]
  local yes = ta:confirm(true)
  eq(yes.ok, true, "a picked mon that only moved keeps the yes")
  eq(yes.mine, 1, "the yes names ANN's pick as BOB knows it")
  eq(yes.yours, 1, "and BOB's pick as ANN understood it")
  tb:handle(wire(yes))
  ta:handle(wire(tb:confirm(true)))
  eq(ta.stage, "done", "both said yes")
  local got = ta:apply({ generation = 3, session = sa })
  eq(got and got.species, 25, "ANN received the PIKACHU")
  eq(ta.appliedSlot, 3, "into the slot the KADABRA had moved to")
  eq(sa.party[3].species, 25, "which now holds it")
  eq(count(sa.party, 64), 0, "and the KADABRA -- the mon BOB was shown -- is what left")
  check(sa.party[1] ~= kadabra, "slot 1 (the RATTATA) was not touched")
  eq(sa.party[1].species, 19, "slot 1 still holds the RATTATA")

  local sc = newSession({ national = true, party = { mon(64, 20), mon(16, 5) } })
  local tc = Trade3.TradeSession.new({ generation = 3, session = sc, data = {} }, {})
  local td = Trade3.TradeSession.new({ generation = 3, session = newSession({ national = true,
    party = { mon(25, 12), mon(20, 22) } }), data = {} }, {})
  td:handle(wire(tc:opening()))
  tc:handle(wire(td:opening()))
  td:handle(wire(tc:pick(1)))
  tc:handle(wire(td:pick(1)))
  table.remove(sc.party, 1)                 -- deposited after the pick
  local no = tc:confirm(true)
  eq(no.ok, false, "a picked mon no longer in the party turns the yes into a no")
  eq(tc.error, Trade3.PARTY_CHANGED, "saying why")

  -- ...and an apply that cannot find the mon it sent sends nothing.
  local se = newSession({ national = true, party = { mon(64, 20), mon(16, 5) } })
  local te = Trade3.TradeSession.new({ generation = 3, session = se, data = {} }, {})
  local tf = Trade3.TradeSession.new({ generation = 3, session = newSession({ national = true,
    party = { mon(25, 12), mon(20, 22) } }), data = {} }, {})
  tf:handle(wire(te:opening()))
  te:handle(wire(tf:opening()))
  tf:handle(wire(te:pick(1)))
  te:handle(wire(tf:pick(1)))
  te:handle(wire(tf:confirm(true)))
  tf:handle(wire(te:confirm(true)))
  eq(te.stage, "done", "done")
  se.party[1] = mon(150, 70)
  local before = #warns
  eq(te:apply({ generation = 3, session = se }), nil, "apply finds no KADABRA and applies nothing")
  eq(se.party[1].species, 150, "the MEWTWO standing in its slot is not traded away")
  check(#warns > before and contains({ warns[#warns] }, "no longer in the party"), "and says so")
end

do
  -- The failed apply reads as a failure: "The trade failed to complete.",
  -- never "a POKéMON was traded over!" about a mon that never arrived.
  local sa = newSession({ name = "ANN", national = true, party = { mon(64, 20), mon(16, 5) } })
  local sb = newSession({ name = "BOB", national = true, party = { mon(25, 12), mon(19, 4) } })
  local a, b = players(sa, sb)
  trade(a, b, { pick = 1, afterConfirm = function()
      -- the whole party replaced between ANN's yes and BOB's (a harness can;
      -- the hold stops a player)
      sa.party = { mon(150, 70) }
    end }, { pick = 1 })
  check(contains(a.ui.said, "The trade failed\nto complete."), "ANN is told the trade failed")
  check(not contains(a.ui.said, "traded over!"), "and not that something was traded over")
  eq(a.game.saves, 0, "nothing was saved for a swap that never happened")
end

-- ------- the other side's messages, in order and once

do
  local wire = function(m) return Json.decode(Json.encode(m)) end
  local function pair()
    local ta = Trade3.TradeSession.new({ generation = 3, session = newSession({ national = true,
      party = { mon(64, 20), mon(16, 5) } }), data = {} }, {})
    local tb = Trade3.TradeSession.new({ generation = 3, session = newSession({ national = true,
      party = { mon(25, 12), mon(19, 4) } }), data = {} }, {})
    tb:handle(wire(ta:opening()))
    ta:handle(wire(tb:opening()))
    return ta, tb
  end

  -- a second pick would swap the mon under the "Trade for X?" being read
  local ta = pair()
  ta:handle({ type = "pick", index = 1 })
  eq(ta.stage, "picking", "their first pick is taken")
  ta:handle({ type = "pick", index = 2 })
  eq(ta.stage, "cancelled", "a second pick cancels")
  eq(ta.error, Trade3.OUT_OF_TURN, "as out of turn")
  eq(ta.theirPick, 1, "and never replaces the first")

  local early = Trade3.TradeSession.new({ generation = 3, session = newSession({ national = true,
    party = { mon(64, 20), mon(16, 5) } }), data = {} }, {})
  early:handle({ type = "pick", index = 1 })
  eq(early.stage, "cancelled", "a pick before their party cancels")

  local tc = pair()
  tc:pick(1)
  tc:handle({ type = "pick", index = 1 })
  eq(tc.stage, "confirming", "both picks in")
  tc:handle({ type = "pick", index = 2 })
  eq(tc.stage, "cancelled", "a pick while confirming cancels")

  -- a yes to another pair is no yes
  local td, te = pair()
  te:handle(wire(td:pick(1)))
  td:handle(wire(te:pick(2)))
  td:handle({ type = "confirm", ok = true, mine = 1, yours = 1 })
  eq(td.stage, "cancelled", "a yes naming a mon they did not pick cancels")
  eq(td.error, Trade3.OFFER_CHANGED, "the offer changed")
  local tf, tg = pair()
  tg:handle(wire(tf:pick(1)))
  tf:handle(wire(tg:pick(2)))
  tf:handle({ type = "confirm", ok = true, mine = 2, yours = 2 })
  eq(tf.stage, "cancelled", "a yes to a different mon of ours cancels")
  local th, ti = pair()
  ti:handle(wire(th:pick(1)))
  th:handle(wire(ti:pick(2)))
  th:handle({ type = "confirm", ok = true })
  eq(th.stage, "cancelled", "a yes that names nothing is no yes")
  local tj, tk = pair()
  tk:handle(wire(tj:pick(2)))
  tj:handle(wire(tk:pick(1)))
  tj:handle(wire(tk:confirm(true)))
  eq(tj.theirConfirm, true, "a yes naming the agreed pair stands")
  local reply = tj:confirm(true)
  eq(reply.mine, 2, "and ours names our pick")
  eq(reply.yours, 1, "and theirs")
  eq(tj.stage, "done", "done")
  tj:handle({ type = "bye" })
  eq(tj.stage, "done", "a goodbye after both yeses does not take this side's half back")
  tj:handle({ type = "confirm", ok = false })
  eq(tj.stage, "done", "nor does a late no")

  local tl = pair()
  tl:handle({ type = "confirm", ok = true, mine = 1, yours = 1 })
  eq(tl.stage, "cancelled", "a confirm before the picks cancels")
  local tm, tn = pair()
  tn:handle(wire(tm:pick(1)))
  tm:handle(wire(tn:pick(1)))
  tm:handle({ type = "confirm", ok = false })
  eq(tm.theirConfirm, false, "their no")
  tm:handle({ type = "confirm", ok = true, mine = 1, yours = 1 })
  eq(tm.stage, "cancelled", "a second confirm cancels")
end

-- ------- names the cart can print; a cart the cable club knows

do
  local wire = function(m) return Json.decode(Json.encode(m)) end
  local function offer(party, tamper)
    local them = Trade3.TradeSession.new({ generation = 3, session = newSession({ national = true,
      party = party }), data = {} }, {})
    local me = Trade3.TradeSession.new({ generation = 3, session = newSession({ national = true,
      party = { mon(16, 5), mon(19, 4) } }), data = {} }, {})
    local msg = wire(them:opening())
    if tamper then tamper(msg) end
    me:handle(msg)
    return me
  end
  eq(offer({ mon(25, 12, { nickname = "SPARKY" }), mon(19, 4) }).stage, "picking",
    "a plain nickname is taken")
  eq(offer({ mon(25, 12, { nickname = "PIKA♂é" }), mon(19, 4) }).stage, "picking",
    "so are the cart's own symbols")
  for _, bad in ipairs({ "{PLAYER}", "A[B", "B}", "#1", "*", "@", "~", "|", "^", "`", "A\\B" }) do
    local me = offer({ mon(25, 12, { nickname = bad }), mon(19, 4) })
    eq(me.stage, "cancelled", ("a nickname holding %q refuses the trade"):format(bad))
  end
  local me = offer({ mon(25, 12), mon(19, 4) }, function(msg) msg.mons[2].otName = "{COLOR RED}" end)
  eq(me.stage, "cancelled", "an OT name holding markup refuses the trade")
  eq(me.error, Trade3.BAD_NAME, "saying the name cannot be printed")
  eq(me.theirParty, nil, "and nothing of theirs is kept")
  local mailed = offer({ mon(25, 12, { item = 121, heldItem = 121 }), mon(19, 4) }, function(msg)
    msg.mail = { { itemId = 121, words = { 1 }, playerName = "B{O}B", trainerId = 1, species = 25 }, false }
  end)
  eq(mailed.stage, "cancelled", "a mail signed with markup refuses the trade")
  eq(Trade3.printableName and Trade3.printableName("RED"), true, "printableName: a cart name")
  eq(Trade3.printableName and Trade3.printableName(nil), true, "printableName: no name")
  eq(Trade3.printableName and Trade3.printableName("{"), false, "printableName: a brace")

  eq((Trade3.sanitizeInfo({ version = 4, progressFlags = 1 }) or {}).version, 4, "FireRed is a cart")
  eq((Trade3.sanitizeInfo({ version = 3 }) or {}).version, 3, "and Emerald")
  eq((Trade3.sanitizeInfo({ version = 5 }) or {}).version, 5, "and LeafGreen")
  eq(Trade3.sanitizeInfo({ version = 99 }), nil, "a cart code no family owns is no answer")
  eq(Trade3.sanitizeInfo({ version = 0 }), nil, "nor is 0")
  local odd = offer({ mon(25, 12), mon(19, 4) }, function(msg) msg.gen3.version = 7 end)
  eq(odd.stage, "cancelled", "a party from a cart no family owns cancels")
  eq(odd.error, Trade3.NO_CART, "saying the other game did not say which it is")
  local silent = offer({ mon(25, 12), mon(19, 4) }, function(msg) msg.gen3 = nil end)
  eq(silent.stage, "cancelled", "and so does one that says nothing about its cart")
end

-- ------- Sessions holds the screen from the pick until the trade is done

do
  local sa = newSession({ name = "ANN", national = true, party = { mon(64, 20), mon(16, 5) } })
  local sb = newSession({ name = "BOB", national = true, party = { mon(25, 12), mon(19, 4) } })
  local a, b = players(sa, sb)
  local log, holds = {}, {}
  function a.ui:holdScreen(_, text)
    local box = { hold = true, text = text }
    holds[#holds + 1] = box
    log[#log + 1] = "hold"
    return box
  end
  a.ui.pop = function(_, target)
    if target and target.hold then log[#log + 1] = "release" end
    return true
  end
  local baseSay = a.ui.say
  function a.ui:say(text, onDone)
    log[#log + 1] = "say:" .. text
    return baseSay(self, text, onDone)
  end
  trade(a, b, { pick = 1 }, { pick = 1 })
  eq(#holds, 1, "the pick puts one hold up")
  eq(holds[1] and holds[1].text, "Waiting for\nBOB...", "naming who is being waited on")
  eq(table.concat(log, ","), "hold,release,say:SPECIES25 was\ntraded over!",
    "it stays until the swap is saved, and the line goes up in its place")

  -- a trade called off after the pick takes the hold down with the session
  local sc = newSession({ name = "ANN", national = true, party = { mon(64, 20), mon(16, 5) } })
  local sd = newSession({ name = "BOB", national = true, party = { mon(25, 12), mon(19, 4) } })
  local c, d = players(sc, sd)
  local released = 0
  function c.ui:holdScreen() return { hold = true } end
  c.ui.pop = function(_, target) if target and target.hold then released = released + 1 end return true end
  trade(c, d, { pick = 1 }, { pick = 1, confirm = false })
  eq(released, 1, "a no after the pick takes the hold down")
  eq(c.sessions.active, nil, "with the session")

  -- off Gen 3 (a ui with no holdScreen) nothing is held
  local se = newSession({ national = true, party = { mon(64, 20), mon(16, 5) } })
  local sf = newSession({ national = true, party = { mon(25, 12), mon(19, 4) } })
  local e, f = players(se, sf)
  trade(e, f, { pick = 1 }, { pick = 1 })
  eq(se.party[1].species, 25, "a ui without holdScreen still trades")
end

-- ------- the evolution belongs to the save the trade was made in

do
  scenes = {}
  local sa = newSession({ name = "ANN", national = true, party = { mon(16, 5), mon(19, 4) } })
  local sb = newSession({ name = "BOB", national = true, party = { mon(64, 20), mon(20, 22) } })
  local a, b = players(sa, sb)
  trade(a, b, { pick = 1, keepBoxes = true }, { pick = 1 })
  eq(sa.party[1].species, 64, "ANN received the KADABRA")
  eq(a.game.saves, 1, "and it was saved")
  local owed = table.remove(a.ui.sayDone, 1)
  check(owed ~= nil, "the \"traded over!\" line is still up")
  -- a reset to the title and CONTINUE of another file, before it is read
  local other = newSession({ name = "CAL", national = true, party = { mon(16, 5) } })
  a.game.session = other
  local before = #warns
  if owed then owed() end
  eq(#scenes, 0, "the evolution does not play under another save")
  eq(a.game.saves, 1, "and nothing writes that save")
  check(#warns > before and contains({ warns[#warns] }, "different save"), "the log says why")
  eq(other.party[1].species, 16, "the other save's party is untouched")
end

-- ------- the Gen 3 screen stack (no game.stack)

do
  Stack.clear()
  local s = Sessions.new({ send = function() return true end }, {})
  local g3 = { generation = 3, phase = "field", session = {} }
  local box = { kind = "confirm" }
  local over = { kind = "text" }
  function over.exit(self) self.exited = true end
  Stack.push("rby_mmo:CONFIRM", box, {})
  Stack.push("rby_mmo:TEXT", over, {})
  eq(s:onStack(g3, box), true, "a held box is found on the Gen 3 stack")
  eq(s:onStack(g3, { kind = "stranger" }), false, "and one that is not, is not")
  check(s:unwindTo(g3, box, true), "unwinding to it succeeds")
  eq(Stack.depth(), 0, "everything above it and the box itself are gone")
  eq(over.exited, true, "the layer above got its exit, as StateStack:pop gives one")
  eq(s:onStack(g3, box), false, "the box is now reported gone")
  eq(s:unwindTo(g3, box, true), false, "and unwinding to a gone box does nothing")

  -- A wrapper layer that keeps the widget it draws is looked into.
  local inner = { kind = "confirm" }
  Stack.push("rby_mmo:CONFIRM", { screen = inner }, {})
  eq(s:onStack(g3, inner), true, "a box inside a wrapper layer is found")
  Stack.clear()

  -- Fights: this mod's (a layer marked mmoBattle) and the cart's own.
  eq(Sessions.stackHasFight(g3), false, "nothing on screen is no fight")
  local fight = { mmoBattle = true }
  Stack.push("rby_mmo:STATE", { state = fight }, {})
  eq(Sessions.stackHasFight(g3), true, "a mediated fight layer is a fight")
  Stack.clear()
  battleActive = true
  eq(Sessions.stackHasFight(g3), true, "the cart's own battle is a fight")
  battleActive = false

  -- dropLocalFight takes a discarded fight's layer down.
  local dropped = { mmoBattle = true, game = g3, finished = true }
  Stack.push("rby_mmo:STATE", dropped, {})
  s.fight = dropped
  s:dropLocalFight()
  eq(Stack.depth(), 0, "a dropped fight's screen comes off the Gen 3 stack")

  -- An invite box that vanished without an answer is a no.
  local sent = {}
  local s2 = Sessions.new({ send = function(_, kind, body) sent[#sent + 1] = { kind = kind, body = body } return true end }, {})
  local ask = { kind = "confirm" }
  Stack.push("rby_mmo:CONFIRM", ask, {})
  s2.incoming = { from = "p9", name = "EVE", kind = "trade" }
  s2.incomingBox = { box = ask, game = g3 }
  s2:waitOutRequest(g3, 0.1)
  eq(#sent, 0, "a box still up is not answered")
  Stack.clear()
  s2:waitOutRequest(g3, 0.1)
  eq(sent[1] and sent[1].kind, Wire.RESPOND, "a box gone from the Gen 3 stack is answered")
  eq(sent[1] and sent[1].body.accept, false, "with a no")

  -- With src/Ui.lua's doors on the ui (Ui.holds / Ui.unwindTo / Ui.pop, which
  -- src/Gen3Ui.lua answers on a Gen 3 boot), Sessions asks them.
  local okUi, Gen3Ui = pcall(need, "Gen3Ui")
  check(okUi and type(Gen3Ui) == "table", "src/Gen3Ui.lua loads for the door check")
  if okUi and type(Gen3Ui) == "table" and Gen3Ui.pushScreen then
    Stack.clear()
    local asked = {}
    local doors = {
      holds = function(game, target) asked[#asked + 1] = "holds" return Gen3Ui.has(target) end,
      unwindTo = function(game, target, alsoPop)
        asked[#asked + 1] = "unwindTo"
        return Gen3Ui.unwindTo(game, target, alsoPop)
      end,
      pop = function(game, target) asked[#asked + 1] = "pop" return Gen3Ui.pop(game, target) end,
    }
    local s3 = Sessions.new({ send = function() return true end }, doors)
    local held = { draw = function() end }
    local above = { draw = function() end }
    function above.exit(self) self.exited = true end
    Gen3Ui.pushScreen(g3, "RbyMmoConfirm", held)
    Gen3Ui.pushScreen(g3, "RbyMmoText", above)
    eq(s3:onStack(g3, held), true, "a Gen3Ui box is found through Ui.holds")
    check(s3:unwindTo(g3, held, true), "and unwound through Ui.unwindTo")
    eq(Stack.depth(), 0, "both layers are gone")
    eq(above.exited, true, "with the screen above given its exit by Gen3Ui")
    eq(asked[1], "holds", "Ui.holds was asked")
    eq(asked[2], "unwindTo", "Ui.unwindTo did the unwinding")
    local fight3 = { mmoBattle = true, game = g3, finished = true }
    Gen3Ui.pushState(g3, fight3)
    eq(Sessions.stackHasFight(g3), true, "a fight Gen3Ui.pushState put up is a fight")
    s3.fight = fight3
    s3:dropLocalFight()
    eq(asked[#asked], "pop", "a dropped fight is taken down through Ui.pop")
    eq(Stack.depth(), 0, "and is gone")
    Stack.clear()
  end
end

-- ------- saving on Gen 3

do
  local s = Sessions.new({}, {})
  local before = #warns
  eq(s:saveTrade({ generation = 3, saveGame = function() return nil end }), true,
    "Game3:saveGame answering nil (nothing to refuse) reads as written")
  eq(s:saveTrade({ generation = 3, saveGame = function() return false end }), false,
    "a refused Gen 3 save is reported")
  eq(#warns, before + 1, "in one line")
  check(warns[#warns]:find("START") ~= nil, "naming somewhere the player can go")
end

-- ------- moves a fight banked, on Gen 3
--
-- Through src/LearnMove.lua's Gen 3 arm (LearnMove.open): the cart's own
-- LearnMove.begin, handed *this mod's* boxes -- the Sessions ui's say and
-- confirm -- and the summary screen's move picker, in the field's wording.
-- Never the engine's Message / Choice singletons: an evolution scene drives
-- those too, and the two running at once lost callbacks and dropped learns.

do
  local begun, forgets = {}, {}
  local messageShown, choiceAsked = 0, 0
  stub("src.core.game3.battle.learn_move", {
    begin = function(opts) begun[#begun + 1] = opts end,
  })
  stub("src.ui.game3.message", {
    show = function() messageShown = messageShown + 1 end,
    isOpen = function() return false end,
  })
  stub("src.ui.game3.choice", { yesNo = function() choiceAsked = choiceAsked + 1 end })
  stub("src.ui.game3.summary_menu", {
    openMenu = function(party, index, opts) forgets[#forgets + 1] = { party = party, index = index, opts = opts } end,
  })
  local needL = newNeed()
  local SessionsL = needL("Sessions")
  local said, asked = {}, {}
  local ui = { ctx = {} }
  function ui:say(text, cb)
    said[#said + 1] = { text = text, cb = cb }
    return { text = text }
  end
  function ui:confirm(_, text, cb)
    asked[#asked + 1] = { text = text, cb = cb }
    return { text = text }
  end
  local s = SessionsL.new({ send = function() return true end }, ui)
  local g3 = { generation = 3, phase = "field", session = {} }
  local m1, m2 = mon(16, 10), mon(19, 10)
  check(s:offerForgets(g3, { { mon = m1, move = 17 }, { mon = m2, move = 98 } }),
    "a Gen 3 queue is taken")
  eq(#begun, 1, "one prompt at a time")
  eq(begun[1].mon, m1, "for the first mon")
  eq(begun[1].moveId, 17, "and its move number")
  eq(begun[1].headless, false, "with the prompts wired")
  eq(begun[1].battleText, false, "in the field's wording: the fight is already over")
  local msgDone = false
  begun[1].pushMsg("hello", function() msgDone = true end)
  eq(said[1] and said[1].text, "hello", "messages are this mod's own box (the ui's say)")
  eq(messageShown, 0, "never the engine's Message singleton")
  if said[1] and said[1].cb then said[1].cb() end
  eq(msgDone, true, "and dismissing it answers LearnMove")
  local answered
  begun[1].askYesNo("Delete a move?", function(yes) answered = yes end)
  eq(asked[1] and asked[1].text, "Delete a move?", "the question is this mod's yes / no")
  eq(choiceAsked, 0, "never the engine's Choice singleton")
  if asked[1] then asked[1].cb(true) end
  eq(answered, true, "and the yes / no answers it")
  local picked
  begun[1].askForget({ "TACKLE" }, function(slot) picked = slot end, { moveId = 17 })
  eq(forgets[1] and forgets[1].opts.mode, "select_move", "the summary move picker opens")
  eq(forgets[1] and forgets[1].opts.moveToLearn, 17, "showing the move to learn")
  if forgets[1] then forgets[1].opts.onSelectMove(2) end
  eq(picked, 2, "and its choice goes back to LearnMove")
  begun[1].onDone(true)
  eq(#begun, 2, "the next banked move follows once the first is answered")
  eq(begun[2] and begun[2].mon, m2, "for the second mon")
  if begun[2] then begun[2].onDone(false) end
  begun[1].onDone(true)
  eq(#begun, 2, "a stray second callback does not reopen anything")

  -- endMediated: the evolutions a fight earned wait for the last learn.  Both
  -- are the cart's own exchanges (EvolutionScene runs LearnMove.begin again
  -- for the evolved species), so starting the scene under an open learn ran
  -- one engine module twice at once.
  local EvolveFxL = needL("EvolveFx")
  local realOffer = EvolveFxL.offerEvolutions
  local offered = {}
  EvolveFxL.offerEvolutions = function(_, leveledUp) offered[#offered + 1] = leveledUp return true end
  begun = {}
  s.fight = { game = g3, leveledUp = { m1 }, result = "win" }
  s:endMediated(g3, { { mon = m1, move = 17 }, { mon = m2, move = 98 } })
  eq(#begun, 1, "endMediated: the first learn is up")
  eq(#offered, 0, "endMediated: and the evolutions wait for it")
  if begun[1] then begun[1].onDone(true) end
  eq(#offered, 0, "endMediated: and for the second learn")
  if begun[2] then begun[2].onDone(false) end
  eq(#offered, 1, "endMediated: then run, once the last learn is answered")
  if begun[2] then begun[2].onDone(false) end
  eq(#offered, 1, "endMediated: exactly once")
  s.fight = { game = g3, leveledUp = { m2 }, result = "win" }
  s:endMediated(g3, {})
  eq(#offered, 2, "endMediated: with nothing to learn the evolutions run at once")
  -- Gen 1 keeps its order: both offers at once, the screens stack there.
  s.fight = { game = { generation = 1, data = {} }, leveledUp = { m1 }, result = "win" }
  begun = {}
  s:endMediated(s.fight.game, { { mon = mon(16, 10), move = "TACKLE" } })
  eq(#begun, 0, "endMediated on Gen 1: never the Gen 3 exchange")
  eq(#offered, 3, "endMediated on Gen 1: the evolutions are offered at once, as before")
  EvolveFxL.offerEvolutions = realOffer

  for _, name in ipairs({ "src.core.game3.battle.learn_move", "src.ui.game3.message",
      "src.ui.game3.choice", "src.ui.game3.summary_menu" }) do
    package.loaded[name] = saved[name] or nil
    saved[name] = nil
  end
end

-- ------- the trade waits while the cart has the screen (Ui.occupied)
--
-- A Gen 3 player can be in the cart's own BAG when the far side accepts,
-- picks or confirms.  BOB's ui below answers Ui.occupied from a flag and
-- holds Ui:whenFree prompts until it drops, the contract src/Ui.lua keeps
-- (the real one is driven in tests/gen3_ui.lua).  The picker, the confirm and
-- the "traded over!" line all wait for the BAG to close; the swap and its
-- save do not; and the trade evolution still follows the line, once.

do
  scenes, evolutions = {}, {}
  local sa = newSession({ name = "ANN", trainerId = 11, national = true,
    party = { mon(25, 12, { nickname = "SPARKY" }), mon(16, 5) } })
  local sb = newSession({ name = "BOB", trainerId = 22, national = true,
    party = { mon(19, 4), mon(20, 22) } })
  sa.party[1].species, sa.party[1].speciesId, sa.party[1].nickname = 64, 64, "KADABRA"
  local a, b = players(sa, sb)
  local held = {}
  b.ui.bagOpen = true
  -- Ui.occupied is a module function (called as ui.occupied(game)); whenFree
  -- and pumpDeferred are methods, as on the real Ui
  b.ui.occupied = function() return b.ui.bagOpen end
  function b.ui:whenFree(_, show, opts)
    if not self.bagOpen and #held == 0 then return show() end
    held[#held + 1] = { show = show, alive = opts and opts.alive }
    return { deferred = true }
  end
  function b.ui:pumpDeferred()
    if self.bagOpen then return false end
    while held[1] do
      local entry = table.remove(held, 1)
      if not entry.alive or entry.alive() then entry.show() return true end
    end
    return false
  end
  local pickOpens = 0
  local basePick = b.ui.pickPartyMon
  function b.ui:pickPartyMon(...)
    pickOpens = pickOpens + 1
    return basePick(self, ...)
  end

  local netA, netB = Net.loopbackPair()
  a.transport.net, b.transport.net = netA, netB
  a.sessions:onSession(a.game, { peer = b.id, peerName = b.name, kind = "trade", role = "host", id = "s9" })
  b.sessions:onSession(b.game, { peer = a.id, peerName = a.name, kind = "trade", role = "guest", id = "s9" })
  local function tick(n)
    for _ = 1, n or 1 do
      deliver(a, b)
      deliver(b, a)
      a.sessions:update(a.game, 0.25)
      b.sessions:update(b.game, 0.25)
      answer(a, { pick = 1 })
    end
  end
  tick(8)
  eq(pickOpens, 0, "BOB's picker waits while he is in the cart's BAG")
  eq(b.sessions.active and b.sessions.active.trade and b.sessions.active.trade.stage, "picking",
    "though his trade is ready for it")
  b.ui.bagOpen = false
  tick(1)
  eq(pickOpens, 1, "it opens once he closes the BAG")
  b.ui.bagOpen = true
  local pick = table.remove(b.ui.picks, 1)
  if pick then pick.onPick(1) end
  tick(8)
  eq(b.ui.asked, nil, "the confirm waits for the BAG too")
  b.ui.bagOpen = false
  tick(1)
  eq(b.ui.asked, 1, "and is asked once it closes")
  b.ui.bagOpen = true
  local box = table.remove(b.ui.confirms, 1)
  if box then box.onChoose(true) end
  tick(8)
  eq(sb.party[1].species, 64, "the swap itself does not wait: BOB holds the KADABRA")
  eq(b.game.saves, 1, "and it is on the cartridge before anything is shown")
  check(not contains(b.ui.said, "KADABRA was\ntraded over!"), "the line waits for the BAG")
  eq(#scenes, 0, "and the evolution waits for the line")
  b.ui.bagOpen = false
  tick(1)
  check(contains(b.ui.said, "KADABRA was\ntraded over!"), "the line is read once the BAG closes")
  eq(#scenes, 0, "the evolution follows the line, not the BAG closing")
  local dismiss = table.remove(b.ui.sayDone, 1)
  if dismiss then dismiss() end
  eq(#scenes, 1, "and plays once the line is dismissed")
  eq(scenes[1] and scenes[1].target, 65, "into ALAKAZAM")
  if dismiss then dismiss() end
  tick(6)
  eq(#scenes, 1, "exactly once, however often the line is answered")
  eq(b.sessions.active, nil, "and BOB's session settled")
end

-- A line with nowhere to go (a ui that pushed nothing) runs its continuation
-- at once, so a trade evolution can never be stranded behind a box that was
-- never drawn.
do
  local calls = 0
  local s = Sessions.new({ send = function() return true end }, {
    say = function() return nil end, ctx = {},
  })
  s:tell(nil, "SPARKY was\ntraded over!", function() calls = calls + 1 end)
  eq(calls, 1, "tell runs onDone at once when no box went up")
  local boxed = 0
  local s2 = Sessions.new({ send = function() return true end }, {
    say = function() return { kind = "text" } end, ctx = {},
  })
  s2:tell(nil, "Held.", function() boxed = boxed + 1 end)
  eq(boxed, 0, "and leaves it to the box when one did")
end

-- The moves a fight banked are the cart's own exchange: LearnMove.open runs
-- whether or not the screen reads as occupied -- it is what occupies it --
-- and chains through its callbacks as before.  With no say / confirm on the
-- ui (a harness stub), LearnMove's own Gen3Ui boxes stand in.
do
  local begun = {}
  stub("src.core.game3.battle.learn_move", { begin = function(opts) begun[#begun + 1] = opts end })
  local needL = newNeed()
  local SessionsL = needL("Sessions")
  local s = SessionsL.new({}, { occupied = function() return true end, ctx = {} })
  local g3 = { generation = 3, phase = "field", session = {} }
  check(s:offerForgets(g3, { { mon = mon(16, 10), move = 17 }, { mon = mon(19, 10), move = 98 } }),
    "a Gen 3 queue is taken while the cart's menus are up")
  eq(#begun, 1, "the first learn-move exchange starts at once")
  begun[1].onDone(false)
  eq(#begun, 2, "and the second follows the first's answer")
  if begun[2] then
    begun[2].onDone(true)
    begun[2].onDone(true)
  end
  eq(#begun, 2, "a stray callback reopens nothing")
  package.loaded["src.core.game3.battle.learn_move"] = saved["src.core.game3.battle.learn_move"] or nil
  saved["src.core.game3.battle.learn_move"] = nil
  Stack.clear()
end

-- ------- a Gen 3 build without the codec refuses rather than falling to Gen 1

do
  check(Trade3.capable(), "capable with a Gen 3 codec")
  -- beginTrade on Gen 3 without the codec refuses rather than falling
  -- through to the Gen 1 TradeSession.
  local needC = newNeed()
  stub("src.link.Protocol", {})
  local SessionsC = needC("Sessions")
  local ended
  SessionsC.beginTrade({ endSession = function(_, msg) ended = msg end },
    { generation = 3, session = {}, data = {} },
    {},
    { Handshake = { tradeAllowed = function() return true end,
                    strict = function() return true end } })
  eq(ended, "You can't trade\non this build.", "a Gen 3 build without packMon3 refuses")
  package.loaded["src.link.Protocol"] = FakeProtocol
end

unstubAll()
Stack.clear()

-- ===================================================================
-- Tier B -- the real codec, on the player's own imported cache
-- ===================================================================

local Cache = require("tests.game3_cache")
local frRoot = Cache.root("meta.json")
if not frRoot then
  print("[skip] trade3 real-codec tier: " .. tostring(Cache.reason))
else
  local GameVersion = require("src.core.GameVersion")
  local Dataset = require("src.core.game3.dataset")
  local Protocol = require("src.link.Protocol")

  local function mount(version, root)
    GameVersion.set(version)
    Dataset.cacheRootOverride = root
    pcall(Dataset.mountExtractRoots)
    local Pokemon = require("src.core.game3.pokemon")
    if Pokemon.invalidate then Pokemon.invalidate() end
    Pokemon.install(nil)
    local ItemsData = require("src.core.game3.items_data")
    ItemsData._pack, ItemsData._byId, ItemsData._byName = nil, nil, nil
    pcall(ItemsData.install, nil)
    return Pokemon
  end

  local Pokemon = mount("firered", frRoot)
  local Party = require("src.core.game3.party")
  local DATA = { pokemon = Pokemon }

  local function give(session, species, level, extra)
    local scratch = { party = {}, name = session.name, trainerId = session.trainerId,
                      secretId = session.secretId, gender = 0 }
    local ok, _, m = Party.giveMon(scratch, species, level)
    assert(ok and m, "giveMon " .. tostring(species))
    for k, v in pairs(extra or {}) do m[k] = v end
    Pokemon.applyStats(m)
    session.party[#session.party + 1] = m
    return m
  end

  -- The real codec, strict, through JSON -- and what does not survive it.
  do
    local s = newSession({ name = "RED", trainerId = 24680, national = true })
    local pika = give(s, 25, 12, { nickname = "SPARKY", item = 121, heldItem = 121 })
    local packed = Protocol.packMon3(pika)
    local got, why = Protocol.unpackMon3(DATA, Json.decode(Json.encode(packed)), { strict = true })
    check(got ~= nil, "a real party mon survives the strict round trip: " .. tostring(why))
    eq(got and got.species, 25, "species")
    eq(got and got.item, 121, "held item")
    eq(got and got.exp, pika.exp, "exp")
    eq(got and got.personality, pika.personality, "personality")
    local bad = Json.decode(Json.encode(packed))
    bad.nature = (bad.nature + 1) % 25
    local refused, reason = Protocol.unpackMon3(DATA, bad, { strict = true })
    eq(refused, nil, "a nature that does not match the personality is refused")
    eq(reason, "nature mismatch", "and says so")
  end

  -- A full Trade3 exchange on real mons, the real TradeMons and the real
  -- evolution rules (no stand-ins left but the handshake).
  do
    stub("src.link.Handshake", {
      generation = function(game) return type(game) == "table" and game.generation or 1 end,
      hello = function(game, kind) return { type = "hello", generation = 3, fingerprint = "fr", mode = kind } end,
      checkCompat = function() return "full" end,
      tradeAllowed = function() return true end,
      strict = function() return true end,
    })
    stub("src.link.LinkBattle", {})
    stub("src.core.game3.runtime", { getSession = function() return nil end })
    -- No window to play the scene in: Sessions applies the evolution outright.
    stub("src.ui.game3.evolution_scene", { start = function() return false end })
    local needB = newNeed()
    Sessions = needB("Sessions")
    Trade3 = needB("Trade3")

    local sa = newSession({ name = "ANN", trainerId = 11, national = true })
    local sb = newSession({ name = "BOB", trainerId = 22, national = true })
    local kadabra = give(sa, 64, 25)
    give(sa, 16, 5)
    local onix = give(sa, 95, 30, { item = 199, heldItem = 199 })
    local pika = give(sb, 25, 12, { nickname = "SPARKY" })
    give(sb, 19, 4)
    give(sb, 20, 22)
    giveMail(sb, pika, { 10, 20, 30, 40, 50, 60, 70, 80, 90 }, "BOB")
    local a, b = players(sa, sb)
    a.game.data, b.game.data = DATA, DATA

    -- The payload the hub carries, measured against its line ceiling: the
    -- worst case, six mons with long nicknames each holding mail.
    do
      local full = newSession({ name = "MAXNAME", trainerId = 65535, national = true })
      local pool = Mail.pool(full)
      for i, species in ipairs({ 6, 9, 3, 25, 150, 94 }) do
        local m = give(full, species, 100, { nickname = "NICKNAME10", item = 120 + i, heldItem = 120 + i })
        pool[i] = { words = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }, playerName = "MAXNAME",
                    trainerId = 4294967295, species = species, itemId = 120 + i }
        m.mail = i - 1
      end
      local tf = Trade3.TradeSession.new({ generation = 3, session = full, data = DATA }, {})
      local payload = tf:partyMessage()
      local line = Json.encode({ type = Wire.RELAY, to = "p2", payload = payload })
      check(#line < 64 * 1024,
        ("a six-mon Gen 3 party with mail is one hub line (%d bytes of 65536)"):format(#line))
      check(Wire.payloadOk(payload), "and within the relay's depth / node limits")
      eq(#payload.mons, 6, "all six mons packed")
      eq(payload.mail[6] and payload.mail[6].itemId, 126, "and all six letters")
      print(("[info] trade3: a six-mon Gen 3 party message with mail is %d bytes"):format(#line))
    end

    trade(a, b, { pick = 1 }, { pick = 1 })
    eq(sb.party[1].species, 65, "the real rules evolve a traded KADABRA into ALAKAZAM")
    eq(sb.party[1].otName, kadabra.otName, "OT kept through the real codec")
    eq(sa.party[1].species, 25, "ANN holds the PIKACHU")
    local got = Mail.get(sa, sa.party[1].mail)
    eq(got and got.words[1], 10, "with BOB's mail, through the real mail pool")
    check(Dex.isCaught(sa.dex, 25), "and it is in ANN's dex")

    local sc = newSession({ name = "CAT", trainerId = 33 })
    give(sc, 19, 4)
    give(sc, 16, 5)
    local c = newPlayer("p3", "CAT", sc, "fr", nil)
    c.game.data = DATA
    local a2 = newPlayer("p1", "ANN", sa, "fr", nil)
    a2.game.data = DATA
    trade(a2, c, { pick = 3 }, { pick = 1 })
    eq(sc.party[1].species, 95, "a FireRed without the National Dex gets its ONIX...")
    eq(sc.party[1].item, 199, "...still holding the METAL COAT: STEELIX is a Johto species, "
      .. "and FireRed's evolution gate keeps it an ONIX until the National Dex")
    unstubAll()
  end

  -- FireRed -> Emerald, when an Emerald cache is there too.
  local emRoot = os.getenv("RBY_MMO_EMERALD_CACHE")
  local emOk = emRoot and io.open(emRoot .. "/meta.json", "rb")
  if emOk then emOk:close() end
  if not emOk then
    print("[skip] trade3 cross-version tier: set RBY_MMO_EMERALD_CACHE to an "
      .. "imported Emerald cache directory (the one holding its meta.json) to run it")
  else
    local s = newSession({ name = "RED", trainerId = 12345, national = true })
    local deoxys = give(s, 410, 30, { fatefulEncounter = true })
    local treecko = give(s, 277, 10, { item = 199, heldItem = 199 })
    local frStats = { deoxys.attack, deoxys.defense, deoxys.speed }
    local line = Json.encode({ Protocol.packMon3(deoxys), Protocol.packMon3(treecko) })
    local EmPokemon = mount("emerald", emRoot)
    local back = Json.decode(line)
    local d, whyD = Protocol.unpackMon3({ pokemon = EmPokemon }, back[1], { strict = true })
    local tr, whyT = Protocol.unpackMon3({ pokemon = EmPokemon }, back[2], { strict = true })
    check(d ~= nil, "a FireRed DEOXYS unpacks strictly on Emerald: " .. tostring(whyD))
    check(tr ~= nil, "and so does a TREECKO: " .. tostring(whyT))
    eq(tr and tr.item, 199, "held item crosses")
    eq(d and d.level, 30, "level crosses")
    eq(d and d.personality, deoxys.personality, "personality crosses")
    check(d and not (d.attack == frStats[1] and d.defense == frStats[2] and d.speed == frStats[3]),
      "DEOXYS takes the receiving cart's forme: Emerald's stats, not FireRed's")
    mount("firered", frRoot)
  end
  GameVersion.set("red")
end

T.finish("trade3")
