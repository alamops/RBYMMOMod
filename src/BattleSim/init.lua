-- BattleSim: the Lua half of the mediated battle intermediator.
--
-- A battle brokered by this mod is resolved by *one* process -- the LAN host
-- running this code, or the Node hub running its twin under
-- server/lib/battle/ -- and never by whichever client happens to be asking.
-- That is the whole point: with the sim on one side of the wire, a modified
-- client can no longer roll its own damage, and the two peers can no longer
-- disagree about what happened.
--
-- The cost of two runtimes is drift, and the answer to drift is
-- tests/fixtures/battle_sim_vectors.json: a synthetic vector pack both suites
-- run, asserting not just the final damage but every intermediate along the
-- way, so a divergence is caught at the step that caused it.  Anything added
-- here that changes a number needs a vector, or the twins quietly part
-- company.  `luajit tests/battle_sim_vectors.lua` is this side of that.
--
-- Everything under src/BattleSim/ is pure: no love, no engine modules, no mod
-- facade, no state outside what a caller passes in.  The formulas therefore
-- run identically in game, under the headless suite, and inside a hub with no
-- graphics at all -- and the vector suite can load them by hand without
-- standing up a mod.
--
-- Legal: no ROM-derived values live here.  These are arithmetic rules, and
-- every number the fixture feeds them is a synthetic integer -- no species,
-- move or item is named anywhere in this directory.

local need = ...

local M = {
  VERSION = 1,
  Rng = need("BattleSim/Rng"),
  Damage = need("BattleSim/Damage"),
  Accuracy = need("BattleSim/Accuracy"),
  Crit = need("BattleSim/Crit"),
  Status = need("BattleSim/Status"),
  Effects = need("BattleSim/Effects"),
  -- The formulas above answer one question each and remember nothing; these
  -- two are the machine that asks them in order.  Turn is the only module here
  -- with state, and events.lua is the vocabulary it speaks -- mirrored from
  -- Wire rather than imported, so this directory still runs where Config does
  -- not.  `luajit tests/battle_sim_turn.lua` is their suite.
  Events = need("BattleSim/events"),
  Turn = need("BattleSim/Turn"),
}

return M
