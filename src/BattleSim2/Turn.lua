-- The turn machine (Gen 2 scaffold): choices in, events out, and one party deciding.
--
-- Light port of BattleSim/Turn.lua onto BattleSim2 formulas.  Public API matches
-- Gen1 Turn (`create`, `submitChoice`, `tick`, …).  Sheet stats are
-- atk/def/spe/spa/spd (Sp.Def); legacy spd+spc still accepted on ingest.
-- Damage/crit/accuracy/status draws use Gen2 rules; Gen1 effect-id table and
-- item catalog are largely unchanged pending a Gen2 effects pass.
--
-- Known gaps left for follow-up: Gen2-native effect jump table, held-item
-- damage/accuracy hooks (type-boost, Bright Powder, Scope Lens mid-turn),
-- weather/badge boosts inside Damage.compute from Turn, Gen2 sleep/confusion
-- parity tests, and Wire spa/spd event fields (T2c).
--
-- The formula modules beside this one each answer a single question with no
-- memory.  This is the thing that holds the fight: it owns the field, the
-- clock, the RNG stream and the order the questions get asked in, and it is
-- the only file in src/BattleSim2/ with state.
--
-- **The RNG order is the contract.**  The twin under server/lib/battle/ has to
-- consume draws at exactly the same points or the same seed produces a
-- different fight, so every draw site is spelled out here and every one of
-- them is conditional in a way both runtimes can reproduce:
--
--   1. a speed tie-break byte, one per group of equally fast actors;
--   2. one gate byte per actor whose monster has a gating status;
--   3. one gate byte per actor whose monster is confused;
--   4. per move that is actually used: accuracy byte, multihit-count byte
--      (TWO_TO_FIVE only), crit byte, damage roll, side-chance byte
--      (damaging hits only), in that order, and none of them drawn when an
--      earlier step ended the move (a missed move draws no crit byte).
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
--   * *Items* apply a hand-authored Gen1 heal/status table by id (Potion,
--     Full Restore, Revive, Ether, …) — locked twin of public amounts, not a
--     port of engine ItemEffects. Unknown ids announce "But it failed" and
--     still spend the turn. Bags are client claims (sheet trust locked; hub
--     has no ROM inventory truth); PROTOCOL 15 holds/spends mid-fight only.
--   * *Forced lock-in* (recharge, trap, thrash, …) fills choices on `_openTurn`
--     so the mediated path never opens a menu the cartridge would withhold; a
--     turn where *nobody* still owes waits for the next `tick` before resolving
--     so clients see a turn boundary for wait-lines / anim pacing. Trap residual
--     uses the first-hit damage store; the trapper emits continue narration +
--     anim without re-rolling `_useMove`.
--   * *Status moves* run through Effects.lua. Metronome picks from host-uploaded
--     `metronomePool` on the ruleset (from MediatedBattle.snapshotRuleset);
--     without a pool it says "But nothing happened".
--   * *Physical / Special* follow Gen1 type categories via host-uploaded
--     `specialTypes` on the ruleset (indices into the uploaded chart). Absent
--     specialTypes keeps every damaging move on atk/def.
--   * A *faint sends the next living monster in party order*, immediately and
--     without asking.  The original stops and asks; asking here would mean a
--     second kind of choice phase with its own deadline and its own forfeit
--     rule, and a fight that can hang between two turns is a worse v1 than one
--     that picks in party order.
--   * *Residuals* run in field order (side a, then side b), not in the speed
--     order the moves used.  Only the order two burns tick in is at stake, and
--     field order is the one both runtimes can reproduce without carrying the
--     turn's sort into the end-of-turn step.
--   * A *timeout* / NPC auto-picks with bag cures & heals (≤50% HP), X-items,
--     SE damage, status / setup reading, and SE bench switches (deterministic
--     heuristics — not a full TrainerAI port) -- and the fight continues.  It
--     does not end the battle -- the player who went to make a sandwich loses
--     a turn, not the match.
--   * *Struggle* when every move is out of PP: synthetic STRUGGLE (power 50,
--     type normal), no PP spent, recoil floor(damage/4) minimum 1 after a hit.
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

local Damage   = need("BattleSim2/Damage")
local Accuracy = need("BattleSim2/Accuracy")
local Crit     = need("BattleSim2/Crit")
local Status   = need("BattleSim2/Status")
local Effects  = need("BattleSim2/Effects")
local Rng      = need("BattleSim2/Rng")
local Events   = need("BattleSim2/events")

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.VERSION = 1

-- Mirrored from Config rather than required, for the reason in events.lua:
-- this directory runs where Config does not.
M.MONS_PER_PARTY      = 6     -- Config.BATTLE_MON_MAX
M.FIGHTERS_PER_SIDE   = 2     -- Config.COOP_SIDE
M.CHOICE_TIMEOUT      = 60    -- Config.BATTLE_CHOICE_TIMEOUT
M.RECONNECT_GRACE     = 60    -- Config.BATTLE_RECONNECT_GRACE
M.RESOLVE_TIMEOUT     = 30    -- Config.BATTLE_RESOLVE_TIMEOUT

-- Below this the side-a member of a tied group moves first.
M.TIE_BREAK_ROLL = 128

M.MODES = {
  ["1v1"] = true, coop_npc = true, coop_pvp = true, wild = true, coop_wild = true,
}
M.SIDES = { "a", "b" }

-- Roster cap per side. coop_wild is 2v1 (humans on a, wild on b); other modes
-- keep a single per-side ceiling (1 for 1v1/wild, FIGHTERS_PER_SIDE otherwise).
local function maxFighters(mode, side)
  if mode == "coop_wild" then
    return (side == "a") and M.FIGHTERS_PER_SIDE or 1
  end
  if mode == "1v1" or mode == "wild" then return 1 end
  return M.FIGHTERS_PER_SIDE
end

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

-- Synthetic move used when every slot is out of PP.  Not in any move table.
local STRUGGLE = {
  id = "STRUGGLE", power = 50, accuracy = 255,
  type = 0, effect = 0, chance = 0,
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
  local pp = max(0, int(raw.pp, 0))
  local maxPp = max(pp, int(raw.maxPp, pp))
  return {
    id       = str(raw.id) or "move",
    pp       = pp,
    maxPp    = maxPp,
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
--
-- `slot` is the *sender's* party position for this monster, zero-based, the way
-- Wire.battleMon carries it -- and it is kept rather than dropped because a
-- switch names it.  The two numbers are the same only while every monster the
-- client uploaded survived the copy and landed in the same order, and neither is
-- guaranteed: a mon this file cannot describe is skipped, a party past
-- MONS_PER_PARTY is cut short, and a coop_npc trainer's team is dealt across two
-- seats before it ever gets here.  In all three the array index has moved and the
-- position on the player's own screen has not, so the position is what a choice
-- is matched against.  `fallback` is that index for a sender that stated none,
-- which keeps an ordinary party numbered exactly as it always was.
local function copyMon(raw, fallback)
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

  local stagesRaw = type(raw.stages) == "table" and raw.stages or {}
  -- Gen2 stages: spe (Speed), spa, spd (Sp.Def). Legacy Gen1: spd=Speed, spc=Special.
  local gen2shaped = stagesRaw.spe ~= nil or stagesRaw.spa ~= nil
    or stagesRaw.speed ~= nil
  local speStage = stagesRaw.spe
  if speStage == nil then speStage = stagesRaw.speed end
  if speStage == nil and not gen2shaped then speStage = stagesRaw.spd end
  local spaStage = stagesRaw.spa
  if spaStage == nil then spaStage = stagesRaw.spc end
  local spdStage = nil
  if gen2shaped then
    spdStage = stagesRaw.spd
  else
    spdStage = stagesRaw.spc
  end
  local stages = {
    atk = Effects.clampStage(stagesRaw.atk),
    def = Effects.clampStage(stagesRaw.def),
    spe = Effects.clampStage(speStage),
    spa = Effects.clampStage(spaStage),
    spd = Effects.clampStage(spdStage),
    acc = Effects.clampStage(stagesRaw.acc),
    eva = Effects.clampStage(stagesRaw.eva),
  }

  local disable = nil
  if type(raw.disable) == "table" then
    disable = {
      moveIndex = max(0, int(raw.disable.moveIndex, 0)),
      turns = max(0, int(raw.disable.turns, 0)),
    }
  end

  local charging = nil
  if type(raw.charging) == "table" then
    charging = {
      moveIndex = max(1, int(raw.charging.moveIndex, 1)),
      effect = max(0, int(raw.charging.effect, 0)),
      targetSlot = int(raw.charging.targetSlot, nil),
    }
  end

  local trapped = nil
  if type(raw.trapped) == "table" then
    trapped = {
      turns = max(0, int(raw.trapped.turns, 0)),
      damage = max(0, int(raw.trapped.damage, 0)),
      fromSlot = int(raw.trapped.fromSlot, nil),
    }
  end

  local thrashing = nil
  if type(raw.thrashing) == "table" then
    thrashing = {
      turns = max(0, int(raw.thrashing.turns, 0)),
      moveIndex = max(1, int(raw.thrashing.moveIndex, 1)),
    }
  end

  local bide = nil
  if type(raw.bide) == "table" then
    bide = {
      turns = max(0, int(raw.bide.turns, 0)),
      stored = max(0, int(raw.bide.stored, 0)),
      moveIndex = max(1, int(raw.bide.moveIndex, 1)),
      targetSlot = int(raw.bide.targetSlot, nil),
    }
  end

  local leechSeed = nil
  if raw.leechSeed == true then
    leechSeed = { fromSlot = nil }
  elseif type(raw.leechSeed) == "table" then
    leechSeed = { fromSlot = int(raw.leechSeed.fromSlot, nil) }
  end

  local out = {
    species     = str(raw.species) or "?",
    slot        = max(0, int(raw.slot, max(0, int(fallback, 0)))),
    level       = max(1, int(raw.level, 1)),
    hp          = hp,
    maxHp       = maxHp,
    status      = status,
    statusTurns = turns,
    toxicCounter = max(1, int(raw.toxicCounter, 1)),
    confusion   = max(0, int(raw.confusion, 0)),
    stats = (function()
      -- Gen2 sheet: spa/spd (Sp.Def) + spe (Speed). Legacy Gen1: spd=Speed, spc=both specials.
      local atk = max(1, int(stats.atk, 1))
      local def = max(1, int(stats.def, 1))
      local spe, spa, spDef
      if stats.spa ~= nil or stats.spe ~= nil or stats.speed ~= nil then
        spe = max(1, int(stats.spe or stats.speed or 1, 1))
        spa = max(1, int(stats.spa or stats.spc or 1, 1))
        spDef = max(1, int(stats.spd or stats.spc or spa, 1))
      else
        spe = max(1, int(stats.spd, 1))
        spa = max(1, int(stats.spc, 1))
        spDef = spa
      end
      return { atk = atk, def = def, spe = spe, spa = spa, spd = spDef }
    end)(),
    types = copyTypes(raw.types),
    moves = moves,
    stages = stages,
    leechSeed = leechSeed,
    disable = disable,
    flinch = raw.flinch == true,
    charging = charging,
    invulnerable = raw.invulnerable == true,
    mustRecharge = raw.mustRecharge == true,
    trapped = trapped,
    trapping = nil,
    thrashing = thrashing,
    raging = raw.raging == true,
    rageMove = max(0, int(raw.rageMove, 0)),
    bide = bide,
    lastMoveIndex = max(0, int(raw.lastMoveIndex, 0)),
    substitute = max(0, int(raw.substitute, 0)),
    lightScreen = raw.lightScreen == true,
    reflect = raw.reflect == true,
    mist = raw.mist == true,
    focusEnergy = raw.focusEnergy == true,
    transformed = raw.transformed == true,
    xAccuracy = raw.xAccuracy == true,
    catchRate = max(0, min(255, int(raw.catchRate, 255))),
  }

  -- Optional Stat Exp sheet (atk/def/spe/spa/spd, optional hp). Absent keys stay 0
  -- at vitamin time; present values are what HP_UP / PROTEIN / … mutate.
  if type(raw.evs) == "table" then
    local evs = {}
    for _, key in ipairs({ "hp", "atk", "def", "spe", "spa", "spd" }) do
      if raw.evs[key] ~= nil then
        evs[key] = max(0, min(65535, int(raw.evs[key], 0)))
      end
    end
    out.evs = evs
  end
  return out
end

local function copyBadges(raw)
  if type(raw) ~= "table" then return nil end
  local out, any = {}, false
  for id, held in pairs(raw) do
    if held and type(id) == "string" then out[id] = true; any = true end
  end
  if not any then return nil end
  return out
end

-- Bag sheet for auto-pick / timeout item use (id → count). Accepts the same
-- shapes Wire.bag does: a list of {id,count} or a map.
local function copyBag(raw)
  if type(raw) ~= "table" then return nil end
  local out, any = {}, false
  local function put(id, count)
    if type(id) ~= "string" or id == "" then return end
    local n = int(count, 0)
    if not n or n < 1 then return end
    out[id] = (out[id] or 0) + n
    any = true
  end
  if #raw > 0 or raw[1] ~= nil then
    for _, entry in ipairs(raw) do
      if type(entry) == "table" then put(entry.id, entry.count) end
    end
  else
    for id, count in pairs(raw) do put(id, count) end
  end
  if not any then return nil end
  return out
end

-- Default kit for coop_npc trainer seats with no uploaded bag (Gen1 gym-style).
M.DEFAULT_NPC_BAG = {
  POTION = 2, SUPER_POTION = 1, FULL_HEAL = 1, X_ATTACK = 1,
}

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

local function allPpEmpty(mon)
  if #mon.moves == 0 then return true end
  for i = 1, #mon.moves do
    if mon.moves[i].pp > 0 then return false end
  end
  return true
end

local function activeMon(fighter)
  if not fighter.active then return nil end
  local mon = fighter.mons[fighter.active]
  if mon and mon.hp > 0 then return mon end
  return nil
end

-- Which of this party a zero-based wire slot means.
--
-- Matched against the position each monster claims rather than counted off the
-- array, for the reason copyMon gives -- and the array index is the fallback
-- rather than the rule, so a sender whose party arrived intact is unaffected and
-- one whose party was cut or dealt still switches to the monster it named.
local function partyIndexOf(fighter, wireSlot)
  for i = 1, #fighter.mons do
    if fighter.mons[i].slot == wireSlot then return i end
  end
  return wireSlot + 1
end

-- opts:
--   id, mode, seed, chart, choiceTimeout, reconnectGrace, resolveTimeout, now
--   sides = { a = { { playerId, name, mons } }, b = { ... } }
--
-- Returns the battle, or nil plus a reason string.  A reason and not a raise:
-- the caller is a session handler that has a client waiting to be told why.
function M.create(opts)
  if type(opts) ~= "table" then return nil, "battle needs an options table" end

  local mode = M.MODES[opts.mode] and opts.mode or "1v1"

  local self = setmetatable({
    id             = str(opts.id) or "battle",
    mode           = mode,
    seed           = int(opts.seed, 0),
    rng            = Rng.new(int(opts.seed, 0)),
    chart          = type(opts.chart) == "table" and opts.chart or nil,
    specialTypes   = nil,
    metronomePool  = nil,
    choiceTimeout  = max(0, int(opts.choiceTimeout, M.CHOICE_TIMEOUT)),
    reconnectGrace = max(0, int(opts.reconnectGrace, M.RECONNECT_GRACE)),
    resolveTimeout = max(0, int(opts.resolveTimeout, M.RESOLVE_TIMEOUT)),
    now            = max(0, int(opts.now, 0)),
    phase          = "choice",
    turn           = 1,
    seq            = 0,
    buffer         = {},
    fighters       = {},
    byId           = {},
    bySide         = { a = {}, b = {} },
    result         = nil,
    resolveDeadline = nil,
  }, Battle)

  if type(opts.specialTypes) == "table" then
    local set = {}
    for i = 1, #opts.specialTypes do
      set[max(0, int(opts.specialTypes[i], 0))] = true
    end
    self.specialTypes = set
  end
  if type(opts.metronomePool) == "table" then
    local pool = {}
    for i = 1, #opts.metronomePool do
      local move = copyMove(opts.metronomePool[i])
      if move then pool[#pool + 1] = move end
    end
    if #pool > 0 then self.metronomePool = pool end
  end

  local sides = type(opts.sides) == "table" and opts.sides or {}
  for _, side in ipairs(M.SIDES) do
    local roster = type(sides[side]) == "table" and sides[side] or {}
    if #roster == 0 then return nil, "side " .. side .. " has nobody on it" end
    local sideMax = maxFighters(mode, side)
    if #roster > sideMax then
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
          local mon = copyMon(entry.mons[i], #mons)
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
        badges    = copyBadges(entry.badges),
        bag       = copyBag(entry.bag),
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

function Battle:_emitMoves(fighter, mon)
  local moves = {}
  for i = 1, #mon.moves do
    local m = mon.moves[i]
    moves[#moves + 1] = {
      id = m.id or "move",
      pp = max(0, int(m.pp, 0)),
      power = max(0, int(m.power, 0)),
      accuracy = max(0, int(m.accuracy, 255)),
      type = max(0, int(m.type, 0)),
      effect = max(0, int(m.effect, 0)),
      chance = max(0, int(m.chance, 0)),
    }
  end
  return self:_emit("moves", {
    slot = fighter.slot, side = fighter.side, moves = moves,
  })
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

-- A fighter owes a choice when it has something standing, or when it must pick
-- a replacement after a faint.  A player whose last monster fainted in a 2v2 is
-- a spectator for the rest of the fight, and waiting on them would hang the
-- turn.  Multi-turn volatiles auto-fill before the player is asked.
function Battle:_owes(fighter)
  if fighter.choice ~= nil then return false end
  if fighter.mustReplace then
    return firstLiving(fighter.mons) ~= nil
  end
  if activeMon(fighter) == nil then return false end
  return true
end

-- Inject forced choices for charge release, recharge skip, thrash/rage repeat,
-- and trap lock-in. Gen1 trapping: victim can't move; user stays locked (no
-- menu) while residual damage (first-hit store) ticks — not a re-rolled fight.
function Battle:_fillForcedChoices()
  for _, fighter in ipairs(self.fighters) do
    if fighter.choice ~= nil then goto continue end
    local mon = activeMon(fighter)
    if not mon then goto continue end

    if mon.mustRecharge then
      mon.mustRecharge = false
      self:_say(mon.species .. " must recharge")
      fighter.choice = { action = "skip" }
      self:_emit("chose", {
        slot = fighter.slot, side = fighter.side, text = fighter.name,
      })
      goto continue
    end

    if mon.bide then
      if mon.bide.turns > 0 then
        self:_say(mon.species .. " is storing energy")
        fighter.choice = { action = "skip" }
        self:_emit("chose", {
          slot = fighter.slot, side = fighter.side, text = fighter.name,
        })
      else
        local foe = self:_firstLivingFoe(fighter)
        if foe then
          self:_say(mon.species .. " unleashed energy")
          fighter.choice = {
            action = "fight",
            move = mon.bide.moveIndex,
            target = mon.bide.targetSlot or foe.slot,
            bideRelease = true,
          }
          self:_emit("chose", {
            slot = fighter.slot, side = fighter.side, text = fighter.name,
          })
        end
      end
      goto continue
    end

    if mon.trapped and mon.trapped.turns > 0 then
      self:_say(mon.species .. " can't move")
      fighter.choice = { action = "skip" }
      self:_emit("chose", {
        slot = fighter.slot, side = fighter.side, text = fighter.name,
      })
      goto continue
    end

    if mon.trapping and mon.trapping.turns > 0 then
      -- Cartridge lock-in: no menu, residual still deals stored damage. Emit
      -- continue narration + anim so the screen shows the trap going on —
      -- do not re-enter _useMove (that would re-roll damage).
      local move = mon.moves[mon.trapping.moveIndex]
      local moveId = move and move.id or "attack"
      self:_say(mon.species .. "'s " .. moveId .. " continues")
      self:_emit("anim", {
        slot = fighter.slot, side = fighter.side, text = moveId,
      })
      fighter.choice = { action = "skip" }
      self:_emit("chose", {
        slot = fighter.slot, side = fighter.side, text = fighter.name,
      })
      goto continue
    end

    if mon.charging then
      local c = mon.charging
      fighter.choice = {
        action = "fight",
        move = c.moveIndex,
        target = c.targetSlot,
      }
      self:_emit("chose", {
        slot = fighter.slot, side = fighter.side, text = fighter.name,
      })
      goto continue
    end

    if mon.thrashing and mon.thrashing.turns > 0 then
      local foe = self:_firstLivingFoe(fighter)
      if foe then
        self:_say(mon.species .. " thrashing about")
        fighter.choice = {
          action = "fight",
          move = mon.thrashing.moveIndex,
          target = foe.slot,
        }
        self:_emit("chose", {
          slot = fighter.slot, side = fighter.side, text = fighter.name,
        })
      end
      goto continue
    end

    if mon.raging and mon.rageMove and mon.rageMove > 0 then
      local foe = self:_firstLivingFoe(fighter)
      if foe then
        self:_say(mon.species .. "'s RAGE is building")
        fighter.choice = {
          action = "fight",
          move = mon.rageMove,
          target = foe.slot,
        }
        self:_emit("chose", {
          slot = fighter.slot, side = fighter.side, text = fighter.name,
        })
      end
    end

    ::continue::
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
--
-- Indices arrive zero-based, because that is how they ride on the wire:
-- `move` is 0..3 into the monster's moves, `slot` is 0..5 into the party, and
-- `target` is a 0..3 *field* slot.  They are converted here, once, so nothing
-- downstream has to remember which of the three it is holding.

function Battle:_normaliseChoice(fighter, choice)
  local action = choice.action

  -- Forced replacement: only a living bench switch is accepted.  Fight / item /
  -- run would spend a turn the seat does not have a mon for.
  if fighter.mustReplace then
    if action ~= "switch" then return nil end
    local slot = int(choice.slot, nil)
    if slot == nil then return nil end
    local target = partyIndexOf(fighter, slot)
    local bench = fighter.mons[target]
    if not bench or bench.hp <= 0 then return nil end
    return { action = "switch", slot = target }
  end

  local mon = activeMon(fighter)
  if not mon then return nil end

  if action == "run" then return { action = "run" } end

  if action == "item" then
    local item = str(choice.item)
    if not item then return nil end
    -- A fighter with a bag sheet must actually hold the stack (hub/NPC auto).
    -- Seats with no bag stay permissive so headless fixtures can still item.
    if fighter.bag and not self:_bagHas(fighter, item) then return nil end
    local effect = Effects.itemEffect(item)
    local out = { action = "item", item = item }
    if choice.slot ~= nil then
      local slot = int(choice.slot, nil)
      if slot == nil then return nil end
      local target = partyIndexOf(fighter, slot)
      if not fighter.mons[target] then return nil end
      out.slot = target
    end
    if choice.move ~= nil then
      local move = int(choice.move, nil)
      if move == nil then return nil end
      out.move = move + 1
    elseif effect and effect.needsMove then
      return nil
    end
    return out
  end

  if action == "switch" then
    local slot = int(choice.slot, nil)
    if slot == nil then return nil end
    local target = partyIndexOf(fighter, slot)
    local bench = fighter.mons[target]
    if not bench or bench.hp <= 0 or target == fighter.active then return nil end
    return { action = "switch", slot = target }
  end

  if action == "fight" then
    local index = int(choice.move, nil)
    if index == nil then return nil end
    local move = mon.moves[index + 1]
    if not move then return nil end
    -- One empty slot is refused; every slot empty means Struggle on any index.
    if move.pp <= 0 and not allPpEmpty(mon) then return nil end
    if mon.disable and mon.disable.turns > 0
       and mon.disable.moveIndex == index + 1 then
      return nil
    end

    local targetFighter
    if choice.target ~= nil then
      targetFighter = self:_fighterAtSlot(int(choice.target, -1))
      -- A named target that is empty or on the chooser's own side is refused
      -- rather than redirected: redirecting would spend somebody's turn on a
      -- monster they did not pick, and the client can ask again.
      -- A seat mid-replace (mustReplace, no active yet) is still a legal aim:
      -- switches resolve before fights, so the mon will be out when the move
      -- lands.
      if not targetFighter or targetFighter.side == fighter.side then
        return nil
      end
      if not activeMon(targetFighter) and not targetFighter.mustReplace then
        return nil
      end
    else
      targetFighter = self:_firstLivingFoe(fighter)
      if not targetFighter then
        for _, foe in ipairs(self:_foes(fighter)) do
          if foe.mustReplace then targetFighter = foe; break end
        end
      end
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
    self:_emit("unchose", {
      slot = fighter.slot, side = fighter.side, text = fighter.name,
    })
    fighter.choice = nil
    return true
  end

  if fighter.choice ~= nil then return false end   -- one answer per turn
  if fighter.mustReplace then
    if choice.action ~= "switch" then return false end
  elseif not activeMon(fighter) then
    return false
  end

  local normalised = self:_normaliseChoice(fighter, choice)
  if not normalised then return false end

  fighter.choice = normalised
  -- Peers need this for the wait line: without it, only the chooser's own
  -- client knows they answered (there is no `act` fan-out on the mediated path).
  self:_emit("chose", {
    slot = fighter.slot, side = fighter.side, text = fighter.name,
  })
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
  if self.phase ~= "choice" then return false end
  for _, fighter in ipairs(self.fighters) do
    if self:_owes(fighter) then return false end
  end
  self:_resolveTurn()
  return true
end

-- timeout/NPC pick: bag cures/heals/X-items when present, else SE / status /
-- setup / switch. Deterministic twin of server/lib/battle/Turn.js — richer
-- than a strongest-move heuristic, still not a full TrainerAI port.
local AUTO_STATUS_PRI = {
  [32] = 4, -- SLEEP_EFFECT
  [67] = 3, -- PARALYZE_EFFECT
  [66] = 2, -- POISON_EFFECT
  [49] = 1, -- CONFUSION_EFFECT
  [84] = 1, -- LEECH_SEED_EFFECT
}
-- Self-boost / screen / substitute. Values are stage keys, or true for flags.
local AUTO_SETUP = {
  [10] = "atk", [11] = "def", [12] = "spe", [13] = "spa",
  [50] = "atk", [51] = "def", [52] = "spe", [53] = "spa",
  [47] = true, -- FOCUS_ENERGY
  [64] = true, -- LIGHT_SCREEN
  [65] = true, -- REFLECT
  [79] = true, -- SUBSTITUTE
}
-- Prefer stronger heals first (gym-AI style).
local AUTO_HEAL_PREF = {
  "FULL_RESTORE", "MAX_POTION", "HYPER_POTION", "SUPER_POTION",
  "LEMONADE", "SODA_POP", "FRESH_WATER", "POTION",
}
local AUTO_STATUS_CURE = {
  poison = { "FULL_RESTORE", "FULL_HEAL", "ANTIDOTE" },
  toxic = { "FULL_RESTORE", "FULL_HEAL", "ANTIDOTE" },
  burn = { "FULL_RESTORE", "FULL_HEAL", "BURN_HEAL" },
  freeze = { "FULL_RESTORE", "FULL_HEAL", "ICE_HEAL" },
  sleep = { "FULL_RESTORE", "FULL_HEAL", "AWAKENING" },
  paralysis = { "FULL_RESTORE", "FULL_HEAL", "PARLYZ_HEAL" },
}
local AUTO_X_ITEM = {
  { id = "X_ATTACK", stat = "atk" },
  { id = "X_DEFEND", stat = "def" },
  { id = "X_SPEED", stat = "spe" },
  { id = "X_SPECIAL", stat = "spa" },
  { id = "DIRE_HIT", flag = "focusEnergy" },
  { id = "GUARD_SPEC", flag = "mist" },
}

function Battle:_effectivenessProduct(moveType, defender)
  local percents = self:_typePercents(moveType, defender)
  local eff = 1
  for _, pct in ipairs(percents) do eff = eff * pct / 100 end
  return eff
end

function Battle:_bagHas(fighter, itemId)
  return fighter.bag and (fighter.bag[itemId] or 0) > 0
end

function Battle:_spendBag(fighter, itemId)
  if not fighter.bag then return end
  local n = fighter.bag[itemId]
  if not n then return end
  if n <= 1 then fighter.bag[itemId] = nil else fighter.bag[itemId] = n - 1 end
end

function Battle:_bestSeBench(fighter, defender)
  if not defender then return nil end
  local best, bestEff = nil, 1
  for i = 1, #fighter.mons do
    if i ~= fighter.active then
      local bench = fighter.mons[i]
      if bench and bench.hp > 0 then
        local maxEff = 1
        for j = 1, #bench.moves do
          local m = bench.moves[j]
          if m.pp > 0 and m.power > 0 then
            local eff = self:_effectivenessProduct(m.type, defender)
            if eff > maxEff then maxEff = eff end
          end
        end
        if maxEff > 1 then
          if not best or maxEff > bestEff or (maxEff == bestEff and i < best) then
            best, bestEff = i, maxEff
          end
        end
      end
    end
  end
  return best
end

-- Bag item for the active mon: cure → heal ≤50% → X-item while stages flat.
function Battle:_autoItemChoice(fighter, mon)
  if not fighter.bag then return nil end

  if mon.status then
    local list = AUTO_STATUS_CURE[mon.status]
    if list then
      for _, id in ipairs(list) do
        if self:_bagHas(fighter, id) then
          return { action = "item", item = id, slot = fighter.active }
        end
      end
    end
  end

  if mon.hp < mon.maxHp and mon.hp * 2 <= mon.maxHp then
    for _, id in ipairs(AUTO_HEAL_PREF) do
      if self:_bagHas(fighter, id) then
        local effect = Effects.itemEffect(id)
        if effect and (effect.heal or effect.healFull or effect.clearAllStatus) then
          return { action = "item", item = id, slot = fighter.active }
        end
      end
    end
  end

  local stagesFlat = mon.stages.atk <= 0 and mon.stages.def <= 0
    and mon.stages.spe <= 0 and mon.stages.spa <= 0
  if stagesFlat and not mon.focusEnergy and not mon.mist then
    for _, row in ipairs(AUTO_X_ITEM) do
      if self:_bagHas(fighter, row.id) then
        if row.flag == "focusEnergy" and not mon.focusEnergy then
          return { action = "item", item = row.id }
        elseif row.flag == "mist" and not mon.mist then
          return { action = "item", item = row.id }
        elseif row.stat and (mon.stages[row.stat] or 0) <= 0 then
          return { action = "item", item = row.id }
        end
      end
    end
  end

  return nil
end

function Battle:_autoChoice(fighter)
  if fighter.mustReplace then
    local foe = self:_firstLivingFoe(fighter)
    local defender = foe and activeMon(foe)
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
    local next_ = firstLiving(fighter.mons)
    if next_ then return { action = "switch", slot = next_ } end
    return nil
  end

  local mon = activeMon(fighter)
  if not mon then return nil end

  if mon.charging then
    local c = mon.charging
    return { action = "fight", move = c.moveIndex, target = c.targetSlot }
  end
  if mon.mustRecharge then
    return { action = "skip" }
  end
  if mon.bide then
    if mon.bide.turns > 0 then
      return { action = "skip" }
    end
    local foe = self:_firstLivingFoe(fighter)
    if foe then
      return {
        action = "fight",
        move = mon.bide.moveIndex,
        target = mon.bide.targetSlot or foe.slot,
        bideRelease = true,
      }
    end
  end
  if mon.trapped and mon.trapped.turns > 0 then
    return { action = "skip" }
  end
  if mon.trapping and mon.trapping.turns > 0 then
    return { action = "skip" }
  end
  if mon.thrashing and mon.thrashing.turns > 0 then
    local foe = self:_firstLivingFoe(fighter)
    if foe then
      return {
        action = "fight",
        move = mon.thrashing.moveIndex,
        target = foe.slot,
      }
    end
  end
  if mon.raging and mon.rageMove and mon.rageMove > 0 then
    local foe = self:_firstLivingFoe(fighter)
    if foe then
      return { action = "fight", move = mon.rageMove, target = foe.slot }
    end
  end

  local foe = self:_firstLivingFoe(fighter)
  if not foe then
    for _, f in ipairs(self:_foes(fighter)) do
      if f.mustReplace then foe = f; break end
    end
  end
  if not foe then return nil end
  local defender = activeMon(foe)
  if not defender then
    local pick = 1
    for i = 1, #mon.moves do
      if mon.moves[i].pp > 0 then pick = i; break end
    end
    return { action = "fight", move = pick, target = foe.slot }
  end

  local itemPick = self:_autoItemChoice(fighter, mon)
  if itemPick then return itemPick end

  local foeBoosted = (defender.stages.atk or 0) >= 2
    or (defender.stages.def or 0) >= 2
    or (defender.stages.spe or 0) >= 2
    or (defender.stages.spa or 0) >= 2
    or defender.focusEnergy
  local foeSub = (defender.substitute or 0) > 0
  local weSlower = self:_speedOf(fighter, mon) < self:_speedOf(foe, defender)

  -- Critical HP: SE retreat (heal already tried via bag).
  if mon.hp * 4 <= mon.maxHp then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end

  -- Behind a boosted / subbed foe at mid-low HP: prefer an SE bench mon.
  if (foeBoosted or foeSub) and mon.hp * 2 <= mon.maxHp then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end

  local function disabled(i)
    return mon.disable and mon.disable.turns > 0 and mon.disable.moveIndex == i
  end

  local pick, pickEff, pickPow = nil, -1, -1
  for i = 1, #mon.moves do
    local m = mon.moves[i]
    if m.pp > 0 and m.power > 0 and not disabled(i) then
      local eff = self:_effectivenessProduct(m.type, defender)
      if not pick or eff > pickEff
         or (eff == pickEff and m.power > pickPow)
         or (eff == pickEff and m.power == pickPow and i < pick) then
        pick, pickEff, pickPow = i, eff, m.power
      end
    end
  end

  if (not pick) or pickEff == 0 then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end

  if pick and pickEff > 1 then
    return { action = "fight", move = pick, target = foe.slot }
  end

  -- Status fails against a Substitute; skip it and trade damage instead.
  if not defender.status and not foeSub then
    local statusPick, statusPri = nil, -1
    for i = 1, #mon.moves do
      local m = mon.moves[i]
      if m.pp > 0 and not disabled(i) and m.power == 0 then
        local pri = AUTO_STATUS_PRI[m.effect]
        if pri and (pri > statusPri
                    or (pri == statusPri and (not statusPick or i < statusPick))) then
          statusPick, statusPri = i, pri
        end
      end
    end
    if statusPick and (weSlower or foeBoosted or not pick or pickEff <= 1) then
      return { action = "fight", move = statusPick, target = foe.slot }
    end
  end

  local stagesFlat = mon.stages.atk <= 0 and mon.stages.def <= 0
    and mon.stages.spe <= 0 and mon.stages.spa <= 0
  -- Do not set up into a boosted foe, behind a substitute, or while slower
  -- at mid-low HP — hit or switch instead.
  if stagesFlat and not mon.focusEnergy and not foeBoosted and not foeSub
     and not (weSlower and mon.hp * 2 <= mon.maxHp) then
    local setupPick = nil
    for i = 1, #mon.moves do
      local m = mon.moves[i]
      if m.pp > 0 and not disabled(i) and m.power == 0 then
        local kind = AUTO_SETUP[m.effect]
        if kind == true or (type(kind) == "string" and (mon.stages[kind] or 0) <= 0) then
          if not setupPick or i < setupPick then setupPick = i end
        end
      end
    end
    if setupPick then
      return { action = "fight", move = setupPick, target = foe.slot }
    end
  end

  if not (pick and pickEff > 0) then
    pick, pickPow = nil, -1
    for i = 1, #mon.moves do
      local m = mon.moves[i]
      if m.pp > 0 and not disabled(i) then
        if not pick or m.power > pickPow
           or (m.power == pickPow and i < pick) then
          pick, pickPow = i, m.power
        end
      end
    end
  end

  pick = pick or 1
  if not mon.moves[pick] then return nil end
  return { action = "fight", move = pick, target = foe.slot }
end

-- File that pick for a seat that has nobody to send one.
--
-- The npc side of a coop_npc is seated like any other fighter and has no
-- connection behind it, so without this the referee would wait out the whole
-- choice deadline every turn and then auto-pick anyway -- a minute a turn, for a
-- decision nothing was ever going to make.  It is deliberately the *same* pick
-- the timeout files rather than a second, cleverer one: both runtimes reproduce
-- it byte for byte (bag / SE / status / setup / switch heuristics above).
--
-- Answers true when a choice was actually filed, so a caller can loop until the
-- machine stops owing.  Filing one may resolve the turn and open the next, which
-- is what makes that loop the thing that carries the fight forward.
function Battle:autoPick(playerId)
  if self.phase ~= "choice" then return false end
  local fighter = self.byId[str(playerId) or ""]
  if not fighter then return false end
  if fighter.choice ~= nil then return false end
  if not fighter.mustReplace and not activeMon(fighter) then return false end

  local auto = self:_autoChoice(fighter)
  if not auto then return false end
  fighter.choice = auto
  self:_emit("chose", {
    slot = fighter.slot, side = fighter.side, text = fighter.name,
  })
  self:_maybeResolve()
  return true
end

-- ------------------------------------------------------------------
-- resolution
-- ------------------------------------------------------------------

function Battle:_openTurn()
  self.phase = "choice"
  self.resolveDeadline = nil
  self.forcedPending = false
  for _, fighter in ipairs(self.fighters) do fighter.choice = nil end
  self.deadline = (self.choiceTimeout > 0) and (self.now + self.choiceTimeout) or nil
  self:_emit("turn", { amount = self.turn })
  self:_fillForcedChoices()
  -- When every living seat is forced, do not resolve in this same call: the
  -- turn event has to reach clients before the next resolve dumps more events
  -- (wait lines and anim pacing). tick() advances the chain one step.
  if not self:_anyoneOwes() then
    self.forcedPending = true
    self.deadline = nil
  end
end

function Battle:_speedOf(fighter, mon)
  local spe = Effects.badgeBoost(mon.stats.spe, "spe", fighter.badges)
  spe = Effects.applyStage(spe, mon.stages.spe)
  if mon.status == "paralysis" then return Status.paralysisSpeed(spe) end
  return spe
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
  -- Armed for the rare case resolution does not leave this phase in the same
  -- call -- a throw mid-resolve used to leave the field wedged forever, and
  -- Hub.receive now contains those throws so the clock has to finish the job.
  self.resolveDeadline = (self.resolveTimeout > 0)
    and (self.now + self.resolveTimeout) or nil

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
        fighter.mustReplace = nil
        mon.charging = nil
        mon.invulnerable = false
        mon.thrashing = nil
        mon.raging = false
        mon.rageMove = 0
        mon.trapped = nil
        mon.trapping = nil
        mon.bide = nil
        mon.substitute = 0
        mon.lightScreen = false
        mon.reflect = false
        mon.mist = false
        mon.focusEnergy = false
        mon.transformed = false
        mon.xAccuracy = false
        mon.leechSeed = nil
        mon.disable = nil
        self:_clearTrapsFrom(fighter.slot)
        self:_emit("switch", { slot = fighter.slot, side = fighter.side,
                               text = mon.species })
        self:_emit("send", { slot = fighter.slot, side = fighter.side,
                             hp = mon.hp, text = mon.species })
      end
    end
  end
end

function Battle:_clearTrapsFrom(slot)
  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    if mon and mon.trapped and mon.trapped.fromSlot == slot then
      mon.trapped = nil
    end
    if mon and mon.trapping and mon.trapping.targetSlot == slot then
      mon.trapping = nil
    end
  end
end

function Battle:_resolveItems()
  -- Non-ball items keep Gen1 array order (heals, dolls, vitamins, …). Balls
  -- resolve in a second pass ordered by active-mon speed (fight tie policy),
  -- so the faster thrower spends first and a successful catch aborts the rest.
  for _, fighter in ipairs(self.fighters) do
    if self.result then return end
    local choice = fighter.choice
    if choice and choice.action == "item" then
      local effect = Effects.itemEffect(choice.item)
      if not (effect and effect.ball) then
        self:_resolveOneItem(fighter)
      end
    end
  end

  local balls = {}
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    if choice and choice.action == "item" then
      local effect = Effects.itemEffect(choice.item)
      if effect and effect.ball then
        local mon = activeMon(fighter)
        balls[#balls + 1] = {
          fighter = fighter,
          speed = mon and self:_speedOf(fighter, mon) or 0,
          order = #balls + 1,
        }
      end
    end
  end
  self:_sortActorsBySpeed(balls)
  for _, actor in ipairs(balls) do
    if self.result then return end
    self:_resolveOneItem(actor.fighter)
  end
end

-- Sort actors by active-mon speed (desc), then field order; tied groups flip on
-- one RNG byte >= TIE_BREAK_ROLL. Shared by fights and ball throws.
function Battle:_sortActorsBySpeed(actors)
  if #actors <= 1 then return end

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
end

function Battle:_resolveOneItem(fighter)
  local choice = fighter.choice
  if not (choice and choice.action == "item") then return end

  local effect = Effects.itemEffect(choice.item)
  -- Vitamins apply before the `item` event so `amount=1` can mean "Stat Exp
  -- writeback is owed"; a failed vitamin still spends the bag stack (Gen1)
  -- but must not bump save.statExp on the client.
  local vitaminApplied, vitaminMon, vitaminResult = false, nil, nil
  if effect and effect.vitamin then
    local partyIdx = choice.slot or fighter.active
    local mon = fighter.mons[partyIdx]
    if mon and mon.hp > 0 then
      local result = Effects.applyVitamin(mon, choice.item)
      if result then
        vitaminApplied, vitaminMon, vitaminResult = true, mon, result
      end
    end
  end
  local itemEv = { slot = fighter.slot, side = fighter.side, text = choice.item }
  if vitaminApplied then itemEv.amount = 1 end
  self:_emit("item", itemEv)
  self:_say(fighter.name .. " used an item")
  -- Spend after the announce, win or fail (Gen1 bag stack). noConsume
  -- (Poké Flute) and seats with no bag sheet are left alone.
  if not (effect and effect.noConsume) then
    self:_spendBag(fighter, choice.item)
  end
  if not effect then
    self:_say("But it failed")
  elseif effect.ball then
    if not Effects.isWildMode(self.mode) then
      self:_say("But it failed")
    else
      local foe = self:_firstLivingFoe(fighter)
      local target = foe and activeMon(foe)
      if not target then
        self:_say("But it failed")
      else
        local caught, shakes = Effects.catchAttempt(choice.item, target, self.rng)
        -- Gen1 TossBallAnimation chain before the catch text (engine ballChain).
        self:_emitBallChain(fighter, choice.item, caught, shakes)
        if shakes and shakes > 0 and not caught then
          self:_say("The ball shook")
        end
        if caught then
          self:_say("Gotcha")
          local finish = self:_finish("win", self:_sidePlayers(fighter.side),
            self:_sidePlayers(fighter.side == "a" and "b" or "a"), "catch")
          local sheet = Effects.caughtSheet(target)
          if finish and sheet then finish.caught = sheet end
          if finish then finish.catcher = fighter.playerId end
        else
          self:_say("It broke free")
        end
      end
    end
  elseif effect.pokeDoll then
    if Effects.isWildMode(self.mode) then
      self:_say("The wild pokemon ran away")
      self:_finish("win", self:_sidePlayers(fighter.side),
        self:_sidePlayers(fighter.side == "a" and "b" or "a"), "run")
    else
      self:_say("But it failed")
    end
  elseif effect.vitamin then
    if not vitaminApplied then
      self:_say("But it failed")
    else
      local mon, result = vitaminMon, vitaminResult
      local label = ({
        hp = "HEALTH POINTS", atk = "ATTACK", def = "DEFENSE",
        spe = "SPEED", spa = "SP.ATK", spd = "SP.DEF",
      })[result.stat] or "STAT"
      if result.stat == "hp" and result.delta > 0 then
        self:_emit("drain", {
          slot = fighter.slot, side = fighter.side,
          amount = result.delta, hp = mon.hp,
        })
      elseif result.delta > 0 then
        self:_emit("stat", {
          slot = fighter.slot, side = fighter.side,
          amount = mon.stats[result.stat],
          text = mon.species .. "'s " .. label .. " rose",
        })
      end
      self:_say(mon.species .. "'s " .. label .. " rose")
    end
  elseif effect.pokeFlute then
    local woke = false
    for _, seat in ipairs(self.fighters) do
      for i = 1, #(seat.mons or {}) do
        local mon = seat.mons[i]
        if mon and mon.status == "sleep" then
          mon.status, mon.statusTurns = nil, 0
          woke = true
          self:_emit("status", {
            slot = seat.slot, side = seat.side,
            text = mon.species .. " woke up",
          })
        end
      end
    end
    if woke then
      self:_say("All sleeping POKeMON woke up")
    else
      self:_say("Now, that's a catchy tune")
    end
  else
    local partyIdx = choice.slot or fighter.active
    local mon = fighter.mons[partyIdx]
    if not mon then
      self:_say("But it failed")
    elseif effect.activeOnly and partyIdx ~= fighter.active then
      self:_say("But it failed")
    elseif effect.faintedOnly and mon.hp > 0 then
      self:_say("But it failed")
    elseif not effect.faintedOnly and mon.hp <= 0
       and (effect.heal or effect.healFull or effect.clearStatuses
            or effect.clearAllStatus or effect.ppRestore
            or effect.ppRestoreAll) then
      self:_say("But it failed")
    else
      local applied = false
      if effect.xAccuracy then
        mon.xAccuracy = true
        self:_say(mon.species .. "'s hits will never miss")
        applied = true
      end
      if effect.focusEnergy then
        mon.focusEnergy = true
        self:_say(mon.species .. " is getting pumped")
        applied = true
      end
      if effect.mist then
        mon.mist = true
        self:_say(mon.species .. " is protected against stat changes")
        applied = true
      end
      if effect.stage then
        local stat = effect.stage.stat
        local before = Effects.clampStage(mon.stages[stat])
        if before >= Effects.STAGE_MAX then
          self:_say("Nothing happened")
        else
          local after = Effects.clampStage(before + int(effect.stage.delta, 1))
          mon.stages[stat] = after
          local label = ({
            atk = "ATTACK", def = "DEFENSE", spe = "SPEED",
            spa = "SP.ATK", spd = "SP.DEF", acc = "ACCURACY", eva = "EVASION",
          })[stat] or "STAT"
          self:_say(mon.species .. "'s " .. label .. " rose")
          self:_emit("stat", {
            slot = fighter.slot, side = fighter.side,
            amount = after, text = mon.species .. "'s " .. label .. " rose",
          })
        end
        applied = true
      end
      if effect.revive then
        local amount = effect.revive
        local hp = amount == 1 and mon.maxHp or max(1, floor(mon.maxHp * amount))
        mon.hp = hp
        mon.status, mon.statusTurns = nil, 0
        self:_emit("drain", {
          slot = fighter.slot, side = fighter.side,
          amount = hp, hp = mon.hp,
        })
        self:_say(mon.species .. " was revived")
        applied = true
      end
      if effect.ppRestore then
        local move = mon.moves[choice.move]
        if not move then
          self:_say("But it failed")
        else
          local maxPp = max(int(move.maxPp, move.pp), move.pp, 1)
          local before = move.pp
          if effect.ppRestore == true then
            move.pp = maxPp
          else
            move.pp = min(maxPp, move.pp + int(effect.ppRestore, 0))
          end
          if move.pp > before then
            self:_say(mon.species .. "'s PP was restored")
            applied = true
          else
            self:_say("But it failed")
          end
        end
      end
      if effect.ppRestoreAll then
        local any = false
        for i = 1, #(mon.moves or {}) do
          local move = mon.moves[i]
          if move then
            local maxPp = max(int(move.maxPp, move.pp), move.pp, 1)
            local before = move.pp
            if effect.ppRestoreAll == true then
              move.pp = maxPp
            else
              move.pp = min(maxPp, move.pp + int(effect.ppRestoreAll, 0))
            end
            if move.pp > before then any = true end
          end
        end
        if any then
          self:_say(mon.species .. "'s PP was restored")
          applied = true
        else
          self:_say("But it failed")
        end
      end
      local healed = false
      if effect.healFull then
        local before = mon.hp
        mon.hp = mon.maxHp
        if mon.hp > before then
          self:_emit("drain", {
            slot = fighter.slot, side = fighter.side,
            amount = mon.hp - before, hp = mon.hp,
          })
          healed = true
        end
      elseif effect.heal and effect.heal > 0 and mon.hp < mon.maxHp then
        self:_heal(fighter, mon, effect.heal)
        healed = true
      end
      local cleared = false
      if effect.clearAllStatus and mon.status then
        mon.status, mon.statusTurns = nil, 0
        cleared = true
      elseif effect.clearStatuses and mon.status
         and effect.clearStatuses[mon.status] then
        mon.status, mon.statusTurns = nil, 0
        cleared = true
      end
      if cleared then
        self:_emit("status", {
          slot = fighter.slot, side = fighter.side,
          text = mon.species .. " recovered",
        })
      end
      if not applied and not healed and not cleared then
        self:_say("But it failed")
      end
    end
  end
end

-- Gen1 TossBallAnimation event stream (mirror BattleState:ballChain / tossAnimFor).
-- Clients pair AnimPlayer opts.ball from the preceding `item` event's text.
function Battle:_emitBallChain(fighter, ballId, caught, shakes)
  local slot, side = fighter.slot, fighter.side
  local toss = ballId == "POKE_BALL" and "TOSS_ANIM"
    or ballId == "GREAT_BALL" and "GREATTOSS_ANIM"
    or "ULTRATOSS_ANIM"
  local function anim(text, amount)
    local fields = { slot = slot, side = side, text = text }
    if amount ~= nil then fields.amount = amount end
    self:_emit("anim", fields)
  end
  anim(toss)
  anim("POOF_ANIM")
  if not caught and (not shakes or shakes == 0) then return end
  anim("HIDEPIC_ANIM")
  anim("SHAKE_ANIM", shakes or 0)
  if not caught then
    anim("POOF_ANIM")
    anim("SHOWPIC_ANIM")
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
        speed = self:_speedOf(fighter, mon),
        order = #actors + 1,
      }
    end
  end
  if #actors == 0 then return end

  self:_sortActorsBySpeed(actors)

  for _, actor in ipairs(actors) do
    if self.result then break end
    -- The monster that chose is the only one allowed to act: if it fainted to
    -- a faster attacker, the replacement that came in behind it does not
    -- inherit the turn.
    if activeMon(actor.fighter) == actor.mon then
      self:_useMove(actor.fighter, actor.mon)
    end
    -- Finalize after each action (not inside `_faint`) so KO + recoil / explode
    -- on the same move can still mutual-faint into a draw, while an empty-bench
    -- KO still stops the slower seat from acting.
    if not self.result then self:_checkOver() end
  end
end

-- Returns false when a gate stopped the move.
function Battle:_runGates(fighter, mon)
  if mon.flinch then
    mon.flinch = false
    self:_say(mon.species .. " flinched")
    return false
  end

  if GATING[mon.status] then
    local gate = Status.beforeMove(
      { status = mon.status, turnsRemaining = mon.statusTurns }, self.rng:byte())
    if gate then
      mon.statusTurns = int(gate.turnsRemaining, mon.statusTurns)
      if gate.wokeUp then
        mon.status, mon.statusTurns = nil, 0
        self:_emit("status", { slot = fighter.slot, side = fighter.side,
                               text = mon.species .. " woke up" })
      elseif gate.thawed then
        mon.status, mon.statusTurns = nil, 0
        self:_emit("status", { slot = fighter.slot, side = fighter.side,
                               text = mon.species .. " thawed out" })
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

function Battle:_applyPrimary(fighter, mon, targetFighter, targetMon, moveIndex, effectId)
  local result = Effects.applyPrimary({
    effectId = effectId,
    rng = self.rng,
    userMon = mon,
    targetMon = targetMon,
    userFighter = fighter,
    targetFighter = targetFighter,
    moveIndex = moveIndex,
    statusToWire = M.STATUS_TO_WIRE,
  })
  if result.nothing then self:_say("But nothing happened") end
  for _, text in ipairs(result.messages or {}) do self:_say(text) end
  for _, entry in ipairs(result.events or {}) do
    self:_emit(entry.kind, entry.fields)
  end
  for _, heal in ipairs(result.heals or {}) do
    self:_heal(fighter, mon, heal.amount)
  end
  for _, cost in ipairs(result.costs or {}) do
    self:_damage(fighter, mon, cost.amount, nil)
  end
  for _, hit in ipairs(result.directDamage or {}) do
    self:_emit("damage", {
      slot = fighter.slot, side = fighter.side,
      amount = hit.amount, hp = mon.hp,
    })
  end
  if result.movesChanged then self:_emitMoves(fighter, mon) end
end

function Battle:_applySide(fighter, mon, targetFighter, targetMon, effectId, chance)
  local result = Effects.applySide({
    effectId = effectId,
    chance = chance,
    rng = self.rng,
    userMon = mon,
    targetMon = targetMon,
    userFighter = fighter,
    targetFighter = targetFighter,
    statusToWire = M.STATUS_TO_WIRE,
  })
  for _, text in ipairs(result.messages or {}) do self:_say(text) end
  for _, entry in ipairs(result.events or {}) do
    self:_emit(entry.kind, entry.fields)
  end
end

function Battle:_markLastMove(mon, moveIndex)
  if moveIndex and moveIndex >= 1 then mon.lastMoveIndex = moveIndex end
end

function Battle:_faintUser(fighter, mon)
  if mon.hp > 0 then self:_damage(fighter, mon, mon.hp, nil) end
end

function Battle:_concedeRun(fighter)
  self:_emit("run", { slot = fighter.slot, side = fighter.side, text = fighter.name })
  if fighter.side == "a" then
    self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "run")
  else
    self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "run")
  end
end

function Battle:_useMove(fighter, mon, opts)
  opts = opts or {}
  local choice = fighter.choice
  if not mon.moves[choice.move] then return end

  if not self:_runGates(fighter, mon) then return end

  local struggling = allPpEmpty(mon) or choice.struggle
  if not struggling and mon.disable and mon.disable.turns > 0
     and mon.disable.moveIndex == choice.move then
    local blocked = mon.moves[choice.move]
    local moveId = blocked and blocked.id or "move"
    self:_say(moveId .. " is disabled")
    return
  end

  local target = self:_fighterAtSlot(choice.target)
  local defender = target and activeMon(target)
  if not defender then
    self:_say(mon.species .. " has no target")
    return
  end

  local move = opts.moveOverride or (struggling and STRUGGLE or mon.moves[choice.move])
  local effectId = int(move.effect, 0)
  local releasing = mon.charging ~= nil and Effects.isCharge(mon.charging.effect)
  local mirrorCopy = opts.mirrorCopy == true

  if not struggling and move.pp > 0 and not releasing and not choice.bideRelease then
    move.pp = move.pp - 1
  end
  self:_emit("anim", { slot = fighter.slot, side = fighter.side, text = move.id })
  self:_say(mon.species .. " used " .. move.id)

  if choice.bideRelease and mon.bide then
    local stored = mon.bide.stored
    mon.bide = nil
    if stored <= 0 then
      self:_say("But it failed")
      self:_markLastMove(mon, choice.move)
      return
    end
    self:_damage(target, defender, 2 * stored, nil)
    self:_markLastMove(mon, choice.move)
    return
  end

  if Effects.isCharge(effectId) and not mon.charging then
    mon.charging = {
      moveIndex = choice.move,
      effect = effectId,
      targetSlot = choice.target,
    }
    if Effects.isFly(effectId) then mon.invulnerable = true end
    self:_say(Effects.chargeMessage(mon, effectId))
    self:_markLastMove(mon, choice.move)
    return
  end

  if mon.charging and Effects.isCharge(mon.charging.effect) then
    mon.charging = nil
    mon.invulnerable = false
  end

  if defender.invulnerable then
    self:_say("But it failed")
    if Effects.isExplode(effectId) then self:_faintUser(fighter, mon) end
    if Effects.isJumpKick(effectId) then
      self:_damage(fighter, mon, Effects.jumpKickCrash(mon.maxHp), nil)
    end
    self:_markLastMove(mon, choice.move)
    return
  end

  if Effects.isMirrorMove(effectId) and not mirrorCopy then
    local lastIdx = int(defender.lastMoveIndex, 0)
    if lastIdx < 1 or not defender.moves[lastIdx] then
      self:_say("But it failed")
      self:_markLastMove(mon, choice.move)
      return
    end
    self:_markLastMove(mon, choice.move)
    self:_useMove(fighter, mon, {
      moveOverride = copyMove(defender.moves[lastIdx]),
      mirrorCopy = true,
    })
    return
  end

  local metronomeCall = opts.metronomeCall == true
  if Effects.isMetronome(effectId) and not metronomeCall then
    local pool = self.metronomePool
    if not pool or #pool == 0 then
      self:_say("But nothing happened")
      self:_markLastMove(mon, choice.move)
      return
    end
    local pick = (self.rng:byte() % #pool) + 1
    self:_markLastMove(mon, choice.move)
    self:_useMove(fighter, mon, {
      moveOverride = copyMove(pool[pick]),
      metronomeCall = true,
    })
    return
  end

  local alwaysHits = effectId == Effects.idOf("SWIFT_EFFECT")
    or mon.xAccuracy == true

  -- Gen 2 rolls in the percent domain (0..99 vs 1..100).  A move sheet that
  -- still carries a Gen 1 accuracy byte (1..255) is scaled down.
  local acc = max(0, int(move.accuracy, 100))
  if acc > 100 then acc = max(1, floor(acc * 100 / 255)) end
  local hit = Accuracy.hit(acc, self.rng:nextInt(0, Accuracy.ROLL_MAX), {
    accuracyStage = mon.stages.acc,
    evasionStage = defender.stages.eva,
    alwaysHits = alwaysHits or acc <= 0,
  })
  if not hit then
    self:_say(mon.species .. " missed")
    if Effects.isExplode(effectId) then self:_faintUser(fighter, mon) end
    if Effects.isJumpKick(effectId) then
      self:_damage(fighter, mon, Effects.jumpKickCrash(mon.maxHp), nil)
    end
    self:_markLastMove(mon, choice.move)
    return
  end

  local isFixed = Effects.isFixedDamage(effectId)
  if effectId == 8 and defender.status ~= "sleep" then
    self:_say("But it failed")
    if Effects.isExplode(effectId) then self:_faintUser(fighter, mon) end
    self:_markLastMove(mon, choice.move)
    return
  end

  if move.power <= 0 and not isFixed then
    if Effects.isBide(effectId) and not mon.bide then
      mon.bide = {
        turns = Effects.bideTurns(self.rng),
        stored = 0,
        moveIndex = choice.move,
        targetSlot = choice.target,
      }
      self:_say(mon.species .. " began storing energy")
      self:_markLastMove(mon, choice.move)
      return
    end
    if Effects.isSwitchAndTeleport(effectId) then
      if Effects.teleportRunAllowed(self.mode) then
        self:_concedeRun(fighter)
      else
        self:_say("But it failed")
      end
      self:_markLastMove(mon, choice.move)
      return
    end
    if Effects.isNoOp(effectId) then
      self:_say("But nothing happened")
      self:_markLastMove(mon, choice.move)
      return
    end
    if Effects.handlesPrimary(effectId) then
      self:_applyPrimary(fighter, mon, target, defender, choice.move, effectId)
    else
      self:_say("But nothing happened")
    end
    self:_markLastMove(mon, choice.move)
    return
  end

  if effectId == 38 then
    if self:_speedOf(fighter, mon) <= self:_speedOf(target, defender) then
      self:_say("But it failed")
      if Effects.isExplode(effectId) then self:_faintUser(fighter, mon) end
      self:_markLastMove(mon, choice.move)
      return
    end
  end

  local hits = Effects.hitCount(effectId, self.rng)
  -- Gen 2 crit ladder (not Gen 1 base-Speed threshold).
  local critOpts = {
    focusEnergy = mon.focusEnergy,
    highCritMove = move.highCrit == true,
  }
  local critLevel = Crit.level(critOpts)
  local critChance = Crit.chance(critLevel)
  local isCrit = select(1, Crit.check(critLevel, self.rng:below(critChance)))
  local percents = self:_typePercents(move.type, defender)

  local immune = false
  for _, pct in ipairs(percents) do
    if pct <= 0 then immune = true; break end
  end

  local damage = 0
  if isFixed then
    if immune then
      self.rng:damageRoll()
      self:_say("It doesn't affect " .. defender.species)
      if Effects.isExplode(effectId) then self:_faintUser(fighter, mon) end
      if Effects.isJumpKick(effectId) then
        self:_damage(fighter, mon, Effects.jumpKickCrash(mon.maxHp), nil)
      end
      self:_markLastMove(mon, choice.move)
      return
    end
    local fixed = Effects.fixedDamage({
      effectId = effectId,
      userMon = mon,
      targetMon = defender,
      power = move.power,
      userSpeed = self:_speedOf(fighter, mon),
      foeSpeed = self:_speedOf(target, defender),
    })
    if fixed == nil then
      self.rng:damageRoll()
      self:_say("But it failed")
      if Effects.isExplode(effectId) then self:_faintUser(fighter, mon) end
      self:_markLastMove(mon, choice.move)
      return
    end
    self.rng:damageRoll()
    damage = fixed
  else
    local isSpecial = Effects.isSpecialType(move.type, self.specialTypes)
    local atkKey = isSpecial and "spa" or "atk"
    local defKey = isSpecial and "spd" or "def"
    local atkStat = Effects.badgeBoost(
      isSpecial and mon.stats.spa or mon.stats.atk, atkKey, fighter.badges)
    local atkStage = isSpecial and mon.stages.spa or mon.stages.atk
    local defStat = Effects.badgeBoost(
      isSpecial and defender.stats.spd or defender.stats.def, defKey, target.badges)
    local defStage = isSpecial and defender.stages.spd or defender.stages.def

    local attack = Effects.applyStage(atkStat, atkStage)
    if (not isSpecial) and mon.status == "burn" then
      attack = Status.burnAttack(attack)
    end

    local defense = Effects.applyStage(defStat, defStage)
    if Effects.isExplode(effectId) then
      defense = max(1, floor(defense / 2))
    end

    local result = Damage.compute(
      { level = mon.level, attack = attack, spa = attack },
      { defense = defense, spd = defense },
      { power = move.power },
      {
        crit = isCrit,
        stab = hasType(mon, move.type),
        typeEffect = percents,
        roll = self.rng:damageRoll(),
        physical = not isSpecial,
      })

    if result.immune then
      self:_say("It doesn't affect " .. defender.species)
      if Effects.isExplode(effectId) then self:_faintUser(fighter, mon) end
      if Effects.isJumpKick(effectId) then
        self:_damage(fighter, mon, Effects.jumpKickCrash(mon.maxHp), nil)
      end
      self:_markLastMove(mon, choice.move)
      return
    end
    damage = result.damage or 0
  end

  local isSpecial = Effects.isSpecialType(move.type, self.specialTypes)
  damage = Effects.screenDamage(damage, defender, isSpecial)

  local effectiveness = 1
  for _, pct in ipairs(percents) do effectiveness = effectiveness * pct / 100 end
  if isCrit and not isFixed then self:_say("A critical hit") end
  if effectiveness > 1 then
    self:_say("It's super effective")
  elseif effectiveness < 1 then
    self:_say("It's not very effective")
  end

  local totalDealt = 0
  for _ = 1, hits do
    if defender.hp <= 0 then break end
    local hpBefore = defender.hp
    self:_damage(target, defender, damage, nil)
    totalDealt = totalDealt + (hpBefore - defender.hp)
  end

  if totalDealt > 0 then
    self:_applySide(fighter, mon, target, defender, effectId, move.chance)

    if Effects.isDrain(effectId) then
      local heal = Effects.drainAmount(totalDealt)
      if heal > 0 then self:_heal(fighter, mon, heal) end
    end

    if Effects.isPayDay(effectId) then
      self:_say("Coins scattered")
    end
  end

  if (struggling or Effects.isRecoil(effectId)) and totalDealt >= 1 then
    local recoil = Effects.recoilAmount(totalDealt)
    self:_say(mon.species .. " is hit with recoil")
    self:_damage(fighter, mon, recoil, nil)
  end

  if Effects.handlesPrimary(effectId) then
    self:_applyPrimary(fighter, mon, target, defender, choice.move, effectId)
  end

  if Effects.isThrash(effectId) and not mon.thrashing then
    mon.thrashing = {
      turns = Effects.thrashTurns(self.rng),
      moveIndex = choice.move,
    }
  end

  if Effects.isRage(effectId) then
    mon.raging = true
    mon.rageMove = choice.move
  end

  if Effects.isTrapping(effectId) and totalDealt > 0 then
    local turns = Effects.trapTurns(self.rng)
    defender.trapped = {
      turns = turns,
      damage = totalDealt,
      fromSlot = fighter.slot,
    }
    mon.trapping = {
      turns = turns,
      moveIndex = choice.move,
      targetSlot = target.slot,
    }
  end

  if Effects.isHyperBeam(effectId) and totalDealt > 0 and defender.hp > 0 then
    mon.mustRecharge = true
  end

  if Effects.isExplode(effectId) then
    self:_faintUser(fighter, mon)
  end

  self:_markLastMove(mon, choice.move)

  if mon.thrashing then
    mon.thrashing.turns = mon.thrashing.turns - 1
    if mon.thrashing.turns <= 0 then
      mon.thrashing = nil
      local turns = self.rng:byte() % 4 + 2
      mon.confusion = turns
      self:_say(mon.species .. " became confused")
    end
  end
end

-- One place where HP comes off, so the faint that follows can never be
-- forgotten at one of the call sites.
function Battle:_damage(fighter, mon, amount, status)
  amount = max(0, int(amount, 0))

  if amount > 0 and mon.bide and mon.bide.turns > 0 then
    mon.bide.stored = mon.bide.stored + amount
  end

  if amount > 0 and mon.substitute and mon.substitute > 0 then
    if amount >= mon.substitute then
      mon.substitute = 0
      self:_say(mon.species .. "'s substitute broke")
    else
      mon.substitute = mon.substitute - amount
    end
    self:_emit("damage", {
      slot = fighter.slot, side = fighter.side,
      amount = amount, hp = mon.hp,
      status = status and M.STATUS_TO_WIRE[status] or nil,
    })
    return
  end

  if amount > mon.hp then amount = mon.hp end

  if amount > 0 and mon.raging then
    local before = Effects.clampStage(mon.stages.atk)
    local after = Effects.clampStage(before + 1)
    if after ~= before then
      mon.stages.atk = after
      self:_say(mon.species .. "'s ATTACK rose")
      self:_emit("stat", {
        slot = fighter.slot, side = fighter.side,
        amount = after, text = mon.species .. "'s ATTACK rose",
      })
    end
  end

  mon.hp = mon.hp - amount

  self:_emit("damage", {
    slot = fighter.slot, side = fighter.side,
    amount = amount, hp = mon.hp,
    status = status and M.STATUS_TO_WIRE[status] or nil,
  })

  if mon.hp <= 0 then self:_faint(fighter, mon) end
end

function Battle:_heal(fighter, mon, amount)
  amount = max(0, int(amount, 0))
  if amount <= 0 then return end
  local before = mon.hp
  mon.hp = min(mon.maxHp, mon.hp + amount)
  local gained = mon.hp - before
  if gained <= 0 then return end
  self:_emit("drain", {
    slot = fighter.slot, side = fighter.side,
    amount = gained, hp = mon.hp,
  })
end

function Battle:_faint(fighter, mon)
  mon.charging = nil
  mon.invulnerable = false
  mon.mustRecharge = false
  mon.thrashing = nil
  mon.raging = false
  mon.rageMove = 0
  mon.trapped = nil
  mon.trapping = nil
  mon.bide = nil
  mon.substitute = 0
  mon.lightScreen = false
  mon.reflect = false
  mon.mist = false
  mon.focusEnergy = false
  mon.transformed = false
  mon.xAccuracy = false
  mon.leechSeed = nil
  mon.disable = nil
  self:_clearTrapsFrom(fighter.slot)

  -- Living bench? Computed before clearing active; fainted mon already has hp 0.
  local next_ = firstLiving(fighter.mons)
  self:_emit("faint", {
    slot = fighter.slot, side = fighter.side, text = mon.species,
    -- amount=1 is the authoritative mustReplace signal (living bench). Clients
    -- open the replace picker from this rather than guessing from local HP.
    -- Omitted when the seat is out of mons so empty-bench never arms a picker.
    amount = next_ and 1 or nil,
  })

  fighter.active = nil
  if next_ then
    -- Ask the seat for a switch on the next choice window; timeout / autoPick
    -- still lands firstLiving (preferring an SE bench). No PROTOCOL bump —
    -- same `switch` + `turn`/`chose` vocabulary; amount rides an existing field.
    fighter.mustReplace = true
  else
    fighter.mustReplace = nil
  end

  -- While resolving, defer `_checkOver` to the caller (after the current move /
  -- residual batch) so the same action can still faint the user (recoil,
  -- explode) and land a draw. Outside resolve, end immediately.
  if self.phase ~= "resolving" then self:_checkOver() end
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
    if self.result then return end
    mon = activeMon(fighter)
    if mon and mon.trapped and mon.trapped.turns > 0 then
      local trap = mon.trapped
      self:_say(mon.species .. " is hurt by the trap")
      self:_damage(fighter, mon, trap.damage, nil)
      trap.turns = trap.turns - 1
      if trap.turns <= 0 then
        mon.trapped = nil
        local trapper = trap.fromSlot and self:_fighterAtSlot(trap.fromSlot)
        local tMon = trapper and activeMon(trapper)
        if tMon then tMon.trapping = nil end
      else
        local trapper = trap.fromSlot and self:_fighterAtSlot(trap.fromSlot)
        local tMon = trapper and activeMon(trapper)
        if tMon and tMon.trapping then tMon.trapping.turns = trap.turns end
      end
    end
    mon = activeMon(fighter)
    if mon and mon.bide and mon.bide.turns > 0 then
      mon.bide.turns = mon.bide.turns - 1
    end
    if self.result then return end
    mon = activeMon(fighter)
    if mon and mon.leechSeed then
      local amount = max(1, floor(mon.maxHp / 16))
      self:_say(mon.species .. " is seeded")
      self:_damage(fighter, mon, amount, nil)
      local from = mon.leechSeed.fromSlot
      local seeder = from and self:_fighterAtSlot(from)
      local sMon = seeder and activeMon(seeder)
      if sMon and sMon.hp > 0 then self:_heal(seeder, sMon, amount) end
    end
    if self.result then return end
    mon = activeMon(fighter)
    if mon and mon.disable and mon.disable.turns > 0 then
      mon.disable.turns = mon.disable.turns - 1
      if mon.disable.turns <= 0 then
        local idx = mon.disable.moveIndex
        local cleared = mon.moves[idx]
        mon.disable = nil
        if cleared and cleared.id then
          self:_say(cleared.id .. " is no longer disabled")
        end
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
  self.resolveDeadline = nil
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

  -- Forced-only turns opened by the previous resolve wait here so one drain
  -- does not swallow a whole trap / recharge / thrash chain.
  if self.forcedPending and self.phase == "choice" then
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

  -- A turn left in `resolving` -- typically after a throw the hub contained --
  -- has no player to wait on, so the ceiling is the only way out. `timeout` is
  -- the existing reason: Wire already phrases it, and a stuck resolve is not
  -- something a screen can usefully distinguish from an unanswered turn.
  if self.phase == "resolving" and self.resolveDeadline
     and self.now >= self.resolveDeadline then
    self:_finish("draw", nil, nil, "timeout")
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
          self:_emit("chose", {
            slot = fighter.slot, side = fighter.side, text = fighter.name,
          })
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
      mustReplace = fighter.mustReplace == true,
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
    resolveDeadline = self.resolveDeadline,
    over = self.result ~= nil,
    reason = self.result and self.result.reason or nil,
    rngState = self.rng:state(),
    field = field,
    waiting = waiting,
  }
end

return M
