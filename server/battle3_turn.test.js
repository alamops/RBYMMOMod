#!/usr/bin/env node
'use strict';

/*
 * Cross-runtime parity suite for the Gen 3 turn machine: `lib/battle3/Turn.js`.
 *
 * battle3_vectors.test.js pins the formulas. A vector cannot express what this
 * file is for: the order the questions get asked in, which of them are asked at
 * all, and therefore how many draws come off the RNG before the next one. Two
 * runtimes can agree on every damage number and still fight two different
 * battles from one seed if one of them draws a crit roll for a move that
 * missed.
 *
 * tests/fixtures/battle3_turn_parity.json holds SCRIPTS, not just answers:
 * each scenario is `create` (the Turn.create options, verbatim) plus `steps`,
 * and `expect` is what src/BattleSim3 produced for them (tests/battle_sim3_turn.lua
 * writes it with --update and checks the Lua against it on every run). This file
 * replays the same steps against Turn.js and compares, event for event, as
 * canonical JSON (sorted keys) -- so key order never matters and a missing or
 * extra field always does. `snapshot.rngState` is the one number that proves
 * both runtimes drew the same count.
 *
 * The step vocabulary (tests/battle_sim3_turn.lua is normative):
 *
 *   { op: "drain" }                          drainEvents(); append the events,
 *                                            append the count to `batches`
 *   { op: "submit", player, choice }         submitChoice -> results
 *   { op: "auto", player }                   autoPick -> results
 *   { op: "tick", now }                      tick(now) -> results
 *   { op: "disconnect" | "reconnect", player } -> results
 *   { op: "repeat", times, untilOver, steps } run `steps` `times` times,
 *                                            stopping first when untilOver and
 *                                            outcome() is set
 *   { op: "waiting" }                        snapshot().waiting -> results
 *   { op: "seats", player }                  the seat ids of seatsOf(player)
 *                                            -> results
 *
 * A scenario with `refuses` is a create that must be refused, for exactly that
 * reason; it has no steps and no `expect`.
 *
 * A result the Lua appends as `t[#t + 1] = nil` never lands; a null/undefined
 * result is therefore not appended here either.
 *
 * BATTLE3_TURN_FIXTURE=<path> replays another fixture of the same shape (a
 * scratch fuzz pack, say) instead of the committed one.
 *
 * ROM-free by construction: every species, move and number is invented.
 *
 * Run: node --test server/battle3_turn.test.js
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const { Turn, Events } = require('./lib/battle3');

const FIXTURE = process.env.BATTLE3_TURN_FIXTURE
  || path.join(__dirname, '..', 'tests', 'fixtures', 'battle3_turn_parity.json');
const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));

// ------------------------------------------------------------------
// canonical JSON, the Lua runner's `encode`
// ------------------------------------------------------------------

// Sorted keys, undefined dropped, and an empty object reads as an empty list:
// Lua has one empty table, and its encoder writes it as [] whichever it was.
function encode(value) {
  if (value === undefined || value === null) return 'null';
  if (typeof value === 'boolean' || typeof value === 'number') return JSON.stringify(value);
  if (typeof value === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map((v) => encode(v)).join(',')}]`;
  const keys = Object.keys(value).filter((k) => value[k] !== undefined && value[k] !== null).sort();
  if (keys.length === 0) return '[]';
  return `{${keys.map((k) => `${JSON.stringify(k)}:${encode(value[k])}`).join(',')}}`;
}

// A decoded value back into plain JS with nulls dropped (the Lua `plain`).
function plain(value) {
  if (value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map((v) => plain(v));
  const out = {};
  for (const [k, v] of Object.entries(value)) {
    if (v !== null) out[k] = plain(v);
  }
  return out;
}

// ------------------------------------------------------------------
// replay
// ------------------------------------------------------------------

function digest(battle) {
  const snap = battle.snapshot();
  return {
    phase: snap.phase,
    turn: snap.turn,
    seq: snap.seq,
    now: snap.now,
    deadline: snap.deadline == null ? null : snap.deadline,
    rngState: snap.rngState,
    weather: snap.weather == null ? null : snap.weather,
    field: snap.field.map((entry) => ({ slot: entry.slot, hp: entry.hp, party: entry.party })),
  };
}

function outcomeOf(out) {
  if (!out) return null;
  const o = { battle: out.battle, outcome: out.outcome, reason: out.reason };
  if (out.winners) o.winners = out.winners;
  if (out.losers) o.losers = out.losers;
  if (out.catcher) o.catcher = out.catcher;
  if (out.caught) o.caughtSpecies = out.caught.species;
  if (out.payDay) o.payDay = out.payDay;
  // contract C3 (docs/plans/gen3-solo-remaining-fights.md): how it ended, by whom
  if (out.how) o.how = out.how;
  if (out.by) o.by = out.by;
  // wave 2 of contract C3: a forced catch's `given = false`, a Safari's spend
  if (out.given != null) o.given = out.given;
  if (out.safari) o.safari = out.safari;
  return o;
}

function run(scn) {
  const opts = plain(scn.create);
  if (opts.typeTable === '$chart') opts.typeTable = plain(fixture.typeTable);
  if (opts.movePool === '$pool') opts.movePool = plain(fixture.movePool);
  const { battle, reason } = Turn.attempt(opts);
  if (!battle) return { refused: reason };
  const got = { events: [], batches: [], results: [] };
  const bad = [];
  const push = (r) => {
    if (r !== undefined && r !== null) got.results.push(r);
  };
  const drain = () => {
    const list = battle.drainEvents();
    for (const e of list) {
      const [ok, why] = Events.check(e);
      if (!ok) bad.push(`${e.seq}: ${why}`);
      got.events.push(e);
    }
    got.batches.push(list.length);
  };
  const exec = (steps) => {
    for (const st of steps) {
      if (st.op === 'drain') drain();
      else if (st.op === 'submit') push(battle.submitChoice(st.player, plain(st.choice)));
      else if (st.op === 'auto') push(battle.autoPick(st.player));
      else if (st.op === 'tick') push(battle.tick(st.now));
      else if (st.op === 'disconnect') push(battle.disconnect(st.player));
      else if (st.op === 'reconnect') push(battle.reconnect(st.player));
      else if (st.op === 'waiting') push(battle.snapshot().waiting);
      else if (st.op === 'seats') push(battle.seatsOf(st.player).map((seat) => seat.playerId));
      else if (st.op === 'repeat') {
        for (let i = 0; i < st.times; i += 1) {
          if (st.untilOver && battle.outcome()) break;
          exec(st.steps);
        }
      } else {
        throw new Error(`unknown step op ${st.op}`);
      }
    }
  };
  exec(scn.steps || []);
  got.outcome = outcomeOf(battle.outcome());
  got.snapshot = digest(battle);
  got.badEvents = bad;
  return got;
}

// ------------------------------------------------------------------
// the scenarios
// ------------------------------------------------------------------

test('fixture is the Gen 3 turn pack', () => {
  assert.strictEqual(fixture.version, 1, 'fixture version bumped -- reread its notes');
  assert.strictEqual(fixture.generation, 3, 'this suite replays Gen 3 scripts only');
  assert.ok(Array.isArray(fixture.scenarios) && fixture.scenarios.length > 0, 'scenarios present');
});

for (const scn of fixture.scenarios) {
  test(`scenario ${scn.name}`, () => {
    const got = run(scn);
    if (scn.refuses != null) {
      assert.strictEqual(got.refused, scn.refuses, 'create is refused for exactly that reason');
      return;
    }
    assert.ok(!got.refused, `create refused: ${got.refused}`);
    assert.deepStrictEqual(got.badEvents, [], 'every event is inside the C5 whitelist');
    const exp = scn.expect;
    assert.ok(exp && typeof exp === 'object', 'fixture scenario has an expect block');
    const n = Math.max(exp.events.length, got.events.length);
    for (let i = 0; i < n; i += 1) {
      const a = encode(exp.events[i]);
      const b = encode(got.events[i]);
      if (a !== b) {
        assert.fail(`event ${i + 1} of ${n}\n  expected ${a}\n  got      ${b}`);
      }
    }
    for (const key of ['batches', 'results', 'outcome', 'snapshot']) {
      assert.strictEqual(encode(got[key]), encode(exp[key]), `${key} differs`);
    }
  });
}
