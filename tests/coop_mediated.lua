-- A 2-on-2 refereed by the intermediator, driven with no hub and no display.
--
-- src/CoopBattle.lua is hub-refereed for coop_pvp / coop_npc (always). CoopSim
-- still holds the field the screen draws from; the intermediator decides.
-- What this suite pins is mostly about that seam:
--
--   * the uploads a co-op battle owes before it can be refereed, including the
--     trainer's party the host sends for the npc seat -- and that a *real* hub
--     accepts them and answers mmo.battle_ready;
--   * that the host stops rolling the moment it does. This is the assertion
--     worth having: two fields resolving the same turn is not a fallback, it is
--     a desync, and it would be invisible in play until the two disagreed;
--   * that a choice goes out as mmo.battle_choice and no `act` goes out beside
--     it, because a second unrefereed opinion about a turn is the same bug seen
--     on the wire;
--   * that the event stream reaches the same screen the client-simulated path
--     draws on -- HP, faints, send-outs and the result -- rather than a second
--     renderer built beside it;
--   * and that Config.MEDIATED_COOP is not a runtime off-switch.
--
-- Run: luajit mods/rby_mmo/tests/coop_mediated.lua
--      (from the engine checkout root -- a co-op field is built out of the
--       engine's own battle modules, so unlike tests/hub_battle.lua beside it
--       this one cannot stand alone)
--
-- Legal: every species, move and trainer below is the committed fixture
-- dataset's. No ROM-derived name appears in this file.

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
local Hub = need("Hub")
local CoopSim = need("CoopSim")
local CoopField = need("CoopField")
local CoopBattle = need("CoopBattle")
local Mediated = need("MediatedBattle")

local function testPlayerId(seed)
  local s = tostring(seed or "")
  local out = {}
  for i = 1, 32 do
    local c = s:byte((i - 1) % #s + 1) or 97
    out[i] = string.format("%x", (c + i) % 16)
  end
  return table.concat(out)
end

-- ------------------------------------------------------------------
-- both co-op modes, whatever this build ships
-- ------------------------------------------------------------------
--
-- Both are on in this build, and both are set here anyway rather than read:
-- a suite that took the flag as its expectation would pass whatever it said, so
-- every section below drives a mode it has switched on itself.
--
-- The shipped values are read first and pinned in section 8, which is the one
-- place that asks what this build actually does.
local SHIPPED = {
  coop_pvp = Config.MEDIATED_COOP.coop_pvp,
  coop_npc = Config.MEDIATED_COOP.coop_npc,
}
Config.MEDIATED_COOP = { coop_pvp = true, coop_npc = true }

-- ------------------------------------------------------------------
-- a field, built the way the real screen builds one
-- ------------------------------------------------------------------
--
-- The engine's own battle modules, not stand-ins: the question this suite asks
-- of the client-simulated path is "did it roll", and a stub sim would answer it
-- whatever the code did. `CoopSim.new` through `CoopField` is exactly what
-- CoopBattle.new assembles.

local okBS, BattleState = pcall(require, "src.battle.BattleState")
check(okBS, "BattleState is requirable headlessly")

local base = T.sdk.loadNone()
local data = base.data
local ruleset = (data.rulesets and data.rulesets.gen1_faithful) or {}

local SPECIES = "FIXMON_A"
-- What the uploader and the event translator will both call that species. Read
-- through the same function rather than written out, so a fixture rename cannot
-- make this suite pass against a screen that has stopped matching.
local SPECIES_NAME = Wire.name(data.pokemon[SPECIES].name)

local function mon(hp, speed)
  return {
    species = SPECIES, level = 20, hp = hp,
    stats = { hp = hp, attack = 30, defense = 30, special = 30, speed = speed },
    dvs = { hp = 8, attack = 8, defense = 8, speed = 8, special = 8 },
    statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 },
    moves = { { id = "FIX_TACKLE", pp = 20 } },
  }
end

local function newGame()
  return { data = data, save = { inventory = {}, options = {}, party = {} } }
end

local function fieldSim(game, slots)
  local rng = function(a) return a end
  local holder = {}
  local field = CoopField.new(
    { BattleState = BattleState, rng = rng }, game, holder, ruleset)
  local sim = CoopSim.new({
    data = data, ruleset = ruleset, rng = rng,
    trainerAI = require("src.battle.TrainerAI"),
    damage = require("src.battle.Damage"),
    status = require("src.battle.Status"),
    turnOrder = require("src.battle.TurnOrder"),
    field = field, drain = CoopField.drain,
    makeBattler = BattleState.makeBattler,
    itemUse = require("src.inventory.ItemEffects").use,
    experience = require("src.battle.Experience"),
    save = game.save,
    onError = function(err)
      check(false, "a move resolved cleanly: " .. tostring(err))
    end,
  }, slots)
  field.slots = sim.slots
  return sim
end

-- Two players against a trainer's pair, which is what `coop_npc` is: side a is
-- owned, side b is not, and the trainer's team was dealt alternately into the
-- two ownerless slots by src/Coop.lua's `npcSide` before it ever got here.
local function npcSlots()
  return {
    { side = "a", owner = "ann", name = "ANN", party = { mon(60, 40) } },
    { side = "a", owner = "bob", name = "BOB", party = { mon(60, 30) } },
    -- Two each, so re-interleaving them has something to get wrong: the
    -- trainer's original party order was 1st, 2nd, 3rd, 4th and the deal put
    -- the odd ones here and the even ones next door.
    { side = "b", owner = nil, name = "TRAINER", party = { mon(50, 20), mon(50, 18) } },
    { side = "b", owner = nil, name = "TRAINER", party = { mon(50, 19), mon(50, 17) } },
  }
end

-- Four players, which is `coop_pvp`: every slot owned, nothing synthetic.
local function pvpSlots()
  return {
    { side = "a", owner = "ann", name = "ANN", party = { mon(60, 40) } },
    { side = "a", owner = "bob", name = "BOB", party = { mon(60, 30) } },
    { side = "b", owner = "cal", name = "CAL", party = { mon(60, 20) } },
    { side = "b", owner = "dee", name = "DEE", party = { mon(60, 10) } },
  }
end

-- A screen, without the constructor.
--
-- `M.new` needs the engine's music, animation and sprite modules to be present
-- and a display to have been opened; every method under test needs a field, a
-- transport and the mediated fields. Built by hand for the same reason the main
-- suite's co-op sections build one -- and the fields are named here rather than
-- defaulted, so the day the constructor grows another one this stops compiling
-- rather than silently testing a screen the game does not build.
local function screen(opts)
  local game = opts.game or newGame()
  local sent = {}
  local transport = {
    send = function(_, msgType, payload)
      sent[#sent + 1] = { type = msgType, payload = payload }
    end,
  }
  local relayed = {}
  local self = setmetatable({
    game = game,
    sim = fieldSim(game, opts.slots),
    mine = opts.mine or 1,
    host = opts.host and true or false,
    hostId = opts.hostId,
    messages = {}, pending = {}, events = {}, seq = 0,
    phase = "messages", moveIndex = 1, targetIndex = 1, frame = 0,
    waitClock = 0, hostClock = 0,
    ranksPoints = opts.ranksPoints and true or false,
    transport = transport,
    battleId = opts.battleId or "cb1",
    selfId = opts.selfId or "ann",
    mode = opts.mode,
    mediated = false, medUploaded = false,
    medPending = {}, medSeq = 0, medGaps = 0,
    net = { poll = function() return {} end,
            send = function(payload) relayed[#relayed + 1] = payload end },
    onDone = opts.onDone,
  }, { __index = CoopBattle })
  self.sent, self.relayed = sent, relayed
  function self.countSent(msgType)
    local n = 0
    for _, msg in ipairs(sent) do
      if msg.type == msgType then n = n + 1 end
    end
    return n
  end
  function self.firstSent(msgType)
    for _, msg in ipairs(sent) do
      if msg.type == msgType then return msg.payload end
    end
    return nil
  end
  return self
end

-- Count what the host's sim was asked to do. This is the spy the whole "one
-- referee" claim rests on: `resolveTurn` and `npcAction` are where the dice
-- are, and a host that reached either of them during a refereed fight is a
-- second referee whatever the flag says.
local function watchSim(self)
  local calls = { resolveTurn = 0, npcAction = 0, replace = 0 }
  local sim = self.sim
  for name in pairs(calls) do
    local original = sim[name]
    sim[name] = function(...)
      calls[name] = calls[name] + 1
      return original(...)
    end
  end
  return calls
end

-- ------------------------------------------------------------------
-- 1. what a refereed co-op battle uploads
-- ------------------------------------------------------------------

do
  local host = screen({ slots = npcSlots(), mine = 1, host = true,
                        mode = "coop_npc", selfId = "ann" })
  eq(host:uploadMediated(), true, "the host of a refereed 2-on-2 uploads")

  eq(host.countSent(Wire.BATTLE_RULESET), 1, "one chart, from the host alone")
  eq(host.countSent(Wire.BATTLE_PARTY), 2,
     "and two parties: its own, and the trainer's for the npc seat")

  -- Sanitised with the real Wire functions rather than read field by field:
  -- these are what the far end runs, so a payload that does not survive them is
  -- one the intermediator drops at the boundary -- leaving four players on a
  -- screen that never starts, and no assertion about a field would have said so.
  local rules = Wire.battleRuleset(host.firstSent(Wire.BATTLE_RULESET))
  check(rules ~= nil, "the ruleset survives Wire.battleRuleset")
  check(rules.chart ~= nil, "and it carries a type chart")

  local mine, npc
  for _, msg in ipairs(host.sent) do
    if msg.type == Wire.BATTLE_PARTY then
      if msg.payload.side == "b" then npc = msg.payload else mine = msg.payload end
    end
  end
  check(mine ~= nil, "the host's own party goes up")
  eq(mine.battle, "cb1", "named with the co-op battle's id, which is the "
     .. "same id the hub opened its record under")
  eq(mine.side, "a", "on the side the agreed field already put it")
  eq(#mine.mons, 1, "with the slot's party, not the save's")
  check(Wire.battleParty(mine) ~= nil, "and it survives Wire.battleParty")

  check(npc ~= nil, "and the trainer's party goes up beside it")
  eq(#npc.mons, 4, "all four of the monsters the two ownerless slots hold")
  check(Wire.battleParty(npc) ~= nil, "sanitised the same way")

  -- Order is the whole point of `npcMons`: the referee sends the next living
  -- monster out in party order and never asks, so a concatenated upload would
  -- have a trainer lead with the monster it meant to finish on. The deal put
  -- 60/50 HP in one slot and 55/45 in the other; re-interleaving gives the
  -- original 1st, 2nd, 3rd, 4th back.
  eq(npc.mons[1].stats.spd, 20, "the first slot's first monster leads")
  eq(npc.mons[2].stats.spd, 19, "then the second slot's first -- the deal, undone")
  eq(npc.mons[3].stats.spd, 18, "then the first slot's second")
  eq(npc.mons[4].stats.spd, 17, "and the second slot's second brings up the rear")

  eq(host:uploadMediated(), false, "asked twice, it uploads once")
  eq(host.countSent(Wire.BATTLE_PARTY), 2, "and sends nothing the second time")
end

do
  local guest = screen({ slots = npcSlots(), mine = 2, host = false,
                         mode = "coop_npc", selfId = "bob" })
  eq(guest:uploadMediated(), true, "a guest uploads too")
  eq(guest.countSent(Wire.BATTLE_RULESET), 0,
     "but no chart -- two charts is a fight with no answer to which")
  eq(guest.countSent(Wire.BATTLE_PARTY), 1,
     "and only its own party: the npc seat is the host's to fill")
end

do
  -- Every seat on a four-player fight uploads its own and nothing else. The
  -- side is read off the agreed field, which is what makes a side-b player's
  -- upload land on side b rather than displacing the host's.
  local cal = screen({ slots = pvpSlots(), mine = 3, host = false,
                       mode = "coop_pvp", selfId = "cal" })
  eq(cal:uploadMediated(), true, "a side-b player uploads")
  eq(cal.firstSent(Wire.BATTLE_PARTY).side, "b", "on side b")
  eq(cal.countSent(Wire.BATTLE_PARTY), 1, "once, and for itself")
end

do
  -- Everything that leaves a fight on the client-simulated path it always had.
  -- None of these is a failure: a battle that is not refereed is still a
  -- battle, which is why none of them says anything in a log.
  local before = #warns

  local nameless = screen({ slots = pvpSlots(), mine = 1, host = true,
                            mode = nil })
  eq(nameless:uploadMediated(), false, "a battle with no mode at all uploads nothing")

  local offline = screen({ slots = pvpSlots(), mine = 1, host = true,
                           mode = "coop_pvp" })
  offline.transport = nil
  eq(offline:uploadMediated(), false, "nor one with no hub to upload to")

  local unnamed = screen({ slots = pvpSlots(), mine = 1, host = true,
                           mode = "coop_pvp" })
  unnamed.battleId = nil
  eq(unnamed:uploadMediated(), false, "nor one the hub never named")

  eq(#warns, before, "and none of the three is worth a word in anybody's log")
end

do
  -- A party the sanitiser could describe nothing from, which is the one refusal
  -- that *is* worth saying out loud: the hub would hold a seat open forever and
  -- three other people would watch a fight that never assembles.
  local slots = pvpSlots()
  slots[1].party = { { species = SPECIES, level = 5, hp = 10, stats = { hp = 10 },
                       moves = {} } }
  local broken = screen({ slots = slots, mine = 1, host = true,
                          mode = "coop_pvp" })
  local before = #warns
  eq(broken:uploadMediated(), false, "an indescribable party does not upload")
  eq(broken.countSent(Wire.BATTLE_PARTY), 0, "and nothing goes out")
  check(#warns > before, "and this one is said out loud, with somewhere to look")
  check(broken.medFailed == true,
        "mediation failed rather than falling back to host-sim")
  check(broken.mediated == false, "and the fight is not marked refereed")
end

-- ------------------------------------------------------------------
-- 2. and a real hub accepts them
-- ------------------------------------------------------------------
--
-- The section above proves the payloads survive their own sanitiser. This one
-- proves the *hub* does what the client is counting on with them: seats the
-- trainer's party on the synthetic npc seat rather than over the host's own, and
-- answers mmo.battle_ready. Driven with src/Hub.lua rather than a description of
-- it, because "the host's second party lands on the npc seat" is a rule that
-- lives over there and could change without this file noticing.

do
  local peers = {}
  local function join(hub, name)
    local peer = { outbox = {} }
    function peer:send(msg) self.outbox[#self.outbox + 1] = msg end
    function peer:close() end
    local client = hub:accept(peer)
    hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
      playerId = testPlayerId(name),
      name = name, map = "PALLET", x = 5, y = 5, facing = "down" })
    peers[client.id] = peer
    return client
  end
  local function count(peer, msgType)
    local n = 0
    for _, msg in ipairs(peer.outbox) do
      if msg.type == msgType then n = n + 1 end
    end
    return n
  end

  local hub = Hub.new({ maxPlayers = 4 })
  local ann, bob = join(hub, "ANN"), join(hub, "BOB")

  hub:openCoopBattle("cb1", { ann.id, bob.id },
    { mode = "coop_npc", hostId = ann.id })
  local record = hub.battles["cb1"]
  check(record ~= nil, "the hub opens a record when the co-op battle is agreed")
  eq(record.mode, "coop_npc", "knowing the shape of it")
  eq(#(record.npcIds or {}), 2,
     "and holding two seats open for the trainer, which is how many monsters "
     .. "this screen draws it standing behind")
  eq(record.sim, nil, "but refereeing nothing until the uploads arrive")

  -- The two clients, built over the ids the hub just handed out, so what goes
  -- into `hub:receive` below is the screen's own output and not a transcript of
  -- it written here.
  local slots = npcSlots()
  slots[1].owner, slots[2].owner = ann.id, bob.id
  local hostScreen = screen({ slots = slots, mine = 1, host = true,
                              mode = "coop_npc", selfId = ann.id })
  local guestScreen = screen({ slots = slots, mine = 2, host = false,
                               mode = "coop_npc", selfId = bob.id })
  hostScreen:uploadMediated()
  guestScreen:uploadMediated()

  for _, msg in ipairs(hostScreen.sent) do
    local payload = {}
    for k, v in pairs(msg.payload) do payload[k] = v end
    payload.type = msg.type
    hub:receive(ann, payload)
  end
  eq(record.sim, nil, "one side's uploads are not a field")

  for _, msg in ipairs(guestScreen.sent) do
    local payload = {}
    for k, v in pairs(msg.payload) do payload[k] = v end
    payload.type = msg.type
    hub:receive(bob, payload)
  end

  check(record.sim ~= nil, "with both in, the hub starts refereeing")
  local npcA, npcB = record.npcIds[1], record.npcIds[2]
  check(record.parties[npcA] ~= nil and record.parties[npcB] ~= nil,
        "the host's side-b party filled both npc seats")
  eq(#record.parties[npcA].mons + #record.parties[npcB].mons, 4,
     "with all four of the trainer's team between them")
  -- Dealt alternately, which is the inverse of the re-interleave `npcMons` did
  -- on the way out -- so the field ends up holding the pair src/Coop.lua built.
  eq(record.parties[npcA].mons[1].stats.spd, 20, "the first seat leads with the "
     .. "monster the trainer meant to lead with")
  eq(record.parties[npcB].mons[1].stats.spd, 19,
     "and the second stands beside it rather than behind it")
  check(record.parties[ann.id] ~= nil, "and did not displace the host's own")
  eq(#record.parties[ann.id].mons, 1, "which is still the one monster it sent")

  eq(count(peers[ann.id], Wire.BATTLE_READY), 1, "the host is told it is on")
  eq(count(peers[bob.id], Wire.BATTLE_READY), 1, "and so is the guest")

  -- And the roster it broadcasts is one this screen can read. The npc seats are
  -- advertised under ids of their own -- nobody is connected to them, so what
  -- the id buys is a name for the box rather than an address -- and `medMap`
  -- lands each of them on an ownerless slot rather than on the host's own.
  local ready
  for _, msg in ipairs(peers[ann.id].outbox) do
    if msg.type == Wire.BATTLE_READY then ready = msg end
  end
  eq(#ready.sides.b, 2, "both trainer seats are named on side b")
  check(Wire.battleReady(ready) ~= nil,
        "and the whole roster survives the client's own sanitiser, npc ids "
        .. "included -- an id with a colon in it would not have")
  eq(hostScreen:onBattleReady(ready), true, "the screen accepts the roster")
  eq(hostScreen.mediated, true, "and the fight is refereed from here")
  eq(hostScreen.medSlots[0], 1, "field slot 0 is the host's own box")
  eq(hostScreen.medSlots[1], 2, "field slot 1 is its partner's")
  eq(hostScreen.medSlots[2], 3,
     "and field slot 2 is the trainer's, not the host's -- the advertised id "
     .. "is where a choice for it arrives from, not who stands in it")
  eq(hostScreen.medSlots[3], 4, "field slot 3 is the trainer's second")
  eq(hostScreen.medFields[3], 2, "and back the other way")
  eq(hostScreen.medFields[4], 3,
     "with the fourth box on a field slot of its own now: the intermediator "
     .. "seats two npcs where this screen draws two")

  -- And the trainer answers. Nothing below advances the hub's clock, so a turn
  -- that needed BATTLE_CHOICE_TIMEOUT to close would not close at all -- which
  -- is the second of the two reasons this mode used to be off, and the one a
  -- player would have experienced as a minute of nothing every turn.
  local opened = record.sim.turn
  for _, seat in ipairs({ ann, bob }) do
    hub:receive(seat, { type = Wire.BATTLE_CHOICE, battle = "cb1",
                        action = "fight", move = 0 })
  end
  check(record.sim.turn > opened or record.settled,
        "the turn resolves on the two players' choices alone")
  eq(hub.clock, 0, "with no time having passed for it to time out in")

  local hurried = false
  for _, msg in ipairs(peers[bob.id].outbox) do
    if msg.type == Wire.BATTLE_EVENT and type(msg.text) == "string"
       and msg.text:find("ran out of time", 1, true) then hurried = true end
  end
  check(not hurried, "and nobody was picked for on a deadline")
end

-- ------------------------------------------------------------------
-- 3. the host stops rolling
-- ------------------------------------------------------------------
--
-- The assertion this whole change rests on. Everything `tryResolve` reaches is
-- dice -- the NPC's move, the turn itself, and the `res` three other clients
-- apply as truth -- and a host still rolling beside the referee is two fields
-- diverging from one turn.

do
  local host = screen({ slots = npcSlots(), mine = 1, host = true,
                        mode = "coop_npc", selfId = "ann" })
  host:uploadMediated()

  -- Before battle_ready, a refereed mode must not host-sim (BattleSim vs
  -- ItemEffects diverge). Choices sit until the hub assembles the field.
  local before = watchSim(host)
  host.pending = {}
  host:commit({ slot = 1, kind = "move", move = 1, target = 3 })
  host:commit({ slot = 2, kind = "move", move = 1, target = 3 })
  eq(before.resolveTurn, 0,
     "before battle_ready, a refereed mode does not host-sim a turn")
  eq(before.npcAction, 0, "and does not choose for the trainer locally")
  eq(host.mediated, false, "ready has not arrived yet")

  -- ...and once ready, the host still resolves nothing locally.
  local mediated = screen({ slots = npcSlots(), mine = 1, host = true,
                            mode = "coop_npc", selfId = "ann" })
  mediated:uploadMediated()
  mediated:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })
  eq(mediated.mediated, true, "the field is assembled")

  local after = watchSim(mediated)
  local relayedBefore = #mediated.relayed
  mediated:commit({ slot = 1, kind = "move", move = 1, target = 3 })
  mediated:commit({ slot = 2, kind = "move", move = 1, target = 3 })
  eq(after.resolveTurn, 0, "a refereed host resolves nothing")
  eq(after.npcAction, 0, "and does not choose for the trainer either -- the "
     .. "intermediator seats it and answers for it")
  eq(#mediated.relayed, relayedBefore,
     "and puts no `act` on the relay beside its choice: a second opinion "
     .. "about a refereed turn is the desync it looks like")

  -- Called directly as well, because `commit` is one of five callers and the
  -- guard is inside `tryResolve` for exactly that reason.
  eq(mediated:tryResolve(), nil, "tryResolve itself answers nothing")
  eq(after.resolveTurn, 0, "however it is reached")

  -- The clocks the client-simulated path runs are the referee's now, and the
  -- deadline they arm forfeits a player the referee is still waiting for.
  mediated:openTurn()
  eq(mediated.turnOpened, nil, "no deadline is armed on a refereed turn")
  eq(mediated:autoPickLate(), false, "and nothing is auto-picked locally")
  mediated:tickStalls(Config.COOP_TURN_TIMEOUT + 5)
  eq(after.resolveTurn, 0, "not even when the old clock would have fired")
end

-- ------------------------------------------------------------------
-- 4. what a pressed button puts on the wire
-- ------------------------------------------------------------------

do
  local host = screen({ slots = pvpSlots(), mine = 1, host = true,
                        mode = "coop_pvp", selfId = "ann" })
  host:uploadMediated()
  host:onBattleReady({ battle = "cb1", mode = "coop_pvp",
    sides = { a = { "ann", "bob" }, b = { "cal", "dee" } } })

  host:commit({ slot = 1, kind = "move", move = 1, target = 3 })
  local fight = host.firstSent(Wire.BATTLE_CHOICE)
  check(fight ~= nil, "a move goes out as a choice")
  eq(fight.battle, "cb1", "against this battle")
  eq(fight.action, "fight", "as a fight")
  eq(fight.move, 0, "with the move index zero-based, as the wire counts")
  eq(fight.target, 2,
     "and the target as a *field* slot -- box 3 on this screen is field slot 2")
  check(Wire.battleChoice(fight) ~= nil, "and it survives Wire.battleChoice")

  -- A target the roster never described is sent as no target rather than as a
  -- guess: the referee then aims at the first living foe, which is what a 1v1
  -- does and the only honest answer.
  local blind = screen({ slots = pvpSlots(), mine = 1, host = false,
                         mode = "coop_pvp", selfId = "ann" })
  blind:uploadMediated()
  blind:onBattleReady({ battle = "cb1", mode = "coop_pvp",
    sides = { a = { "ann", "bob" }, b = { "cal" } } })
  blind:commit({ slot = 1, kind = "move", move = 2, target = 4 })
  eq(blind.firstSent(Wire.BATTLE_CHOICE).target, nil,
     "an unmapped target is left for the referee to pick")

  -- The other three kinds, each as its own action rather than folded into
  -- fight: an item spent as a move would be a turn the player did not take.
  local switcher = screen({ slots = pvpSlots(), mine = 1, host = false,
                            mode = "coop_pvp", selfId = "ann" })
  switcher:uploadMediated()
  switcher:onBattleReady({ battle = "cb1", mode = "coop_pvp",
    sides = { a = { "ann", "bob" }, b = { "cal", "dee" } } })
  switcher:commit({ slot = 1, kind = "switch", index = 2 })
  eq(switcher.firstSent(Wire.BATTLE_CHOICE).action, "switch", "a switch is a switch")
  eq(switcher.firstSent(Wire.BATTLE_CHOICE).slot, 1,
     "naming a party position, zero-based -- not a field slot")

  -- ...and a replacement, which the referee never actually asks for (it sends
  -- the next living monster out in party order) but which must be a choice
  -- rather than an `act` if the screen ever reaches it.
  local relayedBefore = #switcher.relayed
  switcher:sendAction({ slot = 1, index = 3 })
  eq(switcher.countSent(Wire.BATTLE_CHOICE), 2,
     "a replacement goes to the referee")
  eq(#switcher.relayed, relayedBefore, "and not to the other three")
end

-- ------- and RUN, which lost half of itself
--
-- On the client-simulated path, leaving a ranked 2-on-2 needs the partner's
-- consent: it ends the battle for four people and books the pair a loss. The
-- ask and the answer ride mmo.coop_relay, and both hubs stop forwarding a co-op
-- payload the moment they start refereeing -- so there is no channel left to put
-- the question on and no room in the battle vocabulary for one.
--
-- What is kept is the half that was guarding against an accident rather than
-- against a partner: the prompt, with NO under the cursor, because it lands at
-- the moment all four players are holding A through the last turn's narration.

do
  local runner = screen({ slots = pvpSlots(), mine = 1, host = true,
                          mode = "coop_pvp", selfId = "ann" })
  runner:uploadMediated()
  runner:onBattleReady({ battle = "cb1", mode = "coop_pvp",
    sides = { a = { "ann", "bob" }, b = { "cal", "dee" } } })

  eq(runner:askToRun(), true, "RUN still puts a question up")
  eq(runner.runAsk.role, "confirming",
     "but it is the player's own to answer, not their partner's")
  eq(runner.runAsk.index, CoopBattle.RUN_DEFAULT,
     "with the safe answer under the cursor, as it always was")
  eq(#runner.relayed, 0, "and nothing is asked over the relay, which is cut")

  eq(runner:answerRun(false), true, "a no is answerable")
  eq(runner.runAsk, nil, "and takes the prompt down")
  eq(runner.countSent(Wire.BATTLE_CHOICE), 0, "spending nothing")

  runner:askToRun()
  eq(runner:answerRun(true), true, "a yes goes through")
  local ran = runner.firstSent(Wire.BATTLE_CHOICE)
  eq(ran.action, "run", "as a run, refereed like any other choice")
  eq(runner.runAsk.role, "fleeing", "leaving the player watching for the end")
  eq(#runner.relayed, 0, "and still nothing on the relay")

  -- Against a trainer there was never a partner to ask -- the refusal is the
  -- original's, resolved wherever the turn is -- so this one needs no branch at
  -- all: it is a choice, and now it is the referee's choice.
  local fleeing = screen({ slots = npcSlots(), mine = 1, host = true,
                           mode = "coop_npc", selfId = "ann" })
  fleeing:uploadMediated()
  fleeing:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })
  eq(fleeing:askToRun(), false, "an NPC battle asks nobody")
  fleeing:commit({ slot = 1, kind = "run" })
  eq(fleeing.firstSent(Wire.BATTLE_CHOICE).action, "run",
     "and its RUN is a choice the intermediator answers")
end

-- ------------------------------------------------------------------
-- 5. the event stream, on the screen the other path draws on
-- ------------------------------------------------------------------

do
  local host = screen({ slots = npcSlots(), mine = 1, host = true,
                        mode = "coop_npc", selfId = "ann" })
  host:uploadMediated()
  host:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })

  local function lines(self)
    local out = {}
    for _, row in ipairs(self.messages) do
      local text = type(row) == "table" and row.text or row
      if type(text) == "string" then out[#out + 1] = text end
    end
    return out
  end
  local function said(self, needle)
    for _, text in ipairs(lines(self)) do
      if text:find(needle, 1, true) then return true end
    end
    return false
  end

  -- Nothing is drawn until the referee closes the batch. A menu taken away
  -- mid-decision is a turn the player cannot answer, and events arrive one per
  -- message -- so `playEvents` (which closes every open menu) must not run on
  -- each of them.
  host.phase = "choose"
  eq(host:onBattleEvent({ battle = "cb1", seq = 1, t = "msg",
                          text = "ANN used\nFIX TACKLE!" }), true,
     "an event is accepted")
  eq(#host.messages, 0, "but nothing is queued yet")
  eq(host.phase, "choose", "and the menu is still open")

  -- Field slot 2 is the trainer's box, which on this screen is box 3. Getting
  -- that translation backwards would put every one of the referee's numbers on
  -- the wrong monster, and it is the one mistake the screen could not survive.
  host:onBattleEvent({ battle = "cb1", seq = 2, t = "damage", slot = 2, hp = 21 })
  host:onBattleEvent({ battle = "cb1", seq = 3, t = "turn" })
  eq(host.phase, "messages", "the turn closes the batch and it plays")
  check(said(host, "FIX TACKLE"), "the referee's own sentence is what is read")
  eq(host.sim:slot(3).battler.mon.hp, 21,
     "and its number is the HP -- the host applies the stream like everybody "
     .. "else now, because it no longer rolled the turn that made it")
  eq(host.sim:slot(2).battler.mon.hp, 60,
     "with the box that merely shares an index untouched")

  -- A faint is a slide plus a sentence, and the sentence is made here: the
  -- referee's faint carries a species and no words of its own.
  host:onBattleEvent({ battle = "cb1", seq = 4, t = "faint", slot = 2,
                       text = SPECIES_NAME })
  host:onBattleEvent({ battle = "cb1", seq = 5, t = "turn" })
  check(said(host, "fainted"), "a faint is narrated")
  check(not host.replacing, "foe/NPC faint does not arm our replace picker")

  -- Own seat faint with amount=1 (living bench): arm replace after the batch.
  -- Pacing: messages phase first; replacing outranks choose once msgs drain.
  do
    local slots = npcSlots()
    slots[1].party = { mon(60, 40), mon(60, 35) }
    local replacer = screen({ slots = slots, mine = 1, host = true,
                              mode = "coop_npc", selfId = "ann" })
    replacer:onBattleReady({ battle = "cb1", mode = "coop_npc",
      sides = { a = { "ann", "bob" }, b = { "ann" } } })
    replacer.phase = "choose"
    eq(replacer:onBattleEvent({ battle = "cb1", seq = 1, t = "faint",
                                slot = 0, text = "FIXMON", amount = 1 }), true,
       "own faint with amount=1 is accepted")
    check(replacer.medMustReplace, "amount=1 sets medMustReplace")
    check(not replacer.replacing, "picker waits until the turn closes the batch")
    replacer:onBattleEvent({ battle = "cb1", seq = 2, t = "turn" })
    check(replacer.replacing, "turn arms the uncancellable replace picker")
    check(said(replacer, "fainted"), "after faint narration is queued")
    -- Empty-bench: amount omitted → no picker.
    local last = screen({ slots = npcSlots(), mine = 1, host = true,
                          mode = "coop_npc", selfId = "ann" })
    last:onBattleReady({ battle = "cb1", mode = "coop_npc",
      sides = { a = { "ann", "bob" }, b = { "ann" } } })
    last.phase = "choose"
    last:onBattleEvent({ battle = "cb1", seq = 1, t = "faint",
                         slot = 0, text = "FIXMON" })
    last:onBattleEvent({ battle = "cb1", seq = 2, t = "turn" })
    check(not last.replacing, "empty-bench faint (no amount) never opens replace")
  end

  -- A send-out names a species and never a party position, so the position has
  -- to be found -- and it has to be found for the field to move at all. The
  -- trainer's second monster is a different species here so that a lookup which
  -- always answered "the first one" would be visible: the referee's monster is
  -- on the field and this screen's is not.
  local sendSlots = npcSlots()
  sendSlots[3].party[2].species = "FIXMON_B"
  local otherName = Wire.name(data.pokemon.FIXMON_B.name)
  local sendScreen = screen({ slots = sendSlots, mine = 1, host = false,
                              mode = "coop_npc", selfId = "bob" })
  sendScreen:uploadMediated()
  sendScreen:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })
  eq(sendScreen.sim:slot(3).active, 1, "the trainer leads with its first")
  sendScreen:onBattleEvent({ battle = "cb1", seq = 1, t = "send", slot = 2,
                             text = otherName, hp = 50 })
  sendScreen:onBattleEvent({ battle = "cb1", seq = 2, t = "turn" })
  check(said(sendScreen, "sent out"), "a send-out is narrated")
  eq(sendScreen.sim:slot(3).active, 2,
     "and the monster the referee named is the one that walks on")

  -- A name that matches nothing is a send-out this screen cannot draw. The line
  -- is still printed, so a field one monster behind has an explanation on it
  -- rather than being silently wrong.
  local unknown = screen({ slots = npcSlots(), mine = 1, host = false,
                           mode = "coop_npc", selfId = "bob" })
  unknown:uploadMediated()
  unknown:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })
  unknown:onBattleEvent({ battle = "cb1", seq = 1, t = "send", slot = 2,
                          text = "NOBODY", hp = 50 })
  unknown:onBattleEvent({ battle = "cb1", seq = 2, t = "turn" })
  check(said(unknown, "sent out"), "an unmatched send-out is still narrated")
  eq(unknown.sim:slot(3).active, 1, "with the field left where it was")

  -- Out-of-order and duplicate events are read exactly as the 1v1 reads them:
  -- a sequence already applied is a duplicate, and a jump forward is counted
  -- rather than refused -- refusing it would leave the screen waiting on a
  -- message that is not coming.
  local seqScreen = screen({ slots = npcSlots(), mine = 1, host = false,
                             mode = "coop_npc", selfId = "bob" })
  seqScreen:uploadMediated()
  seqScreen:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })
  seqScreen:onBattleEvent({ battle = "cb1", seq = 1, t = "msg", text = "one" })
  eq(seqScreen:onBattleEvent({ battle = "cb1", seq = 1, t = "msg", text = "one" }),
     false, "a sequence already applied is a duplicate")
  seqScreen:onBattleEvent({ battle = "cb1", seq = 5, t = "msg", text = "five" })
  eq(seqScreen.medGaps, 1, "a gap is counted rather than refused")
  seqScreen:onBattleEvent({ battle = "cb1", seq = 6, t = "turn" })
  eq(#lines(seqScreen), 2, "and what did arrive is drawn")

  -- Somebody else's fight is not this one, however well-formed it is.
  local other = screen({ slots = npcSlots(), mine = 1, host = false,
                         mode = "coop_npc", selfId = "bob" })
  other:uploadMediated()
  other:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })
  eq(other:onBattleEvent({ battle = "cb2", seq = 1, t = "msg", text = "elsewhere" }),
     false, "an event about another battle is not ours")
  eq(other:onBattleReady({ battle = "cb2", mode = "coop_pvp", sides = {} }), false,
     "and neither is another battle's roster")

  -- Nor is any of it, before the referee has said the field is assembled.
  local early = screen({ slots = npcSlots(), mine = 1, host = true,
                         mode = "coop_npc", selfId = "ann" })
  eq(early:onBattleEvent({ battle = "cb1", seq = 1, t = "msg", text = "early" }),
     false, "an event that beats mmo.battle_ready is dropped")
  eq(#early.messages, 0, "and draws nothing")
end

-- ------------------------------------------------------------------
-- 5b. mediated move animations
-- ------------------------------------------------------------------

do
  local animScreen = screen({ slots = npcSlots(), mine = 1, host = true,
                              mode = "coop_npc", selfId = "ann" })
  animScreen:uploadMediated()
  animScreen:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })

  local rows = animScreen:medRows({ t = "anim", slot = 0, text = "FIX_TACKLE" })
  eq(#rows, 1, "an anim event yields one row")
  eq(rows[1].kind, "anim", "and it is an anim row for playEvents")
  eq(rows[1].anim, "FIX_TACKLE", "carrying the move id")
  eq(rows[1].from, 1, "with from mapped through medSlots")

  eq(#animScreen:medRows({ t = "switch", slot = 0, text = SPECIES_NAME }), 0,
     "switch is a narration no-op -- send follows")
  eq(#animScreen:medRows({ t = "anim", text = "FIX_TACKLE" }), 0,
     "anim without a mapped slot yields nothing")
end

-- ------------------------------------------------------------------
-- 6. how it ends
-- ------------------------------------------------------------------
--
-- One message, from the only party that knows -- and turned back into a *side*
-- so the ordinary `over` row does the rest: the victory theme, the unranked
-- note and the trainer's parting line all hang off it, and none of them should
-- have a second implementation for a refereed fight.

do
  local function ended(opts)
    local self = screen(opts)
    self:uploadMediated()
    self:onBattleReady({ battle = "cb1", mode = opts.mode,
      sides = { a = { "ann", "bob" }, b = { "cal", "dee" } } })
    return self
  end

  local won = ended({ slots = pvpSlots(), mine = 1, host = true,
                      mode = "coop_pvp", selfId = "ann", ranksPoints = true })
  eq(won:onBattleOutcome({ battle = "cb1", outcome = "win",
    winners = { "ann", "bob" }, losers = { "cal", "dee" } }), true,
     "an outcome for this battle lands")
  eq(won.result, "win", "and a named winner won")
  eq(won.after, "over", "with the screen on its way out")

  local lost = ended({ slots = pvpSlots(), mine = 3, host = false,
                       mode = "coop_pvp", selfId = "cal", ranksPoints = true })
  eq(lost:onBattleOutcome({ battle = "cb1", outcome = "win",
    winners = { "ann", "bob" }, losers = { "cal", "dee" } }), true,
     "the same message reaches the other side")
  eq(lost.result, "loss",
     "and reads as a loss there -- the token is the field's point of view, so "
     .. "who is *named* is what makes it a sentence")

  -- A draw carries no lists at all (Wire refuses an empty one), which is why
  -- the absence is read as a draw rather than as a missing field.
  local drawn = ended({ slots = pvpSlots(), mine = 1, host = true,
                        mode = "coop_pvp", selfId = "ann", ranksPoints = true })
  drawn:onBattleOutcome({ battle = "cb1", outcome = "draw" })
  eq(drawn.result, "draw", "an outcome naming nobody is a draw")

  -- Why it ended, when there is a sentence for it. An unknown token is silent
  -- rather than printed raw: the result is the part that matters.
  local timedOut = ended({ slots = pvpSlots(), mine = 1, host = true,
                           mode = "coop_pvp", selfId = "ann" })
  timedOut:onBattleOutcome({ battle = "cb1", outcome = "win",
    winners = { "cal", "dee" }, losers = { "ann", "bob" }, reason = "timeout" })
  local blamed = false
  for _, row in ipairs(timedOut.messages) do
    local text = type(row) == "table" and row.text or row
    if type(text) == "string" and text:find("in time", 1, true) then blamed = true end
  end
  check(blamed, "a fight the clock ended says so")

  local strange = ended({ slots = pvpSlots(), mine = 1, host = true,
                          mode = "coop_pvp", selfId = "ann" })
  strange:onBattleOutcome({ battle = "cb1", outcome = "draw",
                            reason = "some_future_thing" })
  eq(strange.result, "draw", "a reason this build cannot phrase still ends it")

  local elsewhere = ended({ slots = pvpSlots(), mine = 1, host = true,
                            mode = "coop_pvp", selfId = "ann" })
  eq(elsewhere:onBattleOutcome({ battle = "cb2", outcome = "win",
    winners = { "ann" }, losers = { "cal" } }), false,
     "and another battle's verdict is not ours")
  eq(elsewhere.result, nil, "leaving this one running")

  -- The exit path is the client-simulated one, unchanged: `exit` is what hands
  -- the result to src/Coop.lua, which is where the blackout, the forget-a-move
  -- menu and the trainer's own onFinish all hang.
  local reported = {}
  local done = screen({ slots = pvpSlots(), mine = 1, host = true,
                        mode = "coop_pvp", selfId = "ann",
                        onDone = function(result) reported[#reported + 1] = result end })
  done:uploadMediated()
  done:onBattleReady({ battle = "cb1", mode = "coop_pvp",
    sides = { a = { "ann", "bob" }, b = { "cal", "dee" } } })
  done:onBattleOutcome({ battle = "cb1", outcome = "win",
    winners = { "ann", "bob" }, losers = { "cal", "dee" } })
  CoopBattle.exit(done)
  eq(#reported, 1, "the screen reports its result exactly once")
  eq(reported[1], "win", "and reports the referee's verdict")
end

-- ------------------------------------------------------------------
-- 7. waiting for the referee is not host-sim
-- ------------------------------------------------------------------
--
-- coop_pvp / coop_npc are always hub-refereed. Before battle_ready the host
-- must not resolve locally (that was the fidelity fork). CoopSim remains for
-- field layout and for suites that drive it directly.

do
  local host = screen({ slots = npcSlots(), mine = 1, host = true,
                        mode = "coop_npc", selfId = "ann" })
  host:uploadMediated()
  local calls = watchSim(host)
  host:commit({ slot = 1, kind = "move", move = 1, target = 3 })
  host:commit({ slot = 2, kind = "move", move = 1, target = 3 })
  eq(host.mediated, false, "with nothing refereeing yet, not marked ready")
  eq(calls.resolveTurn, 0, "and the host does not resolve locally")
  eq(calls.npcAction, 0, "or choose for the trainer")
  eq(host.countSent(Wire.BATTLE_CHOICE), 0,
     "choices are not on the battle wire until ready")

  host:openTurn()
  eq(host.turnOpened, nil, "no client-sim deadline while mediation is owed")

  eq(CoopBattle.mediates("coop_pvp"), true, "coop_pvp is always refereed")
  eq(CoopBattle.mediates("coop_npc"), true, "coop_npc is always refereed")
  eq(CoopBattle.mediates("1v1"), false, "1v1 uses MediatedBattle, not this gate")
  -- Mutating the docs table must not reopen host-sim for shipped modes.
  local restore = Config.MEDIATED_COOP
  Config.MEDIATED_COOP = { coop_pvp = false, coop_npc = false }
  eq(CoopBattle.mediates("coop_pvp"), true,
     "Config.MEDIATED_COOP is not a runtime off-switch")
  Config.MEDIATED_COOP = restore
end

-- ------------------------------------------------------------------
-- 7b. wait line names who still owes a choice (chose events)
-- ------------------------------------------------------------------
--
-- Mediated co-op has no `act` fan-out. The referee emits `chose` when a seat
-- answers; the screen must apply it immediately so missingActors drops them.

do
  local watcher = screen({ slots = pvpSlots(), mine = 1, host = false,
                           mode = "coop_pvp", selfId = "ann" })
  watcher:uploadMediated()
  watcher:onBattleReady({ battle = "cb1", mode = "coop_pvp",
    sides = { a = { "ann", "bob" }, b = { "cal", "dee" } } })
  watcher.phase = "wait"
  watcher.waitShown = Config.COOP_WAIT_HINT + 1
  watcher.acted = nil

  local before = watcher:missingActors()
  check(#before >= 1, "before any chose, somebody is still owed")

  -- Peer Bob (field slot 1 -> screen index via medSlots) answered.
  local bobField = watcher.medFields and watcher.medFields[2]
  check(bobField ~= nil or (watcher.medSlots and watcher.medSlots[1] ~= nil),
        "medMap placed Bob on a field slot")
  local bobSlot = watcher.medSlots[1]
  eq(watcher:onBattleEvent({
    battle = "cb1", seq = 1, t = "chose",
    slot = 1, side = "a", text = "BOB",
  }), true, "chose is accepted")
  eq(watcher.acted[bobSlot], true, "and marks that seat acted immediately")

  local after = watcher:missingActors()
  local stillBob = false
  for _, name in ipairs(after) do
    if name == "BOB" then stillBob = true end
  end
  eq(stillBob, false, "wait line no longer names the seat that chose")

  local line = watcher:waitLine()
  check(line ~= nil and not line:find("BOB", 1, true),
        "the on-screen countdown omits who already answered")

  eq(watcher:onBattleEvent({
    battle = "cb1", seq = 2, t = "unchose",
    slot = 1, side = "a", text = "BOB",
  }), true, "unchose is accepted")
  eq(watcher.acted[bobSlot], false, "and clears the acted mark")

  local again = watcher:missingActors()
  local bobBack = false
  for _, name in ipairs(again) do
    if name == "BOB" then bobBack = true end
  end
  eq(bobBack, true, "the seat is owed again after unchose")

  watcher.acted = { [3] = true, [4] = true }
  line = watcher:waitLine()
  check(line ~= nil and line:find("BOB", 1, true),
        "the wait line can name BOB again")
end

-- ------------------------------------------------------------------
-- 7c. wait-line rotation and medFlush on empty batches
-- ------------------------------------------------------------------

do
  local rot = screen({ slots = pvpSlots(), mine = 1, host = false,
                       mode = "coop_pvp", selfId = "ann" })
  rot:uploadMediated()
  rot:onBattleReady({ battle = "cb1", mode = "coop_pvp",
    sides = { a = { "ann", "bob" }, b = { "cal", "dee" } } })
  rot.phase = "wait"
  rot.acted = { [4] = true }
  rot.waitShown = Config.COOP_WAIT_HINT + 1

  local missing = rot:missingActors()
  eq(#missing, 2, "two seats still owed for rotation")
  local rotate = Config.COOP_WAIT_ROTATE or 3

  local line = rot:waitLine()
  check(line ~= nil and line:find(missing[1], 1, true),
        "the wait line names the first missing seat")

  rot.waitShown = math.max(Config.COOP_WAIT_HINT, rotate)
  line = rot:waitLine()
  -- Production waitLine uses "&N" (CoopBattle:waitLine), not "+N".
  check(line ~= nil and line:find("&1", 1, true),
        "and the '&1' tail names the other missing seat when there is room")
end

do
  local flush = screen({ slots = pvpSlots(), mine = 1, host = false,
                          mode = "coop_pvp", selfId = "ann" })
  flush:uploadMediated()
  flush:onBattleReady({ battle = "cb1", mode = "coop_pvp",
    sides = { a = { "ann", "bob" }, b = { "cal", "dee" } } })
  flush:markActed(2)
  flush.waitShown = Config.COOP_WAIT_HINT + 3
  flush.medPending = {}

  eq(flush:medFlush(), false, "an empty flush still returns false")
  eq(flush.acted, nil, "but clears acted")
  eq(flush.waitShown, 0, "and resets the wait countdown")

  flush:markActed(2)
  flush.waitShown = Config.COOP_WAIT_HINT + 3
  flush.medSeq = 1
  flush:onBattleEvent({ battle = "cb1", seq = 2, t = "turn" })
  eq(flush.acted, nil, "a turn with nothing pending clears acted too")
  eq(flush.waitShown, 0, "and resets the wait countdown")
end

-- ------------------------------------------------------------------
-- 8. which modes this build actually referees
-- ------------------------------------------------------------------
--
-- A flag rather than a fact, and the reasons are in src/Config.lua. Pinned here
-- because the two co-op modes are deliberately not in the same state, and a
-- suite that read the flag to decide what to expect would pass whatever it said.

do
  Config.MEDIATED_COOP = SHIPPED

  eq(SHIPPED.coop_pvp, true, "party-versus-party is refereed in this build")
  eq(CoopBattle.mediates("coop_pvp"), true, "so a coop_pvp screen uploads")

  -- On as of the version that gave the intermediator two npc seats and an
  -- answer for them; the reasons it was ever off are in src/Config.lua, and
  -- section 2 above is what proves they are both gone.
  eq(SHIPPED.coop_npc, true, "and so is party-versus-NPC")
  eq(CoopBattle.mediates("coop_npc"), true, "so a coop_npc screen uploads too")

  eq(CoopBattle.mediates("1v1"), false,
     "a 1v1 is not a co-op battle at all -- src/MediatedBattle.lua owns that one")
  eq(CoopBattle.mediates(nil), false, "and a battle with no mode is not refereed")

  eq(CoopBattle.mediates("coop_wild"), true,
     "party-versus-wild is refereed in this build too")
end

-- ------------------------------------------------------------------
-- 9. Party vs Wild wire vocabulary (TT3 — headless predicates)
-- ------------------------------------------------------------------
--
-- Hub seating for coop_wild lives in hub_battle / TT2; here we only pin the
-- client-side mode token the divert path posts on COOP_WAIT and the sanitiser
-- that drops anything else.

do
  eq(Wire.coopOfferMode("coop_wild"), "coop_wild",
     "only coop_wild is a recognised offer mode")
  eq(Wire.coopOfferMode(nil), nil, "absent mode stays absent")
  eq(Wire.coopOfferMode("coop_npc"), nil, "trainer-shaped tokens are rejected")
  eq(Wire.coopOfferMode("garbage"), nil, "and so is garbage")

  local key = "FIX_TOWN|FIXMON_A|5"
  check(Wire.battleKey(key) == key, "fixture battle key is wire-clean")
  local pid = testPlayerId("coop_wild_wire")
  local wild = Wire.coopOffer({
    from = pid, name = "ANN", battle = key, map = "FIX_TOWN", mode = "coop_wild",
  })
  check(wild ~= nil, "a coop_wild offer survives Wire.coopOffer")
  eq(wild.mode, "coop_wild", "and keeps the mode")

  local trainer = Wire.coopOffer({
    from = pid, name = "ANN", battle = key, map = "FIX_TOWN", mode = "coop_npc",
  })
  check(trainer ~= nil, "an unknown mode does not refuse the whole offer")
  eq(trainer.mode, nil, "it is dropped instead")
end

-- ------------------------------------------------------------------
-- 10. Party vs Wild mediated exp (CoopBattle:gainExp via medRows/medFlush)
-- ------------------------------------------------------------------
--
-- coop_wild's referee narrates a knockout the same way coop_npc's does: a
-- `faint` on the loser's slot, then one `exp` per standing winner (species,
-- level, participants -- never an amount). Round 4 above (main suite) proves
-- the formula and the display clock against the host-simulated path
-- (CoopSim); this proves the same machinery reached through the wire path
-- instead -- onBattleEvent -> medRows -> medFlush -> playEvents -- on a
-- coop_wild-shaped screen holding the live save party, the same one
-- src/Coop.lua's buildField hands a party-vs-wild encounter.

do
  local Experience = require("src.battle.Experience")

  -- Prime CoopBattle's private `engine` cache the only way the module
  -- exposes: monFromCaughtSheet calls loadEngine(game) before anything else.
  -- Without this, a screen built by hand (as `screen()` above does, rather
  -- than through M.new) never triggers it, and gainExp's own `eng.Experience`
  -- read is silently nil -- an award that never lands and never warns either,
  -- because gainExp returns before reaching anything worth logging.
  CoopBattle.monFromCaughtSheet({ data = data }, { species = "NOT A SPECIES" })

  -- ANN's seat holds `game.save.party` *by reference*, exactly as the real
  -- field is built, so a level-up lands on the very table the save keeps.
  local function wildSlots(game)
    return {
      { side = "a", owner = "ann", name = "ANN", party = game.save.party },
      { side = "a", owner = "bob", name = "BOB", party = { mon(60, 30) } },
      { side = "b", owner = nil, name = "WILD", party = { mon(50, 20) } },
    }
  end

  -- Parked one point short of level 6 so a 50-level knockout's award crosses
  -- level 7, where the fixture species (FIXMON_A) learns FIX_EMBERISH -- the
  -- "grew to" row is part of what the order assertion below proves.
  local function wildGame()
    local g = newGame()
    g.save.party = { { species = SPECIES, level = 5, hp = 20, exp = 179,
      stats = { hp = 20, attack = 30, defense = 30, special = 30, speed = 40 },
      dvs = { hp = 8, attack = 8, defense = 8, speed = 8, special = 8 },
      statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 },
      moves = { { id = "FIX_TACKLE", pp = 20 } },
    } }
    return g
  end

  local function wildScreen(opts)
    opts = opts or {}
    local game = opts.game or wildGame()
    local built = screen({
      game = game, slots = wildSlots(game), mine = 1, host = true,
      battleId = "cb-wild", selfId = "ann",
      mode = (opts.mode ~= "none") and (opts.mode or "coop_wild") or nil,
    })
    built.trainer = opts.trainer
    return built, game
  end

  -- Row classification the way drive_coop_exp.lua's rowsOf() reads the same
  -- queue: what src/CoopBattle.lua actually stamps a row with, not a copy.
  -- `M:say` (the "gained"/"grew"/"learned" lines `gainExp`/`levelled` queue)
  -- pushes plain strings; the `msg` kind `medRows`/`playEvents` translate the
  -- referee's own sentences through (the "fainted!" line) pushes a `{ text =
  -- ... }` table instead -- both are a text page as far as this is concerned.
  local function rowText(row)
    if type(row) == "string" then return row end
    if type(row) == "table" and type(row.text) == "string" then return row.text end
    return nil
  end
  local function rowKind(row)
    if type(row) == "table" then
      if row.faintfx then return "faintfx" end
      if row.expfill then return "expfill" end
      if row.drain then return "drain" end
    end
    local text = rowText(row)
    if text then
      if text:find("fainted", 1, true) then return "fainted-text" end
      if text:find("gained", 1, true) then return "gained-text" end
      if text:find("grew to", 1, true) then return "grew-text" end
      if text:find("learned", 1, true) then return "learned-text" end
      return "text"
    end
    return nil
  end
  local function firstIndex(self, kind)
    for i, row in ipairs(self.messages) do
      if rowKind(row) == kind then return i end
    end
    return nil
  end
  -- A mediated faint now queues its own drain-to-zero row (medRows: `damage`
  -- ahead of `faint`, so a bar with no killing-blow `damage` of its own still
  -- animates down before the sink) -- a second, unrelated "drain" kind row on
  -- the same queue as the exp climb. `lastIndex` reads past it to the one an
  -- exp award actually queued.
  local function lastIndex(self, kind)
    local found = nil
    for i, row in ipairs(self.messages) do
      if rowKind(row) == kind then found = i end
    end
    return found
  end

  -- ------- own share paid (participants honored), partner's share ignored,
  -- and the row order the batch queues.
  do
    local host, game = wildScreen()
    check(host:onBattleReady({ battle = "cb-wild",
      sides = { a = { "ann", "bob" }, b = { "wild" } } }),
      "coop_wild battle_ready accepted, mediation on")

    local winner = game.save.party[1]
    local before = winner.exp

    host:onBattleEvent({ battle = "cb-wild", seq = 1, t = "faint",
      slot = Config.COOP_SIDE, text = SPECIES_NAME })
    host:onBattleEvent({ battle = "cb-wild", seq = 2, t = "exp",
      slot = 0, species = SPECIES_NAME, level = 50, participants = 2 })
    host:onBattleEvent({ battle = "cb-wild", seq = 3, t = "exp",
      slot = 1, species = SPECIES_NAME, level = 50, participants = 2 })
    eq(#host.messages, 0, "nothing is paid or printed before the turn closes the batch")
    host:onBattleEvent({ battle = "cb-wild", seq = 4, t = "turn" })

    local expected = Experience.gainFor(data.pokemon[SPECIES], 50, false, 2, false)
    eq(winner.exp - before, expected,
       "the save mon was paid the HALVED share -- participants honored, "
       .. "matching Experience.gainFor(def, level, false, 2, false) exactly")
    check(winner.exp - before
          ~= Experience.gainFor(data.pokemon[SPECIES], 50, false, 1, false),
          "...and not the whole knockout (the winners/participants spelling bug)")
    check(game.save.party[1] == winner and winner.level > 5,
          "it is the save party entry that leveled")

    local partner = host.sim:slot(2).battler.mon
    eq(partner.exp, nil,
       "the partner's own share was not paid by this client -- never even touched")

    local iDrainZero = firstIndex(host, "drain")
    local iFaintFx = firstIndex(host, "faintfx")
    local iFainted = firstIndex(host, "fainted-text")
    local iGained = firstIndex(host, "gained-text")
    local iFill = firstIndex(host, "expfill")
    local iGrew = firstIndex(host, "grew-text")
    local iClimb = lastIndex(host, "drain")
    check(iDrainZero and iFaintFx and iFainted and iGained and iFill and iGrew
          and iClimb,
          "the faint's drain-to-zero row, faintfx, fainted-text, gained-text, "
          .. "expfill, grew-text and the HP climb are all queued")
    check(iDrainZero ~= iClimb,
          "...and the drain-to-zero row is a different row from the exp climb")
    check(iDrainZero < iFaintFx and iFaintFx < iFainted and iFainted < iGained
          and iGained < iFill and iFill < iGrew and iGrew < iClimb,
          "in order: the faint's own drain-to-zero -> faintfx -> "
          .. "fainted-text -> gained-text -> expfill -> grew -> HP climb")
  end

  -- ------- round 8's money regression: a faint with NO killing-blow `damage`
  -- of its own -- the dropped-lethal-damage case scratchpad/n2_drive_a2.lua
  -- caught -- still leaves the corpse at hp == 0 and down, not merely sunk on
  -- screen with its local copy still reading pre-KO HP. Before the HP-
  -- authoritative fix (playEvents' `faint` branch, mirroring
  -- src/MediatedBattle.lua:1899-1900) a stream that lost that one event left
  -- `isDown` false, and a later `snapDisplay` -- which re-derives
  -- `displayFainted` from `isDown` -- stood the "fainted" monster back up
  -- with the bar it had before the blow that killed it.
  do
    local host, game = wildScreen()
    check(host:onBattleReady({ battle = "cb-wild",
      sides = { a = { "ann", "bob" }, b = { "wild" } } }),
      "coop_wild battle_ready accepted, mediation on")

    -- `Config.COOP_SIDE` is the wire's FIELD slot for side b's first seat,
    -- not the sim's own slot index -- `medSlots` (built by `onBattleReady`'s
    -- `medMap`) is what translates one into the other, exactly as `medSlotOf`
    -- does for every real wire event.
    local foeIndex = (host.medSlots or {})[Config.COOP_SIDE]
    local foeSlot = host.sim:slot(foeIndex)
    local foeBattler = foeSlot.battler
    check(foeBattler ~= nil and (foeBattler.mon.hp or 0) > 0,
          "the wild foe starts alive, with hp above zero")

    -- No `damage` event at all reaches this client for the kill -- exactly
    -- the dropped-lethal-blow case: the referee's `faint` is the only thing
    -- this client ever hears about it. `turn` closes the batch the same way
    -- every other section in this file does.
    host:onBattleEvent({ battle = "cb-wild", seq = 1, t = "faint",
      slot = Config.COOP_SIDE, text = SPECIES_NAME })
    host:onBattleEvent({ battle = "cb-wild", seq = 2, t = "turn" })

    eq(foeBattler.mon.hp, 0,
       "the faint alone zeroes the party record's hp -- authoritative, not "
       .. "merely a drawing fact deferred to a `damage` that never arrives")
    check(host.sim:isDown(foeSlot), "...so the sim agrees the seat is down")

    -- Drain the queue -- the faintfx row actually plays and latches
    -- `displayFainted` (src/CoopBattle.lua:3549) -- then snap repeatedly, the
    -- way an idle client between turns does.
    local guard = 0
    while (#host.messages > 0 or host.shown ~= nil or host.faintFx
           or host.draining or host.expFilling) and guard < 3000 do
      host:update(1 / 60)
      guard = guard + 1
    end
    check(guard < 3000, "the sink resolves in a bounded number of frames")
    host:snapDisplay()
    host:snapDisplay()
    check(foeBattler.displayFainted == true,
          "the seat stays latched down across repeated snapDisplay calls -- "
          .. "no un-fainting")
    eq(foeBattler.mon.hp, 0, "...and the bar has nothing to climb back to")
  end

  -- ------- an unmatchable species token warns once and pays nothing
  do
    local before = #warns
    local host, game = wildScreen()
    host:onBattleReady({ battle = "cb-wild",
      sides = { a = { "ann", "bob" }, b = { "wild" } } })
    local winner = game.save.party[1]
    local expBefore = winner.exp

    host:onBattleEvent({ battle = "cb-wild", seq = 1, t = "faint",
      slot = Config.COOP_SIDE, text = "NOT A SPECIES" })
    host:onBattleEvent({ battle = "cb-wild", seq = 2, t = "exp",
      slot = 0, species = "NOT A SPECIES", level = 50, participants = 2 })
    host:onBattleEvent({ battle = "cb-wild", seq = 3, t = "turn" })

    eq(winner.exp, expBefore, "an unmatchable species pays nothing")
    eq(#warns, before + 1, "...and is warned about exactly once")
    check(warns[#warns] ~= nil and warns[#warns]:find("could not match", 1, true) ~= nil,
          "naming the miss: " .. tostring(warns[#warns]))

    -- A second unmatchable event in the same fight stays silent -- the first
    -- line already said this build cannot describe this referee's species.
    host:onBattleEvent({ battle = "cb-wild", seq = 4, t = "faint",
      slot = Config.COOP_SIDE, text = "NOT A SPECIES" })
    host:onBattleEvent({ battle = "cb-wild", seq = 5, t = "exp",
      slot = 0, species = "NOT A SPECIES", level = 50, participants = 2 })
    host:onBattleEvent({ battle = "cb-wild", seq = 6, t = "turn" })
    eq(#warns, before + 1, "and a second miss in the same fight is not said again")
  end

  -- ------- coop_wild pays the wild rate, coop_npc pays x1.5, for identical
  -- inputs -- pinned against Experience.gainFor so a mode/isTrainer
  -- regression shows up as a wrong number rather than a vibe
  do
    local wild = wildScreen()
    wild:onBattleReady({ battle = "cb-wild",
      sides = { a = { "ann", "bob" }, b = { "wild" } } })
    local wMon = wild.sim:slot(1).battler.mon
    wMon.level, wMon.exp = 50, 1000000   -- no level-up, so the number is readable
    local wBefore = wMon.exp
    wild:onBattleEvent({ battle = "cb-wild", seq = 1, t = "faint",
      slot = Config.COOP_SIDE, text = SPECIES_NAME })
    wild:onBattleEvent({ battle = "cb-wild", seq = 2, t = "exp",
      slot = 0, species = SPECIES_NAME, level = 50, participants = 2 })
    wild:onBattleEvent({ battle = "cb-wild", seq = 3, t = "turn" })
    local wildGain = wMon.exp - wBefore

    local npc = wildScreen({ mode = "coop_npc" })
    npc:onBattleReady({ battle = "cb-wild",
      sides = { a = { "ann", "bob" }, b = { "wild" } } })
    local nMon = npc.sim:slot(1).battler.mon
    nMon.level, nMon.exp = 50, 1000000
    local nBefore = nMon.exp
    npc:onBattleEvent({ battle = "cb-wild", seq = 1, t = "faint",
      slot = Config.COOP_SIDE, text = SPECIES_NAME })
    npc:onBattleEvent({ battle = "cb-wild", seq = 2, t = "exp",
      slot = 0, species = SPECIES_NAME, level = 50, participants = 2 })
    npc:onBattleEvent({ battle = "cb-wild", seq = 3, t = "turn" })
    local npcGain = nMon.exp - nBefore

    eq(wildGain, Experience.gainFor(data.pokemon[SPECIES], 50, false, 2, false),
       "coop_wild pays isTrainer=false")
    eq(npcGain, Experience.gainFor(data.pokemon[SPECIES], 50, true, 2, false),
       "coop_npc pays isTrainer=true (x1.5)")
    check(npcGain > wildGain, "...visibly larger for identical inputs")
  end

  -- ------- the host-sim path (no mode, CoopSim's own `winners` spelling) is
  -- unchanged: still divides, and a trainer record still pays x1.5
  do
    local hostSim = wildScreen({ mode = "none", trainer = { id = "FIX_TRAINER" } })
    local mon1 = hostSim.sim:slot(1).battler.mon
    mon1.level, mon1.exp = 50, 1000000
    local before = mon1.exp
    hostSim:playEvents({ { kind = "exp", slot = 1, species = SPECIES, level = 50,
                           winners = 2, amount = 999 } })
    eq(mon1.exp - before,
       Experience.gainFor(data.pokemon[SPECIES], 50, true, 2, false),
       "`winners` still divides, and a host-sim trainer fight still pays x1.5")

    local hostPvp = wildScreen({ mode = "none" })
    local mon2 = hostPvp.sim:slot(1).battler.mon
    mon2.level, mon2.exp = 50, 1000000
    local before2 = mon2.exp
    hostPvp:playEvents({ { kind = "exp", slot = 1, species = SPECIES, level = 50,
                          winners = 2 } })
    eq(mon2.exp - before2,
       Experience.gainFor(data.pokemon[SPECIES], 50, false, 2, false),
       "and a host-sim fight with no trainer record pays the wild rate")
  end

  -- ------- round 6: participation-based exp -- benched awards, on both the
  -- host-sim path (CoopSim's own `winners` spelling) and the mediated path
  -- (`participants`, reached through medRows/medFlush).
  --
  -- Vanilla pays every party member that fought the fallen foe and is still
  -- alive, benched included (src/CoopSim.lua's `markFielded`/
  -- `participantsFor`), and both wires now say WHICH of a seat's party is
  -- owed a share with the referee's `mon` field (0-based). Everything above
  -- this block is the single-mon, always-active case, where `mon` never
  -- needed to matter; this is the general one.
  do
    local FOE = "FIXMON_B"
    local FOE_NAME = Wire.name(data.pokemon[FOE].name)

    local function partyMon()
      return { species = SPECIES, level = 10, hp = 20, exp = 0,
        stats = { hp = 20, attack = 30, defense = 30, special = 30, speed = 40 },
        dvs = { hp = 8, attack = 8, defense = 8, speed = 8, special = 8 },
        statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 },
        moves = { { id = "FIX_TACKLE", pp = 20 } },
      }
    end
    local function benchGame(n)
      local g = newGame()
      g.save.party = {}
      for i = 1, (n or 3) do g.save.party[i] = partyMon() end
      return g
    end
    local function countKind(self, kind)
      local n = 0
      for _, row in ipairs(self.messages) do
        if rowKind(row) == kind then n = n + 1 end
      end
      return n
    end

    -- ------- (a) host-sim path: the active AND the bench are paid, each on
    -- its own party index, and only the active's strip fills.
    do
      local game = benchGame(3)
      local active, bench, bystander =
        game.save.party[1], game.save.party[2], game.save.party[3]
      local host = wildScreen({ game = game, mode = "coop_npc" })
      local a0, b0, c0 = active.exp, bench.exp, bystander.exp

      host:playEvents({
        { kind = "faint", slot = 3 },
        -- one event per paid participant, same slot, contiguous
        { kind = "exp", slot = 1, mon = 0, species = FOE, level = 50, winners = 2 },
        { kind = "exp", slot = 1, mon = 1, species = FOE, level = 50, winners = 2 },
      })

      check(active.exp > a0, "the active (mon=0) was paid on its party index")
      check(bench.exp > b0, "the BENCHED participant (mon=1) was paid too")
      eq(bystander.exp, c0, "a party member the referee did not name gained nothing")
      local share = Experience.gainFor(data.pokemon[FOE], 50, true, 2, false)
      eq(active.exp - a0, share, "the active's gain is the engine's own halved share")
      eq(bench.exp - b0, share, "...and the bench's is the same share, not a fraction")

      eq(countKind(host, "gained-text"), 2, "two gained-texts -- nothing collapsed the two awards")
      eq(countKind(host, "expfill"), 1, "exactly ONE fill row: only the active animates")
      eq(countKind(host, "drain"), 1, "...and one HP climb, likewise active-only")
    end

    -- ------- (a2) a benched-only award never touches the active's strip, and
    -- its gained-text names the BENCH's species, not the beaten foe's (the
    -- `def` mix-up round 6 fixed).
    do
      local game = benchGame(2)
      local active, bench = game.save.party[1], game.save.party[2]
      local host = wildScreen({ game = game, mode = "coop_npc" })
      local battler = host.sim:slot(1).battler
      host:seedExpClock(battler)
      local seededFrac, seededLevel = battler.shownExpFrac, battler.shownLevel
      local a0 = active.exp

      host:playEvents({
        { kind = "faint", slot = 3 },
        { kind = "exp", slot = 1, mon = 1, species = FOE, level = 60, winners = 1 },
      })

      check(bench.exp > 0, "the benched mon banked the award")
      eq(active.exp, a0, "the active gained nothing from it")
      eq(battler.shownExpFrac, seededFrac, "the active's shown fraction never moved")
      eq(battler.shownLevel, seededLevel, "...nor its level pill")
      eq(countKind(host, "expfill"), 0, "no fill row was queued for a bench award")
      eq(countKind(host, "drain"), 0, "...and no HP climb either")
      eq(countKind(host, "gained-text"), 1, "the gained-text still printed")
      check(countKind(host, "grew-text") > 0, "and the bench's level-up text ran")

      local gainedLine
      for _, row in ipairs(host.messages) do
        if rowKind(row) == "gained-text" then gainedLine = rowText(row) break end
      end
      check(gainedLine ~= nil and gainedLine:find(data.pokemon[SPECIES].name, 1, true) ~= nil,
            "the bench's gained-text names the bench's own species")
      check(gainedLine ~= nil and gainedLine:find(data.pokemon[FOE].name, 1, true) == nil,
            "...and never the beaten monster's")
    end

    -- ------- (b) the mediated path: medRows carries `mon` through untouched,
    -- and onBattleEvent -> medFlush pays the bench the same way the host-sim
    -- path does.
    do
      local game = benchGame(3)
      local active, bench, bystander =
        game.save.party[1], game.save.party[2], game.save.party[3]
      local fight = wildScreen({ game = game, mode = "coop_npc" })
      check(fight:onBattleReady({ battle = "cb-wild",
        sides = { a = { "ann", "bob" }, b = { "npc" } } }),
        "battle_ready accepted, mediation on")

      local rows = fight:medRows({ t = "exp", slot = 0, species = FOE_NAME,
                                   level = 50, participants = 2, mon = 1 })
      eq(#rows, 1, "one exp row out of the builder")
      eq(rows[1].kind, "exp", "...of kind exp")
      eq(rows[1].mon, 1, "`mon` is carried through the row builder untouched")
      eq(rows[1].participants, 2, "...beside `participants`")
      eq(rows[1].species, FOE, "the wire token still resolves to the registry key")
      eq(rows[1].slot, 1, "...and the field slot still translates to our seat index")

      local a0, b0, c0 = active.exp, bench.exp, bystander.exp
      fight:onBattleEvent({ battle = "cb-wild", seq = 1, t = "faint",
        slot = Config.COOP_SIDE, text = FOE_NAME })
      fight:onBattleEvent({ battle = "cb-wild", seq = 2, t = "exp", slot = 0,
        species = FOE_NAME, level = 50, participants = 2, mon = 0 })
      fight:onBattleEvent({ battle = "cb-wild", seq = 3, t = "exp", slot = 0,
        species = FOE_NAME, level = 50, participants = 2, mon = 1 })
      eq(#fight.messages, 0, "nothing lands before the batch closes")
      fight:onBattleEvent({ battle = "cb-wild", seq = 4, t = "turn" })

      local share = Experience.gainFor(data.pokemon[FOE], 50, true, 2, false)
      eq(active.exp - a0, share, "the active was paid its share over the wire")
      eq(bench.exp - b0, share, "the benched participant was paid its own")
      eq(bystander.exp, c0, "the unnamed party member gained nothing")
      eq(countKind(fight, "gained-text"), 2, "two gained-texts through the mediated queue")
      eq(countKind(fight, "expfill"), 1, "one fill row -- active only")
      -- Two "drain" rows now, not one: medRows queues its own drain-to-zero
      -- row ahead of the faint (the same fix the order pin above covers), and
      -- that is a different row from the exp climb this section is actually
      -- about. Read past it with lastIndex the same way.
      eq(countKind(fight, "drain"), 2,
         "two drains: the faint's own drain-to-zero, and the exp climb")
      check(lastIndex(fight, "drain") ~= firstIndex(fight, "drain"),
            "...and they are two different rows, not the same one counted twice")
    end

    -- ------- (c) `mon` absent (a PROTOCOL 21 referee) -- both paths fall
    -- back to paying the active, exactly as round 5 did.
    do
      local game = benchGame(2)
      local active, bench = game.save.party[1], game.save.party[2]
      local host = wildScreen({ game = game, mode = "coop_npc" })
      local a0, b0 = active.exp, bench.exp
      host:playEvents({
        { kind = "faint", slot = 3 },
        { kind = "exp", slot = 1, species = FOE, level = 50, winners = 1 },
      })
      check(active.exp > a0, "host-sim, no mon: the active was paid")
      eq(bench.exp, b0, "...and the bench was not")
      eq(countKind(host, "expfill"), 1, "...and the strip still fills for it")
    end
    do
      local game = benchGame(2)
      local active, bench = game.save.party[1], game.save.party[2]
      local fight = wildScreen({ game = game, mode = "coop_npc" })
      fight:onBattleReady({ battle = "cb-wild",
        sides = { a = { "ann", "bob" }, b = { "npc" } } })
      local a0, b0 = active.exp, bench.exp
      fight:onBattleEvent({ battle = "cb-wild", seq = 1, t = "faint",
        slot = Config.COOP_SIDE, text = FOE_NAME })
      fight:onBattleEvent({ battle = "cb-wild", seq = 2, t = "exp", slot = 0,
        species = FOE_NAME, level = 50, participants = 1 })
      fight:onBattleEvent({ battle = "cb-wild", seq = 3, t = "turn" })
      check(active.exp > a0, "mediated, no mon: the active was paid")
      eq(bench.exp, b0, "...and the bench was not")
      eq(countKind(fight, "expfill"), 1, "...and the strip still fills for it")
    end

    -- ------- (d) EXP.ALL's second pass runs once per knockout, not once per
    -- award: a bystander in neither award still banks the spread only once.
    do
      local function run(paidMons)
        local game = benchGame(3)
        game.save.inventory.EXP_ALL = 1
        local active, bench, bystander =
          game.save.party[1], game.save.party[2], game.save.party[3]
        local fight = wildScreen({ game = game, mode = "coop_npc" })
        local events = { { kind = "faint", slot = 3 } }
        for _, index in ipairs(paidMons) do
          events[#events + 1] = { kind = "exp", slot = 1, mon = index,
                                  species = FOE, level = 50, winners = 2 }
        end
        fight:playEvents(events)
        return bystander.exp, active.exp, bench.exp
      end
      local oneAward = run({ 0 })
      local twoAwards = run({ 0, 1 })
      eq(twoAwards, oneAward,
         "a bystander banks the EXP.ALL half ONCE however many of ours were paid")
      check(oneAward > 0, "...and it really is being spread (non-zero)")

      -- Two knockouts in one batch still spread twice.
      local game = benchGame(3)
      game.save.inventory.EXP_ALL = 1
      local bystander = game.save.party[3]
      local fight = wildScreen({ game = game, mode = "coop_npc" })
      local before = bystander.exp
      fight:playEvents({
        { kind = "faint", slot = 3 },
        { kind = "exp", slot = 1, mon = 0, species = FOE, level = 50, winners = 2 },
        { kind = "faint", slot = 3 },
        { kind = "exp", slot = 1, mon = 0, species = FOE, level = 50, winners = 2 },
      })
      check(bystander.exp - before > oneAward,
            "two knockouts in one batch still spread twice, not once")

      -- The direct-call path (no faint ever narrated) is unmetered, as
      -- before: `mon = 0` pays only the first party member directly, so the
      -- second's gain can only be the EXP.ALL spread.
      local directGame = benchGame(2)
      directGame.save.inventory.EXP_ALL = 1
      local directOther = directGame.save.party[2]
      local direct = wildScreen({ game = directGame, mode = "coop_npc" })
      local directBefore = directOther.exp
      direct:gainExp({ slot = 1, mon = 0, species = FOE, level = 50, winners = 1 })
      check(directOther.exp > directBefore, "a harness-driven award still spreads its half")
    end
  end

  -- ------- round 6 follow-up (J2): the mediated `mon` field counts in the
  -- space the uploaded SHEETS were cut from, not the save-party array
  -- position -- and the row that carries it, not the screen it arrived on,
  -- is what decides whether that translation runs at all.
  --
  -- `Mediated.snapshotMons` skips any party member it cannot describe, which
  -- shifts the sheet index of everyone after the skip; `medPartySlot` reads
  -- that shift back off each sheet's own `slot` stamp
  -- (src/CoopBattle.lua:6482). `medRows` is the only place that stamps a row
  -- `med = true`; CoopSim's own `playEvents` rows never do, so a host-sim
  -- event resolves `mon` straight off the seat's party array even when this
  -- screen happens to be holding an unrelated `medMine` -- the discriminator
  -- is the row, not `self.mediated`/`self.medMine`.
  local function expMon(opts)
    opts = opts or {}
    local m = {
      species = SPECIES, level = opts.level or 10, hp = opts.hp or 20,
      exp = opts.exp or 0,
      stats = { hp = 20, attack = 30, defense = 30, special = 30, speed = 40 },
      dvs = { hp = 8, attack = 8, defense = 8, speed = 8, special = 8 },
      statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 },
      moves = { { id = "FIX_TACKLE", pp = 20 } },
    }
    if opts.indescribable then m.moves = {} end
    return m
  end

  -- (a) a skipped member shifts the mediated index -- the referee's `mon`
  -- still lands on the save monster the sheet actually describes.
  do
    local game = newGame()
    game.save.party = { expMon({ indescribable = true }), expMon(), expMon() }
    local host = wildScreen({ game = game })
    -- A real coop_wild screen is built with the wild seat's sheets already in
    -- hand (src/CoopBattle.lua's constructor takes `wildParty`); this harness
    -- builds the screen by hand, so it stands in the same shape rather than
    -- exercising the unrelated "no wild sheets at all" refusal.
    host.wildParty = Mediated.snapshotMons(game, { mon(50, 20) })
    eq(host:uploadMediated(), true, "the party uploads despite the skipped member")

    local mine = Mediated.snapshotMons(game, game.save.party)
    eq(type(host.medMine), "table", "the uploaded sheets are stashed on the screen")
    eq(#mine, 2, "snapshotMons skipped the indescribable member")
    eq(mine[1].slot, 1, "sheet 1 stamps party position 1 (0-based)")
    eq(mine[2].slot, 2, "sheet 2 stamps party position 2 (0-based) -- the shift")

    check(host:onBattleReady({ battle = "cb-wild",
      sides = { a = { "ann", "bob" }, b = { "wild" } } }), "mediation on")

    local wrong, right = game.save.party[2], game.save.party[3]
    local wrongBefore, rightBefore = wrong.exp, right.exp

    host:onBattleEvent({ battle = "cb-wild", seq = 1, t = "faint",
      slot = Config.COOP_SIDE, text = SPECIES_NAME })
    host:onBattleEvent({ battle = "cb-wild", seq = 2, t = "exp", slot = 0,
      species = SPECIES_NAME, level = 50, participants = 1, mon = 1 })
    host:onBattleEvent({ battle = "cb-wild", seq = 3, t = "turn" })

    local expected = Experience.gainFor(data.pokemon[SPECIES], 50, false, 1, false)
    eq(right.exp - rightBefore, expected,
       "sheet mon=1 resolved through sheet[2].slot=2 and paid save.party[3]")
    eq(wrong.exp, wrongBefore,
       "...and save.party[2] -- the pre-fix victim -- was untouched")
  end

  -- (b) the discriminator is the row: a host-sim event carries no `med`
  -- flag, so it takes the seat-party path even with an unrelated, shifted
  -- `medMine` stashed on the screen.
  do
    local game = newGame()
    game.save.party = { expMon({ indescribable = true }), expMon(), expMon() }
    local host = wildScreen({ game = game, mode = "none" })
    local stash = Mediated.snapshotMons(game, game.save.party)
    host.medMine = stash
    eq(#stash, 2, "the stash really is shifted")

    local seatPaid = game.save.party[2]
    local before = seatPaid.exp
    host:playEvents({ { kind = "exp", slot = 1, mon = 1, species = SPECIES,
                        level = 50, winners = 1 } })
    eq(seatPaid.exp - before,
       Experience.gainFor(data.pokemon[SPECIES], 50, false, 1, false),
       "CoopSim's mon=1 still means the seat's second party member")
    eq(game.save.party[3].exp, 0, "...and not the sheet-translated third")
  end

  -- (c) an own-side faint does not re-arm the EXP.ALL credit -- only a foe
  -- knockout does, and the flag is set rather than accumulated, so an
  -- own-side faint between two foe knockouts costs nothing.
  do
    local game = newGame()
    game.save.party = { expMon(), expMon() }
    game.save.inventory.EXP_ALL = 1
    local host = wildScreen({ game = game, mode = "none" })
    local bystander = game.save.party[2]

    host:playEvents({ { kind = "faint", slot = 3 } })      -- the wild seat
    eq(host.expAllCredit, true, "a foe knockout arms the credit")
    host:playEvents({ { kind = "exp", slot = 1, mon = 0, species = SPECIES,
                        level = 50, winners = 1 } })
    eq(host.expAllCredit, false, "the first award spends it")
    local afterOne = bystander.exp
    check(afterOne > 0, "...and the half really was spread")

    host:playEvents({ { kind = "faint", slot = 1 } })      -- ann's own monster
    eq(host.expAllCredit, false, "our own knockout does not re-arm it")
    host:playEvents({ { kind = "exp", slot = 1, mon = 0, species = SPECIES,
                        level = 50, winners = 1 } })
    eq(bystander.exp, afterOne,
       "so a second award after an own-side faint spreads no second half")

    host:playEvents({ { kind = "faint", slot = 3 } })
    eq(host.expAllCredit, true, "the next foe knockout re-arms")
    host:playEvents({ { kind = "exp", slot = 1, mon = 0, species = SPECIES,
                        level = 50, winners = 1 } })
    check(bystander.exp > afterOne, "and that one does spread again")
  end

  -- (d) an unresolvable `mon` pays nobody and warns exactly once, on both
  -- the mediated path (`event.med`, "never uploaded") and the host-sim one
  -- ("does not hold") -- and a second miss in the same fight stays silent.
  do
    local game = newGame()
    game.save.party = { expMon(), expMon() }
    local host = wildScreen({ game = game })
    host:uploadMediated()
    host:onBattleReady({ battle = "cb-wild",
      sides = { a = { "ann", "bob" }, b = { "wild" } } })

    local before = #warns
    host:onBattleEvent({ battle = "cb-wild", seq = 1, t = "faint",
      slot = Config.COOP_SIDE, text = SPECIES_NAME })
    host:onBattleEvent({ battle = "cb-wild", seq = 2, t = "exp", slot = 0,
      species = SPECIES_NAME, level = 50, participants = 1, mon = 5 })
    host:onBattleEvent({ battle = "cb-wild", seq = 3, t = "turn" })
    eq(game.save.party[1].exp, 0, "a mon the upload has no sheet for pays nobody")
    eq(game.save.party[2].exp, 0, "...nobody at all")
    eq(#warns, before + 1, "and it is warned about exactly once")
    check(warns[#warns] ~= nil and warns[#warns]:find("never uploaded", 1, true) ~= nil,
          "naming the miss: " .. tostring(warns[#warns]))

    host:onBattleEvent({ battle = "cb-wild", seq = 4, t = "exp", slot = 0,
      species = SPECIES_NAME, level = 50, participants = 1, mon = 6 })
    host:onBattleEvent({ battle = "cb-wild", seq = 5, t = "turn" })
    eq(#warns, before + 1, "a second miss in the same fight is not said again")

    -- The host-sim spelling of the same miss, on a fresh screen.
    local game2 = newGame()
    game2.save.party = { expMon() }
    local sim2 = wildScreen({ game = game2, mode = "none" })
    local before2 = #warns
    sim2:playEvents({ { kind = "exp", slot = 1, mon = 4, species = SPECIES,
                        level = 50, winners = 1 } })
    eq(game2.save.party[1].exp, 0, "a seat index off the end pays nobody")
    eq(#warns, before2 + 1, "...and warns once")
    check(warns[#warns] ~= nil and warns[#warns]:find("does not hold", 1, true) ~= nil,
          "with the host-sim wording: " .. tostring(warns[#warns]))
  end
end

-- ------------------------------------------------------------------
-- 11. the replace phase: `turn` with a `slot` is a solicitation
-- ------------------------------------------------------------------
--
-- PROTOCOL: when a fighter faints with a living bench mon the referee stops
-- auto-advancing and emits `turn{amount, slot}` -- a solicitation naming
-- exactly which seat owes a send-out -- ahead of the ordinary slot-less `turn`
-- that opens the real choice window.  The screen owes three different answers
-- to that one event, and each is a different way to get it wrong:
--
--   * the named seat is ours -> the switch picker, and never the command grid
--     first, because a grid over a corpse is a turn nobody can take;
--   * the named seat is somebody else's -> no menu at all, a held
--     "X is choosing who to send out..." queued *behind* the faint's own sink
--     and sentence, so the hold does not overwrite the death it explains;
--   * no `slot` at all -> exactly what an older referee always got.
--
-- coop_npc is the fourth case and the one that reads as a bug on sight: the
-- NPC's replacement is resolved by the referee in-band with no solicitation,
-- so the batch is faint...switch...send...turn and the grid opens over a seat
-- that is already filled.
do
  local function noInput()
    return { wasPressed = function() return false end,
             isDown = function() return false end }
  end

  -- Run the message queue out, which is where the screen decides what to open:
  -- every assertion about a *menu* below has to be taken after this, because
  -- the whole point of the change is that the picker waits for the narration.
  local function drain(self, guard)
    self.game.input = noInput()
    local n = 0
    while (self.phase == "messages" or self.shown ~= nil or #self.messages > 0)
          and n < (guard or 400) do
      self:update(1 / 60)
      n = n + 1
    end
    return n
  end

  local READY = { battle = "cb1", mode = "coop_npc",
                  sides = { a = { "ann", "bob" }, b = { "ann" } } }

  -- (a) coop_npc: the referee answers the NPC's own knockout in-band, so
  -- nothing is solicited and the grid opens over a filled seat.
  do
    local slots = npcSlots()
    slots[3].party[2].species = "FIXMON_B"
    local other = Wire.name(data.pokemon.FIXMON_B.name)
    local s = screen({ slots = slots, mine = 1, host = true,
                       mode = "coop_npc", selfId = "ann" })
    s:uploadMediated()
    s:onBattleReady(READY)
    s.phase = "choose"
    s:onBattleEvent({ battle = "cb1", seq = 1, t = "faint", slot = 2,
                      text = SPECIES_NAME })
    s:onBattleEvent({ battle = "cb1", seq = 2, t = "switch", slot = 2,
                      text = other })
    s:onBattleEvent({ battle = "cb1", seq = 3, t = "send", slot = 2,
                      text = other, hp = 50 })
    s:onBattleEvent({ battle = "cb1", seq = 4, t = "turn", amount = 2 })
    eq(s.medReplaceWait, nil,
       "no solicitation is recorded for an in-band NPC replacement")
    drain(s)
    eq(s.phase, "choose", "the grid opens on the slot-less turn")
    local foe = s.sim:slot(3)
    eq(foe.active, 2, "and the foe seat has already been advanced")
    check(foe.battler ~= nil and (foe.battler.mon.hp or 0) > 0,
          "...to a living monster, so the grid is not over an empty seat")
    eq(s.sim:awaitingChoice(), nil, "nobody is left awaiting a send-out")
  end

  -- (b) coop_pvp: a PARTNER's knockout.  The hold, and no grid behind it.
  do
    local slots = pvpSlots()
    slots[2].party = { mon(60, 30), mon(60, 25) }
    local s = screen({ slots = slots, mine = 1, host = false,
                       mode = "coop_pvp", selfId = "ann" })
    s:uploadMediated()
    s:onBattleReady({ battle = "cb1", mode = "coop_pvp",
                      sides = { a = { "ann", "bob" }, b = { "cal", "dee" } } })
    s.phase = "choose"
    s:onBattleEvent({ battle = "cb1", seq = 1, t = "faint", slot = 1,
                      text = SPECIES_NAME, amount = 1 })
    s:onBattleEvent({ battle = "cb1", seq = 2, t = "turn", amount = 3, slot = 1 })
    eq(s.medReplaceWait, 2, "the solicitation names the partner's seat")
    check(not s.replacing, "our own picker is NOT armed by somebody else's KO")

    local iFaint, iSink, iHold
    for i, row in ipairs(s.messages) do
      local text = type(row) == "table" and row.text or row
      if type(text) == "string" and text:find("fainted", 1, true) then
        iFaint = iFaint or i
      end
      if type(row) == "table" and row.faintfx ~= nil then iSink = iSink or i end
      if type(text) == "string" and text:find("choosing", 1, true) then
        iHold = iHold or i
      end
    end
    check(iHold ~= nil, "'X is choosing who to send out...' is queued")
    check(iSink and iFaint and iHold and iSink < iFaint and iFaint < iHold,
          ("...behind the faint's sink and its sentence (sink=%s faint=%s "
           .. "hold=%s of %d)"):format(tostring(iSink), tostring(iFaint),
                                       tostring(iHold), #s.messages))

    drain(s)
    eq(s.phase, "wait", "the grid does NOT open behind the hold")
    local awaiting = s.sim:awaitingChoice()
    check(awaiting ~= nil and awaiting.index == 2,
          "and the seat is marked awaiting a send-out")
    local box = tostring(s:boxText())
    check(box:find("aiting", 1, true) ~= nil
          or box:find("choosing", 1, true) ~= nil,
          "the box waits rather than offering a turn: " .. box:gsub("\n", "|"))
    s.waitShown = 99
    check(tostring(s:boxText()):find("choosing", 1, true) ~= nil,
          "and once the hint is due the line names who is choosing: "
          .. tostring(s:boxText()):gsub("\n", "|"))

    s:onBattleEvent({ battle = "cb1", seq = 3, t = "switch", slot = 1,
                      text = SPECIES_NAME })
    s:onBattleEvent({ battle = "cb1", seq = 4, t = "send", slot = 1,
                      text = SPECIES_NAME, hp = 60, mon = 2 })
    s:onBattleEvent({ battle = "cb1", seq = 5, t = "turn", amount = 3 })
    eq(s.medReplaceWait, nil, "the slot-less turn clears the wait")
    eq(s.sim:awaitingChoice(), nil, "awaiting is cleared by the send")
    drain(s)
    eq(s.phase, "choose", "and only now does the grid open")
    eq(s.sim:slot(2).active, 2, "with the partner's seat filled")
  end

  -- (c) our OWN knockout: the picker before any grid, and armed exactly once.
  -- `faint amount=1` already arms medMustReplace; the solicitation arrives in
  -- the same batch, so a second arming here would reset switchIndex under a
  -- player who had already moved the cursor.
  do
    local slots = npcSlots()
    slots[1].party = { mon(60, 40), mon(60, 35) }
    local s = screen({ slots = slots, mine = 1, host = true,
                       mode = "coop_npc", selfId = "ann" })
    s:uploadMediated()
    s:onBattleReady(READY)
    s.phase = "choose"
    s:onBattleEvent({ battle = "cb1", seq = 1, t = "faint", slot = 0,
                      text = SPECIES_NAME, amount = 1 })
    eq(s.medMustReplace, true, "the faint arms medMustReplace")
    check(not s.replacing, "but the picker waits for the batch to close")
    s:onBattleEvent({ battle = "cb1", seq = 2, t = "turn", amount = 2, slot = 0 })
    eq(s.replacing, true, "the solicitation opens the picker")
    eq(s.medMustReplace, nil,
       "and retires medMustReplace so the later slot-less turn cannot re-arm it")
    eq(s.switchIndex, 1, "the cursor starts at the top")
    s.switchIndex = 2
    drain(s)
    check(s.phase ~= "choose" or s.replacing,
          "no command grid behind the picker (phase=" .. tostring(s.phase)
          .. " replacing=" .. tostring(s.replacing) .. ")")
    eq(s.switchIndex, 2, "and nothing re-armed the picker under the cursor")

    s:onBattleEvent({ battle = "cb1", seq = 3, t = "switch", slot = 0,
                      text = SPECIES_NAME })
    s:onBattleEvent({ battle = "cb1", seq = 4, t = "send", slot = 0,
                      text = SPECIES_NAME, hp = 60, mon = 2 })
    s:onBattleEvent({ battle = "cb1", seq = 5, t = "turn", amount = 2 })
    check(not s.replacing, "the send closes the picker")
    drain(s)
    eq(s.phase, "choose", "and the slot-less turn opens the grid")
    eq(s.sim:slot(1).active, 2, "with our own seat filled")
  end

  -- (d) an empty bench: a solicitation this screen cannot answer.
  do
    local s = screen({ slots = npcSlots(), mine = 1, host = true,
                       mode = "coop_npc", selfId = "ann" })
    s:uploadMediated()
    s:onBattleReady(READY)
    s.phase = "choose"
    s:onBattleEvent({ battle = "cb1", seq = 1, t = "faint", slot = 0,
                      text = SPECIES_NAME })
    s:onBattleEvent({ battle = "cb1", seq = 2, t = "turn", amount = 2, slot = 0 })
    check(not s.replacing, "no dead picker over an empty bench")
    eq(s.medReplaceWait, nil, "and no hold left standing")
  end

  -- (e) an older referee, which never puts a `slot` on a `turn`, behaves
  -- exactly as it did before any of this existed.
  do
    local slots = npcSlots()
    slots[1].party = { mon(60, 40), mon(60, 35) }
    local s = screen({ slots = slots, mine = 1, host = true,
                       mode = "coop_npc", selfId = "ann" })
    s:uploadMediated()
    s:onBattleReady(READY)
    s.phase = "choose"
    s:onBattleEvent({ battle = "cb1", seq = 1, t = "faint", slot = 0,
                      text = SPECIES_NAME, amount = 1 })
    s:onBattleEvent({ battle = "cb1", seq = 2, t = "turn" })
    eq(s.replacing, true,
       "an old stream still arms the picker on the slot-less turn")
    eq(s.medReplaceWait, nil, "and records no replace phase")

    local t = screen({ slots = pvpSlots(), mine = 1, host = false,
                       mode = "coop_pvp", selfId = "ann" })
    t:uploadMediated()
    t:onBattleReady({ battle = "cb1", mode = "coop_pvp",
                      sides = { a = { "ann", "bob" }, b = { "cal", "dee" } } })
    t.phase = "choose"
    t:onBattleEvent({ battle = "cb1", seq = 1, t = "damage", slot = 2, hp = 10 })
    t:onBattleEvent({ battle = "cb1", seq = 2, t = "turn" })
    drain(t)
    eq(t.phase, "choose", "and an ordinary slot-less turn still opens the grid")
  end

  -- (f) the joint run: a real coop_pvp refereed by src/BattleSim/Turn.lua,
  -- replayed into the real screen.  No hand-built events -- the referee emits,
  -- CoopBattle reads, and the invariant is checked on every frame the loop
  -- pumps rather than only where this suite thought to look.
  do
    local BattleSim = need("BattleSim/init")
    local RTurn = BattleSim.Turn

    local function rmove()
      return { id = "FIX_TACKLE", pp = 20, power = 200, accuracy = 255,
               type = 0, effect = 0, chance = 0 }
    end
    local function rmon(hp)
      return { species = SPECIES_NAME, level = 20, hp = hp, maxHp = 60,
               stats = { atk = 90, def = 5, spd = 40, spc = 40 },
               moves = { rmove() } }
    end

    local battle = assert(RTurn.create({
      id = "cb1", mode = "coop_pvp", seed = 99, choiceTimeout = 60,
      reconnectGrace = 60,
      sides = {
        a = { { playerId = "ann", name = "ANN", mons = { rmon(60), rmon(60) } },
              { playerId = "bob", name = "BOB", mons = { rmon(1), rmon(60) } } },
        b = { { playerId = "cal", name = "CAL", mons = { rmon(60), rmon(60) } },
              { playerId = "dee", name = "DEE", mons = { rmon(1), rmon(60) } } },
      },
    }))

    local slots = pvpSlots()
    for i = 1, 4 do slots[i].party = { mon(60, 40), mon(60, 40) } end
    slots[2].party[1].hp = 1
    slots[4].party[1].hp = 1
    local s = screen({ slots = slots, mine = 1, host = false,
                       mode = "coop_pvp", selfId = "ann" })
    s:uploadMediated()
    s:onBattleReady({ battle = "cb1", mode = "coop_pvp",
                      sides = { a = { "ann", "bob" }, b = { "cal", "dee" } } })
    s.game.input = noInput()

    local violations, solicits, plain = {}, 0, 0
    local function pump()
      for _, e in ipairs(battle:drainEvents()) do
        if e.t == "turn" then
          if e.slot ~= nil then solicits = solicits + 1 else plain = plain + 1 end
        end
        s:onBattleEvent(e)
      end
      for _ = 1, 300 do
        s:update(1 / 60)
        if s.replacing then break end
        if s.phase == "choose" then
          if s.sim:awaitingChoice() ~= nil then
            violations[#violations + 1] = "grid open while seat "
              .. tostring(s.sim:awaitingChoice().index) .. " still owes a send-out"
          end
          for i = 1, 4 do
            local seat = s.sim:slot(i)
            local live = seat and seat.battler and seat.battler.mon
            local hasReserve = false
            for _, m in ipairs((seat or {}).party or {}) do
              if (m.hp or 0) > 0 then hasReserve = true end
            end
            if hasReserve and (not live or (live.hp or 0) <= 0) then
              violations[#violations + 1] =
                "grid open over empty seat " .. tostring(i)
            end
          end
          break
        end
      end
    end

    pump()
    local guard = 0
    while not battle.finished and guard < 14 do
      guard = guard + 1
      local snap = battle:snapshot()
      if snap.phase == "choice" then
        for _, id in ipairs({ "ann", "bob", "cal", "dee" }) do
          battle:submitChoice(id, { action = "fight", move = 0 })
        end
      elseif snap.phase == "replace" then
        check(s.phase ~= "choose" or s.replacing ~= nil,
              ("no command grid during the referee's replace phase (round %d, "
               .. "phase=%s replacing=%s)"):format(guard, tostring(s.phase),
                                                   tostring(s.replacing)))
        -- Only the seats the referee is asking, each answered with its own
        -- first living reserve: a hardcoded party slot is a choice the referee
        -- is right to refuse.
        for _, entry in ipairs(snap.field) do
          if entry.mustReplace then
            for i, hp in ipairs(entry.party) do
              if (hp or 0) > 0 then
                battle:submitChoice(entry.playerId,
                  { action = "switch", slot = i - 1 })
                break
              end
            end
          end
        end
      else
        break
      end
      pump()
    end

    check(solicits >= 2,
          "the referee really did solicit replacements (" .. solicits .. ")")
    check(plain >= 2, "with ordinary turns behind them (" .. plain .. ")")
    check(#violations == 0, "the screen never opened a grid over an empty seat: "
          .. table.concat(violations, "; "))
    local ended = battle.finished and "finished" or battle:snapshot().phase
    check(ended == "over" or ended == "choice" or ended == "finished",
          "the fight ran to a conclusion rather than stalling in replace: "
          .. tostring(ended))
    local emptySeat
    for i = 1, 4 do
      local seat = s.sim:slot(i)
      local live = seat and seat.battler and seat.battler.mon
      local reserve = false
      for _, m in ipairs((seat or {}).party or {}) do
        if (m.hp or 0) > 0 then reserve = true end
      end
      if reserve and (not live or (live.hp or 0) <= 0) then emptySeat = i end
    end
    eq(emptySeat, nil,
       "every seat the screen holds with a reserve left has a live monster")
  end
end


-- ------------------------------------------------------------------
-- 12. one trainer callout per attack, counted every frame
-- ------------------------------------------------------------------
--
-- The path the bug was played on: coop_npc on the arena, refereed by the
-- intermediator, `onBattleEvent` -> `medRows` -> `playEvents`.
--
-- One attack arrives as two rows -- the referee emits `anim` and *then* says
-- "X used MOVE" (server/lib/battle/Turn.js) -- and the whole move animation
-- runs between them. Both rows used to raise the callout, and the anim row
-- raised it twice more (once on its first pass and once when the callout beat
-- handed the same row back), so the trainer shouted, fell silent while the
-- animation played, and shouted the same order again. `noteBattlefieldBubble`
-- owns the rule now: whichever row arrives first shouts and the other only
-- refreshes it.
--
-- Counted as *appearances* -- absent -> present transitions -- because that is
-- exactly the thing that was seen twice.

do
  local host = screen({ slots = npcSlots(), mine = 1, host = true,
                        mode = "coop_npc", selfId = "ann" })
  host:uploadMediated()
  host:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })
  host.game.input = { wasPressed = function() return false end }
  check(host:usesBattlefield(), "the arena is the stage under test")

  -- The engine's own subanimation player, which `CoopBattle.new` builds
  -- whenever the build has `battle_anims` -- so there is always one in play,
  -- and a Gen1 move animation outruns the bubble's 90-frame life. Its absence
  -- headless is what hid this: with no player the anim row retires on the frame
  -- it starts and every raise lands within a frame or two of the last.
  local animLeft = 0
  host.animPlayer = {
    start = function() animLeft = 120 end,
    update = function() animLeft = animLeft - 1 end,
    isDone = function() return animLeft <= 0 end,
    draw = function() end,
  }

  host.phase = "choose"
  host:onBattleEvent({ battle = "cb1", seq = 1, t = "anim", slot = 0,
                       side = "a", text = "FIX_TACKLE" })
  host:onBattleEvent({ battle = "cb1", seq = 2, t = "msg",
                       text = "FIXMON A used FIX_TACKLE" })
  host:onBattleEvent({ battle = "cb1", seq = 3, t = "damage", slot = 2, hp = 21 })
  host:onBattleEvent({ battle = "cb1", seq = 4, t = "turn" })

  local appearances, maxCount, wasUp = 0, 0, false
  local firstUp, lungeFrame, bubbleAtLunge = nil, nil, nil
  for i = 1, 400 do
    host:update(1 / 60)
    -- Read through the ctx the renderer reads, which is also what ages a
    -- bubble out: a count taken off the raw table would never expire one.
    local ctx = host:battlefieldBubbleCtx()
    local n = (type(ctx) == "table") and #ctx or 0
    if n > maxCount then maxCount = n end
    local up = n > 0
    if up and not wasUp then appearances = appearances + 1 end
    if up and firstUp == nil then firstUp = i end
    wasUp = up
    if lungeFrame == nil then
      for _, fx in ipairs(host.fx or {}) do
        if fx.kind == "lunge" then lungeFrame, bubbleAtLunge = i, up end
      end
    end
  end

  eq(appearances, 1,
     "the refereed attack raises the trainer's callout exactly once -- the "
     .. "anim row, the beat behind it and the referee's 'used X' line are one "
     .. "announcement")
  eq(maxCount, 1, "...and one bubble is the most that is ever up")
  check(lungeFrame ~= nil, "the lunge did play")
  check(firstUp ~= nil and lungeFrame ~= nil and firstUp < lungeFrame,
        "the callout is up before the lunge -- the beat is still a beat")
  check(bubbleAtLunge == true,
        "...and still lit when the monster leans in")
end

T.finish("coop_mediated")
