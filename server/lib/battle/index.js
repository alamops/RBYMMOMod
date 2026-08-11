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
 * The formula modules answer one question each and remember nothing; `Turn` is
 * the machine that asks them in order, and `events` is the vocabulary it
 * speaks. Turn is the only module here with state, and the only one whose
 * parity with the Lua is about the *order* questions get asked in rather than
 * the arithmetic -- server/battle_turn.test.js pins it against luajit running
 * src/BattleSim/Turn.lua on the same seed.
 */

const damage = require('./Damage.js');
const accuracy = require('./Accuracy.js');
const crit = require('./Crit.js');
const status = require('./Status.js');
const Rng = require('./Rng.js');
const Turn = require('./Turn.js');
const events = require('./events.js');
const Effects = require('./Effects.js');

module.exports = { damage, accuracy, crit, status, Rng, Turn, events, Effects };
