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
    EMBER   = { power = 40, accuracy = 100, type = "FIRE", pp = 25 },
    -- a status move: 0 power is an ordinary answer, not a missing field
    GROWL   = { power = 0, accuracy = 100, type = "NORMAL", pp = 40 },
    -- accuracy that is not a round 100, to pin the byte conversion
    HYDRO   = { power = 120, accuracy = 80, type = "WATER", pp = 5 },
  },
  pokemon = {
    CHARMANDER = { name = "CHARMANDER", types = { "FIRE" } },
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
eq(ember.id, "EMBER", "the move id, for narration")
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

-- Sent even though both sanitisers drop it today. See the note in
-- MediatedBattle.typesOf: the sim already reads raw.types, and the day the two
-- twins carry the field the clients are already speaking it.
eq(mons[1].types[1], 0, "a FIRE species claims type 0")
eq(mons[2].types[1], 2, "and a WATER one type 2")

-- The strongest single assertion in this file: the real sanitiser, which is
-- what the far end runs.
local packed = Wire.battleParty({ battle = "7", mons = mons })
check(packed ~= nil, "the snapshot survives Wire.battleParty unchanged")
eq(#packed.mons, 2, "with both mons still in it")
eq(packed.battle, "7", "filed under the battle it was uploaded for")

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
eq(fight:foeSlot(), 2, "and side b slot 2, leaving the odd slots empty")
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
event({ seq = 2, t = "send", slot = 2, text = "PIDGEY", hp = 24 })
eq(fight.slots[2].species, "PIDGEY", "a send puts a name on the foe's box")
eq(fight.slots[2].maxHp, 24, "and the first HP seen is taken as the maximum")
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

event({ seq = 3, t = "damage", slot = 2, hp = 9, amount = 15 })
eq(fight.slots[2].hp, 9, "damage is applied from the event's own HP")
eq(fight.slots[2].maxHp, 24, "and the bar still knows what it is out of")

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
  ev({ seq = 2, t = "send", slot = 2, text = "PIDGEY", hp = 24 })
  local foe = f.slots[2]
  foe.sprite = { id = "foe-pic" }
  -- Anim first (still in lines), then damage to 0, then faint — the old bug
  -- nil'd the sprite on faint while the anim row had not played yet.
  ev({ seq = 3, t = "anim", slot = 0, text = "TACKLE", side = "a" })
  ev({ seq = 4, t = "damage", slot = 2, hp = 0 })
  ev({ seq = 5, t = "faint", slot = 2, text = "PIDGEY" })
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
    -- Fixture Data may be a subset of Gen1; assert the upload derives Special
    -- indices from the same ordered id list snapshotRuleset uses.
    local SPECIAL = {
      FIRE = true, WATER = true, GRASS = true, ELECTRIC = true,
      ICE = true, PSYCHIC = true, DRAGON = true,
    }
    local order = Mediated.typeOrder(Data)
    local expectSpecial = 0
    if order then
      for _, id in ipairs(order.ids) do
        if SPECIAL[id] then expectSpecial = expectSpecial + 1 end
      end
    end
    eq(realRules.specialTypes and #realRules.specialTypes, expectSpecial,
       "specialTypes covers every Gen1 Special name in the type order")
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
  ev({ t = "send", slot = 2, text = "PIDGEY", hp = 24 })
  eq(a.slots[2].species, "PIDGEY", "the seat record follows the referee at parse")
  eq(a:battlefieldSeat(2, false), nil,
     "...but nothing is on the arena until the spawn row: an empty seat is held")
  eq(a:battlefieldSeat(0, true), nil, "...on our own side too")
  check(drain() < 900, "the intro queue drains in bounded frames")
  check(a:battlefieldSeat(2, false) ~= nil,
        "once the spawn rows have played, both seats draw")
  check(a:battlefieldSeat(0, true) ~= nil, "...ally included")
  check(a.spawnHide == nil or next(a.spawnHide) == nil,
        "and no hold is left standing behind them")

  -- A replacement batched behind the KO: the seat is the fallen monster's
  -- until the swap, which is what lets its drain and sink play at all.
  ev({ t = "damage", slot = 2, hp = 0, amount = 24 })
  ev({ t = "faint", slot = 2, text = "PIDGEY" })
  ev({ t = "send", slot = 2, text = "RATTATA", hp = 21 })
  eq(a.slots[2].species, "PIDGEY",
     "a send into an occupied seat does not relabel it")
  eq(a.slots[2].pending and a.slots[2].pending.species, "RATTATA",
     "...the arrival is parked instead")
  eq(a.slots[2].hp, 0, "...and the fallen monster's own numbers are left alone")
  local seat = a:battlefieldSeat(2, false)
  eq(seat and seat.name, "PIDGEY", "so the arena still shows who is falling")
  local sawSink, drawnBeforeSwap = false, nil
  local guard = 0
  while #a.lines > 0 and guard < 900 do
    a:update(1 / 60); guard = guard + 1
    for _, e in ipairs(a.fx or {}) do
      if e.kind == "faint" then sawSink = true end
    end
    local live = a:battlefieldSeat(2, false)
    if live and live.name == "RATTATA" and drawnBeforeSwap == nil then
      drawnBeforeSwap = sawSink
    end
  end
  check(guard < 900, "the batched queue drains in bounded frames")
  check(sawSink, "the KO sinks -- its rows still name the occupant they were filed for")
  eq(drawnBeforeSwap, true,
     "and the newcomer is first drawn only after that sink, at its own spawn row")
  eq(a.slots[2].species, "RATTATA", "the seat changes hands exactly once, there")
  eq(a.slots[2].pending, nil, "...leaving nothing parked")
  eq(a.slots[2].shownHp, 21, "...and the bar starts where the referee put it")

  -- Teardown: a battle ending mid-window strands neither a hold nor a park.
  ev({ t = "send", slot = 2, text = "PIDGEY", hp = 24 })
  check(a.slots[2].pending ~= nil, "a fresh arrival is parked")
  a:snapDisplay()
  eq(a.slots[2].species, "PIDGEY",
     "snapDisplay closes the window forwards -- the field is where the referee "
     .. "says it is, not where the queue had gotten to")
  eq(a.slots[2].pending, nil, "...with nothing parked behind it")
  eq(a.spawnHide, nil, "...and no seat left hidden")
end

-- The classic 160x144 path queues no spawn row, so it must not park anything:
-- there would be nothing to install it.
--
-- Driven by the gate rather than by a generation, since round 7: Gold takes
-- the arena too (docs/plans/gen2-new-battle-system.md), so a Gen2-shaped game
-- is no longer the classic stand-in. `usesBattlefield` on the instance shadows
-- the class method, and it is the one switch every arena surface reads.
do
  local classic = setmetatable({
    game = { data = {} },
    usesBattlefield = function() return false end,
    slots = { [2] = { species = "PIDGEY", hp = 24, maxHp = 24, shownHp = 24 } },
    lines = {},
  }, { __index = Mediated })
  check(not classic:usesBattlefield(), "the gate is down on this screen")
  classic:noteSlot({ t = "send", slot = 2, text = "RATTATA", hp = 21 })
  eq(classic.slots[2].species, "RATTATA",
     "off the arena a send relabels at parse exactly as it always did")
  eq(classic.slots[2].pending, nil, "...and parks nothing that could never land")
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
    ev({ seq = 2, t = "send", slot = 2, text = "PIDGEY", hp = 24 })
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
    ev({ seq = 3, t = "faint", slot = 2, text = "PIDGEY", amount = 1 })
    ev({ seq = 4, t = "turn", amount = 2, slot = 2 })
    eq(f.replaceWait, 2, "the solicitation names the foe's seat")
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
    ev({ seq = 5, t = "send", slot = 2, text = "RATTATA", hp = 20 })
    eq(f.replaceWait, nil, "the send ends the hold")
    check(f:holdLine():find("Waiting for", 1, true) ~= nil,
          "and the band goes back to the ordinary wait: "
          .. f:holdLine():gsub("\n", "|"))
    drainLines(f)
    eq(f.phase, "play", "still no menu until a turn opens")
    ev({ seq = 6, t = "turn", amount = 2 })
    drainLines(f)
    eq(f.phase, "choose", "and the slot-less turn opens the grid")
    eq(f.slots[2].species, "RATTATA", "with the foe seat filled")
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
    ev({ seq = 3, t = "damage", slot = 2, hp = 10 })
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
    ev({ seq = 3, t = "faint", slot = 2, text = "PIDGEY", amount = 1 })
    ev({ seq = 4, t = "turn", amount = 2, slot = 2 })
    eq(f.replaceWait, 2, "the hold is up")
    f:snapDisplay()
    eq(f.replaceWait, nil, "and snapDisplay drops it")

    local g, gev = newFight()
    gev({ seq = 3, t = "faint", slot = 2, text = "PIDGEY", amount = 1 })
    gev({ seq = 4, t = "turn", amount = 2, slot = 2 })
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
          if (f.slots[2] or {}).hp ~= nil and f.slots[2].hp <= 0 then
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
    eq(f.slots[2].species, "RATTATA", "...and the foe's too")
  end
end

T.finish("mediated_battle_client")
