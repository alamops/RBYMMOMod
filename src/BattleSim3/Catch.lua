-- Gen 3 catching: ball multipliers, odds and the four shake checks.
--
-- pret pokefirered/src/battle_script_commands.c:9463 Cmd_handleballthrow, as the
-- engine ports it in src/core/game3/battle/catching.lua (`ballMultiplier`,
-- `catchOdds`, `vanilla_catch`).  Two places follow pret rather than the
-- engine's float shortcut, and the sheet doc says so (§5.5):
--
--   * the odds are `floor(catchRate * mult / 10)` first, then
--     `* (3M - 2H) / (3M)` -- the cart's integer order -- with no floor of 1;
--   * the shake threshold is `1048560 / Sqrt(Sqrt(16711680 / odds))` with the
--     cart's INTEGER square roots (pret `Sqrt` in math_util.c), not float ones.
--
-- Both runtimes compute an integer square root the same way: floor(sqrt(n)) is
-- exact for every n this formula can produce (n < 2^25).
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Types = need("BattleSim3/Types")

local M = {}

local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt

M.MASTER, M.ULTRA, M.GREAT, M.POKE, M.SAFARI = 1, 2, 3, 4, 5
M.NET, M.DIVE, M.NEST, M.REPEAT, M.TIMER, M.LUXURY, M.PREMIER = 6, 7, 8, 9, 10, 11, 12

-- pret sBallCatchBonuses (x10), Ultra .. Safari
M.BONUS = { [2] = 20, [3] = 15, [4] = 10, [5] = 15 }

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

function M.isBall(item)
  local n = int(item, 0)
  return n >= 1 and n <= 12
end

-- ctx: { types = { t1, t2 }, level, turn (battle turn counter), underwater,
--        dexCaught }
function M.multiplier(ball, ctx)
  ball = int(ball, M.POKE)
  ctx = ctx or {}
  if ball == M.MASTER then return 255 end
  if ball <= M.SAFARI then return M.BONUS[ball] or 10 end
  local t = ctx.types or {}
  if ball == M.NET then
    for i = 1, #t do
      if t[i] == Types.ID.WATER or t[i] == Types.ID.BUG then return 30 end
    end
    return 10
  elseif ball == M.DIVE then
    return ctx.underwater and 35 or 10
  elseif ball == M.NEST then
    local level = int(ctx.level, 50)
    if level < 40 then
      local m = 40 - level
      if m <= 9 then m = 10 end
      return m
    end
    return 10
  elseif ball == M.REPEAT then
    return ctx.dexCaught and 30 or 10
  elseif ball == M.TIMER then
    return min(40, 10 + max(0, int(ctx.turn, 0)))
  end
  return 10
end

-- The integer odds `a` (0..).  status: wire token or nil.
function M.odds(ball, catchRate, hp, maxHp, status, ctx)
  local mult = M.multiplier(ball, ctx)
  local mhp = max(1, int(maxHp, 1))
  local h = max(0, int(hp, 0))
  local odds = floor(max(0, int(catchRate, 0)) * mult / 10)
  odds = floor(odds * (mhp * 3 - h * 2) / (3 * mhp))
  if status == "SLP" or status == "FRZ" then
    odds = odds * 2
  elseif status == "PSN" or status == "BRN" or status == "PAR" or status == "TOX" then
    odds = floor(odds * 15 / 10)
  end
  return odds
end

local function isqrt(n)
  n = max(0, floor(n))
  local r = floor(sqrt(n))
  while r * r > n do r = r - 1 end
  while (r + 1) * (r + 1) <= n do r = r + 1 end
  return r
end
M.isqrt = isqrt

-- The shake threshold for odds a (0 < a <= 254), compared against a 0..65535 draw.
function M.shakeThreshold(odds)
  odds = int(odds, 0)
  if odds <= 0 then return 0 end
  local inner = isqrt(isqrt(floor(16711680 / odds)))
  if inner <= 0 then return 65536 end
  return floor(1048560 / inner)
end

-- Returns caught, shakes (0..4; 4 = caught), odds.  Draws up to four
-- rng:roll(0, 65535), stopping at the first failure.
function M.attempt(ball, target, rng, ctx)
  ball = int(ball, M.POKE)
  if ball == M.MASTER then return true, 4, 255 end
  local mon = target and target.mon or target or {}
  local odds = M.odds(ball, mon.catchRate, mon.hp, mon.maxHp, mon.status, ctx)
  if odds > 254 then return true, 4, odds end
  local b = M.shakeThreshold(odds)
  local shakes = 0
  while shakes < 4 do
    local r = rng and rng:roll(0, 65535) or 65535
    if r < b then shakes = shakes + 1 else break end
  end
  return shakes == 4, shakes, odds
end

return M
