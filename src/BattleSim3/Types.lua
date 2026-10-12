-- Gen 3 types: the pret TYPE_* ids, the physical/special split, and the ORDERED
-- type chart walk.
--
-- Port of engine src/core/game3/battle/types.lua (`Types.ID`, `Types.PHYSICAL`,
-- `Types.typeCalc`, pokefirered/src/battle_script_commands.c:1274 Cmd_typecalc).
--
-- The ids are pret enum values (include/constants/pokemon.h) and are code, not
-- data.  The chart itself -- gTypeEffectiveness, pokefirered/src/battle_main.c:312
-- -- IS data, so it is never written here: it arrives per battle as the ruleset's
-- `typeTable`, a flat list of `atk, def, mult` triples in cart order, with the
-- multiplier in tenths and the Foresight sentinel `-1, -1, 0` in place.  See
-- docs/plans/gen3-battle-sheet.md §3.1.
--
-- Why order is the whole point: the cart applies one row at a time and floors
-- after each (`dmg = dmg * mult / 10`), and it applies them in TABLE order, not in
-- defender-type order.  For a dual-typed defender both rows of one attacking type
-- can sit far apart in the table, and a chart modelled as a percent matrix and
-- applied "type 1 then type 2" floors at different points -- the same 1-HP drift
-- on the same roll, every time, and only on some matchups.  The sentinel is the
-- other half: everything after it (Normal/Fighting -> Ghost) is skipped when the
-- defender has been Foresighted, which is how Foresight "removes" the immunity.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...

local M = {}

local floor = math.floor

-- pokefirered/include/constants/pokemon.h TYPE_*
M.ID = {
  NORMAL = 0, FIGHTING = 1, FLYING = 2, POISON = 3, GROUND = 4,
  ROCK = 5, BUG = 6, GHOST = 7, STEEL = 8, MYSTERY = 9,
  FIRE = 10, WATER = 11, GRASS = 12, ELECTRIC = 13, PSYCHIC = 14,
  ICE = 15, DRAGON = 16, DARK = 17,
}
M.MAX = 17

-- The sentinel row that separates the Foresight-skippable tail.
M.FORESIGHT_SENTINEL = -1

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

-- pret IS_TYPE_PHYSICAL(type) ((type) < TYPE_MYSTERY).  `specialTypes`, when a
-- ruleset carries one, is a set { [typeId] = true } of the special types and
-- every other type except MYSTERY is physical.
function M.isPhysical(typeId, specialTypes)
  local t = int(typeId, 0)
  if t == M.ID.MYSTERY then return false end
  if type(specialTypes) == "table" then return specialTypes[t] ~= true end
  return t < M.ID.MYSTERY
end

function M.isSpecial(typeId, specialTypes)
  local t = int(typeId, 0)
  if t == M.ID.MYSTERY then return false end
  return not M.isPhysical(t, specialTypes)
end

-- Copy a flat triple list into a clean integer array, dropping a trailing
-- partial triple.  Anything that is not an integer becomes a neutral row
-- (atk = -2 never matches a real type), so a malformed cell cannot shift every
-- later triple by one and silently rewrite the chart.
function M.copyTable(raw)
  if type(raw) ~= "table" then return nil end
  local out = {}
  local n = #raw - (#raw % 3)
  for i = 1, n, 3 do
    local a, d, m = int(raw[i], nil), int(raw[i + 1], nil), int(raw[i + 2], nil)
    if a == nil or d == nil or m == nil or m < 0 then
      a, d, m = -2, -2, 10
    end
    out[#out + 1] = a
    out[#out + 1] = d
    out[#out + 1] = m
  end
  if #out == 0 then return nil end
  return out
end

-- pokefirered/src/battle_script_commands.c:1274
--
-- Returns dmg (nil in, nil out), flags { super, notVery, immune } and the
-- product of every multiplier applied, in tenths-of-tenths (100 = neutral, 0 =
-- immune, 400 = 4x, 25 = 1/4) -- an integer, so no runtime ever compares floats.
--
-- `def2` nil or equal to `def1` is a single-typed defender.
function M.typeCalc(table_, atkType, def1, def2, dmg, foresight)
  atkType = int(atkType, 0)
  def1 = int(def1, 0)
  def2 = int(def2, nil)
  if def2 == nil then def2 = def1 end
  local flags = { super = false, notVery = false, immune = false }
  local product = 100
  local t = type(table_) == "table" and table_ or nil
  if not t then return dmg, flags, product end

  local function modulate(mult)
    product = floor(product * mult / 10)
    if dmg then
      dmg = floor(dmg * mult / 10)
      if dmg == 0 and mult ~= 0 then dmg = 1 end
    end
    if mult == 0 then
      flags.immune = true
      flags.super = false
      flags.notVery = false
    elseif mult == 5 and not flags.immune then
      if flags.super then flags.super = false else flags.notVery = true end
    elseif mult == 20 and not flags.immune then
      if flags.notVery then flags.notVery = false else flags.super = true end
    end
  end

  local i = 1
  while i + 2 <= #t do
    local a, d, m = t[i], t[i + 1], t[i + 2]
    if a == M.FORESIGHT_SENTINEL then
      if foresight then break end
    elseif a == atkType then
      if d == def1 then modulate(m) end
      if d == def2 and def1 ~= def2 then modulate(m) end
    end
    i = i + 3
  end
  return dmg, flags, product
end

-- The engine's convenience reading: is this move immune / super / not very.
function M.effectivenessOf(table_, atkType, def1, def2, foresight)
  local _, flags, product = M.typeCalc(table_, atkType, def1, def2, nil, foresight)
  return product, flags
end

return M
