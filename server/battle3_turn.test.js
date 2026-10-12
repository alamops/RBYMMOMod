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
 *   { op: "levelup", player, mon, level, stats, maxHp } -> results
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
  // wave 3: the Battle Arena's judged losers, by sheet slot
  if (out.judged) o.judged = out.judged;
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
      else if (st.op === 'levelup') push(battle.levelUp(st.player, st.mon, st.level, plain(st.stats), st.maxHp));
      else if (st.op === 'disconnect') push(battle.disconnect(st.player));
      else if (st.op === 'reconnect') push(battle.reconnect(st.player));
      else if (st.op === 'waiting') push(battle.snapshot().waiting);
      else if (st.op === 'seats') push(battle.seatsOf(st.player).map((seat) => seat.playerId));
      else if (st.op === 'palaceLow') push(battle.palaceLow(st.slot));
      else if (st.op === 'arena') push(battle.snapshot().arena || false);
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

// ------------------------------------------------------------------
// contract C-W: WALLY's throw (docs/plans/gen3-solo-remaining-fights.md, wave
// 4b), asserted on this twin's own replay -- the Lua runner asserts the same
// on its own (tests/battle_sim3_turn.lua). pokeemerald battle_main.c:4819
// sorts B_ACTION_WALLY_THROW with the moves at priority 0 (MOVE_NONE, :4706);
// battle_util.c:625 HandleAction_WallyBallThrow sets gActionsByTurnOrder[1] =
// B_ACTION_FINISHED.
// ------------------------------------------------------------------

test('C-W: WALLY\'s throw is ordered with the moves and cancels the second slot', () => {
  const byName = new Map(fixture.scenarios.map((s) => [s.name, s]));
  const replay = (name) => {
    const scn = byName.get(name);
    assert.ok(scn, `${name} is in the fixture`);
    const got = run(scn);
    assert.ok(!got.refused, `${name}: create refused: ${got.refused}`);
    return got;
  };
  const at = (got, pred, from = -1) => {
    for (let i = from + 1; i < got.events.length; i += 1) if (pred(got.events[i])) return i;
    return -1;
  };
  const isThrow = (e) => e.t === 'wallyThrow';
  const used = (who) => (e) => e.t === 'msg' && e.text.startsWith(`${who} used `);
  const turnOf = (n) => (e) => e.t === 'turn' && e.amount === n && e.slot === undefined;
  const count = (got, pred) => got.events.filter(pred).length;

  let got = replay('w4b_wally_cw_throw_first');
  const t3 = at(got, turnOf(3));
  const t4 = at(got, turnOf(4));
  const thr = at(got, isThrow);
  assert.ok(t3 >= 0 && t3 < thr && thr < t4, 'the throw runs in turn 3, and turn 4 opens after it');
  assert.deepStrictEqual({ seat: got.events[thr].seat, slot: got.events[thr].slot, side: got.events[thr].side },
    { seat: undefined, slot: 0, side: 'a' }, 'wallyThrow { slot, side }, no seat');
  const foeAfter = at(got, used('RALTS'), t3);
  assert.ok(foeAfter < 0 || foeAfter > t4, 'thrown first, the foe never acts in turn 3');
  assert.strictEqual(count(got, isThrow), 1, 'one throw, one event');
  assert.ok(got.outcome.how === 'catch' && got.outcome.given === false, "turn 4's ball is the forced catch");

  for (const name of ['w4b_wally_cw_foe_first', 'w4b_wally_cw_tie_foe_first', 'w4b_wally_cw_priority_foe',
    'w4b_wally_cw_quick_claw_foe']) {
    got = replay(name);
    const foe = at(got, used('RALTS'));
    const t = at(got, isThrow);
    const t2 = at(got, turnOf(2));
    assert.ok(foe >= 0 && foe < t && t < t2, `${name}: the foe acts first, then the throw, then turn 2`);
  }
  for (const name of ['w4b_wally_cw_tie_throw_first', 'w4b_wally_cw_negative_priority_foe']) {
    got = replay(name);
    const t = at(got, isThrow);
    assert.ok(t >= 0 && t < at(got, turnOf(2)) && at(got, used('RALTS')) < 0,
      `${name}: thrown first, the foe never acts that turn`);
  }
  got = replay('w4b_wally_cw_thrower_down');
  assert.ok(count(got, isThrow) === 0 && got.outcome.how === 'ko', 'no throw from a fainted thrower');
  got = replay('w4b_wally_cw_second_slot_partner');
  const tp = at(got, isThrow);
  assert.ok(tp >= 0 && at(got, used('PARTNER')) < 0 && at(got, used('RALTS'), tp) > tp,
    "gActionsByTurnOrder[1] is the partner's; the third slot acts");
  for (const [name, slot] of [['w4b_wally_cw_refused_plain_wild', 0], ['w4b_wally_cw_refused_old_man', 0],
    ['w4b_wally_cw_refused_pokedude', 0], ['w4b_wally_cw_refused_1v1', 0],
    ['w4b_wally_cw_refused_no_battler', 0], ['w4b_wally_cw_refused_replacing', 2]]) {
    got = replay(name);
    assert.ok(got.results[slot] === false && count(got, isThrow) === 0, `${name}: refused and never emitted`);
  }
  got = replay('w4b_wally_cw_refused_side_b');
  assert.ok(got.results[0] === false && got.results[2] === true && count(got, isThrow) === 1
    && got.events[at(got, isThrow)].side === 'a', "side b's throw refused, side a's taken");
  // WALLY's seat alone: side a's second seat (a coop partner) is refused like
  // side b (pokeemerald's WALLY controller drives B_POSITION_PLAYER_LEFT only),
  // so a turn where both side-a seats file one holds one throw, from slot 0.
  got = replay('w4b_wally_cw_refused_partner');
  const tq = at(got, isThrow);
  assert.ok(got.results[0] === false && got.results[1] === true && count(got, isThrow) === 1
    && got.events[tq].slot === 0 && got.events[tq].side === 'a',
    "the partner's throw refused, WALLY's taken; one throw, from slot 0");

  // The throw draws nothing: no tie, no QUICK CLAW, the foe cancelled.
  const opts = plain(byName.get('w4b_wally_cw_throw_first').create);
  opts.typeTable = plain(fixture.typeTable);
  opts.movePool = plain(fixture.movePool);
  delete opts.wildPick;
  const { battle } = Turn.attempt(opts);
  battle.drainEvents();
  const before = battle.snapshot().rngState;
  battle.submitChoice('p1', { action: 'wallyThrow' });
  battle.submitChoice('wild', { action: 'fight', move: 0 });
  assert.ok(battle.snapshot().rngState === before && battle.snapshot().turn === 2,
    'the throw turn drew nothing and closed');
  const b2 = Turn.attempt(opts).battle;
  assert.strictEqual(b2.submitChoice('p1', {
    action: 'wallyThrow', move: 1, item: 4, slot: 1, target: 3,
  }), true, 'stray fields on a wallyThrow are ignored, not refused');
});
