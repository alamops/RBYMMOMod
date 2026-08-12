-- Gen 2 trade over SessionNet: packMon2 / unpackMon2 + party-mail parallel
-- array + apply into Gold party / pokedex.
--
-- Upstream Protocol.TradeSession is still Gen 1 shaped (packMon, owned dex,
-- PikachuFollower). Gold's Cable Club TradeSession is not built yet
-- (docs/gen2-link-design.md §7), so the MMO path owns this twin. Same stage
-- machine and wire vocabulary as TradeSession; only the mon codec, mail
-- block, and apply side-effects differ.
--
-- Capability-tested: Sessions only opens this path when Protocol.packMon2
-- and unpackMon2 both exist. Gen 1 Sessions:beginTrade is untouched.

local _, mod = ...

local M = {}

local protocolTried, ProtocolMod
local mailTried, MailMod
local mailWarned

local function protocol()
  if protocolTried then return ProtocolMod end
  protocolTried = true
  local ok, p = pcall(require, "src.link.Protocol")
  if ok and type(p) == "table" then ProtocolMod = p end
  return ProtocolMod
end

local function mailApi()
  if mailTried then return MailMod end
  mailTried = true
  local ok, m = pcall(require, "src.core.gen2.Mail")
  if ok and type(m) == "table" then MailMod = m end
  return MailMod
end

local function warnMail(action, detail)
  if mailWarned then return end
  mailWarned = true
  mod.log:warn(
    "party mail could not be %s (%s) -- the mon and held item still trade; "
      .. "update gen1recomp so src.core.gen2.Mail is available, or clear mail "
      .. "before trading again",
    action, tostring(detail or "unavailable"))
end

-- True when this engine build can run a Gen 2 trade codec.
function M.capable()
  local P = protocol()
  return P ~= nil
    and type(P.packMon2) == "function"
    and type(P.unpackMon2) == "function"
end

-- Wire-safe mailmsg. Dense parallel arrays use `false` for an empty slot so
-- JSON round-trips keep wire positions aligned (nil holes collapse).
function M.sanitizeMail(entry)
  if entry == nil or entry == false then return nil end
  if type(entry) ~= "table" then return nil end
  local Mail = mailApi()
  local msgLen = (Mail and Mail.MAIL_MSG_LENGTH) or 32
  local authorLen = (Mail and Mail.AUTHOR_LENGTH) or 10
  local itemId = entry.type or entry.item
  if type(itemId) ~= "string" or itemId == "" then return nil end
  if Mail and Mail.isMail and not Mail.isMail(itemId) then return nil end
  local message = type(entry.message) == "string" and entry.message or ""
  local author = type(entry.author) == "string" and entry.author or ""
  local authorId = math.max(0, math.min(65535,
    math.floor(tonumber(entry.authorId) or 0)))
  local species = type(entry.species) == "string" and entry.species or nil
  return {
    type = itemId,
    message = message:sub(1, msgLen),
    author = author:sub(1, authorLen),
    authorId = authorId,
    species = species,
  }
end

-- Parallel mail array for the same indices packParty would use.
function M.packMail(save, indices)
  local out = {}
  local Mail = mailApi()
  local partyMail = save and save.mail and save.mail.party
  if not Mail and not partyMail then
    warnMail("packed", "Mail API and save.mail both missing")
  end
  local function slotMail(slot)
    if Mail and Mail.get then
      local ok, entry = pcall(Mail.get, save, slot)
      if not ok then
        warnMail("packed", entry)
        return nil
      end
      return entry
    end
    return partyMail and partyMail[slot] or nil
  end
  if indices then
    for pos, slot in ipairs(indices) do
      out[pos] = M.sanitizeMail(slotMail(slot)) or false
    end
    return out
  end
  local party = save and save.party or {}
  for i = 1, #party do
    out[i] = M.sanitizeMail(slotMail(i)) or false
  end
  return out
end

function M.unpackMailList(raw)
  local out = {}
  if type(raw) ~= "table" then return out end
  for i, entry in ipairs(raw) do
    out[i] = M.sanitizeMail(entry)
  end
  return out
end

function M.applyMail(save, slot, entry)
  if not (save and slot) then return false end
  local Mail = mailApi()
  local clean = M.sanitizeMail(entry)
  if Mail and Mail.set and Mail.clear then
    local ok, err = pcall(function()
      if clean then
        Mail.set(save, slot, clean)
      else
        Mail.clear(save, slot)
      end
    end)
    if not ok then
      warnMail("applied", err)
      return false
    end
    return true
  end
  -- Soft path when Mail.lua is absent: still keep save.mail.party in shape
  -- so a later engine load can read it.
  save.mail = save.mail or { party = {}, box = {} }
  save.mail.party = save.mail.party or {}
  save.mail.party[slot] = clean
  warnMail("applied via save.mail", "Mail module unavailable")
  return clean ~= nil
end

local function packParty2(party, indices)
  local P = protocol()
  local mons = {}
  if indices then
    for _, i in ipairs(indices) do
      mons[#mons + 1] = P.packMon2(party[i])
    end
    return mons
  end
  for _, mon in ipairs(party) do
    mons[#mons + 1] = P.packMon2(mon)
  end
  return mons
end

local function tradeEvolveTo(data, received)
  local def = data and data.pokemon and data.pokemon[received.species]
  for _, evo in ipairs((def and def.evolutions) or {}) do
    local method = evo.method
    if method == "TRADE" or method == "EVOLVE_TRADE" then
      return evo.species or evo.into
    end
  end
  return nil
end

local function emit(name, payload)
  pcall(function()
    local Runtime = require("src.mods.Runtime")
    if Runtime.wants and not Runtime.wants(name) then return end
    Runtime.emit(name, payload)
  end)
end

local function markDex(save, species)
  if not (save and save.pokedex and species) then return end
  local dex = save.pokedex
  dex.seen = dex.seen or {}
  dex.seen[species] = true
  -- Gen 2 uses caught; Gen 1 owned. Prefer caught when the save already
  -- carries it or declares generation 2.
  if dex.caught ~= nil or save.generation == 2 then
    dex.caught = dex.caught or {}
    dex.caught[species] = true
  else
    dex.owned = dex.owned or {}
    dex.owned[species] = true
  end
end

-- -------------------------------------------------------------------
-- TradeSession twin (Gen 2 codecs + mail)
-- -------------------------------------------------------------------

local TradeSession = {}
TradeSession.__index = TradeSession
M.TradeSession = TradeSession

-- opts: { subset, strict, peerName } -- same as Protocol.TradeSession
function TradeSession.new(game, opts)
  opts = opts or {}
  local save = game and game.save
  local party = save and save.party
  local self = setmetatable({
    game = game,
    data = game and game.data,
    save = save,
    party = party,
    subset = opts.subset or false,
    strict = opts.strict or false,
    peerName = opts.peerName,
    stage = opts.subset and "waitRecords" or "waitParty",
    sendIndices = nil,
    eligible = nil,
    reasons = {},
    theirParty = nil,
    theirMail = nil,
    myPick = nil,
    theirPick = nil,
    myConfirm = nil,
    theirConfirm = nil,
  }, TradeSession)
  if not self.subset then
    local all = {}
    for i = 1, #(party or {}) do all[i] = i end
    self.sendIndices = all
  end
  return self
end

function TradeSession:opening()
  if self.subset then
    local P = protocol()
    return P.recordsMessage(self.data, self.party)
  end
  return self:partyMessage()
end

function TradeSession:partyMessage()
  return {
    type = "party",
    mons = packParty2(self.party, self.sendIndices),
    mail = M.packMail(self.save, self.sendIndices),
  }
end

function TradeSession:_negotiate(theirRecords)
  local P = protocol()
  local mine = P.recordsMessage(self.data, self.party)
  self.eligible, self.reasons =
    P.eligibleParty(self.party, mine, theirRecords)
  local indices = {}
  for i = 1, #self.party do
    if self.eligible[i] then indices[#indices + 1] = i end
  end
  self.sendIndices = indices
end

function TradeSession:canPick(index)
  return self.eligible == nil or self.eligible[index] == true
end

function TradeSession:handle(msg)
  local P = protocol()
  if msg.type == "records" then
    if self.stage ~= "waitRecords" then return nil end
    self:_negotiate(msg)
    self.stage = "waitParty"
    return self:partyMessage()
  elseif msg.type == "party" then
    -- Keep theirParty and theirMail the same length: unpack mail in the same
    -- loop as mons so a non-strict skip drops that mail index too (aligned
    -- indices, never a silent slide of later mail onto earlier mons).
    self.theirParty = {}
    self.theirMail = {}
    local mailList = M.unpackMailList(msg.mail)
    for i, packed in ipairs(msg.mons or {}) do
      local mon, why = P.unpackMon2(self.data, packed, { strict = self.strict })
      if mon then
        local n = #self.theirParty + 1
        self.theirParty[n] = mon
        self.theirMail[n] = mailList[i]
      elseif self.strict then
        self.stage = "cancelled"
        self.error = why or "the other game sent an unknown POKéMON"
        return nil
      end
    end
    if self.stage == "waitParty" then self.stage = "picking" end
  elseif msg.type == "pick" then
    self.theirPick = msg.index
    self:advance()
  elseif msg.type == "confirm" then
    self.theirConfirm = msg.ok
    self:advance()
  elseif msg.type == "bye" then
    self.stage = "cancelled"
  end
  return nil
end

function TradeSession:wireIndex(index)
  for pos, i in ipairs(self.sendIndices or {}) do
    if i == index then return pos end
  end
  return index
end

function TradeSession:pick(index)
  self.myPick = index
  self:advance()
  return { type = "pick", index = self:wireIndex(index) }
end

function TradeSession:confirm(ok)
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

-- Apply into Gen 2 party + party mail. Returns received mon, evolveTo.
function TradeSession:apply(game)
  game = game or self.game
  if self.stage ~= "done" then
    mod.log:warn("Gen 2 trade apply called before both sides confirmed "
      .. "(stage=%s) -- leave the session and ask again",
      tostring(self.stage))
    return nil
  end
  local received = self.theirParty and self.theirParty[self.theirPick]
  local sent = self.party and self.party[self.myPick]
  if not received then
    mod.log:warn("Gen 2 trade apply has no received mon at wire index %s "
      .. "-- check the party from START > POKéMON before trading again",
      tostring(self.theirPick))
    return nil
  end
  received.traded = true
  emit("pokemon.received",
    { mon = received, from = "link", peerName = self.peerName })
  self.party[self.myPick] = received
  M.applyMail(game and game.save or self.save, self.myPick,
    self.theirMail and self.theirMail[self.theirPick])
  if game and game.save then
    markDex(game.save, received.species)
  end
  local evolveTo = tradeEvolveTo(self.data, received)
  emit("trade.completed",
    { sent = sent, received = received, evolveTo = evolveTo })
  return received, evolveTo
end

return M
