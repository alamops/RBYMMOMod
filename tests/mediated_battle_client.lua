-- The client half of a mediated 1v1, driven with no hub and no display.
--
-- PROTOCOL 10 moved the arithmetic of an MMO battle onto the intermediator, so
-- what this side owes is much smaller than it used to be and much easier to
-- state: upload a party (and a chart, if we are the host), send a choice when a
-- turn opens, and draw an ordered stream of events.  This suite pins that, plus
-- the three things the change *removed*, which are the assertions most likely
-- to be quietly undone by a later edit:
--
--   * no handshake and no SessionNet for a battle -- both hubs hard-cut
--     mmo.relay for one, so a hello sent down that path would vanish;
--   * no fingerprint refuse -- Sessions.canBattle is never consulted, which is
--     what lets a Red fight a Yellow;
--   * no mmo.result -- the intermediator's single mmo.battle_outcome is the
--     whole account of the fight.
--
-- The upload is asserted by *sanitising it with the real Wire functions* rather
-- than by reading fields off it.  Wire.battleParty is what the far end runs, so
-- a snapshot that survives it is a snapshot the intermediator will fight; one
-- that does not would be dropped at the boundary and leave a player on a screen
-- that never starts.
--
-- Run: luajit mods/rby_mmo/tests/mediated_battle_client.lua
--      (from the engine checkout root)

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"
do
  local invoked = arg and arg[0]
  local dir = invoked and invoked:match("^(.*)[/\\]tests[/\\][^/\\]+$")
  if dir and dir ~= "" then
    local handle = io.open(dir .. "/src/Gen.lua", "rb")
    if handle then
      handle:close()
      MOD_PATH = dir
    end
  end
end

-- ------------------------------------------------------------------
-- the module graph, resolved the way main.lua resolves it
-- ------------------------------------------------------------------

local warns = {}

local stubMod = {
  id = "rby_mmo",
  path = MOD_PATH,
  log = {
    info = function() end,
    warn = function(_, fmt, ...)
      local ok, line = pcall(string.format, fmt, ...)
      warns[#warns + 1] = ok and line or tostring(fmt)
    end,
    error = function(_, fmt, ...)
      local ok, line = pcall(string.format, fmt, ...)
      warns[#warns + 1] = ok and line or tostring(fmt)
    end,
  },
}

local function resolver()
  local loadstr = loadstring or load
  local cache = {}
  local function need(name)
    if cache[name] then return cache[name] end
    local handle = io.open(MOD_PATH .. "/src/" .. name .. ".lua", "rb")
    if not handle then error("missing module " .. name, 0) end
    local body = handle:read("*a")
    handle:close()
    local chunk = assert(loadstr(body, "@" .. name .. ".lua"))
    cache[name] = chunk(need, stubMod)
    return cache[name]
  end
  return need
end

local need = resolver()
local Config = need("Config")
local Wire = need("Wire")
local Sessions = need("Sessions")
local Mediated = need("MediatedBattle")
local Gen = need("Gen")

-- ------------------------------------------------------------------
-- a world small enough to state every expected number about
-- ------------------------------------------------------------------
--
-- Synthetic rather than the fixture dataset, deliberately: the assertions below
-- are about *which* index a type gets and *what* a matchup converts to, and
-- those are only checkable against a chart small enough to write out.  The
-- fixture data is exercised too, further down, where the question is "does a
-- real party survive the sanitiser" rather than "is this cell 200".

-- Sorted, which is the ordering MediatedBattle.typeOrder produces and the one
-- both clients have to agree on with nothing on the wire stating it:
--   FIRE = 0, NORMAL = 1, WATER = 2
local DATA = {
  type_chart = {
    types = { NORMAL = { name = "NORMAL" }, FIRE = { name = "FIRE" },
              WATER = { name = "WATER" } },
    -- multipliers are x10 in the engine's table, percent on the wire
    matchups = {
      { attacker = "FIRE",  defender = "WATER", multiplier = 5 },
      { attacker = "WATER", defender = "FIRE",  multiplier = 20 },
      { attacker = "FIRE",  defender = "NORMAL", multiplier = 10 },
    },
  },
  moves = {
    EMBER   = { name = "EMBER", power = 40, accuracy = 100, type = "FIRE", pp = 25 },
    -- a status move: 0 power is an ordinary answer, not a missing field
    GROWL   = { name = "GROWL", power = 0, accuracy = 100, type = "NORMAL", pp = 40 },
    -- accuracy that is not a round 100, to pin the byte conversion.  Its name
    -- also differs from its id, which is the ordinary case in a real build
    -- (HYDRO_PUMP / "HYDRO PUMP") and the only one that can tell the two
    -- fields apart.
    HYDRO   = { name = "HYDRO PUMP", power = 120, accuracy = 80, type = "WATER", pp = 5 },
    SLASH   = { name = "SLASH", power = 70, accuracy = 100, type = "NORMAL", pp = 20,
                highCrit = true },
    -- Cache that predates the highCrit field: the client falls back to the
    -- engine's HIGH_CRIT id list so Karate Chop still rides as high-crit.
    KARATE_CHOP = { name = "KARATE CHOP", power = 50, accuracy = 100, type = "NORMAL",
                    pp = 25 },
  },
  pokemon = {
    CHARMANDER = { name = "CHARMANDER", types = { "FIRE" },
                   baseStats = { speed = 65 } },
    SQUIRTLE   = { name = "SQUIRTLE", types = { "WATER" } },
  },
}

local function mon(species, opts)
  opts = opts or {}
  return {
    species = species,
    nickname = opts.nickname,
    level = opts.level or 12,
    hp = opts.hp or 30,
    status = opts.status,
    stats = { hp = 30, attack = 14, defense = 13, speed = 16, special = 15 },
    dvs = { hp = 5, attack = 1, defense = 2, speed = 3, special = 4 },
    statExp = { hp = 0, attack = 100, defense = 0, speed = 0, special = 0 },
    moves = opts.moves or { { id = "EMBER", pp = 25 } },
  }
end

local function gameWith(party, data)
  return {
    data = data,
    save = { party = party, player = { name = "ANN" } },
    input = nil,
    stack = nil,
  }
end

-- ------------------------------------------------------------------
-- 1. the party snapshot
-- ------------------------------------------------------------------

local mons = Mediated.snapshotParty(gameWith({
  mon("CHARMANDER"),
  mon("SQUIRTLE", { nickname = "SHELLY", hp = 12, status = "PSN",
                    moves = { { id = "HYDRO", pp = 5 }, { id = "GROWL", pp = 40 } } }),
}, DATA))

eq(#mons, 2, "every party member that can be described is snapshotted")
eq(mons[1].species, "CHARMANDER", "a mon with no nickname is its species")
eq(mons[1].speciesId, "CHARMANDER", "and keeps the registry id for battle art")
eq(mons[2].species, "SHELLY", "...and one with a nickname is the nickname")
eq(mons[2].speciesId, "SQUIRTLE", "...while speciesId stays the pokedex key")
eq(mons[1].level, 12, "the level rides along")
eq(mons[1].hp, 30, "current HP")
eq(mons[1].maxHp, 30, "and the maximum, from the stat block")
eq(mons[2].hp, 12, "a hurt mon is snapshotted hurt")
eq(mons[2].status, "PSN", "the engine's status token is the wire's token")
eq(mons[1].status, nil, "and a healthy mon states no status at all")
eq(mons[1].slot, 0, "party position is zero-based on the wire")
eq(mons[2].slot, 1, "...counting up the party")

-- The four Gen 1 battle stats, from the five the engine keeps. SPC is one
-- stat: Special did not split until Gen 2.
eq(mons[1].stats.atk, 14, "attack maps to atk")
eq(mons[1].stats.def, 13, "defense to def")
eq(mons[1].stats.spd, 16, "speed to spd")
eq(mons[1].stats.spc, 15, "special to spc -- one stat, not two")
eq(mons[1].stats.hp, nil, "HP is not a battle stat here; it rides as maxHp")
eq(mons[1].ivs.atk, 1, "DVs come across as ivs")
eq(mons[1].evs.atk, 100, "and stat exp as evs")

-- Everything the sim needs to resolve the move, because there is no move table
-- on either intermediator and there must never be one.
local ember = mons[1].moves[1]
eq(ember.id, "EMBER", "the move id, for art and for indexing")
eq(ember.power, 40, "its power")
eq(ember.pp, 25, "its remaining PP")
-- The engine keeps a percent; Gen 1 compares an 8-bit value against a 0-255
-- roll, which is the whole mechanism behind the 1-in-256 miss.
eq(ember.accuracy, 255, "100% converts to the full byte")
eq(mons[2].moves[1].accuracy, 204, "and 80% to floor(80 * 255 / 100)")
eq(ember.type, 0, "FIRE is index 0 of the sorted type list")
eq(mons[2].moves[2].type, 1, "NORMAL is 1")
eq(mons[2].moves[1].type, 2, "WATER is 2")
eq(mons[2].moves[2].power, 0, "a status move keeps its 0 power rather than a default")
eq(ember.effect, 0, "effect is 0: the engine names it with a string and the "
  .. "wire wants a number, so there is no mapping to state")
eq(ember.chance, 0, "and so is its chance")

-- ...and the name it is *narrated* under (PROTOCOL 26), which is a different
-- field from the id doing a different job.  The referee holds no move table to
-- look one up in, so without this every sentence it writes prints the registry
-- key: "SHELLY used HYDRO", in the one place a player reads the fight.
eq(ember.name, "EMBER", "a move whose name matches its id still states it")
eq(mons[2].moves[1].name, "HYDRO PUMP",
   "...and one whose name differs from its id crosses as the name")
eq(mons[2].moves[1].id, "HYDRO",
   "...with the id still beside it, because that is what the anim is drawn from")

-- Sent even though both sanitisers drop it today. See the note in
-- MediatedBattle.typesOf: the sim already reads raw.types, and the day the two
-- twins carry the field the clients are already speaking it.
eq(mons[1].types[1], 0, "a FIRE species claims type 0")
eq(mons[2].types[1], 2, "and a WATER one type 2")
eq(mons[1].baseSpd, 65, "species base Speed rides the sheet for Gen 1 crit")
eq(mons[2].baseSpd, nil, "and is omitted when the species record has none")
eq(mons[1].moves[1].highCrit, nil, "EMBER is not a high-crit move")

local slashParty = Mediated.snapshotParty(gameWith(
  { mon("CHARMANDER", { moves = { { id = "SLASH", pp = 20 },
                                 { id = "KARATE_CHOP", pp = 25 } } }) }, DATA))
eq(slashParty[1].moves[1].highCrit, true,
   "highCrit on the move record stamps the sheet")
eq(slashParty[1].moves[2].highCrit, true,
   "...and KARATE_CHOP does too, from the engine HIGH_CRIT id fallback")
local slashPacked = Wire.battleParty({ battle = "7", mons = slashParty })
check(slashPacked ~= nil, "a high-crit snapshot survives Wire.battleParty")
eq(slashPacked.mons[1].moves[1].highCrit, true,
   "and the sanitiser keeps highCrit")
eq(slashPacked.mons[1].baseSpd, 65, "...and species base Speed")
check(Wire.battleMove({ id = "SLASH", pp = 20, power = 70, accuracy = 255,
                        type = 1, effect = 0, chance = 0,
                        highCrit = true }).highCrit == true,
      "Wire.battleMove keeps highCrit = true")
eq(Wire.battleMove({ id = "SLASH", pp = 20, power = 70, accuracy = 255,
                     type = 1, effect = 0, chance = 0,
                     highCrit = false }).highCrit, nil,
   "highCrit = false is omitted rather than stored")
check(Wire.battleMove({ id = "SLASH", pp = 20, power = 70, accuracy = 255,
                        type = 1, effect = 0, chance = 0,
                        highCrit = "yes" }) == nil,
      "a non-boolean highCrit refuses the move")
check(Wire.battleMon({
  species = "CHARMANDER", level = 5, hp = 1, maxHp = 1,
  stats = { atk = 1, def = 1, spd = 1, spc = 1 },
  moves = { { id = "EMBER", pp = 1, power = 1, accuracy = 255,
              type = 0, effect = 0, chance = 0 } },
  baseSpd = 65,
}).baseSpd == 65, "Wire.battleMon keeps baseSpd")
check(Wire.battleMon({
  species = "CHARMANDER", level = 5, hp = 1, maxHp = 1,
  stats = { atk = 1, def = 1, spd = 1, spc = 1 },
  moves = { { id = "EMBER", pp = 1, power = 1, accuracy = 255,
              type = 0, effect = 0, chance = 0 } },
  baseSpd = "fast",
}) == nil, "an unreadable baseSpd refuses the battler")

-- The strongest single assertion in this file: the real sanitiser, which is
-- what the far end runs.
local packed = Wire.battleParty({ battle = "7", mons = mons })
check(packed ~= nil, "the snapshot survives Wire.battleParty unchanged")
eq(#packed.mons, 2, "with both mons still in it")
eq(packed.battle, "7", "filed under the battle it was uploaded for")
-- ...and with the one field that is *not* prose still on it. `species` is the
-- nickname where there is one, so it is the id that decides what the seat
-- opposite draws and what an exp award is priced from; a sanitiser that
-- dropped it is the difference between a monster and a blank box at Lv 1.
eq(packed.mons[2].species, "SHELLY", "the narration token crosses as itself")
eq(packed.mons[2].speciesId, "SQUIRTLE",
   "...and the registry id crosses beside it, nickname or no nickname")
eq(packed.mons[2].moves[1].name, "HYDRO PUMP",
   "the move's display name survives the real sanitiser too")
-- Optional both ways.  A protocol-25 client states no name at all, and the
-- referee narrates that move under its id exactly as it always did -- so an
-- absent name must not refuse the move, the battler and then the party.
local noName = Wire.battleMove({ id = "HYDRO", pp = 5, power = 120,
                                 accuracy = 204, type = 2, effect = 0, chance = 0 })
check(noName ~= nil, "a move with no name is still a move")
eq(noName.name, nil, "...and states none rather than inventing one")
-- Present-but-unreadable is refused, on this sanitiser's own rule: a field
-- that arrived and did not survive is the sending side being wrong about
-- something, and narrating under the id anyway would hide it.
check(Wire.battleMove({ id = "HYDRO", name = 7, pp = 5, power = 120,
                        accuracy = 204, type = 2, effect = 0,
                        chance = 0 }) == nil,
      "a name that is not prose refuses the move")
eq(Wire.moveName(("X"):rep(40)), ("X"):rep(Config.MOVE_NAME_MAX),
   "an over-long name is cut to MOVE_NAME_MAX rather than to NAME_MAX")
check(Wire.battleMon({ species = "SHELLY", speciesId = "not a species!",
                       level = 5, hp = 1, maxHp = 1,
                       stats = { atk = 1, def = 1, spd = 1, spc = 1 },
                       moves = { { id = "EMBER", pp = 1, power = 1,
                                   accuracy = 255, type = 0, effect = 0,
                                   chance = 0 } } }) == nil,
      "an unreadable id refuses the battler, like every other id on the sheet")
-- The obedience check's `traded` is every generation's now (contract K1 of
-- docs/plans/gen12-referee-fidelity.md: the Gen 1 / Gen 2 carts check it too),
-- while `unfateful` stays Gen 3's (contract K2 of docs/plans/gen3-badge-rules.md)
-- and the Gen 1 / Gen 2 reader never copies it.
do
  local sheet = Wire.battleMon({
    species = "CHARMANDER", level = 5, hp = 1, maxHp = 1,
    stats = { atk = 1, def = 1, spd = 1, spc = 1 },
    moves = { { id = "EMBER", pp = 1, power = 1, accuracy = 255,
                type = 0, effect = 0, chance = 0 } },
    traded = true, unfateful = true,
  })
  check(sheet ~= nil and sheet.traded == true and sheet.unfateful == nil,
        "Wire.battleMon (Gen 1) keeps traded and strips the Gen 3-only unfateful")
end

-- Badges: the save's badge rows in a fight against the computer, none in a
-- link battle -- no cart boosts there (Gen 1 skips the badge step in a link
-- battle), and the referees ignore an uploaded set in 1v1 / coop_pvp too.
do
  local badgeData = setmetatable({ constants = { badgeBoosts = {
    { badge = "BOULDERBADGE", stat = "attack" },
    { badge = "THUNDERBADGE", stat = "defense" },
    { badge = "SOULBADGE", stat = "speed" },
  } } }, { __index = DATA })
  local badgeGame = gameWith({ mon("CHARMANDER") }, badgeData)
  badgeGame.save.inventory = { BOULDERBADGE = 1 }
  badgeGame.save.player.badges = { SOULBADGE = true }
  local function list(mode) return table.concat(Mediated.badgesOf(badgeGame, mode) or {}, ",") end
  eq(list("wild"), "BOULDERBADGE,SOULBADGE", "badges: a wild fight sends the save's badges")
  eq(list("coop_npc"), "BOULDERBADGE,SOULBADGE", "badges: ...as does a trainer fight")
  eq(list(nil), "BOULDERBADGE,SOULBADGE", "badges: a caller naming no mode is not in a link battle")
  eq(Mediated.badgesOf(badgeGame, "1v1"), nil, "badges: a 1v1 is a link battle and sends none")
  eq(Mediated.badgesOf(badgeGame, "coop_pvp"), nil, "badges: ...nor does coop_pvp")
  -- Gen 1 reads its own rows only: a Gold-shaped Kanto store is nothing to it.
  badgeGame.save.player.kantoBadges = { BOULDER = true, [1] = true }
  eq(list("wild"), "BOULDERBADGE,SOULBADGE", "badges: Gen 1 is unchanged by a kantoBadges store")
end

-- Gold: every badge the save holds, the eight Johto then the eight Kanto, by the
-- Gold names BattleSim2's boosts are keyed on -- owned the way the Gold engine's
-- own Battle:hasBadge (src/battle/gen2/Battle.lua) answers it: Johto in
-- `player.badges`, Kanto in `player.kantoBadges`, each keyed by name or by its
-- wJohtoBadges / wKantoBadges bit position.  Not the bag, and not Gen 1's
-- badgeBoosts rows, both of which this save also carries.
do
  local function goldGame(player)
    return {
      generation = 2,
      data = { constants = { badgeBoosts = { { badge = "BOULDERBADGE", stat = "attack" } } } },
      save = { party = {}, player = player, inventory = { BOULDERBADGE = 1, ZEPHYR = 1, EARTH = 1 } },
    }
  end
  local function list(game, mode) return table.concat(Mediated.badgesOf(game, mode) or {}, ",") end

  local byName = goldGame({ name = "GOLD", badges = { ZEPHYR = true, MINERAL = true },
                            kantoBadges = { BOULDER = true, EARTH = true } })
  eq(list(byName, "wild"), "ZEPHYR,MINERAL,BOULDER,EARTH",
     "Gold badges: Johto and Kanto by name, in the cart's walk order")
  eq(list(byName, "coop_npc"), "ZEPHYR,MINERAL,BOULDER,EARTH", "Gold badges: ...in a trainer fight too")
  eq(list(byName, nil), "ZEPHYR,MINERAL,BOULDER,EARTH", "Gold badges: ...and with no mode named")

  local byBit = goldGame({ badges = { [1] = true, [3] = true, [8] = true },
                           kantoBadges = { [2] = true, [7] = true } })
  eq(list(byBit, "wild"), "ZEPHYR,PLAIN,RISING,CASCADE,VOLCANO",
     "Gold badges: keyed by bit position, both stores")

  local mixed = goldGame({ badges = { HIVE = true, [4] = true }, kantoBadges = { THUNDER = true, [8] = true } })
  eq(list(mixed, "wild"), "HIVE,FOG,THUNDER,EARTH", "Gold badges: names and bit positions in one save")

  local all = { badges = {}, kantoBadges = {} }
  for i = 1, 8 do all.badges[i], all.kantoBadges[i] = true, true end
  eq(list(goldGame(all), "wild"),
     "ZEPHYR,HIVE,PLAIN,FOG,MINERAL,STORM,GLACIER,RISING,BOULDER,CASCADE,THUNDER,RAINBOW,"
     .. "SOUL,MARSH,VOLCANO,EARTH", "Gold badges: all sixteen")

  eq(Mediated.badgesOf(goldGame({ badges = { BOULDER = true }, kantoBadges = { ZEPHYR = true } }), "wild"), nil,
     "Gold badges: a badge counts only in its own store")
  eq(Mediated.badgesOf(goldGame({ badges = { ZEPHYR = false, [2] = 1 } }), "wild"), nil,
     "Gold badges: a false name and a bit position that is not `true` own nothing (the engine's test)")
  eq(Mediated.badgesOf(goldGame({ name = "GOLD" }), "wild"), nil,
     "Gold badges: none earned is nil, whatever the bag and badgeBoosts rows say")
  eq(Mediated.badgesOf(byName, "1v1"), nil, "Gold badges: a 1v1 is a link battle and sends none")
  eq(Mediated.badgesOf(byName, "coop_pvp"), nil, "Gold badges: ...nor does coop_pvp")

  -- ...and the list crosses the wire as the referee reads it: a set of Gold names.
  local set = Wire.badges(Mediated.badgesOf(byName, "wild"))
  check(set and set.ZEPHYR and set.MINERAL and set.BOULDER and set.EARTH and not set.BOULDERBADGE,
        "Gold badges: Wire.badges keeps the Gold names as the referee's set")
end

-- Defaults, for a move this build has a slot for but no record of -- a modded
-- move whose definition did not survive. 40 power at full accuracy is a plain
-- hit: weaker than assuming the best, and far better than refusing the move,
-- which would refuse the monster and then the whole party.
local unknown = Mediated.snapshotParty(gameWith(
  { mon("CHARMANDER", { moves = { { id = "MYSTERY_BEAM", pp = 3 } } }) }, DATA))
eq(#unknown, 1, "a mon whose move has no record is still brought")
eq(unknown[1].moves[1].power, 40, "an unknown move defaults to 40 power")
eq(unknown[1].moves[1].accuracy, 255, "...full accuracy")
eq(unknown[1].moves[1].type, 0, "...and type 0")
eq(unknown[1].moves[1].name, nil,
   "...and no name at all, so the referee narrates it under its id")

-- sheetMoves -- the moveset a mid-fight learn republishes (PROTOCOL 28) --
-- is encoded in the boot's own dialect.  It used to call `moveOf` with no
-- generation, so on Gold every resend went through Gen 1's effect table: a
-- learned Crystal EFFECT_* status move became effect 0 (a move that does
-- nothing) and a Gen 1 high-crit id kept its crit.  The opening upload was
-- always right, which is why the drift only showed after a level-up.
do
  local Effects2 = need("BattleSim2/Effects")
  local goldData = {
    moves = {
      HYPNOSIS = { name = "HYPNOSIS", power = 0, accuracy = 60, type = "PSYCHIC_TYPE",
                   pp = 20, effect = "EFFECT_SLEEP" },
      CROSS_CHOP = { name = "CROSS CHOP", power = 100, accuracy = 80, type = "FIGHTING",
                     pp = 5, effect = "EFFECT_ALWAYS_CRIT" },
      KARATE_CHOP = { name = "KARATE CHOP", power = 50, accuracy = 100, type = "FIGHTING",
                      pp = 25, effect = "EFFECT_NORMAL_HIT" },
    },
  }
  local learner = { moves = { { id = "HYPNOSIS", pp = 20 }, { id = "CROSS_CHOP", pp = 5 },
                              { id = "KARATE_CHOP", pp = 25 } } }
  local gold = Mediated.sheetMoves({ generation = 2, data = goldData }, learner)
  eq(#gold, 3, "Gold: every learned move is republished")
  eq(gold[1].effect, Effects2.idOf("EFFECT_SLEEP"),
     "Gold: a republished status move keeps its Crystal effect id")
  check(gold[1].effect ~= 0, "...which is a real effect, not the do-nothing 0")
  eq(gold[2].highCrit, true, "Gold: EFFECT_ALWAYS_CRIT still republishes as high-crit")
  -- KARATE_CHOP is on Gold's own CriticalHitMoves too (pokegold data/moves/
  -- critical_hit_moves.asm), so the resend stamps it -- off Gold's list, not
  -- Gen 1's (the lists differ in RAZOR_WIND / AEROBLAST / CROSS_CHOP, pinned
  -- in the Gold-shaped record section below).
  eq(gold[3].highCrit, true,
     "Gold: KARATE_CHOP republishes high-crit, off Gold's CriticalHitMoves")
  -- ...and the Gen 1 resend is exactly what it was.
  local red = Mediated.sheetMoves({ data = DATA },
    { moves = { { id = "KARATE_CHOP", pp = 25 } } })
  eq(red[1].highCrit, true, "Gen 1: the resend keeps the HIGH_CRIT fallback")
end

-- Gold-shaped move records: the fields an imported Gold record really carries
-- (src/import/RomExtractorGen2.lua extractMoves -- `effectChance` the percent,
-- `effectChanceRaw` the byte, `accuracyRaw`, `effectId`; no `chance`, no
-- `highCrit`).  The sheet used to read `def.chance`, which no Gold record has,
-- so every Gold move went out at chance 0 -- no secondary effect ever fired in
-- a refereed Gold fight, and THIEF never stole -- and it stamped Gen 2
-- high-crit off EFFECT_ALWAYS_CRIT, an effect neither Gold nor Crystal has, so
-- no Gold move ever rolled on the high-crit rung.  Gold's high-crit list is
-- pokegold data/moves/critical_hit_moves.asm, keyed by move id.
do
  local function goldRecord(o)
    return {
      id = o.id, name = o.name or o.id, power = o.power or 40,
      type = o.type or "NORMAL", pp = o.pp or 20,
      accuracy = 100, accuracyRaw = 255,
      effect = o.effect or "EFFECT_NORMAL_HIT", effectId = 0,
      effectChance = o.effectChance or 0, effectChanceRaw = o.raw or 0,
      chance = o.chance, highCrit = o.highCrit,
    }
  end
  local recs = {
    EMBER = goldRecord({ id = "EMBER", type = "FIRE", effect = "EFFECT_BURN_HIT",
                         effectChance = 10, raw = 25 }),
    THIEF = goldRecord({ id = "THIEF", effect = "EFFECT_THIEF",
                         effectChance = 100, raw = 255 }),
    -- A content mod that states `chance` is heard over the cart's field.
    STATED = goldRecord({ id = "STATED", effect = "EFFECT_BURN_HIT",
                          effectChance = 10, raw = 25, chance = 30 }),
    OVER = goldRecord({ id = "OVER", effect = "EFFECT_BURN_HIT", effectChance = 250 }),
    UNDER = goldRecord({ id = "UNDER", effect = "EFFECT_BURN_HIT", effectChance = -5 }),
    TACKLE = goldRecord({ id = "TACKLE" }),
    SLASH = goldRecord({ id = "SLASH" }),
    KARATE_CHOP = goldRecord({ id = "KARATE_CHOP", type = "NORMAL" }),
    RAZOR_WIND = goldRecord({ id = "RAZOR_WIND", effect = "EFFECT_RAZOR_WIND" }),
    AEROBLAST = goldRecord({ id = "AEROBLAST" }),
    CROSS_CHOP = goldRecord({ id = "CROSS_CHOP" }),
    -- The record's own `highCrit` still wins on Gold, an explicit false too.
    CRABHAMMER = goldRecord({ id = "CRABHAMMER", highCrit = false }),
  }
  local goldMoveData = { type_chart = DATA.type_chart, moves = recs,
                         pokemon = DATA.pokemon }
  local function ids(list)
    local out = {}
    for i, id in ipairs(list) do out[i] = { id = id, pp = 5 } end
    return out
  end
  local function byId(sheets)
    local out = {}
    for _, sheet in ipairs(sheets) do out[sheet.id] = sheet end
    return out
  end
  local gold = { generation = 2, data = goldMoveData }
  local red = { data = goldMoveData }

  -- The chance, through the opening upload on a Gold party.
  local party = Mediated.snapshotParty({
    generation = 2, data = goldMoveData,
    save = { generation = 2, party = {
      mon("CHARMANDER", { moves = ids({ "EMBER", "THIEF", "STATED", "TACKLE" }) }),
      mon("SQUIRTLE", { moves = ids({ "OVER", "UNDER" }) }),
    }, player = { name = "GOLD" } },
  })
  eq(#party, 2, "Gold-shaped records: the party is described")
  local lead = byId(party[1] and party[1].moves or {})
  eq(lead.EMBER and lead.EMBER.chance, 10,
     "Gold: a record's effectChance (10) is the sheet's chance -- not 0")
  eq(lead.THIEF and lead.THIEF.chance, 100,
     "Gold: THIEF's effectChance 100 rides, so the referee's `thief` can run")
  eq(lead.STATED and lead.STATED.chance, 30,
     "Gold: a record that states `chance` still wins over effectChance")
  eq(lead.TACKLE and lead.TACKLE.chance, 0, "Gold: a plain hit's 0 stays 0")
  local bench = byId(party[2] and party[2].moves or {})
  eq(bench.OVER and bench.OVER.chance, 100, "Gold: an out-of-range effectChance clamps to 100")
  eq(bench.UNDER and bench.UNDER.chance, 0, "Gold: ...and a negative one to 0")
  local packed = Wire.battleParty({ battle = "fx5", mons = party, generation = 2 })
  local packedLead = byId(packed and packed.mons[1].moves or {})
  eq(packedLead.EMBER and packedLead.EMBER.chance, 10,
     "Gold: the chance survives Wire.battleParty")
  eq(packedLead.THIEF and packedLead.THIEF.chance, 100,
     "Gold: ...THIEF's 100 too")

  -- The mid-fight resend (PROTOCOL 28) reads the same field.
  local resend = byId(Mediated.sheetMoves(gold, { moves = ids({ "EMBER", "THIEF" }) }))
  eq(resend.EMBER and resend.EMBER.chance, 10, "Gold: a republished moveset keeps effectChance")
  eq(resend.THIEF and resend.THIEF.chance, 100, "Gold: ...THIEF's included")

  -- ...and so does the Metronome pool the host uploads.
  local pool = byId(Mediated.snapshotRuleset(gold).metronomePool or {})
  eq(pool.EMBER and pool.EMBER.chance, 10, "Gold: a Metronome-called move carries its effectChance")

  -- An imported Gold moves table also holds two scalars beside its records
  -- (`generation = 2`, `source`).  A table short enough for the pool walk to
  -- reach them -- a stock one is cut off by the pool cap first -- must neither
  -- throw on the number nor offer either as a move.
  local withScalars = { type_chart = DATA.type_chart, pokemon = DATA.pokemon,
                        moves = { generation = 2, source = "ROM:Moves" } }
  for id, rec in pairs(recs) do withScalars.moves[id] = rec end
  local okRules, scalarRules = pcall(Mediated.snapshotRuleset,
                                     { generation = 2, data = withScalars })
  check(okRules, "Gold: a moves table carrying `generation` / `source` still builds a ruleset")
  local scalarPool = byId(okRules and scalarRules.metronomePool or {})
  eq(scalarPool.generation, nil, "Gold: ...`generation` is not a Metronome move")
  eq(scalarPool.source, nil, "Gold: ...nor is `source`")
  eq(scalarPool.EMBER and scalarPool.EMBER.chance, 10, "Gold: ...and the records are all still there")

  -- Gen 1 reads `chance` alone: Red's records carry no odds (the Gen 1 referee
  -- owns them), and the cart field is Gold's.
  local redSheets = byId(Mediated.sheetMoves(red, { moves = ids({ "EMBER", "STATED" }) }))
  eq(redSheets.EMBER and redSheets.EMBER.chance, 0,
     "Gen 1: an effectChance on the record is not read -- still 0")
  eq(redSheets.STATED and redSheets.STATED.chance, 30, "Gen 1: a stated `chance` still rides")

  -- High crit: Gold's CriticalHitMoves, by id.
  local crit = byId(Mediated.sheetMoves(gold, { moves = ids({
    "SLASH", "KARATE_CHOP", "RAZOR_WIND", "AEROBLAST" }) }))
  local crit2 = byId(Mediated.sheetMoves(gold, { moves = ids({
    "CROSS_CHOP", "TACKLE", "CRABHAMMER" }) }))
  eq(crit.SLASH and crit.SLASH.highCrit, true, "Gold: SLASH is high-crit off CriticalHitMoves")
  eq(crit.KARATE_CHOP and crit.KARATE_CHOP.highCrit, true, "Gold: KARATE_CHOP too")
  eq(crit.RAZOR_WIND and crit.RAZOR_WIND.highCrit, true,
     "Gold: RAZOR_WIND, which only Gold's list names")
  eq(crit.AEROBLAST and crit.AEROBLAST.highCrit, true, "Gold: AEROBLAST, likewise")
  eq(crit2.CROSS_CHOP and crit2.CROSS_CHOP.highCrit, true,
     "Gold: CROSS_CHOP with no EFFECT_ALWAYS_CRIT on its record")
  eq(crit2.TACKLE and crit2.TACKLE.highCrit, nil, "Gold: a move off the list is ordinary")
  eq(crit2.CRABHAMMER and crit2.CRABHAMMER.highCrit, nil,
     "Gold: a record's explicit highCrit = false opts a listed move out")
  local redCrit = byId(Mediated.sheetMoves(red, { moves = ids({
    "SLASH", "RAZOR_WIND", "AEROBLAST", "CROSS_CHOP" }) }))
  eq(redCrit.SLASH and redCrit.SLASH.highCrit, true, "Gen 1: SLASH keeps the Gen 1 list")
  eq(redCrit.RAZOR_WIND and redCrit.RAZOR_WIND.highCrit, nil,
     "Gen 1: RAZOR_WIND is not on Red's list")
  eq(redCrit.AEROBLAST and redCrit.AEROBLAST.highCrit, nil, "Gen 1: nor AEROBLAST")
  eq(redCrit.CROSS_CHOP and redCrit.CROSS_CHOP.highCrit, nil, "Gen 1: nor CROSS_CHOP")
end

-- The edges that must not throw, because every one of them is a real build.
eq(#Mediated.snapshotParty(gameWith({}, DATA)), 0, "an empty party snapshots empty")
eq(#Mediated.snapshotParty(gameWith({ mon("CHARMANDER") }, nil)), 1,
   "a game with no data still describes its party")
eq(#Mediated.snapshotParty({}), 0, "and a game with no save is not a crash")
eq(#Mediated.snapshotParty(nil), 0, "neither is no game at all")

-- Refused whole rather than delivered short: a snapshot that came back with
-- seven mons would be a party the sanitiser drops on arrival.
local big = {}
for _ = 1, 9 do big[#big + 1] = mon("CHARMANDER") end
eq(#Mediated.snapshotParty(gameWith(big, DATA)), Config.BATTLE_MON_MAX,
   "an over-long party is cut to what the wire carries")

local manyMoves = { { id = "EMBER", pp = 1 }, { id = "GROWL", pp = 2 },
                    { id = "HYDRO", pp = 3 }, { id = "EMBER", pp = 4 },
                    { id = "GROWL", pp = 5 } }
eq(#Mediated.snapshotParty(gameWith(
     { mon("CHARMANDER", { moves = manyMoves }) }, DATA))[1].moves,
   Config.BATTLE_MOVE_MAX, "and an over-long move list likewise")

-- ------------------------------------------------------------------
-- 2. the ephemeral ruleset
-- ------------------------------------------------------------------

local ruleset = Mediated.snapshotRuleset(gameWith({}, DATA))
eq(#ruleset.chart, 3, "one row per type in the sorted list")
eq(#ruleset.chart[1], 3, "and a square chart")
-- chart[attacker + 1][defender + 1], the indexing BattleSim/Turn.lua reads.
eq(ruleset.chart[1][3], 50, "FIRE into WATER is the x10 table's 5, as percent")
eq(ruleset.chart[3][1], 200, "WATER into FIRE is 200")
eq(ruleset.chart[1][2], 100, "a stated neutral matchup is 100")
eq(ruleset.chart[2][2], Wire.EFF_NEUTRAL, "and an unstated one is too -- the "
  .. "engine states only what is not neutral")
eq(ruleset.seed, nil, "no seed is offered: the intermediator does every roll "
  .. "and can pick its own")
check(Wire.battleRuleset(ruleset) ~= nil, "the ruleset survives its sanitiser")
-- FIRE is Special in Gen1; sorted fixture order is FIRE,NORMAL,WATER → 0 and 2.
eq(ruleset.specialTypes and #ruleset.specialTypes, 2,
   "Special types are uploaded with the chart")
local specialSet = {}
for _, idx in ipairs(ruleset.specialTypes or {}) do specialSet[idx] = true end
check(specialSet[0] and specialSet[2], "FIRE and WATER indices are Special")
check(not specialSet[1], "NORMAL is Physical")
-- The chart's axis by name (`typeIds`): what Gold's badge type boost reads a
-- move's type index through on the referee (BattleSim2 `_typeIdOf`), and what
-- Red's side effects ask POISON / FIRE through (BattleSim `typeIndexOf`).  The
-- same order every row and move index on this upload uses, and it crosses the
-- wire on Gen 1 and Gen 2.
local function goldWith(data)
  local game = gameWith({}, data)
  game.generation = 2
  return game
end
eq(table.concat(ruleset.typeIds or {}, ","), "FIRE,NORMAL,WATER",
   "typeIds: a Gen 1 ruleset names the chart's axis too (Red's POISON / FIRE side-effect checks)")
local redWire = Wire.battleRuleset(ruleset, 1)
eq(table.concat(redWire and redWire.typeIds or {}, ","), "FIRE,NORMAL,WATER",
   "typeIds: Wire keeps them on a Gen 1 ruleset")
local goldRules = Mediated.snapshotRuleset(goldWith(DATA))
eq(table.concat(goldRules.typeIds or {}, ","), "FIRE,NORMAL,WATER",
   "typeIds: Gold's ruleset names the chart's axis, in order")
local ruleWire = Wire.battleRuleset(goldRules, 2)
eq(table.concat(ruleWire and ruleWire.typeIds or {}, ","), "FIRE,NORMAL,WATER",
   "typeIds: Wire keeps them on a Gen 2 ruleset")
if goldRules.typeIds then
  goldRules.typeIds[1] = "SCRIBBLED"
  eq(Mediated.typeOrder(DATA).ids[1], "FIRE", "typeIds: a copy -- the type order's cache is not written through it")
end

-- A registry id is any non-empty string, and a content mod's type need not fit
-- the wire's id alphabet.  The client leaves the axis off rather than send one
-- a hub would drop -- naming the id and how to fix it -- and the ruleset, chart
-- and all, still goes up: the fight is lost a 1/8 boost, not refereeing.
do
  local modded = { type_chart = {
    types = { NORMAL = { name = "NORMAL", category = "physical" },
              ["mymod.FAIRY"] = { name = "FAIRY", category = "special" } },
    matchups = { { attacker = "mymod.FAIRY", defender = "NORMAL", multiplier = 2 } },
  }, moves = {} }
  local mark = #warns
  local rules = Mediated.snapshotRuleset(goldWith(modded))
  eq(#rules.chart, 2, "typeIds (modded): the chart still names both types")
  eq(rules.typeIds, nil, "typeIds (modded): an id off the wire's alphabet leaves the axis off")
  local named = false
  for i = mark + 1, #warns do
    if tostring(warns[i]):find("mymod.FAIRY", 1, true) then named = true end
  end
  check(named, "typeIds (modded): ...and the warning names the id")
  local clean = Wire.battleRuleset(rules, 2)
  check(clean ~= nil and clean.chart ~= nil, "typeIds (modded): the ruleset survives its sanitiser")
  -- A hub handed one anyway (an older client, a hand-made upload) drops the
  -- list and keeps the ruleset, rather than refusing the fight.
  local sent = {}
  for k, v in pairs(rules) do sent[k] = v end
  sent.typeIds = { "NORMAL", "mymod.FAIRY" }
  clean = Wire.battleRuleset(sent, 2)
  check(clean ~= nil and clean.chart ~= nil and clean.typeIds == nil,
        "typeIds (modded): Wire drops an unreadable axis and keeps the ruleset")
  sent.typeIds = "NORMAL"
  clean = Wire.battleRuleset(sent, 2)
  check(clean ~= nil and clean.typeIds == nil, "typeIds: ...as it does one that is not a list")
end

-- ------- the physical/special split comes off the chart's own records
--
-- Gen 1 and Gen 2 both split by TYPE, and every type record the registry
-- serves carries `category`. Reading it (rather than matching type *names*) is
-- what makes this survive the case that shipped broken for months: a type
-- whose registry id is not its own name.
do
  local function rulesetFor(types, matchups)
    return Mediated.snapshotRuleset({
      data = { type_chart = { types = types, matchups = matchups or {} },
               moves = {} },
    })
  end
  local function specialIds(rules, types)
    local order = Mediated.typeOrder({ type_chart = { types = types, matchups = {} } })
    local byIndex = {}
    for id, idx in pairs((order and order.index) or {}) do byIndex[idx] = id end
    local out = {}
    for _, idx in ipairs(rules.specialTypes or {}) do out[byIndex[idx]] = true end
    return out
  end

  -- PSYCHIC_TYPE is the real registry id in BOTH generations -- `PSYCHIC` is
  -- taken by the move. This is the regression: keying on the display name
  -- dropped the whole type out of the upload, and every Psychic move was then
  -- refereed on atk/def with Light Screen not halving it.
  local gen1 = {
    NORMAL       = { name = "NORMAL",   category = "physical" },
    PSYCHIC_TYPE = { name = "PSYCHIC",  category = "special" },
    FIRE         = { name = "FIRE",     category = "special" },
  }
  local got = specialIds(rulesetFor(gen1), gen1)
  check(got.PSYCHIC_TYPE,
        "PSYCHIC_TYPE is uploaded as Special -- the id, not the display name")
  check(got.FIRE, "...alongside the types whose id and name agree")
  check(not got.NORMAL, "...and a physical type stays out")

  -- Gen 2 adds Dark, and it arrives the same way: off the record, with no
  -- second name list in the client.
  local gen2 = {
    DARK  = { name = "DARK",  category = "special" },
    STEEL = { name = "STEEL", category = "physical" },
  }
  local g2 = specialIds(rulesetFor(gen2), gen2)
  check(g2.DARK, "Gen 2's Dark is Special, read off its record")
  check(not g2.STEEL, "...and Steel is not")

  -- ...and Gold in practice, where they arrive with NO record at all:
  -- `TypeChart.TYPES` carries the fifteen Gen 1 types only, so on a Gen 2 boot
  -- Dark and Steel reach the chart through their matchups alone. Both name
  -- lists have to place them, and neither may raise the warning.
  local goldish = { DARK = { name = "DARK" }, STEEL = { name = "STEEL" },
                    NORMAL = { name = "NORMAL" } }
  local mark = #warns
  local gold = specialIds(rulesetFor(goldish), goldish)
  check(gold.DARK, "record-less Dark still uploads as Special (Gold)")
  check(not gold.STEEL, "record-less Steel stays Physical (Gold)")
  local cried = false
  for i = mark + 1, #warns do
    if tostring(warns[i]):find("STEEL", 1, true)
       or tostring(warns[i]):find("DARK", 1, true) then cried = true end
  end
  check(not cried, "...and neither raises a warning: a guard that cries wolf "
        .. "on stock Gold data is a guard nobody reads")

  -- A mod's own type is honoured, which is the point of reading records at
  -- all -- no name list could know about it.
  local modded = {
    NORMAL = { name = "NORMAL", category = "physical" },
    AETHER = { name = "AETHER", category = "special" },
  }
  check(specialIds(rulesetFor(modded), modded).AETHER,
        "a type this client has never heard of is Special if its record says so")

  -- A record with no category at all falls back to the name list, and a type
  -- neither knows is *named* in a warning rather than silently fought as
  -- Physical. The old guard only spoke when the count hit zero, which is why
  -- six-of-seven went unnoticed.
  local before = #warns
  local vague = {
    NORMAL  = { name = "NORMAL" },
    FIRE    = { name = "FIRE" },
    MYSTERY = { name = "MYSTERY" },
  }
  local v = specialIds(rulesetFor(vague), vague)
  check(v.FIRE, "with no categories, the name fallback still finds FIRE")
  local named = false
  for i = before + 1, #warns do
    if tostring(warns[i]):find("MYSTERY", 1, true) then named = true end
  end
  check(named, "a type with no category is named in the warning, not silently "
        .. "treated as Physical")
end
check(ruleset.metronomePool and #ruleset.metronomePool >= 1,
      "Metronome pool is uploaded from the host move table")
local metroHasMetronome = false
for _, sheet in ipairs(ruleset.metronomePool or {}) do
  if sheet.id == "METRONOME" or sheet.id == "metronome" then
    metroHasMetronome = true
  end
end
check(not metroHasMetronome, "Metronome excludes itself from the pool")

-- A build with no chart to read has no matchups to state, and a chart of
-- nothing but neutral cells says exactly that.
local neutral = Mediated.snapshotRuleset(gameWith({}, nil))
eq(#neutral.chart, Mediated.NEUTRAL_TYPES, "no type table falls back to NxN")
eq(#neutral.chart[1], Mediated.NEUTRAL_TYPES, "square")
eq(neutral.chart[4][9], Wire.EFF_NEUTRAL, "of nothing but neutral cells")
check(Wire.battleRuleset(neutral) ~= nil, "and it sanitises too")
eq(neutral.typeIds, nil, "typeIds: no chart, no axis to name")
check(Mediated.NEUTRAL_TYPES <= Config.BATTLE_TYPE_MAX,
      "the fallback fits inside what the wire will carry")

-- Both axes are bounded, and Wire refuses a wider chart outright -- so an
-- over-wide pack has to be cut here or its host could never open a fight.
local wide = { type_chart = { types = {}, matchups = {} } }
for i = 1, Config.BATTLE_TYPE_MAX + 6 do
  wide.type_chart.types[("TYPE_%02d"):format(i)] = { name = "T" }
end
local cut = Mediated.snapshotRuleset(gameWith({}, wide))
eq(#cut.chart, Config.BATTLE_TYPE_MAX, "a pack with too many types is trimmed")
check(Wire.battleRuleset(cut) ~= nil, "so that the ruleset still sanitises")
local goldCut = Mediated.snapshotRuleset(goldWith(wide))
eq(#(goldCut.typeIds or {}), Config.BATTLE_TYPE_MAX,
   "typeIds: Gold's axis is trimmed with the chart, so it still fits the wire")
local goldCutWire = Wire.battleRuleset(goldCut, 2)
eq(goldCutWire and goldCutWire.typeIds and #goldCutWire.typeIds, Config.BATTLE_TYPE_MAX,
   "typeIds: ...and crosses it whole")

-- The ordering is a plain sort, and it has to be: nothing on the wire states
-- it, so two clients whose tables iterated differently would read every one of
-- the guest's moves off the wrong row of the host's chart.
local order = Mediated.typeOrder(DATA)
eq(table.concat(order.ids, ","), "FIRE,NORMAL,WATER", "types sort into one order")

-- ------------------------------------------------------------------
-- 3. a session that opens a battle uploads, and nothing else
-- ------------------------------------------------------------------

local function harness(role, party)
  local side = { sent = {}, said = {}, pushed = {} }
  side.transport = {
    send = function(_, msgType, payload)
      side.sent[#side.sent + 1] = { type = msgType, payload = payload or {} }
      return true
    end,
    isReady = function() return side.dead ~= true end,
  }
  side.ui = {
    say = function(_, text) side.said[#side.said + 1] = text end,
    confirm = function() return {} end,
    choose = function() return {} end,
    pickPartyMon = function() end,
    pushState = function(_, _, state) side.pushed[#side.pushed + 1] = state end,
    ctx = {},
  }
  side.sessions = Sessions.new(side.transport, side.ui)
  side.game = gameWith(party or { mon("CHARMANDER"),
    mon("SQUIRTLE", { moves = { { id = "HYDRO", pp = 5 },
                                { id = "GROWL", pp = 40 } } }) }, DATA)
  side.open = function(id)
    side.sessions:onSession(side.game, {
      peer = "peer1", peerName = "BOB", kind = "battle",
      role = role, id = id or "7",
    })
  end
  side.firstSent = function(msgType)
    for _, entry in ipairs(side.sent) do
      if entry.type == msgType then return entry.payload end
    end
    return nil
  end
  side.countSent = function(msgType)
    local n = 0
    for _, entry in ipairs(side.sent) do
      if entry.type == msgType then n = n + 1 end
    end
    return n
  end
  return side
end

local host = harness("host")
host.open()

local party = host.firstSent(Wire.BATTLE_PARTY)
check(party ~= nil, "opening a battle session uploads a party")
eq(party.battle, "7", "named for the session, which is also the battle id")
check(#party.mons == 2, "with the whole party in it")
check(type(party.bag) == "table", "and a battle bag sheet (PROTOCOL 15)")
check(Wire.battleParty(party) ~= nil, "and it is a party the far end accepts")

local rules = host.firstSent(Wire.BATTLE_RULESET)
check(rules ~= nil, "the host uploads the ruleset")
check(Wire.battleRuleset(rules) ~= nil, "and it is one the far end accepts")

-- The lockstep vocabulary is gone from this path entirely. Both hubs refuse
-- mmo.relay for a battle session, so a hello sent down it would not arrive --
-- and there is nothing left for the handshake to decide anyway.
eq(host.countSent(Wire.RELAY), 0, "no relay traffic: there is no handshake")
eq(host.sessions.active, nil, "and no SessionNet session at all for a battle")
check(host.sessions.fight ~= nil, "the fight is held apart from `active`")
check(host.sessions:isBusy(), "a live fight counts as busy")
eq(#host.pushed, 1, "the battle screen goes up")
eq(host.pushed[1], host.sessions.fight, "and it is the fight itself")
check(Sessions.isFightState(host.sessions.fight),
      "an invite must not pop over it")

-- A new named onSession must follow the hub: it already moved battleId,
-- so keeping the old screen would leave choices unroutable. SESSION_LEAVE
-- would drop the new pairing, not the discarded one.
local stacked = harness("host")
stacked.open("7")
local live = stacked.sessions.fight
local warnBefore = #warns
stacked.open("8")
check(stacked.sessions.fight ~= live, "a new named pairing replaces the local fight")
eq(stacked.sessions.fight.battle, "8", "and follows the hub's new battle id")
eq(stacked.countSent(Wire.SESSION_LEAVE), 0,
   "without leaving the pairing the hub just opened")
check(live.left == true, "the discarded screen cannot endMediated later")
check(#warns > warnBefore, "and says why")

-- The same pairing delivered twice is already on screen: leaving it would
-- forfeit the live fight.
local twice = harness("host")
twice.open("7")
twice.open("7")
eq(#twice.pushed, 1, "the same pairing does not re-push")
eq(twice.countSent(Wire.SESSION_LEAVE), 0, "and does not leave the live fight")

-- beginWildMediated occupancy is still the live fight, so a second call
-- must not SESSION_LEAVE.
local wilder = harness("host")
check(wilder.sessions:beginWildMediated(wilder.game, "w1", {
        mon = mon("CHARMANDER") }) == true,
      "a wild mediated fight opens")
eq(#wilder.pushed, 1, "the wild screen goes up")
local wildLive = wilder.sessions.fight
check(wilder.sessions:beginWildMediated(wilder.game, "w2", {
        mon = mon("CHARMANDER") }) == false,
      "a second wild fight is refused")
eq(wilder.sessions.fight, wildLive, "the live wild fight stays")
eq(#wilder.pushed, 1, "and no second wild screen")
eq(wilder.countSent(Wire.SESSION_LEAVE), 0, "and does not leave the live fight")

-- A finished screen is still on self.fight: onSession of a new pairing
-- drops it (so onDone cannot fire under the replacement) then begins.
local done = harness("host")
done.open("7")
done.sessions.fight:finish("win")
local oldDone = done.sessions.fight
check(done.sessions:beginMediated(done.game, "9", "peer1", "BOB", "host") == true,
      "a new named pairing replaces a finished screen")
check(done.sessions.fight ~= oldDone, "the buried screen is not self.fight")
eq(done.sessions.fight.battle, "9", "the new fight is the one on the pointer")
eq(done.countSent(Wire.SESSION_LEAVE), 0, "without leaving the new pairing")
check(oldDone.left == true, "the old screen cannot endMediated later")

-- Wild must not replace a finished 1v1 either, and must not leave it.
local doneWild = harness("host")
doneWild.open("7")
doneWild.sessions.fight:finish("win")
check(doneWild.sessions:beginWildMediated(doneWild.game, "w2", {
        mon = mon("CHARMANDER") }) == false,
      "wild does not replace a finished 1v1")
eq(doneWild.sessions.fight.battle, "7", "the finished 1v1 stays")
eq(doneWild.countSent(Wire.SESSION_LEAVE), 0, "and is not left")

local guest = harness("guest")
guest.open()
check(guest.firstSent(Wire.BATTLE_PARTY) ~= nil, "the guest uploads a party too")
eq(guest.countSent(Wire.BATTLE_RULESET), 0,
   "but not a ruleset: two charts is a fight with no answer to `which`")

-- A trade session is untouched by any of this.
local trader = harness("host")
trader.sessions:onSession(trader.game, {
  peer = "peer1", peerName = "BOB", kind = "trade", role = "host", id = "8",
})
eq(trader.countSent(Wire.BATTLE_PARTY), 0, "a trade uploads no battle party")
eq(trader.sessions.fight, nil, "and starts no fight")

-- A battle the hub failed to name is one nothing could be uploaded to.
local unnamed = harness("host")
unnamed.sessions:onSession(unnamed.game, {
  peer = "peer1", peerName = "BOB", kind = "battle", role = "host",
})
eq(unnamed.countSent(Wire.BATTLE_PARTY), 0, "an unnamed battle uploads nothing")
eq(unnamed.sessions.fight, nil, "and does not open a screen to wait on")

-- An unnamed SESSION while a fight is live must not SESSION_LEAVE: that
-- message has no id, so it would forfeit the fight the player is in.
local keep = harness("host")
keep.open("7")
keep.sessions:onSession(keep.game, {
  peer = "peer1", peerName = "BOB", kind = "battle", role = "host",
})
eq(keep.sessions.fight.battle, "7", "an unnamed duplicate keeps the live fight")
eq(#keep.pushed, 1, "and does not push another screen")
eq(keep.countSent(Wire.SESSION_LEAVE), 0, "and does not leave it")

-- A player with nothing to fight with is told so rather than left waiting.
local empty = harness("host", {})
empty.open()
eq(empty.countSent(Wire.BATTLE_PARTY), 0, "an empty party is not uploaded")
check(empty.sessions.fight.finished, "the fight ends immediately instead")
check(#warns > 0, "and says why")

-- ------------------------------------------------------------------
-- 4. the fingerprint gate is not consulted
-- ------------------------------------------------------------------
--
-- This is the assertion the whole mediated path exists for. canBattle refused a
-- pairing whose content differed, because a lockstep pair had to roll the same
-- numbers from the same tables; the intermediator rolls them now, off an
-- uploaded chart and uploaded parties, so a Red can fight a Yellow and a data
-- pack can fight vanilla. Counted rather than reasoned about: a later edit that
-- reintroduces the gate fails here rather than in somebody's game.
local realCanBattle = Sessions.canBattle
local canBattleCalls = 0
Sessions.canBattle = function(...)
  canBattleCalls = canBattleCalls + 1
  return realCanBattle(...)
end

local gated = harness("host")
gated.open()
eq(canBattleCalls, 0, "opening a mediated battle never asks canBattle")

-- ...and the rule it states is unchanged, because a cable-club link would still
-- consult it and tests/drivers/red_yellow_battle_compat.lua still drives it.
local fakeHandshake = {
  battleAllowed = function(verdict) return verdict == "full" end,
}
Sessions.canBattle = realCanBattle
eq(Sessions.canBattle("refused", {}, {}, fakeHandshake), false,
   "canBattle still refuses a refused verdict when something does ask it")
eq(Sessions.canBattle("subset", {}, {}, fakeHandshake), true,
   "and still allows two unmodified copies that merely differ")

-- ------------------------------------------------------------------
-- 5. the fight itself
-- ------------------------------------------------------------------

local function fakeInput()
  local pressed = {}
  return {
    press = function(name) pressed[name] = true end,
    wasPressed = function(_, name)
      if not pressed[name] then return false end
      pressed[name] = nil
      return true
    end,
  }
end

local play = harness("host")
play.game.input = fakeInput()
play.open()
local fight = play.sessions.fight

-- Which side we are on is read back from the roster rather than assumed: the
-- peer's id is what decides it, since the side they are not on is ours.
play.sessions:onBattleReady({
  battle = "7", mode = "1v1", sides = { a = { "me" }, b = { "peer1" } },
})
eq(fight.mySide, "a", "the side the peer is not on is ours")
eq(fight:mySlot(), 0, "side a takes field slot 0")
eq(fight:foeSlot(), 3, "and side b slot 3, leaving slots 1-2 empty on a 1v1 field")
eq(fight.phase, "play", "and the fight is under way")

-- An event about somebody else's match is inert.
local before = fight.seq
play.sessions:onBattleEvent({ battle = "99", seq = 1, t = "msg", text = "no" })
eq(fight.seq, before, "an event naming another battle is ignored")

local function event(fields)
  fields.battle = "7"
  play.sessions:onBattleEvent(fields)
end

event({ seq = 1, t = "send", slot = 0, text = "SQUIRTLE", hp = 30 })
event({ seq = 2, t = "send", slot = 3, text = "PIDGEY", hp = 24 })
eq(fight.slots[3].species, "PIDGEY", "a send puts a name on the foe's box")
eq(fight.slots[3].maxHp, 24, "and the first HP seen is taken as the maximum")
eq(fight.active, 2, "our own send-out is matched back to the party we uploaded")

-- Classic field helpers stay callable without a graphics device.
check(type(fight.drawEnemyHUD) == "function", "classic foe HUD is wired")
check(type(fight.drawPlayerHUD) == "function", "classic ally HUD is wired")
check(type(fight.enemyPicXY) == "function", "foe pic placement is wired")
check(type(fight.playerPicXY) == "function", "ally pic placement is wired")
check(fight.isOpaque == true, "1v1 battle is opaque so overworld does not draw under it")
check(fight.letterboxWhite ~= true,
  "1v1 skips letterboxWhite so voids stay black (not SGB paper pink)")
local ex, ey = fight:enemyPicXY(nil)
eq(ex, 88, "fallback foe pic x matches classic anchor")
eq(ey, 0, "fallback foe pic y matches classic anchor")
local px, py, ps = fight:playerPicXY(nil)
eq(px, 8, "fallback ally pic x matches classic anchor")
eq(py, 40, "fallback ally pic y matches classic anchor")
eq(ps, 2, "ally back pic draws at 2x like the GB / BattleState default")
eq(fight.PLAYER_PIC_SCALE, 2, "PLAYER_PIC_SCALE is published for the suite")
-- A 56px-tall back sheet at 2x sits with feet on y=96 (top at y=-16).
local fake = { getDimensions = function() return 56, 56 end }
local sx, sy, ss = fight:playerPicXY(fake)
eq(ss, 2, "measured ally pic keeps the 2x scale")
eq(sx, 8, "measured ally pic keeps the classic left edge")
eq(sy, 96 - 56 * 2, "feet stay on the text-box top at 2x")
-- Already-paletted pics must not take an OG/CLASSIC GRAYS remap.
check(type(fight.sgbPalettes) == "function", "sgbPalettes opt-out is wired")
check(type(fight.zones) == "function", "zones opt-out is wired")
local pals = fight:sgbPalettes()
eq(type(pals), "table", "sgbPalettes returns a zone list")
eq(pals[1] and pals[1].colors, false, "sgbPalettes opts out of shade remap")
-- `fight.game` is Gen1-shaped (DATA carries no type_chart.generation), so the
-- 640x360 battlefield hard-cut (commit 201ca00) is live and the opt-out zone
-- legitimately covers the arena canvas, not the pre-Battlefield 160x144 one.
eq(pals[1] and pals[1].w, 640,
   "sgbPalettes covers the battlefield arena canvas once Gen1 + Battlefield "
   .. "hard-cuts the wide layout")
local z = fight:zones()
eq(z[1] and z[1].colors, false, "zones matches the sgbPalettes opt-out")
eq(z[1] and z[1].w, 640, "...and the same 640-wide arena canvas")

-- Gold takes the arena too, from round 7
-- (docs/plans/gen2-new-battle-system.md), so a Gen2-shaped game is no longer
-- the classic stand-in it used to be here.
local goldFight = setmetatable({
  game = { data = { type_chart = { generation = 2 } } },
}, { __index = Mediated })
check(goldFight:usesBattlefield(),
      "a Gen2-shaped game takes the battlefield gate as well")
check(goldFight:drawsWidescreen(),
      "...and reaches the window through Gold's widescreen seam, since "
      .. "src/core/Game2.lua has no uiSize / fill-scale of its own")
-- ...but its ZONE stays 160x144, because a zone rect is in the receiving
-- generation's space and Gold's is always screen space: `Game2:blitZones`
-- scales every rect by `w/160, h/144`, so the arena's own 640 would mean four
-- times the window there. It clamped back to the window and looked right,
-- which is exactly why this is asserted rather than left to the eye.
local gz = goldFight:zones()
eq(gz[1] and gz[1].w, 160,
   "...while its zone stays in Gold's 160x144 screen space")
eq(gz[1] and gz[1].h, 144, "...both axes")
eq(gz[1] and gz[1].colors, false,
   "...and still opts out of the palette shader, which is all the zone is for")

-- The classic 160x144 zone is what a boot with the gate DOWN takes: still a
-- live path (`Battlefield.enabled` answers false whenever `Gen.generation`
-- throws on a half-built game), just no longer reachable by naming a
-- generation. `usesBattlefield` set on the instance shadows the class method,
-- which is the single switch every one of these surfaces reads.
local classicFight = setmetatable({
  game = { data = {} },
  usesBattlefield = function() return false end,
}, { __index = Mediated })
check(not classicFight:usesBattlefield(),
      "with the gate down the classic path is what is left")
local cz = classicFight:zones()
eq(cz[1] and cz[1].w, 160,
   "...and zones covers the classic 160x144 canvas there")
eq(fight:speciesKeyFor("SQUIRTLE", true), "SQUIRTLE",
   "speciesKeyFor resolves an uploaded registry id")

event({ seq = 3, t = "damage", slot = 3, hp = 9, amount = 15 })
eq(fight.slots[3].hp, 9, "damage is applied from the event's own HP")
eq(fight.slots[3].maxHp, 24, "and the bar still knows what it is out of")

-- seq is what makes the stream a stream.
event({ seq = 3, t = "msg", text = "again" })
eq(fight.seq, 3, "a repeated sequence is dropped")
event({ seq = 7, t = "msg", text = "jumped" })
eq(fight.seq, 7, "a gap is followed rather than refused")
eq(fight.gaps, 1, "but it is counted, so a lossy hub is visible")

-- A turn is held until the lines it produced have been read: opening the menu
-- over them would take the box the player is reading out from under them.
event({ seq = 8, t = "turn" })
check(fight.pendingTurn, "a turn event is held, not acted on")
eq(fight.phase, "play", "the menu does not open over unread text")

local guard = 0
while fight.phase ~= "choose" and guard < 40 do
  fight:update(2.0)
  guard = guard + 1
end
eq(fight.phase, "choose", "once the queue drains, the menu opens")

-- Forced skip: hub chose for our seat before the menu would open — stay in play.
event({ seq = 9, t = "turn" })
event({ seq = 10, t = "msg", text = "SQUIRTLE must recharge" })
event({ seq = 11, t = "chose", slot = 0, text = "me" })
check(fight.answeredTurn, "own chose marks the turn answered")
check(not fight.pendingTurn, "and clears the pending menu open")
guard = 0
while fight.shown ~= nil or #fight.lines > 0 do
  fight:update(2.0)
  guard = guard + 1
  if guard > 40 then break end
end
fight:update(0)
eq(fight.phase, "play", "forced chose never opens the command menu")

-- A fresh turn without a chose still opens the menu as before.
event({ seq = 12, t = "turn" })
guard = 0
while fight.phase ~= "choose" and guard < 40 do
  fight:update(2.0)
  guard = guard + 1
end
eq(fight.phase, "choose", "an unanswered turn still opens the menu")

-- Cursor / multi-move send while Squirtle (2 moves) is still out.
do
  local active = fight:activeMon()
  eq(#(active and active.moves or {}), 2, "Squirtle still offers both moves")
  play.game.input.press("a")
  fight:update(0)
  eq(fight.phase, "move", "A on FIGHT opens the move list before faint")
  play.game.input.press("down")
  fight:update(0)
  eq(fight.cursor, 2, "the cursor moves")
  -- B cancels back; the real send is asserted after replace below.
  play.game.input.press("b")
  fight:update(0)
  eq(fight.phase, "choose", "B returns to the command box")
end

-- Faint with bench: next turn opens the replace picker (B cannot cancel).
-- Pacing: faint line must drain before the picker opens.
do
  local activeIdx = fight.active
  fight.mine[activeIdx].hp = 0
  for i, m in ipairs(fight.mine) do
    if i ~= activeIdx and (m.hp or 0) <= 0 then m.hp = 10 end
  end
end
event({ seq = 13, t = "faint", slot = 0, text = "SQUIRTLE", amount = 1 })
check(fight.mustReplace, "own faint with amount=1 arms mustReplace")
check(fight.shown ~= nil or #fight.lines > 0, "faint line is queued before picker")
event({ seq = 14, t = "turn" })
-- While the faint line is still showing, the switch picker must not open.
check(fight.phase ~= "switch", "picker waits for faint narration")
guard = 0
while (fight.shown ~= nil or #fight.lines > 0) and guard < 40 do
  fight:update(2.0)
  guard = guard + 1
end
guard = 0
while fight.phase ~= "switch" and guard < 40 do
  fight:update(2.0)
  guard = guard + 1
end
eq(fight.phase, "switch", "mustReplace opens the switch picker after msg")
check(fight.replaceOnly, "and marks the picker uncancellable")
event({ seq = 15, t = "send", slot = 0, text = "CHARMANDER", hp = 40 })
check(not fight.mustReplace, "send clears mustReplace")

-- Drain the send line, then a fresh turn reopens the command menu.
guard = 0
while (fight.shown ~= nil or #fight.lines > 0) and guard < 40 do
  fight:update(2.0)
  guard = guard + 1
end
event({ seq = 16, t = "turn" })
guard = 0
while fight.phase ~= "choose" and guard < 40 do
  fight:update(2.0)
  guard = guard + 1
end
eq(fight.phase, "choose", "after replace, a new turn opens the menu")

-- Empty-bench faint on a dedicated screen: no amount → never arms replace.
do
  local alone = harness("host")
  alone.game.input = fakeInput()
  alone.open("empty-bench")
  local f = alone.sessions.fight
  alone.sessions:onBattleReady({
    battle = "empty-bench", mode = "1v1",
    sides = { a = { "me" }, b = { "peer1" } },
  })
  alone.sessions:onBattleEvent({
    battle = "empty-bench", seq = 1, t = "send", slot = 0,
    text = "SQUIRTLE", hp = 1,
  })
  for _, m in ipairs(f.mine or {}) do m.hp = 0 end
  alone.sessions:onBattleEvent({
    battle = "empty-bench", seq = 2, t = "faint", slot = 0,
    text = "SQUIRTLE",
  })
  check(not f.mustReplace, "empty-bench faint (no amount) does not arm replace")
  -- Drain narration so the screen can settle.
  local guard = 0
  while (f.shown ~= nil or #f.lines > 0 or f.anim) and guard < 40 do
    f:update(2.0)
    guard = guard + 1
  end
  alone.sessions:onBattleEvent({ battle = "empty-bench", seq = 3, t = "turn" })
  alone.sessions:onBattleEvent({ battle = "empty-bench", seq = 4, t = "over" })
  check(f.phase ~= "switch", "no replace picker after empty-bench faint")
end

-- KO pic stays on screen through a queued move flash + "fainted!" line.
-- Clearing the sprite in noteSlot(faint) used to drop it under a still-queued
-- anim the moment HP hit 0.
do
  local alone = harness("host")
  alone.game.input = fakeInput()
  alone.open("pic-hold")
  local f = alone.sessions.fight
  alone.sessions:onBattleReady({
    battle = "pic-hold", mode = "1v1",
    sides = { a = { "me" }, b = { "peer1" } },
  })
  local function ev(fields)
    fields.battle = "pic-hold"
    alone.sessions:onBattleEvent(fields)
  end
  ev({ seq = 1, t = "send", slot = 0, text = "SQUIRTLE", hp = 30 })
  ev({ seq = 2, t = "send", slot = 3, text = "PIDGEY", hp = 24 })
  local foe = f.slots[3]
  foe.sprite = { id = "foe-pic" }
  -- Anim first (still in lines), then damage to 0, then faint — the old bug
  -- nil'd the sprite on faint while the anim row had not played yet.
  ev({ seq = 3, t = "anim", slot = 0, text = "TACKLE", side = "a" })
  ev({ seq = 4, t = "damage", slot = 3, hp = 0 })
  ev({ seq = 5, t = "faint", slot = 3, text = "PIDGEY" })
  check(foe.sprite ~= nil, "faint event does not clear the pic immediately")
  check(foe.koHold, "and marks the pic as held through the KO presentation")
  -- Drain until the anim row would have been taken (AnimPlayer may be absent
  -- headless — startAnim still sets f.anim and tickMessages dwells it).
  local guard = 0
  while f.anim == nil and #f.lines > 0 and guard < 20 do
    -- Pull until anim starts or faint line shows; do not skip the whole queue.
    if f.shown then
      alone.game.input.press("a")
    end
    f:update(0.05)
    guard = guard + 1
  end
  check(foe.sprite ~= nil,
        "pic still held while the move flash / faint line is in flight")
  guard = 0
  while (f.shown ~= nil or #f.lines > 0 or f.anim) and guard < 80 do
    alone.game.input.press("a")
    f:update(2.0)
    guard = guard + 1
  end
  check(foe.sprite == nil, "clearPic releases the foe after the faint line")
  check(not foe.koHold, "and clears the hold flag")
end

-- The move list is our own uploaded sheet, which is the only copy of it this
-- side has -- the intermediator narrates by name and never sends it back.
local active = fight:activeMon()
check(active ~= nil, "the menu knows which of ours is out")
eq(active.species, "CHARMANDER", "post-replace active matches the send")
eq(#active.moves, 1, "and offers exactly its moves")

-- Command box first (FIGHT is the default), then the move list.
play.game.input.press("a")
fight:update(0)
eq(fight.phase, "move", "A on FIGHT opens the move list")
play.game.input.press("a")
fight:update(0)

local choice = play.firstSent(Wire.BATTLE_CHOICE)
check(choice ~= nil, "A on a move sends a choice")
eq(choice.battle, "7", "naming the battle it is for")
eq(choice.action, "fight", "as a fight")
eq(choice.move, 0, "with the move index, zero-based on the wire")
eq(choice.target, nil, "and no target: a 1v1 has exactly one thing to hit")
check(Wire.battleChoice(choice) ~= nil, "and it is a choice the hub accepts")
eq(fight.phase, "play", "the menu closes behind it")

-- Nothing here says who is choosing. Which combatant a choice is from is the
-- connection it arrived on, because an id in the payload is an id a modified
-- client could set to somebody else's and spend their turn.
eq(choice.from, nil, "a choice carries no sender")
eq(choice.player, nil, "under any spelling")

-- ------------------------------------------------------------------
-- 6. how it ends
-- ------------------------------------------------------------------
--
-- `outcome` is stated from the field's point of view -- "win" means the winners
-- list won -- and both clients receive the same payload, so it says nothing on
-- its own about the recipient. The peer's id is what turns it into a sentence.

eq(Mediated.resultFor({ outcome = "win", winners = { "me" }, losers = { "peer1" } },
                      "peer1"), "win",
   "the peer in the losers list means we won")
eq(Mediated.resultFor({ outcome = "win", winners = { "peer1" }, losers = { "me" } },
                      "peer1"), "loss",
   "and in the winners list, that we lost")
eq(Mediated.resultFor({ outcome = "forfeit", winners = { "me" },
                        losers = { "peer1" } }, "peer1"), "win",
   "a forfeit is read the same way")
eq(Mediated.resultFor({ outcome = "draw" }, "peer1"), "draw",
   "a draw carries no lists -- the absence is the statement")

play.sessions:onBattleOutcome({
  battle = "7", outcome = "win", winners = { "me" }, losers = { "peer1" },
  reason = "ko",
})
check(fight.finished, "the outcome ends the fight")
eq(fight.result, "win", "and this side knows which way")

-- **No mmo.result.** The dual-client vote existed because neither peer in a
-- relayed battle could be believed about its own win. The intermediator did
-- every roll, so its word is the whole account -- and the way that is made
-- structural rather than remembered is that nothing on this path records a
-- lastBattle for Client.reportBattle to claim.
eq(play.countSent(Wire.RESULT), 0, "a mediated battle reports no result")
eq(play.sessions:claimBattle(), nil, "because there is nothing to claim")
eq(play.sessions.lastBattle, nil, "and nothing was ever recorded")

-- A second outcome for the same fight changes nothing.
play.sessions:onBattleOutcome({ battle = "7", outcome = "loss",
                                winners = { "peer1" }, losers = { "me" } })
eq(fight.result, "win", "a late second outcome does not rewrite the first")

-- ------------------------------------------------------------------
-- 7. the ways out
-- ------------------------------------------------------------------

-- The peer leaving the field is not the fight ending: it starts the
-- intermediator's reconnect grace, and what ends the battle is the outcome sent
-- when that grace expires -- or the reconnect event, if they come back.
local dropped = harness("host")
dropped.game.input = fakeInput()
dropped.open()
dropped.sessions:onBattleReady({
  battle = "7", mode = "1v1", sides = { a = { "me" }, b = { "peer1" } },
})
dropped.sessions:onSessionEnd("peer_left")
check(not dropped.sessions.fight.finished,
      "a peer leaving does not close the battle -- the grace is still running")
check(dropped.sessions.fight ~= nil, "and the screen stays up to be told how it went")

dropped.sessions:onBattleOutcome({
  battle = "7", outcome = "forfeit", winners = { "me" }, losers = { "peer1" },
  reason = "disconnect",
})
eq(dropped.sessions.fight.result, "win", "the grace expiring is a win, from the hub")

-- ...but the hub going away underneath the fight only narrates: the
-- intermediator's reconnect grace is still running, and finishing here would
-- forfeit a fight the player is about to rejoin.
local lost = harness("host")
lost.game.input = fakeInput()
lost.open()
lost.dead = true
lost.sessions:update(lost.game, 0)
check(not lost.sessions.fight.finished,
      "a dead transport does not close the battle -- the grace is still running")
check(lost.sessions.fight.awaitingReconnect == true,
      "and the screen says it is waiting to reconnect")

-- A dropped link must not spend the turn: sendChoice used to ignore
-- awaitingReconnect, put a choice on the wire, and set answeredTurn.
eq(lost.sessions.fight:sendChoice({ action = "fight", move = 0 }), false,
   "sendChoice refuses while awaiting reconnect")
eq(lost.sessions.fight.answeredTurn, false,
   "and does not mark the turn answered")
eq(lost.countSent(Wire.BATTLE_CHOICE), 0,
   "so no choice went on the wire")

-- Coming back sends mmo.battle_reconnect once with the battle id.
lost.dead = false
lost.sessions:update(lost.game, 0)
eq(lost.countSent(Wire.BATTLE_RECONNECT), 1,
   "the ready flip sends mmo.battle_reconnect")
eq(lost.firstSent(Wire.BATTLE_RECONNECT).battle, "7",
   "naming the fight that is still on the stack")
lost.sessions:update(lost.game, 0)
eq(lost.countSent(Wire.BATTLE_RECONNECT), 1,
   "and only once per drop cycle")

-- isReady is its own gate: a live screen with a dead transport still
-- must not file, even after the reconnect wait flag is cleared.
lost.dead = true
lost.sessions.fight.awaitingReconnect = false
eq(lost.sessions.fight:sendChoice({ action = "fight", move = 0 }), false,
   "sendChoice also refuses when the transport is not ready")
eq(lost.sessions.fight.answeredTurn, false,
   "and still does not mark the turn answered")
eq(lost.countSent(Wire.BATTLE_CHOICE), 0,
   "and still puts no choice on the wire")

-- The same hook is reachable directly for a screen with no Sessions wrapper.
local solo = harness("host")
solo.open()
eq(solo.sessions.fight:notifyReconnect(), true,
   "notifyReconnect is the testable alias")
eq(solo.countSent(Wire.BATTLE_RECONNECT), 1, "and it puts the same message on the wire")
eq(solo.sessions.fight:notifyReconnect(), false, "a second call is refused until another drop")

-- Walking off the hub entirely, which is the path Client.disconnect takes.
local quit = harness("host")
quit.game.input = fakeInput()
quit.open()
quit.sessions:endSession(nil)
eq(quit.sessions.fight, nil, "endSession lets go of the fight")
check(not quit.sessions:isBusy(), "and the player is no longer busy")

-- Leaving the screen tells the hub, so the pairing is not left open until a
-- grace expires.
local leaver = harness("host")
leaver.game.input = fakeInput()
leaver.open()
local leaving = leaver.sessions.fight
leaving:exit()
eq(leaver.countSent(Wire.SESSION_LEAVE), 1, "the way out says so")
eq(leaver.sessions.fight, nil, "and the session lets go")
leaving:exit()
eq(leaver.countSent(Wire.SESSION_LEAVE), 1, "said once, however often it is asked")

-- ------------------------------------------------------------------
-- 8. the test hook, and why it is not the game
-- ------------------------------------------------------------------
--
-- autoPick answers a turn the instant it opens, which is what lets a driver run
-- a whole fight with no input device. It is never set in the game: the
-- intermediator already auto-picks for a player who says nothing before
-- BATTLE_CHOICE_TIMEOUT, so a client that silently picked as well would be
-- spending turns the player is still thinking about.
local auto = harness("host")
auto.sessions.autoPick = true
auto.game.input = fakeInput()
auto.open()
auto.sessions:onBattleReady({
  battle = "7", mode = "1v1", sides = { a = { "me" }, b = { "peer1" } },
})
auto.sessions:onBattleEvent({ battle = "7", seq = 1, t = "send", slot = 0,
                              text = "CHARMANDER", hp = 30 })
auto.sessions:onBattleEvent({ battle = "7", seq = 2, t = "turn" })
guard = 0
while auto.countSent(Wire.BATTLE_CHOICE) == 0 and guard < 40 do
  auto.sessions.fight:update(2.0)
  guard = guard + 1
end
eq(auto.countSent(Wire.BATTLE_CHOICE), 1, "autoPick answers the turn unaided")
eq(auto.firstSent(Wire.BATTLE_CHOICE).move, 0, "with the first move")

local manual = harness("host")
manual.game.input = fakeInput()
manual.open()
eq(manual.sessions.fight.autoPick, false, "and it is off by default")

-- ------------------------------------------------------------------
-- 9. a real party, through the real sanitiser
-- ------------------------------------------------------------------
--
-- The synthetic world above pins the numbers; this pins that an actual engine
-- party -- built by the engine's own constructor, off the committed fixture
-- dataset -- survives the boundary. A snapshot Wire drops is a fight that never
-- starts, and no assertion about indices would catch it.

local ok, Data = pcall(function()
  local loaded = T.fixtures.load()
  return loaded
end)
if ok and type(Data) == "table" then
  local okMon, Pokemon = pcall(require, "src.pokemon.Pokemon")
  local species = nil
  for id in pairs(Data.pokemon or {}) do
    if species == nil or id < species then species = id end
  end
  if okMon and species then
    local real = { Pokemon.new(Data, species, 15) }
    local snapshot = Mediated.snapshotParty({ data = Data, save = { party = real } })
    eq(#snapshot, 1, "a real engine mon snapshots")
    check(Wire.battleParty({ battle = "1", mons = snapshot }) ~= nil,
          "and the real party survives Wire.battleParty")
    local realRules = Mediated.snapshotRuleset({ data = Data })
    check(Wire.battleRuleset(realRules) ~= nil,
          "as does a ruleset built from the real type chart")
    -- ------- which types went up as Special
    --
    -- **This used to rebuild snapshotRuleset's own name table and assert the
    -- upload matched it**, which is a tautology: the list could be wrong in
    -- any way at all and both halves were wrong together. It was, for a long
    -- time -- Psychic's registry id is `PSYCHIC_TYPE` (because `PSYCHIC` is a
    -- move), the table keyed on `PSYCHIC`, and the whole type shipped as
    -- Physical. Six of seven matched, so nothing looked odd.
    --
    -- So the expectation is derived from the chart's own `category` records
    -- now -- the thing the production code is supposed to be reading -- and
    -- falls back to the *ids* rather than the display names.
    local order = Mediated.typeOrder(Data)
    local charted = type(Data.type_chart) == "table" and Data.type_chart.types
    local SPECIAL_IDS = {
      FIRE = true, WATER = true, GRASS = true, ELECTRIC = true,
      ICE = true, DRAGON = true, DARK = true,
      PSYCHIC = true, PSYCHIC_TYPE = true,
    }
    local expectSpecial, expectIds = 0, {}
    if order then
      for _, id in ipairs(order.ids) do
        local record = type(charted) == "table" and charted[id] or nil
        local category = type(record) == "table" and record.category or nil
        local isSpecial
        if category ~= nil then isSpecial = (category == "special")
        else isSpecial = SPECIAL_IDS[id] == true end
        if isSpecial then
          expectSpecial = expectSpecial + 1
          expectIds[id] = true
        end
      end
    end
    eq(realRules.specialTypes and #realRules.specialTypes, expectSpecial,
       "specialTypes covers every Special type in the chart's own records")

    -- ...and the one that would have caught it, stated as the fact it is:
    -- if this dataset carries Psychic at all, Psychic is Special. Skipped
    -- rather than failed on a fixture that has no Psychic, because this tier
    -- runs against whatever the checkout has.
    local psychicId = nil
    for _, id in ipairs((order and order.ids) or {}) do
      if id == "PSYCHIC_TYPE" or id == "PSYCHIC" then psychicId = id end
    end
    if psychicId then
      local idx = order.index[psychicId]
      local got = false
      for _, v in ipairs(realRules.specialTypes or {}) do
        if v == idx then got = true end
      end
      check(got, "Psychic is uploaded as Special (id " .. psychicId
            .. ", chart index " .. tostring(idx) .. ") -- it is the type whose "
            .. "registry id is not its own name")
    else
      check(true, "(this dataset carries no Psychic type -- check skipped)")
    end
    local moveN = 0
    if type(Data.moves) == "table" then
      for id in pairs(Data.moves) do
        if id ~= "STRUGGLE" and id ~= "struggle" then moveN = moveN + 1 end
      end
    end
    local poolN = realRules.metronomePool and #realRules.metronomePool or 0
    if moveN > 0 then
      check(poolN >= 1 and poolN <= Config.BATTLE_METRONOME_POOL_MAX,
            "Metronome pool is non-empty from fixture moves ("
              .. tostring(poolN) .. ")")
    end
  end
end

-- ------------------------------------------------------------------
-- 10. vitamin writeback: Stat Exp + live stats without engine Stats
-- ------------------------------------------------------------------

do
  local mon = {
    species = "TESTMON", level = 100,
    hp = 40, stats = { hp = 40, attack = 40, defense = 40, speed = 40, special = 40 },
    statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 },
    dvs = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 },
  }
  local game = { save = { party = { mon } }, data = { pokemon = {} } }
  check(Mediated.writebackVitamin(game, 1, "PROTEIN") == true,
        "PROTEIN writeback succeeds without a species def")
  eq(mon.statExp.attack, 2560, "Stat Exp gains 2560")
  -- Gen1 √EV delta at L100: floor((floor(sqrt(2560)/4) - 0) * 100 / 100) = 12
  eq(mon.stats.attack, 52, "attack rises by the √EV contribution without Stats.calc")
end

-- ------------------------------------------------------------------
-- 11. the arrival window: a monster is on the arena when its row says so
-- ------------------------------------------------------------------
--
-- The seat record moves with the referee -- it is what the rules are read from
-- -- but nothing is *drawn* on the arena until the queued `spawnfx` row plays.
-- Two mechanisms, one for each state a seat can be in when a send lands, and
-- both close on that same row: `spawnHide` for an empty seat (the intro), and
-- `slot.pending` for a seat somebody is still standing on (a switch, or a
-- replacement batched behind the KO it replaces). CoopBattle's `introHide` and
-- its display shadow / `applySwap` are the twins.

do
  local arena = harness("host")
  arena.game.input = fakeInput()
  arena.open()
  local a = arena.sessions.fight
  arena.sessions:onBattleReady({
    battle = "7", mode = "1v1", sides = { a = { "me" }, b = { "peer1" } },
  })
  check(a:usesBattlefield(), "the arena path is the one under test")
  local n = 0
  local function ev(fields)
    n = n + 1
    fields.battle = "7"; fields.seq = n
    arena.sessions:onBattleEvent(fields)
  end
  local function drain(limit)
    local guard = 0
    while #a.lines > 0 and guard < (limit or 900) do
      a:update(1 / 60); guard = guard + 1
    end
    return guard
  end

  -- The intro. Both seats are filled at parse and neither is drawn.
  ev({ t = "send", slot = 0, text = "SQUIRTLE", hp = 30 })
  ev({ t = "send", slot = 3, text = "PIDGEY", hp = 24 })
  eq(a.slots[3].species, "PIDGEY", "the seat record follows the referee at parse")
  eq(a:battlefieldSeat(3, false), nil,
     "...but nothing is on the arena until the spawn row: an empty seat is held")
  eq(a:battlefieldSeat(0, true), nil, "...on our own side too")
  check(drain() < 900, "the intro queue drains in bounded frames")
  check(a:battlefieldSeat(3, false) ~= nil,
        "once the spawn rows have played, both seats draw")
  check(a:battlefieldSeat(0, true) ~= nil, "...ally included")
  check(a.spawnHide == nil or next(a.spawnHide) == nil,
        "and no hold is left standing behind them")

  -- A replacement batched behind the KO: the seat is the fallen monster's
  -- until the swap, which is what lets its drain and sink play at all.
  ev({ t = "damage", slot = 3, hp = 0, amount = 24 })
  ev({ t = "faint", slot = 3, text = "PIDGEY" })
  ev({ t = "send", slot = 3, text = "RATTATA", hp = 21 })
  eq(a.slots[3].species, "PIDGEY",
     "a send into an occupied seat does not relabel it")
  eq(a.slots[3].pending and a.slots[3].pending.species, "RATTATA",
     "...the arrival is parked instead")
  eq(a.slots[3].hp, 0, "...and the fallen monster's own numbers are left alone")
  local seat = a:battlefieldSeat(3, false)
  eq(seat and seat.name, "PIDGEY", "so the arena still shows who is falling")
  local sawSink, drawnBeforeSwap = false, nil
  local guard = 0
  while #a.lines > 0 and guard < 900 do
    a:update(1 / 60); guard = guard + 1
    for _, e in ipairs(a.fx or {}) do
      if e.kind == "faint" then sawSink = true end
    end
    local live = a:battlefieldSeat(3, false)
    if live and live.name == "RATTATA" and drawnBeforeSwap == nil then
      drawnBeforeSwap = sawSink
    end
  end
  check(guard < 900, "the batched queue drains in bounded frames")
  check(sawSink, "the KO sinks -- its rows still name the occupant they were filed for")
  eq(drawnBeforeSwap, true,
     "and the newcomer is first drawn only after that sink, at its own spawn row")
  eq(a.slots[3].species, "RATTATA", "the seat changes hands exactly once, there")
  eq(a.slots[3].pending, nil, "...leaving nothing parked")
  eq(a.slots[3].shownHp, 21, "...and the bar starts where the referee put it")

  -- ------- the hit that lands inside the window belongs to the newcomer
  --
  -- The switch and the attack that answers it resolve in **one batch** -- the
  -- referee fields every switch before it runs a single fight
  -- (`_resolveTurn`, src/BattleSim/Turn.lua) -- so a monster is struck while
  -- its own arrival is still parked on every turn somebody switches into a
  -- move. Read off the seat, that fall was measured against the *departing*
  -- monster's numbers, came out as no fall at all, and queued nothing: the
  -- newcomer was installed at its post-hit HP and the attack showed nothing.
  -- No flash, no nudge, no impact burst, no bar. So the row is filed against
  -- whoever the seat will be showing when it plays, and the arrival carries
  -- the HP it walked out with for the bar to start from.
  local hits = 0
  for _, e in ipairs(a.fx or {}) do if e.kind == "flash" then hits = hits + 1 end end
  ev({ t = "switch", slot = 3, text = "NIDORAN", speciesId = 29, level = 6, mon = 2 })
  ev({ t = "send", slot = 3, text = "NIDORAN", hp = 26, maxHp = 26,
       speciesId = 29, level = 6, mon = 2 })
  ev({ t = "anim", slot = 0, side = "a", text = "TACKLE" })
  ev({ t = "damage", slot = 3, hp = 17, amount = 9 })
  eq(a.slots[3].species, "RATTATA",
     "the seat is still the departing monster's while the arrival is parked")
  eq(a.slots[3].hp, 21, "...and the hit is not written to its numbers")
  eq(a.slots[3].pending.hp, 17, "the referee's number lands on the newcomer")
  eq(a.slots[3].pending.shownHp, 26,
     "...whose bar still starts where it walked out")
  local filed = nil
  for _, row in ipairs(a.lines) do
    if row.drain then filed = row end
  end
  check(filed ~= nil, "a fall is queued for it -- this is the regression")
  eq(filed and filed.species, "NIDORAN",
     "...named for the monster that took it, so it survives the swap")
  eq(filed and filed.to, 17, "...and falls to the referee's number")

  local sawHit, walkedOutAt = false, nil
  guard = 0
  while (#a.lines > 0 or a.draining) and guard < 1500 do
    a:update(1 / 60); guard = guard + 1
    if a.slots[3].species == "NIDORAN" and walkedOutAt == nil then
      walkedOutAt = a.slots[3].shownHp
    end
    for _, e in ipairs(a.fx or {}) do if e.kind == "flash" then sawHit = true end end
  end
  check(guard < 1500, "the batch drains in bounded frames")
  eq(walkedOutAt, 26, "the newcomer is drawn whole, before the blow reads")
  check(sawHit, "...the hit reads on it (beat 3: the flash and the nudge)")
  eq(a.slots[3].shownHp, 17, "...and the bar finishes where the referee put it")
  eq(a.slots[3].hp, 17, "...with the seat's truth agreeing")

  -- Teardown: a battle ending mid-window strands neither a hold nor a park.
  ev({ t = "send", slot = 3, text = "PIDGEY", hp = 24 })
  check(a.slots[3].pending ~= nil, "a fresh arrival is parked")
  a:snapDisplay()
  eq(a.slots[3].species, "PIDGEY",
     "snapDisplay closes the window forwards -- the field is where the referee "
     .. "says it is, not where the queue had gotten to")
  eq(a.slots[3].pending, nil, "...with nothing parked behind it")
  eq(a.spawnHide, nil, "...and no seat left hidden")
end

-- ------- particles, through the queue that orders them
--
-- Every move, every item and every condition landing has a look
-- (src/Vfx.lua), and the assertions that matter are about *when* it is
-- emitted rather than what it looks like: an effect played at parse instead of
-- at the row's turn in the queue is on screen several sentences before the one
-- it belongs to, which is the defect the whole beat structure exists to avoid.

do
  local arena = harness("host")
  arena.game.input = fakeInput()
  -- Two move records, so the catalogue resolves a real type rather than
  -- falling through to NORMAL. `moveDefFor` reads exactly this table.
  arena.game.data = arena.game.data or {}
  arena.game.data.moves = arena.game.data.moves or {}
  arena.game.data.moves.EMBER = { id = "EMBER", type = "FIRE", power = 40 }
  arena.game.data.moves.GROWL = { id = "GROWL", type = "NORMAL", power = 0 }
  -- The session id is the battle id (`harness`), so it is named here rather
  -- than left on the default -- the events below have to reach this fight.
  arena.open("9")
  local a = arena.sessions.fight
  arena.sessions:onBattleReady({
    battle = "9", mode = "1v1", sides = { a = { "me" }, b = { "peer1" } },
  })
  local n = 0
  local function ev(fields)
    n = n + 1
    fields.battle = "9"; fields.seq = n
    arena.sessions:onBattleEvent(fields)
  end
  local function drain(limit)
    local guard = 0
    while #a.lines > 0 and guard < (limit or 900) do
      a:update(1 / 60); guard = guard + 1
    end
    return guard
  end
  local function liveVfx()
    local out = {}
    for _, e in ipairs(a.fx or {}) do
      if e.kind == "vfx" then out[#out + 1] = e end
    end
    return out
  end

  ev({ t = "send", slot = 0, text = "SQUIRTLE", hp = 30 })
  ev({ t = "send", slot = 3, text = "PIDGEY", hp = 24 })
  check(drain() < 900, "the intro queue drains in bounded frames")
  a.fx = nil

  -- ------- a move: emitted on the lunge beat, aimed at the seat opposite

  ev({ t = "anim", slot = 0, side = "a", text = "EMBER" })
  local sawMove, moveEntry = false, nil
  local guard = 0
  while #a.lines > 0 and guard < 900 do
    a:update(1 / 60); guard = guard + 1
    for _, e in ipairs(liveVfx()) do
      if not sawMove then sawMove, moveEntry = true, e end
    end
  end
  check(sawMove, "a move emits particles")
  eq(moveEntry.style, "ember", "...its type's look")
  eq(moveEntry.palette, "FIRE", "...its type's colours")
  eq(moveEntry.side, "foe", "...aimed at the seat opposite the attacker")
  eq(moveEntry.fromSide, "ally", "...and launched from the attacker's own")
  eq(a.moveVfx and a.moveVfx.palette, "FIRE",
     "the move's colours are kept for the impact burst on the beat behind it")

  -- A status move draws too. This is the case an effect gated on damage would
  -- have missed entirely -- Growl never reaches a drain row.
  a.fx = nil
  ev({ t = "anim", slot = 0, side = "a", text = "GROWL" })
  local sawStatusMove = false
  guard = 0
  while #a.lines > 0 and guard < 900 do
    a:update(1 / 60); guard = guard + 1
    if #liveVfx() > 0 then sawStatusMove = true end
  end
  check(sawStatusMove, "a move that deals no damage still draws something")

  -- ...and so does a move nobody here can name, which is the fallback the
  -- catalogue exists to guarantee.
  a.fx = nil
  ev({ t = "anim", slot = 0, side = "a", text = "A_MOVE_FROM_A_MOD" })
  local sawUnknown = false
  guard = 0
  while #a.lines > 0 and guard < 900 do
    a:update(1 / 60); guard = guard + 1
    if #liveVfx() > 0 then sawUnknown = true end
  end
  check(sawUnknown, "an unknown move draws NORMAL's impact rather than nothing")

  -- ------- an item: filed at parse, played at its turn in the queue

  a.fx = nil
  ev({ t = "item", slot = 0, side = "a", text = "POTION" })
  eq(#liveVfx(), 0,
     "an item's effect is not on screen the instant the packet arrived")
  local filed = false
  for _, row in ipairs(a.lines) do
    if type(row) == "table" and row.vfxrow then filed = true end
  end
  check(filed, "...it is filed as a row, in the referee's own order")
  guard = 0
  local sawItem = false
  while #a.lines > 0 and guard < 900 do
    a:update(1 / 60); guard = guard + 1
    for _, e in ipairs(liveVfx()) do
      if e.style == "heal" then sawItem = true end
    end
  end
  check(sawItem, "...and plays when that row comes up")

  -- A ball files nothing: the throw chain behind it already draws the arc, the
  -- rocking and the burst, and a second effect would draw the throw twice.
  a.fx = nil
  local before = #a.lines
  ev({ t = "item", slot = 0, side = "a", text = "POKE_BALL" })
  local ballRows = 0
  for _, row in ipairs(a.lines) do
    if type(row) == "table" and row.vfxrow then ballRows = ballRows + 1 end
  end
  eq(ballRows, 0, "a thrown ball files no particle row of its own")
  check(#a.lines >= before, "...and the ball chain behind it is untouched")
  check(drain() < 900, "the queue still drains")

  -- ------- a condition landing, and one lifting

  a.fx = nil
  -- The wire's own token, which is what a `status` event really carries
  -- (Wire.STATUSES: SLP / PSN / BRN / FRZ / PAR / TOX) -- not the turn
  -- machine's internal long name. The catalogue keys both.
  ev({ t = "status", slot = 3, side = "b", status = "BRN", text = "burned!" })
  local burnFiled = false
  for _, row in ipairs(a.lines) do
    if type(row) == "table" and row.vfxrow then burnFiled = true end
  end
  check(burnFiled, "a condition landing files a row")
  eq(a.slots[3] and a.slots[3].status, "BRN",
     "...and writes the chip the plate draws")
  check(drain() < 900, "...which drains")

  local cleared = #a.lines
  ev({ t = "status", slot = 3, side = "b", text = "is cured!" })
  local clearRows = 0
  for _, row in ipairs(a.lines) do
    if type(row) == "table" and row.vfxrow then clearRows = clearRows + 1 end
  end
  eq(clearRows, 0,
     "a condition lifting is a sentence rather than a sight -- no row filed")
  eq(a.slots[3] and a.slots[3].status, nil,
     "...and the chip comes off, the same way a wake or an item cure must")
  check(#a.lines >= cleared, "...and nothing else is disturbed")
  check(drain() < 900, "the queue drains")

  -- ------- the seed advances, so two casts are not the same emission

  a.fx = nil
  local seedBefore = a.vfxSeed
  ev({ t = "anim", slot = 0, side = "a", text = "EMBER" })
  check(drain() < 900, "the second cast drains")
  check(a.vfxSeed ~= seedBefore, "each emission takes its own seed")

  -- ------- and none of it happens off the arena
  --
  -- The classic 160x144 path has no renderer for a particle, so an emission
  -- there would cost the queue a row to draw nothing.
  local classic = harness("host")
  classic.game.input = fakeInput()
  classic.open("10")
  local c = classic.sessions.fight
  c.usesBattlefield = function() return false end
  classic.sessions:onBattleReady({
    battle = "10", mode = "1v1", sides = { a = { "me" }, b = { "peer1" } },
  })
  local m = 0
  local function cev(fields)
    m = m + 1
    fields.battle = "10"; fields.seq = m
    classic.sessions:onBattleEvent(fields)
  end
  cev({ t = "item", slot = 0, side = "a", text = "POTION" })
  local offArena = 0
  for _, row in ipairs(c.lines) do
    if type(row) == "table" and row.vfxrow then offArena = offArena + 1 end
  end
  eq(offArena, 0, "the classic path files no particle rows")
  eq(c:emitVfx({ style = "ember", palette = "FIRE", delivery = "burst" }, 2),
     nil, "...and emits none if asked directly")
end

-- Classic parks and queues spawnfx (no theatre ball) so a switch-and-hit
-- in one batch keeps the departing pic and the newcomer's bar starts where
-- it walked out -- the same clocks the arena uses.
--
-- Driven by the gate rather than by a generation, since round 7: Gold takes
-- the arena too (docs/plans/gen2-new-battle-system.md), so a Gen2-shaped game
-- is no longer the classic stand-in. `usesBattlefield` on the instance shadows
-- the class method, and it is the one switch every arena surface reads.
do
  local classic = setmetatable({
    game = { data = {} },
    usesBattlefield = function() return false end,
    slots = { [3] = { species = "PIDGEY", hp = 24, maxHp = 24, shownHp = 24 } },
    lines = {},
  }, { __index = Mediated })
  check(not classic:usesBattlefield(), "the gate is down on this screen")
  classic:noteSlot({ t = "send", slot = 3, text = "RATTATA", hp = 21, maxHp = 21 })
  eq(classic.slots[3].species, "PIDGEY",
     "classic parks a send into an occupied seat")
  eq(classic.slots[3].pending and classic.slots[3].pending.species, "RATTATA",
     "...the arrival waits for spawnfx")
  check(classic:queueSpawnFx(3, "b"), "classic still queues a spawnfx row")
  local spawn = nil
  for _, row in ipairs(classic.lines) do
    if type(row) == "table" and row.spawnfx ~= nil then spawn = row end
    check(not (type(row) == "table" and row.sendball ~= nil),
          "classic queues no theatre ball")
  end
  check(spawn ~= nil, "a spawnfx row is on the queue")

  classic:noteSlot({ t = "damage", slot = 3, hp = 12, amount = 9 })
  eq(classic.slots[3].hp, 24, "the departing monster's numbers stay put")
  eq(classic.slots[3].pending and classic.slots[3].pending.hp, 12,
     "the hit lands on the parked newcomer")
  eq(classic.slots[3].pending and classic.slots[3].pending.shownHp, 21,
     "...whose bar still starts where it walked out")
  check(classic:queueDrain(3), "classic queues the fall against the newcomer")
  check(classic:applySwap(spawn), "applySwap installs the arrival")
  eq(classic.slots[3].species, "RATTATA", "...on the seat")
  eq(classic.slots[3].shownHp, 21, "...bar starts at walk-out HP")
  eq(classic.slots[3].hp, 12, "...truth is already the post-hit number")
  eq(classic.slots[3].pending, nil, "...and the park is empty")
end

-- ------------------------------------------------------------------
-- 11a. status chips: inflict writes, a lift (wake / item) clears
-- ------------------------------------------------------------------
--
-- The referee says a condition is gone by sending a `status` event with no
-- token (BattleSim/Events.lua). The plate reads `slot.status`, so a client
-- that only wrote when the field was present kept SLEEP after a wake and
-- every badge after an Awakening / Full Heal / Antidote.

do
  local Battlefield = need("Battlefield")
  local screen = setmetatable({
    game = {
      data = DATA,
      save = { party = { mon("CHARMANDER", { status = "SLP" }) } },
    },
    usesBattlefield = function() return true end,
    slots = {},
    lines = {},
    mine = { { species = "CHARMANDER", status = "SLP", slot = 0 } },
    active = 1,
    mySlot = function() return 0 end,
  }, { __index = Mediated })

  screen:noteSlot({ t = "send", slot = 0, text = "CHARMANDER", hp = 30,
                    status = "SLP" })
  eq(screen.slots[0].status, "SLP", "a send that walked in asleep shows SLEEP")
  eq(Battlefield.cardModel(screen.slots[0]).status, "SLP",
     "...and the card the arena draws agrees")

  -- A send that predates carrying `status` still paints our own chip from
  -- the snapshot sheet, which is how a poisoned walk-in used to look healthy.
  local omitted = setmetatable({
    usesBattlefield = function() return true end,
    slots = {},
    lines = {},
    mine = { { species = "CHARMANDER", status = "PSN", slot = 0 } },
    active = 1,
    mySlot = function() return 0 end,
  }, { __index = Mediated })
  omitted:noteSlot({ t = "send", slot = 0, text = "CHARMANDER", hp = 30 })
  omitted:arriveOnSeat(0, true)
  eq(omitted.slots[0].status, "PSN",
     "a send that named no condition still takes the chip off our own sheet")
  eq(Battlefield.cardModel(omitted.slots[0]).status, "PSN",
     "...and the card agrees")

  screen:noteSlot({ t = "status", slot = 0, text = "CHARMANDER woke up" })
  screen:syncMineStatus({ t = "status", slot = 0, text = "CHARMANDER woke up" })
  eq(screen.slots[0].status, nil, "a wake with no token takes the chip off")
  eq(Battlefield.cardModel(screen.slots[0]).status, nil, "...the card too")
  eq(screen.mine[1].status, nil, "...and the fight sheet")
  eq(screen.game.save.party[1].status, nil, "...and the save mon behind it")

  -- Confusion is a volatile, not a standing token: it must not occupy
  -- `slot.status` (a mon can be PSN and confused) and a snap-out must not
  -- wipe the save.
  screen:noteSlot({ t = "status", slot = 0, status = "PSN", text = "poisoned" })
  screen:syncMineStatus({ t = "status", slot = 0, status = "PSN",
                          text = "poisoned" })
  screen:noteSlot({ t = "status", slot = 0, confused = 1,
                    text = "CHARMANDER became confused" })
  eq(screen.slots[0].status, "PSN", "confuse does not clear standing poison")
  eq(screen.slots[0].confused, true, "...and the CNF chip lights")
  eq(Battlefield.cardModel(screen.slots[0]).confused, true,
     "...and the card the arena draws agrees")
  eq(screen.game.save.party[1].status, "PSN", "...the save is still poisoned")
  screen:noteSlot({ t = "status", slot = 0, confused = 0,
                    text = "CHARMANDER snapped out of confusion" })
  screen:syncMineStatus({ t = "status", slot = 0, confused = 0,
                          text = "CHARMANDER snapped out of confusion" })
  eq(screen.slots[0].confused, nil, "snap-out takes the CNF chip off")
  eq(screen.slots[0].status, "PSN", "...and leaves poison")
  eq(screen.game.save.party[1].status, "PSN", "...and the save")

  -- Walk-in on a fresh seat: a send against an occupied battlefield seat
  -- parks the arrival, so this is its own stub.
  local dazed = setmetatable({
    usesBattlefield = function() return true end,
    slots = {},
    lines = {},
    mine = { { species = "CHARMANDER", slot = 0 } },
    active = 1,
    mySlot = function() return 0 end,
  }, { __index = Mediated })
  dazed:noteSlot({ t = "send", slot = 0, text = "CHARMANDER", hp = 30,
                   confused = 1, status = "SLP" })
  eq(dazed.slots[0].confused, true, "a send that walked in confused shows CNF")
  eq(dazed.slots[0].status, "SLP", "...beside the standing sleep")
  eq(Battlefield.cardModel(dazed.slots[0]).confused, true,
     "...and the card agrees")

  -- Every other standing condition, the way an item cure arrives.
  for _, token in ipairs({ "PSN", "BRN", "FRZ", "PAR", "TOX" }) do
    screen:noteSlot({ t = "status", slot = 0, status = token,
                      text = "was afflicted" })
    eq(screen.slots[0].status, token, token .. " lands on the chip")
    screen:noteSlot({ t = "status", slot = 0, text = "recovered" })
    eq(screen.slots[0].status, nil, "...and an item cure clears " .. token)
  end

  -- A residual `damage` names the status that dealt it; it must not be
  -- readable as a lift, and a damage that names none must not wipe the chip.
  screen:noteSlot({ t = "status", slot = 0, status = "BRN", text = "burned" })
  screen:noteSlot({ t = "damage", slot = 0, hp = 28 })
  eq(screen.slots[0].status, "BRN",
     "a hit that did not mention a condition leaves the chip")
  screen:noteSlot({ t = "damage", slot = 0, hp = 24, status = "BRN" })
  eq(screen.slots[0].status, "BRN",
     "...and a residual that names it keeps it")

  -- Parked arrival: the departing monster keeps its chip; a cure in the
  -- window belongs to the newcomer.
  screen:noteSlot({ t = "send", slot = 3, text = "PIDGEY", hp = 24,
                    status = "SLP" })
  screen:noteSlot({ t = "send", slot = 3, text = "RATTATA", hp = 21,
                    status = "PSN" })
  eq(screen.slots[3].status, "SLP",
     "the departing chip stays while the arrival is parked")
  eq(screen.slots[3].pending.status, "PSN", "...the newcomer carries its own")
  screen:noteSlot({ t = "status", slot = 3, text = "recovered" })
  eq(screen.slots[3].status, "SLP",
     "a cure in the window is not the departing mon's")
  eq(screen.slots[3].pending.status, nil, "...it clears the newcomer")
end

-- ------------------------------------------------------------------
-- 11b. a nicknamed foe: the seat opposite needs an id, not a nickname
-- ------------------------------------------------------------------
--
-- Every name on this wire is the token the fight is *narrated* under, and that
-- token is the nickname when the monster has one.  So the client opposite had
-- exactly one string for a monster it has never seen a sheet of, and that
-- string matched no pokedex row: no front pic (the arena drew its placeholder
-- box), no level (the pill printed 1) and, on a faint, no base rate to price
-- the award with.  From PROTOCOL 22 the referee states the id and the level on
-- `send` / `switch`, and this is what reads them.
do
  local function seatFor(fields)
    local screen = setmetatable({
      game = { data = { pokemon = DATA.pokemon } },
      usesBattlefield = function() return false end,
      slots = {},
      lines = {},
      mine = {},
      active = 1,
    }, { __index = Mediated })
    screen:noteSlot(fields)
    return screen, screen.slots[fields.slot]
  end

  local screen, slot = seatFor({ t = "send", slot = 3, text = "MALBABISCO",
                                 speciesId = "SQUIRTLE", level = 8, hp = 24 })
  eq(slot.species, "MALBABISCO", "the seat keeps the name the fight narrates")
  eq(screen:seatSpeciesKey(slot, false), "SQUIRTLE",
     "...and resolves its art through the id the referee stated")
  eq(slot.level, 8, "...with a level for the pill to print")

  -- A referee that predates the field, and the two cases it splits into.
  local older, oldSlot = seatFor({ t = "send", slot = 3, text = "SQUIRTLE",
                                   hp = 24 })
  eq(oldSlot.speciesId, nil, "a pre-22 referee states no id")
  eq(older:seatSpeciesKey(oldSlot, false), "SQUIRTLE",
     "...and the display-name scan still answers, exactly as it always did")
  local blind, blindSlot = seatFor({ t = "send", slot = 3,
                                     text = "MALBABISCO", hp = 24 })
  eq(blind:seatSpeciesKey(blindSlot, false), nil,
     "...which is the one question a nickname could never answer")

  -- An id this build has no row for is not preferred over a name it can still
  -- resolve: a hub is free to relay a species from a copy of the game this one
  -- does not have.
  local modded, moddedSlot = seatFor({ t = "send", slot = 3, text = "SQUIRTLE",
                                       speciesId = "MISSINGNO", hp = 24 })
  eq(modded:seatSpeciesKey(moddedSlot, false), "SQUIRTLE",
     "an id with no pokedex row falls through to the name")

  -- And the seat changing hands takes both fields with it: the previous
  -- occupant's id left standing would draw the monster that just walked off.
  -- Classic parks until `spawnfx` (`applySwap`); the departing id stays on
  -- the seat until then, then both fields go with the swap.
  screen:noteSlot({ t = "send", slot = 3, text = "CHARMANDER", hp = 30 })
  eq(screen.slots[3].species, "MALBABISCO",
     "classic parks; the departing id stays on the seat")
  eq(screen.slots[3].pending and screen.slots[3].pending.species, "CHARMANDER",
     "...the newcomer waits behind it")
  check(screen:queueSpawnFx(3, "b"), "classic queues the reveal")
  local spawn
  for _, row in ipairs(screen.lines) do
    if type(row) == "table" and row.spawnfx ~= nil then spawn = row end
  end
  check(screen:applySwap(spawn), "applySwap hands the seat over")
  eq(screen.slots[3].speciesId, nil, "a send with no id clears the last one")
  eq(screen.slots[3].level, nil, "...and the level that went with it")
  eq(screen:seatSpeciesKey(screen.slots[3], false), "CHARMANDER",
     "...leaving the newcomer's own name to answer")
end

-- ------------------------------------------------------------------
-- 12. the replace phase: `turn` with a `slot` is a solicitation
-- ------------------------------------------------------------------
--
-- The referee no longer auto-advances a turn when a fighter faints with a
-- living bench mon.  It emits `turn{amount, slot}` first -- a solicitation
-- naming the seat that owes a send-out -- and only then the ordinary slot-less
-- `turn` that opens the choice window.  Three different answers are owed:
--
--   * the seat is ours -> the switch picker, uncancellable, and never the
--     command grid first: a grid over a corpse is a turn nobody can take;
--   * the seat is the foe's -> no menu at all, and a held
--     "X is choosing who to send out..." queued *behind* the faint's own sink
--     and sentence, so the hold does not overwrite the death it explains;
--   * no `slot` -> exactly what an older referee always got.
do
  -- A fresh fight with both seats sent out, which is the state every case
  -- below starts from.  Built through the real Sessions path rather than by
  -- hand, so the screen under test is the one the game pushes.
  local function newFight()
    local play = harness("host")
    play.game.input = fakeInput()
    play.open()
    local f = play.sessions.fight
    play.sessions:onBattleReady({
      battle = "7", mode = "1v1", sides = { a = { "me" }, b = { "peer1" } },
    })
    local function ev(fields)
      fields.battle = "7"
      play.sessions:onBattleEvent(fields)
    end
    ev({ seq = 1, t = "send", slot = 0, text = "SQUIRTLE", hp = 30 })
    ev({ seq = 2, t = "send", slot = 3, text = "PIDGEY", hp = 24 })
    return f, ev, play
  end

  -- Run the narration out and then let update() act on whatever the queue was
  -- holding: every menu assertion below is about what opens *after* the lines
  -- have played, which is the whole of the change.
  local function drainLines(f, guard)
    local n = 0
    while (f.shown ~= nil or #f.lines > 0) and n < (guard or 400) do
      f:update(2.0)
      n = n + 1
    end
    for _ = 1, 4 do f:update(2.0) end
    return n
  end

  local function queued(f, needle)
    if type(f.shown) == "string" and f.shown:find(needle, 1, true) then
      return true
    end
    for _, row in ipairs(f.lines) do
      if type(row) == "string" and row:find(needle, 1, true) then return true end
    end
    return false
  end

  -- (a) our OWN knockout: turn{slot = mySlot} opens the picker, never the grid.
  do
    local f, ev = newFight()
    local active = f.active
    f.mine[active].hp = 0
    for i, m in ipairs(f.mine) do
      if i ~= active and (m.hp or 0) <= 0 then m.hp = 10 end
    end
    ev({ seq = 3, t = "faint", slot = 0, text = "SQUIRTLE", amount = 1 })
    ev({ seq = 4, t = "turn", amount = 2, slot = 0 })
    eq(f.replaceWait, 0, "the solicitation names our own seat")
    eq(f.mustReplace, true, "mustReplace is armed")
    check(f.phase ~= "switch",
          "and the picker waits for the faint narration (phase="
          .. tostring(f.phase) .. ")")
    drainLines(f)
    eq(f.phase, "switch", "then the picker opens -- not the command grid")
    eq(f.replaceOnly, true, "and it cannot be cancelled")
    ev({ seq = 5, t = "send", slot = 0, text = "CHARMANDER", hp = 40 })
    check(not f.mustReplace, "the send clears mustReplace")
    eq(f.replaceWait, nil, "and the solicitation with it")
    drainLines(f)
    ev({ seq = 6, t = "turn", amount = 2 })
    drainLines(f)
    eq(f.phase, "choose", "the slot-less turn behind it opens the grid")
  end

  -- (b) the FOE's knockout: a held line, no menu at all, until the send lands.
  do
    local f, ev = newFight()
    ev({ seq = 3, t = "faint", slot = 3, text = "PIDGEY", amount = 1 })
    ev({ seq = 4, t = "turn", amount = 2, slot = 3 })
    eq(f.replaceWait, 3, "the solicitation names the foe's seat")
    eq(f.pendingTurn, false, "no turn is pending: this is not a choice window")
    eq(f.mustReplace, false, "and our own picker is untouched")
    check(queued(f, "choosing"),
          "'X is choosing who to send out...' is queued")

    -- The chronology is the whole point: the sink, "PIDGEY fainted!", and only
    -- then the hold -- a hold that landed first would erase the death it is
    -- explaining.
    local iFaint, iSink, iHold
    for i, row in ipairs(f.lines) do
      if type(row) == "string" and row:find("fainted", 1, true) then
        iFaint = iFaint or i
      end
      if type(row) == "table" and row.faintfx ~= nil then iSink = iSink or i end
      if type(row) == "string" and row:find("choosing", 1, true) then
        iHold = iHold or i
      end
    end
    check(iSink and iFaint and iHold and iSink < iFaint and iFaint < iHold,
          ("...behind the faint's sink and its sentence (sink=%s faint=%s "
           .. "hold=%s of %d)"):format(tostring(iSink), tostring(iFaint),
                                       tostring(iHold), #f.lines))

    drainLines(f)
    eq(f.phase, "play", "no menu opens for somebody else's replacement")
    check(f:holdLine():find("choosing", 1, true) ~= nil,
          "and the band holds the line: " .. f:holdLine():gsub("\n", "|"))
    ev({ seq = 5, t = "send", slot = 3, text = "RATTATA", hp = 20 })
    eq(f.replaceWait, nil, "the send ends the hold")
    check(f:holdLine():find("Waiting for", 1, true) ~= nil,
          "and the band goes back to the ordinary wait: "
          .. f:holdLine():gsub("\n", "|"))
    drainLines(f)
    eq(f.phase, "play", "still no menu until a turn opens")
    ev({ seq = 6, t = "turn", amount = 2 })
    drainLines(f)
    eq(f.phase, "choose", "and the slot-less turn opens the grid")
    eq(f.slots[3].species, "RATTATA", "with the foe seat filled")
  end

  -- (c) an empty bench: a solicitation we cannot answer opens nothing.
  do
    local f, ev = newFight()
    for _, m in ipairs(f.mine) do m.hp = 0 end
    ev({ seq = 3, t = "faint", slot = 0, text = "SQUIRTLE" })
    ev({ seq = 4, t = "turn", amount = 2, slot = 0 })
    eq(f.mustReplace, false, "no dead picker on an empty bench")
    eq(f.pendingTurn, false, "...and no turn pending behind it")
    eq(f.replaceWait, nil, "and no hold left standing")
    drainLines(f)
    check(f.phase ~= "switch" and f.phase ~= "choose",
          "no menu opened (phase=" .. tostring(f.phase) .. ")")
  end

  -- (d) an older referee, which never puts a `slot` on a `turn`.
  do
    local f, ev = newFight()
    ev({ seq = 3, t = "damage", slot = 3, hp = 10 })
    ev({ seq = 4, t = "turn", amount = 2 })
    eq(f.pendingTurn, true, "a slot-less turn is still a turn")
    eq(f.replaceWait, nil, "and records no replace phase")
    drainLines(f)
    eq(f.phase, "choose", "opening the grid exactly as it always did")

    -- ...and the old faint -> slot-less turn -> picker chronology is untouched.
    local g, gev = newFight()
    local active = g.active
    g.mine[active].hp = 0
    for i, m in ipairs(g.mine) do
      if i ~= active and (m.hp or 0) <= 0 then m.hp = 10 end
    end
    gev({ seq = 3, t = "faint", slot = 0, text = "SQUIRTLE", amount = 1 })
    gev({ seq = 4, t = "turn", amount = 2 })
    drainLines(g)
    eq(g.phase, "switch",
       "an old stream's faint still opens the picker on the next turn")
    eq(g.replaceOnly, true, "...still uncancellable")
  end

  -- (e) teardown: a hold is display state, so anything that snaps the display
  -- drops it.  A hold that outlived the fight would band a finished screen.
  do
    local f, ev = newFight()
    ev({ seq = 3, t = "faint", slot = 3, text = "PIDGEY", amount = 1 })
    ev({ seq = 4, t = "turn", amount = 2, slot = 3 })
    eq(f.replaceWait, 3, "the hold is up")
    f:snapDisplay()
    eq(f.replaceWait, nil, "and snapDisplay drops it")

    local g, gev = newFight()
    gev({ seq = 3, t = "faint", slot = 3, text = "PIDGEY", amount = 1 })
    gev({ seq = 4, t = "turn", amount = 2, slot = 3 })
    gev({ seq = 5, t = "over", text = "ko" })
    eq(g.replaceWait, nil, "and so does `over`")
  end

  -- (f) the joint run: the real referee's stream, replayed into the real
  -- screen.  No hand-built events -- src/BattleSim/Turn.lua emits and
  -- MediatedBattle reads -- and the "no grid over an empty seat" invariant is
  -- checked on every frame the loop pumps.
  do
    local BattleSim = need("BattleSim/init")
    local Turn = BattleSim.Turn

    local function rmove()
      return { id = "thump", pp = 20, power = 200, accuracy = 255,
               type = 0, effect = 0, chance = 0 }
    end
    local function rmon(species, hp)
      return { species = species, level = 20, hp = hp, maxHp = 60,
               stats = { atk = 90, def = 5, spd = 40, spc = 40 },
               moves = { rmove() } }
    end

    local battle = assert(Turn.create({
      id = "7", mode = "1v1", seed = 4242, choiceTimeout = 60,
      reconnectGrace = 60,
      sides = {
        a = { { playerId = "me", name = "ME",
                mons = { rmon("SQUIRTLE", 1), rmon("CHARMANDER", 60) } } },
        b = { { playerId = "peer1", name = "BOB",
                mons = { rmon("PIDGEY", 1), rmon("RATTATA", 60) } } },
      },
    }))

    local play = harness("host")
    play.game.input = fakeInput()
    play.open()
    local f = play.sessions.fight
    play.sessions:onBattleReady({
      battle = "7", mode = "1v1", sides = { a = { "me" }, b = { "peer1" } },
    })

    local violations = {}
    local seenReplaceTurn, seenSlotlessTurn = 0, 0
    local function pump()
      for _, e in ipairs(battle:drainEvents()) do
        if e.t == "turn" then
          if e.slot ~= nil then seenReplaceTurn = seenReplaceTurn + 1
          else seenSlotlessTurn = seenSlotlessTurn + 1 end
        end
        play.sessions:onBattleEvent(e)
      end
      for _ = 1, 200 do
        f:update(2.0)
        if f.phase == "choose" then
          if f.replaceWait ~= nil then
            violations[#violations + 1] = "grid open while slot "
              .. tostring(f.replaceWait) .. " still owes a send-out"
          end
          if (f.slots[0] or {}).hp ~= nil and f.slots[0].hp <= 0 then
            violations[#violations + 1] = "grid open over our own KO'd seat"
          end
          if (f.slots[3] or {}).hp ~= nil and f.slots[3].hp <= 0 then
            violations[#violations + 1] = "grid open over the foe's KO'd seat"
          end
          break
        end
        if f.phase == "switch" then break end
      end
    end

    pump()
    local guard = 0
    while not battle.finished and guard < 12 do
      guard = guard + 1
      local snap = battle:snapshot()
      if snap.phase == "choice" then
        check(f.phase == "choose" or f.phase == "play",
              ("the referee's choice window is what the screen has open "
               .. "(round %d, phase=%s)"):format(guard, tostring(f.phase)))
        battle:submitChoice("me", { action = "fight", move = 0 })
        battle:submitChoice("peer1", { action = "fight", move = 0 })
      elseif snap.phase == "replace" then
        check(f.phase ~= "choose",
              ("no command grid during the referee's replace phase (round %d, "
               .. "phase=%s)"):format(guard, tostring(f.phase)))
        if f.mustReplace then
          eq(f.phase, "switch",
             ("our own solicitation is a picker (round %d)"):format(guard))
        end
        battle:submitChoice("me", { action = "switch", slot = 1 })
        battle:submitChoice("peer1", { action = "switch", slot = 1 })
      else
        break
      end
      pump()
    end

    check(seenReplaceTurn >= 2, "the referee really did open a replace phase ("
          .. seenReplaceTurn .. " solicitations)")
    check(seenSlotlessTurn >= 2, "with the ordinary choice window behind it ("
          .. seenSlotlessTurn .. " slot-less turns)")
    check(#violations == 0, "the screen never opened a grid over an empty seat: "
          .. table.concat(violations, "; "))
    eq(f.slots[0].species, "CHARMANDER",
       "our seat ended up filled by the referee's replacement")
    eq(f.slots[3].species, "RATTATA", "...and the foe's too")
  end
end

-- ------------------------------------------------------------------
-- 11c. the POKeMON panel's front pic: which copy of the monster answers
-- ------------------------------------------------------------------
--
-- The band draws the highlighted party row's monster beside the list, from the
-- arena's own art.  Two things about *where that art comes from* are worth
-- pinning, because both are silent when wrong: the SAVE mon is what is asked
-- (an uploaded sheet carries no shiny flag at all), and the cache is keyed by
-- species plus shiny rather than by the slot that asked -- a party walk goes
-- through six monsters and a slot-shaped cache would evict on every row.
do
  local screen = setmetatable({
    game = {
      data = { pokemon = DATA.pokemon },
      save = { party = {
        { species = "SQUIRTLE", level = 8 },
        { species = "SQUIRTLE", level = 9, shiny = true },
      } },
    },
    mine = {
      { species = "SQUIRTLE", hp = 24, maxHp = 24, slot = 0 },
      { species = "SQUIRTLE", hp = 26, maxHp = 26, slot = 1 },
    },
    active = 1,
    _bfPartyFronts = { SQUIRTLE = "plain-pic", ["SQUIRTLE*"] = "shiny-pic" },
  }, { __index = Mediated })

  local rows = screen:bandPartyRows(true)
  eq(#rows, 2, "the item menu lists the whole party")
  eq(rows[1].front, "plain-pic",
     "a party row carries the same front pic the arena draws for it")
  eq(rows[2].front, "shiny-pic",
     "...and the shiny one gets its own, off the SAVE mon -- the uploaded "
     .. "sheet has no flag to read")
  eq(rows[2].right, "26/26", "the HP column is unchanged by any of this")

  -- Arena plates drain shownHp; party rows used to format sheet.hp and jump.
  local draining = setmetatable({
    game = { data = { pokemon = DATA.pokemon }, save = { party = {} } },
    mine = {
      { species = "SQUIRTLE", hp = 5, maxHp = 24, slot = 0 },
      { species = "PIDGEY", hp = 20, maxHp = 20, slot = 1 },
    },
    active = 1,
    slots = {},
  }, { __index = Mediated })
  draining.slots[draining:mySlot()] = { hp = 5, maxHp = 24, shownHp = 18 }
  local drainRows = draining:bandPartyRows(true)
  eq(drainRows[1].right, "18/24",
     "the active party's HP column follows the display clock mid-drain")
  eq(drainRows[2].right, "20/20",
     "...and a benched mon still prints its own truth hp")
  local pickerRows = draining:classicPickerRows(true)
  eq(pickerRows[1].hp, 18,
     "the classic picker preview uses the same clock")
  eq(pickerRows[1].fainted, false,
     "faint stays on truth hp so a bar crawling to 0 is not already FNT")

  -- No save behind the sheet (a party the save no longer matches): the sheet
  -- answers instead, so the panel shows a monster rather than a hole.
  local sheetOnly = setmetatable({
    game = { data = { pokemon = DATA.pokemon }, save = { party = {} } },
    mine = { { species = "SQUIRTLE", hp = 24, maxHp = 24, slot = 0 } },
    active = 1,
    _bfPartyFronts = { SQUIRTLE = "plain-pic" },
  }, { __index = Mediated })
  eq(sheetOnly:bandPartyRows(true)[1].front, "plain-pic",
     "with no save slot behind it the uploaded sheet names the species")
end

-- ------------------------------------------------------------------
-- 14. the move list: a type column, and a cursor that remembers
-- ------------------------------------------------------------------
--
-- Two things the player asked the menu for, and both are *presentation only*:
-- the wire, the choice and the sim are untouched by either.
--
--   * every row states its own type, so four moves can be compared at once
--     rather than one at a time under the cursor;
--   * the list opens on the move this monster last actually used, because a
--     Gen 1 fight is mostly one attack repeated and walking back down to it
--     every turn is a tax on a decision already made.
do
  local function client()
    return setmetatable({
      game = { data = DATA },
      phase = "move",
      active = 1,
      cursor = 1,
      moveMemory = {},
      commandIndex = 1,
      mine = {
        { species = "CHARMANDER", moves = {
            { id = "EMBER", pp = 25, maxPp = 25 },
            { id = "GROWL", pp = 40, maxPp = 40 },
            { id = "HYDRO", pp = 5, maxPp = 5 },
        } },
        { species = "SQUIRTLE", moves = { { id = "HYDRO", pp = 5, maxPp = 5 } } },
      },
    }, { __index = Mediated })
  end

  -- ------- the type column
  local f = client()
  local rows = f:bandMoveRows()
  eq(#rows, 3, "one row per move")
  eq(rows[1].tag, "FIRE", "the type is the row's own column...")
  eq(rows[1].right, "25/25", "...and does not displace the PP beside it")
  eq(rows[2].tag, "NORMAL", "a status move states its type too")
  eq(rows[3].tag, "WATER", "...as does every other row, not just the hot one")

  -- A referee-published sheet after Transform/Mimic can name a move this copy
  -- has no record of. No record, no type: a blank column says nothing, and
  -- inventing one would say something false.
  f.mine[1].moves[3] = { id = "MYSTERY", pp = 5 }
  rows = f:bandMoveRows()
  eq(rows[3].tag, nil, "a move the dataset does not carry gets no type column")
  eq(rows[3].label, "MYSTERY", "...and still shows under its id")

  -- ------- the cursor
  local g = client()
  eq(g:rememberedMove(), 1,
     "a monster that has not attacked yet opens on its first move")

  local sent = {}
  g.sendChoice = function(_, choice) sent[#sent + 1] = choice; return true end
  check(g:pickMove(2), "the second move is sendable")
  eq(sent[1].move, 1, "the wire is still 0-based, unchanged by any of this")
  eq(g.moveMemory[1], 2, "and the move actually sent is what gets remembered")

  local input = fakeInput()
  g.phase = "choose"
  g.commandIndex = 1
  input.press("a")
  g:updateCommand(input)
  eq(g.phase, "move", "FIGHT opens the move list")
  eq(g.cursor, 2, "...on the move this monster last used, not back on row one")

  -- Per monster: the one that comes in after a switch opens on its own first
  -- move, because row 2 of its sheet is a different move entirely.
  g.active = 2
  g.phase = "choose"
  input.press("a")
  g:updateCommand(input)
  eq(g.cursor, 1, "a monster that has not attacked yet opens on row one, "
     .. "whatever the one it replaced was using")

  -- Sent is what counts. A refused send leaves the turn unspent, so moving
  -- the cursor for it would be the menu reporting a decision never taken.
  g.active = 1
  g.sendChoice = function() return false end
  check(not g:pickMove(3), "a refused send reports the refusal")
  eq(g.moveMemory[1], 2, "...and leaves the remembered move where it was")

  -- A move with no PP is refused *here*, before it hits the wire. The hub
  -- would drop it in silence, this screen would have already left the menu,
  -- and both players would wait out BATTLE_CHOICE_TIMEOUT.
  local h = client()
  h.lines = {}
  h.answeredTurn = false
  h.mine[1].moves[2].pp = 0
  h.sendChoice = function()
    error("a 0-PP move must not be sent")
  end
  check(not h:pickMove(2), "a move with no PP is not sent")
  eq(h.phase, "move", "the menu stays open")
  eq(h.answeredTurn, false, "the turn is not spent")
  check(h.lines[1] and h.lines[1]:find("PP", 1, true),
        "and the player is told why")

  -- Every slot empty is Struggle: any index is legal and still goes.
  local struggleSent = {}
  h.mine[1].moves[1].pp = 0
  h.mine[1].moves[3].pp = 0
  h.sendChoice = function(_, choice)
    struggleSent[#struggleSent + 1] = choice
    return true
  end
  check(h:pickMove(1), "every slot empty is Struggle and still sends")
  eq(struggleSent[1] and struggleSent[1].move, 0, "...as slot 0")

  -- The sheet it has *now* is what the memory is clamped against: Transform
  -- and Mimic rewrite one mid-fight, and a cursor past the end opens on a row
  -- that is not drawn.
  g.moveMemory[1] = 9
  eq(g:rememberedMove(), 1,
     "a remembered row past the end of the current sheet falls back to one")

  -- Referee PP spend used to leave the upload snapshot on the menu: the hub
  -- locked a 0-PP move, but FIGHT still printed the number from start().
  local pp = client()
  pp.battle = "b1"
  pp.seq = 0
  pp.phase = "move"
  eq(pp:bandMoveRows()[1].right, "25/25", "the upload is what FIGHT opens on")
  pp:onEvent({
    battle = "b1", seq = 1, t = "moves", slot = 0, mon = 0,
    moves = {
      { id = "EMBER", pp = 24, maxPp = 25 },
      { id = "GROWL", pp = 40, maxPp = 40 },
      { id = "HYDRO", pp = 5, maxPp = 5 },
    },
  })
  eq(pp:bandMoveRows()[1].right, "24/25",
     "a same-ids moves event ticks the PP the menu draws")
  eq(pp.mine[1].moves[1].pp, 24,
     "...on the uploaded sheet, so a switch does not restore the old number")
  eq(pp.liveMoves, nil,
     "and is not a Transform overlay -- the real sheet is what changed")

  -- Same ids, no `mon`: Transform into a mirror set must not write mine[].
  local mirror = client()
  mirror.battle = "b1"
  mirror.seq = 0
  mirror:onEvent({
    battle = "b1", seq = 1, t = "moves", slot = 0,
    moves = {
      { id = "EMBER", pp = 3, maxPp = 25 },
      { id = "GROWL", pp = 40, maxPp = 40 },
      { id = "HYDRO", pp = 5, maxPp = 5 },
    },
  })
  eq(mirror.mine[1].moves[1].pp, 25,
     "Transform without mon leaves the real sheet's PP alone")
  eq(mirror.liveMoves[1].pp, 3, "...and overlays the copied count")

  -- Transform still overlays: different ids must not be written onto mine.
  pp:onEvent({
    battle = "b1", seq = 2, t = "moves", slot = 0,
    moves = {
      { id = "TACKLE", pp = 10, maxPp = 35 },
    },
  })
  eq(pp.mine[1].moves[1].id, "EMBER",
     "a rewritten list leaves the real sheet alone")
  eq(pp.liveMoves[1].id, "TACKLE", "...and is what FIGHT reads until a send")
  eq(pp:bandMoveRows()[1].right, "10/35",
     "...including the live PP of the copied move")
end

-- ------------------------------------------------------------------
-- 14b. RUN: trainer refuses locally; 1v1 / coop_pvp concede without the lie
-- ------------------------------------------------------------------
--
-- The command used to print the trainer sentence and then file `run` for every
-- non-wild mode, so a 1v1 concession read as a gym refusal. Trainer (coop_npc)
-- still says it and does not file; 1v1 / coop_pvp file a concession and do not
-- pretend there is a trainer.

local function saidTrainerRun(fight)
  for _, row in ipairs(fight.lines or {}) do
    local text = type(row) == "string" and row
      or (type(row) == "table" and row.text)
    if type(text) == "string" and text:lower():find("running", 1, true) then
      return true
    end
  end
  return false
end

do
  eq(Mediated.COMMANDS[4], "RUN", "the fourth command is RUN")

  local function pressRun(mode)
    local sent = {}
    local fight = setmetatable({
      game = { data = DATA },
      mode = mode,
      phase = "choose",
      commandIndex = 4,
      lines = {},
      answeredTurn = false,
      sendChoice = function(_, choice)
        sent[#sent + 1] = choice
        return true
      end,
    }, { __index = Mediated })
    local input = fakeInput()
    input.press("a")
    fight:updateCommand(input)
    return fight, sent
  end

  local pvp, pvpSent = pressRun("1v1")
  eq(#pvpSent, 1, "1v1 RUN is filed")
  eq(pvpSent[1] and pvpSent[1].action, "run", "...as a concession")
  check(not saidTrainerRun(pvp),
        "and does not pretend a 1v1 is a trainer battle")

  local ranked, rankedSent = pressRun("coop_pvp")
  eq(#rankedSent, 1, "coop_pvp RUN is filed too")
  eq(rankedSent[1] and rankedSent[1].action, "run", "...as a concession")
  check(not saidTrainerRun(ranked),
        "and does not use the trainer line for a player fight")

  local npc, npcSent = pressRun("coop_npc")
  eq(#npcSent, 0, "trainer RUN is not filed")
  check(saidTrainerRun(npc),
        "the screen says there is no running from a trainer battle")
end

-- ------------------------------------------------------------------
-- 15. who is standing on the foe edge of the arena
-- ------------------------------------------------------------------
--
-- `Battlefield.drawHuman` falls back to a dark placeholder rectangle for a
-- human that names no walk sheet, and that is what a **solo trainer fight**
-- drew for its whole length: `battlefieldCtx` folds every non-wild shape into
-- "1v1" for the arena's geometry, and the foe-human arm was reading that same
-- folded value -- so a `coop_npc` fight was described as a peer battle and
-- asked the roster for a sprite belonging to a player who does not exist.
--
-- The trainer arm has to be tested *ahead* of the peer arm for exactly that
-- reason, and the walk-sheet resolution under it is `Gen.trainerWalkSpriteId`,
-- which co-op has always used and which now has one home rather than two.
do
  -- Red has SPRITE_YOUNGSTER and no SPRITE_LASS, which is the shape that makes
  -- all three rungs of the ladder reachable in one fixture.
  local SPRITES = {
    SPRITE_YOUNGSTER     = { frames = 4 },
    SPRITE_COOLTRAINER_F = { frames = 4 },
    SPRITE_COOLTRAINER_M = { frames = 4 },
  }
  local ARENA = {
    pokemon = DATA.pokemon,
    sprites = SPRITES,
    -- Two objects fight as LASS drawn with the cooltrainer sheet and one with
    -- the youngster sheet, so the vote has a winner rather than a tie.
    maps = {
      ROUTE_3 = { objects = {
        { trainerClass = "OPP_LASS", sprite = "SPRITE_COOLTRAINER_F" },
        { trainerClass = "OPP_LASS", sprite = "SPRITE_YOUNGSTER" },
      } },
      ROUTE_4 = { objects = {
        { trainerClass = "OPP_LASS", sprite = "SPRITE_COOLTRAINER_F" },
      } },
    },
  }
  local game = {
    data = ARENA,
    save = { party = {}, player = { name = "ANN" } },
  }

  -- ------- the resolver itself
  eq(Gen.trainerWalkSpriteId({ id = "OPP_YOUNGSTER" }, game), "SPRITE_YOUNGSTER",
     "OPP_YOUNGSTER walks around as SPRITE_YOUNGSTER, by the name transform")
  eq(Gen.trainerWalkSpriteId({ id = "OPP_LASS" }, game), "SPRITE_COOLTRAINER_F",
     "a class with no sheet of its own takes the one the overworld votes for")
  eq(Gen.trainerWalkSpriteId({ id = "OPP_NOBODY" }, game), "SPRITE_COOLTRAINER_M",
     "...and a class nobody walks around as still gets a body, not an empty edge")
  eq(Gen.trainerWalkSpriteId(nil, game), nil, "no trainer names no sheet")
  eq(Gen.trainerWalkSpriteId({}, game), nil, "...nor does a record with no id")

  -- ------- and what the arena is told
  local function screen(fields)
    local self = setmetatable({
      game = game,
      slots = {}, lines = {}, mine = {},
      active = 1, mySide = "a", phase = "play",
      commandIndex = 1, frame = 1,
    }, { __index = Mediated })
    for k, v in pairs(fields) do self[k] = v end
    return self
  end

  local npc = screen({
    mode = "coop_npc",
    peerName = "LASS",
    trainer = { id = "OPP_LASS", name = "LASS" },
  }):battlefieldCtx()
  eq(#npc.foeHumans, 1, "a solo trainer fight stands one figure on the foe edge")
  eq(npc.foeHumans[1].spriteId, "SPRITE_COOLTRAINER_F",
     "...with the trainer's own walk sheet, not a placeholder silhouette")
  eq(npc.foeHumans[1].name, "LASS", "...named as the trainer")
  eq(npc.foeHumans[1].id, "OPP_LASS", "...and identified by their class")

  -- The entry is unconditional, exactly as CoopBattle builds it: a trainer
  -- whose sheet cannot be named is still a trainer standing there, and the
  -- silhouette is a better answer than an empty edge.
  local nameless = screen({
    mode = "coop_npc", peerId = "npc", peerName = "BUG CATCHER",
  }):battlefieldCtx()
  eq(#nameless.foeHumans, 1,
     "a trainer record that never arrived still puts somebody on the edge")
  eq(nameless.foeHumans[1].spriteId, nil, "...with no sheet to name")
  eq(nameless.foeHumans[1].name, "BUG CATCHER",
     "...still named from the fight, never as an absent FRIEND")

  local wild = screen({ mode = "wild", peerName = "WILD" }):battlefieldCtx()
  eq(#wild.foeHumans, 0, "a wild fight leaves the foe edge empty")

  -- The peer arm, unchanged: an ordinary MMO 1v1 is still drawn from the
  -- roster, and nothing above may have moved it.
  local peer = screen({
    mode = "1v1", peerId = "peer1", peerName = "BOB",
  }):battlefieldCtx()
  eq(#peer.foeHumans, 1, "an MMO 1v1 still stands the peer on the foe edge")
  eq(peer.foeHumans[1].id, "peer1", "...identified by their player id")
  eq(peer.foeHumans[1].name, "BOB", "...and named from the roster")

  -- ------- the roster chip's party (PROTOCOL 24)
  --
  -- A `team` event is the only thing this screen is ever told about a monster
  -- that is not on the field, and the only source there is for the seat
  -- opposite: no client uploads a party to any other client.

  -- Our own side falls back to the sheets we uploaded, so a PROTOCOL 22
  -- referee that emits no `team` at all still fills the player's own row
  -- rather than leaving both sides blank.
  local ownFallback = screen({
    mode = "1v1", peerId = "peer1", peerName = "BOB",
    mine = { { species = "A", hp = 20 }, { species = "B", hp = 0 } },
  }):battlefieldCtx()
  eq(ownFallback.allyHumans[1].party and #ownFallback.allyHumans[1].party, 2,
     "with no team event the player's own chip reads the uploaded sheets")
  eq(ownFallback.foeHumans[1].party, nil,
     "...and the peer's stays empty, because there is nothing honest to put in it")

  -- With the referee talking, both sides come off the referee -- including our
  -- own, which is the seat where the two could disagree and the referee is the
  -- one that has been fighting with the sheets.
  local told = screen({
    mode = "1v1", peerId = "peer1", peerName = "BOB",
    mine = { { species = "A", hp = 20 }, { species = "B", hp = 0 } },
    teams = { [0] = "ooxs", [3] = "ox" },
  }):battlefieldCtx()
  eq(told.allyHumans[1].party, "ooxs",
     "the referee's roster wins over the uploaded sheets on our own seat")
  eq(told.foeHumans[1].party, "ox",
     "and the peer's roster is drawn from the only source there is")

  -- The solo trainer path runs the same referee over a table transport, so an
  -- NPC's ball row arrives exactly as a stranger's does.
  local solo = screen({
    mode = "coop_npc", peerName = "LASS",
    trainer = { id = "OPP_LASS", name = "LASS" },
    teams = { [3] = "ooo" },
  }):battlefieldCtx()
  eq(solo.foeHumans[1].party, "ooo",
     "a solo trainer's roster comes off the same event a peer's does")

  -- A wild fight has no foe human at all, so there is nothing to hang a roster
  -- on even if the referee published one for the seat.
  local wildTeam = screen({
    mode = "wild", peerName = "WILD",
    mine = { { species = "A", hp = 20 } },
    teams = { [0] = "o", [3] = "o" },
  }):battlefieldCtx()
  eq(#wildTeam.foeHumans, 0, "a wild fight still has nobody to put a chip under")
  eq(wildTeam.allyHumans[1].party, "o",
     "...while the player's own roster is published as it is in any other fight")
end

-- ------- the `team` event reaches `teams` and nothing else
--
-- Stored raw and read by the arena alone: it is a chip, never a rule. A screen
-- that let a roster decide `mustReplace` would be taking a rule off a field the
-- referee sends for drawing.
do
  local screen = setmetatable({
    battle = "b1", seq = 0, gaps = 0, phase = "play",
    slots = {}, lines = {}, teams = {}, mine = {}, active = 1, mySide = "a",
  }, { __index = Mediated })

  screen:onEvent({ battle = "b1", seq = 1, t = "team", slot = 0, team = "oox" })
  screen:onEvent({ battle = "b1", seq = 2, t = "team", slot = 3, team = "x" })
  eq(screen.teams[0], "oox", "a team event lands on the seat it names")
  eq(screen.teams[3], "x", "...on either side")
  eq(screen.mustReplace, nil, "and decides nothing about whose turn it is")

  screen:onEvent({ battle = "b1", seq = 3, t = "team", slot = 0, team = "oxx" })
  eq(screen.teams[0], "oxx", "a later roster replaces the one before it")

  -- Wire drops a malformed roster off the event rather than trimming it (a
  -- short roster is a different party), so what reaches here is a `team` with
  -- no `team` field -- which must leave the last good one standing.
  screen:onEvent({ battle = "b1", seq = 4, t = "team", slot = 0 })
  eq(screen.teams[0], "oxx",
     "a team event whose roster was dropped at the boundary changes nothing")
end

-- ------------------------------------------------------------------
-- 15. what the bar is out of: `maxHp` on a send (PROTOCOL 24)
-- ------------------------------------------------------------------
--
-- Every other reading of HP on this wire is a *current* number, so a client
-- had no handle on a seat's maximum at all and took the largest HP it had ever
-- seen there for it. That is right for a monster sent out whole and wrong for
-- every one that is not: a party mon that ended the last fight on 42 of 200
-- opened the next one with a **full** bar over the number 42, and stayed that
-- way for the whole fight, because nothing later ever raises the guess.
--
-- The referee has held the real maximum since it built the battler, so from
-- PROTOCOL 24 it states it -- on the `send` a monster walks out on, and on the
-- `drain` an HP UP produces, which is the one thing mid-fight that moves the
-- ceiling itself. The guess stays behind as the fallback for a stream that
-- states none, which is what the seat below with no `maxHp` still asserts.

do
  local Battlefield = need("Battlefield")
  local hurt = harness("host")
  hurt.game.input = fakeInput()
  hurt.open()
  local h = hurt.sessions.fight
  hurt.sessions:onBattleReady({
    battle = "7", mode = "1v1", sides = { a = { "me" }, b = { "peer1" } },
  })
  local n = 0
  local function ev(fields)
    n = n + 1
    fields.battle = "7"; fields.seq = n
    hurt.sessions:onBattleEvent(fields)
  end
  -- A send into an occupied seat is parked behind the queue it arrives with
  -- (section 11), so every leg below plays its rows out before it reads the
  -- seat -- otherwise it would be asserting against the previous occupant.
  local function settle()
    local guard = 0
    while #h.lines > 0 and guard < 900 do
      h:update(1 / 60); guard = guard + 1
    end
    return guard < 900
  end

  -- Our own monster, walking out on 42 of the 200 it has: the reported bug.
  ev({ t = "send", slot = 0, text = "SQUIRTLE", hp = 42, maxHp = 200 })
  eq(h.slots[0].hp, 42, "the send still sets the current HP")
  eq(h.slots[0].maxHp, 200, "and the referee's maximum is what it is out of")
  eq(h.slots[0].shownHp, 42, "the display clock starts where the referee is")
  local plate = Battlefield.plateModel({
    hp = h.slots[0].hp, shownHp = h.slots[0].shownHp,
    maxHp = h.slots[0].maxHp, side = "ally",
  })
  eq(plate.frac, 42 / 200, "so the plate draws a fifth of a bar, not a full one")
  eq(("%d/%d"):format(plate.shownHp, plate.maxHp), "42/200",
     "...over the pair of numbers the ally plate prints")

  -- With none stated, the older reading of this wire is still what happens.
  ev({ t = "send", slot = 3, text = "PIDGEY", hp = 24 })
  check(settle(), "the intro queue drains in bounded frames")
  eq(h.slots[3].maxHp, 24,
     "a stream that states no maximum falls back to the largest HP seen")

  -- A maximum under the HP arriving with it is a stream disagreeing with
  -- itself; the bar still has to be a fraction, never past its own end.
  ev({ t = "send", slot = 3, text = "PIDGEY", hp = 30, maxHp = 10 })
  check(settle(), "the swap queue drains in bounded frames")
  eq(h.slots[3].maxHp, 30, "an under-stated maximum is lifted to the HP")

  -- An HP UP moves the ceiling, and says so on the drain that announces it.
  ev({ t = "send", slot = 3, text = "PIDGEY", hp = 100, maxHp = 200 })
  check(settle(), "...and so does the one behind it")
  ev({ t = "drain", slot = 3, amount = 2, hp = 102, maxHp = 202 })
  eq(h.slots[3].hp, 102, "the rise lands")
  eq(h.slots[3].maxHp, 202, "...and the ceiling it moved lands with it")

  -- And through the arrival window: a send into an occupied seat is parked,
  -- so its maximum has to be parked with it and installed at the swap -- the
  -- bar underneath is still the departing monster's, drawn against theirs.
  local before = h.slots[3].maxHp
  ev({ t = "damage", slot = 3, hp = 0, amount = 102 })
  ev({ t = "faint", slot = 3, text = "PIDGEY" })
  ev({ t = "send", slot = 3, text = "RATTATA", hp = 9, maxHp = 60 })
  eq(h.slots[3].maxHp, before,
     "the seat keeps the falling monster's ceiling while the arrival is parked")
  eq(h.slots[3].pending and h.slots[3].pending.maxHp, 60,
     "...and the newcomer's rides on the park")
  check(settle(), "the batched queue drains in bounded frames")
  eq(h.slots[3].species, "RATTATA", "the seat changes hands at the swap")
  eq(h.slots[3].maxHp, 60, "...and takes the ceiling that was parked with it")
end

-- ------------------------------------------------------------------
-- 1v1 RUN is a forfeit, not a trainer refusal
-- ------------------------------------------------------------------
--
-- The command menu used to print the vanilla trainer line for every non-wild
-- fight and then send `{action=run}` anyway. In 1v1 that send is a concession
-- and ends the match, so the refuse copy made players think the turn was
-- wasted. Wild flees with no extra line. NPC prints the trainer refuse
-- line and does not file run. 1v1 says it forfeited only if the send landed.

do
  local function runClient(mode)
    local sent = {}
    local fight = setmetatable({
      mode = mode,
      phase = "choose",
      commandIndex = 4,
      lines = {},
    }, { __index = Mediated })
    fight.sendChoice = function(_, fields)
      sent[#sent + 1] = fields
      return true
    end
    return fight, sent
  end

  local function pressRun(fight)
    local input = fakeInput()
    input.press("a")
    fight:updateCommand(input)
  end

  eq(Mediated.COMMANDS[4], "RUN", "the fourth command is RUN")

  local pvp, pvpSent = runClient("1v1")
  pressRun(pvp)
  eq(pvpSent[1] and pvpSent[1].action, "run",
     "1v1 RUN still sends the concession")
  local pvpSaid = table.concat(pvp.lines or {}, "\n")
  check(pvpSaid:find("forfeit", 1, true),
        "1v1 RUN says it is a forfeit")
  check(not pvpSaid:find("trainer", 1, true),
        "and does not borrow the trainer-battle refuse line")

  local wild, wildSent = runClient("wild")
  pressRun(wild)
  eq(wildSent[1] and wildSent[1].action, "run", "wild RUN still flees")
  eq(#(wild.lines or {}), 0, "without a refuse or forfeit line")

  local npc, npcSent = runClient("coop_npc")
  pressRun(npc)
  eq(#npcSent, 0, "NPC RUN is not filed -- honest menus never send it")
  check(table.concat(npc.lines or {}, "\n"):find("trainer", 1, true),
        "and the screen still says there is no running from a trainer battle")

  local failed, failedSent = runClient("1v1")
  failed.sendChoice = function() return false end
  pressRun(failed)
  eq(#failedSent, 0, "a refused 1v1 send files nothing")
  eq(#(failed.lines or {}), 0,
     "and does not claim a forfeit the wire never took")
end

-- ------------------------------------------------------------------
-- referee fidelity: the client half (docs/plans/gen12-referee-fidelity.md)
-- ------------------------------------------------------------------
--
-- K1 `traded` on the player's own Gen 1 / Gen 2 sheets outside a link battle;
-- K2 the Gold held item's data beside `heldItem`; K4 the four Kanto obedience
-- badges; Gold's `held` event written home (applyHeld2) in the fights the cart
-- keeps an item change from, and never in a fight between players; the wild
-- held item Gold's engine does not roll; and the AMULET COIN.  The item rows
-- below are invented for this file -- ids the cart's constants name, numbers
-- nobody's ROM holds.

-- An invented Gold item table, in the engine's shape (data.items rows with the
-- `heldEffect` / `heldParameter` columns src/core/gen2/ItemEffects.lua reads).
local GOLD_ITEMS = {
  LEFTOVERS   = { name = "LEFTOVERS", heldEffect = "HELD_LEFTOVERS", heldParameter = 7 },
  BERRY       = { name = "BERRY", heldEffect = "HELD_BERRY", heldParameter = 9 },
  NUGGET      = { name = "NUGGET", heldEffect = "HELD_NONE", heldParameter = 0 },
  AMULET_COIN = { name = "AMULET COIN", heldEffect = "HELD_AMULET_COIN", heldParameter = 3 },
  FLOWER_MAIL = { name = "FLOWER MAIL", heldEffect = "HELD_NONE", heldParameter = 0 },
  MASTER_BALL = { name = "MASTER BALL" },
  ODD_THING   = { name = "ODD THING", heldEffect = "mymod.glow", heldParameter = 1 },
}

local function goldData(items)
  return setmetatable({ items = items or GOLD_ITEMS,
                        pokemon = { CHARMANDER = DATA.pokemon.CHARMANDER,
                                    SQUIRTLE = DATA.pokemon.SQUIRTLE } },
                      { __index = DATA })
end

-- A Gold game whose player id is 4321, and a party mon with an OT and an item.
local function goldMon(species, item, otId)
  local m = mon(species)
  m.item, m.otId = item, otId
  return m
end
local function goldGame(party, data)
  return {
    generation = 2,
    data = data or goldData(),
    save = { generation = 2, party = party, inventory = {},
             player = { name = "GOLD", id = 4321, money = 0 } },
  }
end

-- ------- K1: traded, on our own sheets outside a link battle
do
  local function redGame(party, playerId)
    local game = gameWith(party, DATA)
    game.save.player.id = playerId
    return game
  end
  local own = mon("CHARMANDER"); own.otId = 4321
  local swap = mon("SQUIRTLE"); swap.otId = 9876
  local bare = mon("CHARMANDER")
  local sheets = Mediated.snapshotParty(redGame({ own, swap, bare }, 4321))
  eq(sheets[1].traded, nil, "K1 (Gen 1): a mon whose OT id is the player's is not traded")
  eq(sheets[2].traded, true, "K1 (Gen 1): a mon from another OT id is traded")
  eq(sheets[3].traded, nil, "K1 (Gen 1): a mon with no OT id on record is the player's own")
  local packed1 = Wire.battleParty({ battle = "k1", mons = sheets, generation = 1 })
  eq(packed1 and packed1.mons[2].traded, true, "K1 (Gen 1): traded survives Wire.battleParty")
  local linked = Mediated.snapshotParty(redGame({ own, swap }, 4321), { link = true })
  eq(linked[2].traded, nil, "K1 (Gen 1): a link battle's sheets state no traded")
  local foes = Mediated.snapshotMons(redGame({ own, swap }, 4321), { own, swap })
  eq(foes[2].traded, nil, "K1: a foe's sheet (no `own`) is never stamped")
  eq(Mediated.snapshotParty(redGame({ swap }, nil))[1].traded, nil,
     "K1: no player id on the save is nothing to compare against")
  local wide = mon("SQUIRTLE"); wide.otId = 65536 + 4321
  eq(Mediated.snapshotParty(redGame({ wide }, 4321))[1].traded, nil,
     "K1: the OT id is the cart's 16-bit word")
  eq(Mediated.tradedOf({ save = { player = { id = 7 } } }, { otId = "7" }), nil,
     "K1: tradedOf reads numbers the way the save may hold them")

  local gold = goldGame({ goldMon("CHARMANDER", nil, 4321), goldMon("SQUIRTLE", nil, 1) })
  local goldSheets = Mediated.snapshotParty(gold)
  eq(goldSheets[1].traded, nil, "K1 (Gold): the player's own mon")
  eq(goldSheets[2].traded, true, "K1 (Gold): a traded mon")
  local packed2 = Wire.battleParty({ battle = "k1", mons = goldSheets, generation = 2 })
  eq(packed2 and packed2.mons[2].traded, true, "K1 (Gold): traded survives Wire.battleParty")
  eq(Mediated.snapshotParty(gold, { link = true })[2].traded, nil,
     "K1 (Gold): ...and a link battle's sheets carry none")

  -- Through the screen's own upload: a fight against the computer stamps it, a
  -- 1v1 does not.
  local function uploadFor(mode)
    local sent = {}
    local fight = Mediated.new({
      transport = { send = function(_, t, p) sent[#sent + 1] = { type = t, payload = p } end },
      game = gold, battle = "k1u", role = "host", mode = mode,
    })
    fight:start(gold)
    for _, msg in ipairs(sent) do
      if msg.type == Wire.BATTLE_PARTY and msg.payload.side == nil then return msg.payload end
    end
    return nil
  end
  eq(uploadFor("wild").mons[2].traded, true, "K1: a wild fight's upload carries traded")
  eq(uploadFor("coop_npc").mons[2].traded, true, "K1: ...and a trainer fight's")
  eq(uploadFor("1v1").mons[2].traded, nil, "K1: a 1v1 is a link battle: none")
end

-- ------- K2: Gold's held item on the sheet
do
  local game = goldGame({
    goldMon("CHARMANDER", "LEFTOVERS"), goldMon("SQUIRTLE", "FLOWER_MAIL"),
    goldMon("CHARMANDER"),
  })
  local sheets = Mediated.snapshotParty(game)
  eq(sheets[1].heldItem, "LEFTOVERS", "K2: the item id")
  eq(sheets[1].holdEffect, "HELD_LEFTOVERS", "K2: its hold effect token, off the engine's item row")
  eq(sheets[1].holdParam, 7, "K2: the parameter beside it")
  eq(sheets[1].itemName, "LEFTOVERS", "K2: the name the box narrates under")
  eq(sheets[1].mail, nil, "K2: not mail")
  eq(sheets[2].mail, true, "K2: a mail item says so (the engine's Mail.isMail)")
  eq(sheets[2].itemName, "FLOWER MAIL", "K2: ...under its printed name")
  for _, key in ipairs({ "heldItem", "holdEffect", "holdParam", "itemName", "mail" }) do
    eq(sheets[3][key], nil, "K2: a mon holding nothing carries no " .. key)
  end
  local packed = Wire.battleParty({ battle = "k2", mons = sheets, generation = 2 })
  check(packed ~= nil, "K2: the sheets survive Wire.battleParty")
  eq(packed and packed.mons[1].holdEffect, "HELD_LEFTOVERS", "K2: holdEffect crosses the wire")
  eq(packed and packed.mons[1].holdParam, 7, "K2: holdParam too")
  eq(packed and packed.mons[2].mail, true, "K2: and mail")

  -- The merged `held_items` registry wins over the item row: a content mod's
  -- patch reaches the referee (ItemEffects.heldItemFor).
  local patched = goldData()
  patched.gen2HeldItems = { LEFTOVERS = { heldEffect = "HELD_BERRY", heldParameter = 2 } }
  local p = Mediated.snapshotParty(goldGame({ goldMon("CHARMANDER", "LEFTOVERS") }, patched))
  eq(p[1].holdEffect, "HELD_BERRY", "K2: the held_items registry's effect is the one sent")
  eq(p[1].holdParam, 2, "K2: ...with its parameter")

  -- A hold effect off the wire's alphabet would refuse the mon at the hub; it
  -- rides as the bare item instead, said once.
  local mark = #warns
  local odd = Mediated.snapshotParty(goldGame({ goldMon("CHARMANDER", "ODD_THING") }))
  eq(odd[1].heldItem, "ODD_THING", "K2 (modded): the item still rides")
  eq(odd[1].holdEffect, nil, "K2 (modded): an unreadable hold effect is left off")
  eq(odd[1].holdParam, nil, "K2 (modded): ...and its parameter with it")
  check(Wire.battleParty({ battle = "k2", mons = odd, generation = 2 }) ~= nil,
        "K2 (modded): the sheet survives the sanitiser")
  local named = false
  for i = mark + 1, #warns do
    if tostring(warns[i]):find("ODD_THING", 1, true) then named = true end
  end
  check(named, "K2 (modded): the warning names the item")

  -- Gen 1 has no held items: a Kanto sheet carries none of it, whatever its
  -- monster table says.
  local red = gameWith({ goldMon("CHARMANDER", "LEFTOVERS") }, DATA)
  local redSheet = Mediated.snapshotParty(red)[1]
  eq(redSheet.heldItem, nil, "K2: a Gen 1 sheet carries no item")
  eq(redSheet.holdEffect, nil, "K2: ...and no hold effect")
end

-- ------- K4: the Kanto obedience badges
do
  local badgeData = setmetatable({ constants = {
    badgeBoosts = { { badge = "BOULDERBADGE", stat = "attack" } },
    -- A save that keeps one badge under another inventory key (Badges.itemFor).
    badges = { { id = "BOULDERBADGE" }, { id = "CASCADEBADGE" }, { id = "MARSHBADGE", item = "MARSH_PIN" } },
  } }, { __index = DATA })
  local game = gameWith({ mon("CHARMANDER") }, badgeData)
  game.save.inventory = { BOULDERBADGE = 1, CASCADEBADGE = 1, MARSH_PIN = 1 }
  game.save.player.badges = { EARTHBADGE = true }
  local function list(mode) return table.concat(Mediated.badgesOf(game, mode) or {}, ",") end
  eq(list("wild"), "BOULDERBADGE,CASCADEBADGE,MARSHBADGE,EARTHBADGE",
     "K4: the boost rows, then the obedience badges the save holds")
  eq(list("coop_npc"), "BOULDERBADGE,CASCADEBADGE,MARSHBADGE,EARTHBADGE", "K4: ...in a trainer fight")
  eq(Mediated.badgesOf(game, "1v1"), nil, "K4: none in a link battle")
  eq(Mediated.badgesOf(game, "coop_pvp"), nil, "K4: ...on either link mode")
  game.save.inventory = { RAINBOWBADGE = 1 }
  game.save.player.badges = nil
  eq(list("wild"), "RAINBOWBADGE", "K4: an obedience badge alone, with no boost badge")
  local set = Wire.badges(Mediated.badgesOf(game, "wild"))
  check(set and set.RAINBOWBADGE, "K4: Wire.badges keeps the id the referee reads")
  -- Gold reads its own stores; a Kanto badge item in the bag is nothing to it.
  local gold = goldGame({})
  gold.save.inventory = { EARTHBADGE = 1, CASCADEBADGE = 1 }
  eq(Mediated.badgesOf(gold, "wild"), nil, "K4: Gold never sends a Gen 1 obedience badge")
end

-- ------- the wild held item Gold's engine does not roll
do
  local function bytes(list)
    local i = 0
    return function() i = i + 1; return list[i] end, function() return i end
  end
  local itemData = goldData()
  itemData.pokemon = { SQUIRTLE = { name = "SQUIRTLE", items = { "BERRY", "NUGGET" } },
                       CHARMANDER = { name = "CHARMANDER" },
                       PIDGEY = { name = "PIDGEY", items = { nil, "NUGGET" } } }
  local game = goldGame({}, itemData)
  local function rolled(species, list, battleType)
    local m = mon(species)
    local random, drawn = bytes(list)
    local got = Mediated.rollWildItem2(game, m, { random = random, battleType = battleType })
    return got, m.item, drawn()
  end
  local item, held, drawn = rolled("SQUIRTLE", { 191 })
  eq(item, nil, "wild item: below 75 percent + 1 (192) holds nothing")
  eq(held, nil, "wild item: ...and the monster is left empty-handed")
  eq(drawn, 1, "wild item: ...on one draw")
  item, held, drawn = rolled("SQUIRTLE", { 192, 20 })
  eq(item, "BERRY", "wild item: 192 and up holds one; 20 and up on the second draw is item 1")
  eq(held, "BERRY", "wild item: written onto the engine monster (what a catch keeps)")
  eq(drawn, 2, "wild item: ...on two draws")
  item = rolled("SQUIRTLE", { 255, 19 })
  eq(item, "NUGGET", "wild item: under 8 percent (20) on the second draw is item 2")
  item, held = rolled("PIDGEY", { 200, 50 })
  eq(item, nil, "wild item: an empty item 1 slot is NO_ITEM")
  item, held, drawn = rolled("CHARMANDER", { 255, 0 })
  eq(item, nil, "wild item: a species with no items holds none")
  eq(drawn, 0, "wild item: ...and draws nothing")
  item, held, drawn = rolled("SQUIRTLE", {}, Mediated.BATTLETYPE_FORCEITEM2)
  eq(item, "BERRY", "wild item: a forced-item encounter holds item 1")
  eq(drawn, 0, "wild item: ...without a draw")
  local gift = mon("SQUIRTLE"); gift.item = "LEFTOVERS"
  eq(Mediated.rollWildItem2(game, gift, { random = function() return 255 end }), "LEFTOVERS",
     "wild item: a monster already holding one keeps it")
  local red = mon("SQUIRTLE")
  eq(Mediated.rollWildItem2(gameWith({}, itemData), red, { random = function() return 255 end }), nil,
     "wild item: Gen 1 rolls nothing")
  eq(red.item, nil, "wild item: ...and writes nothing")
end

-- ------- Gold's `held` event: applyHeld2, per mode
do
  -- A Gold screen in `mode` holding ANN's party [LEFTOVERS, BERRY, FLOWER_MAIL],
  -- the wild foe (when `wild`) holding NUGGET.
  local function goldFight(mode, wildItem)
    local party = {
      goldMon("CHARMANDER", "LEFTOVERS", 4321),
      goldMon("SQUIRTLE", "BERRY", 4321),
      goldMon("CHARMANDER", "FLOWER_MAIL", 4321),
    }
    local game = goldGame(party)
    local wildParty
    if wildItem then
      wildParty = Mediated.snapshotMons(game, { goldMon("SQUIRTLE", wildItem) })
    end
    local fight = Mediated.new({
      transport = { send = function() return true end },
      game = game, battle = "h2", role = "host", mode = mode, wildParty = wildParty,
    })
    fight:start(game)
    fight.seqNext = 0
    function fight.feed(fields)
      fight.seqNext = fight.seqNext + 1
      fields.battle, fields.seq = "h2", fight.seqNext
      fight:onEvent(fields)
    end
    return fight, party
  end
  local function eaten(fight)
    fight.feed({ t = "held", slot = 0, side = "a", mon = 1, text = "BERRY", amount = 0 })
  end

  for _, mode in ipairs({ "wild", "coop_npc", "coop_wild" }) do
    local fight, party = goldFight(mode)
    eaten(fight)
    eq(party[2].item, nil, "held (" .. mode .. "): a berry eaten is gone from the save")
    eq(fight.mine[2].heldItem, nil, "held (" .. mode .. "): ...and from the fight sheet")
    eq(fight.mine[2].holdEffect, nil, "held (" .. mode .. "): ...with every K2 field")
    eq(party[1].item, "LEFTOVERS", "held (" .. mode .. "): the other mons keep theirs")
  end
  for _, mode in ipairs({ "1v1", "coop_pvp" }) do
    local fight, party = goldFight(mode)
    eaten(fight)
    eq(party[2].item, "BERRY", "held (" .. mode .. "): a fight between players never writes home")
    eq(fight.mine[2].heldItem, nil, "held (" .. mode .. "): ...though the fight sheet follows the referee")
  end

  -- Still holding it (LEFTOVERS healing): nothing moves.
  local fight, party = goldFight("wild")
  fight.feed({ t = "held", slot = 0, side = "a", mon = 0, text = "LEFTOVERS", amount = 1 })
  eq(party[1].item, "LEFTOVERS", "held: a `held` that still holds changes nothing")

  -- THIEF from the wild monster this client described: kept.
  fight, party = goldFight("wild", "NUGGET")
  fight.feed({ t = "held", slot = 3, side = "b", mon = 0, text = "NUGGET", amount = 0 })
  fight.feed({ t = "held", slot = 0, side = "a", mon = 1, text = "NUGGET", amount = 1 })
  eq(party[2].item, "NUGGET", "held: an item THIEF took from our own described foe is kept")
  eq(fight.mine[2].holdEffect, "HELD_NONE", "held: ...the sheet re-read for the new item")
  eq(fight.foeHeld2 and fight.foeHeld2[0], false, "held: the foe's loss is remembered for a catch")

  -- A forged gain: an item nothing in this fight held.
  local mark = #warns
  fight, party = goldFight("wild")
  fight.feed({ t = "held", slot = 0, side = "a", mon = 1, text = "MASTER_BALL", amount = 1 })
  eq(party[2].item, "BERRY", "held: an item nobody uploaded never enters the save")
  check(#warns > mark, "held: ...and it is said")

  -- The foe's events never touch our save.
  fight, party = goldFight("wild", "NUGGET")
  fight.feed({ t = "held", slot = 3, side = "b", mon = 0, text = "NUGGET", amount = 0 })
  eq(party[1].item, "LEFTOVERS", "held: a foe's event writes nothing of ours")
  eq(party[2].item, "BERRY", "held: ...on any of our mons")

  -- A letter is never taken off on the referee's word.
  fight, party = goldFight("wild")
  fight.feed({ t = "held", slot = 0, side = "a", mon = 2, text = "FLOWER_MAIL", amount = 0 })
  eq(party[3].item, "FLOWER_MAIL", "held: a mail item stays in the save")

  -- An event with no fate changes nothing.
  fight, party = goldFight("wild")
  fight.feed({ t = "held", slot = 0, side = "a", mon = 1, text = "BERRY" })
  eq(party[2].item, "BERRY", "held: no `amount` is no change")

  -- A `mon` past the sheets this client uploaded names nobody it can write.
  fight, party = goldFight("wild")
  party[4] = goldMon("SQUIRTLE", "BERRY", 4321)
  fight.feed({ t = "held", slot = 0, side = "a", mon = 3, text = "BERRY", amount = 0 })
  eq(party[4].item, "BERRY", "held: an index no uploaded sheet stands behind writes nothing")

  -- A Gen 3 screen's `held` is its own (numeric `holding`), untouched by this.
  check(Wire.battleEvent({ battle = "x", seq = 1, t = "held", text = "BERRY", amount = 0 }, 2) ~= nil,
        "held: Wire keeps a Gold reader's `held`")
  eq(Wire.battleEvent({ battle = "x", seq = 1, t = "held", text = "BERRY", amount = 0 }, 1), nil,
     "held: ...and a Gen 1 reader drops it")

  -- The catch keeps what the wild monster still holds at the throw.
  fight = goldFight("wild", "NUGGET")
  eq(fight:caughtHolding2(0), nil, "catch: no `held` about it says nothing")
  fight.feed({ t = "held", slot = 3, side = "b", mon = 0, text = "NUGGET", amount = 0 })
  eq(fight:caughtHolding2(0), false, "catch: an item it lost is not caught with it")
  -- Its own THIEF of an item nobody here described: the NUGGET it was rolled
  -- is gone (THIEF takes only when its user holds nothing), and the item it
  -- took is a claim -- nothing, not the roll handed back.
  fight.feed({ t = "held", slot = 3, side = "b", mon = 0, text = "MASTER_BALL", amount = 1 })
  eq(fight:caughtHolding2(0), false,
     "catch: an item this client never described is not caught, and the lost one is not handed back")
  -- Taking back one this client described (its own monster's, by THIEF): kept.
  fight.feed({ t = "held", slot = 3, side = "b", mon = 0, text = "LEFTOVERS", amount = 1 })
  eq(fight:caughtHolding2(0), "LEFTOVERS", "catch: an item this client described is caught with it")

  -- ...through grantCatch: the engine monster the catch keeps, rolled NUGGET,
  -- caught after the foreign THIEF holds nothing.
  fight = goldFight("wild", "NUGGET")
  local wildMon = goldMon("SQUIRTLE", "NUGGET")
  fight.wildCatchMon = wildMon
  fight.feed({ t = "held", slot = 3, side = "b", mon = 0, text = "NUGGET", amount = 0 })
  fight.feed({ t = "held", slot = 3, side = "b", mon = 0, text = "MASTER_BALL", amount = 1 })
  fight:grantCatch({ caught = {} })
  eq(wildMon.item, nil, "catch: grantCatch hands the wild monster back no item it already lost")

  -- AMULET COIN: our own monster coming out holding one, and only ours.
  local coinParty = { goldMon("CHARMANDER", "AMULET_COIN", 4321), goldMon("SQUIRTLE", nil, 4321) }
  local coinGame = goldGame(coinParty)
  local coin = Mediated.new({ transport = { send = function() return true end },
                              game = coinGame, battle = "a2", role = "host", mode = "coop_npc" })
  coin:start(coinGame)
  eq(coin:amuletCoin2(), false, "amulet: nothing has come out yet")
  coin:onEvent({ battle = "a2", seq = 1, t = "send", slot = 3, side = "b", mon = 0, text = "SQUIRTLE", hp = 30 })
  eq(coin:amuletCoin2(), false, "amulet: a foe's send-out is not ours")
  coin:onEvent({ battle = "a2", seq = 2, t = "send", slot = 0, side = "a", mon = 1, text = "SQUIRTLE", hp = 30 })
  eq(coin:amuletCoin2(), false, "amulet: our mon holding nothing")
  coin:onEvent({ battle = "a2", seq = 3, t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  eq(coin:amuletCoin2(), true, "amulet: our mon coming out with the coin latches it")
  coin:onEvent({ battle = "a2", seq = 4, t = "held", slot = 0, side = "a", mon = 0, text = "AMULET_COIN", amount = 0 })
  eq(coin:amuletCoin2(), true, "amulet: ...for the rest of the fight, whatever happens to the coin")
  local stolen = Mediated.new({ transport = { send = function() return true end },
                                game = goldGame({ goldMon("CHARMANDER", "AMULET_COIN", 4321) }),
                                battle = "a3", role = "host", mode = "coop_npc" })
  stolen:start(stolen.game)
  stolen:onEvent({ battle = "a3", seq = 1, t = "held", slot = 0, side = "a", mon = 0, text = "AMULET_COIN", amount = 0 })
  stolen:onEvent({ battle = "a3", seq = 2, t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  eq(stolen:amuletCoin2(), false, "amulet: a coin taken before the send-out counts for nothing")
end

-- ------------------------------------------------------------------
-- closing the Red / Gold referee gaps: the client half
-- (docs/plans/gen12-referee-gaps-fix.md, wave 2 task C)
-- ------------------------------------------------------------------
--
-- K7 (base / dvs / statExp) and K8 (ppUps, Gold priority) on every Red and
-- Gold sheet; K14 (Gold happiness); K9 (a level-up rides mmo.battle_moveset);
-- K10 (a stat event's signed stage as the arrows' tie-break); K11 (Pay Day
-- paid); the cart's PP-Up cap; the Metronome pool per cart; and the wild item
-- `beginWildMediated` used to skip.  Every number here is invented for this
-- file -- no base stat, PP or item row is a ROM's.

-- A Red world with whole species rows and a 40-PP move, the case the PP-Up
-- cap moves (pokered AddBonusPP: a fifth of the base, capped at 7, per PP Up).
local K_RED = {
  type_chart = DATA.type_chart,
  moves = {
    EMBER = { name = "EMBER", power = 40, accuracy = 100, type = "FIRE", pp = 25 },
    GROWL = { name = "GROWL", power = 0, accuracy = 100, type = "NORMAL", pp = 40 },
    TACKLE = { name = "TACKLE", power = 35, accuracy = 95, type = "NORMAL", pp = 35 },
    METRONOME = { name = "METRONOME", power = 0, accuracy = 100, type = "NORMAL",
                  pp = 10, effect = "METRONOME_EFFECT" },
    STRUGGLE = { name = "STRUGGLE", power = 50, accuracy = 100, type = "NORMAL", pp = 10 },
  },
  pokemon = {
    CHARMANDER = { name = "CHARMANDER", types = { "FIRE" },
                   baseStats = { hp = 39, attack = 52, defense = 43, speed = 65, special = 50 } },
    SQUIRTLE = { name = "SQUIRTLE", types = { "WATER" } },
  },
}

-- ------- K7 / K8 on a Red sheet
do
  local m = mon("CHARMANDER", { moves = {
    { id = "GROWL", pp = 30, ppUps = 3 },  -- 40 base: 40 + 3 x 7 = 61, not 64
    { id = "TACKLE", pp = 35, ppUps = 3 }, -- 35 base: 35 + 3 x 7 = 56 (the cap's edge)
    { id = "EMBER", pp = 3 },              -- 25 base, no PP Ups: 25
  } })
  local sheet = Mediated.snapshotParty(gameWith({ m }, K_RED))[1]
  check(sheet ~= nil, "K7 (Gen 1): the sheet is built")
  local b = sheet.base or {}
  eq(table.concat({ b.hp or "-", b.atk or "-", b.def or "-", b.spd or "-", b.spc or "-" }, ","),
     "39,52,43,65,50", "K7 (Gen 1): base is the species row, keyed hp atk def spd spc")
  local d = sheet.dvs or {}
  eq(table.concat({ d.atk or "-", d.def or "-", d.spd or "-", d.spc or "-" }, ","), "1,2,3,4",
     "K7 (Gen 1): dvs are the four the cart stores (no HP DV)")
  eq(d.hp, nil, "K7 (Gen 1): ...the HP DV is derived, never a key")
  local x = sheet.statExp or {}
  eq(table.concat({ x.hp or "-", x.atk or "-", x.def or "-", x.spd or "-", x.spc or "-" }, ","),
     "0,100,0,0,0", "K7 (Gen 1): statExp is the five words")
  eq(sheet.happiness, nil, "K14: Red has no happiness byte")
  local growl, tackle, ember = sheet.moves[1], sheet.moves[2], sheet.moves[3]
  eq(growl.ppUps, 3, "K8 (Gen 1): a move's PP Ups ride the row")
  eq(growl.maxPp, 61, "PP cap (Gen 1): a 40-PP move with three PP Ups tops out at 61 (AddBonusPP)")
  eq(tackle.maxPp, 56, "PP cap (Gen 1): a 35-PP move's bonus is exactly 7 per PP Up")
  eq(ember.ppUps, 0, "K8 (Gen 1): a move with none states 0")
  eq(ember.maxPp, 25, "maxPp (Gen 1): no stated maximum is the record's base, not the PP left")
  eq(growl.priority, nil, "K8: a Red row states no priority (Red has none)")
  -- Through the real sanitiser, the far end's reading.
  local packedRed = Wire.battleParty({ battle = "k7r", mons = { sheet }, generation = 1 })
  local pm = packedRed and packedRed.mons[1]
  check(pm ~= nil, "K7 (Gen 1): the sheet survives Wire.battleParty")
  eq(pm and pm.base and pm.base.spc, 50, "K7 (Gen 1): base survives the wire")
  eq(pm and pm.dvs and pm.dvs.spd, 3, "K7 (Gen 1): dvs survive the wire")
  eq(pm and pm.statExp and pm.statExp.atk, 100, "K7 (Gen 1): statExp survives the wire")
  eq(pm and pm.moves[1].ppUps, 3, "K8 (Gen 1): ppUps survive the wire")
  local one = Wire.battleMon(sheet)
  eq(one and one.base and one.base.hp, 39, "K7 (Gen 1): Wire.battleMon round-trips it too")
  -- A species row this client cannot read whole states no block, rather than
  -- one the far end would refuse the monster (and the party) over.
  local partial = Mediated.snapshotParty(gameWith({ mon("CHARMANDER") }, DATA))[1]
  eq(partial.base, nil, "K7: a species row with a hole (speed only) states no base")
  check(partial.dvs ~= nil and partial.statExp ~= nil, "K7: ...while the monster's own blocks still ride")
  local bare = mon("SQUIRTLE"); bare.statExp = nil; bare.dvs = { attack = 9 }
  local noBlocks = Mediated.snapshotParty(gameWith({ bare }, K_RED))[1]
  eq(noBlocks.statExp, nil, "K7: a monster with no stat exp (a trainer's) states none")
  eq(noBlocks.dvs, nil, "K7: ...and a DV block with a hole states none")
  check(Wire.battleParty({ battle = "k7p", mons = { noBlocks }, generation = 1 }) ~= nil,
        "K7: ...and such a sheet is still a party the far end accepts")
  -- A foe's sheet (a wild monster, a trainer's) carries them too.
  local foe = Mediated.snapshotMons(gameWith({}, K_RED), { mon("CHARMANDER") })[1]
  eq(foe and foe.dvs and foe.dvs.atk, 1, "K7: a described foe's sheet carries its DVs")
end

-- ------- K7 / K8 / K14 on a Gold sheet
do
  local goldK = setmetatable({
    moves = {
      PROTECT = { name = "PROTECT", power = 0, accuracy = 100, type = "NORMAL", pp = 10,
                  effect = "EFFECT_PROTECT" },
      QUICK_ATTACK = { name = "QUICK ATTACK", power = 40, accuracy = 100, type = "NORMAL",
                       pp = 30, effect = "EFFECT_PRIORITY_HIT" },
      COUNTER = { name = "COUNTER", power = 1, accuracy = 100, type = "NORMAL", pp = 20,
                  effect = "EFFECT_COUNTER" },
      VITAL_THROW = { name = "VITAL THROW", power = 70, accuracy = 100, type = "NORMAL",
                      pp = 10, effect = "EFFECT_ALWAYS_HIT" },
      TACKLE = { name = "TACKLE", power = 35, accuracy = 95, type = "NORMAL", pp = 35,
                 effect = "EFFECT_NORMAL_HIT" },
      -- A content mod's move that states its own priority, which wins.
      ZIP = { name = "ZIP", power = 30, accuracy = 100, type = "NORMAL", pp = 40,
              effect = "EFFECT_NORMAL_HIT", priority = 2 },
    },
    pokemon = {
      SQUIRTLE = { name = "SQUIRTLE", types = { "WATER" },
                   baseStats = { hp = 44, attack = 48, defense = 65, speed = 43,
                                 specialAttack = 50, specialDefense = 64 } },
    },
  }, { __index = goldData() })
  local m = goldMon("SQUIRTLE", nil, 4321)
  m.stats = { hp = 30, attack = 14, defense = 13, speed = 16, specialAttack = 15,
              specialDefense = 17 }
  m.dvs = { hp = 5, attack = 1, defense = 2, speed = 3, special = 4 }
  m.statExp = { hp = 7, attack = 100, defense = 0, speed = 9, special = 11 }
  m.happiness = 200
  m.moves = {
    { id = "PROTECT", pp = 10 }, { id = "QUICK_ATTACK", pp = 30 },
    { id = "COUNTER", pp = 20 }, { id = "VITAL_THROW", pp = 10 },
  }
  local game = goldGame({ m }, goldK)
  local sheet = Mediated.snapshotParty(game)[1]
  check(sheet ~= nil, "K7 (Gold): the sheet is built")
  local b = sheet.base or {}
  eq(table.concat({ b.hp or "-", b.atk or "-", b.def or "-", b.spe or "-", b.spa or "-", b.spd or "-" }, ","),
     "44,48,65,43,50,64", "K7 (Gold): base splits Special, keyed like `stats` plus hp")
  local d = sheet.dvs or {}
  eq(table.concat({ d.atk or "-", d.def or "-", d.spe or "-", d.spc or "-" }, ","), "1,2,3,4",
     "K7 (Gold): dvs keep one Special DV (atk def spe spc)")
  local x = sheet.statExp or {}
  eq(table.concat({ x.hp or "-", x.atk or "-", x.def or "-", x.spe or "-", x.spc or "-" }, ","),
     "7,100,0,9,11", "K7 (Gold): statExp keeps one Special word")
  eq(sheet.happiness, 200, "K14 (Gold): happiness rides the sheet")
  local pr = {}
  for _, row in ipairs(sheet.moves) do pr[row.id] = row.priority end
  eq(pr.PROTECT, 3, "K8 (Gold): EFFECT_PROTECT is MoveEffectPriorities' 3")
  eq(pr.QUICK_ATTACK, 2, "K8 (Gold): EFFECT_PRIORITY_HIT is 2")
  eq(pr.COUNTER, 0, "K8 (Gold): EFFECT_COUNTER is 0")
  eq(pr.VITAL_THROW, 0, "K8 (Gold): VITAL_THROW is 0 by its id (GetMovePriority)")
  local more = Mediated.sheetMoves(game, { moves = { { id = "TACKLE", pp = 35 }, { id = "ZIP", pp = 40 } } })
  eq(more[1].priority, Mediated.GOLD_BASE_PRIORITY, "K8 (Gold): a move with no row is BASE_PRIORITY (1)")
  eq(more[2].priority, 2, "K8 (Gold): a record's own priority wins (a content mod's move)")
  -- The numbers agree with the Gold referee's own table for every vanilla id.
  local Effects2 = need("BattleSim2/Effects")
  for id, n in pairs(pr) do
    eq(n, Effects2.movePriority(id), "K8 (Gold): " .. id .. "'s byte is the referee's own")
  end
  -- Gold's engine slot may state only its raised maximum (Mon.ppUpsOf).
  local raised = Mediated.sheetMoves(game, { moves = { { id = "ZIP", pp = 12, maxPp = 61 } } })[1]
  eq(raised.ppUps, 3, "K8 (Gold): PP Ups recovered off a stated 61 over a base of 40")
  eq(raised.maxPp, 61, "K8 (Gold): ...and the stated maximum kept")
  local packedGold = Wire.battleParty({ battle = "k7g", mons = { sheet }, generation = 2 })
  local pm = packedGold and packedGold.mons[1]
  check(pm ~= nil, "K7 (Gold): the sheet survives Wire.battleParty")
  eq(pm and pm.base and pm.base.spd, 64, "K7 (Gold): base survives the wire")
  eq(pm and pm.dvs and pm.dvs.spc, 4, "K7 (Gold): dvs survive the wire")
  eq(pm and pm.statExp and pm.statExp.spc, 11, "K7 (Gold): statExp survives the wire")
  eq(pm and pm.happiness, 200, "K14 (Gold): happiness survives the wire")
  eq(pm and pm.moves[1].priority, 3, "K8 (Gold): priority survives the wire")
  eq(pm and pm.moves[1].ppUps, 0, "K8 (Gold): ppUps survive the wire")
  local one = Wire.battleMon(sheet)
  eq(one and one.happiness, 200, "K14 (Gold): Wire.battleMon round-trips happiness")
  eq(one and one.base and one.base.spe, 43, "K7 (Gold): ...and the K7 blocks")
end

-- ------- the PP-Up rule itself
eq(Mediated.maxPpOf(40, 3), 61, "PP cap: 40 base, three PP Ups -> 61 (both carts)")
eq(Mediated.maxPpOf(35, 3), 56, "PP cap: 35 base -> 7 per PP Up, 56")
eq(Mediated.maxPpOf(10, 3), 16, "PP cap: 10 base -> 2 per PP Up, 16")
eq(Mediated.maxPpOf(40, 0), 40, "PP cap: no PP Ups is the base")
eq(Mediated.maxPpOf(40, 9), 61, "PP cap: a count past 3 reads as the cart's 3")
eq(Mediated.ppUpBonus(64), 7, "PP cap: the bonus never passes 7")

-- ------- the Metronome pool, per cart
do
  local function poolIds(game)
    local out = {}
    for _, row in ipairs(Mediated.snapshotRuleset(game).metronomePool or {}) do out[row.id] = true end
    return out
  end
  local red = poolIds(gameWith({}, K_RED))
  check(red.TACKLE and red.EMBER, "Metronome (Red): ordinary moves are in the pool")
  eq(red.METRONOME, nil, "Metronome (Red): METRONOME is not (MetronomePickMove)")
  eq(red.STRUGGLE, nil, "Metronome (Red): nor STRUGGLE")

  -- Gold: the full 251-move table, the twelve MetronomeExcepts ids among it.
  local goldMoves = {}
  local excepts = { "METRONOME", "STRUGGLE", "SKETCH", "MIMIC", "COUNTER", "MIRROR_COAT",
                    "PROTECT", "DETECT", "ENDURE", "DESTINY_BOND", "SLEEP_TALK", "THIEF" }
  for _, id in ipairs(excepts) do
    goldMoves[id] = { name = id, power = 0, accuracy = 100, type = "NORMAL", pp = 10,
                      effect = id == "METRONOME" and "EFFECT_METRONOME" or "EFFECT_NORMAL_HIT" }
  end
  for i = 1, 251 - #excepts do
    local id = ("ZZ%03d"):format(i)  -- sorts after every name above
    goldMoves[id] = { name = id, power = 40, accuracy = 100, type = "NORMAL", pp = 20,
                      effect = "EFFECT_NORMAL_HIT" }
  end
  local goldGameFull = goldWith({ type_chart = DATA.type_chart, moves = goldMoves })
  local pool = Mediated.snapshotRuleset(goldGameFull).metronomePool or {}
  eq(#pool, 251 - #excepts, "Metronome (Gold): every move but the cart's twelve exceptions -- past the old 200")
  local inPool = {}
  for _, row in ipairs(pool) do inPool[row.id] = true end
  for _, id in ipairs(excepts) do
    eq(inPool[id], nil, "Metronome (Gold): " .. id .. " is never called (MetronomeExcepts)")
  end
  check(inPool.ZZ239, "Metronome (Gold): the table's last id is reachable")
  check(#pool <= Config.BATTLE_METRONOME_POOL_MAX, "Metronome (Gold): ...within the wire's cap")
  check(Wire.battleRuleset(Mediated.snapshotRuleset(goldGameFull), 2) ~= nil,
        "Metronome (Gold): the full pool survives Wire.battleRuleset")
end

-- ------- K10: the arrows read a signed stage only where the words say nothing
eq(Mediated.statFell({ text = "ATTACK fell!", stage = 1 }), true, "K10: the sentence wins (a drop to +1)")
eq(Mediated.statFell({ text = "ATTACK rose!", stage = -1 }), false, "K10: ...both ways (a rise to -1)")
eq(Mediated.statFell({ stage = -2 }), true, "K10: no words: a stage below zero reads as a drop")
eq(Mediated.statFell({ stage = 2 }), false, "K10: ...and one above it as a rise")
eq(Mediated.statFell({ text = "X's RAGE is building!", amount = 3 }), false,
   "K10: no words and no stage: a rise, as before")
eq(Mediated.statFell({ text = "fell", delta = 1 }), false, "K10: Gen 3's delta still beats a sentence")

-- ------- K9: a level-up rides mmo.battle_moveset, once, with the new move list
do
  -- Gold: SQUIRTLE learns GROWL at 13 (Exp2.movesLearnedAt reads levelMoves).
  local data9 = setmetatable({
    pokemon = { SQUIRTLE = { name = "SQUIRTLE", types = { "WATER" },
                             levelMoves = { { level = 13, move = "GROWL" } } },
                CHARMANDER = DATA.pokemon.CHARMANDER },
  }, { __index = goldData() })
  local m = goldMon("SQUIRTLE", nil, 4321)
  m.stats = { hp = 30, attack = 14, defense = 13, speed = 16, specialAttack = 15, specialDefense = 17 }
  local bench = goldMon("CHARMANDER", nil, 4321)
  local game = goldGame({ m, bench }, data9)
  local sent = {}
  local fight = Mediated.new({
    transport = { send = function(_, t, p) sent[#sent + 1] = { type = t, payload = p }; return true end },
    game = game, battle = "lv", role = "host", mode = "wild", peerId = "npc",
  })
  fight:start(game)
  local function movesets()
    local out = {}
    for _, e in ipairs(sent) do if e.type == Wire.BATTLE_MOVESET then out[#out + 1] = e.payload end end
    return out
  end
  -- The award has already written the save monster (Exp2.apply's job).
  m.level = 13
  m.stats = { hp = 34, attack = 16, defense = 15, speed = 18, specialAttack = 17, specialDefense = 19 }
  fight:levelled(m, nil, { 13 })
  local ms = movesets()
  eq(#ms, 1, "K9: one message for a level that also taught a move -- not one per move")
  local msg = ms[1] or {}
  eq(msg.mon, 0, "K9: ...for the uploaded sheet the monster sits behind")
  eq(msg.level, 13, "K9: ...carrying the new level")
  eq(msg.maxHp, 34, "K9: ...the new max HP")
  eq(msg.stats and table.concat({ msg.stats.atk, msg.stats.def, msg.stats.spe, msg.stats.spa, msg.stats.spd }, ","),
     "16,15,18,17,19", "K9: ...and the new stats in the sheet's (Gold) dialect")
  eq(msg.moves and #msg.moves, 2, "K9: ...beside the move list, the learned move in it")
  eq(msg.moves and msg.moves[2] and msg.moves[2].id, "GROWL", "K9: ...GROWL in the free slot")
  local clean = Wire.battleMoveset(msg, 2)
  check(clean ~= nil and clean.level == 13 and clean.maxHp == 34 and clean.stats ~= nil,
        "K9: the hub's own reader keeps level, stats and maxHp")
  eq(fight.mine[1].stats.spe, 18, "K9: the uploaded sheet takes the new stats")
  check(fight.levelSent and fight.levelSent[m], "K9: the send is noted for the plate's HP")

  -- A bench monster's level-up (EXP.SHARE) is told too, with or without a move.
  bench.level = 13
  bench.stats = { hp = 40, attack = 20, defense = 20, speed = 20, specialAttack = 20, specialDefense = 20 }
  fight:levelled(bench, nil, { 13 })
  ms = movesets()
  eq(#ms, 2, "K9: a benched monster's level-up is sent as well")
  eq(ms[2].mon, 1, "K9: ...for its own sheet")
  eq(ms[2].moves and #ms[2].moves, 1, "K9: ...a level that taught nothing sends the unchanged list")

  -- A learn outside a level-up is still the plain PROTOCOL 28 message.
  fight:teach(bench, "BENCH", "GROWL")
  ms = movesets()
  eq(#ms, 3, "K9: a learn on its own still goes out on its own")
  eq(ms[3].level, nil, "K9: ...with no level-up fields")

  -- Red: the stats in the Gen 1 dialect, and nothing on Gen 3.
  local redM = mon("CHARMANDER")
  local redGame = gameWith({ redM }, K_RED)
  local redSent = {}
  local red = Mediated.new({
    transport = { send = function(_, t, p) redSent[#redSent + 1] = { type = t, payload = p }; return true end },
    game = redGame, battle = "lr", role = "host", mode = "wild", peerId = "npc",
  })
  red:start(redGame)
  redM.level = 13
  redM.stats = { hp = 33, attack = 15, defense = 14, speed = 17, special = 16 }
  red:levelled(redM, nil, { 13 })
  local redMsg
  for _, e in ipairs(redSent) do if e.type == Wire.BATTLE_MOVESET then redMsg = e.payload end end
  eq(redMsg and redMsg.stats and table.concat({ redMsg.stats.atk, redMsg.stats.def, redMsg.stats.spd, redMsg.stats.spc }, ","),
     "15,14,17,16", "K9 (Gen 1): the stats ride in Red's dialect")
  eq(redMsg and redMsg.level, 13, "K9 (Gen 1): ...with the level")
  check(redMsg and Wire.battleMoveset(redMsg, 1) ~= nil, "K9 (Gen 1): ...which the hub reads")
  eq(Mediated.growthOf({ generation = 3 }, redM), nil, "K9: Gen 3 builds no growth (its referee rebuilds nothing)")
  check(Mediated.sendMoveset({ send = function() return true end }, "b", 0, { { id = "EMBER", pp = 1,
    power = 40, accuracy = 255, type = 0, effect = 0, chance = 0 } }, 2,
    { level = 0 }) == false, "K9: a growth the wire would refuse sends nothing")
end

-- ------- K9 and the plate: the referee's numbers hold the climb from its next batch
do
  local m = mon("CHARMANDER")
  local game = gameWith({ m }, K_RED)
  local fight = Mediated.new({ transport = { send = function() return true end },
    game = game, battle = "hp", role = "host", mode = "wild", peerId = "npc" })
  fight:start(game)
  local seat = fight:mySlot()
  fight.slots[seat] = { species = "CHARMANDER", hp = 20, maxHp = 30, shownHp = 20 }
  fight.active = 1
  m.level = 13
  m.stats = { hp = 34, attack = 15, defense = 14, speed = 17, special = 16 }
  fight:levelled(m, nil, { 13 })
  fight:syncLevelHp(1, 30, m, true)
  eq(fight.slots[seat].hp, 24, "plate: the level's 4 HP climb lands")
  eq(Mediated.levelHpOwed(fight.slots[seat]), 4, "plate: ...and is owed while this batch plays")
  -- The rest of this batch was resolved before the referee heard: pre-level.
  fight:noteSlot({ t = "damage", slot = seat, hp = 15, amount = 5 })
  eq(fight.slots[seat].hp, 19, "plate: a packet in the same batch keeps the climb (15 + 4)")
  -- The batch closes; from the next one the referee states the levelled pair.
  fight:onEvent({ battle = "hp", seq = 50, t = "turn" })
  eq(Mediated.levelHpOwed(fight.slots[seat]), 0, "plate: the slot-less turn drops a climb the referee holds")
  fight:noteSlot({ t = "damage", slot = seat, hp = 12, amount = 7 })
  eq(fight.slots[seat].hp, 12, "plate: ...so the next batch's packet is read as stated, not +4 again")

  -- A send the transport refused: the referee never heard, so the climb stays.
  local m2 = mon("CHARMANDER")
  local game2 = gameWith({ m2 }, K_RED)
  local deaf = Mediated.new({ transport = { send = function() return false end },
    game = game2, battle = "hq", role = "host", mode = "wild", peerId = "npc" })
  deaf:start(game2)
  local seat2 = deaf:mySlot()
  deaf.slots[seat2] = { species = "CHARMANDER", hp = 20, maxHp = 30, shownHp = 20 }
  deaf.active = 1
  m2.level = 13
  m2.stats = { hp = 34, attack = 15, defense = 14, speed = 17, special = 16 }
  deaf:levelled(m2, nil, { 13 })
  deaf:syncLevelHp(1, 30, m2, true)
  deaf:onEvent({ battle = "hq", seq = 50, t = "turn" })
  deaf:noteSlot({ t = "damage", slot = seat2, hp = 12, amount = 8 })
  eq(deaf.slots[seat2].hp, 16, "plate: an unheard level-up keeps its climb past the turn (12 + 4)")

  -- A newcomer installed off a park never inherits the climb.
  deaf.slots[seat2].pending = { species = "SQUIRTLE", hp = 10, shownHp = 10, maxHp = 10 }
  deaf:applySwap({ spawnfx = seat2, arrive = deaf.slots[seat2].pending })
  eq(Mediated.levelHpOwed(deaf.slots[seat2]), 0, "plate: a parked arrival drops the leaver's climb")
end

-- ------- K11: Pay Day, on Red and Gold
do
  local function payFight(game, opts)
    local fight = Mediated.new({ transport = { send = function() return true end },
      game = game, battle = opts.battle or "pd", role = opts.role or "host",
      mode = opts.mode or "wild", peerId = "npc" })
    fight:start(game)
    return fight
  end
  local function moneyOf(game) return Gen.money.get(game.save) end
  local function won(fight, coins, reason)
    fight:onOutcome({ battle = fight.battle, outcome = "win", winners = { "me" },
                      losers = { "npc" }, reason = reason or "ko", payDay = coins })
  end
  local function lost(fight, coins, reason)
    fight:onOutcome({ battle = fight.battle, outcome = "win", winners = { "npc" },
                      losers = { "me" }, reason = reason, payDay = coins })
  end

  -- Red, a won wild fight: the pot into the wallet, and the cart's line owed.
  local redGame = gameWith({ mon("CHARMANDER") }, K_RED)
  redGame.save.money = 1000
  local f = payFight(redGame, {})
  won(f, 120)
  eq(moneyOf(redGame), 1120, "Pay Day (Red): a won wild fight pays the pot")
  eq(f.payDayPaid, 120, "Pay Day (Red): ...and says what it paid")
  eq(f.payDayLine, "ANN picked up\n¥120!", "Pay Day (Red): the cart's line (_PickUpPayDayMoneyText)")
  check(f:sayPayDay3(), "Pay Day: the line is said once the ending has printed")
  eq(f.payDayLine, nil, "Pay Day: ...once")
  won(f, 120)
  eq(moneyOf(redGame), 1120, "Pay Day: a second outcome pays nothing more")

  -- Red pays a flee too (wBattleResult stays 0); Gold does not (a DRAW).
  local fleeGame = gameWith({ mon("CHARMANDER") }, K_RED)
  fleeGame.save.money = 0
  lost(payFight(fleeGame, {}), 40, "run")
  eq(moneyOf(fleeGame), 40, "Pay Day (Red): a flee picks the coins up too")
  local lossGame = gameWith({ mon("CHARMANDER") }, K_RED)
  lossGame.save.money = 0
  lost(payFight(lossGame, {}), 40, "ko")
  eq(moneyOf(lossGame), 0, "Pay Day (Red): a lost fight pays nothing")
  local goldFlee = goldGame({ goldMon("CHARMANDER", nil, 4321) })
  lost(payFight(goldFlee, {}), 40, "run")
  eq(moneyOf(goldFlee), 0, "Pay Day (Gold): a flee is a DRAW and pays nothing (CheckPayDay)")

  -- Gold: doubled under an AMULET COIN this player fielded.
  local coinGame = goldGame({ goldMon("CHARMANDER", "AMULET_COIN", 4321) })
  local coin = payFight(coinGame, { mode = "coop_npc" })
  coin:onEvent({ battle = coin.battle, seq = 1, t = "send", slot = 0, side = "a", mon = 0,
                 text = "CHARMANDER", hp = 30 })
  won(coin, 50)
  eq(moneyOf(coinGame), 100, "Pay Day (Gold): an AMULET COIN doubles the pot (CheckPayDay)")
  eq(coin.payDayLine, "GOLD picked up\n¥100!", "Pay Day (Gold): ...and the line names the doubled pot")
  local plainGold = goldGame({ goldMon("CHARMANDER", nil, 4321) })
  won(payFight(plainGold, {}), 50)
  eq(moneyOf(plainGold), 50, "Pay Day (Gold): no coin, the pot as it is")

  -- Never between players, never to side b, and the wallet's cap.
  local linkGame = gameWith({ mon("CHARMANDER") }, K_RED)
  linkGame.save.money = 0
  won(payFight(linkGame, { mode = "1v1" }), 120)
  eq(moneyOf(linkGame), 0, "Pay Day: a link fight pays nothing")
  local sideB = gameWith({ mon("CHARMANDER") }, K_RED)
  sideB.save.money = 0
  local bFight = payFight(sideB, { role = "guest", mode = "coop_npc" })
  bFight:onOutcome({ battle = bFight.battle, outcome = "win", winners = { "me" },
                     losers = { "npc" }, reason = "ko", payDay = 120 })
  eq(moneyOf(sideB), 0, "Pay Day: a player on side b is not paid side a's pot")
  local rich = gameWith({ mon("CHARMANDER") }, K_RED)
  rich.save.money = 999990
  won(payFight(rich, {}), 120)
  eq(moneyOf(rich), 999999, "Pay Day: the wallet stops at 999999 (AddBCD / MAX_MONEY)")

  -- Through Sessions: the outcome is read in the boot's dialect, so a Red
  -- pot past Gen 3's u16 still arrives.
  local h = harness("host", { mon("CHARMANDER") })
  h.game.save.money = 0
  check(h.sessions:beginWildMediated(h.game, "pw", { mon = mon("SQUIRTLE") }), "Pay Day: a wild fight opens")
  h.sessions.fight:onReady({ battle = "pw", sides = { a = { "me" }, b = { "npc" } } })
  h.sessions:onBattleOutcome({ battle = "pw", outcome = "win", winners = { "me" },
                               losers = { "npc" }, reason = "ko", payDay = 70000 })
  eq(Gen.money.get(h.game.save), 70000, "Pay Day: Sessions reads a Red pot past 65535 (K11's bound)")
end

-- ------- beginWildMediated rolls Gold's wild item
do
  local wildData = goldData()
  wildData.pokemon = { SQUIRTLE = { name = "SQUIRTLE", types = { "WATER" }, items = { "BERRY", "NUGGET" } },
                       CHARMANDER = DATA.pokemon.CHARMANDER }
  local h = harness("host", {})
  h.game = goldGame({ goldMon("CHARMANDER", nil, 4321) }, wildData)
  local wild = goldMon("SQUIRTLE")
  local draws = { 255, 19 }
  local i = 0
  check(h.sessions:beginWildMediated(h.game, "wi", { mon = wild,
          random = function() i = i + 1; return draws[i] end }), "wild item: the fight opens")
  eq(wild.item, "NUGGET", "wild item: beginWildMediated rolls it onto the engine monster (rollWildItem2)")
  local foe
  for _, e in ipairs(h.sent) do
    if e.type == Wire.BATTLE_PARTY and e.payload.side == "b" then foe = e.payload end
  end
  eq(foe and foe.mons[1] and foe.mons[1].heldItem, "NUGGET", "wild item: ...and the uploaded foe sheet holds it")
  -- Red rolls nothing.
  local r = harness("host")
  local redWild = mon("SQUIRTLE")
  r.sessions:beginWildMediated(r.game, "wr", { mon = redWild, random = function() return 255 end })
  eq(redWild.item, nil, "wild item: a Red wild monster holds nothing")
end

-- ------------------------------------------------------------------
-- closing the Red / Gold referee gaps: wave 3 (task C2a)
-- ------------------------------------------------------------------
--
-- Red's Pay Day on the escapes that pay (the referee states the pot on a
-- `run` only for a TELEPORT / ROAR / WHIRLWIND / POKé DOLL escape; the
-- player's own RUN writes wBattleResult 2 and states none); a foe's Gold
-- happiness is the cart's BASE_HAPPINESS; and the Transform overlay ends with
-- its wearer -- at the send-out and at the faint -- so the party list a Gold
-- referee states behind it (a MYSTERYBERRY restored under Transform) reaches
-- the sheet, as does a benched monster's list.  Numbers invented.

-- ------- Pay Day on a Red escape
do
  local function payFight(game, opts)
    local fight = Mediated.new({ transport = { send = function() return true end },
      game = game, battle = "pe", role = "host", mode = opts.mode or "wild", peerId = "npc" })
    fight:start(game)
    return fight
  end
  local function fresh()
    local game = gameWith({ mon("CHARMANDER") }, K_RED)
    game.save.money = 0
    return game
  end
  -- The foe's TELEPORT / ROAR, or our POKé DOLL: side a is the winner.
  local foeFled = fresh()
  payFight(foeFled, {}):onOutcome({ battle = "pe", outcome = "win", winners = { "me" },
                                    losers = { "npc" }, reason = "run", payDay = 30 })
  eq(Gen.money.get(foeFled.save), 30, "Pay Day (Red escape): a foe that flees leaves the pot to pick up")
  -- Our TELEPORT: side a fled, and is still the one the pot is counted for.
  local weFled = fresh()
  local wf = payFight(weFled, {})
  wf:onOutcome({ battle = "pe", outcome = "win", winners = { "npc" },
                 losers = { "me" }, reason = "run", payDay = 30 })
  eq(Gen.money.get(weFled.save), 30, "Pay Day (Red escape): our own TELEPORT pays too, though we are in `losers`")
  eq(wf.payDayLine, "ANN picked up\n¥30!", "Pay Day (Red escape): ...with the cart's line")
  -- The player's RUN: the referee states no pot, and nothing is paid.
  local ran = fresh()
  payFight(ran, {}):onOutcome({ battle = "pe", outcome = "win", winners = { "npc" },
                                losers = { "me" }, reason = "run" })
  eq(Gen.money.get(ran.save), 0, "Pay Day (Red RUN): an outcome stating no pot pays nothing")
  -- Never in a link fight, whatever the outcome carries.
  local linked = fresh()
  payFight(linked, { mode = "1v1" }):onOutcome({ battle = "pe", outcome = "win", winners = { "npc" },
                                                 losers = { "me" }, reason = "run", payDay = 30 })
  eq(Gen.money.get(linked.save), 0, "Pay Day (Red escape): a link fight pays nothing")
  -- Gold: every escape is a DRAW (ExitBattle skips CheckPayDay), even a foe's
  -- that leaves side a named the winner -- whatever a run carries.
  local goldFled = goldGame({ goldMon("CHARMANDER", nil, 4321) })
  local gf = Mediated.new({ transport = { send = function() return true end },
    game = goldFled, battle = "pe", role = "host", mode = "wild", peerId = "npc" })
  gf:start(goldFled)
  gf:onOutcome({ battle = "pe", outcome = "win", winners = { "me" },
                 losers = { "npc" }, reason = "run", payDay = 30 })
  eq(Gen.money.get(goldFled.save), 0, "Pay Day (Gold escape): a foe's flight pays nothing, even with side a the winner")
  eq(gf.payDayLine, nil, "Pay Day (Gold escape): ...and owes no line")
  -- Through Sessions: the outcome is read through the wire, which keeps a
  -- Red run's pot.
  local h = harness("host", { mon("CHARMANDER") })
  h.game.save.money = 0
  check(h.sessions:beginWildMediated(h.game, "pr", { mon = mon("SQUIRTLE") }), "Pay Day (Red escape): a wild fight opens")
  h.sessions.fight:onReady({ battle = "pr", sides = { a = { "me" }, b = { "npc" } } })
  h.sessions:onBattleOutcome({ battle = "pr", outcome = "win", winners = { "npc" },
                               losers = { "me" }, reason = "run", payDay = 25 })
  eq(Gen.money.get(h.game.save), 25, "Pay Day (Red escape): Sessions pays a run's pot read off the wire")
end

-- ------- K14 on a foe's Gold sheet: BASE_HAPPINESS
do
  local fond = goldMon("CHARMANDER", nil, 4321)
  fond.happiness = 200
  local game = goldGame({ fond })
  eq(Mediated.BASE_HAPPINESS2, 70, "K14 foe: BASE_HAPPINESS is 70 (pokecrystal pokemon_data_constants.asm)")
  eq(Mediated.snapshotParty(game)[1].happiness, 200, "K14 own: the player's own monster sends its own")
  eq(Mediated.snapshotParty(game, { link = true })[1].happiness, 200,
     "K14 own: ...in a link fight too (InitEnemyMon copies the other cart's party struct)")
  local wild = goldMon("SQUIRTLE")
  wild.happiness = 255
  eq(Mediated.snapshotMons(game, { wild })[1].happiness, 70,
     "K14 foe: a wild monster is described at BASE_HAPPINESS (LoadEnemyMon .Happiness)")
  local plain = goldMon("SQUIRTLE")
  plain.happiness = nil
  eq(Mediated.snapshotMons(game, { plain })[1].happiness, 70,
     "K14 foe: ...as is one whose engine record states none")
  local trainerMon = goldMon("SQUIRTLE", "BERRY")
  trainerMon.happiness = 0
  local foeSheet = Mediated.snapshotMons(game, { trainerMon })[1]
  eq(foeSheet.happiness, 70, "K14 foe: ...and a trainer's (the same .Happiness, every trainer battle)")
  local packed = Wire.battleParty({ battle = "k14f", mons = { foeSheet }, generation = 2 })
  eq(packed and packed.mons[1].happiness, 70, "K14 foe: ...which the wire carries")
  eq(Mediated.snapshotMons(gameWith({}, K_RED), { mon("CHARMANDER") })[1].happiness, nil,
     "K14 foe: a Red foe states none (Red has no happiness byte)")
end

-- ------- the Transform overlay ends with its wearer (Gold's MYSTERYBERRY)
do
  local function overlayFight()
    local holder = goldMon("CHARMANDER", "MYSTERYBERRY", 4321)
    holder.moves = { { id = "EMBER", pp = 0 }, { id = "GROWL", pp = 40 } }
    local bench = goldMon("SQUIRTLE", nil, 4321)
    bench.moves = { { id = "HYDRO", pp = 1 } }
    local game = goldGame({ holder, bench })
    local fight = Mediated.new({ transport = { send = function() return true end },
      game = game, battle = "ov", role = "host", mode = "wild", peerId = "npc" })
    fight:start(game)
    local seq = 0
    local function ev(fields)
      seq = seq + 1
      fields.battle, fields.seq = "ov", seq
      fight:onEvent(fields)
    end
    ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
    -- TRANSFORM: the referee's copied list, stated with no `mon`.
    ev({ t = "moves", slot = 0, side = "a", moves = { { id = "TACKLE", pp = 5, maxPp = 5 } } })
    return fight, ev
  end
  local party = { { id = "EMBER", pp = 5, maxPp = 25 }, { id = "GROWL", pp = 40, maxPp = 40 } }

  -- The faint: the overlay goes, and the party list stated behind it is the sheet's.
  local fight, ev = overlayFight()
  eq(fight.liveMoves and fight.liveMoves[1].id, "TACKLE", "overlay: Transform's copies are what FIGHT reads")
  ev({ t = "faint", slot = 0, side = "a", text = "CHARMANDER", amount = 1 })
  eq(fight.liveMoves, nil, "overlay: the faint ends it (the referee gives the fallen monster its own list back)")
  ev({ t = "moves", slot = 0, side = "a", mon = 0, moves = party })
  eq(fight.mine[1].moves[1].pp, 5,
     "MYSTERYBERRY under Transform (faint): the party PP the referee states lands on the sheet")
  eq(fight.liveMoves, nil, "MYSTERYBERRY under Transform (faint): ...and is no new overlay")

  -- The send-out: the same list, stated behind the switch.
  fight, ev = overlayFight()
  ev({ t = "switch", slot = 0, side = "a", mon = 1, text = "SQUIRTLE" })
  ev({ t = "send", slot = 0, side = "a", mon = 1, text = "SQUIRTLE", hp = 30 })
  ev({ t = "moves", slot = 0, side = "a", mon = 0, moves = party })
  eq(fight.mine[1].moves[1].pp, 5, "MYSTERYBERRY under Transform (switch-out): the party PP lands on the sheet")
  eq(fight.liveMoves, nil, "MYSTERYBERRY under Transform (switch-out): ...with no overlay up")

  -- A benched monster's list, while the one standing here wears an overlay.
  fight, ev = overlayFight()
  ev({ t = "moves", slot = 0, side = "a", mon = 1, moves = { { id = "HYDRO", pp = 4, maxPp = 5 } } })
  eq(fight.mine[2].moves[1].pp, 4, "overlay: a benched monster's list writes its own sheet")
  eq(fight.liveMoves and fight.liveMoves[1].id, "TACKLE", "overlay: ...and the overlay stands")
  -- The one standing here: its PP spend still refreshes the overlay.
  ev({ t = "moves", slot = 0, side = "a", mon = 0, moves = { { id = "TACKLE", pp = 4, maxPp = 5 } } })
  eq(fight.liveMoves and fight.liveMoves[1].pp, 4, "overlay: the wearer's own spend refreshes it")
  eq(fight.mine[1].moves[1].id, "EMBER", "overlay: ...and never writes the sheet")
end

-- ------------------------------------------------------------------
-- closing the Red / Gold referee gaps: wave 4 (task C2b)
-- ------------------------------------------------------------------
--
-- Gold's SKETCH written home (fights against the computer, our own seat);
-- Red's MIMIC pick off the foe's list and its slot's PP; a TOXIC saved as
-- PSN; Gold's wTimeOfDay on the ruleset; Gold's weather off its lines; the
-- trainer's whole name; FIGHT with no move list during a Gold Bide and a Red
-- monster asleep.  Every number and move row here is invented.

-- A recording transport the screen can send on.
local function recorder()
  local sent = {}
  return {
    sent = sent,
    isReady = function() return true end,
    send = function(_, msgType, payload)
      sent[#sent + 1] = { t = msgType, p = payload }
      return true
    end,
  }
end
local function choicesOf(transport)
  local out = {}
  for _, m in ipairs(transport.sent) do
    if m.t == Wire.BATTLE_CHOICE then out[#out + 1] = m.p end
  end
  return out
end
local function screenFor(game, mode, battle, opts)
  opts = opts or {}
  local transport = recorder()
  local fight = Mediated.new({ transport = transport, game = game, battle = battle,
    role = "host", mode = mode, peerId = "npc", trainer = opts.trainer,
    wildParty = opts.wildParty, npcParty = opts.npcParty, peerName = opts.peerName })
  fight:start(game)
  local seq = 0
  local function ev(fields)
    seq = seq + 1
    fields.battle, fields.seq = battle, seq
    fight:onEvent(fields)
  end
  return fight, ev, transport
end

-- An invented Gold move table with a SKETCH in it.
local SKETCH_DATA = setmetatable({
  moves = {
    SKETCH = { name = "SKETCH", power = 0, accuracy = 100, type = "NORMAL", pp = 1,
               effect = "EFFECT_SKETCH" },
    TACKLE = { name = "TACKLE", power = 35, accuracy = 95, type = "NORMAL", pp = 30 },
    SPORE = { name = "SPORE", power = 0, accuracy = 100, type = "NORMAL", pp = 13,
              effect = "EFFECT_SLEEP" },
    GROWL = { name = "GROWL", power = 0, accuracy = 100, type = "NORMAL", pp = 40 },
    BIDE = { name = "BIDE", power = 0, accuracy = 100, type = "NORMAL", pp = 9,
             effect = "EFFECT_BIDE" },
  },
  items = GOLD_ITEMS,
  pokemon = { CHARMANDER = DATA.pokemon.CHARMANDER, SQUIRTLE = DATA.pokemon.SQUIRTLE },
}, { __index = DATA })

local function painter()
  local m = goldMon("CHARMANDER", nil, 4321)
  m.moves = { { id = "TACKLE", pp = 20, maxPp = 30 },
              { id = "SKETCH", pp = 1, maxPp = 1, ppUps = 2 } }
  return m
end
local TACKLE20 = { id = "TACKLE", pp = 20, maxPp = 30 }

-- ------- SKETCH, written home (Gold, 1v1 screen)
do
  local m = painter()
  local game = goldGame({ m }, SKETCH_DATA)
  local fight, ev = screenFor(game, "wild", "sk")
  ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  -- SKETCH's own PP spend first (ids unchanged), then the sketch.
  ev({ t = "moves", slot = 0, side = "a", mon = 0,
       moves = { TACKLE20, { id = "SKETCH", pp = 0, maxPp = 1 } } })
  eq(m.moves[2].id, "SKETCH", "SKETCH home: a PP spend is not a sketch")
  ev({ t = "moves", slot = 0, side = "a", mon = 0,
       moves = { TACKLE20, { id = "SPORE", pp = 13, maxPp = 13 } } })
  eq(m.moves[2].id, "SPORE", "SKETCH home: the party monster's SKETCH slot takes the move (BattleCommand_Sketch .user_trainer)")
  eq(m.moves[2].pp, 13, "SKETCH home: ...at the referee's PP, the move's base")
  eq(m.moves[2].maxPp, 13, "SKETCH home: ...out of the move's base PP")
  eq(m.moves[2].ppUps, nil, "SKETCH home: ...and the slot's PP Ups are gone (the bare base PP byte)")
  eq(m.moves[1].id, "TACKLE", "SKETCH home: every other slot is untouched")
  eq(fight.mine[1].moves[2].id, "SPORE", "SKETCH home: the sheet takes the move too")
  eq(fight.mine[1].moves[2].effect, need("BattleSim2/Effects").idOf("EFFECT_SLEEP"),
     "SKETCH home: ...rebuilt off the record (its effect), as the upload described every move")
  ev({ t = "moves", slot = 0, side = "a", mon = 0,
       moves = { TACKLE20, { id = "SPORE", pp = 12, maxPp = 13 } } })
  eq(fight.mine[1].moves[2].pp, 12, "SKETCH home: a later spend of the sketched move lands on the sheet")

  -- A link fight never writes home (the cart refuses SKETCH there).
  local linked = painter()
  local lgame = goldGame({ linked }, SKETCH_DATA)
  local _, lev = screenFor(lgame, "1v1", "skl")
  lev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  lev({ t = "moves", slot = 0, side = "a", mon = 0,
        moves = { TACKLE20, { id = "SPORE", pp = 13, maxPp = 13 } } })
  eq(linked.moves[2].id, "SKETCH", "SKETCH home: a fight between players writes nothing home")

  -- A TRANSFORM (no `mon`) is an overlay, never written home -- even one
  -- whose list differs from the party only in the SKETCH slot.
  local worn = painter()
  local wgame = goldGame({ worn }, SKETCH_DATA)
  local wf, wev = screenFor(wgame, "wild", "skt")
  wev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  wev({ t = "moves", slot = 0, side = "a",
        moves = { { id = "TACKLE", pp = 5, maxPp = 5 }, { id = "GROWL", pp = 5, maxPp = 5 } } })
  eq(worn.moves[2].id, "SKETCH", "SKETCH home: a TRANSFORM overlay is not written home")
  eq(wf.liveMoves and wf.liveMoves[2].id, "GROWL", "SKETCH home: ...it is what FIGHT reads")
  -- ...and a PP spend under it (ids unchanged against the overlay) neither.
  wev({ t = "moves", slot = 0, side = "a", mon = 0,
        moves = { { id = "TACKLE", pp = 4, maxPp = 5 }, { id = "GROWL", pp = 5, maxPp = 5 } } })
  eq(worn.moves[1].pp, 20, "SKETCH home: a spend under the overlay leaves the party alone")

  -- The cart's bug: a TRANSFORMed user that copied a SKETCH may use it, and
  -- the party's slot it writes is the battle list's SKETCH slot.
  local bug = painter()
  bug.moves[1] = { id = "GROWL", pp = 40, maxPp = 40 }
  bug.moves[2] = { id = "TACKLE", pp = 30, maxPp = 30 }
  local bgame = goldGame({ bug }, SKETCH_DATA)
  local _, bev = screenFor(bgame, "wild", "skb")
  bev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  bev({ t = "moves", slot = 0, side = "a",
        moves = { { id = "SKETCH", pp = 1, maxPp = 1 }, { id = "TACKLE", pp = 5, maxPp = 5 } } })
  bev({ t = "moves", slot = 0, side = "a", mon = 0,
        moves = { { id = "SPORE", pp = 13, maxPp = 13 }, { id = "TACKLE", pp = 5, maxPp = 5 } } })
  eq(bug.moves[1].id, "SPORE", "SKETCH home (the TRANSFORM bug): the party slot under the copied SKETCH takes it")
  eq(bug.moves[2].pp, 30, "SKETCH home (the TRANSFORM bug): ...and nothing else of the copies")

  -- The referee's own reading of that bug (BattleSim2 Turn `_sketch`): the
  -- copies are stated as an overlay (no `mon`), and the party list Transform
  -- put aside -- the sketched move in it -- once Transform is undone, behind
  -- the faint: that list is the one written home.
  local bug2 = painter()
  local b2game = goldGame({ bug2 }, SKETCH_DATA)
  local b2f, b2ev = screenFor(b2game, "wild", "skb2")
  b2ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  b2ev({ t = "moves", slot = 0, side = "a",
         moves = { { id = "GROWL", pp = 5, maxPp = 5 }, { id = "SPORE", pp = 13, maxPp = 13 } } })
  eq(bug2.moves[2].id, "SKETCH", "SKETCH home (TRANSFORMed): the overlay alone writes nothing")
  b2ev({ t = "faint", slot = 0, side = "a", text = "CHARMANDER", amount = 0 })
  b2ev({ t = "moves", slot = 0, side = "a", mon = 0,
         moves = { TACKLE20, { id = "SPORE", pp = 13, maxPp = 13 } } })
  eq(bug2.moves[2].id, "SPORE", "SKETCH home (TRANSFORMed): the party list stated behind the faint is written home")
  eq(b2f.mine[1].moves[2].id, "SPORE", "SKETCH home (TRANSFORMed): ...and the sheet")

  -- Red has no SKETCH to write.
  eq(Mediated.sketchHome(gameWith({}, K_RED), "wild", { { id = "SKETCH" } },
       { { id = "TACKLE" } }, { moves = { { id = "SKETCH" } } }), nil,
     "SKETCH home: Red never writes one")
  -- Two slots changed is not a sketch.
  eq(Mediated.sketchedSlots(game, { { id = "SKETCH" }, { id = "GROWL" } },
       { { id = "SPORE" }, { id = "TACKLE" } }), nil,
     "SKETCH home: a list that differs past the SKETCH slot is not one")
end

-- ------- Red's MIMIC: its slot's PP is MIMIC's own
local K_MIMIC = setmetatable({ moves = setmetatable({
  MIMIC = { name = "MIMIC", power = 0, accuracy = 100, type = "NORMAL", pp = 10,
            effect = "MIMIC_EFFECT" },
}, { __index = K_RED.moves }) }, { __index = K_RED })
do
  local copycat = mon("CHARMANDER", { moves = { { id = "MIMIC", pp = 10 }, { id = "TACKLE", pp = 30 } } })
  local game = gameWith({ copycat }, K_MIMIC)
  local fight, ev = screenFor(game, "wild", "mp")
  ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  ev({ t = "moves", slot = 0, side = "a", mon = 0,
       moves = { { id = "MIMIC", pp = 9, maxPp = 10 }, { id = "TACKLE", pp = 30, maxPp = 35 } } })
  ev({ t = "moves", slot = 0, side = "a",
       moves = { { id = "EMBER", pp = 9, maxPp = 10 }, { id = "TACKLE", pp = 30, maxPp = 35 } } })
  check(fight.liveMovesMimic == true, "MIMIC PP (Red): the overlay is read as a MIMIC")
  ev({ t = "moves", slot = 0, side = "a", mon = 0,
       moves = { { id = "EMBER", pp = 8, maxPp = 10 }, { id = "TACKLE", pp = 30, maxPp = 35 } } })
  eq(fight.liveMoves[1].pp, 8, "MIMIC PP (Red): FIGHT shows the mimicked move's PP")
  eq(fight.mine[1].moves[1].id, "MIMIC", "MIMIC PP (Red): the sheet keeps MIMIC")
  eq(fight.mine[1].moves[1].pp, 8, "MIMIC PP (Red): ...and pays its PP (pokered DecrementPP spends the party's slot)")
  -- A TRANSFORM spends none of the party's (DecrementPP returns while TRANSFORMED).
  ev({ t = "moves", slot = 0, side = "a",
       moves = { { id = "GROWL", pp = 5, maxPp = 5 }, { id = "EMBER", pp = 5, maxPp = 5 } } })
  check(fight.liveMovesMimic == false, "MIMIC PP (Red): a TRANSFORM overlay is not a MIMIC")
  ev({ t = "moves", slot = 0, side = "a", mon = 0,
       moves = { { id = "GROWL", pp = 4, maxPp = 5 }, { id = "EMBER", pp = 5, maxPp = 5 } } })
  eq(fight.mine[1].moves[1].pp, 8, "MIMIC PP (Red): a spend under TRANSFORM leaves the sheet alone")
  -- A TRANSFORM whose copies differ from the party only in the MIMIC slot
  -- (a mirror match through METRONOME) is still no MIMIC: its PP are the
  -- copies' 5, not the party's.
  eq(Mediated.mimicOverlay(game, { { id = "MIMIC", pp = 9 }, { id = "TACKLE", pp = 30 } },
       { { id = "EMBER", pp = 5 }, { id = "TACKLE", pp = 5 } }), false,
     "MIMIC PP (Red): a TRANSFORM matching all but the MIMIC slot is told apart by its PP")
  eq(Mediated.mimicOverlay(game, { { id = "GROWL", pp = 9 }, { id = "TACKLE", pp = 30 } },
       { { id = "EMBER", pp = 9 }, { id = "TACKLE", pp = 30 } }), false,
     "MIMIC PP (Red): a slot that was not MIMIC changing is no MIMIC")
  -- Gold's party never pays for a mimicked move (CheckMimicUsed).
  local gm = goldMon("CHARMANDER", nil, 4321)
  gm.moves = { { id = "MIMIC", pp = 10, maxPp = 10 }, { id = "TACKLE", pp = 30, maxPp = 30 } }
  local ggame = goldGame({ gm }, setmetatable({ moves = K_MIMIC.moves }, { __index = SKETCH_DATA }))
  local gf, gev = screenFor(ggame, "wild", "mpg")
  gev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  gev({ t = "moves", slot = 0, side = "a",
        moves = { { id = "EMBER", pp = 5, maxPp = 5 }, { id = "TACKLE", pp = 30, maxPp = 30 } } })
  check(gf.liveMovesMimic == true, "MIMIC PP (Gold): the overlay is read as a MIMIC (the copy at 5 PP)")
  gev({ t = "moves", slot = 0, side = "a", mon = 0,
        moves = { { id = "EMBER", pp = 4, maxPp = 5 }, { id = "TACKLE", pp = 30, maxPp = 30 } } })
  eq(gf.mine[1].moves[1].pp, 10, "MIMIC PP (Gold): the party's MIMIC pays nothing for the mimicked move (CheckMimicUsed)")
  gev({ t = "moves", slot = 0, side = "a", mon = 0,
        moves = { { id = "EMBER", pp = 4, maxPp = 5 }, { id = "TACKLE", pp = 29, maxPp = 30 } } })
  eq(gf.mine[1].moves[2].pp, 29, "MIMIC PP (Gold): ...while its other slots' spends still reach the party")
  eq(gf.mine[1].moves[1].pp, 10, "MIMIC PP (Gold): ...and MIMIC's stays")
end

-- ------- Red's MIMIC pick
do
  local copycat = mon("CHARMANDER", { moves = { { id = "MIMIC", pp = 10 }, { id = "TACKLE", pp = 30 } } })
  local game = gameWith({ copycat }, K_MIMIC)
  local foe = Mediated.snapshotMons(game, { mon("SQUIRTLE", { moves = {
    { id = "GROWL", pp = 40 }, { id = "EMBER", pp = 25 } } }) })
  local fight, ev, transport = screenFor(game, "wild", "mk", { wildParty = foe })
  local FOE = Config.COOP_SIDE
  ev({ t = "send", slot = FOE, side = "b", mon = 0, text = "SQUIRTLE", hp = 30 })
  ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  local input = fakeInput()
  fight.lines, fight.shown, fight.anim = {}, nil, nil
  fight.phase = "move"
  fight.cursor = 1
  input.press("a")
  fight:updateMoveMenu(input)
  eq(fight.phase, "mimic", "MIMIC pick (Red): MIMIC opens the foe's move list first")
  eq(#choicesOf(transport), 0, "MIMIC pick (Red): ...and sends nothing yet")
  local rows = fight:mimicRows()
  eq(#rows, 2, "MIMIC pick (Red): the list is the foe's moves")
  eq(rows[2] and rows[2].label, "EMBER", "MIMIC pick (Red): ...by name")
  input.press("b")
  fight:updateMimic(input)
  eq(fight.phase, "move", "MIMIC pick (Red): B goes back to the move list")
  input.press("a")
  fight:updateMoveMenu(input)
  input.press("down")
  fight:updateMimic(input)
  input.press("a")
  fight:updateMimic(input)
  local sent = choicesOf(transport)
  eq(#sent, 1, "MIMIC pick (Red): the pick sends the choice")
  eq(sent[1] and sent[1].move, 0, "MIMIC pick (Red): ...MIMIC's slot")
  eq(sent[1] and sent[1].mimic, 1, "MIMIC pick (Red): ...with the foe's second move, 0-based (choice.mimic)")
  check(sent[1] and Wire.battleChoice(sent[1], 1) ~= nil, "MIMIC pick (Red): ...which a Red hub reads")
  -- The foe's own TRANSFORM / MIMIC list is the one listed.
  ev({ t = "moves", slot = FOE, side = "b", moves = { { id = "TACKLE", pp = 5 } } })
  eq(fight:mimicRows()[1].label, "TACKLE", "MIMIC pick (Red): a foe's TRANSFORM list is what it holds now")
  -- A link fight asks nothing (the cart picks at random for both sides).
  local lgame = gameWith({ mon("CHARMANDER", { moves = { { id = "MIMIC", pp = 10 } } }) }, K_MIMIC)
  local lf, lev, lt = screenFor(lgame, "1v1", "mkl", { wildParty = foe })
  lev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  check(lf:pickMove(1), "MIMIC pick (Red link): MIMIC sends at once")
  eq(choicesOf(lt)[1] and choicesOf(lt)[1].mimic, nil, "MIMIC pick (Red link): ...with no pick")
  -- Gold's MIMIC copies the last move with no menu.
  local gm = goldMon("CHARMANDER", nil, 4321)
  gm.moves = { { id = "MIMIC", pp = 10, maxPp = 10 } }
  local gg = goldGame({ gm }, setmetatable({ moves = K_MIMIC.moves }, { __index = SKETCH_DATA }))
  local gf, gev = screenFor(gg, "wild", "mkg", { wildParty = foe })
  gev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  check(gf:pickMove(1), "MIMIC pick (Gold): no pick is asked")
end

-- ------- a TOXIC is saved as PSN (Red / Gold)
do
  local red = mon("CHARMANDER")
  local game = gameWith({ red }, K_RED)
  local fight, ev = screenFor(game, "wild", "tx")
  ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  ev({ t = "status", slot = 0, side = "a", status = "TOX" })
  eq(red.status, "PSN", "TOX (Red): the party's status byte holds PSN (BADLY_POISONED is a battle flag)")
  eq(fight.mine[1].status, "TOX", "TOX (Red): ...the fight's own sheet keeps the referee's TOX")
  local gold = goldMon("CHARMANDER", nil, 4321)
  local ggame = goldGame({ gold })
  local _, gev = screenFor(ggame, "wild", "txg")
  gev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  gev({ t = "status", slot = 0, side = "a", status = "TOX" })
  eq(gold.status, "PSN", "TOX (Gold): PSN too (SUBSTATUS_TOXIC is a battle flag)")
  eq(Mediated.partyStatus12("TOX", 3), "TOX", "TOX: Gen 3 keeps its own (STATUS1_TOXIC_POISON)")
  eq(Mediated.partyStatus12("BRN", 1), "BRN", "TOX: every other token passes through")
end

-- ------- Gold's wTimeOfDay on the ruleset
do
  local saved = stubMod.world
  local ow = { timeOfDayId = function() return 2 end }
  stubMod.world = { overworld = function() return ow end }
  local gold = goldGame({ goldMon("CHARMANDER", nil, 4321) })
  local ruleset = Mediated.snapshotRuleset(gold)
  eq(ruleset.timeOfDay, "nite", "timeOfDay: the engine battle's wTimeOfDay (World:timeOfDayId 2 = NITE_F)")
  local packed = Wire.battleRuleset(ruleset, 2)
  eq(packed and packed.timeOfDay, "nite", "timeOfDay: ...which a Gold hub reads")
  ow = { tod = "MORN" }
  eq(Mediated.timeOfDay2(gold), "morn", "timeOfDay: the overworld's clock word when it has no id")
  ow = { hour = function() return 12 end }
  local okP, Palettes = pcall(require, "src.world.gen2.Palettes")
  if okP and type(Palettes) == "table" and Palettes.clockDaytime then
    eq(Mediated.timeOfDay2(gold), (Palettes.clockDaytime(12)):lower(),
       "timeOfDay: ...else the clock EvolveFx reads, at the overworld's hour")
  end
  ow = nil
  eq(Mediated.timeOfDay2(gold), nil, "timeOfDay: no overworld states none (the referee's own-time reading)")
  ow = { timeOfDayId = function() return 2 end }
  eq(Mediated.snapshotRuleset(gameWith({}, K_RED)).timeOfDay, nil, "timeOfDay: Red has no clock")
  stubMod.world = saved
end

-- ------- Gold's weather, off the referee's lines
do
  local Effects2 = need("BattleSim2/Effects")
  local game = goldGame({ goldMon("CHARMANDER", nil, 4321) })
  local fight, ev = screenFor(game, "wild", "wx")
  ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  local function drain() for _ = 1, 40 do fight:update(2.0) end end
  drain()
  ev({ t = "msg", text = Effects2.WEATHER_LINES.rain.start })
  eq(fight.weatherShown, nil, "weather (Gold): the sky waits for its line")
  drain()
  eq(fight.weatherShown, "RAIN", "weather (Gold): RAIN DANCE's line brings the rain")
  ev({ t = "msg", text = Effects2.WEATHER_LINES.sandstorm.continues })
  drain()
  eq(fight.weatherShown, "SAND", "weather (Gold): a continuation names the sky too")
  ev({ t = "msg", text = Effects2.WEATHER_LINES.sandstorm.ended })
  drain()
  eq(fight.weatherShown, nil, "weather (Gold): the end clears it")
  eq(Mediated.weatherOfLine2("CHARMANDER used TACKLE"), nil, "weather (Gold): any other line names nothing")
  -- Red never reads one, whatever the line.
  local red = gameWith({ mon("CHARMANDER") }, K_RED)
  local rf, rev = screenFor(red, "wild", "wxr")
  rev({ t = "msg", text = Effects2.WEATHER_LINES.rain.start })
  for _ = 1, 40 do rf:update(2.0) end
  eq(rf.weatherShown, nil, "weather (Red): no sky")
  -- The arena paints Gold's (the Gen 3 painter, ungated for Gold).
  local Battlefield = need("Battlefield")
  eq(Battlefield.layout({ weather = "RAIN" }).weather, "RAIN", "weather: the arena's layout carries it")
end

-- ------- the trainer's whole name (Red / Gold 1v1)
do
  local game = goldGame({ goldMon("CHARMANDER", nil, 4321) })
  local fight = screenFor(game, "coop_npc", "tn", { peerName = "YOUNGSTER",
    trainer = { name = "YOUNGSTER JOEY", classId = "YOUNGSTER" } })
  fight:onReady({ battle = "tn", mode = "coop_npc", sides = { a = { "me" }, b = { "npc" } } })
  local said = table.concat(fight.lines, "|")
  check(said:find("YOUNGSTER JOEY\nwants to battle!", 1, true) ~= nil,
        "trainer name (Gold): the record's whole name, in WantsToBattleText")
  eq(fight:foeTrainerName(), "YOUNGSTER JOEY", "trainer name (Gold): ...and on the send-out line")
  local red = gameWith({ mon("CHARMANDER") }, K_RED)
  local rf = screenFor(red, "coop_npc", "tnr", { peerName = "BIRD",
    trainer = { name = "BIRD KEEPER" } })
  rf:onReady({ battle = "tnr", mode = "coop_npc", sides = { a = { "me" }, b = { "npc" } } })
  local redSaid = {}
  for _, line in ipairs(rf.lines) do
    if type(line) == "string" then redSaid[#redSaid + 1] = line end
  end
  check(table.concat(redSaid, "|"):find("BIRD KEEPER wants\nto fight!", 1, true) ~= nil,
        "trainer name (Red): a class name past ten letters, whole (pokered _TrainerWantsToFightText)")
  local pvp = screenFor(red, "1v1", "tnp", { peerName = "BOB" })
  eq(pvp:foeTrainerName(), "BOB", "trainer name: a fight between players names the peer")
end

-- ------- FIGHT with no move list: a Gold Bide, a Red monster asleep
do
  local bider = goldMon("CHARMANDER", nil, 4321)
  bider.moves = { { id = "TACKLE", pp = 20, maxPp = 30 }, { id = "BIDE", pp = 1, maxPp = 9 } }
  local game = goldGame({ bider }, SKETCH_DATA)
  local fight, ev, transport = screenFor(game, "wild", "bd")
  ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  ev({ t = "turn", amount = 1 })
  check(fight:pickMove(2), "Bide (Gold): BIDE is chosen")
  -- The first turn says only the used line (wave 5: pokecrystal's
  -- StoreEnergy prints nothing while SUBSTATUS_BIDE is clear).
  ev({ t = "msg", text = "CHARMANDER used BIDE!" })
  ev({ t = "moves", slot = 0, side = "a", mon = 0,
       moves = { { id = "TACKLE", pp = 20, maxPp = 30 }, { id = "BIDE", pp = 0, maxPp = 9 } } })
  ev({ t = "turn", amount = 2 })
  check(fight.bideLocked == true, "Bide (Gold): the next turn is a Bide going on")
  local input = fakeInput()
  fight.phase, fight.commandIndex = "choose", 1
  input.press("a")
  fight:updateCommand(input)
  local sent = choicesOf(transport)
  eq(#sent, 2, "Bide (Gold): FIGHT sends at once, no move list (ParsePlayerAction .locked_in)")
  eq(sent[2] and sent[2].move, 1, "Bide (Gold): ...the Bide's slot, past its spent PP")
  eq(fight.phase, "play", "Bide (Gold): ...and the menu closes")
  ev({ t = "msg", text = "CHARMANDER is storing energy!" })
  ev({ t = "turn", amount = 3 })
  check(fight.bideLocked == true, "Bide (Gold): each storing turn keeps it")
  -- The release ends it; so does a turn that never said it stored (a CantMove).
  fight.phase, fight.commandIndex = "choose", 1
  input.press("a")
  fight:updateCommand(input)
  ev({ t = "msg", text = "CHARMANDER unleashed energy!" })
  ev({ t = "turn", amount = 4 })
  check(not fight.bideLocked, "Bide (Gold): the release ends it")
  fight.phase, fight.commandIndex = "choose", 1
  input.press("a")
  fight:updateCommand(input)
  eq(fight.phase, "move", "Bide (Gold): ...and FIGHT opens the move list again")
  local f2, ev2 = screenFor(goldGame({ (function()
    local m = goldMon("CHARMANDER", nil, 4321)
    m.moves = { { id = "BIDE", pp = 9, maxPp = 9 } }
    return m end)() }, SKETCH_DATA), "wild", "bd2")
  ev2({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  f2:pickMove(1)
  ev2({ t = "msg", text = "CHARMANDER used BIDE!" })
  ev2({ t = "turn", amount = 2 })
  f2:sendLockedFight(1)
  ev2({ t = "msg", text = "CHARMANDER's fully paralyzed!" })
  ev2({ t = "turn", amount = 3 })
  check(not f2.bideLocked, "Bide (Gold): a turn with no storing line (a CantMove) ends it")
  -- An item ends one (pokecrystal .reset_bide).
  f2.bideFiled, f2.bideLocked = true, true
  f2:sendChoice({ action = "item", item = "POTION" })
  check(not f2.bideFiled, "Bide (Gold): an item ends it")

  -- Red, asleep: FIGHT opens no move menu (MainInBattleLoop's SLP / FRZ check).
  local sleeper = mon("CHARMANDER", { moves = { { id = "EMBER", pp = 0 }, { id = "TACKLE", pp = 30 } } })
  local rgame = gameWith({ sleeper }, K_RED)
  local rf, rev, rt = screenFor(rgame, "wild", "sl")
  rev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  rev({ t = "status", slot = 0, side = "a", status = "SLP" })
  rf.phase, rf.commandIndex = "choose", 1
  input.press("a")
  rf:updateCommand(input)
  local rs = choicesOf(rt)
  eq(#rs, 1, "asleep (Red): FIGHT sends at once")
  eq(rs[1] and rs[1].move, 0, "asleep (Red): ...last turn's selection, whatever its PP")
  rev({ t = "status", slot = 0, side = "a" })
  rf.phase, rf.commandIndex = "choose", 1
  input.press("a")
  rf:updateCommand(input)
  eq(rf.phase, "move", "asleep (Red): awake, FIGHT opens the move list")
  -- Gold asleep keeps the move list (SLEEP TALK is picked off it).
  local gs = goldMon("CHARMANDER", nil, 4321)
  local gsg = goldGame({ gs })
  local gsf, gsev = screenFor(gsg, "wild", "slg")
  gsev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  gsev({ t = "status", slot = 0, side = "a", status = "SLP" })
  gsf.phase, gsf.commandIndex = "choose", 1
  input.press("a")
  gsf:updateCommand(input)
  eq(gsf.phase, "move", "asleep (Gold): the move list opens")
end

-- ==================================================================
-- wave 5 of docs/plans/gen12-referee-gaps-fix.md (C3): the client rows
-- ==================================================================
-- Every species, move and number below is invented for this file.

-- ------- Red's TypeEffects order on the ruleset (`chartOrder`)
do
  local CH = setmetatable({
    type_chart = {
      types = { GRND = { name = "GRND" }, ROCK = { name = "ROCK" }, BIRD = { name = "BIRD" } },
      matchups = {
        { attacker = "GRND", defender = "ROCK", multiplier = 20 },
        { attacker = "GRND", defender = "BIRD", multiplier = 0 },
        -- no multiplier: writes no cell, so it is no row either
        { attacker = "ROCK", defender = "BIRD" },
        { attacker = "BIRD", defender = "GRND", multiplier = 5 },
      },
    },
  }, { __index = DATA })
  -- Sorted axis: BIRD 0, GRND 1, ROCK 2.
  local red = Mediated.snapshotRuleset(gameWith({}, CH))
  eq(table.concat(red.chartOrder or {}, ","), "1,2,1,0,0,1",
     "chartOrder (Red): TypeEffects' rows in table order, as chart-index pairs")
  eq(red.chart[2][1], 0, "chartOrder (Red): ...each row's multiplier still its chart cell")
  local packed = Wire.battleRuleset(red, 1)
  eq(table.concat(packed and packed.chartOrder or {}, ","), "1,2,1,0,0,1",
     "chartOrder (Red): a Red hub keeps it")
  eq(Mediated.snapshotRuleset(goldWith(CH)).chartOrder, nil,
     "chartOrder: Gold uploads none (its walk leaves the product, not the last row)")
  local empty = setmetatable({ type_chart = { types = { BIRD = {} }, matchups = {} } }, { __index = DATA })
  eq(Mediated.snapshotRuleset(gameWith({}, empty)).chartOrder, nil,
     "chartOrder (Red): a chart with no rows states none (the referee's product reading)")
end

-- ------- K15: Gold's BASE_GENDER byte in the `base` block
do
  local function species(ratio)
    return { name = "GENDERMON", types = { "FIRE" }, genderRatio = ratio,
             baseStats = { hp = 39, attack = 52, defense = 43, speed = 65,
                           specialAttack = 60, specialDefense = 50 } }
  end
  local GD = setmetatable({
    pokemon = { CHARMANDER = species(31), SQUIRTLE = species(255),
                PIDGEY = species(nil) },
    items = GOLD_ITEMS,
  }, { __index = DATA })
  local game = goldGame({ goldMon("CHARMANDER", nil, 4321) }, GD)
  local own = Mediated.snapshotParty(game)[1]
  eq(own and own.base and own.base.gender, 31,
     "K15: our own Gold sheet states the species' gender ratio in `base`")
  local foes = Mediated.snapshotMons(game, { goldMon("SQUIRTLE"), goldMon("PIDGEY") })
  eq(foes[1] and foes[1].base and foes[1].base.gender, 255,
     "K15: ...so does a foe this client describes (GENDER_UNKNOWN 255)")
  check(foes[2] and foes[2].base ~= nil and foes[2].base.gender == nil,
        "K15: a species with no ratio keeps its base block and states no gender")
  local wired = Wire.battleMon(own, 2)
  eq(wired and wired.base and wired.base.gender, 31, "K15: ...which a Gold hub keeps")
  local redSheet = Mediated.snapshotParty(gameWith({ mon("CHARMANDER") },
    setmetatable({ pokemon = { CHARMANDER = species(31) } }, { __index = K_RED })))[1]
  eq(redSheet and redSheet.base and redSheet.base.gender, nil, "K15: Red has no genders")
end

-- ------- Gold's Metronome pool rows state their cart number (`num`)
do
  local PD = setmetatable({
    moves = {
      POUND = { name = "POUND", power = 40, accuracy = 100, type = "NORMAL", pp = 35, index = 1 },
      KARATE_CHOP = { name = "KARATE CHOP", power = 50, accuracy = 100, type = "NORMAL",
                      pp = 25, index = 2 },
      MODMOVE = { name = "MODMOVE", power = 60, accuracy = 100, type = "NORMAL", pp = 10,
                  index = 300 },
      NOINDEX = { name = "NOINDEX", power = 30, accuracy = 100, type = "NORMAL", pp = 10 },
    },
  }, { __index = DATA })
  local rules = Mediated.snapshotRuleset(goldWith(PD))
  local byId = {}
  for _, row in ipairs(rules.metronomePool or {}) do byId[row.id] = row end
  eq(byId.POUND and byId.POUND.num, 1, "pool num (Gold): POUND's row is move 1 (the record's `index`)")
  eq(byId.KARATE_CHOP and byId.KARATE_CHOP.num, 2, "pool num (Gold): ...KARATE CHOP move 2")
  check(byId.MODMOVE ~= nil and byId.MODMOVE.num == nil,
        "pool num (Gold): a number past NUM_ATTACKS is not stated (the wire would refuse it)")
  check(byId.NOINDEX ~= nil and byId.NOINDEX.num == nil, "pool num (Gold): no index states none")
  local packed = Wire.battleRuleset(rules, 2)
  local kept = {}
  for _, row in ipairs(packed and packed.metronomePool or {}) do kept[row.id] = row.num end
  eq(kept.POUND, 1, "pool num (Gold): a Gold hub keeps it")
  local red = Mediated.snapshotRuleset(gameWith({}, PD))
  local anyNum = false
  for _, row in ipairs(red.metronomePool or {}) do if row.num ~= nil then anyNum = true end end
  eq(anyNum, false, "pool num: Red's pool states none (its pick is the row's place)")
end

-- ------- Gold's BATON PASS asks its successor (1v1 / wild / solo screen)
local BP_DATA = setmetatable({
  moves = {
    TACKLE = { name = "TACKLE", power = 35, accuracy = 95, type = "NORMAL", pp = 30 },
    BATON_PASS = { name = "BATON PASS", power = 0, accuracy = 100, type = "NORMAL", pp = 40,
                   effect = "EFFECT_BATON_PASS" },
    BIDE = { name = "BIDE", power = 0, accuracy = 100, type = "NORMAL", pp = 10,
             effect = "BIDE_EFFECT" },
  },
  items = GOLD_ITEMS,
  pokemon = { CHARMANDER = DATA.pokemon.CHARMANDER, SQUIRTLE = DATA.pokemon.SQUIRTLE },
}, { __index = DATA })
local function passer(species, hp)
  local m = goldMon(species, nil, 4321)
  m.hp = hp or 30
  m.moves = { { id = "TACKLE", pp = 30, maxPp = 30 }, { id = "BATON_PASS", pp = 40, maxPp = 40 } }
  return m
end
do
  local input = fakeInput()
  local game = goldGame({ passer("CHARMANDER"), passer("SQUIRTLE", 0), passer("SQUIRTLE") }, BP_DATA)
  local fight, ev, transport = screenFor(game, "1v1", "bp")
  ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  eq(fight:pickMove(2), false, "BATON PASS (Gold): choosing it sends nothing yet")
  eq(fight.phase, "switch", "BATON PASS (Gold): ...the party picker opens (ForcePickSwitchMonInBattle)")
  eq(#choicesOf(transport), 0, "BATON PASS (Gold): ...and nothing is on the wire")
  input.press("b")
  fight:updateSwitch(input)
  eq(fight.phase, "move", "BATON PASS (Gold): B goes back to the move list")
  eq(fight.passMove, nil, "BATON PASS (Gold): ...and drops the pick")
  fight:pickMove(2)
  input.press("a")
  fight:updateSwitch(input)
  local sent = choicesOf(transport)
  eq(#sent, 1, "BATON PASS (Gold): A on a successor sends the move")
  eq(sent[1] and sent[1].move, 1, "BATON PASS (Gold): ...BATON PASS's slot")
  eq(sent[1] and sent[1].pass, 2,
     "BATON PASS (Gold): ...naming the living bench member's party position (the fainted one is not offered)")
  local wired = Wire.battleChoice(sent[1], 2)
  eq(wired and wired.pass, 2, "BATON PASS (Gold): a Gold hub reads `pass`")
  -- Nobody else able to fight: no menu (FailedBatonPass), the move goes as it is.
  local lone = goldGame({ passer("CHARMANDER"), passer("SQUIRTLE", 0) }, BP_DATA)
  local lf, lev, lt = screenFor(lone, "wild", "bp2")
  lev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  check(lf:pickMove(2), "BATON PASS (Gold): with no one to pass to it is sent at once")
  eq(choicesOf(lt)[1] and choicesOf(lt)[1].pass, nil, "BATON PASS (Gold): ...naming nobody")
  -- A switch names the party position the referee matches (`wireSlotOf`):
  -- the sheet's own stamp, not its place in the upload.
  fight.mine[3].slot = 4
  eq(fight:wireSlotOf(3), 4, "wireSlotOf: the sheet's party stamp")
  fight.mine[3].slot = nil
  eq(fight:wireSlotOf(3), 2, "wireSlotOf: ...else its place in the upload")
  -- Red has no BATON PASS to ask about.
  local rf = screenFor(gameWith({ mon("CHARMANDER"), mon("SQUIRTLE") }, K_RED), "wild", "bp3")
  eq(rf:asksPass({ id = "BATON_PASS", effect = 134 }), false, "BATON PASS: Red never asks")
end

-- ------- HEAL BELL written home (Gold), and not in a fight between players
do
  local lead = goldMon("CHARMANDER", nil, 4321)
  local bench = goldMon("SQUIRTLE", nil, 4321)
  bench.status = "SLP"
  local game = goldGame({ lead, bench })
  local fight, ev = screenFor(game, "wild", "hb")
  ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  ev({ t = "status", slot = 0, side = "a", status = "PAR" })
  eq(lead.status, "PAR", "HEAL BELL: (the lead is paralysed)")
  -- The benched member's cure first: the party's, never the standing seat's chip.
  ev({ t = "status", slot = 0, side = "a", mon = 1, text = "SQUIRTLE's status was healed" })
  eq(bench.status, nil, "HEAL BELL (Gold wild): a benched member's status is cleared in the save")
  eq(fight.mine[2].status, nil, "HEAL BELL (Gold wild): ...and on its sheet")
  eq(fight.slots[0].status, "PAR", "HEAL BELL (Gold wild): ...the standing monster's chip is not touched by it")
  ev({ t = "status", slot = 0, side = "a", mon = 0, text = "CHARMANDER's status was healed" })
  eq(lead.status, nil, "HEAL BELL (Gold wild): the standing monster's cure is written home")
  eq(fight.slots[0].status, nil, "HEAL BELL (Gold wild): ...and clears its chip")
  -- A party member this client never uploaded is nobody's.
  ev({ t = "status", slot = 0, side = "a", mon = 5, status = "PSN" })
  eq(lead.status, nil, "HEAL BELL: a `mon` past the upload writes nothing")
  -- A fight between players: the sheets follow, the save does not.
  local pl, pb = goldMon("CHARMANDER", nil, 4321), goldMon("SQUIRTLE", nil, 4321)
  pl.status, pb.status = "BRN", "SLP"
  local pgame = goldGame({ pl, pb })
  local pf, pev = screenFor(pgame, "1v1", "hb2")
  pev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  pev({ t = "status", slot = 0, side = "a", mon = 1, text = "SQUIRTLE's status was healed" })
  pev({ t = "status", slot = 0, side = "a", mon = 0, text = "CHARMANDER's status was healed" })
  eq(pb.status, "SLP", "HEAL BELL (Gold 1v1): the save's benched member keeps its status")
  eq(pl.status, "BRN", "HEAL BELL (Gold 1v1): ...so does the lead")
  eq(pf.mine[2].status, nil, "HEAL BELL (Gold 1v1): ...while the fight's sheets are cured")
end

-- ------- a fight between players writes nothing home (Red and Gold)
do
  for _, gen in ipairs({ 1, 2 }) do
    local m = (gen == 2) and goldMon("CHARMANDER", nil, 4321) or mon("CHARMANDER")
    local game = (gen == 2) and goldGame({ m }) or gameWith({ m }, K_RED)
    local fight, ev = screenFor(game, "1v1", "pv" .. gen)
    ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
    ev({ t = "status", slot = 0, side = "a", status = "PAR" })
    eq(m.status, nil, "PvP (gen " .. gen .. "): a paralysis does not reach the save")
    eq(fight.mine[1].status, "PAR", "PvP (gen " .. gen .. "): ...the fight's own sheet holds it")
    eq(fight.slots[0].status, "PAR", "PvP (gen " .. gen .. "): ...and the seat shows it")
    -- ...against the computer it does (KEEPS_HELD_MODES).
    local w = (gen == 2) and goldMon("CHARMANDER", nil, 4321) or mon("CHARMANDER")
    local wgame = (gen == 2) and goldGame({ w }) or gameWith({ w }, K_RED)
    local _, wev = screenFor(wgame, "wild", "pw" .. gen)
    wev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
    wev({ t = "status", slot = 0, side = "a", status = "PAR" })
    eq(w.status, "PAR", "wild (gen " .. gen .. "): the paralysis is the save's")
  end
end

-- ------- TOX shows PSN on a Red / Gold seat (both carts' HUDs print PSN)
do
  local ClassicBattle = need("ClassicBattle")
  local Battlefield = need("Battlefield")
  eq(ClassicBattle.statusLabel("TOX", false), "PSN", "status glyph: a Red / Gold TOX reads PSN")
  eq(ClassicBattle.statusLabel("TOX", true), "TOX", "status glyph: Gen 3 keeps TOX")
  eq(ClassicBattle.statusLabel("PAR", false), "PAR", "status glyph: every other token as it was")
  eq(ClassicBattle.statusLabel(nil, false), nil, "status glyph: none is none")
  eq(ClassicBattle.statusGlyph({ hp = 5, status = "TOX" }), "PSN",
     "status glyph: the classic party picker prints PSN for TOX off Gen 3")
  eq(Battlefield.cardModel({ hp = 5, maxHp = 9, status = "TOX" }).status, "PSN",
     "status glyph: ...and so does the arena's chip")
end

-- ------- the cart's send-out line (Red: "X sent\nout Y!"; Gold: two screens)
do
  local function lines(fight)
    local out = {}
    for _, l in ipairs(fight.lines or {}) do if type(l) == "string" then out[#out + 1] = l end end
    return out
  end
  local function has(fight, text)
    for _, l in ipairs(lines(fight)) do if l == text then return true end end
    return false
  end
  local rf, rev = screenFor(gameWith({ mon("CHARMANDER") }, K_RED), "1v1", "so1", { peerName = "BLUE" })
  rev({ t = "send", slot = 3, side = "b", mon = 0, text = "SQUIRTLE", hp = 30 })
  check(has(rf, "BLUE sent\nout SQUIRTLE!"), "send-out (Red): pokered _TrainerSentOutText's break")
  local gf, gev = screenFor(goldGame({ goldMon("CHARMANDER", nil, 4321) }), "1v1", "so2",
    { peerName = "SILVER" })
  gev({ t = "send", slot = 3, side = "b", mon = 0, text = "SQUIRTLE", hp = 30 })
  check(has(gf, "SILVER\nsent out"), "send-out (Gold): BattleText_EnemySentOut's first screen")
  check(has(gf, "sent out\nSQUIRTLE!"), "send-out (Gold): ...and the screen its `cont` scrolls to")
  eq(table.concat(Mediated.sentOutPages("X", "Y", 3), "|"), "X sent out\nY!",
     "send-out: Gen 3 keeps this screen's line")
  -- A wild monster is nobody's send-out: "Wild X\nappeared!" introduces it.
  local wf, wev = screenFor(gameWith({ mon("CHARMANDER") }, K_RED), "wild", "so3",
    { wildParty = Mediated.snapshotMons(gameWith({}, K_RED), { mon("SQUIRTLE") }) })
  wf:onReady({ battle = "so3", mode = "wild", sides = { a = { "me" }, b = { "npc" } } })
  wev({ t = "send", slot = 3, side = "b", mon = 0, text = "SQUIRTLE", hp = 30 })
  check(has(wf, "Wild SQUIRTLE\nappeared!"), "wild (Red): the cart's opening line names the monster")
  local said = false
  for _, l in ipairs(lines(wf)) do if l:find("sent", 1, true) then said = true end end
  eq(said, false, "wild (Red): ...and no trainer sends it out")
end

-- ------- an escape is the cart's "Got away safely!", once
do
  local function count(fight, text)
    local n = 0
    for _, l in ipairs(fight.lines or {}) do if l == text then n = n + 1 end end
    return n
  end
  -- Nobody said it (SoloBattle's own roll): the ending does.
  local f1, ev1 = screenFor(gameWith({ mon("CHARMANDER") }, K_RED), "wild", "ga1")
  ev1({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  ev1({ t = "run", slot = 0, side = "a", text = "ANN" })
  f1:onOutcome({ battle = "ga1", winners = { "npc" }, losers = { "me" }, reason = "run" })
  eq(count(f1, "Got away safely!"), 1, "escape (wild): \"Got away safely!\" is said")
  eq(count(f1, "Someone ran away!") + count(f1, "You lost!"), 0,
     "escape (wild): ...and no win / loss line or second reason follows it")
  -- The referee said it (the Red coop_wild roll): not again.
  local f2, ev2 = screenFor(gameWith({ mon("CHARMANDER") }, K_RED), "wild", "ga2")
  ev2({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  ev2({ t = "msg", text = "Got away safely!" })
  ev2({ t = "run", slot = 0, side = "a", text = "ANN" })
  f2:onOutcome({ battle = "ga2", winners = { "npc" }, losers = { "me" }, reason = "run" })
  eq(count(f2, "Got away safely!"), 1, "escape (wild): the referee's line is not repeated")
  -- A TELEPORT said its own.
  local f3, ev3 = screenFor(gameWith({ mon("CHARMANDER") }, K_RED), "wild", "ga3")
  ev3({ t = "msg", text = "CHARMANDER ran from battle!" })
  f3:onOutcome({ battle = "ga3", winners = { "npc" }, losers = { "me" }, reason = "run" })
  eq(count(f3, "Got away safely!"), 0, "escape (wild): a TELEPORT's own line is the whole of it")
  -- A fight between players keeps its concession line.
  local f4 = screenFor(gameWith({ mon("CHARMANDER") }, K_RED), "1v1", "ga4")
  f4:onOutcome({ battle = "ga4", winners = { "me" }, losers = { "npc" }, reason = "run" })
  eq(count(f4, "Someone ran away!"), 1, "escape (1v1): the concession keeps \"Someone ran away!\"")
  check(Mediated.escapeLine("BETA fled from battle!") and not Mediated.escapeLine("BETA fled"),
        "escapeLine: the referees' escape lines, and nothing else")
end

-- ------- Red's Bide: FIGHT sends at once while one is going on
do
  local input = fakeInput()
  local bider = mon("CHARMANDER", { moves = { { id = "TACKLE", pp = 30 }, { id = "BIDE", pp = 10 } } })
  local game = gameWith({ bider }, setmetatable({ moves = BP_DATA.moves }, { __index = K_RED }))
  local fight, ev, transport = screenFor(game, "wild", "rb")
  ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
  check(fight:pickMove(2), "Bide (Red): BIDE is chosen")
  ev({ t = "msg", text = "CHARMANDER used BIDE" })
  ev({ t = "turn", amount = 2 })
  check(fight.bideLocked == true, "Bide (Red): the turn after \"used BIDE\" is a Bide going on")
  fight.phase, fight.commandIndex = "choose", 1
  input.press("a")
  fight:updateCommand(input)
  local sent = choicesOf(transport)
  eq(#sent, 2, "Bide (Red): FIGHT sends at once (MainInBattleLoop's STORING_ENERGY skip)")
  eq(sent[2] and sent[2].move, 1, "Bide (Red): ...the Bide's slot")
  -- A store turn says nothing (SavingEnergyText is never referenced): still on.
  ev({ t = "turn", amount = 3 })
  check(fight.bideLocked == true, "Bide (Red): a silent store turn keeps it")
  -- An item does not end a Red Bide.
  fight:sendChoice({ action = "item", item = "POTION" })
  ev({ t = "turn", amount = 4 })
  check(fight.bideLocked == true, "Bide (Red): ...nor does an item (wPlayerBattleStatus1 untouched)")
  ev({ t = "msg", text = "CHARMANDER unleashed energy" })
  ev({ t = "turn", amount = 5 })
  check(not fight.bideLocked, "Bide (Red): the release ends it")
  -- Full paralysis clears STORING_ENERGY (`.ParalysisCheck`).
  fight:pickMove(2)
  ev({ t = "msg", text = "CHARMANDER used BIDE" })
  ev({ t = "turn", amount = 6 })
  check(fight.bideLocked == true, "Bide (Red): (a second Bide)")
  ev({ t = "msg", text = "CHARMANDER is fully paralyzed" })
  ev({ t = "turn", amount = 7 })
  check(not fight.bideLocked, "Bide (Red): full paralysis ends it")
  -- ...and the cart's confusion self-hit, named by the line before it.
  fight:pickMove(2)
  ev({ t = "msg", text = "CHARMANDER used BIDE" })
  ev({ t = "turn", amount = 8 })
  ev({ t = "msg", text = "CHARMANDER is confused!" })
  ev({ t = "msg", text = "It hurt itself in its confusion!" })
  ev({ t = "turn", amount = 9 })
  check(not fight.bideLocked, "Bide (Red): a confusion self-hit ends it")
  -- Another monster's lines are not ours.
  eq(Mediated.bideLine1("SQUIRTLE unleashed energy", "CHARMANDER"), nil,
     "bideLine1: a line about another monster is nothing")
  -- A trap's later turns are the referee's to know: the move list stays.
  ev({ t = "msg", text = "CHARMANDER's attack continues!" })
  ev({ t = "turn", amount = 10 })
  eq(fight:lockedFightSlot(), nil, "trap (Red): no lock is guessed from a continuation")
end

-- ------- Gold's wTimeOfDay reaches the evolution check (src/EvolveFx.lua)
do
  local EvolveFx = need("EvolveFx")
  local saved = stubMod.world
  local ow = { timeOfDayId = function() return 2 end }
  stubMod.world = { overworld = function() return ow end }
  local gold = goldGame({})
  eq(EvolveFx.timeOfDay2(gold), "NITE", "EvolveFx: the overworld's wTimeOfDay (NITE_F)")
  eq(Mediated.timeOfDay2(gold), "nite", "...the same reading the ruleset states, in the referee's case")
  local seen, planned
  local savedEvo = package.loaded["src.core.gen2.Evolution"]
  package.loaded["src.core.gen2.Evolution"] = {
    checkMon = function(_, _, ctx) seen = ctx and ctx.timeOfDay; return nil end,
    plan = function(_, _, _, ctx) planned = ctx and ctx.timeOfDay; return {} end,
  }
  local m = goldMon("CHARMANDER", nil, 4321)
  EvolveFx.pending(gold, m)
  eq(seen, "NITE", "EvolveFx: a level-up's evolution check is handed the time of day")
  gold.save.party = { m }
  EvolveFx.offerEvolutions(gold, { [m] = true }, "win", nil, { ui = { push = function() end } })
  eq(planned, "NITE", "EvolveFx: ...and so is the after-battle plan")
  package.loaded["src.core.gen2.Evolution"] = savedEvo
  eq(EvolveFx.timeOfDay2(gameWith({}, DATA)), nil, "EvolveFx: Red has no clock")
  stubMod.world = saved
end

-- ------- wave 6: the referees' own lines, through every client matcher
--
-- Wave 5 rewrote every Red and Gold referee line into the carts' wording, and
-- each screen reads some of those lines to know what happened.  So the lines
-- here are not typed in: real fights are driven through src/BattleSim/Turn.lua
-- and src/BattleSim2/Turn.lua and their own `msg` texts are fed to every
-- matcher -- a future wording change fails this block instead of silently
-- breaking a screen.  Synthetic monsters and moves throughout (ALPHA / BETA,
-- invented ids); the effect numbers are the referees' own tables.
do
  local Red, Gold = need("BattleSim/init"), need("BattleSim2/init")
  local E1, E2 = Red.Effects, Gold.Effects
  local function mv(id, effect, o)
    o = o or {}
    return { id = id, pp = o.pp or 20, power = o.power or 0, accuracy = o.accuracy or 255,
             type = o.type or 0, effect = effect or 0, chance = 0 }
  end
  local function red(sp, moves, o)
    o = o or {}
    return { species = sp, level = o.level or 20, hp = o.hp, maxHp = o.maxHp or 200,
             types = o.types,
             stats = { atk = o.atk or 40, def = 40, spd = o.spd or 40, spc = 40 }, moves = moves }
  end
  local function gold(sp, moves, o)
    o = o or {}
    return { species = sp, level = o.level or 20, hp = o.hp, maxHp = o.maxHp or 200,
             types = o.types,
             stats = { atk = o.atk or 40, def = 40, spe = o.spe or 40, spa = 40, spd = 40 },
             moves = moves }
  end
  local n = 0
  -- One refereed fight: `a` against `b` (lists of mons), driven turn by turn.
  -- Returns the battle, a `step(choiceA, choiceB, choiceC)` that files and
  -- drains, and the list every event lands in.
  local function fightOf(Turn, mode, a, b, o)
    o = o or {}
    n = n + 1
    local id = "w6_" .. n
    local sides = { a = { { playerId = "me", name = "ANN", mons = a, bag = o.bag } },
                    b = { { playerId = "npc", name = o.nameB or "BOB", mons = b, bag = o.bagB } } }
    if o.a2 then sides.a[2] = { playerId = "cal", name = "CAL", mons = o.a2 } end
    local battle = assert(Turn.create({ id = id, mode = mode, seed = o.seed or 7,
      chart = o.chart, choiceTimeout = 60, reconnectGrace = 60, sides = sides }))
    local all = {}
    local function drainTo()
      local got = battle:drainEvents()
      for _, e in ipairs(got) do all[#all + 1] = e end
      return got
    end
    drainTo()
    local function step(ca, cb, cc)
      if ca then battle:submitChoice("me", ca) end
      if cb then battle:submitChoice("npc", cb) end
      if cc then battle:submitChoice("cal", cc) end
      return drainTo()
    end
    return battle, step, all
  end
  local F = function(m) return { action = "fight", move = m or 0 } end
  local function said(events)
    local out = {}
    for _, e in ipairs(events) do if e.t == "msg" then out[#out + 1] = e.text end end
    return out
  end
  local function find(lines, pattern)
    for _, line in ipairs(lines) do if line:find(pattern) then return line end end
    return nil
  end

  -- Bide.  Red: "used BIDE!" then "unleashed energy!", and no storing line
  -- (pokered BideEffect; SavingEnergyText is never referenced).  Gold: "used
  -- BIDE!" alone on the first turn, "is storing energy!" on each storing
  -- turn, "unleashed energy!" on the release.
  local _, rstep, rall = fightOf(Red.Turn, "1v1",
    { red("ALPHA", { mv("BIDE", E1.idOf("BIDE_EFFECT")) }) },
    { red("BETA", { mv("THUMP", 0, { power = 20 }) }) })
  for _ = 1, 4 do rstep(F(), F()) end
  local rl = said(rall)
  local rUsed, rRelease = find(rl, "^ALPHA used BIDE"), find(rl, "unleashed energy")
  check(rUsed ~= nil and rRelease ~= nil, "real lines (Red Bide): the referee's lines were said")
  eq(Mediated.bideLine1(rUsed or "", "ALPHA", Mediated.bideLabels({}, nil)), "start",
     "bideLine1 (Red): the referee's used line starts the Bide")
  eq(Mediated.bideLine1(rRelease or "", "ALPHA"), "release", "bideLine1 (Red): its release ends it")
  eq(find(rl, "storing energy"), nil, "bideLine1 (Red): no store turn says anything")
  local _, gstep, gall = fightOf(Gold.Turn, "1v1",
    { gold("ALPHA", { mv("BIDE", E2.idOf("EFFECT_BIDE")) }) },
    { gold("BETA", { mv("THUMP", 0, { power = 20 }) }) })
  for _ = 1, 4 do gstep(F(), F()) end
  local gl = said(gall)
  local gUsed, gStore = find(gl, "^ALPHA used BIDE"), find(gl, "storing energy")
  local gRelease = find(gl, "unleashed energy")
  check(gUsed and gStore and gRelease, "real lines (Gold Bide): the referee's three lines were said")
  eq(Mediated.bideLine(gUsed or "", "ALPHA"), "start", "bideLine (Gold): \"used BIDE!\" starts it (the first turn's only line)")
  eq(Mediated.bideLine(gStore or "", "ALPHA"), "store", "bideLine (Gold): the storing line, \"!\" and all")
  eq(Mediated.bideLine(gRelease or "", "ALPHA"), "release", "bideLine (Gold): the release")
  eq(Mediated.bideLine(gStore or "", "BETA"), nil, "bideLine (Gold): a line about another monster is nothing")

  -- Stat changes: Red's "rose!" / "greatly rose!" / "fell!" / "greatly fell!",
  -- Gold's "went up!" / "went way up!" / "fell!" / "sharply fell!".  Each
  -- fight lowers ALPHA's ATTACK twice and then raises it once -- a rise that
  -- lands below zero, which K10's stage alone reads as a drop -- then lowers
  -- its DEFENSE by two (the faster BETA) and raises its ATTACK by two.
  local function statRun(Turn, mk, E, names)
    local _, step, all = fightOf(Turn, "1v1",
      { mk("ALPHA", { mv("SPLASH", 0), mv("SHARPEN", E.idOf(names.up1)),
                      mv("DANCE", E.idOf(names.up2)) }, { spd = 1, spe = 1 }) },
      { mk("BETA", { mv("GROWL", E.idOf(names.down1)), mv("SPLASH", 0),
                     mv("SCREECH", E.idOf(names.down2)) }, { spd = 90, spe = 90 }) })
    step(F(0), F(0)) step(F(0), F(0)) step(F(1), F(1)) step(F(2), F(2))
    local got = {}
    for _, e in ipairs(all) do
      if e.t == "stat" then got[#got + 1] = (Mediated.statFell(e) and "down" or "up") .. ":" .. tostring(e.text) end
    end
    return got
  end
  local redStats = statRun(Red.Turn, red, E1, { up1 = "ATTACK_UP1_EFFECT", up2 = "ATTACK_UP2_EFFECT",
    down1 = "ATTACK_DOWN1_EFFECT", down2 = "DEFENSE_DOWN2_EFFECT" })
  eq(table.concat(redStats, "|"),
     "down:ALPHA's ATTACK fell!|down:ALPHA's ATTACK fell!|up:ALPHA's ATTACK rose!"
       .. "|down:ALPHA's DEFENSE greatly fell!|up:ALPHA's ATTACK greatly rose!",
     "statFell (Red): every referee line read the way it moved")
  local goldStats = statRun(Gold.Turn, gold, E2, { up1 = "EFFECT_ATTACK_UP", up2 = "EFFECT_ATTACK_UP_2",
    down1 = "EFFECT_ATTACK_DOWN", down2 = "EFFECT_DEFENSE_DOWN_2" })
  eq(table.concat(goldStats, "|"),
     "down:ALPHA's ATTACK fell!|down:ALPHA's ATTACK fell!|up:ALPHA's ATTACK went up!"
       .. "|down:ALPHA's DEFENSE sharply fell!|up:ALPHA's ATTACK went way up!",
     "statFell (Gold): \"went up!\" is a rise even at a stage below zero")

  -- The effectiveness line, through the hit thud: pokered "It's super
  -- effective!", pokecrystal "It's super-effective!", both "not very".
  local chart = { { 100, 200 }, { 50, 100 } }
  local function hitLines(Turn, mk)
    local _, step, all = fightOf(Turn, "1v1",
      { mk("ALPHA", { mv("HIT", 0, { power = 40, type = 0 }) }, { types = { 0 }, spd = 90, spe = 90 }) },
      { mk("BETA", { mv("WEAK", 0, { power = 40, type = 1 }) }, { types = { 1 } }) }, { chart = chart })
    step(F(), F())
    local l = said(all)
    return find(l, "^It's super"), find(l, "^It's not very")
  end
  local screen = screenFor(gameWith({ mon("CHARMANDER") }, DATA), "1v1", "w6hit")
  local function thud(line)
    screen.lines = { line }
    local sfx = screen:peekHitSfx()
    return sfx and sfx.sound
  end
  for _, cart in ipairs({ { "Red", Red.Turn, red }, { "Gold", Gold.Turn, gold } }) do
    local super, weak = hitLines(cart[2], cart[3])
    check(super and weak, "real lines (" .. cart[1] .. "): both effectiveness lines were said")
    eq(thud(super), Gen.sfx(screen.game, "Super_Effective"),
       "hit thud (" .. cart[1] .. "): \"" .. tostring(super) .. "\" is the super-effective thud")
    eq(thud(weak), Gen.sfx(screen.game, "Not_Very_Effective"),
       "hit thud (" .. cart[1] .. "): \"" .. tostring(weak) .. "\" is the not-very-effective thud")
  end

  -- The used line names the move for the arena's callout (CoopBattle's
  -- `moveNameFromBattleText`), on both carts, plain and named.
  local Coop = need("CoopBattle")
  for _, line in ipairs({ rUsed or "", gUsed or "" }) do
    eq(Coop.moveNameFromBattleText(line), "BIDE", "moveNameFromBattleText: \"" .. line .. "\"")
  end
  -- ...and the computer's item line (Red's AIBattleUseItemText) shouts the item.
  local _, iStep, iAll = fightOf(Red.Turn, "coop_npc", { red("ALPHA", { mv("THUMP", 0, { power = 1 }) }) },
    { red("BETA", { mv("THUMP", 0, { power = 1 }) }, { hp = 50 }) },
    { bagB = { POTION = 1 }, nameB = "BUG CATCHER" })
  iStep(F(), { action = "item", item = "POTION" })
  local itemLine = find(said(iAll), " used POTION on ")
  check(itemLine ~= nil, "real lines (Red computer item): \"<TRAINER> used <ITEM> on <MON>!\"")
  eq(Coop.moveNameFromBattleText(itemLine or ""), "POTION",
     "moveNameFromBattleText: the computer's item line names the item, not \"POTION on BETA\"")

  -- Escapes.  Red: the player's POKe DOLL (its use line is the whole of it),
  -- TELEPORT, WHIRLWIND; Gold: the doll, ROAR in the wild ("fled in fear!"),
  -- and a coop_wild RUN -- "Got away safely!" an escape, "Can't escape!" not.
  local function lastLines(Turn, mode, a, b, ca, cb, o)
    local _, step, all = fightOf(Turn, mode, a, b, o)
    step(ca, cb, o and o.cc)
    return said(all)
  end
  local doll = { action = "item", item = "POKE_DOLL" }
  local escapes = {
    { "Red doll", lastLines(Red.Turn, "wild", { red("ALPHA", { mv("THUMP", 0, { power = 1 }) }) },
        { red("BETA", { mv("THUMP", 0, { power = 1 }) }) }, doll, F(), { bag = { POKE_DOLL = 1 } }) },
    { "Red TELEPORT", lastLines(Red.Turn, "wild",
        { red("ALPHA", { mv("TELEPORT", E1.idOf("SWITCH_AND_TELEPORT_EFFECT")) }, { level = 50 }) },
        { red("BETA", { mv("THUMP", 0, { power = 1 }) }) }, F(), F()) },
    { "Red WHIRLWIND", lastLines(Red.Turn, "wild", { red("ALPHA", { mv("THUMP", 0, { power = 1 }) }) },
        { red("BETA", { mv("WHIRLWIND", E1.idOf("SWITCH_AND_TELEPORT_EFFECT")) }, { level = 50 }) },
        F(), F()) },
    { "Gold doll", lastLines(Gold.Turn, "wild", { gold("ALPHA", { mv("THUMP", 0, { power = 1 }) }) },
        { gold("BETA", { mv("THUMP", 0, { power = 1 }) }) }, doll, F(), { bag = { POKE_DOLL = 1 } }) },
    { "Gold ROAR", lastLines(Gold.Turn, "wild", { gold("ALPHA", { mv("THUMP", 0, { power = 1 }) }) },
        { gold("BETA", { mv("ROAR", E2.idOf("EFFECT_FORCE_SWITCH")) }, { level = 50 }) }, F(), F()) },
  }
  for _, case in ipairs(escapes) do
    local hit = false
    for _, line in ipairs(case[2]) do if Mediated.escapeLine(line) then hit = true end end
    check(hit, "escapeLine (" .. case[1] .. "): the referee's escape is read as one: "
      .. table.concat(case[2], " / "))
  end
  local _, cwStep, cwAll = fightOf(Gold.Turn, "coop_wild",
    { gold("ALPHA", { mv("THUMP", 0, { power = 1 }) }, { spe = 1 }) },
    { gold("BETA", { mv("THUMP", 0, { power = 1 }) }, { spe = 250 }) },
    { a2 = { gold("ZETA", { mv("THUMP", 0, { power = 1 }) }) }, seed = 1 })
  for _ = 1, 8 do cwStep({ action = "run" }, F(), F()) end
  local cw = said(cwAll)
  local cant, away = find(cw, "^Can't escape"), find(cw, "^Got away safely")
  check(cant ~= nil, "real lines (Gold coop_wild RUN): a failed try says \"Can't escape!\"")
  eq(Mediated.escapeLine(cant or ""), false, "escapeLine: \"Can't escape!\" is no escape (the turn goes on)")
  if away then eq(Mediated.escapeLine(away), true, "escapeLine: \"Got away safely!\" is one") end

  -- Gold's weather lines (WEATHER_LINES), as the referee says them.
  local _, wStep, wAll = fightOf(Gold.Turn, "1v1",
    { gold("ALPHA", { mv("RAIN", E2.idOf("EFFECT_RAIN_DANCE")), mv("SPLASH", 0) }) },
    { gold("BETA", { mv("SPLASH", 0) }) })
  wStep(F(0), F()) for _ = 1, 6 do wStep(F(1), F()) end
  local wl = said(wAll)
  eq(Mediated.weatherOfLine2(find(wl, "downpour") or ""), "RAIN", "weatherOfLine2: the referee's start line")
  eq(Mediated.weatherOfLine2(find(wl, "continues") or ""), "RAIN", "weatherOfLine2: ...its continuation")
  eq(Mediated.weatherOfLine2(find(wl, "stopped") or ""), false, "weatherOfLine2: ...and its end")

  -- The confusion lines the Red Bide reading keys on (`noteBideLine`).
  local _, cStep, cAll = fightOf(Red.Turn, "1v1",
    { red("ALPHA", { mv("CONF", E1.idOf("CONFUSION_EFFECT")) }, { spd = 90 }) },
    { red("BETA", { mv("THUMP", 0, { power = 20 }) }) }, { seed = 11 })
  for _ = 1, 3 do cStep(F(), F()) end
  local cl = said(cAll)
  local isConf, selfHit = find(cl, " is confused!$"), find(cl, "^It hurt itself")
  check(isConf and selfHit, "real lines (Red confusion): the referee's two lines were said")
  eq(Mediated.bideLine1(selfHit or "", "BETA", nil, "BETA"), "end",
     "bideLine1 (Red): the cart's self-hit line ends a confused monster's Bide")
  eq((isConf or ""):match("^(.-) is confused!?$"), "BETA", "the confusion line names its monster")

  -- ------- the screen, fed by the real referee
  --
  -- A MediatedBattle whose own upload is the referee's side for "me", the
  -- foe's monsters beside it; `turn(foeChoice)` files whatever the screen sent
  -- since the last call, then the foe's, and plays the events into the screen.
  local sn = 0
  local function refereed(Turn, game, mode, foeMons, o)
    o = o or {}
    sn = sn + 1
    local id = "w6s_" .. sn
    local fight, _, transport = screenFor(game, mode, id, o.screen)
    local party
    for _, m in ipairs(transport.sent) do
      if m.t == Wire.BATTLE_PARTY and m.p.side == nil then party = m.p end
    end
    local mine = o.side or "a"
    local theirs = mine == "a" and "b" or "a"
    local sides = {
      [mine] = { { playerId = "me", name = "ANN", mons = party.mons, bag = o.bag or party.bag } },
      [theirs] = { { playerId = "npc", name = "BOB", mons = foeMons } },
    }
    local battle = assert(Turn.create({ id = id, mode = mode, seed = o.seed or 7,
      choiceTimeout = 60, reconnectGrace = 60, sides = sides }))
    fight:onReady({ battle = id, mode = mode, sides = { [mine] = { "me" }, [theirs] = { "npc" } } })
    local seen = 0
    local function pump()
      for _, e in ipairs(battle:drainEvents()) do fight:onEvent(e) end
    end
    pump()
    local function turn(foeChoice, mineChoice)
      local sent = choicesOf(transport)
      for i = seen + 1, #sent do battle:submitChoice("me", sent[i]) end
      seen = #sent
      if mineChoice then battle:submitChoice("me", mineChoice) end
      if foeChoice then battle:submitChoice("npc", foeChoice) end
      pump()
    end
    return fight, battle, turn, transport
  end
  -- How many times the screen's queue says `pattern` -- read across its
  -- pages (a line the box paged is one sentence again).
  local function shown(fight, pattern)
    local parts = {}
    for _, line in ipairs(fight.lines or {}) do
      if type(line) == "string" then parts[#parts + 1] = (line:gsub("\n", " ")) end
    end
    local _, n = table.concat(parts, " "):gsub(pattern, "")
    return n
  end
  local function pressFight(fight)
    local input = fakeInput()
    fight.phase, fight.commandIndex = "choose", 1
    input.press("a")
    fight:updateCommand(input)
  end

  -- Red's Bide (row 8): the referee's "used BIDE!" opens it, every turn after
  -- it FIGHT goes at once on the Bide's slot, and "unleashed energy!" ends it.
  do
    local data = setmetatable({ moves = BP_DATA.moves }, { __index = K_RED })
    local bider = mon("CHARMANDER", { moves = { { id = "TACKLE", pp = 30 }, { id = "BIDE", pp = 10 } } })
    local fight, _, turn, transport = refereed(Red.Turn, gameWith({ bider }, data), "1v1",
      { red("BETA", { mv("THUMP", 0, { power = 5 }) }) })
    check(fight:pickMove(2), "Bide (Red, refereed): BIDE is chosen")
    turn(F())
    check(fight.bideLocked == true, "Bide (Red, refereed): the referee's \"used BIDE!\" locks the next FIGHT")
    local rounds, atOnce = 0, true
    while fight.bideLocked and rounds < 5 do
      rounds = rounds + 1
      local before = #choicesOf(transport)
      pressFight(fight)
      local sent = choicesOf(transport)
      if not (#sent == before + 1 and sent[#sent].move == 1) then atOnce = false end
      turn(F())
    end
    check(rounds >= 2 and atOnce, "Bide (Red, refereed): each storing turn's FIGHT went at once on the Bide ("
      .. rounds .. " turns)")
    eq(shown(fight, "CHARMANDER unleashed energy!"), 1, "Bide (Red, refereed): the referee released it")
    check(not fight.bideLocked, "Bide (Red, refereed): ...and the release ends the lock")
    eq(shown(fight, "storing energy"), 0, "Bide (Red, refereed): no storing line on Red")
  end

  -- Gold's Bide (row 1): "used BIDE!" alone on the first turn, "is storing
  -- energy!" after it, FIGHT at once until the release.
  do
    local bider = goldMon("CHARMANDER", nil, 4321)
    bider.moves = { { id = "TACKLE", pp = 20, maxPp = 30 }, { id = "BIDE", pp = 9, maxPp = 9 } }
    local fight, _, turn, transport = refereed(Gold.Turn, goldGame({ bider }, SKETCH_DATA), "1v1",
      { gold("BETA", { mv("THUMP", 0, { power = 1 }) }, { atk = 1 }) })
    check(fight:pickMove(2), "Bide (Gold, refereed): BIDE is chosen")
    turn(F())
    eq(shown(fight, "storing energy"), 0, "Bide (Gold, refereed): the first turn says no storing line")
    check(fight.bideLocked == true, "Bide (Gold, refereed): ...and still locks the next FIGHT (\"used BIDE!\")")
    local rounds, atOnce = 0, true
    while fight.bideLocked and rounds < 5 do
      rounds = rounds + 1
      local before = #choicesOf(transport)
      pressFight(fight)
      local sent = choicesOf(transport)
      if not (#sent == before + 1 and sent[#sent].move == 1) then atOnce = false end
      turn(F())
    end
    check(rounds >= 2 and atOnce, "Bide (Gold, refereed): FIGHT went at once every storing turn ("
      .. rounds .. " turns)")
    eq(shown(fight, "CHARMANDER unleashed energy!"), 1, "Bide (Gold, refereed): the referee released it")
    check(not fight.bideLocked, "Bide (Gold, refereed): ...and the release ends the lock")
  end

  -- The catch, said once (row 2): the referee's own line, no "Gotcha!" of
  -- this screen's under it -- Red's and Gold's.
  for _, cart in ipairs({
    { "Red", Red.Turn, gameWith({ mon("CHARMANDER") }, K_RED), red },
    { "Gold", Gold.Turn, goldGame({ goldMon("CHARMANDER", nil, 4321) }), gold },
  }) do
    local fight, battle = refereed(cart[2], cart[3], "wild",
      { cart[4]("BETA", { mv("THUMP", 0, { power = 1 }) }, { hp = 1 }) },
      { bag = { MASTER_BALL = 1 } })
    battle:submitChoice("me", { action = "item", item = "MASTER_BALL" })
    battle:submitChoice("npc", F())
    for _, e in ipairs(battle:drainEvents()) do fight:onEvent(e) end
    fight:onOutcome(battle:outcome())
    -- One line on either cart: Red's "All right! <MON> was caught!", Gold's
    -- "Gotcha! <MON> was caught!" (pokegold Text_BallCaught) -- and no
    -- "Gotcha!" of this screen's beside it.
    eq(shown(fight, "was caught!"), 1,
       "catch (" .. cart[1] .. "): the catch is said once, in the referee's words")
    eq(shown(fight, "Gotcha"), cart[1] == "Gold" and 1 or 0,
       "catch (" .. cart[1] .. "): ...and no \"Gotcha!\" of the screen's own")
  end

  -- POKe DOLL (row 3): a Red doll's escape ends on its use line -- no "Got
  -- away safely!" under it -- and outside a wild fight the doll is refused at
  -- the bag with the cart's line, nothing sent.
  do
    local fight, battle = refereed(Red.Turn, gameWith({ mon("CHARMANDER") }, K_RED), "wild",
      { red("BETA", { mv("THUMP", 0, { power = 1 }) }) }, { bag = { POKE_DOLL = 1 } })
    battle:submitChoice("me", { action = "item", item = "POKE_DOLL" })
    battle:submitChoice("npc", F())
    for _, e in ipairs(battle:drainEvents()) do fight:onEvent(e) end
    fight:onOutcome(battle:outcome())
    eq(shown(fight, "used POKé DOLL!"), 1, "doll (Red): the use line is said")
    eq(shown(fight, "Got away safely"), 0, "doll (Red): ...and nothing after it (ItemUsePokeDoll)")
    local dollRow = { id = "POKE_DOLL", name = "POKe DOLL", count = 1, effect = E1.itemEffect("POKE_DOLL") }
    local function tryDoll(game, mode, tag)
      game.save.inventory = { POKE_DOLL = 1 }
      local f, _, transport = screenFor(game, mode, "w6doll" .. tag)
      f.bagSheet = { POKE_DOLL = 1 }
      local before = #choicesOf(transport)
      local input = fakeInput()
      f.phase, f.itemIndex, f.itemList = "item", 1, { dollRow }
      input.press("a")
      f:updateItemMenu(input)
      return f, #choicesOf(transport) - before
    end
    local tf, tsent = tryDoll(gameWith({ mon("CHARMANDER") }, K_RED), "coop_npc", "t")
    eq(tsent, 0, "doll (Red trainer): nothing is filed -- the turn is not spent")
    eq(shown(tf, "OAK: ANN! This isn't the time to use that!"), 1,
       "doll (Red trainer): ItemUseNotTime's line")
    eq(tf.phase, "item", "doll (Red trainer): ...and the bag stays up")
    local gf, gsent = tryDoll(goldGame({ goldMon("CHARMANDER", nil, 4321) }), "coop_npc", "g")
    eq(gsent, 0, "doll (Gold trainer): refused too (PokeDollEffect .not_wild)")
    eq(shown(gf, "OAK: GOLD! This isn't the time to use that!"), 1, "doll (Gold trainer): the same line")
    local _, wsent = tryDoll(gameWith({ mon("CHARMANDER") }, K_RED), "wild", "w")
    eq(wsent, 1, "doll (wild): ...where it is filed as ever")
  end

  -- Red's status animations (row 5): the referee names a link seat's clip
  -- from its own console (both sides are "the player"), so the screen across
  -- swaps it; a foe's sleep clip plays after its line, as CheckEnemyStatus
  -- Conditions plays SLP_ANIM.
  do
    local function animRows(fight)
      local out = {}
      for i, row in ipairs(fight.lines or {}) do
        if type(row) == "table" and type(row.anim) == "string" and row.anim:find("_ANIM$")
           and (row.anim:find("^SLP") or row.anim:find("^CONF")) then
          out[#out + 1] = { at = i, anim = row.anim }
        end
      end
      return out
    end
    local function feed(all, side, tag)
      local f = screenFor(gameWith({ mon("CHARMANDER") }, DATA), "1v1", all[1].battle)
      f:onReady({ battle = all[1].battle, mode = "1v1",
        sides = side == "a" and { a = { "me" }, b = { "npc" } } or { a = { "npc" }, b = { "me" } } })
      for _, e in ipairs(all) do f:onEvent(e) end
      return f
    end
    local _, cStep2, conf = fightOf(Red.Turn, "1v1",
      { red("ALPHA", { mv("CONF", E1.idOf("CONFUSION_EFFECT")) }, { spd = 90 }) },
      { red("BETA", { mv("THUMP", 0, { power = 20 }) }) }, { seed = 11 })
    cStep2(F(), F())
    local raw = {}
    for _, e in ipairs(conf) do if e.t == "anim" and e.text:find("^CONF.*_ANIM$") then raw[#raw + 1] = e.text end end
    eq(raw[1], "CONF_PLAYER_ANIM", "status anim (Red 1v1): the referee names BETA's clip from BETA's console")
    local seenA, seenB = {}, {}
    for _, r in ipairs(animRows(feed(conf, "a"))) do seenA[#seenA + 1] = r.anim end
    for _, r in ipairs(animRows(feed(conf, "b"))) do seenB[#seenB + 1] = r.anim end
    eq(table.concat(seenA, ","), "CONF_ANIM", "status anim: side a's screen plays the enemy's CONF_ANIM over BETA")
    eq(table.concat(seenB, ","), "CONF_PLAYER_ANIM", "status anim: BETA's own screen keeps its CONF_PLAYER_ANIM")
    local _, sStep, slp = fightOf(Red.Turn, "1v1",
      { red("ALPHA", { mv("SLP", E1.idOf("SLEEP_EFFECT")) }, { spd = 90 }) },
      { red("BETA", { mv("THUMP", 0, { power = 20 }) }) }, { seed = 5 })
    sStep(F(), F()) sStep(F(), F())
    local fa = feed(slp, "a")
    local rows = animRows(fa)
    local asleepAt
    for i, line in ipairs(fa.lines) do
      if type(line) == "string" and line:gsub("\n", " "):find("BETA is fast asleep!") then asleepAt = i end
    end
    check(asleepAt ~= nil and #rows == 1 and rows[1].anim == "SLP_ANIM" and rows[1].at > asleepAt,
          "status anim: side a plays the enemy's SLP_ANIM, behind \"BETA is fast asleep!\" (CheckEnemyStatusConditions)")
    eq(Mediated.viewerAnim("BURN_PSN_ANIM", false), "BURN_PSN_ANIM", "viewerAnim: BURN_PSN_ANIM has one variant")
    -- ...and the arena wears each in its condition's colours (Vfx.forStatusAnim).
    local Vfx = need("Vfx")
    eq((Vfx.forStatusAnim("SLP_ANIM") or {}).style, Vfx.forStatus("SLP").style, "arena: a sleep clip is sleep's look")
    eq((Vfx.forStatusAnim("CONF_PLAYER_ANIM") or {}).style, Vfx.forStatus("confusion").style,
       "arena: a confusion clip is confusion's")
    eq((Vfx.forStatusAnim("BURN_PSN_ANIM", "BRN") or {}).style, Vfx.forStatus("BRN").style,
       "arena: BURN_PSN_ANIM over a burned monster is a burn's")
    eq((Vfx.forStatusAnim("BURN_PSN_ANIM", "TOX") or {}).style, Vfx.forStatus("TOX").style,
       "arena: ...over a badly poisoned one, poison's")
    eq(Vfx.forStatusAnim("TACKLE"), nil, "arena: a move's id is no status clip")
    eq(Mediated.viewerAnim("SLP_ANIM", true), "SLP_PLAYER_ANIM", "viewerAnim: our own monster's is the player's")
  end

  -- The NPC upload carries the trainer (row 4): its name, and on Red the
  -- class's move-choice layers -- as the wire takes them.
  do
    local foes = Mediated.snapshotMons(gameWith({}, K_RED), { mon("SQUIRTLE") })
    local f, _, transport = screenFor(gameWith({ mon("CHARMANDER") }, K_RED), "coop_npc", "w6ai",
      { trainer = { name = "BUG CATCHER", aiMods = { 1, "LAYER_3", 9, "MYMOD" } }, npcParty = foes,
        peerName = "BUG" })
    local npc
    for _, m in ipairs(transport.sent) do
      if m.t == Wire.BATTLE_PARTY and m.p.side == "b" then npc = m.p end
    end
    eq(npc and npc.name, "BUG CATCHER", "NPC upload (Red): the trainer's name, as wTrainerName prints it")
    eq(npc and table.concat(npc.aiMods or {}, ","), "1,3",
       "NPC upload (Red): the class's AI layers, by number (a layer no number names is left out)")
    local packed = npc and Wire.battleParty(npc, 1)
    check(packed ~= nil, "NPC upload (Red): Wire.battleParty takes it")
    eq(packed and packed.aiMods and table.concat(packed.aiMods, ","), "1,3", "NPC upload (Red): ...layers and all")
    local mine
    for _, m in ipairs(transport.sent) do
      if m.t == Wire.BATTLE_PARTY and m.p.side == nil then mine = m.p end
    end
    check(mine and mine.name == nil and mine.aiMods == nil, "the player's own upload states neither")
    local gfoes = Mediated.snapshotMons(goldGame({}), { goldMon("SQUIRTLE") })
    local _, _, gt = screenFor(goldGame({ goldMon("CHARMANDER", nil, 4321) }), "coop_npc", "w6ai2",
      { trainer = { name = "YOUNGSTER JOEY", aiMods = { 1 } }, npcParty = gfoes })
    local gnpc
    for _, m in ipairs(gt.sent) do
      if m.t == Wire.BATTLE_PARTY and m.p.side == "b" then gnpc = m.p end
    end
    eq(gnpc and gnpc.name, "YOUNGSTER JOEY", "NPC upload (Gold): the record's whole name")
    eq(gnpc and gnpc.aiMods, nil, "NPC upload (Gold): no Red layers (pokecrystal scores by AI flags)")
  end

  -- Red's PP byte (row 6): DecrementPP at 0 wraps to 63 and borrows a PP Up;
  -- IncrementMovePP at 63 carries it back.  The referee's own steps, onto the
  -- sheet: the PP is never clamped, the PP Ups follow the byte, and the
  -- maximum reads as GetMaxPP over them.
  do
    local m = mon("CHARMANDER", { moves = { { id = "TACKLE", pp = 0 } } })
    local fight, battle = refereed(Red.Turn, gameWith({ m }, K_RED), "1v1",
      { red("BETA", { mv("THUMP", 0, { power = 1 }) }) })
    local me = battle.byId.me
    local rmon = me.mons[1]
    battle:_decrementPp(rmon, 1)
    battle:_emitMoves(me, rmon, 1)
    for _, e in ipairs(battle:drainEvents()) do fight:onEvent(e) end
    local slot = fight.mine[1].moves[1]
    eq(slot.pp, 63, "PP wrap (Red): 0 PP paid is 63, not clamped to the maximum")
    eq(slot.ppUps, 3, "PP wrap (Red): ...with a PP Up borrowed (none wraps to three)")
    eq(slot.maxPp, Mediated.maxPpOf(35, 3), "PP wrap (Red): the maximum is GetMaxPP over the byte's PP Ups")
    battle:_incrementPp(me, rmon, 1)
    battle:_emitMoves(me, rmon, 1)
    for _, e in ipairs(battle:drainEvents()) do fight:onEvent(e) end
    eq(slot.pp .. "/" .. slot.ppUps, "0/0", "PP wrap (Red): IncrementMovePP's refund carries it back")
    local wrappedSheet = Mediated.snapshotParty(gameWith({ mon("CHARMANDER",
      { moves = { { id = "TACKLE", pp = 63, ppUps = 3 } } }) }, K_RED))[1]
    local wrapped = wrappedSheet.moves[1]
    eq(wrapped.pp .. "/" .. wrapped.maxPp, "63/" .. Mediated.maxPpOf(35, 3),
       "PP wrap (Red): a wrapped save slot uploads its 63 over the cart's maximum")
    local packedWrap = Wire.battleParty({ battle = "w6pp", mons = { wrappedSheet }, generation = 1 })
    eq(packedWrap and packedWrap.mons[1].moves[1].pp, 63, "PP wrap (Red): ...and the wire takes it as it is")
  end

  -- Gold's mid-turn seat changes (row 7).  WHIRLWIND drags our monster out
  -- (a `switch` + `send` we never chose), and the screen follows the seat; a
  -- monster SPIKES left `standing` at 0 HP is asked, and its FIGHT goes.
  do
    local a1, a2 = goldMon("CHARMANDER", nil, 4321), goldMon("SQUIRTLE", nil, 4321)
    a1.moves = { { id = "TACKLE", pp = 20, maxPp = 30 } }
    a2.moves = { { id = "GROWL", pp = 40, maxPp = 40 } }
    local fight, _, turn = refereed(Gold.Turn, goldGame({ a1, a2 }, SKETCH_DATA), "1v1",
      { gold("BETA", { mv("WHIRLWIND", E2.idOf("EFFECT_FORCE_SWITCH")) }, { level = 50, spe = 250 }) })
    fight:pickMove(1)
    turn(F())
    eq(shown(fight, "SQUIRTLE was dragged out!"), 1, "WHIRLWIND (Gold): the referee drags our second monster out")
    eq(fight.active, 2, "WHIRLWIND (Gold): ...and the screen's seat follows it")
    local now = fight:activeMon()
    eq(now and now.moves[1].id, "GROWL", "WHIRLWIND (Gold): FIGHT lists the newcomer's moves")

    local s1, s2 = goldMon("CHARMANDER", nil, 4321), goldMon("SQUIRTLE", nil, 4321)
    s1.moves = { { id = "TACKLE", pp = 30, maxPp = 30 } }
    s2.moves = { { id = "TACKLE", pp = 30, maxPp = 30 } }
    s2.hp = 3
    local sf, sbattle, sturn, stransport = refereed(Gold.Turn, goldGame({ s1, s2 }, SKETCH_DATA), "1v1",
      { gold("ALPHA", { mv("SPIKES", E2.idOf("EFFECT_SPIKES")), mv("PERISH", E2.idOf("EFFECT_PERISH_SONG")),
                        mv("SPLASH", 0) }, { spe = 90 }),
        gold("DELTA", { mv("SPLASH", 0) }, { spe = 1 }) }, { side = "b" })
    for _, foe in ipairs({ 0, 1, 2, 2, 2 }) do
      sf:pickMove(1)
      sturn(F(foe))
    end
    sturn({ action = "switch", slot = 1 }, { action = "switch", slot = 1 })
    eq(shown(sf, "SQUIRTLE's hurt by SPIKES!"), 1, "standing (Gold): SPIKES takes the successor to 0")
    eq(sbattle:snapshot().phase, "choice", "standing (Gold): the referee opens the turn with it standing")
    check(sf.pendingTurn == true and not sf.mustReplace,
          "standing (Gold): the screen opens the command menu for it, no picker")
    local before = #choicesOf(stransport)
    pressFight(sf)
    eq(sf.phase, "move", "standing (Gold): FIGHT opens its move list")
    check(sf:pickMove(1), "standing (Gold): ...and its move is chosen")
    eq(#choicesOf(stransport), before + 1, "standing (Gold): ...and sent")
    sturn(F(0))
    eq(shown(sf, "SQUIRTLE used TACKLE!"), 1, "standing (Gold): the 0-HP monster acts before its faint")
  end

  -- Gold's TRANSFORM: the copies' PP spends carry no `mon` (wave 5), and the
  -- screen spends them on the overlay -- never on the party's own sheet.
  do
    local data = setmetatable({ moves = {
      TRANSFORM = { name = "TRANSFORM", power = 0, accuracy = 100, type = "NORMAL", pp = 10,
                    effect = "EFFECT_TRANSFORM" },
      TACKLE = SKETCH_DATA.moves.TACKLE,
    } }, { __index = SKETCH_DATA })
    local t = goldMon("CHARMANDER", nil, 4321)
    t.moves = { { id = "TRANSFORM", pp = 10, maxPp = 10 }, { id = "TACKLE", pp = 30, maxPp = 30 } }
    local fight, _, turn = refereed(Gold.Turn, goldGame({ t }, data), "1v1",
      { gold("BETA", { mv("THUMP", 0, { power = 1 }) }, { atk = 1 }) })
    fight:pickMove(1)
    turn(F())
    eq(fight.liveMoves and fight.liveMoves[1] and fight.liveMoves[1].id, "THUMP",
       "TRANSFORM (Gold): the copies are the FIGHT list")
    local copyPp = fight.liveMoves[1].pp
    local ownPp = fight.mine[1].moves[1].pp
    fight:pickMove(1)
    turn(F())
    eq(fight.liveMoves and fight.liveMoves[1] and fight.liveMoves[1].pp, copyPp - 1,
       "TRANSFORM (Gold): the copy's spend (no `mon`) lands on the overlay")
    eq(fight.mine[1].moves[1].pp, ownPp, "TRANSFORM (Gold): ...and never on the party's own list")
  end

  -- Glyphs, not bytes (wave 6 W5: é … ♂ ♀ ride a Red / Gold line now): the
  -- box wraps and cuts one tile per glyph, and nothing is split.
  local Classic = need("ClassicBattle")
  local Field = need("Battlefield")
  local perish = Classic.wrapBoxLines("Both POKéMON will faint in 3 turns!")
  eq(perish[1], "Both POKéMON will", "glyph wrap: \"POKéMON\" is 7 columns -- the line breaks after \"will\"")
  local cool = Classic.wrapBoxLines("COOLTRAINER♂ used X ATTACK on FOE!")
  eq(cool[1], "COOLTRAINER♂ used", "glyph wrap: \"COOLTRAINER♂\" is 12 columns")
  local hard = Classic.wrapBoxLines(string.rep("A", 17) .. "éB")
  eq(hard[1], string.rep("A", 17) .. "é", "glyph wrap: a hard cut keeps the é whole")
  eq(Field.fitLine(nil, "COOLTRAINER♂ used X ATTACK", 15 * 6), "COOLTRAINER♂...",
     "glyph fit (arena): the ellipsis cut lands after the ♂, never inside it")
  eq(Field.truncateText("COOLTRAINER♂X", 13), "COOLTRAINER♂X", "glyph truncate (arena): 13 glyphs fit 13")
  eq(Field.truncateText("POKéMON TRAINER", 8), "POKéMON.", "glyph truncate (arena): ...and a cut keeps the é")
  local Coop2 = need("CoopBattle")
  eq(Coop2.fitHudName("POKéDOLLS", 5), "POKé.", "glyph cut (co-op HUD): by glyph")
  eq(Coop2.hudSanitize("é"), ".", "co-op HUD sheet: an é it lacks is one '.'")

  -- ------- review fixes (FX-C of docs/plans/gen12-referee-gaps-fix.md)
  --
  -- Red's Bide start in a mirror match; Gold's ROAR / WHIRLWIND drag-out
  -- line; the glyph helpers' per-frame allocations; Red's overlay maximum PP;
  -- no `mmo.battle_moveset` in a link fight; Gold's doll and catch lines.
  -- Synthetic monsters and moves throughout.
  local FX_RED = setmetatable({ moves = setmetatable({
    MIRROR_MOVE = { name = "MIRROR MOVE", power = 0, accuracy = 100, type = "NORMAL", pp = 20,
                    effect = "MIRROR_MOVE_EFFECT" },
    TRANSFORM = { name = "TRANSFORM", power = 0, accuracy = 100, type = "NORMAL", pp = 10,
                  effect = "TRANSFORM_EFFECT" },
    MIMIC = { name = "MIMIC", power = 0, accuracy = 100, type = "NORMAL", pp = 10,
              effect = "MIMIC_EFFECT" },
    BIDE = BP_DATA.moves.BIDE,
  }, { __index = K_RED.moves }) }, { __index = K_RED })

  -- Red's Bide in a mirror match (row 1): the referee names both sides by
  -- bare species, so the foe's "CHARMANDER used BIDE!" is not ours -- our
  -- FIGHT keeps its move list.
  do
    local ours = mon("CHARMANDER", { moves = { { id = "TACKLE", pp = 30 }, { id = "BIDE", pp = 10 } } })
    local fight, _, turn = refereed(Red.Turn, gameWith({ ours }, FX_RED), "1v1",
      { red("CHARMANDER", { mv("BIDE", E1.idOf("BIDE_EFFECT")) }) })
    check(fight:pickMove(1), "Bide mirror (Red): TACKLE is chosen")
    turn(F())
    eq(shown(fight, "CHARMANDER used BIDE!"), 1, "Bide mirror (Red): the foe's used line was said")
    check(not fight.bideLocked, "Bide mirror (Red): ...and does not lock our FIGHT (we filed no BIDE)")
    pressFight(fight)
    eq(fight.phase, "move", "Bide mirror (Red): FIGHT opens the move list")
  end
  -- ...and a BIDE we filed is not started by the foe's line either: the used
  -- line straight behind a move animation on the other seat is that seat's.
  for _, cart in ipairs({ { "Red", gameWith({ mon("CHARMANDER", { moves = {
      { id = "TACKLE", pp = 30 }, { id = "BIDE", pp = 10 } } }) }, FX_RED) },
    { "Gold", goldGame((function()
      local g = goldMon("CHARMANDER", nil, 4321)
      g.moves = { { id = "TACKLE", pp = 30, maxPp = 30 }, { id = "BIDE", pp = 9, maxPp = 9 } }
      return { g }
    end)(), SKETCH_DATA) } }) do
    local tag = cart[1]
    local fight, ev = screenFor(cart[2], "1v1", "fxbide" .. tag)
    ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
    check(fight:pickMove(2), "Bide seat (" .. tag .. "): BIDE is chosen")
    local foe = Config.COOP_SIDE
    -- Ours could not move (pokered FlinchedText); the foe's BIDE is next.
    ev({ t = "msg", text = "CHARMANDER flinched!" })
    ev({ t = "anim", slot = foe, side = "b", text = "BIDE" })
    ev({ t = "msg", text = "CHARMANDER used BIDE!" })
    ev({ t = "turn", amount = 2 })
    check(not fight.bideLocked, "Bide seat (" .. tag .. "): the foe's line behind its own animation starts nothing")
    -- Our own: the animation on our seat, then the line.
    fight:pickMove(2)
    ev({ t = "anim", slot = 0, side = "a", text = "BIDE" })
    ev({ t = "msg", text = "CHARMANDER used BIDE!" })
    ev({ t = "turn", amount = 3 })
    check(fight.bideLocked == true, "Bide seat (" .. tag .. "): our animation, our line -- the Bide is ours")
  end
  -- A MIRROR MOVE that copies the foe's BIDE is a Bide we filed (pokered
  -- MirrorMoveCopyMove runs the copy as our own move): the referee reports
  -- it on our seat, and the next FIGHT goes at once.
  do
    local ours = mon("CHARMANDER", { moves = { { id = "MIRROR_MOVE", pp = 20 } } })
    local fight, _, turn, transport = refereed(Red.Turn, gameWith({ ours }, FX_RED), "1v1",
      { red("SQUIRTLE", { mv("BIDE", E1.idOf("BIDE_EFFECT")) }, { spd = 250 }) })
    check(fight:pickMove(1), "Bide by MIRROR MOVE (Red): MIRROR MOVE is chosen")
    turn(F())
    eq(shown(fight, "CHARMANDER used BIDE!"), 1, "Bide by MIRROR MOVE (Red): the copy was used")
    check(fight.bideLocked == true, "Bide by MIRROR MOVE (Red): ...and locks our next FIGHT")
    local before = #choicesOf(transport)
    pressFight(fight)
    eq(#choicesOf(transport), before + 1, "Bide by MIRROR MOVE (Red): FIGHT sends at once")
    -- A call that copied something else is no Bide.
    local plain = mon("CHARMANDER", { moves = { { id = "MIRROR_MOVE", pp = 20 } } })
    local pf, _, pturn = refereed(Red.Turn, gameWith({ plain }, FX_RED), "1v1",
      { red("CHARMANDER", { mv("THUMP", 0, { power = 1 }) }, { spd = 250 }) })
    pf:pickMove(1)
    pturn(F())
    check(not pf.bideLocked, "Bide by MIRROR MOVE (Red): a copy of anything else locks nothing")
    check(Mediated.isCallMove({ id = "METRONOME", effect = E1.idOf("METRONOME_EFFECT") })
          and Mediated.isCallMove({ id = "X", effect = E2.idOf("EFFECT_MIRROR_MOVE") })
          and not Mediated.isCallMove({ id = "BIDE", effect = E1.idOf("BIDE_EFFECT") }),
          "isCallMove: METRONOME and MIRROR MOVE on both referees' numbers, nothing else")
  end

  -- Gold's ROAR / WHIRLWIND drag-out (row 2): pokecrystal ForceSwitch fields
  -- the monster with the send-out animation alone and says DraggedOutText --
  -- no "<TRAINER> sent out" pages, no "Go!".
  do
    local data = setmetatable({ moves = {
      ROAR = { name = "ROAR", power = 0, accuracy = 100, type = "NORMAL", pp = 20,
               effect = "EFFECT_FORCE_SWITCH" },
      TACKLE = SKETCH_DATA.moves.TACKLE,
    } }, { __index = SKETCH_DATA })
    -- Ours drags theirs out.
    local roarer = goldMon("CHARMANDER", nil, 4321)
    roarer.moves = { { id = "ROAR", pp = 20, maxPp = 20 } }
    local fight, _, turn = refereed(Gold.Turn, goldGame({ roarer }, data), "1v1",
      { gold("BETA", { mv("THUMP", 0, { power = 1 }) }, { spe = 250 }),
        gold("GAMMA", { mv("THUMP", 0, { power = 1 }) }) })
    eq(shown(fight, "sent out BETA!"), 1, "drag-out (Gold): an ordinary send-out keeps its line")
    check(fight:pickMove(1), "drag-out (Gold): ROAR is chosen")
    turn(F())
    eq(shown(fight, "GAMMA was dragged out!"), 1, "drag-out (Gold): DraggedOutText is said")
    eq(shown(fight, "sent out GAMMA"), 0, "drag-out (Gold): ...and no send-out line before it")
    local seat = fight.slots[Config.COOP_SIDE]
    eq(seat and (seat.pending or seat).species, "GAMMA",
       "drag-out (Gold): the seat is the dragged-out monster's (its arrival still plays)")
    -- Theirs drags ours out: no "Go!".
    local lead = goldMon("CHARMANDER", nil, 4321)
    lead.moves = { { id = "TACKLE", pp = 30, maxPp = 30 } }
    local bench = goldMon("SQUIRTLE", nil, 4321)
    bench.moves = { { id = "TACKLE", pp = 30, maxPp = 30 } }
    local f2, _, turn2 = refereed(Gold.Turn, goldGame({ lead, bench }, data), "1v1",
      { gold("BETA", { mv("ROAR", E2.idOf("EFFECT_FORCE_SWITCH")) }) })
    f2:pickMove(1)
    turn2(F())
    eq(shown(f2, "SQUIRTLE was dragged out!"), 1, "drag-out (Gold, ours): DraggedOutText is said")
    eq(shown(f2, "Go! SQUIRTLE"), 0, "drag-out (Gold, ours): ...and no \"Go!\" for it")
    eq(shown(f2, "Go! CHARMANDER"), 1, "drag-out (Gold, ours): the opening \"Go!\" stands")
    check(Mediated.draggedOutLine("GAMMA was dragged out!", "GAMMA")
          and not Mediated.draggedOutLine("GAMMA was dragged out!", "BETA")
          and not Mediated.draggedOutLine("GAMMA fled in fear!", "GAMMA"),
          "draggedOutLine: DraggedOutText about that monster, and nothing else")
  end

  -- Red's overlay maximum (row 5): the cart's move menu prints GetMaxPP over
  -- the battle struct -- a Transform copy (5 PP, no PP Ups) reads its own
  -- base, a mimicked slot the mimicked move's base with MIMIC's PP Ups.
  do
    local copycat = mon("CHARMANDER", { moves = { { id = "MIMIC", pp = 12, ppUps = 1 },
                                                  { id = "TACKLE", pp = 30 } } })
    local fight, ev = screenFor(gameWith({ copycat }, FX_RED), "wild", "fxpp")
    ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
    local transformed = { { id = "TACKLE", pp = 5, maxPp = 5, ppUps = 0 },
                          { id = "EMBER", pp = 5, maxPp = 5, ppUps = 0 } }
    ev({ t = "moves", slot = 0, side = "a", moves = transformed })
    local rows = fight:bandMoveRows()
    eq(rows[1] and rows[1].right, "5/35", "Transform PP (Red): a copy reads 5 over its own base (GetMaxPP)")
    eq(rows[2] and rows[2].right, "5/25", "Transform PP (Red): ...each copy its own")
    eq(transformed[1].maxPp, 5, "Transform PP (Red): the event's own rows are left as they came")
    ev({ t = "moves", slot = 0, side = "a",
         moves = { { id = "EMBER", pp = 11, maxPp = 12, ppUps = 1 }, { id = "TACKLE", pp = 30, maxPp = 35, ppUps = 0 } } })
    rows = fight:bandMoveRows()
    eq(rows[1] and rows[1].right, "11/30", "MIMIC PP (Red): the mimicked slot reads EMBER's base with MIMIC's PP Up")
    eq(rows[2] and rows[2].right, "30/35", "MIMIC PP (Red): ...the other slot its own")
    -- Through the real referee: a TRANSFORM against a TACKLE.
    local tr = mon("CHARMANDER", { moves = { { id = "TRANSFORM", pp = 10 } } })
    local tf, _, tturn = refereed(Red.Turn, gameWith({ tr }, FX_RED), "1v1",
      { red("BETA", { mv("TACKLE", 0, { power = 1, pp = 12 }) }) })
    tf:pickMove(1)
    tturn(F())
    local trows = tf:bandMoveRows()
    eq(trows[1] and trows[1].right, "5/35", "Transform PP (Red, refereed): the copy reads 5/35")
  end

  -- No `mmo.battle_moveset` in a fight between players (row 6): no cart
  -- learns or levels in a link battle.
  do
    local function movesetsOf(transport)
      local n = 0
      for _, m in ipairs(transport.sent) do if m.t == Wire.BATTLE_MOVESET then n = n + 1 end end
      return n
    end
    for _, mode in ipairs({ "1v1", "coop_pvp" }) do
      local m = mon("CHARMANDER")
      local fight, _, transport = screenFor(gameWith({ m }, K_RED), mode, "fxls" .. mode)
      m.level = 13
      m.stats = { hp = 33, attack = 15, defense = 14, speed = 17, special = 16 }
      eq(fight:syncFightMoves(m, true), false, "link moveset (" .. mode .. "): a level-up sends nothing")
      eq(fight:syncFightMoves(m), false, "link moveset (" .. mode .. "): ...nor a learn")
      eq(movesetsOf(transport), 0, "link moveset (" .. mode .. "): no mmo.battle_moveset went out")
    end
    local m = mon("CHARMANDER")
    local fight, _, transport = screenFor(gameWith({ m }, K_RED), "wild", "fxlsw")
    eq(fight:syncFightMoves(m, true), true, "moveset (wild): a level-up against the computer is still sent")
    eq(movesetsOf(transport), 1, "moveset (wild): ...once")
  end

  -- Gold's doll ends on its own use line (pokegold PokeDollEffect: UseItemText
  -- alone), no "Got away safely!" under it.
  do
    local fight, battle = refereed(Gold.Turn, goldGame({ goldMon("CHARMANDER", nil, 4321) }), "wild",
      { gold("BETA", { mv("THUMP", 0, { power = 1 }) }) }, { bag = { POKE_DOLL = 1 } })
    battle:submitChoice("me", { action = "item", item = "POKE_DOLL" })
    battle:submitChoice("npc", F())
    for _, e in ipairs(battle:drainEvents()) do fight:onEvent(e) end
    fight:onOutcome(battle:outcome())
    eq(shown(fight, "used the POKé DOLL%."), 1, "doll (Gold): ItemUsedText is said")
    eq(shown(fight, "Got away safely"), 0, "doll (Gold): ...and nothing after it")
    eq(Mediated.escapeLine("The wild pokemon ran away"), false,
       "escapeLine: the old Gold doll line is no referee's any more")
  end

  -- Gold's player item line names the item for the callout (CoopBattle
  -- moveNameFromBattleText): ItemUsedText's "the" and full stop are not it.
  do
    -- ALPHA hurt: a POTION at full HP is refused at the door now (FX-R2,
    -- "It won't have any effect." with the item kept and the turn unspent).
    local _, gStep, gAll = fightOf(Gold.Turn, "wild", { gold("ALPHA", { mv("THUMP", 0, { power = 1 }) }, { hp = 100 }) },
      { gold("BETA", { mv("THUMP", 0, { power = 1 }) }) }, { bag = { POTION = 1 } })
    gStep({ action = "item", item = "POTION" }, F())
    local line = find(said(gAll), " used the POTION")
    check(line ~= nil, "real lines (Gold player item): \"<PLAYER> used the POTION.\"")
    local Coop3 = need("CoopBattle")
    eq(Coop3.moveNameFromBattleText(line or ""), "POTION", "moveNameFromBattleText: Gold's item line shouts the item")
    eq(Coop3.moveNameFromBattleText("ANN used the\nGUARD SPEC.."), "GUARD SPEC.",
       "moveNameFromBattleText: ...across a page break, the item's own full stop kept")
    eq(Coop3.moveNameFromBattleText("ALPHA used THUMP!"), "THUMP", "moveNameFromBattleText: a move line as before")
  end

  -- The glyph helpers on the arena's per-frame path (row 3): same answers,
  -- and an ASCII line costs no table.
  do
    for _, text in ipairs({ "", "CHARMANDER used TACKLE!", "POKéMON", "COOLTRAINER♂ X",
                            "\128stray", "é\128\128\128", string.rep("A", 30) }) do
      eq(Classic.glyphCount(text), #Classic.glyphs(text), "glyphCount: \"" .. text .. "\" as the glyph walk counts it")
      for n = 0, 9 do
        eq(Classic.glyphPrefix(text, n), table.concat(Classic.glyphs(text), "", 1, math.min(n, #Classic.glyphs(text))),
           "glyphPrefix: \"" .. text .. "\" cut at " .. n .. " glyphs as the walk cuts it")
      end
    end
    eq(Coop2.hudSanitize("pikachu.lv5 #1"), "PIKACHU.LV5 .1", "co-op HUD sheet (ASCII): mapped by the class")
    eq(Coop2.hudSanitize("POKéMON?"), "POK.MON?", "co-op HUD sheet: an é is still one '.'")
    -- Warmed first, so the JIT's own traces (which LuaJIT counts in the same
    -- heap) are built before the window opens.  A table per call was 600 KB
    -- and up over the 2000 calls; in place it is a few KB of trace residue,
    -- so the bound is 32 KB.
    local function grown(fn)
      for _ = 1, 1000 do fn() end
      collectgarbage("collect")
      collectgarbage("stop")
      local before = collectgarbage("count")
      for _ = 1, 2000 do fn() end
      local kb = collectgarbage("count") - before
      collectgarbage("restart")
      return kb
    end
    local line = "CHARMANDER used TACKLE!"
    check(grown(function() Classic.glyphCount(line) end) < 32,
          "glyphCount: an ASCII line is counted without building anything")
    check(grown(function() Field.truncateText(line, 30) end) < 32,
          "truncate (arena): a line that fits costs nothing per frame")
    check(grown(function() Field.truncateText(line, 12) end) < 32,
          "truncate (arena): ...nor does one cut to fit")
    check(grown(function() Coop2.hudSanitize("CHARMANDER") end) < 32,
          "co-op HUD sheet: an ASCII label is mapped without a table")
    -- The cuts that run every frame a line overflows: same answers, no table.
    local cool = "COOLTRAINER♂ used X ATTACK"
    eq(Field.fitLine(nil, line, 12 * 6), "CHARMANDE...", "glyph fit (arena, ASCII): the cut the walk made")
    check(grown(function() Field.fitLine(nil, cool, 15 * 6) end) < 32,
          "glyph fit (arena): an overflowing line is cut without a table of glyphs")
    local w4 = function(s) return Classic.glyphCount(s) * 4 end
    eq(Coop2.fitHudName("COOLTRAINER♂ JOE", 40, w4), "COOLTRA...", "co-op HUD name (measured): the glyph cut")
    eq(Coop2.fitHudName("POKéMON TRAINER", 44, w4), "POKéMON ...", "co-op HUD name (measured): ...whole é kept")
    check(grown(function() Coop2.fitHudName("COOLTRAINER♂ JOE", 40, w4) end) < 32,
          "co-op HUD name (measured): cut without a table of glyphs")
  end

  -- ------- final client fixes (FX-C2 of docs/plans/gen12-referee-gaps-fix.md)
  --
  -- Gold's overlay maximum PP; STRUGGLE at the menu when every move with PP
  -- is the disabled one; the player's ROAR / WHIRLWIND; items the cart does
  -- not use; a mutual last-monster knockout against the computer.  Synthetic
  -- monsters and moves throughout.
  local FX2_GOLD = setmetatable({ moves = setmetatable({
    TRANSFORM = { name = "TRANSFORM", power = 0, accuracy = 100, type = "NORMAL", pp = 10,
                  effect = "EFFECT_TRANSFORM" },
    MIMIC = { name = "MIMIC", power = 0, accuracy = 100, type = "NORMAL", pp = 10,
              effect = "EFFECT_MIMIC" },
    BATON = { name = "BATON PASS", power = 0, accuracy = 100, type = "NORMAL", pp = 40,
              effect = "EFFECT_BATON_PASS" },
  }, { __index = K_RED.moves }) }, { __index = goldData() })

  -- Gold's overlay maximum (row 1): MoveInfoBox prints GetMaxPPOfMove over
  -- the battle struct (WILDMON: wBattleMonMoves, wBattleMonPP's PP-Up bits),
  -- so a TRANSFORM copy and a MIMIC'd slot (5 PP, no PP Ups) read "5/<the
  -- copied move's base>", and an untouched slot its own PP Ups.
  do
    local m = goldMon("CHARMANDER", nil, 4321)
    m.moves = { { id = "MIMIC", pp = 9, maxPp = 10 }, { id = "GROWL", pp = 50, maxPp = 61, ppUps = 3 } }
    local fight, ev = screenFor(goldGame({ m }, FX2_GOLD), "wild", "fx2pp")
    ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
    local transformed = { { id = "TACKLE", pp = 5, maxPp = 5 }, { id = "EMBER", pp = 5, maxPp = 5 } }
    ev({ t = "moves", slot = 0, side = "a", moves = transformed })
    local rows = fight:bandMoveRows()
    eq(rows[1] and rows[1].right, "5/35", "Transform PP (Gold): a copy reads 5 over its own base (MoveInfoBox GetMaxPPOfMove)")
    eq(rows[2] and rows[2].right, "5/25", "Transform PP (Gold): ...each copy its own")
    eq(fight:activeMon().moves[1].maxPp, 35, "Transform PP (Gold): the classic strip's maximum is the cart's too")
    eq(transformed[1].maxPp, 5, "Transform PP (Gold): the event's own rows are left as they came")
    ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
    ev({ t = "moves", slot = 0, side = "a",
         moves = { { id = "EMBER", pp = 5, maxPp = 5 }, { id = "GROWL", pp = 50, maxPp = 61, ppUps = 3 } } })
    rows = fight:bandMoveRows()
    eq(rows[1] and rows[1].right, "5/25", "MIMIC PP (Gold): the mimicked slot reads 5 over EMBER's base (mimic.asm `ld [hl], 5`)")
    eq(rows[2] and rows[2].right, "50/61", "MIMIC PP (Gold): ...the untouched slot its own three PP Ups (ComputeMaxPP's cap)")
    -- Through the real referee: a TRANSFORM against a TACKLE whose sheet
    -- holds 12 PP -- the cart reads the move table's base, not the foe's PP.
    local tr = goldMon("CHARMANDER", nil, 4321)
    tr.moves = { { id = "TRANSFORM", pp = 10, maxPp = 10 } }
    local tf, _, tturn = refereed(Gold.Turn, goldGame({ tr }, FX2_GOLD), "1v1",
      { gold("BETA", { mv("TACKLE", 0, { power = 1, pp = 12 }) }) })
    tf:pickMove(1)
    tturn(F())
    local trows = tf:bandMoveRows()
    eq(tf.liveMoves and tf.liveMoves[1] and tf.liveMoves[1].id, "TACKLE",
       "Transform PP (Gold, refereed): the copy is the FIGHT list")
    eq(trows[1] and trows[1].right, "5/35", "Transform PP (Gold, refereed): the copy reads 5/35, not the referee's 5/5")
    -- ...and a MIMIC: the faster foe's TACKLE copied into MIMIC's slot.
    local mm = goldMon("CHARMANDER", nil, 4321)
    mm.moves = { { id = "MIMIC", pp = 10, maxPp = 10 }, { id = "GROWL", pp = 40, maxPp = 61, ppUps = 3 } }
    local mf, _, mturn = refereed(Gold.Turn, goldGame({ mm }, FX2_GOLD), "1v1",
      { gold("BETA", { mv("TACKLE", 0, { power = 1, pp = 12 }) }, { spe = 200 }) })
    mf:pickMove(1)
    mturn(F())
    local mrows = mf:bandMoveRows()
    eq(mf.liveMoves and mf.liveMoves[1] and mf.liveMoves[1].id, "TACKLE",
       "MIMIC PP (Gold, refereed): the copy sits in MIMIC's slot")
    eq(mrows[1] and mrows[1].right, "5/35", "MIMIC PP (Gold, refereed): the copy reads 5/35")
    eq(mrows[2] and mrows[2].right, "40/61", "MIMIC PP (Gold, refereed): ...GROWL its own PP Ups")
  end

  -- STRUGGLE at the menu (row 2): pokered AnyMoveToSelect / pokecrystal
  -- CheckPlayerHasUsableMoves.  The disabled slot is read off the referee's
  -- own lines, and FIGHT with nothing else to pick sends STRUGGLE at once.
  do
    for _, gen in ipairs({ 1, 2 }) do
      check(Mediated.mustStruggle({ { pp = 0 }, { pp = 0, ppUps = 2 } }, nil, gen),
            "mustStruggle (gen " .. gen .. "): no Disable -- every slot's masked PP at 0 (PP Ups do not count)")
      check(not Mediated.mustStruggle({ { pp = 0 }, { pp = 3 } }, nil, gen),
            "mustStruggle (gen " .. gen .. "): no Disable -- one slot with PP is a move list")
      check(Mediated.mustStruggle({ { pp = 9 }, { pp = 0 } }, 1, gen),
            "mustStruggle (gen " .. gen .. "): the disabled slot the only one with PP is STRUGGLE")
      check(Mediated.mustStruggle({ { pp = 0, ppUps = 1 }, { pp = 0 } }, 1, gen),
            "mustStruggle (gen " .. gen .. "): the disabled slot's own byte is never read")
      check(not Mediated.mustStruggle({}, nil, gen),
            "mustStruggle (gen " .. gen .. "): an empty list is no FIGHT the referee could take")
    end
    check(not Mediated.mustStruggle({ { pp = 9 }, { pp = 0, ppUps = 1 } }, 1, 1),
          "mustStruggle (Red): a 0-PP slot with PP Ups keeps it away (`and a`, unmasked -- BattleSim `mustStruggle`)")
    check(Mediated.mustStruggle({ { pp = 9 }, { pp = 0, ppUps = 1 } }, 1, 2),
          "mustStruggle (Gold): ...the PP alone counts (BattleSim2 `noUsableMoves`, no softlock)")
    eq(Mediated.disableLine("ALPHA's TACKLE was disabled!", "ALPHA", { { id = "EMBER" }, { id = "TACKLE" } }),
       "on", "disableLine (Red): MoveWasDisabledText")
    eq(select(2, Mediated.disableLine("ALPHA's TACKLE was DISABLED!", "ALPHA", { { id = "TACKLE" } })),
       1, "disableLine (Gold): \"was DISABLED!\", naming the slot")
    eq(select(2, Mediated.disableLine("ALPHA's HYDRO PUMP was disabled!", "ALPHA", { { id = "HYDRO" } },
       { data = DATA })), 1, "disableLine: the move by this build's name for the id")
    eq(Mediated.disableLine("ALPHA's disabled no more!", "ALPHA", {}), "off", "disableLine: DisabledNoMoreText")
    eq(Mediated.disableLine("BETA's TACKLE was disabled!", "ALPHA", { { id = "TACKLE" } }), nil,
       "disableLine: another monster's line is nothing")
    eq(Mediated.disableLine("ALPHA's GROWL was disabled!", "ALPHA", { { id = "TACKLE" } }), nil,
       "disableLine: a move we do not hold is nothing")

    -- The screen, fed lines.
    local m = mon("CHARMANDER", { moves = { { id = "TACKLE", pp = 5 }, { id = "EMBER", pp = 0 } } })
    local fight, ev, transport = screenFor(gameWith({ m }, K_RED), "wild", "fx2st")
    local foe = Config.COOP_SIDE
    ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
    ev({ t = "send", slot = foe, side = "b", mon = 0, text = "CHARMANDER", hp = 30 })
    -- Our own DISABLE in a mirror match: the line is the foe's monster's.
    ev({ t = "anim", slot = 0, side = "a", text = "DISABLE" })
    ev({ t = "msg", text = "CHARMANDER used DISABLE!" })
    ev({ t = "msg", text = "CHARMANDER's TACKLE was disabled!" })
    eq(fight.disabledMove, nil, "Disable (Red): our own DISABLE's line is the foe's, whatever species it names")
    -- The foe's: ours.
    ev({ t = "anim", slot = foe, side = "b", text = "DISABLE" })
    ev({ t = "msg", text = "CHARMANDER used DISABLE!" })
    ev({ t = "msg", text = "CHARMANDER's TACKLE was disabled!" })
    eq(fight.disabledMove, 1, "Disable (Red): the foe's DISABLE on our TACKLE is read off its line")
    check(fight:struggles(), "Struggle (Red): the disabled TACKLE the only move with PP -- AnyMoveToSelect hands STRUGGLE")
    local before = #choicesOf(transport)
    fight.pendingTurn, fight.answeredTurn, fight.lines = false, false, {}
    pressFight(fight)
    check(fight.phase ~= "move", "Struggle (Red): FIGHT opens no move list")
    local sent = choicesOf(transport)
    eq(#sent, before + 1, "Struggle (Red): ...and a FIGHT is sent at once")
    eq(sent[#sent] and sent[#sent].action, "fight", "Struggle (Red): ...a FIGHT")
    eq(sent[#sent] and sent[#sent].move, 0, "Struggle (Red): ...naming the disabled slot")
    eq(shown(fight, "CHARMANDER has no moves left!"), 1, "Struggle (Red): NoMovesLeftText is said")
    -- A list left up across it answers the same way.
    fight.phase, fight.answeredTurn = "move", false
    check(fight:pickMove(2), "Struggle (Red): a pick off a stale list is STRUGGLE too")
    -- DisabledNoMoreText ends it; a newcomer on our seat has none either.
    ev({ t = "msg", text = "CHARMANDER's disabled no more!" })
    eq(fight.disabledMove, nil, "Disable (Red): \"disabled no more!\" lifts it")
    check(not fight:struggles(), "Struggle (Red): ...and the move list is back")
    ev({ t = "anim", slot = foe, side = "b", text = "DISABLE" })
    ev({ t = "msg", text = "CHARMANDER's TACKLE was disabled!" })
    ev({ t = "msg", text = "All STATUS changes are eliminated!" })
    eq(fight.disabledMove, nil, "Disable (Red): HAZE zeroes wPlayerDisabledMove")
    ev({ t = "anim", slot = foe, side = "b", text = "DISABLE" })
    ev({ t = "msg", text = "CHARMANDER's TACKLE was disabled!" })
    ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
    eq(fight.disabledMove, nil, "Disable (Red): a send-out on our seat drops it")

    -- The menu's refusals, the carts' order and words.
    local q = mon("CHARMANDER", { moves = { { id = "TACKLE", pp = 5 }, { id = "EMBER", pp = 0, ppUps = 1 } } })
    local qf, qev, qtransport = screenFor(gameWith({ q }, K_RED), "wild", "fx2rf")
    qev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
    qev({ t = "anim", slot = foe, side = "b", text = "DISABLE" })
    qev({ t = "msg", text = "CHARMANDER's TACKLE was disabled!" })
    check(not qf:struggles(), "Struggle (Red): EMBER at 0 PP with a PP Up keeps STRUGGLE away")
    qf.lines = {}
    eq(qf:pickMove(2), false, "menu (Red): the 0-PP EMBER is refused")
    eq(shown(qf, "No PP left for this move!"), 1, "menu (Red): ...MoveNoPPText")
    eq(qf:pickMove(1), false, "menu (Red): the disabled TACKLE is refused")
    eq(shown(qf, "The move is disabled!"), 1, "menu (Red): ...MoveDisabledText")
    eq(#choicesOf(qtransport), 0, "menu (Red): ...and neither is sent (the player switches or runs)")

    -- Through the real Red referee: the foe's DISABLE on our TACKLE, EMBER
    -- already empty -- FIGHT is STRUGGLE, and the referee runs it.
    do
    local rm = mon("CHARMANDER", { moves = { { id = "TACKLE", pp = 5 }, { id = "EMBER", pp = 0 } } })
    local rf, _, rturn, rtransport = refereed(Red.Turn, gameWith({ rm }, K_RED), "wild",
      { red("BETA", { mv("DISABLE", E1.idOf("DISABLE_EFFECT")) }, { spd = 1 }) })
    rf:pickMove(1)
    rturn(F())
    eq(shown(rf, "CHARMANDER's TACKLE was disabled!"), 1, "Struggle (Red, refereed): the referee's DISABLE line")
    eq(rf.disabledMove, 1, "Struggle (Red, refereed): ...read as our TACKLE's")
    local rbefore = #choicesOf(rtransport)
    rf.lines = {}
    pressFight(rf)
    eq(#choicesOf(rtransport), rbefore + 1, "Struggle (Red, refereed): FIGHT sends at once")
    rturn(F())
    eq(shown(rf, "CHARMANDER has no moves left!"), 1, "Struggle (Red, refereed): NoMovesLeftText")
    eq(shown(rf, "CHARMANDER used STRUGGLE!"), 1, "Struggle (Red, refereed): the referee runs STRUGGLE")
    end

    -- Gold's words.
    local g = goldMon("CHARMANDER", nil, 4321)
    g.moves = { { id = "TACKLE", pp = 5, maxPp = 35 }, { id = "EMBER", pp = 0, maxPp = 25 } }
    local gf, gev, gtransport = screenFor(goldGame({ g }, FX2_GOLD), "wild", "fx2sg")
    gev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
    gev({ t = "anim", slot = foe, side = "b", text = "DISABLE" })
    gev({ t = "msg", text = "CHARMANDER's TACKLE was DISABLED!" })
    eq(gf.disabledMove, 1, "Disable (Gold): \"was DISABLED!\" read off the referee's line")
    check(gf:struggles(), "Struggle (Gold): CheckPlayerHasUsableMoves -- the disabled TACKLE is the only move with PP")
    gf.lines = {}
    pressFight(gf)
    local gsent = choicesOf(gtransport)
    eq(gsent[#gsent] and gsent[#gsent].move, 0, "Struggle (Gold): FIGHT sends STRUGGLE on the disabled slot")
    eq(shown(gf, "CHARMANDER has no moves left!"), 1, "Struggle (Gold): BattleText_MonHasNoMovesLeft is said")
    -- Through the real Gold referee: our TACKLE first, then the foe's
    -- DISABLE on it (BattleCommand_Disable reads the last move), EMBER empty.
    do
    local grm = goldMon("CHARMANDER", nil, 4321)
    grm.moves = { { id = "TACKLE", pp = 5, maxPp = 35 }, { id = "EMBER", pp = 0, maxPp = 25 } }
    local grf, _, grturn, grtransport = refereed(Gold.Turn, goldGame({ grm }, FX2_GOLD), "wild",
      { gold("BETA", { mv("DISABLE", E2.idOf("EFFECT_DISABLE")) }, { spe = 1 }) })
    grf:pickMove(1)
    grturn(F())
    eq(shown(grf, "CHARMANDER's TACKLE was DISABLED!"), 1, "Struggle (Gold, refereed): the referee's DISABLE line")
    eq(grf.disabledMove, 1, "Struggle (Gold, refereed): ...read as our TACKLE's")
    local grbefore = #choicesOf(grtransport)
    grf.lines = {}
    pressFight(grf)
    eq(#choicesOf(grtransport), grbefore + 1, "Struggle (Gold, refereed): FIGHT sends at once")
    grturn(F())
    eq(shown(grf, "CHARMANDER has no moves left!"), 1, "Struggle (Gold, refereed): BattleText_MonHasNoMovesLeft")
    eq(shown(grf, "CHARMANDER used STRUGGLE!"), 1,
       "Struggle (Gold, refereed): the referee runs STRUGGLE (CheckPlayerHasUsableMoves, FX-R2)")
    end
    -- A Gold TRANSFORM of ours lifts it (ResetActorDisable).
    gev({ t = "anim", slot = foe, side = "b", text = "DISABLE" })
    gev({ t = "msg", text = "CHARMANDER's TACKLE was DISABLED!" })
    gev({ t = "moves", slot = 0, side = "a", moves = { { id = "GROWL", pp = 5, maxPp = 5 } } })
    eq(gf.disabledMove, nil, "Disable (Gold): our TRANSFORM lifts it")
    -- A hit on a doll can carry no `amount` (an OHKO's past the wire's
    -- AMOUNT_MAX, FX-R1): the `hp` beside it is what both copies read.
    gev({ t = "damage", slot = 0, side = "a", hp = 17 })
    eq(gf.mine[1].hp, 17, "damage with no amount: the sheet takes the stated HP")
    eq(gf.slots[0] and gf.slots[0].hp, 17, "damage with no amount: ...and so does the seat")
  end

  -- The player's ROAR / WHIRLWIND in a wild fight (row 3): the target's side
  -- leaves (pokered SwitchAndTeleportEffect, BattleSim Turn `_concedeRun`
  -- on the target since FX-R1; pokecrystal BattleCommand_ForceSwitch,
  -- BattleSim2's), so the move's own line ends the fight -- no "Got away
  -- safely!" (that is GotAwayText, the player's RUN), no win line, and no
  -- victory fanfare (pokered plays one only from FaintEnemyPokemon's
  -- `.wild_win`, pokecrystal from the knockout too: an escape plays none).
  -- And the computer's ROAR on us, the other way round.
  do
    local FX2_RED = setmetatable({ moves = setmetatable({
      ROAR = { name = "ROAR", power = 0, accuracy = 100, type = "NORMAL", pp = 20,
               effect = "SWITCH_AND_TELEPORT_EFFECT" },
      WHIRLWIND = { name = "WHIRLWIND", power = 0, accuracy = 100, type = "NORMAL", pp = 20,
                    effect = "SWITCH_AND_TELEPORT_EFFECT" },
    }, { __index = K_RED.moves }) }, { __index = K_RED })
    for _, case in ipairs({ { id = "WHIRLWIND", line = "BETA was blown away!" },
                            { id = "ROAR", line = "BETA ran away scared!" } }) do
      local ours = mon("CHARMANDER", { level = 30, moves = { { id = case.id, pp = 20 } } })
      local fight, battle, turn = refereed(Red.Turn, gameWith({ ours }, FX2_RED), "wild",
        { red("BETA", { mv("SPLASH", 0) }, { level = 5, spd = 1 }) })
      fight:pickMove(1)
      turn(F())
      local outcome = battle:outcome()
      check(outcome ~= nil and outcome.reason == "run", case.id .. " (Red): the fight ends on the escape")
      fight:onOutcome(outcome)
      eq(shown(fight, case.line), 1, case.id .. " (Red): the move's line")
      eq(shown(fight, "Got away safely"), 0, case.id .. " (Red): ...stands alone -- no GotAwayText")
      eq(shown(fight, "You won"), 0, case.id .. " (Red): ...and no win line")
      eq(fight.ranSide, "b", case.id .. " (Red): the wild side is the one that left (FX-R1)")
      eq(fight.result, "win", case.id .. " (Red): the screen's verdict is the foe's flight")
      check(fight.victoryMusicPlayed ~= true and fight.victoryMusicHeld ~= true,
            case.id .. " (Red): no victory fanfare for an escape, now or held for the arena")
    end
    -- The wild monster's ROAR on us: our side leaves, on its line alone.
    local ours = mon("CHARMANDER", { level = 5, moves = { { id = "TACKLE", pp = 20 } } })
    local fight, battle, turn = refereed(Red.Turn, gameWith({ ours }, FX2_RED), "wild",
      { red("BETA", { mv("ROAR", E1.idOf("SWITCH_AND_TELEPORT_EFFECT")) }, { level = 40, spd = 200 }) })
    fight:pickMove(1)
    turn(F())
    local outcome = battle:outcome()
    check(outcome ~= nil and outcome.reason == "run", "ROAR on us (Red): the fight ends on the escape")
    fight:onOutcome(outcome)
    eq(shown(fight, "CHARMANDER ran away scared!"), 1, "ROAR on us (Red): RanAwayScaredText")
    eq(shown(fight, "Got away safely"), 0, "ROAR on us (Red): ...and no GotAwayText under it")
    eq(shown(fight, "You lost"), 0, "ROAR on us (Red): ...nor a loss line")
    -- Gold's: "fled in fear!" / "was blown away!", the same way.
    for _, case in ipairs({ { id = "ROAR", line = "BETA fled in fear!" },
                            { id = "WHIRLWIND", line = "BETA was blown away!" } }) do
      local g = goldMon("CHARMANDER", nil, 4321)
      g.level = 30
      g.moves = { { id = case.id, pp = 20, maxPp = 20 } }
      local gdata = setmetatable({ moves = setmetatable({
        ROAR = { name = "ROAR", power = 0, accuracy = 100, type = "NORMAL", pp = 20,
                 effect = "EFFECT_FORCE_SWITCH" },
        WHIRLWIND = { name = "WHIRLWIND", power = 0, accuracy = 100, type = "NORMAL", pp = 20,
                      effect = "EFFECT_FORCE_SWITCH" },
      }, { __index = K_RED.moves }) }, { __index = goldData() })
      local gf, gb, gturn = refereed(Gold.Turn, goldGame({ g }, gdata), "wild",
        { gold("BETA", { mv("SPLASH", 0) }, { level = 5, spe = 1 }) })
      gf:pickMove(1)
      gturn(F())
      local gout = gb:outcome()
      check(gout ~= nil and gout.reason == "run", case.id .. " (Gold): the fight ends on the escape")
      gf:onOutcome(gout)
      eq(shown(gf, case.line), 1, case.id .. " (Gold): the move's line")
      eq(shown(gf, "Got away safely"), 0, case.id .. " (Gold): ...stands alone")
      eq(shown(gf, "You won"), 0, case.id .. " (Gold): ...and no win line")
      check(gf.victoryMusicPlayed ~= true and gf.victoryMusicHeld ~= true,
            case.id .. " (Gold): no victory fanfare for an escape, now or held for the arena")
    end
  end

  -- Items the cart does not use (row 4): pokered ItemUseNoEffect /
  -- pokecrystal WontHaveAnyEffectMessage keep the item and the turn, and
  -- both referees refuse such a choice at the door (FX-R1 `_itemFails`,
  -- FX-R2 `_itemWontHaveEffect`).  The client asks first.
  do
    local IE1, IE2 = E1.itemEffect, E2.itemEffect
    local full = { hp = 30, maxHp = 30, moves = { { id = "TACKLE", pp = 35, maxPp = 35 },
                                                   { id = "EMBER", pp = 25, maxPp = 25 } } }
    local function hurt(o)
      local m = { hp = 10, maxHp = 30, moves = full.moves }
      for k, v in pairs(o or {}) do m[k] = v end
      return m
    end
    local function w(gen, id, mon, ctx)
      local IE = gen == 1 and IE1 or IE2
      return Mediated.itemWontHaveEffect(gen, { data = K_RED }, id, IE(id), mon, ctx or { onField = true })
    end
    for _, gen in ipairs({ 1, 2 }) do
      local tag = gen == 1 and "Red" or "Gold"
      check(w(gen, "POTION", full), "no effect (" .. tag .. "): a POTION at full HP")
      check(not w(gen, "POTION", hurt()), "no effect (" .. tag .. "): ...not on a hurt monster")
      check(w(gen, "MAX_POTION", full), "no effect (" .. tag .. "): a MAX POTION at full HP")
      check(not w(gen, "FULL_RESTORE", { hp = 30, maxHp = 30, status = "PSN", moves = {} }),
            "no effect (" .. tag .. "): a FULL RESTORE at full HP still cures a status")
      check(w(gen, "FULL_RESTORE", full), "no effect (" .. tag .. "): ...and with neither, does nothing")
      check(w(gen, "ANTIDOTE", hurt({ status = "PAR" })), "no effect (" .. tag .. "): an ANTIDOTE on a paralysis")
      check(not w(gen, "ANTIDOTE", hurt({ status = "TOX" })), "no effect (" .. tag .. "): ...cures a TOXIC")
      check(w(gen, "ETHER", full, { onField = true, move = 1 }), "no effect (" .. tag .. "): an ETHER on a full move")
      check(not w(gen, "ETHER", hurt({ moves = { { id = "TACKLE", pp = 3, maxPp = 35 } } }), { onField = true, move = 1 }),
            "no effect (" .. tag .. "): ...not on a spent one")
      check(w(gen, "ELIXER", full), "no effect (" .. tag .. "): an ELIXER with every move full")
      for _, id in ipairs({ "X_ATTACK", "REVIVE", "POKE_BALL", "HP_UP" }) do
        check(not w(gen, id, full), "no effect (" .. tag .. "): " .. id .. " is always used")
      end
    end
    -- Red's own: its X ACCURACY / GUARD SPEC. / DIRE HIT set their bit
    -- whatever it held (ItemUseXAccuracy and the rest), and a MAX ETHER on a
    -- full move with PP Ups still reads as restored (Effects `restorePp`).
    check(not w(1, "X_ACCURACY", full, { onField = true, xAccuracy = true }),
          "no effect (Red): X ACCURACY is used however often")
    check(not w(1, "MAX_ETHER", { hp = 30, maxHp = 30, moves = { { id = "TACKLE", pp = 49, maxPp = 49, ppUps = 2 } } },
                { onField = true, move = 1 }),
          "no effect (Red): a MAX ETHER on a full move with PP Ups restores (the cart's byte compare)")
    -- Gold's own: the SubStatus4 bits, and confusion for the cure-alls.
    check(w(2, "X_ACCURACY", full, { onField = true, xAccuracy = true }), "no effect (Gold): X ACCURACY twice")
    check(not w(2, "X_ACCURACY", full, { onField = true }), "no effect (Gold): ...once is used")
    check(w(2, "GUARD_SPEC", full, { onField = true, mist = true }), "no effect (Gold): GUARD SPEC. under MIST")
    check(w(2, "DIRE_HIT", full, { onField = true, focusEnergy = true }), "no effect (Gold): DIRE HIT pumped")
    check(not w(2, "FULL_HEAL", full, { onField = true, confused = true }),
          "no effect (Gold): a FULL HEAL takes confusion (IsItemUsedOnConfusedMon)")
    check(w(2, "FULL_HEAL", full, { onField = true }), "no effect (Gold): ...and with nothing to cure, does nothing")
    check(w(2, "ANTIDOTE", full, { onField = true, confused = true }), "no effect (Gold): an ANTIDOTE takes no confusion")
    check(not w(2, "FULL_RESTORE", full, { onField = true, confused = true }),
          "no effect (Gold): a FULL RESTORE at full HP cures confusion")

    -- The screen, against the real Red referee: a POTION on a monster at
    -- full HP is not sent, the line is the cart's, the bag is back up and
    -- nothing is spent -- and the referee would have refused it too.
    do
      local ours = mon("CHARMANDER")
      local game = gameWith({ ours }, K_RED)
      game.save.inventory = { POTION = 2 }
      local fight, battle, _, transport = refereed(Red.Turn, game, "wild",
        { red("BETA", { mv("SPLASH", 0) }) })
      local before = #choicesOf(transport)
      fight.lines, fight.phase, fight.itemIndex, fight.itemList = {}, "item", 1, nil
      local input = fakeInput()
      input.press("a")
      fight:updateItemMenu(input)
      eq(fight.phase, "item_party", "POTION (Red): the party picker first")
      fight.switchIndex = 1
      input.press("a")
      fight:updateItemParty(input)
      eq(#choicesOf(transport), before, "POTION (Red, full HP): nothing is sent")
      eq(shown(fight, "It won't have any effect."), 1, "POTION (Red, full HP): ItemUseNoEffectText")
      eq(fight.phase, "item", "POTION (Red, full HP): the bag back up (BagWasSelected)")
      eq(game.save.inventory.POTION, 2, "POTION (Red, full HP): ...the item kept")
      eq(fight.bagSheet and fight.bagSheet.POTION, 2, "POTION (Red, full HP): ...on the bag sheet too")
      eq(battle:submitChoice("me", { action = "item", item = "POTION", slot = 0 }), false,
         "POTION (Red, full HP): the referee refuses it as well (`_itemFails`)")
    end

    -- ...and against the real Gold referee: X ACCURACY once (the referee
    -- takes it, its `item` event sets the bit), then again -- refused here
    -- as WontHaveAnyEffect_NotUsedMessage, and by the referee.
    do
      local g = goldMon("CHARMANDER", nil, 4321)
      local game = goldGame({ g }, FX2_GOLD)
      game.save.inventory = { X_ACCURACY = 2 }
      local gf, gb, gturn, gtransport = refereed(Gold.Turn, game, "wild",
        { gold("BETA", { mv("SPLASH", 0) }) })
      gf.itemPick = { id = "X_ACCURACY", effect = IE2("X_ACCURACY") }
      check(gf:commitItem(gf.active), "X ACCURACY (Gold): the first is sent")
      gturn(F())
      eq(gf.itemFlags2 and gf.itemFlags2.xAccuracy, true, "X ACCURACY (Gold): its `item` event sets the bit here")
      eq(game.save.inventory.X_ACCURACY, 1, "X ACCURACY (Gold): ...and spends one")
      local before = #choicesOf(gtransport)
      gf.lines = {}
      gf.itemPick = { id = "X_ACCURACY", effect = IE2("X_ACCURACY") }
      eq(gf:commitItem(gf.active), false, "X ACCURACY (Gold): the second is not sent")
      eq(#choicesOf(gtransport), before, "X ACCURACY (Gold): ...nothing went")
      eq(shown(gf, "It won't have any effect."), 1, "X ACCURACY (Gold): ItemWontHaveEffectText")
      eq(game.save.inventory.X_ACCURACY, 1, "X ACCURACY (Gold): ...the item kept")
      eq(gb:submitChoice("me", { action = "item", item = "X_ACCURACY" }), false,
         "X ACCURACY (Gold): the referee refuses it as well (`_itemWontHaveEffect`)")
    end

    -- Gold's bits off the referee's lines: our FOCUS ENERGY (after our own
    -- move animation) sets DIRE HIT's; a foe of our species saying the same
    -- does not; a BATON PASS carries them to the one it sends; any other
    -- send-out drops them.
    do
      local g = goldMon("CHARMANDER", nil, 4321)
      g.moves = { { id = "BATON", pp = 40, maxPp = 40 } }
      local bench = goldMon("SQUIRTLE", nil, 4321)
      local game = goldGame({ g, bench }, FX2_GOLD)
      local fight, ev = screenFor(game, "wild", "fx2fl")
      local foe = Config.COOP_SIDE
      ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
      ev({ t = "anim", slot = foe, side = "b", text = "FOCUS_ENERGY" })
      ev({ t = "msg", text = "CHARMANDER's getting pumped!" })
      eq(fight.itemFlags2 and fight.itemFlags2.focusEnergy, nil, "bits (Gold): a foe's FOCUS ENERGY is not ours")
      ev({ t = "anim", slot = 0, side = "a", text = "FOCUS_ENERGY" })
      ev({ t = "msg", text = "CHARMANDER used FOCUS ENERGY!" })
      ev({ t = "msg", text = "CHARMANDER's getting pumped!" })
      eq(fight.itemFlags2 and fight.itemFlags2.focusEnergy, true, "bits (Gold): our FOCUS ENERGY sets SUBSTATUS_FOCUS_ENERGY")
      fight.itemPick = { id = "DIRE_HIT", effect = IE2("DIRE_HIT") }
      eq(fight:itemNoEffect(fight.itemPick, fight.itemPick.effect, fight.active), true,
         "bits (Gold): ...so a DIRE HIT will not have any effect")
      ev({ t = "anim", slot = 0, side = "a", text = "BATON" })
      ev({ t = "msg", text = "CHARMANDER used BATON PASS!" })
      ev({ t = "send", slot = 0, side = "a", mon = 1, text = "SQUIRTLE", hp = 30 })
      eq(fight.itemFlags2 and fight.itemFlags2.focusEnergy, true, "bits (Gold): BATON PASS carries it")
      ev({ t = "send", slot = 0, side = "a", mon = 0, text = "CHARMANDER", hp = 30 })
      eq(fight.itemFlags2 and fight.itemFlags2.focusEnergy, nil, "bits (Gold): an ordinary send-out drops it")
    end
  end
end

T.finish("mediated_battle_client")
