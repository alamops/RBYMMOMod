-- Gen 3 trade over SessionNet: packMon3 / unpackMon3 + a party-mail parallel
-- array + apply through the cart's own TradeMons, for FireRed, LeafGreen and
-- Emerald.
--
-- src/Trade2.lua's twin, and deliberately the same shape: the same stage
-- machine (waitParty, picking, waitPick, confirming, done, cancelled), the
-- same wire vocabulary (party / pick / confirm / bye), the same `apply`
-- returning the received mon and what it evolves into.  src/Sessions.lua
-- drives all three codecs the same way and only picks which one by
-- generation.  What differs is everything the engine already knows how to do
-- for a Gen 3 cart, which this file hands to the engine rather than
-- re-deriving:
--
--   * **the codec** -- src/link/Protocol.lua packMon3 / unpackMon3, strict
--     always (see below), the same one the engine's own online trade uses;
--   * **the rules** -- src/core/game3/link/family.lua canTradeSelectedMon
--     (pokefirered/src/trade.c:2745, pokeemerald/src/trade.c:2389: the last
--     healthy mon, a non-Kanto / non-Hoenn mon or an egg before the National
--     Dex, a partner who could not take it, an event-only MEW / DEOXYS) and
--     gameProgressForLinkTrade (trade.c:2820 / 2453: FireRed/LeafGreen meet
--     Emerald only once both saves are far enough in);
--   * **the swap** -- src/core/game3/scripting/natives_trade.lua tradeMons
--     (pokefirered/src/trade_scene.c:1054 TradeMons): the outgoing mail
--     cleared, the partner's mail installed, friendship set to the traded 70,
--     the dex marked seen and caught -- plus noteLinkTrade's game stat and
--     the FRLG quest-log line the cable club records;
--   * **the evolution** -- src/core/game3/evolution.lua tradeTarget, which is
--     the cart's own GetEvolutionTargetSpecies(EVO_MODE_TRADE): an Everstone
--     refuses, a trade-item row (Metal Coat, King's Rock, Dragon Scale, Deep
--     Sea Tooth / Scale, Up-Grade) demands and *consumes* its held item, and
--     FireRed's National Dex gate keeps a Kanto save from evolving into a
--     Johto species.  Sessions puts the answer on screen through the engine's
--     EvolutionScene, which is the screen tryTradeEvolution opens.
--
-- ------- strict, always
--
-- Handshake.strict is false only for a v1 peer ("vanilla_peer"), and there is
-- no v1 Gen 3 build: every Gen 3 install speaks the v2 hello.  The engine's
-- own Gen 3 remote trade (src/online/Trade.lua Remote3) unpacks every
-- incoming mon strictly for the same reason, so a mon this cart would rebuild
-- differently -- an unknown species, an impossible exp for its level, a
-- nature that does not match its personality -- cancels the trade rather
-- than being quietly repaired into something neither player offered.
--
-- ------- no subset negotiation
--
-- Gen 1's "subset" verdict exists because two Red installs can disagree
-- about what a species *is* (a data pack rewrote it), so the parties are
-- negotiated down to the records both sides share.  Gen 3 ids are the carts'
-- own internal numbers, shared by all three games, and unpackMon3 validates
-- every received mon against *this* cart's data anyway.  FireRed and Emerald
-- always fingerprint differently (Deoxys alone sees to that), so every
-- cross-version pairing arrives here as "subset" -- and is traded as a full
-- party, the way the cartridges trade.  A `records` message is ignored.
--
-- ------- cross-version (FireRed / LeafGreen <-> Emerald), verified
--
-- Measured against the real FireRed Rev1 and Emerald caches (headless, this
-- machine; tests/trade3.lua repeats it when both are imported):
--
--   * species, moves, abilities, natures and held items are the same numbers
--     on all three carts (411 internal species, 354 moves; Protocol clamps
--     items to FireRed's ITEM_LAST 374, and Emerald's only extras above it are
--     the two key items MAGMA EMBLEM and OLD SEA MAP, which nothing holds), so
--     packMon3 on one cart and unpackMon3 on the other round-trip exactly:
--     same species, level, exp, IVs, EVs, moves, PP, personality, OT, item.
--   * **DEOXYS changes forme with the cart it lands in.**  Only species,
--     level, IVs, EVs and personality travel; unpackMon3 recomputes the stats
--     from the *receiving* cart's base stats, so an Attack Forme DEOXYS sent
--     from FireRed arrives on Emerald as a Speed Forme (and a Defense Forme on
--     LeafGreen) -- which is exactly what the carts do.
--   * Mail (easy-chat word ids, sender, species) is one format on all three.
--
-- Capability-tested: Sessions only opens this path when Protocol.packMon3 and
-- unpackMon3 both exist.  Every engine module is reached through
-- src/Gen3.lua's guarded lazy require, so nothing here loads -- or can be
-- denied -- on a Gen 1 or Gen 2 boot.

local need, mod = ...
local Gen3 = need("Gen3")

local M = {}

-- pokefirered/include/constants/global.h:65 MAIL_WORDS_COUNT and :61
-- PLAYER_NAME_LENGTH; include/constants/easy_chat.h EC_WORD_UNDEFINED;
-- include/constants/items.h:121-132 the twelve mail items.  Constants, the
-- same numbers src/core/game3/mail.lua uses -- the fallbacks below are only
-- read when that module is missing.
local MAIL_WORDS = 9
local PLAYER_NAME_LENGTH = 7
local EC_WORD_UNDEFINED = 0xFFFF
local FIRST_MAIL, LAST_MAIL = 121, 132
local U32 = 4294967296

-- pokefirered/include/constants/species.h
local SPECIES_MEW, SPECIES_DEOXYS, SPECIES_EGG = 151, 410, 412
-- pokefirered/src/trade_scene.c:1075
local TRADED_FRIENDSHIP = 70
local PARTY_SIZE = 6

-- pokeemerald/include/constants/global.h:8 VERSION_*: what the cable club
-- calls each cart.  The fallback when family.lua cannot answer.
local CART = { emerald = 3, firered = 4, leafgreen = 5 }
local CART_FAMILY = { [3] = "rse", [4] = "frlg", [5] = "frlg" }

-- pokefirered/include/constants/trade.h:24
local CAN_TRADE_MON = 0
local CANT_TRADE_LAST_MON = 1
local CANT_TRADE_NATIONAL = 2
local CANT_TRADE_EGG_YET = 3
local CANT_TRADE_INVALID_MON = 4
local CANT_TRADE_PARTNER_EGG_YET = 5

-- The sentences the cart prints for each refusal (pokefirered/src/trade.c:546
-- sMessages), used when the player's own ROM text pack cannot be read.
local REFUSAL_FALLBACK = {
  [CANT_TRADE_LAST_MON] = "That's your only\nPOKéMON for battle.",
  [CANT_TRADE_NATIONAL] = "That POKéMON can't\nbe traded now.",
  [CANT_TRADE_EGG_YET] = "An EGG can't be\ntraded now.",
  [CANT_TRADE_INVALID_MON] = "That POKéMON can't\nbe traded now.",
  [CANT_TRADE_PARTNER_EGG_YET] = "An EGG can't be\ntraded now.",
}
local PEER_REFUSAL_FALLBACK = "The other TRAINER's\nPOKéMON can't be\ntraded now."
-- src/online/Trade.lua crossVersionGate3's two answers, the engine's own
-- wording for GetGameProgressForLinkTrade.
local NOT_READY_MINE = "You can't trade\nwith that game yet."
local NOT_READY_THEIRS = "The other game\ncan't trade with\nyou yet."

M.CART = CART

-- ------- engine access

local protocolTried, ProtocolMod

local function protocol()
  if protocolTried then return ProtocolMod end
  protocolTried = true
  local ok, p = pcall(require, "src.link.Protocol")
  if ok and type(p) == "table" then ProtocolMod = p end
  return ProtocolMod
end

local function engine(name)
  return Gen3 and Gen3.engine and Gen3.engine(name) or nil
end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

local function family() return engine("src.core.game3.link.family") end
local function natives() return engine("src.core.game3.scripting.natives_trade") end
local function mailModule() return engine("src.core.game3.mail") end
local function pokemonModule() return engine("src.core.game3.pokemon") end

local function whole(v, lo, hi)
  local n = tonumber(v)
  if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
  if n ~= math.floor(n) then return nil end
  if (lo and n < lo) or (hi and n > hi) then return nil end
  return n
end

local mailWarned

local function warnMail(action, detail)
  if mailWarned then return end
  mailWarned = true
  mod.log:warn(
    "party mail could not be %s (%s) -- the POKéMON and its held item still "
      .. "trade; update gen1recomp so src.core.game3.mail is available, or "
      .. "take the MAIL before trading again",
    action, tostring(detail or "unavailable"))
end

-- True when this engine build can run the Gen 3 trade codec.
function M.capable()
  local P = protocol()
  return P ~= nil
    and type(P.packMon3) == "function"
    and type(P.unpackMon3) == "function"
    and type(P.packParty3) == "function"
end

-- ------- small facts about a mon

local function isEgg(mon)
  if type(mon) ~= "table" then return false end
  local P = pokemonModule()
  if P and type(P.isEgg) == "function" then
    local ok, egg = pcall(P.isEgg, mon)
    if ok then return egg == true end
  end
  return mon.isEgg == true or mon.egg == true or tonumber(mon.species) == SPECIES_EGG
end
M.isEgg = isEgg

local function speciesOf(mon)
  return tonumber(type(mon) == "table" and (mon.species or mon.speciesId)) or 0
end

local function heldItemOf(mon)
  if type(mon) ~= "table" then return 0 end
  return tonumber(mon.item or mon.heldItem) or 0
end

local function isMailItem(itemId)
  local Mail = mailModule()
  if Mail and type(Mail.isMailItem) == "function" then
    return try(Mail.isMailItem, itemId) == true
  end
  local n = tonumber(itemId)
  return n ~= nil and n >= FIRST_MAIL and n <= LAST_MAIL
end

-- What the player calls a mon: its nickname, else its species, "EGG" for an
-- egg -- Pokemon.displayMonName, the name every Gen 3 menu prints.
function M.displayName(mon)
  if type(mon) ~= "table" then return "POKéMON" end
  local P = pokemonModule()
  local name = P and try(P.displayMonName, mon)
  if type(name) == "string" and name ~= "" then return name end
  if isEgg(mon) then return "EGG" end
  if type(mon.nickname) == "string" and mon.nickname ~= "" then return mon.nickname end
  return Gen3.speciesName(speciesOf(mon)) or "POKéMON"
end

-- ------- mail on the wire
--
-- One Gen 3 mail record (pokefirered/include/global.h struct Mail): nine
-- easy-chat word ids, the sender's name and trainer id, the mon it was
-- written on (Unown carries its letter as 30000+), and the mail item.
-- Re-derived field by field: this is drawn on the receiving screen.
-- `design` follows from the item (ITEM_TO_MAIL) rather than trusting it.

local function clipName(s, max)
  if type(s) ~= "string" then return "" end
  s = s:gsub("%c", "")
  local out, n, i = {}, 0, 1
  while i <= #s and n < max do
    local b = s:byte(i)
    local len = 1
    if b >= 240 then len = 4 elseif b >= 224 then len = 3 elseif b >= 192 then len = 2 end
    out[#out + 1] = s:sub(i, i + len - 1)
    n, i = n + 1, i + len
  end
  return table.concat(out)
end

function M.sanitizeMail(entry)
  if entry == nil or entry == false or type(entry) ~= "table" then return nil end
  local itemId = whole(entry.itemId, 0, 65535)
  if not (itemId and isMailItem(itemId)) then return nil end
  local words = {}
  local raw = type(entry.words) == "table" and entry.words or {}
  for i = 1, MAIL_WORDS do
    words[i] = whole(raw[i], 0, 0xFFFF) or EC_WORD_UNDEFINED
  end
  return {
    words = words,
    playerName = clipName(entry.playerName, PLAYER_NAME_LENGTH),
    trainerId = whole(entry.trainerId, 0, U32 - 1) or 0,
    species = whole(entry.species, 0, 65535) or 1,
    itemId = itemId,
    design = itemId - FIRST_MAIL,
  }
end

-- The mail record a party mon holds, or nil.  Mail.monHasMail is the cart's
-- MonHasMail: a mail index *and* a mail item in hand.
local function heldMail(session, mon)
  local Mail = mailModule()
  if not Mail then
    if type(mon) == "table" and mon.mail ~= nil and isMailItem(heldItemOf(mon)) then
      warnMail("packed", "src.core.game3.mail missing")
    end
    return nil
  end
  if not try(Mail.monHasMail, mon) then return nil end
  local record = try(Mail.get, session, mon.mail)
  if type(record) ~= "table" then return nil end
  return try(Mail.copy, record) or record
end

-- Parallel mail array for the same indices packParty3 uses.  `false` for a
-- mon with no mail, so JSON keeps the positions aligned (a nil hole would
-- collapse and slide later mail onto earlier mons).
function M.packMail(session, indices)
  local party = type(session) == "table" and type(session.party) == "table"
    and session.party or {}
  local out = {}
  if not indices then
    indices = {}
    for i = 1, #party do indices[i] = i end
  end
  for pos, slot in ipairs(indices) do
    out[pos] = M.sanitizeMail(heldMail(session, party[slot])) or false
  end
  return out
end

function M.unpackMailList(raw)
  local out = {}
  if type(raw) ~= "table" then return out end
  for i = 1, PARTY_SIZE do
    out[i] = M.sanitizeMail(raw[i])
  end
  return out
end

-- ------- who is trading: the cable club's LinkPlayer, the part that decides
--
-- pokeemerald/src/link.c:324 InitLocalLinkPlayer: which cart (VERSION_*) and
-- the progress flags -- low nibble "has the National Dex", high nibble "may
-- link with the other region" (FLAG_SYS_CAN_LINK_WITH_RS on FireRed and
-- LeafGreen, FLAG_IS_CHAMPION on Emerald).  Everything canTradeSelectedMon
-- and gameProgressForLinkTrade read about the partner is these two numbers,
-- so they ride on the party message as `gen3`.

local function versionOf(session)
  local v = type(session) == "table" and session.version or nil
  if type(v) == "string" and CART[v] then return v end
  return Gen3.version() or "firered"
end

-- The running game's event flags live in the script engine's store
-- (scripting/space.lua Space.store); session.flags is only the snapshot
-- persistSession writes at save time.  family.lua reads `session.store` first,
-- so the live session is handed over with the live store in front of it --
-- a player who became Champion since their last save can trade across
-- regions now, not after saving.  Any other session (an in-memory peer, a
-- test) is read as it is.
--
-- The live session is recognised by identity, never by the absence of a
-- `store` field: every Emerald session carries a `store` of its own -- the
-- `{flags, vars}` fallback src/core/game3/time_events.lua builds -- which is
-- not Space.store, so trusting it read stale flags and refused every
-- FireRed <-> Emerald trade to a Champion with the National Dex.
local function liveView(session)
  if type(session) ~= "table" then return session end
  if Gen3.session() ~= session then return session end
  local Space = engine("src.core.game3.scripting.space")
  local store = Space and Space.store
  if type(store) ~= "table" then return session end
  return setmetatable({ store = store }, { __index = session })
end

function M.localInfo(session, version)
  version = version or versionOf(session)
  local Family = family()
  local info = Family and try(Family.localLinkPlayer, liveView(session), version)
  if type(info) == "table" then
    local cart = tonumber(info.gameVersion) or ((tonumber(info.version) or 0) % 256)
    return {
      version = cart,
      progressFlags = (tonumber(info.progressFlags) or 0) % 256,
      family = info.family or CART_FAMILY[cart] or "frlg",
      game = version,
    }
  end
  local national = Family and try(Family.nationalDex, liveView(session), version) == true
  local cart = CART[version] or CART.firered
  return {
    version = cart,
    progressFlags = national and 1 or 0,
    family = CART_FAMILY[cart],
    game = version,
  }
end

-- What the other side said about itself, re-derived.  nil when it said
-- nothing (an older build of this mod): every rule that reads the partner
-- then treats it the way the cart treats a Ruby / Sapphire partner -- no
-- partner-side restriction -- and the far side's own rules still apply there.
function M.sanitizeInfo(raw)
  if type(raw) ~= "table" then return nil end
  local cart = whole(raw.version, 0, 255)
  if not cart then return nil end
  return {
    version = cart,
    progressFlags = whole(raw.progressFlags, 0, 255) or 0,
    game = type(raw.game) == "string" and CART[raw.game] and raw.game or nil,
  }
end

local function familyForCart(cart)
  local Family = family()
  local fam = Family and try(Family.familyForCart, cart)
  if fam then return fam end
  return CART_FAMILY[tonumber(cart) or -1]
end

local function versionForCart(cart)
  local Family = family()
  local v = Family and try(Family.versionForCart, cart)
  if type(v) == "string" then return v end
  for name, code in pairs(CART) do
    if code == tonumber(cart) then return name end
  end
  return nil
end

local function refusalText(code)
  local NTrade = natives()
  local text = NTrade and try(NTrade.refusalText, code)
  if type(text) == "string" and text ~= "" then return text end
  return REFUSAL_FALLBACK[code] or REFUSAL_FALLBACK[CANT_TRADE_INVALID_MON]
end

local function peerRefusalText()
  local NTrade = natives()
  local text = NTrade and try(NTrade.peerMonRefusalText)
  if type(text) == "string" and text ~= "" then return text end
  return PEER_REFUSAL_FALLBACK
end

-- ------- a picker's view of one party slot
--
-- What a Gen 3 trade picker needs to draw a row without reaching into the
-- mon itself -- the consumer is src/Ui.lua's PICK screen, which on Gen 3 has
-- no game.save.party to walk and draws `trade:entries()` instead.
-- `iconSpecies` is SPECIES_EGG for an egg (party_menu.c:2655 draws an egg's
-- icon, not the species it will hatch into); Gen3.icon() also takes the mon.
function M.entryOf(mon, index)
  if type(mon) ~= "table" then return nil end
  local species = speciesOf(mon)
  local egg = isEgg(mon)
  local item = heldItemOf(mon)
  local nickname = type(mon.nickname) == "string" and mon.nickname or ""
  return {
    index = index,
    mon = mon,
    name = M.displayName(mon),
    nickname = nickname,
    species = species,
    speciesName = Gen3.speciesName(species),
    level = tonumber(mon.level) or 1,
    iconSpecies = egg and SPECIES_EGG or species,
    heldItem = item,
    heldItemName = item ~= 0 and Gen3.itemName(item) or nil,
    -- MonHasMail: a mail index that is not MAIL_NONE (0xFF), and a mail item
    hasMail = whole(mon.mail, 0, 0xFE) ~= nil and isMailItem(item),
    isEgg = egg,
    gender = mon.gender,
    hp = tonumber(mon.hp),
    maxHp = tonumber(mon.maxHp),
    status = mon.status,
  }
end

local function emit(name, payload)
  pcall(function()
    local Runtime = require("src.mods.Runtime")
    if Runtime.wants and not Runtime.wants(name) then return end
    Runtime.emit(name, payload)
  end)
end

-- -------------------------------------------------------------------
-- TradeSession twin (Gen 3 codec, rules and swap)
-- -------------------------------------------------------------------

local TradeSession = {}
TradeSession.__index = TradeSession
M.TradeSession = TradeSession

-- The live session: Game3's own (the table Runtime.start was handed, so the
-- one every engine module reads), else the runtime's.  Never game.save --
-- that is a snapshot Schema.toSaveTable rebuilds at save time.
local function sessionOf(game)
  local s = type(game) == "table" and game.session or nil
  if type(s) == "table" then return s end
  return Gen3.session()
end

-- opts: { peerName } -- `subset` and `strict` are accepted for the shared
-- constructor shape and ignored (see the header).
function TradeSession.new(game, opts)
  opts = opts or {}
  local session = sessionOf(game)
  if type(session) == "table" and type(session.party) ~= "table" then
    session.party = {}
  end
  local version = versionOf(session)
  local me = M.localInfo(session, version)
  local self = setmetatable({
    game = game,
    data = game and game.data,
    session = session,
    party = session and session.party or {},
    version = version,
    me = me,
    peerName = opts.peerName,
    subset = false,
    strict = true,
    stage = "waitParty",
    reasons = {},
    theirParty = nil,
    theirMail = nil,
    theirInfo = nil,
    myPick = nil,
    theirPick = nil,
    myConfirm = nil,
    theirConfirm = nil,
  }, TradeSession)
  local all = {}
  for i = 1, #self.party do all[i] = i end
  self.sendIndices = all
  return self
end

-- The party as the session holds it now (a save load replaces the table).
function TradeSession:partyNow()
  local s = self.session
  if type(s) == "table" and type(s.party) == "table" then
    self.party = s.party
  end
  return self.party or {}
end

function TradeSession:hasNational()
  return (tonumber(self.me and self.me.progressFlags) or 0) % 16 ~= 0
end

function TradeSession:opening()
  return self:partyMessage()
end

function TradeSession:partyMessage()
  local P = protocol()
  local party = self:partyNow()
  local indices = {}
  for i = 1, math.min(#party, PARTY_SIZE) do indices[i] = i end
  self.sendIndices = indices
  local me = self.me or {}
  return {
    type = "party",
    mons = P.packParty3(party, indices),
    mail = M.packMail(self.session, indices),
    gen3 = { version = me.version, progressFlags = me.progressFlags, game = me.game },
  }
end

function TradeSession:cancel(why)
  self.stage = "cancelled"
  self.error = why
  return nil
end

-- pokefirered/src/trade.c:2820 GetGameProgressForLinkTrade, asked of a
-- partner from the other region only.  Nil when the pair may trade.
function TradeSession:versionGate()
  local info, me = self.theirInfo, self.me
  if not (info and me) then return nil end
  local theirs = familyForCart(info.version)
  if theirs == nil or theirs == me.family then return nil end
  local Family = family()
  if not Family then return nil end
  local code = try(Family.gameProgressForLinkTrade, me.family,
    { progressFlags = me.progressFlags }, { version = info.version, progressFlags = info.progressFlags })
  local T = type(Family.TRADE) == "table" and Family.TRADE or {}
  if code ~= nil and code == T.PLAYER_NOT_READY then return NOT_READY_MINE end
  if code ~= nil and code == T.PARTNER_NOT_READY then return NOT_READY_THEIRS end
  return nil
end

function TradeSession:handle(msg)
  local P = protocol()
  if msg.type == "party" then
    -- The first party is the one the picker shows; a second one mid-trade
    -- would change what "their slot 2" means under a pick already made.
    if self.theirParty or (self.stage ~= "waitParty" and self.stage ~= "picking") then
      return nil
    end
    local list = type(msg.mons) == "table" and msg.mons or {}
    if #list < 1 or #list > PARTY_SIZE then
      return self:cancel("the other game sent no POKéMON")
    end
    -- Mons and mail in one loop, index for index: strict means any mon that
    -- does not rebuild cancels outright, so nothing is ever skipped and the
    -- two arrays cannot slide against each other.
    local mailList = M.unpackMailList(msg.mail)
    local party, mails = {}, {}
    for i = 1, #list do
      local mon, why = P.unpackMon3(self.data, list[i], { strict = true })
      if not mon then
        return self:cancel(why or "the other game sent an unknown POKéMON")
      end
      party[i] = mon
      mails[i] = mailList[i]
    end
    self.theirParty, self.theirMail = party, mails
    self.theirInfo = M.sanitizeInfo(msg.gen3)
    local gate = self:versionGate()
    if gate then return self:cancel(gate) end
    self.reasons = {}
    if self.stage == "waitParty" then self.stage = "picking" end
  elseif msg.type == "pick" then
    local index = whole(msg.index, 1, PARTY_SIZE)
    if not index or (self.theirParty and not self.theirParty[index]) then
      return self:cancel("the other game picked a POKéMON it never showed")
    end
    self.theirPick = index
    self:advance()
  elseif msg.type == "confirm" then
    self.theirConfirm = msg.ok == true
    self:advance()
  elseif msg.type == "bye" then
    self.stage = "cancelled"
  end
  return nil
end

-- Why the cart would refuse to offer party slot `index`, or nil when it may
-- go.  The engine's rule with the partner the party message described --
-- the same call link/trade.lua's offer makes -- then CheckValidityOfTradeMons'
-- half about this side: somebody able to battle has to stay behind.
function TradeSession:refusal(index)
  local party = self:partyNow()
  local mon = party[index]
  if type(mon) ~= "table" then return refusalText(CANT_TRADE_INVALID_MON) end
  local Family = family()
  if Family then
    local info = self.theirInfo
    local code = try(Family.canTradeSelectedMon, self.version, party, index - 1, {
      session = self.session,
      partner = info and { version = info.version, progressFlags = info.progressFlags } or nil,
      nationalDex = self:hasNational(),
      partyCount = #party,
    })
    if code ~= nil and code ~= CAN_TRADE_MON then return refusalText(code) end
  end
  -- pokefirered/src/trade.c:1951 CheckValidityOfTradeMons
  for i, other in ipairs(party) do
    if i ~= index and not isEgg(other) and (tonumber(other.hp) or 0) > 0 then
      return nil
    end
  end
  return refusalText(CANT_TRADE_LAST_MON)
end

function TradeSession:canPick(index)
  local why = self:refusal(index)
  self.reasons[index] = why
  return why == nil
end

-- Why this cart cannot take the mon the other side picked, or nil.
--
-- The receiving half of the cart's check (CheckValidityOfTradeMons' partner
-- half, and Remote3:_partnerMonValid): an event-only MEW or DEOXYS that did
-- not come from the event.  Then, for a partner from this same region, the
-- *sender's* rule replayed with this save as the partner -- a FireRed with
-- no National Dex is offered no Johto / Hoenn mon and no egg, whatever the
-- far side's build thought.  A partner from the other region is already
-- covered by versionGate (neither side can reach this point before both are
-- past the flags that imply the National Dex), and its regional dex is not a
-- table this cart can read.
function TradeSession:theirRefusal()
  local mon = self.theirParty and self.theirParty[self.theirPick or 0]
  if type(mon) ~= "table" then return nil end
  local species = speciesOf(mon)
  if (species == SPECIES_MEW or species == SPECIES_DEOXYS)
      and mon.fatefulEncounter == false then
    return peerRefusalText()
  end
  local info, me = self.theirInfo, self.me
  local Family = family()
  if info and me and Family and familyForCart(info.version) == me.family then
    local code = try(Family.canTradeSelectedMon,
      versionForCart(info.version) or self.version,
      self.theirParty, self.theirPick - 1, {
        nationalDex = (info.progressFlags % 16) ~= 0,
        partner = { version = me.version, progressFlags = me.progressFlags },
        partyCount = #self.theirParty,
      })
    if code ~= nil and code ~= CAN_TRADE_MON then return peerRefusalText() end
  end
  return nil
end

-- One row per party slot for a trade picker (M.entryOf plus whether the cart
-- allows offering it, and why not).
function TradeSession:entries()
  local out = {}
  for index, mon in ipairs(self:partyNow()) do
    local entry = M.entryOf(mon, index)
    if entry then
      local why = self:refusal(index)
      self.reasons[index] = why
      entry.blocked = why ~= nil
      entry.reason = why
      out[#out + 1] = entry
    end
  end
  return out
end

-- The other side's party as picker rows (no blocking: nothing of theirs is
-- this side's to offer).
function TradeSession:theirEntries()
  local out = {}
  for index, mon in ipairs(self.theirParty or {}) do
    out[#out + 1] = M.entryOf(mon, index)
  end
  return out
end

function TradeSession:labelOf(mon)
  return M.displayName(mon)
end

function TradeSession:wireIndex(index)
  return index
end

function TradeSession:pick(index)
  self.myPick = index
  self:advance()
  return { type = "pick", index = index }
end

-- A yes is only a yes this cart can honour: an offer theirRefusal names is
-- answered no on the player's behalf, with the cart's reason kept on
-- `error` for whoever tears the session down.
function TradeSession:confirm(ok)
  ok = ok == true
  if ok then
    local why = self:theirRefusal()
    if why then
      ok = false
      self.error = why
    end
  end
  self.myConfirm = ok
  self:advance()
  return { type = "confirm", ok = ok }
end

function TradeSession:advance()
  if self.stage == "picking" and self.myPick then
    self.stage = self.theirPick and "confirming" or "waitPick"
  elseif self.stage == "waitPick" and self.theirPick then
    self.stage = "confirming"
  end
  if self.stage == "confirming"
      and self.myConfirm ~= nil and self.theirConfirm ~= nil then
    if self.myConfirm and self.theirConfirm then
      self.stage = "done"
    else
      self.stage = "cancelled"
    end
  end
end

-- TradeMons without natives_trade: the swap, the traded friendship and the
-- dex, which is everything but the mail -- said out loud when mail was lost.
local function swapFallback(session, slot, received, mail)
  local party = session.party
  local sent = party[slot]
  if not sent then return nil end
  party[slot] = received
  if not isEgg(received) then
    received.friendship = TRADED_FRIENDSHIP
    received.happiness = TRADED_FRIENDSHIP
    local Dex = engine("src.core.game3.dex")
    if Dex and type(Dex.handleSetPokedexFlag) == "function" then
      session.dex = session.dex or { seen = {}, owned = {}, caught = {} }
      session.dex.seen = session.dex.seen or {}
      session.dex.seen[speciesOf(received)] = true
      try(Dex.handleSetPokedexFlag, session.dex, speciesOf(received), true, received.personality)
    end
  end
  received.mail = nil
  if mail then warnMail("installed", "src.core.game3.scripting.natives_trade missing") end
  return sent
end

-- Apply into the Gen 3 party.  Returns the received mon, the species it
-- evolves into (nil when it does not), and `{ via = "trade" }` in the slot
-- Trade2 fills with its evolution row -- Sessions' Gen 3 arm needs only the
-- species, and the held item a trade-item row demands has already been
-- taken off the mon by tradeTarget, as the cart takes it.
function TradeSession:apply(game)
  if self.stage ~= "done" then
    mod.log:warn("Gen 3 trade apply called before both sides confirmed "
      .. "(stage=%s) -- leave the session and ask again", tostring(self.stage))
    return nil
  end
  local session = self.session or sessionOf(game or self.game)
  local received = self.theirParty and self.theirParty[self.theirPick]
  local party = type(session) == "table" and session.party
  local slot = self.myPick
  local sent = type(party) == "table" and party[slot] or nil
  if not (received and sent) then
    mod.log:warn("Gen 3 trade apply has no %s at slot %s -- check the party "
      .. "from START > POKéMON before trading again",
      received and "POKéMON to send" or "received POKéMON",
      tostring(received and slot or self.theirPick))
    return nil
  end

  -- pokefirered/src/trade_scene.c:2488: the partner's mail goes in
  -- gLinkPartnerMail[0] and the received mon points at it, exactly as the
  -- engine's LT.tryPlayScene stages it for TradeMons to install.
  local mail = self.theirMail and self.theirMail[self.theirPick]
  if not isMailItem(heldItemOf(received)) then mail = nil end
  local NTrade = natives()
  local swapped
  if NTrade and type(NTrade.tradeMons) == "function" then
    local Mail = mailModule()
    try(NTrade.clearPartnerMail)
    if mail and Mail then
      received.mail = 0
      try(NTrade.setPartnerMail, 0, try(Mail.copy, mail) or mail)
    else
      if mail then warnMail("installed", "src.core.game3.mail missing") end
      received.mail = nil
    end
    local ok, result = pcall(NTrade.tradeMons, session, slot - 1, received)
    try(NTrade.clearPartnerMail)
    if not ok then
      mod.log:warn("the cart's trade swap raised (%s) -- check the party "
        .. "from START > POKéMON before trading again", tostring(result))
      return nil
    end
    swapped = result
    if swapped then
      -- pokefirered/src/trade_scene.c:2599: the game stat, and the quest-log
      -- line FireRed's recap replays ("traded X for Y").
      local key, args = try(NTrade.noteLinkTrade, session, sent, received, self.peerName, false)
      local Recorder = key and engine("src.core.game3.quest_log_recorder") or nil
      if Recorder then try(Recorder.event, session, key, args) end
    end
  else
    swapped = swapFallback(session, slot, received, mail)
  end
  if not swapped then
    mod.log:warn("Gen 3 trade swap found nothing at slot %s -- check the "
      .. "party from START > POKéMON before trading again", tostring(slot))
    return nil
  end
  self.party = session.party

  emit("pokemon.received",
    { mon = received, from = "link", peerName = self.peerName })

  local evolveTo
  if not isEgg(received) then
    local Evolution = engine("src.core.game3.evolution")
    evolveTo = Evolution and try(Evolution.tradeTarget, received, session) or nil
  end
  emit("trade.completed",
    { sent = sent, received = received, evolveTo = evolveTo })
  return received, evolveTo, { via = "trade" }
end

return M
