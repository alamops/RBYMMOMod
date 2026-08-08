-- The turn machine: choices in, events out, and one party deciding.
--
-- The formula modules beside this one each answer a single question with no
-- memory.  This is the thing that holds the fight: it owns the field, the
-- clock, the RNG stream and the order the questions get asked in, and it is
-- the only file in src/BattleSim/ with state.  A battle brokered here is
-- resolved by *one* process -- the LAN host or the Node hub -- and the clients
-- receive an ordered stream of events they draw.  They are never asked what
-- happened, which is the whole reason a modified client cannot roll its own
-- damage any more.
--
-- **The RNG order is the contract.**  The twin under server/lib/battle/ has to
-- consume draws at exactly the same points or the same seed produces a
-- different fight, so every draw site is spelled out here and every one of
-- them is conditional in a way both runtimes can reproduce:
--
--   1. a speed tie-break byte, one per group of equally fast actors;
--   2. one gate byte per actor whose monster has a gating status;
--   3. one gate byte per actor whose monster is confused;
--   4. per move that is actually used: accuracy byte, crit byte, damage roll,
--      in that order, and none of them drawn when an earlier step ended the
--      move (a missed move draws no crit byte).
--
-- Nothing else rolls.  Residuals, switches, items and the clock are all
-- deterministic, so a battle replays from its seed plus the choice log.
--
-- **Policies chosen where Gen 1 had no answer**, each one written down because
-- the two runtimes have to pick the same one:
--
--   * *Speed ties* break on a single RNG byte per tied group: below 128 the
--     side-a member goes first, otherwise the group reverses.  One draw per
--     group rather than per pair, so a 2v2 with four equal speeds costs one
--     byte on both runtimes.
--   * *Running* is a concession, not an escape.  A mediated fight is between
--     two people who agreed to it, and Gen 1's flee roll exists to let you
--     leave a wild encounter -- so one side running loses the battle with
--     reason `run`, and both sides running is a draw.  Mirrored: the policy
--     reads the same from either seat, which is what stops "I fled" and "they
--     fled" being two different stories.
--   * *Items* are a v1 stub.  The bag is not modelled, so an `item` choice
--     announces itself and spends the turn -- the honest shape of "you may
--     press it, it does nothing yet" -- rather than being silently refused,
--     which would strand a client whose menu offers the button.
--   * *Status moves* (power 0) narrate and do nothing.  There is no move
--     effect table on either runtime -- by design, since one would be the ROM
--     extract this repo may not contain -- so `effect` and `chance` ride along
--     unread until a data-driven effect layer exists.
--   * *Physical and special are not split*, because Wire's move has no
--     category field to split on: every damaging move uses atk against def.
--   * A *faint sends the next living monster in party order*, immediately and
--     without asking.  The original stops and asks; asking here would mean a
--     second kind of choice phase with its own deadline and its own forfeit
--     rule, and a fight that can hang between two turns is a worse v1 than one
--     that picks in party order.
--   * *Residuals* run in field order (side a, then side b), not in the speed
--     order the moves used.  Only the order two burns tick in is at stake, and
--     field order is the one both runtimes can reproduce without carrying the
--     turn's sort into the end-of-turn step.
--   * A *timeout* auto-picks the first move with PP left, aimed at the first
--     living foe, and the fight continues.  It does not end the battle -- the
--     player who went to make a sandwich loses a turn, not the match.
--   * The choice clock is *suspended while anybody is disconnected*, because
--     the grace timer is already counting for that player and two deadlines
--     racing would decide the match on whichever fired first.
--
-- Nothing here raises.  Bad input is refused with a nil-plus-reason from
-- `create` or a plain `false` from `submitChoice`, because every caller is
-- downstream of a mod callback where a bare error() is a loader rule
-- violation -- and a fight that stops mid-turn is worse than one that declines
-- a malformed choice.
--
-- No love, no engine modules, no mod facade.

local need = ...

local Damage   = need("BattleSim/Damage")
local Accuracy = need("BattleSim/Accuracy")
local Crit     = need("BattleSim/Crit")
local Status   = need("BattleSim/Status")
local Rng      = need("BattleSim/Rng")
local Events   = need("BattleSim/events")

local M = {}

local floor, max = math.floor, math.max

M.VERSION = 1

-- Mirrored from Config rather than required, for the reason in events.lua:
-- this directory runs where Config does not.
M.MONS_PER_PARTY      = 6     -- Config.BATTLE_MON_MAX
M.FIGHTERS_PER_SIDE   = 2     -- Config.COOP_SIDE
M.CHOICE_TIMEOUT      = 60    -- Config.BATTLE_CHOICE_TIMEOUT
M.RECONNECT_GRACE     = 60    -- Config.BATTLE_RECONNECT_GRACE

-- Below this the side-a member of a tied group moves first.
M.TIE_BREAK_ROLL = 128

M.MODES = { ["1v1"] = true, coop_npc = true, coop_pvp = true }
M.SIDES = { "a", "b" }

-- Wire spells a condition as a three-letter token and Status.lua spells it as
-- a word.  Both are accepted on the way in and the token is what goes back out
-- on an event, so neither vocabulary leaks into the other's file.
M.STATUS_FROM_WIRE = {
  SLP = "sleep", PSN = "poison", BRN = "burn",
  FRZ = "freeze", PAR = "paralysis", TOX = "toxic",
}
M.STATUS_TO_WIRE = {
  sleep = "SLP", poison = "PSN", burn = "BRN",
  freeze = "FRZ", paralysis = "PAR", toxic = "TOX",
}

-- The conditions that can stop a move before it happens.  Confusion is not
-- here because in Gen 1 it is a volatile, not a status -- it rides on its own
-- counter and is gated separately, after this one.
local GATING = { sleep = true, freeze = true, paralysis = true }

local ACTIONS = {
  fight = true, item = true, switch = true, run = true, cancel = true,
}

-- ------------------------------------------------------------------
-- coercion
-- ------------------------------------------------------------------

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function str(value)
  if type(value) == "string" and value ~= "" then return value end
  return nil
end

local function copyMove(raw)
  if type(raw) ~= "table" then return nil end
  return {
    id       = str(raw.id) or "move",
    pp       = max(0, int(raw.pp, 0)),
    power    = max(0, int(raw.power, 0)),
    accuracy = max(0, int(raw.accuracy, 255)),
    type     = max(0, int(raw.type, 0)),
    effect   = max(0, int(raw.effect, 0)),
    chance   = max(0, int(raw.chance, 0)),
  }
end

-- A defender with no stated types is type 0, which the chart lookup reads as
-- "whatever row 1 says" and, absent a chart, as neutral.  That is the right
-- default for a sim that must never refuse a party over a missing optional.
local function copyTypes(raw)
  if type(raw) ~= "table" then return { 0 } end
  local out = {}
  for i = 1, #raw do out[i] = max(0, int(raw[i], 0)) end
  if #out == 0 then return { 0 } end
  return out
end

-- Every monster is deep-copied on the way in, and that is load-bearing rather
-- than tidy: the caller's table is usually a party the client still owns and
-- redraws, and a sim that damaged it in place would make "run the same fixture
-- twice" produce two different fights -- which is exactly the property the
-- determinism suite is built to catch.
local function copyMon(raw)
  if type(raw) ~= "table" then return nil end

  local stats = type(raw.stats) == "table" and raw.stats or {}
  local maxHp = max(1, int(raw.maxHp, 1))
  local hp = (raw.hp == nil) and maxHp or max(0, int(raw.hp, 0))
  if hp > maxHp then hp = maxHp end

  local status = str(raw.status)
  if status then status = M.STATUS_FROM_WIRE[status] or status end
  if status and not (GATING[status] or status == "poison"
                     or status == "burn" or status == "toxic") then
    status = nil                        -- a token nothing branches on is noise
  end

  local moves = {}
  if type(raw.moves) == "table" then
    for i = 1, #raw.moves do
      local move = copyMove(raw.moves[i])
      if move then moves[#moves + 1] = move end
    end
  end

  -- Sleep with no counter is read as one turn left, so it still costs the turn
  -- it wakes on rather than passing the gate as if healthy.  Any other default
  -- would be inventing a length; one is the shortest honest answer.
  local turns = max(0, int(raw.statusTurns, 0))
  if status == "sleep" and turns == 0 then turns = 1 end

  return {
    species     = str(raw.species) or "?",
    level       = max(1, int(raw.level, 1)),
    hp          = hp,
    maxHp       = maxHp,
    status      = status,
    statusTurns = turns,
    toxicCounter = max(1, int(raw.toxicCounter, 1)),
    confusion   = max(0, int(raw.confusion, 0)),
    stats = {
      atk = max(1, int(stats.atk, 1)),
      def = max(1, int(stats.def, 1)),
      spd = max(1, int(stats.spd, 1)),
      spc = max(1, int(stats.spc, 1)),
    },
    types = copyTypes(raw.types),
    moves = moves,
  }
end

-- ------------------------------------------------------------------
-- the battle
-- ------------------------------------------------------------------

local Battle = {}
Battle.__index = Battle
M.Battle = Battle

local function firstLiving(mons, skip)
  for i = 1, #mons do
    if mons[i].hp > 0 and i ~= skip then return i end
  end
  return nil
end

local function activeMon(fighter)
  if not fighter.active then return nil end
  local mon = fighter.mons[fighter.active]
  if mon and mon.hp > 0 then return mon end
  return nil
end

-- opts:
--   id, mode, seed, chart, choiceTimeout, reconnectGrace, now
--   sides = { a = { { playerId, name, mons } }, b = { ... } }
--
-- Returns the battle, or nil plus a reason string.  A reason and not a raise:
-- the caller is a session handler that has a client waiting to be told why.
function M.create(opts)
  if type(opts) ~= "table" then return nil, "battle needs an options table" end

  local mode = M.MODES[opts.mode] and opts.mode or "1v1"
  local perSide = (mode == "1v1") and 1 or M.FIGHTERS_PER_SIDE

  local self = setmetatable({
    id             = str(opts.id) or "battle",
    mode           = mode,
    seed           = int(opts.seed, 0),
    rng            = Rng.new(int(opts.seed, 0)),
    chart          = type(opts.chart) == "table" and opts.chart or nil,
    choiceTimeout  = max(0, int(opts.choiceTimeout, M.CHOICE_TIMEOUT)),
    reconnectGrace = max(0, int(opts.reconnectGrace, M.RECONNECT_GRACE)),
    now            = max(0, int(opts.now, 0)),
    phase          = "choice",
    turn           = 1,
    seq            = 0,
    buffer         = {},
    fighters       = {},
    byId           = {},
    bySide         = { a = {}, b = {} },
    result         = nil,
  }, Battle)

  local sides = type(opts.sides) == "table" and opts.sides or {}
  for _, side in ipairs(M.SIDES) do
    local roster = type(sides[side]) == "table" and sides[side] or {}
    if #roster == 0 then return nil, "side " .. side .. " has nobody on it" end
    if #roster > perSide then
      return nil, "side " .. side .. " has more fighters than " .. mode .. " allows"
    end
    for index = 1, #roster do
      local entry = roster[index]
      if type(entry) ~= "table" then return nil, "side " .. side .. " has a malformed fighter" end

      local playerId = str(entry.playerId)
      if not playerId then return nil, "a fighter on side " .. side .. " has no playerId" end
      if self.byId[playerId] then return nil, "duplicate playerId " .. playerId end

      local mons = {}
      if type(entry.mons) == "table" then
        for i = 1, #entry.mons do
          if #mons >= M.MONS_PER_PARTY then break end
          local mon = copyMon(entry.mons[i])
          if mon then mons[#mons + 1] = mon end
        end
      end
      if #mons == 0 then return nil, playerId .. " brought no monsters" end

      local fighter = {
        playerId  = playerId,
        name      = str(entry.name) or playerId,
        side      = side,
        index     = index,
        slot      = Events.fieldSlot(side, index),
        mons      = mons,
        active    = firstLiving(mons),
        connected = true,
        graceEndsAt = nil,
        choice    = nil,
      }
      self.fighters[#self.fighters + 1] = fighter
      self.byId[playerId] = fighter
      local bucket = self.bySide[side]
      bucket[#bucket + 1] = fighter
    end
  end

  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    if mon then
      self:_emit("send", { slot = fighter.slot, side = fighter.side,
                           hp = mon.hp, text = mon.species })
    end
  end

  self:_openTurn()
  return self
end

-- ------------------------------------------------------------------
-- events
-- ------------------------------------------------------------------

function Battle:_emit(kind, fields)
  local event = Events.build(kind, fields)
  if not event then return nil end
  self.seq = self.seq + 1
  event.battle = self.id
  event.seq = self.seq
  self.buffer[#self.buffer + 1] = event
  return event
end

function Battle:_say(text)
  return self:_emit("msg", { text = text })
end

-- Everything since the last call, in order, and the buffer is emptied.  A
-- caller that drops the returned list drops those events for good, which is
-- deliberate: the alternative -- a buffer that grows until somebody reads it --
-- is a memory leak on a hub whose client has gone quiet.
function Battle:drainEvents()
  local out = self.buffer
  self.buffer = {}
  return out
end

-- ------------------------------------------------------------------
-- the field
-- ------------------------------------------------------------------

function Battle:_foes(fighter)
  local other = (fighter.side == "a") and "b" or "a"
  return self.bySide[other]
end

function Battle:_fighterAtSlot(slot)
  for _, fighter in ipairs(self.fighters) do
    if fighter.slot == slot then return fighter end
  end
  return nil
end

function Battle:_firstLivingFoe(fighter)
  for _, foe in ipairs(self:_foes(fighter)) do
    if activeMon(foe) then return foe end
  end
  return nil
end

function Battle:_sideAlive(side)
  for _, fighter in ipairs(self.bySide[side]) do
    if firstLiving(fighter.mons) then return true end
  end
  return false
end

function Battle:_sidePlayers(side)
  local out = {}
  for _, fighter in ipairs(self.bySide[side]) do out[#out + 1] = fighter.playerId end
  return out
end

-- A fighter owes a choice when it has something standing.  A player whose last
-- monster fainted in a 2v2 is a spectator for the rest of the fight, and
-- waiting on them would hang the turn.
function Battle:_owes(fighter)
  return activeMon(fighter) ~= nil and fighter.choice == nil
end

function Battle:_anyDisconnected()
  for _, fighter in ipairs(self.fighters) do
    if not fighter.connected then return true end
  end
  return false
end

-- ------------------------------------------------------------------
-- choices
-- ------------------------------------------------------------------
--
-- Indices arrive zero-based, because that is how they ride on the wire:
-- `move` is 0..3 into the monster's moves, `slot` is 0..5 into the party, and
-- `target` is a 0..3 *field* slot.  They are converted here, once, so nothing
-- downstream has to remember which of the three it is holding.

function Battle:_normaliseChoice(fighter, choice)
  local action = choice.action
  local mon = activeMon(fighter)
  if not mon then return nil end

  if action == "run" then return { action = "run" } end

  if action == "item" then
    local item = str(choice.item)
    if not item then return nil end
    return { action = "item", item = item }
  end

  if action == "switch" then
    local slot = int(choice.slot, nil)
    if slot == nil then return nil end
    local target = slot + 1
    local bench = fighter.mons[target]
    if not bench or bench.hp <= 0 or target == fighter.active then return nil end
    return { action = "switch", slot = target }
  end

  if action == "fight" then
    local index = int(choice.move, nil)
    if index == nil then return nil end
    local move = mon.moves[index + 1]
    if not move or move.pp <= 0 then return nil end

    local targetFighter
    if choice.target ~= nil then
      targetFighter = self:_fighterAtSlot(int(choice.target, -1))
      -- A named target that is empty or on the chooser's own side is refused
      -- rather than redirected: redirecting would spend somebody's turn on a
      -- monster they did not pick, and the client can ask again.
      if not targetFighter or targetFighter.side == fighter.side
         or not activeMon(targetFighter) then
        return nil
      end
    else
      targetFighter = self:_firstLivingFoe(fighter)
      if not targetFighter then return nil end
    end
    return { action = "fight", move = index + 1, target = targetFighter.slot }
  end

  return nil
end

-- Returns true when the choice is now held for this turn, false otherwise.
-- False is the whole of the error report on purpose: the reasons a choice is
-- refused (wrong phase, unknown player, already answered, an index that names
-- nothing) are all things the client can see for itself, and a string here
-- would be a second vocabulary to keep in step across two runtimes.
function Battle:submitChoice(playerId, choice)
  if self.phase ~= "choice" then return false end
  if type(choice) ~= "table" then return false end

  local fighter = self.byId[str(playerId) or ""]
  if not fighter then return false end
  if not ACTIONS[choice.action] then return false end

  if choice.action == "cancel" then
    if fighter.choice == nil then return false end
    fighter.choice = nil
    return true
  end

  if fighter.choice ~= nil then return false end   -- one answer per turn
  if not activeMon(fighter) then return false end

  local normalised = self:_normaliseChoice(fighter, choice)
  if not normalised then return false end

  fighter.choice = normalised
  self:_maybeResolve()
  return true
end

function Battle:_maybeResolve()
  if self.phase ~= "choice" then return false end
  for _, fighter in ipairs(self.fighters) do
    if self:_owes(fighter) then return false end
  end
  self:_resolveTurn()
  return true
end

-- The first move with PP left, at the first living foe.  Used when a deadline
-- passes: doing nothing would stall a clock that nothing else stops, and
-- picking the *best* move would be the sim playing somebody's turn well rather
-- than merely playing it.
function Battle:_autoChoice(fighter)
  local mon = activeMon(fighter)
  if not mon then return nil end
  local foe = self:_firstLivingFoe(fighter)
  if not foe then return nil end

  local pick
  for i = 1, #mon.moves do
    if mon.moves[i].pp > 0 then pick = i break end
  end
  -- Out of PP everywhere is still a turn that has to resolve, so the first
  -- move goes out on empty PP rather than the fight hanging.  Gen 1 would send
  -- Struggle here; there is no move table to send it from.
  pick = pick or 1
  if not mon.moves[pick] then return nil end
  return { action = "fight", move = pick, target = foe.slot }
end

-- ------------------------------------------------------------------
-- resolution
-- ------------------------------------------------------------------

function Battle:_openTurn()
  self.phase = "choice"
  for _, fighter in ipairs(self.fighters) do fighter.choice = nil end
  self.deadline = (self.choiceTimeout > 0) and (self.now + self.choiceTimeout) or nil
  self:_emit("turn", { amount = self.turn })
end

function Battle:_speedOf(mon)
  if mon.status == "paralysis" then return Status.paralysisSpeed(mon.stats.spd) end
  return mon.stats.spd
end

-- chart[atkType + 1][defType + 1], one percent per defender type, because
-- Damage.compute applies them as separate truncating steps the way the
-- original does.  A missing row, a missing cell or no chart at all reads as
-- neutral: a party naming a type this match's chart has no row for is a
-- well-formed party, and refusing it over a lookup would be worse than
-- fighting it straight.
function Battle:_typePercents(moveType, defender)
  local row = self.chart and self.chart[moveType + 1] or nil
  local out = {}
  for i = 1, #defender.types do
    local pct = 100
    if type(row) == "table" then
      local cell = tonumber(row[defender.types[i] + 1])
      if cell then pct = floor(cell) end
    end
    out[#out + 1] = pct
  end
  if #out == 0 then out[1] = 100 end
  return out
end

local function hasType(mon, typeId)
  for i = 1, #mon.types do
    if mon.types[i] == typeId then return true end
  end
  return false
end

function Battle:_resolveTurn()
  self.phase = "resolving"

  if self:_resolveRuns() then return end
  self:_resolveSwitches()
  self:_resolveItems()
  self:_resolveFights()
  if not self.result then self:_resolveResiduals() end
  if not self.result then self:_checkOver() end

  if not self.result then
    self.turn = self.turn + 1
    self:_openTurn()
  end
end

-- Fleeing is a concession; see the policy note in the header.
function Battle:_resolveRuns()
  local running = {}
  for _, fighter in ipairs(self.fighters) do
    if fighter.choice and fighter.choice.action == "run" then
      running[#running + 1] = fighter
    end
  end
  if #running == 0 then return false end

  local sides = {}
  for _, fighter in ipairs(running) do
    sides[fighter.side] = true
    self:_emit("run", { slot = fighter.slot, side = fighter.side, text = fighter.name })
  end

  if sides.a and sides.b then
    self:_finish("draw", nil, nil, "run")
  elseif sides.a then
    self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "run")
  else
    self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "run")
  end
  return true
end

function Battle:_resolveSwitches()
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    if choice and choice.action == "switch" then
      local mon = fighter.mons[choice.slot]
      if mon and mon.hp > 0 then
        fighter.active = choice.slot
        self:_emit("switch", { slot = fighter.slot, side = fighter.side,
                               text = mon.species })
        self:_emit("send", { slot = fighter.slot, side = fighter.side,
                             hp = mon.hp, text = mon.species })
      end
    end
  end
end

function Battle:_resolveItems()
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    if choice and choice.action == "item" then
      self:_emit("item", { slot = fighter.slot, side = fighter.side,
                           text = choice.item })
      self:_say(fighter.name .. " used an item")
    end
  end
end

function Battle:_resolveFights()
  local actors = {}
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    local mon = activeMon(fighter)
    if choice and choice.action == "fight" and mon then
      actors[#actors + 1] = {
        fighter = fighter,
        mon = mon,                      -- pinned: see the skip in the loop
        speed = self:_speedOf(mon),
        order = #actors + 1,
      }
    end
  end
  if #actors == 0 then return end

  table.sort(actors, function(x, y)
    if x.speed ~= y.speed then return x.speed > y.speed end
    return x.order < y.order          -- field order: side a, then side b
  end)

  -- One byte per group of equally fast actors, spent only when the group is
  -- actually tied, so an ordinary turn between two different speeds costs no
  -- draw at all on either runtime.
  local i = 1
  while i <= #actors do
    local j = i
    while j < #actors and actors[j + 1].speed == actors[i].speed do j = j + 1 end
    if j > i and self.rng:byte() >= M.TIE_BREAK_ROLL then
      for lo = i, i + floor((j - i) / 2) do
        local hi = j - (lo - i)
        actors[lo], actors[hi] = actors[hi], actors[lo]
      end
    end
    i = j + 1
  end

  for _, actor in ipairs(actors) do
    if self.result then break end
    -- The monster that chose is the only one allowed to act: if it fainted to
    -- a faster attacker, the replacement that came in behind it does not
    -- inherit the turn.
    if activeMon(actor.fighter) == actor.mon then
      self:_useMove(actor.fighter, actor.mon)
    end
  end
end

-- Returns false when a gate stopped the move.
function Battle:_runGates(fighter, mon)
  if GATING[mon.status] then
    local gate = Status.beforeMove(
      { status = mon.status, turnsRemaining = mon.statusTurns }, self.rng:byte())
    if gate then
      mon.statusTurns = int(gate.turnsRemaining, mon.statusTurns)
      if gate.wokeUp then
        mon.status, mon.statusTurns = nil, 0
        self:_emit("status", { slot = fighter.slot, side = fighter.side,
                               text = mon.species .. " woke up" })
      elseif gate.fullyParalyzed then
        self:_say(mon.species .. " is fully paralyzed")
      elseif mon.status == "sleep" then
        self:_say(mon.species .. " is fast asleep")
      elseif mon.status == "freeze" then
        self:_say(mon.species .. " is frozen solid")
      end
      if not gate.canMove then return false end
    end
  end

  if mon.confusion > 0 then
    local gate = Status.beforeMove({
      status = "confusion",
      turnsRemaining = mon.confusion,
      level = mon.level, attack = mon.stats.atk, defense = mon.stats.def,
    }, self.rng:byte())
    if gate then
      mon.confusion = int(gate.turnsRemaining, 0)
      if gate.snappedOut then
        self:_say(mon.species .. " snapped out of confusion")
      elseif gate.selfHit then
        self:_say(mon.species .. " hurt itself in confusion")
        self:_damage(fighter, mon, gate.selfDamage or 0, nil)
        return false
      end
      if not gate.canMove then return false end
    end
  end

  return true
end

function Battle:_useMove(fighter, mon)
  local choice = fighter.choice
  local move = mon.moves[choice.move]
  if not move then return end

  if not self:_runGates(fighter, mon) then return end

  local target = self:_fighterAtSlot(choice.target)
  local defender = target and activeMon(target)
  if not defender then
    -- The chosen target went down before this actor moved.  Redirecting would
    -- be choosing a different opponent on somebody's behalf, so the move
    -- fizzles and the turn is spent -- the same thing the original does when
    -- its target is gone.
    self:_say(mon.species .. " has no target")
    return
  end

  if move.pp > 0 then move.pp = move.pp - 1 end
  self:_emit("anim", { slot = fighter.slot, side = fighter.side, text = move.id })
  self:_say(mon.species .. " used " .. move.id)

  local hit = Accuracy.hit(move.accuracy, self.rng:byte())
  if not hit then
    self:_say(mon.species .. " missed")
    return
  end

  if move.power <= 0 then
    -- The status-move stub: narrated, and nothing more.  See the header.
    self:_say("But nothing happened")
    return
  end

  local isCrit = Crit.check(mon.stats.spd, self.rng:byte())
  local percents = self:_typePercents(move.type, defender)

  local attack = mon.stats.atk
  if mon.status == "burn" then attack = Status.burnAttack(attack) end

  local result = Damage.compute(
    { level = mon.level, attack = attack },
    { defense = defender.stats.def },
    { power = move.power },
    {
      crit = isCrit,
      stab = hasType(mon, move.type),
      typeEffect = percents,
      roll = self.rng:damageRoll(),
    })

  if result.immune then
    self:_say("It doesn't affect " .. defender.species)
    return
  end

  local effectiveness = 1
  for _, pct in ipairs(percents) do effectiveness = effectiveness * pct / 100 end
  if isCrit then self:_say("A critical hit") end
  if effectiveness > 1 then
    self:_say("It's super effective")
  elseif effectiveness < 1 then
    self:_say("It's not very effective")
  end

  self:_damage(target, defender, result.damage or 0, nil)
end

-- One place where HP comes off, so the faint that follows can never be
-- forgotten at one of the call sites.
function Battle:_damage(fighter, mon, amount, status)
  amount = max(0, int(amount, 0))
  if amount > mon.hp then amount = mon.hp end
  mon.hp = mon.hp - amount

  self:_emit("damage", {
    slot = fighter.slot, side = fighter.side,
    amount = amount, hp = mon.hp,
    status = status and M.STATUS_TO_WIRE[status] or nil,
  })

  if mon.hp <= 0 then self:_faint(fighter, mon) end
end

function Battle:_faint(fighter, mon)
  self:_emit("faint", { slot = fighter.slot, side = fighter.side, text = mon.species })

  local next_ = firstLiving(fighter.mons)
  if next_ then
    fighter.active = next_
    local incoming = fighter.mons[next_]
    self:_emit("send", { slot = fighter.slot, side = fighter.side,
                         hp = incoming.hp, text = incoming.species })
  else
    fighter.active = nil
  end

  self:_checkOver()
end

function Battle:_resolveResiduals()
  for _, fighter in ipairs(self.fighters) do
    if self.result then return end
    local mon = activeMon(fighter)
    if mon and mon.status then
      local amount = Status.residual({
        status = mon.status, maxHp = mon.maxHp, toxicCounter = mon.toxicCounter,
      })
      if amount then
        if mon.status == "toxic" then mon.toxicCounter = mon.toxicCounter + 1 end
        self:_say(mon.species .. " is hurt by its " .. mon.status)
        self:_damage(fighter, mon, amount, mon.status)
      end
    end
  end
end

-- ------------------------------------------------------------------
-- endings
-- ------------------------------------------------------------------

function Battle:_checkOver()
  if self.result then return true end
  local aliveA, aliveB = self:_sideAlive("a"), self:_sideAlive("b")
  if aliveA and aliveB then return false end

  if not aliveA and not aliveB then
    self:_finish("draw", nil, nil, "ko")
  elseif aliveA then
    self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "ko")
  else
    self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "ko")
  end
  return true
end

-- `outcome` is stated from the *field's* point of view, not a recipient's:
-- "win" means the winners list won.  The per-client rendering -- the "loss"
-- the loser's screen shows -- belongs to the session layer that addresses the
-- message, because it is the only party that knows who it is talking to.
--
-- A draw carries no lists at all rather than two empty ones, because
-- Wire.battleOutcome refuses an empty id list: the absence is the statement.
function Battle:_finish(outcome, winners, losers, reason)
  if self.result then return self.result end

  self.result = {
    battle = self.id,
    outcome = outcome,
    winners = winners,
    losers = losers,
    reason = reason,
  }
  self.phase = "over"
  self.deadline = nil
  self:_emit("over", { text = reason })
  return self.result
end

-- nil until the fight is done, so `if battle:outcome() then` is the whole test.
function Battle:outcome()
  return self.result
end

-- ------------------------------------------------------------------
-- the clock
-- ------------------------------------------------------------------

function Battle:disconnect(playerId)
  local fighter = self.byId[str(playerId) or ""]
  if not fighter or not fighter.connected then return false end
  if self.result then return false end

  fighter.connected = false
  fighter.graceEndsAt = self.now + self.reconnectGrace
  self:_emit("wait", { side = fighter.side, text = fighter.name })
  return true
end

-- Back inside the window continues the fight from where it paused, and the
-- choice deadline restarts rather than resuming: the player who reconnects
-- with two seconds left on a clock they could not see would be choosing under
-- a timer the drop created.
function Battle:reconnect(playerId)
  local fighter = self.byId[str(playerId) or ""]
  if not fighter or fighter.connected then return false end
  if self.result then return false end
  if fighter.graceEndsAt and self.now >= fighter.graceEndsAt then return false end

  fighter.connected = true
  fighter.graceEndsAt = nil
  self:_emit("reconnect", { side = fighter.side, text = fighter.name })

  if self.phase == "choice" and not self:_anyDisconnected() and self.choiceTimeout > 0 then
    self.deadline = self.now + self.choiceTimeout
  end
  return true
end

-- Advances the wall clock and fires whatever it has passed.  Returns true when
-- something actually happened, so a hub can skip a drain on a quiet tick.
--
-- Time only moves forward: a caller handing back an earlier `now` -- two
-- sources of time on a hub, a clock that stepped -- must not un-expire a grace
-- period that already ran.
function Battle:tick(nowSeconds)
  local now = int(nowSeconds, self.now)
  if now > self.now then self.now = now end
  if self.result then return false end

  local expiredA, expiredB = false, false
  for _, fighter in ipairs(self.fighters) do
    if not fighter.connected and fighter.graceEndsAt and self.now >= fighter.graceEndsAt then
      if fighter.side == "a" then expiredA = true else expiredB = true end
    end
  end

  if expiredA or expiredB then
    if expiredA and expiredB then
      self:_finish("draw", nil, nil, "disconnect")
    elseif expiredA then
      self:_finish("forfeit", self:_sidePlayers("b"), self:_sidePlayers("a"), "disconnect")
    else
      self:_finish("forfeit", self:_sidePlayers("a"), self:_sidePlayers("b"), "disconnect")
    end
    return true
  end

  -- The choice clock is suspended while anybody is away; the grace above is
  -- the only deadline running for them.
  if self.phase == "choice" and self.deadline and self.now >= self.deadline
     and not self:_anyDisconnected() then
    for _, fighter in ipairs(self.fighters) do
      if self:_owes(fighter) then
        local auto = self:_autoChoice(fighter)
        if auto then
          fighter.choice = auto
          self:_say(fighter.name .. " ran out of time")
        end
      end
    end
    self:_maybeResolve()
    -- A fighter with nothing left to auto-pick would leave the turn open on a
    -- deadline already in the past, and every later tick would announce the
    -- timeout again.  Push the clock instead: the fight waits one more window
    -- rather than filling the log.
    if self.phase == "choice" and self.deadline and self.now >= self.deadline then
      self.deadline = self.now + self.choiceTimeout
    end
    return true
  end

  return false
end

-- ------------------------------------------------------------------
-- snapshot
-- ------------------------------------------------------------------
--
-- For tests and for a log line, not for a client: a client is sent events.
-- Everything here is a copy, so a caller poking at it cannot reach into the
-- field.
function Battle:snapshot()
  local field, waiting = {}, {}

  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    local party = {}
    for i = 1, #fighter.mons do party[i] = fighter.mons[i].hp end

    field[#field + 1] = {
      slot = fighter.slot,
      side = fighter.side,
      playerId = fighter.playerId,
      name = fighter.name,
      connected = fighter.connected,
      graceEndsAt = fighter.graceEndsAt,
      chose = fighter.choice ~= nil and fighter.choice.action or nil,
      species = mon and mon.species or nil,
      hp = mon and mon.hp or 0,
      maxHp = mon and mon.maxHp or 0,
      status = mon and mon.status and M.STATUS_TO_WIRE[mon.status] or nil,
      party = party,
    }
    if self:_owes(fighter) then waiting[#waiting + 1] = fighter.playerId end
  end

  return {
    battle = self.id,
    mode = self.mode,
    phase = self.phase,
    turn = self.turn,
    seq = self.seq,
    now = self.now,
    deadline = self.deadline,
    over = self.result ~= nil,
    reason = self.result and self.result.reason or nil,
    rngState = self.rng:state(),
    field = field,
    waiting = waiting,
  }
end

return M
