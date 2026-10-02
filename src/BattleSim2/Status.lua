-- Gen 2 status: before-move gates and end-of-turn residuals.
--
-- Engine: src/battle/gen2/Battle.lua STATUSES / BURN_FRACTION / THAW_CHANCE.
-- Differs from Gen 1 BattleSim/Status.lua on purpose:
--
--   * **Freeze thaws 1/5.**  roll in 0..4; thawed (and can move) when roll==0.
--   * **Burn and poison tick 1/8 max HP** (not 1/16).  Burn still halves
--     *physical* Attack via burnAttack — SpA is untouched.
--   * **Toxic** still ramps as max(1, floor(maxHp * counter / 16)).
--   * **Paralysis** full-stops 1/4 of the time (roll in 0..3, stop when 0),
--     not Gen 1's 63/256; speed still quarters.
--   * **Sleep** wakes *and acts* on the turn the counter hits zero (Gen 1
--     loses the waking turn).
--   * Confusion self-hit routes through Damage.compute as HitConfusion runs
--     BattleCommand_DamageCalc and nothing after it: power 40, no crit, no
--     STAB, no matchup, no variation.  The caller hands in the attack /
--     defense HitSelfInConfusion builds (the confused mon's own battle stats,
--     its own side's Reflect, TruncateHL_BC, the selected move's Explosion
--     halving) and, as `itemBoostPercent`, the type-boost item DamageCalc
--     finds for the SELECTED move's type -- both cart bugs (pokecrystal
--     docs/bugs_and_glitches.md, "Confusion damage is affected by
--     type-boosting items and Explosion/Self-Destruct doubling").
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Damage = need("BattleSim2/Damage")

local M = {}

local floor, max = math.floor, math.max

M.PARALYSIS_SKIP_CHANCE = 4
M.THAW_CHANCE = 5
M.CONFUSION_HIT_ROLL = 128
M.CONFUSION_POWER = 40
M.RESIDUAL_DIVISOR = 8
M.TOXIC_DIVISOR = 16

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

-- ------- before-move gates

function M.sleepTick(turnsRemaining)
  local left = max(0, int(turnsRemaining, 0))
  if left == 0 then
    return { turnsRemaining = 0, wokeUp = false, canMove = true }
  end
  left = left - 1
  if left == 0 then
    -- Gen 2: waking turn is free — the mon acts this turn.
    return { turnsRemaining = 0, wokeUp = true, canMove = true }
  end
  return { turnsRemaining = left, wokeUp = false, canMove = false }
end

function M.sleepCanMove(turnsRemaining)
  return M.sleepTick(turnsRemaining).canMove
end

-- roll: 0..THAW_CHANCE-1; thaw when 0.
function M.freezeTick(roll)
  local thawed = int(roll, 1) % M.THAW_CHANCE == 0
  return { thawed = thawed, canMove = thawed }
end

function M.freezeCanMove(roll)
  return M.freezeTick(roll).canMove
end

-- roll: 0..PARALYSIS_SKIP_CHANCE-1; stop when 0.
function M.paralysisStop(roll)
  return int(roll, 1) % M.PARALYSIS_SKIP_CHANCE == 0
end

function M.paralysisTick(roll)
  local stopped = M.paralysisStop(roll)
  return { fullyParalyzed = stopped, canMove = not stopped }
end

function M.paralysisSpeed(speed)
  return max(1, floor(max(0, int(speed, 1)) / 4))
end

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
    { crit = false, stab = false, typeEffect = { 100 },
      roll = Damage.ROLL_MAX, physical = true,
      itemBoostPercent = state.itemBoostPercent })

  return { turnsRemaining = left, snappedOut = false, selfHit = true,
           canMove = false, selfDamage = hit.damage or 0 }
end

function M.confusionSelfHit(roll)
  return int(roll, 255) < M.CONFUSION_HIT_ROLL
end

-- ------- residuals

local function eighth(maxHp)
  return max(1, floor(max(0, int(maxHp, 0)) / M.RESIDUAL_DIVISOR))
end

function M.residualBurn(maxHp)
  return eighth(maxHp)
end

function M.residualPoison(maxHp)
  return eighth(maxHp)
end

function M.residualToxic(maxHp, toxicCounter)
  local counter = max(1, int(toxicCounter, 1))
  return max(1, floor(max(0, int(maxHp, 0)) * counter / M.TOXIC_DIVISOR))
end

-- Burn halves physical Attack only (SpA unchanged — callers must not pass spa).
function M.burnAttack(attack)
  return max(1, floor(max(0, int(attack, 1)) / 2))
end

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
