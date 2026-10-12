-- BattleSim3: the Lua half of the Gen 3 mediated battle intermediator.
--
-- Sibling of src/BattleSim/ (Gen 1) and src/BattleSim2/ (Gen 2): the same
-- purity rules, the same need-shaped loader, the same public API on Turn, and
-- the same role -- the single process that rolls, so clients cannot.  Gen 3 is a
-- full port of the FireRed / LeafGreen / Emerald battle rules the engine carries
-- in src/core/game3/battle/ (pret-cited): abilities, held items, weather, the
-- ordered type chart, every EFFECT_* 0..213, doubles targeting and spread
-- damage, catching and escaping.  The hub holds no ROM tables; the sheet and the
-- ruleset carry everything (docs/plans/gen3-battle-sheet.md, contracts C4 / C5).
--
--   Rng        the shared LCG, and the top-bits roll(lo, hi) every draw uses
--   Types      TYPE_* ids, physical/special by type, the ordered chart walk
--   Damage     CalculateBaseDamage + the damagecalc/typecalc/random pipeline
--   Crit       the five-step stage ladder
--   Accuracy   the combined accuracy/evasion stage table
--   Status     who can take which condition, and the chips
--   Abilities  ABILITY_* ids and every ability trigger
--   Items      HOLD_EFFECT_* triggers and the in-battle bag catalog
--   Field      weather, side conditions, end-of-turn order
--   Catch      ball multipliers, odds, shakes
--   Effects    secondary effects, stat changes, every status/setup handler
--   Move       move resolution + the battle's helper surface
--   Residual   end of turn, battle start, switch-in effects
--   Safari     the Safari Zone mode (the factors, the throws, the monster's turn)
--   Palace     the Battle Palace rules (the failed pick, the half-HP line)
--   Arena      the Battle Arena rules (no switching, the three-turn judge)
--   Turn       the machine (BattleSim2's API)
--   Events     the C5 vocabulary
--
-- Vectors: tests/fixtures/battle_sim3_vectors.json  (luajit tests/battle_sim3_vectors.lua)
-- Turns:   tests/fixtures/battle3_turn_parity.json  (luajit tests/battle_sim3_turn.lua)
--
-- Legal: no ROM-derived values.  Synthetic integers only in the fixtures.

local need = ...

local M = {
  VERSION = 1,
  GENERATION = 3,
  Rng = need("BattleSim3/Rng"),
  Types = need("BattleSim3/Types"),
  Damage = need("BattleSim3/Damage"),
  Crit = need("BattleSim3/Crit"),
  Accuracy = need("BattleSim3/Accuracy"),
  Status = need("BattleSim3/Status"),
  Abilities = need("BattleSim3/Abilities"),
  Items = need("BattleSim3/Items"),
  Field = need("BattleSim3/Field"),
  Catch = need("BattleSim3/Catch"),
  Effects = need("BattleSim3/Effects"),
  Move = need("BattleSim3/Move"),
  Residual = need("BattleSim3/Residual"),
  Safari = need("BattleSim3/Safari"),
  Palace = need("BattleSim3/Palace"),
  Arena = need("BattleSim3/Arena"),
  Events = need("BattleSim3/events"),
  Turn = need("BattleSim3/Turn"),
}

return M
