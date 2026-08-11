'use strict';

/*
 * The hub's Gen2 battle sim, formula half.
 *
 * Node twin of src/BattleSim2. Nothing in here knows what a species is called,
 * what a move is called, or how the type chart is shaped: every one of those
 * is the player's own game data, so the caller looks them up and hands this
 * module integers. That is a legal requirement before it is a design one --
 * no ROM-derived table may live in this repository.
 *
 * Sibling of lib/battle/ (Gen1). Same purity rules; Gen2 formulas differ
 * (SpA/SpD, crit ladder, 85–100% variance, damage cap 999, freeze 1/5 thaw,
 * burn/poison /8). Vectors: tests/fixtures/battle_sim2_vectors.json.
 */

const damage = require('./Damage.js');
const accuracy = require('./Accuracy.js');
const crit = require('./Crit.js');
const status = require('./Status.js');
const Rng = require('./Rng.js');
const Turn = require('./Turn.js');
const events = require('./events.js');
const Effects = require('./Effects.js');

module.exports = {
  damage, accuracy, crit, status, Rng, Turn, events, Effects,
  VERSION: 1,
  GENERATION: 2,
};
