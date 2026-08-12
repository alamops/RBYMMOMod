-- BattleSim2: the Lua half of the Gen 2 mediated battle intermediator.
--
-- Sibling of src/BattleSim/ (Gen 1).  Same purity rules, same need-shaped
-- loader, same role as the single process that rolls damage so clients cannot.
-- Gen 2 differs in the formulas (SpA/SpD, crit ladder, 85–100% variance,
-- damage cap 999, freeze 1/5 thaw, burn/poison /8) — see each module header.
--
-- Vectors: tests/fixtures/battle_sim2_vectors.json
-- Run:    luajit tests/battle_sim2_vectors.lua
--
-- Legal: no ROM-derived values.  Synthetic integers only.

local need = ...

local M = {
  VERSION = 1,
  GENERATION = 2,
  Rng = need("BattleSim2/Rng"),
  Damage = need("BattleSim2/Damage"),
  Accuracy = need("BattleSim2/Accuracy"),
  Crit = need("BattleSim2/Crit"),
  Status = need("BattleSim2/Status"),
  Effects = need("BattleSim2/Effects"),
  Events = need("BattleSim2/events"),
  Turn = need("BattleSim2/Turn"),
}

return M
