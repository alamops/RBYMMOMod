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
-- ------- the party the peer saw is the party that trades
--
-- The party message is packed once, at opening(), and it is the only picture
-- of this side the far one ever gets: their picker, their "Trade for X?" and
-- the mon they file on "done" are all that snapshot.  But a Gen 3 player is
-- not held in the trade screen the way a cable club holds them -- the picker
-- and the confirm wait for the cart's own menus to close (Ui.occupied), and
-- in that time START > POKéMON can reorder the party, the BAG can take a held
-- item off, a PC can swap a mon out.  Picking and applying by slot number then
-- sends the snapshot mon to the peer while removing whatever is at that slot
-- now: one mon (or one held item) in two saves.
--
-- So every packed mon is remembered by what makes it that mon (identityOf:
-- species, personality, trainer id, egg flag, held item -- the item because a
-- mon that lost its item after the snapshot would still deliver it) and the
-- live party is only ever read *through* that identity: the picker's row is
-- mapped to the snapshot index the peer knows (pick), checked again before a
-- yes goes out (confirm) and found again by identity when the swap is made
-- (apply).  A mon that is no longer in the party as it was shown cancels the
-- trade rather than trading something else.  Sessions keeps a layer of its
-- own up from the pick until the trade is done, which freezes the field and
-- START for the exchange -- the cart's own trade screen owns the screen the
-- same way -- so the checks after the pick are the belt, not the braces.
--
-- ------- the other side's messages, in order and once
--
-- A pick is taken only while this side is picking or waiting for one, only
-- after their party is in, and only once: a second pick would swap the mon
-- under a "Trade for X?" the player is already reading.  Each yes carries
-- both picks as the sender understood them (`mine` / `yours`), and a yes
-- that does not name the two mons this side agreed to is no yes.  Anything
-- out of turn cancels.  Once both yeses are in ("done") a late bye changes
-- nothing: the peer is applying, and so must this side.
--
-- ------- names the cart can print
--
-- A received nickname, OT name or mail signature holding one of
-- { } [ ] # * @ ~ | ^ ` \ refuses the trade.  src/ui/game3/frlg_font.lua
-- reads "{...}" as a control tag (and throws on an unknown one in a
-- --developer run) and draws the rest blank, in every screen the engine owns
-- -- the party menu, the summary, the PC -- where this mod cannot map them the
-- way Gen3Ui.Font does its own text.  None of them is on the cart's naming
-- grid, so a name holding one was never typed on a cart.  Refused rather than
-- rewritten: the OT name is half of what makes a mon "traded" (obedience, the
-- boosted exp), and a quietly edited one is a different mon from the one the
-- player agreed to take.
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
-- This side's own reasons for calling a trade off (see the header), each read
-- after Sessions' "The trade stopped:".
local PARTY_CHANGED = "your party changed\nafter it was shown."
local OFFER_CHANGED = "the other game's\noffer changed."
local OUT_OF_TURN = "the other game\nanswered out of turn."
local BAD_NAME = "the other game sent\na name this game\ncan't print."
local NO_CART = "the other game did\nnot say which game\nit is."
M.PARTY_CHANGED, M.OFFER_CHANGED, M.OUT_OF_TURN = PARTY_CHANGED, OFFER_CHANGED, OUT_OF_TURN
M.BAD_NAME, M.NO_CART = BAD_NAME, NO_CART

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

-- What makes a party mon the one the peer was shown (see the header): its
-- species, personality and full trainer id, whether it is still an egg, and
-- the item in its hand.  Level, HP, status, exp and friendship are left out
-- -- they move while the player walks and none of them is anything a swap
-- could hand out twice.  nil for a slot with no mon in it.
local function identityOf(mon)
  if type(mon) ~= "table" then return nil end
  return ("%d:%d:%d:%d:%d:%d"):format(
    speciesOf(mon),
    math.floor(tonumber(mon.personality) or 0),
    math.floor(tonumber(mon.otId) or 0),
    math.floor(tonumber(mon.otSecretId) or 0),
    isEgg(mon) and 1 or 0,
    heldItemOf(mon))
end
M.identityOf = identityOf

-- True when the cart's font can print `name` as it stands (see the header):
-- none of the characters frlg_font reads as markup or draws blank.  A
-- missing name is printable (the codec fills an empty one in).
local UNPRINTABLE = "[{}%[%]#%*@~|%^`\\]"
function M.printableName(name)
  if name == nil then return true end
  if type(name) ~= "string" then return false end
  return name:find(UNPRINTABLE) == nil
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

local function familyForCart(cart)
  local Family = family()
  local fam = Family and try(Family.familyForCart, cart)
  if fam then return fam end
  return CART_FAMILY[tonumber(cart) or -1]
end

-- What the other side said about itself, re-derived.  nil when it said
-- nothing, or named a cart no Gen 3 family owns (family.lua familyForCart:
-- the cable club's VERSION_* codes for Ruby / Sapphire / Emerald and FireRed
-- / LeafGreen): handle cancels on nil.  Every Gen 3 build of this mod sends
-- it, and it is what versionGate and theirRefusal read the partner through --
-- a cart code nobody owns would skip both, so it is no answer at all.
function M.sanitizeInfo(raw)
  if type(raw) ~= "table" then return nil end
  local cart = whole(raw.version, 0, 255)
  if not (cart and familyForCart(cart)) then return nil end
  return {
    version = cart,
    progressFlags = whole(raw.progressFlags, 0, 255) or 0,
    game = type(raw.game) == "string" and CART[raw.game] and raw.game or nil,
  }
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
    myPick = nil,       -- snapshot (wire) index of the mon offered
    myLiveSlot = nil,   -- the party slot the picker showed it in
    theirPick = nil,
    myConfirm = nil,
    theirConfirm = nil,
    sentPacked = nil,   -- the packed party the peer was shown ...
    sentKeys = nil,     -- ... and each mon's identityOf, index for index
    appliedSlot = nil,  -- where the received mon landed
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

-- The party as the peer will see it -- and, kept beside it, the snapshot:
-- the packed mons themselves (sentPacked) and each one's identity
-- (sentKeys), index for index, which is what pick / confirm / apply read the
-- live party through (see the header).
function TradeSession:partyMessage()
  local P = protocol()
  local party = self:partyNow()
  local indices = {}
  for i = 1, math.min(#party, PARTY_SIZE) do indices[i] = i end
  self.sendIndices = indices
  local mons = P.packParty3(party, indices)
  local keys = {}
  for pos, slot in ipairs(indices) do keys[pos] = identityOf(party[slot]) end
  self.sentPacked, self.sentKeys = mons, keys
  local me = self.me or {}
  return {
    type = "party",
    mons = mons,
    mail = M.packMail(self.session, indices),
    gen3 = { version = me.version, progressFlags = me.progressFlags, game = me.game },
  }
end

-- The live party slot holding the mon that went out as snapshot index
-- `wire`, or nil when no mon in the party is that mon any more.  The slot it
-- was picked from is asked first (`hint`), so two mons that happen to share
-- an identity still resolve to the one the player chose.
function TradeSession:liveSlotOf(wire, hint)
  local key = self.sentKeys and self.sentKeys[wire]
  if key == nil then return nil end
  local party = self:partyNow()
  if hint and identityOf(party[hint]) == key then return hint end
  for i, mon in ipairs(party) do
    if identityOf(mon) == key then return i end
  end
  return nil
end

-- The snapshot index the peer knows the mon in live slot `index` by, or nil
-- when the picker's row is a mon the peer was never shown.
function TradeSession:wireSlotOf(index)
  local keys = self.sentKeys
  if not keys then return nil end
  local key = identityOf(self:partyNow()[index])
  if key == nil then return nil end
  if keys[index] == key then return index end
  for wire, sent in ipairs(keys) do
    if sent == key then return wire end
  end
  return nil
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
      -- names the engine's own screens will print (see the header)
      if not (M.printableName(mon.nickname) and M.printableName(mon.otName)
          and M.printableName(mailList[i] and mailList[i].playerName)) then
        return self:cancel(BAD_NAME)
      end
      party[i] = mon
      mails[i] = mailList[i]
    end
    local info = M.sanitizeInfo(msg.gen3)
    if not info then return self:cancel(NO_CART) end
    self.theirParty, self.theirMail = party, mails
    self.theirInfo = info
    local gate = self:versionGate()
    if gate then return self:cancel(gate) end
    self.reasons = {}
    if self.stage == "waitParty" then self.stage = "picking" end
  elseif msg.type == "pick" then
    if self.stage == "done" or self.stage == "cancelled" then return nil end
    -- Once, in turn, and only of a party this side has seen (see the header).
    if not self.theirParty or self.theirPick ~= nil
        or (self.stage ~= "picking" and self.stage ~= "waitPick") then
      return self:cancel(OUT_OF_TURN)
    end
    local index = whole(msg.index, 1, PARTY_SIZE)
    if not index or not self.theirParty[index] then
      return self:cancel("the other game picked a POKéMON it never showed")
    end
    self.theirPick = index
    self:advance()
  elseif msg.type == "confirm" then
    if self.stage == "done" or self.stage == "cancelled" then return nil end
    if self.stage ~= "confirming" or self.theirConfirm ~= nil then
      return self:cancel(OUT_OF_TURN)
    end
    local yes = msg.ok == true
    -- A yes names the two mons it agrees to; a yes to any other pair is no.
    if yes and (whole(msg.mine, 1, PARTY_SIZE) ~= self.theirPick
        or whole(msg.yours, 1, PARTY_SIZE) ~= self.myPick) then
      return self:cancel(OFFER_CHANGED)
    end
    self.theirConfirm = yes
    self:advance()
  elseif msg.type == "bye" then
    -- Both yeses in: the peer is applying, and a goodbye after it does not
    -- take this side's half back (that would leave its mon in two saves).
    if self.stage ~= "done" then self.stage = "cancelled" end
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

-- `index` is the live party slot the picker showed.  What goes on the wire
-- is the snapshot index the peer knows that mon by (see the header), and a
-- mon the peer was never shown -- the party changed under the picker --
-- cancels: the answer is then a bye, so the peer is let go too.
function TradeSession:pick(index)
  local wire = self:wireSlotOf(index)
  if not wire then
    self:cancel(PARTY_CHANGED)
    return { type = "bye" }
  end
  self.myPick = wire
  self.myLiveSlot = index
  self:advance()
  return { type = "pick", index = wire }
end

-- A yes is only a yes this cart can honour: the mon picked must still be in
-- the party as it was shown, and an offer theirRefusal names is answered no
-- on the player's behalf -- the reason kept on `error` for whoever tears the
-- session down.  The yes names both picks (`mine` / `yours`, see the header).
function TradeSession:confirm(ok)
  ok = ok == true
  if ok and not self:liveSlotOf(self.myPick, self.myLiveSlot) then
    ok = false
    self.error = PARTY_CHANGED
  end
  if ok then
    local why = self:theirRefusal()
    if why then
      ok = false
      self.error = why
    end
  end
  self.myConfirm = ok
  self:advance()
  return { type = "confirm", ok = ok, mine = self.myPick, yours = self.theirPick }
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
--
-- The mon sent is found by identity, never by slot number (see the header):
-- the peer is filing the snapshot of it, so what leaves this party is that
-- mon wherever it now stands -- and when it is nowhere, nothing leaves and
-- the answer is nil, which Sessions reports as a trade that did not complete.
-- `appliedSlot` is where the received mon landed.
function TradeSession:apply(game)
  if self.stage ~= "done" then
    mod.log:warn("Gen 3 trade apply called before both sides confirmed "
      .. "(stage=%s) -- leave the session and ask again", tostring(self.stage))
    return nil
  end
  -- The session running now, not the one the trade opened on: a soft reset
  -- and CONTINUE mid-trade replaces the whole table, and the old one is a
  -- party nobody will ever save again -- swapping there would hand the peer
  -- a mon this player still has on disk.
  local session = sessionOf(game or self.game) or self.session
  if type(session) == "table" then self.session = session end
  local received = self.theirParty and self.theirParty[self.theirPick]
  local party = type(session) == "table" and session.party
  local slot = type(party) == "table" and self:liveSlotOf(self.myPick, self.myLiveSlot) or nil
  local sent = slot and party[slot] or nil
  if not received then
    mod.log:warn("Gen 3 trade apply has no received POKéMON at their slot %s "
      .. "-- check the party from START > POKéMON before trading again",
      tostring(self.theirPick))
    return nil
  end
  if not sent then
    mod.log:warn("the POKéMON offered as party slot %s is no longer in the "
      .. "party as it was shown, so nothing left it -- check the party from "
      .. "START > POKéMON before trading again", tostring(self.myPick))
    return nil
  end
  self.appliedSlot = slot

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
