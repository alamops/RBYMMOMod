-- Gen 3 move resolution: from "this seat uses this move" to the last event.
--
-- Port of engine src/core/game3/battle/engine.lua (`resolveMove`, `run`,
-- `canceller` pokefirered/src/battle_util.c:1253, `Ctx:accuracyCheck`
-- battle_script_commands.c:1003, `charge_turn`, `ohko`, `try_bounce`,
-- `call_moves`, `move_end` battle_script_commands.c:4056, `forEachTarget`
-- :4308, `resolveTarget` battle_main.c:4024) and effects/hit.lua (`Hit.run`,
-- `hit_once`, `dealDamage` battle_script_commands.c:1744, `adjustDamage` :1577,
-- triple kick, beat up, spit up, present, rollout, fury cutter, drain, crash).
--
-- This file also installs the battle's HELPER SURFACE -- the methods every
-- effect / ability / item behaviour talks to the field through (B:roll,
-- B:active, B:foes, B:say, B:heal, B:loseHp, B:inflict, ...).  Turn.lua owns
-- the machine (choices, phases, the clock, faints, exp) and calls
-- `Move.install(Battle)` once.
--
-- Where this port follows pret rather than the engine, the line says so:
-- absorb abilities act before the accuracy roll (attackcanceler), Future Sight
-- is a delayed attack even though it has power, Facade / Revenge / SmellingSalt
-- double, Struggle is not stopped by Wonder Guard, a cancelled move clears the
-- last *resulting* move too (Protect's streak), and there is no disobedience,
-- no badge boost and no Oak / Pokedude / ghost-battle branch (link rules).
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Types     = need("BattleSim3/Types")
local Damage    = need("BattleSim3/Damage")
local Accuracy  = need("BattleSim3/Accuracy")
local Crit      = need("BattleSim3/Crit")
local Status    = need("BattleSim3/Status")
local Abilities = need("BattleSim3/Abilities")
local Items     = need("BattleSim3/Items")
local Field     = need("BattleSim3/Field")
local Effects   = need("BattleSim3/Effects")

local M = {}

local floor, max, min = math.floor, math.max, math.min

local E = Effects.E

-- pokefirered/include/constants/battle.h MOVE_TARGET_*
M.TARGET = {
  SELECTED = 0, DEPENDS = 1, USER_OR_SELECTED = 2, RANDOM = 4, BOTH = 8, USER = 16,
  FOES_AND_ALLY = 32, OPPONENTS_FIELD = 64,
}
local T = M.TARGET

-- pokefirered/include/constants/pokemon.h:238 FLAG_*
M.FLAG = { CONTACT = 1, PROTECT = 2, MAGIC_COAT = 4, SNATCH = 8, MIRROR_MOVE = 16, KINGS_ROCK = 32 }
local F = M.FLAG

-- pret include/constants/moves.h, the ones this file branches on.
local MOVE = {
  FLY = 19, SURF = 57, DIG = 91, RAGE = 99, METRONOME = 118, MIRROR_MOVE = 119,
  SKY_ATTACK = 143, STRUGGLE = 165, SNORE = 173, CURSE = 174, SLEEP_TALK = 214,
  WHIRLPOOL = 250, UPROAR = 253, FOCUS_PUNCH = 264, ASSIST = 274, DIVE = 291, BOUNCE = 340,
}
M.MOVE = MOVE

-- The synthetic Struggle row (pret battle_moves.h MOVE_STRUGGLE; public facts).
M.STRUGGLE = {
  id = "STRUGGLE", name = "STRUGGLE", num = 165, power = 50, type = 0, accuracy = 100,
  pp = 1, maxPp = 1, effect = 48, chance = 0, target = 0, priority = 0, flags = 3,
}

local TWO_TURN = {
  [E.SKULL_BASH] = true, [E.RAZOR_WIND] = true, [E.SKY_ATTACK] = true,
  [E.SOLAR_BEAM] = true, [E.SEMI_INVULNERABLE] = true, [E.BIDE] = true,
}

-- src/battle_message.c:1029 / battle_scripts_1.s:794 (our own words)
local CHARGE_TEXT = {
  [E.RAZOR_WIND] = " whipped up a whirlwind!", [E.SOLAR_BEAM] = " took in sunlight!",
  [E.SKULL_BASH] = " lowered its head!", [E.SKY_ATTACK] = " is glowing!",
}
local SEMI_TEXT = {
  [MOVE.FLY] = { " flew up high!", "ON_AIR" }, [MOVE.BOUNCE] = { " sprang up!", "ON_AIR" },
  [MOVE.DIG] = { " dug a hole!", "UNDERGROUND" }, [MOVE.DIVE] = { " hid underwater!", "UNDERWATER" },
}

-- Type names for sentences (pret TYPE_* tokens, not ROM text).
local TYPE_LABEL = {
  [0] = "NORMAL", [1] = "FIGHTING", [2] = "FLYING", [3] = "POISON", [4] = "GROUND",
  [5] = "ROCK", [6] = "BUG", [7] = "GHOST", [8] = "STEEL", [9] = "???", [10] = "FIRE",
  [11] = "WATER", [12] = "GRASS", [13] = "ELECTRIC", [14] = "PSYCHIC", [15] = "ICE",
  [16] = "DRAGON", [17] = "DARK",
}

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function hasFlag(move, flag)
  return floor(int(move and move.flags, 0) / flag) % 2 == 1
end
M.hasFlag = hasFlag

local function isType(b, t) return b ~= nil and (b.type1 == t or b.type2 == t) end

-- ==================================================================
-- the helper surface (installed on Battle)
-- ==================================================================

local Bm = {}

function Bm:roll(lo, hi) return self.rng:roll(lo, hi) end

-- pret battler-id order: a1, b1, a2, b2, a3, b3 (only the seats that exist).
function Bm:battlerOrder() return self.order end

function Bm:battlerCount() return #self.fighters end

function Bm:active()
  local out = {}
  for _, f in ipairs(self.order) do
    local b = f.b
    if b and b.mon.hp > 0 then out[#out + 1] = b end
  end
  return out
end

function Bm:foes(b)
  local out = {}
  for _, o in ipairs(self:active()) do
    if o.side ~= b.side then out[#out + 1] = o end
  end
  return out
end

function Bm:allies(b)
  local out = {}
  for _, o in ipairs(self:active()) do
    if o.side == b.side and o ~= b then out[#out + 1] = o end
  end
  return out
end

-- The nearest standing ally seat (ties to the lower slot).
function Bm:partner(b)
  local best, bestD
  for _, o in ipairs(self:allies(b)) do
    local d = o.slot - b.slot
    if d < 0 then d = -d end
    if not bestD or d < bestD or (d == bestD and o.slot < best.slot) then best, bestD = o, d end
  end
  return best
end

function Bm:countStandingOnSide(side)
  local n = 0
  for _, o in ipairs(self:active()) do if o.side == side then n = n + 1 end end
  return n
end

function Bm:sideState(side) return self.sides[side] end

function Bm:weather() return Field.effective(self.field.weather, self:active()) end

function Bm:uproarActive()
  for _, b in ipairs(self:active()) do
    if int(b.uproarTurns, 0) > 0 then return b end
  end
  return nil
end

function Bm:fieldSport(key)
  for _, b in ipairs(self:active()) do if b[key] then return true end end
  return false
end

function Bm:abilityOnField(name)
  for _, b in ipairs(self:active()) do if b.ability == name then return true end end
  return false
end

function Bm:isWild()
  return type(self.mode) == "string" and self.mode:find("wild", 1, true) ~= nil
end

function Bm:nameOf(b)
  return (b and b.mon and b.mon.species) or "POKeMON"
end

function Bm:abilityLabel(b)
  return Abilities.label(b and b.ability, b and b.abilityName)
end

function Bm:itemLabelOf(id, name)
  if type(name) == "string" and name ~= "" then return name end
  return "ITEM " .. tostring(int(id, 0))
end

function Bm:itemLabel(b)
  return self:itemLabelOf(b and b.mon.heldItem, b and b.mon.itemName)
end

function Bm:moveLabel(mv)
  if type(mv) ~= "table" then return "MOVE" end
  if type(mv.name) == "string" and mv.name ~= "" then return mv.name end
  if type(mv.id) == "string" and mv.id ~= "" then return (mv.id:gsub("_", " ")) end
  return "MOVE"
end

function Bm:moveLabelByNum(num)
  local row = self:moveRowByNum(num)
  return row and self:moveLabel(row) or "MOVE"
end

function Bm:typeLabel(t) return TYPE_LABEL[int(t, 0)] or "???" end

function Bm:say(text)
  if type(text) ~= "string" or text == "" then return end
  return self:_emit("msg", { text = text })
end

function Bm:emit(kind, fields) return self:_emit(kind, fields) end

function Bm:emitAbility(b)
  if not b or not b.ability then return end
  return self:_emit("ability", {
    slot = b.slot, side = b.side, amount = Abilities.idOf(b.ability), text = self:abilityLabel(b),
  })
end

-- HP moves in exactly one of these three places, so every change is an event.
function Bm:heal(b, amount)
  amount = max(0, int(amount, 0))
  if amount <= 0 or not b then return 0 end
  local before = b.mon.hp
  b.mon.hp = min(b.mon.maxHp, b.mon.hp + amount)
  local gained = b.mon.hp - before
  if gained > 0 then
    self:_emit("drain", { slot = b.slot, side = b.side, amount = gained, hp = b.mon.hp })
  end
  return gained
end

function Bm:loseHp(b, amount, opts)
  amount = max(0, int(amount, 0))
  if not b then return 0 end
  if amount > b.mon.hp then amount = b.mon.hp end
  b.mon.hp = b.mon.hp - amount
  self:_emit("damage", {
    slot = b.slot, side = b.side, amount = amount, hp = b.mon.hp,
    status = opts and opts.status or nil,
  })
  return amount
end

function Bm:setHp(b, value)
  value = max(0, min(b.mon.maxHp, int(value, 0)))
  if value > b.mon.hp then
    self:heal(b, value - b.mon.hp)
  elseif value < b.mon.hp then
    self:loseHp(b, b.mon.hp - value)
  end
end

function Bm:canInflict(b, status, opts)
  opts = opts or {}
  return Status.canApply(b, status, {
    sun = self:weather() == "SUN", uproar = self:uproarActive() ~= nil,
    safeguard = int(self.sides[b.side].safeguardTurns, 0) > 0,
    ignoreSafeguard = opts.ignoreSafeguard,
  })
end

-- Set a major status (adapter applyStatus, battle_script_commands.c:2356).
-- opts: turns (sleep counter), text (the sentence; default ours), silent (no
-- sentence), source.
function Bm:inflict(b, status, opts)
  opts = opts or {}
  status = Status.normalise(status)
  if not b or not status then return false end
  b.mon.status = status
  if status == "TOX" then b.toxicCounter = 0 end
  if status == "SLP" then
    b.mon.sleepTurns = int(opts.turns, nil) or Status.sleepTurns(self.rng)
    self:cancelMultiTurn(b)
  elseif status == "FRZ" then
    self:cancelMultiTurn(b)
  end
  local text = opts.text or (self:nameOf(b) .. (Status.INFLICT_TEXT[status] or " is afflicted!"))
  self:_emit("status", { slot = b.slot, side = b.side, status = status, text = text })
  if not opts.silent then self:say(text) end
  return true
end

-- Clear the major status.  `text` nil clears silently (the event still goes).
function Bm:cure(b, text)
  if not b or not Status.normalise(b.mon.status) then return false end
  b.mon.status = nil
  b.mon.sleepTurns = nil
  b.toxicCounter = nil
  self:_emit("status", { slot = b.slot, side = b.side, text = text })
  if text then self:say(text) end
  return true
end

-- pokefirered/src/battle_util.c:203 CancelMultiTurnMoves
function Bm:cancelMultiTurn(b)
  if not b then return end
  b.lockedNum, b.lockedSlot, b.lockedTarget = nil, nil, nil
  b.rampageTurns, b.uproarTurns, b.bideTurns = nil, nil, nil
  b.twoTurnNum, b.twoTurnTarget = nil, nil
  b.semi = nil
  b.rolloutTimer = nil
  b.furyCutter = nil
end

-- ------------------------------------------------------------------
-- move rows
-- ------------------------------------------------------------------

function Bm:copyMove(row)
  if type(row) ~= "table" then return nil end
  return {
    id = row.id, name = row.name, num = int(row.num, 0), pp = max(0, int(row.pp, 0)),
    maxPp = max(0, int(row.maxPp, int(row.pp, 0))), power = max(0, int(row.power, 0)),
    accuracy = max(0, int(row.accuracy, 0)), type = max(0, int(row.type, 0)),
    effect = max(0, int(row.effect, 0)), chance = max(0, int(row.chance, 0)),
    target = max(0, int(row.target, 0)), priority = int(row.priority, 0),
    flags = max(0, int(row.flags, 0)),
  }
end

-- The row a CALLED move resolves to (Nature Power's terrain move, Mirror Move,
-- a locked move that was called): the caller's own list (overlay first), then
-- the ruleset pool (the host's decoded move table -- pret reads gBattleMoves),
-- then the caller's seat's party sheets (an Assist-called lock with no pool).
-- Never another fighter's sheet: a row somebody else uploaded under a borrowed
-- number (Swift carrying EFFECT_NATURE_POWER, a 255-power "Swift") can never
-- become the caller's move.
function Bm:calledRowByNum(num, caller)
  num = int(num, 0)
  if num == 0 then return nil end
  if num == MOVE.STRUGGLE then return M.STRUGGLE end
  local function scan(list)
    for i = 1, #(list or {}) do
      if int(list[i].num, 0) == num then return list[i] end
    end
    return nil
  end
  local hit = caller and scan(caller.moves) or nil
  if hit then return hit end
  if self.pool and self.pool[num] then return self.pool[num] end
  for _, mon in ipairs(caller and caller.fighter and caller.fighter.mons or {}) do
    hit = scan(mon.moves)
    if hit then return hit end
  end
  return nil
end

-- A move row by number: the hint battler's list, every battler on the field,
-- every party, then the ruleset pool.  Labels and look-ups only; a row that is
-- going to be USED as a called move comes from `calledRowByNum`.
function Bm:moveRowByNum(num, hint)
  num = int(num, 0)
  if num == 0 then return nil end
  if num == MOVE.STRUGGLE then return M.STRUGGLE end
  local function scan(list)
    for i = 1, #(list or {}) do
      if int(list[i].num, 0) == num then return list[i] end
    end
    return nil
  end
  if hint then
    local hit = scan(hint.moves) or scan(hint.mon and hint.mon.moves)
    if hit then return hit end
  end
  for _, f in ipairs(self.order) do
    if f.b then
      local hit = scan(f.b.moves)
      if hit then return hit end
    end
    for _, mon in ipairs(f.mons) do
      local hit = scan(mon.moves)
      if hit then return hit end
    end
  end
  return self.pool and self.pool[num] or nil
end

function Bm:slotOfNum(b, num)
  num = int(num, 0)
  if num == 0 or not b then return nil end
  for i = 1, #b.moves do
    if int(b.moves[i].num, 0) == num then return i end
  end
  return nil
end

function Bm:isTwoTurnNum(num)
  local row = self:moveRowByNum(num)
  return row ~= nil and TWO_TURN[int(row.effect, -1)] == true
end

-- Transform / Mimic write into a battle-only copy of the move list.
function Bm:overlayMoves(b)
  if b.overlay then return end
  local copy = {}
  for i = 1, #b.moves do copy[i] = self:copyMove(b.moves[i]) end
  b.moves = copy
  b.overlay = true
end

-- A `moves` event: `mon` when this is the party's real list, absent on an
-- overlay (Transform / Mimic).
function Bm:emitMovesOf(b, real)
  local list = {}
  for i = 1, #b.moves do
    local m = b.moves[i]
    local row = self:copyMove(m)
    if type(row.id) ~= "string" or row.id == "" then row.id = "MOVE" end
    if type(m.name) ~= "string" or m.name == "" then row.name = nil end
    list[#list + 1] = row
  end
  if #list == 0 then return end
  local fields = { slot = b.slot, side = b.side, moves = list }
  if real or not b.overlay then fields.mon = b.partyIndex - 1 end
  return self:_emit("moves", fields)
end

-- pokefirered/src/battle_util.c:361 CheckMoveLimitations: the slots this
-- battler may NOT select.  `ignorePP` is the ~MOVE_LIMITATION_PP mask Sleep
-- Talk passes (battle_script_commands.c:7882): every limit but an empty slot's
-- PP.
function Bm:moveLimitations(b, ignorePP)
  local bad = {}
  local he = Items.of(b)
  for i = 1, #b.moves do
    local mv = b.moves[i]
    local n = int(mv.num, 0)
    if n == 0 or (not ignorePP and int(mv.pp, 0) <= 0) then bad[i] = true end
    if b.disabledNum and n == b.disabledNum then bad[i] = true end
    if b.tormented and n == b.lastMoveNum then bad[i] = true end
    if int(b.tauntTurns, 0) > 0 and int(mv.power, 0) == 0 then bad[i] = true end
    if self:isImprisoned(b, n) then bad[i] = true end
    if int(b.encoreTurns, 0) > 0 and b.encoreNum and n ~= b.encoreNum then bad[i] = true end
    if he == Items.HOLD.CHOICE_BAND and b.choicedMove and b.choicedMove ~= n then bad[i] = true end
  end
  return bad
end

function Bm:hasUsableMove(b)
  local bad = self:moveLimitations(b)
  for i = 1, #b.moves do
    if not bad[i] then return true end
  end
  return false
end

-- pokefirered/src/battle_util.c:427
function Bm:isImprisoned(b, num)
  if not num or num == 0 then return false end
  for _, foe in ipairs(self:foes(b)) do
    if foe.imprison then
      for j = 1, #foe.moves do
        if int(foe.moves[j].num, 0) == num then return true end
      end
    end
  end
  return false
end

-- ------------------------------------------------------------------
-- seats, switching, escape
-- ------------------------------------------------------------------

-- The seat that has party member `index` out, or nil.  A shared party (a side
-- entry with `seats = 2`, Turn.create) fields two of its members, one per
-- seat; every other fighter is its own one-seat list (`fighter.seats`).
function Bm:fieldedSeat(fighter, index)
  if index == nil then return nil end
  for _, seat in ipairs(fighter.seats) do
    if seat.active == index then return seat end
  end
  return nil
end

-- Whether party member `index` is spoken for: out on one of the party's seats,
-- or -- while choices are being filed -- the destination of a sibling seat's
-- switch or replacement.  The cart's party menu says "already in battle" for
-- either battler's mon and "already selected" for the partner's pending one
-- (pokefirered/src/party_menu.c:5934; engine.lua switchCandidates /
-- replacementCandidates, both read monToSwitchIntoId).  Once the turn
-- resolves a filed switch has either happened or been dropped, so only the
-- seats count then.  A one-seat fighter only ever has its own active.
function Bm:partyTaken(fighter, index)
  local filing = self.phase == "choice" or self.phase == "replace"
  for _, seat in ipairs(fighter.seats) do
    if seat.active == index then return true end
    local c = seat.choice
    if filing and seat ~= fighter and c and c.action == "switch" and c.slot == index then return true end
  end
  return false
end

-- Living bench party indices (1-based) of a seat, in party order: neither
-- seat's active mon of a shared party, nor one its sibling has claimed
-- (`partyTaken`; pret HasNoMonsToSwitch, battle_util.c, skips both battlers'
-- party indices and the partner's monToSwitchIntoId).
function Bm:benchOf(fighter)
  local out = {}
  for i = 1, #fighter.mons do
    if fighter.mons[i].hp > 0 and not self:partyTaken(fighter, i) then out[#out + 1] = i end
  end
  return out
end

-- Mean Look / Block / Spider Web, a partial trap, Ingrain.
function Bm:isTrapped(b)
  return b.trappedBy ~= nil or int(b.trapTurns, 0) > 0 or b.ingrain == true
end

function Bm:syncTeamsNow() self:_syncTeams() end

-- ==================================================================
-- the move context
-- ==================================================================

local Ctx = {}
Ctx.__index = Ctx
M.Ctx = Ctx

local function newCtx(B, user, target, row, slot, opts)
  local C = setmetatable({
    B = B, user = user, target = target, move = row, mnum = int(row.num, 0),
    effect = int(row.effect, 0), slot = slot, opts = opts or {},
    moveType = int(row.type, 0), dmgMultiplier = 1, animTargetsHit = 0,
  }, Ctx)
  return C
end
M.newCtx = newCtx

function Ctx:moveName() return self.B:moveLabel(self.move) end

-- pokefirered/src/battle_script_commands.c:1108 Cmd_attackstring
function Ctx:attackString()
  if self.printedUsed then return end
  self.printedUsed = true
  self.B:say(self.B:nameOf(self.user) .. " used " .. self:moveName() .. "!")
end

-- pokefirered/src/battle_script_commands.c:1122 Cmd_ppreduce (Pressure costs one more)
function Ctx:ppReduce()
  if self.ppDone then return end
  self.ppDone = true
  if self.noPP or not self.slot then return end
  local B, user = self.B, self.user
  local mv = user.moves[self.slot]
  if not mv then return end
  local cost = 1
  local ttype = int(self.move.target, 0)
  local target = self.target
  if B.double and (ttype == T.FOES_AND_ALLY or ttype == T.BOTH or ttype == T.OPPONENTS_FIELD) then
    for _, b in ipairs(B:active()) do
      if b ~= user and b.ability == "PRESSURE"
          and (ttype == T.FOES_AND_ALLY or b.side ~= user.side) then
        cost = cost + 1
      end
    end
  elseif target and target ~= user and ttype ~= T.USER and target.ability == "PRESSURE" then
    cost = 2
  end
  local before = int(mv.pp, 0)
  if before > cost then mv.pp = before - cost else mv.pp = 0 end
  if mv.pp ~= before then B:emitMovesOf(user) end
end

-- pokefirered/src/battle_controller_player.c:2330 (one anim per target unless
-- the move is a spread / depends move, whose later targets reuse the first)
function Ctx:attackAnimation(amount)
  local B = self.B
  if B.double and self.animTargetsHit > 0 then
    local ttype = int(self.move.target, 0)
    if ttype == T.BOTH or ttype == T.FOES_AND_ALLY or ttype == T.DEPENDS then return end
  end
  local target = self.target
  B:_emit("anim", {
    slot = self.user.slot, side = self.user.side, text = self.move.id or "MOVE",
    amount = amount,
    target = (target and target ~= self.user) and target.slot or nil,
    spread = self.spread and 1 or nil,
  })
  self.animTargetsHit = self.animTargetsHit + 1
end

function Ctx:fail(text)
  self.failed = true
  self.B:say(text or "But it failed!")
end

function Ctx:isProtected()
  local t = self.target
  if not t or t == self.user or not t.protected then return false end
  if not hasFlag(self.move, F.PROTECT) then return false end
  if self.mnum == MOVE.CURSE and not isType(self.user, Types.ID.GHOST) then return false end
  return true
end

function Ctx:lockOnActive()
  local t = self.target
  return t ~= nil and int(t.lockedOnTurns, 0) > 0 and t.lockedOnBy == self.user
end

-- pokefirered/src/battle_script_commands.c:1003 Cmd_accuracycheck.
-- mode "normal" | "noacc" | "lockon" (NO_ACC_CALC / NO_ACC_CALC_CHECK_LOCK_ON).
function Ctx:accuracyCheck(mode, printFail)
  local B, user, target = self.B, self.user, self.target
  local function failMsg(reason)
    self.missReason = reason
    if not printFail then return end
    if reason == "protected" then
      B:say(B:nameOf(target) .. " protected itself!")
    elseif reason == "fail" then
      self.failed = true
      B:say("But it failed!")
    else
      B:say(B:nameOf(user) .. "'s attack missed!")
    end
  end
  if mode == "noacc" or mode == "lockon" then
    if mode == "lockon" and self:lockOnActive() then return true end
    if target and target.semi and target ~= user then failMsg("fail"); return false end
    if self:isProtected() then failMsg("protected"); return false end
    return true
  end
  -- pokefirered/src/battle_script_commands.c:896 JumpIfMoveAffectedByProtect
  if self:isProtected() then failMsg("protected"); return false end
  if self:lockOnActive() then return true end
  local semi = target and target ~= user and target.semi
  if semi == "ON_AIR" and not self.ignoreOnAir then failMsg("miss"); return false end
  if semi == "UNDERGROUND" and not self.ignoreUnderground then failMsg("miss"); return false end
  if semi == "UNDERWATER" and not self.ignoreUnderwater then failMsg("miss"); return false end
  local weather = B:weather()
  local eff = self.effect
  if (weather == "RAIN" and eff == E.THUNDER) or eff == E.ALWAYS_HIT or eff == E.VITAL_THROW then
    return true
  end
  local moveAcc = int(self.accOverride or self.move.accuracy, 100)
  -- Sheet contract: 0 never misses (every cart move with 0 is ALWAYS_HIT or
  -- never reaches this check, so nothing on a cart changes).
  if moveAcc <= 0 then return true end
  if weather == "SUN" and eff == E.THUNDER then moveAcc = 50 end
  local calc = Accuracy.forBattlers(moveAcc, user, target,
    Types.isPhysical(self.moveType, B.specialTypes), weather == "SAND")
  local hit = Accuracy.hit(calc, B:roll(Accuracy.ROLL_MIN, Accuracy.ROLL_MAX))
  if not hit then
    failMsg("miss")
    return false
  end
  return true
end

-- Faint announcements at the engine's points (battle_script_commands.c:2831).
function Ctx:tryFaintTarget()
  local B, user, target = self.B, self.user, self.target
  if not target or target == user then return end
  if target.mon.hp > 0 or target.faintAnnounced then return end
  B:_faintBattler(target)
  if target.destinyBond and user.side ~= target.side and user.mon.hp > 0 then
    B:say(B:nameOf(target) .. " took its attacker down with it!")
    B:loseHp(user, user.mon.hp)
    B:_faintBattler(user)
  end
  -- pokefirered/src/battle_script_commands.c:2894: a foe's Grudge, not
  -- Struggle, and the PP of the slot the attacker CHOSE (chosenMovePositions:
  -- Metronome's slot when Metronome called the KO).
  if target.grudge and self.chosenSlot and user.side ~= target.side and user.mon.hp > 0
      and self.mnum ~= MOVE.STRUGGLE then
    local mv = user.moves[self.chosenSlot]
    if mv then
      mv.pp = 0
      B:say(B:nameOf(user) .. "'s " .. B:moveLabel(mv) .. " lost all its PP due to the GRUDGE!")
      B:emitMovesOf(user)
    end
  end
end

function Ctx:tryFaintUser()
  if self.user.mon.hp <= 0 and not self.user.faintAnnounced then
    self.B:_faintBattler(self.user)
  end
end

-- ==================================================================
-- target resolution (pokefirered/src/battle_main.c:4024, battle_util.c:3054)
-- ==================================================================

-- A uniform pick among living foes, drawn only when there are two or more.
function Bm:_randomFoe(user)
  local foes = self:foes(user)
  if #foes == 0 then return nil end
  if #foes == 1 then return foes[1] end
  return foes[self:roll(0, #foes - 1) + 1]
end

local function followMe(B, user)
  local side = B.sides[user.side == "a" and "b" or "a"]
  local fm = side.followMe
  if fm and fm.mon.hp > 0 and fm.fighter.b == fm then return fm end
  return nil
end

-- The battler an action lands on.  `aimed` is the chosen / stored target
-- battler (or nil); `random` true re-picks a SELECTED move's target at random
-- (a called or Encored move); `called` marks a called move (GetMoveTarget).
function Bm:_pickTarget(user, row, aimed, random, called)
  local ttype = int(row.target, 0)
  if ttype == T.USER then return user end
  -- An active Follow Me takes every MOVE_TARGET_SELECTED move, even one aimed
  -- at the ally (pokefirered/src/battle_main.c:4027 HandleAction_UseMove), and
  -- a called move's random target too (battle_util.c:3054 GetMoveTarget's
  -- MOVE_TARGET_RANDOM arm); a chosen random-target move (Thrash, Uproar) is
  -- not pulled.
  local fm = followMe(self, user)
  if fm and (ttype == T.SELECTED or (called and ttype == T.RANDOM)) then
    return fm
  end
  if ttype == T.RANDOM then
    return self:_randomFoe(user)
  end
  if ttype == T.SELECTED or ttype == T.USER_OR_SELECTED then
    local t = aimed
    if random or t == nil then t = self:_randomFoe(user) end
    -- stolen KO / emptied aim: the same seat's newcomer, else the nearest foe
    if t and (t.mon.hp <= 0 or t.fighter.b ~= t) then
      local now = t.fighter.b
      if now and now.mon.hp > 0 then
        t = now
      elseif t.side ~= user.side then
        t = self:_nearestFoe(user, t.slot)
      else
        t = self:foes(user)[1]
      end
    end
    -- Lightning Rod (doubles, no Follow Me): the earliest-moving foe with it.
    if t and self.double and int(row.type, -1) == Types.ID.ELECTRIC and t.ability ~= "LIGHTNING_ROD" then
      local best, bestN = nil, nil
      for _, o in ipairs(self:foes(user)) do
        if o ~= t and o.ability == "LIGHTNING_ROD" then
          local n = int(o.turnOrder, 99)
          if bestN == nil or n < bestN then best, bestN = o, n end
        end
      end
      if best then
        best.lightningRodRedirected = true
        return best
      end
    end
    return t
  end
  -- DEPENDS / BOTH / FOES_AND_ALLY / OPPONENTS_FIELD: the first standing foe.
  return self:foes(user)[1]
end

-- BattleSim2's stolen-KO rule: the nearest living foe to the emptied seat,
-- ties to the lower slot.
function Bm:_nearestFoe(user, slot)
  local best, bestD
  for _, o in ipairs(self:foes(user)) do
    local d = o.slot - slot
    if d < 0 then d = -d end
    if not bestD or d < bestD or (d == bestD and o.slot < best.slot) then best, bestD = o, d end
  end
  return best
end

-- ==================================================================
-- resolution
-- ==================================================================

-- pokefirered/src/battle_util.c:1253 AtkCanceller_UnableToUseMove.
-- Returns true (go on), false (stopped) or "bide" (Bide releases).
local function canceller(C)
  local B, user = C.B, C.user
  user.destinyBond = nil
  user.grudge = nil
  local nm = B:nameOf(user)

  if Status.normalise(user.mon.status) == "SLP" then
    if B:uproarActive() and user.ability ~= "SOUNDPROOF" then
      user.nightmare = nil
      B:cure(user, nm .. " woke up in the UPROAR!")
    else
      local turns = int(user.mon.sleepTurns, 0)
      if turns <= 0 then turns = Status.sleepTurns(B.rng) end
      local left, woke = Status.sleepTick(turns, user.ability == "EARLY_BIRD")
      user.mon.sleepTurns = left
      if not woke then
        if C.mnum ~= MOVE.SNORE and C.mnum ~= MOVE.SLEEP_TALK then
          B:say(nm .. " is fast asleep.")
          return false
        end
      else
        user.nightmare = nil
        B:cure(user, nm .. " woke up!")
      end
    end
  end

  if Status.normalise(user.mon.status) == "FRZ" then
    if B:roll(0, Status.THAW_ROLL_MAX) ~= 0 then
      if C.effect ~= E.THAW_HIT then
        B:say(nm .. " is frozen solid!")
        return false
      end
    else
      B:cure(user, nm .. " was defrosted!")
    end
  end

  if Abilities.truantLoafs(user) then
    B:cancelMultiTurn(user)
    B:emitAbility(user)
    B:say(nm .. " is loafing around!")
    user.unableToMove = true
    return false
  end

  if user.mustRecharge then
    user.mustRecharge, user.rechargeTurns = nil, nil
    B:cancelMultiTurn(user)
    B:say(nm .. " must recharge!")
    return false
  end

  if user.flinched then
    user.flinched = nil
    B:cancelMultiTurn(user)
    B:say(nm .. " flinched!")
    user.unableToMove = true
    return false
  end

  if user.disabledNum and C.mnum == user.disabledNum then
    B:cancelMultiTurn(user)
    B:say(nm .. "'s " .. C:moveName() .. " is disabled!")
    user.unableToMove = true
    return false
  end

  if int(user.tauntTurns, 0) > 0 and int(C.move.power, 0) == 0 then
    B:cancelMultiTurn(user)
    B:say(nm .. " can't use " .. C:moveName() .. " after the TAUNT!")
    user.unableToMove = true
    return false
  end

  if B:isImprisoned(user, C.mnum) then
    B:cancelMultiTurn(user)
    B:say(nm .. " can't use the sealed " .. C:moveName() .. "!")
    user.unableToMove = true
    return false
  end

  if int(user.confusion, 0) > 0 then
    user.confusion = user.confusion - 1
    if user.confusion > 0 then
      B:say(nm .. " is confused!")
      if B:roll(0, 1) == 0 then
        B:cancelMultiTurn(user)
        B:_selfHit(C)
        user.unableToMove = true
        return false
      end
    else
      user.confusion = nil
      B:emit("status", { slot = user.slot, side = user.side, confused = 0,
                         text = nm .. " snapped out of confusion!" })
      B:say(nm .. " snapped out of confusion!")
    end
  end

  if Status.normalise(user.mon.status) == "PAR" and B:roll(0, Status.PARALYSIS_ROLL_MAX) == 0 then
    B:say(nm .. " is paralyzed! It can't move!")
    user.unableToMove = true
    return false
  end

  if user.infatuatedWith then
    B:say(nm .. " is in love with " .. B:nameOf(user.infatuatedWith) .. "!")
    if B:roll(0, 1) == 0 then
      B:cancelMultiTurn(user)
      B:say(nm .. " is immobilized by love!")
      user.unableToMove = true
      return false
    end
  end

  if int(user.bideTurns, 0) > 0 then
    user.bideTurns = user.bideTurns - 1
    if user.bideTurns > 0 then
      B:say(nm .. " is storing energy!")
      return false
    end
    return "bide"
  end

  if Status.normalise(user.mon.status) == "FRZ" and C.effect == E.THAW_HIT then
    B:cure(user, nm .. " was defrosted by " .. C:moveName() .. "!")
  end
  return true
end
M.canceller = canceller

-- pokefirered/data/battle_scripts_1.s:3741 (confusion self-hit)
function Bm:_selfHit(C)
  local user = C.user
  local dmg = Damage.selfHitBase(user)
  local r = self:roll(Damage.ROLL_MIN, Damage.ROLL_MAX)
  dmg = floor(dmg * r / 100)
  if dmg == 0 then dmg = 1 end
  local banded = Items.rollFocusBand(self, user)
  local hung = nil
  if int(user.substituteHP, 0) <= 0 and (user.enduring or banded) and dmg >= user.mon.hp then
    dmg = user.mon.hp - 1
    hung = user.enduring and "endured" or "band"
  end
  user.focusBanded = nil
  self:say("It hurt itself in its confusion!")
  self:loseHp(user, dmg)
  if hung == "endured" then
    self:say(self:nameOf(user) .. " endured the hit!")
  elseif hung == "band" then
    Items.focusBandMessage(self, user)
  end
  C:tryFaintUser()
end

-- The per-strike move end, defined with the move end below (forward).
local strikeEnd

-- pret GET_MOVE_TYPE: the type the move has in battle.  Hidden Power's
-- `hiddenpowercalc` and Weather Ball's `setweatherballtype` run BEFORE
-- attackcanceler (battle_scripts_1.s BattleScript_EffectHiddenPower /
-- BattleScript_EffectWeatherBall), so the absorbing abilities, Levitate and
-- Hustle's accuracy all read this, not the row's Normal.
local function dynamicMoveType(C)
  local mt = int(C.move.type, 0)
  if C.effect == E.HIDDEN_POWER then
    local hpw = C.user.mon.hiddenPower
    if type(hpw) == "table" then mt = int(hpw.type, mt) end
  elseif C.effect == E.WEATHER_BALL then
    local w = C.B:weather()
    if w == "RAIN" then mt = Types.ID.WATER
    elseif w == "SAND" then mt = Types.ID.ROCK
    elseif w == "SUN" then mt = Types.ID.FIRE
    elseif w == "HAIL" then mt = Types.ID.ICE end
  end
  return mt
end
M.dynamicMoveType = dynamicMoveType

-- ------------------------------------------------------------------
-- the damaging path (effects/hit.lua)
-- ------------------------------------------------------------------

function Bm:_calcOpts(C, target, extra)
  local side = self.sides[target.side]
  local twoDef = self.double and self:countStandingOnSide(target.side) >= 2
  local o = {
    typeTable = self.typeTable, specialTypes = self.specialTypes, rng = self.rng,
    weather = self:weather(), dmgMultiplier = C.dmgMultiplier,
    reflect = int(side.reflectTurns, 0) > 0, lightScreen = int(side.lightScreenTurns, 0) > 0,
    doubleScreens = twoDef, spread = twoDef and int(C.move.target, 0) == T.BOTH,
    mudSport = self:fieldSport("mudSport"), waterSport = self:fieldSport("waterSport"),
    plusPartner = self:abilityOnField("PLUS"), minusPartner = self:abilityOnField("MINUS"),
    pursuitSwitch = C.opts.pursuit, defenderId = target.slot,
  }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

-- pokefirered/src/battle_script_commands.c:1744 (+ datahpupdate)
function Bm:_dealDamage(C, dmg, info)
  local user, target = C.user, C.target
  info = info or {}
  dmg = max(0, floor(dmg or 0))
  if int(target.substituteHP, 0) > 0 and not info.ignoreSub then
    local dealt = min(dmg, target.substituteHP)
    target.substituteHP = target.substituteHP - dealt
    self:_emit("damage", { slot = target.slot, side = target.side, amount = dealt, hp = target.mon.hp })
    self:say("The SUBSTITUTE took damage for " .. self:nameOf(target) .. "!")
    if target.substituteHP <= 0 then
      target.substituteHP = 0
      self:_emit("sub", { slot = target.slot, side = target.side, amount = 0 })
      self:say(self:nameOf(target) .. "'s SUBSTITUTE faded!")
    end
    C.hitSubstitute = true
    -- The strike landed on the doll: its STATUS2_SUBSTITUTE bit stays set until
    -- this strike's move end (MOVEEND_SUBSTITUTE), even when the doll just broke,
    -- so the strike's secondary and King's Rock are refused (SetMoveEffect).
    C.subStrike = true
    if int(C.firstDmg, 0) == 0 then C.firstDmg = dmg end
    C.hpDealt = dealt
    C.hitsLanded = int(C.hitsLanded, 0) + 1
    return dealt
  end
  local dealt = self:loseHp(target, dmg)
  if int(C.firstDmg, 0) == 0 then C.firstDmg = dealt end
  if dealt > 0 then C.targetDamaged = true end
  target.lastHitBy = user
  local physical = info.physical
  if physical == nil then physical = Types.isPhysical(C.moveType, self.specialTypes) end
  -- pokefirered/src/battle_script_commands.c:1824
  if physical then
    target.lastPhysDmg, target.lastPhysBy = dealt, user.slot
  else
    target.lastSpecDmg, target.lastSpecBy = dealt, user.slot
    C.specialHit = true
  end
  if int(target.bideTurns, 0) > 0 then
    target.bideDamage = int(target.bideDamage, 0) + dealt
    target.bideTarget = user
  end
  C.hpDealt = dealt
  C.hitsLanded = int(C.hitsLanded, 0) + 1
  return dealt
end

-- pokefirered/src/battle_script_commands.c:1577 (Endure / Focus Band hang on)
function Bm:_adjustDamage(C, target, dmg)
  local banded = Items.rollFocusBand(self, target)
  target.focusBanded = nil
  if int(target.substituteHP, 0) <= 0 and (target.enduring or banded) and dmg >= target.mon.hp then
    return max(0, target.mon.hp - 1), target.enduring and "endured" or "hung"
  end
  return dmg, nil
end

local function effectivenessLine(B, flags)
  if not flags then return end
  if flags.super then B:say("It's super effective!")
  elseif flags.notVery then B:say("It's not very effective...") end
end

function Bm:_applySetDamage(C, dmg, flags)
  local hung
  dmg, hung = self:_adjustDamage(C, C.target, dmg)
  C:attackAnimation()
  self:_dealDamage(C, dmg)
  if hung == "endured" then
    self:say(self:nameOf(C.target) .. " endured the hit!")
  elseif hung == "hung" then
    Items.focusBandMessage(self, C.target)
  elseif flags then
    effectivenessLine(self, flags)
  end
end

local function fail(C, text)
  C:attackString()
  C:ppReduce()
  C.failed = true
  C.missed = true
  C.B:say(text or "But it failed!")
end

local function preChecks(C)
  local B, user, target, eff = C.B, C.user, C.target, C.effect
  if eff == E.FAKE_OUT and int(user.isFirstTurn, 0) <= 0 then
    fail(C)
    return true
  end
  if eff == E.DREAM_EATER and (int(target.substituteHP, 0) > 0
      or Status.normalise(target.mon.status) ~= "SLP") then
    fail(C, B:nameOf(target) .. " wasn't affected!")
    return true
  end
  if eff == E.COUNTER or eff == E.MIRROR_COAT then
    -- pokefirered/src/battle_script_commands.c:7568: back at whoever hit it.
    local taken = (eff == E.COUNTER) and int(user.lastPhysDmg, 0) or int(user.lastSpecDmg, 0)
    local by = (eff == E.COUNTER) and user.lastPhysBy or user.lastSpecBy
    local foe = nil
    for _, o in ipairs(B:foes(user)) do
      if o.slot == by then foe = o end
    end
    if foe then
      local fm = followMe(B, user)
      if fm then foe = fm end
    end
    if taken <= 0 or not foe then
      fail(C)
      return true
    end
    C.target = foe
  end
  if eff == E.SNORE then
    if Status.normalise(user.mon.status) ~= "SLP" then
      fail(C)
      return true
    end
    if not (C.opts.calledBy and int(C.opts.calledBy.effect, -1) == E.SLEEP_TALK) then
      B:say(B:nameOf(user) .. " is fast asleep.")
    end
  end
  if eff == E.ENDEAVOR and target.mon.hp <= user.mon.hp then
    fail(C)
    return true
  end
  if eff == E.SPIT_UP and C:isProtected() then
    C:attackString()
    C:ppReduce()
    if int(user.stockpile, 0) <= 0 then
      B:say("But it failed to SPIT UP a thing!")
    else
      user.stockpile = 0
      B:say(B:nameOf(C.target) .. " protected itself!")
    end
    C.missed = true
    return true
  end
  if eff == E.EXPLOSION and not C.explosionStarted then
    for _, b in ipairs(B:active()) do
      if b.ability == "DAMP" then
        C.stopTargets = true
        C:attackString()
        C:ppReduce()
        B:emitAbility(b)
        B:say(B:nameOf(b) .. "'s DAMP prevents " .. B:nameOf(user) .. " from using " .. C:moveName() .. "!")
        C.failed = true
        return true
      end
    end
  end
  return false
end

local function setMultipliers(C)
  local target, eff = C.target, C.effect
  local semi = target and target.semi
  C.dmgMultiplier = 1
  if eff == E.GUST or eff == E.TWISTER then
    if semi == "ON_AIR" then C.ignoreOnAir = true; C.dmgMultiplier = 2 end
  elseif eff == E.EARTHQUAKE or eff == E.MAGNITUDE then
    if semi == "UNDERGROUND" then C.ignoreUnderground = true; C.dmgMultiplier = 2 end
  elseif (eff == E.HIT and C.mnum == MOVE.SURF) or (eff == E.TRAP and C.mnum == MOVE.WHIRLPOOL) then
    if semi == "UNDERWATER" then C.ignoreUnderwater = true; C.dmgMultiplier = 2 end
  elseif eff == E.FLINCH_MINIMIZE_HIT then
    if target.minimized then C.dmgMultiplier = 2 end
  elseif eff == E.THUNDER or eff == E.SKY_UPPERCUT then
    C.ignoreOnAir = true
  end
end

-- pokefirered/data/battle_scripts_1.s:848 (Jump Kick / Hi Jump Kick crash)
local function crashDamage(C)
  local B, user, target = C.B, C.user, C.target
  local _, flags = Types.typeCalc(B.typeTable, int(C.move.type, 0), target.type1, target.type2,
    nil, target.identified)
  if flags.immune and C.missReason ~= "protected" then return end
  B:say(B:nameOf(user) .. " kept going and crashed!")
  local dmg = Damage.calc(user, target, C.move, B:_calcOpts(C, target, { forceCrit = false }))
  dmg = floor(dmg / 2)
  if dmg == 0 then dmg = 1 end
  local cap = floor(target.mon.maxHp / 2)
  if cap < dmg then dmg = cap end
  B:loseHp(user, dmg)
  C:tryFaintUser()
end

local function onMiss(C)
  local B, user, eff = C.B, C.user, C.effect
  C.missed = true
  C.noEffect = true
  if eff == E.RECOIL_IF_MISS and C.missReason ~= "absorbed" then crashDamage(C) end
  if eff == E.RAGE then user.rage = nil end
  if eff == E.ROLLOUT then B:cancelMultiTurn(user) end
  if eff == E.FURY_CUTTER then user.furyCutter = 0 end
  if eff == E.SEMI_INVULNERABLE then user.semi = nil end
end

local function flagsImmune(C, info)
  local B, target = C.B, C.target
  local mt = int(info and info.moveType, C.moveType)
  if target.ability == "LEVITATE" and mt == Types.ID.GROUND then
    B:emitAbility(target)
    B:say(B:nameOf(target) .. " makes GROUND moves miss with LEVITATE!")
    return true
  end
  if info and info.effectiveness == 0 then
    B:say("It doesn't affect " .. B:nameOf(target) .. "...")
    return true
  end
  return false
end

-- pokefirered/src/battle_script_commands.c:1274 (Wonder Guard; not Struggle,
-- which returns before typecalc on the cart).  Also OHKO's typecalc.
local function wonderGuard(C, info)
  local B = C.B
  if C.target.ability ~= "WONDER_GUARD" then return false end
  if C.mnum == MOVE.STRUGGLE then return false end
  local f = info and info.typeFlags or {}
  if f.super and not f.notVery then return false end
  B:emitAbility(C.target)
  B:say(B:nameOf(C.target) .. " avoided damage with WONDER GUARD!")
  return true
end

-- pokefirered/data/battle_scripts_1.s:325 (Absorb / Mega Drain / Giga Drain / Dream Eater)
local function drain(C)
  local B, user, target = C.B, C.user, C.target
  if C.noEffect then return end
  local heal = floor(int(C.hpDealt, 0) / 2)
  if heal == 0 then heal = 1 end
  if C.effect == E.ABSORB and target.ability == "LIQUID_OOZE" then
    B:emitAbility(target)
    B:loseHp(user, heal)
    B:say(B:nameOf(user) .. " sucked up the liquid ooze!")
    C:tryFaintUser()
    return
  end
  B:heal(user, heal)
  if C.effect == E.DREAM_EATER then
    B:say(B:nameOf(target) .. "'s dream was eaten!")
  else
    B:say(B:nameOf(target) .. " had its energy drained!")
  end
end

-- pokefirered/src/battle_script_commands.c:8238
local function present(C)
  local B, target = C.B, C.target
  local r = B:roll(0, 255)
  if r < 102 then return 40 end
  if r < 178 then return 80 end
  if r < 204 then return 120 end
  if target.mon.hp >= target.mon.maxHp then
    B:say(B:nameOf(target) .. "'s HP is full!")
    return nil
  end
  C:attackAnimation()
  local heal = max(1, floor(target.mon.maxHp / 4))
  B:heal(target, heal)
  B:say(B:nameOf(target) .. " regained health!")
  return nil
end

-- pokefirered/src/battle_script_commands.c:8161
local function rolloutPower(C)
  local user = C.user
  if int(user.rolloutTimer, 0) <= 0 then
    user.rolloutTimer = 5
    user.lockedNum, user.lockedSlot = C.mnum, C.slot
    user.lockedTarget = C.target
  end
  user.rolloutTimer = user.rolloutTimer - 1
  if user.rolloutTimer == 0 then
    user.lockedNum, user.lockedSlot, user.lockedTarget = nil, nil, nil
  end
  local power = int(C.move.power, 30)
  for _ = 1, (5 - user.rolloutTimer) - 1 do power = power * 2 end
  if user.defenseCurl then power = power * 2 end
  return power
end

-- pokefirered/src/battle_script_commands.c:8205
local function furyCutterPower(C)
  local user = C.user
  local c = int(user.furyCutter, 0)
  if c ~= 5 then c = c + 1 end
  user.furyCutter = c
  local power = int(C.move.power, 10)
  for _ = 1, c - 1 do power = power * 2 end
  return power
end

local function hitOnce(C, opts)
  local B = C.B
  opts = opts or {}
  local dmg, info = Damage.calc(C.user, C.target, C.move, B:_calcOpts(C, C.target, opts.calc))
  C.moveType = int(info.moveType, C.moveType)
  if info.failed then
    C.failed = true
    B:say("But it failed!")
    return nil, info, "fail"
  end
  if flagsImmune(C, info) then
    C.noEffect = true
    C.missed = true
    return nil, info, "immune"
  end
  if wonderGuard(C, info) then
    C.noEffect = true
    C.missed = true
    return nil, info, "immune"
  end
  local hung
  dmg, hung = B:_adjustDamage(C, C.target, dmg)
  C:attackAnimation()
  if opts.onAfterAnim then opts.onAfterAnim() end
  B:_dealDamage(C, dmg, info)
  if info.critical then B:say("A critical hit!") end
  return dmg, info, hung or "ok"
end

-- pokefirered/src/battle_script_commands.c:6857 (2 and 3 at 3/8 each, 4 and 5 at 1/8)
local function multiHitCount(C)
  local r = C.B:roll(0, 3)
  if r > 1 then return C.B:roll(0, 3) + 2 end
  return r + 2
end

local function tripleKick(C)
  local B, user, target = C.B, C.user, C.target
  local power, landed, lastInfo = 0, 0, nil
  for i = 1, 3 do
    if user.mon.hp <= 0 or target.mon.hp <= 0 then break end
    if Status.normalise(user.mon.status) == "SLP"
        and not (C.opts.calledBy and int(C.opts.calledBy.effect, -1) == E.SLEEP_TALK) then break end
    if not C:accuracyCheck("normal", landed == 0) then
      if landed == 0 then onMiss(C) end
      break
    end
    power = power + 10
    local _, info, status = hitOnce(C, { calc = { power = power } })
    lastInfo = info
    if status ~= "ok" and status ~= "endured" and status ~= "hung" then break end
    landed = landed + 1
    if status == "hung" then Items.focusBandMessage(B, target) end
    -- battle_scripts_1.s:1414 moveendto MOVEEND_NEXT_TARGET, every kick (the
    -- endured one too: the FOE_ENDURED jump comes after it)
    strikeEnd(C)
    if status == "endured" then
      B:say(B:nameOf(target) .. " endured the hit!")
      break
    end
  end
  -- battle_scripts_1.s:1433: the kick loop ends with moveendfrom
  -- MOVEEND_UPDATE_LAST_MOVES only.
  C.endFrom = "last"
  if landed > 0 then
    effectivenessLine(B, lastInfo and lastInfo.typeFlags)
    B:say("Hit " .. landed .. " time(s)!")
    C:tryFaintTarget()
  end
end

-- pokefirered/src/battle_script_commands.c:8571: every healthy party member of
-- the user's seat, by the sheet's base Attack against the target's base Defense.
local function beatUp(C)
  local B, user, target = C.B, C.user, C.target
  if not C:accuracyCheck("normal", true) then
    onMiss(C)
    return
  end
  local any = false
  local dBase = target.mon.beatUp or {}
  for i, mon in ipairs(user.fighter.mons) do
    if target.mon.hp <= 0 then break end
    local hp, status = mon.hp, mon.status
    if i == user.partyIndex then hp, status = user.mon.hp, user.mon.status end
    if hp > 0 and not Status.normalise(status) then
      any = true
      local aBase = mon.beatUp or {}
      local atk = max(1, int(aBase.atk, 50))
      local def = max(1, int(dBase.def, 50))
      local lvl = int(mon.level, 1)
      local dmg = atk * int(C.move.power, 10) * (floor(lvl * 2 / 5) + 2)
      dmg = floor(dmg / def)
      dmg = floor(dmg / 50) + 2
      -- pokefirered/src/battle_script_commands.c:8606
      if user.helpingHand then dmg = floor(dmg * 15 / 10) end
      B:say(mon.species .. "'s attack!")
      -- pokefirered/data/battle_scripts_1.s:1947: a critcalc per member, and
      -- Cmd_critcalc (battle_script_commands.c:1196) skips the roll entirely
      -- against Battle Armor / Shell Armor, as Damage.calc does.
      local crit = false
      if target.ability ~= "BATTLE_ARMOR" and target.ability ~= "SHELL_ARMOR" then
        local stage = Crit.stage(user, C.move)
        crit = Crit.check(stage, B:roll(0, Crit.chance(stage) - 1))
      end
      if crit then dmg = dmg * 2 end
      local r = B:roll(Damage.ROLL_MIN, Damage.ROLL_MAX)
      dmg = floor(dmg * r / 100)
      if dmg == 0 then dmg = 1 end
      local hung
      dmg, hung = B:_adjustDamage(C, target, dmg)
      C:attackAnimation()
      B:_dealDamage(C, dmg, { physical = false })
      if crit then B:say("A critical hit!") end
      if hung == "endured" then B:say(B:nameOf(target) .. " endured the hit!")
      elseif hung == "hung" then Items.focusBandMessage(B, target) end
      C:tryFaintTarget()
      -- battle_scripts_1.s:1964 moveendto MOVEEND_NEXT_TARGET per member; the
      -- loop's own end (BattleScript_BeatUpEnd) runs no move end after it.
      strikeEnd(C)
      C.endFrom = "last"
    end
  end
  if not any then
    C.failed = true
    B:say("But it failed!")
  end
end

-- pokefirered/data/battle_scripts_1.s:376 (Selfdestruct / Explosion)
local function explosion(C)
  local B, user = C.B, C.user
  C:attackString()
  C:ppReduce()
  C.explosionStarted = true
  local hpBefore = user.mon.hp
  if hpBefore > 0 then B:loseHp(user, hpBefore) end
  local dmg, info = Damage.calc(user, C.target, C.move, B:_calcOpts(C, C.target))
  if not C:accuracyCheck("normal", true) then
    C.missed = true
    C.noEffect = true
    if not C.deferUserFaint then C:tryFaintUser() end
    return
  end
  if flagsImmune(C, info) then
    C.noEffect = true
    if not C.deferUserFaint then C:tryFaintUser() end
    return
  end
  local target = C.target
  local hung
  dmg, hung = B:_adjustDamage(C, target, dmg)
  C:attackAnimation()
  B:_dealDamage(C, dmg, info)
  if info.critical then B:say("A critical hit!") end
  if hung == "endured" then B:say(B:nameOf(target) .. " endured the hit!")
  elseif hung == "hung" then Items.focusBandMessage(B, target)
  else effectivenessLine(B, info.typeFlags) end
  C:tryFaintTarget()
  if not C.deferUserFaint then C:tryFaintUser() end
end

-- effects/hit.lua Hit.run
function M.hit(C)
  local B, user, eff = C.B, C.user, C.effect
  C.moveType = dynamicMoveType(C)

  if preChecks(C) then return end
  setMultipliers(C)

  if (eff == E.RAMPAGE and int(user.rampageTurns, 0) > 0)
      or (eff == E.UPROAR and int(user.uproarTurns, 0) > 0)
      or (eff == E.ROLLOUT and int(user.rolloutTimer, 0) > 0) then
    C.noPP = true
  end
  if eff == E.RAMPAGE and int(user.rampageTurns, 0) <= 0 then C.startRampage = true end

  if eff == E.EXPLOSION then return explosion(C) end

  C:attackString()
  C:ppReduce()

  local magnitude = C.magnitude
  if eff == E.MAGNITUDE and not magnitude then
    local value, power = Damage.magnitude(B:roll(0, 99))
    magnitude = { power = power, value = value }
    C.magnitude = magnitude
    B:say("MAGNITUDE " .. value .. "!")
  end

  if eff == E.TRIPLE_KICK then return tripleKick(C) end
  if eff == E.BEAT_UP then return beatUp(C) end

  -- Pursuit on a switching target (battle_scripts_1.s:3081
  -- BattleScript_PursuitDmgOnSwitchOut) draws no accuracy: attackstring,
  -- ppreduce, then straight to critcalc / damagecalc.
  if not C.opts.pursuit and not C:accuracyCheck("normal", true) then
    onMiss(C)
    return
  end

  if eff == E.SEMI_INVULNERABLE then user.semi = nil end
  if eff == E.RAGE then user.rage = true end

  local target = C.target
  local calcExtra = {}
  if magnitude then calcExtra.power = magnitude.power end

  if eff == E.ROLLOUT then
    local _, f = Types.typeCalc(B.typeTable, int(C.move.type, 0), target.type1, target.type2,
      nil, target.identified)
    if f.immune then
      B:cancelMultiTurn(user)
      B:say("It doesn't affect " .. B:nameOf(target) .. "...")
      C.noEffect = true
      return
    end
    calcExtra.power = rolloutPower(C)
  elseif eff == E.FURY_CUTTER then
    calcExtra.power = furyCutterPower(C)
  elseif eff == E.PRESENT then
    local p = present(C)
    if not p then return end
    calcExtra.power = p
  elseif eff == E.SPIT_UP then
    -- pokefirered/src/battle_script_commands.c:6586
    local n = int(user.stockpile, 0)
    if n <= 0 then
      B:say("But it failed to SPIT UP a thing!")
      C.failed = true
      return
    end
    user.stockpile = 0
    local o = B:_calcOpts(C, target)
    local base = Damage.base(user, target, C.move, {
      weather = o.weather, reflect = o.reflect, lightScreen = o.lightScreen,
      doubleScreens = o.doubleScreens, specialTypes = B.specialTypes,
      mudSport = o.mudSport, waterSport = o.waterSport,
      plusPartner = o.plusPartner, minusPartner = o.minusPartner,
    }) * n
    -- pokefirered/src/battle_script_commands.c:6603
    if user.helpingHand then base = floor(base * 15 / 10) end
    if isType(user, int(C.move.type, 0)) then base = floor(base * 15 / 10) end
    local dmg, flags = Types.typeCalc(B.typeTable, int(C.move.type, 0), target.type1, target.type2,
      base, target.identified)
    if flags.immune then
      B:say("It doesn't affect " .. B:nameOf(target) .. "...")
      C.noEffect = true
      return
    end
    B:_applySetDamage(C, dmg, flags)
    C:tryFaintTarget()
    return
  elseif eff == E.BRICK_BREAK then
    local side = B.sides[target.side]
    if int(side.reflectTurns, 0) > 0 or int(side.lightScreenTurns, 0) > 0 then
      side.reflectTurns, side.lightScreenTurns = 0, 0
      C.brokeWall = true
    end
  end

  local fixed = eff == E.DRAGON_RAGE or eff == E.SONICBOOM or eff == E.LEVEL_DAMAGE
    or eff == E.SUPER_FANG or eff == E.PSYWAVE or eff == E.ENDEAVOR
  local setDmg = fixed or eff == E.COUNTER or eff == E.MIRROR_COAT

  local nHits, isMulti = 1, false
  if eff == E.MULTI_HIT then nHits = multiHitCount(C); isMulti = true
  elseif eff == E.DOUBLE_HIT or eff == E.TWINEEDLE then nHits = 2; isMulti = true end

  local landed, lastInfo, lastStatus = 0, nil, nil
  for i = 1, nHits do
    if user.mon.hp <= 0 or target.mon.hp <= 0 then break end
    if isMulti and i > 1 and Status.normalise(user.mon.status) == "SLP"
        and not (C.opts.calledBy and int(C.opts.calledBy.effect, -1) == E.SLEEP_TALK) then break end
    local _, info, status = hitOnce(C, {
      calc = calcExtra,
      onAfterAnim = (i == 1 and C.brokeWall) and function() B:say("It shattered the barrier!") end or nil,
    })
    lastInfo, lastStatus = info, status
    if status ~= "ok" and status ~= "endured" and status ~= "hung" then break end
    landed = landed + 1
    if status == "endured" then
      -- battle_scripts_1.s:638: a multi-hit strike's move end runs before the
      -- FOE_ENDURED jump; a single hit prints it straight away.
      if isMulti then strikeEnd(C) end
      B:say(B:nameOf(target) .. " endured the hit!")
      break
    end
    if status == "hung" then
      Items.focusBandMessage(B, target)
    elseif not isMulti then
      local f = info.typeFlags
      if setDmg and not (eff == E.COUNTER or eff == E.MIRROR_COAT) then f = nil end
      effectivenessLine(B, f)
    end
    -- battle_scripts_1.s:638 moveendto MOVEEND_NEXT_TARGET after every strike:
    -- Rage, contact abilities, the item checks, King's Rock / Shell Bell and
    -- the Substitute update run per strike; the loop's end (:654) runs the
    -- move end again from MOVEEND_SYNCHRONIZE_TARGET, skipping on-damage ones.
    if isMulti then strikeEnd(C) end
  end
  if isMulti and landed > 0 then C.endFrom = "sync" end
  if isMulti and landed > 0 then
    if lastStatus ~= "endured" and lastStatus ~= "hung" then
      effectivenessLine(B, lastInfo and lastInfo.typeFlags)
    end
    B:say("Hit " .. landed .. " time(s)!")
  end
  if landed == 0 then
    C.noEffect = true
    if eff == E.ROLLOUT then B:cancelMultiTurn(user) end
    return
  end

  if eff == E.ABSORB or eff == E.DREAM_EATER then drain(C) end
  Effects.secondaryAfter(C)
  C:tryFaintTarget()
  if C.checkUserFaint then C:tryFaintUser() end
end

-- ------------------------------------------------------------------
-- the special shapes (engine.lua)
-- ------------------------------------------------------------------

-- pokefirered/data/battle_scripts_1.s:3251
local function bideAttack(C)
  local B, user = C.B, C.user
  local stored = int(user.bideDamage, 0)
  local src = user.bideTarget
  user.bideDamage, user.bideTarget, user.bideTurns = nil, nil, nil
  user.lockedNum, user.lockedSlot, user.lockedTarget = nil, nil, nil
  B:say(B:nameOf(user) .. " unleashed energy!")
  if stored <= 0 then
    C.failed = true
    B:say("But it failed!")
    return
  end
  if src and src.mon.hp > 0 and src.fighter.b == src then
    C.target = src
  elseif src and src.fighter.b and src.fighter.b.mon.hp > 0 then
    C.target = src.fighter.b
  else
    C.target = B:foes(user)[1]
  end
  if not C.target then
    B:say("But it failed!")
    return
  end
  local target = C.target
  if not C:accuracyCheck("normal", true) then return end
  local _, flags = Types.typeCalc(B.typeTable, int(C.move.type, 0), target.type1, target.type2,
    nil, target.identified)
  if flags.immune then
    B:say("It doesn't affect " .. B:nameOf(target) .. "...")
    return
  end
  B:_applySetDamage(C, stored * 2)
  C:tryFaintTarget()
end

-- pokefirered/data/battle_scripts_1.s:794 (the first turn of a two-turn move)
local function chargeTurn(C)
  local B, user, eff = C.B, C.user, C.effect
  local isCharge = CHARGE_TEXT[eff] or eff == E.SEMI_INVULNERABLE
  if not isCharge then return false end
  if user.twoTurnNum ~= nil and user.twoTurnNum == C.mnum then
    user.twoTurnNum, user.twoTurnTarget = nil, nil
    user.lockedNum, user.lockedSlot, user.lockedTarget = nil, nil, nil
    C.noPP = true
    C.secondTurn = true
    if C.mnum == MOVE.SKY_ATTACK then C.extraEffect = { eff = "FLINCH" } end
    if C.mnum == MOVE.BOUNCE then C.extraEffect = { eff = "PARALYSIS" } end
    return false
  end
  if eff == E.SOLAR_BEAM and B:weather() == "SUN" then
    C:ppReduce()
    C.noPP = true
    return false
  end
  C:ppReduce()
  C:attackAnimation(1)
  user.twoTurnNum = C.mnum
  user.twoTurnTarget = C.target
  user.lockedNum, user.lockedSlot, user.lockedTarget = C.mnum, C.slot, C.target
  if eff == E.SEMI_INVULNERABLE then
    local row = SEMI_TEXT[C.mnum] or { " vanished!", "ON_AIR" }
    B:say(B:nameOf(user) .. row[1])
    user.semi = row[2]
  else
    B:say(B:nameOf(user) .. CHARGE_TEXT[eff])
    if eff == E.SKULL_BASH then
      Effects.changeStat(B, user, "def", 1, { user = true, allowPtr = true, noMsg = user.stages.def >= 6 })
    end
  end
  return true
end

-- pokefirered/data/battle_scripts_1.s:761 (+ Cmd_tryKO battle_script_commands.c:7104)
local function ohko(C)
  local B, user, target = C.B, C.user, C.target
  C:attackString()
  C:ppReduce()
  if not C:accuracyCheck("lockon", true) then
    C.missed = true
    return
  end
  local _, flags = Types.typeCalc(B.typeTable, int(C.move.type, 0), target.type1, target.type2,
    nil, target.identified)
  if flags.immune or (target.ability == "LEVITATE" and int(C.move.type, 0) == Types.ID.GROUND) then
    C.missed = true
    B:say("It doesn't affect " .. B:nameOf(target) .. "...")
    return
  end
  -- Cmd_typecalc (battle_scripts_1.s:766 runs it before tryKO) also applies
  -- Wonder Guard to a move with power: an OHKO move that is not super
  -- effective misses Shedinja.
  if int(C.move.power, 0) ~= 0 and wonderGuard(C, { typeFlags = flags }) then
    C.missed = true
    return
  end
  local banded = Items.rollFocusBand(B, target)
  target.focusBanded = nil
  if target.ability == "STURDY" then
    C.missed = true
    B:emitAbility(target)
    B:say(B:nameOf(target) .. " was protected by STURDY!")
    return
  end
  local uLvl, tLvl = int(user.mon.level, 1), int(target.mon.level, 1)
  local hit
  if C:lockOnActive() and uLvl >= tLvl then
    hit = true
  else
    local chance = int(C.move.accuracy, 30) + (uLvl - tLvl)
    hit = B:roll(1, 100) < chance and uLvl >= tLvl
  end
  if not hit then
    C.missed = true
    if uLvl >= tLvl then
      B:say(B:nameOf(user) .. "'s attack missed!")
    else
      B:say(B:nameOf(target) .. " is unaffected!")
    end
    return
  end
  local hpBefore = target.mon.hp
  local dmg = hpBefore
  local endured = target.enduring and true or false
  local hung = not endured and banded
  if endured or hung then dmg = max(0, hpBefore - 1) end
  C:attackAnimation()
  B:_dealDamage(C, dmg, { physical = Types.isPhysical(int(C.move.type, 0), B.specialTypes) })
  if endured then
    B:say(B:nameOf(target) .. " endured the hit!")
  elseif hung then
    Items.focusBandMessage(B, target)
  else
    B:say("It's a one-hit KO!")
  end
  C:tryFaintTarget()
end

-- pokefirered/src/battle_script_commands.c:866 (Magic Coat, then Snatch)
local function tryBounce(C)
  local B, user, target = C.B, C.user, C.target
  if C.opts.bounced then return false end
  if target and target ~= user and target.magicCoat and hasFlag(C.move, F.MAGIC_COAT) then
    target.magicCoat = nil
    C:attackString()
    C:ppReduce()
    B:say(B:nameOf(user) .. "'s " .. C:moveName() .. " was bounced back by MAGIC COAT!")
    C.user, C.target = target, user
    C.slot, C.chosenSlot = nil, nil
    C.noPP = true
    C.opts.bounced = true
    return true
  end
  if hasFlag(C.move, F.SNATCH) then
    for _, f in ipairs(B.turnOrderFighters or {}) do
      local b = f.b
      if b and b ~= user and b.snatch and b.mon.hp > 0 then
        b.snatch = nil
        C:attackString()
        C:ppReduce()
        B:say(B:nameOf(b) .. " snatched " .. B:nameOf(user) .. "'s move!")
        C.user, C.target = b, user
        C.slot, C.chosenSlot = nil, nil
        C.noPP = true
        C.opts.bounced = true
        return true
      end
    end
  end
  return false
end

-- pokefirered/src/battle_script_commands.c:888
local function lightningRodTook(C)
  local t = C.target
  if not (t and t.lightningRodRedirected) then return false end
  t.lightningRodRedirected = nil
  C:attackString()
  C.B:emitAbility(t)
  C.B:say(C.B:nameOf(t) .. "'s LIGHTNINGROD took the attack!")
  return true
end

-- pokefirered/src/battle_util.c:1891 (attackcanceler's ABILITYEFFECT_ABSORBING,
-- which the cart runs BEFORE the accuracy check)
local function absorbCheck(C)
  local B, user, target = C.B, C.user, C.target
  if not target or target == user then return false end
  local mt = C.moveType
  local power = int(C.move.power, 0)
  if not ((target.ability == "VOLT_ABSORB" and mt == Types.ID.ELECTRIC and power ~= 0)
      or (target.ability == "WATER_ABSORB" and mt == Types.ID.WATER and power ~= 0)
      or (target.ability == "FLASH_FIRE" and mt == Types.ID.FIRE
          and Status.normalise(target.mon.status) ~= "FRZ")) then
    return false
  end
  C:attackString()
  C:ppReduce()
  Abilities.absorb(B, user, target, mt, power, C:moveName())
  C.absorbed = true
  C.noEffect = true
  C.missed = true
  C.missReason = "absorbed"
  return true
end

-- ------------------------------------------------------------------
-- move end (pokefirered/src/battle_script_commands.c:4056 / :4121)
-- ------------------------------------------------------------------

-- MOVEEND_SYNCHRONIZE_TARGET .. MOVEEND_KINGSROCK_SHELLBELL.  `skipOnDamage`
-- is the multi-hit loop's closing pass (moveendcase SYNCHRONIZE_TARGET, then
-- moveendfrom IMMUNITY_ABILITIES), whose strikes already ran the contact
-- abilities one by one.
local function moveEndEffects(C, skipOnDamage)
  local B, user, target = C.B, C.user, C.target
  if target and target ~= user then Abilities.synchronize(B, C, target, user) end
  if not skipOnDamage then Abilities.onDamage(B, C) end
  Abilities.immunityCure(B)
  if target and target ~= user then Abilities.synchronize(B, C, user, target) end
  local chosen = C.opts.calledBy or C.move
  local chosenNum = int(chosen.num, 0)
  if Items.has(user, Items.HOLD.CHOICE_BAND) and chosenNum ~= MOVE.STRUGGLE and not user.choicedMove then
    if not (int(chosen.effect, -1) == E.BATON_PASS and not C.failed) then
      user.choicedMove = chosenNum
    end
  end
  if user.choicedMove and not B:slotOfNum(user, user.choicedMove) then user.choicedMove = nil end
  Items.moveEnd(B)
  -- pokefirered/src/battle_util.c:2995 ITEMEFFECT_KINGSROCK_SHELLBELL
  if target and int(C.firstDmg, 0) ~= 0 then
    local he, param = Items.of(user)
    if he == Items.HOLD.FLINCH then
      -- The cart reads the flinch chance off battler 0's item (the call passes
      -- battler 0), kept as the quirk it is: field slot 0's active mon.
      local first = B.order[1] and B.order[1].b
      local _, p0 = Items.of(first)
      if not C.noEffect and C.targetDamaged and target.mon.hp > 0 then
        if B:roll(0, 99) < p0 and hasFlag(C.move, F.KINGS_ROCK) then
          Effects.set(C, "FLINCH", false, false, false)
        end
      end
    elseif he == Items.HOLD.SHELL_BELL then
      if not C.noEffect and user ~= target and user.mon.hp ~= user.mon.maxHp and user.mon.hp > 0 then
        local amt = floor(C.firstDmg / max(1, param))
        if amt == 0 then amt = 1 end
        C.firstDmg = 0
        local lbl = B:itemLabel(user)
        Items.heldEvent(B, user, int(user.mon.heldItem, 0), lbl)
        B:say(B:nameOf(user) .. "'s " .. lbl .. " restored its HP a little!")
        B:heal(user, amt)
      end
    end
  end
end

-- MOVEEND_RAGE (TARGET_TURN_DAMAGED: a hit on the doll builds nothing) and
-- MOVEEND_DEFROST.
local function rageAndDefrost(C)
  local B, user, target = C.B, C.user, C.target
  if target and target ~= user and target.rage and target.mon.hp > 0 and user.side ~= target.side
      and not C.noEffect and C.targetDamaged and int(C.move.power, 0) > 0
      and target.stages.atk < 6 then
    target.stages.atk = target.stages.atk + 1
    local text = B:nameOf(target) .. "'s RAGE is building!"
    B:emit("stat", { slot = target.slot, side = target.side, stat = "atk",
                     stage = target.stages.atk, delta = 1, text = text })
    B:say(text)
  end
  if target and target ~= user and Status.normalise(target.mon.status) == "FRZ" and target.mon.hp > 0
      and C.specialHit and not C.noEffect and C.moveType == Types.ID.FIRE then
    B:cure(target, B:nameOf(target) .. " was defrosted!")
  end
end

-- One strike's move end (pret `moveendto MOVEEND_NEXT_TARGET` inside the
-- multi-hit, Triple Kick and Beat Up loops): Rage, defrost, the contact
-- abilities, the item checks, King's Rock / Shell Bell, then MOVEEND_SUBSTITUTE
-- drops the strike's doll bit.  The last-move bookkeeping is left to the move's
-- closing pass (the same values either way).
strikeEnd = function(C)
  rageAndDefrost(C)
  moveEndEffects(C, false)
  C.subStrike = nil
end

-- The move's closing move end.  `C.endFrom` says where the move's own script
-- resumes it: nil = moveendall, "sync" = the multi-hit close (no Rage / defrost
-- / on-damage), "last" = Triple Kick / Beat Up (MOVEEND_UPDATE_LAST_MOVES on).
local function moveEnd(C)
  local B, user, target = C.B, C.user, C.target
  if C.endFrom == nil then rageAndDefrost(C) end
  if C.endFrom ~= "last" then moveEndEffects(C, C.endFrom == "sync") end
  C.subStrike = nil
  local chosen = C.opts.calledBy or C.move
  local chosenNum = int(chosen.num, 0)
  if int(chosen.effect, -1) ~= E.BATON_PASS then
    user.lastMoveNum = chosenNum
    user.lastResultingNum = C.mnum
  end
  if C.printedUsed then user.lastPrinted = chosenNum end
  if target and target ~= user and not C.noEffect and not C.missed
      and hasFlag(chosen, F.MIRROR_MOVE) and target.mon.hp > 0 then
    target.lastTakenMove = chosenNum
  end
  if target and target ~= user and not C.noEffect and not C.missed and int(C.hitsLanded, 0) > 0 then
    target.lastLandedMove = C.mnum
    target.lastHitByType = C.moveType
  end
end

local function moveEndLite(C)
  Abilities.immunityCure(C.B)
  Items.moveEnd(C.B)
end

-- ------------------------------------------------------------------
-- calling moves (engine.lua call_moves / run_called)
-- ------------------------------------------------------------------

-- How deep one action may nest called moves.  The deepest chain a cart can
-- build is three calls (Metronome -> Assist -> Nature Power -> the terrain
-- move: Metronome may pick Assist, Assist may pick Nature Power); a sheet or
-- pool row that calls itself (Swift carrying EFFECT_NATURE_POWER, a
-- "Sleep Talk" numbered like Pound) would otherwise recurse until the stack
-- overflows and wedge the fight in `resolving`.  Past the cap the call says
-- "But it failed!".
M.MAX_CALL_DEPTH = 3

-- opts: noPP (Sleep Talk's HITMARKER_NO_PPDEDUCT for the called slot).
local function runCalled(C, row, slot, extra)
  local B = C.B
  local depth = int(C.opts.callDepth, 0) + 1
  if not row or depth > M.MAX_CALL_DEPTH then
    C.failed = true
    B:say("But it failed!")
    return
  end
  local target = B:_pickTarget(C.user, row, nil, true, true)
  local opts = {
    called = true, calledBy = C.opts.calledBy or C.move, pursuit = C.opts.pursuit,
    callDepth = depth, chosenSlot = C.chosenSlot, noPP = extra and extra.noPP or nil,
  }
  return B:_resolveMove(C.user, target, row, slot, opts)
end

-- pokefirered/src/battle_script_commands.c:7834 IsInvalidForSleepTalkOrAssist,
-- by number as on the cart -- and by effect, so a row that carries one of the
-- four calling effects under another number is refused the same way.
local CALLER_EFFECT = {
  [E.SLEEP_TALK] = true, [E.ASSIST] = true, [E.MIRROR_MOVE] = true, [E.METRONOME] = true,
}
local function invalidSleepTalk(num, effect)
  return num == nil or num == 0 or num == MOVE.SLEEP_TALK or num == MOVE.ASSIST
    or num == MOVE.MIRROR_MOVE or num == MOVE.METRONOME or CALLER_EFFECT[int(effect, -1)] == true
end

-- pokefirered/src/battle_script_commands.c:7519: roll 1..511 until a legal pool
-- move; after 64 misses, one pick over the legal list.
local function pickMetronome(B)
  if not B.pool then return nil end
  for _ = 1, 64 do
    local m = B:roll(1, 511)
    if m < 355 and not Effects.forbidden(m, false) and B.pool[m] then return B.pool[m] end
  end
  local list = {}
  for num = 1, 354 do
    if B.pool[num] and not Effects.forbidden(num, false) then list[#list + 1] = num end
  end
  if #list == 0 then return nil end
  return B.pool[list[B:roll(1, #list)]]
end

local function callMoves(C)
  local B, user, eff = C.B, C.user, C.effect
  if eff == E.METRONOME then
    C:attackString()
    C:ppReduce()
    local row = pickMetronome(B)
    if not row then
      C.failed = true
      B:say("But it failed!")
      return
    end
    C:attackAnimation()
    return runCalled(C, row)
  elseif eff == E.SLEEP_TALK then
    -- pokefirered/data/battle_scripts_1.s:1307
    if Status.normalise(user.mon.status) ~= "SLP" then
      C:attackString()
      C:ppReduce()
      C.failed = true
      B:say("But it failed!")
      return
    end
    B:say(B:nameOf(user) .. " is fast asleep.")
    C:attackString()
    C:ppReduce()
    -- pokefirered/src/battle_script_commands.c:7866 Cmd_trychoosesleeptalkmove:
    -- the four callers, Focus Punch, Uproar and the two-turn moves, then
    -- CheckMoveLimitations with every limit but PP (Disable, Torment, Taunt,
    -- Imprison, Encore, Choice Band).
    local bad = B:moveLimitations(user, true)
    local valid = {}
    for i = 1, #user.moves do
      local mv = user.moves[i]
      local n = int(mv.num, 0)
      if not bad[i] and not invalidSleepTalk(n, mv.effect) and n ~= MOVE.FOCUS_PUNCH
          and n ~= MOVE.UPROAR and not TWO_TURN[int(mv.effect, -1)] then
        valid[#valid + 1] = { row = mv, slot = i }
      end
    end
    if #valid == 0 then
      C.failed = true
      B:say("But it failed!")
      return
    end
    local pick = valid[B:roll(1, #valid)]
    C:attackAnimation()
    -- gCurrMovePos = the picked slot (Mimic / Sketch write there), with
    -- HITMARKER_NO_PPDEDUCT: the called move spends no PP of its own.
    return runCalled(C, pick.row, pick.slot, { noPP = true })
  elseif eff == E.MIRROR_MOVE then
    -- pokefirered/src/battle_script_commands.c:6350
    C:attackString()
    local num = user.lastTakenMove
    if num and num ~= 0 then
      C:ppReduce()
      return runCalled(C, B:calledRowByNum(num, user))
    end
    C:ppReduce()
    C.failed = true
    B:say("The MIRROR MOVE failed!")
    return
  elseif eff == E.ASSIST then
    -- pokefirered/src/battle_script_commands.c:9091
    C:attackString()
    local list = {}
    for i, mon in ipairs(user.fighter.mons) do
      if i ~= user.partyIndex then
        for j = 1, #(mon.moves or {}) do
          local n = int(mon.moves[j].num, 0)
          if n ~= 0 and not invalidSleepTalk(n, mon.moves[j].effect) and not Effects.forbidden(n, false) then
            list[#list + 1] = mon.moves[j]
          end
        end
      end
    end
    C:ppReduce()
    if #list == 0 then
      C.failed = true
      B:say("But it failed!")
      return
    end
    C:attackAnimation()
    return runCalled(C, list[B:roll(1, #list)])
  elseif eff == E.NATURE_POWER then
    -- pokefirered/src/battle_script_commands.c:8718
    C:attackString()
    local num = Field.NATURE_POWER_MOVE[B.terrain] or 129
    local row = B:calledRowByNum(num, user)
    if not row then
      C:ppReduce()
      C.failed = true
      B:say("But it failed!")
      return
    end
    B:say("NATURE POWER turned into " .. B:moveLabel(row) .. "!")
    return runCalled(C, row, C.slot)
  end
end

-- ------------------------------------------------------------------
-- targets (pokefirered/src/battle_script_commands.c:4308 + :8532)
-- ------------------------------------------------------------------

local function resetTargetValues(C)
  C.noEffect, C.missReason, C.failed, C.hitSubstitute = nil, nil, nil, nil
  C.hpDealt, C.firstDmg, C.hitsLanded, C.targetDamaged, C.specialHit = nil, nil, nil, nil, nil
  C.dmgMultiplier = 1
  C.ignoreOnAir, C.ignoreUnderground, C.ignoreUnderwater = nil, nil, nil
  C.brokeWall = nil
  C.missed = false
  C.absorbed = nil
  C.endFrom, C.subStrike = nil, nil
end

local function forEachTarget(C, body)
  local B = C.B
  local ttype = int(C.move.target, 0)
  if not B.double then return body(C) end
  if ttype == T.FOES_AND_ALLY then
    local list = {}
    for _, b in ipairs(B:active()) do
      if b ~= C.user then list[#list + 1] = b end
    end
    if #list == 0 then return body(C) end
    C.spread = #list > 1
    C.deferUserFaint = (C.effect == E.EXPLOSION)
    local anyLanded = false
    for i, b in ipairs(list) do
      if i > 1 then resetTargetValues(C) end
      C.target = b
      b.statLoweredMsg = nil
      if b.mon.hp > 0 then
        body(C)
        if not C.missed then anyLanded = true end
      end
      if C.stopTargets then break end
    end
    C.missed = not anyLanded
    if C.deferUserFaint then
      C.deferUserFaint = nil
      C:tryFaintUser()
    end
    return
  end
  if ttype == T.BOTH then
    local foes = B:foes(C.user)
    C.spread = #foes > 1
    local first = C.target
    body(C)
    local firstMissed = C.missed
    if C.stopTargets then return end
    for _, b in ipairs(foes) do
      if b ~= first and b.mon.hp > 0 then
        resetTargetValues(C)
        C.target = b
        b.statLoweredMsg = nil
        body(C)
        firstMissed = firstMissed and C.missed
      end
    end
    C.missed = firstMissed
    return
  end
  return body(C)
end

-- ------------------------------------------------------------------
-- run (engine.lua run) and resolveMove
-- ------------------------------------------------------------------

-- pokefirered/src/battle_util.c:1874 ABILITYEFFECT_MOVES_BLOCK, which
-- Cmd_attackcanceler runs for every target pass of a move (a spread move's
-- second foe, a called move) -- BattleScript_SoundproofProtected, then the move
-- end.  True when Soundproof stopped the move at this target.
local function soundproofBlocked(C)
  local B, user, target = C.B, C.user, C.target
  C.soundproofSeen = target
  if not Abilities.soundproofBlocks(target ~= user and target or nil, C.mnum) then return false end
  if user.lockedNum then C.noPP = true end
  C:attackString()
  C:ppReduce()
  B:emitAbility(target)
  B:say(B:nameOf(target) .. "'s SOUNDPROOF blocks " .. C:moveName() .. "!")
  C.missed = true
  C.noEffect = true
  moveEnd(C)
  return true
end

local function body(C)
  local B, user = C.B, C.user
  -- Pursuit on a switching target skips attackcanceler whole (no Soundproof,
  -- Magic Coat, Snatch, Lightning Rod or absorbing ability): battle_scripts_1.s
  -- :3081 BattleScript_PursuitDmgOnSwitchOut.
  if not C.opts.pursuit then
    if C.soundproofSeen ~= C.target and soundproofBlocked(C) then return end
    tryBounce(C)
    lightningRodTook(C)
    -- The owner of the move context may have changed hands (Snatch / Magic Coat).
    user = C.user
    C.moveType = dynamicMoveType(C)
    if absorbCheck(C) then
      moveEnd(C)
      return
    end
  end
  local eff = C.effect
  if eff == E.OHKO then
    ohko(C)
    moveEnd(C)
    return
  end
  if eff == E.BIDE then
    -- pokefirered/data/battle_scripts_1.s:575
    C:attackString()
    C:ppReduce()
    C:attackAnimation()
    user.bideTurns = 2
    user.bideDamage = 0
    user.bideTarget = nil
    user.lockedNum, user.lockedSlot = C.mnum, C.slot
    moveEnd(C)
    return
  end
  -- Future Sight / Doom Desire are delayed attacks on the cart even though they
  -- have power (battle_scripts_1.s BattleScript_EffectFutureSight).
  if int(C.move.power, 0) > 0 and eff ~= E.FUTURE_SIGHT then
    M.hit(C)
    moveEnd(C)
    return
  end
  C:attackString()
  C:ppReduce()
  local handled = Effects.run(C)
  if not handled then
    C:attackAnimation()
    B:say("But nothing happened!")
  end
  C:tryFaintTarget()
  C:tryFaintUser()
  moveEnd(C)
end

local function run(C)
  local B, user = C.B, C.user
  local eff = C.effect

  if not C.opts.called then
    user.movedThisTurn = true
  end
  -- Pursuit on a switching target never meets the canceller: sleep / freeze /
  -- Truant were checked when it was chosen to strike (Cmd_jumpifnopursuitswitchdmg)
  -- and paralysis, confusion, love and flinching are not rolled at all
  -- (battle_scripts_1.s:3081 has no attackcanceler).
  if not C.opts.called and not C.opts.pursuit then
    local c = canceller(C)
    if c == false then
      user.lastMoveNum = nil
      user.lastResultingNum = nil
      moveEndLite(C)
      return
    end
    if c == "bide" then
      bideAttack(C)
      moveEnd(C)
      return
    end
    -- Soundproof at the first target (the rest are asked per target in
    -- `body`); a doubles spread move asks every target there, the first too,
    -- so one Soundproof foe does not stop the move for the other.
    local ttype = int(C.move.target, 0)
    local spread = B.double and (ttype == T.BOTH or ttype == T.FOES_AND_ALLY)
    if not spread and soundproofBlocked(C) then return end
    if C.slot and user.moves[C.slot] and int(user.moves[C.slot].pp, 0) == 0
        and not user.lockedNum and C.mnum ~= MOVE.STRUGGLE then
      C:attackString()
      B:say("But there was no PP left for the move!")
      return
    end
  end

  if eff ~= E.PROTECT and eff ~= E.ENDURE then user.protectStreak = 0 end

  if chargeTurn(C) then
    moveEnd(C)
    return
  end

  if eff == E.METRONOME or eff == E.SLEEP_TALK or eff == E.MIRROR_MOVE or eff == E.ASSIST
      or eff == E.NATURE_POWER then
    return callMoves(C)
  end

  if eff == E.FOCUS_PUNCH and (int(user.lastPhysDmg, 0) > 0 or int(user.lastSpecDmg, 0) > 0) then
    -- pokefirered/data/battle_scripts_1.s:2255 (then BattleScript_MoveEnd)
    C:ppReduce()
    B:say(B:nameOf(user) .. " lost its focus and couldn't move!")
    moveEnd(C)
    return
  end

  forEachTarget(C, body)
end

-- One move, start to finish (engine.lua resolveMove).  `target` is already
-- resolved; `opts` = { called, calledBy, pursuit, passSlot, chosenAlly, and for
-- a called move callDepth, chosenSlot (the caller's), noPP (Sleep Talk) }.
function Bm:_resolveMove(user, target, row, slot, opts)
  opts = opts or {}
  if not user or user.mon.hp <= 0 or user.fighter.b ~= user then return end
  local C = newCtx(self, user, target, row, slot, opts)
  C.passSlot = opts.passSlot
  C.chosenAlly = opts.chosenAlly
  -- pret chosenMovePositions: the slot the seat chose, which a called move
  -- inherits from its caller (Grudge empties that one).
  if opts.called then C.chosenSlot = opts.chosenSlot else C.chosenSlot = slot end
  if opts.noPP then C.noPP = true end
  if opts.called then C.printedUsed = false end
  user.statLoweredMsg = nil
  if target then target.statLoweredMsg = nil end
  if not opts.called then self.syncEffect = nil end
  if not target then
    -- Nobody standing to aim at: the cart's "But there was no target..."
    C:attackString()
    C:ppReduce()
    self:say("But there was no target...")
    return C
  end
  run(C)
  return C
end

-- pokefirered/src/battle_util.c:1208 (after every action that was not called):
-- Intimidate / Trace, held-item checks (berries), Forecast -- one thing per
-- pass, passes until nothing acts (the cart re-enters state 6 until it returns
-- FALSE, so a 3v3 field's six Intimidates all resolve now).  M.PASS_CAP only
-- bounds a runaway; every pass spends a pending flag, an item or a form change.
M.PASS_CAP = 64
function Bm:_afterAction()
  if self.result then return end
  for _ = 1, M.PASS_CAP do
    local did = false
    did = did or Abilities.runIntimidate(self)
    did = did or Abilities.runTrace(self)
    if not did then
      for _, b in ipairs(self:active()) do
        if Items.normal(self, b, true) then did = true; break end
      end
    end
    did = did or Abilities.forecast(self)
    if not did then break end
  end
end

-- ==================================================================
-- the action a seat chose (the engine's forced_move + resolveMove front end)
-- ==================================================================

-- Which move this action uses and from which slot: the locked move, then an
-- Encore, then the Choice Band move, then Struggle, then the chosen slot.
function Bm:_actionMove(b, choice)
  if b.lockedNum then
    local slot = b.lockedSlot
    local row = slot and b.moves[slot]
    if not row or int(row.num, 0) ~= b.lockedNum then
      row = self:calledRowByNum(b.lockedNum, b)
      slot = self:slotOfNum(b, b.lockedNum)
    end
    if row then return row, slot, "locked" end
  end
  if choice.struggle or not self:hasUsableMove(b) then
    return M.STRUGGLE, nil, "struggle"
  end
  if int(b.encoreTurns, 0) > 0 and b.encoreNum then
    local slot = self:slotOfNum(b, b.encoreNum)
    if slot then
      local changed = slot ~= choice.move
      return b.moves[slot], slot, changed and "encore" or nil
    end
  end
  if b.choicedMove and Items.has(b, Items.HOLD.CHOICE_BAND) then
    local cur = b.moves[choice.move]
    if cur and int(cur.num, 0) ~= b.choicedMove then
      local cs = self:slotOfNum(b, b.choicedMove)
      if cs and int(b.moves[cs].pp, 0) > 0 then return b.moves[cs], cs, "choice" end
    end
  end
  local row = b.moves[choice.move]
  if not row then return M.STRUGGLE, nil, "struggle" end
  return row, choice.move, nil
end

-- A fight action.  `opts.pursuit` marks a Pursuit resolved ahead of a switch.
function Bm:_fightAction(fighter, choice, opts)
  opts = opts or {}
  local user = fighter.b
  if not user or user.mon.hp <= 0 then return end
  if choice.recharge and user.mustRecharge then
    -- The recharge turn: the canceller says it; any move row will do.
    local row = user.moves[user.lastSlot or 1] or M.STRUGGLE
    local C = newCtx(self, user, self:foes(user)[1] or user, row, nil, {})
    user.movedThisTurn = true
    canceller(C)
    return
  end
  local row, slot, why = self:_actionMove(user, choice)
  local aimed = nil
  if why == "locked" then
    aimed = user.lockedTarget or user.twoTurnTarget
    if int(row.target, 0) == T.RANDOM then aimed = nil end
  elseif choice.target ~= nil then
    local tf = self:_fighterAtSlot(choice.target)
    aimed = tf and tf.b or nil
    if aimed == nil and tf then aimed = tf.lastB end
  end
  local chosenAlly = nil
  if aimed and aimed.side == user.side and aimed ~= user then chosenAlly = aimed end
  local target = self:_pickTarget(user, row, aimed, why == "encore", false)
  if slot then user.lastSlot = slot end
  return self:_resolveMove(user, target, row, slot, {
    pursuit = opts.pursuit, passSlot = choice.pass, chosenAlly = chosenAlly,
  })
end

function M.install(Battle)
  for k, v in pairs(Bm) do Battle[k] = v end
end

return M
