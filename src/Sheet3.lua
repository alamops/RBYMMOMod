-- The Gen 3 battle sheet, ruleset and bag: what a FireRed / LeafGreen /
-- Emerald client uploads before a mediated fight.
--
-- One builder, three screens.  src/MediatedBattle.lua (1v1, and the wild /
-- 1xNPC fights SoloBattle puts on it), src/CoopBattle.lua (2v2) and
-- src/SoloBattle.lua all describe a Gen 3 monster through here, so a monster
-- cannot be one thing in a 1v1 and another in a co-op fight.  The contract is
-- C4 in docs/plans/gen3-battle-sheet.md (§2 the sheet, §3 the ruleset, §4 the
-- bag); src/BattleSim3/ is its reference reader and `Wire.battleMon`'s Gen 3
-- dialect (T7) its sanitiser.
--
-- ------- why the client builds it
--
-- The hub holds no ROM tables (CLAUDE.md, legal posture): every number a
-- formula needs rides on the sheet or the ruleset, decoded by *this* client
-- from *this* player's cart and thrown away with the battle.  So everything
-- below is read out of the running engine through src/Gen3.lua -- species
-- rows, move rows, item hold effects, the type chart -- and nothing is ever
-- written down here except pret enum values the battle code itself branches
-- on (the bag ids of §4, the Deoxys species number).
--
-- ------- the shape of a Gen 3 mon (read, never assumed)
--
-- A party mon is a plain table (src/core/game3/party.lua giveMon,
-- save_mon.normalize, Protocol.unpackMon3): numeric internal `species`,
-- numeric `moves` with parallel `pp` / `maxPp`, `ivs` / `evs` keyed
-- hp/atk/def/spe/spa/spd, `personality`, numeric `ability`, `gender`
-- "M"/"F"/"U", `heldItem` (or `item`), `friendship` (or `happiness`), the
-- battle stats flat on the mon (`maxHp attack defense speed spAtk spDef`,
-- Pokemon.applyStats) and sometimes again under `stats`.  Every read below
-- tries the shapes the engine writes and falls back to computing the number
-- through Pokemon.calcStats when a mon arrives without it.
--
-- ------- the API (T11 / T12 call these too)
--
--   Sheet3.mon(session, mon, slot, opts)   one C4 sheet, or nil + reason
--   Sheet3.mons(game, party, opts)         any party (NPC trainer, wild mon)
--   Sheet3.party(game, opts)               this player's own session party
--   Sheet3.moves(mon, opts)                C4 move rows for a party mon
--   Sheet3.moveRow(moveId, pp, maxPp, opts) one move row
--   Sheet3.arenaMind(moveId)               the cart's Battle Arena mind rating (Emerald), or nil
--   Sheet3.stampArenaMind(sheets)          ...stamped on built sheets' move rows
--   Sheet3.ruleset(game, opts)             { generation, typeTable, movePool, terrain?, weather?, underwater? }
--   Sheet3.typeTable()  Sheet3.movePool()  the two halves of the ruleset
--   Sheet3.bag(game)                       the §4 bag upload ({ id, count, name })
--   Sheet3.bagEffect(id)                   the sim's own catalog row for an id
--   Sheet3.itemEffect(id)                  the menu's reading of it (ball / needsParty / ...)
--   Sheet3.itemFailsOnFainted(effect)
--   Sheet3.trainerBag(trainer)             an NPC's kit, §4 ids only
--   Sheet3.monFromSheet(sheet, session)    rebuild a party mon from a caught sheet
--   Sheet3.applyToMon(mon, sheet)          write a referee's hp / status / pp onto a party mon
--   Sheet3.hiddenPower(ivs)                (type, power), pret Cmd_hiddenpowercalc
--   Sheet3.displayName(mon, species)       the name the sheet uploads (wire alphabet)
--   Sheet3.localName(mon, species)         the cart's own spelling, for local text
--   Sheet3.wireName(text, limit)           a cart string in the wire's alphabet
--
-- opts: { wild = true } stamps `catchRate`, `safariFleeRate` and `fateful`
-- (the wild seat's sheet only); { arena = true } stamps each move row's
-- `arenaMind` (the Battle Arena's judge, contract C3 of
-- docs/plans/gen3-solo-remaining-fights.md);
-- { link = true } gives Deoxys its link-battle stats -- a fight between two
-- players' carts only (see `statsFor`); every other fight, and the default,
-- is the forme this cart's own battles use.  { own = true } marks this
-- player's own monsters (Sheet3.party sets it): off the link, their sheets
-- carry the obedience check's `traded` / `unfateful` (contract K2 of
-- docs/plans/gen3-badge-rules.md).
--
-- Names that ride the wire are the cart's names spelled in the wire's
-- alphabet (`M.wireName`: é is E, ♂ / ♀ are M / F); the cart's own spelling
-- stays on this client for its own boxes (`M.localName`).
--
-- Nothing here raises: an engine read that throws is a missing field, and a
-- monster this client cannot describe is skipped with a reason rather than
-- taking the party with it.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local Gen3 = need("Gen3")

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.GENERATION = 3

-- The two new caps of docs/plans/gen3-battle-sheet.md §3.  Config spells them
-- once T7's Wire dialect lands; until then the spec's numbers stand here.
M.MOVE_POOL_MAX = tonumber(Config.BATTLE_MOVE_POOL3_MAX) or 360
M.TYPE_TABLE_MAX = tonumber(Config.BATTLE_TYPE_TABLE3_MAX) or 150   -- triples

-- pret SPECIES_DEOXYS (pokefirered/include/constants/species.h:419).
M.SPECIES_DEOXYS = 410

-- pret SPECIES_EGG.  An egg is not a fighter.
local SPECIES_EGG = 412

-- Mew and Deoxys: the two species the obedience check asks about their
-- fateful-encounter bit (battle/engine.lua:1299, pret
-- IsBattlerModernFatefulEncounter).
local FATEFUL_SPECIES = { [151] = true, [M.SPECIES_DEOXYS] = true }

local STAT_KEYS = { "hp", "atk", "def", "spe", "spa", "spd" }

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

-- The engine module, only ever on a Gen 3 boot (Gen3.engine answers nil
-- everywhere else, so no src.core.game3.* require can reach Red or Gold).
local function engine(name)
  return Gen3.engine(name)
end

-- The sim's own tables, loaded the first time a Gen 3 path asks: a Gen 1 or
-- Gen 2 boot never pays for the Gen 3 intermediator's modules.
local simItems
local function SimItems()
  if simItems == nil then
    local ok, got = pcall(need, "BattleSim3/Items")
    simItems = (ok and type(got) == "table") and got or false
  end
  return simItems or nil
end

-- ------------------------------------------------------------------
-- small readers
-- ------------------------------------------------------------------

local function speciesOf(mon)
  if type(mon) ~= "table" then return nil end
  local sp = tonumber(mon.species) or tonumber(mon.speciesId)
  if sp then return floor(sp) end
  local P = engine("src.core.game3.pokemon")
  local got = P and try(P.speciesOf, mon)
  return tonumber(got)
end
M.speciesOf = speciesOf

local function isEgg(mon)
  if mon.isEgg == true then return true end
  return speciesOf(mon) == SPECIES_EGG
end

local function statusOf(mon)
  local s = mon.status
  if type(s) ~= "string" or s == "" then return nil end
  s = s:upper()
  if s == "SLP" or s == "PSN" or s == "BRN" or s == "FRZ" or s == "PAR" or s == "TOX" then
    return s
  end
  return nil
end

local function heldItemOf(mon)
  local id = mon.heldItem
  if id == nil or id == 0 then id = mon.item end
  local n = tonumber(id)
  if n then return max(0, floor(n)) end
  if type(id) == "string" and id ~= "" then
    local ItemsData = engine("src.core.game3.items_data")
    local num = ItemsData and try(ItemsData.toNumericId, id)
    return tonumber(num) or 0
  end
  return 0
end
M.heldItemOf = heldItemOf

-- The move id at 1-based slot `i`, whichever shape the mon keeps its moves in.
local function moveAt(mon, i)
  local list = type(mon) == "table" and mon.moves or nil
  if type(list) ~= "table" then return nil end
  local entry = list[i]
  if type(entry) == "table" then return tonumber(entry.id or entry.num or entry.move) end
  return tonumber(entry)
end

local function ppAt(mon, i, which)
  local list = mon[which]
  if type(list) == "table" and tonumber(list[i]) then return int(list[i], 0) end
  local entry = type(mon.moves) == "table" and mon.moves[i] or nil
  if type(entry) == "table" then
    local v = which == "maxPp" and (entry.maxPp or entry.pp) or entry.pp
    if tonumber(v) then return int(v, 0) end
  end
  return nil
end

-- ------------------------------------------------------------------
-- Hidden Power (the only IV-derived value a formula reads)
-- ------------------------------------------------------------------

-- pret Cmd_hiddenpowercalc (pokefirered/src/battle_script_commands.c:8503),
-- the engine's Damage.hiddenPower: the power bits are each IV's second bit,
-- the type bits its first, in hp/atk/def/spe/spa/spd order; the type skips
-- MYSTERY (9).  Arithmetic, not data -- written out so it answers headless.
function M.hiddenPower(ivs)
  ivs = type(ivs) == "table" and ivs or {}
  local function iv(a, b) return max(0, int(ivs[a] or ivs[b], 0)) end
  local order = {
    iv("hp", "HP"), iv("atk", "attack"), iv("def", "defense"),
    iv("spe", "speed"), iv("spa", "spAtk"), iv("spd", "spDef"),
  }
  local powerBits, typeBits, weight = 0, 0, 1
  for i = 1, 6 do
    powerBits = powerBits + weight * (floor(order[i] / 2) % 2)
    typeBits = typeBits + weight * (order[i] % 2)
    weight = weight * 2
  end
  local power = floor(40 * powerBits / 63) + 30
  local t = floor(15 * typeBits / 63) + 1
  if t >= 9 then t = t + 1 end
  return t, power
end

-- ------------------------------------------------------------------
-- stats
-- ------------------------------------------------------------------

-- The engine's link-battle stat rule for Deoxys (pokefirered/src/pokemon.c:6163,
-- engine link/battle.lua LB.applyLinkStats): FireRed, LeafGreen and Emerald
-- each carry a different forme's base stats, so a cross-version fight uses the
-- ROM's `linkStats` row instead.  Applied to a *copy* -- the party mon keeps
-- the stats its own cart gives it.  nil when there is no link row to use.
local function deoxysLinkStats(mon)
  local LB = engine("src.core.game3.link.battle")
  if not (LB and type(LB.applyLinkStats) == "function") then return nil end
  local copy = {}
  for k, v in pairs(mon) do copy[k] = v end
  local ok, got = pcall(LB.applyLinkStats, copy)
  if not (ok and type(got) == "table") then return nil end
  return {
    atk = int(got.attack or got.atk, nil), def = int(got.defense or got.def, nil),
    spe = int(got.speed or got.spe, nil), spa = int(got.spAtk or got.spa, nil),
    spd = int(got.spDef or got.spd, nil),
  }
end

-- The five battle stats and the maximum HP, final (nature, IVs, EVs applied).
local function statsFor(mon, species, opts)
  local s = type(mon.stats) == "table" and mon.stats or {}
  local out = {
    hp = int(mon.maxHp or s.hp or s.maxHp, nil),
    atk = int(mon.attack or s.attack or s.atk or mon.atk, nil),
    def = int(mon.defense or s.defense or s.def or mon.def, nil),
    spe = int(mon.speed or s.speed or s.spe or mon.spe, nil),
    spa = int(mon.spAtk or s.spAtk or s.specialAttack or s.spa or mon.spa, nil),
    spd = int(mon.spDef or s.spDef or s.specialDefense or s.spd or mon.spd, nil),
  }
  local missing = false
  for _, k in ipairs(STAT_KEYS) do
    if out[k] == nil then missing = true end
  end
  if missing then
    local P = engine("src.core.game3.pokemon")
    local calc = P and try(P.calcStats, species, mon.level, mon.ivs, mon.evs, mon.personality)
    if type(calc) == "table" then
      out.hp = out.hp or int(calc.maxHp, nil)
      out.atk = out.atk or int(calc.attack, nil)
      out.def = out.def or int(calc.defense, nil)
      out.spe = out.spe or int(calc.speed, nil)
      out.spa = out.spa or int(calc.spAtk, nil)
      out.spd = out.spd or int(calc.spDef, nil)
    end
  end
  -- Link stats are for a fight between two carts only: a solo, wild or NPC
  -- fight is this cart's own battle, which reads the forme this cart carries.
  if species == M.SPECIES_DEOXYS and opts and opts.link == true then
    local link = deoxysLinkStats(mon)
    if link then
      for k, v in pairs(link) do if v then out[k] = v end end
    end
  end
  for _, k in ipairs(STAT_KEYS) do
    if out[k] == nil then return nil end
  end
  return out
end

-- Beat Up's base Attack / Defense (the species row; Deoxys in a fight between
-- two carts: its link row, as `statsFor`).
local function beatUpOf(species, info, opts)
  local base = info and info.baseStats or {}
  local atk, def = int(base.atk, nil), int(base.def, nil)
  if species == M.SPECIES_DEOXYS and opts and opts.link == true then
    local P = engine("src.core.game3.pokemon")
    local meta = P and try(P.speciesMeta, species)
    local row = type(meta) == "table" and meta.linkStats or nil
    if type(row) == "table" and #row >= 6 then
      atk, def = int(row[2], atk), int(row[3], def)
    end
  end
  if not (atk and def) then return nil end
  return { atk = clamp(atk, 1, 255), def = clamp(def, 1, 255) }
end

-- ------------------------------------------------------------------
-- moves
-- ------------------------------------------------------------------

-- A token the sim and Wire both take (`^[%w_%-]+$`, at most 40): the engine's
-- own constant name (THUNDERBOLT), else the display name spelled as one, else
-- the number.
local function tokenFor(info, id)
  local token = info and info.constName
  if type(token) == "string" then
    token = token:gsub("^MOVE_", "")
    if token:match("^[%w_%-]+$") and #token <= 40 then return token end
  end
  local name = info and info.name
  if type(name) == "string" and name ~= "" then
    token = name:upper():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if token ~= "" and #token <= 40 then return token end
  end
  return "MOVE_" .. tostring(id)
end
M.tokenFor = tokenFor

-- ------- the Battle Arena's mind ratings (Emerald)
--
-- pret pokeemerald src/battle_arena.c sMindRatings: one signed byte per move
-- (mostly 1; PROTECT / DETECT / ENDURE -1; a few 0), the Mind points a move
-- earns its user when used in the Arena or the Fallarbor tent
-- (battle_util.c:288 `gBattleStruct->arenaMindPoints[battler] +=
-- sMindRatings[move]`).  A cart table, so it is read from the player's own
-- cart at run time -- the engine decodes it into the Frontier manifest
-- (src/import/gba/rse/frontier_f2_extract.lua `mindRatings`, indexed move
-- number + 1, read by battle/facility_arena.lua addMind) -- and rides on the
-- move row as `arenaMind` for the referee's judge (contract C3 `rules.arena`
-- of docs/plans/gen3-solo-remaining-fights.md, wave 3).  FireRed / LeafGreen
-- and a cart without the manifest
-- have none: nil, and no row carries the field.  Read once per cart.
local arenaMinds, arenaMindsFor = nil, nil
function M.arenaMindTable()
  local version = Gen3.version()
  if arenaMindsFor == version and arenaMinds ~= nil then return arenaMinds or nil end
  arenaMindsFor = version
  arenaMinds = false
  local F2 = engine("src.core.game3.rse.frontier.f2_data")
  local arena = F2 and try(F2.arena)
  local ratings = type(arena) == "table" and arena.mindRatings or nil
  if type(ratings) == "table" then arenaMinds = ratings end
  return arenaMinds or nil
end

-- Forget the cart's table (a suite that swaps carts under one version).
function M.resetArenaMinds() arenaMinds, arenaMindsFor = nil, nil end

-- One move's mind rating (-128..127), or nil when this cart has none.
function M.arenaMind(moveId)
  local id = int(moveId, nil)
  if not id or id < 0 then return nil end
  local ratings = M.arenaMindTable()
  if not ratings then return nil end
  return clamp(int(ratings[id + 1], 0), -128, 127)
end

-- Stamp `arenaMind` on every move row of already-built sheets (a party the
-- screen uploaded before the fight knew it was the Arena's).  How many rows.
function M.stampArenaMind(sheets)
  local n = 0
  if not M.arenaMindTable() then return n end
  for _, sheet in ipairs(type(sheets) == "table" and sheets or {}) do
    for _, row in ipairs(type(sheet) == "table" and type(sheet.moves) == "table" and sheet.moves or {}) do
      if type(row) == "table" then
        local mind = M.arenaMind(row.num)
        if mind ~= nil then row.arenaMind = mind; n = n + 1 end
      end
    end
  end
  return n
end

-- One move row (docs/plans/gen3-battle-sheet.md §2, "Move row").  nil for an
-- empty slot or a move this cart has no row for.  opts: { arena = true }
-- stamps the cart's `arenaMind` (above).
function M.moveRow(moveId, pp, maxPp, opts)
  local id = int(moveId, 0)
  if id <= 0 then return nil end
  local info = Gen3.moveInfo(id)
  if not info then return nil end
  local full = clamp(int(maxPp, info.pp) or 0, 0, 64)
  local left = clamp(int(pp, full) or 0, 0, 64)
  if left > full then full = left end
  local row = {
    id = tokenFor(info, id),
    name = M.wireName(info.name, "move") or nil,
    num = id,
    pp = left,
    maxPp = full,
    power = clamp(int(info.power, 0), 0, 255),
    type = clamp(int(info.type, 0), 0, 17),
    accuracy = clamp(int(info.accuracy, 0), 0, 100),
    effect = clamp(int(info.effect, 0), 0, 213),
    chance = clamp(int(info.secondaryChance, 0), 0, 100),
    target = max(0, int(info.target, 0)),
    priority = clamp(int(info.priority, 0), -7, 7),
    flags = clamp(int(info.flags, 0), 0, 63),
  }
  if type(opts) == "table" and opts.arena then row.arenaMind = M.arenaMind(id) end
  return row
end

-- Every move a party mon knows, as rows, in slot order (opts: moveRow's).
function M.moves(mon, opts)
  local out = {}
  if type(mon) ~= "table" then return out end
  for i = 1, 4 do
    local id = moveAt(mon, i)
    if id and id > 0 then
      local row = M.moveRow(id, ppAt(mon, i, "pp"), ppAt(mon, i, "maxPp"), opts)
      if row then out[#out + 1] = row end
    end
    if #out >= Config.BATTLE_MOVE_MAX then break end
  end
  return out
end

-- ------------------------------------------------------------------
-- one monster
-- ------------------------------------------------------------------

-- The cart spells names in its own charset, which the engine hands over as
-- UTF-8: POKé BALL, NIDORAN♂, a nickname with an é in it.  The wire's
-- alphabet (Wire.text) is plain ASCII and *drops* anything else, so "POKé
-- BALL" arrived as "POK BALL" and both NIDORAN as the same "NIDORAN".
-- Spelled out before the wire sees it instead: é / É are E, ♂ is M and ♀ is
-- F -- the engine's own ASCII spelling of the two NIDORAN
-- (src/core/game3/pokemon.lua NIDORANM / NIDORANF), which both the cart font
-- and the mod's font draw.  Anything else is left for Wire to judge.
local SPELL_OUT = {
  ["\195\169"] = "E", ["\195\137"] = "E",          -- é É
  ["\226\153\130"] = "M", ["\226\153\128"] = "F", -- ♂ ♀
}

function M.spellOut(text)
  if type(text) ~= "string" then return text end
  return (text:gsub("\195[\169\137]", SPELL_OUT):gsub("\226\153[\128\130]", SPELL_OUT))
end

-- A cart string in the wire's alphabet: spelled out, then Wire's own cut
-- (`limit` is Wire.name's when nil, Wire.moveName's when "move").
function M.wireName(text, limit)
  if type(text) ~= "string" then return nil end
  local spelled = M.spellOut(text)
  if limit == "move" then return Wire.moveName(spelled) end
  return Wire.name(spelled)
end

-- The name the sheet uploads: the nickname, else the species, in the wire's
-- alphabet -- this is what the referee narrates under on *both* screens.
local function displayName(mon, species)
  local nick = mon.nickname
  if type(nick) == "string" and nick ~= "" then
    local clean = M.wireName(nick)
    if clean then return clean end
  end
  return M.wireName(Gen3.speciesName(species) or "") or M.wireName(mon.name or "")
    or "POKEMON"
end
M.displayName = displayName

-- The same name as the cart spells it, for this client's own boxes ("NIDORAN♂
-- was added to the party!"): the cart's font draws é and the gender signs, so
-- nothing is cut here.  Falls back to the wire spelling when the cart has no
-- name to give.
function M.localName(mon, species)
  mon = type(mon) == "table" and mon or {}
  local nick = mon.nickname
  if type(nick) == "string" and nick:match("%S") then return nick end
  local name = Gen3.speciesName(species or speciesOf(mon))
  if type(name) == "string" and name ~= "" then return name end
  return displayName(mon, species or speciesOf(mon))
end

local function abilityOf(mon, species, info)
  local id = int(mon.ability or mon.abilityId, nil)
  if id and id > 0 and id <= 255 then return id end
  local pair = info and info.abilities or {}
  local a1, a2 = int(pair[1], 0), int(pair[2], 0)
  if a2 ~= 0 and (int(mon.personality, 0) % 2) == 1 then return a2 end
  return a1
end

-- Contract K2's `traded` (docs/plans/gen3-badge-rules.md): the engine battle's
-- own reading, the one its obedience check asks (battle/engine.lua:1276
-- Engine.isTradedMon, pokefirered/src/pokemon.c:5965, called from
-- Engine.disobedient) -- an OT id other than the player's, or an OT name other
-- than theirs when both are known.  Not Exp3.traded: that asks
-- Pokemon.isTradedMon (pret IsOtherTrainer), which compares the names only up
-- to the end of the OT's and falls back to `mon.ot`, so where one name is a
-- prefix of the other the two answer differently; this sheet feeds the
-- obedience rule, so it takes that rule's reading.  The player is the
-- session's trainer the way the engine resolves it; a session with no trainer
-- id at all (where the engine falls back to a placeholder) is not a trade.
local function tradedOf(mon)
  if mon.otId == nil then return false end
  local s = Gen3.session()
  if type(s) ~= "table" then return false end
  local pid = s.trainerId or s.id or s.playerId
  if pid == nil then return false end
  local pname = s.name or s.playerName
  return tonumber(mon.otId) ~= tonumber(pid)
    or (mon.otName ~= nil and pname ~= nil and tostring(mon.otName) ~= tostring(pname))
end

-- Contract K2's `unfateful`: does the obedience check hold this Mew / Deoxys
-- to the always-disobey rule?  The engine reads one field for it and applies
-- the rule to an explicit false only (battle/engine.lua:1299,
-- `mon.fatefulEncounter == false`): a link-traded monster carries the bit as a
-- boolean (src/link/Protocol.lua unpackMon3), an event encounter sets it true
-- (scripting/natives_events.lua, natives_event_islands.lua), and a monster
-- that never had the field obeys the ordinary rules -- a save import keeps the
-- cart's ribbon bit as `modernFatefulEncounter`, which that check does not
-- read.  So the sheet names the one case that check punishes, an explicit
-- false, and says nothing otherwise: an absent flag reads as the engine's
-- nil, the ordinary rules, so a sheet that leaves it out can never cost a
-- Mew its obedience (the referee reads `unfateful == true`, not "no fateful
-- bit").  Any other species never asks, and carries nothing.
local function unfatefulOf(mon, species)
  if not FATEFUL_SPECIES[species] then return false end
  return mon.fatefulEncounter == false
end

-- One C4 sheet.  `slot` is the 0-based party index the sheet was cut from
-- (the address every `mon` field on the wire is stated in).  nil plus a
-- reason for anything that cannot fight: an egg, an unknown species, a mon
-- with no moves this cart can describe.
function M.mon(session, mon, slot, opts)
  opts = opts or {}
  if type(mon) ~= "table" then return nil, "not a mon" end
  if isEgg(mon) then return nil, "an egg" end
  local species = speciesOf(mon)
  if not species or species < 1 or species > (Config.GEN3_SPECIES_MAX or 411) then
    return nil, "unknown species"
  end
  local info = Gen3.speciesInfo(species)
  if not info then return nil, "no species row" end
  local level = clamp(int(mon.level, 1), 1, 100)
  local stats = statsFor(mon, species, opts)
  if not stats then return nil, "no stats" end
  local moves = M.moves(mon, opts)
  if #moves == 0 then return nil, "no moves" end

  local maxHp = clamp(stats.hp or 1, 1, 999)
  local hp = clamp(int(mon.hp, maxHp), 0, maxHp)
  local types = { clamp(int(info.types[1], 0), 0, 17) }
  local t2 = clamp(int(info.types[2], types[1]), 0, 17)
  if t2 ~= types[1] then types[2] = t2 end
  local ability = abilityOf(mon, species, info)
  local held = heldItemOf(mon)
  local item = held > 0 and Gen3.itemInfo(held) or nil
  local nature = int(mon.nature, nil)
  if not nature or nature < 0 or nature > 24 then nature = int(mon.personality, 0) % 25 end
  local hpType, hpPower = M.hiddenPower(mon.ivs)
  local gender = mon.gender
  if gender ~= "M" and gender ~= "F" and gender ~= "U" then
    -- A mon that carries no gender field has the one its species ratio and
    -- personality give it, the way `monFromSheet` rebuilds one.
    local P = engine("src.core.game3.pokemon")
    local got = P and try(P.gender, species, int(mon.personality, 0) % 4294967296)
    gender = (got == "M" or got == "F") and got or "U"
  end
  local status = statusOf(mon)

  local sheet = {
    generation = 3,
    species = displayName(mon, species),
    speciesId = tostring(species),
    speciesNum = species,
    slot = clamp(int(slot, 0), 0, Wire.SLOT_MAX or 5),
    level = level,
    hp = hp,
    maxHp = maxHp,
    stats = {
      atk = clamp(stats.atk, 1, 999), def = clamp(stats.def, 1, 999),
      spe = clamp(stats.spe, 1, 999), spa = clamp(stats.spa, 1, 999),
      spd = clamp(stats.spd, 1, 999),
    },
    types = types,
    ability = clamp(ability, 0, Config.GEN3_ABILITY_MAX or 77),
    abilityName = M.wireName(Gen3.abilityName(ability) or "", "move") or nil,
    heldItem = clamp(held, 0, Config.GEN3_ITEM_MAX or 376),
    holdEffect = clamp(int(item and item.holdEffect, 0), 0, 66),
    holdEffectParam = clamp(int(item and item.holdEffectParam, 0), 0, 255),
    itemName = held > 0 and M.wireName(Gen3.itemName(held) or "", "move") or nil,
    gender = gender,
    friendship = clamp(int(mon.friendship or mon.happiness, info.baseFriendship or 70), 0, 255),
    weight = clamp(int(info.weight, 0), 0, 9999),
    nature = nature,
    hiddenPower = { type = hpType, power = hpPower },
    beatUp = beatUpOf(species, info, opts) or { atk = 1, def = 1 },
    status = status,
    moves = moves,
  }
  if sheet.heldItem == 0 then sheet.holdEffect, sheet.holdEffectParam = 0, 0 end
  if status == "SLP" then
    local turns = int(mon.sleep or mon.sleepTurns, nil)
    if turns and turns > 0 then sheet.sleepTurns = clamp(turns, 0, 7) end
  end
  if opts.wild then
    sheet.catchRate = clamp(int(info.catchRate, 255), 0, 255)
    -- The species' Safari Zone flee rate (pret gSpeciesInfo .safariZoneFleeRate,
    -- 0..255; the engine decodes it as speciesMeta's `safariZoneFleeRate`),
    -- FireRed / LeafGreen's escape factor at a Safari fight's start
    -- (pokefirered battle_main.c:2284: `rate * 100 / 1275`, raised to 2 when
    -- <= 1) -- read by the referee's safari mode only (contract C3).
    local P = engine("src.core.game3.pokemon")
    local meta = P and try(P.speciesMeta, species)
    local flee = type(meta) == "table" and int(meta.safariZoneFleeRate, nil) or nil
    if flee then sheet.safariFleeRate = clamp(flee, 0, 255) end
    -- A wild met by seteventmon (Mew, Deoxys and the island legendaries:
    -- the engine's natives_events.lua marks it `fatefulEncounter`): carried
    -- like the IVs, so a catch rebuilt from the sheet keeps the bit its
    -- obedience reads (M.monFromSheet).
    if mon.fatefulEncounter == true then sheet.fateful = true end
  end
  -- Passthrough: never read by a formula, copied onto a caught sheet so the
  -- catcher can rebuild the exact mon (Sheet3.monFromSheet).
  if type(mon.ivs) == "table" then
    local ivs = {}
    for _, k in ipairs(STAT_KEYS) do ivs[k] = clamp(int(mon.ivs[k], 0), 0, 31) end
    sheet.ivs = ivs
  end
  if type(mon.evs) == "table" then
    local evs = {}
    for _, k in ipairs(STAT_KEYS) do evs[k] = clamp(int(mon.evs[k], 0), 0, 255) end
    sheet.evs = evs
  end
  if tonumber(mon.personality) then sheet.personality = int(mon.personality, 0) end
  if tonumber(mon.otId) then sheet.otId = int(mon.otId, 0) end
  -- The obedience check's two facts about a monster (contract K2), `true` or
  -- absent, on this player's own sheets (`own`) in a fight against the
  -- computer only: the check asks the player's side alone
  -- (Engine.disobedient: `user.side ~= "player"` obeys), so a trainer's or a
  -- wild monster's sheet never carries them, and a link battle runs no check
  -- at all (`link`; the referee ignores them there too).
  if opts.own and not opts.link then
    if tradedOf(mon) then sheet.traded = true end
    if unfatefulOf(mon, species) then sheet.unfateful = true end
  end
  return sheet
end

-- Any party, best effort: a monster that cannot be described is skipped.
-- `party` is a list of Gen 3 mons; each sheet's `slot` is its index there.
function M.mons(game, party, opts)
  local out = {}
  if type(party) ~= "table" then return out end
  local session = Gen3.session()
  for index = 1, #party do
    if #out >= Config.BATTLE_MON_MAX then break end
    local sheet = M.mon(session, party[index], index - 1, opts)
    if sheet then out[#out + 1] = sheet end
  end
  return out
end

-- This player's own team: the live session party (game.save on Gen 3 is a
-- snapshot rebuilt at save time and lags the party the player sees).  Its
-- sheets are `own` (the K2 obedience facts, see M.mon).
function M.party(game, opts)
  local party = Gen3.party()
  if not party and type(game) == "table" and type(game.session) == "table" then
    party = game.session.party
  end
  local mine = { own = true }
  for k, v in pairs(opts or {}) do
    if k ~= "own" then mine[k] = v end
  end
  return M.mons(game, party, mine)
end

-- Write a referee's numbers onto a party mon (a solo or co-op fight's
-- writeback; T12 / T11).  `sheet` is a sheet or a seat: hp, status and each
-- move's pp by slot.  Only ever lowers nothing it was not told about.
function M.applyToMon(mon, sheet)
  if not (type(mon) == "table" and type(sheet) == "table") then return false end
  local maxHp = int(mon.maxHp, nil)
  local hp = int(sheet.hp, nil)
  if hp then
    if maxHp then hp = clamp(hp, 0, maxHp) end
    mon.hp = max(0, hp)
  end
  if sheet.status ~= nil or sheet.hp ~= nil then
    mon.status = statusOf(sheet)
    if mon.status ~= "SLP" then mon.sleep = nil end
  end
  if type(sheet.moves) == "table" then
    mon.pp = type(mon.pp) == "table" and mon.pp or {}
    for i, row in ipairs(sheet.moves) do
      if type(row) == "table" and moveAt(mon, i) == int(row.num, -1) and tonumber(row.pp) then
        if type(mon.moves[i]) == "table" then
          mon.moves[i].pp = int(row.pp, 0)
        else
          mon.pp[i] = int(row.pp, 0)
        end
      end
    end
  end
  return true
end

-- A party mon rebuilt from a caught sheet (the referee's copy of the wild
-- mon, with the IVs / EVs / personality passthrough the sheet carries).  The
-- engine recomputes its stats and exp from its own tables, so the result is
-- the cart's mon at that level, holding what the fight left it holding.
function M.monFromSheet(sheet, session)
  if type(sheet) ~= "table" then return nil end
  local species = int(sheet.speciesNum, nil) or int(sheet.speciesId, nil)
  if not species or species < 1 then return nil end
  local P = engine("src.core.game3.pokemon")
  if not P then return nil end
  session = session or Gen3.session() or {}
  local level = clamp(int(sheet.level, 5), 1, 100)
  local personality = int(sheet.personality, 0) % 4294967296
  local ivs, evs = {}, {}
  for _, k in ipairs(STAT_KEYS) do
    ivs[k] = clamp(int(type(sheet.ivs) == "table" and sheet.ivs[k] or 0, 0), 0, 31)
    evs[k] = clamp(int(type(sheet.evs) == "table" and sheet.evs[k] or 0, 0), 0, 255)
  end
  local moves, pp, maxPp = {}, {}, {}
  for _, row in ipairs(type(sheet.moves) == "table" and sheet.moves or {}) do
    local num = int(type(row) == "table" and row.num, nil)
    if num and num > 0 and #moves < 4 then
      moves[#moves + 1] = num
      pp[#pp + 1] = clamp(int(row.pp, 0), 0, 64)
      maxPp[#maxPp + 1] = clamp(int(row.maxPp, pp[#pp]), pp[#pp], 64)
    end
  end
  if #moves == 0 then return nil end
  local meta = try(P.speciesMeta, species)
  local growth = int(type(meta) == "table" and meta.growthRate, 0) % 6
  local SummaryData = engine("src.core.game3.summary_data")
  local exp = SummaryData and try(SummaryData.expForLevel, growth, level) or 0
  local gender = sheet.gender
  if gender ~= "M" and gender ~= "F" and gender ~= "U" then
    gender = try(P.gender, species, personality) or "U"
  end
  local mon = {
    species = species,
    speciesId = species,
    speciesNumbering = P.NUMBERING_INTERNAL or "internal",
    name = try(P.name, species),
    nickname = "",
    level = level,
    metLevel = level,
    growthRate = growth,
    exp = tonumber(exp) or 0,
    moves = moves, pp = pp, maxPp = maxPp,
    personality = personality,
    nature = personality % 25,
    ivs = ivs, evs = evs,
    ability = int(sheet.ability, 0), abilityId = int(sheet.ability, 0),
    gender = gender,
    friendship = clamp(int(sheet.friendship, 70), 0, 255),
    happiness = clamp(int(sheet.friendship, 70), 0, 255),
    heldItem = clamp(int(sheet.heldItem, 0), 0, 999),
    item = clamp(int(sheet.heldItem, 0), 0, 999),
    pokerus = 0,
    pokeball = 4,
  }
  if tonumber(sheet.otId) then mon.otId = int(sheet.otId, 0) end
  if sheet.fateful == true then mon.fatefulEncounter = true end
  pcall(P.applyStats, mon)
  M.applyToMon(mon, { hp = sheet.hp, status = sheet.status })
  return mon
end

-- ------------------------------------------------------------------
-- the ruleset
-- ------------------------------------------------------------------

-- The ordered type chart, as flat triples in cart order, the Foresight
-- sentinel and the two ghost immunities behind it included (§3.1).  Read
-- from the engine's own table (battle/types.lua Types.TABLE, pret
-- gTypeEffectiveness) and copied, never edited: order is the contract.
function M.typeTable()
  local Types = engine("src.core.game3.battle.types")
  local src = Types and Types.TABLE
  if type(src) ~= "table" then return nil end
  local out = {}
  local limit = M.TYPE_TABLE_MAX * 3
  for i = 1, #src - (#src % 3) do
    if i > limit then break end
    local n = tonumber(src[i])
    if not n then return nil end
    out[i] = floor(n)
  end
  if #out == 0 then return nil end
  return out
end

-- The Metronome / Nature Power / Sketch pool (§3.3): every move this cart has
-- a row for, packed one string per move, in move-number order.  The sim
-- filters what Metronome may not call itself; the pool is simply the table.
local poolCache = setmetatable({}, { __mode = "k" })

function M.movePool()
  local Mv = engine("src.core.game3.battle.moves")
  local key = Mv or M
  local hit = poolCache[key]
  if hit and hit.version == Gen3.version() then return hit.pool end
  local out = {}
  local last = Config.GEN3_MOVE_MAX or 354
  for id = 1, last do
    if #out >= M.MOVE_POOL_MAX then break end
    local info = Gen3.moveInfo(id)
    if info then
      out[#out + 1] = table.concat({
        id, clamp(int(info.effect, 0), 0, 213), clamp(int(info.power, 0), 0, 255),
        clamp(int(info.type, 0), 0, 17), clamp(int(info.accuracy, 0), 0, 100),
        clamp(int(info.pp, 0), 0, 64), clamp(int(info.secondaryChance, 0), 0, 100),
        max(0, int(info.target, 0)), clamp(int(info.priority, 0), -7, 7),
        clamp(int(info.flags, 0), 0, 63), tokenFor(info, id),
      }, ":")
    end
  end
  poolCache[key] = { version = Gen3.version(), pool = out }
  return out
end

-- The move row a battle event names by its token (C5 `anim.text` is the
-- sheet's move `id`), for a caller holding nothing else -- the VFX catalogue
-- wants the move's type and power, and a foe's moves never reached this
-- client as rows.  Indexed once per pool, so every token the referee can
-- emit resolves; the `MOVE_<n>` fallback token reads its number back.
local tokenIndex = setmetatable({}, { __mode = "k" })

function M.rowByToken(token)
  if type(token) ~= "string" or token == "" then return nil end
  local pool = M.movePool()
  local index = tokenIndex[pool]
  if not index then
    index = {}
    for _, packed in ipairs(pool) do
      local id, tok = packed:match("^(%d+):.*:([^:]+)$")
      if id and tok then index[tok] = tonumber(id) end
    end
    tokenIndex[pool] = index
  end
  local id = index[token] or tonumber(token:match("^MOVE_(%d+)$") or "")
  return id and M.moveRow(id) or nil
end

-- The overworld weather a fight opens under (pret battle_util.c:1709, the
-- engine's battle/init.lua overworld_weather): rain, downpour and
-- thunderstorm are RAIN, the sandstorm SAND, the drought SUN.  Read through
-- the guarded engine require: the mod sandbox hands a mod no real `package`
-- (src/mods/LegacyCompat.lua's shim, whose `loaded` is empty), so reading
-- package.loaded answered nil on every live boot.  The field has loaded the
-- weather module long before any fight is met, so asking starts nothing.
function M.fieldWeather()
  if not Gen3.active() then return nil end
  local W = Gen3.engine("src.core.game3.weather")
  if type(W) ~= "table" then return nil end
  local id = tonumber(try(W.get)) or tonumber(W.current) or 0
  if id == 3 or id == 5 or id == 13 then return "RAIN" end
  if id == 8 then return "SAND" end
  if id == 12 then return "SUN" end
  return nil
end

-- The ruleset for one match.  opts: { wild, terrain, weather, underwater }.
-- A wild fight takes the overworld's weather unless the caller named one;
-- a fight between players is fought on neutral ground (no weather, the sim's
-- default terrain), the way the Cable Club's is.
function M.ruleset(game, opts)
  opts = opts or {}
  local out = {
    generation = 3,
    typeTable = M.typeTable(),
    movePool = M.movePool(),
  }
  if #out.movePool == 0 then out.movePool = nil end
  local terrain = int(opts.terrain, nil)
  if terrain and terrain >= 0 and terrain <= 9 then out.terrain = terrain end
  local weather = opts.weather
  if weather == nil and opts.wild then weather = M.fieldWeather() end
  if weather == "RAIN" or weather == "SUN" or weather == "SAND" or weather == "HAIL" then
    out.weather = weather
  end
  if opts.underwater == true then out.underwater = true end
  if not out.typeTable and mod and mod.log then
    mod.log:warn("the Gen 3 type chart could not be read from this cart, so "
      .. "every matchup in this fight is neutral -- report this with the game "
      .. "version")
  end
  return out
end

-- ------------------------------------------------------------------
-- the bag (§4)
-- ------------------------------------------------------------------

-- The sim's own catalog row for an id (BattleSim3/Items.BAG), so the menu
-- and the referee can never disagree about what an item is.
function M.bagEffect(id)
  local Items = SimItems()
  if not Items then return nil end
  return Items.bagEffect(id)
end

-- The menu's reading of a bag item, in the vocabulary MediatedBattle's item
-- flow already speaks (ball / pokeDoll / pokeFlute / activeOnly / needsMove /
-- needsParty / faintedOnly / noConsume).  `sim` keeps the catalog row.
function M.itemEffect(id)
  local row = M.bagEffect(id)
  if not row then return nil end
  local out = { sim = row, id = tonumber(id) }
  if row.ball then out.ball = true
  elseif row.escape then out.pokeDoll = true
  elseif row.flute then out.pokeFlute = true; out.noConsume = true
  elseif row.activeOnly then out.activeOnly = true
  elseif row.needsMove then out.needsMove = true
  elseif row.revive then out.needsParty = true; out.faintedOnly = true
  else out.needsParty = true end
  return out
end

function M.itemFailsOnFainted(effect)
  local Items = SimItems()
  if not (Items and type(effect) == "table") then return false end
  return Items.failsOnFainted(effect.sim or effect)
end

-- The pockets a battle item can live in: the main pocket, the balls, the
-- berries, and the key items (FireRed's POKe FLUTE).
local BAG_POCKETS = { "ITEMS", "POKE_BALLS", "BERRY_POUCH", "KEY_ITEMS" }

local function numericId(raw)
  local n = tonumber(raw)
  if n then return floor(n) end
  local ItemsData = engine("src.core.game3.items_data")
  return tonumber(ItemsData and try(ItemsData.toNumericId, raw))
end

-- What this player may use from the bag this fight: every §4 item the
-- session's pockets hold, one entry per id, the count capped for the wire,
-- sorted by id.  `name` rides along for the referee's "X used POTION!".
function M.bag(game)
  local counts, names = {}, {}
  for _, pocket in ipairs(BAG_POCKETS) do
    for _, row in ipairs(Gen3.bag.list(pocket)) do
      local id = numericId(row.id)
      local qty = int(row.qty, 0)
      if id and qty > 0 and M.bagEffect(id) then
        counts[id] = (counts[id] or 0) + qty
        names[id] = names[id] or row.name
      end
    end
  end
  local out = {}
  for id, count in pairs(counts) do
    out[#out + 1] = {
      id = id,
      count = min(count, Config.BATTLE_BAG_COUNT_MAX),
      name = M.wireName(names[id] or Gen3.itemName(id) or "", "move") or nil,
    }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  while #out > Config.BATTLE_BAG_MAX do out[#out] = nil end
  return out
end

-- An NPC trainer's kit (the engine trainer row's `items`, up to four numeric
-- ids, one use each), restricted to §4 so an item the sim does not know can
-- never refuse the whole side.
function M.trainerBag(trainer)
  if type(trainer) ~= "table" or type(trainer.items) ~= "table" then return nil end
  local counts = {}
  for _, raw in ipairs(trainer.items) do
    local id = numericId(raw)
    if id and id > 0 and M.bagEffect(id) then counts[id] = (counts[id] or 0) + 1 end
  end
  local out = {}
  for id, count in pairs(counts) do out[#out + 1] = { id = id, count = count } end
  table.sort(out, function(a, b) return a.id < b.id end)
  if #out == 0 then return nil end
  return out
end

return M
