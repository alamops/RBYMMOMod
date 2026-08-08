-- Gen1 status: the before-move gates and the end-of-turn residuals.
--
-- Two families of function live here, and they fire at opposite ends of a
-- turn:
--
--   * the *gates* (sleep, freeze, paralysis, confusion) run before the chosen
--     move and answer one question -- does this side act at all;
--   * the *residuals* (burn, poison, toxic) run after, and answer how much HP
--     the status costs.
--
-- The quirks kept deliberately, each because a mediated fight has to resolve
-- the way the players' own copies would:
--
--   * **Sleep loses the waking turn.**  The counter is decremented *before*
--     the move, and the turn it reaches zero is still spent waking up.  So a
--     3-turn sleep costs three turns, not two.
--   * **Freeze never self-thaws.**  There is no thaw roll in Gen1 at all; only
--     a fire-type hit or an item ends it, so `thawed` is false for every roll
--     and the field exists only to say so out loud.
--   * **Confusion decrements first and snaps out at zero**, and the turn it
--     snaps out on is a free one -- unlike sleep.  Otherwise it self-hits on
--     roll < 128, and the self-hit is a typeless 40-power physical hit using
--     the confused side's *own* attack against its *own* defence, with no
--     STAB, no type chart, no crit, and a fixed max roll.
--   * **Paralysis** full-stops on roll < 63 (63/256, not the 25% the manual
--     claims) and quarters speed.
--
-- Every "a sixteenth" is max(1, floor(maxHp/16)), so a 10 HP monster still
-- takes 1 rather than 0 -- burn and poison can always eventually kill.
--
-- Nothing here raises; no love, no engine modules, no mod facade.  The one
-- dependency is the sibling damage pipeline, which the confusion self-hit
-- routes through rather than reimplementing: two damage formulas in one sim
-- would drift on the first fix to either.

local need = ...
local Damage = need("BattleSim/Damage")

local M = {}

local floor, max = math.floor, math.max

-- 63/256 before the move; 128/256 for a confusion self-hit.
M.PARALYSIS_STOP_ROLL = 63
M.CONFUSION_HIT_ROLL = 128
M.CONFUSION_POWER = 40
M.RESIDUAL_DIVISOR = 16

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

-- ------- before-move gates

-- A sleeping side never acts, so `canMove` is false on every branch; the
-- interesting return is `wokeUp`, which is what the narration hangs off.
--
-- A counter already at zero means "not asleep": the gate passes rather than
-- decrementing into negatives, so a caller that asks the wrong question gets a
-- harmless answer instead of a monster stuck asleep forever.
function M.sleepTick(turnsRemaining)
  local left = max(0, int(turnsRemaining, 0))
  if left == 0 then
    return { turnsRemaining = 0, wokeUp = false, canMove = true }
  end
  left = left - 1
  return { turnsRemaining = left, wokeUp = left == 0, canMove = false }
end

function M.sleepCanMove(turnsRemaining)
  return M.sleepTick(turnsRemaining).canMove
end

-- The roll is accepted and ignored: there is no self-thaw in Gen1, and taking
-- the argument keeps the gate's shape uniform for the turn machine that will
-- call all four of these through one dispatcher.
function M.freezeTick(_roll)
  return { thawed = false, canMove = false }
end

function M.freezeCanMove(_roll)
  return false
end

function M.paralysisStop(roll)
  return int(roll, 255) < M.PARALYSIS_STOP_ROLL
end

function M.paralysisTick(roll)
  local stopped = M.paralysisStop(roll)
  return { fullyParalyzed = stopped, canMove = not stopped }
end

-- max(1, floor(speed/4)) -- the floor matters at low speed, where a straight
-- quarter would reach zero and the turn order would stop being defined.
function M.paralysisSpeed(speed)
  return max(1, floor(max(0, int(speed, 1)) / 4))
end

-- state: { turnsRemaining, level, attack | atk, defense | def }
--
-- The self-hit damage is computed here rather than left to the caller because
-- the parameters that make it typeless are part of the *rule*, not the
-- caller's choice: get one of them wrong and confusion hurts differently on
-- the two runtimes.
function M.confusionTick(state, roll)
  state = state or {}
  local left = max(0, int(state.turnsRemaining, 0))
  if left > 0 then left = left - 1 end

  if left == 0 then
    return { turnsRemaining = 0, snappedOut = true, selfHit = false,
             canMove = true, selfDamage = 0 }
  end

  if not M.confusionSelfHit(roll) then
    return { turnsRemaining = left, snappedOut = false, selfHit = false,
             canMove = true, selfDamage = 0 }
  end

  local hit = Damage.compute(
    { level = state.level, attack = state.attack, atk = state.atk },
    { defense = state.defense, def = state.def },
    { power = M.CONFUSION_POWER },
    { crit = false, stab = false, typeEffect = { 100 }, roll = Damage.ROLL_MAX })

  return { turnsRemaining = left, snappedOut = false, selfHit = true,
           canMove = false, selfDamage = hit.damage or 0 }
end

function M.confusionSelfHit(roll)
  return int(roll, 255) < M.CONFUSION_HIT_ROLL
end

-- ------- residuals

local function sixteenth(maxHp)
  return max(1, floor(max(0, int(maxHp, 0)) / M.RESIDUAL_DIVISOR))
end

function M.residualBurn(maxHp)
  return sixteenth(maxHp)
end

function M.residualPoison(maxHp)
  return sixteenth(maxHp)
end

-- Toxic stacks by multiplying the same sixteenth by the badly-poisoned
-- counter, which the turn machine increments once per tick.
function M.residualToxic(maxHp, toxicCounter)
  return sixteenth(maxHp) * max(1, int(toxicCounter, 1))
end

function M.burnAttack(attack)
  return max(1, floor(max(0, int(attack, 1)) / 2))
end

-- ------- dispatcher
--
-- One entry point for the turn machine, so the call order lives in one place
-- rather than being reassembled at each of the sites that gate a move.
-- Returns the same tables the individual gates do, plus the status name, and
-- nil for a status with no before-move gate at all (burn, poison, toxic) so
-- the caller can tell "passed the gate" from "there was no gate".
function M.beforeMove(state, roll)
  state = state or {}
  local status = state.status
  if status == "sleep" then
    local out = M.sleepTick(state.turnsRemaining); out.status = status; return out
  elseif status == "freeze" then
    local out = M.freezeTick(roll); out.status = status; return out
  elseif status == "paralysis" then
    local out = M.paralysisTick(roll); out.status = status; return out
  elseif status == "confusion" then
    local out = M.confusionTick(state, roll); out.status = status; return out
  end
  return nil
end

-- The end-of-turn half of the same seam.  nil when the status costs no HP.
function M.residual(state)
  state = state or {}
  local status = state.status
  if status == "burn" then return M.residualBurn(state.maxHp) end
  if status == "poison" then return M.residualPoison(state.maxHp) end
  if status == "toxic" then
    return M.residualToxic(state.maxHp, state.toxicCounter)
  end
  return nil
end

return M
