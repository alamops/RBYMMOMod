-- Gen1 damage, as an integer pipeline.
--
-- This is the one number a mediated battle exists to decide, so it is written
-- out step by step rather than as one expression: every intermediate the
-- shared vector pack asserts (`levelTerm`, `base`, `modified`, `statClamped`,
-- `immune`) is returned, which is what lets the Lua and JS twins be pinned
-- against each other at the point they diverge instead of at the total.
--
-- The pipeline, in order, and the order is load-bearing.  Every step is
-- pokered's GetDamageVarsFor{Player,Enemy}Attack .scaleStats and
-- CalculateDamage (engine/battle/core.asm :4030-4143 / :4299-4470):
--
--   1. stat scaling -- if *either* the attack or the defence exceeds 255 (a
--      non-zero high byte), both are shifted right twice.  The quirk is that
--      it scales the pair, so a huge attack quarters a modest defence along
--      with it.  The attack is then bumped to at least 1, and only the LOW
--      BYTE of each goes on: CalculateDamage takes 8-bit operands, so a
--      scaled stat of 256 or more wraps (a 1100 defence -- a Reflect-doubled
--      550 -- scales to 275 and divides as 19).  The cart has no floor on the
--      defence and freezes dividing by zero when it wraps or scales to 0; the
--      referee clamps the divisor to 1 instead, because a cart freeze is the
--      one quirk never reproduced (docs/plans/gen12-referee-fidelity.md §3.7).
--   2. Explosion / Self-Destruct (`opts.explode`) halve the defence AFTER that
--      scaling, on the byte, with a minimum of 1 (CalculateDamage's `srl c`).
--   3. levelTerm = floor(2L/5 + 2), with L doubled on a critical hit.  A crit
--      in Gen1 doubles the *level term*, not the final damage -- close to but
--      not exactly 2x, and the difference is visible at low levels.
--   4. base = min(997, floor(floor(levelTerm * power * attack / defence) / 50))
--      + 2 -- the cap at MAX_NEUTRAL_DAMAGE - MIN_NEUTRAL_DAMAGE comes before
--      the +2 and before every multiplier below, so STAB and the type chart
--      can still carry a hit past 999.
--   5. STAB, as floor(d * 3/2).
--   6. type effectiveness, applied one percent at a time as floor(d * pct/100)
--      -- again the original's shape: against a dual type the two multipliers
--      are two separate truncating steps, not one combined one, so 200 then 50
--      does not always land back where it started.  A single 0 anywhere in the
--      list is immunity: damage is 0 and nothing after it runs.
--   7. the random factor, floor(d * roll / 255) for roll in 217..255 --
--      only when d is 2 or more.  RandomizeDamage (core.asm :5420-5455)
--      opens on `cp 2` / `ret c`: a hit the type chart has already brought
--      to 0 or 1 keeps that number and draws no roll at all, so `rolls`
--      tells the caller whether there is a roll to draw.  For d >= 2 the
--      product is at least floor(2 * 217 / 255) = 1, so the old min-1 clamp
--      only ever guarded a nonsense roll and stays for that.
--
-- A 0 that is not immunity -- a 0.25x matchup taking a 2 or 3 down to 0 --
-- is the caller's miss: AdjustDamageForMoveType sets wMoveMissed when a
-- multiplier step leaves the damage at 0 (core.asm :5170-5176, "this only
-- occurs if a move that would do 2 or 3 damage is 0.25x effective").  This
-- module reports it as `modified = 0` with `immune = false`; Turn says
-- "missed".
--
-- Which stats arrive here is the caller's half of the rule (Turn.lua): the
-- stored battle stats with a screen doubling the defence, or on a critical
-- hit the party stats with no screen at all.
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
-- MAX_NEUTRAL_DAMAGE - MIN_NEUTRAL_DAMAGE (constants/battle_constants.asm):
-- CalculateDamage holds the quotient here and only then adds the 2 back.
M.DAMAGE_CAP = 997
M.DAMAGE_FLOOR = 2

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

-- The 8-bit stat quirk.  Returns the pair plus whether the scaling fired,
-- because "statClamped" is a fixture field and a useful thing to show in a log
-- when a player asks why their 400 attack hit like 100.
--
-- .scaleStats, line for line: either high byte set -> both words shifted
-- right twice; the attack word bumped to 1 if that left it 0; then each
-- operand is the low byte of its word.  The divisor clamp is the referee's,
-- not the cart's (see the header): the cart divides by the wrapped byte and
-- hangs when it is 0.
function M.clampStats(attack, defense)
  attack, defense = max(0, int(attack, 0)), max(0, int(defense, 1))
  if attack <= M.STAT_CAP and defense <= M.STAT_CAP then
    return attack, max(1, defense), false
  end
  local a = floor(attack / 4)
  if a == 0 then a = 1 end
  return a % 256, max(1, floor(defense / 4) % 256), true
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
-- opts:     { crit, stab, typeEffect | typeEff, roll, explode }
--
-- `explode` is the attacker's EXPLODE_EFFECT: the defence it halves is the
-- scaled byte, so it is a step of this pipeline rather than something the
-- caller can do to the stat beforehand.
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
  if opts.explode then
    -- CalculateDamage: `srl c` / `jr nz` / `inc c` -- halved, never below 1.
    defense = max(1, floor(defense / 2))
  end

  local levelTerm = M.levelTerm(attacker.level, opts.crit)
  local power = max(0, int(move.power, 0))

  local quotient = floor(floor(levelTerm * power * attack / defense) / 50)
  if quotient > M.DAMAGE_CAP then quotient = M.DAMAGE_CAP end
  local base = quotient + M.DAMAGE_FLOOR

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
  result.rolls = M.rolls(d)
  result.minDamage = M.applyRoll(d, M.ROLL_MIN)
  result.maxDamage = M.applyRoll(d, M.ROLL_MAX)

  if opts.roll ~= nil then
    result.roll = int(opts.roll, M.ROLL_MAX)
    result.damage = M.applyRoll(d, result.roll)
  end

  return result
end

-- Whether RandomizeDamage draws for this damage: `cp 2` / `ret c` returns
-- before the BattleRandom loop on a 0 or a 1.
function M.rolls(modified)
  return max(0, int(modified, 0)) >= 2
end

-- The random factor on its own, so the turn machine can re-apply a roll it
-- drew elsewhere without rebuilding the whole pipeline.  A 0 or a 1 comes
-- back as it went in, with no roll applied (`M.rolls`).
function M.applyRoll(modified, roll)
  local d = max(0, int(modified, 0))
  if not M.rolls(d) then return d end
  return max(1, floor(d * int(roll, M.ROLL_MAX) / 255))
end

return M
