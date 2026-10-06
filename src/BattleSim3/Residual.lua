-- Gen 3 end of turn, battle start and switch-in effects.
--
-- Port of engine src/core/game3/battle/residuals.lua (`collectEvents`,
-- `sortedBattlers` pokefirered/src/battle_util.c:484 ENDTURN_ORDER) and
-- residual_handlers.lua (every phase, pret battle_util.c:453 DoFieldEndTurnEffects,
-- :722 DoBattlerEndTurnEffects, :1064 HandleFaintedMonActions / Future Sight /
-- Perish Song), plus engine.lua `battleStartEffects` (battle_main.c:2856) and
-- `switchInEffects` (battle_script_commands.c:4960).
--
-- Installed on Battle by Turn.lua (`Residual.install(Battle)`), beside Move.lua's
-- helper surface.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Damage    = need("BattleSim3/Damage")
local Status    = need("BattleSim3/Status")
local Abilities = need("BattleSim3/Abilities")
local Items     = need("BattleSim3/Items")
local Field     = need("BattleSim3/Field")
local Types     = need("BattleSim3/Types")
local Move      = need("BattleSim3/Move")

local M = {}

local floor, max, min = math.floor, math.max, math.min

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local Bm = {}

local WEATHER_START_TEXT = {
  RAIN = "It is raining.", SUN = "The sunlight is strong.",
  SAND = "A sandstorm is raging.", HAIL = "It is hailing.",
}

-- ------------------------------------------------------------------
-- speed and order
-- ------------------------------------------------------------------

-- The live wrappers over Field.speed / Field.sortRows (pure, vector-pinned).
function Bm:_speedOf(b)
  return Field.speed(b, self:weather(), self.randomTurnNumber)
end

function Bm:_orderRows(rows)
  return Field.sortRows(rows, self.rng, self.TIE_BREAK_ROLL)
end

-- The standing battlers by speed (battle start, end of turn): `pri` is this
-- turn's move priority for a battler that fought (ENDTURN_ORDER reads the
-- chosen moves), 0 otherwise.
function Bm:_speedOrder(priorities)
  local rows = {}
  for i, b in ipairs(self:active()) do
    rows[#rows + 1] = { b = b, pri = priorities and priorities[b] or 0, spe = self:_speedOf(b), order = i }
  end
  self:_orderRows(rows)
  local out = {}
  for i, r in ipairs(rows) do out[i] = r.b end
  return out
end

-- ------------------------------------------------------------------
-- switch-in (battle_script_commands.c:4960 switchineffects)
-- ------------------------------------------------------------------

function Bm:switchInEffects(b, opts)
  opts = opts or {}
  if not b or self.result then return false end
  if opts.spikes then
    local layers = int(self.sides[b.side].spikes, 0)
    if layers > 0 and not Abilities.isType(b, Types.ID.FLYING) and b.ability ~= "LEVITATE" then
      local denom = ({ 8, 6, 4 })[min(layers, 3)]
      local dmg = max(1, floor(b.mon.maxHp / denom))
      self:loseHp(b, dmg)
      self:say(self:nameOf(b) .. " is hurt by SPIKES!")
      if b.mon.hp <= 0 then
        self:_faintBattler(b)
        return true
      end
    end
  end
  if b.mon.hp <= 0 then return false end
  if b.ability == "TRUANT" then b.truantCounter = 1 end
  local did = Abilities.switchIn(self, b)
  if not did then did = Items.onSwitchIn(self, b) end
  if not opts.deferIntimidate then
    for _ = 1, Move.PASS_CAP do
      if not (Abilities.runIntimidate(self) or Abilities.runTrace(self)) then break end
      did = true
    end
  end
  return did
end

-- pokefirered/src/battle_main.c:2856 (after the opening send-outs)
function Bm:_battleStart()
  local w = Field.kind(self.initialWeather)
  if w then
    self.field.weather, self.field.weatherTurns = w, 0
    self:_emit("weather", { text = w, amount = 1 })
    self:say(WEATHER_START_TEXT[w])
  end
  local order = self:_speedOrder()
  for _, b in ipairs(order) do
    if not self.result then Abilities.switchIn(self, b) end
  end
  for _ = 1, Move.PASS_CAP do
    if not (Abilities.runIntimidate(self) or Abilities.runTrace(self)) then break end
  end
  for _, b in ipairs(order) do
    if b.mon.hp > 0 then Items.onSwitchIn(self, b) end
  end
  self:_faintSweep()
end

-- ------------------------------------------------------------------
-- end of turn
-- ------------------------------------------------------------------

local SIDE_TIMERS = {
  { key = "reflectTurns", phase = "reflect", name = "REFLECT" },
  { key = "lightScreenTurns", phase = "light_screen", name = "LIGHT SCREEN" },
  { key = "mistTurns", phase = "mist", name = "MIST" },
  { key = "safeguardTurns", phase = "safeguard", name = "SAFEGUARD" },
}

-- The occupant of a field slot, standing, or nil.
function Bm:_standingAt(slot)
  local f = self:_fighterAtSlot(slot)
  local b = f and f.b
  if b and b.mon.hp > 0 then return b end
  return nil
end

-- The battler a field slot holds as the cart's gBattleMons[position] does: the
-- occupant whether standing or not, else the last battler that stood there (a
-- seat emptied by a faint keeps its fainted mon's data until someone switches
-- in).  Never nil for a seat that has fielded a battler.
function Bm:_occupantAt(slot)
  local f = self:_fighterAtSlot(slot)
  if not f then return nil end
  return f.b or f.lastB
end

function Bm:_sideName(side)
  local f = self.bySide[side] and self.bySide[side][1]
  return f and f.name or ("side " .. side)
end

-- pokefirered/src/battle_util.c:505 (one timer, both sides, side a first)
function Bm:_tickSideTimer(row)
  for _, side in ipairs({ "a", "b" }) do
    local s = self.sides[side]
    if int(s[row.key], 0) > 0 then
      s[row.key] = s[row.key] - 1
      if s[row.key] <= 0 then
        s[row.key] = 0
        self:say(self:_sideName(side) .. "'s " .. row.name .. " wore off!")
      end
    end
  end
end

-- pokefirered/src/battle_util.c:603
function Bm:_tickWish()
  for _, side in ipairs({ "a", "b" }) do
    local s = self.sides[side]
    local keep = {}
    for _, tok in ipairs(s.wish) do
      tok.turns = tok.turns - 1
      if tok.turns <= 0 then
        local b = self:_standingAt(tok.slot)
        if b then
          -- src/battle_script_commands.c:8916
          self:say(tok.wisher .. "'s WISH came true!")
          if b.mon.hp >= b.mon.maxHp then
            self:say(self:nameOf(b) .. "'s HP is full!")
          else
            local heal = floor(b.mon.maxHp / 2)
            if heal == 0 then heal = 1 end
            self:heal(b, heal)
            self:say(self:nameOf(b) .. " regained health!")
          end
        end
      else
        keep[#keep + 1] = tok
      end
    end
    s.wish = keep
  end
end

-- pokefirered/src/battle_util.c:624 (weather continues / ends; sand and hail chip)
function Bm:_tickWeather(order)
  local kind = Field.kind(self.field.weather)
  if not kind then return end
  local turns = int(self.field.weatherTurns, 0)
  local ended = false
  if turns > 0 then
    self.field.weatherTurns = turns - 1
    ended = self.field.weatherTurns <= 0
  end
  if ended then
    self.field.weather, self.field.weatherTurns = nil, 0
    self:_emit("weather", { text = kind, amount = 0 })
    self:say(({ RAIN = "The rain stopped.", SUN = "The sunlight faded.",
                SAND = "The sandstorm subsided.", HAIL = "The hail stopped." })[kind])
    return
  end
  self:_emit("weather", { text = kind, amount = 2 })
  self:say(({ RAIN = "Rain continues to fall.", SUN = "The sunlight is strong.",
              SAND = "The sandstorm rages.", HAIL = "Hail continues to fall." })[kind])
  if kind ~= "SAND" and kind ~= "HAIL" then return end
  if not self:weather() then return end
  for _, b in ipairs(order) do
    -- pokefirered/src/battle_script_commands.c:7218 Cmd_weatherdamage: a veiled
    -- GHOST takes no chip (0 damage, so no line either).
    local ghost = self.ghost == "veiled" and b.side == "b"
    if b.mon.hp > 0 and not Field.weatherImmune(b, kind) and not ghost then
      self:say(self:nameOf(b) .. (kind == "SAND" and " is buffeted by the sandstorm!" or " is pelted by HAIL!"))
      self:loseHp(b, Field.chip(b.mon.maxHp))
      self:_faintSweep()
    end
  end
end

-- The per-battler phases (battle_util.c:722).  Returns nothing; faints are
-- announced by the caller after each step.
local PHASE = {}

PHASE.ingrain = function(B, b)
  if not b.ingrain or b.mon.hp >= b.mon.maxHp then return end
  local heal = floor(b.mon.maxHp / 16)
  if heal == 0 then heal = 1 end
  B:say(B:nameOf(b) .. " absorbed nutrients with its roots!")
  B:heal(b, heal)
end

PHASE.abilities = function(B, b) Abilities.endTurn(B, b) end

PHASE.held_items = function(B, b) Items.normal(B, b, false) end

-- ENDTURN_ITEMS2 (battle_util.c:785): the moveTurn pass, per battler.
PHASE.held_items2 = function(B, b) Items.normal(B, b, true) end

-- pokefirered/src/battle_util.c:789
PHASE.leech_seed = function(B, b)
  if b.seededBy == nil then return end
  local src = B:_standingAt(b.seededBy)
  if not src or b.mon.hp <= 0 then return end
  local dmg = floor(b.mon.maxHp / 8)
  if dmg == 0 then dmg = 1 end
  local dealt = B:loseHp(b, dmg)
  if b.ability == "LIQUID_OOZE" then
    B:emitAbility(b)
    B:loseHp(src, dealt)
    B:say("It sucked up the liquid ooze!")
  else
    B:heal(src, dealt)
    B:say(B:nameOf(b) .. "'s health is sapped by LEECH SEED!")
  end
end

-- pokefirered/src/battle_util.c:805
PHASE.status_chip = function(B, b)
  local s = Status.normalise(b.mon.status)
  if not s then return end
  local amount, counter = Status.chip(s, b.mon.maxHp, b.toxicCounter)
  if not amount then return end
  if counter then b.toxicCounter = counter end
  B:say(B:nameOf(b) .. Status.CHIP_TEXT[s])
  B:loseHp(b, amount, { status = s })
end

-- pokefirered/src/battle_util.c:841
PHASE.nightmare = function(B, b)
  if not b.nightmare or b.mon.hp <= 0 then return end
  if Status.normalise(b.mon.status) ~= "SLP" then
    b.nightmare = nil
    return
  end
  local dmg = floor(b.mon.maxHp / 4)
  if dmg == 0 then dmg = 1 end
  B:say(B:nameOf(b) .. " is locked in a NIGHTMARE!")
  B:loseHp(b, dmg)
end

-- pokefirered/src/battle_util.c:861
PHASE.curse = function(B, b)
  if not b.cursed or b.mon.hp <= 0 then return end
  local dmg = floor(b.mon.maxHp / 4)
  if dmg == 0 then dmg = 1 end
  B:say(B:nameOf(b) .. " is afflicted by the CURSE!")
  B:loseHp(b, dmg)
end

-- pokefirered/src/battle_util.c:872
PHASE.partial_trap = function(B, b)
  if int(b.trapTurns, 0) <= 0 or b.mon.hp <= 0 then return end
  b.trapTurns = b.trapTurns - 1
  local label = B:moveLabelByNum(b.trapMove)
  if b.trapTurns > 0 then
    B:_emit("anim", { slot = b.slot, side = b.side, text = "TURN_TRAP" })
    B:say(B:nameOf(b) .. " is hurt by " .. label .. "!")
    B:loseHp(b, Field.chip(b.mon.maxHp, Field.TRAP_CHIP_DENOM))
  else
    b.trapTurns, b.trapMove, b.trapSource = nil, nil, nil
    B:say(B:nameOf(b) .. " was freed from " .. label .. "!")
  end
end

-- pokefirered/src/battle_util.c:904
PHASE.uproar = function(B, b)
  if int(b.uproarTurns, 0) <= 0 then return end
  for _, other in ipairs(B:active()) do
    if Status.normalise(other.mon.status) == "SLP" and other.ability ~= "SOUNDPROOF" then
      other.nightmare = nil
      B:cure(other, B:nameOf(other) .. " woke up in the UPROAR!")
    end
  end
  b.uproarTurns = b.uproarTurns - 1
  if b.unableToMove then
    B:cancelMultiTurn(b)
    B:say(B:nameOf(b) .. " calmed down.")
  elseif b.uproarTurns > 0 then
    B:say(B:nameOf(b) .. " is making an UPROAR!")
  else
    B:cancelMultiTurn(b)
    B:say(B:nameOf(b) .. " calmed down.")
  end
end

-- pokefirered/src/battle_util.c:953
PHASE.thrash = function(B, b)
  if int(b.rampageTurns, 0) <= 0 then return end
  b.rampageTurns = b.rampageTurns - 1
  if b.unableToMove then
    B:cancelMultiTurn(b)
  elseif b.rampageTurns <= 0 and b.lockedNum then
    b.lockedNum, b.lockedSlot, b.lockedTarget, b.rampageTurns = nil, nil, nil, nil
    if int(b.confusion, 0) <= 0 and b.ability ~= "OWN_TEMPO" then
      b.confusion = B:roll(0, 3) + 2
      local text = B:nameOf(b) .. " became confused due to fatigue!"
      B:_emit("status", { slot = b.slot, side = b.side, confused = 1, text = text })
      B:say(text)
    end
  end
end

-- pokefirered/src/battle_util.c:975
PHASE.disable = function(B, b)
  if not b.disabledNum then return end
  if not B:slotOfNum(b, b.disabledNum) then
    b.disabledNum, b.disableTurns = nil, nil
    return
  end
  b.disableTurns = int(b.disableTurns, 1) - 1
  if b.disableTurns <= 0 then
    b.disabledNum, b.disableTurns = nil, nil
    B:say(B:nameOf(b) .. " is disabled no more!")
  end
end

-- pokefirered/src/battle_util.c:998
PHASE.encore = function(B, b)
  if int(b.encoreTurns, 0) <= 0 then return end
  local slot = b.encoreSlot
  if not slot or not b.moves[slot] or int(b.moves[slot].num, 0) ~= b.encoreNum then
    b.encoreNum, b.encoreTurns, b.encoreSlot = nil, nil, nil
    return
  end
  b.encoreTurns = b.encoreTurns - 1
  if b.encoreTurns <= 0 or int(b.moves[slot].pp, 0) <= 0 then
    b.encoreNum, b.encoreTurns, b.encoreSlot = nil, nil, nil
    B:say(B:nameOf(b) .. "'s ENCORE ended!")
  end
end

PHASE.lock_on = function(B, b)
  if int(b.lockedOnTurns, 0) > 0 then
    b.lockedOnTurns = b.lockedOnTurns - 1
    if b.lockedOnTurns <= 0 then b.lockedOnTurns, b.lockedOnBy = nil, nil end
  end
end

PHASE.charge = function(B, b)
  if int(b.charged, 0) > 0 then
    b.charged = b.charged - 1
    if b.charged <= 0 then b.charged = nil end
  end
end

PHASE.taunt = function(B, b)
  if int(b.tauntTurns, 0) > 0 then
    b.tauntTurns = b.tauntTurns - 1
    if b.tauntTurns <= 0 then b.tauntTurns = nil end
  end
end

-- pokefirered/src/battle_util.c:1032
PHASE.yawn = function(B, b)
  if int(b.yawnTurns, 0) <= 0 then return end
  b.yawnTurns = b.yawnTurns - 1
  if b.yawnTurns > 0 then return end
  b.yawnTurns = nil
  local ab = b.ability
  if Status.normalise(b.mon.status) or ab == "VITAL_SPIRIT" or ab == "INSOMNIA" then return end
  if B:uproarActive() and ab ~= "SOUNDPROOF" then return end
  B:cancelMultiTurn(b)
  B:inflict(b, "SLP", { source = b })
end

PHASE.volatiles = function(B, b)
  b.unableToMove = nil
end

M.PHASE = PHASE

-- pokefirered/data/battle_scripts_1.s:3461 (the delayed hit lands).  The damage
-- was fixed at use from the user's stats and level (Effects.lua FUTURE_SIGHT);
-- the attacker here is only the seat, as pret's gBattlerAttacker =
-- futureSightAttacker[target] is a battler position (battle_util.c:1093): its
-- present occupant, or -- when the user fainted and nobody has replaced it (the
-- replace phase comes after the end of turn, or the bench is empty) -- the
-- fainted user itself, which still lands the hit.
function Bm:_futureSightHit(tok, target)
  local attacker = self:_occupantAt(tok.attackerSlot)
  self:say(self:nameOf(target) .. " took the " .. self:moveLabel(tok.move) .. " attack!")
  local C = Move.newCtx(self, attacker, target, tok.move, nil, { futureSight = true })
  C.accOverride = int(tok.move.accuracy, 90)
  if not C:accuracyCheck("normal", false) then
    self:say("But it failed!")
    return
  end
  local dmg = int(tok.damage, 1)
  dmg = floor(dmg * self:roll(Damage.ROLL_MIN, Damage.ROLL_MAX) / 100)
  if dmg == 0 then dmg = 1 end
  local hung
  dmg, hung = self:_adjustDamage(C, target, dmg)
  self:_emit("anim", { slot = target.slot, side = target.side,
                       text = tok.doom and "DOOM_DESIRE_HIT" or "FUTURE_SIGHT_HIT" })
  self:_dealDamage(C, dmg, { physical = false })
  if hung == "endured" then
    self:say(self:nameOf(target) .. " endured the hit!")
  elseif hung == "hung" then
    Items.focusBandMessage(self, target)
  end
end

-- pokefirered/src/battle_util.c:1083.  On the cart the fainted-mon handling
-- (HandleFaintedMonActions) sends every replacement in BEFORE this step, so a
-- hit due at a seat emptied this turn lands on the newcomer.  Here the replace
-- phase follows the end of turn, so such a token waits at 0 (`pending`) and
-- `_landPendingFutureSight` fires it once the seat is filled.  A seat left
-- empty (no living bench: pret's absent battler, skipped) drops it; one a
-- Revive re-armed this turn is owed a mon again (Turn.lua `_refreshVacant`),
-- so its hit waits too.
function Bm:_tickFutureSight()
  for _, f in ipairs(self.order) do
    local side = self.sides[f.side]
    local keep = {}
    for _, tok in ipairs(side.futureSight) do
      if tok.targetSlot == f.slot then
        tok.turns = tok.turns - 1
        if tok.turns <= 0 then
          local target = self:_standingAt(f.slot)
          if target then
            self:_futureSightHit(tok, target)
          elseif f.mustReplace then
            tok.turns = 0
            keep[#keep + 1] = tok
          end
        else
          keep[#keep + 1] = tok
        end
      else
        keep[#keep + 1] = tok
      end
    end
    side.futureSight = keep
    self:_faintSweep()
  end
end

-- The due hits that waited for a replacement (above), after the replace
-- phase's switch-ins; one that still finds its seat empty keeps waiting only
-- while that seat is owed a mon.
function Bm:_landPendingFutureSight()
  for _, f in ipairs(self.order) do
    if self.result then return end
    local side = self.sides[f.side]
    local keep, any = {}, false
    for _, tok in ipairs(side.futureSight) do
      if tok.targetSlot == f.slot and tok.turns <= 0 then
        local target = self:_standingAt(f.slot)
        if target then
          any = true
          self:_futureSightHit(tok, target)
        elseif f.mustReplace then
          keep[#keep + 1] = tok
        end
      else
        keep[#keep + 1] = tok
      end
    end
    side.futureSight = keep
    if any then self:_faintSweep() end
  end
end

-- pokefirered/src/battle_util.c:1116
function Bm:_tickPerishSong(order)
  for _, b in ipairs(order) do
    if b.perishTurns ~= nil and b.mon.hp > 0 then
      local n = b.perishTurns
      self:say(self:nameOf(b) .. "'s PERISH count fell to " .. n .. "!")
      if n <= 0 then
        b.perishTurns = nil
        self:loseHp(b, b.mon.hp)
        self:_faintSweep()
      else
        b.perishTurns = n - 1
      end
    end
  end
end

-- The whole end of turn (engine residuals.lua collectEvents).
function Bm:_endTurn()
  if self.result then return end
  -- pokefirered/src/battle_main.c:2957
  for _, b in ipairs(self:active()) do
    b.protected, b.enduring = nil, nil
  end
  local order = self:_speedOrder(self.turnPriority)

  for _, row in ipairs(SIDE_TIMERS) do self:_tickSideTimer(row) end
  self:_tickWish()
  self:_tickWeather(order)

  for _, b in ipairs(order) do
    for _, phase in ipairs(Field.BATTLER_PHASES) do
      if b.mon.hp <= 0 or b.fighter.b ~= b then break end
      PHASE[phase](self, b)
      local fainted = b.mon.hp <= 0
      self:_faintSweep()
      if fainted and Field.FAINT_HALT[phase] then break end
    end
  end

  self:_afterAction()
  self:_faintSweep()
  self:_tickFutureSight()
  self:_tickPerishSong(order)
  self:_faintSweep()
end

function M.install(Battle)
  for k, v in pairs(Bm) do Battle[k] = v end
end

return M
