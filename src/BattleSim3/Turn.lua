-- The Gen 3 turn machine: choices in, events out, and one party deciding.
--
-- Fork of src/BattleSim2/Turn.lua.  The public API is identical -- `create`,
-- `submitChoice`, `autoPick`, `tick`, `drainEvents`, `disconnect`, `reconnect`,
-- `outcome`, `snapshot` -- and so are the seat model, the phases (choice /
-- replace / resolving / over), the clock, the replace phase, participation and
-- the `exp` facts, the `team` rosters and the forced-lock-in pacing, so a hub
-- and a client switch simulators by generation only.  What is new is what
-- happens inside a turn: Move.lua resolves every action as the Gen 3 engine
-- does (src/core/game3/battle/engine.lua, pret-cited throughout), Residual.lua
-- runs the Gen 3 end of turn, and this file orders the turn and owns the bag,
-- running and catching.  Contracts C4 (sheet) and C5 (events):
-- docs/plans/gen3-battle-sheet.md.
--
-- **The RNG order is the contract.**  One generator per battle (`self.rng`) and
-- the aim stream (`self.aim`, used only by `_autoTarget`).  Every draw is
-- `rng:roll(lo, hi)` (Rng.lua: top bits; a one-value range draws nothing), and
-- the Node twin must draw at exactly these points, in this order:
--
--   1. battle start: one roll(0,255) per speed-tied group of the switch-in order;
--      Trace's pick between two or more traceable foes, roll(0, n-1);
--   2. turn start: Quick Claw roll(0,65535) -- only when two or more seats
--      fight and a fighting mon holds QUICK_CLAW; one roll(0,255) per group of
--      fighters tied on both priority and speed;
--   3. runs (wild modes): roll(0,255) for a runner slower than the wild mon
--      (no draw for Smoke Ball, Run Away or the faster runner);
--   4. switches (and, interleaved in battler order, the bag items that are not
--      balls -- those draw nothing): any foe Pursuit aimed at the leaving seat
--      draws as a move, minus the canceller's and the accuracy draws;
--   5. bag: balls (after other items, fastest thrower first) draw up to four
--      roll(0,65535) (none for a Master Ball or odds > 254);
--   6. moves, in speed order, each drawing only at the points it reaches:
--      canceller (freeze roll(0,4); a sleeper with no counter roll(0,3); confusion
--      roll(0,1) [+ self-hit roll(85,100) + Focus Band roll(0,99) when held];
--      paralysis roll(0,3); infatuation roll(0,1)); random target over two or
--      more living foes roll(0,n-1); Metronome roll(1,511) until a pool move
--      (or roll(1,n) after 64 misses); Sleep Talk / Assist roll(1,n); Protect
--      streak roll(0,2^k-1); Magnitude roll(0,99); accuracy roll(1,100);
--      multi-hit roll(0,3) (+ roll(0,3)); per strike Psywave roll(0,10), crit
--      roll(0,n-1) (not vs Battle / Shell Armor, not for fixed damage), damage
--      roll(85,100), Present roll(0,255), Focus Band roll(0,99) (holder only),
--      Beat Up's crit (not vs Battle / Shell Armor) + damage per party member;
--      secondary roll(0,99) (not for certain effects); effect-internal draws
--      (sleep turns roll(0,3), confusion turns roll(0,3), trap turns roll(0,3),
--      Tri Attack roll(0,2), Thrash roll(0,1), Uproar roll(0,3), Disable
--      roll(0,3), Encore roll(0,3), Spite roll(0,3), Conversion / Conversion 2
--      roll(1,n), Roar's level check roll(0,255) and pick roll(1,n), OHKO
--      roll(1,100)); move end: Effect Spore roll(0,9) then roll(0,3) until
--      non-zero, Static / Flame Body / Poison Point / Cute Charm roll(0,2),
--      King's Rock roll(0,99) -- after EVERY strike of a multi-hit, Triple Kick
--      or Beat Up, plus King's Rock once more at a multi-hit's close; after the
--      action, Trace draws as in 1 (the post-action item pass is the cart's
--      moveTurn pass: no berry there draws);
--   7. end of turn: one roll(0,255) per tied group of the re-sort, then the
--      phases in order (Shed Skin roll(0,2), confusion-berry turns, Starf-type
--      berry roll(0,4) until raisable, Thrash fatigue roll(0,3), Yawn's sleep
--      roll(0,3), Future Sight accuracy roll(1,100) + roll(85,100) [+ Focus
--      Band roll(0,99)] -- a hit due on a seat emptied this turn draws them in
--      the replace phase instead, after the switch-ins).
--
-- Nothing else rolls.  A battle replays from its seed plus the choice log.
--
-- **Policies** (BattleSim2's, kept unless Gen 3 differs -- each written down in
-- docs/plans/gen3-battle-sheet.md §6):
--   * Seats, field slots and the replace phase are BattleSim2's.  A fight with
--     more than one seat on a side is a doubles fight (spread moves, doubled
--     screens, Helping Hand, Follow Me, Lightning Rod, Pressure counting).
--   * Order: runs, then switches and bag items together in battler order (each
--     switch after any Pursuit aimed at it), balls after them by speed, then
--     moves by priority then speed, Quick Claw first in its bracket; ties: one
--     roll(0,255) per group, >= 128 reverses.
--   * End of turn re-sorts the standing battlers by this turn's priority and
--     speed (the cart's ENDTURN_ORDER), not BattleSim2's field order.
--   * Running: 1v1 / coop_pvp concede; coop_npc refuses; wild modes run pret's
--     TryRunFromBattle and a failure spends the turn; trapped runs and switches
--     are refused at submit.
--   * Forced lock-in (no menu): recharge, a two-turn release, Bide, Thrash-type
--     rampage, Uproar, Rollout.  A partial trap does not lock the victim.
--   * Link rules: no badge boosts, no disobedience, no exp and no Pay Day coins
--     in 1v1 / coop_pvp (a won wild / coop_npc fight reports side a's coins as
--     `outcome().payDay`).  King's Rock keeps the cart's battler-0 quirk.
--   * Timeout / NPC auto-pick: BattleSim2's heuristic on Gen 3 ids.
--
-- Nothing here raises.  Bad input is refused with nil-plus-reason from `create`
-- or a plain `false` from `submitChoice`.
--
-- No love, no engine modules, no mod facade.

local need = ...

local Rng       = need("BattleSim3/Rng")
local Types     = need("BattleSim3/Types")
local Status    = need("BattleSim3/Status")
local Abilities = need("BattleSim3/Abilities")
local Items     = need("BattleSim3/Items")
local Field     = need("BattleSim3/Field")
local Catch     = need("BattleSim3/Catch")
local Effects   = need("BattleSim3/Effects")
local Move      = need("BattleSim3/Move")
local Residual  = need("BattleSim3/Residual")
local Events    = need("BattleSim3/events")

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.VERSION = 1
M.GENERATION = 3

M.MONS_PER_PARTY      = 6     -- Config.BATTLE_MON_MAX
M.FIGHTERS_PER_SIDE   = 3     -- Config.COOP_SIDE
M.CHOICE_TIMEOUT      = 60    -- Config.BATTLE_CHOICE_TIMEOUT
M.RECONNECT_GRACE     = 60    -- Config.BATTLE_RECONNECT_GRACE
M.RESOLVE_TIMEOUT     = 30    -- Config.BATTLE_RESOLVE_TIMEOUT

M.TIE_BREAK_ROLL = 128
M.AIM_SEED_OFFSET = 1597334677

M.MODES = {
  ["1v1"] = true, coop_npc = true, coop_pvp = true, wild = true, coop_wild = true,
}
M.SIDES = { "a", "b" }

-- Gen 3 statuses ride the wire in their own tokens, both ways.
M.STATUS_FROM_WIRE = { SLP = "SLP", PSN = "PSN", BRN = "BRN", FRZ = "FRZ", PAR = "PAR", TOX = "TOX" }
M.STATUS_TO_WIRE = M.STATUS_FROM_WIRE

local ACTIONS = { fight = true, item = true, switch = true, run = true, cancel = true }

local E = Effects.E
local T = Move.TARGET

local function maxFighters(mode, side)
  if mode == "coop_wild" then
    return (side == "a") and M.FIGHTERS_PER_SIDE or 1
  end
  if mode == "1v1" or mode == "wild" then return 1 end
  return M.FIGHTERS_PER_SIDE
end

local WILD_SIDE = "b"

local function isWildMode(mode)
  return type(mode) == "string" and mode:find("wild", 1, true) ~= nil
end
M.isWildMode = isWildMode

local function isWildSeat(mode, fighter)
  return fighter ~= nil and fighter.side == WILD_SIDE and isWildMode(mode)
end

-- RUN finishes the fight in wild modes (a real escape attempt) and 1v1 /
-- coop_pvp (a concession); everywhere else it is the trainer refusal.
local function runEndsBattle(mode)
  return isWildMode(mode) or mode == "1v1" or mode == "coop_pvp"
end
M.runEndsBattle = runEndsBattle

-- ------------------------------------------------------------------
-- coercion (the C4 sheet)
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

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function copyMove(raw)
  if type(raw) ~= "table" then return nil end
  local pp = max(0, int(raw.pp, 0))
  return {
    id       = str(raw.id) or "MOVE",
    name     = str(raw.name),
    num      = max(0, int(raw.num, 0)),
    pp       = pp,
    maxPp    = max(pp, int(raw.maxPp, pp)),
    power    = max(0, int(raw.power, 0)),
    accuracy = max(0, int(raw.accuracy, 100)),
    type     = clamp(int(raw.type, 0), 0, 31),
    effect   = clamp(int(raw.effect, 0), 0, 255),
    chance   = clamp(int(raw.chance, 0), 0, 100),
    target   = max(0, int(raw.target, 0)),
    priority = clamp(int(raw.priority, 0), -7, 7),
    flags    = max(0, int(raw.flags, 0)),
  }
end
M.copyMove = copyMove

-- A pool entry: the packed "num:effect:power:type:accuracy:pp:chance:target:
-- priority:flags:id" string (sheet doc §3.3) or a row table.
local function parsePoolEntry(raw)
  if type(raw) == "table" then return copyMove(raw) end
  if type(raw) ~= "string" then return nil end
  local parts = {}
  for piece in (raw .. ":"):gmatch("([^:]*):") do parts[#parts + 1] = piece end
  if #parts ~= 11 then return nil end
  local nums = {}
  for i = 1, 10 do
    local n = tonumber(parts[i])
    if not n or n ~= floor(n) then return nil end
    nums[i] = n
  end
  local id = parts[11]
  if not id:match("^[%w_%-]+$") or #id > 40 then return nil end
  return copyMove({
    num = nums[1], effect = nums[2], power = nums[3], type = nums[4], accuracy = nums[5],
    pp = nums[6], maxPp = nums[6], chance = nums[7], target = nums[8], priority = nums[9],
    flags = nums[10], id = id,
  })
end
M.parsePoolEntry = parsePoolEntry

local function copyTypes(raw)
  if type(raw) ~= "table" then return { 0 } end
  local out = {}
  for i = 1, min(2, #raw) do out[i] = clamp(int(raw[i], 0), 0, 31) end
  if #out == 0 then return { 0 } end
  if out[2] == out[1] then out[2] = nil end
  return out
end

local function copyNumbers(raw)
  if type(raw) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(raw) do
    if type(k) == "string" and tonumber(v) then out[k] = int(v, 0) end
  end
  return out
end

local function copyMon(raw, fallback)
  if type(raw) ~= "table" then return nil end
  local stats = type(raw.stats) == "table" and raw.stats or {}
  local maxHp = max(1, int(raw.maxHp, 1))
  local hp = (raw.hp == nil) and maxHp or max(0, int(raw.hp, 0))
  if hp > maxHp then hp = maxHp end
  local status = Status.normalise(str(raw.status))
  local moves = {}
  if type(raw.moves) == "table" then
    for i = 1, #raw.moves do
      if #moves >= 4 then break end
      local mv = copyMove(raw.moves[i])
      if mv then moves[#moves + 1] = mv end
    end
  end
  local hp3 = nil
  if type(raw.hiddenPower) == "table" then
    hp3 = { type = clamp(int(raw.hiddenPower.type, 0), 0, 17),
            power = clamp(int(raw.hiddenPower.power, 70), 1, 255) }
  end
  local beatUp = nil
  if type(raw.beatUp) == "table" then
    beatUp = { atk = max(1, int(raw.beatUp.atk, 50)), def = max(1, int(raw.beatUp.def, 50)) }
  end
  local gender = raw.gender
  if gender ~= "M" and gender ~= "F" then gender = "U" end
  local out = {
    species = str(raw.species) or "?",
    speciesId = str(raw.speciesId),
    speciesNum = max(0, int(raw.speciesNum, 0)),
    slot = max(0, int(raw.slot, max(0, int(fallback, 0)))),
    level = clamp(int(raw.level, 1), 1, 100),
    hp = hp, maxHp = maxHp,
    stats = {
      atk = max(1, int(stats.atk, 1)), def = max(1, int(stats.def, 1)),
      spe = max(1, int(stats.spe, 1)), spa = max(1, int(stats.spa, 1)),
      spd = max(1, int(stats.spd, 1)),
    },
    types = copyTypes(raw.types),
    ability = clamp(int(raw.ability, 0), 0, 255),
    abilityName = str(raw.abilityName),
    heldItem = max(0, int(raw.heldItem, 0)),
    holdEffect = max(0, int(raw.holdEffect, 0)),
    holdParam = max(0, int(raw.holdEffectParam or raw.holdParam, 0)),
    itemName = str(raw.itemName),
    gender = gender,
    friendship = clamp(int(raw.friendship, 70), 0, 255),
    weight = max(0, int(raw.weight, 0)),
    nature = clamp(int(raw.nature, 0), 0, 24),
    hiddenPower = hp3,
    beatUp = beatUp,
    status = status,
    sleepTurns = (status == "SLP") and int(raw.sleepTurns, nil) or nil,
    catchRate = clamp(int(raw.catchRate, 255), 0, 255),
    moves = moves,
    ivs = copyNumbers(raw.ivs),
    evs = copyNumbers(raw.evs),
    personality = int(raw.personality, nil),
    otId = int(raw.otId, nil),
  }
  if out.heldItem == 0 then out.holdEffect, out.holdParam = 0, 0 end
  return out
end
M.copyMon = copyMon

-- A bag sheet: { { id, count, name? } } or { [id] = count }, numeric ids.
local function copyBag(raw)
  if type(raw) ~= "table" then return nil end
  local out, names, any = {}, {}, false
  local function put(id, count, name)
    local n = Items.idOf(id)
    local c = int(count, 0)
    if not n or not c or c < 1 then return end
    out[n] = (out[n] or 0) + c
    if str(name) then names[n] = name end
    any = true
  end
  if #raw > 0 or raw[1] ~= nil then
    for _, entry in ipairs(raw) do
      if type(entry) == "table" then put(entry.id, entry.count, entry.name) end
    end
  else
    for id, count in pairs(raw) do put(id, count) end
  end
  if not any then return nil end
  return out, names
end

-- ------------------------------------------------------------------
-- the battle
-- ------------------------------------------------------------------

local Battle = {}
Battle.__index = Battle
M.Battle = Battle

Move.install(Battle)
Residual.install(Battle)

Battle.TIE_BREAK_ROLL = M.TIE_BREAK_ROLL

local function firstLiving(mons, skip)
  for i = 1, #mons do
    if mons[i].hp > 0 and i ~= skip then return i end
  end
  return nil
end

-- The seat's standing mon (the party table), or nil.
local function activeMon(fighter)
  local b = fighter.b
  if b and b.mon.hp > 0 then return b.mon end
  return nil
end

local function partyIndexOf(fighter, wireSlot)
  for i = 1, #fighter.mons do
    if fighter.mons[i].slot == wireSlot then return i end
  end
  return wireSlot + 1
end

function Battle:_newBattler(fighter, index)
  local mon = fighter.mons[index]
  local t1, t2 = mon.types[1], mon.types[2]
  local b = {
    fighter = fighter, slot = fighter.slot, side = fighter.side, mon = mon,
    partyIndex = index, speciesNum = mon.speciesNum,
    type1 = t1, type2 = (t2 ~= nil and t2 ~= t1) and t2 or nil,
    ability = Abilities.nameOf(mon.ability), abilityName = mon.abilityName,
    stats = mon.stats, moves = mon.moves, overlay = false,
    stages = { atk = 0, def = 0, spe = 0, spa = 0, spd = 0, acc = 0, eva = 0 },
    isFirstTurn = 2, toxicCounter = 0,
  }
  return b
end

function Battle:_sendEvent(fighter)
  local b = fighter.b
  local mon = b.mon
  self:_emit("send", {
    slot = fighter.slot, side = fighter.side, hp = mon.hp, maxHp = mon.maxHp,
    text = mon.species, speciesId = mon.speciesId, level = mon.level,
    mon = fighter.active - 1, status = mon.status,
    confused = (int(b.confusion, 0) > 0) and 1 or nil,
  })
end

-- opts:
--   id, mode, seed, typeTable (alias chart), specialTypes, movePool, terrain,
--   weather, underwater, choiceTimeout, reconnectGrace, resolveTimeout, now,
--   sides = { a = { { playerId, name, mons, bag } }, b = { ... } }
function M.create(opts)
  if type(opts) ~= "table" then return nil, "battle needs an options table" end

  local mode = M.MODES[opts.mode] and opts.mode or "1v1"

  local self = setmetatable({
    id             = str(opts.id) or "battle",
    mode           = mode,
    seed           = int(opts.seed, 0),
    rng            = Rng.new(int(opts.seed, 0)),
    aim            = Rng.new(int(opts.seed, 0) + M.AIM_SEED_OFFSET),
    typeTable      = Types.copyTable(opts.typeTable or opts.chart),
    specialTypes   = nil,
    pool           = nil,
    terrain        = clamp(int(opts.terrain, Field.DEFAULT_TERRAIN), 0, 9),
    initialWeather = Field.kind(opts.weather),
    underwater     = opts.underwater == true,
    field          = { weather = nil, weatherTurns = 0 },
    sides          = { a = Field.newSide(), b = Field.newSide() },
    choiceTimeout  = max(0, int(opts.choiceTimeout, M.CHOICE_TIMEOUT)),
    reconnectGrace = max(0, int(opts.reconnectGrace, M.RECONNECT_GRACE)),
    resolveTimeout = max(0, int(opts.resolveTimeout, M.RESOLVE_TIMEOUT)),
    now            = max(0, int(opts.now, 0)),
    phase          = "choice",
    turn           = 1,
    seq            = 0,
    buffer         = {},
    pendingExp     = {},
    fighters       = {},
    byId           = {},
    bySide         = { a = {}, b = {} },
    order          = {},
    result         = nil,
    resolveDeadline = nil,
    fleeAttempts   = 0,
    payDay         = { a = 0, b = 0 },  -- pret gPaydayMoney, per side (Effects PAYDAY)
    usedHeldItems  = {},                -- Recycle's memory, per field slot (Items.consume)
  }, Battle)

  if type(opts.specialTypes) == "table" then
    local set = {}
    for i = 1, #opts.specialTypes do set[clamp(int(opts.specialTypes[i], 0), 0, 31)] = true end
    self.specialTypes = set
  end
  if type(opts.movePool) == "table" then
    local pool, any = {}, false
    for i = 1, #opts.movePool do
      local row = parsePoolEntry(opts.movePool[i])
      if row and row.num > 0 and not pool[row.num] then pool[row.num] = row; any = true end
    end
    if any then self.pool = pool end
  end

  local sides = type(opts.sides) == "table" and opts.sides or {}
  for _, side in ipairs(M.SIDES) do
    local roster = type(sides[side]) == "table" and sides[side] or {}
    if #roster == 0 then return nil, "side " .. side .. " has nobody on it" end
    if #roster > maxFighters(mode, side) then
      return nil, "side " .. side .. " has more fighters than " .. mode .. " allows"
    end
    if mode == "coop_wild" and side == "a" and #roster < 2 then
      return nil, "side a has fewer fighters than coop_wild allows"
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
          local mon = copyMon(entry.mons[i], #mons)
          if mon then mons[#mons + 1] = mon end
        end
      end
      if #mons == 0 then return nil, playerId .. " brought no monsters" end
      local bag, bagNames = copyBag(entry.bag)
      local fighter = {
        playerId = playerId, name = str(entry.name) or playerId, side = side,
        index = index, slot = Events.fieldSlot(side, index), mons = mons,
        bag = bag, bagNames = bagNames or {}, active = firstLiving(mons),
        connected = true, graceEndsAt = nil, choice = nil, team = nil, fought = {},
      }
      self.fighters[#self.fighters + 1] = fighter
      self.byId[playerId] = fighter
      local bucket = self.bySide[side]
      bucket[#bucket + 1] = fighter
    end
  end

  -- pret battler ids interleave the sides: a1, b1, a2, b2, a3, b3.
  for i = 1, M.FIGHTERS_PER_SIDE do
    if self.bySide.a[i] then self.order[#self.order + 1] = self.bySide.a[i] end
    if self.bySide.b[i] then self.order[#self.order + 1] = self.bySide.b[i] end
  end
  self.double = #self.bySide.a > 1 or #self.bySide.b > 1

  for _, fighter in ipairs(self.fighters) do
    if fighter.active then fighter.b = self:_newBattler(fighter, fighter.active) end
  end
  for _, fighter in ipairs(self.fighters) do self:_refield(fighter) end
  for _, fighter in ipairs(self.fighters) do
    if fighter.b then self:_sendEvent(fighter) end
  end

  self.phase = "resolving"
  self:_battleStart()
  self:_drainExp()
  self.phase = "choice"
  if not self.result and self:_anyMustReplace() then
    self:_openReplace()
    return self
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

function Battle:_syncTeams()
  for _, fighter in ipairs(self.fighters) do
    local roster = Events.teamString(fighter.mons)
    if roster ~= fighter.team then
      fighter.team = roster
      self:_emit("team", { slot = fighter.slot, side = fighter.side, team = roster })
    end
  end
end

function Battle:drainEvents()
  local out = self.buffer
  self.buffer = {}
  return out
end

-- ------------------------------------------------------------------
-- the field
-- ------------------------------------------------------------------

function Battle:_foeSeats(fighter)
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
  for _, foe in ipairs(self:_foeSeats(fighter)) do
    if activeMon(foe) then return foe end
  end
  return nil
end

-- BattleSim2's aim stream: uniform over the living opposing seats, one byte
-- drawn only when two or more stand.
function Battle:_autoTarget(fighter)
  local living = {}
  for _, foe in ipairs(self:_foeSeats(fighter)) do
    if activeMon(foe) then living[#living + 1] = foe end
  end
  if #living == 0 then return nil end
  if #living == 1 then return living[1] end
  return living[(self.aim:byte() % #living) + 1]
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

function Battle:_owes(fighter)
  if fighter.choice ~= nil then return false end
  if fighter.mustReplace then return firstLiving(fighter.mons) ~= nil end
  if self.phase == "replace" then return false end
  if activeMon(fighter) == nil then return false end
  return true
end

-- Forced lock-in (the cart withholds the menu): recharge, a two-turn release,
-- Bide, rampage, Uproar, Rollout.  The resolution narrates, not the fill.
function Battle:_fillForcedChoices()
  for _, fighter in ipairs(self.fighters) do
    local b = fighter.b
    if fighter.choice == nil and b and b.mon.hp > 0 then
      local choice = nil
      if b.mustRecharge then
        choice = { action = "fight", recharge = true, move = b.lastSlot or 1 }
      elseif b.lockedNum then
        choice = { action = "fight", locked = true, move = b.lockedSlot or 1 }
      end
      if choice then
        fighter.forced = true
        fighter.choice = choice
        self:_emit("chose", { slot = fighter.slot, side = fighter.side, text = fighter.name })
      end
    end
  end
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

function Battle:_bagHas(fighter, item)
  return fighter.bag and (fighter.bag[item] or 0) > 0
end

function Battle:_spendBag(fighter, item)
  if not fighter.bag then return end
  local n = fighter.bag[item]
  if not n then return end
  if n <= 1 then fighter.bag[item] = nil else fighter.bag[item] = n - 1 end
end

-- Whether a bag item would do anything to this party member (the cart's
-- "It won't have any effect." refuses it before the turn is spent).
function Battle:_itemHasEffect(fighter, effect, index, moveIndex)
  local mon = fighter.mons[index]
  if not mon then return false end
  local b = (index == fighter.active) and fighter.b or nil
  if effect.revive then return mon.hp <= 0 end
  if mon.hp <= 0 then return false end
  if effect.activeOnly then
    if not b then return false end
    if effect.stage then return b.stages[effect.stage] < 6 end
    if effect.focusEnergy then return not b.focusEnergy end
    if effect.mist then return int(self.sides[b.side].mistTurns, 0) == 0 end
    return false
  end
  local any = false
  if effect.heal or effect.healFull then any = any or mon.hp < mon.maxHp end
  if effect.cure then
    local s = Status.normalise(mon.status)
    any = any or (s ~= nil and effect.cure[s] == true)
  end
  if effect.confusion and b then any = any or int(b.confusion, 0) > 0 end
  if effect.attract and b then any = any or b.infatuatedWith ~= nil end
  local moves = (b and b.moves) or mon.moves
  if effect.pp or effect.ppFull then
    local mv = moves[moveIndex or 0]
    any = any or (mv ~= nil and mv.pp < mv.maxPp)
  end
  if effect.ppAll or effect.ppAllFull then
    for i = 1, #moves do if moves[i].pp < moves[i].maxPp then any = true end end
  end
  return any
end

function Battle:_switchBlocked(b)
  if not b then return false end
  if self:isTrapped(b) then return true end
  return Abilities.escapeBlocker(self, b) ~= nil
end

function Battle:_normaliseChoice(fighter, choice)
  local action = choice.action

  if fighter.mustReplace then
    if action ~= "switch" then return nil end
    local slot = int(choice.slot, nil)
    if slot == nil then return nil end
    local target = partyIndexOf(fighter, slot)
    local bench = fighter.mons[target]
    if not bench or bench.hp <= 0 then return nil end
    return { action = "switch", slot = target }
  end

  local b = fighter.b
  if not b or b.mon.hp <= 0 then return nil end

  if action == "run" then
    if isWildMode(self.mode) then
      local he = Items.of(b)
      if he ~= Items.HOLD.CAN_ALWAYS_RUN and b.ability ~= "RUN_AWAY" and self:_switchBlocked(b) then
        return nil
      end
    end
    return { action = "run" }
  end

  if action == "item" then
    local item = Items.idOf(choice.item)
    if not item then return nil end
    if isWildSeat(self.mode, fighter) then return nil end
    if fighter.bag and not self:_bagHas(fighter, item) then return nil end
    local effect = Items.bagEffect(item)
    local out = { action = "item", item = item, dexCaught = choice.dexCaught == true }
    if not effect then return out end            -- "But it failed!", turn spent
    if effect.ball or effect.escape or effect.flute then return out end
    local index = fighter.active
    if choice.slot ~= nil then
      local slot = int(choice.slot, nil)
      if slot == nil then return nil end
      index = partyIndexOf(fighter, slot)
      if not fighter.mons[index] then return nil end
    end
    if effect.activeOnly and index ~= fighter.active then return nil end
    out.slot = index
    if choice.move ~= nil then
      local mv = int(choice.move, nil)
      if mv == nil then return nil end
      out.move = mv + 1
    elseif effect.needsMove then
      return nil
    end
    if not self:_itemHasEffect(fighter, effect, index, out.move) then return nil end
    return out
  end

  if action == "switch" then
    local slot = int(choice.slot, nil)
    if slot == nil then return nil end
    local target = partyIndexOf(fighter, slot)
    local bench = fighter.mons[target]
    if not bench or bench.hp <= 0 or target == fighter.active then return nil end
    if self:_switchBlocked(b) then return nil end
    return { action = "switch", slot = target }
  end

  if action == "fight" then
    local index = int(choice.move, nil)
    if index == nil then return nil end
    local out = { action = "fight", move = index + 1 }
    if not self:hasUsableMove(b) then
      out.struggle = true
      out.move = 1
    else
      local encoreSlot = (int(b.encoreTurns, 0) > 0 and b.encoreNum) and self:slotOfNum(b, b.encoreNum) or nil
      if encoreSlot then
        out.move = encoreSlot
      else
        if not b.moves[index + 1] then return nil end
        local bad = self:moveLimitations(b)
        if bad[index + 1] then return nil end
      end
    end
    local row = out.struggle and Move.STRUGGLE or b.moves[out.move]
    local ttype = int(row.target, 0)
    if ttype == T.SELECTED or ttype == T.USER_OR_SELECTED then
      local tf
      if choice.target ~= nil then
        tf = self:_fighterAtSlot(int(choice.target, -1))
        if not tf or tf == fighter then return nil end
        if not activeMon(tf) and not tf.mustReplace then return nil end
      else
        tf = self:_firstLivingFoe(fighter)
        if not tf then
          for _, foe in ipairs(self:_foeSeats(fighter)) do
            if foe.mustReplace then tf = foe; break end
          end
        end
      end
      if not tf then return { action = "skip" } end
      out.target = tf.slot
    else
      local tf = self:_firstLivingFoe(fighter)
      if tf then out.target = tf.slot end
    end
    if choice.pass ~= nil then
      local p = int(choice.pass, nil)
      if p ~= nil then
        local idx = partyIndexOf(fighter, p)
        if fighter.mons[idx] and fighter.mons[idx].hp > 0 and idx ~= fighter.active then out.pass = idx end
      end
    end
    return out
  end

  return nil
end

function Battle:submitChoice(playerId, choice)
  if self.phase ~= "choice" and self.phase ~= "replace" then return false end
  if type(choice) ~= "table" then return false end
  local fighter = self.byId[str(playerId) or ""]
  if not fighter then return false end
  if not fighter.connected then return false end
  if not ACTIONS[choice.action] then return false end
  if self.phase == "replace" and not self:_owes(fighter) then return false end

  if choice.action == "cancel" then
    if self.phase == "replace" then return false end
    if fighter.choice == nil then return false end
    if fighter.forced then return false end
    self:_emit("unchose", { slot = fighter.slot, side = fighter.side, text = fighter.name })
    fighter.choice = nil
    return true
  end

  if fighter.choice ~= nil then return false end
  if fighter.mustReplace then
    if choice.action ~= "switch" then return false end
  elseif not activeMon(fighter) then
    return false
  end

  local normalised = self:_normaliseChoice(fighter, choice)
  if not normalised then return false end
  fighter.choice = normalised
  self:_emit("chose", { slot = fighter.slot, side = fighter.side, text = fighter.name })
  self:_maybeResolve()
  return true
end

function Battle:_anyoneOwes()
  for _, fighter in ipairs(self.fighters) do
    if self:_owes(fighter) then return true end
  end
  return false
end

function Battle:_maybeResolve()
  if self.phase ~= "choice" and self.phase ~= "replace" then return false end
  if self:_anyDisconnected() then return false end
  for _, fighter in ipairs(self.fighters) do
    if self:_owes(fighter) then return false end
  end
  if self.phase == "replace" then
    self:_closeReplace()
    return true
  end
  self:_resolveTurn()
  return true
end

-- ------------------------------------------------------------------
-- the auto-pick (timeout / NPC): BattleSim2's heuristic on Gen 3 ids
-- ------------------------------------------------------------------

-- EFFECT_* status moves worth using, by preference.
local AUTO_STATUS_PRI = {
  [E.SLEEP] = 4, [E.PARALYZE] = 3, [E.TOXIC] = 3, [E.POISON] = 2, [E.WILL_O_WISP] = 2,
  [E.CONFUSE] = 1, [E.LEECH_SEED] = 1,
}
-- Self boosts / screens / Substitute: stat key, or true for a flag move.
local AUTO_SETUP = {
  [E.ATTACK_UP] = "atk", [E.DEFENSE_UP] = "def", [E.SPEED_UP] = "spe",
  [E.SPECIAL_ATTACK_UP] = "spa", [E.SPECIAL_DEFENSE_UP] = "spd",
  [E.ATTACK_UP_2] = "atk", [E.DEFENSE_UP_2] = "def", [E.SPEED_UP_2] = "spe",
  [E.SPECIAL_ATTACK_UP_2] = "spa", [E.SPECIAL_DEFENSE_UP_2] = "spd",
  [E.CALM_MIND] = "spa", [E.BULK_UP] = "atk", [E.DRAGON_DANCE] = "atk", [E.COSMIC_POWER] = "def",
  [E.FOCUS_ENERGY] = true, [E.LIGHT_SCREEN] = true, [E.REFLECT] = true, [E.SUBSTITUTE] = true,
}
-- Heal items, strongest first; cures by status; X items (Gen 3 ids).
local AUTO_HEAL_PREF = { 19, 20, 21, 31, 29, 28, 22, 27, 26, 30, 13, 44, 142, 139 }
local AUTO_STATUS_CURE = {
  PSN = { 19, 23, 32, 38, 141, 14, 135 }, TOX = { 19, 23, 32, 38, 141, 14, 135 },
  BRN = { 19, 23, 32, 38, 141, 15, 136 }, FRZ = { 19, 23, 32, 38, 141, 16, 137 },
  SLP = { 19, 23, 32, 38, 141, 17, 134, 39 }, PAR = { 19, 23, 32, 38, 141, 18, 133 },
}
local AUTO_X_ITEM = { 75, 76, 77, 79, 74, 73 }

function Battle:_effectivenessProduct(moveType, defender)
  local product = Types.effectivenessOf(self.typeTable, moveType, defender.type1, defender.type2,
    defender.identified)
  return product
end

function Battle:_bestSeBench(fighter, defender)
  if not defender then return nil end
  local best, bestEff = nil, 100
  for i = 1, #fighter.mons do
    if i ~= fighter.active then
      local bench = fighter.mons[i]
      if bench and bench.hp > 0 then
        local maxEff = 100
        for j = 1, #bench.moves do
          local m = bench.moves[j]
          if m.pp > 0 and m.power > 0 then
            local eff = self:_effectivenessProduct(m.type, defender)
            if eff > maxEff then maxEff = eff end
          end
        end
        if maxEff > 100 then
          if not best or maxEff > bestEff or (maxEff == bestEff and i < best) then
            best, bestEff = i, maxEff
          end
        end
      end
    end
  end
  return best
end

function Battle:_autoItemChoice(fighter, b)
  if not fighter.bag then return nil end
  if isWildSeat(self.mode, fighter) then return nil end
  local mon = b.mon
  local s = Status.normalise(mon.status)
  if s then
    for _, id in ipairs(AUTO_STATUS_CURE[s] or {}) do
      if self:_bagHas(fighter, id) then
        return { action = "item", item = id, slot = fighter.active }
      end
    end
  end
  if mon.hp < mon.maxHp and mon.hp * 2 <= mon.maxHp then
    for _, id in ipairs(AUTO_HEAL_PREF) do
      if self:_bagHas(fighter, id) then
        return { action = "item", item = id, slot = fighter.active }
      end
    end
  end
  local flat = b.stages.atk <= 0 and b.stages.def <= 0 and b.stages.spe <= 0 and b.stages.spa <= 0
  if flat and not b.focusEnergy then
    for _, id in ipairs(AUTO_X_ITEM) do
      if self:_bagHas(fighter, id) then
        local effect = Items.bagEffect(id)
        if effect and self:_itemHasEffect(fighter, effect, fighter.active) then
          return { action = "item", item = id, slot = fighter.active }
        end
      end
    end
  end
  return nil
end

function Battle:_autoChoice(fighter)
  if fighter.mustReplace then
    local foe = self:_autoTarget(fighter)
    local defender = foe and foe.b
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
    local next_ = firstLiving(fighter.mons)
    if next_ then return { action = "switch", slot = next_ } end
    return nil
  end

  local b = fighter.b
  if not b or b.mon.hp <= 0 then return nil end
  if b.mustRecharge then return { action = "fight", recharge = true, move = b.lastSlot or 1 } end
  if b.lockedNum then return { action = "fight", locked = true, move = b.lockedSlot or 1 } end

  local foe = self:_autoTarget(fighter)
  if not foe then
    for _, f in ipairs(self:_foeSeats(fighter)) do
      if f.mustReplace then foe = f; break end
    end
  end
  if not foe then return nil end

  if not self:hasUsableMove(b) then
    return { action = "fight", move = 1, struggle = true, target = foe.slot }
  end
  local defender = foe.b
  local bad = self:moveLimitations(b)
  if not defender or defender.mon.hp <= 0 then
    for i = 1, #b.moves do
      if not bad[i] then return { action = "fight", move = i, target = foe.slot } end
    end
    return { action = "fight", move = 1, struggle = true, target = foe.slot }
  end

  local itemPick = self:_autoItemChoice(fighter, b)
  if itemPick then return itemPick end

  local ds = defender.stages
  local foeBoosted = ds.atk >= 2 or ds.def >= 2 or ds.spe >= 2 or ds.spa >= 2 or defender.focusEnergy
  local foeSub = int(defender.substituteHP, 0) > 0
  local weSlower = self:_speedOf(b) < self:_speedOf(defender)
  local canSwitch = not self:_switchBlocked(b)

  if b.mon.hp * 4 <= b.mon.maxHp and canSwitch then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end
  if (foeBoosted or foeSub) and b.mon.hp * 2 <= b.mon.maxHp and canSwitch then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end

  local pick, pickEff, pickPow = nil, -1, -1
  for i = 1, #b.moves do
    local m = b.moves[i]
    if not bad[i] and m.power > 0 then
      local eff = self:_effectivenessProduct(m.type, defender)
      if not pick or eff > pickEff or (eff == pickEff and m.power > pickPow)
         or (eff == pickEff and m.power == pickPow and i < pick) then
        pick, pickEff, pickPow = i, eff, m.power
      end
    end
  end

  if ((not pick) or pickEff == 0) and canSwitch then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end
  if pick and pickEff > 100 then
    return { action = "fight", move = pick, target = foe.slot }
  end

  if not Status.normalise(defender.mon.status) and not foeSub then
    local statusPick, statusPri = nil, -1
    for i = 1, #b.moves do
      local m = b.moves[i]
      if not bad[i] and m.power == 0 then
        local pri = AUTO_STATUS_PRI[m.effect]
        if pri and pri > statusPri then statusPick, statusPri = i, pri end
      end
    end
    if statusPick and (weSlower or foeBoosted or not pick or pickEff <= 100) then
      return { action = "fight", move = statusPick, target = foe.slot }
    end
  end

  local flat = b.stages.atk <= 0 and b.stages.def <= 0 and b.stages.spe <= 0 and b.stages.spa <= 0
  if flat and not b.focusEnergy and not foeBoosted and not foeSub
     and not (weSlower and b.mon.hp * 2 <= b.mon.maxHp) then
    for i = 1, #b.moves do
      local m = b.moves[i]
      if not bad[i] and m.power == 0 then
        local kind = AUTO_SETUP[m.effect]
        if kind == true or (type(kind) == "string" and b.stages[kind] <= 0) then
          return { action = "fight", move = i, target = foe.slot }
        end
      end
    end
  end

  if not (pick and pickEff > 0) then
    pick, pickPow = nil, -1
    for i = 1, #b.moves do
      local m = b.moves[i]
      if not bad[i] and (not pick or m.power > pickPow) then pick, pickPow = i, m.power end
    end
  end
  return { action = "fight", move = pick or 1, target = foe.slot }
end

function Battle:_autoChoiceOrSkip(fighter)
  local auto = self:_autoChoice(fighter)
  if auto then return auto end
  if self.phase == "choice" and activeMon(fighter) then return { action = "skip" } end
  return nil
end

function Battle:autoPick(playerId)
  if self.phase ~= "choice" and self.phase ~= "replace" then return false end
  local fighter = self.byId[str(playerId) or ""]
  if not fighter then return false end
  if fighter.choice ~= nil then return false end
  if self.phase == "replace" and not self:_owes(fighter) then return false end
  if not fighter.mustReplace and not activeMon(fighter) then return false end
  local auto = self:_autoChoiceOrSkip(fighter)
  if not auto then return false end
  fighter.choice = auto
  self:_emit("chose", { slot = fighter.slot, side = fighter.side, text = fighter.name })
  self:_maybeResolve()
  return true
end

-- ------------------------------------------------------------------
-- phases
-- ------------------------------------------------------------------

function Battle:_openTurn()
  if self:_checkOver() then return end
  self.phase = "choice"
  self.resolveDeadline = nil
  self.forcedPending = false
  for _, fighter in ipairs(self.fighters) do
    fighter.choice = nil
    fighter.forced = nil
    fighter.acted = nil
  end
  self.deadline = (self.choiceTimeout > 0) and (self.now + self.choiceTimeout) or nil
  self:_syncTeams()
  self:_emit("turn", { amount = self.turn })
  self:_fillForcedChoices()
  if not self:_anyoneOwes() then
    self.forcedPending = true
    self.deadline = nil
  end
end

function Battle:_anyMustReplace()
  for _, fighter in ipairs(self.fighters) do
    if fighter.mustReplace and firstLiving(fighter.mons) ~= nil then return true end
  end
  return false
end

function Battle:_openReplace()
  self.phase = "replace"
  self.resolveDeadline = nil
  self.forcedPending = false
  for _, fighter in ipairs(self.fighters) do
    fighter.choice = nil
    fighter.forced = nil
  end
  self.deadline = (self.choiceTimeout > 0) and (self.now + self.choiceTimeout) or nil
  self:_syncTeams()
  for _, fighter in ipairs(self.fighters) do
    if self:_owes(fighter) then
      self:_emit("turn", { amount = self.turn, slot = fighter.slot })
    end
  end
end

function Battle:_closeReplace()
  self.phase = "resolving"
  for _, fighter in ipairs(self.order) do
    local choice = fighter.choice
    if choice and choice.action == "switch" and not self.result then
      local mon = fighter.mons[choice.slot]
      if mon and mon.hp > 0 then
        local nb = self:_switchIn(fighter, choice.slot)
        self:switchInEffects(nb, { spikes = true })
        self:_faintSweep()
      end
    end
  end
  -- A delayed hit that came due on an emptied seat lands on the newcomer, as
  -- the cart's replacement-first end of turn has it (Residual.lua).
  if not self.result then self:_landPendingFutureSight() end
  self:_drainExp()
  self.phase = "choice"
  if not self.result then self:_checkOver() end
  if self.result then return end
  if self:_anyMustReplace() then
    self:_openReplace()
    return
  end
  self.turn = self.turn + 1
  self:_openTurn()
end

-- ------------------------------------------------------------------
-- switching
-- ------------------------------------------------------------------

-- Drop every link another battler holds to one that is leaving
-- (pokefirered/src/battle_main.c:2329 SwitchInClearSetData / battle_script_
-- commands.c:4966).  `baton`: a Baton Pass keeps the passer's Mean Look-style
-- traps and Lock-Ons standing -- the cart stores them by battler POSITION, so
-- the newcomer inherits them (`_switchIn` re-points them).
function Battle:_unlink(old, baton)
  for _, f in ipairs(self.order) do
    local b = f.b
    if b and b ~= old then
      if b.infatuatedWith == old then b.infatuatedWith = nil end
      if b.trapSource == old then b.trapTurns, b.trapMove, b.trapSource = nil, nil, nil end
      if not baton then
        if b.trappedBy == old then b.trappedBy = nil end
        if b.lockedOnBy == old then b.lockedOnTurns, b.lockedOnBy = nil, nil end
      end
    end
  end
  for _, side in ipairs(M.SIDES) do
    if self.sides[side].followMe == old then self.sides[side].followMe = nil end
  end
end

-- Put party member `index` out on this seat (voluntary switch, replacement,
-- Roar, Baton Pass).  `baton` is the battler passing its volatiles on.
function Battle:_switchIn(fighter, index, baton)
  local old = fighter.b
  if old then
    if old.mon.hp > 0 then Abilities.switchOut(self, old) end
    self:_unlink(old, baton ~= nil)
    fighter.lastB = old
  end
  fighter.active = index
  fighter.mustReplace = nil
  local nb = self:_newBattler(fighter, index)
  if baton then
    -- pokefirered/src/battle_main.c:2350: status2 keeps confusion, Focus
    -- Energy, Substitute, escape prevention and Curse; status3 keeps Leech Seed,
    -- Lock-On, Perish Song, Ingrain and Mud / Water Sport.
    for k, v in pairs(baton.stages) do nb.stages[k] = v end
    nb.confusion = baton.confusion
    nb.focusEnergy = baton.focusEnergy
    nb.substituteHP = baton.substituteHP
    nb.seededBy = baton.seededBy
    nb.ingrain = baton.ingrain
    nb.perishTurns = baton.perishTurns
    nb.cursed = baton.cursed
    nb.trappedBy = baton.trappedBy
    nb.lockedOnTurns = baton.lockedOnTurns
    nb.lockedOnBy = baton.lockedOnBy
    nb.mudSport = baton.mudSport
    nb.waterSport = baton.waterSport
    -- ...and what the passer held on others moves with the position: a foe it
    -- trapped stays trapped, and a foe it Locked On to is re-armed for two
    -- turns for the newcomer (:2356, STATUS3_ALWAYS_HITS_TURN(2)).
    for _, f in ipairs(self.order) do
      local b = f.b
      if b and b ~= old then
        if b.trappedBy == old then b.trappedBy = nb end
        if b.lockedOnBy == old then
          b.lockedOnBy = nb
          if b.side ~= nb.side then b.lockedOnTurns = 2 end
        end
      end
    end
  end
  fighter.b = nb
  self:_refield(fighter)
  local mon = nb.mon
  self:_emit("switch", { slot = fighter.slot, side = fighter.side, text = mon.species,
                         speciesId = mon.speciesId, level = mon.level, mon = index - 1 })
  self:_sendEvent(fighter)
  return nb
end

-- Roar / Whirlwind / Baton Pass (Effects.lua).
function Battle:forceSwitch(fighter, index, reason, baton)
  if not fighter.mons[index] or fighter.mons[index].hp <= 0 then return nil end
  local nb = self:_switchIn(fighter, index, reason == "baton_pass" and baton or nil)
  if reason == "baton_pass" and fighter.lastB and int(fighter.lastB.substituteHP, 0) > 0 then
    self:_emit("sub", { slot = fighter.slot, side = fighter.side, amount = 1 })
  end
  return nb
end

-- Whirlwind / Roar blowing a battler out of a wild fight ends it
-- (pokefirered/data/battle_scripts_1.s:3283).
function Battle:blownAway(b)
  self:_concedeRun(b.fighter)
end

-- Teleport out of a wild fight.
function Battle:concede(fighter)
  self:_concedeRun(fighter)
end

function Battle:_concedeRun(fighter)
  self:_emit("run", { slot = fighter.slot, side = fighter.side, text = fighter.name })
  if fighter.side == "a" then
    self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "run")
  else
    self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "run")
  end
end

-- ------------------------------------------------------------------
-- resolution
-- ------------------------------------------------------------------

-- pokefirered/src/battle_main.c:3623 (engine clear_turn_flags)
function Battle:_clearTurnFlags(b)
  b.protected, b.enduring, b.magicCoat, b.snatch, b.helpingHand = nil, nil, nil, nil, nil
  b.flinched = nil
  b.lastPhysDmg, b.lastPhysBy, b.lastSpecDmg, b.lastSpecBy = nil, nil, nil, nil
  b.lightningRodRedirected = nil
  b.movedThisTurn = nil
  b.turnOrder = nil
  b.unableToMove = nil
  b.statLoweredMsg = nil
  if int(b.isFirstTurn, 0) > 0 then b.isFirstTurn = b.isFirstTurn - 1 end
  if b.rechargeTurns then
    b.rechargeTurns = b.rechargeTurns - 1
    if b.rechargeTurns <= 0 then b.rechargeTurns, b.mustRecharge = nil, nil end
  end
end

-- Order the turn (pokefirered/src/battle_main.c:3532 SetActionsAndBattlersTurnOrder).
function Battle:_beginTurn()
  for _, f in ipairs(self.order) do
    if f.b then self:_clearTurnFlags(f.b) end
  end
  self.sides.a.followMe, self.sides.b.followMe = nil, nil

  local rows = {}
  for i, f in ipairs(self.order) do
    local b = f.b
    local choice = f.choice
    if b and b.mon.hp > 0 and choice and choice.action == "fight" then
      -- A recharge turn chooses no move (pokefirered/src/battle_main.c:3126
      -- withholds the menu; :2993 left gChosenMoveByBattler MOVE_NONE): Rage
      -- ends, no Focus Punch line, bracket 0 (the cart reads the stale chosen
      -- slot, :3490 -- the recharge move or its caller, priority 0 on every
      -- cart).  A branch, because `choice.recharge and nil or x` is always x.
      local row = nil
      if not choice.recharge then row = self:_actionMove(b, choice) end
      -- pokefirered/src/battle_util.c:1223: Rage ends unless Rage is used again
      local num = row and int(row.num, 0) or 0
      if b.rage and num ~= Move.MOVE.RAGE then b.rage = nil end
      rows[#rows + 1] = { f = f, b = b, row = row, pri = row and int(row.priority, 0) or 0, order = i }
    elseif b then
      -- A seat that chose no move (bag, switch, run) has gChosenMoveByBattler
      -- MOVE_NONE (battle_main.c:2993), which is not Rage.  The Fury Cutter
      -- counter is NOT cleared by choosing something else in Gen 3 (pret has
      -- no such check): a miss, the bag, a failed run, a switch or a canceller
      -- stop resets it (CancelMultiTurnMoves / ClearFuryCutterDestinyBondGrudge).
      b.rage = nil
    end
  end

  self.randomTurnNumber = nil
  if #rows >= 2 then
    local anyClaw = false
    for _, r in ipairs(rows) do
      if Items.has(r.b, Items.HOLD.QUICK_CLAW) then anyClaw = true end
    end
    if anyClaw then self.randomTurnNumber = self:roll(0, 0xFFFF) end
  end
  for _, r in ipairs(rows) do r.spe = self:_speedOf(r.b) end
  self:_orderRows(rows)

  -- Turn-order numbers (Protect / Magic Coat / Snatch "moved last" checks):
  -- meta actions first in battler order, then the fighters, then the rest.
  local list, seen = {}, {}
  for _, f in ipairs(self.order) do
    local a = f.choice and f.choice.action
    if a == "switch" or a == "item" or a == "run" then list[#list + 1] = f; seen[f] = true end
  end
  for _, r in ipairs(rows) do list[#list + 1] = r.f; seen[r.f] = true end
  for _, f in ipairs(self.order) do
    if not seen[f] then list[#list + 1] = f end
  end
  for i, f in ipairs(list) do
    if f.b then f.b.turnOrder = i end
  end
  self.turnOrderFighters = list
  self.fightRows = rows
  self.turnPriority = {}
  for _, r in ipairs(rows) do self.turnPriority[r.b] = r.pri end

  -- pokefirered/src/battle_main.c:3669 CheckFocusPunch_ClearVarsBeforeTurnStarts
  for _, r in ipairs(rows) do
    if r.row and int(r.row.effect, -1) == E.FOCUS_PUNCH and not r.b.lockedNum
        and Status.normalise(r.b.mon.status) ~= "SLP" then
      self:_emit("anim", { slot = r.b.slot, side = r.b.side, text = "FOCUS_PUNCH_SETUP" })
      self:say(self:nameOf(r.b) .. " is tightening its focus!")
    end
  end
end

function Battle:_resolveTurn()
  self.phase = "resolving"
  self.resolveDeadline = (self.resolveTimeout > 0) and (self.now + self.resolveTimeout) or nil

  self:_beginTurn()
  if self:_resolveRuns() then return end
  self:_resolveSwitches()
  if not self.result then self:_resolveItems() end
  if not self.result then self:_resolveFights() end
  if not self.result then self:_endTurn() end
  self:_faintSweep()
  self:_drainExp()
  if not self.result then self:_checkOver() end

  if not self.result and self:_anyMustReplace() then
    self:_openReplace()
    return
  end
  if not self.result then
    self.turn = self.turn + 1
    self:_openTurn()
  end
end

-- pokefirered/src/battle_main.c:4229 TryRunFromBattle (wild), a concession
-- (1v1 / coop_pvp), or the trainer refusal.
function Battle:_resolveRuns()
  local running = {}
  for _, fighter in ipairs(self.order) do
    if fighter.choice and fighter.choice.action == "run" then running[#running + 1] = fighter end
  end
  if #running == 0 then return false end

  if not runEndsBattle(self.mode) then
    self:say("No! There's no running from a trainer battle!")
    return false
  end

  if not isWildMode(self.mode) then
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

  for _, fighter in ipairs(running) do
    local b = fighter.b
    if b and b.mon.hp > 0 then
      fighter.acted = true
      local he = Items.of(b)
      local escaped = false
      if he == Items.HOLD.CAN_ALWAYS_RUN then
        local lbl = self:itemLabel(b)
        Items.heldEvent(self, b, int(b.mon.heldItem, 0), lbl)
        self:say(self:nameOf(b) .. " fled using its " .. lbl .. "!")
        escaped = true
      elseif b.ability == "RUN_AWAY" then
        self:emitAbility(b)
        self:say(self:nameOf(b) .. " fled using RUN AWAY!")
        escaped = true
      else
        local foe = self:foes(b)[1]
        local mySpe = int(b.mon.stats.spe, 0)
        local foeSpe = foe and int(foe.mon.stats.spe, 0) or 0
        if mySpe < foeSpe then
          local speedVar = (floor(mySpe * 128 / max(1, foeSpe)) + self.fleeAttempts * 30) % 256
          escaped = speedVar > self:roll(0, 255)
        else
          escaped = true
        end
        self.fleeAttempts = self.fleeAttempts + 1
        if escaped then self:say("Got away safely!") end
      end
      if escaped then
        self:_emit("run", { slot = fighter.slot, side = fighter.side, text = fighter.name })
        local other = fighter.side == "a" and "b" or "a"
        self:_finish("win", self:_sidePlayers(other), self:_sidePlayers(fighter.side), "run")
        return true
      end
      -- pokefirered/src/battle_main.c:4311: a failed escape clears Fury
      -- Cutter, Destiny Bond and Grudge like a bag action.
      b.furyCutter, b.destinyBond, b.grudge = nil, nil, nil
      self:say("Can't escape!")
    end
  end
  return false
end

-- Pursuit aimed at a seat that is switching out strikes first, doubled
-- (engine init.lua D.pursuitRow / switchStep; pret Cmd_pursuitrelated).
function Battle:_pursuitBefore(fighter)
  local foes = self:_foeSeats(fighter)
  for i = #foes, 1, -1 do
    local foe = foes[i]
    local fb = foe.b
    local choice = foe.choice
    if fb and fb.mon.hp > 0 and choice and choice.action == "fight" and not foe.acted
        and fighter.b and fighter.b.mon.hp > 0 then
      local row = (not choice.recharge) and self:_actionMove(fb, choice) or nil
      local s = Status.normalise(fb.mon.status)
      if row and int(row.effect, -1) == E.PURSUIT and choice.target == fighter.slot
          and s ~= "SLP" and s ~= "FRZ" and int(fb.truantCounter, 0) == 0 then
        foe.acted = true
        self:_fightAction(foe, choice, { pursuit = true })
        self:_afterAction()
        self:_faintSweep()
        self:_drainExp()
        if not self.result then self:_checkOver() end
        if self.result then return end
      end
    end
  end
end

-- pokefirered/src/battle_main.c:3532 SetActionsAndBattlersTurnOrder: the
-- switch and bag actions go first, TOGETHER, in battler order (a1, b1, a2, ...),
-- ahead of every move -- a1's Potion before b1's switch.  Balls are the one
-- exception, BattleSim2's policy (sheet doc §6): they wait for the other bag
-- actions and are thrown fastest first (`_resolveItems`).
function Battle:_resolveSwitches()
  for _, fighter in ipairs(self.order) do
    if self.result then return end
    local choice = fighter.choice
    if choice and choice.action == "switch" then
      local mon = fighter.mons[choice.slot]
      if fighter.b and fighter.b.mon.hp > 0 then self:_pursuitBefore(fighter) end
      if self.result then return end
      if mon and mon.hp > 0 and (fighter.b == nil or fighter.b.mon.hp > 0) then
        fighter.acted = true
        local nb = self:_switchIn(fighter, choice.slot)
        self:switchInEffects(nb, { spikes = true })
        self:_faintSweep()
        self:_drainExp()
        if not self.result then self:_checkOver() end
      end
    elseif choice and choice.action == "item" then
      local effect = Items.bagEffect(choice.item)
      if not (effect and effect.ball) then self:_useItem(fighter) end
    end
  end
end

-- The balls, after every other bag action, fastest thrower first.
function Battle:_resolveItems()
  local balls = {}
  for i, fighter in ipairs(self.order) do
    local choice = fighter.choice
    if choice and choice.action == "item" then
      local effect = Items.bagEffect(choice.item)
      if effect and effect.ball then
        balls[#balls + 1] = { f = fighter, pri = 0, spe = fighter.b and self:_speedOf(fighter.b) or 0, order = i }
      end
    end
  end
  self:_orderRows(balls)
  for _, r in ipairs(balls) do
    if self.result then return end
    self:_useItem(r.f)
  end
end

local SHAKE_TEXT = {
  [0] = "Oh, no! The POKeMON broke free!", [1] = "Aww! It appeared to be caught!",
  [2] = "Aargh! Almost had it!", [3] = "Shoot! It was so close, too!",
}

function Battle:_caughtSheet(b, ball)
  local mon = b.mon
  local moves = {}
  for i = 1, #mon.moves do moves[i] = copyMove(mon.moves[i]) end
  return {
    generation = 3, species = mon.species, speciesId = mon.speciesId, speciesNum = mon.speciesNum,
    level = mon.level, hp = mon.hp, maxHp = mon.maxHp, status = mon.status,
    stats = { atk = mon.stats.atk, def = mon.stats.def, spe = mon.stats.spe,
              spa = mon.stats.spa, spd = mon.stats.spd },
    types = { mon.types[1], mon.types[2] }, ability = mon.ability, heldItem = mon.heldItem,
    holdEffect = mon.holdEffect, holdEffectParam = mon.holdParam, gender = mon.gender,
    friendship = mon.friendship, nature = mon.nature, catchRate = mon.catchRate,
    ivs = mon.ivs, evs = mon.evs, personality = mon.personality, otId = mon.otId,
    moves = moves, ball = ball,
  }
end

function Battle:_useItem(fighter)
  local choice = fighter.choice
  if not (choice and choice.action == "item") then return end
  fighter.acted = true
  -- pokefirered/src/battle_main.c:4155 HandleAction_UseItem:
  -- ClearFuryCutterDestinyBondGrudge on the seat's battler.
  if fighter.b then
    fighter.b.furyCutter, fighter.b.destinyBond, fighter.b.grudge = nil, nil, nil
  end
  local item = choice.item
  local effect = Items.bagEffect(item)
  self:_emit("item", { slot = fighter.slot, side = fighter.side, text = tostring(item) })
  local label = fighter.bagNames[item]
  self:say(fighter.name .. " used " .. (label or "an item") .. "!")
  if not (effect and effect.noConsume) then self:_spendBag(fighter, item) end

  if not effect then
    self:say("But it failed!")
    return
  end

  if effect.ball then
    local foe = isWildMode(self.mode) and self:_firstLivingFoe(fighter) or nil
    local target = foe and foe.b
    if not target then
      self:say("But it failed!")
      return
    end
    local caught, shakes = Catch.attempt(item, target, self.rng, {
      types = target.mon.types, level = target.mon.level, turn = self.turn - 1,
      underwater = self.underwater, dexCaught = choice.dexCaught,
    })
    self:_emit("ball", { slot = fighter.slot, side = fighter.side, target = foe.slot,
                         amount = caught and 4 or shakes, text = tostring(item) })
    if caught then
      self:say("Gotcha! " .. self:nameOf(target) .. " was caught!")
      local finish = self:_finish("win", self:_sidePlayers(fighter.side),
        self:_sidePlayers(fighter.side == "a" and "b" or "a"), "catch")
      if finish then
        finish.caught = self:_caughtSheet(target, item)
        finish.catcher = fighter.playerId
      end
    else
      self:say(SHAKE_TEXT[shakes] or SHAKE_TEXT[0])
    end
    return
  end

  if effect.escape then
    if isWildMode(self.mode) then
      self:say("Got away safely!")
      self:_finish("win", self:_sidePlayers(fighter.side),
        self:_sidePlayers(fighter.side == "a" and "b" or "a"), "run")
    else
      self:say("But it failed!")
    end
    return
  end

  if effect.flute then
    local woke = false
    for _, seat in ipairs(self.order) do
      for i = 1, #seat.mons do
        local mon = seat.mons[i]
        if Status.normalise(mon.status) == "SLP" and mon.hp > 0 then
          woke = true
          if seat.b and seat.active == i then
            self:cure(seat.b, nil)
          else
            mon.status, mon.sleepTurns = nil, nil
          end
        end
      end
    end
    self:say(woke and "All sleeping POKeMON woke up!" or "Nothing happened.")
    self:_syncTeams()
    return
  end

  local index = choice.slot or fighter.active
  local mon = fighter.mons[index]
  local b = (index == fighter.active) and fighter.b or nil
  if not mon or not self:_itemHasEffect(fighter, effect, index, choice.move) then
    self:say("But it had no effect!")
    return
  end

  if effect.stage and b then
    Effects.changeStat(self, b, effect.stage, 1, { user = true })
    return
  end
  if effect.focusEnergy and b then
    b.focusEnergy = true
    self:say(self:nameOf(b) .. " is getting pumped!")
    return
  end
  if effect.mist and b then
    self.sides[b.side].mistTurns = Field.MIST_TURNS
    self:say(self:nameOf(b) .. "'s party became shrouded in MIST!")
    return
  end

  if effect.revive then
    local hp = (effect.revive == "full") and mon.maxHp or max(1, floor(mon.maxHp / 2))
    mon.hp = hp
    mon.status, mon.sleepTurns = nil, nil
    self:say(mon.species .. " was revived!")
    self:_syncTeams()
    return
  end

  if effect.pp or effect.ppFull or effect.ppAll or effect.ppAllFull then
    local moves = (b and b.moves) or mon.moves
    local function restore(mv, amount)
      if amount == true then mv.pp = mv.maxPp else mv.pp = min(mv.maxPp, mv.pp + amount) end
    end
    if effect.pp or effect.ppFull then
      restore(moves[choice.move], effect.ppFull and true or effect.pp)
    else
      for i = 1, #moves do restore(moves[i], effect.ppAllFull and true or effect.ppAll) end
    end
    self:say(mon.species .. "'s PP was restored.")
    if b then self:emitMovesOf(b) end
    return
  end

  if effect.healFull or effect.heal then
    local amount = effect.healFull and mon.maxHp or effect.heal
    if b then
      local gained = self:heal(b, amount)
      self:say(mon.species .. "'s HP was restored by " .. gained .. " point(s).")
    else
      local before = mon.hp
      mon.hp = min(mon.maxHp, mon.hp + amount)
      self:say(mon.species .. "'s HP was restored by " .. (mon.hp - before) .. " point(s).")
    end
  end
  local s = Status.normalise(mon.status)
  if effect.cure and s and effect.cure[s] then
    local text = mon.species .. " was cured of its " .. (Status.WORD[s] or "status") .. " problem."
    if b then
      b.nightmare = nil
      self:cure(b, text)
    else
      mon.status, mon.sleepTurns = nil, nil
      self:say(text)
    end
  end
  if effect.confusion and b and int(b.confusion, 0) > 0 then
    b.confusion = nil
    local text = mon.species .. " snapped out of confusion!"
    self:_emit("status", { slot = b.slot, side = b.side, confused = 0, text = text })
    self:say(text)
  end
  if effect.attract and b and b.infatuatedWith then
    b.infatuatedWith = nil
    self:say(mon.species .. " got over its infatuation.")
  end
  self:_syncTeams()
end

function Battle:_resolveFights()
  for _, r in ipairs(self.fightRows or {}) do
    if self.result then break end
    local f = r.f
    -- The battler that chose is the only one that acts: a replacement does not
    -- inherit the turn, and a Pursuit already spent it.
    if not f.acted and f.b == r.b and r.b.mon.hp > 0 then
      f.acted = true
      self:_fightAction(f, f.choice)
      self:_afterAction()
    end
    self:_faintSweep()
    self:_drainExp()
    if not self.result then self:_checkOver() end
  end
end

-- ------------------------------------------------------------------
-- faints
-- ------------------------------------------------------------------

function Battle:_faintSweep()
  for _, f in ipairs(self.order) do
    local b = f.b
    if b and b.mon.hp <= 0 and not b.faintAnnounced then self:_faintBattler(b) end
  end
end

-- ------------------------------------------------------------------
-- participation (BattleSim2's, verbatim in behaviour)
-- ------------------------------------------------------------------

local function foughtKey(slot, index)
  return slot .. ":" .. index
end

function Battle:_refield(fighter)
  fighter.fought = {}
  fighter.foughtSeats = nil
  local mine = activeMon(fighter) and fighter.active or nil
  local foes = self.bySide[fighter.side == "a" and "b" or "a"]
  for _, foe in ipairs(foes) do
    if activeMon(foe) then
      fighter.fought[foughtKey(foe.slot, foe.active)] = true
      if mine then
        foe.fought = foe.fought or {}
        foe.fought[foughtKey(fighter.slot, mine)] = true
      end
    end
  end
  local pending = fighter.pendingFought
  fighter.pendingFought = nil
  if pending then
    for i = 1, #pending do fighter.fought[pending[i]] = true end
  end
end

function Battle:_standingOpposition(fighter)
  local keys = {}
  local foes = self.bySide[fighter.side == "a" and "b" or "a"]
  for _, foe in ipairs(foes) do
    if activeMon(foe) then keys[#keys + 1] = foughtKey(foe.slot, foe.active) end
  end
  return keys
end

-- A participant that faints stops being one (it earns nothing), but its SEAT
-- is remembered as having fought (`foughtSeats`): pret's sentIn bits outlive a
-- faint, and a seat whose participants all fell still pays its Exp. Share
-- holders (`_awardExp`).
function Battle:_unfield(fighter, index)
  local key = foughtKey(fighter.slot, index)
  for _, other in ipairs(self.fighters) do
    if other.fought and other.fought[key] then
      other.foughtSeats = other.foughtSeats or {}
      other.foughtSeats[fighter.slot] = true
    end
    if other.fought then other.fought[key] = nil end
    local pending = other.pendingFought
    if pending then
      for i = #pending, 1, -1 do
        if pending[i] == key then table.remove(pending, i) end
      end
    end
  end
end

local EXP_MODES = { wild = true, coop_wild = true, coop_npc = true }
local EXP_OWNER_SIDE = "a"

function Battle:_awardExp(fallen, mon)
  if not EXP_MODES[self.mode] then return end
  if fallen.side == EXP_OWNER_SIDE then return end
  local fought = fallen.fought or {}
  local participants, alive = 0, {}
  local seatFought, seatPaid = {}, {}
  for _, fighter in ipairs(self.bySide[EXP_OWNER_SIDE]) do
    if fallen.foughtSeats and fallen.foughtSeats[fighter.slot] then seatFought[fighter] = true end
    for index = 1, #fighter.mons do
      if fought[foughtKey(fighter.slot, index)] then
        participants = participants + 1
        seatFought[fighter] = true
        if fighter.mons[index].hp > 0 then
          alive[#alive + 1] = { fighter = fighter, index = index }
          seatPaid[fighter] = true
        end
      end
    end
  end
  if participants == 0 then
    for _, fighter in ipairs(self.bySide[EXP_OWNER_SIDE]) do
      if activeMon(fighter) then
        participants = participants + 1
        alive[#alive + 1] = { fighter = fighter, index = fighter.active }
        seatFought[fighter], seatPaid[fighter] = true, true
      end
    end
  end
  for _, winner in ipairs(alive) do
    self:_emit("exp", {
      slot = winner.fighter.slot, species = mon.species, speciesId = mon.speciesId,
      level = mon.level, participants = participants, mon = winner.index - 1,
    })
  end
  -- pokefirered/src/battle_script_commands.c:3113 Cmd_getexp pays the living
  -- Exp. Share holders whether or not any participant still stands (viaSentIn
  -- 0 is a SAFE_DIV, :3170).  A seat that fought this foe but has nobody
  -- standing who did gets the holders-only fact: `participants` 0 and no
  -- `mon`.  Its client prices it as a knockout with an empty sentIn set, so
  -- only the holders' half is paid (sheet doc §7).
  for _, fighter in ipairs(self.bySide[EXP_OWNER_SIDE]) do
    if seatFought[fighter] and not seatPaid[fighter] and firstLiving(fighter.mons) then
      self:_emit("exp", {
        slot = fighter.slot, species = mon.species, speciesId = mon.speciesId,
        level = mon.level, participants = 0,
      })
    end
  end
end

function Battle:_drainExp()
  local queue = self.pendingExp
  if #queue == 0 then return end
  self.pendingExp = {}
  for i = 1, #queue do self:_awardExp(queue[i].fallen, queue[i].mon) end
end

-- A battler is down: the `faint` event, the participation bookkeeping, and the
-- seat's next step (BattleSim2 `_faint`).  Called at the engine's announcement
-- points (Move.lua tryFaint*, the residual steps, the action sweep).
function Battle:_faintBattler(b)
  if b.faintAnnounced then return end
  b.faintAnnounced = true
  local fighter = b.fighter
  if fighter.b ~= b then return end
  local mon = b.mon
  mon.hp = 0
  mon.status, mon.sleepTurns = nil, nil
  self:_unfield(fighter, b.partyIndex)
  self:_unlink(b)
  local next_ = firstLiving(fighter.mons)
  self:_emit("faint", {
    slot = fighter.slot, side = fighter.side, text = mon.species, amount = next_ and 1 or nil,
  })
  self:_syncTeams()
  self.pendingExp[#self.pendingExp + 1] = { fallen = fighter, mon = mon }
  fighter.lastB = b
  fighter.b = nil
  fighter.active = nil
  if next_ then
    fighter.mustReplace = true
    fighter.pendingFought = self:_standingOpposition(fighter)
  else
    fighter.mustReplace = nil
    fighter.pendingFought = nil
  end
  if self.phase ~= "resolving" then
    self:_drainExp()
    self:_checkOver()
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
    local result = self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "ko")
    -- pokefirered/src/battle_main.c:3764: only a WON battle runs
    -- BattleScript_PayDayMoneyAndPickUpItems (Cmd_givepaydaymoney), and the
    -- coins are the player side's.  Link rules pay nothing (1v1 / coop_pvp); in
    -- the other modes side a is the player side.  The Amulet Coin doubling
    -- (gBattleStruct->moneyMultiplier) and the wallet are the client's.
    local coins = int(self.payDay and self.payDay.a, 0)
    if result and EXP_MODES[self.mode] and coins > 0 then result.payDay = coins end
  else
    self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "ko")
  end
  return true
end

function Battle:_finish(outcome, winners, losers, reason)
  if self.result then return self.result end
  self.result = {
    battle = self.id, outcome = outcome, winners = winners, losers = losers, reason = reason,
  }
  self.phase = "over"
  self.deadline = nil
  self.resolveDeadline = nil
  self:_emit("over", { text = reason })
  return self.result
end

function Battle:outcome()
  return self.result
end

-- ------------------------------------------------------------------
-- the clock (BattleSim2's)
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

function Battle:reconnect(playerId)
  local fighter = self.byId[str(playerId) or ""]
  if not fighter or fighter.connected then return false end
  if self.result then return false end
  if fighter.graceEndsAt and self.now >= fighter.graceEndsAt then return false end
  fighter.connected = true
  fighter.graceEndsAt = nil
  self:_emit("reconnect", { side = fighter.side, text = fighter.name })
  if (self.phase == "choice" or self.phase == "replace")
     and not self:_anyDisconnected() and self.choiceTimeout > 0 then
    self.deadline = self.now + self.choiceTimeout
  end
  self:_maybeResolve()
  return true
end

function Battle:tick(nowSeconds)
  local now = int(nowSeconds, self.now)
  if now > self.now then self.now = now end
  if self.result then return false end

  if (self.phase == "choice" or self.phase == "replace") and self:_checkOver() then
    return true
  end

  if self.forcedPending and self.phase == "choice" and not self:_anyDisconnected() then
    self.forcedPending = false
    if not self:_anyoneOwes() then
      self:_maybeResolve()
      return true
    end
  end

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

  if self.phase == "resolving" and self.resolveDeadline and self.now >= self.resolveDeadline then
    self:_finish("draw", nil, nil, "timeout")
    return true
  end

  if (self.phase == "choice" or self.phase == "replace")
     and self.deadline and self.now >= self.deadline and not self:_anyDisconnected() then
    for _, fighter in ipairs(self.fighters) do
      if self:_owes(fighter) then
        local auto = self:_autoChoiceOrSkip(fighter)
        if auto then
          fighter.choice = auto
          self:_emit("chose", { slot = fighter.slot, side = fighter.side, text = fighter.name })
          self:say(fighter.name .. " ran out of time")
        end
      end
    end
    self:_maybeResolve()
    if (self.phase == "choice" or self.phase == "replace")
       and self.deadline and self.now >= self.deadline then
      self.deadline = self.now + self.choiceTimeout
    end
    return true
  end

  return false
end

-- ------------------------------------------------------------------
-- snapshot (tests and logs)
-- ------------------------------------------------------------------

function Battle:snapshot()
  local field, waiting = {}, {}
  for _, fighter in ipairs(self.fighters) do
    local b = fighter.b
    local mon = b and b.mon
    local party = {}
    for i = 1, #fighter.mons do party[i] = fighter.mons[i].hp end
    field[#field + 1] = {
      slot = fighter.slot, side = fighter.side, playerId = fighter.playerId, name = fighter.name,
      connected = fighter.connected, graceEndsAt = fighter.graceEndsAt,
      chose = fighter.choice ~= nil and fighter.choice.action or nil,
      mustReplace = fighter.mustReplace == true,
      species = mon and mon.species or nil,
      hp = mon and mon.hp or 0, maxHp = mon and mon.maxHp or 0,
      status = mon and mon.status or nil,
      party = party,
    }
    if self:_owes(fighter) then waiting[#waiting + 1] = fighter.playerId end
  end
  return {
    battle = self.id, mode = self.mode, phase = self.phase, turn = self.turn, seq = self.seq,
    now = self.now, deadline = self.deadline, resolveDeadline = self.resolveDeadline,
    over = self.result ~= nil, reason = self.result and self.result.reason or nil,
    rngState = self.rng:state(), weather = self.field.weather,
    field = field, waiting = waiting,
    payDay = { a = self.payDay.a, b = self.payDay.b },
  }
end

return M
