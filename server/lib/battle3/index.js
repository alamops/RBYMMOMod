'use strict';

/*
 * The hub's Gen 3 battle sim: the Node half of the Gen 3 mediated battle
 * intermediator.
 *
 * Node twin of src/BattleSim3 (init.lua), sibling of lib/battle/ (Gen 1) and
 * lib/battle2/ (Gen 2): the same purity rules, the same public API on Turn,
 * and the same role -- the single process that rolls, so clients cannot. Gen 3
 * is a full port of the FireRed / LeafGreen / Emerald battle rules: abilities,
 * held items, weather, the ordered type chart, every EFFECT_* 0..213, doubles
 * targeting and spread damage, catching and escaping. The hub holds no ROM
 * tables; the sheet and the ruleset carry everything
 * (docs/plans/gen3-battle-sheet.md, contracts C4 / C5).
 *
 *   Rng        the shared LCG, and the top-bits roll(lo, hi) every draw uses
 *   Types      TYPE_* ids, physical/special by type, the ordered chart walk
 *   Damage     CalculateBaseDamage + the damagecalc/typecalc/random pipeline
 *   Crit       the five-step stage ladder
 *   Accuracy   the combined accuracy/evasion stage table
 *   Status     who can take which condition, and the chips
 *   Abilities  ABILITY_* ids and every ability trigger
 *   Items      HOLD_EFFECT_* triggers and the in-battle bag catalog
 *   Field      weather, side conditions, end-of-turn order
 *   Catch      ball multipliers, odds, shakes
 *   Effects    secondary effects, stat changes, every status/setup handler
 *   Move       move resolution + the battle's helper surface
 *   Residual   end of turn, battle start, switch-in effects
 *   Turn       the machine (battle2's API: create / attempt / submitChoice ...)
 *   Events     the C5 vocabulary
 *
 * Vectors: tests/fixtures/battle_sim3_vectors.json  (node server/battle3_vectors.test.js)
 * Turns:   tests/fixtures/battle3_turn_parity.json  (node server/battle3_turn.test.js)
 *
 * Legal: no ROM-derived values. Synthetic integers only in the fixtures.
 */

const Rng = require('./Rng.js');
const Types = require('./Types.js');
const Damage = require('./Damage.js');
const Crit = require('./Crit.js');
const Accuracy = require('./Accuracy.js');
const Status = require('./Status.js');
const Abilities = require('./Abilities.js');
const Items = require('./Items.js');
const Field = require('./Field.js');
const Catch = require('./Catch.js');
const Effects = require('./Effects.js');
const Move = require('./Move.js');
const Residual = require('./Residual.js');
const Events = require('./events.js');
const Turn = require('./Turn.js');

module.exports = {
  VERSION: 1,
  GENERATION: 3,
  Rng,
  Types,
  Damage,
  Crit,
  Accuracy,
  Status,
  Abilities,
  Items,
  Field,
  Catch,
  Effects,
  Move,
  Residual,
  Events,
  Turn,
};
