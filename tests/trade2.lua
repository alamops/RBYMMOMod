-- Headless Gen 2 trade helpers (Wave 3 T3b).
--
-- No ROM: stubs Protocol.packMon2/unpackMon2 when the real unpack would need
-- Gen 2 species data, and drives Trade2.TradeSession + apply (held item +
-- party mail). Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/trade2.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"
-- Agetor / out-of-tree checkouts may leave mods/rby_mmo pointed at another
-- tree; fall back to this file's mod root so the suite still exercises the
-- Trade2 under test.
if not io.open(MOD_PATH .. "/src/Trade2.lua", "rb") then
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("(.+)[/\\]")
    if dir then
      MOD_PATH = dir:gsub("[/\\]tests$", "")
    end
  end
end

local warns = {}
local stubMod = {
  log = {
    info = function() end,
    warn = function(_, fmt, ...)
      local ok, line = pcall(string.format, fmt, ...)
      warns[#warns + 1] = ok and line or tostring(fmt)
    end,
    error = function() end,
  },
}

local function loadTrade2()
  local loadstr = loadstring or load
  local handle = assert(io.open(MOD_PATH .. "/src/Trade2.lua", "rb"))
  local body = handle:read("*a")
  handle:close()
  local chunk = assert(loadstr(body, "@Trade2.lua"))
  return chunk(function() end, stubMod)
end

local Trade2 = loadTrade2()

-- ------- sanitize + packMail (no Protocol required)

eq(Trade2.sanitizeMail(nil), nil, "nil mail stays nil")
eq(Trade2.sanitizeMail(false), nil, "false mail stays nil")
eq(Trade2.sanitizeMail("x"), nil, "non-table mail is refused")

local clean = Trade2.sanitizeMail({
  type = "FLOWER_MAIL",
  message = ("A"):rep(40),
  author = "TRAINERNAME!!",
  authorId = 99999,
  species = "PIKACHU",
})
check(clean ~= nil, "a mail entry sanitises")
eq(clean.type, "FLOWER_MAIL", "type preserved")
eq(#clean.message, 32, "message clamped to MAIL_MSG_LENGTH default")
eq(#clean.author, 10, "author clamped to AUTHOR_LENGTH default")
eq(clean.authorId, 65535, "authorId clamped to u16")

local save = {
  generation = 2,
  party = { { species = "A" }, { species = "B" } },
  mail = {
    party = {
      [2] = {
        type = "SURF_MAIL", message = "hi", author = "BOB",
        authorId = 1, species = "B",
      },
    },
    box = {},
  },
  pokedex = { seen = {}, caught = {} },
}
local packed = Trade2.packMail(save, { 2, 1 })
eq(packed[1].type, "SURF_MAIL", "mail follows sendIndices wire order")
eq(packed[2], false, "empty slot is false so JSON keeps alignment")

-- ------- apply preserves held item + mail (session at done)

local game = {
  data = { pokemon = { CYNDAQUIL = { name = "CYNDAQUIL", evolutions = {} } } },
  save = {
    generation = 2,
    party = {
      { species = "TOTODILE", level = 5, item = "BERRY" },
    },
    mail = { party = {}, box = {} },
    pokedex = { seen = {}, caught = {} },
  },
}

local session = Trade2.TradeSession.new(game, { peerName = "ANN" })
session.stage = "done"
session.myPick = 1
session.theirPick = 1
session.theirParty = {
  {
    species = "CYNDAQUIL",
    level = 10,
    item = "LEFTOVERS",
    nickname = "CINDER",
  },
}
session.theirMail = {
  {
    type = "FLOWER_MAIL",
    message = "hello",
    author = "ANN",
    authorId = 42,
    species = "CYNDAQUIL",
  },
}

local received = session:apply(game)
check(received ~= nil, "apply returns the received mon")
eq(game.save.party[1].species, "CYNDAQUIL", "party slot swapped")
eq(game.save.party[1].item, "LEFTOVERS", "held item preserved on apply")
eq(game.save.party[1].traded, true, "received mon marked traded")
eq(game.save.pokedex.caught.CYNDAQUIL, true, "pokedex.caught updated")
eq(game.save.mail.party[1].type, "FLOWER_MAIL", "party mail applied to slot")
eq(game.save.mail.party[1].message, "hello", "mail message preserved")

-- Clearing mail on a slot with no parallel entry
session.theirMail = { false }
session.theirParty = { { species = "CYNDAQUIL", item = "BERRY" } }
session.stage = "done"
session:apply(game)
eq(game.save.mail.party[1], nil, "absent peer mail clears the slot")

-- ------- the trade evolution, and the row that decides it
--
-- apply answers what the received mon becomes; src/Sessions.lua is what puts
-- that on screen.  The row travels with the species because Gold's
-- EvolutionAnim is driven by the row -- it reads `into` and eats a demanded
-- held item itself -- so a species id alone would lose both.

do
  local def = game.data.pokemon.CYNDAQUIL
  def.evolutions = { { method = "EVOLVE_TRADE", into = "QUILAVA" } }
  game.data.pokemon.QUILAVA = { name = "QUILAVA", evolutions = {} }

  local evoSession = Trade2.TradeSession.new(game, { peerName = "ANN" })
  evoSession.stage = "done"
  evoSession.myPick = 1
  evoSession.theirPick = 1
  evoSession.theirParty = { { species = "CYNDAQUIL", level = 10 } }
  evoSession.theirMail = {}
  local _, evolveTo, evoEntry = evoSession:apply(game)
  eq(evolveTo, "QUILAVA", "a received mon with a trade row evolves")
  check(type(evoEntry) == "table" and evoEntry.into == "QUILAVA",
    "and the row that said so travels with it")

  -- The whole reason this goes through the engine's module rather than a
  -- scan of its own: an Everstone is a condition a scan cannot see.
  local okEvo, Gen2Evolution = pcall(require, "src.core.gen2.Evolution")
  if okEvo and type(Gen2Evolution) == "table" and Gen2Evolution.checkMon then
    evoSession.stage = "done"
    evoSession.theirParty =
      { { species = "CYNDAQUIL", level = 10, item = Gen2Evolution.EVERSTONE } }
    local _, stoned = evoSession:apply(game)
    eq(stoned, nil, "an Everstone refuses the trade evolution")
  end

  def.evolutions = {}
  game.data.pokemon.QUILAVA = nil
end

-- ------- capable() tracks Protocol.packMon2 when the engine has it

local okP, Protocol = pcall(require, "src.link.Protocol")
if okP and type(Protocol.packMon2) == "function"
    and type(Protocol.unpackMon2) == "function" then
  check(Trade2.capable(), "capable when packMon2/unpackMon2 exist")
  local mon = {
    species = "TEST",
    level = 5,
    experience = 100,
    hp = 20,
    status = nil,
    nickname = "T",
    dvs = { attack = 1, defense = 2, speed = 3, special = 4 },
    statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 },
    moves = { { id = "TACKLE", pp = 35 } },
    item = "LEFTOVERS",
    happiness = 70,
    pokerus = 0,
    caughtLevel = 5,
    ot = "OT",
    otId = 1,
  }
  local packedMon = Protocol.packMon2(mon)
  eq(packedMon.item, "LEFTOVERS", "packMon2 carries held item")
  eq(packedMon.experience, 100, "packMon2 uses experience not exp")
else
  check(not Trade2.capable(),
    "capable is false when Protocol Gen2 codecs are missing")
end

-- ------- Sessions branches on generation (capability refuse path)

local loadstr = loadstring or load
local moduleCache = {}
local function need(n)
  if moduleCache[n] ~= nil then return moduleCache[n] end
  if n == "Trade2" then
    moduleCache[n] = Trade2
    return Trade2
  end
  local path = MOD_PATH .. "/src/" .. n .. ".lua"
  local h = assert(io.open(path, "rb"))
  local body = h:read("*a")
  h:close()
  local chunk = assert(loadstr(body, "@" .. n .. ".lua"))
  moduleCache[n] = chunk(need, stubMod)
  return moduleCache[n]
end

do
  local Gen = need("Gen")
  local realGen = Gen.generation
  Gen.generation = function() return 2 end
  local Sessions = need("Sessions")
  local ended
  local realCapable = Trade2.capable
  Trade2.capable = function() return false end
  Sessions.beginTrade({ endSession = function(_, msg) ended = msg end },
    { data = {}, save = { party = {} } },
    {},
    { Handshake = {
        tradeAllowed = function() return true end,
        strict = function() return false end,
      } })
  check(ended ~= nil, "Gen2 without packMon2 refuses the trade")
  Trade2.capable = realCapable

  -- ------- and the Gen 2 evolution goes to the engine's own screen
  --
  -- Gold has no link trade of its own, so there is no LinkState to copy:
  -- Sessions pushes Gen2EvolutionAnim the way src/core/Game2.lua's
  -- afterRareCandy does.  The index matters more than anything else here --
  -- that screen builds a NEW party record and files it at `index`, so a
  -- wrong one writes the evolved mon over somebody else's slot.
  local pushes = {}
  stubMod.ui = {
    push = function(_, id, opts)
      pushes[#pushes + 1] = { id = id, opts = opts }
      return { kind = "screen" }
    end,
  }

  local other = { species = "TOTODILE", level = 5 }
  local evolving = { species = "CYNDAQUIL", level = 10 }
  local saves = 0
  local evoGame = {
    data = { pokemon = { CYNDAQUIL = {}, QUILAVA = {} } },
    save = { generation = 2, party = { other, evolving } },
    stack = { pop = function(stack) stack.popped = true end },
    writeSave = function() saves = saves + 1 return true end,
  }
  local entry = { method = "EVOLVE_TRADE", into = "QUILAVA" }
  local sessions = Sessions.new({}, {})
  check(sessions:evolveTraded(evoGame, evolving, "QUILAVA", entry, 2),
    "a Gen 2 trade evolution is put on screen")
  eq(#pushes, 1, "exactly one screen")
  eq(pushes[1].id, "Gen2EvolutionAnim", "the engine's own")
  eq(pushes[1].opts.index, 2, "filed at the slot the trade landed in")
  eq(pushes[1].opts.mon, evolving, "for the mon that landed there")
  eq(pushes[1].opts.entry, entry, "driven by the row, not by a species id")
  eq(pushes[1].opts.party, evoGame.save.party, "writing back into the real party")
  eq(saves, 0, "nothing is written while the movie is still playing")
  pushes[1].opts.onDone({})
  eq(evoGame.stack.popped, true, "and the screen is popped by whoever pushed it")
  -- The trade's own write landed the pre-evo; this is what replaces it with
  -- the species the player ends up holding (gen1recomp #222's second save).
  eq(saves, 1, "with the evolved Gold party committed to disk on the way out")

  -- A party that moved under us between the swap and the box being dismissed
  -- is searched rather than trusted; the wrong index is the one thing here
  -- that would cost a player a different POKéMON.
  pushes = {}
  table.remove(evoGame.save.party, 1)
  check(sessions:evolveTraded(evoGame, evolving, "QUILAVA", entry, 2),
    "a stale slot still finds the mon")
  eq(pushes[1].opts.index, 1, "at where it actually sits now")

  -- ------- and a save that cannot happen is said out loud, not swallowed
  --
  -- The swap has already happened in memory by the time any of this runs, so
  -- a throwing or refusing writeSave must not take the trade down with it --
  -- but the player has to be told, because the way out is theirs to take.
  -- `false` is a refusal rather than a throw (a tool session vetoing writes)
  -- and reads the same from here.
  local before = #warns
  eq(sessions:saveTrade({ save = {} }), false,
    "a build with no writeSave at all is not a failure")
  eq(#warns, before, "and says nothing about it")

  eq(sessions:saveTrade({ writeSave = function() return false end }), false,
    "a refused write is reported")
  eq(sessions:saveTrade({ writeSave = function() error("disk full", 0) end }), false,
    "and so is one that throws")
  eq(#warns, before + 2, "one line each")
  check(warns[#warns]:find("START") ~= nil,
    "naming somewhere the player can go from")

  stubMod.ui = nil
  Gen.generation = realGen
end

T.finish("trade2")
