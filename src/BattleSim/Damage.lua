-- Gen1 damage, as an integer pipeline.
--
-- This is the one number a mediated battle exists to decide, so it is written
-- out step by step rather than as one expression: every intermediate the
-- shared vector pack asserts (`levelTerm`, `base`, `modified`, `statClamped`,
-- `immune`) is returned, which is what lets the Lua and JS twins be pinned
-- against each other at the point they diverge instead of at the total.
--
-- The pipeline, in order, and the order is load-bearing:
--
--   1. stat clamp -- if *either* the attack or the defence exceeds 255, both
--      are replaced by max(1, floor(x/4)).  The original does this because the
--      stats go through an 8-bit register; the quirk is that it clamps the
--      pair, so a huge attack quarters a modest defence along with it.
--   2. levelTerm = floor(2L/5 + 2), with L doubled on a critical hit.  A crit
--      in Gen1 doubles the *level term*, not the final damage -- close to but
--      not exactly 2x, and the difference is visible at low levels.
--   3. base = floor(floor(levelTerm * power * attack / defence) / 50) + 2.
--   4. STAB, as floor(d * 3/2).
--   5. type effectiveness, applied one percent at a time as floor(d * pct/100)
--      -- again the original's shape: against a dual type the two multipliers
--      are two separate truncating steps, not one combined one, so 200 then 50
--      does not always land back where it started.  A single 0 anywhere in the
--      list is immunity: damage is 0 and nothing after it runs.
--   6. the random factor, max(1, floor(d * roll / 255)) for roll in 217..255.
--
-- The min-1 clamp at step 6 is applied unconditionally.  (The original skips
-- the roll entirely when damage has already fallen to 1; that shortcut is
-- deliberately not modelled here, because the shared fixture does not, and the
-- two runtimes agreeing matters more than either agreeing with a disassembly.)
--
-- Nothing here raises: a missing or nonsensical field is coerced to something
-- the arithmetic survives, because every caller is downstream of a mod
-- callback.  A battle that reports an odd number is recoverable; one that
-- throws out of a hook is not.
--
-- No love, no engine modules, no mod facade.

local need = ...            -- entry-chunk shape; this module resolves nothing

local M = {}

local floor, max = math.floor, math.max

M.ROLL_MIN = 217
M.ROLL_MAX = 255
M.STAT_CAP = 255

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

-- Reads a stat off either spelling.  `attack`/`defense` is what the wire and
-- the fixtures use; `atk`/`def` is what the engine's battler tables use, and
-- accepting both means callers on either side of the boundary need no adapter.
local function stat(source, long, short, fallback)
  if type(source) ~= "table" then return fallback end
  local value = source[long]
  if value == nil then value = source[short] end
  return int(value, fallback)
end

-- Normalises whatever the caller had to hand into a list of percents: a bare
-- number is a single step, a list is taken as written, nil is neutral.
local function percents(effect)
  if effect == nil then return { 100 } end
  if type(effect) == "number" then return { floor(effect) } end
  if type(effect) ~= "table" then return { 100 } end
  local list = {}
  for i = 1, #effect do list[i] = int(effect[i], 100) end
  if #list == 0 then return { 100 } end
  return list
end

-- The 8-bit stat quirk.  Returns the pair plus whether it fired, because
-- "statClamped" is a fixture field and a useful thing to show in a log when a
-- player asks why their 400 attack hit like 100.
function M.clampStats(attack, defense)
  attack, defense = max(0, int(attack, 0)), max(0, int(defense, 1))
  if attack <= M.STAT_CAP and defense <= M.STAT_CAP then
    return attack, max(1, defense), false
  end
  return max(1, floor(attack / 4)), max(1, floor(defense / 4)), true
end

-- floor(2L/5 + 2), with the crit doubling folded in at the level rather than
-- at the end.
function M.levelTerm(level, crit)
  local L = max(0, int(level, 1))
  if crit then L = L * 2 end
  return floor(2 * L / 5 + 2)
end

-- attacker: { level, attack | atk }
-- defender: { defense | def }
-- move:     { power }
-- opts:     { crit, stab, typeEffect | typeEff, roll }
--
-- `roll` nil means "do not pick": the result reports the whole 217..255 band
-- through minDamage/maxDamage and leaves `damage` nil, which is how a caller
-- previews a move without spending a draw.
--
-- Returns one table; it is never nil, so a caller can index it without a
-- guard even when the inputs were nonsense.
function M.compute(attacker, defender, move, opts)
  attacker, defender = attacker or {}, defender or {}
  move, opts = move or {}, opts or {}

  local rawAttack = stat(attacker, "attack", "atk", 0)
  local rawDefense = stat(defender, "defense", "def", 1)
  local attack, defense, statClamped = M.clampStats(rawAttack, rawDefense)

  local levelTerm = M.levelTerm(attacker.level, opts.crit)
  local power = max(0, int(move.power, 0))

  local base = floor(floor(levelTerm * power * attack / defense) / 50) + 2

  local result = {
    levelTerm = levelTerm,
    base = base,
    attack = attack,
    defense = defense,
    statClamped = statClamped,
    crit = opts.crit and true or false,
    stab = opts.stab and true or false,
    immune = false,
  }

  local d = base
  if opts.stab then d = floor(d * 3 / 2) end

  local effect = opts.typeEffect
  if effect == nil then effect = opts.typeEff end

  for _, pct in ipairs(percents(effect)) do
    if pct <= 0 then
      -- Immunity short-circuits: the original stops here too, so no later
      -- multiplier and no random factor gets a chance to lift it off zero.
      result.modified = 0
      result.immune = true
      result.damage = 0
      result.minDamage = 0
      result.maxDamage = 0
      return result
    end
    d = floor(d * pct / 100)
  end

  result.modified = d
  result.minDamage = M.applyRoll(d, M.ROLL_MIN)
  result.maxDamage = M.applyRoll(d, M.ROLL_MAX)

  if opts.roll ~= nil then
    result.roll = int(opts.roll, M.ROLL_MAX)
    result.damage = M.applyRoll(d, result.roll)
  end

  return result
end

-- The random factor on its own, so the turn machine can re-apply a roll it
-- drew elsewhere without rebuilding the whole pipeline.
function M.applyRoll(modified, roll)
  return max(1, floor(max(0, int(modified, 0)) * int(roll, M.ROLL_MAX) / 255))
end

return M
