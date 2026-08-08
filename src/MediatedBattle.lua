-- The client half of a mediated 1v1: a screen that sends choices and draws
-- what it is told.
--
-- **Nothing in this file decides anything about the fight.**  That is the whole
-- point of it.  Until PROTOCOL 10 an MMO battle was the engine's own
-- `LinkBattle` running in lockstep inside both players' processes over
-- `SessionNet`, which meant the arithmetic of a fight lived on the same side of
-- the wire as the person who benefits from getting it wrong -- and it meant the
-- two copies had to agree about their content before they were allowed to
-- start, which is what `Sessions.canBattle` and the fingerprint were for.  The
-- intermediator (the Node hub, or a LAN host running `src/BattleSim/`) now owns
-- hit, crit, damage, status and the outcome, so this side is reduced to three
-- jobs:
--
--   1. upload what we are bringing -- `mmo.battle_party`, and on the host
--      `mmo.battle_ruleset` -- before the fight opens;
--   2. put a choice on the wire when a turn opens;
--   3. apply the ordered `mmo.battle_event` stream to a screen.
--
-- Everything the sim needs about a monster therefore rides on (1), because
-- there is no move table and no type chart on either intermediator and there
-- must never be one: those are the player's own decoded ROM, and this repo may
-- not carry them (see the legal posture in CLAUDE.md).  A move brings its own
-- power and accuracy; the chart is uploaded for one match and thrown away with
-- it.
--
-- Because the fingerprint gate is gone, two players whose copies disagree can
-- now fight -- a Red against a Yellow, a data pack against vanilla.  What they
-- are agreeing on instead is *this upload*: the host's chart decides the
-- matchups and each side's own records decide its own moves.  That is a real
-- change in what a battle means and it is deliberate; the residual is that a
-- modified client can lie on the sheet it sends, which is the accepted v1
-- surface written down in src/Wire.lua's mediated-battle section.
--
-- The screen is deliberately small.  It draws two status boxes and a message
-- box, and its only menu is the move list -- no items, no switching, no run
-- consent.  A fuller field belongs with the co-op renderer (I3c); what this
-- owes today is that a fight can be started, played and finished without the
-- engine's link stack being loaded at all.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")

local M = {}
M.__index = M

local floor, max, min = math.floor, math.max, math.min

-- ------- the engine, loaded once and never at file scope
--
-- Lazily and behind pcall, for the reason src/CoopBattle.lua loads its own
-- renderer that way: `modkit validate` loads this file headlessly with no love
-- and no data, and the mod's suite drives the whole exchange with no engine at
-- all.  A build that cannot draw still uploads, still sends choices and still
-- hears the outcome -- it simply has nothing to paint, which is a far better
-- failure than a battle that cannot start.
local engine, engineTried

local function loadEngine()
  if engineTried then return engine end
  engineTried = true
  local ok, Font = pcall(require, "src.render.Font")
  if not ok then
    mod.log:warn("the engine's font module is unavailable, so a mediated "
      .. "battle cannot be drawn; the fight still runs -- report this with "
      .. "the game version")
    engine = false
    return engine
  end
  -- Optional, and separately: the HP bar is the game's own tiles, but a build
  -- that cannot draw one still has a number to print.  A missing bar costs a
  -- nicer readout; a missing font costs the screen.
  local okTiles, HudTiles = pcall(require, "src.render.HudTiles")
  engine = { Font = Font, HudTiles = okTiles and HudTiles or nil }
  return engine
end

-- ------- snapshots
--
-- What this client claims it is bringing, in the shapes src/Wire.lua sanitises.
-- Both halves are built from `game.data` -- the player's own decoded copy --
-- and neither is stored anywhere past the match.

-- The widest neutral chart to offer when there is no type table to read.
--
-- A fallback rather than a default: a build with no `type_chart` has no
-- matchups to state, and a chart of nothing but neutral cells says exactly
-- that.  Sixteen is comfortably above Gen 1's fifteen types and comfortably
-- inside Config.BATTLE_TYPE_MAX, so a move naming any type this client could
-- have produced still finds a row -- and every row reads 100, which is the
-- honest answer for a client that does not know the matchups.
M.NEUTRAL_TYPES = 16

-- The engine spells a type as an id ("NORMAL"); the wire spells it as a small
-- integer, because the chart that crosses it is a rectangle of numbers and a
-- move names its own type by index into that rectangle.
--
-- **The ordering has to be the same on both clients, and nothing on the wire
-- states it.**  The host uploads the chart and the guest uploads moves carrying
-- indices into it, so a guest that ordered its types differently would have
-- every matchup read off the wrong row -- silently, and only for its own moves.
-- A plain sort of the ids is what makes that agree: two copies with the same
-- type set produce the same list whatever order their tables happened to
-- iterate in, and Lua's `pairs` order is not something either side may rely on.
--
-- Two copies with *different* type sets still disagree, and that is the
-- residual the fingerprint gate used to cover.  It is accepted rather than
-- fixed here: refusing the fight would put the mods-incompatibility refusal
-- back, which is the thing PROTOCOL 10 exists to remove.
--
-- Memoised against the data table itself and weakly, so a hot reload that
-- rebuilds `game.data` does not keep the old ordering alive.  `false` is
-- cached for a build with no chart at all, so the walk is not repeated per
-- battle.
local typeOrderCache = setmetatable({}, { __mode = "k" })

local function typeOrder(data)
  if type(data) ~= "table" then return nil end
  local hit = typeOrderCache[data]
  if hit ~= nil then return hit or nil end

  local chart = type(data.type_chart) == "table" and data.type_chart or nil
  if not chart then
    typeOrderCache[data] = false
    return nil
  end

  local seen, ids = {}, {}
  local function note(id)
    if type(id) ~= "string" or id == "" or seen[id] then return end
    seen[id] = true
    ids[#ids + 1] = id
  end
  -- The registry's own type records first, then anything a matchup row names
  -- that they missed: a data pack may register a matchup against a type it
  -- did not also describe, and a type with no row is still a type a move can
  -- claim.
  if type(chart.types) == "table" then
    for id in pairs(chart.types) do note(id) end
  end
  if type(chart.matchups) == "table" then
    for _, row in ipairs(chart.matchups) do
      if type(row) == "table" then note(row.attacker); note(row.defender) end
    end
  end

  if #ids == 0 then
    typeOrderCache[data] = false
    return nil
  end
  table.sort(ids)
  -- Config.BATTLE_TYPE_MAX bounds both axes of the chart, and Wire refuses a
  -- wider one outright.  Cutting the tail is what keeps an over-wide pack
  -- fighting: the types that survive keep their matchups, and a move naming
  -- one that did not is read as neutral by the sim rather than refusing
  -- somebody's whole team.
  for i = #ids, Config.BATTLE_TYPE_MAX + 1, -1 do ids[i] = nil end

  local index = {}
  for i = 1, #ids do index[ids[i]] = i - 1 end

  local out = { ids = ids, index = index }
  typeOrderCache[data] = out
  return out
end

M.typeOrder = typeOrder

-- The ephemeral rules for one match: the type chart, as integer percent.
--
-- The engine's table holds x10 multipliers (5 is half, 20 is double, 0 is
-- immune) and states only the matchups that are not neutral; the wire wants a
-- full rectangle of percent, because a fraction that crossed a JSON boundary
-- into two languages would round differently on the two ends and the same
-- attack would hit for different amounts depending on who was hosting.  So the
-- rectangle is filled with EFF_NEUTRAL and the stated rows are written over it.
function M.snapshotRuleset(game)
  local data = game and game.data
  local order = typeOrder(data)
  local width = order and #order.ids or M.NEUTRAL_TYPES

  local chart = {}
  for i = 1, width do
    local row = {}
    for j = 1, width do row[j] = Wire.EFF_NEUTRAL end
    chart[i] = row
  end

  if order and type(data.type_chart.matchups) == "table" then
    for _, entry in ipairs(data.type_chart.matchups) do
      if type(entry) == "table" then
        local attacker = order.index[entry.attacker]
        local defender = order.index[entry.defender]
        local mult = tonumber(entry.multiplier)
        if attacker and defender and mult then
          chart[attacker + 1][defender + 1] =
            min(Wire.CHART_MAX, max(0, floor(mult * 10)))
        end
      end
    end
  end

  -- No seed: the intermediator is the only party that rolls anything and can
  -- perfectly well pick its own.  Offering one would be claiming a say in the
  -- randomness that this side deliberately no longer has.
  return { chart = chart }
end

local function intOr(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function clamp(value, low, high)
  return min(high, max(low, value))
end

-- What the sim needs to resolve one move, read off the player's own move
-- record.
--
-- `accuracy` is converted rather than copied: the engine keeps a percent and
-- Gen 1 compares an 8-bit value against a 0-255 roll, which is the whole
-- mechanism behind the 1-in-256 miss -- `floor(acc * 255 / 100)` is the
-- conversion the engine's own `Damage.accuracyRoll` does, so a mediated fight
-- misses exactly as often as the same fight played offline.
--
-- `effect` and `chance` go out as 0, and that is honest rather than lazy: the
-- engine names an effect with a string id ("NO_ADDITIONAL_EFFECT") while the
-- wire carries a number, there is no shared numbering for the two to agree on,
-- and `src/BattleSim/Turn.lua` branches on neither today.  Inventing a mapping
-- here would be inventing a rule the far end cannot read.
--
-- The defaults are what a client with no record for a move sends -- a modded
-- move whose definition did not survive, most likely.  40 power at full
-- accuracy on type 0 is a plain hit: weaker than assuming the best and far
-- better than refusing the move, which would refuse the monster and then the
-- whole party.
local function moveOf(data, slot, order)
  if type(slot) ~= "table" then return nil end
  local id = Wire.id(slot.id)
  if not id then return nil end

  local def = type(data) == "table" and type(data.moves) == "table"
    and data.moves[slot.id] or nil

  local accuracy = 255
  if def and tonumber(def.accuracy) then
    accuracy = clamp(floor(tonumber(def.accuracy) * 255 / 100), 0, 255)
  end

  local typeId = 0
  if order and def and order.index[def.type] then typeId = order.index[def.type] end

  return {
    id       = id,
    pp       = clamp(intOr(slot.pp, 0), 0, 99),
    power    = clamp(intOr(def and def.power, 40), 0, 999),
    accuracy = accuracy,
    type     = typeId,
    effect   = 0,
    chance   = 0,
  }
end

-- The four stats Gen 1 fights with, from the five the engine stores.
--
-- SPC is one stat and not two: Special did not split until Gen 2, so a
-- snapshot carrying spa/spd would be describing a different game's battler.
-- HP is absent because it rides as `maxHp`.
--
-- Clamped rather than refused, which is the opposite of what Wire does with the
-- same numbers and is right on this side of the boundary: Wire is judging a
-- stranger's claim and a number out of range there means the sender is not to
-- be believed, while here the number is our own truth and the only alternative
-- to trimming it is uploading a party the far end throws away whole -- a
-- player losing a fight they never got to start, over a stat nothing can fight
-- with anyway.
local function statsOf(mon)
  local stats = type(mon.stats) == "table" and mon.stats or nil
  if not stats then return nil end
  return {
    atk = clamp(intOr(stats.attack, 1), 1, Wire.STAT_MAX),
    def = clamp(intOr(stats.defense, 1), 1, Wire.STAT_MAX),
    spd = clamp(intOr(stats.speed, 1), 1, Wire.STAT_MAX),
    spc = clamp(intOr(stats.special, 1), 1, Wire.STAT_MAX),
  }
end

-- A full set of the four or nothing at all, on Wire's own rule: a snapshot
-- from a client that does not track DVs is ordinary, while one carrying two of
-- the four is a bug on this side that the far end would silently zero the rest
-- of.
local function fourOf(raw, low, high)
  if type(raw) ~= "table" then return nil end
  local out = {}
  local keys = { atk = "attack", def = "defense", spd = "speed", spc = "special" }
  for wireKey, engineKey in pairs(keys) do
    local n = tonumber(raw[engineKey])
    if not n or n ~= n then return nil end
    out[wireKey] = clamp(floor(n), low, high)
  end
  return out
end

-- What this monster is called on the other player's screen.
--
-- The nickname when it has one, then the species record's display name, then
-- the raw id.  The display name is what the game itself prints, and it is the
-- one of the three that survives Wire.name intact for the species whose ids
-- carry punctuation the sanitiser drops.
local function speciesName(data, mon)
  local def = type(data) == "table" and type(data.pokemon) == "table"
    and data.pokemon[mon.species] or nil
  local name = mon.nickname
  if type(name) ~= "string" or name == "" then name = def and def.name end
  if type(name) ~= "string" or name == "" then name = mon.species end
  return Wire.name(name)
end

-- The types a species has, as indices into the uploaded chart.
--
-- Both sanitisers carry the field now -- `Wire.battleMon` and its JS twin keep a
-- present-and-readable `types` and refuse the battler outright when it is
-- present and unreadable, on the same rule a half-filled EV block gets -- so a
-- matchup and STAB apply to a mediated fight the way they do to a local one.
-- The indices are into *this match's* uploaded chart rather than into anything
-- shipped here, which is the whole reason they are numbers: the chart came from
-- the player's own decoded copy and is thrown away with the battle.  A monster
-- whose species this client cannot describe sends no types at all, and the sim
-- reads that absence as neutral rather than refusing the party.
local function typesOf(data, mon, order)
  if not order then return nil end
  local def = type(data) == "table" and type(data.pokemon) == "table"
    and data.pokemon[mon.species] or nil
  if not (def and type(def.types) == "table") then return nil end
  local out = {}
  for _, id in ipairs(def.types) do
    local index = order.index[id]
    if index then out[#out + 1] = index end
  end
  if #out == 0 then return nil end
  return out
end

-- Any team, as the intermediator will fight it.
--
-- Split out from `snapshotParty` because a co-op fight has more than one team
-- to describe from one client: src/CoopBattle.lua uploads its own party *and*,
-- when it is the host of a battle against an NPC, the trainer's -- and neither
-- of those two is `game.save.party`.  `game` is still handed in whole because
-- what a monster looks like on the wire is read off the player's own `data`
-- (the move records, the species names, the type ordering) whoever owns the
-- monster.
--
-- Best-effort throughout: a monster that cannot be described is skipped rather
-- than taking the party with it, because a party of five is a fight and a party
-- of none is not.  An empty result is the caller's to refuse -- see M:start.
function M.snapshotMons(game, party)
  if type(party) ~= "table" then return {} end

  local data = game and game.data
  local order = typeOrder(data)

  local out = {}
  for index = 1, #party do
    if #out >= Config.BATTLE_MON_MAX then break end
    local mon = party[index]
    if type(mon) == "table" then
      local stats = statsOf(mon)
      local species = speciesName(data, mon)
      if stats and species then
        local maxHp = clamp(intOr(mon.stats and mon.stats.hp, 1), 1, Wire.HP_MAX)
        local moves = {}
        for _, slot in ipairs(mon.moves or {}) do
          if #moves >= Config.BATTLE_MOVE_MAX then break end
          local move = moveOf(data, slot, order)
          if move then moves[#moves + 1] = move end
        end
        if #moves > 0 then
          out[#out + 1] = {
            species = species,
            level   = clamp(intOr(mon.level, 1), 1, Wire.LEVEL_MAX),
            hp      = clamp(intOr(mon.hp, maxHp), 0, maxHp),
            maxHp   = maxHp,
            stats   = stats,
            -- The engine spells a condition with the same three-letter token
            -- the wire does ("SLP", "PSN", ...), so this passes through rather
            -- than being translated.  nil is healthy and is a real answer.
            status  = Wire.battleStatus(mon.status) or nil,
            slot    = clamp(index - 1, 0, Wire.SLOT_MAX),
            ivs     = fourOf(mon.dvs, 0, 15),
            evs     = fourOf(mon.statExp, 0, 65535),
            types   = typesOf(data, mon, order),
            moves   = moves,
          }
        end
      end
    end
  end
  return out
end

-- This player's own team.
function M.snapshotParty(game)
  local save = game and game.save
  return M.snapshotMons(game, save and save.party)
end

-- ------- what goes out before the fight opens, in one place
--
-- Two senders and one validator, shared with src/CoopBattle.lua rather than
-- copied into it.  The uploads are the only thing a client says that decides
-- what the fight *is* -- there is no move table and no chart on either
-- intermediator -- so a second copy of "how a party is put on the wire" is a
-- second place for a 1v1 and a 2-on-2 to start describing the same monster
-- differently.

-- The host's chart, and nobody else's.  Not because a guest's would be worse,
-- but because two charts is a fight with no answer to "which", and both
-- intermediators refuse a ruleset from anyone but the seat they brokered as
-- host.
function M.sendRuleset(transport, game)
  if not transport then return false end
  transport:send(Wire.BATTLE_RULESET, M.snapshotRuleset(game))
  return true
end

-- One seat's team.  `side` is optional for a 1v1 -- there are two combatants and
-- the intermediator knows which is which from the session it brokered -- and is
-- what tells a co-op upload apart: it is how the host of a fight against an NPC
-- fills the synthetic npc seat (side "b") without displacing its own.
function M.sendParty(transport, battle, mons, side)
  if not (transport and battle) then return false end
  if type(mons) ~= "table" or #mons == 0 then return false end
  transport:send(Wire.BATTLE_PARTY,
    { battle = battle, mons = mons, side = side })
  return true
end

-- One turn's intent.  A choice and never a result: the fields name what was
-- pressed, and what it costs is the intermediator's to decide.
--
-- Checked before it goes rather than after it is refused: both hubs answer a
-- malformed choice with silence, and silence at a battle screen is a turn the
-- player believes they spent.
function M.submitChoice(transport, battle, fields)
  if not (transport and battle) then return false end
  local out = { battle = battle }
  for key, value in pairs(fields or {}) do out[key] = value end
  if not Wire.battleChoice(out) then
    mod.log:warn("a battle choice would not have been understood and was not "
      .. "sent; press again, or wait for the turn clock")
    return false
  end
  transport:send(Wire.BATTLE_CHOICE, out)
  return true
end

-- Is `id` in this list of player ids?
--
-- Exported because an outcome is read by asking it twice, and both screens ask:
-- a 1v1 asks about the peer (the side they are not on is ours) and a 2-on-2
-- asks about itself (there are four ids and no single "other side").
function M.holds(list, id)
  if id == nil then return false end
  for _, entry in ipairs(list or {}) do
    if entry == id then return true end
  end
  return false
end

-- ------- the fight

-- How long a freshly shown line is safe from the button that dismisses it, and
-- how long it stays up when nobody presses anything.  CoopBattle's numbers and
-- CoopBattle's argument: a player holding A through a battle -- which is every
-- player -- otherwise swallows lines they never saw.
local MSG_MIN_DWELL = 0.25
local MSG_AUTO_ADVANCE = 1.6

-- Side a takes field slot 0 and side b takes slot 2.  Mirrored from
-- src/BattleSim/events.lua's numbering rather than derived, because it is the
-- numbering every event on the wire is already stated in: a 1v1 leaves the odd
-- slots empty so that "which box is this" does not change meaning with the
-- mode.
local function slotOfSide(side) return side == "b" and 2 or 0 end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    transport = opts.transport,
    ui        = opts.ui,
    game      = opts.game,
    battle    = opts.battle,
    role      = opts.role,
    peerId    = opts.peerId,
    peerName  = opts.peerName or "FRIEND",
    onDone    = opts.onDone,

    -- A test hook, and named as one.  With it set, a turn is answered the
    -- instant it opens with the first move at the default target, which is
    -- what lets the headless suite drive a whole fight with no input device.
    -- It is never set in the game: the intermediator already auto-picks for a
    -- player who says nothing before BATTLE_CHOICE_TIMEOUT, so a client that
    -- silently picked as well would be spending turns the player is still
    -- thinking about.
    autoPick  = opts.autoPick == true,

    -- What src/Sessions.lua's isFightState looks for.  A mediated battle is
    -- not a BattleState and carries none of the engine's markers, so without
    -- this an invite could pop over a live fight.
    mmoBattle = true,

    phase     = "setup",   -- setup | play | choose | over
    uploaded  = false,
    finished  = false,
    left      = false,
    mine      = nil,       -- our own snapshot, which the move menu reads
    active    = 1,         -- which of ours is out, as an index into `mine`
    mySide    = (opts.role == "guest") and "b" or "a",
    slots     = {},        -- field slot -> { species, hp, maxHp }
    lines     = {},
    shown     = nil,
    dwell     = 0,
    cursor    = 1,
    seq       = 0,         -- the highest event sequence applied
    gaps      = 0,         -- events that arrived out of order
    pendingTurn = false,
    result    = nil,
    -- Set while the hub link is down under a live fight: the intermediator's
    -- reconnect grace is running, and onTransportReady is what resumes it.
    awaitingReconnect = false,
    reconnectSent = false,
  }, M)
end

function M:say(text)
  if type(text) ~= "string" or text == "" then return end
  self.lines[#self.lines + 1] = text
end

function M:mySlot() return slotOfSide(self.mySide) end
function M:foeSlot() return slotOfSide(self.mySide == "a" and "b" or "a") end

-- Upload what we are bringing.  Idempotent, because two things call it: the
-- session, the moment the hub pairs us, and `enter`, when the screen actually
-- goes up.  The session's call is the one that matters -- it is what lets the
-- suite drive the exchange with no state stack at all -- and `enter` is the
-- belt for a screen pushed by some other route.
function M:start(game)
  if game then self.game = game end
  if self.uploaded then return true end
  if not (self.transport and self.battle) then return false end

  local mons = M.snapshotParty(self.game)
  if #mons == 0 then
    -- Uploading nothing would leave the intermediator holding a seat open
    -- until its grace expired, and the player watching a screen that never
    -- starts.  Ended here instead, with the reason on it.
    mod.log:warn("no POKeMON could be described for a mediated battle, so "
      .. "there is nothing to fight with -- check the party from START > "
      .. "POKeMON, and report this if it is not empty")
    self.uploaded = true
    self:say("You have no POKeMON\nto battle with!")
    self:finish("draw", "gone")
    return false
  end

  self.uploaded = true
  self.mine = mons

  if self.role == "host" then M.sendRuleset(self.transport, self.game) end
  -- No side: a 1v1 has none to name.
  M.sendParty(self.transport, self.battle, mons)
  return true
end

-- ------- inbound

-- The field is assembled and the first turn is open.
--
-- The sides are read back rather than assumed, and the peer's id is what
-- decides them: this client does not carry its own hub id down here, but it
-- does know who it is fighting, so "the side the peer is not on is mine" is an
-- answer that needs nothing else.  The role is the fallback for a hub that
-- named the sides some other way -- the asker hosts, and the hub seats the
-- asker on side a.
function M:onReady(msg)
  if self.finished then return end
  if msg.battle ~= self.battle then return end

  local function holds(list, id)
    for _, entry in ipairs(list or {}) do
      if entry == id then return true end
    end
    return false
  end
  local sides = msg.sides or {}
  if self.peerId then
    if holds(sides.b, self.peerId) then
      self.mySide = "a"
    elseif holds(sides.a, self.peerId) then
      self.mySide = "b"
    end
  end

  if self.phase == "setup" then
    self.phase = "play"
    self:say(("%s wants to\nfight!"):format(self.peerName))
  end
end

-- One thing to draw, in order.
--
-- `seq` is what makes the stream a stream: an event whose sequence is one this
-- side has already passed is a duplicate and is dropped, and a jump forward is
-- counted rather than refused.  Refusing the jump would leave the screen
-- waiting on a message that is not coming; counting it means the gap is
-- visible in a log if a hub really is losing messages, while the fight -- whose
-- state lives on the intermediator anyway -- carries on from what did arrive.
function M:onEvent(msg)
  if self.finished then return end
  if msg.battle ~= self.battle then return end
  if msg.seq <= self.seq then return end
  if msg.seq > self.seq + 1 and self.seq > 0 then
    self.gaps = self.gaps + 1
  end
  self.seq = msg.seq

  if self.phase == "setup" then self.phase = "play" end

  local kind = msg.t
  if kind == "msg" then
    self:say(msg.text)

  elseif kind == "send" or kind == "switch" then
    -- The first HP we are told about is a full bar: the sim sends this the
    -- moment a monster comes out, so the number is that monster's maximum
    -- unless it walked in already hurt.  It is the only handle on a foe's
    -- maximum there is -- an event carries current HP and nothing else -- so
    -- the largest value ever seen is what the bar is drawn against.
    self:noteSlot(msg)
    if msg.text then
      if msg.slot ~= self:mySlot() then
        self:say(("%s sent out\n%s!"):format(self.peerName, msg.text))
      else
        self:say(("Go! %s!"):format(msg.text))
        self:trackActive(msg.text)
      end
    end

  elseif kind == "damage" or kind == "drain" then
    self:noteSlot(msg)

  elseif kind == "faint" then
    local slot = self:noteSlot(msg)
    if slot then slot.hp = 0 end
    if msg.text then self:say(("%s fainted!"):format(msg.text)) end

  elseif kind == "status" then
    self:noteSlot(msg)

  elseif kind == "turn" then
    -- Held rather than acted on: the lines this turn's events produced are
    -- still being read, and opening the menu over them would take the box the
    -- player is reading out from under them.  update() opens it once the
    -- queue is empty.
    self.pendingTurn = true

  elseif kind == "over" then
    -- The field is done; the outcome is a separate message and is what this
    -- screen actually ends on.
    self.pendingTurn = false

  elseif kind == "wait" then
    if msg.text then self:say(("Waiting for\n%s..."):format(msg.text)) end

  elseif kind == "reconnect" then
    -- Their return, or ours after we re-announced: either way the waiting
    -- caption is done.
    self.awaitingReconnect = false
    if msg.text then self:say(("%s is back!"):format(msg.text)) end
  end
end

-- Record whatever an event said about a field slot.  Every event that names one
-- carries the HP that slot is now on, so one place reads it and the screen
-- never has to guess.
function M:noteSlot(msg)
  local index = msg.slot
  if index == nil then return nil end
  local slot = self.slots[index]
  if not slot then
    slot = { species = nil, hp = 0, maxHp = 1 }
    self.slots[index] = slot
  end
  if msg.text and (msg.t == "send" or msg.t == "switch") then
    slot.species = msg.text
  end
  if msg.hp ~= nil then
    slot.hp = msg.hp
    if msg.hp > slot.maxHp then slot.maxHp = msg.hp end
  elseif msg.amount ~= nil and msg.t == "damage" then
    slot.hp = max(0, slot.hp - msg.amount)
  end
  if msg.status ~= nil then slot.status = msg.status end
  return slot
end

-- Which of ours is out, matched by the name the sim narrates it under.
--
-- Only the *name* crosses back, so a party holding two monsters with the same
-- one is matched to the first -- which is wrong only for the move list, and
-- only for a player who nicknamed two of their team identically.  The
-- alternative is tracking send-outs by counting faints, which is wrong more
-- often and more quietly.
function M:trackActive(species)
  for index, mon in ipairs(self.mine or {}) do
    if mon.species == species then
      self.active = index
      return
    end
  end
end

function M:activeMon()
  return self.mine and self.mine[self.active] or nil
end

-- How it ended, from the only party that knows.
--
-- **No mmo.result goes out for this fight.**  The dual-client vote exists
-- because neither peer in a relayed battle could be believed about its own
-- win; here the intermediator did every roll, so it says who won and both hubs
-- ignore a client's report about a battle they ran.  Sessions never records a
-- `lastBattle` on this path, which is what makes that structural rather than a
-- rule somebody has to remember.
function M:onOutcome(msg)
  if self.finished then return end
  if msg.battle ~= self.battle then return end
  self.pendingTurn = false
  self:finish(M.resultFor(msg, self.peerId), msg.reason)
end

-- This player's result, worked out from who is named rather than from the
-- outcome token.
--
-- `outcome` is stated from the *field's* point of view -- "win" means the
-- winners list won -- so it is the same value in both clients' copies of the
-- message and says nothing on its own about the recipient.  The peer's id is
-- what turns it into a sentence: the side they are not on is ours.  A draw
-- carries no lists at all (Wire refuses an empty one), which is why the
-- absence is read as a draw rather than as a missing field.
function M.resultFor(msg, peerId)
  if peerId then
    if M.holds(msg.winners, peerId) then return "loss" end
    if M.holds(msg.losers, peerId) then return "win" end
  end
  return "draw"
end

-- The same verdict read the other way round: from this client's *own* id.
--
-- A 1v1 can reason from the peer because there is exactly one of them.  A
-- 2-on-2 cannot -- four ids arrive, two of them allies -- so the only question
-- with a single answer is "am I named", and it is asked here rather than in the
-- co-op screen so both readings of one message live side by side.
function M.resultForSelf(msg, selfId)
  if selfId then
    if M.holds(msg.winners, selfId) then return "win" end
    if M.holds(msg.losers, selfId) then return "loss" end
  end
  return "draw"
end

local ENDINGS = {
  win  = "You won!",
  loss = "You lost!",
  draw = "It was a draw.",
}

-- Why it ended, for the reasons a sentence exists for.  An unknown token --
-- a newer intermediator naming something this build cannot phrase -- is
-- deliberately silent rather than printed raw: the result is the part that
-- matters and it has already landed.
local REASONS = {
  timeout    = "Nobody answered\nin time.",
  disconnect = "The link was lost.",
  run        = "Someone ran away!",
  forfeit    = "Someone gave up.",
}

function M:finish(result, reason)
  if self.finished then return end
  self.finished = true
  self.result = result or "draw"
  self.phase = "over"
  self.cursor = 1
  self:say(ENDINGS[self.result] or ENDINGS.draw)
  local why = REASONS[reason]
  if why then self:say(why) end
end

-- ------- outbound

-- The hub link came back under a fight that is still open.
--
-- Both hubs already run reconnect grace + sim.reconnect(); until PROTOCOL 10's
-- clients actually sent mmo.battle_reconnect, every drop rode to forfeit. This
-- is that message. Idempotent per drop cycle: Sessions / Coop call it when
-- transport:isReady() flips false→true, and the headless suite calls it
-- directly as notifyReconnect.
function M:onTransportReady()
  if self.finished or self.left then return false end
  if not (self.transport and self.battle) then return false end
  if self.reconnectSent then return false end
  self.reconnectSent = true
  self.awaitingReconnect = false
  self.transport:send(Wire.BATTLE_RECONNECT, { battle = self.battle })
  return true
end

function M:notifyReconnect()
  return self:onTransportReady()
end

-- The hub link dropped under a live fight. Narrate and wait: finishing here
-- would take the screen away before the intermediator's grace (or a reconnect)
-- can resolve it.
function M:onTransportLost()
  if self.finished or self.left then return end
  if self.awaitingReconnect then return end
  self.awaitingReconnect = true
  self.reconnectSent = false
  self:say("Connection lost.\nWaiting to reconnect...")
end

-- One turn's intent, through the shared sender so a 1v1 and a 2-on-2 put the
-- same shape on the wire.  What is left here is this screen's own bookkeeping:
-- the menu closes on a choice that actually went.
function M:sendChoice(fields)
  if self.finished then return false end
  if not M.submitChoice(self.transport, self.battle, fields) then return false end
  self.phase = "play"
  self.pendingTurn = false
  return true
end

-- FIGHT with the move at `index` (1-based here, zero-based on the wire).  No
-- target: a 1v1 has exactly one thing to hit, and the sim picks the first
-- living foe when none is named -- naming one would be a field slot this
-- screen would have to keep in step for no gain.
function M:pickMove(index)
  local mon = self:activeMon()
  local moves = mon and mon.moves
  if not (moves and moves[index]) then return false end
  return self:sendChoice({ action = "fight", move = index - 1 })
end

-- ------- the screen
--
-- enter/exit/update/draw is the whole of the engine's state interface, and
-- src/Ui.lua's RbyMmoState screen hands this object straight to the stack.

function M:enter()
  loadEngine()
  self:start(self.game)
end

function M:exit()
  if self.left then return end
  self.left = true
  if self.onDone then self.onDone(self.result or "draw") end
end

function M:leave()
  if self.game and self.game.stack then
    pcall(function() self.game.stack:pop() end)
  end
end

-- Advance the message queue.  Returns true while a line is still being read,
-- which is what holds the menu closed.
function M:tickMessages(dt, input)
  self.dwell = self.dwell + (dt or 0)

  if self.shown == nil then
    if #self.lines == 0 then return false end
    self.shown = table.remove(self.lines, 1)
    self.dwell = 0
    return true
  end

  local pressed = input
    and (input:wasPressed("a") or input:wasPressed("b"))
  if self.dwell >= MSG_AUTO_ADVANCE or (pressed and self.dwell >= MSG_MIN_DWELL) then
    self.shown = nil
    self.dwell = 0
  end
  return true
end

function M:update(dt)
  local input = self.game and self.game.input

  if self:tickMessages(dt, input) then return end

  if self.phase == "over" then
    -- Nothing left to read and the fight is done: A takes the screen down, and
    -- exit() is what tells the session to leave the hub's pairing.
    if input and input:wasPressed("a") then self:leave() end
    return
  end

  if self.pendingTurn and self.phase ~= "choose" then
    self.pendingTurn = false
    self.phase = "choose"
    self.cursor = 1
    if self.autoPick then
      self:pickMove(1)
      return
    end
  end

  if self.phase ~= "choose" or not input then return end

  local mon = self:activeMon()
  local moves = (mon and mon.moves) or {}
  if #moves == 0 then return end

  if input:wasPressed("up") then
    self.cursor = self.cursor > 1 and self.cursor - 1 or #moves
  elseif input:wasPressed("down") then
    self.cursor = self.cursor < #moves and self.cursor + 1 or 1
  elseif input:wasPressed("a") then
    self:pickMove(self.cursor)
  end
end

-- ------- drawing
--
-- Two status boxes and a message box, in the engine's own font and its own box
-- glyphs.  No field, no pictures and no animation: a wrong animation is worse
-- than none, and the co-op renderer is where a real field belongs.

-- One side's box: who is out, their condition, and the game's own HP bar.
--
-- The bar is HudTiles.drawHPBar and not an approximation of it, so a mediated
-- fight reads like every other fight in the game -- same tiles, same colour
-- thresholds.  It is called behind a pcall with a printed fallback, exactly as
-- CoopBattle calls it: it reaches into palettes and a build that cannot resolve
-- one should lose the bar and not the screen.
function M:drawSlot(Font, HudTiles, index, tileY, label)
  local slot = self.slots[index]
  Font.drawBox(0, tileY, 20, 4)
  love.graphics.setColor(0, 0, 0, 1)
  local top = (tileY + 1) * 8
  if not (slot and slot.species) then
    Font.draw(label, 16, top)
    return
  end

  Font.draw(slot.species:sub(1, 10), 16, top)
  if slot.status then Font.draw(slot.status, 16 + 11 * 8, top) end

  local shown = { hp = slot.hp, stats = { hp = slot.maxHp } }
  local drew = HudTiles and pcall(HudTiles.drawHPBar, self.game and self.game.data,
    2, tileY + 2, shown, nil, false, 6)
  if not drew then
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(("%d/%d"):format(slot.hp, slot.maxHp), 16, top + 16)
  end
end

function M:drawBox(Font, text)
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local y = 112
  for line in tostring(text or ""):gmatch("[^\n]+") do
    Font.draw(line, 8, y)
    y = y + 16
  end
end

function M:drawMoves(Font)
  local mon = self:activeMon()
  local moves = (mon and mon.moves) or {}
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local shown = min(#moves, 3)
  local first = 1
  if self.cursor > 3 then first = self.cursor - 2 end
  for i = 0, shown - 1 do
    local move = moves[first + i]
    if move then Font.draw(tostring(move.id):sub(1, 16), 16, 112 + i * 16) end
  end
  Font.drawCode(0xED, 8, 112 + (self.cursor - first) * 16)
end

function M:drawSafe()
  local eng = loadEngine()
  if not (eng and eng.Font) then return end
  local Font = eng.Font

  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)

  self:drawSlot(Font, eng.HudTiles, self:foeSlot(), 0, self.peerName:sub(1, 8))
  self:drawSlot(Font, eng.HudTiles, self:mySlot(), 5, "YOU")

  if self.shown then
    return self:drawBox(Font, self.shown)
  end
  if self.phase == "choose" then
    return self:drawMoves(Font)
  end
  if self.phase == "setup" then
    return self:drawBox(Font, "Getting ready...")
  end
  self:drawBox(Font, ("Waiting for\n%s..."):format(self.peerName))
end

-- StateStack calls draw() directly, so a throw in there is not a missing frame
-- -- it is the game stopping, mid-fight, for two people.  The mod's rule is
-- that a broken renderer costs a display and never the game, so the real
-- drawing happens in drawSafe and this is the guard around it.  Warned once:
-- a failure that repeats every frame would otherwise become the log.
function M:draw()
  local ok, err = pcall(self.drawSafe, self)
  if ok then return end
  if self.drawFailed then return end
  self.drawFailed = true
  mod.log:error("the mediated battle screen failed to draw (%s); the fight is "
    .. "still running and can be finished blind, but report this", tostring(err))
end

return M
