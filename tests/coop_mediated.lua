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
--   * and that Config.MEDIATED_COOP is not a runtime off-switch;
--   * and (section 14) that a player's badges ride a co-op upload only against
--     the computer -- a coop_npc upload carries them, a coop_pvp one never does
--     -- and that the referee drops badges forged onto a coop_pvp or the
--     trainer's team.
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
-- Only needed from section 13 on (TT4's regression guard on I3's extraction),
-- but resolved here beside its siblings rather than lazily -- Coop itself
-- need()s CoopBattle and Mediated, both already cached above, so this adds no
-- new module to the graph, just a name for what was already loaded.
local Coop = need("Coop")

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
  eq(hostScreen.medSlots[3], 3,
     "and field slot 3 is the trainer's first, not the host's -- the advertised id "
     .. "is where a choice for it arrives from, not who stands in it")
  eq(hostScreen.medSlots[4], 4, "field slot 4 is the trainer's second")
  eq(hostScreen.medFields[3], 3, "and back the other way")
  eq(hostScreen.medFields[4], 4,
     "with the fourth box on a field slot of its own now: the intermediator "
     .. "seats two npcs at field slots 3 and 4 where this screen draws two")

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
  eq(fight.target, 3,
     "and the target as a *field* slot -- box 3 on this screen is field slot 3")
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

  -- Against a trainer there was never a partner to ask. Honest menus refuse
  -- locally and never file `run` -- forwarding it used to forfeit the gym.
  -- The referee still no-ops a filed run (modified-client proof).
  local fleeing = screen({ slots = npcSlots(), mine = 1, host = true,
                           mode = "coop_npc", selfId = "ann" })
  fleeing:uploadMediated()
  fleeing:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })
  eq(fleeing:askToRun(), false, "an NPC battle asks nobody")
  fleeing.phase = "choose"
  fleeing.commandIndex = 4
  eq(CoopBattle.COMMANDS[4], "RUN", "the fourth command is RUN")
  fleeing:updateCommand({ wasPressed = function(_, key) return key == "a" end })
  eq(fleeing.countSent(Wire.BATTLE_CHOICE), 0,
     "and its RUN is not filed with the intermediator")
  local refused = false
  for _, row in ipairs(fleeing.messages) do
    local text = type(row) == "table" and row.text or row
    if type(text) == "string" and text:lower():find("running", 1, true) then
      refused = true
    end
  end
  check(refused, "the screen says there is no running from a trainer battle")
  eq(fleeing.phase, "messages", "the line plays")
  eq(fleeing.after, "choose", "and the menu comes back without spending the turn")
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

  -- Field slot 3 is the trainer's first box, which on this screen is box 3. Getting
  -- that translation backwards would put every one of the referee's numbers on
  -- the wrong monster, and it is the one mistake the screen could not survive.
  host:onBattleEvent({ battle = "cb1", seq = 2, t = "damage", slot = 3, hp = 21 })
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
  host:onBattleEvent({ battle = "cb1", seq = 4, t = "faint", slot = 3,
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
  sendScreen:onBattleEvent({ battle = "cb1", seq = 1, t = "send", slot = 3,
                             text = otherName, hp = 50 })
  sendScreen:onBattleEvent({ battle = "cb1", seq = 2, t = "turn" })
  -- A Red trainer's send-out is the cart's own line (pokered
  -- _TrainerSentOutText "<TRAINER> sent\nout <MON>!", Mediated.sentOutPages).
  check(said(sendScreen, "sent\nout " .. otherName .. "!"), "a send-out is narrated (Red: \"X sent\\nout Y!\")")
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
  unknown:onBattleEvent({ battle = "cb1", seq = 1, t = "send", slot = 3,
                          text = "NOBODY", hp = 50 })
  unknown:onBattleEvent({ battle = "cb1", seq = 2, t = "turn" })
  check(said(unknown, "sent\nout NOBODY!"), "an unmatched send-out is still narrated")
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
-- 5c. particle rows (src/Vfx.lua) -- items, conditions, stat stages
-- ------------------------------------------------------------------
--
-- A move's particles ride the lunge beat inside `startAnim` and are covered by
-- the battlefield driver; what is pinned here is the other three, which reach
-- the arena as *queued rows* so they keep their place in the referee's order.
-- The two that must file nothing are as load-bearing as the ones that do: a
-- thrown ball already has a whole flow of its own, and a condition clearing is
-- a sentence rather than a sight.

do
  local fxScreen = screen({ slots = npcSlots(), mine = 1, host = true,
                            mode = "coop_npc", selfId = "ann" })
  fxScreen:uploadMediated()
  -- The id the upload minted, not one invented here: `onBattleReady` refuses a
  -- battle that is not the one this screen uploaded for, and a refused ready
  -- leaves `medSlots` empty -- which reads downstream as "every event names a
  -- seat this client does not have" rather than as a setup mistake.
  fxScreen:onBattleReady({ battle = fxScreen.battleId, mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })
  check(fxScreen.mediated == true, "the vfx screen is on the mediated path")

  local function vfxRows(msg)
    local out = {}
    for _, row in ipairs(fxScreen:medRows(msg)) do
      if row.kind == "vfx" then out[#out + 1] = row end
    end
    return out
  end

  local item = vfxRows({ t = "item", slot = 0, text = "POTION" })
  eq(#item, 1, "an item files one particle row")
  local itemSaid = 0
  for _, row in ipairs(fxScreen:medRows({ t = "item", slot = 0, text = "POTION" })) do
    if row.kind == "msg" then itemSaid = itemSaid + 1 end
  end
  eq(itemSaid, 0, "an item's id is never a battle line -- the referee's own sentence is (wave 6)")
  eq(item[1].spec.style, "heal", "...with the look the catalogue gave it")
  eq(item[1].slot, 1, "...on the seat that opened the bag, mapped through medSlots")

  eq(#vfxRows({ t = "item", slot = 0, text = "POKE_BALL" }), 0,
     "a thrown ball files none: the throw chain already draws the arc, the "
     .. "rocking and the burst")

  local burn = vfxRows({ t = "status", slot = 0, status = "BRN",
                         text = "was burned!" })
  eq(#burn, 1, "a condition landing files one")
  eq(burn[1].spec.style, "ember", "...in that condition's own look")

  eq(#vfxRows({ t = "status", slot = 0, text = "is cured!" }), 0,
     "a condition lifting files none -- a sentence rather than a sight")

  -- The plate reads `mon.status`. A `status` event used to file VFX only, so a
  -- wake or an Awakening left the SLEEP chip on the card. Truth is a row now.
  local statusRows = fxScreen:medRows({ t = "status", slot = 0, text = "woke up" })
  eq(#statusRows, 1, "a lift still yields a row -- the truth, not a sight")
  eq(statusRows[1].kind, "status", "...that playEvents applies to the battler")
  eq(statusRows[1].status, nil, "...with no token, which is the clear")

  local sleeper = fxScreen.sim:slot(1).battler.mon
  sleeper.status = "SLP"
  fxScreen:playEvents({ { kind = "status", slot = 1 } })
  eq(sleeper.status, nil, "a wake (or an item cure) takes the chip off")
  for _, token in ipairs({ "PSN", "BRN", "FRZ", "PAR", "TOX" }) do
    sleeper.status = token
    fxScreen:playEvents({ { kind = "status", slot = 1 } })
    eq(sleeper.status, nil, token .. " lifts the same way")
  end
  fxScreen:playEvents({ { kind = "status", slot = 1, status = "BRN" } })
  eq(sleeper.status, "BRN", "an inflict still writes the token")

  local rose = vfxRows({ t = "stat", slot = 0, amount = 2,
                         text = "PIKACHU's ATTACK rose" })
  eq(#rose, 1, "a stat stage files one")
  eq(rose[1].spec.style, "buff", "...arrows up, read off the sentence")
  local fell = vfxRows({ t = "stat", slot = 0, amount = 2,
                         text = "PIKACHU's DEFENSE fell" })
  eq(fell[1] and fell[1].spec.style, "debuff", "...and arrows down for a drop")

  -- The rows reach the queue as effects `update` will play, not as text.
  fxScreen:playEvents({ { kind = "vfx", spec = { style = "heal",
    palette = "HEAL", delivery = "self" }, slot = 1, from = 1 } })
  local queued = nil
  for _, row in ipairs(fxScreen.messages) do
    if type(row) == "table" and row.vfxrow then queued = row end
  end
  check(queued ~= nil, "playEvents queues the effect rather than emitting it")
  eq(queued and queued.vfxrow.style, "heal", "...carrying the look intact")

  -- ...and off the arena nothing is emitted at all: the classic 160x144 path
  -- has no renderer for a particle, so an emission there would cost a record
  -- to draw nothing.
  local classic = screen({ slots = npcSlots(), mine = 1, host = true,
                           mode = "coop_npc", selfId = "ann" })
  classic.usesBattlefield = function() return false end
  eq(classic:emitVfx({ style = "heal", palette = "HEAL", delivery = "self" }, 1),
     nil, "the classic path emits no particle effect")
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

    local function partyMon(opts)
      opts = opts or {}
      if opts.nearLevel then
        return { species = SPECIES, level = 5, hp = 20, exp = 179,
          stats = { hp = 20, attack = 30, defense = 30, special = 30, speed = 40 },
          dvs = { hp = 8, attack = 8, defense = 8, speed = 8, special = 8 },
          statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 },
          moves = { { id = "FIX_TACKLE", pp = 20 } },
        }
      end
      return { species = SPECIES, level = 10, hp = 20, exp = 0,
        stats = { hp = 20, attack = 30, defense = 30, special = 30, speed = 40 },
        dvs = { hp = 8, attack = 8, defense = 8, speed = 8, special = 8 },
        statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 },
        moves = { { id = "FIX_TACKLE", pp = 20 } },
      }
    end
    local function benchGame(n, opts)
      local g = newGame()
      g.save.party = {}
      for i = 1, (n or 3) do g.save.party[i] = partyMon(opts) end
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
      local game = benchGame(3, { nearLevel = true })
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
      local game = benchGame(3, { nearLevel = true })
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
    s:onBattleEvent({ battle = "cb1", seq = 1, t = "faint", slot = 3,
                      text = SPECIES_NAME })
    s:onBattleEvent({ battle = "cb1", seq = 2, t = "switch", slot = 3,
                      text = other })
    s:onBattleEvent({ battle = "cb1", seq = 3, t = "send", slot = 3,
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
    t:onBattleEvent({ battle = "cb1", seq = 1, t = "damage", slot = 3, hp = 10 })
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
  host:onBattleEvent({ battle = "cb1", seq = 3, t = "damage", slot = 3, hp = 21 })
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

-- H1b: a multi-hit move is one strike a hit.  pokered replays the move's
-- animation before every hit after the first (`jp nz,
-- GetPlayerAnimationType`) and the Red referee sends each one: every strike
-- leans in and lands its own hit beat, and the attack is still one shout
-- (`calloutSpent`).  The plate shake and the field shake have their motion.
do
  local host = screen({ slots = npcSlots(), mine = 1, host = true,
                        mode = "coop_npc", selfId = "ann" })
  host:uploadMediated()
  host:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })
  host.game.input = { wasPressed = function() return false end }
  local animLeft = 0
  host.animPlayer = {
    start = function() animLeft = 30 end,
    update = function() animLeft = animLeft - 1 end,
    isDone = function() return animLeft <= 0 end,
    draw = function() end,
  }
  host.phase = "choose"
  local seq = 0
  local function send(e)
    seq = seq + 1
    e.battle, e.seq = "cb1", seq
    host:onBattleEvent(e)
  end
  send({ t = "anim", slot = 0, side = "a", text = "FIX_TACKLE" })
  send({ t = "msg", text = "^aFIXMON A\nused FIX_TACKLE!" })
  send({ t = "damage", slot = 3, side = "b", amount = 3, hp = 27 })
  send({ t = "anim", slot = 0, side = "a", text = "FIX_TACKLE" })
  send({ t = "damage", slot = 3, side = "b", amount = 3, hp = 24 })
  send({ t = "anim", slot = 0, side = "a", text = "FIX_TACKLE" })
  send({ t = "damage", slot = 3, side = "b", amount = 3, hp = 21 })
  send({ t = "msg", text = "Hit the enemy\n3 times!" })
  send({ t = "turn" })
  local appearances, wasUp, lunges, seen = 0, false, 0, {}
  for _ = 1, 900 do
    host:update(1 / 60)
    local ctx = host:battlefieldBubbleCtx()
    local up = (type(ctx) == "table") and #ctx > 0
    if up and not wasUp then appearances = appearances + 1 end
    wasUp = up
    for _, fx in ipairs(host.fx or {}) do
      if fx.kind == "lunge" and not seen[fx] then seen[fx] = true; lunges = lunges + 1 end
    end
  end
  eq(appearances, 1, "H1b (co-op): a three-hit attack shouts once")
  eq(lunges, 3, "H1b (co-op): ...and leans in for every hit")

  -- ENEMY_HUD_SHAKE_ANIM moves one plate; SHAKE_SCREEN_ANIM the field.
  host.fx = nil
  pcall(host.startAnim, host, { kind = "anim", anim = "ENEMY_HUD_SHAKE_ANIM", from = 3 })
  local hud
  for _, fx in ipairs(host.fx or {}) do if fx.kind == "hudshake" then hud = fx end end
  eq(hud and hud.slot, 3, "H1b (co-op): ENEMY_HUD_SHAKE_ANIM shakes the plate of the seat it names")
  host.fx = nil
  pcall(host.startAnim, host, { kind = "anim", anim = "SHAKE_SCREEN_ANIM", from = 1 })
  local jolt
  for _, fx in ipairs(host.fx or {}) do if fx.kind == "shake" then jolt = fx end end
  check(jolt ~= nil, "H1b (co-op): SHAKE_SCREEN_ANIM jolts the field")
end

-- H1b: THRASH's first turn as the Red referee sends it -- the used line,
-- ThrashPetalDanceEffect's SHRINKING_SQUARE_ANIM, then the move's animation
-- (pret runs SpecialEffectsCont before MoveHitTest and the move's own
-- animation).  The sentence shouts first (`noteBattlefieldBubble`'s
-- sentence-first order), the square plays, then the strike leans in: one
-- shout, one lunge, the square ahead of it.
do
  local host = screen({ slots = npcSlots(), mine = 1, host = true,
                        mode = "coop_npc", selfId = "ann" })
  host:uploadMediated()
  host:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })
  host.game.input = { wasPressed = function() return false end }
  local animLeft = 0
  host.animPlayer = {
    start = function() animLeft = 30 end,
    update = function() animLeft = animLeft - 1 end,
    isDone = function() return animLeft <= 0 end,
    draw = function() end,
  }
  host.phase = "choose"
  local seq = 0
  local function send(e)
    seq = seq + 1
    e.battle, e.seq = "cb1", seq
    host:onBattleEvent(e)
  end
  send({ t = "msg", text = "^aFIXMON A\nused FIX_TACKLE!" })
  send({ t = "anim", slot = 0, side = "a", text = "SHRINKING_SQUARE_ANIM" })
  send({ t = "anim", slot = 0, side = "a", text = "FIX_TACKLE" })
  send({ t = "damage", slot = 3, side = "b", amount = 3, hp = 27 })
  send({ t = "turn" })
  local appearances, wasUp, lunges, seen = 0, false, 0, {}
  local squareAt, lungeAt
  for frame = 1, 900 do
    host:update(1 / 60)
    local ctx = host:battlefieldBubbleCtx()
    local up = (type(ctx) == "table") and #ctx > 0
    if up and not wasUp then appearances = appearances + 1 end
    wasUp = up
    for _, fx in ipairs(host.fx or {}) do
      if not seen[fx] then
        seen[fx] = true
        if fx.kind == "lunge" then lunges = lunges + 1; lungeAt = lungeAt or frame end
        if fx.kind == "vfx" then squareAt = squareAt or frame end
      end
    end
  end
  eq(appearances .. "/" .. lunges, "1/1", "H1b (co-op): THRASH's first turn shouts once and leans in once")
  check(squareAt ~= nil and lungeAt ~= nil and squareAt < lungeAt,
        "H1b (co-op): the square plays before the strike (" .. tostring(squareAt) .. " < " .. tostring(lungeAt) .. ")")
end

-- A disobedient monster's own pick is said the cart's way -- "<MON> used
-- instead, <MOVE>" (both Gen 1 / Gen 2 referees, pokered _UsedInsteadText /
-- pokecrystal UsedInsteadText) -- and "instead," is the sentence, not the
-- move: the shout reads the move, and keys the same as the anim row, so the
-- attack is still one announcement.
do
  local parse = CoopBattle.moveNameFromBattleText
  eq(parse("FIXMON A used FIX_TACKLE"), "FIX_TACKLE", "used-line: the plain line names its move")
  eq(parse("FIXMON A used\nKARATE CHOP!"), "KARATE CHOP", "used-line: ...across the page break")
  eq(parse("FIXMON A used instead, KARATE CHOP"), "KARATE CHOP",
     "used-line: a disobedient pick names the move, not 'instead, ...'")
  eq(parse("FIXMON A used instead,\nKARATE CHOP"), "KARATE CHOP",
     "used-line: ...wherever the page broke the line")
  eq(parse("FIXMON A used\ninstead, KARATE CHOP"), "KARATE CHOP", "used-line: ...on either side of it")
  eq(parse("FIXMON A used instead,"), nil, "used-line: no move after it is no move")

  local host = screen({ slots = npcSlots(), mine = 1, host = true,
                        mode = "coop_npc", selfId = "ann" })
  host:uploadMediated()
  host:onBattleReady({ battle = "cb1", mode = "coop_npc",
    sides = { a = { "ann", "bob" }, b = { "ann" } } })
  host.game.input = { wasPressed = function() return false end }
  local animLeft = 0
  host.animPlayer = {
    start = function() animLeft = 120 end,
    update = function() animLeft = animLeft - 1 end,
    isDone = function() return animLeft <= 0 end,
    draw = function() end,
  }
  host.phase = "choose"
  -- The Node half's order: the anim row, then the referee's sentence.
  host:onBattleEvent({ battle = "cb1", seq = 1, t = "anim", slot = 0,
                       side = "a", text = "FIX_TACKLE" })
  host:onBattleEvent({ battle = "cb1", seq = 2, t = "msg",
                       text = "FIXMON A used instead, FIX_TACKLE" })
  host:onBattleEvent({ battle = "cb1", seq = 3, t = "damage", slot = 3, hp = 21 })
  host:onBattleEvent({ battle = "cb1", seq = 4, t = "turn" })
  local appearances, wasUp, said = 0, false, {}
  for _ = 1, 400 do
    host:update(1 / 60)
    local ctx = host:battlefieldBubbleCtx()
    local up = type(ctx) == "table" and #ctx > 0
    if up and not wasUp then appearances = appearances + 1 end
    if up then said[tostring(ctx[1].moveName)] = true end
    wasUp = up
  end
  eq(appearances, 1, "used-line: the disobedient attack is still one shout")
  local names = {}
  for name in pairs(said) do names[#names + 1] = name end
  table.sort(names)
  eq(table.concat(names, "|"), "FIX TACKLE",
     "used-line: ...and every bubble it put up names the move, never 'INSTEAD'")
end

-- ------------------------------------------------------------------
-- 13. the post-battle ritual, extracted (TT4 — regression guard on I3)
-- ------------------------------------------------------------------
--
-- src/Coop.lua's prize/blackout/onFinish/unwind sequence was lifted out of
-- M:consume into reusable statics (M.payTrainerPrize, M.finishBuriedBattle,
-- M.unwindStackTo / M.stackHolds, plus M:blackout / M:pumpBlackout made
-- holder-agnostic) so src/SoloBattle.lua could call the same ritual with no
-- co-op encounter around it. The extraction was meant to change nothing about
-- what co-op itself does -- this section is the executable half of that
-- promise, so a later edit to this file that reorders or narrows the ritual
-- fails a test instead of shipping.
--
-- A `Coop` instance is built by hand throughout, the same way section 1 below
-- builds a `CoopBattle` screen without its constructor: nothing here needs a
-- transport, a ui or a real overworld, only the fields the function under
-- test actually reads off `self`.

-- A minimal StateStack double, shaped like the one src/Coop.lua and
-- tests/rby_mmo_test.lua both drive `unwindTo`/`onStack` against: `states` is
-- the array, `top`/`pop` are the two methods the ritual calls.
local function bareStack(states)
  return {
    states = states,
    top = function(self) return self.states[#self.states] end,
    pop = function(self) return table.remove(self.states) end,
  }
end

-- 13.1 -- prize before blackout: the ordering is load-bearing, both ways.
--
-- Run through M:onBattleOver itself, not a hand-rolled re-ordering of its two
-- calls -- so a future edit that swaps the order in the source, not just in a
-- test's idea of the order, is what this catches.
do
  -- A win whose winner still has a party standing: the ordinary case, no
  -- ritual needed, the engine's own prize is the only money that moves.
  local finishArg
  local engine = {
    trainer = { baseMoney = 10 },
    enemyParty = { { level = 20 } },
    onFinish = function(o) finishArg = o end,
  }
  local game = { save = { money = 100, party = { mon(30, 10) } },
                 data = { constants = {} } }
  local coop = setmetatable({ engineBattle = engine, party = { count = function() return 2 end } }, { __index = Coop })
  coop:onBattleOver("win", game, nil, nil)
  eq(finishArg, "win", "a plain win hands the engine a plain win")
  eq(game.save.money, 300,
     "prize alone: 100 + (baseMoney 10 * best enemy level 20)")

  -- A win whose winner's own team is wiped: M.blacksOut says true even on a
  -- win (the safety net co-op re-hangs because BattleState:finish never ran),
  -- so the ritual's own blackout runs -- but only *after* the prize the same
  -- call already paid. Halving before paying would leave 200; halving after
  -- paying leaves 150. Only one of those is the vanilla order.
  local finishArg2
  local engine2 = {
    trainer = { baseMoney = 10 },
    enemyParty = { { level = 20 } },
    onFinish = function(o) finishArg2 = o end,
  }
  local game2 = { save = { money = 100, party = { mon(0, 10) } },
                  data = { constants = {} } }
  local coop2 = setmetatable({ engineBattle = engine2, party = { count = function() return 2 end } }, { __index = Coop })
  coop2:onBattleOver("win", game2, nil, nil)
  eq(finishArg2, "win",
     "a win stays a win for the engine even when the winner blacks out -- "
     .. "see M:consume: the defeat flag is owed to the world, the ritual to "
     .. "the player")
  eq(game2.save.money, 150,
     "prize paid first (100 -> 300), THEN halved by the safety-net blackout "
     .. "(300 -> 150) -- a reordering would leave 200, not 150")

  -- A loss: no prize (the payTrainerPrize gate is `result == "win"`), and the
  -- outcome is aliased to the engine's own "lose" spelling with engineRitual
  -- handed back true -- which is what stops onBattleOver from ALSO halving
  -- the money itself and taxing the player twice for one defeat.
  local finishArg3
  local engine3 = {
    trainer = { baseMoney = 10 },
    enemyParty = { { level = 20 } },
    onFinish = function(o) finishArg3 = o end,
  }
  local game3 = { save = { money = 100, party = { mon(0, 10) } },
                  data = { constants = {} } }
  local coop3 = setmetatable({ engineBattle = engine3, party = { count = function() return 2 end } }, { __index = Coop })
  coop3:onBattleOver("loss", game3, nil, nil)
  eq(finishArg3, "lose",
     "a co-op 'loss' is spelled 'lose' for the engine's own afterBattle, "
     .. "which is the string that actually triggers its blackout")
  eq(game3.save.money, 100,
     "no prize on a loss, and the caller's own blackout does not also fire "
     .. "-- the engine's ritual (engineRitual=true) already owns it")
end

-- 13.2 -- M.finishBuriedBattle: onFinish/onDone aliasing and the early-out.
do
  -- Gen 1 shape: onFinish present.
  local seenFinish
  local engine1 = {
    trainer = { baseMoney = 5 }, enemyParty = { { level = 10 } },
    onFinish = function(o) seenFinish = o end,
  }
  local game1 = { save = { money = 0 } }
  local handled1, ritual1 = Coop.finishBuriedBattle(engine1, game1, "win", false)
  eq(handled1, true, "an onFinish engine is handled")
  eq(ritual1, false, "...and a win never claims the engine ritual")
  eq(seenFinish, "win", "...onFinish gets the result")
  eq(game1.save.money, 50, "...and the prize (5 * 10) is paid")

  -- Gen 2 shape: only onDone, no onFinish at all (the raw shape before
  -- Client.lua's alias runs, or a fixture that never stamped one).
  local seenDone
  local engine2 = {
    trainer = { baseMoney = 5 }, enemyParty = { { level = 10 } },
    onDone = function(o) seenDone = o end,
  }
  local game2 = { save = { money = 0 } }
  local handled2 = Coop.finishBuriedBattle(engine2, game2, "win", false)
  eq(handled2, true, "an onDone-only engine (Gen 2 shape) is handled too")
  eq(seenDone, "win", "...through onDone, since there is no onFinish to prefer")
  eq(game2.save.money, 50, "...and pays the same prize either alias")

  -- Both present: onFinish is preferred (the shape Client.lua actually stamps
  -- on Gold once it aliases onFinish from onDone -- both fields end up set,
  -- and only one should be called or a double-pop is exactly what happens).
  local seenFinish3, seenDone3
  local engine3 = {
    onFinish = function(o) seenFinish3 = o end,
    onDone = function(o) seenDone3 = o end,
  }
  Coop.finishBuriedBattle(engine3, { save = {} }, "draw", false)
  eq(seenFinish3, "draw", "onFinish is called when both are present")
  eq(seenDone3, nil, "...and onDone is not also called")

  -- Neither present at all: early-out before any money moves.
  local engine4 = { trainer = { baseMoney = 5 }, enemyParty = { { level = 10 } } }
  local game4 = { save = { money = 0 } }
  local handled4, ritual4 = Coop.finishBuriedBattle(engine4, game4, "win", false)
  eq(handled4, false, "no onFinish and no onDone: nothing to finish")
  eq(ritual4, nil, "...and no ritual verdict is offered")
  eq(game4.save.money, 0, "...the early-out is before the prize, not after")
end

-- 13.3 -- Coop.blacksOut: the loss rule, the safety-net rule, and the
-- deliberate false for a headless/empty party.
do
  check(Coop.blacksOut("loss", { save = { party = { mon(80, 10) } } }),
        "a lost battle blacks out even with a healthy-looking party record")
  check(Coop.blacksOut("win", { save = { party = { mon(0, 10), mon(0, 10) } } }),
        "a WON battle still blacks out when the winner's own party is wiped "
        .. "-- the safety net BattleState:finish would have run")
  check(not Coop.blacksOut("win", { save = { party = { mon(1, 10) } } }),
        "a win with anything standing does not black out")
  check(not Coop.blacksOut("win", { save = { party = {} } }),
        "an empty party is not a wipe -- a headless load is not a defeat")
  check(not Coop.blacksOut("win", { save = {} }),
        "no party field at all reads the same as an empty one")
  check(not Coop.blacksOut("win", nil),
        "no game/save at all: still not a blackout, never an error")
end

-- 13.4 -- M.unwindStackTo: identity, not count, and an honest guard.
do
  -- Pops by identity with unrelated states sitting between the target and the
  -- top -- a fixed pop-count would either stop short or eat the target.
  local below, target, mid1, mid2, mid3 = {}, {}, {}, {}, {}
  local stack = bareStack({ below, target, mid1, mid2, mid3 })
  local game = { stack = stack }
  local ok = Coop.unwindStackTo(game, target, false)
  check(ok, "the target is reached through the states stacked above it")
  eq(#stack.states, 2, "only what was above the target came off")
  check(stack.states[2] == target, "...leaving the target itself on top")
  check(stack.states[1] == below, "...and what was under it untouched")

  -- alsoPop additionally takes the target itself, by the same identity check.
  local below2, target2, mid = {}, {}, {}
  local stack2 = bareStack({ below2, target2, mid })
  check(Coop.unwindStackTo({ stack = stack2 }, target2, true),
        "alsoPop still reports success when it reaches the target")
  eq(#stack2.states, 1, "...and the target itself is popped too")
  check(stack2.states[1] == below2, "...leaving only what was under it")

  -- The guard: more than sixteen states between the top and the target means
  -- the loop gives up before arriving, and the fixed review finding is that
  -- this must say so rather than claim the clean-unwind `true`.
  local target3 = {}
  local states3 = { target3 }
  for i = 1, 20 do states3[#states3 + 1] = {} end
  local stack3 = bareStack(states3)
  local before = #stack3.states
  local reached = Coop.unwindStackTo({ stack = stack3 }, target3, true)
  eq(reached, false,
     "a target still buried after sixteen pops is reported as NOT reached")
  eq(#stack3.states, before - 16,
     "...exactly the guard's sixteen pops happened, no more")
  check(stack3.states[#stack3.states] ~= target3,
        "...the target is still buried, not falsely popped by alsoPop")

  -- A target no longer on the stack at all answers false immediately, with
  -- nothing popped -- the case M.stackHolds itself has always covered.
  local stale = {}
  local stack4 = bareStack({ {}, {} })
  local lenBefore = #stack4.states
  eq(Coop.unwindStackTo({ stack = stack4 }, stale, true), false,
     "a stale target (already off the stack) is declined, not hunted for")
  eq(#stack4.states, lenBefore, "...and nothing was popped looking for it")
end

-- 13.5 -- the blackout warning wording: unchanged when `context` is absent.
--
-- The four lines below are quoted exactly as src/Coop.lua's git history has
-- always printed them; the only thing under test is that omitting the new
-- `context` argument still reaches all four, byte for byte.
do
  local function lastWarn()
    return warns[#warns]
  end

  -- 1. No save at all.
  local before1 = #warns
  local coop1 = setmetatable({}, { __index = Coop })
  eq(coop1:blackout({}), false, "no save: the ritual declines")
  check(#warns > before1, "...and says so")
  eq(lastWarn(),
     "a lost 2-on-2 could not black you out (no save); walk to a "
     .. "POKéMON CENTER to heal",
     "co-op's default noun is still \"2-on-2\" when context is omitted")

  -- 2. Healed and taxed, but no heal point / no world API to warp through.
  local before2 = #warns
  local coop2 = setmetatable({}, { __index = Coop })
  local game2 = { save = { money = 100 }, data = { constants = {} } }
  eq(coop2:blackout(game2), false, "no warp target: the ritual half-completes")
  check(#warns > before2, "...and says so")
  eq(lastWarn(),
     "a lost 2-on-2 healed your party but could not send you to a "
     .. "POKéMON CENTER; walk out and back in, or reload your last save",
     "still the unmodified co-op wording")
  eq(game2.save.money, 50, "...but the halving itself still ran (100 -> 50)")

  -- 3. Warp armed, but the overworld never comes back on top before the wait
  -- runs out -- pumpBlackout's own warning, reached by jumping its clock past
  -- BLACKOUT_WARP_WAIT in one call rather than iterating real frames.
  stubMod.world = { warpTo = function() return true end }
  local before3 = #warns
  local coop3 = setmetatable({}, { __index = Coop })
  local game3 = { save = { money = 100, lastHeal = { map = "FIX_TOWN" } },
                  stack = bareStack({ { isOverworld = false } }) }
  eq(coop3:blackout(game3), false,
     "armed but not yet resolved: the first attempt (dt=0) declines")
  check(coop3.pendingWarp ~= nil, "...and the warp is left pending")
  coop3:pumpBlackout(61)
  check(#warns > before3, "the wait-timeout warning fires once the clock runs out")
  eq(lastWarn(),
     "your party was healed after the 2-on-2 but the trip to a POKéMON "
     .. "CENTER never got a chance to start; walk there, or reload from "
     .. "your last save",
     "still the unmodified co-op wording")
  eq(coop3.pendingWarp, nil, "...and the pending warp is given up on")

  -- 4. Warp armed, overworld is on top, but the warp itself fails.
  stubMod.world = { warpTo = function() return nil, "boom" end }
  local before4 = #warns
  local coop4 = setmetatable({}, { __index = Coop })
  local game4 = { save = { money = 100, lastHeal = { map = "FIX_TOWN" } },
                  stack = bareStack({ { isOverworld = true } }) }
  eq(coop4:blackout(game4), false, "the warp itself fails")
  check(#warns > before4, "...and says so")
  eq(lastWarn(),
     "a lost 2-on-2 healed your party but the warp to a POKéMON CENTER "
     .. "failed (boom); reload from your last save if you are stuck",
     "still the unmodified co-op wording, including the failure reason")

  -- Restored: nothing else in this file, and no earlier section, drives
  -- mod.world -- left set, a later suite loading this file's stubMod would
  -- inherit a warpTo that always fails.
  stubMod.world = nil
end

-- 13.6 -- the method wrappers agree with the statics they forward to.
do
  local target, mid = {}, {}
  local coop = setmetatable({}, { __index = Coop })

  -- onStack / stackHolds
  local gameOn = { stack = bareStack({ target, mid }) }
  eq(coop:onStack(gameOn, target), Coop.stackHolds(gameOn, target),
     "M:onStack and Coop.stackHolds agree")
  check(coop:onStack(gameOn, target) == true,
        "...and both correctly say the target is there")
  local gameOff = { stack = bareStack({ mid }) }
  eq(coop:onStack(gameOff, target), Coop.stackHolds(gameOff, target),
     "...and agree just as well when the answer is false")

  -- unwindTo / unwindStackTo, driven against two independent stacks built the
  -- same way so neither call can be seeing the other's side effects.
  local targetA, midA = {}, {}
  local stackA = bareStack({ targetA, midA })
  local targetB, midB = {}, {}
  local stackB = bareStack({ targetB, midB })
  local resultMethod = coop:unwindTo({ stack = stackA }, targetA, true)
  local resultStatic = Coop.unwindStackTo({ stack = stackB }, targetB, true)
  eq(resultMethod, resultStatic,
     "M:unwindTo and Coop.unwindStackTo return the same verdict")
  eq(#stackA.states, #stackB.states,
     "...and leave the stack in the same shape")
end


-- ------------------------------------------------------------------
-- 14. badges ride a co-op upload only against the computer
-- ------------------------------------------------------------------
--
-- docs/plans/gen3-badge-rules.md, Gen 1 and Gen 2: no cart boosts in a link
-- battle (pokered's ApplyBadgeStatBoosts and pokecrystal's BadgeStatBoosts both
-- return early under a link), so a coop_pvp upload carries no badges even from
-- a player who holds them, and a coop_npc one carries its own player's.  The
-- referee is the gate that counts, not the client: badges forged onto a
-- coop_pvp upload, or onto the trainer's team, are dropped all the same.

do
  -- What this player's save says.  A Gold client reads its own stores
  -- (`player.badges` Johto, `player.kantoBadges` Kanto), Red's reads the badge
  -- rows against the bag.  The field a screen builds here is Gen 1's shell
  -- whatever the save is (CoopField.new refuses a Gold game), so the Gold save
  -- is put on the screen after the field exists: what a client uploads is read
  -- off `self.game`.
  local function holder(generation)
    local game = newGame()
    if generation == 2 then
      game.generation = 2
      game.save.player = { badges = { ZEPHYR = true }, kantoBadges = { BOULDER = true } }
    else
      game.save.inventory = { BOULDERBADGE = 1 }
    end
    return game
  end
  local HELD = { [1] = "BOULDERBADGE", [2] = "ZEPHYR,BOULDER" }
  local function partyOf(sc, side)
    for _, msg in ipairs(sc.sent) do
      if msg.type == Wire.BATTLE_PARTY and msg.payload.side == side then return msg.payload end
    end
    return nil
  end
  local function upload(generation, mode, mine)
    local sc = screen({ slots = mode == "coop_npc" and npcSlots() or pvpSlots(), mine = mine,
                        host = mine == 1, mode = mode, selfId = mine == 1 and "ann" or "bob" })
    sc.game = holder(generation)
    eq(sc:uploadMediated(), true, "badges: the " .. mode .. " upload goes out")
    return sc
  end

  for generation = 1, 2 do
    local cart = generation == 1 and "Gen 1" or "Gold"
    local host = upload(generation, "coop_npc", 1)
    local up = partyOf(host, "a")
    eq(table.concat(up and up.badges or {}, ","), HELD[generation],
       "badges (" .. cart .. "): a coop_npc host uploads its own player's")
    check(up ~= nil and Wire.battleParty(up) ~= nil and Wire.battleParty(up).badges ~= nil,
          "badges (" .. cart .. "): ...and they survive Wire.battleParty")
    eq(partyOf(host, "b") and partyOf(host, "b").badges, nil,
       "badges (" .. cart .. "): the trainer's team carries none")
    local guest = upload(generation, "coop_npc", 2)
    eq(table.concat(partyOf(guest, "a").badges or {}, ","), HELD[generation],
       "badges (" .. cart .. "): ...and a coop_npc guest uploads its own")

    local pvpHost = upload(generation, "coop_pvp", 1)
    eq(partyOf(pvpHost, "a") and partyOf(pvpHost, "a").badges, nil,
       "badges (" .. cart .. "): a coop_pvp host uploads none, holding them")
    local pvpGuest = upload(generation, "coop_pvp", 2)
    eq(partyOf(pvpGuest, "a") and partyOf(pvpGuest, "a").badges, nil,
       "badges (" .. cart .. "): ...nor does a coop_pvp guest")
  end

  -- Through a real hub, Gen 1: a trainer fight seats ANN's badge on her fighter
  -- and none on BOB's; a four-player spar seats none, though every client
  -- holds one and the second spar has the badge forged onto every upload.
  local function join(hub, name)
    local peer = { outbox = {} }
    function peer:send(msg) self.outbox[#self.outbox + 1] = msg end
    function peer:close() end
    local client = hub:accept(peer)
    hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
      playerId = testPlayerId(name), name = name, map = "PALLET", x = 5, y = 5, facing = "down" })
    return client
  end
  -- What the screen sent, as that client's own messages.  `forge` hangs a
  -- badge on the uploads a hostile client would: `true` on every party, or the
  -- name of one side ("b" is the trainer's team).
  local function relay(hub, client, sc, forge)
    for _, msg in ipairs(sc.sent) do
      local payload = {}
      for k, v in pairs(msg.payload) do payload[k] = v end
      payload.type = msg.type
      if msg.type == Wire.BATTLE_PARTY and (forge == true or forge == payload.side) then
        payload.badges = { "BOULDERBADGE" }
      end
      hub:receive(client, payload)
    end
  end
  local function badgeNames(fighter)
    local names = {}
    for name in pairs(fighter and fighter.badges or {}) do names[#names + 1] = name end
    table.sort(names)
    return table.concat(names, ",")
  end

  for _, forge in ipairs({ false, "b" }) do
    local label = forge and "badges (hub, forged trainer)" or "badges (hub)"
    local hub = Hub.new({ maxPlayers = 4 })
    local ann, bob = join(hub, "ANN"), join(hub, "BOB")
    hub:openCoopBattle("bd1", { ann.id, bob.id }, { mode = "coop_npc", hostId = ann.id })
    local npcField = npcSlots()
    npcField[1].owner, npcField[2].owner = ann.id, bob.id
    local annScreen = screen({ slots = npcField, mine = 1, host = true, mode = "coop_npc",
                               selfId = ann.id, battleId = "bd1" })
    local bobScreen = screen({ slots = npcField, mine = 2, host = false, mode = "coop_npc",
                               selfId = bob.id, battleId = "bd1" })
    annScreen.game = holder(1)
    annScreen:uploadMediated()
    bobScreen:uploadMediated()
    relay(hub, ann, annScreen, forge)
    relay(hub, bob, bobScreen)
    local record = hub.battles["bd1"]
    check(record and record.sim ~= nil, label .. ": the trainer fight is refereed")
    eq(badgeNames(record.sim.byId[ann.id]), "BOULDERBADGE", label .. ": ANN's seat holds her badge against the trainer")
    eq(badgeNames(record.sim.byId[bob.id]), "", label .. ": ...and BOB's, who holds none, holds none")
    if forge then
      check(record.parties[record.npcIds[1]].badges ~= nil, label .. ": the forged badge reached the hub's record")
    end
    for _, npcId in ipairs(record.npcIds) do
      eq(record.sim.byId[npcId].badges, nil, label .. ": the trainer's seat holds none")
    end
  end

  for _, forged in ipairs({ false, true }) do
    local label = forged and "badges (hub, forged)" or "badges (hub)"
    local spar = Hub.new({ maxPlayers = 4 })
    local names = { "ANN", "BOB", "CAL", "DEE" }
    local clients, ids = {}, {}
    for i, name in ipairs(names) do clients[i] = join(spar, name); ids[i] = clients[i].id end
    spar:openCoopBattle("bp1", ids, { mode = "coop_pvp", hostId = ids[1],
      sides = { a = { ids[1], ids[2] }, b = { ids[3], ids[4] } } })
    local field = pvpSlots()
    for i = 1, 4 do field[i].owner = ids[i] end
    for i = 1, 4 do
      local sc = screen({ slots = field, mine = i, host = i == 1, mode = "coop_pvp",
                          selfId = ids[i], battleId = "bp1" })
      sc.game = holder(1)
      sc:uploadMediated()
      relay(spar, clients[i], sc, forged)
    end
    local sparRecord = spar.battles["bp1"]
    check(sparRecord and sparRecord.sim ~= nil, label .. ": the spar is refereed")
    if forged then
      check(sparRecord.parties[ids[1]].badges ~= nil, label .. ": the forged badges reached the hub's record")
    end
    for i = 1, 4 do
      eq(sparRecord.sim.byId[ids[i]].badges, nil, label .. ": " .. names[i] .. "'s seat holds no badge")
    end
  end
end

-- ------------------------------------------------------------------
-- 15. Gold's held items in a 2-on-2 (docs/plans/gen12-referee-fidelity.md)
-- ------------------------------------------------------------------
--
-- The co-op half of the client contract: our own sheets carry `traded` (K1)
-- and the K2 item fields against the computer; a Gold `held` event moves our
-- own seat's item -- the fight sheet always, the save only in a fight against
-- the computer, never a partner's, never one nobody uploaded; the host rolls
-- the wild monster's item Gold's engine never gives it; and an AMULET COIN
-- sent out doubles the prize on every path that pays one.  As in section 14
-- the field is Gen 1's shell (CoopField.new refuses a Gold game), so the Gold
-- game goes on the screen after the field exists.  Item rows are invented.

do
  local GOLD_ITEMS = {
    BERRY       = { name = "BERRY", heldEffect = "HELD_BERRY", heldParameter = 6 },
    NUGGET      = { name = "NUGGET", heldEffect = "HELD_NONE", heldParameter = 0 },
    AMULET_COIN = { name = "AMULET COIN", heldEffect = "HELD_AMULET_COIN", heldParameter = 2 },
    MASTER_BALL = { name = "MASTER BALL" },
  }
  local goldDataT = setmetatable({ items = GOLD_ITEMS }, { __index = data })
  local function goldGame()
    local game = newGame()
    game.generation = 2
    game.data = goldDataT
    game.save.generation = 2
    game.save.player = { name = "ANN", id = 4321, money = 0 }
    return game
  end
  local function holding(m, item, otId)
    m.item, m.otId = item, otId
    return m
  end
  -- ANN on seat 1 (BERRY, her own), BOB on seat 2 (BERRY), the trainer's two
  -- on seats 3 / 4 holding NUGGET.  `mine` 2 makes this BOB's screen.
  local function goldScreen(mode, mine)
    local slots = mode == "coop_pvp" and pvpSlots() or npcSlots()
    holding(slots[1].party[1], "BERRY", 4321)
    holding(slots[2].party[1], "BERRY", 4321)
    holding(slots[3].party[1], "NUGGET")
    holding(slots[4].party[1], "NUGGET")
    local sc = screen({ slots = slots, mine = mine or 1, host = (mine or 1) == 1, mode = mode,
                        selfId = (mine or 1) == 1 and "ann" or "bob" })
    sc.game = goldGame()
    sc.gen2Mediated = true
    -- A party-vs-wild host describes the wild seat from the engine's monster.
    if mode == "coop_wild" then sc.wildCatchMon = slots[3].party[1] end
    eq(sc:uploadMediated(), true, "gold " .. mode .. ": the upload goes out")
    sc.mediated = true
    sc.medSlots = { [0] = 1, [1] = 2, [2] = 3, [3] = 4 }
    sc.medFields = { [1] = 0, [2] = 1, [3] = 2, [4] = 3 }
    return sc, slots
  end
  local function heldAt(field, mon, item, amount)
    return { battle = "cb1", seq = 1, t = "held", slot = field, side = field < 2 and "a" or "b",
             mon = mon, text = item, amount = amount }
  end
  -- One event through the screen the way a batch goes: rows built at parse,
  -- played (and so applied) in the stream's order.
  local function play(screenIn, msg)
    local rows = screenIn:medRows(msg)
    screenIn:playEvents(rows)
    return rows
  end

  -- K1 / K2 on the co-op upload.
  local sc = goldScreen("coop_npc")
  local up
  for _, msg in ipairs(sc.sent) do
    if msg.type == Wire.BATTLE_PARTY and msg.payload.side == "a" then up = msg.payload end
  end
  eq(up and up.mons[1].heldItem, "BERRY", "gold co-op: our sheet carries the item")
  eq(up and up.mons[1].holdEffect, "HELD_BERRY", "gold co-op: ...its hold effect (K2)")
  eq(up and up.mons[1].holdParam, 6, "gold co-op: ...and parameter")
  eq(up and up.mons[1].traded, nil, "gold co-op: ANN's own mon is not traded")
  local packed = up and Wire.battleParty(up, 2)
  check(packed ~= nil and packed.mons[1].holdEffect == "HELD_BERRY",
        "gold co-op: the upload survives Wire.battleParty")
  local tradeSlots = npcSlots()
  holding(tradeSlots[1].party[1], nil, 77)
  local traded = screen({ slots = tradeSlots, mine = 1, host = true, mode = "coop_npc", selfId = "ann" })
  traded.game = goldGame()
  traded:uploadMediated()
  local tradedUp
  for _, msg in ipairs(traded.sent) do
    if msg.type == Wire.BATTLE_PARTY and msg.payload.side == "a" then tradedUp = msg.payload end
  end
  eq(tradedUp and tradedUp.mons[1].traded, true, "gold co-op: a traded mon says so against the computer (K1)")
  local pvpTrade = screen({ slots = (function()
      local s = pvpSlots(); holding(s[1].party[1], nil, 77); return s end)(),
    mine = 1, host = true, mode = "coop_pvp", selfId = "ann" })
  pvpTrade.game = goldGame()
  pvpTrade:uploadMediated()
  for _, msg in ipairs(pvpTrade.sent) do
    if msg.type == Wire.BATTLE_PARTY then
      eq(msg.payload.mons[1].traded, nil, "gold co-op: ...and never in coop_pvp, a link battle")
    end
  end

  -- A berry eaten on our own seat: the save mon (the seat's own party) and the
  -- sheet, in the fights the cart keeps it from.
  for _, mode in ipairs({ "coop_npc", "coop_wild" }) do
    local s, slots = goldScreen(mode)
    local rows = play(s, heldAt(0, 0, "BERRY", 0))
    eq(slots[1].party[1].item, nil, "gold held (" .. mode .. "): our berry eaten is gone from the party")
    eq(s.medMine[1].heldItem, nil, "gold held (" .. mode .. "): ...and from the sheet")
    local said = false
    for _, row in ipairs(rows) do
      if row.kind == "msg" then said = true end
    end
    check(not said, "gold held (" .. mode .. "): the item's id is never printed as a line")
  end
  -- Applied where the stream puts it, when the batch is played -- the same
  -- walk that pays an `exp` row -- not when the event is parsed.
  local deferred, deferredSlots = goldScreen("coop_npc")
  local pendingRows = deferred:medRows(heldAt(0, 0, "BERRY", 0))
  eq(deferredSlots[1].party[1].item, "BERRY", "gold held: parsed, not yet played -- nothing has moved")
  deferred:playEvents(pendingRows)
  eq(deferredSlots[1].party[1].item, nil, "gold held: ...played in the stream's order, it lands")
  -- A fight between players: the sheet follows, the save never does.
  local pvp, pvpSlotsT = goldScreen("coop_pvp")
  play(pvp, heldAt(0, 0, "BERRY", 0))
  eq(pvpSlotsT[1].party[1].item, "BERRY", "gold held (coop_pvp): nothing written home")
  eq(pvp.medMine[1].heldItem, nil, "gold held (coop_pvp): ...though the sheet follows the referee")
  -- A partner's seat is the partner's to write.
  local ann, annSlots = goldScreen("coop_npc")
  play(ann, heldAt(1, 0, "BERRY", 0))
  eq(annSlots[2].party[1].item, "BERRY", "gold held: BOB's berry is not written by ANN's client")
  eq(annSlots[1].party[1].item, "BERRY", "gold held: ...nor does it touch ANN's own")

  -- THIEF: the host described the trainer's team, so its NUGGET is one of her
  -- own uploads and is kept; BOB (a joiner) never uploaded it, so his is not.
  local host, hostSlots = goldScreen("coop_npc")
  play(host, heldAt(2, 0, "NUGGET", 0))
  play(host, heldAt(0, 0, "NUGGET", 1))
  eq(hostSlots[1].party[1].item, "NUGGET", "gold thief: the host keeps an item from the team it described")
  local bob, bobSlots = goldScreen("coop_npc", 2)
  local mark = #warns
  play(bob, heldAt(1, 0, "NUGGET", 1))
  eq(bobSlots[2].party[1].item, "BERRY",
     "gold thief: a joiner keeps no gain no foe's loss stands behind (anti-forgery)")
  check(#warns > mark, "gold thief: ...and is told why")
  eq(bob.medMine[1].heldItem, "NUGGET", "gold thief: ...though its fight sheet shows what it holds now")
  local forged = goldScreen("coop_npc")
  play(forged, heldAt(0, 0, "MASTER_BALL", 1))
  eq(forged.sim:slot(1).party[1].item, "BERRY", "gold held: an item nobody uploaded never enters the save")
  local stray, straySlots = goldScreen("coop_npc")
  straySlots[1].party[2] = holding(mon(60, 40), "BERRY", 4321)
  play(stray, heldAt(0, 1, "BERRY", 0))
  eq(straySlots[1].party[2].item, "BERRY", "gold held: a sheet index this client never uploaded writes nothing")
  eq(straySlots[1].party[1].item, "BERRY", "gold held: ...not even onto whoever is out")

  -- AMULET COIN: our own send-out with one latches it; a partner's does not.
  local coin, coinSlots = goldScreen("coop_npc")
  coinSlots[1].party[1].item = "AMULET_COIN"
  coin.medMine[1].heldItem, coin.medMine[1].holdEffect = "AMULET_COIN", "HELD_AMULET_COIN"
  coin.medMine[1].slot = 0
  eq(coin:amuletCoin2(), false, "gold amulet: nothing out yet")
  play(coin, { battle = "cb1", seq = 2, t = "send", slot = 1, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
  eq(coin:amuletCoin2(), false, "gold amulet: a partner's send-out is not ours")
  play(coin, { battle = "cb1", seq = 3, t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
  eq(coin:amuletCoin2(), true, "gold amulet: ours, holding the coin, latches it")

  -- ...and the prize it doubles, on every path that pays one.
  local engine = { trainer = { baseMoney = 10 }, enemyParty = { { level = 20 } } }
  local purse = { save = { generation = 2, player = { money = 0 } } }
  eq(Coop.payTrainerPrize(engine, purse, "win"), 200, "gold prize: baseMoney x best level")
  engine.amuletCoin = true
  eq(Coop.payTrainerPrize(engine, purse, "win"), 400, "gold prize: doubled by an AMULET COIN sent out")
  eq(purse.save.player.money, 600, "gold prize: into save.player.money")
  eq(Coop.payTrainerPrize(engine, purse, "loss"), 0, "gold prize: a loss pays nothing, coin or not")

  local finished
  local walkIn = { trainer = { baseMoney = 10 }, enemyParty = { { level = 20 } },
                   onFinish = function(o) finished = o end }
  local walkGame = { save = { generation = 2, player = { money = 100 }, party = { mon(30, 10) } },
                     data = { constants = {} } }
  local walker = setmetatable({ engineBattle = walkIn, party = { count = function() return 2 end } },
                              { __index = Coop })
  walker:onBattleOver("win", walkGame, coin, nil)
  eq(finished, "win", "gold prize (walk-in): the buried battle is told it was won")
  eq(walkGame.save.player.money, 500, "gold prize (walk-in): 100 + 2 x 200, the screen's coin read")
  local plain = setmetatable({ engineBattle = { trainer = { baseMoney = 10 }, enemyParty = { { level = 20 } },
                                                onFinish = function() end },
                               party = { count = function() return 2 end } }, { __index = Coop })
  local plainGame = { save = { generation = 2, player = { money = 100 }, party = { mon(30, 10) } },
                      data = { constants = {} } }
  plain:onBattleOver("win", plainGame, ann, nil)
  eq(plainGame.save.player.money, 300, "gold prize (walk-in): a fight with no coin out pays once")

  -- The invite joiner's synthetic finish reads the same answer off the screen.
  local ow = {
    npcPool = { npc9 = { def = { trainerClass = "OPP_FIX", trainerParty = 1, index = 1 } } },
    map = { def = { label = "FIX_TOWN" } },
    afterBattle = function() end,
  }
  local joinerGame = { save = { generation = 2, player = { money = 0 } },
                       data = setmetatable({ trainers = { OPP_FIX = { id = "OPP_FIX", baseMoney = 10,
                         parties = { { { level = 20 } } } } } }, { __index = data }),
                       stack = { states = { ow } } }
  local joiner = setmetatable({}, { __index = Coop })
  eq(joiner:syntheticFinish(joinerGame, { npcId = "npc9" }, coin), true, "gold prize (joiner): the finish runs")
  eq(joinerGame.save.player.money, 400, "gold prize (joiner): doubled by the coin the screen saw")

  -- The wild monster's item: rolled by the host at its upload, once, onto the
  -- engine monster a catch keeps.
  local rollSlots = {
    { side = "a", owner = "ann", name = "ANN", party = { holding(mon(60, 40), nil, 4321) } },
    { side = "a", owner = "bob", name = "BOB", party = { mon(60, 30) } },
    { side = "b", owner = nil, name = "WILD", party = { mon(50, 20) } },
  }
  local wildMon = mon(50, 20)
  local wildHost = screen({ slots = rollSlots, mine = 1, host = true, mode = "coop_wild", selfId = "ann" })
  wildHost.game = goldGame()
  wildHost.game.data = setmetatable({ pokemon = setmetatable({
      [SPECIES] = setmetatable({ items = { "BERRY", "NUGGET" } }, { __index = data.pokemon[SPECIES] }),
    }, { __index = data.pokemon }) }, { __index = goldDataT })
  wildHost.gen2Mediated = true
  wildHost.wildCatchMon = wildMon
  local realByte = CoopBattle.randomByte
  local draws = { 250, 99 }
  local drawn = 0
  CoopBattle.randomByte = function() drawn = drawn + 1; return draws[drawn] end
  eq(wildHost:uploadMediated(), true, "gold wild: the host's upload goes out")
  local wildUp
  for _, msg in ipairs(wildHost.sent) do
    if msg.type == Wire.BATTLE_PARTY and msg.payload.side == "b" then wildUp = msg.payload end
  end
  eq(wildMon.item, "BERRY", "gold wild: the host rolls the cart's item onto the engine monster")
  eq(wildUp and wildUp.mons[1].heldItem, "BERRY", "gold wild: ...and the wild seat's sheet carries it")
  eq(wildUp and wildUp.mons[1].holdEffect, "HELD_BERRY", "gold wild: ...with its K2 fields")
  eq(drawn, 2, "gold wild: two draws, the cart's")
  wildHost:wildMons()
  eq(drawn, 2, "gold wild: rolled once, however often the seat is described")
  CoopBattle.randomByte = realByte
  -- The catch keeps what it still holds: THIEF took it, so nothing.
  wildHost.mediated = true
  wildHost.medSlots = { [0] = 1, [1] = 2, [2] = 3 }
  play(wildHost, { battle = "cb1", seq = 1, t = "held", slot = 2, side = "b", mon = 0,
                     text = "BERRY", amount = 0 })
  eq(wildHost.foeHeld2 and wildHost.foeHeld2[0], false, "gold wild: the foe's loss is remembered")
  wildHost:grantCatch({ caught = {} })
  eq(wildMon.item, nil, "gold wild: a monster caught after losing its item holds none")
  -- Its own THIEF of an item this client never described (a partner's): the
  -- BERRY it was rolled is already gone -- THIEF takes only when its user holds
  -- nothing (pokecrystal BattleCommand_Thief `.enemy`) -- and the item it took
  -- is not this client's to write, so it is caught holding nothing, not with
  -- the pre-fight roll handed back.
  wildMon.item = "BERRY"
  play(wildHost, { battle = "cb1", seq = 2, t = "held", slot = 2, side = "b", mon = 0,
                     text = "MASTER_BALL", amount = 1 })
  eq(wildHost.foeHeld2 and wildHost.foeHeld2[0], "MASTER_BALL", "gold wild: the foe's gain is remembered")
  wildHost:grantCatch({ caught = {} })
  eq(wildMon.item, nil, "gold wild: a foreign item it took is not caught, and its lost roll is not handed back")
  -- One this client did describe, held at the throw: caught with it.
  wildMon.item = nil
  play(wildHost, { battle = "cb1", seq = 3, t = "held", slot = 2, side = "b", mon = 0,
                     text = "BERRY", amount = 1 })
  wildHost:grantCatch({ caught = {} })
  eq(wildMon.item, "BERRY", "gold wild: an item this client described is caught with it")

  -- ------- closing the referee gaps, the 2-on-2's half
  -- (docs/plans/gen12-referee-gaps-fix.md, wave 2 task C)

  -- Gold trainer items ride the host's npc sheets (gap #12, proven): the
  -- trainer's engine party mons hold items (src/world/gen2/Trainers.lua
  -- Trainers.party), and the host describes them with the K2 fields.
  local npcHost = goldScreen("coop_npc")
  local npcUp
  for _, msg in ipairs(npcHost.sent) do
    if msg.type == Wire.BATTLE_PARTY and msg.payload.side == "b" then npcUp = msg.payload end
  end
  eq(npcUp and npcUp.mons[1].heldItem, "NUGGET", "gold trainer item: the host's npc sheet carries the item")
  eq(npcUp and npcUp.mons[1].holdEffect, "HELD_NONE", "gold trainer item: ...with its K2 hold effect")
  eq(npcUp and npcUp.mons[1].itemName, "NUGGET", "gold trainer item: ...and the name the cart prints")
  local npcPacked = npcUp and Wire.battleParty(npcUp, 2)
  eq(npcPacked and npcPacked.mons[1].heldItem, "NUGGET", "gold trainer item: ...which the wire keeps")
  -- K7 / K8 / K14 on the same uploads.
  eq(npcUp and npcUp.mons[1].dvs and npcUp.mons[1].dvs.spe, 8, "K7 (co-op): the trainer's sheet carries its DVs")
  eq(npcUp and npcUp.mons[1].moves[1].priority, 1, "K8 (co-op): a Gold row states its priority byte")

  -- The joiner's THIEF from a trainer: kept only when the trainer this client
  -- resolved itself holds that item in its party rows.
  local bobT, bobTSlots = goldScreen("coop_npc", 2)
  bobT.trainer = { party = { { item = "NUGGET" }, { item = nil } } }
  play(bobT, heldAt(2, 0, "NUGGET", 0))
  play(bobT, heldAt(1, 0, "NUGGET", 1))
  eq(bobTSlots[2].party[1].item, "NUGGET",
     "gold thief (joiner): an item the named trainer's own party row holds is kept")
  local bobF, bobFSlots = goldScreen("coop_npc", 2)
  bobF.trainer = { party = { { item = "BERRY" } } }
  play(bobF, heldAt(2, 0, "NUGGET", 0))
  play(bobF, heldAt(1, 0, "NUGGET", 1))
  eq(bobFSlots[2].party[1].item, "BERRY",
     "gold thief (joiner): ...not one this client's data says that trainer never held")
  local bobN, bobNSlots = goldScreen("coop_npc", 2)
  play(bobN, heldAt(2, 0, "NUGGET", 0))
  play(bobN, heldAt(1, 0, "NUGGET", 1))
  eq(bobNSlots[2].party[1].item, "BERRY",
     "gold thief (joiner): ...nor any, when this client resolved no trainer at all")
  local bobS, bobSSlots = goldScreen("coop_npc", 2)
  bobS.trainer = { party = { { item = "NUGGET" } } }
  play(bobS, heldAt(2, 0, "NUGGET", 0))
  play(bobS, heldAt(0, 0, "BERRY", 0))  -- something else in between
  play(bobS, heldAt(1, 0, "NUGGET", 1))
  eq(bobSSlots[2].party[1].item, "BERRY",
     "gold thief (joiner): a loss vouches only for the gain right behind it")
  -- The rows the engine data names, by class and member, when the record
  -- carries no built party (Trainers.classIndex over data.trainers).
  local looked = goldScreen("coop_npc", 2)
  looked.game.data = setmetatable({ trainers = { classes = { FIXCLASS = { index = 7,
    trainers = { { id = "FIX1", party = { { species = SPECIES, level = 5, item = "NUGGET" } } } } } } } },
    { __index = goldDataT })
  looked.trainer = { class = 7, memberId = "FIX1" }
  eq(table.concat(looked:trainerItems2(), ","), "NUGGET",
     "gold thief (joiner): the named trainer's rows, looked up in the engine's own data")

  -- The joiner's THIEF from a wild monster, and its catch: the species' own
  -- wild item slots in this client's data.
  local wildData = setmetatable({ pokemon = setmetatable({
      [SPECIES] = setmetatable({ items = { "BERRY", "NUGGET" } }, { __index = data.pokemon[SPECIES] }),
    }, { __index = data.pokemon }) }, { __index = goldDataT })
  local joinSlots = {
    { side = "a", owner = "ann", name = "ANN", party = { holding(mon(60, 40), nil, 4321) } },
    { side = "a", owner = "bob", name = "BOB", party = { holding(mon(60, 30), nil, 4321) } },
    { side = "b", owner = nil, name = "WILD", party = { holding(mon(50, 20), "NUGGET") } },
  }
  local joinW = screen({ slots = joinSlots, mine = 2, host = false, mode = "coop_wild", selfId = "bob" })
  joinW.game = goldGame()
  joinW.game.data = wildData
  joinW.gen2Mediated = true
  eq(joinW:uploadMediated(), true, "gold wild (joiner): the joiner's upload goes out")
  joinW.mediated = true
  joinW.medSlots = { [0] = 1, [1] = 2, [2] = 3 }
  joinW.sim:sendOut(joinW.sim:slot(3), 1, true)
  play(joinW, heldAt(2, 0, "NUGGET", 0))
  play(joinW, heldAt(1, 0, "NUGGET", 1))
  eq(joinSlots[2].party[1].item, "NUGGET",
     "gold thief (joiner, wild): an item in the species' own item slots is kept")
  play(joinW, heldAt(2, 0, "MASTER_BALL", 0))
  play(joinW, heldAt(1, 0, "MASTER_BALL", 1))
  eq(joinSlots[2].party[1].item, "NUGGET",
     "gold thief (joiner, wild): ...one off its slots is not, whoever says the foe held it")
  -- The catch: rebuilt off the outcome's sheet, its item checked the same way.
  local caught = Mediated.snapshotMons(joinW.game, { holding(mon(50, 20), "BERRY") })[1]
  joinW.game.save.party = {}
  joinW.foeHeld2 = nil
  joinW:grantCatch({ caught = caught })
  local got = joinW.game.save.party[1]
  check(got ~= nil, "gold catch (joiner): the monster is rebuilt into the party")
  eq(got and got.item, "BERRY", "gold catch (joiner): ...holding an item its species can carry")
  local forgedCatch = Mediated.snapshotMons(joinW.game, { holding(mon(50, 20), "MASTER_BALL") })[1]
  joinW.game.save.party = {}
  joinW:grantCatch({ caught = forgedCatch })
  got = joinW.game.save.party[1]
  eq(got and got.item, nil, "gold catch (joiner): ...and nothing its species never carries")

  -- K9: our own seat's level-up, once, with the move list (2-on-2).
  local lv, lvSlots = goldScreen("coop_npc")
  local own = lvSlots[1].party[1]
  local before = lv.countSent(Wire.BATTLE_MOVESET)
  own.level = 21
  own.stats = { hp = 64, attack = 32, defense = 31, special = 33, speed = 41 }
  lv:levelled(own, nil, { 21 })
  eq(lv.countSent(Wire.BATTLE_MOVESET) - before, 1, "K9 (co-op): a level-up of our own mon goes out once")
  local lvMsg
  for _, msg in ipairs(lv.sent) do if msg.type == Wire.BATTLE_MOVESET then lvMsg = msg.payload end end
  eq(lvMsg and lvMsg.level, 21, "K9 (co-op): ...with the new level")
  eq(lvMsg and lvMsg.maxHp, 64, "K9 (co-op): ...max HP")
  eq(lvMsg and lvMsg.stats and lvMsg.stats.spe, 41, "K9 (co-op): ...and Gold-dialect stats")
  check(lvMsg and Wire.battleMoveset(lvMsg, 2) ~= nil, "K9 (co-op): ...which the hub reads")
  local partner = lvSlots[2].party[1]
  partner.level = 21
  lv:levelled(partner, nil, { 21 })
  eq(lv.countSent(Wire.BATTLE_MOVESET) - before, 1, "K9 (co-op): a partner's monster is the partner's to report")

  -- K11: PAY DAY, every human on side a picks the pot up.
  local function outcome(sc, coins, winners, losers, reason)
    sc:onBattleOutcome({ battle = "cb1", outcome = "win", winners = winners, losers = losers,
                         reason = reason or "ko", payDay = coins })
  end
  local function lines(sc)
    local out = {}
    for _, list in ipairs({ sc.messages or {}, sc.medPending or {} }) do
      for _, row in ipairs(list) do
        local text = type(row) == "string" and row or (type(row) == "table" and row.text)
        if type(text) == "string" then out[#out + 1] = text end
      end
    end
    return table.concat(out, "|")
  end
  local payA = goldScreen("coop_npc")
  outcome(payA, 50, { "ann", "bob" }, { "npc1", "npc2" })
  eq(payA.game.save.player.money, 50, "Pay Day (co-op): ANN is paid the pot")
  check(lines(payA):find("ANN picked up\n¥50!", 1, true) ~= nil, "Pay Day (co-op): ...and reads the cart's line")
  local payB = goldScreen("coop_npc", 2)
  outcome(payB, 50, { "ann", "bob" }, { "npc1", "npc2" })
  eq(payB.game.save.player.money, 50, "Pay Day (co-op): BOB is paid the same whole pot (plan §9)")
  local payCoin, payCoinSlots = goldScreen("coop_npc")
  payCoinSlots[1].party[1].item = "AMULET_COIN"
  payCoin.medMine[1].heldItem, payCoin.medMine[1].holdEffect = "AMULET_COIN", "HELD_AMULET_COIN"
  play(payCoin, { battle = "cb1", seq = 3, t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
  outcome(payCoin, 50, { "ann", "bob" }, { "npc1", "npc2" })
  eq(payCoin.game.save.player.money, 100, "Pay Day (co-op, Gold): doubled by our AMULET COIN")
  local payPvp = goldScreen("coop_pvp")
  outcome(payPvp, 50, { "ann", "bob" }, { "cal", "dee" })
  eq(payPvp.game.save.player.money, 0, "Pay Day (co-op): never between players")
  local payLost = goldScreen("coop_npc")
  outcome(payLost, 50, { "npc1", "npc2" }, { "ann", "bob" }, "run")
  eq(payLost.game.save.player.money, 0, "Pay Day (co-op, Gold): a flee is a DRAW on Gold -- nothing")
  -- Red pays a flee (EndOfBattle while wBattleResult is 0).
  local redRun = screen({ slots = npcSlots(), mine = 1, host = true, mode = "coop_wild", selfId = "ann" })
  redRun.mediated = true
  redRun.game.save.money = 10
  outcome(redRun, 30, { "npc1" }, { "ann", "bob" }, "run")
  eq(redRun.game.save.money, 40, "Pay Day (co-op, Red): a flee picks the pot up")
end

-- ------- the Gold target picker asks for every move aimed at somebody
do
  local goldPick = setmetatable({
    game = { generation = 2, data = { moves = {
      HYPNOSIS = { power = 0, effect = "EFFECT_SLEEP" },
      THUNDER_WAVE = { power = 0, effect = "EFFECT_PARALYZE" },
      MEAN_LOOK = { power = 0, effect = "EFFECT_MEAN_LOOK" },
      SWORDS_DANCE = { power = 0, effect = "EFFECT_ATTACK_UP_2" },
      PROTECT = { power = 0, effect = "EFFECT_PROTECT" },
      HAZE = { power = 0, effect = "EFFECT_RESET_STATS" },
      SPIKES = { power = 0, effect = "EFFECT_SPIKES" },
      TRANSFORM = { power = 0, effect = "EFFECT_TRANSFORM" },
      CURSE = { power = 0, effect = "EFFECT_CURSE" },
      ZAP = { power = 0, effect = "EFFECT_SOMETHING_NEW" },
      TACKLE = { power = 35, effect = "EFFECT_NORMAL_HIT" },
    }, move_effects = { EFFECT_SLEEP = { kind = "primary" }, EFFECT_PARALYZE = { kind = "primary" },
                        EFFECT_MEAN_LOOK = { kind = "primary" } } } },
  }, { __index = CoopBattle })
  local function aims(id) return goldPick:needsTarget({ id = id }) end
  eq(aims("HYPNOSIS"), true, "Gold picker: HYPNOSIS (a primary status record) asks whom")
  eq(aims("THUNDER_WAVE"), true, "Gold picker: THUNDER WAVE too")
  eq(aims("MEAN_LOOK"), true, "Gold picker: MEAN LOOK too")
  eq(aims("SWORDS_DANCE"), false, "Gold picker: a stat raise is aimed at nobody")
  eq(aims("PROTECT"), false, "Gold picker: PROTECT likewise")
  eq(aims("HAZE"), false, "Gold picker: HAZE resets every battler")
  eq(aims("SPIKES"), false, "Gold picker: SPIKES lands on the foe's side, not a foe")
  eq(aims("TRANSFORM"), true, "Gold picker: TRANSFORM reads its target")
  eq(aims("CURSE"), true, "Gold picker: CURSE reads one when its user is a Ghost")
  eq(aims("ZAP"), true, "Gold picker: an effect off the list keeps the picker")
  eq(aims("TACKLE"), true, "Gold picker: anything with power keeps it")
end

-- ------------------------------------------------------------------
-- 16. closing the Red / Gold referee gaps, wave 3 (task C2a)
-- ------------------------------------------------------------------
--
-- The Gold picker for the referee's wave-2 ids (102-105); the Transform
-- overlay through a learn (Red drops it, Gold keeps it -- each cart's
-- LearnMove) and at the faint; the party list a referee states behind a
-- switch-out or a faint (Gold's MYSTERYBERRY restored under Transform) written
-- onto that party monster; Red's paying escape; a foe's Gold happiness; and an
-- invite joiner's Gold trainer, looked up by class and member.  Trainer,
-- class and item names here are invented.

do
  local Gen = need("Gen")
  local Effects2 = need("BattleSim2/Effects")
  local GOLD_ITEMS = {
    NUGGET = { name = "NUGGET", heldEffect = "HELD_NONE", heldParameter = 0 },
    FIX_POTION = { name = "FIX POTION" },
  }
  -- The joiner's own copy of the Gold trainer table (the importer's shape,
  -- src/import/RomExtractorGen2.lua: classes by constant, each with its
  -- numeric `index`, its attribute row and its members).
  local function goldTrainers()
    return { classes = {
      FIXCLASS = { id = "FIXCLASS", index = 7, name = "FIX CLASS", baseMoney = 9,
                   attributes = { 0, 0, 9, 0, 0, 0, 0 }, items = { "FIX_POTION" },
                   trainers = {
                     { id = "FIX1", name = "ABE", trainerType = "TRAINERTYPE_ITEM",
                       party = { { species = SPECIES, level = 5, item = "NUGGET" } } },
                     { id = "FIX2", name = "BEA", party = { { species = SPECIES, level = 7 } } },
                   } },
      RIVAL1 = { id = "RIVAL1", index = 9, name = "RIVAL", baseMoney = 1, items = {},
                 trainers = { { id = "RIVAL1_1_FIX", name = "?", party = { { species = SPECIES, level = 5 } } } } },
    } }
  end
  local function goldGame(withTrainers)
    local game = newGame()
    game.generation = 2
    game.data = setmetatable({ items = GOLD_ITEMS, trainers = withTrainers and goldTrainers() or nil },
                             { __index = data })
    game.save.generation = 2
    game.save.player = { name = "BOB", id = 4321, money = 0 }
    return game
  end
  local function redGame()
    local game = newGame()
    game.save.money = 0
    return game
  end
  local function play(screenIn, msg)
    local rows = screenIn:medRows(msg)
    screenIn:playEvents(rows)
    return rows
  end
  local function idsOf(list)
    local out = {}
    for i, m in ipairs(list or {}) do out[i] = m.id end
    return table.concat(out, ",")
  end
  local seq = 100
  local function ev(sc, fields)
    seq = seq + 1
    fields.battle, fields.seq = "cb1", seq
    return sc:onBattleEvent(fields)
  end
  -- ANN's screen on seat 1 (the host), a bench monster behind her lead; the
  -- game is Red or Gold.
  local function seatScreen(gen)
    local slots = npcSlots()
    slots[1].party[2] = mon(60, 35)
    slots[1].party[2].moves = { { id = "FIX_SCRATCH", pp = 1 } }
    local sc = screen({ slots = slots, mine = 1, host = true, mode = "coop_npc", selfId = "ann" })
    if gen == 2 then
      sc.game = goldGame()
      sc.gen2Mediated = true
    else
      sc.game = redGame()
    end
    eq(sc:uploadMediated(), true, "wave 3: the upload goes out (gen " .. gen .. ")")
    sc.mediated = true
    sc.medSlots = { [0] = 1, [1] = 2, [2] = 3, [3] = 4 }
    sc.medFields = { [1] = 0, [2] = 1, [3] = 2, [4] = 3 }
    seq = seq + 1000
    return sc, slots
  end
  local COPIED = { { id = "FIX_EMBERISH", pp = 5, maxPp = 5 } }

  -- ------- the Gold picker for the referee's wave-2 ids, by their own names
  do
    local byId = {}
    for id = 102, 105 do byId[id] = Effects2.NAMES[id] end
    eq(byId[102], "EFFECT_SLEEP_TALK", "Gold picker: the referee's 102 is SLEEP TALK")
    eq(byId[103], "EFFECT_LOCK_ON", "Gold picker: ...103 LOCK-ON")
    eq(byId[104], "EFFECT_SAFEGUARD", "Gold picker: ...104 SAFEGUARD")
    eq(byId[105], "EFFECT_TOXIC", "Gold picker: ...105 TOXIC")
    local moves = {}
    for id, name in pairs(byId) do moves["MOVE_" .. id] = { power = 0, effect = name } end
    local picker = setmetatable({ game = { generation = 2, data = { moves = moves } } },
                                { __index = CoopBattle })
    local function aims(id) return picker:needsTarget({ id = "MOVE_" .. id }) end
    eq(aims(103), true, "Gold picker: LOCK-ON asks whom (its checkhit is on a foe)")
    eq(aims(105), true, "Gold picker: TOXIC asks whom")
    eq(aims(104), false, "Gold picker: SAFEGUARD is the user's side, aimed at nobody")
    eq(aims(102), true,
       "Gold picker: SLEEP TALK asks, as METRONOME does -- the referee aims the called move at the chosen seat")
    eq(CoopBattle.SELF_EFFECTS2.EFFECT_SAFEGUARD, true, "Gold picker: SAFEGUARD is the table's one entry")
  end

  -- ------- the Gold picker for the referee's wave-4 ids (R2d), each pinned by
  -- its own number and name: pokecrystal data/moves/effects.asm -- a script
  -- that runs `checkhit` or reads the foe it was used on asks whom; one that
  -- acts on the user, the user's side, the foe's side or everybody does not.
  do
    local AIMED = {
      [133] = "EFFECT_ATTRACT", [136] = "EFFECT_CONVERSION2", [139] = "EFFECT_ENCORE",
      [140] = "EFFECT_FORESIGHT", [142] = "EFFECT_MEAN_LOOK", [143] = "EFFECT_NIGHTMARE",
      [144] = "EFFECT_PAIN_SPLIT", [146] = "EFFECT_PSYCH_UP", [148] = "EFFECT_SKETCH",
      [150] = "EFFECT_SPITE", [152] = "EFFECT_SWAGGER", [155] = "EFFECT_SP_DEF_DOWN",
      [156] = "EFFECT_SP_DEF_DOWN_2",
    }
    local UNAIMED = {
      [134] = "EFFECT_BATON_PASS", [135] = "EFFECT_BELLY_DRUM", [138] = "EFFECT_DESTINY_BOND",
      [141] = "EFFECT_HEAL_BELL", [145] = "EFFECT_PERISH_SONG", [149] = "EFFECT_SPIKES",
      [151] = "EFFECT_SP_DEF_UP_2", [153] = "EFFECT_TELEPORT", [154] = "EFFECT_SP_DEF_UP",
    }
    local moves = {}
    for _, list in ipairs({ AIMED, UNAIMED }) do
      for id, name in pairs(list) do
        eq(Effects2.NAMES[id], name, "Gold picker (wave 4): the referee's " .. id .. " is " .. name)
        moves["MOVE_" .. id] = { power = 0, effect = name }
      end
    end
    moves.MOVE_137 = { power = 0, effect = "EFFECT_CURSE" }
    eq(Effects2.NAMES[137], "EFFECT_CURSE", "Gold picker (wave 4): the referee's 137 is EFFECT_CURSE")
    local picker = setmetatable({ game = { generation = 2, data = { moves = moves } } },
                                { __index = CoopBattle })
    for id, name in pairs(AIMED) do
      eq(picker:needsTarget({ id = "MOVE_" .. id }), true,
         "Gold picker (wave 4): " .. name .. " (" .. id .. ") asks whom")
      eq(CoopBattle.SELF_EFFECTS2[name], nil, "Gold picker (wave 4): " .. name .. " is off the self table")
    end
    for id, name in pairs(UNAIMED) do
      eq(picker:needsTarget({ id = "MOVE_" .. id }), false,
         "Gold picker (wave 4): " .. name .. " (" .. id .. ") is aimed at nobody")
    end
    -- CURSE (137): the user's type decides (BattleCommand_Curse `.ghost`); a
    -- seat this picker cannot read keeps the picker.
    eq(picker:needsTarget({ id = "MOVE_137" }), true,
       "Gold picker (wave 4): CURSE with no readable user asks whom (the safe side)")
  end

  -- ------- the Transform overlay through a learn
  do
    -- Red: pokered LearnMove copies the party's list over the battle monster's.
    local sc, slots = seatScreen(1)
    local lead = slots[1].party[1]
    sc.medMoveList = COPIED
    lead.moves[#lead.moves + 1] = { id = "FIX_CUT", pp = 30 }
    eq(sc:syncFightMoves(lead), true, "learn under Transform (Red co-op): the learn goes to the referee")
    eq(sc.medMoveList, nil, "learn under Transform (Red co-op): ...and the overlay goes with LearnMove's copy")
    eq(idsOf(sc:liveMoves()), "FIX_TACKLE,FIX_CUT", "learn under Transform (Red co-op): FIGHT reads its own list")
    -- A level-up that taught nothing resends the list unchanged: no LearnMove.
    sc.medMoveList = COPIED
    eq(sc:syncFightMoves(lead, true), true, "level-up under Transform (Red co-op): the level goes to the referee")
    eq(sc.medMoveList, COPIED, "level-up under Transform (Red co-op): ...and the overlay stays up")

    -- Gold: LearnMove skips the copy under SUBSTATUS_TRANSFORMED.
    local gs, gslots = seatScreen(2)
    local glead = gslots[1].party[1]
    gs.medMoveList = COPIED
    glead.moves[#glead.moves + 1] = { id = "FIX_CUT", pp = 30 }
    eq(gs:syncFightMoves(glead), true, "learn under Transform (Gold co-op): the learn goes to the referee")
    eq(gs.medMoveList, COPIED, "learn under Transform (Gold co-op): the overlay stays -- the referee fights on with the copies")
    eq(idsOf(gs.medMine[1].moves), "FIX_TACKLE,FIX_CUT", "learn under Transform (Gold co-op): ...while the sheet learns")
  end

  -- ------- the party list behind a faint or a switch-out (Gold's MYSTERYBERRY)
  do
    -- The faint: the overlay goes, and the list stated behind it is the
    -- fallen monster's own.
    local sc, slots = seatScreen(2)
    local lead = slots[1].party[1]
    lead.moves[1].pp = 0
    ev(sc, { t = "moves", slot = 0, side = "a", moves = COPIED })
    eq(sc.medMoveList and sc.medMoveList[1].id, "FIX_EMBERISH", "overlay (co-op): Transform's copies are up")
    ev(sc, { t = "faint", slot = 0, side = "a", text = SPECIES_NAME, amount = 1 })
    eq(sc.medMoveList, nil, "overlay (co-op): the faint ends it")
    ev(sc, { t = "moves", slot = 0, side = "a", mon = 0, moves = { { id = "FIX_TACKLE", pp = 5, maxPp = 20 } } })
    eq(lead.moves[1].pp, 5, "MYSTERYBERRY under Transform (co-op faint): the restored PP reaches the party monster")
    eq(sc.medMoveList, nil, "MYSTERYBERRY under Transform (co-op faint): ...and is no new overlay")

    -- The switch-out, with the newcomer already standing: the list names the
    -- monster that left, and lands on it rather than on the newcomer.
    sc, slots = seatScreen(2)
    lead = slots[1].party[1]
    local bench = slots[1].party[2]
    lead.moves[1].pp = 0
    ev(sc, { t = "moves", slot = 0, side = "a", moves = COPIED })
    play(sc, { battle = "cb1", seq = 1, t = "send", slot = 0, side = "a", mon = 1, text = SPECIES_NAME, hp = 60 })
    sc.medMoveList = nil
    check(sc:mySlot().battler and sc:mySlot().battler.mon == bench, "switch-out (co-op): the bench monster stands")
    ev(sc, { t = "moves", slot = 0, side = "a", mon = 0, moves = { { id = "FIX_TACKLE", pp = 5, maxPp = 20 } } })
    eq(lead.moves[1].pp, 5, "MYSTERYBERRY under Transform (co-op switch-out): the PP lands on the monster that left")
    eq(bench.moves[1].pp, 1, "MYSTERYBERRY under Transform (co-op switch-out): ...never on the newcomer")

    -- A benched monster's list while the one standing wears an overlay.
    sc, slots = seatScreen(2)
    ev(sc, { t = "moves", slot = 0, side = "a", moves = COPIED })
    ev(sc, { t = "moves", slot = 0, side = "a", mon = 1, moves = { { id = "FIX_SCRATCH", pp = 9, maxPp = 35 } } })
    eq(slots[1].party[2].moves[1].pp, 9, "overlay (co-op): a benched monster's list writes that monster")
    eq(sc.medMoveList and sc.medMoveList[1].id, "FIX_EMBERISH", "overlay (co-op): ...and the overlay stands")
    -- The wearer's own spend still refreshes it.
    ev(sc, { t = "moves", slot = 0, side = "a", mon = 0, moves = { { id = "FIX_EMBERISH", pp = 4, maxPp = 5 } } })
    eq(sc.medMoveList and sc.medMoveList[1].pp, 4, "overlay (co-op): the wearer's spend refreshes the overlay")
    eq(slots[1].party[1].moves[1].id, "FIX_TACKLE", "overlay (co-op): ...and never writes its own moves")
  end

  -- ------- Red Pay Day: what the referee states on a run, and nothing more
  do
    local function outcome(sc, fields)
      fields.battle, fields.outcome = "cb1", "win"
      sc:onBattleOutcome(fields)
    end
    -- Our TELEPORT: side a in `losers`, still paid.
    local fled = screen({ slots = npcSlots(), mine = 1, host = true, mode = "coop_npc", selfId = "ann" })
    fled.mediated, fled.game.save.money = true, 0
    outcome(fled, { winners = { "npc1" }, losers = { "ann", "bob" }, reason = "run", payDay = 30 })
    eq(fled.game.save.money, 30, "Pay Day (co-op, Red escape): a TELEPORT of ours still pays side a")
    -- The player's RUN: no pot stated, nothing paid.
    local ran = screen({ slots = npcSlots(), mine = 1, host = true, mode = "coop_npc", selfId = "ann" })
    ran.mediated, ran.game.save.money = true, 0
    outcome(ran, { winners = { "npc1" }, losers = { "ann", "bob" }, reason = "run" })
    eq(ran.game.save.money, 0, "Pay Day (co-op, Red RUN): an outcome stating no pot pays nothing")
    -- Gold: a foe's flight is a DRAW too, even with side a named the winner.
    local goldRun = seatScreen(2)
    outcome(goldRun, { winners = { "ann", "bob" }, losers = { "npc1" }, reason = "run", payDay = 30 })
    eq(goldRun.game.save.player.money, 0, "Pay Day (co-op, Gold escape): a run pays nothing, whoever is the winner")
  end

  -- ------- K14: the host describes the trainer's and the wild's at BASE_HAPPINESS
  do
    local sc, slots = seatScreen(2)
    local npcUp, ownUp
    for _, msg in ipairs(sc.sent) do
      if msg.type == Wire.BATTLE_PARTY and msg.payload.side == "b" then npcUp = msg.payload end
      if msg.type == Wire.BATTLE_PARTY and msg.payload.side == "a" then ownUp = msg.payload end
    end
    eq(npcUp and npcUp.mons[1].happiness, 70, "K14 foe (co-op): the trainer's sheet is at BASE_HAPPINESS")
    local fond = slots[3].party[1]
    fond.happiness = 255
    local again = sc:npcMons()
    eq(again and again[1].happiness, 70, "K14 foe (co-op): ...whatever its engine record says")
    slots[1].party[1].happiness = 222
    local mine = Mediated.snapshotMons(sc.game, slots[1].party, { own = true })
    eq(mine[1].happiness, 222, "K14 own (co-op): our own monster keeps its own")
    check(ownUp ~= nil, "K14 own (co-op): the own upload went out")
    sc.wildCatchMon = fond
    sc.wildParty = nil
    eq(sc:wildMons()[1].happiness, 70, "K14 foe (co-op): a wild seat's sheet too")
  end

  -- ------- an invite joiner's Gold trainer
  do
    -- The host's half: the engine's record (World:startScriptedBattle's
    -- shape: numeric class, its constant, the member constant, no `id`).
    local walkedInto = { class = 7, classId = "FIXCLASS", memberId = "FIX1", name = "FIX CLASS ABE",
                         trainerName = "ABE", className = "FIX CLASS" }
    local host = goldGame(true)
    eq(Coop.trainerToken2(host, walkedInto), "7-FIX1", "Gold trainer: the field names the class and member")
    eq(Coop.trainerToken2(host, { classId = "FIXCLASS", memberId = "FIX2" }), "7-FIX2",
       "Gold trainer: ...the class row's index when the record names only the constant")
    eq(Coop.trainerToken2(host, { class = 7 }), nil, "Gold trainer: no member, no token")
    eq(Coop.trainerToken2(host, { class = 7, memberId = "BAD-ID" }), nil,
       "Gold trainer: a member that would break the token's split names nobody")
    eq(Coop.trainerToken2(host, { class = 7, memberId = string.rep("M", 39) }), nil,
       "Gold trainer: ...nor one past Wire.id's 40 characters (the joiner fights faceless, as before)")
    -- buildField on Gold, through the real assembler (parties packed as given).
    local realPack, realUnpack = CoopBattle.packParty, CoopBattle.unpackParty
    CoopBattle.packParty = function(party) return party end
    CoopBattle.unpackParty = function(_, packed) return packed end
    local assembler = setmetatable({}, { __index = Coop })
    local battle = {
      parties = { ann = { mon(60, 40) }, bob = { mon(60, 30) } },
      plan = { hostId = "ann", label = "FIX CLASS",
               allies = { { id = "ann", name = "ANN" }, { id = "bob", name = "BOB" } },
               engine = { enemyParty = { mon(50, 20), mon(50, 18) }, trainer = walkedInto } },
    }
    local field = assembler:buildField(host, battle, battle.plan.allies)
    eq(field and field.trainer, "7-FIX1", "Gold trainer: buildField sends the token")
    local wired = field and Wire.coopField(field)
    eq(wired and wired.trainer, "7-FIX1", "Gold trainer: ...which the wire keeps (Wire.id-shaped)")

    -- The joiner's half: its own record, off its own data.
    local joiner = goldGame(true)
    local record = Coop.trainerFor(joiner, wired, nil)
    check(type(record) == "table", "Gold trainer: a joiner who never met the trainer resolves it")
    record = record or {}
    eq(record.class, 7, "Gold trainer: ...its class number")
    eq(record.classId, "FIXCLASS", "Gold trainer: ...its class constant (the music ladder's key)")
    eq(record.memberId, "FIX1", "Gold trainer: ...its member")
    eq(record.name, "FIX CLASS ABE", "Gold trainer: ...named as the walk-in's is (class, then name)")
    eq(record.trainerName, "ABE", "Gold trainer: ...its bare name")
    eq(record.baseMoney, 9, "Gold trainer: ...the class's reward byte")
    eq(record.items and record.items[1], "FIX_POTION", "Gold trainer: ...its TRNATTR items")
    eq(record.roster and record.roster[1] and record.roster[1].item, "NUGGET", "Gold trainer: ...the member's party rows")
    eq(record.id, nil, "Gold trainer: ...and no Gen 1 id, as the walk-in's record has none")
    check(record.items ~= joiner.data.trainers.classes.FIXCLASS.items,
          "Gold trainer: the item list is a copy (Trainers.lookup), not the class record's")
    local own = { classId = "FIXCLASS" }
    eq(Coop.trainerFor(joiner, wired, { trainer = own }), own, "Gold trainer: the walk-in keeps its own record")
    eq(Coop.trainerFor(joiner, { trainer = "7-NOPE" }, nil), nil, "Gold trainer: a member this build lacks names nobody")
    eq(Coop.trainerFor(joiner, { trainer = "8-FIX1" }, nil), nil, "Gold trainer: ...nor a class it lacks")
    eq(Coop.trainerFor(joiner, { trainer = "classes" }, nil), nil,
       "Gold trainer: a token naming a key of the class table is no trainer (never the Gen 1 lookup)")
    eq(Coop.trainerFor(joiner, { trainer = "FIX1" }, nil), nil, "Gold trainer: ...nor a bare member")
    eq(Coop.trainerFor(goldGame(false), wired, nil), nil, "Gold trainer: a build with no trainer table names nobody")
    -- A rival is this player's own rival's name (PlaceEnemysName).
    joiner.save.rival = { name = "SILVO" }
    local rival = Coop.trainerFor(joiner, { trainer = "9-RIVAL1_1_FIX" }, nil) or {}
    eq(rival.name, "SILVO", "Gold trainer: a rival is named as this player's cart names its rival")
    joiner.save.rival = nil
    eq((Coop.trainerFor(joiner, { trainer = "9-RIVAL1_1_FIX" }, nil) or {}).name, "???",
       "Gold trainer: ...or ??? before the rival was named")

    -- startBattle on the joiner: the record and its class reach the screen.
    local realNew = CoopBattle.new
    local handed
    CoopBattle.new = function(_, opts) handed = opts; return nil, "stub" end
    local coop = setmetatable({
      battle = { plan = { hostId = "ann", allies = battle.plan.allies, id = "cb1" }, ready = false },
      party = { isSelf = function(_, id) return id == "bob" end, selfId = "bob" },
      transport = { send = function() end },
      ui = {},
      abandon = function() return false end,
    }, { __index = Coop })
    joiner.save.party = { mon(60, 30) }
    coop:startBattle(joiner, wired)
    CoopBattle.new = realNew
    CoopBattle.packParty, CoopBattle.unpackParty = realPack, realUnpack
    eq(handed and handed.trainer and handed.trainer.memberId, "FIX1",
       "Gold trainer (joiner's startBattle): the screen is handed the record")
    eq(handed and handed.oppClass, "FIXCLASS",
       "Gold trainer (joiner's startBattle): ...and the class the walk-in's battle names (the Client's Gold alias)")

    -- What the joiner's screen does with it.
    local bobT, bobSlots = seatScreen(2)
    bobT.mine, bobT.selfId, bobT.host = 2, "bob", false
    bobT.trainer, bobT.oppClass = record, "FIXCLASS"
    local foeFigure = bobT:battlefieldFoeHumans()[1]
    eq(foeFigure and foeFigure.name, "FIX CLASS ABE", "Gold trainer (joiner): the trainer stands on the field by name")
    check(bobT:trainerIntroName():find("FIX CLASS", 1, true) == 1,
          "Gold trainer (joiner): ...and the intro line names the trainer's record, not the seat's label")
    eq(table.concat(bobT:trainerItems2(), ","), "NUGGET",
       "Gold trainer (joiner): ...its own data vouches for the item the trainer's party row holds")
    eq(bobT:musicKind(), "trainer", "Gold trainer (joiner): ...a trainer fight's theme, not the two-parties cue")
    local noRecord = seatScreen(2)
    noRecord.mine = 2
    eq(noRecord:musicKind(), "link", "Gold trainer (joiner): before the lookup it was the two-parties cue")
    -- The song: the class and member reach Gold's PlayBattleMusic ladder.
    local savedMusic = package.loaded["src.battle.gen2.BattleMusic"]
    local asked
    package.loaded["src.battle.gen2.BattleMusic"] = {
      battleSong = function(opts) asked = opts; return "SONG" end,
      victorySong = function() return "WIN" end,
      isKanto = function() return false end,
    }
    local song = Gen.gen2BattleSong(bobT.game, { kind = bobT:musicKind(), mode = bobT.mode,
                                                 trainer = bobT.trainer, oppClass = bobT.oppClass })
    package.loaded["src.battle.gen2.BattleMusic"] = savedMusic
    eq(song, "SONG", "Gold trainer (joiner): the trainer's song is asked for")
    eq(asked and asked.class, "FIXCLASS", "Gold trainer (joiner): ...by its class")
    eq(asked and asked.member, "FIX1", "Gold trainer (joiner): ...and member (RIVAL2's ladder reads it)")
    check(bobSlots ~= nil, "Gold trainer (joiner): the screen was built")
  end
end

-- ------------------------------------------------------------------
-- 17. closing the Red / Gold referee gaps, wave 4 (task C2b)
-- ------------------------------------------------------------------
--
-- Gold's SKETCH written onto our seat's party monster; Red's MIMIC slot PP
-- and its pick off the target's list; a TOXIC on our seat saved as PSN;
-- Gold's CURSE picker by the user's type; the trainer's whole name; Gold's
-- weather off its lines; FIGHT with no move list during a Gold Bide and a
-- Red monster asleep.  Move rows and numbers are invented.

do
  local Gen = need("Gen")
  local Effects2 = need("BattleSim2/Effects")
  -- The fixture's moves, plus the few this section needs.
  local MOVES4 = setmetatable({
    FIX_SKETCH = { name = "SKETCH", power = 0, accuracy = 100, type = "NORMAL", pp = 1,
                   effect = "EFFECT_SKETCH" },
    FIX_SPORE = { name = "SPORE", power = 0, accuracy = 100, type = "NORMAL", pp = 13,
                  effect = "EFFECT_SLEEP" },
    MIMIC = { name = "MIMIC", power = 0, accuracy = 100, type = "NORMAL", pp = 10,
              effect = "MIMIC_EFFECT" },
    FIX_BIDE = { name = "BIDE", power = 0, accuracy = 100, type = "NORMAL", pp = 9,
                 effect = "EFFECT_BIDE" },
    FIX_CURSE = { name = "CURSE", power = 0, accuracy = 100, type = "NORMAL", pp = 10,
                  effect = "EFFECT_CURSE" },
  }, { __index = data.moves })
  local data4 = setmetatable({ moves = MOVES4 }, { __index = data })
  local seq = 5000
  local function ev(sc, fields)
    seq = seq + 1
    fields.battle, fields.seq = "cb1", seq
    return sc:onBattleEvent(fields)
  end
  local function play(sc, msg)
    local rows = sc:medRows(msg)
    sc:playEvents(rows)
    return rows
  end
  local function inputOf(...)
    local pressed = {}
    for _, k in ipairs({ ... }) do pressed[k] = true end
    return { wasPressed = function(_, k)
      if pressed[k] then pressed[k] = nil; return true end
      return false
    end, isDown = function() return false end }
  end
  local function choices(sc)
    local out = {}
    for _, m in ipairs(sc.sent) do
      if m.type == Wire.BATTLE_CHOICE then out[#out + 1] = m.payload end
    end
    return out
  end
  -- ANN's seat (1) in a coop_npc fight on Red or Gold, her lead holding `moves`.
  local function seat4(gen, moves, mode)
    local slots = npcSlots()
    slots[1].party[1].moves = moves
    local game = newGame()
    game.data = data4
    game.save.money = 0
    if gen == 2 then
      game.generation = 2
      game.save.generation = 2
      game.save.player = { name = "ANN", id = 4321, money = 0 }
    end
    -- Built on the fixture's Red field (CoopField takes no Gold game), then
    -- handed this section's game, as section 16's `seatScreen` does.
    local sc = screen({ slots = slots, mine = 1, host = true, mode = mode or "coop_npc",
                        selfId = "ann" })
    sc.game = game
    if gen == 2 then sc.gen2Mediated = true end
    eq(sc:uploadMediated(), true, "wave 4: the upload goes out (gen " .. gen .. ")")
    sc.mediated = true
    sc.medSlots = { [0] = 1, [1] = 2, [2] = 3, [3] = 4 }
    sc.medFields = { [1] = 0, [2] = 1, [3] = 2, [4] = 3 }
    return sc, slots, slots[1].party[1]
  end

  -- ------- SKETCH, written home (Gold co-op)
  do
    local sc, _, lead = seat4(2, { { id = "FIX_TACKLE", pp = 20, maxPp = 35 },
                                   { id = "FIX_SKETCH", pp = 1, maxPp = 1, ppUps = 1 } })
    ev(sc, { t = "moves", slot = 0, side = "a", mon = 0,
             moves = { { id = "FIX_TACKLE", pp = 20 }, { id = "FIX_SKETCH", pp = 0 } } })
    eq(lead.moves[2].id, "FIX_SKETCH", "SKETCH home (co-op): a PP spend is no sketch")
    eq(lead.moves[2].pp, 0, "SKETCH home (co-op): ...its spend lands as ever")
    ev(sc, { t = "moves", slot = 0, side = "a", mon = 0,
             moves = { { id = "FIX_TACKLE", pp = 20 }, { id = "FIX_SPORE", pp = 13, maxPp = 13 } } })
    eq(lead.moves[2].id, "FIX_SPORE", "SKETCH home (co-op): our seat's party monster takes the sketched move")
    eq(lead.moves[2].pp, 13, "SKETCH home (co-op): ...at the move's base PP")
    eq(lead.moves[2].maxPp, 13, "SKETCH home (co-op): ...out of its base")
    eq(lead.moves[2].ppUps, nil, "SKETCH home (co-op): ...with the PP Ups gone")
    eq(sc:liveMoves()[2].id, "FIX_SPORE", "SKETCH home (co-op): FIGHT lists it")
    eq(sc.medMine[1].moves[2].id, "FIX_SPORE", "SKETCH home (co-op): the uploaded sheet follows (no learn read later)")
    -- Under a TRANSFORM overlay a spend is not written home.
    local ws, _, wlead = seat4(2, { { id = "FIX_TACKLE", pp = 20, maxPp = 35 },
                                    { id = "FIX_SKETCH", pp = 1, maxPp = 1 } })
    ev(ws, { t = "moves", slot = 0, side = "a",
             moves = { { id = "FIX_TACKLE", pp = 5 }, { id = "FIX_SCRATCH", pp = 5 } } })
    ev(ws, { t = "moves", slot = 0, side = "a", mon = 0,
             moves = { { id = "FIX_TACKLE", pp = 4 }, { id = "FIX_SCRATCH", pp = 5 } } })
    eq(wlead.moves[2].id, "FIX_SKETCH", "SKETCH home (co-op): a TRANSFORM overlay is never written home")
    eq(wlead.moves[1].pp, 20, "SKETCH home (co-op): ...nor its spends")
    -- The referee's TRANSFORMed sketch (BattleSim2 Turn `_sketch`): the copies
    -- as an overlay, then the party list it put aside, behind the faint.
    local ts, _, tlead = seat4(2, { { id = "FIX_TACKLE", pp = 20, maxPp = 35 },
                                    { id = "FIX_SKETCH", pp = 1, maxPp = 1 } })
    ev(ts, { t = "moves", slot = 0, side = "a",
             moves = { { id = "FIX_SCRATCH", pp = 5 }, { id = "FIX_SPORE", pp = 13 } } })
    eq(tlead.moves[2].id, "FIX_SKETCH", "SKETCH home (co-op, TRANSFORMed): the overlay writes nothing")
    ev(ts, { t = "faint", slot = 0, side = "a", text = SPECIES_NAME, amount = 0 })
    ev(ts, { t = "moves", slot = 0, side = "a", mon = 0,
             moves = { { id = "FIX_TACKLE", pp = 20 }, { id = "FIX_SPORE", pp = 13, maxPp = 13 } } })
    eq(tlead.moves[2].id, "FIX_SPORE", "SKETCH home (co-op, TRANSFORMed): the party list behind the faint is written home")
    -- A fight between players writes nothing home.
    local ps, _, plead = seat4(2, { { id = "FIX_TACKLE", pp = 20, maxPp = 35 },
                                    { id = "FIX_SKETCH", pp = 1, maxPp = 1 } }, "coop_pvp")
    ev(ps, { t = "moves", slot = 0, side = "a", mon = 0,
             moves = { { id = "FIX_TACKLE", pp = 20 }, { id = "FIX_SPORE", pp = 13 } } })
    eq(plead.moves[2].id, "FIX_SKETCH", "SKETCH home (coop_pvp): nothing written home")
  end

  -- ------- Red's MIMIC: the slot's PP is MIMIC's own (co-op)
  do
    local sc, _, lead = seat4(1, { { id = "MIMIC", pp = 10 }, { id = "FIX_TACKLE", pp = 20 } })
    ev(sc, { t = "moves", slot = 0, side = "a", mon = 0,
             moves = { { id = "MIMIC", pp = 9 }, { id = "FIX_TACKLE", pp = 20 } } })
    eq(lead.moves[1].pp, 9, "MIMIC PP (Red co-op): MIMIC's own spend")
    ev(sc, { t = "moves", slot = 0, side = "a",
             moves = { { id = "FIX_SCRATCH", pp = 9 }, { id = "FIX_TACKLE", pp = 20 } } })
    check(sc.medOverlayMimic == true, "MIMIC PP (Red co-op): the overlay is read as a MIMIC")
    ev(sc, { t = "moves", slot = 0, side = "a", mon = 0,
             moves = { { id = "FIX_SCRATCH", pp = 8 }, { id = "FIX_TACKLE", pp = 20 } } })
    eq(lead.moves[1].id, "MIMIC", "MIMIC PP (Red co-op): the party keeps MIMIC")
    eq(lead.moves[1].pp, 8, "MIMIC PP (Red co-op): ...and pays the mimicked move's PP (DecrementPP by slot)")
    eq(sc:liveMoves()[1].id, "FIX_SCRATCH", "MIMIC PP (Red co-op): FIGHT lists the mimicked move")
    -- TRANSFORM: none of it.
    ev(sc, { t = "moves", slot = 0, side = "a",
             moves = { { id = "FIX_SCRATCH", pp = 5 }, { id = "FIX_SCRATCH", pp = 5 } } })
    check(sc.medOverlayMimic == false, "MIMIC PP (Red co-op): a TRANSFORM is no MIMIC")
    ev(sc, { t = "moves", slot = 0, side = "a", mon = 0,
             moves = { { id = "FIX_SCRATCH", pp = 4 }, { id = "FIX_SCRATCH", pp = 5 } } })
    eq(lead.moves[1].pp, 8, "MIMIC PP (Red co-op): a spend under TRANSFORM leaves the party alone")
    -- Gold's party never pays (CheckMimicUsed).
    local gs, _, glead = seat4(2, { { id = "MIMIC", pp = 10, maxPp = 10 }, { id = "FIX_TACKLE", pp = 20, maxPp = 35 } })
    ev(gs, { t = "moves", slot = 0, side = "a",
             moves = { { id = "FIX_SCRATCH", pp = 5 }, { id = "FIX_TACKLE", pp = 20 } } })
    ev(gs, { t = "moves", slot = 0, side = "a", mon = 0,
             moves = { { id = "FIX_SCRATCH", pp = 4 }, { id = "FIX_TACKLE", pp = 20 } } })
    eq(glead.moves[1].pp, 10, "MIMIC PP (Gold co-op): the party's MIMIC pays nothing (CheckMimicUsed)")
    ev(gs, { t = "moves", slot = 0, side = "a", mon = 0,
             moves = { { id = "FIX_SCRATCH", pp = 4 }, { id = "FIX_TACKLE", pp = 19 } } })
    eq(glead.moves[2].pp, 19, "MIMIC PP (Gold co-op): ...while its other slots' spends still reach the party")
    eq(glead.moves[1].pp, 10, "MIMIC PP (Gold co-op): ...and MIMIC's stays")
  end

  -- ------- Red's MIMIC pick (co-op)
  do
    local sc, slots = seat4(1, { { id = "MIMIC", pp = 10 }, { id = "FIX_TACKLE", pp = 20 } })
    sc.phase, sc.moveIndex = "move", 1
    sc:updateMove(inputOf("a"))
    eq(sc.phase, "target", "MIMIC pick (co-op): MIMIC asks whom first")
    local targets = sc:targetChoices()
    sc.targetIndex = 1
    sc:updateTarget(inputOf("a"))
    eq(sc.phase, "mimic", "MIMIC pick (co-op): ...then which of its moves")
    eq(#choices(sc), 0, "MIMIC pick (co-op): ...with nothing sent yet")
    local rows = sc:mimicRows()
    local foeMoves = sc:seatMoveList(targets[1].index)
    eq(#rows, #foeMoves, "MIMIC pick (co-op): the list is the target's moves")
    sc:updateMimic(inputOf("b"))
    eq(sc.phase, "target", "MIMIC pick (co-op): B goes back to the target")
    sc:updateTarget(inputOf("a"))
    sc:updateMimic(inputOf("a"))
    local sent = choices(sc)
    eq(#sent, 1, "MIMIC pick (co-op): the pick files the choice")
    eq(sent[1] and sent[1].mimic, 0, "MIMIC pick (co-op): ...its first row, 0-based")
    eq(sent[1] and sent[1].move, 0, "MIMIC pick (co-op): ...on MIMIC's slot")
    eq(sent[1] and sent[1].target, sc:medFieldOf(targets[1].index), "MIMIC pick (co-op): ...at the target")
    -- The target's own TRANSFORM list, once the referee states one.
    local ms = seat4(1, { { id = "MIMIC", pp = 10 } })
    ev(ms, { t = "moves", slot = 2, side = "b", moves = { { id = "FIX_SCRATCH", pp = 5 } } })
    local at = ms.medSlots[2]
    eq(ms:seatMoveList(at)[1].id, "FIX_SCRATCH", "MIMIC pick (co-op): a foe's TRANSFORM list is what it holds")
    ev(ms, { t = "send", slot = 2, side = "b", mon = 1, text = SPECIES_NAME, hp = 50 })
    eq(ms.medSeatMoves[at], nil, "MIMIC pick (co-op): ...until another monster comes out there")
    -- A fight between players never asks (a link battle's random pick).
    local pv = seat4(1, { { id = "MIMIC", pp = 10 } }, "coop_pvp")
    eq(pv:asksMimic({ id = "MIMIC" }, 3), false, "MIMIC pick (coop_pvp): no pick")
    local gd = seat4(2, { { id = "MIMIC", pp = 10, maxPp = 10 } })
    eq(gd:asksMimic({ id = "MIMIC" }, 3), false, "MIMIC pick (Gold co-op): no pick")
  end

  -- ------- a TOXIC on our seat is saved as PSN
  do
    for _, gen in ipairs({ 1, 2 }) do
      local sc, slots, lead = seat4(gen, { { id = "FIX_TACKLE", pp = 20, maxPp = 35 } })
      play(sc, { battle = "cb1", seq = 1, t = "status", slot = 0, side = "a", status = "TOX" })
      eq(lead.status, "PSN", "TOX (co-op gen " .. gen .. "): our party monster holds PSN")
      play(sc, { battle = "cb1", seq = 2, t = "status", slot = 2, side = "b", status = "TOX" })
      local foe = sc.sim:slot(sc.medSlots[2])
      eq(foe and foe.battler and foe.battler.mon.status, "TOX", "TOX (co-op gen " .. gen .. "): a foe's seat keeps the referee's token")
    end
  end

  -- ------- Gold's CURSE: a Ghost asks whom, anything else does not
  do
    local function picker(types)
      return setmetatable({
        game = { generation = 2, data = { moves = MOVES4 } },
        mine = 1,
        sim = { slot = function() return { battler = { curTypes = types } } end },
      }, { __index = CoopBattle })
    end
    eq(picker({ "GHOST", "POISON" }):needsTarget({ id = "FIX_CURSE" }), true,
       "CURSE (Gold co-op): a Ghost's CURSE asks whom (BattleCommand_Curse .ghost)")
    eq(picker({ "NORMAL" }):needsTarget({ id = "FIX_CURSE" }), false,
       "CURSE (Gold co-op): anyone else's raises its own stats, aimed at nobody")
  end

  -- ------- the trainer's whole name (walk-in and joiner)
  do
    local walkIn = setmetatable({ trainer = { name = "YOUNGSTER JOEY" } }, { __index = CoopBattle })
    eq(walkIn:trainerIntroName(), "YOUNGSTER JOEY",
       "trainer name (co-op walk-in): the engine record's name whole, not cut at NAME_MAX")
    local longRed = setmetatable({ trainer = { name = "BIRD KEEPER" } }, { __index = CoopBattle })
    eq(longRed:trainerIntroName(), "BIRD KEEPER", "trainer name (co-op, Red): a class name past ten letters")
    -- The Gold joiner's own record (Coop.trainerRecord2) reads the same way.
    local jgame = newGame()
    jgame.generation = 2
    jgame.save.generation = 2
    jgame.data = setmetatable({ trainers = { classes = {
      FIXCLASS = { id = "FIXCLASS", index = 7, name = "FIX CLASS", baseMoney = 9,
                   attributes = { 0, 0, 9, 0, 0, 0, 0 }, items = {},
                   trainers = { { id = "FIX1", name = "ABERNATHY",
                                  party = { { species = SPECIES, level = 5 } } } } },
    } } }, { __index = data })
    local record = Coop.trainerRecord2(jgame, "7-FIX1")
    if record then
      local joiner = setmetatable({ trainer = record }, { __index = CoopBattle })
      eq(joiner:trainerIntroName(), record.name, "trainer name (Gold joiner): its own record's name, whole")
      check(#record.name > Config.NAME_MAX, "trainer name (Gold joiner): ...past the wire's ten")
    else
      check(true, "trainer name (Gold joiner): this build's Gold trainer module is absent")
    end
    -- No record: the field's NPC label.
    local sc = seat4(1, { { id = "FIX_TACKLE", pp = 20 } })
    sc.trainer = nil
    eq(sc:trainerIntroName(), "TRAINER", "trainer name (co-op): no record reads the NPC seat's label")
  end

  -- ------- Gold's weather off its lines (co-op)
  do
    local sc = seat4(2, { { id = "FIX_TACKLE", pp = 20, maxPp = 35 } })
    local rows = sc:medRows({ battle = "cb1", seq = 1, t = "msg", text = Effects2.WEATHER_LINES.sun.start })
    eq(rows[1] and rows[1].kind, "state3", "weather (Gold co-op): a weather line files a state row")
    eq(rows[1] and rows[1].value, "SUN", "weather (Gold co-op): ...naming the sky")
    eq(rows[2] and rows[2].text, Effects2.WEATHER_LINES.sun.start, "weather (Gold co-op): ...ahead of its line")
    sc:applyState3(rows[1])
    eq(sc.weatherShown, "SUN", "weather (Gold co-op): applied when its row plays")
    local ended = sc:medRows({ battle = "cb1", seq = 2, t = "msg", text = Effects2.WEATHER_LINES.sun.ended })
    sc:applyState3(ended[1])
    eq(sc.weatherShown, nil, "weather (Gold co-op): the end clears it")
    local red = seat4(1, { { id = "FIX_TACKLE", pp = 20 } })
    local redRows = red:medRows({ battle = "cb1", seq = 3, t = "msg", text = Effects2.WEATHER_LINES.sun.start })
    eq(redRows[1] and redRows[1].kind, "msg", "weather (Red co-op): a line is only a line")
  end

  -- ------- FIGHT with no move list (Gold Bide, Red asleep)
  do
    local sc, _, lead = seat4(2, { { id = "FIX_TACKLE", pp = 20, maxPp = 35 },
                                   { id = "FIX_BIDE", pp = 9, maxPp = 9 } })
    ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    local targets = sc:targetChoices()
    sc:commit({ slot = 1, move = 2, target = targets[1].index })
    check(sc.bideFiled == true, "Bide (Gold co-op): BIDE chosen")
    -- The first turn says only the used line (wave 5, pokecrystal StoreEnergy).
    ev(sc, { t = "msg", text = SPECIES_NAME .. " used BIDE!" })
    ev(sc, { t = "turn", amount = 2 })
    check(sc.bideLocked == true, "Bide (Gold co-op): the next turn is a Bide going on")
    lead.moves[2].pp = 0
    local before = #choices(sc)
    sc.phase, sc.commandIndex = "choose", 1
    sc:updateCommand(inputOf("a"))
    local sent = choices(sc)
    eq(#sent, before + 1, "Bide (Gold co-op): FIGHT files at once (.locked_in)")
    eq(sent[#sent] and sent[#sent].move, 1, "Bide (Gold co-op): ...the Bide's slot, past its PP")
    ev(sc, { t = "msg", text = SPECIES_NAME .. " unleashed energy!" })
    ev(sc, { t = "turn", amount = 3 })
    check(not sc.bideLocked, "Bide (Gold co-op): the release ends it")
    sc.phase, sc.commandIndex = "choose", 1
    sc:updateCommand(inputOf("a"))
    eq(sc.phase, "move", "Bide (Gold co-op): ...and FIGHT opens the move list again")

    local rs, _, rlead = seat4(1, { { id = "FIX_TACKLE", pp = 20 } })
    rlead.status = "SLP"
    rs.phase, rs.commandIndex = "choose", 1
    rs:updateCommand(inputOf("a"))
    local rsent = choices(rs)
    eq(#rsent, 1, "asleep (Red co-op): FIGHT files at once (MainInBattleLoop's SLP check)")
    eq(rsent[1] and rsent[1].move, 0, "asleep (Red co-op): ...the remembered slot")
    rlead.status = nil
    rs.phase, rs.commandIndex = "choose", 1
    rs:updateCommand(inputOf("a"))
    eq(rs.phase, "move", "asleep (Red co-op): awake, the move list")
  end
end

-- ------------------------------------------------------------------
-- wave 5 of docs/plans/gen12-referee-gaps-fix.md (C3): the co-op rows
-- ------------------------------------------------------------------
--
-- HEAL BELL onto the party; a fight between players fights copies and writes
-- nothing home (Red and Gold, as Gen 3); Gold's BATON PASS successor; a foe's
-- send-out in the cart's words; the escape said once; Red's Bide lock-in.
-- Every move row, name and number is invented.

do
  local Gen = need("Gen")
  local Coop = need("Coop")
  local MOVES5 = setmetatable({
    FIX_BATON = { name = "BATON PASS", power = 0, accuracy = 100, type = "NORMAL", pp = 40,
                  effect = "EFFECT_BATON_PASS" },
    FIX_BIDE = { name = "BIDE", power = 0, accuracy = 100, type = "NORMAL", pp = 10,
                 effect = "BIDE_EFFECT" },
    FIX_MIRROR = { name = "MIRROR MOVE", power = 0, accuracy = 100, type = "NORMAL", pp = 20,
                   effect = "MIRROR_MOVE_EFFECT" },
  }, { __index = data.moves })
  local data5 = setmetatable({ moves = MOVES5 }, { __index = data })
  local seq = 9000
  local function ev(sc, fields)
    seq = seq + 1
    fields.battle, fields.seq = "cb1", seq
    return sc:onBattleEvent(fields)
  end
  local function inputOf(...)
    local pressed = {}
    for _, k in ipairs({ ... }) do pressed[k] = true end
    return { wasPressed = function(_, k)
      if pressed[k] then pressed[k] = nil; return true end
      return false
    end, isDown = function() return false end }
  end
  local function choices(sc)
    local out = {}
    for _, m in ipairs(sc.sent) do
      if m.type == Wire.BATTLE_CHOICE then out[#out + 1] = m.payload end
    end
    return out
  end
  local function texts(sc, rows)
    local out = {}
    for _, m in ipairs(sc.messages or {}) do
      if type(m) == "string" then out[#out + 1] = m
      elseif type(m) == "table" and type(m.text) == "string" then out[#out + 1] = m.text end
    end
    for _, r in ipairs(rows or sc.medPending or {}) do
      if type(r) == "table" and r.kind == "msg" and type(r.text) == "string" then out[#out + 1] = r.text end
    end
    return out
  end
  local function count(list, text)
    local n = 0
    for _, t in ipairs(list) do if t == text then n = n + 1 end end
    return n
  end
  -- ANN's seat (1) on Red or Gold, her party `party` (the save's), in `mode`.
  local function seat5(gen, party, mode, slots)
    slots = slots or npcSlots()
    if party then slots[1].party = party end
    local game = newGame()
    game.data = data5
    game.save.money = 0
    game.save.party = slots[1].party
    if gen == 2 then
      game.generation = 2
      game.save.generation = 2
      game.save.player = { name = "ANN", id = 4321, money = 0 }
    end
    local sc = screen({ slots = slots, mine = 1, host = true, mode = mode or "coop_npc",
                        selfId = "ann" })
    sc.game = game
    if gen == 2 then sc.gen2Mediated = true end
    local uploaded = sc:uploadMediated()
    -- A coop_wild host also owes the wild side's sheet, which these sections
    -- never read; the party upload is what they stand on.
    if mode ~= "coop_wild" then
      eq(uploaded, true, "wave 5: the upload goes out (gen " .. gen .. ", " .. tostring(mode) .. ")")
    end
    sc.mediated = true
    sc.medSlots = { [0] = 1, [1] = 2, [2] = 3, [3] = 4 }
    sc.medFields = { [1] = 0, [2] = 1, [3] = 2, [4] = 3 }
    return sc, slots
  end

  -- ------- HEAL BELL (Gold): every party member's status, benched ones too
  do
    local lead, bench = mon(60, 40), mon(60, 35)
    lead.status, bench.status = "PAR", "SLP"
    local sc, slots = seat5(2, { lead, bench })
    ev(sc, { t = "status", slot = 0, side = "a", mon = 1, text = "X's status was healed" })
    ev(sc, { t = "turn", amount = 2 })
    eq(bench.status, nil, "HEAL BELL (Gold co-op): the benched member's status is cleared in the save")
    eq(lead.status, "PAR", "HEAL BELL (Gold co-op): ...the standing one is not touched by its cure")
    ev(sc, { t = "status", slot = 0, side = "a", mon = 0, text = "X's status was healed" })
    ev(sc, { t = "turn", amount = 3 })
    eq(lead.status, nil, "HEAL BELL (Gold co-op): the standing one's own cure is written home")
    -- A partner's bell cures the partner's party, on this screen's copy of it.
    slots[2].party[1].status = "PSN"
    ev(sc, { t = "status", slot = 1, side = "a", mon = 0, text = "Y's status was healed" })
    ev(sc, { t = "turn", amount = 4 })
    eq(slots[2].party[1].status, nil, "HEAL BELL (Gold co-op): a partner's party member is cured too")
    -- A member the seat does not hold: nothing.
    local rows = sc:medRows({ battle = "cb1", t = "status", slot = 0, side = "a", mon = 5 })
    eq(#rows, 0, "HEAL BELL (Gold co-op): a `mon` the seat does not hold files nothing")
  end

  -- ------- a fight between players fights copies (Red and Gold)
  do
    for _, gen in ipairs({ 1, 2 }) do
      local slots = pvpSlots()
      local saved = slots[1].party[1]
      saved.status = nil
      local opts = CoopBattle.sparOpts({ slots = slots, mine = 1, mode = "coop_pvp" })
      check(opts.slots[1].party[1] ~= saved,
            "PvP (gen " .. gen .. " co-op): our own seat fights a copy of the save's monster")
      eq(opts.slots[1].party[1].hp, saved.hp, "PvP (gen " .. gen .. " co-op): ...an exact one")
      check(opts.slots[3] == slots[3], "PvP (gen " .. gen .. " co-op): the other seats are handed on as they were")
      local sc = seat5(gen, nil, "coop_pvp", opts.slots)
      sc.game.save.party = { saved }
      ev(sc, { t = "damage", slot = 0, side = "a", hp = 7, amount = 53 })
      ev(sc, { t = "status", slot = 0, side = "a", status = "PAR" })
      ev(sc, { t = "turn", amount = 2 })
      eq(saved.hp, 60, "PvP (gen " .. gen .. " co-op): the save's HP is untouched")
      eq(saved.status, nil, "PvP (gen " .. gen .. " co-op): ...and its status")
      eq(opts.slots[1].party[1].hp, 7, "PvP (gen " .. gen .. " co-op): the fight's copy took the hit")
      ev(sc, { t = "faint", slot = 0, side = "a", text = SPECIES_NAME, amount = 0 })
      ev(sc, { t = "turn", amount = 3 })
      eq(saved.hp, 60, "PvP (gen " .. gen .. " co-op): ...nor a faint")
      -- A vitamin's Stat Exp stays the fight's; the bag is still spent.
      sc.game.save.inventory.PROTEIN = 1
      local before = saved.statExp.attack
      sc.pendingItem, sc.pendingItemSlot = "PROTEIN", 1
      sc:confirmMediatedItem("PROTEIN", 1)
      eq(saved.statExp.attack, before, "PvP (gen " .. gen .. " co-op): a vitamin writes no Stat Exp home")
      eq(sc.game.save.inventory.PROTEIN, nil, "PvP (gen " .. gen .. " co-op): ...the bag is still spent")
      -- No EXP, whatever a hub sends.
      local copy = opts.slots[1].party[1]
      local exp0 = copy.exp
      sc:gainExp({ slot = 1, mon = 0, med = true, species = SPECIES, level = 20, participants = 1 })
      eq(copy.exp, exp0, "PvP (gen " .. gen .. " co-op): no EXP is banked in a fight between players")
    end
    -- ...and against the computer the vitamin is the save's (KEEPS_HELD_MODES).
    local keep = mon(60, 40)
    local sc = seat5(1, { keep })
    sc.game.save.inventory.PROTEIN = 1
    local before = keep.statExp.attack
    sc.pendingItem, sc.pendingItemSlot = "PROTEIN", 1
    sc:confirmMediatedItem("PROTEIN", 1)
    check(keep.statExp.attack > before, "coop_npc: a vitamin's Stat Exp is written home")
    -- CoopBattle.new hands a coop_pvp fight to `sparOpts` on Red and Gold.
    for _, gen in ipairs({ 1, 2 }) do
      local realSpar, handed = CoopBattle.sparOpts, nil
      CoopBattle.sparOpts = function(o) handed = o; return realSpar(o) end
      local game = newGame()
      if gen == 2 then game.generation = 2; game.save.generation = 2 end
      pcall(CoopBattle.new, game, { slots = pvpSlots(), mine = 1, mode = "coop_pvp" })
      CoopBattle.sparOpts = realSpar
      check(handed ~= nil, "PvP (gen " .. gen .. "): CoopBattle.new fights copies of our own seat")
    end
  end

  -- ------- a lost fight between players is no whiteout (Red and Gold)
  do
    for _, gen in ipairs({ 1, 2 }) do
      local game = { save = { money = 100, party = { mon(0, 10) }, generation = gen },
                     data = { constants = {} }, generation = gen }
      local coop = setmetatable({ party = { count = function() return 4 end },
        battle = { plan = { allies = { { id = "ann" }, { id = "bob" } },
                            foes = { { id = "cal" }, { id = "dee" } } } } }, { __index = Coop })
      local blackedOut = false
      coop.blackout = function() blackedOut = true end
      coop:onBattleOver("loss", game, { mode = "coop_pvp", mediated = true }, nil)
      eq(blackedOut, false, "PvP loss (gen " .. gen .. "): nobody whites out (a link battle)")
      eq(game.save.money, 100, "PvP loss (gen " .. gen .. "): ...and the wallet is untouched")
    end
    -- Against the computer a wiped party still does.
    local game = { save = { money = 100, party = { mon(0, 10) } }, data = { constants = {} } }
    local coop = setmetatable({ party = { count = function() return 2 end },
      battle = { plan = { allies = { { id = "ann" }, { id = "bob" } } } } }, { __index = Coop })
    local blackedOut = false
    coop.blackout = function() blackedOut = true end
    coop:onBattleOver("loss", game, { mode = "coop_npc", mediated = true }, nil)
    eq(blackedOut, true, "coop_npc loss: the whiteout still runs")
  end

  -- ------- Gold's BATON PASS asks its successor (co-op)
  do
    local lead, fainted, bench = mon(60, 40), mon(0, 30), mon(60, 30)
    lead.moves = { { id = "FIX_TACKLE", pp = 20 }, { id = "FIX_BATON", pp = 40 } }
    local sc = seat5(2, { lead, fainted, bench })
    sc.phase, sc.moveIndex = "move", 2
    sc:updateMove(inputOf("a"))
    eq(sc.phase, "switch", "BATON PASS (Gold co-op): choosing it opens the party picker")
    eq(#choices(sc), 0, "BATON PASS (Gold co-op): ...with nothing filed yet")
    sc:updateSwitch(inputOf("b"))
    eq(sc.phase, "move", "BATON PASS (Gold co-op): B goes back to the move list")
    sc.phase, sc.moveIndex = "move", 2
    sc:updateMove(inputOf("a"))
    sc:updateSwitch(inputOf("a"))
    local sent = choices(sc)
    eq(#sent, 1, "BATON PASS (Gold co-op): A files the move")
    eq(sent[1] and sent[1].move, 1, "BATON PASS (Gold co-op): ...BATON PASS's slot")
    eq(sent[1] and sent[1].pass, 2,
       "BATON PASS (Gold co-op): ...naming the living bench member's party position")
    -- No bench: no menu, the move is filed at once.
    local alone = mon(60, 40)
    alone.moves = { { id = "FIX_TACKLE", pp = 20 }, { id = "FIX_BATON", pp = 40 } }
    local as = seat5(2, { alone })
    as.phase, as.moveIndex = "move", 2
    as:updateMove(inputOf("a"))
    local asent = choices(as)
    eq(#asent, 1, "BATON PASS (Gold co-op): with nobody to pass to it is filed at once")
    eq(asent[1] and asent[1].pass, nil, "BATON PASS (Gold co-op): ...naming nobody")
    -- Red has none.
    local rs = seat5(1, { lead, bench })
    eq(rs:asksPass({ id = "FIX_BATON" }), false, "BATON PASS: Red's co-op never asks")
  end

  -- ------- a foe's send-out is the cart's line; a partner's keeps this screen's
  do
    local sc = seat5(2)
    local rows = sc:medRows({ battle = "cb1", t = "send", slot = 2, side = "b", text = "FOEMON" })
    local said = texts(sc, rows)
    eq(count(said, "TRAINER\nsent out"), 1, "send-out (Gold co-op): BattleText_EnemySentOut's first screen")
    eq(count(said, "sent out\nFOEMON!"), 1, "send-out (Gold co-op): ...and its `cont` screen")
    local prow = sc:medRows({ battle = "cb1", t = "send", slot = 1, side = "a", text = "PALMON" })
    eq(count(texts(sc, prow), "BOB sent out\nPALMON!"), 1, "send-out (co-op): a partner's line is this screen's")
  end

  -- ------- coop_wild: an escape is "Got away safely!", once
  do
    local function wildScreen()
      local slots = {
        { side = "a", owner = "ann", name = "ANN", party = { mon(60, 40) } },
        { side = "a", owner = "bob", name = "BOB", party = { mon(60, 30) } },
        { side = "b", owner = nil, name = "WILD", party = { mon(50, 20) } },
      }
      return seat5(1, nil, "coop_wild", slots)
    end
    local function outcome(sc)
      sc:onBattleOutcome({ battle = "cb1", winners = { "npc" }, losers = { "ann", "bob" }, reason = "run" })
    end
    local said = wildScreen()
    ev(said, { t = "msg", text = "Got away safely!" })
    outcome(said)
    local lines = texts(said)
    eq(count(lines, "Got away safely!"), 1, "escape (coop_wild): the referee's line, once")
    eq(count(lines, "Someone ran away!"), 0, "escape (coop_wild): ...and no \"Someone ran away!\" after it")
    local silent = wildScreen()
    outcome(silent)
    eq(count(texts(silent), "Got away safely!"), 1, "escape (coop_wild): said by the ending when the stream did not")
    local npc = seat5(1)
    npc:onBattleOutcome({ battle = "cb1", winners = { "ann", "bob" }, losers = { "npc" }, reason = "run" })
    eq(count(texts(npc), "Someone ran away!"), 1, "run (coop_npc): the reason line as before")
  end

  -- ------- Red's Bide (co-op): FIGHT files at once while one is going on
  do
    local lead = mon(60, 40)
    lead.moves = { { id = "FIX_TACKLE", pp = 20 }, { id = "FIX_BIDE", pp = 10 } }
    local sc = seat5(1, { lead })
    ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    sc:commit({ slot = 1, move = 2, target = 3 })
    ev(sc, { t = "msg", text = SPECIES_NAME .. " used BIDE" })
    ev(sc, { t = "turn", amount = 2 })
    check(sc.bideLocked == true, "Bide (Red co-op): the turn after \"used BIDE\" is a Bide going on")
    local before = #choices(sc)
    sc.phase, sc.commandIndex = "choose", 1
    sc:updateCommand(inputOf("a"))
    local sent = choices(sc)
    eq(#sent, before + 1, "Bide (Red co-op): FIGHT files at once (MainInBattleLoop's STORING_ENERGY skip)")
    eq(sent[#sent] and sent[#sent].move, 1, "Bide (Red co-op): ...the Bide's slot")
    ev(sc, { t = "turn", amount = 3 })
    check(sc.bideLocked == true, "Bide (Red co-op): a silent store turn keeps it")
    ev(sc, { t = "msg", text = SPECIES_NAME .. " unleashed energy" })
    ev(sc, { t = "turn", amount = 4 })
    check(not sc.bideLocked, "Bide (Red co-op): the release ends it")
  end

  -- ------- wave 6 of docs/plans/gen12-referee-gaps-fix.md: the co-op screen
  -- against the referees' new wording, events and states.
  local function noInput6()
    return { wasPressed = function() return false end, isDown = function() return false end }
  end
  -- Plays the batch out, A pressed on every frame a line is up (and only
  -- then, so no press reaches the menu the batch hands over to).
  local function drain6(sc)
    local n = 0
    while (sc.phase == "messages" or sc.shown ~= nil or #sc.messages > 0) and n < 400 do
      sc.game.input = (sc.phase == "messages") and inputOf("a") or noInput6()
      sc:update(1 / 60)
      n = n + 1
    end
    sc.game.input = noInput6()
  end
  local function rowsOf(sc, kind)
    local out = {}
    for _, r in ipairs(sc.medPending or {}) do
      if r.kind == kind then out[#out + 1] = r end
    end
    return out
  end

  -- Gold's 0-HP `standing` seat (BattleSim2, wave 5): a hit that left our
  -- monster at 0 with no `faint` behind it -- SPIKES on a successor -- is
  -- still our monster: we choose for it, never watch.
  do
    local sc = seat5(2)
    ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 6 })
    ev(sc, { t = "msg", text = SPECIES_NAME .. "'s hurt by SPIKES!" })
    ev(sc, { t = "damage", slot = 0, side = "a", hp = 0, amount = 6 })
    ev(sc, { t = "damage", slot = 2, side = "b", hp = 0, amount = 50 })
    ev(sc, { t = "turn", amount = 2 })
    drain6(sc)
    local seat = sc.sim:slot(1)
    eq(seat.battler and seat.battler.mon and seat.battler.mon.hp, 0,
       "standing (Gold co-op): the monster on our seat is at 0 HP")
    eq(sc:spectating(), false, "standing (Gold co-op): ...and we are not spectating")
    eq(sc.phase, "choose", "standing (Gold co-op): the command menu opens for it")
    local foeAt = false
    for _, t in ipairs(sc:targetChoices()) do if t.index == 3 then foeAt = true end end
    check(foeAt, "standing (Gold co-op): a foe standing at 0 HP is still a target")
    ev(sc, { t = "faint", slot = 0, side = "a", text = SPECIES_NAME })
    eq(sc:spectating(), true, "standing (Gold co-op): the faint that comes later ends it")
  end

  -- Gold's ROAR / WHIRLWIND drags our monster out mid-turn (wave 5): a
  -- `switch` + `send` on our seat we never chose, and the seat follows it.
  do
    local lead, bench = mon(60, 40), mon(60, 35)
    bench.moves = { { id = "FIX_TACKLE", pp = 7 } }
    local sc = seat5(2, { lead, bench })
    ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    ev(sc, { t = "msg", text = "FOE used WHIRLWIND!" })
    ev(sc, { t = "switch", slot = 0, side = "a", mon = 1, text = SPECIES_NAME })
    ev(sc, { t = "send", slot = 0, side = "a", mon = 1, text = SPECIES_NAME, hp = 60 })
    ev(sc, { t = "msg", text = SPECIES_NAME .. " was dragged out!" })
    ev(sc, { t = "turn", amount = 2 })
    drain6(sc)
    eq(sc.sim:slot(1).active, 2, "dragged out (Gold co-op): our seat fields the party member the referee named")
    eq(sc:liveMoves()[1] and sc:liveMoves()[1].pp, 7, "dragged out (Gold co-op): FIGHT lists the newcomer's moves")
    eq(sc.phase, "choose", "dragged out (Gold co-op): ...and the next turn is ours to choose")
  end

  -- The trainer on the NPC upload (Red): its name and its class's AI layers,
  -- which the hub hands the computer seats (W5).
  do
    local game = newGame()
    game.data = data5
    local host = screen({ slots = npcSlots(), mine = 1, host = true, mode = "coop_npc",
                          selfId = "ann", game = game })
    host.trainer = { name = "BUG CATCHER", aiMods = { 1, 3 } }
    eq(host:uploadMediated(), true, "NPC seat (Red co-op): the upload goes out")
    local npc
    for _, m in ipairs(host.sent) do
      if m.type == Wire.BATTLE_PARTY and m.payload.side == "b" then npc = m.payload end
    end
    eq(npc and npc.name, "BUG CATCHER", "NPC seat (Red co-op): the trainer's name rides the party")
    eq(npc and table.concat(npc.aiMods or {}, ","), "1,3", "NPC seat (Red co-op): ...with its AI layers")
    local packed = npc and Wire.battleParty(npc, 1)
    eq(packed and packed.aiMods and table.concat(packed.aiMods, ","), "1,3",
       "NPC seat (Red co-op): Wire.battleParty takes them")
  end

  -- POKe DOLL in a trainer fight (Red and Gold): the cart's line, the bag back
  -- up, nothing filed.
  for _, gen in ipairs({ 1, 2 }) do
    local sc = seat5(gen)
    sc.game.save.player = sc.game.save.player or { name = "ANN" }
    local before = #choices(sc)
    sc.phase, sc.itemIndex = "item", 1
    sc.itemList = { { id = "POKE_DOLL", name = "POKe DOLL", count = 1,
                      effect = need("BattleSim/Effects").itemEffect("POKE_DOLL") } }
    sc:updateItem(inputOf("a"))
    eq(#choices(sc), before, "doll (co-op trainer, gen " .. gen .. "): nothing is filed")
    eq(sc.after, "item", "doll (co-op trainer, gen " .. gen .. "): the bag comes back")
    local said = table.concat(texts(sc), " "):gsub("\n", " ")
    -- text / line / cont: the `cont` scrolls the middle row up (K18).
    check(said:find("OAK: ANN! This isn't the This isn't the time to use that!", 1, true) ~= nil,
          "doll (co-op trainer, gen " .. gen .. "): ItemUseNotTime's line")
  end

  -- Red's status animations in coop_pvp: a foe's clip is the enemy's variant
  -- on this screen, and its sleep clip goes after its line.
  do
    local sc = seat5(1, nil, "coop_pvp", pvpSlots())
    sc.medPending = {}
    ev(sc, { t = "anim", slot = 2, side = "b", text = "CONF_PLAYER_ANIM" })
    ev(sc, { t = "anim", slot = 0, side = "a", text = "CONF_PLAYER_ANIM" })
    local anims = rowsOf(sc, "anim")
    eq(anims[1] and anims[1].anim, "CONF_ANIM", "status anim (co-op): a foe's clip is the enemy's")
    eq(anims[2] and anims[2].anim, "CONF_PLAYER_ANIM", "status anim (co-op): ...our own keeps the player's")
    sc.medPending = {}
    ev(sc, { t = "anim", slot = 2, side = "b", text = "SLP_PLAYER_ANIM" })
    ev(sc, { t = "msg", text = "FOE is fast asleep!" })
    local order = {}
    for _, r in ipairs(sc.medPending) do
      if r.kind == "anim" then order[#order + 1] = r.anim
      elseif r.kind == "msg" then order[#order + 1] = "msg" end
    end
    eq(table.concat(order, ","), "msg,SLP_ANIM", "status anim (co-op): the foe's sleep clip plays behind its line")
  end

  -- Red's PP byte past the wrap (co-op's live party is the save's): 0 paid is
  -- 63 and a PP Up borrowed, and a refund carries it back.
  do
    local lead = mon(60, 40)
    lead.moves = { { id = "FIX_TACKLE", pp = 0 } }
    local sc = seat5(1, { lead })
    ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    ev(sc, { t = "moves", slot = 0, side = "a", mon = 0,
             moves = { { id = "FIX_TACKLE", pp = 63, maxPp = 35 } } })
    eq(lead.moves[1].pp .. "/" .. tostring(lead.moves[1].ppUps), "63/3",
       "PP wrap (Red co-op): the save holds 63 PP and the borrowed PP Up")
    ev(sc, { t = "moves", slot = 0, side = "a", mon = 0,
             moves = { { id = "FIX_TACKLE", pp = 0, maxPp = 35 } } })
    eq(lead.moves[1].pp .. "/" .. tostring(lead.moves[1].ppUps), "0/0",
       "PP wrap (Red co-op): IncrementMovePP's carry gives it back")
  end

  -- The catch is the referee's line alone: no "Gotcha!" of this screen's.
  do
    local sc = seat5(1, nil, "coop_wild")
    sc:onBattleOutcome({ battle = "cb1", winners = { "ann", "bob" }, losers = { "npc" },
                         reason = "catch", catcher = "bob" })
    eq(count(texts(sc), "Gotcha!"), 0, "catch (co-op): the referee's catch line is not echoed")
  end

  -- Gold's coop_wild RUN can fail (wave 5): "Can't escape!" and the turn goes
  -- on -- the screen is back at its menu, the fight still open.
  do
    local game = newGame()
    game.data = data5
    game.generation, game.save.generation = 2, 2
    game.save.player = { name = "ANN", id = 4321, money = 0 }
    -- Built on the fixture's Red field (CoopField takes no Gold game), then
    -- handed the Gold game, as `seat5` does.
    local sc = screen({ slots = npcSlots(), mine = 1, host = true, mode = "coop_wild",
                        selfId = "ann" })
    sc.game = game
    sc.gen2Mediated = true
    sc.wildParty = need("MediatedBattle").snapshotMons(game, { mon(20, 10) })
    eq(sc:uploadMediated(), true, "failed run (Gold co-op): the wild fight is uploaded")
    sc.mediated = true
    sc.medSlots = { [0] = 1, [1] = 2, [2] = 3, [3] = 4 }
    sc.medFields = { [1] = 0, [2] = 1, [3] = 2, [4] = 3 }
    ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    sc.phase = "choose"
    sc:askToRun()
    local sent = choices(sc)
    eq(sent[#sent] and sent[#sent].action, "run", "failed run (Gold co-op): the RUN is filed")
    ev(sc, { t = "msg", text = "Can't escape!" })
    ev(sc, { t = "turn", amount = 2 })
    drain6(sc)
    eq(sc.result, nil, "failed run (Gold co-op): the fight is still on")
    eq(sc.escapeSaid, nil, "failed run (Gold co-op): no escape was read")
    eq(sc.phase, "choose", "failed run (Gold co-op): ...and the menu is back")
  end

  -- ------- review fixes (FX-C of docs/plans/gen12-referee-gaps-fix.md)
  --
  -- The Bide start in a mirror match (a foe or a partner of our species), a
  -- MIRROR MOVE that copied a BIDE, Gold's drag-out line, no moveset message
  -- in a fight between players, and Red's overlay maximum PP.
  do
    local function bider(moves)
      local lead = mon(60, 40)
      lead.moves = moves or { { id = "FIX_TACKLE", pp = 20 }, { id = "FIX_BIDE", pp = 10 } }
      return lead
    end
    -- Red: we file TACKLE, the foe -- our species -- uses BIDE.
    local sc = seat5(1, { bider() })
    ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    sc:commit({ slot = 1, move = 1, target = 3 })
    ev(sc, { t = "anim", slot = 2, side = "b", text = "FIX_BIDE" })
    ev(sc, { t = "msg", text = SPECIES_NAME .. " used BIDE!" })
    ev(sc, { t = "turn", amount = 2 })
    check(not sc.bideLocked, "Bide mirror (Red co-op): the foe's used line locks nothing (we filed no BIDE)")
    -- We file BIDE, our partner -- our species -- says it first: still not ours.
    sc:commit({ slot = 1, move = 2, target = 3 })
    ev(sc, { t = "anim", slot = 1, side = "a", text = "FIX_BIDE" })
    ev(sc, { t = "msg", text = SPECIES_NAME .. " used BIDE!" })
    ev(sc, { t = "msg", text = SPECIES_NAME .. " flinched!" })
    ev(sc, { t = "turn", amount = 3 })
    check(not sc.bideLocked, "Bide mirror (Red co-op): a partner's line behind its own animation is the partner's")
    sc:commit({ slot = 1, move = 2, target = 3 })
    ev(sc, { t = "anim", slot = 0, side = "a", text = "FIX_BIDE" })
    ev(sc, { t = "msg", text = SPECIES_NAME .. " used BIDE!" })
    ev(sc, { t = "turn", amount = 4 })
    check(sc.bideLocked == true, "Bide mirror (Red co-op): ...and our own animation and line start ours")
    -- A MIRROR MOVE that copied a BIDE (reported on our seat) is ours too.
    local mc = seat5(1, { bider({ { id = "FIX_MIRROR", pp = 20 } }) })
    ev(mc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    mc:commit({ slot = 1, move = 1, target = 3 })
    check(mc.callFiled == 1 and not mc.bideFiled, "Bide by MIRROR MOVE (Red co-op): filed as a call")
    ev(mc, { t = "anim", slot = 0, side = "a", text = "FIX_MIRROR" })
    ev(mc, { t = "msg", text = SPECIES_NAME .. " used MIRROR MOVE!" })
    ev(mc, { t = "anim", slot = 0, side = "a", text = "FIX_BIDE" })
    ev(mc, { t = "msg", text = SPECIES_NAME .. " used BIDE!" })
    ev(mc, { t = "turn", amount = 2 })
    check(mc.bideLocked == true, "Bide by MIRROR MOVE (Red co-op): the copied BIDE locks the next FIGHT")
    -- Gold: our BIDE filed, the foe's line behind the foe's animation.
    local gs = seat5(2, { bider({ { id = "FIX_TACKLE", pp = 20, maxPp = 35 },
                                  { id = "FIX_BIDE", pp = 9, maxPp = 9 } }) })
    ev(gs, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    gs:commit({ slot = 1, move = 2, target = 3 })
    ev(gs, { t = "anim", slot = 3, side = "b", text = "FIX_BIDE" })
    ev(gs, { t = "msg", text = SPECIES_NAME .. " used BIDE!" })
    ev(gs, { t = "turn", amount = 2 })
    check(not gs.bideLocked, "Bide seat (Gold co-op): the foe's line behind its own animation starts nothing")
  end

  -- Gold's drag-out: DraggedOutText alone -- no "Go!" for our monster, no
  -- trainer's pages for theirs (pokecrystal BattleCommand_ForceSwitch).
  do
    local lead, bench = mon(60, 40), mon(60, 35)
    local sc = seat5(2, { lead, bench })
    ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    ev(sc, { t = "switch", slot = 0, side = "a", mon = 1, text = SPECIES_NAME })
    ev(sc, { t = "send", slot = 0, side = "a", mon = 1, text = SPECIES_NAME, hp = 60 })
    ev(sc, { t = "moves", slot = 0, side = "a", mon = 0, moves = { { id = "FIX_TACKLE", pp = 20 } } })
    ev(sc, { t = "msg", text = SPECIES_NAME .. " was dragged out!" })
    local said = texts(sc)
    eq(count(said, "Go! " .. SPECIES_NAME .. "!"), 1, "drag-out (Gold co-op): only the opening \"Go!\" -- none for the dragged-out one")
    eq(count(said, SPECIES_NAME .. " was dragged out!"), 1, "drag-out (Gold co-op): DraggedOutText is said")
    eq(#rowsOf(sc, "send"), 2, "drag-out (Gold co-op): ...and both arrivals still play")
    -- The foe's: the trainer's two pages go.
    ev(sc, { t = "switch", slot = 2, side = "b", mon = 1, text = "DRAGGEE" })
    ev(sc, { t = "send", slot = 2, side = "b", mon = 1, text = "DRAGGEE", hp = 50 })
    ev(sc, { t = "msg", text = "DRAGGEE was dragged out!" })
    local foeLine = 0
    for _, t in ipairs(texts(sc)) do if t:find("DRAGGEE!", 1, true) then foeLine = foeLine + 1 end end
    eq(foeLine, 0, "drag-out (Gold co-op): no \"sent out DRAGGEE!\" page for the foe's")
    -- An ordinary send-out keeps its line.
    ev(sc, { t = "send", slot = 3, side = "b", mon = 1, text = "PLAINSEND", hp = 50 })
    ev(sc, { t = "msg", text = "PLAINSEND used FIX TACKLE!" })
    local plain = 0
    for _, t in ipairs(texts(sc)) do if t:find("PLAINSEND!", 1, true) then plain = plain + 1 end end
    eq(plain, 1, "drag-out (Gold co-op): a send-out with no drag-out behind it keeps its page")
  end

  -- No `mmo.battle_moveset` in a fight between players: no cart learns or
  -- levels in a link battle.
  do
    local sc, slots = seat5(1, nil, "coop_pvp", pvpSlots())
    local lead = slots[1].party[1]
    local before = 0
    for _, m in ipairs(sc.sent) do if m.type == Wire.BATTLE_MOVESET then before = before + 1 end end
    lead.moves[#lead.moves + 1] = { id = "FIX_CUT", pp = 30 }
    eq(sc:syncFightMoves(lead, true), false, "link moveset (coop_pvp): a level-up sends nothing")
    eq(sc:syncFightMoves(lead), false, "link moveset (coop_pvp): ...nor a learn")
    local after = 0
    for _, m in ipairs(sc.sent) do if m.type == Wire.BATTLE_MOVESET then after = after + 1 end end
    eq(after - before, 0, "link moveset (coop_pvp): no mmo.battle_moveset went out")
    local npc, nslots = seat5(1)
    eq(npc:syncFightMoves(nslots[1].party[1], true), true,
       "moveset (coop_npc): a level-up against the computer is still sent")
  end

  -- Red's overlay maximum: GetMaxPP over the battle struct -- a Transform
  -- copy (5 PP, no PP Ups) reads its own move's base.
  do
    local sc = seat5(1)
    ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    ev(sc, { t = "moves", slot = 0, side = "a",
             moves = { { id = "FIX_EMBERISH", pp = 5, maxPp = 5, ppUps = 0 } } })
    local rows = sc:bandMoveRows()
    eq(rows[1] and rows[1].right, "5/25", "Transform PP (Red co-op): a copy reads 5 over its own base")
  end

  -- ------- final client fixes (FX-C2): STRUGGLE at the menu (co-op)
  --
  -- MediatedBattle `mustStruggle` (pokered AnyMoveToSelect, pokecrystal
  -- CheckPlayerHasUsableMoves): the disabled move the only one with PP --
  -- FIGHT opens no move list, says the cart's line, and aims a STRUGGLE.
  -- Every monster in these fixtures is one species, so the DISABLE user's
  -- side is what says whose move the line names.
  do
    for _, gen in ipairs({ 1, 2 }) do
      local lead = mon(60, 40)
      lead.moves = { { id = "FIX_TACKLE", pp = 5 }, { id = "FIX_EMBERISH", pp = 0 } }
      local sc = seat5(gen, { lead })
      local tag = gen == 1 and "Red co-op" or "Gold co-op"
      local word = gen == 1 and "disabled" or "DISABLED"
      local line = SPECIES_NAME .. "'s FIX TACKLE was " .. word .. "!"
      ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
      -- Our partner's DISABLE: aimed at a foe of our species.
      ev(sc, { t = "anim", slot = 1, side = "a", text = "DISABLE" })
      ev(sc, { t = "msg", text = line })
      eq(sc.medDisabled, nil, "Disable (" .. tag .. "): a partner's DISABLE is a foe's line")
      -- A foe's: ours.
      ev(sc, { t = "anim", slot = 2, side = "b", text = "DISABLE" })
      ev(sc, { t = "msg", text = line })
      eq(sc.medDisabled, 1, "Disable (" .. tag .. "): a foe's DISABLE on our FIX TACKLE is read off its line")
      check(sc:medStruggles(), "Struggle (" .. tag .. "): the disabled move the only one with PP")
      sc.messages, sc.phase, sc.commandIndex = {}, "choose", 1
      sc:updateCommand(inputOf("a"))
      eq(sc.phase, "messages", "Struggle (" .. tag .. "): FIGHT opens no move list -- the line first")
      eq(sc.after, "target", "Struggle (" .. tag .. "): ...then the aim")
      eq((sc.messages[1] or ""):gsub("\n", " "), SPECIES_NAME .. " has no moves left!",
         "Struggle (" .. tag .. "): the cart's no-moves-left line")
      local before = #choices(sc)
      sc.phase = sc.after
      sc:updateTarget(inputOf("a"))
      local got = choices(sc)
      eq(#got, before + 1, "Struggle (" .. tag .. "): the aimed STRUGGLE is sent")
      eq(got[#got] and got[#got].action, "fight", "Struggle (" .. tag .. "): ...a FIGHT")
      eq(got[#got] and got[#got].move, 0, "Struggle (" .. tag .. "): ...naming the disabled slot")
      eq(sc.bideFiled, nil, "Struggle (" .. tag .. "): ...and no Bide is read off it")
      -- The end of it, and the refusals of an ordinary list.
      ev(sc, { t = "msg", text = SPECIES_NAME .. "'s disabled no more!" })
      eq(sc.medDisabled, nil, "Disable (" .. tag .. "): \"disabled no more!\" lifts it")
      lead.moves[2].pp = 3
      ev(sc, { t = "anim", slot = 2, side = "b", text = "DISABLE" })
      ev(sc, { t = "msg", text = line })
      check(not sc:medStruggles(), "Struggle (" .. tag .. "): FIX EMBER with PP is a move list")
      sc.messages, sc.phase, sc.moveIndex = {}, "move", 1
      sc:updateMove(inputOf("a"))
      eq((sc.messages[1] or ""):gsub("\n", " "), "The move is " .. word .. "!",
         "menu (" .. tag .. "): the disabled pick is refused in the cart's words")
      eq(sc.after, "move", "menu (" .. tag .. "): ...back to the list")
      ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
      eq(sc.medDisabled, nil, "Disable (" .. tag .. "): a send-out on our seat drops it")
    end
  end

  -- ------- final client fixes (FX-C2): a WHIRLWIND that blows the wild
  -- monster off ends on its line -- the wild side is the one that left (the
  -- target's, FX-R1), so the party is named the winner, and the carts play
  -- no fanfare for an escape (MediatedBattle `finish`).
  do
    local function fanfares(sc)
      local n = 0
      for _, row in ipairs(sc.messages or {}) do
        if type(row) == "table" and type(row.act) == "function" then n = n + 1 end
      end
      return n
    end
    for _, gen in ipairs({ 1, 2 }) do
      local tag = gen == 1 and "Red" or "Gold"
      local slots = {
        { side = "a", owner = "ann", name = "ANN", party = { mon(60, 40) } },
        { side = "a", owner = "bob", name = "BOB", party = { mon(60, 30) } },
        { side = "b", owner = nil, name = "WILD", party = { mon(50, 20) } },
      }
      local sc = seat5(gen, nil, "coop_wild", slots)
      sc.messages = {}
      ev(sc, { t = "msg", text = SPECIES_NAME .. " was blown away!" })
      sc:onBattleOutcome({ battle = "cb1", winners = { "ann", "bob" }, losers = { "npc" }, reason = "run" })
      eq(sc.result, "win", "WHIRLWIND (" .. tag .. " coop_wild): the party is the side left standing")
      eq(count(texts(sc), "Got away safely!"), 0, "WHIRLWIND (" .. tag .. " coop_wild): the move's line stands alone")
      eq(fanfares(sc), 0, "WHIRLWIND (" .. tag .. " coop_wild): no victory fanfare for an escape")
      -- A knockout still plays it.
      local ko = seat5(gen, nil, "coop_wild", {
        { side = "a", owner = "ann", name = "ANN", party = { mon(60, 40) } },
        { side = "a", owner = "bob", name = "BOB", party = { mon(60, 30) } },
        { side = "b", owner = nil, name = "WILD", party = { mon(50, 20) } },
      })
      ko.messages = {}
      ko:onBattleOutcome({ battle = "cb1", winners = { "ann", "bob" }, losers = { "npc" }, reason = "ko" })
      eq(fanfares(ko), 1, "knockout (" .. tag .. " coop_wild): the fanfare as before")
    end
    -- The wild monster's ROAR on the party (FX-R1: the target's side is the
    -- runner and the loser), and the party's own RUN, the same shape: an
    -- escape, no defeat -- its line, and no blackout behind it.
    for _, gen in ipairs({ 1, 2 }) do
      local tag = gen == 1 and "Red" or "Gold"
      local sc = seat5(gen, nil, "coop_wild", {
        { side = "a", owner = "ann", name = "ANN", party = { mon(60, 40) } },
        { side = "a", owner = "bob", name = "BOB", party = { mon(60, 30) } },
        { side = "b", owner = nil, name = "WILD", party = { mon(50, 20) } },
      })
      sc.messages = {}
      ev(sc, { t = "msg", text = SPECIES_NAME .. " ran away scared!" })
      sc:onBattleOutcome({ battle = "cb1", winners = { "npc" }, losers = { "ann", "bob" }, reason = "run" })
      eq(sc.result, "loss", "ROAR on us (" .. tag .. " coop_wild): the outcome names the party the side that left")
      eq(count(texts(sc), "Got away safely!"), 0, "ROAR on us (" .. tag .. " coop_wild): the move's line stands alone")
      eq(sc.medEndReason, "run", "ROAR on us (" .. tag .. " coop_wild): the screen keeps why it ended")
      local game = { save = { money = 100, party = { mon(60, 10) }, generation = gen },
                     data = { constants = {} }, generation = gen }
      local coop = setmetatable({ party = { count = function() return 2 end },
        battle = { plan = { kind = "wild", allies = { { id = "ann" }, { id = "bob" } } } } },
        { __index = Coop })
      local blackedOut = false
      coop.blackout = function() blackedOut = true end
      coop:onBattleOver("loss", game, { mode = "coop_wild", mediated = true, medEndReason = "run" }, nil)
      eq(blackedOut, false, "escape (" .. tag .. " coop_wild): a run is no defeat -- no blackout")
      eq(game.save.money, 100, "escape (" .. tag .. " coop_wild): ...and the wallet is untouched")
      local lost = setmetatable({ party = { count = function() return 2 end },
        battle = { plan = { kind = "wild", allies = { { id = "ann" }, { id = "bob" } } } } },
        { __index = Coop })
      local wiped = false
      lost.blackout = function() wiped = true end
      lost:onBattleOver("loss", game, { mode = "coop_wild", mediated = true, medEndReason = "ko" }, nil)
      eq(wiped, true, "knockout (" .. tag .. " coop_wild): a lost fight still whites out")
    end
  end

  -- ------- final client fixes (FX-C2): an item the cart does not use
  --
  -- MediatedBattle `itemWontHaveEffect` (pokered ItemUseNoEffect, pokecrystal
  -- WontHaveAnyEffectMessage): the line, the bag back up, nothing filed and
  -- nothing spent -- the referees refuse such a choice at the door, which a
  -- hub answers with silence.
  do
    for _, gen in ipairs({ 1, 2 }) do
      local tag = gen == 1 and "Red co-op" or "Gold co-op"
      local IE = (gen == 1 and need("BattleSim/Effects") or need("BattleSim2/Effects")).itemEffect
      local lead = mon(60, 40)
      local sc = seat5(gen, { lead })
      sc.game.save.inventory = { POTION = 2 }
      sc.bagSheet = { POTION = 2 }
      sc.messages = {}
      local before = #choices(sc)
      sc.itemPick = { id = "POTION", effect = IE("POTION") }
      eq(sc:commitMediatedItem(1, nil), false, "POTION (" .. tag .. ", full HP): not filed")
      eq(#choices(sc), before, "POTION (" .. tag .. ", full HP): ...nothing sent")
      eq(count(texts(sc), "It won't have any\neffect."), 1, "POTION (" .. tag .. ", full HP): the cart's line")
      eq(sc.after, "item", "POTION (" .. tag .. ", full HP): ...then the bag again")
      eq(sc.game.save.inventory.POTION, 2, "POTION (" .. tag .. ", full HP): ...the item kept")
      lead.hp = 20
      sc.itemPick = { id = "POTION", effect = IE("POTION") }
      check(sc:commitMediatedItem(1, nil), "POTION (" .. tag .. ", hurt): filed")
      eq(#choices(sc), before + 1, "POTION (" .. tag .. ", hurt): ...sent")
    end
    -- Gold's X ACCURACY: taken once (its `item` event sets the bit), refused
    -- the second time (WontHaveAnyEffect_NotUsedMessage).
    local IE2 = need("BattleSim2/Effects").itemEffect
    local sc = seat5(2, { mon(60, 40) })
    sc.game.save.inventory = { X_ACCURACY = 2 }
    sc.bagSheet = { X_ACCURACY = 2 }
    ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    sc.itemPick = { id = "X_ACCURACY", effect = IE2("X_ACCURACY") }
    check(sc:commitMediatedItem(1, nil), "X ACCURACY (Gold co-op): the first is filed")
    ev(sc, { t = "item", slot = 0, side = "a", text = "X_ACCURACY" })
    eq(sc.medItemFlags2 and sc.medItemFlags2.xAccuracy, true, "X ACCURACY (Gold co-op): its `item` event sets the bit")
    sc.messages = {}
    local before = #choices(sc)
    sc.itemPick = { id = "X_ACCURACY", effect = IE2("X_ACCURACY") }
    eq(sc:commitMediatedItem(1, nil), false, "X ACCURACY (Gold co-op): the second is not filed")
    eq(#choices(sc), before, "X ACCURACY (Gold co-op): ...nothing sent")
    ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    eq(sc.medItemFlags2, nil, "X ACCURACY (Gold co-op): a send-out on our seat drops the bit")
  end

  -- ------------------------------------------------------------------
  -- the remaining Red / Gold gaps (docs/plans/gen12-referee-remaining-gaps.md)
  -- ------------------------------------------------------------------
  local function has(list, text) return count(list, text) > 0 end

  -- K17: a mark per viewer -- our side, a partner's monster included, bare;
  -- the other side "Enemy " (Red's and Gold's EnemyText, every mode).
  for _, gen in ipairs({ 1, 2 }) do
    local sc = seat5(gen)
    ev(sc, { t = "msg", text = "^a" .. SPECIES_NAME .. "\nused FIX TACKLE!" })
    ev(sc, { t = "msg", text = "^b" .. SPECIES_NAME .. "'s\nattack missed!" })
    ev(sc, { t = "turn", amount = 2 })
    local said = texts(sc)
    check(has(said, SPECIES_NAME .. "\nused FIX TACKLE!"),
          "K17 (co-op, gen " .. gen .. "): our side's monster -- ours or the partner's -- is bare")
    check(has(said, "Enemy " .. SPECIES_NAME .. "'s\nattack missed!"),
          "K17 (co-op, gen " .. gen .. "): the trainer's is the enemy's")
    for _, t in ipairs(said) do
      if t:find("^", 1, true) then check(false, "K17 (co-op): a mark reached the box: " .. t) end
    end
  end
  do
    local sc = seat5(2, nil, "coop_wild")
    ev(sc, { t = "msg", text = "^b" .. SPECIES_NAME .. "\nused FIX TACKLE!" })
    ev(sc, { t = "turn", amount = 2 })
    check(has(texts(sc), "Enemy " .. SPECIES_NAME .. "\nused FIX TACKLE!"),
          "K17 (co-op Gold wild): \"Enemy\" -- PlaceBattlersName has no wild arm")
  end
  do
    -- A coop_pvp seat on side b reads side a as the enemy's.
    local slots = pvpSlots()
    local sc = screen({ slots = slots, mine = 3, host = false, mode = "coop_pvp", selfId = "cal" })
    sc.mediated = true
    sc.medSlots = { [0] = 1, [1] = 2, [2] = 3, [3] = 4 }
    sc.medFields = { [1] = 0, [2] = 1, [3] = 2, [4] = 3 }
    eq(sc:viewerSide(), "b", "K17 (coop_pvp): this seat's side is the sim's")
    eq(sc:medViewLine("^aALPHA hit ^bBETA!"), "Enemy ALPHA hit BETA!",
       "K17 (coop_pvp, side b): side a's monster is the enemy's here")
  end

  -- The faint line, per viewer: a partner's monster is on our side.
  do
    local sc = seat5(1)
    ev(sc, { t = "faint", slot = 1, side = "a", text = SPECIES_NAME })
    ev(sc, { t = "faint", slot = 2, side = "b", text = SPECIES_NAME })
    ev(sc, { t = "turn", amount = 2 })
    local said = texts(sc)
    check(has(said, SPECIES_NAME .. "\nfainted!"), "faint (co-op): the partner's monster is said bare")
    check(has(said, "Enemy " .. SPECIES_NAME .. "\nfainted!"), "faint (co-op): the trainer's is the enemy's")
  end

  -- K19: a knockout's faint after the hit's tail -- the 0-HP monster stands,
  -- its sink and line come behind the drain's line.
  do
    local sc = seat5(1)
    ev(sc, { t = "damage", slot = 2, side = "b", hp = 0 })
    ev(sc, { t = "drain", slot = 0, side = "a", hp = 60 })
    ev(sc, { t = "msg", text = "Sucked health from\n^b" .. SPECIES_NAME .. "!" })
    ev(sc, { t = "faint", slot = 2, side = "b", text = SPECIES_NAME })
    ev(sc, { t = "turn", amount = 2 })
    local tail, sink, line
    for i, row in ipairs(sc.messages) do
      local text = type(row) == "table" and row.text or row
      if text == "Sucked health from\nEnemy " .. SPECIES_NAME .. "!" then tail = tail or i end
      if type(row) == "table" and row.faintfx ~= nil then sink = sink or i end
      if text == "Enemy " .. SPECIES_NAME .. "\nfainted!" then line = line or i end
    end
    check(tail ~= nil and sink ~= nil and tail < sink, "K19 (co-op): the tail's line plays before the sink")
    check(sink ~= nil and line ~= nil and sink < line, "K19 (co-op): ...and the faint line after it")
    local foe = sc.sim:slot(3)
    eq(foe.battler and foe.battler.displayFainted, nil, "K19 (co-op): the 0-HP monster still stands while it plays")
  end

  -- Timeout lines said at once are rendered too.
  do
    local sc = seat5(1)
    ev(sc, { t = "msg", text = "^aANN ran out of time!" })
    check(has(texts(sc), "ANN ran out of\ntime!"), "K17 (co-op): an immediate line is rendered as well")
  end

  -- Link run lines in coop_pvp: the runner, the runner's partner, the foe.
  local function pvpRun(gen, runnerField, runnerSide, result)
    local sc = seat5(gen, nil, "coop_pvp", pvpSlots())
    ev(sc, { t = "run", slot = runnerField, side = runnerSide, text = "SOMEONE" })
    local winners, losers = { "cal", "dee" }, { "ann", "bob" }
    if result == "win" then winners, losers = losers, winners end
    sc:onBattleOutcome({ battle = "cb1", winners = winners, losers = losers, reason = "run" })
    return texts(sc)
  end
  do
    local runner = pvpRun(1, 0, "a", "loss")
    check(has(runner, "Got away safely!"), "link run (coop_pvp, runner): GotAwayText")
    check(not has(runner, "Someone ran away!") and not has(runner, "SOMEONE"),
          "link run (coop_pvp, runner): no mod line, and the trainer's name is never a line")
    local partner = pvpRun(1, 1, "a", "loss")
    check(has(partner, SPECIES_NAME .. "\nran!"), "link run (coop_pvp, partner): the foe's line without the prefix")
    local foe = pvpRun(1, 2, "b", "win")
    check(has(foe, "Enemy " .. SPECIES_NAME .. "\nran!"), "link run (coop_pvp Red, foe): _EnemyRanText")
    local foe2 = pvpRun(2, 2, "b", "win")
    check(has(foe2, "Enemy " .. SPECIES_NAME .. "\nfled!"), "link run (coop_pvp Gold, foe): BattleText_EnemyFled")
  end
  do
    -- A coop_wild escape: the referee's own line, once, and no trainer's name.
    local sc = seat5(1, nil, "coop_wild")
    ev(sc, { t = "msg", text = "Got away safely!" })
    ev(sc, { t = "run", slot = 0, side = "a", text = "ANN" })
    sc:onBattleOutcome({ battle = "cb1", winners = { "ann", "bob" }, losers = {}, reason = "run" })
    local said = texts(sc)
    eq(count(said, "Got away safely!"), 1, "coop_wild run: \"Got away safely!\" once")
    eq(count(said, "ANN"), 0, "coop_wild run: the runner's name is not printed as a line")
  end

  -- K20: XSTATITEM_ANIM takes the X item's look over.
  do
    local sc = seat5(1)
    sc.medPending = {}
    ev(sc, { t = "item", slot = 0, side = "a", text = "X_ATTACK" })
    ev(sc, { t = "msg", text = "ANN used X ATTACK!" })
    ev(sc, { t = "anim", slot = 0, side = "a", text = "XSTATITEM_ANIM" })
    local looks, style = 0, nil
    for _, row in ipairs(sc.medPending) do
      if type(row) == "table" and row.kind == "vfx" and type(row.spec) == "table" then
        looks = looks + 1
        style = row.spec.style
      end
    end
    eq(looks, 1, "K20 (co-op): an X item is one look, not the bag's and the cart's")
    eq(style, "sparkle", "K20 (co-op): ...XSTATITEM_ANIM's")
    -- ...and a Gold residual id has a look on its seat.
    ev(sc, { t = "anim", slot = 2, side = "b", text = "IN_SANDSTORM_ANIM" })
    local last = sc.medPending[#sc.medPending]
    check(type(last) == "table" and last.kind == "vfx" and last.spec and last.spec.palette == "ROCK",
          "K20 (co-op): a Gold residual clip wears its look")
  end

  -- K21: the Gold wild foe's weight and the fight's battle type.
  do
    local sc = seat5(2, nil, "coop_wild")
    sc.game.data = setmetatable({ gen2Pokedex = { entries = { [SPECIES] = { weight = 77 } } } },
      { __index = sc.game.data })
    sc.wildCatchMon = mon(50, 20)
    sc.wildParty = nil
    eq(sc:wildMons()[1].weight, 77, "K21 (co-op Gold): the wild foe's sheet carries its dex weight")
    sc.medUploaded, sc.wildBattleType = false, 4
    for k in pairs(sc.sent) do sc.sent[k] = nil end
    sc:uploadMediated()
    local rules = sc.firstSent(Wire.BATTLE_RULESET)
    eq(rules and rules.battleType, 4, "K21 (co-op Gold): the ruleset states the wild fight's battle type")
  end

  -- K16: the co-op host's NPC upload carries the class data and no bag.
  do
    local sc = seat5(2)
    local npc
    for _, m in ipairs(sc.sent) do
      if m.type == Wire.BATTLE_PARTY and m.payload.side == "b" then npc = m.payload end
    end
    eq(npc and npc.bag, nil, "K16 (co-op Gold): the NPC upload carries no bag")
  end

  -- ------------------------------------------------------------------
  -- wave 2: K17's side-word marks, K22's quiet animations and the used
  -- line's seat, the new cart ids, K23's count-as-species types (co-op)
  -- ------------------------------------------------------------------
  local CB = need("ClassicBattle")
  do
    local sc = seat5(2)
    eq(sc:medViewLine("^APOK\195\169MON's\nLIGHT SCREEN fell!"), "Your POK\195\169MON's\nLIGHT SCREEN fell!",
       "K17 (co-op Gold): our side's screen line says Your (HandleScreens .Your)")
    eq(sc:medViewLine("^BPOK\195\169MON's\nLIGHT SCREEN fell!"), "Enemy POK\195\169MON's\nLIGHT SCREEN fell!",
       "K17 (co-op Gold): ...the trainer's says Enemy")
    local slots = pvpSlots()
    local pv = screen({ slots = slots, mine = 3, host = false, mode = "coop_pvp", selfId = "cal" })
    pv.mediated = true
    pv.medSlots = { [0] = 1, [1] = 2, [2] = 3, [3] = 4 }
    pv.medFields = { [1] = 0, [2] = 1, [3] = 2, [4] = 3 }
    eq(pv:medViewLine("^AX ^BY"), "Enemy X Your Y", "K17 (coop_pvp, side b): side b is this seat's own")
    eq(CB.plainLine("^AX ^BY"), "X Y", "K17: the matchers read no side word")
  end

  -- K22: the used line names its seat, so a missed move's shout (no
  -- animation row ahead of it) goes over the monster that used it.
  do
    local slots = npcSlots()
    slots[2].party[1].species = "FIXMON_B"
    local sc = seat5(1, nil, nil, slots)
    local bName = Wire.name(data.pokemon.FIXMON_B.name)
    local function fromOf(text)
      local rows = sc:medRows({ battle = "cb1", seq = 1, t = "msg", text = text })
      local last = rows[#rows]
      return type(last) == "table" and last.from or nil
    end
    eq(fromOf("^a" .. bName .. "\nused FIX TACKLE!"), 2, "K22 (co-op): the partner's used line is the partner's seat")
    eq(fromOf("^a" .. SPECIES_NAME .. "\nused FIX TACKLE!"), 1, "K22 (co-op): ...ours is ours")
    eq(fromOf("^b" .. SPECIES_NAME .. "\nused FIX TACKLE!"), nil,
       "K22 (co-op): two namesakes on the trainer's side are no reading (the shout stays where it was)")
    eq(fromOf("^a" .. SPECIES_NAME .. "'s\nattack missed!"), nil, "K22 (co-op): only a used line names a seat")
    -- The shout itself, raised by that line when it is shown.
    sc.usesBattlefield = function() return true end
    sc.messages, sc.shown, sc.battlefieldBubbles, sc.calloutShout = {}, nil, nil, nil
    sc.acting = 1
    sc.messages[1] = { text = "^a" .. bName .. "\nused FIX TACKLE!", from = fromOf("^a" .. bName .. "\nused FIX TACKLE!") }
    sc.messages[1].text = sc:medViewLine(sc.messages[1].text)
    pcall(sc.update, sc, 1 / 60)
    eq(sc.calloutShout and sc.calloutShout.slot, 2, "K22 (co-op): the missed move's shout is over the partner")
  end

  -- K22: a quiet animation shouts nothing and plays its look alone.
  do
    local sc = seat5(1)
    sc.usesBattlefield = function() return true end
    local rows = sc:medRows({ battle = "cb1", seq = 1, t = "anim", slot = 2, side = "b", text = "FIX_TACKLE",
                              quiet = true })
    local row = rows[1]
    eq(row and row.quiet, true, "K22 (co-op): the anim row says quiet")
    sc.battlefieldBubbles, sc.calloutShout = nil, nil
    eq(sc:splitCalloutBeat({ kind = "anim", anim = "FIX_TACKLE", from = 3, quiet = true }), false,
       "K22 (co-op): no callout beat for a quiet row")
    eq(sc.battlefieldBubbles, nil, "K22 (co-op): ...and no bubble")
    sc.fx = nil
    sc:startQuietAnim({ anim = "FIX_TACKLE", from = 3, quiet = true }, 3)
    local look, lunge
    for _, e in ipairs(sc.fx or {}) do
      if e.kind == "vfx" then look = e end
      if e.kind == "lunge" then lunge = e end
    end
    check(look ~= nil and look.slot == 3 and look.delivery == "self",
          "K22 (co-op): the look plays in place on the seat the event names")
    eq(lunge, nil, "K22 (co-op): ...with no lunge")
    -- FLY's charge as a quiet TELEPORT hides the seat; a quiet FLY on it
    -- brings it back with no strike.
    sc.fx = nil
    sc:startQuietAnim({ anim = "TELEPORT", from = 1, quiet = true }, 1)
    eq(sc.vanishFlow and sc.vanishFlow[1], "fly", "K22 (co-op): a quiet TELEPORT is FLY's charge")
    sc:startQuietAnim({ anim = "FLY", from = 1, quiet = true }, 1)
    eq(sc.vanishFlow and sc.vanishFlow[1], nil, "K22 (co-op): a quiet FLY on the hidden seat shows it again")
  end

  -- K22: new ids -- SLIDE_DOWN_ANIM hides, BLOCKBALL_ANIM's knock lands where
  -- the ball went, a charge turn's XSTATITEM_ANIM takes no bag look over.
  do
    local sc = seat5(1)
    sc.usesBattlefield = function() return true end
    sc.medPending = {}
    local rows = sc:medRows({ battle = "cb1", seq = 1, t = "anim", slot = 0, side = "a", text = "BLOCKBALL_ANIM" })
    local knock = rows[#rows]
    check(type(knock) == "table" and knock.kind == "vfx" and knock.slot ~= 1,
          "K22 BLOCKBALL_ANIM (co-op): the knock plays on the seat the ball was thrown at")
    pcall(sc.startAnim, sc, { anim = "SLIDE_DOWN_ANIM", from = 1 })
    eq(sc.vanishFlow and sc.vanishFlow[1], "dig", "K22 SLIDE_DOWN_ANIM (co-op): the monster sinks, as DIG")
    pcall(sc.startAnim, sc, { anim = "STATUS_AFFECTED_ANIM", from = 1 })
    eq(sc.vanishFlow and sc.vanishFlow[1], nil, "K22 (co-op): STATUS_AFFECTED_ANIM shows it again")
    -- XSTATITEM_ANIM with no item straight ahead of it.
    sc.medPending = {}
    ev(sc, { t = "item", slot = 0, side = "a", text = "X_ATTACK" })
    ev(sc, { t = "anim", slot = 2, side = "b", text = "NOT_A_LOOK_ANIM" })
    ev(sc, { t = "anim", slot = 0, side = "a", text = "XSTATITEM_ANIM" })
    local looks = 0
    for _, row in ipairs(sc.medPending) do
      if type(row) == "table" and row.kind == "vfx" then looks = looks + 1 end
    end
    eq(looks, 2, "K22 (co-op): an XSTATITEM_ANIM not straight behind its seat's item keeps the bag's look")
  end

  -- K22 and the Bide reading: a used line's own mark says whose it is, and a
  -- called BIDE is read off its line (BideEffect's turn-1 clip is
  -- XSTATITEM_ANIM, so no BIDE animation names it any more).
  do
    local function bider(moves)
      local lead = mon(60, 40)
      lead.moves = moves or { { id = "FIX_TACKLE", pp = 20 }, { id = "FIX_BIDE", pp = 10 } }
      return lead
    end
    local slots = npcSlots()
    slots[2].party[1].species = "FIXMON_B"
    local bName = Wire.name(data.pokemon.FIXMON_B.name)
    local sc = seat5(1, { bider() }, nil, slots)
    ev(sc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    sc:commit({ slot = 1, move = 2, target = 3 })
    ev(sc, { t = "msg", text = "^b" .. SPECIES_NAME .. "\nused BIDE!" })
    ev(sc, { t = "turn", amount = 2 })
    check(not sc.bideLocked, "K22 Bide (Red co-op): the foe's marked line is not ours, with no animation ahead of it")
    sc:commit({ slot = 1, move = 2, target = 3 })
    ev(sc, { t = "msg", text = "^a" .. SPECIES_NAME .. "\nused BIDE!" })
    ev(sc, { t = "anim", slot = 0, side = "a", text = "XSTATITEM_ANIM" })
    ev(sc, { t = "turn", amount = 3 })
    check(sc.bideLocked == true, "K22 Bide (Red co-op): our own marked line starts ours, the clip behind it")
    -- A quiet animation names nobody's line.
    local seqBefore = sc.medAnimSeq
    ev(sc, { t = "anim", slot = 2, side = "b", text = "FIX_TACKLE", quiet = true })
    eq(sc.medAnimSeq, seqBefore, "K22 Bide (co-op): a quiet animation is passed over")
    -- A MIRROR MOVE that called BIDE, read off the called move's line.
    local mc = seat5(1, { bider({ { id = "FIX_MIRROR", pp = 20 } }) }, nil, (function()
      local s2 = npcSlots(); s2[2].party[1].species = "FIXMON_B"; return s2 end)())
    ev(mc, { t = "send", slot = 0, side = "a", mon = 0, text = SPECIES_NAME, hp = 60 })
    mc:commit({ slot = 1, move = 1, target = 3 })
    ev(mc, { t = "msg", text = "^a" .. bName .. "\nused BIDE!" })
    check(mc.callFiled == 1 and not mc.bideFiled, "K22 Bide (co-op): the partner's BIDE line is not our call's")
    ev(mc, { t = "msg", text = "^a" .. SPECIES_NAME .. "\nused MIRROR MOVE!" })
    ev(mc, { t = "msg", text = "^a" .. SPECIES_NAME .. "\nused BIDE!" })
    ev(mc, { t = "turn", amount = 2 })
    check(mc.bideLocked == true, "K22 Bide (co-op): a called BIDE's own line files and starts it")
  end

  -- K23: the co-op host's Gold NPC upload states the count-as-species types.
  do
    local slots = npcSlots()
    slots[3].party = { mon(50, 20) }
    slots[4].party = { mon(50, 19) }
    local sc = seat5(2, nil, nil, slots)
    local npc
    for _, m in ipairs(sc.sent) do
      if m.type == Wire.BATTLE_PARTY and m.payload.side == "b" then npc = m.payload end
    end
    local want = Mediated.countSpeciesTypes2(sc.game, 2)
    check(type(want) == "table" and #want >= 1, "K23 (co-op Gold): the fixture has a species numbered 2")
    eq(npc and table.concat(npc.countSpeciesTypes or {}, ","), table.concat(want or {}, ","),
       "K23 (co-op Gold): the NPC upload states the types of the species numbered its size")
    local red = seat5(1, nil, nil, npcSlots())
    local redNpc
    for _, m in ipairs(red.sent) do
      if m.type == Wire.BATTLE_PARTY and m.payload.side == "b" then redNpc = m.payload end
    end
    eq(redNpc and redNpc.countSpeciesTypes, nil, "K23 (co-op Red): none")
  end
end

T.finish("coop_mediated")
