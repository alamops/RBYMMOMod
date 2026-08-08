'use strict';

/*
 * The hub's battle sim, formula half.
 *
 * Node twin of src/BattleSim. Nothing in here knows what a species is called,
 * what a move is called, or how the type chart is shaped: every one of those
 * is the player's own game data, so the caller looks them up and hands this
 * module integers. That is a legal requirement before it is a design one --
 * no ROM-derived table may live in this repository.
 *
 * The turn machine (choices, order, switches, deadlines) lands beside this as
 * I1c; this file is only the arithmetic every runtime has to agree on.
 */

const damage = require('./Damage.js');
const accuracy = require('./Accuracy.js');
const crit = require('./Crit.js');
const status = require('./Status.js');
const Rng = require('./Rng.js');

module.exports = { damage, accuracy, crit, status, Rng };
